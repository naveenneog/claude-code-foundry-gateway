# Authentication types, measured

The gateway accepts one kind of credential: a Microsoft Entra ID access token
whose audience is `https://cognitiveservices.azure.com` or `https://ai.azure.com`.
How a caller obtains that token differs by who the caller is, and the
differences matter for token lifetime, for Conditional Access, and for how
access is taken away.

## Prerequisites for a review

Use Reader access to the gateway and its supporting resources, and permission
to inspect the relevant Entra groups/applications. No Foundry inference role is
needed merely to review configuration. Select resources using
[Operations](OPERATIONS.md#1-select-the-gateway-and-workspace).

**Portal:** APIM > APIs > Claude API > Policies shows token validation and
entitlement. APIM > Identity shows the backend principal. Foundry > Access
control (IAM) shows its data-plane assignment; Entra ID > Users / Groups /
Enterprise applications shows directory and optional console access.
Use [Architecture](ARCHITECTURE.md) for the complete component map.

The default developer path uses the existing Azure CLI sign-in and Foundry
audience; it needs no custom app registration. The optional resolver, Turnstile
and Desktop-native sign-in have different app registrations and grants. Do not
use a resolver or Turnstile token as the Foundry token.

Everything marked **measured** was run on 2026-09-23 against an API Management
Premium v2 gateway reading entitlement from the projection, with the resolver
and the Foundry account both private
([Deploy the projection privately](SECURE-PROJECTION.md)). To test a credential
without spending model capacity, the request asked for a model its tier may not
call. The gateway then authenticates the caller and resolves entitlement before
it refuses, so a `403 model_not_allowed` means *authenticated and entitled*.

## The matrix

| Caller | How it gets the token | At the gateway | Token lifetime | Status |
|---|---|---|---|---|
| Developer, Azure CLI sign-in | `az login`; Claude Code reads it through `DefaultAzureCredential` | Served. Claude Code CLI 2.1.272 answered `pong` in 9 seconds | 86 minutes | measured |
| Developer, the other audience | `az account get-access-token --resource https://ai.azure.com` | Served. Both audiences are accepted | 67 minutes | measured |
| Managed identity (a container inside the VNet) | `ManagedIdentityCredential` | 150 of 150 requests authorised, entitled through the projection alone | not recorded | measured |
| Service principal with a client secret | Client credentials | `403 permission_error` until entitled; entitled 39 seconds after its projection record was written | **1,445 minutes, about 24 hours** | measured |
| Any caller, wrong audience | For example `https://management.azure.com` | `401` | | measured |
| Any caller, garbled or missing token | | `401` | | measured |
| Developer, device code sign-in | `az login --use-device-code` | Not run here: it needs a person to enter the code | | not measured |
| Workload identity federation | For example GitHub Actions OIDC | Not run here | | not measured |

## What takes access away

**The gateway's entitlement check, not token expiry.** A service principal's
token lived for about 24 hours, so deleting its secret leaves a working token in
circulation for up to a day. What stops it is removing the identity from the
entitlement source. On the projection that took effect within the cache
windows: a refused answer is cached for at most 60 seconds, and an entitled one
for `entitlement-cache-seconds`. The same holds for people: removing a developer
from the Entra group does nothing until the sync publishes it and the cached
answer expires.

Since the 2026-09-24 hardening, both caches are also clipped to the record's
absolute lease. A complete observation grants at most two hours from scan
start; an expired record returns `503`, even on a cache hit. This bounds new
admission, not an already-running stream. The named-value default has no such
lease: if sync stops, stale membership stays until replaced.

**Revocation procedure:** remove every effective tier/group path, publish to the
active store, verify the removed identity is refused, and audit direct Foundry
access. Disable the Entra account as well, but do not equate that with
invalidating an already-issued bearer token. See
[Onboarding](ONBOARDING.md#5-revoke-access).

**Verify:** named-value admins compare with `scripts/Compare-ClaudeEntitlement.ps1`;
projection admins use the private runner comparison and expiry checks in
[Private projection](SECURE-PROJECTION.md#verify). In the portal, inspect Entra
All members and the published store. A portal membership removal alone is not
proof of refusal.

## What data lives where

| Location | Data | Who governs retention/access |
|---|---|---|
| Developer device | Entra token cache, client settings, local conversation history and tool files | Device/identity policies and client retention |
| APIM configuration | Tier/unit limits and, by default, identity membership lists | Azure RBAC; do not put keys in plain named values |
| Log Analytics / Application Insights | Request/token telemetry, user IDs/names, unit, model and client metadata | Workspace/table access, retention and diagnostics settings |
| Optional Cosmos projection | Identity, tier, unit, authorization and freshness metadata | Container-scoped data roles and private networking |
| Optional Turnstile/PostgreSQL | Exported usage/cost, catalog, budgets, people and console session/account data | Turnstile roles, database access and its backup/retention policy |
| Optional customer OTEL collector | Client telemetry; prompts/replies only if content capture is enabled | Customer privacy review and collector configuration |
| Foundry provider | Inference payload and service metadata under the selected hosting terms | Deployment/region and provider agreement, not the gateway's log settings |

Default gateway telemetry does not record prompt/reply bodies; do not generalize
that to local history, MCP tools, optional content capture or every possible APIM
diagnostic configuration. See [Migration: storage](MIGRATION.md#where-history-lives-afterwards-local-or-cloud)
for client controls and [Comparison](COMPARISON.md#4-data-handling--the-nuance-most-people-get-wrong)
for hosting limitations.

Entra tokens remain bearer credentials. Signing claims protects their integrity,
not a stolen token against replay. Keep diagnostic exports private; never print
the full token or share user claims in a public issue.

## Things that surprised us

| Symptom | Cause | What to do |
|---|---|---|
| `az ad app credential reset` fails with `Credential lifetime exceeds the max value allowed as per assigned policy` | A tenant app-management policy caps client-secret lifetime. A 1-year secret was refused, a 7-day one accepted | Use a short secret, a certificate or a federated credential; ask the tenant administrator what the cap is |
| A new secret is refused for the first seconds | Propagation. A token was issued 20 seconds after the secret was created | Retry for up to a minute before treating it as wrong |
| A signed-in developer gets `401 A Microsoft Entra ID token is required. Run 'az login'.` | The token has the wrong audience. The message is the same as for no token at all | Check the client requests `https://cognitiveservices.azure.com`; `az account get-access-token --resource https://cognitiveservices.azure.com` shows what it would get |

## Conditional Access

Device code sign-in happens on a second device, so a policy that requires a
compliant or joined device, or that blocks the device code flow, stops it. That
matters most for Claude Desktop, whose own Entra sign-in uses device code: under
such a policy, use the credential helper the setup installs, which gets its
token from the Azure CLI on the managed machine instead. Service principals and
managed identities are not subject to user Conditional Access policies.
Workload-identity policy and the resource's own authorization still apply;
do not infer that a user MFA policy protects a service principal.
Microsoft's guidance is that organisations "get as close as possible to a
unilateral block on device code flow"
([Block authentication flows with Conditional Access](https://learn.microsoft.com/entra/identity/conditional-access/policy-block-authentication-flows)).

## Next steps

- [Network](NETWORK.md) — client egress and private endpoint boundaries.
- [Data governance](DATA-GOVERNANCE.md) — retention, data discovery and purge limitations.
- [Setup: close the bypass](SETUP.md#42-close-the-bypass) — direct/inherited roles and key access.
- [Turnstile roles](TURNSTILE.md#viewers-and-managers) — console access is not inference entitlement.
