---
title: Use AUM - Azure Usage Management
description: Monitor live Claude gateway usage, budgets and governance in a keyboard-first Azure terminal dashboard.
ms.topic: how-to
---

# Use AUM - Azure Usage Management

AUM provides a terminal dashboard and scriptable commands over the same usage
and governance engine. Run `aum` for the interactive console, or add a noun and
verb for automation. The backend is Turnstile, the gateway directly, or example
data used for tests.

```text
 _____ _____ _____ 
|  _  |  |  |     |
|     |  |  | | | |
|__|__|_____|_|_|_|
```

The ASCII banner appears on a large Overview and terminal `aum --version`.
An 80x24 terminal uses the compact **AUM · Azure Usage Management** heading
(an ASCII hyphen when `--ascii` is selected).
Piped output, `--json`, `--plain` and `--screen-reader` never print the banner
or launch a full-screen application.

> [!IMPORTANT]
> Budgets remain delayed brakes, not exact spend guarantees. Estimated cost is
> not an Azure invoice. A successful save is not proof that every gateway control
> is in effect; AUM reports the apply job's actual status.

## Prerequisites

- Python 3.12 or later and an 80x24 or larger terminal.
- Azure CLI signed in as a person in the relevant Microsoft Entra tenant.
- For Turnstile, its HTTPS origin, API scope and an assigned Turnstile role.
- For Direct, PowerShell 7, this repository, gateway read access and Log Analytics
  access. Writes require effective named-value write permission.

No new tenant consent or permission is needed for an existing Turnstile Owner
and gateway subscription Owner to use the live read views or capture redacted
screenshots.

## Install and sign in

From the repository root:

```powershell
python -m venv .venv-finops
.\.venv-finops\Scripts\python.exe -m pip install -e 'cli/finops[test]'
.\.venv-finops\Scripts\Activate.ps1
az login --tenant <your-tenant-id>
aum --version
aum --help
```

Without activation, use `.\.venv-finops\Scripts\aum.exe`. On Linux, activate
`.venv-finops/bin/activate`. `pipx` is not required.

`claude-finops` remains an alias for one release and emits a deprecation notice
on stderr. The package distribution is `azure-usage-management`; the internal
`cli/finops`, `claude_finops` and `.venv-finops` names are intentionally retained
to avoid disrupting imports, existing configurations and the repository test runner.

## Configure a backend

Use discovery instead of guessing a deployment name:

```powershell
aum configure
aum configure --backend direct --save
aum configure --backend turnstile --save
aum configure --subscription <selected-id> --resource-group <selected-name> `
  --apim-name <selected-name> --backend direct --no-prompt --save
```

The wizard shows numbered real subscriptions, resource groups containing
gateways, API Management instances and workspaces. It prefers the current
subscription, the deployment recorded by `Get-ClaudeGatewayTarget.ps1`, and the
workspace referenced by the gateway's actual diagnostic/logger. Parameters
make the same choices reproducible. It never changes the global Azure CLI
account. `--what-if` never writes even a local profile; `--force` is required
to replace an existing profile.

![Live Azure discovery with names and ids redacted.](images/aum/direct-configure-110x60-after.svg)

Create `%USERPROFILE%\.aum\config.json` (`~/.aum/config.json` on Linux):

```json
{
  "backend": "turnstile",
  "url": "https://api-turnstile.contoso.com",
  "scope": "api://00000000-0000-0000-0000-000000000000/Turnstile.Manage",
  "theme": "gateway",
  "ascii": false
}
```

Select another profile with `--config .\contoso-aum.json` or `AUM_CONFIG`.
`CLAUDE_FINOPS_CONFIG` and `~/.claude-finops/config.json` remain fallbacks.
Command-line options take precedence. Config stores addresses, never tokens.

```powershell
aum whoami --url https://api-turnstile.contoso.com `
  --scope api://00000000-0000-0000-0000-000000000000/Turnstile.Manage
```

Alternatively, configure `resource_group` and `apim_name`; an administrator can
discover URL and scope from the gateway's `turnstile-integration` named value.

AUM obtains a bearer token in memory with Azure CLI. Read authentication can
refresh once; a write is never automatically repeated. Settings offers an explicit
sign-out preview; `az logout` is the equivalent outside AUM. Both affect the shared
Azure CLI session, not only AUM.

### Direct gateway access

```json
{
  "backend": "direct",
  "resource_group": "rg-contoso",
  "apim_name": "apim-contoso",
  "repository": "C:\\work\\claude-code-foundry-gateway",
  "workspace": "00000000-0000-0000-0000-000000000000"
}
```

`workspace` is the Log Analytics Workspace ID, not an ARM resource id.
Publish the repository's `ClaudeCost` function with
`scripts/Publish-ClaudeQueries.ps1` first. It contains the generated price book
and membership map. Request detail reuses `analytics/chargeback-ledger.kql`.

The existing `scripts/Invoke-ClaudeFinOps.ps1` bridge keeps its filename for
compatibility. It uses the shared registry serializers and `Set-ClaudeTier.ps1`,
not a second registry format. Direct writes are refused if Turnstile owns
governance.

Direct mode differs from Turnstile:

- Limits are current, not historical budget versions. Only the current month
  can be edited.
- Monthly person budgets and manager-group authoring require Turnstile.
- Priced trends are daily or weekly, not hourly. Unpriced facts make aggregate
  cost **unknown**, not zero. Cache writes remain unavailable.
- There is no Turnstile anomaly engine or apply job. The panels label these
  limitations rather than implying an all-clear.
- Multi-value catalog/tier writes are not transactional. Refresh after failure.
- New scopes have no monthly budget until one is assigned. Names come from
  their Entra groups; direct mode is not a delegated-manager security boundary.

## Tour the live terminal

The images below are captured from **live backends with display redaction on**.
Their [manifest](images/aum/manifest.json) records backend, UTC capture time,
source commit, dimensions and redaction state. Example renders are kept beside
the snapshot tests, not presented as live documentation.

### Overview

The KPI strip separates monthly usage from allocated-scope budget use. Daily
token and estimated-cost charts share the same time window. Forecast comes from
the server; missing forecasts and prices are labeled unknown.

Top units/teams use proportional bars. Risk and anomaly panels keep attention on
exceptions. Tab focuses each panel; Enter opens selectable ranking, risk or finding
rows, and `d` shows exact source values. Drilldown preserves authorized filters;
a context-only parent unit never becomes a broader manager query. The source
timestamp and fetch timestamp are distinct: fetching does not eliminate ledger lag.

![Live Turnstile Overview, redacted, at 80x24.](images/aum/turnstile-overview-80x24-after.svg)

[Wide Overview](images/aum/turnstile-overview-160x48-after.svg) ·
[Before the redesign, live and redacted](images/aum/turnstile-overview-80x24-before.svg)

### Budgets

Read the unit/team hierarchy with used tokens, budget, remaining usage and
unallocated parent headroom. These are different quantities. The mode badge
shows `STRICT`, `ALLOW +N%` or `NOTIFY` from the catalog's `enforcement` and
`allowance_percent` attributes; absent enforcement means strict.

![Live redacted budget hierarchy.](images/aum/turnstile-budgets-80x24-after.svg)

### People

Choose a team and search on the server, 50 rows at a time. Parent headroom uses
the complete server allocation total, never just the visible page.

![Live redacted People view.](images/aum/turnstile-people-80x24-after.svg)

### Governance

Read units, teams, member and manager groups, enforcement badges, tiers and apply
status. Owners can edit with `e` or choose add/remove/apply in `:` command mode.
Owners choose **Set budget enforcement mode** in `:` to preview strict, allowance
(1–100 percent) or notify. Direct uses the repository's `Set-ClaudeBusinessUnit.ps1`
with `-Mode` and `-AllowancePercent`; it never duplicates the registry serializer.

![Live redacted Governance view.](images/aum/turnstile-governance-80x24-after.svg)

### Usage

Pivot between units, teams, people, models, surfaces and tiers. Rankings are explicitly
top 100. Chargeback export instead enumerates every authorized catalog scope.

![Live redacted Usage view.](images/aum/turnstile-usage-80x24-after.svg)

### Trends

Choose daily, hourly or weekly buckets. Bars compare volume inside the selected
month; Enter retains full precision. **Compare trend periods** in `:` compares
returned month buckets, without filling missing values with invented zeroes.
`f` chooses an explicit time range. Dates display local time and UTC offset;
month accounting remains UTC.

![Live redacted Trends view.](images/aum/turnstile-trends-80x24-after.svg)

### Requests

Filter by model or an ISO Before timestamp. A server window holds at most 200
requests; AUM pages it in groups of 50. When the server advertises the cursor
contract, AUM instead follows its snapshot-bound pages, including tied timestamps.
Until then this is not an exhaustive history export. Keep timestamp overlap
when inspecting older windows. `c` copies the real id and `o` opens its discovered
Log Analytics workspace. Both are hidden during redacted capture.

![Live redacted Requests view.](images/aum/turnstile-requests-80x24-after.svg)

### Anomalies

Severity, scope, time and details come from the read-only usage-anomalies API.
Acknowledgment and false-positive disposition appear in `:` only when the server
advertises the corresponding scoped API.

![Live redacted Anomalies view.](images/aum/turnstile-anomalies-80x24-after.svg)

### Settings

Inspect identity, role, managed scope, backend and config. Change the session
theme, open **Profile / backend**, or preview **Sign out**. A replacement profile
is authenticated before the working connection is closed. **Tour** repeats the
first-run keyboard introduction.

![Live redacted Settings view.](images/aum/turnstile-settings-80x24-after.svg)

### Ask, Approvals and Advanced

**Ask** (`a`) appears when the permitted assistant API exists. Enter a question,
then choose **Ask**. Requests can incur model cost and create conversation history.
The answer and chart rows are the server's response, not client-generated facts.
Choose **Pin** to preview a chart pin; `:` also opens history, pinned reports and
Owner-only model settings. Redacted and `--what-if` sessions never send a question.

![Live assistant availability and settings, redacted; no model query submitted.](images/aum/turnstile-ask-80x24-after.svg)

**Approvals** (`9`) is hidden until the server advertises the budget-request
contract. Its My requests, Waiting for me and History views share the request,
approve, reject and escalate clients. Boosts, notifications and anomaly
dispositions follow their own advertised actions; unavailable actions are hidden.

**Advanced** is read-only and appears only when the connected Turnstile has an
authorized, configured model gateway. Models, backend pools, releases and
application subscriptions belong to that gateway, not the Claude governance
registry. AUM does not reveal keys or offer model-gateway mutations.

The current live connection does not advertise Approvals or expose a configured
Advanced registry. Their 80x24 and 160x48 screenshots are test baselines only,
not mislabelled live documentation.

### Direct Overview

This capture comes from the gateway's own ledger and published cost function.
Its accounting basis can differ from Turnstile's ingestion. Unknown prices are
not replaced by guessed costs.

![Live Direct Overview with redaction.](images/aum/direct-overview-80x24-after.svg)

## Keyboard, accessibility and safe edits

The following interaction evidence was also captured against the live backend,
not FakeBackend:

| Flow | Live redacted evidence |
|---|---|
| Exact panel data | [Detail](images/aum/turnstile-flow-exact-detail-100x30-after.svg) |
| Help | [Help overlay](images/aum/turnstile-flow-help-100x30-after.svg) |
| Command mode | [Commands](images/aum/turnstile-flow-commands-100x30-after.svg) |
| Server-side lookup | [Lookup](images/aum/turnstile-flow-lookup-100x30-after.svg) |
| Local row filter | [Filter](images/aum/turnstile-flow-filter-100x30-after.svg) |
| Month selection | [Month](images/aum/turnstile-flow-month-100x30-after.svg) |
| Model pivot | [Models](images/aum/turnstile-flow-model-pivot-100x30-after.svg) |
| Hourly trends | [Hourly buckets](images/aum/turnstile-flow-hourly-trends-100x30-after.svg) |
| Request paging and detail | [Second page](images/aum/turnstile-flow-request-page-two-100x30-after.svg), [detail](images/aum/turnstile-flow-request-detail-100x30-after.svg) |
| Accessible themes | [High contrast](images/aum/turnstile-flow-high-contrast-100x30-after.svg), [monochrome/ASCII](images/aum/turnstile-flow-monochrome-ascii-100x30-after.svg) |
| CSV export | [Completed export](images/aum/turnstile-flow-export-100x30-after.svg) |
| Server filter chips | [Filter editor](images/aum/turnstile-flow-r4-filters-100x32-after.svg) |
| Private saved view | [Validated local preview](images/aum/turnstile-flow-r4-saved-view-100x32-after.svg) |
| Profile/backend switch | [Validated profile preview](images/aum/turnstile-flow-r4-profile-switch-100x32-after.svg) |
| Sign-out | [Preview only; shared CLI session retained](images/aum/turnstile-flow-r4-signout-preview-100x32-after.svg) |
| First-run tour | [Tour](images/aum/turnstile-flow-r4-first-run-tour-100x32-after.svg) |
| Period comparison | [Live comparison](images/aum/turnstile-flow-r4-comparison-100x32-after.svg) |
| Assistant reads | [History](images/aum/turnstile-flow-r4-assistant-history-100x32-after.svg), [pins](images/aum/turnstile-flow-r4-assistant-pins-100x32-after.svg) |
| Reconciled local report | [Live manifest and totals; no email](images/aum/direct-flow-r4-report-110x36-after.svg) |

| Key or option | Behavior |
|---|---|
| `1`–`8`, `0` | Tabs; `0` opens Settings |
| `Tab` / `Shift+Tab` | Focus panels and controls |
| `Enter` | Exact panel/row detail |
| `/` | Lookup scopes, people, models or `request:<id>` |
| `Ctrl+F` | Filter visible rows; `Esc` clears |
| `f`, click the filter bar | Edit server filters: unit, team, person, tier, model, surface, range |
| `v` | Open a saved view; `:` saves/removes views private to this identity/profile |
| `:` | Search available commands and actions |
| `m`, `r`, `?`, `q` | Month, refresh, help, quit |
| `e` | Edit a selected budget/tier/catalog row when authorized |
| `Ctrl+A` | Preview Apply now on Governance |
| `a`, `9` | Ask and Approvals, only when available and authorized |
| `c`, `o`, `d` | Copy request id, open ledger, exact selected details |
| `n`, `p` | Next/previous People, Requests or Approvals page |
| `--theme high-contrast` | High-contrast terminal palette |
| `--no-color`, `--ascii` | Monochrome or ASCII-cell rendering |
| `--plain`, `--screen-reader` | Linear output; no art or full-screen UI |

Motion is disabled. Status always has words, not only color.

Every governance change starts with Preview. Changing a field invalidates the
preview; server state and role are rechecked. Removal and lowering below usage
require typing the scope id. Apply follows the job without retrying the write.
Whole-catalog/tier writes send `If-Match` only when the server advertises conditional
writes and returns an ETag. A 412 requires a fresh preview; no write is retried.
Until that contract is advertised, avoid concurrent collection editors.

Person monthly budgets are **saved in Turnstile**, not claimed as gateway
per-person quota enforcement.

### Scoped managers

`manager_scope: null` is unrestricted; an object is scoped even if its lists are
empty. Member alone does not imply a manager. AUM refreshes assignments, clears
stale data and hides unavailable navigation. Managers with assignments retain
the permitted views. A unit manager may edit the departments in the server's
`writable_department_ids`; managers may edit person budgets in assigned departments.
Unit budgets, modes, catalog, tiers and explicit Apply now remain Owner-only.
Viewers remain read-only.

Parent units shown for context are not authorized unit filters. Scoped exports
query managed departments, not those context parents. A 403 means **Not in your
scope / not permitted for this sign-in**, never zero usage or token expiry.

## Publish safe live screenshots

```powershell
aum --redact
$env:AUM_REDACT = '1'
aum status --json
```

Redaction is display-time only: numbers and backend requests stay unchanged;
people, addresses and deployment identifiers become deterministic Contoso
pseudonyms. Free-form private descriptions and query-field text are hidden;
selected person ids are still sent unchanged to the API, not echoed into captures.
Redacted interactive
sessions are intentionally read-only to prevent pseudonyms being mistaken for
write targets. Turn redaction off when making an authorized edit.

```powershell
.\.venv-finops\Scripts\python.exe cli\finops\tools\capture_live.py `
  --url https://api-turnstile.contoso.com `
  --scope api://00000000-0000-0000-0000-000000000000/Turnstile.Manage `
  --month 2026-09
```

The capture tool uses live reads, Textual `save_screenshot`, and a privacy guard
before publication. It never saves tokens or unredacted source screenshots.
The guard rejects undocumented images, live images without redaction, non-Contoso
addresses, GUIDs and Azure service hostnames. A mutation test turns redaction off
and proves that the guard catches it.

## Command reference

`--json`, `--plain`, `--what-if`, `--redact`, `--month`, `--backend`, `--config`,
`--url`, `--scope`, `--resource-group`, `--apim-name`, `--theme`, `--no-color`
and `--ascii` work before or after the noun/verb. `--what-if` wins over `--apply`.
Use token suffixes `k`, `M`, `B`; USD strings are rejected.

| Task | Example |
|---|---|
| Identity | `aum whoami --json` |
| Month status | `aum status --month 2026-09 --unit sales` |
| Budgets | `aum budget list` |
| Preview | `aum budget set team sales-emea 9M --what-if` |
| Save and follow | `aum budget set team sales-emea 9M --apply` |
| Warning threshold | `aum budget set team sales-emea 9M --warning 85 --apply` |
| Remove | `aum budget remove team sales-emea --apply --confirm sales-emea` |
| Person budget | `aum budget set person dev@contoso.com 200k --team sales-emea --apply` |
| People search | `aum people find dev --team sales-emea --offset 0 --limit 50` |
| Governance | `aum governance show --json` |
| Apply preview | `aum governance apply --what-if` |
| Apply job | `aum governance apply --apply` |
| Tier view | `aum tier show` |
| Tier limits | `aum tier set standard --per-minute 20k --per-day 500k --apply` |
| Tier models | `aum tier set premium --models claude-sonnet-5,claude-opus-5 --apply` |
| Unit | `aum catalog set unit sales --name Sales --group contoso-sales --apply` |
| Team | `aum catalog set team sales-emea --name "Sales EMEA" --group contoso-sales-emea --parent sales --apply` |
| Manager group | `aum catalog set team sales-emea --manager-group 00000000-0000-0000-0000-000000000001 --apply` |
| Remove scope | `aum catalog remove team sales-apac --apply --confirm sales-apac` |
| Requests | `aum requests list --team sales-emea --limit 50` |
| Older window | `aum requests list --before 2026-09-20T00:00:00Z --limit 200` |
| Request detail | `aum requests show <request-id> --json` |
| Anomalies | `aum anomalies list --month 2026-09` |
| Usage | `aum usage show --dimension model --split-by department` |
| Trends | `aum trends show --interval day --group-by department` |
| Unit chargeback | `aum report chargeback --month 2026-09 --csv > chargeback.csv` |
| Team chargeback | `aum report chargeback --dimension department --csv` |
| Global/bounded lookup | `aum lookup sales-emea --team sales-emea --json` |
| Person detail | `aum people show dev@contoso.com --team sales-emea` |
| Entra membership path | `aum people membership sales-emea` |
| Modes | `aum mode show` |
| Mode preview | `aum mode set team sales-emea allowance --allowance 10 --what-if` |
| Mode save | `aum mode set team sales-emea strict --apply` |
| Bulk person budgets | `aum budget import .\allocations.csv --what-if` |
| Filtered usage | `aum usage show --dimension tier --unit sales --team sales-emea --tier standard` |
| Compared months | `aum trends show --compare 2026-08 --month 2026-09 --interval day` |
| Explicit range | `aum trends show --start 2026-09-01T00:00:00Z --end 2026-09-08T00:00:00Z` |
| Request ledger link | `aum requests ledger <request-id>` |
| Copy request id | `aum requests copy <request-id> --what-if` |
| Saved views | `aum view list` |
| Save a view | `aum view save sales-models --tab usage --unit sales --dimension model --apply` |
| Use a saved view | `aum view load sales-models --json` |
| Remove a view | `aum view remove sales-models --apply` |
| Profile and capabilities | `aum session show --json` |
| Sign-out preview | `aum session signout --what-if` |
| Sign out explicitly | `aum session signout --apply --confirm "sign out"` |
| Ask, with no request sent | `aum ask query "Compare token use by unit" --what-if` |
| Ask and store a conversation | `aum ask query "Compare token use by unit"` |
| Conversation list/detail | `aum ask history`; `aum ask show <conversation-id>` |
| Pinned charts | `aum ask pins` |
| Pin a returned chart | `aum ask pin <conversation-id> <chart-id> "Monthly tokens" --apply` |
| Assistant settings | `aum ask settings` |
| Owner assistant configuration | `aum ask configure --model <advertised-model-id> --auto-title --apply` |
| Advanced models | `aum advanced show models` |
| Backend pool | `aum advanced show pools --key <model-id>` |
| Releases/detail/diff | `aum advanced show releases`; `aum advanced show release --key <release-id>`; `aum advanced show diff --key <release-id>` |
| Application subscriptions | `aum advanced show subscriptions`; `aum advanced show application --key <application-id>` |
| Reconciled completed-month report | `aum report generate --month 2026-08 --unit sales --formats CSV,HTML --apply` |
| Reconciled current-month report | `aum report generate --month 2026-09 --month-to-date --apply` |

The reconciled report delegates to the merged P50 generator. It verifies source
functions and reconciliation before publishing local files. `--send` is separate,
explicit, and requires an already-configured delivery path; AUM never silently
emails a report. Its Azure subscription remains process-local.

Bulk CSV uses a header `team,person,tokens` and optional `warning` percentage.
It accepts at most 500 rows/2 MB, rejects duplicates, validates total allocation
across the complete plan, and shows every normalized change before Apply.

```csv
team,person,tokens,warning
sales-emea,dev@contoso.com,200000,80
```

### Commands waiting on advertised server contracts

These clients are implemented and tested. They return an actionable unavailable
error rather than calling an unadvertised mutation route.

| Task | Example | Required capability |
|---|---|---|
| Request queues | `aum request list --view waiting` | `approvals` |
| Request capacity | `aum request budget team sales-emea 9M "Capacity review" --apply` | `approvals.request` |
| Approve/reject/escalate | `aum request approve <id> "Reviewed" --apply` (or `reject`, `escalate`) | corresponding `approvals` action |
| Active/expired boosts | `aum boost list` | `boosts.read` |
| Temporary boost | `aum boost set dev@contoso.com sales-emea 100k 2099-01-01 "Capacity review" --apply` | `boosts.create` |
| Revoke boost | `aum boost revoke <id> --apply` | `boosts.revoke` |
| Notifications | `aum notifications list` | `notifications.read` |
| Mark read | `aum notifications read <id> --apply` | `notifications.mark_read` |
| Finding disposition | `aum anomalies set-status <id> acknowledged "Reviewed" --apply` (or `false_positive`) | `anomaly_dispositions` |
| Continue request page | `aum requests list --cursor <opaque-cursor>` | `request_cursor` |

Choose a real approved expiry; the far-future sample is syntax only. The server
must reserve headroom and restore the baseline at expiry/revocation. The client
refuses self-approval and tracks a returned gateway apply anchor, but does not
pretend to enforce a server-side quota itself.

Interactive `:` → **Export complete chargeback CSV** writes under
`finops-reports` and never overwrites an existing file.

## Troubleshoot and validate

| Exit / symptom | Fix |
|---|---|
| 2, invalid input | Check month, stable id, token amount and parent headroom |
| 3, 401 | Run `az login` in the correct tenant |
| 4, AADSTS50105 | Ask an existing administrator to check your Turnstile assignment |
| 4, 403 | Choose an assigned scope; see Settings |
| 5, missing scope/route | Check month/id; deploy the compatible Turnstile fork for 405 |
| 6, conflict | Refresh and preview again |
| 7, service/job failure | Check network, Azure access and job logs; do not blindly repeat a write |
| 8, apply still pending | Follow `aum governance show`; the save may already have succeeded |
| Unknown Direct cost | Check unpriced facts and the published `ClaudeCost` price book |

```powershell
.\.venv-finops\Scripts\python.exe -m pytest cli\finops\tests -q
node .ironclad\gate.mjs --stage packet --verbose
```

Test-All uses the worktree `.venv-finops` or reports an explicit skip. Fake SVGs
and exact screen grids live under `cli/finops/tests/snapshots`; regenerate them
deliberately with `cli/finops/tools/capture.py`. Live evidence is separate.

The [revision-4 parity manifest](../cli/finops/src/claude_finops/parity.json)
distinguishes implemented current APIs from named server dependencies. Exact
future request/response contracts ship in
[`contracts.json`](../cli/finops/src/claude_finops/contracts.json).

## Do the same Azure steps by hand

These paths use the resources you discover, not the redacted names in the
screenshots. AUM does not create VNets, subnets, DNS zones, Key Vaults or gateways;
there is no hidden infrastructure deployment to reproduce.

### 1. Choose the subscription, resource group and gateway

1. In the Azure portal, open **Subscriptions** and select the subscription you
   already manage. Check the signed-in account and directory in the top-right menu.
2. Open **Resource groups**, choose the group containing the existing gateway,
   and open its **API Management service**.
3. On **Overview**, verify **Status**, **Resource group**, **Location**,
   **Subscription**, **Subscription ID**, **Gateway URL** and **Tier**.
4. Record your own values locally. The screenshot deliberately replaces names,
   hostnames and ids; do not copy its Contoso placeholders.

![Live API Management Overview, with deployment and account values redacted.](images/aum-portal/gateway-overview.png)

Equivalent Azure CLI:

```powershell
az account list -o table
$sub = Read-Host 'Subscription id from the list'
az apim list --subscription $sub -o table
$rg = Read-Host 'Resource group from the list'
$apim = Read-Host 'API Management name from the list'
az apim show --subscription $sub -g $rg -n $apim `
  --query '{id:id,name:name,location:location,sku:sku.name,gatewayUrl:gatewayUrl}' -o json
```

Verification: the CLI's resource, location and tier match **Overview**. AUM
passes the selected subscription explicitly rather than running `az account set`.

### 2. Read the Turnstile connection and governance authority

1. In the gateway's left menu, expand **APIs** and select **Named values**.
2. Use **Search to filter items by display name and name** to find
   `turnstile-integration`.
3. Open that named value and read **Value**. Copy its `url` and `scope` fields
   into the local AUM profile. Read `governanceAuthority` and `budgetAuthority`
   before deciding where a change belongs.
4. Do not reveal or copy unrelated secret named values. This connection is
   address metadata, not a bearer token.

![Live Named values, redacted before publication.](images/aum-portal/gateway-named-values.png)

Equivalent Azure CLI:

```powershell
$connection = az apim nv show --subscription $sub -g $rg `
  --service-name $apim --named-value-id turnstile-integration --query value -o tsv
$settings = @{}
foreach ($pair in ($connection -split ';')) {
  if ($pair.Contains('=')) {
    $parts = $pair -split '=', 2
    $settings[$parts[0]] = $parts[1]
  }
}
$api = $settings.url.TrimEnd('/')
$scope = $settings.scope
$audience = $scope.Substring(0, $scope.LastIndexOf('/'))
az rest --method get --url "$api/api/v1/auth/me" --resource $audience `
  --subscription $sub --query '{role:role,method:method}' -o json
```

Verification: `/auth/me` reports the expected role and method. This native
`az rest --resource` path was run live as Owner; the CLI obtains the token
without putting it in your command arguments or printing it.

### 3. Find the actual telemetry workspace

1. In API Management, expand **APIs**, then select **APIs**. Select the Claude
   API and inspect **Settings** / its Application Insights diagnostic.
2. Open the referenced **Application Insights** resource, not another resource
   with a similar name.
3. On its **Overview**, find **Logs workspace** and open that workspace.
4. On the workspace's **Overview**, verify **Workspace name**, **Workspace ID**,
   **Subscription**, **Location** and **Access control mode**.
5. Put **Workspace ID** in AUM's `workspace` field. This is not the ARM resource id.

![Live Application Insights with its Logs workspace link.](images/aum-portal/insights-overview.png)

![Live workspace Overview with ids redacted.](images/aum-portal/workspace-overview.png)

Equivalent Azure CLI, following references rather than assuming names:

```powershell
$apimId = az apim show --subscription $sub -g $rg -n $apim --query id -o tsv
$diag = az rest --method get --subscription $sub `
  --url "https://management.azure.com$apimId/apis/claude-foundry/diagnostics/applicationinsights" `
  --url-parameters api-version=2024-05-01 -o json | ConvertFrom-Json
$logger = az rest --method get --subscription $sub `
  --url "https://management.azure.com$($diag.properties.loggerId)" `
  --url-parameters api-version=2024-05-01 -o json | ConvertFrom-Json
$insights = az rest --method get --subscription $sub `
  --url "https://management.azure.com$($logger.properties.resourceId)" `
  --url-parameters api-version=2020-02-02 -o json | ConvertFrom-Json
$workspaceResourceId = $insights.properties.WorkspaceResourceId
az rest --method get --subscription $sub `
  --url "https://management.azure.com$workspaceResourceId" `
  --url-parameters api-version=2023-09-01 `
  --query '{name:name,workspaceId:properties.customerId}' -o json
```

If the API has no diagnostic, inspect the service-level
`$apimId/diagnostics/applicationinsights` instead. The wizard performs that
fallback and offers accessible workspaces when no logger reference can be read.

### 4. Query usage and export a report

1. Open the selected workspace and choose **Logs**.
2. Close **Welcome to Log Analytics** if shown. In the current preview,
   turn **Agent** off and choose **Use Query** when prompted.
3. Select **Simple mode** in the query toolbar, then **KQL mode**.
4. Enter the query below and select **Run** (or **Shift+Enter**).
5. Verify the returned scope, token, cache and cost columns. Use the result
   export control to save CSV. Unknown prices must remain unknown.

```kusto
ClaudeCost(startofmonth(now()), now())
| summarize tokens=sum(prompt_tokens + completion_tokens),
            cache_read_tokens=sum(cache_read_tokens),
            requests=sum(requests), estimated_usd=sum(usd),
            unpriced=countif(not(priced_ok)) by business_unit
| extend estimated_usd=iff(unpriced > 0, real(null), estimated_usd)
```

The mode and Run controls are documented in
[Microsoft Learn's Log Analytics guide](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-simple-mode#switch-modes).
The copied portal session required sign-in before this packet finished the KQL
editor/result capture. Capture stopped; no sign-in was attempted. No loading,
welcome or agent screen is presented as a successful query result.

Equivalent Azure CLI: write the KQL into `query.kql`, then send the JSON body
through a file so shell pipes never become Azure CLI arguments:

```powershell
$workspaceId = Read-Host 'Workspace ID verified above'
@{query=(Get-Content .\query.kql -Raw)} | ConvertTo-Json |
  Set-Content -Encoding utf8 .\query-body.json
az rest --method post --resource https://api.loganalytics.io `
  --url "https://api.loganalytics.io/v1/workspaces/$workspaceId/query" `
  --body '@query-body.json' --subscription $sub -o json
```

AUM's equivalent is `aum report chargeback --csv`. Its complete-catalog export,
and the underlying Direct queries, were run live.

### 5. Inspect or change governance in the correct control plane

1. Read the authority in step 2. If Turnstile is authoritative, **do not edit
   the gateway's named values to bypass it**.
2. In the Azure portal, open the discovered Turnstile **App Service**.
   On **Overview**, verify **Status** and **Runtime status**, then select
   **View app** (called **Browse** in the classic portal experience).
3. In Turnstile, use **Budget Management** for scope budgets and
   **Gateway governance** for units, teams, groups and tiers. Preview the exact
   scope and amount, save, then follow the gateway apply result.
4. If normal web sign-in requires tenant consent that you do not hold, use the
   existing consent-free Azure CLI sign-in path described in [Turnstile](TURNSTILE.md).
   AUM itself uses that already-authorized CLI token, not a new grant.

App Service capture is incomplete: a welcome dialog obscured the blade, so that
image was rejected rather than published as evidence. An approved, signed-in
session is required to recapture it.

The Azure portal does not contain native fields for Turnstile's business-unit,
team or person budgets. **View app** opens the actual management GUI; a portal
database edit would bypass its validation and is not an equivalent safe procedure.

For Gateway authority only, use **API Management > APIs > Named values**:
`tpm-standard` / `tpm-premium` are per-minute tier limits; `quota-standard` /
`quota-premium` are daily limits; `models-*` are model allowlists; `bu-registry`
and `bu-parents` hold the unit/team hierarchy. Open the item, edit **Value** and
select **Save**, preserving every unrelated entry. Check parent allocation
before changing a team. Read the value back after saving.

Equivalent Azure CLI for a direct tier value:

```powershell
$tier = Read-Host 'Existing tier id'
$newLimit = Read-Host 'Approved tokens per minute'
az apim nv update --subscription $sub -g $rg --service-name $apim `
  --named-value-id "tpm-$tier" --value $newLimit -o none
az apim nv show --subscription $sub -g $rg --service-name $apim `
  --named-value-id "tpm-$tier" --query value -o tsv
```

For Turnstile authority, the equivalent REST operation is authenticated by
Azure CLI. Read the original first, write a body file, and follow apply:

```powershell
$month = Read-Host 'Month YYYY-MM'
$team = Read-Host 'Existing managed team id'
az rest --method get --url "$api/api/v1/budgets" --resource $audience `
  --url-parameters "period=$month" --subscription $sub -o json
@{token_limit=9000000; warning_threshold_percent=80} | ConvertTo-Json |
  Set-Content -Encoding utf8 .\budget-body.json
az rest --method put --url "$api/api/v1/budgets/department/$team" --resource $audience `
  --url-parameters "period=$month" --body '@budget-body.json' --subscription $sub -o json
az rest --method get --url "$api/api/v1/gateway-apply" --resource $audience `
  --subscription $sub -o json
```

`9000000` is an illustrative amount, not a deployment default. Choose the
approved value within the parent budget and retain the original for rollback.
Never print a bearer token or manually edit a secret named value to perform
these operations.

Installation, terminal themes, local filters, the banner and screenshot
rendering are local software operations; there is no Azure portal equivalent
because they do not change an Azure resource.

### 6. Change a mode or allocate person budgets

1. Follow **App Service > Overview > View app** to the authoritative Turnstile
   console. In **Gateway governance**, select the existing unit or team.
2. Inspect the current enforcement setting. Choose **strict**, **allowance** or
   **notify**. For allowance, enter an integer percentage from 1 through 100.
   Preserve the member and manager groups and all unrelated scopes.
3. Save, then inspect the gateway apply job. Verify the saved mode and, after
   completion, the gateway's **Named values > bu-modes > Value**. Absence of a
   scope in this value means strict; allowance is serialized as
   `scope-id=allowance:10` between sentinel commas.
4. For person allocation, use **Budget Management**, choose the team and search
   the person before editing. The displayed parent allocation must accommodate
   the entire change, not just the visible page. A person budget is a Turnstile
   budget record, not proof of a new gateway person-counter quota.

Azure CLI equivalent for a mode, using the connection variables established
above. This edits only the selected row but sends the complete preserved catalog:

```powershell
$catalog = az rest --method get --url "$api/api/v1/enterprise-catalog" `
  --resource $audience --subscription $sub -o json | ConvertFrom-Json -AsHashtable
$teamId = Read-Host 'Existing team id from the catalog'
$row = @($catalog.departments | Where-Object id -eq $teamId)
if ($row.Count -ne 1) { throw 'Choose exactly one existing team.' }
$row[0].attributes.enforcement = 'allowance'
$row[0].attributes.allowance_percent = 10
foreach ($unit in $catalog.organizations) { $unit.Remove('parent_id') | Out-Null }
@{
  organizations=$catalog.organizations
  departments=$catalog.departments
  default_department_id=$catalog.default_department_id
} | ConvertTo-Json -Depth 30 | Set-Content -Encoding utf8 .\catalog-body.json
az rest --method put --url "$api/api/v1/enterprise-catalog" --resource $audience `
  --subscription $sub --body '@catalog-body.json' -o json
az rest --method get --url "$api/api/v1/gateway-apply" --resource $audience `
  --subscription $sub -o json
```

Read and retain the original before editing. `10` is an illustrative approved
percentage, not a deployment default. For strict or notify, remove
`allowance_percent`; it is invalid outside allowance mode. If conditional writes
are advertised, include the current ETag as `If-Match`; a conflict requires rereading.

For bulk person allocation, the equivalent supported API is:

```powershell
$personId = Read-Host 'Person id returned by the selected team search'
@{
  department_id=$teamId
  selection='ids'
  user_ids=@($personId)
  allocation_mode='fixed'
  token_limit=200000
  warning_threshold_percent=80
} | ConvertTo-Json | Set-Content -Encoding utf8 .\bulk-budget-body.json
az rest --method post --url "$api/api/v1/budgets/users/bulk" `
  --resource $audience --subscription $sub --url-parameters "period=$month" `
  --body '@bulk-budget-body.json' -o json
```

`200000` and `80` are illustrative, not defaults read from a deployment.
Verify with `GET /api/v1/budgets/users?period=...&department_id=...&query=...`.
The portal has no native Turnstile bulk-budget blade; do not replace the
validated endpoint with a database edit. AUM's CSV client groups only the
prevalidated people/amounts and reports partial failure without retrying a write.

### 7. Inspect a request or move team membership

1. In **Log Analytics workspace > Logs**, use **KQL mode** and the repository's
   `analytics/chargeback-ledger.kql` query. Add a filter for the selected
   `request_id`. Select **Run** and verify the request id, timestamp and unit/team
   fields against the terminal detail.
2. AUM's `o` action builds this workspace link from the discovered ARM workspace
   id and tenant. `c` copies only the selected id; it does not modify Azure.
3. For membership, open **Microsoft Entra ID > Groups > All groups**, select the
   team member group recorded in the catalog, and open **Members**.
4. Only with existing group-owner/directory rights, use **Add members** on the
   target group and **Remove** on the former group. Verify both member lists.
   Directory propagation and gateway projection refresh are separate from the
   budget apply job. Do not grant yourself permissions to make this example work.

Azure CLI equivalents:

```powershell
$group = Read-Host 'Member group name or object id from the catalog'
az ad group show --group $group --query '{id:id,displayName:displayName}' -o json
az ad group member list --group $group --query '[].{id:id,displayName:displayName}' -o table
# After explicit approval, using the existing member's object id:
$personObjectId = Read-Host 'Verified person object id'
$targetGroup = Read-Host 'Verified target member group'
az ad group member add --group $targetGroup --member-id $personObjectId
az ad group member remove --group $group --member-id $personObjectId
```

These directory writes were not performed for this packet. The running account's
gateway/Turnstile Owner role does not imply directory membership-management rights.
AUM opens the discovered group blade rather than inventing or requesting grants.

### 8. Ask, pin and inspect optional model-gateway views

1. Open the actual Turnstile GUI through **App Service > Overview > View app**.
   Choose **FinOps Assistant** with an unrestricted authorized sign-in. Scoped
   manager profiles do not gain access by opening the URL directly.
2. Review the selected model/cost settings. Submit a question only when its
   model cost and persistence are intended. Pin a chart actually returned by
   that conversation; the client must not fabricate chart rows.
3. If the connected Turnstile operates its own model gateway, open its model,
   backend-pool, release or subscription views. AUM exposes those same
   authorized reads, never key-reveal or provisioning operations.

Equivalent Azure CLI reads, with token acquisition kept inside Azure CLI:

```powershell
az rest --method get --url "$api/api/v1/assistant/settings" `
  --resource $audience --subscription $sub -o json
az rest --method get --url "$api/api/v1/assistant/conversations" `
  --resource $audience --subscription $sub -o json
az rest --method get --url "$api/api/v1/assistant/pinned-charts" `
  --resource $audience --subscription $sub -o json
az rest --method get --url "$api/api/v1/model-management" `
  --resource $audience --subscription $sub -o json
```

The last read may return 403 or no configured models; that is not an instruction
to request broader permissions. For an intended assistant invocation, write
`question`, `history`, `conversation_id`, `timezone` and `locale` to a JSON body
file and POST `/api/v1/assistant/ask`. A pin POSTs `title`, `description`,
`original_question` and the exact returned `chart` to
`/api/v1/assistant/pinned-charts`. The matching `aum ask` commands avoid hand-copying
response charts. This packet's live assistant evidence is read/preview evidence;
it is not a claim that a model invocation or pin write was performed.

### 9. Reports, local preferences and future service workflows

1. For a manual usage CSV, use **Log Analytics workspace > Logs > Run** and the
   result export control in step 4. This is a raw query export, not a substitute
   for P50's streaming reconciliation, provenance manifest and per-unit files.
2. `aum report generate` runs that existing generator. The report output remains
   local unless explicit `--send` is requested. No Azure portal blade performs
   the whole local reconciliation algorithm; the GUI path inspects its saved
   query functions and exported results instead.
3. Profiles, saved views and tour state are local to AUM. Use **Settings >
   Profile / backend**, `v` or `:`. Azure CLI's equivalent sign-in/session reads
   are `az account show` and `az account list`; `az logout` is the explicit shared
   session sign-out, not a harmless preview.
4. Approvals, boosts, notifications and anomaly dispositions have no live
   Turnstile GUI/portal counterpart on this connection yet. The packaged
   contract names every required endpoint. Do not manually edit storage to
   simulate approval, expiry or acknowledgment.

The live portal captures above are partial. Authentication stopped the capture
journey before KQL result evidence; no expired profile is reused and no sign-in
is attempted. The automated completeness check deliberately remains red until
the missing live portal evidence can be obtained through an approved session.
