# Server aggregation over the existing saved functions; never download raw requests.
function Get-ClaudeReportQuery {
    param($Window, [ValidateSet('Scopes','People','Dimensions')][string]$Kind, [string]$Unit, [string]$HashPrefix = '')
    $from = [datetime]::Parse($Window.From).ToUniversalTime().ToString('o')
    $to = [datetime]::Parse($Window.QueryTo).ToUniversalTime().ToString('o')
    $base = @"
let d = ClaudeCost(datetime($from), datetime($to))
| extend Unit = tolower(iff(isnotempty(business_unit_parent), business_unit_parent, coalesce(business_unit, "unassigned"))),
         Team = iff(isnotempty(business_unit_parent), business_unit, ""),
         PersonKey = coalesce(user_id, actor, "unattributed");
"@
    $sum = 'Requests=sum(requests), InputTokens=sum(prompt_tokens), OutputTokens=sum(completion_tokens), CacheReadTokens=sum(cache_read_tokens), EstimatedCostUsd=sum(usd), People=count_distinct(PersonKey), UnpricedRows=countif(not(priced_ok))'
    if ($Kind -eq 'Scopes') {
        return $base + @"
union
 (d | summarize $sum | extend Level="Workspace", Unit="", Team=""),
 (d | summarize $sum by Unit | extend Level="Unit", Team=""),
 (d | where isnotempty(Team) | summarize $sum by Unit, Team | extend Level="Team")
"@
    }
    Get-ClaudeReportFileName $Unit | Out-Null
    if ($HashPrefix -notmatch '^[0-9a-f]{0,8}$') { throw 'Invalid person hash prefix.' }
    $base += "`nlet u = d | where Unit == `"$Unit`";`n"
    if ($Kind -eq 'Dimensions') {
        return $base + @'
union
 (u | summarize Requests=sum(requests), EstimatedCostUsd=sum(usd) by Name=model | extend Kind="Model"),
 (u | summarize Requests=sum(requests), EstimatedCostUsd=sum(usd) by Name=client_surface | extend Kind="Client")
'@
    }
    $filter = if ($HashPrefix) { "| where substring(hash_sha256(PersonKey), 0, $($HashPrefix.Length)) == `"$HashPrefix`"" } else { '' }
    return $base + @"
let p = u $filter;
let models = p | summarize Cost=sum(usd) by PersonKey, model
| summarize arg_max(Cost, model) by PersonKey | project PersonKey, TopModel=model;
p
| summarize Requests=sum(requests), InputTokens=sum(prompt_tokens), OutputTokens=sum(completion_tokens),
    CacheReadTokens=sum(cache_read_tokens), EstimatedCostUsd=sum(usd), UnpricedRows=countif(not(priced_ok)),
    Person=take_anyif(actor, isnotempty(actor) and actor != "unattributed"),
    Team=make_set(Team, 1000), Tier=make_set(tier, 100), Clients=make_set(client_surface, 100)
    by Unit, PersonKey
| join kind=leftouter models on PersonKey
| extend Person=coalesce(Person, PersonKey), Team=strcat_array(array_sort_asc(Team), "; "),
    Tier=strcat_array(array_sort_asc(Tier), "; "), Clients=strcat_array(array_sort_asc(Clients), "; ")
| project Unit, PersonKey, Person, Team, Tier, Requests, InputTokens, OutputTokens,
    CacheReadTokens, EstimatedCostUsd, TopModel, Clients, UnpricedRows
| take 20001
"@
}

function Get-ClaudeReportToken {
    param([string]$Resource)
    $token = az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire the required Entra token. Sign in with az login and check resource roles.' }
    return $token.Trim()
}

function Invoke-ClaudeReportQuery {
    param([string]$WorkspaceResourceId, [string]$Kql)
    if ($WorkspaceResourceId -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
        throw 'WorkspaceResourceId must be a Log Analytics workspace ARM resource ID.'
    }
    $uri = "https://api.loganalytics.io/v1$WorkspaceResourceId/query"
    $response = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -TimeoutSec 620 `
                -Headers @{ Authorization='Bearer ' + (Get-ClaudeReportToken 'https://api.loganalytics.io'); Prefer='wait=600' } `
                -Body (@{query=$Kql} | ConvertTo-Json -Compress)
            break
        }
        catch {
            $status = [int]$_.Exception.Response.StatusCode
            if ($status -notin @(429,502,503,504) -or $attempt -eq 4) { throw "Log Analytics query failed (HTTP $status). Check workspace roles, functions and query limits." }
            Start-Sleep -Seconds ([math]::Pow(2,$attempt) * 5)
        }
    }
    if ($response.error) { throw "Log Analytics returned a partial result ($($response.error.code)). No report was published." }
    if (-not $response.tables -or $response.tables.Count -ne 1) { throw 'Log Analytics returned no unambiguous result table.' }
    $table = $response.tables[0]
    if (@($table.rows).Count -ge 500000) { throw 'Log Analytics reached its 500,000-row limit. No report was published.' }
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $table.rows) {
        $record = [ordered]@{}
        for ($i=0; $i -lt $table.columns.Count; $i++) { $record[$table.columns[$i].name]=$row[$i] }
        $out.Add([pscustomobject]$record)
    }
    return ,$out.ToArray()
}

function Get-ClaudeReportSource {
    param([string]$WorkspaceResourceId)
    $headers = @{ Authorization='Bearer ' + (Get-ClaudeReportToken 'https://management.azure.com') }
    $items = New-Object 'System.Collections.Generic.List[object]'
    $pricingDate = ''; $membershipDate = ''
    foreach ($alias in @('ClaudeCost','ClaudeChargeback')) {
        $uri = "https://management.azure.com$WorkspaceResourceId/savedSearches/$($alias.ToLowerInvariant())?api-version=2020-08-01"
        $saved = Invoke-RestMethod -Uri $uri -Headers $headers
        $text = [string]$saved.properties.query
        if (-not $text) { throw "Saved function $alias is missing. Run Publish-ClaudeQueries.ps1 for the discovered workspace." }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        $items.Add([ordered]@{ Alias=$alias; Version=$saved.properties.version; Sha256=$hash })
        if ($alias -eq 'ClaudeCost') {
            if ($text -match 'let price_book_date = "([^"]+)"') { $pricingDate=$Matches[1] }
            if ($text -match 'let membership_date = "([^"]+)"') { $membershipDate=$Matches[1] }
        }
    }
    if ($pricingDate -notmatch '^\d{4}-\d{2}-\d{2}$') { throw 'ClaudeCost has no published price-book date. Republish the saved function.' }
    [ordered]@{ QueryVersion=1; Functions=$items.ToArray(); PricingDate=$pricingDate; MembershipDate=$membershipDate; CostBasis='Existing ClaudeCost list-price showback; not an Azure invoice'; BudgetAsOfUtc=[datetime]::UtcNow.ToString('o') }
}

function Get-ClaudeReportCatalog {
    param([string]$ResourceGroup, [string]$ApimName)
    . (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
    $sub = az account show --query id -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Not signed in. Run az login.' }
    $uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/namedValues?api-version=2024-05-01"
    $map = @{}
    do {
        $r = Invoke-RestMethod -Uri $uri -Headers @{Authorization='Bearer ' + (Get-ClaudeReportToken 'https://management.azure.com')}
        foreach ($nv in $r.value) { if (-not $nv.properties.secret) { $map[$nv.name]=$nv.properties.value } }
        $uri=$r.nextLink
    } while ($uri)
    $registry = @(ConvertFrom-ClaudeBuRegistry $map['bu-registry'])
    $parents = ConvertFrom-ClaudeBuParents $map['bu-parents']
    foreach ($u in $registry) { $u | Add-Member NoteProperty Parent ([string]$parents[$u.Id]); $u }
}
