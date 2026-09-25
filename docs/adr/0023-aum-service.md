# ADR-0023: Optional AUM authority, independent of Turnstile

- **Status:** Accepted
- **Date:** 2026-09-24
- **Packet:** P55; P47 workflows for the AUM service
- **Decider:** Platform owner

## Context

AUM Direct uses the operator's Azure RBAC privileges. Azure RBAC cannot express
"may change only these teams". Turnstile is a separate, optional FinOps tool,
not a dependency of AUM. The owner commissioned P55 in an isolated worktree
and reserved the shared ledger and client for other agents. This ADR reconciles
the parallel assignment with the single-packet charter: ledger proposals and
the five-seat verdict go to the delivery report; no gate is weakened.

## Options

| Option | Consequence |
|---|---|
| Direct only | No infrastructure cost, but only Azure administrators can use it safely |
| Require Turnstile | Reuses its authority, but violates independent tool choice |
| AUM on App Service/PostgreSQL | Familiar, but introduces an unnecessary always-on database |
| Functions Flex Consumption and Storage | Python, scale to zero, Entra-only storage; explicit cold-start choice |

## Decision

An optional Python Functions app has a bearer-token HTTP API and a minute timer.
It never proxies model traffic or changes the gateway policy or network.
The gateway remains the enforcement point. Budget modes remain strict by default.
An AUM app registration exposes `AUM.Access`, pre-authorizes Azure CLI, requires
assignment and emits only application-assigned groups. Its roles are
`AUM.Admin`, `AUM.Viewer`, and `AUM.Manager`, in that precedence. Only delegated
people with an assigned role enter; developers have no service sign-in.

Validate a v2 token's signature, pinned tenant issuer, audience, expiry, object
identity, delegated scope and role. Never follow a token-supplied key URL or
groups-overage URL. Overage grants no group-based scope. `/me` mirrors
Turnstile's `manager_scope`: null is unrestricted, any object is scoped.
Unit managers see their teams and direct members; team managers do not acquire
their parent unit's scope merely because its name is displayed.

The named values remain the single budget/catalog/tier/mode format. Python
serializers must match fixtures executed by the PowerShell serializers byte for
byte. Malformed values and values beyond 4,096 characters fail closed. No
manager mappings, approvals, audit history or boost records enter named values.
Those live in the service's Table storage. Analytics use the existing saved
functions, with server-side scope predicates and bounded, keyset-paged results.
No Graph directory scan or 500,000-person list is loaded into an HTTP worker.

Use a gateway-wide storage lease, fresh reads, conditional ARM writes,
read-back and compensating rollback. Record durable audit intent before every
mutation and its result afterwards. A failure to audit refuses the mutation.
External writers are not made transactional by this lease: ETags detect their
conflicts; rollback never overwrites a later independent write.

Headroom is an allocation constraint, independent of strict/allowance/notify:
children cannot reserve more than a finite parent's remaining allocation.
Monthly team and daily person budgets are not compared as if periods matched;
person overrides reserve 31 times their daily amount, so a longer next month
cannot silently consume unallocated headroom. A unit
manager may edit its teams, any manager may edit people in scope, and only an
Admin edits units, catalog, tiers or modes.

Requests route one level up; self-approval is refused by default. Approvals recheck scope and
headroom at decision time. Escalation moves toward the administrator.
Boosts retain the previous value and an expiry. The timer retries overdue
records on subsequent ticks, using compare-and-restore rather than overwriting
a newer administrator edit. Warning records are idempotent per budget, UTC
period, threshold, usage basis and nominal limit version. A changed limit
rearms; restoring the same limit reuses the fact. Versioned facts carry exact
decimal usage, exclusive UTC period bounds and source, but no addresses or
transport state. Email delivery is not implemented.

## Evidence and unknowns recorded before implementation

| State | Evidence or assumption | Detector |
|---|---|---|
| DOCUMENTED | `New-ClaudeTurnstileEntraApp.ps1` and TURNSTILE's consent-free CLI journey prove app-owner registration and CLI pre-authorization without tenant consent | Live token acquisition |
| DOCUMENTED | `turnstile-scoping/backend/http/{manager_scope,session,authentication}.py` defines role and scope behavior | Scope and API negative tests |
| DOCUMENTED | `ClaudeBusinessUnit.ps1`, `ClaudeBudgetModes.ps1`, `Set-ClaudeBudget.ps1` own the registry formats | Cross-language fixtures and drift mutation |
| DOCUMENTED | [Flex deployment](https://learn.microsoft.com/azure/azure-functions/flex-consumption-how-to#deploy-your-code-project) requires Python remote build; deployment storage supports managed identity | Live deployment and app-settings inspection |
| DOCUMENTED | [Timer connections](https://learn.microsoft.com/azure/azure-functions/functions-bindings-timer#connections) require Storage Blob Data Owner for identity-based host storage | Timer expiry test |
| DOCUMENTED | `ClaudeTurnstileApply.ps1::Set-ClaudeGovernanceWriterRole` defines the narrow named-value writer role | Role-action allow-list test |
| ASSUMED | Public Entra-only Functions and Storage are permitted by the target subscription's policies | ARM what-if/deployment; report policy denial rather than weaken controls |
| ASSUMED | Retail meters in the discovered region price optional warm instances, redundancy and telemetry | Live Retail API; unknown is never zero |
| RESOLVED 2026-09-25 | Full live manager journey changes shared group membership | Lead-approved team/unit Manager-only proof; fresh Admin and exact directory/configuration restoration verified at 03:45:17Z |
| OPEN | 500,000 observed developers with the current Log Analytics query envelope | Bounded-query tests; no claim of measured full-directory latency |

Sources retrieved 2026-09-24. Measured outcomes belong in the guide and delivery
report, not in this pre-implementation evidence table.

## Operations and limits

The administrator chooses Direct, this service, Turnstile, or Turnstile with
AUM as a client. The deployment summary prices every infrastructure choice
before approval: zero/one always-ready instance, LRS/ZRS/GRS, telemetry and
public Entra-only/private endpoints. Private deployment requires connected
clients, VNet integration and private DNS; private endpoints have a fixed bill.
Do not modify a discovered shared storage account or Function plan to fit.

Managed identity receives only the gateway's custom named-value role,
Log Analytics Reader on its workspace, and Blob/ Table data roles on its own
storage. Shared-key and basic publishing authentication are disabled.
Identity assignment and storage RBAC propagation are deployment prerequisites,
not excuses to introduce keys.

The current registry and per-person overrides still have the gateway's 4,096
character ceiling. Paging 500,000 observed people does not imply 500,000
individual named-value overrides are possible. Projection-backed budgets and
a cross-tool single writer remain P48. At capacity, edits return an explicit
conflict; they never truncate, widen scope, or silently stop enforcing.

## Live findings and bounded refinements

- **Measured:** the tenant modifies newly created Storage accounts to disable
  public network access. The public-storage shape cannot deploy there. Offer an
  explicit public-API/private-storage choice, priced separately; do not weaken
  storage policy or enable a key. A new isolated VNet requires an administrator-
  selected address range and never peers or modifies the gateway network.
- **Measured:** private endpoints, DNS links, VNet integration and correct data
  roles alone still produced `InaccessibleStorageException` during OneDeploy.
  Explicit `outboundVnetRouting.allTraffic=true` made the same keyless deployment
  succeed. Persist that property with the
  [2025-03-01 site schema](https://learn.microsoft.com/azure/templates/microsoft.web/2025-03-01/sites).
- **Decision:** managers can never self-approve. An Admin, who already has direct
  budget-writing authority, can explicitly choose `admin_override: true` on a
  request decision, with a reason. It is false by default, cannot be claimed by a
  Manager, is flagged in the resulting record and audit, and never bypasses
  headroom. This supports a single-administrator non-production installation
  without pretending that it supplies independent two-person approval.
- **Measured:** the copied portal session required sign-in on the Entra blade.
  Capture stopped. Existing resource screenshots are not evidence of an Entra
  UI journey; CLI registration and token evidence are recorded separately.
- **Measured, 2026-09-25:** a real manager-only person-budget call exposed a
  Kusto syntax error in the observed-membership lookup: `latest` cannot be an
  unquoted `let` binding. The same bounded query with `last_observations`
  returned the last real request's team. Keep the timestamp/tie-denial logic,
  add a regression against the rejected binding, and verify the deployed
  manager write; mocked analytics alone did not prove query compilation.
- **Measured, 2026-09-25:** APIM returned 500 when budget-trace `Notice` or
  `ParentUnit` metadata was empty: `The value field is required.` Use the
  nonempty sentinel `none` only for absent values. Tests compile the actual
  policy expressions. The lead-authorized dedicated gateway then served real
  Claude requests under strict/allowance/notify; the original test policy and
  all named values were restored. The service still never edits gateway policy.
- **Verified, 2026-09-25:** fresh team-only and unit-only Manager tokens proved
  positive person/team writes and four 403 boundaries. Recovery restored the
  original Admin authority, all 14 memberships and 22 direct assignment tuples,
  catalog and named values; all three temporary groups were independently absent.
  This was HTTP/API proof, not a native AUM-client journey.
- **Harness contract:** publish test membership before probing attribution, but
  restore the exact saved `ClaudeCost` properties in `finally`, even if catalog
  cleanup fails. Regenerating a query is not snapshot restoration across days.
  Offline tests execute the actual restoration request against an original-date
  fixture. The live receipt separately verified authored-field equality.
- **Measured cleanup:** generic `az resource delete` failed without deleting a
  recorded private endpoint. The network-specific `az network private-endpoint
  delete --ids` succeeded for that same endpoint. Use the scoped provider
  operation before DNS deletion, covered by the cleanup regression.
