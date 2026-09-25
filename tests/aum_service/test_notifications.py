import unittest
from unittest.mock import Mock

from aum_service.notifications import record_warnings
from aum_service.service import AumService
from fakes import FakeArm, FakeStore, FakeAnalytics, Clock
from test_identity import PERSON


class NotificationTests(unittest.TestCase):
    def test_warning_is_recorded_once_per_period_scope_and_threshold(self):
        arm, store, logs, clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        service = AumService(arm, store, logs, clock)
        logs.usage_rows = [{"business_unit": "payroll", "user_id": "", "tokens": 2500000}]
        record_warnings(service)
        record_warnings(service)
        rows, _ = store.list("notifications")
        self.assertEqual(1, len(rows))
        self.assertEqual("budget.warning", rows[0]["kind"])
        self.assertEqual("payroll", rows[0]["scope_id"])
        self.assertEqual(1, rows[0]["schema_version"])
        self.assertEqual("tokens", rows[0]["usage_unit"])
        self.assertEqual("prompt_completion_only", rows[0]["usage_basis"])
        self.assertEqual("ClaudeCost", rows[0]["source"])
        self.assertEqual("2026-09-01T00:00:00.000000Z", rows[0]["period_start_utc"])
        self.assertEqual("2026-10-01T00:00:00.000000Z", rows[0]["period_end_utc"])
        self.assertNotIn("delivery_status", rows[0])
        self.assertNotIn("recipients", rows[0])
        self.assertEqual(80, rows[0]["threshold_percent"])
        self.assertEqual("succeeded", store.audits[-1]["outcome"])

    def test_below_threshold_and_unlimited_budgets_emit_nothing(self):
        arm, store, logs, clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        logs.usage_rows = [{"business_unit": "payroll", "user_id": "", "tokens": 100}]
        record_warnings(AumService(arm, store, logs, clock))
        self.assertEqual([], store.list("notifications")[0])

    def test_person_warning_uses_daily_usage_and_daily_deduplication(self):
        arm, store, logs, clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        logs.query = Mock(side_effect=[[], [{"user_id": PERSON, "tokens": 900}]])
        record_warnings(AumService(arm, store, logs, clock))
        rows, _ = store.list("notifications")
        self.assertEqual(1, len(rows))
        self.assertEqual("user", rows[0]["scope_type"])
        self.assertEqual("2026-09-24", rows[0]["period"])
        self.assertIn("ClaudeChargeback(", logs.query.call_args.args[0])
        self.assertIn(PERSON, logs.query.call_args.args[0])

    def test_changed_limit_rearms_but_restoring_identical_limit_does_not(self):
        arm, store, logs, clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        service = AumService(arm, store, logs, clock)
        logs.usage_rows = [{"business_unit": "payroll", "user_id": "", "tokens": 2500000}]
        record_warnings(service)
        arm.values["bu-registry"] = arm.values["bu-registry"].replace("Payroll:3000000", "Payroll:3100000")
        record_warnings(service)
        records, _ = store.list("notifications")
        self.assertEqual(2, len(records))
        self.assertEqual(2, len({row["effective_limit_version"] for row in records}))
        arm.values["bu-registry"] = arm.values["bu-registry"].replace("Payroll:3100000", "Payroll:3000000")
        record_warnings(service)
        self.assertEqual(2, len(store.list("notifications")[0]))

    def test_usage_is_recorded_as_exact_decimal_text_and_daily_bounds_are_exclusive(self):
        arm, store, logs, clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        quantity = "900.123456789012345678"
        logs.query = Mock(side_effect=[[], [{"user_id": PERSON, "tokens": quantity}]])
        record_warnings(AumService(arm, store, logs, clock))
        fact = store.list("notifications")[0][0]
        self.assertEqual(quantity, fact["observed_usage"])
        self.assertEqual("2026-09-24T00:00:00.000000Z", fact["period_start_utc"])
        self.assertEqual("2026-09-25T00:00:00.000000Z", fact["period_end_utc"])
        self.assertEqual("ClaudeChargeback", fact["source"])


if __name__ == "__main__":
    unittest.main()
