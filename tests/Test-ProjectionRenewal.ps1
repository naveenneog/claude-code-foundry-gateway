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

    # Container Apps names are 2-32 characters (U118); a projection prefix can be 37. Each name is a
    # literal start plus uniqueString's 13 characters, so its length does not depend on the prefix.
    foreach ($variable in 'jobName', 'environmentName') {
        $m = [regex]::Match($rb, "(?m)^var $variable = '([a-z][a-z0-9-]*-)\$\{uniqueString\(resourceGroup\(\)\.id, namePrefix\)\}'\s*$")
        Assert "the $variable is a short literal and a 13-character hash" ($m.Success -and ($m.Groups[1].Value.Length + 13) -le 32) ([regex]::Match($rb, "(?m)^var $variable = .*$").Value)
    }
    foreach ($template in @($renewalTemplate, $registry) | Where-Object { $_ }) {
        Assert 'the templates accept every projection prefix, 1 to 37 characters' ($template.parameters.namePrefix.minLength -eq 1 -and $template.parameters.namePrefix.maxLength -eq 37) "min $($template.parameters.namePrefix.minLength) max $($template.parameters.namePrefix.maxLength)"
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
        Assert 'there are failed-run and Graph-read-denied alerts by default' ((($definitions | ForEach-Object name) -join ',') -eq 'graph-read-denied,renewal-failed') (($definitions | ForEach-Object name) -join ',')
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
            $expected = if ($definition.name -in 'renewal-failed','graph-read-denied') { $failedEvent } else { $succeeded }
            Assert "$($definition.name): it matches the job's $expected line" ($expected -and $query.Contains("'`"event`":`"$expected`"'")) $query
        }
        Assert 'the expiry-margin alert is removed because records persist until sync changes them' (-not (($definitions | ForEach-Object name) -contains 'expiry-margin-60m')) (($definitions | ForEach-Object name) -join ',')
        Assert 'the stale-success alert is conditional on a schedule' ([IO.File]::ReadAllText((Join-Path $root 'infra\projection-renewal.bicep')) -match "resource noSuccessAlert 'Microsoft\.Insights/scheduledQueryRules@2023-12-01' = if \(isScheduled\)" -and $renewalTemplate.parameters.cronExpression.defaultValue -eq '')
    }

    Write-Host ''
    Write-Host 'Projection renewal - the deploy script runs the three phases in order' -ForegroundColor Cyan
    $deployScript = Join-Path $root 'scripts\Deploy-ClaudeProjectionRenewal.ps1'
    $sub = '00000000-0000-4000-8000-000000000001'
    $tenant = '00000000-0000-4000-8000-000000000094'
    $rgId = "/subscriptions/$sub/resourceGroups/rg-p94"
    $subnet = "$rgId/providers/Microsoft.Network/virtualNetworks/vnet-p94fixture/subnets/renewal"
    $workspace = "$rgId/providers/Microsoft.OperationalInsights/workspaces/law-p94"
    $standard = '10000000-0000-4000-8000-000000000001'
    $premium = '10000000-0000-4000-8000-000000000002'
    $digestBuilt = 'sha256:' + ('d' * 64)
    $global:P94Stub = @{ Case = ''; Calls = $null; Params = $null; RenewalAttempts = 0 }
    # Group names resolve through Graph with Invoke-RestMethod (scripts/ClaudeGraphMembership.ps1).
    $global:P94Graph = @{ Calls = $null; Refuse = $false; Groups = @{ 'claude-code-standard' = 'ABCDEF00-0000-4000-8000-000000000011'; 'claude-code-premium' = '20000000-0000-4000-8000-000000000012'; 'claude-code-everyone' = 'abcdef00-0000-4000-8000-000000000011' } }
    function global:Invoke-RestMethod {
        [CmdletBinding()]
        param([string]$Uri, [hashtable]$Headers, [string]$Method, [int]$TimeoutSec)
        $graph = $global:P94Graph
        $graph.Calls.Add($Uri)
        if ($graph.Refuse) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
        $filter = [uri]::UnescapeDataString((($Uri -split '\$filter=', 2)[1] -split '&')[0])
        $id = if ($filter -match "^displayName eq '(.+)'$") { $graph.Groups[$Matches[1]] }
        return [pscustomobject]@{ value = @(if ($id) { [pscustomobject]@{ id = $id } }) }
    }
    function global:az {
        $words = @($args | ForEach-Object { [string]$_ })
        $line = $words -join ' '
        $state = $global:P94Stub
        $state.Calls.Add($line)
        $global:LASTEXITCODE = 0
        $fileIndex = [Array]::IndexOf($words, '--parameters')
        if ($line -match '^deployment group create' -and $fileIndex -ge 0) {
            $name = $words[[Array]::IndexOf($words, '-n') + 1]
            $state.Params[$name] = Get-Content -LiteralPath $words[$fileIndex + 1].TrimStart('@') -Raw | ConvertFrom-Json -AsHashtable
            if ($name -like 'projection-renewal-*' -and $state.Case -eq 'renewal-fails-once' -and $state.RenewalAttempts++ -eq 0) {
                $global:LASTEXITCODE = 1; return 'ERROR: (InvalidParameterValueInContainerTemplate) image pull unauthorized'
            }
            return
        }
        $outputs = {
            param($values)
            $o = [ordered]@{}; foreach ($k in $values.Keys) { $o[$k] = @{ value = $values[$k] } }; $o | ConvertTo-Json -Depth 5
        }
        switch -Regex ($line) {
            '^account show' { return (@{ id = $sub; tenantId = $tenant } | ConvertTo-Json) }
            '^account get-access-token' { return (@{ accessToken = 'graph-token' } | ConvertTo-Json) }
            '^deployment group show .*-n projection-p94fixture ' { return (& $outputs @{ accountName = 'cosmos-p94fixture' }) }
            '^deployment group show .*-n projection-network-p94fixture ' {
                $renewalOutput = switch ($state.Case) { 'no-renewal-subnet' { '' } 'odd-subnet-output' { "/subscriptions/$sub/resourceGroups/rg(net)/providers/Microsoft.Network/virtualNetworks/vnet-p94fixture/subnets/renewal" } default { $subnet } }
                return (& $outputs @{ renewalSubnetId = $renewalOutput; runnerName = 'aci-projtest-p94fixture' })
            }
            '^deployment group show .*-n projection-registry-p94fixture ' {
                return (& $outputs @{ acrName = $(if ($state.Case -eq 'bad-acr-name') { 'acr(p94)' } else { 'acrp94fixture' }); acrLoginServer = 'acrp94fixture.azurecr.io'; identityName = 'id-projection-renewal-p94fixture'; identityClientId = '40000000-0000-4000-8000-000000000001'; identityPrincipalId = '40000000-0000-4000-8000-000000000002' })
            }
            '^deployment group show .*-n projection-renewal-p94fixture ' {
                return (& $outputs @{ jobName = 'caj-renew-p94'; jobResourceId = "$rgId/providers/Microsoft.App/jobs/caj-renew-p94"; actionGroupResourceId = "$rgId/providers/Microsoft.Insights/actionGroups/ag-projection-renewal-p94fixture" })
            }
            '^network vnet show' { return (@{ location = 'eastus2' } | ConvertTo-Json) }
            '^resource list -g rg-p94 ' {
                # Names P94 shares with P86 are updated in place; the three P94 renamed are refused,
                # by name and type: resource names are unique per type only.
                $items = @(
                    @{ name = 'cosmos-p94fixture'; type = 'Microsoft.DocumentDB/databaseAccounts' }, @{ name = 'acrp94fixture'; type = 'Microsoft.ContainerRegistry/registries' }
                    @{ name = 'id-projection-renewal-p94fixture'; type = 'Microsoft.ManagedIdentity/userAssignedIdentities' }, @{ name = 'ag-projection-renewal-p94fixture'; type = 'microsoft.insights/actiongroups' }
                    @{ name = 'sqr-projection-p94fixture-no-success-45m'; type = 'microsoft.insights/scheduledqueryrules' }
                )
                if ($state.Case -eq 'p86-leftovers') {
                    $items += @(@{ name = 'caj-projection-renewal-p94fixture'; type = 'Microsoft.App/jobs' }, @{ name = 'cae-projection-p94fixture'; type = 'Microsoft.App/managedEnvironments' }, @{ name = 'sqr-projection-p94fixture-graph-read-failed'; type = 'microsoft.insights/scheduledqueryrules' })
                }
                if ($state.Case -eq 'p86-name-other-type') { $items += @{ name = 'cae-projection-p94fixture'; type = 'Microsoft.Network/networkSecurityGroups' } }
                return (ConvertTo-Json @($items))
            }
            '^apim show' { return (@{ id = "$rgId/providers/Microsoft.ApiManagement/service/apim-p94" } | ConvertTo-Json) }
            '^acr build' { if ($state.Case -eq 'tasks-refused') { $global:LASTEXITCODE = 1; return 'ERROR: (TasksOperationsNotAllowed) ACR Tasks requests are not permitted.' }; return }
            '^acr manifest show-metadata' { return (ConvertTo-Json $(if ($state.Case -eq 'bad-digest') { 'latest' } else { $digestBuilt })) }
        }
        $global:LASTEXITCODE = 9
        return "stub az has no answer for: $line"
    }
    function Invoke-DeployScenario([string]$Case = 'healthy', [hashtable]$Change = @{}) {
        $global:P94Stub.Case = $Case
        $global:P94Stub.Calls = [Collections.Generic.List[string]]::new()
        $global:P94Stub.Params = @{}
        $global:P94Stub.RenewalAttempts = 0
        $global:P94Graph.Calls = [Collections.Generic.List[string]]::new()
        $global:P94Graph.Refuse = ($Case -eq 'graph-refused')
        $receiptPath = Join-Path $work ('receipt-' + [guid]::NewGuid().ToString('N') + '.json')
        $params = @{
            ResourceGroup = 'rg-p94'; ApimName = 'apim-p94'; NamePrefix = 'p94fixture'; AlertEmail = @('ops@example.invalid', 'oncall@example.invalid')
            StandardGroup = $standard; PremiumGroup = $premium; WorkspaceResourceId = $workspace; ReceiptPath = $receiptPath
            RetryDelaySeconds = 0; ImageTag = 'sync-test'
        }
        foreach ($key in $Change.Keys) { if ($null -eq $Change[$key]) { $params.Remove($key) } else { $params[$key] = $Change[$key] } }
        $failure = $null
        $all = @()
        try { $all = @(& $deployScript @params *>&1) } catch { $failure = $_.Exception.Message }
        [pscustomobject]@{
            Failure = $failure; Output = ($all | Out-String); Calls = @($global:P94Stub.Calls); Params = $global:P94Stub.Params; GraphCalls = @($global:P94Graph.Calls)
            Receipt = $(if (Test-Path -LiteralPath $receiptPath) { Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json } else { $null })
        }
    }
    function Get-CallIndex($Run, [string]$Pattern) {
        for ($i = 0; $i -lt $Run.Calls.Count; $i++) { if ($Run.Calls[$i] -match $Pattern) { return $i } }
        return -1
    }
    function Get-WriteCount($Run) { @($Run.Calls | Where-Object { $_ -match '^(deployment group create|acr build)' }).Count }

    $run = Invoke-DeployScenario
    $registryAt = Get-CallIndex $run '^deployment group create .*-n projection-registry-p94fixture '
    $buildAt = Get-CallIndex $run '^acr build '
    $digestAt = Get-CallIndex $run '^acr manifest show-metadata '
    $renewalAt = Get-CallIndex $run '^deployment group create .*-n projection-renewal-p94fixture '
    Assert 'a healthy run completes' (-not $run.Failure) $run.Failure
    Assert 'each deployment is named for its template and the prefix' ((@($run.Params.Keys) | Sort-Object) -join ',' -eq 'projection-registry-p94fixture,projection-renewal-p94fixture') (@($run.Params.Keys) -join ',')
    Assert 'registry, then build, then digest, then the job' ($registryAt -ge 0 -and $registryAt -lt $buildAt -and $buildAt -lt $digestAt -and $digestAt -lt $renewalAt) ($run.Calls -join ' | ')
    Assert 'the image builds from the sync package with the image Dockerfile' ($run.Calls[$buildAt] -match '--registry acrp94fixture --image claude-projection-sync:sync-test --file sync/Dockerfile --no-logs ')
    $renewalParams = $run.Params['projection-renewal-p94fixture']
    $value = { param($name) if ($renewalParams -and $renewalParams.parameters.Contains($name)) { $renewalParams.parameters[$name].value } }
    Assert 'the job is pinned to the digest the registry reported' ((& $value 'syncImageDigest') -ceq $digestBuilt) (& $value 'syncImageDigest')
    Assert 'the job runs on the renewal subnet' ((& $value 'containerAppsSubnetId') -eq $subnet)
    Assert 'its logs go to the given workspace' ((& $value 'logAnalyticsWorkspaceId') -eq $workspace)
    Assert 'the alert addresses go to the action group' (((& $value 'actionGroupEmailReceivers') -join ',') -eq 'ops@example.invalid,oncall@example.invalid')
    Assert 'the job uses the registry and identity from phase 1' ((& $value 'acrName') -eq 'acrp94fixture' -and (& $value 'identityName') -eq 'id-projection-renewal-p94fixture')
    Assert 'the job gets the tier group ids and the gateway' ((& $value 'standardGroupId') -eq $standard -and (& $value 'premiumGroupId') -eq $premium -and (& $value 'gatewayResourceId') -match 'Microsoft\.ApiManagement/service/apim-p94$')
    Assert 'the job deploys in the network region and the signed-in tenant' ((& $value 'location') -eq 'eastus2' -and (& $value 'tenantId') -eq $tenant)
    Assert 'the tenant administrator step names the job identity' ($run.Output -match 'Grant-ClaudeProjectionRenewalGraphAccess\.ps1 -PrincipalId 40000000-0000-4000-8000-000000000002')
    Assert 'the output names optional on-demand operation without admission-wait text' ($run.Output -match 'optional sync job' -and $run.Output -match 'az containerapp job start' -and $run.Output -notmatch '60-90 minutes|three successful runs')
    $receipt = $run.Receipt
    Assert 'the receipt records what the switch needs' ($receipt -and $receipt.kind -eq 'claude-projection-renewal-receipt' -and $receipt.reconcilerResourceId -match '/Microsoft\.App/jobs/caj-renew-p94$' -and
        $receipt.imageDigest -ceq $digestBuilt -and $receipt.runnerName -eq 'aci-projtest-p94fixture' -and $receipt.cosmosAccount -eq 'cosmos-p94fixture' -and
        $receipt.accountResourceId -match '/databaseAccounts/cosmos-p94fixture$' -and $receipt.tenantId -eq $tenant -and $receipt.entryPoint -eq 'node /app/sync/src/apply-projection.mjs' -and
        $receipt.actionGroupResourceId -match '/actionGroups/')
    Assert 'the receipt records the settings the job runs with' ($receipt -and $receipt.standardGroupId -ceq $standard -and $receipt.premiumGroupId -ceq $premium -and
        $receipt.gatewayResourceId -match 'Microsoft\.ApiManagement/service/apim-p94$' -and $receipt.identityClientId -eq '40000000-0000-4000-8000-000000000001') ($receipt | ConvertTo-Json -Compress)
    Assert 'the receipt records a manual trigger by default' ($receipt -and $receipt.triggerType -eq 'Manual' -and $receipt.cronExpression -eq '') ($receipt | ConvertTo-Json -Compress)
    Assert 'the receipt holds no secret' ($receipt -and -not (($receipt | ConvertTo-Json) -match '(?i)token|password|secret|key"'))
    Assert 'no Graph call when both groups are object ids' (-not ($run.Calls -match 'get-access-token'))

    foreach ($case in @(
            @{ Name = 'an alert address with a command separator'; Change = @{ AlertEmail = @('ops@example.invalid&calc') }; Expect = 'AlertEmail' }
            @{ Name = 'no alert address'; Change = @{ AlertEmail = @(' ') }; Expect = 'AlertEmail' }
            @{ Name = 'a resource group with cmd metacharacters'; Change = @{ ResourceGroup = 'rg&echo' }; Expect = 'ResourceGroup' }
            @{ Name = 'a prefix the projection deployer refuses'; Change = @{ NamePrefix = 'P94_Fixture' }; Expect = 'NamePrefix' }
            @{ Name = 'a malformed digest'; Change = @{ ImageDigest = 'sha256:abc' }; Expect = 'ImageDigest' }
            @{ Name = 'a cron with a separator'; Change = @{ CronExpression = '*/30 * * * *;' }; Expect = 'CronExpression' }
            @{ Name = 'no standard group'; Change = @{ StandardGroup = 'none' }; Expect = 'StandardGroup' }
            @{ Name = 'the standard group as the premium group'; Change = @{ PremiumGroup = $standard.ToUpperInvariant() }; Expect = 'PremiumGroup' }
            @{ Name = 'a subnet id with parentheses, which cmd.exe re-reads'; Change = @{ RenewalSubnetId = "/subscriptions/$sub/resourceGroups/rg(p94)/providers/Microsoft.Network/virtualNetworks/vnet-p94fixture/subnets/renewal" }; Expect = 'RenewalSubnetId' }
        )) {
        $refused = Invoke-DeployScenario 'healthy' $case.Change
        Assert "refused before any Azure call: $($case.Name)" ($refused.Failure -match 'before any Azure call' -and $refused.Failure -match $case.Expect -and $refused.Calls.Count -eq 0) "$($refused.Failure) | calls $($refused.Calls.Count)"
    }
    # As an operator runs it: PowerShell's default view of an uncaught throw adds the script path and
    # a code excerpt and folds the message onto one line.
    $operatorView = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $deployScript -ResourceGroup 'rg&echo' -ApimName 'apim-p94' -NamePrefix 'p94fixture' -AlertEmail 'ops@example.invalid&calc' 2>&1 | Out-String -Width 400
    $operatorCode = $LASTEXITCODE
    Assert 'an operator sees each refused value on its own line, with no script path or code excerpt' ($operatorCode -eq 1 -and
        $operatorView -match "(?m)^\s+- -ResourceGroup 'rg&echo' is not 1-90 letters" -and $operatorView -match "(?m)^\s+- -AlertEmail 'ops@example\.invalid&calc' is not an email address\.\s*$" -and
        $operatorView -notmatch 'Deploy-ClaudeProjectionRenewal\.ps1:\d' -and $operatorView -notmatch '(?m)^\s*Line \|') "exit $operatorCode | $operatorView"
    $noSubnet = Invoke-DeployScenario 'no-renewal-subnet'
    Assert 'a network without the renewal subnet stops before any write, with the remedy' ($noSubnet.Failure -match 'no renewal subnet' -and $noSubnet.Failure -match 'Deploy-ClaudeProjection\.ps1' -and (Get-WriteCount $noSubnet) -eq 0) $noSubnet.Failure
    $leftovers = Invoke-DeployScenario 'p86-leftovers'
    Assert 'P86 resources that the new names would leave behind stop the deploy before any write, with the delete commands' ((Get-WriteCount $leftovers) -eq 0 -and
        $leftovers.Failure -match 'az resource delete -g rg-p94 -n caj-projection-renewal-p94fixture --resource-type Microsoft\.App/jobs' -and
        $leftovers.Failure -match 'az resource delete -g rg-p94 -n cae-projection-p94fixture --resource-type Microsoft\.App/managedEnvironments' -and
        $leftovers.Failure -match 'az resource delete -g rg-p94 -n sqr-projection-p94fixture-graph-read-failed --resource-type Microsoft\.Insights/scheduledQueryRules' -and
        $leftovers.Failure.IndexOf('Microsoft.App/jobs') -lt $leftovers.Failure.IndexOf('Microsoft.App/managedEnvironments')) "$($leftovers.Failure) | writes $(Get-WriteCount $leftovers)"
    $otherType = Invoke-DeployScenario 'p86-name-other-type'
    Assert 'a resource with a P86 name but another type does not stop the deploy' (-not $otherType.Failure -and (Get-WriteCount $otherType) -gt 0) $otherType.Failure
    $oddSubnet = Invoke-DeployScenario 'odd-subnet-output'
    Assert 'a renewal subnet from the network output is checked like -RenewalSubnetId before it reaches az' ($oddSubnet.Failure -match 'returned renewal subnet' -and $oddSubnet.Failure -match 'docs/AZ-COMMANDS\.md' -and
        (Get-CallIndex $oddSubnet '^network vnet show') -lt 0 -and (Get-WriteCount $oddSubnet) -eq 0) "$($oddSubnet.Failure) | writes $(Get-WriteCount $oddSubnet)"
    $tasks = Invoke-DeployScenario 'tasks-refused'
    Assert 'a refused registry build stops before the job, naming the docker path' ($tasks.Failure -match 'TasksOperationsNotAllowed' -and $tasks.Failure -match 'docker build' -and $tasks.Failure -match '-ImageDigest' -and (Get-CallIndex $tasks '^deployment group create .*projection-renewal') -lt 0) $tasks.Failure
    $badDigest = Invoke-DeployScenario 'bad-digest'
    Assert 'a digest that is not sha256 stops before the job' ($badDigest.Failure -match 'not a sha256 digest' -and (Get-CallIndex $badDigest '^deployment group create .*projection-renewal') -lt 0) $badDigest.Failure
    $given = Invoke-DeployScenario 'healthy' @{ ImageDigest = 'sha256:' + ('e' * 64) }
    Assert 'a given digest skips the build and pins the job to it' (-not $given.Failure -and (Get-CallIndex $given '^acr build') -lt 0 -and $given.Params['projection-renewal-p94fixture'].parameters.syncImageDigest.value -ceq ('sha256:' + ('e' * 64))) $given.Failure
    $retry = Invoke-DeployScenario 'renewal-fails-once'
    Assert 'a job deployment that fails once (AcrPull still propagating) is retried' (-not $retry.Failure -and @($retry.Calls -match '^deployment group create .*projection-renewal').Count -eq 2) $retry.Failure
    $whatIf = Invoke-DeployScenario 'healthy' @{ WhatIf = $true }
    Assert 'WhatIf writes nothing and leaves no receipt' (-not $whatIf.Failure -and (Get-WriteCount $whatIf) -eq 0 -and -not $whatIf.Receipt) $whatIf.Failure
    $wrongSubscription = Invoke-DeployScenario 'healthy' @{ SubscriptionId = '00000000-0000-4000-8000-0000000000ff' }
    Assert 'a different signed-in subscription stops before any write' ($wrongSubscription.Failure -match 'az account set' -and (Get-WriteCount $wrongSubscription) -eq 0) $wrongSubscription.Failure
    $byName = Invoke-DeployScenario 'healthy' @{ StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium' }
    $byNameParams = if ($byName.Params['projection-renewal-p94fixture']) { $byName.Params['projection-renewal-p94fixture'].parameters } else { @{} }
    Assert 'group names resolve through Graph to the object ids the job receives' (-not $byName.Failure -and @($byName.GraphCalls).Count -eq 2 -and
        @($byName.Calls -match '^account get-access-token .*https://graph\.microsoft\.com').Count -eq 1 -and
        $byNameParams.standardGroupId.value -ceq 'abcdef00-0000-4000-8000-000000000011' -and $byNameParams.premiumGroupId.value -ceq '20000000-0000-4000-8000-000000000012') "$($byName.Failure) | graph $(@($byName.GraphCalls).Count) | $($byNameParams.standardGroupId.value) $($byNameParams.premiumGroupId.value)"
    $missingGroup = Invoke-DeployScenario 'healthy' @{ StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premim' }
    Assert 'a group name Graph does not find stops before any write, with the remedy' ($missingGroup.Failure -match "premium tier group 'claude-code-premim' was not found" -and $missingGroup.Failure -match '-PremiumGroup none' -and (Get-WriteCount $missingGroup) -eq 0) "$($missingGroup.Failure) | writes $(Get-WriteCount $missingGroup)"
    $graphRefused = Invoke-DeployScenario 'graph-refused' @{ StandardGroup = 'claude-code-standard' }
    Assert 'a refused Graph read stops before any write and is not read as a missing group' ($graphRefused.Failure -match 'Graph read failed' -and $graphRefused.Failure -match '403' -and $graphRefused.Failure -notmatch 'was not found' -and (Get-WriteCount $graphRefused) -eq 0) "$($graphRefused.Failure) | writes $(Get-WriteCount $graphRefused)"
    $sameGroup = Invoke-DeployScenario 'healthy' @{ StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-everyone' }
    Assert 'two names for one group stop before any write: premium would take every standard member' ($sameGroup.Failure -match 'same group' -and (Get-WriteCount $sameGroup) -eq 0) "$($sameGroup.Failure) | writes $(Get-WriteCount $sameGroup)"
    $badAcr = Invoke-DeployScenario 'bad-acr-name'
    Assert 'a registry name that is not a registry name stops before the build' ($badAcr.Failure -match 'not a registry name' -and (Get-CallIndex $badAcr '^acr build') -lt 0 -and (Get-CallIndex $badAcr '^deployment group create .*projection-renewal') -lt 0) $badAcr.Failure
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'Projection renewal - switch evidence no longer depends on the optional job definition' -ForegroundColor Cyan
    $checks = [IO.File]::ReadAllText((Join-Path $root 'scripts\ClaudeProjectionChecks.ps1'))
    $renewalSource = [IO.File]::ReadAllText((Join-Path $root 'infra\projection-renewal.bicep'))
    Assert 'switch admission has no job-definition validator to accept or refuse' ($checks -notmatch 'Assert-ClaudeProjectionJobDefinition') ''
    Assert 'switch admission has no image digest input' ($checks -notmatch 'ImageDigest') ''
    Assert 'switch admission has no action group input' ($checks -notmatch 'ActionGroup') ''
    Assert 'switch admission has no tier group setting input' ($checks -notmatch 'standard-group-id|premium-group-id') ''
    Assert 'switch admission has no gateway-resource-id setting input' ($checks -notmatch 'gateway-resource-id') ''
    Assert 'the optional job still carries AZURE_CLIENT_ID for Graph and not for admission' ($renewalSource -match 'AZURE_CLIENT_ID' -and $checks -notmatch 'AZURE_CLIENT_ID') ''
    Assert 'the optional job still carries tier group settings for graph sync and not for admission' ($renewalSource -match 'PROJECTION_STANDARD_GROUP_ID' -and $renewalSource -match 'PROJECTION_PREMIUM_GROUP_ID' -and $checks -notmatch 'PROJECTION_STANDARD_GROUP_ID|PROJECTION_PREMIUM_GROUP_ID') ''
    Assert 'the optional job still carries gatewayResourceId for unit reads and not for admission' ($renewalSource -match 'PROJECTION_GATEWAY_RESOURCE_ID' -and $checks -notmatch 'PROJECTION_GATEWAY_RESOURCE_ID') ''
    Assert 'the optional job is manual by default while scheduled stale-success evidence stays conditional' ($renewalTemplate.parameters.cronExpression.defaultValue -eq '' -and $renewalSource -match "resource noSuccessAlert 'Microsoft\.Insights/scheduledQueryRules@2023-12-01' = if \(isScheduled\)") ''
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection renewal templates and deploy script hold.' -ForegroundColor Green
exit 0
