# P92 acceptance test 7 and A8 (docs/adr/0047-lean-installer-phase-0.md): Start-ClaudeGateway.ps1 -PlanOnly
# runs the installer's preflight engine on the arguments its plan gives Install-ClaudeGateway.ps1, shows
# a failing check in the plan output, binds the result into the plan fingerprint, and an apply refuses
# while a check fails. The flow's -AnswersPath file is checked against the answers schema. The flow runs
# in this process over the az stub of tests/InstallerCheckpointStubs.ps1; the installer's own
# -Preflight -Json runs over the same world in a child PowerShell, and the two report the same checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerCheckpointHarness.ps1')
$root = $script:P91Root
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block | Out-Null; return '' } catch { return $_.Exception.Message } }
Write-Host ''
Write-Host 'Guided flow and the installer answers schema' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$scratch = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('p92-flow-' + [guid]::NewGuid().ToString('N'))))
$modules = Join-Path $scratch 'flow'; $logs = Join-Path $scratch 'logs'
New-Item -ItemType Directory -Force -Path $modules, $logs | Out-Null
$start = Join-Path $root 'Start-ClaudeGateway.ps1'
$sub = $script:P91Subscription
$world = Join-Path $scratch 'world.json'
Write-P91Text $world ((New-P91World) | ConvertTo-Json -Depth 30)
# A Foundation step whose plan runs the installer, as scripts/flow/Foundation.ps1 does: the installer
# arguments come from the foundation decisions, so an answers file decides them.
@'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name = 'Foundation'; Title = 'Foundation'; DecisionKey = 'foundation'; DependsOn = @(); Actions = @('Setup','Change') } }
function Get-ClaudeFlowStepQuestions { param($Record, $Discovery) @() }
function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $d = $Record.decisions.foundation
    $installerArgs = [ordered]@{ Yes = $true; SkipFinOpsOffer = $true; SubscriptionId = $d.subscriptionId; FoundryAccount = $d.foundryAccount; FoundryResourceGroup = $d.foundryResourceGroup
        ResourceGroup = $d.resourceGroup; Location = $d.location; NamePrefix = $d.namePrefix; PublisherEmail = $d.publisherEmail; Sku = $d.sku; StandardGroup = $d.standardGroup; PremiumGroup = $d.premiumGroup }
    New-ClaudeFlowPlan -Step Foundation -Summary "Create gateway apim-$($d.namePrefix)" -Actions @(New-ClaudeFlowAction -Verb Create -Target "apim-$($d.namePrefix)") `
        -Costs @(New-ClaudeFlowCost -Item 'API Management' -MonthlyUsd 150 -Source 'stub') -Implications @('Developers use the gateway URL') -Rollback 'Delete the resource group' `
        -Data @{ installerArgs = $installerArgs; runsInstaller = $true; attended = $false; asksInConsole = $false }
}
function Invoke-ClaudeFlowStep { param($Record, $Plan) [IO.File]::AppendAllText((Join-Path $env:P92_FLOW_LOG 'applied.log'), "foundation`n"); @{ foundationApplied = $true } }
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step = 'Foundation'; Passed = $true; Checks = @() } }
'@ | Set-Content -LiteralPath (Join-Path $modules 'Foundation.ps1') -Encoding UTF8
$env:P92_FLOW_LOG = $logs
$answers = [ordered]@{ 'foundation.subscriptionId' = $sub; 'foundation.foundryAccount' = 'ai-p91'; 'foundation.foundryResourceGroup' = 'rg-ai-p91'; 'foundation.resourceGroup' = 'rg-p91'
    'foundation.location' = 'eastus2'; 'foundation.namePrefix' = 'p92flow'; 'foundation.publisherEmail' = 'ops@contoso.com'; 'foundation.sku' = 'BasicV2'
    'foundation.standardGroup' = 'claude-code-standard'; 'foundation.premiumGroup' = 'claude-code-premium' }
function Write-Answers([string]$Name, [scriptblock]$Change) {
    $a = [ordered]@{}; foreach ($k in $answers.Keys) { $a[$k] = $answers[$k] }
    if ($Change) { & $Change $a }
    $p = Join-Path $scratch "$Name.json"; Write-P91Text $p ($a | ConvertTo-Json -Depth 6); return $p
}
function Get-PreflightLines([string]$Text) { @($Text -split "`n" | Where-Object { $_ -match '^\s*\[(PASS|FAIL|NOT-RUN)\] [A-Za-z.]+: ' } | ForEach-Object { $_.Trim() }) }
function Get-Fingerprint([string]$Text) { [regex]::Match($Text, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value }

try {
    . (Join-Path $PSScriptRoot 'InstallerCheckpointStubs.ps1') -World $world -Log $logs
    $good = Write-Answers 'good'
    $bad = Write-Answers 'bad' { param($a) $a['foundation.standardGroup'] = "O'Brien" }
    $record = { param([string]$n) Join-Path $scratch "$n-record.json" }
    $goodPlan = & $start -Action Setup -PlanOnly -RecordPath (& $record 'good') -FlowModulePath $modules -AnswersPath $good *>&1 | Out-String
    $badPlan = & $start -Action Setup -PlanOnly -RecordPath (& $record 'bad') -FlowModulePath $modules -AnswersPath $bad *>&1 | Out-String
    $goodLines = @(Get-PreflightLines $goodPlan); $badLines = @(Get-PreflightLines $badPlan)
    Assert 'P7 -PlanOnly runs the preflight on the installer arguments of its plan: all 14 checks appear in the plan output' ($goodLines.Count -eq 14 -and $badLines.Count -ge 14) "$($goodLines.Count) lines || $(($goodPlan -split "`n" | Select-Object -Last 6) -join ' | ')"
    Assert 'P7 a failing check appears in the plan output: a standard group with a single quote is [FAIL] entra.groupNames' (@($badLines | Where-Object { $_ -match "^\[FAIL\] entra\.groupNames: .*O'Brien" }).Count -ge 1 -and
        -not @($goodLines | Where-Object { $_ -match '^\[FAIL\]' }).Count) ($badLines -join ' | ')
    $goodFp = Get-Fingerprint $goodPlan; $badFp = Get-Fingerprint $badPlan
    # The same answers over an estate where the gateway name is taken: only the preflight differs.
    $saved = [IO.File]::ReadAllText($world)
    $taken = $saved | ConvertFrom-Json; $taken | Add-Member -NotePropertyName apimNamesTaken -NotePropertyValue @('apim-p92flow') -Force
    Write-P91Text $world ($taken | ConvertTo-Json -Depth 30)
    $takenPlan = & $start -Action Setup -PlanOnly -RecordPath (& $record 'taken') -FlowModulePath $modules -AnswersPath $good *>&1 | Out-String
    Write-P91Text $world $saved
    $takenFp = Get-Fingerprint $takenPlan
    Assert 'P7 the fingerprint binds the preflight result: the same answers over an estate where the name is taken give [FAIL] apim.nameAvailability and another fingerprint' ($goodFp -and $takenFp -and $goodFp -ne $takenFp -and
        @(Get-PreflightLines $takenPlan | Where-Object { $_ -match '^\[FAIL\] apim\.nameAvailability: ' }).Count -eq 1) "$goodFp / $takenFp || $((Get-PreflightLines $takenPlan) -join ' | ')"
    $refused = Get-Thrown { & $start -Action Setup -RecordPath (& $record 'bad-apply') -FlowModulePath $modules -AnswersPath $bad -ApprovedPlanFingerprint $badFp }
    Assert 'P7 an apply of the approved plan refuses while a preflight check fails, before any step runs' ($refused -match 'entra\.groupNames' -and -not (Test-Path -LiteralPath (Join-Path $logs 'applied.log')) -and
        -not (Test-Path -LiteralPath (& $record 'bad-apply'))) $refused
    # Round 3, the Architect seat's item 2: a preflight that fails with no FAIL check. The installer
    # arguments name a subscription and Azure CLI is signed out, so the checks that read Azure are NOT-RUN
    # (not-signed-in), which fails the preflight; the plan's own fingerprint is approved.
    $saved = [IO.File]::ReadAllText($world)
    $signedOut = $saved | ConvertFrom-Json; $signedOut | Add-Member -NotePropertyName signedOut -NotePropertyValue $true -Force
    Write-P91Text $world ($signedOut | ConvertTo-Json -Depth 30)
    $soPlan = & $start -Action Setup -PlanOnly -RecordPath (& $record 'signed-out') -FlowModulePath $modules -AnswersPath $good *>&1 | Out-String
    $soFp = Get-Fingerprint $soPlan
    $soRefused = Get-Thrown { & $start -Action Setup -RecordPath (& $record 'signed-out-apply') -FlowModulePath $modules -AnswersPath $good -ApprovedPlanFingerprint $soFp }
    Write-P91Text $world $saved
    $soLines = @(Get-PreflightLines $soPlan)
    Assert 'R3 an apply refuses a preflight that does not pass with no FAIL check: signed out, the refusal names each blocking NOT-RUN check with its reason (not-signed-in), before any step runs; nothing is written' (
        $soFp -and -not @($soLines | Where-Object { $_ -match '^\[FAIL\]' }).Count -and @($soLines | Where-Object { $_ -match '^\[NOT-RUN\] target\.tenant: .*\(not-signed-in\)' }).Count -eq 1 -and
        $soRefused -match 'not-signed-in' -and $soRefused -match 'target\.tenant' -and $soRefused -match 'entra\.groupNames' -and $soRefused -notmatch 'does not match plan fingerprint' -and
        -not (Test-Path -LiteralPath (Join-Path $logs 'applied.log')) -and -not (Test-Path -LiteralPath (& $record 'signed-out-apply'))) "$soRefused || $(($soLines | Select-Object -First 4) -join ' | ')"

    # The same engine: the installer's own preflight over the same world and the same answers.
    $template = New-P91Template $scratch
    $s = New-P91Scenario -Name 'installer' -Scratch $scratch -Template $template -World ([IO.File]::ReadAllText($world) | ConvertFrom-Json)
    $installerAnswers = Join-Path $s.Dir 'answers.json'
    Write-P91Text $installerAnswers ([ordered]@{ schemaVersion = 1; SubscriptionId = $sub; FoundryAccount = 'ai-p91'; FoundryResourceGroup = 'rg-ai-p91'; ResourceGroup = 'rg-p91'; Location = 'eastus2'
            NamePrefix = 'p92flow'; PublisherEmail = 'ops@contoso.com'; Sku = 'BasicV2'; StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium' } | ConvertTo-Json)
    $run = New-P91Run $s -Arguments @('-Preflight', "-AnswersPath '$installerAnswers'")
    $res = Get-P91Result (Invoke-P91Runs @($run)) $run
    $installerLines = @(Get-PreflightLines $res.Out)
    Assert 'P7 the flow and Install-ClaudeGateway.ps1 -Preflight report the same 14 checks with the same results and messages for the same answers' ($installerLines.Count -eq 14 -and ($installerLines -join "`n") -eq ($goodLines -join "`n")) (
        "flow: $($goodLines -join ' | ') || installer: $($installerLines -join ' | ')")

    # The flow's answers file is read against the schema.
    $unknown = Write-Answers 'unknown' { param($a) $a['foundation.bogus'] = 'x' }
    $unknownMessage = Get-Thrown { & $start -Action Setup -PlanOnly -RecordPath (& $record 'unknown') -FlowModulePath $modules -AnswersPath $unknown }
    Assert 'P7 -AnswersPath is checked against the answers schema: an unknown key is refused before any plan, naming it' ($unknownMessage -match 'foundation\.bogus' -and $unknownMessage -match 'answers schema') $unknownMessage
    # Set-FlowAnswersOnRecord copies each <step>.<field> answer onto the record, so a key the flow records
    # itself, such as the approved network review (scripts/flow/Network.ps1:40), is not an answer.
    $recordedField = Write-Answers 'recorded' { param($a) $a['network.approvedFingerprint'] = ('a' * 64) }
    $recordedMessage = Get-Thrown { & $start -Action Setup -PlanOnly -RecordPath (& $record 'recorded') -FlowModulePath $modules -AnswersPath $recordedField }
    Assert 'P7 a field the flow records itself (network.approvedFingerprint) is refused in an answers file, before any plan' ($recordedMessage -match 'network\.approvedFingerprint' -and $recordedMessage -match 'answers schema' -and $recordedMessage -match 'Nothing was planned') $recordedMessage
    $secret = Write-Answers 'secret' { param($a) $a['AddressCertificatePassword'] = 'not-a-real-password' }
    $secretMessage = Get-Thrown { & $start -Action Setup -PlanOnly -RecordPath (& $record 'secret') -FlowModulePath $modules -AnswersPath $secret }
    Assert 'P7 a secret in the flow''s answers file is refused, as in the installers' ($secretMessage -match 'AddressCertificatePassword' -and $secretMessage -match 'secret') $secretMessage
    $inline = & $start -Action Setup -PlanOnly -RecordPath (& $record 'inline') -FlowModulePath $modules -AnswersPath $good -NonInteractiveAnswers @{ 'foundation.namePrefix' = 'p92inline' } *>&1 | Out-String
    Assert 'P7 -NonInteractiveAnswers still win over -AnswersPath' ($inline -match 'apim-p92inline' -and $inline -notmatch 'apim-p92flow') (($inline -split "`n" | Select-Object -First 8) -join ' | ')
}
finally {
    Remove-Item Env:\P92_FLOW_LOG -ErrorAction SilentlyContinue
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
