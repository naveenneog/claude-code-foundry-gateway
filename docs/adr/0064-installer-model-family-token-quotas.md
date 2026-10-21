# ADR-0064: Installer-generated model-family token quotas

**Status:** Proposed
**Date:** 2026-10-19
**Packet:** P118

## Context

API Management Basic v2 supports `llm-token-limit` for Anthropic Messages. Its
quota and counter key accept policy expressions, but it counts prompt and
completion tokens rather than cache tokens and concurrent calls can overshoot.
The installer already knows the selected deployments and the repository holds a
dated list-price book.

The existing daily tier quota is one token total. It cannot distinguish a
cheaper Haiku request from a more expensive Sonnet or Opus request. The
reconciled USD stop prices more categories, but it is delayed and depends on a
fresh reconciliation state.

## Decision

1. `StandardMonthlyUsd` and `PremiumMonthlyUsd` are optional per-developer
   installer inputs. Zero disables this additional control.
2. Selected deployment metadata determines each canonical family. The allowance
   is divided equally among distinct allowed families.
3. Each family uses the highest blended input/output list rate among its
   selected deployments. The output share defaults to 20 percent and is
   recorded with the generated plan.
4. An unpriced selected model refuses conversion. Missing price is unknown
   cost, never zero cost.
5. The canonical named value is a comma-delimited map containing exact
   deployment-family mappings followed by quotas:
   `,deployment:fast=haiku,standard:haiku=123,standard:sonnet=456,`.
6. APIM applies the matching monthly quota with a counter key containing Entra
   object id, tier and model family. Existing budget policies remain independent.
7. Installer reruns preserve the named value unless either monthly USD input is
   explicitly supplied. Output share alone cannot rewrite the map.
8. A tier with no quota entry is disabled. Once a tier has an entry, an allowed
   family that is absent, duplicated, malformed or non-positive returns 503
   until the installer recalculates the canonical map.
9. The PowerShell installer answers schema, guided flow and browser installer
   expose both tier allowances and the output-share assumption; guided-flow
   answers preserve them through installer launch. Bash installer parity is
   outside P118; the answer schema marks these fields as unsupported by Bash.

## Consequences

+ Expensive families receive fewer tokens for the same allocated dollars.
+ The approximation is visible before deployment.
- The limits remain soft token caps and do not count cache tokens.
- Equal family allocation may not match the customer's actual traffic mix.
- The quota inputs are not available through the Bash installer in P118.

## Alternatives considered

**Use `max_tokens` in each request.** This limits one response, not cumulative
monthly use.

**Give every family the full tier allowance.** Using several families could
consume the allowance once per family.

**Replace the USD reconciler.** Token quotas omit cache categories. They are an
additional fallback, not invoice-accurate dollar enforcement.
