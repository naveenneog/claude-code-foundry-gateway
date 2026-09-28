# ADR-0038: AUM actions and a local connection transaction

- **Status:** Accepted for P80 implementation; owner review and council pending
- **Date:** 2026-09-28
- **Packet:** P80

## Context

The owner's AUM session did not expose adding a person, changing a selected
person's budget, USD availability or a single chargeback-report action. The
connection was Turnstile, but the terminal did not identify that choice clearly.
The connection editor required a separately edited profile file. The guide
started with tool selection rather than installation.

The resumed branch contains `cd92f47`, `450e817`, `2043448`, `be12957` and
`b1dfcd4`, based on P71's `bcf8554`. Their existing tests are regression
evidence, not a recorded test-first sequence. P80 records reversion probes for
that behavior and RED/GREEN results for subsequent corrections.

The owner requires isolation until review after the 2026-09-29 deployment.
This supersedes the earlier P80 plan's instruction to merge P71 again.
Later P71 commits, main and origin are not changed by this packet. The lead
owns the five-seat council; no builder council verdict is inferred.

## Options

1. Document command-palette workarounds and manual profile editing. This
   leaves the reported terminal paths undiscoverable.
2. Add new backend writers or infer another authority when USD is unavailable.
   This conflicts with [ADR-0026](0026-usd-budget-reconciliation.md).
3. Expose the existing actions, reuse their preview-first forms, and treat
   connection replacement as a reversible local-file operation. This is the
   selected option.

## Decision

People and Budgets name the same actions in their controls, keyboard hints
and Help. The existing role, writable-scope and capability checks remain the
authority. USD stays an explicit option, or an unavailable explanation; it
does not become the universal budget default. Turnstile gets no USD writer.

The People add flow reads the existing budget catalog on demand, without a
visit to Budgets. Both the directory result and catalog retain their original
publication guards through form opening and later preview. Directory and
catalog waits have estimates and errors remain visible. Entra membership
still requires the existing delegated rights and owner check.

Chargeback uses the engine's complete month aggregation, not visible table
rows or top rankings. Its default folder is `Documents/AUM` on Windows and
`aum-reports` under the home directory elsewhere. Exclusive file creation
prevents overwrites; collisions get numbered filenames. The terminal reports
the resolved full path. The installed P50 generator is a separate,
preview-first option, with its existing authorization and reconciliation
checks; selecting the CSV action does not send a report or deploy a job.

Settings exposes the current connection kind and address and a single form
for Direct, AUM service and Turnstile. The form previews address-only
configuration before saving. A timestamped backup preserves the exact
previous bytes. Replacement uses a temporary file in the same directory and
an atomic rename. Failed identity verification restores the previous file
(or removes a newly created profile) and keeps the previous live engine.
Neither an Azure resource nor Azure CLI's global account is changed.
Configuration-file overrides remain local to the selected profile.

The CLI shares local backup/save helpers. An attended replacement requires
confirmation; unattended replacement still requires `--force`. Explicit
HTTP URL and scope avoid unnecessary discovery. A backend change remains a
connection choice, never a permission or governance-authority upgrade.

The guide's first sections are Install, Connect, First run and screen tour,
task how-to sections, Reference and Troubleshooting. Existing detailed
evidence remains available under those sections or through local references.
Related FinOps guides link to this installation and connection contract
instead of maintaining competing steps.

## Architecture and consequences

There is no new Azure component, identity, schedule, network destination or
backend authority. The existing AUM client gains local profile backup and
report-file flows. The AUM diagram records those local flows and its source
manifest is regenerated with the terminal inputs. P71's publication boundary
remains in force for widgets, dialogs, clipboard and exported data.

Validation is offline and fixture-backed. It does not establish production
directory scale, Azure availability or invoice reconciliation. No reference
gateway operation is part of P80. Full suites and mutation batches run only
under a lock created by this builder and released in `finally`.

The export progress literal now includes its 3-30 s estimate. The existing
static-write allowlist entry and its pinned hash track that exact changed
literal and reason; the list remains 51 entries. No handler-wide exception,
dynamic value exemption or publication-boundary relaxation is added.

## Evidence

- Existing authority: [ADR-0018](0018-terminal-finops.md),
  [ADR-0026](0026-usd-budget-reconciliation.md) and
  [ADR-0029](0029-aum-developer-membership.md).
- Publication and responsiveness: [ADR-0035](0035-aum-bounded-readiness-and-progressive-reads.md).
- Local contracts and investigation: [U38-U41](../UNKNOWNS.md#p80-research-before-resumed-implementation).
- Measured tests, reversion probes, captures and handoff state:
  [P80 STATUS](../STATUS.md#p80-aum-shows-every-action-it-has-connects-in-one-step-and-its-guide-starts-with-installation-2026-09-28).

## Builder validation, 2026-09-28

The full Windows AUM suite passed 614 tests in 486.25 s at `2d41f69`.
All 49 isolated reversion probes were caught, retaining each baseline
selector's exact test-case IDs/count and producing failures rather than
collection errors. The harness, including clean baselines and restoration,
took 472.875 s. Restored P80/manifest tests passed 55 cases; a separate LF
checkout simulation passed the normalized-text manifest check.

The owned lock interval was 22:16:30-22:32:54 IST. Architecture and all 42
guide references passed under that lock. The no-run gate passed with the
file-size and unrelated-open-unknown warnings; it did not execute Test-All
or the build. Council, the full packet gate and post-deployment owner review
remain pending. No live Azure, directory or model evidence is claimed.

## Council round 1 amendment

The 2026-09-28 review found two windows not held by the initial tests. Apply
recomputed the candidate and profile revision after its comparison. A failed
read immediately after atomic replacement also happened before the rollback
region. The replacement contract now requires the reviewed candidate bytes and
previous profile snapshot to remain immutable through commit. Expected written
revision is derived from those candidate bytes, not a post-save file read.

All AUM profile writers serialize comparison, backup, replacement and verification
with an OS-held lock on a persistent sibling file. Nonblocking acquisition
refuses another active writer rather than waiting without a deadline. The
OS releases the lock when the handle/process closes; the sibling file is not
deleted, avoiding a second lock identity. Windows uses
[`msvcrt.locking`](https://docs.python.org/3.12/library/msvcrt.html#msvcrt.locking);
Unix uses [`fcntl.flock`](https://docs.python.org/3.12/library/fcntl.html#fcntl.flock)
(documentation retrieved 2026-09-28). The lock coordinates AUM writers, not
arbitrary editors that do not participate. A changed profile before replacement
or after verification is refused; a detected newer file is not overwritten.

Failure after replacement retains the old live engine and attempts guarded
restoration. An unreadable file or failed restore is not reported as a restored
profile: the durable error names the backup and the manual recovery steps.
Conflict messages name changed address fields and revisions, not arbitrary
file contents or credentials.

Settings shows the connection in a guarded, wrapping label independent of
DataTable width caches. AUM-service membership is unavailable in the current
bridge; its control and explanation reflect that existing limit without
adding a writer. These are corrections within the existing local client/file
boundary, with no new Azure component, identity, network path or authority.

Round-1 correction evidence on 2026-09-29: all 19 new negative probes were
caught with their baseline case identities/counts preserved. The full AUM
regression union passed 632 unique cases across three disjoint, separately
locked commands, taking 339.57 s of pytest time. The unchanged original
Settings assertion and deterministic narrow-table/wrapping cases passed ten
consecutive fresh processes (40 cases, 152.750 s). The lead's round-2 council
and subsequent packet gate remain pending.

## Council round 2 amendment

The 2026-09-29 review found that transaction validation was correctly guarded
but the caller adopted the candidate UI before that validation completed.
The adoption boundary is after successful transaction exit: `whoami` alone
does not authorize closing the old form or discarding its identity and cached
state. The final saved-revision check still runs under the profile writer lock.
A failure retains the old UI and leaves recovery in the same persistent form.

Recovery content uses the existing keyboard-scrollable form container pattern.
The backup path and full recovery steps remain wrapped, focusable and readable
at 80x24 instead of relying on the two-line application status. The regression
holds its real Windows handle through successful identity verification, final
validation, rollback failure and UI inspection. This changes no Azure component,
identity, network path, membership writer or gateway authority.

Round-2 evidence on 2026-09-29: three new end-to-end regressions first failed
with the cleared identity, missing form and early adoption. The focused
connection/transaction/publication run then passed 56 tests in 52.56 s.
The final AUM regression union passed all 635 cases across separately locked
commands (331.30 s pytest time). All seven negative probes were caught after
the first sweep's notification survivor led to an additional notification
assertion; the original state and viewport assertions were not relaxed.
The Windows handle remained held through verification, both denied reads and
the complete keyboard-scrolled recovery inspection. Round 3 is lead-owned.
