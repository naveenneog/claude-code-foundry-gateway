# Steps, step selection and the progress stream of Install-ClaudeGateway.ps1 (docs/adr/0047-lean-installer-phase-0.md).
# Dot-sourced by scripts/ClaudeInstallCheckpoint.ps1. -ListSteps reads the install checkpoint only;
# -Steps runs the named steps after each prerequisite is completed in the checkpoint and verified live
# (P91 R1); -ProgressPath appends one JSON event per line, the events scripts/install-steps.sh writes.
# Runs on Windows PowerShell 5.1 and PowerShell 7.

# A step's prerequisites: the steps whose result it uses. Both installers list the same pairs.
$script:ClaudeInstallStepDependencies = [ordered]@{
    'claude-deployment' = @(); 'resource-group' = @(); 'gateway-deployment' = @('resource-group'); 'company-address' = @('gateway-deployment')
    'entra-groups' = @(); 'sync' = @('gateway-deployment', 'entra-groups'); 'projection' = @('gateway-deployment'); 'business-units' = @('gateway-deployment')
    'onboarding-package' = @('gateway-deployment'); 'verify' = @('gateway-deployment')
}
$script:ClaudeInstallSelection = @()
$script:ClaudeInstallRunId = [guid]::NewGuid().ToString('N')
$script:ClaudeInstallProgressPath = ''
$script:ClaudeInstallProgressSeen = @{}
$script:ClaudeInstallCurrentStep = ''

function Initialize-ClaudeInstallProgress {
    # The progress file is appended to, never replaced; a file that cannot be written refuses at startup.
    param([string]$Path)
    if (-not $Path) { return }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    try { [IO.File]::AppendAllText($full, '', (New-Object Text.UTF8Encoding($false))) }
    catch { Stop-ClaudeInstall "-ProgressPath $Path cannot be written ($($_.Exception.Message)). Nothing was changed. Give a writable file path, or run without -ProgressPath." }
    $script:ClaudeInstallProgressPath = $full
}

function Write-ClaudeInstallProgress {
    # One event, one line of JSON (NDJSON), appended in one write. Each secret shape in its message or resume
    # command is replaced by [redacted] (Protect-ClaudeInstallText, ADR-0047 decision 12).
    param([string]$StepId, [string]$Event, [string]$Message, [string]$ResumeCommand = '')
    if (-not $script:ClaudeInstallProgressPath) { return }
    $clean = { param([string]$Text) (Protect-ClaudeInstallText ($Text -replace '\s*[\r\n]+\s*', ' ')).Trim() }
    $row = [ordered]@{ schemaVersion = 1; time = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        runId = $script:ClaudeInstallRunId; stepId = $StepId; event = $Event; message = (& $clean $Message); resumeCommand = (& $clean $ResumeCommand) }
    [IO.File]::AppendAllText($script:ClaudeInstallProgressPath, (ConvertTo-Json -InputObject ([pscustomobject]$row) -Compress) + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-ClaudeInstallResumeLine {
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Root) { return '' }
    if ($c.Location -and $c.Location.Persistent) { return (Format-ClaudeInstallResume) }
    return (Format-ClaudeInstallResume -WithAnswers)
}

function Write-ClaudeInstallStepEvent {
    # A step's event with the message both installers write: '<title>: started', 'completed', 'verified
    # live, skipped', 'incomplete' (a warning with the resume command) or 'failed: <reason>'. A step is
    # started once per run, however often its checkpoint state is written.
    param([string]$Id, [ValidateSet('started', 'completed', 'skipped-verified', 'warning', 'failed')][string]$Event, [string]$Reason)
    if ($Event -eq 'started') {
        if ($script:ClaudeInstallProgressSeen[$Id] -eq 'started') { return }
        $script:ClaudeInstallCurrentStep = $Id
    }
    elseif ($script:ClaudeInstallCurrentStep -eq $Id) { $script:ClaudeInstallCurrentStep = '' }
    $script:ClaudeInstallProgressSeen[$Id] = $Event
    $title = $script:ClaudeInstallSteps[$Id]
    $text = switch ($Event) { 'started' { 'started' } 'completed' { 'completed' } 'skipped-verified' { 'verified live, skipped' } 'warning' { 'incomplete' } 'failed' { "failed: $Reason" } }
    Write-ClaudeInstallProgress -StepId $Id -Event $Event -Message "${title}: $text" -ResumeCommand $(if ($Event -in 'warning', 'failed') { Get-ClaudeInstallResumeLine } else { '' })
}

function Write-ClaudeInstallTrapEvent {
    # From the installer's trap: a refusal is 'refused', any other stop 'failed' for the running step.
    param([string]$Message)
    $line = (($Message -replace '\s*[\r\n]+\s*', ' ')).Trim()
    if ($line -like 'Refused: *') { Write-ClaudeInstallProgress -StepId $script:ClaudeInstallCurrentStep -Event 'refused' -Message $line; return }
    if ($script:ClaudeInstallCurrentStep) { Write-ClaudeInstallStepEvent -Id $script:ClaudeInstallCurrentStep -Event 'failed' -Reason $line; return }
    Write-ClaudeInstallProgress -StepId '' -Event 'failed' -Message $line -ResumeCommand (Get-ClaudeInstallResumeLine)
}

function Set-ClaudeInstallSelection {
    # -Steps: each id a step of this installer, refused on one line before anything is read.
    param([string[]]$Steps)
    $ids = @($Steps | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($id in $ids) {
        if (-not $script:ClaudeInstallSteps.Contains($id)) {
            Stop-ClaudeInstall "-Steps '$id' names no step of Install-ClaudeGateway.ps1. Its steps are $(@($script:ClaudeInstallSteps.Keys) -join ', '). Nothing was changed. ./Install-ClaudeGateway.ps1 -ListSteps lists the steps with their state."
        }
    }
    $script:ClaudeInstallSelection = @($ids)
}
function Test-ClaudeInstallStepSelected([string]$Id) { return (-not $script:ClaudeInstallSelection.Count -or $script:ClaudeInstallSelection -contains $Id) }

function Test-ClaudeInstallGroupReceipts($Receipt) {
    # The tier groups the checkpoint records, read live by id and listed under the configured name by
    # the name rule (ADR-0046 decision 11), as a resume reads them.
    $read = { param($n) [string](Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    $names = @{ standard = (& $read 'StandardGroup'); premium = (& $read 'PremiumGroup') }
    foreach ($role in 'standard', 'premium') {
        $rec = @(@(if ($Receipt) { $Receipt.groups }) | Where-Object { $_ -and $_.role -eq $role -and [string]::Equals([string]$_.displayName, $names[$role], [StringComparison]::Ordinal) }) | Select-Object -First 1
        if (-not $rec -or -not $rec.id) { return (Get-ClaudeInstallVerdict 'absent' "the checkpoint records no $role group named '$($names[$role])'") }
        $r = Invoke-ClaudeInstallAzRead @('ad', 'group', 'show', '--group', [string]$rec.id, '--query', 'id', '-o', 'tsv') $script:ClaudeInstallGraphNotFound
        if ($r.Verdict -ne 'present') { return (Get-ClaudeInstallVerdict $r.Verdict "Entra group '$($names[$role])' ($($rec.id)) is not returned by Microsoft Graph ($($r.Detail))") }
        $named = Find-ClaudeInstallGroupByName $names[$role] ([string]$rec.id)
        if ($named.Verdict -ne 'present' -or -not [string]::Equals($named.Id, [string]$rec.id, [StringComparison]::OrdinalIgnoreCase)) {
            return (Get-ClaudeInstallVerdict 'inconclusive' "Entra group '$($names[$role])' ($($rec.id)) is not listed by Microsoft Graph under that name")
        }
    }
    return (Get-ClaudeInstallVerdict 'present' '')
}

function Assert-ClaudeInstallPrerequisites {
    # Before any question and any change: each prerequisite of a selected step is completed in the
    # install checkpoint and verified live, or the run refuses on one line naming it (A11).
    if (-not $script:ClaudeInstallSelection.Count) { return }
    $c = $script:ClaudeInstall
    $read = { param($n) [string](Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    $apim = if ($c.Checkpoint) { [string]$c.Checkpoint.binding.apimName } else { '' }
    $where = if ($c.Checkpoint) { "the install checkpoint $($c.Location.Checkpoint)" } else { 'an install checkpoint' }
    $needed = @($script:ClaudeInstallSelection | ForEach-Object { $script:ClaudeInstallStepDependencies[$_] } | Select-Object -Unique | Where-Object { $_ -and $script:ClaudeInstallSelection -notcontains $_ })
    foreach ($s in $script:ClaudeInstallSelection) {
        $why = @()
        foreach ($dep in @($script:ClaudeInstallStepDependencies[$s] | Where-Object { $needed -contains $_ })) {
            $step = Get-ClaudeInstallStep $dep
            if (-not $step) { $why += "$dep is not in $where"; continue }
            if ($step.state -ne 'completed') { $why += "$dep is $($step.state) in $where"; continue }
            $v = switch ($dep) {
                'resource-group' { Test-ClaudeInstallResourceGroup (& $read 'ResourceGroup') }
                'gateway-deployment' { Test-ClaudeInstallGateway (& $read 'ResourceGroup') $apim $step.receipt }
                'entra-groups' { Test-ClaudeInstallGroupReceipts $step.receipt }
                default { Get-ClaudeInstallVerdict 'present' '' }
            }
            if ($v.Verdict -ne 'present') { $why += "${dep}: $($v.Detail)" }
        }
        if ($why.Count) {
            $deps = @($script:ClaudeInstallStepDependencies[$s]) -join ' and '
            Stop-ClaudeInstall "step $s needs $deps completed and verified live: $($why -join '; '). Nothing was changed. Run the prerequisite first, or run without -Steps to resume every step."
        }
    }
}

function Get-ClaudeInstallStepStates {
    # Each step of this installer with its title, prerequisites and the state the checkpoint records.
    param($Checkpoint, [string[]]$Ids)
    foreach ($id in $Ids) {
        $s = @(@(if ($Checkpoint) { $Checkpoint.steps }) | Where-Object { $_ -and $_.id -eq $id })[0]
        [pscustomobject][ordered]@{ id = $id; title = $script:ClaudeInstallSteps[$id]; dependencies = @($script:ClaudeInstallStepDependencies[$id]); state = $(if ($s) { [string]$s.state } else { 'not-started' }) }
    }
}

function Show-ClaudeInstallStepList {
    # -ListSteps: the steps and the state the install checkpoint records; no Azure call, nothing written.
    param([Parameter(Mandatory = $true)][string]$Root, [switch]$Json)
    $c = New-ClaudeInstallContext -Root $Root
    Assert-ClaudeInstallStore
    $cp = $null
    if (-not $c.Location.NoStore) { $cp = Read-ClaudeInstallCheckpoint -Path $c.Location.Checkpoint -Restart ((Format-ClaudeInstallResume) + ' -Restart') }
    if ($cp -and $cp.installer -ne 'pwsh') { Stop-ClaudeInstall "the install checkpoint $($c.Location.Checkpoint) was written by install-claude-gateway.sh, whose steps differ; list them with that installer. Nothing was changed." }
    $steps = @(Get-ClaudeInstallStepStates -Checkpoint $cp -Ids @($script:ClaudeInstallSteps.Keys))
    if ($Json) {
        return ([pscustomobject][ordered]@{ schemaVersion = 1; installer = 'pwsh'; checkpoint = $(if ($cp) { $c.Location.Checkpoint } else { $null })
                runId = $(if ($cp) { [string]$cp.runId } else { $null }); steps = $steps } | ConvertTo-Json -Depth 6)
    }
    $head = if ($cp) { "Install checkpoint: $($c.Location.Checkpoint), run $($cp.runId)" } elseif ($c.Location.NoStore) { [string]$c.Location.NoStore } else { "No install checkpoint at $($c.Location.Checkpoint)." }
    @($head) + @($steps | ForEach-Object { '{0,-20} {1,-24} {2}' -f $_.id, $_.title, $_.state })
}

function Resolve-ClaudeInstallUnitGroup {
    # A business unit's Entra group by the name rule of ADR-0046 decision 11 (Find-ClaudeInstallGroupByName),
    # for both business-unit paths, the answers file and the installer's prompt (ADR-0047 decision 13):
    # present, reused; absent, created; inconclusive, neither, and the caller refuses the unit. Azure CLI's
    # az ad group show --group falls back to a single group whose name starts with the name, so it is not used.
    param([Parameter(Mandatory = $true)][string]$Group)
    $found = Find-ClaudeInstallGroupByName $Group
    if ($found.Verdict -eq 'present') { return [pscustomobject]@{ Verdict = 'present'; Id = [string]$found.Id; Origin = 'pre-existing'; Detail = '' } }
    if ($found.Verdict -ne 'absent') { return [pscustomobject]@{ Verdict = 'inconclusive'; Id = ''; Origin = ''; Detail = [string]$found.Detail } }
    $created = Invoke-ClaudeInstallAzRead @('ad', 'group', 'create', '--display-name', $Group, '--mail-nickname', $Group, '-o', 'json')
    $obj = $null
    if ($created.Verdict -eq 'present') { try { $obj = $created.Output | ConvertFrom-Json -ErrorAction Stop } catch { $obj = $null } }
    if (-not $obj -or -not $obj.id) { return [pscustomobject]@{ Verdict = 'create-failed'; Id = ''; Origin = ''; Detail = [string]$created.Detail } }
    return [pscustomobject]@{ Verdict = 'created'; Id = [string]$obj.id; Origin = 'created'; Detail = '' }
}

function Invoke-ClaudeInstallBusinessUnits {
    # The answers' business units and teams through scripts/Set-ClaudeBusinessUnit.ps1 (ADR-0047): units
    # before teams; each group found by the name rule of ADR-0046 decision 11, or created, before its
    # unit is written; each unit once. A unit whose receipt records this input and which bu-registry shows
    # is not written again, so a rerun after a refused unit makes no duplicate call.
    param([Parameter(Mandatory = $true)][string]$Root, [object[]]$Units, [string]$ResourceGroup, [string]$ApimName)
    $resume = Get-ClaudeInstallResumeLine
    $step = Get-ClaudeInstallStep 'business-units'
    $old = @(if ($step -and $step.receipt) { $step.receipt.units | Where-Object { $_ } })
    $registry = Invoke-ClaudeInstallAzRead @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $ApimName, '--named-value-id', 'bu-registry', '--query', 'value', '-o', 'tsv') @('ResourceNotFound')
    if ($registry.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "bu-registry on $ApimName could not be read ($($registry.Detail)), so no business unit is skipped or written again. Nothing was changed. Resume: $resume" }
    $field = { param($u, [string]$n) [string](Get-ClaudeAnswersField $u $n) }
    $ordered = @(@($Units | Where-Object { -not (& $field $_ 'parent') }) + @($Units | Where-Object { & $field $_ 'parent' }))
    foreach ($u in $ordered) {
        $id = & $field $u 'id'; $group = & $field $u 'group'; $parent = & $field $u 'parent'; $mode = & $field $u 'mode'
        $hash = 'sha256:' + (Get-ClaudeInstallSha256 ([Text.Encoding]::UTF8.GetBytes((ConvertTo-ClaudeFlowCanonical $u))))
        $rec = @($old | Where-Object { [string]$_.id -ceq $id }) | Select-Object -First 1
        if ($rec -and [string]$rec.inputHash -eq $hash -and $registry.Verdict -eq 'present' -and $registry.Output -match (',' + [regex]::Escape($id) + '=')) {
            Write-Host "    [OK]   ${id}: applied by this install run, and in bu-registry" -ForegroundColor Green; continue
        }
        $found = Resolve-ClaudeInstallUnitGroup $group
        if ($found.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "Entra group '$group' of business unit $id could not be looked up by name ($($found.Detail)), so it is neither reused nor created. Nothing was changed by this unit. Resume: $resume" }
        if ($found.Verdict -eq 'create-failed') { Stop-ClaudeInstall "Entra group '$group' of business unit $id could not be created ($($found.Detail)). Nothing was changed by this unit. Resume: $resume" }
        if ($found.Verdict -eq 'created') { Write-Host "    [OK]   $group created" -ForegroundColor Green }
        $groupId = $found.Id; $origin = $found.Origin
        $unit = @{ Id = $id; Group = $group; MonthlyBudgetUsd = [decimal](Get-ClaudeAnswersField $u 'monthlyUsdBudget'); Mode = $mode; SkipGroupCheck = $true; ApimName = $ApimName; ResourceGroup = $ResourceGroup }
        if ($parent) { $unit.Parent = $parent }
        if ($mode -eq 'Allowance') { $unit.AllowancePercent = [int](Get-ClaudeAnswersField $u 'percent') }
        & (Join-Path $Root 'scripts/Set-ClaudeBusinessUnit.ps1') @unit
        Add-ClaudeInstallBusinessUnit -Id $id -GroupId $groupId -GroupOrigin $origin -InputHash $hash
    }
    Complete-ClaudeInstallStep 'business-units'
}

function Write-ClaudeInstallUsdReconcile {
    # A dollar budget is enforced for each usd-budgets item whose scope's mode is not notify; a unit
    # bu-modes does not list is strict (infra/policy.xml:533-570). Its state is then reconciled by
    # scripts/Sync-ClaudeUsdBudgets.ps1, so the command is printed for this gateway.
    param([string]$ResourceGroup, [string]$ApimName)
    $nv = { param([string]$Id) Invoke-ClaudeInstallAzRead @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $ApimName, '--named-value-id', $Id, '--query', 'value', '-o', 'tsv') @('ResourceNotFound') }
    $budgets = & $nv 'usd-budgets'; $modes = & $nv 'bu-modes'
    $command = "./scripts/Sync-ClaudeUsdBudgets.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName"
    if ($budgets.Verdict -ne 'present' -or $modes.Verdict -eq 'inconclusive') { Write-Host "    [WARN] usd-budgets or bu-modes could not be read, so whether dollar budgets are enforced is unknown. To reconcile them: $command" -ForegroundColor Yellow; return }
    $items = @()
    try {
        $doc = ConvertFrom-ClaudeUsdValue ([string]$budgets.Output)
        $map = ConvertFrom-ClaudeBuModes $(if ($modes.Verdict -eq 'present') { [string]$modes.Output } else { '' })
        $scopes = @(if ($doc.items) { $doc.items.PSObject.Properties.Name })
        $items = @($scopes | Where-Object { $_ -like 'user:*' -or [string]$map[($_ -replace '^[a-z]+:', '')] -ne 'notify' })
    }
    catch { Write-Host "    [WARN] usd-budgets or bu-modes could not be read ($(Protect-ClaudeInstallText $_.Exception.Message)). To reconcile dollar budgets: $command" -ForegroundColor Yellow; return }
    if ($items.Count) { Write-Host "    Dollar budgets are enforced for $($items.Count) scope(s); after access sync changes bu-members, reconcile their state: $command" -ForegroundColor Yellow }
}
