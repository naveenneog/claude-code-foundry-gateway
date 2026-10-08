# Unknowns register

Unknowns are written down before implementation, then closed by research with a citation and a
date, or by an explicitly labelled assumption with its blast radius.

The table is the machine-readable part: `.ironclad/gate.mjs` counts rows marked `OPEN`, and
fails the release stage while any remain. Detail for each one follows below.

| ID | State | Question | Blocks |
|---|---|---|---|
| U175 | RESEARCHED | P108: What is the published list price for `claude-opus-5-5` in the shipped USD price book? Anthropic pricing page retrieved 2026-10-08 lists Claude Opus 5.5 at $4/MTok input, $20/MTok output, $5/MTok 5m cache write, $8/MTok 1h cache write and $0.20/MTok cache hits. | P108 price book |
| U176 | RESEARCHED | P108: Which Claude models can the dynamic Foundry installer offer in the live eastus2 catalog? Source: `az cognitiveservices account list-models`, eastus2, read 2026-10-08 16:30 IST by the lead: `claude-fable-5`, `claude-fable-5-1`, `claude-haiku-4-5`, `claude-haiku-5-5`, `claude-opus-4-1`, `claude-opus-4-5`, `claude-opus-4-6`, `claude-opus-4-7`, `claude-opus-4-8`, `claude-opus-5`, `claude-opus-5-5`, `claude-sonnet-4-5`, `claude-sonnet-4-6`, `claude-sonnet-5`, `claude-sonnet-5-5`. | P108 price book completeness |
| U177 | OPEN | P108: Does the P108 commit restore the P107 live projection gateway and prove stop/raise timing? Explicitly out of scope for this implementation turn; the lead owns criterion 7 live evidence. | P108 live criterion 7 |
| U178 | OPEN | P108: Claude Haiku 5.5 has tiered pricing by prompt size: Anthropic pricing retrieved 2026-10-08 lists one tier for prompts up to 100,000 tokens ($0.10 input, $0.125 5m cache write, $0.20 1h cache write, $0.01 cache hits, $0.50 output per MTok) and another for prompts over 100,000 tokens ($0.50 input, $0.625 5m cache write, $1 1h cache write, $0.05 cache hits, $2.50 output per MTok). The reconciler aggregates per day, so a per-request tier needs the usage query to split by prompt size; until then `claude-haiku-5-5` stays unpriced and an enforced dollar scope whose members use it is refused with `usd_budget_unpriced` naming the model. | P108 Haiku 5.5 pricing |
| U179 | RESEARCHED | P108: Can a newly deployed scheduled reconciler identity fail before Azure RBAC propagation completes, and can the script start/poll it without the Container Apps CLI extension? Microsoft Learn Troubleshoot Azure RBAC, updated 2026-05-24 and read 2026-10-08, says role assignment changes can take up to 10 minutes to take effect. Microsoft Learn Container Apps Jobs - Start REST API for 2024-03-01, read 2026-10-08, documents `POST .../jobs/{jobName}/start?api-version=2024-03-01` and responses of 200 with `JobExecutionBase` or 202 Accepted with headers only. Therefore registration keeps old jobs until a post-deployment execution succeeds and uses ARM `az rest` for start/poll. | P108 reconciler upgrade |
| U180 | ASSUMED | P108: A ledger row with empty `DeploymentName` on a gateway that uses custom deployment names cannot be joined to that custom deployment's cache metric. Blast radius: the unmatched metric can be charged to the user's latest stamped unit and counted twice with same-day body reads, or ignored when all reads for that family are already known. Detector: rows with empty `DeploymentName` on gateways with custom deployment names, plus the live harness custom-deployment case. | P108 residual cache metric attribution |
| U150 | ASSUMED | P103: GitHub repository Outline lists headings that live inside correctly parsed details bodies. Risk: hidden subsection discovery is weaker than expected. Detector: keep every H2 visible and verify representative rendered guides before closure. | P103 rendered review |
| U151 | ASSUMED | P103: GitHub fragment navigation opens a closed details ancestor for H3/H4 targets in supported browsers. Risk: a linked subsection remains hidden. Detector: visible H2 anchors do not depend on it, and rendered review tests representative H3 links. | P103 rendered review |
| U152 | ASSUMED | P103: browser find-in-page reveals matches inside closed details on the supported browser set. Risk: readers miss hidden reference text. Detector: rendered review records browser/version behavior; Quickstart contains mandatory path. | P103 rendered review |
| U153 | ASSUMED | P103: printing from GitHub can include required content when sections are opened or raw Markdown is used. Risk: closed bodies do not appear in formatted print output. Detector: print-preview spot check and documented Raw fallback. | P103 rendered review |
| U154 | ASSUMED | P103: native summary labels give usable disclosure semantics for screen readers. Risk: closed content or summary labels degrade navigation. Detector: labels are plain text, H2 headings stay outside summary, and accessibility review samples converted guides. | P103 accessibility review |
| U155 | RESEARCHED | P103: GitHub supports blank-separated `details`/`summary` collapsed sections with Markdown body content. Sources read 2026-10-06: GitHub collapsed sections and GFM HTML blocks. | P103 structure test |
| U156 | RESEARCHED | P103: visible Markdown headings preserve ordinary GitHub section links better than summary-only headings. Sources read 2026-10-06: GitHub basic writing syntax and GitHub markup pipeline. | P103 structure test |
| U1 | CLOSED | Does a constant counter-key share one counter across callers? Yes — measured 2026-09-02 | P11 unblocked |
| U2 | OPEN | Do emitted token counts reconcile with the Azure invoice? Blocked: this subscription exposes no cost data — measured 2026-09-03 | P12 cost figures |
| U3 | OPEN | Does Claude in Chrome apply under a third-party provider at all? | parity matrix |
| U4 | CLOSED | Can a self-hosted Claude apps gateway serve a Foundry deployment, and is it worth operating? Yes and no — researched 2026-09-03 | P13 unblocked |
| U6 | CLOSED | What signs a plugin, and who verifies it? Nothing, for Claude Code — researched 2026-09-03 | P14 rescoped |
| U7 | CLOSED | Can Log Analytics honour selective deletion within its purge limits? Yes, within 30 days and Analytics-plan tables only — researched 2026-09-03 | P15 unblocked |
| U8 | OPEN | Which OTEL attributes split lines-of-code and tool decisions into their parts? | P10 productivity columns |
| U9 | OPEN | Does `llm-token-limit` have a counter-key cardinality limit? Today's design implies one counter per developer. Narrowed 2026-09-24 on a throwaway Premium v2 instance: 500,000 identities were accepted and charged at about 1,600 requests a second on one unit, but no allowance was exact - one identity was served 540 tokens against a 300-token quota, and 1,000 exhausted identities were admitted again within the hour ([SCALE.md](SCALE.md)) | P22 at scale |
| U10 | OPEN | What does Graph cost in latency and throttling when the volatile cache is cold? | P19 |
| U11 | OPEN | What does the trace ledger cost to ingest, and does a cheaper table plan forfeit purge? | P18, conflicts with U7 |
| U12 | CLOSED | Does APIM telemetry preserve the Claude cache TTL split? No, and the quota scalar excludes cache entirely — measured 2026-09-15 | P18 shipped |
| U13 | OPEN | Can APIM enforce a budget on categorised usage rather than one token total? `llm-token-limit` takes a single `token-quota` and counts prompt and completion only. Narrowed 2026-09-25 by P59 ([ADR-0026](adr/0026-usd-budget-reconciliation.md)): v2 policies recover every Claude usage category from JSON responses, including 5-minute and 1-hour cache creation, and a Decimal reconciler over the logged categories enforces a delayed, scoped dollar stop (measured live: 403 175.9 s after the crossing request). Response-weighted counters accept expression increments but are distributed, deferred and Int32-bounded, and expose no stream-safe final usage. Still open: cache-creation and TTL detail for streaming responses without buffering the stream, so per-request exact streaming-dollar enforcement | P21, P59 |
| U14 | CLOSED | What does the projection resolver add to p99 on a cache miss? Measured 2026-09-23 from inside the VNet, 150 misses against 150 hits: p50 91 against 5 ms, p95 149 against 10, p99 301 against 172, max 389 - a Canada Central gateway reading Cosmos in East US 2, with one always-ready instance. Remeasured 2026-09-24 from outside the VNet, 220 against 220: a miss adds 78 ms at p50 and 134 ms at p99. After idle and under a burst: U18. Remeasured 2026-09-24 with the hardened resolver, 100 misses against 99 hits: 81 ms more at p50, 192 ms more at p99. In a 500,000-record container a point read costs 1 RU, p99 51 ms: that is storage latency, not gateway overhead | P19, [ADR-0013](adr/0013-gateway-outlives-instance.md), [ADR-0017](adr/0017-projection-freshness-and-admission.md) |
| U15 | CLOSED | What forces `publicNetworkAccess: Disabled` on every Cosmos account in this subscription? Azure Policy: `CosmosDB_PublicNetwork_Modify` in the management-group initiative `MCAPSGovDeployPolicies`, which `az policy assignment list` did not show - found through the resource activity log, 2026-09-23 | nothing: the projection is deployed private by design ([SECURE-PROJECTION.md](SECURE-PROJECTION.md)) |
| U16 | OPEN | Why does an AI Gateway tier instance deployed through ARM, in the published sample's shape, serve no model route? Measured 2026-09-23 in East US 2: its status endpoint answered 200, and every model route 404 with or without a key for more than six hours, for a Claude and an OpenAI model ([AI-GATEWAY-TIER.md](AI-GATEWAY-TIER.md)) | P42 |
| U17 | OPEN | Can the projection renewal job's managed identity be granted Microsoft Graph application permission `GroupMember.Read.All` in a live tenant? P86 adds the tenant-admin script and plain `az rest` commands and proves offline that Graph-denied runs write no success evidence. A positive read still needs a tenant where a Privileged Role Administrator or Global Administrator grants the permission; the reference tenant has no such grant. Since P97 ([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md)) only the optional sync job needs the grant; the installer, the switch and `Sync-ClaudeAccess.ps1` use the operator's own sign-in. | P86 live positive Graph proof, [ADR-0045](adr/0045-scheduled-projection-renewal.md) |
| U18 | OPEN | Does the resolver answer inside the gateway's 5-second limit after idle and under a burst of misses? Measured 2026-09-24 on the Premium v2 test gateway: with no always-ready instance, 2 of 3 first requests after 15 minutes idle returned 503; with one, the first burst of 20 concurrent misses for one identity returned four 503s while two new hosts started. Nothing coalesced the concurrent misses ([SCALE.md](SCALE.md)). Narrowed 2026-09-24 after the fix in [ADR-0017](adr/0017-projection-freshness-and-admission.md): two always-ready instances taking 100 concurrent requests each, coalescing within a process, and at most 100 concurrent and 200 misses a second admitted before the resolver. No 503 in the first 20 after deployment (slowest 2,334 ms) or after 16 minutes idle (1,105 ms), nor in bursts of 50 and 100; 500 primed connections at once got 221 retryable 429s and no 503. Still open: bursts of different identities, coalescing across instances, and a larger envelope | P19 |
| U19 | OPEN | Will the reference tenant grant tenant-wide consent for Turnstile's web sign-in (`openid`, `profile`, `email`, `User.Read`)? Only a Cloud Application Administrator, Application Administrator or higher can; users cannot consent here. Measured 2026-09-24: no consent grant exists, and every Entra user sees Need admin approval. Signing in through the Azure CLI (`Open-ClaudeTurnstile.ps1`) needs none. 2026-09-25: a tenant-admin grant needs a support ticket, so none is requested; the consent-free CLI sign-in remains the supported path | P45, [ADR-0016](adr/0016-delegated-management.md) |
| U20 | OPEN | Does AUM (formerly `claude-finops`) stay usable at full directory scale, and do its sources agree? Measured 2026-09-24: the command and terminal faces agreed on identity, budgets, catalog, tiers, month totals and 200 request ids. Measured 2026-09-25 (P52): live Direct and Turnstile journeys created owned test groups, enforced all three modes on real requests and restored every value byte for byte; the manager-only sign-in ran in P53. The gateway-direct source and Turnstile report different totals, because their ingestion, attribution and token definitions differ. Not measured: people search and chargeback export at 500,000 people; request history past 200 (the client supports a cursor no server advertises yet); a mutation journey through the AUM service (its deployment was removed); limiter-counter continuity across a mode change | P51, P52, [ADR-0018](adr/0018-terminal-finops.md) |
| U21 | OPEN | When one account's roles change (a group membership or an app-role assignment removed), how soon does a fresh token reflect it, and can a cached token keep the wider role? Found 2026-09-24 by P53: removing the account from the admin group still left Admin, because it also holds a direct `Turnstile.Admin` assignment, and a fresh token's freshness could not be proven from the token alone. A manager-only proof must check the token's `roles` and `groups` claims before it counts, and abort and restore otherwise. Narrowed 2026-09-25: on Windows the account broker (WAM) keeps serving the cached token after a role change, and neither another scope spelling nor MSAL's `force_refresh` alone renews it; MSAL's `set_access_token_to_renew` does, and with it P53's manager-only proof passed. The same renewal produced fresh AUM.Manager-only tokens for the AUM service's audience (P55, 2026-09-25 03:42Z). Still open: how long Entra, Turnstile and the AUM service take to reflect a change without an explicit renewal | P53, P55 |
| U22 | OPEN | Which callers would a private or edge-only gateway cut off? Measured 2026-09-25 by P54, read-only over seven days on the reference gateway: 5 Entra identities observed and 0 reliable caller addresses, because its GatewayLogs category is off and its Application Insights components mask IP addresses. The access report names those identities and requires their acknowledgement before a change; it cannot show which already have a private route, and it cannot see callers that use Foundry directly. Collecting GatewayLogs and the ledger's `client_ip` for a full business cycle before switching narrows it; addresses that were never logged cannot be recovered | P54, P49, [ADR-0022](adr/0022-enterprise-network-edge.md) |
| U23 | OPEN | Will the reference tenant grant consent for a Claude Desktop public-client app, so Desktop's own Entra sign-in (external-idp, browser or broker) can be proven end to end? Measured 2026-09-26 by P60 on an isolated gateway: an Azure CLI token returned 200 and a wrong-audience token 401, but acquiring a token for the proof Desktop app failed with `AADSTS65001 consent_required`; no tenant-wide consent was attempted, and the owner reports that a tenant-admin grant needs a support ticket. The helper-script default needs no consent | P60, [ADR-0027](adr/0027-claude-desktop-sign-in-choice.md) |
| U24 | OPEN | Does Microsoft Graph `$search` find directory users by a full email address consistently, for members and guests? Measured 2026-09-26 by P64: in the reference tenant `$search` did not return the signed-in owner for their full email, so `aum developer find` falls back to exact `mail`, `userPrincipalName` and `otherMails` filters for a typed address. Partial-email behaviour in a tenant with many guests is not measured ([advanced queries](https://learn.microsoft.com/graph/aad-advanced-queries)) | P64, [ADR-0029](adr/0029-aum-developer-membership.md) |
| U25 | OPEN | How does `aum developer add` and `remove` publish on a gateway whose entitlement comes from the Cosmos projection rather than named values? P64 documents that such a gateway publishes through its projection pipeline after the group write ([AUM.md](AUM.md)); a live add-then-remove through a projection-backed gateway (P61) is not measured | P64, P61 |
| U26 | OPEN | Which checks fail intermittently when the whole suite runs, and why? The "AUM - commands, dashboard and pilot" check (and its predecessor, Terminal FinOps) failed under the full Test-All run on 2026-09-25 (six agents' concurrent load), in the P62 branch gate on 2026-09-26 (~11:41Z), and in the lead's integration gate on `c25d246` (13:06-13:20Z, 141.9 s), each time alone. The same tree then passed directly (320 tests, 134 s), in three concurrent pytest runs (320 each) and in a verbose gate rerun (13:26-13:40Z, 67 of 67). The failing test was not identified, because Test-All's summary does not keep a failing check's output; a rerun that passes is recorded here, not treated as proof. The "Wizard reaches summary on PS 5.1" check behaves the same way: it failed alone in the P61 branch gate (07:14Z) and in the lead's gate on `55b2a17` (13:47-14:00Z, 70.1 s), and passed when run directly (79.6 s). So does "Chargeback report generation": it failed alone after 2.5 s in the lead's gate on 2026-09-26 (17:00-17:14Z) and passed directly (78 assertions, 3.1 s); a P52 gate on 2026-09-25 recorded that check failing once with `Access to the path '...\empty\.building-<id>' is denied` from a directory move. Other workloads were running on the workstation during these gates. On 2026-09-29 P85 split the AUM check into four, "AUM - commands, dashboard and pilot [0/4]" to "[3/4]", after it reached the 600 s per-check timeout ([tests/README.md](../tests/README.md#aum-test-shards)). In P85's gate on 2026-09-29 (18:47-19:17Z) "[3/4]" failed alone without output; pytest's cache named `test_publication_generation.py::test_assistant_context_is_cleared_before_b_request`, which then failed 4 of 12 runs under 16 CPU burners with `NoMatches` for `#main-tabs` raised in `FinOpsApp.switched`, a P71 comparison ([STATUS.md](status/P85.md#delta-council-and-packet-gate-2)). On 2026-09-30 hosted run 36646539868 on main `3b7c192` failed two AUM deadline tests: a zero-millisecond exit check raced asynchronous job termination ([STATUS.md](status/P71.md#p71-follow-up-the-deadline-tests-prove-termination-without-racing-it-2026-09-30)). The p71c packet gate on `edbf6cb` (2026-09-30, 20:03-20:36 IST) failed "Chargeback report generation" alone after 5.2 s, with no output kept; eight concurrent direct runs then passed, and the cause is not established ([STATUS.md](status/P71.md#packet-gate-1-an-unrelated-chargeback-failure)) | P50, P52, P56 |
| U27 | CLOSED | Which Desktop sign-in keys does an installed Claude Desktop read? Researched and measured 2026-09-27: `inferenceIdpOidc`, `inferenceIdpAuthFlow` and the `external-idp` kind need Desktop 2.7032.0; `interactive` with `inferenceGatewayOidc` (1.6889.0) and `inferenceGatewayOidcAuthFlow` (1.25927.0) is read as `external-idp` by later releases, with no end date. The installed 2.2553.1.0 reads neither new key ([detail](#u27--desktop-sign-in-keys-by-release--closed-2026-09-27)) | P67, [ADR-0031](adr/0031-client-keys-every-release-reads.md) |
| U28 | CLOSED | Which Claude Code releases work with `claude-opus-5` and `claude-sonnet-5` through Foundry deployments? Measured 2026-09-27: 2.1.101 returns `400 thinking.type.enabled is not supported`; with `ANTHROPIC_DEFAULT_*_MODEL_SUPPORTED_CAPABILITIES` it answers, and so does 2.1.272 at effort `high` and `max`. Sonnet 5 arrived in 2.1.197 and Opus 5 in 2.1.219 ([detail](#u28--claude-code-releases-and-the-5-series-models--closed-2026-09-27)) | P67, [ADR-0031](adr/0031-client-keys-every-release-reads.md) |
| U29 | OPEN | What made Claude Desktop report `ENOTFOUND` on the owner's workstation on 2026-09-27? Not reproduced here. Its configuration then had no readable credential kind (U27). `Debug-ClaudeWorkstation.ps1` now shows Desktop's own recent `[custom-3p]` warnings and errors from `%LOCALAPPDATA%\Claude-3p\logs\main.log`, which name the failing host | P67 |
| U30 | CLOSED | Can the guided flow create the company address itself, on each v2 tier, and at what cost? Researched 2026-09-28: all three support a custom gateway hostname with an uploaded PFX or Key Vault certificate; none supports a free managed certificate. A public CNAME is required before binding; Basic v2 also rejects an undelegated `.test` domain with `CustomHostnameOwnershipCheckFailed`, measured live. Azure DNS public list prices are USD 0.50/zone/month and USD 0.40/million queries; Key Vault operations USD 0.03/10,000, issuer charges separate. Positive company TLS proof is blocked without a delegated domain ([detail](#u30--the-company-address--closed-2026-09-28)) | P69, [ADR-0033](adr/0033-company-address.md) |
| U31 | CLOSED | Can the flow show the customer's own prices (an agreement's price sheet) instead of Azure retail list prices, and with what role? Researched 2026-09-27: the price sheet of an Enterprise Agreement, Microsoft Customer Agreement or Microsoft Partner Agreement is readable only with a billing role (for MCA: billing profile owner, contributor, reader or invoice manager; for EA: as the Enterprise Admin's policy allows), not with a subscription role, and the API downloads the whole sheet as a file. The flow shows Azure Retail Prices API list prices, named as list prices, and names the price sheet as the authority ([detail](#u31--customer-prices--closed-2026-09-27)) | P68, [ADR-0032](adr/0032-guided-flow-starts-at-once.md) |
| U32 | OPEN | What stops the reference Turnstile database every evening? Measured 2026-09-27 from the activity log: `contoso-e8f7782d` in `contoso-534a5930` (synthetic aliases matching capture 60) was stopped at 19:05Z on 09-23, 09-24 and 09-25 by an application whose token was issued by a tenant other than the subscription's. P71 observed it Stopped at 20:13:35Z on 09-27; that evening's stop started at 19:05:18Z and succeeded at 19:07:19Z. While stopped, Turnstile's `auth/me` waits about 30 s and returns 500, which AUM reports as `Read failed (exit 7)` ([detail](#u32--the-turnstile-database-stops-every-evening--open)) | P71, f10, f11 |
| U37 | ASSUMED | Can the client identify the Turnstile database without reading App Service secrets? The integration records a deployment resource group, not a database id. P71 treats exactly one valid PostgreSQL Flexible Server in that recorded group as the deployment's database; zero/multiple servers, missing metadata, denied reads or malformed names/state cannot establish a stopped database. Risk: an operator can repurpose a single-database group without updating its integration. Detectors cover every negative case, and the error reports Azure's observed state rather than claiming a connection-string match. Azure's inventory contract is documented in [Servers - List By Resource Group](https://learn.microsoft.com/rest/api/postgresql/servers/list-by-resource-group?view=rest-postgresql-2024-08-01), retrieved 2026-09-27 | P71, [ADR-0035](adr/0035-aum-bounded-readiness-and-progressive-reads.md) |
| U36 | CLOSED | Can `Start-ClaudeGateway.ps1` tell a top-level run from a call by another script, on both shells? Measured 2026-09-28: `$MyInvocation.PSCommandPath` is empty at top level and names the calling script otherwise, on PowerShell 7 and 5.1 | P72 unblocked |

---

## P103 documentation quickstart and disclosure assumptions

Research and assumptions for [ADR-0056](adr/0056-documentation-quickstart-and-disclosures.md). Sources were read on 2026-10-06 in the read-only documentation review.

- **U150 ASSUMED.** GitHub's repository-file Outline is expected to list Markdown headings that remain inside a correctly parsed details body. The primary H2 headings stay visible so main navigation does not depend on this assumption.
- **U151 ASSUMED.** Fragment navigation to H3/H4 targets inside closed details is expected to reveal the ancestor disclosure where the browser implements the WHATWG ancestor revealing algorithm. The detector is rendered link testing on representative guides; visible H2 anchors do not depend on reveal.
- **U152 ASSUMED.** Find-in-page reveal is expected on current supported browsers, but exact Firefox/Safari ordinary-ID versions were not established from permitted sources. The detector is browser/version recording during rendered review.
- **U153 ASSUMED.** GitHub printing of closed details was not verified. The detector is a print preview spot check with required sections expanded and the Raw view as a complete-source fallback.
- **U154 ASSUMED.** Native summary/disclosure semantics are expected to be usable with plain labels. The detector is accessibility review of sample converted guides; H2 headings are not placed inside summary.
- **U155 RESEARCHED.** GitHub documents collapsed sections using `details`/`summary` with blank lines around Markdown body content, and GFM documents raw HTML block parsing boundaries.
- **U156 RESEARCHED.** GitHub documents automatic heading links for Markdown headings and custom anchors; custom anchors are not Outline entries. ADR-0056 therefore keeps H2 Markdown headings outside disclosures.

## P100 research before implementation

Researched 2026-10-06 for [ADR-0054](adr/0054-update-flow-entitlement-migration.md), before any P100 code. U131-U134 belong to P99.

| ID | State | Question | Blocks |
|---|---|---|---|
| U135 | CLOSED | Which limits can the projection's resources hit, and how are they read without writing? Read 2026-10-06 and tested read-only against the reference subscription: Cosmos DB accounts, 250 per subscription ([Cosmos DB limits](https://learn.microsoft.com/azure/cosmos-db/concepts-limits), updated 2026-08-25), counted with `az cosmosdb list`; container groups and cores, 100 each per region ([ACI quotas](https://learn.microsoft.com/azure/container-instances/container-instances-resource-and-quota-limits), updated 2026-07-26), read from `Microsoft.ContainerInstance/locations/<region>/usages`; storage accounts, 250 per region, from `az storage account show-usage --location`, which returns one object rather than a list; virtual networks, 1,000 per region, from `az network list-usages --location`, whose values are strings; private DNS zones, 1,000 per subscription, counted with `az network private-dns zone list`; Container Apps environments, 50 per region ([Container Apps quotas](https://learn.microsoft.com/azure/container-apps/quotas), updated 2026-09-24), from `Microsoft.App/locations/<region>/usages`. Limits from [subscription and service limits](https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits) (updated 2026-09-29). The `Microsoft.Quota` provider was not registered in the reference subscription, so the checks use each provider's own usages. | P100 readiness checks |
| U136 | ASSUMED | Can Cosmos DB regional capacity be checked before deploying? No method is documented, and [SECURE-PROJECTION](SECURE-PROJECTION.md) records it as a deployment-time failure. Assumption: the plan shows it as a note. Blast radius: the deployment stops at the Cosmos account, before the switch, and named values keep serving; the remedy is another region. Detector: the deployment's error. | P100 readiness checks |
| U137 | ASSUMED | Does template validation report an Azure Policy denial before any write? A deny assignment stops a matching request before the resource provider receives it ([deny effect](https://learn.microsoft.com/azure/governance/policy/concepts/effect-deny), updated 2025-12-01); the page does not say that `az deployment group validate` evaluates it. Assumption: validation of the projection and network templates reports a `RequestDisallowedByPolicy` denial. Blast radius: a denial that validation misses fails the deployment before the switch. Detector: such a failure after a plan that passed. | P100 readiness checks |
| U138 | CLOSED | Can the plan tell whether the operator may create role assignments, without creating one? Yes: `GET <resource-group>/providers/Microsoft.Authorization/permissions?api-version=2022-04-01` returns the caller's own actions and not-actions, tested 2026-10-06. Contributor excludes `Microsoft.Authorization/*/Write` ([privileged built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged), updated 2026-07-01), so Contributor alone fails the check. | P100 readiness checks |
| U139 | CLOSED | How does the plan check region availability? `az provider show -n <namespace>` lists each resource type's locations, tested 2026-10-06 for `Microsoft.DocumentDB/databaseAccounts`, `Microsoft.ContainerInstance/containerGroups` and `Microsoft.App/managedEnvironments`; `az functionapp list-flexconsumption-locations` lists the Flex Consumption regions (52 on 2026-10-06, East US 2 among them). No narrower region list for Cosmos DB serverless was found ([serverless](https://learn.microsoft.com/azure/cosmos-db/serverless), updated 2026-04-27). | P100 readiness checks |
| U157 | CLOSED | How long after a membership change does Microsoft Graph report it to the transitive-member reads the sync uses? Measured in P101 live run 5 at `591eeb77` on 2026-10-07: 54.3 s from removing the developer from the standard group to the first `Sync-ClaudeAccess.ps1 -User` run whose returned `published_tier` was `none`, and 80.5 s from adding them back to the first run that returned `standard` (one measured pair; the live verifier retries the targeted sync for up to 300 s and records the seconds, so a longer lag fails the run with the last published tier). Earlier live runs did not measure it: two captured only success and error streams, and one was held by the named-value empty-tier guard ([P101 status](status/P101.md#live-run-5-2026-10-07), [ADR-0057](adr/0057-one-sync-command.md)). |
| U158 | CLOSED | Does AUM's Direct publication know the developer's object ID when it publishes? Yes: `developer_change` resolves the developer (`person["id"]`) before it changes the memberships and before it calls `developer_publish` (`cli/finops/src/claude_finops/developer_actions.py:73,119-124`, read 2026-10-07). |
| U159 | ASSUMED | Two syncs on one named-value gateway at the same time each write the whole lists from Entra, and the later write wins. Assumption: both read the same Entra state, so the result is the same; a membership change between the two reads is published by the next sync. Blast radius: one sync interval of a stale tier for one developer. Detector: the whole refresh rewrites every list on every run. |
| U160 | CLOSED | What does the sync do when the gateway's `entitlement-groups` names a group that was deleted? It stops before any write and names the remedy (`-StandardGroup`/`-PremiumGroup` with `-RecordGroups`), as the update flow does for a missing authoritative group ([ADR-0054](adr/0054-update-flow-entitlement-migration.md)). P101 detector: `tests\Test-ProjectionSyncScripts.ps1` assertion `a missing group named by entitlement-groups stops before writes and names the operator remedy`; mutation proof: changing the U160/remedy path failed that detector with the full `P97_SYNC assertions=41` suite, and the security-round suite still passes with `P97_SYNC assertions=49 failed=0` ([P101 status](status/P101.md#council-round-1-findings-and-fixes)). |

---

## P99 research before implementation

Researched and measured on 2026-10-06 for [ADR-0053](adr/0053-parallel-compressed-runner-transfer.md), before any P99 code.

| ID | State | Question | Blocks |
|---|---|---|---|
| U131 | CLOSED | How many `az container exec` calls a second reach one runner when several run at once? Measured 2026-10-06 in East US 2 against a 2-CPU container instance, each exec writing 4,850 characters: 0.16 a second one at a time (6.3 s each), 0.57 at 4, 0.93 at 8, 1.39 at 16 (10.9 s each) and 1.45 at 24 (15.6 s each). All 318 execs succeeded. The [ACI quota page](https://learn.microsoft.com/azure/container-instances/container-instances-resource-and-quota-limits) (updated 2026-07-26, read 2026-10-06) lists no exec limit. | P99 parallelism |
| U132 | CLOSED | How far does a full snapshot compress? A synthetic 500,000-record snapshot in the exporter's format (`scripts/Sync-ClaudeProjection.ps1:260-284`) is 63,152,686 bytes. .NET gzip `Optimal` makes it 12,126,017 bytes (3,327 parts of 4,860 characters), `SmallestSize` 12,860,707, and Brotli 11,641,280; measured 2026-10-06 on PowerShell 7.6.6 (.NET 10.0.12). Random object IDs bound the ratio. | P99 part count |
| U133 | CLOSED | Does Azure Resource Manager throttle 16 execs at once? Writes are limited for each subscription and service principal to a bucket of 200, refilled at 10 a second, and globally to 15 times that ([ARM throttling](https://learn.microsoft.com/azure/azure-resource-manager/management/request-limits-and-throttling), updated 2026-04-03, read 2026-10-06). An exec is a `POST` ([Containers - Execute Command](https://learn.microsoft.com/rest/api/container-instances/containers/execute-command), updated 2026-07-09). Measured 2026-10-06 with `az container exec --debug` against the P99 live runner: the exec's response carried `x-ms-ratelimit-remaining-subscription-writes: 199` and `x-ms-ratelimit-remaining-subscription-global-writes: 2999`, so an exec counts against the write bucket. At up to 1.45 execs a second the transfer uses about 15% of the refill rate. A throttled exec fails and is retried; a part that fails 3 times stops the transfer with nothing written. | P99 parallelism |
| U134 | CLOSED | Does a 500,000-record snapshot arrive, apply and compare through the runner (2 CPU, 4 GB, `infra/projection-network.bicep:293-294`) within its 2-hour apply-by time? Yes, measured 2026-10-06: a 63,150,738-byte snapshot travelled in 41 minutes (3,336 parts, 16 at once), the writer applied 500,000 records in 529 s through one exec session, and `--compare-snapshot` found 0 differences in 28 s; the apply started 78 minutes before the apply-by time ([P99 live run](status/P99.md#live-run)). The operator-side Graph scan of 500,000 developers is not measured (U10). | P99 acceptance |

## P102 research before implementation

Researched 2026-10-06 for [ADR-0055](adr/0055-content-safety-screening.md), before any P102 implementation code.

| ID | State | Question | Blocks |
|---|---|---|---|
| U140 | RESEARCHED | What are the Content Safety text API shapes and per-call limits? `text:analyze` takes `text`, optional `categories` and `outputType`; its `text` field is capped at 10,000 Unicode code points and `FourSeverityLevels` returns 0, 2, 4 and 6. `text:shieldPrompt` takes `userPrompt` and `documents`; the service limits page says Prompt Shields allows a 10,000-character prompt and up to five documents with 10,000 total characters. Read 2026-10-06: [Analyze Text](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/analyze-text?view=rest-contentsafety-2024-09-01), [Shield Prompt](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01), [Content Safety limits](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability). | P102 policy contract |
| U141 | RESEARCHED | What should Prompt Shields documents represent? Prompt Shields describes user prompt attacks as direct attempts to bypass rules, and document attacks as hidden instructions in third-party content; it says document attacks are scanned at user input and tool response intervention points in Foundry. Read 2026-10-06: [Prompt Shields](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/concepts/jailbreak-detection). | P102 request slicing |
| U142 | RESEARCHED | What safety layer already exists for Claude in Foundry? Microsoft's Claude hosting comparison lists `Content safety` as `Anthropic safety systems active` for both Azure-hosted and Anthropic-hosted Claude models. It does not list a configurable Azure content filter for Claude deployments in that table. Read 2026-10-06: [Claude hosting comparison](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-hosting-comparison). | P102 rationale |
| U143 | RESEARCHED | Why not use APIM `llm-content-safety` as the P102 default? Microsoft documents that policy for LLM prompts and completions, Prompt Shields and the four harm categories, but the 2026-10-06 spike measured that it missed harmful Claude `system` strings, harmful `system` blocks and harmful `tool_result`, and blocked a benign prompt over 10,000 characters. The same Microsoft page says request prompts always use a 10,000-character window and over-limit content returns 403. Read 2026-10-06: [APIM llm-content-safety](https://learn.microsoft.com/en-us/azure/api-management/llm-content-safety-policy); spike 2026-10-06. | P102 policy choice |
| U144 | RESEARCHED | What is required for APIM to call Content Safety with managed identity? Microsoft Entra authentication for Foundry Tools requires a custom subdomain and recommends disabling local authentication; APIM's Content Safety policy prerequisites require APIM's managed identity to have Cognitive Services User on the Content Safety resource, a backend URL `https://<name>.cognitiveservices.azure.com`, and managed identity resource `https://cognitiveservices.azure.com`. Read 2026-10-06: [Foundry Tools authentication](https://learn.microsoft.com/en-us/azure/ai-services/authentication), [APIM llm-content-safety](https://learn.microsoft.com/en-us/azure/api-management/llm-content-safety-policy). | P102 deployment |
| U145 | RESEARCHED | Where is Azure AI Content Safety with Prompt Shields available? The Content Safety region table lists direct Azure AI Content Safety availability for Content harms and Prompt Shields across commercial regions including `eastus2`, and states direct Content Safety features that support regional processing remain in the resource region. Read 2026-10-06: [region availability and service limits](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability). | P102 readiness checks |
| U146 | RESEARCHED | What is the list price used for the P102 estimate? The Azure Retail Prices API query `serviceName eq 'Foundry Tools' and productName eq 'Content Safety' and skuName eq 'Standard' and meterName eq 'Standard Text Records'` returned `Standard Text Records`, unit `1K`, USD 0.375 in `eastus2` on 2026-10-06. Query source: [Azure Retail Prices API](https://prices.azure.com/api/retail/prices). | P102 cost estimate |
| U147 | RESEARCHED 2026-10-07 | Does one `text:shieldPrompt` call and one `text:analyze` call bill as two Standard Text Records per screened Claude request? No: the Azure pricing page defines a Standard text record as up to 1,000 characters, measured in Unicode code points, and counts a longer text input as one record for each 1,000 characters (7,500 characters are 8 records). A 10,000-character `analyze` input is 10 records. The first assumption, one record per call, is replaced in the [ADR-0055 council round 2 amendment](adr/0055-content-safety-screening.md#amendment-2026-10-07-p102-council-round-2-prompt-shields-calls-and-text-records). Read 2026-10-07: [Content Safety pricing](https://azure.microsoft.com/en-us/pricing/details/content-safety/). | P102 cost proof |
| U148 | ASSUMED | Does APIM trace metadata land in Application Insights `traces` with the expected custom dimension names on v2 gateways? The APIM trace policy says custom traces can emit Application Insights telemetry with metadata and are not affected by Application Insights sampling. Assumption: the v2 gateway records the source and metadata names as queried in ADR-0055. Blast radius: live evidence KQL needs adjusted field names, not a policy behavior change. Detector: the live P102 KQL check must find a trace row for T1 and for one blocked request before the packet can close. | P102 evidence |
| U149 | ASSUMED | Does Cost Management in the owner's subscription expose Content Safety meter quantities soon enough to verify U147 during P102, or only after invoice latency? Assumption: P102 closes on the published text-record definition (U147) without a Cost Management reading. Blast radius: the per-request record range in ADR-0055 is wrong if the meter counts differently; this changes the cost estimate, not screening. Detector: once usage data for the P102 live-run Content Safety accounts is available, a Cost Management query of meter `Standard Text Records` for those accounts is compared with the runs' screened request counts (P102 follow-up). | P102 cost proof |
| U161 | RESEARCHED | What text length can Azure AI Content Safety `text:analyze` accept? The REST reference says the `text` request field has `maxLength: 10000` and supports a maximum of 10k Unicode characters in one request; `FourSeverityLevels` returns severities 0, 2, 4 and 6. Read 2026-10-07: [Analyze Text](https://learn.microsoft.com/en-us/rest/api/contentsafety/text-operations/analyze-text?view=rest-contentsafety-2024-09-01). | P102 sampling |
| U162 | RESEARCHED | What Prompt Shields input budget is available for user prompts and documents? The service limits page says the Prompt Shields API has a maximum prompt length of 10K characters and up to five documents with 10K total characters. The Prompt Shields concept page describes user prompt attacks as user input and document attacks as third-party content, including tool responses. Read 2026-10-07: [Content Safety service limits](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/region-availability), [Prompt Shields](https://learn.microsoft.com/en-us/azure/ai-services/content-safety/concepts/jailbreak-detection). | P102 document sampling |
| U163 | RESOLVED 2026-10-07 | Does APIM return a stored policy fragment through ARM GET `policyFragments/<id>?format=rawxml&api-version=2024-05-01` in a form whose canonical XML hash equals `infra/<id>.xml`? Assumption: parsing both XML values with whitespace not preserved and hashing the canonical serialization removes line-ending and indentation differences, while APIM does not rewrite expressions, entities or comments into a different canonical XML tree. Blast radius: an updated gateway could repeatedly plan a fragment update after apply. Detector: the P102 upgrade live proof runs the update plan again after apply and fails if migration `0002-policy-and-named-values` still plans a policy fragment change. The 2026-10-07 resolution is withdrawn: upgrade runs 19 and 21 reported no 0002 fragment change only because the code then counted a fragment it could not read as current. Upgrade run 23 showed that the `rawxml` read-back does not parse as XML. A probe on a disposable instance the same day found that `format=xml` returns the stored text encoded once more, and that decoding it once more gives the template's hash; discovery now does that ([ADR-0055](adr/0055-content-safety-screening.md#amendment-2026-10-07-p102-council-round-2-reading-the-fragment-back), [P102 status](status/P102.md#council-round-2-fixes-and-live-runs-22-23-2026-10-07)). Resolved by upgrade runs 24 (`baaa84c4`) and 26 (`de775d73`): the update's check passed, the plan after apply held no 0002 fragment change, and the read-back parsed with no read warning ([P102 status](status/P102.md#council-rounds-3-and-4-fixes-and-live-runs-24-26-2026-10-07)). | P102 update flow |
| U164 | ASSUMED | How does the Standard text-record meter count one Prompt Shields request with a `userPrompt` and documents, and how many characters does a Claude Code request send to each call? The pricing page counts records per text input but does not say whether the prompt and each document are separate inputs. Assumption: they are separate, so one Prompt Shields call is at most 24 records (10 for the prompt, at most 14 for five documents of 10,000 characters in total). Blast radius: the ADR-0055 per-request range is high by up to four records; screening is unaffected. Detector: the U149 Cost Management comparison; the trace records no characters per call, so the share of requests in each cost row needs a trace change outside P102. | P102 cost estimate |
| U165 | RESEARCHED | Can a scheduled Container Apps job execution start while the previous execution still runs? Yes. Scheduled jobs run on Kubernetes CronJobs, and the job does not expose `concurrencyPolicy`; `parallelism` is the number of replicas in one execution (Microsoft reply of 2024-08-26 on [microsoft/azure-container-apps#1271](https://github.com/microsoft/azure-container-apps/issues/1271), open, read 2026-10-08). The sync's apply lock (`sync/src/apply-lock.mjs`, a 300-second lease renewed during the run) lets one run write at a time. A later run waits up to 900 seconds for it (`--lock-wait-seconds`, default at `sync/src/apply-projection.mjs:58`; the job passes no arguments, `infra/projection-renewal.bicep:222`). If the lock is still held, the later run stops at stage `lock` before any write, and the failed-run alert fires. | P104 schedule |
| U166 | RESEARCHED | In which time zone does a job's cron expression run, and how short can its period be? Cron expressions are evaluated in UTC, and the documented examples run every minute (`*/1 * * * *`) and every 5 minutes. Read 2026-10-08: [Jobs in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/jobs) (updated 2026-09-16). | P104 schedule |
| U167 | RESOLVED 2026-10-08 | How long a range can the no-success log search alert read? The query time range can be overridden up to two days, and the evaluation frequency is one minute to one day. Read 2026-10-08: [Create Azure Monitor log search alert rules](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule) (updated 2026-09-22). The assumption that `overrideQueryTimeRange` accepts every range from 75 minutes to 24 hours 15 minutes was refuted by the P104 live run on 2026-10-08: ARM refused the `30m` rule with InvalidRequestContent, "OverrideQueryTimeRange of 75 minutes is not supported. Supported granularities are: 5, 10, 15, 30, 45, 60, 120, 180, 240, 300, 360, 720, 1440, 2880". `az bicep build` does not check the value. The rule now queries the smallest accepted range that covers the no-success time and compares the newest success with that time (`infra/projection-renewal.bicep`); `tests/Test-ProjectionRenewal.ps1` checks the list and the range for every interval, and the live rerun deploys the `30m` rule. | P104 alerts |
| U168 | RESEARCHED | What does the scheduled job cost per interval? Retail Prices API, `eastus2`, read 2026-10-07: Container Apps Standard vCPU active USD 0.000024 per second and memory USD 0.000003 per GiB-second, so the job's 1 vCPU and 2 GiB cost USD 0.00003 per run-second. The first 180,000 vCPU-seconds and 360,000 GiB-seconds per subscription per calendar month are free, and jobs bill at the active rate ([Billing in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/billing), updated 2026-03-25). The grant is shared with every other Container Apps workload in the subscription. | P104 cost |
| U169 | ASSUMED | How many deletions should one unattended run make before it stops? Assumption: max(10, 10% of the existing entitlement records); developers who leave between two runs stay under that, and a larger removal is deliberate. Blast radius: a legitimate large removal waits for an attended `Sync-ClaudeAccess.ps1` run; until then the removed developers keep access. Detector: the `removal-ceiling` failure line names both counts and the attended command, and the failed-run alert fires. | P104 removal ceiling |
| U170 | RESOLVED 2026-10-08 | Does the no-success rule count a `summarize` row that has no datetime column? Its query ends `summarize Succeeded = count() \| where Succeeded == 0`, so when no run succeeded in the range it returns one row without `TimeGenerated`; the rule counts rows with a 5-minute window and one evaluation period. Read 2026-10-08: [Create Azure Monitor log search alert rules](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule) requires a datetime column in the results only to use the number of violations; this rule counts one violation in one period. The row is counted: in the P104 live run, a `30m` job without the Graph grant had no successful run, and the no-success alert fired 6 minutes after its rule was created (Alerts Management API). Since the range fix (U167) the query ends `summarize LastSuccess = max(TimeGenerated) | where isnull(LastSuccess) or LastSuccess < ago(<minutes>m)`, which also returns one row when no run succeeded. P97's rule never reached this question: its query held the literal text `${renewalLogs}`, because Bicep does not interpolate `'''` strings (found by P104). | P104 alerts |

---

## P97 research before implementation

Researched 2026-10-05 and 2026-10-06 for [ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md). U127 and U128 were added at council round 2, U129 and U130 at round 3 ([P97 council](status/P97.md#council)).

| ID | State | Question | Blocks |
|---|---|---|---|
| U124 | CLOSED | Which call tells whether one user is in a set of groups, and with which permissions? Graph `checkMemberGroups` returns, for up to 20 group ids per request, those the user is a transitive member of; for another user it needs User.ReadBasic.All and GroupMember.Read.All, delegated or application ([checkMemberGroups](https://learn.microsoft.com/graph/api/directoryobject-checkmembergroups), updated 2026-06-12, read 2026-10-05). `Sync-ClaudeProjection.ps1 -User` sends batches of at most 20. | P97 targeted sync |
| U125 | CLOSED | Can the runner be started again after its `sleep 10800` ends? Yes: `az container start` starts a container group whose containers terminated on their own ([Stop and start container groups](https://learn.microsoft.com/azure/container-instances/container-instances-stop-start), updated 2025-11-17, read 2026-10-05). The deployer, the switch and `Sync-ClaudeAccess.ps1` start a stopped runner. | P97 runner |
| U126 | CLOSED | Can one sync's writes be atomic? No: Cosmos transactions cover the items of one logical partition key ([Transactional batch](https://learn.microsoft.com/azure/cosmos-db/transactional-batch), updated 2026-04-27, read 2026-10-06), and entitlement records are partitioned by object id. A sync that fails during its writes can leave some of them; it writes no status record ([ADR-0051](adr/0051-persistent-sync-based-cosmos-entitlement.md), consequences). | P97 failure semantics |
| U127 | CLOSED | Can writers be serialised with Cosmos alone? Yes: creating a document whose id exists returns 409 Conflict ([Create a document](https://learn.microsoft.com/rest/api/cosmos-db/create-a-document), read 2026-10-06), and a replace or delete whose `if-match` ETag is no longer current returns 412 Precondition Failed ([Optimistic concurrency](https://learn.microsoft.com/azure/cosmos-db/database-transactions-optimistic-concurrency), read 2026-10-06). The apply lock (ADR-0051 decision 11) is a lease document created by its holder and taken over only by an `if-match` replace after the lease has passed. | P97 apply lock |
| U128 | ASSUMED | Does `Sync-ClaudeAccess.ps1 -User` work for an operator without an Entra directory role? It calls `checkMemberGroups` for another user with the operator's Azure CLI token (`scripts/ClaudeGraphMembership.ps1:25`), and a delegated call is limited to what the signed-in user may read. Proven live on 2026-10-06 with one operator account (the P98 packet's live run 2); a member account without directory roles is not tested. Assumption: default member-user permissions allow the call, as they allow the group-membership reads that the named-value sync makes with the same token. Blast radius: in a tenant that restricts directory reads, the targeted sync stops with the Graph error and its remedy (`Get-ClaudeGraphFailureRemedy`) and writes nothing. | P97 targeted sync for operators without a directory role |
| U129 | CLOSED | Does a query that filters on a path the container does not index fail? Not on this account type: on 2026-10-06 (P98 live run 2) the writer's `WHERE NOT IS_DEFINED(c.type) OR c.type != ...` and the switch evidence's `WHERE c.type = ... AND c.tenantId = ...` returned results from a serverless container that indexes only `/oid/?` (`infra/projection.bicep`), so such a filter is evaluated by reading the records. Microsoft Learn lists a full scan as the least efficient way the query engine evaluates a filter, after the index seek and index scans ([Indexing overview](https://learn.microsoft.com/azure/cosmos-db/index-overview), updated 2026-04-27, read 2026-10-06). Since council round 3 the queries send no `WHERE` clause: status reads use the status partition and entitlement reads filter in the client (ADR-0051 decision 11). | P97 query cost at scale |
| U130 | CLOSED | Does a status record's `ttl` expire it? Only when the container sets `defaultTtl`: with none set, item `ttl` has no effect; with -1, items without `ttl` never expire and items with `ttl` expire after it ([Time to live](https://learn.microsoft.com/azure/cosmos-db/time-to-live), updated 2026-04-27, read 2026-10-06). The container sets -1 since council round 3. | P97 status history |

---

## P95 research before implementation

Researched 2026-10-05, before any P95 code. U120 and U121 were added at council round 1, U122 at
round 2 and U123 at round 3 ([P95 council](status/P95.md#council)).

| ID | State | Question | Blocks |
|---|---|---|---|
| U119 | CLOSED | Does ARM say whether an action group's email receiver receives alerts? Yes: `GET .../Microsoft.Insights/actionGroups/<name>` returns `properties.enabled` and, for each `emailReceivers` entry, `status` `NotSpecified`, `Enabled` or `Disabled`; "Receivers that are not Enabled will not receive any communications", and a disabled group sends to none of its receivers ([Action Groups - Get](https://learn.microsoft.com/rest/api/monitor/action-groups/get?view=rest-monitor-2021-09-01), updated 2026-03-17, read 2026-10-05). Whether a receiver that has not confirmed its passcode reads `Enabled` is not documented; U116 stays an assumption with the live test notification as its detector. | P95 admission |
| U120 | CLOSED | Does a deployment read return the parameter values and outputs of a deployment made with a parameter file? Yes: Deployments - Get returns `properties.parameters` ("Deployment parameters") and `properties.outputs` ("Key/value pairs that represent deployment output") ([Deployments - Get, 2025-04-01](https://learn.microsoft.com/rest/api/resources/deployments/get?view=rest-resources-2025-04-01), updated 2026-08-27, read 2026-10-05). The switch reads the string parameter `cosmosAccountName` and the outputs `resolverUrl` and `resolverAudience` of `projection-resolver-<prefix>`; a secure parameter would not be returned, and none of these is one. | P95 resolver check |
| U121 | CLOSED | Does an exec command with embedded double quotes reach the runner intact? No. Measured 2026-10-05 in council round 1 with the real `az.cmd` and a logged-out isolated profile: `--entrypoint "node /app/sync/src/apply-projection.mjs"` inside `--exec-command` gave "ERROR: unrecognized arguments: /app/sync/src/apply-projection.mjs ..."; without the quotes the command parsed and stopped at sign-in. The runner also splits on spaces with no quoting and URL-decodes the command (`scripts/ClaudeRunner.ps1`, measured 2026-09-23). The entry point now travels base64url-encoded, and `Invoke-RunnerCommand` refuses a quote, `+`, `%` or a `cmd.exe` metacharacter. | P95 admission command |
| U122 | CLOSED | Can the switch read which Cosmos account the live resolver reads, and with what right? Yes: `POST .../Microsoft.Web/sites/{name}/config/appsettings/list` returns the application settings as `properties`, a name-to-value dictionary ([Web Apps - List Application Settings, 2024-04-01](https://learn.microsoft.com/rest/api/appservice/web-apps/list-application-settings?view=rest-appservice-2024-04-01), updated 2025-10-02, read 2026-10-05), and the site's `properties.defaultHostName` comes from Web Apps - Get. The list is an action (`Microsoft.Web/sites/config/list/action`); the Reader role includes only `*/read` for the control plane ([Azure built-in roles, General](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/general#reader), updated 2026-07-01, read 2026-10-05), so the account running the switch needs a role with that action. The settings hold `APPLICATIONINSIGHTS_CONNECTION_STRING`; the switch reads only the four `COSMOS_*`/`PROJECTION_TENANT_ID` values and prints none of the others. | P95 resolver check |
| U123 | CLOSED | How does az report that an API Management instance or its resource group does not exist, so that the installer can tell a new gateway from a failed read? As the ARM error code in parentheses. The Azure CLI prints service errors through azure-core, whose `ODataV4Format.__str__` returns `({code}) {message}` ([azure-core exceptions.py](https://github.com/Azure/azure-sdk-for-python/blob/main/sdk/core/azure-core/azure/core/exceptions.py), lines 276-277, read 2026-10-05), and ARM names a missing resource `ResourceNotFound` and a missing resource group `ResourceGroupNotFound` ([common deployment errors](https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/common-deployment-errors), updated 2026-03-18, read 2026-10-05). The same form was measured for a missing named value (`scripts/ApimNamedValue.ps1:112`), and `scripts/flow/Discovery.ps1:56` reads `apim show` failures by the same rule. If az printed the code in another form, a first installation would stop with "Could not tell whether API Management ... exists" rather than deploy over a gateway. | P95 installer probe |

---

## P94 research before implementation

Researched 2026-10-04, before any P94 code. Rows marked ASSUMED name the blast radius and the
detector; the live detectors are steps in the owner's live runbook, not agent runs.

| ID | State | Question | Blocks |
|---|---|---|---|
| U107 | CLOSED | Where does a Container Apps job's console output land? With `appLogsConfiguration.destination = 'azure-monitor'` and a diagnostic setting, in the resource-specific table `ContainerAppConsoleLogs`, column `Log`, with a `JobName` column; the legacy `log-analytics` destination writes `ContainerAppConsoleLogs_CL` and takes a shared key. [Table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/containerappconsolelogs) (updated 2026-07-28), [migrate to Azure Monitor](https://learn.microsoft.com/azure/container-apps/migrate-logs-azure-monitor) (updated 2026-08-14), read 2026-10-04. `JobName` holds the job's name: [CHARGEBACK-REPORTS.md](CHARGEBACK-REPORTS.md#troubleshoot) records filtering by the exact `JobName` live. | P94 logs and alerts |
| U108 | CLOSED | How does a log search alert count? `timeAggregation: Count` without `metricMeasureColumn` counts result rows, and `summarize` without `by` returns one row even when nothing matched, so a `summarize count()` rule with `GreaterThan 0` fires on every evaluation and one with `LessThan 1` never fires. [Create a log search alert rule](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-log-alert-rule) (updated 2026-09-22), [summarize operator](https://learn.microsoft.com/kusto/query/summarize-operator), read 2026-10-04. P94 rules return rows only in the unhealthy state. | P94 alerts |
| U109 | ASSUMED | Does a rule deploy before its table holds data? `scheduledQueryRules` validates the query at deployment unless `skipQueryValidation` is true ([template reference](https://learn.microsoft.com/azure/templates/microsoft.insights/scheduledqueryrules), read 2026-10-04); community reports say an empty table can still fail. Assumption: every rule reads `union isfuzzy=true` of an empty `datatable` and `ContainerAppConsoleLogs`, which resolves while the table is empty. Blast radius: the renewal deployment fails before the job exists; nothing else changes. Detectors: the template test requires the fuzzy union in every rule; the live runbook's first deployment. | P94 alerts |
| U110 | CLOSED | `unixtime_seconds_todatetime` takes a number of seconds, and `now()` is a datetime, so `unixtime_seconds_todatetime(now())` is a type error. Remaining lease is `unixtime_seconds_todatetime(todouble(x)) - now()`, a timespan. [Function reference](https://learn.microsoft.com/kusto/query/unixtime-seconds-todatetime-function), read 2026-10-04. | P94 alerts |
| U111 | CLOSED | What subnet does the job's environment need? A workload-profiles environment needs at least a `/27`, delegated to `Microsoft.App/environments`, used by that environment only. [Container Apps networking](https://learn.microsoft.com/azure/container-apps/networking) (updated 2026-08-31), read 2026-10-04. The resolver's Flex Consumption subnet carries the same delegation, so the job gets a separate subnet. A job with no ingress needs no private DNS zone of its own (the DNS guidance covers ingress). | P94 network |
| U112 | CLOSED | Does a job with only a user-assigned identity need its client id? Yes: `DefaultAzureCredential` needs `AZURE_CLIENT_ID` or `managedIdentityClientId` ([azure-sdk-for-js identity examples](https://github.com/Azure/azure-sdk-for-js/blob/main/sdk/identity/identity/samples/AzureIdentityExamples.md), read 2026-10-04). The three other jobs set it (`infra/usd-reconciler-job.bicep:194`, `infra/turnstile-schedule.bicep:157`, `infra/chargeback-reports.bicep:327`). | P94 job |
| U113 | ASSUMED | Is the AcrPull grant in effect when the job is created? Container Apps validates an image pull when the image reference changes ([troubleshoot image pulls](https://learn.microsoft.com/azure/container-apps/troubleshoot-image-pull-failures), updated 2026-06-04); no propagation time is documented. Assumption: granting AcrPull in the first phase, before the image build, leaves enough time before the third phase creates the job. Blast radius: the third phase fails with a pull error and the deploy script retries it. Detectors: the deploy test proves the order; the live runbook's first deployment. | P94 deploy |
| U114 | CLOSED | Does `az acr build` work on ACR Basic? Yes: only dedicated agent pools need Premium. ACR task runs are paused for subscriptions on Azure free credits. [ACR Tasks overview](https://learn.microsoft.com/azure/container-registry/container-registry-tasks-overview), [ACR SKUs](https://learn.microsoft.com/azure/container-registry/container-registry-skus), read 2026-10-04. The deploy script stops with the error and names `docker build` and `docker push` as the alternative. | P94 deploy |
| U115 | CLOSED | Does `az acr build --no-logs` wait, and how is the digest read back? It waits for the run to finish; the digest comes from `az acr manifest show-metadata --registry <acr> --name <repository>:<tag> --query digest`. [az acr](https://learn.microsoft.com/cli/azure/acr), [az acr manifest](https://learn.microsoft.com/cli/azure/acr/manifest) (updated 2026-08-04), read 2026-10-04. | P94 deploy |
| U116 | ASSUMED | Do action-group email receivers need confirmation? Azure Monitor documents a one-time passcode that each email receiver confirms within 30 minutes; an unconfirmed receiver gets no notifications once enforcement applies; at most 100 emails an hour per address and region. [Action groups](https://learn.microsoft.com/azure/azure-monitor/alerts/action-groups) (updated 2026-07-29), [service limits](https://learn.microsoft.com/azure/azure-monitor/fundamentals/service-limits), read 2026-10-04. Assumption: receivers created through ARM follow the same rule; ARM exposes no confirmation state. Blast radius: an unconfirmed receiver gets no renewal alert; admission is not affected. Detector: the deploy script prints the step, and the live runbook sends a test notification. | P94 alerts |
| U117 | CLOSED | Can a job identity read `bu-registry` and `bu-parents` through ARM? Both are non-secret named values (`infra/main.bicep:381-383,408-420`); an ARM `GET .../namedValues/<id>` returns `properties.value` for them (`scripts/Get-ClaudeBudget.ps1:57`), and the chargeback job reads named values with a custom role whose only action is `Microsoft.ApiManagement/service/namedValues/read` (`infra/chargeback-reports.bicep:190-197`, `scripts/ClaudeChargebackQuery.ps1:119`). | P94 business units |
| U118 | CLOSED | How long can a Container Apps job name be? 2-32 characters: lowercase letters, numbers and hyphens, starting with a letter and ending with a letter or number ([resource name rules, Microsoft.App](https://learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules#microsoftapp), updated 2026-08-07, read 2026-10-04, which lists `containerApps`; jobs carry the same rule, [microsoft/azure-container-apps#1103](https://github.com/microsoft/azure-container-apps/issues/1103)). The P86 name `caj-projection-renewal-<prefix>` is 23 characters before the prefix, so any prefix longer than 9 failed, while the projection deployer accepts 1-37. P94 names the job and environment with a literal start and `uniqueString` (23 characters) and tags them with the prefix. A resource group that still holds P86's job, environment or `graph-read-failed` alert, which the new names would leave beside the new job, is refused before any write, with the delete commands ([ADR-0049](adr/0049-projection-renewal-deployment.md)). | P94 job name |

## P85 research before implementation

| ID | State | Question | Blocks |
|---|---|---|---|
| U58 | CLOSED | Council round 1's late-read race is reproduced and corrected. The UI pins its plan/confirmation and the existing engine compares all operation-plan fields except the preview flag against the exact resolved snapshot used for writing. All eight early/late catalog, tier and identity pilots pass; equality and forwarding mutations are caught. The explicit fresh-apply CLI path remains. Measured offline 2026-09-29 in the full 865-case pass. [Writer](../cli/finops/src/claude_finops/developer_actions.py), [council pilots](../cli/finops/tests/test_p85_council_plan.py), [evidence](STATUS.md). | P85 reviewed write snapshot bound |
| U59 | CLOSED | Inspected and tested offline 2026-09-29: `Engine.catalog_change` refuses a unit with any child department, the default department, or removal of the last unit. It does not query Entra member counts; an otherwise removable unit/team can still have directory members. The catalog-only write does not remove their Entra memberships or delete groups. All 18 Direct/Turnstile catalog pilots passed, including typed-confirmation and unchanged-membership assertions. [Engine](../cli/finops/src/claude_finops/engine.py), [pilots](../cli/finops/tests/test_p85_catalog.py). Native writer behavior beyond these fixture boundaries is not live evidence. | P85 existing catalog rule recorded |
| U60 | CLOSED | Round 2's cancelled sign-out is reproduced and corrected in application-owned completion handling after registry release. Successful intent survives modal cancellation and other pending mutations; failure stays running with an error, and completed sign-out replaces stale progress. All 18 lifecycle cases pass in the 871-case full run, and owned-completion/release/intent/failure/progress mutations are caught. Measured offline 2026-09-29. [Lifecycle](../cli/finops/src/claude_finops/tui.py), [standard pilots](../cli/finops/tests/test_p85_council_quit.py), [evidence](STATUS.md). | P85 application-owned sign-out completion verified |
| U61 | OPEN | Round 2's alias gap is corrected: pip/uv children receive fresh explicit environments, and pip also uses isolated mode, null configuration and an explicit confined cache. Real offline pip tests cover ordinary and malformed log names; actual pip/uv child environments and retained Azure context for AUM are verified. All 51 launcher/environment cases pass in the 871-case run, with changed/new isolation mutations caught. The remaining unknown is the owner-only live Cloud Shell/network/persistence check, including the documented storage-source conflict in [ADR-0041](adr/0041-aum-session-safety-and-cloud-shell.md) and [P85 STATUS](status/P85.md#p85-follow-up-the-cloud-shell-tests-name-paths-without-git-bashs-tmp-mount-2026-09-30). | Owner-only live Cloud Shell and persistence verification |
| U62 | CLOSED | Reviewed and measured offline 2026-09-30: P85 complies with ADR-0035 through existing protected controls, source guards and application-owned callbacks, without a new boundary or raw output permission. The merge's 91 diagnostics and nine changed contexts are resolved by three reviewed imports, twelve public members, eighteen exact exceptions, six new and nine renewed context digests. All 33 new current/expired-origin, native-log, normalization and source controls pass; all 269 P85 cases pass. Six scratch mutations fail assertions with all 219 baseline identities retained, then restoration passes 219/219. P71's known principal-transition load race remains separately recorded and is not changed. [Review and evidence](status/P85.md#adr-0035-integration-approval-review), [controls](../cli/finops/tests/test_p85_publication_contract.py). | P85 closed-contract integration |

## P80 research before resumed implementation

These four entries were recorded at resume on 2026-09-28, before corrections
to the earlier P80 implementation. They do not retrospectively claim research
or RED evidence for the five existing P80 commits.

| ID | State | Question | Blocks |
|---|---|---|---|
| U38 | CLOSED | People uses the existing `Engine.read("budgets")` catalog on demand. `DeveloperPicker.open_add_form` retains the directory and catalog guards through `ActionForm`; owner restrictions and preview-first membership remain. Offline tests on 2026-09-28 cover owner/non-owner entry, filled email/team, visible catalog errors and refusal of a stale directory result. [Source](../cli/finops/src/claude_finops/developer_screens.py), [tests](../cli/finops/tests/test_p80_usability.py), [ADR-0038](adr/0038-aum-actions-and-connection.md). This does not establish live directory-scale latency. | P80 add-person flow resolved |
| U39 | CLOSED | `Engine.chargeback` enumerates authorized catalog scopes rather than top rankings. One terminal action now saves its CSV through exclusive creation and numbered collision handling; tests cover 137 returned rows, existing/racing files, custom names, JSON metadata and no-write preview. An installed P50 generator appears with its existing owner check and preview. [Engine](../cli/finops/src/claude_finops/engine.py), [file helper](../cli/finops/src/claude_finops/reports.py), [tests](../cli/finops/tests/test_p80_reports.py), inspected and measured offline 2026-09-28. This proves the tested output shape, not live scale or invoice reconciliation. | P80 chargeback flow resolved |
| U40 | CLOSED | Round 2's missing path is reproduced with successful whoami and a real Windows handle held through final validation, failed restoration and UI inspection. Adoption now follows successful transaction exit. Tests retain the old engine/configuration, identity, preferences, capabilities, data, records and modal on failure; a successful-save control proves validation precedes adoption. Reverting that order fails all three new cases. Measured 2026-09-29: all 635 AUM cases passed and all seven new negative probes were caught. [Source](../cli/finops/src/claude_finops/ui_features.py), [end-to-end regressions](../cli/finops/tests/test_p80_connection_recovery.py). | P80 round 2 adoption ordering corrected; round 3 pending |
| U41 | CLOSED | The retained form uses a focusable VerticalScroll feedback area at 80x24. The end-to-end test reconstructs every rendered recovery character using keyboard scrolling while the read-denying Windows handle remains held, including the complete backup path and final recovery step. Clipping, dismissal, missing focus and duplicate notification mutations are caught; top/bottom fixture captures were inspected. The original Settings-label and membership corrections remain. [Recovery tests](../cli/finops/tests/test_p80_connection_recovery.py), [architecture](ARCHITECTURE.md#aum-azure-usage-management---terminal-finops-console), measured 2026-09-29. | P80 round 2 recovery visibility corrected; round 3 pending |

Integration research, 2026-09-30: U39's report-directory creation must be inside
the guarded writer, not before it. U40's local revision errors must surface
without being mistaken for an expired principal; actual exit-3 origin failures
still reject publication. U41's native `scroll_home` defers by default, so
recovery now uses the protected receiver's origin-checked synchronous reset.
The RED counterexamples, current/expired controls and seven count-preserving
removal probes are recorded in [P80 STATUS](status/P80.md#p71-closed-contract-integration-2026-09-30)
and [ADR-0038](adr/0038-aum-actions-and-connection.md#p71-integration-authorization-2026-09-30).
These are offline client-boundary findings, not new live Azure or directory
claims. U38-U41 remain P80's IDs; the separate P71 timing observations are
retained in STATUS without closing U26.

The lead's 2026-09-30 final-main/sharding follow-up retains those four P80
contracts. P71's final exact-type message and absent-main-tab corrections are
reviewed against ADR-0035. P80's complete serial run passed 928 cases in
518.76 s and supplied all 65 file weights; none were assumed from P85.
Its four shard plans are 141/140/140/140 s. The reviewed P85 planner's 300 s
limit is a planned-weight bound, not a measurement of concurrent gate wall
time; that risk remains visible in the P80 STATUS and test-runner documentation.

## P84 research before implementation

| ID | State | Question | Blocks |
|---|---|---|---|
| U54 | CLOSED | Council correction, researched 2026-09-29: allowedToCreateApps describes the default user role, not effective delegated/custom-role permission. Policy.Read.All denial is not app-creation denial. Unreadable, false-default, guest or otherwise unproven rights produce WARN; a supplied ResolverAppId avoids that policy read. Explicit resource/creation denial still fails. Confirmed-absent optional premium is distinct from a failed Graph lookup. Sources and access date: [ADR-0040](adr/0040-projection-preflight-and-switch.md). | P84 revised contract; no live tenant permission claim |
| U55 | CLOSED | Researched 2026-09-29 against all three Bicep templates and Microsoft naming/RBAC docs: nine providers, a 1-37 character safe prefix, and three global name checks. Local Bicep build-params evaluates the existing uniqueString storage name without a deployment; fixture result stres52p2c4jfs43ig. [ADR-0040](adr/0040-projection-preflight-and-switch.md) records API shapes and citations. | P84 contract defined; regional capacity cannot be guaranteed |
| U56 | CLOSED | P86 closes the offline admission gap: ARM cron, bindings, digest and one succeeded execution are not enough. Admission reads destination-bound Cosmos status history and oldest expiry through the in-VNet runner, separately reads the ARM job definition, and rejects stale, missing, wrong-destination, missing-action-group, dry-run, command/args override and single-generation evidence. Live operation and future health remain monitored, not guaranteed. [ADR-0045](adr/0045-scheduled-projection-renewal.md). | P86 offline admission proof complete; live tenant run remains operational evidence |
| U57 | CLOSED | Council round 1 invalidated the earlier safety conclusion despite 240 assertions and 111 mutations. Revised offline proof at eca8b55, 2026-09-29: preflight 197; council 83 including every real Graph caller, en-US/en-GB/de-DE, 100-column output, identity-safe bounded diagnostics and declined confirmation. All 95 current mutations retained complete selected baselines (197/66/14), parsed, failed assertions and exited nonzero; restored suites passed, total 1,356.35 s. Earlier receipts remain historical in STATUS, not proof of rejected admission. | P84 correction proof complete; lead round 2 pending; no Azure writes |

## P78 research before implementation

| ID | State | Question | Blocks |
|---|---|---|---|
| U50 | CLOSED | Can the complete default registration run on hosted Windows without Azure credentials? Measured 2026-09-28: [run 36457223984](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36457223984), exact `f829812`, passes 95/95 registrations with 0 SKIP and both Python environments (320 FinOps tests; 127 AUM service unit tests plus five mutations). Native CLI/HTTP fixtures retain the PS 5.1 boundaries (`tests/TestAzureFixture.ps1:2`). Chromium and full release history are required setup, not optional skips. The first run's isolated projection baseline failure was not explained; later passing runs do not establish a root-cause fix, and its output is now retained. | P78 hosted compatibility measured |
| U51 | CLOSED | How long do whole-check LPT shards take on hosted Windows? [Run 36457223984](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36457223984), accessed 2026-09-28, took 638 s queue-to-merge (10 min 38 s), versus the approximate 44-minute loaded local baseline. Shard jobs took 153-608 s; their Test-All receipts took 55.5-287.4 s. Setup excluding proofs took 87-212 s. The committed table now records all 95 observed passing durations (`tests/test-all-durations.json:1`). One measurement is not a queue SLA or controlled speedup claim. | P78 timing evidence recorded |
| U52 | CLOSED | Can remote evidence be bound to the requested source without trusting a branch name? GitHub workflow runs expose head_sha, run_attempt, status and conclusion; jobs and artifacts are run-scoped. The workflow checks out github.sha; receipts record HEAD and its tree. The helper requires a clean pushed HEAD and revalidates downloaded coverage locally. Workflow dispatch requires the workflow on the default branch; before merge, the packet's push trigger supplies the run. Researched 2026-09-28: [workflow runs API](https://docs.github.com/en/rest/actions/workflow-runs), [workflow dispatch](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch). | P78 remote contract defined |
| U53 | CLOSED | Do the infrastructure detectors reject broken ownership, evidence and workflow setup without losing tests? [Run 36457223984](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36457223984), accessed 2026-09-28, caught 74/74 Core, 12/12 Runner and 9/9 Wizard mutations with complete baseline counts 79/37, 20 and 4/2; restored suites passed. A catch requires valid syntax, the full count, nonzero exit and a failed assertion (`.github/scripts/Test-InfrastructureProof.ps1:1`). One earlier survivor exposed an error regex matching the wrong exception; its diagnostic is now exact. Main `449489b` is merged in `d11dd93`; P79's final process-start probe and new registrations remain. Under P78's own lock, 79 sharding, 37 remote and 68 full RunnerIntegrity assertions passed in 2.2, 1.0 and 214.0 s. | P78 negative and integration evidence recorded |

## P70 research before implementation

| ID | State | Question | Blocks |
|---|---|---|---|
| U34 | CLOSED | Which dated prices and model-name mappings can a model lifecycle change safely write, especially `claude-opus-5-5` and the dotted Haiku entry? Researched 2026-09-28: the published Opus 5.5 input/output rates are USD 4/20 per million, but its cache-read multiplier is 0.05x, not the accelerator's 0.1x. P70 leaves it explicitly unpriced in defaults. An unambiguous Haiku spelling can copy the existing dated USD 1/5 entry; no family-price inference. [ADR-0034](adr/0034-model-lifecycle.md), [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing) | P70 pricing decision resolved; broader cache-rate schema remains separate |
| U35 | CLOSED | How soon does an API Management v2 gateway enforce a changed model named value, and is the entitlement cache involved? Measured on the isolated Basic v2 gateway on 2026-09-27: Haiku returned 403 before the Change and 200 on the first request after it, at 22:01:49Z, 1.6 s after apply returned. The apply included post-write management verification, so this is not a 1.6 s write-propagation bound. The policy reads model lists outside the entitlement cache; no immediate-propagation SLA is claimed. | P70 propagation statement resolved by measurement |

These entries belong to P70; U33 is reserved for the parallel P69 packet.

U35 research, 2026-09-28: the [named-value reference](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties)
describes plain values in policies but promises no propagation interval. Its four-hour refresh
applies to Key Vault secret rotation, not plain model lists. `infra/policy.xml` expands the
model lists in the request's `modelAllowed` expression, outside the entitlement lookup cache.
The isolated P70 request proof measured actual enforcement: `claude-haiku-4-5` returned
`403 error.code=model_not_allowed` at 21:55:00Z and standard-tier 200 at 22:01:49Z after
the reviewed Change. The named-value update took 21.3 s, readback 22.5 s, and the apply
performed further management verification before returning. The first request then took
1.539 s. This demonstrates propagation by that request, not instantaneous application or
a published interval, and does not infer a delay from `entitlement-cache-seconds`.
After the same account moved to the dedicated premium group, Sonnet returned premium-tier
200 at 22:04:28Z and Haiku returned `403 error.code=model_not_allowed` at 22:04:29Z.
The isolated resources, groups and exact shared-Foundry role assignment were deleted;
independent absence checks passed at 22:13:51Z.

## Detail

### U26 - P71 lookup refresh follow-up, 2026-09-30

Round 2 applies one rule to request-kind results too: one target-view refresh
and one detail read, without resetting paging or closing the detail modal.
Pending request selection is consumed by matching `request_id`. The
notice-present branch is for calls made without input; `PrincipalUI.on_event`
clears the notice before dispatching a normal user-started lookup. Eight
request cases failed before the correction (missing view reads or wrong
selection); those cases and the real-input control passed afterward.
The final rule-A proof passed 300 loaded executions and all 1,278 full-suite
identities. Four request mutations were caught without changing test identities.
Current evidence is in [STATUS](status/P71.md#council-round-2-request-lookup-follows-rule-a).

Council found that a principal notice can suppress the activation to which the
initial lookup fix delegated its read. A tab change was therefore not evidence
of refresh ownership. Accepted current-source compound actions now request one
explicit refresh and suppress their redundant activation; the notice is not
cleared, and expired lookup guards still refuse the operation.
The first council-correction stress run retained one WorkerCancelled failure
in 1,920 executions. A delayed native overview-focus event was then shown to
retarget a People lookup despite current focus already being in People.
The protected receiver now checks actual current focus before forwarding.
Final proof passed 1,980 loaded executions and all 1,269 full-suite cases;
four mutation probes caught dropped reads, duplicate activation, notice clearing
and obsolete-focus acceptance. U26 remains OPEN for other observations and the
listed connection-adoption transition. See the current council correction in
[STATUS](status/P71.md#council-correction-a-principal-notice-cannot-drop-a-current-lookup).

[Hosted run 36670519226](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36670519226)
failed the redacted dashboard lookup case with `WorkerCancelled` after
`open_lookup_result`. That action directly requests a view refresh and also
queues one by changing tabs. Held view completion counted two real workers
before the correction. The changed-tab/current-tab controls and original
redaction assertion then passed; four mutations were caught, the four-burner
stress passed 930 executions, and the final full suite passed 1,230 cases.
The first full run's stale snapshot-source witness failure is retained, with
unchanged grids/SVGs verified after regeneration. The evidence is recorded in
[STATUS](status/P71.md#p71-follow-up-a-lookup-starts-one-refresh-2026-09-30).
The scan lists a possible separate duplicate during connection adoption:
`activate_profile` refreshes after `update_access` can force a permitted tab.
That engine/authority transition is not changed here. U26 remains OPEN for it
and the unrelated historical observations.

### U26 - P71 observation, 2026-09-28

The lead's 2026-09-30 follow-up identifies a second, independent lifecycle
failure: the assistant-context case failed 4/12 times under 16 CPU burners
on P85's `bcf8554` P71 base, without the later message-sealing change and
without worker cancellation. `FinOpsApp.switched` queries `active` while
`#main-tabs` is absent. Retained activations reproduce that exact error on
real empty running and shut-down default screens. The new contract requires
ignoring these stale events while preserving live activations; deterministic
and loaded correction evidence is recorded in
[STATUS](status/P71.md#stale-tab-activation-without-main-content-2026-09-30).
Both deterministic cases failed before the presence check; the corrected
targeted/contract selection passed all 14 cases. The expanded 16-burner proof
passed 270 executions over 30 iterations, including both lifecycle cases and
the assistant-context case. The full AUM suite passed all 831 cases.
U26 remains OPEN for its other historical failures.

During P71's refresh changes, full pytest runs identified the exact failing
cases: `test_service_terminal_hides_unoffered_views_and_opens_real_core_tabs`,
`test_preselected_people_team_does_not_trigger_refresh_loop`,
`test_compact_rankings_keep_a_team_and_drill_into_server_filter` and
`test_lookup_jumps_to_scope`. Queued widget focus could reactivate the previous
pane after the worker completed; an already-dismissed modal's row event could
then reach the destination table. P71 makes the focus handoff immediate and
checks the row event's originating table. A deterministic queued-focus mutation
and a modal-origin mutation each fail the full relevant selector; the restored
full AUM run passes 408 tests. This is evidence for these observed failures,
not a retrospective diagnosis of the unrecorded 2026-09-25/26 failures. The
locked packet gate and any failure output are recorded in P71's STATUS section.
The first P71 gate exceeded its 1,800 s suite deadline on 2026-09-27 at 23:33Z.
The surviving runner's own timing receipt recorded AUM PASS in 249.5 s and
guided-flow start FAIL in 225.2 s; the latter passed directly in 90.8 s afterward.
The failed guided-flow assertion was not retained by the gate's timeout branch.
No assertion or timeout was relaxed; the next run retains the original runner's
stdout/stderr as separate evidence.
That second gate passed at `84bddeb` on 2026-09-28 00:22:51Z, with complete
output proving 408 AUM tests passed (192.82 s), and the guided-flow check passed.
U26 remains open for the earlier unrecorded failures; the retry is not a
retrospective explanation for them.
P71 round 3's first integrated run identified two Windows descendant-fixture
marker failures while 466 other cases passed. A direct probe measured venv
interpreter startup above the fixed deadline; the fixture now uses the base
interpreter without site imports, retaining all deadline, marker and process-exit
assertions. All five original containment mutations were reconfirmed at seven
cases each; the next full AUM run passed 468 tests. Exact timings and the failed
run are in P71's STATUS section and private evidence.

Round 6's reviewer observed
`test_navigation_immediately_after_worker_completion_cannot_restore_old_pane`
raise worker cancellation once in a 232-case affected run (1 failed, 231
passed, 337.85 s), then pass alone. The bounded local attempt held the shared
lock from **13:50:34Z to 13:53:17Z on 2026-09-28**. Thirty separate runs of that
case passed, followed by **20 passed in 20.65 s** for `test_progressive_tui.py`.
The attempt used a frozen copy of `829ef40`'s package (the reviewed `dd46186`
production code), with its import path checked before running. No timeout,
assertion or synchronization was changed. This attempt did not reproduce the
reviewer's cancellation; U26 remains open for that result.

### U30 — The company address — CLOSED 2026-09-28

**Answer.** Basic v2, Standard v2 and Premium v2 support custom gateway domains, using either an
uploaded PFX or a certificate held in Key Vault. The [v2 overview][u30-v2] explicitly lists
"Free, managed TLS certificate" as unavailable. The [custom-domain article][u30-domain] says the
same, even though its managed-certificate section also discusses a temporary issuance suspension
ending on June 30, 2026. Ending that suspension does not add v2 support.

| Question | Researched result |
|---|---|
| Gateway hostname on each v2 tier | Supported on all three. Basic v2 and Standard v2 support one custom gateway hostname; Premium v2 supports multiple. The default `<apim>.azure-api.net` gateway remains available ([domain][u30-domain], [feature table][u30-features]). |
| Uploaded certificate | PFX, triple-DES encrypted, private RSA key at least 2,048 bits, hostname in subject/SAN, and complete certificate chain. A password is optional. The issuer's charge is separate ([domain][u30-domain]). |
| Key Vault | The certificate is imported/created as a **certificate**, not an unrelated secret. APIM references its backing `application/x-pkcs12` secret URL in `keyVaultId`. A versionless URL permits rotation; a versioned URL pins a version. Its managed identity needs secret get/list, or the **Key Vault Secrets User** RBAC role. Automatic pickup can take 1-2 days; manual synchronization is available ([domain][u30-domain], [ARM update][u30-arm]). |
| DNS | CNAME from the company hostname to `<apim>.azure-api.net`. `apimuid.<hostname>` TXT with the domain-ownership identifier is needed only for the free managed certificate, which these tiers cannot use. The chosen CA may impose its own issuance records; those belong to issuance, not APIM binding ([domain][u30-domain]). |
| Public or private DNS | The domain article explicitly requires publicly resolvable custom gateway names on Standard v2 and Premium v2. Basic v2 also requires the public CNAME, measured 2026-09-27 at 20:44 UTC: `CustomHostnameOwnershipCheckFailed` for the isolated `.test` hostname. DNS creation and resolution must precede binding; an authoritative-only Azure DNS zone is insufficient. |
| Update duration | Infrastructure changes can take 15 minutes or longer, with longer waits for larger deployments. The v2 overview describes faster certificate/hostname updates but gives no fixed SLA. P69 announces an estimate and uses a bounded 45-minute wait, reporting elapsed time. The gateway continues serving existing requests while updating ([domain][u30-domain], [v2][u30-v2]). |
| Preserving the service | ARM `PATCH` accepts `properties.hostnameConfigurations`. A patch changes that collection without a service `PUT`; P69 retains the other entries in the collection and does not send network, tier or portal settings ([ARM update][u30-arm]). |

**Prices read from the [Azure Retail Prices API][u30-retail] on 2026-09-27 at 20:11 UTC
(2026-09-28 locally).** Consumption rows, USD; these are list prices, not the agreement's price
sheet (**U31**). Public DNS uses `armRegionName = ''`, not an assumed regional meter. Key Vault
below uses `eastus2`, product `Key Vault`, SKU `Standard`, not Managed HSM's hourly instance meter.

| Component and published meter | First tier | Later tier / qualification |
|---|---|---|
| Azure DNS, Public, `Public Zone` | USD 0.50 per zone/month, first 25 zones | USD 0.10 beyond 25. Adding a record to an existing zone does not add another zone. |
| Azure DNS, Public, `Public Queries` | USD 0.40 per million queries | USD 0.20 after 1,000 million. Request count and DNS query count are not interchangeable. |
| Key Vault, Standard, `Operations` | USD 0.03 per 10,000 operations | Usage-based, not a fixed monthly vault fee. |
| Key Vault, Standard, `Certificate Renewal Request` | USD 3 per renewal request | Certificate-authority charges are separate; not every imported certificate uses integrated renewal. |
| API Management, `Basic v2 Unit`, eastus2 | USD 0.20548/hour; USD 150.00 at 730 hours | The existing gateway tier charge continues. A custom domain is a supported feature, not a separate custom-domain retail meter. |
| Certificate issuer / external DNS provider / domain registration | Not priced by these Azure meters | P69 reports this as provider-dependent, not USD 0. No domain is purchased. |

P69 binds a certificate the administrator already owns; it does not claim that Azure issues a
public certificate on v2. DNS and certificate usage stay usage-based in the review. Missing retail
data stays unknown. The isolated proof uses a reserved `.test` name, an uploaded self-signed PFX,
authoritative nameserver queries and a pinned certificate with SNI; it cannot establish public
delegation, public trust or certificate renewal. Azure refused the Basic v2 hostname before TLS
could be measured. No supported way to bypass its ownership validation was found in the cited
custom-domain and ARM references. A positive company-hostname proof needs an administrator-owned,
publicly delegated DNS name; no domain is purchased for P69.

[u30-domain]: https://learn.microsoft.com/azure/api-management/configure-custom-domain
[u30-v2]: https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview
[u30-features]: https://learn.microsoft.com/azure/api-management/api-management-features
[u30-arm]: https://learn.microsoft.com/rest/api/apimanagement/api-management-service/update?view=rest-apimanagement-2024-05-01
[u30-retail]: https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices

### U26 - P71 rounds 6-10 validation

The resumed round 6 full Python run on `36f3088`, under the shared lock from
**16:30:27Z to 16:38:50Z on 2026-09-28**, executed 563 cases:
**560 passed, 3 failed in 498.64 s** (502.38 s wall). The two
`test_azure_deadline.py` cases
`test_timeout_terminates_started_children_and_grandchildren` and
`test_scheduling_delay_before_assignment_cannot_release_uncontained_children`
failed because their child startup markers were absent.
`test_dashboard.py::test_redacted_queries_do_not_leak_through_input_or_filter_echo`
raised `WorkerCancelled` at the worker wait after the lookup handoff.
All 115 publication cases, including the B4/B5 replays, passed in that run.
The original stdout and JUnit report remain in
`.finops-evidence\p71-r6-resume`; [STATUS](status/P71.md#resumed-round-6-proof-on-36f3088)
records the full selection, timings and mutation proof. No second full run,
deadline change or assertion change replaced those failures. Their cause is
not established by this run; U26 remains open.

The round 7 council reports that these three cases passed together with pinned
P71 imports in **4.77 s**. The lead also reports that the round 6 full run
overlapped its P79 gate, which ran at AboveNormal priority from **21:44 to
22:28 IST on 2026-09-28**. This is an observed overlap, not a controlled
reproduction of the cause. Round 7 leaves the assertions and deadlines
unchanged and retains U26 as open after its requested final full-suite run.

Round 7's restored publication selection passed **177 cases in 73.71 s**,
then its one full AUM/FinOps Python run on `530a8dd` passed **625 cases in
247.21 s** (248.95 s wall), from **21:07:43Z to 21:11:52Z on 2026-09-28**
(**02:37:43-02:41:52 IST on 2026-09-29**). Each validation command acquired
and released its own lock. This passing run is not a controlled proof that
the earlier scheduling overlap caused the three failures.

Eight of the 27 round 7 mutation runs also observed
`test_cached_dialog_handoffs_retain_origin_during_deferred_composition[pin-chart]`
raise `KeyError: 'ask'` at the precondition reading
`app._data_guards[app.active]`. This was before the stale-origin assertions
and was observed with several different removals, including AST-only changes.
Each mutation also failed its intended detector case at the full 177-test
count; the setup failures are excluded from the claimed mutation catches.
The pin-chart case passed in the restored selector and full suite. Its cause
is not established; no assertion, deadline or synchronization was changed.
[STATUS](status/P71.md#final-round-7-proof-on-530a8dd) records the individual
receipts and timings. U26 remains open.

Round 8 again observed the pin-chart `KeyError: 'ask'` before the stale-origin
probe (275/276 and 262/263 passed). Its fixture advertises no Ask view, yet
invokes the assistant directly. The response has `ask_reply_guard`; focusing
its answer can activate Ask without creating a view-cache guard. The test's
control was therefore reading the wrong cache. It now uses the completed
reply's guard, the same one used by `action_pin_chart`, and verifies that it
is current before the principal change. All later guard and output assertions
are retained. The corrected 263-case selection passed in 94.00 s.
This is a test-control correction, not a production timing fix or a diagnosis
of the earlier Windows marker and worker-cancellation failures. U26 remains
open, with all failing receipts retained.

Following that control correction, all 26 round 8 removal probes executed
their complete 263-case selectors without the pin-chart setup failure.
The restored selector passed **263 in 89.18 s**, and the requested one full
AUM/FinOps run passed **711 in 267.15 s** (269.77 s wall), under its own lock
from **00:57:04Z to 01:01:34Z on 2026-09-29** (**06:27:04-06:31:34 IST**).
The failing pre-correction receipts remain in `.finops-evidence\p71-r8`.
This supports the test-control correction; it does not establish the cause
of the older Windows marker or worker-cancellation failures. U26 remains open.

Round 9's restored selector passed **322 cases in 106.32 s**. Its requested
one full AUM/FinOps run on `125f352` passed **770 cases in 283.15 s**
(285.94 s wall), under its own lock from **03:43:39Z to 03:48:25Z on
2026-09-29** (**09:13:39-09:18:25 IST**). All notification and prior
publication cases were included. No historical failure was reproduced or
diagnosed by that passing run; U26 remains open. The receipts are in
`.finops-evidence\p71-r9` and the [round 9 STATUS record](status/P71.md#final-round-9-proof-on-125f352).

Round 10's first expanded publication selector had **358 passed, 3 failed in
166.58 s**. The request-action case raised `WorkerCancelled`, then `NoMatches`
during shutdown, and passed in the isolated follow-up; that pass does not
establish its cause. The people-selector failure was reproducible and traced
to a new native cached-paint refusal cancelling a newer source read; the native
adapter correction separates that paint refusal from write/input rejection.
The notification failure preceded the current-toast assertion; the positive
control now waits for visible text instead of assuming one pause completes
mounting. The original receipts remain in the
[round 10 record](status/P71.md#council-round-10-corrections). U26 stays open.
Its second expanded selector had **358 passed, 4 failed in 172.79 s**:
`test_cached_dialog_handoffs_retain_origin_during_deferred_composition`
(`pin-chart`, `request-form`), the delayed `people-selector` case and
`test_guarded_deferral_reenters_at_execution_and_keeps_input_usable`.
Each raised `WorkerCancelled` at startup or after navigation; two also raised `NoMatches` during
shutdown. The later 48-case runtime control passed, but that pass does not
diagnose these intermittent cancellations.

The requested one full round 10 run on `70b6919` executed **810 cases:
806 passed, 4 failed in 360.31 s** (363.59 s wall), under its own lock from
**2026-09-29 18:22:17Z to 18:28:21Z**. Both `budgets` and `requests` variants
of `test_deferred_detail_retains_cached_or_fresh_origin_after_b_verifies`,
`test_principal_change_closes_prior_forms_and_clears_state_before_input` and
`test_approval_paging_and_queue_change_reset_cursor` raised `WorkerCancelled`
at a worker wait. The first three also raised `NoMatches` during shutdown.
All 40 new native/diagnostic cases passed. No timeout or assertion was relaxed,
and no second full run replaced this result. The cause remains unproven; U26
stays open. Full output, JUnit and the lock receipt are in
`.finops-evidence\p71-r10-resume`; see the
[round 10 full-run record](status/P71.md#final-round-10-full-aum-run-on-70b6919).

The 2026-09-30 builder traced the four reported identities' first failure to
exclusive refresh cancellation, with `NoMatches` occurring during shutdown.
Round-10 diagnostic message subclasses evade Textual 6.12.0's exact-type
`prevent()` and disabled-message checks. A direct prevention probe fails
deterministically, and a single budgets navigation starts two workers and
cancels the first. This identifies a concrete cause introduced by `f122985`.
All 12 deterministic regressions failed before the correction; the initial
16-case corrected selection passed. Loaded RED had 4 failures in 16 completed
cases before another gate interrupted the harness. Loaded GREEN then passed
30 complete iterations / 120 executions under four CPU burners with zero
failures. The final complete AUM invocation passed all 829 cases in 585.16 s,
including four 60-second gate pauses between tests, with no errors, skips or
failed-test retries. Its production source matches the loaded proof; see the
[startup correction](status/P71.md#startup-and-navigation-cancellation-correction-2026-09-30).
The first complete corrected-source run had 828 passes and one
`FooterKey-description` setup failure: Textual removes and asynchronously
remounts footer keys after a binding change, outside worker completion.
The existing privacy probe now awaits the native after-refresh callback and
batch lock before accessing the current receiver; all original guard assertions stay.
An event-held remove/remount gap produced 2 failures and 2 passes before that
await; all 4 cases passed afterward, without a clock-based readiness allowance.
It does not establish the cause of the older Windows marker, wizard,
chargeback or unrecorded failures; U26 remains OPEN.

### U1 — Does APIM support a shared counter across all principals? — CLOSED 2026-09-02

**Answer: yes.** A constant `counter-key` is a single counter shared by every caller. P11 can
enforce the org ceiling in the request path; the scheduled-job fallback is not needed.

**Measured, not inferred.** A throwaway API (`u1-counter-test`) was added to the live gateway
alongside the untouched `claude-foundry` API, carrying two `llm-token-limit` policies: one keyed
on an `x-test-user` header with a 100,000-token quota, one keyed on the constant
`u1-org-constant` with a 400-token quota. Both hourly. Entra validation was kept so the route
was never unauthenticated. The API was deleted immediately afterwards and the live API verified
still serving 200 with entitlement intact.

Using a header for caller identity removed the blocker that had held this open — proving a
*shared* counter needs two callers, and one operator presents one Entra token. The counter-key
mechanism is the same whichever way identity is established.

```
alice  200  org-remaining=319   user-remaining=99919
alice  200  org-remaining=238   user-remaining=99838
alice  200  org-remaining=157   user-remaining=99757
alice  200  org-remaining=76    user-remaining=99676
alice  200  org-remaining=0     user-remaining=99595
alice  403
bob    403   <- had spent none of its own quota
carol  403   <- had spent none of its own quota
```

Two counters moved independently in the same response: `x-org-remaining` fell to zero while
alice's own `x-user-remaining` still showed 99,595. Then two callers who had spent nothing were
refused. That is a shared counter.

**Design consequences for P11**, from the
[`llm-token-limit` reference](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
(retrieved 2026-09-02) and confirmed above:

| Point | Consequence |
|---|---|
| `Monthly` is a valid `token-quota-period` — `Hourly`, `Daily`, `Weekly`, `Monthly`, `Yearly` | The org ceiling can be monthly as the customer asked. Windows start at the UTC timestamp truncated to the unit |
| "For each key value, a single counter is used for all scopes" | Confirmed by measurement |
| "This policy can be used multiple times per policy definition" | The org counter sits alongside the two existing per-user policies |
| "High-concurrency requests can temporarily exceed the configured token limit" | The ceiling is a **soft cap**. It must not be described as a hard spend guarantee |
| Remaining quota "may be larger than expected based on actual token usage" | Any month-to-date figure surfaced in P12 is an estimate |
| Reusing one `counter-key` across scopes needs matching `tokens-per-minute` | The org counter takes its own key at a single scope |

The refusal is `403`, matching the existing daily-quota behaviour, so the developer-facing
message needs to distinguish "your budget" from "the organisation's budget" or the 403 will be
misread as an entitlement problem.

### U2 — Cost attribution accuracy against the Azure invoice

**Question.** The gateway meters tokens via `llm-emit-token-metric`. Claude's analytics API
reports an `estimated_cost` in cents. Whether token counts multiplied by Foundry list price
reconcile with the actual Azure invoice, and within what margin, is unmeasured.

**Why it matters.** P12 exposes month-to-date spend. Reporting a figure that does not match
the invoice is worse than reporting tokens alone, which is why `Get-ClaudeBudget.ps1` reports
tokens and sets `cost_reported: false`.

**Attempted 2026-09-03, and blocked by the environment, not by the method.** August is closed, so
the reconciliation should have been possible. It is not, on this subscription:

| Check | Result |
|---|---|
| `az consumption usage list` for August | 1,002 records returned |
| Records carrying `pretaxCost` | **0 of 1,002** |
| Records carrying `usageQuantity` | **0 of 1,002** |
| `az billing account list` | empty |
| Cost Management query API | blocked before reaching Azure |

The subscription is an internal MCAPS allocation, which returns usage records with the cost and
quantity fields empty. No amount of querying fixes that from inside the subscription.

**How to close.** Run the reconciliation where the cost data is visible:

1. On a subscription whose principal holds **Cost Management Reader**, or an EA/MCA
   **Billing Reader** on the enrolment.
2. Take one closed month of Foundry cost for the account, grouped by meter.
3. Take the same month's tokens from the gateway's Application Insights — note that a redeploy
   may have split them across two workspaces, as happened here on 2026-08-31, so check both with
   `scripts/Get-ClaudeTelemetry.ps1`.
4. Divide to get an effective price per million input and output tokens, and record the margin
   against Foundry list price.

Until that runs, `estimated_cost` keeps `is_estimate: true` and `Get-ClaudeBudget.ps1` keeps
reporting tokens rather than money. Both are correct as they stand; what is missing is the
evidence that would let them report money.

### U3 — Claude in Chrome under a third-party provider

**Question.** Claude Enterprise exposes Chrome controls in org settings. Whether the Chrome
extension works against a third-party provider at all, and whether any managed key governs it,
is unconfirmed.

**How to close.** Check the Claude Desktop 3P configuration reference and the Chrome extension
documentation. If it does not apply, record it as N/A rather than a gap.

### U4 — Server-managed settings without MDM — CLOSED 2026-09-03

**Answer: it can serve Foundry, and it is not the right component for this accelerator.**

The Claude apps gateway is real, documented, and Microsoft Foundry is a first-class upstream. The
page is titled "Claude apps gateway for Amazon Bedrock, Claude Platform on AWS, Google Cloud, and
Microsoft Foundry" ([reference](https://code.claude.com/docs/en/claude-apps-gateway), retrieved
2026-09-03). It ships inside the `claude` binary and runs with `claude gateway --config
gateway.yaml`, so there is no separate product to buy, and there is "no separate license or
per-seat fee".

It does what this repository would want from it. Managed settings are selected by IdP group —
"your IdP groups map to model allowlists and managed settings policies" — and it "delivers
managed settings to signed-in clients itself, taking the place of server-managed settings from
the claude.ai admin console". Model access is enforced server-side.

**Why it is still not adopted here.** It is an inference proxy, not a policy service: "a
self-hosted service that sits between your developers' Claude Code clients and your model
provider". No policy-only mode is documented. It holds the upstream credential itself, and issues
its own short-lived bearer tokens to developers.

That is the one thing this accelerator will not give up. The gateway's value here is that every
request carries the developer's own Entra token, is metered against their `oid`, and is only then
swapped for the managed identity. Under the Claude apps gateway the provider sees one shared
gateway credential, so per-developer attribution at the provider is gone — and with it P10, P11
and P12.

| | Claude apps gateway | This accelerator |
|---|---|---|
| Foundry upstream | Documented | Yes |
| Developer identity reaching the provider boundary | One shared gateway credential | The developer's own Entra token, per request |
| Per-group managed settings | Server-delivered | Per-tier MDM profile |
| Per-group model allowlist | Server-side | Server-side, at the gateway policy |
| Spend limits | Per user and group | Per user, per tier, and org-wide |
| Always-on components | Gateway plus PostgreSQL plus load balancer | API Management only |
| Network exposure | Private addresses only — "Claude Code only connects to a gateway whose address is private" | Public endpoint, Entra-authenticated |

Chaining the two was considered and is **not documented**: the apps gateway's Foundry upstream
takes a `resource` and its own credential, and nothing in the reference describes forwarding a
caller's original Entra token to an intermediate API Management instance. That is left as an
inference nobody should make.

**The finding that decides P13.** Anthropic's own hosted server-managed settings state: "Settings
apply uniformly to all users in the organization. Per-group configurations are not yet supported"
([reference](https://code.claude.com/docs/en/server-managed-settings), retrieved 2026-09-03). So
per-tier MDM profiles are not a downgrade from the hosted option — for per-group scoping they are
ahead of it. P13 is one profile per tier, plus a server-side model allowlist at the gateway,
where it cannot be bypassed by editing a client.

**When the apps gateway is the right answer.** An organisation that has no API Management
instance and no wish to run one, that needs data residency through its own cloud provider, and
that does not need per-developer attribution at the provider boundary. That is a different
customer from this repository's.

### U6 — Plugin signing and trust — CLOSED 2026-09-03

**Question.** A plugin marketplace can be hosted in git or over HTTPS.
`isDesktopExtensionSignatureRequired` exists for `.mcpb` extensions. What signs a plugin, who
verifies it, and whether the same trust applies to marketplace-delivered plugins?

**Answer: nothing signs a Claude Code plugin. This changes P14's acceptance criterion.**

P14 was written to accept "a pinned marketplace delivers a signed plugin to a managed desktop,
and an unsigned one is refused". That test cannot be written, because for Claude Code there is no
signature to check.

| Artefact | Publisher signature | Integrity pinning |
|---|---|---|
| Claude Code plugin | **None documented** | Git source: full 40-character commit `sha`. HTTPS archive: `sha256`, and "Claude Code verifies every download against it and refuses the install on a mismatch" |
| Claude Code marketplace catalog | **None documented** | Branch or tag `ref` only — **not** a commit sha |
| Claude Desktop `.mcpb` | **Yes.** Detached PKCS#7/CMS over SHA-256, chain validated against the OS trust store | Signature covers bundle content |

For Claude Code the documentation has no signature field, no publisher trust root, no signed-commit
verification, no attestation check and no "require signed plugins" setting. Anthropic says so
directly: "Anthropic doesn't control what MCP servers, files, or other software are included in
plugins and can't verify that they work as intended"
([reference](https://code.claude.com/docs/en/discover-plugins), retrieved 2026-09-03).

Pinning a commit sha or an archive hash proves the content is the content that was reviewed. It
does not prove who wrote it, and the expected hash is itself only as trustworthy as the catalog
it is read from — and the catalog cannot be pinned to a commit, only to a branch or tag.

**Claude Desktop is the exception.** `isDesktopExtensionSignatureRequired` "reject[s] desktop
extensions that are not signed by a trusted publisher. Defaults to `false`"
([reference](https://claude.com/docs/third-party/claude-desktop/configuration), retrieved
2026-09-03). Bundles are signed with `mcpb sign` using an X.509 code-signing certificate, and
verification validates the chain against the operating system's trust store — `security
verify-cert -p codeSign` on macOS, `X509Chain` with OID 1.3.6.1.5.5.7.3.3 on Windows. There is no
Anthropic CA. Whether an existing Authenticode or Apple Developer ID certificate is accepted is
not documented.

**Blast radius, which is why this matters.** A plugin contributes hooks, commands, agents and MCP
servers, and runs as native code with the user's privileges. The only documented sandbox is the
Bash tool sandbox: unavailable on native Windows without WSL2, and not documented as covering
hook, MCP or LSP processes. There is no plugin-wide sandbox, and no Anthropic-operated vetted
registry or approval workflow.

**Admin controls that do exist**, all managed-settings keys:

| Key | Effect |
|---|---|
| `strictKnownMarketplaces` | Only listed marketplaces may be used |
| `extraKnownMarketplaces` | Provisions marketplaces; does not restrict others on its own |
| `blockedMarketplaces` | Explicit blocklist |
| `enabledPlugins` | `plugin@marketplace` to boolean. Managed `false` blocks installation and hides it |
| `disableSideloadFlags` | Rejects `--plugin-dir`, `--plugin-url`, `--agents`, `--mcp-config` |
| `disableCommandPluginSources` | Blocks command-source plugins |
| `disableSkillShellExecution` | Blocks inline shell in skills and custom commands |
| `allowedMcpServers`, `allowManagedMcpServersOnly` | Restricts MCP servers, including plugin-provided ones |

**P14's acceptance criterion is therefore restated** as two claims that can each be tested:

1. Claude Code — an approved plugin pinned to a commit sha or archive hash installs, and a
   modified one is refused on hash mismatch. Marketplaces outside the allowlist are rejected.
2. Claude Desktop — with `isDesktopExtensionSignatureRequired` set, a bundle signed by a trusted
   publisher installs and an unsigned one does not.

What must not be claimed is universal signed-plugin enforcement. It does not exist for Claude
Code, and a marketplace does not add verification — it is a distribution convenience, and the
same trust model applies to marketplace-delivered and locally installed plugins alike.

### U7 — Selective deletion of captured content — CLOSED 2026-09-03

**Question.** The Compliance API supports deleting specific records. If content capture lands
prompts and responses in Log Analytics, deleting one user's records on request is bounded by
what Log Analytics supports for purge, and by its latency and quota.

**Answer: yes, within limits that have to be written down rather than glossed.**

Azure Monitor's Purge operation is Microsoft's documented GDPR erasure mechanism, and it is a
real delete, not a hide: "Delete and purge operations are destructive and non-reversible"
([Manage personal data in Azure Monitor Logs](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/personal-data-mgmt),
retrieved 2026-09-03). It takes a per-column predicate, so one identified subject over a time
range is expressible.

The constraints are the part that matters, because they decide what may be promised.

| Constraint | Documented value |
|---|---|
| Purge requests | **50 per hour**. The scope of that limit — workspace, subscription or tenant — is not documented |
| Formal completion SLA | **30 days.** "There's no way to expedite the operation" |
| Tables per request | **One.** Content spread across five tables needs five requests |
| Table plans | Analytics only. "You can't purge data from tables that have the Basic and Auxiliary table plans" |
| Predicate operators | `==`, `=~`, `in`, `in~`, `>`, `>=`, `<`, `<=`, `between`. Not arbitrary KQL — no joins, regex or `contains` |
| Custom dimensions | Addressable through the filter's `key` property |
| Permission | `Microsoft.OperationalInsights/workspaces/purge/action`, from the **Data Purger** role (`150f5e0c-0603-4f03-8c7f-cf70034c4e90`) or Log Analytics Contributor |
| Sentinel data-lake mirrors | Cannot be selectively purged: "Specific records can't be purged from the Sentinel data lake" |
| Resource locks | A `CanNotDelete` lock does **not** prevent purge |
| Billing | Unaffected. "Deleting or purging data doesn't affect billing" |
| Eligible use | GDPR only. Microsoft "reserves the right to reject" other purge requests |

**What this rules out.** Any promise of deletion in hours or days. The Delete Data API is faster,
typically minutes, but it only marks rows deleted "without physically removing them from
storage", is limited to 10 requests per hour, and Microsoft points GDPR cases away from it: "If
you need to comply with GDPR requirements, use the Purge API."

**What it means for P15.** Microsoft's own first recommendation is not to capture the data:
filtering or pseudonymising at ingestion is "*by far* the best option". That is already this
repository's posture — content capture is opt-in behind `-CaptureContent` — and P15 should keep
it that way rather than making capture the default and deletion the remedy.

The design that follows:

1. Content capture stays opt-in, and off by default.
2. Capture into **one dedicated Analytics-plan table**, not scattered across Application Insights
   tables, so a deletion is one purge request rather than five.
3. Key rows on the Entra object id, which the gateway already emits, rather than on a UPN or
   email — Microsoft's advice is to log an internal identifier and keep the identity lookup
   somewhere separately deletable.
4. Document the 30-day SLA and the Basic/Auxiliary exclusion as constraints of the offering, not
   as footnotes.

**The wording P15 may use, and no stronger:** records in the designated Analytics-plan table can
be identified by subject id, purged with Microsoft's GDPR Purge operation per affected table, and
tracked to completion — subject to 50 purge requests per hour and a 30-day completion SLA with no
expedite. It does not cover Basic or Auxiliary tables, Sentinel data-lake mirrors, or exported
copies.

### U9 — Counter-key cardinality in llm-token-limit

**Question.** The per-user daily quota keys on `oid + ":daily"`. At 500,000 developers that implies
500,000 distinct counters. Whether API Management supports that cardinality on Basic v2, how long
inactive keys are retained, and what happens under memory pressure — rejection, throttling or
eviction — is not documented.

**Why it matters.** Eviction that restores a spent allowance is worse than no quota, because it
looks like it is working. It decides whether per-user budgets survive at 500k or whether quota
authority has to move to a durable service.

**How to close.** The counter cache and the value cache are different mechanisms, so nothing about
one can be inferred from the other. Ask Microsoft for Basic v2 behaviour, then load-test: create
the target number of identities, exercise quota state, and revisit early identities after heavy key
churn to confirm their consumption survived scale-out, policy deployment and period rollover.

The structural half of this is measured and written up in [SCALE.md](SCALE.md): a named value holds
4,096 characters and 110 object ids, so the entitlement path runs out long before counter
cardinality is reached. That does not close U9 — it means U9 only starts to matter once entitlement
has moved to the projection in [ADR-0005](adr/0005-identity-projection.md).

**Narrowed 2026-09-24.** The load test was run on a throwaway Premium v2 instance with a mock
backend, and the instance was deleted and purged afterwards. Cardinality is not the problem:
500,000 identities were accepted and charged at about 1,600 requests a second on one unit, with no
capacity 429. Exactness is: the remaining allowance each response reported did not match what had
been used, before any scale-out or policy change; one identity sent requests one at a time was
served 540 tokens against a 300-token hourly quota; and 1,000 identities refused for 40 rounds were
all accepted and charged again later in the same hour. Microsoft documents the figure as an
estimate and the limit as exceedable by concurrent requests. Still open: how far over a
production-sized quota a developer can go, why exhausted identities were admitted again, and Basic
v2, which was not tested. Results in [SCALE.md](SCALE.md#counters-at-500000-keys-measured-2026-09-24).

### U10 — Directory latency and throttling on a cold cache

**Question.** `cache-lookup-value` is available on v2, but its built-in cache is "volatile and
shared by all units in the same region". After a flush, every active developer is a miss at once.
Microsoft Graph's throttling limits for that burst, and the p99 latency a miss adds, are unmeasured.

**Why it matters.** It decides whether Graph can sit in the request path at all. It probably cannot,
which is why ADR-0005 proposes a durable projection instead.

**How to close.** Measure a cold-start burst against the real tenant, with request coalescing, and
record the throttling response and `Retry-After` behaviour.

### U11 — What the ledger costs to ingest

**Question.** A per-request trace ledger at 500k scale is order 75 GB a month on rough numbers.
Log Analytics bills ingestion per GB. Basic and Auxiliary table plans are cheaper.

**Why it matters.** U7 established that Basic and Auxiliary tables **cannot be purged**. The cheaper
plan forfeits the deletion promise P15 makes, so cost and compliance pull in opposite directions
and the choice has to be deliberate.

**How to close.** Measure a real trace row, multiply by the load envelope from P18b, and price both
plans against the retention and purge requirement.

### U12 — Whether APIM telemetry preserves the cache TTL split — CLOSED 2026-09-15

**Question.** Claude prices three cache categories differently: read at 0.1x base input, a
five-minute write at 1.25x and a one-hour write at 2x. Whether `llm-emit-token-metric` or the
built-in `ApiManagementGatewayLlmLog` table carries that split is not documented, and Microsoft's
own AI Hub Gateway accelerator has a single `CostPerCachedInputUnit`.

**Measured 2026-09-15.** The Anthropic response body does carry it in full:
`input_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_5m_input_tokens`,
`cache_creation.ephemeral_1h_input_tokens`, `output_tokens`,
`output_tokens_details.thinking_tokens`, plus `service_tier` and `inference_geo` — the last of which
matters because data-zone deployments carry a 1.1x multiplier. APIM's own `x-tokens-consumed`
returned a single scalar.

**What stays open.** Whether that scalar includes cache tokens when caching is actually active, and
so whether any existing quota silently mis-counts a cached workload. The reference states total
input tokens is the sum of input, cache creation and cache read, so naive addition double-counts.

**Answer, measured 2026-09-15.** No APIM-native source carries the cache categories per request,
and the quota scalar does not count cache tokens at all.

Two identical calls with a cacheable 10,000-token system prompt. The first wrote 10,003 cache
tokens and the second read 10,003. Both were metered as **16** through `x-tokens-consumed` — the
plain input and output only. This is documented behaviour: the reference says the policy "currently
counts prompt and completion tokens only". What had not been drawn is the consequence.

Against thirty days of live usage on this gateway — 6,803,708 cached tokens against 319,709 prompt
and 151,594 completion — and weighting at Claude's published rates where output is 5x base input
and a cache read is 0.1x:

| Source of cost | Base-input equivalents | Share |
|---|---:|---:|
| Prompt | 319,709 | 18.2% |
| Completion | 757,970 | 43.1% |
| Cache reads | 680,371 | **38.7%** |

**38.7% of the real cost weight is invisible to the quota.** Cache reads are the second largest
cost driver here and the per-user daily budget does not see them.

The built-in `ApiManagementGatewayLlmLog` does not carry them either: its columns are
`PromptTokens`, `CompletionTokens` and `TotalTokens`, and a cached request recorded 9 and 30 while
10,003 cache reads went unrecorded. APIM is clearly parsing the stream, because it gets streamed
output tokens right where the quota scalar does not, so this is a projection gap rather than a
parsing one.

**What P18 did with it.** The ledger records cache as null with `cache_tokens_known = false`, and a
test fails if that ever becomes zero. Reading the response body in `outbound` would recover the
categories but buffers the response and ends streaming, which is not a trade worth making for a
reporting field. See ADR-0006.

**What stays open.** That the *budget* under-counts cached workloads is now a known behaviour rather
than an unknown. Whether to correct for it — and how, without breaking streaming — is P21's problem,
and it is why P21 may not express a dollar budget as a token quota.

**Correction, 2026-09-17.** "No APIM-native source carries the cache categories" is true **per
request**, which is what the measurement above established. It is not true in aggregate.
`infra/policy.xml` emits `llm-emit-token-metric` with dimensions `User`, `UserId`, `Tier`, `Model`
and `SessionId`, and that emitter produces a **`Prompt Cached Tokens`** metric.
`analytics/claude-code-daily.kql` already reads it, summarised `by date, actor, model`, and
`tests/Test-Analytics.ps1` asserts it is greater than zero against live data.

So the comment in `analytics/chargeback-ledger.kql` — "available from the `Prompt Cached Tokens`
metric, which is bounded but **not per-user**" — is wrong. The metric carries `User` and `UserId`,
which is what chargeback keys on.

| | Cache read | Cache write 5m / 1h |
|---|---|---|
| Per request, `ApiManagementGatewayLlmLog` | absent — measured | absent |
| Aggregated, `Prompt Cached Tokens` metric | **present**, by user, model, day | absent |
| Anthropic response body | present | present, but reading it in `outbound` ends streaming |

**What this unblocks.** Chargeback bills per developer per period, not per request, so the aggregate
metric is at the granularity the report needs. Joining it closes the larger part of the 38.7% gap,
leaving only the two cache *write* categories unattributed. It is a reporting change, not a policy
change, so it does not touch streaming.

**What it does not unblock.** Enforcement. `llm-token-limit` counts prompt and completion only, so a
budget stays blind to cache. That is U13, unchanged.

**Recorded, not built.** Found 2026-09-17 in a session that could not run the test suite or the
gate. This repository does not accept code that has not been through RED.

### U13 — Whether APIM can enforce a budget on categorised usage

**Question.** P21 requires spend computed from categorised usage, because output is 5x base input
and a cache read is 0.1x, so one token total cannot represent money. `llm-token-limit` takes a
single `token-quota` attribute and, per the reference, "currently counts prompt and completion
tokens only". Whether a categorised budget can be expressed in APIM at all is unknown.

**What shipped instead.** `Set-ClaudeBusinessUnit.ps1` converts dollars to one blended token figure
at write time, assuming 20% output — a deliberately conservative mix, adjustable with
`-OutputShare`. Enforcement is a single monthly `llm-token-limit` keyed on the business unit.

**Blast radius of the assumption.** Two errors, both in the same direction:

| | |
|---|---|
| Output mix | A unit running heavier than 20% output exhausts its dollar budget before its token budget. A lighter one under-spends |
| Cache | 38.7% of real cost weight on measured usage, invisible to the counter — see U12 |

Real spend is therefore **higher** than the budget suggests, never lower, which is the safe
direction for a soft cap but not acceptable for an invoice. `docs/BUSINESS-UNITS.md` and every
command's output state both.

**What would close it.** Three candidates, none measured: a second `llm-token-limit` weighted for
output on the same counter-key; `azure-openai-emit-token-metric` feeding an out-of-band reconciler
that adjusts the named value; or accepting blended enforcement and moving exactness to reporting
only, where the ledger already has the categories. The third is cheapest and matches the "soft cap"
semantics P20b has yet to define.

### U8 — OTEL attribute names behind the split productivity metrics

**Question.** Claude Code's OpenTelemetry export publishes
`claude_code.lines_of_code.count` and `claude_code.code_edit_tool.decision`
([monitoring reference](https://code.claude.com/docs/en/monitoring-usage), retrieved
2026-09-02). The Analytics API reports those split four ways — lines added, lines removed,
tools accepted, tools rejected. The attribute that carries the split, and its exact values, has
not been read from a live export because no OpenTelemetry collector is deployed in this
environment.

**Why it matters.** `analytics/claude-code-daily.kql` returns those four columns as null rather
than guessing an attribute name. A wrong guess would return zero, which reads as "nobody
rejected anything" instead of "not measured".

**How to close.** Deploy an OpenTelemetry collector against one Claude Code install, run one
session containing an accepted and a rejected edit, and read the attribute keys off the
exported metric. Then replace the four `real(null)` literals with `sumif` over the real
attribute.

---

## U15 — what forces Cosmos public access off

**Symptom.** Every Cosmos account in this subscription comes up with
`publicNetworkAccess: Disabled`, including one nobody here created. The sync
therefore cannot reach the projection from a laptop, which is what blocks
populating it, `cos-default` and `cos-upgrade`.

**Answered 2026-09-23 — it is Azure Policy after all, assigned where it could
not be listed.** The initiative `MCAPSGovDeployPolicies`, assigned at a management
group above the subscription, contains
`CosmosDB_PublicNetwork_Modify`. Its rule: if the resource is a
`Microsoft.DocumentDB/databaseAccounts` whose `publicNetworkAccess` is neither
`Disabled` nor `SecuredByPerimeter`, and it does not carry the rule's exclusion
tag, then `addOrReplace` `publicNetworkAccess` with `Disabled` for api-version
2021-04-15 or later. A Modify effect rewrites the request before the resource
provider sees it, which is exactly the symptom: the value is replaced at
creation, success is reported, and the requested value is never accepted.

The same initiative holds `CosmosDB_LocalAuth_Modify`,
`StorageAccount_PublicNetwork_Modify`, `StorageAccount_DisableLocalAuth_Modify`,
`KeyVault_PublicNetwork_Modify`, `AIFoundryHub_PublicNetwork_Modify` and
`CognitiveServices_LocalAuth_Modify`, among 36. The resolver's storage account
came up private for the same reason.

**Why the narrowing below ruled it out, wrongly.** `az policy assignment list
--disable-scope-strict-match` at subscription scope returned only the three
Defender assignments; the management-group assignment is not in its output even
though it applies. The resource's own activity log is what named it: an entry
`Microsoft.Authorization/policies/modify/action` whose `policies` property gives
the assignment and definition ids. Read that first when a setting comes back
different from what was asked for.

**What it means for the accelerator.** Nothing needs an exemption. The
projection is deployed with no public endpoint by design and was verified end to
end ([SECURE-PROJECTION.md](SECURE-PROJECTION.md)), and the templates now state
`publicNetworkAccess` themselves rather than leaving it to whatever a policy
decides.

**Narrowed earlier on 2026-09-23.** The important part is what this is *not*, because each
of those is a place an operator would otherwise spend a day:

| Ruled out | How |
|---|---|
| Azure Policy — **wrong, see above** | Three assignments on the subscription, all Defender-related. `az policy assignment list --disable-scope-strict-match` returns the same three, so nothing is inherited from a management group either. `az policy state list` reports nothing. The management-group assignment was not in that output. |
| A deny assignment | Three exist, all `Container Apps Managed Resource Group`, and all scoped to resource groups this deployment does not use. |
| A feature registration | No `Microsoft.DocumentDB` feature is registered; the only network-shaped ones are `NotRegistered` previews. |
| Something about the existing account | A **brand-new** account created with `--public-network-access Enabled` came back `Disabled` in the create response itself. |
| An async revert | The create and update responses *themselves* carry `Disabled`. Nothing sets it and then changes it back — it is never accepted. |

**So the control acts at creation, inside the resource provider, and reports
success while ignoring the requested value.** That shape — silent, at creation,
invisible to the policy surface — is consistent with a tenant-level
secure-by-default governance control rather than anything expressed in ARM.

**What to do about it.** Do not hunt for a policy to exempt; there is not one
to find at subscription scope. Either:

- run the sync somewhere the projection is reachable — an Azure context inside
  the VNet, which is how the load test reached the data plane
  (`infra/projection-network.bicep` stands up exactly that), or
- ask whoever owns tenant governance for an exemption, naming the account.

**Still unmeasured.** Which control it is, and whether it is the same one on a
customer tenant. An operator on a normal subscription may not hit this at all —
the accelerator should not assume either way, which is why
`infra/projection.bicep` makes network access an explicit choice rather than a
default.

---

## U27 — Desktop sign-in keys by release — CLOSED 2026-09-27

**Symptom.** On the owner's workstation, after `Setup-ClaudeWorkstation.ps1` wrote a Desktop
profile for Entra sign-in, **Configure third-party inference** showed the gateway base URL, an
empty **Credential kind** and "Connection needs Credential kind".

**Research.** The configuration reference
(<https://claude.com/docs/third-party/claude-desktop/configuration>, retrieved 2026-09-27) lists:

| Key or value | Added in | Note |
|---|---|---|
| `inferenceCredentialKind` | 1.8555.0 | one of `static`, `helper-script`, `interactive`, `vendor-profile`, `workforce`, `external-idp` |
| `inferenceGatewayOidc` | 1.6889.0 | deprecated in favour of `inferenceIdpOidc`; "the original spelling will keep working; no end date has been set" |
| `inferenceGatewayOidcAuthFlow` | 1.25927.0 | `browser` (default) or `broker`; same deprecation note |
| `inferenceIdpOidc`, `inferenceIdpAuthFlow` | 2.7032.0 | the new spelling |
| `interactive` with `inferenceGatewayOidc` | — | "read as `external-idp`" |

**Measurement.** The Desktop release installed on this workstation, 2.2553.1.0 (MSIX), carries a
configuration schema of 171 keys. It has `inferenceGatewayOidc` and `inferenceGatewayOidcAuthFlow`,
not `inferenceIdpOidc` or `inferenceIdpAuthFlow`, and its credential kinds exclude `external-idp`
(`tests/fixtures/claude-desktop-schema-2.2553.1.0.json`). ADR-0027's profile wrote only keys and a
kind this release does not read, which matches the symptom.

**Resolution.** [ADR-0031](adr/0031-client-keys-every-release-reads.md): write the spelling the
release that reads the profile knows. With no release known, the original spelling, which every
release since 1.25927.0 reads.

**Owner's evidence, 2026-09-27.** On the owner's workstation the per-user installer had installed
Desktop 2.9939.2 in the background, while the running process was `app-1.44121.2\claude.exe`,
most likely started from a shortcut pinned to that versioned folder. 1.44121.2 reads neither
`external-idp` nor `inferenceIdpOidc`, and its **Sign in** button did nothing. After 2.9939.2 was
started, Desktop showed "Identity provider sign-in (OIDC)" with the browser flow and the recorded
client id. The app registration, the redirect `http://127.0.0.1/callback`, the
`external-idp-extra-audience` named value and the policy branch were correct. So the release that
reads a profile is the running one when it is older than the installed one:
`Get-ClaudeDesktopReadingVersion` takes the older of the two, and `Debug-ClaudeWorkstation.ps1`
reports the running build and any versioned shortcut.

## U28 — Claude Code releases and the 5-series models — CLOSED 2026-09-27

**Symptom.** Claude Code 2.1.101 on the owner's workstation returned
`API Error: 400 ... "thinking.type.enabled" is not supported for this model. Use
"thinking.type.adaptive" and "output_config.effort"` for `claude-opus-5` through the gateway.
The VS Code extension on the same machine worked.

**Research.** The Claude Code changelog
(<https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md>, retrieved 2026-09-27) adds
Claude Sonnet 5 in 2.1.197, Claude Opus 5 in 2.1.219 and Claude Opus 5.5 in 2.1.280, and added
capability overrides for pinned third-party models in 2.1.84. The model configuration guide
(<https://code.claude.com/docs/en/model-config>, retrieved 2026-09-27) says Claude Code never
recognises a pinned Microsoft Foundry deployment name and detects capabilities from the model ID
unless `ANTHROPIC_DEFAULT_<ALIAS>_MODEL_SUPPORTED_CAPABILITIES` lists them (`effort`,
`xhigh_effort`, `max_effort`, `thinking`, `adaptive_thinking`, `interleaved_thinking`).

**Measurement**, 2026-09-27, `claude -p` through the reference gateway with `claude-sonnet-5`
and an isolated `CLAUDE_CONFIG_DIR`:

| Claude Code | Capability variable | Result |
|---|---|---|
| 2.1.101 | none | 400 `thinking.type.enabled` |
| 2.1.101 | `..._SUPPORTS` (the changelog's shorthand) | 400 |
| 2.1.101 | `..._SUPPORTED_CAPABILITIES` with all six | answered; also at `--effort max` |
| 2.1.272 | `..._SUPPORTED_CAPABILITIES` with all six | answered at `--effort high` and `max` |

**Resolution.** [ADR-0031](adr/0031-client-keys-every-release-reads.md): declare capabilities for
recorded models, and report or update a Claude Code older than the release that knows them.

**Live proof of the setup's settings**, 2026-09-27 08:52Z, Claude Code 2.1.101 with the settings
`Set-ClaudeCodeGatewaySettings` writes for `claude-opus-5` and `claude-sonnet-5`, through the
reference gateway, isolated `CLAUDE_CONFIG_DIR`:

| Invocation | Result |
|---|---|
| `claude -p ping` (default model) | answered, 12.4 s |
| `--model opus`, `--model sonnet` | answered, 8.2 s and 10.1 s |
| `--model claude-sonnet-5`, `--model claude-opus-5` | answered, 8.7 s and 9.0 s |
| `--model claude-opus-5 --effort max` | answered, 9.4 s |
| default model, same settings without `_SUPPORTED_CAPABILITIES` | 400 `thinking.type.enabled` |

**What each release sends**, 2026-09-27, captured by a local listener standing in for the gateway
(`thinking` field of the message request; `--model sonnet`):

| Pinned name | Declaration | 2.1.101 | 2.1.272 |
|---|---|---|---|
| `claude-sonnet-5` | none | `enabled` | `adaptive` |
| `claude-sonnet-5` | `thinking` | `enabled` | `enabled` |
| `claude-sonnet-5` | all six | `adaptive` | `adaptive` |
| `prod-fast` | none | `adaptive` | `adaptive` |
| `prod-fast` | `thinking` | `enabled` | `enabled` |
| `prod-fast` | all six | `adaptive` | `adaptive` |

With the listener answering `enabled` with the model's real 400, 2.1.272 sent a second request with
`adaptive` and answered; 2.1.101 sent one request and failed. Through the reference gateway,
2.1.101 with `thinking` or `effort,thinking` returned the 400, and with `adaptive_thinking`,
`effort` or all six in another order it answered; 2.1.272 answered in every case.

## U31 — Customer prices — CLOSED 2026-09-27

**Question.** Can the guided flow and the installer show the prices of the customer's own
agreement instead of Azure retail list prices, and with what role?

**Research**, Microsoft Learn, retrieved 2026-09-27:

| Agreement | Who can read the price sheet | Source |
|---|---|---|
| Microsoft Customer Agreement | billing profile owner, contributor, reader or invoice manager | [View and download your organization's Azure pricing](https://learn.microsoft.com/azure/cost-management-billing/manage/ea-pricing#download-pricing-for-an-mca-or-mpa-account) |
| Microsoft Partner Agreement | the Admin Agent or billing admin role in the partner organization | same page |
| Enterprise Agreement | the administrative roles the Enterprise Admin's policy allows | [same page](https://learn.microsoft.com/azure/cost-management-billing/manage/ea-pricing) |

The price sheet APIs sit at the billing account or billing profile scope
(`/providers/Microsoft.Billing/billingAccounts/{id}[/billingProfiles/{id}]/providers/Microsoft.Consumption/pricesheets/download`)
and return the whole sheet as a file
([Migrate from EA to MCA APIs](https://learn.microsoft.com/azure/cost-management-billing/costs/migrate-cost-management-api#price-sheet-for-a-scope-by-billing-account)).
None of these is a subscription role, so the administrator who runs the installer, who holds
Contributor on a subscription, cannot read it unless also given a billing role. The Azure Retail
Prices API needs no credential and filters on `serviceName`, `meterName` and `armRegionName`
([Azure Retail Prices overview](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)).

**Resolution.** [ADR-0032](adr/0032-guided-flow-starts-at-once.md): prices at each choice are
Azure Retail Prices API list prices, named as such with the time they were read, and the
agreement's price sheet is named as the authority with the role it needs. Reading the price
sheet for an administrator who holds a billing role is a roadmap entry, not P68.

## U32 — The Turnstile database stops every evening — OPEN

**Symptom.** On 2026-09-27 the owner reported AUM taking 33–36 s per command and failing with
`Read failed (exit 7)`, and Turnstile sign-in failing.

**Measurement.** AUM reads through the Turnstile backend named by the `turnstile-integration`
named value. The Turnstile App Service answered `/health`, but the authenticated
`GET /api/v1/auth/me` waited about 30 s for a database connection and returned 500. The
PostgreSQL Flexible Server `contoso-e8f7782d` in `contoso-534a5930` was in state
`Stopped`. These are the synthetic aliases in capture 60. Its activity log
for the previous 7 days:

| UTC | Operation | Caller |
|---|---|---|
| 09-23 19:05–19:09 | stop | an application from another tenant |
| 09-23 19:40–19:42 | start | the owner |
| 09-24 19:05–19:07 | stop | the same application |
| 09-24 19:42–19:44 | start | the owner |
| 09-25 19:05–19:08 | stop | the same application |
| 09-27 08:15–08:17 | start | P67 session, owner's account |
| 09-27 19:05:18–19:07:19 | stop | not re-attributed by P71; operation and timestamps read only |
| 09-27 22:23:22–22:25:35 | start and Ready verification | P71, under the owner's explicit authorization |

P71's read at **2026-09-27 20:13:35Z** found the server `Stopped`. This packet
has authorization to start that server after measuring the stopped case and
leave it running for the owner's morning test. That authorization does not
cover the stopping automation, Turnstile settings or any other resource.
That authorized start completed with `Ready` verified at **22:25:35Z**. The
database was left running. P71's stopped terminal read rendered exit 9 and the
manual command in **4.046 s** after refresh start (**4.725 s** including the
Textual harness startup). Running Turnstile then returned identity in **4.126 s**
and status in **8.938 s** from a fresh CLI process. Short credential/metadata
deadlines can still produce an explicit unverified exit 7 under workstation or
network load; they do not establish a stopped server. The external automation
has not been changed.
The final P71 read at **2026-09-28 00:23:34Z** still reported `Ready`.

The stop token's claims name an application (`idtyp` `app`) issued by a tenant other than the
subscription's, so the stop comes from an automation outside this
deployment, most likely a subscription-level cost policy. After the start, `auth/me` returned 200
in 1.2 s. To check it on a gateway's Turnstile: `az postgres flexible-server show -g <rg> -n
<server> --query id -o tsv`, then `az monitor activity-log list --resource-id <id> --offset 7d`,
and read `caller` and `claims` on the `Microsoft.DBforPostgreSQL/flexibleServers/stop/action`
events.

**Open.** Which automation this is and whether it can exclude the server. Until then the server
is expected to stop again at about 19:05Z. The product side is queued as f10 and f11: a Turnstile
readiness endpoint that answers 503 at once when the database is unavailable, and an AUM
preflight that names the stopped database instead of `exit 7`.

## U36 — A top-level run and an in-process call — CLOSED 2026-09-28

**Question.** P72 prints a refusal of `Start-ClaudeGateway.ps1` as its reason, without
PowerShell's code excerpt (`Line |` on PowerShell 7, `CategoryInfo` on Windows PowerShell 5.1).
`tests/Test-GuidedFlow.ps1` calls the script in process and expects the refusal as an exception.
Can the script tell a top-level run from a call by another script, on both shells?

**Measured 2026-09-28** with a script that prints `$MyInvocation.PSCommandPath` and
`$MyInvocation.CommandOrigin`, on PowerShell 7 (`pwsh`) and Windows PowerShell 5.1
(`powershell.exe`):

| Invocation | `PSCommandPath` | `CommandOrigin` |
|---|---|---|
| `-File script.ps1` | empty | `Runspace` |
| `-Command "& script.ps1"` (as from a prompt) | empty | `Runspace` |
| `& script.ps1` from another script | the calling script's path | `Internal` |

Both shells gave the same results. The [about_Automatic_Variables][u36-auto] reference documents
`$MyInvocation.PSCommandPath` as the path of the script that invoked the current command. A
top-level run therefore prints the reason and exits 1; a call from another script still receives
the exception. `tests/Test-FlowPermutations.ps1` checks both.

**Measured again 2026-09-28, after council round 1 of P72**, on both shells:

| Invocation or error | Observed |
|---|---|
| `. script.ps1` from another script | `InvocationName` is `.`; `PSCommandPath` is the calling script |
| `. script.ps1` at a prompt (`-Command`) | `InvocationName` is `.`; `PSCommandPath` is empty |
| `throw 'text'` | `RuntimeException`; `FullyQualifiedErrorId` equals the message |
| `$null.Method()` | `RuntimeException`; `FullyQualifiedErrorId` is `InvokeMethodOnNull` |
| a cmdlet error under `-ErrorAction Stop` | its own exception type, such as `DriveNotFoundException` |

A dot-sourced run shares its caller's scope, and at a prompt that is the console's global scope,
where `exit` closes the console. The flow therefore treats a dot-sourced run as a call and raises
the exception. The flow refuses by throwing its reason, so an error whose id is its own message
is a refusal, printed without the debugging hint; any other error prints the hint.

[u36-auto]: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables#myinvocation

---

## Closed

_(none yet)_
