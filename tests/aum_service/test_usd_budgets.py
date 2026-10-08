import base64
from copy import deepcopy
from datetime import UTC, datetime
from decimal import Decimal
import json
from pathlib import Path
import unittest

from aum_service.errors import ServiceError
from aum_service.usd_budgets import (
    calculate_state, check_authority, decode_document, encode_document,
    parse_budgets, price_book_key, price_row, source_revision,
)
from test_registry import values
from test_identity import PERSON


NOW = datetime(2026, 9, 25, 12, tzinfo=UTC)
BOOK = {"date": "2026-09-16", "models": {
    "claude-sonnet-5": {"inputPerM": "2", "outputPerM": "10"},
}}


def document():
    return {"schema_version": 1, "price_book": deepcopy(BOOK), "items": {
        "organization:finance": {"amount_usd": "0.03", "period": "month", "price_book_date": BOOK["date"]},
        "department:payroll": {"amount_usd": "0.025", "period": "month", "price_book_date": BOOK["date"]},
        "user:" + PERSON: {"amount_usd": "0.025", "period": "day", "price_book_date": BOOK["date"]},
    }}


def row(**updates):
    return {"day": "2026-09-25T00:00:00Z", "user_id": PERSON, "business_unit": "payroll",
            "model": "claude-sonnet-5", "deployment": "claude-sonnet-5",
            "prompt_tokens": 10, "completion_tokens": 100, "cache_read_tokens": 10000,
            "cache_write_5m_tokens": 10000, "cache_write_1h_tokens": 0,
            "cache_read_known": True, "cache_write_known": True,
            "inference_geo": "global", "usage_source": "body", **updates}


def configured(doc=None):
    config = values()
    config["usd-budgets"] = encode_document(doc or document())
    config["usd-budget-state"] = encode_document({})
    return config


class DollarArithmeticTests(unittest.TestCase):
    def test_model_price_matching_uses_one_normalized_dated_rule(self):
        book = json.loads(Path(__file__).parents[2].joinpath("config", "price-book.example.json").read_text())
        cases = {
            "claude-fable-5": "claude-fable-5",
            "claude-fable-5-1": "claude-fable-5-1",
            "claude_haiku_4_5": "claude-haiku-4.5",
            "claude-haiku-4-5": "claude-haiku-4.5",
            "claude-haiku-4-5-2025-10-01": "claude-haiku-4.5",
            "claude-haiku-4-5-20251001": "claude-haiku-4.5",
            "claude-haiku-5-5": None,
            "claude-opus-4-1": "claude-opus-4-1",
            "claude-opus-4-5": "claude-opus-4-5",
            "claude-opus-4-6": "claude-opus-4-6",
            "claude-opus-4-7": "claude-opus-4-7",
            "claude-opus-4-8": "claude-opus-4.8",
            "claude-opus-4-8-2026-01-01": "claude-opus-4.8",
            "claude-opus-5-5": "claude-opus-5-5",
            "claude-sonnet-4-5": "claude-sonnet-4-5",
            "claude-sonnet-4-6": "claude-sonnet-4-6",
            "CLAUDE SONNET 5": "claude-sonnet-5",
            "Claude-Sonnet-5": "claude-sonnet-5",
            "claude-sonnet-5-5": "claude-sonnet-5-5",
            "claude-sonnet-5-2": None,
            "claude-sonnet-5-123456": None,
            "gpt-5": None,
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(expected, price_book_key(name, book))
        without_opus_55 = deepcopy(book)
        del without_opus_55["models"]["claude-opus-5-5"]
        self.assertIsNone(price_book_key("claude-opus-5-5", without_opus_55))
        without_fable_51 = deepcopy(book)
        del without_fable_51["models"]["claude-fable-5-1"]
        self.assertIsNone(price_book_key("claude-fable-5-1", without_fable_51))
        without_sonnet_55 = deepcopy(book)
        del without_sonnet_55["models"]["claude-sonnet-5-5"]
        self.assertIsNone(price_book_key("claude-sonnet-5-5", without_sonnet_55))
        duplicate = deepcopy(book)
        duplicate["models"]["claude-haiku-4-5"] = {"inputPerM": 1, "outputPerM": 5}
        self.assertEqual("claude-haiku-4-5", price_book_key("claude-haiku-4-5", duplicate))
        self.assertEqual("claude-haiku-4-5", price_book_key("claude_haiku_4_5", duplicate))
        scaled_equal = {"models": {
            "scaled.model": {"inputPerM": "0.8", "outputPerM": "4"},
            "scaled-model": {"inputPerM": "0.8", "outputPerM": "4", "cacheWrite5mPerM": "1.000"},
        }}
        self.assertEqual("scaled-model", price_book_key("scaled-model", scaled_equal))
        conflict = deepcopy(book)
        conflict["models"]["claude-haiku-4-5"] = {"inputPerM": 2, "outputPerM": 5}
        self.assertIsNone(price_book_key("claude-haiku-4-5-20251001", conflict))
        cache_conflict = {"models": {
            "claude-haiku-4.5": {"inputPerM": 1, "outputPerM": 5},
            "claude-haiku-4-5": {"inputPerM": 1, "outputPerM": 5, "cacheReadPerM": "0.05"},
        }}
        self.assertIsNone(price_book_key("claude-haiku-4-5-20251001", cache_conflict))
        rate_conflicts = {
            "inputPerM": ({"inputPerM": 1, "outputPerM": 5}, {"inputPerM": 2, "outputPerM": 5}),
            "outputPerM": ({"inputPerM": 1, "outputPerM": 5}, {"inputPerM": 1, "outputPerM": 6}),
            "cacheReadPerM": ({"inputPerM": 1, "outputPerM": 5}, {"inputPerM": 1, "outputPerM": 5, "cacheReadPerM": "0.05"}),
            "cacheWrite5mPerM": ({"inputPerM": 1, "outputPerM": 5}, {"inputPerM": 1, "outputPerM": 5, "cacheWrite5mPerM": "2"}),
            "cacheWrite1hPerM": ({"inputPerM": 1, "outputPerM": 5}, {"inputPerM": 1, "outputPerM": 5, "cacheWrite1hPerM": "3"}),
        }
        for field, (left, right) in rate_conflicts.items():
            with self.subTest(rate=field):
                self.assertIsNone(price_book_key("rate-family-20260101", {"models": {
                    "rate.family": left,
                    "rate-family": right,
                }}))
        invalid_family = {"models": {
            "claude-opus-5-5": {"inputPerM": 5, "outputPerM": 25, "cacheReadPerM": None},
            "claude-opus-5.5": {"inputPerM": 1, "outputPerM": 5},
        }}
        self.assertIsNone(price_book_key("claude-opus-5.5", invalid_family))
        invalid_dated = {"models": {
            "claude-sonnet-5-5-20260101": {"inputPerM": 2, "outputPerM": 10, "cacheReadPerM": None},
            "claude-sonnet-5.5": {"inputPerM": 1, "outputPerM": 5},
        }}
        self.assertIsNone(price_book_key("claude-sonnet-5-5-20260101", invalid_dated))
        invalid_required = {"models": {
            "required-negative": {"inputPerM": -5, "outputPerM": 25},
            "required-boolean": {"inputPerM": True, "outputPerM": 25},
        }}
        self.assertIsNone(price_book_key("required-negative", invalid_required))
        self.assertIsNone(price_book_key("required-boolean", invalid_required))

    def test_all_five_categories_are_priced_before_sum_without_rounding(self):
        result = price_row(row(cache_write_1h_tokens=1000), BOOK)
        self.assertEqual("0.03202", result["known_usd"])
        self.assertTrue(result["exact"])
        self.assertEqual("0.002", result["categories"]["cache_read_usd"])
        self.assertEqual("0.025", result["categories"]["cache_write_5m_usd"])

    def test_explicit_cache_rates_are_honored(self):
        book = deepcopy(BOOK)
        book["models"]["claude-sonnet-5"].update(
            cacheReadPerM="0.3", cacheWrite5mPerM="3", cacheWrite1hPerM="5")
        self.assertEqual("0.03402", price_row(row(), book)["known_usd"])

    def test_fractional_microdollars_are_not_rounded_per_request(self):
        tiny = row(prompt_tokens=0, completion_tokens=0, cache_read_tokens=1, cache_write_5m_tokens=0)
        self.assertEqual(Decimal("0.000002"), sum(
            Decimal(price_row(tiny, BOOK)["known_usd"]) for _ in range(10)))

    def test_unknown_price_and_explicit_null_rate_never_become_zero(self):
        for field, value in (("model", "unknown-model"), ("prompt_tokens", -1),
                             ("completion_tokens", "NaN"), ("cache_read_tokens", None)):
            with self.subTest(field=field), self.assertRaises(ServiceError):
                price_row(row(**{field: value, **({"deployment": value} if field == "model" else {})}), BOOK)
        book = deepcopy(BOOK)
        book["models"]["claude-sonnet-5"]["cacheReadPerM"] = None
        with self.assertRaises(ServiceError):
            price_row(row(), book)

    def test_unknown_stream_cache_write_is_not_claimed_complete(self):
        result = price_row(row(cache_write_known=False, cache_write_5m_tokens=0,
                               usage_source="log+metric"), BOOK)
        self.assertFalse(result["exact"])
        self.assertFalse(result["cache_write_known"])
        self.assertEqual("0.00302", result["known_usd"])

    def test_unknown_cache_read_and_geography_are_visible(self):
        result = price_row(row(cache_read_known=False, cache_read_tokens=0,
                               inference_geo="unknown"), BOOK)
        self.assertFalse(result["exact"])
        self.assertFalse(result["cache_read_known"])
        self.assertFalse(result["inference_geo_known"])

    def test_us_data_zone_multiplier_is_separate_from_categories(self):
        self.assertEqual("0.030822", price_row(row(inference_geo="us"), BOOK)["known_usd"])

    def test_deployment_price_wins_over_requested_alias(self):
        self.assertEqual("0.02802", price_row(row(model="client-alias"), BOOK)["known_usd"])

    def test_dated_deployment_uses_price_book_family_without_prefix_shortening(self):
        book = deepcopy(BOOK)
        book["models"]["claude-opus-5"] = {"inputPerM": "5", "outputPerM": "25"}
        self.assertEqual("0.02802", price_row(row(deployment="claude-sonnet-5-20251001"), book)["known_usd"])
        with self.assertRaises(ServiceError):
            price_row(row(model="claude-opus-5-5", deployment="claude-opus-5-5"), book)


class DollarDocumentTests(unittest.TestCase):
    def test_round_trip_preserves_decimal_text_and_price_book_date(self):
        doc = document()
        doc["items"]["organization:finance"]["amount_usd"] = "19.000000001"
        self.assertEqual(doc, parse_budgets(encode_document(doc)))

    def test_missing_is_disabled_but_malformed_is_not_disabled(self):
        self.assertEqual({}, parse_budgets(None))
        self.assertEqual({}, parse_budgets("e30="))
        for raw in ("oops", base64.b64encode(b'[]').decode(),
                    base64.b64encode(b'{"schema_version":2}').decode()):
            with self.subTest(raw=raw), self.assertRaises(ServiceError):
                parse_budgets(raw)

    def test_price_book_duplicate_normalized_keys_are_rejected(self):
        doc = document()
        doc["price_book"]["models"]["claude_sonnet_5"] = {"inputPerM": "2", "outputPerM": "10"}
        self.assertEqual(doc, parse_budgets(encode_document(doc)))

    def test_existing_price_book_conflicts_are_scope_local_unpriced_not_global(self):
        doc = document()
        doc["price_book"]["models"]["claude_sonnet_5"] = {"inputPerM": "3", "outputPerM": "10"}
        state = calculate_state(configured(doc), [row(deployment="claude-sonnet-5", model="claude-sonnet-5")], NOW)
        self.assertEqual("unpriced", state["items"]["department:payroll"]["status"])
        self.assertEqual(["claude-sonnet-5"], state["items"]["department:payroll"]["unpriced_models"])

    def test_existing_price_book_invalid_model_entry_is_scope_local_unpriced(self):
        doc = document()
        doc["price_book"]["models"]["broken-model"] = {"inputPerM": "2"}
        state = calculate_state(configured(doc), [row(deployment="broken-model", model="broken-model")], NOW)
        self.assertEqual("unpriced", state["items"]["department:payroll"]["status"])
        self.assertEqual(["broken-model"], state["items"]["department:payroll"]["unpriced_models"])

    def test_capacity_overflow_and_duplicate_keys_are_rejected(self):
        with self.assertRaises(ServiceError):
            encode_document({"oversized": "x" * 5000})
        with self.assertRaises(ServiceError):
            decode_document(base64.b64encode(b'{"x":1,"x":2}').decode())

    def test_invalid_money_period_scope_and_price_date_are_rejected(self):
        for field, value in (("amount_usd", -1), ("amount_usd", "NaN"), ("amount_usd", 1.25),
                             ("period", "week"), ("price_book_date", "yesterday")):
            doc = document()
            doc["items"]["organization:finance"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ServiceError):
                parse_budgets(encode_document(doc))
        doc = document()
        doc["items"]["organization:finance"]["period"] = "day"
        with self.assertRaises(ServiceError):
            parse_budgets(encode_document(doc))

    def test_fingerprint_ignores_state_but_covers_governance(self):
        config = configured()
        before = source_revision(config)
        config["usd-budget-state"] = "changed"
        self.assertEqual(before, source_revision(config))
        for key in ("usd-budgets", "bu-members", "bu-parents", "bu-modes",
                    "entitlement-source", "turnstile-integration"):
            with self.subTest(key=key):
                changed = {**config, key: config.get(key, "") + "changed"}
                self.assertNotEqual(before, source_revision(changed))

    def test_authority_is_checked_for_both_budget_and_governance_owner(self):
        for key in ("budgetAuthority", "governanceAuthority"):
            with self.subTest(key=key), self.assertRaises(ServiceError) as error:
                check_authority({"turnstile-integration": f"version=1;{key}=Turnstile;connectedAt=now"})
            self.assertEqual("other_authority", error.exception.code)
        check_authority({"turnstile-integration": ""})


class DollarDecisionTests(unittest.TestCase):
    def test_unit_team_and_person_charge_same_spend_once_each(self):
        state = calculate_state(configured(), [row()], NOW)
        self.assertEqual("allow", state["items"]["organization:finance"]["status"])
        for scope in ("department:payroll", "user:" + PERSON):
            self.assertEqual("stop", state["items"][scope]["status"])
            self.assertEqual("0.02802", state["items"][scope]["spent_usd"])
            self.assertEqual("2026-09-25T12:00:00Z", state["reconciled_at"])

    def test_strict_stops_at_equality_allowance_only_above(self):
        doc = document()
        doc["items"]["department:payroll"]["amount_usd"] = "0.02802"
        state = calculate_state(configured(doc), [row()], NOW)
        self.assertEqual("stop", state["items"]["department:payroll"]["status"])
        config = configured(doc)
        config["bu-modes"] = ",payroll=allowance:10,"
        at = row(prompt_tokens=1411, completion_tokens=100, cache_read_tokens=10000,
                 cache_write_5m_tokens=10000)
        self.assertEqual("notice", calculate_state(config, [at], NOW)["items"]["department:payroll"]["status"])
        at["prompt_tokens"] += 1
        self.assertEqual("stop", calculate_state(config, [at], NOW)["items"]["department:payroll"]["status"])

    def test_notify_never_stops_even_for_unpriced_usage(self):
        config = configured()
        config["bu-modes"] = ",payroll=notify,"
        state = calculate_state(config, [row(model="unknown", deployment="unknown")], NOW)
        item = state["items"]["department:payroll"]
        self.assertEqual("notice", item["status"])
        self.assertIsNone(item["spent_usd"])
        self.assertIn("unknown", item["unpriced_models"])
        self.assertEqual("unpriced", state["items"]["organization:finance"]["status"])

    def test_raising_budget_and_utc_rollover_lift_stop(self):
        config = configured()
        state = calculate_state(config, [row()], NOW)
        self.assertEqual("stop", state["items"]["department:payroll"]["status"])
        doc = document()
        doc["items"]["department:payroll"]["amount_usd"] = "1"
        self.assertEqual("allow", calculate_state(configured(doc), [row()], NOW)["items"]["department:payroll"]["status"])
        next_month = datetime(2026, 10, 1, tzinfo=UTC)
        fresh = calculate_state(config, [row()], next_month)
        self.assertEqual("0", fresh["items"]["department:payroll"]["spent_usd"])
        self.assertEqual("allow", fresh["items"]["department:payroll"]["status"])

    def test_daily_user_does_not_charge_yesterday_but_monthly_unit_does(self):
        state = calculate_state(configured(), [row(day="2026-09-24T00:00:00Z")], NOW)
        self.assertEqual("0", state["items"]["user:" + PERSON]["spent_usd"])
        self.assertEqual("0.02802", state["items"]["department:payroll"]["spent_usd"])

    def test_projection_never_uses_the_obsolete_membership_map(self):
        config = configured()
        config["entitlement-source"] = "projection"
        config["bu-members"] = "," + PERSON + "=finance,"
        state = calculate_state(config, [row()], NOW)
        self.assertEqual("stop", state["items"]["department:payroll"]["status"])
        self.assertEqual("0.02802", state["items"]["department:payroll"]["spent_usd"])

    def test_named_value_gateway_uses_current_membership_before_stamp(self):
        config = configured()
        config["bu-members"] = "," + PERSON + "=finance,"
        state = calculate_state(config, [row(business_unit="payroll")], NOW)
        self.assertEqual("allow", state["items"]["organization:finance"]["status"])
        self.assertEqual("0.02802", state["items"]["organization:finance"]["spent_usd"])
        self.assertEqual("0", state["items"]["department:payroll"]["spent_usd"])

    def test_projection_charges_each_stamped_unit_when_user_moves_in_a_day(self):
        config = configured()
        config["entitlement-source"] = "projection"
        config["bu-registry"] = ",finance=Finance:1000,payroll=Payroll:1000,"
        config["bu-parents"] = ",payroll=finance,"
        state = calculate_state(config, [
            row(business_unit="finance", prompt_tokens=10, completion_tokens=0, cache_read_tokens=0,
                cache_write_5m_tokens=0),
            row(business_unit="payroll", prompt_tokens=10, completion_tokens=0, cache_read_tokens=0,
                cache_write_5m_tokens=0),
        ], NOW)
        self.assertEqual("0.00004", state["items"]["organization:finance"]["spent_usd"])
        self.assertEqual("0.00002", state["items"]["department:payroll"]["spent_usd"])
        self.assertEqual([], state["items"]["organization:finance"]["unpriced_models"])

    def test_rows_without_user_are_reported_but_not_charged_or_unpriced(self):
        state = calculate_state(configured(), [row(user_id="", business_unit="payroll")], NOW)
        self.assertEqual("allow", state["items"]["organization:finance"]["status"])
        self.assertEqual("0", state["items"]["organization:finance"]["spent_usd"])
        self.assertEqual([], state["items"]["organization:finance"]["unpriced_models"])
        self.assertEqual({"rows": 1, "prompt_tokens": "10", "completion_tokens": "100",
                          "cache_read_tokens": "10000", "cache_write_5m_tokens": "10000",
                          "cache_write_1h_tokens": "0"}, state["userless_usage"])

    def test_unpriced_models_are_limited_to_the_scope_owning_the_row(self):
        config = configured()
        config["entitlement-source"] = "projection"
        state = calculate_state(config, [row(business_unit="external", deployment="unknown", model="unknown")], NOW)
        self.assertEqual("allow", state["items"]["organization:finance"]["status"])
        self.assertEqual("0", state["items"]["organization:finance"]["spent_usd"])
        self.assertEqual([], state["items"]["organization:finance"]["unpriced_models"])
        owned = calculate_state(configured(), [row(deployment="unknown", model="unknown")], NOW)
        self.assertEqual(["unknown"], owned["items"]["department:payroll"]["unpriced_models"])

    def test_tiered_haiku_55_stays_unpriced_and_named(self):
        state = calculate_state(configured(), [row(deployment="claude-haiku-5-5", model="claude-haiku-5-5")], NOW)
        item = state["items"]["department:payroll"]
        self.assertEqual("unpriced", item["status"])
        self.assertIsNone(item["spent_usd"])
        self.assertEqual(["claude-haiku-5-5"], item["unpriced_models"])

    def test_unit_unknown_metric_row_uses_named_value_membership_for_units(self):
        state = calculate_state(configured(), [row(
            business_unit="", unit_unknown=True, deployment="claude-sonnet-5", model="claude-sonnet-5",
            prompt_tokens=0, completion_tokens=0, cache_read_tokens=1000,
            cache_write_5m_tokens=0, cache_write_1h_tokens=0,
        )], NOW)
        self.assertEqual("0.0002", state["items"]["organization:finance"]["spent_usd"])
        self.assertEqual("0.0002", state["items"]["department:payroll"]["spent_usd"])
        self.assertEqual("0.0002", state["items"]["user:" + PERSON]["spent_usd"])
        self.assertNotIn("unit_unknown_usage", state)

    def test_unit_unknown_metric_row_counts_only_for_person_and_is_reported_on_projection(self):
        config = configured()
        config["entitlement-source"] = "projection"
        state = calculate_state(config, [row(
            business_unit="", unit_unknown=True, deployment="claude-sonnet-5", model="claude-sonnet-5",
            prompt_tokens=0, completion_tokens=0, cache_read_tokens=1000,
            cache_write_5m_tokens=0, cache_write_1h_tokens=0,
        )], NOW)
        self.assertEqual("0", state["items"]["organization:finance"]["spent_usd"])
        self.assertEqual("0", state["items"]["department:payroll"]["spent_usd"])
        self.assertEqual("0.0002", state["items"]["user:" + PERSON]["spent_usd"])
        self.assertEqual({"rows": 1, "prompt_tokens": "0", "completion_tokens": "0",
                          "cache_read_tokens": "1000", "cache_write_5m_tokens": "0",
                          "cache_write_1h_tokens": "0"}, state["unit_unknown_usage"])

    def test_unattributed_zero_usage_failure_is_not_invented_spend(self):
        failed = row(user_id="", business_unit="", model="", deployment="", prompt_tokens=0,
                     completion_tokens=0, cache_read_tokens=0, cache_write_5m_tokens=0)
        state = calculate_state(configured(), [failed], NOW)
        self.assertEqual("allow", state["items"]["organization:finance"]["status"])
        self.assertEqual("0", state["items"]["organization:finance"]["spent_usd"])

    def test_missing_day_is_a_service_error_not_attribute_error(self):
        with self.assertRaises(ServiceError) as error:
            calculate_state(configured(), [row(day=None)], NOW)
        self.assertEqual("usd_invalid_usage", error.exception.code)

    def test_repeat_evaluation_is_idempotent_and_expiry_is_bounded(self):
        config = configured()
        state = calculate_state(config, [row()], NOW)
        self.assertEqual(state, calculate_state(config, [row()], NOW))
        self.assertEqual("2026-09-25T12:15:00Z", state["valid_until"])
        self.assertEqual(source_revision(config), state["source_revision"])
        self.assertNotIn("userless_usage", state)

    def test_twenty_unit_decisions_fit_the_existing_named_value_boundary(self):
        doc = document()
        sample = doc["items"]["organization:finance"]
        doc["items"] = {"organization:unit-" + str(i): deepcopy(sample) for i in range(20)}
        config = configured(doc)
        config["bu-registry"] = "," + ",".join(f"unit-{i}=Contoso Group {i}:1000" for i in range(20)) + ","
        config["bu-parents"], config["bu-members"], config["bu-modes"] = ",,", ",,", ",,"
        state = calculate_state(config, [], NOW)
        from aum_service.usd_budgets import encode_state, decode_state
        packed = encode_state(state)
        self.assertLessEqual(len(packed), 4096)
        self.assertEqual(state, decode_state(packed))


if __name__ == "__main__":
    unittest.main()
