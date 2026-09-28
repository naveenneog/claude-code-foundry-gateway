# Fast contracts: no product checks, Azure calls or real workflow runs.
$ErrorActionPreference = 'Stop'
$fail = 0
function Assert($Name, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name - $Detail" -ForegroundColor Red; $script:fail++ }
}
function Rejects($Name, [scriptblock]$Action, [string]$Message) {
    $errorText = ''
    try { & $Action | Out-Null } catch { $errorText = $_.Exception.Message }
    Assert $Name ($errorText -match $Message) $errorText
}

$library = Join-Path $PSScriptRoot 'TestAll-Sharding.ps1'
if (-not (Test-Path -LiteralPath $library)) {
    Write-Host '[FAIL] TestAll-Sharding.ps1 is missing: deterministic ownership and coverage are not implemented.'
    exit 1
}
. $library

$fixture = @'
param([switch]$IncludeAzure)
# BEGIN CHECK REGISTRATION
Invoke-Check 'first' 'First.ps1'
    Invoke-Check 'second' 'Second.ps1'
Invoke-Check 'third' 'Third.ps1'
Invoke-Check 'exclusive' 'Exclusive.ps1' -SerialLane
$optionalSkip = if (-not (Test-Path 'not-a-prerequisite-probe')) { 'fixture prerequisite absent' } else { '' }
Invoke-Check 'optional' 'Optional.ps1' -SkipReason $optionalSkip
if ($IncludeAzure) {
    Invoke-Check 'live' 'Live.ps1' -Azure
}
# END CHECK REGISTRATION
'@
$registration = @(Get-TestAllRegistration -Text $fixture)
Assert 'static registration keeps all offline labels in declaration order' (
    ($registration.Name -join '|') -ceq 'first|second|third|exclusive|optional')
Assert 'registration can also inventory opt-in live checks without running them' (
    (@(Get-TestAllRegistration -Text $fixture -IncludeAzure).Name -join '|') -ceq 'first|second|third|exclusive|optional|live')
Assert 'the registered reason is read without executing prerequisite probes' (
    ($registration[4].SkipReasons -join '|') -ceq 'fixture prerequisite absent')
Rejects 'ambiguous registration markers fail' {
    Get-TestAllRegistration -Text ($fixture + "`n# BEGIN CHECK REGISTRATION")
} 'registration'
Rejects 'duplicate labels fail' {
    Get-TestAllRegistration -Text ($fixture.Replace("'second'", "'first'"))
} 'duplicate'
Rejects 'computed labels cannot disappear from a static inventory' {
    Get-TestAllRegistration -Text ($fixture.Replace("'second'", '"computed-$label"'))
} 'literal'
Rejects 'an undeclared dynamic skip reason fails closed' {
    Get-TestAllRegistration -Text ($fixture.Replace('-SkipReason $optionalSkip', '-SkipReason $unknown'))
} 'reason'
Rejects 'an empty registration cannot prove coverage' {
    Get-TestAllRegistration -Text "# BEGIN CHECK REGISTRATION`n# END CHECK REGISTRATION"
} 'empty'
Rejects 'registered scripts cannot escape the test and scripts directories' {
    Get-TestAllRegistration -Text ($fixture.Replace("'Second.ps1'", "'..\Second.ps1'"))
} 'identity'

$timing = @{ SchemaVersion = 1; ShardCount = 2; DefaultSeconds = 10
    Seconds = @{ first = 100; second = 80; third = 60; exclusive = 40 } }
$plan = @(New-TestAllShardPlan -Registration $registration -Timing $timing -ShardCount 2)
Assert 'LPT has a fixed golden assignment, ties broken by original index and bin index' (
    ($plan.ShardIndex -join ',') -eq '0,1,1,0,0')
Assert 'an unknown check gets the committed default weight' ($plan[4].EstimatedSeconds -eq 10)
Assert 'ownership remains in original registration order' (($plan.Name -join '|') -ceq ($registration.Name -join '|'))
$priorCulture = [cultureinfo]::CurrentCulture
try {
    foreach ($culture in 'en-US', 'tr-TR', 'sv-SE') {
        [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo($culture)
        $again = @(New-TestAllShardPlan -Registration $registration -Timing $timing -ShardCount 2)
        Assert "assignment is identical in $culture" (($again.ShardIndex -join ',') -eq '0,1,1,0,0')
    }
} finally { [cultureinfo]::CurrentCulture = $priorCulture }
Rejects 'zero shards fail' { New-TestAllShardPlan $registration $timing 0 } 'ShardCount'
Rejects 'too many shards fail instead of creating unprovable empty shards' {
    New-TestAllShardPlan $registration $timing 6
} 'ShardCount'
$badTiming = $timing.Clone(); $badTiming.DefaultSeconds = 0
Rejects 'a nonpositive default fails' { New-TestAllShardPlan $registration $badTiming 2 } 'weight'
$badTiming = $timing.Clone(); $badTiming.Seconds = @{ first = -1 }
Rejects 'negative weights fail' { New-TestAllShardPlan $registration $badTiming 2 } 'weight'
$badTiming = $timing.Clone(); $badTiming.Seconds = @{ first = '100' }
Rejects 'string weights fail instead of depending on locale coercion' {
    New-TestAllShardPlan $registration $badTiming 2
} 'weight'
$local = @(@{ Name = 'exclusive'; Reason = 'fixture needs a local device' })
$localPlan = @(New-TestAllShardPlan $registration $timing 2 -LocalOnly $local)
Assert 'local-only work remains in the complete inventory with explicit ownership' (
    $localPlan.Count -eq 5 -and $localPlan[3].ShardIndex -eq -1 -and
    $localPlan[3].LocalReason -ceq 'fixture needs a local device')
Rejects 'a local-only entry needs a reason' {
    New-TestAllShardPlan $registration $timing 2 -LocalOnly @(@{ Name = 'exclusive'; Reason = '' })
} 'reason'
Rejects 'an unregistered local-only entry fails' {
    New-TestAllShardPlan $registration $timing 2 -LocalOnly @(@{ Name = 'unknown'; Reason = 'no' })
} 'registered'
Rejects 'duplicate local-only entries fail' {
    New-TestAllShardPlan $registration $timing 2 -LocalOnly @($local[0], $local[0])
} 'duplicate'
$equalTiming = @{ SchemaVersion = 1; DefaultSeconds = 10; Seconds = @{} }
Assert 'equal weights use registration index rather than label sorting' (
    ((New-TestAllShardPlan $registration $equalTiming 2).ShardIndex -join ',') -eq '0,1,0,1,0')
$badTiming = $timing.Clone(); $badTiming.DefaultSeconds = [double]::PositiveInfinity
Rejects 'an infinite default fails' { New-TestAllShardPlan $registration $badTiming 2 } 'weight'
$badTiming = $timing.Clone(); $badTiming.SchemaVersion = '1'
Rejects 'the timing schema version is an integer rather than coercible text' {
    New-TestAllShardPlan $registration $badTiming 2
} 'schema'

$commit = 'a' * 40
$tree = 'b' * 40
# Receipt tests use fixed ownership, so an allocator regression cannot corrupt their fixtures.
$plan = @(for ($i = 0; $i -lt $registration.Count; $i++) {
    [pscustomobject]@{
        Id = $i; Name = $registration[$i].Name; Script = $registration[$i].Script
        ShardIndex = @(0, 1, 1, 0, 0)[$i]
    }
})
$localPlan = @($plan | ForEach-Object {
    [pscustomobject]@{
        Id = $_.Id; Name = $_.Name; Script = $_.Script
        ShardIndex = $(if ($_.Name -ceq 'exclusive') { -1 } else { $_.ShardIndex })
    }
})
function New-FixtureReceipts($Assigned = $plan, [switch]$WithLocal) {
    $indices = @(0, 1)
    if ($WithLocal) { $indices += -1 }
    foreach ($index in $indices) {
        $owned = @($Assigned | Where-Object ShardIndex -eq $index)
        [pscustomobject]@{
            SchemaVersion = 1; Mode = $(if ($index -eq -1) { 'local' } else { 'ci' })
            Commit = $commit; Tree = $tree; ShardIndex = $index; ShardCount = 2
            RunId = $(if ($index -eq -1) { '' } else { '1234' }); RunAttempt = 1
            Completed = $true; OwnedChecks = @($owned.Name)
            StartedAt = '2026-09-28T10:00:00Z'; FinishedAt = '2026-09-28T10:00:03Z'; Seconds = 3.0
            Results = @($owned | ForEach-Object {
                [pscustomobject]@{
                    RegistrationId = $_.Id; Name = $_.Name; Script = $_.Script
                    Result = 'PASS'; Seconds = 1.0; ExitCode = 0; SkipReason = ''
                }
            })
        }
    }
}
function Copy-Receipts { @(New-FixtureReceipts | ConvertTo-Json -Depth 12 | ConvertFrom-Json) }
function Merge-Fixture($Receipts, $Assigned = $plan) {
    @(Assert-TestAllReceiptSet -Receipts $Receipts -Registration $registration -Plan $Assigned `
        -ShardCount 2 -Commit $commit -Tree $tree -RunId '1234' -RunAttempt 1)
}
$receipts = @(New-FixtureReceipts)
$merged = @(Merge-Fixture $receipts)
Assert 'a complete set merges once in original registration order' (
    ($merged.Name -join '|') -ceq ($registration.Name -join '|'))
Assert 'arrival order never changes the summary order' (
    ((Merge-Fixture @($receipts[1], $receipts[0])).Name -join '|') -ceq ($registration.Name -join '|'))
Rejects 'a missing shard fails' { Merge-Fixture @($receipts[0]) } 'shard'
$bad = Copy-Receipts; $bad[0].Results = @($bad[0].Results | Select-Object -Skip 1)
Rejects 'a missing result fails' { Merge-Fixture $bad } 'missing|ownership'
$bad = Copy-Receipts; $bad[0].Results += $bad[0].Results[0]
Rejects 'a duplicate result fails' { Merge-Fixture $bad } 'duplicate'
$bad = Copy-Receipts; $bad[1].Commit = 'c' * 40
Rejects 'another SHA fails' { Merge-Fixture $bad } 'commit'
$bad = Copy-Receipts; $bad[1].Tree = 'c' * 40
Rejects 'another tree fails even at the same SHA' { Merge-Fixture $bad } 'tree'
$bad = Copy-Receipts; $bad[0].Results[0].Result = 'FAIL'; $bad[0].Results[0].ExitCode = 7
Rejects 'a failing check fails the merge' { Merge-Fixture $bad } 'FAIL'
$bad = Copy-Receipts; $bad[0].Results[0].ExitCode = 7
Rejects 'a PASS label cannot hide a failed exit code' { Merge-Fixture $bad } 'exit'
$bad = Copy-Receipts; $bad[0].Results[0].ExitCode = $null
Rejects 'a PASS without a process exit is not evidence' { Merge-Fixture $bad } 'exit'
$bad = Copy-Receipts; $bad[0].Completed = $false
Rejects 'the completion guard is mandatory' { Merge-Fixture $bad } 'complete'
$bad = Copy-Receipts; $bad[0].Completed = 'true'
Rejects 'completion must be a boolean, not truthy text' { Merge-Fixture $bad } 'complete'
$bad = Copy-Receipts; $bad[0].OwnedChecks = @('second', 'exclusive', 'optional')
Rejects 'invented ownership fails even if all results are present' { Merge-Fixture $bad } 'ownership'
$bad = Copy-Receipts; $bad[0].Results[0].Name = 'unknown'
Rejects 'unregistered checks fail' { Merge-Fixture $bad } 'registered'
$bad = Copy-Receipts; $bad[0].Results[0].Script = 'Wrong.ps1'
Rejects 'the label must identify the registered script' { Merge-Fixture $bad } 'identity'
$bad = Copy-Receipts; $bad[0].Results[0].RegistrationId = 4
Rejects 'the original registration index is bound to the label' { Merge-Fixture $bad } 'identity'
$bad = Copy-Receipts; $bad[0].Results[0].Seconds = -1
Rejects 'negative durations fail' { Merge-Fixture $bad } 'duration'
$bad = Copy-Receipts; $bad[0].RunId = '9999'
Rejects 'receipts from another run fail' { Merge-Fixture $bad } 'run'
$bad = Copy-Receipts; $bad[0].RunAttempt = 2
Rejects 'mixed rerun attempts fail' { Merge-Fixture $bad } 'attempt'
$bad = Copy-Receipts; $bad[0].SchemaVersion = 2
Rejects 'unknown receipt schemas fail' { Merge-Fixture $bad } 'schema'
$bad = Copy-Receipts; $bad[0].ShardCount = 3
Rejects 'inconsistent shard counts fail' { Merge-Fixture $bad } 'shard'
$bad = Copy-Receipts
$optional = $bad[0].Results | Where-Object Name -eq 'optional'
$optional.Result = 'SKIP'; $optional.ExitCode = $null; $optional.SkipReason = 'fixture prerequisite absent'
Assert 'SKIP is counted only with its exact registered reason' ((Merge-Fixture $bad).Count -eq 5)
$optional.SkipReason = 'machine too busy'
Rejects 'an invented skip reason fails' { Merge-Fixture $bad } 'reason'
$bad = Copy-Receipts; $bad[0].Results[0].Result = 'SKIP'
$bad[0].Results[0].SkipReason = 'fixture prerequisite absent'; $bad[0].Results[0].ExitCode = $null
Rejects 'another checks registered reason cannot authorize a skip' { Merge-Fixture $bad } 'reason'
$withLocal = @(New-FixtureReceipts -Assigned $localPlan -WithLocal)
Assert 'CI union local evidence covers every registered check exactly once' (
    (Merge-Fixture $withLocal $localPlan).Count -eq 5)
Rejects 'local-only does not mean unverified: missing local evidence fails' {
    Merge-Fixture @($withLocal | Where-Object Mode -eq 'ci') $localPlan
} 'local'
Rejects 'an empty receipt set is not coverage' { Merge-Fixture @() } 'shard'
Rejects 'a duplicate shard receipt fails' { Merge-Fixture @($receipts + $receipts[0]) } 'shard'
Rejects 'expected source identities must be full Git object IDs' {
    Assert-TestAllReceiptSet $receipts $registration $plan 2 'short' $tree
} 'object IDs'
$bad = Copy-Receipts; $bad[0].Mode = 'other'
Rejects 'unknown receipt modes fail' { Merge-Fixture $bad } 'mode'
$bad = Copy-Receipts; $bad[0].ShardIndex = 2
Rejects 'a receipt outside the shard range fails' { Merge-Fixture $bad } 'range'
$bad = Copy-Receipts; $bad[0].ShardIndex = '0'
Rejects 'a receipt shard index cannot be text' { Merge-Fixture $bad } 'coordinates'
$bad = Copy-Receipts; $bad[0].Seconds = -1
Rejects 'a negative receipt wall duration fails' { Merge-Fixture $bad } 'duration'
$bad = Copy-Receipts
$optional = $bad[0].Results | Where-Object Name -eq 'optional'
$optional.Result = 'SKIP'; $optional.SkipReason = 'fixture prerequisite absent'
Rejects 'a skipped check cannot claim a process exit code' { Merge-Fixture $bad } 'reason'
$bad = Copy-Receipts; $bad[0].SchemaVersion = '1'
Rejects 'the receipt schema version cannot be text' { Merge-Fixture $bad } 'schema'
$bad = Copy-Receipts; $bad[0].ShardCount = '2'
Rejects 'the receipt shard count cannot be text' { Merge-Fixture $bad } 'coordinates'
$bad = Copy-Receipts; $bad[0].Results[0].RegistrationId = '0'
Rejects 'a result registration index cannot be text' { Merge-Fixture $bad } 'identity'
$bad = Copy-Receipts; $bad[0].RunAttempt = '1'
Rejects 'a workflow attempt cannot be text' { Merge-Fixture $bad } 'attempt'
$bad = Copy-Receipts; $bad[0].StartedAt = '2026-09-28T11:00:00Z'
Rejects 'a reversed receipt time interval fails' { Merge-Fixture $bad } 'interval'
$bad = Copy-Receipts; $bad[0].Results[0].SkipReason = 'fixture prerequisite absent'
Rejects 'a passed process cannot also claim a prerequisite skip' { Merge-Fixture $bad } 'skip'
$bad = Copy-Receipts; $bad[0].Results[0].Seconds = [double]::NaN
Rejects 'a nonfinite result duration fails' { Merge-Fixture $bad } 'duration'
$bad = Copy-Receipts; $bad[0].RunId = ''; $bad[0].RunAttempt = 0
Rejects 'inferred run identity cannot change after a receipt without hosted metadata' {
    Assert-TestAllReceiptSet $bad $registration $plan 2 $commit $tree
} 'run'
$single = (Copy-Receipts)[0]
$single.ShardCount = 1; $single.OwnedChecks = @('first'); $single.Results = @($single.Results[0])
$singlePlan = @($plan[0])
$single.OwnedChecks = 'first'
Rejects 'single-check ownership still needs a JSON array' {
    Assert-TestAllReceiptSet @($single) @($registration[0]) $singlePlan 1 $commit $tree
} 'array'
$single.OwnedChecks = @('first'); $single.Results = $single.Results[0]
Rejects 'single-check results still need a JSON array' {
    Assert-TestAllReceiptSet @($single) @($registration[0]) $singlePlan 1 $commit $tree
} 'array'
$config = Get-TestAllConfiguration
Assert 'the committed configuration assigns the full registration' (
    $config.Plan.Count -eq $config.Registration.Count -and
    @($config.Plan | Where-Object ShardIndex -ge 0 | Group-Object ShardIndex).Count -eq $config.ShardCount)
$directory = Join-Path ([IO.Path]::GetTempPath()) ('test-all-config-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $directory | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'Test-All.ps1'), $fixture)
    $timingPath = Join-Path $directory 'test-all-durations.json'
    $localPath = Join-Path $directory 'test-all-local-only.json'
    [IO.File]::WriteAllText($timingPath, ($timing | ConvertTo-Json -Depth 5))
    [IO.File]::WriteAllText($localPath, '{"SchemaVersion":1,"Checks":[]}')
    Assert 'configuration reads the committed shard count without running checks' (
        (Get-TestAllConfiguration -Directory $directory).ShardCount -eq 2)
    Assert 'an explicit shard-count override is applied deterministically' (
        ((Get-TestAllConfiguration -Directory $directory -ShardCount 1).Plan.ShardIndex -join ',') -eq '0,0,0,0,0')
    $badTiming = $timing.Clone(); $badTiming.ShardCount = '2'
    [IO.File]::WriteAllText($timingPath, ($badTiming | ConvertTo-Json -Depth 5))
    Rejects 'the configured shard count must be an integer' {
        Get-TestAllConfiguration -Directory $directory
    } 'integer'
    [IO.File]::WriteAllText($timingPath, ($timing | ConvertTo-Json -Depth 5))
    foreach ($invalidManifest in '{"SchemaVersion":2,"Checks":[]}', '{"SchemaVersion":1}', '{"SchemaVersion":1,"Checks":{}}') {
        [IO.File]::WriteAllText($localPath, $invalidManifest)
        Rejects "invalid local-only manifests fail: $invalidManifest" {
            Get-TestAllConfiguration -Directory $directory
        } 'schema'
    }
}
finally { if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force } }

$real = @(Get-TestAllRegistration)
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Test-All.ps1'))
$block = [regex]::Match($source, '(?s)# BEGIN CHECK REGISTRATION(.*?)# END CHECK REGISTRATION').Groups[1].Value
$offline = $block.Substring(0, $block.IndexOf('if ($IncludeAzure)'))
$independent = @([regex]::Matches($offline, "(?m)^[ \t]*Invoke-Check[ \t]+'([^']+)'[ \t]+'([^']+)'") |
    ForEach-Object { $_.Groups[1].Value })
Assert 'the real inventory equals an independent Get-Registered-style parse' (
    $real.Count -ge 90 -and ($real.Name -join '|') -ceq ($independent -join '|'))

if ($fail) { Write-Host "$fail sharding assertion(s) failed."; exit 1 }
Write-Host 'Deterministic ownership and complete exact-source coverage passed.' -ForegroundColor Green
exit 0
