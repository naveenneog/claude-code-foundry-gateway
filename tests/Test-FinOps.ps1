# Run the package's offline checks with this worktree's isolated interpreter.
# -Shard i/n runs one part of the test files (tests/Select-FinOpsShard.ps1); Test-All registers
# every part. -ListFiles prints the selected files and their planned seconds as JSON, without Python.
param([string]$Shard = '', [switch]$ListFiles)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tests = Join-Path $root 'cli\finops\tests'
$targets = @($tests)
if ($Shard -or $ListFiles) {
    . (Join-Path $PSScriptRoot 'Select-FinOpsShard.ps1')
    $coordinates = if ($Shard) { ConvertFrom-FinOpsShard $Shard } else { [pscustomobject]@{ Index = 0; Count = 1 } }
    $files = @(Get-FinOpsTestFile $tests)
    $timing = Read-FinOpsTiming (Join-Path $PSScriptRoot 'finops-test-durations.json')
    $selected = @(Get-FinOpsShardPlan -File $files -Timing $timing -Count $coordinates.Count |
        Where-Object { $_.Shard -eq $coordinates.Index })
    if ($ListFiles) {
        ConvertTo-Json -InputObject @($selected | Select-Object Name, Seconds) -Compress
        exit 0
    }
    if (-not $selected.Count) {
        Write-Host "FAIL - AUM shard $Shard owns none of the $($files.Count) test files; use fewer shards."
        exit 1
    }
    $targets = @($selected | ForEach-Object { Join-Path $tests $_.Name })
    $planned = ($selected | Measure-Object Seconds -Sum).Sum
    Write-Host "AUM shard ${Shard}: $($selected.Count) of $($files.Count) test files, $planned s planned."
}
$python = Join-Path $root '.venv-finops\Scripts\python.exe'
if (-not (Test-Path $python)) {
    $python = Join-Path $root '.venv-finops\bin\python'
}
if (-not (Test-Path $python)) {
    Write-Host 'SKIP - AUM: no worktree Python venv. Create .venv-finops and install cli/finops[test].'
    exit 0
}
& $python -m pytest @targets -q
exit $LASTEXITCODE
