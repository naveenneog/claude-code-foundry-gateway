function New-ClaudeInstallerChoiceOption {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Label,
        [string]$Detail,
        [switch]$Recommended,
        [string]$Reason
    )
    if (Get-Command New-ClaudeChoiceOption -ErrorAction SilentlyContinue) {
        return New-ClaudeChoiceOption -Value $Value -Label $Label -Detail $Detail -Recommended:$Recommended -Reason $Reason
    }
    [pscustomobject]@{ Value = $Value; Label = $Label; Detail = $Detail; Recommended = [bool]$Recommended; Reason = $Reason }
}

function Resolve-ClaudeInstallerEntitlementStore {
    param(
        [ValidateSet('named-value','projection')][string]$EntitlementStore,
        [Parameter(Mandatory)][int]$DeveloperCount,
        [Parameter(Mandatory)][int]$BuCeiling,
        [Parameter(Mandatory)][int]$ListCeiling,
        [switch]$Yes,
        [scriptblock]$Selector
    )
    $options = @(
        New-ClaudeInstallerChoiceOption -Value 'projection' -Label 'Cosmos projection (recommended)' `
            -Detail 'Deploys the private Cosmos entitlement store, resolver and switch. This is the default path for every team size.' `
            -Recommended -Reason 'recommended default for new gateways'
        New-ClaudeInstallerChoiceOption -Value 'named-value' -Label 'Named values' `
            -Detail ("No Cosmos components. Intended for small teams only: about {0} developers in business-unit membership and about {1} per tier list." -f $BuCeiling, $ListCeiling) `
            -Reason 'small-team fallback when you do not want Cosmos components'
    )
    $store = $EntitlementStore
    if (-not $store) {
        if ($Yes) { $store = 'projection' }
        elseif ($Selector) { $store = & $Selector $options }
        else { $store = 'projection' }
    }
    if ($store -eq 'named-value' -and $DeveloperCount -gt $BuCeiling) {
        throw ("Named values hold about {0} developers in the business-unit map (about {1} in a tier list), and you declared {2}. Choose projection; raising the API Management SKU does not increase one named value's 4,096-character capacity. Nothing was created." -f $BuCeiling, $ListCeiling, $DeveloperCount)
    }
    [pscustomobject]@{ Store = $store; DeployProjection = ($store -eq 'projection'); Options = $options }
}

function Resolve-ClaudeInstallerResolverInboundAccess {
    param(
        [Parameter(Mandatory)][ValidateSet('BasicV2','StandardV2','PremiumV2')][string]$Sku,
        [Parameter(Mandatory)][ValidateSet('named-value','projection')][string]$EntitlementStore,
        [AllowEmptyString()][ValidateSet('private','public','')][string]$Requested
    )
    if ($EntitlementStore -ne 'projection') {
        return [pscustomobject]@{ Access = $(if ($Requested) { $Requested } else { 'private' }); Message = '' }
    }
    $access = if ($Requested) { $Requested } else { 'public' }
    if ($Sku -eq 'BasicV2' -and $access -eq 'private') {
        throw 'BasicV2 cannot use a private resolver because Basic v2 has no outbound VNet integration. Use -ResolverInboundAccess public or choose StandardV2/PremiumV2. Nothing was created.'
    }
    $message = if ($access -eq 'private') {
        'Projection resolver: private endpoint. Prerequisite: gateway outbound VNet integration into the projection network; Microsoft Learn integrate-vnet-outbound, updated 2025-12-04, documents outbound VNet integration for Standard v2 and Premium v2.'
    } else {
        'Projection resolver: public, Entra-authenticated endpoint. The resolver accepts only the gateway managed identity token; Cosmos remains private.'
    }
    [pscustomobject]@{ Access = $access; Message = $message }
}

function Assert-ClaudeInstallerProjectionPrerequisites {
    param(
        [int]$PowerShellMajor = $PSVersionTable.PSVersion.Major,
        [scriptblock]$CommandExists = { param($Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
    )
    if ($PowerShellMajor -lt 7) {
        throw 'Projection deployment requires PowerShell 7. Remedy: rerun this installer in pwsh.'
    }
    foreach ($tool in 'az','node','npm','tar') {
        if (-not (& $CommandExists $tool)) {
            $remedy = switch ($tool) {
                'az' { 'Install Azure CLI, then rerun.' }
                'node' { 'Install node (Node.js), then rerun.' }
                'npm' { 'Install npm with Node.js, then rerun.' }
                'tar' { 'Install tar or run on a shell where tar is on PATH, then rerun.' }
            }
            throw "Projection deployment requires $tool before any Azure write. Remedy: $remedy"
        }
    }
}

function Get-ClaudeInstallerProjectionPlan {
    param([switch]$WhatIf, [switch]$DeploySyncJob)
    $steps = @(
        'Check projection prerequisites',
        'Deploy projection resources',
        'Populate and compare the projection',
        'Switch entitlement-source to projection'
    )
    if ($DeploySyncJob) { $steps += 'Deploy optional sync job' }
    [pscustomobject]@{ Steps = $steps; Writes = $(if ($WhatIf) { @() } else { $steps }) }
}

# Runs one repository script the way the installer does: its output goes to the console, a thrown
# refusal becomes exit 1 with its message shown. Tests pass -InvokeScript to record the call instead.
function Invoke-ClaudeInstallerScript {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string[]]$Arguments, [scriptblock]$InvokeScript)
    if ($InvokeScript) { return [int](& $InvokeScript $ScriptPath $Arguments) }
    try { & $ScriptPath @Arguments | Out-Host; return 0 }
    catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor Red; return 1 }
}

# Choosing projection deploys it, then switches the gateway (ADR-0052, P98). The deployer deploys,
# populates and compares and leaves named values serving; its -FlipAfterCleanCompare run deploys nothing
# and switches only after the resolver checks, the compare and switch evidence (ADR-0051).
function Invoke-ClaudeInstallerProjectionDeployment {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidateSet('BasicV2','StandardV2','PremiumV2')][string]$Sku,
        [Parameter(Mandatory)][ValidateSet('private','public')][string]$ResolverInboundAccess,
        [Parameter(Mandatory)][string]$StandardGroup,
        [Parameter(Mandatory)][string]$PremiumGroup,
        [string]$SubscriptionId,
        [string]$ProjectionResolverAppId,
        [switch]$WhatIf,
        [scriptblock]$InvokeScript
    )
    $scriptPath = Join-Path $Root 'scripts\Deploy-ClaudeProjection.ps1'
    $common = @('-ResourceGroup', $ResourceGroup, '-ApimName', $ApimName, '-NamePrefix', $NamePrefix, '-StandardGroup', $StandardGroup, '-PremiumGroup', $PremiumGroup)
    if ($SubscriptionId) { $common += @('-SubscriptionId', $SubscriptionId) }
    $deployArguments = $common + @('-Location', $Location, '-Sku', $Sku, '-ResolverInboundAccess', $ResolverInboundAccess)
    if ($ProjectionResolverAppId) { $deployArguments += @('-ResolverAppId', $ProjectionResolverAppId) }
    if ($WhatIf) {
        if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Arguments ($deployArguments + '-WhatIf') -InvokeScript $InvokeScript) -ne 0) {
            throw 'The projection deployment preview failed; nothing was created.'
        }
        Write-Host '    WhatIf: the switch follows the deployment; it reads the deployed resolver and Cosmos account, so a preview does not run it.' -ForegroundColor DarkGray
        return $true
    }
    $deployRerun = ".\scripts\Deploy-ClaudeProjection.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -Location $Location -Sku $Sku -ResolverInboundAccess $ResolverInboundAccess -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup"
    if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Arguments $deployArguments -InvokeScript $InvokeScript) -ne 0) {
        throw "Projection deployment failed; named values keep serving and nothing was switched. Rerun after fixing the reason with: $deployRerun"
    }
    if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Arguments ($common + '-FlipAfterCleanCompare') -InvokeScript $InvokeScript) -ne 0) {
        throw "Projection switch refused; named values keep serving. Rerun after fixing the reason with: .\scripts\Deploy-ClaudeProjection.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -FlipAfterCleanCompare"
    }
    return $true
}

# The optional sync job (ADR-0051) is deployed after the switch. A failure leaves the projection and the
# switch as they are, so it is reported with the rerun command rather than ending the install.
function Invoke-ClaudeInstallerSyncJobDeployment {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$StandardGroup,
        [Parameter(Mandatory)][string]$PremiumGroup,
        [Parameter(Mandatory)][string]$AlertEmail,
        [string]$SubscriptionId,
        [scriptblock]$InvokeScript
    )
    $jobArguments = @('-ResourceGroup', $ResourceGroup, '-ApimName', $ApimName, '-NamePrefix', $NamePrefix,
        '-StandardGroup', $StandardGroup, '-PremiumGroup', $PremiumGroup, '-AlertEmail', $AlertEmail)
    if ($SubscriptionId) { $jobArguments += @('-SubscriptionId', $SubscriptionId) }
    $scriptPath = Join-Path $Root 'scripts\Deploy-ClaudeProjectionRenewal.ps1'
    if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Arguments $jobArguments -InvokeScript $InvokeScript) -ne 0) {
        Write-Warning "The optional sync job was not deployed; the projection and the switch are unaffected. Rerun: .\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -AlertEmail $AlertEmail"
        return $false
    }
    return $true
}
function Test-ClaudeInstallerShouldSyncNamedValues {
    param([ValidateSet('named-value','projection')][string]$EntitlementStore, [bool]$NewGateway)
    return ($EntitlementStore -eq 'named-value' -or -not $NewGateway)
}

function Get-ClaudeInstallerProjectionNextSteps {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ApimName, [Parameter(Mandatory)][string]$NamePrefix, [switch]$DeploySyncJob)
    $steps = @(
        "        .\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -User <name-or-object-id>",
        '        Add or remove the developer in the Entra group first; this targeted sync publishes that one projection record.',
        '        .\scripts\New-OnboardingEmail.ps1 -ConfigPath .\onboarding\claude-gateway.json -To dev@contoso.com'
    )
    if ($DeploySyncJob) {
        $steps += '        The optional sync job is deployed. A Privileged Role Administrator or Global Administrator grants its Microsoft Graph permission with the command the deployment printed; then start it with az containerapp job start.'
    } else {
        $steps += "        For very large directories, the optional sync job reads Microsoft Graph inside the network: .\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -AlertEmail <address>"
    }
    return $steps
}