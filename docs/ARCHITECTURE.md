# Architecture

## The request path

```
Developer workstation                 API Management (v2)                 Microsoft Foundry
─────────────────────                 ───────────────────                 ─────────────────
claude / VS Code panel
  │
  │ az login → DefaultAzureCredential
  │ Authorization: Bearer <user's Entra token>
  │ aud = https://cognitiveservices.azure.com
  │ oid = the actual person
  ▼
                              1. validate-azure-ad-token
                                 signature, issuer, audience, expiry
                              2. read oid / upn from the validated token
                              3. tier lookup against synced allowlists
                                 not listed → 403
                              4. llm-token-limit (tokens/minute, per oid)
                                 exceeded → 429 + Retry-After
                              5. llm-token-limit (tokens/day, per oid)
                                 exceeded → 403
                              6. rate-limit-by-key (requests/minute)
                              7. llm-emit-token-metric → App Insights
                              8. authentication-managed-identity
                                 user token discarded here
                                 │ Authorization: Bearer <gateway MI token>
                                 ▼
                                                              /anthropic/v1/messages
                                                              claude-sonnet-5
                                                              claude-opus-5
```

## Why the identity model works

Claude Code's Foundry mode does not invent a credential. It calls the Azure SDK's
`DefaultAzureCredential`, which on a workstation resolves the `az login` session and on Azure
compute resolves a managed identity. The token it sends is a genuine Entra ID token for the
Cognitive Services data plane.

That has three useful consequences:

1. **Identity is unforgeable.** The `oid` claim is signed by Entra. A developer cannot spoof a
   colleague, and a shared credential cannot exist because there is no credential to share.
2. **No client-side auth work.** No app registration, no custom audience, no device-code flow, no
   token-refresh helper. `az login` is the entire developer-side story.
3. **Offboarding is free.** Remove the person from Entra, or from the group, and access stops.
   Nothing has to be revoked at the endpoint.

The gateway validates that token and then **throws it away**. Foundry never sees it. The call to
Foundry is made with the gateway's own managed identity, which is the only principal holding
`Cognitive Services User` on the account.

This is what turns the gateway from a recommendation into an enforcement point: with developers
removed from the Foundry role, there is no path to the model that does not pass through policy.

## Why an APIM v2 tier

The `llm-token-limit`, `llm-emit-token-metric`, `llm-semantic-cache-*` and `llm-content-safety`
policies support the **Anthropic Messages API** shape only on v2 tiers.

On a classic tier the policy is accepted and appears to work. It simply counts zero tokens
forever, so no budget ever trips. That failure is silent and expensive, which is why this
accelerator refuses anything but a v2 SKU.

## Why tiering is a group, not a config file

Entitlement lives in Entra ID because that is where joiner/mover/leaver already runs. Adding
someone to `claude-code-premium` is an action your identity team can take, audit, and review —
whereas an allowlist in a config file drifts and is nobody's job.

The gateway cannot read group membership directly from the caller's token: the Cognitive Services
audience is a first-party Microsoft resource, and its token has no configurable `groups` claim.
Two ways to close that gap:

| | How | Trade-off |
|---|---|---|
| **Sync** (default) | `Sync-ClaudeAccess.ps1` writes object ids into APIM named values | needs no tenant admin; membership changes lag by one sync |
| **Live Graph lookup** | policy calls Microsoft Graph per request, cached | no lag; needs an admin to grant the gateway identity `GroupMember.Read.All`, which requires admin consent |

Most teams should start with the sync and move to Graph if the lag matters.

## Why the metrics look the way they do

`llm-emit-token-metric` writes to Application Insights custom metrics in the `claudecode`
namespace. Two things are easy to get wrong and both fail silently:

- the APIM diagnostic must have `metrics: true`, or nothing is emitted at all
- the Application Insights component must have `CustomMetricsOptedInType: WithDimensions`, or the
  metric arrives as a bare total with no `User` breakdown — which is exactly the part chargeback
  needs

The Bicep sets both.

Azure Monitor allows 10 dimension keys per metric and APIM uses 5 built-ins, leaving **5 custom
dimensions**. This accelerator spends them on `User`, `UserId`, `Tier`, `Model` and `SessionId`.

## Streaming

Claude Code always streams, and every agent turn is a long-lived SSE response. Two settings keep
that healthy:

- `forward-request timeout="600"` — agent turns can run for minutes
- `buffer-request-body="false"` — requests carry large tool schemas and file context; a 90 KB
  request body is ordinary

Token counting on a streamed response is estimated rather than exact. Anthropic sends final usage
in the terminating `message_delta` event and APIM v2 reads it, but a client that disconnects
mid-stream can under-report. Budgets should be set with a little headroom for that.

## What this deliberately does not do

- **No prompt inspection or logging.** The gateway records token counts and identities, not
  content. Adding `llm-content-safety` is a supported next step if your policy requires it.
- **No semantic caching.** `llm-semantic-cache-*` would cut cost, but caching an agent's tool-using
  turns is rarely safe. Left out on purpose.
- **No cross-region aggregation.** APIM token counters are per gateway. In a multi-region Premium
  deployment a developer's budget is enforced per region, not globally.
