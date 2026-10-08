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
Assert 'template suffix excludes repositoryRef so commit upgrades keep names stable' ($template -match 'uniqueString\(resourceGroup\(\)\.id, gatewayResourceId, workspaceResourceId\)' -and $template -notmatch 'uniqueString\([^\r\n]*repositoryRef')
$compiled = az bicep build --file (Join-Path $root 'infra\usd-reconciler-job.bicep') --stdout | ConvertFrom-Json
$suffixExpression = [string]$compiled.variables.suffix
Assert 'compiled template suffix excludes repositoryRef' ($suffixExpression -match 'gatewayResourceId' -and $suffixExpression -match 'workspaceResourceId' -and $suffixExpression -notmatch 'repositoryRef') $suffixExpression
Assert 'compiled resource names are unchanged by a different repositoryRef' ($suffixExpression -notmatch 'repositoryRef' -and ($compiled.resources | ConvertTo-Json -Depth 20) -match 'repositoryRef')
$compiledJson = $compiled | ConvertTo-Json -Depth 80
Assert 'template delegates workspace role assignment to the principalId-keyed access module' ($compiledJson -match 'usd-reconciler-logs-access-' -and $compiledJson -match "guid\(resourceId\('Microsoft\.OperationalInsights/workspaces', parameters\('workspaceName'\)\), parameters\('principalId'\), variables\('logsReader'\)\)") $compiledJson
Assert 'template delegates gateway role assignment to the principalId-keyed access module' ($compiledJson -match 'usd-reconciler-gateway-access-' -and $compiledJson -match "guid\(resourceId\('Microsoft\.ApiManagement/service', parameters\('gatewayName'\)\), parameters\('principalId'\), parameters\('writerRoleDefinitionId'\)\)") $compiledJson
Assert 'compiled role assignment names never key on the user-assigned identity resource id' ($compiledJson -notmatch 'guid\([^\r\n]*identity\.id') $compiledJson
$gatewayAccessDeployment = @($compiled.resources | Where-Object { [string]$_.name -match 'usd-reconciler-gateway-access' })[0]
$logsAccessDeployment = @($compiled.resources | Where-Object { [string]$_.name -match 'usd-reconciler-logs-access' })[0]
$identityPrincipalExpression = "reference(resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', format('id-usd-reconcile-{0}', variables('suffix'))), '2023-01-31').principalId"
Assert 'gateway access module receives the runtime identity principalId, not the identity resource id' ([string]$gatewayAccessDeployment.properties.parameters.principalId.value -eq "[$identityPrincipalExpression]") ([string]$gatewayAccessDeployment.properties.parameters.principalId.value)
Assert 'logs access module receives the runtime identity principalId, not the identity resource id' ([string]$logsAccessDeployment.properties.parameters.principalId.value -eq "[$identityPrincipalExpression]") ([string]$logsAccessDeployment.properties.parameters.principalId.value)
Assert 'gateway access module receives the reconciler writer role definition id' ([string]$gatewayAccessDeployment.properties.parameters.writerRoleDefinitionId.value -eq "[resourceId('Microsoft.Authorization/roleDefinitions', guid(parameters('gatewayResourceId'), 'usd-reconciler-writer'))]") ([string]$gatewayAccessDeployment.properties.parameters.writerRoleDefinitionId.value)
Assert 'template command and args are JSON arrays, not CLI inline args' ($template -match "(?s)command:\s*\[\s*'/bin/bash'\s*'-c'" -and $template -notmatch '--args')
Assert 'template runs the shared USD command engine' ($template -match 'python3 -m aum_service.usd_command' -and $template -match '--managed-identity')
Assert 'template fetches pinned repository ref' ($template.Contains('archive = f"{repo}/archive/{ref}.tar.gz"') -and $template -notmatch 'git clone.*main')
Assert 'template uses user-assigned managed identity' ($template -match 'Microsoft.ManagedIdentity/userAssignedIdentities' -and $template -match "type: 'UserAssigned'")
Assert 'gateway role has only named-value writer actions' ($template -match 'Microsoft.ApiManagement/service/namedValues/write' -and $template -notmatch 'Microsoft.ApiManagement/service/apis/write' -and $template -notmatch 'Microsoft.ApiManagement/service/policies/write')
Assert 'gateway role assignment is scoped to the gateway resource' ($template -match "module gatewayAccess 'aum-gateway-access.bicep'" -and $template -match 'writerRoleDefinitionId: writerRole.id')
Assert 'workspace role is Log Analytics Reader' ($template -match "module logsAccess 'aum-logs-access.bicep'")
Assert 'arguments carry no secrets' ($template -notmatch 'secretRef|connectionString|listKeys\(')
Assert 'logs use diagnostic setting to workspace, not shared key' ($template -match 'diagnosticSettings' -and $template -notmatch 'workspaceKey|sharedKey')

Write-Host ''
Write-Host 'USD reconciler schedule upgrade cleanup' -ForegroundColor Cyan

$register = Join-Path $root 'scripts\Register-ClaudeUsdReconciler.ps1'
$global:UsdCalls = [Collections.Generic.List[string]]::new()
$global:UsdJobs = @()
$global:UsdShown = @{}
$global:UsdDeploymentFails = $false
$global:UsdDeleted = @()
$global:UsdDeploymentEnvironmentName = 'cae-usd-reconcile-stable'
$global:UsdNow = [datetime]'2026-10-08T10:00:00Z'
$global:UsdRestGets = @()
$global:UsdGetCount = 0
$global:UsdRestPostFailures = 0
$global:UsdPostCount = 0
function New-JobListItem($Name) {
    [pscustomobject]@{
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/jobs/$Name"
        name = $Name
        tags = [pscustomobject]@{ component = 'usd-reconciler' }
    }
}
function New-JobDetail($Name, $Gateway, $EnvironmentId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-$Name", $PrincipalId = '22222222-2222-2222-2222-222222222222') {
    $identityId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$Name"
    [pscustomobject]@{
        id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/jobs/$Name"
        name = $Name
        identity = [pscustomobject]@{
            userAssignedIdentities = [pscustomobject]@{
                $identityId = [pscustomobject]@{ principalId = $PrincipalId }
            }
        }
        properties = [pscustomobject]@{
            environmentId = $EnvironmentId
            template = [pscustomobject]@{ containers = @([pscustomobject]@{ env = @(
                [pscustomobject]@{ name = 'GATEWAY_ID'; value = $Gateway },
                [pscustomobject]@{ name = 'REPO_REF'; value = 'old' }
            ) }) }
        }
    }
}
function New-Execution($Name, $Status, $Start, $End = $null) {
    [pscustomobject]@{
        name = $Name
        properties = [pscustomobject]@{
            status = $Status
            startTime = ([datetime]$Start).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss+00:00", [Globalization.CultureInfo]::InvariantCulture)
            endTime = $(if ($End) { ([datetime]$End).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss+00:00", [Globalization.CultureInfo]::InvariantCulture) } else { $null })
        }
    }
}
function global:az {
    $global:UsdCalls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'account show*') { return '00000000-0000-0000-0000-000000000000' }
    if ($line -like 'apim show*--query location*') { return 'eastus2' }
    if ($line -like 'apim show*--query id*') { return '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test' }
    if ($line -like 'resource list*') { return ($global:UsdJobs | ConvertTo-Json -Depth 20 -Compress) }
    if ($line -like 'resource show*') {
        $id = [string]$args[[array]::IndexOf($args, '--ids') + 1]
        return ($global:UsdShown[$id] | ConvertTo-Json -Depth 30 -Compress)
    }
    if ($line -like 'deployment group create*') {
        if ($global:UsdDeploymentFails) { $global:LASTEXITCODE = 1; return 'denied' }
        return (@{ jobName = @{ value = 'job-usd-reconcile-stable' }; jobId = @{ value = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/jobs/job-usd-reconcile-stable' }; environmentName = @{ value = $global:UsdDeploymentEnvironmentName }; principalId = @{ value = 'principal' }; cronExpression = @{ value = '*/5 * * * *' } } | ConvertTo-Json -Depth 10 -Compress)
    }
    if ($line -like 'resource delete*') {
        $global:UsdDeleted += [string]$args[[array]::IndexOf($args, '--ids') + 1]
        return ''
    }
    if ($line -like 'rest --method post*') {
        $global:UsdPostCount++
        if ($global:UsdRestPostFailures -gt 0) {
            $global:UsdRestPostFailures--
            $global:LASTEXITCODE = 1
            return 'HTTP 403'
        }
        return ''
    }
    if ($line -like 'rest --method get*executions*') {
        $index = [math]::Min($global:UsdRestGets.Count - 1, $global:UsdGetCount)
        $global:UsdGetCount++
        $value = if ($global:UsdRestGets.Count) { @($global:UsdRestGets[$index]) } else { @() }
        return (@{ value = $value } | ConvertTo-Json -Depth 20 -Compress)
    }
    throw "Unexpected az call: $line"
}
function Invoke-Register($Jobs, $Shown, [switch]$FailDeploy, [string]$ExistingEnvironmentId = '', [string]$OutputEnvironmentName = '', $RestGets = @(@(New-Execution 'run-ok' Succeeded '2026-10-08T10:00:20Z' '2026-10-08T10:00:40Z')), [int]$PostFailures = 0, [switch]$RunNow) {
    $global:UsdCalls.Clear(); $global:UsdDeleted = @(); $global:UsdJobs = $Jobs; $global:UsdShown = $Shown; $global:UsdDeploymentFails = [bool]$FailDeploy
    $global:UsdDeploymentEnvironmentName = if ($OutputEnvironmentName) { $OutputEnvironmentName } elseif ($ExistingEnvironmentId) { ($ExistingEnvironmentId -split '/')[-1] } else { 'cae-usd-reconcile-stable' }
    $global:UsdNow = [datetime]'2026-10-08T10:00:00Z'; $global:UsdRestGets = @($RestGets); $global:UsdGetCount = 0; $global:UsdRestPostFailures = $PostFailures; $global:UsdPostCount = 0
    & $register -ResourceGroup rg-test -ApimName apim-test `
        -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test' `
        -WorkspaceCustomerId '11111111-1111-1111-1111-111111111111' `
        -RepositoryUrl 'https://github.com/contoso/gateway.git' -RepositoryRef ('b' * 40) -Location eastus2 -ExistingEnvironmentId $ExistingEnvironmentId `
        -RunNow:$RunNow -Clock { $global:UsdNow } -Sleep { param($Seconds) $global:UsdNow = $global:UsdNow.AddSeconds($Seconds) } *>&1
}
$gateway = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test'
$otherGateway = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-other'
$old = New-JobListItem 'job-usd-reconcile-old'
$stable = New-JobListItem 'job-usd-reconcile-stable'
$other = New-JobListItem 'job-usd-reconcile-other'
$shown = @{
    $old.id = New-JobDetail 'job-usd-reconcile-old' $gateway
    $stable.id = New-JobDetail 'job-usd-reconcile-stable' $gateway
    $other.id = New-JobDetail 'job-usd-reconcile-other' $otherGateway
}
$parserErrors = $null
$registerAst = [System.Management.Automation.Language.Parser]::ParseFile($register, [ref]$null, [ref]$parserErrors)
$registerText = Get-Content $register -Raw
Assert 'Azure resource-name cleanup comparisons use explicit ordinal string equality' ($registerText -notmatch '\$envName\s+-and\s+\$envName\s+-in' -and $registerText -notmatch '\$envId\s+-and\s+\$envId\s+-in' -and $registerText -notmatch '\$_.name\s+-ne\s+\[string\]\$outputs\.jobName\.value') $registerText
$utcAst = $registerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertTo-ClaudeUsdReconcilerUtc' }, $true)
if ($utcAst) {
    . ([scriptblock]::Create($utcAst.Extent.Text))
    $local = [datetime]::SpecifyKind([datetime]'2026-10-08T15:30:00', [DateTimeKind]::Local)
    Assert 'execution time helper keeps +00:00 strings as UTC' ((ConvertTo-ClaudeUsdReconcilerUtc '2026-10-08T10:00:00+00:00').ToString('o') -eq '2026-10-08T10:00:00.0000000Z')
    Assert 'execution time helper converts offset strings through DateTimeOffset' ((ConvertTo-ClaudeUsdReconcilerUtc '2026-10-08T15:30:00+05:30').ToString('o') -eq '2026-10-08T10:00:00.0000000Z')
    Assert 'execution time helper converts Local DateTime directly' ((ConvertTo-ClaudeUsdReconcilerUtc $local).ToString('o') -eq $local.ToUniversalTime().ToString('o'))
    Assert 'execution time helper preserves Utc DateTime' ((ConvertTo-ClaudeUsdReconcilerUtc ([datetime]'2026-10-08T10:00:00Z')).ToString('o') -eq '2026-10-08T10:00:00.0000000Z')
}
else {
    Assert 'execution time helper exists' $false 'ConvertTo-ClaudeUsdReconcilerUtc missing'
}
$none = @(Invoke-Register @() @{})
Assert 'no earlier job and no RunNow means no delete and no ARM start/poll' ($global:UsdDeleted.Count -eq 0 -and ($global:UsdCalls -join '|') -notmatch 'containerapp job delete|resource delete|/start\?|/executions\?')
$firstFailedThenSucceeded = @(
    @(New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'),
    @(New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'),
    @((New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'), (New-Execution 'run-ok' Succeeded '2026-10-08T10:01:40Z' '2026-10-08T10:02:00Z'))
)
$cleanup = @(Invoke-Register @($old, $stable, $other) $shown -RestGets $firstFailedThenSucceeded)
$deployIndex = [array]::FindIndex($global:UsdCalls.ToArray(), [Predicate[string]]{ param($x) $x -like 'deployment group create*' })
$deleteIndex = [array]::FindIndex($global:UsdCalls.ToArray(), [Predicate[string]]{ param($x) $x -like 'resource delete*job-usd-reconcile-old*' })
Assert 'upgrade deletes old job only after a successful counted run and uses core az resource delete' ($global:UsdDeleted -contains $old.id -and $deployIndex -ge 0 -and $deleteIndex -gt ([array]::FindIndex($global:UsdCalls.ToArray(), [Predicate[string]]{ param($x) $x -like 'rest --method get*executions*' })) -and ($global:UsdCalls -join '|') -notmatch 'containerapp job delete') ($global:UsdCalls -join ' | ')
Assert 'failed first execution starts another run before cleanup' (@($global:UsdCalls | Where-Object { $_ -like 'rest --method post*/start*' }).Count -eq 3 -and ($cleanup | Out-String) -match 'Run run-fail failed' -and ($cleanup | Out-String) -match 'Run run-ok succeeded')
Assert 'another gateway reconciler job is untouched' ($global:UsdDeleted -notcontains $other.id)
$cleanupText = $cleanup | Out-String
$workspaceRoleLine = $cleanupText.IndexOf('az role assignment delete --assignee 22222222-2222-2222-2222-222222222222 --scope /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test')
$gatewayRoleLine = $cleanupText.IndexOf('az role assignment delete --assignee 22222222-2222-2222-2222-222222222222 --scope /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ApiManagement/service/apim-test')
$identityLine = $cleanupText.IndexOf('az identity delete')
Assert 'cleanup prints old identity role assignment deletes before the identity delete' ($workspaceRoleLine -ge 0 -and $gatewayRoleLine -ge 0 -and $identityLine -gt $workspaceRoleLine -and $identityLine -gt $gatewayRoleLine) $cleanupText
Assert 'cleanup prints leftover identity and environment delete commands' ($identityLine -ge 0 -and $cleanupText -match 'az containerapp env delete')
$finalRun = @(Invoke-Register @($old, $stable) $shown -RestGets @(
    @((New-Execution 'pre-delete-ok' Succeeded '2026-10-08T10:00:01Z' '2026-10-08T10:00:10Z')),
    @((New-Execution 'pre-delete-ok' Succeeded '2026-10-08T10:00:01Z' '2026-10-08T10:00:10Z')),
    @((New-Execution 'pre-delete-ok' Succeeded '2026-10-08T10:00:01Z' '2026-10-08T10:00:10Z'), (New-Execution 'post-delete-ok' Succeeded '2026-10-08T10:01:00Z' '2026-10-08T10:01:20Z'))
))
Assert 'after deleting old jobs the new job is started once more and only a post-delete execution satisfies the final wait' (@($global:UsdCalls | Where-Object { $_ -like 'rest --method post*/start*' }).Count -eq 2 -and ($finalRun | Out-String) -match 'state now comes from job job-usd-reconcile-stable' -and ($finalRun | Out-String) -notmatch 'Run pre-delete-ok succeeded at .*state now') ($finalRun | Out-String)
Assert 'the final run is returned separately from the make-before-break run' (($finalRun[-1].Run.Execution -eq 'pre-delete-ok') -and ($finalRun[-1].FinalRun.Execution -eq 'post-delete-ok')) ($finalRun[-1] | ConvertTo-Json -Depth 10)
$finalRunFailed = @(Invoke-Register @($old, $stable) $shown -RestGets @(
    @((New-Execution 'pre-delete-ok' Succeeded '2026-10-08T10:00:01Z' '2026-10-08T10:00:10Z')),
    @((New-Execution 'post-delete-fail' Failed '2026-10-08T10:01:00Z' '2026-10-08T10:01:20Z')),
    @((New-Execution 'post-delete-fail' Failed '2026-10-08T10:01:00Z' '2026-10-08T10:01:20Z'))
))
Assert 'failed post-delete final run warns but does not throw after old jobs are deleted' ($global:UsdDeleted -contains $old.id -and ($finalRunFailed | Out-String) -match 'old USD reconciler jobs are deleted' -and $finalRunFailed[-1].FinalRun.Status -eq 'Failed') ($finalRunFailed | Out-String)
$sharedEnvId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-shared'
$shared = New-JobListItem 'job-usd-reconcile-shared'
$sharedShown = @{
    $shared.id = New-JobDetail 'job-usd-reconcile-shared' $gateway $sharedEnvId
    $stable.id = New-JobDetail 'job-usd-reconcile-stable' $gateway $sharedEnvId
}
$sharedCleanup = @(Invoke-Register @($shared, $stable) $sharedShown -ExistingEnvironmentId $sharedEnvId)
Assert 'cleanup does not print an environment delete for the environment passed to the new deployment' (($sharedCleanup | Out-String) -match 'az identity delete' -and ($sharedCleanup | Out-String) -notmatch 'az containerapp env delete')
$sameOutputEnv = @(Invoke-Register @($shared, $stable) $sharedShown -OutputEnvironmentName 'cae-shared')
Assert 'cleanup does not print an environment delete for the environment returned by the deployment' (($sameOutputEnv | Out-String) -match 'az identity delete' -and ($sameOutputEnv | Out-String) -notmatch 'az containerapp env delete')
$failed = Throws { Invoke-Register @($old, $stable) $shown -FailDeploy }
Assert 'failed deployment does not delete earlier jobs' ($failed -and $global:UsdDeleted.Count -eq 0) $failed
$noSuccess = @(Invoke-Register @($old, $stable) $shown -RestGets @(@(New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z')))
Assert 'upgrade keeps old job and reports logs when no new run succeeds' ($global:UsdDeleted.Count -eq 0 -and ($noSuccess | Out-String) -match 'kept' -and ($noSuccess | Out-String) -match 'ContainerAppConsoleLogs' -and ($noSuccess | Out-String) -match 'Status=Failed') ($noSuccess | Out-String)
Assert 'last failed execution after retry window stops without polling to hard cap' ($global:UsdNow -le ([datetime]'2026-10-08T10:13:30Z')) ("clock=$global:UsdNow gets=$global:UsdGetCount")
$scheduledAfterEmptyStart = @(Invoke-Register @($old, $stable) $shown -RestGets @(@(New-Execution 'scheduled-ok' Succeeded '2026-10-08T10:00:30Z' '2026-10-08T10:00:50Z')))
Assert 'empty POST body with scheduled success counts and deletes old job' ($global:UsdDeleted -contains $old.id -and ($scheduledAfterEmptyStart | Out-String) -match 'scheduled-ok')
$oldThenNew = @(Invoke-Register @($old, $stable) $shown -RestGets @(
    @((New-Execution 'old-ok' Succeeded '2026-10-08T09:59:00Z' '2026-10-08T09:59:30Z'), (New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z')),
    @((New-Execution 'old-ok' Succeeded '2026-10-08T09:59:00Z' '2026-10-08T09:59:30Z'), (New-Execution 'new-ok' Succeeded '2026-10-08T10:01:40Z' '2026-10-08T10:02:00Z'))
))
Assert 'success before deployStartedUtc does not count' (($oldThenNew | Out-String) -notmatch 'Run old-ok succeeded' -and ($oldThenNew | Out-String) -match 'Run new-ok succeeded')
$postFailure = @(Invoke-Register @($old, $stable) $shown -PostFailures 1 -RestGets @(@(New-Execution 'run-ok' Succeeded '2026-10-08T10:01:40Z' '2026-10-08T10:02:00Z')))
Assert 'failed POST start is retried within the window and then reported by a later run' (@($global:UsdCalls | Where-Object { $_ -like 'rest --method post*/start*' }).Count -eq 3 -and ($postFailure | Out-String) -match 'Run run-ok succeeded')
$previousThenRunning = @(Invoke-Register @($old, $stable) $shown -RestGets @(
    @(New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'),
    @(New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'),
    @((New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'), (New-Execution 'run-new' Running '2026-10-08T10:01:35Z')),
    @((New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z'), (New-Execution 'run-new' Succeeded '2026-10-08T10:01:35Z' '2026-10-08T10:02:00Z'))
))
Assert 'same failed execution is handled once while a later execution appears' (@($global:UsdCalls | Where-Object { $_ -like 'rest --method post*/start*' }).Count -eq 3 -and ($previousThenRunning | Out-String) -match 'Run run-new succeeded')
$rerun = @(Invoke-Register @($old, $stable) $shown -ExistingEnvironmentId $sharedEnvId -RestGets @(@(New-Execution 'run-fail' Failed '2026-10-08T10:00:10Z' '2026-10-08T10:00:20Z')) -RunNow)
Assert 'no-success rerun command preserves operator parameters' (($rerun | Out-String) -match "-ExistingEnvironmentId '$([regex]::Escape($sharedEnvId))'" -and ($rerun | Out-String) -match "-Location 'eastus2'" -and ($rerun | Out-String) -match "-Image 'python:3.12.11-slim-bookworm'" -and ($rerun | Out-String) -match "-Cron '\*/5 \* \* \* \*'")
Assert 'no Container Apps extension start or execution commands are used' (($global:UsdCalls -join '|') -notmatch 'containerapp job start|containerapp job execution')

if ($fail) { throw "$fail USD reconciler schedule assertion(s) failed." }
Write-Host 'USD reconciler schedule contract holds.' -ForegroundColor Green
