# ADR-0001: Adopt Ironclad as this project's engineering discipline

- **Status:** Accepted
- **Date:** 2026-09-02
- **Packet:** P-0 (setup)
- **Deciders:** claude-code-foundry-gateway maintainers

## Context

This repository is built largely through AI-assisted sessions, and the work now queued —
administrative parity with Claude Enterprise — is substantially larger than anything shipped so
far. Two failure modes are already visible in its history.

**Context loss.** Reasoning that lived only in a chat log is gone. Several decisions here were
re-derived more than once because the first derivation was never written to disk.

**Drift under confidence.** This repository has shipped, and then had to correct, all of the
following:

| Corrected | How it was caught |
|---|---|
| "Claude Desktop conversations cannot be imported" — an inference from an architecture table, published twice | Reading the page that documented the import wizard |
| A check reporting PASS while scanning zero files | Reintroducing the bug it guarded against |
| A regression test asserting a property it could not detect | The same |
| A role-assignment collision that `what-if` reported as clean | Deploying it |

None of these were caught by care. Each was caught by a check that ran, or by deliberately
trying to break something. That is the argument for a machine-checked gate rather than
convention.

## Options considered

1. **Nothing formal.** Zero setup cost. Fails exactly when a session is long, which is when it
   matters.
2. **Prose guidelines.** Better, but unenforced text is advice. Nothing detects a test that was
   never written.
3. **Ironclad — charter, ledger, council, executable gate.** Already in use in
   `foundry-hackathon-gateway` in this workspace, so the discipline and the tooling are proven
   here rather than adopted on faith.

## Decision

Option 3, matching the sibling repository.

- `.ironclad/charter.json` holds commands, budgets and architecture boundaries.
- `.ironclad/gate.mjs` is vendored, zero-dependency, and is the definition of done:
  `--stage packet` must exit 0.
- `docs/` holds the ledger: CHARTER, ROADMAP, STATUS, UNKNOWNS, CHANGELOG, adr/.
- Work proceeds in packets: PLAN → CONTRACT → RED → GREEN → REFACTOR → COUNCIL → GATE → LOG.

### Tests moved to `tests/`

Adopting the gate surfaced `tests.exist: FAIL — No test files found`, in a repository with nine
`Test-*.ps1` files.

The detector was right. `Test-` is a PowerShell *verb*, not a test marker:
`scripts/Test-Prerequisites.ps1` is a runtime preflight called by the installer, and
`scripts/Test-FoundryDirect.ps1` is a manual diagnostic. Neither is a test. Matching
`Test-*.ps1` wholesale would have counted both and inflated the ratio into a lie — which is
what the detector's own comment warns against.

The seven files that genuinely are tests moved to `tests/`. The two that are product code
stayed in `scripts/`. No allowlist was added and no budget was loosened.

## Consequences

+ A fresh session reads `docs/STATUS.md` and knows what is in flight.
+ Test-first is enforced rather than intended, before M1 rather than after.
+ The parity work has a written plan, so scope creep is visible as an unplanned packet.
− Real overhead per packet: the ledger has to be updated and the gate has to pass.
− The gate can produce false positives. Each is fixed by a recorded charter exception with a
  stated reason, never by silently loosening a budget.

## How we would know this was wrong

If the gate is routinely bypassed with `--no-verify`, it is mis-tuned or too slow, and the
honest response is to fix the checks. More than a couple of bypasses in a milestone means this
ADR needs revisiting.
