# ADR-0035: Bounded AUM readiness and progressive reads

- **Status:** Accepted for P71 implementation; council and merge belong to the lead
- **Date:** 2026-09-28
- **Packet:** P71

## Context

The owner authorizes this packet on `p71-aum-speed`, alongside other worktrees.
This supersedes the single-active-packet wording for this assigned worktree, not
the test-first or gate contract. The lead conducts the five council reviews.
This branch records its tests, mutations, live measurements and packet gate, and
does not mark the ROADMAP packet complete.

The 2026-09-27 investigation found a stopped Turnstile PostgreSQL server behind a
healthy `/health` endpoint. Authenticated `/api/v1/auth/me` waited about 30 s for a
database pool connection, then returned 500. Tonight's initial state and stop
timestamps are recorded under U32. Direct also repeated token acquisition and
PowerShell processes, and the terminal withheld all data until identity and
capability discovery completed.

The dominant criterion is time to truthful, actionable information. Replacing a
blank screen with an indefinite spinner would not satisfy the owner's rule that
every wait has a progress indicator or an estimate.

## Options

1. Change Turnstile readiness or pool configuration. That product is in another
   repository and is outside this packet's authorization.
2. Automatically start the database or fall back to Direct. Either changes cost
   or authority without the operator's explicit choice; neither is accepted.
3. Bound the client's authenticated readiness read, diagnose through read-only
   Azure metadata, and remove redundant work within each Direct read cycle.
   This is the selected approach.

## Decision

### Readiness and diagnosis

The existing authenticated identity read is the readiness probe; an additional
liveness call is not evidence of database readiness. Turnstile identity uses a
short HTTP timeout. A timeout or 5xx initiates a bounded read of PostgreSQL state
in the deployment resource group recorded by `turnstile-integration`.
Discovery preserves that address metadata in `turnstile_resource_group`; older
gateway-backed profiles can resolve it from their gateway. Address-only profiles
remain valid without any Azure resource-management permission.

Only an unambiguous, validated server reported as `Stopped` produces exit **9**
and the command `az postgres flexible-server start -g <group> -n <server>`.
The diagnostic command includes the selected subscription when known. Ready,
starting, missing, unreadable, malformed and ambiguous inventories are not
reported as a stopped database. Authentication and scope failures keep their
existing codes. Generic availability failures keep exit 7 and explain when
database state could not be verified. No response body, bearer token or raw
transport exception is included in the message. Nothing starts automatically.

HTTP timeouts bound network inactivity, not all possible workstation or network
delays. The approximately-five-second acceptance is measured end to end with a
warm Azure CLI session; the ledger records cold-start and metadata-lookup costs
separately rather than treating a configured timeout as a timing measurement.

### Direct read cycles

Resource tokens are kept only in process memory, keyed by resource and selected
Azure account context, synchronized across simultaneous reads and refreshed
before expiry. Explicit sign-out clears them. A token is never written to a
profile, evidence file, command line or log.

A read cycle shares a bounded gateway snapshot. One PowerShell invocation and
one named-value listing supply catalog, tiers, budgets and the existing USD
conversions. The existing PowerShell serializers remain the only serializers.
Individual batch-read errors remain errors for their requested view, not
invented empty data. The snapshot does not survive the read cycle or a write;
authorization preflight, optimistic conflict detection and compensation continue
to read fresh state. Independent read-only telemetry queries can overlap.
Writes remain serial and are never retried automatically.

### Terminal

The existing Textual widgets, themes, keyboard navigation and no-motion policy
remain. A refresh tracks the actual pending sources and displays an estimate
and elapsed time. Each Overview panel renders when its source arrives; missing,
loading, failed and genuinely empty data remain distinct.

Direct read-only data is authorized by Azure independently of its identity
label. Those reads can begin while Azure identity/RBAC lookup runs, but edits
stay disabled until identity and capabilities are verified. HTTP-backed scoped
data still waits for the current identity/scope check required by ADR-0018;
settings and wait/error feedback do not. This preserves the existing empty-scope,
context-parent and scope-change guarantees instead of trading them for speed.
Cancelled or superseded refreshes cannot publish stale data into a newer view.

## Evidence and assumptions before implementation

- The full investigation is the owner's 2026-09-27
  `aum-turnstile-investigation.md`; public observations are in U32 and STATUS.
- Microsoft documents the resource-group PostgreSQL list and each server's
  state in [Servers - List By Resource Group](https://learn.microsoft.com/rest/api/postgresql/servers/list-by-resource-group?view=rest-postgresql-2024-08-01).
- The explicit operator action is documented in
  [az postgres flexible-server start](https://learn.microsoft.com/cli/azure/postgres/flexible-server#az-postgres-flexible-server-start).
- [HTTPX timeouts](https://www.python-httpx.org/advanced/timeouts/) distinguish
  connect, read, write and pool timeouts; they are not a whole-operation SLA.
- Sources were retrieved 2026-09-27 UTC. U35 records the deployment-inventory
  assumption and its fail-closed negative cases before implementation.

## Consequences

No server deployment, account switch, consent, resource grant or authority
change is added. The only authorized live write by this packet is the owner's
named database start after stopped-case measurements; the database is left
running. The U32 external stopping automation remains an operational unknown.

Offline pytest and PowerShell checks cover the new boundaries, followed by
deliberate detector mutations and a full locked packet gate with pytest enabled.
Live timings use separate CLI processes and saved profiles, with output and
failure timings distinguished. Terminal captures are read-only and redacted.
