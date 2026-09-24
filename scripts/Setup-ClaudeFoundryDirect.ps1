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
    Example: ai-contoso-foundry

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
    .\Setup-ClaudeFoundryDirect.ps1 -Resource ai-contoso-foundry -TenantId 00000000-0000-0000-0000-000000000000

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
    # Claude Desktop holds its configuration in memory and rewrites it on exit,
    # so it has to be closed before we write. Default is to ask; -Force closes
    # it without asking, for unattended runs.
    [switch]$SkipDesktop,
    [switch]$SkipVSCode,
    [switch]$Force,
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

# Which deployment is Opus, and which is Sonnet? Deployment names are chosen by
# whoever created them, so the name is not evidence. properties.model.name is.
# Matching on the name alone works only where someone happened to name the
# deployment after its model, and silently sets nothing where they did not -
# at which point Claude Code falls back to its own built-in model names, none
# of which exist on a Foundry resource.
function Find-Deployment {
    param([object[]]$Pool, [string]$Family)
    $hit = $Pool | Where-Object { $_.model -and $_.model -match $Family } | Select-Object -First 1
    if (-not $hit) { $hit = $Pool | Where-Object { $_.name -match $Family } | Select-Object -First 1 }
    if ($hit) { $hit.name } else { $null }
}

# The error Foundry returns on a refused call names a "Principal" and nothing
# else, and on this path the principal is very often not the person reading the
# message - the Azure Identity chain puts environment variables ahead of the
# signed-in CLI user. Reading the token is the only way to see who actually
# called. Everything below is measured; nothing is guessed.
function ConvertFrom-JwtPayload {
    param([string]$Token)
    try {
        $p = $Token.Split('.')[1]
        $p = $p.Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } 1 { $p += '===' } }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    } catch { $null }
}

function Resolve-FoundryDenial {
    param([string]$Token, [string]$Resource, [string]$Deployment, [int]$Status)

    $claims = ConvertFrom-JwtPayload -Token $Token
    if (-not $claims) { Note 'Could not read the token, so this cannot be diagnosed further.'; return }

    $who = if ($claims.upn) { $claims.upn }
           elseif ($claims.unique_name) { $claims.unique_name }
           elseif ($claims.app_displayname) { "$($claims.app_displayname) (application)" }
           elseif ($claims.appid) { "application $($claims.appid)" }
           else { '<unnamed principal>' }

    Write-Host '  The call was made as:' -ForegroundColor White
    Note "  principal : $who"
    Note "  object id : $($claims.oid)"
    Note "  tenant    : $($claims.tid)"
    Note "  audience  : $($claims.aud)"

    # A 404 is never an authorisation problem. Azure has accepted the caller and
    # is saying the deployment is not there, so walking the role ladder below
    # would be noise dressed up as diagnosis.
    if ($Status -eq 404) {
        Write-Host ''
        Write-Host "  Authentication succeeded. '$Deployment' is not a deployment on this resource." -ForegroundColor Yellow
        $rg404 = az cognitiveservices account list --query "[?name=='$Resource'].resourceGroup | [0]" -o tsv 2>$null
        if ($rg404) {
            $rg404 = $rg404.Trim()
            $real = az cognitiveservices account deployment list --name $Resource --resource-group $rg404 `
                        --query "[?properties.model.format=='Anthropic' && properties.provisioningState=='Succeeded'].name" -o tsv 2>$null
            if ($real) {
                Note 'Anthropic deployments that do exist here:'
                foreach ($n in ($real -split "`r?`n" | Where-Object { $_ })) { Note "  $($n.Trim())" }
                Note ''
                Note 'Re-run without -Models and these are discovered automatically.'
            }
            else {
                Note 'This resource has no Succeeded Anthropic deployment at all.'
                Note 'Deploy a Claude model on it before configuring a client.'
            }
        }
        return
    }

    # The az CLI's own token carries an appid alongside the user claims, so appid
    # alone does not mean a service principal. Absence of any user claim does.
    if ($claims.appid -and -not $claims.upn -and -not $claims.unique_name) {
        Write-Host ''
        Write-Host '  That is a service principal, not you.' -ForegroundColor Yellow
        Note 'Something in the environment is ahead of your signed-in CLI user.'
        Note 'Check, then clear it or grant it access:'
        Note '  Get-ChildItem Env: | Where-Object Name -match ''AZURE_CLIENT_ID|AZURE_CLIENT_SECRET'''
    }

    # Is the resource even in the tenant this token was minted for? An account
    # in the wrong tenant produces a valid token for a principal that tenant
    # has never heard of, which is exactly what the message describes.
    $rg = az cognitiveservices account list --query "[?name=='$Resource'].resourceGroup | [0]" -o tsv 2>$null
    if ($rg) { $rg = $rg.Trim() }
    Write-Host ''
    if (-not $rg) {
        Write-Host "  $Resource is not visible from tenant $($claims.tid)." -ForegroundColor Yellow
        Note 'This is a tenant problem, not a role problem. No role assignment in'
        Note 'this tenant can grant access to a resource in another one.'
        Note ''
        Note 'Sign in to the tenant that owns it, then record it so every session uses it:'
        Note '  az login --tenant <owning-tenant-guid>'
        Note "  .\Setup-ClaudeFoundryDirect.ps1 -Resource $Resource -TenantId <owning-tenant-guid>"
        return
    }
    Ok "$Resource found in resource group $rg"

    # Both Foundry User and Cognitive Services User carry the same data action,
    # so naming one role is misleading. Ask what this principal actually holds,
    # at this scope, and whether any of it reaches the data plane.
    $scope = az cognitiveservices account show -n $Resource -g $rg --query id -o tsv 2>$null
    if ($scope) { $scope = $scope.Trim() }
    $roles = @()
    if ($scope -and $claims.oid) {
        $raw = az role assignment list --assignee $claims.oid --scope $scope --include-inherited `
                  --query "[].roleDefinitionName" -o tsv 2>$null
        if ($raw) { $roles = @($raw -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique) }
    }

    Write-Host ''
    if ($roles.Count -eq 0) {
        Write-Host '  This principal holds no role on the resource.' -ForegroundColor Yellow
        Note 'Either of these grants the data plane - they carry the same data action:'
        Note ('  az role assignment create --assignee ' + $claims.oid)
        Note ('    --role "Cognitive Services User" --scope ' + $scope)
        Note ''
        Note 'A new assignment can take a few minutes to take effect.'
        return
    }

    Write-Host '  Roles held at this scope:' -ForegroundColor White
    foreach ($r in $roles) { Note "  $r" }

    # Rather than hard-coding which role names count, ask Azure which of the
    # roles actually held carry a Cognitive Services data action.
    $dataCapable = @()
    foreach ($r in $roles) {
        $da = az role definition list --name $r --query "[0].permissions[0].dataActions" -o tsv 2>$null
        if (-not $da) { continue }
        # Must be the unrestricted wildcard. A substring test for
        # "Microsoft.CognitiveServices" also matches
        # Microsoft.CognitiveServices/accounts/OpenAI/*, which is what Azure AI
        # Developer and Cognitive Services OpenAI User hold - and Claude is not
        # served under accounts/OpenAI, so those grant nothing here. Measured
        # across the built-in roles: five carry the unrestricted form.
        $actions = @($da -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($actions -contains 'Microsoft.CognitiveServices/*') { $dataCapable += $r }
    }

    Write-Host ''
    if ($dataCapable.Count -gt 0) {
        $verb = if ($dataCapable.Count -eq 1) { 'grants' } else { 'grant' }
        Write-Host "  $($dataCapable -join ' and ') $verb data-plane access." -ForegroundColor Yellow
        Note 'So the role name is not the problem. What is left, in order:'
        Note ''
        Note '  - The assignment is new. Propagation takes a few minutes; try again.'
        Note '  - The assignment may be on a project inside this account rather'
        Note '    than on the account itself. A role on a project does not cover'
        Note '    the account-level endpoint this client calls. Check the scope:'
        Note ('      az role assignment list --assignee ' + $claims.oid + ' --all -o table')
        Note '  - The resource may restrict network access. Check its firewall and'
        Note '    whether it requires a private endpoint:'
        Note "      az cognitiveservices account show -n $Resource -g $rg --query properties.networkAcls"
    }
    else {
        Write-Host '  None of those roles reaches Claude on this resource.' -ForegroundColor Yellow
        # The two most plausible-looking AI roles are both scoped to OpenAI
        # models. Claude is not served under accounts/OpenAI, so they grant
        # nothing here and the refusal looks identical to holding no role.
        $openAiOnly = $roles | Where-Object { $_ -in @('Azure AI Developer', 'Cognitive Services OpenAI User', 'Cognitive Services OpenAI Contributor') }
        if ($openAiOnly) {
            Note ($openAiOnly -join ' and ') 
            Note 'is scoped to accounts/OpenAI/* only. Claude on Foundry is not served'
            Note 'there, so it grants nothing on this endpoint even though it reads as'
            Note 'the obvious AI role.'
            Note ''
        }
        Note 'Add a role carrying the unrestricted Microsoft.CognitiveServices data'
        Note 'action. Cognitive Services User is the least-privilege one:'
        Note ('  az role assignment create --assignee ' + $claims.oid)
        Note ('    --role "Cognitive Services User" --scope ' + $scope)
    }
}

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
$deployments = @()
if (-not $Models -or $Models.Count -eq 0) {
    # Discovered rather than assumed. A deployment name that does not exist
    # fails later as DeploymentNotFound, mid-session, which reads like a bug in
    # Claude Code rather than a setting.
    #
    # Filtered to Succeeded: a Disabled deployment is listed and accepted here
    # and then refuses every call, which is the same failure wearing a different
    # hat. Measured on the reference resource, two of the deployments on it are
    # Disabled.
    #
    # Both the name and the model are taken. The name is what Claude Code sends;
    # the model is the only thing that says which Claude it actually is. Naming
    # a deployment after its model is a convention, not a rule - see below.
    $rg = az cognitiveservices account list --query "[?name=='$Resource'].resourceGroup | [0]" -o tsv 2>$null
    if ($rg) { $rg = $rg.Trim() }
    $found = $null
    if ($rg) {
        $found = az cognitiveservices account deployment list --name $Resource --resource-group $rg `
                    --query "[?properties.model.format=='Anthropic' && properties.provisioningState=='Succeeded'].{name:name, model:properties.model.name}" `
                    -o json 2>$null
    }
    if ($found) { try { $deployments = @($found | ConvertFrom-Json) } catch { $deployments = @() } }

    if ($deployments.Count -gt 0) {
        $Models = @($deployments | ForEach-Object { $_.name })
        Ok ("$($Models.Count) found on $Resource")
        foreach ($d in $deployments) {
            if ($d.name -eq $d.model) { Note "  $($d.name)" }
            else { Note "  $($d.name)  ->  $($d.model)" }
        }
    }
    else {
        # Assuming a name here writes a deployment that may not exist into the
        # settings file, and the run then "succeeds" into a DeploymentNotFound
        # several minutes later. Refusing costs one more command and says the
        # true thing.
        Bad "No Anthropic deployments could be listed on $Resource."
        Write-Host ''
        Note 'Either this account cannot read the resource, or the resource has none.'
        Note 'Check which it is:'
        Note "  az cognitiveservices account deployment list --name $Resource --resource-group <rg> -o table"
        Write-Host ''
        Note 'If you already know the deployment names, pass them and skip discovery:'
        Note "  .\Setup-ClaudeFoundryDirect.ps1 -Resource $Resource -Models <name>[,<name>]"
        Write-Host ''
        throw "Cannot configure $Resource without knowing its deployment names."
    }
}
else {
    # Supplied by hand, so there is no model to read. Aliases fall back to
    # matching the name, which is why -Models is the less reliable route.
    $deployments = @($Models | ForEach-Object { [pscustomobject]@{ name = $_; model = $_ } })
    Ok ($Models -join ', ')
}

# ---------------------------------------------------------------- 5. prove access
# Signing in proves nothing. Every signed-in account gets a token, including one
# for a tenant that has never heard of this resource - which is exactly the case
# that produces "Principal does not have access to API/Operation" later, in
# Claude Code, where it reads as a broken install.
#
# The only evidence that this machine can use this resource is a real call, and
# it belongs here rather than at the end: a machine that cannot reach Foundry is
# then left exactly as it was found, instead of carrying a settings file that
# points somewhere it cannot go.
$probeModel = Find-Deployment -Pool $deployments -Family 'sonnet'
if (-not $probeModel) { $probeModel = $deployments[0].name }

if (-not $SkipVerify) {
    Step 'Access check'
    Note "calling $probeModel on $Resource"
    $probeBody = @{
        model      = $probeModel
        max_tokens = 16
        messages   = @(@{ role = 'user'; content = 'Reply with exactly: FOUNDRY-OK' })
    } | ConvertTo-Json -Depth 6

    try {
        $probe = Invoke-RestMethod -Method Post -Uri "$baseUrl/v1/messages" `
                    -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' } `
                    -ContentType 'application/json' -Body $probeBody -ErrorAction Stop
        Ok ('Foundry answered: ' + $probe.content[0].text)
    }
    catch {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        Bad "The call failed: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { Note $_.ErrorDetails.Message }
        Write-Host ''
        Resolve-FoundryDenial -Token $token -Resource $Resource -Deployment $probeModel -Status $status
        Write-Host ''
        Note 'Nothing was written. This machine is unchanged.'
        throw "Cannot reach $Resource as the signed-in principal."
    }
}
else {
    Note 'Access check skipped (-SkipVerify). Settings are being written unverified.'
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

$sonnet = Find-Deployment -Pool $deployments -Family 'sonnet'
$opus   = Find-Deployment -Pool $deployments -Family 'opus'
$haiku  = Find-Deployment -Pool $deployments -Family 'haiku'

# Every alias has to name a deployment that exists here. Leaving one unset does
# not mean "unused" - Claude Code falls back to its own built-in model name for
# that family, and that name is not a deployment on anybody's Foundry resource.
# Measured on a resource carrying only claude-opus-4-7: the Sonnet alias went
# unset and every turn that selected Sonnet failed with DeploymentNotFound.
$fallback = if ($sonnet) { $sonnet } elseif ($opus) { $opus } else { $deployments[0].name }
$envBlock['ANTHROPIC_DEFAULT_OPUS_MODEL']   = if ($opus)   { $opus }   else { $fallback }
$envBlock['ANTHROPIC_DEFAULT_SONNET_MODEL'] = if ($sonnet) { $sonnet } else { $fallback }
# Claude Code uses a small model for background work.
$envBlock['ANTHROPIC_DEFAULT_HAIKU_MODEL']  = if ($haiku)  { $haiku }  else { $fallback }

$substituted = @()
if (-not $opus)   { $substituted += 'opus' }
if (-not $sonnet) { $substituted += 'sonnet' }
if (-not $haiku)  { $substituted += 'haiku' }
if ($substituted.Count -gt 0) {
    Note "no $($substituted -join ', ') deployment here - those aliases point at $fallback"
}

if (-not $sonnet -and -not $opus) {
    Note 'Nothing here identifies as Sonnet or Opus by model or by name.'
    Note "Every alias points at $fallback, which does exist."
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

# ---------------------------------------------------------------- 6. VS Code
# The extension reads the same ~/.claude/settings.json and its own setting
# description says to prefer it, so this is belt and braces rather than
# required. It matters on a machine where someone has previously set these in
# VS Code by hand: a stale gateway URL there outlives the file we just wrote.
if (-not $SkipVSCode) {
    Step 'VS Code'
    $codeSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (-not (Test-Path (Split-Path $codeSettings))) {
        Note 'VS Code user settings folder not found - skipping.'
    }
    else {
        $doc = $null
        if (Test-Path $codeSettings) {
            Copy-Item $codeSettings "$codeSettings.bak" -Force
            # settings.json is JSONC - VS Code ships it with comments, and
            # ConvertFrom-Json refuses them. Strip comments and trailing commas
            # rather than abandoning a file that is valid for its own editor.
            $rawCode = Get-Content $codeSettings -Raw
            $noBlock = [regex]::Replace($rawCode, '/\*[\s\S]*?\*/', '')
            $noLine  = ($noBlock -split "`r?`n" | ForEach-Object { if ($_ -match '^\s*//') { '' } else { $_ } }) -join "`n"
            $clean   = [regex]::Replace($noLine, ',(\s*[}\]])', '$1')
            try { $doc = $clean | ConvertFrom-Json } catch {
                Note 'settings.json could not be parsed even after removing comments.'
                Note 'Leaving it alone; the CLI settings file is what matters, and the'
                Note 'extension reads that.'
                $doc = $null
            }
        }
        else { $doc = [pscustomobject]@{} }

        if ($doc) {
            # An array of {name, value}, per the extension's own schema. A map
            # is accepted by the JSON editor and silently does nothing.
            $vars = @(
                @{ name = 'CLAUDE_CODE_USE_FOUNDRY';    value = '1' }
                @{ name = 'ANTHROPIC_FOUNDRY_RESOURCE'; value = $Resource }
            )
            if ($TenantId) { $vars += @{ name = 'AZURE_TENANT_ID'; value = $TenantId } }
            foreach ($k in @('ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL','ANTHROPIC_DEFAULT_HAIKU_MODEL')) {
                if ($envBlock[$k]) { $vars += @{ name = $k; value = $envBlock[$k] } }
            }
            $doc | Add-Member -NotePropertyName 'claudeCode.environmentVariables' -NotePropertyValue $vars -Force
            $doc | ConvertTo-Json -Depth 8 | Set-Content $codeSettings -Encoding UTF8
            Ok $codeSettings
            Note 'Run "Developer: Reload Window" in VS Code - the extension host reads'
            Note 'configuration at startup and will not see this in an open window.'
        }
    }
}

# ---------------------------------------------------------------- 7. Desktop
# Claude Desktop cannot read ~/.claude/settings.json. It takes a base URL and a
# credential helper, which is the same helper the gateway path uses - it prints
# an Entra token for the Cognitive Services data plane, and both paths accept
# exactly that.
if (-not $SkipDesktop) {
    Step 'Claude Desktop'

    $desktopInstalled = $false
    try {
        if (Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue) { $desktopInstalled = $true }
    } catch { }
    $running = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) { $desktopInstalled = $true }

    if (-not $desktopInstalled) {
        Note 'Claude Desktop is not installed on this machine - skipping.'
    }
    else {
        # It rewrites its configuration on exit, so anything written underneath
        # a running instance is lost the moment the user quits.
        if ($running.Count -gt 0) {
            $close = $Force
            if (-not $close) {
                Write-Host ''
                Write-Host '  Claude Desktop is running. It rewrites its configuration when it' -ForegroundColor Yellow
                Write-Host '  exits, so anything written now would be discarded.' -ForegroundColor Yellow
                $answer = Read-Host '  Close it and continue? [y/N]'
                $close = ($answer -match '^(y|yes)$')
            }
            if (-not $close) {
                Note 'Left running. Desktop was not configured; the CLI and VS Code were.'
                Note 'Re-run with -Force, or close Desktop and run again.'
                $desktopInstalled = $false
            }
            else {
                foreach ($p in $running) {
                    try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Note "could not stop pid $($p.Id): $($_.Exception.Message)" }
                }
                Start-Sleep -Seconds 2
                $still = @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)
                if ($still.Count -gt 0) {
                    Bad 'Claude Desktop is still running. Quit it from the tray icon, then re-run.'
                    $desktopInstalled = $false
                }
                else { Ok 'closed' }
            }
        }
    }

    if ($desktopInstalled) {
        # The same location the gateway path uses. Two helper directories means
        # a machine that has run both scripts has two copies, and a profile can
        # end up pointing at the stale one.
        $helperDir = Join-Path $env:LOCALAPPDATA 'ClaudeFoundry'
        New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
        $helperCmd = Join-Path $helperDir 'get-foundry-token.cmd'
        $srcPs1 = Join-Path $PSScriptRoot 'get-foundry-token.ps1'
        $srcCmd = Join-Path $PSScriptRoot 'get-foundry-token.cmd'
        if ((Test-Path $srcPs1) -and (Test-Path $srcCmd)) {
            Copy-Item $srcPs1 (Join-Path $helperDir 'get-foundry-token.ps1') -Force
            Copy-Item $srcCmd $helperCmd -Force
            Ok "credential helper -> $helperDir"
        }
        else {
            Bad 'get-foundry-token.ps1/.cmd not found next to this script.'
            Note 'Desktop needs them to fetch a token. The CLI and VS Code are configured.'
            $helperCmd = $null
        }

        if ($helperCmd) {
            # Presence is not the same as enabled - a file left with
            # allowDevTools false hides Settings -> Connection entirely.
            $devSettings = Join-Path $env:APPDATA 'Claude\developer_settings.json'
            New-Item -ItemType Directory -Force -Path (Split-Path $devSettings) | Out-Null
            $devDoc = $null
            if (Test-Path $devSettings) { try { $devDoc = Get-Content $devSettings -Raw | ConvertFrom-Json } catch { $devDoc = $null } }
            if ($devDoc -and $devDoc.allowDevTools -eq $true) { Ok 'developer mode already on' }
            else {
                if (-not $devDoc) { $devDoc = [pscustomobject]@{} }
                $devDoc | Add-Member -NotePropertyName 'allowDevTools' -NotePropertyValue $true -Force
                $devDoc | ConvertTo-Json -Depth 5 | Set-Content $devSettings -Encoding UTF8
                Ok 'developer mode enabled'
            }

            $lib = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
            $metaPath = Join-Path $lib '_meta.json'
            if (-not (Test-Path $metaPath)) {
                New-Item -ItemType Directory -Force -Path $lib | Out-Null
                $id = [guid]::NewGuid().ToString()
                @{ appliedId = $id; entries = @(@{ id = $id; name = 'Default' }) } |
                    ConvertTo-Json -Depth 5 | Set-Content $metaPath -Encoding UTF8
                Note 'created the profile library'
            }
            $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
            $profilePath = Join-Path $lib "$($meta.appliedId).json"
            if (Test-Path $profilePath) { Copy-Item $profilePath "$profilePath.bak" -Force }

            # Same shape the gateway path writes; only the base URL differs.
            $desktopProfile = [ordered]@{
                inferenceProvider                             = 'gateway'
                inferenceGatewayBaseUrl                       = $baseUrl
                inferenceGatewayAuthScheme                    = 'bearer'
                inferenceCredentialKind                       = 'helper-script'
                inferenceCredentialHelper                     = $helperCmd
                inferenceCredentialHelperTimeoutSec           = 60
                inferenceCredentialHelperTtlSec               = 1800
                inferenceCredentialHelperSilentRefreshEnabled = $true
                inferenceModels                               = @($Models | ForEach-Object { @{ name = $_ } })
                chatTabEnabled                                = $true
                isClaudeCodeForDesktopEnabled                 = $true
                inferenceModelPricingEnabled                  = $true
            }
            $desktopProfile | ConvertTo-Json -Depth 6 | Set-Content $profilePath -Encoding UTF8
            Ok $profilePath
            if ($TenantId) {
                # The helper needs the tenant for guests and multi-tenant
                # accounts; without it a bare az login lands in the home tenant.
                [Environment]::SetEnvironmentVariable('CLAUDE_FOUNDRY_TENANT_ID', $TenantId, 'User')
                Note "CLAUDE_FOUNDRY_TENANT_ID set for your user account"
            }
        }
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
