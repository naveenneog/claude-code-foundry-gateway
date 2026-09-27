<#
.SYNOPSIS
    Shared helpers for P66 lifecycle update and change steps. Dot-sourcing this file performs no Azure writes.
#>

function global:Get-ClaudeFlowLifecycleRepoRoot {
    return (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent)
}

function global:Get-ClaudeFlowLifecycleFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

function global:Get-ClaudeFlowLifecycleStringHash {
    param([AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$Text)) | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

function global:Get-ClaudeFlowLifecyclePolicyNamedValueReferences {
    param([string]$PolicyPath = (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'infra\policy.xml'))
    if (-not (Test-Path -LiteralPath $PolicyPath)) { throw "Policy file '$PolicyPath' does not exist." }
    $text = [IO.File]::ReadAllText($PolicyPath)
    return @([regex]::Matches($text, '\{\{([^}]+)\}\}') |
        ForEach-Object { $_.Groups[1].Value.Trim() } |
        Where-Object { $_ } |
        Sort-Object -Unique)
}

function global:Get-ClaudeFlowLifecycleTemplateNamedValueDefaults {
    param([string]$BicepPath = (Join-Path (Get-ClaudeFlowLifecycleRepoRoot) 'infra\main.bicep'))
    if (-not (Test-Path -LiteralPath $BicepPath)) { throw "Bicep file '$BicepPath' does not exist." }
    $text = [IO.File]::ReadAllText($BicepPath)
    $defaults = [ordered]@{}
    foreach ($m in [regex]::Matches($text, "\{\s*key:\s*'([^']+)'\s*,\s*value:\s*([^}]+)\}")) {
        $key = $m.Groups[1].Value
        $expr = $m.Groups[2].Value.Trim()
        $value = switch -Regex ($key) {
            '^usd-budgets$' { 'e30='; break }
            '^usd-budget-state$' { 'e30='; break }
            '^(allow-standard|allow-premium|quota-overrides|models-standard|models-premium|bu-registry|bu-members|bu-parents|bu-modes)$' { ',,'; break }
            '^bu-unassigned$' { 'allow'; break }
            '^calls-per-minute$' { '120'; break }
            '^entitlement-source$' { 'named-value'; break }
            '^entitlement-resolver-url$' { 'https://resolver-not-deployed.invalid'; break }
            '^entitlement-resolver-audience$' { 'https://resolver-not-deployed.invalid'; break }
            '^entitlement-cache-seconds$' { '3600'; break }
            '^external-idp-extra-audience$' { 'urn:disabled:claude-extra-audience'; break }
            '^tpm-standard$' { '20000'; break }
            '^quota-standard$' { '500000'; break }
            '^tpm-premium$' { '80000'; break }
            '^quota-premium$' { '5000000'; break }
            '^quota-org$' { '100000000'; break }
            default { $null }
        }
        $defaults[$key] = [pscustomobject]@{ Value = $value; Expression = $expr }
    }
    return $defaults
}

function global:Get-ClaudeFlowLifecycleNamedValueMap {
    param($Discovery)
    $map = @{}
    if ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'namedValues' -and $Discovery.namedValues) {
        if ($Discovery.namedValues -is [System.Collections.IDictionary]) {
            foreach ($k in $Discovery.namedValues.Keys) { $map[[string]$k] = [string]$Discovery.namedValues[$k] }
        }
        elseif ($Discovery.namedValues -is [pscustomobject]) {
            foreach ($p in $Discovery.namedValues.PSObject.Properties) { $map[[string]$p.Name] = [string]$p.Value }
        }
        else {
            foreach ($n in @($Discovery.namedValues)) {
                if ($n.PSObject.Properties.Name -contains 'name') {
                    $map[[string]$n.name] = if ($n.PSObject.Properties.Name -contains 'value') { [string]$n.value } else { [string]$n.properties.value }
                }
                elseif ($n.PSObject.Properties.Name -contains 'displayName') {
                    $map[[string]$n.displayName] = [string]$n.value
                }
            }
        }
    }
    return $map
}

function global:Get-ClaudeFlowLifecycleRecordTarget {
    param([Parameter(Mandatory = $true)]$Record, $Discovery = $null)
    $decision = $null
    if ($Record.PSObject.Properties.Name -contains 'decisions' -and $Record.decisions -and
        $Record.decisions.PSObject.Properties.Name -contains 'foundation') {
        $decision = $Record.decisions.foundation
    }
    [pscustomobject]@{
        SubscriptionId = if ($Discovery -and $Discovery.subscriptionId) { [string]$Discovery.subscriptionId } elseif ($Record.subscriptionId) { [string]$Record.subscriptionId } elseif ($decision -and $decision.subscriptionId) { [string]$decision.subscriptionId } else { '' }
        ResourceGroup = if ($Discovery -and $Discovery.resourceGroup) { [string]$Discovery.resourceGroup } elseif ($Record.resourceGroup) { [string]$Record.resourceGroup } elseif ($decision -and $decision.resourceGroup) { [string]$decision.resourceGroup } else { '' }
        ApimName = if ($Discovery -and $Discovery.apimName) { [string]$Discovery.apimName } elseif ($Record.apimName) { [string]$Record.apimName } elseif ($decision -and $decision.apimName) { [string]$decision.apimName } else { '' }
        Location = if ($Discovery -and $Discovery.location) { [string]$Discovery.location } elseif ($Record.location) { [string]$Record.location } elseif ($decision -and $decision.location) { [string]$decision.location } else { '' }
        Sku = if ($Discovery -and $Discovery.sku) { [string]$Discovery.sku } elseif ($Record.sku) { [string]$Record.sku } elseif ($decision -and $decision.sku) { [string]$decision.sku } else { '' }
    }
}

function global:Import-ClaudeFlowLifecycleDiscovery {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Discovery fixture '$Path' does not exist." }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function global:Get-ClaudeFlowLifecycleLiveDiscovery {
    param([string]$ResourceGroup, [string]$ApimName, [string]$ApiId = 'claude-foundry')
    if (-not $ResourceGroup -or -not $ApimName) { throw 'ResourceGroup and ApimName are required for live discovery.' }
    $apim = az apim show -g $ResourceGroup -n $ApimName -o json | ConvertFrom-Json
    $nvs = az apim nv list -g $ResourceGroup --service-name $ApimName -o json | ConvertFrom-Json
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
    $policyUri = "https://management.azure.com$($apim.id)/apis/$ApiId/policies/policy?api-version=2024-05-01&format=rawxml"
    $policy = Invoke-RestMethod -Method Get -Uri $policyUri -Headers @{ Authorization = "Bearer $token" }
    [pscustomobject]@{
        subscriptionId = (($apim.id -split '/')[2])
        resourceGroup = $ResourceGroup
        apimName = $ApimName
        location = $apim.location
        sku = $apim.sku.name
        capacity = $apim.sku.capacity
        apimId = $apim.id
        policy = $policy.properties.value
        namedValues = @($nvs | Where-Object { -not $_.properties.secret } | ForEach-Object {
            [pscustomobject]@{ name = $_.name; value = $_.properties.value }
        })
    }
}

function global:Get-ClaudeFlowLifecycleApimMeterName {
    param([Parameter(Mandatory = $true)][string]$Sku)
    switch ($Sku) {
        'BasicV2' { 'Basic v2 Unit' }
        'StandardV2' { 'Standard v2 Unit' }
        'PremiumV2' { 'Premium v2 Unit' }
        default { "$Sku Unit" }
    }
}

function global:Get-ClaudeFlowLifecycleApimMonthlyCost {
    param([Parameter(Mandatory = $true)][string]$Sku, [Parameter(Mandatory = $true)][string]$Region, [int]$Units = 1)
    $root = Get-ClaudeFlowLifecycleRepoRoot
    . (Join-Path $root 'scripts\AzureRetailPrice.ps1')
    $price = Get-AzureRetailPrice -ServiceName 'API Management' -Region $Region -MeterName (Get-ClaudeFlowLifecycleApimMeterName -Sku $Sku)
    if ($price) {
        return New-ClaudeFlowCost -Item "API Management $Sku ($Units unit)" -MonthlyUsd (ConvertTo-MonthlyPrice -HourlyPrice $price.UnitPrice -Units $Units) -Source 'Azure Retail Prices API' -RetrievedUtc $price.RetrievedUtc
    }
    return New-ClaudeFlowCost -Item "API Management $Sku ($Units unit)" -Source 'Azure Retail Prices API' -UnknownReason "no retail meter found for $Sku in $Region"
}

function global:Assert-ClaudeFlowLifecycleSnapshotBeforeWrite {
    param([Parameter(Mandatory = $true)]$Plan)
    if (-not $Plan.Data -or -not $Plan.Data.SnapshotPath) { throw 'A named-value snapshot path is required before applying this lifecycle change.' }
    if ($Plan.Data.SnapshotTaken -eq $true) { return }
    $target = $Plan.Data.Target
    if (-not $target -or -not $target.ResourceGroup -or -not $target.ApimName) { throw 'Plan target is incomplete; cannot take a backup before writing.' }
    $root = Get-ClaudeFlowLifecycleRepoRoot
    & (Join-Path $root 'scripts\Backup-ClaudeGateway.ps1') -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Path $Plan.Data.SnapshotPath
    if ($LASTEXITCODE -ne 0) { throw 'Backup-ClaudeGateway.ps1 failed; no lifecycle write was attempted.' }
    $Plan.Data.SnapshotTaken = $true
}
