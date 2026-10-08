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
$newBook = [pscustomobject]@{ date = '2026-10-08'; models = [pscustomobject]@{
    'claude-sonnet-5' = [pscustomobject]@{ inputPerM = '3'; outputPerM = '15' }
    'claude-opus-5-5' = [pscustomobject]@{ inputPerM = '4'; outputPerM = '20' }
} }
$raw = Invoke-Value { New-ClaudeUsdBudgetValue -Value 'e30=' -ScopeType organization -ScopeId finance -AmountUsd 12.345678901 -Period month -PriceBook $book }
$doc = Invoke-Value { ConvertFrom-ClaudeUsdValue $raw }
Assert 'USD is stored as decimal text, not a blended quota' ($doc.items.'organization:finance'.amount_usd -ceq '12.345678901')
Assert 'price book date travels with the dollars' ($doc.items.'organization:finance'.price_book_date -eq '2026-09-16')
Assert 'empty value creates a schema document with the current price book' ($doc.schema_version -eq 1 -and $doc.price_book.date -eq '2026-09-16' -and $doc.price_book.models.'claude-sonnet-5')
$next = Invoke-Value { New-ClaudeUsdBudgetValue -Value $raw -ScopeType department -ScopeId payroll -AmountUsd 1 -Period month -PriceBook $book }
$doc = Invoke-Value { ConvertFrom-ClaudeUsdValue $next }
Assert 'setting one budget preserves the other scope' ($doc.items.'organization:finance'.amount_usd -ceq '12.345678901')
$cleared = Invoke-Value { New-ClaudeUsdBudgetValue -Value $next -ScopeType department -ScopeId payroll -Clear }
$doc = Invoke-Value { ConvertFrom-ClaudeUsdValue $cleared }
Assert 'clear removes only the selected dollar budget' ($null -eq $doc.items.'department:payroll' -and $doc.items.'organization:finance')
$emptyDocValue = Invoke-Value { New-ClaudeUsdBudgetValue -Value $raw -ScopeType organization -ScopeId finance -Clear }
$emptyDoc = Invoke-Value { ConvertFrom-ClaudeUsdValue $emptyDocValue }
Assert 'clearing the last item leaves a valid schema document' ($emptyDoc.schema_version -eq 1 -and $emptyDoc.price_book.date -eq '2026-09-16' -and @($emptyDoc.items.PSObject.Properties).Count -eq 0)
$rewrittenAfterClear = Invoke-Value { New-ClaudeUsdBudgetValue -Value $emptyDocValue -ScopeType organization -ScopeId finance -AmountUsd 2 -Period month -PriceBook $newBook }
$rewrittenDoc = Invoke-Value { ConvertFrom-ClaudeUsdValue $rewrittenAfterClear }
Assert 'writing after clearing all budgets stores the current price book' ($rewrittenDoc.price_book.date -eq '2026-10-08' -and $rewrittenDoc.items.'organization:finance'.price_book_date -eq '2026-10-08')
$activePinOutput = @(New-ClaudeUsdBudgetValue -Value $raw -ScopeType department -ScopeId payroll -AmountUsd 1 -Period month -PriceBook $newBook *>&1)
$activePinValue = [string]$activePinOutput[-1]
$activePinDoc = Invoke-Value { ConvertFrom-ClaudeUsdValue $activePinValue }
Assert 'active budgets keep their stored price book and warn when a newer book is offered' ($activePinDoc.price_book.date -eq '2026-09-16' -and $activePinDoc.items.'department:payroll'.price_book_date -eq '2026-09-16' -and (($activePinOutput | Out-String) -match 'Active USD budgets pin their tariff' -and ($activePinOutput | Out-String) -match '2026-09-16' -and ($activePinOutput | Out-String) -match '2026-10-08')) ($activePinOutput | Out-String)
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
$kql = Get-Content (Join-Path $root 'analytics\chargeback-cost.kql') -Raw
Assert 'chargeback KQL normalizes model names to lowercase letters and digits' ($kql -match 'replace_regex\(m, @"\[\^A-Za-z0-9\]"')
Assert 'chargeback KQL matches a dated model by exactly eight trailing digits' ($kql -match '\\d\{8\}' -and $kql -match 'substring\(')
Assert 'chargeback KQL does not use a broad prefix price match' ($kql -notmatch 'startswith\(|hasprefix')
Assert 'chargeback KQL reduces price rows to one normalized key before joins' ($kql -match 'input_rates = make_set' -and $kql -match 'output_rates = make_set' -and $kql -match 'by k' -and $kql -match 'array_length\(input_rates\) == 1')
Assert 'chargeback KQL publishes and reduces cache-read rates from the price book' ($kql -match 'cache_read_per_m: real' -and $kql -match 'cache_read_rates = make_set\(cache_read_per_m, 2\)' -and $kql -match 'array_length\(cache_read_rates\) == 1')
Assert 'chargeback KQL prices cache reads from the effective cache-read rate, not a fixed multiplier' ($kql -notmatch 'cache_read_multiplier' -and $kql -match 'cache_read_per_m' -and $kql -match 'cache_read_tokens / 1000000\.0\) \* cache_read_per_m')
$publisher = Get-Content (Join-Path $root 'scripts\Publish-ClaudeQueries.ps1') -Raw
Assert 'query publisher formats price numbers with invariant culture' ($publisher -match 'InvariantCulture' -and $publisher -match 'ToString\(')
Assert 'query publisher refuses duplicate normalized price keys' ($publisher -match 'Duplicate normalized price-book key' -and $publisher -match 'ConvertTo-ClaudeQueryPriceKey')
Assert 'query publisher allows equal-rate duplicate price keys with a warning' ($publisher -match 'Write-Warning' -and $publisher -match 'Duplicate normalized price-book key')
Assert 'query publisher compares all five effective price rates' ($publisher -match 'cacheReadPerM' -and $publisher -match 'cacheWrite5mPerM' -and $publisher -match 'cacheWrite1hPerM')
$harness = Get-Content (Join-Path $root 'scripts\Test-ClaudeUsdUsageQuery.ps1') -Raw
Assert 'live USD query harness compares dates as UTC yyyy-MM-dd strings' ($harness -match "ToUniversalTime\(\)\.ToString\('yyyy-MM-dd'")
Assert 'live USD query harness covers the next UTC day metric' ($harness -match '2026, 10, 9, 2')
Assert 'live USD query harness prints returned rows on failure' ($harness -match 'Write-ReturnedRows')
Assert 'live USD query harness asserts rows have non-null day and users where required' ($harness -match 'every row has a day' -and $harness -match 'non-userless row has a user')
Assert 'live USD query harness covers duplicate metric spellings and tied latest rows' ($harness -match 'claude-haiku-4.5' -and $harness -match 'tie-a' -and $harness -match 'tie-b')

$dupBook = [pscustomobject]@{ date = '2026-10-08'; models = [pscustomobject]@{
    'claude-haiku-4.5' = [pscustomobject]@{ inputPerM = 1; outputPerM = 5 }
    'claude-haiku-4-5' = [pscustomobject]@{ inputPerM = 1; outputPerM = 5 }
} }
$rawDup = Invoke-Value { New-ClaudeUsdBudgetValue -Value 'e30=' -ScopeType organization -ScopeId finance -AmountUsd 1 -Period month -PriceBook $dupBook }
Assert 'USD budget writer refuses even equal-rate duplicate normalized price keys' ($rawDup -match 'Duplicate normalized price-book key')
# A local book is validated only where it is stored. With active budgets the stored book stays pinned, so a local book
# that holds two spellings of one model (the R2 workaround) must not stop a budget change.
$dupBookPath = Join-Path ([IO.Path]::GetTempPath()) ('usd-dup-book-' + [guid]::NewGuid().ToString('N') + '.json')
[IO.File]::WriteAllText($dupBookPath, ($dupBook | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
try {
    $readDup = Get-Thrown { Get-ClaudeUsdPriceBook -Path $dupBookPath }
    Assert 'reading a local book with an equal-rate duplicate does not throw' ($null -eq $readDup) $readDup
    $pinnedDoc = New-ClaudeUsdBudgetValue -Value 'e30=' -ScopeType organization -ScopeId finance -AmountUsd 1 -Period month -PriceBook (Get-Content (Join-Path $root 'config\price-book.example.json') -Raw | ConvertFrom-Json)
    $raised = Invoke-Value { New-ClaudeUsdBudgetValue -Value $pinnedDoc -ScopeType organization -ScopeId finance -AmountUsd 2 -Period month -PriceBook $dupBook 3>$null }
    $raisedDoc = ConvertFrom-ClaudeUsdValue $raised
    Assert 'raising a budget with active budgets and a duplicate local book keeps the stored book' ($raisedDoc.items.'organization:finance'.amount_usd -eq '2' -and -not $raisedDoc.price_book.models.PSObject.Properties['claude-haiku-4-5']) $raised
}
finally { Remove-Item -LiteralPath $dupBookPath -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($fail) { Write-Host "$fail USD assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'USD script and gateway contracts passed.' -ForegroundColor Green
exit 0
