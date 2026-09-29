<#
.SYNOPSIS
Validates complete, exact-source Test-All evidence and prints its ordered summary.
#>
param(
    [Parameter(Mandatory)][string]$ReceiptDirectory,
    [string]$ExpectedCommit,
    [string]$ExpectedTree,
    [string]$RunId,
    [int]$RunAttempt = 0,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestAll-Sharding.ps1')
try {
    $identity = Get-TestAllIdentity -RequireClean
    if (-not $ExpectedCommit) { $ExpectedCommit = $identity.Commit }
    if (-not $ExpectedTree) { $ExpectedTree = $identity.Tree }
    if ($identity.Commit -cne $ExpectedCommit -or $identity.Tree -cne $ExpectedTree) {
        throw 'The checkout must match the expected commit and tree so registration is authoritative.'
    }
    $config = Get-TestAllConfiguration
    $paths = @(Get-ChildItem -LiteralPath $ReceiptDirectory -Recurse -File -Filter '*.json')
    if (-not $paths.Count) { throw 'No shard receipts were found.' }
    $receipts = @($paths | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    $results = @(Assert-TestAllReceiptSet -Receipts $receipts -Registration $config.Registration `
        -Plan $config.Plan -ShardCount $config.ShardCount -Commit $ExpectedCommit -Tree $ExpectedTree `
        -RunId $RunId -RunAttempt $RunAttempt)
    $start = ($receipts | ForEach-Object { [datetimeoffset]$_.StartedAt } | Sort-Object | Select-Object -First 1)
    $end = ($receipts | ForEach-Object { [datetimeoffset]$_.FinishedAt } | Sort-Object | Select-Object -Last 1)
    $wall = ($end - $start).TotalSeconds
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host ' Summary' -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    foreach ($result in $results) {
        $colour = if ($result.Result -eq 'PASS') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-4}  {1}  ({2} s)" -f $result.Result, $result.Name, $result.Seconds) -ForegroundColor $colour
        if ($result.Result -eq 'SKIP') { Write-Host "        $($result.SkipReason)" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host ("  {0:N1} s wall; {1:N1} s in checks; slowest:" -f $wall, ($results | Measure-Object Seconds -Sum).Sum)
    $results | Sort-Object Seconds -Descending | Select-Object -First 5 |
        ForEach-Object { Write-Host ("    {0,7:N1} s  {1}" -f $_.Seconds, $_.Name) }
    Write-Host "  Coverage: $($results.Count)/$($config.Registration.Count); $($config.ShardCount) CI shards; commit $ExpectedCommit; tree $ExpectedTree"
    Write-Host '  Wall above spans test execution, not the workflow queue/setup/merge interval.'
    if ($OutputPath) {
        [ordered]@{
            SchemaVersion = 1; Commit = $ExpectedCommit; Tree = $ExpectedTree; Completed = $true
            ShardCount = $config.ShardCount; Seconds = $wall; Results = $results
            Shards = @($receipts | Sort-Object ShardIndex | Select-Object Mode, ShardIndex, Seconds, StartedAt, FinishedAt, RunId, RunAttempt)
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
catch { Write-Host "Receipt merge failed: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
