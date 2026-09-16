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
| **Identifier** | `platform`. Stable. It is what the budget counter and every report use, and the key each request is recorded under in the chargeback ledger — the gateway's own log of who spent what |
| **Entra group** | `claude-code-standard`. Who belongs to the unit. Can be renamed without touching the identifier |
| **Budget** | Set in dollars, stored in tokens, converted once when written |

Membership comes from the group, so moving a developer between business units is
done in Entra and picked up by the sync. There is no separate roster to keep in
step.

## Teams, and how they relate to tiers

A **team** is a business unit that names a parent. A request is charged to the
team **and** to the business unit above it — two counters, both monthly, both
soft. [ADR-0008](adr/0008-teams-and-tiers.md) records the model.

**Tier** is a separate axis. It answers "what may this developer do" — which
models, and what personal budget. Team answers "whose budget does this spend".
They are independent, so a team can move between tiers without disturbing
chargeback, and a team can move between business units without changing what its
members are allowed to call.

Both are expressed the same way: **one Entra group nested inside another**.

```
claude-bu-mcaps                     business unit, budget
├── claude-team-ites-1              team, own budget, charged to MCAPS too
│   ├── Naveen Gopalakrishna
│   └── Saurabh Seth
└── claude-team-ites-2              team, own budget, charged to MCAPS too
    ├── Nived Velayudhan
    └── Vraja Kishore Mudumbai

claude-bu-gbb                       business unit with direct members, no team
└── Somnath Banerjee

claude-code-standard                tier: which models, personal budget
├── claude-team-ites-1              → everyone in ITES 1 is standard
└── claude-bu-gbb                   → everyone in GBB is standard

claude-code-premium                 tier
└── claude-team-ites-2              → everyone in ITES 2 is premium
```

A group can sit in more than one parent, which is what makes the two axes
independent: `claude-team-ites-1` is inside `claude-bu-mcaps` for chargeback and
inside `claude-code-standard` for entitlement.

Changing a team's tier is one membership edit in Entra. Nothing in the gateway
changes, because entitlement is already resolved transitively.

### Seeing it in Entra

The hierarchy is ordinary group nesting, so it is visible in the portal.

**Direct members** of a business unit are its teams, not people:

![The claude-bu-mcaps group in the Azure portal, Direct members tab, showing two members: claude-team-ites-1 and claude-team-ites-2, both of type Group](guide/entra-1-bu-direct-members.png)

**All members** resolves the nesting and shows the people underneath — the same
transitive view the sync reads:

![The same group on the All members tab, showing six members: the two team groups plus the four people inside them, each with type User and an email address](guide/entra-2-bu-all-members.png)

The difference between those two tabs is the whole model. Membership is
maintained on the team, and the business unit gets it by containment.

The teams themselves are where people are actually added. ITES 1:

![The claude-team-ites-1 group, Members tab, showing two members of type User with masked names and email addresses](guide/entra-5-team-ites-1-members.png)

ITES 2, holding two different people:

![The claude-team-ites-2 group, Members tab, showing two members of type User with masked names and email addresses](guide/entra-6-team-ites-2-members.png)

Those four rows are the six rows on the business unit's All members tab, minus
the two team groups. Nobody was added to `claude-bu-mcaps` directly.

**Group memberships** on the team shows the two axes directly — ITES 1 is inside
`claude-bu-mcaps` for chargeback and inside `claude-code-standard` for
entitlement, at the same time:

![The Group memberships blade of claude-team-ites-1, listing two security groups it belongs to: claude-bu-mcaps and claude-code-standard, both assigned and cloud-sourced](guide/entra-3-team-memberships.png)

Moving that team to the premium tier is removing one of those two rows and
adding another. Its business unit, budget and spend history are untouched.

Read from the tier side, the same nesting looks like this. `claude-code-standard`
holds two teams and three people added to the tier directly:

![The claude-code-standard group, Members tab, showing five members: two of type Group and three of type User with masked names and addresses](guide/entra-7-tier-standard-members.png)

A tier can hold people, teams, or both. Mixing them is supported because
entitlement is resolved transitively — a person in ITES 1 gets the standard tier
through the team, and a person added to the tier row gets it directly.

`claude-code-premium` holds one team and one service principal:

![The claude-code-premium group, Members tab, showing two members: claude-team-ites-2 of type Group and claude-code-dev-bob of type Service principal](guide/entra-8-tier-premium-members.png)

That second row is a workload identity, not a person, so its name is not masked.
A build agent or scheduled job authenticates as a service principal and needs a
tier like anyone else. It is not in a business unit, so its usage is recorded
against the `unassigned` bucket unless you put it in one.

A business unit does not have to contain teams. GBB holds one person directly:

![The claude-bu-gbb group, Direct members tab, showing a single member of type User](guide/entra-4-bu-direct-person.png)

The same hierarchy read from one person's end. The Groups blade on a user
account lists the groups that account belongs to **directly**:

![The Groups blade of a user account, listing the security groups that account belongs to, with the display name masked in the title and breadcrumb](guide/entra-9-user-groups.png)

The account in this capture belongs to its team and to a tier group directly, so
both appear. That is not the general case. Measured on two accounts in this
tenant:

| Account | Direct memberships | Resolved transitively |
|---|---|---|
| in a team, and added to a tier directly | `claude-team-ites-1`, `claude-code-standard` | plus `claude-bu-mcaps` |
| in a team only | `claude-team-ites-1` | plus `claude-code-standard`, `claude-bu-mcaps` |

Both resolve to the same tier and the same business unit. The business unit never
appears in the direct list, because it is always reached through the team.

So a wrong tier or a wrong business unit cannot be diagnosed from this blade
alone — a missing row here is not a fault. Read the transitive view instead:

```powershell
az ad user get-member-groups --id someone@contoso.com --query "[].displayName" -o tsv
```

That returns every group the gateway's sync will see, which is what entitlement
and attribution are actually resolved from.

These are real accounts in a real Microsoft non-production tenant. Names and
addresses are masked in the middle — enough removed to stop anyone being
identified or contacted, enough kept that you can see this is a working
deployment rather than a mock-up.

These links open the same blades in the reference deployment; substitute your own
group object ids.

| Group | Role | Portal |
|---|---|---|
| `claude-bu-mcaps` | Business unit. Members are the two team groups | [Members](https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/df529b3b-df37-40ab-9593-f19b9219f855) |
| `claude-team-ites-1` | Team. Members are people | [Members](https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/cbe8263d-55fc-4080-b147-d1fc6fc36aed) |
| `claude-team-ites-2` | Team. Members are people | [Members](https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/a2a9bda1-06dd-4774-a50a-63e89e45ad32) |
| `claude-bu-gbb` | Business unit with direct members and no team | [Members](https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/058d5d1d-1823-4b43-b884-0938694e462a) |
| `claude-code-standard` | Tier. Contains `claude-team-ites-1` and `claude-bu-gbb` | [Members](https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/bac8d3f3-a87e-493b-b607-cca92d013d18) |
| `claude-code-premium` | Tier. Contains `claude-team-ites-2` | [Members](https://portal.azure.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Members/groupId/78e38759-d8a3-4436-b0dd-699a5e0c31be) |

To see what one person inherits, open their profile and use **Groups →
transitive membership**, which is the view the sync reads.

`guide/capture-entra.mjs` screenshots all six blades and
`guide/redact-entra.mjs` replaces the identities in them. Sign in once first:

```powershell
node guide/auth.mjs              # complete MFA once; session is kept
node guide/capture-entra.mjs     # writes .shots-entra/
node guide/redact-entra.mjs      # writes docs/guide/entra-*.png
```

The capture exits non-zero if the session has expired rather than saving the
sign-in page, because a screenshot of a login form looks enough like a
screenshot of a group to get published by mistake. `.shots-entra/` is
git-ignored — the unredacted captures carry real names and the signed-in
account, and only the redacted output ships.

Redaction boxes are pixel coordinates, so each capture needs its own entry in
`JOBS`. The four shown above have one; the remaining blades do not yet. If you
capture them, `redact-entra.mjs` **exits non-zero and names the files it could
not handle** rather than skipping them quietly — an unredacted capture sitting
in a folder is the one that gets copied into the docs by hand with a real name
still on it.

Only the masked strings are committed. The originals exist only in the capture,
which is git-ignored.

### Depth is two levels

Organisation ceiling → business unit → team. No deeper.

Charging both levels is two counters in the gateway policy, with fixed keys and
no loop, so a third level would not be charged at all. Rather than let that
happen quietly, `Set-ClaudeBusinessUnit.ps1` refuses a deeper chain when you
write it, and refuses a cycle.

### Creating a team

```powershell
./scripts/Set-ClaudeBusinessUnit.ps1 -Id mcaps `
    -Group "claude-bu-mcaps" -MonthlyBudgetUsd 20000

./scripts/Set-ClaudeBusinessUnit.ps1 -Id ites-1 `
    -Group "claude-team-ites-1" -MonthlyBudgetUsd 6000 -Parent mcaps
```

The parent must already exist. To promote a team back to top level, pass an
empty parent:

```powershell
./scripts/Set-ClaudeBusinessUnit.ps1 -Id ites-1 -Parent ''
```

Removing a business unit promotes its teams to top level rather than leaving them
pointing at something that is gone.

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

The sync reads the list of registered business units, resolves each unit's Entra
group to the object ids of its members, and writes that mapping into the gateway
for the policy to read. A developer in two business-unit groups takes the
**first in registry order**, which is deterministic and visible in the list
above.

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
to them is set by `bu-unassigned`, one of the gateway's named values — API
Management's own configuration store, which the policy reads at request time:

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
