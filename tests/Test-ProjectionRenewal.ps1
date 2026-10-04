# The projection renewal job's templates and deploy script (ADR-0049, P94).
#
# Offline. Templates are compiled with the Bicep CLI and read as ARM JSON; nothing reaches Azure.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('projection-renewal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Each az bicep build takes about 13 s, nearly all of it CLI start-up, so the templates compile at once.
$templateFiles = 'infra\projection-network.bicep', 'infra\projection-registry.bicep', 'infra\projection-renewal.bicep'
$compileJobs = foreach ($relative in $templateFiles) {
    $out = Join-Path $work (([IO.Path]::GetFileNameWithoutExtension($relative)) + '.json')
    Start-ThreadJob -ArgumentList (Join-Path $root $relative), $out, $relative -ScriptBlock {
        param($file, $out, $relative)
        $ErrorActionPreference = 'Continue'
        $log = & az bicep build --file $file --outfile $out 2>&1 | Out-String
        [pscustomobject]@{ Relative = $relative; Out = $out; Log = $log }
    }
}
$compiled = @{}
foreach ($job in $compileJobs) { $result = Receive-Job -Job $job -Wait -AutoRemoveJob; $compiled[$result.Relative] = $result }

function Get-CompiledTemplate([string]$Relative) {
    $result = $compiled[$Relative]
    if (-not $result -or -not (Test-Path -LiteralPath $result.Out)) { Assert "$Relative compiles" $false $(if ($result) { $result.Log.Trim() } else { 'not compiled' }); return $null }
    Assert "$Relative compiles" $true
    return (Get-Content -LiteralPath $result.Out -Raw | ConvertFrom-Json -AsHashtable)
}

function Get-TemplateResources($Template) {
    if ($Template.resources -is [Collections.IDictionary]) { return @($Template.resources.Values) }
    return @($Template.resources)
}

function ConvertTo-Ipv4Number([string]$Address) {
    $bytes = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return ([uint64]$bytes[0] -shl 24) + ([uint64]$bytes[1] -shl 16) + ([uint64]$bytes[2] -shl 8) + [uint64]$bytes[3]
}

# Bicep's cidrSubnet(prefix, newBits, index): the index-th subnet of length newBits inside prefix.
function Get-CidrSubnetRange([string]$Prefix, [int]$Bits, [int]$Index) {
    $address, $length = $Prefix -split '/'
    $size = [uint64][math]::Pow(2, 32 - $Bits)
    $start = (ConvertTo-Ipv4Number $address) + ([uint64]$Index * $size)
    [pscustomobject]@{ Start = $start; End = $start + $size - 1; Bits = $Bits }
}

try {
    Write-Host ''
    Write-Host 'Projection renewal - the network has a subnet for the job' -ForegroundColor Cyan

    $network = Get-CompiledTemplate 'infra\projection-network.bicep'
    if ($network) {
        Assert 'an existing VNet passes a renewal subnet' ($network.parameters.Contains('renewalSubnetId') -and $network.parameters.renewalSubnetId.defaultValue -eq '')
        $vnet = Get-TemplateResources $network | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' } | Select-Object -First 1
        $prefix = [string]$network.parameters.vnetAddressPrefix.defaultValue
        $plan = Get-CidrSubnetRange $prefix ([int]($prefix -split '/')[1]) 0
        $ranges = @()
        foreach ($subnet in @($vnet.properties.subnets)) {
            $m = [regex]::Match([string]$subnet.properties.addressPrefix, "cidrSubnet\(parameters\('vnetAddressPrefix'\), (\d+), (\d+)\)")
            Assert "subnet $($subnet.name) is carved from the address plan" $m.Success ([string]$subnet.properties.addressPrefix)
            if ($m.Success) { $ranges += [pscustomobject]@{ Name = $subnet.name; Range = (Get-CidrSubnetRange $prefix ([int]$m.Groups[1].Value) ([int]$m.Groups[2].Value)); Subnet = $subnet } }
        }
        $renewal = $ranges | Where-Object Name -eq 'renewal' | Select-Object -First 1
        Assert 'a new VNet gets a renewal subnet' ([bool]$renewal) (($ranges | ForEach-Object Name) -join ', ')
        if ($renewal) {
            $delegations = @($renewal.Subnet.properties.delegations | ForEach-Object { $_.properties.serviceName })
            Assert 'it is delegated to Microsoft.App/environments only' (($delegations -join ',') -eq 'Microsoft.App/environments') ($delegations -join ',')
            Assert 'it is at least a /27' ($renewal.Range.Bits -le 27) "/$($renewal.Range.Bits)"
        }
        $overlaps = @()
        for ($i = 0; $i -lt $ranges.Count; $i++) {
            if ($ranges[$i].Range.Start -lt $plan.Start -or $ranges[$i].Range.End -gt $plan.End) { $overlaps += "$($ranges[$i].Name) is outside $prefix" }
            for ($j = $i + 1; $j -lt $ranges.Count; $j++) {
                if ($ranges[$i].Range.Start -le $ranges[$j].Range.End -and $ranges[$j].Range.Start -le $ranges[$i].Range.End) { $overlaps += "$($ranges[$i].Name) overlaps $($ranges[$j].Name)" }
            }
        }
        Assert "no subnet overlaps another in the default plan $prefix" ($ranges.Count -ge 4 -and $overlaps.Count -eq 0) ($overlaps -join '; ')
        $output = [string]$network.outputs.renewalSubnetId.value
        Assert 'the renewal subnet is an output, from either VNet shape' ($output -match "subnets/renewal" -and $output -match "parameters\('renewalSubnetId'\)") $output
    }

    Write-Host ''
    Write-Host 'Projection renewal - the registry and the job identity come first' -ForegroundColor Cyan

    $registry = Get-CompiledTemplate 'infra\projection-registry.bicep'
    if ($registry) {
        $res = Get-TemplateResources $registry
        $acr = $res | Where-Object { $_.type -eq 'Microsoft.ContainerRegistry/registries' -and -not $_.existing } | Select-Object -First 1
        Assert 'the registry template creates the registry' ([bool]$acr)
        Assert 'with no admin user' ($acr -and $acr.properties.adminUserEnabled -eq $false)
        Assert 'the registry SKU defaults to Basic, with Premium allowed' ($registry.parameters.acrSku.defaultValue -eq 'Basic' -and (@($registry.parameters.acrSku.allowedValues) -join ',') -eq 'Basic,Premium')
        Assert 'it creates the job identity' (@($res | Where-Object { $_.type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities' -and -not $_.existing }).Count -eq 1)
        $pull = $res | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' } | Select-Object -First 1
        Assert 'and grants it AcrPull on the registry' ($pull -and [string]$pull.properties.roleDefinitionId -match '7f951dda-4ed3-4680-a7ca-43fe172d538d' -and [string]$pull.scope -match 'Microsoft\.ContainerRegistry/registries') ([string]$pull.scope)
        foreach ($name in 'acrName', 'acrLoginServer', 'identityName', 'identityClientId', 'identityPrincipalId') {
            Assert "it outputs $name" ($registry.outputs.Contains($name))
        }
    }
    $renewalTemplate = Get-CompiledTemplate 'infra\projection-renewal.bicep'
    if ($renewalTemplate) {
        $res = Get-TemplateResources $renewalTemplate
        Assert 'the renewal template creates no registry' (-not @($res | Where-Object { $_.type -eq 'Microsoft.ContainerRegistry/registries' -and -not $_.existing }).Count)
        Assert 'and no identity' (-not @($res | Where-Object { $_.type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities' -and -not $_.existing }).Count)
        Assert 'and no AcrPull grant' (-not @($res | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' -and [string]$_.properties.roleDefinitionId -match '7f951dda' }).Count)
        Assert 'it takes the registry and the identity by name' ($renewalTemplate.parameters.Contains('acrName') -and $renewalTemplate.parameters.Contains('identityName') -and -not $renewalTemplate.parameters.Contains('acrSku'))
    }
    $rb = [IO.File]::ReadAllText((Join-Path $root 'infra\projection-renewal.bicep'))
    Assert 'the renewal template references them as existing resources' ($rb -match "resource acr 'Microsoft\.ContainerRegistry/registries@[0-9-]+' existing" -and $rb -match "resource identity 'Microsoft\.ManagedIdentity/userAssignedIdentities@[0-9-]+' existing")

    Write-Host ''
    Write-Host 'Projection renewal - the job carries its identity, tier groups and gateway' -ForegroundColor Cyan
    if ($renewalTemplate) {
        foreach ($name in 'standardGroupId', 'premiumGroupId', 'gatewayResourceId') {
            Assert "the renewal template takes $name" ($renewalTemplate.parameters.Contains($name))
        }
        $job = Get-TemplateResources $renewalTemplate | Where-Object { $_.type -eq 'Microsoft.App/jobs' } | Select-Object -First 1
        $container = @($job.properties.template.containers)[0]
        $jobEnv = @{}
        foreach ($e in @($container.env)) { $jobEnv[$e.name] = [string]$e.value }
        Assert 'the job names its user-assigned identity to the Azure SDK' ($jobEnv['AZURE_CLIENT_ID'] -match 'clientId' -and $jobEnv['AZURE_CLIENT_ID'] -match 'identityName') $jobEnv['AZURE_CLIENT_ID']
        Assert 'the job gets the standard tier group id' ($jobEnv['PROJECTION_STANDARD_GROUP_ID'] -eq "[parameters('standardGroupId')]") $jobEnv['PROJECTION_STANDARD_GROUP_ID']
        Assert 'the job gets the premium tier group id' ($jobEnv['PROJECTION_PREMIUM_GROUP_ID'] -eq "[parameters('premiumGroupId')]") $jobEnv['PROJECTION_PREMIUM_GROUP_ID']
        Assert 'the job gets the gateway whose units it reads' ($jobEnv['PROJECTION_GATEWAY_RESOURCE_ID'] -eq "[parameters('gatewayResourceId')]") $jobEnv['PROJECTION_GATEWAY_RESOURCE_ID']
        Assert 'the job runs the image entry point and command unchanged' (@($container.command).Count -eq 0 -and @($container.args).Count -eq 0)
        $reader = Get-TemplateResources $renewalTemplate | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' } | Select-Object -First 1
        Assert 'a nested deployment grants the read at the gateway resource group' ($reader -and [string]$reader.resourceGroup -match 'gatewayResourceId' -and [string]$reader.subscriptionId -match 'gatewayResourceId') "rg=$($reader.resourceGroup) subscription=$($reader.subscriptionId)"
        if ($reader) {
            $nested = $reader.properties.template
            $roleDefinition = Get-TemplateResources $nested | Where-Object { $_.type -eq 'Microsoft.Authorization/roleDefinitions' } | Select-Object -First 1
            $actions = @($roleDefinition.properties.permissions | ForEach-Object { $_.actions } | ForEach-Object { $_ })
            $dataActions = @($roleDefinition.properties.permissions | ForEach-Object { $_.dataActions } | ForEach-Object { $_ } | Where-Object { $_ })
            Assert 'the role reads named values and nothing else' (($actions -join ',') -eq 'Microsoft.ApiManagement/service/namedValues/read' -and $dataActions.Count -eq 0) ($actions -join ',')
            $assignment = Get-TemplateResources $nested | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' } | Select-Object -First 1
            Assert 'it is assigned to the job identity on the gateway' ($assignment -and [string]$assignment.scope -match 'Microsoft\.ApiManagement/service' -and $assignment.properties.principalType -eq 'ServicePrincipal' -and [string]$reader.properties.parameters.principalId.value -match 'principalId')
        }
        $jobDepends = @($job.dependsOn) -join ' '
        Assert 'the job waits for its named-value read role' ($jobDepends -match 'Microsoft\.Resources/deployments|gatewayReader') $jobDepends
    }
    $docker = [IO.File]::ReadAllText((Join-Path $root 'sync\Dockerfile'))
    Assert 'the image command is --graph alone, and the job supplies the rest' ($docker -match '(?m)^CMD \["--graph"\]\s*$')

    Write-Host ''
    Write-Host 'Projection renewal - logs reach the workspace and alerts fire only when unhealthy' -ForegroundColor Cyan
    if ($renewalTemplate) {
        $res = Get-TemplateResources $renewalTemplate
        $environment = $res | Where-Object { $_.type -eq 'Microsoft.App/managedEnvironments' } | Select-Object -First 1
        $logsConfig = $environment.properties.appLogsConfiguration
        Assert 'the environment sends logs through Azure Monitor, with no shared key' ($logsConfig.destination -eq 'azure-monitor' -and -not $logsConfig.Contains('logAnalyticsConfiguration')) ($logsConfig | ConvertTo-Json -Compress)
        $diagnostic = $res | Where-Object { $_.type -eq 'Microsoft.Insights/diagnosticSettings' } | Select-Object -First 1
        Assert 'a diagnostic setting sends every log category to the gateway workspace' (
            $diagnostic -and [string]$diagnostic.scope -match 'Microsoft\.App/managedEnvironments' -and
            [string]$diagnostic.properties.workspaceId -match "parameters\('logAnalyticsWorkspaceId'\)" -and
            @($diagnostic.properties.logs | Where-Object { $_.categoryGroup -eq 'allLogs' -and $_.enabled }).Count -eq 1)
        $job = $res | Where-Object { $_.type -eq 'Microsoft.App/jobs' } | Select-Object -First 1
        Assert 'the job waits for its log route' ((@($job.dependsOn) -join ' ') -match 'diagnosticSettings|environmentLogs')

        $definitions = @($renewalTemplate.variables.alertDefinitions)
        $base = [string]$renewalTemplate.variables.renewalLogs
        Assert 'there are three renewal alerts' ((($definitions | ForEach-Object name) -join ',') -eq 'no-success-45m,expiry-margin-60m,renewal-failed') (($definitions | ForEach-Object name) -join ',')
        Assert 'each query reads the job''s console table through a fuzzy union with an empty table' ($base -match '(?m)^union isfuzzy=true \(datatable\(TimeGenerated: datetime, JobName: string, Log: string\) \[\]\), ContainerAppConsoleLogs\s*$') $base
        Assert 'each query keeps only the job''s own lines' ($base -match 'JobName == "\{jobName\}"') $base
        $rule = $res | Where-Object { $_.type -eq 'Microsoft.Insights/scheduledQueryRules' } | Select-Object -First 1
        $criterion = @($rule.properties.criteria.allOf)[0]
        Assert 'the job name is put into each query' ([string]$criterion.query -match "replace\(" -and [string]$criterion.query -match "'\{jobName\}', variables\('jobName'\)") ([string]$criterion.query)
        Assert 'a rule fires when its query returns any row' ($criterion.timeAggregation -eq 'Count' -and $criterion.operator -eq 'GreaterThan' -and [int]$criterion.threshold -eq 0 -and -not $criterion.Contains('metricMeasureColumn'))
        Assert 'each rule notifies the action group' ([string](@($rule.properties.actions.actionGroups)[0]) -match 'actionGroups')
        $events = [IO.File]::ReadAllText((Join-Path $root 'sync\src\events.mjs'))
        $succeeded = [regex]::Match($events, "RENEWAL_SUCCEEDED = '([^']+)'").Groups[1].Value
        $failedEvent = [regex]::Match($events, "RENEWAL_FAILED = '([^']+)'").Groups[1].Value
        foreach ($definition in $definitions) {
            $query = $base + [string]$definition.query
            $lines = @($query -split "`r?`n" | Where-Object { $_.Trim() })
            Assert "$($definition.name): no legacy table or column" ($query -notmatch '_CL\b|Log_s\b')
            Assert "$($definition.name): no summarize that always returns a row" ($query -notmatch 'summarize' -or $lines[-1] -match '^\| where ') $lines[-1]
            Assert "$($definition.name): no datetime passed as epoch seconds" ($query -notmatch 'unixtime_seconds_todatetime\(now\(\)\)')
            $expected = if ($definition.name -eq 'renewal-failed') { $failedEvent } else { $succeeded }
            Assert "$($definition.name): it matches the job's $expected line" ($expected -and $query.Contains("'`"event`":`"$expected`"'")) $query
        }
        $expiry = [string]($definitions | Where-Object name -eq 'expiry-margin-60m').query
        Assert 'the expiry rule reads the newest success and its remaining lease' ($expiry -match 'top 1 by TimeGenerated desc' -and $expiry -match "unixtime_seconds_todatetime\(todouble\(extract\('`"oldestExpiresAt`":\(\[0-9\]\+\)', 1, Log\)\)\)" -and $expiry -match '- now\(\) < 1h') $expiry
    }

    Write-Host ''
    Write-Host 'Projection renewal - admission refuses a job without these settings' -ForegroundColor Cyan
    . (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
    $digest = 'sha256:' + ('c' * 64)
    function New-JobDefinition([hashtable]$Settings) {
        $jobContainer = @{
            name = 'projection-renewal'; image = "acr.example.invalid/claude-projection-sync@$digest"; command = @(); args = @()
            env = @($Settings.GetEnumerator() | Sort-Object Key | ForEach-Object { @{ name = $_.Key; value = $_.Value } })
        }
        return (@{ properties = @{ template = @{ containers = @($jobContainer) } } } | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }
    $goodSettings = @{
        AZURE_CLIENT_ID = '40000000-0000-4000-8000-000000000001'
        PROJECTION_STANDARD_GROUP_ID = '10000000-0000-4000-8000-000000000001'
        PROJECTION_PREMIUM_GROUP_ID = 'none'
        PROJECTION_GATEWAY_RESOURCE_ID = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg-p94/providers/Microsoft.ApiManagement/service/apim-p94'
    }
    $verdict = try { Assert-ClaudeProjectionJobDefinition -Job (New-JobDefinition $goodSettings) -ImageDigest $digest } catch { $_.Exception.Message }
    Assert 'a job with its client id, tier groups and gateway is accepted' ($verdict -eq $true) "$verdict"
    foreach ($case in @(
            @{ Name = 'no client id'; Change = @{ AZURE_CLIENT_ID = $null }; Names = 'AZURE_CLIENT_ID' }
            @{ Name = 'no standard group'; Change = @{ PROJECTION_STANDARD_GROUP_ID = $null }; Names = 'PROJECTION_STANDARD_GROUP_ID' }
            @{ Name = 'a standard group name instead of an id'; Change = @{ PROJECTION_STANDARD_GROUP_ID = 'claude-code-standard' }; Names = 'PROJECTION_STANDARD_GROUP_ID' }
            @{ Name = 'no premium setting'; Change = @{ PROJECTION_PREMIUM_GROUP_ID = $null }; Names = 'PROJECTION_PREMIUM_GROUP_ID' }
            @{ Name = 'an empty premium setting'; Change = @{ PROJECTION_PREMIUM_GROUP_ID = '' }; Names = 'PROJECTION_PREMIUM_GROUP_ID' }
            @{ Name = 'no gateway'; Change = @{ PROJECTION_GATEWAY_RESOURCE_ID = $null }; Names = 'PROJECTION_GATEWAY_RESOURCE_ID' }
            @{ Name = 'a gateway that is not API Management'; Change = @{ PROJECTION_GATEWAY_RESOURCE_ID = '/subscriptions/00000000-0000-4000-8000-000000000001/resourceGroups/rg-p94/providers/Microsoft.Storage/storageAccounts/stp94' }; Names = 'PROJECTION_GATEWAY_RESOURCE_ID' }
        )) {
        $settings = $goodSettings.Clone()
        foreach ($key in $case.Change.Keys) { if ($null -eq $case.Change[$key]) { $settings.Remove($key) } else { $settings[$key] = $case.Change[$key] } }
        $verdict = try { $null = Assert-ClaudeProjectionJobDefinition -Job (New-JobDefinition $settings) -ImageDigest $digest; 'accepted' } catch { $_.Exception.Message }
        Assert "admission refuses a job with $($case.Name)" ($verdict -ne 'accepted' -and $verdict -match [regex]::Escape($case.Names) -and $verdict -match 'Remedy') "$verdict"
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection renewal templates and deploy script hold.' -ForegroundColor Green
exit 0
