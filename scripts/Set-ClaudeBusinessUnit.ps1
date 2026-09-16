<#
.SYNOPSIS
    Add, change or remove a business unit.

.DESCRIPTION
    A business unit is an Entra group with a monthly budget. Membership comes
    from the group, so adding a developer to a business unit is done in Entra and
    picked up by Sync-ClaudeAccess.ps1. See docs/adr/0007-business-unit-model.md.

    The identifier is stable and the display name is not. `finance` is what the
    counter, the ledger and every report use; the group behind it can be renamed
    without orphaning the history.

    The budget is set in dollars and stored in tokens, converted once here rather
    than per request. That conversion is an approximation and is reported as one:
    Claude's output tokens cost five times base input, so a dollar does not buy a
    fixed number of tokens, and the gateway's quota counter excludes cached
    tokens entirely - on thirty days of live usage, 38.7% of the real cost
    weight. It is a spend guide, not an accounting figure.

.PARAMETER Id
    The business unit's stable identifier: lower-case letters, digits, hyphens.

.PARAMETER Group
    The Entra group whose members belong to it.

.PARAMETER MonthlyBudgetUsd
    Monthly budget in US dollars, converted to tokens on write.

.PARAMETER Model
    Model to price the conversion against. Defaults to claude-sonnet-5.

.PARAMETER OutputShare
    Fraction of tokens assumed to be output, which is the expensive half.
    Defaults to 0.2, deliberately conservative.

.PARAMETER Remove
    Remove the business unit. Its members fall back to unassigned.

.PARAMETER List
    Show the registry and change nothing.

.EXAMPLE
    ./scripts/Set-ClaudeBusinessUnit.ps1 -Id finance -Group "Claude BU Finance" -MonthlyBudgetUsd 5000

.EXAMPLE
    ./scripts/Set-ClaudeBusinessUnit.ps1 -Id finance -MonthlyBudgetUsd 8000

.EXAMPLE
    ./scripts/Set-ClaudeBusinessUnit.ps1 -Id finance -Remove
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [Parameter(ParameterSetName = 'Remove', Mandatory = $true)]
    [string]$Id,

    [Parameter(ParameterSetName = 'Set')]
    [string]$Group,

    [Parameter(ParameterSetName = 'Set')]
    [AllowEmptyString()]
    [string]$Parent,

    [Parameter(ParameterSetName = 'Set')]
    [switch]$SkipGroupCheck,

    [Parameter(ParameterSetName = 'Set')]
    [double]$MonthlyBudgetUsd,

    [Parameter(ParameterSetName = 'Set')]
    [string]$Model = 'claude-sonnet-5',

    [Parameter(ParameterSetName = 'Set')]
    [double]$OutputShare = 0.2,

    [Parameter(ParameterSetName = 'Remove', Mandatory = $true)]
    [switch]$Remove,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)]
    [switch]$List,

    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')

if (-not (az account show --query id -o tsv 2>$null)) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$raw = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'
if ($null -eq $raw) {
    throw "bu-registry not found on $ApimName. Redeploy with the current template first."
}
$registry = @(ConvertFrom-ClaudeBuRegistry $raw)

$parentsRaw = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents'
if ($null -eq $parentsRaw) {
    throw "bu-parents not found on $ApimName. Redeploy with the current template first."
}
$parents = ConvertFrom-ClaudeBuParents $parentsRaw

function Show-Registry($units) {
    if (-not $units.Count) {
        Write-Host '  No business units defined.' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host ("  {0,-16} {1,-16} {2,-30} {3,18} {4,12}" -f 'Id', 'Parent', 'Entra group', 'Tokens/month', 'approx USD')
    Write-Host ('  ' + ('-' * 98)) -ForegroundColor DarkGray
    # Business units first, each followed by its teams, so the hierarchy reads
    # top-down rather than in registry order.
    $tops = @($units | Where-Object { -not $parents[$_.Id] })
    $ordered = @()
    foreach ($t in $tops) {
        $ordered += $t
        $ordered += @($units | Where-Object { $parents[$_.Id] -eq $t.Id })
    }
    # Anything whose parent is not itself in the registry still has to appear.
    $ordered += @($units | Where-Object { $ordered -notcontains $_ })

    foreach ($u in $ordered) {
        $usd = ConvertTo-ClaudeBuUsd -Tokens $u.TokensPerMonth -Model $Model -OutputShare $OutputShare
        $p = if ($parents[$u.Id]) { $parents[$u.Id] } else { '-' }
        $name = if ($parents[$u.Id]) { '  ' + $u.Id } else { $u.Id }
        Write-Host ("  {0,-16} {1,-16} {2,-30} {3,18:n0} {4,12}" -f $name, $p, $u.Group, $u.TokensPerMonth, $(if ($null -ne $usd) { '$' + ('{0:n0}' -f $usd) } else { '-' }))
    }
    Write-Host ''
    Write-Host '  An indented row is a team. Its spend is charged to it and to its parent.' -ForegroundColor DarkGray
    Write-Host '  Dollar figures are list price and exclude cached tokens. See docs/BUSINESS-UNITS.md.' -ForegroundColor DarkGray
}

if ($List) {
    Write-Host ''
    Write-Host ("Business units on {0}" -f $ApimName) -ForegroundColor Cyan
    Show-Registry $registry
    exit 0
}

Test-ClaudeBuId $Id
$existing = @($registry | Where-Object { $_.Id -eq $Id })
$before = $registry.Count

if ($Remove) {
    if (-not $existing.Count) { Write-Host "No business unit '$Id'. Nothing to remove." -ForegroundColor DarkGray; exit 0 }
    $registry = @($registry | Where-Object { $_.Id -ne $Id })
    $action = "removed (was $($existing[0].Group), $('{0:n0}' -f $existing[0].TokensPerMonth) tokens/month)"

    # A team pointing at a unit that no longer exists would look up a quota of
    # zero and quietly stop cascading. Promote those teams to top level and say
    # so, rather than leaving a dangling parent.
    $orphans = @($parents.Keys | Where-Object { $parents[$_] -eq $Id })
    $parents.Remove($Id)
    foreach ($o in $orphans) { $parents.Remove($o) }
}
else {
    if (-not $existing.Count -and -not $Group) {
        throw "Business unit '$Id' does not exist yet, so -Group is required to create it."
    }
    if (-not $existing.Count -and -not $PSBoundParameters.ContainsKey('MonthlyBudgetUsd')) {
        throw "Business unit '$Id' does not exist yet, so -MonthlyBudgetUsd is required to create it."
    }

    $targetGroup = if ($Group) { $Group } else { $existing[0].Group }
    if ($targetGroup -match '[,:]') { throw "An Entra group name cannot contain a comma or a colon: '$targetGroup'." }

    # Verify the group exists before writing the registry. A typo here is
    # invisible afterwards: the unit is created, the sync resolves it to nobody,
    # and the report shows a business unit with a budget and zero members, which
    # reads as "nobody has used it yet" rather than "this group does not exist".
    if ($Group -and -not $SkipGroupCheck) {
        $gid = az ad group show --group $Group --query id -o tsv 2>$null
        if (-not $gid) {
            $hint = ''
            # Offer near matches rather than only refusing. The usual mistake is
            # a prefix people half-remember.
            $stem = ($Group -split '[- ]')[0]
            if ($stem.Length -ge 3) {
                $tok = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
                if ($tok) {
                    try {
                        $u = "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$stem')&`$select=displayName&`$top=10"
                        $near = @((Invoke-RestMethod -Uri $u -Headers @{ Authorization = "Bearer $tok" }).value.displayName)
                        if ($near.Count) { $hint = " Groups starting '$stem': " + ($near -join ', ') + "." }
                    }
                    catch { }
                }
            }
            throw ("No Entra group '$Group'. Nothing has been written - a business unit pointing at a group " +
                   "that does not exist resolves to zero members and reads as unused rather than broken." + $hint +
                   " Pass -SkipGroupCheck to register it anyway, for a group that does not exist yet.")
        }
    }

    if ($PSBoundParameters.ContainsKey('Parent')) {
        if ([string]::IsNullOrWhiteSpace($Parent)) {
            $parents.Remove($Id)
            $parentAction = 'no parent - this is now a top-level business unit'
        }
        else {
            Test-ClaudeBuId $Parent
            if ($Parent -eq $Id) { throw "A business unit cannot be its own parent." }
            if (-not @($registry | Where-Object { $_.Id -eq $Parent }).Count) {
                throw ("There is no business unit '$Parent' to be a parent. Create it first, then set -Parent on '$Id'. " +
                       "Defined: " + (($registry.Id | Sort-Object) -join ', ') + ".")
            }
            $parents[$Id] = $Parent
            # Depth and cycles are refused when written, because the policy
            # charges a request to its unit and that unit's parent and has no
            # loop - a third level would silently go uncharged. See ADR-0008.
            Test-ClaudeBuDepth -Parents $parents
            $parentAction = "team of '$Parent'"
        }
    }

    if ($PSBoundParameters.ContainsKey('MonthlyBudgetUsd')) {
        $conv = ConvertTo-ClaudeBuTokens -Usd $MonthlyBudgetUsd -Model $Model -OutputShare $OutputShare
        $tokens = $conv.TokensPerMonth
    }
    else {
        $conv = $null
        $tokens = $existing[0].TokensPerMonth
    }

    if ($existing.Count) {
        $was = "was $($existing[0].Group), $('{0:n0}' -f $existing[0].TokensPerMonth) tokens/month"
        $registry = @($registry | Where-Object { $_.Id -ne $Id })
        $action = "updated ($was)"
    }
    else {
        $action = 'created'
    }

    $registry += [pscustomobject]@{ Id = $Id; Group = $targetGroup; TokensPerMonth = $tokens }
}

$value = ConvertTo-ClaudeBuRegistry $registry

# The write is only safe because the registry was read first. Assert that every
# other business unit survived rather than trusting the string building - an
# earlier version of this pattern emptied the entitlement allow list.
foreach ($u in ($registry | Where-Object { $_.Id -ne $Id })) {
    if ($value -notmatch [regex]::Escape(",$($u.Id)=")) {
        throw "Refusing to write: business unit '$($u.Id)' would be lost. Nothing has been changed."
    }
}

Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry' -Value $value

$parentValue = ConvertTo-ClaudeBuParents $parents
if ($parentValue -ne $parentsRaw) {
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents' -Value $parentValue
}

Write-Host ''
Write-Host ("  {0} {1}" -f $Id, $action) -ForegroundColor Green
if ($parentAction) { Write-Host ("  {0}" -f $parentAction) -ForegroundColor Green }
if ($orphans -and $orphans.Count) {
    Write-Host ("  {0} team(s) promoted to top level: {1}" -f $orphans.Count, ($orphans -join ', ')) -ForegroundColor Yellow
    Write-Host "  They keep their own budgets and are no longer charged to a parent." -ForegroundColor DarkGray
}
if ($conv) {
    Write-Host ("  `${0:n0}/month -> {1:n0} tokens, at a blended `${2}/M for {3} assuming {4:p0} output." -f `
        $conv.Usd, $conv.TokensPerMonth, $conv.BlendedUsdPerM, $conv.Model, $conv.OutputShare) -ForegroundColor DarkGray
    Write-Host ("  List price, price book {0}. The quota counter excludes cached tokens." -f $conv.PriceBookDate) -ForegroundColor DarkGray
}
Write-Host ("  {0} business unit(s) before, {1} after. Others untouched." -f $before, $registry.Count) -ForegroundColor DarkGray

if (-not $Remove -and $Group) {
    Write-Host ''
    Write-Host "  Membership comes from the Entra group. Run the sync to pick it up:" -ForegroundColor DarkGray
    Write-Host "    ./scripts/Sync-ClaudeAccess.ps1 -ApimName $ApimName -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
}
