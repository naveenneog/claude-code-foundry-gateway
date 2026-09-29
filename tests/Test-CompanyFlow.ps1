$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:assertions = 0
$script:failed = 0
function Check([string]$Name, [scriptblock]$Test) {
    $script:assertions++
    try { $ok = [bool](& $Test); $why = '' } catch { $ok = $false; $why = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK] $Name" } else { $script:failed++; Write-Host "  [FAIL] $Name $why" }
}
function Reject([scriptblock]$Test, [string]$Pattern) {
    try { & $Test | Out-Null; return $false } catch { return ($_.Exception.Message -match $Pattern) }
}
function Import-Function([string]$Path, [string]$Name) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if (-not $node) { throw "Missing function $Name in $Path" }
    Set-Item -Path "function:script:$Name" -Value $node.Body.GetScriptBlock()
}
. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\ClaudeChoice.ps1')
. (Join-Path $root 'scripts\flow\Discovery.ps1')
$sub = '00000000-0000-0000-0000-000000000001'
$record = [pscustomobject]@{ subscriptionId = $sub; apimName = 'apim-contoso'; resourceGroup = 'rg-contoso'; gatewayUrl = 'https://claude.contoso.test/claude'; decisions = [pscustomobject]@{} }
$script:proxyType = 'Proxy'
$script:liveHost = 'claude.contoso.test'
function Invoke-ClaudeFlowAzRead {
    param($What, $AboutSeconds, $Arguments)
    [pscustomobject]@{
        Failure = ''; NotFound = $false
        Value = [pscustomobject]@{
            name = 'apim-contoso'; location = 'eastus2'; sku = @{ name = 'BasicV2' }; publisherEmail = 'ops@contoso.test'
            gatewayUrl = 'https://apim-contoso.azure-api.net'
            hostnameConfigurations = @(@{ type = $script:proxyType; hostName = $script:liveHost })
        }
    }
}
Check 'discovery accepts an exact live Proxy company hostname' { (Get-ClaudeFlowDiscovery -Record $record).comparison.status -ne 'drift' }
Check 'a removed company hostname is drift' {
    $script:liveHost = 'elsewhere.contoso.test'
    $d = Get-ClaudeFlowDiscovery -Record $record
    $script:liveHost = 'claude.contoso.test'
    $d.comparison.status -eq 'drift'
}
Check 'a portal hostname cannot masquerade as a gateway address' {
    $script:proxyType = 'DeveloperPortal'
    $d = Get-ClaudeFlowDiscovery -Record $record
    $script:proxyType = 'Proxy'
    $d.comparison.status -eq 'drift'
}
foreach ($bad in 'http://claude.contoso.test/claude','http://claude.contoso.test:443/claude','https://claude.contoso.test.attacker.test/claude','https://user@claude.contoso.test/claude','https://claude.contoso.test:444/claude','https://claude.contoso.test/claude?token=fixture','https://claude.contoso.test/claude#fragment') {
    Check "discovery refuses the noncanonical company URL: $bad" {
        $record.gatewayUrl = $bad
        (Get-ClaudeFlowDiscovery -Record $record).comparison.status -eq 'drift'
    }
}
$record.gatewayUrl = 'https://claude.contoso.test/claude'
$decision = [pscustomobject]@{
    addressMode = 'custom'; addressHostname = 'claude.contoso.test'; addressCertificateSource = 'KeyVault'
    addressKeyVaultCertificateId = 'https://kv-contoso.vault.azure.net/certificates/company'
    addressDnsZoneResourceId = "/subscriptions/$sub/resourceGroups/rg-contoso/providers/Microsoft.Network/dnsZones/contoso.test"
    sku = 'BasicV2'; location = 'eastus2'; resourceGroup = 'rg-contoso'; namePrefix = 'contoso'
}
Set-ClaudeDecision -Record $record -Key foundation -Value $decision
. (Join-Path $root 'scripts\flow\Foundation.ps1')
Check 'bound or unrelated records cannot be initialized as Setup drafts' {
    $draft=[pscustomobject]@{schemaVersion=2;activeRun=[pscustomobject]@{action='Setup';change=''}}
    $invalid=@(
        @{apimName='apim-other'}, @{resourceGroup='rg-other'}, @{mode='foundry-direct'},
        @{schemaVersion=1}, @{activeRun=[pscustomobject]@{action='Status';change=''}},
        @{activeRun=[pscustomobject]@{action='Change';change='address'}}
    )
    $refused=$true
    foreach($override in $invalid){
        $r=Copy-ClaudeFlowValue $draft
        foreach($key in $override.Keys){Set-ClaudeRecordProperty $r $key $override[$key]}
        if(Test-ClaudeAddressDraftRecord $r){$refused=$false}
    }
    $refused
}
Check 'unattended foundation forwards the explicit company-address choice' {
    $a = Get-ClaudeFlowFoundationInstallerArgs -Decision $decision -Record $record -Attended $false
    $a.AddressMode -eq 'custom' -and $a.AddressHostname -eq 'claude.contoso.test' -and
        $a.AddressCertificateSource -eq 'KeyVault' -and $a.AddressKeyVaultCertificateId -eq $decision.addressKeyVaultCertificateId -and
        $a.AddressDnsZoneResourceId -eq $decision.addressDnsZoneResourceId
}
Check 'attended foundation review names certificate, DNS and their costs' {
    $text = ($script:ClaudeFlowInstallerTopics + $script:ClaudeFlowInstallerUpdateTopics) -join ' '
    $text -match 'certificate' -and $text -match 'DNS' -and $text -match 'cost'
}
Check 'a company address in unattended Foundation has its own costed plan' {
    $empty = [pscustomobject]@{ subscriptionId = $sub; decisions = [pscustomobject]@{ foundation = $decision } }
    function Get-ClaudeFlowFoundationCost { New-ClaudeFlowCost -Item APIM -MonthlyUsd 150 -Source fixture }
    function Get-ClaudeAddressPlan {
        param($SubscriptionId,$ResourceGroup,$ApimName,$Hostname,$CertificateSource,$KeyVaultCertificateId,$PfxPath,$CertificatePassword,$DnsZoneResourceId,$ReplaceHostname,$Gateway)
        New-ClaudeFlowPlan -Step Address -Costs @(New-ClaudeFlowCost -Item 'DNS fixture cost' -MonthlyUsd 0.50 -Source fixture) -Data @{ Hostname = $Hostname }
    }
    $p = Get-ClaudeFlowStepPlan -Record $empty -Discovery ([pscustomobject]@{ action = 'Setup'; attended = $false })
    @($p.Costs | Where-Object Item -eq 'DNS fixture cost').Count -eq 1 -and $p.Data.addressPlan.Data.Hostname -eq 'claude.contoso.test'
}
$start = Join-Path $root 'Start-ClaudeGateway.ps1'
foreach ($name in 'Set-FlowRecordProperty','Set-FlowDecisionPath','Get-FlowDecisionPath','Read-FlowAnswers','Invoke-Questions','Set-CurrentOptionRecommended') { Import-Function $start $name }
$script:FlowAnswers = @{ 'address.hostname' = 'new.contoso.test' }
$script:questionReads = 0
function Test-ClaudeInteractive { $false }
function Select-ClaudeChoice { throw 'A text question must not call the numbered choice helper.' }
$steps = @([pscustomobject]@{
    Info = @{ Name = 'Address' }
    Questions = {
        param($Record,$Discovery)
        @(
            [pscustomobject]@{ Key = 'address.hostname'; Type = 'Text'; Question = 'Hostname'; Optional = $false }
            [pscustomobject]@{ Key = 'address.keyVaultCertificateId'; Type = 'Text'; Question = 'Only KeyVault'; Optional = $false; When = { param($r) $r.decisions.address.certificateSource -eq 'KeyVault' } }
        )
    }
})
Check 'text questions use explicit noninteractive answers without a fabricated option' {
    $r = [pscustomobject]@{ decisions = [pscustomobject]@{ address = [pscustomobject]@{ certificateSource = 'Pfx' } } }
    Invoke-Questions -Steps $steps -Record $r -CurrentAction Change
    $r.decisions.address.hostname -eq 'new.contoso.test' -and $r.decisions.address.PSObject.Properties.Name -notcontains 'keyVaultCertificateId'
}
Check 'a required text answer cannot default to nothing' {
    $script:FlowAnswers = @{}
    Reject { Invoke-Questions -Steps $steps -Record ([pscustomobject]@{ decisions = [pscustomobject]@{} }) -CurrentAction Change } 'required'
}
Check 'text answers reject a list before parameter binding can join it' {
    $script:FlowAnswers = @{ 'address.hostname' = @('claude','contoso') }
    Reject { Invoke-Questions -Steps $steps -Record ([pscustomobject]@{ decisions = [pscustomobject]@{} }) -CurrentAction Change } 'text.*list'
}
Check 'certificate passwords cannot be persisted in an answers file' {
    Reject { Read-FlowAnswers -InlineAnswers @{ 'address.certificatePassword' = 'fixture' } } 'transient'
}
. (Join-Path $root 'scripts\flow\Address.ps1')
$script:planInvocation = $null
function Get-ClaudeAddressPlan {
    param($SubscriptionId,$ResourceGroup,$ApimName,$Hostname,$CertificateSource,$KeyVaultCertificateId,$PfxPath,$CertificatePassword,$DnsZoneResourceId,$ReplaceHostname)
    $script:planInvocation = $PSBoundParameters
    New-ClaudeFlowPlan -Step Address -Data @{ Hostname = $Hostname; CertificateSource = $CertificateSource }
}
Check 'Address step passes every selected resource and preserves transient secrets outside the plan' {
    $r = [pscustomobject]@{
        subscriptionId = $sub; apimName = 'apim-contoso'; resourceGroup = 'rg-contoso'
        decisions = [pscustomobject]@{ address = [pscustomobject]@{ hostname = 'claude.contoso.test'; certificateSource = 'Pfx'; pfxPath = 'C:\certificate.pfx'; dnsMode = 'AzureDns'; dnsZoneResourceId = $decision.addressDnsZoneResourceId; replaceHostname = 'old.contoso.test' } }
    }
    $AddressCertificatePassword = ConvertTo-SecureString 'transient-fixture' -AsPlainText -Force
    $p = Get-ClaudeFlowStepPlan $r
    $script:planInvocation.CertificatePassword -is [securestring] -and
        $script:planInvocation.DnsZoneResourceId -eq $decision.addressDnsZoneResourceId -and
        $script:planInvocation.ReplaceHostname -eq 'old.contoso.test' -and
        ($p | ConvertTo-Json -Depth 10) -notmatch 'transient-fixture|certificatePassword'
}
Check 'switching to external DNS does not retain a stale Azure zone write' {
    $r = [pscustomobject]@{ subscriptionId = $sub; apimName = 'apim-contoso'; resourceGroup = 'rg-contoso'; decisions = [pscustomobject]@{ address = [pscustomobject]@{ hostname = 'claude.contoso.test'; certificateSource = 'KeyVault'; dnsMode = 'External'; dnsZoneResourceId = $decision.addressDnsZoneResourceId } } }
    Get-ClaudeFlowStepPlan $r | Out-Null
    -not $script:planInvocation.DnsZoneResourceId
}
Check 'Address AzureDns cannot silently fall back to external DNS when its zone is absent' {
    $r = [pscustomobject]@{ decisions = [pscustomobject]@{ address = [pscustomobject]@{ dnsMode = 'AzureDns' } } }
    Reject { Get-ClaudeFlowStepPlan $r } 'requires dnsZoneResourceId'
}
Check 'the step applies the approved plan rather than silently replanning it' {
    $p = New-ClaudeFlowPlan -Step Address -Data @{ fixed = 'approved' }
    function Invoke-ClaudeAddressPlan {
        param($Plan, $CertificatePassword, $RecordPath)
        if ($Plan.Data.fixed -ne 'approved' -or $RecordPath -ne 'C:\fixture.json') { throw 'Plan or record was not forwarded.' }
        [pscustomobject]@{ GatewayUrl = 'https://claude.contoso.test/claude'; Address = @{ hostname = 'claude.contoso.test' } }
    }
    Check 'the step updates the top-level installer address as well as the flow decision' {
        function Invoke-ClaudeAddressPlan {
            param($Plan, $CertificatePassword, $RecordPath)
            [pscustomobject]@{ GatewayUrl = 'https://new.contoso.test/claude'; Address = @{ hostname = 'new.contoso.test' } }
        }
        $r = [pscustomobject]@{ __recordPath = 'C:\fixture.json'; address = [pscustomobject]@{ hostname = 'old.contoso.test' } }
        $result = Invoke-ClaudeFlowStep -Record $r -Plan (New-ClaudeFlowPlan -Step Address)
        $r.address.hostname -eq 'new.contoso.test' -and $result.address.hostname -eq 'new.contoso.test'
    }
    $result = Invoke-ClaudeFlowStep -Record ([pscustomobject]@{ __recordPath = 'C:\fixture.json' }) -Plan $p
    $result.gatewayUrl -eq 'https://claude.contoso.test/claude' -and $result.address.hostname -eq 'claude.contoso.test'
}
Check 'live step verification does not report a generic 404 as success' {
    function Invoke-ClaudeAddressHttps { [pscustomobject]@{ StatusCode = 404; Trusted = $true; Thumbprint = 'ABC' } }
    $r = [pscustomobject]@{ gatewayUrl = 'https://claude.contoso.test/claude'; decisions = [pscustomobject]@{ address = [pscustomobject]@{ hostname = 'claude.contoso.test'; certificateThumbprint = 'ABC' } } }
    -not (Test-ClaudeFlowStep $r).Passed
}
Import-Function $start 'Assert-RecordMatchesLive'
Check 'only Change address can review a validated unverified address recovery' {
    $Action='Change';$Change='address'
    $d=[pscustomobject]@{comparison=@{differences=@('old gateway URL no longer bound')};addressRecovery=@{Allowed=$true}}
    Assert-RecordMatchesLive $d
    $true
}
Check 'address recovery cannot bypass drift for another action or decision' {
    $d=[pscustomobject]@{comparison=@{differences=@('old gateway URL no longer bound')};addressRecovery=@{Allowed=$true}}
    $Action='Setup';$Change='address'
    $setup=Reject {Assert-RecordMatchesLive $d} 'drift'
    $Action='Change';$Change='foundation'
    $setup -and (Reject {Assert-RecordMatchesLive $d} 'drift')
}
Check 'recovery planning refuses a different proposed hostname' {
    . (Join-Path $root 'scripts\flow\Address.ps1')
    $choice=[pscustomobject]@{hostname='other.contoso.test';certificateSource='KeyVault';dnsMode='External'}
    $expected=[pscustomobject]@{hostname='claude.contoso.test';certificateSource='KeyVault';dnsMode='External'}
    $r=[pscustomobject]@{subscriptionId=$sub;apimName='apim-contoso';resourceGroup='rg-contoso';decisions=[pscustomobject]@{address=$choice}}
    Reject {Get-ClaudeFlowStepPlan $r ([pscustomobject]@{addressRecovery=@{Allowed=$true;Decision=$expected;Fingerprint='receipt'}})} 'recovery must retain'
}
Check 'real ARM transport sends conditional DNS headers and removes the body file' {
    . (Join-Path $root 'scripts\ClaudeNetwork.ps1')
    function Invoke-ClaudeNetworkAz { [pscustomobject]@{ accessToken = 'fixture-token-not-a-credential' } }
    $script:sentHeaders = @()
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$TimeoutSec,$ErrorAction,$Body,$ContentType)
        $script:sentHeaders += ,$Headers
        [pscustomobject]@{ etag = 'new' }
    }
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('address-transport-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    try {
        $url = "https://management.azure.com/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Network/dnsZones/contoso.test/CNAME/claude?api-version=2018-05-01"
        Invoke-ClaudeNetworkArm $url -Method put -Body @{ properties = @{ TTL = 300 } } -StateDirectory $scratch -IfMatch 'before' | Out-Null
        Invoke-ClaudeNetworkArm $url -Method put -Body @{ properties = @{ TTL = 300 } } -StateDirectory $scratch -IfNoneMatch | Out-Null
        $script:sentHeaders[0]['If-Match'] -eq 'before' -and $script:sentHeaders[1]['If-None-Match'] -eq '*' -and @(Get-ChildItem -LiteralPath $scratch).Count -eq 0
    }
    finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Check 'network region order is ordinal across hyphens and case-folded duplicates' {
    . (Join-Path $root 'scripts\ClaudeNetwork.ps1')
    $regions=Get-ClaudeNetworkSkuLocation -Sku BasicV2 -Skus @(
        [pscustomobject]@{name='BasicV2';locations=@('eastusa','eastus-b','EASTUS-B');restrictions=@()}
    )
    (@($regions) -join ',') -ceq 'EASTUS-B,eastusa'
}
Check 'network region null and empty lists remain empty rather than selectable choices' {
    . (Join-Path $root 'scripts\ClaudeNetwork.ps1')
    $empty=Get-ClaudeNetworkSkuLocation -Sku BasicV2 -Skus @()
    $mixed=Get-ClaudeNetworkSkuLocation -Sku BasicV2 -Skus @(
        [pscustomobject]@{name='BasicV2';locations=@($null,'eastus-b',$null);restrictions=@()}
    )
    @($empty).Count -eq 0 -and @($mixed).Count -eq 1 -and $mixed[0] -eq 'eastus-b'
}
Check 'recovery host projection orders type then hostname by code point and drops null rows' {
    . (Join-Path $root 'scripts\ClaudeGatewayAddressRecovery.ps1')
    $gateway=[pscustomobject]@{properties=@{hostnameConfigurations=@(
        @{type='Proxy';hostName='eastusa.contoso.test';certificateSource='Custom'}
        $null
        @{type='DeveloperPortal';hostName='z.contoso.test';certificateSource='Custom'}
        @{type='Proxy';hostName='eastus-b.contoso.test';certificateSource='Custom'}
        @{type='Proxy';hostName='built-in.azure-api.net';certificateSource='BuiltIn'}
    )}}
    $hosts=@(Get-ClaudeAddressRecoveryHosts $gateway)
    $empty=@(Get-ClaudeAddressRecoveryHosts ([pscustomobject]@{properties=@{hostnameConfigurations=$null}}))
    (@($hosts|ForEach-Object { "$($_.type):$($_.hostname)" }) -join ',') -ceq 'DeveloperPortal:z.contoso.test,Proxy:eastus-b.contoso.test,Proxy:eastusa.contoso.test' -and $empty.Count -eq 0
}
Check 'network subscription discovery sorts unique scopes and still refuses an empty scope' {
    . (Join-Path $root 'scripts\ClaudeNetwork.ps1')
    $first='00000000-0000-0000-0000-000000000001'
    $second='00000000-0000-0000-0000-000000000002'
    $script:scopeReads=@()
    function Invoke-ClaudeNetworkAz {
        param($Arguments)
        @([pscustomobject]@{id=$first;state='Enabled'},[pscustomobject]@{id=$second;state='Enabled'})
    }
    function Get-ClaudeNetworkPages {
        param($Url)
        if($Url -match '/subscriptions/([^/]+)/resources\?'){$script:scopeReads+=$Matches[1]}
        return ,@()
    }
    function Invoke-ClaudeNetworkArm {param($Url);[pscustomobject]@{resourceTypes=@();properties=@{state='Registered'}}}
    Get-ClaudeNetworkInventory -SubscriptionId $second -DiscoverySubscriptionId @($first,$second) | Out-Null
    $ordered=($script:scopeReads -join ',') -ceq "$first,$second"
    $ordered -and (Reject { Get-ClaudeNetworkInventory -SubscriptionId $second -DiscoverySubscriptionId @($null) } 'not an enabled visible subscription')
}
Check 'network NSG identifiers use ordinal order and exclude empty subnet references' {
    . (Join-Path $root 'scripts\ClaudeNetwork.ps1')
    $rg='/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-contoso'
    $prefix="$rg/providers/Microsoft.Network/networkSecurityGroups/"
    function Invoke-ClaudeNetworkArm {
        param($Url,[switch]$AllowNotFound)
        if($Url -match '/virtualNetworks/'){
            return [pscustomobject]@{properties=@{subnets=@(
                @{properties=@{networkSecurityGroup=@{id="${prefix}nsga"}}}
                @{properties=@{networkSecurityGroup=@{id="${prefix}nsg-b"}}}
                @{properties=@{networkSecurityGroup=$null}}
                @{properties=@{networkSecurityGroup=@{id="${prefix}nsg-b"}}}
            )}}
        }
        [pscustomobject]@{tags=@{'claude-network-owner'='fixture'}}
    }
    $nsgs=Get-ClaudeNetworkOwnedNsgs -VnetId "$rg/providers/Microsoft.Network/virtualNetworks/fixture" -ResourceGroupId $rg -OwnerId fixture
    (@($nsgs|ForEach-Object id) -join ',') -ceq "${prefix}nsg-b,${prefix}nsga"
}
Check 'standalone network and recovery helpers load the shared ordinal sorter' {
    $loaded=$true
    foreach($library in 'scripts\ClaudeNetwork.ps1','scripts\ClaudeGatewayAddressRecovery.ps1'){
        $probe=[powershell]::Create()
        try{
            $null=$probe.AddScript('param($path) . $path; [bool](Get-Command Sort-ClaudeFlowOrdinal -ErrorAction SilentlyContinue)').AddArgument((Join-Path $root $library))
            $result=@($probe.Invoke())
            if($probe.HadErrors -or $result.Count -ne 1 -or $result[0] -ne $true){$loaded=$false}
        }finally{$probe.Dispose()}
    }
    $loaded
}
Write-Host ("Company flow: {0} assertions, {1} passed, {2} failed." -f $script:assertions, ($script:assertions - $script:failed), $script:failed)
if ($script:failed) { exit 1 }
