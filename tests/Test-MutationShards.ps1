# The executable manifests, not a second hand-maintained list, define coverage.
# Listing and execution must use the same original mutation indices.
$ErrorActionPreference = 'Stop'
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

function Read-Inventory([string]$Path, [string]$Shard = '') {
    $options = @('-NoProfile', '-NonInteractive', '-File', $Path, '-ListMutations')
    if ($Shard) { $options += @('-Shard', $Shard) }
    $text = & pwsh @options 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Inventory failed for $Path ${Shard}: $text" }
    @($text | ConvertFrom-Json)
}

function Same-Inventory($Left, $Right) {
    if ($Left.Count -ne $Right.Count) { return $false }
    for ($i = 0; $i -lt $Left.Count; $i++) {
        if ($Left[$i].Index -ne $Right[$i].Index -or $Left[$i].Name -cne $Right[$i].Name) { return $false }
    }
    return $true
}

$runner = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-All.ps1'))
foreach ($harness in @(
    @{ Script = 'Test-BusinessUnitsNegative.ps1'; Parts = 4 },
    @{ Script = 'Test-TurnstileNegative.ps1'; Parts = 2 }
)) {
    $path = Join-Path $PSScriptRoot $harness.Script
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $canList = 'Shard' -in $parameters -and 'ListMutations' -in $parameters
    Assert "$($harness.Script) exposes safe shard inventories" $canList
    if (-not $canList) { continue }

    # Evaluate only manifest construction, independently of the selector. This
    # includes generated cases (Turnstile appends five for each of two scopes).
    # A selector dropping work in BOTH modes must not make the union pass.
    $manifest = [regex]::Matches([IO.File]::ReadAllText($path), '(?s)# BEGIN MUTATION MANIFEST(.*?)# END MUTATION MANIFEST')
    if ($manifest.Count -ne 1) { throw "Missing or ambiguous manifest in $path" }
    $declared = @(& ([scriptblock]::Create($manifest[0].Groups[1].Value + '; $mutations')))
    $names = @($declared | ForEach-Object Name)
    $full = @(Read-Inventory $path)
    Assert "$($harness.Script) lists every declared mutation, in original order" (
        $names.Count -gt 0 -and $full.Count -eq $names.Count -and
        ($full.Name -join '|') -ceq ($names -join '|') -and
        ($full.Index -join ',') -eq ((0..($names.Count - 1)) -join ',')
    ) "$($full.Count) listed, $($names.Count) declared"

    $union = @()
    for ($part = 0; $part -lt $harness.Parts; $part++) {
        $shard = "$part/$($harness.Parts)"
        $listed = @(Read-Inventory $path $shard)
        $expected = @($full | Where-Object { $_.Index % $harness.Parts -eq $part })
        Assert "$($harness.Script) shard $shard selects exactly its modulo indices" (Same-Inventory $listed $expected)
        $union += $listed
        $registration = "(?m)^\s*Invoke-Check\s+'[^']+'\s+'" + [regex]::Escape($harness.Script) +
            "'\s+@\{\s*Shard\s*=\s*'" + [regex]::Escape($shard) + "'\s*\}"
        Assert "shard $shard of $($harness.Script) is registered exactly once" ([regex]::Matches($runner, $registration).Count -eq 1)
    }
    Assert "$($harness.Script) shard union equals the complete unsharded inventory" (
        (Same-Inventory @($union | Sort-Object Index) $full) -and @($union.Index | Sort-Object -Unique).Count -eq $full.Count
    ) "$($union.Count) across shards, $($full.Count) unsharded"
    $whole = @(Read-Inventory $path '0/1')
    Assert "$($harness.Script) 0/1 is the unsharded run" (Same-Inventory $whole $full)
    $out = & pwsh -NoProfile -NonInteractive -File $path -Shard '4/4' -ListMutations 2>&1 | Out-String
    Assert "$($harness.Script) refuses an out-of-range shard before running" ($LASTEXITCODE -ne 0 -and $out -match 'Shard')

    # Prove the comparator does not hide either loss or duplicate work.
    Assert 'inventory comparison catches a missing mutation' (-not (Same-Inventory @($full | Select-Object -Skip 1) $full))
    $duplicate = @($full)
    $duplicate[0] = $duplicate[1]
    Assert 'inventory comparison catches a duplicate replacing a mutation' (-not (Same-Inventory $duplicate $full))
    Write-Host "  Inventory: $($harness.Script) = $($full.Count) mutations in $($harness.Parts) shards."
}
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }

. (Join-Path $PSScriptRoot 'Select-MutationShard.ps1')
foreach ($bad in '0/0', '-1/4', '4/4', '0/17', 'a/2', '1', '0/999999999999999999999') {
    $threw = $false
    try { Get-MutationShardIndices -Count 100 -Shard $bad | Out-Null } catch { $threw = $true }
    Assert "invalid shard '$bad' is rejected" $threw
}
Assert 'more shards than mutations do not duplicate work' (
    (@(0..3 | ForEach-Object { Get-MutationShardIndices -Count 2 -Shard "$_/4" }) -join ',') -eq '0,1'
)
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Shards run exactly the complete mutation set.' -ForegroundColor Green
exit 0
