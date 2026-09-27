$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeUsdReconcilerSchedule.ps1')
$fail = 0
function Assert($Name, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Throws([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

Write-Host 'USD reconciler schedule contract' -ForegroundColor Cyan
$template = Get-Content (Join-Path $root 'infra\usd-reconciler-job.bicep') -Raw
$params = New-ClaudeUsdReconcilerParameters `
    -GatewayResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso' `
    -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso/providers/Microsoft.OperationalInsights/workspaces/log-contoso' `
    -WorkspaceCustomerId '11111111-1111-1111-1111-111111111111' `
    -RepositoryUrl 'https://github.com/contoso/gateway.git' -RepositoryRef ('a' * 40) `
    -Cron '*/5 * * * *' -Image 'python:3.12.11-slim-bookworm' -Location 'eastus2'

Assert 'parameter builder pins full commit' ($params.parameters.repositoryRef.value -eq ('a' * 40))
Assert 'parameter builder keeps five-minute schedule as data' ($params.parameters.cronExpression.value -eq '*/5 * * * *')
Assert 'parameter builder pins image tag' ($params.parameters.image.value -eq 'python:3.12.11-slim-bookworm')
Assert 'mutable repository refs are refused' ((Throws { New-ClaudeUsdReconcilerParameters -GatewayResourceId x -WorkspaceResourceId y -WorkspaceCustomerId z -RepositoryUrl 'https://github.com/contoso/gateway.git' -RepositoryRef main }) -match 'full published commit')
Assert 'non-five-minute cron is refused' ((Throws { New-ClaudeUsdReconcilerParameters -GatewayResourceId x -WorkspaceResourceId y -WorkspaceCustomerId z -RepositoryUrl 'https://github.com/contoso/gateway.git' -RepositoryRef ('a' * 40) -Cron '*/10 * * * *' }) -match 'five minutes')
Assert 'untagged images are refused' ((Throws { New-ClaudeUsdReconcilerParameters -GatewayResourceId x -WorkspaceResourceId y -WorkspaceCustomerId z -RepositoryUrl 'https://github.com/contoso/gateway.git' -RepositoryRef ('a' * 40) -Image 'mcr.microsoft.com/azure-cli' }) -match 'tag-pinned')

Assert 'template uses Container Apps schedule trigger' ($template -match "triggerType: 'Schedule'" -and $template -match "cronExpression: cronExpression")
Assert 'template defaults to every five minutes' ($template.Contains("param cronExpression string = '*/5 * * * *'"))
Assert 'template command and args are JSON arrays, not CLI inline args' ($template -match "(?s)command:\s*\[\s*'/bin/bash'\s*'-c'" -and $template -notmatch '--args')
Assert 'template runs the shared USD command engine' ($template -match 'python3 -m aum_service.usd_command' -and $template -match '--managed-identity')
Assert 'template fetches pinned repository ref' ($template.Contains('archive = f"{repo}/archive/{ref}.tar.gz"') -and $template -notmatch 'git clone.*main')
Assert 'template uses user-assigned managed identity' ($template -match 'Microsoft.ManagedIdentity/userAssignedIdentities' -and $template -match "type: 'UserAssigned'")
Assert 'gateway role has only named-value writer actions' ($template -match 'Microsoft.ApiManagement/service/namedValues/write' -and $template -notmatch 'Microsoft.ApiManagement/service/apis/write' -and $template -notmatch 'Microsoft.ApiManagement/service/policies/write')
Assert 'gateway role assignment is scoped to the gateway resource' ($template -match 'scope: gateway' -and $template -match 'roleDefinitionId: writerRole.id')
Assert 'workspace role is Log Analytics Reader' ($template -match "73c42c96-874c-492b-b04d-ab87d138a893" -and $template -match 'workspaceReader')
Assert 'arguments carry no secrets' ($template -notmatch 'secretRef|connectionString|listKeys\(')
Assert 'logs use diagnostic setting to workspace, not shared key' ($template -match 'diagnosticSettings' -and $template -notmatch 'workspaceKey|sharedKey')

if ($fail) { throw "$fail USD reconciler schedule assertion(s) failed." }
Write-Host 'USD reconciler schedule contract holds.' -ForegroundColor Green
