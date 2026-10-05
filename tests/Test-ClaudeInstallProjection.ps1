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

Capture { Resolve-ClaudeInstallerEntitlementStore -DeveloperCount 94 -BuCeiling 93 -ListCeiling 110 -EntitlementStore 'named-value' -Yes }
Assert 'named values above the computed business-unit ceiling are refused' ($Failure -match 'Named values hold about 93 developers' -and $Failure -match 'choose projection') $Failure

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
$record = { param($ScriptPath, [string[]]$Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); 0 }
$ok = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem -SubscriptionId 00000000-0000-4000-8000-000000000001 `
    -InvokeScript $record
$named = { param($Call, $Name) $i = [array]::IndexOf([string[]]$Call.Args, $Name); if ($i -ge 0) { [string]$Call.Args[$i + 1] } }
Assert 'choosing projection deploys, populates and compares first, then switches in a second run of the deployer' (
    $ok -and $calls.Count -eq 2 -and
    ($calls[0].Path -match 'Deploy-ClaudeProjection\.ps1$') -and ($calls[1].Path -match 'Deploy-ClaudeProjection\.ps1$') -and
    ($calls[0].Args -notcontains '-FlipAfterCleanCompare') -and ($calls[1].Args -contains '-FlipAfterCleanCompare') -and
    (& $named $calls[0] '-Sku') -eq 'BasicV2' -and (& $named $calls[0] '-ResolverInboundAccess') -eq 'public' -and (& $named $calls[0] '-Location') -eq 'eastus2' -and
    (& $named $calls[1] '-NamePrefix') -eq 'p98' -and (& $named $calls[1] '-StandardGroup') -eq 'std' -and (& $named $calls[1] '-PremiumGroup') -eq 'prem' -and
    -not @($calls | ForEach-Object { $_.Args } | Where-Object { $_ -match 'Renewal|^-ReconcilerResourceId$' }).Count
) ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
Capture {
    Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
        -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem `
        -InvokeScript { param($ScriptPath, [string[]]$Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); 7 }
}
Assert 'a failed deployment runs no switch and names the deployment rerun; named values keep serving' ($calls.Count -eq 1 -and $Failure -match 'Deploy-ClaudeProjection\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98' -and $Failure -notmatch '-FlipAfterCleanCompare' -and $Failure -match 'named values keep serving') "$Failure | calls $($calls.Count)"

$calls.Clear()
Capture {
    Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
        -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem `
        -InvokeScript { param($ScriptPath, [string[]]$Arguments) $calls.Add([pscustomobject]@{ Path = $ScriptPath; Args = $Arguments }); if ($Arguments -contains '-FlipAfterCleanCompare') { 42 } else { 0 } }
}
Assert 'a refused switch reports the rerun command and leaves named values serving' ($calls.Count -eq 2 -and $Failure -match 'Deploy-ClaudeProjection.ps1' -and $Failure -match '-FlipAfterCleanCompare' -and $Failure -match 'named values keep serving') $Failure

$calls.Clear()
$null = Invoke-ClaudeInstallerProjectionDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 `
    -Location eastus2 -Sku BasicV2 -ResolverInboundAccess public -StandardGroup std -PremiumGroup prem -WhatIf -InvokeScript $record
Assert '-WhatIf previews the deployment only: the switch reads resources that a preview does not create' ($calls.Count -eq 1 -and ($calls[0].Args -contains '-WhatIf') -and ($calls[0].Args -notcontains '-FlipAfterCleanCompare')) ($calls | ConvertTo-Json -Depth 5)

$calls.Clear()
Invoke-ClaudeInstallerSyncJobDeployment -Root $root -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -StandardGroup std -PremiumGroup prem `
    -AlertEmail 'ops@contoso.example' -SubscriptionId 00000000-0000-4000-8000-000000000001 -InvokeScript $record 6>$null | Out-Null
Assert 'the optional sync job gets its alert address, the tier groups and the prefix' ($calls.Count -eq 1 -and $calls[0].Path -match 'Deploy-ClaudeProjectionRenewal\.ps1$' -and
    (& $named $calls[0] '-AlertEmail') -eq 'ops@contoso.example' -and (& $named $calls[0] '-StandardGroup') -eq 'std' -and (& $named $calls[0] '-PremiumGroup') -eq 'prem' -and (& $named $calls[0] '-NamePrefix') -eq 'p98') ($calls | ConvertTo-Json -Depth 5)
Assert 'new projection gateways skip the named-value Sync-ClaudeAccess step' (-not (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore projection -NewGateway $true))
Assert 'named-value gateways still run Sync-ClaudeAccess' (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore 'named-value' -NewGateway $true)

$steps = Get-ClaudeInstallerProjectionNextSteps -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -DeploySyncJob:$false
Assert 'projection next steps name targeted Sync-ClaudeAccess and developer setup' (
    ($steps -join "`n") -match 'Sync-ClaudeAccess\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -User <name-or-object-id>' -and
    ($steps -join "`n") -match 'New-OnboardingEmail\.ps1' -and
    ($steps -join "`n") -match 'very large directories' -and
    ($steps -join "`n") -match 'Deploy-ClaudeProjectionRenewal\.ps1 -ResourceGroup rg-p98 -ApimName apim-p98 -NamePrefix p98 -AlertEmail' -and ($steps -join "`n") -notmatch '<prefix>'
) ($steps -join "`n")

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count projection installer assertion(s) passed." -ForegroundColor Green
