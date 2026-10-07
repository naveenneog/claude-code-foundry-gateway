# Authentication types, measured

The default developer path uses a Microsoft Entra access token with the Cognitive
Services or AI audience. Optional Desktop sign-in profiles record their token type
and gateway audience separately ([Desktop sign-in](../DEVELOPER.md#letting-desktop-do-the-sign-in-itself),
[ADR-0027](adr/0027-claude-desktop-sign-in-choice.md)). Token acquisition,
lifetime, Conditional Access and revocation differ by caller type.
## Quickstart

The reviewer has Reader access to the gateway resources and permission to inspect the relevant Entra users, groups and enterprise applications. The deployment target comes from [Operations](OPERATIONS.md#1-select-the-gateway-and-workspace).

```powershell
$gateway = Get-Content .\onboarding\claude-gateway.json -Raw | ConvertFrom-Json
$rg = $gateway.resourceGroup
$apim = $gateway.apimName
.\scripts\Test-ClaudeHealth.ps1 -ResourceGroup $rg -ApimName $apim
.\scripts\Compare-ClaudeEntitlement.ps1 -ResourceGroup $rg -ApimName $apim
```

**Expected result:** the health command runs its read-only checks (SKU, entitlement sync, named-value headroom, model prices, Foundry bypass and business units) and sends no model request ([`Test-ClaudeHealth.ps1`](../scripts/Test-ClaudeHealth.ps1)); the entitlement comparison identifies whether the selected gateway's published store matches directory membership. Revocation still requires a fresh request from the affected identity or the projection verification path below.

## Prerequisites for a review

<details>

<summary>Prerequisites for a review reference</summary>

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

</details>

## The matrix

<details>

<summary>The matrix reference</summary>

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

</details>

## What takes access away

<details>

<summary>What takes access away reference</summary>

**The gateway's entitlement check, not token expiry.** A service principal's
token lived for about 24 hours, so deleting its secret leaves a working token in
circulation for up to a day. What stops it is removing the identity from the
entitlement source. On the projection that took effect within the cache
windows: a refused answer is cached for at most 60 seconds, and an entitled one
for `entitlement-cache-seconds`. The same holds for people: removing a developer
from the Entra group does nothing until the sync publishes it and the cached
answer expires.

Projection records persist until a sync deletes or changes them. Removal takes
effect after publication plus at most `entitlement-cache-seconds`; a sync-job
outage does not expire existing access. Exported snapshots retain their apply-by
deadline, which is separate from the lifetime of applied records
([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md)). The installer
selects the projection by default; named values remain available within their
capacity ([ADR-0052](adr/0052-cosmos-default-installer.md)).

**Revocation procedure:** remove every effective tier/group path, publish to the
active store, verify the removed identity is refused, and audit direct Foundry
access. Disable the Entra account as well, but do not equate that with
invalidating an already-issued bearer token. See
[Onboarding](ONBOARDING.md#5-revoke-access).

**Verify:** named-value admins compare with `scripts/Compare-ClaudeEntitlement.ps1`;
projection admins use the private runner comparison and expiry checks in
[projection workbook](PROJECTION-WORKBOOK.md#step-5-verify-requests). In the portal, inspect Entra
All members and the published store. A portal membership removal alone is not
proof of refusal.

</details>

## What data lives where

<details>

<summary>What data lives where reference</summary>

| Location | Data | Who governs retention/access |
|---|---|---|
| Developer device | Entra token cache, client settings, local conversation history and tool files | Device/identity policies and client retention |
| APIM configuration | Tier and unit limits, resolver metadata and membership lists when the named-value store is selected | Azure RBAC; do not put keys in plain named values |
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

</details>

## Things that surprised us

<details>

<summary>Things that surprised us reference</summary>

| Symptom | Cause | What to do |
|---|---|---|
| `az ad app credential reset` fails with `Credential lifetime exceeds the max value allowed as per assigned policy` | A tenant app-management policy caps client-secret lifetime. A 1-year secret was refused, a 7-day one accepted | Use a short secret, a certificate or a federated credential; ask the tenant administrator what the cap is |
| A new secret is refused for the first seconds | Propagation. A token was issued 20 seconds after the secret was created | Retry for up to a minute before treating it as wrong |
| A signed-in developer gets `401 A Microsoft Entra ID token is required. Run 'az login'.` | The token has the wrong audience. The message is the same as for no token at all | Check the client requests `https://cognitiveservices.azure.com`; `az account get-access-token --resource https://cognitiveservices.azure.com` shows what it would get |

</details>

## Conditional Access

<details>

<summary>Conditional Access reference</summary>

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

</details>

## Next steps

- [Network](NETWORK.md) — client egress and private endpoint boundaries.
- [Data governance](DATA-GOVERNANCE.md) — retention, data discovery and purge limitations.
- [Setup: close the bypass](SETUP.md#42-close-the-bypass) — direct/inherited roles and key access.
- [Turnstile roles](TURNSTILE.md#viewers-and-managers) — console access is not inference entitlement.
