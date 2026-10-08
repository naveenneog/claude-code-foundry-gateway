import base64
import binascii
from datetime import UTC, datetime, timedelta
from decimal import Decimal, InvalidOperation, localcontext
import hashlib
import json
import re

from .errors import Conflict, ServiceError, invalid
from .registry import Config, checked_value


USD_NAMES = ("usd-budgets", "bu-modes", "bu-parents", "bu-members",
             "entitlement-source", "turnstile-integration")
DECIMAL = re.compile(r"^[0-9]{1,12}(?:\.[0-9]{1,9})?$")
SCOPE = re.compile(r"^(organization|department|user):([a-z0-9-]{1,100})$")
MODEL_KEY = re.compile(r"[^a-z0-9]", re.I)


class JsonNumber(str):
    pass


def timestamp(value):
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def decode_document(raw):
    if raw is None:
        return {}
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    try:
        checked_value(raw)
        result = json.loads(base64.b64decode(raw, validate=True).decode("ascii"),
                            object_pairs_hook=unique, parse_float=JsonNumber)
        if not isinstance(result, dict):
            raise ValueError("object required")
        return result
    except (ValueError, TypeError, UnicodeError, binascii.Error) as error:
        raise Conflict("USD configuration is not valid encoded JSON", "usd_invalid_configuration") from error


def encode_document(document):
    raw = json.dumps(document, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return checked_value(base64.b64encode(raw.encode("ascii")).decode("ascii"))


def encode_state(state):
    if not state:
        return encode_document({})
    packed = {k: v for k, v in state.items() if k != "items"}
    packed.update(encoding="compact-v1", periods={}, items={})
    for key, item in state["items"].items():
        packed["price_book_date"] = item["price_book_date"]
        packed["periods"][item["period"]] = [item["period_start"], item["period_end"]]
        flags = int(item["exact"]) | (int(item["cache_read_known"]) << 1) | (int(item["cache_write_known"]) << 2)
        packed["items"][key] = [item["period"], item["budget_usd"], item["effective_budget_usd"],
                                item["spent_usd"], item["status"], item["enforcement"], flags,
                                item["unpriced_models"]]
    return encode_document(packed)


def decode_state(raw):
    packed = decode_document(raw)
    if packed.get("encoding") != "compact-v1":
        return packed
    state = {k: v for k, v in packed.items() if k not in ("encoding", "periods", "price_book_date", "items")}
    state["items"] = {}
    try:
        for key, data in packed["items"].items():
            if len(data) != 8 or type(data[6]) is not int or not 0 <= data[6] <= 7:
                raise ValueError()
            kind, target = key.split(":", 1)
            start, end = packed["periods"][data[0]]
            state["items"][key] = {
                "scope_type": kind, "scope_id": target, "period": data[0],
                "period_start": start, "period_end": end, "price_book_date": packed["price_book_date"],
                "budget_usd": data[1], "effective_budget_usd": data[2], "spent_usd": data[3],
                "status": data[4], "enforcement": data[5], "exact": bool(data[6] & 1),
                "cache_read_known": bool(data[6] & 2), "cache_write_known": bool(data[6] & 4),
                "unpriced_models": data[7],
            }
    except (KeyError, TypeError, ValueError) as error:
        raise Conflict("Invalid compact USD state", "usd_invalid_configuration") from error
    return state


def dollars(value):
    if type(value) is not str or not DECIMAL.fullmatch(value):
        raise invalid("USD amounts must be nonnegative decimal strings with at most 9 fractional digits")
    return Decimal(value)


def parse_budgets(raw):
    doc = decode_document(raw)
    if not doc:
        return {}
    if (set(doc) != {"schema_version", "price_book", "items"}
            or type(doc["schema_version"]) is not int or doc["schema_version"] != 1):
        raise invalid("USD budget schema_version must be 1")
    book = doc["price_book"]
    if not isinstance(book, dict) or not isinstance(book.get("models"), dict) or not book["models"]:
        raise invalid("USD budgets require a nonempty dated price book")
    try:
        datetime.strptime(book["date"], "%Y-%m-%d")
    except (ValueError, TypeError, KeyError) as error:
        raise invalid("Price book date must be YYYY-MM-DD") from error
    if not isinstance(doc["items"], dict):
        raise invalid("USD budget items must be an object")
    for key, item in doc["items"].items():
        match = SCOPE.fullmatch(key)
        if not match or not isinstance(item, dict) or set(item) != {"amount_usd", "period", "price_book_date"}:
            raise invalid("USD budget scope or fields are invalid")
        dollars(item["amount_usd"])
        if item["period"] not in ("day", "month") or (match[1] != "user" and item["period"] != "month"):
            raise invalid("Units and teams are monthly; people may be daily or monthly")
        if item["price_book_date"] != book["date"]:
            raise invalid("Every budget must reference the stored price-book date")
    return doc


def effective_price_rates(model):
    if not isinstance(model, dict):
        raise ServiceError(503, "usd_unpriced", "Required category price is missing or invalid")
    base = rate(model.get("inputPerM"))
    return (
        base,
        rate(model.get("outputPerM")),
        rate(model.get("cacheReadPerM", base * Decimal("0.1"))),
        rate(model.get("cacheWrite5mPerM", base * Decimal("1.25"))),
        rate(model.get("cacheWrite1hPerM", base * Decimal("2"))),
    )


def validate_price_book(book):
    seen = {}
    for key, model in book.get("models", {}).items():
        normalized = normalized_model_key(key)
        if normalized in seen:
            raise invalid(f"Duplicate normalized price-book key: {seen[normalized]} and {key}")
        seen[normalized] = key
        if not isinstance(model, dict):
            raise invalid("Price book model entries must be objects")
        effective_price_rates(model)


def check_authority(values):
    integration = values.get("turnstile-integration", "")
    if re.search(r"(?:^|;)(?:governanceAuthority|budgetAuthority)=Turnstile(?:;|$)", integration, re.I):
        raise Conflict("Turnstile owns governance; USD reconciliation and writes are refused", "other_authority")


def source_revision(values):
    text = "\n".join(values.get(key, "") for key in USD_NAMES)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def quantity(value):
    try:
        if isinstance(value, bool) or value is None:
            raise ValueError()
        result = Decimal(str(value))
        if not result.is_finite() or result < 0 or result != result.to_integral_value() or result > 9223372036854775807:
            raise ValueError()
        return result
    except (InvalidOperation, ValueError) as error:
        raise ServiceError(503, "usd_invalid_usage", "Usage must contain finite nonnegative integer token counts") from error


def rate(value):
    try:
        if value is None or isinstance(value, bool):
            raise ValueError()
        result = Decimal(str(value))
        if not result.is_finite() or result < 0 or result > 1000000:
            raise ValueError()
        return result
    except (ValueError, InvalidOperation) as error:
        raise ServiceError(503, "usd_unpriced", "Required category price is missing or invalid") from error


def money(value):
    return format(value, "f").rstrip("0").rstrip(".") if "." in format(value, "f") else format(value, "f")


def _ordinal_sort_key(key):
    # The order of scripts/flow/FlowContract.ps1 Sort-ClaudeFlowOrdinal (P76): .NET ToUpperInvariant, a one-to-one
    # uppercase (str.upper() can expand one character, as ß to SS), compared by UTF-16 code units, then the key itself.
    folded = "".join(ch.upper() if len(ch.upper()) == 1 else ch for ch in key)
    return (folded.encode("utf-16-be", "surrogatepass"), key.encode("utf-16-be", "surrogatepass"))


def normalized_model_key(value):
    return MODEL_KEY.sub("", str(value or "")).lower()


def price_book_key(name, book):
    models = book.get("models", {}) if isinstance(book, dict) else {}
    target = normalized_model_key(name)
    poisoned = set()
    for key, model in models.items():
        normalized = normalized_model_key(key)
        try:
            effective_price_rates(model)
        except ServiceError:
            poisoned.add(normalized)
            if len(normalized) > 8 and normalized[-8:].isdigit():
                poisoned.add(normalized[:-8])
    family_target = target[:-8] if len(target) > 8 and target[-8:].isdigit() else ""
    if target in poisoned or (family_target and family_target in poisoned):
        return None
    def has_conflicting_rates(matches):
        if len(matches) <= 1:
            return False
        rates = set()
        for key in matches:
            try:
                rates.add(effective_price_rates(models[key]))
            except ServiceError:
                return True
        return len(rates) > 1
    normalized_matches = [key for key in models if normalized_model_key(key) == target]
    if has_conflicting_rates(normalized_matches):
        return None
    if family_target and has_conflicting_rates([key for key in models if normalized_model_key(key) == family_target]):
        return None
    if not target:
        return None
    matches = normalized_matches
    if not matches and len(target) > 8 and target[-8:].isdigit():
        family = target[:-8]
        matches = [key for key in models if normalized_model_key(key) == family]
    if len(matches) > 1:
        rates = set()
        for key in matches:
            try:
                rates.add(effective_price_rates(models[key]))
            except ServiceError:
                return None
        if len(rates) == 1:
            return sorted(matches, key=_ordinal_sort_key)[0]
    return matches[0] if len(matches) == 1 else None


def price_row(row, book):
    if row.get("ambiguous_model"):
        raise ServiceError(503, "usd_unpriced", "A deployment served multiple model versions in this period")
    deployment = row.get("deployment") or row.get("model")
    key = price_book_key(deployment, book)
    model = book.get("models", {}).get(key)
    if not isinstance(model, dict):
        raise ServiceError(503, "usd_unpriced", "Deployment has no explicit price-book entry")
    with localcontext() as ctx:
        ctx.prec = 50
        base, output, cache_read, cache_write_5m, cache_write_1h = effective_price_rates(model)
        rates = {"prompt": base, "completion": output,
                 "cache_read": cache_read,
                 "cache_write_5m": cache_write_5m,
                 "cache_write_1h": cache_write_1h}
        geo = row.get("inference_geo", "unknown")
        geography_known = geo in ("global", "us")
        multiplier = Decimal("1.1") if geo == "us" else Decimal(1)
        categories = {key + "_usd": quantity(row.get(key + "_tokens")) * value * multiplier / 1000000
                      for key, value in rates.items()}
        read_known = row.get("cache_read_known") is True
        write_known = row.get("cache_write_known") is True
        return {"known_usd": money(sum(categories.values())),
                "categories": {k: money(v) for k, v in categories.items()},
                "cache_read_known": read_known, "cache_write_known": write_known,
                "inference_geo_known": geography_known,
                "exact": read_known and write_known and geography_known and row.get("usage_source") == "body"}


def bounds(now, period):
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == "day":
        return start, start + timedelta(days=1)
    start = start.replace(day=1)
    end = start.replace(year=start.year + 1, month=1) if start.month == 12 else start.replace(month=start.month + 1)
    return start, end


def calculate_state(values, rows, now, freshness_seconds=900):
    check_authority(values)
    doc = parse_budgets(values.get("usd-budgets"))
    if not doc or not doc["items"]:
        return {}
    if now.tzinfo is None or not 60 <= freshness_seconds <= 3600:
        raise invalid("Reconciliation requires UTC time and a bounded freshness interval")
    now = now.astimezone(UTC)
    config = Config(values)
    state = {"schema_version": 1, "source_revision": source_revision(values),
             "policy_revision": hashlib.sha256("\n".join(values.get(k, "") for k in USD_NAMES[:-1]).encode("utf-8")).hexdigest(),
             "reconciled_at": timestamp(now), "valid_until": timestamp(now + timedelta(seconds=freshness_seconds)),
             "items": {}}
    userless_rows = set()
    userless_totals = {key: Decimal(0) for key in (
        "prompt_tokens", "completion_tokens", "cache_read_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens")}
    unit_unknown_rows = set()
    unit_unknown_totals = {key: Decimal(0) for key in (
        "prompt_tokens", "completion_tokens", "cache_read_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens")}
    for key, budget in doc["items"].items():
        kind, target = key.split(":", 1)
        config.require_target(kind, target)
        start, end = bounds(now, budget["period"])
        spent, exact, read_known, write_known = Decimal(0), True, True, True
        problems = set()
        for row in rows:
            try:
                raw_day = row.get("day")
                if not isinstance(raw_day, str):
                    raise ValueError()
                observed = datetime.fromisoformat(raw_day.replace("Z", "+00:00"))
                if observed.tzinfo is None:
                    raise ValueError()
            except (KeyError, TypeError, ValueError) as error:
                raise ServiceError(503, "usd_invalid_usage", "Ledger rows need an explicit UTC day") from error
            if not start <= observed < min(end, now + timedelta(microseconds=1)):
                continue
            row_id = id(row)
            user = row.get("user_id")
            if not user:
                if row_id not in userless_rows:
                    userless_rows.add(row_id)
                    for total_key in userless_totals:
                        userless_totals[total_key] += quantity(row.get(total_key))
                continue
            stamped = row.get("business_unit") or "unassigned"
            leaf = (stamped if config.values.get("entitlement-source") == "projection"
                    else config.members.get(user, stamped))
            if kind == "user":
                matches = user == target
            else:
                if (row.get("unit_unknown") is True
                        and (config.values.get("entitlement-source") == "projection" or user not in config.members)):
                    if row_id not in unit_unknown_rows:
                        unit_unknown_rows.add(row_id)
                        for total_key in unit_unknown_totals:
                            unit_unknown_totals[total_key] += quantity(row.get(total_key))
                    continue
                matches = target == leaf or target == config.parents.get(leaf)
            if not matches:
                continue
            try:
                priced = price_row(row, doc["price_book"])
                with localcontext() as ctx:
                    ctx.prec = 50
                    spent += Decimal(priced["known_usd"])
                exact = exact and priced["exact"]
                read_known = read_known and priced["cache_read_known"]
                write_known = write_known and priced["cache_write_known"]
            except ServiceError:
                problems.add(str(row.get("deployment") or row.get("model") or "unknown"))
        mode = config.mode(target) if kind != "user" else {"enforcement": "strict"}
        enforcement = mode["enforcement"]
        nominal = dollars(budget["amount_usd"])
        effective = nominal * (1 + Decimal(mode.get("allowance_percent", 0)) / 100)
        if enforcement == "notify":
            status = "notice"
        elif problems:
            status = "unpriced"
        elif (spent > effective if enforcement == "allowance" else spent >= effective):
            status = "stop"
        elif spent >= nominal or not exact:
            status = "notice"
        else:
            status = "allow"
        state["items"][key] = {
            "scope_type": kind, "scope_id": target, "period": budget["period"],
            "period_start": timestamp(start), "period_end": timestamp(end),
            "budget_usd": budget["amount_usd"], "effective_budget_usd": money(effective),
            "spent_usd": None if problems else money(spent), "status": status,
            "enforcement": enforcement, "price_book_date": budget["price_book_date"],
            "exact": exact and not problems, "cache_read_known": read_known and not problems,
            "cache_write_known": write_known and not problems, "unpriced_models": sorted(problems),
        }
    if userless_rows:
        state["userless_usage"] = {"rows": len(userless_rows), **{
            key: money(value) for key, value in userless_totals.items()
        }}
    if unit_unknown_rows:
        state["unit_unknown_usage"] = {"rows": len(unit_unknown_rows), **{
            key: money(value) for key, value in unit_unknown_totals.items()
        }}
    encode_state(state)
    return state
