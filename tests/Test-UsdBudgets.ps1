# In-process mutation safe: unexpected errors are failures, never escaping exceptions.
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] unexpected error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label $detail" -ForegroundColor Red; $script:fail++ }
}
function Invoke-Value([scriptblock]$Block) { try { & $Block } catch { "<threw: $($_.Exception.Message)>" } }
function Get-Thrown([scriptblock]$Block) { try { & $Block *> $null; return $null } catch { return $_.Exception.Message } }

. (Join-Path $root 'scripts\ClaudeUsdBudgets.ps1')
$book = [pscustomobject]@{ date = '2026-09-16'; models = [pscustomobject]@{
    'claude-sonnet-5' = [pscustomobject]@{ inputPerM = '2'; outputPerM = '10' }
} }
$raw = Invoke-Value { New-ClaudeUsdBudgetValue -Value 'e30=' -ScopeType organization -ScopeId finance -AmountUsd 12.345678901 -Period month -PriceBook $book }
$doc = Invoke-Value { ConvertFrom-ClaudeUsdValue $raw }
Assert 'USD is stored as decimal text, not a blended quota' ($doc.items.'organization:finance'.amount_usd -ceq '12.345678901')
Assert 'price book date travels with the dollars' ($doc.items.'organization:finance'.price_book_date -eq '2026-09-16')
$next = Invoke-Value { New-ClaudeUsdBudgetValue -Value $raw -ScopeType department -ScopeId payroll -AmountUsd 1 -Period month -PriceBook $book }
$doc = Invoke-Value { ConvertFrom-ClaudeUsdValue $next }
Assert 'setting one budget preserves the other scope' ($doc.items.'organization:finance'.amount_usd -ceq '12.345678901')
$cleared = Invoke-Value { New-ClaudeUsdBudgetValue -Value $next -ScopeType department -ScopeId payroll -Clear }
$doc = Invoke-Value { ConvertFrom-ClaudeUsdValue $cleared }
Assert 'clear removes only the selected dollar budget' ($null -eq $doc.items.'department:payroll' -and $doc.items.'organization:finance')
Assert 'negative dollars refuse' ((Get-Thrown { New-ClaudeUsdBudgetValue -Value 'e30=' -ScopeType organization -ScopeId finance -AmountUsd -1 -Period month -PriceBook $book }) -match 'nonnegative')
Assert 'malformed state is not an empty budget map' ((Get-Thrown { ConvertFrom-ClaudeUsdValue 'broken!' }) -match 'USD')
Assert 'capacity is enforced before writing' ((Get-Thrown { ConvertTo-ClaudeUsdValue @{ big = ('x' * 5000) } }) -match '4,096|4096')
$script:Authority = 'url=https://turnstile.example.com;budgetAuthority=Turnstile'
function Get-ApimNamedValue { param($ResourceGroup, $ApimName, $Id, [switch]$FailOnError) return $script:Authority }
Assert 'Turnstile budget ownership prevents writes' ((Get-Thrown { Assert-ClaudeUsdAuthority -ResourceGroup rg-test -ApimName apim-test }) -match 'Turnstile')
$script:Authority = 'url=https://turnstile.example.com;governanceAuthority=Turnstile'
Assert 'Turnstile governance ownership prevents writes' ((Get-Thrown { Assert-ClaudeUsdAuthority -ResourceGroup rg-test -ApimName apim-test }) -match 'Turnstile')
$library = Get-Content (Join-Path $root 'scripts\ClaudeUsdBudgets.ps1') -Raw
Assert 'USD delegates ownership to the shared guard, not another regex' ($library -match 'Assert-ClaudeGatewayOwnsGovernance -ResourceGroup \$ResourceGroup -ApimName \$ApimName -Write UsdBudgets' -and
    $library -notmatch '\(\?:governanceAuthority\|budgetAuthority\)=Turnstile')

$fake = [pscustomobject]@{ Writes = 0; DelayReadback = 1; BeforeWrite = ''; Values = @{
    'bu-registry' = ',finance=Contoso Finance:1000000,'
    'bu-parents' = ',,'; 'bu-modes' = ',,'; 'quota-org' = '100000000'
    'usd-budgets' = 'e30='; 'usd-budget-state' = 'e30='
} }
function az {
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'account show*') { return '00000000-0000-0000-0000-000000000000' }
    if ($line -like 'account get-access-token*') { return 'test-only-token' }
    if ($line -like 'apim nv list*') {
        return ConvertTo-Json -InputObject @($fake.Values.Keys | ForEach-Object {
            [pscustomobject]@{ name = $_; value = $fake.Values[$_]; secret = $false }
        })
    }
    if ($line -like 'apim nv *') {
        $key = [string]$args[[array]::IndexOf($args, '--named-value-id') + 1]
        if ($line -like 'apim nv update*' -or $line -like 'apim nv create*') {
            $fake.Values[$key] = [string]$args[[array]::IndexOf($args, '--value') + 1]
            return
        }
        if ($line -match '--query name') { return $key }
        return $fake.Values[$key]
    }
    throw "Unexpected offline az call: $line"
}
function Invoke-WebRequest {
    param($Method, $Uri, $Headers, $Body, $ContentType, [switch]$UseBasicParsing)
    if ($Method -eq 'Put') {
        $text = if ($Body -is [byte[]]) { [Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
        $fake.BeforeWrite = $fake.Values['usd-budgets']
        $fake.Values['usd-budgets'] = ($text | ConvertFrom-Json).properties.value
        $fake.Writes++
    }
    return [pscustomobject]@{
        Headers = @{ ETag = '"version-1"' }
        Content = (@{ properties = @{ displayName = 'usd-budgets'; value = $fake.Values['usd-budgets']; secret = $false } } | ConvertTo-Json -Depth 5)
    }
}
function Invoke-RestMethod {
    param($Method, $Uri, $Headers)
    if ($fake.DelayReadback -gt 0) {
        $fake.DelayReadback--
        return [pscustomobject]@{ properties = [pscustomobject]@{ value = $fake.BeforeWrite } }
    }
    return [pscustomobject]@{ properties = [pscustomobject]@{ value = $fake.Values['usd-budgets'] } }
}
function Start-Sleep { param($Seconds) }
foreach ($name in 'az', 'Invoke-WebRequest', 'Invoke-RestMethod') {
    Set-Item -Path "Function:$name" -Value (Get-Item "Function:$name").ScriptBlock.GetNewClosure()
}
$result = Get-Thrown {
    & (Join-Path $root 'scripts\Set-ClaudeBusinessUnit.ps1') -Id finance -MonthlyBudgetUsd 0.02 -ResourceGroup rg-test -ApimName apim-test
}
Assert 'a dollar-only edit executes the actual write even without a mode change' ($null -eq $result -and $fake.Writes -eq 1) $result
$written = Invoke-Value { ConvertFrom-ClaudeUsdValue $fake.Values['usd-budgets'] }
Assert 'the real script persists the approved tiny amount' ($written.items.'organization:finance'.amount_usd -ceq '0.02')

$policy = Get-Content (Join-Path $root 'infra\policy.xml') -Raw
Assert 'USD stop has a distinct error code' ($policy -match 'usd_budget_exceeded')
Assert 'stale state fails closed' ($policy -match 'usd_budget_state_stale' -and $policy -match 'valid_until')
Assert 'policy UTC conversion uses APIM-supported DateTimeOffset' ($policy -match '\(DateTimeOffset\)state\["reconciled_at"\]' -and $policy -notmatch 'CultureInfo|ToUniversalTime')
Assert 'configuration fingerprint guards old decisions' ($policy -match 'source_revision' -and $policy -match 'SHA256')
Assert 'USD state matches only the authenticated scopes' ($policy -match '"user:" \+ \(string\)context.Variables\["userId"\]' -and $policy -match '"parentUnit"')
Assert 'SSE forwarding explicitly avoids response buffering' ($policy -match 'buffer-response="false"')
Assert 'body collection is restricted to nonstream JSON success' ($policy -match '!\(bool\)context.Variables\["usdRequestStream"\]' -and $policy -match 'context.Response.StatusCode == 200' -and $policy -match 'application/json')
Assert 'only usage, not content, reaches the trace' ($policy -match 'name="UsageJson"' -and $policy -match 'body\["usage"\]' -and $policy -notmatch 'metadata name="ResponseBody"')
$template = Get-Content (Join-Path $root 'infra\main.bicep') -Raw
$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
foreach ($key in 'usd-budgets', 'usd-budget-state') {
    Assert "$key is deployed and preserved from an authoritative read" ($template -match [regex]::Escape("key: '$key'") -and $installer -match [regex]::Escape("`$usdSavedValues['$key']"))
}
Assert 'installer refuses an unreadable USD snapshot instead of resetting controls' ($installer -match '\$usdSavedValues = Get-ClaudeUsdNamedValues -ResourceGroup')
foreach ($script in 'Set-ClaudeBusinessUnit.ps1', 'Set-ClaudeBudget.ps1') {
    $source = Get-Content (Join-Path $root "scripts\$script") -Raw
    Assert "$script stores dollars through the guarded shared USD writer" ($source -match 'Set-ClaudeUsdBudget')
}
Write-Host ''
if ($fail) { Write-Host "$fail USD assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'USD script and gateway contracts passed.' -ForegroundColor Green
exit 0
