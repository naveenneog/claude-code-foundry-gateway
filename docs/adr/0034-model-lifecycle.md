# ADR-0034: A reviewed model change reconciles tiers, prices and client records

## Status

Accepted for implementation in P70, 2026-09-28. The lead owns council review and merge.
Amended for the first council review on 2026-09-28: complete renderer inputs, raw deployment
validation, persisted initial tier selections and retirement cleanup.
Extends [ADR-0030](0030-guided-flow.md); preserves the client rules in
[ADR-0031](0031-client-keys-every-release-reads.md).

## Context

Deploying a Claude model in Foundry does not change API Management's `models-standard` or
`models-premium`, the installer's deployment record, the price book or an installed client.
`Add-ClaudeModel.ps1` changes one model's lists and price, but does not reconcile the record or
profiles and takes one resource group for both services. The owner has deployments which the
reference gateway does not allow. That gateway remains read-only during this packet.

The lists contain deployment names, not necessarily catalogue model names. Empty lists mean
allow all in `infra/policy.xml`. The price book's `claude-haiku-4.5` is a different key from
the deployed `claude-haiku-4-5`. The published Opus 5.5 cache-read multiplier is 0.05x, unlike
the 0.1x currently used by the accelerator's financial readers (U34).

## Options

1. Extend the single-model add command. Its immediate writes and one-group target do not
   implement the flow's review, snapshot and fingerprint contract.
2. Reinstall the gateway. That changes more than model access and can overwrite other choices.
3. Add one Change-only model reconciler, shared by the flow and a standalone command, using
   the existing deployment normaliser, named-value writer, backup and client renderers.

## Decision

Option 3. `scripts/Sync-ClaudeModels.ps1` and `scripts/flow/Models.ps1` share the model
lifecycle helpers. The flow's decision key is `models`; Setup does not run this step.

### Discovery and selection

The target contains the subscription, API Management name/group and Foundry name/group.
Every Azure call carries an explicit subscription; names passed to `az.cmd` are validated.
The API backend must match the selected Foundry account. Failed or malformed discovery is an
error, not an empty deployment list or permission to remove a deployment.
Raw deployment rows are validated before publisher filtering: each has an object identity
with a nonempty string deployment name, model name, publisher format and version. A malformed
row, even beside valid rows or from another publisher, makes the inventory unreadable.
The installer uses the same validation and reports a failed Azure command rather than
interpreting its result as an empty account. With no existing or explicitly pending Claude
deployment, it stops. A tier selection that normalizes to no deployment names also stops
before provisioning; it cannot become an implicit unrestricted list.

Discovery uses the existing Claude deployment normaliser and filter, then shows name, model,
version, SKU, capacity, provisioning state, current tiers, record presence and price status.
A new deployment needs `standard`, `premium`, `both` or `none`; an existing one defaults to
`keep`. A missing deployment offers `keep` or `drop`, and is never silently removed. A model
not in `Succeeded` cannot be newly allowed. No Foundry deployment is created or deleted here.

Standalone callers use `-TierAssignments @{ '<deployment>' = '<choice>' }`, or `-AnswersPath`.
The flow uses `models.tiers.<deployment>` answer keys. A period in a deployment name is encoded
as `~` in that question key because the flow treats periods as path separators; the Azure
deployment name itself is unchanged. `models.priceBookPath` can select a private dated book.
Unknown choices, duplicate deployment identities and unknown assignment keys are refused.
Completed `drop` decisions remain in the decision record, so the same answers file can be
reused after the deployment has disappeared from both lists. The installer accepts explicit
`-StandardModels` and `-PremiumModels` for an unattended initial subset and rejects unknown
deployment names before provisioning.

Removal which would empty a restricted tier is refused: writing `,,` would grant access to
all models, not revoke access. An already unrestricted tier is stated as such and is never
silently converted to a deny-all claim.

### Review, snapshot and apply

The canonical flow fingerprint binds the target, discovery, assignments, record inputs, price
book and output locations. Monthly inference cost is unknown without token volume; the
review shows dated per-million input/output rates separately. Unpriced is never zero.
`-PlanOnly` and `-WhatIf` read only and do not create a backup, price book, record or profile.
The renderer stamp covers the lifecycle/profile writers, the profile generator, its Claude
Code, Desktop and banner helpers, and the flow record serializer. Every file's presence and
content participates in the stamp, at planning and before apply. A helper change therefore
requires a new review just as a generator change does; the dependency list is covered by
source-copy mutation tests. An AST-derived import-coverage assertion follows the profile
generator's dot-sources transitively and compares that closure with the paths the stamp
function actually hashes. A newly imported helper cannot escape both handwritten lists;
unresolved dynamic imports fail coverage rather than being silently omitted.

An optional step preparation hook runs after approval and before the flow writes its local
run journal. Models uses it to recheck discovery and take `Backup-ClaudeGateway.ps1`'s
non-secret named-value snapshot. The standalone command uses the same preparation. Snapshot
failure prevents all managed writes. The apply rechecks relevant state again before writing,
changes only the two model named values through the failure-reporting writer, and reads them
back. Other named values, membership, entitlements, quotas and policies are untouched.
The existing Turnstile governance-authority guard applies to models as it does to
`Set-ClaudeTier.ps1`: a preview remains available, but apply refuses Turnstile-owned tiers.
No ownership switch is implicit. A read-only reference check at 2026-09-27 20:19Z found
Turnstile ownership and two unrestricted lists, unlike the owner's earlier inventory.
The record comparison normalizes schema 1/2 and an absent or empty decisions object:
the installer omits it, and the flow's own run journal introduces it. Other decision
fields still participate in drift detection.

Writes across Azure and the filesystem are not an atomic transaction. A failed write stops
the operation and names the snapshot and the need to replan; no success is recorded.
The next plan reads actual state, so a partially completed change can be finished deliberately.
No automatic rollback overwrites a concurrent administrator's work. Review and readback detect
drift but do not claim a cross-service transaction or an atomic compare-and-swap.

### Prices and records

The existing dated private book is authoritative; when absent, the existing built-in rates
are the starting book. An exact deployment price takes precedence. Otherwise an exact
catalogue-model entry, or one unambiguous dotted/hyphenated numeric-version spelling of it,
can be copied under the deployment name. The copied entry retains its source/date and
mapping. No rate is inferred from a family, newest model, another SKU or a network lookup.
Conflicting normalised entries are refused. Historical entries and unrelated metadata remain.

Opus 5.5 stays unpriced in the shipped defaults. The published base rates are USD 4 input
and USD 20 output per million, but adopting them while assuming 0.1x cache reads would
misprice cached usage. The review names this limitation; an operator-owned price book remains
the operator's financial policy, not a claim of invoice accuracy. Publication of saved
`ClaudeCost` queries and distribution of a book to scheduled reconcilers are explicit
follow-up operations, not silent changes to an existing financial period.

The administrator record's `models` is the union of permitted existing deployments;
`deployments` records their live model/version and preserves existing client overrides and
unknown fields. Each tier also records its own model list. Missing deployments retained in
the gateway lists are reported as unavailable and excluded from the client selection.
The initial installer record has the same per-tier `models` and `modelAllowList` fields,
so profiles generated before the first model Change use the original tier restrictions.

The change regenerates both device profiles with `New-ClaudeCodePolicy.ps1`, using only
that tier's deployments and safe alias fallbacks. Each profile directory also contains a
tier-specific `claude-gateway.json` for the existing Windows and macOS/Linux setups.
The shared DeviceProfiles step reads these tier lists too, so a later Guide does not undo
the model selection. The root deployment record remains backward compatible.

The developer handover names the existing setup/onboarding command with the tier record.
Rerunning setup replaces the model picker (`availableModels`), newest-per-family alias pins,
capability declarations, VS Code model environment and Desktop `inferenceModels`, preserving
unrelated user settings. It does not change entitlement. MDM assignment and workstation
execution remain explicit administrator/developer actions; this command does not remotely
modify devices.
Both workstation implementations remove an owned alias and its capability declaration when
that family is no longer selected, then populate the remaining aliases. The Sonnet fallback
for Haiku is unchanged; unrelated environment variables remain.

Standalone history records the prior model decision and the signed-in principal. Nested
records, profiles and snapshots under `onboarding` are git-ignored just like the top-level
generated files. An explicit subscription scopes both the ARM URI and its access token.

### Progress and propagation

Every Azure read, backup, write, readback and local profile generation prints its purpose
and an estimate before it starts and its elapsed time afterwards. A management-plane
readback is not proof that every gateway has consumed the value. The isolated proof measures
data-plane propagation with bounded requests; no entitlement-cache interval is assumed (U35).

## Consequences

One plan covers tier access and the local client handover, without reinstalling infrastructure.
Two independent tier profiles do not pin a standard user to a premium-only Opus deployment.
New deployments and missing deployments both require review, and price gaps remain visible.

The price book still cannot represent every provider's cache multiplier. Model sync does not
repair that broader financial schema or publish a new tariff into historical reports.
An unavailable last deployment cannot be removed by writing an empty gateway list; entitlement
revocation remains a separate control. The control-plane/data-plane propagation interval is
measured, not promised as immediate.

## References

- Anthropic, Pricing, retrieved 2026-09-28:
  <https://platform.claude.com/docs/en/about-claude/pricing>
  (Opus 5.5 USD 4/20 per million; cache reads 0.05x; Haiku 4.5 USD 1/5;
  Foundry bills standard per-feature rates through CCUs, subject to agreement discounts).
- Microsoft Learn, Use named values in Azure API Management policies, retrieved 2026-09-28:
  <https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties>
  (plain named values used in policy; the documented four-hour refresh is for Key Vault
  secret rotation, not these plain model lists).
