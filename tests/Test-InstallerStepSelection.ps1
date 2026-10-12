# P92 acceptance tests 3, 4 and 5, PowerShell half (docs/adr/0047-lean-installer-phase-0.md): -ListSteps
# reads the install checkpoint, -Steps runs one step after its prerequisites are verified live,
# answers take effect in the order parameter > answers file > checkpoint > default, and -ProgressPath
# writes one JSON event per line. Each run is a child PowerShell over the az stub of
# tests/InstallerCheckpointStubs.ps1; nothing reaches Azure. The bash half is
# tests/Test-BashInstallerStepSelection.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerCheckpointHarness.ps1')
. (Join-Path $PSScriptRoot 'InstallerRedactionShapes.ps1')
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Installer step selection, precedence and progress (PowerShell installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$scratch = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('p92-steps-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$sub = $script:P91Subscription
$common = @("-SubscriptionId '$sub'", "-FoundryAccount 'ai-p91'", "-FoundryResourceGroup 'rg-ai-p91'", "-EntitlementStore 'named-value'", "-AuthMode 'interactive'",
    "-DesktopSignInKind 'helper-script'", "-AddressMode 'azure'", '-SkipFinOpsOffer', "-ResourceGroup 'rg-p91'", "-Location 'eastus2'", "-NamePrefix 'p91gw'",
    "-PublisherEmail 'ops@contoso.com'", "-Sku 'BasicV2'", '-DeveloperCount 25', "-StandardModels 'claude-sonnet-5'", "-PremiumModels 'claude-opus-5','claude-sonnet-5'", '-QuotaStandard 500000',
    '-TpmPremium 80000', '-QuotaPremium 5000000', '-QuotaOrg 100000000', '-CallsPerMinute 120', '-Yes')
$tpm = @('-TpmStandard 20000')
$secret = "-AddressCertificatePassword (ConvertTo-SecureString 'P92-PFX-SENTINEL' -AsPlainText -Force)"
$stepIds = @('claude-deployment', 'resource-group', 'gateway-deployment', 'company-address', 'entra-groups', 'sync', 'projection', 'business-units', 'onboarding-package', 'verify')
$deps = [ordered]@{ 'claude-deployment' = ''; 'resource-group' = ''; 'gateway-deployment' = 'resource-group'; 'company-address' = 'gateway-deployment'; 'entra-groups' = ''
    'sync' = 'gateway-deployment,entra-groups'; 'projection' = 'gateway-deployment,sync'; 'business-units' = 'gateway-deployment'; 'onboarding-package' = 'gateway-deployment'; 'verify' = 'gateway-deployment' }
function Test-Refusal($Result, [string]$Pattern) {
    $lines = @(Get-P91ErrLines $Result)
    ($Result.ExitCode -eq 1 -and $lines.Count -eq 1 -and $lines[0] -match '^Refused: ' -and $lines[0] -match $Pattern -and $lines[0] -match 'Nothing was changed')
}
function Get-Writes($Result) { @($Result.Az | Where-Object { $_ -match '(^| )(create|update|delete|add|remove|assign)( |$)' }) }
function Get-Events([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    # time is read as written: PowerShell 7 reads an ISO time in JSON as a DateTime.
    @([IO.File]::ReadAllText($Path) -split "`n" | Where-Object { $_ } | ForEach-Object {
            $line = $_
            try { $e = $line | ConvertFrom-Json -ErrorAction Stop; $m = [regex]::Match($line, '"time"\s*:\s*"([^"]*)"'); if ($m.Success) { $e.time = $m.Groups[1].Value }; $e }
            catch { [pscustomobject]@{ unreadable = $line } } })
}
function Write-Answers($Scenario, $Answers) { $p = Join-Path $Scenario.Dir 'answers.json'; Write-P91Text $p ($Answers | ConvertTo-Json -Depth 8); return $p }
function New-From($Name, $From, [scriptblock]$World) { $s = New-P91Scenario -Name $Name -Scratch $scratch -From $From; if ($World) { Edit-P91World $s $World }; $s }
# Each call of the projection deployment's stub: its arguments as one JSON array (tests/InstallerCheckpointHarness.ps1).
function Get-ProjectionCalls($Run) { $f = Join-Path $Run.Logs 'projection.log'; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() } }
function Test-ProjectionCall([string]$Json, [System.Collections.IDictionary]$Want, [string[]]$Switches = @()) {
    $a = @($Json | ConvertFrom-Json | ForEach-Object { [string]$_ })
    foreach ($k in $Want.Keys) { $i = [array]::IndexOf($a, [string]$k); if ($i -lt 0 -or $i + 1 -ge $a.Count -or $a[$i + 1] -cne [string]$Want[$k]) { return $false } }
    foreach ($s in $Switches) { if ($a -notcontains $s) { return $false } }
    return $true
}

try {
    $template = New-P91Template $scratch
    # ------------------------------------------------------------------ wave 1: checkpoints to work from
    $w = New-P91World; $w.inject.groupCreateFail = @('claude-code-premium')
    $listSrc = New-P91Scenario -Name 'list-src' -Scratch $scratch -Template $template -World $w
    $progress1 = Join-Path $listSrc.Dir 'progress.ndjson'
    $w = New-P91World; $w.inject.sync = 'graph404'
    $syncFail = New-P91Scenario -Name 'sync-fail' -Scratch $scratch -Template $template -World $w
    $w = New-P91World; $w.inject.groupCreateFail = @('claude-code-premium')
    $precSrc = New-P91Scenario -Name 'prec-src' -Scratch $scratch -Template $template -World $w
    $precDefault = New-P91Scenario -Name 'prec-default' -Scratch $scratch -Template $template -World (New-P91World)
    $stepsNone = New-P91Scenario -Name 'steps-none' -Scratch $scratch -Template $template -World (New-P91World)
    $unknownStep = New-P91Scenario -Name 'unknown-step' -Scratch $scratch -Template $template -World (New-P91World)
    # The failure carries a JWT-shaped value, as an error that echoes a token would: the failed event's
    # message holds the error, so only its redaction keeps the token out of the stream (ADR-0047 decision 12).
    $w = New-P91World; $w.inject.createMode = 'disconnect'; $w.inject.runningPolls = @('forever')
    $w.inject['disconnectDetail'] = 'Authorization: Bearer ' + 'eyJhbGciOiJSUzI1NiJ9' + '.eyJzdWIiOiJwOTItdGVzdCJ9.c2lnbmF0dXJl'
    $disconnect = New-P91Scenario -Name 'disconnect' -Scratch $scratch -Template $template -World $w
    $progressFail = Join-Path $disconnect.Dir 'progress.ndjson'
    # A -ProgressPath that cannot be written (a directory): the run refuses before any Azure call.
    $progressDirScenario = New-P91Scenario -Name 'progress-dir' -Scratch $scratch -Template $template -World (New-P91World)
    $progressDir = Join-Path $progressDirScenario.Dir 'not-a-file'
    New-Item -ItemType Directory -Force -Path $progressDir | Out-Null
    # Round 3, the Security seat's item 5: a failure whose error carries every secret shape, in a checkout
    # whose path holds one too (sig=<value>), so that the failed event's message and resume command quote them.
    $w = New-P91World; $w.inject.createMode = 'disconnect'; $w.inject.runningPolls = @('forever'); $w.inject['disconnectDetail'] = $P92RedactionSentence
    $redact = New-P91Scenario -Name 'redact-sig=p92PathSentinel' -Scratch $scratch -Template $template -World $w
    $progressRedact = Join-Path $redact.Dir 'progress.ndjson'
    # Round 3, the UX seat's item 8: an answers file with two problems, refused before anything is read.
    $answersBad = New-P91Scenario -Name 'answers-bad' -Scratch $scratch -Template $template -World (New-P91World)
    $answersBadFile = Write-Answers $answersBad ([ordered]@{ schemaVersion = 1; Sku = 'Gold'; Bogus = 1 })
    # Round 4, the Security seat's item 4: a refusal and a failure whose errors quote every secret shape, as an
    # Azure CLI error would, printed on the console.
    $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'ad group list --display-name claude-code-standard*'; text = $P92RedactionSentence })
    $consoleRefusal = New-P91Scenario -Name 'console-refusal' -Scratch $scratch -Template $template -World $w
    $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'deployment group create*'; text = $P92RedactionSentence })
    $consoleFailure = New-P91Scenario -Name 'console-failure' -Scratch $scratch -Template $template -World $w
    $wave1 = @(
        ($runList1 = New-P91Run $listSrc -Arguments ($common + $tpm + $secret + "-ProgressPath '$progress1'"))
        ($runSync1 = New-P91Run $syncFail -Arguments ($common + $tpm))
        ($runPrec1 = New-P91Run $precSrc -Arguments ($common + '-TpmStandard 11111'))
        ($runPrecDefault = New-P91Run $precDefault -Arguments $common)
        ($runStepsNone = New-P91Run $stepsNone -Arguments ($common + $tpm + "-Steps 'sync'"))
        ($runUnknown = New-P91Run $unknownStep -Arguments ($common + $tpm + "-Steps 'gateway-deploy'"))
        ($runDisconnect = New-P91Run $disconnect -Arguments ($common + $tpm + "-ProgressPath '$progressFail'"))
        ($runProgressDir = New-P91Run $progressDirScenario -Arguments ($common + $tpm + "-ProgressPath '$progressDir'"))
        ($runRedact = New-P91Run $redact -Arguments ($common + $tpm + "-ProgressPath '$progressRedact'"))
        ($runAnswersBad = New-P91Run $answersBad -Arguments (@($common | Where-Object { $_ -notlike '-Sku *' }) + $tpm + "-AnswersPath '$answersBadFile'"))
        ($runConsoleRefusal = New-P91Run $consoleRefusal -Arguments ($common + $tpm))
        ($runConsoleFailure = New-P91Run $consoleFailure -Arguments ($common + $tpm))
    )
    $r1 = Invoke-P91Runs $wave1
    $l1 = Get-P91Result $r1 $runList1
    $cpList = Get-P91CheckpointFile $listSrc
    Assert 'setup: the first run keeps its checkpoint with Entra groups incomplete, and the run that fails at sync keeps one too' ($l1.ExitCode -eq 0 -and $cpList -and (Get-P91Result $r1 $runSync1).ExitCode -ne 0 -and
        (Get-P91CheckpointFile $syncFail) -and (Get-P91CheckpointFile $precSrc)) "$(Get-P91Tail $l1) || $(Get-P91Tail (Get-P91Result $r1 $runSync1))"

    # ------------------------------------------------------------------ wave 2: from those checkpoints
    $list = New-From 'list' $listSrc; $listText = New-From 'list-text' $listSrc
    $refuse = New-From 'refuse-prereq' $listSrc
    $listHash = Get-P91Hash (Get-P91CheckpointFile $list).FullName
    $refuseHash = Get-P91Hash (Get-P91CheckpointFile $refuse).FullName
    $onlySync = New-From 'only-sync' $syncFail { param($w) $w.inject.sync = '' }
    $gone = New-From 'prereq-gone' $syncFail { param($w) $w.inject.sync = ''; foreach ($p in @($w.groups.PSObject.Properties | Where-Object { $_.Value -eq 'claude-code-standard' })) { $w.groups.PSObject.Properties.Remove($p.Name) } }
    $goneHash = Get-P91Hash (Get-P91CheckpointFile $gone).FullName
    $resume = New-From 'resume-progress' $listSrc { param($w) $w.inject.groupCreateFail = @() }
    $progress2 = Join-Path $resume.Dir 'progress.ndjson'
    $precParam = New-From 'prec-param' $precSrc { param($w) $w.inject.groupCreateFail = @() }
    $precFile = New-From 'prec-file' $precSrc { param($w) $w.inject.groupCreateFail = @() }
    $precCkpt = New-From 'prec-checkpoint' $precSrc { param($w) $w.inject.groupCreateFail = @() }
    $precBind = New-From 'prec-binding' $precSrc
    $bindHash = Get-P91Hash (Get-P91CheckpointFile $precBind).FullName
    $progressBind = Join-Path $precBind.Dir 'progress.ndjson'
    # Round 4, item 4: a resume whose live reads quote every secret shape. The resource group cannot be read
    # (the step is idempotent, so it runs again and prints the read's detail), and the recorded deployment failed
    # with such an error, which the run prints with its failed operation before it deploys again.
    $consoleResume = New-From 'console-resume' $syncFail { param($w) $w.inject.sync = ''
        $w.inject.readErrors = @([pscustomobject]@{ match = 'group show -n rg-p91*'; text = $P92RedactionSentence })
        foreach ($d in @($w.deployments.'rg-p91'.PSObject.Properties)) { $d.Value.state = 'Failed'; $d.Value | Add-Member -NotePropertyName error -NotePropertyValue ([pscustomobject]@{ code = 'DeploymentFailed'; message = $P92RedactionSentence }) -Force } }
    $wave2 = @(
        ($runList = New-P91Run $list -Arguments @('-ListSteps', '-Json'))
        ($runListText = New-P91Run $listText -Arguments @('-ListSteps'))
        ($runRefuse = New-P91Run $refuse -Arguments ($common + $tpm + "-Steps 'sync'"))
        ($runOnlySync = New-P91Run $onlySync -Arguments ($common + $tpm + "-Steps 'sync'"))
        ($runGone = New-P91Run $gone -Arguments ($common + $tpm + "-Steps 'sync'"))
        ($runResume = New-P91Run $resume -Arguments ($common + $tpm + "-ProgressPath '$progress2'"))
        ($runPrecParam = New-P91Run $precParam -Arguments ($common + '-TpmStandard 33333' + "-AnswersPath '$(Write-Answers $precParam ([ordered]@{ schemaVersion = 1; TpmStandard = 22222 }))'"))
        ($runPrecFile = New-P91Run $precFile -Arguments ($common + "-AnswersPath '$(Write-Answers $precFile ([ordered]@{ schemaVersion = 1; TpmStandard = 22222 }))'"))
        ($runPrecCkpt = New-P91Run $precCkpt -Arguments $common)
        ($runPrecBind = New-P91Run $precBind -Arguments (@($common | Where-Object { $_ -notlike '-ResourceGroup *' }) + "-AnswersPath '$(Write-Answers $precBind ([ordered]@{ schemaVersion = 1; ResourceGroup = 'rg-other' }))'" + "-ProgressPath '$progressBind'"))
        ($runConsoleResume = New-P91Run $consoleResume -Arguments ($common + $tpm))
    )
    $r2 = Invoke-P91Runs $wave2

    # ------------------------------------------------------------------ -ListSteps
    $ls = Get-P91Result $r2 $runList
    $json = $null; try { $json = $ls.Out | ConvertFrom-Json -ErrorAction Stop } catch { }
    $state = @{}; foreach ($s in @(if ($json) { $json.steps })) { $state[[string]$s.id] = [string]$s.state }
    $depDrift = @(foreach ($s in @(if ($json) { $json.steps })) { if ((@($s.dependencies) -join ',') -ne $deps[[string]$s.id] -or -not $s.title) { "$($s.id): $(@($s.dependencies) -join ',')" } })
    Assert 'P3 -ListSteps -Json prints only JSON: the 10 step ids in order, each with its title and dependencies' ($ls.ExitCode -eq 0 -and $json -and $json.schemaVersion -eq 1 -and $json.installer -eq 'pwsh' -and
        ((@($json.steps | ForEach-Object id)) -join ',') -eq ($stepIds -join ',') -and -not $depDrift.Count) "$($depDrift -join '; ') || $(Get-P91Tail $ls)"
    Assert 'P3 -ListSteps -Json gives each step the state the install checkpoint records, and names the checkpoint and its run' ($state['resource-group'] -eq 'completed' -and $state['gateway-deployment'] -eq 'completed' -and
        $state['entra-groups'] -eq 'incomplete' -and $state['sync'] -eq 'completed' -and $state['company-address'] -eq 'not-started' -and $state['claude-deployment'] -eq 'not-started' -and
        $json.checkpoint -like '*install-*.json' -and [string]$json.runId -match '^[0-9a-f]{32}$') (($state.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
    $lt = Get-P91Result $r2 $runListText
    Assert 'P3 -ListSteps reads only the checkpoint: no Azure CLI call, the checkpoint unchanged, and the text form names each id with its title and state' (-not $ls.Az.Count -and -not $lt.Az.Count -and
        (Get-P91Hash (Get-P91CheckpointFile $list).FullName) -eq $listHash -and $lt.Out -match '(?m)^\s*entra-groups\s+Entra groups\s+incomplete' -and $lt.Out -match '(?m)^\s*verify\s+Verification\s+') (Get-P91Tail $lt)

    # ------------------------------------------------------------------ -Steps
    $rf = Get-P91Result $r2 $runRefuse
    Assert 'P3 -Steps sync with Entra groups incomplete refuses on one line naming entra-groups; nothing changes' ((Test-Refusal $rf '\bsync\b.*\bentra-groups\b') -and -not (Get-Writes $rf).Count -and
        -not $rf.Scripts.Count -and (Get-P91Hash (Get-P91CheckpointFile $refuse).FullName) -eq $refuseHash) (Get-P91Tail $rf)
    $sn = Get-P91Result $r1 $runStepsNone
    Assert 'P3 -Steps sync with no checkpoint refuses naming both prerequisites, gateway-deployment and entra-groups; nothing is created' ((Test-Refusal $sn 'gateway-deployment') -and @(Get-P91ErrLines $sn)[0] -match 'entra-groups' -and
        -not (Get-Writes $sn).Count -and -not (Get-P91CheckpointFile $stepsNone)) (Get-P91Tail $sn)
    $uk = Get-P91Result $r1 $runUnknown
    Assert 'P3 -Steps with an unknown id refuses on one line naming it and the known ids' ((Test-Refusal $uk "gateway-deploy'") -and @(Get-P91ErrLines $uk)[0] -match 'gateway-deployment' -and -not (Get-Writes $uk).Count) (Get-P91Tail $uk)
    $gn = Get-P91Result $r2 $runGone
    Assert 'P3 -Steps sync refuses when the checkpoint says Entra groups completed but Microsoft Graph no longer returns the group (verified live, not from the checkpoint)' ((Test-Refusal $gn 'entra-groups') -and
        -not $gn.Scripts.Count -and -not (Get-Writes $gn).Count -and (Get-P91Hash (Get-P91CheckpointFile $gone).FullName) -eq $goneHash) (Get-P91Tail $gn)
    $os = Get-P91Result $r2 $runOnlySync
    $osCp = Get-P91CheckpointFile $onlySync
    $osSteps = if ($osCp) { (Get-Content -LiteralPath $osCp.FullName -Raw | ConvertFrom-Json).steps } else { @() }
    Assert 'P3 with its prerequisites verified live, -Steps sync runs the sync and nothing else: no Azure write, no other script, no onboarding package' ($os.ExitCode -eq 0 -and
        @($os.Scripts | Where-Object { $_ -like 'sync *' }).Count -eq 1 -and @($os.Scripts).Count -eq 1 -and -not (Get-Writes $os).Count -and
        -not (Test-Path -LiteralPath (Join-Path $onlySync.Repo 'onboarding\claude-gateway.json')) -and @($osSteps | Where-Object { $_.id -eq 'sync' -and $_.state -eq 'completed' }).Count -eq 1 -and
        -not @($osSteps | Where-Object { $_.id -in 'onboarding-package', 'verify' }).Count) "$(Get-P91Tail $os) || scripts: $($os.Scripts -join '; ') || writes: $((Get-Writes $os) -join '; ')"

    # ------------------------------------------------------------------ precedence
    $tpmOf = { param($Result) @($Result.Az | Where-Object { $_ -like 'deployment group create*' } | ForEach-Object { if ($_ -match 'tpmStandard=(\d+)') { $Matches[1] } }) -join ',' }
    $summaryOf = { param($Result) if ($Result.Out -match '(?m)^\s+Standard tier\s+([\d,]+) tokens/min') { $Matches[1] } else { '' } }
    $pp = Get-P91Result $r2 $runPrecParam; $pf = Get-P91Result $r2 $runPrecFile; $pc = Get-P91Result $r2 $runPrecCkpt; $pd = Get-P91Result $r1 $runPrecDefault
    Assert 'P4 a parameter wins over the answers file and the checkpoint: -TpmStandard 33333 reaches the deployment' ($pp.ExitCode -eq 0 -and (& $tpmOf $pp) -eq '33333' -and (& $summaryOf $pp) -eq '33,333') "$(& $tpmOf $pp) || $(Get-P91Tail $pp)"
    Assert 'P4 the answers file wins over the checkpoint: TpmStandard 22222 reaches the deployment' ($pf.ExitCode -eq 0 -and (& $tpmOf $pf) -eq '22222' -and (& $summaryOf $pf) -eq '22,222') "$(& $tpmOf $pf) || $(Get-P91Tail $pf)"
    Assert 'P4 the checkpoint wins over the default: the recorded 11111 is used, and the deployment is verified live, not repeated' ($pc.ExitCode -eq 0 -and (& $summaryOf $pc) -eq '11,111' -and -not (& $tpmOf $pc)) (Get-P91Tail $pc)
    Assert 'P4 with no parameter, answers file or checkpoint the default applies: 20000' ($pd.ExitCode -eq 0 -and (& $tpmOf $pd) -eq '20000' -and (& $summaryOf $pd) -eq '20,000') "$(& $tpmOf $pd) || $(Get-P91Tail $pd)"
    $pb = Get-P91Result $r2 $runPrecBind
    Assert 'P4 an answers file that names another resource group than the checkpoint refuses on one line naming the field; nothing changes' ((Test-Refusal $pb 'resource group') -and @(Get-P91ErrLines $pb)[0] -match 'rg-other' -and
        -not (Get-Writes $pb).Count -and (Get-P91Hash (Get-P91CheckpointFile $precBind).FullName) -eq $bindHash) (Get-P91Tail $pb)

    # ------------------------------------------------------------------ progress
    $first = @(Get-Events $progress1); $second = @(Get-Events $progress2); $failed = @(Get-Events $progressFail); $bound = @(Get-Events $progressBind)
    $all = @($first + $second + $failed + $bound)
    $fields = 'schemaVersion,time,runId,stepId,event,message,resumeCommand'
    $malformed = @($all | Where-Object { $_.PSObject.Properties.Name -contains 'unreadable' -or (@($_.PSObject.Properties.Name) -join ',') -ne $fields -or $_.schemaVersion -ne 1 -or
            [string]$_.time -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' -or [string]$_.runId -notmatch '^[0-9a-f]{32}$' -or $_.event -cnotin 'started', 'completed', 'skipped-verified', 'failed', 'refused', 'warning' -or
            ($_.stepId -and $_.stepId -notin $stepIds) -or -not $_.message })
    Assert 'P5 every progress line is one JSON object with schemaVersion, UTC time, runId, stepId, event, message and resumeCommand, in that order' ($all.Count -ge 12 -and -not $malformed.Count) (($malformed | Select-Object -First 3 | ConvertTo-Json -Compress -Depth 4))
    $pairs = { param($Events, [string]$Step) (@($Events | Where-Object { $_.stepId -eq $Step } | ForEach-Object { $_.event })) -join ',' }
    Assert 'P5 a run emits started and completed for each step it runs, and warning with the resume command for one it leaves incomplete; one runId' (
        (& $pairs $first 'resource-group') -eq 'started,completed' -and (& $pairs $first 'gateway-deployment') -eq 'started,completed' -and (& $pairs $first 'sync') -eq 'started,completed' -and
        (& $pairs $first 'onboarding-package') -eq 'started,completed' -and (& $pairs $first 'entra-groups') -eq 'started,warning' -and
        @($first | Where-Object { $_.event -eq 'warning' -and $_.resumeCommand -match 'Install-ClaudeGateway\.ps1' }).Count -ge 1 -and @($first.runId | Select-Object -Unique).Count -eq 1) (($first | ForEach-Object { "$($_.stepId):$($_.event)" }) -join ' ')
    Assert 'P5 a resume emits skipped-verified for each step it verifies live, then runs the rest, under the same runId' ((& $pairs $second 'resource-group') -eq 'skipped-verified' -and
        (& $pairs $second 'gateway-deployment') -eq 'skipped-verified' -and (& $pairs $second 'entra-groups') -eq 'started,completed' -and
        @($second.runId | Select-Object -Unique).Count -eq 1 -and $second[0].runId -eq $first[0].runId) (($second | ForEach-Object { "$($_.stepId):$($_.event)" }) -join ' ')
    Assert 'P5 a failure emits failed for its step with the resume command' (@($failed | Where-Object { $_.event -eq 'failed' -and $_.stepId -eq 'gateway-deployment' -and $_.resumeCommand -match 'Install-ClaudeGateway\.ps1' }).Count -eq 1 -and
        (Get-P91Result $r1 $runDisconnect).ExitCode -ne 0) (($failed | ConvertTo-Json -Compress -Depth 3))
    $pd = Get-P91Result $r1 $runProgressDir
    Assert 'P5 an unwritable -ProgressPath (a directory) refuses at startup on one line naming -ProgressPath, before any Azure call; nothing is written' ((Test-Refusal $pd '-ProgressPath .+ cannot be written') -and
        -not $pd.Az.Count -and -not (Get-P91CheckpointFile $progressDirScenario) -and -not @(Get-ChildItem -LiteralPath $progressDir -Force).Count) (Get-P91Tail $pd)
    Assert 'P5 a refusal emits refused with its reason' (@($bound | Where-Object { $_.event -eq 'refused' -and $_.message -match 'resource group' }).Count -eq 1) (($bound | ConvertTo-Json -Compress -Depth 3))
    $texts = @(@($progress1, $progress2, $progressFail, $progressBind) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [IO.File]::ReadAllText($_) }) +
        @(foreach ($s in $listSrc, $resume, $precParam) { $f = Get-P91CheckpointFile $s; if ($f) { [IO.File]::ReadAllText($f.FullName) } }) +
        @(Get-ChildItem -LiteralPath $scratch -Recurse -Filter 'answers.json' -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) })
    $leak = @($texts | Where-Object { $_ -match 'P92-PFX-SENTINEL|eyJ[A-Za-z0-9_-]{4,}\.|(?i)password|accesstoken' })
    $redacted = @(@(Get-Events $progressFail) | Where-Object { $_.event -eq 'failed' -and $_.message -match '\[redacted\]' })
    Assert 'P5 no secret reaches the progress stream, the checkpoint or an answers file: not the PFX password passed to the run, not the token in a failure''s error, which the failed event carries as [redacted]' ($texts.Count -ge 6 -and -not $leak.Count -and $redacted.Count -eq 1) "$($leak.Count) of $($texts.Count) texts; failed events with [redacted]: $($redacted.Count)"
    # ------------------------------------------------------------------ round 3: redaction in the stream (item 5)
    $rx = Get-P91Result $r1 $runRedact
    $rxEvents = @(Get-Events $progressRedact)
    $rxFailed = @($rxEvents | Where-Object { $_.event -eq 'failed' -and $_.stepId -eq 'gateway-deployment' })[0]
    $rxProblems = @(Get-P92RedactionProblems "$($rxFailed.message)")
    $rxText = if (Test-Path -LiteralPath $progressRedact) { [IO.File]::ReadAllText($progressRedact) } else { '' }
    Assert 'R3 the failed event redacts every secret shape in the error it quotes: each becomes its [redacted] form, and no sentinel appears in the progress file or in stdout' ($rx.ExitCode -ne 0 -and $rxFailed -and
        -not $rxProblems.Count -and $rxText -and (Test-P92NoSentinel $rxText) -and (Test-P92NoSentinel $rx.Out)) "$($rxProblems -join '; ') || $($rxFailed.message)"
    Assert 'R3 the failed event redacts a secret shape in its resume command: a checkout path that holds sig=<value> is written as sig=[redacted]' ($rxFailed -and "$($rxFailed.resumeCommand)" -match 'Install-ClaudeGateway\.ps1' -and
        "$($rxFailed.resumeCommand)" -match 'sig=\[redacted\]' -and -not $rxText.Contains('p92PathSentinel')) "$($rxFailed.resumeCommand)"
    # ------------------------------------------------------------------ round 3: refusals name the next step (items 6, 7, 8)
    Assert 'R3 the -ProgressPath refusal names the next step: a writable file path, or a run without -ProgressPath' (@(Get-P91ErrLines $pd).Count -eq 1 -and
        @(Get-P91ErrLines $pd)[0].Contains('Give a writable file path, or run without -ProgressPath.')) (Get-P91Tail $pd)
    Assert 'R3 the unknown-step refusal says that -ListSteps lists the steps with their state' (@(Get-P91ErrLines $uk).Count -eq 1 -and @(Get-P91ErrLines $uk)[0].Contains('./Install-ClaudeGateway.ps1 -ListSteps lists the steps with their state.')) (Get-P91Tail $uk)
    $ab = Get-P91Result $r1 $runAnswersBad
    $abLine = @(Get-P91ErrLines $ab)[0]
    # Test-ClaudePrerequisites runs before the answers file is read: Azure CLI's version, its account and Bicep, and
    # whether management.azure.com answers. No Azure resource is read.
    $probes = @($ab.Az | Where-Object { $_ -notmatch '^(version|account list|account show|bicep version)( |$)' -and $_ -notlike 'WEB *' })
    Assert 'R3 an answers file with problems refuses on one line with the first problem, its remedy, the number of problems and the command that lists every one; no Azure resource is read' ((Test-Refusal $ab 'does not match the answers schema') -and
        $abLine.Contains('(2 problems)') -and $abLine -match 'Remedy: \S' -and $abLine -match 'Bogus|Gold' -and $abLine.Contains("./Install-ClaudeGateway.ps1 -Preflight -AnswersPath '$answersBadFile' lists every problem.") -and
        -not $probes.Count -and -not (Get-P91CheckpointFile $answersBad)) "$abLine || az: $($ab.Az -join ' | ')"
    # ------------------------------------------------------------------ round 4: the console (item 4)
    $cr = Get-P91Result $r1 $runConsoleRefusal
    $crLine = [string](@(Get-P91ErrLines $cr | Where-Object { $_ -match '^Refused: ' })[0])
    $crProblems = @(Get-P92RedactionProblems $crLine)
    Assert 'R4 a refusal whose error quotes every secret shape prints each in its [redacted] form on standard error, and no sentinel appears in stdout or stderr' ((Test-Refusal $cr 'claude-code-standard') -and
        -not $crProblems.Count -and (Test-P92NoSentinel ($cr.Out + $cr.Err))) "$($crProblems -join '; ') || $crLine"
    $cf = Get-P91Result $r1 $runConsoleFailure
    $cfProblems = @(Get-P92RedactionProblems $cf.Err)
    Assert 'R4 a failure whose Azure CLI error quotes every secret shape prints that error with each in its [redacted] form, then the failure and the resume command, and no sentinel appears in stdout or stderr' (
        $cf.ExitCode -ne 0 -and -not $cfProblems.Count -and $cf.Err -match 'Deployment failed' -and $cf.Out -match '(?m)^Resume: ' -and (Test-P92NoSentinel ($cf.Out + $cf.Err))) "$($cfProblems -join '; ') || $(Get-P91Tail $cf)"
    $installerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\Install-ClaudeGateway.ps1'), [ref]$null, [ref]$null)
    $helperText = @{}
    foreach ($fn in $installerAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $helperText[$fn.Name] = $fn.Extent.Text }
    . (Join-Path $PSScriptRoot '..\scripts\ClaudeInstallResume.ps1')
    $siteProblems = @()
    foreach ($name in 'Write-Warn2', 'Write-Bad') {
        if (-not $helperText.ContainsKey($name)) { $siteProblems += "${name}: not defined"; continue }
        . ([scriptblock]::Create($helperText[$name]))
        $line = (@(& $name "an error that quotes ($P92RedactionSentence)" 6>&1) | ForEach-Object { [string]$_ }) -join "`n"
        $kind = if ($name -eq 'Write-Warn2') { '\[WARN\]' } else { '\[FAIL\]' }
        if ($line -notmatch $kind) { $siteProblems += "${name}: no $kind line" }
        foreach ($p in @(Get-P92RedactionProblems $line)) { $siteProblems += "${name}: $p" }
    }
    Assert 'R5 Write-Warn2 and Write-Bad warning and failure lines quote every secret shape only in its [redacted] form, with no sentinel' (-not $siteProblems.Count) ($siteProblems -join '; ')
    # R3's redact run on the console: the failure ends at the top-level trap, which prints the error on standard
    # error, and the failure hint prints the resume command of a checkout path that holds sig=<value>.
    $rxTrap = [string](@(Get-P91ErrLines $rx | Where-Object { $_ -match 'disconnected' })[0])
    $rxTrapProblems = @(Get-P92RedactionProblems $rxTrap)
    Assert 'R4 a failure that ends at the top-level trap prints its error with each secret shape in its [redacted] form, then a Resume line with sig=[redacted], and no sentinel in stdout or stderr' ($rx.ExitCode -ne 0 -and $rxTrap -and
        -not $rxTrapProblems.Count -and $rx.Out -match '(?m)^Resume: .*sig=\[redacted\]' -and (Test-P92NoSentinel ($rx.Out + $rx.Err)) -and -not "$($rx.Out)$($rx.Err)".Contains('p92PathSentinel')) "$($rxTrapProblems -join '; ') || $rxTrap || $(Get-P91Tail $rx)"
    $cv = Get-P91Result $r2 $runConsoleResume
    $cvLines = @($cv.Out -split "`n" | Where-Object { $_ -match '(Resource group: .*running it again|Gateway deployment: deployment \S+ Failed: |failed operation: )' })
    $cvProblems = @(foreach ($l in $cvLines) { Get-P92RedactionProblems $l })
    Assert 'R4 a resume whose live reads quote every secret shape prints the resource group''s read detail, the failed deployment''s error and its failed operation, each shape in its [redacted] form, and no sentinel in stdout or stderr' (
        $cv.ExitCode -eq 0 -and $cvLines.Count -eq 3 -and -not $cvProblems.Count -and (Test-P92NoSentinel ($cv.Out + $cv.Err))) "$($cvProblems -join '; ') || $($cvLines -join ' || ') || $(Get-P91Tail $cv)"
    $unexpected = @(foreach ($r in @($r1.Values) + @($r2.Values)) { @($r.Unexpected) })
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @(@($r1.Values) + @($r2.Values) | Where-Object { $_.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
