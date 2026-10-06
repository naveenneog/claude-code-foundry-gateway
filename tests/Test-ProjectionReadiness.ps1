param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = & $Action }
    catch { $script:CapturedError = $_.Exception.Message }
}
function ConvertTo-JsonText($Value) { return ($Value | ConvertTo-Json -Depth 12 -Compress) }
function New-Ids([int]$Count, [string]$Prefix) {
    $items = @()
    for ($i = 1; $i -le $Count; $i++) { $items += "/id/$Prefix/$i" }
    return $items
}
function New-FakeReadinessAz([hashtable]$Overrides) {
    $global:ReadinessCalls = [Collections.Generic.List[string]]::new()
    return {
        param([string[]]$Arguments)
        $line = $Arguments -join ' '
        $global:ReadinessCalls.Add($line)
        $global:LASTEXITCODE = 0
        foreach ($pattern in $Overrides.Keys) {
            if ($line -like $pattern) {
                $value = $Overrides[$pattern]
                if ($value -is [scriptblock]) { return & $value $line }
                if ($value -is [Exception]) { throw $value.Message }
                return $value
            }
        }
        if ($line -like 'provider show -n Microsoft.DocumentDB*') { return ConvertTo-JsonText @{ resourceTypes = @(@{ resourceType = 'databaseAccounts'; locations = @('East US 2') }) } }
        if ($line -like 'provider show -n Microsoft.ContainerInstance*') { return ConvertTo-JsonText @{ resourceTypes = @(@{ resourceType = 'containerGroups'; locations = @('East US 2') }) } }
        if ($line -like 'provider show -n Microsoft.Network*') { return ConvertTo-JsonText @{ resourceTypes = @(@{ resourceType = 'privateEndpoints'; locations = @('East US 2') }) } }
        if ($line -like 'provider show -n Microsoft.App*') { return ConvertTo-JsonText @{ resourceTypes = @(@{ resourceType = 'managedEnvironments'; locations = @('East US 2') }) } }
        if ($line -like 'functionapp list-flexconsumption-locations*') { return ConvertTo-JsonText @(@{ name = 'East US 2' }) }
        if ($line -like 'rest --method get --url *Microsoft.ContainerInstance*usages*') {
            return ConvertTo-JsonText @{ value = @(
                @{ name = @{ value = 'ContainerGroups' }; currentValue = 99; limit = 100 },
                @{ name = @{ value = 'StandardCores' }; currentValue = 98; limit = 100 }
            ) }
        }
        if ($line -like 'storage account show-usage*') { return ConvertTo-JsonText @{ currentValue = 249; limit = 250 } }
        if ($line -like 'network list-usages*') { return ConvertTo-JsonText @(@{ name = @{ value = 'VirtualNetworks' }; currentValue = '999'; limit = '1000' }) }
        if ($line -like 'cosmosdb list*') { return (New-Ids 249 'cosmos') -join "`n" }
        if ($line -like 'network private-dns zone list*') { return (New-Ids 995 'dns') -join "`n" }
        if ($line -like 'rest --method get --url *Microsoft.App*usages*') { return ConvertTo-JsonText @{ value = @(@{ name = @{ value = 'ManagedEnvironmentCount' }; currentValue = 49; limit = 50 }) } }
        if ($line -like 'rest --method get --url *Microsoft.Authorization/permissions*') { return ConvertTo-JsonText @{ value = @(@{ actions = @('*'); notActions = @() }) } }
        if ($line -like 'deployment group validate*projection.bicep*') { return ConvertTo-JsonText @{ properties = @{ provisioningState = 'Succeeded' } } }
        if ($line -like 'deployment group validate*projection-network.bicep*') { return ConvertTo-JsonText @{ properties = @{ provisioningState = 'Succeeded' } } }
        throw "unexpected az call: $line"
    }.GetNewClosure()
}
function Invoke-Readiness([hashtable]$Overrides, [switch]$IncludeSyncJob, [string]$Prefix = 'proj-p100') {
    $fake = New-FakeReadinessAz $Overrides
    return @(Get-ClaudeProjectionReadiness -SubscriptionId '00000000-0000-4000-8000-000000000100' -ResourceGroup 'rg-p100' -Location 'East US 2' -NamePrefix $Prefix -RepositoryRoot $root -IncludeSyncJob:$IncludeSyncJob -InvokeAz $fake)
}
function Find-Check($Checks, [string]$Name) { return @($Checks | Where-Object Name -eq $Name | Select-Object -First 1)[0] }

. (Join-Path $root 'scripts\ClaudeProjectionReadiness.ps1')

Write-Host 'P100 projection readiness'
Capture { Invoke-Readiness -Overrides @{} -IncludeSyncJob }
$healthy = @($CapturedResult)
Assert 'healthy data returns checks' (-not $CapturedError -and $healthy.Count -gt 10) $CapturedError
Assert 'healthy non-note checks pass' (@($healthy | Where-Object { $_.Result -notin @('PASS','NOTE') }).Count -eq 0) (($healthy | Where-Object { $_.Result -ne 'PASS' -and $_.Result -ne 'NOTE' } | ConvertTo-Json -Compress))
Assert 'capacity note is present' (@($healthy | Where-Object { $_.Name -eq 'Cosmos regional capacity' -and $_.Result -eq 'NOTE' -and $_.Evidence -match 'U136' }).Count -eq 1)
$preflightText = [IO.File]::ReadAllText((Join-Path $root 'scripts\ClaudeProjectionChecks.ps1'))
Assert 'the capacity note has the projection preflight''s name, so a plan that merges both lists it once' ($preflightText -match "Check='Cosmos regional capacity'; Result='NOTE'")
Assert 'storage usage accepts a single object at the pass boundary' ((Find-Check $healthy 'Usage: storage accounts').Result -eq 'PASS')
Assert 'network usage casts string values at the pass boundary' ((Find-Check $healthy 'Usage: virtual networks').Result -eq 'PASS')
Assert 'IncludeSyncJob adds Container Apps region and usage checks' (@($healthy | Where-Object { $_.Name -like '*Container Apps*' }).Count -eq 2)
$calls = @($global:ReadinessCalls)
Assert 'no az argument contains cmd metacharacters' (-not (($calls -join "`n") -match '[()|&<>^]')) (($calls -join ' | '))
Assert 'every az call carries subscription' (@($calls | Where-Object { $_ -notmatch '--subscription 00000000-0000-4000-8000-000000000100' }).Count -eq 0) (($calls | Where-Object { $_ -notmatch '--subscription' }) -join ' | ')

$regionCases = @(
    @('Region: Cosmos DB accounts', 'provider show -n Microsoft.DocumentDB*', @{ resourceTypes = @(@{ resourceType = 'databaseAccounts'; locations = @('West US') }) }),
    @('Region: container groups', 'provider show -n Microsoft.ContainerInstance*', @{ resourceTypes = @(@{ resourceType = 'containerGroups'; locations = @('West US') }) }),
    @('Region: private endpoints', 'provider show -n Microsoft.Network*', @{ resourceTypes = @(@{ resourceType = 'privateEndpoints'; locations = @('West US') }) }),
    @('Region: Flex Consumption', 'functionapp list-flexconsumption-locations*', @(@{ name = 'West US' })),
    @('Region: Container Apps environments', 'provider show -n Microsoft.App*', @{ resourceTypes = @(@{ resourceType = 'managedEnvironments'; locations = @('West US') }) })
)
foreach ($case in $regionCases) {
    $over = @{}; $over[$case[1]] = ConvertTo-JsonText $case[2]
    Capture { Invoke-Readiness -Overrides $over -IncludeSyncJob }
    $check = Find-Check $CapturedResult $case[0]
    Assert "$($case[0]) fails when the region is absent" ($check.Result -eq 'FAIL' -and $check.Remedy -match 'choose a region') ($check | ConvertTo-Json -Compress)
}

$usageCases = @(
    @('Usage: container groups', 'rest --method get --url *Microsoft.ContainerInstance*usages*', @{ value = @(@{ name = @{ value = 'ContainerGroups' }; currentValue = 100; limit = 100 }, @{ name = @{ value = 'StandardCores' }; currentValue = 98; limit = 100 }) }),
    @('Usage: container cores', 'rest --method get --url *Microsoft.ContainerInstance*usages*', @{ value = @(@{ name = @{ value = 'ContainerGroups' }; currentValue = 99; limit = 100 }, @{ name = @{ value = 'StandardCores' }; currentValue = 99; limit = 100 }) }),
    @('Usage: storage accounts', 'storage account show-usage*', @{ currentValue = 250; limit = 250 }),
    @('Usage: virtual networks', 'network list-usages*', @(@{ name = @{ value = 'VirtualNetworks' }; currentValue = '1000'; limit = '1000' })) ,
    @('Usage: Cosmos DB accounts', 'cosmosdb list*', ((New-Ids 250 'cosmos') -join "`n")),
    @('Usage: private DNS zones', 'network private-dns zone list*', ((New-Ids 996 'dns') -join "`n")),
    @('Usage: Container Apps environments', 'rest --method get --url *Microsoft.App*usages*', @{ value = @(@{ name = @{ value = 'ManagedEnvironmentCount' }; currentValue = 50; limit = 50 }) })
)
foreach ($case in $usageCases) {
    $over = @{}; $over[$case[1]] = if ($case[2] -is [string]) { $case[2] } else { ConvertTo-JsonText $case[2] }
    Capture { Invoke-Readiness -Overrides $over -IncludeSyncJob }
    $check = Find-Check $CapturedResult $case[0]
    Assert "$($case[0]) fails one over the boundary" ($check.Result -eq 'FAIL' -and $check.Remedy -match 'quota increase') ($check | ConvertTo-Json -Compress)
}

$warnCases = @(
    @('Region: Cosmos DB accounts', 'provider show -n Microsoft.DocumentDB*', { $global:LASTEXITCODE = 1; 'provider read failed' }),
    @('Region: Flex Consumption', 'functionapp list-flexconsumption-locations*', { $global:LASTEXITCODE = 1; 'flex read failed' }),
    @('Usage: container groups', 'rest --method get --url *Microsoft.ContainerInstance*usages*', { $global:LASTEXITCODE = 1; 'aci usage failed' }),
    @('Usage: storage accounts', 'storage account show-usage*', (ConvertTo-JsonText @(@{ currentValue = 1; limit = 2 }, @{ currentValue = 1; limit = 2 }))) ,
    @('Usage: virtual networks', 'network list-usages*', (ConvertTo-JsonText @(@{ name = @{ value = 'Other' }; currentValue = '1'; limit = '2' }))) ,
    @('Usage: Cosmos DB accounts', 'cosmosdb list*', { $global:LASTEXITCODE = 1; 'cosmos list failed' }),
    @('Usage: private DNS zones', 'network private-dns zone list*', { $global:LASTEXITCODE = 1; 'dns list failed' }),
    @('Usage: Container Apps environments', 'rest --method get --url *Microsoft.App*usages*', (ConvertTo-JsonText @{ value = @() })),
    @('Role assignments write permission', 'rest --method get --url *Microsoft.Authorization/permissions*', { $global:LASTEXITCODE = 1; 'permissions failed' })
)
foreach ($case in $warnCases) {
    $over = @{}; $over[$case[1]] = $case[2]
    Capture { Invoke-Readiness -Overrides $over -IncludeSyncJob }
    $check = Find-Check $CapturedResult $case[0]
    Assert "$($case[0]) warns on read failure or unexpected shape" ($check.Result -eq 'WARN') ($check | ConvertTo-Json -Compress)
}

$roleCases = @(
    @('Owner wildcard passes', @{ value = @(@{ actions = @('*'); notActions = @() }) }, 'PASS'),
    @('Contributor notActions fail', @{ value = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }) }, 'FAIL'),
    @('Contributor plus User Access Administrator passes', @{ value = @(@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Write') }, @{ actions = @('Microsoft.Authorization/roleAssignments/*'); notActions = @() }) }, 'PASS'),
    @('RBAC Administrator exact action passes', @{ value = @(@{ actions = @('Microsoft.Authorization/roleAssignments/write'); notActions = @() }) }, 'PASS')
)
foreach ($case in $roleCases) {
    Capture { Invoke-Readiness -Overrides @{ 'rest --method get --url *Microsoft.Authorization/permissions*' = (ConvertTo-JsonText $case[1]) } }
    $check = Find-Check $CapturedResult 'Role assignments write permission'
    Assert $case[0] ($check.Result -eq $case[2]) ($check | ConvertTo-Json -Compress)
}

$policy = '{"error":{"code":"InvalidTemplateDeployment","message":"The template deployment failed with error: RequestDisallowedByPolicy. policyAssignmentName: denyProjection policyDefinitionName: noPrivateEndpoints"}}'
Capture { Invoke-Readiness -Overrides @{ 'deployment group validate*projection.bicep*' = { $global:LASTEXITCODE = 1; $policy } } }
$policyCheck = Find-Check $CapturedResult 'Template validation: projection'
Assert 'policy denial fails and names the policy' ($policyCheck.Result -eq 'FAIL' -and $policyCheck.Evidence -match 'denyProjection' -and $policyCheck.Evidence -match 'noPrivateEndpoints') ($policyCheck | ConvertTo-Json -Compress)

$otherError = '{"error":{"code":"InvalidTemplate","message":"Parameter value is invalid for this synthetic test."}}'
Capture { Invoke-Readiness -Overrides @{ 'deployment group validate*projection-network.bicep*' = { $global:LASTEXITCODE = 1; $otherError } } }
$warnCheck = Find-Check $CapturedResult 'Template validation: projection network'
Assert 'other validation error warns with first code and message' ($warnCheck.Result -eq 'WARN' -and $warnCheck.Evidence -match 'InvalidTemplate' -and $warnCheck.Evidence.Length -le 300) ($warnCheck | ConvertTo-Json -Compress)

Capture { Invoke-Readiness -Overrides @{} -Prefix 'Bad_Prefix' }
Assert 'invalid prefix throws before any az call' ($CapturedError -match 'NamePrefix' -and $global:ReadinessCalls.Count -eq 0) "$CapturedError calls=$($global:ReadinessCalls.Count)"

Write-Host "P100_READINESS assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))





