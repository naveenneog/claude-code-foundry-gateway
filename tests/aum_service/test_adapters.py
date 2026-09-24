import unittest
from unittest.mock import Mock

from aum_service.azure import NamedValues, LogAnalytics
from aum_service.errors import ServiceError
from aum_service.storage import encode_entity, decode_entity, row_filter


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
        self.assertIn("arg_max", query)
        self.assertIn("ClaudeCost(", query)


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


if __name__ == "__main__":
    unittest.main()
