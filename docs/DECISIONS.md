# Decisions

Nine choices an operator makes. Seven have a sensible default and can wait. Two
are expensive to change later, and both cost nothing today.

Nothing here is a recommendation about your organisation — each entry says what
the default does, what the alternatives cost, and what happens if you leave it.

---

## The two that are expensive to defer

### 1. Do developers get a company web address, or the Azure one?

**Default today:** the Azure one. `Install-ClaudeGateway.ps1` writes
`https://<instance>.azure-api.net/claude` into `onboarding/claude-gateway.json`,
and every client on every machine is configured from it.

**Why it matters:** the instance name is part of that address. If you ever
replace the gateway — moving to a tier that cannot be upgraded in place, or to a
different region — the address changes and **every developer has to be
reconfigured**. Behind `https://claude.<company>.com/claude` the same move is a
DNS change nobody notices.

**Cost of choosing it now:** a certificate and a DNS record.

**Cost of choosing it later:** at 200 developers, an afternoon of everybody's
time. At 200,000, nobody attempts it — which means whatever you pick on the
first day is permanent.

See [ADR-0013](adr/0013-gateway-outlives-instance.md).

### 2. Do you need this to survive an Azure region failing?

**Default today:** no. A single region.

**Why it matters:** multi-region is only available in the **Premium classic**
tier. It is not in Premium v2, and there is no supported migration between the
v2 family and the classic family. So this is not a switch you flip later — it
decides which family you start in.

| | Zone redundancy | Multi-region |
|---|---|---|
| Basic v2 | no | no |
| Standard v2 | no | no |
| Premium v2 | **yes** | no |
| Premium (classic) | **yes** | **yes** |

**If the answer is yes**, start on Premium classic. If it is no, or you are not
sure, the custom domain above is what keeps the option open at reasonable cost.

---

## The one that blocks the scaling work

### 3. If you remove someone, how long may they keep working?

**Default today:** one hour — `entitlement-cache-seconds`, currently 3600.

Access is not withdrawn the instant you remove somebody. The gateway holds the
answer for a while rather than asking on every request, and that interval is
this number.

| Window | Cost at 500,000 developers |
|---|---|
| 15 minutes | about $16 a month |
| 1 hour | about $4 a month |
| 4 hours | about $1 a month |

Computed by `./scripts/Measure-ClaudeProjectionCost.ps1`, not quoted.

This does **not** hold up any engineering — it is a named value with a working
default, and changing it is one command. It holds up being able to state your
revocation guarantee to a security reviewer, which is usually the thing that is
actually being asked for.

---

## The tier

### 4. When do you move off the starter tier?

**Default today:** Basic v2.

Basic v2 cannot join a virtual network. The entitlement store that removes the
roughly 93-developer ceiling sits behind a private endpoint, so **Basic v2
cannot run it at any size**. This is a networking limit, not a headcount one.

Basic v2 to Standard v2 is an in-place change: no gateway downtime, no change of
address, nothing to reconfigure. Anything beyond Standard v2 means a new
instance, which is why decision 1 exists.

**Move before a wider rollout**, not after.

---

## Money and policy

### 5. What is the whole-organisation ceiling?

**Default today:** `quota-org` is 100,000,000 tokens a month — roughly $360 at
the blended Sonnet rate.

It is checked **before** every per-team budget, so whichever is smaller is the
one that actually binds. A team budget larger than this can never be reached:
the organisation is refused first, and every team still shows plenty of headroom
right up to that moment.

`./scripts/Test-ClaudeHealth.ps1` fails the run when the team budgets add up to
more than this.

### 6. Is a team budget a report, or a hard stop?

**Default today:** a report.

Budgets are set in dollars and enforced by counting tokens, and the counter
**cannot see cached tokens**. On the reference gateway, cache was 98% of
estimated spend, which made real spend **41.5 times** the portion the budget
counts.

So a $2,000 limit permits far more than $2,000 of real spend. Two honest ways to
handle that:

- treat the dollar figure as **reporting**, and use the per-developer daily
  limit as the thing that actually stops a runaway; or
- divide the token figure by **your own** measured ratio — read it from the
  chargeback workbook rather than reusing 41.5, which is one gateway's caching
  profile and not a constant.

Say "we can attribute the cost" rather than "we can cap it". Today the first is
true and the second is not.

### 7. Can everyone use the most expensive model?

**Default today:** yes. `models-standard` and `models-premium` are both empty,
which means every deployed model is allowed in both tiers.

Opus is two and a half times Sonnet on both input and output. This is the
largest single cost lever available, and it is the only one caching cannot
defeat.

```powershell
./scripts/Set-ClaudeTier.ps1 -Tier standard -Models claude-sonnet-5
```

### 8. Can somebody with no team assigned still use it?

**Default today:** yes — `bu-unassigned` is `allow`. Their usage is served and
recorded, and charged to nobody.

Switch it to `deny` once every developer has a team, not before, or you will
refuse people who have done nothing wrong. `./scripts/Get-ClaudeBusinessUnit.ps1`
reports how many are still unassigned.

---

## The scope question

### 9. How many developers are you actually planning for?

This decides how much of the scaling work is worth doing.

| Planning for | What you need |
|---|---|
| Up to about 90 | Nothing. It works today |
| A few hundred | The entitlement store, and Standard v2 to run it |
| Thousands | The above, plus a look at request volume — Standard v2 includes 50,000,000 requests a month, about 4,500 developers at 500 requests each a day |
| 200,000 | All of the above, plus decisions 1 and 2 settled first, because neither can be retrofitted |

`./scripts/Measure-ClaudeCeiling.ps1` reports where your own gateway is against
the first of those.
