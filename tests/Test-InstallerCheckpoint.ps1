# P91: Install-ClaudeGateway.ps1 keeps a checkpoint and a rerun resumes after the last step whose
# result Azure still shows (docs/adr/0046-installer-checkpoint-and-resume.md). Scenarios S1-S10 and
# S12 of the P91 brief, the lead's amendment 1, R2, R6, R9 and ADR-0032. Every run is a child
# PowerShell over the az stub of tests/InstallerCheckpointStubs.ps1; nothing reaches Azure. The bash
# installer's checks (S11) are tests/Test-BashInstallerCheckpoint.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerCheckpointHarness.ps1')
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Installer checkpoint and resume (PowerShell installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p91-checkpoint-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$sleeper = $null

$sub = $script:P91Subscription
$common = @("-SubscriptionId '$sub'", "-FoundryAccount 'ai-p91'", "-FoundryResourceGroup 'rg-ai-p91'", "-EntitlementStore 'named-value'",
    "-AuthMode 'interactive'", "-DesktopSignInKind 'helper-script'", "-AddressMode 'azure'", '-SkipFinOpsOffer')
$newGateway = $common + @("-ResourceGroup 'rg-p91'", "-Location 'eastus2'", "-NamePrefix 'p91gw'", "-PublisherEmail 'ops@contoso.com'", "-Sku 'BasicV2'")
$reused = $common + @("-ResourceGroup 'rg-p91'", "-ExistingApimName 'apim-p91reuse'")
$quiet = @("-StandardModels 'claude-sonnet-5'", "-PremiumModels 'claude-opus-5','claude-sonnet-5'", '-TpmStandard 20000', '-QuotaStandard 500000',
    '-TpmPremium 80000', '-QuotaPremium 5000000', '-QuotaOrg 100000000', '-CallsPerMinute 120')
$secret = "-AddressCertificatePassword (ConvertTo-SecureString 'P91-PFX-SENTINEL' -AsPlainText -Force)"
$premiumId = '00000000-0000-4000-8000-0000000000e2'

$doneAt = '(?m)^\s+done \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z  '
$resumesAt = '(?m)^\s+resumes at: '
function Test-Refusal($Result, [string]$Field) {
    $lines = @(Get-P91ErrLines $Result)
    ($Result.ExitCode -eq 1 -and $lines.Count -eq 1 -and $lines[0] -match '^Refused: ' -and $lines[0] -match $Field -and $lines[0] -match 'Nothing was changed')
}
function Get-Checkpoint($Scenario) {
    $file = Get-P91CheckpointFile $Scenario
    if (-not $file) { return $null }
    try { [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json } catch { $null }
}
function Get-Step($Checkpoint, [string]$Id) { if ($Checkpoint) { @($Checkpoint.steps | Where-Object { $_.id -eq $Id })[0] } }
function Edit-Checkpoint($Scenario, [scriptblock]$Change) {
    $file = Get-P91CheckpointFile $Scenario
    if (-not $file) { return }
    $cp = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
    & $Change $cp
    Write-P91Text $file.FullName ($cp | ConvertTo-Json -Depth 30)
}
function Test-Kept($Scenario, [string]$Hash) { $file = Get-P91CheckpointFile $Scenario; [bool]($file -and $Hash -and (Get-P91Hash $file.FullName) -eq $Hash) }
function Write-Lock($Scenario, [hashtable]$Fields, [int]$AgeMinutes = 0) {
    $path = Join-Path $Scenario.State ((Get-P91Key $Scenario.Repo) + '.lock')
    Write-P91Text $path (($Fields | ConvertTo-Json -Compress))
    if ($AgeMinutes) { [IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddMinutes(-$AgeMinutes)) }
}
function Get-Order($Result, [string]$First, [string]$Then) {
    $a = -1; $b = -1
    for ($i = 0; $i -lt $Result.Az.Count; $i++) { if ($a -lt 0 -and $Result.Az[$i] -like $First) { $a = $i }; if ($Result.Az[$i] -like $Then) { $b = $i } }
    return ($a -ge 0 -and $b -gt $a)
}

try {
    $template = New-P91Template $scratch

    # ------------------------------------------------------------------ wave 1: first runs
    $baseWorld = New-P91World
    $baseWorld.groups[$premiumId] = 'claude-code-premium'
    $baseWorld.inject.sync = 'graph404'
    $base = New-P91Scenario -Name 'base' -Scratch $scratch -Template $template -World $baseWorld
    $identityWorld = New-P91World -ReusedGateway -IdentityType 'None'
    $identityWorld.inject.createMode = 'fail-identity'
    $identity = New-P91Scenario -Name 'identity' -Scratch $scratch -Template $template -World $identityWorld
    $buWorld = New-P91World -ReusedGateway
    $buWorld.inject.bu = 'refuse'
    $bu = New-P91Scenario -Name 'bu' -Scratch $scratch -Template $template -World $buWorld
    $runningWorld = New-P91World
    $runningWorld.inject.createMode = 'disconnect'
    $runningWorld.inject.runningPolls = @('Running', 'Running')
    $running = New-P91Scenario -Name 'running' -Scratch $scratch -Template $template -World $runningWorld
    $foreignWorld = New-P91World
    $foreignWorld.resourceGroups['rg-p91'] = 'eastus2'
    $foreignWorld.deployments['rg-p91'] = [ordered]@{ 'claude-gw-20260101000000' = [ordered]@{ rg = 'rg-p91'; apim = 'apim-p91gw'; grantRole = 'true'; state = 'Running'; polls = @('Running'); error = $null } }
    $foreign = New-P91Scenario -Name 'foreign' -Scratch $scratch -Template $template -World $foreignWorld
    $shellWorld = New-P91World
    $shellWorld.inject.sync = 'graph404'
    $noDrive = New-P91Scenario -Name 'cloudshell-nodrive' -Scratch $scratch -Template $template -World $shellWorld
    $drive = New-P91Scenario -Name 'cloudshell-drive' -Scratch $scratch -Template $template -World $shellWorld
    $homeA = Join-Path $noDrive.Dir 'home'; New-Item -ItemType Directory -Force -Path $homeA | Out-Null
    $homeB = Join-Path $drive.Dir 'home'; New-Item -ItemType Directory -Force -Path (Join-Path $homeB 'clouddrive') | Out-Null
    $shellEnv = @{ AZUREPS_HOST_ENVIRONMENT = 'cloud-shell/1.0'; CLAUDE_GATEWAY_STATE_DIR = $null }
    $whatIf = New-P91Scenario -Name 'whatif' -Scratch $scratch -Template $template -World (New-P91World)
    $cancel = New-P91Scenario -Name 'cancel' -Scratch $scratch -Template $template -World (New-P91World)
    # A group read by name: az ad group list --display-name matches a prefix, so only an exact name is
    # the group; a failed read or two groups with the name create nothing.
    $prefixWorld = New-P91World
    $prefixWorld.groups['00000000-0000-4000-8000-0000000000e7'] = 'claude-code-standard-old'
    $prefixWorld.groups[$premiumId] = 'claude-code-premium'
    $graphPrefix = New-P91Scenario -Name 'graph-prefix' -Scratch $scratch -Template $template -World $prefixWorld
    $readNameWorld = New-P91World
    $readNameWorld.groups[$premiumId] = 'claude-code-premium'
    $denied = 'ERROR: Insufficient privileges to complete the operation. (Authorization_RequestDenied)'
    $readNameWorld.inject.readErrors = @([ordered]@{ match = 'ad group show --group claude-code-standard*'; text = $denied }, [ordered]@{ match = 'ad group list --display-name claude-code-standard*'; text = $denied })
    $graphRead = New-P91Scenario -Name 'graph-read' -Scratch $scratch -Template $template -World $readNameWorld
    $twinsWorld = New-P91World
    $twinsWorld.groups['00000000-0000-4000-8000-0000000000e8'] = 'claude-code-standard'
    $twinsWorld.groups['00000000-0000-4000-8000-0000000000e9'] = 'claude-code-standard'
    $twinsWorld.groups[$premiumId] = 'claude-code-premium'
    $graphTwins = New-P91Scenario -Name 'graph-twins' -Scratch $scratch -Template $template -World $twinsWorld
    $noDir = New-P91Scenario -Name 'nodir' -Scratch $scratch -Template $template -World (New-P91World)
    $blocker = Join-Path $noDir.Dir 'blocker'
    Write-P91Text $blocker 'a file where the state directory would be'

    $first = @(
        ($runBase1 = New-P91Run $base -Arguments ($newGateway + $secret + '-Yes'))
        ($runIdentity1 = New-P91Run $identity -Arguments ($reused + '-Yes'))
        ($runBu1 = New-P91Run $bu -Arguments ($reused + $quiet) -Attended -Answers @('', '', '', '', '', 'y', 'Platform', 'y', 'platform', '', ''))
        ($runRunning1 = New-P91Run $running -Arguments ($newGateway + '-Yes'))
        ($runForeign = New-P91Run $foreign -Arguments ($newGateway + '-Yes'))
        ($runNoDrive = New-P91Run $noDrive -Arguments ($newGateway + '-Yes') -Environment ($shellEnv + @{ HOME = $homeA }))
        ($runDrive = New-P91Run $drive -Arguments ($newGateway + '-Yes') -Environment ($shellEnv + @{ HOME = $homeB }))
        ($runWhatIf = New-P91Run $whatIf -Arguments ($newGateway + '-Yes', '-WhatIf'))
        ($runCancel = New-P91Run $cancel -Arguments ($newGateway + $quiet) -Attended -Answers @('', '', '', '', '', '', 'n'))
        ($runGraphPrefix = New-P91Run $graphPrefix -Arguments ($newGateway + '-Yes'))
        ($runGraphRead = New-P91Run $graphRead -Arguments ($newGateway + '-Yes'))
        ($runGraphTwins = New-P91Run $graphTwins -Arguments ($newGateway + '-Yes'))
        ($runNoDir = New-P91Run $noDir -Arguments ($newGateway + '-Yes') -Environment @{ CLAUDE_GATEWAY_STATE_DIR = (Join-Path $blocker 'state') })
    )
    $r1 = Invoke-P91Runs $first
    $b1 = Get-P91Result $r1 $runBase1
    $baseCheckpoint = Get-Checkpoint $base
    Write-Host '  first runs' -ForegroundColor DarkGray
    Assert 'S1 run 1 stops at the sync with the Graph 404 and leaves a checkpoint named for its checkout' ($b1.ExitCode -ne 0 -and ($b1.Out + $b1.Err) -match 'Graph read failed' -and
        $null -ne $baseCheckpoint -and (Get-P91CheckpointFile $base).BaseName -eq (Get-P91Key $base.Repo)) (Get-P91Tail $b1)
    Assert 'S1 the checkpoint records resource group, gateway and groups as completed and sync as started' (
        (Get-Step $baseCheckpoint 'resource-group').state -eq 'completed' -and (Get-Step $baseCheckpoint 'gateway-deployment').state -eq 'completed' -and
        (Get-Step $baseCheckpoint 'entra-groups').state -eq 'completed' -and (Get-Step $baseCheckpoint 'sync').state -eq 'started')
    $groupReceipt = @((Get-Step $baseCheckpoint 'entra-groups').receipt.groups)
    Assert 'S1 the group receipts hold ids, the created group and the pre-existing one' (
        @($groupReceipt | Where-Object { $_.role -eq 'standard' -and $_.origin -eq 'created' -and $_.id -match '^[0-9a-f-]{36}$' }).Count -eq 1 -and
        @($groupReceipt | Where-Object { $_.role -eq 'premium' -and $_.origin -eq 'pre-existing' -and $_.id -eq $premiumId }).Count -eq 1) ($groupReceipt | ConvertTo-Json -Compress)
    $confirmedFirst = @($b1.Snapshots) -contains 'checkpoint-at-group-create present'
    $w1 = Get-P91Result $r1 $runWhatIf
    $whatIfNone = ($w1.ExitCode -eq 0 -and $w1.Out -match 'WhatIf - stopping' -and -not (Test-Path -LiteralPath $whatIf.State))
    $c1 = Get-P91Result $r1 $runCancel
    $cancelNone = ($c1.Out -match 'Cancelled' -and -not (Get-P91CheckpointFile $cancel) -and -not @(Get-P91Calls $c1 'group create*').Count)
    Assert 'ADR-0032 the first checkpoint write follows the confirmation: before the first change, and none after -WhatIf or a cancelled summary' ($confirmedFirst -and $whatIfNone -and $cancelNone) "confirmed=$confirmedFirst whatif=$whatIfNone cancel=$cancelNone"
    $cpText = if (Get-P91CheckpointFile $base) { [IO.File]::ReadAllText((Get-P91CheckpointFile $base).FullName) } else { '' }
    Assert 'S10 the checkpoint holds no token, password, key or connection string' ($cpText -and $cpText -notmatch 'eyJ[A-Za-z0-9_-]{4,}\.' -and $cpText -notmatch 'P91-PFX-SENTINEL' -and
        $cpText -notmatch '(?i)accountkey=|sharedaccesssignature|-----begin|"password|accesstoken|"secret')
    $allowed = @{
        top = 'schema', 'schemaVersion', 'runId', 'installer', 'installerFingerprint', 'installerCommit', 'checkout', 'createdUtc', 'updatedUtc', 'binding', 'answers', 'steps'
        binding = 'tenantId', 'subscriptionId', 'resourceGroup', 'apimName', 'namePrefix', 'reusedApim'
        step = 'id', 'state', 'startedUtc', 'completedUtc', 'inputHash', 'receipt'
        answers = 'SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku', 'AddressMode', 'AddressHostname',
            'AddressCertificateSource', 'AddressKeyVaultCertificateId', 'AddressPfxPath', 'AddressDnsZoneResourceId', 'AddressDnsMode', 'AddressReplaceHostname', 'ExistingApimName',
            'EntitlementStore', 'ResolverInboundAccess', 'DeployProjection', 'ProjectionReconcilerResourceId', 'ProjectionResolverAppId', 'TpmStandard', 'QuotaStandard', 'TpmPremium',
            'QuotaPremium', 'QuotaOrg', 'CallsPerMinute', 'StandardGroup', 'PremiumGroup', 'StandardModels', 'PremiumModels', 'AuthMode', 'DesktopSignInKind', 'DesktopBearerTokenType',
            'DesktopEntraClientId', 'DesktopEntraIssuer', 'DesktopEntraScopes', 'DesktopEntraAudience', 'DesktopEntraResource', 'ModelOrganizationName', 'ModelIndustry', 'ModelCountryCode',
            'RevocationWindowSeconds', 'TeamBudgetBehaviour', 'UnassignedDevelopers', 'DeveloperEstimate', 'PendingClaudeDeployment'
    }
    $receiptKeys = @{ 'resource-group' = 'name', 'location', 'origin'; 'gateway-deployment' = 'deployments', 'apimName', 'origin', 'gatewayUrl', 'roleAssignmentId', 'roleOrigin', 'desktopClientId'
        'entra-groups' = @('groups'); 'claude-deployment' = 'account', 'resourceGroup', 'name', 'origin'; 'company-address' = @('hostname'); 'projection' = 'resolverAppId', 'resolverOrigin'
        'business-units' = @('units'); 'onboarding-package' = @('path'); 'sync' = @(); 'verify' = @() }
    $extra = @()
    if ($baseCheckpoint) {
        $extra += @($baseCheckpoint.PSObject.Properties.Name | Where-Object { $_ -notin $allowed.top })
        $extra += @($baseCheckpoint.binding.PSObject.Properties.Name | Where-Object { $_ -notin $allowed.binding } | ForEach-Object { "binding.$_" })
        $extra += @($baseCheckpoint.answers.PSObject.Properties.Name | Where-Object { $_ -notin $allowed.answers } | ForEach-Object { "answers.$_" })
        foreach ($st in @($baseCheckpoint.steps)) {
            $extra += @($st.PSObject.Properties.Name | Where-Object { $_ -notin $allowed.step } | ForEach-Object { "step.$_" })
            if ($st.receipt) { $extra += @($st.receipt.PSObject.Properties.Name | Where-Object { $_ -notin @($receiptKeys[[string]$st.id]) } | ForEach-Object { "$($st.id).$_" }) }
        }
    }
    Assert 'S10 every key of the checkpoint is in the schema' ($baseCheckpoint -and -not $extra.Count) ($extra -join ', ')
    if ($env:OS -eq 'Windows_NT') {
        $acl = if (Test-Path -LiteralPath $base.State) { Get-Acl -LiteralPath $base.State } else { $null }
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $rules = if ($acl) { @($acl.Access) } else { @() }
        Assert 'R6 the state directory has a protected ACL with one rule, for the current user' ($acl -and $acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and
            $rules[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $me) "$($rules.Count) rule(s)"
    }
    $nd = Get-P91Result $r1 $runNoDrive
    $ndFile = Get-P91CheckpointFile $noDrive (Join-Path $homeA '.claude-gateway')
    Assert 'S12 Cloud Shell without clouddrive warns that the checkpoint cannot persist' ($nd.Out -match '(?m)\[WARN\].*Cloud Shell.*clouddrive') (Get-P91Tail $nd)
    Assert 'S12 and prints the exact resume command on one line, with the recorded answers' ($nd.Out -match "(?m)^\s*Resume: .*Install-ClaudeGateway\.ps1 .*-ResourceGroup 'rg-p91'.*-NamePrefix 'p91gw'")
    Assert 'S12 the checkpoint is under $HOME/.claude-gateway' ($null -ne $ndFile)
    $dr = Get-P91Result $r1 $runDrive
    Assert 'S12 with clouddrive the checkpoint is under $HOME/clouddrive/.claude-gateway, with no warning' (
        $null -ne (Get-P91CheckpointFile $drive (Join-Path $homeB 'clouddrive\.claude-gateway')) -and $dr.Out -notmatch '(?m)\[WARN\].*clouddrive') (Get-P91Tail $dr)
    Assert 'S12 in Cloud Shell the run prints the 20-minute line before the deployment' ($dr.Out -match '(?m)20 minutes without interactive activity.*Resume: ')
    Assert 'S12 without clouddrive the 20-minute line says the ARM deployment outlives the session and this checkpoint does not, with the answers' (
        $nd.Out -match "(?m)20 minutes without interactive activity; the ARM deployment outlives the session and this install checkpoint does not\. Resume: .*Install-ClaudeGateway\.ps1 .*-ResourceGroup 'rg-p91'") (Get-P91Tail $nd)
    $gp = Get-P91Result $r1 $runGraphPrefix
    Assert 'R5 a group name that only longer names start with is absent and created once; an exact name is reused' ($gp.ExitCode -eq 0 -and
        (Get-P91Calls $gp 'ad group create --display-name claude-code-standard*').Count -eq 1 -and -not (Get-P91Calls $gp 'ad group create --display-name claude-code-premium*').Count) (Get-P91Tail $gp)
    $gr = Get-P91Result $r1 $runGraphRead
    Assert 'R5 a failed read of a group by name refuses on one line and creates no group' ((Test-Refusal $gr 'claude-code-standard') -and @(Get-P91ErrLines $gr)[0] -match 'by name' -and
        -not (Get-P91Calls $gr 'ad group create*').Count) (Get-P91Tail $gr)
    $gt = Get-P91Result $r1 $runGraphTwins
    $gtLine = [string]@(Get-P91ErrLines $gt)[0]
    Assert 'R5 two groups with the configured name refuse on one line naming both ids, and no third group is created' ((Test-Refusal $gt 'claude-code-standard') -and
        $gtLine -match '0000000000e8' -and $gtLine -match '0000000000e9' -and -not (Get-P91Calls $gt 'ad group create*').Count) (Get-P91Tail $gt)
    $nx = Get-P91Result $r1 $runNoDir
    Assert 'R6 a state directory that cannot be created: the run warns, prints the resume command with the answers and completes' ($nx.ExitCode -eq 0 -and
        $nx.Out -match '(?m)\[WARN\].*could not be created' -and $nx.Out -match "(?m)^\s*Resume: .*Install-ClaudeGateway\.ps1 .*-ResourceGroup 'rg-p91'" -and
        (Get-P91Calls $nx 'deployment group create*').Count -eq 1) (Get-P91Tail $nx)
    $f1 = Get-P91Result $r1 $runForeign
    Assert 'S4 an unrecorded running claude-gw- deployment is awaited before the new one is created' ($f1.ExitCode -eq 0 -and
        (Get-Order $f1 'deployment group show*claude-gw-20260101000000*' 'deployment group create*')) (Get-P91Tail $f1)

    # ------------------------------------------------------------------ wave 2: reruns
    $sleeper = Start-Process -FilePath $script:P91Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 900') -PassThru -WindowStyle Hidden
    $exited = Start-Process -FilePath $script:P91Pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'exit 0') -PassThru -WindowStyle Hidden
    $exited.WaitForExit()
    $hostName = [Environment]::MachineName.ToLowerInvariant().Split('.')[0]
    $startOf = { param($p) $p.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

    $copy = { param([string]$Name) New-P91Scenario -Name $Name -Scratch $scratch -From $base }
    $sc = [ordered]@{}
    foreach ($n in 'tenant', 'subscription', 'group', 'gateway', 'reuse', 'installer', 'version', 'changed', 'template', 'rgMissing', 'apimMissing', 'groupMissing', 'graphLag',
        'readDeployment', 'readGroup', 'readRg', 'truncated', 'schema', 'unknownStep', 'unsafe', 'restart', 'liveLock', 'exitedLock', 'reusedPid', 'otherHost', 'staleHost', 'flow', 'flowRefusal',
        'aclDir', 'aclFile', 'tamperDeployment', 'tamperGroup', 'tamperRole') {
        $sc[$n] = & $copy $n
    }
    $sc['existingName'] = New-P91Scenario -Name 'existingName' -Scratch $scratch -From $identity
    foreach ($s in @($base) + @($sc.Values)) { Edit-P91World $s { param($w) $w.inject.sync = '' } }
    Edit-P91World $sc.tenant { param($w) $w.tenantId = '00000000-0000-4000-8000-0000000000f9' }
    Edit-Checkpoint $sc.installer { param($cp) $cp.installer = 'bash' }
    Add-Content -LiteralPath (Join-Path $sc.version.Repo 'Install-ClaudeGateway.ps1') -Value '# a later installer'
    Add-Content -LiteralPath (Join-Path $sc.template.Repo 'infra\policy.xml') -Value '<!-- a later policy -->'
    Edit-P91World $sc.rgMissing { param($w) $w.resourceGroups.PSObject.Properties.Remove('rg-p91'); $w.apims.PSObject.Properties.Remove('apim-p91gw'); $w.deployments.PSObject.Properties.Remove('rg-p91') }
    Edit-P91World $sc.apimMissing { param($w) $w.apims.PSObject.Properties.Remove('apim-p91gw') }
    Edit-P91World $sc.groupMissing { param($w) $w.groups.PSObject.Properties.Remove($premiumId) }
    $createdId = [string](@($groupReceipt | Where-Object { $_.origin -eq 'created' })[0].id)
    Edit-P91World $sc.graphLag { param($w) if ($createdId) { $w.groups.PSObject.Properties.Remove($createdId) } }
    Edit-P91World $sc.readDeployment { param($w) $w.inject.readErrors = @([pscustomobject]@{ match = 'deployment group show*'; text = 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.Resources/deployments/read.' }) }
    Edit-P91World $sc.readGroup { param($w) $w.inject.readErrors = @([pscustomobject]@{ match = 'ad group show --group ????????-????-????-????-????????????*'; text = 'ERROR: Service Unavailable (503).' }) }
    Edit-P91World $sc.readRg { param($w) $w.inject.readErrors = @([pscustomobject]@{ match = 'group show*'; text = 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.Resources/subscriptions/resourceGroups/read.' }) }
    $truncate = { param($s) $file = Get-P91CheckpointFile $s; if ($file) { $t = [IO.File]::ReadAllText($file.FullName); Write-P91Text $file.FullName $t.Substring(0, [int]($t.Length / 2)) } }
    & $truncate $sc.truncated
    & $truncate $sc.restart
    Edit-Checkpoint $sc.schema { param($cp) $cp.schemaVersion = 99 }
    Edit-Checkpoint $sc.unknownStep { param($cp) $first = @($cp.steps | Where-Object { $_ })[0]; if ($first) { $first.id = 'gateway-deploy' } }
    Edit-Checkpoint $sc.unsafe { param($cp) if ($cp.answers) { $cp.answers | Add-Member -NotePropertyName PublisherEmail -NotePropertyValue '@C:\p91-secret.txt' -Force } }
    # Receipt values reach az as arguments on a resume, so a value of another shape is a corrupt checkpoint.
    $stepOf = { param($cp, [string]$id) @($cp.steps | Where-Object { $_ -and $_.id -eq $id })[0] }
    Edit-Checkpoint $sc.tamperDeployment { param($cp) $st = & $stepOf $cp 'gateway-deployment'; if ($st) { @($st.receipt.deployments)[0].name = 'p91-not-a-deployment' } }
    Edit-Checkpoint $sc.tamperGroup { param($cp) $st = & $stepOf $cp 'entra-groups'; if ($st) { @($st.receipt.groups)[0].id = '@C:\p91-secret.txt' } }
    Edit-Checkpoint $sc.tamperRole { param($cp) $st = & $stepOf $cp 'gateway-deployment'; if ($st) { $st.receipt | Add-Member -NotePropertyName roleAssignmentId -NotePropertyValue 'https://p91.invalid/collect?id=' -Force } }
    if ($env:OS -eq 'Windows_NT') {
        # Real access rules: Everyone may modify the state directory; Users may write the checkpoint.
        Protect-P91Directory $sc.aclDir.State -AlsoWritableBy 'S-1-1-0'
        $aclTarget = Get-P91CheckpointFile $sc.aclFile
        if ($aclTarget) { Add-P91FileWriter $aclTarget.FullName 'S-1-5-32-545' }
    }
    Write-Lock $sc.liveLock @{ pid = $sleeper.Id; processStart = (& $startOf $sleeper); host = $hostName; installer = 'pwsh'; runId = ('a' * 32); acquiredUtc = '2026-10-01T00:00:00Z' }
    Write-Lock $sc.exitedLock @{ pid = $exited.Id; processStart = (& $startOf $exited); host = $hostName; installer = 'pwsh'; runId = ('b' * 32); acquiredUtc = '2026-10-01T00:00:00Z' }
    Write-Lock $sc.reusedPid @{ pid = $sleeper.Id; processStart = '2001-01-01T00:00:00Z'; host = $hostName; installer = 'pwsh'; runId = ('c' * 32); acquiredUtc = '2026-10-01T00:00:00Z' }
    Write-Lock $sc.otherHost @{ pid = 4242; processStart = '2026-10-01T00:00:00Z'; host = 'p91-other-host'; installer = 'pwsh'; runId = ('d' * 32); acquiredUtc = '2026-10-01T00:00:00Z' }
    Write-Lock $sc.staleHost @{ pid = 4242; processStart = '2026-10-01T00:00:00Z'; host = 'p91-other-host'; installer = 'pwsh'; runId = ('e' * 32); acquiredUtc = '2026-10-01T00:00:00Z' } -AgeMinutes 10
    Edit-P91World $identity { param($w) $w.inject.createMode = 'ok'; $w.apims.'apim-p91reuse'.identity = 'SystemAssigned' }
    Edit-P91World $bu { param($w) $w.inject.bu = '' }
    $bounded = New-P91Scenario -Name 'bounded' -Scratch $scratch -From $running
    Edit-P91World $bounded { param($w) foreach ($p in $w.deployments.'rg-p91'.PSObject.Properties) { $p.Value.polls = @('forever') } }
    $hashes = @{}
    foreach ($n in 'tenant', 'subscription', 'group', 'gateway', 'reuse', 'installer', 'truncated', 'schema', 'unknownStep', 'unsafe', 'aclDir', 'aclFile', 'tamperDeployment', 'tamperGroup', 'tamperRole', 'existingName') { $file = Get-P91CheckpointFile $sc[$n]; $hashes[$n] = if ($file) { Get-P91Hash $file.FullName } else { '' } }

    $flowArgs = "@{ SubscriptionId = '$sub'; FoundryAccount = 'ai-p91'; FoundryResourceGroup = 'rg-ai-p91'; ResourceGroup = 'RG'; Location = 'eastus2'; NamePrefix = 'p91gw'; PublisherEmail = 'ops@contoso.com'; Sku = 'BasicV2'; EntitlementStore = 'named-value'; AuthMode = 'interactive'; DesktopSignInKind = 'helper-script'; AddressMode = 'azure'; SkipFinOpsOffer = `$true; Yes = `$true }"
    $flowCommand = { param($s, [string]$rg) ". '$(Join-Path $s.Repo 'scripts\flow\FlowContract.ps1')'; . '$(Join-Path $s.Repo 'scripts\flow\Foundation.ps1')'; " +
        "try { `$null = Invoke-ClaudeFlowStep -Record ([pscustomobject]@{ decisions = [pscustomobject]@{} }) -Plan ([pscustomobject]@{ Data = [pscustomobject]@{ runsInstaller = `$true; installerArgs = $($flowArgs.Replace("'RG'", "'$rg'")) } }); [Console]::Out.WriteLine('FLOW-STEP-DONE') } " +
        "catch { [Console]::Out.WriteLine('FLOW-CAUGHT: ' + `$_.Exception.Message); exit 3 }" }
    $second = @(
        # The lock runs first: their locks were written with a last-write time just before this wave.
        ($runLiveLock = New-P91Run $sc.liveLock -Arguments ($newGateway + '-Yes'))
        ($runExitedLock = New-P91Run $sc.exitedLock -Arguments ($newGateway + '-Yes'))
        ($runReusedPid = New-P91Run $sc.reusedPid -Arguments ($newGateway + '-Yes'))
        ($runOtherHost = New-P91Run $sc.otherHost -Arguments ($newGateway + '-Yes'))
        ($runStaleHost = New-P91Run $sc.staleHost -Arguments ($newGateway + '-Yes'))
        ($runBase2 = New-P91Run $base -Arguments ($newGateway + '-Yes'))
        ($runIdentity2 = New-P91Run $identity -Arguments ($reused + '-Yes'))
        ($runBu2 = New-P91Run $bu -Arguments ($reused + $quiet) -Attended -Answers @('', 'y', 'platform', '', '', 'n'))
        ($runRunning2 = New-P91Run $running -Arguments ($newGateway + '-Yes'))
        ($runBounded = New-P91Run $bounded -Arguments ($newGateway + '-Yes') -Environment @{ CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS = '1' })
        ($runTenant = New-P91Run $sc.tenant -Arguments ($newGateway + '-Yes'))
        ($runSubscription = New-P91Run $sc.subscription -Arguments (($newGateway -replace [regex]::Escape($sub), '00000000-0000-4000-8000-0000000000a9') + '-Yes'))
        ($runGroup = New-P91Run $sc.group -Arguments (($newGateway -replace "'rg-p91'", "'rg-other'") + '-Yes'))
        ($runGateway = New-P91Run $sc.gateway -Arguments (($newGateway -replace "'p91gw'", "'p91other'") + '-Yes'))
        ($runInstaller = New-P91Run $sc.installer -Arguments ($newGateway + '-Yes'))
        ($runVersion = New-P91Run $sc.version -Arguments ($newGateway + '-Yes'))
        ($runChanged = New-P91Run $sc.changed -Arguments ($newGateway + '-TpmStandard 30000' + '-Yes'))
        ($runReuse = New-P91Run $sc.reuse -Arguments ($common + @("-ResourceGroup 'rg-p91'", "-ExistingApimName 'apim-p91gw'", '-Yes')))
        ($runTemplate = New-P91Run $sc.template -Arguments ($newGateway + '-Yes'))
        ($runRgMissing = New-P91Run $sc.rgMissing -Arguments ($newGateway + '-Yes'))
        ($runApimMissing = New-P91Run $sc.apimMissing -Arguments ($newGateway + '-Yes'))
        ($runGroupMissing = New-P91Run $sc.groupMissing -Arguments ($newGateway + '-Yes'))
        ($runGraphLag = New-P91Run $sc.graphLag -Arguments ($newGateway + '-Yes'))
        ($runReadDeployment = New-P91Run $sc.readDeployment -Arguments ($newGateway + '-Yes'))
        ($runReadGroup = New-P91Run $sc.readGroup -Arguments ($newGateway + '-Yes'))
        ($runReadRg = New-P91Run $sc.readRg -Arguments ($newGateway + '-Yes'))
        ($runTruncated = New-P91Run $sc.truncated -Arguments ($newGateway + '-Yes'))
        ($runSchema = New-P91Run $sc.schema -Arguments ($newGateway + '-Yes'))
        ($runUnknownStep = New-P91Run $sc.unknownStep -Arguments ($newGateway + '-Yes'))
        ($runUnsafe = New-P91Run $sc.unsafe -Arguments ($newGateway + '-Yes'))
        ($runRestart = New-P91Run $sc.restart -Arguments ($newGateway + '-Yes', '-Restart'))
        ($runFlow = New-P91Run $sc.flow -Command (& $flowCommand $sc.flow 'rg-p91'))
        ($runFlowRefusal = New-P91Run $sc.flowRefusal -Command (& $flowCommand $sc.flowRefusal 'rg-other'))
        ($runAclDir = New-P91Run $sc.aclDir -Arguments ($newGateway + '-Yes'))
        ($runAclFile = New-P91Run $sc.aclFile -Arguments ($newGateway + '-Yes'))
        ($runTamperDeployment = New-P91Run $sc.tamperDeployment -Arguments ($newGateway + '-Yes'))
        ($runTamperGroup = New-P91Run $sc.tamperGroup -Arguments ($newGateway + '-Yes'))
        ($runTamperRole = New-P91Run $sc.tamperRole -Arguments ($newGateway + '-Yes'))
        ($runExistingName = New-P91Run $sc.existingName -Arguments ($common + @("-ResourceGroup 'rg-p91'", "-ExistingApimName 'apim-other'", '-Yes')))
    )
    $r2 = Invoke-P91Runs $second

    Write-Host '  reruns' -ForegroundColor DarkGray
    $b2 = Get-P91Result $r2 $runBase2
    Assert 'S1 the rerun completes and creates no deployment and no group' ($b2.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $base.Repo 'onboarding\claude-gateway.json')) -and
        -not (Get-P91Calls $b2 'deployment group create*').Count -and -not (Get-P91Calls $b2 'ad group create*').Count) (@(Get-P91Calls $b2 '*create*') -join '; ')
    Assert 'S1 the rerun reads both groups by id, not by name, and syncs again' ((Get-P91Calls $b2 "ad group show --group $createdId*").Count -and (Get-P91Calls $b2 "ad group show --group $premiumId*").Count -and
        -not (Get-P91Calls $b2 'ad group show --group claude-code-*').Count -and @($b2.Scripts | Where-Object { $_ -like 'sync *' }).Count -eq 1) (@(Get-P91Calls $b2 'ad group show*') -join '; ')
    Assert 'R9 the rerun prints each completed step with its UTC time and the step it resumes at' ($b2.Out -match ($doneAt + 'Resource group') -and $b2.Out -match ($doneAt + 'Gateway deployment') -and
        $b2.Out -match ($doneAt + 'Entra groups') -and $b2.Out -match ($resumesAt + 'Sync entitlement')) (Get-P91Tail $b2)
    Assert 'R1 each skipped step was verified live' (([regex]::Matches($b2.Out, 'verified live, skipped')).Count -ge 3)
    Assert 'R2 the summary names the checkpoint and the recorded answers' ($b2.Out -match '(?m)^\s+Checkpoint\s+.*recorded answers')
    Assert 'S1 a completed run removes the checkpoint run 1 left, and its lock' ($baseCheckpoint -and $b2.ExitCode -eq 0 -and -not (Get-P91CheckpointFile $base) -and
        -not @(Get-ChildItem -LiteralPath $base.State -Filter '*.lock' -ErrorAction SilentlyContinue).Count)

    $i1 = Get-P91Result $r1 $runIdentity1; $i2 = Get-P91Result $r2 $runIdentity2
    $firstName = [string](@(Get-P91Calls $i1 'deployment group create*')[0] -replace '^.*--name (\S+).*$', '$1')
    $secondCreate = @(Get-P91Calls $i2 'deployment group create*')
    $secondName = if ($secondCreate.Count) { [string]($secondCreate[0] -replace '^.*--name (\S+).*$', '$1') } else { '' }
    # The stub's az error is a PowerShell error record, which the error view wraps at the console
    # width; az itself writes the text unwrapped.
    $i1Text = ($i1.Out + $i1.Err) -replace '\s*\n\s*(\|\s*)?', ' '
    Assert 'S2 after the identity error of run 1, the rerun shows the recorded deployment''s error' ($i1.ExitCode -ne 0 -and $i1Text -match "property 'identity' doesn't exist" -and
        $i2.Out -match "(?m)^.*$([regex]::Escape($firstName)).*Failed.*property 'identity' doesn't exist") (Get-P91Tail $i2)
    Assert 'S2 the read-backs run before a new deployment whose name differs and was recorded before it was created' ($i2.ExitCode -eq 0 -and $secondName -and $secondName -ne $firstName -and
        (Get-Order $i2 'apim nv show*allow-standard*' 'deployment group create*') -and (Get-Order $i2 'REST Get https://management.azure.com/*' 'deployment group create*') -and
        (Test-Path -LiteralPath (Join-Path $i2.Run.Logs "checkpoint-at-create-$secondName.json")) -and
        ([IO.File]::ReadAllText((Join-Path $i2.Run.Logs "checkpoint-at-create-$secondName.json")) -match [regex]::Escape($secondName))) "$firstName -> $secondName"

    $u1 = Get-P91Result $r1 $runBu1; $u2 = Get-P91Result $r2 $runBu2
    Assert 'S3 after run 1 stopped at the business-unit write, the attended rerun resumes there without asking the answered questions' ($u1.ExitCode -ne 0 -and
        ($u1.Out + $u1.Err) -match "Business unit 'platform' was refused" -and $u2.ExitCode -eq 0 -and $u2.Out -match ($resumesAt + 'Business units') -and
        @($u2.Scripts | Where-Object { $_ -like 'bu platform *' }).Count -eq 1) (Get-P91Tail $u2)
    Assert 'S3 the rerun creates no deployment' ($u2.ExitCode -eq 0 -and -not (Get-P91Calls $u2 'deployment group create*').Count)

    $g2 = Get-P91Result $r2 $runRunning2; $g1 = Get-P91Result $r1 $runRunning1
    Assert 'S4 after run 1 died while its deployment ran, the rerun waits for it and creates none' ($g1.ExitCode -ne 0 -and $g2.ExitCode -eq 0 -and
        -not (Get-P91Calls $g2 'deployment group create*').Count -and (Get-P91Calls $g2 'deployment group show*').Count -ge 3) (Get-P91Tail $g2)
    $bb = Get-P91Result $r2 $runBounded
    $bbLines = @(Get-P91ErrLines $bb)
    Assert 'S4 past the bound the run refuses on one line with the resume command, and creates nothing' ($bb.ExitCode -eq 1 -and $bbLines.Count -eq 1 -and $bbLines[0] -match 'still running' -and
        $bbLines[0] -match 'Install-ClaudeGateway\.ps1' -and -not (Get-P91Calls $bb 'deployment group create*').Count) (Get-P91Tail $bb)

    foreach ($case in @(@('tenant', $runTenant, 'tenant'), @('subscription', $runSubscription, 'subscription'), @('group', $runGroup, 'resource group'),
            @('gateway', $runGateway, 'gateway'), @('installer', $runInstaller, 'install-claude-gateway\.sh'))) {
        $res = Get-P91Result $r2 $case[1]
        Assert "S5 a different $($case[2] -replace '\\', '') refuses on one line, names it and keeps the checkpoint unchanged" ((Test-Refusal $res $case[2]) -and (Test-Kept $sc[$case[0]] $hashes[$case[0]])) (Get-P91Tail $res)
    }
    $v2 = Get-P91Result $r2 $runVersion
    Assert 'S5 a different installer version resumes and says which wrote the checkpoint' ($v2.ExitCode -eq 0 -and
        $v2.Out -match '(?m)checkpoint written by Install-ClaudeGateway\.ps1 \S+; running Install-ClaudeGateway\.ps1 \S+' -and -not (Get-P91Calls $v2 'deployment group create*').Count) (Get-P91Tail $v2)
    $t2 = Get-P91Result $r2 $runTemplate
    Assert 'Amendment 1 a template change reruns the deployment through the read-backs, and the unchanged resource group is verified, not created' ($t2.ExitCode -eq 0 -and
        (Get-Order $t2 'apim nv show*allow-standard*' 'deployment group create*') -and $t2.Out -match ($doneAt + 'Resource group') -and -not (Get-P91Calls $t2 'group create*').Count) (Get-P91Tail $t2)

    $m1 = Get-P91Result $r2 $runRgMissing; $m2 = Get-P91Result $r2 $runApimMissing; $m3 = Get-P91Result $r2 $runGroupMissing
    Assert 'S6 a completed resource group that is gone is created again' ($m1.ExitCode -eq 0 -and $m1.Out -match $resumesAt -and (Get-P91Calls $m1 'group create*').Count -eq 1) (Get-P91Tail $m1)
    Assert 'S6 a completed gateway that is gone is deployed again' ($m2.ExitCode -eq 0 -and $m2.Out -match $resumesAt -and (Get-P91Calls $m2 'deployment group create*').Count -eq 1) (Get-P91Tail $m2)
    Assert 'S6 a pre-existing group that is gone is looked up again and created' ($m3.ExitCode -eq 0 -and (Get-P91Calls $m3 "ad group show --group $premiumId*").Count -and
        (Get-P91Calls $m3 'ad group create --display-name claude-code-premium*').Count -eq 1 -and -not (Get-P91Calls $m3 'ad group create --display-name claude-code-standard*').Count) (Get-P91Tail $m3)
    $lag = Get-P91Result $r2 $runGraphLag
    Assert 'U74 a group this run created that Graph does not return refuses on one line, with the Graph delay and the resume command' (
        (Test-Refusal $lag 'Microsoft Graph') -and @(Get-P91ErrLines $lag)[0] -match 'without creating a second group' -and @(Get-P91ErrLines $lag)[0] -match 'Install-ClaudeGateway\.ps1' -and
        -not (Get-P91Calls $lag 'ad group create*').Count) (Get-P91Tail $lag)
    $e1 = Get-P91Result $r2 $runReadDeployment; $e2 = Get-P91Result $r2 $runReadGroup; $e3 = Get-P91Result $r2 $runReadRg
    Assert 'S7 a deployment read error refuses and creates nothing' ((Test-Refusal $e1 'deployment') -and -not (Get-P91Calls $e1 'deployment group create*').Count) (Get-P91Tail $e1)
    Assert 'S7 a group read error refuses and creates no group' ((Test-Refusal $e2 'group') -and -not (Get-P91Calls $e2 'ad group create*').Count) (Get-P91Tail $e2)
    Assert 'S7 an unreadable resource group is not skipped: its idempotent step runs again' ($e3.ExitCode -eq 0 -and $e3.Out -match $resumesAt -and
        (Get-P91Calls $e3 'group create*').Count -eq 1 -and $e3.Out -notmatch '(?m)Resource group: verified live, skipped') (Get-P91Tail $e3)

    foreach ($case in @(@('truncated', $runTruncated, 'not valid JSON'), @('schema', $runSchema, 'schemaVersion'), @('unknownStep', $runUnknownStep, 'gateway-deploy'), @('unsafe', $runUnsafe, 'PublisherEmail'))) {
        $res = Get-P91Result $r2 $case[1]
        Assert "S8 a corrupt checkpoint ($($case[0])) refuses on one line naming the problem and keeps the file byte for byte" ((Test-Refusal $res $case[2]) -and (Test-Kept $sc[$case[0]] $hashes[$case[0]])) (Get-P91Tail $res)
    }
    $rs = Get-P91Result $r2 $runRestart
    Assert 'S8 -Restart sets the corrupt checkpoint aside and runs as a first run' ($rs.ExitCode -eq 0 -and
        @(Get-ChildItem -LiteralPath $sc.restart.State -Filter '*.discarded-*.json').Count -eq 1 -and (Get-P91Calls $rs 'deployment group create*').Count -eq 1) (Get-P91Tail $rs)

    $l1 = Get-P91Result $r2 $runLiveLock; $l2 = Get-P91Result $r2 $runExitedLock; $l3 = Get-P91Result $r2 $runReusedPid; $l4 = Get-P91Result $r2 $runOtherHost; $l5 = Get-P91Result $r2 $runStaleHost
    Assert 'S9 a live lock refuses on one line naming its process' ((Test-Refusal $l1 "$($sleeper.Id)") -and -not (Get-P91Calls $l1 'group *').Count) (Get-P91Tail $l1)
    Assert 'S9 a lock whose process has exited is stale and taken over' ($l2.ExitCode -eq 0 -and $l2.Out -match '(?m)stale lock') (Get-P91Tail $l2)
    Assert 'S9 a lock whose PID now names another process (start time differs) is stale' ($l3.ExitCode -eq 0 -and $l3.Out -match '(?m)stale lock') (Get-P91Tail $l3)
    Assert 'S9 another host''s lock with a recent heartbeat refuses and names the host' (Test-Refusal $l4 'p91-other-host') (Get-P91Tail $l4)
    Assert 'S9 another host''s lock without a heartbeat for 5 minutes is stale' ($l5.ExitCode -eq 0 -and $l5.Out -match '(?m)stale lock') (Get-P91Tail $l5)
    $l1Line = [string]@(Get-P91ErrLines $l1)[0]; $l4Line = [string]@(Get-P91ErrLines $l4)[0]
    Assert 'S9 the held-lock refusal names host, PID and start, says the lock ends with that run, and ends with the resume command' ($l1Line -match (
        "^Refused: another install run \(host [^,]+, PID $($sleeper.Id), started [^)]+\) holds the lock .+; nothing was changed\. The lock ends with that run: a later run takes it over once that process has exited\. Resume: .*Install-ClaudeGateway\.ps1")) $l1Line
    Assert 'S9 another host''s held lock says when a later run takes it over, and ends with the resume command' ($l4Line -match (
        '^Refused: another install run \(host p91-other-host, PID 4242, started [^,]+, last heartbeat \d+ minute\(s\) ago\) holds the lock .+; nothing was changed\. The lock ends with that run: a later run takes it over after 5 minutes without a heartbeat\. Resume: .*Install-ClaudeGateway\.ps1')) $l4Line

    if ($env:OS -eq 'Windows_NT') {
        $ad = Get-P91Result $r2 $runAclDir; $af = Get-P91Result $r2 $runAclFile
        $adLine = [string]@(Get-P91ErrLines $ad)[0]; $afLine = [string]@(Get-P91ErrLines $af)[0]
        Assert 'R6 a state directory with a rule that lets Everyone write refuses at startup on one line naming the rule; nothing is read or changed' ($ad.ExitCode -eq 1 -and
            @(Get-P91ErrLines $ad).Count -eq 1 -and $adLine -match '^Refused: the install checkpoint directory ' -and $adLine.Contains($sc.aclDir.State) -and $adLine -match 'S-1-1-0' -and $adLine -match 'Nothing was read or changed' -and
            -not (Get-P91Calls $ad 'account set*').Count -and (Test-Kept $sc.aclDir $hashes.aclDir) -and -not @(Get-ChildItem -LiteralPath $sc.aclDir.State -Filter '*.lock').Count) (Get-P91Tail $ad)
        Assert 'R6 a checkpoint with a rule that lets Users write refuses at startup on one line naming the file and the rule' ($af.ExitCode -eq 1 -and @(Get-P91ErrLines $af).Count -eq 1 -and
            $afLine -match '^Refused: ' -and $afLine -match 'install-[0-9a-f]{16}\.json' -and $afLine -match 'S-1-5-32-545' -and $afLine -match 'Nothing was read or changed' -and
            -not (Get-P91Calls $af 'account set*').Count -and (Test-Kept $sc.aclFile $hashes.aclFile)) (Get-P91Tail $af)
    }
    foreach ($case in @(@('tamperDeployment', $runTamperDeployment, 'receipt of step gateway-deployment that names the deployment'),
            @('tamperGroup', $runTamperGroup, 'receipt of step entra-groups that holds the group id'), @('tamperRole', $runTamperRole, 'receipt of step gateway-deployment that holds the role assignment id'))) {
        $res = Get-P91Result $r2 $case[1]
        Assert "R5 a tampered receipt ($($case[0])) refuses on one line as a corrupt checkpoint and keeps the file byte for byte" ((Test-Refusal $res $case[2]) -and (Test-Kept $sc[$case[0]] $hashes[$case[0]])) (Get-P91Tail $res)
    }
    $en = Get-P91Result $r2 $runExistingName
    $enLine = [string]@(Get-P91ErrLines $en)[0]
    Assert 'S5 a different -ExistingApimName refuses on one line, names both gateways and keeps the checkpoint unchanged' ((Test-Refusal $en 'gateway') -and $enLine -match 'apim-p91reuse' -and
        $enLine -match 'apim-other' -and (Test-Kept $sc.existingName $hashes.existingName)) (Get-P91Tail $en)

    $fl = Get-P91Result $r2 $runFlow; $fr = Get-P91Result $r2 $runFlowRefusal
    Assert 'Flow the guided flow''s foundation step resumes the installer from its checkpoint' ($fl.ExitCode -eq 0 -and $fl.Out -match 'FLOW-STEP-DONE' -and $fl.Out -match $resumesAt -and
        -not (Get-P91Calls $fl 'deployment group create*').Count) (Get-P91Tail $fl)
    Assert 'Flow called from a script, the installer raises the refusal unchanged' ($fr.ExitCode -eq 3 -and $fr.Out -match '(?m)^FLOW-CAUGHT: Refused: .*resource group.*Nothing was changed') (Get-P91Tail $fr)

    # ------------------------------------------------------------------ R6: an interrupted write keeps the previous checkpoint
    $library = Join-Path $script:P91Root 'scripts\ClaudeInstallCheckpoint.ps1'
    $atomicDir = Join-Path $scratch 'atomic'
    New-Item -ItemType Directory -Force -Path $atomicDir | Out-Null
    Protect-P91Directory $atomicDir
    $kept = $false; $noTemp = $false
    if (Test-Path -LiteralPath $library) {
        . $library
        $path = Join-Path $atomicDir 'install-0000000000000000.json'
        $cp = [pscustomobject]@{ schema = 'claude-gateway-install-checkpoint'; schemaVersion = 1; runId = ('f' * 32); steps = @() }
        Write-ClaudeInstallCheckpoint -Checkpoint $cp -Path $path
        $before = Get-P91Hash $path
        function Move-ClaudeInstallCheckpointFile { param($Source, $Destination) throw 'interrupted before the rename' }
        $cp.runId = ('0' * 32)
        try { Write-ClaudeInstallCheckpoint -Checkpoint $cp -Path $path } catch { }
        $kept = ((Get-P91Hash $path) -eq $before)
        $noTemp = -not @(Get-ChildItem -LiteralPath $atomicDir -Filter '*.tmp-*').Count
    }
    Assert 'R6 a write interrupted before its rename keeps the previous checkpoint and leaves no temporary file' ($kept -and $noTemp)

    $cg = Get-P91Result $r2 $runChanged
    Assert 'R2 the summary''s Checkpoint row names an answer this run changes, before the confirmation' ($cg.ExitCode -eq 0 -and
        $cg.Out -match '(?m)^\s+Checkpoint\s+.*changed since the checkpoint: TpmStandard' -and (Get-P91Calls $cg 'deployment group create*').Count -eq 1) (Get-P91Tail $cg)

    $ru = Get-P91Result $r2 $runReuse
    Assert 'S5 the same gateway name, reused where run 1 created it, refuses on one line, names reusedApim and keeps the checkpoint unchanged' ((Test-Refusal $ru 'reusedApim') -and (Test-Kept $sc.reuse $hashes.reuse)) (Get-P91Tail $ru)

    $all = @($r1.Values) + @($r2.Values)
    $unexpected = @($all | ForEach-Object { $_.Unexpected } | Where-Object { $_ })
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @($all | Where-Object { $_.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($sleeper -and -not $sleeper.HasExited) { try { $sleeper.Kill() } catch { } }
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
