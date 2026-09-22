<#
.SYNOPSIS
    Configures a developer machine from the file the platform team sent, after
    proving it will work.

.DESCRIPTION
    One command, one file, and nothing written until the machine has been shown
    capable of using what is about to be written.

    That ordering is the point. The two setup scripts already configure
    correctly; what they cannot do is tell a developer why a correct
    configuration then fails, because by the time it fails the evidence is a
    401, an ENOTFOUND or a silent hang, none of which names its cause. A
    machine behind a proxy that breaks server-sent events, or holding a role
    that does not reach Claude, gets configured perfectly and does not work.

    So this runs the checks first and stops if they fail. A developer who
    cannot proceed learns it in thirty seconds with a reason, rather than after
    a reconfiguration, a reinstall and a support thread.

    Preflight, in the order that answers the cheapest question first:

      1. tooling      the Azure CLI, and a PowerShell that can run the rest
      2. identity     signed in, and to the tenant the file names
      3. network      the destinations this mode needs, and a streaming call
      4. access       a real request to the model, with this person's token

    Nothing is written before all four pass. `-PreflightOnly` stops after them,
    which is what to run on a fleet before promising a rollout date.

    The file decides everything else. A `gateway` config configures against API
    Management; a `foundry-direct` config configures against Foundry. Both are
    JSON, both have the same extension, and applying one as the other produces
    a machine pointed somewhere wrong and an error that names neither - so the
    mode is read, not guessed, and a file with no mode tag is inferred from its
    contents and reported.

    Safe to re-run. It is how a machine moves between the two paths, and how a
    reissued file - a new gateway address, a different sign-in mode - is picked
    up. Re-running with the same file changes nothing.

.PARAMETER ConfigPath
    The JSON your platform team sent, as a path or a URL.

.PARAMETER PreflightOnly
    Run the checks and stop. Writes nothing. Use this to survey machines before
    committing to a rollout.

.PARAMETER SkipPreflight
    Configure without checking first. There is one good reason - the checks
    need outbound access that a build agent legitimately lacks - and it is
    worth knowing that this is the switch that turns a clear failure into an
    unclear one.

.PARAMETER Unattended
    Do not prompt. Fails rather than asking.

.EXAMPLE
    ./scripts/Onboard-ClaudeDeveloper.ps1 -ConfigPath .\claude-gateway.json

.EXAMPLE
    # survey a machine without touching it
    ./scripts/Onboard-ClaudeDeveloper.ps1 -ConfigPath .\claude-gateway.json -PreflightOnly

.EXAMPLE
    # from the intranet, no prompts, for a provisioning script
    ./scripts/Onboard-ClaudeDeveloper.ps1 -ConfigPath https://intranet/claude.json -Unattended
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [switch]$PreflightOnly,
    [switch]$SkipPreflight,
    [switch]$SkipDesktop,
    [switch]$SkipVSCode,
    [switch]$Unattended
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

function Head($m) { Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

$failures = New-Object System.Collections.ArrayList
function Fail($what, $why) {
    Bad $what
    if ($why) { Note $why }
    $null = $failures.Add($what)
}

Write-Host ''
Write-Host '  Claude developer onboarding' -ForegroundColor Cyan
Write-Host '  Checks this machine first, and writes nothing until they pass.' -ForegroundColor DarkGray

# ------------------------------------------------------------------ the file
Head 'The configuration'

$raw = if ($ConfigPath -match '^https?://') {
    try { (Invoke-WebRequest -Uri $ConfigPath -UseBasicParsing -TimeoutSec 30).Content }
    catch { throw "Could not fetch $ConfigPath. $($_.Exception.Message)" }
}
else {
    if (-not (Test-Path $ConfigPath)) { throw "No config at $ConfigPath" }
    Get-Content $ConfigPath -Raw
}

$cfg = try { $raw | ConvertFrom-Json } catch { throw "$ConfigPath is not valid JSON. $($_.Exception.Message)" }

# Read the mode rather than guessing it. Files written before the mode tag
# existed are inferred from their contents and the inference is stated, because
# a silent guess about which endpoint a machine is pointed at is exactly the
# class of thing that is discovered three steps later.
$mode = $cfg.mode
if (-not $mode) {
    if ($cfg.foundryResource) { $mode = 'foundry-direct' }
    elseif ($cfg.gatewayUrl) { $mode = 'gateway' }
    if ($mode) { Warn "no mode in the file; inferred '$mode' from its contents" }
}
if ($mode -notin @('gateway', 'foundry-direct')) {
    throw "Cannot tell what this file configures. It needs a 'mode' of 'gateway' or 'foundry-direct', or a gatewayUrl or foundryResource to infer one from."
}

$target = if ($mode -eq 'gateway') { $cfg.gatewayUrl } else { $cfg.foundryResource }
if (-not $target) { throw "A '$mode' config needs $(if ($mode -eq 'gateway') { 'gatewayUrl' } else { 'foundryResource' })." }

Ok "$mode"
Note "target   $target"
if ($cfg.tenantId) { Note "tenant   $($cfg.tenantId)" }
$authMode = if ($cfg.authMode) { $cfg.authMode } elseif ($cfg.auth) { $cfg.auth } else { 'interactive' }
Note "sign-in  $authMode"
if ($cfg.generated) { Note "issued   $($cfg.generated)" }

# What this machine looks like now, so a re-run can say what it is changing
# rather than reporting success identically whether or not anything moved.
$settingsPath = Join-Path $env:USERPROFILE '.claude/settings.json'
$before = $null
if (Test-Path $settingsPath) {
    try { $before = (Get-Content $settingsPath -Raw | ConvertFrom-Json).env } catch { }
}
if ($before) {
    $now = if ($before.PSObject.Properties['ANTHROPIC_FOUNDRY_BASE_URL']) { $before.ANTHROPIC_FOUNDRY_BASE_URL }
    elseif ($before.PSObject.Properties['ANTHROPIC_FOUNDRY_RESOURCE']) { "resource:$($before.ANTHROPIC_FOUNDRY_RESOURCE)" }
    else { $null }
    if ($now) { Note "this machine is currently configured against $now" }
}

# ------------------------------------------------------------------ preflight
if (-not $SkipPreflight) {

    # 1. Tooling. Cheapest question, and the one whose failure is least
    #    ambiguous, so it is asked before anything that needs the network.
    Head 'Preflight 1 of 4 - tooling'

    $azPath = $null
    foreach ($c in @(
            (Get-Command az -ErrorAction SilentlyContinue).Source,
            "$env:ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
            "${env:ProgramFiles(x86)}\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
        )) {
        if ($c -and (Test-Path $c)) { $azPath = $c; break }
    }
    if ($azPath) {
        $azv = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
        Ok "Azure CLI $azv"
    }
    else {
        Fail 'Azure CLI is not installed' 'Every sign-in route here goes through it. https://aka.ms/installazurecli'
    }

    Ok "PowerShell $($PSVersionTable.PSVersion)"

    # 2. Identity. A token from the wrong tenant fails later as a 401 that
    #    reads like a missing role, so the tenant is compared here where the
    #    comparison is cheap and the message can say which two values differ.
    Head 'Preflight 2 of 4 - identity'

    if ($azPath) {
        $acct = $null
        try { $acct = az account show -o json 2>$null | ConvertFrom-Json } catch { }
        if (-not $acct) {
            Fail 'not signed in to Azure' "Run: az login$(if ($authMode -eq 'device') { ' --use-device-code' })"
        }
        else {
            Ok "signed in as $($acct.user.name)"
            Note "tenant $($acct.tenantId)"
            if ($cfg.tenantId -and $acct.tenantId -ne $cfg.tenantId) {
                Fail 'signed in to a different tenant than the config names' `
                    "config $($cfg.tenantId), session $($acct.tenantId). Run: az login --tenant $($cfg.tenantId)"
            }
            elseif ($cfg.tenantId) {
                Ok 'tenant matches the configuration'
            }
        }
    }
    else {
        Warn 'skipping identity - no Azure CLI'
    }

    # 3. Network. Delegated rather than reimplemented: the same check an
    #    administrator runs, so a developer and an administrator looking at the
    #    same machine cannot get different answers from different code.
    Head 'Preflight 3 of 4 - network'

    $netScript = Join-Path $scriptDir 'Test-ClaudeNetwork.ps1'
    if (-not (Test-Path $netScript)) {
        Warn 'skipping network - Test-ClaudeNetwork.ps1 is not beside this script'
    }
    else {
        $netArgs = @{ AsJson = $true }
        if ($mode -eq 'foundry-direct') {
            $netArgs['FoundryResource'] = $cfg.foundryResource
            # Explicitly none. Test-ClaudeNetwork reads the gateway out of this
            # machine's existing settings otherwise, and on a machine moving
            # from the gateway to the direct path that would make an irrelevant
            # host a required one - failing the onboarding over something the
            # new configuration will not use.
            $netArgs['GatewayHost'] = ''
        }
        else {
            if ($cfg.gatewayUrl -match '^https?://([^/]+)') { $netArgs['GatewayHost'] = $Matches[1] }
            $netArgs['FoundryResource'] = ''
        }
        $net = $null
        try { $net = & $netScript @netArgs | ConvertFrom-Json } catch { }

        if (-not $net) {
            Warn 'the network check did not complete'
        }
        else {
            foreach ($d in $net.destinations) {
                if ($d.Reachable) { Ok "$($d.Host) reachable" }
                elseif ($d.Need -eq 'required') { Fail "$($d.Host) is not reachable" $d.Breaks }
                else { Warn "$($d.Host) is not reachable - $($d.Breaks)" }
            }
            if ($net.roundTrip) {
                switch ($net.roundTrip.Verdict) {
                    'ok' { Ok "streaming works - $($net.roundTrip.Detail)" }
                    'reset' {
                        Fail 'the connection is cut once the response streams' `
                            'Not an allowlist problem - every host above is reachable. Ask the network team to exclude these hosts from TLS inspection. See docs/NETWORK.md section 6.'
                    }
                    'buffered' {
                        Fail 'the response is buffered rather than streamed' `
                            'A proxy is holding the whole response. Same fix as a reset: exclude these hosts from inspection.'
                    }
                    'tls' {
                        Fail 'the TLS certificate is not trusted' `
                            'An inspecting proxy whose authority is not installed here. Install the corporate root, or set NODE_EXTRA_CA_CERTS.'
                    }
                    'auth' { Note "the round trip returned $($net.roundTrip.Http) - the network is fine; access is checked next" }
                    'skipped' { Note "streaming check skipped - $($net.roundTrip.Detail)" }
                    default { Warn "streaming check: $($net.roundTrip.Verdict) - $($net.roundTrip.Detail)" }
                }
            }
            if ($net.imds -and $net.imds.Behaviour -eq 'answers') {
                # Not a failure. It is the default on a Cloud PC or Dev Box, and
                # it decides which identity the client uses, so it is reported
                # here rather than left to surface as an unexplained 401.
                Warn 'this machine has a managed identity, which is tried before your sign-in'
                Note 'It will be pinned to your sign-in if the remaining checks pass.'
            }
        }
    }

    # 4. Access. The network being open says nothing about whether this person
    #    may call the model; a role that does not reach Claude looks identical
    #    to no role at all from the client.
    Head 'Preflight 4 of 4 - access'

    if (-not $azPath -or $failures.Count -gt 0) {
        Note 'skipped - an earlier check failed, and its cause would be reported as this one'
    }
    else {
        $tok = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
        if (-not $tok) {
            Fail 'could not get a token for Foundry' 'Sign in again: az login'
        }
        else {
            Ok 'token acquired for cognitiveservices.azure.com'
            # Decoded locally. The name in the token is what the service will
            # see, and it is the only way to say "you are entitled as X" rather
            # than "someone is entitled".
            try {
                $p = $tok.Split('.')[1].Replace('-', '+').Replace('_', '/')
                switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
                $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
                if ($claims.upn -or $claims.preferred_username) {
                    Note "as $(if ($claims.upn) { $claims.upn } else { $claims.preferred_username })"
                }
                if ($claims.oid) { Note "object id $($claims.oid)" }
            }
            catch { }

            if ($net -and $net.roundTrip -and $net.roundTrip.Verdict -eq 'ok') {
                Ok 'a real request to the model succeeded'
            }
            elseif ($net -and $net.roundTrip -and $net.roundTrip.Verdict -eq 'auth') {
                Fail "the model refused this identity (HTTP $($net.roundTrip.Http))" `
                    "The network is fine. Ask for a role that reaches Claude on the account scope - see docs/FOUNDRY-DIRECT.md section 4. For the gateway, ask to be added to an entitlement group."
            }
            elseif ($net -and $net.roundTrip -and $net.roundTrip.Verdict -eq 'notfound') {
                Fail 'the configured model is not a deployment on that resource' $net.roundTrip.Detail
            }
        }
    }
}
else {
    Head 'Preflight'
    Warn 'skipped at your request - a failure after this will be harder to place'
}

# ------------------------------------------------------------------ verdict
Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "  $($failures.Count) check(s) failed. Nothing has been written." -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "    - $f" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Fix these and run this again. The configuration on this machine is unchanged.' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

Write-Host '  Preflight passed.' -ForegroundColor Green
if ($PreflightOnly) {
    Write-Host '  -PreflightOnly, so nothing was written.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ------------------------------------------------------------------ configure
Head 'Configuring'

$setup = if ($mode -eq 'gateway') { Join-Path $scriptDir 'Setup-ClaudeWorkstation.ps1' }
else { Join-Path $scriptDir 'Setup-ClaudeFoundryDirect.ps1' }
if (-not (Test-Path $setup)) { throw "Cannot find $setup" }

# Delegated, not reimplemented. Two scripts that configure the same machine
# differently is how a fleet ends up in two states that nobody can reproduce.
$args = @('-ConfigPath', $ConfigPath)
if ($SkipDesktop) { $args += '-SkipDesktop' }
if ($SkipVSCode) { $args += '-SkipVSCode' }
if ($mode -eq 'foundry-direct' -and $Unattended) { $args += '-Force' }

Note "$(Split-Path $setup -Leaf) $($args -join ' ')"

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "configure for $mode")) {
    & $setup @args
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  Setup reported a failure. See its output above.' -ForegroundColor Red
        exit 1
    }

    # The credential chain, pinned where a managed identity would otherwise win.
    # dev, not a credential name: Claude Code validates this value itself before
    # @azure/identity sees it and accepts only dev or prod.
    if ($net -and $net.imds -and $net.imds.Behaviour -eq 'answers') {
        $existing = [Environment]::GetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'User')
        if (-not $existing) {
            [Environment]::SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'dev', 'User')
            Ok 'pinned AZURE_TOKEN_CREDENTIALS=dev for this user'
            Note 'This machine has a managed identity that would otherwise be used instead of you.'
            Note 'Open a new terminal for it to take effect.'
        }
        elseif ($existing -notin @('dev', 'prod')) {
            Warn "AZURE_TOKEN_CREDENTIALS is '$existing', which Claude Code rejects"
            Note "It accepts only 'dev' or 'prod'. Every call will fail until this is changed."
        }
    }
}

# ------------------------------------------------------------------ verify
Head 'Verifying'

$check = Join-Path $scriptDir 'Test-FoundryDirect.ps1'
if (-not (Test-Path $check)) {
    Warn 'Test-FoundryDirect.ps1 is not beside this script; skipping verification'
}
elseif (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'verify')) {
    Note 'skipped under -WhatIf'
}
else {
    $expect = if ($mode -eq 'gateway') { 'gateway' } else { 'direct' }
    $res = if ($mode -eq 'foundry-direct') { $cfg.foundryResource } else { 'unused' }
    & $check -Resource $res -Expect $expect
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '  Configured, but the health check found problems. See above.' -ForegroundColor Yellow
        Write-Host '  The configuration was written - these are things to fix, not a failed install.' -ForegroundColor DarkGray
        Write-Host ''
        exit 1
    }
}

Write-Host ''
Write-Host '  Done. Open a new terminal, and reload VS Code if it is running.' -ForegroundColor Green
Write-Host ''
exit 0
