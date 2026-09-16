# Status

**Active packet:** P18b and P19b — the load envelope, the measured scale ceilings, and the shadow migration path. M4 is complete. Full regression including the Azure half passes: 30 checks, 94 of 94 mutations caught.

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