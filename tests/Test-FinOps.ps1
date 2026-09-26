# Run the package's offline checks with this worktree's isolated interpreter.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$python = Join-Path $root '.venv-finops\Scripts\python.exe'
if (-not (Test-Path $python)) {
    $python = Join-Path $root '.venv-finops\bin\python'
}
if (-not (Test-Path $python)) {
    Write-Host 'SKIP - AUM: no worktree Python venv. Create .venv-finops and install cli/finops[test].'
    exit 0
}
& $python -m pytest (Join-Path $root 'cli\finops\tests') -q
exit $LASTEXITCODE
