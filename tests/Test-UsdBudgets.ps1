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
# A rate the per-key reduction nulls (conflicting rates) must mark the row unpriced: usd coalesces a null category cost
# to 0, so priced_ok is the only signal a report has (ClaudeChargebackQuery.ps1 counts UnpricedRows from it).
Assert 'chargeback KQL marks a metered row priced only when both its input and output rates exist' ($kql -match 'priced_ok = isnotnull\(input_per_m\) and isnotnull\(output_per_m\)')
Assert 'chargeback KQL marks a cache row priced only when its cache-read rate exists' ($kql -match 'priced_ok = isnotnull\(cache_read_per_m\)')
Assert 'chargeback KQL derives no priced_ok from the input rate alone' (@([regex]::Matches($kql, 'priced_ok = isnotnull\(input_per_m\)\s*\r?\n')).Count -eq 0)
$publisher = Get-Content (Join-Path $root 'scripts\Publish-ClaudeQueries.ps1') -Raw
Assert 'query publisher formats price numbers with invariant culture' ($publisher -match 'InvariantCulture' -and $publisher -match 'ToString\(')
Assert 'query publisher refuses duplicate normalized price keys' ($publisher -match 'Duplicate normalized price-book key' -and $publisher -match 'ConvertTo-ClaudeQueryPriceKey')
Assert 'query publisher allows equal-rate duplicate price keys with a warning' ($publisher -match 'Write-Warning' -and $publisher -match 'Duplicate normalized price-book key')
Assert 'query publisher compares all five effective price rates' ($publisher -match 'cacheReadPerM' -and $publisher -match 'cacheWrite5mPerM' -and $publisher -match 'cacheWrite1hPerM')
$publishAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Publish-ClaudeQueries.ps1'), [ref]$null, [ref]$null)
foreach ($fn in 'Format-ClaudeQueryDecimal', 'Get-ClaudeQueryPriceRate', 'Get-ClaudeQueryEffectivePriceRates', 'Get-ClaudeQueryEffectivePriceRateKey', 'ConvertTo-ClaudeQueryPriceKey', 'New-PriceBlock') {
    $fnAst = $publishAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $fn }, $true)
    if ($fnAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
}
$scalePublisherA = [pscustomobject]@{ inputPerM = [decimal]'0.8'; outputPerM = [decimal]'4' }
$scalePublisherB = [pscustomobject]@{ inputPerM = [decimal]'0.8'; outputPerM = [decimal]'4'; cacheWrite5mPerM = [decimal]'1.000' }
Assert 'query publisher treats defaulted and explicit equal decimal-scale rates as the same effective rate' (
    (Get-ClaudeQueryEffectivePriceRateKey $scalePublisherA 'scaled.model') -eq
    (Get-ClaudeQueryEffectivePriceRateKey $scalePublisherB 'scaled-model')
)
function Test-UnsafeRepoPriceBookTouch {
    param([Parameter(Mandatory = $true)][string]$Text)
    $withoutProbeData = [regex]::Replace($Text, '(?s)\$knownBadPriceBookTouches\s*=\s*@\(.*?\)\s*\$knownSafePriceBookTouches\s*=\s*@\(.*?\)', '')
    $direct = '(?is)(Set-Content|Out-File|WriteAllText|Delete|Remove-Item|Move-Item|Copy-Item|open\s*\()[^\r\n;]*(Join-Path\s+\$root\s+[''"]config[\\/]price-book\.json|Join-Path\s+\$root\s+[''"]config[''"]\s+[''"]price-book\.json|\$root[\\/]+config[\\/]+price-book\.json)'
    if ($withoutProbeData -match $direct) { return $true }
    if ($withoutProbeData -match '(?is)Path\(\s*root\s*,\s*[''"]config[''"]\s*,\s*[''"]price-book\.json[''"]\s*\)\.write_text\s*\(') { return $true }
    $assigned = @([regex]::Matches($withoutProbeData, '(?im)^\s*(\$\w+)\s*=\s*(?:Join-Path\s+\$root\s+[''"]config[\\/]price-book\.json[''"]|Join-Path\s+\$root\s+[''"]config[''"]\s+[''"]price-book\.json[''"]|["'']\$root[\\/]config[\\/]price-book\.json["''])') |
        ForEach-Object { [regex]::Escape($_.Groups[1].Value) })
    foreach ($variable in $assigned) {
        if ($withoutProbeData -match "(?is)(Set-Content|Out-File|WriteAllText|Delete|Remove-Item|Move-Item|Copy-Item|open\s*\(|write_text\s*\()[^\r\n;]*$variable\b") {
            return $true
        }
    }
    return $false
}
$knownBadPriceBookTouches = @(
    "Copy-Item `$src (Join-Path `$root 'config\price-book.json')",
    "`$book = Join-Path `$root 'config\price-book.json'; Remove-Item -LiteralPath `$book",
    "Copy-Item `$src -Destination (Join-Path `$root 'config\price-book.json')",
    "`$book = Join-Path `$root 'config' 'price-book.json'; Remove-Item `$book",
    "Set-Content ""`$root\config\price-book.json"" 'x'",
    "[IO.File]::Delete((Join-Path `$root 'config\price-book.json'))",
    "'x' | Out-File (Join-Path `$root 'config\price-book.json')",
    "from pathlib import Path; Path(root, 'config', 'price-book.json').write_text('x')"
)
$knownSafePriceBookTouches = @(
    "`$book = Join-Path `$env:TEMP 'price-book.json'; Remove-Item -LiteralPath `$book",
    "[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetTempPath()) 'price-book.json'), 'x')"
)
foreach ($probe in $knownBadPriceBookTouches) {
    Assert 'price-book guard flags known unsafe repo writes' (Test-UnsafeRepoPriceBookTouch $probe) $probe
}
foreach ($probe in $knownSafePriceBookTouches) {
    Assert 'price-book guard ignores scratch-path writes' (-not (Test-UnsafeRepoPriceBookTouch $probe)) $probe
}
$testSourceRoots = @((Join-Path $root 'tests'), (Join-Path $root 'tests\aum_service'))
$unsafePriceBookTouches = @()
foreach ($sourceRoot in $testSourceRoots) {
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Include *.ps1,*.py | ForEach-Object {
        if ($_.Name -notin 'Test-All.ps1', 'Test-RunnerIntegrity.ps1', 'Test-UsdBudgets.ps1') {
            $text = Get-Content -LiteralPath $_.FullName -Raw
            if (Test-UnsafeRepoPriceBookTouch $text) {
                $unsafePriceBookTouches += $_.FullName.Substring($root.Length + 1)
            }
        }
    }
}
Assert 'tests never write, move, copy or delete the repo-local config\price-book.json' (-not $unsafePriceBookTouches.Count) ($unsafePriceBookTouches -join ', ')
$tempPublishBook = Join-Path ([IO.Path]::GetTempPath()) ('p108-price-book-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [IO.File]::WriteAllText($tempPublishBook, (@{ date = '2026-10-08'; models = @{ 'temp-only-model' = @{ inputPerM = 3; outputPerM = 15 } } } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $tempBlock = New-PriceBlock -Path $tempPublishBook
    Assert 'query publisher can read a caller-supplied temporary price-book path' ($tempBlock -match 'temp-only-model' -and $tempBlock -notmatch 'claude-sonnet-5') $tempBlock
    [IO.File]::WriteAllText($tempPublishBook, (@{ date = '2026-10-08'; models = @{ 'my-typo' = @{ inputPerM = 3 } } } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $missingRate = Get-Thrown { New-PriceBlock -Path $tempPublishBook }
    Assert 'query publisher refuses a missing required rate before formatting it as zero' ($missingRate -match 'my-typo' -and $missingRate -match 'outputPerM') $missingRate
    [IO.File]::WriteAllText($tempPublishBook, (@{ date = '2026-10-08'; models = @{ 'my-typo' = @{ inputPerM = 3; outputPerM = 15; cacheReadPerM = 'oops' } } } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $invalidRate = Get-Thrown { New-PriceBlock -Path $tempPublishBook }
    Assert 'query publisher refuses a non-numeric optional rate with the key and field' ($invalidRate -match 'my-typo' -and $invalidRate -match 'cacheReadPerM') $invalidRate
    foreach ($edge in @(@('1e30', 'decimal range'), @('2000000', 'above 1,000,000'), @('-1e-30', 'negative'))) {
        [IO.File]::WriteAllText($tempPublishBook, ('{"date":"2026-10-08","models":{"edge-model":{"inputPerM":' + $edge[0] + ',"outputPerM":5}}}'), [Text.UTF8Encoding]::new($false))
        $edgeError = [string](Get-Thrown { New-PriceBlock -Path $tempPublishBook })
        Assert "query publisher refuses inputPerM $($edge[0]) with the file and the rule" ($edgeError.Contains($tempPublishBook) -and $edgeError -match 'edge-model' -and $edgeError.Contains($edge[1])) $edgeError
    }
    Assert 'query publisher rate refusals name the price book file' ($missingRate.Contains($tempPublishBook) -and $invalidRate.Contains($tempPublishBook)) "$missingRate | $invalidRate"
    [IO.File]::WriteAllText($tempPublishBook, (@{ date = '2026-10-08'; models = [ordered]@{
        'claude-haiku-4.5' = @{ inputPerM = 1; outputPerM = 5 }
        'claude-haiku-4-5' = @{ inputPerM = 1; outputPerM = 5; cacheReadPerM = 0.05 }
    } } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $conflictingDuplicate = Get-Thrown { New-PriceBlock -Path $tempPublishBook }
    Assert 'query publisher behaviorally refuses duplicate normalized keys with conflicting effective rates' ($conflictingDuplicate -match 'Duplicate normalized price-book key' -and $conflictingDuplicate -match 'claude-haiku-4\.5' -and $conflictingDuplicate -match 'claude-haiku-4-5') $conflictingDuplicate
    $rateConflictCases = @(
        @('inputPerM', @{ inputPerM = 1; outputPerM = 5; cacheReadPerM = 0.1; cacheWrite5mPerM = 1.25; cacheWrite1hPerM = 2 }, @{ inputPerM = 2; outputPerM = 5; cacheReadPerM = 0.1; cacheWrite5mPerM = 1.25; cacheWrite1hPerM = 2 }),
        @('outputPerM', @{ inputPerM = 1; outputPerM = 5 }, @{ inputPerM = 1; outputPerM = 6 }),
        @('cacheReadPerM', @{ inputPerM = 1; outputPerM = 5 }, @{ inputPerM = 1; outputPerM = 5; cacheReadPerM = 0.05 }),
        @('cacheWrite5mPerM', @{ inputPerM = 1; outputPerM = 5 }, @{ inputPerM = 1; outputPerM = 5; cacheWrite5mPerM = 2 }),
        @('cacheWrite1hPerM', @{ inputPerM = 1; outputPerM = 5 }, @{ inputPerM = 1; outputPerM = 5; cacheWrite1hPerM = 3 })
    )
    foreach ($case in $rateConflictCases) {
        [IO.File]::WriteAllText($tempPublishBook, (@{ date = '2026-10-08'; models = [ordered]@{
            'rate.family' = $case[1]
            'rate-family' = $case[2]
        } } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        $rateConflict = Get-Thrown { New-PriceBlock -Path $tempPublishBook }
        Assert "query publisher refuses duplicate normalized keys that differ only in $($case[0])" ($rateConflict -match 'Duplicate normalized price-book key' -and $rateConflict -match 'rate.family' -and $rateConflict -match 'rate-family') $rateConflict
    }
}
finally { Remove-Item -LiteralPath $tempPublishBook -Force -ErrorAction SilentlyContinue }
$harness = Get-Content (Join-Path $root 'scripts\Test-ClaudeUsdUsageQuery.ps1') -Raw
Assert 'live USD query harness compares dates as UTC yyyy-MM-dd strings' ($harness -match "ToUniversalTime\(\)\.ToString\('yyyy-MM-dd'")
Assert 'live USD query harness covers the next UTC day metric' ($harness -match '2026, 10, 9, 2')
Assert 'live USD query harness prints returned rows on failure' ($harness -match 'Write-ReturnedRows')
Assert 'live USD query harness asserts rows have non-null day and users where required' ($harness -match 'every row has a day' -and $harness -match 'non-userless row has a user')
Assert 'live USD query harness covers duplicate metric spellings and tied latest rows' ($harness -match 'claude-haiku-4.5' -and $harness -match 'tie-a' -and $harness -match 'tie-b')
Assert 'live USD query harness characterizes empty-deployment custom-metric residuals' ($harness -match 'residual empty deployment custom metric is a latest-stamp metric-only row and body reads remain' -and $harness -match 'known-read family ignores same-family metric residual')
$adr60 = Get-Content (Join-Path $root 'docs\adr\0060-usd-reconciler-attribution-and-pricing.md') -Raw
Assert 'ADR-0060 records the residual empty-deployment custom-metric double-count assumption' (
    $adr60 -match 'latest stamped unit' -and
    $adr60 -match 'counted twice' -and
    $adr60 -match 'all .*reads are known.*metric is ignored' -and
    $adr60 -notmatch 'metric-only `unit_unknown`/person row'
) $adr60
# The documented remedies and causes for an unpriced model, and the code each citation points at (round 5 UX and
# Architect findings): a citation whose range no longer holds its code fails here.
$troubleshootingText = Get-Content (Join-Path $root 'docs\TROUBLESHOOTING.md') -Raw
$budgetsText = Get-Content (Join-Path $root 'docs\BUDGETS.md') -Raw
$changelogText = Get-Content (Join-Path $root 'CHANGELOG.md') -Raw
$unpricedRow = @($troubleshootingText -split "`r?`n" | Where-Object { $_ -match 'usd_budget_unpriced` naming a model' })[0]
Assert 'TROUBLESHOOTING gives the add-or-correct remedy and every cause of an unpriced model' ($unpricedRow -match 'add or correct' -and $unpricedRow -match 'missing `inputPerM` or `outputPerM`' -and $unpricedRow -match 'above 1,000,000' -and $unpricedRow -match 'different rates' -and $unpricedRow -match 'undated family') $unpricedRow
Assert 'BUDGETS says another spelling does not price an unpriced family and names the rate bounds' ($budgetsText -match 'Adding another spelling\s+does not price such a family' -and $budgetsText -match 'above\s+1,000,000')
Assert 'the CHANGELOG says only invalid rates warn in the business-unit and Turnstile scripts' ($changelogText -match 'for an invalid rate the business-unit and\s+Turnstile scripts warn' -and $changelogText -notmatch 'conflicting rates leave that model unpriced\)')
Assert 'ADR-0060 states the rate bounds and the shared ordinal order' ($adr60 -match 'above\s+1,000,000' -and $adr60 -match 'Sort-ClaudeFlowOrdinal' -and $adr60 -match 'UTF-16')
function Test-CitedRange([string]$DocPath, [string]$File, [string]$FirstLine, [string]$Holds) {
    # True when the document cites a range of File whose first line holds FirstLine and whose lines hold Holds.
    $doc = Get-Content (Join-Path $root $DocPath) -Raw
    $lines = @(Get-Content (Join-Path $root ($File -replace '/', '\')))
    foreach ($m in [regex]::Matches($doc, [regex]::Escape($File) + ':(\d+)(?:-(\d+))?')) {
        $start = [int]$m.Groups[1].Value; $end = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { $start }
        if ($start -lt 1 -or $end -lt $start -or $end -gt $lines.Count) { continue }
        if ($lines[$start - 1].Contains($FirstLine) -and (($lines[($start - 1)..($end - 1)]) -join "`n").Contains($Holds)) { return $true }
    }
    return $false
}
foreach ($cited in @(
    @('docs\TROUBLESHOOTING.md', 'service/aum/aum_service/usd_budgets.py', 'def price_book_key', 'return matches[0] if len(matches) == 1 else None'),
    @('docs\TROUBLESHOOTING.md', 'scripts/ClaudeUsdBudgets.ps1', 'elseif (-not $Clear -and $hasItems -and $hasOfferedBook)', 'Active USD budgets pin their tariff'),
    @('docs\TROUBLESHOOTING.md', 'scripts/Publish-ClaudeQueries.ps1', 'function New-PriceBlock', 'let price = datatable'),
    @('docs\TROUBLESHOOTING.md', 'infra/policy.xml', 'var state = JObject.Parse', 'until > asof.AddSeconds(900)'),
    @('docs\TROUBLESHOOTING.md', 'infra/policy.xml', '} catch {', 'usd_budget_state_stale'),
    @('docs\BUDGETS.md', 'scripts/ClaudeUsdBudgets.ps1', 'if (-not $doc.schema_version)', '$doc.price_book = $PriceBook'),
    @('docs\BUDGETS.md', 'scripts/ClaudeUsdBudgets.ps1', 'elseif (-not $Clear -and $hasItems -and $hasOfferedBook)', 'Active USD budgets pin their tariff'),
    @('docs\BUDGETS.md', 'service/aum/aum_service/usd_budgets.py', 'def price_book_key', 'return matches[0] if len(matches) == 1 else None')
)) {
    Assert "$($cited[0]) cites the $($cited[1]) range that starts at '$($cited[2])'" (Test-CitedRange $cited[0] $cited[1] $cited[2] $cited[3])
}$unknowns = Get-Content (Join-Path $root 'docs\UNKNOWNS.md') -Raw
Assert 'UNKNOWNS records the empty DeploymentName custom deployment residual detector' (
    $unknowns -match 'U180 \| ASSUMED' -and
    $unknowns -match 'empty `DeploymentName`' -and
    $unknowns -match 'custom deployment names' -and
    $unknowns -match 'live harness'
) $unknowns

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
