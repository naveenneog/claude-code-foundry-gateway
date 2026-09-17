<#
.SYNOPSIS
    Lists what this accelerator actually deployed, and what it costs to keep.

.DESCRIPTION
    A resource group usually holds more than one thing. On the reference
    deployment it held 68 resources, six of which belong to this gateway - so a
    bill of materials written by hand from the design drifts from what is really
    there, and a screenshot of the resource group answers the wrong question.

    This reads the live deployment and reports only the gateway's own resources,
    separating three things that get conflated:

      created     resources this accelerator deploys and you pay for
      reused      resources it attaches to but did not create - the Foundry
                  account is yours and was there first
      configured  things that are not resources at all: named values, the API
                  policy, saved KQL functions, Entra groups, a role assignment.
                  These carry no bill, which is most of why the footprint is
                  small

.EXAMPLE
    ./scripts/Get-ClaudeBom.ps1
    ./scripts/Get-ClaudeBom.ps1 -AsJson
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

if (-not $ApimName) {
    $found = @((az apim list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
    if ($found.Count -eq 1) { $ApimName = $found[0].Trim() }
    elseif ($found.Count -eq 0) { throw "No API Management instance in '$ResourceGroup'. Pass -ApimName." }
    else { throw ("$($found.Count) instances in '$ResourceGroup': " + ($found -join ', ') + ". Pass -ApimName.") }
}

# The gateway names everything after the APIM instance, which is what makes its
# own resources separable from whatever else shares the group.
$stem = $ApimName -replace '^apim-', ''

$all = az resource list -g $ResourceGroup --query "[].{name:name, type:type, sku:sku.name, id:id}" -o json 2>$null | ConvertFrom-Json
$mine = @($all | Where-Object { $_.name -like "*$stem*" -or $_.name -eq $ApimName })

# The workbook is named by a GUID, so it is found by reading it rather than by
# matching a name.
$sub = az account show --query id -o tsv
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$hdr = @{ Authorization = "Bearer $tok" }
try {
    $wb = Invoke-RestMethod -Headers $hdr `
        -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/workbooks?api-version=2023-06-01&category=workbook"
    foreach ($w in ($wb.value | Where-Object { $_.properties.displayName -like '*Claude*' })) {
        if ($mine.id -notcontains $w.id) {
            $mine += [pscustomobject]@{ name = $w.properties.displayName; type = 'Microsoft.Insights/workbooks'; sku = $null; id = $w.id }
        }
    }
}
catch { }

# What the gateway attaches to but did not create.
$backend = az apim api show -g $ResourceGroup --service-name $ApimName --api-id claude-foundry --query serviceUrl -o tsv 2>$null
$foundry = if ($backend -match 'https://([^.]+)\.') { $Matches[1] } else { $null }

# Configuration, which is where most of this accelerator lives.
$nv = @()
try { $nv = @((az apim nv list -g $ResourceGroup --service-name $ApimName --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ }) } catch { }
$fn = @()
try {
    $ws = @((az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ -like "*$stem*" })
    if ($ws.Count) {
        $s = Invoke-RestMethod -Headers $hdr `
            -Uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$($ws[0].Trim())/savedSearches?api-version=2020-08-01"
        $fn = @($s.value | Where-Object { $_.properties.category -eq 'Claude' } | ForEach-Object { $_.properties.functionAlias })
    }
}
catch { }

# What each thing costs to keep, stated as the shape of the bill rather than a
# number - prices are regional and change, and a hard-coded figure in a script
# is wrong somewhere by the time anyone reads it.
$COST = @{
    'Microsoft.ApiManagement/service'                            = 'per hour, by SKU and units - the whole cost of this accelerator'
    'Microsoft.Insights/components'                              = 'per GB ingested, after 5 GB free each month'
    'Microsoft.OperationalInsights/workspaces'                   = 'per GB ingested and retained; shares the Application Insights allowance'
    'Microsoft.Insights/workbooks'                               = 'nothing - a definition, billed only by the queries it runs'
    'microsoft.alertsmanagement/smartDetectorAlertRules'         = 'nothing - created with Application Insights, free'
    'Microsoft.CognitiveServices/accounts'                       = 'per token, on your existing Foundry agreement'
    # The entitlement projection, ADR-0011. Serverless bills per request unit
    # and per GB with no minimum, so an empty one is free - but a private
    # endpoint, which the governance baseline forces, bills per hour at rest.
    'Microsoft.DocumentDB/databaseAccounts'                      = 'per request unit and GB, no minimum - but its private endpoint bills hourly at rest'
    'Microsoft.Network/privateEndpoints'                         = 'per hour, whether used or not - the only line here that bills at rest'
    'Microsoft.Web/sites'                                        = 'per execution and GB-second, after a monthly free grant'
    'Microsoft.Web/serverfarms'                                  = 'per hour on Flex Consumption only when instances run'
}

$created = @($mine | Where-Object { $_.type -ne 'Microsoft.CognitiveServices/accounts' } | Sort-Object type)

if ($AsJson) {
    [ordered]@{
        resourceGroup = $ResourceGroup
        apim          = $ApimName
        created       = @($created | ForEach-Object { [ordered]@{ type = $_.type; name = $_.name; sku = $_.sku; cost = $COST[$_.type] } })
        reused        = @(if ($foundry) { [ordered]@{ type = 'Microsoft.CognitiveServices/accounts'; name = $foundry; note = 'pre-existing; the gateway calls it and did not create it' } })
        configured    = [ordered]@{ namedValues = $nv.Count; savedFunctions = $fn; apiPolicy = 'infra/policy.xml' }
        groupTotal    = @($all).Count
    } | ConvertTo-Json -Depth 8
    exit 0
}

Write-Host ''
Write-Host ("Bill of materials - {0}" -f $ApimName) -ForegroundColor Cyan
Write-Host ("  {0} resource(s) in {1}; {2} belong to this gateway." -f @($all).Count, $ResourceGroup, $created.Count) -ForegroundColor DarkGray

Write-Host ''
Write-Host '  Created, and billed' -ForegroundColor Cyan
Write-Host ("  {0,-46} {1,-12} {2}" -f 'Type', 'SKU', 'What it costs')
Write-Host ('  ' + ('-' * 118)) -ForegroundColor DarkGray
foreach ($r in $created) {
    $short = ($r.type -split '/')[-1]
    Write-Host ("  {0,-46} {1,-12} {2}" -f $r.type, $(if ($r.sku) { $r.sku } else { '-' }), $COST[$r.type])
}

Write-Host ''
Write-Host '  Reused, not created' -ForegroundColor Cyan
if ($foundry) {
    Write-Host ("  {0,-46} {1}" -f 'Microsoft.CognitiveServices/accounts', $foundry)
    Write-Host '    Your Foundry account. The gateway calls it with its managed identity and bills' -ForegroundColor DarkGray
    Write-Host '    on your existing agreement - removing the gateway does not remove it.' -ForegroundColor DarkGray
}
else { Write-Host '  could not read the backend from the API' -ForegroundColor Yellow }

Write-Host ''
Write-Host '  Configured, and free' -ForegroundColor Cyan
Write-Host ("  {0,-46} {1}" -f 'API Management named values', "$($nv.Count) - entitlement, budgets, business units, model lists")
Write-Host ("  {0,-46} {1}" -f 'API policy', 'infra/policy.xml - every control the gateway enforces')
Write-Host ("  {0,-46} {1}" -f 'Saved KQL functions', $(if ($fn.Count) { $fn -join ', ' } else { 'none published' }))
Write-Host ("  {0,-46} {1}" -f 'Entra groups', 'tiers, business units and teams - directory objects, no Azure bill')
Write-Host ("  {0,-46} {1}" -f 'Role assignment', 'Cognitive Services User, gateway identity on the Foundry account')

Write-Host ''
Write-Host '  Most of this accelerator is configuration rather than infrastructure, which is' -ForegroundColor DarkGray
Write-Host '  why the footprint is one API Management instance plus telemetry. Prices are' -ForegroundColor DarkGray
Write-Host '  regional and change; see the Azure pricing calculator rather than a figure here.' -ForegroundColor DarkGray
Write-Host ''
