<#
.SYNOPSIS
    Verifies that Claude Code is correctly wired to Claude models deployed in
    Microsoft Foundry using Microsoft Entra ID (az login / managed identity).

.DESCRIPTION
    Runs seven independent checks and prints a PASS/FAIL summary:

      1. Azure CLI sign-in
      2. Entra ID data-plane token for the Foundry resource
      3. Foundry resource reachable and Claude deployments present
      4. Anthropic Messages API answers over Entra ID auth
      5. Claude Code CLI installed
      6. Claude Code reports the Foundry provider
      7. Claude Code completes a real round trip on Foundry

.PARAMETER Resource
    Foundry (AIServices) account name, e.g. ai-contosohub530569751908.

.PARAMETER ResourceGroup
    Resource group of the Foundry account. Optional; enables the deployment check.

.PARAMETER Model
    Deployment name to exercise. Defaults to one discovered on the resource -
    every resource carries different deployments, so nothing is assumed.

.EXAMPLE
    .\Test-ClaudeFoundry.ps1 -Resource ai-contosohub530569751908 -ResourceGroup rg-contosohub
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Resource,
    [string]$ResourceGroup,
    # Defaults to a deployment discovered on the resource. A hardcoded name
    # reports a 404 as though the endpoint were broken - measured on a resource
    # carrying only claude-opus-4-7, where the default claude-sonnet-5 failed
    # the Messages API check while the resource was entirely healthy.
    [string]$Model,
    # Supply the client id from Claude Desktop's Connection screen to test the
    # device-code flow it uses. That flow fails before any token exists, so no
    # role assignment can fix it and the other checks here cannot see it.
    [string]$ClientId,
    [string]$TenantId,
    # Which shape this machine is supposed to be in. Run against a healthy
    # gateway machine without this, the client checks report failures for
    # pointing at the gateway - which is correct and also not a fault.
    [ValidateSet('direct', 'gateway')][string]$Expect = 'direct',
    # Pins the subscription to look in. Without it the resource is searched
    # for across every subscription this account can see - measured at 86 on
    # one account, where the active one was not the one holding the resource.
    [string]$SubscriptionId,
    # Read-only by default. -Fix proposes each repair and asks first; -Force
    # skips the asking. Nothing here changes Azure - these are local repairs
    # to this machine, plus sign-ins.
    [switch]$Fix,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$BaseUrl = "https://$Resource.services.ai.azure.com/anthropic"
$Scope   = 'https://cognitiveservices.azure.com'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Name; Status = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
    $colour = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "Claude Code on Microsoft Foundry - verification" -ForegroundColor Cyan
Write-Host "Resource : $Resource"
Write-Host "Endpoint : $BaseUrl"
Write-Host "Model    : $(if ($Model) { $Model } else { '(discovered from the resource)' })"
# Two client versions moved under us in a single day - Desktop 2.110.1.0 to
# 2.2553.1.0, the CLI 2.1.241 to 2.1.272. The measured facts this suite relies
# on (the VS Code setting being an array of name/value objects, the Desktop
# profile key names) were read from particular builds, so a later failure can
# only be correlated if the versions are in the report.
$verCli = if (Get-Command claude -ErrorAction SilentlyContinue) { (claude --version 2>$null | Out-String).Trim() } else { 'absent' }
$verDesk = 'absent'
try { $pk = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue; if ($pk) { $verDesk = $pk.Version } } catch { }
$verExt = 'absent'
try {
    $ext = (code --list-extensions --show-versions 2>$null | Select-String 'anthropic.claude-code')
    if ($ext) { $verExt = ($ext -split '@')[-1] }
} catch { }
Write-Host "Expect   : $Expect"
Write-Host "Versions : CLI $verCli | Desktop $verDesk | extension $verExt"
Write-Host ""
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

# Finding the resource without changing anything.
#
# az cognitiveservices account list only sees the active subscription. An
# account with rights over many of them - 86 on one measured here - reports a
# resource in a neighbouring subscription as "not visible in this tenant",
# which reads as a permissions fault and is not one. So: look in the pinned
# subscription if one was named, then the active one, then across every
# subscription the account can reach.
#
# Nothing here runs 'az account set'. Changing someone's CLI context as a side
# effect of a read-only check is rude and hard to notice; switching is offered
# as a repair instead.
function Find-FoundryAccount {
    param([string]$Name, [string]$Sub)

    if ($Sub) {
        $rg = az cognitiveservices account list --subscription $Sub --query "[?name=='$Name'].resourceGroup | [0]" -o tsv 2>$null
        if ($rg) { return [pscustomobject]@{ Rg = $rg.Trim(); Sub = $Sub; Where = 'pinned subscription' } }
        return $null
    }

    $rg = az cognitiveservices account list --query "[?name=='$Name'].resourceGroup | [0]" -o tsv 2>$null
    if ($rg) {
        $cur = az account show --query id -o tsv 2>$null
        return [pscustomobject]@{ Rg = $rg.Trim(); Sub = $cur.Trim(); Where = 'active subscription' }
    }

    # Resource Graph searches every subscription in the signed-in tenant in one
    # call. Without the extension, fall back to walking them.
    $q = "resources | where type =~ 'microsoft.cognitiveservices/accounts' and name =~ '$Name' | project resourceGroup, subscriptionId"
    $hit = $null
    $raw = az graph query -q $q --first 5 -o json 2>$null | ConvertFrom-Json
    if ($raw -and $raw.data -and @($raw.data).Count -gt 0) { $hit = @($raw.data)[0] }
    if (-not $hit) {
        $subs = az account list --all --query "[].id" -o tsv 2>$null
        foreach ($s in @($subs -split "`r?`n" | Where-Object { $_ })) {
            $r2 = az cognitiveservices account list --subscription $s.Trim() --query "[?name=='$Name'].resourceGroup | [0]" -o tsv 2>$null
            if ($r2) { $hit = [pscustomobject]@{ resourceGroup = $r2.Trim(); subscriptionId = $s.Trim() }; break }
        }
    }
    if ($hit) {
        return [pscustomobject]@{ Rg = $hit.resourceGroup; Sub = $hit.subscriptionId; Where = 'another subscription' }
    }
    return $null
}

# Repairs are collected and applied at the end, so the whole picture is read
# before anything changes. Each carries the command it would run.
$repairs = [System.Collections.Generic.List[object]]::new()
function Add-Repair {
    param([string]$What, [string]$Why, [scriptblock]$Do, [string]$Command)
    $repairs.Add([pscustomobject]@{ What = $What; Why = $Why; Do = $Do; Command = $Command })
}

# 0. Can this machine reach the endpoint at all? -----------------------------
# Before any token is discussed. A resolver failure presents inside Claude Code
# as "Can't reach the API server (ENOTFOUND)", which reads like an outage and
# is usually a resource name that does not exist. Measured on a developer
# machine configured with a placeholder resource name.
$endpointHost = "$Resource.services.ai.azure.com"
$dnsOk = $false
try {
    $null = [System.Net.Dns]::GetHostEntry($endpointHost)
    $dnsOk = $true
} catch { }
Add-Result 'The endpoint name resolves' $dnsOk $(
    if ($dnsOk) { $endpointHost }
    else { "$endpointHost does not resolve - the resource name is wrong, or DNS is blocked" })
if (-not $dnsOk) {
    Note 'Claude Code reports this as ENOTFOUND and blames your internet.'
    Note 'Check the name against what Azure actually has:'
    Note '  az cognitiveservices account list --query "[].name" -o tsv'
}

# A corporate proxy changes which certificate is presented, and an intercepted
# handshake fails in a way that reads like an auth problem.
$proxyVars = @()
foreach ($n in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { $proxyVars += "$n=$v" }
}
if ($proxyVars.Count -gt 0) {
    Write-Host '  [NOTE] a proxy is configured for this shell' -ForegroundColor Yellow
    Note ($proxyVars -join '; ')
    Note 'If calls fail on TLS or certificates, the proxy is intercepting. NO_PROXY'
    Note 'should include services.ai.azure.com and login.microsoftonline.com.'
}

# 1. Azure CLI sign-in ------------------------------------------------------
$account = az account show -o json 2>$null | ConvertFrom-Json
if ($account) {
    Add-Result 'Azure CLI signed in' $true "$($account.user.name) / $($account.name)"
}
else {
    Add-Result 'Azure CLI signed in' $false "Run 'az login' (or 'az login --identity' on Azure compute)."
    $t0 = $TenantId
    Add-Repair -What 'sign in to Azure' -Why 'no CLI session on this machine' `
        -Command $(if ($t0) { "az login --tenant $t0" } else { 'az login' }) `
        -Do {
            if ($t0) { az login --tenant $t0 -o none } else { az login -o none }
            return ($LASTEXITCODE -eq 0)
        }.GetNewClosure()
}

# 2. Entra ID data-plane token ---------------------------------------------
$token = az account get-access-token --resource $Scope --query accessToken -o tsv 2>$null
if ($token) {
    Add-Result 'Entra ID token acquired' $true "scope $Scope"
}
else {
    Add-Result 'Entra ID token acquired' $false "Could not get a token for $Scope."
}

# 2b. Who does that token actually belong to? -------------------------------
# The refusal Foundry returns names a "Principal", and the Azure Identity chain
# puts environment variables ahead of the signed-in CLI user - so the principal
# is often not the person reading the message.
$claims = $null
if ($token) {
    try {
        $p = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } 1 { $p += '===' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    } catch { $claims = $null }
}
if ($claims) {
    $who = if ($claims.upn) { $claims.upn }
           elseif ($claims.unique_name) { $claims.unique_name }
           elseif ($claims.appid) { "application $($claims.appid)" }
           else { '<unnamed>' }
    $isUser = [bool]($claims.upn -or $claims.unique_name)
    Add-Result 'Token belongs to a signed-in user' $isUser "$who  tenant=$($claims.tid)"
    if (-not $isUser) {
        Write-Host '         A service principal is ahead of your CLI sign-in. Check:' -ForegroundColor DarkGray
        Write-Host '         Get-ChildItem Env: | Where-Object Name -match ''AZURE_CLIENT_ID''' -ForegroundColor DarkGray
    }
}

# 2b-ii. Would Claude Code use that same identity? ---------------------------
# Everything above tests the token the Azure CLI hands out. Claude Code does
# not ask the CLI - it walks the Azure Identity chain, and several credentials
# sit ahead of the CLI in it. So the Messages API check can pass on this very
# machine while Claude Code is refused, and the refusal names a "principal"
# the developer has never heard of.
$ahead = @()
foreach ($n in @('AZURE_CLIENT_ID','AZURE_CLIENT_SECRET','AZURE_CLIENT_CERTIFICATE_PATH','AZURE_USERNAME','AZURE_FEDERATED_TOKEN_FILE')) {
    if ([Environment]::GetEnvironmentVariable($n)) { $ahead += "$n is set" }
}
# Azure VMs answer IMDS; Arc-enabled servers and App Service use IDENTITY_ENDPOINT.
foreach ($n in @('IDENTITY_ENDPOINT','MSI_ENDPOINT','IMDS_ENDPOINT')) {
    if ([Environment]::GetEnvironmentVariable($n)) { $ahead += "$n is set (managed identity)" }
}
if ($ahead.Count -eq 0) {
    # Ask for a token, not for instance metadata. The metadata endpoint can
    # answer on a machine that has no usable identity at all, which turns this
    # check into a false alarm; only a token that is actually issued can
    # outrank the CLI. Measured: the metadata endpoint returned 200 on a
    # workstation whose token endpoint returned 400 and where Claude Code was
    # working perfectly through the CLI credential.
    try {
        $mi = Invoke-RestMethod -TimeoutSec 4 -ErrorAction Stop -Headers @{ Metadata = 'true' } `
                -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://cognitiveservices.azure.com'
        if ($mi.access_token) {
            $miWho = '<unreadable>'
            try {
                $mp = $mi.access_token.Split('.')[1].Replace('-', '+').Replace('_', '/')
                switch ($mp.Length % 4) { 2 { $mp += '==' } 3 { $mp += '=' } 1 { $mp += '===' } }
                $mc = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($mp)) | ConvertFrom-Json
                $miWho = if ($mc.appid) { "application $($mc.appid)" } else { $mc.oid }
            } catch { }
            $ahead += "a managed identity on this machine issues tokens ($miWho)"
        }
    } catch { }
}
Add-Result 'Nothing outranks your CLI sign-in' ($ahead.Count -eq 0) $(
    if ($ahead.Count -eq 0) { 'Claude Code will use the same account the checks above used' }
    else { ($ahead -join '; ') + ' - Claude Code may authenticate as that instead of you' })
if ($ahead.Count -gt 0) {
    Write-Host '         The checks above use the Azure CLI token. Claude Code does not.' -ForegroundColor DarkGray
    Write-Host '         If Claude Code reports 401 while those pass, this is why.' -ForegroundColor DarkGray
    Write-Host '' -ForegroundColor DarkGray

    # The supported way to pin the chain to one credential, rather than
    # deleting an identity the machine may need for other things.
    #
    # `dev`, not `AzureCliCredential`. The Azure documentation lists individual
    # credential names as valid from @azure/identity 4.11.0, and that is true of
    # the library - but Claude Code validates the value itself against a shorter
    # list before the library ever sees it. Measured on CLI 2.1.272:
    #
    #   AzureCliCredential -> API Error: Invalid value for AZURE_TOKEN_CREDENTIALS
    #                         = AzureCliCredential. Valid values are 'prod' or 'dev'.
    #   dev                -> works
    #   prod               -> fails; prod excludes the developer credentials,
    #                         which is the CLI sign-in we are trying to select
    #
    # This script used to recommend AzureCliCredential and -Fix used to set it,
    # which turned a working machine into a broken one. `dev` excludes managed
    # identity, which is the whole purpose here.
    $already = [Environment]::GetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'User')
    if ($already) {
        Note "AZURE_TOKEN_CREDENTIALS is already set to $already"
        if ($already -notin @('dev', 'prod')) {
            Note "  That value is not one Claude Code accepts; it takes 'dev' or 'prod'."
            Note "  Every call will fail with 'Invalid value for AZURE_TOKEN_CREDENTIALS'."
        }
    }
    else {
        Note 'Pin the credential chain to your CLI sign-in instead of removing the identity:'
        Note '  AZURE_TOKEN_CREDENTIALS=dev    (excludes managed identity; the value to use)'
        Note "  Claude Code accepts only 'dev' or 'prod' - a credential name is rejected,"
        Note '  even though @azure/identity 4.11.0+ understands one.'
        Add-Repair -What 'pin Claude Code to your Azure CLI sign-in' `
            -Why 'a managed identity or environment credential is ahead of you in the chain' `
            -Command "[Environment]::SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS','dev','User')" `
            -Do {
                [Environment]::SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'dev', 'User')
                return $true
            }
    }
    Note ''
    Note 'The other route is to grant that principal the role, which is right only if'
    Note 'the machine identity is meant to have Claude access.'
    Note 'Do not set ANTHROPIC_FOUNDRY_AUTH_TOKEN to work around this: it pins a token'
    Note 'that expires in about an hour, and the failure returns looking unrelated.'
}

# 2c. Is the resource in that token's tenant? -------------------------------
# A token for the wrong tenant is valid and useless: the resource's tenant has
# never heard of the principal, and says so in a way that reads like RBAC.
$found = Find-FoundryAccount -Name $Resource -Sub $SubscriptionId
$rgFound = $null
if ($found) { $rgFound = $found.Rg }
if ($claims) {
    Add-Result 'Resource is in the signed-in tenant' ([bool]$rgFound) $(
        if ($rgFound) { "resource group $($found.Rg), $($found.Where)" }
        else { "$Resource is not visible from tenant $($claims.tid) - sign in to the tenant that owns it" })

    # Found, but somewhere other than where the CLI is pointed. Everything
    # downstream that takes a subscription implicitly would look in the wrong
    # place, so pin it rather than leaving it to chance.
    if ($rgFound -and $found.Where -eq 'another subscription') {
        $activeSub = az account show --query id -o tsv 2>$null
        if ($activeSub) { $activeSub = $activeSub.Trim() }
        if ($activeSub -ne $found.Sub) {
            $subName = az account list --all --query "[?id=='$($found.Sub)'].name | [0]" -o tsv 2>$null
            if ($subName) { $subName = $subName.Trim() } else { $subName = $found.Sub }
            Write-Host '  [NOTE] the resource is not in your active subscription' -ForegroundColor Yellow
            Note "found in $subName ($($found.Sub))"
            Note 'Checks here name it explicitly, so they are correct either way. Claude'
            Note 'Code does not use subscriptions at all - it calls the endpoint directly -'
            Note 'so this matters for az commands you run by hand, not for the client.'
            $fs = $found.Sub
            Add-Repair -What 'pin the Azure CLI to that subscription' `
                -Why 'az commands you run by hand would otherwise look in the wrong one' `
                -Command "az account set --subscription $fs" `
                -Do {
                    az account set --subscription $fs 2>$null
                    return ($LASTEXITCODE -eq 0)
                }.GetNewClosure()
        }
    }

    if (-not $rgFound) {
        # Two different faults wear this: signed in to the wrong tenant, or a
        # CLI session old enough that a recent role grant is not reflected.
        # Signing in again settles both, and costs a browser round trip.
        $t1 = $TenantId
        if (-not $t1) { $t1 = '<owning-tenant-guid>' }
        Note 'Either you are in the wrong tenant, or this session predates the change.'
        if ($TenantId) {
            $tt = $TenantId
            Add-Repair -What "sign in again to tenant $tt" `
                -Why 'the resource is not visible from the tenant this session is in' `
                -Command "az account clear; az login --tenant $tt" `
                -Do {
                    az account clear -o none 2>$null
                    az login --tenant $tt -o none
                    return ($LASTEXITCODE -eq 0)
                }.GetNewClosure()
        }
        else {
            Note "  az login --tenant $t1        (pass -TenantId to have this offered as a repair)"
        }
    }
}

# 2d. Does the principal hold a role that reaches Claude? -------------------
# Azure AI Developer and Cognitive Services OpenAI User are confined to
# accounts/OpenAI/*, and Claude is not served there - so they look like the
# obvious AI roles and grant nothing on this endpoint.
if ($claims -and $rgFound) {
    $subArg = @()
    if ($found -and $found.Sub) { $subArg = @('--subscription', $found.Sub) }
    $scopeId = az cognitiveservices account show -n $Resource -g $rgFound @subArg --query id -o tsv 2>$null
    if ($scopeId) { $scopeId = $scopeId.Trim() }
    $held = @()
    if ($scopeId -and $claims.oid) {
        $raw = az role assignment list --assignee $claims.oid --scope $scopeId --include-inherited `
                  --query "[].roleDefinitionName" -o tsv 2>$null
        if ($raw) { $held = @($raw -split "`r?`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() } | Sort-Object -Unique) }
    }
    $capable = @()
    foreach ($r in $held) {
        $da = az role definition list --name $r --query "[0].permissions[0].dataActions" -o tsv 2>$null
        if (-not $da) { continue }
        $acts = @($da -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($acts -contains 'Microsoft.CognitiveServices/*') { $capable += $r }
    }
    if ($capable.Count -gt 0) {
        Add-Result 'A role reaches the Claude data plane' $true ($capable -join ', ')
    }
    elseif ($held.Count -gt 0) {
        Add-Result 'A role reaches the Claude data plane' $false `
            ("held: $($held -join ', ') - none carries Microsoft.CognitiveServices/*")
        # A role granted minutes ago is a different fault from no role at all,
        # and the two are indistinguishable from here. Say so rather than
        # sending someone to ask for access they already have.
        Note 'If a role was granted recently, it can take a few minutes to take effect,'
        Note 'and an old CLI session will not pick it up. Signing in again settles it.'
    }
    else {
        Add-Result 'A role reaches the Claude data plane' $false `
            'no role assignment on this resource for that principal'
        Note 'Ask an admin to run, against this resource:'
        Note "  ./scripts/Test-FoundryDirectAdmin.ps1 -Resource $Resource -GrantTo <your-object-id> -Fix"
    }
}

# 3. Deployments present ----------------------------------------------------
# The resource group is taken from discovery when the caller did not name one,
# so a resource in a neighbouring subscription still gets checked properly.
if (-not $ResourceGroup -and $found) { $ResourceGroup = $found.Rg }
$depSub = @()
if ($found -and $found.Sub) { $depSub = @('--subscription', $found.Sub) }
if ($ResourceGroup) {
    $deps = az cognitiveservices account deployment list -n $Resource -g $ResourceGroup @depSub -o json 2>$null | ConvertFrom-Json
    $claude = @($deps | Where-Object { $_.properties.model.format -eq 'Anthropic' })
    if ($claude.Count -gt 0) {
        Add-Result 'Claude deployments found' $true (($claude.name) -join ', ')
        # Exercise something that is actually here. Testing a name this script
        # invented turns a healthy resource into a 404 and sends the reader
        # looking for a fault in the endpoint.
        if (-not $Model) {
            $live = @($claude | Where-Object { $_.properties.provisioningState -eq 'Succeeded' })
            if ($live.Count -eq 0) { $live = $claude }
            $pick = $live | Where-Object { $_.properties.model.name -match 'sonnet' } | Select-Object -First 1
            if (-not $pick) { $pick = $live | Select-Object -First 1 }
            $Model = $pick.name
            Write-Host "         testing with $Model" -ForegroundColor DarkGray
        }
    }
    else {
        Add-Result 'Claude deployments found' $false 'No Anthropic-format deployments on this resource.'
    }
}
else {
    Write-Host "  [SKIP] Claude deployments found" -ForegroundColor Yellow
    Write-Host "         Pass -ResourceGroup to enable this check, or -Model to name one." -ForegroundColor DarkGray
}
if (-not $Model) {
    Write-Host '  [SKIP] Messages API responds (Entra ID)' -ForegroundColor Yellow
    Write-Host '         No deployment discovered, and none named with -Model. This check' -ForegroundColor DarkGray
    Write-Host '         will not invent a name: every resource carries different' -ForegroundColor DarkGray
    Write-Host '         deployments, and a guessed one returns 404 on a healthy resource.' -ForegroundColor DarkGray
    Write-Host '         Pass -ResourceGroup to discover them, or -Model to name one.' -ForegroundColor DarkGray
}

# 4. Messages API round trip ------------------------------------------------
if ($token -and $Model) {
    $body = @{
        model      = $Model
        max_tokens = 32
        messages   = @(@{ role = 'user'; content = 'Reply with exactly: FOUNDRY-OK' })
    } | ConvertTo-Json -Depth 6

    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/v1/messages" -Method Post -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01' }
        $text = ($resp.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
        Add-Result 'Messages API responds (Entra ID)' $true "model=$($resp.model) reply='$text'"
    }
    catch {
        Add-Result 'Messages API responds (Entra ID)' $false $_.Exception.Message
    }
}

# 5. Claude Code CLI --------------------------------------------------------
$cli = Get-Command claude -ErrorAction SilentlyContinue
if ($cli) {
    $ver = (claude --version 2>$null | Out-String).Trim()
    Add-Result 'Claude Code CLI installed' $true $ver
}
else {
    Add-Result 'Claude Code CLI installed' $false 'npm install -g @anthropic-ai/claude-code'
}

# 6. Provider reported by Claude Code --------------------------------------
if ($cli) {
    try {
        $auth = claude auth status 2>$null | Out-String | ConvertFrom-Json
        $isFoundry = $auth.apiProvider -eq 'foundry'
        Add-Result 'Claude Code provider = foundry' $isFoundry "apiProvider=$($auth.apiProvider) authMethod=$($auth.authMethod)"
    }
    catch {
        Add-Result 'Claude Code provider = foundry' $false 'Could not parse `claude auth status`.'
    }
}

# 7. End-to-end Claude Code turn -------------------------------------------
if ($cli) {
    try {
        $json = claude -p 'Reply with exactly: FOUNDRY-OK' --output-format json 2>$null | Out-String | ConvertFrom-Json
        $usage = $json.modelUsage.PSObject.Properties | Select-Object -First 1
        $provider = $usage.Value.provider
        $ok = ($provider -eq 'foundry') -and -not $json.is_error
        Add-Result 'Claude Code end-to-end on Foundry' $ok "model=$($usage.Name) provider=$provider reply='$($json.result)'"
    }
    catch {
        Add-Result 'Claude Code end-to-end on Foundry' $false $_.Exception.Message
    }
}

# 8. The three clients agree -----------------------------------------------
# Claude Desktop cannot read ~/.claude/settings.json, and VS Code can hold its
# own copy. A stale value in either outlives a correct CLI configuration and
# looks like an intermittent fault.
$expected = "https://$Resource.services.ai.azure.com/anthropic"
$cliFile  = Join-Path $env:USERPROFILE '.claude\settings.json'
$codeFile = Join-Path $env:APPDATA 'Code\User\settings.json'

$cliTarget = $null
if (Test-Path $cliFile) {
    try {
        $c = Get-Content $cliFile -Raw | ConvertFrom-Json
        $cliTarget = if ($c.env.ANTHROPIC_FOUNDRY_RESOURCE) { "resource:$($c.env.ANTHROPIC_FOUNDRY_RESOURCE)" }
                     elseif ($c.env.ANTHROPIC_FOUNDRY_BASE_URL) { $c.env.ANTHROPIC_FOUNDRY_BASE_URL }
        # Both set at once ends the session outright.
        if ($c.env.ANTHROPIC_FOUNDRY_RESOURCE -and $c.env.ANTHROPIC_FOUNDRY_BASE_URL) {
            Add-Result 'CLI settings are not self-contradictory' $false `
                'both ANTHROPIC_FOUNDRY_RESOURCE and ANTHROPIC_FOUNDRY_BASE_URL are set - mutually exclusive'
        }
    } catch { }
}
Add-Result 'Claude CLI is configured' ([bool]$cliTarget) $(if ($cliTarget) { "$cliFile -> $cliTarget" } else { "nothing Foundry-related in $cliFile" })

# A file further up the precedence order silently wins, and this check would
# otherwise read the user file, call it correct, and be looking at settings
# nothing uses. Measured: a project .claude/settings.local.json overrode a
# correct user file, and the symptom was a model name nobody could find in
# any configuration they were looking at.
#
# Claude Code's order, lowest to highest: user (~/.claude/settings.json),
# shared project (.claude/settings.json), local project
# (.claude/settings.local.json), then command-line arguments.
$overrides = @()
foreach ($cand in @(
    @{ Path = (Join-Path $PWD '.claude\settings.json');       What = 'project (shared)' },
    @{ Path = (Join-Path $PWD '.claude\settings.local.json'); What = 'project (local)' },
    @{ Path = (Join-Path $env:USERPROFILE '.claude\settings.local.json'); What = 'user (local)' }
)) {
    if (-not (Test-Path $cand.Path)) { continue }
    $ov = $null
    try { $ov = Get-Content $cand.Path -Raw | ConvertFrom-Json } catch { }
    if (-not $ov) { continue }
    $names = @()
    if ($ov.env) { $names += @($ov.env.PSObject.Properties.Name | Where-Object { $_ -match 'ANTHROPIC_|CLAUDE_CODE_USE_FOUNDRY|AZURE_' }) }
    if ($ov.PSObject.Properties.Name -contains 'availableModels') { $names += 'availableModels' }
    if ($ov.PSObject.Properties.Name -contains 'model') { $names += 'model' }
    if ($names.Count -gt 0) { $overrides += [pscustomobject]@{ Path = $cand.Path; What = $cand.What; Keys = $names } }
}
Add-Result 'Nothing overrides the settings just checked' ($overrides.Count -eq 0) $(
    if ($overrides.Count -eq 0) { "$cliFile is the file in force" }
    else { "$($overrides.Count) file(s) higher in the precedence order set Foundry values" })
foreach ($o in $overrides) {
    Note "  $($o.What): $($o.Path)"
    Note "    sets $(($o.Keys | Sort-Object -Unique) -join ', ')"
}
if ($overrides.Count -gt 0) {
    Note ''
    Note 'Lowest to highest: ~/.claude/settings.json, .claude/settings.json,'
    Note '.claude/settings.local.json, then command-line arguments. A correct user'
    Note 'file is simply ignored while one of these is present, and the error names'
    Note 'a model you cannot find in the configuration you are reading.'
}

# Every model name in the settings file must be a deployment on the resource.
# Hand-written configuration is where invented names come from: measured on a
# machine whose settings named claude-sonnet-5, claude-opus-5 and
# claude-haiku-4-5 against a resource carrying none of them. Claude Code
# refuses with "not available on your foundry deployment", which reads as the
# resource being wrong rather than the file.
if ($cliTarget -and $live -and @($live).Count -gt 0) {
    $realNames = @($live | ForEach-Object { $_.name })
    $configured = @()
    try {
        $cdoc = Get-Content $cliFile -Raw | ConvertFrom-Json
        foreach ($k in @('ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL')) {
            if ($cdoc.env.$k) { $configured += [pscustomobject]@{ Where = $k; Name = $cdoc.env.$k } }
        }
        foreach ($m in @($cdoc.availableModels)) {
            if ($m) { $configured += [pscustomobject]@{ Where = 'availableModels'; Name = $m } }
        }
    } catch { }

    if ($configured.Count -gt 0) {
        $invented = @($configured | Where-Object { $realNames -notcontains $_.Name })
        Add-Result 'Every configured model exists on the resource' ($invented.Count -eq 0) $(
            if ($invented.Count -eq 0) { "$(@($configured | Select-Object -ExpandProperty Name -Unique).Count) name(s), all deployed" }
            else { "$(@($invented | Select-Object -ExpandProperty Name -Unique).Count) name(s) are not deployed here" })
        foreach ($i in $invented) { Note "  $($i.Where) = $($i.Name)" }
        if ($invented.Count -gt 0) {
            Note ''
            Note ('deployed here: ' + ($realNames -join ', '))
            $rs2 = $Resource
            $tn2 = $TenantId
            $setup2 = Join-Path (Split-Path $PSCommandPath -Parent) 'Setup-ClaudeFoundryDirect.ps1'
            $cmd2 = ".\Setup-ClaudeFoundryDirect.ps1 -Resource $rs2"
            if ($tn2) { $cmd2 += " -TenantId $tn2" }
            Add-Repair -What 'rewrite the model names from what is deployed' `
                -Why 'the settings file names models this resource does not carry' `
                -Command "$cmd2 -Force" `
                -Do {
                    if (-not (Test-Path $setup2)) { return $false }
                    $a = @('-Resource', $rs2, '-Force')
                    if ($tn2) { $a += @('-TenantId', $tn2) }
                    & $setup2 @a | Out-Null
                    return $?
                }.GetNewClosure()
        }
    }
}
# Configured is not the same as configured for this resource. A machine on the
# gateway passes every check above - the token, the role and the endpoint are
# all genuinely fine - and is still not on the direct path.
if ($cliTarget) {
    $onDirect = ($cliTarget -eq "resource:$Resource") -or ($cliTarget -eq $expected)
    $wanted = ($Expect -eq 'direct')
    Add-Result 'Claude CLI points where expected' ($onDirect -eq $wanted) $(
        if ($onDirect -eq $wanted) { "$Expect path" }
        elseif ($cliTarget -match 'azure-api\.net') { "on the gateway ($cliTarget), not the direct path" }
        else { "points at $cliTarget" })
    # Rewriting settings by hand is how a placeholder ends up in them. Offer
    # the setup script, which discovers the deployments rather than assuming.
    if (($onDirect -ne $wanted) -and $wanted) {
        $rs = $Resource
        $tn = $TenantId
        $setup = Join-Path (Split-Path $PSCommandPath -Parent) 'Setup-ClaudeFoundryDirect.ps1'
        $cmd = ".\Setup-ClaudeFoundryDirect.ps1 -Resource $rs"
        if ($tn) { $cmd += " -TenantId $tn" }
        Add-Repair -What 'point every client at this resource' `
            -Why "the CLI is configured for $cliTarget" -Command "$cmd -Force" `
            -Do {
                if (-not (Test-Path $setup)) { return $false }
                $a = @('-Resource', $rs, '-Force')
                if ($tn) { $a += @('-TenantId', $tn) }
                & $setup @a | Out-Null
                return ($LASTEXITCODE -eq 0 -or $?)
            }.GetNewClosure()
    }
}

if (Test-Path $codeFile) {
    try {
        # VS Code settings.json is JSONC - it ships with comments in it, and
        # ConvertFrom-Json refuses them. Strip line and block comments, and
        # trailing commas, rather than abandoning the check on a file that is
        # perfectly valid for its own editor.
        $rawCode = Get-Content $codeFile -Raw
        $noBlock = [regex]::Replace($rawCode, '/\*[\s\S]*?\*/', '')
        $noLine  = ($noBlock -split "`r?`n" | ForEach-Object {
            if ($_ -match '^\s*//') { '' } else { $_ }
        }) -join "`n"
        $clean = [regex]::Replace($noLine, ',(\s*[}\]])', '$1')
        $v = ($clean | ConvertFrom-Json).'claudeCode.environmentVariables'
        if ($v) {
            $res = ($v | Where-Object name -eq 'ANTHROPIC_FOUNDRY_RESOURCE').value
            $url = ($v | Where-Object name -eq 'ANTHROPIC_FOUNDRY_BASE_URL').value
            $codeTarget = if ($res) { "resource:$res" } else { $url }
            $agrees = (-not $codeTarget) -or ($codeTarget -eq $cliTarget)
            Add-Result 'VS Code agrees with the CLI' $agrees $(
                if ($agrees) { 'same target' } else { "VS Code -> $codeTarget, CLI -> $cliTarget" })
        }
        else {
            Write-Host '  [SKIP] VS Code agrees with the CLI' -ForegroundColor Yellow
            Write-Host '         No claudeCode.environmentVariables set. That is the normal case -' -ForegroundColor DarkGray
            Write-Host '         the extension reads ~/.claude/settings.json and prefers it.' -ForegroundColor DarkGray
        }
    } catch {
        Write-Host '  [SKIP] VS Code agrees with the CLI' -ForegroundColor Yellow
        Write-Host '         settings.json could not be parsed - JSON with comments is valid there.' -ForegroundColor DarkGray
    }
}
else {
    # Silently omitting a check reads as a pass. Say it was not run.
    Write-Host '  [SKIP] VS Code agrees with the CLI' -ForegroundColor Yellow
    Write-Host "         No user settings file at $codeFile" -ForegroundColor DarkGray
}

$lib = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
$metaFile = Join-Path $lib '_meta.json'
if (Test-Path $metaFile) {
    try {
        $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
        $pf = Join-Path $lib "$($meta.appliedId).json"
        if (Test-Path $pf) {
            $dp = Get-Content $pf -Raw | ConvertFrom-Json
            $agrees = $dp.inferenceGatewayBaseUrl -eq $expected
            $wantedD = ($Expect -eq 'direct')
            Add-Result 'Claude Desktop points where expected' ($agrees -eq $wantedD) $(
                if ($agrees -eq $wantedD) { "$Expect path" }
                elseif ($dp.inferenceGatewayBaseUrl -match 'azure-api\.net') { "on the gateway ($($dp.inferenceGatewayBaseUrl)), not the direct path" }
                else { "Desktop -> $($dp.inferenceGatewayBaseUrl)" })
            if ($dp.inferenceCredentialHelper) {
                if (-not (Test-Path $dp.inferenceCredentialHelper)) {
                    Add-Result 'Desktop credential helper exists' $false $dp.inferenceCredentialHelper
                }
                else {
                    # Existing is not working. The helper that broke Desktop on
                    # 2026-09-22 was present, executable, and named in the
                    # profile - it simply could not find az, because Desktop
                    # spawns it with the environment the app started with. That
                    # failure passed every check in this file. So run it.
                    $helperEnvOk = $true
                    if ($dp.inferenceCredentialHelper -match 'helper|foundry') {
                        $tenantForHelper = [Environment]::GetEnvironmentVariable('CLAUDE_FOUNDRY_TENANT_ID', 'User')
                        if (-not $tenantForHelper) { $tenantForHelper = $env:CLAUDE_FOUNDRY_TENANT_ID }
                        $helperEnvOk = [bool]$tenantForHelper
                        Add-Result 'Desktop helper knows its tenant' $helperEnvOk $(
                            if ($helperEnvOk) { "CLAUDE_FOUNDRY_TENANT_ID=$tenantForHelper" }
                            else { 'CLAUDE_FOUNDRY_TENANT_ID is not set - a guest or multi-tenant account will get a home-tenant token the gateway refuses' })
                        if (-not $helperEnvOk -and $TenantId) {
                            $tset = $TenantId
                            Add-Repair -What 'record the tenant for the Desktop helper' `
                                -Why 'without it a guest or multi-tenant account signs in to the wrong directory' `
                                -Command "[Environment]::SetEnvironmentVariable('CLAUDE_FOUNDRY_TENANT_ID','$tset','User')" `
                                -Do {
                                    [Environment]::SetEnvironmentVariable('CLAUDE_FOUNDRY_TENANT_ID', $tset, 'User')
                                    return $true
                                }.GetNewClosure()
                        }
                    }

                    $out = ''
                    try { $out = (& $dp.inferenceCredentialHelper 2>&1 | Out-String) } catch { $out = $_.Exception.Message }
                    $gotToken = ($out -match '(?m)^eyJ')
                    Add-Result 'Desktop helper returns a token' $gotToken $(
                        if ($gotToken) { 'JWT on stdout' }
                        else { ($out -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) })

                    # And the way Desktop actually calls it. A helper that only
                    # works because this shell has the Azure CLI on PATH will
                    # fail the moment Desktop runs it.
                    if ($gotToken) {
                        $stripped = (($env:Path -split ';') | Where-Object { $_ -and $_ -notmatch 'Azure\\CLI2' }) -join ';'
                        $q = '"' + $dp.inferenceCredentialHelper + '"'
                        $out2 = cmd /c "set ""PATH=$stripped"" && $q 2>&1"
                        $survives = (@($out2) -match '^eyJ').Count -gt 0
                        Add-Result 'and without the CLI on PATH' $survives $(
                            if ($survives) { 'resolves az independently of PATH' }
                            else { 'helper depends on PATH - Desktop inherits a stale environment and will fail' })
                    }
                }
            }
        }
    } catch { }
}
# 8b. What the model list actually does -------------------------------------
# enforceAvailableModels reads like it refuses an unlisted model. Measured on
# 2026-09-22 against CLI 2.1.272, it does not: asking for gpt-4o, and for a
# Claude model absent from the list, both returned claude-sonnet-5 with no
# error. That is safe - nothing unlisted is ever called - but it is silent, so
# the check asserts substitution rather than refusal.
if ($cli -and $Expect -eq 'direct' -and $cliTarget -eq "resource:$Resource") {
    try {
        $sub = claude -p 'Reply with exactly: SUB' --model gpt-4o --output-format json 2>$null | Out-String | ConvertFrom-Json
        $usedName = ($sub.modelUsage.PSObject.Properties | Select-Object -First 1).Name
        $allowed = @()
        try { $allowed = @((Get-Content $cliFile -Raw | ConvertFrom-Json).availableModels) } catch { }
        $constrained = ($usedName -and ($allowed -contains $usedName))
        Add-Result 'an unlisted model is substituted, not served' $constrained $(
            if ($constrained) { "asked for gpt-4o, served $usedName - silently, with no error" }
            else { "asked for gpt-4o and got $usedName, which is not in availableModels" })
    }
    catch { Write-Host '  [SKIP] model substitution - could not complete a turn' -ForegroundColor Yellow }
}

# 9. Entra device-code init, only when a client id is given -----------------
# Claude Desktop's native Foundry Entra mode posts to /devicecode before any
# token exists. A 400 there is an app registration problem and no role
# assignment can affect it, which is why it needs its own check.
if ($ClientId) {
    $tid = if ($TenantId) { $TenantId } elseif ($claims) { $claims.tid } else { $null }
    if (-not $tid) { Write-Host '  [SKIP] Entra device-code init - pass -TenantId' -ForegroundColor Yellow }
    else {
        $dcScope = 'https://cognitiveservices.azure.com/.default offline_access'
        $dcUri  = "https://login.microsoftonline.com/$tid/oauth2/v2.0/devicecode"
        $dcBody = "client_id=$ClientId&scope=$([uri]::EscapeDataString($dcScope))"
        # -SkipHttpErrorCheck is PowerShell 7 and later. Windows PowerShell 5.1
        # is what most developers run, and there it throws on 4xx - which is the
        # very response this check exists to read. Measured on 5.1.26100.9444:
        # "A parameter cannot be found that matches parameter name
        # 'SkipHttpErrorCheck'", turning a working diagnosis into a failure of
        # the diagnostic itself.
        $status = 0
        $content = ''
        try {
            $p = @{ Uri = $dcUri; Method = 'POST'; ContentType = 'application/x-www-form-urlencoded'
                    Body = $dcBody; UseBasicParsing = $true; TimeoutSec = 30 }
            if ($PSVersionTable.PSVersion.Major -ge 6) { $p['SkipHttpErrorCheck'] = $true }
            $r = Invoke-WebRequest @p
            $status = [int]$r.StatusCode
            $content = $r.Content
        }
        catch {
            # 5.1 lands here for every non-2xx, so read the body off the
            # exception rather than reporting the exception as the fault.
            # On 5.1 the response body arrives in ErrorDetails; the stream is
            # often already consumed by the time we get here, which loses the
            # AADSTS code that is the entire value of this check.
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $content = $_.ErrorDetails.Message }
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                if (-not $content) {
                    try {
                        $s = $_.Exception.Response.GetResponseStream()
                        $content = (New-Object IO.StreamReader($s)).ReadToEnd()
                    } catch { }
                }
            }
            if (-not $status) {
                Add-Result 'Entra device-code init (Desktop)' $false $_.Exception.Message
            }
        }
        if ($status -eq 200) {
            Add-Result 'Entra device-code init (Desktop)' $true "client $ClientId accepted"
        }
        elseif ($status) {
            $err = $null
            try { $err = ($content | ConvertFrom-Json).error_description } catch { }
            $aadsts = if ($err -match '(AADSTS\d+)') { $Matches[1] } else { "HTTP $status" }
            Add-Result 'Entra device-code init (Desktop)' $false "$aadsts - app registration or tenant, not RBAC"
        }
    }
}

# Summary -------------------------------------------------------------------
Write-Host ""
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failed -eq 0) {
    Write-Host "All $($results.Count) checks passed - Claude Code is running on Microsoft Foundry." -ForegroundColor Green
}
else {
    Write-Host "$failed of $($results.Count) checks failed." -ForegroundColor Red
}

# Repairs --------------------------------------------------------------------
# After the summary, so the whole picture is read before anything changes.
# Nothing here alters Azure: these are local files, a user environment
# variable, and sign-ins. Granting a role is an admin action and lives in
# Test-FoundryDirectAdmin.ps1.
if ($repairs.Count -gt 0) {
    Write-Host ''
    Write-Host "  $($repairs.Count) repair(s) available" -ForegroundColor Cyan
    foreach ($r in $repairs) {
        Write-Host "    - $($r.What)" -ForegroundColor White
        Write-Host "      $($r.Why)" -ForegroundColor DarkGray
        Write-Host "      $($r.Command)" -ForegroundColor DarkGray
    }
    Write-Host ''
    if (-not $Fix) {
        Write-Host '  Re-run with -Fix to apply these, or copy the commands above.' -ForegroundColor DarkGray
    }
    else {
        $applied = 0
        foreach ($r in $repairs) {
            $go = $Force
            if (-not $go) {
                $ans = Read-Host "  Apply: $($r.What)? [y/N]"
                $go = ($ans -match '^(y|yes)$')
            }
            if (-not $go) { Write-Host '    skipped' -ForegroundColor DarkGray; continue }
            $ok = $false
            try { $ok = [bool](& $r.Do) } catch { $ok = $false }
            if ($ok) { Write-Host '    done' -ForegroundColor Green; $applied++ }
            else {
                Write-Host '    failed' -ForegroundColor Red
                Write-Host "      $($r.Command)" -ForegroundColor DarkGray
            }
        }
        if ($applied -gt 0) {
            Write-Host ''
            Write-Host "  $applied repair(s) applied. Open a new terminal before re-running:" -ForegroundColor DarkGray
            Write-Host '  a running shell keeps the environment it started with.' -ForegroundColor DarkGray
        }
    }
}
Write-Host ""
exit $failed
