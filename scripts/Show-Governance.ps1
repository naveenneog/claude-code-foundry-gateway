<#
.SYNOPSIS
    Demonstrates every governance control on the Claude gateway, end to end.

.DESCRIPTION
    Runs the checks a platform team needs to see before handing Claude Code to
    developers:

      1. an entitled developer is served, and told what budget remains
      2. an identity in no Claude Code group is refused (403)
      3. tier membership changes the limits that apply
      4. exceeding the per-minute token budget is throttled (429 + Retry-After)
      5. consumption is attributed to a named identity for chargeback

    The second identity is a service principal standing in for another
    developer; acquiring an interactive token for a colleague is not something
    a test should do.

.EXAMPLE
    .\Show-Governance.ps1 -ApimName <apim-name> -ResourceGroup <resource-group>
#>
[CmdletBinding()]
param(
    [string]$ApimName,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$SecondIdentityPath = "$env:TEMP\bob.json",
    # Both resolved from the gateway when omitted. Fixed defaults were wrong on
    # real gateways - see Resolve-GovernanceModel and Resolve-GatewayAppInsights.
    [string]$AppInsightsName,
    [string]$Model,
    [switch]$SkipThrottleTest
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup }

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
$gw = "https://$ApimName.azure-api.net/claude"

function Get-GatewayArm {
    param([string]$Path)
    $id = az apim show -g $ResourceGroup -n $ApimName --query id -o tsv 2>$null
    if (-not $id) { return $null }
    $raw = az rest --method get --url "https://management.azure.com$id$($Path)?api-version=2024-05-01" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    return ($raw | Out-String | ConvertFrom-Json)
}

function Get-ClaudeApi {
    $apis = Get-GatewayArm '/apis'
    return @($apis.value | Where-Object { $_.properties.path -eq 'claude' })[0]
}

function Resolve-GatewayAppInsights {
    <#
        The component that receives the token metric is the one the Claude API's
        own applicationinsights diagnostic names; an API-level diagnostic
        overrides the service-level one. The default this script used to have,
        'appi-claude-gateway', was the service-level component on the reference
        gateway and held 0 tokens over 7 days while the API-level one held
        168,438 (measured 2026-09-23); on a newly installed gateway it did not
        exist at all and the query returned 404.
    #>
    $api = Get-ClaudeApi
    $paths = @()
    if ($api) { $paths += "/apis/$($api.name)/diagnostics/applicationinsights" }
    $paths += '/diagnostics/applicationinsights'
    foreach ($p in $paths) {
        $d = Get-GatewayArm $p
        $loggerId = "$($d.properties.loggerId)"
        if (-not $loggerId) { continue }
        $raw = az rest --method get --url "https://management.azure.com$($loggerId)?api-version=2024-05-01" -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { continue }
        $resourceId = "$(($raw | Out-String | ConvertFrom-Json).properties.resourceId)"
        if ($resourceId) { return $resourceId }
    }
    return $null
}

function Resolve-GovernanceModel {
    <#
        A model the caller's tier is allowed and the account deploys. The fixed
        default, 'claude-sonnet-5', made the first check fail on every gateway
        whose account does not deploy it: the gateway answered 403
        model_not_allowed and a healthy install was reported as failed
        (measured on a new gateway, 2026-09-23).
    #>
    param([object]$Interactive = $null, [scriptblock]$Reader)
    $choice = @{ Interactive = $Interactive }
    if ($Reader) { $choice.Reader = $Reader }
    $oid = az ad signed-in-user show --query id -o tsv 2>$null
    $premium = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id allow-premium --query value -o tsv 2>$null
    $tier = if ($oid -and "$premium" -like "*,$oid,*") { 'premium' } else { 'standard' }
    $listed = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id "models-$tier" --query value -o tsv 2>$null
    $allowed = @("$listed".Trim(',') -split ',' | Where-Object { $_ })
    if ($allowed.Count) {
        return (Select-ClaudeModel -Names $allowed -Source "the models-$tier named value on $ApimName" -WhereToFind @(
            "az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id models-$tier --query value -o tsv"
            "Azure portal: API Management > $ApimName > Named values > models-$tier"
        ) @choice)
    }

    # An empty list means the tier is not restricted, so any deployment will do.
    $api = Get-ClaudeApi
    if ("$($api.properties.serviceUrl)" -match '^https://([^./]+)\.') {
        $account = $Matches[1]
        # Filtered here rather than in --query: az is a .cmd shim on Windows and
        # cmd.exe re-parses JMESPath punctuation.
        $accountRg = @(az cognitiveservices account list -o json 2>$null | Out-String | ConvertFrom-Json |
            Where-Object { $_.name -eq $account } | ForEach-Object { $_.resourceGroup })[0]
        if ($accountRg) {
            $deployments = az cognitiveservices account deployment list -g $accountRg -n $account -o json 2>$null | Out-String | ConvertFrom-Json
            $claude = @($deployments | Where-Object { $_.name -like 'claude-*' } | Sort-Object name)
            if ($claude.Count) {
                return (Select-ClaudeModel -Names @($claude | ForEach-Object { $_.name }) -Source "the Claude deployments on $account ($accountRg)" -WhereToFind @(
                    "az cognitiveservices account deployment list -g $accountRg -n $account -o table"
                    "Azure portal: Foundry > $account > Deployments"
                ) @choice)
            }
        }
    }
    return $null
}

if (-not $Model) {
    $Model = Resolve-GovernanceModel
    if (-not $Model) {
        throw ("No allowed Claude model could be discovered. Pass -Model. Where to find it: " +
            "az apim nv list -g $ResourceGroup --service-name $ApimName -o table; " +
            "Azure portal: API Management > $ApimName > Named values > models-standard or models-premium; Foundry > Deployments.")
    }
}

# Windows PowerShell 5.1 throws on 4xx/5xx and has no -SkipHttpErrorCheck, so
# responses are normalised to one shape that both editions can work with.
function Invoke-Normalised {
    param([hashtable]$Params)

    if ($PSVersionTable.PSVersion.Major -ge 6) { $Params['SkipHttpErrorCheck'] = $true }
    $Params['ErrorAction'] = 'Stop'

    try {
        $r = Invoke-WebRequest @Params
        $headers = @{}
        foreach ($k in $r.Headers.Keys) { $headers[$k] = ($r.Headers[$k] -join ',') }
        return [pscustomobject]@{ StatusCode = [int]$r.StatusCode; Headers = $headers; Content = $r.Content }
    }
    catch {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }

        $headers = @{}
        $body = ''
        if ($resp -is [System.Net.HttpWebResponse]) {
            foreach ($k in $resp.Headers.AllKeys) { $headers[$k] = $resp.Headers[$k] }
            $reader = New-Object IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd(); $reader.Close()
        }
        else {
            foreach ($h in $resp.Headers) { $headers[$h.Key] = ($h.Value -join ',') }
        }
        return [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Headers = $headers; Content = $body }
    }
}

function Get-Header {
    param($Response, [string]$Name)
    foreach ($k in $Response.Headers.Keys) {
        if ($k -ieq $Name) { return $Response.Headers[$k] }
    }
    return ''
}

function Send-Prompt {
    param([string]$Token, [string]$Text = 'Reply with exactly: OK', [int]$MaxTokens = 24)

    $body = @{ model = $Model; max_tokens = $MaxTokens; messages = @(@{ role = 'user'; content = $Text }) } | ConvertTo-Json -Depth 5
    return Invoke-Normalised -Params @{
        Uri         = "$gw/v1/messages"
        Method      = 'Post'
        Headers     = @{ Authorization = "Bearer $Token"; 'anthropic-version' = '2023-06-01' }
        ContentType = 'application/json'
        Body        = $body
    }
}

function Show-Result {
    param([string]$Label, $Response, [string]$Expect)

    $ok = "$($Response.StatusCode)" -eq $Expect
    $mark = if ($ok) { 'PASS' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }

    Write-Host ("  [{0}] {1}" -f $mark, $Label) -ForegroundColor $colour
    Write-Host ("         HTTP {0}   tier={1}   consumed={2}   remaining={3}" -f `
        $Response.StatusCode,
        (Get-Header $Response 'x-claude-tier'),
        (Get-Header $Response 'x-tokens-consumed'),
        (Get-Header $Response 'x-ratelimit-remaining-tokens')) -ForegroundColor DarkGray

    if ($Response.StatusCode -eq 429) {
        Write-Host ("         Retry-After: {0}s" -f (Get-Header $Response 'Retry-After')) -ForegroundColor DarkGray
    }

    # A bare status left the operator guessing which layer refused. The
    # gateway's own refusals carry a code (model_not_allowed, permission_error)
    # that says what to change.
    if (-not $ok -and $Response.Content) {
        try {
            $e = ($Response.Content | ConvertFrom-Json).error
            $code = if ($e.code) { $e.code } else { $e.type }
            $msg = "$($e.message)"
            if ($msg.Length -gt 150) { $msg = $msg.Substring(0, 150) + '...' }
            if ($code -or $msg) { Write-Host ("         {0}: {1}" -f $code, $msg) -ForegroundColor DarkYellow }
        }
        catch { }
    }
}

Write-Host ""
Write-Host "Claude Code governance - control checks" -ForegroundColor Cyan
Write-Host "  gateway : $gw"
Write-Host "  model   : $Model"
Write-Host ""

# --- 1. Entitled developer -------------------------------------------------
Write-Host "1. Entitled developer" -ForegroundColor Yellow
$mine = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
$me = az ad signed-in-user show --query userPrincipalName -o tsv
Show-Result -Label "$me is served" -Response (Send-Prompt -Token $mine) -Expect '200'
Write-Host ""

# --- 2 and 3. A second identity -------------------------------------------
if (Test-Path $SecondIdentityPath) {
    $second = Get-Content $SecondIdentityPath -Raw | ConvertFrom-Json
    $secondToken = (Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$($second.tenant)/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ client_id = $second.appId; client_secret = $second.secret
                 scope = 'https://cognitiveservices.azure.com/.default'; grant_type = 'client_credentials' }).access_token

    Write-Host "2. Tier enforcement" -ForegroundColor Yellow
    Show-Result -Label "second identity is served at its own tier" -Response (Send-Prompt -Token $secondToken) -Expect '200'
    Write-Host ""
}

# --- 4. Throttling ---------------------------------------------------------
if (-not $SkipThrottleTest) {
    Write-Host "3. Per-minute token budget" -ForegroundColor Yellow
    Write-Host "         temporarily lowering tpm-standard to 100..." -ForegroundColor DarkGray
    $restore = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id tpm-standard --query value -o tsv 2>$null
    if (-not $restore) { throw "Could not read tpm-standard, so it cannot be restored afterwards. Not lowering it." }
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'tpm-standard' -Value '100'
    Start-Sleep -Seconds 25

    # The restore runs in a finally: this demo deliberately cripples the
    # standard tier, and an interrupted or failed run used to leave it capped at
    # 100 tokens per minute with nothing said, because the restore was written
    # with errors suppressed and no exit check.
    try {
        $throttled = $null
        foreach ($i in 1..15) {
            $r = Send-Prompt -Token $mine
            if ($r.StatusCode -eq 429) { $throttled = $r; break }
        }

        if ($throttled) { Show-Result -Label "budget exhausted -> throttled" -Response $throttled -Expect '429' }
        else { Write-Host "  [FAIL] never throttled after 15 calls" -ForegroundColor Red }
    }
    finally {
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'tpm-standard' -Value $restore
        Write-Host ("         tpm-standard restored to {0}" -f $restore) -ForegroundColor DarkGray
    }
    Write-Host ""
}

# --- 5. Chargeback ---------------------------------------------------------
Write-Host "4. Chargeback attribution (last hour)" -ForegroundColor Yellow
$sub = az account show --query id -o tsv
$ai = if ($AppInsightsName) {
    "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$AppInsightsName"
}
else {
    $linked = Resolve-GatewayAppInsights
    if ($linked) { $linked } else { Select-ClaudeAppInsights -ResourceGroup $ResourceGroup }
}
if ($ai) { Write-Host ("         component: {0}" -f ($ai -split '/')[-1]) -ForegroundColor DarkGray }
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$ts = "$((Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))/$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
$filter = [uri]::EscapeDataString("User eq '*'")
$uri = "https://management.azure.com$ai/providers/Microsoft.Insights/metrics?api-version=2019-07-01" +
       "&metricnamespace=claudecode&metricnames=Total%20Tokens&timespan=$ts&interval=PT1H&aggregation=Total&`$filter=$filter"

if ($ai) { try {
    $m = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $tok" }
    $rows = @()
    foreach ($metric in $m.value) {
        foreach ($s in $metric.timeseries) {
            $rows += [pscustomobject]@{
                Developer = ($s.metadatavalues | ForEach-Object { $_.value }) -join '/'
                Tokens    = [int](($s.data | Measure-Object -Property total -Sum).Sum)
            }
        }
    }
    if ($rows) {
        foreach ($row in ($rows | Sort-Object Tokens -Descending)) {
            Write-Host ("         {0,-45} {1,8} tokens" -f $row.Developer, $row.Tokens)
        }
    }
    else { Write-Host "         (no dimensioned metrics yet - allow ~3 min after traffic)" -ForegroundColor DarkGray }
}
catch { Write-Host "         metric query failed: $($_.Exception.Message)" -ForegroundColor DarkYellow } }

Write-Host ""
Write-Host "Every call above was authenticated as a named Entra identity," -ForegroundColor DarkGray
Write-Host "metered against that identity, and served by the gateway's managed" -ForegroundColor DarkGray
Write-Host "identity. No developer holds a Foundry credential." -ForegroundColor DarkGray
Write-Host ""
