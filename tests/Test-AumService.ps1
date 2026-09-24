param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$python = Join-Path $root '.venv-aum-service\Scripts\python.exe'
if (-not (Test-Path $python)) { $python = Join-Path $root '.venv-aum-service\bin\python' }
if (-not (Test-Path $python)) { throw 'Missing .venv-aum-service. See docs/AUM-SERVICE.md; Test-All records an explicit SKIP when absent.' }
$prior = $env:PYTHONPATH
$priorBytecode = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONPATH = Join-Path $root 'service\aum'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    & $python -m unittest discover -s (Join-Path $PSScriptRoot 'aum_service') -p 'test_*.py' -q
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & $python (Join-Path $PSScriptRoot 'aum_service\mutations.py')
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}
finally {
    $env:PYTHONPATH = $prior
    $env:PYTHONDONTWRITEBYTECODE = $priorBytecode
}
exit 0
