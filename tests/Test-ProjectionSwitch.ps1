# Split in P97: responsibility-specific suites are registered in tests/Test-All.ps1.
# Keep this wrapper so direct invocations of the old P95 suite name still run the switch evidence suite.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-ProjectionSwitchEvidence.ps1')
exit $LASTEXITCODE
