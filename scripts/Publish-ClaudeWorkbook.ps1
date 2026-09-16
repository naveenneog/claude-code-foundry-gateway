<#
.SYNOPSIS
    Publishes the Claude gateway workbook into the Azure portal.

.DESCRIPTION
    The workbook is the Observe pane: consumption by business unit, by team, by
    developer, by client and by model, plus what the gateway could not
    attribute. It reads the saved KQL functions, so publish those first with
    ./scripts/Publish-ClaudeQueries.ps1.

    A workbook is an ARM resource holding JSON. It runs nothing and stores
    nothing, so it adds no standing cost - the only bill is the query when
    somebody opens it.

    The workbook is bound to one Log Analytics workspace. If the resource group
    holds more than one, it says so rather than guessing, because a workbook
    pointed at the wrong workspace renders empty and looks like no usage.

.PARAMETER Name
    Display name in the portal. Defaults to "Claude gateway".

.PARAMETER List
    Show the Claude workbooks already published, and exit.

.PARAMETER Remove
    Delete the workbook instead of publishing it.

.EXAMPLE
    ./scripts/Publish-ClaudeWorkbook.ps1 -List
    ./scripts/Publish-ClaudeWorkbook.ps1
    ./scripts/Publish-ClaudeWorkbook.ps1 -Name "Claude gateway - platform" -WorkspaceName log-claude-gw-abc
#>
[CmdletBinding()]
param(
    [string]$Name = 'Claude gateway',
    [switch]$List,
    [switch]$Remove,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$WorkspaceName,
    [string]$WorkbookFile,
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $WorkbookFile) { $WorkbookFile = Join-Path $root 'infra/workbook.json' }

function Get-Token {
    $t = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire an Azure Resource Manager token. Run: az login" }
    return $t.Trim()
}

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
$headers = @{ Authorization = "Bearer $(Get-Token)"; 'Content-Type' = 'application/json' }
# Kept apart on purpose: the ARM path is what a portal deep link needs, and
# concatenating the management.azure.com base into one produces a link that
# looks plausible and opens nothing.
$armPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$rgScope = "https://management.azure.com$armPath"

if ($List) {
    $r = Invoke-RestMethod -Method Get -Headers $headers `
        -Uri "$rgScope/providers/Microsoft.Insights/workbooks?api-version=2023-06-01&category=workbook"
    $ours = @($r.value | Where-Object { $_.properties.displayName -like '*Claude*' })
    Write-Host ''
    if (-not $ours.Count) {
        Write-Host "  No Claude workbook in $ResourceGroup. Run this without -List to publish one." -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
    Write-Host ("  {0,-34} {1}" -f 'Display name', 'Opens at')
    Write-Host ('  ' + ('-' * 100)) -ForegroundColor DarkGray
    foreach ($w in $ours) {
        Write-Host ("  {0,-34} https://portal.azure.com/#@/resource{1}" -f $w.properties.displayName, $w.id)
    }
    Write-Host ''
    exit 0
}

if (-not $WorkspaceName) {
    $found = az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null
    $names = @($found -split "`n" | Where-Object { $_ })
    if ($names.Count -eq 1) { $WorkspaceName = $names[0].Trim() }
    elseif ($names.Count -eq 0) { throw "No Log Analytics workspace in '$ResourceGroup'. Pass -WorkspaceName." }
    else {
        throw ("$($names.Count) workspaces in '$ResourceGroup': " + ($names -join ', ') +
               ". Pass -WorkspaceName to say which holds the gateway's telemetry - a workbook " +
               "pointed at the wrong one renders empty and reads as no usage.")
    }
}

$workspaceId = "$rgScope/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"

# Deterministic id from the display name, so re-running updates the workbook in
# place rather than leaving a second copy beside the first.
$md5 = [System.Security.Cryptography.MD5]::Create()
$hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ResourceGroup/$Name"))).Replace('-', '').ToLower()
$guid = [guid]::new($hash.Substring(0, 32))
$uri = "$rgScope/providers/Microsoft.Insights/workbooks/$guid`?api-version=2023-06-01"

Write-Host ''
Write-Host ("Workbook '{0}' in {1}" -f $Name, $ResourceGroup) -ForegroundColor Cyan

if ($Remove) {
    try { Invoke-RestMethod -Uri $uri -Headers $headers -Method Delete | Out-Null; Write-Host "  removed" -ForegroundColor Yellow }
    catch { Write-Host "  was not published" -ForegroundColor DarkGray }
    Write-Host ''
    exit 0
}

if (-not (Test-Path $WorkbookFile)) { throw "Missing workbook definition: $WorkbookFile" }
$json = [IO.File]::ReadAllText($WorkbookFile)

# Fail before publishing rather than after: an invalid definition produces a
# workbook that opens to an error, which is harder to diagnose than a script
# that refused.
try { $null = $json | ConvertFrom-Json }
catch { throw "$WorkbookFile is not valid JSON, so it would publish a workbook that cannot open. $($_.Exception.Message)" }

# The workbook calls the saved functions. Publishing it against a workspace
# where they do not exist gives every tile a "failed to resolve" error, which
# reads as a broken dashboard rather than a missing step.
$saved = Invoke-RestMethod -Method Get -Headers $headers `
    -Uri "$workspaceId/savedSearches?api-version=2020-08-01"
$aliases = @($saved.value | Where-Object { $_.properties.category -eq 'Claude' } | ForEach-Object { $_.properties.functionAlias })
$needed = @([regex]::Matches($json, 'Claude[A-Za-z]+\(') | ForEach-Object { $_.Value.TrimEnd('(') } | Sort-Object -Unique)
$missing = @($needed | Where-Object { $aliases -notcontains $_ })
if ($missing.Count) {
    throw ("The workbook calls " + ($missing -join ', ') + ", which $WorkspaceName does not have. " +
           "Run ./scripts/Publish-ClaudeQueries.ps1 first, or every tile will open on a resolver error.")
}

$body = @{
    location   = (az group show -n $ResourceGroup --query location -o tsv)
    kind       = 'shared'
    properties = @{
        displayName    = $Name
        serializedData = $json
        version        = '1.0'
        category       = 'workbook'
        sourceId       = $workspaceId
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body $body | Out-Null

Write-Host ("  published, bound to {0}" -f $WorkspaceName) -ForegroundColor Green
Write-Host ("  functions in use: {0}" -f ($needed -join ', ')) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Open it:' -ForegroundColor DarkGray
Write-Host ("    https://portal.azure.com/#@/resource$armPath/providers/Microsoft.Insights/workbooks/$guid") -ForegroundColor Cyan
Write-Host ''
Write-Host '  Figures are list price and exclude cached tokens. See docs/MONITORING.md.' -ForegroundColor DarkGray
Write-Host ''
