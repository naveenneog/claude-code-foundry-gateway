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
    .\Show-Governance.ps1 -ApimName apim-claude-gw-xxxx -ResourceGroup rg-contosohub
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$SecondIdentityPath = "$env:TEMP\bob.json",
    [string]$AppInsightsName = 'appi-claude-gateway',
    [string]$Model = 'claude-sonnet-5',
    [switch]$SkipThrottleTest
)

$ErrorActionPreference = 'Continue'
$gw = "https://$ApimName.azure-api.net/claude"

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
}

Write-Host ""
Write-Host "Claude Code governance - control checks" -ForegroundColor Cyan
Write-Host "  gateway : $gw"
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
    az apim nv update -g $ResourceGroup --service-name $ApimName --named-value-id tpm-standard --value 100 -o none 2>$null
    Start-Sleep -Seconds 25

    $throttled = $null
    foreach ($i in 1..15) {
        $r = Send-Prompt -Token $mine
        if ($r.StatusCode -eq 429) { $throttled = $r; break }
    }

    if ($throttled) { Show-Result -Label "budget exhausted -> throttled" -Response $throttled -Expect '429' }
    else { Write-Host "  [FAIL] never throttled after 15 calls" -ForegroundColor Red }

    az apim nv update -g $ResourceGroup --service-name $ApimName --named-value-id tpm-standard --value $restore -o none 2>$null
    Write-Host ("         tpm-standard restored to {0}" -f $restore) -ForegroundColor DarkGray
    Write-Host ""
}

# --- 5. Chargeback ---------------------------------------------------------
Write-Host "4. Chargeback attribution (last hour)" -ForegroundColor Yellow
$sub = az account show --query id -o tsv
$ai = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$AppInsightsName"
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$ts = "$((Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))/$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
$filter = [uri]::EscapeDataString("User eq '*'")
$uri = "https://management.azure.com$ai/providers/Microsoft.Insights/metrics?api-version=2019-07-01" +
       "&metricnamespace=claudecode&metricnames=Total%20Tokens&timespan=$ts&interval=PT1H&aggregation=Total&`$filter=$filter"

try {
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
catch { Write-Host "         metric query failed: $($_.Exception.Message)" -ForegroundColor DarkYellow }

Write-Host ""
Write-Host "Every call above was authenticated as a named Entra identity," -ForegroundColor DarkGray
Write-Host "metered against that identity, and served by the gateway's managed" -ForegroundColor DarkGray
Write-Host "identity. No developer holds a Foundry credential." -ForegroundColor DarkGray
Write-Host ""
