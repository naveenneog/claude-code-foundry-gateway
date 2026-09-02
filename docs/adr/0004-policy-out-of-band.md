# ADR-0004: Keep API Management in the request path; deliver policy out of band

- **Status:** Accepted
- **Date:** 2026-09-03
- **Packet:** P13
- **Deciders:** claude-code-foundry-gateway maintainers
- **Closes:** U4

## Context

P13 needs per-group capability scoping: different tiers getting different models, tools,
permissions and connectors across Claude Code, the VS Code extension and Claude Desktop.

Three mechanisms exist.

**Anthropic's hosted server-managed settings.** Ruled out twice over. They require a Team or
Enterprise plan and network access to `api.anthropic.com`, they are skipped entirely for
third-party-provider sessions, and they cannot do what P13 asks: "Settings apply uniformly to all
users in the organization. Per-group configurations are not yet supported."
([reference](https://code.claude.com/docs/en/server-managed-settings), retrieved 2026-09-03.)

**The Claude apps gateway.** Anthropic's own self-hosted gateway. Microsoft Foundry is a
documented upstream, it ships inside the `claude` binary, it costs no licence fee, and it selects
managed settings by IdP group — everything P13 wants. See U4 for the full reading.

**Endpoint-managed settings per tier.** One MDM profile, registry policy or managed settings file
per entitlement group, which this repository already generates with `New-ClaudeCodePolicy.ps1`.

## The constraint that decides this

The Claude apps gateway is an inference proxy, not a policy service: "a self-hosted service that
sits between your developers' Claude Code clients and your model provider". It holds the upstream
credential and issues its own bearer tokens to developers.

Adopting it therefore replaces the API Management request path. And that path is the product.
Every request carrying the developer's own Entra token, metered against their `oid` and only then
exchanged for the managed identity, is what makes per-developer attribution possible at all. P10
reports on it, P11 and P12 enforce against it. Under a shared gateway credential the provider
sees one caller, and all three go with it.

Chaining the two — apps gateway for policy, API Management for inference — is not documented.
The Foundry upstream takes a `resource` and its own credential, and no documented option forwards
a caller's original token to an intermediate gateway. That is an inference, and this repository
does not ship inferences.

## Decision

Keep API Management in the request path. Deliver policy out of band, per tier.

| Concern | Where it is enforced | Why there |
|---|---|---|
| Entitlement | Gateway policy, from Entra group membership | Server-side. A modified client cannot grant itself access |
| Token budgets, org ceiling, per-user overrides | Gateway policy | Server-side, and already built |
| Model allowlist per tier | Gateway policy | Server-side. A client-side model list is a preference, not a control |
| Tools, permissions, hooks, MCP servers | Per-tier managed settings, delivered by MDM | No server-side option exists that also keeps the request path |
| Claude Desktop tabs — Chat, Cowork, Code | Per-tier managed settings, delivered by MDM | Same |

The split follows one rule: **anything that can be enforced at the gateway is enforced at the
gateway.** Everything else is a management control, and is described as one.

That distinction is not ours to soften. Anthropic states it plainly: "A user who can run a
modified Claude Code binary can bypass any client-side control."
([reference](https://code.claude.com/docs/en/server-managed-settings), retrieved 2026-09-03.)
Tab visibility, permission rules and connector lists are client-side wherever they are delivered
from — including from the Claude apps gateway. Moving them server-side is not among the choices.

## Consequences

+ No new always-on component. The apps gateway would add a Linux service, PostgreSQL, an internal
  load balancer and a private DNS name.
+ Per-developer identity survives at the provider boundary, so P10, P11 and P12 keep working.
+ Per-tier scoping is ahead of Anthropic's hosted server-managed settings, which are org-wide.
+ The model allowlist becomes server-side, which is stronger than any client-delivered list.
− Policy changes ride the MDM cycle rather than taking effect at the next client start.
− An unmanaged device gets no policy. Entitlement and budgets still apply, because those are at
  the gateway, so the exposure is capability scoping only — not access and not spend.
− Two delivery mechanisms to keep in step: gateway policy and MDM profiles.

## How we would know this was wrong

If customers turn out to have no MDM at all, the tradeoff inverts: the apps gateway's settings
delivery stops being redundant and starts being the only option, and losing per-developer
attribution becomes the price of having any policy. The signal to watch is how many deployments
run `New-ClaudeCodePolicy.ps1` and never deploy its output.
