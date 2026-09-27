. (Join-Path $PSScriptRoot 'lib\LifecycleCommon.ps1')

# What Install-ClaudeGateway.ps1 asks, in its order. The attended review names these (ADR-0032);
# tests/Test-FlowStart.ps1 maps every installer section that asks something to one of them.
$script:ClaudeFlowInstallerTopics = @(
    'the subscription'
    'the Foundry account and its Claude deployments'
    'the models each tier may call'
    'the resource group and region, with each v2 tier''s monthly list price'
    'whether to reuse an existing v2 gateway'
    'the developer count and the API Management tier, with its monthly list price'
    'the name prefix and publisher email'
    'the entitlement store, revocation window, team budget behaviour, developers with no team, developer address, developer sign-in and Claude Desktop sign-in'
    'the token budgets for each tier, the organisation ceiling and the request ceiling'
    'the Entra groups for each tier'
    'business units, after it deploys'
)

# What it asks when it updates a recorded gateway (-ExistingApimName): the gateway keeps its own
# region, tier, name and publisher, so those are not asked.
$script:ClaudeFlowInstallerUpdateTopics = @(
    'the Foundry account and its Claude deployments'
    'the models each tier may call'
    'the entitlement store, revocation window, team budget behaviour, developers with no team, developer address, developer sign-in and Claude Desktop sign-in'
    'the token budgets for each tier, the organisation ceiling and the request ceiling'
    'the Entra groups for each tier'
    'business units, after it deploys'
)

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{ Name = 'Foundation'; Title = 'Gateway foundation'; DecisionKey = 'foundation'; DependsOn = @(); Actions = @('Setup', 'Change', 'Guide'); AttendedFirst = $true }
}

# Install-ClaudeGateway.ps1 parameters whose values reach az as native arguments, directly or through
# the Desktop gateway audience derived from them (measured on the installer's az calls, 2026-09-27).
$script:ClaudeFlowAzBoundInstallerArgs = @(
    'SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix',
    'PublisherEmail', 'ExistingApimName', 'StandardGroup', 'PremiumGroup', 'DesktopEntraClientId', 'DesktopEntraAudience'
)

function Get-ClaudeFlowFoundationContext {
    # The orchestrator adds action and attended to discovery; a plan without them is an unattended Setup.
    param($Discovery)
    $action = if ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'action' -and $Discovery.action) { [string]$Discovery.action } else { 'Setup' }
    $attended = [bool]($Discovery -and $Discovery.PSObject.Properties.Name -contains 'attended' -and $Discovery.attended)
    $gateway = if ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'gateway') { $Discovery.gateway } else { $null }
    [pscustomobject]@{ Action = $action; Attended = $attended; Gateway = $gateway }
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $questions = [System.Collections.Generic.List[object]]::new()
    # In an attended run the installer asks these itself, with its own defaults and prices.
    if ((Get-ClaudeFlowFoundationContext -Discovery $Discovery).Attended) { return @() }
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

function Assert-ClaudeFlowInstallerArgsSafe {
    # Every installer parameter takes one value: a list or an object would be turned into text by
    # parameter binding, after any check of its parts. Values that reach az are also checked for what
    # cmd.exe re-reads, since az is a .cmd shim on Windows: & | < > ^ ( ) " % in an argument can end it
    # early or run a second command. The organisation details go to Azure in a JSON body, not to az.
    param([System.Collections.IDictionary]$InstallerArgs)
    foreach ($key in @($InstallerArgs.Keys)) {
        $value = $InstallerArgs[$key]
        if ($null -ne $value -and $value -isnot [string] -and $value -isnot [System.ValueType]) {
            throw "The foundation value -$key is a list or an object; Install-ClaudeGateway.ps1 takes one value there. Change it in the decision record or the answers file."
        }
    }
    if (-not (Test-ClaudeFlowAzCmdShim)) { return }
    foreach ($key in @($InstallerArgs.Keys | Where-Object { $_ -in $script:ClaudeFlowAzBoundInstallerArgs })) {
        $value = [string]$InstallerArgs[$key]
        if ($value -match '[&|<>^()"%\r\n]') {
            throw "The foundation value -$key '$value' holds '$($Matches[0])', which cmd.exe re-reads in an Azure CLI argument (& | < > ^ ( ) `" %), so it is not passed to Install-ClaudeGateway.ps1. Change it in the decision record or the answers file."
        }
    }
}

function Get-ClaudeFlowFoundationInstallerArgs {
    # The exact Install-ClaudeGateway.ps1 arguments. The plan carries them, so the approval
    # fingerprint binds what the installer is given (ADR-0032).
    param($Decision, [bool]$Attended, $Record = $null, [bool]$UpdateRecorded = $false)
    $installerArgs = [ordered]@{}
    if (-not $Attended) { $installerArgs['Yes'] = $true }
    # The flow's FinOps step follows the installer, so the installer does not offer it.
    $installerArgs['SkipFinOpsOffer'] = $true
    # Discovery read the gateway in this subscription, so the installer is given the same one.
    $subscription = Get-ClaudeFlowRecordSubscription -Record $Record
    if ($subscription) {
        if (-not (Test-ClaudeFlowSubscriptionId $subscription)) {
            throw "The record names the subscription '$subscription', which is not a subscription id, so discovery and Install-ClaudeGateway.ps1 could use different subscriptions. Record the id instead (az account show --query id -o tsv)."
        }
        $installerArgs['SubscriptionId'] = $subscription
    }
    $skip = @('SubscriptionId')
    if ($UpdateRecorded) {
        # -ExistingApimName takes the installer's reuse path, which adopts the gateway's own region,
        # tier, name and publisher, so none of those is passed.
        foreach ($value in @([string]$Record.apimName, [string]$Record.resourceGroup)) {
            if ($value -notmatch '^[A-Za-z0-9._-]{1,90}$') {
                throw "The recorded gateway '$([string]$Record.resourceGroup)/$([string]$Record.apimName)' has characters that cmd.exe would re-read in an Azure CLI argument, so it is not passed to Install-ClaudeGateway.ps1."
            }
        }
        $installerArgs['ExistingApimName'] = [string]$Record.apimName
        $installerArgs['ResourceGroup'] = [string]$Record.resourceGroup
        $skip += @('ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku')
    }
    # Updating in a console, the installer asks every other question; otherwise it takes the record's values.
    if (-not ($UpdateRecorded -and $Attended)) {
        foreach ($pair in (Get-ClaudeFlowFoundationInstallerMap).GetEnumerator()) {
            if ($pair.Key -in $skip) { continue }
            $name = [string]$pair.Value
            if ($Decision -and $Decision.PSObject.Properties.Name -contains $name -and $null -ne $Decision.$name -and [string]$Decision.$name -ne '') { $installerArgs[$pair.Key] = $Decision.$name }
        }
    }
    # Unattended, the installer refuses the projection without its deployer.
    if (-not $Attended -and [string]$installerArgs['EntitlementStore'] -eq 'projection') { $installerArgs['DeployProjection'] = $true }
    Assert-ClaudeFlowInstallerArgsSafe -InstallerArgs $installerArgs
    return $installerArgs
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $d = Get-ClaudeDecision -Record $Record -Key foundation
    if (-not $d) { $d = [pscustomobject]@{} }
    $context = Get-ClaudeFlowFoundationContext -Discovery $Discovery
    $sku = if ($d.sku) { [string]$d.sku } else { 'BasicV2' }
    $inputs = Get-ClaudeFlowFoundationInputs -Decision $d
    $existing = [bool]($Record.apimName -and $Record.resourceGroup)
    $location = if ($inputs.Contains('location')) { [string]$inputs['location'] } else { '' }
    $requires = @('Azure Contributor on the gateway resource group', 'User Access Administrator or Owner on the Foundry account for the managed identity grant')
    $rollback = 'Delete or restore the resource group after taking a gateway backup'
    # Setup runs the installer only when no gateway is recorded; Change foundation always; Guide never.
    $runsInstaller = ($context.Action -eq 'Change') -or ($context.Action -eq 'Setup' -and -not $existing)
    # A recorded gateway keeps its own tier and region, so its price is what is running now.
    $runningCost = {
        $liveSku = if ($context.Gateway -and $context.Gateway.sku) { [string]$context.Gateway.sku } else { $sku }
        $liveLocation = if ($context.Gateway -and $context.Gateway.location) { [string]$context.Gateway.location } else { $location }
        $cost = Get-ClaudeFlowFoundationCost -Sku $liveSku -Location $liveLocation
        $cost.Item = "$($cost.Item), already running"
        $cost
    }

    if (-not $runsInstaller) {
        $check = if ($existing) {
            New-ClaudeFlowAction -Verb Check -Target "$($Record.resourceGroup)/$($Record.apimName)" -Detail 'Compare existing gateway with the recorded decisions'
        } else {
            New-ClaudeFlowAction -Verb Check -Target 'the decision record' -Detail 'No gateway is recorded; Setup creates one'
        }
        $cost = if ($existing) { & $runningCost } else { Get-ClaudeFlowFoundationCost -Sku $sku -Location $location }
        return New-ClaudeFlowPlan -Step Foundation -Summary $(if ($existing) { 'Existing gateway foundation is recorded' } else { 'No gateway foundation is recorded' }) `
            -Actions @($check) `
            -Costs @($cost) `
            -Implications @('To change the gateway''s own settings, run .\Start-ClaudeGateway.ps1 -Action Change -Change foundation, which runs Install-ClaudeGateway.ps1 and asks its questions.') `
            -Requires $requires -Reversible $true -Rollback $rollback `
            -Data @{ sku = $sku; entitlementStore = $d.entitlementStore; authMode = $d.authMode; desktopSignInKind = $d.desktopSignInKind; inputs = $inputs; runsInstaller = $false; attended = $context.Attended; asksInConsole = $false }
    }

    # The installer runs over a recorded gateway only for Change, and then it updates that gateway.
    $updateRecorded = $existing
    $installerArgs = Get-ClaudeFlowFoundationInstallerArgs -Decision $d -Attended $context.Attended -Record $Record -UpdateRecorded $updateRecorded
    $target = "$($Record.resourceGroup)/$($Record.apimName)"
    if ($context.Attended) {
        $topics = if ($updateRecorded) { @($script:ClaudeFlowInstallerUpdateTopics) } else { @($script:ClaudeFlowInstallerTopics) }
        if ($installerArgs.Contains('SubscriptionId')) { $topics = @($topics | Where-Object { $_ -ne 'the subscription' }) }
        elseif ($updateRecorded) { $topics = @('the subscription') + $topics }
        if ($updateRecorded) {
            $summary = 'Install-ClaudeGateway.ps1 updates the recorded gateway and asks its other questions'
            $detail = "updates $target, keeping its region, tier, name and publisher; asks for " + ($topics -join '; ')
            $costs = @(& $runningCost)
            $implications = @('Install-ClaudeGateway.ps1 changes nothing until you confirm its summary.', 'The tier changes through .\Start-ClaudeGateway.ps1 -Action Change -Change sku.')
        }
        else {
            $passed = @($installerArgs.Keys | Where-Object { $_ -ne 'SkipFinOpsOffer' })
            $passing = if ($passed.Count) { '; it is given the recorded ' + (@($passed | ForEach-Object { "-$_" }) -join ', ') } else { '' }
            $summary = 'Install-ClaudeGateway.ps1 asks its own questions and sets up the gateway'
            $detail = 'asks for ' + ($topics -join '; ') + $passing
            $costs = @(New-ClaudeFlowCost -Item 'API Management' -Source 'Azure Retail Prices API, at the installer''s region and tier prompts' -UnknownReason 'chosen at the installer''s region and tier prompts, which show each monthly list price')
            $implications = @('Install-ClaudeGateway.ps1 creates nothing until you confirm its summary, which states the monthly price.', 'After the installer, the flow reads the new gateway and asks the remaining questions, priced in its region.')
        }
        return New-ClaudeFlowPlan -Step Foundation -Summary $summary `
            -Actions @(New-ClaudeFlowAction -Verb Run -Target 'Install-ClaudeGateway.ps1' -Detail $detail) `
            -Costs $costs -Implications $implications `
            -Requires $requires -Reversible $true -Rollback $rollback `
            -Data @{ sku = $d.sku; inputs = $inputs; installerArgs = $installerArgs; runsInstaller = $true; attended = $true; asksInConsole = $true }
    }

    if ($updateRecorded) {
        $actions = @(New-ClaudeFlowAction -Verb Run -Target 'Install-ClaudeGateway.ps1 -Yes' -Detail "updates $target, keeping its region, tier, name and publisher, with the recorded foundation values and the installer's defaults for the rest")
        $summary = 'Run the installer again against the recorded gateway'
        $costs = @(& $runningCost)
    } else {
        $rg = if ($inputs.Contains('resourceGroup')) { [string]$inputs['resourceGroup'] } else { '(resource group chosen by the installer)' }
        $apim = if ($inputs.Contains('namePrefix')) { "apim-$($inputs['namePrefix'])" } else { 'apim-(name chosen by the installer)' }
        $region = if ($inputs.Contains('location')) { [string]$inputs['location'] } else { '(region chosen by the installer)' }
        $foundry = if ($inputs.Contains('foundryAccount')) { "Foundry $($inputs['foundryAccount'])$(if ($inputs.Contains('foundryResourceGroup')) { " in $($inputs['foundryResourceGroup'])" })" } else { 'Foundry account chosen by the installer' }
        $subscription = if ($installerArgs.Contains('SubscriptionId')) { "; subscription $($installerArgs['SubscriptionId'])" } else { '' }
        $actions = @(New-ClaudeFlowAction -Verb Create -Target "$rg/$apim" -Detail "$sku API Management in $region; $foundry$subscription")
        $summary = "Set up a $sku governed gateway"
        $costs = @(Get-ClaudeFlowFoundationCost -Sku $sku -Location $location)
    }
    New-ClaudeFlowPlan -Step Foundation -Summary $summary `
        -Actions $actions `
        -Costs $costs `
        -Implications @('All later choices are written into one decision record and developer handover.', 'Installer implementation remains Install-ClaudeGateway.ps1, run with -Yes: it takes the recorded values and its own defaults for the rest.') `
        -Requires $requires -Reversible $true -Rollback $rollback `
        -Data @{ sku = $sku; entitlementStore = $d.entitlementStore; authMode = $d.authMode; desktopSignInKind = $d.desktopSignInKind; inputs = $inputs; installerArgs = $installerArgs; runsInstaller = $true; attended = $false; asksInConsole = $false }
}
function Get-ClaudeFlowFileStamp {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $item = Get-Item -LiteralPath $Path
    return "$($item.LastWriteTimeUtc.Ticks)/$($item.Length)"
}

function Merge-ClaudeFlowFoundationDecision {
    # The foundation decision after the installer: what it created overrides what was asked for.
    param($Decision, $Config)
    $merged = [ordered]@{}
    if ($Decision) { foreach ($p in $Decision.PSObject.Properties) { $merged[$p.Name] = $p.Value } }
    foreach ($name in 'sku', 'location', 'foundryAccount', 'foundryResourceGroup', 'resourceGroup', 'entitlementStore', 'authMode') {
        if ($Config.PSObject.Properties.Name -contains $name -and $Config.$name) { $merged[$name] = $Config.$name }
    }
    if ($Config.PSObject.Properties.Name -contains 'desktopSignIn' -and $Config.desktopSignIn -and $Config.desktopSignIn.kind) { $merged['desktopSignInKind'] = [string]$Config.desktopSignIn.kind }
    return [pscustomobject]$merged
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    $d = Get-ClaudeDecision -Record $Record -Key foundation
    if (-not $d) { $d = [pscustomobject]@{} }
    # A recorded gateway is checked, not installed again; discovery has compared it with Azure.
    if (-not ($Plan -and $Plan.Data -and $Plan.Data.runsInstaller)) { return @{ foundation = $d } }
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $installer = Join-Path $repo 'Install-ClaudeGateway.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found: $installer" }
    $written = Join-Path $repo 'onboarding\claude-gateway.json'
    $installerArgs = @{}
    foreach ($key in @($Plan.Data.installerArgs.Keys)) { $installerArgs[[string]$key] = $Plan.Data.installerArgs[$key] }
    $before = Get-ClaudeFlowFileStamp -Path $written
    & $installer @installerArgs
    if (-not (Test-Path -LiteralPath $written) -or (Get-ClaudeFlowFileStamp -Path $written) -eq $before) {
        # A cancellation, not a fault: the orchestrator reports it without a stack trace.
        throw [System.OperationCanceledException]::new('Install-ClaudeGateway.ps1 finished without writing onboarding\claude-gateway.json, so it created nothing: it was cancelled at its summary or stopped before deploying. The guided flow stopped before the remaining steps; run it again when ready.')
    }
    $cfg = Get-Content -LiteralPath $written -Raw | ConvertFrom-Json
    $changes = @{}
    foreach ($p in $cfg.PSObject.Properties) { $changes[$p.Name] = $p.Value }
    $changes['foundation'] = Merge-ClaudeFlowFoundationDecision -Decision $d -Config $cfg
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
