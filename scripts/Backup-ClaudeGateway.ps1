<#
.SYNOPSIS
    Exports everything that makes this gateway behave the way it does.

.DESCRIPTION
    The migration and disaster path. One file holds the configuration the
    gateway runs on, so it can be moved to another subscription, kept before a
    risky change, or diffed against what is live now.

    What it captures:

      named values   entitlement lists, per-tier limits, the organisation
                     ceiling, per-user overrides, the business unit registry,
                     the parent map, the membership map, model allow lists
      policy         the API policy XML, which is where enforcement lives
      functions      the saved KQL functions published into the workspace
      workbooks      the Observe pane definitions

    What it deliberately does not capture:

      secrets        API Management returns a secret named value's contents only
                     from the listValue action. This reads the plain list, which
                     omits them, so a secret cannot reach the file even by
                     mistake. Secret names are recorded so a restore can say what
                     has to be set by hand.
      telemetry      logs and metrics live in Log Analytics with their own
                     retention; a config backup is not an archive
      Entra groups   membership belongs to the directory. The backup records the
                     group names a business unit points at, not the people in
                     them, because restoring people into a different tenant is
                     not a thing this should attempt.

.PARAMETER Path
    Where to write. Defaults to a timestamped file in ./backups.

.EXAMPLE
    ./scripts/Backup-ClaudeGateway.ps1
    ./scripts/Backup-ClaudeGateway.ps1 -Path C:\safe\before-upgrade.json
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$WorkspaceName,
    [string]$ApiId = 'claude-foundry',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

# Bumped when the shape of the file changes. Restore refuses a version it does
# not know rather than applying half of it.
$SCHEMA = 1

function Get-Token {
    $t = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire an Azure Resource Manager token. Run: az login" }
    return $t.Trim()
}

if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
if (-not $ApimName) {
    $found = @((az apim list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
    if ($found.Count -eq 1) { $ApimName = $found[0].Trim() }
    elseif ($found.Count -eq 0) { throw "No API Management instance in '$ResourceGroup'. Pass -ApimName." }
    else { throw ("$($found.Count) API Management instances in '$ResourceGroup': " + ($found -join ', ') + ". Pass -ApimName.") }
}

$headers = @{ Authorization = "Bearer $(Get-Token)"; 'Content-Type' = 'application/json' }
$rg = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
$apim = "$rg/providers/Microsoft.ApiManagement/service/$ApimName"

Write-Host ''
Write-Host ("Backing up {0} ({1})" -f $ApimName, $ResourceGroup) -ForegroundColor Cyan

# --- named values -----------------------------------------------------------
#
# The plain list, never the listValue action. listValue returns a secret's
# contents, and a backup that writes secrets to a file on disk is a worse
# problem than the one it solves.
$nvResp = Invoke-RestMethod -Uri "$apim/namedValues?api-version=2024-05-01" -Headers $headers
$named = @()
$secretNames = @()
foreach ($n in $nvResp.value) {
    if ($n.properties.secret) { $secretNames += $n.name; continue }
    $named += [ordered]@{
        name        = $n.name
        displayName = $n.properties.displayName
        value       = $n.properties.value
        tags        = $n.properties.tags
    }
}
Write-Host ("  named values   {0} captured, {1} secret and skipped" -f $named.Count, $secretNames.Count) -ForegroundColor Green

# --- policy -----------------------------------------------------------------
$policy = $null
try {
    $p = Invoke-RestMethod -Headers $headers `
        -Uri "$apim/apis/$ApiId/policies/policy?api-version=2024-05-01&format=rawxml"
    $policy = $p.properties.value
    Write-Host ("  policy         {0:n0} characters" -f $policy.Length) -ForegroundColor Green
}
catch { Write-Warning "Could not read the API policy for '$ApiId': $($_.Exception.Message)" }

# --- saved KQL functions ----------------------------------------------------
$functions = @()
$workspaceHow = if ($WorkspaceName) { 'as given' } else { $null }
$workspaceElsewhere = $null
if (-not $WorkspaceName) {
    # Ask the gateway where it writes, rather than guessing from what else is in
    # the resource group. The diagnostic setting on the API Management instance
    # is what routes the ledger rows, so it is the authority.
    #
    # Measured on the reference deployment: three workspaces in one group, and
    # the first one listed is not the gateway's. Choosing by count left this
    # backup unable to choose at all, so it skipped the saved functions - and
    # both workbooks call them, nineteen times between them. A restore from
    # such a file brings the workbooks back without the functions their queries
    # need, and every tile opens on an error.
    #
    # Only a workspace in the gateway's own resource group is taken, because
    # that is where Restore-ClaudeGateway.ps1 publishes the functions back.
    $apimResourceId = $apim -replace '^https://management\.azure\.com', ''
    $diagWs = @((az monitor diagnostic-settings list --resource $apimResourceId --query "[].workspaceId" -o tsv 2>$null) -split "`n" |
            ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    $sameGroup = @($diagWs | Where-Object {
            $_ -match "/resourceGroups/$([regex]::Escape($ResourceGroup))/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$"
        })
    if ($sameGroup.Count -eq 1) {
        $WorkspaceName = ($sameGroup[0] -split '/')[-1]
        $workspaceHow = 'named by the gateway diagnostic setting'
    }
    elseif ($diagWs.Count -gt 0 -and $sameGroup.Count -eq 0) {
        $workspaceElsewhere = $diagWs -join ', '
    }
    else {
        $ws = @((az monitor log-analytics workspace list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
        if ($ws.Count -eq 1) {
            $WorkspaceName = $ws[0].Trim()
            $workspaceHow = 'the only one in the group'
        }
    }
}
if ($WorkspaceName) {
    try {
        $s = Invoke-RestMethod -Headers $headers `
            -Uri "$rg/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/savedSearches?api-version=2020-08-01"
        foreach ($f in ($s.value | Where-Object { $_.properties.category -eq 'Claude' })) {
            $functions += [ordered]@{
                id                 = ($f.id -split '/')[-1]
                displayName        = $f.properties.displayName
                category           = $f.properties.category
                functionAlias      = $f.properties.functionAlias
                functionParameters = $f.properties.functionParameters
                query              = $f.properties.query
            }
        }
        Write-Host ("  functions      {0} from {1} - {2}" -f $functions.Count, $WorkspaceName, $workspaceHow) -ForegroundColor Green
    }
    catch { Write-Warning "Could not read saved functions from '$WorkspaceName': $($_.Exception.Message)" }
}
elseif ($workspaceElsewhere) {
    Write-Host "  functions      skipped - the gateway writes to $workspaceElsewhere," -ForegroundColor Yellow
    Write-Host "                 outside '$ResourceGroup', and restore publishes into the gateway's own group." -ForegroundColor Yellow
    Write-Host '                 Pass -WorkspaceName to choose.' -ForegroundColor Yellow
}
else {
    Write-Host "  functions      skipped - no diagnostic setting names a workspace, and '$ResourceGroup' does not hold exactly one. Pass -WorkspaceName" -ForegroundColor Yellow
}

# --- workbooks --------------------------------------------------------------
$workbooks = @()
$listed = @()
try {
    $w = Invoke-RestMethod -Headers $headers `
        -Uri "$rg/providers/Microsoft.Insights/workbooks?api-version=2023-06-01&category=workbook"
    $listed = @($w.value | Where-Object { $_.properties.displayName -like '*Claude*' })
}
catch {
    # Only the list is tolerated: a gateway may legitimately have no workbooks,
    # or the caller may not be able to read them.
    Write-Warning "Could not list workbooks: $($_.Exception.Message)"
}

foreach ($b in $listed) {
    # The list omits serializedData - the workbook's entire content - and says
    # nothing about doing so. Backing up the list alone produced a file that
    # restored an empty workbook and failed with "the serializedData field is
    # missing or null" at the far end of a migration.
    #
    # $b.id is an ARM path, not a URL. Fetching it directly threw "the hostname
    # could not be parsed", which the first version caught and downgraded to a
    # warning - so the backup reported success and contained no workbook. A
    # workbook that exists and could not be captured fails the backup now,
    # because a quietly incomplete backup is worse than no backup.
    $full = Invoke-RestMethod -Headers $headers `
        -Uri "https://management.azure.com$($b.id)?api-version=2023-06-01&canFetchContent=true"
    if (-not $full.properties.serializedData) {
        throw ("Workbook '$($b.properties.displayName)' returned no content even with canFetchContent. " +
               "Backing it up would record a workbook that cannot be restored.")
    }
    $workbooks += [ordered]@{
        id             = ($b.id -split '/')[-1]
        displayName    = $b.properties.displayName
        serializedData = $full.properties.serializedData
        sourceId       = $b.properties.sourceId
        location       = $b.location
    }
}
Write-Host ("  workbooks      {0}" -f $workbooks.Count) -ForegroundColor Green

# --- write ------------------------------------------------------------------
$backup = [ordered]@{
    schemaVersion = $SCHEMA
    capturedAt    = (Get-Date).ToUniversalTime().ToString('o')
    capturedBy    = (az account show --query user.name -o tsv 2>$null)
    gateway       = [ordered]@{
        subscriptionId = $SubscriptionId
        resourceGroup  = $ResourceGroup
        apimName       = $ApimName
        apiId          = $ApiId
        workspaceName  = $WorkspaceName
    }
    namedValues   = $named
    secretsSkipped = $secretNames
    policy        = $policy
    functions     = $functions
    workbooks     = $workbooks
}

if (-not $Path) {
    $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'backups'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Path = Join-Path $dir ("claude-gateway-{0}-{1}.json" -f $ApimName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

# WriteAllText resolves a relative path against the process working directory,
# which is not PowerShell's location. Resolve it here or the file lands
# somewhere the operator did not ask for.
$full = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location).Path $Path }
New-Item -ItemType Directory -Path (Split-Path $full -Parent) -Force | Out-Null
[IO.File]::WriteAllText($full, ($backup | ConvertTo-Json -Depth 10))

Write-Host ''
Write-Host ("  written to {0}" -f $full) -ForegroundColor Green
Write-Host ("  {0:n0} KB, schema version {1}" -f ((Get-Item $full).Length / 1KB), $SCHEMA) -ForegroundColor DarkGray
if ($secretNames.Count) {
    Write-Host ''
    Write-Host ("  {0} secret named value(s) were not captured: {1}" -f $secretNames.Count, ($secretNames -join ', ')) -ForegroundColor Yellow
    Write-Host '  API Management only returns their contents from listValue, and a backup that' -ForegroundColor DarkGray
    Write-Host '  writes secrets to disk is a worse problem than the one it solves. Set them by' -ForegroundColor DarkGray
    Write-Host '  hand after a restore; the names are recorded in the file.' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  Restore with ./scripts/Restore-ClaudeGateway.ps1 -Path <file>.' -ForegroundColor DarkGray
Write-Host '  It is a dry run until you add -Apply.' -ForegroundColor DarkGray
Write-Host ''
