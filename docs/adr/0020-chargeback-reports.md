# ADR-0020: Reconciled monthly reports and a rate-limited private email outbox

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** P50
- **Related:** ADR-0006, ADR-0008, ADR-0010, ADR-0014; U2, U9, U12, U13

## Context and scope

Administrators need one-command monthly business-unit reports, and scheduled delivery to
recipients they can change without deploying code. Reports contain personal usage data.
The target population is 500,000 developers, not 500,000 email recipients.

The owner assigned this worktree P50 while the shared status still names P46. The owner
reserved STATUS, ROADMAP, CHANGELOG, UNKNOWNS and README to the lead. This ADR records
the local contract; proposed ledger entries and the five-seat review go in the delivery
report for the lead to merge. No parallel packet or shared ledger is edited here.

Acceptance criteria: UTC calendar periods; exact token/request reconciliation including
Unassigned; per-unit privacy; escaped CSV and HTML; versioned recipient configuration;
secretless scheduled generation, private archive and email; mutations that detect lost
data or weaker privacy; live owner-only proof; packet gate on the committed clean tree.

## Evidence and decisions

### Reuse the saved ledger, do not invent a second tariff

`ClaudeCost` calls `ClaudeChargeback` and combines request tokens with cache-read metrics.
Use server-side aggregation per unit, with disjoint person-hash partitions when a result
reaches the client page budget. Root-unit totals, including Unassigned, reconcile to a
separate workspace total. Team totals are subdivisions, never added a second time.
Compare every returned person total to its unit before publishing any output.

The saved functions use inclusive `between`. Pass the exclusive UTC end minus one
100-nanosecond tick. The default is the previous calendar month; month-to-date is explicit.
Record the exact window, saved-function hashes, price-book date and membership date.
Budgets are the configuration read at generation time, not reconstructed history.

**Existing limitation, not silently resolved:** ADR-0010 describes effective-dated prices,
deployment/geography pricing and decimal arithmetic. The published `ClaudeCost` instead
uses a flat model price book and Kusto real-valued costs. P50 exports that existing
showback contract, accumulates returned values in decimal, and records its provenance;
it does not claim invoice accuracy or historical tariff reconstruction. Changing the
tariff is a separate packet. Reconciliation tolerates only sub-microdollar floating-point
differences, never missing tokens or requests. Unpriced usage is explicitly reported.

Cache-write categories are **unknown**, not zero. Include both columns as empty CSV/null
JSON, print the caveat in every HTML report, and reconcile the measured categories only.
Cache reads have no measured client surface. Do not allocate them to a client.

[Azure Monitor limits](https://learn.microsoft.com/azure/azure-monitor/fundamentals/service-limits#query-api)
(read 2026-09-24): 500,000 rows, approximately 100 MiB uncompressed/64 MB compressed,
10-minute maximum query time, 200 requests per 30 seconds. A partial response fails
closed; a bounded person page is recursively split rather than silently truncated.
Sequential queries keep concurrency low. A 100,000-person offline generation benchmark
measures rendering and serialization, not Azure query performance.

### A private versioned blob document, not an APIM named value

Store `settings.json` in a separate `configuration` container. Use Entra authentication,
blob versioning and ETag conditional writes. A stale writer receives a conflict instead
of overwriting another administrator's changes. Hundreds of units do not encounter the
4,096-character APIM named-value ceiling. Allowed domains are required, exact-match,
and checked both on edit and immediately before delivery.

Unit recipients receive only their unit. All-units recipients receive the selected
index and CSVs. Team recipients are deferred: sending the parent report to a team would
be a privacy error. A future implementation needs separately rendered team artifacts
and explicit parent/team authorization, not another address field pointing at unit data.

Recipients, unit selection, output formats, period mode and retention are script-editable.
Changing a schedule patches the existing job; it does not redeploy resources or fetch a
new code revision. The code itself remains pinned to a published commit.

### Secretless email, with an honest capacity boundary

[Email supports Microsoft Entra ID](https://learn.microsoft.com/azure/communication-services/quickstarts/email/send-email?tabs=windows&pivots=programming-language-csharp).
Use the REST API with an Entra bearer token for `https://communication.azure.com`.
The reference REST page still describes HMAC; the SDK authentication quickstart explicitly
supports Entra. Prove the bearer path live before claiming it.

There is no email-send-only data action in the inspected Microsoft.Communication provider.
Use a custom role with CommunicationServices read/write, scoped to the **dedicated**
Communication Services resource; no keys, delete or subscription-wide Contributor.
This is a residual management permission, not a fictitious Email Sender built-in role.
[The documented custom-role pattern](https://learn.microsoft.com/azure/communication-services/quickstarts/email/send-email-smtp/smtp-authentication)
and the live provider operations establish the available RBAC granularity.

[ACS limits](https://learn.microsoft.com/azure/communication-services/concepts/service-limits#email)
(read 2026-09-24): Azure-managed domains allow 5 sends/minute and 10/hour per subscription;
status queries allow 10/minute and 20/hour. These quotas cannot be increased for
Azure-managed domains. A message allows 50 recipients and 10 MB including Base64 overhead.
Use CSV directly for small reports; split large CSVs at record boundaries and compress
each part, then check actual serialized request bytes. Never put an unrestricted download
link or SAS in an email.

A durable archive-backed outbox separates monthly generation from delivery. A second,
short-lived, blob-triggered Container Apps job drains it conservatively. KEDA polls the
outbox every 420 seconds, minExecutions zero, maxExecutions one: no container starts
when there is no mail. The [blob scaler](https://keda.sh/docs/2.18/scalers/azure-storage-blob/)
uses the same managed identity and counts pending blobs, which the worker deletes on
completion. A blob lease serializes sends
across manual and scheduled runs; persisted pacing survives process restarts. Read current
recipient settings at delivery time, including removals and the domain policy. Record
operation IDs, scope and recipient counts, not address lists, in each run manifest.
Ambiguous outcomes are recorded and inspected rather than retried as new messages.

This avoids running a container idle for days. With hundreds of units, delivery through
an Azure-managed domain still takes days. Generation supports the target population;
prompt large-organization delivery requires a verified custom domain and an approved quota,
as [Microsoft recommends for production](https://learn.microsoft.com/azure/communication-services/concepts/email/email-domain-and-sender-authentication).
ACS send success is not proof of inbox placement.

### Dedicated Consumption resources

Create a reports-only Container Apps Consumption environment, generator job, dispatcher
job, user-assigned identity, StorageV2 account, Email Service, Azure-managed domain and
connected Communication Services resource. No dependency on Turnstile and no modification
to its environment. Configuration is readable but not writable by the job. Archive/outbox
access is scoped to their container. Workspace access is read-only; gateway access is
limited to reading the named-value catalog used for budgets.

Storage disables public blob access and shared-key access, requires HTTPS/TLS 1.2, enables
soft delete/versioning, and deletes archived runs by an administrator-editable lifecycle
rule (default 400 days, approximately 13 months). Private means authenticated containers,
not private endpoints: network isolation is optional and not claimed by this packet.

## Alternatives rejected

- Logic Apps: additional connectors and a smaller query-response ceiling; duplicates scripts.
- APIM named values for recipient lists: size ceiling and no natural document concurrency.
- Connection strings: unnecessary when the existing identity can authenticate with Entra.
- One long-running sender: expensive idle time under the non-increasable managed-domain quota.
- Sending every person's report individually: neither requested nor feasible at this quota.

## Consequences and detectors

Archived reports are reproducible artifacts, not proof that telemetry was complete at source.
Late ingestion can change a restatement; mismatched query snapshots fail reconciliation and
require regeneration. Manifest hashes identify changes to queries, prices and artifacts.
Email leaves Azure storage retention control once delivered; recipients and retention are
governance decisions. Mutation tests must detect an incorrect boundary, dropped token kind,
missing Unassigned, cross-unit row, unescaped formula and disabled domain policy.
