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

## 1. Publish or refresh the reporting definitions

Have a platform owner run these from the repository root, with explicit targets:

```powershell
./scripts/Publish-ClaudeQueries.ps1 -ResourceGroup '<workspace-resource-group>' `
    -ApimName '<apim-name>' -WorkspaceName '<ledger-workspace>'
./scripts/Publish-ClaudeWorkbook.ps1 -ResourceGroup '<workspace-resource-group>' `
    -WorkspaceName '<ledger-workspace>' -WorkbookFile infra/workbook-chargeback.json `
    -Name 'Claude gateway - chargeback'
```

The publisher expects the gateway and target workspace in the supplied resource
group. If they are in different groups, do not pass a convenient but wrong name:
use the manual path below or have the platform owner arrange publication for
that layout.

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
- **Terminal:** this revision ships `scripts/Manage-ClaudeBusinessUnits.ps1`
  for interactive unit management, plus the read/report commands above.
  The separate terminal FinOps tool is being merged; its guide is not present
  in this revision. Do not assume an unmerged command is installed.
- **Grafana:** optional [existing-instance publication](MONITORING.md#if-you-would-rather-use-grafana).

## Next steps

- [Monitoring](MONITORING.md) — saved functions, workbooks, alerts and empty data.
- [Turnstile](TURNSTILE.md) — browser-based governance and consent troubleshooting.
- [Scale](SCALE.md) — what the 500,000-record test did and did not measure.
