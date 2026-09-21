<#
.SYNOPSIS
    Configures Claude Code to talk straight to Microsoft Foundry, with no
    gateway in front of it.

.DESCRIPTION
    This is the direct path: your Entra token goes to Foundry, and nothing
    meters, attributes or limits it. That is the point of it for a spike, and
    the reason it is not what a fleet should run - see the note at the end.

    Three sign-in modes:

      device        az login --use-device-code. Use on a box with no browser,
                    over SSH, or in a container. Prints a code to enter on
                    another machine.
      interactive   az login. Opens a browser on this machine.
      current       whatever az is already signed in to. Verifies and moves on.

    Claude Code's Foundry mode resolves the caller with DefaultAzureCredential,
    which picks up the Azure CLI sign-in. So signing in with az is what makes
    this work; the environment variables only say where to send the request.

.PARAMETER Resource
    The Foundry (AIServices) account name - not a URL, not a resource id.
    Example: ai-contosohub530569751908

.PARAMETER TenantId
    Entra tenant to sign in to. Required when your account exists in more than
    one tenant, or when you are a guest, because the default is rarely the one
    holding the Foundry resource.

.PARAMETER ClientId
    Optional. An app registration to sign in as, when your organisation
    requires its own client rather than the Azure CLI's. Leave it off unless
    you were given one.

.PARAMETER Auth
    device, interactive or current. Default: device.

.PARAMETER Models
    Deployment names to allow. Default discovers them from the resource.

.EXAMPLE
    .\Setup-ClaudeFoundryDirect.ps1 -Resource ai-contosohub530569751908 -TenantId 16b3c013-d300-468d-ac64-7eda0820b6d3

.EXAMPLE
    .\Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso -TenantId <guid> -Auth interactive
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][string]$Resource,
    [string]$TenantId,
    [string]$ClientId,
    [ValidateSet('device', 'interactive', 'current')][string]$Auth = 'device',
    [string[]]$Models,
    [switch]$SkipVerify,
    [switch]$ShowConfig,
    # A file or URL holding the answers, so a developer is handed one thing
    # rather than asked to type four. Same shape and same idea as the gateway's
    # claude-gateway.json - see docs/FOUNDRY-DIRECT.md for the schema.
    [string]$ConfigPath,
    # Where to write that file after a successful run, so the machine that was
    # set up first can produce the file for everybody else.
    [string]$WriteConfig
)

$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 0. the file
#
# Read before anything else, and explicit arguments still win. An operator who
# passes both a config and a -Resource means the override, not a merge conflict.
if ($ConfigPath) {
    $raw = if ($ConfigPath -match '^https?://') {
        (Invoke-WebRequest -Uri $ConfigPath -UseBasicParsing -TimeoutSec 30).Content
    } else {
        if (-not (Test-Path $ConfigPath)) { throw "No config at $ConfigPath" }
        Get-Content $ConfigPath -Raw
    }
    $cfg = try { $raw | ConvertFrom-Json } catch { throw "$ConfigPath is not valid JSON. $($_.Exception.Message)" }

    if ($cfg.mode -and $cfg.mode -ne 'foundry-direct') {
        # The gateway file has the same extension and a different meaning.
        # Applying one as the other produces a machine pointed at a URL that is
        # not a Foundry resource, and an error that says nothing about which
        # file was wrong.
        throw "$ConfigPath is a '$($cfg.mode)' config, not foundry-direct. For a gateway config use Setup-ClaudeWorkstation.ps1."
    }
    if ($cfg.gatewayUrl -and -not $cfg.foundryResource) {
        throw "$ConfigPath looks like a gateway config (it has gatewayUrl). Use Setup-ClaudeWorkstation.ps1 with it instead."
    }

    if (-not $Resource -and $cfg.foundryResource) { $Resource = $cfg.foundryResource }
    if (-not $TenantId -and $cfg.tenantId)        { $TenantId = $cfg.tenantId }
    if (-not $ClientId -and $cfg.clientId)        { $ClientId = $cfg.clientId }
    if (-not $PSBoundParameters.ContainsKey('Auth') -and $cfg.auth) { $Auth = $cfg.auth }
    if ((-not $Models -or $Models.Count -eq 0) -and $cfg.models) { $Models = @($cfg.models) }
}

if (-not $ShowConfig -and -not $Resource) {
    throw "-Resource is required, or pass -ConfigPath. Use -ShowConfig to read the settings off a machine that already works."
}

Write-Host ''
if (-not $ShowConfig) {
    Write-Host 'Claude Code -> Microsoft Foundry, direct' -ForegroundColor White
    Write-Host "  resource : $Resource"
    Write-Host "  tenant   : $(if ($TenantId) { $TenantId } else { '(account default)' })"
    Write-Host "  sign-in  : $Auth"
}
else {
    Write-Host 'Claude Code configuration on this machine' -ForegroundColor White
}

# ---------------------------------------------------------------- 0. export
#
# "How do I get the settings off a machine that already works?" There is no
# separate config file for the direct path - the configuration IS
# ~/.claude/settings.json. This prints the part that matters, so it can be
# read over a call or pasted into a ticket without sending the whole file.
if ($ShowConfig) {
    $p = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path $p)) {
        Bad "No settings.json at $p"
        Write-Host ''
        Note 'That is not a fault. Claude Code creates .claude\ the first time it runs -'
        Note 'sessions, projects and telemetry appear there from using it - but'
        Note 'settings.json is only written when something configures it. A machine'
        Note 'showing only those folders has never been pointed at Foundry or a gateway,'
        Note 'so there is nothing on it to copy.'
        Write-Host ''
        Note 'Configure it instead of exporting from it:'
        Note '  .\Setup-ClaudeFoundryDirect.ps1 -Resource <foundry-account> -TenantId <guid>'
        Write-Host ''
        Note 'If a colleague has a working machine, ask them to run -ShowConfig there.'
        Note 'It prints the exact command to reproduce it.'
        Write-Host ''
        return
    }
    $s = Get-Content $p -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host "  from: $p" -ForegroundColor DarkGray
    Write-Host ''
    if ($s.env) {
        foreach ($k in $s.env.PSObject.Properties.Name) {
            Write-Host ("    {0,-32} {1}" -f $k, $s.env.$k)
        }
    }
    if ($s.availableModels) {
        Write-Host ("    {0,-32} {1}" -f 'availableModels', ($s.availableModels -join ', '))
    }
    Write-Host ''
    Write-Host '  Nothing above is a secret - they are resource names and directory ids.' -ForegroundColor DarkGray
    Write-Host '  The credential is your Entra sign-in and is not stored in this file.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  To reproduce this machine elsewhere:' -ForegroundColor DarkGray
    if ($s.env.ANTHROPIC_FOUNDRY_RESOURCE) {
        $t = if ($s.env.AZURE_TENANT_ID) { $s.env.AZURE_TENANT_ID } else { '<tenant-guid>' }
        Write-Host ("    .\Setup-ClaudeFoundryDirect.ps1 -Resource {0} -TenantId {1}" -f `
            $s.env.ANTHROPIC_FOUNDRY_RESOURCE, $t) -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Or as a file to hand over, which is the same thing without the typing:' -ForegroundColor DarkGray
        Write-Host ''
        $export = [ordered]@{
            mode            = 'foundry-direct'
            generated       = (Get-Date -Format 'yyyy-MM-dd HH:mm')
            foundryResource = $s.env.ANTHROPIC_FOUNDRY_RESOURCE
            tenantId        = $t
            clientId        = $(if ($s.env.AZURE_CLIENT_ID) { $s.env.AZURE_CLIENT_ID } else { '' })
            auth            = 'device'
            models          = @($s.availableModels)
            defaults        = [ordered]@{
                opus   = $s.env.ANTHROPIC_DEFAULT_OPUS_MODEL
                sonnet = $s.env.ANTHROPIC_DEFAULT_SONNET_MODEL
                haiku  = $s.env.ANTHROPIC_DEFAULT_HAIKU_MODEL
            }
        }
        ($export | ConvertTo-Json -Depth 6) -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '    Save that as claude-foundry-direct.json, then on the other machine:' -ForegroundColor DarkGray
        Write-Host '      .\Setup-ClaudeFoundryDirect.ps1 -ConfigPath .\claude-foundry-direct.json' -ForegroundColor DarkGray
    }
    elseif ($s.env.ANTHROPIC_FOUNDRY_BASE_URL) {
        Write-Host '    This machine is on a gateway, not the direct path. Either hand the' -ForegroundColor DarkGray
        Write-Host '    other machine the gateway setup and its claude-gateway.json, or copy' -ForegroundColor DarkGray
        Write-Host '    this file across and sign in there:' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host ("      copy `"{0}`" \\<machine>\c`$\Users\<them>\.claude\" -f $p) -ForegroundColor DarkGray
        Write-Host '      az login --tenant <same-tenant-as-here>' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    The file holds no credential, so copying it grants nothing on its own -' -ForegroundColor DarkGray
        Write-Host '    they still have to be entitled and signed in.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '    This machine has a settings.json but no Foundry configuration in it,' -ForegroundColor DarkGray
        Write-Host '    so it is running Claude on the default Anthropic path.' -ForegroundColor DarkGray
    }
    Write-Host ''
    return
}

# ---------------------------------------------------------------- 1. az present
Step 'Azure CLI'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Bad 'az is not on PATH.'
    Note 'Install it: https://aka.ms/installazurecliwindows, then reopen this terminal.'
    throw 'Azure CLI required.'
}
# Read from the JSON rather than a --query with embedded quotes, which
# PowerShell strips before az ever sees them.
$azVer = try { (az version -o json 2>$null | ConvertFrom-Json).'azure-cli' } catch { $null }
Ok ("az " + $(if ($azVer) { $azVer } else { '(version unknown)' }))

# ---------------------------------------------------------------- 2. sign in
Step 'Sign in'
$loginArgs = @('login')
if ($Auth -eq 'device') { $loginArgs += '--use-device-code' }
if ($TenantId)          { $loginArgs += @('--tenant', $TenantId) }

if ($Auth -eq 'current') {
    $who = az account show --query 'user.name' -o tsv 2>$null
    if (-not $who) {
        Bad 'Not signed in, and -Auth current was asked for.'
        Note 'Run again with -Auth device or -Auth interactive.'
        throw 'No existing sign-in.'
    }
    Ok "already signed in as $who"
}
else {
    if ($Auth -eq 'device') {
        Note 'A code will be printed. Open the URL on any device and enter it.'
    }
    az @loginArgs --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw 'Sign-in failed. Nothing was changed.' }
    Ok (az account show --query 'user.name' -o tsv)
}

$signedInTenant = az account show --query tenantId -o tsv 2>$null
if ($TenantId -and $signedInTenant -and ($signedInTenant.Trim() -ne $TenantId)) {
    Bad "Signed in to tenant $signedInTenant, not $TenantId."
    Note 'The Foundry resource is almost certainly not visible from that directory.'
    throw 'Wrong tenant.'
}
Ok "tenant $signedInTenant"

# ---------------------------------------------------------------- 3. the token
#
# Claude Code asks for a data-plane token for Cognitive Services. Getting one
# here proves the sign-in is usable before anything is written to disk - a
# config file that looks right but cannot authenticate is harder to diagnose
# than a refusal now.
Step 'Data-plane token'
$token = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
if (-not $token) {
    Bad 'Could not get a token for https://cognitiveservices.azure.com'
    Note 'Usually one of: the account has no subscription in this tenant, or'
    Note 'conditional access blocked it. Run the same command without -o tsv to see why:'
    Note '  az account get-access-token --resource https://cognitiveservices.azure.com'
    throw 'No data-plane token.'
}
Ok 'acquired'

# ---------------------------------------------------------------- 4. the models
Step 'Claude deployments'
$baseUrl = "https://$Resource.services.ai.azure.com/anthropic"
if (-not $Models -or $Models.Count -eq 0) {
    # Discovered rather than assumed. A deployment name that does not exist
    # fails later as DeploymentNotFound, mid-session, which reads like a bug in
    # Claude Code rather than a setting.
    #
    # Filtered to Succeeded: a Disabled deployment is listed and accepted here
    # and then refuses every call, which is the same failure wearing a different
    # hat. Measured on the reference resource, two of the deployments on it are
    # Disabled.
    $rg = az cognitiveservices account list --query "[?name=='$Resource'].resourceGroup | [0]" -o tsv 2>$null
    if ($rg) { $rg = $rg.Trim() }
    $found = $null
    if ($rg) {
        $found = az cognitiveservices account deployment list --name $Resource --resource-group $rg `
                    --query "[?properties.model.format=='Anthropic' && properties.provisioningState=='Succeeded'].name" `
                    -o tsv 2>$null
    }
    if ($found) {
        $Models = @($found -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        Ok ("$($Models.Count) found on $Resource")
        foreach ($m in $Models) { Note "  $m" }
    }
    else {
        $Models = @('claude-sonnet-5')
        Note 'Could not list deployments - you may lack reader rights on the resource,'
        Note 'or it is in a subscription this account cannot see.'
        Note "Assuming: $($Models -join ', '). Pass -Models to set them explicitly."
    }
}
else {
    Ok ($Models -join ', ')
}

# ---------------------------------------------------------------- 5. write it
Step 'Claude Code settings'
$claudeDir = Join-Path $env:USERPROFILE '.claude'
$settingsPath = Join-Path $claudeDir 'settings.json'
New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null

$settings = if (Test-Path $settingsPath) {
    try { Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { [pscustomobject]@{} }
} else { [pscustomobject]@{} }

if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.bak" -Force
    Note "existing settings backed up to settings.json.bak"
}

$envBlock = [ordered]@{
    CLAUDE_CODE_USE_FOUNDRY    = '1'
    # The resource name, not a URL. ANTHROPIC_FOUNDRY_RESOURCE and
    # ANTHROPIC_FOUNDRY_BASE_URL are mutually exclusive - setting both ends the
    # session with "baseURL and resource are mutually exclusive". The base URL
    # is the gateway path; this script is the direct one, so it uses the
    # resource and removes any base URL a gateway setup left behind.
    ANTHROPIC_FOUNDRY_RESOURCE = $Resource
}
if ($TenantId) { $envBlock['AZURE_TENANT_ID'] = $TenantId }
if ($ClientId) { $envBlock['AZURE_CLIENT_ID'] = $ClientId }

$sonnet = $Models | Where-Object { $_ -match 'sonnet' } | Select-Object -First 1
$opus   = $Models | Where-Object { $_ -match 'opus' }   | Select-Object -First 1
if ($opus)   { $envBlock['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $opus }
if ($sonnet) {
    $envBlock['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $sonnet
    # Claude Code uses a small model for background work. Pointing it at a
    # deployment that exists stops mid-session DeploymentNotFound errors.
    $envBlock['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $sonnet
}

$settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]$envBlock) -Force
$settings | Add-Member -NotePropertyName 'availableModels' -NotePropertyValue @($Models) -Force
$settings | Add-Member -NotePropertyName 'enforceAvailableModels' -NotePropertyValue $true -Force

# Left over from a gateway setup, and fatal if both survive.
if ($settings.env.PSObject.Properties.Name -contains 'ANTHROPIC_FOUNDRY_BASE_URL') {
    $settings.env.PSObject.Properties.Remove('ANTHROPIC_FOUNDRY_BASE_URL')
    Note 'removed ANTHROPIC_FOUNDRY_BASE_URL (gateway setting, conflicts with direct)'
}

$settings | ConvertTo-Json -Depth 8 | Set-Content $settingsPath -Encoding UTF8
Ok $settingsPath

# ---------------------------------------------------------------- 6. prove it
if (-not $SkipVerify) {
    Step 'Round trip'
    $model = if ($sonnet) { $sonnet } else { $Models[0] }
    $body = @{
        model      = $model
        max_tokens = 16
        messages   = @(@{ role = 'user'; content = 'Reply with exactly: FOUNDRY-OK' })
    } | ConvertTo-Json -Depth 6

    try {
        $r = Invoke-RestMethod -Method Post -Uri "$baseUrl/v1/messages" `
                -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } `
                -ContentType 'application/json' -Body $body -ErrorAction Stop
        Ok ("Foundry answered: " + $r.content[0].text)
    }
    catch {
        Bad "The call failed: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { Note $_.ErrorDetails.Message }
        Note ''
        Note 'Most common causes, in order:'
        Note '  403  you lack Cognitive Services User on the resource'
        Note '  404  the deployment name does not exist - check -Models'
        Note '  401  the token is for the wrong tenant'
        throw 'Verification failed. Settings were still written.'
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host '  Start a new terminal, then run: claude' -ForegroundColor DarkGray
Write-Host '  Confirm the backend with: /status' -ForegroundColor DarkGray

# ---------------------------------------------------------------- 7. the file
#
# So the machine set up first can produce the thing every other machine is
# handed, rather than each developer being told four values to type.
if ($WriteConfig) {
    $out = [ordered]@{
        mode            = 'foundry-direct'
        generated       = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        foundryResource = $Resource
        tenantId        = $signedInTenant
        clientId        = $ClientId
        auth            = $Auth
        models          = @($Models)
        defaults        = [ordered]@{
            opus   = $opus
            sonnet = $sonnet
            haiku  = $sonnet
        }
    }
    $dir = Split-Path $WriteConfig -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $out | ConvertTo-Json -Depth 6 | Set-Content $WriteConfig -Encoding UTF8
    Write-Host ''
    Ok "config written to $WriteConfig"
    Note 'Hand that to anyone else who needs the same setup:'
    Note "  ./scripts/Setup-ClaudeFoundryDirect.ps1 -ConfigPath $WriteConfig"
    Note 'It holds no credential - they still sign in as themselves.'
}

Write-Host ''
Write-Host '  This is the DIRECT path. Your token goes to Foundry and nothing' -ForegroundColor Yellow
Write-Host '  meters, attributes or limits it - no per-developer budget, no' -ForegroundColor Yellow
Write-Host '  chargeback, and removing someone from a group does not revoke it.' -ForegroundColor Yellow
Write-Host '  Fine for a spike. Use the gateway for a fleet.' -ForegroundColor Yellow
Write-Host ''
