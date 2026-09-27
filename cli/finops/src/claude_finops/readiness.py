"""Read-only Turnstile dependency diagnosis; no resource starts or secret reads."""

import json
import re
import time

from . import config as configuration
from .errors import FinOpsError


def database_failure(config, status=None):
    cause = f"HTTP {status}" if status else "authenticated readiness timed out"
    prefix = f"Turnstile unavailable: {cause}. "
    unknown = prefix + (
        "Database state could not be verified. An Azure administrator can check the "
        "Turnstile deployment's PostgreSQL state; no resource was started. "
        "Direct is a separate Azure-RBAC connection, not a scoped fallback.")
    selected = ("--subscription", config.subscription) if config.subscription else ()
    group = config.turnstile_resource_group
    deadline = time.monotonic() + (2.5 if group else 5.0)

    def read(*args):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FinOpsError("Database diagnostic deadline reached.", 7)
        return configuration.az(*args, *selected, timeout=min(2.5, remaining))

    try:
        if not group:
            if not config.resource_group or not config.apim_name:
                return FinOpsError(unknown, 7)
            integration = configuration.parse_integration(read(
                "apim", "nv", "show", "-g", config.resource_group, "--service-name", config.apim_name,
                "--named-value-id", "turnstile-integration", "--query", "value", "-o", "tsv"))
            if (integration["url"].rstrip("/") != config.url.rstrip("/")
                    or integration["scope"] != config.scope):
                return FinOpsError(unknown, 7)
            group = integration.get("resourceGroup", "")
        if not isinstance(group, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,90}", group):
            return FinOpsError(unknown, 7)
        config.turnstile_resource_group = group
        servers = json.loads(read("postgres", "flexible-server", "list",
                                  "--resource-group", group, "-o", "json", "--only-show-errors"))
        if not isinstance(servers, list):
            return FinOpsError(unknown, 7)
        if len(servers) != 1:
            reason = "No PostgreSQL" if not servers else "Several PostgreSQL"
            return FinOpsError(prefix + f"{reason} servers found in {group}; "
                               "the database could not be identified. No resource was started.", 7)
        server = servers[0]
        if not isinstance(server, dict):
            return FinOpsError(unknown, 7)
        name, state = server.get("name"), server.get("state")
        resource_group = server.get("resourceGroup")
        if (not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", name)
                or not isinstance(resource_group, str) or resource_group.casefold() != group.casefold()
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
    except (FinOpsError, ValueError, TypeError):
        return FinOpsError(unknown, 7)
