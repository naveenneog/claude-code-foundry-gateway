param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = & $Action }
    catch { $script:CapturedError = $_.Exception.Message }
}

$global:RunnerCalls = [Collections.Generic.List[string]]::new()
$global:RunnerStates = [Collections.Generic.Queue[string]]::new()
function az {
    $line = (@($args) -join ' ')
    $global:RunnerCalls.Add("az $line")
    $global:LASTEXITCODE = 0
    if ($line -like 'container show*') {
        if ($global:RunnerStates.Count) { return $global:RunnerStates.Dequeue() }
        return 'Running'
    }
    if ($line -like 'container start*') { return '' }
    throw "unexpected az call: $line"
}
function Start-Sleep { param([int]$Seconds) $global:RunnerCalls.Add("sleep $Seconds") }

. (Join-Path $root 'scripts\ClaudeRunner.ps1')

Write-Host 'P97 runner lifecycle'
$global:RunnerStates.Clear()
$global:RunnerStates.Enqueue('Terminated')
$global:RunnerStates.Enqueue('Pending')
$global:RunnerStates.Enqueue('Running')
Capture { Start-ClaudeProjectionRunner -ResourceGroup rg-p97 -Name aci-projtest-p97 -SubscriptionId 00000000-0000-4000-8000-000000000084 -WaitTimeoutSeconds 30 -PollSeconds 5 }
Assert 'stopped runner is started and returned when Running' (-not $CapturedError -and $CapturedResult.State -eq 'Running') $CapturedError
$calls = $RunnerCalls -join "`n"
Assert 'runner start uses az container start' ($calls -match 'az container start -g rg-p97 -n aci-projtest-p97 --subscription 00000000-0000-4000-8000-000000000084')
Assert 'runner state uses safe query' ($calls -match 'az container show -g rg-p97 -n aci-projtest-p97 --query instanceView.state -o tsv')
Assert 'runner poll is bounded and injectable' ($calls -match 'sleep 5')

$global:RunnerCalls.Clear()
$global:RunnerStates.Clear()
$global:RunnerStates.Enqueue('Stopped')
$global:RunnerStates.Enqueue('Stopped')
$global:RunnerStates.Enqueue('Stopped')
Capture { Start-ClaudeProjectionRunner -ResourceGroup rg-p97 -Name aci-projtest-p97 -WaitTimeoutSeconds 5 -PollSeconds 5 }
Assert 'runner timeout fails with redeploy remedy' ($CapturedError -match 'runner.*Running' -and $CapturedError -match 'Deploy-ClaudeProjection.ps1') $CapturedError

$global:RunnerCalls.Clear()
Capture { Start-ClaudeProjectionRunner -ResourceGroup 'bad rg' -Name aci-projtest-p97 }
Assert 'unsafe runner name is rejected before az' ($CapturedError -match 'letters, digits' -and $RunnerCalls.Count -eq 0) $CapturedError

# P98 council round 2 (Architect 4): a snapshot sent through the runner moves at about 1 KB a second (base64url
# chunks under 5,000 characters, one exec of about five seconds each). A transfer that cannot end before the
# snapshot's apply-by time is refused before the first exec, instead of failing hours later.
$snapshotFile = Join-Path ([IO.Path]::GetTempPath()) ('runner-deadline-' + [guid]::NewGuid().ToString('N') + '.json')
$expires = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
[IO.File]::WriteAllText($snapshotFile, '{"kind":"claude-entitlement-snapshot","expiresAt": ' + $expires + ',"records":["' + ('x' * 600000) + '"]}')
try {
    Capture { Get-RunnerFileDeadline -Path $snapshotFile }
    Assert 'the apply-by time is read from the snapshot header' ($CapturedResult -and $CapturedResult.ToUnixTimeSeconds() -eq $expires) "$CapturedError $CapturedResult"
    $global:RunnerCalls.Clear()
    Capture { Send-RunnerFile -ResourceGroup rg-p97 -Name aci-projtest-p97 -Path $snapshotFile -Destination /work/snapshot.json -Deadline ([DateTimeOffset]::FromUnixTimeSeconds($expires)) }
    Assert 'a snapshot transfer that would end after its apply-by time is refused before the first exec' (
        $CapturedError -match 'apply-by' -and $CapturedError -match 'P99' -and $CapturedError -match 'was not sent' -and $global:RunnerCalls.Count -eq 0) "$CapturedError | $($global:RunnerCalls -join ' | ')"
    # P98 confirmation round (UX): the refusal names what runs today at this size.
    Assert 'the refusal names the sync job command for a full sync of this size' (
        $CapturedError -match [regex]::Escape('.\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup rg-p97 -ApimName <apim> -NamePrefix p97 -AlertEmail <address>') -and
        $CapturedError -match 'az containerapp job start') $CapturedError
    $global:RunnerCalls.Clear()
    Capture { Send-RunnerFile -ResourceGroup rg-p97 -Name aci-projtest-p97 -Path $snapshotFile -Destination /work/snapshot.json -Deadline ([DateTimeOffset]::UtcNow.AddHours(2)) }
    Assert 'a transfer that ends before the apply-by time is started' ($CapturedError -notmatch 'apply-by' -and $global:RunnerCalls.Count -ge 1) "$CapturedError | $($global:RunnerCalls.Count) call(s)"
    Capture { Get-RunnerFileDeadline -Path (Join-Path $root 'sync\package.json') }
    Assert 'a file without an apply-by time has no deadline' (-not $CapturedError -and $null -eq $CapturedResult) "$CapturedError $CapturedResult"
}
finally { Remove-Item -LiteralPath $snapshotFile -Force -ErrorAction SilentlyContinue }
foreach ($caller in 'scripts\Deploy-ClaudeProjection.ps1', 'scripts\ClaudeProjectionSwitch.ps1', 'scripts\Sync-ClaudeAccess.ps1') {
    $callerText = [IO.File]::ReadAllText((Join-Path $root $caller))
    Assert "$caller sends its snapshot with the snapshot's apply-by time" ($callerText -match 'Send-RunnerFile [^\r\n]*-Path \$snapshot [^\r\n]*-Deadline \(Get-RunnerFileDeadline -Path \$snapshot\)')
}

Write-Host "P97_RUNNER assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
