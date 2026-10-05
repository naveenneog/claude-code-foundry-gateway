# ADR-0051. The projection switch is sync-evidence based: no renewal receipt or job definition.
# Importing this file performs no Azure operations.
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')

function Resolve-ClaudeProjectionTierGroupId {
    param([Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Tier, [string]$Token)
    if ($Tier -eq 'premium' -and $Group -eq 'none') { return 'none' }
    if ($Group -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $Group.ToLowerInvariant() }
    $found = Get-ClaudeGraphGroup -GroupName $Group -Token $Token
    if (-not $found) { throw "Projection switch refused: the $Tier tier group '$Group' was not found in Microsoft Graph. Remedy: pass the group the gateway's lists come from, or none for no premium tier." }
    return ([string]$found.id).ToLowerInvariant()
}

function Get-ClaudeProjectionRollbackText {
    param([string]$BackupPath)
    $rollback = 'Rollback: refresh named values with scripts/Sync-ClaudeAccess.ps1 -Store named-value, check them with scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift, then set entitlement-source back to named-value. The lists change only when Sync-ClaudeAccess.ps1 runs, so lists left unrefreshed while the projection serves can grant or deny the wrong people.'
    if ($BackupPath) { $rollback += " The values before the switch are in $BackupPath." }
    return $rollback
}

function Save-ClaudeProjectionSwitchBackup {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ApimName, [Parameter(Mandatory)][string]$GatewayResourceId, [Parameter(Mandatory)][string]$Directory)
    $values = [ordered]@{}
    foreach ($id in 'entitlement-source', 'allow-standard', 'allow-premium', 'bu-members') {
        $values[$id] = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id -FailOnError
    }
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $path = Join-Path $Directory ("projection-switch-$ApimName-" + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $backup = [ordered]@{ kind = 'claude-projection-switch-backup'; schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o'); resourceGroup = $ResourceGroup; apimName = $ApimName; gatewayResourceId = $GatewayResourceId; namedValues = $values }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($backup | ConvertTo-Json -Depth 5)); $stream.Write($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
    return $path
}

function Test-ClaudeProjectionHasNamedValueMembers {
    param([AllowEmptyString()][string]$AllowStandard, [AllowEmptyString()][string]$AllowPremium, [AllowEmptyString()][string]$BuMembers)
    $guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    return (($AllowStandard -match $guid) -or ($AllowPremium -match $guid) -or ($BuMembers -match $guid))
}

function Get-ClaudeProjectionResolverAppId {
    param($Resolver, [string]$ResolverAudience)
    $appId = [string]$Resolver.parameters.resolverAppId.value
    if (-not $appId -and $ResolverAudience -match '^api://([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$') { $appId = $Matches[1] }
    if ($appId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Projection switch refused: the resolver deployment does not expose a resolver application id. Remedy: redeploy the projection resolver.' }
    return $appId
}

function Invoke-ClaudeProjectionSwitch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix,
        [string]$StandardGroup = 'claude-code-standard',
        [string]$PremiumGroup = 'claude-code-premium',
        [string]$BackupDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding'),
        [scriptblock]$Backup,
        [string]$CompareScript = (Join-Path $PSScriptRoot 'Compare-ClaudeEntitlement.ps1'),
        [string]$SyncProjectionScript = (Join-Path $PSScriptRoot 'Sync-ClaudeProjection.ps1')
    )
    if ($ApimName -notmatch '^[A-Za-z][A-Za-z0-9-]{0,49}$') { throw "Projection switch refused: '$ApimName' is not an API Management name, which holds 1-50 letters, digits and hyphens and starts with a letter. Remedy: pass the gateway name as the Azure portal shows it." }
    if ($ResourceGroup -notmatch '^[A-Za-z0-9._-]{1,90}$') { throw "Projection switch refused: resource group '$ResourceGroup' holds characters other than letters, digits, '.', '_' or '-'. Azure allows some of them, such as parentheses, but az.cmd hands them to cmd.exe, so this switch does not pass them (ADR-0050). Remedy: switch a gateway in a resource group named with those characters only; Azure moves an API Management instance between resource groups, except on the Consumption tier." }
    if ($NamePrefix.Length -gt 37 -or $NamePrefix -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Projection switch refused: NamePrefix '$NamePrefix' is not 1-37 lowercase letters/digits with separated hyphens. Remedy: pass the projection prefix used for deployment." }
    $previewOnly = [bool]$WhatIfPreference
    $WhatIfPreference = $false
    $confirmWrite = $ConfirmPreference
    $ConfirmPreference = 'None'

    $apim = Invoke-ClaudeNetworkAz @('apim', 'show', '-g', $ResourceGroup, '-n', $ApimName)
    $gatewayId = [string]$apim.id
    if (-not $gatewayId) { throw "Projection switch refused: API Management $ApimName in $ResourceGroup could not be read. Remedy: check the names, the Azure CLI sign-in and read access to the gateway, then rerun." }
    $tenantId = [string]$apim.identity.tenantId
    if ($tenantId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Projection switch refused: the gateway has no managed-identity tenant id. Remedy: enable the system assigned identity, then rerun.' }

    Write-Host "`n==> Resolver: the gateway's resolver reads the projection Cosmos account" -ForegroundColor Cyan
    $resolverDeployment = "projection-resolver-$NamePrefix"
    try { $resolver = Invoke-ClaudeNetworkAz @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $resolverDeployment, '--query', 'properties') }
    catch { throw "Projection switch refused: could not read the resolver deployment $resolverDeployment in ${ResourceGroup}: $($_.Exception.Message) Remedy: deploy the projection with scripts/Deploy-ClaudeProjection.ps1 -NamePrefix $NamePrefix, then rerun." }
    $cosmosAccount = [string]$resolver.parameters.cosmosAccountName.value
    if ($cosmosAccount -notmatch '^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$') { throw "Projection switch refused: the resolver deployment $resolverDeployment names no valid Cosmos account. Remedy: redeploy the projection." }
    $resolverUrl = [string]$resolver.outputs.resolverUrl.value
    $resolverAudience = [string]$resolver.outputs.resolverAudience.value
    $siteName = [string]$resolver.outputs.siteName.value
    if ($siteName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,58}[A-Za-z0-9]$') { throw "Projection switch refused: the resolver deployment $resolverDeployment names no site ('$siteName'). Remedy: redeploy the projection." }
    $gatewayUrl = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-url' -FailOnError
    $gatewayAudience = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-audience' -FailOnError
    if (-not $resolverUrl -or $gatewayUrl -ne $resolverUrl -or $gatewayAudience -ne $resolverAudience) { throw "Projection switch refused: the gateway's entitlement-resolver-url is '$gatewayUrl' and its entitlement-resolver-audience is '$gatewayAudience', not $resolverUrl and $resolverAudience from $resolverDeployment. Remedy: rerun scripts/Deploy-ClaudeProjection.ps1 -NamePrefix $NamePrefix without -FlipAfterCleanCompare, then rerun." }
    $resolverAppId = Get-ClaudeProjectionResolverAppId -Resolver $resolver -ResolverAudience $resolverAudience
    Assert-ClaudeProjectionResolverServicePrincipal -AppId $resolverAppId | Out-Null
    $siteId = "/subscriptions/$(($gatewayId -split '/')[2])/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$siteName"
    $siteUrl = Get-ClaudeProjectionArmUrl -ResourceId $siteId -ApiVersion '2024-04-01'
    $settingsUrl = Get-ClaudeProjectionArmUrl -ResourceId $siteId -ApiVersion '2024-04-01' -SubPath 'config/appsettings/list'
    try {
        $site = Invoke-ClaudeNetworkAz @('rest', '--method', 'get', '--url', $siteUrl)
        $siteSettings = Invoke-ClaudeNetworkAz @('rest', '--method', 'post', '--url', $settingsUrl)
    }
    catch { throw "Projection switch refused: could not read the resolver site $siteName and its application settings: $($_.Exception.Message) Remedy: rerun as an account that can read the site and list its settings." }
    if ("https://$([string]$site.properties.defaultHostName)/api" -ne $gatewayUrl) { throw "Projection switch refused: the gateway calls $gatewayUrl, but the resolver site $siteName serves https://$([string]$site.properties.defaultHostName)/api. Remedy: set entitlement-resolver-url to the site's address, or redeploy the projection." }
    $live = $siteSettings.properties
    $liveCosmos = try { ([uri][string]$live.COSMOS_ENDPOINT).Host } catch { '' }
    if ($liveCosmos -ne "$cosmosAccount.documents.azure.com" -or [string]$live.COSMOS_DATABASE -ne 'claude' -or [string]$live.COSMOS_CONTAINER -ne 'entitlement' -or [string]$live.PROJECTION_TENANT_ID -ne $tenantId) { throw "Projection switch refused: the resolver site $siteName reads Cosmos account $liveCosmos (database '$($live.COSMOS_DATABASE)', container '$($live.COSMOS_CONTAINER)', tenant '$($live.PROJECTION_TENANT_ID)'), not $cosmosAccount.documents.azure.com (claude, entitlement, $tenantId). Remedy: redeploy the projection with this prefix, then rerun." }

    $token = if ($StandardGroup -notmatch '^[0-9a-fA-F-]{36}$' -or ($PremiumGroup -ne 'none' -and $PremiumGroup -notmatch '^[0-9a-fA-F-]{36}$')) { Get-GraphToken } else { $null }
    $standardId = Resolve-ClaudeProjectionTierGroupId -Group $StandardGroup -Tier standard -Token $token
    $premiumId = Resolve-ClaudeProjectionTierGroupId -Group $PremiumGroup -Tier premium -Token $token
    $null = $standardId, $premiumId

    $runnerGroup = $ResourceGroup
    $runner = "aci-projtest-$NamePrefix"
    $accountResourceId = "/subscriptions/$(($gatewayId -split '/')[2])/resourceGroups/$ResourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosAccount"
    $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-projection-switch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        $allowStandard = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-standard' -FailOnError
        $allowPremium = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-premium' -FailOnError
        $buMembers = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-members' -FailOnError
        $hasNamedMembers = Test-ClaudeProjectionHasNamedValueMembers -AllowStandard $allowStandard -AllowPremium $allowPremium -BuMembers $buMembers
        $gateway = Join-Path $work 'gateway-decisions.json'
        $snapshot = Join-Path $work 'snapshot.json'
        $archive = New-ClaudeProjectionSyncArchive -Path (Join-Path $work 'sync.tar.gz') -Root (Split-Path $PSScriptRoot -Parent)
        if ($hasNamedMembers) {
            Write-Host "`n==> Drift check: the gateway's lists against Entra" -ForegroundColor Cyan
            & $CompareScript -ResourceGroup $ResourceGroup -ApimName $ApimName -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportGatewayPath $gateway -FailOnDrift:$true
            if ($LASTEXITCODE -ne 0) { throw 'Projection switch refused: the named-value lists drift from Entra. Remedy: refresh them with scripts/Sync-ClaudeAccess.ps1 -Store named-value, then rerun.' }
        }
        else {
            Write-Host "`n==> New gateway: no named-value members; compare projection with a fresh Entra snapshot" -ForegroundColor Cyan
            & $SyncProjectionScript -ApimName $ApimName -ResourceGroup $ResourceGroup -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportPath $snapshot
            if ($LASTEXITCODE -ne 0) { throw 'Projection switch refused: snapshot export failed; no compare or switch was attempted.' }
        }
        Write-Host '==> Compare: the projection through the in-VNet runner (read-only)' -ForegroundColor Cyan
        Start-ClaudeProjectionRunner -ResourceGroup $runnerGroup -Name $runner | Out-Null
        Send-RunnerFile -ResourceGroup $runnerGroup -Name $runner -Path $archive -Destination /work/sync-source.tar.gz | Out-Null
        Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work' | Out-Null
        Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' | Out-Null
        if ($hasNamedMembers) {
            Send-RunnerFile -ResourceGroup $runnerGroup -Name $runner -Path $gateway -Destination /work/gateway-decisions.json | Out-Null
            $compareRaw = Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command "node /work/sync/src/apply-projection.mjs --cosmos https://$cosmosAccount.documents.azure.com:443/ --tenant $tenantId --compare /work/gateway-decisions.json"
        }
        else {
            Send-RunnerFile -ResourceGroup $runnerGroup -Name $runner -Path $snapshot -Destination /work/snapshot.json | Out-Null
            $compareRaw = Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command "node /work/sync/src/apply-projection.mjs --cosmos https://$cosmosAccount.documents.azure.com:443/ --tenant $tenantId --compare-snapshot /work/snapshot.json"
        }
        $summaryLine = @(([string]$compareRaw).TrimEnd("`r", "`n") -split '\r?\n' | Select-Object -Last 1)[0]
        $compare = try { $summaryLine | ConvertFrom-Json -ErrorAction Stop } catch { $null }
        if (-not ($compare -and $compare.ok -eq $true -and (($compare.mode -eq 'compare') -or ($compare.mode -eq 'compare-snapshot')))) {
            if ($compare -and $compare.differences -gt 0) { throw "Projection switch refused: the projection comparison found $($compare.differences) differences. Remedy: run a full projection sync, then rerun." }
            Write-ClaudeRunnerOutput -RawOutput ([string]$compareRaw) -Step 'Projection compare'
            throw 'Projection switch refused: the runner compare did not complete; its sanitized output is shown above. Remedy: check the in-VNet runner and its Cosmos access, then rerun.'
        }
        Write-Host '==> Evidence: newest full sync and invalid projection records' -ForegroundColor Cyan
        $admission = Assert-ClaudeProjectionAdmission -ResourceGroup $runnerGroup -RunnerName $runner -CosmosAccount $cosmosAccount -TenantId $tenantId -AccountResourceId $accountResourceId
        if ($previewOnly) {
            Write-Host '    WhatIf: resolver checks, compare and evidence passed; no backup and no write.' -ForegroundColor DarkGray
            return [pscustomobject]@{ Switched = $false; BackupPath = $null; Compared = $compare.compared; Admission = $admission; Rollback = (Get-ClaudeProjectionRollbackText) }
        }
        $ConfirmPreference = $confirmWrite
        if (-not $PSCmdlet.ShouldProcess($ApimName, 'set entitlement-source to projection')) { throw 'Projection switch declined after evidence; entitlement-source is unchanged and no backup was written.' }
        $ConfirmPreference = 'None'
        Write-Host '==> Backup and switch' -ForegroundColor Cyan
        $backupPath = if ($Backup) { [string](@(& $Backup) | Select-Object -Last 1) } else { Save-ClaudeProjectionSwitchBackup -ResourceGroup $ResourceGroup -ApimName $ApimName -GatewayResourceId $gatewayId -Directory $BackupDirectory }
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-source' -Value 'projection'
        $rollback = Get-ClaudeProjectionRollbackText -BackupPath $backupPath
        $evidenceFinished = if ($admission.newestFullSync -and $admission.newestFullSync.finishedAt -is [DateTime]) { $admission.newestFullSync.finishedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } elseif ($admission.newestFullSync) { [string]$admission.newestFullSync.finishedAt } else { '' }
        $evidenceText = if ($admission.newestFullSync) { " from full sync finished $evidenceFinished by $($admission.newestFullSync.executor)" } else { '' }
        Write-Host "    [OK]   entitlement-source is projection after switch evidence$evidenceText" -ForegroundColor Green
        Write-Host "    $rollback" -ForegroundColor DarkGray
        return [pscustomobject]@{ Switched = $true; BackupPath = $backupPath; Compared = $compare.compared; Admission = $admission; Rollback = $rollback }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false }
}
# The deployer's compare before any switch (ADR-0051 D10, as in the switch): a gateway whose named values
# hold members is drift-checked against Entra and compared with those lists; a new gateway, with none, is
# compared with the snapshot the deployer has just applied, already on the runner at /work/snapshot.json.
function Invoke-ClaudeProjectionDeployerCompare {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$RunnerName, [Parameter(Mandatory)][string]$CosmosAccount,
        [Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$GatewayPath,
        [string]$StandardGroup = 'claude-code-standard', [string]$PremiumGroup = 'claude-code-premium',
        [string]$CompareScript = (Join-Path $PSScriptRoot 'Compare-ClaudeEntitlement.ps1')
    )
    $hasNamedMembers = Test-ClaudeProjectionHasNamedValueMembers `
        -AllowStandard (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-standard' -FailOnError) `
        -AllowPremium (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'allow-premium' -FailOnError) `
        -BuMembers (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-members' -FailOnError)
    $apply = "node /work/sync/src/apply-projection.mjs --cosmos https://$CosmosAccount.documents.azure.com:443/ --tenant $TenantId"
    if ($hasNamedMembers) {
        & $CompareScript -ResourceGroup $ResourceGroup -ApimName $ApimName -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportGatewayPath $GatewayPath -FailOnDrift:$true
        if ($LASTEXITCODE -ne 0) { throw 'named-value lists drift from Entra; refusing projection comparison and flip.' }
        Send-RunnerFile -ResourceGroup $ResourceGroup -Name $RunnerName -Path $GatewayPath -Destination /work/gateway-decisions.json | Out-Null
        $raw = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $RunnerName -Command "$apply --compare /work/gateway-decisions.json"
    }
    else {
        Write-Host '    New gateway: no named-value members, so the projection is compared with the snapshot just applied.' -ForegroundColor DarkGray
        $raw = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $RunnerName -Command "$apply --compare-snapshot /work/snapshot.json"
    }
    return (ConvertFrom-ClaudeRunnerResult -RawOutput $raw -Step 'Refusing to flip because projection drift remains')
}
