# ADR-0040. Importing these checks performs no Azure operations.
. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')

function Assert-ClaudeProjectionPowerShell {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Projection deployment and sync require PowerShell 7 or later; run in pwsh.' }
}

function Get-ClaudeProjectionAppRemedy {
    param([string]$NamePrefix)
    return "Customer Entra admin: https://entra.microsoft.com > Entra ID > App registrations > New registration > claude-projection-resolver-$NamePrefix > Accounts in this organizational directory only > Register; Overview supplies the Application (client) ID; Expose an API > Application ID URI is api://<id>. CLI equivalent: az ad app create --display-name claude-projection-resolver-$NamePrefix --sign-in-audience AzureADMyOrg --query appId -o tsv; after a successful nonempty id, az ad app update --id <id> --identifier-uris api://<id>. The operator supplies -ResolverAppId <id>."
}

# Read-only: does the resolver application have a service principal in this tenant? Entra issues no token
# for a resource application without one (AADSTS500011).
function Test-ClaudeProjectionResolverServicePrincipal {
    param([Parameter(Mandatory)][string]$AppId)
    if ($AppId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'Resolver application id must be a GUID before its service principal is read.'
    }
    try {
        $sp = Invoke-ClaudeNetworkAz @('ad','sp','show','--id',$AppId)
        return [bool]($sp -and $sp.appId)
    }
    catch {
        if ($_.Exception.Message -match '(?i)not\s*found|Request_ResourceNotFound|does not exist') { return $false }
        throw
    }
}

# The switch checks and never writes: a missing service principal refuses with the remedy.
function Assert-ClaudeProjectionResolverServicePrincipal {
    param([Parameter(Mandatory)][string]$AppId)
    if (-not (Test-ClaudeProjectionResolverServicePrincipal -AppId $AppId)) {
        throw "Projection switch refused: resolver application $AppId has no service principal in this tenant, so Microsoft Entra ID issues the gateway no token for the resolver (AADSTS500011). Remedy: rerun scripts/Deploy-ClaudeProjection.ps1 with this -NamePrefix, which creates it, or run az ad sp create --id $AppId; then rerun the switch."
    }
    return $AppId
}

# The deployer creates the service principal when it is missing.
function Confirm-ClaudeProjectionResolverServicePrincipal {
    param([Parameter(Mandatory)][string]$AppId)
    if (Test-ClaudeProjectionResolverServicePrincipal -AppId $AppId) { return $AppId }
    $null = Invoke-ClaudeNetworkAz @('ad','sp','create','--id',$AppId)
    return $AppId
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
    $null = Confirm-ClaudeProjectionResolverServicePrincipal -AppId ([string]$made.appId)
    return [string]$made.appId
}

function ConvertTo-ClaudeProjectionLocationKey {
    param([AllowEmptyString()][string]$Location)
    return (($Location -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
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

function Format-ClaudeProjectionChecks {
    param([object[]]$Checks, [int]$Width = 100)
    if ($Width -lt 40) { $Width = 100 }
    if ($Width -ge 225) {
        return ($Checks | Format-Table @{Label='Check';Expression={$_.Check};Width=24}, @{Label='Result';Expression={$_.Result};Width=6},
            @{Label='Evidence';Expression={$_.Evidence};Width=74}, @{Label='Remedy';Expression={$_.Remedy};Width=96},
            @{Label='Who';Expression={$_.Who};Width=21} -Wrap | Out-String -Width $Width).TrimEnd()
    }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($check in $Checks) {
        foreach ($field in 'Check','Result','Evidence','Remedy','Who') {
            $text = "${field}: $($check.$field)" -replace '\s+', ' '
            while ($text.Length -gt $Width) {
                $cut = $text.LastIndexOf(' ', $Width)
                if ($cut -lt 1) { $cut = $Width }
                $lines.Add($text.Substring(0, $cut).TrimEnd())
                $text = $text.Substring($cut).TrimStart()
            }
            $lines.Add($text)
        }
        $lines.Add('')
    }
    return ($lines -join "`n").TrimEnd()
}

function Get-ClaudeProjectionArmUrl {
    # The management token goes with this request: the id must be an ARM resource id whose URL stays on
    # management.azure.com. A sub-path, such as config/appsettings/list, is letters in segments under
    # that resource.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ResourceId, [Parameter(Mandatory)][string]$ApiVersion,
        [ValidatePattern('^[A-Za-z]+(/[A-Za-z]+)*$')][string]$SubPath)
    if ($ResourceId -notmatch '^/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/resourceGroups/[A-Za-z0-9._-]{1,90}/providers/[A-Za-z0-9.]{1,64}(/[A-Za-z0-9._-]{1,260}){2}$') {
        throw "Projection switch refused: '$ResourceId' is not an Azure resource id, so the management token is not sent for it. Remedy: redeploy the projection and rerun."
    }
    $path = if ($SubPath) { "$ResourceId/$SubPath" } else { $ResourceId }
    $url = "https://management.azure.com${path}?api-version=$ApiVersion"
    $uri = [uri]$url
    if ($uri.Host -ne 'management.azure.com' -or $uri.UserInfo -or $uri.AbsolutePath -ne $path) {
        throw "Projection switch refused: '$path' does not stay on management.azure.com, so the management token is not sent for it."
    }
    return $url
}

function ConvertFrom-ClaudeProjectionAdmissionResult {
    param([Parameter(Mandatory)][string]$RawOutput)
    $jsonLines = @($RawOutput -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $jsonLines = @($jsonLines | Where-Object { $_.StartsWith('{') -and $_.EndsWith('}') })
    if ($jsonLines.Count -ne 1) { throw "Projection admission returned $($jsonLines.Count) JSON lines, not exactly one. Remedy: rerun the fixed repository checker through the runner." }
    try { $obj = $jsonLines[0] | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Projection admission returned malformed JSON. Remedy: rerun the fixed repository checker through the runner.' }
    if (-not ($obj.ok -eq $true -and [string]$obj.mode -eq 'switch-evidence')) {
        $reason = if ($obj.reason) { [string]$obj.reason } elseif ($obj.error) { [string]$obj.error } else { 'switch evidence was not accepted' }
        if (-not $obj.newestFullSync -and $reason -notmatch 'full sync') { $reason = "no full sync within 24 hours; $reason" }
        if ($obj.invalidCount -gt 0) {
            $samples = @($obj.invalidSamples | Select-Object -First 3)
            $suffix = if ($samples.Count) { " Samples: $($samples -join ', ')." } else { '' }
            $reason = "$reason Invalid projection records: $($obj.invalidCount).$suffix"
        }
        throw "Projection switch refused: $reason Remedy: run scripts/Sync-ClaudeAccess.ps1 for the projection (or a full projection sync), fix invalid projection records, then rerun."
    }
    return $obj
}

function Assert-ClaudeProjectionAdmission {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$RunnerName,
        [Parameter(Mandatory)][string]$CosmosAccount,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$AccountResourceId,
        [ValidateRange(60,604800)][int]$MaxEvidenceAgeSeconds = 86400
    )
    Write-Host '    Checking switch evidence from Cosmos through the in-VNet runner.' -ForegroundColor DarkGray
    $command = "node /work/sync/src/check-admission.mjs --cosmos https://$CosmosAccount.documents.azure.com:443/ --tenant $TenantId --account-resource-id $AccountResourceId --max-evidence-age-seconds $MaxEvidenceAgeSeconds"
    $raw = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $RunnerName -Command $command
    return (ConvertFrom-ClaudeProjectionAdmissionResult -RawOutput $raw)
}

function Assert-ClaudeProjectionResolverRedeploy {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix, [Parameter(Mandatory)][string]$SubscriptionId,
        [AllowEmptyString()][string]$ResolverAppId)
    if ((Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-source' -FailOnError) -ne 'projection') { return }
    $gatewayUrl = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-url' -FailOnError
    $gatewayAudience = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-resolver-audience' -FailOnError
    $siteName = "func-resolver-$NamePrefix"
    $siteUrl = ''
    try {
        $siteArmUrl = Get-ClaudeProjectionArmUrl -ResourceId "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$siteName" -ApiVersion '2024-04-01'
        $siteHost = [string](Invoke-ClaudeNetworkAz @('rest', '--method', 'get', '--url', $siteArmUrl)).properties.defaultHostName
        if ($siteHost) { $siteUrl = "https://$siteHost/api" }
    } catch { }
    if ($ResolverAppId -and "api://$ResolverAppId" -eq $gatewayAudience -and $siteUrl -and $siteUrl -eq $gatewayUrl) { return }
    $appInAudience = $gatewayAudience -replace '^api://', ''
    throw "Refusing to redeploy the resolver for -NamePrefix ${NamePrefix}: entitlement-source is projection, so every request goes to $gatewayUrl with a token for $gatewayAudience. Remedy: rerun scripts/Deploy-ClaudeProjection.ps1 with the -NamePrefix of the resolver at $gatewayUrl and -ResolverAppId $appInAudience, or return the gateway to named values first (refresh the lists with scripts/Sync-ClaudeAccess.ps1 -Store named-value, check them with scripts/Compare-ClaudeEntitlement.ps1 -FailOnDrift, then set entitlement-source to named-value)."
}

function Invoke-ClaudeProjectionPreflight {
    param(
        [string]$ResourceGroup, [string]$ApimName, [string]$NamePrefix, [string]$SubscriptionId,
        [string]$Location, [string]$Sku = 'BasicV2', [string]$ResolverInboundAccess,
        [string]$ResolverAppId, [string]$StandardGroup = 'claude-code-standard',
        [string]$PremiumGroup = 'claude-code-premium'
    )
    Write-Host 'Projection preflight (about 30-90 s, including a 25 s Graph pause). No Azure writes.'
    $checks = [Collections.Generic.List[object]]::new()
    $context = @{ Location = $Location; ResolverAppId = $ResolverAppId }
    function Check($Name, $Who, $Remedy, [scriptblock]$Read) {
        try {
            $evidence = & $Read
            $warning = $evidence -is [hashtable] -and $evidence.Result -eq 'WARN'
            $checks.Add([pscustomobject]@{ Check=$Name; Result=$(if ($warning) { 'WARN' } else { 'PASS' }); Evidence=$(if ($warning) { $evidence.Evidence } else { $evidence -join '; ' }); Remedy=$(if ($warning) { $Remedy } else { 'None' }); Who=$Who })
        } catch {
            $checks.Add([pscustomobject]@{ Check=$Name; Result='FAIL'; Evidence=$_.Exception.Message; Remedy=$Remedy; Who=$Who })
        }
    }
    function Report {
        Format-ClaudeProjectionChecks -Checks $checks.ToArray() -Width $Host.UI.RawUI.WindowSize.Width | Write-Host
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
        $context.ResourceGroupId = [string]$rg.id
        $context.GatewayResourceId = [string]$context.Apim.id
        $context.AccountResourceId = "$($context.ResourceGroupId)/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-$NamePrefix"
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
    foreach ($tier in @(@{Name=$StandardGroup;Optional=$false},@{Name=$PremiumGroup;Optional=$true})) {
        $groupName = $tier.Name
        Check "Tier group: $groupName" 'customer Entra admin' 'Graph group read permission is required. Standard must exist; premium may be confirmed absent.' {
            if (-not $context.GraphToken) { throw 'Graph token could not be acquired; group lookup is unverified.' }
            $group = Get-ClaudeGraphGroup -GroupName $groupName -Token $context.GraphToken
            if (-not $group -and -not $tier.Optional) { throw "Required tier group '$groupName' was confirmed absent." }
            if ($group) { "$groupName = $($group.id)" } else { "Optional premium group '$groupName' confirmed absent; no premium identities." }
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
            $unconfirmed = "cannot confirm; if creation fails, the customer's admin creates the app and you pass -ResolverAppId."
            if (-not $context.User -or $context.User.userType -ne 'Member') {
                return @{ Result='WARN'; Evidence="App-registration rights $unconfirmed Effective guest/delegated rights were not enumerated." }
            }
            try { $policy = Invoke-ClaudeGraphRead -Uri 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' -Token $context.GraphToken }
            catch { return @{ Result='WARN'; Evidence="App-registration rights $unconfirmed Policy.Read.All-class read unavailable: $($_.Exception.Message)" } }
            $allowed = $policy.defaultUserRolePermissions.allowedToCreateApps
            if ($allowed -is [bool] -and $allowed) { 'Member user; authorizationPolicy.allowedToCreateApps=true' }
            else { @{ Result='WARN'; Evidence="App-registration rights $unconfirmed allowedToCreateApps does not establish effective delegated/custom-role permission." } }
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
        # The scoped --include-inherited query supplies management-group ancestors too.
        $ids = @($roles | Where-Object {
            -not $_.condition -and ($_.scope -eq $context.ResourceGroupId -or
                $_.scope -eq "/subscriptions/$($context.SubscriptionId)" -or
                $_.scope -like '/providers/Microsoft.Management/managementGroups/*')
        } | ForEach-Object { ([string]$_.roleDefinitionId -split '/')[-1] })
        $owner = $ids -contains '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        $contributorAndUaa = $ids -contains 'b24988ac-6180-42a0-ab88-20f7382dd24c' -and $ids -contains '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
        if (-not ($owner -or $contributorAndUaa)) { throw 'Owner, or Contributor plus User Access Administrator, was not proven at resource-group scope (including inherited/group roles).' }
        'Required unconditional built-in role assignment(s) found; deny assignments and Azure Policy can still reject deployment.'
    }
    Check 'Names and Bicep' 'operator' 'A valid, globally available prefix and local Azure CLI Bicep with build-params/using none support are required. Existing exact target resources can be reused.' {
        if (-not $context.ResourceGroupId) { throw 'Name availability requires the verified resource group.' }
        $storageName = Get-ClaudeProjectionStorageName -ResourceGroupId $context.ResourceGroupId -NamePrefix $NamePrefix
        $resources = @(Invoke-ClaudeNetworkAz @('resource','list','-g',$ResourceGroup,'--subscription',$context.SubscriptionId))
        $existingCosmos = @($resources | Where-Object id -eq $context.AccountResourceId | Select-Object -First 1)
        if ($existingCosmos.Count -and [string]$existingCosmos[0].location) {
            $existingLocation = [string]$existingCosmos[0].location
            if ($Location) {
                if ((ConvertTo-ClaudeProjectionLocationKey $Location) -ne (ConvertTo-ClaudeProjectionLocationKey $existingLocation)) {
                    throw "Cosmos account cosmos-$NamePrefix already exists in $existingLocation, but -Location requested $Location. Remedy: rerun with -Location $existingLocation or another -NamePrefix."
                }
            } else {
                $context.Location = $existingLocation
            }
        }
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
    Report
    $context.Remove('GraphToken')
    return $context
}
