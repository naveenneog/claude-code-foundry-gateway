$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$count = 0
function Assert($label, $condition, $detail = '') {
    $script:count++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) {
    $script:Failure = ''
    $script:Result = $null
    try { $script:Result = & $Block }
    catch { $script:Failure = $_.Exception.Message }
}

. (Join-Path $root 'scripts\ClaudeChoice.ps1')
. (Join-Path $root 'scripts\ClaudeInstallProjection.ps1')

Write-Host ''
Write-Host 'Installer projection defaults and orchestration' -ForegroundColor Cyan

$choice = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 50 -BuCeiling 93 -ListCeiling 110 -Yes
Assert '-Yes without -EntitlementStore chooses projection at small size' ($choice.Store -eq 'projection' -and $choice.DeployProjection) ($choice | ConvertTo-Json -Depth 4)
Assert 'the interactive choice offers projection first and recommends it' ($choice.Options[0].Value -eq 'projection' -and $choice.Options[0].Recommended -and $choice.Options[1].Value -eq 'named-value') ($choice.Options | ConvertTo-Json -Depth 4)

$existingNamedDefault = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 50 -BuCeiling 93 -ListCeiling 110 -DefaultStore 'named-value' -Yes
Assert 'an existing named-value gateway still defaults to projection so reruns migrate unless named-value is explicit' ($existingNamedDefault.Store -eq 'projection' -and $existingNamedDefault.Options[0].Recommended -and -not $existingNamedDefault.Options[1].Recommended -and $existingNamedDefault.Options[0].Reason -match 'migrate') ($existingNamedDefault | ConvertTo-Json -Depth 4)
$existingProjectionDefault = Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 50 -BuCeiling 93 -ListCeiling 110 -DefaultStore 'projection' -Yes
Assert 'an existing projection gateway defaults to projection' ($existingProjectionDefault.Store -eq 'projection' -and $existingProjectionDefault.Options[0].Reason -match 'current store') ($existingProjectionDefault | ConvertTo-Json -Depth 4)

Capture { Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 94 -BuCeiling 93 -ListCeiling 110 -EntitlementStore 'named-value' -Yes }
Assert 'named values above the computed business-unit ceiling are refused' ($Failure -match 'Named values hold about 93 developers' -and $Failure -match 'choose projection') $Failure

function Get-GraphToken { 'offline-token' }
function Get-GroupMemberOids { param([string]$GroupName, [string]$Token) if ($GroupName -eq 'std') { @([pscustomobject]@{Oid='a'},[pscustomobject]@{Oid='b'}) } else { @([pscustomobject]@{Oid='b'},[pscustomobject]@{Oid='c'}) } }
$countFromGroups = Get-ClaudeInstallerDeveloperCountFromGroups -StandardGroup std -PremiumGroup prem
Assert 'unattended named-value capacity can derive a distinct developer count from tier groups' ($countFromGroups -eq 3) "count=$countFromGroups"

foreach ($sku in 'BasicV2','StandardV2','PremiumV2') {
    $resolver = Resolve-ClaudeInstallerResolverInboundAccess -Sku $sku -EntitlementStore projection
    Assert "resolver inbound access defaults public on $sku" ($resolver.Access -eq 'public' -and $resolver.Message -match 'public') ($resolver | ConvertTo-Json -Depth 4)
}
Capture { Resolve-ClaudeInstallerResolverInboundAccess -Sku BasicV2 -EntitlementStore projection -Requested private }
Assert 'Basic v2 still refuses private resolver inbound access' ($Failure -match 'BasicV2 cannot use a private resolver') $Failure
$private = Resolve-ClaudeInstallerResolverInboundAccess -Sku StandardV2 -EntitlementStore projection -Requested private
Assert 'private resolver text states the outbound VNet prerequisite and source date' ($private.Message -match 'outbound VNet integration' -and $private.Message -match 'updated 2025-12-04') $private.Message

$missing = @{ pwsh = $true; az = $true; node = $false; npm = $true; tar = $true }
Capture {
    Assert-ClaudeInstallerProjectionPrerequisites -PowerShellMajor 7 -CommandExists { param($Name) [bool]$missing[$Name] }
}
Assert 'projection prerequisite checks stop before Azure writes and name the missing tool remedy' ($Failure -match 'node' -and $Failure -match 'Install node') $Failure
Capture {
    Assert-ClaudeInstallerProjectionPrerequisites -PowerShellMajor 5 -CommandExists { param($Name) $true }
}
Assert 'PowerShell 7 is required before projection deployment' ($Failure -match 'PowerShell 7' -and $Failure -match 'pwsh') $Failure

$whatIf = Get-ClaudeInstallerProjectionPlan -WhatIf -SyncInterval 2h
Assert '-WhatIf lists projection deployment, populate, compare, switch and the sync job with its interval' (
    (($whatIf.Steps -join '|') -match 'Deploy projection resources' -and
     ($whatIf.Steps -join '|') -match 'Populate and compare' -and
     ($whatIf.Steps -join '|') -match 'Switch entitlement-source to projection' -and
     ($whatIf.Steps -join '|') -match 'Deploy the sync job, running every 2 hours') -and -not $whatIf.Writes
) ($whatIf | ConvertTo-Json -Depth 4)
$noJobPlan = Get-ClaudeInstallerProjectionPlan -SyncInterval none
Assert '-ProjectionSyncInterval none plans no sync job' ($noJobPlan.Steps.Count -eq 4 -and -not (($noJobPlan.Steps -join '|') -match 'sync job')) ($noJobPlan | ConvertTo-Json -Depth 4)
$manualPlan = Get-ClaudeInstallerProjectionPlan -SyncInterval manual
Assert 'a manual job is planned as running only when started' ((($manualPlan.Steps -join '|') -match 'Deploy the sync job, running only when started')) ($manualPlan | ConvertTo-Json -Depth 4)

# P104 (ADR-0058 decision 2): -ProjectionSyncInterval, else the deployed job's interval on a re-run, else 2h.
# Each choice runs through Capture, so a refusal fails its own assertion instead of ending the suite.
$deployedJob = { param($Interval, $Cron) [pscustomobject]@{ Name = 'caj-renew-p98'; Interval = $Interval; Cron = $Cron } }
function Get-SyncChoice([string]$Requested, $DeployedJob) {
    Capture { Resolve-ClaudeInstallerSyncInterval -Requested $Requested -DeployedJob $DeployedJob }
    [pscustomobject]@{ Choice = $script:Result; Failure = $script:Failure }
}
$fresh = Get-SyncChoice '' $null
Assert 'a new projection gets the sync job every 2 hours by default' (-not $fresh.Failure -and $fresh.Choice.Interval -ceq '2h' -and $fresh.Choice.Source -ceq 'default' -and
    $fresh.Choice.Summary -match 'every 2 hours' -and $fresh.Choice.Summary -match '365 runs a month' -and $fresh.Choice.Summary -match '0\.00003') "$($fresh.Failure) | $($fresh.Choice | ConvertTo-Json -Compress)"
$kept = Get-SyncChoice '' (& $deployedJob '30m' '*/30 * * * *')
Assert "a re-run keeps the deployed job's interval" (-not $kept.Failure -and $kept.Choice.Interval -ceq '30m' -and $kept.Choice.Source -ceq 'deployed job' -and
    $kept.Choice.Summary -match 'every 30 minutes' -and $kept.Choice.Summary -match '1460 runs a month') "$($kept.Failure) | $($kept.Choice | ConvertTo-Json -Compress)"
$chosen = Get-SyncChoice '4h' (& $deployedJob '30m' '*/30 * * * *')
Assert '-ProjectionSyncInterval wins over the deployed job' (-not $chosen.Failure -and $chosen.Choice.Interval -ceq '4h' -and $chosen.Choice.Source -ceq 'parameter') "$($chosen.Failure) | $($chosen.Choice | ConvertTo-Json -Compress)"
$oddCron = Get-SyncChoice '' (& $deployedJob $null '15 */2 * * *')
Assert 'a deployed cron outside the intervals stops the re-run until -ProjectionSyncInterval names one' ($oddCron.Failure -match '15 \*/2 \* \* \*' -and
    $oddCron.Failure -match '-ProjectionSyncInterval' -and $oddCron.Failure -match 'Nothing was changed') "$($oddCron.Failure) | $($oddCron.Choice | ConvertTo-Json -Compress)"
$oddReplaced = Get-SyncChoice '4h' (& $deployedJob $null '15 */2 * * *')
Assert '-ProjectionSyncInterval replaces a deployed cron outside the intervals' (-not $oddReplaced.Failure -and $oddReplaced.Choice.Interval -ceq '4h' -and $oddReplaced.Choice.Source -ceq 'parameter') "$($oddReplaced.Failure) | $($oddReplaced.Choice | ConvertTo-Json -Compress)"
$keptManual = Get-SyncChoice '' (& $deployedJob 'manual' '')
Assert 'a re-run keeps a deployed manual job manual' (-not $keptManual.Failure -and $keptManual.Choice.Interval -ceq 'manual' -and $keptManual.Choice.Source -ceq 'deployed job' -and
    $keptManual.Choice.Summary -match 'only when started') "$($keptManual.Failure) | $($keptManual.Choice | ConvertTo-Json -Compress)"
$noneKept = Get-SyncChoice 'none' (& $deployedJob '30m' '*/30 * * * *')
Assert 'none with a deployed job says the job keeps its schedule and how to change it' (-not $noneKept.Failure -and $noneKept.Choice.Interval -ceq 'none' -and
    $noneKept.Choice.KeptJob -ceq 'every 30 minutes' -and $noneKept.Choice.Summary -match 'keeps its schedule \(every 30 minutes\)' -and
    $noneKept.Choice.Summary -match 'Set-ClaudeProjectionSyncSchedule\.ps1') "$($noneKept.Failure) | $($noneKept.Choice | ConvertTo-Json -Compress)"
$noneOdd = Get-SyncChoice 'none' (& $deployedJob $null '15 */2 * * *')
Assert 'none with a deployed cron outside the intervals names that cron' (-not $noneOdd.Failure -and $noneOdd.Choice.KeptJob -match "cron '15 \*/2 \* \* \*'") "$($noneOdd.Failure) | $($noneOdd.Choice | ConvertTo-Json -Compress)"
$manualChoice = Get-SyncChoice 'manual' $null
Assert 'manual deploys the job with no schedule' (-not $manualChoice.Failure -and $manualChoice.Choice.Interval -ceq 'manual' -and $manualChoice.Choice.Summary -match 'only when started') "$($manualChoice.Failure) | $($manualChoice.Choice | ConvertTo-Json -Compress)"
$noneChoice = Get-SyncChoice 'NONE' $null
Assert 'none skips the job, in any case, and says how group changes are published' (-not $noneChoice.Failure -and $noneChoice.Choice.Interval -ceq 'none' -and
    $noneChoice.Choice.Summary -match 'not deployed' -and $noneChoice.Choice.Summary -match 'Sync-ClaudeAccess\.ps1') "$($noneChoice.Failure) | $($noneChoice.Choice | ConvertTo-Json -Compress)"
$tooShort = Get-SyncChoice '15m' $null
Assert 'an interval under 30 minutes is refused with the accepted values, none included' ($tooShort.Failure -match "'15m'" -and $tooShort.Failure -match '30m, 1h, 2h, 3h, 4h, 6h, 8h, 12h, manual, none') $tooShort.Failure

$calls = [System.Collections.Generic.List[object]]::new()
$everyCall = [System.Collections.Generic.List[object]]::new()
$record = { param($ScriptPath, $Arguments) $call = [pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }; $calls.Add($call); $everyCall.Add($call); 0 }
$ok = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem -SubscriptionId 00000000-0000-4000-8000-000000000001 `
    -InvokeScript $record
$named = { param($Call, $Name) $key = $Name.TrimStart('-'); if ($Call.Args.Contains($key)) { @($Call.Args[$key]) -join ',' } }
Assert 'choosing projection deploys, populates and compares first, then switches in a second run of the deployer' (
    $ok -and $calls.Count -eq 2 -and
    ($calls[0].Path -match 'Deploy-ClaudeProjection\.ps1$') -and ($calls[1].Path -match 'Deploy-ClaudeProjection\.ps1$') -and
    (-not $calls[0].Args.Contains('FlipAfterCleanCompare')) -and $calls[1].Args.Contains('FlipAfterCleanCompare') -and
    (& $named $calls[0] '-Sku') -eq 'BasicV2' -and (& $named $calls[0] '-ResolverInboundAccess') -eq 'public' -and (& $named $calls[0] '-Location') -eq 'eastus2' -and
    (& $named $calls[1] '-NamePrefix') -eq 'p98' -and (& $named $calls[1] '-StandardGroup') -eq 'std' -and (& $named $calls[1] '-PremiumGroup') -eq 'prem' -and
    -not @($calls | ForEach-Object { $_.Args.Keys } | Where-Object { $_ -match 'Renewal|^ReconcilerResourceId$' }).Count
) ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
Capture {
    Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
        -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem `
        -InvokeScript { param($ScriptPath, $Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); 7 }
}
Assert 'a failed deployment runs no switch and names the deployment rerun; named values keep serving' ($calls.Count -eq 1 -and $Failure -match 'Deploy-ClaudeProjection\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98' -and $Failure -notmatch '-FlipAfterCleanCompare' -and $Failure -match 'named values keep serving') "$Failure | calls $($calls.Count)"

$calls.Clear()
Capture {
    Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
        -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem `
        -InvokeScript { param($ScriptPath, $Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); if ($Arguments.Contains('FlipAfterCleanCompare')) { 42 } else { 0 } }
}
Assert 'a refused switch reports the rerun command and leaves named values serving' ($calls.Count -eq 2 -and $Failure -match 'Deploy-ClaudeProjection.ps1' -and $Failure -match '-FlipAfterCleanCompare' -and $Failure -match 'named values keep serving') $Failure

$calls.Clear()
$null = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem -WhatIf -InvokeScript $record
Assert '-WhatIf previews the deployment only: the switch reads resources that a preview does not create' ($calls.Count -eq 1 -and $calls[0].Args.Contains('WhatIf') -and (-not $calls[0].Args.Contains('FlipAfterCleanCompare'))) ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
Invoke-ClaudeInstallerSyncJobDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup std -PremiumGroup prem `
    -AlertEmail 'ops@contoso.example' -SubscriptionId 00000000-0000-4000-8000-000000000001 -SyncInterval 30m -InvokeScript $record 6>$null | Out-Null
Assert 'the sync job gets its alert address, the tier groups, the prefix and the interval' ($calls.Count -eq 1 -and $calls[0].Path -match 'Deploy-ClaudeProjectionRenewal\.ps1$' -and
    (& $named $calls[0] '-AlertEmail') -eq 'ops@contoso.example' -and (& $named $calls[0] '-StandardGroup') -eq 'std' -and (& $named $calls[0] '-PremiumGroup') -eq 'prem' -and (& $named $calls[0] '-NamePrefix') -eq 'p98' -and
    (& $named $calls[0] '-SyncInterval') -eq '30m') ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
Invoke-ClaudeInstallerSyncJobDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup std -PremiumGroup prem `
    -AlertEmail @('ops@contoso.example', 'oncall@contoso.example') -SyncInterval 2h -AcrSku Premium `
    -WorkspaceResourceId '/subscriptions/s/resourceGroups/rg-p98/providers/Microsoft.OperationalInsights/workspaces/law-custom' `
    -RenewalSubnetId '/subscriptions/s/resourceGroups/rg-p98/providers/Microsoft.Network/virtualNetworks/vnet/subnets/renewal' -InvokeScript $record 6>$null | Out-Null
Assert 'a re-run passes the kept alert addresses, registry SKU, workspace and subnet to the deploy script' ($calls.Count -eq 1 -and
    ((@($calls[0].Args['AlertEmail'])) -join ',') -ceq 'ops@contoso.example,oncall@contoso.example' -and $calls[0].Args['AcrSku'] -ceq 'Premium' -and
    $calls[0].Args['WorkspaceResourceId'] -match '/workspaces/law-custom$' -and $calls[0].Args['RenewalSubnetId'] -match '/subnets/renewal$') ($calls | ConvertTo-Json -Depth 5)

# P104 council round 1 (Coder): a re-run keeps what the deployed job was deployed with.
$kept = [pscustomobject]@{ RenewalDeploymentState = 'Succeeded'; RegistryPublicNetworkAccess = 'Enabled'; JobResourceId = '/subscriptions/s/resourceGroups/rg-p98/providers/Microsoft.App/jobs/caj-renew-p98'; AlertEmails = @('ops@contoso.example', 'oncall@contoso.example')
    AcrSku = 'Premium'; WorkspaceResourceId = '/w/law-custom'; RenewalSubnetId = '/s/renewal' }
$jobFound = [pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-p98/providers/Microsoft.App/jobs/caj-renew-p98'; Name = 'caj-renew-p98' }
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $jobFound -JobSettings $kept -PublisherEmail 'publisher@contoso.example' }
Assert 'a re-run keeps the deployed job''s alert addresses, registry SKU, workspace and subnet' (-not $Failure -and ((@($Result.AlertEmail)) -join ',') -ceq 'ops@contoso.example,oncall@contoso.example' -and
    $Result.AcrSku -ceq 'Premium' -and $Result.WorkspaceResourceId -ceq '/w/law-custom' -and $Result.RenewalSubnetId -ceq '/s/renewal' -and $Result.AlertSource -ceq 'kept from the deployed job') "$Failure | $($Result | ConvertTo-Json -Compress)"
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $null -JobSettings $null -PublisherEmail 'publisher@contoso.example' }
Assert 'a first install alerts the publisher address with the template defaults' (-not $Failure -and ((@($Result.AlertEmail)) -join ',') -ceq 'publisher@contoso.example' -and
    -not $Result.AcrSku -and -not $Result.WorkspaceResourceId -and -not $Result.RenewalSubnetId) "$Failure | $($Result | ConvertTo-Json -Compress)"
$noReceivers = [pscustomobject]@{ RenewalDeploymentState = 'Succeeded'; RegistryPublicNetworkAccess = 'Enabled'; JobResourceId = $jobFound.Id; AlertEmails = @(); AcrSku = 'Basic'; WorkspaceResourceId = ''; RenewalSubnetId = '' }
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $jobFound -JobSettings $noReceivers -PublisherEmail 'publisher@contoso.example' }
Assert 'a deployed job with no alert address gets the publisher address, and the run says so' (-not $Failure -and ((@($Result.AlertEmail)) -join ',') -ceq 'publisher@contoso.example' -and $Result.AcrSku -ceq 'Basic' -and $Result.AlertSource -match 'action group has none') "$Failure | $($Result | ConvertTo-Json -Compress)"
$otherJob = [pscustomobject]@{ RenewalDeploymentState = 'Succeeded'; RegistryPublicNetworkAccess = 'Enabled'; JobResourceId = '/subscriptions/s/resourceGroups/rg-p98/providers/Microsoft.App/jobs/caj-renew-other'; AlertEmails = @('ops@contoso.example'); AcrSku = 'Basic'; WorkspaceResourceId = ''; RenewalSubnetId = '' }
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $jobFound -JobSettings $otherJob -PublisherEmail 'publisher@contoso.example' }
Assert 'a tagged job that the renewal deployment did not create stops the re-run' ($Failure -match 'caj-renew-p98' -and $Failure -match 'caj-renew-other' -and $Failure -match 'Nothing was changed') $Failure
$failedRenewal = [pscustomobject]@{ RenewalDeploymentState = 'Failed'; RegistryPublicNetworkAccess = 'Enabled'; JobResourceId = ''; AlertEmails = @('ops@contoso.example'); AcrSku = 'Premium'; WorkspaceResourceId = '/w/law-custom'; RenewalSubnetId = '/s/renewal' }
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $jobFound -JobSettings $failedRenewal -PublisherEmail 'publisher@contoso.example' }
Assert 'a failed renewal deployment does not read as another job; the re-run deploys it again and says so' (-not $Failure -and $Result.Note -match 'Failed' -and
    $Result.WorkspaceResourceId -ceq '/w/law-custom' -and $Result.AcrSku -ceq 'Premium') "$Failure | $($Result | ConvertTo-Json -Compress)"
$standardSku = [pscustomobject]@{ RenewalDeploymentState = 'Succeeded'; RegistryPublicNetworkAccess = 'Enabled'; JobResourceId = $jobFound.Id; AlertEmails = @('ops@contoso.example'); AcrSku = 'Standard'; WorkspaceResourceId = ''; RenewalSubnetId = '' }
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $jobFound -JobSettings $standardSku -PublisherEmail 'publisher@contoso.example' }
Assert 'a registry SKU the deploy script cannot keep stops the re-run' ($Failure -match 'Standard' -and $Failure -match 'Basic or Premium' -and $Failure -match 'Nothing was changed') $Failure
$privateRegistry = [pscustomobject]@{ RenewalDeploymentState = 'Succeeded'; RegistryPublicNetworkAccess = 'Disabled'; JobResourceId = $jobFound.Id; AlertEmails = @('ops@contoso.example'); AcrSku = 'Premium'; WorkspaceResourceId = ''; RenewalSubnetId = '' }
Capture { Resolve-ClaudeInstallerSyncJobInputs -DeployedJob $jobFound -JobSettings $privateRegistry -PublisherEmail 'publisher@contoso.example' }
Assert 'a registry with public network access disabled stops the re-run, which would open it' ($Failure -match 'public network access' -and $Failure -match '-KeepRegistry' -and $Failure -match 'Nothing was changed') $Failure

$calls.Clear()
$okSnapshot = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup 'std group' -PremiumGroup prem -CompareBaseline Snapshot -InvokeScript $record
Assert 'snapshot baseline is passed to deploy and switch, and rerun commands quote values with spaces' (
    $okSnapshot -and $calls.Count -eq 2 -and
    (& $named $calls[0] '-CompareBaseline') -eq 'Snapshot' -and (& $named $calls[1] '-CompareBaseline') -eq 'Snapshot'
) ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
$warnings = @(Invoke-ClaudeInstallerSyncJobDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup 'std group' -PremiumGroup prem `
    -AlertEmail 'ops team@contoso.example' -SubscriptionId 00000000-0000-4000-8000-000000000001 -SyncInterval 2h -InvokeScript { param($ScriptPath, $Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); 9 } 3>&1)
Assert 'a failed sync job returns false and warns with the full quoted rerun command' (($warnings -contains $false) -and (($warnings | Out-String) -match "-StandardGroup 'std group'" -and ($warnings | Out-String) -match "-SubscriptionId 00000000-0000-4000-8000-000000000001" -and ($warnings | Out-String) -match "-AlertEmail 'ops team@contoso.example'" -and ($warnings | Out-String) -match '-SyncInterval 2h')) (($warnings | Out-String) + ($calls | ConvertTo-Json -Depth 5))
$failedStep = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup 'std group' -PremiumGroup prem -SubscriptionId 00000000-0000-4000-8000-000000000001 -SyncInterval 2h -SyncJobStatus failed
$calls.Clear()
$resolverApp = '11111111-2222-4333-8444-555555555555'
$null = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem -ProjectionResolverAppId $resolverApp -InvokeScript $record
Assert 'a supplied resolver app reaches the deployer as -ResolverAppId' ($calls.Count -eq 2 -and (& $named $calls[0] '-ResolverAppId') -eq $resolverApp) ($calls | ConvertTo-Json -Depth 5)

# Every argument the installer passes reaches a parameter of the real deployer, with a value that parameter's
# fixed set allows. The live run of 2026-10-06 failed when the deployer's arguments bound by position, so
# the name prefix reached -Sku; this reads the real scripts' parameter blocks, not a copy of them.
$bindProblems = @(foreach ($call in $everyCall) {
    $command = Get-Command -Name $call.Path -CommandType ExternalScript -ErrorAction Stop
    foreach ($key in @($call.Args.Keys)) {
        $parameter = $command.Parameters[$key]
        if (-not $parameter) { "$(Split-Path $call.Path -Leaf) has no -$key"; continue }
        foreach ($set in @($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })) {
            foreach ($value in @($call.Args[$key])) { if ($set.ValidValues -notcontains [string]$value) { "$(Split-Path $call.Path -Leaf) -$key '$value' is not one of $($set.ValidValues -join ', ')" } }
        }
    }
})
$boundScripts = @($everyCall | ForEach-Object { Split-Path $_.Path -Leaf } | Sort-Object -Unique)
Assert 'every argument the installer passes is a parameter of the real deployer, with a value its set allows' (
    $everyCall.Count -ge 6 -and ($boundScripts -join ',') -eq 'Deploy-ClaudeProjection.ps1,Deploy-ClaudeProjectionRenewal.ps1' -and -not $bindProblems.Count
) "$($everyCall.Count) call(s) to $($boundScripts -join ', ') | $($bindProblems -join '; ')"
Assert 'sync-job failure next steps do not report the job as deployed and include the rerun command' ($failedStep.SyncJob.Title -match 'not deployed' -and ((@($failedStep.SyncJob.Detail) -join "`n") -match "-StandardGroup 'std group'") -and ((@($failedStep.SyncJob.Detail) -join "`n") -match '-SyncInterval 2h')) ((@($failedStep.SyncJob.Detail) -join "`n"))
# The live run of 2026-10-06 failed here: a string array splatted into a script binds by position, so the
# deployer received the name prefix as -Sku. This runs the real helper against a real script.
$probe = Join-Path ([IO.Path]::GetTempPath()) ('installer-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($probe, 'param($ResourceGroup, $ApimName, $NamePrefix, [ValidateSet(''BasicV2'',''StandardV2'',''PremiumV2'')][string]$Sku, [switch]$FlipAfterCleanCompare, [string[]]$AlertEmail) $global:InstallerProbe = "$ResourceGroup|$ApimName|$NamePrefix|$Sku|$FlipAfterCleanCompare|$($AlertEmail -join '','')"')
$global:InstallerProbe = ''
$probeCode = Invoke-ClaudeInstallerScript -ScriptPath $probe -Parameters ([ordered]@{ ResourceGroup = 'rg-p98'; ApimName = 'apim-p98'; NamePrefix = 'p98'; Sku = 'BasicV2'; FlipAfterCleanCompare = $true; AlertEmail = @('ops@contoso.example') }) 6>$null
Remove-Item -LiteralPath $probe -Force
Assert 'the installer binds each script parameter by name when it runs the real script' ($probeCode -eq 0 -and $global:InstallerProbe -eq 'rg-p98|apim-p98|p98|BasicV2|True|ops@contoso.example') "$probeCode | $global:InstallerProbe"
$installerText = [IO.File]::ReadAllText((Join-Path $root 'Install-ClaudeGateway.ps1'))
$tokens = $null; $parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$tokens, [ref]$parseErrors)
$planCall = $installerAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-ClaudeInstallerProjectionPlan' }, $true)
$whatIfStop = $installerAst.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$WhatIfPreference' -and $n.Extent.Text -match 'WhatIf - stopping before any change' }, $true)
Assert 'installer exposes a validated DeveloperCount parameter' ($installerText -match '\[ValidateRange\(1,10000000\)\]\s*\[int\]\$DeveloperCount')
Assert 'summary names an implicit migration from named values before writes' ($installerText -match 'migrating from named values: deploy, compare, switch')
Assert 'the approval summary lists the projection steps before the -WhatIf stop, so -WhatIf shows them' ($planCall -and $whatIfStop -and $planCall.Extent.StartOffset -lt $whatIfStop.Extent.StartOffset) "plan at $($planCall.Extent.StartLineNumber); stop at $($whatIfStop.Extent.StartLineNumber)"
Assert 'new projection gateways skip the named-value Sync-ClaudeAccess step' (-not (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore projection -NewGateway $true))
Assert 'named-value gateways still run Sync-ClaudeAccess' (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore 'named-value' -NewGateway $true)

$steps = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -SyncInterval none
$developer = @($steps.Developer.Detail) -join "`n"
$job = @($steps.SyncJob.Detail) -join "`n"
Assert 'the projection developer step is the group change and the targeted sync, and nothing else' (
    $steps.Developer.Title -eq 'Add or remove a developer in the projection' -and
    $developer -match 'Sync-ClaudeAccess\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -User <name-or-object-id>' -and
    $developer -match 'Entra group first' -and $developer -notmatch 'New-OnboardingEmail|Deploy-ClaudeProjectionRenewal'
) $developer
Assert 'without a sync job, its step says so and gives the deploy command with the default interval' (
    $steps.SyncJob.Title -match '^No sync job' -and $job -match 'Sync-ClaudeAccess\.ps1' -and
    $job -match "Deploy-ClaudeProjectionRenewal\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -AlertEmail '<address>' -SyncInterval 2h" -and $job -notmatch '<prefix>'
) $job
$deployed = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -SyncInterval 2h -SyncJobStatus deployed -GraphGrant missing
$deployedJob = @($deployed.SyncJob.Detail) -join "`n"
$scheduledDeveloper = @($deployed.Developer.Detail) -join "`n"
Assert 'a deployed job step names its interval, the Graph grant, how to change the interval and how to start a run' ($deployed.SyncJob.Title -match 'runs every 2 hours' -and
    $deployedJob -match 'Privileged Role Administrator or Global Administrator' -and $deployedJob -match 'Set-ClaudeProjectionSyncSchedule\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -Interval' -and
    $deployedJob -match 'az containerapp job start') $deployedJob
Assert 'with a scheduled job, a group change needs no command; the targeted sync publishes at once' ($scheduledDeveloper -match 'tier or business-unit group' -and
    $scheduledDeveloper -match 'next run, every 2 hours' -and $scheduledDeveloper -match 'within 60 seconds of that run' -and $scheduledDeveloper -match 'entitlement-cache-seconds' -and
    $scheduledDeveloper -match 'Sync-ClaudeAccess\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -User <name-or-object-id>') $scheduledDeveloper
$leftAsIs = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -SyncInterval none -DeployedJobSchedule 'every 30 minutes'
$leftJob = @($leftAsIs.SyncJob.Detail) -join "`n"
Assert 'with none and a deployed job, the step says the job was left as it is and how to change it' ($leftAsIs.SyncJob.Title -match 'left as it is' -and
    $leftJob -match 'It runs every 30 minutes' -and $leftJob -match 'Set-ClaudeProjectionSyncSchedule\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98') $leftJob
$granted = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -SyncInterval 30m -SyncJobStatus deployed -GraphGrant held
$grantedJob = @($granted.SyncJob.Detail) -join "`n"
Assert 'a job whose identity holds the grant needs no grant step' ($granted.SyncJob.Title -match 'every 30 minutes' -and $grantedJob -match 'holds Microsoft Graph GroupMember\.Read\.All' -and $grantedJob -notmatch 'Privileged Role Administrator') $grantedJob
$grantRoot = Join-Path ([IO.Path]::GetTempPath()) ('p104-grant-' + [guid]::NewGuid().ToString('N'))
$grantReceipt = Join-Path $grantRoot 'onboarding\projection-renewal-p98.json'
New-Item -ItemType Directory -Force -Path (Split-Path $grantReceipt -Parent) | Out-Null
Assert 'no job receipt reads as an unknown grant' ((Get-ClaudeInstallerSyncJobGrant -Root $grantRoot -NamePrefix p98) -ceq '')
[IO.File]::WriteAllText($grantReceipt, '{"kind":"claude-projection-renewal-receipt","graphGrant":"held"}')
Assert 'the job receipt gives the Graph grant the deployment read' ((Get-ClaudeInstallerSyncJobGrant -Root $grantRoot -NamePrefix p98) -ceq 'held')
[IO.File]::WriteAllText($grantReceipt, 'not json')
Assert 'an unreadable receipt reads as an unknown grant' ((Get-ClaudeInstallerSyncJobGrant -Root $grantRoot -NamePrefix p98) -ceq '')
[IO.File]::WriteAllText($grantReceipt, '{"graphGrant":"granted-by-hand"}')
Assert 'a grant value the deploy script does not write reads as unknown' ((Get-ClaudeInstallerSyncJobGrant -Root $grantRoot -NamePrefix p98) -ceq '')
Remove-Item -LiteralPath $grantRoot -Recurse -Force
$module = [IO.File]::ReadAllText((Join-Path $root 'scripts\ClaudeInstallProjection.ps1'))
$sendSetup = $installerText.IndexOf("Title = 'Send them the setup'")
$jobStep = $installerText.IndexOf('$nextSteps.Add($projectionSteps.SyncJob)')
Assert 'the onboarding email is only in Send them the setup, and the optional job step follows it' ($module -notmatch 'New-OnboardingEmail' -and $sendSetup -ge 0 -and $jobStep -gt $sendSetup) "send at $sendSetup; job at $jobStep"
$setupDoc = [IO.File]::ReadAllText((Join-Path $root 'docs\SETUP.md'))
$readmeDoc = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
$checkedTools = @(([regex]::Match($module, "foreach \(\`$tool in ('[a-z]+'(?:,'[a-z]+')*)\)").Groups[1].Value -replace "'", '') -split ',' | Where-Object { $_ })
$toolRows = @{ az = '\| Azure CLI \|'; node = '\| Node\.js and npm \|'; npm = '\| Node\.js and npm \|'; tar = '\| tar \|' }
Assert 'Setup lists every tool the installer checks before the projection, and PowerShell 7 for it; the README points there' (
    $checkedTools.Count -ge 4 -and @($checkedTools | Where-Object { -not $toolRows.ContainsKey($_) -or $setupDoc -notmatch $toolRows[$_] }).Count -eq 0 -and
    $setupDoc -match '\| PowerShell \| 7\+ for the Cosmos projection' -and $readmeDoc -match 'docs/SETUP\.md#tooling'
) "checked: $($checkedTools -join ',')"


# P98 council round 2 (Coder 1, Architect 2): what the installer refreshes before the projection deployment, the
# comparison baseline and the store that serves if a later step fails.
$syncCalls = [System.Collections.Generic.List[object]]::new()
$syncOk = { param($ScriptPath, $Arguments) $syncCalls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }) }
$syncOver = { param($ScriptPath, $Arguments) $syncCalls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); throw "Named value 'allow-standard' is 4441 characters, which is 345 over the API Management limit of 4096. Nothing was written." }
$syncArgs = @{ Root = $root; ResourceGroup = 'rg-p98'; ApimName = 'apim-p98'; StandardGroup = 'std'; PremiumGroup = 'prem' }
$onProjection = Invoke-ClaudeInstallerEntitlementSync @syncArgs -EntitlementStore projection -LiveEntitlementSource projection -InvokeScript $syncOk
Assert 'a re-run on a projection gateway refreshes no named values and compares with a fresh snapshot; the projection is what serves' (
    $syncCalls.Count -eq 0 -and $onProjection.CompareBaseline -eq 'Snapshot' -and $onProjection.ServingStore -eq 'projection') ($onProjection | ConvertTo-Json -Compress)
$syncCalls.Clear()
$migrating = Invoke-ClaudeInstallerEntitlementSync @syncArgs -EntitlementStore projection -LiveEntitlementSource named-value -InvokeScript $syncOk
Assert 'a migration refreshes the named-value lists explicitly and compares with them; named values serve until the switch' (
    $syncCalls.Count -eq 1 -and $syncCalls[0].Path -match 'Sync-ClaudeAccess\.ps1$' -and $syncCalls[0].Args['Store'] -eq 'named-value' -and
    $migrating.CompareBaseline -eq 'Auto' -and $migrating.ServingStore -eq 'named-value') ($migrating | ConvertTo-Json -Compress)
$syncCalls.Clear()
$overCapacity = Invoke-ClaudeInstallerEntitlementSync @syncArgs -EntitlementStore projection -LiveEntitlementSource named-value -InvokeScript $syncOver
Assert 'above named-value capacity the comparison uses a fresh snapshot, and named values are still what serves' (
    $overCapacity.CompareBaseline -eq 'Snapshot' -and $overCapacity.ServingStore -eq 'named-value' -and $overCapacity.Reason -eq 'over-capacity') ($overCapacity | ConvertTo-Json -Compress)
$syncCalls.Clear()
$newProjection = Invoke-ClaudeInstallerEntitlementSync @syncArgs -EntitlementStore projection -LiveEntitlementSource '' -NewGateway -InvokeScript $syncOk
Assert 'a new projection gateway refreshes nothing before the deployment' ($syncCalls.Count -eq 0 -and $newProjection.CompareBaseline -eq 'Auto') ($newProjection | ConvertTo-Json -Compress)
Capture { Invoke-ClaudeInstallerEntitlementSync @syncArgs -EntitlementStore named-value -LiveEntitlementSource named-value -InvokeScript { throw 'Graph read failed: 403' } }
Assert 'any other refresh failure stops the installer' ($Failure -match 'Graph read failed') $Failure

$calls.Clear()
Capture { Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public `
        -StandardGroup std -PremiumGroup prem -CompareBaseline Snapshot -ServingStore named-value -InvokeScript { param($ScriptPath, $Arguments) 7 } }
Assert 'a failed migration above capacity says named values keep serving' ($Failure -match 'named values keep serving' -and $Failure -notmatch 'projection keeps serving') $Failure
Capture { Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public `
        -StandardGroup std -PremiumGroup prem -CompareBaseline Snapshot -ServingStore projection -InvokeScript { param($ScriptPath, $Arguments) if ($Arguments.Contains('FlipAfterCleanCompare')) { 42 } else { 0 } } }
Assert 'a refused switch on a projection gateway says the projection keeps serving' ($Failure -match 'the projection keeps serving' -and $Failure -notmatch 'named values keep serving') $Failure

# P98 council round 2 (Architect 1): -EntitlementStore named-value on a gateway that serves from the projection.
Capture { Resolve-ClaudeInstallerEntitlementStore -EntitlementStore named-value -DeveloperCount 20 -BuCeiling 93 -ListCeiling 110 -Yes -LiveStore projection }
Assert 'named values on a projection gateway are refused before anything is created, naming the rollback steps' (
    $Failure -match 'serves entitlement from the projection' -and $Failure -match 'Sync-ClaudeAccess\.ps1 .*-Store named-value' -and
    $Failure -match 'Compare-ClaudeEntitlement\.ps1 .*-FailOnDrift' -and $Failure -match 'entitlement-source' -and $Failure -match 'Nothing was created') $Failure
$keepNamed = Resolve-ClaudeInstallerEntitlementStore -EntitlementStore named-value -DeveloperCount 20 -BuCeiling 93 -ListCeiling 110 -Yes -LiveStore named-value
Assert 'named values on a named-value gateway are kept' ($keepNamed.Store -eq 'named-value') ($keepNamed | ConvertTo-Json -Compress -Depth 3)

# P98 council round 2 (Architect 3): the projection a re-run touches, and the resolver access it keeps.
Assert 'the gateway''s recorded projection prefix is the one a re-run deploys' ((Get-ClaudeInstallerProjectionPrefix -RecordedPrefix 'workbook-proj' -NamePrefix 'claudegw123456') -eq 'workbook-proj')
Assert 'without a recorded prefix the installer''s own prefix is used' ((Get-ClaudeInstallerProjectionPrefix -RecordedPrefix '' -NamePrefix 'claudegw123456') -eq 'claudegw123456')
Capture { Get-ClaudeInstallerProjectionPrefix -RecordedPrefix 'Bad_Prefix' -NamePrefix 'claudegw123456' }
Assert 'a recorded prefix that is not a projection prefix stops the run' ($Failure -match 'entitlement-projection-prefix' -and $Failure -match 'Nothing was created') $Failure
# P98 confirmation round (Coder): the resolver runs on a Flex Consumption plan (infra/resolver.bicep), for which
# az functionapp show returns the raw ARM resource; a top-level publicNetworkAccess query prints nothing. These
# stubs answer as az does: only the ARM path properties.publicNetworkAccess holds the value.
$accessRead = { param($Answer, $Code) { param([string[]]$Arguments)
    $global:LASTEXITCODE = $Code
    if ($Code -ne 0) { return $Answer }
    if (($Arguments -join ' ') -match '^resource show -g rg-p98 -n func-resolver-p98 --resource-type Microsoft\.Web/sites --query properties\.publicNetworkAccess -o tsv$') { return $Answer }
    return '' }.GetNewClosure() }
Capture { Get-ClaudeInstallerResolverAccess -ResourceGroup rg-p98 -SiteName func-resolver-p98 -InvokeAz (& $accessRead 'Disabled' 0) }
Assert 'a private resolver stays private on a re-run' (-not $Failure -and $Result -eq 'private') $Failure
Capture { Get-ClaudeInstallerResolverAccess -ResourceGroup rg-p98 -SiteName func-resolver-p98 -InvokeAz (& $accessRead 'Enabled' 0) }
Assert 'a public resolver stays public on a re-run' (-not $Failure -and $Result -eq 'public') $Failure
Assert 'no resolver yet means no access to keep' ((Get-ClaudeInstallerResolverAccess -ResourceGroup rg-p98 -SiteName func-resolver-p98 -InvokeAz (& $accessRead "ERROR: (ResourceNotFound) The Resource 'Microsoft.Web/sites/func-resolver-p98' under resource group 'rg-p98' was not found." 3)) -eq '')
Capture { Get-ClaudeInstallerResolverAccess -ResourceGroup rg-p98 -SiteName func-resolver-p98 -InvokeAz (& $accessRead 'ERROR: (AuthorizationFailed) The client does not have authorization.' 1) }
Assert 'a failed read of the resolver''s access stops the run instead of defaulting to public' ($Failure -match 'Could not read' -and $Failure -match '-ResolverInboundAccess' -and $Failure -match 'Nothing was created') $Failure
Capture { Get-ClaudeInstallerResolverAccess -ResourceGroup rg-p98 -SiteName func-resolver-p98 -InvokeAz (& $accessRead '' 0) }
Assert 'a resolver that reports no network access setting stops the run' ($Failure -match '-ResolverInboundAccess' -and $Failure -match 'Nothing was created') $Failure

# P98 council round 2 (Security 1): a printed rerun command passes each value and runs nothing else when pasted.
$hostile = @('grp;calc', '@{a=calc}', ("x" + [char]0x2019 + " ;\\host\share\x.exe;#"), 'cost$center', '{team}', '-x', 'a,b', 'a"b', 'std group', "it's")
$quoteProblems = @(foreach ($value in $hostile) {
    $line = New-ClaudeInstallerCommandLine -Command '.\scripts\Deploy-ClaudeProjection.ps1' -Parameters ([ordered]@{ StandardGroup = $value; NamePrefix = 'p98' })
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
    $commands = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $elements = if ($commands.Count -eq 1) { $commands[0].CommandElements } else { @() }
    $argument = if ($elements.Count -ge 3) { $elements[2] } else { $null }
    if ($errors.Count -or $tree.EndBlock.Statements.Count -ne 1 -or $commands.Count -ne 1 -or -not ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or $argument.Value -cne $value) { "[$value] -> $line" }
})
Assert 'every rerun command value parses back as one literal argument of one command' ($quoteProblems.Count -eq 0) ($quoteProblems -join ' | ')
$emails = New-ClaudeInstallerCommandLine -Command '.\scripts\Deploy-ClaudeProjectionRenewal.ps1' -Parameters ([ordered]@{ AlertEmail = @('ops@contoso.example', 'oncall@contoso.example') })
$emailTree = [System.Management.Automation.Language.Parser]::ParseInput($emails, [ref]$null, [ref]$null)
$emailParams = @($emailTree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'AlertEmail' }, $true))
Assert 'an array value is passed once, as a list, not as a repeated parameter' ($emailParams.Count -eq 1 -and $emails -match 'ops@contoso\.example,oncall@contoso\.example') $emails

# The installer uses each of these with its live values.
$wiring = [IO.File]::ReadAllText((Join-Path $root 'Install-ClaudeGateway.ps1'))
$wiringTree = [System.Management.Automation.Language.Parser]::ParseInput($wiring, [ref]$null, [ref]$null)
function Get-CallArgument([string]$Command, [string]$Parameter) {
    $call = $wiringTree.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Command }, $true)
    if (-not $call) { return $null }
    $elements = $call.CommandElements
    for ($i = 0; $i -lt $elements.Count; $i++) {
        if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq $Parameter) {
            if ($elements[$i].Argument) { return $elements[$i].Argument.Extent.Text }
            if ($i + 1 -lt $elements.Count) { return $elements[$i + 1].Extent.Text }
        }
    }
    return $null
}
Assert 'the installer decides the sync and baseline from the live entitlement-source' ((Get-CallArgument 'Invoke-ClaudeInstallerEntitlementSync' 'LiveEntitlementSource') -eq '$liveEntitlementSource')
Assert 'the deployment gets the decided baseline, the serving store and the recorded projection prefix' (
    (Get-CallArgument 'Invoke-ClaudeInstallerProjectionDeployment' 'CompareBaseline') -match '^\$entitlementSync\.CompareBaseline$' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerProjectionDeployment' 'ServingStore') -match '^\$entitlementSync\.ServingStore$' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerProjectionDeployment' 'NamePrefix') -eq '$projectionPrefix' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerSyncJobDeployment' 'NamePrefix') -eq '$projectionPrefix' -and
    (Get-CallArgument 'Get-ClaudeInstallerProjectionNextSteps' 'NamePrefix') -eq '$projectionPrefix')
Assert 'the store choice knows the live store' ((Get-CallArgument 'Resolve-ClaudeInstallerEntitlementStore' 'LiveStore') -eq '$liveEntitlementSource')
# P104 (ADR-0058 decision 2): one interval reaches the plan, the deployment and the next steps; a re-run reads the
# deployed job only when -ProjectionSyncInterval is not given; -DeploySyncJob is accepted and decides nothing.
Assert 'the installer passes the chosen interval to the plan, the job deployment and the next steps' (
    (Get-CallArgument 'Get-ClaudeInstallerProjectionPlan' 'SyncInterval') -eq '$ProjectionSyncInterval' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerSyncJobDeployment' 'SyncInterval') -eq '$ProjectionSyncInterval' -and
    (Get-CallArgument 'Get-ClaudeInstallerProjectionNextSteps' 'SyncInterval') -eq '$ProjectionSyncInterval')
Assert 'on a re-run the installer reads the deployed job, and -ProjectionSyncInterval decides the interval' (
    (Get-CallArgument 'Resolve-ClaudeInstallerSyncInterval' 'Requested') -eq '$ProjectionSyncInterval' -and
    $wiring -match 'if \(\$ExistingApim -or \$liveApimIdForDefaults\) \{\s*\$deployedSyncJob = Get-ClaudeProjectionSyncJob' -and
    (Get-CallArgument 'Get-ClaudeProjectionSyncJob' 'NamePrefix') -eq '$projectionPrefix' -and
    (Get-CallArgument 'Get-ClaudeInstallerProjectionNextSteps' 'DeployedJobSchedule') -eq '$syncJobChoice.KeptJob')
Assert 'the job deploys unless the interval is none; -DeploySyncJob is accepted and decides nothing' (
    $wiring -match "if \(\`$ProjectionSyncInterval -ne 'none' -and -not \`$WhatIfPreference\)" -and $wiring -match '\[switch\]\$DeploySyncJob' -and
    $wiring -notmatch 'if \(\$DeploySyncJob -and' -and $wiring -match 'DeploySyncJob is no longer needed')
Assert 'the review lists the sync job choice' ($wiring -match "Insert\(\`$storeRow \+ 1, 'Sync job'")
Assert 'a re-run reads the deployed job''s settings before the review and passes them to the job deployment' (
    (Get-CallArgument 'Get-ClaudeProjectionSyncJobSettings' 'NamePrefix') -eq '$projectionPrefix' -and
    $wiring.IndexOf('Get-ClaudeProjectionSyncJobSettings') -ge 0 -and $wiring.IndexOf('Get-ClaudeProjectionSyncJobSettings') -lt $wiring.IndexOf('foreach ($k in $rows.Keys)') -and
    (Get-CallArgument 'Invoke-ClaudeInstallerSyncJobDeployment' 'AlertEmail') -eq '$syncJobInputs.AlertEmail' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerSyncJobDeployment' 'AcrSku') -eq '$syncJobInputs.AcrSku' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerSyncJobDeployment' 'WorkspaceResourceId') -eq '$syncJobInputs.WorkspaceResourceId' -and
    (Get-CallArgument 'Invoke-ClaudeInstallerSyncJobDeployment' 'RenewalSubnetId') -eq '$syncJobInputs.RenewalSubnetId' -and
    $wiring -match '\(\$\(\$syncJobInputs\.AlertSource\)\)' -and $wiring -match 'if \(\$syncJobInputs\.Note\) \{ Write-Warn2 \$syncJobInputs\.Note \}')
$earlyIntervalCheck = $wiring.IndexOf('Resolve-ClaudeInstallerSyncInterval -Requested $ProjectionSyncInterval -DeployedJob $null')
$prerequisiteCheck = $wiring.IndexOf('Test-ClaudePrerequisites -Mode Admin')
Assert 'a -ProjectionSyncInterval outside the list is refused before the prerequisite check and any Azure call' ($earlyIntervalCheck -ge 0 -and $prerequisiteCheck -gt $earlyIntervalCheck) "early check at $earlyIntervalCheck; prerequisites at $prerequisiteCheck"
Assert 'the next steps read the Graph grant from the job receipt' ((Get-CallArgument 'Get-ClaudeInstallerProjectionNextSteps' 'GraphGrant') -eq '$syncJobGrant' -and
    $wiring -match 'Get-ClaudeInstallerSyncJobGrant -Root \$root -NamePrefix \$projectionPrefix')
Assert 'the resolver access is read strictly, not through the error-swallowing helper' ($wiring -match 'Get-ClaudeInstallerResolverAccess' -and $wiring -notmatch 'Invoke-AzOptional \{ az functionapp show')

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection installer assertion(s) passed." -ForegroundColor Green
