<#
.SYNOPSIS
    JSON bridge for claude-finops. Reuses the gateway's registry implementation.
.DESCRIPTION
    Reads named values without secrets. Mutations are explicit, use the existing
    serializers and tier script, and never accept PowerShell code in the input.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
$request = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
$values = @(az apim nv list -g $ResourceGroup --service-name $ApimName -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read gateway named values. Check Azure RBAC.' }
$nv = @{}
foreach ($value in $values) {
    if (-not $value.secret) { $nv[[string]$value.name] = [string]$value.value }
}
$registry = @(ConvertFrom-ClaudeBuRegistry $nv['bu-registry'])
$parents = ConvertFrom-ClaudeBuParents $nv['bu-parents']
$result = $null

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
        $catalog = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents
        $result = [ordered]@{
            catalog = $catalog; tiers = @($tiers)
            registry = @($registry); parents = $parents
            quota_org = [long]$nv['quota-org']
            authority = $(if ($nv['turnstile-integration'] -match 'governanceAuthority=Turnstile') { 'Turnstile' } else { 'Gateway' })
        }
    }
    { $_ -in 'budget', 'budget_remove' } {
        if ($nv['turnstile-integration'] -match '(governanceAuthority|budgetAuthority)=Turnstile') {
            throw 'Turnstile owns these budgets. Use the Turnstile backend to prevent an overwrite.'
        }
        $id = [string]$request.parameters.scope_id
        Test-ClaudeBuId $id
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
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry' -Value $raw | Out-Null
        $actual = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'
        if ($actual -ne $raw) { throw 'Registry read-back did not match. Refresh before retrying.' }
        $result = @{ verified = $true; effect = 'Named value read-back verified; gateway cache may still be stale.' }
    }
    'tiers' {
        if ($nv['turnstile-integration'] -match 'governanceAuthority=Turnstile') { throw 'Turnstile owns tiers. Use its backend.' }
        foreach ($tier in @($request.body.tiers)) {
            & (Join-Path $PSScriptRoot 'Set-ClaudeTier.ps1') -Tier $tier.id -TokensPerMinute $tier.tokens_per_minute `
                -DailyQuota $tier.tokens_per_day -Models ($tier.models -join ',') -ResourceGroup $ResourceGroup -ApimName $ApimName 6>$null | Out-Null
        }
        $result = @{ verified = $true; effect = 'Tier script completed. Read tier show to verify limits.' }
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
            if ($item.attributes.manager_group) { throw 'Manager group authoring requires Turnstile.' }
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
        $nextRaw = ConvertTo-ClaudeBuRegistry $nextRegistry
        $parentRaw = ConvertTo-ClaudeBuParents $nextParents
        Test-ApimNamedValueLength -Id 'bu-registry' -Value $nextRaw
        Test-ApimNamedValueLength -Id 'bu-parents' -Value $parentRaw
        if ($nextRaw -ne $nv['bu-registry']) {
            Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry' -Value $nextRaw | Out-Null
        }
        if ($parentRaw -ne $nv['bu-parents']) {
            Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents' -Value $parentRaw | Out-Null
        }
        $result = @{ verified = $true; effect = 'Registry written using shared serializers. New scopes have no budget; set one explicitly. Display names are Entra group names.' }
    }
    default { throw 'Unsupported bridge action.' }
}
$result | ConvertTo-Json -Depth 30 -Compress
