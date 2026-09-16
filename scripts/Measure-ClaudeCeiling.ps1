<#
.SYNOPSIS
    Reports how close this gateway is to the limits that stop it scaling.

.DESCRIPTION
    "500,000 employees" is not a capacity specification, and no single number
    tells you whether a deployment will hold. This reads the live gateway and
    reports each measured ceiling, what is consumed against it, and which one
    is reached first.

    Every figure here was measured against a live API Management instance
    rather than read from a document, because the two have disagreed before.

      Named value maximum       4,096 characters. 4,096 returns 201, 4,097
                                returns 400 ValidationError. Measured
                                2026-09-16 on BasicV2.

      Identities per list       110. A 110-object-id list is 4,071 characters
                                and is accepted; 111 is 4,108 and is rejected.
                                An object id plus its separator is 37
                                characters, so the list holds
                                floor(4095 / 37) = 110.

      Named values per instance 5,000 on Consumption, Developer, Basic and
                                Basic v2; 10,000 on Standard and Standard v2;
                                18,000 on Premium and Premium v2. Published,
                                not measured - creating 5,000 of them on a
                                live instance is not a test worth running.
                                https://learn.microsoft.com/azure/api-management/service-limits

    The exit code is non-zero when any ceiling is past -FailAtPercent, so this
    runs as a check rather than only as a report.

.PARAMETER FailAtPercent
    Consumption above this fraction of a ceiling fails the run. Defaults to 80.

.EXAMPLE
    ./scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup rg-claude -ApimName apim-claude

.EXAMPLE
    ./scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup rg-claude -ApimName apim-claude -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [int]$FailAtPercent = 80,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

# Measured, not assumed. See the block comment above for how.
$MaxChars      = 4096
$OidCost       = 37    # 36-character guid plus one separator
$MaxIdentities = [int][math]::Floor(($MaxChars - 1) / $OidCost)

# Published per-instance named value ceiling, by SKU family. The key is what
# `az apim show --query sku.name` returns.
$NamedValueCap = @{
    'Consumption' = 5000
    'Developer'   = 5000
    'Basic'       = 5000
    'BasicV2'     = 5000
    'Standard'    = 10000
    'StandardV2'  = 10000
    'Premium'     = 18000
    'PremiumV2'   = 18000
}

# The lists that hold one entry per identity. These are the ones that stop the
# deployment growing; the rest are single scalars and cannot run out.
$IdentityLists = @{
    'allow-standard' = 'Standard tier entitlement'
    'allow-premium'  = 'Premium tier entitlement'
    'bu-members'     = 'Business unit membership'
}

Write-Host ''
Write-Host 'Gateway scale ceilings' -ForegroundColor Cyan
Write-Host "  APIM : $ApimName ($ResourceGroup)"

$sku = az apim show -g $ResourceGroup -n $ApimName --query 'sku.name' -o tsv 2>$null
if (-not $sku) { throw "Could not read the SKU of '$ApimName' in '$ResourceGroup'. Check the name and that you are signed in." }
$sku = $sku.Trim()

$cap = $NamedValueCap[$sku]
if (-not $cap) {
    # A SKU this script has not seen. Report it rather than guessing a cap:
    # a wrong ceiling is worse than a stated gap.
    Write-Warning "Unknown SKU '$sku'. The per-instance named value cap is not known for it and is reported as unavailable."
}

Write-Host "  SKU  : $sku"
Write-Host ''

$nv = az apim nv list -g $ResourceGroup --service-name $ApimName -o json | ConvertFrom-Json
$nvCount = @($nv).Count

$findings = @()
$worst = 0

foreach ($id in $IdentityLists.Keys | Sort-Object) {
    $entry = $nv | Where-Object { $_.name -eq $id }
    if (-not $entry) { continue }

    # A secret named value comes back with no value. Report that rather than
    # counting it as empty, which would read as "plenty of headroom".
    if ($entry.secret) {
        $findings += [ordered]@{
            list = $id; purpose = $IdentityLists[$id]
            readable = $false
            note = 'Marked secret, so the list is not returned and cannot be measured.'
        }
        continue
    }

    $value = [string]$entry.value
    $chars = $value.Length
    $items = @($value.Trim(',') -split ',' | Where-Object { $_ })
    $pct   = if ($MaxChars) { [math]::Round(100.0 * $chars / $MaxChars, 1) } else { 0 }
    if ($pct -gt $worst) { $worst = $pct }

    # Remaining capacity in the unit the reader is thinking in. bu-members
    # entries carry "oid=unit" so they cost more than a bare object id; derive
    # the real per-entry cost from this list rather than assuming 37.
    $per = if ($items.Count) { [int][math]::Ceiling($chars / $items.Count) } else { $OidCost }
    $room = [int][math]::Floor(($MaxChars - $chars) / $per)

    $findings += [ordered]@{
        list = $id; purpose = $IdentityLists[$id]
        readable = $true
        entries = $items.Count
        chars = $chars
        max_chars = $MaxChars
        percent_used = $pct
        bytes_per_entry = $per
        entries_remaining = $room
    }
}

if ($AsJson) {
    [ordered]@{
        apim = $ApimName
        resource_group = $ResourceGroup
        sku = $sku
        named_values_used = $nvCount
        named_values_cap = $(if ($cap) { $cap } else { $null })
        max_chars_per_value = $MaxChars
        max_identities_per_list = $MaxIdentities
        lists = $findings
        worst_percent = $worst
        fail_at_percent = $FailAtPercent
    } | ConvertTo-Json -Depth 6
} else {
    foreach ($f in $findings) {
        Write-Host ("  {0,-16} {1}" -f $f.list, $f.purpose) -ForegroundColor White
        if (-not $f.readable) {
            Write-Host ("  {0,-16} {1}" -f '', $f.note) -ForegroundColor Yellow
            continue
        }
        $colour = if ($f.percent_used -ge $FailAtPercent) { 'Red' } elseif ($f.percent_used -ge 50) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-16} {1} entries, {2} of {3} characters ({4}%), about {5} more fit" -f `
            '', $f.entries, $f.chars, $f.max_chars, $f.percent_used, $f.entries_remaining) -ForegroundColor $colour
    }

    Write-Host ''
    Write-Host ("  Named values in use: {0}{1}" -f $nvCount, $(if ($cap) { " of $cap for $sku" } else { ' (cap unknown for this SKU)' }))
    Write-Host ("  Ceiling per list   : {0} identities, measured" -f $MaxIdentities)
    Write-Host ''

    # The point of the report. Sharding across named values is the obvious
    # escape and it does not work, so say so here rather than leaving the
    # reader to discover it at 111 developers.
    Write-Host '  What runs out first' -ForegroundColor Cyan
    Write-Host ("    One tier list holds {0} identities. That is the binding limit, and it is" -f $MaxIdentities)
    Write-Host '    reached long before any other ceiling on this instance.'
    Write-Host ''
    Write-Host '    Splitting the list across several named values does not rescue it. The'
    Write-Host '    policy would have to scan every shard on every request, and even at the'
    Write-Host ("    {0} cap of {1} named values the ceiling is only about {2} identities," -f $sku, $(if ($cap) { $cap } else { 5000 }), $(if ($cap) { $cap * $MaxIdentities } else { 5000 * $MaxIdentities }))
    Write-Host '    reached with a policy nobody can operate. See docs/SCALE.md and ADR-0005.'
}

if ($worst -ge $FailAtPercent) {
    Write-Host ''
    Write-Host ("A list is at {0}% of the {1}-character limit, at or past the {2}% threshold." -f $worst, $MaxChars, $FailAtPercent) -ForegroundColor Red
    Write-Host 'Writes fail outright at the limit - they do not truncate. See docs/SCALE.md.' -ForegroundColor Red
    exit 1
}

exit 0
