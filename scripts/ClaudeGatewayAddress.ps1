# Shared plan/apply implementation for the installer and Address flow step (ADR-0033).
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'ClaudeNetwork.ps1')
. (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')
. (Join-Path $PSScriptRoot 'ClaudeGatewayCertificate.ps1')
. (Join-Path $PSScriptRoot 'ClaudeGatewayAddressRecovery.ps1')
. (Join-Path $PSScriptRoot 'ClaudeGatewayAddressWait.ps1')

function Get-ClaudeAddressHostState {
    param($Gateway)
    # Built-in certificate rotation is independent of the company's approval.
    $custom = @($Gateway.properties.hostnameConfigurations | Where-Object { $_.certificateSource -ne 'BuiltIn' })
    ConvertTo-ClaudeFlowCanonical $custom
}

function Get-ClaudeAddressCosts {
    param([string]$DnsZoneResourceId, [string]$CertificateSource, [string]$Region)
    New-ClaudeFlowCost -Item 'APIM custom hostname; existing gateway tier charge continues' -MonthlyUsd 0 -Source 'https://learn.microsoft.com/azure/api-management/configure-custom-domain'
    $meters = @()
    if ($DnsZoneResourceId) {
        $meters += @(
            @{ Service = 'Azure DNS'; Region = ''; Sku = 'Public'; Meter = 'Public Zone'; Item = 'Azure DNS existing public zone (already billed; no new zone)'; Fixed = $true }
            @{ Service = 'Azure DNS'; Region = ''; Sku = 'Public'; Meter = 'Public Queries'; Item = 'Azure DNS public queries'; Fixed = $false }
        )
    }
    else { New-ClaudeFlowCost -Item 'External DNS provider' -Source 'Selected DNS provider' -UnknownReason 'The provider prices its existing zone and queries; not an Azure DNS charge.' }
    if ($CertificateSource -eq 'KeyVault') {
        $meters += @(
            @{ Service = 'Key Vault'; Region = $Region; Sku = 'Standard'; Meter = 'Operations'; Item = 'Key Vault certificate/secret operations'; Fixed = $false }
            @{ Service = 'Key Vault'; Region = $Region; Sku = 'Standard'; Meter = 'Certificate Renewal Request'; Item = 'Key Vault renewal requests, only with integrated CA renewal'; Fixed = $false }
        )
    }
    foreach ($m in $meters) {
        $price = Get-AzureRetailPrice -ServiceName $m.Service -Region $m.Region -MeterName $m.Meter -SkuName $m.Sku -ProductName $m.Service -Tier First
        $monthly = $null
        $rate = $null; $unit = ''
        $read = ''
        $reason = "No retail meter could be read for $($m.Meter); price unknown."
        $item = $m.Item
        if ($price) {
            $rate = $price.UnitPrice; $unit = $price.UnitOfMeasure; $read = $price.RetrievedUtc
            $item += " - USD $rate / $unit$(if ($m.Meter -eq 'Public Zone') { ' zone-month, first 25 zones' })"
            $reason = 'Usage-dependent; the monthly quantity is not known.'
            if ($m.Fixed) { $monthly = [decimal]0; $reason = '' }
        }
        $cost = New-ClaudeFlowCost -Item $item -MonthlyUsd $monthly -Source 'Azure Retail Prices API' -RetrievedUtc $read -UnknownReason $reason
        $cost | Add-Member -NotePropertyName UnitPrice -NotePropertyValue $rate
        $cost | Add-Member -NotePropertyName UnitOfMeasure -NotePropertyValue $unit
        $cost
    }
    New-ClaudeFlowCost -Item 'Supplied certificate and domain registration' -Source 'Certificate issuer and domain registrar' -UnknownReason 'Provider-dependent; no domain purchase or public certificate issuance is performed here.'
}

function Get-ClaudeAddressPlan {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId, [string]$ResourceGroup, [string]$ApimName, [string]$Hostname,
        [string]$CertificateSource, [string]$KeyVaultCertificateId, [string]$PfxPath,
        [securestring]$CertificatePassword, [string]$DnsZoneResourceId, [string]$ReplaceHostname,
        $Gateway, [switch]$IsolatedProof, [string]$DnsServer, [string]$ConnectAddress
    )
    if (-not (Test-ClaudeFlowSubscriptionId $SubscriptionId)) { throw 'A subscription ID is required for the company address.' }
    if ($ResourceGroup -notmatch '^[a-zA-Z0-9._-]{1,90}$') { throw 'The resource group must use letters, digits, dots, underscores or hyphens.' }
    if ($ApimName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,48}[a-zA-Z0-9]$') { throw 'The API Management name is invalid.' }
    $ip = $null
    if ($Hostname.Length -gt 253 -or $Hostname -notmatch '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z][a-zA-Z0-9-]{1,62}$' -or [Net.IPAddress]::TryParse($Hostname, [ref]$ip)) {
        throw 'The company hostname must be a DNS hostname, not a URL, IP, wildcard or command.'
    }
    $Hostname = $Hostname.ToLowerInvariant()
    if ($CertificateSource -notin @('KeyVault','Pfx')) { throw 'Free managed certificates are not supported on API Management v2; use KeyVault or Pfx.' }
    if (($ConnectAddress -or $DnsServer) -and -not $IsolatedProof) { throw 'DNS-server and connect-IP overrides require IsolatedProof.' }
    if ($IsolatedProof -and ($Hostname -notlike '*.test' -or -not $DnsServer -or -not [Net.IPAddress]::TryParse($ConnectAddress, [ref]$ip))) {
        throw 'Isolated proof requires a reserved .test hostname, explicit DNS server and connect IP; it cannot publish a production address.'
    }
    $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
    if (-not $Gateway) {
        $Gateway = Wait-ClaudeAddress -Condition "gateway metadata $ResourceGroup/$ApimName" -About 'about 4 s' -TimeoutSeconds 45 -Arguments @($id) -Check {
            param($id)
            @{ Done = $true; Value = (Invoke-ClaudeNetworkArm "https://management.azure.com${id}?api-version=2024-05-01") }
        }
    }
    if ($Gateway.id -ine $id) { throw 'The discovered gateway does not match the selected subscription and resource.' }
    $sku = [string]$Gateway.sku.name
    if ($sku -notin @('BasicV2','StandardV2','PremiumV2')) { throw 'The company address path requires an API Management v2 tier.' }
    if ($IsolatedProof -and $sku -ne 'BasicV2') { throw 'Isolated proof without public DNS is restricted to Basic v2.' }
    if ($Gateway.properties.provisioningState -ne 'Succeeded') { throw "Gateway provisioning state is '$($Gateway.properties.provisioningState)', not Succeeded; wait for its current operation before planning." }
    $other = @($Gateway.properties.hostnameConfigurations | Where-Object { $_.type -eq 'Proxy' -and $_.certificateSource -ne 'BuiltIn' -and $_.hostName -ine $Hostname })
    if ($ReplaceHostname -and @($other | Where-Object hostName -eq $ReplaceHostname).Count -ne 1) { throw 'The named replacement hostname is not a different live custom Proxy hostname.' }
    if ($sku -ne 'PremiumV2' -and @($other | Where-Object { $_.hostName -ine $ReplaceHostname }).Count) {
        throw "$sku has another custom gateway hostname. An explicit ReplaceHostname is required; its callers will need new settings."
    }
    $dns = @{ Name = $Hostname; Target = "$ApimName.azure-api.net"; Id = ''; Before = $null }
    if ($DnsZoneResourceId) {
        if ($DnsZoneResourceId -notmatch '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/([a-zA-Z0-9._-]{1,90})/providers/Microsoft.Network/dnsZones/([a-zA-Z0-9.-]+)$') { throw 'An Azure public DNS zone resource ID is required, not a private DNS zone.' }
        if ($Matches[1] -ine $SubscriptionId) { throw 'The Azure DNS zone must be in the selected subscription.' }
        $zoneName = $Matches[3].ToLowerInvariant()
        if ($Hostname -ieq $zoneName) { throw 'A CNAME cannot be created at the DNS zone apex.' }
        if (-not $Hostname.EndsWith(".$zoneName", [StringComparison]::OrdinalIgnoreCase)) { throw 'The hostname is not below the selected DNS zone.' }
        $zone = Invoke-ClaudeAddressArm "https://management.azure.com${DnsZoneResourceId}?api-version=2018-05-01"
        if (-not $zone -or $zone.id -ine $DnsZoneResourceId) { throw 'The selected DNS zone could not be read.' }
        $dns.Name = $Hostname.Substring(0, $Hostname.Length - $zoneName.Length - 1)
        $dns.Id = "$DnsZoneResourceId/CNAME/$($dns.Name)"
        $dns.Before = Invoke-ClaudeAddressArm "https://management.azure.com$($dns.Id)?api-version=2018-05-01" -AllowNotFound
        if ($dns.Before -and -not $dns.Before.etag) { throw 'The existing DNS record has no etag; refusing an unconditional overwrite.' }
    }
    $certificateArgs=@{CertificateSource=$CertificateSource;KeyVaultCertificateId=$KeyVaultCertificateId;PfxPath=$PfxPath;CertificatePassword=$CertificatePassword;Hostname=$Hostname;SubscriptionId=$SubscriptionId}
    $certificate = Wait-ClaudeAddress -Condition 'certificate metadata and hostname validation' -About 'about 5 s' -TimeoutSeconds 60 -Arguments @($certificateArgs) -Check {
        param($values)
        @{ Done = $true; Value = (Read-ClaudeAddressCertificate @values) }
    }
    $actions = @()
    if ($CertificateSource -eq 'KeyVault') { $actions += New-ClaudeFlowAction -Verb Grant -Target $certificate.VaultId -Detail 'Gateway system-assigned identity: Key Vault Secrets User, or additive secret get/list access policy; networking unchanged.' }
    $actions += New-ClaudeFlowAction -Verb Update -Target $id -Detail "Bind Proxy hostname $Hostname; retain other hostname and service properties.$(if ($ReplaceHostname) { " Replace only $ReplaceHostname; its callers must be reconfigured." })"
    $dnsDetail = "$Hostname CNAME $($dns.Target); TTL $(if ($dns.Before) { $dns.Before.properties.TTL } else { 300 }) s. No APIM managed-certificate TXT record."
    $dnsAction = New-ClaudeFlowAction -Verb $(if ($DnsZoneResourceId) { if ($dns.Before) { 'Update' } else { 'Create' } } else { 'Check' }) -Target $(if ($dns.Id) { $dns.Id } else { 'External DNS provider' }) -Detail $dnsDetail
    $actions = @($dnsAction) + @($actions)
    $actions += New-ClaudeFlowAction -Verb Check -Target "https://$Hostname/claude/v1/messages" -Detail 'DNS, configured certificate with SNI/Host, and unauthenticated gateway HTTP 401 before publishing.'
    $costs = @(Wait-ClaudeAddress -Condition 'company-address list prices' -About 'about 5 s' -TimeoutSeconds 180 -Arguments @($DnsZoneResourceId,$CertificateSource,$Gateway.location) -Check {
        param($zone,$source,$region)
        @{ Done = $true; Value = @(Get-ClaudeAddressCosts -DnsZoneResourceId $zone -CertificateSource $source -Region $region) }
    })
    New-ClaudeFlowPlan -Step Address -Summary "Configure and prove https://$Hostname/claude" -Actions $actions -Costs $costs `
        -Requires @('API Management Service Contributor', 'DNS Zone Contributor on the selected Azure DNS zone, or a DNS provider operator', 'For Key Vault: permission to assign Secrets User or amend the vault access policy') `
        -Implications @('No free managed certificate exists on v2; the certificate and domain are supplied.', 'APIM update: about 5-15 minutes, sometimes longer; DNS: about 1-10 minutes, provider TTL dependent.', 'A failed DNS/TLS proof leaves the old recorded URL; already-configured devices need redistributed settings.', $(if ($IsolatedProof) { 'ISOLATED PROOF: authoritative DNS and pinned self-signed TLS only; no public delegation/trust and no record publication.' } else { 'Normal DNS resolution and a trusted, matching TLS certificate are required.' })) `
        -Rollback 'The Azure hostname remains available. Reapply the previous certificate/hostname and DNS record with a reviewed plan; redistribute the previous client record if it was published.' `
        -Data @{
            SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; ApimName = $ApimName; GatewayId = $id
            Sku = $sku; Region = $Gateway.location; Hostname = $Hostname; ReplaceHostname = $ReplaceHostname
            CertificateSource = $CertificateSource; KeyVaultCertificateId = $KeyVaultCertificateId; PfxPath = $PfxPath; Certificate = $certificate
            HostnameBaseline = (Get-ClaudeAddressHostState $Gateway); DnsZoneResourceId = $DnsZoneResourceId; DnsRecord = $dns
            IsolatedProof = [bool]$IsolatedProof; DnsServer = $DnsServer; ConnectAddress = $ConnectAddress
        }
}

function Get-ClaudeAddressHostnamePatch {
    param($Gateway, $Plan, $Binding)
    $hosts = @($Gateway.properties.hostnameConfigurations | Where-Object {
        -not ($_.type -eq 'Proxy' -and ($_.hostName -ieq $Plan.Data.Hostname -or ($Plan.Data.ReplaceHostname -and $_.hostName -ieq $Plan.Data.ReplaceHostname)))
    })
    @{ properties = @{ hostnameConfigurations = @($hosts) + @($Binding) } }
}

function Grant-ClaudeAddressCertificateRead {
    param($Gateway, $Plan, [double]$TimeoutSeconds, [double]$PollSeconds)
    $d = $Plan.Data
    $uri = "https://management.azure.com$($d.GatewayId)?api-version=2024-05-01"
    if (-not $Gateway.identity.principalId -or $Gateway.identity.type -notmatch 'SystemAssigned') {
        $identity = @{ type = 'SystemAssigned' }
        if ($Gateway.identity.userAssignedIdentities) { $identity.type = 'SystemAssigned, UserAssigned'; $identity.userAssignedIdentities = $Gateway.identity.userAssignedIdentities }
        Invoke-ClaudeAddressArm $uri -Method patch -Body @{ identity = $identity } -StateDirectory ([IO.Path]::GetTempPath()) | Out-Null
        $Gateway = Wait-ClaudeAddress -Condition 'gateway managed identity' -About 'about 1-5 minutes' -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -Arguments @($uri) -Check {
            param($uri)
            $g = Invoke-ClaudeNetworkArm $uri
            if ($g.properties.provisioningState -in @('Failed','Canceled')) { throw "Gateway managed identity update $($g.properties.provisioningState)." }
            @{ Done = ($g.properties.provisioningState -eq 'Succeeded' -and [bool]$g.identity.principalId); Value = $g; Status = $g.properties.provisioningState }
        }
    }
    $vault = Invoke-ClaudeAddressArm "https://management.azure.com$($d.Certificate.VaultId)?api-version=2023-07-01"
    if ([bool]$vault.properties.enableRbacAuthorization -ne [bool]$d.Certificate.Rbac) { throw 'Key Vault permission model changed since review.' }
    $principal = [string]$Gateway.identity.principalId
    if ($vault.properties.enableRbacAuthorization) {
        $role = "/subscriptions/$($d.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
        $assignments = Wait-ClaudeAddress -Condition 'Key Vault role assignments' -About 'about 4 s' -TimeoutSeconds 45 -Arguments @("https://management.azure.com$($vault.id)/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01") -Check {
            param($uri)
            @{Done=$true;Value=(Get-ClaudeNetworkPages $uri)}
        }
        if (@($assignments | Where-Object { $_.properties.principalId -eq $principal -and $_.properties.roleDefinitionId -eq $role }).Count) { return $Gateway }
        $name = Get-ClaudeNetworkStableGuid "$($vault.id)|$principal|$role"
        $grantUri = "https://management.azure.com$($vault.id)/providers/Microsoft.Authorization/roleAssignments/${name}?api-version=2022-04-01"
        Invoke-ClaudeAddressArm $grantUri -Method put -Body @{ properties = @{ roleDefinitionId = $role; principalId = $principal; principalType = 'ServicePrincipal' } } -StateDirectory ([IO.Path]::GetTempPath()) | Out-Null
    }
    else {
        $old = @($vault.properties.accessPolicies | Where-Object { $_.objectId -eq $principal })
        if ($old.Count -gt 1) { throw 'Multiple Key Vault access policies name the gateway identity; review them before changing access.' }
        $permissions = @{ secrets = @('get','list') }
        if ($old.Count) {
            foreach ($p in $old[0].permissions.PSObject.Properties) { $permissions[$p.Name] = @($p.Value) }
            $permissions.secrets = @(@($permissions.secrets) + @('get','list') | Select-Object -Unique)
        }
        $policy = @{ tenantId = $vault.properties.tenantId; objectId = $principal; permissions = $permissions }
        if ($old.Count -and $old[0].applicationId) { $policy.applicationId = $old[0].applicationId }
        Invoke-ClaudeAddressArm "https://management.azure.com$($vault.id)/accessPolicies/add?api-version=2023-07-01" -Method put -Body @{ properties = @{ accessPolicies = @($policy) } } -StateDirectory ([IO.Path]::GetTempPath()) | Out-Null
    }
    return $Gateway
}

function Update-ClaudeAddressArtifacts {
    param([string]$RecordPath, [string]$OldUrl, [string]$NewUrl)
    if (-not $OldUrl -or $OldUrl -eq $NewUrl) { return }
    $dir = Split-Path -Parent $RecordPath
    $files = @()
    $directories = New-Object 'Collections.Generic.Queue[string]'
    $directories.Enqueue($dir)
    $profiles = Join-Path $dir 'profiles'
    while ($directories.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $directories.Dequeue()) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $directories.Enqueue($item.FullName); continue }
            $isProfile = $item.FullName.StartsWith($profiles + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            if ($item.FullName -ne [IO.Path]::GetFullPath($RecordPath) -and
                ($item.Name -eq 'HOW-TO-USE.md' -or $item.Name -eq 'claude-gateway.json' -or
                ($item.Name -like 'onboarding-*' -and $item.Extension -in @('.html','.txt','.eml')) -or
                ($isProfile -and $item.Extension -in @('.json','.xml','.mobileconfig','.reg','.ps1','.sh','.md','.txt','.html')))) { $files += $item }
        }
    }
    foreach ($file in $files) {
        $text = [IO.File]::ReadAllText($file.FullName)
        $updated = $text.Replace($OldUrl, $NewUrl)
        if ($file.Extension -eq '.eml' -and $text -match '(?is)^(.*?Content-Transfer-Encoding:\s*base64[^\r\n]*\r?\n\r?\n)([a-zA-Z0-9+/=\s]+)$') {
            $header = $Matches[1]
            $html = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($Matches[2] -replace '\s','')))
            if ($html.Contains($OldUrl)) {
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($html.Replace($OldUrl, $NewUrl)))
                $updated = $header + [regex]::Replace($encoded, '.{1,76}', { param($m) $m.Value + "`r`n" })
            }
        }
        if ($updated -eq $text) { continue }
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $encoding = New-Object Text.UTF8Encoding($false)
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) { $encoding = [Text.Encoding]::Unicode }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) { $encoding = [Text.Encoding]::BigEndianUnicode }
        elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $encoding = New-Object Text.UTF8Encoding($true) }
        [IO.File]::WriteAllText($file.FullName, $updated, $encoding)
        Write-Host "  Updated generated address in $($file.Name)."
    }
}

function Invoke-ClaudeAddressPlan {
    [CmdletBinding()]
    param($Plan, [securestring]$CertificatePassword, [string]$RecordPath, [double]$TimeoutSeconds = 2700, [double]$DnsTimeoutSeconds = 600, [double]$PollSeconds = 15)
    $d = $Plan.Data
    $record = if ($RecordPath) { Read-ClaudeDecisionRecord $RecordPath } else { $null }
    if ($record -and ($record.apimName -ine $d.ApimName -or $record.resourceGroup -ine $d.ResourceGroup -or ($record.subscriptionId -and $record.subscriptionId -ine $d.SubscriptionId))) {
        throw 'The record names a different gateway; no company-address write was made.'
    }
    $uri = "https://management.azure.com$($d.GatewayId)?api-version=2024-05-01"
    $gateway = Invoke-ClaudeAddressArm $uri
    if ($gateway.properties.provisioningState -ne 'Succeeded') { throw "Gateway provisioning is $($gateway.properties.provisioningState); review again after it completes." }
    if ((Get-ClaudeAddressHostState $gateway) -ne $d.HostnameBaseline -or $gateway.sku.name -ne $d.Sku) { throw 'Gateway hostname state or tier changed since review; no write was made.' }
    $pfxBytes = if ($d.CertificateSource -eq 'Pfx') { [IO.File]::ReadAllBytes($d.PfxPath) } else { $null }
    $certificateArgs=@{CertificateSource=$d.CertificateSource;KeyVaultCertificateId=$d.KeyVaultCertificateId;PfxPath=$d.PfxPath;PfxBytes=$pfxBytes;CertificatePassword=$CertificatePassword;Hostname=$d.Hostname;SubscriptionId=$d.SubscriptionId}
    $cert = Wait-ClaudeAddress -Condition 'reviewed certificate metadata' -About 'about 5 s' -TimeoutSeconds 60 -Arguments @($certificateArgs) -Check {
        param($values)
        @{Done=$true;Value=(Read-ClaudeAddressCertificate @values)}
    }
    if ($cert.Thumbprint -ne $d.Certificate.Thumbprint -or $cert.PfxSha256 -ne $d.Certificate.PfxSha256 -or $cert.SecretId -ne $d.Certificate.SecretId) { throw 'The certificate changed since review; no write was made.' }
    $dnsUri = if ($d.DnsRecord.Id) { "https://management.azure.com$($d.DnsRecord.Id)?api-version=2018-05-01" } else { '' }
    if ($dnsUri) {
        $currentDns = Invoke-ClaudeAddressArm $dnsUri -AllowNotFound
        if ((ConvertTo-ClaudeFlowCanonical $currentDns) -ne (ConvertTo-ClaudeFlowCanonical $d.DnsRecord.Before)) { throw 'DNS record changed since review; no write was made.' }
    }
    if ($record -and -not $d.IsolatedProof) {
        Set-ClaudeRecordProperty $record pendingAddress (New-ClaudeAddressRecoveryReceipt -Record $record -Gateway $gateway -Plan $Plan)
        Write-ClaudeDecisionRecord -Record $record -Path $RecordPath
    }
    if ($dnsUri) {
        $properties = @{ TTL = 300; CNAMERecord = @{ cname = $d.DnsRecord.Target } }
        $condition = @{ IfNoneMatch = $true }
        if ($d.DnsRecord.Before) {
            $properties.TTL = $d.DnsRecord.Before.properties.TTL
            if ($d.DnsRecord.Before.properties.metadata) { $properties.metadata = $d.DnsRecord.Before.properties.metadata }
            $condition = @{ IfMatch = $d.DnsRecord.Before.etag }
        }
        Invoke-ClaudeAddressArm $dnsUri -Method put -Body @{ properties = $properties } -StateDirectory ([IO.Path]::GetTempPath()) @condition | Out-Null
    }
    else { Write-Host "External DNS record: $($d.Hostname) 300 IN CNAME $($d.DnsRecord.Target)." }
    Wait-ClaudeAddress -Condition "DNS CNAME $($d.Hostname)" -About 'about 1-10 minutes; provider TTL dependent' -TimeoutSeconds $DnsTimeoutSeconds -PollSeconds $PollSeconds -Arguments @($d) -Check {
        param($d)
        $args = @{ Name = $d.Hostname; Type = 'CNAME'; DnsOnly = $true; NoHostsFile = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
        if ($d.DnsServer) { $args.Server = $d.DnsServer }
        $matchesDns = $false; $reason = 'CNAME is not the planned gateway'
        try {
            $answers = @(Resolve-DnsName @args)
            $matchesDns = @($answers | Where-Object { $_.Name.TrimEnd('.') -ieq $d.Hostname -and $_.NameHost -and $_.NameHost.TrimEnd('.') -ieq $d.DnsRecord.Target }).Count -gt 0
        }
        catch { $reason = "DNS resolver: $($_.Exception.Message)" }
        @{ Done = $matchesDns; Status = $reason }
    } | Out-Null
    if ($d.CertificateSource -eq 'KeyVault') { $gateway = Grant-ClaudeAddressCertificateRead -Gateway $gateway -Plan $Plan -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds }
    $binding = @{ type = 'Proxy'; hostName = $d.Hostname; defaultSslBinding = $false; negotiateClientCertificate = $false }
    $currentBinding = @($gateway.properties.hostnameConfigurations | Where-Object { $_.type -eq 'Proxy' -and $_.hostName -eq $d.Hostname })
    if ($currentBinding.Count) {
        $binding.defaultSslBinding = [bool]$currentBinding[0].defaultSslBinding
        $binding.negotiateClientCertificate = [bool]$currentBinding[0].negotiateClientCertificate
    }
    $bindingMatches = $currentBinding.Count -eq 1 -and $currentBinding[0].certificate.thumbprint -ieq $cert.Thumbprint -and
        $currentBinding[0].certificateSource -eq $(if ($d.CertificateSource -eq 'Pfx') { 'Custom' } else { 'KeyVault' }) -and
        ($d.CertificateSource -ne 'KeyVault' -or $currentBinding[0].keyVaultId -eq $cert.SecretId) -and -not $d.ReplaceHostname
    if ($d.CertificateSource -eq 'KeyVault') { $binding.certificateSource = 'KeyVault'; $binding.keyVaultId = $cert.SecretId; $binding.identityClientId = $null }
    else {
        $binding.certificateSource = 'Custom'
        $binding.encodedCertificate = [Convert]::ToBase64String($pfxBytes)
        if ($CertificatePassword) { $binding.certificatePassword = (New-Object Net.NetworkCredential('', $CertificatePassword)).Password }
    }
    try {
        if (-not $bindingMatches) {
        Wait-ClaudeAddress -Condition 'hostname update submission and certificate access' -About 'about 5 s; new Key Vault grants can take 10 minutes' -TimeoutSeconds ([Math]::Min([double]600, $TimeoutSeconds)) -PollSeconds $PollSeconds -Arguments @($uri,$d,$Plan,$binding) -Check {
            param($uri,$d,$Plan,$binding)
            $fresh = Invoke-ClaudeNetworkArm $uri
            if ((Get-ClaudeAddressHostState $fresh) -ne $d.HostnameBaseline) { throw 'Gateway hostnames changed during certificate access setup; review again.' }
            try {
                $body = Get-ClaudeAddressHostnamePatch -Gateway $fresh -Plan $Plan -Binding $binding
                Invoke-ClaudeNetworkArm $uri -Method patch -Body $body -StateDirectory ([IO.Path]::GetTempPath()) | Out-Null
                @{ Done = $true; Status = 'submitted' }
            }
            catch {
                if ($d.CertificateSource -eq 'KeyVault' -and $_.Exception.Message -match 'KeyVault.*(Access|Forbidden)|Failed to access.*KeyVault|Access denied.*Key Vault') {
                    @{ Done = $false; Status = 'Key Vault access has not propagated to the gateway identity' }
                } else { throw }
            }
        } | Out-Null
        }
        else { Write-Host '  The company hostname already has the supplied certificate; no APIM patch is needed.' }
    }
    finally { $binding.Remove('encodedCertificate'); $binding.Remove('certificatePassword') }
    Wait-ClaudeAddress -Condition "APIM hostname $($d.Hostname)" -About 'about 5-15 minutes; Azure can take longer' -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds -Arguments @($uri,$d) -Check {
        param($uri,$d)
        $g = Invoke-ClaudeNetworkArm $uri
        if ($g.properties.provisioningState -in @('Failed','Canceled')) { throw "APIM hostname update $($g.properties.provisioningState)." }
        $hostConfig = @($g.properties.hostnameConfigurations | Where-Object { $_.type -eq 'Proxy' -and $_.hostName -ieq $d.Hostname })
        if ($hostConfig.Count -and $hostConfig[0].certificateStatus -eq 'Failed') { throw 'APIM hostname certificate status is Failed.' }
        @{ Done = ($g.properties.provisioningState -eq 'Succeeded' -and $hostConfig.Count -eq 1 -and $hostConfig[0].certificateStatus -ne 'InProgress'); Status = $g.properties.provisioningState }
    } | Out-Null
    $proof = Wait-ClaudeAddress -Condition "HTTPS proof through $($d.Hostname) with SNI and Host" -About 'about 5 s' -TimeoutSeconds 45 -Arguments @($d,$cert) -Check {
        param($d,$cert)
        $result = Invoke-ClaudeAddressHttps -Hostname $d.Hostname -Thumbprint $cert.Thumbprint -ConnectAddress $d.ConnectAddress -IsolatedProof:$d.IsolatedProof
        if ($result.StatusCode -ne 401) { throw "HTTPS returned $($result.StatusCode), not the gateway's unauthenticated 401." }
        if ($result.Thumbprint -ine $cert.Thumbprint) { throw 'HTTPS did not present the configured certificate.' }
        if ($result.Hostname -ine $d.Hostname) { throw 'HTTPS proof used a different hostname.' }
        if (-not $result.Trusted -and -not $d.IsolatedProof) { throw 'HTTPS certificate trust failed; the record was not changed.' }
        @{ Done = $true; Value = $result }
    }
    $url = "https://$($d.Hostname)/claude"
    Write-Host "  HTTPS $($proof.StatusCode); certificate $($proof.Thumbprint); SNI/Host $($d.Hostname)."
    $address = [pscustomobject]@{
        hostname = $d.Hostname; certificateSource = $d.CertificateSource; keyVaultCertificateId = $d.KeyVaultCertificateId
        pfxPath = $d.PfxPath; dnsZoneResourceId = $d.DnsZoneResourceId; dnsMode = $(if ($d.DnsZoneResourceId) { 'AzureDns' } else { 'External' })
        certificateThumbprint = $cert.Thumbprint; verifiedUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ($d.IsolatedProof) { Write-Host 'ISOLATED PROOF: no public delegation/trust claimed; no developer record was published.' }
    elseif ($RecordPath) {
        if (-not $record) { $record = [pscustomobject]@{ mode = 'gateway'; subscriptionId = $d.SubscriptionId; apimName = $d.ApimName; resourceGroup = $d.ResourceGroup; sku = $d.Sku; location = $d.Region } }
        Update-ClaudeAddressArtifacts -RecordPath $RecordPath -OldUrl $record.gatewayUrl -NewUrl $url
        Set-ClaudeRecordProperty $record gatewayUrl $url
        Set-ClaudeRecordProperty $record address $address
        Set-ClaudeDecision -Record $record -Key address -Value $address
        $record.PSObject.Properties.Remove('pendingAddress')
        Write-ClaudeDecisionRecord -Record $record -Path $RecordPath
        Write-Host '  Developer record published. Already-configured workstations need the redistributed settings.'
    }
    [pscustomobject]@{ GatewayUrl = $url; Address = $address; Proof = $proof }
}
