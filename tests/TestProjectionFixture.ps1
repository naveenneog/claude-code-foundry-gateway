# P84 boundary fixtures. Unexpected Azure/HTTP calls fail; no real credentials are used.
function Reset-ProjectionFixture {
    param([string]$Case = 'healthy')
    $global:FixtureCase = $Case
    $global:FixtureCalls = [Collections.Generic.List[string]]::new()
    $global:FixtureWaits = [Collections.Generic.List[int]]::new()
    $global:FixtureProbes = 0
    $global:FixtureRunnerStarted = $false
    $global:FixtureBicepExpression = ''
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
        AZURE_CLIENT_ID = '00000000-0000-4000-8000-000000000088'
        PROJECTION_STANDARD_GROUP_ID = $FixtureGroupId
        PROJECTION_PREMIUM_GROUP_ID = 'none'
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
    $global:FixtureRunnerFiles = @{}
    # The resolver the gateway calls (entitlement-resolver-url/-audience) and the one deployed with the projection.
    $global:FixtureResolverUrl = switch ($Case) {
        'resolver-placeholder' { 'https://resolver-not-deployed.invalid' }
        'resolver-other-url' { 'https://func-resolver-other.azurewebsites.net/api' }
        'source-projection-other-url' { 'https://func-resolver-other.azurewebsites.net/api' }
        default { 'https://func-resolver-p84fixture.azurewebsites.net/api' }
    }
    $global:FixtureResolverAudience = if ($Case -in 'resolver-other-audience', 'source-projection-other-audience') { 'api://00000000-0000-4000-8000-0000000000dd' } else { "api://$FixtureApp" }
    $global:FixtureActionGroupId = "$FixtureRgId/providers/Microsoft.Insights/actionGroups/ag-projection-renewal"
    $global:FixtureActionGroup = [pscustomobject]@{
        id = $FixtureActionGroupId; type = 'Microsoft.Insights/ActionGroups'
        properties = [pscustomobject]@{
            enabled = ($Case -ne 'action-group-disabled')
            emailReceivers = @([pscustomobject]@{ name = 'email-0'; emailAddress = 'ops@example.invalid'; status = $(if ($Case -eq 'action-group-no-email') { 'Disabled' } else { 'Enabled' }) })
        }
    }
    $global:LASTEXITCODE = 0
}

function az {
    $words = @($args); $line = $words -join ' '
    $global:FixtureCalls.Add("az $line")
    $global:LASTEXITCODE = 0
    if ($line -like 'account show*') {
        if ($FixtureCase -eq 'signed-out') { $global:LASTEXITCODE = 1; return }
        return (@{ id = $FixtureSubscription; tenantId = $FixtureTenant; state = $(if ($FixtureCase -eq 'subscription-disabled') { 'Disabled' } else { 'Enabled' }); user = @{ type = 'user'; name = 'fixture@example.invalid' } } | ConvertTo-Json -Compress)
    }
    if ($line -like 'account get-access-token*') {
        if ($FixtureCase -eq 'token-error') { $global:LASTEXITCODE = 1; return }
        if ($FixtureCase -eq 'token-empty') { return '{}' }
        if ($line -match '--query accessToken') { return 'offline-token' }
        return '{"accessToken":"offline-token"}'
    }
    if ($line -like 'group show*') {
        return (@{ id = $(if ($FixtureCase -eq 'wrong-rg') { "$FixtureRgId-other" } else { $FixtureRgId }); location = 'eastus2' } | ConvertTo-Json -Compress)
    }
    if ($line -like 'apim show*') {
        if ($FixtureCase -eq 'apim-empty') { return '{}' }
        $id = if ($FixtureCase -eq 'wrong-subscription') { $FixtureGatewayId.Replace($FixtureSubscription, $FixtureTenant) } else { $FixtureGatewayId }
        $identity = if ($FixtureCase -eq 'no-identity') { @{} } else { @{ principalId = $FixtureGroupId; tenantId = $FixtureTenant } }
        if ($FixtureCase -eq 'wrong-tenant') { $identity.tenantId = $FixtureSubscription }
        $sku = if ($FixtureCase -eq 'wrong-sku') { 'PremiumV2' } else { 'BasicV2' }
        return (@{ id = $id; identity = $identity; sku = @{ name = $sku } } | ConvertTo-Json -Depth 5 -Compress)
    }
    if ($line -like 'apim nv show*') {
        if ($FixtureCase -eq 'nv-read-error') { $global:LASTEXITCODE = 1; return 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.ApiManagement/service/namedValues/read.' }
        $id = [string]$words[[array]::IndexOf($words, '--named-value-id') + 1]
        # A gateway that never had the projection deployed: az exits 3 with this message (measured, ApimNamedValue.ps1).
        if ($FixtureCase -in 'prefix-missing', 'source-projection-no-prefix' -and $id -eq 'entitlement-projection-prefix') { $global:LASTEXITCODE = 3; return 'ERROR: (ResourceNotFound) NamedValue not found.' }
        $resolverValues = @{ 'entitlement-resolver-url' = $FixtureResolverUrl; 'entitlement-resolver-audience' = $FixtureResolverAudience; 'entitlement-projection-prefix' = 'p84fixture'; 'allow-standard' = $(if ($FixtureCase -eq 'new-gateway') { ',' } else { ",$FixtureApp," }); 'allow-premium' = ','; 'bu-members' = ',' }
        if ($resolverValues.ContainsKey($id)) {
            if ($line -match '--query name') { return $id }
            if ($line -match '--query value') { return $resolverValues[$id] }
            return (@{ name = $id; value = $resolverValues[$id]; secret = $false } | ConvertTo-Json -Compress)
        }
        if ($line -match '--query name') { return 'entitlement-source' }
        if ($FixtureCase -like 'source-projection*' -and $id -eq 'entitlement-source' -and $line -match '--query value') { return 'projection' }
        if ($line -match '--query value') { return 'named-value' }
        return (@{ name='entitlement-source'; value='named-value'; secret=$false } | ConvertTo-Json -Compress)
    }
    if ($line -like 'deployment group show*') {
        $name = [string]$words[[array]::IndexOf($words, '-n') + 1]
        if ($name -eq 'projection-resolver-p84fixture' -and $FixtureCase -notin 'resolver-missing', 'source-projection-failed-deployment') {
            $cosmos = if ($FixtureCase -eq 'resolver-other-cosmos') { 'cosmos-other' } else { 'cosmos-p84fixture' }
            return (@{
                    parameters = @{ cosmosAccountName = @{ type = 'String'; value = $cosmos }; resolverAppId = @{ type = 'String'; value = $FixtureApp } }
                    outputs = @{ siteName = @{ type = 'String'; value = 'func-resolver-p84fixture' }; resolverUrl = @{ type = 'String'; value = 'https://func-resolver-p84fixture.azurewebsites.net/api' }; resolverAudience = @{ type = 'String'; value = "api://$FixtureApp" } }
                } | ConvertTo-Json -Depth 5 -Compress)
        }
        $global:LASTEXITCODE = 3
        return "ERROR: (DeploymentNotFound) Deployment '$name' could not be found."
    }
    # The resolver site and its live application settings (Web Apps - Get; Web Apps - List Application Settings).
    if ($line -match "^rest --method (get|post) --url https://management\.azure\.com/subscriptions/$FixtureSubscription/resourceGroups/rg-p84/providers/Microsoft\.Web/sites/func-resolver-p84fixture(/config/appsettings/list)?\?api-version=") {
        if ($Matches[2]) {
            if ($FixtureCase -eq 'resolver-settings-error') { $global:LASTEXITCODE = 1; return 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.Web/sites/config/list/action.' }
            $endpoint = if ($FixtureCase -eq 'resolver-live-cosmos') { 'https://cosmos-other.documents.azure.com:443/' } else { 'https://cosmos-p84fixture.documents.azure.com:443/' }
            $database = if ($FixtureCase -eq 'resolver-live-database') { 'claude-old' } else { 'claude' }
            $container = if ($FixtureCase -eq 'resolver-live-container') { 'entitlement-old' } else { 'entitlement' }
            $tenant = if ($FixtureCase -eq 'resolver-live-tenant') { '00000000-0000-4000-8000-0000000000ff' } else { $FixtureTenant }
            return (@{ name = 'appsettings'; properties = @{ COSMOS_ENDPOINT = $endpoint; COSMOS_DATABASE = $database; COSMOS_CONTAINER = $container; PROJECTION_TENANT_ID = $tenant; APPLICATIONINSIGHTS_CONNECTION_STRING = 'InstrumentationKey=00000000-0000-4000-8000-0000000000ee' } } | ConvertTo-Json -Depth 4 -Compress)
        }
        $hostName = if ($FixtureCase -eq 'resolver-live-host') { 'func-resolver-p84fixture-a1b2.eastus2-01.azurewebsites.net' } else { 'func-resolver-p84fixture.azurewebsites.net' }
        if ($FixtureCase -eq 'source-projection-no-site') { $global:LASTEXITCODE = 3; return "ERROR: (ResourceNotFound) The Resource 'Microsoft.Web/sites/func-resolver-p84fixture' under resource group 'rg-p84' was not found." }
        return (@{ name = 'func-resolver-p84fixture'; properties = @{ defaultHostName = $hostName; state = 'Running' } } | ConvertTo-Json -Depth 4 -Compress)
    }
    if ($line -like 'apim nv update*' -or $line -like 'apim nv create*') {
        return ''
    }
    if ($line -like 'ad sp show*') {
        if ($FixtureCase -eq 'sp-error') { $global:LASTEXITCODE = 1; return }
        # az ad sp show for an app without a service principal: exit 3 and this message (az 2.6x).
        if ($FixtureCase -eq 'sp-missing') { $global:LASTEXITCODE = 3; return "ERROR: Resource '$($words[[array]::IndexOf($words, '--id') + 1])' does not exist or one of its queried reference-property objects are not present." }
        if ($line -match '--query appId') { return $FixtureApp }
        return (@{ appId = $(if ($FixtureCase -eq 'sp-empty') { '' } else { $FixtureApp }) } | ConvertTo-Json -Compress)
    }
    if ($line -like 'ad signed-in-user show*') { return (@{ id = $FixtureGroupId; userType = 'Member' } | ConvertTo-Json -Compress) }
    if ($line -like 'ad group show*') {
        if ($FixtureCase -match '^(group-|cae$|network$|401$|403$)') { $global:LASTEXITCODE = 1; return }
        return $FixtureGroupId
    }
    if ($line -like 'ad app list*') {
        if ($FixtureCase -eq 'app-list-error') { $global:LASTEXITCODE = 1; return }
        if ($FixtureCase -eq 'existing-app') { return ('[{"appId":"' + $FixtureApp + '","identifierUris":["api://' + $FixtureApp + '"]}]') }
        if ($FixtureCase -eq 'duplicate-apps') { return ('[{"appId":"' + $FixtureApp + '"},{"appId":"' + $FixtureTenant + '"}]') }
        return '[]'
    }
    if ($line -like 'ad app show*') {
        if ($FixtureCase -eq 'app-error') { $global:LASTEXITCODE = 1; return }
        $returnedAppId = if ($FixtureCase -eq 'app-id') { $FixtureTenant } else { $FixtureApp }
        $uri = if ($FixtureCase -eq 'app-uri') { 'api://wrong' } else { "api://$returnedAppId" }
        return (@{ appId = $returnedAppId; identifierUris = @($uri) } | ConvertTo-Json -Compress)
    }
    if ($line -like 'ad app create*') {
        if ($FixtureCase -eq 'app-create-denied') { $global:LASTEXITCODE = 1; return 'ERROR: Insufficient privileges to complete the operation.' }
        if ($FixtureCase -eq 'app-create-empty') { return '{}' }
        return (@{ appId = $FixtureApp } | ConvertTo-Json -Compress)
    }
    if ($line -like 'ad app update*') { return '{}' }
    if ($line -like 'ad sp create*') { return (@{ appId = $FixtureApp } | ConvertTo-Json -Compress) }
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
               scope = $(if ($FixtureCase -eq 'role-child') { "$FixtureRgId/providers/Microsoft.Web/sites/one-site" } elseif ($FixtureCase -eq 'role-management-group') { '/providers/Microsoft.Management/managementGroups/fixture-parent' } else { $FixtureRgId })
               condition = $(if ($FixtureCase -eq 'role-conditional') { 'conditional assignment' } else { $null })
               roleDefinitionName = 'Owner' }
        }
        return (ConvertTo-Json -InputObject @($roles) -Compress)
    }
    if ($line -like 'resource list*') {
        if ($FixtureCase -eq 'owned-names') {
            return (@(
                @{ id = $FixtureCosmosId; type = 'Microsoft.DocumentDB/databaseAccounts'; name = 'cosmos-p84fixture'; location = 'eastus2' }
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
        $global:FixtureBicepExpression = Get-Content -LiteralPath $words[([array]::IndexOf($words, '--file') + 1)] -Raw
        if ($FixtureCase -in @('bicep-evaluation','tool:bicep')) { $global:LASTEXITCODE = 1; return }
        $params = @{ parameters = @{ storageName = @{ value = $(if ($FixtureCase -eq 'bicep-shape') { 'bad_derived_name' } else { 'stres52p2c4jfs43ig' }) } } } | ConvertTo-Json -Compress -Depth 5
        return (@{ parametersJson = $params } | ConvertTo-Json -Compress)
    }
    # Start-ClaudeProjectionRunner reads the state, starts a stopped group and polls until Running.
    if ($line -like 'container show*' -and $line -match '--query instanceView\.state') {
        if ($FixtureCase -eq 'runner-stopped' -and -not $global:FixtureRunnerStarted) { return 'Stopped' }
        return 'Running'
    }
    if ($line -like 'container start*') { $global:FixtureRunnerStarted = $true; return '' }
    if ($line -like 'container exec*') {
        if ($FixtureCase -eq 'runner-exit') { $global:LASTEXITCODE = 9; return 'runner transport failed' }
        $command = [string]$words[[array]::IndexOf($words, '--exec-command') + 1]
        # az.cmd re-quotes its arguments for cmd.exe, so an embedded quote splits the command (measured with
        # the real az.cmd in P95 council round 1: "ERROR: unrecognized arguments").
        if ($command.Contains('"')) { $global:LASTEXITCODE = 2; return "ERROR: unrecognized arguments: $command" }
        # Send-RunnerFile: an empty temp file, base64url chunks appended, then the decoded file's SHA-256.
        if ($command -match "^node -e require\('fs'\)\.mkdirSync\('[^']*',\{recursive:true\}\);require\('fs'\)\.writeFileSync\('([^']+)',''\)$") {
            $global:FixtureRunnerFiles[$Matches[1]] = [Text.StringBuilder]::new(); return ''
        }
        if ($command -match "^node -e require\('fs'\)\.appendFileSync\('([^']+)','([^']*)'\)$") { $null = $global:FixtureRunnerFiles[$Matches[1]].Append($Matches[2]); return '' }
        if ($command -match "^node -e f=require\('fs'\);f\.writeFileSync\('[^']+',Buffer\.from\(f\.readFileSync\('([^']+)','utf8'\),'base64url'\)\)") {
            $b64 = $global:FixtureRunnerFiles[$Matches[1]].ToString().Replace('-', '+').Replace('_', '/')
            $b64 += '=' * ((4 - $b64.Length % 4) % 4)
            return [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Convert]::FromBase64String($b64))).Replace('-', '').ToLower()
        }
        if ($command -match "existsSync\('/work/sync/node_modules'\)") {
            return $(if ($FixtureCase -eq 'node-modules-present') { 'present' } else { 'absent' })
        }
        # apply-projection.mjs --compare prints ok:false with the differences when the projection and the gateway disagree.
        if ($FixtureCase -eq 'compare-differs' -and $command -match 'apply-projection\.mjs .*--compare ') { return '{"ok":false,"mode":"compare","compared":2,"differences":1,"byKind":{"missing":1}}' }
        if ($FixtureCase -eq 'compare-error' -and $command -match 'apply-projection\.mjs .*--compare ') { $global:LASTEXITCODE = 0; return '{"ok":false,"error":"Cosmos read failed: 403 Forbidden"}' }
        if ($FixtureCase -eq 'compare-no-mode' -and $command -match 'apply-projection\.mjs .*--compare ') { return '{"ok":true}' }
        # The summaries the real scripts print last (sync/src/apply-projection.mjs, sync/src/check-admission.mjs).
        if ($command -match 'apply-projection\.mjs .*--compare-snapshot ') { return '{"ok":true,"mode":"compare-snapshot","compared":1,"differences":0,"byKind":{},"sample":[]}' }
        if ($command -match 'apply-projection\.mjs .*--compare ') { return '{"ok":true,"mode":"compare","gateway":"apim-p84","compared":1,"projectionRecords":1,"differences":0,"byKind":{},"sample":[]}' }
        if ($FixtureCase -eq 'apply-excluded' -and $command -match 'apply-projection\.mjs .*--snapshot ') { return '{"ok":true,"written":0,"deleted":0,"unchanged":1,"excludedByNewerTargetedSync":2}' }
        if ($command -match 'check-admission\.mjs ') {
            switch ($FixtureCase) {
                'admission-no-full-sync' { return '{"ok":false,"mode":"switch-evidence","newestFullSync":null,"invalidCount":0,"reason":"no full sync within 24 hours for this account and tenant"}' }
                'admission-user-mode' { return '{"ok":false,"mode":"switch-evidence","newestFullSync":null,"invalidCount":0,"reason":"newest status is mode user; only mode full counts"}' }
                'admission-invalid-records' { return '{"ok":false,"mode":"switch-evidence","newestFullSync":{"finishedAt":"2026-10-05T11:00:00.000Z","executor":"runner","generation":"00000000-0000-4000-8000-000000000099"},"invalidCount":2,"invalidSamples":["aaaaaaaaaaaa","bbbbbbbbbbbb"],"reason":"projection contains records the resolver would refuse"}' }
                'admission-other-scope' { return '{"ok":false,"mode":"switch-evidence","newestFullSync":null,"invalidCount":0,"reason":"no full sync for this account, database, container and tenant"}' }
                'admission-no-json' { return 'switch evidence completed without a summary' }
                'admission-two-json' { return '{"ok":true,"mode":"switch-evidence","newestFullSync":{"finishedAt":"2026-10-05T10:00:00.000Z","executor":"runner"},"invalidCount":0}' + "`n" + '{"ok":true,"mode":"switch-evidence","newestFullSync":{"finishedAt":"2026-10-05T11:00:00.000Z","executor":"runner"},"invalidCount":0}' }
                default { return '{"ok":true,"mode":"switch-evidence","newestFullSync":{"finishedAt":"2026-10-05T11:00:00.000Z","executor":"runner","generation":"00000000-0000-4000-8000-000000000099"},"invalidCount":0}' }
            }
        }
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
        return [pscustomobject]@{ id = $(if ($FixtureCase -eq 'user-empty') { '' } else { $FixtureGroupId }); userType = $(if ($FixtureCase -eq 'guest') { 'Guest' } else { 'Member' }) }
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
        if ($FixtureCase -eq 'group-no-id') { $groups[0].id = '' }
        if ($FixtureCase -eq 'group-null-nextlink') { return [pscustomobject]@{ value=$groups; '@odata.nextLink'=$null } }
        return [pscustomobject]@{ value = $groups }
    }
    if ($url -like 'https://graph.microsoft.com/v1.0/groups/*/transitiveMembers/*') {
        if ($FixtureCase -eq 'member-error') { throw 'Graph 403 membership denied' }
        if ($FixtureCase -eq 'member-shape') { return [pscustomobject]@{} }
        $response = @{ value = @([pscustomobject]@{ id = $FixtureApp; userPrincipalName = 'user@example.invalid'; displayName = 'user' }) }
        if ($FixtureCase -eq 'member-nextlink') { $response['@odata.nextLink'] = 'https://example.invalid/steal-token' }
        if ($FixtureCase -eq 'member-no-id') { $response.value[0].id = '' }
        if ($FixtureCase -eq 'member-repeat') {
            if (@($FixtureCalls | Where-Object { $_ -eq "HTTP Get $url" }).Count -gt 3) { throw 'Fixture stopped an unbounded Graph loop.' }
            $response['@odata.nextLink'] = [string]$Uri
        }
        return [pscustomobject]$response
    }
    if ($url -like 'https://management.azure.com/*/checkNameAvailability?*') {
        if ($FixtureCase -eq 'site-error') { throw 'Site availability lookup failed' }
        if ($FixtureCase -eq 'site-shape') { return [pscustomobject]@{} }
        return [pscustomobject]@{ nameAvailable = ($FixtureCase -notin @('site-taken','owned-names')); reason = 'AlreadyExists' }
    }
    if ($FixtureCase -eq 'foreign-job' -and $url.StartsWith("https://management.azure.com/subscriptions/$FixtureTenant/")) {
        $foreignId = $FixtureJobId.Replace($FixtureSubscription, $FixtureTenant)
        if ($url -like '*/executions?*') {
            $execution = $FixtureExecution | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $execution.id = "$foreignId/executions/recent"
            return [pscustomobject]@{ value=@($execution); nextLink=$null }
        }
        $job = $FixtureJob | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $job.id = $foreignId
        return $job
    }
    if ($url -match '^https://management\.azure\.com/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/actionGroups/[^/?]+\?api-version=') {
        if ($FixtureCase -eq 'action-group-error') { throw 'ARM 404 ResourceNotFound: the action group was not found.' }
        return $FixtureActionGroup
    }
    if ($url -eq "https://management.azure.com${FixtureJobId}?api-version=2024-03-01") {
        if ($FixtureCase -eq 'job-error') { throw 'ARM 403 job read denied' }
        return $FixtureJob
    }
    if ($url -like "https://management.azure.com$FixtureJobId/executions?*") {
        if ($FixtureCase -eq 'execution-error') { throw 'ARM execution read denied' }
        if ($FixtureCase -eq 'execution-shape') { return [pscustomobject]@{ value=$FixtureExecution; nextLink=$null } }
        if ($FixtureCase -eq 'execution-nextlink') { return [pscustomobject]@{ value = @(); nextLink = 'https://example.invalid/steal-token' } }
        if ($FixtureCase -eq 'execution-foreign-path') { return [pscustomobject]@{ value=@(); nextLink=$url.Replace('projection-renewal','foreign-job') } }
        if ($FixtureCase -eq 'execution-repeat') {
            if (@($FixtureCalls | Where-Object { $_ -eq "HTTP Get $url" }).Count -gt 3) { throw 'Fixture stopped an unbounded ARM loop.' }
            return [pscustomobject]@{ value=@(); nextLink=$url }
        }
        if ($FixtureCase -eq 'execution-page' -and $url -notmatch 'skiptoken') {
            return [pscustomobject]@{ value = @(); nextLink = "https://management.azure.com$FixtureJobId/executions?api-version=2024-03-01&skiptoken=second" }
        }
        return [pscustomobject]@{ value = $FixtureExecutions; nextLink = $null }
    }
    throw "UNEXPECTED HTTP CALL (offline fixture): $Method $url"
}
