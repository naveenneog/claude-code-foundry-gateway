<#
.SYNOPSIS
    Set or clear one developer's daily Claude token budget.

.DESCRIPTION
    The equivalent of setting and clearing a per-user limit through Claude
    Enterprise's Admin API, against a Foundry gateway.

    Overrides live in the quota-overrides named value as ",oid=tokens,". The
    policy resolves it per request, so a change takes effect on the next call -
    no redeployment, no restart.

    An override replaces the daily quota only. Tokens per minute stays at the
    tier value, because the llm-token-limit reference does not allow an
    expression for tokens-per-minute. To change someone's rate, move them
    between tiers.

    This script reads the current map and writes it back with one entry changed.
    It never composes the value from scratch: the entitlement allow list was
    once emptied by a write that assumed an incomplete read, revoking everyone,
    and this is the same failure mode with the same shape.

.PARAMETER User
    The developer, by UPN or object id.

.PARAMETER Tokens
    New daily token budget for that developer.

.PARAMETER Clear
    Remove the override so the tier default applies again.

.EXAMPLE
    ./scripts/Set-ClaudeBudget.ps1 -User someone@contoso.com -Tokens 2000000

.EXAMPLE
    ./scripts/Set-ClaudeBudget.ps1 -User someone@contoso.com -Clear

.EXAMPLE
    ./scripts/Set-ClaudeBudget.ps1 -List
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Clear', Mandatory = $true)]
    [string]$User,

    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [long]$Tokens,

    [Parameter(ParameterSetName = 'Clear', Mandatory = $true)]
    [switch]$Clear,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
$H = @{ Authorization = 'Bearer ' + $armToken.Trim(); 'Content-Type' = 'application/json' }
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$v = '?api-version=2024-05-01'

function Get-Nv($name) {
    try { return (Invoke-RestMethod -Uri "$base/namedValues/$name$v" -Headers $H).properties.value }
    catch { return $null }
}
function Set-Nv($name, $value) {
    $b = @{ properties = @{ displayName = $name; value = "$value"; secret = $false } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/namedValues/$name$v" -Headers $H -Body $b | Out-Null
}
function Split-Sentinel($value) {
    if (-not $value) { return @() }
    return @($value.Trim(',') -split ',' | Where-Object { $_ })
}

$raw = Get-Nv 'quota-overrides'
if ($null -eq $raw) {
    throw "quota-overrides not found on $ApimName. Redeploy with the current template first."
}

# Read the whole map before changing anything, so entries for other people are
# carried through unchanged rather than dropped.
$map = [ordered]@{}
foreach ($pair in (Split-Sentinel $raw)) {
    $bits = $pair -split '=', 2
    if ($bits.Count -eq 2 -and $bits[1] -match '^\d+$') { $map[$bits[0]] = [long]$bits[1] }
    else { Write-Warning "Ignoring malformed override entry '$pair'." }
}

if ($List) {
    if (-not $map.Count) { Write-Host 'No per-user overrides. Everyone is on their tier default.' -ForegroundColor DarkGray; exit 0 }
    Write-Host ''
    Write-Host ("{0,-40} {1,>14}" -f 'Object id', 'Tokens/day')
    Write-Host ('-' * 56) -ForegroundColor DarkGray
    foreach ($k in $map.Keys) { Write-Host ("{0,-40} {1,14:n0}" -f $k, $map[$k]) }
    exit 0
}

# Resolve to an object id. A UPN is what an administrator has to hand; the
# policy keys on oid.
$oid = $User.Trim()
if ($oid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    $resolved = az ad user show --id $oid --query id -o tsv 2>$null
    if (-not $resolved) {
        # Guest accounts are stored under a mangled UPN, so a direct lookup
        # misses them. Same four-strategy problem Import-ClaudeEntitlement hits.
        $escaped = $oid.Replace("'", "''")
        $resolved = az ad user list --filter "mail eq '$escaped'" --query "[0].id" -o tsv 2>$null
    }
    if (-not $resolved) { throw "Could not resolve '$User' to an object id. Pass the object id directly." }
    $oid = $resolved.Trim()
}

$entitled = (Split-Sentinel (Get-Nv 'allow-standard')) + (Split-Sentinel (Get-Nv 'allow-premium'))
if ($entitled -notcontains $oid) {
    Write-Warning "$oid is not in either entitlement group. The override is stored but has no effect until they are entitled."
}

$before = $map.Count
if ($Clear) {
    if (-not $map.Contains($oid)) { Write-Host "No override for $oid. Nothing to clear." -ForegroundColor DarkGray; exit 0 }
    $was = $map[$oid]
    $map.Remove($oid)
    $action = "cleared (was $('{0:n0}' -f $was) tokens/day)"
}
else {
    if ($Tokens -lt 1) { throw "Tokens must be at least 1. To remove the override use -Clear." }
    $action = if ($map.Contains($oid)) { "changed from $('{0:n0}' -f $map[$oid]) to $('{0:n0}' -f $Tokens) tokens/day" }
              else { "set to $('{0:n0}' -f $Tokens) tokens/day" }
    $map[$oid] = $Tokens
}

$value = if ($map.Count) { ',' + (($map.Keys | ForEach-Object { "$_=$($map[$_])" }) -join ',') + ',' } else { ',,' }

# The write is only safe because the map was read first. Assert that the entries
# belonging to other people survived, rather than trusting the string building.
$others = @($map.Keys | Where-Object { $_ -ne $oid })
foreach ($k in $others) {
    if ($value -notmatch [regex]::Escape(",$k=$($map[$k]),") -and $value -notmatch [regex]::Escape(",$k=$($map[$k])")) {
        throw "Refusing to write: override for $k would be lost. Nothing has been changed."
    }
}

Set-Nv 'quota-overrides' $value
Write-Host ""
Write-Host "  $oid $action" -ForegroundColor Green
Write-Host ("  {0} override(s) before, {1} after. Others untouched." -f $before, $map.Count) -ForegroundColor DarkGray
Write-Host '  Takes effect on the next request - the policy resolves this per call.' -ForegroundColor DarkGray
