import unittest
from unittest.mock import Mock
from unittest.mock import patch
import json
from pathlib import Path

from aum_service.azure import NamedValues, LogAnalytics
from aum_service.errors import ServiceError
from aum_service.storage import AzureStore, encode_entity, decode_entity, row_filter


APIM = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso"


class AzureAdapterTests(unittest.TestCase):
    def test_arm_list_pages_and_never_exposes_unrelated_named_values(self):
        http = Mock()
        http.call.side_effect = [
            ({"value": [{"name": "quota-org", "properties": {"value": "100"}},
                         {"name": "private-secret", "properties": {"secret": True}}],
              "nextLink": "https://management.azure.com" + APIM + "/namedValues?cursor=two"}, {}),
            ({"value": [{"name": "bu-modes", "properties": {"value": ",,"}}]}, {}),
        ]
        values = NamedValues(APIM, http).read()
        self.assertEqual({"quota-org", "bu-modes"}, set(values))
        self.assertEqual(2, http.call.call_count)

    def test_arm_rejects_external_continuation_url(self):
        http = Mock()
        http.call.return_value = ({"value": [], "nextLink": "https://contoso.invalid/steal"}, {})
        with self.assertRaises(ServiceError):
            NamedValues(APIM, http).read()
        self.assertEqual(1, http.call.call_count)

    def test_put_sends_etag_and_readback_has_version(self):
        http = Mock()
        http.call.return_value = ({"properties": {"value": "100"}}, {"ETag": '"3"'})
        result = NamedValues(APIM, http).put("quota-org", "100", '"2"')
        self.assertEqual('"3"', result["etag"])
        self.assertEqual('"2"', http.call.call_args.kwargs["headers"]["If-Match"])
        self.assertNotIn("listKeys", http.call.call_args.args[1])

    def test_put_preserves_display_name_and_tags(self):
        http = Mock()
        http.call.return_value = ({"properties": {"value": "100", "displayName": "quota-org",
                                                  "tags": ["Contoso Governance"]}}, {"ETag": '"2"'})
        arm = NamedValues(APIM, http)
        arm.get("quota-org")
        arm.put("quota-org", "101", '"2"')
        self.assertEqual(["Contoso Governance"], http.call.call_args.kwargs["body"]["properties"]["tags"])

    def test_log_analytics_rejects_partial_error_not_zero_usage(self):
        http = Mock()
        http.call.return_value = ({"error": {"code": "PartialError"}, "tables": []}, {})
        logs = LogAnalytics("00000000-0000-0000-0000-000000000001", http)
        with self.assertRaises(ServiceError):
            logs.query("ClaudeCost()")
        http.call.return_value = ({"tables": [{"columns": [{"name": "usd"}], "rows": [[1.25]]}]}, {})
        self.assertEqual([{"usd": 1.25}], logs.query("ClaudeCost()"))

    def test_member_resolution_uses_bounded_id_predicate(self):
        http = Mock()
        http.call.return_value = ({"tables": [{"columns": [{"name": "id"}, {"name": "parent_id"}],
                                              "rows": [["00000000-0000-0000-0000-000000000001", "finance"]]}]}, {})
        logs = LogAnalytics("00000000-0000-0000-0000-000000000002", http)
        mapping = logs.memberships(["00000000-0000-0000-0000-000000000001"])
        self.assertEqual("finance", next(iter(mapping.values())))
        query = http.call.call_args.kwargs["body"]["query"]
        self.assertIn("user_id in (", query)
        self.assertIn("last_timestamp=max(timestamp)", query)
        self.assertIn("array_length(units) == 1", query)
        self.assertIn("ClaudeChargeback(", query)
        self.assertNotIn("ClaudeCost(", query)
        self.assertNotRegex(query, r"\blet\s+latest\s*=")


class StorageEncodingTests(unittest.TestCase):
    def test_roundtrip_preserves_nulls_large_limits_and_nested_audit(self):
        value = {"id": "contoso", "before": {"limit": 9223372036854775807},
                 "after": None, "state": "pending", "approver_scope": None}
        row = encode_entity("requests", "contoso", value)
        self.assertEqual("requests", row["PartitionKey"])
        self.assertEqual(value, decode_entity(row))
        self.assertNotIn("AccountKey", str(row))

    def test_storage_keys_and_filters_cannot_inject_odata(self):
        with self.assertRaises(ServiceError):
            row_filter("boosts", "x' or true")
        with self.assertRaises(ServiceError):
            encode_entity("requests", "bad/key", {})
        self.assertEqual("PartitionKey eq 'boosts' and RowKey gt 'abc'", row_filter("boosts", "abc"))

    def test_a_hung_renewal_cannot_extend_the_local_writer_deadline(self):
        store = AzureStore.__new__(AzureStore)
        store.blob = Mock()
        with patch("aum_service.storage.threading.Thread"), patch("time.monotonic") as clock:
            clock.return_value = 100
            with store.lease() as check:
                check()
                clock.return_value = 161
                with self.assertRaises(ServiceError) as error:
                    check()
                self.assertEqual("lease_lost", error.exception.code)


class FunctionHostTests(unittest.TestCase):
    def test_timer_extension_and_registered_bindings(self):
        import function_app
        config = json.loads((Path(__file__).resolve().parents[2] / "service" / "aum" / "host.json").read_text())
        self.assertEqual("Microsoft.Azure.Functions.ExtensionBundle", config["extensionBundle"]["id"])
        bindings = {f.get_function_name(): f.get_bindings_dict() for f in function_app.app.get_functions()}
        self.assertEqual("0 * * * * *", bindings["expire_boosts"]["bindings"][0]["schedule"])
        self.assertTrue(bindings["expire_boosts"]["bindings"][0]["useMonitor"])


if __name__ == "__main__":
    unittest.main()
