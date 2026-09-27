"""Read-only Turnstile dependency diagnosis; no resource starts or secret reads."""

import re
import time
from urllib.parse import quote

import httpx

from . import config as configuration
from .errors import FinOpsError


def database_failure(config, client, status=None, credential=None):
    cause = f"HTTP {status}" if status else "authenticated readiness timed out"
    prefix = f"Turnstile unavailable: {cause}. "
    unknown = prefix + (
        "Database state could not be verified. An Azure administrator can check the "
        "Turnstile deployment's PostgreSQL state; no resource was started. "
        "Direct is a separate Azure-RBAC connection, not a scoped fallback.")
    if not config.subscription:
        return FinOpsError(unknown, 7)
    group = config.turnstile_resource_group
    deadline = time.monotonic() + 3
    subscription = f"/subscriptions/{config.subscription}"

    def remaining():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FinOpsError("Database diagnostic deadline reached.", 7)
        return min(2.5, remaining)

    try:
        access = credential.result(timeout=remaining()) if credential else configuration.resource_token(
            "https://management.azure.com/", config.subscription, config.tenant_id, timeout=remaining())
        def read(path, version):
            response = client.get("https://management.azure.com" + path, params={"api-version": version},
                                  headers={"Authorization": "Bearer " + access},
                                  timeout=remaining(), follow_redirects=False)
            response.raise_for_status()
            return response.json()

        if not group:
            if not config.resource_group or not config.apim_name:
                return FinOpsError(unknown, 7)
            path = (f"{subscription}/resourceGroups/{quote(config.resource_group, safe='')}"
                    "/providers/Microsoft.ApiManagement/service/"
                    f"{quote(config.apim_name, safe='')}/namedValues/turnstile-integration")
            integration = configuration.parse_integration(read(path, "2024-05-01")["properties"]["value"])
            if (integration["url"].rstrip("/") != config.url.rstrip("/")
                    or integration["scope"] != config.scope):
                return FinOpsError(unknown, 7)
            group = integration.get("resourceGroup", "")
        if not isinstance(group, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,90}", group):
            return FinOpsError(unknown, 7)
        config.turnstile_resource_group = group
        server_path = (f"{subscription}/resourceGroups/{group}"
                       "/providers/Microsoft.DBforPostgreSQL/flexibleServers")
        servers = read(server_path, "2024-08-01")["value"]
        if not isinstance(servers, list):
            return FinOpsError(unknown, 7)
        if len(servers) != 1:
            reason = "No PostgreSQL" if not servers else "Several PostgreSQL"
            return FinOpsError(prefix + f"{reason} servers found in {group}; "
                               "the database could not be identified. No resource was started.", 7)
        server = servers[0]
        if not isinstance(server, dict):
            return FinOpsError(unknown, 7)
        name, state = server.get("name"), server.get("properties", {}).get("state")
        resource_id = server.get("id")
        if (not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", name)
                or not isinstance(resource_id, str) or resource_id.casefold() != f"{server_path}/{name}".casefold()
                or state not in ("Stopped", "Stopping", "Starting", "Ready", "Disabled", "Dropping", "Updating", "Unknown")):
            return FinOpsError(unknown, 7)
        if state == "Stopped":
            command = f"az postgres flexible-server start -g {group} -n {name}"
            if config.subscription:
                command += f" --subscription {config.subscription}"
            return FinOpsError(prefix + f"PostgreSQL server {name} in {group} is Stopped. "
                               f"Start manually: {command}. "
                               "Starting resumes compute charges; AUM did not start it.", 9)
        return FinOpsError(prefix + f"Azure reports PostgreSQL server {name} in {group} as {state}, "
                           "not Stopped. Check the Turnstile API and database connectivity; "
                           "no resource was started.", 7)
    except (FinOpsError, httpx.HTTPError, TimeoutError, ValueError, KeyError, TypeError, AttributeError):
        return FinOpsError(unknown, 7)
