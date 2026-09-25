# ADR-0021: Architecture diagrams are source-backed, rendered and checked with every feature

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** Architecture generation, explicitly assigned by the owner alongside the active feature work
- **Deciders:** repository owner

## Context

The owner requires an architecture generation task after every feature. The existing
concept article and two README images do not describe Turnstile, delegated managers,
the projection or terminal FinOps. The request sheet's assertion that no database,
processor or queue is added is only defensible for the default profile.

The repository already has Playwright screenshot tooling and a deterministic HTML
request sheet. Identifiers must match code; the images must contain no real tenant
identities or resource names. Two features are being built in separate worktrees,
and delegated management is implemented in a separate Turnstile fork.

## Options considered

1. **Manually maintained images.** Flexible, but cannot establish source freshness or
   reliably detect missing feature pictures.
2. **Mermaid plus a new pinned npm dependency.** Native GitHub diagrams are useful, but
   the existing six-hop sheet and carefully grouped identity/network boundaries would
   still need a second layout mechanism. Automatic layout can shift labels on updates.
3. **One JSON spec per deterministic HTML/SVG diagram, using existing Playwright.**
   Chosen. Text wrapping and explicit coordinates keep exact names readable, the
   existing request sheet can remain a six-hop diagram, and no new package is required.

## Decision

`node guide/render-architecture.mjs` discovers all specs under `docs/architecture`,
validates them, renders PNGs at device scale factor 2, checks text overflow and writes
`manifest.json`. Canonical images live under `docs/images/architecture`; the two
existing README names remain byte-identical copies.

Specs bind code labels to implementation files and exact witnesses. The manifest
hashes source, shared rendering code, the lockfile, implementation inputs and PNG
bytes. Text hashes normalize line endings so Git checkout conversions do not invent
drift. A separate offline checker validates image ownership, document references,
identifier witnesses and an explicit rendered inventory of every resource type
declared in the repository's Bicep.

External implementations are not silently treated as local code. Turnstile and the
unmerged CLI carry pinned repository/commit/path witnesses in the spec. When a pending
file from this repository becomes local, it is preferred over its snapshot, which
requires a new render. Fork changes require review and repinning; the offline gate
does not claim to monitor a remote branch.

`Test-Architecture.ps1` runs the checker and destructive mutations only in a uniquely
named scratch copy under the checkout. It is part of `Test-All.ps1`. Every feature
packet that changes a component, data flow, identity, schedule or network path updates
its source, regenerates images and updates the concept article.

## Consequences

- Adding a picture is one spec file and a document reference, not a renderer edit.
- An implementation edit to a declared input invalidates its pictures even if the
  label still exists. A new Azure type cannot disappear into prose-only documentation.
- The default, projection and Turnstile profiles explicitly state what they add.
- Layout work remains human-reviewed. Hashes prove provenance and freshness, not
  semantic accuracy. Review every changed picture at normal viewing size.
- Pixel output is deterministic for the same locked browser/font stack. Different
  operating-system fonts can produce different pixels; the committed manifest does
  not require CI to render with the same host fonts.
- The lead owns STATUS, ROADMAP, CHANGELOG and UNKNOWNS and records the packet and
  review receipt when merging. This worktree supplies proposed entries, not competing
  ledger edits.

## How we would know this was wrong

An unrendered source, an orphan image, a removed code label or a new Azure resource
type passes the tests; a source can read/write outside the checkout; a rendered
caption loses an identifier; or adding an ordinary feature diagram requires changing
the generator. Each is a regression, not a reason to weaken the check.

## Terminal integration and AUM naming

The terminal implementation merged to main at `c7f0a29`. Importing it invalidated the
old terminal diagram manifest because the checker found the local implementation instead
of its pinned snapshot. The regenerated diagram now binds implementation labels directly
to local source files and links to ADR-0018 and `docs/CLI-FINOPS.md`.

The owner named the product AUM - Azure Usage Management, with command `aum` and a deprecated
`claude-finops` alias. The entry points were verified on branch `aum` at `a1f0836` and
recorded as naming evidence; this architecture uses the new name while explicitly stating
that the naming packet is not yet integrated. The terminal SVGs under `docs/images/finops`
remain snapshot baselines, outside the architecture-orphan check's scope.

## Pending P50 resource declarations

The pushed chargeback-reports implementation at `d1a304f` is drawn without importing or
editing that packet's runtime files. Its diagram carries pinned code witnesses, including
five additional Azure resource types. A visible `kind: "resource"` identifier may satisfy
resource coverage when its source contains a real Bicep declaration. Comment text and
undrawn metadata cannot satisfy that contract. This allows a feature to add its flow and
resource types in one spec while keeping the existing inventory useful.

Pinned external types are not claimed as declarations in the current local checkout.
When P50 is merged, local Bicep and scripts replace the snapshots, invalidating the old
manifest and requiring review and regeneration. This is the same adoption rule used for
the terminal implementation, not a separate renderer or an exception to drift checking.

## Live evidence and discovery

The owner's standing requirement adds live, redacted evidence and portal/CLI inspection
paths beside the concept diagrams. Keep live screenshots under `docs/images/architecture-live`,
separate from deterministic diagram outputs. Discover selected Azure resources; no tenant,
subscription, gateway, workspace or hostname is a checked-in default.

The capture tool uses only the copied worktree profile, stops on a visible sign-in page,
waits for actual content in visible portal frames, and stages captures privately.
Display redaction must not alter hidden OAuth fields, passwords, textarea/select values
or application input values. Sensitive input pixels are overlaid, not rewritten.
Only individually reviewed image ids can be published, with hashes and identifier-free receipts.

The live pass proved a small authenticated request and log/trace join, Owner sign-in and
single-use code replay refusal, and read-only terminal views. It also exposed a stopped
console database, a projection 503 and a pending governance difference. The coverage
table records what was not exercised. Neither a screenshot nor an offline gate may
silently convert these limits into a claim that every flow passed live.

## Current main and check cost

The integration follows current main at `fc98cca`, including the merged budget modes
and ADR-0025's parallel runner. ADR-0025 supersedes ADR-0024's temporary 60-minute
command budget and restores 30 minutes; this packet does not change that budget.

Architecture reads are bounded to the declared source paths, docs and Bicep inventory,
not the whole working tree. Fixtures have unique names in the ignored `.shots-entra`
area and never mutate repository sources or share Azure CLI state, so the one-line
registration uses the normal parallel lane. Repeated source/path reads are cached for one synchronous
check only, including proper cleanup on failure; a later check always starts fresh.
Tests prove that edits and deletions between checks remain visible. No mutation was
removed to improve timing.

## Lead-operated portal batches

The later Conditional Access protocol replaces packet-local portal sessions. Required
shots now live in one versioned `guide/captures/architecture.json` spec, using P53's
discovery-only schema and runtime selections. The guide names every pending id and final
output path; existing earlier images remain dated evidence, and missing new images use
explicit inline pending paths rather than fabricated placeholders.

`capture-architecture-live.mjs` is retired and exits before importing browser code.
Only the lead operates the shared original-profile batch after the owner's fresh sign-in.
Non-portal console evidence remains available through the CLI code flow in an isolated
browser with management writes blocked. Neither path changes the recorded acceptance gaps.

## Subsequent main integration

Main advanced through the P50/P55/P53 and documentation integrations while the batch
handoff was being prepared. The architecture adopts those sources rather than continuing
to describe them as unmerged: P50's discovered network choices and readable administration
JSON, the independent AUM service and its Blob/Table resources, and the canonical P53
batch validator. The service diagram does not imply a completed terminal adapter or a
new live manager test. Service warning/OpenAPI files are explicit diagram inputs so
their contract changes invalidate its rendering.
