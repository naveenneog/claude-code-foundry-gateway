# P84 boundary fixtures. Unexpected Azure/HTTP calls fail; no real credentials are used.
function Reset-ProjectionFixture {
    param([string]$Case = 'healthy')
    $global:FixtureCase = $Case
    $global:FixtureCalls = [Collections.Generic.List[string]]::new()
    $global:FixtureWaits = [Collections.Generic.List[int]]::new()
    $global:FixtureProbes = 0
    $script:ClaudeNetworkTokens = @{}
    $global:FixtureSubscription = '00000000-0000-4000-8000-000000000084'
    $global:FixtureTenant = '00000000-0000-4000-8000-000000000085'
    $global:FixtureApp = '00000000-0000-4000-8000-000000000086'
    $global:FixtureGroupId = '00000000-0000-4000-8000-000000000087'
    $global:FixtureRgId = "/subscriptions/$FixtureSubscription/resourceGroups/rg-p84"
    $global:FixtureGatewayId = "$FixtureRgId/providers/Microsoft.ApiManagement/service/apim-p84"
    $global:FixtureCosmosId = "$FixtureRgId/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-p84fixture"
    $global:FixtureJobId = "$FixtureRgId/providers/Microsoft.App/jobs/projection-renewal"
    $global:FixtureCae = 'Continuous access evaluation resulted in challenge with result: InteractionRequired and code: LocationConditionEvaluationSatisfied'
    $global:FixtureEnvironment = [ordered]@{
        CLAUDE_PROJECTION_CONTRACT = '1'
        PROJECTION_GATEWAY_RESOURCE_ID = $FixtureGatewayId
        PROJECTION_ACCOUNT_RESOURCE_ID = $FixtureCosmosId
        PROJECTION_TENANT_ID = $FixtureTenant
        PROJECTION_DATABASE = 'claude'
        PROJECTION_CONTAINER = 'entitlement'
        PROJECTION_MAX_AGE_SECONDS = '7200'
    }
    $container = @{
        name = 'reconciler'; image = ('example.invalid/projection@sha256:' + ('a' * 64))
        command = @('pwsh'); args = @('-NoProfile', '-File', '/app/reconcile.ps1')
        env = @($FixtureEnvironment.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
    }
    $global:FixtureJob = @{
        id = $FixtureJobId; type = 'Microsoft.App/jobs'
        properties = @{
            provisioningState = 'Succeeded'
            configuration = @{ triggerType = 'Schedule'; replicaTimeout = 300; scheduleTriggerConfig = @{ cronExpression = '0 * * * *' } }
            template = @{ containers = @($container); initContainers = @() }
        }
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $global:FixtureExecution = @{
        id = "$FixtureJobId/executions/recent"; name = 'recent'
        properties = @{
            status = 'Succeeded'
            startTime = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
            endTime = [DateTimeOffset]::UtcNow.AddMinutes(-9).ToString('o')
            template = $FixtureJob.properties.template
        }
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $global:FixtureExecutions = @($FixtureExecution)
    $global:LASTEXITCODE = 0
}

function az {
    $words = @($args); $line = $words -join ' '
    $global:FixtureCalls.Add("az $line")
    $global:LASTEXITCODE = 0
    if ($line -like 'account show*') {
        if ($FixtureCase -eq 'signed-out') { $global:LASTEXITCODE = 1; return }
        return (@{ id = $FixtureSubscription; tenantId = $FixtureTenant; state = 'Enabled'; user = @{ type = 'user'; name = 'fixture@example.invalid' } } | ConvertTo-Json -Compress)
    }
    if ($line -like 'account get-access-token*') {
        if ($FixtureCase -eq 'token-error') { $global:LASTEXITCODE = 1; return }
        if ($line -match '--query accessToken') { return 'offline-token' }
        return '{"accessToken":"offline-token"}'
    }
    if ($line -like 'group show*') {
        return (@{ id = $FixtureRgId; location = 'eastus2' } | ConvertTo-Json -Compress)
    }
    if ($line -like 'apim show*') {
        $id = if ($FixtureCase -eq 'wrong-subscription') { $FixtureGatewayId.Replace($FixtureSubscription, $FixtureTenant) } else { $FixtureGatewayId }
        $identity = if ($FixtureCase -eq 'no-identity') { @{} } else { @{ principalId = $FixtureGroupId; tenantId = $FixtureTenant } }
        $sku = if ($FixtureCase -eq 'wrong-sku') { 'PremiumV2' } else { 'BasicV2' }
        return (@{ id = $id; identity = $identity; sku = @{ name = $sku } } | ConvertTo-Json -Depth 5 -Compress)
    }
    if ($line -like 'ad sp show*') {
        if ($FixtureCase -eq 'sp-error') { $global:LASTEXITCODE = 1; return }
        if ($line -match '--query appId') { return $FixtureApp }
        return (@{ appId = $FixtureApp } | ConvertTo-Json -Compress)
    }
    if ($line -like 'ad signed-in-user show*') { return (@{ id = $FixtureGroupId; userType = 'Member' } | ConvertTo-Json -Compress) }
    if ($line -like 'ad group show*') {
        if ($FixtureCase -match '^(group-|cae$|network$|401$|403$)') { $global:LASTEXITCODE = 1; return }
        return $FixtureGroupId
    }
    if ($line -like 'ad app list*') {
        if ($FixtureCase -eq 'app-list-error') { $global:LASTEXITCODE = 1; return }
        if ($FixtureCase -eq 'existing-app') { return ('[{"appId":"' + $FixtureApp + '","identifierUris":["api://' + $FixtureApp + '"]}]') }
        return '[]'
    }
    if ($line -like 'ad app show*') {
        if ($FixtureCase -eq 'app-error') { $global:LASTEXITCODE = 1; return }
        $uri = if ($FixtureCase -eq 'app-uri') { 'api://wrong' } else { "api://$FixtureApp" }
        return (@{ appId = $FixtureApp; identifierUris = @($uri) } | ConvertTo-Json -Compress)
    }
    if ($line -like 'ad app create*') {
        if ($FixtureCase -eq 'app-create-denied') { $global:LASTEXITCODE = 1; return 'ERROR: Insufficient privileges to complete the operation.' }
        if ($FixtureCase -eq 'app-create-empty') { return '{}' }
        return (@{ appId = $FixtureApp } | ConvertTo-Json -Compress)
    }
    if ($line -like 'ad app update*') { return '{}' }
    if ($line -like 'provider list*') {
        $providers = foreach ($name in @('Microsoft.App','Microsoft.DocumentDB','Microsoft.Web','Microsoft.ContainerInstance','Microsoft.Network','Microsoft.Storage','Microsoft.OperationalInsights','Microsoft.Insights','Microsoft.Authorization')) {
            @{ namespace = $name; registrationState = $(if ($FixtureCase -eq "provider:$name") { 'NotRegistered' } else { 'Registered' }) }
        }
        return (ConvertTo-Json -InputObject @($providers) -Compress)
    }
    if ($line -like 'role assignment list*') {
        $ids = @('8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
        if ($FixtureCase -eq 'contributor-uaa') { $ids = @('b24988ac-6180-42a0-ab88-20f7382dd24c', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9') }
        if ($FixtureCase -eq 'contributor-only') { $ids = @('b24988ac-6180-42a0-ab88-20f7382dd24c') }
        if ($FixtureCase -eq 'role-custom') { $ids = @($FixtureApp) }
        if ($FixtureCase -eq 'role-error') { $global:LASTEXITCODE = 1; return }
        $roles = foreach ($id in $ids) {
            @{ roleDefinitionId = "/subscriptions/$FixtureSubscription/providers/Microsoft.Authorization/roleDefinitions/$id"
               scope = $(if ($FixtureCase -eq 'role-child') { "$FixtureRgId/providers/Microsoft.Web/sites/one-site" } else { $FixtureRgId })
               condition = $(if ($FixtureCase -eq 'role-conditional') { 'conditional assignment' } else { $null })
               roleDefinitionName = 'Owner' }
        }
        return (ConvertTo-Json -InputObject @($roles) -Compress)
    }
    if ($line -like 'resource list*') {
        if ($FixtureCase -eq 'owned-names') {
            return (@(
                @{ id = $FixtureCosmosId; type = 'Microsoft.DocumentDB/databaseAccounts'; name = 'cosmos-p84fixture' }
                @{ id = "$FixtureRgId/providers/Microsoft.Storage/storageAccounts/stres52p2c4jfs43ig"; type = 'Microsoft.Storage/storageAccounts'; name = 'stres52p2c4jfs43ig' }
                @{ id = "$FixtureRgId/providers/Microsoft.Web/sites/func-resolver-p84fixture"; type = 'Microsoft.Web/sites'; name = 'func-resolver-p84fixture' }
            ) | ConvertTo-Json -Compress)
        }
        return '[]'
    }
    if ($line -like 'cosmosdb check-name-exists*') {
        if ($FixtureCase -eq 'cosmos-error') { $global:LASTEXITCODE = 1; return }
        if ($FixtureCase -eq 'cosmos-shape') { return '{}' }
        return $(if ($FixtureCase -in @('cosmos-taken','owned-names')) { 'true' } else { 'false' })
    }
    if ($line -like 'storage account check-name*') {
        if ($FixtureCase -eq 'storage-error') { $global:LASTEXITCODE = 1; return }
        if ($FixtureCase -eq 'storage-shape') { return '{"nameAvailable":"true"}' }
        return $(if ($FixtureCase -in @('storage-taken','owned-names')) { '{"nameAvailable":false}' } else { '{"nameAvailable":true}' })
    }
    if ($line -like 'bicep version*') {
        if ($FixtureCase -eq 'tool:bicep') { $global:LASTEXITCODE = 1; return }
        return '{"bicepVersion":"0.46.1"}'
    }
    if ($line -like 'bicep build-params*') {
        if ($FixtureCase -in @('bicep-evaluation','tool:bicep')) { $global:LASTEXITCODE = 1; return }
        if ($FixtureCase -eq 'bicep-shape') { return '{"parametersJson":"{}"}' }
        $params = @{ parameters = @{ storageName = @{ value = 'stres52p2c4jfs43ig' } } } | ConvertTo-Json -Compress -Depth 5
        return (@{ parametersJson = $params } | ConvertTo-Json -Compress)
    }
    if ($line -like 'container exec*') {
        if ($FixtureCase -eq 'runner-exit') { $global:LASTEXITCODE = 9; return 'runner transport failed' }
        return '{"ok":true}'
    }
    throw "UNEXPECTED AZURE CALL (offline fixture): $line"
}

function Get-Command {
    param($Name, $ErrorAction, $CommandType)
    if ($Name -in @('node','npm','tar','az')) {
        if ($FixtureCase -eq "tool:$Name") { return $null }
        return [pscustomobject]@{ Name = $Name; Source = 'offline-fixture'; CommandType = 'Function' }
    }
    Microsoft.PowerShell.Core\Get-Command -Name $Name -ErrorAction SilentlyContinue
}

function Start-Sleep {
    param([int]$Seconds)
    $global:FixtureCalls.Add("sleep $Seconds")
    $global:FixtureWaits.Add($Seconds)
}

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $ErrorAction, $TimeoutSec, $Body, $ContentType, [switch]$UseBasicParsing)
    $url = [uri]::UnescapeDataString([string]$Uri)
    $global:FixtureCalls.Add("HTTP $Method $url")
    if ($url -like 'https://graph.microsoft.com/v1.0/me*') {
        $global:FixtureProbes++
        if ($FixtureCase -eq 'cae' -or ($FixtureCase -eq 'cae-second' -and $FixtureProbes -eq 2)) { throw $FixtureCae }
        if ($FixtureCase -eq 'network') { throw 'Graph network connection failed' }
        return [pscustomobject]@{ id = $FixtureGroupId; userType = $(if ($FixtureCase -eq 'guest') { 'Guest' } else { 'Member' }) }
    }
    if ($url -like 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy*') {
        if ($FixtureCase -eq 'policy-error') { throw '403 Policy.Read.All is required' }
        return [pscustomobject]@{ defaultUserRolePermissions = @{ allowedToCreateApps = $(if ($FixtureCase -eq 'policy-false') { $false } elseif ($FixtureCase -eq 'policy-shape') { 'true' } else { $true }) } }
    }
    if ($url.StartsWith('https://graph.microsoft.com/v1.0/groups?')) {
        if ($FixtureCase -eq 'cae') { throw $FixtureCae }
        if ($FixtureCase -in @('401','403','network','group-error')) { throw "Graph $FixtureCase lookup failed" }
        if ($FixtureCase -eq 'group-shape') { return [pscustomobject]@{} }
        if ($FixtureCase -eq 'group-missing' -or ($FixtureCase -eq 'standard-missing' -and $url -match 'claude-code-standard') -or ($FixtureCase -eq 'premium-missing' -and $url -match 'claude-code-premium')) { return [pscustomobject]@{ value = @() } }
        $groups = @([pscustomobject]@{ id = $FixtureGroupId; displayName = 'fixture' })
        if ($FixtureCase -eq 'group-duplicate') { $groups += [pscustomobject]@{ id = $FixtureApp; displayName = 'fixture' } }
        return [pscustomobject]@{ value = $groups }
    }
    if ($url -like 'https://graph.microsoft.com/v1.0/groups/*/transitiveMembers/*') {
        if ($FixtureCase -eq 'member-error') { throw 'Graph 403 membership denied' }
        if ($FixtureCase -eq 'member-shape') { return [pscustomobject]@{} }
        $response = @{ value = @([pscustomobject]@{ id = $FixtureApp; userPrincipalName = 'user@example.invalid'; displayName = 'user' }) }
        if ($FixtureCase -eq 'member-nextlink') { $response['@odata.nextLink'] = 'https://example.invalid/steal-token' }
        return [pscustomobject]$response
    }
    if ($url -like 'https://management.azure.com/*/checkNameAvailability?*') {
        if ($FixtureCase -eq 'site-error') { throw 'Site availability lookup failed' }
        if ($FixtureCase -eq 'site-shape') { return [pscustomobject]@{} }
        return [pscustomobject]@{ nameAvailable = ($FixtureCase -notin @('site-taken','owned-names')); reason = 'AlreadyExists' }
    }
    if ($url -eq "https://management.azure.com${FixtureJobId}?api-version=2024-03-01") {
        if ($FixtureCase -eq 'job-error') { throw 'ARM 403 job read denied' }
        return $FixtureJob
    }
    if ($url -like "https://management.azure.com$FixtureJobId/executions?*") {
        if ($FixtureCase -eq 'execution-error') { throw 'ARM execution read denied' }
        if ($FixtureCase -eq 'execution-nextlink') { return [pscustomobject]@{ value = @(); nextLink = 'https://example.invalid/steal-token' } }
        if ($FixtureCase -eq 'execution-page' -and $url -notmatch 'skiptoken') {
            return [pscustomobject]@{ value = @(); nextLink = "https://management.azure.com$FixtureJobId/executions?api-version=2024-03-01&skiptoken=second" }
        }
        return [pscustomobject]@{ value = $FixtureExecutions; nextLink = $null }
    }
    throw "UNEXPECTED HTTP CALL (offline fixture): $Method $url"
}
