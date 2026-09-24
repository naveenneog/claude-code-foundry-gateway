from copy import deepcopy
from datetime import timedelta
import unittest

from aum_service.auth import resolve_identity
from aum_service.errors import ServiceError
from aum_service.service import AumService
from aum_service.transactions import apply_values
from aum_service.workflows import Workflows
from fakes import FakeArm, FakeStore, FakeAnalytics, Clock
from test_identity import claims, UNIT_GROUP, TEAM_GROUP, PERSON


def actor(role="Admin", oid=PERSON, groups=None):
    return resolve_identity({**claims(["AUM." + role], groups), "oid": oid})


class TransactionTests(unittest.TestCase):
    def test_partial_write_rolls_back_verified_previous_value(self):
        arm = FakeArm()
        before = arm.read()
        arm.fail_key = "quota-standard"
        with self.assertRaises(ServiceError) as error:
            apply_values(arm, before, {"tpm-standard": "201", "quota-standard": "2001"}, lambda: None)
        self.assertEqual("write_failed", error.exception.code)
        self.assertEqual(before["tpm-standard"]["value"], arm.values["tpm-standard"])
        self.assertEqual([("tpm-standard", "201"), ("tpm-standard", "200")], arm.writes)

    def test_stale_etag_never_overwrites_external_writer(self):
        arm = FakeArm()
        before = arm.read()
        arm.put("tpm-standard", "555", before["tpm-standard"]["etag"])
        with self.assertRaises(ServiceError):
            apply_values(arm, before, {"tpm-standard": "201"}, lambda: None)
        self.assertEqual("555", arm.values["tpm-standard"])

    def test_readback_mismatch_is_failure_not_success(self):
        arm = FakeArm()
        arm.corrupt_key = "tpm-standard"
        with self.assertRaises(ServiceError):
            apply_values(arm, arm.read(), {"tpm-standard": "201"}, lambda: None)

    def test_lost_lease_prevents_write(self):
        arm = FakeArm()
        def lost():
            raise ServiceError(409, "lease_lost", "Lease lost")
        with self.assertRaises(ServiceError):
            apply_values(arm, arm.read(), {"tpm-standard": "201"}, lost)
        self.assertEqual([], arm.writes)


class ServiceWriteTests(unittest.TestCase):
    def setUp(self):
        self.arm, self.store, self.logs, self.clock = FakeArm(), FakeStore(), FakeAnalytics(), Clock()
        self.service = AumService(self.arm, self.store, self.logs, self.clock)
        self.admin = actor()
        self.store.put("managers", "finance", {"manager_group_id": UNIT_GROUP})
        self.store.put("managers", "payroll", {"manager_group_id": TEAM_GROUP})

    def revision(self):
        return self.service.budgets(self.admin)["revision"]

    def write(self, who, kind, id_, limit, revision=None):
        return self.service.set_budget(who, kind, id_, {
            "token_limit": limit, "reason": "Test allocation",
        }, revision or self.revision())

    def test_admin_write_audited_with_before_after_and_readback(self):
        result = self.write(self.admin, "department", "payroll", 3000001)
        self.assertIn("payroll=Contoso Payroll:3000001", self.arm.values["bu-registry"])
        self.assertEqual("succeeded", self.store.audits[-1]["outcome"])
        self.assertEqual(PERSON, self.store.audits[-1]["who"])
        self.assertIn("3000000", self.store.audits[0]["before"]["bu-registry"])
        self.assertIn("3000001", self.store.audits[0]["after"]["bu-registry"])
        self.assertEqual(self.revision(), result["revision"])

    def test_manager_only_allowed_team_and_person_writes(self):
        unit = actor("Manager", groups=[UNIT_GROUP])
        team = actor("Manager", groups=[TEAM_GROUP])
        self.write(unit, "department", "payroll", 3100000)
        self.write(team, "user", PERSON, 1001)
        for who, kind, id_ in ((team, "department", "payroll"), (unit, "organization", "finance"),
                               (team, "user", "00000000-0000-0000-0000-000000000004")):
            with self.subTest(kind=kind, id_=id_), self.assertRaises(ServiceError) as error:
                self.write(who, kind, id_, 1001)
            self.assertEqual(403, error.exception.status)

    def test_viewer_and_empty_manager_have_no_writes(self):
        for who in (actor("Viewer"), actor("Manager")):
            with self.subTest(access=who.access), self.assertRaises(ServiceError) as error:
                self.write(who, "department", "payroll", 3000001)
            self.assertEqual(403, error.exception.status)
        self.assertEqual([], self.arm.writes)

    def test_failed_headroom_and_stale_revision_do_not_write(self):
        revision = self.revision()
        with self.assertRaises(ServiceError):
            self.write(self.admin, "department", "payroll", 7000001)
        self.write(self.admin, "department", "payroll", 3000001)
        with self.assertRaises(ServiceError) as error:
            self.write(self.admin, "department", "payroll", 3000002, revision)
        self.assertEqual("stale_revision", error.exception.code)
        self.assertEqual(1, len(self.arm.writes))

    def test_daily_override_reserves_longest_month_not_only_today_month(self):
        with self.assertRaises(ServiceError) as error:
            self.write(self.admin, "user", PERSON, 100000)
        self.assertEqual("insufficient_headroom", error.exception.code)

    def test_audit_outage_refuses_mutation(self):
        self.store.fail_audit = True
        with self.assertRaises(Exception):
            self.write(self.admin, "department", "payroll", 3000001)
        self.assertEqual([], self.arm.writes)

    def test_admin_only_catalog_tiers_modes_and_manager_mappings(self):
        manager = actor("Manager", groups=[UNIT_GROUP])
        for kind, id_, data in (
            ("mode", "finance", {"enforcement": "notify"}),
            ("manager", "finance", {"manager_group_id": TEAM_GROUP}),
            ("tier", "standard", {"tokens_per_day": 3000, "tokens_per_minute": 500, "models": []}),
            ("catalog", "", {"entities": []}),
        ):
            with self.subTest(kind=kind), self.assertRaises(ServiceError) as error:
                self.service.configure(manager, kind, id_, {**data, "reason": "Test"}, self.revision())
            self.assertEqual(403, error.exception.status)

    def test_turnstile_authority_refuses_a_second_writer(self):
        self.arm.values["turnstile-integration"] = "governanceAuthority=Turnstile"
        self.arm.etags["turnstile-integration"] = 1
        with self.assertRaises(ServiceError) as error:
            self.write(self.admin, "department", "payroll", 3000001)
        self.assertEqual("other_authority", error.exception.code)


class WorkflowTests(ServiceWriteTests):
    def setUp(self):
        super().setUp()
        self.workflows = Workflows(self.service)
        self.manager = actor("Manager", groups=[TEAM_GROUP])
        self.approver = actor("Manager", oid="00000000-0000-0000-0000-000000000099", groups=[UNIT_GROUP])

    def request(self, limit=3100000):
        return self.workflows.request(self.manager, {
            "scope_type": "department", "scope_id": "payroll",
            "token_limit": limit, "reason": "Quarter end",
        })

    def decide(self, who, request, action="approve"):
        return self.workflows.decide(who, request["id"], action, {"version": request["version"], "reason": "Reviewed"})

    def test_request_one_level_up_and_approve(self):
        request = self.request()
        self.assertEqual("finance", request["approver_scope"])
        result = self.decide(self.approver, request)
        self.assertEqual("approved", result["result"]["state"])
        self.assertIn(":3100000", self.arm.values["bu-registry"])
        with self.assertRaises(ServiceError):
            self.decide(self.approver, request)

    def test_self_approval_and_out_of_scope_requests_denied(self):
        request = self.request()
        with self.assertRaises(ServiceError):
            self.decide(self.manager, request)
        with self.assertRaises(ServiceError):
            self.workflows.request(self.manager, {
                "scope_type": "department", "scope_id": "audit", "token_limit": 1, "reason": "No",
            })

    def test_approval_rechecks_headroom_and_dynamic_group_mapping(self):
        request = self.request(8000000)
        with self.assertRaises(ServiceError):
            self.decide(self.approver, request)
        self.assertEqual("pending", self.store.get("requests", request["id"])["state"])
        self.store.put("managers", "finance", {"manager_group_id": TEAM_GROUP})
        with self.assertRaises(ServiceError):
            self.decide(self.approver, request, "reject")

    def test_reject_and_escalation(self):
        request = self.request()
        result = self.decide(self.manager, request, "escalate")
        escalated = result["result"]
        self.assertIsNone(escalated["approver_scope"])
        result = self.decide(actor("Admin", self.approver.oid), escalated, "reject")
        self.assertEqual("rejected", result["result"]["state"])
        self.assertEqual([], self.arm.writes)

    def test_expiring_boost_restores_previous_value(self):
        before = self.arm.values["bu-registry"]
        result = self.workflows.boost(self.admin, {
            "scope_type": "department", "scope_id": "payroll", "token_limit": 3100000,
            "expires_at": (self.clock.now + timedelta(minutes=1)).isoformat(), "reason": "Release",
        }, self.revision())
        id_ = result["result"]["id"]
        self.assertEqual("active", self.store.get("boosts", id_)["state"])
        self.workflows.expire()
        self.assertNotEqual(before, self.arm.values["bu-registry"])
        self.clock.now += timedelta(minutes=2)
        self.workflows.expire()
        self.assertEqual(before, self.arm.values["bu-registry"])
        self.assertEqual("expired", self.store.get("boosts", id_)["state"])

    def test_overlapping_boost_and_children_that_prevent_restore_denied(self):
        data = {"scope_type": "department", "scope_id": "payroll", "token_limit": 3100000,
                "expires_at": (self.clock.now + timedelta(minutes=1)).isoformat(), "reason": "Release"}
        self.workflows.boost(self.admin, data, self.revision())
        with self.assertRaises(ServiceError):
            self.workflows.boost(self.admin, data, self.revision())
        with self.assertRaises(ServiceError):
            self.write(self.admin, "user", PERSON, 103333)

    def test_timer_does_not_overwrite_newer_external_edit(self):
        result = self.workflows.boost(self.admin, {
            "scope_type": "department", "scope_id": "payroll", "token_limit": 3100000,
            "expires_at": (self.clock.now + timedelta(minutes=1)).isoformat(), "reason": "Release",
        }, self.revision())
        self.arm.values["bu-registry"] = self.arm.values["bu-registry"].replace(":3100000", ":3200000")
        self.clock.now += timedelta(minutes=2)
        self.workflows.expire()
        self.assertIn(":3200000", self.arm.values["bu-registry"])
        self.assertEqual("superseded", self.store.get("boosts", result["result"]["id"])["state"])

    def test_timer_failure_keeps_due_record_for_retry(self):
        result = self.workflows.boost(self.admin, {
            "scope_type": "department", "scope_id": "payroll", "token_limit": 3100000,
            "expires_at": (self.clock.now + timedelta(minutes=1)).isoformat(), "reason": "Release",
        }, self.revision())
        self.clock.now += timedelta(minutes=2)
        self.arm.fail_key = "bu-registry"
        self.workflows.expire()
        self.assertEqual("active", self.store.get("boosts", result["result"]["id"])["state"])
        self.arm.fail_key = None
        self.workflows.expire()
        self.assertEqual("expired", self.store.get("boosts", result["result"]["id"])["state"])


if __name__ == "__main__":
    unittest.main()
