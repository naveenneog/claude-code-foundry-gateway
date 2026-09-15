# ADR-0007: A business unit is an Entra group with a budget

- **Status:** Accepted
- **Date:** 2026-09-15
- **Packet:** P20
- **Deciders:** claude-code-foundry-gateway maintainers
- **Assumptions:** every decision below was taken as a stated default rather than
  a stakeholder answer. Each records what would change it.

## Context

Chargeback needs an answer to "whose budget did this request spend". Nothing in
the gateway holds that today. Tier is resolved from Entra group membership synced
into an API Management named value, and business unit needs the same kind of
answer.

## Decision

**A business unit is an Entra security group, registered with a budget.**

```
bu-registry   ,finance=Claude BU Finance:5000000,platform=Claude BU Platform:20000000,
bu-members    ,<oid>=finance,<oid>=platform,
```

`Sync-ClaudeAccess.ps1` already resolves a group to object ids with paging and a
guard against wiping the result. The same routine fills `bu-members`, so business
units inherit machinery that has been through three bugs and is now tested.

### Why a group rather than a user attribute

`department` and `employeeOrgData.costCenter` are attractive: no new objects, and
usually populated from HR. They were not chosen because reading another user's
attributes needs `User.Read.All` application permission and tenant-admin consent,
where group membership is already being read today with a delegated token. A
tenant that has clean `department` data can point each business-unit group at a
dynamic membership rule and get the same result without changing this design.

**What would change it:** a customer whose directory has accurate `costCenter`
and who objects to creating groups. The registry would then map a business unit
to an attribute value rather than a group, and nothing downstream would move.

### The identifier is not the name

The registry key — `finance` — is the identifier. It is what the counter, the
ledger and every report use. The display name sits beside it and may change
without orphaning history. Renaming the Entra group does not change the key.

**What would change it:** nothing. Astra's review raised this specifically, and a
system that keys chargeback on a mutable display name loses its own history the
first time someone reorganises.

### Precedence, and the unassigned case

A developer in two business-unit groups takes the **first match in registry
order**, which is deterministic and visible in the registry itself. Splitting a
single request across two budgets is not attempted.

A developer in **no** business unit is `unassigned`. What happens then is
configurable, and the default is deliberate:

| `bu-unassigned` | Behaviour | When |
|---|---|---|
| `allow` (default) | Served, recorded against `unassigned`, counted against no budget | Rollout, and any period where assignment is incomplete |
| `deny` | Refused with a message naming the problem | Once every developer has a business unit |

The target state is `deny` — an ungoverned request with no chargeback owner is
the thing this packet exists to remove. The default is `allow` because it cannot
be anything else: no developer has a business unit at the moment this ships, and
a default of `deny` would refuse every request on the deployment that installs
it. An accelerator whose upgrade takes the gateway down is not one anybody
upgrades.

`Get-ClaudeBusinessUnit.ps1` reports how many developers are unassigned, so the
move to `deny` is a decision with a number in front of it.

**What would change it:** a customer deploying from scratch with assignment done
up front could set `deny` on day one.

### Service principals

A service principal is entitled through `-AdditionalStandardOids` and is not in a
group, so it lands in `unassigned` unless the registry names it. That is correct
rather than incidental: automation spend belongs to whoever runs the automation,
and the registry is where that is stated.

## The budget is in dollars, and is not enforced as dollars

The registry carries a monthly figure. It is converted to tokens when written,
never per request, and the conversion is recorded.

This is the weakest part of the design and is documented rather than hidden.
Measured 2026-09-15, Claude's published rates make output five times base input
and a cache read a tenth of it, so a token total is not proportional to spend.
Worse, the `llm-token-limit` policy "currently counts prompt and completion
tokens only", and against thirty days of live usage that leaves **38.7% of the
real cost weight outside the counter**.

So:

- The registry stores dollars because that is what a budget holder sets.
- Enforcement runs on tokens because that is what the gateway can count.
- Every report states that the figure is derived at list price and excludes
  cached tokens, and `cost_is_estimate` travels with it.
- It is never called a dollar cap.

**What would change it:** closing U2 gives real rates, and moving enforcement to
an asynchronous controller reading the P18 ledger removes the cache blind spot.
Both are M4 work and neither blocks this.

## Consequences

+ Business units reuse the group sync, the named value helper with its 4,096-char
  guard, and the sentinel-comma convention already carrying entitlement and
  per-user overrides. No new mechanism.
+ Adding a business unit is one command naming a group and a budget.
+ The unassigned default means installing this changes no existing behaviour.
− Membership inherits the 4,096-character ceiling, about 110 developers per map.
  That is the same ceiling entitlement already has, it now fails loudly rather
  than silently, and P19 replaces the store.
− The budget is a token proxy for money, with a measured error. Stated everywhere
  it appears.

## How we would know this was wrong

If administrators end up maintaining business-unit groups that duplicate an
existing HR hierarchy, the attribute-based variant was the right one and the
registry should map to `costCenter` instead. The signal is groups whose
membership is maintained by hand rather than by a dynamic rule.
