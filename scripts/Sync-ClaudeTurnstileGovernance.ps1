<#
.SYNOPSIS
    Keeps Turnstile's organizations, departments and budgets in step with the gateway.

.DESCRIPTION
    The gateway is where business units, teams and tiers are enforced (docs/TURNSTILE.md).
    This makes them visible and manageable in Turnstile, reading the connection that
    Connect-ClaudeTurnstile.ps1 stored rather than any constant.

    -Direction ToTurnstile (default)
        Business units become Turnstile organizations, their Entra groups travel as
        external references, teams become departments under them, and every unit also
        gets a department for the people mapped to it directly. When budgets are
        authored in the gateway (the connection's budgetAuthority), unit and team monthly
        budgets are set in Turnstile too. Tiers travel on every usage row as Turnstile's
        project, so spend can be broken down by tier.

        Person budgets are off unless the connection turns them on. Turnstile treats a
        person's budget as an allocation that must fit inside the department's - measured:
        it refused a department budget "lower than its 15000000 allocated child tokens" -
        while a tier is a ceiling each person may reach, not a share of a pot. Mirroring
        tiers as person budgets therefore blocks ordinary unit budgets once a department has
        more than a handful of people. With personBudgets on, each discovered person gets
        their tier's daily quota times the days in the month, for departments where that fits.

    -Direction FromTurnstile
        For a connection whose budgets are authored in Turnstile. Unit and team budgets
        changed on Turnstile's budget page are written back to the gateway's registry and
        enforced on the next request. Nothing is written without -Apply. Structure is never
        taken from Turnstile: a unit needs an Entra group, and groups belong to the gateway.

    Authentication is a Microsoft Entra access token for the Turnstile API: your own
    `az login` interactively, or a workload identity on a schedule. Turnstile accepts it
    only from its pinned tenant and only with its admin app role.

.PARAMETER Period
    The budget month, yyyy-MM. Defaults to the current UTC month.

.PARAMETER AccessToken
    A token already obtained by a workload identity. Omit to use `az`.

.EXAMPLE
    ./scripts/Sync-ClaudeTurnstileGovernance.ps1

.EXAMPLE
    ./scripts/Sync-ClaudeTurnstileGovernance.ps1 -WhatIf

.EXAMPLE
    ./scripts/Sync-ClaudeTurnstileGovernance.ps1 -Direction FromTurnstile -Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('ToTurnstile', 'FromTurnstile')][string]$Direction = 'ToTurnstile',
    [ValidatePattern('^\d{4}-(0[1-9]|1[0-2])$')][string]$Period = [datetime]::UtcNow.ToString('yyyy-MM'),
    [switch]$Apply,
    [switch]$WhatIf,
    [switch]$SkipPersonBudgets,
    [ValidateRange(1, 100)][int]$WarningThresholdPercent = 80,
    [string]$TurnstileUrl,
    [string]$Scope,
    [string]$AccessToken,
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$integration = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)
$url = ([string](Resolve-ClaudeTurnstileSetting $TurnstileUrl $integration 'url' 'TurnstileUrl')).TrimEnd('/')
$scope = [string](Resolve-ClaudeTurnstileSetting $Scope $integration 'scope' 'Scope')
$authority = [string](Resolve-ClaudeTurnstileSetting $null $integration 'budgetAuthority' 'BudgetAuthority' 'Gateway')
$personBudgets = (-not $SkipPersonBudgets) -and [bool](Resolve-ClaudeTurnstileSetting $null $integration 'personBudgets' 'PersonBudgets' $false)

$token = if ($AccessToken) { $AccessToken } else { (az account get-access-token --scope $scope --query accessToken -o tsv 2>$null) }
if (-not $token) { throw "Could not get a token for $scope. Your account must hold the Turnstile admin role (its admin group), or pass -AccessToken from a workload identity that does." }

function Invoke-Turnstile([string]$Method, [string]$Path, $Body = $null) {
    $request = @{ Method = $Method; Uri = "$url$Path"; Headers = @{ Authorization = "Bearer $token" }; ContentType = 'application/json' }
    if ($null -ne $Body) { $request.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 8 -Compress)) }
    Invoke-RestMethod @request
}

function Get-TurnstileErrorDetail($ErrorRecord) {
    $detail = $ErrorRecord.ErrorDetails.Message
    if (-not $detail) { return $ErrorRecord.Exception.Message }
    try { $d = ($detail | ConvertFrom-Json).detail; if ($d -is [array]) { return ($d -join '; ') }; return [string]$d } catch { return $detail }
}

$registry = @(ConvertFrom-ClaudeBuRegistry (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'))
$parents = ConvertFrom-ClaudeBuParents (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents')
if (-not $parents) { $parents = [ordered]@{} }
$unassignedMode = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-unassigned'
if (-not $unassignedMode) { $unassignedMode = 'allow' }

if ($Direction -eq 'FromTurnstile') {
    if ($authority -ne 'Turnstile') {
        throw ('This connection authors budgets in the gateway, so Turnstile''s budgets are a mirror and are not read back. ' +
            'To edit budgets in Turnstile instead: ./scripts/Connect-ClaudeTurnstile.ps1 -BudgetAuthority Turnstile')
    }
    $overview = Invoke-Turnstile GET "/api/v1/budgets?period=$Period"
    $changes = Compare-ClaudeTurnstileBudgets -Registry $registry -Parents $parents -TurnstileItems @($overview.items)
    $toApply = @($changes | Where-Object Apply)
    foreach ($c in $changes) {
        Write-Host ("  {0,-14} {1,-12} {2,14:n0} -> {3,14}  {4}" -f $c.Id, $c.ScopeType, $c.Was, $(if ($null -eq $c.Now) { 'none' } else { '{0:n0}' -f $c.Now }), $c.Reason)
    }
    if (-not $toApply.Count) { Write-Host '  The gateway already matches Turnstile.'; return [pscustomobject]@{ Direction = $Direction; Period = $Period; Changes = 0; Applied = 0 } }
    if (-not $Apply) {
        Write-Host "  Nothing written. Pass -Apply to write $($toApply.Count) change(s) to the gateway."
        return [pscustomobject]@{ Direction = $Direction; Period = $Period; Changes = $toApply.Count; Applied = 0 }
    }
    foreach ($c in $toApply) {
        foreach ($u in $registry) { if ([string]$u.Id -eq $c.Id) { $u.TokensPerMonth = [long]$c.Now } }
    }
    $value = ConvertTo-ClaudeBuRegistry $registry
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry' -Value $value
    $readBack = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'
    if ($readBack -ne $value) { throw 'The registry did not read back as written; the change may not be in effect.' }
    Write-Host "  Wrote $($toApply.Count) budget(s) to the gateway. In effect on the next request - named values need no redeploy."
    return [pscustomobject]@{ Direction = $Direction; Period = $Period; Changes = $toApply.Count; Applied = $toApply.Count }
}

# --- ToTurnstile ---------------------------------------------------------------------------
$catalog = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents -IncludeUnassigned:($unassignedMode -ne 'deny')
$plan = if ($authority -eq 'Gateway') { Get-ClaudeTurnstileBudgetPlan -Registry $registry -Parents $parents } else { @() }
if ($WhatIf) {
    return [pscustomobject][ordered]@{
        Direction     = $Direction
        Turnstile     = $url
        Organizations = @($catalog.organizations | ForEach-Object { $_.id })
        Departments   = @($catalog.departments | ForEach-Object { "$($_.id) <- $($_.parent_id)" })
        Budgets       = @($plan | ForEach-Object { "$($_.ScopeType)/$($_.ScopeId) = $($_.TokenLimit)" })
        Authority     = $authority
        PersonBudgets = $personBudgets
    }
}

$stored = Invoke-Turnstile PUT '/api/v1/enterprise-catalog' $catalog

$budgetResults = New-Object System.Collections.Generic.List[string]
foreach ($b in $plan) {
    try {
        Invoke-Turnstile PUT "/api/v1/budgets/$($b.ScopeType)/$($b.ScopeId)?period=$Period" @{ token_limit = [long]$b.TokenLimit; warning_threshold_percent = $WarningThresholdPercent } | Out-Null
        $budgetResults.Add("set $($b.ScopeType)/$($b.ScopeId)")
    }
    catch {
        # Turnstile refuses a department budget larger than its organization's, and the
        # gateway allows teams to be oversubscribed against a parent that caps them all
        # (ADR-0008). Report it rather than stop: the enforcement is the gateway's.
        $budgetResults.Add("refused $($b.ScopeType)/$($b.ScopeId): $(Get-TurnstileErrorDetail $_)")
    }
}

# Person budgets from tiers, for people Turnstile has discovered from usage.
$personResults = New-Object System.Collections.Generic.List[string]
if ($personBudgets) {
    $workspace = Get-ClaudeGatewayWorkspaceId -ResourceGroup $ResourceGroup -ApimName $ApimName
    $tierRows = @(Invoke-ClaudeLedgerQuery -WorkspaceResourceId $workspace -Kql (Get-ClaudeTurnstileTierQuery))
    $tierOf = @{}
    foreach ($r in $tierRows) { $tierOf[[string]$r.user] = [string]$r.tier }
    $monthly = @{}
    foreach ($t in @($tierOf.Values | Sort-Object -Unique)) {
        $daily = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id "quota-$t"
        if ("$daily" -match '^\d+$' -and [long]$daily -gt 0) { $monthly[$t] = Get-ClaudeTierMonthlyTokens -DailyQuota ([long]$daily) -Period $Period }
    }
    foreach ($dept in @($catalog.departments)) {
        $people = New-Object System.Collections.Generic.List[string]
        $offset = 0
        do {
            $page = Invoke-Turnstile GET "/api/v1/budgets/users?period=$Period&department_id=$([uri]::EscapeDataString($dept.id))&limit=200&offset=$offset"
            foreach ($i in @($page.items)) { $people.Add([string]$i.scope_id) }
            $offset += 200
        } while ($offset -lt [int]$page.total)
        foreach ($group in @($people | Group-Object { $tierOf[$_] })) {
            $tier = [string]$group.Name
            if (-not $tier -or -not $monthly.ContainsKey($tier)) { continue }
            $ids = @($group.Group)
            for ($start = 0; $start -lt $ids.Count; $start += 500) {
                $chunk = $ids[$start..([Math]::Min($ids.Count, $start + 500) - 1)]
                try {
                    Invoke-Turnstile POST "/api/v1/budgets/users/bulk?period=$Period" @{
                        department_id = $dept.id; selection = 'ids'; user_ids = @($chunk); allocation_mode = 'fixed'
                        token_limit = [long]$monthly[$tier]; warning_threshold_percent = $WarningThresholdPercent
                    } | Out-Null
                    $personResults.Add("$($chunk.Count) $tier in $($dept.id)")
                }
                catch { $personResults.Add("refused $tier in $($dept.id): $(Get-TurnstileErrorDetail $_)") }
            }
        }
    }
}

[pscustomobject][ordered]@{
    Direction      = $Direction
    Turnstile      = $url
    Catalog        = "$($stored.source): $(@($stored.organizations).Count) organizations, $(@($stored.departments).Count) departments"
    BudgetAuthority = $authority
    Budgets        = $budgetResults.ToArray()
    PersonBudgets  = $(if ($personBudgets) { $personResults.ToArray() } else { 'off' })
    Period         = $Period
}
