<#
.SYNOPSIS
    Deploys the scheduled projection renewal job: registry, image, job and alerts (ADR-0049).

.DESCRIPTION
    Runs after scripts/Deploy-ClaudeProjection.ps1, in the same resource group, and reads that
    deployment's outputs: the Cosmos account and the projection network with its renewal subnet.
    Three phases, each safe to rerun:

      1. infra/projection-registry.bicep: the registry, the job's user-assigned identity and its
         AcrPull grant.
      2. az acr build from the sync package (scripts/ClaudeProjectionPackage.ps1), then the image
         digest read back with az acr manifest show-metadata. -ImageDigest skips this phase.
      3. infra/projection-renewal.bicep: the internal Container Apps environment on the renewal
         subnet, the job pinned to the digest, its Cosmos and named-value grants, the action group
         and the alerts.

    It then prints the tenant administrator's Graph grant and the email confirmation step, and
    writes a receipt with no secrets for the switch (P95). It never grants Graph access and never
    changes entitlement-source.

.PARAMETER AlertEmail
    Email addresses for the renewal alerts. Each one receives a confirmation from Azure Monitor.

.PARAMETER StandardGroup
    The standard tier group: an object id, or a display name resolved to one through Graph.

.PARAMETER PremiumGroup
    The premium tier group, as for StandardGroup, or none when the gateway has no premium tier.

.PARAMETER ImageDigest
    A sha256 digest of an image already pushed to the registry as claude-projection-sync. Skips the
    build, for example after a docker build and push.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup <rg> `
      -ApimName <apim> -NamePrefix <prefix> -AlertEmail ops@contoso.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$NamePrefix,
    [Parameter(Mandatory = $true)][string[]]$AlertEmail,
    [string]$SubscriptionId,
    [string]$GatewayResourceGroup,
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [ValidateSet('Basic', 'Premium')][string]$AcrSku = 'Basic',
    [string]$CronExpression = '*/30 * * * *',
    [string]$ImageTag,
    [string]$ImageDigest,
    [string]$WorkspaceResourceId,
    [string]$RenewalSubnetId,
    [string]$ReceiptPath,
    [ValidateRange(1, 10)][int]$RetryCount = 3,
    [ValidateRange(0, 300)][int]$RetryDelaySeconds = 30
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')
Assert-ClaudeProjectionPowerShell

$guid = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$entryPoint = 'node /app/sync/src/apply-projection.mjs'
$repository = 'claude-projection-sync'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Note($m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Ok($m) { Write-Host "    [OK]   $m" -ForegroundColor Green }

# Every value that reaches an az argument is checked before the first Azure call: on Windows az is
# az.cmd, and cmd.exe re-reads & | < > ^ ( ) in its arguments. Values for ARM go in parameter files.
$problems = [Collections.Generic.List[string]]::new()
if (-not $GatewayResourceGroup) { $GatewayResourceGroup = $ResourceGroup }
foreach ($pair in @(@('-ResourceGroup', $ResourceGroup), @('-GatewayResourceGroup', $GatewayResourceGroup))) {
    if ($pair[1] -notmatch '^[A-Za-z0-9._-]{1,90}$') { $problems.Add("$($pair[0]) '$($pair[1])' is not 1-90 letters, digits, '.', '_' or '-'; other characters are refused before an az call.") }
}
if ($ApimName -notmatch '^[A-Za-z0-9-]{1,50}$') { $problems.Add("-ApimName '$ApimName' is not an API Management name.") }
if ($NamePrefix -cnotmatch '^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){0,36}$') { $problems.Add("-NamePrefix '$NamePrefix' is not the projection prefix: 1-37 lowercase letters or digits, with single hyphens inside.") }
if ($SubscriptionId -and $SubscriptionId -notmatch $guid) { $problems.Add('-SubscriptionId is not a subscription id.') }
$emails = @($AlertEmail | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $emails.Count) { $problems.Add('-AlertEmail needs at least one address: without one the alerts notify no one and admission refuses the switch.') }
foreach ($email in $emails) {
    if ($email -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$') { $problems.Add("-AlertEmail '$email' is not an email address.") }
}
if ([string]::IsNullOrWhiteSpace($StandardGroup) -or $StandardGroup -eq 'none') { $problems.Add('-StandardGroup is required: the job reads its members on every run.') }
if ([string]::IsNullOrWhiteSpace($PremiumGroup)) { $problems.Add('-PremiumGroup is a group or none.') }
if ($CronExpression -notmatch '^[0-9*/,-]+( [0-9*/,-]+){4}$') { $problems.Add("-CronExpression '$CronExpression' is not five cron fields.") }
if (-not $ImageTag) { $ImageTag = 'sync-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') }
if ($ImageTag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { $problems.Add("-ImageTag '$ImageTag' is not an image tag.") }
if ($ImageDigest -and $ImageDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { $problems.Add('-ImageDigest is not sha256: followed by 64 lowercase hex digits.') }
if ($WorkspaceResourceId -and $WorkspaceResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') { $problems.Add('-WorkspaceResourceId is not a Log Analytics workspace resource id.') }
if ($RenewalSubnetId -and $RenewalSubnetId -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$') { $problems.Add('-RenewalSubnetId is not a subnet resource id.') }
if ($problems.Count) { throw ("Projection renewal refused before any Azure call:`n  - " + ($problems -join "`n  - ")) }
if (-not $ReceiptPath) { $ReceiptPath = Join-Path $root "onboarding/projection-renewal-$NamePrefix.json" }

function Invoke-WithRetry {
    # The action runs in this function's scope, so this parameter is not called Name: the
    # deployment actions read their caller's $Name.
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Label)
    for ($i = 1; $i -le $RetryCount; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $RetryCount) { throw }
            Write-Warning "$Label failed on attempt $i/${RetryCount}: $($_.Exception.Message) Retrying in $RetryDelaySeconds s."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Get-DeploymentOutput([string]$Name) {
    $outputs = Invoke-ClaudeNetworkAz @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $Name, '--query', 'properties.outputs')
    if (-not $outputs) { throw "Deployment $Name in $ResourceGroup returned no outputs." }
    $values = @{}
    foreach ($property in $outputs.PSObject.Properties) { $values[$property.Name] = $property.Value.value }
    return $values
}

function New-ParameterFile([hashtable]$Values) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('claude-renewal-params-' + [guid]::NewGuid().ToString('N') + '.json')
    $parameters = [ordered]@{}
    foreach ($key in $Values.Keys) { $parameters[$key] = @{ value = $Values[$key] } }
    $document = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters }
    [IO.File]::WriteAllText($path, ($document | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-Deployment([string]$Name, [string]$Template, [hashtable]$Values) {
    $file = New-ParameterFile $Values
    try {
        Invoke-WithRetry -Label "$Name deployment" -Action {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $output = & az deployment group create -g $ResourceGroup -n $Name --template-file (Join-Path $root $Template) --parameters "@$file" --only-show-errors -o none 2>&1 | Out-String
            $code = $LASTEXITCODE
            $ErrorActionPreference = $previous
            if ($code -ne 0) { throw "$Name deployment failed (az exit $code): $($output.Trim())" }
        }
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    return Get-DeploymentOutput $Name
}

function Resolve-TierGroup([string]$Group, [string]$Tier) {
    if ($Tier -eq 'premium' -and $Group -eq 'none') { return 'none' }
    if ($Group -match $guid) { return $Group.ToLowerInvariant() }
    $found = Get-ClaudeGraphGroup -GroupName $Group -Token $script:graphToken
    if (-not $found) { throw "The $Tier tier group '$Group' was not found in Microsoft Graph. Pass its object id, or -PremiumGroup none when the gateway has no premium tier." }
    return ([string]$found.id).ToLowerInvariant()
}

Step 'Read the projection, the gateway and the workspace'
$account = Invoke-ClaudeNetworkAz @('account', 'show')
if (-not $account -or -not $account.id) { throw 'Not signed in to Azure CLI. Run az login, then rerun.' }
if ($SubscriptionId -and $account.id -ne $SubscriptionId) { throw "The Azure CLI subscription is $($account.id), not $SubscriptionId. Run az account set --subscription $SubscriptionId, then rerun." }
$tenantId = [string]$account.tenantId
$projection = Get-DeploymentOutput "projection-$NamePrefix"
$cosmosAccount = if ($projection.accountName) { [string]$projection.accountName } else { "cosmos-$NamePrefix" }
$network = Get-DeploymentOutput "projection-network-$NamePrefix"
if (-not $RenewalSubnetId) { $RenewalSubnetId = [string]$network.renewalSubnetId }
if (-not $RenewalSubnetId) {
    throw 'The projection network has no renewal subnet. Rerun scripts/Deploy-ClaudeProjection.ps1, which redeploys infra/projection-network.bicep with it, or pass -RenewalSubnetId with a /27 delegated to Microsoft.App/environments.'
}
$vnetId = ($RenewalSubnetId -split '/subnets/')[0]
$location = [string](Invoke-ClaudeNetworkAz @('network', 'vnet', 'show', '--ids', $vnetId)).location
if (-not $location) { throw "Could not read the location of $vnetId; the job's environment must be in the network's region." }
$gateway = Invoke-ClaudeNetworkAz @('apim', 'show', '-g', $GatewayResourceGroup, '-n', $ApimName)
$gatewayId = [string]$gateway.id
if ($gatewayId -notmatch '/providers/Microsoft\.ApiManagement/service/[^/]+$') { throw "Could not read API Management $ApimName in $GatewayResourceGroup." }
if (-not $WorkspaceResourceId) {
    $telemetry = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') -ResourceGroup $GatewayResourceGroup -ApimName $ApimName
    $WorkspaceResourceId = [string]$telemetry.WorkspaceResourceId
    if (-not $WorkspaceResourceId) { throw "The gateway's Application Insights has no Log Analytics workspace. Pass -WorkspaceResourceId." }
}
$script:graphToken = if (($StandardGroup -notmatch $guid) -or ($PremiumGroup -ne 'none' -and $PremiumGroup -notmatch $guid)) { Get-GraphToken } else { $null }
$standardGroupId = Resolve-TierGroup $StandardGroup 'standard'
$premiumGroupId = Resolve-TierGroup $PremiumGroup 'premium'
$accountResourceId = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosAccount"
Ok "Cosmos $cosmosAccount; renewal subnet in $location; gateway $ApimName; standard $standardGroupId; premium $premiumGroupId"

if (-not $PSCmdlet.ShouldProcess($ResourceGroup, 'deploy the projection registry, build the sync image and deploy the renewal job')) {
    Note "WhatIf: projection-registry-$NamePrefix, az acr build $repository`:$ImageTag, projection-renewal-$NamePrefix on $RenewalSubnetId every '$CronExpression'. No Azure writes."
    return
}

Step 'Phase 1: registry and job identity'
$registry = Invoke-Deployment "projection-registry-$NamePrefix" 'infra/projection-registry.bicep' @{ namePrefix = $NamePrefix; location = $location; acrSku = $AcrSku }
if (-not $registry.acrName -or -not $registry.identityPrincipalId) { throw 'The registry deployment did not return the registry and identity.' }
Ok "registry $($registry.acrName); job identity principal $($registry.identityPrincipalId)"
Note "A tenant administrator can grant Graph access now, while the image builds: ./scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId $($registry.identityPrincipalId)"

Step 'Phase 2: sync image'
if ($ImageDigest) {
    Note "Using the given image digest $ImageDigest; no build."
}
else {
    $package = New-ClaudeProjectionSyncPackage -Destination (Join-Path ([IO.Path]::GetTempPath()) ('claude-sync-' + [guid]::NewGuid().ToString('N'))) -Root $root
    try {
        Note "az acr build waits for the build (about 1-3 minutes) with log streaming off."
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $build = & az acr build --registry $registry.acrName --image "${repository}:$ImageTag" --file sync/Dockerfile --no-logs --only-show-errors -o none $package 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
    }
    finally { Remove-Item -LiteralPath $package -Recurse -Force -ErrorAction SilentlyContinue }
    if ($code -ne 0) {
        throw ("The registry build failed (az exit $code): $($build.Trim()) ACR Tasks runs are paused for subscriptions on Azure free credits (U114). " +
            "Alternative: write the package with New-ClaudeProjectionSyncPackage, then docker build -f sync/Dockerfile -t $($registry.acrLoginServer)/${repository}:$ImageTag <package>, " +
            "az acr login --name $($registry.acrName), docker push, and rerun with -ImageDigest <sha256 digest>. Nothing after the registry was deployed.")
    }
    $ImageDigest = [string](Invoke-ClaudeNetworkAz @('acr', 'manifest', 'show-metadata', '--registry', $registry.acrName, '--name', "${repository}:$ImageTag", '--query', 'digest'))
    if ($ImageDigest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw "The registry returned '$ImageDigest' for ${repository}:$ImageTag, not a sha256 digest. Nothing after the registry was deployed." }
}
Ok "image $($registry.acrLoginServer)/$repository@$ImageDigest"

Step 'Phase 3: renewal job, alerts and grants'
$renewal = Invoke-Deployment "projection-renewal-$NamePrefix" 'infra/projection-renewal.bicep' @{
    namePrefix = $NamePrefix; location = $location; cosmosAccountName = $cosmosAccount
    containerAppsSubnetId = $RenewalSubnetId; logAnalyticsWorkspaceId = $WorkspaceResourceId
    actionGroupEmailReceivers = @($emails); acrName = $registry.acrName; identityName = $registry.identityName
    syncImageDigest = $ImageDigest; cronExpression = $CronExpression; tenantId = $tenantId
    standardGroupId = $standardGroupId; premiumGroupId = $premiumGroupId; gatewayResourceId = $gatewayId
    entrypoint = $entryPoint
}
if (-not $renewal.jobResourceId -or -not $renewal.actionGroupResourceId) { throw 'The renewal deployment did not return the job and the action group.' }
Ok "job $($renewal.jobName) every '$CronExpression'; action group $($renewal.actionGroupResourceId)"

$sourceCommit = (& git -C $root rev-parse HEAD 2>$null | Out-String).Trim()
$sourceDirty = [bool]((& git -C $root status --porcelain --untracked-files=no 2>$null | Out-String).Trim())
$receipt = [ordered]@{
    kind = 'claude-projection-renewal-receipt'; schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o')
    sourceCommit = $sourceCommit; sourceDirty = $sourceDirty
    resourceGroup = $ResourceGroup; namePrefix = $NamePrefix; tenantId = $tenantId; gatewayResourceId = $gatewayId
    cosmosAccount = $cosmosAccount; accountResourceId = $accountResourceId; runnerName = [string]$network.runnerName
    reconcilerResourceId = [string]$renewal.jobResourceId; jobName = [string]$renewal.jobName
    imageDigest = $ImageDigest; imageTag = $ImageTag; entryPoint = $entryPoint
    actionGroupResourceId = [string]$renewal.actionGroupResourceId; identityPrincipalId = [string]$registry.identityPrincipalId
    workspaceResourceId = $WorkspaceResourceId; cronExpression = $CronExpression
}
New-Item -ItemType Directory -Force -Path (Split-Path $ReceiptPath -Parent) | Out-Null
[IO.File]::WriteAllText($ReceiptPath, ($receipt | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

Step 'Next steps'
Write-Host "    1. A Privileged Role Administrator or Global Administrator grants Microsoft Graph GroupMember.Read.All to the job identity, once:"
Write-Host "       ./scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId $($registry.identityPrincipalId)"
Write-Host "    2. Each alert address receives a confirmation from Azure Monitor; an address not confirmed within 30 minutes receives no alerts (U116)."
Write-Host "    3. Admission needs three successful runs, about 60-90 minutes on a 30-minute schedule after the grant takes effect."
Write-Host "       Runs: az containerapp job execution list -g $ResourceGroup -n $($renewal.jobName) -o table"
Write-Host "    Receipt (no secrets): $ReceiptPath"
[pscustomobject]$receipt
