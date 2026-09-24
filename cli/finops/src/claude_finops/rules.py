"""Pure rules shared by command and interactive faces."""

import re
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

from .errors import FinOpsError

SCOPE_TYPES = {"unit": "organization", "team": "department", "person": "user",
               "organization": "organization", "department": "department", "user": "user"}


def month_window(month: str) -> tuple[str, str]:
    if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month):
        raise FinOpsError("Use a month in YYYY-MM format, for example 2026-09.")
    try:
        year, number = map(int, month.split("-"))
        start = date(year, number, 1)
        end = date(year + (number == 12), number % 12 + 1, 1)
    except ValueError:
        raise FinOpsError("Month must be between 0001-01 and 9998-12.") from None
    return f"{start}T00:00:00Z", f"{end}T00:00:00Z"


def parse_tokens(text: str | int) -> int:
    value = str(text).strip().replace(",", "")
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([kKmMbB]?)", value)
    if not match:
        raise FinOpsError("Enter whole tokens, for example 1500000 or 1.5M. USD is not a token limit.")
    try:
        result = Decimal(match[1]) * {"": 1, "k": 1000, "m": 1000000, "b": 1000000000}[match[2].lower()]
    except InvalidOperation:
        raise FinOpsError("Enter a finite token amount.") from None
    if result != int(result) or not 1 <= result <= 10**15:
        raise FinOpsError("Token limit must be a whole number between 1 and 1,000,000,000,000,000.")
    return int(result)


def can_edit(identity: dict) -> bool:
    return identity.get("role") == "owner"


def require_owner(identity: dict) -> None:
    if not can_edit(identity):
        raise FinOpsError("Read-only role. Ask an Owner to make this change; manager writes are not enabled.", 4)


def scope_type(value: str) -> str:
    if value not in SCOPE_TYPES:
        raise FinOpsError("Scope must be unit, team or person.")
    return SCOPE_TYPES[value]


def identifier(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:@-]{0,199}", value):
        raise FinOpsError("Use a stable identifier: letters, digits, dot, underscore, colon, @ or hyphen.")
    return value


def allocation_left(rows: list[dict], row: dict, proposed: int) -> int | None:
    parent_type = {"department": "organization", "user": "department"}.get(row["scope_type"])
    parent = next((item for item in rows if item["scope_type"] == parent_type
                   and item["scope_id"] == row.get("parent_scope_id")), None)
    if parent is None or parent.get("token_limit") is None:
        return None
    siblings = sum(item.get("token_limit") or 0 for item in rows
                   if item.get("parent_scope_id") == parent["scope_id"]
                   and item["scope_type"] == row["scope_type"] and item["scope_id"] != row["scope_id"])
    return parent["token_limit"] - siblings - proposed


def validate_budget(rows: list[dict], row: dict, amount: int) -> None:
    left = allocation_left(rows, row, amount)
    if left is not None and left < 0:
        raise FinOpsError(f"Parent headroom is short by {-left:,} tokens. Ask its Owner to raise the allocation.")
    child_type = {"organization": "department", "department": "user"}.get(row["scope_type"])
    allocated = sum(item.get("token_limit") or 0 for item in rows
                    if item.get("parent_scope_id") == row["scope_id"] and item["scope_type"] == child_type)
    if amount < allocated:
        raise FinOpsError(f"{allocated:,} tokens are allocated to children. Lower those allocations first.")


def human(value: object) -> str:
    if value is None:
        return "not set"
    if not isinstance(value, (int, float)):
        return str(value)
    for size, suffix in ((10**9, "B"), (10**6, "M"), (1000, "k")):
        if abs(value) >= size:
            return f"{value / size:.2f}".rstrip("0").rstrip(".") + suffix
    return f"{value:,}"


def apply_state(status: dict, since: str | None = None) -> str:
    if not status.get("configured"):
        return "Not configured: ask an Owner to connect the apply job."
    if status.get("executions_error"):
        return "Unknown: cannot read apply executions; check Azure job access."
    request = status.get("last_request") or {}
    def at_or_after(value, boundary):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")) >= datetime.fromisoformat(boundary.replace("Z", "+00:00"))
        except (ValueError, AttributeError, TypeError):
            return False
    if since and not at_or_after(request.get("requested_at"), since):
        return "Pending: waiting for this save's apply request."
    if request.get("error"):
        return "Failed: apply could not start; check Governance and retry Apply now."
    execution_id = request.get("execution")
    executions = status.get("executions", [])
    if execution_id:
        executions = [e for e in executions if e.get("name") == execution_id.split("/")[-1]]
    elif since:
        executions = [e for e in executions if at_or_after(e.get("started_at"), since)]
    if not executions:
        return "Pending: waiting for the apply job."
    state = executions[0].get("status", "Unknown")
    if state.lower() == "succeeded":
        return "Apply succeeded: " + str(executions[0].get("ended_at") or "time unavailable")
    if state.lower() in {"failed", "cancelled", "canceled"}:
        return f"Failed: job {state}; check Azure execution logs."
    return f"Applying: {state}; usually about two minutes."
