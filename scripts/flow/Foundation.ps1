. (Join-Path $PSScriptRoot 'lib\LifecycleCommon.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Foundation'; Title = 'Gateway foundation'; DecisionKey = 'foundation'; DependsOn = @(); Actions = @('Setup', 'Change', 'Guide') }
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $questions = [System.Collections.Generic.List[object]]::new()
    if (-not (Get-ClaudeDecision -Record $Record -Key foundation)) {
        $questions.Add([pscustomobject]@{
            Key = 'foundation.sku'
            Question = 'Which API Management v2 tier should the gateway use?'
            Options = @(
                New-ClaudeChoiceOption -Value 'BasicV2' -Label 'Basic v2' -Detail 'Lowest-cost v2 gateway; no outbound VNet integration; use a public Entra-protected projection resolver if projection is selected.' -Recommended -Reason 'lowest-cost governed pilot and small rollout tier'
                New-ClaudeChoiceOption -Value 'StandardV2' -Label 'Standard v2' -Detail 'Adds outbound VNet integration for private resolver and enterprise network patterns.'
                New-ClaudeChoiceOption -Value 'PremiumV2' -Label 'Premium v2' -Detail 'Adds zone redundancy; use when enterprise availability requirements justify the higher cost.'
            )
            AcceptRecommendedWithoutConsole = $true
        })
        $questions.Add([pscustomobject]@{
            Key = 'foundation.entitlementStore'
            Question = 'Where should entitlement be enforced from?'
            Options = @(
                New-ClaudeChoiceOption -Value 'named-value' -Label 'Named values' -Detail 'No extra Azure components; measured ceiling is roughly 93-110 developers depending on identifiers.' -Recommended -Reason 'simplest default below the named-value ceiling'
                New-ClaudeChoiceOption -Value 'projection' -Label 'Cosmos projection' -Detail 'Scales beyond named values; adds Cosmos, resolver, sync path and resolver freshness checks.'
            )
            AcceptRecommendedWithoutConsole = $true
        })
        $questions.Add([pscustomobject]@{
            Key = 'foundation.authMode'
            Question = 'How should developers sign in?'
            Options = @(
                New-ClaudeChoiceOption -Value 'interactive' -Label 'Interactive browser' -Detail 'Best for developer laptops with a browser.' -Recommended -Reason 'default client sign-in path'
                New-ClaudeChoiceOption -Value 'device' -Label 'Device code' -Detail 'Use for jump boxes, VDI, SSH and devices without a browser.'
                New-ClaudeChoiceOption -Value 'helper' -Label 'Credential helper' -Detail 'Routes clients through the helper used by Claude Desktop.'
            )
            AcceptRecommendedWithoutConsole = $true
        })
        $questions.Add([pscustomobject]@{
            Key = 'foundation.desktopSignInKind'
            Question = 'How should Claude Desktop obtain its gateway token?'
            Options = @(
                New-ClaudeChoiceOption -Value 'helper-script' -Label 'Helper script' -Detail 'No Entra app registration; Desktop reuses Azure CLI sign-in through the shipped helper.' -Recommended -Reason 'requires no tenant consent'
                New-ClaudeChoiceOption -Value 'external-idp-browser' -Label 'External IdP browser' -Detail 'Desktop uses an Entra public-client app; needs consent review and a gateway audience.'
                New-ClaudeChoiceOption -Value 'external-idp-broker' -Label 'External IdP broker' -Detail 'Desktop uses broker sign-in on supported managed devices; needs public-client app and broker redirects.'
            )
            AcceptRecommendedWithoutConsole = $true
        })
    }
    return @($questions)
}

function Get-ClaudeFlowFoundationData {
    param($Record)
    $d = Get-ClaudeDecision -Record $Record -Key foundation
    if (-not $d) { $d = [pscustomobject]@{} }
    return $d
}

function Get-ClaudeFlowFoundationInstallerMap {
    # Install-ClaudeGateway.ps1 parameter -> foundation decision property.
    [ordered]@{
        SubscriptionId = 'subscriptionId'
        FoundryAccount = 'foundryAccount'
        FoundryResourceGroup = 'foundryResourceGroup'
        ResourceGroup = 'resourceGroup'
        Location = 'location'
        NamePrefix = 'namePrefix'
        PublisherEmail = 'publisherEmail'
        Sku = 'sku'
        EntitlementStore = 'entitlementStore'
        AuthMode = 'authMode'
        DesktopSignInKind = 'desktopSignInKind'
        DesktopEntraClientId = 'desktopEntraClientId'
        DesktopEntraIssuer = 'desktopEntraIssuer'
        DesktopEntraScopes = 'desktopEntraScopes'
        DesktopEntraAudience = 'desktopEntraAudience'
        DesktopEntraResource = 'desktopEntraResource'
        ModelOrganizationName = 'modelOrganizationName'
        ModelIndustry = 'modelIndustry'
        ModelCountryCode = 'modelCountryCode'
        TpmStandard = 'tpmStandard'
        QuotaStandard = 'quotaStandard'
        TpmPremium = 'tpmPremium'
        QuotaPremium = 'quotaPremium'
        QuotaOrg = 'quotaOrg'
        CallsPerMinute = 'callsPerMinute'
        StandardGroup = 'standardGroup'
        PremiumGroup = 'premiumGroup'
    }
}

function Get-ClaudeFlowFoundationInputs {
    # The installer inputs present on the decision. The plan carries them, so the approval
    # fingerprint binds the subscription, resource group, names and quotas it will create.
    param($Decision)
    $inputs = [ordered]@{}
    foreach ($name in (Get-ClaudeFlowFoundationInstallerMap).Values) {
        if ($Decision.PSObject.Properties.Name -contains $name -and $null -ne $Decision.$name -and [string]$Decision.$name -ne '') { $inputs[$name] = $Decision.$name }
    }
    return $inputs
}

function Get-ClaudeFlowFoundationCost {
    param([string]$Sku, [string]$Location)
    if ($Location -and -not $env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY) {
        try { return (Get-ClaudeFlowLifecycleApimMonthlyCost -Sku $Sku -Region $Location) }
        catch { return (New-ClaudeFlowCost -Item "API Management $Sku (1 unit)" -Source 'Azure Retail Prices API' -UnknownReason "price lookup failed: $($_.Exception.Message)") }
    }
    return (New-ClaudeFlowCost -Item "API Management $Sku" -Source 'Azure Retail Prices API via installer/BOM' -UnknownReason 'price is discovered during live setup for the selected region and unit count')
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $d = Get-ClaudeDecision -Record $Record -Key foundation
    if (-not $d) { $d = [pscustomobject]@{} }
    $sku = if ($d.sku) { [string]$d.sku } else { 'BasicV2' }
    $inputs = Get-ClaudeFlowFoundationInputs -Decision $d
    $existing = $Record.apimName -and $Record.resourceGroup
    $actions = if ($existing) {
        @(New-ClaudeFlowAction -Verb Check -Target "$($Record.resourceGroup)/$($Record.apimName)" -Detail 'Compare existing gateway with the recorded decisions')
    } else {
        $rg = if ($inputs.Contains('resourceGroup')) { [string]$inputs['resourceGroup'] } else { '(resource group chosen by the installer)' }
        $apim = if ($inputs.Contains('namePrefix')) { "apim-$($inputs['namePrefix'])" } else { 'apim-(name chosen by the installer)' }
        $region = if ($inputs.Contains('location')) { [string]$inputs['location'] } else { '(region chosen by the installer)' }
        $foundry = if ($inputs.Contains('foundryAccount')) { "Foundry $($inputs['foundryAccount'])$(if ($inputs.Contains('foundryResourceGroup')) { " in $($inputs['foundryResourceGroup'])" })" } else { 'Foundry account chosen by the installer' }
        $subscription = if ($inputs.Contains('subscriptionId')) { "; subscription $($inputs['subscriptionId'])" } else { '' }
        @(New-ClaudeFlowAction -Verb Create -Target "$rg/$apim" -Detail "$sku API Management in $region; $foundry$subscription")
    }
    $location = if ($inputs.Contains('location')) { [string]$inputs['location'] } else { '' }
    New-ClaudeFlowPlan -Step Foundation -Summary $(if ($existing) { 'Existing gateway foundation is recorded' } else { "Set up a $sku governed gateway" }) `
        -Actions $actions `
        -Costs @(Get-ClaudeFlowFoundationCost -Sku $sku -Location $location) `
        -Implications @('All later choices are written into one decision record and developer handover.', 'Installer implementation remains Install-ClaudeGateway.ps1.') `
        -Requires @('Azure Contributor on the gateway resource group', 'User Access Administrator or Owner on the Foundry account for the managed identity grant') `
        -Reversible $true -Rollback 'Delete or restore the resource group after taking a gateway backup' `
        -Data @{ sku = $sku; entitlementStore = $d.entitlementStore; authMode = $d.authMode; desktopSignInKind = $d.desktopSignInKind; inputs = $inputs }
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    $d = Get-ClaudeDecision -Record $Record -Key foundation
    if (-not $d) { $d = [pscustomobject]@{} }
    $installer = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Install-ClaudeGateway.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found: $installer" }
    $args = @{ Yes = $true }
    foreach ($pair in (Get-ClaudeFlowFoundationInstallerMap).GetEnumerator()) {
        $propertyName = [string]$pair.Value
        if ($d.PSObject.Properties.Name -contains $propertyName -and $d.$propertyName) { $args[$pair.Key] = $d.$propertyName }
    }
    & $installer @args
    $written = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'onboarding\claude-gateway.json'
    $changes = @{}
    if (Test-Path -LiteralPath $written) {
        $cfg = Get-Content -LiteralPath $written -Raw | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties) { $changes[$p.Name] = $p.Value }
    }
    if (-not $changes.ContainsKey('foundation')) { $changes['foundation'] = $d }
    return $changes
}

function Test-ClaudeFlowStep {
    param($Record)
    $checks = @(
        @{ Name = 'gateway URL recorded'; Passed = [bool]$Record.gatewayUrl; Evidence = [string]$Record.gatewayUrl; Fix = 'Run Start-ClaudeGateway.ps1 -Action Setup.' },
        @{ Name = 'gateway name recorded'; Passed = [bool]$Record.apimName; Evidence = [string]$Record.apimName; Fix = 'Re-run the foundation step or restore the decision record.' },
        @{ Name = 'resource group recorded'; Passed = [bool]$Record.resourceGroup; Evidence = [string]$Record.resourceGroup; Fix = 'Re-run the foundation step or restore the decision record.' }
    )
    [pscustomobject]@{ Step = 'Foundation'; Passed = (@($checks | Where-Object { -not $_.Passed }).Count -eq 0); Checks = @($checks) }
}
