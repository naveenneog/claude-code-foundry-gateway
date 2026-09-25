# Set-* must refuse only the values Turnstile's apply would overwrite.
# Offline: every Azure CLI, ARM and Graph call is intercepted, including writes.
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] unexpected error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$personId = '00000000-0000-0000-0000-000000000001'
$otherId = '00000000-0000-0000-0000-000000000002'
$groupId = '00000000-0000-0000-0000-000000000003'
$origin = 'https://turnstile.example.com'
function Reset-Gateway([string]$Integration = '', [string]$ReadError = '') {
    $script:gateway = @{
        Integration = $Integration; ReadError = $ReadError
        Reads = New-Object 'System.Collections.Generic.List[string]'
        Writes = New-Object 'System.Collections.Generic.List[string]'
        Members = New-Object 'System.Collections.Generic.List[string]'
        GroupWrites = New-Object 'System.Collections.Generic.List[string]'
        Values = @{
            'bu-registry' = ',sales=Sales:1000,platform=Platform:2000,'
            'bu-parents' = ',,'; 'bu-modes' = ',,'
            'tpm-standard' = '100'; 'quota-standard' = '1000'; 'models-standard' = ',,'
            'tpm-premium' = '200'; 'quota-premium' = '2000'; 'models-premium' = ',,'
            'allow-standard' = ",$personId,"; 'allow-premium' = ',,'
            'quota-overrides' = ",$personId=1000,$otherId=2000,"
        }
    }
}
function az {
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'account show*') { return '00000000-0000-0000-0000-000000000000' }
    if ($line -like 'account get-access-token*') { return 'fixture-token' }
    if ($line -like 'ad group show*') { return $groupId }
    if ($line -like 'apim nv show*') {
        $id = [string]$args[[array]::IndexOf($args, '--named-value-id') + 1]
        $gateway.Reads.Add($id)
        if ($id -eq 'turnstile-integration') {
            if ($gateway.ReadError -eq 'throw') { throw 'CLI could not start' }
            if ($gateway.ReadError) {
                $global:LASTEXITCODE = 3
                Write-Error $gateway.ReadError -ErrorAction Continue
                return
            }
            return $gateway.Integration
        }
        if ($line -like '*--query name*') {
            if ($gateway.Values.ContainsKey($id)) { return $id }
            return
        }
        return $gateway.Values[$id]
    }
    if ($line -match '^apim nv (update|create) ') {
        $id = [string]$args[[array]::IndexOf($args, '--named-value-id') + 1]
        $gateway.Writes.Add($id)
        $gateway.Values[$id] = [string]$args[[array]::IndexOf($args, '--value') + 1]
        return
    }
    throw "Unexpected az call: $line"
}
function Invoke-RestMethod {
    param($Uri, $Method = 'Get', $Headers, $Body, $ContentType)
    if ($Uri -match '/namedValues/([^?]+)') {
        $id = $Matches[1]
        if ($Method -eq 'Put') {
            $gateway.Writes.Add($id)
            $gateway.Values[$id] = ($Body | ConvertFrom-Json).properties.value
        }
        elseif ($Method -ne 'Get') { throw "Unexpected ARM method: $Method" }
        return [pscustomobject]@{ properties = @{ value = $gateway.Values[$id] } }
    }
    if ($Uri -match '/users/[^/]+/memberOf\?') {
        return @{ value = @($gateway.Members | ForEach-Object { @{ id = $_ } }) }
    }
    if ($Uri -match '/users/[^/]+\?') {
        return @{ id = $personId; displayName = 'Example Developer'; userPrincipalName = 'developer@example.com' }
    }
    if ($Uri -match '/groups/([^/]+)/members/' -and $Method -in 'Post', 'Delete') {
        $gateway.GroupWrites.Add("$Method $($Matches[1])")
        if ($Method -eq 'Post') { $gateway.Members.Add($Matches[1]) }
        else { [void]$gateway.Members.Remove($Matches[1]) }
        return
    }
    throw "Unexpected HTTP call: $Method $Uri"
}
function Invoke-Set([string]$Name, [hashtable]$Parameters) {
    try {
        & (Join-Path $root "scripts\$Name.ps1") @Parameters -ResourceGroup rg-test -ApimName apim-test *> $null
        return ''
    }
    catch { return $_.Exception.Message }
}
function Assert-Refusal([string]$Label, [string]$Message, [string]$Page) {
    Assert "$Label refuses before any write" ($Message -match 'Turnstile owns' -and $gateway.Writes.Count -eq 0 -and $gateway.GroupWrites.Count -eq 0) $Message
    Assert "$Label names Turnstile's URL and page" ($Message.Contains($origin) -and $Message.Contains($Page)) $Message
    Assert "$Label names the explicit authority switch" ($Message -match 'Connect-ClaudeTurnstile\.ps1' -and $Message -match '-GovernanceAuthority Gateway' -and $Message -match '-BudgetAuthority Gateway' -and $Message -match 'rg-test' -and $Message -match 'apim-test') $Message
}

$missing = 'ERROR: (ResourceNotFound) NamedValue not found. Code: ResourceNotFound'
$full = "url=$origin;governanceAuthority=Turnstile;budgetAuthority=Gateway;personBudgets=false"
$budgetOnly = "url=$origin;governanceAuthority=Gateway;budgetAuthority=Turnstile;personBudgets=false"
$local = "url=$origin;governanceAuthority=Gateway;budgetAuthority=Gateway;personBudgets=false"

Write-Host 'Authority - gateway-owned and disconnected writes' -ForegroundColor Cyan
foreach ($case in @(
    @{ Name = 'absent connection'; Value = ''; Error = $missing },
    @{ Name = 'explicit disconnect'; Value = ' '; Error = '' },
    @{ Name = 'Gateway authority'; Value = $local; Error = '' },
    @{ Name = 'legacy Gateway defaults'; Value = "url=$origin;budgetAuthority=Gateway"; Error = '' }
)) {
    Reset-Gateway $case.Value $case.Error
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'sales'; MonthlyBudgetUsd = 1 }
    Assert "$($case.Name): unit budget is written" (-not $m -and $gateway.Writes -contains 'bu-registry' -and $gateway.Values['bu-registry'] -notmatch 'sales=Sales:1000,') $m
    Reset-Gateway $case.Value $case.Error
    $m = Invoke-Set 'Set-ClaudeTier' @{ Tier = 'standard'; TokensPerMinute = 300; DailyQuota = 4000; Models = 'example-model'; SkipModelCheck = $true }
    Assert "$($case.Name): all tier settings are written" (-not $m -and $gateway.Writes.Count -eq 3 -and $gateway.Values['tpm-standard'] -eq '300' -and $gateway.Values['quota-standard'] -eq '4000' -and $gateway.Values['models-standard'] -eq ',example-model,') $m
}

Write-Host 'Authority - Turnstile owns governance' -ForegroundColor Cyan
foreach ($operation in @(
    @{ Name = 'group'; Params = @{ Id = 'sales'; Group = 'New Sales' } },
    @{ Name = 'parent'; Params = @{ Id = 'sales'; Parent = 'platform' } },
    @{ Name = 'mode'; Params = @{ Id = 'sales'; Mode = 'Notify' } },
    @{ Name = 'budget'; Params = @{ Id = 'sales'; MonthlyBudgetUsd = 1 } },
    @{ Name = 'mixed edit'; Params = @{ Id = 'sales'; Group = 'New Sales'; MonthlyBudgetUsd = 1; Mode = 'Notify' } },
    @{ Name = 'create'; Params = @{ Id = 'new-team'; Group = 'New Team'; Parent = 'platform'; MonthlyBudgetUsd = 1 } },
    @{ Name = 'remove'; Params = @{ Id = 'sales'; Remove = $true } }
)) {
    Reset-Gateway $full
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' $operation.Params
    Assert-Refusal "unit $($operation.Name)" $m 'Gateway governance'
}
foreach ($parameters in @(
    @{ Tier = 'standard'; TokensPerMinute = 300 },
    @{ Tier = 'premium'; DailyQuota = 4000 },
    @{ Tier = 'standard'; Models = 'example-model'; SkipModelCheck = $true }
)) {
    Reset-Gateway $full
    $m = Invoke-Set 'Set-ClaudeTier' $parameters
    Assert-Refusal "tier $(@($parameters.Keys) -join ',')" $m 'Gateway governance'
    Assert 'tier refusal names tiers' ($m -match '(?i)tiers') $m
}
Reset-Gateway ($full.Replace('Turnstile', 'turnstile'))
$m = Invoke-Set 'Set-ClaudeTier' @{ Tier = 'standard'; TokensPerMinute = 300 }
Assert 'authority matches the apply case-insensitively' ($m -match 'Turnstile owns' -and $gateway.Writes.Count -eq 0) $m
Reset-Gateway ($full.Replace($origin, ''))
$m = Invoke-Set 'Set-ClaudeTier' @{ Tier = 'standard'; TokensPerMinute = 300 }
Assert 'an unrecorded URL still gives the portal path' ($m -match 'Turnstile owns' -and $m -match 'Gateway governance' -and $gateway.Writes.Count -eq 0) $m

Write-Host 'Authority - budgets only' -ForegroundColor Cyan
foreach ($parameters in @(
    @{ Id = 'sales'; MonthlyBudgetUsd = 1 },
    @{ Id = 'sales'; Group = 'New Sales'; MonthlyBudgetUsd = 1 },
    @{ Id = 'sales'; MonthlyBudgetUsd = 0 },
    @{ Id = 'new-team'; Group = 'New Team'; MonthlyBudgetUsd = 1 }
)) {
    Reset-Gateway $budgetOnly
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' $parameters
    Assert-Refusal 'monthly budget under budget-only authority' $m 'Budgets'
    Assert 'budget refusal names monthly budgets' ($m -match '(?i)monthly budgets') $m
}
foreach ($operation in @(
    @{ Name = 'group'; Params = @{ Id = 'sales'; Group = 'New Sales' }; Value = 'bu-registry'; Pattern = 'sales=New Sales:1000' },
    @{ Name = 'parent'; Params = @{ Id = 'sales'; Parent = 'platform' }; Value = 'bu-parents'; Pattern = 'sales=platform' },
    @{ Name = 'mode'; Params = @{ Id = 'sales'; Mode = 'Notify' }; Value = 'bu-modes'; Pattern = 'sales=notify' },
    @{ Name = 'remove'; Params = @{ Id = 'sales'; Remove = $true }; Value = 'bu-registry'; Pattern = '^,platform=Platform:2000,$' }
)) {
    Reset-Gateway $budgetOnly
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' $operation.Params
    Assert "budget-only authority permits $($operation.Name)" (-not $m -and $gateway.Writes.Count -gt 0 -and $gateway.Values[$operation.Value] -match $operation.Pattern) $m
}
Reset-Gateway $budgetOnly
$m = Invoke-Set 'Set-ClaudeTier' @{ Tier = 'standard'; TokensPerMinute = 300; DailyQuota = 4000; Models = 'example-model'; SkipModelCheck = $true }
Assert 'budget-only authority permits every tier setting' (-not $m -and $gateway.Writes.Count -eq 3) $m

Write-Host 'Authority - reads fail closed, not disconnected' -ForegroundColor Cyan
foreach ($errorText in @(
    'ERROR: (AuthorizationFailed) Not authorized to read named values.',
    'ERROR: (ResourceGroupNotFound) Resource group not found.',
    "ERROR: (ResourceNotFound) The resource 'Microsoft.ApiManagement/service/apim-test' was not found.",
    'ERROR: (TooManyRequests) Retry later.',
    'Connection timed out.', 'throw'
)) {
    foreach ($command in 'Set-ClaudeBusinessUnit', 'Set-ClaudeTier') {
        Reset-Gateway '' $errorText
        $parameters = if ($command -eq 'Set-ClaudeTier') { @{ Tier = 'standard'; TokensPerMinute = 300 } } else { @{ Id = 'sales'; MonthlyBudgetUsd = 1 } }
        $m = Invoke-Set $command $parameters
        Assert "$command stops on $errorText" ($m -match 'turnstile-integration' -and $m -match '(?i)cannot|could not' -and $m -match '(?i)nothing was written' -and $gateway.Writes.Count -eq 0) $m
    }
}
foreach ($invalid in @(
    'not an integration value',
    'governanceAuthority=Turnstile',
    "url=$origin;governanceAuthority=Unknown",
    "url=$origin;budgetAuthority=Unknown",
    "version=broken;url=$origin"
)) {
    Reset-Gateway $invalid
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'sales'; MonthlyBudgetUsd = 1 }
    Assert 'an invalid nonempty connection cannot grant write authority' ($m -match 'turnstile-integration' -and $gateway.Writes.Count -eq 0) $m
}

# Native stderr used to terminate a read early on Windows PowerShell 5.1.
# Exercise the real native-command boundary as well as the fast az mocks.
& {
    . (Join-Path $root 'scripts\ApimNamedValue.ps1')
    function az { & node --eval $nativeScript }
    $nativeScript = "process.stderr.write('ERROR: (ResourceNotFound) NamedValue not found.\n');process.exit(3)"
    $m = ''
    $value = 'not read'
    try { $value = Get-ApimNamedValue -ResourceGroup rg-test -ApimName apim-test -Id turnstile-integration -FailOnError }
    catch { $m = $_.Exception.Message }
    Assert 'native missing-named-value stderr means disconnected on both hosts' (-not $m -and $null -eq $value) $m
    $nativeScript = "process.stderr.write('ERROR: (AuthorizationFailed) Access denied.\n');process.exit(1)"
    $m = ''
    try { Get-ApimNamedValue -ResourceGroup rg-test -ApimName apim-test -Id turnstile-integration -FailOnError | Out-Null }
    catch { $m = $_.Exception.Message }
    Assert 'native authorization stderr is a failed read on both hosts' ($m -match 'Could not read' -and $m -match 'turnstile-integration') $m
}

Write-Host 'Authority - list modes and non-owned writes remain usable' -ForegroundColor Cyan
foreach ($command in 'Set-ClaudeBusinessUnit', 'Set-ClaudeTier', 'Set-ClaudeBudget') {
    foreach ($errorText in '', 'Connection timed out.') {
        Reset-Gateway $full $errorText
        $m = Invoke-Set $command @{ List = $true }
        Assert "$command lists without authority checks ($errorText)" (-not $m -and $gateway.Writes.Count -eq 0 -and $gateway.Reads -notcontains 'turnstile-integration') $m
    }
}
Reset-Gateway $full
$m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'absent'; Remove = $true }
Assert 'removing an absent unit remains a no-op' (-not $m -and $gateway.Writes.Count -eq 0) $m

# personBudgets mirrors daily tier ceilings TO Turnstile. Neither apply path
# writes quota-overrides, and neither edits Entra membership.
foreach ($integration in '', $local, $full, $budgetOnly, $full.Replace('false', 'true'), $budgetOnly.Replace('false', 'true')) {
    foreach ($parameters in @(
        @{ User = $personId; Tokens = 3000 },
        @{ User = $personId; DailyUsd = 1 },
        @{ User = $personId; Clear = $true }
    )) {
        Reset-Gateway $integration
        $m = Invoke-Set 'Set-ClaudeBudget' $parameters
        Assert 'personal daily overrides stay gateway-owned' (-not $m -and $gateway.Writes.Count -eq 1 -and $gateway.Writes[0] -eq 'quota-overrides' -and $gateway.Values['quota-overrides'].Contains("$otherId=2000")) $m
    }
    Reset-Gateway $integration
    $m = Invoke-Set 'Set-ClaudeDeveloper' @{ User = $personId; Tier = 'standard'; BusinessUnit = 'sales' }
    Assert 'Entra membership edits remain allowed, not competing named-value writes' (-not $m -and $gateway.GroupWrites.Count -gt 0 -and $gateway.Writes.Count -eq 0) $m
}

Write-Host ''
if ($fail) { Write-Host "$fail authority assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Governance authority contract holds.' -ForegroundColor Green
exit 0
