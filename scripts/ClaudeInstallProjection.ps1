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
        throw ("Named values hold about {0} developers in the business-unit map (about {1} in a tier list), and you declared {2}. Choose projection; raising the API Management SKU does not increase one named value's 4,096-character capacity." -f $BuCeiling, $ListCeiling, $DeveloperCount)
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
    $args = @(
        '-ResourceGroup', $ResourceGroup,
        '-ApimName', $ApimName,
        '-NamePrefix', $NamePrefix,
        '-Location', $Location,
        '-Sku', $Sku,
        '-ResolverInboundAccess', $ResolverInboundAccess,
        '-StandardGroup', $StandardGroup,
        '-PremiumGroup', $PremiumGroup,
        '-FlipAfterCleanCompare'
    )
    if ($ProjectionResolverAppId) { $args += @('-ResolverAppId', $ProjectionResolverAppId) }
    if ($SubscriptionId) { $args += @('-SubscriptionId', $SubscriptionId) }
    if ($WhatIf) { $args += '-WhatIf' }
    $exitCode = if ($InvokeScript) { & $InvokeScript $scriptPath $args } else {
        & $scriptPath @args
        $LASTEXITCODE
    }
    if ($exitCode -ne 0) {
        throw "Projection switch refused or deployment failed; named values keep serving. Rerun after fixing the reason with: .\scripts\Deploy-ClaudeProjection.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix $NamePrefix -FlipAfterCleanCompare"
    }
    return $true
}

function Invoke-ClaudeInstallerSyncJobDeployment {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix,
        [string]$SubscriptionId
    )
    $args = @('-ResourceGroup', $ResourceGroup, '-ApimName', $ApimName, '-NamePrefix', $NamePrefix)
    if ($SubscriptionId) { $args += @('-SubscriptionId', $SubscriptionId) }
    & (Join-Path $Root 'scripts\Deploy-ClaudeProjectionRenewal.ps1') @args
    if ($LASTEXITCODE -ne 0) { throw 'Optional sync job deployment failed.' }
    Write-Host 'Tenant administrator grant command: .\scripts\Grant-ClaudeProjectionRenewalGraphAccess.ps1 -ReceiptPath .\onboarding\projection-renewal-<namePrefix>.json' -ForegroundColor Yellow
}

function Test-ClaudeInstallerShouldSyncNamedValues {
    param([ValidateSet('named-value','projection')][string]$EntitlementStore, [bool]$NewGateway)
    return ($EntitlementStore -eq 'named-value' -or -not $NewGateway)
}

function Get-ClaudeInstallerProjectionNextSteps {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ApimName, [switch]$DeploySyncJob)
    $steps = @(
        "        .\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -User <name-or-object-id>",
        '        Add or remove the developer in Entra first; this targeted sync publishes the one projection record.',
        '        .\scripts\New-OnboardingEmail.ps1 -ConfigPath .\onboarding\claude-gateway.json -To dev@contoso.com'
    )
    if ($DeploySyncJob) {
        $steps += '        The optional sync job is deployed; ask a tenant administrator to grant its Graph permission before running it.'
    } else {
        $steps += "        For very large directories, deploy the optional sync job later with .\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -NamePrefix <prefix>."
    }
    return $steps
}
