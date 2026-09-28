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

## Evidence

- Existing authority: [ADR-0018](0018-terminal-finops.md),
  [ADR-0026](0026-usd-budget-reconciliation.md) and
  [ADR-0029](0029-aum-developer-membership.md).
- Publication and responsiveness: [ADR-0035](0035-aum-bounded-readiness-and-progressive-reads.md).
- Local contracts and investigation: [U38-U41](../UNKNOWNS.md#p80-research-before-resumed-implementation).
- Measured tests, reversion probes, captures and handoff state:
  [P80 STATUS](../STATUS.md#p80-aum-shows-every-action-it-has-connects-in-one-step-and-its-guide-starts-with-installation-2026-09-28).
