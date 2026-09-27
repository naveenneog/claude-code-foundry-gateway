# P69: offline boundaries, write ordering and publication. Every assertion runs after a failure.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:failed = 0
$script:assertions = 0
function Check([string]$Name, [scriptblock]$Test) {
    $script:assertions++
    try { $ok = [bool](& $Test); $why = '' } catch { $ok = $false; $why = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK] $Name" }
    else { $script:failed++; Write-Host "  [FAIL] $Name $why" }
}
function Reject([scriptblock]$Test, [string]$Pattern) {
    try { & $Test | Out-Null; return $false } catch { return ($_.Exception.Message -match $Pattern) }
}
function Copy-Object($Value) { $json = $Value | ConvertTo-Json -Depth 30; $parsed = $json | ConvertFrom-Json; return $parsed }
. (Join-Path $root 'scripts\flow\FlowContract.ps1')
$entry = Join-Path $root 'scripts\Set-ClaudeGatewayAddress.ps1'
Check 'the company address implementation exists' { Test-Path -LiteralPath $entry }
if (Test-Path -LiteralPath $entry) { . $entry }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('company-address-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sub = '00000000-0000-0000-0000-000000000001'
$rgId = "/subscriptions/$sub/resourceGroups/rg-contoso"
$apimId = "$rgId/providers/Microsoft.ApiManagement/service/apim-contoso"
$zoneId = "$rgId/providers/Microsoft.Network/dnsZones/contoso.test"
$vaultId = "$rgId/providers/Microsoft.KeyVault/vaults/kv-contoso"
$recordPath = Join-Path $scratch 'claude-gateway.json'
$script:thumbprint = '1234567890ABCDEF1234567890ABCDEF12345678'
$script:certificateReader = if (Get-Command Read-ClaudeAddressCertificate -ErrorAction SilentlyContinue) { (Get-Command Read-ClaudeAddressCertificate).ScriptBlock } else { $null }

function Reset-State {
    $script:writes = @()
    $script:events = @()
    $script:missingPrice = $false
    $script:priceCalls = @()
    $script:dnsMatches = $true
    $script:tlsStatus = 401
    $script:tlsThumbprint = $script:thumbprint
    $script:tlsTrusted = $true
    $script:patchFails = $false
    $script:patchState = 'Succeeded'
    $script:live = [pscustomobject]@{
        id = $apimId; name = 'apim-contoso'; location = 'eastus2'; sku = @{ name = 'BasicV2'; capacity = 1 }
        identity = @{ type = 'SystemAssigned'; principalId = '00000000-0000-0000-0000-000000000002'; tenantId = $sub }
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'; gatewayUrl = 'https://apim-contoso.azure-api.net'
            publicNetworkAccess = 'Disabled'; virtualNetworkType = 'External'
            virtualNetworkConfiguration = @{ subnetResourceId = "$rgId/providers/Microsoft.Network/virtualNetworks/vnet/subnets/apim" }
            customProperties = @{ 'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10' = 'False' }
            hostnameConfigurations = @(
                @{ type = 'Proxy'; hostName = 'apim-contoso.azure-api.net'; certificateSource = 'BuiltIn'; defaultSslBinding = $false }
                @{ type = 'DeveloperPortal'; hostName = 'portal.contoso.test'; certificateSource = 'Custom'; certificate = @{ thumbprint = 'PORTAL' }; negotiateClientCertificate = $true }
            )
        }
    }
    $script:zone = [pscustomobject]@{ id = $zoneId; name = 'contoso.test'; properties = @{ nameServers = @('ns1.example.test') } }
    $script:dnsRecord = $null
    $script:vault = [pscustomobject]@{
        id = $vaultId; location = 'eastus2'
        properties = @{ enableRbacAuthorization = $true; tenantId = $sub; accessPolicies = @() }
    }
    $script:cert = [pscustomobject]@{ Thumbprint = $script:thumbprint; SecretId = 'https://kv-contoso.vault.azure.net/secrets/company'; VaultId = $vaultId; Rbac = $true; PfxSha256 = '' }
    $script:record = [pscustomobject]@{
        mode = 'gateway'; subscriptionId = $sub; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'
        gatewayUrl = 'https://apim-contoso.azure-api.net/claude'; sku = 'BasicV2'; location = 'eastus2'
        tenantId = $sub; unknownField = @{ survives = 'yes' }; history = @(@{ action = 'Setup'; decision = 'foundation' })
        decisions = [pscustomobject]@{}
    }
    Write-ClaudeDecisionRecord -Record $script:record -Path $recordPath
}
function Read-ClaudeAddressCertificate {
    param($CertificateSource, $KeyVaultCertificateId, $PfxPath, $CertificatePassword, $Hostname, $SubscriptionId)
    Copy-Object $script:cert
}
function Get-AzureRetailPrice {
    param($ServiceName, [AllowEmptyString()]$Region, $MeterName, $SkuName, $ProductName, $Tier)
    $script:priceCalls += [pscustomobject]@{ Service = $ServiceName; Region = $Region; Meter = $MeterName; Tier = $Tier; Sku = $SkuName }
    if ($script:missingPrice) { return $null }
    $rate = @{ 'Public Zone' = 0.50; 'Public Queries' = 0.40; 'Operations' = 0.03; 'Certificate Renewal Request' = 3 }
    [pscustomobject]@{ UnitPrice = [decimal]$rate[$MeterName]; UnitOfMeasure = @{ 'Public Zone' = '1'; 'Public Queries' = '1M'; 'Operations' = '10K'; 'Certificate Renewal Request' = '1' }[$MeterName]; Currency = 'USD'; RetrievedUtc = '2026-09-28T00:00:00Z' }
}
function Invoke-ClaudeNetworkArm {
    param($Url, $Method = 'get', $Body, $StateDirectory, [switch]$AllowNotFound, $IfMatch, [switch]$IfNoneMatch)
    if ($Method -ne 'get') {
        $script:writes += [pscustomobject]@{ Url = $Url; Method = $Method; Body = (Copy-Object $Body); IfMatch = $IfMatch; IfNoneMatch = [bool]$IfNoneMatch }
        if ($Url -like "$apimId*") { throw 'The ARM URL omitted its authority.' }
        if ($Url -match '/Microsoft.ApiManagement/service/') {
            $script:events += 'binding'
            if ($script:patchFails) { throw 'AuthorizationFailed: APIM write refused' }
            if ($Body.properties -and $Body.properties.hostnameConfigurations) {
                $script:live.properties.hostnameConfigurations = Copy-Object $Body.properties.hostnameConfigurations
            }
            if ($Body.identity) { $script:live.identity = Copy-Object $Body.identity; $script:live.identity | Add-Member principalId '00000000-0000-0000-0000-000000000002' -Force }
            $script:live.properties.provisioningState = $script:patchState
            return Copy-Object $script:live
        }
        if ($Url -match '/CNAME/') {
            $script:events += 'dns'
            $script:dnsRecord = [pscustomobject]@{ etag = 'after'; properties = (Copy-Object $Body.properties) }
            return Copy-Object $script:dnsRecord
        }
        $script:events += 'grant'
        return [pscustomobject]@{ name = 'grant' }
    }
    if ($Url -match '/Microsoft.ApiManagement/service/') { return Copy-Object $script:live }
    if ($Url -match '/CNAME/') { return Copy-Object $script:dnsRecord }
    if ($Url -match '/dnsZones/') { return Copy-Object $script:zone }
    if ($Url -match '/Microsoft.KeyVault/vaults/') { return Copy-Object $script:vault }
    if ($Url -match '/roleAssignments') { return [pscustomobject]@{ value = @() } }
    throw "Unexpected ARM read: $Url"
}
function Resolve-DnsName {
    param($Name, $Type, $Server, [switch]$DnsOnly, [switch]$NoHostsFile, [switch]$QuickTimeout, $ErrorAction)
    if (-not $script:dnsMatches) { throw 'DNS name does not exist' }
    [pscustomobject]@{ Name = $Name; Type = 'CNAME'; NameHost = 'apim-contoso.azure-api.net.' }
}
function Invoke-ClaudeAddressHttps {
    param($Hostname, $Thumbprint, $ConnectAddress, [switch]$IsolatedProof)
    $script:events += 'proof'
    [pscustomobject]@{ StatusCode = $script:tlsStatus; Thumbprint = $script:tlsThumbprint; Trusted = $script:tlsTrusted; Hostname = $Hostname }
}
function New-Plan([hashtable]$Overrides = @{}) {
    $p = @{
        SubscriptionId = $sub; ResourceGroup = 'rg-contoso'; ApimName = 'apim-contoso'
        Hostname = 'claude.contoso.test'; CertificateSource = 'KeyVault'
        KeyVaultCertificateId = 'https://kv-contoso.vault.azure.net/certificates/company'
        DnsZoneResourceId = $zoneId
    }
    foreach ($k in $Overrides.Keys) { $p[$k] = $Overrides[$k] }
    Get-ClaudeAddressPlan @p
}
function Apply-Plan($Plan) {
    Invoke-ClaudeAddressPlan -Plan $Plan -RecordPath $recordPath -TimeoutSeconds 0 -DnsTimeoutSeconds 0 -PollSeconds 0
}
try {
    Reset-State
    Check 'planning creates no Azure resources or record changes' {
        $before = [IO.File]::ReadAllText($recordPath)
        $p = New-Plan
        $p.Step -eq 'Address' -and $script:writes.Count -eq 0 -and [IO.File]::ReadAllText($recordPath) -eq $before
    }
    Check 'the exact CNAME is planned with no managed-certificate TXT' {
        $p = New-Plan
        $p.Data.DnsRecord.Name -eq 'claude' -and $p.Data.DnsRecord.Target -eq 'apim-contoso.azure-api.net' -and
            ($p | ConvertTo-Json -Depth 30) -notmatch '"TXT"'
    }
    foreach ($sku in 'BasicV2','StandardV2','PremiumV2') {
        Check "$sku offers supplied certificates, not managed issuance" {
            $script:live.sku.name = $sku
            $p = New-Plan
            $p.Data.Sku -eq $sku -and (Reject { New-Plan @{ CertificateSource = 'Managed' } } 'managed.*not supported')
        }
    }
    Reset-State
    foreach ($bad in 'https://claude.contoso.test','*.contoso.test','127.0.0.1','claude..contoso.test','claude.contoso.test/path','claude&whoami.contoso.test','-claude.contoso.test') {
        Check "invalid hostname is refused: $bad" { Reject { New-Plan @{ Hostname = $bad } } 'hostname' }
    }
    Check 'a different DNS suffix cannot be mistaken for the selected zone' { Reject { New-Plan @{ Hostname = 'claude.notcontoso.test' } } 'zone' }
    Check 'a CNAME at the zone apex is refused before a write' { Reject { New-Plan @{ Hostname = 'contoso.test' } } 'apex' }
    Check 'a DNS zone in another subscription is refused' { Reject { New-Plan @{ DnsZoneResourceId = $zoneId.Replace($sub,'00000000-0000-0000-0000-000000000099') } } 'subscription' }
    Check 'a private DNS zone is not treated as public Azure DNS' { Reject { New-Plan @{ DnsZoneResourceId = $zoneId.Replace('/dnsZones/','/privateDnsZones/') } } 'DNS zone' }
    Check 'a CLI metacharacter cannot reach resource discovery' { Reject { New-Plan @{ ResourceGroup = 'rg&whoami' } } 'resource group' }
    Check 'unsupported gateway tiers fail before writes' {
        $script:live.sku.name = 'Developer'
        $result = Reject { New-Plan } 'v2'
        $script:live.sku.name = 'BasicV2'
        $result -and $script:writes.Count -eq 0
    }
    Check 'a busy service is not modified or hidden by a successful old state' {
        $script:live.properties.provisioningState = 'Updating'
        $result = Reject { New-Plan } 'provisioning|updating'
        $script:live.properties.provisioningState = 'Succeeded'
        $result
    }
    Check 'Basic v2 does not silently discard a different company hostname' {
        $script:live.properties.hostnameConfigurations += @{ type = 'Proxy'; hostName = 'old.contoso.test'; certificateSource = 'Custom' }
        Reject { New-Plan } 'ReplaceHostname'
    }
    Check 'an explicit replacement names only the hostname being removed' {
        $p = New-Plan @{ ReplaceHostname = 'old.contoso.test' }
        $patch = Get-ClaudeAddressHostnamePatch -Gateway $script:live -Plan $p -Binding @{ type = 'Proxy'; hostName = 'claude.contoso.test' }
        @($patch.properties.hostnameConfigurations).Count -eq 3 -and @($patch.properties.hostnameConfigurations | Where-Object hostName -eq 'old.contoso.test').Count -eq 0
    }
    Check 'a misspelled replacement is refused instead of ignoring it' { Reject { New-Plan @{ ReplaceHostname = 'typo.contoso.test' } } 'replacement' }
    Check 'Premium v2 retains another custom gateway hostname' {
        $script:live.sku.name = 'PremiumV2'
        $p = New-Plan
        $patch = Get-ClaudeAddressHostnamePatch -Gateway $script:live -Plan $p -Binding @{ type = 'Proxy'; hostName = 'claude.contoso.test' }
        @($patch.properties.hostnameConfigurations | Where-Object hostName -eq 'old.contoso.test').Count -eq 1
    }
    Reset-State
    Check 'DNS is priced at the first tier of global public meters' {
        $p = New-Plan
        @($script:priceCalls | Where-Object { $_.Service -eq 'Azure DNS' -and $_.Region -eq '' -and $_.Tier -eq 'First' -and $_.Sku -eq 'Public' }).Count -eq 2 -and
            @($p.Costs | Where-Object { $_.UnitPrice -eq [decimal]0.50 }).Count -eq 1 -and
            @($p.Costs | Where-Object { $_.UnitPrice -eq [decimal]0.40 }).Count -eq 1
    }
    Check 'Key Vault operations and optional renewal are not a monthly HSM fee' {
        $p = New-Plan
        @($p.Costs | Where-Object { $_.UnitPrice -eq [decimal]0.03 -and $null -eq $_.MonthlyUsd }).Count -eq 1 -and
            @($p.Costs | Where-Object { $_.UnitPrice -eq 3 -and $null -eq $_.MonthlyUsd }).Count -eq 1 -and
            ($p.Costs | ConvertTo-Json) -notmatch 'Standard Instance'
    }
    Check 'an unknown retail price never becomes a zero quote' {
        $script:missingPrice = $true
        $p = New-Plan
        $script:missingPrice = $false
        @($p.Costs | Where-Object { $_.Source -eq 'Azure Retail Prices API' -and $null -eq $_.UnitPrice -and $null -eq $_.MonthlyUsd -and $_.UnknownReason }).Count -eq 4
    }
    Check 'external DNS prints a complete record and does not invent a provider price' {
        $p = New-Plan @{ DnsZoneResourceId = '' }
        $text = Format-ClaudeFlowReview @($p)
        $text -match 'claude.contoso.test' -and $text -match 'CNAME' -and $text -match 'apim-contoso.azure-api.net' -and
            @($p.Costs | Where-Object { $_.Item -match 'external DNS' -and $null -eq $_.MonthlyUsd }).Count -eq 1
    }
    Check 'hostname and certificate reference both change the approval fingerprint' {
        $a = Get-ClaudeFlowFingerprint @(New-Plan)
        $b = Get-ClaudeFlowFingerprint @(New-Plan @{ Hostname = 'other.contoso.test' })
        $c = Get-ClaudeFlowFingerprint @(New-Plan @{ KeyVaultCertificateId = 'https://kv-contoso.vault.azure.net/certificates/other' })
        $a -ne $b -and $a -ne $c
    }
    Check 'the plan contains no PFX bytes or password' { (New-Plan | ConvertTo-Json -Depth 30) -notmatch 'encodedCertificate|certificatePassword' }
    Check 'a hostname patch does not PUT or restate service properties' {
        $p = New-Plan
        $patch = Get-ClaudeAddressHostnamePatch -Gateway $script:live -Plan $p -Binding @{ type = 'Proxy'; hostName = 'claude.contoso.test' }
        @($patch.Keys).Count -eq 1 -and @($patch.properties.Keys).Count -eq 1 -and $patch.properties.Contains('hostnameConfigurations')
    }
    Check 'unrelated portal certificate settings survive exactly' {
        $p = New-Plan
        $patch = Get-ClaudeAddressHostnamePatch -Gateway $script:live -Plan $p -Binding @{ type = 'Proxy'; hostName = 'claude.contoso.test' }
        (ConvertTo-ClaudeFlowCanonical $patch.properties.hostnameConfigurations[1]) -eq (ConvertTo-ClaudeFlowCanonical $script:live.properties.hostnameConfigurations[1])
    }
    Check 'changed hostname state invalidates an approved plan before writes' {
        $p = New-Plan
        $script:live.properties.hostnameConfigurations[1].hostName = 'different.contoso.test'
        (Reject { Apply-Plan $p } 'changed|drift') -and $script:writes.Count -eq 0
    }
    Reset-State
    Check 'a changed certificate invalidates approval before writes' {
        $p = New-Plan
        $script:cert.Thumbprint = 'DIFFERENT'
        (Reject { Apply-Plan $p } 'certificate.*changed') -and $script:writes.Count -eq 0
    }
    Reset-State
    Check 'an APIM write failure leaves the recorded address unchanged' {
        $p = New-Plan; $script:patchFails = $true
        (Reject { Apply-Plan $p } 'APIM write refused') -and ((Read-ClaudeDecisionRecord $recordPath).gatewayUrl -eq $script:record.gatewayUrl)
    }
    Reset-State
    Check 'a failed provisioning state is not mistaken for ready' {
        $p = New-Plan; $script:patchState = 'Failed'
        (Reject { Apply-Plan $p } 'Failed') -and ((Read-ClaudeDecisionRecord $recordPath).gatewayUrl -eq $script:record.gatewayUrl)
    }
    Reset-State
    Check 'DNS timeout reports failure and does not publish the company URL' {
        $p = New-Plan; $script:dnsMatches = $false
        (Reject { Apply-Plan $p } 'DNS.*timed out|timed out.*DNS') -and ((Read-ClaudeDecisionRecord $recordPath).gatewayUrl -eq $script:record.gatewayUrl)
    }
    foreach ($case in 'status','certificate','trust') {
        Reset-State
        Check "HTTPS $case failure does not publish the company URL" {
            $p = New-Plan
            switch ($case) { status { $script:tlsStatus = 404 } certificate { $script:tlsThumbprint = 'WRONG' } trust { $script:tlsTrusted = $false } }
            (Reject { Apply-Plan $p } 'HTTPS|certificate|trust|401') -and ((Read-ClaudeDecisionRecord $recordPath).gatewayUrl -eq $script:record.gatewayUrl)
        }
    }
    Reset-State
    Check 'successful binding waits, proves and publishes in that order' {
        $p = New-Plan
        $result = Apply-Plan $p
        $after = Read-ClaudeDecisionRecord $recordPath
        $script:events -join ',' -eq 'grant,binding,dns,proof' -and $after.gatewayUrl -eq 'https://claude.contoso.test/claude' -and
            $result.GatewayUrl -eq $after.gatewayUrl -and $after.unknownField.survives -eq 'yes' -and @($after.history).Count -eq 1
    }
    Check 'the gateway read permission is the narrowly named Secrets User role' {
        $grant = @($script:writes | Where-Object Url -match '/roleAssignments/')[0]
        $grant.Body.properties.roleDefinitionId -like '*/4633458b-17de-408a-b874-0445c86b69e6' -and
            $grant.Body.properties.principalId -eq '00000000-0000-0000-0000-000000000002'
    }
    Check 'new DNS records use conditional creation' { @($script:writes | Where-Object { $_.Url -match '/CNAME/' -and $_.IfNoneMatch }).Count -eq 1 }
    Check 'the APIM update uses PATCH and leaves network settings unchanged' {
        @($script:writes | Where-Object { $_.Url -match '/Microsoft.ApiManagement/service/' -and $_.Method -eq 'patch' }).Count -eq 1 -and
            $script:live.properties.publicNetworkAccess -eq 'Disabled' -and $script:live.properties.virtualNetworkType -eq 'External'
    }
    Reset-State
    Check 'an existing DNS record retains TTL and metadata with its etag' {
        $script:dnsRecord = [pscustomobject]@{ etag = 'before'; properties = @{ TTL = 900; metadata = @{ owner = 'platform' }; CNAMERecord = @{ cname = 'previous.azure-api.net' } } }
        $p = New-Plan; Apply-Plan $p | Out-Null
        $write = @($script:writes | Where-Object Url -match '/CNAME/')[0]
        $write.IfMatch -eq 'before' -and $write.Body.properties.TTL -eq 900 -and $write.Body.properties.metadata.owner -eq 'platform'
    }
    Reset-State
    Check 'an intervening DNS edit is not overwritten' {
        $p = New-Plan
        $script:dnsRecord = [pscustomobject]@{ etag = 'someone-else'; properties = @{ TTL = 300; CNAMERecord = @{ cname = 'someone-else.azure-api.net' } } }
        (Reject { Apply-Plan $p } 'DNS.*changed') -and @($script:writes | Where-Object Url -match '/CNAME/').Count -eq 0
    }
    Reset-State
    Check 'access-policy grants preserve existing secret permissions' {
        $script:vault.properties.enableRbacAuthorization = $false; $script:cert.Rbac = $false
        $script:vault.properties.accessPolicies = @(@{ tenantId = $sub; objectId = $script:live.identity.principalId; permissions = @{ secrets = @('set'); keys = @('get'); certificates = @('get') } })
        $p = New-Plan; Apply-Plan $p | Out-Null
        $grant = @($script:writes | Where-Object Url -match '/accessPolicies/add')[0]
        $grant.Body.properties.accessPolicies[0].permissions.secrets -contains 'set' -and
            $grant.Body.properties.accessPolicies[0].permissions.secrets -contains 'get' -and
            $grant.Body.properties.accessPolicies[0].permissions.secrets -contains 'list' -and
            $grant.Body.properties.accessPolicies[0].permissions.keys -contains 'get'
    }
    Reset-State
    Check 'existing generated profiles change the URL, not unrelated settings' {
        $profile = Join-Path $scratch 'profiles\standard'
        New-Item -ItemType Directory -Path $profile -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $profile 'managed-settings.json'), '{"env":{"ANTHROPIC_FOUNDRY_BASE_URL":"https://apim-contoso.azure-api.net/claude"},"custom":"retained"}')
        [IO.File]::WriteAllText((Join-Path $scratch 'HOW-TO-USE.md'), 'Gateway: https://apim-contoso.azure-api.net/claude')
        Apply-Plan (New-Plan) | Out-Null
        $text = [IO.File]::ReadAllText((Join-Path $profile 'managed-settings.json'))
        $text -match 'https://claude.contoso.test/claude' -and $text -match '"custom":"retained"' -and
            [IO.File]::ReadAllText((Join-Path $scratch 'HOW-TO-USE.md')) -match 'https://claude.contoso.test/claude'
    }
    Reset-State
    Check 'a record naming another gateway is refused before any write' {
        $script:record.apimName = 'other'; Write-ClaudeDecisionRecord $script:record $recordPath
        (Reject { Apply-Plan (New-Plan) } 'record.*gateway') -and $script:writes.Count -eq 0
    }
    Reset-State
    Check 'self-signed proof is explicit, restricted and cannot publish the record' {
        $p = New-Plan @{ IsolatedProof = $true; DnsServer = 'ns1.example.test'; ConnectAddress = '192.0.2.1' }
        $script:tlsTrusted = $false
        $before = [IO.File]::ReadAllText($recordPath)
        Apply-Plan $p | Out-Null
        [IO.File]::ReadAllText($recordPath) -eq $before
    }
    Check 'test-only TLS cannot be used for a production hostname' { Reject { New-Plan @{ Hostname = 'claude.contoso.com'; DnsZoneResourceId = ''; IsolatedProof = $true; DnsServer = 'ns1.example.test'; ConnectAddress = '192.0.2.1' } } 'test' }
    Check 'a connect-IP override requires isolated proof mode' { Reject { New-Plan @{ ConnectAddress = '192.0.2.1' } } 'IsolatedProof' }
    Check 'a timed wait says condition, estimate and elapsed time' {
        $log = @(Wait-ClaudeAddress -Condition 'DNS test' -About 'about 1 minute' -TimeoutSeconds 0 -PollSeconds 0 -Check { @{ Done = $true; Value = 'ready'; Status = 'ready' } } 6>&1) -join "`n"
        $log -match 'DNS test' -and $log -match 'about 1 minute' -and $log -match 'in [0-9.,]+ s'
    }
    Check 'a timeout says how long it waited and never returns a success value' {
        Reject { Wait-ClaudeAddress -Condition 'DNS test' -About 'about 1 minute' -TimeoutSeconds 0 -PollSeconds 0 -Check { @{ Done = $false; Status = 'not yet' } } } 'DNS test.*timed out after'
    }

    $installer = Get-Content -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
    Check 'the installer exposes address and transient certificate inputs' { $installer -match '\$AddressMode' -and $installer -match '\$AddressHostname' -and $installer -match '\[securestring\]\$AddressCertificatePassword' }
    Check 'the installer plans the address before its summary' { $installer.IndexOf('Get-ClaudeAddressPlan') -gt 0 -and $installer.IndexOf('Get-ClaudeAddressPlan') -lt $installer.IndexOf("Write-Head 'Summary'") }
    Check 'the installer applies only after its deployment succeeds' { $installer.IndexOf('Invoke-ClaudeAddressPlan') -gt $installer.IndexOf("throw 'Deployment failed.") -and $installer.IndexOf('Invoke-ClaudeAddressPlan') -lt $installer.IndexOf("Write-Head 'Done'") }
    Check 'the installer no longer prints unimplemented company-address instructions' { $installer -notmatch 'Nothing here configured it|hostnameConfigurations=\.\.\.' }
    Check 'template-owned redeploys preserve custom hostname configurations' {
        $bicep = Get-Content -LiteralPath (Join-Path $root 'infra\main.bicep') -Raw
        $installer -match 'apimHostnameConfigurations.*value' -and $bicep -match 'hostnameConfigurations: apimHostnameConfigurations'
    }
    $step = Join-Path $root 'scripts\flow\Address.ps1'
    Check 'the address is a Change-only step with all five contracts' {
        . $step
        $info = Get-ClaudeFlowStepInfo
        $info.Name -eq 'Address' -and $info.DecisionKey -eq 'address' -and @($info.Actions).Count -eq 1 -and $info.Actions[0] -eq 'Change' -and
            (Get-Command Get-ClaudeFlowStepQuestions) -and (Get-Command Get-ClaudeFlowStepPlan) -and (Get-Command Invoke-ClaudeFlowStep) -and (Get-Command Test-ClaudeFlowStep)
    }
    Check 'the flow has transient password and text-question plumbing' {
        $start = Get-Content -LiteralPath (Join-Path $root 'Start-ClaudeGateway.ps1') -Raw
        $start -match '\[securestring\]\$AddressCertificatePassword' -and $start -match "Type -eq 'Text'"
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Write-Host ("Company address: {0} assertions, {1} passed, {2} failed." -f $script:assertions, ($script:assertions - $script:failed), $script:failed)
if ($script:failed) { exit 1 }
