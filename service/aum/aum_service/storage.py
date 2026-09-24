from contextlib import contextmanager
from datetime import UTC, datetime
import json
import re
import threading
from uuid import uuid4

from azure.core.exceptions import HttpResponseError, ResourceExistsError, ResourceNotFoundError
from azure.data.tables import TableClient, UpdateMode
from azure.storage.blob import BlobClient

from .errors import Conflict, ServiceError, invalid


KEY = re.compile(r"^[A-Za-z0-9:._-]{1,200}$")
INDEX_FIELDS = ("state", "scope_type", "scope_id", "requester", "approver_scope", "expires_at")


def check_key(value):
    if not isinstance(value, str) or not KEY.fullmatch(value):
        raise invalid("Invalid storage record key")
    return value


def encode_entity(kind, key, value):
    raw = json.dumps(value, separators=(",", ":"), ensure_ascii=True)
    if len(raw.encode("utf-16-le")) > 64000:
        raise ServiceError(413, "audit_too_large", "Record exceeds the Table storage property limit")
    return {"PartitionKey": check_key(kind), "RowKey": check_key(key), "data": raw,
            **{k: str(value[k]) for k in INDEX_FIELDS if value.get(k) is not None}}


def decode_entity(row):
    return json.loads(row["data"])


def row_filter(kind, after=None):
    result = f"PartitionKey eq '{check_key(kind)}'"
    return result + (f" and RowKey gt '{check_key(after)}'" if after else "")


class AzureStore:
    def __init__(self, account_name, credential, table="AumState"):
        if not re.fullmatch(r"[a-z0-9]{3,24}", account_name):
            raise invalid("AUM_STORAGE_ACCOUNT must be a storage account name")
        self.table = TableClient(f"https://{account_name}.table.core.windows.net",
                                 table, credential=credential, retry_total=0)
        self.blob = BlobClient(f"https://{account_name}.blob.core.windows.net",
                               "aum-control", "gateway-writer", credential=credential, retry_total=0)

    def get(self, kind, key):
        try:
            return decode_entity(self.table.get_entity(check_key(kind), check_key(key)))
        except ResourceNotFoundError:
            return None

    def put(self, kind, key, value, create=False):
        row = encode_entity(kind, key, value)
        if create:
            try:
                self.table.create_entity(row)
            except ResourceExistsError as error:
                raise Conflict("Record already exists", "duplicate_record") from error
        else:
            self.table.upsert_entity(row, mode=UpdateMode.REPLACE)

    def list(self, kind, limit=200, after=None, filters=None):
        pager = self.table.query_entities(row_filter(kind, after), results_per_page=limit + 1).by_page()
        try:
            rows = list(next(pager))
        except StopIteration:
            return [], None
        more = len(rows) > limit or pager.continuation_token is not None
        taken = rows[:limit]
        result = [decode_entity(row) for row in taken]
        if filters:
            result = [row for row in result if filters(row)]
        return result, taken[-1]["RowKey"] if more and taken else None

    def mappings(self):
        result = {}
        pager = self.table.query_entities(row_filter("managers"), results_per_page=300)
        for index, row in enumerate(pager):
            if index >= 256:
                raise ServiceError(503, "mapping_capacity", "Manager mapping exceeds catalog capacity")
            value = decode_entity(row).get("manager_group_id")
            if value:
                result[row["RowKey"]] = value
        return result

    def audit(self, event):
        # Sort most recent first without scanning old audit history.
        reverse_time = 9999999999999999 - int(datetime.now(UTC).timestamp() * 1000000)
        key = f"{reverse_time:016}-{uuid4()}"
        self.put("audit", key, event, create=True)

    def due_boosts(self, now, limit=100):
        query = row_filter("boosts") + " and (state eq 'active' or state eq 'pending') and expires_at le @now"
        pager = self.table.query_entities(query, parameters={"now": now}, results_per_page=limit).by_page()
        try:
            return [decode_entity(row) for row in next(pager)]
        except StopIteration:
            return []

    def active_boost(self, kind, key):
        query = (row_filter("boosts") + " and (state eq 'active' or state eq 'pending')"
                 " and scope_type eq @kind and scope_id eq @key")
        rows = self.table.query_entities(query, parameters={"kind": kind, "key": key}, results_per_page=1)
        return next((decode_entity(row) for row in rows), None)

    @contextmanager
    def lease(self):
        try:
            self.blob.upload_blob(b"", overwrite=False)
        except ResourceExistsError:
            pass
        try:
            lease = self.blob.acquire_lease(lease_duration=60)
        except HttpResponseError as error:
            if error.status_code == 409:
                raise Conflict("Another service writer is active; read state before retrying", "writer_busy") from error
            raise
        stopped, lost = threading.Event(), threading.Event()
        def renew():
            while not stopped.wait(20):
                try:
                    lease.renew()
                except Exception:
                    lost.set()
                    return
        worker = threading.Thread(target=renew, daemon=True)
        worker.start()
        def check():
            if lost.is_set():
                raise Conflict("Gateway writer lease was lost", "lease_lost")
        try:
            yield check
        finally:
            stopped.set()
            worker.join(timeout=5)
            try:
                lease.release()
            except HttpResponseError:
                # A 60-second server lease expires even if a worker loses connectivity.
                pass
