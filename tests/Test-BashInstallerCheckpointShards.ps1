# P92 A14 (docs/adr/0047-lean-installer-phase-0.md): tests/Test-BashInstallerCheckpoint.ps1 runs as two
# Test-All checks within the default per-check timeout, and the two shards together run every check of the
# suite exactly once. The partition is read from the suite's syntax tree: every Assert sits inside one
# Test-ShardGroup block, and each group belongs to one shard. The weights are the measured durations in
# tests/test-all-durations.json.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Bash checkpoint suite shards' -ForegroundColor Cyan
$suitePath = Join-Path $root 'tests\Test-BashInstallerCheckpoint.ps1'
$runnerPath = Join-Path $root 'tests\Test-All.ps1'
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($suitePath, [ref]$null, [ref]$null)

# ------------------------------------------------------------------ the suite's own partition
$maps = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ShardGroups' }, $true))
$groups = [ordered]@{}
$count = 0
if ($maps.Count -eq 1) {
    $h = $maps[0].Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
    foreach ($kv in @($h.KeyValuePairs)) { $groups[[string]$kv.Item1.Value] = [int]$kv.Item2.Extent.Text }
    $countAst = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:ShardCount' }, $true))
    if ($countAst.Count -eq 1) { $count = [int]$countAst[0].Right.Extent.Text }
}
Assert 'A14 the suite declares its shard count and a map from each group of checks to one shard' ($count -ge 2 -and $groups.Count -ge 2 -and -not @($groups.Values | Where-Object { $_ -lt 0 -or $_ -ge $count }).Count -and
    (@($groups.Values | Sort-Object -Unique).Count -eq $count)) "count $count; $(($groups.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
$param = @($Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Shard' })
Assert 'A14 the suite takes -Shard i/n and selects groups only through Test-ShardGroup' ($param.Count -eq 1 -and @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ShardGroup' }, $true)).Count -eq 1)
$asserts = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert' }, $true))
$homeless = [System.Collections.Generic.List[string]]::new(); $twice = [System.Collections.Generic.List[string]]::new(); $byGroup = @{}
foreach ($a in $asserts) {
    $label = [string]$a.CommandElements[1].Extent.Text
    if ($label -match "^['""]harness:") { continue }
    $owners = @()
    for ($p = $a.Parent; $p; $p = $p.Parent) {
        if ($p -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
        foreach ($clause in $p.Clauses) {
            if (-not $clause.Item2.Extent.Text.Contains($a.Extent.Text)) { continue }
            $call = $clause.Item1.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-ShardGroup' }, $true)
            if ($call) { $owners += [string]$call.CommandElements[1].Extent.Text.Trim("'", '"') }
        }
    }
    if (-not $owners.Count) { $homeless.Add("line $($a.Extent.StartLineNumber)") }
    elseif ($owners.Count -gt 1 -or -not $groups.Contains($owners[0])) { $twice.Add("line $($a.Extent.StartLineNumber): $($owners -join ',')") }
    else { $byGroup[$owners[0]] = 1 + $(if ($byGroup.ContainsKey($owners[0])) { $byGroup[$owners[0]] } else { 0 }) }
}
Assert 'A14 bash-checkpoint-shards-cover-every-case-once: every check sits in exactly one group, and each group runs in exactly one shard' ($asserts.Count -ge 40 -and -not $homeless.Count -and -not $twice.Count -and
    -not @($groups.Keys | Where-Object { -not $byGroup.ContainsKey($_) }).Count) "outside a group: $($homeless -join ', '); ambiguous: $($twice -join '; '); per group: $(($byGroup.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"

# ------------------------------------------------------------------ Test-All registrations and weights
$runner = [IO.File]::ReadAllText($runnerPath)
$registrations = @([regex]::Matches($runner, "(?m)^\s*Invoke-Check\s+'([^']+)'\s+'Test-BashInstallerCheckpoint\.ps1'([^\r\n]*)") | ForEach-Object { [pscustomobject]@{ Name = $_.Groups[1].Value; Rest = $_.Groups[2].Value } })
$expected = @(for ($i = 0; $i -lt [Math]::Max($count, 1); $i++) { "@{ Shard = '$i/$count' }" })
$missing = @($expected | Where-Object { $e = $_; -not @($registrations | Where-Object { $_.Rest.Contains($e) }).Count })
Assert 'A14 Test-All registers one check per shard, at the default per-check timeout (no -TimeoutSeconds)' ($registrations.Count -eq $count -and -not $missing.Count -and
    -not @($registrations | Where-Object { $_.Rest -match 'TimeoutSeconds' }).Count) (($registrations | ForEach-Object { "$($_.Name)$($_.Rest)" }) -join ' || ')
$timing = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'test-all-durations.json')) | ConvertFrom-Json
$default = if ($runner -match '\[int\]\$CheckTimeoutSeconds = (\d+)') { [int]$Matches[1] } else { 0 }
$weights = @($registrations | ForEach-Object { $n = $_.Name; $w = $timing.Seconds.PSObject.Properties[$n]; [pscustomobject]@{ Name = $n; Seconds = $(if ($w) { [double]$w.Value } else { -1 }) } })
Assert 'A14 bash-checkpoint-shard-loads-under-default-timeout: each shard''s measured weight is at most half the default per-check timeout' ($default -gt 0 -and $weights.Count -eq $count -and
    -not @($weights | Where-Object { $_.Seconds -le 0 -or $_.Seconds -gt ($default / 2) }).Count) (($weights | ForEach-Object { "$($_.Name)=$($_.Seconds)" }) -join ', ')
Write-Host ''
Write-Host ("{0} checks, {1} failed" -f $script:checks, $script:fail)
if ($script:fail) { exit 1 }
