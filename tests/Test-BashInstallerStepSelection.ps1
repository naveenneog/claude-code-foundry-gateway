# P92 acceptance tests 3, 4 and 5, bash half (docs/adr/0047-lean-installer-phase-0.md): --list-steps,
# --steps, answer precedence and --progress-file in install-claude-gateway.sh, with the same contracts as
# Install-ClaudeGateway.ps1 (tests/Test-InstallerStepSelection.ps1). One PowerShell run over the same
# kind of world checks that both installers write the same progress events. Runs through the stubs of
# tests/BashInstallerHarness.ps1 and tests/InstallerCheckpointHarness.ps1; nothing reaches Azure.
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
Write-Host 'Installer step selection, precedence and progress (bash installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'BashInstallerHarness.ps1')
. (Join-Path $PSScriptRoot 'InstallerCheckpointHarness.ps1')
$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('p92-bash-steps-' + [guid]::NewGuid().ToString('N'))))
$made = New-BashTemplate $scratch
$template = $made.Template; $psTable = $made.PsTable
$bashIds = @('resource-group', 'gateway-deployment', 'entra-groups', 'sync', 'onboarding-package')
$deps = [ordered]@{ 'resource-group' = ''; 'gateway-deployment' = 'resource-group'; 'entra-groups' = ''; 'sync' = 'gateway-deployment,entra-groups'; 'onboarding-package' = 'gateway-deployment' }
$base = @('--subscription', $sub, '--foundry-account', 'ai-p91', '--foundry-rg', 'rg-ai-p91', '--resource-group', 'rg-p91', '--location', 'eastus2', '--name-prefix', 'p91gw',
    '--publisher-email', 'ops@contoso.com', '--sku', 'BasicV2', '--quota-standard', '500000', '--tpm-premium', '80000', '--quota-premium', '5000000', '--calls-per-minute', '120', '--yes', '--skip-finops-offer')
$tpm = @('--tpm-standard', '20000')
function Get-Writes($Result) { @($Result.Az | Where-Object { $_ -match '(^| )(create|update|delete|add|remove|assign)( |$)' }) }
function Get-Events([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @([IO.File]::ReadAllText($Path) -split "`n" | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json -ErrorAction Stop } catch { [pscustomobject]@{ unreadable = $_ } } })
}
function Write-Answers($Scenario, $Answers) { $p = Join-Path $Scenario.Dir 'answers.json'; Write-Lf $p ($Answers | ConvertTo-Json -Depth 8); return (ConvertTo-BashPath $p) }
function Copy-Scenario($Name, $Source, [scriptblock]$Change) { $s = New-Scenario $Name $null $Source; if ($Change) { Edit-World $s $Change }; $s }
function Test-Refused($Result, [string]$Pattern) { (Test-Refusal $Result $Pattern) }

try {
    $w = New-World; $w.inject.groupCreateFail = @('claude-code-premium')
    $listSrc = New-Scenario 'list-src' $w
    $progress1 = Join-Path $listSrc.Dir 'progress.ndjson'
    $w = New-World; $w.inject.sync = 'fail'
    $syncFail = New-Scenario 'sync-fail' $w
    $w = New-World; $w.inject.groupCreateFail = @('claude-code-premium')
    $precSrc = New-Scenario 'prec-src' $w
    $precDefault = New-Scenario 'prec-default' (New-World)
    $stepsNone = New-Scenario 'steps-none' (New-World)
    $unknown = New-Scenario 'unknown-step' (New-World)
    $w = New-World; $w.inject.createMode = 'fail'
    $failing = New-Scenario 'failing' $w
    $progressFail = Join-Path $failing.Dir 'progress.ndjson'
    $wave1 = @(
        ($runList1 = New-Run $listSrc ($base + $tpm + @('--progress-file', (ConvertTo-BashPath $progress1))))
        ($runSync1 = New-Run $syncFail ($base + $tpm))
        ($runPrec1 = New-Run $precSrc ($base + @('--tpm-standard', '11111')))
        ($runDefault = New-Run $precDefault $base)
        ($runNone = New-Run $stepsNone ($base + $tpm + @('--steps', 'sync')))
        ($runUnknown = New-Run $unknown ($base + $tpm + @('--steps', 'gateway-deploy')))
        ($runFailing = New-Run $failing ($base + $tpm + @('--progress-file', (ConvertTo-BashPath $progressFail))))
    )
    # The PowerShell installer over the same kind of world, for the parity of progress events.
    $psScratch = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('p92-parity-' + [guid]::NewGuid().ToString('N'))))
    New-Item -ItemType Directory -Force -Path $psScratch | Out-Null
    $psTemplate = New-P91Template $psScratch
    $pw = New-P91World; $pw.inject.groupCreateFail = @('claude-code-premium')
    $psScenario = New-P91Scenario -Name 'parity' -Scratch $psScratch -Template $psTemplate -World $pw
    $psProgress = Join-Path $psScenario.Dir 'progress.ndjson'
    $psRun = New-P91Run $psScenario -Arguments @("-SubscriptionId '$sub'", "-FoundryAccount 'ai-p91'", "-FoundryResourceGroup 'rg-ai-p91'", "-EntitlementStore 'named-value'", "-AuthMode 'interactive'",
        "-DesktopSignInKind 'helper-script'", "-AddressMode 'azure'", '-SkipFinOpsOffer', "-ResourceGroup 'rg-p91'", "-Location 'eastus2'", "-NamePrefix 'p91gw'", "-PublisherEmail 'ops@contoso.com'",
        "-Sku 'BasicV2'", "-StandardModels 'claude-sonnet-5'", "-PremiumModels 'claude-sonnet-5'", '-TpmStandard 20000', '-QuotaStandard 500000', '-TpmPremium 80000', '-QuotaPremium 5000000',
        '-QuotaOrg 100000000', '-CallsPerMinute 120', '-Yes', "-ProgressPath '$psProgress'")
    $psResults = Invoke-P91Runs @($psRun)
    $r1 = Invoke-Runs $wave1
    $l1 = $r1[$runList1.Dir]
    Assert 'setup: the first run keeps its checkpoint with Entra groups incomplete, and the run whose sync fails keeps one with sync incomplete' ($l1.ExitCode -eq 0 -and (Get-CheckpointFile $listSrc) -and
        (Get-CheckpointFile $syncFail) -and (Get-CheckpointFile $precSrc)) "$(Get-Tail $l1) || $(Get-Tail $r1[$runSync1.Dir])"

    $list = Copy-Scenario 'list' $listSrc; $listText = Copy-Scenario 'list-text' $listSrc; $refuse = Copy-Scenario 'refuse-prereq' $listSrc
    $listHash = Get-Hash $list; $refuseHash = Get-Hash $refuse
    $onlySync = Copy-Scenario 'only-sync' $syncFail { param($w) $w.inject.sync = '' }
    $gone = Copy-Scenario 'prereq-gone' $syncFail { param($w) $w.inject.sync = ''; foreach ($p in @($w.groups.PSObject.Properties | Where-Object { $_.Value -eq 'claude-code-standard' })) { $w.groups.PSObject.Properties.Remove($p.Name) } }
    $goneHash = Get-Hash $gone
    $resume = Copy-Scenario 'resume-progress' $listSrc { param($w) $w.inject.groupCreateFail = @() }
    $progress2 = Join-Path $resume.Dir 'progress.ndjson'
    $precParam = Copy-Scenario 'prec-param' $precSrc { param($w) $w.inject.groupCreateFail = @() }
    $precFile = Copy-Scenario 'prec-file' $precSrc { param($w) $w.inject.groupCreateFail = @() }
    $precCkpt = Copy-Scenario 'prec-checkpoint' $precSrc { param($w) $w.inject.groupCreateFail = @() }
    $precBind = Copy-Scenario 'prec-binding' $precSrc
    $bindHash = Get-Hash $precBind
    $progressBind = Join-Path $precBind.Dir 'progress.ndjson'
    $noRg = @(for ($i = 0; $i -lt $base.Count; $i++) { if ($base[$i] -eq '--resource-group') { $i++; continue }; $base[$i] })
    $wave2 = @(
        ($runList = New-Run $list @('--list-steps', '--json'))
        ($runListText = New-Run $listText @('--list-steps'))
        ($runRefuse = New-Run $refuse ($base + $tpm + @('--steps', 'sync')))
        ($runOnlySync = New-Run $onlySync ($base + $tpm + @('--steps', 'sync')))
        ($runGone = New-Run $gone ($base + $tpm + @('--steps', 'sync')))
        ($runResume = New-Run $resume ($base + $tpm + @('--progress-file', (ConvertTo-BashPath $progress2))))
        ($runPrecParam = New-Run $precParam ($base + @('--tpm-standard', '33333', '--answers-file', (Write-Answers $precParam ([ordered]@{ schemaVersion = 1; TpmStandard = 22222 })))))
        ($runPrecFile = New-Run $precFile ($base + @('--answers-file', (Write-Answers $precFile ([ordered]@{ schemaVersion = 1; TpmStandard = 22222 })))))
        ($runPrecCkpt = New-Run $precCkpt $base)
        ($runPrecBind = New-Run $precBind ($noRg + @('--answers-file', (Write-Answers $precBind ([ordered]@{ schemaVersion = 1; ResourceGroup = 'rg-other' })), '--progress-file', (ConvertTo-BashPath $progressBind))))
    )
    $r2 = Invoke-Runs $wave2

    $ls = $r2[$runList.Dir]
    $json = $null; try { $json = $ls.Out | ConvertFrom-Json -ErrorAction Stop } catch { }
    $state = @{}; foreach ($s in @(if ($json) { $json.steps })) { $state[[string]$s.id] = [string]$s.state }
    $depDrift = @(foreach ($s in @(if ($json) { $json.steps })) { if ((@($s.dependencies) -join ',') -ne $deps[[string]$s.id] -or -not $s.title) { "$($s.id): $(@($s.dependencies) -join ',')" } })
    Assert 'P3 bash --list-steps --json prints only JSON: the five steps this installer runs, in order, each with its title and dependencies' ($ls.ExitCode -eq 0 -and $json -and $json.schemaVersion -eq 1 -and $json.installer -eq 'bash' -and
        ((@($json.steps | ForEach-Object id)) -join ',') -eq ($bashIds -join ',') -and -not $depDrift.Count) "$($depDrift -join '; ') || $(Get-Tail $ls)"
    Assert 'P3 bash --list-steps --json gives each step the state the install checkpoint records, and names the checkpoint and its run' ($state['resource-group'] -eq 'completed' -and $state['gateway-deployment'] -eq 'completed' -and
        $state['entra-groups'] -eq 'incomplete' -and $state['sync'] -eq 'completed' -and [string]$json.checkpoint -like '*install-*.json' -and [string]$json.runId -match '^[0-9a-f]{32}$') (($state.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
    $lt = $r2[$runListText.Dir]
    Assert 'P3 bash --list-steps reads only the checkpoint: no Azure CLI call, the checkpoint unchanged, and the text names each id with its title and state' (-not $ls.Az.Count -and -not $lt.Az.Count -and
        (Get-Hash $list) -eq $listHash -and $lt.Out -match '(?m)^\s*entra-groups\s+Entra groups\s+incomplete') (Get-Tail $lt)
    $rf = $r2[$runRefuse.Dir]
    Assert 'P3 bash --steps sync with Entra groups incomplete refuses on one line naming entra-groups; nothing changes' ((Test-Refused $rf '\bsync\b.*\bentra-groups\b') -and -not (Get-Writes $rf).Count -and
        -not @($rf.Scripts | Where-Object { $_ -like '*Sync-ClaudeAccess*' }).Count -and (Get-Hash $refuse) -eq $refuseHash) (Get-Tail $rf)
    $sn = $r1[$runNone.Dir]
    Assert 'P3 bash --steps sync with no checkpoint refuses naming gateway-deployment and entra-groups; nothing is created' ((Test-Refused $sn 'gateway-deployment') -and @(Get-ErrLines $sn)[0] -match 'entra-groups' -and
        -not (Get-Writes $sn).Count -and -not (Get-CheckpointFile $stepsNone)) (Get-Tail $sn)
    $uk = $r1[$runUnknown.Dir]
    Assert 'P3 bash --steps with an unknown id refuses on one line naming it and the known ids' ((Test-Refused $uk "gateway-deploy'") -and @(Get-ErrLines $uk)[0] -match 'gateway-deployment' -and -not (Get-Writes $uk).Count) (Get-Tail $uk)
    $gn = $r2[$runGone.Dir]
    Assert 'P3 bash --steps sync refuses when Microsoft Graph no longer returns a group the checkpoint records (verified live, not from the checkpoint)' ((Test-Refused $gn 'entra-groups') -and
        -not @($gn.Scripts | Where-Object { $_ -like '*Sync-ClaudeAccess*' }).Count -and -not (Get-Writes $gn).Count -and (Get-Hash $gone) -eq $goneHash) (Get-Tail $gn)
    $os = $r2[$runOnlySync.Dir]
    Assert 'P3 bash with its prerequisites verified live, --steps sync runs the sync and nothing else: no Azure write, no onboarding package' ($os.ExitCode -eq 0 -and
        @($os.Scripts | Where-Object { $_ -like '*Sync-ClaudeAccess*' }).Count -eq 1 -and -not (Get-Writes $os).Count -and -not (Test-Path -LiteralPath (Join-Path $onlySync.Repo 'onboarding/claude-gateway.json'))) "$(Get-Tail $os) || $((Get-Writes $os) -join '; ')"

    $tpmOf = { param($Result) @($Result.Az | Where-Object { $_ -like 'deployment group create*' } | ForEach-Object { if ($_ -match 'tpmStandard=(\d+)') { $Matches[1] } }) -join ',' }
    $summaryOf = { param($Result) if ($Result.Out -match '(?m)^\s+Standard tier\s+([\d,.]+) tokens/min') { $Matches[1] -replace '[,.]', '' } else { '' } }
    $pp = $r2[$runPrecParam.Dir]; $pf = $r2[$runPrecFile.Dir]; $pc = $r2[$runPrecCkpt.Dir]; $pd = $r1[$runDefault.Dir]
    Assert 'P4 bash a flag wins over the answers file and the checkpoint: --tpm-standard 33333 reaches the deployment' ($pp.ExitCode -eq 0 -and (& $tpmOf $pp) -eq '33333' -and (& $summaryOf $pp) -eq '33333') "$(& $tpmOf $pp) || $(Get-Tail $pp)"
    Assert 'P4 bash the answers file wins over the checkpoint: TpmStandard 22222 reaches the deployment' ($pf.ExitCode -eq 0 -and (& $tpmOf $pf) -eq '22222' -and (& $summaryOf $pf) -eq '22222') "$(& $tpmOf $pf) || $(Get-Tail $pf)"
    Assert 'P4 bash the checkpoint wins over the default: the recorded 11111 is used, and the deployment is verified live, not repeated' ($pc.ExitCode -eq 0 -and (& $summaryOf $pc) -eq '11111' -and -not (& $tpmOf $pc)) (Get-Tail $pc)
    Assert 'P4 bash with no flag, answers file or checkpoint the default applies: 20000' ($pd.ExitCode -eq 0 -and (& $tpmOf $pd) -eq '20000') "$(& $tpmOf $pd) || $(Get-Tail $pd)"
    $pb = $r2[$runPrecBind.Dir]
    Assert 'P4 bash an answers file that names another resource group than the checkpoint refuses on one line naming the field; nothing changes' ((Test-Refused $pb 'resource group') -and @(Get-ErrLines $pb)[0] -match 'rg-other' -and
        -not (Get-Writes $pb).Count -and (Get-Hash $precBind) -eq $bindHash) (Get-Tail $pb)

    $first = @(Get-Events $progress1); $second = @(Get-Events $progress2); $failed = @(Get-Events $progressFail); $bound = @(Get-Events $progressBind)
    $all = @($first + $second + $failed + $bound)
    $fields = 'schemaVersion,time,runId,stepId,event,message,resumeCommand'
    $malformed = @($all | Where-Object { $_.PSObject.Properties.Name -contains 'unreadable' -or (@($_.PSObject.Properties.Name) -join ',') -ne $fields -or $_.schemaVersion -ne 1 -or
            [string]$_.time -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' -or [string]$_.runId -notmatch '^[0-9a-f]{32}$' -or $_.event -cnotin 'started', 'completed', 'skipped-verified', 'failed', 'refused', 'warning' -or
            ($_.stepId -and $_.stepId -notin $bashIds) -or -not $_.message })
    Assert 'P5 bash every progress line is one JSON object with schemaVersion, UTC time, runId, stepId, event, message and resumeCommand, in that order' ($all.Count -ge 10 -and -not $malformed.Count) (($malformed | Select-Object -First 3 | ConvertTo-Json -Compress -Depth 4))
    $pairs = { param($Events, [string]$Step) (@($Events | Where-Object { $_.stepId -eq $Step } | ForEach-Object { $_.event })) -join ',' }
    Assert 'P5 bash a run emits started and completed per step, and warning with the resume command for a step it leaves incomplete; one runId' ((& $pairs $first 'resource-group') -eq 'started,completed' -and
        (& $pairs $first 'gateway-deployment') -eq 'started,completed' -and (& $pairs $first 'entra-groups') -eq 'started,warning' -and (& $pairs $first 'sync') -eq 'started,completed' -and
        (& $pairs $first 'onboarding-package') -eq 'started,completed' -and @($first | Where-Object { $_.event -eq 'warning' -and $_.resumeCommand -match 'install-claude-gateway\.sh' }).Count -ge 1 -and
        @($first.runId | Select-Object -Unique).Count -eq 1) (($first | ForEach-Object { "$($_.stepId):$($_.event)" }) -join ' ')
    Assert 'P5 bash a resume emits skipped-verified for each step it verifies live, then runs the rest, under the same runId' ((& $pairs $second 'resource-group') -eq 'skipped-verified' -and
        (& $pairs $second 'gateway-deployment') -eq 'skipped-verified' -and (& $pairs $second 'entra-groups') -eq 'started,completed' -and $second.Count -and $second[0].runId -eq $first[0].runId) (($second | ForEach-Object { "$($_.stepId):$($_.event)" }) -join ' ')
    Assert 'P5 bash a failure emits failed for its step with the resume command' (@($failed | Where-Object { $_.event -eq 'failed' -and $_.stepId -eq 'gateway-deployment' -and $_.resumeCommand -match 'install-claude-gateway\.sh' }).Count -eq 1 -and
        $r1[$runFailing.Dir].ExitCode -ne 0) (($failed | ConvertTo-Json -Compress -Depth 3))
    Assert 'P5 bash a refusal emits refused with its reason' (@($bound | Where-Object { $_.event -eq 'refused' -and $_.message -match 'resource group' }).Count -eq 1) (($bound | ConvertTo-Json -Compress -Depth 3))
    $psEvents = @(Get-Events $psProgress)
    $shape = { param($Events) @($Events | Where-Object { $_.stepId -in $bashIds } | ForEach-Object { "$($_.stepId)|$($_.event)|$($_.message)" }) -join "`n" }
    $psOut = Get-P91Result $psResults $psRun
    Assert 'P5 both installers write the same events, with the same messages, for the steps both run (identical stream contract)' ($psOut.ExitCode -eq 0 -and $psEvents.Count -and (& $shape $psEvents) -eq (& $shape $first)) "pwsh: $((& $shape $psEvents) -replace "`n", ' ; ') || bash: $((& $shape $first) -replace "`n", ' ; ')"
    $texts = @(@($progress1, $progress2, $progressFail, $progressBind) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [IO.File]::ReadAllText($_) })
    Assert 'P5 bash no secret reaches the progress stream (no token az returned)' ($texts.Count -ge 3 -and -not @($texts | Where-Object { $_ -match 'eyJ[A-Za-z0-9_-]{4,}\.|(?i)password|accesstoken' }).Count) "$($texts.Count) streams"
    $unexpected = @(foreach ($r in @($r1.Values) + @($r2.Values)) { @($r.Unexpected) })
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @(@($r1.Values) + @($r2.Values) | Where-Object { $_.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { foreach ($d in $scratch, $psScratch) { if ($d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } } }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
