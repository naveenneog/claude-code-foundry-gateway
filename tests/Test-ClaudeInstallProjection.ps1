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

$whatIf = Get-ClaudeInstallerProjectionPlan -WhatIf -DeploySyncJob
Assert '-WhatIf lists projection deployment, populate, compare, switch and optional job' (
    (($whatIf.Steps -join '|') -match 'Deploy projection resources' -and
     ($whatIf.Steps -join '|') -match 'Populate and compare' -and
     ($whatIf.Steps -join '|') -match 'Switch entitlement-source to projection' -and
     ($whatIf.Steps -join '|') -match 'Deploy optional sync job') -and -not $whatIf.Writes
) ($whatIf | ConvertTo-Json -Depth 4)

$calls = [System.Collections.Generic.List[object]]::new()
$record = { param($ScriptPath, $Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); 0 }
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
    -AlertEmail 'ops@contoso.example' -SubscriptionId 00000000-0000-4000-8000-000000000001 -InvokeScript $record 6>$null | Out-Null
Assert 'the optional sync job gets its alert address, the tier groups and the prefix' ($calls.Count -eq 1 -and $calls[0].Path -match 'Deploy-ClaudeProjectionRenewal\.ps1$' -and
    (& $named $calls[0] '-AlertEmail') -eq 'ops@contoso.example' -and (& $named $calls[0] '-StandardGroup') -eq 'std' -and (& $named $calls[0] '-PremiumGroup') -eq 'prem' -and (& $named $calls[0] '-NamePrefix') -eq 'p98') ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
$okSnapshot = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup 'std group' -PremiumGroup prem -CompareBaseline Snapshot -InvokeScript $record
Assert 'snapshot baseline is passed to deploy and switch, and rerun commands quote values with spaces' (
    $okSnapshot -and $calls.Count -eq 2 -and
    (& $named $calls[0] '-CompareBaseline') -eq 'Snapshot' -and (& $named $calls[1] '-CompareBaseline') -eq 'Snapshot'
) ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
$warnings = @(Invoke-ClaudeInstallerSyncJobDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup 'std group' -PremiumGroup prem `
    -AlertEmail 'ops team@contoso.example' -SubscriptionId 00000000-0000-4000-8000-000000000001 -InvokeScript { param($ScriptPath, $Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); 9 } 3>&1)
Assert 'a failed optional sync job returns false and warns with the full quoted rerun command' (($warnings -contains $false) -and (($warnings | Out-String) -match "-StandardGroup 'std group'" -and ($warnings | Out-String) -match "-SubscriptionId 00000000-0000-4000-8000-000000000001" -and ($warnings | Out-String) -match "-AlertEmail 'ops team@contoso.example'")) (($warnings | Out-String) + ($calls | ConvertTo-Json -Depth 5))
$failedStep = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup 'std group' -PremiumGroup prem -SubscriptionId 00000000-0000-4000-8000-000000000001 -SyncJobStatus failed
Assert 'sync-job failure next steps do not report the job as deployed and include the rerun command' ($failedStep.SyncJob.Title -match 'not deployed' -and ((@($failedStep.SyncJob.Detail) -join "`n") -match "-StandardGroup 'std group'")) ((@($failedStep.SyncJob.Detail) -join "`n"))
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

$steps = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -DeploySyncJob:$false
$developer = @($steps.Developer.Detail) -join "`n"
$job = @($steps.SyncJob.Detail) -join "`n"
Assert 'the projection developer step is the group change and the targeted sync, and nothing else' (
    $steps.Developer.Title -eq 'Add or remove a developer in the projection' -and
    $developer -match 'Sync-ClaudeAccess\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -User <name-or-object-id>' -and
    $developer -match 'Entra group first' -and $developer -notmatch 'New-OnboardingEmail|Deploy-ClaudeProjectionRenewal'
) $developer
Assert 'the optional sync job is its own step, with the full deploy command' (
    $steps.SyncJob.Title -match '^Optional' -and
    $job -match 'very large directories' -and
    $job -match 'Deploy-ClaudeProjectionRenewal\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -AlertEmail' -and $job -notmatch '<prefix>'
) $job
$deployed = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -DeploySyncJob
$deployedJob = @($deployed.SyncJob.Detail) -join "`n"
Assert 'a deployed sync job step names the Graph grant and how to start the job' ($deployedJob -match 'Privileged Role Administrator or Global Administrator' -and $deployedJob -match 'az containerapp job start') $deployedJob
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

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection installer assertion(s) passed." -ForegroundColor Green
