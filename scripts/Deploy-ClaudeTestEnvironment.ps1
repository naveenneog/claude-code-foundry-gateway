<#
.SYNOPSIS
    Deploys a disposable test environment in stages, then checks it with a live smoke test (P121, ADR-0067).

.DESCRIPTION
    Stages, in order; -Phase names one or more, or All:

      Identity   Creates the resource group (tag claude-test-environment), four Entra groups
                 (standard, premium, unit a, unit b), the resolver app registration, and adds the
                 signed-in user to the standard group and unit a.
      Resources  Deploys infra/test-environment/resources.bicep: the gateway on Basic v2 with Foundry
                 in another tenant, the private Cosmos projection, its network and the job registry.
      Publish    Builds the sync image in the registry and records its digest.
      Configure  Deploys infra/test-environment/configuration.bicep (resolver, gateway named values,
                 sync job every -SyncMinutes) and publishes the resolver code.
      Grant      Grants Microsoft Graph GroupMember.Read.All to the job identity. Needs a Privileged
                 Role Administrator or Global Administrator.
      Populate   Starts the job once and waits for it to succeed.
      Smoke      As the signed-in user: the standard model returns 200 and the premium model 403; the
                 user moves to the premium group and unit b; with no operator step, the next scheduled
                 run makes the premium model return 200 and prints membership lines that place the user
                 in unit b.

    Teardown (not part of All) deletes the resource group and the Entra objects recorded on its tags.

    The Foundry client secret is read from -FoundrySecretSourceApim's named value into memory and sent
    to Azure Resource Manager in the deployment request body. It is never written to disk, printed, or
    put on a command line.

.EXAMPLE
    ./scripts/Deploy-ClaudeTestEnvironment.ps1 -SubscriptionId <id> -ResourceGroup rg-claude-test -PublisherEmail you@example.com `
        -FoundryAccountName <account> -FoundryEndpoint https://<account>.services.ai.azure.com/ -FoundryTenantId <tenant> `
        -FoundryClientId <app id> -FoundrySecretSourceApim <APIM resource id> -UseCurrentAzLogin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string[]]$Phase = @('All'),
    [int]$SyncMinutes = 5,
    [string]$Location = 'eastus2',
    [string]$NamePrefix,
    [string]$PublisherEmail,
    [string]$FoundryAccountName,
    [string]$FoundryEndpoint,
    [string]$FoundryTenantId,
    [string]$FoundryClientId,
    [string]$FoundrySecretSourceApim,
    [string]$FoundrySecretNamedValue = 'foundry-crosstenant-client-secret',
    [string]$StandardModels = 'claude-haiku-4-5,claude-sonnet-5',
    [string]$PremiumModels = 'claude-haiku-4-5,claude-sonnet-5,claude-opus-5',
    [string]$StandardModel = 'claude-haiku-4-5',
    [string]$PremiumModel = 'claude-opus-5',
    [ValidateRange(60, 3600)][int]$ChangeWaitSeconds = 1500,
    [ValidateRange(5, 120)][int]$PollSeconds = 20,
    [switch]$UseCurrentAzLogin
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$stages = @('Identity', 'Resources', 'Publish', 'Configure', 'Grant', 'Populate', 'Smoke')
$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$results = [System.Collections.Generic.List[object]]::new()
$tagKey = 'claude-test-environment'

# Every input is checked before any Azure call.
$problems = [System.Collections.Generic.List[string]]::new()
if ($SubscriptionId -notmatch $guid) { $problems.Add('-SubscriptionId must be a subscription GUID.') }
if ($ResourceGroup -notmatch '^[A-Za-z0-9._()-]{1,90}$' -or $ResourceGroup.EndsWith('.')) { $problems.Add('-ResourceGroup is not a valid resource group name.') }
if ($SyncMinutes -lt 5 -or $SyncMinutes -gt 30) { $problems.Add('-SyncMinutes must be 5 to 30; the production intervals start at 30 minutes (ADR-0058).') }
foreach ($p in $Phase) { if ($p -notin ($stages + 'All', 'Teardown')) { $problems.Add("-Phase '$p' is not one of: $(($stages + 'All', 'Teardown') -join ', ').") } }
if ($NamePrefix -and $NamePrefix -cnotmatch '^[a-z][a-z0-9]{0,19}$') { $problems.Add('-NamePrefix must be 1-20 lower-case letters and digits, starting with a letter.') }
foreach ($m in @($StandardModels -split ',') + @($PremiumModels -split ',') + $StandardModel + $PremiumModel) {
    if ($m -and $m -cnotmatch '^[a-z0-9][a-z0-9.-]{0,63}$') { $problems.Add("Model '$m' is not a deployment name.") }
}
if ($problems.Count) { $problems | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; exit 2 }

$run = if ($Phase -contains 'All') { $stages } else { @($stages | Where-Object { $_ -in $Phase }) }
$teardown = $Phase -contains 'Teardown'
if (-not $NamePrefix) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ResourceGroup.ToLowerInvariant())))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $NamePrefix = 't' + $hash.Substring(0, 9)
}

. (Join-Path $PSScriptRoot 'ClaudeLiveHarness.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')
Assert-AzProfileAllowed -UseCurrentAzLogin:$UseCurrentAzLogin

function Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Note([string]$Text) { Write-Host "   $Text" -ForegroundColor DarkGray }
function AzS([string[]]$Arguments, [switch]$AllowFailure) { Invoke-Az ($Arguments + @('--subscription', $SubscriptionId)) -AllowFailure:$AllowFailure }

function Get-ArmToken([string]$Resource = 'https://management.azure.com/') {
    $token = Invoke-Az @('account', 'get-access-token', '--subscription', $SubscriptionId, '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv')
    if (-not $token) { throw "No access token for $Resource." }
    return $token
}

function Get-EnvironmentTags {
    $raw = AzS @('group', 'show', '-n', $ResourceGroup, '--query', 'tags', '-o', 'json') -AllowFailure
    if (-not $raw) { return $null }
    $tags = $raw | ConvertFrom-Json -AsHashtable
    if (-not $tags -or -not $tags.ContainsKey($tagKey)) {
        throw "Resource group '$ResourceGroup' exists and was not created by Deploy-ClaudeTestEnvironment.ps1 (no $tagKey tag); nothing was changed."
    }
    if ($tags[$tagKey] -cne $NamePrefix) { throw "Resource group '$ResourceGroup' belongs to test environment '$($tags[$tagKey])', not '$NamePrefix'; nothing was changed." }
    return $tags
}

function Set-EnvironmentTag([string]$Key, [string]$Value) {
    $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
    $null = Invoke-Az @('tag', 'update', '--resource-id', $id, '--operation', 'Merge', '--tags', "$Key=$Value")
}

# ARM deployment through REST, so a secure parameter travels only in the request body.
function Invoke-TestDeployment([string]$Name, [string]$TemplateFile, [hashtable]$Parameters) {
    $template = Invoke-Az @('bicep', 'build', '--file', (Join-Path $root $TemplateFile), '--stdout')
    $body = @{ properties = @{ mode = 'Incremental'; template = ($template | ConvertFrom-Json -AsHashtable); parameters = @{} } }
    foreach ($k in $Parameters.Keys) { $body.properties.parameters[$k] = @{ value = $Parameters[$k] } }
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroup/providers/Microsoft.Resources/deployments/$Name`?api-version=2024-03-01"
    $headers = @{ Authorization = 'Bearer ' + (Get-ArmToken) }
    $null = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 100 -Compress)
    $body = $null
    $deadline = (Get-Date).AddMinutes(90)
    do {
        Start-Sleep -Seconds 20
        $state = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = 'Bearer ' + (Get-ArmToken) }
        $status = [string]$state.properties.provisioningState
        Note "$Name $status"
    } while ($status -notin 'Succeeded', 'Failed', 'Canceled' -and (Get-Date) -lt $deadline)
    if ($status -ne 'Succeeded') {
        $ops = Invoke-RestMethod -Uri ($uri.Replace("deployments/$Name`?", "deployments/$Name/operations?")) -Headers @{ Authorization = 'Bearer ' + (Get-ArmToken) }
        $failed = @($ops.value | Where-Object { $_.properties.provisioningState -eq 'Failed' } | ForEach-Object {
            "$($_.properties.targetResource.resourceName): $($_.properties.statusMessage.error.message ?? ($_.properties.statusMessage | ConvertTo-Json -Depth 6 -Compress))" })
        throw "Deployment $Name ended $status. $($failed -join ' | ')"
    }
    return Get-DeploymentOutputs $Name
}

function Get-DeploymentOutputs([string]$Name) {
    $raw = AzS @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $Name, '--query', 'properties.outputs', '-o', 'json') -AllowFailure
    if (-not $raw) { throw "Deployment $Name is not in $ResourceGroup; run its stage first." }
    $outputs = @{}
    ($raw | ConvertFrom-Json -AsHashtable).GetEnumerator() | ForEach-Object { $outputs[$_.Key] = $_.Value.value }
    return $outputs
}

function Get-GroupIds {
    $tags = Get-EnvironmentTags
    if (-not $tags -or -not $tags['claude-test-groups']) { throw 'The Identity stage has not run for this resource group.' }
    $ids = $tags['claude-test-groups'] -split ','
    return @{ standard = $ids[0]; premium = $ids[1]; unitA = $ids[2]; unitB = $ids[3]; resolverApp = $tags['claude-test-resolver-app']; image = $tags['claude-test-image'] }
}

function Get-SignedInUser { Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv') }

function Set-Membership([string]$GroupId, [string]$MemberId, [bool]$Member) {
    $now = Invoke-Az @('ad', 'group', 'member', 'check', '--group', $GroupId, '--member-id', $MemberId, '--query', 'value', '-o', 'tsv')
    if ($Member -and $now -ne 'true') { $null = Invoke-Az @('ad', 'group', 'member', 'add', '--group', $GroupId, '--member-id', $MemberId) }
    if (-not $Member -and $now -eq 'true') { $null = Invoke-Az @('ad', 'group', 'member', 'remove', '--group', $GroupId, '--member-id', $MemberId) }
}

# Log Analytics query through REST; the KQL never passes through az.cmd (cmd.exe would parse its | and ( ).
function Invoke-WorkspaceQuery([string]$WorkspaceId, [string]$Query) {
    $customerId = AzS @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $WorkspaceId, '--query', 'customerId', '-o', 'tsv')
    $headers = @{ Authorization = 'Bearer ' + (Get-ArmToken 'https://api.loganalytics.io') }
    $response = Invoke-RestMethod -Method Post -Uri "https://api.loganalytics.io/v1/workspaces/$customerId/query" -Headers $headers -ContentType 'application/json' -Body (@{ query = $Query } | ConvertTo-Json -Compress)
    $table = $response.tables[0]
    $names = @($table.columns | ForEach-Object name)
    return @($table.rows | ForEach-Object { $row = $_; $o = [ordered]@{}; for ($i = 0; $i -lt $names.Count; $i++) { $o[$names[$i]] = $row[$i] }; [pscustomobject]$o })
}

Write-Host ''
Write-Host "Test environment $NamePrefix in $ResourceGroup ($SubscriptionId): $(($run + $(if ($teardown) { 'Teardown' })) -join ', ')" -ForegroundColor Cyan
Note "tenant $(Invoke-Az @('account', 'show', '--subscription', $SubscriptionId, '--query', 'tenantId', '-o', 'tsv'))"

if ('Identity' -in $run) {
    Step 'Identity: resource group, groups, resolver app'
    $tags = Get-EnvironmentTags
    if (-not $tags) {
        $null = AzS @('group', 'create', '-n', $ResourceGroup, '-l', $Location, '--tags', "$tagKey=$NamePrefix", 'purpose=claude-gateway-test', '-o', 'none')
        Add-Result 'resource group created' $true $ResourceGroup
        $tags = @{}
    }
    $me = Get-SignedInUser
    $ids = if ($tags['claude-test-groups']) { $tags['claude-test-groups'] -split ',' } else {
        @(foreach ($role in 'standard', 'premium', 'unit-a', 'unit-b') {
            $name = "claude-test-$NamePrefix-$role"
            Invoke-Az @('ad', 'group', 'create', '--display-name', $name, '--mail-nickname', $name, '--query', 'id', '-o', 'tsv')
        })
    }
    Set-EnvironmentTag 'claude-test-groups' ($ids -join ',')
    Set-Membership $ids[0] $me $true
    Set-Membership $ids[2] $me $true
    Add-Result 'groups ready; the signed-in user is in standard and unit a' $true ($ids -join ', ')
    $appId = $tags['claude-test-resolver-app']
    if (-not $appId) {
        $appId = Invoke-Az @('ad', 'app', 'create', '--display-name', "claude-test-resolver-$NamePrefix", '--sign-in-audience', 'AzureADMyOrg', '--query', 'appId', '-o', 'tsv')
        Set-EnvironmentTag 'claude-test-resolver-app' $appId
        $null = Invoke-Az @('ad', 'app', 'update', '--id', $appId, '--identifier-uris', "api://$appId")
    }
    if (-not (Invoke-Az @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFailure)) { $null = Invoke-Az @('ad', 'sp', 'create', '--id', $appId) }
    Add-Result 'resolver app registration ready' $true $appId
}

if ('Resources' -in $run) {
    Step 'Resources: infra/test-environment/resources.bicep'
    $null = Get-GroupIds
    foreach ($required in 'PublisherEmail', 'FoundryAccountName', 'FoundryEndpoint', 'FoundryTenantId', 'FoundryClientId', 'FoundrySecretSourceApim') {
        if (-not (Get-Variable -Name $required -ValueOnly)) { throw "-$required is required for the Resources stage." }
    }
    if ($FoundrySecretSourceApim -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/service/[^/]+$') { throw '-FoundrySecretSourceApim must be an API Management resource id.' }
    $foundrySecret = Invoke-Az @('rest', '--method', 'post', '--url', "https://management.azure.com$FoundrySecretSourceApim/namedValues/$FoundrySecretNamedValue/listValue?api-version=2024-05-01", '--query', 'value', '-o', 'tsv')
    if (-not $foundrySecret) { throw "Named value $FoundrySecretNamedValue on the source gateway returned no value." }
    try {
        $out = Invoke-TestDeployment 'test-resources' 'infra/test-environment/resources.bicep' @{
            namePrefix = $NamePrefix; location = $Location; publisherEmail = $PublisherEmail
            foundryAccountName = $FoundryAccountName; foundryEndpoint = $FoundryEndpoint; foundryTenantId = $FoundryTenantId
            foundryClientId = $FoundryClientId; foundryClientSecret = $foundrySecret
            modelsStandard = ",$StandardModels,"; modelsPremium = ",$PremiumModels,"
        }
    }
    finally { $foundrySecret = $null }
    Add-Result 'resources deployed' $true "$($out.apimName), $($out.cosmosAccountName), $($out.acrName)"
}

if ('Publish' -in $run) {
    Step 'Publish: sync image'
    $res = Get-DeploymentOutputs 'test-resources'
    $tag = 'p121-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
    $package = New-ClaudeProjectionSyncPackage -Destination (Join-Path ([IO.Path]::GetTempPath()) ('claude-sync-' + [guid]::NewGuid().ToString('N'))) -Root $root
    try { $null = AzS @('acr', 'build', '--registry', $res.acrName, '--image', "claude-projection-sync:$tag", '--file', 'sync/Dockerfile', '--no-logs', '--only-show-errors', '-o', 'none', $package) }
    finally { Remove-Item -LiteralPath $package -Recurse -Force -ErrorAction SilentlyContinue }
    $digest = AzS @('acr', 'manifest', 'show-metadata', '--registry', $res.acrName, '--name', "claude-projection-sync:$tag", '--query', 'digest', '-o', 'tsv')
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw "The registry returned '$digest', not a sha256 digest." }
    Set-EnvironmentTag 'claude-test-image' $digest
    Add-Result 'sync image built' $true $digest
}

if ('Configure' -in $run) {
    Step "Configure: infra/test-environment/configuration.bicep (sync every $SyncMinutes minutes)"
    $res = Get-DeploymentOutputs 'test-resources'
    $ids = Get-GroupIds
    if (-not $ids.image) { throw 'The Publish stage has not run; there is no sync image.' }
    $gatewayAppId = Invoke-Az @('ad', 'sp', 'show', '--id', $res.apimPrincipalId, '--query', 'appId', '-o', 'tsv')
    if (-not $PublisherEmail) { $PublisherEmail = AzS @('apim', 'show', '-g', $ResourceGroup, '-n', $res.apimName, '--query', 'publisherEmail', '-o', 'tsv') }
    $cfg = Invoke-TestDeployment 'test-configuration' 'infra/test-environment/configuration.bicep' @{
        namePrefix = $NamePrefix; location = $Location; apimName = $res.apimName; cosmosAccountName = $res.cosmosAccountName
        workspaceId = $res.workspaceId; resolverSubnetId = $res.resolverSubnetId; renewalSubnetId = $res.renewalSubnetId
        acrName = $res.acrName; jobIdentityName = $res.jobIdentityName; resolverAppId = $ids.resolverApp
        gatewayAppId = $gatewayAppId; gatewayPrincipalId = $res.apimPrincipalId; syncImageDigest = $ids.image
        standardGroupId = $ids.standard; premiumGroupId = $ids.premium
        buRegistry = ",unit-a=$($ids.unitA):100000000,unit-b=$($ids.unitB):100000000,"; buParents = ',,'
        syncMinutes = $SyncMinutes; alertEmails = @($PublisherEmail)
    }
    Add-Result 'configuration deployed' $true "job $($cfg.jobName) on $($cfg.cronExpression); resolver $($cfg.resolverUrl)"

    $stage = Join-Path ([IO.Path]::GetTempPath()) ('claude-resolver-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        Copy-Item (Join-Path $root 'resolver/host.json'), (Join-Path $root 'resolver/package.json') $stage
        Copy-Item (Join-Path $root 'resolver/src') $stage -Recurse
        Push-Location $stage
        try {
            & npm install --omit=dev --no-audit --fund=false --loglevel=error | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'resolver dependency installation failed' }
            $zip = New-ClaudeProjectionResolverArchive -Source $stage -Path (Join-Path $stage 'resolver.zip')
            $null = AzS @('functionapp', 'deployment', 'source', 'config-zip', '-g', $ResourceGroup, '-n', $cfg.resolverSiteName, '--src', $zip, '-o', 'none')
        }
        finally { Pop-Location }
    }
    finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    Add-Result 'resolver code published' $true $cfg.resolverSiteName
}

if ('Grant' -in $run) {
    Step 'Grant: Microsoft Graph GroupMember.Read.All for the job identity'
    $res = Get-DeploymentOutputs 'test-resources'
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & (Join-Path $PSScriptRoot 'Grant-ClaudeProjectionRenewalGraphAccess.ps1') -PrincipalId $res.jobIdentityPrincipalId 2>&1 | Out-String
    $code = $LASTEXITCODE; $ErrorActionPreference = $saved
    $granted = ($code -eq 0)
    Add-Result 'Graph grant' $granted $(if ($granted) { 'held' } else { "not granted. A Privileged Role Administrator or Global Administrator runs: ./scripts/Grant-ClaudeProjectionRenewalGraphAccess.ps1 -PrincipalId $($res.jobIdentityPrincipalId). $(($out -split "`n" | Where-Object { $_ -match 'Authorization|Forbidden|denied|privilege' } | Select-Object -First 1).Trim())" })
    if (-not $granted) { throw 'The job identity has no Graph grant; its runs stop at the Graph stage. Rerun from -Phase Grant once an administrator has granted it.' }
}

function Wait-JobExecution([string]$JobName, [string]$Execution, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        Start-Sleep -Seconds $PollSeconds
        $status = AzS @('containerapp', 'job', 'execution', 'show', '-g', $ResourceGroup, '-n', $JobName, '--job-execution-name', $Execution, '--query', 'properties.status', '-o', 'tsv') -AllowFailure
        Note "$Execution $status"
    } while ($status -notin 'Succeeded', 'Failed', 'Stopped', 'Degraded' -and (Get-Date) -lt $deadline)
    return $status
}

if ('Populate' -in $run) {
    Step 'Populate: one job run'
    $cfg = Get-DeploymentOutputs 'test-configuration'
    $execution = AzS @('containerapp', 'job', 'start', '-g', $ResourceGroup, '-n', $cfg.jobName, '--query', 'name', '-o', 'tsv')
    $status = Wait-JobExecution $cfg.jobName $execution 900
    Add-Result 'first sync run' ($status -eq 'Succeeded') "$execution $status"
    if ($status -ne 'Succeeded') { throw "The first sync run ended $status; see ContainerAppConsoleLogs for $($cfg.jobName)." }
}

if ('Smoke' -in $run) {
    Step 'Smoke: request, move, scheduled run, membership'
    $res = Get-DeploymentOutputs 'test-resources'
    $cfg = Get-DeploymentOutputs 'test-configuration'
    $ids = Get-GroupIds
    $me = Get-SignedInUser
    $url = "$($res.gatewayUrl.TrimEnd('/'))/v1/messages"
    Set-Membership $ids.premium $me $false
    Set-Membership $ids.unitB $me $false
    Wait-GatewayStatus -Url $url -ModelName $StandardModel -Expected 200 -Step 'standard model as a standard developer'
    Wait-GatewayStatus -Url $url -ModelName $PremiumModel -Expected 403 -Step 'premium model refused to a standard developer'

    $moved = (Get-Date).ToUniversalTime()
    Set-Membership $ids.standard $me $false
    Set-Membership $ids.premium $me $true
    Set-Membership $ids.unitA $me $false
    Set-Membership $ids.unitB $me $true
    Add-Result 'moved to premium and unit b in Entra; no sync started by hand' $true $moved.ToString('o')
    Wait-GatewayStatus -Url $url -ModelName $PremiumModel -Expected 200 -Step 'premium model after the scheduled run'

    $query = @"
ContainerAppConsoleLogs
| where TimeGenerated > datetime($($moved.ToString('o'))) and JobName == "$($cfg.jobName)"
| where Log has "projection-membership"
| extend m = parse_json(substring(Log, indexof(Log, "{")))
| mv-expand row = m.rows
| where tostring(row[0]) == "$me"
| project TimeGenerated, unit = tostring(row[1]), run = tostring(m.run)
| top 1 by TimeGenerated desc
"@
    $deadline = (Get-Date).AddSeconds($ChangeWaitSeconds)
    $line = $null
    do {
        $line = @(Invoke-WorkspaceQuery $res.workspaceId $query | Where-Object unit -eq 'unit-b') | Select-Object -First 1
        if (-not $line) { Start-Sleep -Seconds $PollSeconds }
    } while (-not $line -and (Get-Date) -lt $deadline)
    Add-Result 'membership lines place the user in unit b (P120)' ([bool]$line) $(if ($line) { "run $($line.run) at $($line.TimeGenerated)" } else { "no line within $ChangeWaitSeconds s" })

    $runs = Invoke-WorkspaceQuery $res.workspaceId @"
ContainerAppConsoleLogs
| where TimeGenerated > datetime($($moved.ToString('o'))) and JobName == "$($cfg.jobName)"
| where Log has "projection-renewal-succeeded"
| summarize runs = count(), first = min(TimeGenerated)
"@
    Add-Result 'a scheduled run succeeded after the move' ([int]$runs[0].runs -ge 1) "runs $($runs[0].runs), first $($runs[0].first)"
}

if ($teardown) {
    Step 'Teardown'
    $tags = Get-EnvironmentTags
    if (-not $tags) { Add-Result 'nothing to delete' $true $ResourceGroup }
    else {
        $left = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @(($tags['claude-test-groups'] ?? '') -split ',' | Where-Object { $_ -match $guid })) {
            $null = Invoke-TeardownAz "group $id" @('ad', 'group', 'delete', '--group', $id) "az ad group delete --group $id" $left
        }
        if ($tags['claude-test-resolver-app'] -match $guid) {
            $null = Invoke-TeardownAz "app $($tags['claude-test-resolver-app'])" @('ad', 'app', 'delete', '--id', $tags['claude-test-resolver-app']) "az ad app delete --id $($tags['claude-test-resolver-app'])" $left
        }
        $null = Invoke-TeardownAz "resource group $ResourceGroup" @('group', 'delete', '-n', $ResourceGroup, '--yes', '--subscription', $SubscriptionId) "az group delete -n $ResourceGroup --subscription $SubscriptionId" $left
        Add-Result 'teardown' (-not $left.Count) ($left -join ' | ')
    }
}

Write-Host ''
$failed = @($results | Where-Object { -not $_.ok })
if ($failed.Count) { Write-Host "$($failed.Count) of $($results.Count) step(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($results.Count) step(s) passed." -ForegroundColor Green
exit 0
