<#
.SYNOPSIS
    Moves a gateway that serves entitlement from named values to the Cosmos projection, through the update
    flow (ADR-0054): the facts its plan shows (previous values, readiness, resources, cost) and its apply.
    Dot-sourcing this file makes no Azure calls.
#>

# ConvertTo-ClaudeArmRegionName: az apim show gives 'East US 2'; ARM, the Retail Prices API and the usage
# reads take 'eastus2' (as Install-ClaudeGateway.ps1 converts an existing gateway's region).
. (Join-Path $PSScriptRoot 'ClaudeGatewayRegion.ps1')

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

# The first candidate that Graph finds wins. A candidate 'none' says the tier has no group. A value the operator
# passed, the gateway records or the gateway's decision record names is not replaced by a later candidate when
# Graph cannot find it: a typo or a deleted group would otherwise select another group, such as the default name,
# with no sign in the plan. Only the default names are a fallback.
function Resolve-ClaudeMigrationGroup {
    param([Parameter(Mandatory)][string]$Tier, [object[]]$Candidates, [Parameter(Mandatory)][scriptblock]$FindGroup)
    foreach ($candidate in $Candidates) {
        if (-not $candidate.Value) { continue }
        if ($candidate.Value -eq 'none') {
            return [pscustomobject]@{ Tier = $Tier; Name = ''; Id = ''; Source = $candidate.Source; Found = $false; Absent = $true; Missing = ''; Members = @() }
        }
        $group = & $FindGroup $candidate.Value
        if ($group -and $group.Id) {
            $members = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($member in @($group.Members)) { if ($member) { $null = $members.Add(([string]$member).ToLowerInvariant()) } }
            return [pscustomobject]@{ Tier = $Tier; Name = [string]$group.Name; Id = ([string]$group.Id).ToLowerInvariant(); Source = $candidate.Source; Found = $true; Absent = $false
                Missing = ''; Members = @($members) }
        }
        if ($candidate.Authoritative) {
            return [pscustomobject]@{ Tier = $Tier; Name = ''; Id = ''; Source = $candidate.Source; Found = $false; Absent = $false; Missing = [string]$candidate.Value; Members = @() }
        }
    }
    return [pscustomobject]@{ Tier = $Tier; Name = ''; Id = ''; Source = ''; Found = $false; Absent = $false; Missing = ''; Members = @() }
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
        # The projection deployment and its checks need PowerShell 7 (scripts/ClaudeProjectionChecks.ps1).
        [int]$PowerShellMajor = $PSVersionTable.PSVersion.Major,
        # Test seams; the defaults read Microsoft Graph, run the preflight and readiness checks, and price.
        [scriptblock]$FindGroup = { param($Value) Find-ClaudeMigrationGraphGroup -Value $Value },
        [scriptblock]$Preflight = { param($Parameters) Invoke-ClaudeProjectionPreflight @Parameters -PassThru },
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
        Location = (ConvertTo-ClaudeArmRegionName ([string]$Discovery.location)); Sku = [string]$Discovery.sku
        NamePrefix = ''; PrefixSource = ''; ResolverInboundAccess = ''; AccessSource = ''
        Groups = $null; BusinessUnits = 0; BusinessUnitIds = @(); BusinessUnitRegistrySha256 = ''; BusinessUnitParentsSha256 = ''; Developers = 0; ListedDevelopers = 0
        ResolverAppId = ''
        Problems = @(); Checks = @(); Blocked = $false; RecordNote = ''; RecordFits = $false
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
    # On Windows PowerShell 5.1 the move is not planned, so the update's other migrations still apply there.
    if ($PowerShellMajor -lt 7) {
        $facts.Reason = "The move to the Cosmos projection needs PowerShell 7 (pwsh); this update ran in PowerShell $PowerShellMajor, so it plans no move. Run .\Update-ClaudeGateway.ps1 in pwsh to plan the move."
        return [pscustomobject]$facts
    }
    $facts.Needed = $true
    $problems = [Collections.Generic.List[string]]::new()

    # Prefix: the gateway's entitlement-projection-prefix, which the deployer writes before the switch, so projection
    # resources may exist under it; else -NamePrefix; else the installer's rule (Install-ClaudeGateway.ps1:585). A
    # recorded value that is not a valid prefix names no resources (the deployer refuses such a prefix).
    $prefixRule = '1-37 lowercase letters or digits separated by single hyphens'
    $isPrefix = { param($Value) ([string]$Value).Length -ge 1 -and ([string]$Value).Length -le 37 -and [string]$Value -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' }
    $recordedPrefix = [string]$Discovery.projectionPrefix
    $derivedPrefix = [string]$Discovery.apimName -replace '^apim-', ''
    if (& $isPrefix $recordedPrefix) {
        $facts.NamePrefix = $recordedPrefix; $facts.PrefixSource = 'the gateway''s entitlement-projection-prefix'
        if ($NamePrefix -and $NamePrefix -cne $recordedPrefix) {
            $problems.Add("The gateway records entitlement-projection-prefix '$recordedPrefix', and projection resources may exist under it; -NamePrefix '$NamePrefix' differs. Remedy: omit -NamePrefix, so the move continues with '$recordedPrefix'.")
        }
    }
    elseif ($NamePrefix) {
        if (& $isPrefix $NamePrefix) { $facts.NamePrefix = $NamePrefix; $facts.PrefixSource = 'parameter' }
        else { $problems.Add("-NamePrefix '$NamePrefix' is not $prefixRule. Remedy: pass a -NamePrefix that is.") }
    }
    elseif ($recordedPrefix) {
        $problems.Add("The gateway's entitlement-projection-prefix '$recordedPrefix' is not $prefixRule. Remedy: pass -NamePrefix <prefix>; the deployment records it.")
    }
    elseif (& $isPrefix $derivedPrefix) { $facts.NamePrefix = $derivedPrefix; $facts.PrefixSource = 'the API Management name without apim-' }
    else {
        $problems.Add("No projection name prefix: '$derivedPrefix', the API Management name without apim-, is not $prefixRule. Remedy: pass -NamePrefix <prefix>.")
    }

    if ($facts.Sku -notin @('BasicV2', 'StandardV2', 'PremiumV2')) {
        $problems.Add("The gateway's tier is $($facts.Sku); the projection's resolver supports the v2 tiers (Basic v2, Standard v2, Premium v2). Remedy: change the tier first (the guided flow's Tier step, docs/UPDATE-AND-CHANGE.md).")
    }
    if ($ResolverInboundAccess) { $facts.ResolverInboundAccess = $ResolverInboundAccess; $facts.AccessSource = 'parameter' }
    else { $facts.ResolverInboundAccess = 'public'; $facts.AccessSource = 'ADR-0052 default' }
    if ($facts.Sku -eq 'BasicV2' -and $facts.ResolverInboundAccess -eq 'private') {
        $problems.Add('A private resolver needs the gateway''s outbound virtual network integration, which Basic v2 does not have. Remedy: -ResolverInboundAccess public, or Standard v2 or Premium v2.')
    }

    # Tier groups: parameters, the gateway's entitlement-groups, the decision record when it describes this gateway
    # (a record of another gateway would bring that gateway's groups), the default names.
    $recorded = ConvertFrom-ClaudeEntitlementGroups ([string]$values['entitlement-groups'])
    $recordFits = $Record -and $Record.PSObject.Properties['resourceGroup'] -and $Record.PSObject.Properties['apimName'] -and
        [string]::Equals([string]$Record.resourceGroup, $facts.ResourceGroup, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Record.apimName, $facts.ApimName, [StringComparison]::OrdinalIgnoreCase)
    if ($Record -and -not $recordFits) {
        $facts.RecordNote = "The decision record describes $(if ($Record.PSObject.Properties['apimName'] -and $Record.apimName) { "$($Record.resourceGroup)/$($Record.apimName)" } else { 'no gateway' }), not $($facts.ResourceGroup)/$($facts.ApimName); its tier groups were not used."
    }
    $facts.RecordFits = [bool]$recordFits
    $recordStandard = if ($recordFits -and $Record.PSObject.Properties['standardGroup']) { [string]$Record.standardGroup } else { '' }
    $recordPremium = if ($recordFits -and $Record.PSObject.Properties['premiumGroup']) { [string]$Record.premiumGroup } else { '' }
    $standard = Resolve-ClaudeMigrationGroup -Tier 'standard' -FindGroup $FindGroup -Candidates @(
        @{ Value = $StandardGroup; Source = 'parameter'; Authoritative = $true }, @{ Value = $recorded['standard']; Source = 'gateway entitlement-groups'; Authoritative = $true },
        @{ Value = $recordStandard; Source = 'decision record'; Authoritative = $true }, @{ Value = 'claude-code-standard'; Source = 'default name' })
    $premium = Resolve-ClaudeMigrationGroup -Tier 'premium' -FindGroup $FindGroup -Candidates @(
        @{ Value = $PremiumGroup; Source = 'parameter'; Authoritative = $true }, @{ Value = $recorded['premium']; Source = 'gateway entitlement-groups'; Authoritative = $true },
        @{ Value = $recordPremium; Source = 'decision record'; Authoritative = $true }, @{ Value = 'claude-code-premium'; Source = 'default name' })
    $listedStandard = ConvertFrom-ClaudeEntitlementList ([string]$values['allow-standard'])
    $listedPremium = ConvertFrom-ClaudeEntitlementList ([string]$values['allow-premium'])
    if ($standard.Missing) {
        $problems.Add("The standard tier group '$($standard.Missing)' (from the $($standard.Source)) was not found in Microsoft Graph. Remedy: pass -StandardGroup <the name or object id of an existing group>.")
    }
    elseif (-not $standard.Found) {
        $problems.Add('The standard tier group was not found in Microsoft Graph under the gateway''s, the decision record''s or the default name. Remedy: pass -StandardGroup <name or object id>.')
    }
    if ($premium.Missing) {
        $problems.Add("The premium tier group '$($premium.Missing)' (from the $($premium.Source)) was not found in Microsoft Graph. Remedy: pass -PremiumGroup <the name or object id of an existing group>, or -PremiumGroup none.")
    }
    elseif (-not $premium.Found -and -not $premium.Absent) {
        if ($listedPremium.Count) { $problems.Add("allow-premium lists $($listedPremium.Count) developer(s), but no premium tier group was found. Remedy: pass -PremiumGroup <name or object id>, or -PremiumGroup none.") }
        else { $premium.Absent = $true; $premium.Source = 'not found; allow-premium is empty' }
    }
    # A member of both groups is premium only, as Sync-ClaudeAccess.ps1 writes the lists. Sets keep this linear for a
    # directory of hundreds of thousands.
    $premiumSet = [Collections.Generic.HashSet[string]]::new([string[]]@($premium.Members), [StringComparer]::OrdinalIgnoreCase)
    $effectiveStandard = @($standard.Members | Where-Object { -not $premiumSet.Contains($_) })
    $tierFacts = foreach ($t in @(@{ G = $standard; Members = $effectiveStandard; Listed = $listedStandard }, @{ G = $premium; Members = @($premium.Members); Listed = $listedPremium })) {
        $memberSet = [Collections.Generic.HashSet[string]]::new([string[]]@($t.Members), [StringComparer]::OrdinalIgnoreCase)
        $listedSet = [Collections.Generic.HashSet[string]]::new([string[]]@($t.Listed), [StringComparer]::OrdinalIgnoreCase)
        [pscustomobject]@{
            Tier = $t.G.Tier; Name = $t.G.Name; Id = $t.G.Id; Source = $t.G.Source; Found = $t.G.Found; Absent = $t.G.Absent
            Members = $memberSet.Count; Listed = $listedSet.Count
            Gained = @($t.Members | Where-Object { -not $listedSet.Contains($_) }).Count
            Lost = @($t.Listed | Where-Object { -not $memberSet.Contains($_) }).Count
        }
    }
    $facts.Groups = [pscustomobject]@{ Standard = $tierFacts[0]; Premium = $tierFacts[1] }
    # The refresh and the snapshot carry the Entra members, so the transfer time and the cost count them; the
    # named-value lists are counted apart, for the drift.
    $entra = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($member in @($effectiveStandard) + @($premium.Members)) { if ($member) { $null = $entra.Add([string]$member) } }
    $facts.Developers = $entra.Count
    $facts.ListedDevelopers = @(@($listedStandard) + @($listedPremium) | Select-Object -Unique).Count
    $unitIds = @(([string]$values['bu-registry'] -split ',') | Where-Object { $_ -match '=' } | ForEach-Object { ($_ -split '=', 2)[0].Trim() } | Where-Object { $_ })
    $facts.BusinessUnits = $unitIds.Count
    $facts.BusinessUnitIds = @(Sort-ClaudeFlowOrdinal -InputObject $unitIds -Unique)
    # The registry's groups and budgets, not only its IDs, decide the projection's business units.
    $facts.BusinessUnitRegistrySha256 = Get-ClaudeFlowLifecycleStringHash -Text ([string]$values['bu-registry'])
    $facts.BusinessUnitParentsSha256 = Get-ClaudeFlowLifecycleStringHash -Text ([string]$values['bu-parents'])

    # Readiness: the projection preflight and the subscription checks, only once the previous values are known.
    $checks = [Collections.Generic.List[object]]::new()
    if (-not $problems.Count) {
        # A tier with no group is none, the switch's and the sync job's convention, never a default group name.
        $groupArgument = { param($G) if ($G.Found) { $G.Id } else { 'none' } }
        $preflightParameters = [ordered]@{
            ResourceGroup = $facts.ResourceGroup; ApimName = $facts.ApimName; NamePrefix = $facts.NamePrefix; SubscriptionId = $facts.SubscriptionId
            Location = $facts.Location; Sku = $facts.Sku; ResolverInboundAccess = $facts.ResolverInboundAccess
            StandardGroup = (& $groupArgument $standard); PremiumGroup = (& $groupArgument $premium)
        }
        # Assigned first: a seam that returns ', @(checks)' writes one array object, which @(& $seam) would nest.
        # The default seam returns the preflight's {Checks; Context}; the context holds the resolver app it found.
        $preflightResult = & $Preflight $preflightParameters
        $preflightChecks = $preflightResult
        if ($preflightResult -and $preflightResult.PSObject.Properties['Checks']) {
            $preflightChecks = $preflightResult.Checks
            $context = $preflightResult.PSObject.Properties['Context']
            if ($context -and $context.Value -and $context.Value.ResolverAppId) { $facts.ResolverAppId = ([string]$context.Value.ResolverAppId).ToLowerInvariant() }
        }
        foreach ($c in @($preflightChecks)) { if ($c) { $checks.Add((ConvertTo-ClaudeMigrationCheck $c)) } }
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
    # The apply took 36 minutes for one developer in the live run of 2026-10-06 (docs/status/P100.md, Live run).
    $facts.EstimatedMinutes = 35 + $transferMinutes
    return [pscustomobject]$facts
}

# When the facts cannot be read (a Graph or Azure error), the plan is blocked with the reason rather than the
# whole update failing; a gateway already on the projection still plans no move.
function New-ClaudeEntitlementMigrationFailure {
    param([Parameter(Mandatory)]$Discovery, [Parameter(Mandatory)][string]$Message)
    $values = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery
    $store = if ($values['entitlement-source']) { [string]$values['entitlement-source'] } else { 'named-value' }
    $needed = $store -ne 'projection'
    [pscustomobject]@{
        Assessed = $true; Store = $store; Needed = $needed
        Reason = $(if ($needed) { '' } else { 'The gateway already serves entitlement from the Cosmos projection.' })
        SubscriptionId = [string]$Discovery.subscriptionId; ResourceGroup = [string]$Discovery.resourceGroup; ApimName = [string]$Discovery.apimName
        Location = (ConvertTo-ClaudeArmRegionName ([string]$Discovery.location)); Sku = [string]$Discovery.sku
        NamePrefix = ''; PrefixSource = ''; ResolverInboundAccess = ''; AccessSource = ''
        Groups = $null; BusinessUnits = 0; BusinessUnitIds = @(); BusinessUnitRegistrySha256 = ''; BusinessUnitParentsSha256 = ''; Developers = 0; ListedDevelopers = 0
        ResolverAppId = ''
        Problems = @("The move to the projection could not be assessed: $Message Remedy: fix the cause and run the update again.")
        Checks = @(); Blocked = $needed; RecordNote = ''; RecordFits = $false
        Resources = $null; InventoryLines = @(); MonthlyUsd = $null; CostUnknownReason = 'not assessed'; EstimatedMinutes = 0
    }
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

# The update that resumes a failed move. It names every resolved value: the prefix and resolver access have no
# home on the gateway before the deployer writes them, so a resume that resolved them again could choose a second
# prefix or another access; the groups are named so the resume needs no Graph lookup by name. A decision record
# other than the default is named too, so the resume updates the same record.
function Get-ClaudeEntitlementMigrationResumeCommand([Parameter(Mandatory)]$Facts, [string]$RecordPath) {
    $premium = if ($Facts.Groups.Premium.Found) { [string]$Facts.Groups.Premium.Id } else { 'none' }
    $parts = [ordered]@{
        RecordPath = $RecordPath
        ResourceGroup = [string]$Facts.ResourceGroup; ApimName = [string]$Facts.ApimName; StandardGroup = [string]$Facts.Groups.Standard.Id
        PremiumGroup = $premium; NamePrefix = [string]$Facts.NamePrefix; ResolverInboundAccess = [string]$Facts.ResolverInboundAccess
    }
    $arguments = foreach ($name in $parts.Keys) { if ($parts[$name]) { "-$name $(ConvertTo-ClaudeFlowCommandArgument $parts[$name])" } }
    return (@('.\Update-ClaudeGateway.ps1') + @($arguments)) -join ' '
}

# The decision record names the groups the move used: until P101 reads entitlement-groups, Sync-ClaudeAccess.ps1
# takes its groups from the record (scripts/Get-ClaudeGatewayTarget.ps1) or the default names. A record of another
# gateway keeps its own groups; the result says whether the record was written.
function Set-ClaudeEntitlementMigrationRecordGroups {
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)]$Facts)
    if (-not ($Facts.PSObject.Properties['RecordFits'] -and $Facts.RecordFits)) { return $false }
    Set-ClaudeRecordProperty $Record 'standardGroup' ([string]$Facts.Groups.Standard.Id)
    Set-ClaudeRecordProperty $Record 'premiumGroup' $(if ($Facts.Groups.Premium.Found) { [string]$Facts.Groups.Premium.Id } else { 'none' })
    return $true
}

# The apply (ADR-0054): record the tier groups on the gateway, then the installer's order (ADR-0052): refresh the
# named values from Entra, deploy, populate, compare and switch. The groups come first: a later step that fails
# leaves them on the gateway for the resume, and the switch never happens without them.
function Invoke-ClaudeEntitlementMigrationApply {
    param(
        [Parameter(Mandatory)]$Facts,
        [Parameter(Mandatory)][string]$Root,
        [string]$ResumeCommand,
        # The decision record the update was run with, when it is not the default; the resume command names it.
        [string]$RecordPath,
        [scriptblock]$EntitlementSync = { param($Parameters) Invoke-ClaudeInstallerEntitlementSync @Parameters },
        [scriptblock]$ProjectionDeployment = { param($Parameters) Invoke-ClaudeInstallerProjectionDeployment @Parameters },
        [scriptblock]$SetNamedValue = { param($Id, $Value) Set-ApimNamedValue -ResourceGroup $Facts.ResourceGroup -ApimName $Facts.ApimName -Id $Id -Value $Value -SubscriptionId $Facts.SubscriptionId }
    )
    if (-not $Facts.Needed) { return $false }
    if (-not $ResumeCommand) { $ResumeCommand = Get-ClaudeEntitlementMigrationResumeCommand -Facts $Facts -RecordPath $RecordPath }
    if ($Facts.Blocked) { throw "The move to the projection is blocked by the plan's checks; nothing was written. Fix the FAIL items and plan again: $ResumeCommand" }
    $standardGroup = [string]$Facts.Groups.Standard.Id
    # A tier with no group is none, the switch's and the sync job's convention, never a default group name.
    $premiumGroup = if ($Facts.Groups.Premium.Found) { [string]$Facts.Groups.Premium.Id } else { 'none' }
    $premiumId = $premiumGroup
    try { & $SetNamedValue 'entitlement-groups' (ConvertTo-ClaudeEntitlementGroups -StandardId $standardGroup -PremiumId $premiumId) }
    catch { throw "Recording the tier groups in entitlement-groups failed: $($_.Exception.Message) Named values keep serving and nothing was switched. Resume with the same update: $ResumeCommand" }
    try {
        $sync = & $EntitlementSync ([ordered]@{ Root = $Root; ResourceGroup = $Facts.ResourceGroup; ApimName = $Facts.ApimName; StandardGroup = $standardGroup
                PremiumGroup = $premiumGroup; EntitlementStore = 'projection'; LiveEntitlementSource = [string]$Facts.Store
                # A tier with no members (no group, or a group that is empty) was counted in the approved plan as its
                # listed developers leaving it; the refresh may then empty that list.
                AllowEmptyStandard = ([int]$Facts.Groups.Standard.Members -eq 0)
                AllowEmptyPremium = ([int]$Facts.Groups.Premium.Members -eq 0) })
        $baseline = if ($sync -and $sync.CompareBaseline) { [string]$sync.CompareBaseline } else { 'Auto' }
        $deployment = [ordered]@{ Root = $Root; ResourceGroup = $Facts.ResourceGroup; ApimName = $Facts.ApimName; NamePrefix = $Facts.NamePrefix
                Location = $Facts.Location; Sku = $Facts.Sku; ResolverInboundAccess = $Facts.ResolverInboundAccess; StandardGroup = $standardGroup
                PremiumGroup = $premiumGroup; SubscriptionId = $Facts.SubscriptionId; CompareBaseline = $baseline; ServingStore = 'named-value' }
        # The resolver app the plan's preflight found is the one the deployment uses (it re-checks it).
        if ($Facts.PSObject.Properties['ResolverAppId'] -and $Facts.ResolverAppId) { $deployment['ProjectionResolverAppId'] = [string]$Facts.ResolverAppId }
        $null = & $ProjectionDeployment $deployment
    }
    catch { throw "$($_.Exception.Message) Resume with the same update: $ResumeCommand" }
    return $true
}
