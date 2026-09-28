# Executes the real installer, with only external services and post-deploy leaf scripts stubbed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('company-installer-' + [guid]::NewGuid().ToString('N'))
$failed = 0; $count = 0
function Check([string]$Name,[scriptblock]$Test) {
    $script:count++
    try { $ok=[bool](& $Test); $why='' } catch { $ok=$false; $why=$_.Exception.Message }
    if($ok){Write-Host "  [OK] $Name"}else{$script:failed++;Write-Host "  [FAIL] $Name $why"}
}
try {
    foreach($dir in 'scripts\flow\lib','onboarding\profiles\standard'){New-Item -ItemType Directory -Path (Join-Path $scratch $dir) -Force|Out-Null}
    foreach($file in 'Install-ClaudeGateway.ps1','scripts\Show-Banner.ps1','scripts\Test-Prerequisites.ps1','scripts\ClaudeModelDeployment.ps1','scripts\ClaudeDesktopSignIn.ps1','scripts\ClaudeChoice.ps1','scripts\ClaudeGatewayRegion.ps1','scripts\AzureRetailPrice.ps1','scripts\flow\FlowContract.ps1','scripts\flow\Foundation.ps1','scripts\flow\lib\LifecycleCommon.ps1'){
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $scratch $file)
    }
    $inputs=Join-Path $root 'scripts\ClaudeGatewayAddressInput.ps1'
    if(Test-Path $inputs){Copy-Item -LiteralPath $inputs -Destination (Join-Path $scratch 'scripts')}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\ClaudeGatewayAddress.ps1'),[ref]$tokens,[ref]$errors)
    $artifacts=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-ClaudeAddressArtifacts'},$true).Extent.Text
    $stub=@'
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
if (Test-Path (Join-Path $PSScriptRoot 'ClaudeGatewayAddressInput.ps1')) { . (Join-Path $PSScriptRoot 'ClaudeGatewayAddressInput.ps1') }
function Get-ClaudeAddressPlan {
    param($SubscriptionId,$ResourceGroup,$ApimName,$Hostname,$CertificateSource,$KeyVaultCertificateId,$PfxPath,$CertificatePassword,$DnsZoneResourceId,$ReplaceHostname,$Gateway)
    $global:P69InstallPlanned = @{ Hostname=$Hostname; CertificateSource=$CertificateSource; KeyVaultCertificateId=$KeyVaultCertificateId; DnsZoneResourceId=$DnsZoneResourceId }
    New-ClaudeFlowPlan -Step Address -Actions @(New-ClaudeFlowAction -Verb Update -Target 'company-address') -Costs @(New-ClaudeFlowCost -Item 'Company DNS fixture' -MonthlyUsd 0.50 -Source fixture) -Data $global:P69InstallPlanned
}
function Invoke-ClaudeAddressPlan {
    param($Plan,$CertificatePassword)
    $global:P69InstallWrites.Add('address')
    [pscustomobject]@{ GatewayUrl="https://$($Plan.Data.Hostname)/claude"; Address=[pscustomobject]@{ hostname=$Plan.Data.Hostname; certificateSource=$Plan.Data.CertificateSource; keyVaultCertificateId=$Plan.Data.KeyVaultCertificateId; dnsMode='AzureDns'; dnsZoneResourceId=$Plan.Data.DnsZoneResourceId; certificateThumbprint='NEW-PIN' } }
}
'@
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\ClaudeGatewayAddress.ps1'),$stub+"`n"+$artifacts)
    foreach($leaf in 'Sync-ClaudeAccess.ps1','Show-Governance.ps1'){[IO.File]::WriteAllText((Join-Path $scratch "scripts\$leaf"),'$global:LASTEXITCODE=0')}
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\Measure-ClaudeProjectionCost.ps1'),'param($Developers,$CacheMinutes,[switch]$AsJson); ''{"monthly_usd":{"total":1}}''')
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\ClaudeUsdBudgets.ps1'),'function Get-ClaudeUsdNamedValues { param($ResourceGroup,$ApimName); @{''usd-budgets''='''';''usd-budget-state''=''''} }')
    $sub='00000000-0000-0000-0000-000000000001'
    $zone="/subscriptions/$sub/resourceGroups/rg-contoso/providers/Microsoft.Network/dnsZones/contoso.test"
    $initial=[pscustomobject]@{
        subscriptionId=$sub;apimName='apim-contoso';resourceGroup='rg-contoso';gatewayUrl='https://old.contoso.test/claude'
        address=[pscustomobject]@{hostname='old.contoso.test';certificateSource='KeyVault';keyVaultCertificateId='https://kv-contoso.vault.azure.net/certificates/company';dnsMode='AzureDns';dnsZoneResourceId=$zone;certificateThumbprint='OLD-PIN'}
        decisions=[pscustomobject]@{address=[pscustomobject]@{hostname='old.contoso.test';certificateThumbprint='OLD-PIN'};foundation=[pscustomobject]@{addressMode='custom';addressHostname='old.contoso.test'}}
    }
    $recordPath=Join-Path $scratch 'onboarding\claude-gateway.json'
    $driver=@'
param($Root,$Values,$Decline)
$global:P69InstallWrites=New-Object 'Collections.Generic.List[string]'
$global:P69InstallUnexpected=New-Object 'Collections.Generic.List[string]'
$global:P69InstallPlanned=$null
function az {
    $s=$args -join ' '; $global:LASTEXITCODE=0
    if($s -like 'version*'){return "2.86.0`t2.86.0`t1.1.0`t"}
    if($s -like 'bicep version*'){return 'Bicep CLI version 0.46.1'}
    if($s -like 'account list --query*'){return '00000000-0000-0000-0000-000000000001'}
    if($s -like 'account set*'){return}
    if($s -like 'account show --query name*'){return 'fixture'}
    if($s -like 'account get-access-token*'){return 'fixture-not-a-credential'}
    if($s -like 'account show*'){return '{"id":"00000000-0000-0000-0000-000000000001","name":"fixture","tenantId":"00000000-0000-0000-0000-000000000001","user":{"name":"admin@contoso.com"}}'}
    if($s -like 'cognitiveservices account deployment list*'){
        return (@('claude-sonnet-5','claude-opus-5','claude-haiku-4-5') | ForEach-Object { @{name=$_;sku=@{name='GlobalStandard';capacity=1};properties=@{provisioningState='Succeeded';model=@{format='Anthropic';name=$_;version='2'}}} } | ConvertTo-Json -Depth 7)
    }
    if($s -like 'apim show*'){
        if($s -match '--query identity.principalId'){return ''}
        if($s -match '--query id'){return '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso'}
        if($s -match '--query sku.name'){return 'BasicV2'}
        return '{"name":"apim-contoso","resourceGroup":"rg-contoso","location":"eastus2","publisherEmail":"ops@contoso.com","sku":{"name":"BasicV2"},"gatewayUrl":"https://apim-contoso.azure-api.net"}'
    }
    if($s -like 'apim nv show*'){ if($s -like '*entitlement-cache-seconds*'){return '3600'}; return ',,' }
    if($s -like 'group show*'){return 'eastus2'}
    if($s -like 'deployment group create*'){$global:P69InstallWrites.Add('deployment');return}
    if($s -like 'deployment group show*'){return 'https://apim-contoso.azure-api.net/claude'}
    if($s -like 'ad group show*'){return '00000000-0000-0000-0000-000000000002'}
    $global:P69InstallUnexpected.Add($s); throw "Unexpected az call: $s"
}
function Invoke-WebRequest {param($Uri,$Method,$TimeoutSec,$ErrorAction,[switch]$UseBasicParsing);[pscustomobject]@{StatusCode=200}}
function Invoke-RestMethod {
    param($Uri,$TimeoutSec,$ErrorAction,$Method,$Headers,$Body,$ContentType)
    if([string]$Uri -like '*prices.azure.com*'){
        $rows=foreach($r in @(@('Basic v2 Unit',0.21),@('Standard v2 Unit',0.96),@('Premium v2 Unit',3.84))){[pscustomobject]@{meterName=$r[0];retailPrice=$r[1];type='Consumption';skuName=($r[0]-replace ' Unit$','');productName='API Management';tierMinimumUnits=0;unitOfMeasure='1 Hour';currencyCode='USD';armRegionName='eastus2'}}
        return [pscustomobject]@{Items=@($rows);NextPageLink=$null}
    }
    [pscustomobject]@{properties=@{virtualNetworkType='None';hostnameConfigurations=@();customProperties=@{}}}
}
function Read-Host { if($Decline -and $Prompt -eq 'Apply this to the existing gateway?'){return 'n'}; return '' }
$lines=New-Object 'Collections.Generic.List[string]'
$failure=''
try { & (Join-Path $Root 'Install-ClaudeGateway.ps1') @Values *>&1 | ForEach-Object {$lines.Add([string]$_)} }
catch {$failure=$_.Exception.Message}
[pscustomobject]@{Text=$lines -join "`n";Failure=$failure;Writes=@($global:P69InstallWrites);Unexpected=@($global:P69InstallUnexpected);Planned=$global:P69InstallPlanned}
'@
    function Invoke-Installer([hashtable]$Overrides=@{},[bool]$Decline=$false){
        [IO.File]::WriteAllText($recordPath,($initial|ConvertTo-Json -Depth 15))
        [IO.File]::WriteAllText((Join-Path $scratch 'onboarding\profiles\standard\managed-settings.json'),'{"gatewayUrl":"https://old.contoso.test/claude"}')
        $values=@{SubscriptionId=$sub;FoundryAccount='ai-contoso';FoundryResourceGroup='rg-contoso';ResourceGroup='rg-contoso';ExistingApimName='apim-contoso';Location='eastus2';Sku='BasicV2';AuthMode='interactive';EntitlementStore='named-value';SkipFinOpsOffer=$true;Yes=$true}
        foreach($k in $Overrides.Keys){$values[$k]=$Overrides[$k]}
        $ps=[powershell]::Create()
        try {$null=$ps.AddScript($driver).AddArgument($scratch).AddArgument($values).AddArgument($Decline);@($ps.Invoke())[-1]}finally{$ps.Dispose()}
    }
    $preview=Invoke-Installer @{WhatIf=$true}
    Check 'real custom WhatIf reaches summary with inherited hostname and costs' {
        if($preview.Failure){throw $preview.Failure}
        if(-not ($preview.Text -match 'Summary' -and $preview.Text -match 'Company DNS fixture' -and $preview.Planned.Hostname -eq 'old.contoso.test')){throw ($preview|ConvertTo-Json -Depth 5)}
        $true
    }
    Check 'custom WhatIf creates no deployment or address' {$preview.Writes.Count -eq 0 -and $preview.Unexpected.Count -eq 0}
    $mismatch=Invoke-Installer @{AddressApprovedPlanFingerprint=('0'*64)}
    Check 'real installer fingerprint mismatch rejects every resource write' {$mismatch.Failure -match 'plan changed' -and $mismatch.Writes.Count -eq 0}
    $declined=Invoke-Installer @{Yes=$false} $true
    Check 'real declined custom confirmation creates nothing' {$declined.Text -match 'Cancelled' -and -not $declined.Failure -and $declined.Writes.Count -eq 0}
    $azure=Invoke-Installer @{AddressMode='azure'}
    $after=Get-Content -Raw $recordPath|ConvertFrom-Json
    Check 'Azure transition runs the real package writer without address apply' {-not $azure.Failure -and $azure.Writes -contains 'deployment' -and $azure.Writes -notcontains 'address'}
    Check 'Azure transition clears both company metadata copies' {$after.gatewayUrl -eq 'https://apim-contoso.azure-api.net/claude' -and -not $after.address -and -not $after.decisions.address}
    Check 'Azure transition clears inherited Foundation company inputs as well' {$after.decisions.foundation.addressMode -eq 'azure' -and -not $after.decisions.foundation.addressHostname}
    Check 'Azure transition updates existing generated settings' {[IO.File]::ReadAllText((Join-Path $scratch 'onboarding\profiles\standard\managed-settings.json')) -match 'apim-contoso.azure-api.net'}
    . (Join-Path $root 'scripts\flow\FlowContract.ps1')
    . (Join-Path $root 'scripts\flow\Foundation.ps1')
    . (Join-Path $scratch 'scripts\ClaudeGatewayAddress.ps1')
    Check 'Foundation merge retains the address chosen by the installer rather than an old proposal' {
        $merged=Merge-ClaudeFlowFoundationDecision -Decision ([pscustomobject]@{addressMode='custom';addressHostname='old.contoso.test'}) -Config $after
        $merged.addressMode -eq 'azure' -and -not $merged.addressHostname
    }
    function Get-ClaudeFlowFoundationCost {param($Sku,$Location);New-ClaudeFlowCost -Item APIM -MonthlyUsd 150 -Source fixture}
    Set-ClaudeDecision $initial foundation ([pscustomobject]@{})
    $plan=Get-ClaudeFlowStepPlan $initial ([pscustomobject]@{action='Change';attended=$false})
    Check 'Foundation fingerprints and prices inherited company address inputs' {
        $plan.Data.addressPlan -and $plan.Data.installerArgs.AddressApprovedPlanFingerprint -eq (Get-ClaudeFlowFingerprint @($plan.Data.addressPlan)) -and
            $plan.Data.installerArgs.AddressHostname -eq 'old.contoso.test' -and $plan.Data.installerArgs.AddressDnsZoneResourceId -eq $zone -and @($plan.Costs|Where-Object Item -eq 'Company DNS fixture').Count -eq 1
    }
    $without=[pscustomobject]@{subscriptionId=$sub;apimName='apim-contoso';resourceGroup='rg-contoso';decisions=[pscustomobject]@{foundation=[pscustomobject]@{}}}
    $noAddress=Get-ClaudeFlowStepPlan $without ([pscustomobject]@{action='Change';attended=$false})
    Check 'Foundation passes explicit Azure mode when nothing is recorded, preventing other-file inheritance' {$noAddress.Data.installerArgs.AddressMode -eq 'azure'}
}
finally {if(Test-Path $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}}
Write-Host "Company installer: $count assertions, $($count-$failed) passed, $failed failed."
if($failed){exit 1}
