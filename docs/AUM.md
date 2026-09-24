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
An 80x24 terminal uses the compact **AUM - Azure Usage Management** heading.
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
refresh once; a write is never automatically repeated. Sign out with `az logout`
outside AUM.

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
exceptions. Tab focuses each panel; Enter opens exact source values. The source
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
Modes are displayed here; their policy implementation belongs to the gateway.

![Live redacted Governance view.](images/aum/turnstile-governance-80x24-after.svg)

### Usage

Pivot between units, teams, people, models and surfaces. Rankings are explicitly
top 100. Chargeback export instead enumerates every authorized catalog scope.

![Live redacted Usage view.](images/aum/turnstile-usage-80x24-after.svg)

### Trends

Choose daily, hourly or weekly buckets. Bars compare volume inside the selected
month; Enter retains full precision. Dates are labeled UTC.

![Live redacted Trends view.](images/aum/turnstile-trends-80x24-after.svg)

### Requests

Filter by model or an ISO Before timestamp. A server window holds at most 200
requests; AUM pages it in groups of 50. The server has no useful next cursor,
so this is not presented as an exhaustive history export. Keep timestamp overlap
when inspecting older windows.

![Live redacted Requests view.](images/aum/turnstile-requests-80x24-after.svg)

### Anomalies

Severity, scope, time and details come from the read-only usage-anomalies API.
Acknowledgment and false-positive disposition require separate APIs.

![Live redacted Anomalies view.](images/aum/turnstile-anomalies-80x24-after.svg)

### Settings

Inspect identity, role, managed scope, backend and config. Change the session
theme. Profiles and sign-out are explicit config/Azure CLI operations.

![Live redacted Settings view.](images/aum/turnstile-settings-80x24-after.svg)

### Direct Overview

This capture comes from the gateway's own ledger and published cost function.
Its accounting basis can differ from Turnstile's ingestion. Unknown prices are
not replaced by guessed costs.

![Live Direct Overview with redaction.](images/aum/direct-overview-80x24-after.svg)

## Keyboard, accessibility and safe edits

| Key or option | Behavior |
|---|---|
| `1`–`8`, `0` | Tabs; `0` opens Settings |
| `Tab` / `Shift+Tab` | Focus panels and controls |
| `Enter` | Exact panel/row detail |
| `/` | Filter the visible view; `Esc` clears |
| `Ctrl+F` | Lookup scopes, people, models or `request:<id>` |
| `:` | Search available commands and actions |
| `m`, `r`, `?`, `q` | Month, refresh, help, quit |
| `e` | Edit a selected budget/tier/catalog row when authorized |
| `a` | Preview Apply now on Governance |
| `n`, `p` | Next/previous People or Requests page |
| `--theme high-contrast` | High-contrast terminal palette |
| `--no-color`, `--ascii` | Monochrome or ASCII-cell rendering |
| `--plain`, `--screen-reader` | Linear output; no art or full-screen UI |

Motion is disabled. Status always has words, not only color.

Every governance change starts with Preview. Changing a field invalidates the
preview; server state and role are rechecked. Removal and lowering below usage
require typing the scope id. Apply follows the job without retrying the write.
Whole-catalog/tier APIs lack ETags: avoid concurrent editors.

Person monthly budgets are **saved in Turnstile**, not claimed as gateway
per-person quota enforcement.

### Scoped managers

`manager_scope: null` is unrestricted; an object is scoped even if its lists are
empty. Member alone does not imply a manager. AUM refreshes assignments, clears
stale data and hides unavailable navigation. Managers with assignments retain
the permitted views and remain read-only in this release.

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
pseudonyms. Free-form private descriptions are hidden. Redacted interactive
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

Approvals, expiring boosts, bulk allocation, assistant chat and Turnstile's
separate model gateway administration remain outside the first-release endpoint
contract. See the [parity manifest](../cli/finops/src/claude_finops/parity.json).
