$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-applied-' + [guid]::NewGuid().ToString('N'))
$failed = 0; $count = 0
function Check([string]$Name, [scriptblock]$Test) {
    $script:count++
    try { $ok = [bool](& $Test); $why = '' } catch { $ok = $false; $why = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK] $Name" } else { $script:failed++; Write-Host "  [FAIL] $Name $why" }
}
function Write-Json($Path,$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false))) }
function Run-Flow($Parameters) {
    $pipeline = [powershell]::Create()
    try {
        $null = $pipeline.AddScript('param($entry,$values) & $entry @values *>&1').AddArgument((Join-Path $scratch 'Start-ClaudeGateway.ps1')).AddArgument($Parameters)
        $output = @(); $errorText = ''
        try { $output = @($pipeline.Invoke()) } catch { $errorText = $_.Exception.Message }
        [pscustomobject]@{ Failed = ($pipeline.HadErrors -or [bool]$errorText); Text = ($output -join "`n") + "`n" + $errorText + "`n" + ($pipeline.Streams.Error -join "`n") }
    }
    finally { $pipeline.Dispose() }
}
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts\flow') -Force | Out-Null
    foreach ($file in 'Start-ClaudeGateway.ps1','scripts\ClaudeChoice.ps1','scripts\flow\FlowContract.ps1') {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $scratch $file)
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\flow\Discovery.ps1'), @'
function Get-ClaudeFlowDiscovery {
    param($RecordPath,$Record)
    [pscustomobject]@{ record=$Record; gateway=$null; comparison=[pscustomobject]@{ status='match'; differences=@() } }
}
'@)
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\flow\Synthetic.ps1'), @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name='Synthetic'; Title='Generic decision'; DecisionKey='choice'; DependsOn=@(); Actions=@('Change') } }
function Get-ClaudeFlowStepQuestions {
    param($Record,$Discovery)
    @([pscustomobject]@{ Key='choice.value'; Type='Text'; Question='Proposed value'; Optional=$false })
}
function Get-ClaudeFlowStepPlan {
    param($Record,$Discovery)
    New-ClaudeFlowPlan -Step Synthetic -Actions @(New-ClaudeFlowAction -Verb Update -Target 'fixture') -Data @{ wanted=$Record.decisions.choice.value }
}
function Invoke-ClaudeFlowStep {
    param($Record,$Plan)
    $disk = Read-ClaudeDecisionRecord $Record.__recordPath
    @{ disk=$disk; passed=$Record.decisions.choice; plan=$Plan.Data.wanted } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Record.witness -Encoding UTF8
    $Record.decisions.choice.pin = 'changed-by-step'
    if ($Record.failApply) { throw 'synthetic apply failure' }
    @{ choice = [pscustomobject]@{ value=$Plan.Data.wanted; pin='new-pin' } }
}
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step='Synthetic'; Passed=$true; Checks=@() } }
function Get-ClaudeFlowReleaseInfo { param($Repo) [pscustomobject]@{ version='fixture'; commit='fixture' } }
function az { $global:LASTEXITCODE=0; '{"user":{"name":"admin@contoso.com"}}' }
'@)
    foreach ($failApply in $false,$true) {
        $recordPath = Join-Path $scratch "record-$failApply.json"
        $witness = Join-Path $scratch "witness-$failApply.json"
        $original = @{
            schemaVersion=2; witness=$witness; failApply=$failApply; history=@()
            decisions=@{ choice=@{ value='old'; pin='old-pin' }; unselected=@{ value='unchanged' } }
        }
        Write-Json $recordPath $original
        $args = @{
            Action='Change'; Change='choice'; RecordPath=$recordPath
            NonInteractiveAnswers=@{ 'choice.value'='new'; 'unselected.value'='not-applied' }
        }
        $preview = Run-Flow ($args + @{ PlanOnly=$true })
        $fingerprint = [regex]::Match($preview.Text, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        Check "generic preview keeps applied decisions ($failApply)" {
            $disk = Get-Content -Raw $recordPath | ConvertFrom-Json
            -not $preview.Failed -and $fingerprint.Length -eq 64 -and $disk.decisions.choice.value -eq 'old'
        }
        $result = Run-Flow ($args + @{ ApprovedPlanFingerprint=$fingerprint })
        $seen = if (Test-Path $witness) { Get-Content -Raw $witness | ConvertFrom-Json } else { $null }
        $after = Get-Content -Raw $recordPath | ConvertFrom-Json
        Check "step receives proposed choices but durable state is still applied ($failApply)" {
            $seen.passed.value -eq 'new' -and $seen.plan -eq 'new' -and $seen.disk.decisions.choice.value -eq 'old' -and $seen.disk.decisions.choice.pin -eq 'old-pin'
        }
        Check "unselected proposed decisions never become applied ($failApply)" { $after.decisions.unselected.value -eq 'unchanged' }
        if ($failApply) {
            Check 'failed apply retains the previous decision and records no success history' {
                $result.Failed -and $result.Text -match 'synthetic apply failure' -and $after.decisions.choice.value -eq 'old' -and $after.decisions.choice.pin -eq 'old-pin' -and @($after.history).Count -eq 0
            }
        }
        else {
            Check 'successful history starts before questions, not at the proposed value' {
                -not $result.Failed -and $after.history[0].from.value -eq 'old' -and $after.history[0].from.pin -eq 'old-pin' -and $after.history[0].to.value -eq 'new'
            }
            Check 'only a successful step advances its applied decision' { $after.decisions.choice.value -eq 'new' -and $after.decisions.choice.pin -eq 'new-pin' }
        }
    }
}
finally { if (Test-Path $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
Write-Host "Applied flow state: $count assertions, $($count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
