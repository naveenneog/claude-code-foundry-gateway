<#
.SYNOPSIS
    Resolves Microsoft Entra group membership into an entitlement snapshot file for the Cosmos projection.

.DESCRIPTION
    The directory side of ADR-0005, export only (ADR-0051 amendment 2). Sync-ClaudeAccess.ps1
    writes the same membership into API Management named values; this resolves it with the same
    Graph calls, so the two cannot disagree about who is in a group.

    The script writes a snapshot file and contacts no Cosmos endpoint. sync/src/apply-projection.mjs
    is the one Cosmos writer: it serialises writers with an apply lock and records every sync, and
    the default Cosmos account has no public endpoint. Sync-ClaudeAccess.ps1 exports with this script
    and applies the file through the in-network runner.

.PARAMETER Account
    Cosmos account name, cosmos-<prefix> as projection.bicep names it. Used for the printed apply command.

.PARAMETER WhatIf
    Resolve and report, writing no snapshot file.

.EXAMPLE
    ./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-claude-gw-fzgql9 -ApimName apim-claude-gw -ResourceGroup rg-claude-gw -ExportPath snapshot.json -WhatIf

.EXAMPLE
    ./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-claude-gw-fzgql9 -ApimName apim-claude-gw -ResourceGroup rg-claude-gw -ExportPath snapshot.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$Account,
    [string]$Database = 'claude',
    [string]$Container = 'entitlement',
    [string]$TenantId,

    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',

    [string]$ConfigPath,

    # Business unit groups, as bu-registry records them: id=group-name, in
    # precedence order. Prefer -ApimName and -ResourceGroup instead, which read
    # the registry and its parents from the gateway exactly as
    # Sync-ClaudeAccess.ps1 does.
    [string[]]$BusinessUnitGroups,

    # The gateway whose business-unit registry this projection must agree with.
    [string]$ApimName,
    [string]$ResourceGroup,

    # Resolve membership and write it to a snapshot file. Required: the operator's
    # own sign-in reads Graph here, and sync/src/apply-projection.mjs applies the
    # file from inside the network with an identity that can write only the
    # container. No credential crosses into the network - only object ids and tiers.
    # An empty resolve and orphan removal are decided by the writer (--allow-empty).
    [ValidateRange(60,7200)][int]$MaxAgeSeconds = 7200,
    [string]$ExportPath,

    # Export a snapshot for one user only. The apply side then upserts or
    # deletes only that user's record.
    [string]$User
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Projection sync requires PowerShell 7 or later; run in pwsh.' }
if ($User -and -not $ExportPath) { throw '-User requires -ExportPath because targeted sync is applied from a snapshot. Remedy: run scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -User <upn-or-object-id>, which exports and applies it, or pass -ExportPath <file>.' }
if (-not $ExportPath) {
    throw ('Sync-ClaudeProjection.ps1 only resolves membership into a snapshot file (ADR-0051 amendment 2): ' +
        'sync/src/apply-projection.mjs is the one Cosmos writer, because it takes the apply lock and records each sync. ' +
        'Nothing was read or written. Remedy: run scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> ' +
        '(add -User <upn-or-object-id> for one person), which exports and applies through the runner; or pass -ExportPath <file> ' +
        'and apply that file on the runner with sync/src/apply-projection.mjs --snapshot.')
}
. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

function Resolve-ClaudeProjectionUserObjectId {
    param([Parameter(Mandatory)][string]$Identity, [Parameter(Mandatory)][string]$Token)
    $guid = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if ($Identity -match $guid) { return $Identity.ToLowerInvariant() }
    if ($Identity -notmatch "^[A-Za-z0-9.!#`$%&'*+/=?^_``{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$") {
        throw '-User must be an object id GUID or a valid user principal name. Remedy: pass the user''s object id or user principal name, for example -User dev@contoso.com.'
    }
    $encoded = [uri]::EscapeDataString($Identity)
    $user = Invoke-ClaudeGraphRead -Uri "https://graph.microsoft.com/v1.0/users/${encoded}?`$select=id" -Token $Token
    if (-not $user -or [string]$user.id -notmatch $guid) { throw "Graph did not return a valid object id for user '$Identity'." }
    return ([string]$user.id).ToLowerInvariant()
}

function Invoke-ClaudeProjectionCheckMemberGroups {
    param([Parameter(Mandatory)][string]$UserObjectId, [Parameter(Mandatory)][string[]]$GroupIds, [Parameter(Mandatory)][string]$Token)
    $guid = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if ($UserObjectId -notmatch $guid) { throw 'Target user object id must be a GUID.' }
    $matched = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $GroupIds.Count; $i += 20) {
        $batch = @($GroupIds[$i..([Math]::Min($i + 19, $GroupIds.Count - 1))] | Where-Object { $_ })
        if (-not $batch.Count) { continue }
        $body = @{ groupIds = @($batch) } | ConvertTo-Json -Depth 3
        try {
            $page = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$UserObjectId/checkMemberGroups" `
                -Method Post -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
                -Body $body -TimeoutSec 30 -ErrorAction Stop
        } catch {
            throw "Graph checkMemberGroups failed for target user: $($_.Exception.Message) $(Get-ClaudeGraphFailureRemedy $_.Exception.Message)"
        }
        if (-not $page -or -not $page.PSObject.Properties['value'] -or $page.value -isnot [array]) {
            throw 'Graph checkMemberGroups returned an invalid collection.'
        }
        foreach ($id in @($page.value)) { if ($id -match $guid) { $null = $matched.Add([string]$id) } }
    }
    return ,$matched
}

function Get-ClaudeProjectionUnitRegistry {
    param([string[]]$BusinessUnitGroups, [string]$ApimName, [string]$ResourceGroup)
    $units = @()
    if ($BusinessUnitGroups) {
        foreach ($spec in $BusinessUnitGroups) {
            $parts = $spec -split '=', 2
            if ($parts.Count -ne 2) { Write-Warning "Skipping '$spec' - expected id=group-name"; continue }
            $units += [pscustomobject]@{ Id = $parts[0].Trim(); Group = $parts[1].Trim() }
        }
    }
    elseif ($ApimName -and $ResourceGroup) {
        . (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
        . (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
        $registry = @(ConvertFrom-ClaudeBuRegistry (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'))
        $parents = ConvertFrom-ClaudeBuParents (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents')
        $units = @(Sort-ClaudeBuByDepth $registry -Parents $parents)
    }
    return @($units)
}

function Resolve-ClaudeProjectionTargetRecord {
    param([string]$UserObjectId, [string]$Token, [string]$StandardGroup, [string]$PremiumGroup, [object[]]$Units)
    $groupSpecs = [Collections.Generic.List[object]]::new()
    foreach ($spec in @(
        [pscustomobject]@{ Kind='tier'; Id='premium'; Group=$PremiumGroup },
        [pscustomobject]@{ Kind='tier'; Id='standard'; Group=$StandardGroup }
    )) {
        $group = Get-ClaudeGraphGroup -GroupName $spec.Group -Token $Token
        if ($group) { $groupSpecs.Add([pscustomobject]@{ Kind=$spec.Kind; Id=$spec.Id; GroupId=[string]$group.id }) }
    }
    foreach ($u in @($Units)) {
        $group = Get-ClaudeGraphGroup -GroupName $u.Group -Token $Token
        if ($group) { $groupSpecs.Add([pscustomobject]@{ Kind='bu'; Id=$u.Id; GroupId=[string]$group.id }) }
    }
    if (-not $groupSpecs.Count) { return $null }
    $memberships = Invoke-ClaudeProjectionCheckMemberGroups -UserObjectId $UserObjectId -GroupIds @($groupSpecs.GroupId) -Token $Token
    $tier = ''
    foreach ($name in 'premium','standard') {
        $spec = @($groupSpecs | Where-Object { $_.Kind -eq 'tier' -and $_.Id -eq $name } | Select-Object -First 1)
        if ($spec.Count -and $memberships.Contains($spec[0].GroupId)) { $tier = $name; break }
    }
    if (-not $tier) { return $null }
    $businessUnit = ''
    foreach ($u in @($Units)) {
        $spec = @($groupSpecs | Where-Object { $_.Kind -eq 'bu' -and $_.Id -eq $u.Id } | Select-Object -First 1)
        if ($spec.Count -and $memberships.Contains($spec[0].GroupId)) { $businessUnit = [string]$u.Id; break }
    }
    return [pscustomobject]@{ Oid = $UserObjectId; Name = $UserObjectId; Tier = $tier; BusinessUnit = $businessUnit }
}

# ---------------------------------------------------------------- config file
if ($ConfigPath) {
    try {
        $raw = if ($ConfigPath -match '^https?://') {
            (Invoke-WebRequest -Uri $ConfigPath -UseBasicParsing -TimeoutSec 30).Content
        } else { Get-Content $ConfigPath -Raw }
        $cfg = $raw | ConvertFrom-Json
        if (-not $TenantId -and $cfg.tenantId) { $TenantId = $cfg.tenantId }
        if ($cfg.standardGroup) { $StandardGroup = $cfg.standardGroup }
        if ($cfg.premiumGroup)  { $PremiumGroup  = $cfg.premiumGroup }
        Ok "loaded from $ConfigPath"
    } catch { Write-Warning "Could not read $ConfigPath - $($_.Exception.Message)" }
}

Write-Host ''
Write-Host 'Entra groups -> entitlement projection' -ForegroundColor Cyan
Write-Host "Account  : $Account"
Write-Host "Container: $Database/$Container"

# ---------------------------------------------------------------- 1. identity
Step 'Signing in'
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Bad "Run 'az login' first."; exit 1 }
if (-not $TenantId) { $TenantId = $acct.tenantId }
Ok "$($acct.user.name)  tenant $TenantId"

# The projection records the tenant on every document, and the resolver refuses
# a record from another one. Writing records stamped with a tenant the operator
# is not signed in to would produce a projection nothing will ever honour.
if ($acct.tenantId -ne $TenantId) {
    Bad "Signed in to $($acct.tenantId) but asked to stamp records with $TenantId."
    Note 'The resolver refuses a record whose tenantId does not match its own,'
    Note 'so these records would be written and then never honoured.'
    Note "  az login --tenant $TenantId"
    exit 1
}

$graphToken = Get-GraphToken
Ok 'Graph token acquired (export only - Cosmos is not contacted)'

# ---------------------------------------------------------------- 2. resolve
$units = @(Get-ClaudeProjectionUnitRegistry -BusinessUnitGroups $BusinessUnitGroups -ApimName $ApimName -ResourceGroup $ResourceGroup)
Step 'Reading group membership'
$scanStarted = [DateTimeOffset]::UtcNow
$byOid = @{}
$targetUserOid = $null

if ($User) {
    $targetUserOid = Resolve-ClaudeProjectionUserObjectId -Identity $User -Token $graphToken
    $targetRecord = Resolve-ClaudeProjectionTargetRecord -UserObjectId $targetUserOid -Token $graphToken -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -Units $units
    if ($targetRecord) { $byOid[$targetRecord.Oid] = $targetRecord }
    Write-Host ("  {0,-10} {1,-32} {2} record(s)" -f 'user', $targetUserOid, $byOid.Count)
} else {
    foreach ($t in @(
        @{ Name = 'premium';  Group = $PremiumGroup },
        @{ Name = 'standard'; Group = $StandardGroup })) {
        $members = @(Get-GroupMemberOids -GroupName $t.Group -Token $graphToken)
        Write-Host ("  {0,-10} {1,-32} {2} member(s)" -f $t.Name, $t.Group, $members.Count)
        foreach ($m in $members) {
            # Premium is read first and wins, matching the policy, which checks the
            # premium list before the standard one. Someone in both groups is
            # premium in the gateway, so the projection must say the same.
            if (-not $byOid.ContainsKey($m.Oid)) {
                $byOid[$m.Oid] = [pscustomobject]@{ Oid = $m.Oid; Name = $m.Name; Tier = $t.Name; BusinessUnit = '' }
            }
        }
    }

    if ($units.Count) {
        Step 'Reading business unit membership'
        $assigned = @{}
        foreach ($u in $units) {
            $bm = @(Get-GroupMemberOids -GroupName $u.Group -Token $graphToken)
            Write-Host ("  {0,-22} {1,-30} {2} member(s)" -f $u.Id, $u.Group, $bm.Count)
            foreach ($m in $bm) {
                if (-not $byOid.ContainsKey($m.Oid)) { Note "  $($m.Name) is in $($u.Id) but no tier - not entitled, so not projected"; continue }
                if (-not $assigned.ContainsKey($m.Oid)) { $byOid[$m.Oid].BusinessUnit = $u.Id; $assigned[$m.Oid] = $true }
            }
        }
    }
}

$resolved = @($byOid.Values)
Write-Host ''
Ok "$($resolved.Count) entitled identity(ies) resolved"
$generation = [guid]::NewGuid().ToString()
$verifiedAt = $scanStarted.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$expiresAt = $scanStarted.ToUnixTimeSeconds() + $MaxAgeSeconds
if ($expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
    throw 'Directory scan outlived the snapshot apply-by limit. Nothing exported; resolve again. Remedy: rerun this command; a directory whose scan takes longer than -MaxAgeSeconds (at most 7200) is synced by the optional job, scripts/Deploy-ClaudeProjectionRenewal.ps1.'
}
Step 'Writing the snapshot'
$snapshot = [ordered]@{
    kind           = 'claude-entitlement-snapshot'
    tenantId       = $TenantId
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    reconciliationGeneration = $generation
    lastVerifiedAt = $verifiedAt
    expiresAt      = $expiresAt
    mappingVersion = [int][double]::Parse((Get-Date -UFormat %s))
    groups         = [ordered]@{ standard = $StandardGroup; premium = $PremiumGroup; businessUnits = @($BusinessUnitGroups) }
    records        = @($resolved | ForEach-Object { [ordered]@{ oid = $_.Oid; tier = $_.Tier; businessUnit = $_.BusinessUnit } })
}
if ($targetUserOid) {
    $snapshot.scope = 'user'
    $snapshot.user = $targetUserOid
}
# Without a byte-order mark: Windows PowerShell 5.1 adds one to UTF8 and
# JSON.parse in Node refuses it.
$full = if ([IO.Path]::IsPathRooted($ExportPath)) { $ExportPath } else { Join-Path (Get-Location) $ExportPath }
$full = [IO.Path]::GetFullPath($full)
if (-not $PSCmdlet.ShouldProcess($full, 'write the entitlement snapshot')) {
    Note "WhatIf: $($resolved.Count) record(s) resolved; no snapshot file was written and Cosmos was not contacted."
    $global:LASTEXITCODE = 0
    return
}
[IO.File]::WriteAllText($full, ($snapshot | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Ok "$($resolved.Count) record(s) written to $full"
Note 'Nothing was written to Cosmos. scripts/Sync-ClaudeAccess.ps1 applies a snapshot through the runner.'
Note 'To apply this file by hand from inside the network:'
Note "  node sync/src/apply-projection.mjs --cosmos https://$Account.documents.azure.com:443/ --tenant $TenantId --account-resource-id <account-id> --snapshot <file>"
Note "  <account-id> is the output of: az cosmosdb show -n $Account -g <rg> --query id -o tsv"
$global:LASTEXITCODE = 0