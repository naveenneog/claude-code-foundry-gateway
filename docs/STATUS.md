# Status

**Active packet:** P46 — managers scoped to their units and teams (done, fork `c0c345a`), and budget modes in the gateway (in progress) ([TURNSTILE.md](TURNSTILE.md#managers), [ADR-0016](adr/0016-delegated-management.md)).

## P46 acceptance criteria — managers scoped, and budget modes

- [x] A manager-only token reaches an allow-list of 13 read routes and the budget writes; every other protected route is refused by default, asserted on each protected router
- [x] Scope comes from the manager groups in the person's token, resolved against the catalog on each request; a unit manager's scope includes its teams and direct members; missing or overage groups grant nothing
- [x] Usage, budgets, people, the catalog and a request's detail are filtered to the scope; a filter or id outside it is refused
- [x] A unit manager sets its teams' budgets and any manager sets person budgets in scope; the unit budget, catalog, tiers, modes and **Apply now** stay the owner's; Turnstile still refuses a child above its parent
- [x] An owner records a unit's or team's manager group and budget mode on the Gateway governance page (`manager_group_id`, `enforcement`, `allowance_percent`)
- [ ] The gateway enforces strict, allowance and notify (in progress)
- [ ] A live sign-in with a manager-only account: the owner's acceptance step, since the account running the checks holds `Turnstile.Admin`
- [ ] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| Fork checks at `c0c345a` | 770 platform tests passed, 5 skipped, the six known environmental failures only; 203 manager-scope tests; 17 page-rule tests |
| The built console against test-signed manager tokens, in a browser | 30 API requests, none outside the allow-list; forbidden pages redirected; team-only budgets shown as roots |
| Turnstile redeploy | 9 min 22 s; the owner's live sign-in afterwards: `owner`, `entra`, no scope |
| Two manager attributes added to the live catalog, then restored | The restore read back identical, write-payload hash unchanged; every budget unchanged |

**Found by running it.** Two catalog saves one second apart started two apply runs that
finished out of order, 13:36:15Z and 13:36:05Z, so the earlier save's run wrote last. Harmless
this time, because manager attributes do not reach the gateway, but budget modes will: a guard
against stale runs is being added with the modes, and a single queue-driven writer (P48) is the
full fix. Routes that FastAPI composes into an aggregate router needed the manager check on
their own routers, not only on the aggregate.

## P51 terminal FinOps, first release, 2026-09-24

**Delivered: `claude-finops`, merged from branch `claude-finops` at `00f296a`.** Nine terminal
views (Textual) and scriptable commands (Typer) share one engine, backed by Turnstile's API with
an Azure CLI token, by the gateway directly (Azure RBAC, Log Analytics and the repository's own
PowerShell writers), or by example data for tests and pictures.
[ADR-0018](adr/0018-terminal-finops.md); `docs/CLI-FINOPS.md`.

| | |
|---|---|
| **Scope** | The first-release routes are pinned by a parity test. Approvals, boosts, bulk allocation and the richer revision-4 views are listed as deferred in the parity manifest, not shown as controls that do nothing |
| **Changes** | Every budget change is previewed, rechecked against the server before the write, never retried, and removal or a limit below usage needs typed confirmation |
| **Managers** | Follows Turnstile's `manager_scope` contract from `c0c345a`: null means unrestricted, an empty scope is still scoped, a team manager's parent unit is context and never a filter, a 403 reads "Not in your scope", and managers stay read-only |
| **Tests** | 93 offline tests; 18 example-only screen pictures at 80x24 and 160x48. `Test-All` runs them when `.venv-finops` exists and otherwise records an explicit SKIP |
| **Live** | 2026-09-24, owner only: command and terminal journeys agreed on identity, budgets, catalog, tiers, month totals (5,394,583 tokens, $1.923207 estimated) and 200 request ids. No live writes |
| **Gate** | The agent's completeness-audited packet gate passed on `00f296a` in 25 min 43 s with all 32 registered checks present in the raw summary |

Found at merge: the CLI's check is registered only when its venv exists, so a copy of the runner
without the venv recorded SKIP, and `Test-RunnerIntegrity` expected every registered check to
run. The invariant it now asserts is the one the false pass broke: every registered check has a
result in the summary, PASS, FAIL or an explicit SKIP; the checks not skipped all run; and the
final lines count the skips. Open: **U20** (scale, and the two sources' totals differ by design).

## A gate that passed on 9 of 32 checks, 2026-09-24

Found while merging P19, before anything was pushed: the packet gate on `c938ec9` passed in 57
seconds. `Test-All.ps1` had run 9 of its 32 checks. A second `Test-All` in another worktree held
the PowerShell 5.1 wizard's fixed temp file, the write threw, and a terminating error travels up
to the nearest `try`: the one around every check. The summary counted only the results it had and
printed "All checks passed." That receipt is not counted.

| | |
|---|---|
| **Fix** | Each check catches its own error and records FAIL; a run that stops early fails; a registered check whose script is missing fails; both wizard tests use one temp file per run |
| **Proof** | `tests/Test-RunnerIntegrity.ps1`, 17 assertions on a copy of the runner with stub checks: a locked-file error, a thrown error, exit 1 and a missing script. Removing the per-check catch still fails the run through the completion guard; removing both reproduces the false pass. Before the fix, 9 assertions failed: exit 0 with 10 of 32 stubs run |
| **Earlier receipts** | They ran for 20 to 30 minutes; a run cut short at the wizard check takes about one |

## P45 acceptance criteria — delegated management, phase 1

- [x] `Turnstile.Viewer` and `Turnstile.Manager` exist beside `Turnstile.Admin`, created by the repository's script as the application's owner, with no directory role
- [x] Tokens carry only the groups assigned to Turnstile, so a manager's token can name their manager groups
- [x] An admin signs in as Owner, a viewer or manager as Member, read-only, and anyone else is refused before an account is written: 21 new tests in the fork
- [x] A person signs in through the Azure CLI with no consent: a link in 13.4 s, a session as role `owner`, method `entra`, and the same link again 401
- [ ] A manager limited to the units and teams of their manager groups, and the admin's enforcement modes (P46)
- [ ] The normal **Sign in with Microsoft**: needs the one-time consent (**U19**)
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| `New-ClaudeTurnstileEntraApp.ps1` as the app's owner | Added `Turnstile.Viewer` [User/Application], `Turnstile.Manager` [User] and the ApplicationGroup claim; nothing else changed |
| Turnstile's consent grants | None: every Entra user sees Need admin approval |
| A Turnstile token from the Azure CLI | Issued with no consent, carrying `roles=[Turnstile.Admin]` |
| `Open-ClaudeTurnstile.ps1`, then the link in a browser | Link in 13.4 s; session `owner`, `entra`; code gone from the address; the same link in a fresh browser 401 |
| Turnstile redeploy | 630 s; `ENTRA_VIEWER_ROLE` and `ENTRA_MANAGER_ROLE` kept |

**Found by running it.** Nobody in the tenant had ever consented to Turnstile's web sign-in, so the
Microsoft button had never worked for anyone, the owner included; every earlier Entra check had
used the Azure CLI. The fork's `member` role already hides every management control, which is what
made mapping viewers and managers to it a sign-in change rather than a new role.

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Entra decides who; the scope arrives in the person's own token, so no directory permission is needed to read it |
| Coder | Accept | One mapping serves the web sign-in and bearer tokens, so the two cannot drift |
| QA | Accept | The single-use, expiry and workload refusals are tested, and the live link was replayed to prove it |
| Security | Accept, with a reservation | Until P46 a manager sees what a viewer sees; the code is stored hashed, lives a minute and opens only a person's session |

## P44 acceptance criteria — governance authored in Turnstile

- [x] Business units, teams, their Entra groups, budgets and tier limits are edited on Turnstile's pages, with no script for the Turnstile administrator
- [x] A save starts the gateway's apply job, and the gateway enforces it: a tier limit read on the gateway 112 s after **Save and apply**, a budget refusing the next request 123 s after the save
- [x] Turnstile gains one power, starting one job; the job's identity may write the gateway's named values and nothing else
- [x] Governance moves to Turnstile with one command, which seeds Turnstile once; registering the schedule again neither seeds it nor restarts it
- [x] The start of a month never reads as every budget removed: Turnstile rolls the month in before the apply reads it
- [x] No group that cannot be confirmed is applied, tier limits always are, membership is never rewritten from groups that could not be read, and a catalog with no business unit is refused
- [ ] New groups and membership refreshed by the job: needs `GroupMember.Read.All` from a tenant administrator, which the reference tenant's operator cannot grant (**U17**). The script is `Grant-ClaudeGovernanceGraphAccess.ps1`
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| `Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Turnstile` | 249 s: 3 organizations, 5 departments and 2 tiers seeded; the writer role and Container Apps Jobs Operator granted; validation `ok` |
| **Apply now**, through Turnstile's API | The job started in 1.9 s and succeeded after 152 s: 33 s for the container to start, 55 s to add PowerShell, sign in and fetch the commit, 64 s the pass |
| Standard tier 20,000 to 20,001 on the Gateway governance page | Read on the gateway 112 s after **Save and apply**; put back the same way in 109 s |
| Team budget 1,666,666,666 to 1,000, saved in Turnstile | The first refused request 123 s after the save: 403 `rate_limit_error` naming the unit. Put back: 200 after 102 s, and the registry read back as it was |
| The schedule registered again | Turnstile's tier record and its API's last-modified time unchanged |
| Eight named values read one at a time, against one list call | 21.3 s against 3.1 s, the same values |
| Offline | `Test-TurnstileGovernance.ps1` 132 of 132, 51 new; the fork's 27 API tests and 9 page-rule tests |

**Found by running it.** The first live apply wrote the registry only to reorder it; entries are
now compared by name, as the policy reads them. The pass spent 21 s reading eight named values
one at a time; it reads them in one call. Turnstile's redeploys keep the app's settings, because its
release step merges them, so the apply job's setting survives them. The plan had assumed the
opposite. Turnstile's API answered 405, not 404, for the route it did not have yet. The guide's
one-enforcer check matched the phrase anywhere on the page, and the new section uses it, so the
mutation that drops the section went uncaught; the check now looks for the section. The first gate
failed on the Graph check's address, which carried an `&`: on Windows `az` runs through
`cmd.exe`, which ends a command there, so an administrator's run would have misread the result.

**Found before it ran.** Registering the schedule runs Connect, and Connect seeded Turnstile
whenever governance was Turnstile's, which would have overwritten every save on each
registration; it now seeds on the change only, and a failed seed leaves governance with the
gateway. A new month has no budgets in Turnstile until its five-minute timer rolls the last month's
in, which the apply would have read as every budget removed; Turnstile now rolls the month in when
the apply asks. With the directory unreadable, a tier's limits were dropped whenever its group had
a name other than the default. An empty catalog would have emptied the registry. Connect wrote
Turnstile's app setting on every run, restarting Turnstile's API each time. And at scale the
gateway reads membership from the projection, where the job would have tried to write every member
into a named value that holds about 110; it now leaves membership to the projection's own sync.

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Turnstile stays out of the request path. Its one new power is starting a job whose code and permissions this repository fixes |
| Coder | Accept | The registry format keeps one implementation, and a round trip from the gateway through Turnstile and back is tested |
| QA | Accept | 20 new mutations, all caught; the apply is tested against a gateway held in memory, not by reading its source |
| UX | Accept, with a reservation | About two minutes from save to effect, most of it the job starting, and the page shows the last apply. Membership waits on a tenant administrator (U17) |

## P39 acceptance criteria — Turnstile, from the gateway

- [x] Units, teams and budgets appear in Turnstile, read from the gateway rather than configured twice
- [x] Every request and every hour of cache reads reaches Turnstile exactly: its own ingest code accepts every event unaltered
- [x] Sending the same window twice counts once
- [x] A budget edited in Turnstile is enforced by the gateway, and only after `-Apply`
- [x] Only an assigned administrator can use Turnstile, and the refusal comes from Entra
- [x] Nothing about the Turnstile deployment is written into a script: it is discovered, stored on the gateway, and changed by the same command
- [x] What it costs is read from what is deployed and today's list prices
- [x] Scheduled export and sync as a workload identity (P40): an hourly Container Apps job with no secret ([ADR-0014](adr/0014-turnstile-beside-the-gateway.md)). Run live: it sent usage and wrote a changed budget as `app:<job identity>`, and was refused (`401`) once its Event Hubs grant was removed
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

| Measured | Result |
|---|---|
| Turnstile's `UsageProcessor` at `4e93935` on the exported file | 561 of 561 accepted, none skipped, altered or estimated; $2.972987 sent and stored |
| The same 557 events sent twice to the live hub | 1,114 messages in, 557 calls and $2.972581 stored |
| Budget set to 1,000 in Turnstile, `-Apply` | 57 s; the next request 403 `rate_limit_error` naming the unit; restored, then 200 |
| Admin group's assignment removed | `AADSTS50105` 5 s later; restored, a token again 22 s later |
| 30-day backfill, hourly against day slices | 586.5 s against 66.9 s |
| Turnstile at rest, Central US list prices | $158.84 a month, $62.05 of it a usage observer this integration does not use |

**Found by running it.** Turnstile skips an event with any field it does not define, zeroes a row
with a null count, and pins its reconciliation window on an estimated row it cannot match; the
export checks all three before sending. The batch check's estimated-row guard was untested until
its mutation went uncaught. Upstream Turnstile's catalog is demo data, its sign-in accepts any
organization, and its deployer does not run on Windows; the fork fixes each, in four branches to be
offered upstream (P41). Two working notes were wrong and never reached the guide: object-id rows
are 3, not 20, and an 85 s refusal delay was not reproduced — the refusal came on the first
request after `-Apply` returned.

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Turnstile stays out of the request path; a Turnstile outage cannot refuse a Claude call |
| Coder | Accept | The connection lives in one quote-free named value, because `cmd.exe` strips quotes from JSON arguments |
| QA | Accept | 15 mutations, all caught, after one gap was closed |
| UX | Accept | One command per step, each safe to re-run, with a portal path beside the script |
| Security | Accept | Single tenant, assignment required, role checked on every token; pictures redacted in the page and refused if a real value survives |

## Where P19 stands, 2026-09-24

**Hardened and measured at 500,000 records, but still not the default.** The four review findings
recorded on 2026-09-23 that were code are fixed, deployed to the Premium v2 test gateway, and
measured there. The default install still holds about 93 developers, because the installer still
writes named values: `cos-default` and `cos-upgrade` are not built.
[ADR-0017](adr/0017-projection-freshness-and-admission.md) records the design.

| Finding from 2026-09-23 | Now |
|---|---|
| The resolver accepted a record of any age | Each complete directory observation stamps every member it keeps with a reconciliation generation and an absolute expiry: 7,200 s by default and at most, 60 s at least. The resolver and the gateway's cache both check it, and the cache TTL is clipped to the time left. Measured: a record whose lease was cut to 20 s answered 503, naming the expired projection, although the gateway caches entries for 60 s; restored, it answered 403 again |
| A burst of misses reached the resolver unthrottled | The gateway admits at most 100 concurrent misses and 200 a second before calling the resolver, and answers the rest with a retryable 429 (`Retry-After: 1`). The resolver coalesces concurrent reads of one identity within a process, holds at most 100 distinct reads, and gives up after 3.5 s. Two always-ready instances take 100 concurrent requests each |
| The sync read one page of existing records | Both writers read every continuation page, empty ones included, before publishing, and fail on a repeated token or a failed page |
| `projection.bicep` defaulted to a public account | The enterprise default is private-only; public and selected-IP stay explicit choices |
| Rollback can regrant leavers; allowance is local to one gateway | Not changed: design, not code |

Measured 2026-09-24:

| | |
|---|---|
| **500,000 records** | A throwaway container loaded in 524 s, 954 records a second, 2.95 M RU (5.9 RU a write). 500 point reads of the first, middle and last records cost 1 RU each: p50 47.5 ms, p99 51.0 ms, max 72.1 ms. The container was deleted. This measures storage, not a directory scan or 500,000 people at once |
| **First requests** | 20 concurrent misses right after deployment: no 503, slowest 2,334 ms. The same after 16 minutes idle: no 503, slowest 1,105 ms. Before the fix, 2 of 3 first requests after idle returned 503 |
| **Bursts** | 100, three of 50 and three of 100 concurrent misses: no 503, slowest 1,682 ms. 500 primed connections at once: 279 answered, 221 retryable 429, no 503 |
| **Miss overhead (U14)** | 100 misses against 99 hits: 81 ms more at p50, 192 ms more at p99 |
| **Gate** | Packet gate PASS on `8a19524` in 29 min 35 s; 57 of 57 projection mutations caught |

The lease has a running cost. Every member the scan keeps is written again, changed or not, so the
scan has to run at least hourly and finish inside the lease. At 500,000 members that is about 365
million writes a month: about $538 a month at the measured 5.9 RU a write and $0.25 per million RU,
on top of $91.56 a month at rest, which is $26.28 more than with one warm instance (derived, list
price).

**The test gateway's leases expire at 2026-09-24T15:58:49Z.** Nothing reconciles there on a
schedule: the runner is stopped, and an unattended scan needs `GroupMember.Read.All` (U17). After
that time the test gateway answers every request with 503 until someone reconciles again. That is
the fix working, not a fault.

Still missing before 500,000 can be claimed:

- **Counters at that cardinality (U9).** Unchanged: narrowed, not closed.
- **A scheduled directory scan of 500,000 members.** It needs U17 and has not been run at that size.
- **Coalescing across instances.** It is per process, so two instances can both read one identity.
- **Bursts of different identities, a regional failure, and allowance retention on failover.**
- **Making it the default** (`cos-default`) and a one-command move for existing gateways
  (`cos-upgrade`).
- **Foundry quota.** Unchanged: the model deployment, not the gateway, is the first limit
  ([SCALE.md](SCALE.md)).

## Where P19 stood, 2026-09-23 (superseded by the section above)

**Not finished, but no longer only designed.** The default install still holds about 93
developers, because the projection is not the default and has not been load-tested at 500,000.
What changed is that the whole path now exists and was run: deployed with no public endpoint,
populated, compared, flipped to, failed over, rolled back and flipped to again, on a Premium v2
gateway in Canada Central with the Cosmos account in East US 2
([SECURE-PROJECTION.md](SECURE-PROJECTION.md)).

| | |
|---|---|
| **Built and run** | `infra/resolver.bicep` (the resolver's template, which did not exist), `infra/projection-network.bicep` for an existing VNet, the in-network writer `sync/`, and the projection-against-gateway comparison |
| **Found by running it** | A missing record answered 503 instead of 403; the two syncs charged nested teams to different business units; `Sort-Object` reordered units of equal depth; a gateway redeploy would have removed its VNet integration; the Deploy to Azure template was the first commit's. All fixed |
| **Cost** | $69.09 a month at 500,000 developers, $65.28 of it at rest — five private endpoints, five zones, one warm resolver instance |
| **U15** | Closed: a management-group Modify policy, `CosmosDB_PublicNetwork_Modify` |

Still missing before 500,000 can be claimed:

- **Counters at that cardinality (U9).** Narrowed, not closed: 500,000 identities were accepted
  and charged, but no allowance was exact ([SCALE.md](SCALE.md)). The resolver's p99 on a miss (U14)
  is: 301 ms, with 389 ms the slowest of 150 ([SCALE.md](SCALE.md)).
- **Foundry quota.** One capacity unit is 1 request and 1,000 tokens per minute (measured), so
  the model deployment, not the gateway, is the first limit — see [SCALE.md](SCALE.md).
- **The resolver after idle and under a burst (U18).** With no always-ready instance, 2 of 3 first
  requests after idle returned 503; with one, the first burst of 20 concurrent misses returned
  four. Nothing coalesces concurrent misses.
- **Making it the default** (`cos-default`) and a one-command move for existing gateways
  (`cos-upgrade`).

Found by review, 2026-09-24, and checked against the code before being recorded here:

| Finding | Checked | Fix to make |
|---|---|---|
| The resolver accepts a record of any age. A stopped sync keeps access indefinitely, so the cache TTL does not bound revocation | No expiry, age or generation check in `resolver/src/entitlement.mjs` | A completed-reconciliation generation with an absolute expiry, enforced by the resolver and the cache; an expired projection answers 503 |
| The resolver is called before any limiter, so a burst of cache misses reaches it unthrottled | First `send-request` at line 98 of `infra/policy.xml`, first limiter at line 298. Measured 2026-09-24: every concurrent miss reached the resolver, and the first burst of 20 returned four 503s (U18) | Miss-path backpressure and request coalescing, with Cosmos deadlines under five seconds |
| `Sync-ClaudeProjection.ps1` reads existing records with one query and no continuation, so a revocation beyond the first page is never planned | One `POST .../docs`, no `x-ms-continuation` | Page through continuation tokens. Not changed yet: it needs a Cosmos account reachable from the test machine, and every account in the test subscription is private (U15) |
| `projection.bicep` defaults to a public account | `param networkAccess string = 'public'` | Make the enterprise profile private-only |
| Rolling back to the named-value lists after the flip can regrant leavers, and allowance counters are local to one gateway | Design, not code | Keep both destinations current for a bounded rollback window; treat a replacement or failed-over gateway as restoring allowance (U9) |

Fixed at the same time: `sync/src/apply-projection.mjs` reported `ok: true` when writes or deletes had failed, though it exited 3. It now reports the outcome.

## Where P19 stood, 2026-09-17 (superseded by the section above)

**Not finished, and the shipped product still holds about 93 developers.** That number is
measured, not estimated: `Measure-ClaudeCeiling.ps1` against the reference gateway reports
`bu-members` at 218 of 4,096 characters with room for 88 more entries. Nothing about the 500,000
requirement is in the running product today.

What is settled:

| | |
|---|---|
| **Platform** | Cosmos DB serverless plus a Function resolver — [ADR-0011](adr/0011-projection-platform.md) |
| **Cost** | $11.11/month at 500,000 developers, computed by `Measure-ClaudeProjectionCost.ps1`, after deploying corrected the first figure |
| **Shape** | Two orthogonal switches rather than a size ladder — [ADR-0012](adr/0012-store-and-availability.md) |
| **Storage risk** | Retired. Point reads measured **1 RU flat** at ~1, 500, 20,000 and 100,000 records, 24–47 ms. The collection growing does not make a lookup cost more |
| **Migration** | Shadow comparison built and negative-tested — [ADR-0009](adr/0009-shadow-migration.md) |

What is not built, and is what a 500,000-developer deployment needs:

- **Population.** Nothing writes the projection from Entra. Backfill was measured at ~190
  records/second, so 500,000 identities is about 45 minutes — a number, not a design.
- **The resolver.** No Function exists. It must be Flex Consumption, because Y1 Consumption has no
  VNet integration and the Cosmos account comes back with public access disabled.
- **The policy path.** `cache-lookup-value` plus `send-request` to the resolver, with the failure
  contract ADR-0005 requires: bounded stale authorization, deny past the limit, and never treat a
  lookup failure as user-not-found.
- **The switches.** `-EntitlementStore` and `-ProjectionHa` are described in ADR-0012 and
  implemented nowhere.

The infrastructure template exists and has been deployed once and verified, then torn down —
`infra/projection.bicep`, partitioned on `/oid`. There is no Cosmos account or Function in the
reference resource group today; `az cosmosdb list` and `az functionapp list` both return nothing
belonging to this accelerator.

**The one open input is still not a technical one:** how long the gateway may keep serving someone
the directory has already revoked. That number sets the cache window, and the cache window sets the
cost — 15 minutes is $15.69/month, 4 hours is $0.84. It costs nothing to decide and the design
cannot be finished without it.

## The P19 platform decision, 2026-09-17

The operator chose **Cosmos DB serverless with an Azure Function resolver**, recorded as
[ADR-0011](adr/0011-projection-platform.md). ADR-0005 decided what entitlement becomes and
deliberately did not name a platform; this names it and prices it.

**The standing-cost objection does not survive the arithmetic.** At the full requirement — 500,000
developers, 50,000 active on a working day, a 60-minute cache window — it is **$11.11 a month**:
$1.56 Functions, $2.20 Cosmos request units, $0.05 storage, $7.30 private endpoint. Computed by
`scripts/Measure-ClaudeProjectionCost.ps1`, not quoted, because the number that decides it is the
cache miss rate and nobody can look that up.

The reason it is that small: the resolver is called **once per cache window per active developer**,
not once per request. A developer making 500 calls an hour and one making 5 cost the same.

| Cache window | Misses per month | Per month | A revoked developer keeps working for up to |
|---|---:|---:|---|
| 240 minutes | 2,200,000 | $8.14 | 4 hours |
| 60 minutes | 8,800,000 | $11.11 | 1 hour |
| 15 minutes | 35,200,000 | $22.99 | 15 minutes |

Every row is affordable, and most of each row is a fixed endpoint charge, so **the window is a
revocation decision, not a budget one**. That reframes the one question still open from ADR-0005: it
was never going to be settled by cost.

### The first draft of the costing was wrong, and deploying found it

ADR-0011 originally said $3.81 on Functions Consumption with no private networking. Deploying
`infra/projection.bicep` to the reference subscription returned an account with
`publicNetworkAccess: Disabled`, enforced above the resource group — an update to enable it reported
success and changed nothing. Nothing in the template asks for that; the governance baseline imposes
it.

Two consequences, and an accelerator aimed at six-figure organisations has to assume both:

- Cosmos needs a **private endpoint**, $7.30 a month, billed whether anyone calls the gateway or
  not. It is the first line in this accelerator that bills at rest.
- The resolver **cannot run on Consumption**: the Y1 plan has no VNet integration. Flex Consumption
  does and keeps per-execution billing, so the cost line is unchanged — but the plan originally
  named could not have reached the database at all.

Neither was visible from a pricing page.

**What it costs in latency, not money.** Serverless offers no guaranteed throughput or latency, and
caps at 5,000 RU/s per physical partition — against an average under 15 RU/s at full scale, so
headroom is not the concern. It is survivable only because the resolver sits behind the APIM cache,
which is why ADR-0005 put it there. Functions Consumption cold starts land in p99 on a miss; the
escape is a Premium plan with a warm instance, and that does carry a standing bill.

**Still not decided:** the staleness window itself, and when to build. Eight identities against a
binding ceiling of about 93 — `Test-ClaudeHealth.ps1` flags at 80%.

### Two corrections to SCALE.md, 2026-09-17

**The binding ceiling was the wrong number.** The page headlined *"the binding limit is 110
developers per tier"* while its own table already gave the business-unit map as about 93. Both
figures were right; the prose picked the larger one. A `bu-members` entry is `oid=unit,` — 38
characters plus the unit name, against 37 for a bare object id — so with a six-character unit id it
holds 93 and a longer name holds fewer. Business-unit membership runs out first, and planning
against 110 over-plans by roughly a fifth. Measured on the live gateway: `allow-*` 38 characters per
entry, `bu-members` 44.

**The token-claim alternative was never written down.** The first thing a reviewer proposes for P19
is to put the tier in an Entra app role or the `groups` claim and drop the lookup entirely — no
projection, no resolver, no standing cost. It cannot work: the policy validates the audience
`https://cognitiveservices.azure.com`, a first-party Microsoft resource, and app roles and the
groups claim are configured on the application registration that the token is issued for. Nobody
here owns that registration, so there is nowhere to put the claim. Recorded so it is not
re-proposed each review.

### What P19 actually needs from the operator

Three decisions, and only one of them is technical:

| | |
|---|---|
| **When** | Not yet, on the reference gateway: 8 identities against a ~93 ceiling, and `Test-ClaudeHealth.ps1` flags at 80%. For an organisation that already has more than about 90 developers, the answer is *before rollout*, because the ceiling is reached on the first day rather than gradually |
| **The staleness window** | How long the gateway may keep serving someone the directory has already revoked. Today's implicit answer is "until the next sync", unbounded and unstated. Costs nothing to decide and is the input the design needs |
| **What hosts it** | The billable one. Raising the APIM SKU is the tempting wrong answer — Standard v2 raises the *count* of named values, not the 4,096-character limit per value, which is what binds |

## P37 acceptance criteria — chargeback counts cache reads

Chargeback omitted cache entirely. On measured usage cache is 38.7% of real cost weight, and the
omission is **uneven**: a team reusing a large cached prompt is under-charged against one that does
not. That is the distortion that makes a chargeback figure arguable, which is the one thing it
cannot afford to be.

- [x] Cache read is attributed to a business unit, from a source that carries the object id
- [x] It is reported beside the metered total, not inside it
- [x] Priced at its own rate (0.1x base input), not the blended mix
- [x] What is still missing is stated rather than implied
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**The recorded blocker was drawn too broadly.** U12 said "no APIM-native source carries the cache
categories". True per request — the log's token columns are `PromptTokens`, `CompletionTokens` and
`TotalTokens`, and that was properly measured. Not true in aggregate: the gateway's own
`llm-emit-token-metric` emits `Prompt Cached Tokens` carrying a `UserId` dimension.

Measured live 2026-09-17 before building anything:

| | Result |
|---|---|
| `AppMetrics`, `Prompt Cached Tokens`, 30 days | 162 rows, **6,833,717** tokens |
| Dimensions on the metric | `UserId`, `User`, `Tier`, `Model`, `SessionId` |
| `UserId` value | `43cc5304-...` — the same object id `bu-members` keys on |

So the join was available all along. The comment in `chargeback-ledger.kql` claiming the metric was
"bounded but **not per-user**" was simply wrong, and that one wrong clause is what kept the gap open.

**What the report now shows**, on the reference deployment over 30 days:

```
Id        Members   Budget           Used   Used %   Cache read
mcaps           4  5,555,555,555    6,105      0%    6,833,717
  ites-1        2  1,666,666,666    6,105      0%    6,833,717
```

6,105 metered tokens against 6,833,717 cache reads. The scale of what was invisible is the finding.

**Cache read sits in its own column, not inside `tokens_used`.** The quota still cannot see it, and
folding it into the same number would imply the budget counts it. Three states are now distinct:
reported and counted, reported and not counted, neither.

### What is still missing

Cache *write* — the 5-minute and 1-hour categories at 1.25x and 2x. They exist only in the Anthropic
response body, and reading that in an outbound policy buffers the response and ends streaming. The
report says so rather than implying cache is solved. Enforcement is unchanged and still blind to
every cache category, which is U13.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Per-user is the granularity chargeback bills at, so an aggregate metric is not a compromise here — it is the right shape |
| Coder | Accept | `union` in both directions rather than a join: a caller can have a metered request whose trace never landed, or a metric row whose request did not |
| QA | Accept | Two of the first four assertions passed while measuring nothing — `cache_read` matched three other fields, and "cache write" matched the comment. Both now assert the field and its value |
| UX | Accept | A separate column makes the previously invisible number the most striking thing in the report, which is what it should be |

## P36 acceptance criteria — the two things an admin does after go-live

- [x] A new model is one command: deploy-check, deploy, allow, price, and what developers change
- [x] The price book is configuration rather than code, and git-ignored because it may hold negotiated rates
- [x] Retiring a model is one command too, and keeps its price so past months still reconcile
- [x] Marketplace and extension controls are emitted for both clients from one input
- [x] The limits of those controls are stated rather than implied
- [x] One command answers whether the gateway needs attention at all
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**Forty-seven scripts, and no single answer to "is it healthy?"** `Test-ClaudeHealth.ps1` runs the
read-only checks and reports one verdict with the fix beside each finding. It composes the shipped
checks and reads their exit codes rather than reimplementing them, so there is no second copy to
drift. On the reference deployment it reports four passes, one failure (11 principals can reach
Foundry directly) and one warning (3 developers in no business unit).

Two bugs in it, both found by running it. Splatting an array passes arguments **positionally**, so
the entitlement check ran with the resource group as its first positional parameter and compared
0 identities against 0 — reporting "In sync" while measuring nothing. And `Write-Host` does not
travel on the success or error stream, so `2>&1` captured none of the sub-check output and sixty
lines printed over the summary meant to replace them; `*>&1` captures it.

**Four things have to agree for a model to work, and the third fails quietly.** Deployed, allowed,
priced, selectable. A model with no price is served and reported at **$0**, which reads as nobody
using it rather than as a configuration gap. `-List` marks it red and the command refuses to add
one unless `-SkipPrice` is passed.

**The Desktop profile was built and thrown away.** `New-ClaudeCodePolicy.ps1` assembled a `$desktop`
block — and its own comment said the keys were "emitted here so one run produces one tier's
complete profile" — but nothing ever wrote it. Every Desktop tab setting the script has accepted
since it was written reached no machine. It now writes `claude-desktop.managed-settings.json` and
`claude-desktop.reg`.

**A one-element array became an object.** `allowedPluginMarketplaces` is `object[]`. Piping a
one-element array to `ConvertTo-Json` unwraps it, so a single allowed marketplace was written as
`{...}` instead of `[{...}]` and would have been read as the wrong type. `-InputObject` fixes it.

**My own docstring claimed a feature that did not exist.** It said the command "offers to deploy it
when it is not" deployed; the code only threw. Astra's review caught it. `-Deploy` now exists and
uses the existing helper, so a quota refusal is still reported as quota rather than as a retry.

### Two more tests that measured nothing

The mutation reverting one model's price to doubles stopped being caught once the sandbox began
copying `config/`, because a developer's own `price-book.json` overrides the built-in table and
made it dead code inside the sandbox. The sandbox now copies only `*.example.json`.

The assertion that the Desktop profile is written matched the string anywhere in the file, so
commenting out the `Save` left it passing. Anchored at line start.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The price book belongs in configuration: a model release is an operational event, not a reason to edit and redeploy code |
| Coder | Accept | Both clients are emitted from one input, because two files kept in step by hand drift and govern half a fleet each |
| QA | Accept | Three defects here were found by running the thing rather than reading it, and two were tests that passed while measuring nothing |
| UX | Accept | `-List` answers "where am I" before anything changes, and the unpriced case is the one it shouts about |

## P25 acceptance criteria — state the overshoot, and stop calling it a hard cap

- [x] The bound is measured on a live deployment, not asserted
- [x] The worst case is used, not the median
- [x] Terms that cannot be measured here are named rather than filled in
- [x] Nothing is left changed: the override is restored in a `finally`
- [x] It is not described as a hard cap anywhere
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| Term | Measured |
|---|---|
| Telemetry lag | 193s worst, 87s median, over 102 requests |
| Propagation | 17s |
| Job interval | 300s, a parameter |
| **Window** | **511s** |

Roughly eight and a half minutes of continued spending after a threshold is crossed, plus
in-flight requests.

**Two bugs in the measurement itself, both found by running it.**

The first version polled: make a call, then query the ledger every few seconds until it appeared.
It reported *"not visible within 420s"*. The real lag was around 80 seconds. The poll loop wrapped
its query in `catch { }`, so a failing query and an empty result were indistinguishable, and the
answer came out four times too large. Replaced with `ingestion_time()`, which measures it directly
and gives a distribution instead of one sample.

The second was resolving the Log Analytics workspace with `[0].customerId`. The reference resource
group holds **three** workspaces and `[0]` was not the gateway's, so the first run reported "no
requests in the last 24h" against a ledger holding 29. This is the same shape as the bypass audit
picking the wrong Foundry account with `[0].name`. It now refuses an ambiguous group and names the
workspaces.

Both failures shared a property worth naming: each returned a plausible number rather than an
error. A measurement that cannot fail loudly is not a measurement.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The bound is the honest description of what the architecture can do; naming it a hard cap would be a claim the request path cannot support |
| Coder | Accept | Propagation had to be observed through the gateway — ARM returns the new value instantly and says nothing about when the policy sees it |
| QA | Accept | Both defects produced believable numbers. The silent catch is now asserted against, and `[0]` selection is asserted against by name |
| UX | Accept | The window is reported in seconds with its terms itemised, so an operator can see which one to shorten |

## P20b acceptance criteria — settle the financial semantics

Money code that is wrong is worse than none, because the output looks authoritative. P21 and P23
both compute dollars and neither should be built before the rules are the same in both.

- [x] Eight questions answered in [ADR-0010](adr/0010-financial-semantics.md), each grounded in a recorded measurement
- [x] The implementation moved to decimal to match the decision
- [x] Rounding behaviour asserted on values, not on source text
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The ADR said money is decimal; the code was `[double]` throughout — `$Usd`, `$MonthlyBudgetUsd`,
`$OutputShare` — and token spend was accumulated as `0.0`. Writing the decision without changing
the code would have left a document contradicting the thing it describes, which is the failure this
session has spent its time removing elsewhere.

After the change, $5,000 converts to 1,388,888,888 tokens and back to exactly $5000.00.

**A test that asserted nothing, caught before it shipped.** The first rounding assertion claimed
that rounding per row differs from rounding once, using 333,333 tokens. Under decimal accumulation
both came to 3.60, so the assertion asserted a difference that did not exist. The apparent
difference in the earlier manual check — 3.5999999999999996 — came from `Measure-Object -Sum`
promoting to double, not from the rounding at all.

Replaced with an input where the rule genuinely bites: 1,389 tokens is $0.0050004 and rounds to a
cent on its own, so three rounded rows total $0.03 while the same 4,167 tokens priced once is
$0.0150012 and rounds to $0.02.

**A mutation that proved the guard was weak.** Reverting one model's price to doubles was not
caught. Two reasons, both worth recording: the source assertion matched the three other models that
were still decimal, and PowerShell promotes to decimal when *either* operand is decimal, so a double
price book still produced decimal output while `OutputShare` stayed decimal. The price book's type
was a latent problem, not a visible one. The assertion now walks every entry and checks its runtime
type.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The eight questions are the ones that have to agree across P21 and P23; settling them separately is why those two can now be built independently |
| Coder | Accept | Decimal is the mechanism, but the property is reproducibility — a chargeback figure that changes between two runs cannot be argued with |
| QA | Accept | Both defects here were tests that measured nothing, and both were found by running the mutation rather than by reading the assertion |
| UX | Accept | "Soft cap" is the term most likely to be misread by a finance reader, and it now says which of the two meanings it has |

## P19b acceptance criteria — migrate without resetting allowances

- [x] The sequence is written down, with authorization unchanged until the canary — [ADR-0009](adr/0009-shadow-migration.md)
- [x] Phase 2's comparison ships and runs against a live gateway
- [x] It resolves tier with the policy's precedence, so it cannot invent drift
- [x] It was negative-tested by creating real drift, not assumed to work
- [x] A rollback restores authorization and never consumption; counter keys are preserved
- [x] The mid-period opening balance is deferred to P20b rather than quietly decided
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The comparison had to be negative-tested, because a comparison that always says "in sync" is
indistinguishable from one that is not measuring. Removing the test service principal from
`claude-code-premium` in Entra, without running the sync, produced:

```
stale (1)
  On the gateway, not in the directory. Still entitled after removal.
  d6cd24b0-...  gateway: premium   directory: denied
```

and exit 1. Re-adding it returned the comparison to clean. That is also a demonstration of the
revocation gap documented in ONBOARDING.md: removal from a group does not take effect until the
sync runs.

The Graph membership read moved to `ClaudeGraphMembership.ps1` and is now shared by the sync and
the comparison. Two readers of the same directory that implement the read separately will drift,
and this particular read took six measured combinations to get right.

The extraction was caught by the existing tests, which is what should happen: five assertions in
`Test-Teams.ps1` failed because they pointed at the old location. One mutation then had to be
repointed as well — `transitiveMembers/microsoft.graph.user` now survives only inside the comment
holding the measured table, so mutating it changed a comment and nothing failed. That is the
seventh instance of an assertion or mutation matching prose rather than behaviour.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Phases are ordered by blast radius: everything before the canary is observation, so being wrong costs a report rather than a 403 |
| Coder | Accept | Sharing the membership read is the whole point — a comparison with its own Graph call measures itself |
| QA | Accept | Proven in both directions against live Entra. A clean result now means something because a dirty one was produced on purpose |
| UX | Accept | `missing` and `stale` are named rather than both called drift; one is a developer waiting, the other is access that should have gone |

## P18b acceptance criteria — the load envelope

"500,000 employees" is not a capacity specification. It gives no rate, no concurrency and no
shape, so it cannot be designed against or tested.

- [x] Every ceiling the tooling enforces is measured, not copied from a document
- [x] The identity ceiling is derived from the character limit rather than written as a literal
- [x] `Measure-ClaudeCeiling.ps1` reports a live gateway's headroom and exits non-zero past a threshold
- [x] The five numbers a capacity figure actually needs are named
- [x] What has not been measured is stated rather than filled in
- [x] A capacity test is defined by what it must prove, not by how many keys it creates
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| Measured on BasicV2 | Result |
|---|---|
| Named value of 4,096 characters | Accepted, HTTP 201 |
| 4,097 characters | Rejected, HTTP 400 `ValidationError` |
| 110 object ids (4,071 characters) | Accepted |
| 111 object ids (4,108 characters) | Rejected |

So a tier holds **110 developers**, which ADR-0005 already stated and this confirms exactly.

Two things the measurement changed:

**Per-entry cost is not constant.** A `bu-members` entry carries `oid=unit` and costs 44 characters
against a bare object id's 37. Assuming 37 overstates remaining room by about 19% on the list that
fills first, so the script measures the real cost from the data it is reading.

**Sharding looks like it works and does not.** 5,000 named values x 110 identities is 550,000,
which clears a 500,000 requirement on paper. It requires the policy to scan every shard on every
request. The arithmetic was never the constraint: materialising 500,000 records in a data store is
unremarkable, and materialising them in API Management policy configuration is what cannot work.

### What was deliberately not done

The traffic half is empty. The reference deployment's ledger holds **111 requests across 2 days**,
and an envelope extrapolated from that would read as evidence while being none. The page states the
method and the traffic-independent ceilings, and says why it stops there.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Confirms ADR-0005's premise by measurement rather than restating it, and closes off sharding as the escape a reviewer would otherwise propose |
| Coder | Accept | The ceiling is derived from the limit, so it stops being correct out loud rather than silently if the service changes |
| QA | Accept | The README reachability check was negative-tested: an unlinked page fails with its own name. Six pages were unreachable before it existed |
| UX | Accept | The report names what runs out first rather than listing limits, and the failure path says writes fail outright instead of truncating |

## P35 acceptance criteria — a service principal in a tier group is entitled

A tier group can hold a workload identity as well as people. Adding one was a silent no-op:
the portal listed it as a member and the gateway returned 403.

- [x] The sync reads service principals as well as users
- [x] The Graph request form is measured, not assumed — six combinations, one works
- [x] Proven on the live gateway: premium 2 members to 3, total 7 authorised identities to 8
- [x] A service principal in no business unit is attributed to `unassigned`, reported as 2 to 3
- [x] Three mutations, one per component of the request, each failing the run on its own
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The sync used `transitiveMembers/microsoft.graph.user`, which excludes workload identities by
construction. The obvious fix — add the `servicePrincipal` cast — returns an empty collection.

| Request | Returned |
|---|---|
| `transitiveMembers` | 3 — service principal missing |
| `transitiveMembers/microsoft.graph.user` | 2 |
| `transitiveMembers/microsoft.graph.servicePrincipal` | 0 — missing |
| the same, plus `ConsistencyLevel: eventual` | 0 — missing |
| the same, plus `$count=true` | 0 — missing |
| the same, plus **both** | 1 — found |

Graph answers 200 with an empty collection in the four failing rows rather than erroring, so
every wrong form reads as "this group holds no service principals".

The first fix attempt added the cast alone, was run against the live tenant, and changed
nothing — the sync still reported 2 members. That negative result is what produced the table.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Entitlement is identity-shaped, not person-shaped; a build agent calling the gateway is the ordinary case, not an edge one |
| Coder | Accept | Both casts are issued identically rather than leaving one subtly different, so the next reader cannot conclude the header is optional |
| QA | Accept | Caught only because the fix was run against live Entra and the count did not move. A source-only check would have passed on the broken version |
| UX | Accept | The measured table is in the code comment, the changelog and here, because the failing forms return success and look correct |

### Note

The first assertion written for the guide matched the phrase `service principal`, which appears
in the alt text and twice in the prose. The mutation that removed the explanation was missed.
This is the sixth time an assertion has matched prose rather than the claim; it now matches a
sentence that occurs once.

### Documentation review

`guide/ask-astra.mjs` asks gpt-6-astra to judge a page on four fixed points — jargon used before
it is explained, rationale placed ahead of the command, missing steps, and length that carries no
instruction. Run against `BUSINESS-UNITS.md`, `ONBOARDING.md` and `SETUP.md` it returned 22, 24 and 24 items.

Most were style. Four were factual errors, each verified against the live tenant before changing
anything, and each now carries an assertion and a mutation:

| Claim as written | Measured |
|---|---|
| A user's Groups blade shows "two rows, one per axis" | It lists direct memberships. One account shows two rows, another shows one; both resolve identically. The business unit never appears |
| Changing a tier is "one membership edit" and "nothing in the gateway changes" | Two edits, and the entitlement lists change when the sync next runs. The sync is not automatic |
| Revocation is `az ad group member remove` from `claude-code-standard` | Leaves a premium or dual-tier member entitled, and leaves business-unit membership behind |
| A disabled Entra account revokes access "at that moment, ahead of any sync" | It stops new tokens. `validate-jwt` does not call Entra per request, so an issued token works until it expires |
| `SETUP.md` Options B and C produce "the same result" as the wizard | Only `Install-ClaudeGateway.ps1` writes `onboarding/claude-gateway.json`; it is the single writer in the repository. The portal button deploys the template alone |

The last is the one worth keeping in view: it reads as a security control and is not one.

## P16 acceptance criteria — close the bypass

Every control in this repository governs traffic that passes through the gateway. A principal
with data-plane access directly on the Foundry account skips all of it.

- [x] `scripts/Get-ClaudeBypass.ps1` lists them, graded by what the role actually grants
- [x] Roles are classified from their `dataActions`, not from a name
- [x] Inherited assignments are included
- [x] The gateway's own identity is excluded
- [x] Exits non-zero on a finding, so it works as a check and not only a report
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The audit in `SETUP.md` 4.2 checked one role name by hand and reported clean. The reference
deployment had **11 assignments that could call Foundry directly**, plus four with partial
data-plane access.

| | |
|---|---|
| `Foundry User` grants `Microsoft.CognitiveServices/*` | The same as `Cognitive Services User`. Three assignments held it, and no version of this documentation mentioned the role. Matching role names would never have found it — classifying by `dataActions` did |
| Inherited assignments were invisible | Two of the three `Foundry User` grants came from subscription and resource group scope. They apply to the Foundry account and do not appear without `--include-inherited` |
| The first draft audited the wrong account | `[0].name` picked `dhwani` rather than the account the gateway calls, and reported 2 findings instead of 11. The account is now read from the gateway's own API backend |

Not remediated here. Several holders are Defender, deployment and platform service principals, and
removing them autonomously would break things that are not this repository's to break. The finding
is that the access is ungoverned, which is the operator's decision to act on.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The audit belongs next to the gateway because it measures the gateway's own assumption — that traffic arrives through it |
| Coder | Accept | Deriving the role set from `dataActions` is what makes this survive Azure adding another role, and it is the only reason `Foundry User` was found |
| QA | Accept | Verified against the live account, and the wrong-account bug was caught by reading the output rather than trusting the exit code |
| UX | Accept | Findings are graded rather than flattened, the removal command is printed with the scope the grant actually came from, and the output says to check a principal before deleting it |
| Security | Accept | Read-only. It reports and refuses to remediate, which is right: several holders are legitimate platform identities, and an audit that deletes things is one nobody runs twice |

## P17 acceptance criteria — named value writes fail loudly

Every named value write in this repository was made with `az apim nv update ... -o none 2>$null` and
no exit check. Named values cap at 4,096 characters, so past about 110 object ids the write failed,
the error went to `$null`, and the caller reported success.

- [x] `scripts/ApimNamedValue.ps1`, dot-sourced by both callers
- [x] An oversized value is refused before the request, naming the limit and how many entries fit
- [x] A failed write throws, carrying what the service actually said
- [x] No script writes a named value with errors suppressed — asserted, not just replaced once
- [x] The governance demo restores `tpm-standard` in a `finally`
- [x] Verified live: a valid write lands and reads back identical
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

The sync was the obvious victim: past ~110 members a tier stops updating while the run reports
success. The second one was worse. `Show-Governance.ps1` lowers `tpm-standard` to 100 to demonstrate
throttling, then restores it — with the same suppressed error and no `finally`. A failed or
interrupted demo left the **standard tier capped at 100 tokens per minute**, silently. That restore
now runs in a `finally`, and refuses to lower the value at all if it could not first read what to
restore.

Negative-tested end to end. A 150-entry allow list is refused with "5551 characters, which is 1455
over the limit ... roughly 107 fit", and an invalid write throws with the service's own
`ValidationError`. Neither created anything.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | One helper, dot-sourced, matching the existing `Show-Banner.ps1` pattern. No new dependency |
| Coder | Accept | The detector forbids the old shape repo-wide rather than fixing two call sites, so it cannot creep back. It skips comment lines, which it had to learn after flagging its own documentation |
| QA | Accept | Both failure modes negative-tested against live Azure, and the live half asserts a read-back rather than trusting the exit code |
| UX | Accept | The refusal says how far over the limit it is and roughly how many entries fit, so an operator learns the real capacity instead of a rejected request |
| Security | Accept | Entitlement failing loudly is the point: the old behaviour froze an allow list while reporting success, which is a stale-authorization bug wearing a green tick. The helper never echoes a value |

## P18 acceptance criteria — the chargeback ledger

- [x] `analytics/chargeback-ledger.kql`, one row per request with the caller attached
- [x] Built on `ApiManagementGatewayLlmLog`, a log rather than a metric, so no cardinality cap
- [x] Identity joined on `context.RequestId`, carried deliberately
- [x] Streamed requests carry correct completion tokens
- [x] Cache recorded as null with `cache_tokens_known = false`, never zero
- [x] Message capture left off; the template deploys both halves of the switch
- [x] Verified live, and both failure modes negative-tested
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**The quota scalar excludes cache tokens.** Two identical calls with a cacheable 10,000-token
prompt wrote and then read 10,003 cache tokens; both metered 16. Documented behaviour — "counts
prompt and completion tokens only" — but the consequence had not been drawn. Against thirty days of
live usage here, weighted at Claude's published rates, **38.7% of the real cost weight is invisible
to the per-user budget**. That is a property of the shipped P11 and P12 budgets, not of this packet,
and it is why P21 may not express a dollar budget as a token quota.

**The quota scalar is also wrong for streaming**, reporting 11 tokens for a 41-token completion. The
built-in log gets the same request right. Since streaming is most of Claude Code, that alone
justifies the move.

**Neither APIM source carries the cache categories.** They are in the response body, but reading it
in `outbound` buffers the response and ends streaming. The gap is recorded rather than closed.

**Two switches, not one.** `GatewayLlmLogs` on the resource decides where rows land;
`largeLanguageModel.logs` on the API diagnostic decides whether they are produced. Enabling only the
first found an empty table with a full schema.

### The test that measured nothing

The first version asserted that the `actor` column was populated. The query fills it with
`coalesce(actor, "unattributed")`, so it was always populated and the assertion passed while every
row was in fact unattributed — the join had not worked at all. It was caught by reading the output
rather than the exit code. The assertion now requires a real caller, and breaking the join key turns
it red.

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The ledger is a built-in log, so the scale fix costs no new component. The one thing written is the identity the log lacks |
| Coder | Accept | The join key is carried rather than inferred, because the two candidate ids look similar and are not |
| QA | Accept | Both failure modes negative-tested: a broken join gives 0 attributed, and a zero in place of null fails. The first version of this test was vacuous and is recorded above rather than quietly fixed |
| UX | Accept | A row says whether it was streamed and where its numbers came from, so a report can state what it does not know instead of implying zero |
| Security | Accept | `RequestMessages` and `ResponseMessages` are left unset and asserted off. Enabling LLM logs without that check would have turned on prompt capture, which P15 keeps opt-in |

## P20–P22 acceptance criteria — business units

A business unit is an Entra security group registered with a monthly budget.
[ADR-0007](adr/0007-business-unit-model.md) records why: a group already exists, is already
governed, and already has joiner/mover/leaver handling, so membership needs no second roster.

- [x] **P20** A stable identifier separate from the display name. The registry key is the
      identifier; renaming the Entra group does not move spend to a new line
- [x] **P20** Transfer is group membership, deletion returns members to `unassigned`, and a
      developer in two business-unit groups takes the first in registry order
- [x] **P22** A unit that exhausts its budget gets a fourth, distinct `403` naming the unit;
      other units are unaffected; an unpriced unit is skipped rather than walled off
- [x] Unassigned developers are allowed by default, because nobody has a unit on the deployment
      that first installs this. `bu-unassigned=deny` is the target state once the report reads zero
- [x] Verified live: add, list, edit and remove all work; sync mapped 3 developers to `platform`;
      the report showed 544 tokens and 1 unassigned; `x-bu-quota-remaining: 2222222195` came back
      on a real request
- [x] No regression: an unassigned developer still received HTTP 200
- [x] 66 assertions in `tests/Test-BusinessUnits.ps1`, and every one of the 11 things they guard
      negative-tested by `tests/Test-BusinessUnitsNegative.ps1`
- [x] `./tests/Test-All.ps1` passes offline and with `-IncludeAzure`
- [x] `node .ironclad/gate.mjs --stage packet` exits 0
- [ ] **P21** remains open. The admin surface takes dollars and the report is categorised, but
      enforcement converts to one blended token figure at write time. "One counter cannot represent
      money" was P21's acceptance criterion and it is not met — see **U13**

### What the work found

| | |
|---|---|
| Five of ten mutations survived the first negative run | The colon-in-group-name case was never exercised, so `LastIndexOf` versus `IndexOf` made no difference to any assertion — the entire reason the split is on the last colon was untested |
| `'38\.7|cache'` is an alternation | The word "cache" alone satisfied it while the measured figure was wrong. Split into two assertions |
| A caveat in a `<# #>` help block is not a caveat | `-match` over raw file text cannot tell a comment from output. Comments are now stripped, and the terminal and JSON surfaces asserted separately — matching either one passed while the other had been deleted |
| A refusal check scoped to the whole file tail | `$policy.Substring(IndexOf(...))` matched `businessUnit` 200 lines above the message. Now scoped to the branch that builds it |
| `Test-Discovery.ps1` printed FAIL and exited 0 | It fell off the end without an exit code, so `Test-All` read whatever the last child process left. `Test-PreflightBothHosts.ps1` never checked its result at all — both were in a suite whose PASS was partly vacuous |
| `RESULT=` is printed even when nothing ran | A failed dot-source is non-terminating, so the child carried on and printed an empty value. The check now requires `True` or `False` |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Membership comes from the group that already governs joiner/mover/leaver, so there is no second roster to reconcile. No new always-on component: three named values and a policy branch |
| Coder | Accept | The registry format has one owner, `ClaudeBusinessUnit.ps1`, read by the writer, the reader, the sync and the test. Splitting on the last colon is now covered by a case that fails on the first |
| QA | Accept | Eleven mutations, all caught — but only after five survived the first run and three assertions were found to measure nothing. That is recorded above rather than quietly fixed. Two unrelated suites that could not fail were repaired as a result |
| UX | Accept | Every command states list price and the cache gap in its own output, so a figure cannot be read without them. An edit reports the previous value alongside the new one |
| Security | Accept | No new identity path: membership is the same Graph read entitlement already does, under the same guard that refuses to empty a populated map. The refusal names the unit but not its members |

## P20c acceptance criteria — teams and tiers

[ADR-0008](adr/0008-teams-and-tiers.md) sets the model. A team is a business unit that names a
parent; tier is a separate axis attached by nesting the team group inside the tier group.

- [x] A request is charged to its team **and** to the unit above it. Verified live: one call
      returned `x-bu-quota-remaining: 1666666644` (ITES 1) and
      `x-bu-parent-quota-remaining: 5555555533` (MCAPS), with the org ceiling unchanged
- [x] Depth is capped at two and cycles are refused when written, not discovered when a budget
      stops cascading. Verified live: a third level was refused and **nothing was written** —
      the registry still held four units and no partial entry
- [x] Membership resolves to the most specific unit. Verified live: MCAPS transitively contains
      four people, all four were claimed by their teams first, and MCAPS itself took none
- [x] Tier resolves through nesting with no change to the tier mechanism. Verified live:
      `claude-code-premium` resolved to 2 members via the nested team, `claude-code-standard` to 5
- [x] Removing a business unit promotes its teams rather than leaving a dangling parent
- [x] A parent's reported figure is the roll-up of its own members and its teams, matching what
      its counter enforces
- [x] `./tests/Test-All.ps1` passes; 19 of 19 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| `transitiveMembers` returns nested **groups**, not only users | Measured on `claude-code-standard` with one team nested inside: 7 objects, 2 of them `#microsoft.graph.group`. `Get-GroupMemberOids` did not filter by type, so a group's object id would have been entitled and would have eaten a 4,096-character budget that holds about 110 ids. The defect predates teams and was unreachable only because nothing was nested |
| A client-side `@odata.type` filter would have been worse | Under the typed cast Graph omits that property, so the filter would have discarded every user. The cast `/transitiveMembers/microsoft.graph.user` filters server-side — measured 5 users, 0 groups |
| A test can assert the comment instead of the behaviour | The ordering check matched the prose explaining "most specific" and passed while the sort had been replaced with a constant. Fixed by extracting `Sort-ClaudeBuByDepth` and asserting against real data |
| A parent reads zero from the ledger | Members map to their team, so the roll-up has to be computed or the parent's percentage would contradict its own counter |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | A team is not a new object — it is a unit with a parent, so the ledger, the reports and the refusal path were unchanged. Tier stays orthogonal, so re-organising one axis does not disturb the other |
| Coder | Accept | The parent map is a second named value rather than a fourth registry field, because the group name may contain a colon and the budget is already found by splitting on the last one. A variable field count is where the previous defect in this area came from |
| QA | Accept | 19 mutations, all caught. One assertion was found matching a comment rather than behaviour, which is the same failure mode recorded in P20–P22 and was fixed by making the ordering a function with a data-driven test |
| UX | Accept | Teams are indented under their parent in both the writer and the reader, and the depth cap explains itself at the point of refusal rather than in documentation |
| Security | Accept | The typed cast closes a path where a group object could have been written into an entitlement list. No new identity surface: the same delegated Graph read as before |

## P26 acceptance criteria — the installer finds or creates a model

- [x] Claude deployments are listed with SKU and capacity, not just a name — a name alone does not
      say whether the deployment can carry the traffic
- [x] The operator chooses which models each tier may call, and the choice reaches the template.
      `modelsStandard` and `modelsPremium` were previously never passed at all
- [x] When no account has a Claude deployment, the installer offers to create one rather than
      stopping. Verified live: `foundry-plus-resource` has no Claude deployment and returned 12
      deployable Claude models, one row per model at its newest version
- [x] Selection matches on the model and publisher format, never the deployment name. Verified live
      on an account with **27 deployments**, of which 2 are Claude — OpenAI, OpenAI-OSS, Mistral and
      DeepSeek were all excluded
- [x] Quota is a distinct failure with its own advice, tested against both a quota error and an
      authorisation error
- [x] `./tests/Test-All.ps1` passes; 25 of 25 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

**A redeploy would have wiped every business unit, team and membership.** The installer preserves
`allow-standard`, `allow-premium` and `quota-overrides` by reading them off the gateway and handing
them back. `bu-registry`, `bu-members` and `bu-parents` were never added to that list, and their
template parameters default to `,,` — so omitting them clears them.

Confirmed with `what-if` against the live gateway:

| Parameters | Planned `bu-registry` |
|---|---|
| Omitted, as the installer did | `,,` — four units and two teams gone |
| Supplied, as it now does | `,mcaps=…,gbb=…,ites-1=…,ites-2=…` unchanged |

Every existing "a redeploy preserves X" assertion checked only the Bicep expression, never that the
caller supplied the value. The template was willing to preserve and nothing proved anyone asked it
to. Both ends are now asserted.

| | |
|---|---|
| Azure lists a model once per version | `claude-sonnet-5` came back as v1 and v2. Offering the same model twice is a choice nobody wants; newest wins |
| `$args` is an automatic variable | Assigning to it inside a function is at best confusing. Renamed |
| A `quota` match on the installer proves nothing | The installer contains `quotaStandard`, `quotaOrg` and more, so the assertion passed on unrelated text. The classification moved into `Get-DeploymentFailureReason` and is tested against both error kinds |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | The installer already holds the subscription context needed to create a deployment. Sending the operator elsewhere to do it by hand was a gap in the installer, not a property of the gateway |
| Coder | Accept | Deployable models are read from the account rather than hard-coded, because what is offerable depends on region and entitlement, and a hard-coded list goes stale and then offers something that cannot be created |
| QA | Accept | 25 mutations, all caught. The quota assertion was found matching unrelated text in the installer and was replaced with a function tested against a quota error and an authorisation error |
| UX | Accept | SKU and capacity are shown because they are what an operator changes when a deployment cannot carry the load. Opus is excluded from standard by default with the reason given at the prompt |
| Security | Accept | No new permission: creating a deployment needs the Cognitive Services contributor rights the operator already needs to stand up the gateway, and failure states which right was missing |

## P24/P27 acceptance criteria — the Observe half

- [x] The client that made the call is recorded. Nothing in API Management carried it — measured
      2026-09-16, `AppRequests.Properties` held only API and service metadata, `ClientType` read
      `PC`, `ClientBrowser` was empty
- [x] The surface is **parsed** from the agent string, not matched against a list. Verified live
      with the real Claude Code CLI plus Desktop-, VS Code- and SDK-shaped agents, all five
      distinguishable in one query
- [x] The queries are callable functions. Verified the window parameter is honoured rather than
      pinned: `ClaudeChargeback()` 44 rows, `(ago(2h), now())` 5, `(ago(30d), now())` 44,
      `(ago(1m), now())` 0
- [x] The publisher refuses when a window line has moved, rather than shipping a function that
      ignores its arguments
- [x] A workbook exists, bound to one workspace, updating in place on re-run
- [x] It refuses to publish against a workspace without the functions. Verified: pointed at a
      second workspace it named the missing function and the script to run first
- [x] Every currency figure on the pane says list price and states the 38.7% cache gap
- [x] No always-on component added — a saved search and a workbook both store and run nothing
- [x] `./tests/Test-All.ps1` passes; 39 of 39 mutations caught
- [x] `node .ironclad/gate.mjs --stage packet` exits 0

### What the work found

| | |
|---|---|
| The obvious guess at the CLI's agent string was wrong | Claude Code 2.1.241 sends `claude-cli/2.1.241 (external, sdk-cli)` — `sdk-cli`, not `cli`. A classifier written from the guess would have bucketed the real CLI as "other" and looked correct doing it. The surface is now extracted from whatever follows `external,` |
| A classifier in policy is a redeploy; in KQL it is a query edit | The policy captures the fact and the query interprets it, so a client that changes its agent string costs nothing to accommodate |
| A portal link built from the management endpoint opens nothing | `https://management.azure.com/subscriptions/...` concatenated after `#@/resource` produced a link that looked plausible and went nowhere. The ARM path is now kept separate from the base URL |
| A workbook bound to the wrong workspace reads as no usage | It renders empty rather than erroring, so both publishers refuse to guess when a resource group holds more than one |

### Council

| Seat | Verdict | Note |
|---|---|---|
| Architect | Accept | Observe was the last box in the flow with nothing behind it. It is filled with metadata only — a saved search and a workbook — so the constraint of not adding an always-on bill of materials held |
| Coder | Accept | The `.kql` files stay the single source; the publisher rewrites only the window lines and refuses if it cannot find them. A copy of the query inside the publisher would have been a second thing to keep current |
| QA | Accept | 39 mutations, all caught. The parameter check was made non-vacuous by proving four different windows return four different counts — a pinned function returns the same number every time and passes a weaker test |
| UX | Accept | Both publishers list, publish and remove, and refuse with the name of the script to run first rather than an Azure error. The caveats sit on the pane, not in a footnote |
| Security | Accept | The agent string is a request header the caller already sends, truncated and stored beside data already held. No prompt content is captured and no new permission is needed |

## Commands that prove it```powershell./tests/Test-All.ps1                                    # 17 checks, offline
./tests/Test-All.ps1 -IncludeAzure                      # plus the seven that call Azure
./scripts/Get-ClaudeTelemetry.ps1                       # where this gateway logs, and whether metrics are on
./scripts/Get-ClaudeAnalytics.ps1 -Days 30              # the usage report
./scripts/Get-ClaudeBudget.ps1                          # effective limits and spend to date
./scripts/Get-ClaudeBusinessUnit.ps1                    # budgets, members and spend by business unit
./scripts/Publish-ClaudeQueries.ps1 -List               # the callable KQL functions
./scripts/Publish-ClaudeWorkbook.ps1 -List              # the Observe pane, and where it opens
./scripts/New-ClaudeCodePolicy.ps1 -Tier premium        # one managed-settings profile per tier
./scripts/Find-ClaudeUserData.ps1 -User <upn>           # what is held about one person
./scripts/Get-ClaudeBypass.ps1                          # who can skip the gateway entirely
./tests/Test-OrgCeilingLive.ps1 -ProveRefusal           # exhausts each budget, then restores it
./tests/Test-BusinessUnitsNegative.ps1                  # breaks each business-unit check and confirms it goes red
node .ironclad/gate.mjs --stage packet                  # definition of done
```

## Next

P14 — the plugin marketplace — is the only packet left, and U6 rewrote its acceptance criterion.
Claude Code has no plugin signing scheme, so "signed accepted, unsigned refused" cannot be tested.
What can be tested is immutable approved content: a plugin pinned to a commit sha or archive
hash, a modified one refused on hash mismatch, marketplaces outside `strictKnownMarketplaces`
rejected, and `isDesktopExtensionSignatureRequired` enforcing publisher signing for `.mcpb`
bundles only. `docs/UNKNOWNS.md` U6 has the keys and the blast radius.

Three unknowns remain open. **U2** blocks putting a currency figure on spend. **U8** blocks the
four productivity fields P10 returns as null. **U3** — whether Claude in Chrome applies under a
third-party provider — is unexamined and affects only a parity-matrix row.

One thing outside the packet queue and worth doing: seven principals hold `Cognitive Services
User` directly on the Foundry account, which bypasses every budget in this repository.
`SETUP.md` section 4.2 has the audit commands.
