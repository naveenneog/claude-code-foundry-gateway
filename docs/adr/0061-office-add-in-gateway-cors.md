# ADR-0061: Serve Claude Office add-ins through the existing gateway

- **Status:** Accepted for P114
- **Date:** 2026-10-14
- **Packet:** P114
- **Builds on:** [ADR-0050](0050-projection-switch-function.md) and the existing `infra/policy.xml` caller-validation and managed-identity path

## Context

Anthropic's Claude for Microsoft 365 add-in supports Azure AI Foundry through an
organization-owned gateway. The add-in runs in a browser task pane hosted at
`https://pivot.claude.ai`, sends a preflighted request to the gateway, and can
use the same Foundry base URL as Claude Code. The existing gateway already
accepts Cognitive Services Entra tokens, resolves the caller's entitlement, and
replaces the caller token with its managed-identity token before forwarding to
Foundry.

The live gateway probe on 2026-10-14 returned 404 for `OPTIONS /v1/messages`
and returned no `Access-Control-Allow-Origin` header on 401 and 404 responses.
The add-in therefore cannot use the gateway from Office even though the
inference and identity path is otherwise compatible.

Microsoft Learn's APIM `cors` policy reference, retrieved 2026-10-14, states
that the policy handles preflight requests, must be first in the inbound
section, and adds CORS support for browser-based clients:
<https://learn.microsoft.com/en-us/azure/api-management/cors-policy>.
Anthropic's third-party-platform documentation, retrieved 2026-10-14, states
that `azure_base_url` routes Foundry requests through the organization's gateway
and requires CORS:
<https://claude.com/docs/office-agents/third-party-platforms>.

## Decision

Add one API-level APIM `cors` policy as the first inbound policy. Allow only
`https://pivot.claude.ai`, the `GET` and `POST` methods used by the add-in, and
the explicit authentication and Anthropic protocol headers required by the
add-in. Expose only the gateway response headers the add-in may read.

Do not add a second gateway, a shared gateway token, an `OPTIONS` business
operation, or a model-discovery proxy. The Foundry-through-gateway path does
not require `/v1/models`; the add-in uses its Foundry model path and the
gateway's existing model policy. Caller validation, entitlement, budgets,
content safety and managed-identity forwarding remain unchanged.

The packet test proves the policy shape and the live probe proves preflight,
unauthenticated error and origin rejection behavior. If the live probe shows
that APIM does not attach CORS headers to policy-generated errors, the packet
adds the smallest explicit error-path header needed and records that result in
the status evidence.

## Consequences

The existing gateway can be piloted with Office add-ins after a normal policy
deployment and a manifest containing the real Foundry resource name and Entra
app client ID. Outlook remains a separate manifest and still requires the
Microsoft Graph delegated permissions and tenant-wide consent documented by
Anthropic. The browser origin is intentionally narrow; other browser clients
are not admitted by this packet.
