[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path $PSScriptRoot -Parent }
$fail = 0
$passed = 0
function Assert([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:passed++; Write-Host "  [OK] $Name" }
    else { $script:fail++; Write-Host "  [FAIL] $Name" }
}
function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null; Assert $Name $false }
    catch { Assert $Name ($_.Exception.Message -match $Pattern) }
}

$common = Join-Path $RepositoryRoot 'scripts\ClaudeNetwork.ps1'
Assert 'network discovery helper exists' (Test-Path $common)
if (-not (Test-Path $common)) { exit 1 }
. $common

$choices = @(
    [pscustomobject]@{ id = 'a'; label = 'Existing private network'; consequence = 'No new VNet charge'; value = 1 },
    [pscustomobject]@{ id = 'b'; label = 'New isolated network'; consequence = 'IPAM approval required'; value = 2 }
)
Assert 'explicit choice returns the discovered record' ((Select-ClaudeNetworkOption -Options $choices -SelectedId b -NonInteractive -Prompt 'Network').value -eq 2)
Assert-Throws 'unknown explicit choice fails closed' { Select-ClaudeNetworkOption -Options $choices -SelectedId c -NonInteractive -Prompt 'Network' } 'not.*discovered'
Assert-Throws 'unattended ambiguity is not silently defaulted' { Select-ClaudeNetworkOption -Options $choices -NonInteractive -Prompt 'Network' } 'Select.*explicitly'
Assert-Throws 'no options is not success' { Select-ClaudeNetworkOption -Options @() -NonInteractive -Prompt 'Network' } 'No.*options'
Assert 'one real choice can be selected unattended' ((Select-ClaudeNetworkOption -Options @($choices[0]) -NonInteractive -Prompt 'Network').id -eq 'a')

$r = Get-ClaudeNetworkCidr -Cidr '10.12.4.0/24'
Assert 'IPv4 range has the correct start and end' ($r.First -eq 168559616 -and $r.Last -eq 168559871)
Assert-Throws 'host bits in a subnet are rejected' { Get-ClaudeNetworkCidr '10.12.4.1/24' } 'network address'
Assert-Throws 'IPv6 is not silently treated as IPv4' { Get-ClaudeNetworkCidr '::1/128' } 'IPv4'
Assert-Throws 'invalid prefix is rejected' { Get-ClaudeNetworkCidr '10.0.0.0/33' } 'prefix'
Assert 'overlap includes containment' (Test-ClaudeNetworkOverlap '10.12.4.0/24' '10.12.4.128/25')
Assert 'adjacent subnets do not overlap' (-not (Test-ClaudeNetworkOverlap '10.12.4.0/24' '10.12.5.0/24'))
$free = Get-ClaudeNetworkFreePrefix -Existing @('10.0.0.0/22', '10.0.4.0/24') -PrefixLength 22 -Count 3
Assert 'free address suggestions skip all observed overlaps' (@($free).Count -eq 3 -and $free[0] -eq '10.0.8.0/22')
Assert 'private address classification excludes public and link-local' ((Test-ClaudeNetworkPrivateAddress '172.16.8.4') -and -not (Test-ClaudeNetworkPrivateAddress '172.32.8.4') -and -not (Test-ClaudeNetworkPrivateAddress '169.254.1.1'))

$basic = Get-ClaudeApimNetworkCapability 'BasicV2' 'None'
$standard = Get-ClaudeApimNetworkCapability 'StandardV2' 'External'
$premium = Get-ClaudeApimNetworkCapability 'PremiumV2' 'Internal'
Assert 'Basic v2 is not advertised as Private Link capable' (-not $basic.PrivateEndpoint -and -not $basic.OutboundIntegration)
Assert 'Standard v2 can combine private inbound and outbound' ($standard.PrivateEndpoint -and $standard.OutboundIntegration -and -not $standard.Injection)
Assert 'Premium v2 injection is recognized, not converted' ($premium.Injection -and $premium.Internal)
Assert-Throws 'classic metering is not passed off as Claude governance' { Assert-ClaudeNetworkSku 'Premium' 'private' } 'v2'
Assert-Throws 'private topology refuses Basic v2' { Assert-ClaudeNetworkSku 'BasicV2' 'private' } 'StandardV2|PremiumV2'
Assert 'public edge can front Basic v2' (Assert-ClaudeNetworkSku 'BasicV2' 'public')

$skuRows = @(
    [pscustomobject]@{ name = 'StandardV2'; locations = @('regiona','regionb'); restrictions = @([pscustomobject]@{ type = 'Location'; values = @('regionb'); reasonCode = 'NotAvailableForSubscription' }) },
    [pscustomobject]@{ name = 'BasicV2'; locations = @('regiona'); restrictions = @() }
)
$regions = Get-ClaudeNetworkSkuLocation -Skus $skuRows -Sku StandardV2
Assert 'SKU choices exclude subscription restrictions' (@($regions).Count -eq 1 -and $regions[0] -eq 'regiona')

$script:azCalls = @()
function Invoke-ClaudeNetworkAz {
    param([string[]]$Arguments)
    $script:azCalls += ,$Arguments
    switch ($Arguments[0] + ' ' + $Arguments[1]) {
        'account list' { return @([pscustomobject]@{ id='00000000-0000-0000-0000-000000000001'; name='Contoso'; state='Enabled'; isDefault=$true }) }
        'rest --method' {
            $url = $Arguments[4]
            if ($url -match '/resources\?') { return [pscustomobject]@{ value = @(); nextLink = $null } }
            if ($url -match '/resourcegroups\?') { return [pscustomobject]@{ value = @(); nextLink = $null } }
            if ($url -match '/locations\?') { return [pscustomobject]@{ value = @([pscustomobject]@{ name='regiona'; displayName='Region A' }) } }
            if ($url -match '/skus\?') { return [pscustomobject]@{ value = $skuRows } }
            if ($url -match 'applicationGatewayAvailableWafRuleSets') { return [pscustomobject]@{ value=@([pscustomobject]@{ properties=[pscustomobject]@{ ruleSetType='Microsoft_DefaultRuleSet'; ruleSetVersion='2.1' } }) } }
            if ($url -match '/features/') { return [pscustomobject]@{ properties=[pscustomobject]@{ state='Registered' } } }
            if ($url -match '/providers/Microsoft.Network\?') { return [pscustomobject]@{ resourceTypes=@([pscustomobject]@{ resourceType='applicationGateways'; locations=@('Region A') }) } }
            throw "Unexpected discovery URL: $url"
        }
        default { throw 'Unexpected Azure command' }
    }
}
$inventory = Get-ClaudeNetworkInventory -SubscriptionId '00000000-0000-0000-0000-000000000001'
Assert 'discovery can represent an empty subscription' (@($inventory.Resources).Count -eq 0 -and @($inventory.Locations).Count -eq 1)
Assert 'discovery gets real SKUs and available WAF rule sets' (@($inventory.ApimSkus).Count -eq 2 -and @($inventory.WafRuleSets).Count -eq 1)
Assert 'discovery has no control-plane writes' (-not (@($script:azCalls | ForEach-Object { $_ -join ' ' }) -match '--method (put|patch|post|delete)|account set'))
Assert 'discovery pins every ARM call to the requested scope' (@($script:azCalls | Where-Object { $_[0] -eq 'rest' -and $_[4] -notmatch '/subscriptions/00000000-0000-0000-0000-000000000001/' }).Count -eq 0)

. (Join-Path $RepositoryRoot 'scripts\ClaudeNetworkPolicy.ps1')
$original = '<policies><inbound><base /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
$restricted = Set-ClaudeNetworkPolicyText -Policy $original -AllowedCidrs @('10.2.0.0/24') -EdgeId 'contoso-edge'
Assert 'edge filter is before inherited policy and token use' ($restricted.IndexOf('ip-filter') -lt $restricted.IndexOf('<base'))
Assert 'edge client IP is accepted only after the IP filter' ($restricted.IndexOf('claude-edge-client-ip') -gt $restricted.IndexOf('</ip-filter>'))
Assert 'restriction carries explicit provenance' ($restricted -match 'claude-network-edge:contoso-edge')
Assert 'policy rerun is idempotent' ((Set-ClaudeNetworkPolicyText -Policy $restricted -AllowedCidrs @('10.2.0.0/24') -EdgeId 'contoso-edge') -eq $restricted)
Assert-Throws 'another edge cannot replace an existing restriction' { Set-ClaudeNetworkPolicyText -Policy $restricted -AllowedCidrs @('10.3.0.0/24') -EdgeId 'other-edge' } 'another edge'
Assert-Throws 'an open allow range is rejected' { Set-ClaudeNetworkPolicyText -Policy $original -AllowedCidrs @('0.0.0.0/0') -EdgeId 'contoso-edge' } 'unrestricted'
Assert-Throws 'untrusted marker input is rejected' { Set-ClaudeNetworkPolicyText -Policy $original -AllowedCidrs @('10.2.0.0/24') -EdgeId 'x--><choose>' } 'edge identifier'
Assert 'removal changes only the owned block' ((Remove-ClaudeNetworkPolicyText -Policy $restricted -EdgeId 'contoso-edge') -eq $original)

. (Join-Path $PSScriptRoot 'NetworkEdgeContract.ps1')
$issues = @(Test-ClaudeNetworkTemplateContract -Root $RepositoryRoot)
Assert ('edge deployment invariants: ' + ($issues -join '; ')) ($issues.Count -eq 0)

foreach ($name in @('New-ClaudeNetworkEdge.ps1','Test-ClaudeNetworkEdge.ps1','Remove-ClaudeNetworkEdge.ps1')) {
    $text = Get-Content (Join-Path $RepositoryRoot "scripts\$name") -Raw
    Assert "$name supports WhatIf" ($text -match 'SupportsShouldProcess')
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    Assert "$name parses" (@($errors).Count -eq 0)
}

Write-Host "$passed passed; $fail failed."
if ($fail) { exit 1 }
exit 0
