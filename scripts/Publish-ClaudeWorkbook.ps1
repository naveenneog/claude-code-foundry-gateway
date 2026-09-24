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
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
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
#
# The tenant matters too. "#@/resource/..." - the form this script used to
# emit - has an empty tenant, so the portal opens the resource in whichever
# directory the browser last used. For an account in more than one tenant that
# is usually the wrong one, and the blade then reports that the resource does
# not exist. Naming the tenant makes the link work for whoever it is sent to,
# not only for the person who generated it.
$TenantId = az account show --query tenantId -o tsv 2>$null
if ($TenantId) { $TenantId = $TenantId.Trim() }
$portalBase = "https://portal.azure.com/#@$TenantId/resource"
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
        Write-Host ("  {0,-34} {1}{2}" -f $w.properties.displayName, $portalBase, $w.id)
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
# The same workspace as a bare ARM resource id, with no management endpoint in
# front of it. $workspaceId above is a REST URL and is correct for calling the
# API; it is wrong everywhere the *portal* is the reader. A workbook's sourceId
# and a tile's crossComponentResources are resource ids, and given a URL the
# portal cannot resolve it - the workbook then opens with "No Log Analytics
# workspace resources are selected" on every tile, which reads as a broken
# dashboard rather than a malformed id.
$workspaceArmId = "$armPath/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"

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
# Resolve before reading. Test-Path resolves a relative path against the
# PowerShell location, but [IO.File] uses the .NET current directory, which is
# where the process started and is rarely the same. A relative -WorkbookFile
# therefore passed the check above and then failed the read with a path nobody
# typed.
$WorkbookFile = (Resolve-Path $WorkbookFile).ProviderPath
$json = [IO.File]::ReadAllText($WorkbookFile)

# Fail before publishing rather than after: an invalid definition produces a
# workbook that opens to an error, which is harder to diagnose than a script
# that refused.
try { $null = $json | ConvertFrom-Json }
catch { throw "$WorkbookFile is not valid JSON, so it would publish a workbook that cannot open. $($_.Exception.Message)" }

# Bind every query tile to the workspace.
#
# sourceId below scopes the workbook, but it does not tell an individual tile
# which resource to run its query against. Without that, a tile renders "No Log
# Analytics workspace resources are selected. Please select Log Analytics
# workspace." and the dashboard looks broken on first open - the operator is
# expected to pick the workspace by hand, every time, on a workbook that already
# knows which one it belongs to.
#
# Injected here rather than written into the .json so the definition stays
# portable: the file ships with no subscription or workspace id in it, and each
# deployment publishes the same file against its own workspace.
$wb = $json | ConvertFrom-Json
$bound = 0
function Set-WorkbookScope($node) {
    if ($null -eq $node) { return }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        foreach ($child in $node) { Set-WorkbookScope $child }
        return
    }
    if ($node -isnot [psobject]) { return }

    foreach ($prop in @($node.PSObject.Properties)) {
        # A query that targets a workspace needs the workspace naming it.
        if ($prop.Name -eq 'resourceType' -and $prop.Value -eq 'microsoft.operationalinsights/workspaces') {
            if ($node.PSObject.Properties.Name -contains 'crossComponentResources') {
                $node.crossComponentResources = @($workspaceArmId)
            } else {
                $node | Add-Member -NotePropertyName 'crossComponentResources' -NotePropertyValue @($workspaceArmId)
            }
            $script:bound++
        }
        if ($prop.Value -is [psobject] -or ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string])) {
            Set-WorkbookScope $prop.Value
        }
    }
}
Set-WorkbookScope $wb.items
if (-not $bound) {
    throw ("$WorkbookFile has no tile targeting a Log Analytics workspace, so nothing would query anything. " +
           "Every query item needs resourceType 'microsoft.operationalinsights/workspaces'.")
}
$json = $wb | ConvertTo-Json -Depth 40 -Compress:$false

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
        sourceId       = $workspaceArmId
    }
} | ConvertTo-Json -Depth 6

Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body $body | Out-Null

Write-Host ("  published, bound to {0}" -f $WorkspaceName) -ForegroundColor Green
Write-Host ("  functions in use: {0}" -f ($needed -join ', ')) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Open it:' -ForegroundColor DarkGray
Write-Host ("    $portalBase$armPath/providers/Microsoft.Insights/workbooks/$guid") -ForegroundColor Cyan
Write-Host ''
# Derived from the file just published, not stated as a blanket fact. Two
# workbooks ship and they differ: the usage workbook counts no cache at all,
# while the chargeback workbook prices cache reads. A fixed sentence was true
# for one and false for the other, and the false one understated the largest
# component on the page.
if ($json -match 'cache_read_usd') {
    Write-Host '  Figures are list price. Cache reads are priced; cache writes are not counted' -ForegroundColor DarkGray
    Write-Host '  at all, so real spend is higher than shown. See docs/MONITORING.md.' -ForegroundColor DarkGray
} else {
    Write-Host '  Figures are list price and exclude cached tokens. See docs/MONITORING.md.' -ForegroundColor DarkGray
}
Write-Host ''
