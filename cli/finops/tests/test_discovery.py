import json

import pytest

from claude_finops.discovery import discover, choose
from claude_finops.errors import FinOpsError

SUB = "00000000-0000-0000-0000-000000000001"
APIM_ID = f"/subscriptions/{SUB}/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso"
WS_ID = f"/subscriptions/{SUB}/resourceGroups/rg-logs/providers/Microsoft.OperationalInsights/workspaces/log-contoso"


def test_ambiguous_selection_never_takes_first_silently():
    rows = [{"id": "one", "name": "One"}, {"id": "two", "name": "Two"}]
    with pytest.raises(FinOpsError, match="choose"):
        choose("gateway", rows, interactive=False)
    assert choose("gateway", rows, selected="two", interactive=False)["id"] == "two"


def test_picker_uses_recorded_default_but_presents_every_real_option():
    seen = []
    rows = [{"id": "one", "name": "One"}, {"id": "two", "name": "Two"}]
    def pick(label, options, default):
        seen.append((label, options, default))
        return default
    assert choose("gateway", rows, default="two", picker=pick)["id"] == "two"
    assert seen[0][1] == rows and seen[0][2] == 1


def runner():
    calls = []
    def run(*args):
        calls.append(args)
        joined = " ".join(args)
        if args[:2] == ("account", "show"):
            return json.dumps({"id": SUB})
        if args[:2] == ("account", "list"):
            return json.dumps([{"id": SUB, "name": "Contoso subscription", "tenantId": SUB, "state": "Enabled"}])
        if args[:2] == ("apim", "list"):
            return json.dumps([{"id": APIM_ID, "name": "apim-contoso", "resourceGroup": "rg-contoso",
                                "location": "eastus2", "sku": {"name": "StandardV2"}}])
        if args[:3] == ("apim", "nv", "show"):
            return "version=1;url=https://api.contoso.com;scope=api://contoso/Turnstile.Manage"
        if args[:4] == ("monitor", "log-analytics", "workspace", "list"):
            return json.dumps([{"id": WS_ID, "name": "log-contoso", "customerId": SUB}])
        if "diagnostics/applicationinsights" in joined:
            return json.dumps({"properties": {"loggerId": APIM_ID + "/loggers/live"}})
        if "/loggers/live?" in joined:
            return json.dumps({"properties": {"resourceId": APIM_ID.rsplit("/providers/", 1)[0] + "/providers/Microsoft.Insights/components/live"}})
        if "/components/live?" in joined:
            return json.dumps({"properties": {"WorkspaceResourceId": WS_ID}})
        raise AssertionError(args)
    return run, calls


def test_turnstile_comes_from_selected_gateway_without_global_account_change():
    run, calls = runner()
    result = discover(backend="turnstile", runner=run, target_reader=lambda _: "", interactive=False)
    assert result["config"]["url"] == "https://api.contoso.com"
    assert result["config"]["subscription"] == SUB
    assert result["config"]["workspace_resource_id"] == WS_ID
    assert not any(call[:2] == ("account", "set") for call in calls)
    assert all("--subscription" in call for call in calls if call[0] == "apim")


def test_direct_workspace_is_resolved_from_logger_not_name_guess():
    run, calls = runner()
    result = discover(backend="direct", runner=run, target_reader=lambda _: "", interactive=False)
    assert result["config"]["workspace"] == SUB
    assert result["portal"]["workspace_resource_id"] == WS_ID
    assert any("diagnostics/applicationinsights" in " ".join(call) for call in calls)


@pytest.mark.parametrize("recorded_other_gateway", [False, True])
def test_service_discovery_uses_tagged_function_and_nonsecret_settings(recorded_other_gateway):
    base, calls = runner()
    function_id = APIM_ID.rsplit("/providers/", 1)[0] + "/providers/Microsoft.Web/sites/func-contoso"
    def run(*args):
        if args[:2] == ("apim", "list") and recorded_other_gateway:
            original = json.loads(base(*args))
            return json.dumps(original + [dict(id=APIM_ID.replace("rg-contoso", "rg-other").replace("apim-contoso", "apim-other"),
                name="apim-other", resourceGroup="rg-other")])
        if args[:2] == ("functionapp", "list"):
            calls.append(args)
            return json.dumps([dict(id=function_id, name="func-contoso", resourceGroup="rg-contoso",
                                   defaultHostName="func.contoso.com", tags={"component": "aum-service"})])
        if args[:4] == ("functionapp", "config", "appsettings", "list"):
            import subprocess
            calls.append(args)
            assert "--query" in args
            assert not any("|" in str(arg) or "&" in str(arg) for arg in args)
            assert subprocess.list2cmdline([args[args.index("--query") + 1]]).startswith('"')
            return json.dumps([dict(name=name, value=value) for name, value in {
                "AUM_CLIENT_ID": SUB, "AUM_TENANT_ID": SUB, "AUM_APIM_RESOURCE_ID": APIM_ID,
                "AUM_WORKSPACE_ID": SUB}.items()])
        return base(*args)
    target = lambda field: ("rg-other" if field == "ResourceGroup" else "apim-other") if recorded_other_gateway else ""
    result = discover(backend="aum-service", runner=run, target_reader=target, interactive=False)
    assert result["config"]["url"] == "https://func.contoso.com"
    assert result["config"]["scope"] == f"api://{SUB}/AUM.Access"
    assert result["config"]["workspace_resource_id"] == WS_ID
    assert not any(call[:2] == ("account", "set") for call in calls)


def test_configure_command_previews_without_existing_profile(monkeypatch):
    from typer.testing import CliRunner
    from claude_finops.cli import app
    monkeypatch.setattr("claude_finops.configure.discover", lambda **kwargs:
                        {"config": {"backend": "direct", "subscription": SUB}, "portal": {}})
    result = CliRunner().invoke(app, ["configure", "--no-prompt", "--json", "--backend", "direct"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output)["saved"] is False


def test_configure_what_if_never_writes_profile(monkeypatch):
    from pathlib import Path
    from typer.testing import CliRunner
    from claude_finops.cli import app
    monkeypatch.setattr("claude_finops.configure.discover", lambda **kwargs:
                        {"config": {"backend": "direct", "subscription": SUB}, "portal": {}})
    writes = []
    monkeypatch.setattr(Path, "write_text", lambda *args, **kwargs: writes.append(args))
    result = CliRunner().invoke(app, ["configure", "--no-prompt", "--json", "--save", "--what-if"])
    assert result.exit_code == 0, result.output
    assert not writes


def test_bridge_selects_one_azure_executable_when_both_launchers_exist():
    from pathlib import Path
    import re
    import subprocess
    bridge = Path(__file__).resolve().parents[3] / "scripts" / "Invoke-ClaudeFinOps.ps1"
    expression = re.search(r"\$aumDirectAzureExecutable = (.+)", bridge.read_text(encoding="utf-8-sig"))[1]
    script = """
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    @([pscustomobject]@{Source='az-one'}, [pscustomobject]@{Source='az-two'})
}
$selected = """ + expression + """
if ($selected -is [array] -or $selected -ne 'az-one') { exit 1 }
"""
    result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_direct_wrapper_does_not_add_subscription_to_graph_ad_commands():
    from pathlib import Path
    import subprocess
    bridge = Path(__file__).resolve().parents[3] / "scripts" / "Invoke-ClaudeFinOps.ps1"
    script = r"""
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile('_BRIDGE_',[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'az'},$true)
Invoke-Expression $function.Extent.Text
function Fake-Az { $script:captured=@($args);$global:LASTEXITCODE=0 }
$aumDirectAzureExecutable='Fake-Az'
$aumDirectSubscription='00000000-0000-0000-0000-000000000001'
az ad group show --group test
if($script:captured -contains '--subscription'){throw 'Graph az ad commands do not accept subscription.'}
az apim nv list
if($script:captured -notcontains '--subscription'){throw 'ARM calls must keep the explicit subscription.'}
"""
    result = subprocess.run(["pwsh", "-NoProfile", "-Command", script.replace("_BRIDGE_", str(bridge))], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
