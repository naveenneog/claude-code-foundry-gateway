<#
.SYNOPSIS
    JSON bridge for AUM (Azure Usage Management). Keeps its compatible filename.
.DESCRIPTION
    Reads named values without secrets. Mutations are explicit, use the existing
    serializers and tier script, and never accept PowerShell code in the input.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [string]$Subscription
)
$ErrorActionPreference = 'Stop'
trap {
    @{ error=$_.Exception.Message; error_type=$_.Exception.GetType().Name } | ConvertTo-Json -Compress
    exit 1
}
if ($Subscription) {
    $parsedSubscription = [guid]::Empty
    if (-not [guid]::TryParse($Subscription, [ref]$parsedSubscription)) { throw 'Subscription must be an object id.' }
    $aumDirectAzureExecutable = @(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    $aumDirectSubscription = $Subscription
    function az {
        if ($args[0] -eq 'ad') { & $aumDirectAzureExecutable @args }
        else { & $aumDirectAzureExecutable @args --subscription $aumDirectSubscription }
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBudgetOverride.ps1')
. (Join-Path $PSScriptRoot 'ClaudeAumDirectWrites.ps1')
. (Join-Path $PSScriptRoot 'ClaudeUsdBudgets.ps1')
$request = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
$nv = Get-AumNamedValueMap -ResourceGroup $ResourceGroup -ApimName $ApimName
$registry = @(ConvertFrom-ClaudeBuRegistry $nv['bu-registry'])
$parents = ConvertFrom-ClaudeBuParents $nv['bu-parents']
$modes = ConvertFrom-ClaudeBuModes $nv['bu-modes']
$result = $null

function Invoke-VerifiedChange($Expected, [scriptblock]$Operation) {
    foreach ($key in $Expected.Keys) { Test-ApimNamedValueLength -Id $key -Value ([string]$Expected[$key]) }
    Invoke-AumVerifiedWrite -Before $nv -After $Expected -Operation $Operation `
        -Read { Get-AumNamedValueMap -ResourceGroup $ResourceGroup -ApimName $ApimName } `
        -Write { param($key,$value) Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $key -Value $value } `
        -Remove {
            param($key)
            az apim nv delete -g $ResourceGroup --service-name $ApimName --named-value-id $key --yes -o none
            if ($LASTEXITCODE -ne 0) { throw 'Could not remove the value created by this operation.' }
        }
}

function Get-AumSha256Hex([string]$Value) {
    $bytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

switch ([string]$request.action) {
    'delegated_publish' {
        if ($nv['turnstile-integration'] -notmatch 'governanceAuthority=Turnstile') {
            throw 'Delegated publication requires an explicitly configured Turnstile authority.'
        }
        $result=& (Join-Path $PSScriptRoot 'Sync-ClaudeTurnstileGovernance.ps1') `
            -Direction FromTurnstile -Apply -ResourceGroup $ResourceGroup -ApimName $ApimName 6>$null
    }
    'membership' {
        $arguments=@{ResourceGroup=$ResourceGroup;ApimName=$ApimName;ScopeIds=@($request.parameters.scope_ids)}
        if($request.parameters.source_authority){$arguments.GovernanceSource=[string]$request.parameters.source_authority}
        if($request.parameters.apply){$arguments.Apply=$true}
        if($request.parameters.allow_reassignment){$arguments.AllowReassignment=$true}
        $result=& (Join-Path $PSScriptRoot 'Sync-AumMembership.ps1') @arguments | ConvertFrom-Json
    }
    'read' {
        $tiers = foreach ($tier in @('standard', 'premium')) {
            [ordered]@{
                id = $tier; name = $tier; entra_group = ''
                tokens_per_minute = [long]$nv["tpm-$tier"]
                tokens_per_day = [long]$nv["quota-$tier"]
                models = @($nv["models-$tier"].Trim(',') -split ',' | Where-Object { $_ })
            }
        }
        $catalog = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents -Modes $modes
        $result = [ordered]@{
            catalog = $catalog; tiers = @($tiers)
            registry = @($registry); parents = $parents
            quota_org = [long]$nv['quota-org']
            overrides = $(if ($nv.ContainsKey('quota-overrides')) { ConvertFrom-ClaudeBudgetOverrides $nv['quota-overrides'] } else { @{} })
            person_budgets_supported = $nv.ContainsKey('quota-overrides')
            modes_supported = $nv.ContainsKey('bu-modes')
            authority = $(if ($nv['turnstile-integration'] -match '(?:^|;)(?:governanceAuthority|budgetAuthority)=Turnstile(?:;|$)') { 'Turnstile' } else { 'Gateway' })
            usd_supported = $nv.ContainsKey('usd-budgets') -and $nv.ContainsKey('usd-budget-state')
        }
    }
    'usd_budgets' {
        $doc = ConvertFrom-ClaudeUsdValue $nv['usd-budgets']
        $items = @()
        if ($doc.items) {
            foreach ($entry in $doc.items.PSObject.Properties) {
                $parts = $entry.Name.Split(':', 2)
                $items += [ordered]@{
                    scope_type = $parts[0]; scope_id = $parts[1]
                    amount_usd = [string]$entry.Value.amount_usd
                    period = [string]$entry.Value.period
                    price_book_date = [string]$entry.Value.price_book_date
                    writable = ($nv['turnstile-integration'] -notmatch '(?:^|;)(?:governanceAuthority|budgetAuthority)=Turnstile(?:;|$)')
                }
            }
        }
        $result = [ordered]@{
            schema_version = 1; currency = 'USD'
            revision = Get-AumSha256Hex $nv['usd-budgets']
            price_book_date = [string]$doc.price_book.date
            items = @($items)
        }
    }
    'usd_status' {
        $state = ConvertFrom-ClaudeUsdValue $nv['usd-budget-state']
        if (-not $state.PSObject.Properties.Count) {
            $result = [ordered]@{ enabled = $false; fresh = $false; items = [pscustomobject]@{}; reconcile_interval_seconds = 300; state_max_age_seconds = 900 }
        }
        else {
            if ($state.encoding -eq 'compact-v1') {
                $expanded = [ordered]@{}
                foreach ($name in $state.PSObject.Properties.Name) {
                    if ($name -notin @('encoding', 'periods', 'price_book_date', 'items')) { $expanded[$name] = $state.$name }
                }
                $expanded['items'] = [ordered]@{}
                foreach ($entry in $state.items.PSObject.Properties) {
                    $parts = $entry.Name.Split(':', 2)
                    $data = @($entry.Value)
                    $periodBounds = @($state.periods.PSObject.Properties[$data[0]].Value)
                    $flags = [int]$data[6]
                    $expanded['items'][$entry.Name] = [ordered]@{
                        scope_type = $parts[0]; scope_id = $parts[1]; period = [string]$data[0]
                        period_start = [string]$periodBounds[0]; period_end = [string]$periodBounds[1]
                        price_book_date = [string]$state.price_book_date
                        budget_usd = [string]$data[1]; effective_budget_usd = [string]$data[2]
                        spent_usd = $data[3]; status = [string]$data[4]; enforcement = [string]$data[5]
                        exact = (($flags -band 1) -ne 0)
                        cache_read_known = (($flags -band 2) -ne 0)
                        cache_write_known = (($flags -band 4) -ne 0)
                        unpriced_models = @($data[7])
                    }
                }
                $state = [pscustomobject]$expanded
            }
            $result = $state
            $result | Add-Member -NotePropertyName reconcile_interval_seconds -NotePropertyValue 300 -Force
            $result | Add-Member -NotePropertyName state_max_age_seconds -NotePropertyValue 900 -Force
            $result | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force
            $result | Add-Member -NotePropertyName fresh -NotePropertyValue $true -Force
        }
    }
    'usd_price_book' {
        if ($request.body -and $request.body.price_book) {
            Assert-ClaudeUsdAuthority -ResourceGroup $ResourceGroup -ApimName $ApimName
            $doc = ConvertFrom-ClaudeUsdValue $nv['usd-budgets']
            if ($doc.items -and $doc.items.PSObject.Properties.Count -and ($doc.price_book | ConvertTo-Json -Depth 30 -Compress) -cne ($request.body.price_book | ConvertTo-Json -Depth 30 -Compress)) {
                throw 'Active USD budgets pin their tariff; clear them before replacing the price book.'
            }
            $next = [pscustomobject]@{ schema_version = 1; price_book = $request.body.price_book; items = $(if ($doc.items) { $doc.items } else { [pscustomobject]@{} }) }
            $encoded = ConvertTo-ClaudeUsdValue $next
            $result = Invoke-VerifiedChange @{ 'usd-budgets'=$encoded } {
                Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'usd-budgets' -Value $encoded | Out-Null
            }
            $result.price_book = $request.body.price_book
        }
        else {
            $doc = ConvertFrom-ClaudeUsdValue $nv['usd-budgets']
            $result = [ordered]@{
                revision = Get-AumSha256Hex $nv['usd-budgets']
                price_book = $doc.price_book
            }
        }
    }
    { $_ -in 'usd_budget', 'usd_budget_remove' } {
        if (-not $nv.ContainsKey('usd-budgets') -or -not $nv.ContainsKey('usd-budget-state')) {
            throw 'Install the current gateway template/policy before setting USD budgets.'
        }
        $args = @{
            ResourceGroup = $ResourceGroup
            ApimName = $ApimName
            ScopeType = [string]$request.parameters.scope_type
            ScopeId = [string]$request.parameters.scope_id
            AmountUsd = $(if ($request.action -eq 'usd_budget_remove') { [decimal]0 } else { [decimal]::Parse([string]$request.body.amount_usd, [Globalization.CultureInfo]::InvariantCulture) })
            Period = $(if ($request.body.period) { [string]$request.body.period } else { 'month' })
        }
        if ($request.action -eq 'usd_budget_remove') { $args.Clear = $true }
        Set-ClaudeUsdBudget @args 6>$null | Out-Null
        $doc = ConvertFrom-ClaudeUsdValue (Get-AumNamedValueMap -ResourceGroup $ResourceGroup -ApimName $ApimName)['usd-budgets']
        $key = "$($request.parameters.scope_type):$($request.parameters.scope_id)"
        $result = [ordered]@{
            audit_id = 'direct-control-plane'
            revision = Get-AumSha256Hex (ConvertTo-ClaudeUsdValue $doc)
            result = $(if ($request.action -eq 'usd_budget_remove') { [ordered]@{ cleared = $true } }
                else { [ordered]@{ scope_type = [string]$request.parameters.scope_type; scope_id = [string]$request.parameters.scope_id
                    amount_usd = [string]$doc.items.PSObject.Properties[$key].Value.amount_usd
                    period = [string]$doc.items.PSObject.Properties[$key].Value.period
                    price_book_date = [string]$doc.items.PSObject.Properties[$key].Value.price_book_date } })
        }
    }
    'usd_reconcile' {
        if (-not $request.parameters.workspace_id) { throw 'USD reconciliation needs the Log Analytics workspace id in Direct config.' }
        $arguments = @{
            ResourceGroup = $ResourceGroup
            ApimName = $ApimName
            WorkspaceId = [string]$request.parameters.workspace_id
        }
        if ($request.parameters.subscription_id) { $arguments.SubscriptionId = [string]$request.parameters.subscription_id }
        $result = & (Join-Path $PSScriptRoot 'Sync-ClaudeUsdBudgets.ps1') @arguments | ConvertFrom-Json
    }
    { $_ -in 'budget', 'budget_remove' } {
        if ($nv['turnstile-integration'] -match '(governanceAuthority|budgetAuthority)=Turnstile') {
            throw 'Turnstile owns these budgets. Use the Turnstile backend to prevent an overwrite.'
        }
        if ($request.parameters.scope_type -eq 'user') {
            $personId = [guid]::Empty
            if (-not [guid]::TryParse([string]$request.parameters.scope_id, [ref]$personId)) {
                throw 'Use the person object id observed in the ledger; AUM does not scan the directory.'
            }
            if (-not $nv.ContainsKey('quota-overrides')) { throw 'This gateway does not expose daily person overrides.' }
            $personMap = ConvertFrom-ClaudeBudgetOverrides $nv['quota-overrides']
            $personArgs = @{ User=[string]$personId; ResourceGroup=$ResourceGroup; ApimName=$ApimName }
            if ($request.action -eq 'budget_remove') {
                $personMap.Remove([string]$personId)
                $personArgs.Clear = $true
            }
            else {
                $personMap[[string]$personId] = [long]$request.body.token_limit
                $personArgs.Tokens = [long]$request.body.token_limit
            }
            $expected = @{ 'quota-overrides'=(ConvertTo-ClaudeBudgetOverrides $personMap) }
            $result = Invoke-VerifiedChange $expected {
                & (Join-Path $PSScriptRoot 'Set-ClaudeBudget.ps1') @personArgs 6>$null | Out-Null
            }
            $result.budget_period = 'day'
            break
        }
        $id = [string]$request.parameters.scope_id
        Test-ClaudeBuId $id
        if ($request.parameters.scope_type -notin 'organization', 'department') { throw 'Only unit and team budgets are direct gateway limits.' }
        $row = @($registry | Where-Object Id -eq $id)
        if ($row.Count -ne 1) { throw 'Scope not found in the gateway registry.' }
        $isTeam = $parents.Contains($id)
        if (($request.parameters.scope_type -eq 'department') -ne $isTeam) { throw 'Scope kind does not match the registry.' }
        if ($request.action -eq 'budget_remove') {
            $row[0].TokensPerMonth = [long]0
        }
        else {
            $amount = [long]$request.body.token_limit
            if ($amount -lt 1) { throw 'The budget must be positive.' }
            $row[0].TokensPerMonth = $amount
        }
        foreach ($unit in @($registry | Where-Object { -not $parents.Contains([string]$_.Id) })) {
            $allocated = [long]0
            foreach ($child in @($registry | Where-Object { $parents[[string]$_.Id] -eq [string]$unit.Id })) {
                $allocated += [long]$child.TokensPerMonth
            }
            if ($unit.TokensPerMonth -gt 0 -and $allocated -gt $unit.TokensPerMonth) { throw 'Children exceed the parent budget.' }
        }
        $raw = ConvertTo-ClaudeBuRegistry $registry
        $result = Invoke-VerifiedChange @{ 'bu-registry'=$raw } {
            Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry' -Value $raw | Out-Null
        }
        $result.effect = 'Named value read-back verified; gateway cache may still be stale.'
    }
    'tiers' {
        if ($nv['turnstile-integration'] -match 'governanceAuthority=Turnstile') { throw 'Turnstile owns tiers. Use its backend.' }
        $expected = [ordered]@{}
        foreach ($tier in @($request.body.tiers)) {
            if ($tier.id -notin @('standard','premium')) { throw 'Unknown gateway tier.' }
            $expected["tpm-$($tier.id)"] = [string]$tier.tokens_per_minute
            $expected["quota-$($tier.id)"] = [string]$tier.tokens_per_day
            $expected["models-$($tier.id)"] = $(if (@($tier.models).Count) { ',' + ($tier.models -join ',') + ',' } else { ',,' })
        }
        $result = Invoke-VerifiedChange $expected {
            foreach ($tier in @($request.body.tiers)) {
                & (Join-Path $PSScriptRoot 'Set-ClaudeTier.ps1') -Tier $tier.id -TokensPerMinute $tier.tokens_per_minute `
                    -DailyQuota $tier.tokens_per_day -Models ($tier.models -join ',') -ResourceGroup $ResourceGroup -ApimName $ApimName 6>$null | Out-Null
            }
        }
        $result.effect = 'All requested tier values read back exactly.'
    }
    'mode' {
        if ($nv['turnstile-integration'] -match 'governanceAuthority=Turnstile') { throw 'Turnstile owns modes. Use its backend.' }
        if (-not $nv.ContainsKey('bu-modes')) { throw 'Upgrade the gateway mode policy before editing modes.' }
        $modeArgs = @{
            Id = [string]$request.parameters.scope_id
            Mode = [string]$request.body.mode
            ResourceGroup = $ResourceGroup
            ApimName = $ApimName
        }
        if ($null -ne $request.body.allowance_percent) { $modeArgs.AllowancePercent = [int]$request.body.allowance_percent }
        $target = @($registry | Where-Object Id -eq $modeArgs.Id)
        if ($target.Count -ne 1) { throw 'Scope not found.' }
        $expectedMode = ConvertTo-ClaudeBudgetMode $request.body.mode $request.body.allowance_percent
        $modes.Remove($modeArgs.Id)
        if ($expectedMode -ne 'strict') { $modes[$modeArgs.Id] = $expectedMode }
        $reordered = @($registry | Where-Object Id -ne $modeArgs.Id) + $target
        $expected = [ordered]@{
            'bu-registry'=(ConvertTo-ClaudeBuRegistry $reordered)
            'bu-modes'=(ConvertTo-ClaudeBuModes $modes)
        }
        if ($nv.ContainsKey('bu-parents')) { $expected['bu-parents'] = ConvertTo-ClaudeBuParents $parents }
        $result = Invoke-VerifiedChange $expected {
            & (Join-Path $PSScriptRoot 'Set-ClaudeBusinessUnit.ps1') @modeArgs 6>$null | Out-Null
        }
        $result.attributes = Get-ClaudeBudgetModeAttributes -Id $modeArgs.Id -Modes $modes
    }
    'catalog' {
        if ($nv['turnstile-integration'] -match 'governanceAuthority=Turnstile') { throw 'Turnstile owns the catalog. Use its backend.' }
        $wanted = @($request.body.organizations) + @($request.body.departments | Where-Object { $_.attributes.kind -ne 'unit-direct' })
        if (-not @($request.body.organizations).Count) { throw 'Keep at least one unit.' }
        $nextRegistry = @()
        $nextParents = [ordered]@{}
        $seen = @{}
        foreach ($item in $wanted) {
            Test-ClaudeBuId ([string]$item.id)
            if ($seen.ContainsKey([string]$item.id)) { throw 'Duplicate scope identifier.' }
            $seen[[string]$item.id] = $true
            if ([string]$item.external_ref -notlike 'entra-group:*') { throw 'Every direct scope needs an Entra group.' }
            if ($item.attributes.manager_group_id -or $item.attributes.manager_group) { throw 'Manager groups require the optional AUM service or Turnstile authority.' }
            $group = ([string]$item.external_ref).Substring(12)
            if ($group -match '[,:=&|<>^%!"\r\n]') { throw 'Group contains unsafe registry or shell characters.' }
            $groupId = az ad group show --group $group --query id -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $groupId) { throw 'An Entra group could not be verified. Nothing was written.' }
            $prior = @($registry | Where-Object Id -eq $item.id)
            $amount = if ($prior.Count) { [long]$prior[0].TokensPerMonth } else { [long]0 }
            $nextRegistry += [pscustomobject]@{ Id = [string]$item.id; Group = $group; TokensPerMonth = $amount }
            if ($item.parent_id) {
                if ([string]$item.parent_id -notin @($request.body.organizations.id)) { throw 'Team parent is not a unit.' }
                $nextParents[[string]$item.id] = [string]$item.parent_id
            }
        }
        Test-ClaudeBuDepth -Parents $nextParents
        foreach ($unit in @($nextRegistry | Where-Object { -not $nextParents.Contains([string]$_.Id) })) {
            $allocated = [long]0
            foreach ($child in @($nextRegistry | Where-Object { $nextParents[[string]$_.Id] -eq [string]$unit.Id })) {
                $allocated += [long]$child.TokensPerMonth
            }
            if ($unit.TokensPerMonth -gt 0 -and $allocated -gt $unit.TokensPerMonth) { throw 'Moving these teams would exceed parent headroom.' }
        }
        $nextRaw = ConvertTo-ClaudeBuRegistry $nextRegistry
        $parentRaw = ConvertTo-ClaudeBuParents $nextParents
        Test-ApimNamedValueLength -Id 'bu-registry' -Value $nextRaw
        Test-ApimNamedValueLength -Id 'bu-parents' -Value $parentRaw
        $expected = [ordered]@{ 'bu-registry'=$nextRaw; 'bu-parents'=$parentRaw }
        if ($nv.ContainsKey('bu-modes')) {
            foreach ($modeId in @($modes.Keys)) {
                if ($modeId -notin @($nextRegistry.Id)) { $modes.Remove($modeId) }
            }
            $expected['bu-modes'] = ConvertTo-ClaudeBuModes $modes
        }
        $result = Invoke-VerifiedChange $expected {
            foreach ($key in $expected.Keys) {
                if ($expected[$key] -cne $nv[$key]) {
                    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $key -Value $expected[$key] | Out-Null
                }
            }
        }
        $result.effect = 'Registry and related values read back. New scopes have no budget until explicitly assigned.'
    }
    default { throw 'Unsupported bridge action.' }
}
$result | ConvertTo-Json -Depth 30 -Compress
