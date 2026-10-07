# Run offline checks in isolated pwsh processes, with ordered output.
# -Serial retains registration-order, one-at-a-time execution.
# -IncludeAzure adds live checks, always last and exclusive (they share a gateway).
# TEST_ALL_THROTTLE overrides the CPU-derived default; -ThrottleLimit wins over it.
param(
    [switch]$IncludeAzure,
    [switch]$Serial,
    [ValidateRange(1, 16)][int]$ThrottleLimit,
    [ValidateRange(1, 3600)][int]$CheckTimeoutSeconds = 600,
    [ValidateRange(0, 63)][int]$ShardIndex = 0,
    [ValidateRange(1, 64)][int]$ShardCount = 1,
    [switch]$LocalOnly,
    [string]$ReceiptPath
)

$ErrorActionPreference = 'Stop'
$sharded = $PSBoundParameters.ContainsKey('ShardIndex') -or $PSBoundParameters.ContainsKey('ShardCount')
if ($PSBoundParameters.ContainsKey('ShardIndex') -xor $PSBoundParameters.ContainsKey('ShardCount')) {
    throw 'ShardIndex and ShardCount must be supplied together.'
}
if ($sharded -and $ShardIndex -ge $ShardCount) { throw 'ShardIndex must be less than ShardCount (zero-based).' }
if ($LocalOnly -and $sharded) { throw 'LocalOnly cannot be combined with shard coordinates.' }
if (($sharded -or $LocalOnly) -and $IncludeAzure) { throw 'Sharded evidence covers the default offline suite, not IncludeAzure.' }
if ($ReceiptPath -and -not ($sharded -or $LocalOnly)) { throw 'ReceiptPath requires shard coordinates or LocalOnly.' }
if (-not $PSBoundParameters.ContainsKey('ThrottleLimit')) {
    $ThrottleLimit = [math]::Max(1, [math]::Min(4, [Environment]::ProcessorCount))
    if ($env:TEST_ALL_THROTTLE) {
        $configured = 0
        if (-not [int]::TryParse($env:TEST_ALL_THROTTLE, [ref]$configured) -or $configured -lt 1 -or $configured -gt 16) {
            throw 'TEST_ALL_THROTTLE must be an integer from 1 to 16.'
        }
        $ThrottleLimit = $configured
    }
}
if ($Serial) { $ThrottleLimit = 1 }
$root = Split-Path $PSScriptRoot -Parent
$scriptsDir = Join-Path $root 'scripts'
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$checks = [Collections.Generic.List[object]]::new()
$active = [Collections.Generic.List[object]]::new()
$results = @()
$runDirectory = Join-Path ([IO.Path]::GetTempPath()) ('test-all-' + [guid]::NewGuid().ToString('N'))
$suiteClock = [Diagnostics.Stopwatch]::StartNew()
$startedAt = [datetime]::UtcNow.ToString('o')
$configuration = $null
$identity = $null
$selectedIndex = $ShardIndex
if ($sharded -or $LocalOnly) {
    . (Join-Path $PSScriptRoot 'TestAll-Sharding.ps1')
    $identity = Get-TestAllIdentity -Root $root -RequireClean
    $configuration = if ($sharded) { Get-TestAllConfiguration -ShardCount $ShardCount } else { Get-TestAllConfiguration }
    if ($LocalOnly) { $selectedIndex = -1; $ShardCount = $configuration.ShardCount }
    if (-not $ReceiptPath) {
        $ReceiptPath = Join-Path ([IO.Path]::GetTempPath()) ("test-all-shard-$selectedIndex-of-$ShardCount-" + [guid]::NewGuid().ToString('N') + '.json')
    }
}

function Invoke-Check {
    param(
        [string]$Name, [string]$Script, [hashtable]$Params = @{},
        [switch]$SerialLane, [switch]$Azure, [string]$SkipReason,
        [ValidateRange(0, 3600)][int]$TimeoutSeconds = 0
    )
    $checks.Add([pscustomobject]@{
        Id = $checks.Count; Name = $Name; Script = $Script; Params = $Params
        RegistrationId = $checks.Count
        Lane = $(if ($Azure) { 'Azure' } elseif ($SerialLane) { 'Exclusive' } else { 'Parallel' })
        SkipReason = $SkipReason
        Timeout = $(if ($TimeoutSeconds) { $TimeoutSeconds } else { $CheckTimeoutSeconds })
        Process = $null; Stdout = $null; Stderr = $null; Clock = $null
    })
}

function Set-CheckResult($check, [string]$Status, [string]$Output = '', $ExitCode = $null) {
    $seconds = if ($check.Clock) { [math]::Round($check.Clock.Elapsed.TotalSeconds, 1) } else { 0.0 }
    $result = [pscustomobject]@{
        Id = $check.Id; Name = $check.Name; Script = $check.Script
        RegistrationId = $check.RegistrationId; SkipReason = $(if ($Status -eq 'SKIP') { $check.SkipReason } else { '' })
        Result = $Status; Seconds = $seconds; ExitCode = $ExitCode; Output = $Output
    }
    $script:results[$check.Id] = $result
}

function Stop-CheckProcess($check) {
    if ($check.Process) {
        try {
            if (-not $check.Process.HasExited) {
                # The wizard, Node and pytest launch descendants of their own.
                $check.Process.Kill($true)
                if (-not $check.Process.WaitForExit(5000)) { throw 'The check process did not stop.' }
            }
            foreach ($read in @($check.Stdout, $check.Stderr)) {
                if ($read) { [void]$read.Wait(1000) }
            }
        }
        finally { $check.Process.Dispose(); $check.Process = $null }
    }
}

function Set-CheckFailure($check, [string]$Message) {
    # Killing the process closes its pipes. Collect after that, or a timed-out
    # check loses all the diagnostic output it printed before hanging.
    try { Stop-CheckProcess $check } catch { $Message += " Cleanup: $($_.Exception.Message)" }
    $output = ''
    if ($check.Stdout -and $check.Stdout.IsCompletedSuccessfully) { $output += $check.Stdout.Result }
    if ($check.Stderr -and $check.Stderr.IsCompletedSuccessfully) { $output += $check.Stderr.Result }
    Set-CheckResult $check 'FAIL' ($output + "`n  FAIL - $Message")
}

function Start-Check($check) {
    $check.Clock = [Diagnostics.Stopwatch]::StartNew()
    $path = Join-Path $PSScriptRoot $check.Script
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = Join-Path $scriptsDir $check.Script }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Set-CheckFailure $check "$($check.Script) not found"
        return
    }
    if ($check.SkipReason) {
        Set-CheckResult $check 'SKIP' ("  SKIP - " + $check.SkipReason)
        return
    }
    $scratch = Join-Path $runDirectory ([string]$check.Id)
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.WorkingDirectory = $root
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in 'TEMP', 'TMP', 'TMPDIR') { $startInfo.Environment[$key] = $scratch }
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $path)) { $startInfo.ArgumentList.Add($arg) }
    foreach ($key in $check.Params.Keys) {
        $value = $check.Params[$key]
        if ($value -is [bool] -or $value -is [switch]) {
            $startInfo.ArgumentList.Add(('-{0}:${1}' -f $key, ([bool]$value).ToString().ToLowerInvariant()))
        }
        else {
            $startInfo.ArgumentList.Add("-$key")
            $startInfo.ArgumentList.Add([string]$value)
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $check.Process = $process
    [void]$process.Start()
    $process.StandardInput.Close()
    # Drain BOTH pipes immediately. Reading one synchronously deadlocks once
    # the other fills (especially a verbose mutation or exception).
    $check.Stdout = $process.StandardOutput.ReadToEndAsync()
    $check.Stderr = $process.StandardError.ReadToEndAsync()
    $active.Add($check)
}

function Receive-Check($check) {
    if ($check.Process.HasExited -and $check.Stdout.IsCompleted -and $check.Stderr.IsCompleted) {
        $code = $check.Process.ExitCode
        $output = $check.Stdout.GetAwaiter().GetResult() + $check.Stderr.GetAwaiter().GetResult()
        if ($code -ne 0) { $output += "`n  FAIL - process exited $code" }
        Set-CheckResult $check $(if ($code -eq 0) { 'PASS' } else { 'FAIL' }) $output $code
        Stop-CheckProcess $check
    }
    elseif ($check.Clock.Elapsed.TotalSeconds -ge $check.Timeout) {
        Set-CheckFailure $check "timed out after $($check.Timeout) s"
    }
}

$nextOutput = 0
function Write-CompletedOutput {
    while ($script:nextOutput -lt $results.Count -and $null -ne $results[$script:nextOutput]) {
        $r = $results[$script:nextOutput]
        Write-Host ''
        Write-Host ('=' * 72) -ForegroundColor DarkGray
        Write-Host " $($r.Name)" -ForegroundColor Cyan
        Write-Host ('=' * 72) -ForegroundColor DarkGray
        if ($r.Output) { Write-Host $r.Output.TrimEnd() }
        $script:nextOutput++
    }
}

$completed = $false
try {
    $azureConfig = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
    $compilerName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
    $bicepNeedsAz = -not (Test-Path -LiteralPath (Join-Path (Join-Path $azureConfig 'bin') $compilerName))
    # BEGIN CHECK REGISTRATION
    # Recursive source scans and native Azure CLI users run before sandboxes.
    Invoke-Check 'Script encoding (PowerShell 5.1 safety)' 'Repair-ScriptEncoding.ps1' @{ Check = $true } -SerialLane
    Invoke-Check 'Test-All counts every check'             'Test-RunnerIntegrity.ps1'
    Invoke-Check 'Test-All shards and receipt coverage'    'Test-TestAllSharding.ps1'
    Invoke-Check 'Remote Test-All exact-source contract'   'Test-RemoteTestAll.ps1'
    Invoke-Check 'Mutation shards preserve every case'     'Test-MutationShards.ps1'
    Invoke-Check 'Format strings parse and run'            'Test-FormatStrings.ps1'
    Invoke-Check 'Screenshots and the docs that show them' 'Test-Screenshots.ps1'
    Invoke-Check 'Architecture sources, images and code agree' 'Test-Architecture.ps1'
    Invoke-Check 'Documentation links and commands'        'Test-DocReferences.ps1'
    Invoke-Check 'Markdown commands and tables'            'Test-DocMarkdown.ps1'
    Invoke-Check 'Azure CLI setup guide mirrors scripts [0/4]' 'Test-AzCommandsGuide.ps1' @{ Shard = '0/4' }
    Invoke-Check 'Azure CLI setup guide mirrors scripts [1/4]' 'Test-AzCommandsGuide.ps1' @{ Shard = '1/4' }
    Invoke-Check 'Azure CLI setup guide mirrors scripts [2/4]' 'Test-AzCommandsGuide.ps1' @{ Shard = '2/4' }
    Invoke-Check 'Azure CLI setup guide mirrors scripts [3/4]' 'Test-AzCommandsGuide.ps1' @{ Shard = '3/4' }
    Invoke-Check 'Azure CLI setup guide portal path'       'Test-AzPortalGuide.ps1'
Invoke-Check 'Azure CLI guide renewal block runs in order' 'Test-AzCommandsRenewal.ps1'
    Invoke-Check 'Portal capture specs and batch safety'   'Test-PortalCaptureSpecs.ps1'
    Invoke-Check 'Resolver - the entitlement read path'   'Test-Resolver.ps1'
    Invoke-Check 'Named value writes fail loudly'          'Test-NamedValueWrites.ps1' @{ SkipLive = $true }
    Invoke-Check 'Release log hygiene'                     'Test-ReleaseLog.ps1'
    Invoke-Check 'Azure CLI arguments vs cmd.exe'          'Test-AzArguments.ps1' -SerialLane
    Invoke-Check 'Shell scripts - syntax and banner'       'Test-ShellScripts.ps1' -SerialLane
    # Stub az, curl and pwsh in TEMP: nothing shared, so it runs in parallel. It needs bash (Git
    # Bash on Windows) with jq on its PATH, as the installer does, and fails without them.
    $installerBash = if ($IsWindows -or $env:OS -eq 'Windows_NT') { @(@('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', (Join-Path "$env:LOCALAPPDATA" 'Programs\Git\bin\bash.exe')) | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1 } else { (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    $bashInstallerSkip = if (-not $installerBash) { 'macOS/Linux installer: no Git Bash (Windows) or bash on this machine.' } elseif (-not (& $installerBash -c 'command -v jq' 2>$null)) { 'macOS/Linux installer: jq is not on the bash PATH; the installer needs it.' } else { '' }
    Invoke-Check 'macOS/Linux installer prices and record'  'Test-BashInstaller.ps1' -SkipReason $bashInstallerSkip
    Invoke-Check 'Preflight on both PowerShell hosts'      'Test-PreflightBothHosts.ps1' -SerialLane
    Invoke-Check 'Guided diagnostics and support bundles'  'Test-Diagnose.ps1' -SerialLane
    Invoke-Check 'Wizard reaches summary on PS 5.1'        'Test-On-PS51.ps1' -SerialLane
    Invoke-Check 'Analytics query contract'                'Test-Analytics.ps1' @{ SkipLive = $true }
    Invoke-Check 'Content Safety request screening'        'Test-ContentSafetyPolicy.ps1'
    Invoke-Check 'Content Safety deployment wiring'        'Test-ContentSafetyDeployment.ps1'
    Invoke-Check 'Content Safety live-script contract'     'Test-ContentSafetyLiveScript.ps1'
    Invoke-Check 'Set gateway policy drift repair'         'Test-SetGatewayPolicy.ps1'
    Invoke-Check 'Content Safety negative detectors'       'Test-ContentSafetyNegative.ps1' -SerialLane
    Invoke-Check 'Org spend ceiling'                       'Test-OrgCeiling.ps1' @{ SkipLive = $true }
    Invoke-Check 'Per-user budget control'                 'Test-BudgetControl.ps1' @{ SkipLive = $true }
    Invoke-Check 'Capability scoping per tier'             'Test-CapabilityScoping.ps1' @{ SkipLive = $true }
    Invoke-Check 'Compliance retrieval and deletion'       'Test-Compliance.ps1' @{ SkipLive = $true }
    Invoke-Check 'Chargeback ledger'                       'Test-Ledger.ps1' @{ SkipLive = $true }
    Invoke-Check 'Chargeback report generation'            'Test-ChargebackReports.ps1'
    Invoke-Check 'Chargeback recipients and attachments'   'Test-ChargebackDelivery.ps1'
    Invoke-Check 'Chargeback durable email outbox'         'Test-ChargebackOutbox.ps1'
    Invoke-Check 'Chargeback queue preserves attachments'  'Test-ChargebackQueue.ps1'
    Invoke-Check 'Chargeback configuration and archive'    'Test-ChargebackStorage.ps1'
    Invoke-Check 'Chargeback private administration'       'Test-ChargebackAdministration.ps1'
    Invoke-Check 'Chargeback selectable discovery'         'Test-ChargebackDiscovery.ps1'
    Invoke-Check 'Chargeback portal redaction'             'Test-ChargebackCapture.ps1'
    Invoke-Check 'Chargeback scheduled jobs'               'Test-ChargebackSchedule.ps1'
    Invoke-Check 'Chargeback mutations detect breakage'    'Test-ChargebackNegative.ps1'
    Invoke-Check 'Business unit chargeback'                'Test-BusinessUnits.ps1'
    Invoke-Check 'Teams and the budget cascade'            'Test-Teams.ps1'
    Invoke-Check 'Model discovery and deployment'          'Test-ModelDeployment.ps1'
    Invoke-Check 'Model lifecycle and tier client handover' 'Test-ModelLifecycle.ps1'
    Invoke-Check 'Client attribution and the workbook'     'Test-Observability.ps1'
    Invoke-Check 'Scripts ask for what they were not given' 'Test-ClaudeChoice.ps1'
    Invoke-Check 'USD budget scripts and gateway contracts' 'Test-UsdBudgets.ps1'
    Invoke-Check 'USD policy expression behavior' 'Test-UsdPolicy.ps1'
    Invoke-Check 'USD scheduled reconciler job' 'Test-UsdReconcilerSchedule.ps1'
    # Shard 0 also carries the mutation that runs the PS 5.1 wizard (Test-On-PS51.ps1), about
    # 100 s alone and up to 300 s on a loaded machine; measured 520 s against the others' ~220 s.
    Invoke-Check 'Business unit checks detect breakage [0/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '0/4' } -TimeoutSeconds 900
    Invoke-Check 'Business unit checks detect breakage [1/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '1/4' } -TimeoutSeconds 900
    Invoke-Check 'Business unit checks detect breakage [2/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '2/4' } -TimeoutSeconds 900
    Invoke-Check 'Business unit checks detect breakage [3/4]' 'Test-BusinessUnitsNegative.ps1' @{ Shard = '3/4' } -TimeoutSeconds 900
    Invoke-Check 'Admin surface - SKU, groups, tiers'      'Test-AdminSurface.ps1'
    Invoke-Check 'Set scripts respect governance authority' 'Test-GovernanceAuthority.ps1'
    Invoke-Check 'Scale ceilings and the load envelope'    'Test-Scale.ps1'
    Invoke-Check 'Secure projection and the migration'     'Test-SecureProjection.ps1' -SerialLane
    Invoke-Check 'Enterprise network edge contract'         'Test-NetworkEdge.ps1' -SerialLane
    Invoke-Check 'Network ARM transport and ownership'       'Test-NetworkTransport.ps1'
    Invoke-Check 'Company address plan, apply and publication' 'Test-CompanyAddress.ps1' -SerialLane
    Invoke-Check 'Company certificate and TLS boundaries'    'Test-CompanyCertificate.ps1'
    Invoke-Check 'Company address guided-flow integration'   'Test-CompanyFlow.ps1'
    Invoke-Check 'Company address detectors reject mutations' 'Test-CompanyAddressNegative.ps1' -SerialLane -TimeoutSeconds 900
    Invoke-Check 'Company mutation runner retains isolation' 'Test-CompanyMutationRunner.ps1'
    Invoke-Check 'Flow proposals remain separate from applied decisions' 'Test-FlowAppliedState.ps1'
    Invoke-Check 'Company installer executes approval boundaries' 'Test-CompanyInstaller.ps1'
    Invoke-Check 'Address checks enforce their remaining deadline' 'Test-AddressDeadline.ps1' -SerialLane
    Invoke-Check 'Network access impact and uncertainty'     'Test-NetworkImpact.ps1'
    Invoke-Check 'Network decisions and cost deltas'         'Test-NetworkDecisions.ps1'
    Invoke-Check 'Network explicit change approval'          'Test-NetworkApproval.ps1'
    Invoke-Check 'Network review checks detect breakage'     'Test-NetworkReviewNegative.ps1'
    Invoke-Check 'Network prices are discovered, not guessed' 'Test-NetworkCost.ps1'
    Invoke-Check 'Network edge checks detect breakage'       'Test-NetworkEdgeNegative.ps1'
    Invoke-Check 'Projection checks detect breakage'        'Test-ProjectionNegative.ps1'
    Invoke-Check 'Projection preflight and safe switch'     'Test-ProjectionPreflight.ps1'
    Invoke-Check 'Update flow moves named values to the projection' 'Test-UpdateEntitlementMigration.ps1'
    Invoke-Check 'Projection readiness checks before a migration' 'Test-ProjectionReadiness.ps1'
    Invoke-Check 'Projection resource inventory matches the templates' 'Test-ProjectionInventory.ps1'
    Invoke-Check 'Projection council corrections'           'Test-ProjectionCouncil.ps1'
Invoke-Check 'Projection runner lifecycle' 'Test-ProjectionRunnerLifecycle.ps1'
Invoke-Check 'Projection runner transfer, compressed and parallel' 'Test-RunnerTransfer.ps1'
Invoke-Check 'Projection sync scripts' 'Test-ProjectionSyncScripts.ps1'
Invoke-Check 'Projection sync package and its import closure' 'Test-ProjectionPackage.ps1'
Invoke-Check 'Projection renewal templates and deploy script' 'Test-ProjectionRenewal.ps1'
Invoke-Check 'Projection renewal runs reach admission offline' 'Test-ProjectionRenewalRuns.ps1'
Invoke-Check 'Projection switch evidence and switch function' 'Test-ProjectionSwitchEvidence.ps1'
# Exclusive: it counts the switch backups that a run adds to the repository's onboarding folder, which
# the council suite's deployer flip also writes into.
Invoke-Check 'Projection deployer and installer switch wiring' 'Test-ProjectionDeployerInstallerWiring.ps1' -SerialLane
Invoke-Check 'Projection deployer compare before any switch' 'Test-ProjectionDeployerCompare.ps1'
Invoke-Check 'Projection guided flow switch wiring' 'Test-ProjectionFlowSwitch.ps1'
Invoke-Check 'Projection installer contract' 'Test-ProjectionInstaller.ps1'
Invoke-Check 'Installer projection defaults and live verifier' 'Test-ClaudeInstallProjection.ps1'
Invoke-Check 'Live projection verifier validation and order' 'Test-ClaudeLiveProjection.ps1'
    Invoke-Check 'Claude Desktop sign-in choice'             'Test-DesktopSignIn.ps1'
    Invoke-Check 'Workstation clients read what setup writes' 'Test-WorkstationClients.ps1' -SerialLane
    Invoke-Check 'Workstation model retirement agrees across shells' 'Test-WorkstationModels.ps1'
    Invoke-Check 'Adding models, and plugin governance'    'Test-ModelsAndPlugins.ps1'
    Invoke-Check 'Backup and restore'                      'Test-Backup.ps1'
    Invoke-Check 'Turnstile - usage mapping and its rules' 'Test-Turnstile.ps1'
    Invoke-Check 'Turnstile - governance and connection'   'Test-TurnstileGovernance.ps1' -SerialLane:$bicepNeedsAz
    Invoke-Check 'Turnstile checks detect breakage [0/2]'   'Test-TurnstileNegative.ps1' @{ Shard = '0/2' } -SerialLane:$bicepNeedsAz
    Invoke-Check 'Turnstile checks detect breakage [1/2]'   'Test-TurnstileNegative.ps1' @{ Shard = '1/2' } -SerialLane:$bicepNeedsAz
    Invoke-Check 'No deployment written into the code'     'Test-NoDeploymentValues.ps1'
    Invoke-Check 'Foundry bypass audit'                    'Test-Bypass.ps1' @{ SkipLive = $true }
    Invoke-Check 'AUM service - discovery and administrator choices' 'Test-AumDeployment.ps1' -SerialLane

    $aumPython = Join-Path $root '.venv-aum-service\Scripts\python.exe'
    $aumUnixPython = Join-Path $root '.venv-aum-service\bin\python'
    $aumSkip = if (-not ((Test-Path $aumPython) -or (Test-Path $aumUnixPython))) {
        'AUM service: worktree .venv-aum-service is missing. See docs/AUM-SERVICE.md.'
    } else { '' }
    Invoke-Check 'AUM service - authority, API and mutations' 'Test-AumService.ps1' -SkipReason $aumSkip

    $finopsPython = Join-Path $root '.venv-finops\Scripts\python.exe'
    $finopsUnixPython = Join-Path $root '.venv-finops\bin\python'
    $finopsSkip = if (-not ((Test-Path $finopsPython) -or (Test-Path $finopsUnixPython))) {
        'AUM: Python or the worktree .venv-finops is missing. See docs/AUM.md to install.'
    } else { '' }
    # cli/finops/tests took 860 s serially on 2026-09-29, beyond the 600 s per-check timeout, so four
    # checks each run a longest-first share of the files (tests/Select-FinOpsShard.ps1).
    Invoke-Check 'AUM - commands, dashboard and pilot [0/4]' 'Test-FinOps.ps1' @{ Shard = '0/4' } -SkipReason $finopsSkip
    Invoke-Check 'AUM - commands, dashboard and pilot [1/4]' 'Test-FinOps.ps1' @{ Shard = '1/4' } -SkipReason $finopsSkip
    Invoke-Check 'AUM - commands, dashboard and pilot [2/4]' 'Test-FinOps.ps1' @{ Shard = '2/4' } -SkipReason $finopsSkip
    Invoke-Check 'AUM - commands, dashboard and pilot [3/4]' 'Test-FinOps.ps1' @{ Shard = '3/4' } -SkipReason $finopsSkip
    Invoke-Check 'AUM shards run every test file once'       'Test-FinOpsShards.ps1'
    Invoke-Check 'AUM install script'                        'Test-InstallAum.ps1'
    Invoke-Check 'Guided flow contract'                      'Test-FlowContract.ps1'
    Invoke-Check 'Guided flow FinOps modules'                'Test-FlowFinOps.ps1'
    Invoke-Check 'Guided flow FinOps step runs what it plans' 'Test-FlowFinOpsApply.ps1'
    Invoke-Check 'Relative decision record paths follow the current folder' 'Test-RelativeRecordPath.ps1'
    Invoke-Check 'Guided lifecycle update and change flow'    'Test-FlowLifecycle.ps1'
    Invoke-Check 'Guided flow orchestrator'                  'Test-GuidedFlow.ps1'
    Invoke-Check 'Guided flow start and installer prices'    'Test-FlowStart.ps1' -SerialLane
    Invoke-Check 'Guided flow across permutations'           'Test-FlowPermutations.ps1' -SerialLane
    Invoke-Check 'Guided flow plans in one order on both shells' 'Test-FlowOrdinalOrder.ps1' -SerialLane
    Invoke-Check 'Installer summary across permutations'     'Test-InstallerPermutations.ps1'
Invoke-Check 'Tier groups follow their gateway'          'Test-TierGroupTarget.ps1'

    if ($IncludeAzure) {
        Invoke-Check 'Foundry discovery is selective'      'Test-Discovery.ps1' -Azure
        Invoke-Check 'Wizard reuses an existing gateway'   'Test-ApimReuse.ps1' -Azure
        Invoke-Check 'Analytics query against live data'   'Test-Analytics.ps1' -Azure
        Invoke-Check 'Org ceiling on the live gateway'     'Test-OrgCeilingLive.ps1' -Azure
        Invoke-Check 'Budget control on the live gateway'  'Test-BudgetControlLive.ps1' -Azure
        Invoke-Check 'Model allowlist on the live gateway' 'Test-CapabilityScopingLive.ps1' -Azure
        Invoke-Check 'Named value writes against Azure'    'Test-NamedValueWrites.ps1' -Azure
    }
    # END CHECK REGISTRATION

    if ($configuration) {
        if (-not (Test-TestAllNamesEqual @($checks.Name) @($configuration.Registration.Name))) {
            throw 'Executed registration differs from its read-only inventory.'
        }
        $ownedIds = [Collections.Generic.HashSet[int]]::new()
        foreach ($planned in $configuration.Plan) {
            if ($planned.ShardIndex -eq $selectedIndex) { [void]$ownedIds.Add($planned.Id) }
        }
        $registeredChecks = $checks.ToArray()
        $checks = [Collections.Generic.List[object]]::new()
        foreach ($check in $registeredChecks) {
            if ($ownedIds.Contains($check.RegistrationId)) { $check.Id = $checks.Count; $checks.Add($check) }
        }
        if (-not $checks.Count) { throw 'The selected shard/local lane owns no checks.' }
        Write-Host "Shard $selectedIndex/$ShardCount owns $($checks.Count) of $($configuration.Registration.Count) registered checks."
    }
    $results = [object[]]::new($checks.Count)
    # The first phase avoids source-scan/sandbox and Azure CLI config races.
    # Azure's mutable deployment is never part of the parallel phase.
    $schedule = if ($Serial) { @($checks.ToArray()) } else {
        @($checks | Where-Object Lane -eq 'Exclusive') +
        @($checks | Where-Object Lane -eq 'Parallel') +
        @($checks | Where-Object Lane -eq 'Azure')
    }
    Write-Host ("Running {0} checks; throttle {1}; per-check timeout {2} s{3}." -f $checks.Count, $ThrottleLimit, $CheckTimeoutSeconds, $(if ($Serial) { '; serial' } else { '' }))
    $next = 0
    while ($next -lt $schedule.Count -or $active.Count) {
        foreach ($check in @($active.ToArray())) {
            try { Receive-Check $check }
            catch { Set-CheckFailure $check $_.Exception.Message } # per-check failure
            if ($null -ne $results[$check.Id] -or -not $check.Process) { [void]$active.Remove($check) }
        }
        while ($next -lt $schedule.Count -and $active.Count -lt $ThrottleLimit) {
            $check = $schedule[$next]
            if ($active.Count -and ($check.Lane -ne 'Parallel' -or @($active | Where-Object Lane -ne 'Parallel').Count)) { break }
            $next++
            try { Start-Check $check }
            catch { Set-CheckFailure $check $_.Exception.Message } # per-check failure
            if ($check.Lane -ne 'Parallel' -and $check.Process) { break }
        }
        Write-CompletedOutput
        if ($active.Count) { Start-Sleep -Milliseconds 50 }
    }
    $valid = @($checks | Where-Object {
        $r = $results[$_.Id]
        $null -ne $r -and $r.Id -eq $_.Id -and $r.Name -ceq $_.Name -and $r.Result -in 'PASS', 'FAIL', 'SKIP'
    })
    $completed = $checks.Count -gt 0 -and $valid.Count -eq $checks.Count
}
catch { Write-Host "Runner stopped: $($_.Exception.Message)" -ForegroundColor Red }
finally {
    foreach ($check in @($active.ToArray())) {
        try { Stop-CheckProcess $check } catch { Write-Warning $_.Exception.Message }
    }
    Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkGray
Write-Host ' Summary' -ForegroundColor Cyan
Write-Host ('=' * 72) -ForegroundColor DarkGray
$reported = @($results | Where-Object { $null -ne $_ })
foreach ($r in $reported) {
    $colour = switch ($r.Result) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ("  {0,-4}  {1}  ({2} s)" -f $r.Result, $r.Name, $r.Seconds) -ForegroundColor $colour
}
Write-Host ''
Write-Host ("  {0:N1} s wall; {1:N1} s in checks; slowest:" -f $suiteClock.Elapsed.TotalSeconds, ($reported | Measure-Object -Property Seconds -Sum).Sum) -ForegroundColor DarkGray
$reported | Sort-Object Seconds -Descending | Select-Object -First 5 | ForEach-Object { Write-Host ("    {0,7:N1} s  {1}" -f $_.Seconds, $_.Name) -ForegroundColor DarkGray }
$timings = Join-Path ([IO.Path]::GetTempPath()) ('test-all-timings-{0}-{1}-{2}.json' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss'), $PID, [guid]::NewGuid().ToString('N'))
ConvertTo-Json -InputObject @($reported | Select-Object Name, Result, Seconds, ExitCode) | Set-Content -LiteralPath $timings -Encoding ASCII
Write-Host "  timings: $timings" -ForegroundColor DarkGray
if (-not $IncludeAzure) { Write-Host '  Azure checks not run. Add -IncludeAzure once you are signed in.' -ForegroundColor DarkGray }

if ($configuration) {
    try {
        $after = Get-TestAllIdentity -Root $root -RequireClean
        if ($after.Commit -cne $identity.Commit -or $after.Tree -cne $identity.Tree) { throw 'Source changed during the shard run.' }
    }
    catch { $completed = $false; Write-Host "Receipt source check failed: $($_.Exception.Message)" -ForegroundColor Red }
    [ordered]@{
        SchemaVersion = 1; Mode = $(if ($LocalOnly) { 'local' } else { 'ci' })
        Commit = $identity.Commit; Tree = $identity.Tree; ShardIndex = $selectedIndex; ShardCount = $ShardCount
        RunId = [string]$env:GITHUB_RUN_ID; RunAttempt = $(if ($env:GITHUB_RUN_ATTEMPT) { [int]$env:GITHUB_RUN_ATTEMPT } else { 0 })
        Completed = [bool]$completed; OwnedChecks = @($checks.Name)
        StartedAt = $startedAt; FinishedAt = [datetime]::UtcNow.ToString('o'); Seconds = [math]::Round($suiteClock.Elapsed.TotalSeconds, 1)
        Results = @($reported | Select-Object RegistrationId, Name, Script, Result, Seconds, ExitCode, SkipReason)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
    Write-Host "  receipt: $ReceiptPath" -ForegroundColor DarkGray
}

Write-Host ''
if (-not $completed) { Write-Host 'The run stopped before every check ran, so it proves nothing.' -ForegroundColor Red; exit 1 }
$skippedCount = @($reported | Where-Object Result -eq 'SKIP').Count
if ($skippedCount) { Write-Host "$skippedCount check(s) skipped - the summary names them, and each said why." -ForegroundColor Yellow }
$failed = @($reported | Where-Object Result -eq 'FAIL').Count
if ($failed) { Write-Host "$failed check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
