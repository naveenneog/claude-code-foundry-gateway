<#
.SYNOPSIS
    Moves a gateway that serves entitlement from named values to the Cosmos projection, through the update
    flow (ADR-0054): the facts its plan shows (previous values, readiness, resources, cost) and its apply.
    Dot-sourcing this file makes no Azure calls.
#>

function Test-ClaudeMigrationGuid([AllowEmptyString()][string]$Value) {
    return ([string]$Value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
}

# allow-standard and allow-premium hold object ids between commas, with sentinels (Sync-ClaudeAccess.ps1).
function ConvertFrom-ClaudeEntitlementList([AllowEmptyString()][string]$Value) {
    return @(([string]$Value -split ',') | ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { Test-ClaudeMigrationGuid $_ } | Select-Object -Unique)
}

# entitlement-groups (ADR-0054): 'standard=<object id>,premium=<object id>|none'. Only object ids, so the
# value passes az.cmd and cmd.exe unchanged; names are read back from Graph.
function ConvertFrom-ClaudeEntitlementGroups([AllowEmptyString()][string]$Value) {
    $result = @{}
    foreach ($pair in ([string]$Value -split ',')) {
        if ($pair -match '^\s*(standard|premium)=([0-9a-fA-F-]{36}|none)\s*$') {
            $id = $Matches[2].ToLowerInvariant()
            if ($id -eq 'none' -or (Test-ClaudeMigrationGuid $id)) { $result[$Matches[1]] = $id }
        }
    }
    return $result
}

function ConvertTo-ClaudeEntitlementGroups([Parameter(Mandatory)][string]$StandardId, [AllowEmptyString()][string]$PremiumId) {
    if (-not (Test-ClaudeMigrationGuid $StandardId)) { throw "entitlement-groups needs the standard group's object id, not '$StandardId'." }
    $premium = if ($PremiumId) { $PremiumId } else { 'none' }
    if ($premium -ne 'none' -and -not (Test-ClaudeMigrationGuid $premium)) { throw "entitlement-groups needs the premium group's object id or none, not '$PremiumId'." }
    return "standard=$($StandardId.ToLowerInvariant()),premium=$($premium.ToLowerInvariant())"
}

# The first candidate that Graph finds wins. A candidate 'none' says the tier has no group.
function Resolve-ClaudeMigrationGroup {
    param([Parameter(Mandatory)][string]$Tier, [object[]]$Candidates, [Parameter(Mandatory)][scriptblock]$FindGroup)
    foreach ($candidate in $Candidates) {
        if (-not $candidate.Value) { continue }
        if ($candidate.Value -eq 'none') {
            return [pscustomobject]@{ Tier = $Tier; Name = ''; Id = ''; Source = $candidate.Source; Found = $false; Absent = $true; Members = @() }
        }
        $group = & $FindGroup $candidate.Value
        if ($group -and $group.Id) {
            return [pscustomobject]@{ Tier = $Tier; Name = [string]$group.Name; Id = ([string]$group.Id).ToLowerInvariant(); Source = $candidate.Source; Found = $true; Absent = $false
                Members = @(@($group.Members) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique) }
        }
    }
    return [pscustomobject]@{ Tier = $Tier; Name = ''; Id = ''; Source = ''; Found = $false; Absent = $false; Members = @() }
}

# The runner's transfer on this branch sends one 4,900-character chunk per exec, one at a time, 6.3 s each
# (measured 2026-10-06), and a snapshot takes about 127 bytes a record (63,150,738 bytes for 500,000, measured
# 2026-10-06). Send-RunnerFile refuses a transfer that cannot end inside the snapshot's 2-hour apply-by time.
function Get-ClaudeMigrationTransferMinutes([int]$Developers) {
    $chars = [Math]::Ceiling([Math]::Max(1, $Developers) * 127 * 4 / 3)
    return [int][Math]::Ceiling(([Math]::Ceiling($chars / 4900) + 2) * 6.3 / 60)
}

function ConvertTo-ClaudeMigrationCheck($Check) {
    $name = if ($Check.PSObject.Properties['Name']) { [string]$Check.Name } else { [string]$Check.Check }
    $remedy = if ($Check.PSObject.Properties['Remedy'] -and $Check.Remedy -and $Check.Remedy -ne 'None') { [string]$Check.Remedy } else { '' }
    [pscustomobject]@{ Name = $name; Result = [string]$Check.Result; Remedy = $remedy; Evidence = [string]$Check.Evidence }
}

function Get-ClaudeEntitlementMigrationFacts {
    param(
        [Parameter(Mandatory)]$Discovery,
        $Record,
        [string]$StandardGroup,
        [string]$PremiumGroup,
        [string]$NamePrefix,
        [AllowEmptyString()][ValidateSet('', 'public', 'private')][string]$ResolverInboundAccess = '',
        [switch]$KeepNamedValues,
        # Test seams; the defaults read Microsoft Graph, run the preflight and readiness checks, and price.
        [scriptblock]$FindGroup = { param($Value) Find-ClaudeMigrationGraphGroup -Value $Value },
        [scriptblock]$Preflight = { param($Parameters) $result = Invoke-ClaudeProjectionPreflight @Parameters -PassThru; , @($result.Checks) },
        [scriptblock]$Readiness = { param($Parameters) , @(Get-ClaudeProjectionReadiness @Parameters) },
        [scriptblock]$Inventory = { param($Parameters) Get-ClaudeProjectionResourcePlan @Parameters },
        [scriptblock]$FormatInventory = { param($Plan) Format-ClaudeProjectionResourcePlan -Plan $Plan },
        [scriptblock]$Cost = { param($Developers, $Region, $Access) Get-ClaudeMigrationMonthlyCost -Developers $Developers -Region $Region -ResolverInboundAccess $Access }
    )
    $values = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery
    $store = if ($values['entitlement-source']) { [string]$values['entitlement-source'] } else { 'named-value' }
    $facts = [ordered]@{
        Assessed = $true; Store = $store; Needed = $false; Reason = ''
        SubscriptionId = [string]$Discovery.subscriptionId; ResourceGroup = [string]$Discovery.resourceGroup; ApimName = [string]$Discovery.apimName
        Location = [string]$Discovery.location; Sku = [string]$Discovery.sku
        NamePrefix = ''; PrefixSource = ''; ResolverInboundAccess = ''; AccessSource = ''
        Groups = $null; BusinessUnits = 0; Developers = 0
        Problems = @(); Checks = @(); Blocked = $false
        Resources = $null; InventoryLines = @(); MonthlyUsd = $null; CostUnknownReason = ''; EstimatedMinutes = 0
    }
    if ($store -eq 'projection') {
        $facts.Reason = 'The gateway already serves entitlement from the Cosmos projection.'
        return [pscustomobject]$facts
    }
    if ($KeepNamedValues) {
        $facts.Reason = 'The gateway keeps named values (-KeepNamedValues).'
        return [pscustomobject]$facts
    }
    $facts.Needed = $true
    $problems = [Collections.Generic.List[string]]::new()

    # Prefix: the one the gateway records, else -NamePrefix, else the installer's rule (Install-ClaudeGateway.ps1:585).
    $prefixCandidates = @(
        @{ Value = [string]$Discovery.projectionPrefix; Source = 'the gateway''s entitlement-projection-prefix' },
        @{ Value = $NamePrefix; Source = 'parameter' },
        @{ Value = ([string]$Discovery.apimName -replace '^apim-', ''); Source = 'the API Management name without apim-' }
    )
    $prefix = @($prefixCandidates | Where-Object { $_.Value } | Select-Object -First 1)
    if ($prefix -and $prefix[0].Value.Length -le 37 -and $prefix[0].Value -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        $facts.NamePrefix = $prefix[0].Value; $facts.PrefixSource = $prefix[0].Source
    }
    else {
        $problems.Add("No projection name prefix: '$($prefix[0].Value)' is not 1-37 lowercase letters or digits separated by single hyphens. Remedy: pass -NamePrefix <prefix>.")
    }

    if ($facts.Sku -notin @('BasicV2', 'StandardV2', 'PremiumV2')) {
        $problems.Add("The gateway's tier is $($facts.Sku); the projection's resolver supports the v2 tiers (Basic v2, Standard v2, Premium v2). Remedy: change the tier first (the guided flow's Tier step, docs/UPDATE-AND-CHANGE.md).")
    }
    if ($ResolverInboundAccess) { $facts.ResolverInboundAccess = $ResolverInboundAccess; $facts.AccessSource = 'parameter' }
    else { $facts.ResolverInboundAccess = 'public'; $facts.AccessSource = 'ADR-0052 default' }
    if ($facts.Sku -eq 'BasicV2' -and $facts.ResolverInboundAccess -eq 'private') {
        $problems.Add('A private resolver needs the gateway''s outbound virtual network integration, which Basic v2 does not have. Remedy: -ResolverInboundAccess public, or Standard v2 or Premium v2.')
    }

    # Tier groups: parameters, the gateway's entitlement-groups, the decision record, the default names.
    $recorded = ConvertFrom-ClaudeEntitlementGroups ([string]$values['entitlement-groups'])
    $recordStandard = if ($Record -and $Record.PSObject.Properties['standardGroup']) { [string]$Record.standardGroup } else { '' }
    $recordPremium = if ($Record -and $Record.PSObject.Properties['premiumGroup']) { [string]$Record.premiumGroup } else { '' }
    $standard = Resolve-ClaudeMigrationGroup -Tier 'standard' -FindGroup $FindGroup -Candidates @(
        @{ Value = $StandardGroup; Source = 'parameter' }, @{ Value = $recorded['standard']; Source = 'gateway entitlement-groups' },
        @{ Value = $recordStandard; Source = 'decision record' }, @{ Value = 'claude-code-standard'; Source = 'default name' })
    $premium = Resolve-ClaudeMigrationGroup -Tier 'premium' -FindGroup $FindGroup -Candidates @(
        @{ Value = $PremiumGroup; Source = 'parameter' }, @{ Value = $recorded['premium']; Source = 'gateway entitlement-groups' },
        @{ Value = $recordPremium; Source = 'decision record' }, @{ Value = 'claude-code-premium'; Source = 'default name' })
    $listedStandard = ConvertFrom-ClaudeEntitlementList ([string]$values['allow-standard'])
    $listedPremium = ConvertFrom-ClaudeEntitlementList ([string]$values['allow-premium'])
    if (-not $standard.Found) {
        $problems.Add('The standard tier group was not found in Microsoft Graph under the gateway''s, the decision record''s or the default name. Remedy: pass -StandardGroup <name or object id>.')
    }
    if (-not $premium.Found -and -not $premium.Absent) {
        if ($listedPremium.Count) { $problems.Add("allow-premium lists $($listedPremium.Count) developer(s), but no premium tier group was found. Remedy: pass -PremiumGroup <name or object id>, or -PremiumGroup none.") }
        else { $premium.Absent = $true; $premium.Source = 'not found; allow-premium is empty' }
    }
    # A member of both groups is premium only, as Sync-ClaudeAccess.ps1 writes the lists.
    $effectiveStandard = @($standard.Members | Where-Object { $premium.Members -notcontains $_ })
    $tierFacts = foreach ($t in @(@{ G = $standard; Members = $effectiveStandard; Listed = $listedStandard }, @{ G = $premium; Members = @($premium.Members); Listed = $listedPremium })) {
        [pscustomobject]@{
            Tier = $t.G.Tier; Name = $t.G.Name; Id = $t.G.Id; Source = $t.G.Source; Found = $t.G.Found; Absent = $t.G.Absent
            Members = @($t.Members).Count; Listed = @($t.Listed).Count
            Gained = @($t.Members | Where-Object { $t.Listed -notcontains $_ }).Count
            Lost = @($t.Listed | Where-Object { $t.Members -notcontains $_ }).Count
        }
    }
    $facts.Groups = [pscustomobject]@{ Standard = $tierFacts[0]; Premium = $tierFacts[1] }
    $facts.Developers = @(@($listedStandard) + @($listedPremium) | Select-Object -Unique).Count
    $facts.BusinessUnits = @(([string]$values['bu-registry'] -split ',') | Where-Object { $_ -match '=' }).Count

    # Readiness: the projection preflight and the subscription checks, only once the previous values are known.
    $checks = [Collections.Generic.List[object]]::new()
    if (-not $problems.Count) {
        $groupArgument = { param($G, $Default) if ($G.Found) { $G.Id } else { $Default } }
        $preflightParameters = [ordered]@{
            ResourceGroup = $facts.ResourceGroup; ApimName = $facts.ApimName; NamePrefix = $facts.NamePrefix; SubscriptionId = $facts.SubscriptionId
            Location = $facts.Location; Sku = $facts.Sku; ResolverInboundAccess = $facts.ResolverInboundAccess
            StandardGroup = (& $groupArgument $standard 'claude-code-standard'); PremiumGroup = (& $groupArgument $premium 'claude-code-premium')
        }
        # Assigned first: a seam that returns ', @(checks)' writes one array object, which @(& $seam) would nest.
        $preflightResult = & $Preflight $preflightParameters
        foreach ($c in @($preflightResult)) { if ($c) { $checks.Add((ConvertTo-ClaudeMigrationCheck $c)) } }
        $readinessParameters = [ordered]@{ SubscriptionId = $facts.SubscriptionId; ResourceGroup = $facts.ResourceGroup; Location = $facts.Location; NamePrefix = $facts.NamePrefix }
        $readinessResult = & $Readiness $readinessParameters
        foreach ($c in @($readinessResult)) {
            if (-not $c) { continue }
            $converted = ConvertTo-ClaudeMigrationCheck $c
            if (-not @($checks | Where-Object { $_.Name -eq $converted.Name }).Count) { $checks.Add($converted) }
        }
    }
    $transferMinutes = Get-ClaudeMigrationTransferMinutes -Developers $facts.Developers
    if ($transferMinutes -gt 110) {
        $checks.Add([pscustomobject]@{ Name = 'Snapshot transfer through the runner'; Result = 'FAIL'
            Evidence = "about $transferMinutes minutes for $($facts.Developers) developers, past the snapshot's 2-hour apply-by time"
            Remedy = "A directory of this size syncs in the optional sync job: .\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup $($facts.ResourceGroup) -ApimName $($facts.ApimName) -NamePrefix $($facts.NamePrefix) -AlertEmail <address>; the directory-scale transfer is ROADMAP packet P99." })
    }
    $facts.Checks = @($checks)
    $facts.Problems = @($problems)
    $facts.Blocked = [bool]($problems.Count -or @($checks | Where-Object Result -eq 'FAIL').Count)

    if ($facts.NamePrefix) {
        $resourcePlan = & $Inventory ([ordered]@{ NamePrefix = $facts.NamePrefix; Location = $facts.Location; Sku = $(if ($facts.Sku -in @('BasicV2', 'StandardV2', 'PremiumV2')) { $facts.Sku } else { 'BasicV2' }); ResolverInboundAccess = $facts.ResolverInboundAccess })
        $facts.Resources = $resourcePlan
        $facts.InventoryLines = @(& $FormatInventory $resourcePlan)
    }
    $price = & $Cost $facts.Developers $facts.Location $facts.ResolverInboundAccess
    if ($price -and $null -ne $price.MonthlyUsd) { $facts.MonthlyUsd = [decimal]$price.MonthlyUsd }
    else { $facts.CostUnknownReason = $(if ($price -and $price.UnknownReason) { [string]$price.UnknownReason } else { 'the price could not be read' }) }
    $facts.EstimatedMinutes = 20 + $transferMinutes
    return [pscustomobject]$facts
}

# The default Graph lookup: a name or an object id, the group's display name and its transitive user members.
function Find-ClaudeMigrationGraphGroup {
    param([Parameter(Mandatory)][string]$Value)
    $token = Get-GraphToken
    $group = Get-ClaudeGraphGroup -GroupName $Value -Token $token
    if (-not $group) { return $null }
    $name = $Value
    if (Test-ClaudeMigrationGuid $Value) {
        $named = Invoke-ClaudeGraphRead -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)?`$select=displayName" -Token $token
        if ($named.displayName) { $name = [string]$named.displayName }
    }
    $members = @(Get-GroupMemberOids -GroupName ([string]$group.id) -Token $token | ForEach-Object { [string]$_.Oid })
    return [pscustomobject]@{ Id = [string]$group.id; Name = $name; Members = $members }
}

function Get-ClaudeMigrationMonthlyCost {
    # The same network shapes as scripts/Measure-ClaudeProjectionCost.ps1 -P61Scenarios: a public resolver has four
    # private endpoints and DNS zones (Cosmos and the resolver's storage), a private one five.
    param([int]$Developers, [string]$Region, [string]$ResolverInboundAccess = 'public')
    $script = Join-Path $PSScriptRoot 'Measure-ClaudeProjectionCost.ps1'
    $shape = if ($ResolverInboundAccess -eq 'private') { 5 } else { 4 }
    try {
        $json = & $script -Developers ([Math]::Max(1, $Developers)) -Region $Region -PrivateEndpoints $shape -PrivateDnsZones $shape -AsJson 2>$null 6>$null | Out-String
        $total = ($json | ConvertFrom-Json).monthly_usd.total
        if ($null -ne $total) { return [pscustomobject]@{ MonthlyUsd = [decimal]$total; UnknownReason = '' } }
        return [pscustomobject]@{ MonthlyUsd = $null; UnknownReason = 'scripts/Measure-ClaudeProjectionCost.ps1 returned no monthly total' }
    }
    catch { return [pscustomobject]@{ MonthlyUsd = $null; UnknownReason = "scripts/Measure-ClaudeProjectionCost.ps1 failed: $($_.Exception.Message)" } }
}

# The apply, in the installer's order (ADR-0052, ADR-0054): refresh the named values from Entra, deploy,
# populate, compare and switch; then record the tier groups on the gateway.
function Invoke-ClaudeEntitlementMigrationApply {
    param(
        [Parameter(Mandatory)]$Facts,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResumeCommand,
        [scriptblock]$EntitlementSync = { param($Parameters) Invoke-ClaudeInstallerEntitlementSync @Parameters },
        [scriptblock]$ProjectionDeployment = { param($Parameters) Invoke-ClaudeInstallerProjectionDeployment @Parameters },
        [scriptblock]$SetNamedValue = { param($Id, $Value) Set-ApimNamedValue -ResourceGroup $Facts.ResourceGroup -ApimName $Facts.ApimName -Id $Id -Value $Value -SubscriptionId $Facts.SubscriptionId }
    )
    if (-not $Facts.Needed) { return $false }
    if ($Facts.Blocked) { throw "The move to the projection is blocked by the plan's checks; nothing was written. Fix the FAIL items and plan again: $ResumeCommand" }
    $standardGroup = [string]$Facts.Groups.Standard.Id
    $premiumGroup = if ($Facts.Groups.Premium.Found) { [string]$Facts.Groups.Premium.Id } else { 'claude-code-premium' }
    try {
        $sync = & $EntitlementSync ([ordered]@{ Root = $Root; ResourceGroup = $Facts.ResourceGroup; ApimName = $Facts.ApimName; StandardGroup = $standardGroup
                PremiumGroup = $premiumGroup; EntitlementStore = 'projection'; LiveEntitlementSource = [string]$Facts.Store })
        $baseline = if ($sync -and $sync.CompareBaseline) { [string]$sync.CompareBaseline } else { 'Auto' }
        $null = & $ProjectionDeployment ([ordered]@{ Root = $Root; ResourceGroup = $Facts.ResourceGroup; ApimName = $Facts.ApimName; NamePrefix = $Facts.NamePrefix
                Location = $Facts.Location; Sku = $Facts.Sku; ResolverInboundAccess = $Facts.ResolverInboundAccess; StandardGroup = $standardGroup
                PremiumGroup = $premiumGroup; SubscriptionId = $Facts.SubscriptionId; CompareBaseline = $baseline; ServingStore = 'named-value' })
    }
    catch { throw "$($_.Exception.Message) Resume with the same update: $ResumeCommand" }
    $premiumId = if ($Facts.Groups.Premium.Found) { [string]$Facts.Groups.Premium.Id } else { 'none' }
    & $SetNamedValue 'entitlement-groups' (ConvertTo-ClaudeEntitlementGroups -StandardId $standardGroup -PremiumId $premiumId)
    return $true
}
