# Close a month of Claude chargeback

For FinOps owners and budget holders. The output is an **internal usage tariff**,
not a reconciled Azure invoice. Read [Architecture](ARCHITECTURE.md) for the data
flow and [Business units](BUSINESS-UNITS.md) for who owns each allocation.

## Prerequisites

| Need | Who supplies it |
|---|---|
| Gateway, subscription, Application Insights and ledger workspace | Platform owner; [target discovery](OPERATIONS.md#1-select-the-gateway-and-workspace) |
| Log Analytics Reader and workbook read access | Azure resource owner; write roles only for publishing |
| Cost Management Reader / relevant billing-scope access for invoice comparison | Billing owner; not an inference entitlement |
| Approved rates and allocation policy | Finance; `config/price-book.json` is local/private, not committed |
| Period, currency and timezone | Finance; the examples use a closed UTC calendar month and USD |

No Foundry data-plane role is needed for reporting. Turnstile readers/managers
use their assigned app roles, not Azure subscription access.

### Resolve the values before reporting

Use [Monitoring's diagnostic-to-workspace discovery](MONITORING.md#find-the-gateway-logger-and-workspace-values)
for `<apim-name>`, `<ledger-workspace>` and the correct resource group.
**Portal:** select the gateway's actual diagnostic/logger destination and open
that workspace's Properties; **CLI:** `Get-ClaudeTelemetry.ps1`, followed by
the ID-based reads in that procedure. Do not choose a workspace by its similar
name or by list order.

The period is the agreed closed UTC month, not a deployment value.
Rates come from the approved dated price book; recipients and budget ownership
come from the finance/governance owner, not from an inferred email domain.
For a console connection, the owner supplies the actual URL and delegated scope,
or an authorised administrator reads the gateway's `turnstile-integration`
named value. Do not derive a client ID from an account or tenant ID.

## 1. Publish or refresh the reporting definitions

Have a platform owner run these from the repository root, with explicit targets:

```powershell
./scripts/Publish-ClaudeQueries.ps1 -ResourceGroup '<gateway-resource-group>' `
    -ApimName '<apim-name>' -WorkspaceName '<ledger-workspace>'
./scripts/Publish-ClaudeWorkbook.ps1 -ResourceGroup '<gateway-resource-group>' `
    -WorkspaceName '<ledger-workspace>' -WorkbookFile infra/workbook-chargeback.json `
    -Name 'Claude gateway - chargeback'
```

The ledger workspace is the one linked to the gateway's Application Insights:
`./scripts/Get-ClaudeTelemetry.ps1` prints it as `Workspace`. Omit `-WorkspaceName`
and each publisher offers that workspace, even when it is in another resource group,
and asks in a console. A `-WorkspaceName` you pass is looked up in the supplied
resource group; if the workspace is elsewhere, omit it rather than pass a convenient
but wrong name.

**Portal/manual:** Log Analytics workspace > Logs > Functions. Publish
`analytics/chargeback-ledger.kql` as `ClaudeChargeback` with the `p_from` and
`p_to` datetime parameters described in [Monitoring](MONITORING.md#7-dashboard).
`ClaudeCost` also needs the generated price and membership tables: do not paste
the unpopulated placeholders from `chargeback-cost.kql`. Copy the reviewed
published definition from the correct gateway, or populate both marked tables
from the approved price book and current membership, recording their dates.
Azure Monitor > Workbooks > New > Edit > Advanced editor accepts
`infra/workbook-chargeback.json`; bind it to the ledger workspace and save.

**Verify:** run `ClaudeChargeback()` and `ClaudeCost()` in that workspace.
Confirm recent known requests, nonempty `price_book_date`/`membership_date`,
and `priced_ok`. An empty chart is not proof of zero spend.

## 2. Select and export the closed month

In Log Analytics > Logs, run:

```kusto
let from = startofmonth(now(), -1);
let to = endofmonth(now(), -1);
ClaudeCost(from, to)
| summarize estimated_usd = sum(usd), requests = sum(requests),
            unpriced_rows = countif(priced_ok == false)
  by business_unit, business_unit_parent
| order by estimated_usd desc
```

**Portal:** use the chargeback workbook's Time range and Business unit controls,
then inspect **Attribution and pricing gaps** before exporting. In Logs use
Export > CSV; save the detailed `ClaudeCost(from, to)` rows as well as totals.
There is no month-close command that locks the ledger for you.

Record the exact UTC bounds, export time, gateway/workspace, price-book date,
membership date and unresolved gaps with the export. Wait for ingestion to
settle and rerun after late data arrives; do not count the same boundary twice.
Child spend also rolls into its parent, so do not sum a parent and its children
as independent charges.

## 3. Review caveats before approving allocations

| Check | Consequence |
|---|---|
| Core request counts | `ClaudeChargeback` joins `ApiManagementGatewayLlmLog` to identity traces; unlike custom metric dimensions, this request ledger is not capped at 100 users |
| Cache reads | `ClaudeCost` still uses `AppMetrics` for cache reads. Metric cardinality limits still affect this portion at scale; an uncapped request ledger does not make cache attribution complete |
| Cache writes | Not observed by this workbook. `cache_write_known=false` must remain in exports |
| Unpriced models | `priced_ok=false`; totals omit their dollars. Add an approved rate and republish, rather than accepting zero as free usage |
| Membership | The function embeds membership at publication. `business_unit_at_time` keeps the request stamp; `business_unit` prefers the current published map. Transfers can reallocate past usage |
| Rates | Publication embeds the current book, not an automatic historical tariff series. Preserve the month's book and exported rows before later price changes |
| Client surface | Derived from a client-supplied User-Agent, useful for reporting, not a security identity. Cache reads have no client surface |
| Invoice | U2 remains open: no measured reconciliation to the Azure invoice. Discounts, hosting terms, missing categories and gateway infrastructure can change the comparison |

Keep each token category separate when pricing. `Total Tokens` is neither a
dollar amount nor complete billable usage. The measured cache ratios in older
examples describe that sample only, not your organisation.

## 4. Compare to billed cost and set the next budget

**Portal:** Cost Management > Cost analysis > select the same billing scope and
closed month > filter the Foundry resource / Claude meter. Reconcile separately
from APIM, Log Analytics, projection and Turnstile infrastructure. If billing
data is unavailable, record the block rather than marking the allocation
invoice-reconciled ([U2](UNKNOWNS.md)).

Set allocations through [Business units](BUSINESS-UNITS.md), personal/tier
ceilings through [Budgets](BUDGETS.md), or the configured Turnstile authority.
For a dollar budget, state the model and output-share assumptions used to convert
it to tokens. Concurrent requests and cache blindness mean it is not a hard
dollar stop; see [Scale](SCALE.md#the-budget-is-a-delayed-kill-switch-not-a-hard-cap).

## Optional consoles

- **Turnstile:** [setup and operating guide](TURNSTILE.md). Units/teams, usage
  and delegated management are separate from the inference request path.
  [Viewers and managers](TURNSTILE.md#viewers-and-managers) explains roles and
  `scripts/Open-ClaudeTurnstile.ps1` when web consent is unavailable.
- **AUM (Azure Usage Management):** the [terminal FinOps console](CLI-FINOPS.md)
  supplies interactive views and scriptable reports/commands over Turnstile,
  direct gateway access or isolated example data. Managers and viewers remain
  read-only in its first release, even where Turnstile's web console permits
  manager budget edits. Direct mode requires Azure permissions and is not a
  delegated-manager boundary. Preview and apply are separate; follow the job
  result rather than treating a saved budget as enforced.
  The merged first release exposes `claude-finops`; the product rename changes
  the preferred command to `aum`, retaining `claude-finops` as a deprecated alias.
  Use the linked guide for the command available in your checkout. Its
  `CLI-FINOPS.md` address remains the stable entry point during the guide move.
  `scripts/Manage-ClaudeBusinessUnits.ps1` remains the narrower unit-management
  script, not another name for AUM.
- **Grafana:** optional [existing-instance publication](MONITORING.md#if-you-would-rather-use-grafana).

### Sign in as a viewer or business-unit manager

1. Ask the console owner for its URL, tenant ID and API scope, and for an
   assignment to `Turnstile.Viewer` or `Turnstile.Manager`. A manager also needs
   a manager group assigned to the application and recorded on their unit/team.
   These are separate from inference entitlement and Azure RBAC.
2. With Azure CLI and the complete repository scripts available, sign in as
   yourself and pass the supplied values explicitly. This avoids needing
   permission to read the gateway's connection configuration:

   ```powershell
   az login --tenant '<tenant-id>' --allow-no-subscriptions
   ./scripts/Open-ClaudeTurnstile.ps1 -TurnstileUrl 'https://<console-api>.azurewebsites.net' `
       -Scope 'api://<turnstile-application-id>/Turnstile.Manage'
   ```

   **Browser alternative:** use Sign in with Microsoft only after the tenant has
   granted the one-time web consent. There is no Azure portal action that
   bypasses that consent. The CLI route uses its pre-authorised delegated scope,
   not a workload identity or another person's token. Do not forward its
   one-use sign-in link.
3. Verify the displayed role and scope. Viewers can read across the console,
   not just one unit. Managers see their scoped units/teams/people; a unit
   manager can allocate to teams and in-scope people, and a team manager to
   in-scope people. The owner retains unit budgets, catalog, tiers, modes and
   Apply now. Admin or Viewer assignments take precedence over Manager; avoid
   them on an account intended to be scoped.
4. After a permitted budget save, check the last apply result and the gateway's
   effective behavior. A UI save does not prove enforcement yet. Sign out/in
   after role or manager-group changes; current sessions retain token groups.

**Troubleshoot:** `AADSTS50105` means check application assignment, not Foundry
roles. Need admin approval on the browser path means web consent is missing.
An empty manager scope means check the assigned manager group/catalog and a
fresh sign-in. The owner's live manager-only acceptance is still open in
[Status](STATUS.md); do not mistake the recorded test-signed-token browser run
for that separate live acceptance.

## Next steps

- [Monitoring](MONITORING.md) — saved functions, workbooks, alerts and empty data.
- [AUM](CLI-FINOPS.md) — terminal setup, scoped reads and safe command workflows.
- [Turnstile](TURNSTILE.md) — browser-based governance and consent troubleshooting.
- [Scale](SCALE.md) — what the 500,000-record test did and did not measure.
