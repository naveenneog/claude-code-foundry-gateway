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
if ($Subscription) {
    $parsedSubscription = [guid]::Empty
    if (-not [guid]::TryParse($Subscription, [ref]$parsedSubscription)) { throw 'Subscription must be an object id.' }
    $aumDirectAzureExecutable = @(Get-Command az -CommandType Application -ErrorAction Stop)[0].Source
    $aumDirectSubscription = $Subscription
    function az {
        & $aumDirectAzureExecutable @args --subscription $aumDirectSubscription
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBudgetOverride.ps1')
. (Join-Path $PSScriptRoot 'ClaudeAumDirectWrites.ps1')
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

switch ([string]$request.action) {
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
        }
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
