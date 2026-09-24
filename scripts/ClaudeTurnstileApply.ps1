# Governance authored in Turnstile, applied to the gateway.
#
# When the connection's governanceAuthority is Turnstile, business units, teams, their Entra
# groups, budgets and tier limits are all edited in Turnstile's UI, and each save starts the
# gateway's apply job, which calls the functions below. The gateway stays the one enforcer
# (ADR-0014); Turnstile becomes where its configuration is written (ADR-0015).
#
# Dot-sourced after ApimNamedValue.ps1 and ClaudeBusinessUnit.ps1, whose named value and
# registry functions it uses.

$script:ClaudeGatewayTiers = @('standard', 'premium')

function ConvertTo-ClaudeGatewayModelList {
    <#
    .SYNOPSIS
        A tier's model allow list in the gateway's comma-anchored form: ',a,b,', and ',,' for every model.
    #>
    param([AllowNull()][AllowEmptyCollection()][string[]]$Models)
    $items = @($Models | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $items.Count) { return ',,' }
    return ',' + ($items -join ',') + ','
}

function ConvertFrom-ClaudeTurnstileGovernance {
    <#
    .SYNOPSIS
        Turnstile's catalog, budgets and tiers as the gateway's registry, parent map and tier settings.

    .DESCRIPTION
        A business unit is an organization whose external reference names its Entra group
        (entra-group:<group>). A team is a department under a unit with a group of its own; the
        department that shares its unit's id holds the unit's direct members and is not a team,
        and the unassigned organization is not a unit. A unit's or team's monthly budget is its
        organization or department budget for the period; one without a budget gets 0, which the
        policy reads as no business-unit budget - tier quotas still apply.

        Only tiers the gateway's policy enforces are applied; a new tier is a policy change, so
        it is reported instead. Anything not applied is named in Problems, never dropped silently.
    #>
    param(
        [Parameter(Mandatory = $true)]$Catalog,
        [AllowNull()][AllowEmptyCollection()]$BudgetItems = @(),
        [AllowNull()][AllowEmptyCollection()]$Tiers = @(),
        [string[]]$SupportedTiers = $script:ClaudeGatewayTiers
    )

    if ([string]$Catalog.source -ne 'configured') {
        throw "Turnstile's catalog is its seeded demonstration set. Add business units on Turnstile's Gateway governance page first; nothing was applied."
    }
    $problems = New-Object System.Collections.Generic.List[string]
    $limits = @{}
    foreach ($b in @($BudgetItems)) {
        if ($b -and [string]$b.scope_type -in @('organization', 'department') -and $null -ne $b.token_limit) {
            $limits["$($b.scope_type)/$($b.scope_id)"] = [long]$b.token_limit
        }
    }
    $groupOf = {
        param($Entity)
        $ref = [string]$Entity.external_ref
        if ($ref -like 'entra-group:*') { return $ref.Substring('entra-group:'.Length).Trim() }
        return $ref.Trim()
    }

    $units = New-Object System.Collections.Generic.List[object]
    foreach ($org in @($Catalog.organizations)) {
        $id = [string]$org.id
        if ($id -eq 'unassigned') { continue }
        if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') { $problems.Add("business unit '$id': not a valid gateway id (lower-case letters, digits and hyphens)"); continue }
        $group = & $groupOf $org
        if (-not $group) { $problems.Add("business unit '$id': names no Entra group, so it could have no members"); continue }
        $tokens = if ($limits.ContainsKey("organization/$id")) { $limits["organization/$id"] } else { [long]0 }
        $units.Add([pscustomobject]@{ Id = $id; Group = $group; TokensPerMonth = [long]$tokens })
    }
    $unitIds = @($units | ForEach-Object { $_.Id })
    $parents = [ordered]@{}
    foreach ($dept in @($Catalog.departments)) {
        $id = [string]$dept.id
        $parent = [string]$dept.parent_id
        if (-not $parent -or $id -eq $parent -or $parent -eq 'unassigned') { continue }
        if ($unitIds -notcontains $parent) { $problems.Add("team '$id': its business unit '$parent' was not applied"); continue }
        if ($id -notmatch '^[a-z0-9][a-z0-9-]*$') { $problems.Add("team '$id': not a valid gateway id (lower-case letters, digits and hyphens)"); continue }
        $group = & $groupOf $dept
        if (-not $group) { $problems.Add("team '$id': names no Entra group"); continue }
        $tokens = if ($limits.ContainsKey("department/$id")) { $limits["department/$id"] } else { [long]0 }
        $units.Add([pscustomobject]@{ Id = $id; Group = $group; TokensPerMonth = [long]$tokens })
        $parents[$id] = $parent
    }

    $tierSettings = New-Object System.Collections.Generic.List[object]
    foreach ($tier in @($Tiers)) {
        if (-not $tier) { continue }
        $id = [string]$tier.id
        if ($SupportedTiers -notcontains $id) {
            $problems.Add("tier '$id': the gateway's policy enforces only $($SupportedTiers -join ' and '); a new tier is a policy change")
            continue
        }
        $tierSettings.Add([pscustomobject]@{
            Id              = $id
            Group           = ([string]$tier.entra_group).Trim()
            TokensPerMinute = [long]$tier.tokens_per_minute
            TokensPerDay    = [long]$tier.tokens_per_day
            Models          = ConvertTo-ClaudeGatewayModelList @($tier.models)
        })
    }

    [pscustomobject]@{
        Registry = $units.ToArray()
        Parents  = $parents
        Tiers    = $tierSettings.ToArray()
        Problems = $problems.ToArray()
    }
}

function Get-ClaudeGatewayGovernanceChanges {
    <#
    .SYNOPSIS
        The named values that differ between the gateway now and what Turnstile says.
    .DESCRIPTION
        Returns one change per named value to write, with the value it had. Nothing that
        already matches is written, so an apply after an unrelated save changes nothing.
    #>
    param(
        [Parameter(Mandatory = $true)]$Desired,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Current
    )
    $changes = New-Object System.Collections.Generic.List[object]
    $want = [ordered]@{
        'bu-registry' = ConvertTo-ClaudeBuRegistry @($Desired.Registry)
        'bu-parents'  = ConvertTo-ClaudeBuParents $Desired.Parents
    }
    foreach ($t in @($Desired.Tiers)) {
        $want["tpm-$($t.Id)"] = [string]$t.TokensPerMinute
        $want["quota-$($t.Id)"] = [string]$t.TokensPerDay
        $want["models-$($t.Id)"] = [string]$t.Models
    }
    foreach ($id in $want.Keys) {
        $was = if ($Current.Contains($id)) { [string]$Current[$id] } else { '' }
        if ($was -ne [string]$want[$id]) { $changes.Add([pscustomobject]@{ Id = $id; Was = $was; Now = [string]$want[$id] }) }
    }
    return , $changes.ToArray()
}

function Test-ClaudeGraphGroupAccess {
    <#
    .SYNOPSIS
        Whether this identity can read Entra groups: 'ok', 'denied', or 'error'.
    .DESCRIPTION
        The apply job's identity needs Microsoft Graph GroupMember.Read.All to check that a group
        exists and to read its members. A tenant administrator grants it once (docs/TURNSTILE.md).
        Without it, groups the gateway already uses are trusted, new ones are not applied, and
        membership is left as it is - never rewritten from groups that merely could not be read.
    #>
    $raw = az rest --method get --url 'https://graph.microsoft.com/v1.0/groups?$top=1&$select=id' 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { return 'ok' }
    if ($raw -match '(?i)Authorization_RequestDenied|Insufficient privileges|Forbidden|403') { return 'denied' }
    return 'error'
}

function Test-ClaudeEntraGroup {
    <#
    .SYNOPSIS
        'exists', 'missing', or 'unknown' when the directory cannot be read.
    #>
    param([Parameter(Mandatory = $true)][string]$Group)
    $raw = az ad group show --group $Group --query id -o tsv 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $raw.Trim() -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return 'exists' }
    if ($raw -match '(?i)Authorization_RequestDenied|Insufficient privileges|Forbidden|403') { return 'unknown' }
    return 'missing'
}

function Select-ClaudeGovernanceWithGroups {
    <#
    .SYNOPSIS
        Keeps the units and teams whose Entra group is known to exist, and every tier's limits.
    .DESCRIPTION
        A unit pointing at a group that does not exist resolves to nobody and reads as unused
        rather than broken (P31), so it is not applied. When the directory cannot be read, a group
        the gateway already uses is trusted and a new one is not. A team whose unit is not applied
        is not applied either.

        A tier's limits do not depend on its group, so they are always kept. Its group only says
        who holds it, which matters when membership is refreshed: TierGroups holds a tier's group
        only when the group is known to exist, and membership is refreshed only when every tier
        has one. Returns the kept governance, TierGroups, and the reasons for what was left out.
    #>
    param(
        [Parameter(Mandatory = $true)]$Desired,
        [AllowEmptyCollection()][string[]]$KnownGroups = @(),
        [Parameter(Mandatory = $true)][scriptblock]$GroupState
    )
    $known = @($KnownGroups | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $problems = New-Object System.Collections.Generic.List[string]
    $cache = @{}
    $accept = {
        param([string]$Label, [string]$Group)
        $key = $Group.ToLowerInvariant()
        if (-not $cache.ContainsKey($key)) { $cache[$key] = [string](& $GroupState $Group) }
        switch ($cache[$key]) {
            'exists' { return $true }
            'unknown' {
                if ($known -contains $key) { return $true }
                $problems.Add("${Label}: the Entra group '$Group' could not be checked - the apply identity cannot read Entra groups - and the gateway does not use it yet")
                return $false
            }
            default { $problems.Add("${Label}: there is no Entra group '$Group'"); return $false }
        }
    }
    $kept = @($Desired.Registry | Where-Object { & $accept "'$($_.Id)'" $_.Group })
    $keptIds = @($kept | ForEach-Object { $_.Id })
    $parents = [ordered]@{}
    foreach ($team in @($Desired.Parents.Keys)) {
        if ($keptIds -contains $team -and $keptIds -contains $Desired.Parents[$team]) { $parents[$team] = $Desired.Parents[$team] }
        elseif ($keptIds -contains $team) { $problems.Add("team '$team': its business unit was not applied") }
    }
    $kept = @($kept | Where-Object { -not $Desired.Parents.Contains($_.Id) -or $parents.Contains($_.Id) })
    $tierGroups = [ordered]@{}
    foreach ($tier in @($Desired.Tiers)) {
        $key = $tier.Group.ToLowerInvariant()
        if (-not $cache.ContainsKey($key)) { $cache[$key] = [string](& $GroupState $tier.Group) }
        if ($cache[$key] -eq 'exists') { $tierGroups[$tier.Id] = $tier.Group }
        elseif ($cache[$key] -eq 'missing') {
            $problems.Add("tier '$($tier.Id)': there is no Entra group '$($tier.Group)'; its limits were applied and its members left as they are")
        }
    }
    [pscustomobject]@{
        Governance = [pscustomobject]@{ Registry = $kept; Parents = $parents; Tiers = @($Desired.Tiers) }
        TierGroups = $tierGroups
        Problems   = $problems.ToArray()
    }
}

function Invoke-ClaudeGatewayGovernanceApply {
    <#
    .SYNOPSIS
        Applies governance authored in Turnstile to the gateway: units, teams, budgets and tiers.
    .DESCRIPTION
        Reads what the gateway has now, works out what Turnstile says it should have, keeps only
        what names an Entra group known to exist, writes the named values that differ - reading
        each back - and then refreshes membership from the groups, when the directory can be
        read. Without -Apply it only reports. Nothing is written for a seeded Turnstile catalog.
    #>
    param(
        [Parameter(Mandatory = $true)]$Catalog,
        [AllowEmptyCollection()]$BudgetItems = @(),
        [AllowEmptyCollection()]$Tiers = @(),
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$ApimName,
        [Parameter(Mandatory = $true)][string]$ScriptRoot,
        [switch]$Apply
    )
    $desired = ConvertFrom-ClaudeTurnstileGovernance -Catalog $Catalog -BudgetItems @($BudgetItems) -Tiers @($Tiers)
    $ids = @('bu-registry', 'bu-parents') + @($script:ClaudeGatewayTiers | ForEach-Object { "tpm-$_"; "quota-$_"; "models-$_" })
    $current = [ordered]@{}
    foreach ($id in $ids) { $current[$id] = [string](Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id) }

    $graph = Test-ClaudeGraphGroupAccess
    $currentUnits = @(ConvertFrom-ClaudeBuRegistry $current['bu-registry'])
    $knownGroups = @($currentUnits | ForEach-Object { $_.Group })
    $state = if ($graph -eq 'ok') { { param($g) Test-ClaudeEntraGroup $g } } else { { param($g) 'unknown' } }
    $selected = Select-ClaudeGovernanceWithGroups -Desired $desired -KnownGroups $knownGroups -GroupState $state
    $problems = @($desired.Problems) + @($selected.Problems)
    $changes = Get-ClaudeGatewayGovernanceChanges -Desired $selected.Governance -Current $current
    if (-not @($selected.Governance.Registry).Count -and $currentUnits.Count) {
        # Every unit gone at once is far more often a read that went wrong than a decision.
        $changes = @($changes | Where-Object { $_.Id -notin 'bu-registry', 'bu-parents' })
        $problems += "Turnstile has no business unit the gateway can apply, so the gateway's $($currentUnits.Count) were left as they are"
    }

    $membership = 'not refreshed: nothing was applied'
    if ($Apply) {
        foreach ($c in $changes) {
            Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $c.Id -Value $c.Now
            if ([string](Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $c.Id) -ne $c.Now) {
                throw "$($c.Id) did not read back as written; the change may not be in effect."
            }
        }
        if ($graph -ne 'ok') {
            # Never refresh membership from groups that could not be read: an unreadable group
            # looks empty, and an empty tier list would refuse everyone in it.
            $membership = "not refreshed: the apply identity cannot read Entra groups ($graph). A tenant administrator grants it Microsoft Graph GroupMember.Read.All once (docs/TURNSTILE.md)"
        }
        elseif (@($script:ClaudeGatewayTiers | Where-Object { -not $selected.TierGroups.Contains($_) }).Count) {
            # The access sync writes every tier at once, and a tier with no confirmed group would
            # be written from a default name that may not be this gateway's.
            $membership = 'not refreshed: every tier needs an Entra group that exists'
        }
        else {
            # The access sync signals failure by throwing, not by an exit code.
            try {
                & (Join-Path $ScriptRoot 'Sync-ClaudeAccess.ps1') -ApimName $ApimName -ResourceGroup $ResourceGroup `
                    -StandardGroup $selected.TierGroups['standard'] -PremiumGroup $selected.TierGroups['premium'] *> $null
            }
            catch { throw "The limits were applied, but the membership refresh did not finish: $($_.Exception.Message)" }
            $membership = 'refreshed from the Entra groups'
        }
    }
    [pscustomobject][ordered]@{
        Direction  = 'FromTurnstile'
        Mode       = 'governance'
        Units      = @($selected.Governance.Registry | Where-Object { -not $selected.Governance.Parents.Contains($_.Id) }).Count
        Teams      = $selected.Governance.Parents.Count
        Tiers      = @($selected.Governance.Tiers).Count
        Changes    = @($changes | ForEach-Object { "$($_.Id): $($_.Was) -> $($_.Now)" })
        Applied    = $(if ($Apply) { @($changes).Count } else { 0 })
        Membership = $membership
        Problems   = $problems
    }
}

function Get-ClaudeGatewayTierDocument {
    param([string]$ResourceGroup, [string]$ApimName, [string]$StandardGroup, [string]$PremiumGroup)
    $groups = @{ standard = $StandardGroup; premium = $PremiumGroup }
    $names = @{ standard = 'Standard'; premium = 'Premium' }
    $tiers = foreach ($t in $script:ClaudeGatewayTiers) {
        $tpm = [string](Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id "tpm-$t")
        $day = [string](Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id "quota-$t")
        $models = [string](Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id "models-$t")
        if ($tpm -notmatch '^\d+$' -or $day -notmatch '^\d+$') { continue }
        [ordered]@{
            id = $t; name = $names[$t]; entra_group = $groups[$t]
            tokens_per_minute = [long]$tpm; tokens_per_day = [long]$day
            models = @($models.Trim(',') -split ',' | Where-Object { $_ })
        }
    }
    return @{ tiers = @($tiers) }
}

$script:ClaudeGovernanceWriterRole = 'Claude gateway governance writer'

function Set-ClaudeGovernanceWriterRole {
    # A custom role that reads and writes an API Management instance's named values and nothing
    # else. The built-in role that can write them, API Management Service Contributor, can also
    # change the gateway's policy, certificates and network. Role names are unique in a tenant,
    # so an existing role is reused, with this resource group added to where it may be assigned.
    param([Parameter(Mandatory)][string]$ResourceGroup)
    $scope = "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$ResourceGroup"
    $existing = @(az role definition list --custom-role-only true --name $script:ClaudeGovernanceWriterRole -o json | ConvertFrom-Json)
    $scopes = @($scope)
    if ($existing.Count) {
        $current = @($existing[0].assignableScopes)
        if ($current | Where-Object { $scope -eq $_ -or $scope.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) }) {
            return $script:ClaudeGovernanceWriterRole
        }
        $scopes = $current + $scope
    }
    $definition = [ordered]@{
        Name             = $script:ClaudeGovernanceWriterRole
        IsCustom         = $true
        Description      = 'Reads and writes the named values of a Claude gateway, for the job that applies what Turnstile saves. Nothing else.'
        Actions          = @(
            'Microsoft.ApiManagement/service/read',
            'Microsoft.ApiManagement/service/namedValues/read',
            'Microsoft.ApiManagement/service/namedValues/write',
            'Microsoft.ApiManagement/service/operationresults/read')
        NotActions       = @()
        DataActions      = @()
        NotDataActions   = @()
        AssignableScopes = $scopes
    }
    if ($existing.Count) { $definition['Id'] = $existing[0].name }
    $file = Join-Path ([IO.Path]::GetTempPath()) "claude-governance-role-$PID.json"
    try {
        $definition | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding utf8
        if ($existing.Count) { az role definition update --role-definition "@$file" -o none }
        else { az role definition create --role-definition "@$file" -o none }
        if ($LASTEXITCODE) { throw "Could not define the role '$($script:ClaudeGovernanceWriterRole)'. Defining a role needs Owner or User Access Administrator." }
    }
    finally { Remove-Item $file -ErrorAction SilentlyContinue }
    $script:ClaudeGovernanceWriterRole
}
