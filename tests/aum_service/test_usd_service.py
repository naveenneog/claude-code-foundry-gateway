from copy import deepcopy
import json
import unittest
from unittest.mock import Mock

from aum_service.api import Api
from aum_service.errors import ServiceError
from aum_service.service import AumService
from aum_service.usd_budgets import decode_document, encode_document
from aum_service.usd_service import UsdBudgets
from aum_service.usd_reconcile import reconcile, usage_query
from fakes import FakeArm, FakeStore, FakeAnalytics, Clock
from test_identity import UNIT_GROUP, TEAM_GROUP, PERSON
from test_usd_budgets import BOOK, configured, document, row, NOW
from test_writes import actor


class UsdServiceTests(unittest.TestCase):
    def setUp(self):
        doc = document()
        doc["items"]["user:" + PERSON]["period"] = "month"
        initial = {**configured(doc), "turnstile-integration": ""}
        self.arm, self.store, self.logs, self.clock = FakeArm(initial), FakeStore(), FakeAnalytics(), Clock()
        self.clock.now = NOW
        self.arm.base = ("https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000"
                         "/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test")
        self.service = AumService(self.arm, self.store, self.logs, self.clock)
        self.usd = UsdBudgets(self.service)
        self.admin = actor()
        self.store.put("managers", "finance", {"manager_group_id": UNIT_GROUP})
        self.store.put("managers", "payroll", {"manager_group_id": TEAM_GROUP})
        self.logs.usage_rows = [row()]

    def revision(self):
        return self.service.budgets(self.admin)["revision"]

    def write(self, who=None, kind="department", key="payroll", amount="0.026"):
        return self.usd.set_budget(who or self.admin, kind, key,
                                   {"reason": "USD allocation", "amount_usd": amount, "period": "month",
                                    "price_book_date": BOOK["date"]}, self.revision())

    def test_scoped_reads_and_no_outside_scope_in_mutation_response(self):
        manager = actor("Manager", groups=[UNIT_GROUP])
        result = self.write(manager)
        self.assertEqual("0.026", result["result"]["amount_usd"])
        self.assertNotIn("usd-budgets", str(result))
        self.assertNotIn("organization:finance", str(result))
        team = actor("Manager", groups=[TEAM_GROUP])
        visible = self.usd.read(team)
        self.assertTrue(visible["items"])
        self.assertNotIn("finance", str(visible["items"]))
        self.assertEqual([], self.usd.read(actor("Manager"))["items"])

    def test_manager_and_viewer_boundaries_reuse_existing_scope(self):
        for who, kind, target in ((actor("Viewer"), "department", "payroll"),
                                  (actor("Manager", groups=[TEAM_GROUP]), "department", "payroll"),
                                  (actor("Manager", groups=[UNIT_GROUP]), "organization", "finance"),
                                  (actor("Manager"), "user", PERSON)):
            with self.subTest(kind=kind), self.assertRaises(ServiceError) as error:
                self.write(who, kind, target)
            self.assertEqual(403, error.exception.status)
        self.assertEqual([], self.arm.writes)

    def test_usd_changes_invalidate_revision_but_timer_state_does_not(self):
        before = self.revision()
        self.write()
        self.assertNotEqual(before, self.revision())
        after = self.revision()
        reconcile(self.service)
        self.assertEqual(after, self.revision())

    def test_authority_is_checked_before_query_and_every_write(self):
        self.arm.values["turnstile-integration"] = "governanceAuthority=Turnstile"
        for work in (self.write, lambda: reconcile(self.service)):
            with self.assertRaises(ServiceError) as error:
                work()
            self.assertEqual("other_authority", error.exception.code)
        self.assertEqual([], self.logs.queries)
        self.assertEqual([], self.arm.writes)

    def test_reconcile_stop_repeat_noop_raise_and_lift(self):
        first = reconcile(self.service)
        self.assertEqual("stop", first["items"]["department:payroll"]["status"])
        writes = len(self.arm.writes)
        reconcile(self.service)
        self.assertEqual(writes, len(self.arm.writes))
        self.write(kind="organization", key="finance", amount="10")
        self.write(amount="1")
        fresh = reconcile(self.service)
        self.assertEqual("allow", fresh["items"]["department:payroll"]["status"])
        self.assertEqual("succeeded", self.store.audits[-1]["outcome"])

    def test_budget_raise_above_dollar_parent_is_refused(self):
        with self.assertRaises(ServiceError) as error:
            self.write(amount="100")
        self.assertEqual("insufficient_headroom", error.exception.code)
        self.assertEqual([], self.arm.writes)

    def test_clearing_team_allocation_does_not_hide_person_reservations(self):
        self.usd.set_budget(self.admin, "department", "payroll", {"reason": "Clear team dollars"},
                            self.revision(), clear=True)
        with self.assertRaises(ServiceError) as error:
            self.write(kind="user", key=PERSON, amount="100")
        self.assertEqual("insufficient_headroom", error.exception.code)

    def test_capabilities_expose_usd_installation_and_authorized_actions(self):
        admin = self.service.capabilities(self.admin)["capabilities"]
        self.assertTrue(admin.get("usd_budgets_read"))
        self.assertTrue(admin.get("usd_budget_write"))
        self.assertTrue(admin.get("usd_budget_reconcile"))
        manager = self.service.capabilities(actor("Manager", groups=[TEAM_GROUP]))["capabilities"]
        self.assertTrue(manager.get("usd_budget_write"))
        self.assertFalse(manager.get("usd_budget_reconcile"))
        viewer = self.service.capabilities(actor("Viewer"))["capabilities"]
        self.assertFalse(viewer.get("usd_budget_write"))

    def test_audit_failure_and_analytics_failure_never_lift_existing_state(self):
        reconcile(self.service)
        before = self.arm.values["usd-budget-state"]
        self.logs.query = Mock(side_effect=RuntimeError("query outage"))
        with self.assertRaises(RuntimeError):
            reconcile(self.service)
        self.assertEqual(before, self.arm.values["usd-budget-state"])
        self.store.fail_audit = True
        with self.assertRaises(RuntimeError):
            self.write()
        self.assertEqual(before, self.arm.values["usd-budget-state"])

    def test_configuration_or_authority_change_during_query_never_writes(self):
        def change(_):
            self.arm.values["turnstile-integration"] = "budgetAuthority=Turnstile"
            return [row()]
        self.logs.query = change
        with self.assertRaises(ServiceError):
            reconcile(self.service)
        self.assertEqual([], self.arm.writes)

    def test_missing_installed_state_refuses_rather_than_unconditional_create(self):
        del self.arm.values["usd-budget-state"]
        with self.assertRaises(ServiceError):
            reconcile(self.service)
        self.assertEqual([], self.arm.writes)

    def test_status_is_scoped_and_reports_staleness(self):
        reconcile(self.service)
        result = self.usd.status(actor("Manager", groups=[TEAM_GROUP]))
        self.assertTrue(result["fresh"])
        self.assertNotIn("organization:finance", str(result))
        self.write()
        self.assertFalse(self.usd.status(self.admin)["fresh"])

    def test_additive_http_routes_and_manual_reconcile_admin_only(self):
        verifier = Mock()
        verifier.verify.return_value = self.admin
        api = Api(self.service, verifier)
        for path in ("usd-budgets", "usd-budget-status", "usd-price-book"):
            code, body, _ = api.handle("GET", "/api/v1/" + path, {}, b"", {"Authorization": "Bearer test"})
            self.assertEqual(200, code, body)
        verifier.verify.return_value = actor("Manager", groups=[UNIT_GROUP])
        code, _, _ = api.handle("POST", "/api/v1/usd-budget-reconcile", {}, b"{}", {"Authorization": "Bearer test"})
        self.assertEqual(403, code)

    def test_query_keeps_counts_separate_filters_gateway_and_detects_overflow(self):
        query = usage_query(self.arm.base, NOW)
        for fragment in ("ClaudeChargeback(", "Prompt Cached Tokens", 'Properties["Service ID"]',
                         "apim-test", "cache_write_5m_tokens", "cache_write_1h_tokens",
                         "cache_read_known", "take 1001", "gateway_id"):
            self.assertIn(fragment, query)
        self.assertNotIn("sum(usd)", query)
        self.assertNotIn("sum(total_tokens)", query)


if __name__ == "__main__":
    unittest.main()
