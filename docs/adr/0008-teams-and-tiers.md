# ADR-0008: Teams nest inside business units, and tier is a separate axis

- **Status:** Accepted
- **Date:** 2026-09-15
- **Packet:** P20c
- **Deciders:** claude-code-foundry-gateway maintainers
- **Supersedes:** nothing. Extends [ADR-0007](0007-business-unit-model.md).

## Context

ADR-0007 gave chargeback one level: a developer belongs to a business unit, and
that unit has a budget. Organisations do not stop there. A budget holder owns a
business unit, delegates part of it to a team, and expects to see both the team's
spend and the unit's total.

Separately, the gateway already has **tiers** — `claude-code-standard` and
`claude-code-premium` — which decide which models a developer may call and what
their personal budget is. Whether tier and team are the same thing was not
settled.

## Decision

### Teams are units with a parent

A team is a business unit that names a parent. The registry format does not
change; a second named value records the parent.

```
bu-registry   ,mcaps=claude-bu-mcaps:5000000,ites-1=claude-team-ites-1:2000000,
bu-parents    ,ites-1=mcaps,ites-2=mcaps,
bu-members    ,<oid>=ites-1,<oid>=ites-2,<oid>=gbb,
```

A request is charged to the developer's unit **and** to that unit's parent. Two
counters, both monthly, both soft. A unit with no parent is charged once.

The alternative was a fourth field in the registry entry. It was not chosen
because the group name may itself contain a colon, which is why the budget is
already parsed by splitting on the **last** one. A variable number of
colon-separated fields makes that rule ambiguous, and that exact parsing rule is
where the last defect in this area was found.

**What would change it:** a customer needing more than two levels. The registry
would then need a real nested form, and the policy a loop it cannot currently
express.

### Depth is capped at two

Organisation ceiling → business unit → team. No deeper.

`llm-token-limit` is a policy element, not a loop. Each level costs one more
element with a statically written counter key. Two levels covers
BU-and-team, which is what the hierarchy is for; supporting arbitrary depth would
mean generating the policy per customer.

**What would change it:** evidence that a customer's chargeback genuinely needs
division → BU → team → squad. The answer then is a projection computed outside
the request path, not more policy elements.

### Membership resolves to the most specific unit

An Entra group can contain another group, so `claude-bu-mcaps` transitively
contains everyone in `claude-team-ites-1`. A developer therefore matches both.

The sync assigns the **most specific** unit — the team — and the parent is
reached through the cascade rather than through membership. Units with a parent
are resolved before units without one, so a team always wins over the business
unit that contains it.

ADR-0007's "first match in registry order" still decides between two units at the
same depth.

### Tier is a separate axis, attached by nesting

Tier answers "what may this developer do". Team answers "whose budget does this
spend". They are independent, and a team can be moved between tiers without
touching chargeback.

A team gets a tier by **nesting the team group inside the tier group**:

```
claude-code-standard
└── claude-team-ites-1        → everyone in ITES 1 is standard
claude-code-premium
└── claude-team-ites-2        → everyone in ITES 2 is premium
```

Nothing in the tier mechanism changes. `Sync-ClaudeAccess.ps1` already resolves
entitlement transitively, so a nested team's members appear in the tier's
entitlement list without a second step. Changing a team's tier is one membership
edit in Entra.

**What would change it:** a customer wanting per-developer tiers inside one team.
Direct membership of the tier group still works and takes effect the same way,
so both coexist.

## What this exposed

Graph's `transitiveMembers` returns **nested group objects as well as users**.
Measured 2026-09-15 against `claude-code-standard` with one team nested inside
it: seven members returned, of which two were `#microsoft.graph.group`.

`Get-GroupMemberOids` did not filter by type, so a group's object id would have
been written into the entitlement list and the membership map — consuming the
scarce 4,096-character named value budget, which holds roughly 110 object ids,
and inflating the "developers mapped" count.

The fix is the typed cast `/transitiveMembers/microsoft.graph.user`, which
filters server-side. Filtering client-side on `@odata.type` would not work:
under a cast Graph omits that property, and before the cast it is only present
because the collection is heterogeneous. Measured: the cast returned five users
and no groups where the uncast call returned seven objects.

This defect predates teams. It was unreachable only because nothing was nested.

## Consequences

+ A team is not a new kind of object. Every command, the ledger, the report and
  the refusal path treat it as a unit that happens to have a parent.
+ Tier and chargeback stay independent, so re-organising one does not disturb
  the other.
+ Membership is maintained in Entra, where joiner/mover/leaver already runs.
− Two more counters per request at the policy level, and one more named value.
− The cascade is two levels. A third would need a different mechanism.
− Both counters carry ADR-0007's measured error: they count prompt and completion
  only, missing 38.7% of real cost weight on measured usage.

## How we would know this was wrong

If administrators start creating a team per developer to get per-developer
budgets, the tier's per-user budget was the right control and the team level is
being misused. The signal is teams with one member.
