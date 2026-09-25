import json
from datetime import datetime, timezone
import time

import httpx

from .config import az
from .errors import FinOpsError


def tiny_request(config, model="claude-sonnet-5", *, apply=False):
    plan = dict(preview=not apply, action="Send one tiny governed Claude request", model=model,
                effect="Consumes real model tokens and is recorded in the gateway ledger. No bypass endpoint or stored key is used.")
    if not apply:
        return plan
    if not config.resource_group or not config.apim_name:
        raise FinOpsError("Discover the gateway with aum configure before sending an enforcement probe.")
    selected = ("--subscription", config.subscription) if config.subscription else ()
    gateway = json.loads(az("apim", "show", "-g", config.resource_group, "-n", config.apim_name, "-o", "json", *selected))
    url = gateway["gatewayUrl"].rstrip("/") + "/claude/v1/messages"
    token = az("account", "get-access-token", "--resource", "https://cognitiveservices.azure.com",
               "--query", "accessToken", "-o", "tsv", *selected)
    started = time.monotonic()
    try:
        with httpx.Client(timeout=90, follow_redirects=False) as client:
            response = client.post(url, headers={"Authorization": "Bearer " + token,
                "anthropic-version": "2023-06-01", "Content-Type": "application/json"},
                json=dict(model=model, max_tokens=1, messages=[dict(role="user",
                    content="This is a temporary budget enforcement acceptance test. Reply only OK.")]))
        try:
            payload = response.json()
        except ValueError:
            payload = {"error": "Gateway returned a non-JSON response."}
        headers = {key: value for key, value in response.headers.items()
                   if key.startswith(("x-bu-", "x-claude-", "apim-request-id", "x-request-id"))}
        return dict(plan, status_code=response.status_code, headers=headers, usage=payload.get("usage"),
                    error=payload.get("error"), at=datetime.now(timezone.utc).isoformat(),
                    seconds=round(time.monotonic() - started, 3))
    except httpx.HTTPError:
        raise FinOpsError("Gateway probe transport failed. The request may have been processed; inspect the ledger before retrying.", 7) from None
    finally:
        token = ""
