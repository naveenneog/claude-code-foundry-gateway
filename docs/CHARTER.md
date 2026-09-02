# Charter

## Goal

Give an organisation running Claude on Microsoft Foundry the governance surface it would
otherwise get from Claude Enterprise, using Azure primitives it already owns, without adding
a second control plane to operate.

## Non-goals

- Rebuilding claude.ai. The target is administrative parity, not product parity.
- Replacing Entra ID, Azure RBAC or Intune with anything of our own.
- A hosted service. Everything ships as templates, policy and scripts the customer runs in
  their own tenant.
- Matching Anthropic's first-party release cadence. Preview and beta features reach the
  first-party API first; that gap is structural.

## Constraints

| Constraint | Consequence |
|---|---|
| Overhead cost stays low | API Management Basic v2 (~$250/month) is the floor. New components must justify themselves against it, and prefer serverless or existing Azure services over anything always-on. |
| Switchover must be simple | A customer moving off Claude Enterprise should not re-tool. Entra groups, Intune and Azure Monitor are the control surfaces, not a bespoke admin app. |
| Security parity is not negotiable | Anything that weakens the current posture — no credential on a developer machine, entitlement by group membership, the gateway as the only principal with data-plane access — is out of scope regardless of what it buys. |
| Research over recall | Every limit, API shape, price and policy behaviour is verified against a cited source or a live run before it lands in a design. |

## Quality bar

- A feature without a test is a rumour. Tests live in `tests/`.
- Every control claimed in documentation has a command that proves it, run against a live
  deployment before the claim ships.
- Anything not known is written to `docs/UNKNOWNS.md` before implementation, then closed by
  research with a citation, or recorded as an explicit assumption with a detector.
- Documentation states what is true and cites its source. It does not tell the reader what to
  think.
