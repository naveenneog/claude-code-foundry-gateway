from contextlib import contextmanager
from copy import deepcopy
from datetime import UTC, datetime

from aum_service.errors import Conflict

from test_registry import values


class FakeArm:
    def __init__(self, raw=None):
        self.values = dict(raw or values())
        self.etags = {k: 1 for k in self.values}
        self.writes = []
        self.fail_key = None
        self.corrupt_key = None

    def read(self):
        return {k: {"value": v, "etag": str(self.etags[k])} for k, v in self.values.items()}

    def get(self, key):
        return {"value": self.values[key], "etag": str(self.etags[key])}

    def put(self, key, value, etag):
        if key == self.fail_key:
            raise RuntimeError("Simulated ARM write failure")
        if str(self.etags[key]) != etag:
            raise Conflict("ARM ETag changed")
        self.values[key] = value if self.corrupt_key != key else "wrong-value"
        self.etags[key] += 1
        self.writes.append((key, value))
        return self.get(key)


class FakeStore:
    def __init__(self):
        self.rows = {}
        self.audits = []
        self.fail_audit = False
        self.locked = False

    @contextmanager
    def lease(self):
        if self.locked:
            raise Conflict("Another writer holds the lease")
        self.locked = True
        try:
            yield lambda: None
        finally:
            self.locked = False

    def get(self, kind, key):
        return deepcopy(self.rows.get((kind, key)))

    def put(self, kind, key, value, create=False):
        if create and (kind, key) in self.rows:
            raise Conflict("Already exists")
        self.rows[(kind, key)] = deepcopy(value)

    def list(self, kind, limit=200, after=None, filters=None):
        entries = [(k, deepcopy(v)) for (p, k), v in sorted(self.rows.items()) if p == kind
                   and (not after or k > after)]
        if filters:
            entries = [(k, v) for k, v in entries if filters(v)]
        taken = entries[:limit]
        return [v for _, v in taken], taken[-1][0] if len(entries) > limit else None

    def mappings(self):
        return {k: v["manager_group_id"] for (p, k), v in self.rows.items()
                if p == "managers" and v["manager_group_id"]}

    def audit(self, event):
        if self.fail_audit:
            raise RuntimeError("Simulated audit outage")
        self.audits.append(deepcopy(event))

    def due_boosts(self, now, limit=100):
        return [deepcopy(v) for (p, _), v in self.rows.items() if p == "boosts"
                and v["state"] in {"active", "pending"}
                and v["expires_at"] <= now][:limit]

    def active_boost(self, kind, key):
        return next((deepcopy(v) for (p, _), v in self.rows.items() if p == "boosts"
                     and v["scope_type"] == kind and v["scope_id"] == key
                     and v["state"] in {"active", "pending"}), None)


class FakeAnalytics:
    def __init__(self):
        self.members = {}
        self.queries = []
        self.usage_rows = []

    def memberships(self, ids):
        return {id_: self.members[id_] for id_ in ids if id_ in self.members}

    def query(self, query):
        self.queries.append(query)
        return deepcopy(self.usage_rows)


class Clock:
    def __init__(self):
        self.now = datetime(2026, 9, 24, 12, 0, tzinfo=UTC)

    def __call__(self):
        return self.now
