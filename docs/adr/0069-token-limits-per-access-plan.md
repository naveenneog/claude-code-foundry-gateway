# ADR-0069: Token limits per access plan from its dollar credit

**Status:** Proposed
**Date:** 2026-10-22
**Packet:** P123

## Context

The access catalog ([ADR-0062](0062-cosmos-access-profile-catalog.md)) has
nine plans with nominal monthly credits from USD 50 to 5,000. Model-family
token limits ([ADR-0064](0064-installer-model-family-token-quotas.md)) were
keyed only on the standard and premium compatibility tiers, so every plan in a
tier shared one limit. The customer asked for limits that follow each plan's
dollar value, enforced as tokens rather than as a dollar stop, with cache reads
estimated. Each projection record already carries `planId`, which the policy
reads (`infra/policy.xml`, `entPlanId`).

## Decision

1. `model-family-quotas` may hold `plan:<planId>:<family>=<tokens>` entries next
   to the tier entries. When the caller's `planId` has entries, the policy uses
   them and counts per user, plan and family. Otherwise it uses the tier, as
   before. A family the plan does not list is a configuration fault (503).
2. `scripts/Set-ClaudePlanTokenQuotas.ps1` computes the entries from the access
   catalog file, the Foundry deployments and the price book, and writes them
   with a read-back. `-WhatIf` prints the table only. The installer keeps the
   entries on a re-run.
3. Each tier is one profile of the customer's sheet (level, model set and
   credit), converted to one catalog plan by
   `scripts/ConvertTo-ClaudeAccessCatalog.ps1`, so Standard-L3 with and
   without Opus are separate tiers. A tier's credit is split equally across the
   model families of its model set. Each share is divided by the rate per
   counted token of the family's price model: by default Haiku 5.5, Sonnet 5.5,
   Opus 5.5 and Fable 5.1 (`-PriceModels`). List prices per million, read from
   [Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing) on
   2026-10-22: Haiku 5.5 input 0.50, output 2.50, cache read 0.05 for prompts over
   100,000 tokens (the default, `-Haiku55PromptTier long`) or 0.10 / 0.50 / 0.01 up
   to 100,000 (`standard`); Sonnet 5.5 2 / 10 / 0.10; Opus 5.5 4 / 20 / 0.20; Fable 5.1
   10 / 50 / 0.25. A sheet profile's `tokensPerMonth`, when set, replaces the
   derived figure and is split equally across its families.
4. Rate per million counted tokens: `(1 - output share) x (input rate + cache
   ratio x cache-read rate) + output share x output rate`, where cache ratio =
   cache-read share / (1 - cache-read share). APIM counts uncached input and
   output tokens, not cache reads, so the cache-read spend is folded into the
   rate. Defaults: output share 0.2 and cache-read share 0.5 of input tokens,
   both configurable (`-OutputShare`, `-CacheReadShare`).

## Consequences

- Limits scale with plan credit: a USD 100 plan gets twice the tokens of a USD
  50 plan for the same families.
- The limit approximates the dollar value; it is not a dollar cap. Real cache
  reads, output share, streaming estimates and concurrent requests move spend
  around the credit. The dollar stop remains the reconciled USD budget
  ([ADR-0026](0026-usd-budget-reconciliation.md)).
- Haiku 5.5 stays out of the shared price book, so dollar budgets still refuse it
  as unpriced (U178, [ADR-0060](0060-usd-reconciler-attribution-and-pricing.md)).
  Only these token limits use its rate; the long-prompt default errs low for
  short prompts.
- The 31 entries for the customer's 11 tiers fit the 4,096-character named
  value. The script refuses a value that does not fit.
- Changing a plan's credit or families, the deployments or the price book needs
  the script to run again.
