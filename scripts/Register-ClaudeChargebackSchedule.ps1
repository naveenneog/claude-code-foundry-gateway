<#
.SYNOPSIS
    Creates or updates dedicated reports resources; no dependency on Turnstile.
.DESCRIPTION
    First registration deploys private storage, ACS Email, a managed identity, Consumption
    environment and generator/dispatcher jobs. Later calls patch only supplied settings.
    Recipients, selection and formats live in private storage and never require redeployment.
.EXAMPLE
    ./scripts/Register-ClaudeChargebackSchedule.ps1 -AllowedDomains contoso.com -RunNow
.EXAMPLE
    ./scripts/Register-ClaudeChargebackSchedule.ps1 -Cron '0 8 1 * *' -WhatIf
.EXAMPLE
    ./scripts/Register-ClaudeChargebackSchedule.ps1 -Remove -WhatIf
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
param(
    [string]$Cron='0 6 1 * *',[string[]]$AllowedDomains,[switch]$MonthToDate,[switch]$RunNow,
    [switch]$Remove,[switch]$PurgeArchive,[switch]$BreakDispatchLease,
    [string]$RepositoryUrl,[string]$RepositoryRef,[string]$Location,
    [string]$OperatorObjectId,[ValidateSet('User','ServicePrincipal')][string]$OperatorPrincipalType='User',
    [ValidateRange(1,3650)][int]$RetentionDays=400,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName)
)
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Query','Configuration','Storage','Schedule')) {. (Join-Path $PSScriptRoot "ClaudeChargeback$helper.ps1")}
$repo=Split-Path $PSScriptRoot -Parent
Test-ClaudeReportCron $Cron
if($AllowedDomains) {Test-ClaudeReportDomains $AllowedDomains}
if(-not $ResourceGroup -or -not $ApimName) {throw 'Pass -ResourceGroup and -ApimName or set CLAUDE_RG and CLAUDE_APIM.'}
if(-not $PSCmdlet.ShouldProcess("$ResourceGroup / $ApimName",$(if($Remove){'Remove dedicated reports resources (archive retained unless -PurgeArchive)'}elseif($BreakDispatchLease){'Break dispatch lease after verifying no dispatcher is running'}else{"Register/update reports; UTC cron $Cron$(if($RunNow){'; run generator now'})"}))) {return}
$resources=@(az resource list -g $ResourceGroup -o json | ConvertFrom-Json | Where-Object {$_.tags.'claude-chargeback-gateway' -eq $ApimName})
if($LASTEXITCODE -ne 0) {throw 'Could not enumerate reports resources.'}
if($Remove) {
    if($RunNow -or $BreakDispatchLease) {throw 'Remove cannot be combined with RunNow or BreakDispatchLease.'}
    $identity=@($resources | Where-Object type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities')
    foreach($id in $identity) {
        $principal=az identity show --ids $id.id --query principalId -o tsv
        if($LASTEXITCODE -ne 0) {throw 'Could not identify the dedicated reports principal for cleanup.'}
        $assignments=@(az role assignment list --assignee-object-id $principal --all -o json | ConvertFrom-Json)
        foreach($assignment in $assignments) {
            az role assignment delete --ids $assignment.id --output none
            if($LASTEXITCODE -ne 0) {throw 'Could not remove a reports identity role assignment.'}
        }
    }
    $order=@('Microsoft.App/jobs','Microsoft.App/managedEnvironments','Microsoft.Communication/communicationServices','Microsoft.Communication/emailServices','Microsoft.ManagedIdentity/userAssignedIdentities','Microsoft.Storage/storageAccounts')
    foreach($type in $order) {
        foreach($resource in @($resources | Where-Object type -eq $type)) {
            if($type -eq 'Microsoft.Storage/storageAccounts' -and -not $PurgeArchive) {Write-Host 'Keeping the report archive and configuration. Add -PurgeArchive to delete storage.';continue}
            az resource delete --ids $resource.id --output none
            if($LASTEXITCODE -ne 0) {throw "Could not remove report resource of type $type."}
        }
    }
    $storageResource=@($resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts')
    $suffix=if($storageResource.Count -eq 1) {$storageResource[0].name -replace '^streports',''} else {''}
    $roles=@(az role definition list --custom-role-only true -o json | ConvertFrom-Json | Where-Object {$suffix -and $_.roleName -in @("Claude reports catalog reader $suffix","Claude reports email sender $suffix")})
    foreach($role in $roles) {
        # Exact gateway-specific role IDs, not every report deployment's custom role.
        $assignments=@(az role assignment list --role $role.name --all -o json | ConvertFrom-Json)
        if(-not $assignments.Count) {az role definition delete --name $role.name --output none}
    }
    Write-Host 'Dedicated reports resources removed. The gateway and workspace were not changed.'
    return
}
$storage=@($resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts')
$stored=$null
if($storage.Count -eq 1) {$stored=Get-ClaudeReportConfiguration $storage[0].name -AllowMissing}
if($BreakDispatchLease) {
    if(-not $stored) {throw 'Reports configuration does not exist.'}
    Invoke-ClaudeReportBlob -Account $storage[0].name -Name 'state/dispatch.json' -Method PUT -Query 'comp=lease' `
        -ExtraHeaders @{'x-ms-lease-action'='break';'x-ms-lease-break-period'='0'} | Out-Null
    Write-Host 'Dispatch lease broken. Check the last operation before resending anything.'
    return
}
$refExplicit=$PSBoundParameters.ContainsKey('RepositoryRef')
if(-not $stored -or $refExplicit) {
    if(-not $RepositoryRef) {$RepositoryRef=(git -C $repo rev-parse HEAD).Trim()}
    if($RepositoryRef -notmatch '^[0-9a-f]{40}$') {throw 'RepositoryRef must be a full published commit ID.'}
    git -C $repo fetch -q origin
    if($LASTEXITCODE -ne 0) {throw 'Could not verify the pinned commit on origin.'}
    $remote=@(git -C $repo branch -r --contains $RepositoryRef | Where-Object {$_.Trim()})
    if(-not $remote.Count) {throw 'The job commit is not on origin. Push your branch before registration.'}
}
if($stored) {
    $config=$stored.Configuration
    if($PSBoundParameters.ContainsKey('Cron') -or $refExplicit) {
        $newCron=if($PSBoundParameters.ContainsKey('Cron')) {$Cron} else {''}
        Update-ClaudeReportJob $ResourceGroup $config.Connection.JobName $newCron $(if($refExplicit){$RepositoryRef}else{''})
        if($refExplicit) {Update-ClaudeReportJob $ResourceGroup $config.Connection.DispatcherJobName '' $RepositoryRef}
    }
    $change=$false
    if($AllowedDomains) {$config.AllowedDomains=@($AllowedDomains | ForEach-Object {$_.ToLowerInvariant()} | Sort-Object -Unique);$change=$true}
    if($PSBoundParameters.ContainsKey('MonthToDate')) {$config.MonthToDate=[bool]$MonthToDate;$change=$true}
    if($PSBoundParameters.ContainsKey('RetentionDays')) {$config.RetentionDays=$RetentionDays;$change=$true;Set-ClaudeReportRetention $ResourceGroup $storage[0].name $RetentionDays}
    if($change) {$config.UpdatedUtc=[datetime]::UtcNow.ToString('o');Save-ClaudeReportConfiguration $storage[0].name $config $stored.ETag}
    $account=$storage[0].name
}
else {
    if(-not $AllowedDomains) {throw 'First registration requires -AllowedDomains. No recipient is configured automatically.'}
    . (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
    $workspace=Get-ClaudeGatewayWorkspaceId $ResourceGroup $ApimName
    if(-not $Location) {$Location=az apim show -g $ResourceGroup -n $ApimName --query location -o tsv}
    if(-not $OperatorObjectId) {
        $OperatorObjectId=az ad signed-in-user show --query id -o tsv 2>$null
        if(-not $OperatorObjectId) {throw 'Pass -OperatorObjectId and -OperatorPrincipalType for a workload operator.'}
    }
    if($OperatorObjectId -notmatch '^[0-9a-f-]{36}$') {throw 'OperatorObjectId must be an Entra object ID.'}
    if(-not $RepositoryUrl) {$RepositoryUrl=(git -C $repo remote get-url origin).Trim() -replace '^git@github\.com:','https://github.com/'}
    $parameters=New-ClaudeReportScheduleParameters $ApimName $workspace $RepositoryUrl $RepositoryRef $Cron $OperatorObjectId $OperatorPrincipalType $Location $RetentionDays
    $folder=Join-Path $repo ('.chargeback-deploy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $folder | Out-Null
    $file=Join-Path $folder 'parameters.json'
    try {
        Write-ClaudeReportJson $file $parameters
        $deployment=az deployment group create -g $ResourceGroup -n "chargeback-$ApimName" `
            --template-file (Join-Path $repo 'infra\chargeback-reports.bicep') --parameters "@$file" --query properties.outputs -o json | ConvertFrom-Json
        if($LASTEXITCODE -ne 0 -or -not $deployment) {throw 'Reports deployment failed. Inspect its operations in the resource group; rerun after correcting the failure.'}
    }
    finally {Remove-Item $folder -Recurse -Force}
    $account=$deployment.storageAccount.value
    $config=New-ClaudeChargebackConfiguration $AllowedDomains
    $config.MonthToDate=[bool]$MonthToDate;$config.RetentionDays=$RetentionDays
    $config.Connection=[pscustomobject]@{
        Endpoint=$deployment.endpoint.value;SenderAddress=$deployment.senderAddress.value
        JobName=$deployment.jobName.value;DispatcherJobName=$deployment.dispatcherJobName.value
        EnvironmentName=$deployment.environmentName.value;WorkspaceResourceId=$workspace
    }
    # Role propagation is asynchronous. Retry only authorization failures, never silently skip.
    for($attempt=0;$attempt -lt 12;$attempt++) {
        try {
            Save-ClaudeReportConfiguration $account $config ''
            Set-ClaudeReportArchiveJson $account 'state/dispatch.json' @{NextActionUtc=$null} @{'If-None-Match'='*'}
            break
        }
        catch {
            if($_.Exception.Message -notmatch 'HTTP 403' -or $attempt -eq 11) {throw}
            Start-Sleep -Seconds 30
        }
    }
}
$run=$null
if($RunNow) {$run=Wait-ClaudeReportJob $ResourceGroup $config.Connection.JobName}
[pscustomobject]@{StorageAccount=$account;Job=$config.Connection.JobName;Dispatcher=$config.Connection.DispatcherJobName;Run=$run;Configuration='configuration/settings.json';Utc=[datetime]::UtcNow.ToString('o')}
