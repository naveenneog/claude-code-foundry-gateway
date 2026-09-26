<#
.SYNOPSIS
    Adds or removes one developer.

.DESCRIPTION
    The common admin action, and the one that had no command: entitlement was
    either the bulk sync from Entra groups or a CSV import.

    It edits the **Entra group**, not the gateway. That distinction is the whole
    reason this script exists rather than a one-line named value write:
    Sync-ClaudeAccess.ps1 rebuilds `allow-standard` and `allow-premium` from
    group membership every time it runs, so a developer added straight to the
    named value works until the next sync and then silently stops. Editing the
    group is the durable change; the sync just publishes it.

    Membership is the only thing this touches. Tier limits are
    Set-ClaudeTier.ps1, personal budgets are Set-ClaudeBudget.ps1, and chargeback
    is the business unit - see ADR-0008 for why those are separate axes.

    This remains available when Turnstile owns governance. Its apply reads
    membership from Entra; it never edits the groups' members, so it does not
    undo these changes. Use the tier group names configured for the gateway.
    Turnstile owns group-to-unit/tier mappings, not the Entra membership itself.

.PARAMETER User
    UPN, email or object id. Guests are found by the address they were invited
    with as well as by their directory UPN.

.PARAMETER Tier
    standard or premium. Omit with -Remove to take them out of both.

.PARAMETER BusinessUnit
    Also put them in this business unit's group, so their spend has an owner.

.PARAMETER Sync
    Publish to the gateway afterwards rather than printing the command.

.EXAMPLE
    ./scripts/Set-ClaudeDeveloper.ps1 -User amara@contoso.com -Tier standard -Sync
    ./scripts/Set-ClaudeDeveloper.ps1 -User amara@contoso.com -Tier premium -BusinessUnit mcaps
    ./scripts/Set-ClaudeDeveloper.ps1 -User amara@contoso.com -Remove -Sync
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$User,
    [ValidateSet('standard', 'premium')][string]$Tier,
    [string]$BusinessUnit,
    [switch]$Remove,
    [switch]$Sync,
    [string]$StandardGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') StandardGroup 3>$null),
    [string]$PremiumGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') PremiumGroup 3>$null),
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')

if (-not $Remove -and -not $Tier) { throw "Say which tier: -Tier standard or -Tier premium. Use -Remove to take someone out." }
if ($Remove -or $BusinessUnit -or $Sync) {
    if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
    if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup }
}

function Select-ClaudeDeveloperTierGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Tier
    )
    $rows = @()
    try {
        $rows = @(az ad group list --filter "startswith(displayName,'claude')" -o json 2>$null | ConvertFrom-Json)
    }
    catch { $rows = @() }
    $options = foreach ($row in @($rows | Where-Object { $_.securityEnabled -and $_.displayName -match $Tier } | Select-Object -First 25)) {
        New-ClaudeChoiceOption -Value ([string]$row.displayName) -Label ([string]$row.displayName) `
            -Detail ("object id: {0}" -f $row.id) -Recommended:($row.displayName -eq "claude-code-$Tier") `
            -Reason 'matches the historical gateway tier-group naming convention'
    }
    Select-ClaudeChoice -Parameter ("{0}Group" -f ((Get-Culture).TextInfo.ToTitleCase($Tier))) `
        -Question "Which Entra group is the $Tier Claude tier?" `
        -Options @($options) `
        -WhereToFind @(
            'Install-ClaudeGateway.ps1 records standardGroup and premiumGroup in onboarding/claude-gateway.json'
            'Azure portal: Microsoft Entra ID > Groups > the recorded tier group > Overview'
            'Pass -StandardGroup and -PremiumGroup for automation'
        ) `
        -NoneMessage "No recorded or discoverable $Tier tier group was found."
}

if (-not $StandardGroup -or -not $PremiumGroup) {
    if (-not $StandardGroup) {
        $StandardGroup = Select-ClaudeDeveloperTierGroup -Tier standard
    }
    if (-not $PremiumGroup) {
        $PremiumGroup = Select-ClaudeDeveloperTierGroup -Tier premium
    }
}

function Get-GraphToken {
    $t = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
    if (-not $t) { throw "Could not acquire a Microsoft Graph token. Run: az login" }
    return $t.Trim()
}
$headers = @{ Authorization = "Bearer $(Get-GraphToken)"; 'Content-Type' = 'application/json' }

# Resolve the person. A guest's UPN is not their email - measured in this
# tenant, amara@contoso.com is amara_contoso.com#EXT#@tenant.onmicrosoft.com -
# so searching only by UPN finds nobody and reads as "this person does not
# exist" rather than "you gave me their email".
function Resolve-User([string]$q) {
    # Every query value is URL-encoded. A guest's UPN contains #EXT#, and '#'
    # starts a fragment - so an unencoded filter is truncated at the hash before
    # it ever leaves the client, and Graph rejects it as an unterminated string
    # literal. The error names the filter, not the URL, which sends you looking
    # in the wrong place.
    $enc = [uri]::EscapeDataString($q)

    if ($q -match '^[0-9a-f]{8}-[0-9a-f]{4}-') {
        try { return Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$enc`?`$select=id,displayName,userPrincipalName,mail" -Headers $headers } catch { }
    }
    foreach ($field in @('mail', 'userPrincipalName')) {
        $u = "https://graph.microsoft.com/v1.0/users?`$filter=$field%20eq%20'$enc'&`$select=id,displayName,userPrincipalName,mail"
        $r = @((Invoke-RestMethod -Uri $u -Headers $headers).value)
        if ($r.Count -eq 1) { return $r[0] }
        if ($r.Count -gt 1) { throw "'$q' matches $($r.Count) accounts. Pass the object id." }
    }
    # Guests are commonly stored with the email mangled into the UPN.
    $stem = [uri]::EscapeDataString((($q -split '@')[0] -split '#')[0])
    $u = "https://graph.microsoft.com/v1.0/users?`$filter=startswith(userPrincipalName,'$stem')&`$select=id,displayName,userPrincipalName,mail&`$top=5"
    $r = @((Invoke-RestMethod -Uri $u -Headers $headers).value)
    if ($r.Count -eq 1) { return $r[0] }
    if ($r.Count -gt 1) {
        throw ("'$q' matches several accounts: " + (($r.userPrincipalName) -join ', ') + ". Pass the object id.")
    }
    throw "No account matches '$q' by object id, mail or user principal name. Guests are often stored as name_domain.com#EXT#@tenant.onmicrosoft.com - try their object id."
}

function Get-GroupId([string]$name) {
    $id = az ad group show --group $name --query id -o tsv 2>$null
    if (-not $id) { throw "No Entra group '$name'." }
    return $id.Trim()
}

function Test-Member([string]$groupId, [string]$userId) {
    # Direct membership only, via memberOf. The obvious call, checkMemberObjects,
    # answers transitively - and with teams nested inside business units and
    # business units nested inside tier groups, that is a different question.
    # Measured: a developer in claude-bu-gbb reported as a member of
    # claude-code-standard because gbb is nested in it, so removing them failed
    # with Request_ResourceNotFound - you can only remove a direct member.
    $r = Invoke-RestMethod -Headers $headers `
        -Uri "https://graph.microsoft.com/v1.0/users/$userId/memberOf?`$select=id&`$top=999"
    return @($r.value.id) -contains $groupId
}

function Set-Membership([string]$groupId, [string]$groupName, [string]$userId, [bool]$want) {
    $is = Test-Member $groupId $userId
    if ($is -eq $want) {
        Write-Host ("    {0,-28} already {1}" -f $groupName, $(if ($want) { 'a member' } else { 'not a member' })) -ForegroundColor DarkGray
        return $false
    }
    if ($want) {
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Headers $headers -Body $body -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" | Out-Null
        Write-Host ("    {0,-28} added" -f $groupName) -ForegroundColor Green
    }
    else {
        Invoke-RestMethod -Method Delete -Headers $headers -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/$userId/`$ref" | Out-Null
        Write-Host ("    {0,-28} removed" -f $groupName) -ForegroundColor Yellow
    }
    return $true
}

$person = Resolve-User $User

Write-Host ''
Write-Host ("{0}" -f $person.displayName) -ForegroundColor Cyan
Write-Host ("  {0}" -f $person.userPrincipalName) -ForegroundColor DarkGray
Write-Host ("  {0}" -f $person.id) -ForegroundColor DarkGray
Write-Host ''

$changed = $false

if ($Remove) {
    Write-Host '  Entitlement' -ForegroundColor Cyan
    foreach ($g in @($StandardGroup, $PremiumGroup)) {
        $changed = (Set-Membership (Get-GroupId $g) $g $person.id $false) -or $changed
    }

    # Removing entitlement but leaving them in a business unit group leaves a
    # member on a budget who can no longer call the gateway - which reads as a
    # team that has stopped working rather than as an offboarding that was only
    # half done. Every unit is cleared, not just a named one.
    . (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
    if ($ApimName) {
        $registry = @(ConvertFrom-ClaudeBuRegistry (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'))
        $units = if ($BusinessUnit) { @($registry | Where-Object { $_.Id -eq $BusinessUnit }) } else { $registry }
        if ($units.Count) {
            Write-Host ''
            Write-Host '  Business unit' -ForegroundColor Cyan
            foreach ($u in $units) {
                try { $changed = (Set-Membership (Get-GroupId $u.Group) $u.Group $person.id $false) -or $changed }
                catch { Write-Warning "Could not check $($u.Group): $($_.Exception.Message)" }
            }
        }
    }
}
else {
    $wanted = if ($Tier -eq 'premium') { $PremiumGroup } else { $StandardGroup }
    $other  = if ($Tier -eq 'premium') { $StandardGroup } else { $PremiumGroup }

    Write-Host '  Entitlement' -ForegroundColor Cyan
    $changed = (Set-Membership (Get-GroupId $wanted) $wanted $person.id $true) -or $changed
    # Leaving them in both is not an error - the policy checks premium first -
    # but it makes the lists unreadable and the tier hard to predict from the
    # portal, so it is undone rather than warned about.
    $changed = (Set-Membership (Get-GroupId $other) $other $person.id $false) -or $changed
}

if ($BusinessUnit) {
    . (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')

    $registry = @(ConvertFrom-ClaudeBuRegistry (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'))
    $unit = @($registry | Where-Object { $_.Id -eq $BusinessUnit })
    if (-not $unit.Count) {
        throw ("No business unit '$BusinessUnit'. Defined: " + (($registry.Id | Sort-Object) -join ', ') + ".")
    }

    Write-Host ''
    Write-Host '  Business unit' -ForegroundColor Cyan
    $changed = (Set-Membership (Get-GroupId $unit[0].Group) $unit[0].Group $person.id $true) -or $changed
}

Write-Host ''
if (-not $changed) {
    Write-Host '  Nothing to change.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# The group edit is the durable part; the gateway still reads named values, and
# they are only rebuilt when the sync runs.
if ($Sync) {
    Write-Host '  Publishing to the gateway' -ForegroundColor Cyan
    $a = @{ ResourceGroup = $ResourceGroup }
    if ($ApimName) { $a.ApimName = $ApimName }
    & (Join-Path $PSScriptRoot 'Sync-ClaudeAccess.ps1') @a
}
else {
    Write-Host '  Entra is updated. The gateway reads named values, which the sync rebuilds:' -ForegroundColor Yellow
    Write-Host ("    ./scripts/Sync-ClaudeAccess.ps1 -ResourceGroup {0}" -f $ResourceGroup) -ForegroundColor Cyan
    Write-Host '  Until then the change is in the directory but not at the gateway. -Sync does both.' -ForegroundColor DarkGray
}
Write-Host ''
