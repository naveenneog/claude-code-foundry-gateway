# ADR-0017: Two terminal faces over one FinOps backend

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** CLI FinOps first release (owner-authorized parallel packet)
- **Deciders:** Platform owner

## Context

The owner explicitly commissioned this packet on the `claude-finops` worktree while P45
remains the lead worktree's active packet. The owner reserved STATUS, ROADMAP, CHANGELOG
and UNKNOWNS for the lead; this packet proposes those ledger changes in its delivery
report instead of modifying them. This reconciles the repository's single-packet and
same-packet ledger rules with the parallel assignment; no detector is relaxed.

The revision 4 design includes future approvals, boosts, bulk allocation and an assistant.
This release is bounded by the owner's enumerated Turnstile endpoints. Features without
that API contract are not represented as working controls.

## Decision

Use Textual and Typer over one backend interface: Turnstile HTTP, direct gateway through
the existing PowerShell scripts and analytics queries, and deterministic example data.
Keep token acquisition in memory through Azure CLI; configuration holds addresses only.
Members remain read-only even when a future server returns manager scopes. The server
always makes the authorization decision.

Changes default to a preview; an explicit apply is required. Show allocation headroom
separately from remaining usage. Follow apply jobs without treating a saved record as
proof of gateway enforcement. Never automatically retry a write.

## Evidence and unknowns before implementation

- DOCUMENTED: Repository ADR-0016 defines Owner and Member behavior; manager writes
  belong to a later packet.
- DOCUMENTED: `ClaudeTurnstileGovernance.ps1` maps units to organizations and teams
  to departments, and defines the quote-free integration named value.
- DOCUMENTED: The fork's `claude-gateway` models and HTTP routers are the API contract;
  compatibility tests pin the covered routes and response fields.
- INFERRED pending tests: A scoped manager response may grow fields. Preserve additional
  identity fields, fail closed for edits, and never perform client-side scope widening.
- INFERRED pending live reads: Server apply status demonstrates job completion, not
  exact budget counters; budgets remain delayed brakes, not invoice guarantees.

## Consequences

One set of validation and preview rules serves automation and the terminal. Direct mode
requires the repository scripts and Azure roles and cannot offer scoped manager access.
Future Turnstile pages require explicit parity review; the manifest distinguishes current
coverage from intentionally deferred endpoints.
