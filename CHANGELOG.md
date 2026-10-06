# Changelog

All notable changes to this project are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged in git. `docs/ROADMAP.md` holds the forward plan and
`docs/STATUS.md` the packet currently in flight.

## [Unreleased]

Business-unit chargeback. Budgets are set and reported in dollars, but three
limits apply to every figure here and are repeated in each command's output.

The token counter is blind to cached tokens: `llm-token-limit` "currently counts
prompt and completion tokens only", and on thirty days of live usage cache reads
were 6.8M tokens against 320K prompt and 152K completion — 38.7% of real cost
weight at Claude's published rates. Token budgets therefore bound less spend than
they appear to, always in the direction of under-counting.

Dollar figures are list price and do not reconcile to an Azure invoice, because
Azure bills Claude as one aggregated Claude Consumption Unit meter and
private-offer discounts apply before that conversion. **U2**.

A token budget is still enforced as one blended token figure converted at write
time, assuming a 20% output mix. Dollar budgets (P59, below) are enforced from
priced categories, including cache reads and writes, after each reconciliation;
exact streaming cache-creation detail remains **U13**.

### Added

- **P99 a snapshot of 500,000 developers reaches the runner within its apply-by time.** `Send-RunnerFile`
  (`scripts/ClaudeRunner.ps1`) compresses the file with gzip, sends base64url parts through up to 16
  `az container exec` calls at once, retries a failed part, stops an exec that does not answer, and
  assembles, decompresses and checks the file on the runner
  ([ADR-0053](docs/adr/0053-parallel-compressed-runner-transfer.md)). On 2026-10-06 a synthetic snapshot of
  500,000 records (63 MB, 12 MB compressed) took 41 minutes in 3,336 parts; the writer applied it in 529
  seconds and the compare found no differences ([P99 status](docs/status/P99.md#live-run)). A transfer that
  cannot end 10 minutes before the snapshot's apply-by time is refused before it starts, or stopped when it
  falls behind; nothing is written either way. A transfer of a minute or more prints its progress. The
  deployer's populate step, the switch's snapshot compare and full syncs use it unchanged, so the earlier
  limit of about 40,000 developers no longer applies to them.
- **P98 the installer deploys the Cosmos projection by default.** `Install-ClaudeGateway.ps1` offers
  the projection first, as recommended, for every size; `-Yes` chooses it, and named values above their
  capacity are refused, also under `-Yes` and `-Sku`, from `-DeveloperCount` or the tier groups' members
  ([ADR-0052](docs/adr/0052-cosmos-default-installer.md)). Choosing the projection deploys, populates and
  compares it, then switches the gateway; a failure leaves the current store serving and prints the
  rerun command. A re-run without `-EntitlementStore` migrates a named-value gateway, and the approval
  summary says so; a gateway already on the projection keeps it and its resolver access. Above
  named-value capacity, `-CompareBaseline Snapshot` compares the projection with a fresh Entra snapshot.
  The resolver is public by default on every tier, accepting only the gateway's managed identity.
  `-DeploySyncJob` adds the optional sync job; a failed job deployment is reported with its full rerun
  command. The approval summary lists the projection steps, so `-WhatIf` shows them. The SKU guidance
  cites the cache, units, network and zone facts, and states that zone redundancy and Premium v2 virtual
  network injection are chosen at creation, which the installer does not provision. README, Setup and
  the projection guide open with a quickstart. `scripts/Test-ClaudeLiveProjection.ps1` installs a
  disposable gateway, checks one developer's access through removal and re-adding, and deletes only what
  the run created. A re-run keeps the store that serves:
  - on a projection gateway it compares with a fresh snapshot;
  - it deploys the projection that `entitlement-projection-prefix` records;
  - it keeps the resolver's network access;
  - it refuses `-EntitlementStore named-value` with the rollback steps.

  The named-value sync checks every list before its first write, and the drift check no longer reports a
  one-member list as in sync. A snapshot too large to send through the runner before its apply-by time
  (about 40,000 developers) is refused before it starts; ROADMAP packet P99 plans a directory-scale
  transfer. Rerun commands quote every value that is not a plain token
  ([P98 status](docs/status/P98.md#p98-the-installer-deploys-the-cosmos-projection-by-default-2026-10-06)).
- **P97 Cosmos entitlement persists until a sync changes it, and syncs run on demand.** Projection
  records no longer expire 7,200 seconds after the scan that wrote them; a sync writes only the records
  that change ([ADR-0051](docs/adr/0051-persistent-sync-based-cosmos-entitlement.md)). The resolver
  refuses a record with an invalid generation or verification time, and a record that still carries a
  past `expiresAt` from before ADR-0051; the next full or targeted sync rewrites it.
  `scripts/Sync-ClaudeAccess.ps1 -User <upn-or-object-id>` publishes one developer's change through the
  in-VNet runner, using Microsoft Graph `checkMemberGroups`; without `-User` it syncs everyone, and
  `-Store auto` follows the gateway's `entitlement-source`. `sync/src/apply-projection.mjs` is the one
  Cosmos writer: every apply that writes takes a lease lock in the container, reads records and sync
  statuses inside it, requires `--account-resource-id`, and refuses a snapshot older than a sync that
  already covered it, or past its apply-by time when the first write is due; a full sync leaves alone the
  people a newer targeted sync changed, and `Sync-ClaudeAccess.ps1` prints how many. Every refusal names a
  remedy, which `Sync-ClaudeAccess.ps1` and the deployer show with the stage that refused. No Cosmos query
  filters on a path the container does not index: status reads query only the status partition. The
  container sets `defaultTtl: -1`, so records and the lock never expire and status records expire after
  seven days. The resolver refuses any document that carries a `type`, and `--tenant` must be a GUID,
  stored in lower case. `scripts/Sync-ClaudeProjection.ps1` only exports snapshots; its direct Cosmos writes,
  `-AllowEmpty` and `-KeepOrphans` are removed. The switch (`scripts/Deploy-ClaudeProjection.ps1
  -FlipAfterCleanCompare`) admits a gateway on a successful full sync within 24 hours for its Cosmos
  account and tenant, with no record the resolver would refuse; it needs no job and no receipt. The sync
  job is optional and manual unless `-CronExpression` is passed. The runner starts when it has stopped.
  The deployer creates the resolver's service principal, refuses a `-Location` other than an existing
  Cosmos account's, compares a new gateway with the snapshot it applied, and records
  `entitlement-projection-prefix`, also on a gateway that served from a projection before P97; the
  renewal deployer refuses until that named value names its projection, because the job's records carry no
  `expiresAt` and an older resolver refuses them. `docs/PROJECTION-WORKBOOK.md` gives the manual steps,
  quickstart first, and `tests/Test-DocMarkdown.ps1` refuses masked `Authorization` headers and fenced
  blocks inside table rows in every tracked markdown file
  ([P97 status](docs/status/P97.md#p97-cosmos-entitlement-persists-until-a-sync-changes-it-2026-10-05)).
- **P95 the projection switch runs end to end.** `Invoke-ClaudeProjectionSwitch`
  (`scripts/ClaudeProjectionSwitch.ps1`) takes the renewal receipt and checks every value in it
  before any call, requires the gateway's `entitlement-resolver-url` to be the resolver deployed with
  the projection, which reads the Cosmos account the job renews, runs the drift check with
  `scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift` and a read-only compare in the runner, runs
  admission, writes the entitlement named values to
  `onboarding/projection-switch-<apim>-<UTC time>-<8 hex digits>.json` and sets `entitlement-source`
  to `projection`, then prints the rollback. The deployer's `-FlipAfterCleanCompare`, the installer
  through it, and the guided Entitlement step use it; the deployer deploys, publishes and applies
  nothing in switch mode, and `-WhatIf` stops before the backup. The deployer's normal run points
  the gateway at the resolver. Admission reads the action group and requires an email receiver whose
  status is `Enabled`, and counts only status records the job wrote under its current settings,
  which must name the gateway, the compared tier groups, the receipt's identity and the Cosmos
  account and tenant admission reads. A restore does not switch to the projection.
  `docs/SECURE-PROJECTION.md` lists the owner-attended live run.
  [ADR-0050](docs/adr/0050-projection-switch-function.md).
- **P94 the projection renewal job deploys and renews.** `scripts/Deploy-ClaudeProjectionRenewal.ps1`
  deploys `infra/projection-registry.bicep` (registry, job identity, AcrPull), builds the image
  from the sync package, reads back its digest and deploys `infra/projection-renewal.bicep` pinned
  to it; `docs/AZ-COMMANDS.md` gives the same steps as Azure CLI commands. The projection network
  gains a `/27` renewal subnet. The job carries its client id, tier group ids and gateway id, reads
  `bu-registry` and `bu-parents` on every run, and prints a success or failure line that the
  alerts match. [ADR-0049](docs/adr/0049-projection-renewal-deployment.md).
- **P86 scheduled projection renewal.** A 30-minute Container Apps renewal job,
  tenant-admin Graph grant script, Cosmos status evidence, email-backed alerts
  and evidence-gated switch admission replace P84's unconditional projection
  refusal. Admission reads Cosmos through the in-VNet runner and separately
  verifies the pinned no-override job definition; rollback to named values
  remains available after refresh and comparison.
- **P86 gate correction.** The deployer, installer and guided flow tests now
  assert the accepted evidence-gated switch contract: missing or insufficient
  renewal evidence refuses before backup/write, while good Cosmos evidence and
  a pinned no-override job definition admit the projection switch.
- **P90 portal path for the Azure CLI setup guide, round 2.** `docs/AZ-COMMANDS.md`
  now has one `### Part N in the portal` subsection per part 1-12 instead of
  repeated per-step portal/change-later paragraphs. The overview table links to
  those subsections; each subsection contains matching portal steps, no-portal
  reasons for command-only work and one change-later paragraph. The guide embeds
  26 verified existing capture references, prunes P90 pending captures to
  `p90-company-custom-domains`, references the four existing P60 Desktop capture
  specs, and records tooling gaps for create wizards, tenant-wide Entra creation
  entry points and resource-group delete discovery. `Test-AzPortalGuide.ps1`
  now guards all parts, portal subsection shape, duplicate long prose, image
  provenance, pending-table/spec-file parity and overview portal anchors.
- **P90 portal path for the Azure CLI setup guide, rounds 3-4.** The portal
  guide now cross-checks az lead sentences and portal steps both ways, validates
  portal variables including braced `${VAR}` syntax, verifies Desktop redirect
  URI and audience parity, checks pending-capture tables in both directions and
  rejects editorial wording in portal/change-later text. The §2 custom-template
  route, §7 Desktop consent review and §9 Key Vault/custom-domain labels now
  cite the matching Microsoft Learn pages fetched for the round.
- **P90 portal path for the Azure CLI setup guide, round 5.** P90 now merges
  P89 round 10 while keeping all P89 bash fences byte-identical, adds portal
  parity for live gateway URL/SKU resolution, custom hostname receipts,
  model-refusal restore checks and receipt-gated resource-group teardown, and
  guards the new mappings plus imperative Change-later wording.
- **P90 portal path for the Azure CLI setup guide, round 6.** P90 now merges
  P89 rounds 11-12, preserves all P89 bash fences byte-identical, documents the
  immediate missing-`dig` refusal, the 600-second CNAME wait, the 2,700-second
  hostname wait, and the reused-APIM `appinsights` logger portal view, with
  guard mutations for each new assertion.
- **P90 portal path for the Azure CLI setup guide, round 7.** The council fixes
  split Part 2 named-value and diagnostic screenshots, mark Part 7 as only for
  external-IdP Desktop sign-in modes, remove internal P89 marker names from
  reader prose, convert §10 Change later into a table, and document how portal
  teardown identifies objects that have no CLI receipt.
- **P90 portal path for the Azure CLI setup guide, round 8.** P90 now merges
  P89 rounds 13-14, preserves all P89 bash fences byte-identical, verifies
  unmasked Bearer authorization headers, keeps the §7 external-IdP applicability
  sentence aligned with P89, and documents receipt-tag and live-object checks for
  portal teardown parity.
- **P89 Azure CLI setup guide.** `docs/AZ-COMMANDS.md` mirrors the installer and
  in-scope administration scripts with Cloud Shell bash commands, verification
  commands, expected results and source references; `Test-AzCommandsGuide.ps1`
  checks the documented `az` command paths and flags, named-value parity, Bicep
  parameters and relative links. Round 2 makes entitlement publishing fail
  closed on Graph errors, missing files, empty groups, incomplete pages and
  oversize APIM named values, with a Git Bash execution harness around the
  guide's bash blocks. Round 3 aligns projection deployment order, resolver
  caller ids, runner transfer, handover JSON shape and teardown receipts with
  the installer and projection scripts. Round 4 makes runner file transfer
  fail-closed with SHA-256 verification, requires teardown receipts for external
  deletes, records group/app creation receipts and documents the Microsoft Graph
  advanced-query eventual-consistency retry. Round 5 wraps refusal blocks in
  functions so Cloud Shell stays open, makes group/app discovery fail closed,
  tightens Graph 404 parsing, checks runner error text, and verifies teardown
  receipts before deleting anything. Round 6 refuses existing APIM instances
  without SystemAssigned managed identity, adds an optional PATCH-only identity
  enablement block, and prevents empty-assignee Foundry role checks or empty
  receipts after failed role creation. Round 7 makes Key Vault grants exact-scope
  and receipt-backed, preserves live APIM hostnames during company-address PATCH,
  and refuses empty-scope bypass/teardown reads. Round 8 adds first-deployment
  APIM absence and safe reuse blocks, warns against destructive reruns, and
  merges Desktop redirect URIs instead of replacing live lists.
- **P87 archives merged status sections.** `docs/STATUS.md` keeps the active packet, archive index,
  proof commands and next work; merged packet evidence now lives under `docs/status/` so the gate
  can read the active-packet line and all archived status files.
- **Final P85 follow-up integration.** P71's owned-process deadline probes and
  precise public-evidence section lookup are merged without production changes.
  The single full AUM run passes all 1,200 cases; refreshed file and whole-check
  weights retain four planned shards at 259, 259, 258 and 258 seconds.
  P85 remains first in STATUS, with both follow-up and earlier merge records kept.
- **P85 takes merged P80 without replacing its shard measurements.** The
  bounded merge keeps P85's reviewed helpers, approvals, capture provenance
  and four 281-second planned shards while retaining both ledger histories.
  Contract/publication/P85 checks pass; a new full AUM run, weight refresh
  and RunnerIntegrity are deferred until the pending deadline-test follow-up.
- **P85 includes P71's final main fixes.** Native message suppression and
  missing-main-tab handling now coexist with P80's guarded recovery and
  P85's management, Escape/quit and Cloud Shell behavior. The composed
  widget boundary is reviewed under ADR-0035. All 1,197 offline AUM cases
  pass in one full serial run; refreshed weights keep four planned shards
  at 281 s each. The earlier integration evidence remains in STATUS.
- **P85/P80 publication integration.** People, catalog and budget workflows,
  confirmed quit and the Cloud Shell launcher retain P71's closed publication
  contract. Reviewed lifecycle interfaces have current/expired-origin,
  native-log and scratch-mutation controls; protected output boundaries,
  existing rules and test budgets are unchanged. One integrated full-suite
  measurement refreshes all 75 file weights; four planned shards remain
  within 252 s each. Runtime publication/paging failures are recorded
  separately rather than described as a passing suite.
- **P85 packet gate 1: the AUM check runs in four shards.** The AUM pytest
  suite (871 tests, 860 s serially) exceeded Test-All's 600 s per-check
  timeout. Test-All now registers four checks, each running a longest-first
  share of the test files by committed per-file weights, and a fifth check
  proves every file runs in exactly one shard (`tests/README.md`). That check
  reads pytest's results with colour on and off, as the packet gate forces
  colour through `FORCE_COLOR=0`.
- **P85 council round 2: installer alias isolation.** Pip/uv processes use
  fresh explicit environments rather than relying on shell-name enumeration.
  Pip also uses isolated mode, null configuration and a confined cache.
  Real offline pip and child-environment tests cover malformed aliases while
  the final AUM process retains its Azure CLI session context.
- **P85 council round 2: sign-out completion.** A successful sign-out exits
  from application-owned completion handling after registry release, even
  when its modal worker was cancelled. Other mutations still finish first,
  failures stay visible, and completed sign-out does not retain saving text.
- **P85 council round 1: quit deferral.** Application-owned mutation tasks
  retain backend and receipt completion even when a modal worker is cancelled.
  All application exit routes defer during a save; the quit dialog explains
  the wait and disables confirmation. Results remain available after completion,
  without an automatic deferred exit. Read-only work remains interruptible.
- **P85 council round 1: installer destinations.** The Cloud Shell bootstrap
  clears inherited pip/uv/XDG settings, including `PIP_LOG`, and pins Python's
  user base and all controlled directories under HOME. A real-pip offline
  regression and per-variable write probes replace the earlier incomplete
  confinement evidence.
- **P85 council round 1: removal-plan binding.** The terminal passes its
  reviewed plan to the existing membership engine. A difference against the
  exact resolved write snapshot is refused before Graph or publication
  writes, including catalog changes after the form's apply-time re-preview.
- **P85 owner additions: Escape and quit safety.** Rapid Escape remains
  navigation/cancellation through the tested main/modal/slow/error paths.
  Expected refresh transport failures no longer become fatal worker errors.
  One `q` opens confirmation; a second `q` or Enter quits and Escape stays.
  The palette includes quit, back/clear and page navigation. CAE location
  challenges explain IP variation, VPN/IPv6 consistency and administrator
  review without echoing transport details or retrying writes.
- **P85 owner additions: Cloud Shell bootstrap.** A HOME-local launcher
  creates/reuses a managed Python 3.12 environment and installs the checked-out
  AUM package, retaining Cloud Shell's existing Azure CLI sign-in. Dry-run,
  canonical destination checks and offline fake-command tests cover setup,
  reuse and failures. The guide records networking, idle and persistence
  limits with dated sources; live Cloud Shell verification remains owner-only.
- **AUM terminal management (P85, builder candidate; lead council/gate pending).** People exposes
  Remove person from team beside Add person to team, with `h` and a matching
  palette entry. Its preview names the resolved person, all tier/catalog group
  removals and the `allow-standard`/`allow-premium` publication targets. The
  existing engine checks owner authority and typed email/UPN confirmation;
  AUM service membership remains unavailable. Done returns from both membership
  forms to a refreshed People view. Observed usage is not a membership roster
  and can remain after access removal.
  Complete offline pilots cover unit/team creation and removal, unit/team/person
  token budgets, and Direct/service USD saves with actual adapter-write
  assertions. Native synchronous receipts no longer enter Turnstile apply
  polling. Direct person budgets retain their gateway meaning, USD results
  state that reconciliation is pending, and the USD palette entry follows its
  own selected-scope capability rather than catalog-write permission.
  The install-first guide has separate task how-tos, existing destructive-scope
  rules and estimated waits. Required Example snapshots are regenerated;
  historical live captures remain unchanged. Twelve exact-test-identity
  mutation probes detect removal and related receipt/discovery regressions.
  Architecture boundaries are unchanged. P71's closed-presentation integration
  requirements are recorded in STATUS without merging that branch.
- **P80 final-main integration and AUM test sharding.** P71's final exact-type message
  controls and absent-main-tab handling retain P80's protected actions and recovery.
  Four duration-weighted AUM checks and their coverage proof are ported from P85
  `c9ae1c8` / `729a249`, using P80's own serial JUnit timings rather than P85's weights;
  the 600 s check timeout and every existing test remain unchanged.
  The main `3b7c192` integration passes all 928 serial AUM cases in 518.76 s.
  Its 65 files plan at 141/140/140/140 s across four complete shards; coverage,
  runner integrity, mutation ownership, documentation, encoding and architecture
  checks pass. The combined publication fingerprint review and source-preserving
  removal proofs are recorded in [P80 STATUS](docs/status/P80.md#final-main-integration-and-reviewed-aum-test-shards-2026-09-30).

- **P80/P71 publication integration.** Existing AUM actions retain guarded notifications,
  text-only report/profile paths, origin-checked local saves and recovery scrolling;
  profile conflicts keep the current connection form instead of clearing its principal state.

- **AUM action discovery (P80, owner-approved for integration after P71).** People and Budgets show
  Add person to team, Set budget, Set USD budget and Chargeback report, with
  matching Help and keyboard hints. The selected connection appears as
  `via Direct`, `via AUM service` or `via Turnstile`. Add person loads the
  catalog without a Budgets visit, keeps directory/catalog publication guards
  and shows read errors. The existing authority rules and preview-first
  writers remain; Turnstile has no USD writer.
  Settings has one connection form with preview, exact-byte timestamped
  backups, atomic local replacement and rollback after failed identity
  verification. It retains the selected profile path. The configure command
  honors explicit HTTP URL/scope, asks before attended replacement and keeps
  the unattended `--force` requirement.
  Council round 1 corrections preserve the reviewed candidate and revision
  through commit, serialize profile writers and protect post-replacement
  failures. Failed rollback keeps the old live connection and displays the
  backup path and recovery steps instead of claiming restoration.
  Settings now has a wrapping, guarded connection label independent of table
  width caches. AUM-service membership is explicitly unavailable in the
  controls, shortcut, command palette and guide; no membership writer is added.
  Council round 2 corrections delay UI adoption until saved-revision validation
  finishes. A post-whoami file failure retains the old identity, cached state
  and connection form; its complete recovery text is keyboard-scrollable at
  80x24 instead of being clipped in the application status.
  One Chargeback report action writes the complete month CSV to the local
  reports folder with an absolute path and non-overwrite naming. The installed
  reconciled-report action retains its existing permissions. CLI report output
  supports JSON path metadata and a no-file `--what-if` preview.
  The AUM guide starts with installation, connection and first run, then tasks,
  reference and troubleshooting. Historical live evidence remains dated;
  regenerated Example screens have separate source/output hashes. Related
  FinOps guides link to the shared setup. The architecture diagram records
  local backup/report flows without adding an Azure component or authority.
  Initial builder evidence was 614 offline AUM tests and 49 caught reversion
  probes. Round-1 corrections passed all 632 AUM tests, 19 additional negative
  probes and ten consecutive Settings visibility runs. Round-2 council, the
  full packet gate and post-deployment owner review remained pending at that
  handoff. Round-2 corrections passed all 635 AUM cases and seven additional
  negative probes, including end-to-end persistent-lock recovery at 80x24.
  Round-3 council passed on all five seats, and the packet gate passed at
  `5e31cd3`. The owner approved integration after P71 on 2026-09-29.
  Main `30cdfd0` is integrated into the P80 branch without rebasing; its
  requested documentation, architecture, encoding and 635-test AUM checks pass.
  The lead owns final P71 integration and the merge to main.
  [AUM](docs/AUM.md), [ADR-0038](docs/adr/0038-aum-actions-and-connection.md).
- **AUM latency and readiness (P71).** Direct shares one named-value snapshot per
  read cycle, reuses resource tokens until near expiry and overlaps independent
  telemetry reads. The terminal displays arriving panels with named, estimated
  waits and elapsed time. Turnstile readiness names an Azure-verified stopped
  PostgreSQL server and its manual paid start command (exit 9); no resource is
  started automatically. Windows Azure CLI deadlines include wrapper-child
  cleanup. Existing scope checks, preview/write rules and settled terminal
  snapshots remain. [AUM](docs/AUM.md#read-latency-and-progress),
  [ADR-0035](docs/adr/0035-aum-bounded-readiness-and-progressive-reads.md).
  Council fixes bind credential reuse to verified principal/session generations,
  contain wrappers before execution, share one monotonic credential deadline,
  and surface fatal query errors while identity/capabilities are pending.
  Read cycles pin that generation immutably and reject obsolete snapshots and
  complete multi-source aggregates after a verified principal change.
  HTTP aggregate cycles and progressive publication now retain the same
  generation through cache, screen and command/file output boundaries.
  Cached dialogs/forms and request actions retain the item's originating guard;
  connection closure invalidates deferred references to the old source.
  Round-five publication uses one guarded execution boundary with an AST
  contract; verified principal transitions clear all presentation/assistant
  state before input, including highlighted status and outgoing history.
  Round-six widget, terminal/file, clipboard and assistant-transport sinks
  validate active origins at execution, including indirect calls. Explicit
  deferral rechecks the source on execution; the structural detector also
  covers lambda/def, dynamic attributes and partials. Sink decorators reject
  coroutine and generator bodies rather than checking only their creation.
  Round-seven `content` writes retain their source, and the structural contract
  rejects unchecked descriptor/raw-state/dynamic-code paths, additional
  scheduler spellings and partial methods. Refused timer, screen and event-loop
  callbacks retain responsive input and report only the safe underlying error,
  without rendering callback arguments or traceback locals.
  Round-eight attachment validates retained widget origins before DOM
  insertion, including copied and composed subtrees; protected instances
  refuse class replacement. The structural contract now uses an explicit
  import/member allowlist and checked metaprogramming exceptions instead of
  trusting unrecognized spellings. Console, file and framework capabilities
  remain inside the protected boundary modules.
  Round-nine notifications retain their origin through queued delivery and
  visible/cached toast rendering; principal changes clear old notifications.
  Presentation attribute loads and literal reflection are now default-deny,
  with checked internal exceptions and restricted superclass forwarding.
  Round-ten native DOM receivers use an explicit reviewed class set; unsupported
  content classes are refused before attachment. Native writes and cached
  rendering retain their source. Application titles stay static, raw exit
  messages are refused, and queued message/notification representations omit
  backend text before Textual logging. The seven scheduler cases enable visible
  notifications. [Corrections and evidence](docs/status/P71.md#council-round-10-corrections),
  [approval recipe](docs/adr/0035-aum-bounded-readiness-and-progressive-reads.md#approval-recipe-for-attributes-and-builtins).
  Diagnostic sealing now preserves Textual's exact-type message suppression
  and disabled-message controls, preventing duplicate tab/selector refreshes
  from cancelling current reads without weakening provenance or payload redaction.
  Retained tab activations are ignored while main content is absent during
  remount or shutdown; current activations and publication checks remain unchanged.
- **P84 projection deployment preflight and deferred switching.** `-PreflightOnly` and normal
  deployment share read-only prerequisite checks before Azure writes. PowerShell 7 is required
  for deployment/projection sync. Graph errors no longer count as absent groups; runner failures
  show sanitized counts/hashed samples from at most 40 lines and 4,096 characters; failed app
  creation cannot update an empty id. Council round 1 rejected ARM-only admission: a successful
  scheduled dry-run can renew nothing. Deployment, installer and guided Entitlement now refuse
  every projection switch until P86. [ADR-0040](docs/adr/0040-projection-preflight-and-switch.md)
  proposes destination-bound Cosmos renewal evidence for that later packet.
  Confirmed-absent premium passes, unproven app rights produce WARN, supplied app ids skip
  policy reads, narrow reports use stacked records, and declined prerequisites abort.
  Real-caller and locale tests cover en-GB/de-DE and supported PowerShell hosts. Earlier proof
  receipts remain historical, not acceptance of the rejected design. Revised proof at `eca8b55`:
  197 preflight assertions, 83 council assertions and 95/95 valid-syntax, count-preserving
  mutations ([P84 status](docs/status/P84.md)).

- **P78 parallel hosted checks.** Opt-in deterministic Test-All shards retain
  isolated processes, exclusive checks and deadlines, with commit/tree-bound receipts and an
  ordered, fail-closed coverage merge. A SHA-pinned, read-only GitHub workflow installs both AUM
  Python environments and offline prerequisites. The remote helper validates exact-source jobs
  and artifacts rather than a workflow badge. The wizard and preflight retain native Windows
  boundaries through isolated fixtures instead of an operator's Azure session.
  [Test execution](tests/README.md), [P78 evidence](docs/status/P78.md),
  [draft ADR-0039](docs/adr/0039-test-suite-hosted-runners.md).
  The charter, product scripts and deployed resources are unchanged.
  The first hosted attempt exposed missing Chromium installation and an error-pattern assertion
  that accepted the wrong exception; both have targeted regression coverage
  (`tests/Test-RemoteTestAll.ps1`, `tests/Test-TestAllSharding.ps1`).
  After P79 integration, [run 36457223984](https://github.com/naveenneog/claude-code-foundry-gateway/actions/runs/36457223984)
  on exact `f829812` passed 95/95 registrations with 0 SKIP in 638 s queue-to-merge, including
  both Python environments and 95 count-preserving infrastructure mutations (74 Core, 12 Runner,
  nine Wizard). The timing table records its 95 passing durations. Evidence was accessed
  2026-09-28. Council, gate and the proposed charter adoption remain with the lead and owner.

- **P69 council corrections.** Inherited addresses are resolved before Foundation approval;
  proposed decisions no longer overwrite applied state or history; failed replacements have a
  narrowly scoped recovery review; Azure transitions reconcile metadata and generated settings.
  Checks enforce remaining deadlines and clean private worker files on cancellation. PFX uploads
  use the validated byte buffer. The positive delegated-domain TLS proof is explicitly deferred
  to P74 by the lead, not marked complete.
  Round 2 adds explicit cross-decision results and removals, applied-only Status/Guide/discovery,
  installer recovery receipts and legacy subscription resolution. DesktopSignIn and Models retain
  their profile decisions, and a failed Models profile generation does not publish proposed state.
- **Company address in the installer and guided flow (P69).** The company choice now plans
  and applies public DNS, a supplied PFX or Key Vault certificate, and a preserved APIM Proxy
  hostname, with component prices before approval. `-Change address` uses the same fingerprinted
  plan. A trusted, pinned HTTPS gateway response precedes publication to developer settings.
  The isolated Basic v2 proof established authoritative DNS but could not bind its undelegated
  `.test` name: Azure requires public CNAME ownership. No free managed certificate is available
  on v2; the positive company TLS proof remains blocked without a delegated domain
  ([Setup](docs/SETUP.md#company-address), [ADR-0033](docs/adr/0033-company-address.md)).
- **Reviewed model lifecycle (P70).** `-Action Change -Change models` and
  `scripts/Sync-ClaudeModels.ps1` discover the selected Foundry account, show deployment
  model/version/SKU/capacity and price status, accept per-deployment tier choices, snapshot
  before writes, update only the model named values, and regenerate the record and both
  tiers' MDM/workstation handovers. Stale plans, Turnstile-owned tiers, malformed discovery
  and last-entry allow-all removal are refused. Dated unambiguous price mappings preserve
  history; Opus 5.5 stays explicitly unpriced because the current financial readers do not
  represent its published cache-read multiplier. The installer gains `-StandardModels` and
  `-PremiumModels` for an unattended initial subset. [Model guide](docs/MODELS.md),
  [ADR-0034](docs/adr/0034-model-lifecycle.md).
- **P70 council fixes.** Model fingerprints now bind renderer helpers as well as the
  generator. Raw deployment identities and empty installer selections fail closed;
  initial tier restrictions reach profiles. Bash removes retired aliases consistently
  with Windows. Standalone history includes the prior decision and principal, empty
  named-value writes use a subscription-bound token, and nested generated onboarding
  records/profiles/snapshots remain git-ignored.
- **Permutation tests of the guided flow and the installer (P72).** `tests/Test-FlowPermutations.ps1`
  runs the orchestrator over Setup, Change foundation, Guide and Status × six record states ×
  attended, `-PlanOnly` and unattended apply (76 runs, some on Windows PowerShell 5.1), a recorded
  foundation through an unattended Change, and Foundation's installer arguments over 432
  combinations. `tests/Test-InstallerPermutations.ps1` runs the installer under `-WhatIf -Yes` over
  every combination of tier × entitlement store × developer sign-in × Desktop sign-in (96 cases), six
  refusals and a reused gateway, on both shells, offline in about 40 s; `-Live` runs 16 cases that cover every pair of levels
  read-only against the signed-in subscription. [Guided flow](docs/GUIDED-FLOW.md#what-the-tests-hold).
- Guided-flow FinOps modules for tool selection, USD/token budgets, monitoring workbooks
  and chargeback reports, including a scheduled USD reconciler job definition for
  deployments without the AUM service.
- `Register-ClaudeUsdReconciler.ps1` and `infra/usd-reconciler-job.bicep` deploy
  that no-AUM-service USD reconciler as a five-minute Container Apps scheduled job
  with a pinned image/commit and least-privilege managed identity.
- **Guided lifecycle update and change modules (P66).** `scripts/Update-ClaudeGateway.ps1`
  plans and applies ordered migrations for older decision records, current policy hash drift,
  policy-referenced named values and optional job commit pins, with a named-value snapshot before
  any write and `release`/`history` recorded afterward. New flow step modules cover API Management
  tier changes, named values ↔ projection entitlement moves, enterprise network review execution
  and Desktop sign-in changes. `docs/UPDATE-AND-CHANGE.md` gives the step-by-step and manual
  equivalents.
- **Guided flow core (P66).** `Start-ClaudeGateway.ps1` now orchestrates setup,
  change, guide and status from one decision record and one reviewed plan
  fingerprint, with absent parallel-branch modules skipped rather than failed.
  `scripts/flow/Discovery.ps1`, `Foundation.ps1`, `DeviceProfiles.ps1`,
  `Verify.ps1` and `Guide.ps1` provide the owned step modules, and
  `docs/GUIDED-FLOW.md` documents the product path and manual equivalents.
- **Guided diagnostics (P66).** `scripts/Debug-ClaudeSetup.ps1` and
  `scripts/Debug-ClaudeWorkstation.ps1` run read-only administrator and developer
  checks with PASS/WARN/FAIL/SKIP evidence, exact fixes and redacted support
  bundles; `scripts/debug-claude-workstation.sh` covers macOS/Linux and
  `scripts/flow/Diagnose.ps1` exposes the ADR-0030 guided-flow step.
- **One-command AUM client install.** `scripts/Install-ClaudeAum.ps1` reads the Python version the
  package requires, lists the interpreters that meet it and asks which one, creates or reuses
  `.venv-finops`, installs `cli/finops`, checks `aum --version` and the Azure CLI sign-in, and
  runs `aum configure`. `-WhatIf` writes nothing. `tests/Test-InstallAum.ps1` covers the choice
  rules and `-WhatIf` on every run, and a real install with `AUM_INSTALL_E2E=1`.
- **AUM manages gateway USD budgets (P62).** `aum usd list|set|clear|status|reconcile`
  and `aum usd price-book show|set` manage the P59 dollar-budget contract with
  decimal strings, preview-first writes, typed confirmation for clears and the
  **Saved; awaiting reconciliation** state. Direct reuses
  `ClaudeUsdBudgets.ps1`, `Sync-ClaudeUsdBudgets.ps1` and the shared
  `UsdBudgets` authority guard; the AUM service backend uses advertised
  capability flags and `If-Match`; Turnstile USD writes are hidden/refused until
  it exposes a real USD source. Measured live on 2026-09-26 on an isolated Basic v2
  gateway through AUM: a $0.00005 unit budget, $0.000068 of priced spend after
  reconciliation, the next request refused with 403 `usd_budget_exceeded` 73.8 s after
  the crossing request, and 200 again after `aum usd set` raised it to $0.001.
  `docs/AUM.md`, `docs/BUDGETS.md`, [ADR-0018](docs/adr/0018-terminal-finops.md).
- **The Cosmos entitlement store offered by SKU, including Basic v2 (P61).** The installer asks
  for `named-value` or `projection`, states the named-value ceiling (about 93 developers in
  `bu-members`) at the operator's developer count, and chooses the resolver's inbound path by SKU:
  private for Standard v2 and Premium v2, public with Microsoft Entra authentication pinned to the
  gateway's managed identity for Basic v2, which has no outbound VNet integration; Cosmos stays
  private either way. `scripts/Deploy-ClaudeProjection.ps1` deploys the private Cosmos account,
  its network and the resolver, populates from Entra, compares against the named-value decisions
  and flips `entitlement-source` only after a clean comparison;
  `Measure-ClaudeProjectionCost.ps1 -P61Scenarios` prints the 100- and 500-developer cost rows.
  Measured live on 2026-09-26 on an isolated Basic v2 gateway: an unauthenticated call to the
  public resolver returned 401, a real count-tokens request through the gateway returned 200 after
  the flip, and 500 synthetic records were written and counted. [ADR-0028](docs/adr/0028-basic-v2-projection-resolver.md).
- **MDM deployment guide (P65).** `docs/MDM.md` now gives Intune, Jamf and
  Group Policy fleet rollout steps for Claude Code, the VS Code extension and
  Claude Desktop, with live workstation validation notes and Intune capture
  steps for a tenant with the required role.
- **Desktop macOS MDM profile (P65 follow-up).** `New-ClaudeCodePolicy.ps1`
  now emits `claude-desktop.mobileconfig` for
  `com.anthropic.claudefordesktop`, including the recorded P60 sign-in keys.
- **Claude Desktop sign-in chosen by the administrator (P60).** `Install-ClaudeGateway.ps1`
  records `desktopSignIn` in `claude-gateway.json`: the unchanged helper-script default,
  or Desktop external-idp sign-in through an Entra public-client app in browser or broker
  flow. `scripts/ClaudeDesktopSignIn.ps1` validates the record and renders the exact
  Desktop keys for both workstation setup scripts and the MDM payload generator. The
  gateway accepts a Desktop audience only through the new `external-idp-extra-audience` named
  value; empty keeps the previous Azure CLI/helper audiences. `New-ClaudeDesktopEntraApp.ps1`
  creates or discovers the public-client registration and redirect URIs without granting
  tenant-wide consent. [ADR-0027](docs/adr/0027-claude-desktop-sign-in-choice.md).
  Measured live on 2026-09-26 on an isolated gateway: the helper token returned 200 and a
  wrong audience 401; a Desktop-audience token stopped at `AADSTS65001 consent_required`,
  because this tenant grants no consent (**U23**).
- **AUM adds and removes developers by email (P64).** `aum developer find|add|remove` searches the
  Entra directory with the signed-in administrator's delegated Graph token,
  resolves exact email/UPN/object-id targets including guests, previews tier and
  unit/team group changes, writes membership once, verifies propagation and
  publishes the gateway. `Set-ClaudeDeveloper.ps1` now discovers recorded tier
  group names instead of silently defaulting to fixed strings.
  Removal allows an empty tier list only for a tier it is proven to empty, so a failed read
  of another tier is still refused. Measured live on 2026-09-26 on an isolated gateway: a
  request returned 200 after `aum developer add` and 403 after `aum developer remove`.
  [ADR-0029](docs/adr/0029-aum-developer-membership.md).
- **Dollar budgets enforced from priced token categories (P59).** A unit, team or person budget
  can be set in dollars with a pinned price book; a reconciler prices observed input, output,
  cache-read and both cache-write tokens with Decimal, refuses unpriced models rather than
  counting them as $0, and publishes expiring gateway stops in the strict, allowance and notify
  modes. The refusal is a distinct 403 `usd_budget_exceeded`; enforced state older than 15
  minutes gives 503 `usd_budget_state_stale`. It runs on demand (`Sync-ClaudeUsdBudgets.ps1`) or
  on the AUM service's five-minute timer, which also serves the dollar routes. Measured live on
  2026-09-25: $0.0364984 of priced spend crossed a $0.02 budget and the next request was refused
  175.9 s after the crossing one; a raise to $0.50 restored 200. Enforcement trails ingestion;
  it is not a hard invoice cap. [ADR-0026](docs/adr/0026-usd-budget-reconciliation.md).

- **AUM (Azure Usage Management), the terminal FinOps client renamed from `claude-finops`.**
  `aum` (the old command still works) adds an executive overview, budgets by unit, team and
  person, gateway governance, usage breakdown and trends, a request trace, anomalies, reports
  through P50's generator, and Entra group find, create, member and delete, each previewed before
  any write. It runs against Turnstile, the gateway directly, the AUM service or example data, so
  it does not depend on Turnstile. Measured live on 2026-09-25 through Direct and Turnstile:
  owned test groups, budgets and all three modes enforced on real requests (strict 403, allowance
  and notify 200 with a notice), then 13 named values restored byte for byte. Clients for server
  features that do not exist yet stay hidden until a server advertises them. `docs/AUM.md`.
- **Governance authored in Turnstile, applied to the gateway on save.** With
  `Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Turnstile`, business units, teams, their Entra
  groups, budgets and tier limits are edited on Turnstile's pages, and each save starts the
  gateway's apply job, a manually triggered Container Apps job beside the hourly one. Measured: a
  tier limit saved on the page was read on the gateway 112 s later, and a budget saved in Turnstile
  refused the next request 123 s after the save. Turnstile's API holds Container Apps Jobs Operator
  on that one job; the job's identity holds a custom role that reads and writes the gateway's named
  values and nothing else. `scripts/ClaudeTurnstileApply.ps1` applies no group it cannot confirm,
  always applies tier limits, never rewrites membership from groups it could not read, reads each
  write back, and refuses a catalog with no business unit. New groups and membership refresh need
  `GroupMember.Read.All` from a tenant administrator, `scripts/Grant-ClaudeGovernanceGraphAccess.ps1`
  (**U17**). [ADR-0015](docs/adr/0015-governance-authored-in-turnstile.md) amends ADR-0014.
- **Managers scoped to their units and teams.** In Turnstile (fork `c0c345a`), a person holding
  only `Turnstile.Manager` sees and manages the units and teams whose manager group is in their
  own token: usage, budgets, people and requests, filtered; a unit manager sets its teams'
  budgets, any manager sets person budgets in scope; every other page and API is refused by
  default. Owners record each unit's and team's manager group and budget mode on the Gateway
  governance page. Migration 012 asks existing Entra members to sign in once again.
- **Viewers, managers, and a sign-in that needs no consent.** Turnstile's Entra application has
  `Turnstile.Viewer` and `Turnstile.Manager` beside `Turnstile.Admin`, created by
  `New-ClaudeTurnstileEntraApp.ps1` as the app's owner, and its tokens carry only the groups
  assigned to it. Viewers and managers sign in read-only; developers never do.
  `scripts/Open-ClaudeTurnstile.ps1` signs a person in through the Azure CLI, which is
  pre-authorized on Turnstile's API: the token is exchanged for a code that works once, within a
  minute. For tenants whose web sign-in has no consent yet (**U19**).
  [ADR-0016](docs/adr/0016-delegated-management.md).
- **A manager sees only their unit, proven live.** With admin access removed for a few minutes, a
  fresh token carried exactly `Turnstile.Manager`; Turnstile scoped the session to one unit and
  its three teams and refused the admin pages, then every membership and assignment was restored
  and verified. On Windows the account broker kept serving the old token; MSAL's
  `set_access_token_to_renew`, behind a helper that fails closed, renews it without deleting any
  cache or adding any grant.
- **Every FinOps tool in one guide.** `docs/FINOPS-TOOLS.md` compares the saved queries and
  workbooks, the scripts, Terminal FinOps, the AUM service, Turnstile, chargeback reports and
  Grafana. It covers who signs in to what and with which method, six end-to-end flows with their
  commands, and a bill of materials from live list prices, with the command that recalculates
  each line.
- **Where a Premium v2 injected gateway's private IP is, measured.** ARM returns it in
  `properties.privateIPAddresses` only at api-versions `2024-05-01`, `2023-09-01-preview` and
  `2023-05-01-preview`, and Resource Graph shows it; `az apim show` (`2022-08-01`) and every
  newer preview return `null`. Azure publishes no DNS for the gateway name.
  `docs/NETWORK-ENTERPRISE.md` gives the command, the portal path (JSON View at `2024-05-01`) and
  the per-host private DNS zone that made it answer by name from a peered VNet.
- **An enterprise network edge, chosen and priced by the administrator.**
  `scripts/New-ClaudeNetworkEdge.ps1` puts a regional Application Gateway WAF_v2 in front of the
  gateway as its only ingress, with internal, internet or hybrid listeners, and Foundry, Key Vault
  and a verifier behind private endpoints. It discovers the options, prices each from the retail
  price list with its implications, and writes nothing until one frozen review, which names the
  identities that may lose access, is confirmed; removal has its own review. Measured live:
  complete SSE for code prompts in Prevention mode with 71 scoped WAF exclusions, Claude Code
  through the edge with TLS verified, a 600-second backend timeout, and forged client-address
  headers kept out of the ledger. `docs/NETWORK-ENTERPRISE.md`,
  [ADR-0022](docs/adr/0022-enterprise-network-edge.md).
- **Architecture that cannot drift from the code.** Ten diagrams generated from text sources under
  `docs/architecture/` by `node guide/render-architecture.mjs`, a rewritten `docs/ARCHITECTURE.md`,
  and an `AGENTS.md` rule that every feature packet updates its diagram. `tests/Test-Architecture.ps1`
  fails when a source changes without re-rendering, a label names something that no longer
  exists, or an Azure resource type in `infra/*.bicep` appears in no diagram.
- **Chargeback reports, generated and emailed per business unit.** `New-ClaudeChargebackReport.ps1
  -Month` writes each unit's CSV of its people and an HTML summary, reconciled to the month through
  an explicit Unassigned line, or fails. `Set-ClaudeChargebackRecipients.ps1` sets each unit's and
  the admin team's recipients, limited to allowed domains. `Register-ClaudeChargebackSchedule.ps1`
  deploys a private scheduled job that archives every run and emails each unit only its own report
  through Azure Communication Services. Both months' reports reached the owner's inbox live on
  2026-09-24. About $29.70 a month standing, list price. `docs/CHARGEBACK-REPORTS.md`,
  [ADR-0020](docs/adr/0020-chargeback-reports.md).
- **The AUM service: viewers, managers and budget requests without Turnstile.** An optional Azure
  Functions API with its own Entra app roles and consent-free Azure CLI tokens. Managers are scoped
  by their manager groups; budgets are written to the gateway's named values by its managed
  identity with conditional revisions, in exactly the PowerShell serializers' format; budget
  requests, decisions and boosts with an expiry are audited. It refuses to write to a gateway
  another authority governs. `Deploy-ClaudeAumService.ps1` and `Select-ClaudeFinOpsTooling.ps1`
  show each choice's cost and implications first. `docs/AUM-SERVICE.md`,
  [ADR-0023](docs/adr/0023-aum-service.md).
- **Turnstile's pictures are live, and say so.** All 22 were recaptured from the reference
  deployment through the consent-free sign-in and 4 added, each with a dated, redacted provenance
  record and a pixel hash the screenshot check enforces. A tier change and a budget mode made in the
  UI were read on the gateway, then restored. Capture scripts discover their targets instead of
  defaulting to live resource names, and the deployment-values check now scans `.mjs` files.
- **Budget modes per business unit and team: strict, allowance or notify.** Strict is the default
  and unchanged. Allowance admits up to a percentage (1 to 100) above the budget; notify skips only
  that scope's limiter, while the parent, organization and tier limits still apply.
  `Set-ClaudeBusinessUnit.ps1 -Mode -AllowancePercent` sets it, and so does the Gateway governance
  page in Turnstile; the new named value `bu-modes` holds only the exceptions and survives a
  redeploy. Notices are advisory, because the remaining quota API Management reports is an
  estimate: `estimated-over-budget` for allowance, `usage-reported` for notify. Each budget trace
  joins the ledger on `BudgetRequestId`. Live-tested on the reference gateway and restored exactly.
  An apply run now rechecks Turnstile's revisions immediately before writing and reconciles again
  from newer state, so an earlier save can no longer overwrite a later one in the common case; the
  single writer in P48 closes it. [ADR-0019](docs/adr/0019-budget-enforcement-modes.md).
- **A terminal FinOps console, `claude-finops`.** Nine views in the terminal and the same actions as
  commands for scripts, over Turnstile's API, the gateway directly, or example data. Budget
  changes are previewed, rechecked against the server, never retried, and removal needs typed
  confirmation; the full chargeback export covers every unit and team, and CSV cells that start
  like a formula are escaped. Managers see only their scope and read only. Sign-in uses the Azure
  CLI and no token is stored. Accessible themes, no motion, and plain linear output.
  `docs/CLI-FINOPS.md`, [ADR-0018](docs/adr/0018-terminal-finops.md) (**U20**).
- **A projection record authorizes for two hours at most, and a burst of misses gets an answer.**
  Each complete directory observation stamps every member it keeps with a reconciliation generation
  and an absolute expiry, two hours by default and at most. The resolver and the gateway's cache
  both refuse an expired record with a 503 that names the expired projection, so a stopped writer
  no longer leaves access standing. Reconcile an existing projection once before deploying the new
  resolver and policy. Both writers read every Cosmos continuation page before publishing. Before
  the resolver, the gateway admits at most 100 concurrent misses and 200 a second and answers the
  rest with a retryable 429; the resolver coalesces concurrent reads of one identity within a
  process and runs two always-ready instances. Enterprise Cosmos defaults to private-only. Measured
  on the Premium v2 test gateway: no 503 in the first 20 misses after deployment or after 16 minutes
  idle, nor in bursts of 50 and 100. A throwaway container loaded 500,000 records at 954 a second,
  and 500 point reads cost 1 RU each, p99 51 ms (**U14**; **U18**, narrowed).
  [ADR-0017](docs/adr/0017-projection-freshness-and-admission.md).
- **Scale, measured at 500,000 identities.** On a throwaway Premium v2 instance with a mock
  backend, API Management's `llm-token-limit` counters accepted and charged 500,000 identities at
  about 1,600 requests a second on one unit, and no allowance was exact: one identity was served
  540 tokens against a 300-token hourly quota, and 1,000 exhausted identities were admitted again
  within the hour (**U9**, narrowed). On the Premium v2 test gateway, the projection's resolver
  returned 503 to 2 of 3 first requests after idle with no always-ready instance, and to 4 of the
  first burst of 20 concurrent misses with one; nothing coalesces concurrent misses (**U18**).
  `docs/SCALE.md`.
- **Nothing about one deployment is written into the scripts.** Twenty-seven scripts and tests
  defaulted `-ResourceGroup` to the reference deployment's resource group. They now resolve it
  through `scripts/Get-ClaudeGatewayTarget.ps1`: `CLAUDE_RG`, else the resource group the installer
  recorded in `onboarding/claude-gateway.json`, else nothing, with a warning naming what to pass.
  Help examples, a live test's workspace name, and three tenant ids in `docs/FOUNDRY-DIRECT.md`
  and the resolver's test fixture are placeholders or discovered. `tests/Test-NoDeploymentValues.ps1`
  keeps it that way, and fails when a literal is put back.

- **The API Management AI Gateway tier (preview), assessed beside this gateway.**
  `docs/AI-GATEWAY-TIER.md`. Its dollar budgets count per API key, not per person; enforcement for
  Entra principals is announced as coming. Deployed in 133 s as `Microsoft.ApiManagement/service`
  with the `AIGateway` SKU; ARM accepted a Foundry provider, Claude and OpenAI models, and token
  and cost limits, but the runtime served no model route (U16), so Claude clients and the limits'
  enforcement are untested. The Turnstile fork's four branches are offered upstream as draft pull
  requests xuleihive/turnstile#25 to #28.

- **Turnstile as the FinOps console, admin-only, with the gateway still the one enforcer.**
  `docs/TURNSTILE.md` is the walkthrough; every step was run live on 2026-09-23.
  - `New-ClaudeTurnstileEntraApp.ps1` creates the single-tenant application, the `Turnstile.Admin`
    role, the `Turnstile.Manage` scope pre-authorized for the Azure CLI, assignment required and the
    admin group. Removing the group's assignment made Entra refuse a token (`AADSTS50105`).
  - `Connect-ClaudeTurnstile.ps1` discovers a Turnstile deployment and stores it in one named
    value, `turnstile-integration`; `Sync-ClaudeTurnstileGovernance.ps1` maps units to
    organizations, teams to departments and budgets both ways, writing nothing back without
    `-Apply`; `Export-ClaudeTurnstileUsage.ps1` sends requests and hourly cache reads through the
    Event Hubs REST API with an Entra token.
  - Turnstile's own `UsageProcessor` accepted 561 of 561 exported events unaltered; the same 557
    sent twice were stored once. A budget set in Turnstile refused the next gateway request.
  - `Get-ClaudeTurnstileBom.ps1` prices the Turnstile deployment from live list prices: $158.84 a
    month at rest in Central US.
  - Uses the fork naveenneog/turnstile, branch `claude-gateway`: Entra admin-only sign-in and
    bearer tokens, an enterprise catalog API, and a deployer that runs on Windows.
  - `Register-ClaudeTurnstileSchedule.ps1` and `infra/turnstile-schedule.bicep` put the export and
    sync on a schedule: an Azure Container Apps job signed in as its own managed identity, with no
    secret, running a pinned commit ([ADR-0014](docs/adr/0014-turnstile-beside-the-gateway.md)).
    A workload identity is now also granted Reader on the gateway's Application Insights
    resource, which the export reads to find the ledger. Run live on 2026-09-23: a pass took 143 s,
    a changed budget reached Turnstile attributed to the job's identity, and removing its Event
    Hubs grant made the next run fail with 401. The first runs found two faults, both handled: the
    start script carried CRLF from a Windows checkout, and governance automation had stopped
    Turnstile's PostgreSQL server.

- **The projection deploys with no public endpoint anywhere, and was deployed
  and migrated to end to end.** On 2026-09-23, on a Premium v2 gateway in Canada
  Central with the Cosmos account in East US 2, it was populated, compared,
  flipped to, failed over, rolled back and flipped to again.
  `docs/SECURE-PROJECTION.md` is the walkthrough.
  - `infra/resolver.bicep` existed only as a reference in
    `resolver/src/index.mjs`. It is now a Flex Consumption app whose built-in
    authentication admits one caller, the gateway's managed identity, checked
    on application id and object id. Its app registration requires
    assignment, so nothing else can obtain a token for it (`AADSTS50105`). It
    reads one container, and it uses no keys anywhere: storage, Cosmos and
    Application Insights are all Entra-only. Inbound can be private (measured:
    `403 Web App - Unavailable` from outside, `200` through the integrated
    gateway), or public for Basic v2 gateways.
  - `infra/projection-network.bicep` takes an existing VNet and the subnets a
    network team hands over. It creates only the endpoints, zones and links, and
    adds the resolver's `Microsoft.App/environments` subnet and the zones for its
    endpoint and storage. Redeploying it over resources created by hand adopted
    them without duplicates.
  - `sync/` writes the projection from inside the network, as its own identity
    with write access to one container. `Sync-ClaudeProjection.ps1 -ExportPath`
    resolves Entra with the operator's sign-in and writes a snapshot of object
    ids and tiers, so no credential crosses into the network. `--graph` reads
    Entra with the job's own identity where a tenant administrator has granted
    `GroupMember.Read.All` (refused here with `Authorization_RequestDenied`).
    Measured: 8 records in 1.5 seconds, then 8 unchanged on the re-run.
  - `Compare-ClaudeEntitlement.ps1 -ExportGatewayPath` plus
    `apply-projection.mjs --compare` compare the projection with the gateway.
    Each difference is named `would-lose-access`, `would-gain-access`,
    `tier-drift` or `unit-drift`. The migration's step 4 had compared the lists
    with the directory only, which says whether the lists are current and
    nothing about the projection.
  - `scripts/ClaudeRunner.ps1` gets files into the in-network runner. Measured
    on `az container exec`: no shell, URL-decoded (a `+` arrives as a space),
    and under 5,000 characters or refused with `InvalidCommandLength`. So files
    travel as base64url in chunks, checked by SHA-256.
  - `docs/AUTHENTICATION.md`: which credentials reach the gateway, measured.
    People by Azure CLI sign-in, with both audiences; Claude Code CLI 2.1.272
    end to end; a managed identity inside the VNet (150 of 150); a service
    principal (refused, then entitled 39 seconds after its record was written,
    with a 24-hour token); and 401 for a wrong audience, a garbled token or none.
    It says plainly that device code and workload identity federation were not
    run, and that the entitlement check, not token expiry, is what revokes
    access.
  - `tests/Test-SecureProjection.ps1`: 84 assertions and 31 mutations. The
    business-unit order runs the real function over 300 units; the sync rules
    run under `node --test` (20 cases).

- **What to allow on a firewall, measured rather than listed.**
  `docs/NETWORK.md` gives one table per destination, marked with which of the
  three clients — CLI, VS Code extension, Claude Desktop — needs it, and
  separating what is needed to *run* from what is needed to *install*. Three
  hosts are needed to run: the Foundry host on the direct path or API
  Management on the gateway path, plus `login.microsoftonline.com`.

  Two entries that commonly appear on an allowlist and do not do what they
  look like. `cognitiveservices.azure.com` is the **token audience**, the
  string in the OAuth scope — no client connects to it, so an allowlist
  holding it without a wildcard appears to cover Foundry and covers nothing.
  All three build `${resource}.services.ai.azure.com`. And `*.azure-api.net`
  is **not matched by any `*.azure.com` rule**: different suffix, and on the
  gateway path it is the entry that matters most.

  `scripts/Test-ClaudeNetwork.ps1` checks it, and makes a real **streaming**
  call rather than stopping at reachability, because the two are not the same
  question. `scripts/observe-egress.mjs` records what a client attempts and
  forwards it, tunnelling rather than intercepting so it never terminates TLS.

- **Live infrastructure prices in the bill of materials.**
  `Get-ClaudeBom.ps1 -WithPrices` reads `prices.azure.com` for the SKUs
  actually deployed in the region actually deployed. Claude token rates are
  deliberately excluded: measured across 6,734 `Foundry Models` meters in four
  regions, **none is a Claude meter**. They stay in `config/price-book.json`
  with the date they were read.

  `scripts/AzureRetailPrice.ps1` defends the three ways that API returns a
  wrong number quietly. `contains()` is unsupported and returns an empty set
  rather than erroring. A `Free Tier` row shadows the real meter — Cosmos
  `100 RU/s` is published at both $0.008 and $0. Tiered meters start at zero.
  A lookup that finds nothing returns `$null` and never `0`.

- **The P19 platform is decided and priced.** Cosmos DB serverless with an Azure
  Function resolver, recorded in
  [ADR-0011](docs/adr/0011-projection-platform.md).
  `scripts/Measure-ClaudeProjectionCost.ps1` computes the running cost rather
  than quoting one, because the figure that decides it is the cache miss rate and
  nobody can look that up.

  At the full requirement — 500,000 developers, 50,000 active daily, a 60-minute
  cache window — it is **$11.11 a month**: $1.56 Functions, $2.20 Cosmos request
  units, $0.05 storage, $7.30 private endpoint. The resolver is called once per
  cache window per active developer, not once per request, so a developer making
  500 calls an hour and one making 5 cost the same.

  Halving the window to 15 minutes costs $22.99, and most of that is the fixed
  endpoint charge. Every plausible setting is
  affordable, so the cache window is a **revocation decision, not a budget one**
  — which settles how the question still open from ADR-0005 should be answered.

  What it costs instead is a guarantee: serverless offers no guaranteed
  throughput or latency, and Functions cold starts land in p99 on a miss. Both
  are stated rather than left to be discovered.

- `infra/projection.bicep` deploys the projection: a serverless Cosmos account
  with local auth disabled, partitioned on `/oid` so every identity is its own
  logical partition. Partitioning on `/tenantId` — the obvious reading of
  ADR-0005 — would put all 500,000 records in one logical partition, which looks
  correct at eight developers and hits a 20 GB wall later.

  Deployed to the reference subscription to prove it works, which is how the
  private-networking constraint above was found. Nothing reads it yet; that is
  ADR-0009 phase 1, schema first with authorization unchanged.

- **Cache reads are now charged back.** `Get-ClaudeBusinessUnit.ps1` attributes
  them per business unit and shows them in their own **Cache read** column,
  priced at 0.1x base input.

  Chargeback previously omitted cache entirely. On measured usage that is 38.7%
  of real cost weight, and the omission is uneven — a team reusing a large cached
  prompt was under-charged against one that does not.

  The recorded blocker turned out to be too broad. "No APIM-native source carries
  the cache categories" is true per request; the gateway's own
  `llm-emit-token-metric` emits `Prompt Cached Tokens` carrying a `UserId`
  dimension, which is the same object id `bu-members` keys on. Measured
  2026-09-17: 6,833,717 cached tokens across 162 rows, against a `UserId` already
  in the business-unit map. On the reference deployment the report now shows
  6,105 metered tokens beside 6,833,717 cache reads.

  Cache read is reported **beside** `tokens_used`, not inside it, because the
  quota still cannot see it — folding it in would imply the budget counts it.

  Still missing, and stated in the output: cache *write*, the 5-minute and 1-hour
  categories, which exist only in the response body. Reading that in an outbound
  policy buffers the response and ends streaming. Enforcement remains blind to
  every cache category — U13, unchanged.

- `Test-ClaudeHealth.ps1` answers, in one command, whether the gateway needs
  attention. Six read-only checks: the API Management tier is v2, entitlement is
  in sync with the directory, no named value is near its limit, every deployed
  Claude model is priced, nothing can reach Foundry around the gateway, and no
  entitled developer is without a business unit.

  It runs the shipped checks and reads their exit codes rather than
  reimplementing them, so there is no second copy of the logic to drift. Each
  finding carries the command that fixes it. `-AsJson` for monitoring, `-FailOn
  warn` for a scheduled gate, `-Detailed` to see each check's own output.

  Nothing is written, so it can be run freely.

- `Add-ClaudeModel.ps1` makes a newly released Claude model usable in one
  command: it checks the model is deployed (and deploys it with `-Deploy`), adds
  it to the tier allow lists, writes its price, and prints what developers have
  to change — the model name, and nothing else.

  Four things have to agree for a model to work, and the third fails quietly:

  | | Where | If missed |
  |---|---|---|
  | Deployed | the Foundry account | Foundry refuses |
  | Allowed | `models-standard` / `models-premium` | the gateway 403s |
  | **Priced** | `config/price-book.json` | **served, and reported at $0** |
  | Selectable | `availableModels`, if pinned | the client hides it |

  An unpriced model is refused unless `-SkipPrice` is passed, and `-List` marks
  it red. `-Remove` retires a model and deliberately keeps its price, because a
  report covering a past month still needs the rate that applied then.

  Only Claude deployments are listed. The reference account also carries GPT,
  Sora and embedding deployments; showing them as unpriced would be true and
  useless.

- The price book moved out of the code into `config/price-book.json`, so a new
  model is no longer a code change. The file is git-ignored — it may hold
  negotiated rates rather than list price, which is commercially sensitive — and
  `config/price-book.example.json` ships instead. With no file, the built-in list
  rates apply, so a fresh clone works. A malformed file throws rather than
  falling back, and rates are cast to decimal on load because `ConvertFrom-Json`
  produces doubles and ADR-0010 requires decimal end to end.

- `New-ClaudeCodePolicy.ps1` gained `-Marketplace`, `-BlockUserPlugins` and
  `-RequireSignedExtensions`. A plugin runs with the developer's own permissions
  and can add tools, skills, hooks and MCP servers, so where plugins come from is
  worth pinning. Claude Code and Claude Desktop use different key names for the
  same idea, and both are emitted from one input:

  `strictKnownMarketplaces` for Claude Code; `allowedPluginMarketplaces`,
  `userPluginMarketplacesEnabled`, `userPluginUploadsEnabled`,
  `disableDeploymentModeChooser` and `isDesktopExtensionSignatureRequired` for
  Claude Desktop.

  Both guides state the limit plainly: these are feature-availability controls,
  not data boundaries. Marketplaces already registered — including any registered
  outside the app, such as by the Claude Code CLI — are not removed by them.

- `docs/MODELS.md` and `docs/PLUGINS.md`.

- `Measure-ClaudeOvershoot.ps1` measures how far spend runs past a budget before
  a kill switch stops it, because a budget enforced outside the request path
  cannot be a hard cap and the gap should be a number rather than a shrug.

  Measured on the reference deployment: telemetry lag **193s worst**, 87s median
  over 102 requests; named-value propagation **17s**; with a 300s job interval
  that is a **511s window**, plus requests already admitted and still streaming.

  The worst case feeds the bound, not the median — telemetry lag ranged 56s to
  193s, and a bound on the median would be wrong about half the time in the
  direction that matters. Propagation is observed through a gateway response
  header rather than by reading the named value back, because ARM returns the
  new value immediately and that says nothing about when the policy sees it.

  Nothing is left changed: the override map is restored in a `finally`, and a
  failed restore says so loudly.

- [ADR-0010](docs/adr/0010-financial-semantics.md) settles the financial
  semantics that P21 and P23 both depend on, each answer grounded in a
  measurement already recorded here rather than a pricing page:

  an internal tariff at **list price** rather than actual Azure cost, because the
  CCU meter carries no per-user or per-model split and private-offer discounts
  apply before conversion; all five token categories billable at their measured
  multipliers — cache read 0.1x, five-minute write 1.25x, one-hour write 2x — and
  never summed before pricing, since total input is defined as the sum of input,
  cache creation and cache read; pricing joined on the **deployment** rather than
  the model alias the client sent, with the `inference_geo` multiplier that
  applies to the request; decimal arithmetic rounded **once**, at presentation; a
  price book versioned by effective interval so a price change cannot rewrite a
  month that was already signed off; UTC periods so the quota renewal and the
  reporting month are the same boundary; an append-only ledger where corrections
  are new rows; and **"soft cap" defined as approximate blocking, not warn-only**,
  which is the term most likely to be read the wrong way by a finance owner.

- `Compare-ClaudeEntitlement.ps1` resolves every identity twice — once from what
  the gateway is enforcing, once from the directory — and exits non-zero when
  the two disagree. It reports `missing` (added in the portal, still getting
  403), `stale` (removed, still entitled) and `tier-drift`.

  Tier is resolved with the policy's own precedence, premium before standard, so
  an identity in both groups is premium on both sides. Resolving it the other
  way would report drift the gateway does not have, and a noisy comparison stops
  being read.

  Negative-tested on the reference deployment rather than assumed to work:
  removing an identity from its Entra group without running the sync produced
  `stale (1)` and exit 1, and re-adding it returned the comparison to clean.

  This is phase 2 of the migration in ADR-0009, and it is useful before any of
  that is built: entitlement is not live, and this measures the gap between a
  directory change and the sync.

- `ClaudeGraphMembership.ps1` — the Graph membership read, extracted from
  `Sync-ClaudeAccess.ps1` so the writer and the comparison cannot drift apart. A
  comparison that reads the directory differently from the writer reports its own
  bugs as drift. The request form it holds took six measured combinations to
  find, which is exactly the kind of thing that gets reimplemented slightly wrong.

- [ADR-0009](docs/adr/0009-shadow-migration.md) — how entitlement migrates.
  Five phases with authorization unchanged until the canary, counter keys and
  period boundaries preserved throughout, and a rollback that restores
  authorization without restoring consumption.

  Budgets are consumed state rather than configuration: a developer at 80% of a
  monthly allowance carries a number that exists only in the gateway's counters,
  and a migration that re-keys them hands that allowance back. A budget that has
  stopped binding looks like a budget that is working.

  The mid-period opening balance — full allowance or pro-rata — is a finance
  question, so it is deferred to P20b and the current behaviour is stated rather
  than left to be discovered.

- `Measure-ClaudeCeiling.ps1` reports how close a gateway is to the limits that
  stop it scaling, and exits non-zero past a threshold so it runs as a check.

  The figures it enforces were measured against a live instance rather than read
  from a document, because the two have disagreed: a named value holds **4,096
  characters** (4,097 returns `ValidationError`) and **110 object ids** (110 is
  4,071 characters and is accepted; 111 is 4,108 and is rejected). The identity
  ceiling is derived from those two rather than written as a literal, so it
  stops being correct out loud if the service limit changes.

  Per-entry cost is measured from the list being read, not assumed to be 37
  characters. A `bu-members` entry carries `oid=unit` and costs 44, so assuming
  the smaller figure overstates remaining room on the list that fills first.

  On the reference deployment: 3, 5 and 5 entries against a 110 ceiling, and 22
  of 5,000 named values.

- `docs/SCALE.md` — the load envelope. It states what runs out first, why
  sharding the list across named values is not the escape it appears to be, and
  the five numbers a capacity figure needs that "500,000 employees" does not
  supply: daily actives, peak requests per second, peak token rate, streaming
  concurrency and burst shape.

  It also states what has **not** been measured. The reference deployment's
  ledger holds 111 requests across 2 days, so it cannot supply a traffic model,
  and the page does not extrapolate one from it.

  A capacity test that proves 500,000 counter keys can be created proves nothing
  about whether allowance survives scale-out, policy deployment or period
  rollover. The page says what the test has to demonstrate instead.

- `Get-ClaudeBom.ps1` reads the live deployment and reports only this gateway's
  own resources, separating what it created and bills for, what it reuses and
  did not create, and what is configuration and carries no bill at all. On the
  reference deployment that is 5 of 66 resources in the group, of which only
  API Management meaningfully costs anything.
- `docs/images/request-flow.png` — the six-hop request and telemetry path,
  rendered from HTML rather than generated, because the value of the picture is
  that the resource and table names on it are the real ones.
- `Publish-ClaudeGrafana.ps1` — optional, for organisations that already run
  Grafana. It reads the same saved KQL functions as the workbook, states that
  Grafana is charged per instance per hour whether or not anyone opens it, and
  will not create the instance.
- `Set-ClaudeDeveloper.ps1` — add or remove one person. It edits the **Entra
  group**, not the gateway, because `Sync-ClaudeAccess.ps1` rebuilds the allow
  lists from group membership every run: a developer added straight to a named
  value works until the next sync and then silently stops. `-Sync` publishes in
  the same command; without it the script says the change is in the directory
  but not yet at the gateway. Removing clears every business unit as well as
  both tiers, because leaving someone on a budget they can no longer spend reads
  as a broken team rather than a half-finished offboarding.
- A decision tree at the top of the README, routing by who you are, with the
  nine commands for running it day to day inline rather than behind another page.
- Claude Desktop backup and restore. `Backup-ClaudeDesktop.ps1` captures both
  profile roots - `%APPDATA%\Claude` for first-party and
  `%LOCALAPPDATA%\Claude-3p` for this gateway - and refuses while the app is
  running, because it holds its conversation database open. Measured with
  Desktop running, `LOCK`, `LOG` and `000003.log` could not be opened while
  `CURRENT` could, so a copy taken then is part of a LevelDB and restores as
  corruption. The restore refuses harder: writing into a live database takes the
  history already on that machine with it.
- The virtual machine bulk is excluded. Measured, a third-party profile is
  11.4 GB of which `vm_bundles` alone is 10.6 GB, against 4 MB of session data.
  A synthetic profile of 6 MB, nearly all bulk, produced a 2 KB archive.
- `Migrate-ClaudeWorkstation.ps1` - the developer-side tool. `-Status` reports
  what is on the machine, `-Backup` captures Claude Code and Desktop,
  `-Configure` points everything at the gateway, `-Restore` puts it back. It
  warns that configuring switches Desktop to a different profile root, so the
  first thing seen afterwards is an empty Desktop - backing up first makes that
  reversible.
- The installer sizes the SKU. It asks how many developers and shows the
  arithmetic against published included request volume, because Microsoft
  publishes no requests-per-second per unit for the v2 tiers - the guidance is
  to load test. On that basis Basic v2 covers about 900 developers, so it also
  says what usually decides the tier instead: Basic v2 has no VNet integration
  and no availability zones.
- `Set-ClaudeTier.ps1` reads and changes tier limits and model allow lists,
  checking models against what the Foundry account actually serves - a tier
  allowing an undeployed model refuses the caller with a name that looks
  correct. It states plainly that a third tier is a policy change, because the
  policy names `standard` and `premium` in five places.
- `Set-ClaudeBusinessUnit.ps1` verifies the Entra group exists before writing,
  and offers near matches. A unit pointing at a missing group is created, syncs
  to nobody, and reads as unused rather than broken.
- The gateway records which client made the call. Nothing in API Management
  carried it — measured 2026-09-16, `AppRequests.Properties` held only API and
  service metadata, `ClientType` read `PC` and `ClientBrowser` was empty. The
  chargeback trace now captures the `User-Agent`, truncated, and the ledger
  parses the surface out of it. **Parsed, not matched against a list**: Claude
  Code 2.1.241 identifies itself as `claude-cli/2.1.241 (external, sdk-cli)`,
  and a list built on the obvious guess of `cli` mis-buckets the real CLI.
  Verified live against the real CLI plus Desktop-, VS Code- and SDK-shaped
  agents.
- `scripts/Publish-ClaudeQueries.ps1` publishes the queries in `analytics/` as
  callable workspace functions — `ClaudeChargeback()`, `ClaudeCodeDaily()`. The
  `.kql` files stay the source; only the window lines are rewritten into
  parameters, and it refuses to publish when it cannot find them, because a
  function pinned to a fixed window answers every question wrongly and looks
  right doing it. Verified the parameter is honoured: 44, 5, 44 and 0 rows
  across four windows.
- `infra/workbook.json` and `scripts/Publish-ClaudeWorkbook.ps1` — the Observe
  pane. Consumption by business unit, by client, by developer, by model and over
  time, plus what could not be attributed. It refuses when the definition is not
  valid JSON or when the workspace lacks the functions it calls, either of which
  produces a dashboard that opens on an error. The id is derived from the
  resource group and display name, so re-running updates in place rather than
  leaving a second copy. Neither a saved search nor a workbook stores or runs
  anything, so no always-on component was added.
- The installer finds or creates a Claude deployment. It used to stop with "the
  gateway fronts a model, it cannot create one" when no account had one, which
  is true of the gateway and beside the point for an installer already signed in
  to the subscription where the deployment would be made. It now lists the
  models the account is entitled to deploy — read from the account, because what
  is offerable depends on region and entitlement — asks which and at what
  capacity, and creates it. `scripts/ClaudeModelDeployment.ps1` holds the logic.
- Tier model lists come from what is actually deployed. The installer shows each
  Claude deployment with its SKU and capacity and asks which models each tier may
  call, defaulting premium to all of them and standard to everything except Opus,
  which costs five times Sonnet per output token. Previously `modelsStandard` and
  `modelsPremium` were never passed at all.
- Quota is separated from other deployment failures.
  `Get-DeploymentFailureReason` classifies Azure's error and says what to do —
  ask for quota, lower the capacity, or change region — because a generic
  "deployment failed" sends the operator to retry when none of those is a retry.
- Teams. A team is a business unit that names a parent, decided in
  [ADR-0008](docs/adr/0008-teams-and-tiers.md). A request is charged to the team
  and to the business unit above it — two monthly counters, both soft. Verified
  live: one request returned `x-bu-quota-remaining: 1666666644` for the team and
  `x-bu-parent-quota-remaining: 5555555533` for its parent, alongside the
  unchanged org ceiling.
- `-Parent` on `Set-ClaudeBusinessUnit.ps1`, with `bu-parents` as a second named
  value. Depth is capped at two and cycles are refused when written, because the
  cascade is two policy elements with fixed counter keys and no loop — a third
  level would go uncharged rather than fail. Removing a business unit promotes
  its teams to top level instead of leaving a dangling parent.
- Hierarchy in the reports. `Set-ClaudeBusinessUnit.ps1 -List` and
  `Get-ClaudeBusinessUnit.ps1` indent teams under their parent, and a parent's
  figure is the roll-up of its own members and its teams — which is what its
  counter actually enforces.
- Tier by nesting. A team gets a tier by putting the team group inside
  `claude-code-standard` or `claude-code-premium`. Nothing in the tier mechanism
  changed; entitlement was already resolved transitively.
- `tests/Test-Teams.ps1`, and eight more mutations in
  `tests/Test-BusinessUnitsNegative.ps1`, which now drives both suites.
- `guide/capture-entra.mjs` screenshots the Entra group blades that back the
  hierarchy. It exits non-zero on an expired session rather than saving the
  sign-in page.
- Business units. A business unit is an Entra security group registered with a
  monthly budget, decided in [ADR-0007](docs/adr/0007-business-unit-model.md).
  `scripts/Set-ClaudeBusinessUnit.ps1` adds, edits, lists and removes them;
  `scripts/Get-ClaudeBusinessUnit.ps1` reports budgets, members and spend;
  `docs/BUSINESS-UNITS.md` is the guide. The registry key is a stable identifier
  rather than the display name, so renaming a group in Entra does not move spend
  to a new line.
- Business-unit membership sync. `Sync-ClaudeAccess.ps1` now resolves each unit's
  group to object ids and writes the `bu-members` map alongside the entitlement
  list, under the same guard that refuses to overwrite a populated map with an
  empty one.
- Business-unit soft cap in `infra/policy.xml`. A unit with a budget gets a
  monthly `llm-token-limit` keyed on its identifier, and exhausting it returns a
  fourth distinct `403` that names the unit. A unit with no budget set is
  skipped rather than refused, so an unpriced unit behaves like the organisation
  ceiling alone. Developers in no unit are `unassigned`, allowed by default
  because no one has a unit on the deployment that first installs this.
- `tests/Test-BusinessUnits.ps1`, 66 assertions, and
  `tests/Test-BusinessUnitsNegative.ps1`, which breaks each thing those
  assertions guard and confirms the suite goes red. Both are wired into
  `tests/Test-All.ps1`.
- `tests/Test-FormatStrings.ps1`, a repo-wide check that every .NET format
  string parses and runs.

### Changed

- **The gate's command budget is 60 minutes until the exclusive checks are sharded (P77).**
  `.ironclad/charter.json` gave every gate command 1,800 seconds (ADR-0025). On 2026-09-28 four packet
  gates passed in 1,368 to 1,688 seconds and three timed out at 1,800, the last at the default
  throttle with no other gate or review running; throttle 8 was slower, with per-check timeouts.
  A timeout ends only the gate's shell, and `Test-All` kept running for ten minutes after one.
  `commandTimeoutMs` is 3,600,000; no check, mutation, throttle or per-check timeout changes. P78
  shards the long exclusive checks and returns the budget to 1,800 seconds
  ([ADR-0036](docs/adr/0036-gate-budget-until-sharded.md)).
- **The guided flow starts at once (P68).** `Start-ClaudeGateway.ps1` listed every subscription,
  API Management instance, Foundry account, workspace and deployment before its first line, 66 s on
  the reference subscription, for lists no step read. Discovery now reads only the gateway the
  record names, with one `az apim show` announced with an estimate and timed; with an empty record
  it reads nothing, and the first line appeared after 0.76 s and the review after 2.3 s. A gateway
  Azure reports missing, or a URL that differs, is drift; a read that fails for another reason is
  reported and is not drift, and Status says drift was not checked. The FinOps step announces its
  price read and reads each region once. ADR-0032.
- **In a console, Setup gives the foundation to the installer (P68).** Setup runs
  `Install-ClaudeGateway.ps1` first without `-Yes`, so the installer asks its own questions and its
  summary approves what it creates; declining there stops the flow with no stack trace. Setup then
  reads the new gateway and asks the remaining steps, FinOps first and priced in the gateway's
  region, with the typed fingerprint. `CLAUDE_INTERACTIVE=1` lets a test drive an attended run
  through standard input. ADR-0032, [Guided flow](docs/GUIDED-FLOW.md#attended-setup).
- **The installer prices its region and tier choices (P68).** The region prompt lists the Foundry
  account's region and the rest of its geography with each v2 tier's monthly list price from one
  Azure Retail Prices API call, and names the agreement's price sheet as the authority (**U31**);
  the tier prompt prices each tier in the chosen region. The installer records `sku`, `location`,
  `foundryAccount` and `foundryResourceGroup` in `claude-gateway.json`, numbers its next steps, and
  run on its own in a console offers the FinOps tool; `-SkipFinOpsOffer` is for the guided flow.
  The Foundry account search states its estimate and reports each account as it is read.

- **AUM shows the owner's ASCII art on every tab.** The four-line art was in the code byte for byte
  but appeared only at 120x38 or larger and only on Overview, so common terminals never showed it.
  It is now the header on every tab at AUM's documented minimum of 80x24 or larger, with the
  product name and the signed-in identity beside it; smaller terminals, `--plain`,
  `--screen-reader`, `--json` and piped output keep the compact heading or none.
- **Scripts ask for a value they were not given, and say where it comes from.**
  `scripts/ClaudeChoice.ps1` offers the options discovered in Azure, numbered, with the one the
  deployment points at recommended and the command and portal path to look it up; without a
  console it uses a certain recommendation and otherwise stops naming the candidates. The
  publishers (`Publish-ClaudeQueries.ps1`, `Publish-ClaudeWorkbook.ps1`, `Publish-ClaudeGrafana.ps1`)
  now find the workspace behind the gateway's Application Insights instead of refusing when a
  resource group holds several, and `Get-ClaudeTelemetry.ps1` prints that `Workspace` and no
  longer takes the first API Management instance in a group.
- **The chargeback ledger records the caller's address.** `analytics/chargeback-ledger.kql` has a
  `client_ip` column, from a new `ClientIp` field in the gateway's identity trace: behind the P54
  edge it is the edge's socket peer, otherwise the address APIM saw. It is personal data; review
  who can read the ledger and how long it is kept. Every response also carries
  `x-claude-gateway-request-id`, the id the ledger joins on.
- **The documentation is organised by what a reader is trying to do.** README is a 278-line
  landing page with a documentation map, down from 710 lines, and five task guides were added:
  Operations, Budgets, FinOps, Reference and Data governance. Guides say where each value comes
  from and give the command that discovers it, with the portal path beside the script. Seventy
  findings from walking eight reader journeys were fixed. `tests/Test-DocReferences.ps1` fails
  on a broken link or anchor, or on a script or parameter a guide names that does not exist.

- **The test suite runs in parallel, and the gate's budget is 30 minutes again.** `Test-All`
  starts each check as its own `pwsh` process, four at a time, with an exclusive lane for checks
  that share Azure CLI state or scan the whole tree, logs in registration order, and a 600 s
  deadline per check. The business-unit and Turnstile mutation harnesses run as four and two
  shards, and `tests/Test-MutationShards.ps1` proves the shards cover all 476 and 108 mutations
  exactly. Measured on a busy machine: 790 to 927 s, against 1,829 s serially.
  [ADR-0025](docs/adr/0025-parallel-test-suite.md).

- **The gate gives the test suite 60 minutes, and the suite reports where its time goes.**
  `tests/Test-All.ps1` took 1,797.2 s on `690015d` against a 1,800 s command budget, and a
  budget-modes gate had already failed on time with no failing check. `commandTimeoutMs` is now
  3,600,000 ([ADR-0024](docs/adr/0024-test-suite-time-budget.md)); `Test-All` prints each check's
  seconds and the five slowest, and writes them to `test-all-timings-<utc>-<pid>.json` in the temp
  folder, because the gate discards the suite's output when it passes. P56 makes the suite
  parallel so the budget can return to 30 minutes.

- Money moved from `[double]` to `[decimal]` in `ClaudeBusinessUnit.ps1`,
  `Set-ClaudeBusinessUnit.ps1` and `Get-ClaudeBusinessUnit.ps1`, and token spend
  is accumulated as `[long]` rather than `0.0`.

  A rate of 0.000002 per token accumulated over millions of tokens in binary
  floating point does not reproduce, and a chargeback figure that changes between
  two runs of the same query cannot be argued with. After the change $5,000
  converts to 1,388,888,888 tokens and back to exactly $5000.00.

### Fixed

- **P96 a business unit identifier with a capital, or another spelling of a stored one.**
  `scripts/Set-ClaudeBusinessUnit.ps1` accepted a new identifier such as `Platform` and then stopped at
  the dollar budget with "Invalid USD scope identifier." (`scripts/ClaudeUsdBudgets.ps1:42`); the AUM
  catalog action wrote such an identifier to `bu-registry`; and `scripts/Manage-ClaudeBusinessUnits.ps1`
  accepted it at its prompt and offered to create the Entra group. A spelling that differed only in case
  from a stored unit, such as `Sales` for `sales` or `legacy-unit` for `Legacy-Unit`, changed, renamed
  or removed that unit, and a registry that held two such spellings lost one at the next change. A new
  identifier is now refused with the lower-case rule, and another spelling of a stored unit with the
  stored spelling, before any write. The script, the AUM bridge and the Turnstile budget pull compare
  identifiers by their characters and keep each spelling's mode and parent entry, and a budget mode is
  refused for an identifier with capitals, which `bu-modes` cannot hold. A unit that the registry holds
  with capitals keeps working under that spelling
  ([P96 status](docs/status/P96.md#p96-fixes-from-a-live-deployment-2026-10-05)).
- **P96 the guided flow's Tier and Desktop sign-in changes.** `Start-ClaudeGateway.ps1 -Action Change`
  with `-Change sku` or `-Change desktopSignIn` stopped at the write gate with "A named-value snapshot
  path is required before applying this lifecycle change." Both steps now export the gateway to
  `backups/before-tier-<apim>-<UTC time>.json` or `backups/before-desktop-sign-in-<apim>-<UTC time>.json`
  before their write ([P96 status](docs/status/P96.md#p96-fixes-from-a-live-deployment-2026-10-05)).
- **P95 no switch path could reach the projection.** The deployer's `-FlipAfterCleanCompare`
  redeployed and applied a fresh snapshot before admission, so admission refused every attempt as
  an older generation; the guided flow's live discovery supplied no renewal evidence and ran no
  compare; admission accepted any action-group id and did not tie the job's evidence to its
  settings. README, six guides, the deployer synopsis and the preflight refusal said the switch
  was unavailable or later work. Each is corrected with tests
  ([P95 status](docs/status/P95.md#p95-the-projection-switch-over-runs-end-to-end-2026-10-05)).
- **P95 council round 1.** The guided flow's real entry point (`Get-ClaudeFlowDiscovery`) carried no
  receipt and gave the Entitlement plan no snapshot path, so it refused every switch. Admission's
  command quoted the entry point, which `az.cmd` and the runner split, so every live admission
  would have failed. No script set `entitlement-resolver-url` after P84, so a scripted switch would
  have pointed every request at the placeholder resolver. Receipt values reached `az.cmd`, the
  runner and ARM URLs unchecked, so a planted receipt could run commands or send the management
  token to another host. A restore could set `entitlement-source` to `projection`. A failed runner
  compare read as a projection mismatch, an unreadable job gave the raw ARM error, `-Confirm`
  prompted for working files first, and `-RenewalEntryPoint` was ignored. Each is corrected with a
  test ([P95 council](docs/status/P95.md#council)).
- **P95 council round 2.** The switch trusted the resolver deployment's recorded parameters, so a
  resolver site whose settings had since changed passed; it now reads the live site and its
  application settings. The deployer's normal run repointed a gateway that already served from the
  projection, which would move every request to a new, unpopulated resolver; it now stops. A failed
  read of `entitlement-source` or the resolver values during an installer redeploy returned the
  gateway to named values; those reads now stop the run. Discovery found a receipt only beside the
  decision record; it now also reads the repository's `onboarding/`, where the renewal deployer
  writes it. Each is corrected with a test ([P95 council](docs/status/P95.md#council)).
- **P95 council round 3.** A failed read of whether the gateway exists made the installer take an
  existing gateway for new, skip its fail-closed reads and deploy the template's defaults over it;
  only Azure's not-found answer now means a new gateway. The deployer redeployed the resolver site
  and its sign-in settings before its projection check, so on a gateway on the projection a rerun
  with another resolver app changed the live resolver and then refused; the check now runs before
  any write, `-PreflightOnly` and `-WhatIf` included. The guided Entitlement plan listed a deployment
  and list writes the step does not make and a rollback without the refresh and compare. A resource
  group name with parentheses was asked for again in the same form. Refusals without a remedy now
  name one. Each is corrected with a test ([P95 council](docs/status/P95.md#council)).
- **P95 council round 4.** The deployer's projection check compared the gateway's URL with the last
  resolver deployment record, whose outputs a failed deployment leaves empty, so one failed resolver
  redeploy blocked every rerun; it now reads the site the run redeploys. The refusal said nothing had
  changed when the installer had already deployed the gateway, and named only the deployer's
  `-ResolverAppId`; it now says what this run did not write and names the installer's
  `-ProjectionResolverAppId` too. Each guided Entitlement direction names the rights its own step
  uses ([P95 council](docs/status/P95.md#council)).
- **P94 the renewal job could not be deployed or run as merged.** The image and the runner archive
  missed `resolver/src/entitlement.mjs`, which `sync/src/plan.mjs` imports, so the job, the runner
  apply and compare, and admission stopped with a missing module; the runner archive now holds the
  same package as the image and installs from a committed lockfile. The renewal template needed the
  digest of an image in a registry it created itself; the job had no `AZURE_CLIENT_ID`; its name
  exceeded the 32-character Container Apps limit for prefixes over 9 characters; and the alerts read
  the legacy `_CL` table, ended in a `summarize` that always returns a row and passed `now()` as
  epoch seconds. Each is corrected with tests ([P94 status](docs/status/P94.md#p94-the-p86-renewal-job-deploys-and-renews-2026-10-04)).
- **P94 council rounds 1-3.** A refusal from `scripts/Deploy-ClaudeProjectionRenewal.ps1` prints its
  message alone, one refused value per line. The script and the guide refuse a resource group that
  still holds P86's renewal job, environment or failure alert, matched by name and resource type,
  with the delete commands, and refuse one group for both tiers, as admission now does; the script
  refuses a subnet id, from its parameter or the network deployment, or a registry name with
  characters that `cmd.exe` re-reads. The guide reads the tier group ids from the section 5 group
  receipts recorded for the current group names, refuses an id that is not an object id, and
  removes its package directory. The job treats a unit whose group was deleted as an empty unit,
  computes the oldest expiry with a loop that holds past 125,000 records, and orders unit ids that
  differ only in case as PowerShell does. Every `npm ci` of the sync package skips install scripts.
  The receipt records the tier group ids and the identity's client id
  ([P94 council](docs/status/P94.md#council)).
- **P88 AUM test clock independence.** AUM pytest now pins `datetime.now(timezone.utc)` for `claude_finops` modules and AUM test helpers to an advancing instant inside the September fixture month without changing the stdlib datetime module. A real-clock opt-out, clock-reader coverage guard and September service budget write guard keep the seam reversible.
- **AUM lookups could cancel their own view refresh (P71 follow-up).** A changed
  tab and its caller both started exclusive refresh workers. Lookup, breadcrumb,
  saved-view, comparison, usage-basis, ranking and dashboard navigation now
  refresh once; Advanced navigation also suppresses its programmatic selector
  echo. Same-tab actions still reload. Redaction assertions and publication
  guards are unchanged; hosted run 36670519226 is recorded in STATUS.
  Council correction: accepted compound navigation now owns an explicit refresh
  even while a principal notice suppresses native activation. The notice is not
  cleared to obtain a read, expired lookup origins remain refused, and obsolete
  native pane-focus events cannot retarget or cancel the newer lookup.
  Request lookups follow the same rule: one target-view refresh and one detail
  read for changed/current tabs and non-input calls under a notice. Refresh
  preserves offset/cursor paging and consumes request-row selection. Normal
  input clears the notice before the lookup action is dispatched. A request
  lookup returns the id its backend read back, so a request typed in another
  letter case selects the backend's row.
- **The Cloud Shell launcher tests depended on Git Bash's /tmp mount (P85 follow-up).** The tests
  converted paths with `cygpath -u`, which names a folder under the Windows temp folder `/tmp/...`.
  One test starts Git Bash with `TMP` and `TEMP` set to a missing folder; the hosted runner's Git
  Bash then could not resolve `/tmp`, and the launcher's path did not exist (hosted run
  36668853983). The tests now use the drive form (`/c/...`) for every path. The launcher is
  unchanged.
- **The AUM deadline tests raced process teardown on hosted runners (P71 follow-up).** Two tests
  in `cli/finops/tests/test_azure_deadline.py` checked, with a zero-millisecond wait, that each
  descendant had exited right after the Azure CLI deadline. `TerminateJobObject` starts
  termination and returns before the processes are signaled, so hosted run 36646539868 on main
  `3b7c192` reported a terminated descendant as still running. The descendants now record their
  creation time and outlive the test, and the check waits up to 10 s for the recorded process to
  end; a reused process id no longer counts as the descendant. The timeout code is unchanged.
- **The guided flow's FinOps step failed for every tool but None (P79).** It stopped at "Applying
  FinOps..." with "Cannot convert value to type System.String.": `& $path @($Command.arguments)`
  passed the argument list as one array, which the advanced scripts it runs refuse for a `[string]`
  parameter, and a string such as `-Accept` in a splatted array is a positional value to a script.
  A PowerShell script's command now carries named parameters, splatted as a hashtable; `aum`
  keeps its string arguments; a command's output is shown, not returned into the step's change
  set. `tests/Test-FlowFinOpsApply.ps1` applies every choice on both shells against stubs that
  carry the real scripts' parameter blocks.
- **A relative record path meant the process's start directory (P79).** From the repository root,
  `.\Update-ClaudeGateway.ps1` read `C:\Users\<name>\onboarding\claude-gateway.json`:
  `[IO.File]` resolves a relative path against the directory PowerShell started in, which `cd`
  does not change. `Read-` and `Write-ClaudeDecisionRecord` resolve it against PowerShell's current
  folder, and the root Update shim resolves a relative `-RecordPath` against the repository, as
  `Start-ClaudeGateway.ps1` does (`tests/Test-RelativeRecordPath.ps1`).
- **The installer refused a record for another gateway only after every question (P79).** The
  comparison now runs when the gateway is chosen; in a console the installer offers to keep that
  record as `onboarding\claude-gateway.<resource group>-<instance>.json` and start a new one, and
  `-ArchiveSavedRecord` does the same unattended.
- **The developer count asked about a store that exists (P79).** Above about 93 developers the
  installer asked "Continue anyway" before the tier and the entitlement store were chosen, saying
  the Cosmos store "is not built yet"; P61 built it on every v2 tier. The count now prints a note,
  and the confirmation follows the store question, only for named values.
- **The installer permutation check read the checkout's own saved record (P79 follow-up).** After
  P79 moved the saved-record comparison to the gateway question, 14 of the check's assertions failed
  in any checkout whose `onboarding\claude-gateway.json` names another gateway, such as the main
  worktree, with "Saved record ... names gateway ..."; packet worktrees have no record, so the P79
  gate passed. `tests/Test-InstallerPermutations.ps1` runs a copy of the installer's inputs without
  saved records and asserts the copy, the installer path and that the checkout's own record is
  unchanged.
- **The macOS/Linux installer approved every choice against a fixed price (P75).**
  `install-claude-gateway.sh` printed "BasicV2 is about $150/month at list price" and "Provisioning
  takes 30-45 minutes" whatever tier and region were chosen; `Install-ClaudeGateway.ps1` stopped
  printing both before P68. It now lists the default region and the other regions in its
  geography that publish an API Management v2 price, cheapest Basic v2 first, each with the three
  tiers' monthly list price for one unit at 730 hours, from one Retail Prices API call and rounded
  to the cent as the PowerShell installer rounds it on PowerShell 7 ([decimal] of the double, half to
  even); prices the tier prompt and the summary; and
  says so, with the reason, when the prices cannot be read or are not in the form the API
  publishes. It reads a next page of the price list only on `https://prices.azure.com`. Its
  record gains `mode`, `sku`, `location`, `foundryAccount`, `foundryResourceGroup` and
  `requestsPerMinute`, and, run on its own in a terminal, it offers the FinOps tool
  (`--choose-finops`, `--skip-finops-offer`). The admin preflight warns on jq 1.7.0, which reads a price
  written with 17 significant digits through a 16-digit decimal. `tests/Test-BashInstaller.ps1` runs 21 installs in
  Git Bash with stub `az`, `curl` and `pwsh`, and compares the region table with the one
  `Install-ClaudeGateway.ps1` prints for the same list, over 170 prices, ten of them written with trailing
  zeros, an exponent, 16 or 17 significant digits or above 10,000.
- **jq.exe on Windows ends lines with CRLF (P75).** In Git Bash, command substitution drops the
  carriage return of the last line only, so the last field of every other region line kept one,
  and a price the region does not publish printed as USD 0.00. The region lines drop it before
  they are split, and the test stubs refuse any `az` or `curl` argument that carries one.
- **One plan still had two fingerprints on the two shells (P76).** A live `-PlanOnly` over the
  reference record printed one review and two fingerprints: Monitoring sorted its workbooks with
  `Sort-Object`, which compares by culture, and .NET Framework and .NET weigh a hyphen differently.
  The named values of the Update migration `0002` had the same fault, and so did the order of the
  step modules and of the migrations. Merged from P70 the same day, the model change sorted its
  deployments, tier lists and questions the same way: on Windows PowerShell 5.1 a model change over
  tier lists already in code-point order proposed rewriting both lists, and its fingerprint differed
  from PowerShell 7's. The price-book entry a deployment takes, the region choice, the deployable
  models and the installer's default tier lists had the same fault. All of them order by code point
  through `Sort-ClaudeFlowOrdinal`, which now takes several keys, compares numbers, times and versions
  by value, and has `-Descending`. `tests/Test-FlowOrdinalOrder.ps1` compares every shipped Setup step
  and a model change on both shells, follows every script the plans load and lists each `Sort-Object`
  left in them with its reason. For the shipped lists, PowerShell 7's culture order was already
  code-point order (measured), so its plans keep their fingerprints; on Windows PowerShell 5.1 the
  Monitoring and Update plans have new ones.
- **`-AuthMode` skipped the installer's Claude Desktop sign-in section (P72).** The Desktop
  questions and the external IdP record sat inside the `else` branch that asks the developer
  sign-in, so `-AuthMode device -DesktopSignInKind external-idp-browser -DesktopEntraClientId <id>`
  recorded the helper script without a word; measured live under `-WhatIf -Yes` on 2026-09-27.
  The guided flow's unattended Setup and Change pass both parameters. The section now runs whatever
  `-AuthMode` is. Under `-Yes` an external IdP sign-in without its client id, or `access_token`
  without its scope and audience, stops before the summary, naming the parameter.
- **The installer's summary named one choice out of seven (P72).** It is the approval, and it now
  names the entitlement store and resolver access, revocation window, team budget behaviour,
  developers with no team, developer address and Claude Desktop sign-in beside the developer
  sign-in. The address question showed `https://<prefix>.azure-api.net`; the gateway is
  `apim-<prefix>`.
- **One plan had two fingerprints (P72).** `ConvertTo-Json` escapes `'`, `<`, `>` and `&` on
  Windows PowerShell 5.1 only, and `Sort-Object` compares by culture, so a plan reviewed on one shell
  was refused on the other. The flow writes its canonical text itself and sorts keys ordinally.
  The canonical text changed, so a fingerprint printed by an earlier release may no longer match its
  plan; when one is refused, run `-PlanOnly` again.
- **An unattended Change foundation lost what the installer recorded (P72).** The installer
  records Desktop sign-in as `external-idp` with a flow; the merge copied that as
  `desktopSignInKind`, a value `-DesktopSignInKind` refuses, and dropped the Desktop app, issuer,
  scopes, audience and token type, the tier groups and the budgets. The merge maps them back in the
  installer's parameter values, the flow passes `-DesktopBearerTokenType` and
  `-ResolverInboundAccess`, and the installer records its request ceiling as `requestsPerMinute`.
- **Every apply ran `git` (P72).** Without git on the machine, or outside a repository on Windows
  PowerShell 5.1, the apply stopped after writing `activeRun`. The release info now records no
  commit instead.
- **A refusal of the guided flow printed PowerShell's code excerpt (P72).** A top-level run prints
  the reason and exits 1; a cancel (the installer cancelled at its summary, a mistyped confirmation)
  prints in yellow. An error the flow does not expect says so and names
  `$env:CLAUDE_FLOW_DEBUG = '1'`, which prints where it stopped. Called from another script or
  dot-sourced, a refusal or a cancel is an exception and never exits the caller; before, a cancel ran
  `exit 1` there.
- **Guide with nothing recorded wrote placeholders, then failed its verification (P72).** It now
  refuses before planning. Over drift it names the differences instead of going on silently.
  Status with no decision record says that nothing is recorded, not "none detected".
- **Unattended, an external IdP Desktop sign-in without its app failed after approval (P72).** The
  plan now refuses, naming `foundation.desktopEntraClientId`.
- **Setup and Guide over a recorded gateway ran the installer again (P68).** The Foundation plan
  said `Check`, while its apply ran `Install-ClaudeGateway.ps1 -Yes`, whose reuse menu defaults to
  creating a new gateway; found by reading the code. Setup and Guide now check the recorded
  gateway; `-Change foundation` runs the installer with the new `-ExistingApimName`, which takes
  the installer's own reuse path for that gateway and keeps its region, tier, name and publisher.
- **The installer created a Claude deployment before its summary (P68 council).** With no Claude
  deployment in the subscription, it deployed the chosen model before asking "Create these
  resources?", so declining left a model behind, and `-WhatIf` created one. The summary now lists
  the deployment, and it is created first after the confirmation, never under `-WhatIf`.
- **A value with `&` reached `az.cmd` (P68 council).** The first P68 version of `-Change
  foundation` forwarded the live gateway's publisher email to the installer, which passes it to
  the Azure CLI; on Windows `cmd.exe` re-reads `& | < > ^ ( ) " %`, so an `&` in it ran a second
  command (reproduced with a stub). The flow no longer forwards it. It refuses a list where the
  installer takes one value, and a character `cmd.exe` re-reads in the values that reach `az`
  (the organisation details go in a JSON body and pass). The installer checks its bound
  parameters before its first `az` call that uses one, and the adopted and derived values before
  its summary.
- **A failed step after the installer did not resume (P68 council).** The retry planned the
  foundation check that the new gateway added, so the fingerprint changed and completed steps ran
  again. The run records its phase and steps, and a retry plans the same steps and resumes, when
  the steps present are the recorded ones; otherwise it plans every step again.
- **The flow could read the gateway in one subscription and install in another (P68 council).**
  Discovery honoured the record's `subscriptionId` and the installer was not given it. One
  resolver serves both, the id is passed and fingerprinted, and a name instead of an id is refused.
- **The Change review priced the recorded tier and region (P68 council),** not the live ones the
  installer keeps. It prices the live gateway, as already running.
- **A mistyped fingerprint after the installer said "nothing was written" (P68 council).** It says
  that the gateway foundation is set up and that the remaining steps were not applied.
- **Attended Change passed the recorded values (P68 council),** so the installer skipped the
  questions and the reuse menu the review named. It passes only the recorded gateway, and the
  installer asks the rest.
- **Setup stopped on the Cosmos entitlement store (P68).** Without a console the flow now passes
  `-DeployProjection` with the projection, which the installer requires under `-Yes`.
- **The installer's next steps were numbered 0, 0, 1, 2, 3, 4 (P68).** They are numbered in the
  order they print.
- **Windows PowerShell 5.1 listed only the Foundry region (P68).** `@(... | ConvertFrom-Json)`
  held the parsed region array as one element there; measured with the installer on 5.1.
- **FinOps monthly totals printed six decimals (P68).** Monthly totals show cents; unit rates keep
  the precision the price list publishes.

- **Claude Code returned `400 "thinking.type.enabled" is not supported` through the gateway.**
  Claude Code does not recognise a Foundry deployment name, so a release older than the model
  sent the older thinking request; measured with 2.1.101 for `claude-opus-5` and
  `claude-sonnet-5`. The workstation setups and the MDM profiles now declare
  `ANTHROPIC_DEFAULT_<ALIAS>_MODEL_SUPPORTED_CAPABILITIES` for each pinned model by family rule
  (Opus 4.7 and later, Sonnet, Fable and Mythos 5 and later), pin each alias to the newest
  recorded model in its family, run `claude update` when a recorded model needs a newer release,
  and end by asking Claude Code itself for a reply. The installer records each deployment's model
  in `claude-gateway.json`; `capabilities` and `claudeCode` on a deployment override the rule.
  2.1.101 with the new settings answered through the reference gateway by every model selection,
  and returned the 400 without them. ADR-0031.
- **Claude Desktop showed an empty Credential kind, and its Entra Sign in did nothing.** The
  Entra sign-in profile used `external-idp`, `inferenceIdpOidc` and `inferenceIdpAuthFlow`, which
  only Desktop 2.7032.0 and later read. The setups now write the spelling the Desktop that reads
  the profile knows: on Windows the older of the installed and running builds, because the
  per-user installer keeps an older `app-<version>` build running until it is restarted, as on
  the owner's workstation (2.9939.2 installed, 1.44121.2 running). The MDM generator writes the
  original spelling, which every release since 1.25927.0 reads, unless
  `-DesktopKeySpelling current`. ADR-0031, U27.
- **Diagnose waited for minutes on `claude doctor` and printed it unreadably.** Client commands
  now run with standard input closed, a time limit (45 s for `claude doctor`,
  `CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS`) and UTF-8 decoding. Diagnose also names an unfinished
  decision record instead of "Gateway URL not supplied", never prints an empty `--tenant`, checks
  Claude Code against the recorded models, checks the Desktop sign-in keys against the release
  that reads them, reports a running Desktop build older than the installed one, and shows
  Desktop's recent log errors.
- **On PowerShell 7 the workstation scripts ran npm's extensionless `claude`.** `Group-Object`
  sorts its groups on PowerShell 7, which put npm's POSIX script before `claude.cmd`, and Windows
  cannot start it. Every Claude Code on PATH is now listed one per folder, in PATH order, with
  the `.exe`, `.cmd`, `.bat` or `.ps1` chosen; a command that cannot start is reported, not
  thrown.
- **The macOS/Linux setup broke under a Windows `jq.exe`, and differed from the Windows setup.**
  Under WSL, `jq` can resolve to the Windows `jq.exe`, whose CRLF output left a carriage return
  in every value. Values are stripped now, and the setup pins the haiku alias to a recorded Haiku
  deployment, keeps the developer's own VS Code variables and honours `claudeCode` overrides, as
  the Windows setup does. The macOS/Linux diagnostics read the `Claude-3p` profile instead of
  Desktop's MCP file and gain the model check.
- **The Windows setup dropped the developer's own environment variables.** It replaced the whole
  `env` block of `~/.claude/settings.json` and the whole `claudeCode.environmentVariables` array
  in VS Code. It now changes only the variables it owns, and removes `ANTHROPIC_FOUNDRY_RESOURCE`.
- **On Windows PowerShell 5.1 the setup's gateway check never sent its request.** `Invoke-WebRequest`
  without `-UseBasicParsing` throws `Object reference not set to an instance of an object` on a
  machine without Internet Explorer, and hangs in a hidden window; measured on this workstation,
  the same POST returned 200 with the switch. The setup, the workstation diagnostics, the
  preflight, the onboarding wrapper's final check (`Debug-ClaudeCode.ps1`), the administrator
  diagnostics and `Show-Governance.ps1` now pass it. Found by the new end-to-end run of the
  Windows setup on both PowerShell hosts.
- **The setup could not read a record fetched over HTTP on Windows PowerShell 5.1.** The installer
  writes `claude-gateway.json` with `Set-Content -Encoding UTF8`, which on 5.1 starts the file with
  a UTF-8 byte-order mark; 5.1 left it in a `text/plain` body as three characters that
  `ConvertFrom-Json` refused, and the setup reported "No gateway configuration". The setup decodes
  the downloaded bytes as UTF-8 and drops the mark; bytes that are not UTF-8 are reported as an
  unreadable record rather than read with characters replaced. The bash scripts drop the mark too.
- **The onboarding email's command downloaded only `Setup-ClaudeWorkstation.ps1`.** The setup now
  needs `ClaudeClientSupport.ps1` and `ClaudeDesktopSignIn.ps1` beside it and stops at once,
  naming them, when they are missing; Desktop also needs its token helpers. The email's command
  fetches every file the setup reads from its own folder, taken from the script itself. The
  location is one single-quoted literal, escaped as PowerShell escapes it, curly quotes included,
  so a `$web` container, an `&` or an apostrophe in a path stays text; a file share or folder is
  resolved where the developer runs the command, so a relative path works, and copied with
  `Copy-Item`. The test runs the email's command as written, over HTTP from a path with `$web` and
  `&` in it and from a relative folder path with a space, `&`, `'` and `’`.
- **The MDM generator ignored a record with one deployment on Windows PowerShell 5.1, and pinned
  the haiku alias past an explicit `-SonnetModel`.** Assigning an `if` statement unrolled the
  one-element list, which has no `Count` there. With no Haiku deployment recorded, the haiku alias
  now follows the Sonnet choice, including one the administrator passed.
- **Diagnostics passed a capability declaration that breaks requests.** They compared a
  declaration with the record only when the installed release predated the model. Each pinned
  alias is now judged on what Claude Code was measured to send (ADR-0031): a declaration listing
  `thinking` without `adaptive_thinking` made 2.1.101 and 2.1.272 send `thinking.type.enabled`,
  and only 2.1.272 retried; with no declaration, 2.1.101 sent it for the name `claude-sonnet-5`
  but not for a custom name. Declarations compare as sets, in any order.
- **The macOS/Linux time limits could be outlived.** The watchdog used where `timeout(1)` is
  missing, as on stock macOS, sent only TERM to one process, and a child that outlived the command
  on TERM kept the captured output open. The command now runs in its own process group (from perl,
  `setsid` or GNU `timeout`); once the time is up TERM and then KILL 5 s later go to the group, and
  once the command has exited, on time or not, anything it left running in its group is ended too.
  Signals go through the group, whose ID cannot be reused while a member lives, and the watchdog
  stops as soon as the command is reaped, so no reused PID is signalled. The bash model rules and
  this helper moved into `scripts/claude-client-support.sh`, which both bash scripts source; its
  alias check also counts a name in an older record's `models` list as recorded, as the
  PowerShell diagnostics do.
- **The AUM service guide did not say its analytics read the whole workspace.** A warning written
  on the `aum-service` branch on 2026-09-25 never reached `main`: the service's usage reads,
  observed-person lookup and warnings call the saved `ClaudeChargeback` and `ClaudeCost` functions
  without filtering by gateway, so in a Log Analytics workspace shared by several gateways they mix
  those gateways' data. `docs/AUM-SERVICE.md` and ADR-0023 now say so, and name the exception
  checked on 2026-09-27: the dollar-budget reconciler keeps only its own gateway's rows.
- **Update planned a false change on every current gateway.** Live discovery read named values
  as `properties.value`, but `az apim nv list` returns flattened objects, so every value read as
  empty and migration 0002 always proposed "whitespace/empty -> disabled URI sentinel" for the
  Desktop audience. It reads either shape now and leaves secret values out. Measured 2026-09-27:
  on a gateway installed by the current release, all three migrations now report no change.
- **`Sync-ClaudeAccess.ps1` published the tenant's default groups to a gateway installed with
  other group names.** It and `Compare-ClaudeEntitlement.ps1` defaulted to `claude-code-standard`
  and `claude-code-premium`, and the installer's closing instructions run the sync without group
  names. Measured 2026-09-27: on a gateway installed with `claude-p66i09270024-*` groups (0
  members), the health check reported "drift: missing=7", the 7 members of the default groups.
  An earlier guided-flow proof's 200 came through the same default groups. Both scripts now take
  the groups recorded for that gateway in `onboarding/claude-gateway.json` (only when the record
  names the same API Management instance), then the defaults. `Test-TierGroupTarget.ps1` holds it.
- **The health check stopped at the bypass check when Foundry is in another resource group.**
  The installer accepts `-FoundryResourceGroup`, but `Get-ClaudeBypass.ps1` looked for the
  account in the gateway's group and threw, and `Test-ClaudeHealth.ps1` let the throw end the run,
  so every later check went unreported and the guided Verify step recorded only a warning. Both
  take `-FoundryResourceGroup` now, a throwing sub-check is recorded as a failed check, and the
  guided flow and `Debug-ClaudeSetup.ps1` pass the recorded Foundry account and group.
  `Debug-ClaudeSetup.ps1` waits `-HealthTimeoutSeconds` (300 by default) for the health check,
  which measured 182-201 s against a shared Foundry account; it had waited 90 s.
- **The guided Verify step passed when the health check failed.** It checked only that a health
  run was recorded. It now also requires the health check to pass, and names the command to see
  and fix each failing check.
- **`Start-ClaudeGateway.ps1 -Action Diagnose -SupportBundle` wrote `True.zip`.** The flow passed
  the switch value to scripts that take a zip path. Each script now gets its own path under the
  git-ignored `onboarding\support\` folder.
- **`Start-ClaudeGateway.ps1 -Action Update` could only plan.** It called the updater without
  `-Apply` or the fingerprint, so an older gateway could be reviewed through the flow but had to
  be updated with `scripts\Update-ClaudeGateway.ps1` directly. `-ApprovedPlanFingerprint` now
  applies the reviewed update plan, `-PlanOnly` never applies, and the plan output names the
  command that applies it.
- **A guided-setup approval did not bind the estate it would create.** The Foundation review
  said "Create API Management governed Claude gateway - BasicV2" for every target, so two setups
  aimed at different resource groups printed the same fingerprint, and an approval for one was
  accepted for the other. The review now names the resource group, gateway, region, Foundry
  account and subscription, the plan carries every installer input, and the Basic v2 line is
  priced from the Azure Retail Prices API ($150.00/month in eastus2, measured 2026-09-27). Found
  on the first integrated run: the fingerprint matched the one from a run a day earlier against
  a different resource group.
- **Helpers defined by a guided-flow module were gone by the time the plan ran.** The
  orchestrator dot-sourced each module inside a function, so a module's own helper functions
  ended with that function and only `global:` helpers survived. It now keeps each module's new
  helpers at script scope, as ADR-0030's one-session contract says; `Test-GuidedFlow.ps1` runs
  the shipped modules through the orchestrator to hold it.
- **Setup reported present modules as absent.** Tier, Entitlement, Network and Desktop sign-in
  run under `-Action Change`, and Setup printed "Skipped absent step ... not present on this
  branch" for each. Setup now lists them with the command that changes them, for example
  `.\Start-ClaudeGateway.ps1 -Action Change -Change sku`, and reserves "absent" for missing files.
- **An unreachable price API was reported as a missing meter.** The lifecycle price helper now
  says the Azure Retail Prices API could not be reached, and to rerun the plan.
- **The Intune detection script in the MDM guide failed under Windows PowerShell 5.1.** It hashed
  the policy with `SHA256.HashData` and `Convert.ToHexString`, which 5.1 does not have, so a
  remediation would always report drift. It uses `ComputeHash` now, and `Test-DocReferences.ps1`
  runs the block under `powershell.exe`.
- **A half-resolved merge could commit conflict markers unnoticed.** A branch committed
  `<<<<<<< HEAD` into this file and its gate passed; `Test-ReleaseLog.ps1` now refuses conflict
  markers in the changelog and in every tracked text file.
- **Removing a developer could switch off the empty-list guard for both tiers.** Caught in review
  before merge (P64); the removal now allows an empty list only for a tier it is proven to empty.
- **The first reviewed network edge deployment refused a VNet that did not exist yet.**
  `New-ClaudeNetworkEdge.ps1` read the owned VNet before creating it; the lookup returned
  nothing, and the extra-subnet guard counted that empty result as an unknown subnet, so a fresh
  install stopped with "The owned VNet has additional subnets". The guard now runs only when the
  VNet exists. Found by P54's isolated live estate on 2026-09-25; the regression test runs the
  script's own deployment block offline for an absent VNet, the owned four-subnet layout, and an
  extra subnet (still refused, with no deployment) on PowerShell 7 and 5.1.
- **Four gaps a review found in the new capture redaction.** A tenant-name pair could turn a
  colleague's address into one on the placeholder domain, which the address rule then kept:
  addresses are now replaced before any pair. A real value that started inside a replacement and
  ran past it was hidden by the shadowing rule: only a match wholly inside a replacement is now
  ignored. An application's assigned principals were read from Graph's first page only: every
  page is read, and a list that never ends is refused. And every record named a commit that did
  not contain the code that took it: the runner now refuses to capture from uncommitted capture
  code and records each step's hash; the existing records are marked `accel_dirty` with a
  provenance note.
- **A deployment suffix inside a longer name escaped redaction, and people on directory pages
  were not redacted at all.** The capture redactor matched private values only at word
  boundaries, so a mapped suffix inside a name built from it (a report storage account shown as
  an environment variable on the admin job's blade) survived, and the leak check, using the same
  rule, passed it. A value of 8 or more characters, or a 6+ character mix of letters and digits,
  is now replaced and checked wherever it occurs; a replacement that happens to contain another
  private value is not itself a leak. Separately, a group's Members blade showed colleagues' real
  names, which no private map lists: Entra group and application pages now read the page's own
  members or assigned principals at discovery, show them as `Contoso user N`, hide their initials,
  and refuse to capture when none were discovered (`redaction.people`). Both were found by
  reviewing uncommitted batch images; neither reached a commit. Every portal image was then
  recaptured under the new rules.
- **Portal batch steps failed on blades that had rendered.** The runner took the first DOM match
  for a label, and the portal keeps hidden copies of many (collapsed menus, tooltips, other
  blades); it now takes the first visible match, and a timeout names the locator. Spec fixes found
  by replaying each failure: jobs reach execution history through the overview's `View` link;
  the gateway's APIs item is addressed inside the menu; Log Analytics Functions need KQL mode;
  top-level waits sit on the landing blade; deep links that no longer render became menu clicks.
  The Azure portal has no deployments blade for a Foundry resource, so that picture is a live CLI
  read instead. `docs/guide/portal-captures.json` records every capture, and the tests now fail if
  a published image differs from its record.
- **Scripts refuse governance writes that Turnstile would overwrite.**
  `Set-ClaudeBusinessUnit.ps1` and `Set-ClaudeTier.ps1` check the recorded authority
  before writing, name the Turnstile page to use, and explain the explicit
  `Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Gateway -BudgetAuthority Gateway`
  switch. Budget-only authority blocks monthly unit/team budget edits, not structure,
  modes or tiers. Failed authority reads stop writes; a genuinely absent or explicitly
  disconnected integration leaves the gateway in charge. Lists, personal daily
  overrides and Entra membership edits remain available. The same tests on PowerShell
  5.1 exposed and fixed singleton registry rendering when removing one of two units.
- **A root unit in allowance or notify mode got HTTP 500.** The gateway's budget trace sent an
  empty `ParentUnit` (a unit has no parent) or `Notice` (no advisory yet), and APIM rejects empty
  trace metadata: "The value field is required". Absent values are now `none`, and a test
  compiles and runs the policy's actual expressions. Found live by the AUM service's enforcement
  journey; the reference gateway, all strict, could not reach it.
- **The resolver check could fail with every test passing, and three runner gaps.** Under a
  headless console on code page 437, Node's Unicode summary line did not match the wrapper's
  pattern, so it counted zero passes; `tests/Test-Resolver.ps1` now asks for ASCII TAP output and
  reads its exact pass and fail counters. A registered script that was missing behind a
  prerequisite SKIP was reported as skipped, not failed; a check stopped at its deadline lost the
  output it had printed; and a check started late could have outlived the gate's budget. Each was
  reproduced by a failing test first.

- **`Test-All.ps1` reported success for checks that never ran.** A terminating error inside a
  check travels up to the nearest `try`, and every check ran inside one `try`/`finally` with no
  `catch`. So when `Test-On-PS51.ps1` found its fixed temp file `wiz51-answers.txt` locked by a
  second run on the same machine, the rest of the run was skipped and the summary still printed
  "All checks passed." with exit code 0: a packet gate passed in 57 seconds on 9 of 32 checks. It
  was caught before anything was pushed. Each check now records FAIL and the run continues; a run
  that stops early fails; a registered check whose script is missing fails instead of being
  skipped; and both wizard tests use one temp file per run. `tests/Test-RunnerIntegrity.ps1`
  reproduces the false pass on a copy of the runner, and two mutations prove its assertions catch
  it. The only trigger found was the wizard's fixed temp file; earlier gate receipts ran for 20 to
  30 minutes, and a run cut short at the wizard check takes about one.

- **The in-network projection writer reported success when writes failed.**
  `sync/src/apply-projection.mjs` printed `ok: true` even when upserts or deletes had failed,
  though it exited 3. It now reports the outcome. Found by a review of the 500,000-developer
  design, whose other findings are recorded, checked against the code, in `docs/STATUS.md`: the
  resolver accepts a record of any age, it is called before any limiter, and
  `Sync-ClaudeProjection.ps1` reads only the first page of existing records.

- **Re-running the installer reset the revocation window to an hour.** That is
  how long a removed developer keeps working. The wizard's answer, 60 minutes
  by default and the only answer under `-Yes`, always won over the value it had
  just read back, so three consecutive re-runs each deployed
  `entitlementCacheSeconds=3600` whatever the gateway had. Found because a
  1-second window stayed an hour: the installer's own verification cached an
  entry for 3,600 seconds. A gateway that already has a window now keeps it,
  and the wizard says so. The lookup goes through `Invoke-AzOptional`: on
  Windows PowerShell 5.1 an az call for a gateway that does not exist yet
  raised `NativeCommandError` under `2>$null`, and `ErrorActionPreference Stop`
  ended the wizard before its summary. The same helper now guards the two
  existing-gateway checks on the deploy path, which had the same exposure on
  5.1 for every new gateway.

- **The installer stopped at the entitlement sync on every run, after
  deploying the gateway.** Introduced earlier the same day, by the fix that made
  the confirmation screen price the chosen SKU: that fix dot-sourced
  `AzureRetailPrice.ps1`, which ran `Set-StrictMode -Version Latest` at top
  level. Strict mode then reached `Sync-ClaudeAccess.ps1`, where reading
  `'@odata.nextLink'` on the last Graph page threw
  (`The property '@odata.nextLink' cannot be found on this object`). The
  library now sets strict mode inside each function only, and both Graph pagers
  read the link in a way strict mode tolerates. Checks run the library in a
  fresh shell and the real paging function under strict mode, and fail any
  dot-sourced library that sets strict mode for its caller. A full re-run
  against the Premium v2 gateway then finished with exit code 0.

- **An identity with no projection record got 503, "this is not a problem with
  your access", and `Retry-After: 5`.** The policy handled only the resolver's
  200, so its 404 fell through to the branch for an unreachable resolver. Every
  unentitled attempt read as an outage, invited a retry and went uncached.
  Measured before and after on a live gateway: it is now `403 permission_error`,
  cached for at most 60 seconds (the second call took 567 ms). A resolver that
  does not answer still gets 503 until the positive cache runs out. Measured:
  served for 120 seconds with the resolver stopped, then 503.

- **The two syncs charged nested teams to different business units.**
  `Sync-ClaudeAccess.ps1` writes `bu-members` deepest first, with the first
  match winning. `Sync-ClaudeProjection.ps1` applied units in the order given,
  with the last match winning. Anyone in a team and its parent would have moved
  unit at the flip, with no entitlement difference to show for it. The
  projection now reads the registry and parents from the gateway and applies
  the same rule.

- **`Sort-ClaudeBuByDepth` did not keep registry order, although it said it
  did.** `Sort-Object` is not stable. Sorting 2,000 items on a three-valued key
  reordered equal items 960 times in PowerShell 7.6 and 1,011 times in 5.1, and
  a five-unit registry came back in a different order in 5.1. So ADR-0007's
  "first match in registry order" depended on the shell that ran the sync.
  Registry position is now an explicit second key.

- **Re-running the installer would have removed a gateway's VNet integration.**
  `main.bicep` writes the service whenever it created it, and stated only the
  publisher. An ARM what-if against the Premium v2 gateway predicted
  `virtualNetworkType` External -> None, the subnet deleted,
  `publicNetworkAccess` and `customProperties` removed, and both portals
  switched on. Every request to a private deployment would then fail. The
  installer now reads that state over ARM and hands it back, and refuses to
  redeploy a gateway it cannot read. With it, the same what-if predicts none of
  those changes.

- **The Deploy to Azure button deployed the first commit's gateway.**
  `infra/azuredeploy.json` had not been rebuilt since, so it lacked the
  entitlement switch, business units and everything else added since. It is
  rebuilt, and a check compiles `main.bicep` and compares.

- **The projection's cost was understated.** It priced one private endpoint and
  no warm instance: $11.11 a month at 500,000 developers. As deployed, it is
  $69.09, of which $65.28 bills at rest: five endpoints, five DNS zones, and one
  warm resolver instance.

- **U15 had wrongly ruled out Azure Policy.** The control is
  `CosmosDB_PublicNetwork_Modify` in a management-group initiative that
  `az policy assignment list` did not show. The resource's activity log named
  it. The same initiative made the resolver's storage private.

- **The migration runbook described a path that could not be run.** It said
  Basic v2 cannot use the projection (a public resolver works), stood it up
  with one template out of three, had no command to populate it, and compared
  the wrong things. Each step now matches what was run.

- **The installer's own verification reported a healthy new gateway as failed,
  and priced every gateway as Basic v2.** Found by a Premium v2 install in
  canadacentral on 2026-09-23.

  `Show-Governance.ps1` asked for a fixed `claude-sonnet-5`. The new account
  deployed only `claude-haiku-4-5`, so the gateway answered `403
  model_not_allowed`, and the check printed `[FAIL]` with an empty tier. It
  queried a fixed `appi-claude-gateway` component, which did not exist (`404`).
  On the reference gateway that name belonged to the service-level diagnostic's
  component, which held 0 tokens over 7 days while the Claude API's own
  component held 168,438. So the chargeback check there had always reported "no
  metrics yet". The model now comes from the caller's tier list, or from a Claude
  deployment on the account when the tier is unrestricted. The component comes
  from the Claude API's `applicationinsights` diagnostic, falling back to the
  service-level one. A failed check prints the gateway's error code.

  The confirmation screen said "BasicV2 is about $150/month" whatever was chosen.
  The Premium v2 run was approved against it at $2,800/month. It now reads the
  chosen SKU's price in the chosen region from the Azure retail prices API, and
  says so when it cannot. The "30-45 minutes" estimate is gone: the whole
  Premium v2 install took 5 minutes 23 seconds. The closing instructions printed
  `1. Entitle a developer Write-Host ./scripts/...` because two statements
  shared a line. A check across every script now refuses that.

- **The installer could not deploy a Claude model, and the model it would have
  deployed was the wrong one.** Both defects were found by deploying into a new
  Foundry account on 2026-09-23.

  Azure now refuses an Anthropic deployment without
  `properties.modelProviderData` (organisation name, industry, two-letter
  country code) and answers `InvalidModelProviderData`.
  `az cognitiveservices account deployment create` has no parameter for it, so
  every deployment the installer attempted failed. `New-ClaudeDeployment` now
  sends an Azure Resource Manager `PUT` at api-version `2025-12-01`, carrying the
  data. It copies the data from an existing Claude deployment in the subscription
  when there is one. Otherwise it stops and names the three fields before
  touching Azure. It then waits for provisioning to reach `Succeeded`, `Failed`
  or `Canceled` instead of returning at `Creating`. The installer asks for the
  values only when none can be copied, and `-ModelOrganizationName`,
  `-ModelIndustry` and `-ModelCountryCode` supply them unattended.

  The picker chose the highest version string. `claude-haiku-4-5` is listed as
  version `2` (hosted on Azure, `isDefaultVersion` true) and as `20251001`
  (hosted on Anthropic), and `'20251001'` sorts above `'2'`, so the picker
  offered the Anthropic-hosted version. It now picks the version Azure marks as
  default, then an Azure-hosted one, then the highest. The menu shows where each
  version is hosted. The fixed path deployed `claude-haiku-4-5` version `2` in
  66 seconds. `tests/Test-ModelDeployment.ps1` runs the real selection and
  refusal code against that catalogue shape through a stand-in `az`, and six
  mutations restore the old behaviour.

- **A correctly configured Claude Desktop that would not open passed every
  check.** All the Desktop checks read files, so a configuration that was right
  everywhere reported healthy while the app did nothing when launched.

  The cause was named wrongly first. `0x80070020` creating the app container
  looked like a container fault needing a reboot; the deployment log actually
  says `Error while deleting file ...UserClasses.dat. Error Code : 0x20`, and
  `0x20` is `ERROR_SHARING_VIOLATION`. The package's own registry hives are
  held open. `scripts/Get-FileLockOwner.ps1` — Restart Manager, so no
  Sysinternals download and no elevation — attributes the handles to `System`
  (pid 4) and `Registry` (pid 276): the kernel has the hive loaded. It sits in
  the AppX app-hive namespace rather than under `HKEY_USERS`, so `reg unload`
  cannot reach it, and **reinstalling does not help because the lock outlives
  the package**. Signing out or restarting is the only remedy.

  `Test-FoundryDirect.ps1` now detects it without launching anything: a lock on
  those hives while no Claude process is running is the signature.

- **The gateway price was overstated by 67%.** Quoted as ~$250/month in eight
  places; the measured list price is **$150.00** — `Basic v2 Unit` at
  $0.20548/hour over 730 hours, identical in eastus, eastus2 and westeurope.
  `COMPARISON.md` used the figure to advise small teams the gateway was not
  worth it, so the error changed a recommendation.

- **The documented credential pin was a value the client rejects.**
  `AZURE_TOKEN_CREDENTIALS=AzureCliCredential` is refused by Claude Code with
  `Valid values are 'prod' or 'dev'` — the client validates it before
  `@azure/identity` sees it, whatever the library supports. `-Fix` applied that
  value, so running the repair broke a working machine. It is now `dev`.
  `prod` is not an alternative: it excludes the developer credentials, which is
  the sign-in being selected.

  This matters more than it looks. On a Cloud PC, a Dev Box or any Azure VM the
  instance metadata service answers — measured at 10 ms on a Windows 365 Cloud
  PC — so a managed identity is found ahead of the developer's `az login` every
  time. The pin is the default case there, not an edge case.

- **The network check reported the wrong path as healthy.** An explicitly
  supplied empty argument was indistinguishable from an omitted one, so the
  configuration refilled it and the round trip tested the gateway while the
  report named a resource. Detected through `PSBoundParameters` now, and the
  path tested is always printed.

- `SCALE.md` headlined the wrong ceiling. It said *"the binding limit is 110
  developers per tier"* while its own table already gave the business-unit map as
  about 93. A `bu-members` entry is `oid=unit,` — 38 characters plus the unit
  name, against 37 for a bare object id — so business-unit membership runs out
  first, and planning against 110 over-plans by roughly a fifth. Measured on the
  live gateway: 38 characters per entry on the tier lists, 44 on `bu-members`.

- `SCALE.md` now records why the tier cannot be carried in the token. Putting it
  in an Entra app role or the `groups` claim would remove the lookup entirely,
  which is the first alternative anyone proposes for P19. It cannot work: the
  policy validates the audience `https://cognitiveservices.azure.com`, a
  first-party Microsoft resource, and both are configured on the application
  registration the token is issued for — which nobody here owns.

- The README never said how many developers the accelerator actually holds. A
  reader had to reach `docs/SCALE.md` to find out, and the 500,000 figure the
  design discusses reads as a capability when it is a target. It now states the
  measured ceiling — about 90, business-unit membership first — and that the
  projection which lifts it is designed and costed but **not built**.

- `New-ClaudeCodePolicy.ps1` built a Claude Desktop settings block and then
  discarded it. Its own comment said the keys were "emitted here so one run
  produces one tier's complete profile rather than two half-profiles that can
  drift", and nothing ever wrote them, so every Desktop tab setting the script
  has accepted since it was written reached no machine. It now writes
  `claude-desktop.managed-settings.json` and `claude-desktop.reg`.

  The registry form follows the documented encoding: every value is a string,
  including booleans; arrays and objects are a JSON document encoded into one
  string; values sit directly under `HKLM\SOFTWARE\Policies\Claude` because the
  app reads no subkeys; and the file is UTF-16.

- A one-element marketplace list was written as an object rather than an array.
  `allowedPluginMarketplaces` is `object[]`, and piping a one-element array to
  `ConvertTo-Json` unwraps it, so a single allowed marketplace produced `{...}`
  instead of `[{...}]`. Fixed with `-InputObject`.

- `SETUP.md` Options B and C did not say what they leave undone. `deploy.ps1`
  creates the Entra groups and runs the sync, but only `Install-ClaudeGateway.ps1`
  writes `onboarding/claude-gateway.json`, which is the file the developer setup
  script reads — it is the single writer in the repository. The portal button
  deploys the template alone. Both routes now list the remaining commands.

- Two verification sections put the rationale before the command. `SETUP.md` 4.1
  and 4.2 now open with the command. 4.2 also named its controls as "entitlement,
  both budgets, the organisation ceiling and the model allowlist"; "both budgets"
  had no referent on that page.

- Six pages under `docs/` were not linked from the README, including
  `BUSINESS-UNITS.md`, which is a whole feature area. The documentation index
  now carries every guide, a reading order for chargeback and for scale, and the
  project's working record — charter, roadmap, status, unknowns and the decision
  records — which were reachable only by knowing they existed.

  A check derives the list from the directory rather than a written-out set, so
  a new page under `docs/` either gets linked or fails the run. Negative-tested:
  an unlinked page fails with its own name in the output.

  The repository layout listing was also stale — it showed 5 of the 17 scripts
  in `scripts/` and 8 of the 16 pages in `docs/`.

- The roadmap listed P24 twice, once ticked in the delivered section and once
  open in the planned section. The gate counts those markers, so the open
  duplicate was reported as outstanding work that had shipped.

- Two documented claims about revocation were wrong.

  `ONBOARDING.md` showed revocation as `az ad group member remove` against
  `claude-code-standard` only, while its own checklist said "removed from both
  groups". A premium developer, or one in both tiers, kept access. The step is
  now `Set-ClaudeDeveloper.ps1 -Remove -Sync`, which clears both tier groups and
  every business-unit group.

  The same section said a departing employee's access "is revoked at that moment,
  ahead of any sync" once their Entra account is disabled. Disabling an account
  stops new tokens being issued; it does not invalidate one already issued. The
  gateway checks the signature and claims with `validate-jwt` and does not call
  Entra per request, so a token obtained shortly before the account was disabled
  keeps working until it expires. The guide now says to remove membership and
  sync as well.

- `BUSINESS-UNITS.md` said changing a team's tier was "one membership edit in
  Entra" and that "nothing in the gateway changes". It is two edits, and the
  gateway's entitlement lists do change — when `Sync-ClaudeAccess.ps1` next runs.
  That sync is not automatic; this accelerator ships it as a script to schedule,
  so until it runs the old tier still applies.

- `BUSINESS-UNITS.md` described a user's Groups blade as showing "two rows, one
  per axis", and said a missing row was the fault. The blade lists direct
  memberships. Measured on two accounts: one shows its team and its tier, because
  that tier was assigned directly; the other shows only its team, and resolves to
  the same tier and business unit transitively. The business unit never appears
  there. The guide now gives `az ad user get-member-groups`, verified to return
  the full transitive set.

- A service principal in a tier group was never entitled, so adding one was a
  silent no-op and the gateway returned 403 for an identity the portal listed as
  a member. `Sync-ClaudeAccess.ps1` read membership through
  `transitiveMembers/microsoft.graph.user`, which by construction excludes
  workload identities. Measured against `claude-code-premium`, which holds one
  nested team and one service principal:

  | Request | Returned |
  |---|---|
  | `transitiveMembers` | 3 — service principal missing |
  | `transitiveMembers/microsoft.graph.user` | 2 |
  | `transitiveMembers/microsoft.graph.servicePrincipal` | 0 — missing |
  | the same, plus `ConsistencyLevel: eventual` | 0 — missing |
  | the same, plus `$count=true` | 0 — missing |
  | the same, plus **both** | 1 — found |

  A service principal is returned only when the header and `$count` are both
  present. With one or neither Graph answers 200 with an empty collection rather
  than an error, so the sync read "no service principals" and wrote an
  entitlement list without them. The sync now issues both casts with both set.
  On the reference gateway the premium tier went from 2 members to 3 and the
  total from 7 authorised identities to 8. A service principal in no business
  unit is attributed to `unassigned`, which the same run reported rising from 2
  to 3.

- A redeploy would have wiped every business unit, team and membership.
  `Install-ClaudeGateway.ps1` reads `allow-standard`, `allow-premium` and
  `quota-overrides` off the gateway and hands them back so a redeploy cannot
  revoke anyone, but `bu-registry`, `bu-members` and `bu-parents` were never
  added to that list. Their template parameters default to `,,`, so omitting
  them does not preserve them — it clears them. Confirmed against the live
  gateway with `what-if`: with the parameters omitted, all three were planned as
  `,,`; with them supplied, each `after` matched the current value. Every
  existing "a redeploy preserves X" check asserted only the Bicep expression and
  never that the installer supplied the value, which is why this passed for
  three releases — the tests now assert both ends.
- Entitlement could have been granted to a group object. Graph
  `transitiveMembers` returns nested **group** objects as well as users, and
  `Get-GroupMemberOids` did not filter by type. Measured on
  `claude-code-standard` with one team nested inside it: seven objects returned,
  two of them `#microsoft.graph.group`. Those object ids would have been written
  into the entitlement list and the membership map, spending a 4,096-character
  budget that holds about 110 ids, and inflating the count of developers mapped.
  Now uses the typed cast `/transitiveMembers/microsoft.graph.user`, which
  filters server-side — measured five users and no groups. Filtering on
  `@odata.type` in the client would not have worked, because Graph omits that
  property under a cast. The defect predates teams and was unreachable only
  because nothing was nested.
- `Set-ClaudeBudget.ps1 -List` crashed. `{n,>14}` is not valid .NET format
  syntax — the alignment sign belongs on the number, `{n,-14}` or `{n,14}`. It
  parses at read time and throws only when the line runs, so it shipped in
  v1.4.0 and was found by the new format-string check. Two other files carried
  the same mistake.
- `tests/Test-Discovery.ps1` printed `FAIL` and then fell off the end without
  setting an exit code, so `Test-All.ps1` recorded whatever the last child
  process had left behind — including `PASS` for a failed run.
- `tests/Test-PreflightBothHosts.ps1` never checked its own result. It now
  requires each host to print `RESULT=True` or `RESULT=False`; matching the bare
  `RESULT=` label was not enough, because a failed dot-source is a
  non-terminating error and the child carried on to print an empty value.

## [1.5.0] - 2026-09-15

The foundation for business-unit chargeback. Three independent limits were
measured that together made the accelerator a roughly 100-developer system, which
is below the scale at which chargeback is a question worth asking.

### Added

- Chargeback ledger: `analytics/chargeback-ledger.kql`, one row per request with
  the caller attached. Built on the API Management LLM log rather than custom
  metrics, because Microsoft caps a metric dimension at 100 unique values and
  then, in its words, "silently discard[s]" the rest — one dimension per
  developer reaches that at about a hundred people. The log is also the only
  APIM-native source correct for streamed requests: measured 2026-09-15, a
  streamed call reported 11 tokens through the quota scalar where the completion
  was 41. Identity is joined on `context.RequestId`, carried deliberately because
  the log's `CorrelationId` is a GUID and Application Insights `operation_Id` is
  a W3C trace id. Message capture stays off. ADR-0006.
- `scripts/ApimNamedValue.ps1`: writes a named value, refuses an oversized one
  before the call, and throws on a failed one.
- ADR-0005: identity resolution becomes a durable projection synced from Graph
  off the request path, rather than a directory call on a cache miss. Reverses a
  design proposed and rejected the same day.
- ADR-0006: why the ledger is the built-in LLM log, and the four sources it was
  chosen from.
- U9 to U12 in `docs/UNKNOWNS.md`: counter-key cardinality at scale, Graph load
  on a cold cache, ledger ingestion cost against the Basic-Logs purge conflict,
  and cache accounting. U12 is closed below.

### Fixed

- Named value writes fail loudly instead of silently. Every write used
  `az apim nv update ... -o none 2>$null` with no exit check, and named values
  cap at 4,096 characters — measured: 4,096 returns HTTP 201, 8,192 returns HTTP
  400. An object id plus separator is 37 characters, so a tier holds about 110
  developers. Past that the write failed, the error was discarded, and
  `Sync-ClaudeAccess.ps1` reported a successful sync while entitlement silently
  stopped updating. `Show-Governance.ps1` was worse: it lowers `tpm-standard` to
  100 to demonstrate throttling, and a failed restore left the standard tier
  capped at 100 tokens per minute. The restore now runs in a `finally`.

### Changed

- **Behaviour change.** `Sync-ClaudeAccess.ps1` now throws where it previously
  continued. A sync that outgrows the 4,096-character limit fails instead of
  reporting success, so automation that treated a zero exit code as "entitlement
  is current" will now see the failure it was missing.

### Known limitation

- The per-user token budget does not count cache tokens. Measured 2026-09-15:
  two identical calls with a cacheable 10,000-token prompt wrote and then read
  10,003 cache tokens, and both metered 16. This is documented API Management
  behaviour — the `llm-token-limit` policy "currently counts prompt and
  completion tokens only" — but against thirty days of live usage, weighted at
  Claude's published rates where output is 5x base input and a cache read is
  0.1x, **38.7% of the real cost weight is invisible to the budget**. The ledger
  records what the budget cannot see. Correcting the budget itself is M4 work.

## [1.4.0] - 2026-09-03

Claude Enterprise parity: analytics, spend control, capability scoping and
compliance retrieval.

### Added

- `analytics/claude-code-daily.kql` and `scripts/Get-ClaudeAnalytics.ps1`: Claude
  Code usage in the shape of the Claude Code Analytics API, built from the
  gateway's own telemetry. Anthropic's API does not cover Foundry — "Usage
  through ... Claude in Microsoft Foundry ... is not included"
  ([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
  retrieved 2026-09-02) — so after a migration this is the only source of those
  numbers.
- Organisation-wide monthly spend ceiling: `quota-org`, enforced in the request
  path on a constant counter-key and checked before the per-tier budgets. A soft
  cap; the policy reference states high-concurrency requests can temporarily
  exceed the configured limit.
- The gateway says which budget ran out. Both refusals are `403` with the same
  `LastError.Reason`, and `403` is also what the entitlement check returns, so a
  developer out of budget previously read it as losing access. The reply carries
  `"budget": "organisation"` or `"budget": "personal"`.
- Per-developer daily budget overrides: `scripts/Set-ClaudeBudget.ps1` sets and
  clears them, `scripts/Get-ClaudeBudget.ps1` reports effective limits and spend
  to date. Measured: `token-quota` accepts a policy expression but it must return
  `long`; `Int32` and `string` are both rejected at deploy time.
- Model allowlist per tier: `models-standard` and `models-premium`, enforced
  before the request reaches Foundry. Sentinel commas make the match exact, so
  `claude-opus-5` does not admit `claude-opus-5-mini`.
- `New-ClaudeCodePolicy.ps1 -Tier standard|premium` generates one managed-settings
  profile per entitlement tier.
- Data subject request tooling: `scripts/Find-ClaudeUserData.ps1` reports what the
  telemetry holds about one person and what is actually deletable;
  `scripts/Remove-ClaudeUserData.ps1` purges it and does nothing without
  `-Execute`. Both print the limits — 50 purge requests an hour, a 30-day
  completion SLA with no expedite, Analytics-plan tables only.
- `scripts/Get-ClaudeBypass.ps1`: who can reach Foundry without passing through
  the gateway. It derives the roles granting data-plane access from their
  `dataActions` rather than matching a name, and includes inherited assignments.
  On the reference deployment the documented one-role hand check reported clean
  while 11 assignments could call Foundry directly — three through `Foundry
  User`, which grants the same `Microsoft.CognitiveServices/*` as `Cognitive
  Services User`.
- `scripts/Get-ClaudeTelemetry.ps1`: which Application Insights the gateway is
  actually writing to, resolved from its diagnostic rather than a name.
- ADR-0002 (analytics from two sources), ADR-0003 (telemetry located from the
  gateway), ADR-0004 (policy delivered out of band).

### Fixed

- Usage reports read the Application Insights the gateway is currently writing
  to, instead of a workspace named by convention. The reference deployment moved
  workspaces on 2026-08-31 and nothing noticed: every analytics assertion still
  passed on data that had stopped two days earlier, and `Get-ClaudeBudget.ps1`
  reported `0 used this month` on a gateway that had served hundreds of requests
  that morning. ADR-0003.

## [1.3.0] - 2026-09-02

### Added

- Ironclad engineering discipline: `.ironclad/charter.json`, a vendored
  `gate.mjs`, and the `docs/` ledger — CHARTER, ROADMAP, STATUS, UNKNOWNS and
  ADRs. See ADR-0001.
- `docs/ROADMAP.md` with a parity matrix against Claude Enterprise.
- `docs/UNKNOWNS.md`, so what is not known is written down before it is built on.
- `DEVELOPER.md`: the developer's setup on one page, with a router at the top of
  the README.
- Client screenshots for the CLI, VS Code and Claude Desktop, redacted by
  `guide/redact-clients.mjs` and `guide/redact-terminal.mjs`.

### Changed

- Tests moved from `scripts/` to `tests/`. `Test-Prerequisites.ps1` and
  `Test-FoundryDirect.ps1` stayed, being runtime tooling rather than tests.
  See ADR-0001.
- Documentation states what is true and cites a source, rather than telling the
  reader what matters.

## [1.2.0] - 2026-08-31

Robustness on Windows, and the first migration tooling.

### Added

- `Import-ClaudeEntitlement.ps1`: bulk entitlement from a CSV or an Entra group,
  resolving identifiers four ways because a directory holds a person under
  several addresses.
- `Import-ClaudeMemory.ps1`: lands memory exported from claude.ai into
  `CLAUDE.md`.
- `New-ClaudeCodePolicy.ps1`: managed settings for Claude Code as JSON, `.reg`,
  Intune OMA-URI and `.mobileconfig`.
- `docs/MIGRATION.md`, covering what transfers from Claude Enterprise and what
  does not.
- `tests/Test-AzArguments.ps1`: fails on any `az` argument `cmd.exe` would
  re-parse.
- A project banner, and `.gitattributes` pinning line endings so shell scripts
  survive a Windows contributor.

### Changed

- The installer reuses an existing v2 API Management instance instead of always
  creating one.

### Fixed

- `az --query` mangled on Windows, because `az` is a `.cmd` shim and PowerShell
  only quotes a native argument containing a space.
- Entitlement sync failing on Windows because `&` in a Graph URL reached
  `cmd.exe`; the sync also never paged, silently truncating at 999 members.
- A redeploy resetting the entitlement allow lists to empty, revoking every user.
- Reuse resetting API Management TLS settings, NAT gateway and developer portals
  to defaults.
- `RoleAssignmentExists` when reusing a gateway that already held the Foundry
  role.
- The migration guide's claim that Desktop and Cowork sessions do not transfer.
  An import wizard exists.

## [1.1.0] - 2026-08-28

### Added

- Interactive admin setup, one-command developer setup, and an onboarding email
  template.
- macOS and Linux versions of the admin and workstation scripts.
- An end-to-end health check, `scripts/Debug-ClaudeCode.ps1`.
- A preflight so setup fails early rather than midway.

### Fixed

- The health check detecting the main VS Code process rather than the extension
  host.

## [1.0.0] - 2026-08-19

Initial release.

### Added

- Governed gateway for Claude Code on Microsoft Foundry: API Management Basic v2,
  per-developer token budgets keyed on the Entra object id, tiering from Entra
  group membership, and chargeback telemetry. The gateway holds the only Foundry
  credential; developers authenticate with their own Entra token.
- `Install-ClaudeGateway.ps1` and the Bicep template behind it.
- `Sync-ClaudeAccess.ps1`, syncing Entra group membership into API Management
  named values.
- Task-shaped documentation, an annotated click-by-click UI guide, and the
  Playwright tooling that generates its screenshots.

[Unreleased]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/naveenneog/claude-code-foundry-gateway/releases/tag/v1.0.0
