param([string]$FixturePath = (Join-Path $PSScriptRoot 'fixtures\aum-mode-inputs.json'))
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ClaudeBudgetModes.ps1')
$fixtures = Get-Content -Raw -Encoding UTF8 $FixturePath | ConvertFrom-Json
$rows = @(foreach ($fixture in $fixtures) {
    [pscustomobject]@{name=$fixture.name; canonical=(ConvertTo-ClaudeBuModes (ConvertFrom-ClaudeBuModes $fixture.raw))}
})
ConvertTo-Json -InputObject $rows -Depth 5 -Compress
