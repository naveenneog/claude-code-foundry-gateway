param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
$helpers = Join-Path $root 'scripts\ClaudeAumDeployment.ps1'
Assert (Test-Path $helpers) 'AUM deployment helpers exist'
. $helpers

function Get-AzureRetailPrice {
    param($ServiceName, $Region, $MeterName, $SkuName, $ProductName)
    $amount = switch -Regex ($MeterName) {
        'Always Ready Baseline' { [decimal]'0.000004' }
        'On Demand Execution Time' { [decimal]'0.000026' }
        'On Demand Total Executions' { [decimal]'0.000004' }
        'Data Stored' { [decimal]'0.05' }
        'Private Endpoint' { [decimal]'0.01' }
        'Zone' { [decimal]'0.5' }
        'Data Ingestion' { [decimal]'2.76' }
        default { [decimal]'0.001' }
    }
    [pscustomobject]@{ UnitPrice = $amount; UnitOfMeasure = 'unit'; Region = $Region; MeterName = $MeterName; RetrievedUtc = '2026-09-24T00:00:00Z' }
}
$prices = Get-ClaudeAumPrices -Region 'contoso-region'
Assert ($prices.AlwaysReadyMonthly -eq [decimal]'5.256') '512 MiB warm-instance baseline uses GB-seconds and 730 hours'
$choices = @(Get-ClaudeAumChoices -Prices $prices)
Assert (@($choices | Where-Object Category -eq 'AlwaysReady').Count -eq 2) 'zero and one warm instance are explicit choices'
Assert (@($choices | Where-Object Category -eq 'Redundancy').Count -eq 3) 'storage redundancy is chosen'
Assert (@($choices | Where-Object Category -eq 'Insights').Count -eq 2) 'telemetry is opt-in'
Assert (@($choices | Where-Object Category -eq 'Network').Count -eq 2) 'public and private have implications'
Assert (@($choices | Where-Object { -not $_.Implications }).Count -eq 0) 'every choice explains implications'
Assert (@($choices | Where-Object { -not $_.Cost }).Count -eq 0) 'every choice describes cost'
Assert ((Format-ClaudeAumCost $null) -match 'unknown') 'missing prices never become free'

$plans = @(
    [pscustomobject]@{ name = 'contoso-flex'; location = 'contoso-region'; sku = @{ name = 'FC1' }; properties = @{ numberOfSites = 1 } },
    [pscustomobject]@{ name = 'contoso-empty'; location = 'contoso-region'; sku = @{ name = 'FC1' }; properties = @{ numberOfSites = 0 } },
    [pscustomobject]@{ name = 'contoso-other'; location = 'other-region'; sku = @{ name = 'FC1' }; properties = @{ numberOfSites = 0 } }
)
$compatible = @(Get-ClaudeAumReusablePlans -Plans $plans -Region 'contoso-region')
Assert ($compatible.Count -eq 1 -and $compatible[0].name -eq 'contoso-empty') 'Flex plan cannot be shared with another app or region'

$discovery = @{
    Account = @{ id = '00000000-0000-0000-0000-000000000001'; tenantId = '00000000-0000-0000-0000-000000000002' }
    Gateway = @{ id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso'; name = 'apim-contoso'; location = 'contoso-region' }
    Workspace = @{ id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso/providers/Microsoft.OperationalInsights/workspaces/log-contoso'; properties = @{ customerId = '00000000-0000-0000-0000-000000000003' } }
}
$plan = New-ClaudeAumPlan -Discovery $discovery -ResourceGroup 'rg-aum-contoso' -Location 'contoso-region' -NamePrefix 'contoso' -AlwaysReady 0 -Redundancy LRS -Insights Off -Network Public
Assert ($plan.parameters.apimResourceId -eq $discovery.Gateway.id) 'discovered gateway becomes the target'
Assert ($plan.parameters.workspaceCustomerId -eq $discovery.Workspace.properties.customerId) 'discovered workspace is used, not the first in a group'
Assert ($plan.parameters.alwaysReadyInstances -eq 0) 'cold-start choice is preserved'
Assert (-not $plan.parameters.enableInsights) 'no hidden telemetry cost'
Assert ($plan.parameters.inboundAccess -eq 'public') 'network choice is preserved'

$options = @(Get-ClaudeFinOpsChoices -Prices $prices)
Assert ($options.Count -eq 5) 'admin chooses among five independent FinOps options'
Assert (($options | Where-Object Id -eq 'Direct').Who -match 'admin') 'Direct is admin-only'
Assert (($options | Where-Object Id -eq 'AumService').Who -match 'manager') 'service supports scoped managers'
Assert (($options | Where-Object Id -eq 'TurnstileAum').Needs -match 'Turnstile') 'AUM can use Turnstile without its own service'

foreach ($file in @('Deploy-ClaudeAumService.ps1','Remove-ClaudeAumService.ps1','Select-ClaudeFinOpsTooling.ps1','New-ClaudeAumEntraApp.ps1')) {
    $path = Join-Path $root "scripts\$file"
    Assert (Test-Path $path) "$file exists"
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert ($errors.Count -eq 0) "$file parses"
    $text = Get-Content -Raw $path
    Assert ($text -match 'SupportsShouldProcess') "$file supports WhatIf"
    Assert ($text -notmatch 'GetTempPath|GetTempFileName') "$file uses worktree-local uniquely named files"
}
$bicep = Get-Content (Join-Path $root 'infra\aum-service.bicep') -Raw
Assert ($bicep -match "name: 'FC1'") 'runtime is Flex Consumption'
Assert ($bicep -match 'allowSharedKeyAccess: false') 'storage keys are off'
Assert ($bicep -notmatch 'listKeys\(') 'template never obtains a key'
Assert ($bicep -match "name: 'AUM_APIM_RESOURCE_ID'") 'gateway is an injected resource id'
Assert ($bicep -match 'Storage Blob Data Owner|b7e6dc6d-f1e8-4753-8033-0f276bb0955b') 'timer host has the required data role'
$role = Get-ClaudeAumWriterRoleDefinition -Scope '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso'
Assert (@($role.Actions).Count -eq 4) 'writer role has exactly the existing four governance actions'
Assert (@($role.Actions | Where-Object { $_ -match 'policies|delete|\*' }).Count -eq 0) 'writer cannot edit policy or delete resources'
Write-Host "$script:passed AUM deployment assertions passed." -ForegroundColor Green
