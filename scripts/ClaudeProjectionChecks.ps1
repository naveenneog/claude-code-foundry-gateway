# ADR-0040. Importing these checks performs no Azure operations.
. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')

function Assert-ClaudeProjectionPowerShell {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Projection deployment and sync require PowerShell 7 or later; run in pwsh.' }
}

function Get-ClaudeProjectionAppRemedy {
    param([string]$NamePrefix)
    return "Customer Entra admin: https://entra.microsoft.com > Entra ID > App registrations > New registration > claude-projection-resolver-$NamePrefix > Accounts in this organizational directory only > Register; Overview supplies the Application (client) ID; Expose an API > Application ID URI is api://<id>. CLI equivalent: az ad app create --display-name claude-projection-resolver-$NamePrefix --sign-in-audience AzureADMyOrg --query appId -o tsv; after a successful nonempty id, az ad app update --id <id> --identifier-uris api://<id>. The operator supplies -ResolverAppId <id>."
}

function New-ClaudeProjectionResolverApp {
    param([string]$NamePrefix)
    try {
        $made = Invoke-ClaudeNetworkAz @('ad','app','create','--display-name',"claude-projection-resolver-$NamePrefix",'--sign-in-audience','AzureADMyOrg')
    } catch {
        throw "Resolver app creation failed: $($_.Exception.Message) Insufficient privileges requires a customer Entra admin, not Azure subscription Owner. $(Get-ClaudeProjectionAppRemedy $NamePrefix)"
    }
    if (-not $made -or [string]$made.appId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw "Resolver app creation returned no valid application id; no update was attempted. $(Get-ClaudeProjectionAppRemedy $NamePrefix)"
    }
    $null = Invoke-ClaudeNetworkAz @('ad','app','update','--id',[string]$made.appId,'--identifier-uris',"api://$($made.appId)")
    return [string]$made.appId
}

function Get-ClaudeProjectionStorageName {
    param([string]$ResourceGroupId, [string]$NamePrefix)
    $file = Join-Path ([IO.Path]::GetTempPath()) ("projection-name-" + [guid]::NewGuid().ToString('N') + '.bicepparam')
    try {
        $expression = "using none`nparam storageName = take('stres`${uniqueString('$ResourceGroupId', '$NamePrefix')}', 24)`n"
        [IO.File]::WriteAllText($file, $expression, [Text.UTF8Encoding]::new($false))
        $built = Invoke-ClaudeNetworkAz @('bicep','build-params','--file',$file,'--stdout')
        $parameters = $built.parametersJson | ConvertFrom-Json -ErrorAction Stop
        $name = [string]$parameters.parameters.storageName.value
        if ($name -notmatch '^stres[a-z0-9]{13}$') { throw 'Bicep returned no valid derived storage account name.' }
        return $name
    } finally { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -WhatIf:$false } }
}

function Invoke-ClaudeProjectionPreflight {
    param(
        [string]$ResourceGroup, [string]$ApimName, [string]$NamePrefix, [string]$SubscriptionId,
        [string]$Location, [string]$Sku = 'BasicV2', [string]$ResolverInboundAccess,
        [string]$ResolverAppId, [string]$StandardGroup = 'claude-code-standard',
        [string]$PremiumGroup = 'claude-code-premium', [switch]$FlipAfterCleanCompare,
        [string]$ReconcilerResourceId
    )
    Write-Host 'Projection preflight (about 30-90 s, including 25 s between Graph probes). No Azure writes.'
    $checks = [Collections.Generic.List[object]]::new()
    $context = @{ Location = $Location; ResolverAppId = $ResolverAppId }
    function Check($Name, $Who, $Remedy, [scriptblock]$Read) {
        try {
            $evidence = & $Read
            $checks.Add([pscustomobject]@{ Check=$Name; Result='PASS'; Evidence=($evidence -join '; '); Remedy='None'; Who=$Who })
        } catch {
            $checks.Add([pscustomobject]@{ Check=$Name; Result='FAIL'; Evidence=$_.Exception.Message; Remedy=$Remedy; Who=$Who })
        }
    }
    function Report {
        $checks | Format-Table @{Label='Check';Expression={$_.Check};Width=24}, @{Label='Result';Expression={$_.Result};Width=6},
            @{Label='Evidence';Expression={$_.Evidence};Width=74}, @{Label='Remedy';Expression={$_.Remedy};Width=96},
            @{Label='Who';Expression={$_.Who};Width=21} -Wrap | Out-String -Width 240 | Write-Host
        $failed = @($checks | Where-Object Result -eq 'FAIL')
        if ($failed.Count) { throw "Projection preflight failed ($($failed.Count)): $(($failed | ForEach-Object { "$($_.Check): $($_.Evidence)" }) -join '; ')" }
    }
    Check 'PowerShell' 'operator' 'run in pwsh (PowerShell 7 or later)' {
        Assert-ClaudeProjectionPowerShell
        "PowerShell $($PSVersionTable.PSVersion)"
    }
    Check 'Input names' 'operator' 'NamePrefix is 1-37 lowercase letters/digits with separated hyphens, starting/ending alphanumeric; ids are GUIDs.' {
        if ($NamePrefix.Length -gt 37 -or $NamePrefix -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'NamePrefix is invalid for the derived Cosmos, Function, storage, network, telemetry or runner names.' }
        if ($ResourceGroup -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,89}$' -or $ApimName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,49}$') { throw 'Resource group or gateway name is unsafe for the Azure CLI.' }
        foreach ($id in @($SubscriptionId,$ResolverAppId)) {
            if ($id -and $id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'SubscriptionId and ResolverAppId must be GUIDs when supplied.' }
        }
        'All prefix-derived names fit the template naming-rule intersection; Cosmos is the 44-character bound.'
    }
    foreach ($tool in @('az','node','npm','tar')) {
        Check "Tool: $tool" 'operator' "The local $tool executable is required; Bicep is checked by offline name evaluation." {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing local tool: $tool" }
            "$tool found"
        }
    }
    if (@($checks | Where-Object Result -eq 'FAIL').Count) { Report }
    Check 'Azure sign-in' 'operator' 'az login; az account set --subscription <gateway-subscription-id>' {
        $context.Account = Invoke-ClaudeNetworkAz @('account','show')
        if (-not $context.Account -or -not $context.Account.id -or $context.Account.state -ne 'Enabled') { throw 'Azure CLI is not signed in to an enabled subscription.' }
        if ($SubscriptionId -and $SubscriptionId -ne $context.Account.id) { throw 'The selected subscription does not match the requested gateway subscription.' }
        $context.SubscriptionId = [string]$context.Account.id
        $context.Account.id
    }
    Check 'Gateway subscription' 'operator' 'The gateway name/resource group and selected subscription identify the same gateway; its system-assigned identity is enabled.' {
        if (-not $context.SubscriptionId) { throw 'The gateway subscription is unverified because account discovery failed.' }
        $context.ResourceGroupId = "/subscriptions/$($context.SubscriptionId)/resourceGroups/$ResourceGroup"
        $context.GatewayResourceId = "$($context.ResourceGroupId)/providers/Microsoft.ApiManagement/service/$ApimName"
        $context.AccountResourceId = "$($context.ResourceGroupId)/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-$NamePrefix"
        $context.Apim = Invoke-ClaudeNetworkAz @('apim','show','-g',$ResourceGroup,'-n',$ApimName,'--subscription',$context.SubscriptionId)
        if ($context.Apim.id -ne $context.GatewayResourceId) { throw 'The returned gateway subscription/resource id does not match the selected target.' }
        if (-not $context.Apim.identity.principalId -or $context.Apim.identity.tenantId -ne $context.Account.tenantId) { throw 'Gateway managed identity or tenant is missing/mismatched.' }
        if ($context.Apim.sku.name -ne $Sku) { throw "Requested SKU $Sku does not match gateway tier $($context.Apim.sku.name)." }
        if ($Sku -eq 'BasicV2' -and $ResolverInboundAccess -eq 'private') { throw 'BasicV2 requires ResolverInboundAccess public.' }
        $sp = Invoke-ClaudeNetworkAz @('ad','sp','show','--id',[string]$context.Apim.identity.principalId)
        if (-not $sp.appId) { throw 'Gateway managed identity application id could not be read.' }
        $context.GatewayAppId = [string]$sp.appId
        $rg = Invoke-ClaudeNetworkAz @('group','show','-n',$ResourceGroup,'--subscription',$context.SubscriptionId)
        if ($rg.id -ne $context.ResourceGroupId) { throw 'Resource group id does not match the gateway subscription.' }
        if (-not $context.Location) { $context.Location = [string]$rg.location }
        $context.GatewayResourceId
    }
    foreach ($probe in 1..2) {
        if ($probe -eq 2) { Start-Sleep -Seconds 25 }
        Check "Graph probe $probe" 'network team' (Get-ClaudeGraphFailureRemedy 'LocationConditionEvaluationSatisfied') {
            $context.GraphToken = Get-GraphToken
            $context.User = Invoke-ClaudeGraphRead -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userType' -Token $context.GraphToken
            if (-not $context.User.id) { throw 'Graph did not return the signed-in user id.' }
            "Graph reached at $([DateTimeOffset]::UtcNow.ToString('o'))"
        }
    }
    foreach ($groupName in @($StandardGroup,$PremiumGroup)) {
        Check "Tier group: $groupName" 'customer Entra admin' 'An existing, unambiguous tier group and Graph group read permission are required.' {
            if (-not $context.GraphToken) { throw 'Graph token could not be acquired; group lookup is unverified.' }
            $group = Get-ClaudeGraphGroup -GroupName $groupName -Token $context.GraphToken
            if (-not $group) { throw "Required tier group '$groupName' was confirmed absent." }
            "$groupName = $($group.id)"
        }
    }
    Check 'Resolver registration' 'customer Entra admin' (Get-ClaudeProjectionAppRemedy $NamePrefix) {
        $app = $null
        if ($ResolverAppId) {
            $app = Invoke-ClaudeNetworkAz @('ad','app','show','--id',$ResolverAppId)
            if (-not $app -or $app.appId -ne $ResolverAppId) { throw 'The supplied resolver app could not be verified.' }
        } else {
            $apps = @(Invoke-ClaudeNetworkAz @('ad','app','list','--display-name',"claude-projection-resolver-$NamePrefix"))
            if ($apps.Count -gt 1) { throw 'Resolver registration display name is ambiguous; ResolverAppId is required.' }
            if ($apps.Count -eq 1) { $app = $apps[0] }
        }
        if ($app) {
            if (-not $app.appId -or @($app.identifierUris) -notcontains "api://$($app.appId)") { throw 'The resolver app must have identifier URI api://<id>.' }
            $context.ResolverAppId = [string]$app.appId
            "Existing resolver app: $($app.appId)"
        } else {
            if (-not $context.User -or $context.User.userType -ne 'Member') { throw 'App creation permission is unproven: a member user or pre-created ResolverAppId is required.' }
            $policy = Invoke-ClaudeGraphRead -Uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' -Token $context.GraphToken
            $allowed = $policy.defaultUserRolePermissions.allowedToCreateApps
            if ($allowed -isnot [bool] -or -not $allowed) { throw 'App creation permission is unproven: allowedToCreateApps is not explicitly true. Role-delegated operators can supply an admin-created ResolverAppId.' }
            'Member user; authorizationPolicy.allowedToCreateApps=true'
        }
    }
    Check 'Resource providers' 'operator' 'Subscription admin registration: az provider register --namespace <provider>; registration commonly takes several minutes.' {
        if (-not $context.SubscriptionId) { throw 'Provider reads require the verified subscription.' }
        $providers = @(Invoke-ClaudeNetworkAz @('provider','list','--subscription',$context.SubscriptionId))
        $required = @('Microsoft.App','Microsoft.DocumentDB','Microsoft.Web','Microsoft.ContainerInstance','Microsoft.Network','Microsoft.Storage','Microsoft.OperationalInsights','Microsoft.Insights','Microsoft.Authorization')
        $missing = @($required | Where-Object { $name = $_; -not @($providers | Where-Object { $_.namespace -eq $name -and $_.registrationState -eq 'Registered' }).Count })
        if ($missing.Count) { throw "Unregistered or unreadable provider(s): $($missing -join ', ')" }
        $required -join ', '
    }
    Check 'Resource-group RBAC' 'operator' 'An Azure access administrator grants/activates Owner, or Contributor plus User Access Administrator, on this resource group. Conditional/custom assignments are not sufficient evidence.' {
        if (-not $context.User.id -or -not $context.ResourceGroupId) { throw 'Role evidence requires verified user and resource group ids.' }
        $roles = @(Invoke-ClaudeNetworkAz @('role','assignment','list','--assignee',[string]$context.User.id,'--scope',$context.ResourceGroupId,'--include-groups','--include-inherited','--fill-principal-name','false','--fill-role-definition-name','false','--subscription',$context.SubscriptionId))
        $ids = @($roles | Where-Object { -not $_.condition -and ($_.scope -eq $context.ResourceGroupId -or $_.scope -eq "/subscriptions/$($context.SubscriptionId)") } | ForEach-Object { ([string]$_.roleDefinitionId -split '/')[-1] })
        $owner = $ids -contains '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        $contributorAndUaa = $ids -contains 'b24988ac-6180-42a0-ab88-20f7382dd24c' -and $ids -contains '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
        if (-not ($owner -or $contributorAndUaa)) { throw 'Owner, or Contributor plus User Access Administrator, was not proven at resource-group scope (including inherited/group roles).' }
        'Required unconditional built-in role assignment(s) found; deny assignments and Azure Policy can still reject deployment.'
    }
    Check 'Names and Bicep' 'operator' 'A valid, globally available prefix and local Azure CLI Bicep with build-params/using none support are required. Existing exact target resources can be reused.' {
        if (-not $context.ResourceGroupId) { throw 'Name availability requires the verified resource group.' }
        $storageName = Get-ClaudeProjectionStorageName -ResourceGroupId $context.ResourceGroupId -NamePrefix $NamePrefix
        $resources = @(Invoke-ClaudeNetworkAz @('resource','list','-g',$ResourceGroup,'--subscription',$context.SubscriptionId))
        $cosmosTaken = Invoke-ClaudeNetworkAz @('cosmosdb','check-name-exists','-n',"cosmos-$NamePrefix",'--subscription',$context.SubscriptionId)
        if ($cosmosTaken -isnot [bool] -or ($cosmosTaken -and -not @($resources | Where-Object id -eq $context.AccountResourceId).Count)) { throw "Cosmos name cosmos-$NamePrefix is unavailable or its availability is unproven." }
        $storage = Invoke-ClaudeNetworkAz @('storage','account','check-name','--name',$storageName,'--subscription',$context.SubscriptionId)
        $storageId = "$($context.ResourceGroupId)/providers/Microsoft.Storage/storageAccounts/$storageName"
        if ($storage.nameAvailable -isnot [bool] -or (-not $storage.nameAvailable -and -not @($resources | Where-Object id -eq $storageId).Count)) { throw "Storage name $storageName is unavailable or its availability is unproven." }
        $state = Join-Path ([IO.Path]::GetTempPath()) ('projection-availability-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($state)
        try {
            $site = Invoke-ClaudeNetworkArm -Url "https://management.azure.com/subscriptions/$($context.SubscriptionId)/providers/Microsoft.Web/checkNameAvailability?api-version=2024-04-01" -Method post -Body @{ name="func-resolver-$NamePrefix"; type='Microsoft.Web/sites' } -StateDirectory $state
        } finally { Remove-Item -LiteralPath $state -Recurse -Force -WhatIf:$false }
        $siteId = "$($context.ResourceGroupId)/providers/Microsoft.Web/sites/func-resolver-$NamePrefix"
        if ($site.nameAvailable -isnot [bool] -or (-not $site.nameAvailable -and -not @($resources | Where-Object id -eq $siteId).Count)) { throw "Function site func-resolver-$NamePrefix is unavailable or its availability is unproven." }
        "Cosmos cosmos-$NamePrefix, Function func-resolver-$NamePrefix, storage $storageName available or owned by this resource group; Bicep evaluated storage offline."
    }
    $checks.Add([pscustomobject]@{
        Check='Cosmos regional capacity'; Result='NOTE'; Evidence='Capacity cannot be checked in advance. Canada Central and Canada East refused account creation in the recorded tests (docs/SECURE-PROJECTION.md prerequisites).'
        Remedy='A failed allocation may require regional access at https://aka.ms/cosmosdbquota or another region; successful preflight is not capacity reservation.'
        Who='operator'
    })
    if ($FlipAfterCleanCompare) {
        Check 'Reconciliation switch' 'operator' 'ReconcilerResourceId identifies an existing verified scheduled projection job (ADR-0040). No override exists; P86 owns provisioning.' {
            $evidence = Assert-ClaudeProjectionReconciler -ReconcilerResourceId $ReconcilerResourceId -GatewayResourceId $context.GatewayResourceId -AccountResourceId $context.AccountResourceId -TenantId $context.Account.tenantId
            "Verified $($evidence.ResourceId), execution $($evidence.Execution); scan-start expiry estimate $($evidence.ExpiresAt)."
        }
    }
    Report
    $context.Remove('GraphToken')
    return $context
}

function Get-ClaudeProjectionContainerSignature {
    param($Template)
    $containers = @($Template.containers)
    if ($containers.Count -ne 1) { throw 'The reconciler contract requires exactly one container.' }
    if ($Template.PSObject.Properties['initContainers'] -and @($Template.initContainers).Count) { throw 'The reconciler contract does not permit init containers.' }
    $container = $containers[0]
    if ([string]$container.image -notmatch '@sha256:[0-9a-f]{64}$') { throw 'The reconciler image requires a SHA-256 digest, not a mutable tag.' }
    $environment = @{}
    foreach ($variable in @($container.env)) {
        $secret = $variable.PSObject.Properties['secretRef']
        if (-not $variable.name -or $environment.ContainsKey([string]$variable.name) -or ($secret -and $secret.Value)) { throw 'Reconciler environment binding must contain unique literal non-secret values.' }
        $environment[[string]$variable.name] = [string]$variable.value
    }
    $canonical = [ordered]@{ name=$container.name; image=$container.image; command=@($container.command); args=@($container.args); env=@($environment.Keys | Sort-Object | ForEach-Object { "$_=$($environment[$_])" }) }
    @{ Environment=$environment; Signature=($canonical | ConvertTo-Json -Depth 20 -Compress) }
}

function Assert-ClaudeProjectionReconciler {
    param([string]$ReconcilerResourceId, [string]$GatewayResourceId, [string]$AccountResourceId, [string]$TenantId, [long]$ExpiresAt = 0)
    $now = [DateTimeOffset]::UtcNow
    $estimated = -not $PSBoundParameters.ContainsKey('ExpiresAt')
    if ($estimated) { $ExpiresAt = $now.ToUnixTimeSeconds() + 7200 }
    $expiry = [DateTimeOffset]::FromUnixTimeSeconds($ExpiresAt).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $lease = "Records expire at most 2 hours after the scan, at $expiry$(if ($estimated) { ' (estimate for a scan starting now)' }); every developer gets 503 after that without successful reconciliation."
    try {
        if (-not $estimated -and $ExpiresAt -le 0) { throw 'The actual snapshot has no valid expiry; no new lease is assumed.' }
        if (-not $ReconcilerResourceId) { throw 'ReconcilerResourceId is required; no scheduled reconciliation has been verified.' }
        $pattern = '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/[A-Za-z0-9._-]+/providers/Microsoft.App/jobs/[A-Za-z0-9-]+$'
        if ($ReconcilerResourceId -notmatch $pattern) { throw 'ReconcilerResourceId must identify a Microsoft.App/jobs ARM resource.' }
        $subscription = $Matches[1]
        if ($GatewayResourceId -notlike "/subscriptions/$subscription/*" -or $AccountResourceId -notlike "/subscriptions/$subscription/*") { throw 'Reconciler, gateway and Cosmos account must share the verified subscription.' }
        $base = "https://management.azure.com$ReconcilerResourceId"
        $job = Invoke-ClaudeNetworkArm -Url "${base}?api-version=2024-03-01"
        if ($job.id -ne $ReconcilerResourceId -or $job.type -ne 'Microsoft.App/jobs') { throw 'ARM returned a different job resource id/type.' }
        if ($job.properties.provisioningState -ne 'Succeeded') { throw 'Reconciler provisioning has not succeeded.' }
        $configuration = $job.properties.configuration
        if ($configuration.triggerType -ne 'Schedule') { throw 'Reconciler trigger must be Schedule.' }
        $cron = [string]$configuration.scheduleTriggerConfig.cronExpression
        if ($cron -notmatch '^(?:\*|\*/(?:[1-9]|[1-5][0-9])|(?:[0-5]?[0-9])(?:,[0-5]?[0-9])*) \* \* \* \*$') { throw 'Reconciler cron must be a supported UTC hourly-or-faster schedule (for example 0 * * * *).' }
        $timeout = $configuration.replicaTimeout
        if (($timeout -isnot [int] -and $timeout -isnot [long]) -or $timeout -lt 1 -or $timeout -gt 3600) { throw 'Reconciler replica timeout must be 1-3600 seconds, within the two-hour lease.' }
        if ($ExpiresAt - $now.ToUnixTimeSeconds() -le (3600 + $timeout)) { throw 'The snapshot lease has insufficient remaining runway for an hourly execution plus its timeout.' }
        $definition = Get-ClaudeProjectionContainerSignature $job.properties.template
        $expected = @{
            CLAUDE_PROJECTION_CONTRACT='1'; PROJECTION_GATEWAY_RESOURCE_ID=$GatewayResourceId
            PROJECTION_ACCOUNT_RESOURCE_ID=$AccountResourceId; PROJECTION_TENANT_ID=$TenantId
            PROJECTION_DATABASE='claude'; PROJECTION_CONTAINER='entitlement'; PROJECTION_MAX_AGE_SECONDS='7200'
        }
        foreach ($key in $expected.Keys) {
            if (-not $definition.Environment.ContainsKey($key) -or $definition.Environment[$key] -cne $expected[$key]) { throw "Reconciler environment binding $key does not match the projection contract." }
        }
        $executions = [Collections.Generic.List[object]]::new()
        $next = "$base/executions?api-version=2024-03-01"; $seen = @{}
        do {
            if ($next -notlike "$base/executions?*" -or $seen.ContainsKey($next) -or $seen.Count -ge 20) { throw 'ARM execution nextLink is foreign, repeated or exceeds 20 pages; evidence is incomplete.' }
            $seen[$next] = $true
            $page = Invoke-ClaudeNetworkArm -Url $next
            if (-not $page -or -not $page.PSObject.Properties['value'] -or $page.value -isnot [array]) { throw 'ARM returned an invalid execution collection.' }
            foreach ($execution in $page.value) {
                $executionId = $execution.PSObject.Properties['id']
                if ([string]$execution.name -notmatch '^[A-Za-z0-9._-]+$' -or
                    ($executionId -and $executionId.Value -ne "$ReconcilerResourceId/executions/$($execution.name)")) { throw 'ARM returned an invalid execution name or an execution for a different job.' }
                $start = [DateTimeOffset]::MinValue; $end = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string]$execution.properties.startTime, [ref]$start) -or $start -gt $now) { throw 'Execution start time is malformed or future-dated.' }
                if ($execution.properties.status -eq 'Running') { continue }
                if (-not [DateTimeOffset]::TryParse([string]$execution.properties.endTime, [ref]$end) -or $end -lt $start -or $end -gt $now) { throw 'Execution end time is malformed, inverted or future-dated.' }
                $executions.Add(@{ Item=$execution; Start=$start; End=$end })
            }
            $link = $page.PSObject.Properties['nextLink']
            $next = if ($link) { [string]$link.Value } else { '' }
        } while ($next)
        $latest = $executions | Sort-Object Start -Descending | Select-Object -First 1
        if (-not $latest -or $latest.Item.properties.status -ne 'Succeeded') { throw 'No latest succeeded execution: reconciliation is missing or its latest completed execution failed.' }
        if (($now - $latest.Start).TotalSeconds -ge 7200) { throw 'Succeeded execution is outside the fresh scan-start lease window.' }
        $ran = Get-ClaudeProjectionContainerSignature $latest.Item.properties.template
        if ($ran.Signature -cne $definition.Signature) { throw 'Succeeded execution used a different container template from the current reconciler.' }
        Write-Host "Verified reconciler $ReconcilerResourceId; execution $($latest.Item.name); cron $cron. $lease"
        return @{ ResourceId=$ReconcilerResourceId; Execution=[string]$latest.Item.name; ExpiresAt=$expiry }
    } catch { throw "Refusing projection switch: $($_.Exception.Message) $lease" }
}
