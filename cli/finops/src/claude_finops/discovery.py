"""Read-only discovery with explicit choices; never changes the global az account."""

import json
from pathlib import Path
import subprocess

from .config import Config, az, parse_integration
from .errors import FinOpsError


def recorded_target(field):
    script = Path(__file__).resolve().parents[4] / "scripts" / "Get-ClaudeGatewayTarget.ps1"
    if not script.exists():
        return ""
    try:
        result = subprocess.run(["pwsh", "-NoProfile", "-File", str(script), "-Field", field,
                                 "-WarningAction", "SilentlyContinue"], capture_output=True, text=True,
                                encoding="utf-8", timeout=30)
        return result.stdout.strip() if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def choose(label, rows, *, selected=None, default=None, interactive=True, picker=None):
    if not rows:
        raise FinOpsError(f"No accessible {label} was found. Check the signed-in tenant and Azure roles.", 5)
    if selected:
        match = next((row for row in rows if selected.casefold() in {
            str(row.get("id", "")).casefold(), str(row.get("name", "")).casefold()}), None)
        if match is None:
            raise FinOpsError(f"Requested {label} was not in the accessible options. Run configure to choose it.")
        return match
    default_index = next((i for i, row in enumerate(rows) if default in {row.get("id"), row.get("name")}), None)
    if interactive and picker:
        index = picker(label, rows, default_index if default_index is not None else 0)
        if not isinstance(index, int) or not 0 <= index < len(rows):
            raise FinOpsError(f"Select a listed {label} number.")
        return rows[index]
    if default_index is not None:
        return rows[default_index]
    if len(rows) == 1:
        return rows[0]
    raise FinOpsError(f"Several {label} options exist; run configure interactively to choose, or pass its identifier.")


def discover(*, backend=None, subscription=None, resource_group=None, apim_name=None,
             workspace=None, interactive=True, picker=None, runner=az, target_reader=recorded_target):
    current = json.loads(runner("account", "show", "-o", "json"))
    subscriptions = [s for s in json.loads(runner("account", "list", "-o", "json")) if s.get("state") == "Enabled"]
    selected_sub = choose("subscription", subscriptions, selected=subscription, default=current.get("id"),
                          interactive=interactive, picker=picker)
    sub = selected_sub["id"]
    gateways = json.loads(runner("apim", "list", "--subscription", sub, "-o", "json"))
    for gateway in gateways:
        gateway["resourceGroup"] = gateway.get("resourceGroup") or gateway["id"].split("/")[4]
    groups = sorted({gateway["resourceGroup"] for gateway in gateways})
    selected_group = choose("gateway resource group", [{"id": g, "name": g} for g in groups],
                            selected=resource_group, default=target_reader("ResourceGroup"),
                            interactive=interactive, picker=picker)
    rg = selected_group["name"]
    selected_apim = choose("API Management gateway", [g for g in gateways if g["resourceGroup"] == rg],
                           selected=apim_name, default=target_reader("ApimName"), interactive=interactive, picker=picker)
    apim = selected_apim["name"]
    integration = None
    try:
        value = runner("apim", "nv", "show", "-g", rg, "--service-name", apim,
                       "--named-value-id", "turnstile-integration", "--query", "value", "-o", "tsv",
                       "--subscription", sub)
        integration = parse_integration(value)
    except FinOpsError:
        pass
    choices = ([{"id": "turnstile", "name": "Turnstile (connected)"}] if integration else [])
    choices += [{"id": "direct", "name": "Direct (Azure RBAC administrator)"}]
    mode = choose("backend", choices, selected=backend, default=choices[0]["id"], interactive=interactive,
                  picker=picker)["id"]
    config = Config(backend=mode, subscription=sub, resource_group=rg, apim_name=apim)
    config.tenant_id = selected_sub.get("tenantId", "")
    portal = dict(tenant_id=selected_sub.get("tenantId"), subscription_id=sub,
                  apim_resource_id=selected_apim["id"])
    if mode == "turnstile":
        config.url, config.scope = integration["url"], integration["scope"]

    def arm(resource_id, version):
        return json.loads(runner("rest", "--method", "get", "--url",
                                 f"https://management.azure.com{resource_id}?api-version={version}",
                                 "--subscription", sub, "-o", "json"))

    preferred_workspace = None
    for suffix in ("/apis/claude-foundry/diagnostics/applicationinsights", "/diagnostics/applicationinsights"):
        try:
            diagnostic = arm(selected_apim["id"] + suffix, "2024-05-01")
            logger = arm(diagnostic["properties"]["loggerId"], "2024-05-01")
            component_id = logger["properties"]["resourceId"]
            component = arm(component_id, "2020-02-02")
            preferred_workspace = component["properties"]["WorkspaceResourceId"]
            portal["app_insights_resource_id"] = component_id
            break
        except (FinOpsError, KeyError):
            continue
    try:
        workspaces = json.loads(runner("monitor", "log-analytics", "workspace", "list",
                                      "--subscription", sub, "-o", "json"))
        selected_ws = choose("Log Analytics workspace", workspaces, selected=workspace, default=preferred_workspace,
                             interactive=interactive, picker=picker)
    except FinOpsError:
        if mode == "turnstile" and not workspace:
            return {"config": config.validate().public(), "portal": portal,
                    "ledger_note": "Turnstile is usable; ledger discovery needs an accessible workspace or explicit workspace selection."}
        raise
    customer_id = selected_ws.get("customerId") or selected_ws.get("properties", {}).get("customerId")
    if not customer_id:
        customer_id = arm(selected_ws["id"], "2023-09-01")["properties"]["customerId"]
    config.workspace = customer_id
    config.workspace_resource_id = selected_ws["id"]
    portal["workspace_resource_id"] = selected_ws["id"]
    return {"config": config.validate().public(), "portal": portal}
