<#
.SYNOPSIS
    Restores gateway configuration from a backup file.

.DESCRIPTION
    Reads a file written by Backup-ClaudeGateway.ps1 and puts the configuration
    back: named values, the API policy, the saved KQL functions and the
    workbooks.

    It is a dry run until you pass -Apply. A restore overwrites live
    entitlement and live budgets, and the difference between "this is what would
    change" and "this is what I changed" is the difference between a migration
    and an incident.

    Two refusals, both deliberate:

      wrong gateway   a backup records the subscription, resource group and
                      instance it came from. Restoring into a different one is a
                      legitimate thing to want - it is how a migration works -
                      but it is never the thing you want by accident, so it
                      needs -Force.

      unknown schema  a file from a newer version of the backup script may hold
                      shapes this one does not understand. Applying the parts it
                      recognises would leave the gateway half configured.

    Secrets are not in the file and cannot be restored. Their names are, so this
    reports what has to be set by hand.

.PARAMETER Apply
    Actually write. Without it, nothing is changed.

.PARAMETER Force
    Allow restoring into a gateway other than the one the backup came from.

.EXAMPLE
    ./scripts/Restore-ClaudeGateway.ps1 -Path ./backups/claude-gateway-....json
    ./scripts/Restore-ClaudeGateway.ps1 -Path ./backups/....json -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Apply,
    [switch]$Force,
    [string]$ResourceGroup,
    [string]$ApimName,
    [string]$WorkspaceName,
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$SCHEMA = 1

function Get-Token {
    $t = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire an Azure Resource Manager token. Run: az login" }
    return $t.Trim()
}

if (-not (Test-Path $Path)) { throw "No backup at '$Path'." }
$backup = try { Get-Content $Path -Raw | ConvertFrom-Json } catch { throw "'$Path' is not valid JSON: $($_.Exception.Message)" }

if ($null -eq $backup.schemaVersion) {
    throw "'$Path' has no schemaVersion, so it was not written by Backup-ClaudeGateway.ps1."
}
if ($backup.schemaVersion -ne $SCHEMA) {
    throw ("'$Path' is schema version $($backup.schemaVersion); this script understands $SCHEMA. " +
           "Applying only the parts it recognises would leave the gateway half configured. " +
           "Use the version of the accelerator that wrote it.")
}

# Default to where the backup came from, so the common case - putting a gateway
# back the way it was - needs no arguments.
if (-not $SubscriptionId) { $SubscriptionId = $backup.gateway.subscriptionId }
if (-not $ResourceGroup)  { $ResourceGroup  = $backup.gateway.resourceGroup }
if (-not $ApimName)       { $ApimName       = $backup.gateway.apimName }
if (-not $WorkspaceName)  { $WorkspaceName  = $backup.gateway.workspaceName }
$apiId = if ($backup.gateway.apiId) { $backup.gateway.apiId } else { 'claude-foundry' }

$sameGateway = ($SubscriptionId -eq $backup.gateway.subscriptionId) -and
               ($ResourceGroup -eq $backup.gateway.resourceGroup) -and
               ($ApimName -eq $backup.gateway.apimName)

Write-Host ''
Write-Host ("Restore from {0}" -f (Split-Path $Path -Leaf)) -ForegroundColor Cyan
Write-Host ("  taken     {0} by {1}" -f $backup.capturedAt, $backup.capturedBy) -ForegroundColor DarkGray
Write-Host ("  from      {0} / {1}" -f $backup.gateway.resourceGroup, $backup.gateway.apimName) -ForegroundColor DarkGray
Write-Host ("  into      {0} / {1}" -f $ResourceGroup, $ApimName) -ForegroundColor $(if ($sameGateway) { 'DarkGray' } else { 'Yellow' })

if (-not $sameGateway -and -not $Force) {
    Write-Host ''
    throw ("This backup came from $($backup.gateway.resourceGroup)/$($backup.gateway.apimName) and you are " +
           "restoring into $ResourceGroup/$ApimName. That is how a migration works, but it is never what you " +
           "want by accident - it overwrites the target's entitlement and budgets with another deployment's. " +
           "Add -Force if you mean it.")
}

$headers = @{ Authorization = "Bearer $(Get-Token)"; 'Content-Type' = 'application/json' }
$rg = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$apim = "$rg/providers/Microsoft.ApiManagement/service/$ApimName"

# --- work out what would change --------------------------------------------
$live = @{}
try {
    $nv = Invoke-RestMethod -Uri "$apim/namedValues?api-version=2024-05-01" -Headers $headers
    foreach ($n in $nv.value) { if (-not $n.properties.secret) { $live[$n.name] = [string]$n.properties.value } }
}
catch { throw "Could not read $ApimName to compare against. $($_.Exception.Message)" }

$plan = @()
foreach ($n in $backup.namedValues) {
    $now = if ($live.ContainsKey($n.name)) { $live[$n.name] } else { $null }
    $state = if ($null -eq $now) { 'create' } elseif ($now -ne [string]$n.value) { 'change' } else { 'same' }
    $plan += [pscustomobject]@{ Name = $n.name; State = $state; From = $now; To = [string]$n.value }
}

Write-Host ''
$changing = @($plan | Where-Object { $_.State -ne 'same' })
if (-not $changing.Count) {
    Write-Host '  Named values already match the backup.' -ForegroundColor Green
}
else {
    Write-Host ("  {0,-24} {1,-8} {2}" -f 'Named value', 'Action', 'Change')
    Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
    foreach ($p in $changing) {
        $shorten = { param($s) if ($null -eq $s) { '(absent)' } elseif ($s.Length -gt 34) { $s.Substring(0, 34) + '...' } else { $s } }
        Write-Host ("  {0,-24} {1,-8} {2}  ->  {3}" -f $p.Name, $p.State, (& $shorten $p.From), (& $shorten $p.To)) `
            -ForegroundColor $(if ($p.State -eq 'create') { 'Green' } else { 'Yellow' })
    }
}

Write-Host ''
Write-Host ("  policy      {0}" -f $(if ($backup.policy) { "$($backup.policy.Length) characters would be applied" } else { 'not in this backup' })) -ForegroundColor DarkGray
Write-Host ("  functions   {0} would be published to {1}" -f $backup.functions.Count, $WorkspaceName) -ForegroundColor DarkGray
Write-Host ("  workbooks   {0} would be published" -f $backup.workbooks.Count) -ForegroundColor DarkGray

if ($backup.secretsSkipped.Count) {
    Write-Host ''
    Write-Host ("  {0} secret named value(s) are not in the backup and cannot be restored:" -f $backup.secretsSkipped.Count) -ForegroundColor Yellow
    foreach ($s in $backup.secretsSkipped) { Write-Host "    $s" -ForegroundColor Yellow }
    Write-Host '  Set them by hand after this completes.' -ForegroundColor DarkGray
}

if (-not $Apply) {
    Write-Host ''
    Write-Host '  Dry run. Nothing has been changed. Add -Apply to write.' -ForegroundColor Cyan
    Write-Host ''
    exit 0
}

# --- apply ------------------------------------------------------------------
Write-Host ''
Write-Host '  Applying...' -ForegroundColor Cyan

foreach ($p in $changing) {
    $n = $backup.namedValues | Where-Object { $_.name -eq $p.Name } | Select-Object -First 1
    $body = @{ properties = @{ displayName = $n.displayName; value = [string]$n.value; secret = $false } } | ConvertTo-Json -Depth 4
    Invoke-RestMethod -Uri "$apim/namedValues/$($p.Name)?api-version=2024-05-01" -Headers $headers -Method Put -Body $body | Out-Null
    Write-Host ("    {0} {1}" -f $p.State, $p.Name) -ForegroundColor Green
}

if ($backup.policy) {
    $body = @{ properties = @{ format = 'rawxml'; value = $backup.policy } } | ConvertTo-Json -Depth 4
    Invoke-RestMethod -Uri "$apim/apis/$apiId/policies/policy?api-version=2024-05-01" -Headers $headers -Method Put -Body $body | Out-Null
    Write-Host "    policy applied to $apiId" -ForegroundColor Green
}

if ($WorkspaceName -and $backup.functions.Count) {
    foreach ($f in $backup.functions) {
        $body = @{ properties = @{
            category = $f.category; displayName = $f.displayName; query = $f.query
            functionAlias = $f.functionAlias; functionParameters = $f.functionParameters; version = 2
        } } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Method Put -Headers $headers -Body $body `
            -Uri "$rg/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/savedSearches/$($f.id)?api-version=2020-08-01" | Out-Null
        Write-Host ("    function {0}" -f $f.functionAlias) -ForegroundColor Green
    }
}

foreach ($w in $backup.workbooks) {
    # A backup written before the content fetch was fixed records the workbook's
    # metadata and none of its content. Azure's own error for that arrives at
    # the end of a restore and blames a missing field; saying so here names the
    # real problem, which is the backup.
    if (-not $w.serializedData) {
        throw ("Workbook '$($w.displayName)' in this backup has no content. It was written before " +
               "Backup-ClaudeGateway.ps1 fetched workbook content, so it cannot be restored. Take a " +
               "fresh backup from the source gateway if it is still available.")
    }
    # Rebind to the workspace being restored into. Keeping the recorded sourceId
    # would point a restored workbook at the workspace it came from, which on a
    # migration is the one being left behind.
    $source = if ($WorkspaceName) { "$rg/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" } else { $w.sourceId }
    $body = @{
        location = $w.location
        kind     = 'shared'
        properties = @{
            displayName = $w.displayName; serializedData = $w.serializedData
            version = '1.0'; category = 'workbook'; sourceId = $source
        }
    } | ConvertTo-Json -Depth 6
    Invoke-RestMethod -Method Put -Headers $headers -Body $body `
        -Uri "$rg/providers/Microsoft.Insights/workbooks/$($w.id)?api-version=2023-06-01" | Out-Null
    Write-Host ("    workbook {0}" -f $w.displayName) -ForegroundColor Green
}

Write-Host ''
Write-Host '  Restored.' -ForegroundColor Green
Write-Host '  Run ./scripts/Sync-ClaudeAccess.ps1 to refresh membership from Entra.' -ForegroundColor DarkGray
Write-Host ''
