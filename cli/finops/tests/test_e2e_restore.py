import importlib.util
from pathlib import Path


def support():
    path = Path(__file__).resolve().parents[1] / "tools" / "e2e_support.py"
    spec = importlib.util.spec_from_file_location("e2e_support", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_restore_reinstates_exact_bytes_and_preserves_other_fields():
    module = support()
    state = module.GatewayState.__new__(module.GatewayState)
    original = {"bu-registry": {"value": ",sales=contoso:10,"}, "bu-members": {"value": ",,"}}
    current = {"bu-registry": {"value": ",sales=contoso:20,"}, "bu-members": {"value": ",x=test,"}}
    state.snapshot = lambda: current
    def call(method, path, *args, **kwargs):
        key = path.rsplit("/", 1)[-1]
        return {"properties": current[key]}
    state.call = call
    state.put = lambda key, value: current[key].update(value=value)
    result = state.restore(original, ["bu-members", "bu-registry"])
    assert result["verified"] and current == original


def test_restore_failure_is_not_reported_as_clean():
    import pytest
    from claude_finops.errors import FinOpsError
    module = support()
    state = module.GatewayState.__new__(module.GatewayState)
    state.snapshot = lambda: {"bu-members": {"value": ",changed,"}}
    state.call = lambda *args, **kwargs: {"properties": {"value": ",changed,"}}
    state.put = lambda *args: (_ for _ in ()).throw(RuntimeError("restore refused"))
    with pytest.raises(FinOpsError, match="RESTORE INCOMPLETE"):
        state.restore({"bu-members": {"value": ",,"}}, ["bu-members"])


def test_budget_cleanup_failure_does_not_suppress_catalog_restore():
    path = Path(__file__).resolve().parents[1] / "tools" / "e2e_cleanup.py"
    spec = importlib.util.spec_from_file_location("e2e_cleanup", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    calls = []
    class Engine:
        month = "2026-09"
        backend = None
        def write(self, *args, **kwargs):
            calls.append(kwargs["scope_id"])
            if len(calls) == 1:
                raise RuntimeError("first delete failed")
        def _replace(self, *args):
            calls.append("catalog-restored")
            return {}
        def read(self, resource):
            if resource == "budgets":
                return {"items": [{"scope_type": "organization", "scope_id": "unit", "token_limit": 10},
                                  {"scope_type": "department", "scope_id": "team", "token_limit": 1}]}
            return {"executions": []}
    engine = Engine()
    engine.backend = engine
    errors = module.restore_turnstile(engine, {}, "unit", "team")
    assert errors == ["first delete failed"]
    assert calls == ["team", "unit", "catalog-restored"]


def test_enforcement_uses_actual_quota_403_not_generic_permission_denial():
    matches = support().enforcement_matches
    assert matches(dict(status_code=403, error=dict(type="rate_limit_error", budget="business unit",
        message="Budget for aum-e2e-team-test is spent")), "strict", "aum-e2e-team-test")
    assert not matches(dict(status_code=403, error=dict(type="permission_error",
        message="Not permitted aum-e2e-team-test")), "strict", "aum-e2e-team-test")
    assert matches(dict(status_code=200, headers={"x-claude-budget-notice":
        "aum-e2e-team-test;mode=allowance:10;status=estimated-over-budget"}), "allowance", "aum-e2e-team-test")


def test_secret_governance_values_never_look_absent_to_restore():
    import pytest
    from claude_finops.errors import FinOpsError
    module = support()
    state = module.GatewayState.__new__(module.GatewayState)
    state.call = lambda *args, **kwargs: {"value": [
        {"name": "allow-standard", "properties": {"secret": True, "value": None}}]}
    with pytest.raises(FinOpsError, match="secret governance"):
        state.snapshot()


def test_direct_authority_switch_refuses_overlapping_scheduled_sync():
    import pytest
    from datetime import datetime, timezone
    from claude_finops.config import Config
    from claude_finops.errors import FinOpsError
    module = support()
    jobs = [dict(properties=dict(configuration=dict(scheduleTriggerConfig=dict(cronExpression="7 * * * *")),
        template=dict(containers=[dict(env=[dict(name="CLAUDE_APIM", value="apim-contoso"),
                                           dict(name="TURNSTILE_GOVERNANCE", value="true")])])))]
    with pytest.raises(FinOpsError, match="overlap"):
        module.require_quiet_direct_window(jobs, Config(apim_name="apim-contoso"), datetime(2026, 9, 25, 6, 58, tzinfo=timezone.utc))
    module.require_quiet_direct_window(jobs, Config(apim_name="apim-contoso"), datetime(2026, 9, 25, 7, 10, tzinfo=timezone.utc))
