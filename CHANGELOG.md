# Changelog

All notable changes to this project are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are tagged in git. `docs/ROADMAP.md` holds the forward plan and
`docs/STATUS.md` the packet currently in flight.

## [Unreleased]

Business-unit chargeback. Budgets are set and reported in dollars, but three
limits apply to every figure here and are repeated in each command's output.

The counter is blind to cached tokens: `llm-token-limit` "currently counts
prompt and completion tokens only", and on thirty days of live usage cache reads
were 6.8M tokens against 320K prompt and 152K completion — 38.7% of real cost
weight at Claude's published rates. Budgets therefore bound less spend than they
appear to, always in the direction of under-counting.

Dollar figures are list price and do not reconcile to an Azure invoice, because
Azure bills Claude as one aggregated Claude Consumption Unit meter and
private-offer discounts apply before that conversion. **U2**.

A budget is enforced as one blended token figure converted at write time,
assuming a 20% output mix. That is what P21's acceptance criterion calls
insufficient, so P21 stays open. Categorised enforcement is **U13**.

### Added

- **AUM developer add/remove.** `aum developer find|add|remove` searches the
  Entra directory with the signed-in administrator's delegated Graph token,
  resolves exact email/UPN/object-id targets including guests, previews tier and
  unit/team group changes, writes membership once, verifies propagation and
  publishes the gateway. `Set-ClaudeDeveloper.ps1` now discovers recorded tier
  group names instead of silently defaulting to fixed strings.
- **AUM (Azure Usage Management), the terminal FinOps client renamed from `claude-finops`.**
  `aum` (the old command still works) adds an executive overview, budgets by unit, team and
  person, gateway governance, usage breakdown and trends, a request trace, anomalies, reports
  through P50's generator, and Entra group find, create, member and delete, each previewed before
  any write. It runs against Turnstile, the gateway directly, the AUM service or example data, so
  it does not depend on Turnstile. Measured live on 2026-09-25 through Direct and Turnstile:
  owned test groups, budgets and all three modes enforced on real requests (strict 403, allowance
  and notify 200 with a notice), then 13 named values restored byte for byte. Clients for server
  features that do not exist yet stay hidden until a server advertises them. `docs/AUM.md`.
- **Governance authored in Turnstile, applied to the gateway on save.** With
  `Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Turnstile`, business units, teams, their Entra
  groups, budgets and tier limits are edited on Turnstile's pages, and each save starts the
  gateway's apply job, a manually triggered Container Apps job beside the hourly one. Measured: a
  tier limit saved on the page was read on the gateway 112 s later, and a budget saved in Turnstile
  refused the next request 123 s after the save. Turnstile's API holds Container Apps Jobs Operator
  on that one job; the job's identity holds a custom role that reads and writes the gateway's named
  values and nothing else. `scripts/ClaudeTurnstileApply.ps1` applies no group it cannot confirm,
  always applies tier limits, never rewrites membership from groups it could not read, reads each
  write back, and refuses a catalog with no business unit. New groups and membership refresh need
  `GroupMember.Read.All` from a tenant administrator, `scripts/Grant-ClaudeGovernanceGraphAccess.ps1`
  (**U17**). [ADR-0015](docs/adr/0015-governance-authored-in-turnstile.md) amends ADR-0014.
- **Managers scoped to their units and teams.** In Turnstile (fork `c0c345a`), a person holding
  only `Turnstile.Manager` sees and manages the units and teams whose manager group is in their
  own token: usage, budgets, people and requests, filtered; a unit manager sets its teams'
  budgets, any manager sets person budgets in scope; every other page and API is refused by
  default. Owners record each unit's and team's manager group and budget mode on the Gateway
  governance page. Migration 012 asks existing Entra members to sign in once again.
- **Viewers, managers, and a sign-in that needs no consent.** Turnstile's Entra application has
  `Turnstile.Viewer` and `Turnstile.Manager` beside `Turnstile.Admin`, created by
  `New-ClaudeTurnstileEntraApp.ps1` as the app's owner, and its tokens carry only the groups
  assigned to it. Viewers and managers sign in read-only; developers never do.
  `scripts/Open-ClaudeTurnstile.ps1` signs a person in through the Azure CLI, which is
  pre-authorized on Turnstile's API: the token is exchanged for a code that works once, within a
  minute. For tenants whose web sign-in has no consent yet (**U19**).
  [ADR-0016](docs/adr/0016-delegated-management.md).
- **A manager sees only their unit, proven live.** With admin access removed for a few minutes, a
  fresh token carried exactly `Turnstile.Manager`; Turnstile scoped the session to one unit and
  its three teams and refused the admin pages, then every membership and assignment was restored
  and verified. On Windows the account broker kept serving the old token; MSAL's
  `set_access_token_to_renew`, behind a helper that fails closed, renews it without deleting any
  cache or adding any grant.
- **Every FinOps tool in one guide.** `docs/FINOPS-TOOLS.md` compares the saved queries and
  workbooks, the scripts, Terminal FinOps, the AUM service, Turnstile, chargeback reports and
  Grafana. It covers who signs in to what and with which method, six end-to-end flows with their
  commands, and a bill of materials from live list prices, with the command that recalculates
  each line.
- **Where a Premium v2 injected gateway's private IP is, measured.** ARM returns it in
  `properties.privateIPAddresses` only at api-versions `2024-05-01`, `2023-09-01-preview` and
  `2023-05-01-preview`, and Resource Graph shows it; `az apim show` (`2022-08-01`) and every
  newer preview return `null`. Azure publishes no DNS for the gateway name.
  `docs/NETWORK-ENTERPRISE.md` gives the command, the portal path (JSON View at `2024-05-01`) and
  the per-host private DNS zone that made it answer by name from a peered VNet.
- **An enterprise network edge, chosen and priced by the administrator.**
  `scripts/New-ClaudeNetworkEdge.ps1` puts a regional Application Gateway WAF_v2 in front of the
  gateway as its only ingress, with internal, internet or hybrid listeners, and Foundry, Key Vault
  and a verifier behind private endpoints. It discovers the options, prices each from the retail
  price list with its implications, and writes nothing until one frozen review, which names the
  identities that may lose access, is confirmed; removal has its own review. Measured live:
  complete SSE for code prompts in Prevention mode with 71 scoped WAF exclusions, Claude Code
  through the edge with TLS verified, a 600-second backend timeout, and forged client-address
  headers kept out of the ledger. `docs/NETWORK-ENTERPRISE.md`,
  [ADR-0022](docs/adr/0022-enterprise-network-edge.md).
- **Architecture that cannot drift from the code.** Ten diagrams generated from text sources under
  `docs/architecture/` by `node guide/render-architecture.mjs`, a rewritten `docs/ARCHITECTURE.md`,
  and an `AGENTS.md` rule that every feature packet updates its diagram. `tests/Test-Architecture.ps1`
  fails when a source changes without re-rendering, a label names something that no longer
  exists, or an Azure resource type in `infra/*.bicep` appears in no diagram.
- **Chargeback reports, generated and emailed per business unit.** `New-ClaudeChargebackReport.ps1
  -Month` writes each unit's CSV of its people and an HTML summary, reconciled to the month through
  an explicit Unassigned line, or fails. `Set-ClaudeChargebackRecipients.ps1` sets each unit's and
  the admin team's recipients, limited to allowed domains. `Register-ClaudeChargebackSchedule.ps1`
  deploys a private scheduled job that archives every run and emails each unit only its own report
  through Azure Communication Services. Both months' reports reached the owner's inbox live on
  2026-09-24. About $29.70 a month standing, list price. `docs/CHARGEBACK-REPORTS.md`,
  [ADR-0020](docs/adr/0020-chargeback-reports.md).
- **The AUM service: viewers, managers and budget requests without Turnstile.** An optional Azure
  Functions API with its own Entra app roles and consent-free Azure CLI tokens. Managers are scoped
  by their manager groups; budgets are written to the gateway's named values by its managed
  identity with conditional revisions, in exactly the PowerShell serializers' format; budget
  requests, decisions and boosts with an expiry are audited. It refuses to write to a gateway
  another authority governs. `Deploy-ClaudeAumService.ps1` and `Select-ClaudeFinOpsTooling.ps1`
  show each choice's cost and implications first. `docs/AUM-SERVICE.md`,
  [ADR-0023](docs/adr/0023-aum-service.md).
- **Turnstile's pictures are live, and say so.** All 22 were recaptured from the reference
  deployment through the consent-free sign-in and 4 added, each with a dated, redacted provenance
  record and a pixel hash the screenshot check enforces. A tier change and a budget mode made in the
  UI were read on the gateway, then restored. Capture scripts discover their targets instead of
  defaulting to live resource names, and the deployment-values check now scans `.mjs` files.
- **Budget modes per business unit and team: strict, allowance or notify.** Strict is the default
  and unchanged. Allowance admits up to a percentage (1 to 100) above the budget; notify skips only
  that scope's limiter, while the parent, organization and tier limits still apply.
  `Set-ClaudeBusinessUnit.ps1 -Mode -AllowancePercent` sets it, and so does the Gateway governance
  page in Turnstile; the new named value `bu-modes` holds only the exceptions and survives a
  redeploy. Notices are advisory, because the remaining quota API Management reports is an
  estimate: `estimated-over-budget` for allowance, `usage-reported` for notify. Each budget trace
  joins the ledger on `BudgetRequestId`. Live-tested on the reference gateway and restored exactly.
  An apply run now rechecks Turnstile's revisions immediately before writing and reconciles again
  from newer state, so an earlier save can no longer overwrite a later one in the common case; the
  single writer in P48 closes it. [ADR-0019](docs/adr/0019-budget-enforcement-modes.md).
- **A terminal FinOps console, `claude-finops`.** Nine views in the terminal and the same actions as
  commands for scripts, over Turnstile's API, the gateway directly, or example data. Budget
  changes are previewed, rechecked against the server, never retried, and removal needs typed
  confirmation; the full chargeback export covers every unit and team, and CSV cells that start
  like a formula are escaped. Managers see only their scope and read only. Sign-in uses the Azure
  CLI and no token is stored. Accessible themes, no motion, and plain linear output.
  `docs/CLI-FINOPS.md`, [ADR-0018](docs/adr/0018-terminal-finops.md) (**U20**).
- **A projection record authorizes for two hours at most, and a burst of misses gets an answer.**
  Each complete directory observation stamps every member it keeps with a reconciliation generation
  and an absolute expiry, two hours by default and at most. The resolver and the gateway's cache
  both refuse an expired record with a 503 that names the expired projection, so a stopped writer
  no longer leaves access standing. Reconcile an existing projection once before deploying the new
  resolver and policy. Both writers read every Cosmos continuation page before publishing. Before
  the resolver, the gateway admits at most 100 concurrent misses and 200 a second and answers the
  rest with a retryable 429; the resolver coalesces concurrent reads of one identity within a
  process and runs two always-ready instances. Enterprise Cosmos defaults to private-only. Measured
  on the Premium v2 test gateway: no 503 in the first 20 misses after deployment or after 16 minutes
  idle, nor in bursts of 50 and 100. A throwaway container loaded 500,000 records at 954 a second,
  and 500 point reads cost 1 RU each, p99 51 ms (**U14**; **U18**, narrowed).
  [ADR-0017](docs/adr/0017-projection-freshness-and-admission.md).
- **Scale, measured at 500,000 identities.** On a throwaway Premium v2 instance with a mock
  backend, API Management's `llm-token-limit` counters accepted and charged 500,000 identities at
  about 1,600 requests a second on one unit, and no allowance was exact: one identity was served
  540 tokens against a 300-token hourly quota, and 1,000 exhausted identities were admitted again
  within the hour (**U9**, narrowed). On the Premium v2 test gateway, the projection's resolver
  returned 503 to 2 of 3 first requests after idle with no always-ready instance, and to 4 of the
  first burst of 20 concurrent misses with one; nothing coalesces concurrent misses (**U18**).
  `docs/SCALE.md`.
- **Nothing about one deployment is written into the scripts.** Twenty-seven scripts and tests
  defaulted `-ResourceGroup` to the reference deployment's resource group. They now resolve it
  through `scripts/Get-ClaudeGatewayTarget.ps1`: `CLAUDE_RG`, else the resource group the installer
  recorded in `onboarding/claude-gateway.json`, else nothing, with a warning naming what to pass.
  Help examples, a live test's workspace name, and three tenant ids in `docs/FOUNDRY-DIRECT.md`
  and the resolver's test fixture are placeholders or discovered. `tests/Test-NoDeploymentValues.ps1`
  keeps it that way, and fails when a literal is put back.

- **The API Management AI Gateway tier (preview), assessed beside this gateway.**
  `docs/AI-GATEWAY-TIER.md`. Its dollar budgets count per API key, not per person; enforcement for
  Entra principals is announced as coming. Deployed in 133 s as `Microsoft.ApiManagement/service`
  with the `AIGateway` SKU; ARM accepted a Foundry provider, Claude and OpenAI models, and token
  and cost limits, but the runtime served no model route (U16), so Claude clients and the limits'
  enforcement are untested. The Turnstile fork's four branches are offered upstream as draft pull
  requests xuleihive/turnstile#25 to #28.

- **Turnstile as the FinOps console, admin-only, with the gateway still the one enforcer.**
  `docs/TURNSTILE.md` is the walkthrough; every step was run live on 2026-09-23.
  - `New-ClaudeTurnstileEntraApp.ps1` creates the single-tenant application, the `Turnstile.Admin`
    role, the `Turnstile.Manage` scope pre-authorized for the Azure CLI, assignment required and the
    admin group. Removing the group's assignment made Entra refuse a token (`AADSTS50105`).
  - `Connect-ClaudeTurnstile.ps1` discovers a Turnstile deployment and stores it in one named
    value, `turnstile-integration`; `Sync-ClaudeTurnstileGovernance.ps1` maps units to
    organizations, teams to departments and budgets both ways, writing nothing back without
    `-Apply`; `Export-ClaudeTurnstileUsage.ps1` sends requests and hourly cache reads through the
    Event Hubs REST API with an Entra token.
  - Turnstile's own `UsageProcessor` accepted 561 of 561 exported events unaltered; the same 557
    sent twice were stored once. A budget set in Turnstile refused the next gateway request.
  - `Get-ClaudeTurnstileBom.ps1` prices the Turnstile deployment from live list prices: $158.84 a
    month at rest in Central US.
  - Uses the fork naveenneog/turnstile, branch `claude-gateway`: Entra admin-only sign-in and
    bearer tokens, an enterprise catalog API, and a deployer that runs on Windows.
  - `Register-ClaudeTurnstileSchedule.ps1` and `infra/turnstile-schedule.bicep` put the export and
    sync on a schedule: an Azure Container Apps job signed in as its own managed identity, with no
    secret, running a pinned commit ([ADR-0014](docs/adr/0014-turnstile-beside-the-gateway.md)).
    A workload identity is now also granted Reader on the gateway's Application Insights
    resource, which the export reads to find the ledger. Run live on 2026-09-23: a pass took 143 s,
    a changed budget reached Turnstile attributed to the job's identity, and removing its Event
    Hubs grant made the next run fail with 401. The first runs found two faults, both handled: the
    start script carried CRLF from a Windows checkout, and governance automation had stopped
    Turnstile's PostgreSQL server.

- **The projection deploys with no public endpoint anywhere, and was deployed
  and migrated to end to end.** On 2026-09-23, on a Premium v2 gateway in Canada
  Central with the Cosmos account in East US 2, it was populated, compared,
  flipped to, failed over, rolled back and flipped to again.
  `docs/SECURE-PROJECTION.md` is the walkthrough.
  - `infra/resolver.bicep` existed only as a reference in
    `resolver/src/index.mjs`. It is now a Flex Consumption app whose built-in
    authentication admits one caller, the gateway's managed identity, checked
    on application id and object id. Its app registration requires
    assignment, so nothing else can obtain a token for it (`AADSTS50105`). It
    reads one container, and it uses no keys anywhere: storage, Cosmos and
    Application Insights are all Entra-only. Inbound can be private (measured:
    `403 Web App - Unavailable` from outside, `200` through the integrated
    gateway), or public for Basic v2 gateways.
  - `infra/projection-network.bicep` takes an existing VNet and the subnets a
    network team hands over. It creates only the endpoints, zones and links, and
    adds the resolver's `Microsoft.App/environments` subnet and the zones for its
    endpoint and storage. Redeploying it over resources created by hand adopted
    them without duplicates.
  - `sync/` writes the projection from inside the network, as its own identity
    with write access to one container. `Sync-ClaudeProjection.ps1 -ExportPath`
    resolves Entra with the operator's sign-in and writes a snapshot of object
    ids and tiers, so no credential crosses into the network. `--graph` reads
    Entra with the job's own identity where a tenant administrator has granted
    `GroupMember.Read.All` (refused here with `Authorization_RequestDenied`).
    Measured: 8 records in 1.5 seconds, then 8 unchanged on the re-run.
  - `Compare-ClaudeEntitlement.ps1 -ExportGatewayPath` plus
    `apply-projection.mjs --compare` compare the projection with the gateway.
    Each difference is named `would-lose-access`, `would-gain-access`,
    `tier-drift` or `unit-drift`. The migration's step 4 had compared the lists
    with the directory only, which says whether the lists are current and
    nothing about the projection.
  - `scripts/ClaudeRunner.ps1` gets files into the in-network runner. Measured
    on `az container exec`: no shell, URL-decoded (a `+` arrives as a space),
    and under 5,000 characters or refused with `InvalidCommandLength`. So files
    travel as base64url in chunks, checked by SHA-256.
  - `docs/AUTHENTICATION.md`: which credentials reach the gateway, measured.
    People by Azure CLI sign-in, with both audiences; Claude Code CLI 2.1.272
    end to end; a managed identity inside the VNet (150 of 150); a service
    principal (refused, then entitled 39 seconds after its record was written,
    with a 24-hour token); and 401 for a wrong audience, a garbled token or none.
    It says plainly that device code and workload identity federation were not
    run, and that the entitlement check, not token expiry, is what revokes
    access.
  - `tests/Test-SecureProjection.ps1`: 84 assertions and 31 mutations. The
    business-unit order runs the real function over 300 units; the sync rules
    run under `node --test` (20 cases).

- **What to allow on a firewall, measured rather than listed.**
  `docs/NETWORK.md` gives one table per destination, marked with which of the
  three clients — CLI, VS Code extension, Claude Desktop — needs it, and
  separating what is needed to *run* from what is needed to *install*. Three
  hosts are needed to run: the Foundry host on the direct path or API
  Management on the gateway path, plus `login.microsoftonline.com`.

  Two entries that commonly appear on an allowlist and do not do what they
  look like. `cognitiveservices.azure.com` is the **token audience**, the
  string in the OAuth scope — no client connects to it, so an allowlist
  holding it without a wildcard appears to cover Foundry and covers nothing.
  All three build `${resource}.services.ai.azure.com`. And `*.azure-api.net`
  is **not matched by any `*.azure.com` rule**: different suffix, and on the
  gateway path it is the entry that matters most.

  `scripts/Test-ClaudeNetwork.ps1` checks it, and makes a real **streaming**
  call rather than stopping at reachability, because the two are not the same
  question. `scripts/observe-egress.mjs` records what a client attempts and
  forwards it, tunnelling rather than intercepting so it never terminates TLS.

- **Live infrastructure prices in the bill of materials.**
  `Get-ClaudeBom.ps1 -WithPrices` reads `prices.azure.com` for the SKUs
  actually deployed in the region actually deployed. Claude token rates are
  deliberately excluded: measured across 6,734 `Foundry Models` meters in four
  regions, **none is a Claude meter**. They stay in `config/price-book.json`
  with the date they were read.

  `scripts/AzureRetailPrice.ps1` defends the three ways that API returns a
  wrong number quietly. `contains()` is unsupported and returns an empty set
  rather than erroring. A `Free Tier` row shadows the real meter — Cosmos
  `100 RU/s` is published at both $0.008 and $0. Tiered meters start at zero.
  A lookup that finds nothing returns `$null` and never `0`.

- **The P19 platform is decided and priced.** Cosmos DB serverless with an Azure
  Function resolver, recorded in
  [ADR-0011](docs/adr/0011-projection-platform.md).
  `scripts/Measure-ClaudeProjectionCost.ps1` computes the running cost rather
  than quoting one, because the figure that decides it is the cache miss rate and
  nobody can look that up.

  At the full requirement — 500,000 developers, 50,000 active daily, a 60-minute
  cache window — it is **$11.11 a month**: $1.56 Functions, $2.20 Cosmos request
  units, $0.05 storage, $7.30 private endpoint. The resolver is called once per
  cache window per active developer, not once per request, so a developer making
  500 calls an hour and one making 5 cost the same.

  Halving the window to 15 minutes costs $22.99, and most of that is the fixed
  endpoint charge. Every plausible setting is
  affordable, so the cache window is a **revocation decision, not a budget one**
  — which settles how the question still open from ADR-0005 should be answered.

  What it costs instead is a guarantee: serverless offers no guaranteed
  throughput or latency, and Functions cold starts land in p99 on a miss. Both
  are stated rather than left to be discovered.

- `infra/projection.bicep` deploys the projection: a serverless Cosmos account
  with local auth disabled, partitioned on `/oid` so every identity is its own
  logical partition. Partitioning on `/tenantId` — the obvious reading of
  ADR-0005 — would put all 500,000 records in one logical partition, which looks
  correct at eight developers and hits a 20 GB wall later.

  Deployed to the reference subscription to prove it works, which is how the
  private-networking constraint above was found. Nothing reads it yet; that is
  ADR-0009 phase 1, schema first with authorization unchanged.

- **Cache reads are now charged back.** `Get-ClaudeBusinessUnit.ps1` attributes
  them per business unit and shows them in their own **Cache read** column,
  priced at 0.1x base input.

  Chargeback previously omitted cache entirely. On measured usage that is 38.7%
  of real cost weight, and the omission is uneven — a team reusing a large cached
  prompt was under-charged against one that does not.

  The recorded blocker turned out to be too broad. "No APIM-native source carries
  the cache categories" is true per request; the gateway's own
  `llm-emit-token-metric` emits `Prompt Cached Tokens` carrying a `UserId`
  dimension, which is the same object id `bu-members` keys on. Measured
  2026-09-17: 6,833,717 cached tokens across 162 rows, against a `UserId` already
  in the business-unit map. On the reference deployment the report now shows
  6,105 metered tokens beside 6,833,717 cache reads.

  Cache read is reported **beside** `tokens_used`, not inside it, because the
  quota still cannot see it — folding it in would imply the budget counts it.

  Still missing, and stated in the output: cache *write*, the 5-minute and 1-hour
  categories, which exist only in the response body. Reading that in an outbound
  policy buffers the response and ends streaming. Enforcement remains blind to
  every cache category — U13, unchanged.

- `Test-ClaudeHealth.ps1` answers, in one command, whether the gateway needs
  attention. Six read-only checks: the API Management tier is v2, entitlement is
  in sync with the directory, no named value is near its limit, every deployed
  Claude model is priced, nothing can reach Foundry around the gateway, and no
  entitled developer is without a business unit.

  It runs the shipped checks and reads their exit codes rather than
  reimplementing them, so there is no second copy of the logic to drift. Each
  finding carries the command that fixes it. `-AsJson` for monitoring, `-FailOn
  warn` for a scheduled gate, `-Detailed` to see each check's own output.

  Nothing is written, so it can be run freely.

- `Add-ClaudeModel.ps1` makes a newly released Claude model usable in one
  command: it checks the model is deployed (and deploys it with `-Deploy`), adds
  it to the tier allow lists, writes its price, and prints what developers have
  to change — the model name, and nothing else.

  Four things have to agree for a model to work, and the third fails quietly:

  | | Where | If missed |
  |---|---|---|
  | Deployed | the Foundry account | Foundry refuses |
  | Allowed | `models-standard` / `models-premium` | the gateway 403s |
  | **Priced** | `config/price-book.json` | **served, and reported at $0** |
  | Selectable | `availableModels`, if pinned | the client hides it |

  An unpriced model is refused unless `-SkipPrice` is passed, and `-List` marks
  it red. `-Remove` retires a model and deliberately keeps its price, because a
  report covering a past month still needs the rate that applied then.

  Only Claude deployments are listed. The reference account also carries GPT,
  Sora and embedding deployments; showing them as unpriced would be true and
  useless.

- The price book moved out of the code into `config/price-book.json`, so a new
  model is no longer a code change. The file is git-ignored — it may hold
  negotiated rates rather than list price, which is commercially sensitive — and
  `config/price-book.example.json` ships instead. With no file, the built-in list
  rates apply, so a fresh clone works. A malformed file throws rather than
  falling back, and rates are cast to decimal on load because `ConvertFrom-Json`
  produces doubles and ADR-0010 requires decimal end to end.

- `New-ClaudeCodePolicy.ps1` gained `-Marketplace`, `-BlockUserPlugins` and
  `-RequireSignedExtensions`. A plugin runs with the developer's own permissions
  and can add tools, skills, hooks and MCP servers, so where plugins come from is
  worth pinning. Claude Code and Claude Desktop use different key names for the
  same idea, and both are emitted from one input:

  `strictKnownMarketplaces` for Claude Code; `allowedPluginMarketplaces`,
  `userPluginMarketplacesEnabled`, `userPluginUploadsEnabled`,
  `disableDeploymentModeChooser` and `isDesktopExtensionSignatureRequired` for
  Claude Desktop.

  Both guides state the limit plainly: these are feature-availability controls,
  not data boundaries. Marketplaces already registered — including any registered
  outside the app, such as by the Claude Code CLI — are not removed by them.

- `docs/MODELS.md` and `docs/PLUGINS.md`.

- `Measure-ClaudeOvershoot.ps1` measures how far spend runs past a budget before
  a kill switch stops it, because a budget enforced outside the request path
  cannot be a hard cap and the gap should be a number rather than a shrug.

  Measured on the reference deployment: telemetry lag **193s worst**, 87s median
  over 102 requests; named-value propagation **17s**; with a 300s job interval
  that is a **511s window**, plus requests already admitted and still streaming.

  The worst case feeds the bound, not the median — telemetry lag ranged 56s to
  193s, and a bound on the median would be wrong about half the time in the
  direction that matters. Propagation is observed through a gateway response
  header rather than by reading the named value back, because ARM returns the
  new value immediately and that says nothing about when the policy sees it.

  Nothing is left changed: the override map is restored in a `finally`, and a
  failed restore says so loudly.

- [ADR-0010](docs/adr/0010-financial-semantics.md) settles the financial
  semantics that P21 and P23 both depend on, each answer grounded in a
  measurement already recorded here rather than a pricing page:

  an internal tariff at **list price** rather than actual Azure cost, because the
  CCU meter carries no per-user or per-model split and private-offer discounts
  apply before conversion; all five token categories billable at their measured
  multipliers — cache read 0.1x, five-minute write 1.25x, one-hour write 2x — and
  never summed before pricing, since total input is defined as the sum of input,
  cache creation and cache read; pricing joined on the **deployment** rather than
  the model alias the client sent, with the `inference_geo` multiplier that
  applies to the request; decimal arithmetic rounded **once**, at presentation; a
  price book versioned by effective interval so a price change cannot rewrite a
  month that was already signed off; UTC periods so the quota renewal and the
  reporting month are the same boundary; an append-only ledger where corrections
  are new rows; and **"soft cap" defined as approximate blocking, not warn-only**,
  which is the term most likely to be read the wrong way by a finance owner.

- `Compare-ClaudeEntitlement.ps1` resolves every identity twice — once from what
  the gateway is enforcing, once from the directory — and exits non-zero when
  the two disagree. It reports `missing` (added in the portal, still getting
  403), `stale` (removed, still entitled) and `tier-drift`.

  Tier is resolved with the policy's own precedence, premium before standard, so
  an identity in both groups is premium on both sides. Resolving it the other
  way would report drift the gateway does not have, and a noisy comparison stops
  being read.

  Negative-tested on the reference deployment rather than assumed to work:
  removing an identity from its Entra group without running the sync produced
  `stale (1)` and exit 1, and re-adding it returned the comparison to clean.

  This is phase 2 of the migration in ADR-0009, and it is useful before any of
  that is built: entitlement is not live, and this measures the gap between a
  directory change and the sync.

- `ClaudeGraphMembership.ps1` — the Graph membership read, extracted from
  `Sync-ClaudeAccess.ps1` so the writer and the comparison cannot drift apart. A
  comparison that reads the directory differently from the writer reports its own
  bugs as drift. The request form it holds took six measured combinations to
  find, which is exactly the kind of thing that gets reimplemented slightly wrong.

- [ADR-0009](docs/adr/0009-shadow-migration.md) — how entitlement migrates.
  Five phases with authorization unchanged until the canary, counter keys and
  period boundaries preserved throughout, and a rollback that restores
  authorization without restoring consumption.

  Budgets are consumed state rather than configuration: a developer at 80% of a
  monthly allowance carries a number that exists only in the gateway's counters,
  and a migration that re-keys them hands that allowance back. A budget that has
  stopped binding looks like a budget that is working.

  The mid-period opening balance — full allowance or pro-rata — is a finance
  question, so it is deferred to P20b and the current behaviour is stated rather
  than left to be discovered.

- `Measure-ClaudeCeiling.ps1` reports how close a gateway is to the limits that
  stop it scaling, and exits non-zero past a threshold so it runs as a check.

  The figures it enforces were measured against a live instance rather than read
  from a document, because the two have disagreed: a named value holds **4,096
  characters** (4,097 returns `ValidationError`) and **110 object ids** (110 is
  4,071 characters and is accepted; 111 is 4,108 and is rejected). The identity
  ceiling is derived from those two rather than written as a literal, so it
  stops being correct out loud if the service limit changes.

  Per-entry cost is measured from the list being read, not assumed to be 37
  characters. A `bu-members` entry carries `oid=unit` and costs 44, so assuming
  the smaller figure overstates remaining room on the list that fills first.

  On the reference deployment: 3, 5 and 5 entries against a 110 ceiling, and 22
  of 5,000 named values.

- `docs/SCALE.md` — the load envelope. It states what runs out first, why
  sharding the list across named values is not the escape it appears to be, and
  the five numbers a capacity figure needs that "500,000 employees" does not
  supply: daily actives, peak requests per second, peak token rate, streaming
  concurrency and burst shape.

  It also states what has **not** been measured. The reference deployment's
  ledger holds 111 requests across 2 days, so it cannot supply a traffic model,
  and the page does not extrapolate one from it.

  A capacity test that proves 500,000 counter keys can be created proves nothing
  about whether allowance survives scale-out, policy deployment or period
  rollover. The page says what the test has to demonstrate instead.

- `Get-ClaudeBom.ps1` reads the live deployment and reports only this gateway's
  own resources, separating what it created and bills for, what it reuses and
  did not create, and what is configuration and carries no bill at all. On the
  reference deployment that is 5 of 66 resources in the group, of which only
  API Management meaningfully costs anything.
- `docs/images/request-flow.png` — the six-hop request and telemetry path,
  rendered from HTML rather than generated, because the value of the picture is
  that the resource and table names on it are the real ones.
- `Publish-ClaudeGrafana.ps1` — optional, for organisations that already run
  Grafana. It reads the same saved KQL functions as the workbook, states that
  Grafana is charged per instance per hour whether or not anyone opens it, and
  will not create the instance.
- `Set-ClaudeDeveloper.ps1` — add or remove one person. It edits the **Entra
  group**, not the gateway, because `Sync-ClaudeAccess.ps1` rebuilds the allow
  lists from group membership every run: a developer added straight to a named
  value works until the next sync and then silently stops. `-Sync` publishes in
  the same command; without it the script says the change is in the directory
  but not yet at the gateway. Removing clears every business unit as well as
  both tiers, because leaving someone on a budget they can no longer spend reads
  as a broken team rather than a half-finished offboarding.
- A decision tree at the top of the README, routing by who you are, with the
  nine commands for running it day to day inline rather than behind another page.
- Claude Desktop backup and restore. `Backup-ClaudeDesktop.ps1` captures both
  profile roots - `%APPDATA%\Claude` for first-party and
  `%LOCALAPPDATA%\Claude-3p` for this gateway - and refuses while the app is
  running, because it holds its conversation database open. Measured with
  Desktop running, `LOCK`, `LOG` and `000003.log` could not be opened while
  `CURRENT` could, so a copy taken then is part of a LevelDB and restores as
  corruption. The restore refuses harder: writing into a live database takes the
  history already on that machine with it.
- The virtual machine bulk is excluded. Measured, a third-party profile is
  11.4 GB of which `vm_bundles` alone is 10.6 GB, against 4 MB of session data.
  A synthetic profile of 6 MB, nearly all bulk, produced a 2 KB archive.
- `Migrate-ClaudeWorkstation.ps1` - the developer-side tool. `-Status` reports
  what is on the machine, `-Backup` captures Claude Code and Desktop,
  `-Configure` points everything at the gateway, `-Restore` puts it back. It
  warns that configuring switches Desktop to a different profile root, so the
  first thing seen afterwards is an empty Desktop - backing up first makes that
  reversible.
- The installer sizes the SKU. It asks how many developers and shows the
  arithmetic against published included request volume, because Microsoft
  publishes no requests-per-second per unit for the v2 tiers - the guidance is
  to load test. On that basis Basic v2 covers about 900 developers, so it also
  says what usually decides the tier instead: Basic v2 has no VNet integration
  and no availability zones.
- `Set-ClaudeTier.ps1` reads and changes tier limits and model allow lists,
  checking models against what the Foundry account actually serves - a tier
  allowing an undeployed model refuses the caller with a name that looks
  correct. It states plainly that a third tier is a policy change, because the
  policy names `standard` and `premium` in five places.
- `Set-ClaudeBusinessUnit.ps1` verifies the Entra group exists before writing,
  and offers near matches. A unit pointing at a missing group is created, syncs
  to nobody, and reads as unused rather than broken.
- The gateway records which client made the call. Nothing in API Management
  carried it — measured 2026-09-16, `AppRequests.Properties` held only API and
  service metadata, `ClientType` read `PC` and `ClientBrowser` was empty. The
  chargeback trace now captures the `User-Agent`, truncated, and the ledger
  parses the surface out of it. **Parsed, not matched against a list**: Claude
  Code 2.1.241 identifies itself as `claude-cli/2.1.241 (external, sdk-cli)`,
  and a list built on the obvious guess of `cli` mis-buckets the real CLI.
  Verified live against the real CLI plus Desktop-, VS Code- and SDK-shaped
  agents.
- `scripts/Publish-ClaudeQueries.ps1` publishes the queries in `analytics/` as
  callable workspace functions — `ClaudeChargeback()`, `ClaudeCodeDaily()`. The
  `.kql` files stay the source; only the window lines are rewritten into
  parameters, and it refuses to publish when it cannot find them, because a
  function pinned to a fixed window answers every question wrongly and looks
  right doing it. Verified the parameter is honoured: 44, 5, 44 and 0 rows
  across four windows.
- `infra/workbook.json` and `scripts/Publish-ClaudeWorkbook.ps1` — the Observe
  pane. Consumption by business unit, by client, by developer, by model and over
  time, plus what could not be attributed. It refuses when the definition is not
  valid JSON or when the workspace lacks the functions it calls, either of which
  produces a dashboard that opens on an error. The id is derived from the
  resource group and display name, so re-running updates in place rather than
  leaving a second copy. Neither a saved search nor a workbook stores or runs
  anything, so no always-on component was added.
- The installer finds or creates a Claude deployment. It used to stop with "the
  gateway fronts a model, it cannot create one" when no account had one, which
  is true of the gateway and beside the point for an installer already signed in
  to the subscription where the deployment would be made. It now lists the
  models the account is entitled to deploy — read from the account, because what
  is offerable depends on region and entitlement — asks which and at what
  capacity, and creates it. `scripts/ClaudeModelDeployment.ps1` holds the logic.
- Tier model lists come from what is actually deployed. The installer shows each
  Claude deployment with its SKU and capacity and asks which models each tier may
  call, defaulting premium to all of them and standard to everything except Opus,
  which costs five times Sonnet per output token. Previously `modelsStandard` and
  `modelsPremium` were never passed at all.
- Quota is separated from other deployment failures.
  `Get-DeploymentFailureReason` classifies Azure's error and says what to do —
  ask for quota, lower the capacity, or change region — because a generic
  "deployment failed" sends the operator to retry when none of those is a retry.
- Teams. A team is a business unit that names a parent, decided in
  [ADR-0008](docs/adr/0008-teams-and-tiers.md). A request is charged to the team
  and to the business unit above it — two monthly counters, both soft. Verified
  live: one request returned `x-bu-quota-remaining: 1666666644` for the team and
  `x-bu-parent-quota-remaining: 5555555533` for its parent, alongside the
  unchanged org ceiling.
- `-Parent` on `Set-ClaudeBusinessUnit.ps1`, with `bu-parents` as a second named
  value. Depth is capped at two and cycles are refused when written, because the
  cascade is two policy elements with fixed counter keys and no loop — a third
  level would go uncharged rather than fail. Removing a business unit promotes
  its teams to top level instead of leaving a dangling parent.
- Hierarchy in the reports. `Set-ClaudeBusinessUnit.ps1 -List` and
  `Get-ClaudeBusinessUnit.ps1` indent teams under their parent, and a parent's
  figure is the roll-up of its own members and its teams — which is what its
  counter actually enforces.
- Tier by nesting. A team gets a tier by putting the team group inside
  `claude-code-standard` or `claude-code-premium`. Nothing in the tier mechanism
  changed; entitlement was already resolved transitively.
- `tests/Test-Teams.ps1`, and eight more mutations in
  `tests/Test-BusinessUnitsNegative.ps1`, which now drives both suites.
- `guide/capture-entra.mjs` screenshots the Entra group blades that back the
  hierarchy. It exits non-zero on an expired session rather than saving the
  sign-in page.
- Business units. A business unit is an Entra security group registered with a
  monthly budget, decided in [ADR-0007](docs/adr/0007-business-unit-model.md).
  `scripts/Set-ClaudeBusinessUnit.ps1` adds, edits, lists and removes them;
  `scripts/Get-ClaudeBusinessUnit.ps1` reports budgets, members and spend;
  `docs/BUSINESS-UNITS.md` is the guide. The registry key is a stable identifier
  rather than the display name, so renaming a group in Entra does not move spend
  to a new line.
- Business-unit membership sync. `Sync-ClaudeAccess.ps1` now resolves each unit's
  group to object ids and writes the `bu-members` map alongside the entitlement
  list, under the same guard that refuses to overwrite a populated map with an
  empty one.
- Business-unit soft cap in `infra/policy.xml`. A unit with a budget gets a
  monthly `llm-token-limit` keyed on its identifier, and exhausting it returns a
  fourth distinct `403` that names the unit. A unit with no budget set is
  skipped rather than refused, so an unpriced unit behaves like the organisation
  ceiling alone. Developers in no unit are `unassigned`, allowed by default
  because no one has a unit on the deployment that first installs this.
- `tests/Test-BusinessUnits.ps1`, 66 assertions, and
  `tests/Test-BusinessUnitsNegative.ps1`, which breaks each thing those
  assertions guard and confirms the suite goes red. Both are wired into
  `tests/Test-All.ps1`.
- `tests/Test-FormatStrings.ps1`, a repo-wide check that every .NET format
  string parses and runs.

### Changed

- **Scripts ask for a value they were not given, and say where it comes from.**
  `scripts/ClaudeChoice.ps1` offers the options discovered in Azure, numbered, with the one the
  deployment points at recommended and the command and portal path to look it up; without a
  console it uses a certain recommendation and otherwise stops naming the candidates. The
  publishers (`Publish-ClaudeQueries.ps1`, `Publish-ClaudeWorkbook.ps1`, `Publish-ClaudeGrafana.ps1`)
  now find the workspace behind the gateway's Application Insights instead of refusing when a
  resource group holds several, and `Get-ClaudeTelemetry.ps1` prints that `Workspace` and no
  longer takes the first API Management instance in a group.
- **The chargeback ledger records the caller's address.** `analytics/chargeback-ledger.kql` has a
  `client_ip` column, from a new `ClientIp` field in the gateway's identity trace: behind the P54
  edge it is the edge's socket peer, otherwise the address APIM saw. It is personal data; review
  who can read the ledger and how long it is kept. Every response also carries
  `x-claude-gateway-request-id`, the id the ledger joins on.
- **The documentation is organised by what a reader is trying to do.** README is a 278-line
  landing page with a documentation map, down from 710 lines, and five task guides were added:
  Operations, Budgets, FinOps, Reference and Data governance. Guides say where each value comes
  from and give the command that discovers it, with the portal path beside the script. Seventy
  findings from walking eight reader journeys were fixed. `tests/Test-DocReferences.ps1` fails
  on a broken link or anchor, or on a script or parameter a guide names that does not exist.

- **The test suite runs in parallel, and the gate's budget is 30 minutes again.** `Test-All`
  starts each check as its own `pwsh` process, four at a time, with an exclusive lane for checks
  that share Azure CLI state or scan the whole tree, logs in registration order, and a 600 s
  deadline per check. The business-unit and Turnstile mutation harnesses run as four and two
  shards, and `tests/Test-MutationShards.ps1` proves the shards cover all 476 and 108 mutations
  exactly. Measured on a busy machine: 790 to 927 s, against 1,829 s serially.
  [ADR-0025](docs/adr/0025-parallel-test-suite.md).

- **The gate gives the test suite 60 minutes, and the suite reports where its time goes.**
  `tests/Test-All.ps1` took 1,797.2 s on `690015d` against a 1,800 s command budget, and a
  budget-modes gate had already failed on time with no failing check. `commandTimeoutMs` is now
  3,600,000 ([ADR-0024](docs/adr/0024-test-suite-time-budget.md)); `Test-All` prints each check's
  seconds and the five slowest, and writes them to `test-all-timings-<utc>-<pid>.json` in the temp
  folder, because the gate discards the suite's output when it passes. P56 makes the suite
  parallel so the budget can return to 30 minutes.

- Money moved from `[double]` to `[decimal]` in `ClaudeBusinessUnit.ps1`,
  `Set-ClaudeBusinessUnit.ps1` and `Get-ClaudeBusinessUnit.ps1`, and token spend
  is accumulated as `[long]` rather than `0.0`.

  A rate of 0.000002 per token accumulated over millions of tokens in binary
  floating point does not reproduce, and a chargeback figure that changes between
  two runs of the same query cannot be argued with. After the change $5,000
  converts to 1,388,888,888 tokens and back to exactly $5000.00.

### Fixed

- **The first reviewed network edge deployment refused a VNet that did not exist yet.**
  `New-ClaudeNetworkEdge.ps1` read the owned VNet before creating it; the lookup returned
  nothing, and the extra-subnet guard counted that empty result as an unknown subnet, so a fresh
  install stopped with "The owned VNet has additional subnets". The guard now runs only when the
  VNet exists. Found by P54's isolated live estate on 2026-09-25; the regression test runs the
  script's own deployment block offline for an absent VNet, the owned four-subnet layout, and an
  extra subnet (still refused, with no deployment) on PowerShell 7 and 5.1.
- **Four gaps a review found in the new capture redaction.** A tenant-name pair could turn a
  colleague's address into one on the placeholder domain, which the address rule then kept:
  addresses are now replaced before any pair. A real value that started inside a replacement and
  ran past it was hidden by the shadowing rule: only a match wholly inside a replacement is now
  ignored. An application's assigned principals were read from Graph's first page only: every
  page is read, and a list that never ends is refused. And every record named a commit that did
  not contain the code that took it: the runner now refuses to capture from uncommitted capture
  code and records each step's hash; the existing records are marked `accel_dirty` with a
  provenance note.
- **A deployment suffix inside a longer name escaped redaction, and people on directory pages
  were not redacted at all.** The capture redactor matched private values only at word
  boundaries, so a mapped suffix inside a name built from it (a report storage account shown as
  an environment variable on the admin job's blade) survived, and the leak check, using the same
  rule, passed it. A value of 8 or more characters, or a 6+ character mix of letters and digits,
  is now replaced and checked wherever it occurs; a replacement that happens to contain another
  private value is not itself a leak. Separately, a group's Members blade showed colleagues' real
  names, which no private map lists: Entra group and application pages now read the page's own
  members or assigned principals at discovery, show them as `Contoso user N`, hide their initials,
  and refuse to capture when none were discovered (`redaction.people`). Both were found by
  reviewing uncommitted batch images; neither reached a commit. Every portal image was then
  recaptured under the new rules.
- **Portal batch steps failed on blades that had rendered.** The runner took the first DOM match
  for a label, and the portal keeps hidden copies of many (collapsed menus, tooltips, other
  blades); it now takes the first visible match, and a timeout names the locator. Spec fixes found
  by replaying each failure: jobs reach execution history through the overview's `View` link;
  the gateway's APIs item is addressed inside the menu; Log Analytics Functions need KQL mode;
  top-level waits sit on the landing blade; deep links that no longer render became menu clicks.
  The Azure portal has no deployments blade for a Foundry resource, so that picture is a live CLI
  read instead. `docs/guide/portal-captures.json` records every capture, and the tests now fail if
  a published image differs from its record.
- **Scripts refuse governance writes that Turnstile would overwrite.**
  `Set-ClaudeBusinessUnit.ps1` and `Set-ClaudeTier.ps1` check the recorded authority
  before writing, name the Turnstile page to use, and explain the explicit
  `Connect-ClaudeTurnstile.ps1 -GovernanceAuthority Gateway -BudgetAuthority Gateway`
  switch. Budget-only authority blocks monthly unit/team budget edits, not structure,
  modes or tiers. Failed authority reads stop writes; a genuinely absent or explicitly
  disconnected integration leaves the gateway in charge. Lists, personal daily
  overrides and Entra membership edits remain available. The same tests on PowerShell
  5.1 exposed and fixed singleton registry rendering when removing one of two units.
- **A root unit in allowance or notify mode got HTTP 500.** The gateway's budget trace sent an
  empty `ParentUnit` (a unit has no parent) or `Notice` (no advisory yet), and APIM rejects empty
  trace metadata: "The value field is required". Absent values are now `none`, and a test
  compiles and runs the policy's actual expressions. Found live by the AUM service's enforcement
  journey; the reference gateway, all strict, could not reach it.
- **The resolver check could fail with every test passing, and three runner gaps.** Under a
  headless console on code page 437, Node's Unicode summary line did not match the wrapper's
  pattern, so it counted zero passes; `tests/Test-Resolver.ps1` now asks for ASCII TAP output and
  reads its exact pass and fail counters. A registered script that was missing behind a
  prerequisite SKIP was reported as skipped, not failed; a check stopped at its deadline lost the
  output it had printed; and a check started late could have outlived the gate's budget. Each was
  reproduced by a failing test first.

- **`Test-All.ps1` reported success for checks that never ran.** A terminating error inside a
  check travels up to the nearest `try`, and every check ran inside one `try`/`finally` with no
  `catch`. So when `Test-On-PS51.ps1` found its fixed temp file `wiz51-answers.txt` locked by a
  second run on the same machine, the rest of the run was skipped and the summary still printed
  "All checks passed." with exit code 0: a packet gate passed in 57 seconds on 9 of 32 checks. It
  was caught before anything was pushed. Each check now records FAIL and the run continues; a run
  that stops early fails; a registered check whose script is missing fails instead of being
  skipped; and both wizard tests use one temp file per run. `tests/Test-RunnerIntegrity.ps1`
  reproduces the false pass on a copy of the runner, and two mutations prove its assertions catch
  it. The only trigger found was the wizard's fixed temp file; earlier gate receipts ran for 20 to
  30 minutes, and a run cut short at the wizard check takes about one.

- **The in-network projection writer reported success when writes failed.**
  `sync/src/apply-projection.mjs` printed `ok: true` even when upserts or deletes had failed,
  though it exited 3. It now reports the outcome. Found by a review of the 500,000-developer
  design, whose other findings are recorded, checked against the code, in `docs/STATUS.md`: the
  resolver accepts a record of any age, it is called before any limiter, and
  `Sync-ClaudeProjection.ps1` reads only the first page of existing records.

- **Re-running the installer reset the revocation window to an hour.** That is
  how long a removed developer keeps working. The wizard's answer, 60 minutes
  by default and the only answer under `-Yes`, always won over the value it had
  just read back, so three consecutive re-runs each deployed
  `entitlementCacheSeconds=3600` whatever the gateway had. Found because a
  1-second window stayed an hour: the installer's own verification cached an
  entry for 3,600 seconds. A gateway that already has a window now keeps it,
  and the wizard says so. The lookup goes through `Invoke-AzOptional`: on
  Windows PowerShell 5.1 an az call for a gateway that does not exist yet
  raised `NativeCommandError` under `2>$null`, and `ErrorActionPreference Stop`
  ended the wizard before its summary. The same helper now guards the two
  existing-gateway checks on the deploy path, which had the same exposure on
  5.1 for every new gateway.

- **The installer stopped at the entitlement sync on every run, after
  deploying the gateway.** Introduced earlier the same day, by the fix that made
  the confirmation screen price the chosen SKU: that fix dot-sourced
  `AzureRetailPrice.ps1`, which ran `Set-StrictMode -Version Latest` at top
  level. Strict mode then reached `Sync-ClaudeAccess.ps1`, where reading
  `'@odata.nextLink'` on the last Graph page threw
  (`The property '@odata.nextLink' cannot be found on this object`). The
  library now sets strict mode inside each function only, and both Graph pagers
  read the link in a way strict mode tolerates. Checks run the library in a
  fresh shell and the real paging function under strict mode, and fail any
  dot-sourced library that sets strict mode for its caller. A full re-run
  against the Premium v2 gateway then finished with exit code 0.

- **An identity with no projection record got 503, "this is not a problem with
  your access", and `Retry-After: 5`.** The policy handled only the resolver's
  200, so its 404 fell through to the branch for an unreachable resolver. Every
  unentitled attempt read as an outage, invited a retry and went uncached.
  Measured before and after on a live gateway: it is now `403 permission_error`,
  cached for at most 60 seconds (the second call took 567 ms). A resolver that
  does not answer still gets 503 until the positive cache runs out. Measured:
  served for 120 seconds with the resolver stopped, then 503.

- **The two syncs charged nested teams to different business units.**
  `Sync-ClaudeAccess.ps1` writes `bu-members` deepest first, with the first
  match winning. `Sync-ClaudeProjection.ps1` applied units in the order given,
  with the last match winning. Anyone in a team and its parent would have moved
  unit at the flip, with no entitlement difference to show for it. The
  projection now reads the registry and parents from the gateway and applies
  the same rule.

- **`Sort-ClaudeBuByDepth` did not keep registry order, although it said it
  did.** `Sort-Object` is not stable. Sorting 2,000 items on a three-valued key
  reordered equal items 960 times in PowerShell 7.6 and 1,011 times in 5.1, and
  a five-unit registry came back in a different order in 5.1. So ADR-0007's
  "first match in registry order" depended on the shell that ran the sync.
  Registry position is now an explicit second key.

- **Re-running the installer would have removed a gateway's VNet integration.**
  `main.bicep` writes the service whenever it created it, and stated only the
  publisher. An ARM what-if against the Premium v2 gateway predicted
  `virtualNetworkType` External -> None, the subnet deleted,
  `publicNetworkAccess` and `customProperties` removed, and both portals
  switched on. Every request to a private deployment would then fail. The
  installer now reads that state over ARM and hands it back, and refuses to
  redeploy a gateway it cannot read. With it, the same what-if predicts none of
  those changes.

- **The Deploy to Azure button deployed the first commit's gateway.**
  `infra/azuredeploy.json` had not been rebuilt since, so it lacked the
  entitlement switch, business units and everything else added since. It is
  rebuilt, and a check compiles `main.bicep` and compares.

- **The projection's cost was understated.** It priced one private endpoint and
  no warm instance: $11.11 a month at 500,000 developers. As deployed, it is
  $69.09, of which $65.28 bills at rest: five endpoints, five DNS zones, and one
  warm resolver instance.

- **U15 had wrongly ruled out Azure Policy.** The control is
  `CosmosDB_PublicNetwork_Modify` in a management-group initiative that
  `az policy assignment list` did not show. The resource's activity log named
  it. The same initiative made the resolver's storage private.

- **The migration runbook described a path that could not be run.** It said
  Basic v2 cannot use the projection (a public resolver works), stood it up
  with one template out of three, had no command to populate it, and compared
  the wrong things. Each step now matches what was run.

- **The installer's own verification reported a healthy new gateway as failed,
  and priced every gateway as Basic v2.** Found by a Premium v2 install in
  canadacentral on 2026-09-23.

  `Show-Governance.ps1` asked for a fixed `claude-sonnet-5`. The new account
  deployed only `claude-haiku-4-5`, so the gateway answered `403
  model_not_allowed`, and the check printed `[FAIL]` with an empty tier. It
  queried a fixed `appi-claude-gateway` component, which did not exist (`404`).
  On the reference gateway that name belonged to the service-level diagnostic's
  component, which held 0 tokens over 7 days while the Claude API's own
  component held 168,438. So the chargeback check there had always reported "no
  metrics yet". The model now comes from the caller's tier list, or from a Claude
  deployment on the account when the tier is unrestricted. The component comes
  from the Claude API's `applicationinsights` diagnostic, falling back to the
  service-level one. A failed check prints the gateway's error code.

  The confirmation screen said "BasicV2 is about $150/month" whatever was chosen.
  The Premium v2 run was approved against it at $2,800/month. It now reads the
  chosen SKU's price in the chosen region from the Azure retail prices API, and
  says so when it cannot. The "30-45 minutes" estimate is gone: the whole
  Premium v2 install took 5 minutes 23 seconds. The closing instructions printed
  `1. Entitle a developer Write-Host ./scripts/...` because two statements
  shared a line. A check across every script now refuses that.

- **The installer could not deploy a Claude model, and the model it would have
  deployed was the wrong one.** Both defects were found by deploying into a new
  Foundry account on 2026-09-23.

  Azure now refuses an Anthropic deployment without
  `properties.modelProviderData` (organisation name, industry, two-letter
  country code) and answers `InvalidModelProviderData`.
  `az cognitiveservices account deployment create` has no parameter for it, so
  every deployment the installer attempted failed. `New-ClaudeDeployment` now
  sends an Azure Resource Manager `PUT` at api-version `2025-12-01`, carrying the
  data. It copies the data from an existing Claude deployment in the subscription
  when there is one. Otherwise it stops and names the three fields before
  touching Azure. It then waits for provisioning to reach `Succeeded`, `Failed`
  or `Canceled` instead of returning at `Creating`. The installer asks for the
  values only when none can be copied, and `-ModelOrganizationName`,
  `-ModelIndustry` and `-ModelCountryCode` supply them unattended.

  The picker chose the highest version string. `claude-haiku-4-5` is listed as
  version `2` (hosted on Azure, `isDefaultVersion` true) and as `20251001`
  (hosted on Anthropic), and `'20251001'` sorts above `'2'`, so the picker
  offered the Anthropic-hosted version. It now picks the version Azure marks as
  default, then an Azure-hosted one, then the highest. The menu shows where each
  version is hosted. The fixed path deployed `claude-haiku-4-5` version `2` in
  66 seconds. `tests/Test-ModelDeployment.ps1` runs the real selection and
  refusal code against that catalogue shape through a stand-in `az`, and six
  mutations restore the old behaviour.

- **A correctly configured Claude Desktop that would not open passed every
  check.** All the Desktop checks read files, so a configuration that was right
  everywhere reported healthy while the app did nothing when launched.

  The cause was named wrongly first. `0x80070020` creating the app container
  looked like a container fault needing a reboot; the deployment log actually
  says `Error while deleting file ...UserClasses.dat. Error Code : 0x20`, and
  `0x20` is `ERROR_SHARING_VIOLATION`. The package's own registry hives are
  held open. `scripts/Get-FileLockOwner.ps1` — Restart Manager, so no
  Sysinternals download and no elevation — attributes the handles to `System`
  (pid 4) and `Registry` (pid 276): the kernel has the hive loaded. It sits in
  the AppX app-hive namespace rather than under `HKEY_USERS`, so `reg unload`
  cannot reach it, and **reinstalling does not help because the lock outlives
  the package**. Signing out or restarting is the only remedy.

  `Test-FoundryDirect.ps1` now detects it without launching anything: a lock on
  those hives while no Claude process is running is the signature.

- **The gateway price was overstated by 67%.** Quoted as ~$250/month in eight
  places; the measured list price is **$150.00** — `Basic v2 Unit` at
  $0.20548/hour over 730 hours, identical in eastus, eastus2 and westeurope.
  `COMPARISON.md` used the figure to advise small teams the gateway was not
  worth it, so the error changed a recommendation.

- **The documented credential pin was a value the client rejects.**
  `AZURE_TOKEN_CREDENTIALS=AzureCliCredential` is refused by Claude Code with
  `Valid values are 'prod' or 'dev'` — the client validates it before
  `@azure/identity` sees it, whatever the library supports. `-Fix` applied that
  value, so running the repair broke a working machine. It is now `dev`.
  `prod` is not an alternative: it excludes the developer credentials, which is
  the sign-in being selected.

  This matters more than it looks. On a Cloud PC, a Dev Box or any Azure VM the
  instance metadata service answers — measured at 10 ms on a Windows 365 Cloud
  PC — so a managed identity is found ahead of the developer's `az login` every
  time. The pin is the default case there, not an edge case.

- **The network check reported the wrong path as healthy.** An explicitly
  supplied empty argument was indistinguishable from an omitted one, so the
  configuration refilled it and the round trip tested the gateway while the
  report named a resource. Detected through `PSBoundParameters` now, and the
  path tested is always printed.

- `SCALE.md` headlined the wrong ceiling. It said *"the binding limit is 110
  developers per tier"* while its own table already gave the business-unit map as
  about 93. A `bu-members` entry is `oid=unit,` — 38 characters plus the unit
  name, against 37 for a bare object id — so business-unit membership runs out
  first, and planning against 110 over-plans by roughly a fifth. Measured on the
  live gateway: 38 characters per entry on the tier lists, 44 on `bu-members`.

- `SCALE.md` now records why the tier cannot be carried in the token. Putting it
  in an Entra app role or the `groups` claim would remove the lookup entirely,
  which is the first alternative anyone proposes for P19. It cannot work: the
  policy validates the audience `https://cognitiveservices.azure.com`, a
  first-party Microsoft resource, and both are configured on the application
  registration the token is issued for — which nobody here owns.

- The README never said how many developers the accelerator actually holds. A
  reader had to reach `docs/SCALE.md` to find out, and the 500,000 figure the
  design discusses reads as a capability when it is a target. It now states the
  measured ceiling — about 90, business-unit membership first — and that the
  projection which lifts it is designed and costed but **not built**.

- `New-ClaudeCodePolicy.ps1` built a Claude Desktop settings block and then
  discarded it. Its own comment said the keys were "emitted here so one run
  produces one tier's complete profile rather than two half-profiles that can
  drift", and nothing ever wrote them, so every Desktop tab setting the script
  has accepted since it was written reached no machine. It now writes
  `claude-desktop.managed-settings.json` and `claude-desktop.reg`.

  The registry form follows the documented encoding: every value is a string,
  including booleans; arrays and objects are a JSON document encoded into one
  string; values sit directly under `HKLM\SOFTWARE\Policies\Claude` because the
  app reads no subkeys; and the file is UTF-16.

- A one-element marketplace list was written as an object rather than an array.
  `allowedPluginMarketplaces` is `object[]`, and piping a one-element array to
  `ConvertTo-Json` unwraps it, so a single allowed marketplace produced `{...}`
  instead of `[{...}]`. Fixed with `-InputObject`.

- `SETUP.md` Options B and C did not say what they leave undone. `deploy.ps1`
  creates the Entra groups and runs the sync, but only `Install-ClaudeGateway.ps1`
  writes `onboarding/claude-gateway.json`, which is the file the developer setup
  script reads — it is the single writer in the repository. The portal button
  deploys the template alone. Both routes now list the remaining commands.

- Two verification sections put the rationale before the command. `SETUP.md` 4.1
  and 4.2 now open with the command. 4.2 also named its controls as "entitlement,
  both budgets, the organisation ceiling and the model allowlist"; "both budgets"
  had no referent on that page.

- Six pages under `docs/` were not linked from the README, including
  `BUSINESS-UNITS.md`, which is a whole feature area. The documentation index
  now carries every guide, a reading order for chargeback and for scale, and the
  project's working record — charter, roadmap, status, unknowns and the decision
  records — which were reachable only by knowing they existed.

  A check derives the list from the directory rather than a written-out set, so
  a new page under `docs/` either gets linked or fails the run. Negative-tested:
  an unlinked page fails with its own name in the output.

  The repository layout listing was also stale — it showed 5 of the 17 scripts
  in `scripts/` and 8 of the 16 pages in `docs/`.

- The roadmap listed P24 twice, once ticked in the delivered section and once
  open in the planned section. The gate counts those markers, so the open
  duplicate was reported as outstanding work that had shipped.

- Two documented claims about revocation were wrong.

  `ONBOARDING.md` showed revocation as `az ad group member remove` against
  `claude-code-standard` only, while its own checklist said "removed from both
  groups". A premium developer, or one in both tiers, kept access. The step is
  now `Set-ClaudeDeveloper.ps1 -Remove -Sync`, which clears both tier groups and
  every business-unit group.

  The same section said a departing employee's access "is revoked at that moment,
  ahead of any sync" once their Entra account is disabled. Disabling an account
  stops new tokens being issued; it does not invalidate one already issued. The
  gateway checks the signature and claims with `validate-jwt` and does not call
  Entra per request, so a token obtained shortly before the account was disabled
  keeps working until it expires. The guide now says to remove membership and
  sync as well.

- `BUSINESS-UNITS.md` said changing a team's tier was "one membership edit in
  Entra" and that "nothing in the gateway changes". It is two edits, and the
  gateway's entitlement lists do change — when `Sync-ClaudeAccess.ps1` next runs.
  That sync is not automatic; this accelerator ships it as a script to schedule,
  so until it runs the old tier still applies.

- `BUSINESS-UNITS.md` described a user's Groups blade as showing "two rows, one
  per axis", and said a missing row was the fault. The blade lists direct
  memberships. Measured on two accounts: one shows its team and its tier, because
  that tier was assigned directly; the other shows only its team, and resolves to
  the same tier and business unit transitively. The business unit never appears
  there. The guide now gives `az ad user get-member-groups`, verified to return
  the full transitive set.

- A service principal in a tier group was never entitled, so adding one was a
  silent no-op and the gateway returned 403 for an identity the portal listed as
  a member. `Sync-ClaudeAccess.ps1` read membership through
  `transitiveMembers/microsoft.graph.user`, which by construction excludes
  workload identities. Measured against `claude-code-premium`, which holds one
  nested team and one service principal:

  | Request | Returned |
  |---|---|
  | `transitiveMembers` | 3 — service principal missing |
  | `transitiveMembers/microsoft.graph.user` | 2 |
  | `transitiveMembers/microsoft.graph.servicePrincipal` | 0 — missing |
  | the same, plus `ConsistencyLevel: eventual` | 0 — missing |
  | the same, plus `$count=true` | 0 — missing |
  | the same, plus **both** | 1 — found |

  A service principal is returned only when the header and `$count` are both
  present. With one or neither Graph answers 200 with an empty collection rather
  than an error, so the sync read "no service principals" and wrote an
  entitlement list without them. The sync now issues both casts with both set.
  On the reference gateway the premium tier went from 2 members to 3 and the
  total from 7 authorised identities to 8. A service principal in no business
  unit is attributed to `unassigned`, which the same run reported rising from 2
  to 3.

- A redeploy would have wiped every business unit, team and membership.
  `Install-ClaudeGateway.ps1` reads `allow-standard`, `allow-premium` and
  `quota-overrides` off the gateway and hands them back so a redeploy cannot
  revoke anyone, but `bu-registry`, `bu-members` and `bu-parents` were never
  added to that list. Their template parameters default to `,,`, so omitting
  them does not preserve them — it clears them. Confirmed against the live
  gateway with `what-if`: with the parameters omitted, all three were planned as
  `,,`; with them supplied, each `after` matched the current value. Every
  existing "a redeploy preserves X" check asserted only the Bicep expression and
  never that the installer supplied the value, which is why this passed for
  three releases — the tests now assert both ends.
- Entitlement could have been granted to a group object. Graph
  `transitiveMembers` returns nested **group** objects as well as users, and
  `Get-GroupMemberOids` did not filter by type. Measured on
  `claude-code-standard` with one team nested inside it: seven objects returned,
  two of them `#microsoft.graph.group`. Those object ids would have been written
  into the entitlement list and the membership map, spending a 4,096-character
  budget that holds about 110 ids, and inflating the count of developers mapped.
  Now uses the typed cast `/transitiveMembers/microsoft.graph.user`, which
  filters server-side — measured five users and no groups. Filtering on
  `@odata.type` in the client would not have worked, because Graph omits that
  property under a cast. The defect predates teams and was unreachable only
  because nothing was nested.
- `Set-ClaudeBudget.ps1 -List` crashed. `{n,>14}` is not valid .NET format
  syntax — the alignment sign belongs on the number, `{n,-14}` or `{n,14}`. It
  parses at read time and throws only when the line runs, so it shipped in
  v1.4.0 and was found by the new format-string check. Two other files carried
  the same mistake.
- `tests/Test-Discovery.ps1` printed `FAIL` and then fell off the end without
  setting an exit code, so `Test-All.ps1` recorded whatever the last child
  process had left behind — including `PASS` for a failed run.
- `tests/Test-PreflightBothHosts.ps1` never checked its own result. It now
  requires each host to print `RESULT=True` or `RESULT=False`; matching the bare
  `RESULT=` label was not enough, because a failed dot-source is a
  non-terminating error and the child carried on to print an empty value.

## [1.5.0] - 2026-09-15

The foundation for business-unit chargeback. Three independent limits were
measured that together made the accelerator a roughly 100-developer system, which
is below the scale at which chargeback is a question worth asking.

### Added

- Chargeback ledger: `analytics/chargeback-ledger.kql`, one row per request with
  the caller attached. Built on the API Management LLM log rather than custom
  metrics, because Microsoft caps a metric dimension at 100 unique values and
  then, in its words, "silently discard[s]" the rest — one dimension per
  developer reaches that at about a hundred people. The log is also the only
  APIM-native source correct for streamed requests: measured 2026-09-15, a
  streamed call reported 11 tokens through the quota scalar where the completion
  was 41. Identity is joined on `context.RequestId`, carried deliberately because
  the log's `CorrelationId` is a GUID and Application Insights `operation_Id` is
  a W3C trace id. Message capture stays off. ADR-0006.
- `scripts/ApimNamedValue.ps1`: writes a named value, refuses an oversized one
  before the call, and throws on a failed one.
- ADR-0005: identity resolution becomes a durable projection synced from Graph
  off the request path, rather than a directory call on a cache miss. Reverses a
  design proposed and rejected the same day.
- ADR-0006: why the ledger is the built-in LLM log, and the four sources it was
  chosen from.
- U9 to U12 in `docs/UNKNOWNS.md`: counter-key cardinality at scale, Graph load
  on a cold cache, ledger ingestion cost against the Basic-Logs purge conflict,
  and cache accounting. U12 is closed below.

### Fixed

- Named value writes fail loudly instead of silently. Every write used
  `az apim nv update ... -o none 2>$null` with no exit check, and named values
  cap at 4,096 characters — measured: 4,096 returns HTTP 201, 8,192 returns HTTP
  400. An object id plus separator is 37 characters, so a tier holds about 110
  developers. Past that the write failed, the error was discarded, and
  `Sync-ClaudeAccess.ps1` reported a successful sync while entitlement silently
  stopped updating. `Show-Governance.ps1` was worse: it lowers `tpm-standard` to
  100 to demonstrate throttling, and a failed restore left the standard tier
  capped at 100 tokens per minute. The restore now runs in a `finally`.

### Changed

- **Behaviour change.** `Sync-ClaudeAccess.ps1` now throws where it previously
  continued. A sync that outgrows the 4,096-character limit fails instead of
  reporting success, so automation that treated a zero exit code as "entitlement
  is current" will now see the failure it was missing.

### Known limitation

- The per-user token budget does not count cache tokens. Measured 2026-09-15:
  two identical calls with a cacheable 10,000-token prompt wrote and then read
  10,003 cache tokens, and both metered 16. This is documented API Management
  behaviour — the `llm-token-limit` policy "currently counts prompt and
  completion tokens only" — but against thirty days of live usage, weighted at
  Claude's published rates where output is 5x base input and a cache read is
  0.1x, **38.7% of the real cost weight is invisible to the budget**. The ledger
  records what the budget cannot see. Correcting the budget itself is M4 work.

## [1.4.0] - 2026-09-03

Claude Enterprise parity: analytics, spend control, capability scoping and
compliance retrieval.

### Added

- `analytics/claude-code-daily.kql` and `scripts/Get-ClaudeAnalytics.ps1`: Claude
  Code usage in the shape of the Claude Code Analytics API, built from the
  gateway's own telemetry. Anthropic's API does not cover Foundry — "Usage
  through ... Claude in Microsoft Foundry ... is not included"
  ([reference](https://platform.claude.com/docs/en/manage-claude/claude-code-analytics-api),
  retrieved 2026-09-02) — so after a migration this is the only source of those
  numbers.
- Organisation-wide monthly spend ceiling: `quota-org`, enforced in the request
  path on a constant counter-key and checked before the per-tier budgets. A soft
  cap; the policy reference states high-concurrency requests can temporarily
  exceed the configured limit.
- The gateway says which budget ran out. Both refusals are `403` with the same
  `LastError.Reason`, and `403` is also what the entitlement check returns, so a
  developer out of budget previously read it as losing access. The reply carries
  `"budget": "organisation"` or `"budget": "personal"`.
- Per-developer daily budget overrides: `scripts/Set-ClaudeBudget.ps1` sets and
  clears them, `scripts/Get-ClaudeBudget.ps1` reports effective limits and spend
  to date. Measured: `token-quota` accepts a policy expression but it must return
  `long`; `Int32` and `string` are both rejected at deploy time.
- Model allowlist per tier: `models-standard` and `models-premium`, enforced
  before the request reaches Foundry. Sentinel commas make the match exact, so
  `claude-opus-5` does not admit `claude-opus-5-mini`.
- `New-ClaudeCodePolicy.ps1 -Tier standard|premium` generates one managed-settings
  profile per entitlement tier.
- Data subject request tooling: `scripts/Find-ClaudeUserData.ps1` reports what the
  telemetry holds about one person and what is actually deletable;
  `scripts/Remove-ClaudeUserData.ps1` purges it and does nothing without
  `-Execute`. Both print the limits — 50 purge requests an hour, a 30-day
  completion SLA with no expedite, Analytics-plan tables only.
- `scripts/Get-ClaudeBypass.ps1`: who can reach Foundry without passing through
  the gateway. It derives the roles granting data-plane access from their
  `dataActions` rather than matching a name, and includes inherited assignments.
  On the reference deployment the documented one-role hand check reported clean
  while 11 assignments could call Foundry directly — three through `Foundry
  User`, which grants the same `Microsoft.CognitiveServices/*` as `Cognitive
  Services User`.
- `scripts/Get-ClaudeTelemetry.ps1`: which Application Insights the gateway is
  actually writing to, resolved from its diagnostic rather than a name.
- ADR-0002 (analytics from two sources), ADR-0003 (telemetry located from the
  gateway), ADR-0004 (policy delivered out of band).

### Fixed

- Usage reports read the Application Insights the gateway is currently writing
  to, instead of a workspace named by convention. The reference deployment moved
  workspaces on 2026-08-31 and nothing noticed: every analytics assertion still
  passed on data that had stopped two days earlier, and `Get-ClaudeBudget.ps1`
  reported `0 used this month` on a gateway that had served hundreds of requests
  that morning. ADR-0003.

## [1.3.0] - 2026-09-02

### Added

- Ironclad engineering discipline: `.ironclad/charter.json`, a vendored
  `gate.mjs`, and the `docs/` ledger — CHARTER, ROADMAP, STATUS, UNKNOWNS and
  ADRs. See ADR-0001.
- `docs/ROADMAP.md` with a parity matrix against Claude Enterprise.
- `docs/UNKNOWNS.md`, so what is not known is written down before it is built on.
- `DEVELOPER.md`: the developer's setup on one page, with a router at the top of
  the README.
- Client screenshots for the CLI, VS Code and Claude Desktop, redacted by
  `guide/redact-clients.mjs` and `guide/redact-terminal.mjs`.

### Changed

- Tests moved from `scripts/` to `tests/`. `Test-Prerequisites.ps1` and
  `Test-FoundryDirect.ps1` stayed, being runtime tooling rather than tests.
  See ADR-0001.
- Documentation states what is true and cites a source, rather than telling the
  reader what matters.

## [1.2.0] - 2026-08-31

Robustness on Windows, and the first migration tooling.

### Added

- `Import-ClaudeEntitlement.ps1`: bulk entitlement from a CSV or an Entra group,
  resolving identifiers four ways because a directory holds a person under
  several addresses.
- `Import-ClaudeMemory.ps1`: lands memory exported from claude.ai into
  `CLAUDE.md`.
- `New-ClaudeCodePolicy.ps1`: managed settings for Claude Code as JSON, `.reg`,
  Intune OMA-URI and `.mobileconfig`.
- `docs/MIGRATION.md`, covering what transfers from Claude Enterprise and what
  does not.
- `tests/Test-AzArguments.ps1`: fails on any `az` argument `cmd.exe` would
  re-parse.
- A project banner, and `.gitattributes` pinning line endings so shell scripts
  survive a Windows contributor.

### Changed

- The installer reuses an existing v2 API Management instance instead of always
  creating one.

### Fixed

- `az --query` mangled on Windows, because `az` is a `.cmd` shim and PowerShell
  only quotes a native argument containing a space.
- Entitlement sync failing on Windows because `&` in a Graph URL reached
  `cmd.exe`; the sync also never paged, silently truncating at 999 members.
- A redeploy resetting the entitlement allow lists to empty, revoking every user.
- Reuse resetting API Management TLS settings, NAT gateway and developer portals
  to defaults.
- `RoleAssignmentExists` when reusing a gateway that already held the Foundry
  role.
- The migration guide's claim that Desktop and Cowork sessions do not transfer.
  An import wizard exists.

## [1.1.0] - 2026-08-28

### Added

- Interactive admin setup, one-command developer setup, and an onboarding email
  template.
- macOS and Linux versions of the admin and workstation scripts.
- An end-to-end health check, `scripts/Debug-ClaudeCode.ps1`.
- A preflight so setup fails early rather than midway.

### Fixed

- The health check detecting the main VS Code process rather than the extension
  host.

## [1.0.0] - 2026-08-19

Initial release.

### Added

- Governed gateway for Claude Code on Microsoft Foundry: API Management Basic v2,
  per-developer token budgets keyed on the Entra object id, tiering from Entra
  group membership, and chargeback telemetry. The gateway holds the only Foundry
  credential; developers authenticate with their own Entra token.
- `Install-ClaudeGateway.ps1` and the Bicep template behind it.
- `Sync-ClaudeAccess.ps1`, syncing Entra group membership into API Management
  named values.
- Task-shaped documentation, an annotated click-by-click UI guide, and the
  Playwright tooling that generates its screenshots.

[Unreleased]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/naveenneog/claude-code-foundry-gateway/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/naveenneog/claude-code-foundry-gateway/releases/tag/v1.0.0
