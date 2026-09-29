---
title: AUM - Azure Usage Management
description: Monitor live Claude gateway usage, budgets and governance in a keyboard-first Azure terminal dashboard.
ms.topic: how-to
---

# AUM - Azure Usage Management

AUM is an independent FinOps tool for an existing Claude gateway. It provides a
terminal dashboard and scriptable commands over one engine. **Turnstile is not a
prerequisite.** Without an explicitly configured HTTP backend, AUM defaults to
**Direct**: Azure CLI, the gateway's named values, Log Analytics and the repository's
PowerShell writers. `aum` opens the console; a noun and verb select a scriptable
operation.

An optional **AUM service** adds its own Entra roles and server-enforced scoped
management, without Turnstile. Administrators can instead choose Turnstile as
their web FinOps tool; AUM can optionally use its API as another keyboard-facing
client. Example data is an explicit test backend, never the production default.

## Install

AUM requires Python 3.12 or later and Azure CLI. Direct also requires
PowerShell 7 and this repository. The
[package manifest](../cli/finops/pyproject.toml) defines the Python requirement;
the [installer](../scripts/Install-ClaudeAum.ps1) reads that requirement rather
than pinning one interpreter.

### Windows

The repository installer creates or reuses `.venv-finops`, installs AUM,
checks its version and Azure CLI sign-in, and starts read-only connection
discovery. It lists compatible installed interpreters (`py -0p`, then PATH)
when `-Python` is omitted. No Azure resource is created or changed.

```powershell
.\scripts\Install-ClaudeAum.ps1
```

`-WhatIf` prints the installation plan without writing. `-NoConfigure` stops
after the installation check, and `-WithTests` includes test dependencies.
The equivalent manual installation and sign-in commands are:

```powershell
python -m venv .venv-finops
.\.venv-finops\Scripts\python.exe -m pip install -e 'cli/finops[test]'
.\.venv-finops\Scripts\Activate.ps1
az login --tenant <your-tenant-id>
aum --version
aum --help
```

Without activation, the executable is `.\.venv-finops\Scripts\aum.exe`.
The signed-in Azure CLI account supplies Direct credentials and the existing
app tokens for HTTP backends
([credential implementation](../cli/finops/src/claude_finops/config.py)).

### macOS and Linux

The Python package uses the same engine and command entry point on macOS and
Linux. The equivalent shell commands from the repository root are:

```bash
python3 -m venv .venv-finops
. .venv-finops/bin/activate
python -m pip install -e cli/finops
aum --version
az login --tenant <your-tenant-id>
```

`--plain` and `--screen-reader` select linear output without the terminal UI.
The [prerequisites](#prerequisites) describe backend-specific roles. `pipx`
is not required.

### Run AUM in Azure Cloud Shell

The [Cloud Shell launcher](../scripts/aum-cloudshell.sh) runs from a checkout
of this repository in a Cloud Shell **Bash** session. It uses the session's
already authenticated `az`; it does not run `az login`, change the selected
Azure account, create storage or deploy an Azure resource.

```bash
bash scripts/aum-cloudshell.sh --dry-run
bash scripts/aum-cloudshell.sh -- configure --backend direct \
  --resource-group "$GATEWAY_RESOURCE_GROUP" --apim-name "$GATEWAY_NAME" \
  --save --no-prompt
bash scripts/aum-cloudshell.sh
```

`GATEWAY_RESOURCE_GROUP` and `GATEWAY_NAME` identify an existing gateway.
The configure command discovers its connection addresses and saves the local
profile; existing-profile replacement retains AUM's normal confirmation and
backup rules. An existing saved profile can be used by the last command
without another configure step. Arguments after `--` are passed literally
to AUM, including HTTP-backend options.

The launcher creates or reuses `$HOME/.aum-cloudshell/venv`. Its pinned uv
bootstrap, managed Python 3.12, downloads, temporary files, bytecode and caches
also stay under `$HOME/.aum-cloudshell`; editable package metadata stays in
the checkout. The documented Cloud Shell image lists Python 3.9, which is
below AUM's requirement, so the launcher does not assume the system Python
can run AUM. uv comes from a pinned binary wheel, not a downloaded shell
installer. The first bootstrap has a 2-5 minute estimate; cached dependency
setup has a 10-60 s estimate. Bootstrap requires access to PyPI and uv's Python
download hosts as well as the application's Azure endpoints.

The storage-specific Microsoft Learn article describes `$HOME` persisted as
an image in the attached Azure file share; that mode retains the venv between
sessions. Ephemeral sessions without attached storage lose the venv and the
checkout when the session ends. The current FAQ's HOME wording conflicts with
the storage-specific article and Features page; this discrepancy and the
unperformed live persistence check are recorded in
[ADR-0041](adr/0041-aum-session-safety-and-cloud-shell.md) and U61 in
[UNKNOWNS](UNKNOWNS.md). No live Cloud Shell success is claimed.

Direct uses public ARM (`management.azure.com`), Log Analytics
(`api.loganalytics.io`) and Graph (`graph.microsoft.com`) endpoints, with the
same existing caller permissions as a workstation. An AUM service or
Turnstile endpoint behind private networking requires Cloud Shell deployed
into a connected Azure VNet, including the required DNS/routing. The launcher
does not provision that VNet deployment. Conditional Access location rules
can still apply to the Azure egress addresses used by Cloud Shell; it is not
an exemption from the tenant's policies.

Cloud Shell sessions end after about **20 minutes without interactive
activity**. A long-running command or terminal redraw is not a persistence
guarantee. Browser and Cloud Shell shortcuts can intercept keys; the `:`
command palette reaches AUM's available actions without depending on those
browser shortcuts. Native field editing and modal buttons remain accessible
with Tab and Enter.

Sources, accessed 2026-09-29:
[Cloud Shell features/tools and automatic authentication](https://learn.microsoft.com/azure/cloud-shell/features),
[persisted HOME and clouddrive](https://learn.microsoft.com/azure/cloud-shell/persisting-shell-storage),
[ephemeral sessions](https://learn.microsoft.com/azure/cloud-shell/get-started/ephemeral),
[idle timeout](https://learn.microsoft.com/azure/cloud-shell/faq-troubleshooting),
[Deploy Azure Cloud Shell in a virtual network](https://learn.microsoft.com/azure/cloud-shell/vnet/deployment),
[private-network reachability](https://learn.microsoft.com/azure/cloud-shell/vnet/overview),
[terminal/browser shortcuts](https://learn.microsoft.com/azure/cloud-shell/use-the-shell-window),
[CAE and differing IP addresses](https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot#ip-address-configuration).
The AUM endpoint facts come from
[Direct](../cli/finops/src/claude_finops/direct.py) and
[Graph](../cli/finops/src/claude_finops/groups.py).

## Connect

Each gateway has one budget/governance write authority. P80 does not change the authority
rules in [ADR-0026](adr/0026-usd-budget-reconciliation.md) or the publication
rules in [ADR-0035](adr/0035-aum-bounded-readiness-and-progressive-reads.md).

| Backend | Token budgets | USD budgets | Add a person | Chargeback | Managers | Cost and where it runs |
|---|---|---|---|---|---|---|
| Direct | Yes, through repository scripts and gateway named values | Yes when the gateway owns USD budgets | Yes, with the signed-in admin's delegated Graph rights | Yes, local CSV; reconciled P50 report when installed | No unit-scoped boundary; Azure RBAC is administrative | No AUM server. Runs on the operator workstation; existing gateway and Log Analytics costs remain |
| AUM service | Yes, through the service's revisioned API | Yes when advertised by capabilities | Unavailable; this backend has no membership writer | Yes; service-scoped data plus local report generation | Yes, through `AUM.Manager` and manager groups | Azure Functions and Storage, plus selected monitoring/network resources |
| Turnstile | Yes, through Turnstile's API and apply job | Unavailable; no USD writer is added in P80 | Directory membership remains the AUM/script/portal path | Yes for authorized Turnstile data | Yes, through Turnstile roles and manager groups | Existing Turnstile App Service, PostgreSQL and jobs; the AUM client adds no server |
| Example | Demonstration data only | Demonstration data only when tests enable it | No production directory | Demonstration CSV | No production role | Local tests only |

The connection commands are:

```powershell
aum configure --backend direct --save
aum configure --backend aum-service --url https://<function-app>.azurewebsites.net --scope api://<app-id>/AUM.Access --save
aum configure --backend turnstile --url https://<turnstile-app>.azurewebsites.net --scope api://<app-id>/Turnstile.Manage --save
```

In the terminal, **Settings > Change connection** opens one form for the backend
and its address fields, without requiring an existing JSON file. The screen
names the current backend as `via Direct`, `via AUM service` or `via Turnstile`.
A preview shows the current and proposed profile. **Save and connect** keeps
an exact-byte timestamped backup, replaces the selected local profile atomically
and verifies both `whoami` and the saved profile revision before adopting the
connection or dismissing the form. A failed verification
keeps the prior live connection and attempts to restore its file; with no prior
profile, recovery removes the new file. A failed restore remains an error in
the form, with the backup path and steps to release the file lock and restore
the old file or remove an unverified first profile. The previous identity,
configuration and cached UI remain active. Recovery feedback receives keyboard
focus; Up/Down, Page Up/Page Down and Home/End scroll its complete wrapped text
at 80x24. The form stays open until the operator closes it or a later connection
succeeds.

The reviewed candidate bytes and prior revision remain unchanged through
Apply. AUM writers share an OS-held lock on a sibling `.config.json.lock`
file for comparison, backup, replacement and verification. The lock is released
when its handle closes; the empty sibling file remains. Another active AUM
writer is refused rather than retried. Changed address-field names and both
revisions appear in a conflict message; a detected newer file is not overwritten.
The expected saved revision comes from the written bytes, so a post-save read
failure stays inside rollback protection. This lock coordinates AUM writers,
not external editors that ignore it
([ADR-0038](adr/0038-aum-actions-and-connection.md#council-round-1-amendment)).
The normal discovery-preview estimate is 3-30 s; identity verification shows
a 3-10 s estimate. These are progress estimates, not availability guarantees.

An attended `aum configure --save` asks before replacing a profile and keeps
the same backup. Unattended replacement requires `--force`. Explicit HTTP
URL/scope pairs do not require Azure resource discovery. Profiles contain
addresses, not tokens. `--config`, `AUM_CONFIG` and the legacy fallbacks are
described in [Configure a backend](#configure-a-backend).

## First run and screen tour

The terminal entry point is:

```powershell
aum
```

The header shows the month, backend and role, for example
`2026-09 | via Turnstile | owner | admin@contoso.com`. `1` through `8` select
the main views; `0` opens Settings. `?` opens the current key map. The detailed screen tour is
kept in [Tour the live terminal](#tour-the-live-terminal), including Overview,
Budgets, People, Governance, Usage, Trends, Requests, Anomalies and Settings.
Those live images are historical measurements with their original provenance.
Current P85 layout examples use explicit Example data, not a live deployment:
[People, 80x24](../cli/finops/tests/snapshots/svg/people-80x24.svg),
[Budgets, 160x48](../cli/finops/tests/snapshots/svg/budgets-160x48.svg) and
[Settings, 80x24](../cli/finops/tests/snapshots/svg/settings-80x24.svg).
The [snapshot manifest](../cli/finops/tests/snapshots/manifest.json) records
source and output hashes for all 24 screen images. Text hashes normalize
Windows CRLF and Unix LF line endings to the same UTF-8/LF representation.

Escape clears a filter, returns along a breadcrumb or dismisses a modal; it
does not request application exit. A single `q` opens a quit confirmation.
A second `q` or Enter confirms; Escape stays in AUM. **Quit AUM**, **Clear
filter or go back**, and the context-dependent **Next page** / **Previous
page** actions are also in the `:` palette.

Expected refresh failures remain visible rather than terminating the terminal.
Network/I/O failures and HTTP 401/403 have plain status explanations; an
explicit refresh (`r`, normally estimated at 3-5 s) retries the read, not a
mutation. The CAE `InteractionRequired` / `LocationConditionEvaluationSatisfied`
challenge gets an IP-variation explanation: consistent on/off VPN use,
IPv4/IPv6 differences, and administrator review of a named location or an
appropriate policy exclusion. No policy exception is granted by AUM.
The Azure CLI boundary recognizes that challenge without echoing raw stderr
([CAE guidance](https://learn.microsoft.com/entra/identity/conditional-access/howto-continuous-access-evaluation-troubleshoot#ip-address-configuration),
accessed 2026-09-29;
[error boundary](../cli/finops/src/claude_finops/errors.py),
[pilot matrix](../cli/finops/tests/test_p85_escape.py)).

## How-to

### Add a person to a team

In **People**, the team selector and email/UPN search identify the intended
scope. **Add person to team** (`g`) is available to owners through Direct and
Turnstile-backed gateway configurations. If the search has no result and the
caller has that action,
the empty state offers `Add <email> to <team>`. The form searches Entra, loads
the team/unit catalog on demand, previews the chosen tier addition, other-tier
removal and optional unit/team group addition, and writes only through Apply.
The palette name is **Add developer**. The selected email and team are filled
in the add flow. No prior visit to Budgets is required. Non-owners see a plain
explanation rather than an add offer.
The AUM-service backend does not support this membership flow:
[`developer_actions.py`](../cli/finops/src/claude_finops/developer_actions.py)
accepts only Direct and Turnstile-backed gateway configurations. People and
Budgets disable **Add person to team** with that explanation on AUM service;
neither its shortcut nor its command-palette entry opens a membership writer.
Directory/catalog reads and preview have a 3-10 s estimate; apply has a
3-30 s estimate. Done returns to People and refreshes its selected scope.
People contains observed usage, not a directory roster: a newly added account
can remain absent until an observed request is available. The
[offline pilots](../cli/finops/tests/test_p85_people.py) exercise both
authority paths and refreshed endpoint responses, not live ingestion latency.

CLI:

```powershell
aum developer find amara@contoso.com
aum developer add amara@contoso.com --tier standard --unit sales-emea --what-if
aum developer add amara@contoso.com --tier standard --unit sales-emea --apply
```

### Remove a person from a team

In **People**, **Remove person from team** (`h`) sits beside the add action.
The palette has the same name. An owner selects the resolved account in the
Entra picker. The preview shows its object id and email/UPN, every planned
tier and catalog unit/team group removal with the group's id, and the
`allow-standard` and `allow-premium` publication targets. This removes
gateway access across those groups, **not just the selected team**.
Listed direct memberships that are already absent are no-ops; groups are not
deleted. The resolved email/UPN is the required typed confirmation, including
the resolved guest UPN when it differs from the searched email.

Field edits invalidate the preview. A new Preview after the confirmation
enables Apply; a blank or different confirmation is refused by the existing
[`developer_change(remove=True)` engine](../cli/finops/src/claude_finops/developer_actions.py).
Non-owners and the AUM service backend cannot open this writer. Directory and
preview reads have a 3-10 s estimate; apply has a 3-30 s estimate. The result
names the resolved account and publication path. Done refreshes People
(estimate 3-10 s), whose historical observed rows can remain after removal.
Removal does not erase usage or revoke an already-issued Entra token.

Direct permits an empty allow list only for a changed tier whose last direct
member was removed and whose post-write member read is empty. The other tier's
empty-list guard remains in force. Turnstile retains its existing delegated
publish-as-admin path. These rules come from the
[membership engine](../cli/finops/src/claude_finops/developer_actions.py) and
[access sync](../scripts/Sync-ClaudeAccess.ps1), and are covered by
[engine tests](../cli/finops/tests/test_developers.py) and
[terminal pilots](../cli/finops/tests/test_p85_people.py).

CLI:

```powershell
aum developer remove amara@contoso.com --what-if
aum developer remove amara@contoso.com --confirm amara@contoso.com --apply
```

### Create a unit or team

The `:` palette entry **Add unit or team** opens GroupPicker. An Entra group
prefix search and Enter select an assigned-membership security group; the
catalog form carries its group id and name. The form's Unit/Team choice,
stable id and display name describe the new scope. A team requires an existing
parent unit. The separate **Find or create Entra security group** palette
entry exposes group discovery/creation; creating a group alone does not add
a catalog scope.

Preview validates a fresh catalog and reports **Replace catalog**; the form
shows the proposed scope, group and parent. Apply submits the complete
catalog through the selected existing writer. Group search and preview have
a 3-10 s estimate, and the save estimate is 3-30 s. Direct returns its verified
receipt; Turnstile normally applies in about two minutes, with terminal
following limited to three minutes. Done refreshes Governance. The
[catalog pilots](../cli/finops/tests/test_p85_catalog.py) cover both a new unit
and a team under an existing unit on Direct and Turnstile, including exact
catalog request bodies.

### Remove a unit or team

In **Governance** (`4`), the selected unit/team and the `:` palette entry
**Remove selected budget or scope** identify a catalog removal. The form
requires the scope's stable id, not its display name. Preview reports
**Replace catalog** after validating the current catalog; Apply checks the
typed id and saves the remaining collection. The same palette entry in
Budgets or People clears a budget instead of deleting a catalog scope.
Preview has a 3-10 s estimate and the save estimate is 3-30 s. Turnstile
normally applies in about two minutes, with terminal following limited to
three minutes; Direct returns a verified receipt without that job.

The [engine](../cli/finops/src/claude_finops/engine.py) refuses a unit while
it has any child department, including a synthetic unit-direct department.
It also refuses the default department and removal of the last business unit.
It has no empty-Entra-membership requirement: an otherwise removable scope
can still have members. Catalog removal does not delete the Entra group or
remove those directory memberships. The
[Direct/Turnstile pilots](../cli/finops/tests/test_p85_catalog.py) prove these
rules, wrong-id refusal and the actual catalog-only writes.

### Set a person's budget

In **People**, **Set budget** (`e`) opens a preview for the selected writable
person. With no selected person, the button is disabled and its hint explains
the required selection. A person with no row cannot be edited; membership and
the selected team/month determine which observed rows are available. The
palette entry is **Edit selected budget or governance row** for owners, or
**Edit selected delegated budget** where delegated writes are permitted.
Preview shows the previous/proposed token amounts and parent headroom.
Direct person limits are daily gateway overrides; Turnstile person budgets
are monthly server records, not gateway quotas. Destructive changes require
the selected row's scope id. Preview has a 3-10 s estimate and save has a
3-30 s estimate. Direct completes with its native receipt rather than a
Turnstile-only message
([engine](../cli/finops/src/claude_finops/engine.py),
[pilots](../cli/finops/tests/test_p85_budgets.py)).

CLI:

```powershell
aum budget set user amara@contoso.com 100k --team sales-emea --what-if
aum budget set user amara@contoso.com 100k --team sales-emea --apply
```

Those email-key examples describe Turnstile rows. Direct uses the observed
person's Entra object id from the selected row instead of the email.

### Set a team or unit budget

In **Budgets**, **Set budget** (`e`) opens the selected unit or team.
The palette name is **Edit selected budget or governance row** for owners.
The preview shows previous/proposed token amounts and parent headroom from
current server state. Units and teams use monthly tokens. A reduction below
observed usage or an unknown-usage change requires the stable scope id.
Preview has a 3-10 s estimate and save has a 3-30 s estimate. Direct and AUM
service return synchronous receipts; the service also requires an audit
reason. Turnstile normally applies in about two minutes, with terminal
following limited to three minutes
([engine](../cli/finops/src/claude_finops/engine.py),
[pilots](../cli/finops/tests/test_p85_budgets.py)).

CLI:

```powershell
aum budget set unit engineering 30M --what-if
aum budget set team sales-emea 8M --apply
```

### Set a USD budget

**Set USD budget** (`u`) is available where the backend advertises
`usd_budgets.write`. USD is the default budget unit on that form. If the backend
does not advertise the writer, People and Budgets show a disabled USD action
and an explanation. Direct and AUM service USD writes also depend on the
gateway's recorded authority and the caller's permissions. A connection change
does not change that authority. Ordinary token-budget forms keep their existing
default; USD is not made the default everywhere.
The palette name is **Edit selected USD budget** and uses the same selected-
scope permission as the button and key. Preview shows the old and proposed
USD amounts and **Saved; awaiting reconciliation**; decimal text is preserved
to nine fractional places. Units and teams are monthly; people can be daily
or monthly. AUM service requires an audit reason and sends the reviewed
revision through If-Match. Preview has a 3-10 s estimate and save has a
3-30 s estimate. A successful save remains awaiting reconciliation and does
not wait for a Turnstile apply job.

The shipped service reconciliation timer runs every five minutes; the next
scheduled run is therefore normally within about five minutes, plus its
execution and gateway propagation time. Direct reconciliation is a separate
action. Neither a save nor this schedule proves enforcement. Turnstile shows
the existing disabled explanation, **USD budget writes need Direct or the
AUM service. P81 brings USD to Turnstile.**, without substituting a token
write
([timer](../service/aum/function_app.py),
[engine](../cli/finops/src/claude_finops/engine.py),
[complete USD pilots](../cli/finops/tests/test_p85_budgets.py)).

CLI:

```powershell
aum usd set unit engineering 250.00 --what-if
aum usd set team sales-emea 75.00 --apply
```

### Create a chargeback report

**Chargeback report** (`x`) in People or Budgets writes the
complete chargeback CSV for the current month to a default local report folder
and shows its full path without another Export click. The folder is
`Documents/AUM` under the Windows home directory, or `~/aum-reports` on macOS
and Linux. Existing files remain unchanged; collisions get numbered names,
including a collision during exclusive file creation. **Export complete
chargeback CSV** in the command palette retains the optional custom filename.

When the P50 generator is installed, **Generate reconciled chargeback report**
opens its existing preview-first form for authorized owners. This is separate
from the CSV action and does not send email by default. The complete-scope read
shows a 3-30 s progress estimate; the [dated report measurement](#command-reference)
is not a runtime promise for another deployment.

CLI:

```powershell
aum report chargeback --month 2026-09 --output "$HOME\Documents\AUM"
aum report generate --month 2026-09 --output finops-reports --formats CSV,HTML --what-if
```

### Change the connection

**Settings > Change connection** displays the current `via ...` connection and
the replacement fields. Its preview, backup, verification and rollback are
described in [Connect](#connect).

CLI:

```powershell
aum configure --backend direct --save
aum configure --backend turnstile --url https://<turnstile-app>.azurewebsites.net --scope api://<app-id>/Turnstile.Manage --save
```

### Remove a person

The developer removal command previews Entra membership removal and requires
confirmation. The terminal's **Remove selected budget or scope** action removes
the selected budget or catalog scope, not the person's Entra membership.

CLI:

```powershell
aum developer remove amara@contoso.com --what-if
aum developer remove amara@contoso.com --apply --confirm amara@contoso.com
```

### Find someone

In **People**, the selected team and **Search people** field define the query;
Enter submits it. `/` opens a bounded lookup across scopes, people, models and
requests.

CLI:

```powershell
aum people find amara@contoso.com --team sales-emea
aum lookup amara@contoso.com --team sales-emea
```

## Reference

Command syntax is in [Command reference](#command-reference). Backend-specific
details remain in [Direct gateway access](#direct-gateway-access),
[Optional independent AUM service](#optional-independent-aum-service) and
[Optional workflows by selected authority](#optional-workflows-by-selected-authority).

### Choose the FinOps tool and authority

| Choice | What it offers | Who signs in | Additional Azure resources and cost |
|---|---|---|---|
| **AUM Direct** | Terminal/commands, gateway budgets and modes, observed-people search, hourly token facts, daily statistical cost findings, reports; no FinOps server | Azure administrators with gateway permissions and workspace query access | No additional server infrastructure. Existing API Management, logging and applicable workspace-query charges continue |
| **AUM + AUM service** | Independent scoped authority, current gateway budgets, audited conditional changes, native requests/approvals, expiring boosts and warning facts | Its own `AUM.Admin`, `AUM.Viewer`, `AUM.Manager` roles; manager groups resolved by the service | Functions and Storage, plus chosen monitoring/network features. Region, execution/storage volume, always-ready instances, private endpoints and DNS determine cost |
| **Turnstile** | Web FinOps console, charts, assistant and optional model-gateway pages | Its own Turnstile roles and server-resolved manager scope | App Service, PostgreSQL and background-job resources. Its standard deployer may create another gateway with separate cost and configuration |
| **Turnstile + AUM client** | The same Turnstile authority with a terminal/automation face | Existing Turnstile role through the Azure CLI token | The CLI adds no server infrastructure; Turnstile costs remain. No AUM service is required |

These are deployment choices, not permission upgrades performed by AUM.
A gateway has one write authority. Direct and the AUM service respect an
existing Turnstile ownership setting rather than silently bypassing it.

> [!IMPORTANT]
> Direct is an **administrative Azure RBAC connection, not a unit-scoped boundary**.
> Azure roles do not restrict a caller to some business units inside one gateway.
> Scoped managers and viewers require the AUM service or Turnstile.
> Settings states this explicitly. An AUM service user with an app role does not
> need the service managed identity's Azure permissions.

### Create owned groups and register governed scopes from AUM

This flow uses the signed-in administrator's existing delegated Graph access.
AUM does not grant consent, assign directory roles or create an application
credential. New groups are ordinary, non-mail-enabled security groups. Their
verified owner is the signed-in person; group ownership does not itself grant a
Turnstile/AUM service app role.

1. **Governance > : > Add unit or team** opens the group picker.
2. The picker searches Graph server-side by Entra group-name prefix;
   **Next page** follows its bounded continuation. An existing assigned
   security group or **Create new** supplies the group.
3. A new group needs a name and description. Its preview names the signed-in
   owner and membership-refresh implications; **Apply** requires the full name.
   A subsequent search returns the newly created group.
4. The scope form records **Unit** or **Team**, a stable scope id and display
   label, and the parent unit for a team. Preview precedes Apply.
5. Unit/team monthly token budgets and enforcement modes are separate settings.
   Direct verifies named values immediately; Turnstile follows the apply job;
   the AUM service requires a reason and current revision.
6. Group membership is not effective at the gateway merely because Graph saved
   it. **Refresh selected group membership** in Direct, or the selected
   server authority's publication path, publishes it. Reassignment has a preview.

Equivalent AUM commands:

```powershell
aum group find aum-e2e- --limit 50 --backend direct
aum group create aum-e2e-unit-example --description "Temporary acceptance group" --what-if
aum group create aum-e2e-unit-example --description "Temporary acceptance group" `
  --apply --confirm aum-e2e-unit-example
aum group member <owned-group-object-id> --apply
aum catalog set unit <unit-id> --name "Example test unit" --group <selected-group-object-id> --apply
aum catalog set team <team-id> --name "Example test team" --group <selected-group-object-id> --parent <unit-id> --apply
aum budget set unit <unit-id> 100k --apply
aum budget set team <team-id> 1k --apply
aum mode set team <team-id> strict --apply
aum mode set team <team-id> allowance --allowance 10 --apply
aum mode set team <team-id> notify --apply
aum governance refresh-membership --scope <unit-id> --scope <team-id> --what-if
aum governance refresh-membership --scope <unit-id> --scope <team-id> --apply --allow-reassignment
```

`group member` defaults to the signed-in person when `--member-id` is omitted.
It modifies only a group that person owns, verifies the result and never changes
unrelated memberships. `--remove` removes the member reference, not the directory
user. The example amounts are not deployment defaults.

Selected-scope refresh reuses the repository's delegated Graph group reader,
depth ordering and `bu-members` serializer. Teams win over their parent units.
Unrelated mappings and tier entitlement remain intact. Existing assignments that
move require explicit `--allow-reassignment`. A lookup error is not treated as an
empty group. Projection-backed gateways must use their projection pipeline.

### Add and remove developers

Developer entitlement is ordinary Entra group membership followed by gateway
publication. AUM uses the signed-in administrator's delegated Microsoft Graph
token from Azure CLI. It does not request tenant consent, add an app permission
or grant a directory role.

```powershell
aum developer find amara --limit 50
aum developer add amara@contoso.com --tier standard --unit sales-emea --what-if
aum developer add amara@contoso.com --tier premium --unit sales-emea --apply
aum developer remove amara@contoso.com --what-if
aum developer remove amara@contoso.com --apply --confirm amara@contoso.com
```

`developer find` searches the whole Entra directory by display name, mail and
UPN, including guest accounts by their invited address (`mail`/`otherMails`) and
their `#EXT#` UPN stem. Results are bounded and paged. Microsoft Graph directory
search uses the documented advanced-query shape: `ConsistencyLevel: eventual`
with `$count=true` for advanced filters, and `$search` support varies by entity
([Graph search](https://learn.microsoft.com/graph/search-query-parameter),
[advanced queries](https://learn.microsoft.com/graph/aad-advanced-queries),
retrieved 2026-09-26). The terminal People action **Add person to team** uses the
same bounded search and refreshes as the operator types; redacted capture mode
hides the action.

Add and remove resolve exactly one account before any write. Resolution tries
object id, `mail`, `userPrincipalName`, `otherMails`, then the guest `#EXT#`
UPN stem. Ambiguous matches stop and require an object id. Preview lists the
exact group changes: add the selected discovered tier group, remove the other
tier group, and optionally add a catalog unit/team group. Remove lists direct
removal from both tier groups and every catalog unit/team group, then requires
typing the resolved UPN.

Apply writes Microsoft Graph `$ref` membership once per group, verifies each
change with bounded propagation reads, and then publishes to the gateway. Direct
runs the existing membership refresh and tier allow-list sync. Turnstile-backed
gateways use the existing delegated **publish as signed-in admin** path; the
Turnstile web app still does not own Entra membership. Projection-backed
gateways must use the projection publication pipeline after the group write.

Permissions are the administrator's existing rights. Microsoft Graph documents
group owners, Directory Writers, Groups Administrator, Identity Governance
Administrator and User Administrator as supported delegated roles for ordinary
group member updates; role-assignable groups require Privileged Role
Administrator
([Graph add members](https://learn.microsoft.com/graph/api/group-post-members),
retrieved 2026-09-26). AUM lets Graph decide and reports HTTP 403 with these
requirements.

Already-issued Entra access tokens remain valid until they expire; Microsoft
documents access-token lifetime as time-limited rather than live membership
state ([access tokens](https://learn.microsoft.com/entra/identity-platform/access-tokens),
retrieved 2026-09-26). Gateway publication refreshes the allow lists used for
new requests.

Manual Azure portal path:

1. **Microsoft Entra ID > Groups > All groups** lists the directory groups.
2. The recorded tier, unit or team group contains its member list.
3. **Members > Add members** and the selected member's **Remove** action change membership.
4. `Sync-ClaudeAccess.ps1` or the selected authority's publication path publishes
   the change. A real gateway response is the enforcement evidence.

CLI equivalent:

```powershell
$user = az ad user show --id amara@contoso.com --query id -o tsv
$standard = az ad group show --group <standard-tier-group> --query id -o tsv
az ad group member add --group $standard --member-id $user
.\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>
```
Direct refresh refuses when Turnstile owns publication.

#### Manual Azure portal and Azure CLI path

1. **Microsoft Entra ID > Groups > All groups** supports the same prefix search
   and exposes **Group type**, **Membership type** and **Owners**.
2. **New group** accepts **Group type: Security**, **Group name**, **Group
   description**, **Assigned** membership and the signed-in person under
   **Owners**. **Create** submits those values.
3. The reopened group's **Owners** list verifies ownership. **Members >
   Add members** adds the intended test account.
4. Registration belongs to the selected governance authority, as described
   in the manual governance reference; it does not override another authority.
5. Cleanup removes the temporary member and test scopes, then **Delete** removes
   each test group. An absence check verifies deletion.

Native Azure CLI equivalents:

```powershell
$prefix = Read-Host 'Test-only group prefix'
az ad group list --filter "startswith(displayName, '$prefix')" `
  --query '[].{id:id,name:displayName}' -o table
$owner = az ad signed-in-user show --query id -o tsv
$name = Read-Host 'Unique test-only security group name'
$newGroup = az ad group create --display-name $name --mail-nickname $name `
  --description 'Temporary AUM acceptance group' -o json | ConvertFrom-Json
az ad group owner list --group $newGroup.id --query '[].id' -o json
# If the signed-in account was not automatically made owner, add it with existing rights:
az ad group owner add --group $newGroup.id --owner-object-id $owner
az ad group member add --group $newGroup.id --member-id $owner
az ad group member check --group $newGroup.id --member-id $owner -o json
# Cleanup only the group created in this run:
az ad group member remove --group $newGroup.id --member-id $owner
az ad group delete --group $newGroup.id
```

The Graph service may automatically own a delegated non-admin creation; an
administrator's security-group creation can require explicitly adding its owner.
AUM verifies this rather than assuming the directory behavior. If ownership
verification fails, it attempts to remove only the newly created group and reports
any incomplete cleanup. A transport failure is never automatically retried.

### Verify budget enforcement with a tiny real request

`aum requests probe --what-if` explains the operation without obtaining a token
or sending a request. `--apply` sends one real request through the discovered
gateway, with a Cognitive Services token, `anthropic-version: 2023-06-01` and
`max_tokens: 1`. It reports status, quota/notice headers, usage and elapsed time.
This costs model tokens and creates ledger records; it is not a connectivity-only ping.

```powershell
aum requests probe --what-if
aum requests probe --apply --json
```

In the terminal, **: > Probe gateway budget enforcement** has Preview and Apply.
The gateway's **APIs > Claude API > Test** pane is a manual equivalent only when
it supports the required bearer request without revealing a credential.
The direct HTTPS example below uses an authenticated shell; the portal itself
is not evidence of the data-plane response or its headers.

```powershell
$gatewayUrl = az apim show --subscription $sub -g $rg -n $apim --query gatewayUrl -o tsv
$access = az account get-access-token --resource https://cognitiveservices.azure.com `
  --subscription $sub --query accessToken -o tsv
try {
  $body = @{ model='claude-sonnet-5'; max_tokens=1; messages=@(@{role='user';content='Reply OK.'}) } |
    ConvertTo-Json -Depth 5
  $response = Invoke-WebRequest -Method Post -Uri "$gatewayUrl/claude/v1/messages" `
    -Headers @{Authorization="Bearer $access";'anthropic-version'='2023-06-01'} `
    -ContentType application/json -Body $body -SkipHttpErrorCheck
  $response.StatusCode
  $response.Headers['x-bu-quota-remaining']
  $response.Headers['x-claude-budget-notice']
} finally { $access=$null }
```

The bearer token stays in memory and is not printed. Strict should refuse an exhausted test scope,
allowance may report `estimated-over-budget`, and notify reports `usage-reported`
without a scope limiter. These are delayed token counters, not precise spend
guarantees. A mode save is not proof of effect until the actual gateway response
confirms it. Membership/policy propagation and ledger ingestion have separate
delays; the measured intervals are in [Timings and what they prove](#timings-and-what-they-prove).

The reference gateway reports an exhausted strict unit as **HTTP 403** with
`error.type=rate_limit_error`, `error.budget=business unit`, and the specific
unit/team in its message. That data-plane quota response differs from
an AUM/Turnstile API 403 scope denial. An acceptance probe verifies the body
and target scope, not assume every limiter uses HTTP 429.

#### If the Turnstile apply identity cannot read a new group

The background job may complete while deliberately leaving a group it cannot
verify unapplied. The actual registry and subsequent gateway response, rather
than execution completion alone, establish publication. With existing Azure-administrator and delegated
Graph rights, AUM offers an explicit alternative:

```powershell
aum governance publish-as-admin --backend turnstile --what-if
aum governance publish-as-admin --backend turnstile --apply
aum governance refresh-membership --backend turnstile --scope <unit-id> `
  --scope <team-id> --apply --allow-reassignment
```

The terminal command is **Publish Turnstile as signed-in admin**. This runs the
repository's mode-aware `Sync-ClaudeTurnstileGovernance.ps1` as the signed-in
administrator. It is **not** the background job's identity and is labelled that
way in receipts. It does not grant Graph permissions to the workload identity.
Subsequent background budget/mode changes can use already-verified group references.

The manual CLI equivalent is:

```powershell
.\scripts\Sync-ClaudeTurnstileGovernance.ps1 -Direction FromTurnstile -Apply `
  -ResourceGroup $rg -ApimName $apim
```

The portal evidence is in **Container Apps Jobs > the discovered apply job >
Execution history**, its logs, and **API Management > Named values**.
The portal has no button that lends a signed-in person's delegated Graph token
to a managed-identity job. The explicit administrator path above uses existing
rights; it neither grants new consent nor treats an unverified group as valid.

#### Refresh a bounded usage window without waiting for the hourly schedule

1. **: > Refresh recent Turnstile usage** accepts an explicit UTC start/end
   window of no more than two hours and produces a preview.
2. The preview identifies the discovered exporter job and its **usage-only**
   operation. Apply starts one execution using its already-authorized managed identity.
3. The execution result and request ids in AUM provide the result evidence. The job definition,
   cron schedule and governance are not changed.

```powershell
aum usage refresh <UTC-start> <UTC-end> --backend turnstile --what-if
aum usage refresh <UTC-start> <UTC-end> --backend turnstile --apply --json
```

Manual portal path: **Container Apps Jobs > discovered exporter > Execution
history** verifies the run and result. **Run now** runs the normal configured
window. The Azure portal does not support a one-execution configuration override;
the equivalent CLI is `az containerapp job start --yaml <reviewed-template>`.
A reviewed execution-only template retains the existing image, identity,
resources and bootstrap, and invokes only `Export-ClaudeTurnstileUsage.ps1`
with `-From`, `-To` and `-NoCacheEvents`, never the governance scheduler.
[Azure's execution override documentation](https://learn.microsoft.com/azure/container-apps/jobs#start-a-job-execution-on-demand)
describes this operation.

Job secrets and grants remain unchanged. An uncertain start result requires
an execution-history check before another start; a retry can create another execution.

```text
 _____ _____ _____
|  _  |  |  |     |
|     |  |  | | | |
|__|__|_____|_|_|_|
```

Terminal `aum --version` prints the ASCII banner on a TTY. In the full-screen
terminal, the four-line ASCII banner appears on every tab at
80x24 or larger, with the product name and signed-in identity folded into the
header. Smaller terminals use the compact **AUM · Azure Usage Management**
heading (an ASCII hyphen when `--ascii` is selected).
Piped output, `--json`, `--plain` and `--screen-reader` never print the banner
or launch a full-screen application.

> [!IMPORTANT]
> Budgets remain delayed brakes, not exact spend guarantees. Estimated cost is
> not an Azure invoice. A successful save is not proof that every gateway control
> is in effect; AUM reports the apply job's actual status.

### Prerequisites

- Python 3.12 or later and an 80x24 or larger terminal.
- Azure CLI signed in as a person in the relevant Microsoft Entra tenant.
- For Turnstile, its HTTPS origin, API scope and an assigned Turnstile role.
- For the AUM service, its HTTPS origin, `api://<app-id>/AUM.Access` scope and an
  already-assigned AUM app role. A supplied HTTP profile needs no client-side
  workspace or gateway management permissions.
- For Direct, PowerShell 7, this repository, gateway read access and Log Analytics
  access. Writes require effective named-value write permission.

No new tenant consent or permission is needed for an existing Turnstile Owner
and gateway subscription Owner to use the live read views or capture redacted
screenshots.

For an app-role user with no Azure subscriptions, the sign-in equivalent is
`az login --tenant <your-tenant-id> --allow-no-subscriptions`. HTTP profiles can
specify `tenant_id`; token acquisition then selects that tenant rather than
requiring access to the administrator's subscription.

### Install and sign in

The installer, its options and the equivalent manual commands are in
[Install](#install).

`claude-finops` remains an alias for one release and emits a deprecation notice
on stderr. The package distribution is `azure-usage-management`; the internal
`cli/finops`, `claude_finops` and `.venv-finops` names are intentionally retained
to avoid disrupting imports, existing configurations and the repository test runner.

### Configure a backend

Discovery lists real deployment names. Separate `--config` paths keep separate
backend profiles:

```powershell
aum configure
aum configure --backend direct --save
aum configure --backend aum-service --save
aum configure --backend turnstile --save
aum configure --subscription <selected-id> --resource-group <selected-name> `
  --apim-name <selected-name> --backend direct --no-prompt --save
```

The wizard shows numbered real subscriptions, resource groups containing
gateways, API Management instances and workspaces. It prefers the current
subscription, the deployment recorded by `Get-ClaudeGatewayTarget.ps1`, and the
workspace referenced by the gateway's actual diagnostic/logger. Parameters
make the same choices reproducible. It never changes the global Azure CLI
account. `--what-if` never writes even a local profile. An attended replacement
asks for confirmation and keeps a timestamped backup; unattended replacement
requires `--force`.

For `aum-service`, it discovers Function apps tagged `component=aum-service`.
It reads only four nonsecret address/identity settings, then follows that
service's **actual gateway**, which need not be the old Turnstile target.
`--service-app <listed-name>` selects among several apps non-interactively.
Explicitly mismatched gateway parameters are refused, not silently ignored.

![Live Azure discovery with names and ids redacted.](images/aum/direct-configure-110x60-after.svg)

The wizard writes `%USERPROFILE%\.aum\config.json` (`~/.aum/config.json` on Linux).
The JSON fields below illustrate the format; deployment-specific names and ids
come from discovery rather than these Contoso placeholders:

```json
{
  "backend": "direct",
  "resource_group": "rg-contoso",
  "apim_name": "apim-contoso",
  "workspace": "00000000-0000-0000-0000-000000000000",
  "theme": "gateway",
  "ascii": false
}
```

`--config .\contoso-aum.json` or `AUM_CONFIG` selects another profile.
`CLAUDE_FINOPS_CONFIG` and `~/.claude-finops/config.json` remain fallbacks.
Command-line options take precedence. Config stores addresses, never tokens.

```powershell
aum whoami --backend turnstile --url https://api-turnstile.contoso.com `
  --scope api://00000000-0000-0000-0000-000000000000/Turnstile.Manage
```

With `resource_group` and `apim_name`, an administrator can
discover URL and scope from the gateway's `turnstile-integration` named value.

AUM obtains a bearer token in memory with Azure CLI. Authentication for reads can
refresh once; a write is never automatically repeated. Settings offers an explicit
sign-out preview; `az logout` is the equivalent outside AUM. Both affect the shared
Azure CLI session, not only AUM.

#### Read latency and progress

Direct reuses resource tokens for a verified principal and Azure CLI session
until two minutes before known expiry. Opaque tokens have a five-minute reuse
limit. Each read cycle verifies the current account once; concurrent queries
share that result and token acquisition without waiting for the RBAC permission
label. Different resources, principals and sessions do not share credentials.
An unverified caller obtains a fresh token rather than borrowing the cache.
Tokens stay in memory; principal changes and explicit sign-out invalidate them.
Obsolete in-flight results are not returned after a verified identity change.
HTTP identity reads obtain current CLI credentials before identifying the caller.

Each Direct refresh shares one gateway snapshot, obtained through one PowerShell
bridge process and one named-value listing. Catalog, tiers, token limits and the
existing USD converters read that snapshot. Independent Log Analytics queries
overlap and reuse their HTTP client. A new refresh or any write invalidates the
snapshot; write preflight, read-back and compensation still use current values.
The cycle pins an immutable credential generation. A verified principal change
invalidates every cycle holding the old generation; a cached account cannot
rebind it. Catalog, tier and USD snapshots, pending budgets, and multi-source
chargeback, lookup, trend and person-detail results are checked again before
return. An obsolete aggregate is discarded with the existing sign-in-changed
exit 3, and a new cycle verifies the current principal.
HTTP cycles retain their generation through complete aggregates too. Publication
checks occur before each progressive or final cache/render operation, not only
at cycle exit. Capability/backend caches, deferred dialogs and selectors,
assistant results, JSON and CSV exports use the same guard; a delayed response
from a previous principal is not briefly displayed and then cleared.
Cached details retain the original row's guard through deferred dialog
composition. A new cycle that read no data does not supply a replacement.
Dashboard dialogs, prefilled edit/request forms, chart pins and cached request
copy/ledger actions follow the same rule; closing their source connection
invalidates the retained guard. A stale dialog explains the sign-in change
without displaying the previous principal's row or defaults.

All backend-derived presentation and assistant-context reuse pass through
`guarded_publish` with their originating guard. A verified principal change
clears tables, selections, picker options, open forms/dialogs, cached
capabilities/preferences and assistant conversation/history before another
input is dispatched. Highlighted status, clipboard/ledger actions and assistant
requests do not reuse the previous principal's data. Publication rejection
clears the current view and explains the sign-in change.

The offline structural test scans the presentation/output modules for direct
widget/property/status/clipboard/export/assistant writes outside this boundary.
Its exact, documented static-write allowlist covers local shell labels, resets
and fixed controls, not whole handlers. JSON/linear/table formatters require an
active guarded publication, and an async wait cannot be inside that write scope.

Overview displays each source as it arrives. Pending panels name their source,
and the progress line shows an estimate and elapsed time. Estimates are not
network deadlines or ingestion guarantees. A delayed trend query no longer
holds back current usage or budget rows; its failure remains visible alongside
the other results. Pending catalog modes read as pending, not as an assumed
strict mode. Settings remains readable while sign-in is pending.

Direct's Azure-authorized facts can arrive before its identity label; edits
remain disabled during identity verification. Scoped HTTP data still follows the
current identity/scope check. A 401 or 403 clears partial protected data rather
than preserving a previously wider view. Superseded refreshes cannot repaint the
new view.
Fatal data failures are observed while identity or capabilities are still
pending; the denial is displayed immediately rather than waiting for metadata.

The P71 live measurements and their method are in
[STATUS](STATUS.md#p71-aum-answers-fast-and-says-why-it-cannot-2026-09-28).
These captures use live read-only sources with display redaction, not examples:
[provenance and hashes](guide/aum-p71-captures.json).
Direct captures 61/62 were refreshed after the council's principal-binding fix.
The stopped/running Turnstile captures 60/63 retain their original dated
provenance; the correction round changed no database state.

![Live Direct first data while the remaining sources are still pending.](guide/aum-61-direct-progressive.png)

![Live Direct Overview after the current read completes.](guide/aum-62-direct-ready.png)

#### Turnstile database stopped

Turnstile's `/health` is a liveness check and can return 200 while its database is
stopped. AUM bounds the authenticated identity request instead. On a timeout or
5xx, an Azure-selected profile can read PostgreSQL state through ARM using its
existing Azure rights. No App Service secret or connection string is read.

Discovery stores the integration's `resourceGroup` as
`turnstile_resource_group` in the address-only profile. Older gateway-backed
profiles resolve that group from the matching `turnstile-integration` named
value. Exactly one validated server in that group, reported `Stopped` by Azure,
produces exit **9** with its name and this manual command:

```powershell
az postgres flexible-server start -g <turnstile-resource-group> -n <server-name> --subscription <subscription-id>
```

The command resumes paid compute; AUM never runs it automatically. No backend
fallback changes the selected authority. A profile with no Azure subscription,
denied metadata reads, an ambiguous inventory or another server state retains
exit 7 with the diagnostic limit stated. Authentication and scope denials retain
their own codes. The single-server association is the explicit assumption
recorded as **U37** in [UNKNOWNS](UNKNOWNS.md), not a connection-string match.

![Live stopped-database failure with the manual start command visible at 80 columns.](guide/aum-60-turnstile-stopped.png)

![Live Turnstile Overview after the separately authorized database start.](guide/aum-63-turnstile-ready.png)

The reference database was started under the owner's separate P71 authorization,
not by the client. That start does not change the external automation in **U32**.
[Troubleshooting](TROUBLESHOOTING.md#turnstile-database-stopped) distinguishes this
condition from the browser's tenant-consent failure.

#### Direct gateway access

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
The repository's `ClaudeCost` function, published by
`scripts/Publish-ClaudeQueries.ps1`, contains the generated price book
and membership map. Request detail reuses `analytics/chargeback-ledger.kql`.

The existing `scripts/Invoke-ClaudeFinOps.ps1` bridge keeps its filename for
compatibility. It uses the shared registry serializers and `Set-ClaudeTier.ps1`,
not a second registry format. Direct writes are refused if Turnstile owns
governance.

Direct mode differs from Turnstile:

- Limits are current, not historical budget versions. Only the current month
  can be edited.
- People are observed ledger identities, searched/grouped/paged in KQL. AUM does
  not enumerate Entra or load a 500,000-person directory into the client.
- Person limits are **daily gateway overrides**, with the tier limit as the
  default. The UI labels daily used/limit separately from monthly unit/team
  allocation. `Set-ClaudeBudget.ps1` owns the shared override serialization.
- Hourly request/token trends come from the request ledger. Hourly cache/cost
  remain unknown; AUM never distributes daily cost into invented hourly values.
- Statistical anomaly candidates come from daily cost KQL, not a Turnstile rule
  engine. There is no independent acknowledge/false-positive state store.
- Multi-value writes check observed state, use the existing writers, read back
  every target and restore previous values when a later write fails. This is
  **compensation, not an atomic transaction**. Unexpected concurrent values are
  not overwritten; a failed restore reports manual recovery explicitly.
- Warning thresholds and scoped manager groups need a server authority. Those
  unsupported Direct form controls are hidden rather than accepted and ignored.
- New scopes have no monthly budget until one is assigned. Names come from
  their Entra groups; direct mode is not a delegated-manager security boundary.

#### Standalone daily person budgets and modes

```powershell
aum people find dev --team <observed-team-id> --backend direct --limit 50
aum people show <observed-person-object-id> --team <observed-team-id> --backend direct
aum budget set person <observed-person-object-id> 200k --team <observed-team-id> --backend direct --what-if
aum budget remove person <observed-person-object-id> --team <observed-team-id> `
  --backend direct --apply --confirm <observed-person-object-id>
aum mode set team <team-id> allowance --allowance 10 --backend direct --what-if
```

A daily limit is not multiplied into a fictitious monthly allocation. Monthly
unit/team ceilings still apply independently. Only identities with an observed
Entra object id are writable; an unresolved actor label is not a directory grant.
The gateway's `quota-overrides` named value has a 4,096-character capacity:
scalable people **search** does not imply 500,000 individual override records fit.

Direct governance verifies control-plane state. Gateway propagation can lag,
so read-back is not claimed as a measured runtime counter result. No separate
Turnstile apply job is required.

**: > Usage: request-time attribution** and
`aum usage show --basis ledger --dimension department` provide request-time
acceptance evidence. This
reads the team stamped on each request rather than substituting a possibly older
published cost-function membership map. Cost/cache remain unknown on this basis.
**Usage: current priced membership** returns to the existing priced workspace
view; the two bases answer different questions and are labelled separately.

#### Dollar budgets in AUM

Dollar budgets are separate from token budgets. They use the gateway's P59 USD
definition and reconciled-state named values, price every observed category with
the pinned tariff, and enforce through the gateway after reconciliation. AUM does
not convert a token budget to dollars and does not use the token-budget commands
as a fallback.

```powershell
aum usd list --backend direct --json
aum usd set unit <unit-id> 0.02 --period month --backend direct --what-if
aum usd set team <team-id> 0 --period month --backend direct --apply
aum usd set person <entra-object-id> 1.250000001 --period day --backend direct --apply
aum usd clear team <team-id> --backend direct --apply --confirm <team-id>
aum usd status --backend direct --json
aum usd reconcile --backend direct --what-if
aum usd reconcile --backend direct --apply
aum usd price-book show --backend direct --json
aum usd price-book set .\approved-price-book.json --backend direct --apply
```

Amounts are decimal strings: nonnegative, below one trillion, with at most nine
fractional digits. `0` is a real zero-dollar stop. Unit and team budgets are
monthly. Person budgets may be daily or monthly when the connected service
supports the selected period. A successful write says **Saved; awaiting
reconciliation**. It is not reported as enforced until `aum usd reconcile
--apply`, or the AUM service timer, writes a fresh state.

`aum usd status` reports the reconciled UTC window, nominal and effective budget,
observed spend, enforcement mode, `allow`/`notice`/`stop`/`unpriced` status,
cache completeness, exactness and unpriced model names. Null spend is unpriced
or unknown, never zero. The Budgets tab shows these dollar columns next to token
budget, usage and mode. The dollar edit form is preview-first; clearing a dollar
budget requires typing the exact scope id.

Live P62 dollar-budget evidence from the isolated, deleted proof estate:
[80x24](images/aum/direct-usd-budgets-80x24-after.svg) ·
[160x48](images/aum/direct-usd-budgets-160x48-after.svg). The general Direct
Budgets captures later in this guide stay on the reference gateway and show the
merged banner/header baseline.

Direct mode reuses the gateway's existing USD implementation:

- `scripts\ClaudeUsdBudgets.ps1` for validation, encoding, named-value capacity
  checks and the shared `UsdBudgets` authority guard.
- `scripts\Sync-ClaudeUsdBudgets.ps1` for on-demand reconciliation. It calls the
  same Python engine used by the optional AUM service timer.
- `scripts\Invoke-ClaudeFinOps.ps1` only bridges AUM requests into those shared
  scripts; it does not implement a second price book or serializer.

The AUM service backend uses the service contract in
[AUM client contract: USD budgets](aum-usd-budgets-client-contract.md). It
requires advertised capability flags, sends `If-Match` for writes, and keeps
manager scope on the server. A manager never sees reconcile or price-book actions
unless the service advertises them. A 409 conflict requires a fresh read and a
new preview.

The Turnstile backend currently has no real USD budget source. AUM hides or
refuses dollar writes and reconciliation through Turnstile with an authority
message. It does not write token budgets as a substitute for dollars.

Manual Azure equivalents:

```powershell
# Inspect the stored definitions and state.
az apim nv show -g $rg --service-name $apim --named-value-id usd-budgets `
  --query value -o tsv
az apim nv show -g $rg --service-name $apim --named-value-id usd-budget-state `
  --query value -o tsv

# Set or clear a USD budget through the shared writer.
.\scripts\ClaudeUsdBudgets.ps1
.\scripts\Set-ClaudeBusinessUnit.ps1 -Id <unit-id> -MonthlyBudgetUsd 0.02 `
  -ResourceGroup $rg -ApimName $apim

# Reconcile observed spend into gateway stops.
.\scripts\Sync-ClaudeUsdBudgets.ps1 -ResourceGroup $rg -ApimName $apim `
  -WorkspaceId <workspace-customer-id>
```

The named values are base64-encoded ASCII JSON so policy literals remain safe.
The shared script or AUM performs encoding and validation. If Turnstile owns budgets or governance,
the shared authority guard refuses Direct dollar writes and reconciliation.

#### Direct anomaly method and accounting scope

`aum anomalies list --backend direct` runs
[`series_decompose_anomalies()`](https://learn.microsoft.com/kusto/query/series-decompose-anomalies-function)
over daily estimated cost by unit and team:

1. The source is the selected period from published `ClaudeCost`.
2. The unfinished UTC day and series with unpriced facts are excluded.
3. At least 14 active priced days are required; bins cover one day.
4. The residual threshold is **3**, with weekly seasonality **7** and a linear trend.
5. Bounded positive/negative candidates contain the observed cost, baseline,
   score and date; absolute score 6 or greater is labelled critical.

These are statistical candidates, not confirmed incidents. Missing days are
treated as no *observed* cost, so ingestion gaps can produce findings. Sparse or
unpriced series are excluded; no returned findings is **not** an all-clear.

Request-level Direct facts are constrained to the discovered gateway's resource
id. Priced daily facts come from the **published workspace function** and its
current membership/price book. Its source determines whether a shared workspace
figure represents one gateway. The dashboard labels
**Workspace usage | selected gateway budgets** to keep those bases separate.
Unpriced aggregate cost and per-request cache remain unknown.

#### Optional independent AUM service

An administrator can discover the existing service:

```powershell
aum configure --backend aum-service --config .\aum-service.json --save
aum whoami --config .\aum-service.json --json
aum status --config .\aum-service.json --json
```

An app-role user can use an address-only profile supplied by that administrator:

```json
{
  "backend": "aum-service",
  "url": "https://aum.contoso.com",
  "scope": "api://00000000-0000-0000-0000-000000000000/AUM.Access",
  "tenant_id": "00000000-0000-0000-0000-000000000000"
}
```

The backend uses `/api/v1/me` and `/api/v1/capabilities`, not Turnstile routes.
`manager_scope: null` means unrestricted; a scope object with empty lists stays
scoped. Native boolean flags normalize to the same client action-capability model.
Every native budget/configuration change needs an explicit audit reason and a
current quoted `If-Match` revision. A conflict is never automatically retried.

```powershell
aum mode set team <team-id> notify --config .\aum-service.json `
  --reason "Approved notification-only policy" --what-if
aum budget set person <object-id> 200k --team <team-id> --config .\aum-service.json `
  --reason "Approved daily capacity" --what-if
aum request list --view waiting --config .\aum-service.json
aum notifications list --config .\aum-service.json
```

The current published service contract (1.0.3) provides daily trends, native
requests/decisions/escalation, daily person boosts with expiry within 31 days,
and immutable warning facts. It does not yet provide usage distribution,
anomaly findings, assistant/model-gateway pages, notification mark-read, boost
revocation or an indexed arbitrary-request detail route. Unsupported views/actions
are hidden. Selected request detail rechecks the server; an id outside the current
bounded page is not treated as a failed search of all history. No missing feature
silently falls back to Direct or Turnstile.

Native People and Requests use server cursors. For unit managers, complete-scope
CSV export consolidates actually managed units (including direct members) plus
separately managed teams, never a context-only parent or overlapping subtotal.

With the AUM service, **All authorized observed people** searches its ledger even
when the gateway catalog is empty. Unparented observations are readable, not
automatically writable. The service applies scope on every request and page.

#### Live independent-backend evidence

All images below are historical **live**, display-redacted captures recorded in the same
[provenance manifest](images/aum/manifest.json). Empty results are not seeded
with examples. The service target differs from the reference Direct gateway;
their totals are not presented as interchangeable.

| Tab | AUM Direct live | AUM service live |
|---|---|---|
| Overview | [80x24](images/aum/direct-overview-80x24-after.svg) · [160x48](images/aum/direct-overview-160x48-after.svg) | [80x24](images/aum/aum-service-overview-80x24-after.svg) · [160x48](images/aum/aum-service-overview-160x48-after.svg) |
| Budgets | [80x24](images/aum/direct-budgets-80x24-after.svg) · [160x48](images/aum/direct-budgets-160x48-after.svg) | [80x24](images/aum/aum-service-budgets-80x24-after.svg) · [160x48](images/aum/aum-service-budgets-160x48-after.svg) |
| People | [80x24](images/aum/direct-people-80x24-after.svg) · [160x48](images/aum/direct-people-160x48-after.svg) | [80x24](images/aum/aum-service-people-80x24-after.svg) · [160x48](images/aum/aum-service-people-160x48-after.svg) |
| Governance | [80x24](images/aum/direct-governance-80x24-after.svg) · [160x48](images/aum/direct-governance-160x48-after.svg) | [80x24](images/aum/aum-service-governance-80x24-after.svg) · [160x48](images/aum/aum-service-governance-160x48-after.svg) |
| Usage | [80x24](images/aum/direct-usage-80x24-after.svg) · [160x48](images/aum/direct-usage-160x48-after.svg) | No distribution endpoint in contract 1.0.3; hidden |
| Trends | [80x24](images/aum/direct-trends-80x24-after.svg) · [160x48](images/aum/direct-trends-160x48-after.svg) | [80x24](images/aum/aum-service-trends-80x24-after.svg) · [160x48](images/aum/aum-service-trends-160x48-after.svg) |
| Requests | [80x24](images/aum/direct-requests-80x24-after.svg) · [160x48](images/aum/direct-requests-160x48-after.svg) | [80x24](images/aum/aum-service-requests-80x24-after.svg) · [160x48](images/aum/aum-service-requests-160x48-after.svg) |
| Anomalies | [80x24](images/aum/direct-anomalies-80x24-after.svg) · [160x48](images/aum/direct-anomalies-160x48-after.svg) | No finding endpoint in contract 1.0.3; hidden |
| Approvals | Requires a server authority | [80x24](images/aum/aum-service-approvals-80x24-after.svg) · [160x48](images/aum/aum-service-approvals-160x48-after.svg) |
| Settings | [80x24](images/aum/direct-settings-80x24-after.svg) · [160x48](images/aum/direct-settings-160x48-after.svg) | [80x24](images/aum/aum-service-settings-80x24-after.svg) · [160x48](images/aum/aum-service-settings-160x48-after.svg) |

The hourly Direct query has separate live evidence:
[80x24](images/aum/direct-trends-hour-80x24-after.svg) ·
[160x48](images/aum/direct-trends-hour-160x48-after.svg). Its cost column is
unknown because the source is the request ledger, not daily prices divided into hours.

On 2026-09-25, the independent live journeys ran **14 Direct commands** and
**15 AUM service commands**, then visited the matching terminal views. Identity,
catalog, tiers, budget limits, request ids and overview totals agreed within
each backend. Direct returned 51 hourly buckets and one observed person;
the native service returned one observed person despite an empty catalog.
No remote writes were performed. Direct anomaly output contained no candidates;
pricing/coverage exclusions mean this is not a health or security verdict.

### Tour the live terminal

The images below are historical captures from **live backends with display redaction on**.
Their [manifest](images/aum/manifest.json) records backend, UTC capture time,
source commit, dimensions and redaction state. They preserve the measured
layouts rather than claiming to show the P80 controls. Current Example renders
are linked in [First run and screen tour](#first-run-and-screen-tour) and are
not live evidence. The recaptured Direct
Overview and Budgets images show the compact ASCII-art header at 80x24 and 160x48.

#### Overview

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

#### Budgets

The unit/team hierarchy shows used tokens, budget, remaining usage and
unallocated parent headroom. These are different quantities. The mode badge
shows `STRICT`, `ALLOW +N%` or `NOTIFY` from the catalog's `enforcement` and
`allowance_percent` attributes; absent enforcement means strict.

![Live redacted budget hierarchy.](images/aum/turnstile-budgets-80x24-after.svg)

#### People

People searches the selected team on the server, 50 rows at a time. Parent headroom uses
the complete server allocation total, never just the visible page.

![Live redacted People view.](images/aum/turnstile-people-80x24-after.svg)

#### Governance

Governance shows units, teams, member and manager groups, enforcement badges,
tiers and apply status. Owners can edit with `e` or choose add/remove/apply in `:` command mode.
Owners choose **Set budget enforcement mode** in `:` to preview strict, allowance
(1–100 percent) or notify. Direct uses the repository's `Set-ClaudeBusinessUnit.ps1`
with `-Mode` and `-AllowancePercent`; it never duplicates the registry serializer.

![Live redacted Governance view.](images/aum/turnstile-governance-80x24-after.svg)

#### Usage

Usage pivots between units, teams, people, models, surfaces and tiers. Rankings are explicitly
top 100. Chargeback export instead enumerates every authorized catalog scope.

![Live redacted Usage view.](images/aum/turnstile-usage-80x24-after.svg)

#### Trends

Trends offers daily, hourly or weekly buckets. Bars compare volume inside the selected
month; Enter retains full precision. **Compare trend periods** in `:` compares
returned month buckets, without filling missing values with invented zeroes.
`f` chooses an explicit time range. Dates display local time and UTC offset;
month accounting remains UTC.

![Live redacted Trends view.](images/aum/turnstile-trends-80x24-after.svg)

#### Requests

Requests has model and ISO Before-timestamp filters. A server window holds at most 200
requests; AUM pages it in groups of 50. When the server advertises the cursor
contract, AUM instead follows its snapshot-bound pages, including tied timestamps.
Until then this is not an exhaustive history export. Overlapping timestamps
preserve boundary rows when inspecting older windows. `c` copies the real id and `o` opens its discovered
Log Analytics workspace. Both are hidden during redacted capture.

![Live redacted Requests view.](images/aum/turnstile-requests-80x24-after.svg)

#### Anomalies

Severity, scope, time and details come from the read-only usage-anomalies API.
Acknowledgment and false-positive disposition appear in `:` only when the server
advertises the corresponding scoped API.

![Live redacted Anomalies view.](images/aum/turnstile-anomalies-80x24-after.svg)

#### Settings

Settings shows identity, role, managed scope, connection and configuration.
The connection kind and address appear in a wrapping guarded label separate
from the table, including at 80x24; cached table widths do not determine their visibility.
It offers a session theme, **Change connection** and a **Sign out** preview.
The connection form's local backup and rollback are described in
[Connect](#connect). A replacement identity is verified before the working
connection is closed. **Tour** repeats the
first-run keyboard introduction.

![Live redacted Settings view.](images/aum/turnstile-settings-80x24-after.svg)

#### Ask, Approvals and Advanced

**Ask** (`a`) appears when the permitted assistant API exists. Its question field
and **Ask** button send the request. Requests can incur model cost and create conversation history.
The answer and chart rows are the server's response, not client-generated facts.
**Pin** previews a chart pin; `:` also opens history, pinned reports and
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

The recorded live **Turnstile** connection did not advertise Approvals or expose
a configured Advanced registry. Their Turnstile contract screenshots are test
baselines, not mislabelled live documentation. The independent AUM service does
offer native Approvals; its actual live queue appears in the table above.

#### Direct Overview

This capture comes from the gateway's own ledger and published cost function.
Its accounting basis can differ from Turnstile's ingestion. Unknown prices are
not replaced by guessed costs.

![Live Direct Overview with redaction.](images/aum/direct-overview-80x24-after.svg)

### Keyboard, accessibility and safe edits

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
| `g` | Add person to team, for owners; People preserves the searched email and selected team |
| `u` | Set USD budget on a selected writable row when the capability is available |
| `x` | Chargeback report: save the complete month CSV to a non-overwriting local path |
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
Without that contract, concurrent collection edits do not have an ETag conflict guard.

Person monthly budgets are **saved in Turnstile**, not claimed as gateway
per-person quota enforcement.

#### Scoped managers

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

### Publish safe live screenshots

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
write targets. Authorized edits require a non-redacted session.

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

### Command reference

`--json`, `--plain`, `--what-if`, `--redact`, `--month`, `--backend`, `--config`,
`--url`, `--scope`, `--resource-group`, `--apim-name`, `--theme`, `--no-color`
and `--ascii` work before or after the noun/verb. `--reason` supplies native
AUM-service audit text for budget/configuration changes. `--what-if` wins over `--apply`.
Token-budget amounts accept suffixes `k`, `M`, `B` and reject USD strings.
The separate `aum usd` commands accept decimal USD amounts.

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
| Directory developer search | `aum developer find amara --limit 50` |
| Add developer | `aum developer add amara@contoso.com --tier standard --unit sales-emea --apply` |
| Remove developer | `aum developer remove amara@contoso.com --apply --confirm amara@contoso.com` |
| Governance | `aum governance show --json` |
| Native service audit | `aum governance audit --backend aum-service --limit 50` |
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
| Non-overwriting saved CSV | `aum report chargeback --month 2026-09 --output finops-reports --json` |
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

The recorded live report on **2026-09-25** completed in **80.289 seconds**:
884 ledger requests, six people, matched source reconciliation and nine unpriced
rows. CSV and HTML were written locally; no delivery was requested. These are
dated capture facts, not an estimate of your workload or a claim that Turnstile
ingestion and the gateway ledger use identical accounting bases.

Bulk CSV uses a header `team,person,tokens` and optional `warning` percentage.
It accepts at most 500 rows/2 MB, rejects duplicates, validates total allocation
across the complete plan, and shows every normalized change before Apply.

```csv
team,person,tokens,warning
sales-emea,dev@contoso.com,200000,80
```

#### Optional workflows by selected authority

These clients are implemented and tested. Turnstile needs the advertised
contracts; the AUM service already supplies its native request/approval/boost
and warning-read contracts. Unavailable actions return an actionable error
rather than calling an unadvertised mutation route.

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

The far-future sample is syntax only for the proposed Turnstile contract;
an actual expiry is an approved date. AUM service requires `--window daily`
and an expiry within 31 days. The server
must reserve headroom and restore the baseline at expiry/revocation. The client
refuses self-approval and tracks a returned gateway apply anchor, but does not
pretend to enforce a server-side quota itself.

Interactive **Chargeback report** writes to the platform's default report
folder and never overwrites an existing file. The command palette's explicit
CSV export also accepts a custom filename
([report behavior](#create-a-chargeback-report)).

### Do the same Azure steps by hand

These paths use the resources you discover, not the redacted names in the
screenshots. AUM does not create VNets, subnets, DNS zones, Key Vaults or gateways;
there is no hidden infrastructure deployment to reproduce.

#### 1. Choose the subscription, resource group and gateway

1. The portal's **Subscriptions** list identifies an already-managed
   subscription. The top-right menu shows the signed-in account and directory.
2. **Resource groups > the gateway's group > API Management service** locates
   the existing gateway.
3. **Overview** displays **Status**, **Resource group**, **Location**,
   **Subscription**, **Subscription ID**, **Gateway URL** and **Tier**.
4. Deployment values belong to that selected resource. The screenshot replaces
   names, hostnames and ids with Contoso placeholders, not configuration values.

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

#### 2. Read the Turnstile connection and governance authority

1. The gateway's **APIs > Named values** page lists its configuration.
2. **Search to filter items by display name and name** locates `turnstile-integration`.
3. Its **Value** contains the profile's `url` and `scope`, plus
   `governanceAuthority` and `budgetAuthority`, which determine where changes belong.
4. This connection is address metadata, not a bearer token. Unrelated secret
   named values are not part of the procedure.

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

#### 3. Find the actual telemetry workspace

1. **API Management > APIs > APIs > Claude API > Settings** exposes the
   Application Insights diagnostic.
2. That diagnostic references the **Application Insights** resource; a similar
   name is not evidence of the relationship.
3. Its **Overview > Logs workspace** link identifies the workspace.
4. The workspace's **Overview** shows **Workspace name**, **Workspace ID**,
   **Subscription**, **Location** and **Access control mode**.
5. **Workspace ID** is AUM's `workspace` field, not its ARM resource id.

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

If the API has no diagnostic, the service-level
`$apimId/diagnostics/applicationinsights` is the fallback. The wizard performs that
fallback and offers accessible workspaces when no logger reference can be read.

#### 4. Query usage and export a report

1. The selected workspace's **Logs** page contains the editor.
2. The recorded portal preview shows the editor after **Welcome to Log Analytics**
   is closed, **Agent** is off and **Use Query** is selected.
3. **Simple mode > KQL mode** switches the query toolbar.
4. **Run** (or **Shift+Enter**) executes the query below.
5. Returned scope, token, cache and cost columns are the result evidence.
   The result export control saves CSV. Unknown prices remain unknown.

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
An earlier copied session expired and capture stopped without attempting sign-in.
For the culminating run, a fresh copy of the owner's supplied profile worked.
The current image includes a verified successful query response and real results;
blank editors, welcome screens and onboarding overlays are rejected.

![Live KQL editor and actual query results, with redacted resource and scope names.](images/aum-portal/workspace-logs.png)

The equivalent Azure CLI request reads KQL from `query.kql` and sends a JSON
body file, so shell pipes do not become Azure CLI arguments:

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

#### 5. Inspect or change governance in the correct control plane

1. The authority from step 2 determines the writer. Direct named-value edits
   would bypass an authoritative Turnstile configuration.
2. The discovered Turnstile **App Service > Overview** shows **Status** and
   **Runtime status**. **View app** (**Browse** in the classic portal) opens it.
3. Turnstile's **Budget Management** owns scope budgets; **Gateway governance**
   owns units, teams, groups and tiers. The preview identifies scope and amount;
   the gateway apply result follows the save.
4. The existing consent-free Azure CLI sign-in path in [Turnstile](TURNSTILE.md)
   remains available when normal web sign-in requires unavailable tenant consent.
   AUM itself uses that already-authorized CLI token, not a new grant.

![Live App Service Overview after its onboarding overlay was closed.](images/aum-portal/turnstile-overview.png)

The Azure portal does not contain native fields for Turnstile's business-unit,
team or person budgets. **View app** opens the actual management GUI; a portal
database edit would bypass its validation and is not an equivalent safe procedure.

For Gateway authority only, **API Management > APIs > Named values** contains:
`tpm-standard` / `tpm-premium` are per-minute tier limits; `quota-standard` /
`quota-premium` are daily limits; `models-*` are model allowlists; `bu-registry`
and `bu-parents` hold the unit/team hierarchy. The item's **Value** editor and
**Save** action change its value. A valid change preserves unrelated entries
and parent allocation; read-back establishes the saved value.

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
Azure CLI. The sequence below reads the original, writes a body file and reads apply status:

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

`9000000` is an illustrative amount, not a deployment default. An approved
value stays within the parent budget; the original is the rollback source.
These operations neither print a bearer token nor require a secret named-value edit.

Installation, terminal themes, local filters, the banner and screenshot
rendering are local software operations; there is no Azure portal equivalent
because they do not change an Azure resource.

#### 6. Change a mode or allocate person budgets

1. **App Service > Overview > View app** opens the authoritative Turnstile
   console. **Gateway governance** contains the existing units and teams.
2. The current enforcement setting supports **strict**, **allowance** or
   **notify**. Allowance requires an integer percentage from 1 through 100.
   Member/manager groups and unrelated scopes remain unchanged.
3. The save is followed by the gateway apply job. Its result and the gateway's
   **Named values > bu-modes > Value** establish publication. Absence of a
   scope in this value means strict; allowance is serialized as
   `scope-id=allowance:10` between sentinel commas.
4. Person allocation is in **Budget Management**, under the selected team's
   person search. The displayed parent allocation must accommodate
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

The original catalog is the rollback source. `10` is an illustrative approved
percentage, not a deployment default. `allowance_percent` is absent for strict
and notify, because it is invalid outside allowance mode. Advertised conditional
writes require the current ETag as `If-Match`; a conflict requires rereading.

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
`GET /api/v1/budgets/users?period=...&department_id=...&query=...` reads the result.
The portal has no native Turnstile bulk-budget blade; a database edit bypasses
the validated endpoint. AUM's CSV client groups only the
prevalidated people/amounts and reports partial failure without retrying a write.

#### 7. Inspect a request or move team membership

1. **Log Analytics workspace > Logs > KQL mode** runs the repository's
   `analytics/chargeback-ledger.kql` query with a selected `request_id` filter.
   Its request id, timestamp and unit/team fields correspond to terminal detail.
2. AUM's `o` action builds this workspace link from the discovered ARM workspace
   id and tenant. `c` copies only the selected id; it does not modify Azure.
3. Membership is in **Microsoft Entra ID > Groups > All groups > the catalog's
   team member group > Members**.
4. Existing group-owner/directory rights permit **Add members** on the target
   group and **Remove** on the former group. Both member lists provide verification.
   Directory propagation and gateway projection refresh are separate from the
   budget apply job. This example authorizes no additional permission grant.

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

The culminating acceptance performed directory writes only on clearly test-only
groups created and owned by the signed-in person, then deleted them. It did not
remove that person from unrelated groups. The final membership set matched the
starting set. Gateway/Turnstile Owner alone does not imply directory rights;
AUM verifies group ownership and never requests broader grants.

#### 8. Ask, pin and inspect optional model-gateway views

1. **App Service > Overview > View app** opens the Turnstile GUI.
   **FinOps Assistant** requires an unrestricted authorized sign-in. Scoped
   manager profiles do not gain access by opening the URL directly.
2. The selected model/cost settings determine the model invocation. A submitted
   question incurs its model cost and persistence. A pin uses an actual returned
   chart, not client-generated rows.
3. A connected Turnstile with its own model gateway exposes model,
   backend-pool, release and subscription views. AUM exposes those same
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
to request broader permissions. An assistant invocation POSTs a JSON body with
`question`, `history`, `conversation_id`, `timezone` and `locale`
to `/api/v1/assistant/ask`. A pin POSTs `title`, `description`,
`original_question` and the exact returned `chart` to
`/api/v1/assistant/pinned-charts`. The matching `aum ask` commands avoid hand-copying
response charts. This packet's live assistant evidence is read/preview evidence;
it is not a claim that a model invocation or pin write was performed.

#### 9. Reports, local preferences and future service workflows

1. **Log Analytics workspace > Logs > Run** and the result export control in
   step 4 produce a manual usage CSV. This raw query export is not a substitute
   for P50's streaming reconciliation, provenance manifest and per-unit files.
2. `aum report generate` runs that existing generator. The report output remains
   local unless explicit `--send` is requested. No Azure portal blade performs
   the whole local reconciliation algorithm; the GUI path inspects its saved
   query functions and exported results instead.
3. Profiles, saved views and tour state are local to AUM. **Settings >
   Change connection**, `v` and `:` expose them. Azure CLI's equivalent sign-in/session reads
   are `az account show` and `az account list`; `az logout` is the explicit shared
   session sign-out, not a preview.
4. Turnstile does not yet advertise the proposed approvals/boosts/notification
   workflows on this connection. The independent AUM service offers native
   workflow endpoints with a different explicit contract. Neither authority
   should be bypassed by manually editing its storage records.

The current portal manifest covers all required gateway, workspace, verified
KQL-result and unobscured App Service pages, plus the created group's Overview,
Owners and Members. It records UTC times, source commits and image hashes.

#### 10. Configure AUM Direct without any Turnstile service

1. **Subscriptions > your subscription > Resource groups > your existing
   API Management service** exposes the **Overview** fields from step 1.
   Its configured **Application Insights** diagnostic identifies the
   **Logs workspace**, as in step 3.
2. **API Management > APIs > Named values** contains `bu-registry`,
   `bu-parents`, `bu-modes`, `quota-overrides`, `quota-*`, `tpm-*` and `models-*`.
   None requires a Turnstile installation. If a `turnstile-integration` value
   exists, its recorded write authority still applies.
3. `aum configure --backend direct --save` generates a profile containing
   your selected subscription, gateway and workspace, never a token.
4. `aum whoami`, `aum status` and `aum people find <query> --team <team-id>` read
   the identity, status and people. Settings identifies Direct/Azure RBAC and
   explains the optional manager authorities.

The equivalent discovery CLI is the `az account list`, `az apim list`,
diagnostic/logger traversal and workspace query sequence in steps 1–4. No
deployment-specific resource name is a script default.

Daily person overrides are in **Named values > quota-overrides > Value**.
The format is a comma-sentinel map of Entra object ids to daily tokens, limited
to 4,096 characters. A valid edit preserves unrelated entries. Removing one entry restores
that person's tier default; it does not change membership or per-minute tier
limits. The CLI equivalent uses the existing validated serializer/writer:

```powershell
aum budget set person <observed-object-id> 200k --team <team-id> --backend direct --what-if
# Only after reviewing the preview:
aum budget set person <observed-object-id> 200k --team <team-id> --backend direct --apply
```

Equivalent native Azure CLI after preparing and validating the complete map:

```powershell
$existing = az apim nv show --subscription $sub -g $rg --service-name $apim `
  --named-value-id quota-overrides --query value -o tsv
# Retain $existing for rollback. $updated must preserve every unrelated object id.
$updated = Read-Host 'Reviewed complete override sentinel map'
az apim nv update --subscription $sub -g $rg --service-name $apim `
  --named-value-id quota-overrides --value $updated -o none
$actual = az apim nv show --subscription $sub -g $rg --service-name $apim `
  --named-value-id quota-overrides --query value -o tsv
if ($actual -cne $updated) { throw 'Read-back mismatch: inspect and restore the retained original.' }
```

Multi-value rollback uses exact old values in reverse order after a failed save.
A changed value from another operator requires manual reconciliation rather
than an overwrite.
The AUM writer automates these checks and reports an incomplete restore as an error.

#### 11. Query hourly facts or statistical candidates manually

1. The editor is **Log Analytics workspace > Logs > KQL mode**.
2. `analytics/chargeback-ledger.kql` supplies the base query, with the selected
   time bounds and discovered API Management resource-id filter before projection.
3. The following suffix aggregates hourly results:

```kusto
| summarize total_tokens=sum(total_tokens), total_requests=count()
    by bucket_start=bin(timestamp, 1h)
| order by bucket_start asc
```

The Azure CLI equivalent uses a `query.kql` file and `az rest --body
'@query-body.json'` as in step 4. The hourly token/request buckets do not
establish hourly cost or cache, which the request ledger does not contain.

For statistical findings, the exact server query is composed in
[`direct_analytics.py::anomalies`](../cli/finops/src/claude_finops/direct_analytics.py).
That KQL runs in the same **Logs** editor with selected dates and preserved
pricing-exclusion/14-day guards. Its method and limits are described above.
The live query-result screenshot above is separate from the terminal/KQL API
proof; neither is substituted for the other.

#### 12. Inspect the independent AUM service and call its native API

1. **Azure portal > Function App** lists the deployed app with
   `component=aum-service` in **Tags**. Its **Overview** displays the default
   domain and running state.
2. **Settings > Environment variables > App settings** contains
   `AUM_CLIENT_ID`, `AUM_TENANT_ID`, `AUM_APIM_RESOURCE_ID` and `AUM_WORKSPACE_ID`.
   These are address/identity metadata. Unrelated connection strings or
   credentials are not part of discovery.
3. `AUM_APIM_RESOURCE_ID` identifies the governed gateway. An older recorded gateway default is not proof
   that the service governs that gateway.
4. **Microsoft Entra ID > Enterprise applications > the existing AUM app >
   Users and groups** displays the already-assigned role. Admin, Viewer and
   Manager precedence is enforced by the service; this guide does not authorize
   assigning new roles or granting consent.
5. `aum configure --backend aum-service --save` records the discovered profile;
   `aum session show --json` displays it. A supplied profile also works for app-role users without Azure
   resource-management rights.

Native Azure CLI reads:

```powershell
az functionapp list --subscription $sub --query "[?tags.component=='aum-service'].{name:name,group:resourceGroup,host:defaultHostName}" -o table
$functionGroup = Read-Host 'Selected Function App resource group'
$functionName = Read-Host 'Selected Function App name'
az functionapp config appsettings list --subscription $sub -g $functionGroup -n $functionName `
  --query "[?contains(['AUM_CLIENT_ID','AUM_TENANT_ID','AUM_APIM_RESOURCE_ID','AUM_WORKSPACE_ID'], name)].{name:name, value:value}" -o json
```

The following calls use the discovered endpoint and audience, not a function key:

```powershell
$aumApi = Read-Host 'Discovered AUM HTTPS origin'
$aumAudience = Read-Host 'api:// followed by the discovered AUM_CLIENT_ID'
az rest --method get --url "$aumApi/api/v1/me" --resource $aumAudience -o json
az rest --method get --url "$aumApi/api/v1/capabilities" --resource $aumAudience -o json
$budgets = az rest --method get --url "$aumApi/api/v1/budgets" --resource $aumAudience -o json | ConvertFrom-Json
$etag = '"' + $budgets.revision + '"'
@{ token_limit=200000; reason='Approved daily capacity' } | ConvertTo-Json |
  Set-Content -Encoding utf8 .\aum-budget-body.json
# Example mutation; choose an existing authorized object and review before running:
az rest --method put --url "$aumApi/api/v1/budgets/user/<object-id>" --resource $aumAudience `
  --headers "If-Match=$etag" --body '@aum-budget-body.json' -o json
```

`/api/v1/budgets` and its new revision provide native mutation read-back;
an Admin may inspect `/api/v1/audit`. No Turnstile apply endpoint is involved.
A request uses POST `/api/v1/budget-requests` with scope, absolute `token_limit`
and reason; decisions POST `/api/v1/budget-requests/{id}/approve|reject|escalate`
with reason and the current integer `version`. A boost POSTs `/api/v1/boosts`
with the current `If-Match`, absolute raised limit and an expiry within 31 days.
The service's timer owns expiry restoration.

There is no native Azure portal form for these application workflows. The AUM
terminal is their GUI; Azure CLI REST is the manual API path. The Function App
portal verifies deployment and identity metadata, not application authorization
by editing its storage. At the culminating run the earlier native-service
deployment had been removed (`ResourceGroupNotFound`); no service deployment
or live mutation evidence is fabricated from the earlier read-only screenshots.

### Measured end-to-end acceptance: create, enforce, restore

On **2026-09-25**, AUM completed the owner-approved journey through Direct and
Turnstile. Each used uniquely named `aum-e2e-*` security groups, verified the
signed-in owner, temporarily added only that person, registered a unit and team,
set monthly budgets, refreshed membership and sent tiny real Claude requests.
No new permission or consent was granted. Standard TPM was not changed.

| Step | Direct live evidence | Turnstile live evidence | Manual verification |
|---|---|---|---|
| Find/create group | [Group picker](images/aum/direct-group-form-lookup-110x36.svg), [owner preview](images/aum/direct-group-form-create-preview-110x36.svg), [created unit group](images/aum/direct-e2e-group-created-unit-ba354220.svg), [created team group](images/aum/direct-e2e-group-created-team-ba354220.svg) | [Unit group](images/aum/turnstile-e2e-group-created-unit-1f706bd1.svg), [team group](images/aum/turnstile-e2e-group-created-team-1f706bd1.svg) | Entra **Groups > Overview**, **Owners**, **Members** |
| Register hierarchy | [Scope form](images/aum/direct-group-form-scope-registration-110x36.svg), [unit](images/aum/direct-e2e-registered-unit-ba354220.svg), [team](images/aum/direct-e2e-registered-team-ba354220.svg) | [Unit](images/aum/turnstile-e2e-registered-unit-1f706bd1.svg), [team](images/aum/turnstile-e2e-registered-team-1f706bd1.svg), [explicit delegated bootstrap](images/aum/turnstile-e2e-delegated-bootstrap-team-1f706bd1.svg) | APIM **Named values > bu-registry / bu-parents**; server catalog and apply receipt |
| Set budgets | [Unit](images/aum/direct-e2e-budget-unit-ba354220.svg), [team](images/aum/direct-e2e-budget-team-ba354220.svg) | [Unit](images/aum/turnstile-e2e-budget-unit-1f706bd1.svg), [team](images/aum/turnstile-e2e-budget-team-1f706bd1.svg) | Reread original scope and current limit; distinguish parent allocation from usage |
| Refresh membership | [Delegated refresh](images/aum/direct-e2e-membership-refreshed-ba354220.svg) | [Authority-matched delegated refresh](images/aum/turnstile-e2e-membership-refreshed-1f706bd1.svg) | Entra member exists; APIM **bu-members** maps the object id to the test team |
| Strict refusal | [Actual HTTP 403](images/aum/direct-e2e-enforcement-strict-ba354220.svg) | [Actual HTTP 403](images/aum/turnstile-e2e-enforcement-strict-1f706bd1.svg) | `rate_limit_error`, business-unit budget and exact target scope; not generic access denial |
| Allowance 10% | [HTTP 200 + notice](images/aum/direct-e2e-enforcement-allowance-ba354220.svg) | [HTTP 200 + notice](images/aum/turnstile-e2e-enforcement-allowance-1f706bd1.svg) | `x-claude-budget-notice` contains `mode=allowance:10;status=estimated-over-budget` |
| Notify | [HTTP 200 + notice](images/aum/direct-e2e-enforcement-notify-ba354220.svg) | [HTTP 200 + notice](images/aum/turnstile-e2e-enforcement-notify-1f706bd1.svg) | Notice contains `mode=notify;status=usage-reported`; no team remaining-counter header is invented |
| Usage/request attribution | [Usage](images/aum/direct-e2e-post-cleanup-usage-ba354220.svg), [Requests](images/aum/direct-e2e-post-cleanup-requests-ba354220.svg) | [Usage](images/aum/turnstile-e2e-post-cleanup-usage-1f706bd1.svg), [Requests](images/aum/turnstile-e2e-post-cleanup-requests-1f706bd1.svg), [usage refresh](images/aum/turnstile-e2e-usage-refreshed-1f706bd1.svg) | Three accepted requests / 96 prompt+completion tokens remain attributed after cleanup |
| Cleanup | [Exact original values](images/aum/direct-e2e-cleanup-ba354220.svg) | [Exact values + original memberships](images/aum/turnstile-e2e-cleanup-1f706bd1.svg) | Test groups absent; original catalog, direct membership set and named-value bytes restored |

The live portal ownership/membership proof contains only the verified test identity:

![Live test security group Overview.](images/aum-portal/group-overview.png)

![Live signed-in owner of the AUM-created test group.](images/aum-portal/group-owners.png)

![Live temporary test membership, removed during cleanup.](images/aum-portal/group-members.png)

#### Timings and what they prove

| Backend | Strict mode save → confirmed refusal | Allowance save → confirmed notice | Notify save → confirmed notice |
|---|---:|---:|---:|
| Direct | 26.498 s | 9.401 s | 7.994 s |
| Turnstile | 130.632 s | 156.900 s | 157.099 s |

These are measured upper bounds from save completion to the confirming response,
including the probe itself; they are not exact internal propagation latencies.
The strict test first admitted a 32-token request, then refused the next one at
the tiny limit. This confirms the documented delayed-counter behavior, not a
zero-overshoot hard ceiling.

Direct first observed two accepted rows 321.264 seconds after the first accepted
request; a later post-cleanup read confirmed all three / 96 tokens. Turnstile
waited for all accepted requests in the gateway ledger, then ran a **usage-only**
existing exporter execution for the bounded window. That execution took
160.156 seconds and left its job definition unchanged. All three ingested rows
were then visible; the first-observation upper bound was 794.006 seconds.

The background Turnstile job initially could not verify the new groups. AUM
measured that the execution completed but the registry lacked the test unit,
then explicitly used the signed-in-administrator publication path. Subsequent
budget/mode changes traversed **catalog/budget save → background apply job →
gateway**. The bootstrap is not mislabelled as success by the managed identity.

The AUM service's earlier read-only deployment was no longer deployed at the
culminating window: its endpoint was unreachable and its resource group returned
`ResourceGroupNotFound`. Its current contract/client tests remain, but no native
service group/budget mutation journey is claimed without an active target.

#### Cleanup and operational pitfalls

The runner restores in `finally` even when a step fails. It preserves exact
`bu-registry`, `bu-members`, `bu-modes`, `bu-parents`, integration authority,
allowlists, TPM/daily-tier limits and model allowlists. The final Turnstile run
also compared the complete original direct-membership set: **14 memberships**,
unchanged after deleting both test groups.

An independent final read at **2026-09-25T09:45:44Z** verified all 13 named-value
strings, the original catalog (equivalent absent/default-strict representation),
the original membership set, zero remaining `aum-e2e-*` groups/catalog entries,
and zero active apply jobs:
[final restored live state](images/aum/turnstile-e2e-final-state-equal-restored.svg).

Earlier failed attempts exposed real issues, fixed and regression-tested:

- Graph create returned an id before `/owners` replicated it; deletion could
  remain readable briefly. Only verification reads are retried, not mutations.
- `az ad` rejects `--subscription`; ARM calls keep it, directory calls do not.
- A cached Direct capability still reflected the old authority after the explicit
  temporary switch. Native mode edits now refresh capability/authority state.
- The gateway's quota refusal is 403, not an assumed 429.
- A scheduled synchronization overlapped an early Direct attempt and copied test
  entities to Turnstile. They were removed and the original catalog verified.
  The runner now snapshots linked authority state and refuses a Direct window
  that can overlap the next scheduled governance pass.
- Cleanup removes child budgets before parents and follows the server's
  coalesced apply timestamp, then drains jobs before restoring exact gateway bytes.
- An immediate exporter override initially included unsupported template fields.
  The corrected execution-only payload was verified live; it changes no schedule,
  job definition, grants or governance.

Historical usage and audit facts from real test requests are retained, not deleted
to make the test disappear. Operational configuration, memberships and groups
are what the cleanup restores.


## Troubleshooting

[Troubleshoot and validate](#troubleshoot-and-validate) lists exit codes.
[Read latency and progress](#read-latency-and-progress) and
[Turnstile database stopped](#turnstile-database-stopped) describe startup
failures. [Do the same Azure steps by hand](#do-the-same-azure-steps-by-hand)
contains the independent verification paths.

### Troubleshoot and validate

| Exit / symptom | Meaning and recovery |
|---|---|
| 2, invalid input | Month, stable id, amount or parent headroom failed validation |
| 3, 401 | `az login` supplies a new session in the selected tenant |
| 4, AADSTS50105 | The selected application's existing role assignment is missing or incorrect |
| 4, 403 | The requested scope is not permitted; Settings shows the current assignment |
| 5, missing scope/route | Month/id or advertised API version does not supply the requested object; another authority is not a permission bypass |
| 6, conflict | Current state differs from the preview; a fresh read and preview are required |
| 7, service/job failure | Network, Azure access or job failure; existing job history determines whether a write already ran |
| 8, apply still pending | `aum governance show` reports progress; the save may already have succeeded |
| 9, verified stopped Turnstile database | Azure reports the named PostgreSQL server as `Stopped`; the message contains its explicit paid start command. AUM starts nothing automatically |
| Unknown Direct cost | Unpriced facts or the published `ClaudeCost` price book leave the amount unknown |
| Failed connection verification | The prior local profile and live connection remain active; a restore error names the backup for manual recovery |

```powershell
.\.venv-finops\Scripts\python.exe -m pytest cli\finops\tests -q
node .ironclad\gate.mjs --stage packet --verbose
```

Test-All uses the worktree `.venv-finops` or reports an explicit skip. Fake SVGs
and exact screen grids live under `cli/finops/tests/snapshots`;
`cli/finops/tools/capture.py` regenerates them and their source/output manifest.
Live evidence is separate and retains its original timestamps.

The [revision-4 parity manifest](../cli/finops/src/claude_finops/parity.json)
distinguishes implemented current APIs from named server dependencies. Exact
future request/response contracts ship in
[`contracts.json`](../cli/finops/src/claude_finops/contracts.json).
