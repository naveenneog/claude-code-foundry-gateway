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
            'usd-budgets' = 'e30='; 'usd-budget-state' = 'e30='
        }
    }
}
function az {
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'account show*') { return '00000000-0000-0000-0000-000000000000' }
    if ($line -like 'account get-access-token*') { return 'fixture-token' }
    if ($line -like 'ad group show*') { return $groupId }
    if ($line -like 'apim nv list*') {
        return ConvertTo-Json -InputObject @($gateway.Values.Keys | ForEach-Object {
            [pscustomobject]@{ name = $_; value = $gateway.Values[$_]; secret = $false }
        })
    }
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
function Invoke-WebRequest {
    param($Uri, $Method = 'Get', $Headers, $Body, $ContentType, [switch]$UseBasicParsing)
    if ($Uri -notmatch '/namedValues/usd-budgets\?') { throw "Unexpected USD HTTP call: $Method $Uri" }
    if ($Method -eq 'Put') {
        $text = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
        $gateway.Values['usd-budgets'] = ($text | ConvertFrom-Json).properties.value
        $gateway.Writes.Add('usd-budgets')
    }
    elseif ($Method -ne 'Get') { throw "Unexpected USD method: $Method" }
    return [pscustomobject]@{ Headers = @{ ETag = '"fixture-1"' }
        Content = (@{ properties = @{ displayName = 'usd-budgets'; value = $gateway.Values['usd-budgets']; secret = $false } } | ConvertTo-Json -Depth 5) }
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

# P96: a new identifier with a capital passed the business-unit check and then stopped at the dollar budget
# with "Invalid USD scope identifier." (scripts/ClaudeUsdBudgets.ps1:42). It is refused with the rule, before
# any write, and a capitalised spelling of a stored identifier is not taken as that unit.
Write-Host 'Business unit identifiers - a new identifier is lower-case (P96)' -ForegroundColor Cyan
Reset-Gateway $local
$m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'Platform-Two'; Group = 'Platform Two'; MonthlyBudgetUsd = 1 }
Assert 'a new identifier with a capital is refused with the lower-case rule, before any write' ($m -match "'Platform-Two' is not a valid business unit identifier" -and $m -match 'lower-case letters' -and
    $gateway.Writes.Count -eq 0 -and $gateway.GroupWrites.Count -eq 0) "$m | writes $($gateway.Writes -join ',')"
Reset-Gateway $local
$m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'Sales'; MonthlyBudgetUsd = 1 }
Assert 'a capitalised spelling of a stored identifier is refused, not used to change that unit' ($m -match "'Sales' is not a valid business unit identifier" -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',')"
Reset-Gateway $local
$m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'sales'; Parent = 'Platform' }
Assert 'a capitalised spelling of a stored parent is refused, not written as the parent' ($m -match "'Platform' is not a valid business unit identifier" -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',')"
# Before P96 the check ignored case, so a registry can hold an identifier with capitals. Changes that do not
# touch its dollar budget keep working when the registry holds that exact spelling.
$legacyRegistry = ',sales=Sales:1000,Legacy-Unit=Legacy:3000,'
Reset-Gateway $local
$gateway.Values['bu-registry'] = $legacyRegistry
$m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'Legacy-Unit'; Group = 'Legacy Renamed' }
Assert 'a unit the registry holds with capitals can still change its group' (-not $m -and $gateway.Values['bu-registry'] -ceq ',sales=Sales:1000,Legacy-Unit=Legacy Renamed:3000,') "$m | registry $($gateway.Values['bu-registry'])"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $legacyRegistry
$m = Invoke-Set 'Set-ClaudeBusinessUnit' @{ Id = 'sales'; Parent = 'Legacy-Unit' }
Assert 'a unit the registry holds with capitals can still be a parent' (-not $m -and $gateway.Values['bu-parents'] -ceq ',sales=Legacy-Unit,') "$m | parents $($gateway.Values['bu-parents'])"
# Council round 1 (Architect): the same identifier in another case is not the stored unit. Changing, removing or
# naming it as a parent through that spelling is refused before any write, rather than acting on 'Legacy-Unit'.
foreach ($case in @(
        @{ Name = 'a change of group'; P = @{ Id = 'legacy-unit'; Group = 'Legacy Renamed' } }
        @{ Name = 'a removal'; P = @{ Id = 'legacy-unit'; Remove = $true } }
        @{ Name = 'a parent'; P = @{ Id = 'sales'; Parent = 'legacy-unit' } }
    )) {
    Reset-Gateway $local
    $gateway.Values['bu-registry'] = $legacyRegistry
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' $case.P
    Assert "the lower-case spelling of a unit stored with capitals is refused for $($case.Name), before any write" ($m -match 'differs only in case' -and $m.Contains("'Legacy-Unit'") -and
        $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',') | registry $($gateway.Values['bu-registry'])"
}
# Council round 1 (QA): a registry can hold two spellings of one identifier (before P96, through Turnstile or a
# manual edit). They are two units: a change to one leaves the other, its budget and its team as they are.
# bu-parents is read without case, as the renewal job reads it (sync/src/business-units.mjs), so these cases keep
# the two spellings out of bu-parents' keys.
$unitSpellings = ',sales=Lower Sales:1000,Sales=Upper Sales:2000,eu=EU:100,'
foreach ($case in @(
        @{ Name = 'a change of group'; P = @{ Id = 'Sales'; Group = 'New Sales' }
            WantRegistry = ',sales=Lower Sales:1000,eu=EU:100,Sales=New Sales:2000,'; WantParents = ',eu=sales,' }
        @{ Name = 'the removal of one'; P = @{ Id = 'Sales'; Remove = $true }
            WantRegistry = ',sales=Lower Sales:1000,eu=EU:100,'; WantParents = ',eu=sales,' }
    )) {
    Reset-Gateway $local
    $gateway.Values['bu-registry'] = $unitSpellings
    $gateway.Values['bu-parents'] = ',eu=sales,'
    $m = Invoke-Set 'Set-ClaudeBusinessUnit' $case.P
    Assert "two spellings of one identifier stay two units after $($case.Name)" (-not $m -and $gateway.Values['bu-registry'] -ceq $case.WantRegistry -and $gateway.Values['bu-parents'] -ceq $case.WantParents) "$m | registry $($gateway.Values['bu-registry']) | parents $($gateway.Values['bu-parents'])"
}

function Invoke-Bridge([hashtable]$Request) {
    $file = Join-Path ([IO.Path]::GetTempPath()) ('p96-bridge-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $Request | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $file -Encoding UTF8
        $json = & (Join-Path $root 'scripts\Invoke-ClaudeFinOps.ps1') -InputFile $file -ResourceGroup rg-test -ApimName apim-test 6>$null
        return [string](($json | ConvertFrom-Json).error)
    }
    finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
}
function New-BridgeUnit([string]$Id, [string]$Group) { @{ id = $Id; external_ref = "entra-group:$Group"; attributes = @{} } }
Reset-Gateway $local
$gateway.Values['bu-registry'] = $legacyRegistry
$m = Invoke-Bridge @{ action = 'budget'; parameters = @{ scope_type = 'organization'; scope_id = 'Legacy-Unit' }; body = @{ token_limit = 4000 } }
Assert 'the AUM bridge still sets the budget of a unit the registry holds with capitals' (-not $m -and $gateway.Values['bu-registry'] -ceq ',sales=Sales:1000,Legacy-Unit=Legacy:4000,') "$m | registry $($gateway.Values['bu-registry'])"
Reset-Gateway $local
$m = Invoke-Bridge @{ action = 'budget'; parameters = @{ scope_type = 'organization'; scope_id = 'Sales' }; body = @{ token_limit = 4000 } }
Assert 'the AUM bridge refuses a capitalised spelling of a stored unit before any write' ($m -match "'Sales' is not a valid business unit identifier" -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',')"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $legacyRegistry
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @((New-BridgeUnit 'sales' 'Sales'), (New-BridgeUnit 'Legacy-Unit' 'Legacy Renamed')); departments = @() } }
Assert 'the AUM catalog keeps a unit the registry holds with capitals' (-not $m -and $gateway.Values['bu-registry'] -ceq ',sales=Sales:1000,Legacy-Unit=Legacy Renamed:3000,') "$m | registry $($gateway.Values['bu-registry'])"
Reset-Gateway $local
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @((New-BridgeUnit 'sales' 'Sales'), (New-BridgeUnit 'platform' 'Platform'), (New-BridgeUnit 'NewUnit' 'New Unit')); departments = @() } }
Assert 'the AUM catalog refuses a new identifier with a capital before any write' ($m -match "'NewUnit' is not a valid business unit identifier" -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',')"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $legacyRegistry
$m = Invoke-Bridge @{ action = 'budget'; parameters = @{ scope_type = 'organization'; scope_id = 'legacy-unit' }; body = @{ token_limit = 4000 } }
Assert 'the AUM bridge refuses the lower-case spelling of a unit stored with capitals before any write' ($m -match 'differs only in case' -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',')"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $legacyRegistry
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @((New-BridgeUnit 'sales' 'Sales'), (New-BridgeUnit 'legacy-unit' 'Legacy')); departments = @() } }
Assert 'the AUM catalog does not rename a unit stored with capitals to another spelling' ($m -match 'differs only in case' -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',') | registry $($gateway.Values['bu-registry'])"
# Council round 1 (QA): with two spellings stored, the AUM bridge acts on the exact one.
$bridgeSpellings = ',platform=Platform:5000,sales=Lower Sales:1000,Sales=Upper Sales:2000,'
Reset-Gateway $local
$gateway.Values['bu-registry'] = $bridgeSpellings
$m = Invoke-Bridge @{ action = 'budget'; parameters = @{ scope_type = 'organization'; scope_id = 'Sales' }; body = @{ token_limit = 4000 } }
Assert 'the AUM bridge sets the budget of the exact spelling when the registry holds two' (-not $m -and $gateway.Values['bu-registry'] -ceq ',platform=Platform:5000,sales=Lower Sales:1000,Sales=Upper Sales:4000,') "$m | registry $($gateway.Values['bu-registry'])"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $bridgeSpellings
$m = Invoke-Bridge @{ action = 'mode'; parameters = @{ scope_id = 'sales' }; body = @{ mode = 'notify' } }
Assert 'the AUM bridge sets the mode of the exact spelling when the registry holds two' (-not $m -and $gateway.Values['bu-modes'] -ceq ',sales=notify,' -and
    $gateway.Values['bu-registry'] -cmatch ',sales=Lower Sales:1000,' -and $gateway.Values['bu-registry'] -cmatch ',Sales=Upper Sales:2000,') "$m | registry $($gateway.Values['bu-registry']) | modes $($gateway.Values['bu-modes'])"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $bridgeSpellings
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @((New-BridgeUnit 'platform' 'Platform'), (New-BridgeUnit 'sales' 'Lower Sales'), (New-BridgeUnit 'Sales' 'Upper Sales')); departments = @() } }
Assert 'the AUM catalog keeps two spellings of one identifier as two units' (-not $m -and $gateway.Values['bu-registry'] -ceq $bridgeSpellings) "$m | registry $($gateway.Values['bu-registry'])"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $bridgeSpellings
$gateway.Values['bu-parents'] = ',sales=platform,Sales=platform,'
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @(New-BridgeUnit 'platform' 'Platform'); departments = @(
            @{ id = 'sales'; parent_id = 'platform'; external_ref = 'entra-group:Lower Sales'; attributes = @{} }
            @{ id = 'Sales'; parent_id = 'platform'; external_ref = 'entra-group:Upper Sales'; attributes = @{} }) } }
Assert 'the AUM catalog writes a team for each spelling it is given' (-not $m -and $gateway.Values['bu-registry'] -ceq $bridgeSpellings -and $gateway.Values['bu-parents'] -ceq ',sales=platform,Sales=platform,') "$m | registry $($gateway.Values['bu-registry']) | parents $($gateway.Values['bu-parents'])"
Reset-Gateway $local
$gateway.Values['bu-registry'] = $bridgeSpellings
$gateway.Values['bu-modes'] = ',sales=notify,'
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @((New-BridgeUnit 'platform' 'Platform'), (New-BridgeUnit 'Sales' 'Upper Sales')); departments = @() } }
Assert "the AUM catalog removes the mode of the spelling it removes" (-not $m -and $gateway.Values['bu-registry'] -ceq ',platform=Platform:5000,Sales=Upper Sales:2000,' -and $gateway.Values['bu-modes'] -ceq ',,') "$m | registry $($gateway.Values['bu-registry']) | modes $($gateway.Values['bu-modes'])"
Reset-Gateway $local
$m = Invoke-Bridge @{ action = 'catalog'; body = @{ organizations = @((New-BridgeUnit 'sales' 'Sales'), (New-BridgeUnit 'platform' 'Platform')); departments = @(@{ id = 'eu'; parent_id = 'Platform'; external_ref = 'entra-group:EU'; attributes = @{} }) } }
Assert "the AUM catalog refuses a team whose parent is another spelling of a unit, before any write" ($m -match 'Team parent is not a unit' -and $gateway.Writes.Count -eq 0) "$m | writes $($gateway.Writes -join ',') | parents $($gateway.Values['bu-parents'])"

# personBudgets mirrors daily tier ceilings TO Turnstile. Neither apply path
# writes quota-overrides, and neither edits Entra membership.
foreach ($integration in '', $local, $full, $budgetOnly, $full.Replace('false', 'true'), $budgetOnly.Replace('false', 'true')) {
    foreach ($parameters in @(
        @{ User = $personId; Tokens = 3000 },
        @{ User = $personId; Clear = $true }
    )) {
        Reset-Gateway $integration
        $m = Invoke-Set 'Set-ClaudeBudget' $parameters
        Assert 'personal daily overrides stay gateway-owned' (-not $m -and $gateway.Writes.Count -eq 1 -and $gateway.Writes[0] -eq 'quota-overrides' -and $gateway.Values['quota-overrides'].Contains("$otherId=2000")) $m
    }
    Reset-Gateway $integration
    $m = Invoke-Set 'Set-ClaudeDeveloper' @{ User = $personId; Tier = 'standard'; BusinessUnit = 'sales'; StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium' }
    Assert 'Entra membership edits remain allowed, not competing named-value writes' (-not $m -and $gateway.GroupWrites.Count -gt 0 -and $gateway.Writes.Count -eq 0) $m
}

Write-Host 'Authority - new USD allocations use the shared financial guard' -ForegroundColor Cyan
foreach ($integration in '', $local) {
    Reset-Gateway $integration
    $m = Invoke-Set 'Set-ClaudeBudget' @{ User = $personId; DailyUsd = 1 }
    Assert 'gateway-owned dollar input persists both the token guard and dollars' (-not $m -and
        $gateway.Writes.Count -eq 2 -and $gateway.Writes -contains 'quota-overrides' -and
        $gateway.Writes -contains 'usd-budgets' -and $gateway.Values['quota-overrides'].Contains("$otherId=2000")) $m
}
foreach ($integration in $full, $budgetOnly, $full.Replace('false', 'true'), $budgetOnly.Replace('false', 'true')) {
    Reset-Gateway $integration
    $m = Invoke-Set 'Set-ClaudeBudget' @{ User = $personId; DailyUsd = 1 }
    Assert-Refusal 'personal USD allocation' $m 'Budgets'
    Assert 'personal USD refusal names dollars rather than a monthly token allocation' ($m -match 'USD') $m
}
Reset-Gateway $local
$m = Invoke-Set 'Set-ClaudeBudget' @{ User = $personId; DailyUsd = 1 }
Assert 'USD clear fixture is written before probing ownership' (-not $m -and $gateway.Writes -contains 'usd-budgets') $m
$gateway.Writes.Clear()
$beforeDollars = $gateway.Values['usd-budgets']
$beforeTokens = $gateway.Values['quota-overrides']
$gateway.Integration = $budgetOnly
$m = Invoke-Set 'Set-ClaudeBudget' @{ User = $personId; Clear = $true }
Assert-Refusal 'clearing an existing personal USD control' $m 'Budgets'
Assert 'refused USD clear preserves both independent limits' ($gateway.Values['usd-budgets'] -eq $beforeDollars -and
    $gateway.Values['quota-overrides'] -eq $beforeTokens)
Reset-Gateway $local
$gateway.Values.Remove('usd-budgets')
$gateway.Values.Remove('usd-budget-state')
$m = Invoke-Set 'Set-ClaudeBudget' @{ User = $personId; DailyUsd = 1 }
Assert 'legacy gateway cannot silently degrade a dollar write into tokens only' ($m -match 'Install the current gateway' -and $gateway.Writes.Count -eq 0) $m

Write-Host ''
if ($fail) { Write-Host "$fail authority assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Governance authority contract holds.' -ForegroundColor Green
exit 0
