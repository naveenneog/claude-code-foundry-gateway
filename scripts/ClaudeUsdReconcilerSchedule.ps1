function Test-ClaudeUsdReconcilerCron {
    param([string]$Expression)
    if ($Expression -ne '*/5 * * * *') { throw 'The USD reconciler cron must be exactly every five minutes: */5 * * * *.' }
}

function New-ClaudeUsdReconcilerParameters {
    param(
        [Parameter(Mandatory)][string]$GatewayResourceId,
        [Parameter(Mandatory)][string]$WorkspaceResourceId,
        [Parameter(Mandatory)][string]$WorkspaceCustomerId,
        [Parameter(Mandatory)][string]$RepositoryUrl,
        [Parameter(Mandatory)][string]$RepositoryRef,
        [string]$Cron = '*/5 * * * *',
        [string]$Image = 'mcr.microsoft.com/azure-cli:2.90.0',
        [string]$Location = '',
        [string]$ExistingEnvironmentId = '',
        [hashtable]$Tags = @{}
    )
    Test-ClaudeUsdReconcilerCron $Cron
    if ($RepositoryRef -notmatch '^[0-9a-f]{40}$') { throw 'RepositoryRef must be a full published commit ID.' }
    if ($RepositoryUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$') { throw 'RepositoryUrl must be a public GitHub HTTPS repository URL.' }
    if ($Image -notmatch ':.+') { throw 'Image must be tag-pinned.' }
    $parameters = @{
        gatewayResourceId = @{ value = $GatewayResourceId }
        workspaceResourceId = @{ value = $WorkspaceResourceId }
        workspaceCustomerId = @{ value = $WorkspaceCustomerId }
        repositoryUrl = @{ value = $RepositoryUrl }
        repositoryRef = @{ value = $RepositoryRef }
        cronExpression = @{ value = $Cron }
        image = @{ value = $Image }
        existingEnvironmentId = @{ value = $ExistingEnvironmentId }
        tags = @{ value = $Tags }
    }
    if ($Location) { $parameters.location = @{ value = $Location } }
    @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $parameters
    }
}
