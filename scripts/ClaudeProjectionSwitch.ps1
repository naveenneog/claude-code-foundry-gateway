# ADR-0050. The one projection switch: the deployer's -FlipAfterCleanCompare and the guided flow call
# Invoke-ClaudeProjectionSwitch. Importing this file performs no Azure operations.
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')

$script:ClaudeProjectionRenewalFields = @(
    'resourceGroup', 'namePrefix', 'runnerName', 'cosmosAccount', 'accountResourceId', 'tenantId', 'reconcilerResourceId', 'imageDigest',
    'entryPoint', 'actionGroupResourceId', 'gatewayResourceId', 'standardGroupId', 'premiumGroupId', 'identityClientId'
)

function Assert-ClaudeProjectionRenewalEvidence {
    # ADR-0050. Receipt values reach az.cmd arguments, which cmd.exe re-reads; the runner's command line,
    # which it splits on spaces and URL-decodes; and ARM URLs, which carry the management token. Each value
    # must have the form Azure gives it before the first call.
    param([Parameter(Mandatory)]$Renewal)
    $remedy = 'Remedy: use the receipt that scripts/Deploy-ClaudeProjectionRenewal.ps1 wrote for this gateway, or redeploy the renewal job, which writes a new one.'
    if ([string]$Renewal.kind -ne 'claude-projection-renewal-receipt' -or [string]$Renewal.schemaVersion -ne '1') {
        throw "Projection switch refused: the renewal evidence is not a version 1 renewal receipt (kind '$($Renewal.kind)', schemaVersion '$($Renewal.schemaVersion)'). $remedy"
    }
    $guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $group = '[A-Za-z0-9._-]{1,90}'
    $resourceId = { param($Type, $Name) "^/subscriptions/$guid/resourceGroups/$group/providers/$Type/$Name`$" }
    $forms = [ordered]@{
        resourceGroup         = "^$group`$"
        namePrefix            = '(?-i)^(?=.{1,37}$)[a-z0-9]+(?:-[a-z0-9]+)*$'
        runnerName            = '(?-i)^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'
        cosmosAccount         = '(?-i)^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$'
        accountResourceId     = (& $resourceId 'Microsoft\.DocumentDB/databaseAccounts' '[a-z0-9][a-z0-9-]{1,42}[a-z0-9]')
        tenantId              = "^$guid`$"
        reconcilerResourceId  = (& $resourceId 'Microsoft\.App/jobs' '[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?')
        imageDigest           = '(?-i)^sha256:[0-9a-f]{64}$'
        entryPoint            = '(?-i)^node /app/sync/src/apply-projection\.mjs$'
        actionGroupResourceId = (& $resourceId 'Microsoft\.Insights/actionGroups' '[A-Za-z0-9._-]{1,260}')
        gatewayResourceId     = (& $resourceId 'Microsoft\.ApiManagement/service' '[A-Za-z0-9-]{1,50}')
        standardGroupId       = "^$guid`$"
        premiumGroupId        = "^(?:$guid|none)`$"
        identityClientId      = "^$guid`$"
    }
    foreach ($field in $forms.Keys) {
        $value = [string]$Renewal.$field
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Projection switch refused: the renewal evidence has no $field. $remedy" }
        if ($value -notmatch $forms[$field]) {
            $shown = if ($value.Length -gt 160) { $value.Substring(0, 160) + '...' } else { $value }
            throw "Projection switch refused: the renewal receipt's $field '$shown' is not in the form Azure gives it, and such a value can change an az.cmd, runner or ARM call. $remedy"
        }
    }
    # The renewal deployment puts the job, its action group and the Cosmos account in the receipt's
    # resource group, in the gateway's subscription.
    $subscription = ([string]$Renewal.gatewayResourceId -split '/')[2]
    foreach ($field in 'accountResourceId', 'reconcilerResourceId', 'actionGroupResourceId') {
        $parts = ([string]$Renewal.$field) -split '/'
        if ($parts[2] -ne $subscription) { throw "Projection switch refused: the renewal receipt's $field is in subscription $($parts[2]), not the gateway's subscription $subscription. $remedy" }
        if ($parts[4] -ne [string]$Renewal.resourceGroup) { throw "Projection switch refused: the renewal receipt's $field is in resource group $($parts[4]), not the receipt's resource group $($Renewal.resourceGroup). $remedy" }
    }
    $accountName = ([string]$Renewal.accountResourceId -split '/')[-1]
    if ($accountName -ne [string]$Renewal.cosmosAccount) {
        throw "Projection switch refused: the renewal receipt's accountResourceId names Cosmos account $accountName, not its cosmosAccount $($Renewal.cosmosAccount). $remedy"
    }
}

function Read-ClaudeProjectionRenewalReceipt {
    # The receipt scripts/Deploy-ClaudeProjectionRenewal.ps1 writes (ADR-0049 decision 7).
    param([Parameter(Mandatory)][string]$Path)
    $remedy = 'Remedy: deploy the renewal job with scripts/Deploy-ClaudeProjectionRenewal.ps1, which writes the receipt, then rerun.'
    if (-not (Test-Path -LiteralPath $Path)) { throw "Projection switch refused: no renewal receipt at $Path. $remedy" }
    try { $receipt = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Projection switch refused: the renewal receipt $Path is not JSON. $remedy" }
    if ($receipt.kind -ne 'claude-projection-renewal-receipt' -or $receipt.schemaVersion -ne 1) {
        throw "Projection switch refused: $Path is not a version 1 renewal receipt. $remedy"
    }
    foreach ($field in $script:ClaudeProjectionRenewalFields) {
        if ([string]::IsNullOrWhiteSpace([string]$receipt.$field)) { throw "Projection switch refused: the renewal receipt $Path has no $field. $remedy" }
    }
    return $receipt
}

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
    $rollback = 'Rollback: refresh allow-standard and allow-premium with scripts/Sync-ClaudeAccess.ps1, check them with scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift, then set entitlement-source back to named-value. The lists change only when Sync-ClaudeAccess.ps1 runs, so lists left unrefreshed while the projection serves can grant or deny the wrong people.'
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
    # A unique name, created once: a second switch must not overwrite the values from before the first.
    $path = Join-Path $Directory ("projection-switch-$ApimName-" + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $backup = [ordered]@{
        kind = 'claude-projection-switch-backup'; schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o')
        resourceGroup = $ResourceGroup; apimName = $ApimName; gatewayResourceId = $GatewayResourceId; namedValues = $values
    }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($backup | ConvertTo-Json -Depth 5)); $stream.Write($bytes, 0, $bytes.Length) }
    finally { $stream.Dispose() }
    return $path
}

function Invoke-ClaudeProjectionSwitch {
    <#
    .SYNOPSIS
        Switches entitlement-source to projection after a drift check, a runner compare and admission.

    .DESCRIPTION
        Order: Compare-ClaudeEntitlement.ps1 -FailOnDrift with the gateway export; the sync package and
        a read-only apply-projection.mjs --compare in the runner; admission over the action group, the
        job definition and its settings, and Cosmos evidence; a backup; one entitlement-source write.
        Nothing is deployed, published or applied. -WhatIf stops before the backup. A refusal at any
        step leaves entitlement-source unchanged and writes no backup.

    .PARAMETER Renewal
        The renewal receipt (Read-ClaudeProjectionRenewalReceipt), or an object with the same fields.

    .PARAMETER Backup
        Replaces the backup file and returns the path of the backup it took; the guided flow passes its
        own snapshot gate.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)]$Renewal,
        [string]$StandardGroup = 'claude-code-standard',
        [string]$PremiumGroup = 'claude-code-premium',
        [string]$BackupDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding'),
        [scriptblock]$Backup,
        [string]$CompareScript = (Join-Path $PSScriptRoot 'Compare-ClaudeEntitlement.ps1')
    )
    if ($ResourceGroup -notmatch '^[A-Za-z0-9._-]{1,90}$' -or $ApimName -notmatch '^[A-Za-z][A-Za-z0-9-]{0,49}$') {
        throw "Projection switch refused: resource group '$ResourceGroup' or gateway name '$ApimName' holds characters other than letters, digits, '.', '_' or '-', which az.cmd hands to cmd.exe. Remedy: pass the names as the Azure portal shows them."
    }
    Assert-ClaudeProjectionRenewalEvidence -Renewal $Renewal
    # -WhatIf previews the backup and the write only: the reads, the runner compare and admission run,
    # and their working files are written.
    $previewOnly = [bool]$WhatIfPreference
    $WhatIfPreference = $false
    $apim = Invoke-ClaudeNetworkAz @('apim', 'show', '-g', $ResourceGroup, '-n', $ApimName)
    $gatewayId = [string]$apim.id
    if (-not $gatewayId) { throw "Projection switch refused: API Management $ApimName in $ResourceGroup could not be read." }
    if ([string]$Renewal.gatewayResourceId -ne $gatewayId) {
        throw "Projection switch refused: the renewal receipt is for gateway $($Renewal.gatewayResourceId), not $gatewayId. Remedy: pass the receipt written for this gateway's renewal job."
    }
    if ([string]$apim.identity.tenantId -ne [string]$Renewal.tenantId) {
        throw "Projection switch refused: the renewal receipt's tenant $($Renewal.tenantId) is not the tenant of the gateway's managed identity ($($apim.identity.tenantId)), which the resolver accepts tokens from. Remedy: pass the receipt written for this gateway's renewal job."
    }

    # After the switch the gateway calls entitlement-resolver-url for every request. It must be the
    # resolver deployed with this projection, which reads the Cosmos account the job renews.
    Write-Host "`n==> Resolver: the gateway's resolver reads the Cosmos account the renewal job renews" -ForegroundColor Cyan
    $resolverDeployment = "projection-resolver-$($Renewal.namePrefix)"
    try { $resolver = Invoke-ClaudeNetworkAz @('deployment', 'group', 'show', '-g', [string]$Renewal.resourceGroup, '-n', $resolverDeployment, '--query', 'properties') }
    catch { throw "Projection switch refused: could not read the resolver deployment $resolverDeployment in $($Renewal.resourceGroup): $($_.Exception.Message) Remedy: deploy the projection with scripts/Deploy-ClaudeProjection.ps1 -NamePrefix $($Renewal.namePrefix), then rerun." }
    $resolverCosmos = [string]$resolver.parameters.cosmosAccountName.value
    if ($resolverCosmos -ne [string]$Renewal.cosmosAccount) {
        throw "Projection switch refused: the resolver deployed as $resolverDeployment reads Cosmos account $resolverCosmos, not $($Renewal.cosmosAccount), which the renewal job renews. Remedy: deploy the projection and the renewal job with one -NamePrefix, then rerun."
    }
    $resolverUrl = [string]$resolver.outputs.resolverUrl.value
    $resolverAudience = [string]$resolver.outputs.resolverAudience.value
    $gatewayUrl = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-url' -FailOnError
    $gatewayAudience = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-audience' -FailOnError
    if (-not $resolverUrl -or $gatewayUrl -ne $resolverUrl -or $gatewayAudience -ne $resolverAudience) {
        throw "Projection switch refused: the gateway calls entitlement-resolver-url '$gatewayUrl' with audience '$gatewayAudience', not $resolverUrl with $resolverAudience from $resolverDeployment; after the switch every request would go to the first. Remedy: set both named values to the outputs of $resolverDeployment (docs/SECURE-PROJECTION.md, section 9), or rerun scripts/Deploy-ClaudeProjection.ps1 -NamePrefix $($Renewal.namePrefix) without -FlipAfterCleanCompare, which sets them, then rerun."
    }
    $token = if ($StandardGroup -notmatch '^[0-9a-fA-F-]{36}$' -or ($PremiumGroup -ne 'none' -and $PremiumGroup -notmatch '^[0-9a-fA-F-]{36}$')) { Get-GraphToken } else { $null }
    $standardId = Resolve-ClaudeProjectionTierGroupId -Group $StandardGroup -Tier standard -Token $token
    $premiumId = Resolve-ClaudeProjectionTierGroupId -Group $PremiumGroup -Tier premium -Token $token

    $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-projection-switch-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        Write-Host "`n==> Drift check: the gateway's lists against Entra" -ForegroundColor Cyan
        $gateway = Join-Path $work 'gateway-decisions.json'
        & $CompareScript -ResourceGroup $ResourceGroup -ApimName $ApimName -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup -ExportGatewayPath $gateway -FailOnDrift:$true
        if ($LASTEXITCODE -ne 0) {
            throw 'Projection switch refused: the named-value lists drift from Entra. Remedy: refresh them with scripts/Sync-ClaudeAccess.ps1, then rerun.'
        }

        Write-Host '==> Compare: the projection against the gateway, through the in-VNet runner (read-only)' -ForegroundColor Cyan
        $runnerGroup = [string]$Renewal.resourceGroup
        $runner = [string]$Renewal.runnerName
        $archive = New-ClaudeProjectionSyncArchive -Path (Join-Path $work 'sync.tar.gz') -Root (Split-Path $PSScriptRoot -Parent)
        Send-RunnerFile -ResourceGroup $runnerGroup -Name $runner -Path $archive -Destination /work/sync-source.tar.gz | Out-Null
        Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work' | Out-Null
        Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' | Out-Null
        Send-RunnerFile -ResourceGroup $runnerGroup -Name $runner -Path $gateway -Destination /work/gateway-decisions.json | Out-Null
        $compareRaw = Invoke-RunnerCommand -ResourceGroup $runnerGroup -Name $runner -Command "node /work/sync/src/apply-projection.mjs --cosmos https://$($Renewal.cosmosAccount).documents.azure.com:443/ --tenant $($Renewal.tenantId) --compare /work/gateway-decisions.json"
        try { $compare = ConvertFrom-ClaudeRunnerResult -RawOutput $compareRaw -Step 'Projection compare' }
        catch { throw "Projection switch refused: the projection does not match the gateway's decisions. $($_.Exception.Message) Remedy: let the renewal job run, refresh the lists with scripts/Sync-ClaudeAccess.ps1 if they are behind, then rerun." }

        Write-Host '==> Admission: alerts, the job definition and its settings, and Cosmos evidence' -ForegroundColor Cyan
        $admission = Assert-ClaudeProjectionAdmission -ResourceGroup $runnerGroup -RunnerName $runner -CosmosAccount $Renewal.cosmosAccount `
            -TenantId $Renewal.tenantId -AccountResourceId $Renewal.accountResourceId -ReconcilerResourceId $Renewal.reconcilerResourceId `
            -ImageDigest $Renewal.imageDigest -EntryPoint $Renewal.entryPoint -ActionGroupResourceId $Renewal.actionGroupResourceId `
            -GatewayResourceId $gatewayId -StandardGroupId $standardId -PremiumGroupId $premiumId -IdentityClientId $Renewal.identityClientId

        if ($previewOnly) {
            Write-Host '    WhatIf: the drift check, the compare and admission passed; no backup and no write.' -ForegroundColor DarkGray
            return [pscustomobject]@{ Switched = $false; BackupPath = $null; Compared = $compare.compared; Admission = $admission; Rollback = (Get-ClaudeProjectionRollbackText) }
        }
        if (-not $PSCmdlet.ShouldProcess($ApimName, 'set entitlement-source to projection')) {
            throw 'Projection switch declined after admission; entitlement-source is unchanged and no backup was written.'
        }
        Write-Host '==> Backup and switch' -ForegroundColor Cyan
        $backupPath = if ($Backup) { [string](@(& $Backup) | Select-Object -Last 1) } else { Save-ClaudeProjectionSwitchBackup -ResourceGroup $ResourceGroup -ApimName $ApimName -GatewayResourceId $gatewayId -Directory $BackupDirectory }
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-source' -Value 'projection'
        $rollback = Get-ClaudeProjectionRollbackText -BackupPath $backupPath
        Write-Host "    [OK]   entitlement-source is projection after admission over $($admission.generations) renewals" -ForegroundColor Green
        Write-Host "    $rollback" -ForegroundColor DarkGray
        return [pscustomobject]@{ Switched = $true; BackupPath = $backupPath; Compared = $compare.compared; Admission = $admission; Rollback = $rollback }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
