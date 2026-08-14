# Governance control checks — command reference

Every command below was run against the live gateway. Set these once:

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

```
1. Entitled developer          [PASS] HTTP 200  tier=standard  consumed=20  remaining=19980
2. Tier enforcement            [PASS] HTTP 200  tier=premium   consumed=20  remaining=79980
3. Per-minute token budget     [PASS] HTTP 429  Retry-After: 3s
4. Chargeback attribution      alice@contoso.com 831 · build-agent 728
```

Add `-SkipThrottleTest` to leave the live budget untouched.

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

Live output:

```
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
| **403** (no message) | Daily quota exhausted |
| **429** | Per-minute token budget hit; honour `Retry-After` |

> On Windows PowerShell 5.1 there is no `-SkipHttpErrorCheck`; wrap the call in
> `try/catch` and read `$_.Exception.Response`.

---

## Check 2 — Tier enforcement, using a second identity

Acquire a token as a service principal standing in for another developer:

```powershell
$tok = (Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token" `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        client_id     = '<app-id>'
        client_secret = '<secret>'
        scope         = 'https://cognitiveservices.azure.com/.default'
        grant_type    = 'client_credentials'
    }).access_token
```

Then repeat check 1 with that token. A premium member returns
`x-claude-tier: premium` and a visibly larger `x-ratelimit-remaining-tokens`.

---

## Check 3 — Prove the budget actually throttles

Lower the limit, exhaust it, restore it:

```powershell
$restore = az apim nv show -g $RG --service-name $APIM `
    --named-value-id tpm-standard --query value -o tsv

az apim nv update -g $RG --service-name $APIM --named-value-id tpm-standard --value 100 -o none
Start-Sleep -Seconds 25          # allow the policy to pick up the new value

1..15 | ForEach-Object {
    $r = Invoke-WebRequest -Uri "$GW/v1/messages" -Method Post `
        -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } `
        -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
    "{0}  HTTP {1}  remaining={2}  retry-after={3}" -f $_, $r.StatusCode,
        ($r.Headers['x-ratelimit-remaining-tokens'] -join ''), ($r.Headers['Retry-After'] -join '')
}

az apim nv update -g $RG --service-name $APIM --named-value-id tpm-standard --value $restore -o none
```

Expected tail:

```
11  HTTP 200  remaining=11
12  HTTP 200  remaining=0
13  HTTP 429  remaining=0  retry-after=2
```

**Always restore the named value.** Anything else leaves the team throttled.

---

## Check 4 — Chargeback attribution

Custom metric dimensions are not exposed by `az monitor metrics list`, so query
the REST API:

```powershell
$sub = az account show --query id -o tsv
$ai  = "/subscriptions/$sub/resourceGroups/$RG/providers/Microsoft.Insights/components/appi-claude-gateway"
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

```
alice@contoso.com                              831
build-agent (service principal)                728
```

Swap `metricnames` for `Prompt%20Tokens` or `Completion%20Tokens`, or change the
filter to `Tier eq '*'` or `Model eq '*'` to slice differently.

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
    --query "[?contains(name,'tpm') || contains(name,'quota') || contains(name,'calls')].{setting:name,value:value}" -o table
```

**Nobody bypasses the gateway** — the only principal with data-plane access
should be the gateway's managed identity:

```powershell
$scope = az cognitiveservices account show -n $FOUNDRY -g $FRG --query id -o tsv
az role assignment list --scope $scope --include-inherited `
    --query "[?roleDefinitionName=='Cognitive Services User'].{who:principalName,type:principalType}" -o table
```

Any human in that list can skip every control above.

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
