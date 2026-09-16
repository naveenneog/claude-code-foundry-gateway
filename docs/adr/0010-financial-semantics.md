# ADR-0010: Financial semantics — an internal tariff, priced in decimal, versioned by time

- **Status:** Accepted
- **Date:** 2026-09-16
- **Packet:** P20b
- **Deciders:** claude-code-foundry-gateway maintainers
- **Blocks:** P21 (dollar budgets), P23 (showback reporting). Neither should be built before this
- **Related:** [U2](../UNKNOWNS.md) cost reconciliation, [U13](../UNKNOWNS.md) categorised enforcement

## Context

Money code that is wrong is worse than no money code, because the output looks authoritative. This
settles the questions that have to be answered the same way in every place a figure is produced,
before anything computes a dollar.

Everything below rests on measurements already recorded in this repository rather than on a pricing
page:

| Measured | Value |
|---|---|
| List price per million tokens, 2026-09-15 | Opus 5 and 4.8 in $5 / out $25; Sonnet 5 in $2 / out $10; Haiku 4.5 in $1 / out $5 |
| Cache rates | Multipliers of base input: read 0.1x, five-minute write 1.25x, one-hour write 2x |
| Data zone | US Data Zone Standard carries 1.1x. The response body exposes `inference_geo` |
| Azure meter | One aggregated Claude Consumption Unit meter, 100 CCU = $1.00 |
| Quota counter | Counts prompt and completion only. Two identical calls, one writing 10,003 cache tokens and one reading 10,003, were both metered as **16** |
| Cache share of cost weight | 38.7% over thirty days on the reference gateway |

## Decisions

### 1. An internal tariff, not actual Azure cost

Figures are computed from token counts at a published list price held in this repository. They are
**showback**, and every surface that prints one says so.

Actual-cost chargeback is not available: Azure bills Claude through a single aggregated CCU meter
with no per-user or per-model split, and private-offer discounts are applied before that conversion.
A customer who wants invoice-accurate chargeback has to supply their negotiated schedule as a price
book. That is **U2**, and it is blocked by this subscription exposing no cost data rather than by a
design choice.

### 2. All five token categories are billable, and they are not added together

| Category | Rate |
|---|---|
| Input | base input |
| Cache read | 0.1x base input |
| Cache write, five minute | 1.25x base input |
| Cache write, one hour | 2x base input |
| Output | base output |

The price book stores **input and output per model** and derives the three cache rates. Storing five
independent numbers per model invites them to disagree with the multipliers.

The reference defines total input tokens as the sum of input, cache creation and cache read, so a
naive sum double-counts. Categories are priced separately and never summed before pricing.

**Enforcement remains a single blended token figure**, which is what P21's acceptance criterion
calls insufficient, and is why P21 stays open. Reporting is categorised; enforcement is not. That
gap is **U13** and is stated wherever a budget is shown.

### 3. Price the deployment, not the alias the client sent

A client sends a model name. What was served is the **deployment**, and the two can differ — an alias
can be repointed. Pricing joins on `DeploymentName` from the ledger, with the model name kept for
display only.

Requests are also priced with the `inference_geo` multiplier that applies to them, not a
deployment-wide assumption, because a data-zone deployment is 1.1x.

### 4. Decimal arithmetic, rounded once, at the end

Money is `decimal`. Never `float` or `double`: a rate of 0.000002 per token accumulated over
millions of tokens in binary floating point does not reproduce, and a chargeback figure that changes
between two runs of the same query is unusable.

| Rule | |
|---|---|
| Intermediate values | Full precision, unrounded, stored unrounded |
| Presentation | Round half away from zero, 2 decimal places |
| Rounding happens | Once, at the boundary where a number is displayed or exported |

Rounding per request and then summing produces a different total from summing and rounding once. The
second is correct and is what every surface does.

### 5. The price book is versioned by effective interval

Each entry carries `[effectiveFrom, effectiveTo)` per model and geography. A request is priced by
the book **in force at the request's timestamp**, never by today's book.

Without this, a price change silently rewrites every historical report, and a month that was signed
off stops reconciling to itself.

### 6. UTC, and one month boundary

Periods are UTC. The API Management quota renewal period and the reporting month must be the same
boundary, or a developer's allowance resets on a different day from the month they are charged for.

A local-timezone month is two different months in a tenant with offices either side of a date line.

### 7. The ledger is append-only; corrections are new rows

Late events, retries and restatements do not edit history:

- A retried request that was served twice is two rows, because it cost twice.
- A correction is a new row carrying the identifier of what it corrects.
- A restated period is identifiable as restated, so a report run twice over the same window can
  explain why it changed.

### 8. "Soft cap" means approximate blocking, not warn-only

This is the one most likely to be misread. Finance commonly reads *soft cap* as **do not block**.
Ours **does** block — approximately, with overshoot, because the counter is distributed and
observation lags.

So the term is not used on its own. Every surface says which of the two it means, and the overshoot
is stated rather than implied. The delayed kill switch in P25 is named for what it is for the same
reason: it is not a hard cap, and a genuine hard cap needs admission-time reservation.

## Consequences

+ P21 and P23 can be built against a settled set of rules instead of each inventing one.
+ Historical reports stay stable across a price change.
+ The gap between what is reported and what is enforced is stated, not discovered.
− Showback only, until a customer supplies a negotiated price book. That is honest rather than
  satisfying.
− A versioned price book is more machinery than a constant, and it is the only thing that keeps last
  quarter's number the same next quarter.

## How we would know this was wrong

If operators consistently ignore the list-price caveat and treat the figure as an invoice, the
caveat is in the wrong place or the number should not be shown at all.

If the decimal rule never matters — if no one ever reconciles two runs of the same query — it was
more care than the problem needed. The cost of being wrong in the other direction is a chargeback
argument with no way to settle it.
