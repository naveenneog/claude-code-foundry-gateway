# Discover live resource choices. The output contains deployment identifiers and
# belongs only in the ignored capture workspace, never in a commit.
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ApimName,
    [int]$GatewayIndex = 0,
    [switch]$NonInteractive,
    [switch]$Quiet,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $root '.shots-entra\architecture-live\plan.json' }
$privateRoot = [IO.Path]::GetFullPath((Join-Path $root '.shots-entra\architecture-live')) + [IO.Path]::DirectorySeparatorChar
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (-not $OutputPath.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Capture plans contain deployment identities. Keep OutputPath inside the ignored .shots-entra\architecture-live directory.'
}
if (-not $ResourceGroup) { $ResourceGroup = & (Join-Path $root 'scripts/Get-ClaudeGatewayTarget.ps1') ResourceGroup 3>$null }
if (-not $ApimName) { $ApimName = & (Join-Path $root 'scripts/Get-ClaudeGatewayTarget.ps1') ApimName 3>$null }

function Read-AzureJson {
    param([string[]]$Arguments)
    $raw = & az @Arguments -o json 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Azure discovery failed: $($Arguments[0]) $($Arguments[1]). No selection was guessed." }
    return $raw | ConvertFrom-Json
}

function Select-Discovered {
    param([object[]]$Items, [string]$Label, [string]$Field, [string]$Preferred, [int]$Index = 0)
    if (-not $Items.Count) { throw "No $Label was discovered." }
    $default = 1
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].isDefault) { $default = $i + 1 }
        if ([string]$Items[$i].$Field -eq $Preferred) { $default = $i + 1 }
        $display = if ($Field -eq 'id' -and $Items[$i].name) { "$($Items[$i].name) ($($Items[$i].id))" } else { [string]$Items[$i].$Field }
        if (-not $Quiet) { Write-Host ("  [{0}] {1}" -f ($i + 1), $display) }
    }
    if ($Index) {
        if ($Index -lt 1 -or $Index -gt $Items.Count) { throw "$Label selection is outside the discovered list." }
        return $Items[$Index - 1]
    }
    if ($Preferred) {
        $found = @($Items | Where-Object { [string]$_.$Field -eq $Preferred })
        if ($found.Count -eq 1) { return $found[0] }
        throw "The requested $Label was not uniquely discovered."
    }
    if ($Items.Count -eq 1) { return $Items[0] }
    if ($NonInteractive) { throw "Several $Label choices exist. Pass an explicit parameter or index." }
    $choice = Read-Host "Choose $Label [$default]"
    if (-not $choice) { $choice = [string]$default }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $Items.Count) { throw 'Invalid numbered selection.' }
    return $Items[$number - 1]
}

$current = Read-AzureJson @('account','show')
$subscriptions = @(Read-AzureJson @('account','list') | Where-Object state -eq 'Enabled')
# In non-interactive mode the explicitly signed-in current subscription is the
# sensible default; no az account set changes another worktree's global context.
$preferredSubscription = if ($SubscriptionId) { $SubscriptionId } elseif ($NonInteractive) { $current.id } else { '' }
$subscription = Select-Discovered $subscriptions 'subscription id' 'id' $preferredSubscription
$sub = [string]$subscription.id
$resources = @(Read-AzureJson @('resource','list','--subscription',$sub))
$candidates = New-Object 'System.Collections.Generic.List[object]'
$unreadable = 0
foreach ($resource in @($resources | Where-Object type -eq 'Microsoft.ApiManagement/service')) {
    if ($ResourceGroup -and $resource.resourceGroup -ne $ResourceGroup) { continue }
    try { $values = @(Read-AzureJson @('apim','nv','list','--subscription',$sub,'-g',$resource.resourceGroup,'--service-name',$resource.name)) }
    catch {
        if ($ApimName -and $resource.name -eq $ApimName) { throw }
        $unreadable++
        continue
    }
    $map = @{}
    foreach ($value in $values) { if (-not $value.secret) { $map[$value.name] = [string]$value.value } }
    if ($map.ContainsKey('entitlement-source') -and $map.ContainsKey('quota-org')) {
        $candidates.Add([pscustomobject]@{ name = $resource.name; resource = $resource; values = $map })
    }
}
if ($unreadable) { Write-Warning "$unreadable APIM instance(s) could not be inspected and are not offered as capture targets." }
$gateway = Select-Discovered ($candidates.ToArray()) 'configured gateway' 'name' $ApimName $GatewayIndex
$group = [string]$gateway.resource.resourceGroup
$pages = New-Object 'System.Collections.Generic.List[object]'
$replacements = New-Object 'System.Collections.Generic.List[object]'
foreach ($key in @('allow-standard','allow-premium','bu-members','bu-registry','bu-parents','quota-overrides',
    'turnstile-integration','tenant-id','entitlement-resolver-url','entitlement-resolver-audience')) {
    if ($gateway.values[$key] -and $gateway.values[$key].Length -gt 2) {
        $replacements.Add(@{from=[string]$gateway.values[$key];to='[configuration redacted]'})
    }
}
$serial = @{}
foreach ($r in $resources) {
    $type = [string]$r.type
    if (-not $serial.ContainsKey($type)) { $serial[$type] = 0 }
    $serial[$type]++
    $prefix = switch -Regex ($type) {
        'ApiManagement/service$' { 'apim'; break }
        'CognitiveServices/accounts$' { 'foundry'; break }
        'OperationalInsights/workspaces$' { 'workspace'; break }
        'Microsoft.Web/sites$' { 'app'; break }
        'virtualNetworks$' { 'vnet'; break }
        'privateEndpoints$' { 'pe'; break }
        'storageAccounts$' { 'storage'; break }
        'Microsoft.App/jobs$' { 'job'; break }
        'DocumentDB/databaseAccounts$' { 'cosmos'; break }
        default { 'resource' }
    }
    if ($r.name.Length -gt 5 -and $r.name -notmatch '^privatelink\.') {
        $replacements.Add(@{from=[string]$r.name;to=("$prefix-contoso-" + $serial[$type])})
    }
    if ($r.resourceGroup) { $replacements.Add(@{from=[string]$r.resourceGroup;to='rg-contoso'}) }
}
$replacements.Add(@{from=[string]$subscription.name;to='Contoso subscription'})
if ($subscription.tenantDisplayName) { $replacements.Add(@{from=[string]$subscription.tenantDisplayName;to='Contoso tenant'}) }
foreach ($vnet in @(Read-AzureJson @('network','vnet','list','--subscription',$sub))) {
    $alias = @($replacements | Where-Object { $_.from -eq $vnet.name } | Select-Object -First 1)[0].to
    if (-not $alias) { $alias = 'vnet-contoso' }
    $number = 0
    foreach ($subnet in $vnet.subnets) {
        $number++
        $replacements.Add(@{from=("$($vnet.name)/$($subnet.name)");to=("$alias/subnet-contoso-$number")})
    }
}
try {
    $person = Read-AzureJson @('ad','signed-in-user','show')
    if ($person.displayName) { $replacements.Add(@{from=[string]$person.displayName;to='Contoso administrator'}) }
    if ($person.userPrincipalName) { $replacements.Add(@{from=[string]$person.userPrincipalName;to='administrator@contoso.com'}) }
} catch { Write-Warning 'Directory display name unavailable; the capture also masks the entire account chip.' }

function Add-PortalPage {
    param([string]$Id, [string]$Title, $Resource, [string]$Blade = 'overview', [string]$Expect = 'Overview', [string]$Menu = '')
    if (-not $Resource) { return }
    $ready = switch ($Id) {
        'gateway-identity' { 'System assigned'; break }
        'gateway-named-values' { 'allow-standard'; break }
        'gateway-apis' { 'Add API'; break }
        'foundry-access' { 'Role assignments'; break }
        'telemetry-tables' { 'AppTraces'; break }
        'resolver-authentication' { 'Identity provider'; break }
        'resolver-networking' { 'Inbound traffic'; break }
        'projection-networking' { 'Public network access'; break }
        'reports-networking' { 'Public network access'; break }
        default { if ($Menu -eq 'Execution history') { 'Status' } else { 'Essentials' } }
    }
    $pages.Add([ordered]@{id=$Id;title=$Title;resourceId=[string]$Resource.id;resourceName=[string]$Resource.name;blade=$Blade;expect=$Expect;ready=$ready;menu=$Menu})
}
function Find-Resource([string]$Id) {
    return @($resources | Where-Object id -eq $Id | Select-Object -First 1)[0]
}

Add-PortalPage 'gateway-overview' '1. Gateway overview and v2 tier' $gateway.resource
Add-PortalPage 'gateway-identity' '2. Gateway managed identity' $gateway.resource 'overview' 'System assigned' 'Managed identities'
Add-PortalPage 'gateway-named-values' '3. Entitlement and budget named values' $gateway.resource 'overview' 'Named values' 'Named values'
Add-PortalPage 'gateway-apis' '4. The governed API and policy entry point' $gateway.resource 'overview' 'APIs' 'APIs'
$apis = @(Read-AzureJson @('apim','api','list','--subscription',$sub,'-g',$group,'--service-name',$gateway.name))
$api = @($apis | Where-Object { $_.serviceUrl -match 'anthropic' } | Select-Object -First 1)[0]
if ($api) {
    $hostName = ([uri]$api.serviceUrl).Host
    $foundry = @($resources | Where-Object { $_.type -eq 'Microsoft.CognitiveServices/accounts' -and $hostName.StartsWith(([string]$_.name + '.'), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
    Add-PortalPage 'foundry-overview' '5. Customer-owned Foundry account' $foundry
    Add-PortalPage 'foundry-access' '6. Foundry access control boundary' $foundry 'users' 'Access control'
}
$diagnostic = $null
if ($api) {
    try { $diagnostic = Read-AzureJson @('rest','--method','get','--url',("https://management.azure.com" + $api.id + '/diagnostics/applicationinsights?api-version=2024-05-01'),'--subscription',$sub) }
    catch { $diagnostic = $null }
}
if (-not $diagnostic.properties.loggerId) {
    $diagnostic = Read-AzureJson @('rest','--method','get','--url',("https://management.azure.com" + $gateway.resource.id + '/diagnostics/applicationinsights?api-version=2024-05-01'),'--subscription',$sub)
}
$logger = Read-AzureJson @('rest','--method','get','--url',("https://management.azure.com" + $diagnostic.properties.loggerId + '?api-version=2024-05-01'),'--subscription',$sub)
$workspaceId = ''
if ($logger.properties.resourceId) {
    $insights = Read-AzureJson @('resource','show','--ids',$logger.properties.resourceId,'--api-version','2020-02-02','--subscription',$sub)
    $workspaceId = [string]$insights.properties.WorkspaceResourceId
    Add-PortalPage 'telemetry-workspace' '7. Log Analytics telemetry workspace' (Find-Resource $workspaceId)
    Add-PortalPage 'telemetry-tables' '8. Request and attribution tables' (Find-Resource $workspaceId) 'tables' 'Tables'
}

$projection = @($candidates | Where-Object { $_.values['entitlement-source'] -eq 'projection' })
if ($projection.Count -eq 1) {
    $resolverAppId = [regex]::Match([string]$projection[0].values['entitlement-resolver-audience'], '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
    if ($resolverAppId) {
        try {
            $resolverApp = Read-AzureJson @('ad','app','show','--id',$resolverAppId)
            $replacements.Add(@{from=[string]$resolverApp.displayName;to='Contoso resolver'})
        } catch { Write-Warning 'Resolver app display name could not be discovered; provider labels are redacted generically.' }
    }
    $resolverHost = ([uri]$projection[0].values['entitlement-resolver-url']).Host
    $resolver = @($resources | Where-Object { $_.type -eq 'Microsoft.Web/sites' -and $resolverHost.StartsWith(([string]$_.name + '.'), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
    Add-PortalPage 'projection-gateway' '9. Projection-enabled gateway' $projection[0].resource
    Add-PortalPage 'resolver-overview' '10. Entitlement resolver Function' $resolver
    Add-PortalPage 'resolver-authentication' '11. Resolver authentication boundary' $resolver 'overview' 'Authentication' 'Authentication'
    Add-PortalPage 'resolver-networking' '12. Resolver private networking' $resolver 'overview' 'Networking' 'Networking'
    if ($resolver) {
        $settings = @(Read-AzureJson @('functionapp','config','appsettings','list','--subscription',$sub,'-g',$resolver.resourceGroup,'-n',$resolver.name))
        $cosmosSetting = @($settings | Where-Object name -eq 'COSMOS_ENDPOINT' | Select-Object -First 1)[0]
        if ($cosmosSetting) {
            $cosmosHost = ([uri]$cosmosSetting.value).Host
            $cosmos = @($resources | Where-Object { $_.type -eq 'Microsoft.DocumentDB/databaseAccounts' -and $cosmosHost.StartsWith(([string]$_.name + '.'), [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)[0]
            Add-PortalPage 'projection-cosmos' '13. Entitlement projection store' $cosmos
            Add-PortalPage 'projection-networking' '14. Cosmos private networking' $cosmos 'overview' 'Networking' 'Networking'
        }
    }
}

$jobs = @($resources | Where-Object type -eq 'Microsoft.App/jobs')
$jobDetails = New-Object 'System.Collections.Generic.List[object]'
foreach ($job in $jobs) {
    $detail = Read-AzureJson @('resource','show','--ids',$job.id,'--api-version','2025-01-01','--subscription',$sub)
    $envMap = @{}
    foreach ($entry in $detail.properties.template.containers[0].env) { $envMap[$entry.name] = [string]$entry.value }
    if ($envMap['CLAUDE_APIM'] -ne $gateway.name) { continue }
    $role = if ($envMap['REPORT_MODE']) { 'reports-' + $envMap['REPORT_MODE'] }
        elseif ($envMap['TURNSTILE_SKIP_EXPORT'] -eq 'true') { 'governance-apply' } else { 'governance-export' }
    Add-PortalPage ($role + '-job') ("15. " + $role + ' job and execution history') $job 'overview' 'Execution history' 'Execution history'
    $jobDetails.Add([pscustomobject]@{role=$role;id=$job.id;name=$job.name;resourceGroup=$job.resourceGroup;identity=$detail.identity;properties=$detail.properties})
    if ($role -eq 'reports-generator') {
        Add-PortalPage 'reports-environment' '16. Dedicated reports Consumption environment' (Find-Resource $detail.properties.environmentId)
        $storage = @($resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' -and $_.name -eq $envMap['REPORT_STORAGE'] } | Select-Object -First 1)[0]
        Add-PortalPage 'reports-storage' '17. Private report archive and configuration' $storage
        Add-PortalPage 'reports-networking' '18. Reports storage network boundary' $storage 'overview' 'Networking' 'Networking'
    }
}

$connection = $null
foreach ($r in @($resources | Where-Object { $_.tags.'claude-chargeback-gateway' -eq $gateway.name })) {
    if ($r.type -eq 'Microsoft.Communication/communicationServices') { Add-PortalPage 'reports-email' '19. Dedicated ACS Email resource' $r }
    if ($r.type -eq 'Microsoft.Communication/emailServices') { Add-PortalPage 'reports-domain' '20. Email service and managed domain' $r }
}
if ($gateway.values['turnstile-integration']) {
    . (Join-Path $root 'scripts/ClaudeTurnstileGovernance.ps1')
    $connection = ConvertFrom-ClaudeTurnstileIntegrationValue $gateway.values['turnstile-integration']
    if ($connection['clientId']) {
        $app = Read-AzureJson @('ad','app','show','--id',$connection['clientId'])
        $replacements.Add(@{from=[string]$app.displayName;to='Contoso Turnstile'})
        $pages.Add([ordered]@{id='turnstile-app-roles';title='21. Delegated console app roles';kind='entra-app';appId=[string]$app.appId;resourceName=[string]$app.displayName;expect='App roles';ready='Turnstile.Admin'})
    }
}
$plan = [ordered]@{
    version=1;tenantId=[string]$subscription.tenantId;subscriptionId=$sub
    pages=$pages.ToArray();replacements=$replacements.ToArray()
    selected=[ordered]@{gateway=$gateway.resource;api=$api;workspaceId=$workspaceId;projection=@($projection);turnstile=$connection;jobs=$jobDetails.ToArray()}
}
$parent = Split-Path ([IO.Path]::GetFullPath($OutputPath)) -Parent
New-Item $parent -ItemType Directory -Force | Out-Null
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($plan | ConvertTo-Json -Depth 40), (New-Object Text.UTF8Encoding($false)))
Write-Host ("Discovered {0} resources; prepared {1} portal captures. The plan is private and must not be committed." -f $resources.Count,$pages.Count)
