# ADR-0050. The one projection switch: the deployer's -FlipAfterCleanCompare and the guided flow call
# Invoke-ClaudeProjectionSwitch. Importing this file performs no Azure operations.
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionChecks.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')

$script:ClaudeProjectionRenewalFields = @(
    'resourceGroup', 'runnerName', 'cosmosAccount', 'accountResourceId', 'tenantId', 'reconcilerResourceId', 'imageDigest',
    'entryPoint', 'actionGroupResourceId', 'gatewayResourceId', 'standardGroupId', 'premiumGroupId', 'identityClientId'
)

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
    $path = Join-Path $Directory ("projection-switch-$ApimName-" + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
    $backup = [ordered]@{
        kind = 'claude-projection-switch-backup'; schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o')
        resourceGroup = $ResourceGroup; apimName = $ApimName; gatewayResourceId = $GatewayResourceId; namedValues = $values
    }
    [IO.File]::WriteAllText($path, ($backup | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
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
        Replaces the backup file; the guided flow passes its own snapshot gate.
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
    foreach ($field in $script:ClaudeProjectionRenewalFields) {
        if ([string]::IsNullOrWhiteSpace([string]$Renewal.$field)) { throw "Projection switch refused: the renewal evidence has no $field. Remedy: deploy the renewal job with scripts/Deploy-ClaudeProjectionRenewal.ps1 and pass its receipt." }
    }
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
        $backupPath = if ($Backup) { & $Backup; $null } else { Save-ClaudeProjectionSwitchBackup -ResourceGroup $ResourceGroup -ApimName $ApimName -GatewayResourceId $gatewayId -Directory $BackupDirectory }
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-source' -Value 'projection'
        $rollback = Get-ClaudeProjectionRollbackText -BackupPath $backupPath
        Write-Host "    [OK]   entitlement-source is projection after admission over $($admission.generations) renewals" -ForegroundColor Green
        Write-Host "    $rollback" -ForegroundColor DarkGray
        return [pscustomobject]@{ Switched = $true; BackupPath = $backupPath; Compared = $compare.compared; Admission = $admission; Rollback = $rollback }
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
