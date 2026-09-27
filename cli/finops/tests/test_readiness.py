import json

import httpx
import pytest
from typer.testing import CliRunner

from claude_finops.cli import app
from claude_finops.config import Config, load_config
from claude_finops.engine import Engine
from claude_finops.errors import FinOpsError
from claude_finops.turnstile import TurnstileBackend


SUB = "00000000-0000-0000-0000-000000000071"
URL = "https://turnstile.contoso.com"
SCOPE = "api://contoso/Turnstile.Manage"
GROUP = "rg-turnstile-contoso"
SERVER = "pg-turnstile-contoso"
INTEGRATION = f"version=1;url={URL};scope={SCOPE};resourceGroup={GROUP}"


def backend(monkeypatch, *, response=500, inventory=None, group=GROUP, integration=INTEGRATION):
    config = Config(backend="turnstile", url=URL, scope=SCOPE, subscription=SUB,
                    resource_group="rg-gateway", apim_name="apim-contoso")
    config.turnstile_resource_group = group
    calls, requests = [], []

    def run(*args, **kwargs):
        calls.append((args, kwargs))
        if args[:3] == ("apim", "nv", "show"):
            return integration
        assert args[:3] == ("postgres", "flexible-server", "list"), args
        if isinstance(inventory, Exception):
            raise inventory
        return json.dumps(inventory if inventory is not None else [
            dict(name=SERVER, resourceGroup=GROUP, state="Stopped")])

    def respond(request):
        requests.append(request)
        if response == "timeout":
            raise httpx.ReadTimeout("private-transport-details", request=request)
        return httpx.Response(response, json={"role": "owner"} if response == 200 else
                              {"detail": "private-server-details"})

    monkeypatch.setattr("claude_finops.config.az", run)
    result = TurnstileBackend(config, token_provider=lambda: "test-only",
                             transport=httpx.MockTransport(respond))
    return result, calls, requests


@pytest.mark.parametrize("response", ["timeout", 500, 503])
def test_stopped_database_has_specific_exit_and_exact_manual_start(monkeypatch, response):
    target, calls, requests = backend(monkeypatch, response=response)
    with pytest.raises(FinOpsError) as caught:
        Engine(target, "2026-09").read("budgets")
    assert caught.value.code == 9
    assert f"az postgres flexible-server start -g {GROUP} -n {SERVER}" in str(caught.value)
    assert f"--subscription {SUB}" in str(caught.value)
    assert "Stopped" in str(caught.value)
    assert all("start" not in args for args, _ in calls)
    assert all(request.method == "GET" and request.url.path == "/api/v1/auth/me" for request in requests)
    assert "private-" not in str(caught.value) and "test-only" not in str(caught.value)
    target.close()


def test_identity_is_the_bounded_authenticated_probe_not_liveness(monkeypatch):
    target, calls, requests = backend(monkeypatch, response=200)
    assert target.read("whoami")["role"] == "owner"
    assert len(requests) == 1
    assert requests[0].url.path == "/api/v1/auth/me"
    assert requests[0].headers["Authorization"] == "Bearer test-only"
    assert all(0 < seconds <= 1.5 for seconds in requests[0].extensions["timeout"].values())
    assert not calls
    target.close()


@pytest.mark.parametrize("status,code,count", [(401, 3, 2), (403, 4, 1), (404, 5, 1), (429, 7, 1)])
def test_non_availability_failures_do_not_probe_azure_or_change_exit(monkeypatch, status, code, count):
    target, calls, requests = backend(monkeypatch, response=status)
    with pytest.raises(FinOpsError) as caught:
        target.read("whoami")
    assert caught.value.code == code
    assert not calls and len(requests) == count
    target.close()


@pytest.mark.parametrize("state", ["Ready", "Starting", "Stopping", "Disabled", "Unknown"])
def test_other_database_states_are_named_but_never_called_stopped(monkeypatch, state):
    target, _, _ = backend(monkeypatch, inventory=[dict(name=SERVER, resourceGroup=GROUP, state=state)])
    with pytest.raises(FinOpsError) as caught:
        target.read("whoami")
    assert caught.value.code == 7
    assert SERVER in str(caught.value) and state in str(caught.value)
    assert "flexible-server start" not in str(caught.value)
    target.close()


@pytest.mark.parametrize("inventory,reason", [
    ([], "No PostgreSQL"),
    ([dict(name=SERVER, state="Stopped"), dict(name="pg-other", state="Ready")], "Several PostgreSQL"),
    ({"state": "Stopped"}, "could not be verified"),
    ([dict(name=SERVER, resourceGroup="rg-unrelated", state="Stopped")], "could not be verified"),
    ([dict(name="pg-unsafe&command", resourceGroup=GROUP, state="Stopped")], "could not be verified"),
    ([dict(name=SERVER, resourceGroup=GROUP)], "could not be verified"),
    ([dict(name=SERVER, resourceGroup=GROUP, state={"private": "Stopped"})], "could not be verified"),
    (FinOpsError("private-azure-details", 3), "could not be verified"),
])
def test_unverified_database_is_not_a_stopped_diagnosis(monkeypatch, inventory, reason):
    target, _, _ = backend(monkeypatch, inventory=inventory)
    with pytest.raises(FinOpsError) as caught:
        target.read("whoami")
    assert caught.value.code == 7
    assert reason in str(caught.value)
    assert "flexible-server start" not in str(caught.value)
    assert "private-" not in str(caught.value) and "pg-unsafe" not in str(caught.value)
    target.close()


def test_old_gateway_profile_resolves_matching_integration_and_bounds_every_azure_read(monkeypatch):
    target, calls, _ = backend(monkeypatch, group="")
    with pytest.raises(FinOpsError) as caught:
        target.read("whoami")
    assert caught.value.code == 9
    assert [args[:3] for args, _ in calls] == [
        ("apim", "nv", "show"), ("postgres", "flexible-server", "list")]
    assert all(0 < kwargs["timeout"] <= 2.5 for _, kwargs in calls)
    assert all(args[args.index("--subscription") + 1] == SUB for args, _ in calls)
    assert calls[-1][0][calls[-1][0].index("--resource-group") + 1] == GROUP
    assert all(not any(char in arg for char in "()|&<>^") for args, _ in calls for arg in args)
    target.close()


@pytest.mark.parametrize("integration", [
    INTEGRATION.replace(URL, "https://unrelated.contoso.com"),
    INTEGRATION.replace(SCOPE, "api://other/Turnstile.Manage"),
    INTEGRATION.replace(GROUP, "rg-unsafe&command"),
    INTEGRATION.replace(GROUP, "rg-unsafe(command)"),
    INTEGRATION.replace(f";resourceGroup={GROUP}", ""),
    "not-an-integration",
])
def test_mismatched_or_unsafe_integration_never_selects_another_database(monkeypatch, integration):
    target, calls, _ = backend(monkeypatch, group="", integration=integration)
    with pytest.raises(FinOpsError) as caught:
        target.read("whoami")
    assert caught.value.code == 7 and "could not be verified" in str(caught.value)
    assert len(calls) == 1 and calls[0][0][:3] == ("apim", "nv", "show")
    target.close()


def test_address_only_app_role_profile_does_not_require_azure_inventory(monkeypatch):
    target, calls, _ = backend(monkeypatch, group="")
    target.config.resource_group = target.config.apim_name = target.config.subscription = ""
    with pytest.raises(FinOpsError) as caught:
        target.read("whoami")
    assert caught.value.code == 7
    assert "could not be verified" in str(caught.value)
    assert not calls
    target.close()


def test_new_profile_metadata_survives_save_load_and_discovery(monkeypatch, tmp_path):
    path = tmp_path / "profile.json"
    path.write_text(json.dumps(dict(backend="turnstile", url=URL, scope=SCOPE,
                                   turnstile_resource_group=GROUP)), encoding="utf-8")
    assert load_config(path).public()["turnstile_resource_group"] == GROUP
    from test_discovery import runner
    from claude_finops.discovery import discover
    original, _ = runner()

    def run(*args):
        return INTEGRATION if args[:3] == ("apim", "nv", "show") else original(*args)

    result = discover(backend="turnstile", runner=run, target_reader=lambda _: "", interactive=False)
    assert result["config"]["turnstile_resource_group"] == GROUP
    monkeypatch.setattr("claude_finops.config.az", run)
    path.write_text(json.dumps(dict(backend="turnstile", resource_group="rg-gateway",
                                   apim_name="apim-contoso")), encoding="utf-8")
    assert load_config(path).turnstile_resource_group == GROUP


def test_cli_preserves_specific_failure_in_machine_readable_output(monkeypatch):
    target, _, _ = backend(monkeypatch)
    monkeypatch.setattr("claude_finops.cli.connect", lambda _: target)
    result = CliRunner().invoke(app, ["whoami", "--json", "--backend", "fake"])
    assert result.exit_code == 9
    error = json.loads(result.output)
    assert error["exit_code"] == 9 and SERVER in error["error"]


def test_writes_are_never_repeated_or_reclassified_as_database_starts(monkeypatch):
    target, calls, requests = backend(monkeypatch)
    with pytest.raises(FinOpsError) as caught:
        target.write("budget", dict(token_limit=1000), month="2026-09",
                     scope_type="department", scope_id="sales-emea")
    assert caught.value.code == 7
    assert not calls and len(requests) == 1 and requests[0].method == "PUT"
    target.close()
