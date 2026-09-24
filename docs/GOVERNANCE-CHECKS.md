# Governance control checks — command reference

For platform operators verifying a deployment or change. Manual HTTP examples
use **PowerShell 7**; the shipped `Show-Governance.ps1` also supports 5.1.
Use an entitled test user and an approved change window: calls consume model
capacity and the throttle test temporarily changes a live tier limit.

Required roles are in [Setup](SETUP.md#2-permissions-and-roles). Select the
subscription, gateway group, Foundry group and actual telemetry resources with
[Operations](OPERATIONS.md#1-select-the-gateway-and-workspace), then set:

```powershell
$APIM = "<your-apim-name>"          # e.g. apim-claude-gw-xxxxxx
$RG   = "rg-claude-gateway"
$GW   = "https://$APIM.azure-api.net/claude"
$FOUNDRY = "<your-foundry-account>"
$FRG     = "<foundry-resource-group>"
```

---

## The one-shot check

Produces the full four-control report:

```powershell
./scripts/Show-Governance.ps1 -ApimName $APIM -ResourceGroup $RG
```

```text
1. Entitled developer          [PASS] HTTP 200  tier=standard  consumed=20  remaining=19980
2. Tier enforcement            [PASS] HTTP 200  tier=premium   consumed=20  remaining=79980
3. Per-minute token budget     [PASS] HTTP 429  Retry-After: 3s
4. Chargeback attribution      alice@contoso.com 831 · build-agent 728
```

Add `-SkipThrottleTest` to leave the live budget untouched.
That option does not prove throttling. **Portal/manual:** inspect APIM > APIs >
Claude API > Policies and Named values, then perform the request tests below.
There is no single portal button equivalent to this report.

---

## Check 1 — Is the caller entitled, and at which tier?

One call tells you everything: whether they are allowed, their tier, what they spent, and what is left.

```powershell
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv

$body = @{
  model      = 'claude-sonnet-5'
  max_tokens = 24
  messages   = @(@{ role = 'user'; content = 'Reply OK' })
} | ConvertTo-Json -Depth 5

$r = Invoke-WebRequest -Uri "$GW/v1/messages" -Method Post `
    -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } `
    -ContentType 'application/json' -Body $body -SkipHttpErrorCheck

$r.StatusCode
$r.Headers['x-claude-tier']
$r.Headers['x-tokens-consumed']
$r.Headers['x-ratelimit-remaining-tokens']
$r.Headers['x-quota-remaining-today']
```

Illustrative response shape; token counts depend on the request and model:

```text
HTTP 200
x-claude-tier                    standard
x-tokens-consumed                35
x-ratelimit-remaining-tokens     19965
x-quota-remaining-today          499965
x-governed-by                    apim-claude-gateway
```

| Result | Meaning |
|---|---|
| **200** | Entitled; `x-claude-tier` names the tier |
| **401** | No valid Entra token — not signed in, or wrong tenant |
| **403** `permission_error` | Authenticated but in no Claude Code group |
| **403** `rate_limit_error` | Inspect `budget` and the unit name for the exhausted counter |
| **403** `model_not_allowed` / unassigned-unit message | Model or unit policy, not a missing token |
| **429** | Token/request rate, miss admission or Foundry capacity; honour `Retry-After` |
| **503** naming entitlement | Resolver unavailable or expired lease; use [Private projection](SECURE-PROJECTION.md#troubleshooting) |

> On Windows PowerShell 5.1 there is no `-SkipHttpErrorCheck`; wrap the call in
> `try/catch` and read `$_.Exception.Response`.

---

## Check 2 — Tier enforcement, using a second identity

Acquire a token as a service principal standing in for another developer:

Use an isolated, entitled test principal. Supply its short-lived credential from
an approved secret store, not a literal pasted into shell history. A second
human test account is also valid; do not grant a new Foundry bypass role.

```powershell
$tok = (Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token" `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        client_id     = '<app-id>'
        client_secret = $env:CLAUDE_TEST_CLIENT_SECRET
        scope         = 'https://cognitiveservices.azure.com/.default'
        grant_type    = 'client_credentials'
    }).access_token
```

Then repeat check 1 with that token. A premium member returns
`x-claude-tier: premium` and a visibly larger `x-ratelimit-remaining-tokens`.

**Portal:** Entra ID > Groups > premium tier > Members and APIM > Named values
show configuration. A call using that identity proves enforcement; the APIM
portal operator's own sign-in is a different identity.

---

## Check 3 — Prove the budget actually throttles

Lower the limit, exhaust it, restore it:

```powershell
$restore = az apim nv show -g $RG --service-name $APIM `
    --named-value-id tpm-standard --query value -o tsv
if ($LASTEXITCODE -ne 0 -or -not $restore) { throw 'Cannot read the limit to restore; do not change it' }

try {
az apim nv update -g $RG --service-name $APIM --named-value-id tpm-standard --value 100 -o none
if ($LASTEXITCODE -ne 0) { throw 'Limit update failed' }
Start-Sleep -Seconds 25          # check response headers too; propagation can be slower

1..15 | ForEach-Object {
    $r = Invoke-WebRequest -Uri "$GW/v1/messages" -Method Post `
        -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } `
        -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
    "{0}  HTTP {1}  remaining={2}  retry-after={3}" -f $_, $r.StatusCode,
        ($r.Headers['x-ratelimit-remaining-tokens'] -join ''), ($r.Headers['Retry-After'] -join '')
}

}
finally {
    az apim nv update -g $RG --service-name $APIM --named-value-id tpm-standard --value $restore -o none
    az apim nv show -g $RG --service-name $APIM --named-value-id tpm-standard --query value -o tsv
}
```

Expected tail:

```text
11  HTTP 200  remaining=11
12  HTTP 200  remaining=0
13  HTTP 429  remaining=0  retry-after=2
```

**Always restore the named value.** Anything else leaves the team throttled.
If the restore call fails, restore it immediately in **APIM > Named values >
`tpm-standard` > Edit**, then prove a normal request succeeds. The fixed sleep
is not a propagation guarantee; compare response headers before drawing a
conclusion about the new limit.

---

## Check 4 — Chargeback attribution

First verify the request ledger in **Log Analytics > Logs** in the gateway's
workspace, after [publishing its functions](MONITORING.md#7-dashboard):

```kusto
ClaudeChargeback(ago(1h), now())
| project timestamp, actor, user_id, tier, business_unit, model,
          prompt_tokens, completion_tokens, cache_tokens_known
| take 20
```

Confirm the test identity/model and time. Cache categories remain unknown on
request rows. Use [FinOps](FINOPS.md) for priced aggregates and monthly close.

For a **pilot metric diagnostic only**, custom metric dimensions are not
reliably exposed by `az monitor metrics list`, so query the REST API:

```powershell
$sub = az account show --query id -o tsv
$ai  = '<application-insights-resource-id-from-the-gateway-logger>'
$mgmt = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv

$ts = "{0}/{1}" -f (Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'),
                   (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$filter = [uri]::EscapeDataString("User eq '*'")

$uri = "https://management.azure.com$ai/providers/Microsoft.Insights/metrics" +
       "?api-version=2019-07-01&metricnamespace=claudecode&metricnames=Total%20Tokens" +
       "&timespan=$ts&interval=PT1H&aggregation=Total&`$filter=$filter"

$m = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $mgmt" }
foreach ($metric in $m.value) {
    foreach ($s in $metric.timeseries) {
        "{0,-45} {1,8}" -f ($s.metadatavalues.value -join '/'),
                           [int](($s.data | Measure-Object -Property total -Sum).Sum)
    }
}
```

Swap `metricnames` for `Prompt%20Tokens` or `Completion%20Tokens`, or change the
filter to `Tier eq '*'` or `Model eq '*'` to slice differently.
**Portal:** the linked Application Insights > Metrics > `claudecode` > Sum >
Apply splitting. This diagnostic has metric cardinality limits and is not
evidence of complete billing.

> Nothing returned? Allow ~3 minutes after traffic, confirm the APIM diagnostic
> has `metrics: true`, and confirm App Insights has
> `CustomMetricsOptedInType = WithDimensions`.

---

## Configuration audits

**Who is currently entitled, and at which tier**

```powershell
az apim nv show -g $RG --service-name $APIM --named-value-id allow-standard --query value -o tsv
az apim nv show -g $RG --service-name $APIM --named-value-id allow-premium  --query value -o tsv

az ad group member list --group claude-code-standard --query "[].{name:displayName,upn:userPrincipalName}" -o table
```

**Current budget allocations**

```powershell
az apim nv list -g $RG --service-name $APIM `
    -o json | ConvertFrom-Json |
    Where-Object { $_.name -match 'tpm|quota|calls' } |
    Select-Object name, value
```

**Nobody bypasses the gateway** — the only principal with data-plane access
should be the gateway's managed identity:

```powershell
./scripts/Get-ClaudeBypass.ps1 -ResourceGroup $RG -ApimName $APIM
```

It checks data actions and inherited scope, not just one role name. Review each
finding with its owner. **Portal:** Foundry > Access control (IAM) > Role
assignments, including inherited assignments. Also review key access and
networking before claiming there is no bypass.

**Portal equivalents for the other audits:** APIM > Named values; Entra > Groups
> All members for transitive membership; APIM > APIs > Claude API > Policy code
editor for policy. A direct-members list alone is not the effective roster.
For projection entitlement use [the store comparison](SCALE.md#4-run-the-comparison-until-it-reports-nothing),
not stale named-value lists.

**The policy that is actually deployed**

```powershell
$mgmt = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$RG/providers/Microsoft.ApiManagement" +
       "/service/$APIM/apis/claude-foundry/policies/policy?api-version=2024-05-01&format=rawxml"
(Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $mgmt" }).properties.value
```

> `az rest` mis-decodes this response on Windows and reports a failure for a call
> that succeeded. Use `Invoke-RestMethod`.

---

## Traffic and errors at the gateway

```powershell
$wsid = az monitor log-analytics workspace show -g $RG -n <workspace> --query customerId -o tsv

az monitor log-analytics query -w $wsid --analytics-query @'
AppRequests
| where TimeGenerated > ago(1h)
| summarize Requests=count(), Failures=countif(Success==false) by Name
'@ -o table
```

**Portal:** open that workspace > Logs and run the same query. The workspace
ID is its `customerId`, not the Application Insights AppId or ARM resource ID.
Query access is required, not a Foundry inference role.

---

## Client-side verification

Run on the developer's machine, not the gateway:

```powershell
claude auth status     # { "apiProvider": "foundry" }
claude doctor          # confirms Foundry mode, and NOT connected to api.anthropic.com
claude -p "Reply OK" --output-format json   # look for "provider":"foundry"
```

In an interactive session, `/status` reports **API provider: Microsoft Foundry**
plus the resource name. It does not work in the VS Code panel — terminal only.

**Client UI:** verify the gateway connection in Desktop and the configured
provider in VS Code; use [Developer setup](../DEVELOPER.md#using-it).
If a request fails, [Troubleshooting](TROUBLESHOOTING.md) routes by symptom.
