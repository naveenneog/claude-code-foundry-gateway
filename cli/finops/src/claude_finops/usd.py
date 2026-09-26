"""USD budget client rules. Pricing stays in the gateway/AUM service engine."""

from copy import deepcopy
from decimal import Decimal, InvalidOperation
import re

from .errors import FinOpsError
from .rules import scope_type, identifier, can_budget_write


USD_AMOUNT = re.compile(r"^(0|[1-9][0-9]{0,11})(?:\.([0-9]{1,9}))?$")


def parse_usd(text):
    value = str(text).strip()
    if not USD_AMOUNT.fullmatch(value):
        raise FinOpsError("USD amounts are decimal strings: nonnegative, below one trillion, up to 9 fractional digits.")
    try:
        amount = Decimal(value)
    except InvalidOperation:
        raise FinOpsError("USD amount must be finite decimal text.") from None
    if amount < 0 or amount >= Decimal("1000000000000"):
        raise FinOpsError("USD amount must be nonnegative and below one trillion.")
    return value


def usd_key(kind, key):
    return scope_type(kind), identifier(key)


def normalize_usd_items(document):
    items = document.get("items", [])
    if isinstance(items, dict):
        rows = []
        for key, item in items.items():
            kind, _, scope_id = key.partition(":")
            rows.append({"scope_type": kind, "scope_id": scope_id, **item})
        return rows
    return list(items)


def usd_row(document, kind, key):
    for row in normalize_usd_items(document):
        if row.get("scope_type") == kind and row.get("scope_id") == key:
            return row
    return None


def merge_usd_into_budgets(budgets, definitions, status):
    result = deepcopy(budgets)
    definitions_by_key = {f"{row.get('scope_type')}:{row.get('scope_id')}": row for row in normalize_usd_items(definitions)}
    status_items = status.get("items", {}) if isinstance(status, dict) else {}
    for row in result.get("items", []):
        key = f"{row.get('scope_type')}:{row.get('scope_id')}"
        definition = definitions_by_key.get(key)
        state = status_items.get(key, {})
        row["usd_budget"] = definition.get("amount_usd") if definition else None
        row["usd_effective_budget"] = state.get("effective_budget_usd")
        row["usd_spent"] = state.get("spent_usd")
        row["usd_status"] = state.get("status", "not set" if not definition else "awaiting reconciliation")
        row["usd_exact"] = state.get("exact")
        row["usd_cache_read_known"] = state.get("cache_read_known")
        row["usd_cache_write_known"] = state.get("cache_write_known")
        row["usd_unpriced_models"] = state.get("unpriced_models", [])
        row["usd_period_start"] = state.get("period_start")
        row["usd_period_end"] = state.get("period_end")
        row["usd_reconciled_at"] = status.get("reconciled_at")
        row["usd_writable"] = definition.get("writable") if definition else row.get("writable")
    result["usd"] = {
        "definitions": definitions,
        "status": status,
        "note": "Dollar budgets are delayed observed-category stops. Null spend is unpriced, never zero.",
    }
    return result


def can_usd_write(identity, kind, key, row):
    if row and row.get("writable") is False:
        return False
    return can_budget_write(identity, kind, key, row.get("parent_scope_id") if row else None)
