# Dated dollars live beside the approximate token quota, not inside it.
if (-not (Get-Command Get-ApimNamedValue -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
}
if (-not (Get-Command Assert-ClaudeGatewayOwnsGovernance -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
}
function ConvertFrom-ClaudeUsdValue {
    param([AllowNull()][string]$Value)
    if (-not $Value) { return [pscustomobject]@{} }
    try {
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
        if ($text -notmatch '^\s*\{') { throw 'Expected an object.' }
        $doc = $text | ConvertFrom-Json
        if ($doc.schema_version -and $doc.schema_version -ne 1) { throw 'Unsupported version.' }
        if ($doc.PSObject.Properties.Count -and $text.Trim() -ne '{}' -and
            ($doc.schema_version -ne 1 -or $null -eq $doc.items -or -not $doc.price_book.date)) {
            throw 'A schema, dated price book and items are required.'
        }
        return $doc
    }
    catch { throw "Invalid USD budget configuration: $($_.Exception.Message)" }
}

function ConvertTo-ClaudeUsdValue {
    param([Parameter(Mandatory = $true)]$Document)
    $text = $Document | ConvertTo-Json -Depth 30 -Compress
    if ($text -match '[^\x00-\x7F]') { throw 'USD configuration must contain ASCII identifiers and values.' }
    $value = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    if ($value.Length -gt 4096) { throw 'USD named value exceeds 4,096 characters. Nothing was written.' }
    return $value
}

function New-ClaudeUsdBudgetValue {
    param(
        [AllowNull()][string]$Value,
        [ValidateSet('organization', 'department', 'user')][string]$ScopeType,
        [string]$ScopeId, [decimal]$AmountUsd,
        [ValidateSet('day', 'month')][string]$Period = 'month',
        $PriceBook, [switch]$Clear
    )
    if ($ScopeId -cnotmatch '^[a-z0-9][a-z0-9-]{0,99}$') { throw 'Invalid USD scope identifier.' }
    if ($ScopeType -eq 'user' -and $ScopeId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'A person USD scope must be an Entra object id.'
    }
    if ($AmountUsd -lt 0 -or $AmountUsd -ge 1000000000000 -or [decimal]::Round($AmountUsd, 9) -ne $AmountUsd) {
        throw 'USD amounts must be nonnegative, below one trillion, with at most 9 fractional digits.'
    }
    if ($ScopeType -ne 'user' -and $Period -ne 'month') { throw 'Unit and team USD budgets are monthly.' }
    $doc = ConvertFrom-ClaudeUsdValue $Value
    if (-not $doc.schema_version) {
        if ($Clear) { return 'e30=' }
        if (-not $PriceBook.date -or -not $PriceBook.models) { throw 'A dated USD price book is required.' }
        $date = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$PriceBook.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$date)) { throw 'USD price book date must be YYYY-MM-DD.' }
        $doc = [pscustomobject]@{ schema_version = 1; price_book = $PriceBook; items = [pscustomobject]@{} }
    }
    $key = "$ScopeType`:$ScopeId"
    if ($Clear) { $doc.items.PSObject.Properties.Remove($key) }
    else {
        $item = [pscustomobject]@{
            amount_usd = $AmountUsd.ToString('0.#########', [Globalization.CultureInfo]::InvariantCulture)
            period = $Period
            price_book_date = [string]$doc.price_book.date
        }
        $doc.items | Add-Member -NotePropertyName $key -NotePropertyValue $item -Force
    }
    return ConvertTo-ClaudeUsdValue $doc
}

function Get-ClaudeUsdNamedValues {
    param([string]$ResourceGroup, [string]$ApimName)
    $json = az apim nv list -g $ResourceGroup --service-name $ApimName -o json
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw 'Cannot read gateway authority and USD configuration; no write is safe.' }
    $values = @{}
    $listed = $json | ConvertFrom-Json
    foreach ($entry in $listed) {
        if ($entry.secret -and $entry.name -in @('turnstile-integration', 'usd-budgets', 'usd-budget-state')) {
            throw 'Governance configuration is secret or unreadable; no write is safe.'
        }
        $values[[string]$entry.name] = [string]$entry.value
    }
    return $values
}

function Assert-ClaudeUsdAuthority {
    param([string]$ResourceGroup, [string]$ApimName)
    Assert-ClaudeGatewayOwnsGovernance -ResourceGroup $ResourceGroup -ApimName $ApimName -Write UsdBudgets
}

function Get-ClaudeUsdPriceBook {
    param([string]$Path)
    if (-not $Path) {
        $base = Split-Path $PSScriptRoot -Parent
        $Path = Join-Path $base 'config\price-book.json'
        if (-not (Test-Path $Path)) { $Path = Join-Path $base 'config\price-book.example.json' }
    }
    $book = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Write-Host ("  USD tariff source: {0}; dated {1}. Existing USD budgets keep their stored tariff." -f $Path, $book.date)
    return $book
}

function Set-ClaudeUsdBudget {
    [CmdletBinding()]
    param(
        [string]$ResourceGroup, [string]$ApimName,
        [ValidateSet('organization', 'department', 'user')][string]$ScopeType,
        [string]$ScopeId, [decimal]$AmountUsd,
        [ValidateSet('day', 'month')][string]$Period = 'month',
        [string]$PriceBookPath, [switch]$Clear, [switch]$ValidateOnly
    )
    $all = Get-ClaudeUsdNamedValues -ResourceGroup $ResourceGroup -ApimName $ApimName
    if (-not $all.ContainsKey('usd-budgets') -or -not $all.ContainsKey('usd-budget-state')) {
        if ($Clear) { return }
        throw 'Install the current gateway template/policy before setting USD budgets. No dollar control is installed.'
    }
    if ($Clear) {
        $existing = ConvertFrom-ClaudeUsdValue $all['usd-budgets']
        $key = "$ScopeType`:$ScopeId"
        if (-not $existing.schema_version -or -not $existing.items -or -not $existing.items.PSObject.Properties[$key]) { return }
    }
    Assert-ClaudeUsdAuthority -ResourceGroup $ResourceGroup -ApimName $ApimName
    $book = if ($Clear) { $null } else { Get-ClaudeUsdPriceBook -Path $PriceBookPath }
    $next = New-ClaudeUsdBudgetValue -Value $all['usd-budgets'] -ScopeType $ScopeType -ScopeId $ScopeId `
        -AmountUsd $AmountUsd -Period $Period -PriceBook $book -Clear:$Clear
    if ($ValidateOnly -or $next -eq $all['usd-budgets']) { return }
    $sub = az account show --query id -o tsv
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
    if (-not $sub -or -not $token -or $LASTEXITCODE -ne 0) { throw 'Cannot acquire the selected Azure subscription and token.' }
    $uri = "https://management.azure.com/subscriptions/$($sub.Trim())/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/namedValues/usd-budgets?api-version=2024-05-01"
    $headers = @{ Authorization = 'Bearer ' + $token.Trim() }
    $current = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $uri -Headers $headers
    $old = $current.Content | ConvertFrom-Json
    $etag = [string]$current.Headers['ETag']
    if (-not $etag -or $old.properties.value -ne $all['usd-budgets']) {
        throw 'USD configuration changed or has no ETag. Read it again; no dollars were written.'
    }
    Assert-ClaudeUsdAuthority -ResourceGroup $ResourceGroup -ApimName $ApimName
    $headers['If-Match'] = $etag
    $old.properties.value = $next
    $body = @{ properties = $old.properties } | ConvertTo-Json -Depth 30 -Compress
    $write = Invoke-WebRequest -UseBasicParsing -Method Put -Uri $uri -Headers $headers `
        -ContentType application/json -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $poll = [string]$write.Headers['Azure-AsyncOperation']
    $gatewayBase = $uri.Substring(0, $uri.IndexOf('/namedValues/'))
    if ($poll -and -not $poll.StartsWith($gatewayBase + '/', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Azure returned an unexpected USD operation address. Inspect the write before retrying.'
    }
    $read = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ($poll) {
            $operation = Invoke-RestMethod -Method Get -Uri $poll -Headers @{ Authorization = $headers.Authorization }
            if ($operation.status -in @('Failed', 'Canceled')) { throw 'The asynchronous USD write failed. Inspect the gateway before retrying.' }
        }
        $read = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = $headers.Authorization }
        if ($read.properties.value -eq $next) { break }
        Start-Sleep -Seconds 2
    }
    if ($read.properties.value -ne $next) { throw 'USD write has not read back. Inspect gateway configuration before retrying.' }
    if ($Clear) { Write-Host ("  USD budget cleared: {0}:{1}." -f $ScopeType, $ScopeId) }
    else {
        $saved = ConvertFrom-ClaudeUsdValue $next
        Write-Host ("  USD budget: {0} per {1}; price book {2}." -f $AmountUsd, $Period, $saved.price_book.date)
    }
    Write-Host '  Dollars stored with their price-book date. Reconcile now or wait for the five-minute AUM timer.'
    Write-Host '  Token guards remain approximate; the dollar stop uses delayed observed categories, not an invoice.'
}
