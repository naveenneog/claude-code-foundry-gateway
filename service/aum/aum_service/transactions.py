from .errors import Conflict, ServiceError
from .registry import checked_value


def apply_values(arm, snapshot, changes, check_lease):
    receipts = []
    try:
        for key, value in changes.items():
            checked_value(value)
            if key not in snapshot:
                raise Conflict(f"Named value {key} is missing; redeploy the gateway template first")
        for key, value in changes.items():
            check_lease()
            before = snapshot[key]
            current = arm.get(key)
            if current["value"] != before["value"] or (
                before.get("etag") and current["etag"] != before["etag"]
            ):
                raise Conflict("Gateway changed since it was read", "stale_revision")
            if before["value"] == value:
                continue
            result = arm.put(key, value, current["etag"])
            receipts.append((key, before["value"], result["etag"]))
            readback = arm.get(key)
            if readback["value"] != value or readback["etag"] != result["etag"]:
                raise Conflict("Named value read-back did not match", "readback_failed")
        return {key: arm.get(key) for key in changes}
    except Exception as error:
        incomplete = []
        for key, previous, written_etag in reversed(receipts):
            try:
                check_lease()
                arm.put(key, previous, written_etag)
                if arm.get(key)["value"] != previous:
                    incomplete.append(key)
            except Exception:
                incomplete.append(key)
        if incomplete:
            raise ServiceError(502, "rollback_failed",
                               "Rollback needs administrator review: " + ", ".join(incomplete)) from error
        if isinstance(error, ServiceError) and not receipts:
            raise
        raise ServiceError(502, "write_failed", "Named-value write failed; completed changes restored") from error
