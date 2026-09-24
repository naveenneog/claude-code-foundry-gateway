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
        For a connection whose budgets are authored in Turnstile (budgetAuthority). Unit and
        team budgets changed on Turnstile's budget page are written back to the gateway's
        registry and enforced on the next request. Structure stays the gateway's.

        For a connection whose governance is authored in Turnstile (governanceAuthority),
        everything comes from Turnstile: business units, teams, their Entra groups, budgets
        and tiers. Turnstile first rolls the previous month's budgets into the current month
        if its own timer has not yet, so the start of a month never reads as every budget
        removed. Groups the gateway cannot confirm exist are not applied, and tier
        membership is refreshed only where group members can be read (docs/TURNSTILE.md).
        The apply job runs this after every save in Turnstile.

        Nothing is written without -Apply.

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
    # Push the gateway's state into Turnstile even when Turnstile authors governance: used once,
    # by Connect-ClaudeTurnstile.ps1, when governance moves to Turnstile.
    [switch]$Seed,
    [ValidateRange(1, 100)][int]$WarningThresholdPercent = 80,
    [string]$TurnstileUrl,
    [string]$Scope,
    [string]$AccessToken,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileApply.ps1')

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
$governanceAuthority = [string](Resolve-ClaudeTurnstileSetting $null $integration 'governanceAuthority' 'GovernanceAuthority' 'Gateway')

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


if ($Direction -eq 'ToTurnstile' -and $governanceAuthority -eq 'Turnstile' -and -not $Seed) {
    throw ('Governance is authored in Turnstile, so pushing the gateway''s state would overwrite what was saved there. ' +
        'Apply Turnstile to the gateway instead: -Direction FromTurnstile -Apply')
}

if ($Direction -eq 'FromTurnstile' -and $governanceAuthority -eq 'Turnstile') {
    # Everything from Turnstile: business units, teams, their Entra groups, budgets and tiers.
    # The month first: a new month has no budgets until Turnstile rolls the previous month's
    # in, and reading it before then would remove every budget. Prepare does that, once.
    try { $prepared = Invoke-Turnstile POST '/api/v1/gateway-governance/prepare' }
    catch {
        # 405, not 404, when the route is missing: Turnstile's page fallback owns the path.
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in 404, 405) {
            throw 'This Turnstile has no gateway governance endpoints. Deploy the Turnstile version with the Gateway governance page.'
        }
        throw
    }
    if ($PSBoundParameters.ContainsKey('Period') -and $Period -ne [string]$prepared.period) {
        throw "Governance authored in Turnstile applies Turnstile's current month, $($prepared.period); -Period $Period cannot be applied."
    }
    $Period = [string]$prepared.period
    $catalogDoc = Invoke-Turnstile GET '/api/v1/enterprise-catalog'
    $budgetDoc = Invoke-Turnstile GET "/api/v1/budgets?period=$Period"
    $tierDoc = Invoke-Turnstile GET '/api/v1/gateway-tiers'
    $readGovernance = {
        $freshMonth = Invoke-Turnstile POST '/api/v1/gateway-governance/prepare'
        $freshCatalog = Invoke-Turnstile GET '/api/v1/enterprise-catalog'
        $freshBudgets = Invoke-Turnstile GET "/api/v1/budgets?period=$($freshMonth.period)"
        $freshTiers = Invoke-Turnstile GET '/api/v1/gateway-tiers'
        [pscustomobject]@{
            Catalog = $freshCatalog; BudgetItems = @($freshBudgets.items); Tiers = @($freshTiers.items)
            TierUpdatedAt = $freshTiers.updated_at; BudgetPeriod = [string]$freshMonth.period
        }
    }
    $result = Invoke-ClaudeGatewayGovernanceApply -Catalog $catalogDoc -BudgetItems @($budgetDoc.items) -Tiers @($tierDoc.items) `
        -TierUpdatedAt $tierDoc.updated_at -BudgetPeriod $Period -ReadGovernance $readGovernance `
        -ResourceGroup $ResourceGroup -ApimName $ApimName -ScriptRoot $PSScriptRoot -Apply:$Apply
    foreach ($c in $result.Changes) { Write-Host "  $c" }
    foreach ($p in $result.Problems) { Write-Host "  not applied - $p" }
    Write-Host "  Freshness: $($result.Freshness)"
    foreach ($read in @($result.SourceReads)) { Write-Host ("  Source revisions: " + ($read | ConvertTo-Json -Depth 5 -Compress)) }
    if (-not @($result.Changes).Count -and @($result.Problems).Count) { Write-Host '  No named values written; see the reported problems.' }
    elseif (-not @($result.Changes).Count) { Write-Host '  The gateway already matches Turnstile.' }
    elseif (-not $Apply) { Write-Host "  Nothing written. Pass -Apply to write $(@($result.Changes).Count) change(s) to the gateway." }
    else { Write-Host "  Wrote $($result.Applied) named value(s). In effect on the next request." }
    Write-Host "  Membership: $($result.Membership)"
    return $result
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
$modes = ConvertFrom-ClaudeBuModes (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-modes')
$catalog = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents -Modes $modes -IncludeUnassigned:($unassignedMode -ne 'deny')
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

# Tiers too, so Turnstile's Gateway governance page shows the gateway's own limits. Their groups
# are the ones the installer recorded, or the access sync's defaults.
$standardGroup = [string](& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') StandardGroup 3>$null)
$premiumGroup = [string](& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') PremiumGroup 3>$null)
if (-not $standardGroup) { $standardGroup = 'claude-code-standard' }
if (-not $premiumGroup) { $premiumGroup = 'claude-code-premium' }
$tierDocument = Get-ClaudeGatewayTierDocument -ResourceGroup $ResourceGroup -ApimName $ApimName -StandardGroup $standardGroup -PremiumGroup $premiumGroup
$tierResult = 'none on the gateway'
if (@($tierDocument.tiers).Count) {
    try { $tierResult = "$(@((Invoke-Turnstile PUT '/api/v1/gateway-tiers' $tierDocument).items).Count) tier(s)" }
    catch { $tierResult = "not sent: $(Get-TurnstileErrorDetail $_)" }
}

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
    Tiers          = $tierResult
    BudgetAuthority = $authority
    Budgets        = $budgetResults.ToArray()
    PersonBudgets  = $(if ($personBudgets) { $personResults.ToArray() } else { 'off' })
    Period         = $Period
}
