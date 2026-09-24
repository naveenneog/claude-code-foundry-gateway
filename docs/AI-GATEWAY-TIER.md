# The API Management AI Gateway tier (preview), beside this gateway

The AI Gateway tier of Azure API Management went into public preview in 2026. It puts model APIs
and MCP tools behind one endpoint, with runtime keys, structured policies and, since August, US
dollar budgets and estimated spend. This article compares it with this repository's gateway and
records what happened when it was deployed for Claude.

Sources, in the order they were trusted:

1. Measured on 2026-09-23 in the test subscription, East US 2.
2. The portal's own documentation and release notes at
   [ai.gateway.azure.com/docs](https://ai.gateway.azure.com/docs), read from the rendered pages,
   and the payloads its code builds.
3. Microsoft Learn: [AI Gateway tier overview](https://learn.microsoft.com/azure/api-management/ai-gateway-overview)
   and [Govern, secure, and operate](https://learn.microsoft.com/azure/api-management/ai-gateway-govern-secure-assets).
4. The deployment shape in
   [Azure-Samples/simple-foundry-hosted-agent-python-aigateway](https://github.com/Azure-Samples/simple-foundry-hosted-agent-python-aigateway).

## Side by side

| | AI Gateway tier (preview) | This gateway |
|---|---|---|
| Who the caller is | A runtime access key in the `api-key` header. Keys are gateway-scoped: one key reaches every published model and tool | Each developer's own Microsoft Entra token. Claude Code, the VS Code extension and Claude Desktop sign in as the person |
| Per-person limits | Not yet. Budgets count per caller identity, "which currently uses the API key"; enforcement for Entra principals is announced as coming | Tier quotas per person, by Entra group; business-unit and team monthly budgets |
| Claude | Anthropic Messages passthrough at `/default/models/anthropic/v1/messages`, no translation between protocols | Anthropic Messages through the gateway, measured with all three clients |
| Token limits | Per minute, hour or day, counted per key or per IP address | Tokens per minute and a daily quota per person |
| Dollar budgets | A US dollar amount per model, on fixed hourly to yearly windows, per key, with per-key overrides since 2026-09-10. Over budget: HTTP 403 `LlmCostQuotaExceeded`, with a small overshoot across instances | Budgets set in dollars and enforced as tokens at list price; blind to cache (U13) |
| Spend reporting | Estimated cost metrics over OpenTelemetry from observed tokens and public model prices, by key and model, with a portal dashboard | The chargeback ledger per person, unit, team and tier; [Turnstile](TURNSTILE.md) as the console |
| Content safety, IP filter | Built-in policies | Not built |
| MCP tools | Federated MCP endpoint with per-tool allow and block rules | Out of scope |
| Price | "Pricing details are coming soon" on the API Management pricing page | The API Management v2 tier you choose ([Get-ClaudeBom.ps1](../scripts/Get-ClaudeBom.ps1)) |
| Regions in preview | East US 2 and Sweden Central (Learn) | Any API Management v2 region |

Learn says governance policies are operational controls, and that financial reporting should use
provider billing or Azure Cost Management. That page predates the cost limits.

## How it is deployed

Measured: the gateway, its connector gateway, monitoring, a managed-identity Foundry provider and a
runtime key deployed in **133 s**.

| Resource | Notes |
|---|---|
| `Microsoft.ApiManagement/service@2025-09-01-preview`, `sku.name: 'AIGateway'` | The gateway. The sample's scripts call `Microsoft.ApiManagement/aigateways` the retired type, although ARM still lists it |
| `Microsoft.Web/connectorGateways@2026-05-01-preview` | Same name as the gateway |
| `service/workspaces/default/modelProviders` | `kind: 'Foundry'`, managed identity for `https://cognitiveservices.azure.com/`. The gateway's identity needs **Foundry User** (`53ca6127-db72-4b80-b1b0-d745d6d5456d`) on the account |
| `.../modelProviders/foundry/models/<name>` | `supportedEndpoints: ['/anthropic/v1/messages']` and the Foundry deployment. Also listed under `service/workspaces/default/models` |
| `service/apiKeys/<name>` | `listSecrets` returns `primaryKey` and `secondaryKey` |
| `service/workspaces/default/telemetryExporters` | Application Insights |

The classic API Management surfaces answer `MethodNotAllowedInPricingTier`.

Policies are inline objects in a model's `properties.policies`, and a PATCH replaces the whole
array, so read before every update. These shapes are the ones the portal's code builds, and ARM
accepted both on a Claude model and read them back unchanged (measured):

```json
{ "type": "tokenLimit", "count": 120000, "period": "minute", "counterKey": ["identity"], "scope": "resource" }
{ "type": "costLimit", "id": "claude-daily", "amount": 100, "period": "day", "counterKey": ["identity"], "scope": "resource" }
```

A `counterKey` given as a string, as in the sample and the documentation's example, is refused:
measured, `Invalid field 'counterKey' specified`. Per-key overrides go in an `overrides` array on
the cost limit; their shape was not tested.

## What happened with Claude

The runtime did not serve a model. Its health endpoint returned 200, but every model route returned
404 `Resource not found`, with or without a key, from provisioning until the last check more than
six hours later. That
held for a Claude model on the Anthropic route and for an OpenAI model on the chat completions
route, and for every path variant tried. So Claude Code, the VS Code extension, Claude Desktop, and
the enforcement of the token and cost limits were **not** tested against it; only their
configuration was.

Not diagnosed. The portal is the supported way to create a gateway and was not used, because its
sign-in asked for a fresh multifactor approval that could not be given unattended. The deployment
followed the published sample's shape, which expects its model route within a minute.

## Which to use

| You need | Use |
|---|---|
| Each developer signed in as themselves, tiers by Entra group, per-person chargeback, Claude Code, VS Code and Desktop | This gateway |
| Dollar budgets per application key with calendar windows, a built-in spend dashboard, content safety, MCP federation | The AI Gateway tier |
| Both | This gateway in front for identity and per-person limits, with the AI Gateway tier behind it as the backend. **Not tested.** The AI Gateway tier would see one key for every developer, so its cost limit becomes one organisation-wide cap, not a per-person one |

Revisit when the tier enforces budgets per Entra principal, which its release notes announce as
coming: that removes the main reason to keep identity in front of it.
