"""Send tokenless discovery and in-memory redaction context to the portal capturer."""

import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit

from claude_finops.config import az, load_config, parse_integration
from claude_finops.discovery import discover
from claude_finops.errors import FinOpsError
from claude_finops.direct import DirectBackend
from claude_finops.config import Config
from claude_finops.redaction import digest


def context(config_path):
    config = load_config(Path(config_path))
    found = discover(backend="direct", subscription=config.subscription or None,
                     resource_group=config.resource_group or None, apim_name=config.apim_name or None,
                     workspace=None, interactive=False)
    values = found["config"]
    subscription = values["subscription"]
    account = json.loads(az("account", "show", "--subscription", subscription, "-o", "json"))
    replacements = {}
    try:
        display_name = az("apim", "api", "show", "-g", values["resource_group"], "--service-name",
                          values["apim_name"], "--api-id", "claude-foundry", "--query", "displayName",
                          "-o", "tsv", "--subscription", subscription)
        found["portal"]["api_display_name"] = display_name
    except FinOpsError:
        pass
    for field, replacement in (("name", "Contoso subscription"), ("tenantDisplayName", "Contoso directory"),
                                ("tenantDefaultDomain", "contoso.com")):
        if account.get(field):
            replacements[account[field]] = replacement
    for field, replacement in (("resource_group", "contoso-resource-group"), ("apim_name", "contoso-gateway")):
        replacements[values[field]] = replacement
    for field, replacement in (("workspace_resource_id", "contoso-logs"), ("app_insights_resource_id", "contoso-insights")):
        resource_id = found["portal"].get(field)
        if resource_id:
            replacements[resource_id.rsplit("/", 1)[-1]] = replacement
            replacements[resource_id.split("/")[4]] = "contoso-resource-group"
    catalog = DirectBackend(Config(**values)).read("catalog")
    for field in ("organizations", "departments"):
        for entity in catalog[field]:
            replacements[entity["name"]] = "contoso-group-" + digest(entity["id"])
            replacements[entity["id"]] = "contoso-scope-" + digest(entity["id"])
    try:
        own = json.loads(az("ad", "signed-in-user", "show", "-o", "json"))
        if own.get("displayName"):
            replacements[own["displayName"]] = "Contoso administrator"
            found["portal"]["signed_in_display_name"] = own["displayName"]
    except FinOpsError:
        pass
    try:
        integration = parse_integration(az("apim", "nv", "show", "-g", values["resource_group"],
                                          "--service-name", values["apim_name"], "--named-value-id", "turnstile-integration",
                                          "--query", "value", "-o", "tsv", "--subscription", subscription))
        apps = json.loads(az("webapp", "list", "--subscription", subscription, "-o", "json"))
        app = next((item for item in apps if item.get("defaultHostName") == urlsplit(integration["url"]).hostname), None)
        if app:
            found["portal"]["turnstile_resource_id"] = app["id"]
            replacements[app["name"]] = "contoso-usage-api"
            if app.get("serverFarmId"):
                replacements[app["serverFarmId"].rsplit("/", 1)[-1]] = "contoso-app-plan"
            if app.get("appServicePlanId"):
                replacements[app["appServicePlanId"].rsplit("/", 1)[-1]] = "contoso-app-plan"
            for value in (app.get("tags") or {}).values():
                if isinstance(value, str) and "/microsoft.insights/components/" in value.lower():
                    replacements[value.rsplit("/", 1)[-1]] = "contoso-service-insights"
            for component in json.loads(az("resource", "list", "-g", app["resourceGroup"],
                                           "--resource-type", "Microsoft.Insights/components",
                                           "--subscription", subscription, "-o", "json")):
                if component.get("name"):
                    replacements[component["name"]] = "contoso-service-insights"
    except FinOpsError:
        pass
    return dict(targets=found["portal"], replacements=replacements)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    print(json.dumps(context(args.config)))
