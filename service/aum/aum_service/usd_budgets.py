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
        result = json.loads(base64.b64decode(raw, validate=True).decode("ascii"), object_pairs_hook=unique)
        if not isinstance(result, dict):
            raise ValueError("object required")
        return result
    except (ValueError, TypeError, UnicodeError, binascii.Error) as error:
        raise Conflict("USD configuration is not valid encoded JSON", "usd_invalid_configuration") from error


def encode_document(document):
    raw = json.dumps(document, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return checked_value(base64.b64encode(raw.encode("ascii")).decode("ascii"))


def dollars(value):
    if not isinstance(value, str) or not DECIMAL.fullmatch(value):
        raise invalid("USD amounts must be nonnegative decimal strings with at most 9 fractional digits")
    return Decimal(value)


def parse_budgets(raw):
    doc = decode_document(raw)
    if not doc:
        return {}
    if set(doc) != {"schema_version", "price_book", "items"} or doc["schema_version"] != 1:
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


def price_row(row, book):
    deployment = row.get("deployment") or row.get("model")
    model = book.get("models", {}).get(deployment)
    if not isinstance(model, dict):
        raise ServiceError(503, "usd_unpriced", "Deployment has no explicit price-book entry")
    with localcontext() as ctx:
        ctx.prec = 50
        base = rate(model.get("inputPerM"))
        rates = {"prompt": base, "completion": rate(model.get("outputPerM")),
                 "cache_read": rate(model.get("cacheReadPerM", base * Decimal("0.1"))),
                 "cache_write_5m": rate(model.get("cacheWrite5mPerM", base * Decimal("1.25"))),
                 "cache_write_1h": rate(model.get("cacheWrite1hPerM", base * Decimal("2")))}
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
             "reconciled_at": timestamp(now), "valid_until": timestamp(now + timedelta(seconds=freshness_seconds)),
             "items": {}}
    for key, budget in doc["items"].items():
        kind, target = key.split(":", 1)
        config.require_target(kind, target)
        start, end = bounds(now, budget["period"])
        spent, exact, read_known, write_known = Decimal(0), True, True, True
        problems = set()
        for row in rows:
            try:
                observed = datetime.fromisoformat(row["day"].replace("Z", "+00:00"))
                if observed.tzinfo is None:
                    raise ValueError()
            except (KeyError, TypeError, ValueError) as error:
                raise ServiceError(503, "usd_invalid_usage", "Ledger rows need an explicit UTC day") from error
            if not start <= observed < min(end, now + timedelta(microseconds=1)):
                continue
            user = row.get("user_id")
            leaf = config.members.get(user, row.get("business_unit"))
            if not user or not leaf:
                problems.add("unattributed-usage")
                continue
            if kind == "user":
                matches = user == target
            else:
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
    encode_document(state)
    return state
