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

Write-Host "P97_RUNNER assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
