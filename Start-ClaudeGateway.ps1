<#
.SYNOPSIS
    One guided entry point for setup, update, change, diagnosis, status and the deployment guide.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Setup', 'Update', 'Change', 'Diagnose', 'Guide', 'Status')]
    [string]$Action,
    [string]$Change,
    [string]$RecordPath = 'onboarding/claude-gateway.json',
    [switch]$PlanOnly,
    [string]$ApprovedPlanFingerprint,
    [string]$FlowModulePath,
    [hashtable]$NonInteractiveAnswers,
    [string]$AnswersPath,
    [switch]$SupportBundle
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $FlowModulePath) { $FlowModulePath = Join-Path $root 'scripts\flow' }
. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\ClaudeChoice.ps1')
$discoveryScript = Join-Path $root 'scripts\flow\Discovery.ps1'
if (Test-Path -LiteralPath $discoveryScript) { . $discoveryScript }

$script:ExpectedFlowSteps = @(
    'Foundation', 'Tier', 'Entitlement', 'Network', 'DesktopSignIn',
    'FinOps', 'Budgets', 'Monitoring', 'Reports', 'DeviceProfiles', 'Verify', 'Guide'
)

function New-EmptyDecisionRecord {
    [pscustomobject][ordered]@{ schemaVersion = 2; decisions = [pscustomobject]@{}; history = @() }
}

function Resolve-FlowPath {
    param([string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $root $Path)
}

function Set-FlowRecordProperty {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-FlowDecisionPath {
    param($Record, [string]$Path, $Value)
    if (-not $Path) { return }
    Set-FlowRecordProperty $Record 'schemaVersion' 2
    if (-not ($Record.PSObject.Properties.Name -contains 'decisions') -or $null -eq $Record.decisions) {
        Set-FlowRecordProperty $Record 'decisions' ([pscustomobject]@{})
    }
    $parts = @($Path -split '\.' | Where-Object { $_ })
    if (-not $parts.Count) { return }
    $target = $Record.decisions
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $p = $parts[$i]
        if (-not ($target.PSObject.Properties.Name -contains $p) -or $null -eq $target.$p) {
            Set-FlowRecordProperty $target $p ([pscustomobject]@{})
        }
        $target = $target.$p
    }
    Set-FlowRecordProperty $target $parts[-1] $Value
}

function Get-FlowDecisionPath {
    param($Record, [string]$Path)
    $current = $Record
    foreach ($part in @($Path -split '\.' | Where-Object { $_ })) {
        if ($null -eq $current -or -not ($current.PSObject.Properties.Name -contains $part)) { return $null }
        $current = $current.$part
    }
    return $current
}

function Write-FlowDecisionRecord {
    param($Record, [string]$Path)
    $hadPath = $Record.PSObject.Properties.Name -contains '__recordPath'
    $oldPath = if ($hadPath) { $Record.__recordPath } else { $null }
    if ($hadPath) { $Record.PSObject.Properties.Remove('__recordPath') }
    try { Write-ClaudeDecisionRecord -Record $Record -Path $Path }
    finally { if ($hadPath) { Set-FlowRecordProperty $Record '__recordPath' $oldPath } }
}

function Remove-FlowRecordProperty {
    param($Object, [string]$Name)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.PSObject.Properties.Remove($Name) }
}

function Read-FlowAnswers {
    param([string]$Path, [hashtable]$InlineAnswers)
    $answers = @{}
    if ($Path) {
        $resolved = Resolve-FlowPath $Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "AnswersPath not found: $resolved" }
        $raw = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $answers[$p.Name] = $p.Value }
    }
    if ($InlineAnswers) {
        foreach ($key in $InlineAnswers.Keys) { $answers[$key] = $InlineAnswers[$key] }
    }
    return $answers
}

function Set-FlowAnswersOnRecord {
    param($Record, [hashtable]$Answers)
    if (-not $Answers) { return }
    foreach ($key in $Answers.Keys) {
        if ([string]$key -match '\.') { Set-FlowDecisionPath -Record $Record -Path ([string]$key) -Value $Answers[$key] }
    }
}

function Get-FlowPrincipal {
    try {
        $acct = az account show -o json 2>$null | ConvertFrom-Json
        if ($acct -and $acct.user -and $acct.user.name) { return [string]$acct.user.name }
    } catch { }
    return [Environment]::UserName
}

function Get-FlowModules {
    param([string]$ModulePath, [string]$ForAction)
    $loaded = @{}
    $otherAction = [System.Collections.Generic.List[object]]::new()
    $infos = [System.Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $ModulePath) {
        foreach ($file in @(Get-ChildItem -LiteralPath $ModulePath -Filter '*.ps1' -File | Sort-Object Name)) {
            if ($file.Name -in @('FlowContract.ps1', 'Discovery.ps1')) { continue }
            foreach ($name in 'Get-ClaudeFlowStepInfo','Get-ClaudeFlowStepQuestions','Get-ClaudeFlowStepPlan','Invoke-ClaudeFlowStep','Test-ClaudeFlowStep') {
                if (Get-Command $name -ErrorAction SilentlyContinue) { Remove-Item "function:\$name" -Force -ErrorAction SilentlyContinue -WhatIf:$false }
            }
            $functionsBefore = @{}
            foreach ($fn in @(Get-ChildItem function:)) { $functionsBefore[$fn.Name] = $fn.ScriptBlock }
            . $file.FullName
            # ADR-0030: modules share one session. Dot-sourcing here defines their helpers in this
            # function's scope, which ends on return, so each new helper is kept at script scope.
            foreach ($fn in @(Get-ChildItem function:)) {
                if ($fn.Name -like '*-ClaudeFlowStep*') { continue }
                if (-not $functionsBefore.ContainsKey($fn.Name) -or $functionsBefore[$fn.Name] -ne $fn.ScriptBlock) {
                    Set-Item -LiteralPath "function:script:$($fn.Name)" -Value $fn.ScriptBlock -WhatIf:$false
                }
            }
            $info = & (Get-Command Get-ClaudeFlowStepInfo -ErrorAction Stop).ScriptBlock
            $actions = @($info.Actions)
            if ($actions.Count -and $ForAction -notin $actions) { $otherAction.Add($info); continue }
            $infos.Add($info)
            $loaded[$info.Name] = [pscustomobject]@{
                Info = $info
                Questions = (Get-Command Get-ClaudeFlowStepQuestions -ErrorAction Stop).ScriptBlock
                Plan = (Get-Command Get-ClaudeFlowStepPlan -ErrorAction Stop).ScriptBlock
                Invoke = (Get-Command Invoke-ClaudeFlowStep -ErrorAction Stop).ScriptBlock
                Test = (Get-Command Test-ClaudeFlowStep -ErrorAction Stop).ScriptBlock
                Path = $file.FullName
            }
        }
    }
    $present = @($infos.ToArray())
    $ordered = if ($present.Count) { @(Get-ClaudeFlowStepOrder -Steps $present) } else { @() }
    $steps = foreach ($info in $ordered) { $loaded[$info.Name] }
    $presentNames = @($loaded.Keys) + @($otherAction | ForEach-Object { [string]$_.Name })
    $skipped = foreach ($name in $script:ExpectedFlowSteps) {
        if ($name -notin $presentNames) { "Skipped absent step: $name (module scripts\flow\$name.ps1 is not present on this branch)." }
    }
    # Present modules that another action runs, named with the command that runs them.
    $elsewhere = foreach ($info in $otherAction) {
        if ($ForAction -ne 'Change' -and 'Change' -in @($info.Actions) -and 'Setup' -notin @($info.Actions) -and $info.DecisionKey) {
            "Not part of ${ForAction}: $($info.Name) - change it later with .\Start-ClaudeGateway.ps1 -Action Change -Change $($info.DecisionKey)"
        }
    }
    [pscustomobject]@{ Steps = @($steps); Skipped = @($skipped) + @($elsewhere) }
}

function Get-FlowDiscovery {
    param($Record)
    if (Get-Command Get-ClaudeFlowDiscovery -ErrorAction SilentlyContinue) {
        return Get-ClaudeFlowDiscovery -RecordPath $RecordPath -Record $Record
    }
    [pscustomobject]@{ record = $Record; comparison = [pscustomobject]@{ status = 'unknown'; differences = @('Discovery.ps1 is absent.') } }
}

function Assert-RecordMatchesLive {
    param($Discovery)
    $diffs = @()
    if ($Discovery -and $Discovery.comparison -and $Discovery.comparison.differences) {
        $diffs = @($Discovery.comparison.differences | Where-Object { $_ })
    }
    if ($diffs.Count) {
        throw ("The decision record does not match live state; refusing to apply over drift.`n - " + ($diffs -join "`n - "))
    }
}

function Set-CurrentOptionRecommended {
    param([object[]]$Options, $Current)
    if ($null -eq $Current -or "$Current" -eq '') { return @($Options) }
    $matched = $false
    foreach ($option in @($Options)) {
        if ([string]$option.Value -eq [string]$Current) {
            $option.Recommended = $true
            $option.Reason = $(if ($option.Reason) { "current value; $($option.Reason)" } else { 'current value' })
            $matched = $true
        } else {
            $option.Recommended = $false
        }
    }
    if (-not $matched) {
        return @((New-ClaudeChoiceOption -Value ([string]$Current) -Label ("Current: {0}" -f $Current) -Detail 'Recorded current value' -Recommended -Reason 'current value') + @($Options))
    }
    return @($Options)
}

function Invoke-Questions {
    param($Steps, $Record, $Discovery, [string]$CurrentAction)
    foreach ($step in $Steps) {
        $questions = @(& $step.Questions -Record $Record -Discovery $Discovery)
        foreach ($q in $questions) {
            if (-not $q.Key) { throw "Step '$($step.Info.Name)' returned a question without a key." }
            $existing = Get-FlowDecisionPath -Record $Record -Path ('decisions.' + $q.Key)
            if ($CurrentAction -ne 'Change' -and $null -ne $existing -and "$existing" -ne '') { continue }
            if ($CurrentAction -eq 'Change' -and $null -ne $existing -and "$existing" -ne '') {
                $q.Options = @(Set-CurrentOptionRecommended -Options @($q.Options) -Current $existing)
                Set-FlowRecordProperty $q 'AcceptRecommendedWithoutConsole' $true
            }
            if ($script:FlowAnswers -and $script:FlowAnswers.ContainsKey($q.Key)) {
                $choice = $script:FlowAnswers[$q.Key]
            }
            else {
                $select = @{
                    Parameter = $q.Key
                    Question = $q.Question
                    Options = @($q.Options)
                    WhereToFind = @($q.WhereToFind)
                    AcceptRecommendedWithoutConsole = [bool]$q.AcceptRecommendedWithoutConsole
                }
                if ($q.NoneMessage) { $select.NoneMessage = $q.NoneMessage }
                if ($q.AmbiguousMessage) { $select.AmbiguousMessage = $q.AmbiguousMessage }
                $choice = Select-ClaudeChoice @select
            }
            Set-FlowDecisionPath -Record $Record -Path $q.Key -Value $choice
        }
    }
}

function Test-StepCompleted {
    param($Record, $Step, [string]$CurrentAction, [string]$RunId)
    if (-not ($Record.PSObject.Properties.Name -contains 'history') -or $null -eq $Record.history) { return $false }
    $decision = if ($Step.Info.DecisionKey) { $Step.Info.DecisionKey } else { $Step.Info.Name }
    return @($Record.history | Where-Object { $_.action -eq $CurrentAction -and $_.decision -eq $decision -and $_.runId -eq $RunId }).Count -gt 0
}

function Start-FlowRun {
    param($Record, [string]$Path, [string]$CurrentAction, [string]$CurrentChange, [string]$Fingerprint)
    $existing = $null
    if ($Record.PSObject.Properties.Name -contains 'activeRun') { $existing = $Record.activeRun }
    if ($existing -and $existing.action -eq $CurrentAction -and [string]$existing.change -eq [string]$CurrentChange -and $existing.fingerprint -eq $Fingerprint -and $existing.id) {
        return [string]$existing.id
    }
    $run = [pscustomobject][ordered]@{
        id = [guid]::NewGuid().ToString('N')
        action = $CurrentAction
        change = $CurrentChange
        fingerprint = $Fingerprint
        startedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Set-FlowRecordProperty $Record 'activeRun' $run
    Write-FlowDecisionRecord -Record $Record -Path $Path
    return [string]$run.id
}

function Invoke-ApplySteps {
    param($Steps, $Plans, $Record, [string]$Path, [string]$CurrentAction, [string]$RunId)
    # Read after the first step runs, so no Azure call waits in front of the installer (ADR-0032).
    $principal = $null
    $release = Get-ClaudeFlowReleaseInfo -Repo $root
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        $plan = $Plans[$i]
        if (Test-StepCompleted -Record $Record -Step $step -CurrentAction $CurrentAction -RunId $RunId) {
            Write-Host "Skipping completed step: $($step.Info.Name)" -ForegroundColor DarkGray
            continue
        }
        $before = if ($step.Info.DecisionKey) { Get-ClaudeDecision -Record $Record -Key $step.Info.DecisionKey } else { $null }
        Write-Host "Applying $($step.Info.Name)..." -ForegroundColor Cyan
        $changes = & $step.Invoke -Record $Record -Plan $plan
        if ($null -eq $principal) { $principal = Get-FlowPrincipal }
        foreach ($key in @($changes.Keys)) {
            if ($key -eq $step.Info.DecisionKey) { Set-ClaudeDecision -Record $Record -Key $key -Value $changes[$key] }
            else { Set-FlowRecordProperty $Record $key $changes[$key] }
        }
        if ($changes.ContainsKey($step.Info.DecisionKey) -eq $false -and $step.Info.DecisionKey) {
            $afterDecision = Get-ClaudeDecision -Record $Record -Key $step.Info.DecisionKey
        } else { $afterDecision = $changes[$step.Info.DecisionKey] }
        Add-ClaudeDecisionHistory -Record $Record -Action $CurrentAction -Decision $(if ($step.Info.DecisionKey) { $step.Info.DecisionKey } else { $step.Info.Name }) -From $before -To $afterDecision -Principal $principal -Commit $release.commit
        $last = @($Record.history)[@($Record.history).Count - 1]
        Set-FlowRecordProperty $last 'runId' $RunId
        Set-ClaudeDecisionRelease -Record $Record -Version $release.version -Commit $release.commit
        Write-FlowDecisionRecord -Record $Record -Path $Path
    }
}

function Invoke-VerifySteps {
    param($Steps, $Record)
    Write-Host ''
    Write-Host 'Verification' -ForegroundColor Cyan
    $failed = 0
    foreach ($step in $Steps) {
        $result = & $step.Test -Record $Record
        $passed = [bool]$result.Passed
        if (-not $passed) { $failed++ }
        Write-Host ("  {0}  {1}" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $result.Step) -ForegroundColor $(if ($passed) { 'Green' } else { 'Red' })
        foreach ($check in @($result.Checks)) {
            Write-Host ("    {0}  {1}  {2}" -f $(if ($check.Passed) { 'PASS' } else { 'FAIL' }), $check.Name, $check.Evidence) -ForegroundColor $(if ($check.Passed) { 'DarkGray' } else { 'Yellow' })
            if (-not $check.Passed -and $check.Fix) { Write-Host "          $($check.Fix)" -ForegroundColor DarkGray }
        }
    }
    if ($failed) { throw "$failed guided flow step verification(s) failed." }
}

function Show-Status {
    param($Record, $Discovery)
    Write-Host ''
    Write-Host 'Claude gateway status' -ForegroundColor Cyan
    if (-not $Record) { Write-Host "No decision record at $RecordPath."; return }
    Write-Host ''
    Write-Host 'Decisions' -ForegroundColor Cyan
    if ($Record.decisions) { $Record.decisions | ConvertTo-Json -Depth 8 }
    Write-Host ''
    Write-Host 'Release' -ForegroundColor Cyan
    if ($Record.release) { $Record.release | ConvertTo-Json -Depth 6 } else { Write-Host '(none)' }
    Write-Host ''
    Write-Host 'History' -ForegroundColor Cyan
    @($Record.history | Select-Object -Last 5) | ConvertTo-Json -Depth 8
    Write-Host ''
    Write-Host 'Live drift' -ForegroundColor Cyan
    if ($Discovery.comparison -and $Discovery.comparison.differences -and @($Discovery.comparison.differences).Count) {
        foreach ($d in @($Discovery.comparison.differences)) { Write-Host "  DRIFT $d" -ForegroundColor Yellow }
    } elseif ($Discovery.comparison -and $Discovery.comparison.status -eq 'unknown') {
        Write-Host "  not checked: $($Discovery.comparison.reason)" -ForegroundColor Yellow
    } else { Write-Host '  none detected' -ForegroundColor Green }
}

function Get-FlowAttendedLead {
    # ADR-0032: in an attended run a step that declares AttendedFirst, and whose plan asks its own
    # questions in the console, is applied before the other steps are asked anything.
    param($Steps, $Record, $Discovery, [string]$CurrentAction)
    $lead = [System.Collections.Generic.List[object]]::new()
    $plans = [System.Collections.Generic.List[object]]::new()
    $asked = [System.Collections.Generic.List[object]]::new()
    foreach ($step in $Steps) {
        if (-not ($step.Info.PSObject.Properties.Name -contains 'AttendedFirst' -and $step.Info.AttendedFirst)) { break }
        Invoke-Questions -Steps @($step) -Record $Record -Discovery $Discovery -CurrentAction $CurrentAction
        $asked.Add($step)
        $plan = & $step.Plan -Record $Record -Discovery $Discovery
        if (-not ($plan.Data -and $plan.Data.asksInConsole)) { break }
        $lead.Add($step)
        $plans.Add($plan)
    }
    [pscustomobject]@{ Steps = @($lead); Plans = @($plans); Asked = @($asked) }
}

function Get-FlowDiscoveryForSteps {
    param($Record, [string]$CurrentAction, [bool]$Attended)
    $found = Get-FlowDiscovery -Record $Record
    Set-FlowRecordProperty $found 'action' $CurrentAction
    Set-FlowRecordProperty $found 'attended' $Attended
    return $found
}

if (-not $Action) {
    if (Test-ClaudeInteractive) {
        $Action = Select-ClaudeChoice -Parameter Action -Question 'What do you want to do?' -Options @(
            New-ClaudeChoiceOption -Value Setup -Label 'Setup'
            New-ClaudeChoiceOption -Value Update -Label 'Update'
            New-ClaudeChoiceOption -Value Change -Label 'Change'
            New-ClaudeChoiceOption -Value Diagnose -Label 'Diagnose'
            New-ClaudeChoiceOption -Value Guide -Label 'Guide'
            New-ClaudeChoiceOption -Value Status -Label 'Status'
        )
    } else { throw 'Pass -Action when running without a console.' }
}

$RecordPath = Resolve-FlowPath $RecordPath
$script:FlowAnswers = Read-FlowAnswers -Path $AnswersPath -InlineAnswers $NonInteractiveAnswers
$record = Read-ClaudeDecisionRecord -Path $RecordPath
if (-not $record) { $record = New-EmptyDecisionRecord }
Set-FlowRecordProperty $record '__recordPath' $RecordPath
Set-FlowAnswersOnRecord -Record $record -Answers $script:FlowAnswers

if ($Action -eq 'Update') {
    $update = Join-Path $root 'scripts\Update-ClaudeGateway.ps1'
    if (-not (Test-Path -LiteralPath $update)) { $update = Join-Path $root 'Update-ClaudeGateway.ps1' }
    if (Test-Path -LiteralPath $update) {
        $updateArgs = @{ RecordPath = $RecordPath }
        if ($ApprovedPlanFingerprint -and -not $PlanOnly) { $updateArgs.Apply = $true; $updateArgs.ApprovedPlanFingerprint = $ApprovedPlanFingerprint }
        & $update @updateArgs -WhatIf:$WhatIfPreference
        if (-not $updateArgs.Apply) { Write-Host 'To apply this update plan: .\Start-ClaudeGateway.ps1 -Action Update -ApprovedPlanFingerprint <fingerprint>' -ForegroundColor DarkGray }
        return
    }
    Write-Host 'Update-ClaudeGateway.ps1 is not present on this branch; Update is skipped.' -ForegroundColor Yellow
    return
}
if ($Action -eq 'Diagnose') {
    $scripts = @('scripts\Debug-ClaudeSetup.ps1', 'scripts\Debug-ClaudeWorkstation.ps1') | ForEach-Object { Join-Path $root $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ($scripts.Count) {
        # The debug scripts take a zip path. Passing the switch itself wrote a file named True.zip.
        $bundleStamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $bundleDir = Join-Path $root 'onboarding\support'
        foreach ($s in $scripts) {
            $args = @{ RecordPath = $RecordPath }
            if ($SupportBundle) {
                if (-not (Test-Path -LiteralPath $bundleDir)) { New-Item -ItemType Directory -Path $bundleDir -Force -WhatIf:$false | Out-Null }
                $kind = if ((Split-Path $s -Leaf) -like '*Workstation*') { 'workstation' } else { 'setup' }
                $args.SupportBundle = Join-Path $bundleDir "claude-$kind-support-$bundleStamp.zip"
                Write-Host "Support bundle: $($args.SupportBundle)" -ForegroundColor DarkGray
            }
            & $s @args
        }
    }
    else { Write-Host 'Diagnose scripts are not present on this branch; Diagnose is skipped.' -ForegroundColor Yellow }
    return
}

# ADR-0032: an attended run is a console without -PlanOnly, -ApprovedPlanFingerprint or -WhatIf.
$attended = [bool]((Test-ClaudeInteractive) -and -not $PlanOnly -and -not $ApprovedPlanFingerprint -and -not $WhatIfPreference)
$discovery = Get-FlowDiscoveryForSteps -Record $record -CurrentAction $Action -Attended $attended
if ($Action -eq 'Status') { Show-Status -Record $record -Discovery $discovery; return }
if ($Action -ne 'Guide') { Assert-RecordMatchesLive -Discovery $discovery }

$modules = Get-FlowModules -ModulePath $FlowModulePath -ForAction $Action
foreach ($note in $modules.Skipped) { Write-Host $note -ForegroundColor DarkGray }
$steps = @($modules.Steps)
if (-not $steps.Count) { throw "No guided flow modules for action '$Action' were found in $FlowModulePath." }

if ($Change) {
    $steps = @($steps | Where-Object { $_.Info.DecisionKey -eq $Change -or $_.Info.Name -eq $Change })
    if (-not $steps.Count) { throw "No present guided flow step owns change '$Change'." }
}

# Attended: the installer asks its own questions first; its summary and confirmation approve what
# it creates. The steps after it are asked, planned and approved once the gateway exists.
$askedFirst = @()
if ($attended) {
    $lead = Get-FlowAttendedLead -Steps $steps -Record $record -Discovery $discovery -CurrentAction $Action
    $askedFirst = @($lead.Asked | ForEach-Object { $_.Info.Name })
    if ($lead.Steps.Count) {
        $leadNames = @($lead.Steps | ForEach-Object { $_.Info.Name })
        $rest = @($steps | Where-Object { $_.Info.Name -notin $leadNames })
        Write-Host ''
        Write-Host ("First: {0}. Then: {1}." -f (@($lead.Steps | ForEach-Object { $_.Info.Title }) -join ', '), $(if ($rest.Count) { (@($rest | ForEach-Object { $_.Info.Title }) -join ', ') + ', asked once the gateway exists' } else { 'nothing else' })) -ForegroundColor Cyan
        Write-Host (Format-ClaudeFlowReview -Plans @($lead.Plans))
        if (-not $PSCmdlet.ShouldProcess($RecordPath, "Apply guided flow action $Action")) { return }
        $leadRunId = Start-FlowRun -Record $record -Path $RecordPath -CurrentAction $Action -CurrentChange $Change -Fingerprint (Get-ClaudeFlowFingerprint -Plans @($lead.Plans))
        try { Invoke-ApplySteps -Steps $lead.Steps -Plans @($lead.Plans) -Record $record -Path $RecordPath -CurrentAction $Action -RunId $leadRunId }
        catch [System.OperationCanceledException] { Write-Host ''; Write-Host $_.Exception.Message -ForegroundColor Yellow; exit 1 }
        Invoke-VerifySteps -Steps $lead.Steps -Record $record
        Remove-FlowRecordProperty $record 'activeRun'
        Write-FlowDecisionRecord -Record $record -Path $RecordPath
        $steps = $rest
        if (-not $steps.Count) { return }
        Write-Host ''
        Write-Host ("{0} is done. Next: {1}." -f (@($lead.Steps | ForEach-Object { $_.Info.Title }) -join ', '), (@($steps | ForEach-Object { $_.Info.Title }) -join ', ')) -ForegroundColor Cyan
        $discovery = Get-FlowDiscoveryForSteps -Record $record -CurrentAction $Action -Attended $attended
        Assert-RecordMatchesLive -Discovery $discovery
    }
}

Invoke-Questions -Steps @($steps | Where-Object { $_.Info.Name -notin $askedFirst }) -Record $record -Discovery $discovery -CurrentAction $Action
$plans = foreach ($step in $steps) { & $step.Plan -Record $record -Discovery $discovery }
$review = Format-ClaudeFlowReview -Plans $plans
$fingerprint = Get-ClaudeFlowFingerprint -Plans $plans
Write-Host $review
Write-Host ''
Write-Host "Fingerprint: $fingerprint" -ForegroundColor Cyan
if ($PlanOnly -and (Test-ClaudeInteractive) -and @($plans | Where-Object { $_.Data -and $_.Data.runsInstaller }).Count) {
    Write-Host 'This is the unattended plan, in which Install-ClaudeGateway.ps1 runs with -Yes. In a console, Setup without -PlanOnly runs the installer first, so that it asks its own questions, and plans the steps after it then.' -ForegroundColor DarkGray
}

if ($PlanOnly) { return }
if ($WhatIfPreference) { Write-Host 'WhatIf: no guided flow changes were written.' -ForegroundColor Yellow; return }

if ($ApprovedPlanFingerprint) {
    if ($ApprovedPlanFingerprint.Length -lt 8 -or -not $fingerprint.StartsWith($ApprovedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ApprovedPlanFingerprint '$ApprovedPlanFingerprint' does not match plan fingerprint '$fingerprint'."
    }
} elseif (Test-ClaudeInteractive) {
    $typed = Read-Host "Type the first 8 characters of the fingerprint ($($fingerprint.Substring(0, 8))) to apply"
    if ($typed -ne $fingerprint.Substring(0, 8)) { throw 'Confirmation did not match; nothing was written.' }
} else {
    throw 'Pass -ApprovedPlanFingerprint to apply this reviewed plan without a console.'
}

if ($PSCmdlet.ShouldProcess($RecordPath, "Apply guided flow action $Action")) {
    $runId = Start-FlowRun -Record $record -Path $RecordPath -CurrentAction $Action -CurrentChange $Change -Fingerprint $fingerprint
    try { Invoke-ApplySteps -Steps $steps -Plans @($plans) -Record $record -Path $RecordPath -CurrentAction $Action -RunId $runId }
    catch [System.OperationCanceledException] { Write-Host ''; Write-Host $_.Exception.Message -ForegroundColor Yellow; exit 1 }
    Invoke-VerifySteps -Steps $steps -Record $record
    Remove-FlowRecordProperty $record 'activeRun'
    Write-FlowDecisionRecord -Record $record -Path $RecordPath
}
