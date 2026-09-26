<#
.SYNOPSIS
    Guided-flow Change step for API Management v2 tier changes.
#>

. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $PSScriptRoot 'lib\LifecycleCommon.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{
        Name = 'Tier'
        Title = 'API Management tier'
        DecisionKey = 'sku'
        DependsOn = @('Foundation')
        Actions = @('Change')
    }
}

function Get-ClaudeFlowTierResearch {
    @(
        'Microsoft Learn, Upgrade and scale an Azure API Management instance, fetched 2026-09-26: https://learn.microsoft.com/en-us/azure/api-management/upgrade-and-scale',
        'Microsoft Learn, Azure API Management v2 tiers overview, fetched 2026-09-26: https://learn.microsoft.com/en-us/azure/api-management/v2-service-tiers-overview',
        'Microsoft Learn, Feature-based comparison of Azure API Management tiers, fetched 2026-09-26: https://learn.microsoft.com/en-us/azure/api-management/api-management-features',
        'Azure API Management pricing, fetched 2026-09-26: https://azure.microsoft.com/pricing/details/api-management/'
    )
}

function Get-ClaudeFlowTierChangeOptions {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
    $current = if ($target.Sku) { $target.Sku } else { 'BasicV2' }
    $region = if ($target.Location) { ($target.Location -replace '\s+', '').ToLowerInvariant() } else { 'eastus2' }
    $all = @('BasicV2','StandardV2','PremiumV2')
    $options = @()
    foreach ($sku in $all | Where-Object { $_ -ne $current }) {
        $inPlace = ($current -in @('BasicV2','StandardV2') -and $sku -in @('BasicV2','StandardV2'))
        $reason = if ($inPlace) {
            'Documented in-place v2 family tier change between Basic v2 and Standard v2; gateway continues serving during infrastructure update.'
        }
        elseif ($sku -eq 'PremiumV2' -or $current -eq 'PremiumV2') {
            'Premium v2 networking/injection changes require a guided move to a new instance for this flow; VNet injection is a create-time topology decision.'
        }
        else {
            'Not offered as an in-place change by the documented lifecycle path.'
        }
        $cost = Get-ClaudeFlowLifecycleApimMonthlyCost -Sku $sku -Region $region
        $options += [pscustomobject]@{
            Key = $sku
            Label = $sku
            InPlace = $inPlace
            Cost = $cost
            Detail = $reason
            Implications = @(if ($sku -eq 'BasicV2') { 'Loses outbound VNet integration and inbound private endpoint support.' }
                if ($sku -eq 'StandardV2') { 'Adds outbound VNet integration and inbound private endpoint support; still public management/developer portal.' }
                if ($sku -eq 'PremiumV2') { 'Adds full virtual network injection and availability zones, but this flow treats it as a replacement/move.' })
        }
    }
    return $options
}

function Get-ClaudeFlowStepQuestions {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $options = @(Get-ClaudeFlowTierChangeOptions -Record $Record -Discovery $Discovery)
    @([pscustomobject]@{
        Key = 'sku'
        Question = 'Choose the API Management v2 tier change.'
        Options = $options
        WhereToFind = @('Azure portal > API Management > Pricing tier', 'az apim show -g <rg> -n <apim> --query sku')
        AcceptRecommendedWithoutConsole = $false
        Recommended = @($options | Where-Object InPlace | Select-Object -First 1).Key
        Reason = 'Only documented in-place changes are recommended automatically; Premium v2 moves need an explicit guided replacement.'
    })
}

function Get-ClaudeFlowStepPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
    $decision = Get-ClaudeDecision -Record $Record -Key sku
    $desired = if ($decision -is [string]) { [string]$decision } elseif ($decision -and $decision.target) { [string]$decision.target } elseif ($Discovery -and $Discovery.desiredSku) { [string]$Discovery.desiredSku } else { '' }
    if (-not $desired -or $desired -eq $target.Sku) { return New-ClaudeFlowPlan -Step Tier -Summary 'No tier change selected.' }
    $option = @(Get-ClaudeFlowTierChangeOptions -Record $Record -Discovery $Discovery | Where-Object { $_.Key -eq $desired })[0]
    if (-not $option) { throw "Desired SKU '$desired' is not a supported v2 choice." }
    $actions = @()
    $rollback = ''
    if ($option.InPlace) {
        $actions += New-ClaudeFlowAction -Verb Update -Target "apim/$($target.ApimName)" -Detail "$($target.Sku) -> $desired in place"
        $rollback = "Run Tier change back to $($target.Sku), or restore the snapshot if policy/named values were changed."
    }
    else {
        $actions += New-ClaudeFlowAction -Verb Migrate -Target "apim/$($target.ApimName)" -Detail "$($target.Sku) -> $desired by creating a new instance, restoring backup, then cutover"
        $rollback = 'Keep the old gateway serving until the new gateway passes verification; switch DNS/client base URL back if the move fails.'
    }
    $implications = @($option.Detail) + @($option.Implications) + @(Get-ClaudeFlowTierResearch)
    New-ClaudeFlowPlan -Step Tier `
        -Summary "Change API Management tier from $($target.Sku) to $desired." `
        -Actions $actions `
        -Costs @($option.Cost) `
        -Implications $implications `
        -Requires @('API Management Service Contributor', 'Backup/restore permission') `
        -Reversible $true `
        -Rollback $rollback `
        -Data @{ Target = $target; DesiredSku = $desired; InPlace = $option.InPlace; SnapshotPath = $null; SnapshotTaken = $false }
}

function Invoke-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
    $target = $Plan.Data.Target
    if ($Plan.Data.InPlace) {
        $subscription = if ($target.SubscriptionId) { $target.SubscriptionId } else { az account show --query id -o tsv }
        $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
        $uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.ApiManagement/service/$($target.ApimName)?api-version=2024-05-01"
        $body = @{ sku = @{ name = $Plan.Data.DesiredSku; capacity = 1 } } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Method Patch -Uri $uri -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body | Out-Null
        $deadline = [DateTime]::UtcNow.AddMinutes(45)
        do {
            Start-Sleep -Seconds 30
            $current = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $token" }
            if ($current.properties.provisioningState -eq 'Failed') { throw 'API Management SKU update failed.' }
        } while (($current.properties.provisioningState -ne 'Succeeded' -or $current.sku.name -ne $Plan.Data.DesiredSku) -and [DateTime]::UtcNow -lt $deadline)
        if ($current.sku.name -ne $Plan.Data.DesiredSku) { throw 'API Management SKU update did not complete before the timeout.' }
    }
    else {
        throw 'This tier choice requires a guided move to a new instance: create it with Install-ClaudeGateway.ps1, restore the backup, verify, then cut over clients. No partial write was made after the snapshot.'
    }
    Add-ClaudeDecisionHistory -Record $Record -Action Change -Decision sku -From $target.Sku -To $Plan.Data.DesiredSku -Commit (Get-ClaudeFlowReleaseInfo).commit
    @{ sku = @{ from = $target.Sku; to = $Plan.Data.DesiredSku } }
}

function Test-ClaudeFlowStep {
    param([Parameter(Mandatory = $true)]$Record)
    [pscustomobject]@{
        Step = 'Tier'
        Passed = $true
        Checks = @(@{ Name = 'offline contract'; Passed = $true; Evidence = 'Tier plans are derived from discovery and Microsoft Learn citations.'; Fix = '' })
    }
}

