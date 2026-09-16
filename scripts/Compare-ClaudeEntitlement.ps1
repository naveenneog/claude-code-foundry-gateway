<#
.SYNOPSIS
    Compares the tier the gateway is enforcing against the tier Entra implies.

.DESCRIPTION
    Entitlement is not live. Group membership is projected into API Management
    named values by Sync-ClaudeAccess.ps1, so between a directory change and
    that sync the gateway enforces a stale answer.

    This reports the difference. Every identity is resolved twice - once from
    what the gateway holds now, once from the directory - and the two are
    compared.

    It exists for two jobs:

      Day to day     Answer "is the sync current?" without reading two lists by
                     eye. A developer added to a group an hour ago and still
                     getting 403 shows up here as `missing`.

      Migration      P19b replaces the named-value path with a durable
                     projection. That cannot be cut over blind, so the new path
                     runs beside the old one and the two decisions are compared
                     for the existing cohort before anything is trusted. This is
                     that comparison, against the source both paths read.

    Precedence matches the policy exactly: premium is tested before standard, so
    an identity in both groups is premium. Resolving it the other way here would
    report drift the gateway does not have.

    Exits non-zero when the two disagree, so it runs as a check.

.PARAMETER FailOnDrift
    Return a non-zero exit code when the two sides disagree. On by default;
    pass -FailOnDrift:$false to report without failing.

.EXAMPLE
    ./scripts/Compare-ClaudeEntitlement.ps1 -ResourceGroup rg-claude -ApimName apim-claude

.EXAMPLE
    ./scripts/Compare-ClaudeEntitlement.ps1 -ResourceGroup rg-claude -ApimName apim-claude -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [switch]$AsJson,
    [bool]$FailOnDrift = $true
)

$ErrorActionPreference = 'Stop'

# The same membership read the sync uses. Sharing it is the point: a comparison
# that reads the directory differently from the writer reports its own bugs as
# drift.
. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')

function Get-ListOids {
    param([string]$Id)

    $nv = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id -o json 2>$null
    if (-not $nv) { return @() }
    $o = $nv | ConvertFrom-Json

    # A secret named value returns no value. Treating that as an empty list
    # would report every entitled identity as missing, which is a page of false
    # drift rather than a finding.
    if ($o.secret) {
        throw "Named value '$Id' is marked secret, so its value is not returned and the two sides cannot be compared. Unset the secret flag or compare on a gateway where it is not set."
    }
    return @(([string]$o.value).Trim(',') -split ',' | Where-Object { $_ })
}

# Premium first, exactly as the policy does it.
function Resolve-Tier {
    param([string]$Oid, [string[]]$Premium, [string[]]$Standard)

    if ($Premium -contains $Oid)  { return 'premium' }
    if ($Standard -contains $Oid) { return 'standard' }
    return 'denied'
}

Write-Host ''
Write-Host 'Entitlement: gateway versus directory' -ForegroundColor Cyan
Write-Host "  APIM : $ApimName ($ResourceGroup)"

# Side one: what the gateway is enforcing right now.
$gwPremium  = Get-ListOids 'allow-premium'
$gwStandard = Get-ListOids 'allow-standard'

# Side two: what the directory says now.
$token = Get-GraphToken
$dirPremiumM  = @(Get-GroupMemberOids -GroupName $PremiumGroup  -Token $token)
$dirStandardM = @(Get-GroupMemberOids -GroupName $StandardGroup -Token $token)
$dirPremium   = @($dirPremiumM  | ForEach-Object { $_.Oid })
$dirStandard  = @($dirStandardM | ForEach-Object { $_.Oid })

$names = @{}
foreach ($m in @($dirPremiumM) + @($dirStandardM)) { $names[$m.Oid] = $m.Name }

Write-Host ("  Gateway: {0} premium, {1} standard" -f $gwPremium.Count, $gwStandard.Count)
Write-Host ("  Entra  : {0} premium, {1} standard" -f $dirPremium.Count, $dirStandard.Count)
Write-Host ''

$all = @($gwPremium + $gwStandard + $dirPremium + $dirStandard | Sort-Object -Unique)

$drift = @()
foreach ($oid in $all) {
    $now  = Resolve-Tier -Oid $oid -Premium $gwPremium  -Standard $gwStandard
    $next = Resolve-Tier -Oid $oid -Premium $dirPremium -Standard $dirStandard
    if ($now -eq $next) { continue }

    # Named so the reader knows what to do, not just that something differs.
    $kind = if ($now -eq 'denied') { 'missing' }
            elseif ($next -eq 'denied') { 'stale' }
            else { 'tier-drift' }

    $drift += [ordered]@{
        oid = $oid
        name = $(if ($names[$oid]) { $names[$oid] } else { '(not in either group)' })
        kind = $kind
        gateway = $now
        directory = $next
    }
}

$explain = @{
    'missing'    = 'In the directory, not on the gateway. Gets 403 until the sync runs.'
    'stale'      = 'On the gateway, not in the directory. Still entitled after removal.'
    'tier-drift' = 'Entitled on both sides, at different tiers.'
}

if ($AsJson) {
    [ordered]@{
        apim = $ApimName
        resource_group = $ResourceGroup
        gateway = [ordered]@{ premium = $gwPremium.Count; standard = $gwStandard.Count }
        directory = [ordered]@{ premium = $dirPremium.Count; standard = $dirStandard.Count }
        identities_compared = $all.Count
        drift = $drift
        in_sync = ($drift.Count -eq 0)
    } | ConvertTo-Json -Depth 6
} else {
    if ($drift.Count -eq 0) {
        Write-Host ("  In sync. {0} identities resolve to the same tier on both sides." -f $all.Count) -ForegroundColor Green
    } else {
        foreach ($k in 'missing', 'stale', 'tier-drift') {
            $rows = @($drift | Where-Object { $_.kind -eq $k })
            if (-not $rows.Count) { continue }
            Write-Host ("  {0} ({1})" -f $k, $rows.Count) -ForegroundColor Yellow
            Write-Host ("    {0}" -f $explain[$k]) -ForegroundColor DarkGray
            foreach ($r in $rows) {
                Write-Host ("    {0}  {1}" -f $r.oid, $r.name)
                Write-Host ("      gateway: {0}   directory: {1}" -f $r.gateway, $r.directory) -ForegroundColor DarkGray
            }
            Write-Host ''
        }
        Write-Host '  Run ./scripts/Sync-ClaudeAccess.ps1 to bring the gateway up to the directory.' -ForegroundColor DarkGray
    }
}

if ($drift.Count -and $FailOnDrift) { exit 1 }
exit 0
