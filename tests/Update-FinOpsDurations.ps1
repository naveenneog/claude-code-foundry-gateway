# Rewrites tests/finops-test-durations.json from pytest JUnit reports of cli/finops/tests.
# A file's weight is the sum of its test cases' times in whole seconds, rounded up, at least 1.
# Pass the report of one complete run, or one report from each shard of the same run.
param(
    [Parameter(Mandatory)][string[]]$JUnitXml,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'finops-test-durations.json'),
    [string]$TestDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'cli\finops\tests'),
    [ValidateRange(1, 3600)][int]$DefaultSeconds = 10
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Select-FinOpsShard.ps1')
$invariant = [Globalization.CultureInfo]::InvariantCulture
$files = @(Get-FinOpsTestFile $TestDirectory)
$modules = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
foreach ($file in $files) { $modules[[IO.Path]::GetFileNameWithoutExtension($file)] = $file }
$sums = [Collections.Generic.Dictionary[string, double]]::new([StringComparer]::Ordinal)
$cases = 0
$total = 0.0
foreach ($path in $JUnitXml) {
    [xml]$report = Get-Content -LiteralPath $path -Raw
    foreach ($case in @($report.SelectNodes('//testcase'))) {
        # pytest writes the module path as dotted segments, then any class names.
        $module = @(([string]$case.classname) -split '\.' | Where-Object { $modules.ContainsKey($_) }) | Select-Object -First 1
        if (-not $module) { throw "Test case '$($case.classname)::$($case.name)' names no file in $TestDirectory." }
        $seconds = [double]::Parse([string]$case.time, $invariant)
        $sums[$modules[$module]] = $(if ($sums.ContainsKey($modules[$module])) { $sums[$modules[$module]] } else { 0.0 }) + $seconds
        $cases++
        $total += $seconds
    }
}
if (-not $cases) { throw 'The reports contain no test cases.' }
$weights = [ordered]@{}
foreach ($file in $files) {
    if ($sums.ContainsKey($file)) { $weights[$file] = [long][math]::Max(1, [math]::Ceiling($sums[$file])) }
}
$document = [ordered]@{
    SchemaVersion  = 1
    DefaultSeconds = $DefaultSeconds
    Source         = ('{0} test cases, {1} s in total, summed per file from pytest JUnit reports on {2}. Whole seconds, rounded up. A file without a weight takes DefaultSeconds.' -f
        $cases, $total.ToString('0.0', $invariant), (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd', $invariant))
    Seconds        = $weights
}
$json = (ConvertTo-Json -InputObject $document -Depth 3).Replace("`r`n", "`n")
[IO.File]::WriteAllText($OutputPath, $json + "`n")
Write-Host "Wrote $($weights.Count) file weights from $cases test cases to $OutputPath."
