import json
import unittest
from unittest.mock import Mock

from aum_service.api import Api
from aum_service.errors import AccessDenied
from aum_service.queries import QueryBuilder, decode_cursor, encode_cursor
from aum_service.service import AumService
from fakes import FakeArm, FakeStore, FakeAnalytics, Clock
from test_identity import UNIT_GROUP, TEAM_GROUP, PERSON
from test_writes import actor


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.arm, self.store, self.logs, self.clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        self.service = AumService(self.arm, self.store, self.logs, self.clock)
        self.store.put("managers", "finance", {"manager_group_id": UNIT_GROUP})
        self.store.put("managers", "payroll", {"manager_group_id": TEAM_GROUP})
        self.verifier = Mock()
        self.verifier.verify.return_value = actor()
        self.api = Api(self.service, self.verifier)

    def call(self, method, path, query=None, body=None, headers=None):
        return self.api.handle(method, "/api/v1" + path, query or {},
                               json.dumps(body).encode() if body is not None else b"",
                               {"authorization": "Bearer test", **(headers or {})})

    def test_me_capabilities_and_catalog_scope(self):
        status, me, _ = self.call("GET", "/me")
        self.assertEqual(200, status)
        self.assertIsNone(me["manager_scope"])
        self.verifier.verify.return_value = actor("Manager", groups=[TEAM_GROUP])
        _, me, _ = self.call("GET", "/me")
        self.assertEqual([], me["manager_scope"]["organizations"])
        self.assertEqual(["payroll"], [r["id"] for r in me["manager_scope"]["departments"]])
        _, capabilities, _ = self.call("GET", "/capabilities")
        self.assertTrue(capabilities["capabilities"]["manager_budget_write"])
        self.assertFalse(capabilities["capabilities"]["catalog_write"])
        self.verifier.verify.return_value = actor("Viewer")
        _, capabilities, _ = self.call("GET", "/capabilities")
        self.assertFalse(capabilities["capabilities"]["budget_write"])

    def test_capabilities_never_offer_a_second_writer_or_absent_gateway_modes(self):
        del self.arm.values["bu-modes"]
        self.assertFalse(self.call("GET", "/capabilities")[1]["capabilities"]["modes_write"])
        self.arm.values["turnstile-integration"] = "governanceAuthority=Turnstile"
        self.arm.etags["turnstile-integration"] = 1
        capabilities = self.call("GET", "/capabilities")[1]["capabilities"]
        for flag in ("budget_write", "catalog_write", "tiers_write", "modes_write", "boosts", "approvals"):
            self.assertFalse(capabilities[flag], flag)

    def test_auth_required_on_every_route_and_error_does_not_leak(self):
        for path in ("/me", "/capabilities", "/budgets", "/people", "/unknown"):
            with self.subTest(path=path):
                status, body, headers = self.api.handle("GET", "/api/v1" + path, {}, b"", {})
                self.assertEqual(401, status)
                self.assertEqual("no-store", headers["Cache-Control"])
        self.verifier.verify.side_effect = AccessDenied("Expired", status=401)
        self.assertEqual(401, self.call("GET", "/me")[0])
        self.verifier.verify.side_effect = RuntimeError("sensitive-internal-value")
        status, body, _ = self.call("GET", "/me")
        self.assertEqual(503, status)
        self.assertNotIn("sensitive-internal-value", str(body))

    def test_usage_and_requests_are_filtered_before_aggregation_and_paging(self):
        self.verifier.verify.return_value = actor("Manager", groups=[TEAM_GROUP])
        self.logs.usage_rows = [{"requests": 1, "prompt_tokens": 2, "completion_tokens": 3, "usd": 0.01}]
        self.assertEqual(200, self.call("GET", "/usage")[0])
        query = self.logs.queries[-1]
        self.assertIn("ClaudeCost(", query)
        self.assertIn('"payroll"', query)
        self.assertNotIn('"finance"', query)
        self.assertLess(query.index("| where"), query.index("| summarize"))
        self.assertEqual(200, self.call("GET", "/requests")[0])
        self.assertIn("ClaudeChargeback(", self.logs.queries[-1])
        self.assertIn("| take 101", self.logs.queries[-1])

    def test_outside_scope_filters_fail_instead_of_returning_zero(self):
        self.verifier.verify.return_value = actor("Manager", groups=[TEAM_GROUP])
        for path, filters in (("/usage", {"organization_id": "finance"}),
                              ("/people", {"department_id": "audit"}),
                              ("/requests", {"user_id": "00000000-0000-0000-0000-000000000004"})):
            with self.subTest(path=path):
                self.assertEqual(403, self.call("GET", path, filters)[0])
        self.assertEqual([], self.logs.queries)

    def test_empty_manager_scope_is_not_unfiltered_query(self):
        self.verifier.verify.return_value = actor("Manager")
        self.call("GET", "/usage")
        self.assertIn("| where false", self.logs.queries[-1])
        _, budgets, _ = self.call("GET", "/budgets")
        self.assertEqual([], budgets["items"])

    def test_people_paging_is_bounded_even_for_half_million_developers(self):
        self.logs.usage_rows = [{"id": f"{n:08}-0000-0000-0000-000000000000", "name": f"person{n}"}
                               for n in range(201)]
        status, page, _ = self.call("GET", "/people", {"limit": "200", "search": "person"})
        self.assertEqual(200, status)
        self.assertEqual(200, len(page["items"]))
        self.assertIsNotNone(page["next_cursor"])
        self.assertIn("| take 201", self.logs.queries[-1])
        self.logs.usage_rows = []
        self.assertEqual(200, self.call("GET", "/people", {
            "limit": "200", "search": "person", "cursor": page["next_cursor"],
        })[0])
        self.assertIn("id >", self.logs.queries[-1])
        self.assertEqual(400, self.call("GET", "/people", {"limit": "500000"})[0])

    def test_query_injection_stays_in_a_quoted_string(self):
        self.call("GET", "/people", {"search": 'x" | union * //'})
        self.assertIn('x\\" | union * //', self.logs.queries[-1])
        self.assertNotIn('contains "x" | union', self.logs.queries[-1])
        self.assertEqual(400, self.call("GET", "/people", {"department_id": "x';union *"})[0])

    def test_write_http_contract_and_readonly_viewer(self):
        _, current, _ = self.call("GET", "/budgets")
        body = {"token_limit": 3000001, "reason": "Pilot"}
        self.assertEqual(409, self.call("PUT", "/budgets/department/payroll", body=body)[0])
        status, result, _ = self.call("PUT", "/budgets/department/payroll", body=body,
                                    headers={"If-Match": current["revision"]})
        self.assertEqual(200, status)
        self.assertIn("audit_id", result)
        self.verifier.verify.return_value = actor("Viewer")
        self.assertEqual(403, self.call("PUT", "/budgets/department/payroll", body=body,
                                      headers={"If-Match": result["revision"]})[0])

    def test_bad_json_unknown_fields_methods_and_oversized_body_fail(self):
        headers = {"authorization": "Bearer test"}
        self.assertEqual(400, self.api.handle("POST", "/api/v1/boosts", {}, b"{", headers)[0])
        self.assertEqual(413, self.api.handle("POST", "/api/v1/boosts", {}, b" " * 70000, headers)[0])
        self.assertEqual(400, self.call("PUT", "/budgets/department/payroll", body={
            "token_limit": 100, "reason": "x", "manager_scope": None,
        })[0])
        self.assertEqual(405, self.call("PATCH", "/budgets")[0])
        self.assertEqual(404, self.call("GET", "/never-a-route")[0])

    def test_scoped_audit_and_workflow_viewer_denied(self):
        self.verifier.verify.return_value = actor("Manager", groups=[TEAM_GROUP])
        self.assertEqual(403, self.call("GET", "/audit")[0])
        self.verifier.verify.return_value = actor("Viewer")
        self.assertEqual(403, self.call("GET", "/budget-requests")[0])


class QueryTests(unittest.TestCase):
    def test_bad_cursor_and_datetime_rejected(self):
        for value in ("%%%", "e30=", encode_cursor({"after": "x" * 3000})):
            with self.subTest(value=value[:10]), self.assertRaises(Exception):
                decode_cursor(value)


if __name__ == "__main__":
    unittest.main()
