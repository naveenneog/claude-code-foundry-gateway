# P60 - Claude Desktop sign-in is chosen by the administrator.
#
# RED first: this contract was written while Desktop was still hardcoded to the
# Azure CLI credential helper in the workstation scripts and MDM generator.

$root = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $root 'Install-ClaudeGateway.ps1'
$desktop = Join-Path $root 'scripts/ClaudeDesktopSignIn.ps1'
$workstationPs = Join-Path $root 'scripts/Setup-ClaudeWorkstation.ps1'
$workstationSh = Join-Path $root 'scripts/setup-claude-workstation.sh'
$policy = Join-Path $root 'infra/policy.xml'
$bicep = Join-Path $root 'infra/main.bicep'
$policyGen = Join-Path $root 'scripts/New-ClaudeCodePolicy.ps1'
$appScript = Join-Path $root 'scripts/New-ClaudeDesktopEntraApp.ps1'
$adr = Join-Path $root 'docs/adr/0027-claude-desktop-sign-in-choice.md'
$developer = Join-Path $root 'DEVELOPER.md'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

function Get-PlistDictValueMap($Dict) {
    $map = @{}
    $nodes = @($Dict.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
    for ($i = 0; $i -lt $nodes.Count - 1; $i++) {
        if ($nodes[$i].Name -ne 'key') { continue }
        $key = $nodes[$i].InnerText
        $valueNode = $nodes[$i + 1]
        $map[$key] = [pscustomobject]@{ Type = $valueNode.Name; Value = $valueNode.InnerText; Node = $valueNode }
        $i++
    }
    $map
}

function Get-MobileconfigPayload($Path, $PayloadType) {
    [xml]$xml = Get-Content $Path -Raw
    $uuids = @()
    foreach ($dict in $xml.SelectNodes('//dict')) {
        $values = Get-PlistDictValueMap $dict
        if ($values.ContainsKey('PayloadUUID')) { $uuids += $values['PayloadUUID'].Value }
        if ($values.ContainsKey('PayloadType') -and $values['PayloadType'].Value -eq $PayloadType) {
            return [pscustomobject]@{ Xml = $xml; Uuids = $uuids; Values = $values }
        }
    }
    return [pscustomobject]@{ Xml = $xml; Uuids = $uuids; Values = @{} }
}

Write-Host ''
Write-Host 'P60 contract - recorded choice' -ForegroundColor Cyan

Assert 'the desktop sign-in helper exists' (Test-Path $desktop) $desktop
Assert 'the ADR records the decision' (Test-Path $adr) $adr
Assert 'the app-registration script exists' (Test-Path $appScript) $appScript

if (Test-Path $desktop) {
    . $desktop

    $helper = [pscustomobject]@{ desktopSignIn = [pscustomobject]@{ kind = 'helper-script' } }
    $browser = [pscustomobject]@{
        desktopSignIn = [pscustomobject]@{
            kind = 'external-idp'; flow = 'browser'; bearerTokenType = 'id_token'
            clientId = '11111111-1111-1111-1111-111111111111'
            issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0'
        }
    }
    $broker = [pscustomobject]@{
        desktopSignIn = [pscustomobject]@{
            kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'access_token'
            clientId = '11111111-1111-1111-1111-111111111111'
            issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0'
            scopes = 'api://gateway-claude/user_impersonation'
            audience = 'api://gateway-claude'
        }
    }

    $helperChoice = Get-ClaudeDesktopSignIn -Config $helper
    $browserChoice = Get-ClaudeDesktopSignIn -Config $browser
    $brokerChoice = Get-ClaudeDesktopSignIn -Config $broker

    Assert 'helper-script is the default and validates' ($helperChoice.kind -eq 'helper-script')
    Assert 'browser external-idp validates' ($browserChoice.kind -eq 'external-idp' -and $browserChoice.flow -eq 'browser')
    Assert 'broker external-idp validates' ($brokerChoice.flow -eq 'broker')

    $bad = [pscustomobject]@{ desktopSignIn = [pscustomobject]@{ kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'id_token'; clientId = 'x'; issuer = 'https://login.microsoftonline.com/t/v2.0' } }
    $threw = $false
    try { Get-ClaudeDesktopSignIn -Config $bad | Out-Null } catch { $threw = $true }
    Assert 'invalid client ids are refused clearly' $threw

    $helperSettings = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.example/claude' -Models @('claude-sonnet-5') -HelperPath 'C:\h\get-foundry-token.cmd' -DesktopSignIn $helperChoice
    Assert 'helper settings keep the existing credential kind' ($helperSettings.inferenceCredentialKind -eq 'helper-script')
    Assert 'helper settings include the helper path' ($helperSettings.inferenceCredentialHelper -eq 'C:\h\get-foundry-token.cmd')
    Assert 'helper settings do not include IdP keys' (-not $helperSettings.Contains('inferenceIdpOidc') -and -not $helperSettings.Contains('inferenceIdpAuthFlow'))

    $browserSettings = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.example/claude' -Models @('claude-sonnet-5') -HelperPath 'C:\h\get-foundry-token.cmd' -DesktopSignIn $browserChoice
    Assert 'external-idp settings use the new credential kind' ($browserSettings.inferenceCredentialKind -eq 'external-idp')
    Assert 'external-idp settings include the IdP block' ($browserSettings.inferenceIdpOidc.clientId -eq $browser.desktopSignIn.clientId)
    Assert 'browser settings do not write a helper' (-not $browserSettings.Contains('inferenceCredentialHelper'))
    Assert 'id-token audience is the desktop app client id' ((Get-ClaudeDesktopGatewayAudience -DesktopSignIn $browserChoice) -eq $browser.desktopSignIn.clientId)

    $brokerSettings = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.example/claude' -Models @('claude-sonnet-5') -HelperPath 'C:\h\get-foundry-token.cmd' -DesktopSignIn $brokerChoice
    Assert 'broker settings write the broker flow' ($brokerSettings.inferenceIdpAuthFlow -eq 'broker')
    Assert 'access-token settings write scopes' ($brokerSettings.inferenceIdpOidc.scopes -eq $broker.desktopSignIn.scopes)
    Assert 'access-token audience is explicit' ((Get-ClaudeDesktopGatewayAudience -DesktopSignIn $brokerChoice) -eq $broker.desktopSignIn.audience)
}

Write-Host ''
Write-Host 'P60 installer and gateway policy' -ForegroundColor Cyan

$install = if (Test-Path $installer) { Get-Content $installer -Raw } else { '' }
$pol = if (Test-Path $policy) { Get-Content $policy -Raw } else { '' }
$main = if (Test-Path $bicep) { Get-Content $bicep -Raw } else { '' }

Assert 'installer offers Desktop sign-in kinds' ($install -match 'DesktopSignInKind' -and $install -match 'external-idp-browser' -and $install -match 'external-idp-broker')
Assert 'installer records desktopSignIn in claude-gateway.json' ($install -match 'desktopSignIn\s+=')
Assert 'installer records the gateway audience named value' ($install -match 'desktopExternalAudience|desktopGatewayAudience')
Assert 'gateway has a named value for the optional Desktop audience' ($main -match "key:\s*'external-idp-extra-audience'")
Assert 'policy has the default no-extra-audience branch' ($pol -match 'external-idp-extra-audience' -and $pol -match 'https://cognitiveservices.azure.com')
Assert 'policy accepts the Desktop audience only when configured' ($pol -match '\{\{external-idp-extra-audience\}\}' -and $pol -match '<choose>')
Assert 'policy still pins the tenant' ($pol -match 'tenant-id="\{\{tenant-id\}\}"')

Write-Host ''
Write-Host 'P60 workstation and MDM output' -ForegroundColor Cyan

$ps = if (Test-Path $workstationPs) { Get-Content $workstationPs -Raw } else { '' }
$sh = if (Test-Path $workstationSh) { Get-Content $workstationSh -Raw } else { '' }
$gen = if (Test-Path $policyGen) { Get-Content $policyGen -Raw } else { '' }

Assert 'PowerShell workstation reads desktopSignIn' ($ps -match 'Get-ClaudeDesktopSignIn')
Assert 'PowerShell workstation writes shared Desktop settings' ($ps -match 'New-ClaudeDesktopSettings')
Assert 'shell workstation reads desktopSignIn' ($sh -match 'desktopSignIn')
Assert 'shell workstation writes external-idp when recorded' ($sh -match 'inferenceIdpOidc' -and $sh -match 'inferenceIdpAuthFlow')
Assert 'MDM generator reads the recorded choice' ($gen -match 'Get-ClaudeDesktopSignIn')
Assert 'MDM generator writes the same Desktop connection keys' ($gen -match 'New-ClaudeDesktopSettings')

$scratch = Join-Path ([IO.Path]::GetTempPath()) "desktop-mdm-$PID-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
try {
    $helperConfig = Join-Path $scratch 'helper.json'
    $browserConfig = Join-Path $scratch 'browser.json'
    @'
{
  "gatewayUrl": "https://gateway.contoso.example/claude",
  "models": ["claude-sonnet-5"],
  "desktopSignIn": { "kind": "helper-script" }
}
'@ | Set-Content $helperConfig -Encoding utf8
    @'
{
  "gatewayUrl": "https://gateway.contoso.example/claude",
  "models": ["claude-sonnet-5"],
  "desktopSignIn": {
    "kind": "external-idp",
    "flow": "broker",
    "bearerTokenType": "access_token",
    "clientId": "11111111-1111-1111-1111-111111111111",
    "issuer": "https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0",
    "scopes": "api://gateway-claude/user_impersonation",
    "audience": "api://gateway-claude"
  }
}
'@ | Set-Content $browserConfig -Encoding utf8

    $helperOut = Join-Path $scratch 'helper'
    $browserOut = Join-Path $scratch 'browser'
    & $policyGen -ConfigPath $helperConfig -OutputPath $helperOut *> $null
    & $policyGen -ConfigPath $browserConfig -OutputPath $browserOut *> $null

    $helperMobile = Join-Path $helperOut 'claude-desktop.mobileconfig'
    $browserMobile = Join-Path $browserOut 'claude-desktop.mobileconfig'
    Assert 'MDM generator writes a Desktop mobileconfig' (Test-Path $helperMobile)
    Assert 'external-idp output writes a Desktop mobileconfig' (Test-Path $browserMobile)

    if ((Test-Path $helperMobile) -and (Test-Path $browserMobile) -and (Test-Path $desktop)) {
        . $desktop
        foreach ($case in @(
            @{ Name = 'helper'; Path = $helperMobile; Json = Join-Path $helperOut 'claude-desktop.managed-settings.json' },
            @{ Name = 'external-idp'; Path = $browserMobile; Json = Join-Path $browserOut 'claude-desktop.managed-settings.json' }
        )) {
            $parsed = Get-MobileconfigPayload -Path $case.Path -PayloadType 'com.anthropic.claudefordesktop'
            Assert "$($case.Name) Desktop mobileconfig parses as XML" ($null -ne $parsed.Xml)
            Assert "$($case.Name) Desktop mobileconfig has unique PayloadUUIDs" (
                $parsed.Uuids.Count -ge 2 -and (@($parsed.Uuids | Select-Object -Unique).Count -eq $parsed.Uuids.Count))
            Assert "$($case.Name) Desktop mobileconfig payload domain is correct" (
                $parsed.Values.ContainsKey('PayloadType') -and $parsed.Values['PayloadType'].Value -eq 'com.anthropic.claudefordesktop')

            $settingsJson = Get-Content $case.Json -Raw | ConvertFrom-Json -AsHashtable
            foreach ($key in $settingsJson.Keys) {
                Assert "$($case.Name) Desktop mobileconfig includes $key" ($parsed.Values.ContainsKey($key))
                if ($parsed.Values.ContainsKey($key)) {
                    Assert "$($case.Name) Desktop mobileconfig writes $key as documented string" ($parsed.Values[$key].Type -eq 'string')
                    $expected = ConvertTo-ClaudeDesktopRegistryString -Value $settingsJson[$key]
                    Assert "$($case.Name) Desktop mobileconfig value matches $key" ($parsed.Values[$key].Value -eq $expected)
                }
            }
        }

        $helperPayload = (Get-MobileconfigPayload -Path $helperMobile -PayloadType 'com.anthropic.claudefordesktop').Values
        Assert 'helper Desktop mobileconfig includes helper credential kind' ($helperPayload['inferenceCredentialKind'].Value -eq 'helper-script')
        Assert 'helper Desktop mobileconfig includes helper path' ($helperPayload.ContainsKey('inferenceCredentialHelper'))
        Assert 'helper Desktop mobileconfig excludes external IdP keys' (-not $helperPayload.ContainsKey('inferenceIdpOidc') -and -not $helperPayload.ContainsKey('inferenceIdpAuthFlow'))

        $externalPayload = (Get-MobileconfigPayload -Path $browserMobile -PayloadType 'com.anthropic.claudefordesktop').Values
        Assert 'external-idp Desktop mobileconfig includes external credential kind' ($externalPayload['inferenceCredentialKind'].Value -eq 'external-idp')
        Assert 'external-idp Desktop mobileconfig includes IdP flow' ($externalPayload['inferenceIdpAuthFlow'].Value -eq 'broker')
        Assert 'external-idp Desktop mobileconfig includes IdP object' ($externalPayload['inferenceIdpOidc'].Value -match '"bearerTokenType":"access_token"')
        Assert 'external-idp Desktop mobileconfig excludes helper path' (-not $externalPayload.ContainsKey('inferenceCredentialHelper'))
    }
}
finally {
    Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'P60 app registration and documentation' -ForegroundColor Cyan

$app = if (Test-Path $appScript) { Get-Content $appScript -Raw } else { '' }
$dev = if (Test-Path $developer) { Get-Content $developer -Raw } else { '' }

Assert 'app registration script is idempotent' ($app -match 'az ad app list' -and $app -match 'az ad app update')
Assert 'app registration script supports WhatIf' ($app -match 'SupportsShouldProcess')
Assert 'browser redirect is exact' ($app -match 'http://127\.0\.0\.1/callback')
Assert 'broker redirects are added' ($app -match 'ms-appx-web://Microsoft\.AAD\.BrokerPlugin' -and $app -match 'msauth\.com\.anthropic\.claudefordesktop://auth')
Assert 'developer guide documents helper-script unchanged' ($dev -match 'helper-script')
Assert 'developer guide documents external-idp browser and broker' ($dev -match 'external-idp' -and $dev -match 'broker')
Assert 'developer guide names consent and the audience' ($dev -match 'AADSTS65001|admin consent|Need admin approval' -and $dev -match 'audience')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P60 contract holds.' -ForegroundColor Green
exit 0
