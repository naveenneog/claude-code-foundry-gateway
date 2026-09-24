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
        self.assertEqual("pending", rows[0]["delivery_status"])
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


if __name__ == "__main__":
    unittest.main()
