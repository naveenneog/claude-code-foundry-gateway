# Business units

Chargeback answers one question: whose budget did this request spend. A business
unit is the owner of that budget.

This page covers adding one, setting and changing its budget, moving people
between them, and removing one. The decision behind the design is in
[ADR-0007](adr/0007-business-unit-model.md).

## What a business unit is

An **Entra security group** with a **monthly budget**.

| | |
|---|---|
| **Identifier** | `platform`. Stable. It is what the budget counter, the ledger and every report use |
| **Entra group** | `claude-code-standard`. Who belongs to the unit. Can be renamed without touching the identifier |
| **Budget** | Set in dollars, stored in tokens, converted once when written |

Membership comes from the group, so moving a developer between business units is
done in Entra and picked up by the sync. There is no separate roster to keep in
step.

## Read this before you quote a number

The budget is a **spend guide, not an accounting figure**, and there are two
measured reasons why.

**A dollar does not buy a fixed number of tokens.** Claude's output tokens cost
five times base input, so the conversion assumes a mix — 20% output by default,
which is deliberately conservative. Change it with `-OutputShare` if your
workload differs.

**The counter does not see cached tokens.** API Management's `llm-token-limit`
policy "currently counts prompt and completion tokens only". Measured against
thirty days of live usage on the reference gateway, cache reads were 6.8 million
tokens against 320 thousand prompt and 152 thousand completion, which at Claude's
published rates is **38.7% of the real cost weight**. Real spend is therefore
**higher** than any figure here, not lower.

Figures are also at **list price**. Azure bills Claude as a single aggregated
Claude Consumption Unit meter, and private-offer discounts are applied before
that conversion, so none of this reconciles to an invoice. See `U2` in
[UNKNOWNS.md](UNKNOWNS.md).

Every command repeats these caveats in its own output, so nobody reads a number
without them.

## Adding a business unit

```powershell
./scripts/Set-ClaudeBusinessUnit.ps1 -Id platform `
    -Group "claude-code-standard" -MonthlyBudgetUsd 5000
```

![Adding a business unit, showing the dollar-to-token conversion and the assumptions behind it](guide/bu-1-add.png)

The identifier must be lower-case letters, digits and hyphens. It becomes a
counter key and a map key, so a space, comma, equals or colon is refused rather
than silently mangled.

Creating one needs both `-Group` and `-MonthlyBudgetUsd`. After that, either can
be changed on its own.

## Listing them

```powershell
./scripts/Set-ClaudeBusinessUnit.ps1 -List
```

![Listing business units with their groups, token budgets and approximate dollar value](guide/bu-2-list.png)

## Changing a budget

Pass the identifier and the new figure. The group is left alone.

```powershell
./scripts/Set-ClaudeBusinessUnit.ps1 -Id platform -MonthlyBudgetUsd 8000
```

![Changing a budget, reporting the previous value alongside the new one](guide/bu-3-change-budget.png)

The output states what the value was as well as what it now is, so a change made
by mistake is visible in the terminal rather than only in the audit log.

To point a unit at a different Entra group, pass `-Group` instead. To change
both, pass both.

## Moving people between business units

Membership is group membership. Add or remove the developer in Entra, then run
the sync:

```powershell
./scripts/Sync-ClaudeAccess.ps1
```

![The sync resolving Entra groups to object ids and mapping developers to business units](guide/bu-4-sync.png)

The sync reads the registry, resolves each unit's group, and writes the map the
gateway reads. A developer in two business-unit groups takes the **first in
registry order**, which is deterministic and visible in the list above.

If a group resolves to zero members while the map currently assigns people, the
sync **refuses to overwrite it** and says so. That guard exists because the
entitlement lists were once silently emptied by exactly this, and the symptom —
spend landing on no budget — is invisible until someone reconciles a report.

## Seeing what has been spent

```powershell
./scripts/Get-ClaudeBusinessUnit.ps1
```

![Spend by business unit, with member counts, budgets, usage and the unassigned count](guide/bu-5-report.png)

Spend comes from the [chargeback ledger](adr/0006-ledger-is-the-llm-log.md), which
is the built-in API Management LLM log joined to the caller. `-AsJson` gives the
same data for a dashboard, and `-Days` overrides the default of month-to-date.

## Developers with no business unit

Anyone entitled but not in a business-unit group is **unassigned**. What happens
to them is set by the `bu-unassigned` named value:

| Value | Behaviour |
|---|---|
| `allow` (default) | Served, recorded against `unassigned`, counted against no budget |
| `deny` | Refused, with a message telling them to ask for a business unit |

The default is `allow` deliberately. Nobody has a business unit at the moment
this first deploys, so a default of `deny` would refuse every request on the
gateway that installs it.

The target state is `deny`. Move to it once the report shows zero unassigned:

```powershell
az apim nv update -g <rg> --service-name <apim> `
    --named-value-id bu-unassigned --value deny
```

## Removing one

```powershell
./scripts/Set-ClaudeBusinessUnit.ps1 -Id research -Remove
```

![Removing a business unit, reporting what it was before it went](guide/bu-6-remove.png)

Its members become unassigned at the next sync. Their history in the ledger keeps
the identifier they spent under, because the ledger records the unit that was in
force at the time rather than looking it up later.

## When a budget runs out

The gateway returns `403` in Anthropic's error shape, naming the business unit:

```json
{ "type": "error",
  "error": {
    "type": "rate_limit_error",
    "budget": "business unit",
    "message": "The Claude budget for your business unit (platform) is spent for this period. Your access is unaffected - this budget is shared with your colleagues in that unit, and your platform team can raise it." } }
```

This is the fourth `403` the gateway can return, and they are deliberately
distinguishable: not entitled, personal budget, organisation budget, business
unit budget, wrong model. `budget` says which.

The limit is a **soft cap**. The policy reference states that high-concurrency
requests can temporarily exceed a configured limit, so it bounds spend rather
than guaranteeing it. Combined with the cache blind spot above, it should not be
described to a budget holder as a hard stop.

## Limits worth knowing

| | |
|---|---|
| Members per map | About 110. Named values cap at 4,096 characters and an object id is 37 of them. The sync now **fails loudly** rather than silently truncating |
| Business units | About 100 in a 4,096-character registry, depending on group name lengths |
| Enforcement | Monthly, soft, and blind to cached tokens |
| Reporting | List price, not reconciled to an invoice |

The membership ceiling is the same one entitlement already has, and
[ROADMAP.md](ROADMAP.md) `P19` replaces the store.

## Related

- [ADR-0007](adr/0007-business-unit-model.md) — why a group rather than a directory attribute
- [ADR-0006](adr/0006-ledger-is-the-llm-log.md) — where spend figures come from
- [ONBOARDING.md](ONBOARDING.md) — tiers, budgets and entitlement
