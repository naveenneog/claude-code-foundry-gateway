$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
$script:failures = 0
$global:P71BatchReads = 0
function Assert($Condition, [string]$Message) {
    $script:checks++
    if (-not $Condition) {
        $script:failures++
        Write-Host "FAIL - $Message"
    }
}
function Encode([string]$Value) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value)) }
$global:P71BatchValues = @(
    @{name='bu-registry'; value=',sales=group-sales:1000,'}
    @{name='bu-parents'; value=',,'}
    @{name='bu-modes'; value=',,'}
    @{name='bu-members'; value=',,'}
    @{name='allow-standard'; value=',,'}
    @{name='allow-premium'; value=',,'}
    @{name='models-standard'; value=',claude-sonnet-5,'}
    @{name='models-premium'; value=',claude-sonnet-5,'}
    @{name='tpm-standard'; value='100'}
    @{name='tpm-premium'; value='200'}
    @{name='quota-standard'; value='1000'}
    @{name='quota-premium'; value='2000'}
    @{name='quota-org'; value='5000'}
    @{name='quota-overrides'; value=',,'}
    @{name='usd-budgets'; value=(Encode '{"schema_version":1,"price_book":{"date":"2026-09-16","models":{"claude-sonnet-5":{"inputPerM":"2","outputPerM":"10"}}},"items":{"organization:sales":{"amount_usd":"0.02","period":"month","price_book_date":"2026-09-16"}}}')}
    @{name='usd-budget-state'; value=(Encode '{"reconciled_at":"2026-09-27T12:00:00Z","valid_until":"2026-09-27T12:15:00Z","items":{"organization:sales":{"spent_usd":null,"status":"unpriced"}}}')}
    @{name='private-key'; value='private-test-value'; secret=$true}
)
function az {
    if (($args[0..2] -join ' ') -ne 'apim nv list') { throw 'Only a named-value list is permitted.' }
    $global:P71BatchReads++
    $global:LASTEXITCODE = 0
    ConvertTo-Json -InputObject $global:P71BatchValues -Depth 10 -Compress
}
$folder = Join-Path $root '.finops-evidence'
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$inputFile = Join-Path $folder ("p71-batch-test-" + [guid]::NewGuid().ToString('N') + '.json')
function Read-Bridge([string]$Action, [bool]$Snapshot) {
    @{action=$Action; parameters=@{snapshot=$Snapshot}} | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $inputFile -Encoding UTF8
    $json = & (Join-Path $root 'scripts\Invoke-ClaudeFinOps.ps1') -InputFile $inputFile `
        -ResourceGroup 'rg-contoso' -ApimName 'apim-contoso'
    $parsed = $json | ConvertFrom-Json
    if ($parsed.error) { Write-Host "Bridge error: $($parsed.error)" }
    return $parsed
}
try {
    $batch = Read-Bridge 'read' $true
    Assert ($global:P71BatchReads -eq 1) 'One named-value list supplies the complete snapshot.'
    Assert ($null -ne $batch.registry -and @($batch.registry).Count -eq 1) 'The registry keeps its array shape on both hosts.'
    Assert (@($batch.registry)[0].TokensPerMonth -eq 1000) 'Token limits are preserved.'
    Assert (@($batch.reads.usd_budgets.items)[0].amount_usd -eq '0.02') 'USD definitions keep exact decimal strings.'
    Assert ($null -ne $batch.reads.usd_status.items -and $batch.reads.usd_status.items.'organization:sales'.spent_usd -eq $null) 'Unpriced spend stays null.'
    Assert ($batch.reads.usd_price_book.price_book.date -eq '2026-09-16') 'Price-book reads share the snapshot.'
    Assert (($batch | ConvertTo-Json -Depth 30) -notmatch 'private-test-value') 'No secret named value is returned.'
    foreach ($action in @('usd_budgets', 'usd_status', 'usd_price_book')) {
        $single = Read-Bridge $action $false
        Assert (($single | ConvertTo-Json -Depth 30 -Compress) -ceq ($batch.reads.$action | ConvertTo-Json -Depth 30 -Compress)) "Batch and existing $action reads agree."
    }
    ($global:P71BatchValues | Where-Object { $_.name -eq 'usd-budget-state' }).value = 'not-base64'
    $before = $global:P71BatchReads
    $invalid = Read-Bridge 'read' $true
    Assert ($global:P71BatchReads -eq $before + 1) 'A failed optional read does not trigger another list.'
    Assert ($invalid.reads.usd_status.exit_code -eq 7) 'Invalid USD state is an explicit batch error.'
    Assert ($invalid.reads.usd_status.error -match 'usd_status') 'The error names its failed read.'
    Assert (@($invalid.catalog.organizations)[0].id -eq 'sales') 'A failed USD read does not erase the valid catalog.'
}
finally {
    Remove-Item -LiteralPath $inputFile -ErrorAction SilentlyContinue
    Remove-Variable -Name P71BatchReads,P71BatchValues -Scope Global
}
Write-Host "$($script:checks - $script:failures)/$script:checks AUM batch read assertions passed."
if ($script:failures) { exit 1 }
