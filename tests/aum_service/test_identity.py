import time
import unittest
from unittest.mock import Mock

from aum_service.auth import AccessDenied, TokenVerifier, resolve_identity
from aum_service.scope import resolve_scope


UNIT_GROUP = "00000000-0000-0000-0000-000000000001"
TEAM_GROUP = "00000000-0000-0000-0000-000000000002"
PERSON = "00000000-0000-0000-0000-000000000003"
TENANT = "00000000-0000-0000-0000-000000000004"
APP = "00000000-0000-0000-0000-000000000005"


def claims(roles=None, groups=None):
    return {
        "oid": PERSON, "sub": PERSON, "tid": TENANT, "aud": APP,
        "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
        "exp": int(time.time()) + 300, "iat": int(time.time()) - 10,
        "nbf": int(time.time()) - 10, "ver": "2.0", "scp": "AUM.Access",
        "roles": roles if roles is not None else ["AUM.Manager"],
        "groups": groups or [], "preferred_username": "manager@contoso.com",
    }


class IdentityTests(unittest.TestCase):
    def test_precedence_admin_then_viewer_then_manager(self):
        self.assertEqual("admin", resolve_identity(claims(["AUM.Manager", "AUM.Admin"])).access)
        viewer = resolve_identity(claims(["AUM.Manager", "AUM.Viewer"], [UNIT_GROUP]))
        self.assertEqual("viewer", viewer.access)
        self.assertIsNone(viewer.groups)
        self.assertEqual((), resolve_identity(claims()).groups)

    def test_no_role_or_workload_is_refused(self):
        for overrides in ({"roles": []}, {"scp": ""}, {"scp": "other"}, {"oid": "bad"},
                          {"roles": "AUM.Admin"}, {"ver": "1.0"}):
            with self.subTest(overrides=overrides), self.assertRaises(AccessDenied):
                resolve_identity({**claims(), **overrides})

    def test_group_overage_never_grants_scope(self):
        for marker in ({"hasgroups": True}, {"_claim_names": {"groups": "src1"}}):
            identity = resolve_identity({**claims(groups=[UNIT_GROUP]), **marker})
            self.assertEqual((), identity.groups)
        self.assertEqual((UNIT_GROUP,), resolve_identity(claims(groups=[UNIT_GROUP.upper()])).groups)

    def test_missing_and_malformed_groups_fail_closed(self):
        for groups in (None, "all", {}, ["not-an-object-id"]):
            identity = resolve_identity({**claims(), "groups": groups})
            self.assertEqual((), identity.groups)

    def test_real_rsa_signature_and_required_claims(self):
        import jwt
        from cryptography.hazmat.primitives.asymmetric import rsa

        private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        keys = Mock()
        keys.get_signing_key_from_jwt.return_value.key = private.public_key()
        verifier = TokenVerifier(TENANT, APP, keys=keys)
        valid = claims(["AUM.Admin"])
        self.assertEqual("admin", verifier.verify(jwt.encode(valid, private, algorithm="RS256")).access)
        invalid = [
            ({**valid, "aud": TENANT}, private, "RS256"),
            ({**valid, "tid": APP}, private, "RS256"),
            ({**valid, "iss": "https://contoso.invalid/v2.0"}, private, "RS256"),
            ({**valid, "exp": int(time.time()) - 120}, private, "RS256"),
            ({**valid, "nbf": int(time.time()) + 120}, private, "RS256"),
            (valid, other, "RS256"),
            (valid, "test-only-key", "HS256"),
        ]
        for payload, key, algorithm in invalid:
            with self.subTest(algorithm=algorithm, payload=payload), self.assertRaises(AccessDenied):
                verifier.verify(jwt.encode(payload, key, algorithm=algorithm))
        for name in ("exp", "iss", "aud", "oid", "tid", "iat"):
            payload = {k: v for k, v in valid.items() if k != name}
            with self.subTest(missing=name), self.assertRaises(AccessDenied):
                verifier.verify(jwt.encode(payload, private, algorithm="RS256"))


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.units = [
            {"id": "finance", "name": "Finance", "parent_id": None},
            {"id": "ops", "name": "Operations", "parent_id": None},
            {"id": "payroll", "name": "Payroll", "parent_id": "finance"},
            {"id": "audit", "name": "Audit", "parent_id": "finance"},
            {"id": "support", "name": "Support", "parent_id": "ops"},
        ]
        self.mapping = {"finance": UNIT_GROUP, "payroll": TEAM_GROUP}

    def test_unit_manager_inherits_teams_and_direct_people(self):
        scope = resolve_scope((UNIT_GROUP,), self.units, self.mapping)
        self.assertEqual({"finance"}, scope.organization_ids)
        self.assertEqual({"payroll", "audit"}, scope.department_ids)
        self.assertEqual({"payroll", "audit"}, scope.writable_department_ids)
        self.assertTrue(scope.contains_leaf("finance"))
        self.assertTrue(scope.contains_leaf("payroll"))
        self.assertFalse(scope.contains_leaf("ops"))
        scope.require_write("department", "audit")
        with self.assertRaises(AccessDenied):
            scope.require_write("organization", "finance")

    def test_team_parent_is_context_never_authority(self):
        scope = resolve_scope((TEAM_GROUP,), self.units, self.mapping)
        self.assertEqual(set(), scope.organization_ids)
        self.assertEqual({"finance"}, scope.context_organization_ids)
        self.assertEqual({"payroll"}, scope.department_ids)
        self.assertFalse(scope.contains_leaf("finance"))
        self.assertFalse(scope.contains_leaf("audit"))
        with self.assertRaises(AccessDenied):
            scope.require_write("department", "payroll")
        scope.require_write("user", PERSON, person_leaf="payroll")
        with self.assertRaises(AccessDenied):
            scope.require_write("user", PERSON, person_leaf="support")

    def test_empty_is_scoped_null_is_unrestricted(self):
        empty = resolve_scope((), self.units, self.mapping)
        self.assertEqual({"organizations": [], "departments": [], "writable_department_ids": []},
                         empty.profile())
        self.assertFalse(empty.contains_leaf("finance"))
        self.assertIsNone(resolve_scope(None, self.units, self.mapping))

    def test_invalid_mapping_and_unknown_catalog_never_expand_scope(self):
        scope = resolve_scope((UNIT_GROUP,), self.units, {"missing": UNIT_GROUP, "finance": None})
        self.assertFalse(scope.contains_leaf("finance"))


if __name__ == "__main__":
    unittest.main()
