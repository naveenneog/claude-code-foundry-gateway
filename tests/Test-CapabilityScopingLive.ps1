# P13 verification against the live gateway.
#
# Asserts that the model allowlist is a control, not a preference: that a model
# outside the caller's tier list is refused before Foundry is called, that a
# model inside it still works, and that an empty list allows everything.
#
# The named values are captured first and restored in a finally block.

param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'
$rg = $ResourceGroup
$svc = if ($ApimName) { $ApimName } else { az apim list -g $rg --query "[0].name" -o tsv 2>$null }
if (-not $svc) { Write-Host '  skipped - no API Management found' -ForegroundColor Yellow; exit 0 }
$root = Split-Path $PSScriptRoot -Parent

$sub = az account show --query id -o tsv
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$H = @{ Authorization = 'Bearer ' + $tok.Trim(); 'Content-Type' = 'application/json' }
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$svc"
$v = '?api-version=2024-05-01'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Nv($name) { try { return (Invoke-RestMethod -Uri "$base/namedValues/$name$v" -Headers $H).properties.value } catch { return $null } }
function Set-Nv($name, $value) {
    $b = @{ properties = @{ displayName = $name; value = "$value"; secret = $false } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/namedValues/$name$v" -Headers $H -Body $b | Out-Null
}
function Call($model) {
    $t = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
    $payload = @{ model = $model; max_tokens = 40; messages = @(@{ role = 'user'; content = 'Say OK.' }) } | ConvertTo-Json -Depth 5
    return Invoke-WebRequest -Uri "https://$svc.azure-api.net/claude/v1/messages" -Method Post -Body $payload `
           -ContentType 'application/json' -SkipHttpErrorCheck `
           -Headers @{ Authorization = 'Bearer ' + $t.Trim(); 'anthropic-version' = '2023-06-01' }
}

$savedStd = $null
$savedPrm = $null

try {
    Write-Host ''
    Write-Host "P13 live - $svc" -ForegroundColor Cyan

    foreach ($n in 'models-standard', 'models-premium') {
        if ($null -eq (Get-Nv $n)) { Set-Nv $n ',,' }
    }
    $savedStd = Get-Nv 'models-standard'
    $savedPrm = Get-Nv 'models-premium'

    $policy = Get-Content (Join-Path $root 'infra/policy.xml') -Raw
    $b = @{ properties = @{ value = $policy; format = 'rawxml' } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/apis/claude-foundry/policies/policy$v" -Headers $H -Body $b | Out-Null
    Assert 'APIM accepted the policy' $true
    Start-Sleep -Seconds 12

    Write-Host ''
    Write-Host 'P13 live - an empty list allows every model' -ForegroundColor Cyan
    Set-Nv 'models-standard' ',,'
    Set-Nv 'models-premium' ',,'
    Start-Sleep -Seconds 15
    $r = Call 'claude-sonnet-5'
    Assert 'sonnet is served'  ([int]$r.StatusCode -eq 200) "HTTP $($r.StatusCode): $($r.Content)"
    $tier = ($r.Headers['x-claude-tier'] -join '')
    Write-Host "         caller tier: $tier" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'P13 live - a model outside the list is refused' -ForegroundColor Cyan
    # Allow only opus, then ask for sonnet.
    Set-Nv "models-$tier" ',claude-opus-5,'
    Start-Sleep -Seconds 15
    $r2 = Call 'claude-sonnet-5'
    Assert 'the call is refused' ([int]$r2.StatusCode -eq 403) "HTTP $($r2.StatusCode)"
    $json = $null
    try { $json = $r2.Content | ConvertFrom-Json } catch { }
    Assert 'the reply is JSON' ($null -ne $json) $r2.Content
    if ($json) {
        Assert 'it is in Anthropic error shape' ($json.error.type -eq 'invalid_request_error') $r2.Content
        Assert 'it says why'                    ($json.error.code -eq 'model_not_allowed') "code=$($json.error.code)"
        Assert 'it names the model'             ($json.error.message -match 'claude-sonnet-5') $json.error.message
        Assert 'it says access is unaffected'   ($json.error.message -match 'access is unaffected') $json.error.message
        Write-Host ('         ' + $json.error.message) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'P13 live - a model inside the list still works' -ForegroundColor Cyan
    $r3 = Call 'claude-opus-5'
    Assert 'opus is served while sonnet is blocked' ([int]$r3.StatusCode -eq 200) "HTTP $($r3.StatusCode): $($r3.Content)"

    Write-Host ''
    Write-Host 'P13 live - a prefix does not widen the list' -ForegroundColor Cyan
    # ",claude-opus-5," must not admit a longer name that starts the same way.
    $r4 = Call 'claude-opus-5-mini'
    Assert 'a longer name sharing the prefix is refused' ([int]$r4.StatusCode -eq 403) "HTTP $($r4.StatusCode)"
}
finally {
    foreach ($pair in @(@{ n = 'models-standard'; v = $savedStd }, @{ n = 'models-premium'; v = $savedPrm })) {
        if ($null -ne $pair.v) {
            try { Set-Nv $pair.n $pair.v; Write-Host "  $($pair.n) restored to '$($pair.v)'" -ForegroundColor DarkGray }
            catch { Write-Host "  RESTORE FAILED - set $($pair.n) back to '$($pair.v)' by hand" -ForegroundColor Red }
        }
    }
}

Start-Sleep -Seconds 15
$back = Call 'claude-sonnet-5'
Assert 'service restored' ([int]$back.StatusCode -eq 200) "HTTP $($back.StatusCode)"

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P13 holds on the live gateway.' -ForegroundColor Green
exit 0
