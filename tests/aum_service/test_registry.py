import json
import os
from pathlib import Path
import subprocess
import unittest

from aum_service.errors import ServiceError
from aum_service.registry import (
    Config, parse_registry, render_registry, parse_map, render_map, parse_modes, render_modes,
    budget_changes, validate_headroom,
)


ROOT = Path(__file__).resolve().parents[2]
PERSON = "00000000-0000-0000-0000-000000000003"
OTHER = "00000000-0000-0000-0000-000000000004"


def values():
    return {
        "bu-registry": ",finance=Contoso Finance:9000000,payroll=Contoso Payroll:3000000,audit=Contoso Audit:2000000,",
        "bu-parents": ",payroll=finance,audit=finance,", "bu-modes": ",,",
        "bu-members": f",{PERSON}=payroll,{OTHER}=finance,",
        "quota-overrides": f",{PERSON}=1000,", "quota-org": "12000000",
        "quota-standard": "2000", "quota-premium": "4000",
        "tpm-standard": "200", "tpm-premium": "400",
        "models-standard": ",model-a,", "models-premium": ",,",
    }


class SerializerTests(unittest.TestCase):
    def test_shared_fixtures_execute_on_both_windows_powershell_hosts(self):
        if os.name == "nt":
            for script in ("Export-AumRegistryFixtures.ps1", "Export-AumModeFixtures.ps1"):
                results = []
                for host in ("pwsh", "powershell"):
                    result = subprocess.run([host, "-NoProfile", "-File", str(ROOT / "tests" / script)],
                                            check=True, capture_output=True, encoding="utf-8-sig")
                    results.append(json.loads(result.stdout))
                self.assertEqual(results[0], results[1], script)

    def test_mode_input_normalization_matches_the_actual_powershell_parser(self):
        fixtures = json.loads((ROOT / "tests" / "fixtures" / "aum-mode-inputs.json").read_text())
        output = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ROOT / "tests" / "Export-AumModeFixtures.ps1")],
            check=True, capture_output=True, encoding="utf-8-sig",
        )
        powershell = {f["name"]: f["canonical"] for f in json.loads(output.stdout)}
        for fixture in fixtures:
            with self.subTest(name=fixture["name"]):
                actual = render_modes(parse_modes(fixture["raw"]))
                self.assertEqual(fixture["canonical"].encode(), actual.encode())
                self.assertEqual(powershell[fixture["name"]].encode(), actual.encode())
        with self.assertRaises(ServiceError):
            parse_modes(",,,")

    def test_shared_fixtures_python_and_powershell_are_byte_identical(self):
        fixtures = json.loads((ROOT / "tests" / "fixtures" / "aum-registry.json").read_text())
        output = subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ROOT / "tests" / "Export-AumRegistryFixtures.ps1")],
            check=True, capture_output=True, encoding="utf-8-sig",
        )
        powershell = {f["name"]: f for f in json.loads(output.stdout)}
        for fixture in fixtures:
            actual = {
                "registry": render_registry(fixture["units"]),
                "parents": render_map(fixture["parents"]),
                "members": render_map(fixture["members"]),
                "overrides": render_map(fixture["overrides"]),
                "modes": render_modes(fixture["modes"]),
            }
            for key, value in actual.items():
                with self.subTest(fixture=fixture["name"], key=key):
                    self.assertEqual(fixture["expected"][key].encode(), value.encode())
                    self.assertEqual(powershell[fixture["name"]][key].encode(), value.encode())
            self.assertEqual(fixture["units"], parse_registry(actual["registry"]))
            self.assertEqual(fixture["parents"], parse_map(actual["parents"]))
            self.assertEqual({k: v for k, v in fixture["modes"].items() if v != "strict"},
                             parse_modes(actual["modes"]))

    def test_bad_existing_values_are_not_silently_dropped(self):
        for value in (",broken,", ",a=group:not-a-number,", ",a=group:1,a=other:2,",
                      "a=group:1", ",a=group:-1,", ",a=group:9223372036854775808,"):
            with self.subTest(value=value), self.assertRaises(ServiceError):
                parse_registry(value)
        for value in (",a=1,a=2,", ",malformed,", ",a=,"):
            with self.subTest(value=value), self.assertRaises(ServiceError):
                parse_map(value)
        for value in (",a=allowance:0,", ",a=allowance:101,", ",a=Notify,", ",a=strict,a=notify,"):
            with self.subTest(value=value), self.assertRaises(ServiceError):
                parse_modes(value)

    def test_exact_named_value_limit_in_utf16_code_units(self):
        self.assertEqual(4096, len(render_map({"x": "a" * 4092})))
        with self.assertRaises(ServiceError):
            render_map({"x": "a" * 4093})
        with self.assertRaises(ServiceError):
            render_map({"x": "\U0001f642" * 2047})

    def test_parents_cycles_depth_and_dangling_are_refused(self):
        for parents in (",payroll=missing,", ",finance=payroll,payroll=finance,",
                        ",payroll=finance,audit=payroll,"):
            with self.subTest(parents=parents), self.assertRaises(ServiceError):
                Config({**values(), "bu-parents": parents})

    def test_mode_is_strict_by_default(self):
        config = Config(values())
        self.assertEqual("strict", config.mode("payroll")["enforcement"])
        self.assertNotIn("allowance_percent", config.mode("payroll"))


class HeadroomTests(unittest.TestCase):
    def setUp(self):
        self.config = Config(values())
        self.members = {PERSON: "payroll", OTHER: "finance"}

    def check(self, kind, id_, tokens, config=None):
        return validate_headroom(config or self.config, kind, id_, tokens, self.members, 30)

    def test_team_must_fit_parent_less_siblings_and_direct_overrides(self):
        self.check("department", "payroll", 7000000)
        with self.assertRaises(ServiceError):
            self.check("department", "payroll", 7000001)
        config = Config({**values(), "quota-overrides": f",{PERSON}=1000,{OTHER}=100000,"})
        with self.assertRaises(ServiceError):
            self.check("department", "payroll", 4000001, config)

    def test_person_daily_reserves_whole_calendar_month(self):
        self.check("user", PERSON, 100000)
        with self.assertRaises(ServiceError):
            self.check("user", PERSON, 100001)

    def test_cannot_lower_parent_below_children(self):
        self.check("organization", "finance", 5000000)
        with self.assertRaises(ServiceError):
            self.check("organization", "finance", 4999999)
        with self.assertRaises(ServiceError):
            self.check("department", "payroll", 29999)

    def test_no_parent_budget_or_unknown_person_fail_closed(self):
        config = Config({**values(), "bu-registry": values()["bu-registry"].replace(":9000000", ":0")})
        with self.assertRaises(ServiceError):
            self.check("department", "payroll", 1, config)
        with self.assertRaises(ServiceError):
            self.check("user", "00000000-0000-0000-0000-000000000099", 1)

    def test_notify_does_not_bypass_allocation_constraint(self):
        config = Config({**values(), "bu-modes": ",finance=notify,"})
        with self.assertRaises(ServiceError):
            self.check("department", "payroll", 7000001, config)

    def test_budget_write_preserves_unrelated_entries_and_order(self):
        change = budget_changes(self.config, "department", "payroll", 3500000)
        self.assertEqual({"bu-registry": values()["bu-registry"].replace(
            "payroll=Contoso Payroll:3000000", "payroll=Contoso Payroll:3500000")}, change)
        person = budget_changes(self.config, "user", OTHER, 500)
        self.assertEqual(f",{PERSON}=1000,{OTHER}=500,", person["quota-overrides"])
        clear = budget_changes(self.config, "user", PERSON, None)
        self.assertEqual(",,", clear["quota-overrides"])


if __name__ == "__main__":
    unittest.main()
