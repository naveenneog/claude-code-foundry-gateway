# Decisions

Nine choices an operator makes. Settle the address and availability requirements
before onboarding. Neither a default nor a cost illustration is a production
capacity guarantee. See [Architecture](ARCHITECTURE.md) for the component map.

**Prerequisites:** platform, finance and network owners agree the required
revocation window, hosting option, peak traffic and budget authority. Confirm
roles and target resources in [Setup](SETUP.md).

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

**Cost of choosing it later:** reissue client configuration unless the old
address remains available. That is fleet work, not a measured fixed duration.

**Portal:** APIM > Custom domains > Gateway; install the approved certificate,
create the DNS record through its owner, and verify TLS before distributing the
custom URL. The wizard's `custom` choice does not configure DNS or certificates.

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

**If the answer is yes, this repository does not supply a verified multi-region
governed solution.** Classic Premium has multi-region, but its policies do not
parse Anthropic tokens as required here. Do not select it as a drop-in fix.
Design and test regional failover and quota semantics separately; a custom
domain preserves address flexibility, not counters or a global budget.

**Portal verification:** APIM > Overview > Pricing tier and Availability zones.
The pricing-tier name alone is not evidence of a regional failover design.
See [Scale](SCALE.md#two-things-to-get-right-on-the-first-day) and U9.

---

## The one that blocks the scaling work

### 3. If you remove someone, how long may they keep working?

**Default today:** the named-value install changes only when a sync publishes.
It has no lease-based revocation bound if sync stops. On the optional projection,
`entitlement-cache-seconds` defaults to 3600, but cache is clipped to an absolute
lease of at most 7,200 seconds from directory scan start.

Under healthy sync, removal takes effect after reconciliation plus the smaller
of cache duration and remaining lease. A stopped projection sync eventually
causes `503`, not indefinitely stale access. Existing streams are not interrupted.

Read-path cost is computed by `./scripts/Measure-ClaudeProjectionCost.ps1
-Developers 500000 -DailyActive 50000 -AlwaysReadyInstances 2`, not quoted as a
complete operating bill. Current at-rest cost is $91.56/month; hourly lease
renewal at this size adds about 365 million writes/month, approximately
$538/month at the measured create charge (derived). See the
[2026-09-24 P19 record](STATUS.md#where-p19-stands-2026-09-24).

**Portal:** APIM > Named values > `entitlement-cache-seconds`; the sync owner
sets the scan schedule and lease. Cosmos > Data Explorer, from an authorised
private-network client, can inspect `lastVerifiedAt` and `expiresAt`.
Do not lengthen a cache setting to hide an expired projection. Verify removal
with a real request and the [projection checks](SECURE-PROJECTION.md#verify).

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
**Portal:** APIM > Pricing tier can show available in-place changes. Review the
current supported upgrade path before approving it; [Scale](SCALE.md) separates
the tier decision from the storage and traffic limits.

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

**Default today:** a unit with no entry in `bu-modes` is **strict**. The shipped
policy also supports **allowance** (base plus an integer percentage) and
**notify** (no blocking limiter at that unit/team scope). Parent, organisation
and personal controls still apply independently.

The installer's legacy `report` / `stop` prompt does not select these per-unit
modes. Its `report` answer is not proof of notify behavior; the installer
preserves the existing map. Configure the desired mode explicitly through
[Business units](BUSINESS-UNITS.md#budget-modes) or the configured Turnstile
authority, then verify the applied named value and response behavior.

Enforcing budgets are set in dollars and enforced by counting tokens, and the counter
**cannot see cached tokens**. The retained U12 sample attributes **38.7%** of
cost weight to cache reads ([UNKNOWNS.md](UNKNOWNS.md)); it is evidence of a gap,
not a ratio to apply to every deployment.

So a $2,000 limit permits far more than $2,000 of real spend. Two honest ways to
handle that:

- treat the dollar figure as **reporting**, and use the per-developer daily
  limit as the thing that actually stops a runaway; or
- divide the token figure by **your own** measured ratio — read it from the
  chargeback workbook, including its missing-category and metric-limit caveats.

Say "we can attribute the cost" rather than "we can cap it". Today the first is
true and the second is not.
**Portal:** inspect the configured authority in [Turnstile](TURNSTILE.md), or
APIM > Named values > `bu-registry` and `bu-modes`. Verify the next request and
the reported budget, not just the label on an installer prompt. Notify's notice
is advisory on each applicable response, not proof the budget was crossed.
Switching back from notify does not backfill the skipped monthly counter;
use the ledger for reporting ([ADR-0019](adr/0019-budget-enforcement-modes.md)).

### 7. Can everyone use the most expensive model?

**Default today:** yes. `models-standard` and `models-premium` are both empty,
which means every deployed model is allowed in both tiers.

Opus is two and a half times Sonnet on both input and output. This is the
largest single cost lever available, and it is the only one caching cannot
defeat.

```powershell
./scripts/Set-ClaudeTier.ps1 -Tier standard -Models claude-sonnet-5
```

**Portal:** APIM > Named values > `models-standard` > Value
`,claude-sonnet-5,` > Save. Verify the deployment exists and test as that tier;
an empty list allows all deployed models. [Models](MODELS.md) covers the lifecycle.

### 8. Can somebody with no team assigned still use it?

**Default today:** yes — `bu-unassigned` is `allow`. Their usage is served and
recorded, and charged to nobody.

Switch it to `deny` once every developer has a team, not before, or you will
refuse people who have done nothing wrong. `./scripts/Get-ClaudeBusinessUnit.ps1`
reports how many are still unassigned.
**Portal:** APIM > Named values > `bu-unassigned` > Edit. Confirm no unintended
unassigned developers in the workbook before switching to `deny`.

---

## The scope question

### 9. How many developers are you actually planning for?

This decides how much of the scaling work is worth doing.

| Planning for | What you need |
|---|---|
| Up to about 90 | The default named-value path, subject to actual identifier lengths and measured headroom |
| A few hundred | The entitlement store, and Standard v2 to run it |
| Thousands | The above, plus measured request/token rate, streaming concurrency and Foundry quota; included monthly requests are not an RPS guarantee |
| 500,000 | Storage was tested at this record count, not a complete production deployment. Scheduled Graph scans, traffic and failover still need verification |

`./scripts/Measure-ClaudeCeiling.ps1` reports where your own gateway is against
the first of those.
**Portal:** APIM > Named values shows list lengths; [Scale](SCALE.md) explains
how to calculate headroom and the measurements a capacity claim requires.

## Next steps

[Setup](SETUP.md) for deployment, [FinOps](FINOPS.md) for financial close, and
[Private projection](SECURE-PROJECTION.md) for the optional store.
