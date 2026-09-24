param([string]$FixturePath = (Join-Path $PSScriptRoot 'fixtures\aum-registry.json'))
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ClaudeBusinessUnit.ps1')
function ConvertTo-OrderedMap($Object) {
    $map = [ordered]@{}
    foreach ($p in $Object.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}
$results = @(foreach ($f in @(Get-Content -Raw $FixturePath | ConvertFrom-Json)) {
    [ordered]@{
        name = $f.name
        registry = ConvertTo-ClaudeBuRegistry @($f.units)
        parents = ConvertTo-ClaudeBuParents (ConvertTo-OrderedMap $f.parents)
        members = ConvertTo-ClaudeBuMembers (ConvertTo-OrderedMap $f.members)
        overrides = ConvertTo-ClaudeBuMembers (ConvertTo-OrderedMap $f.overrides)
        modes = ConvertTo-ClaudeBuModes (ConvertTo-OrderedMap $f.modes)
    }
})
ConvertTo-Json -InputObject $results -Depth 5 -Compress
