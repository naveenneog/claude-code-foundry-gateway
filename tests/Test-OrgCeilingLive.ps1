# P11 - the org ceiling, verified against a running gateway.
#
# Test-OrgCeiling.ps1 asserts the policy's shape from the files. This asserts its
# behaviour on a deployed gateway.
#
# Two modes.
#
#   default          Read-only. Calls the gateway once and checks it reports the
#                    shared org budget alongside the per-user one.
#
#   -ProveRefusal    Also proves the refusal. Lowers a quota below what has
#                    already been spent so the next call is refused without
#                    spending more, reads the message, then restores the quota.
#                    Service returns immediately: raising a ceiling above current
#                    consumption unblocks the next request.
#
# -ProveRefusal edits named values on a live gateway. They are restored in a
# finally block, and the original values are printed first so they can be put
# back by hand if the script is interrupted.
#
# Measured with this method on 2026-09-02:
#   org exhausted      -> 403 {"error":{"type":"rate_limit_error","budget":"organisation",...}}
#   personal exhausted -> 403 {"error":{"type":"rate_limit_error","budget":"personal",...}}

[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName,
    [switch]$ProveRefusal
)

$ErrorActionPreference = 'Stop'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { Write-Host '  skipped - not signed in. Run: az login' -ForegroundColor Yellow; exit 0 }

if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { Write-Host "  skipped - no API Management in $ResourceGroup" -ForegroundColor Yellow; exit 0 }
}

$armTok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
$H = @{ Authorization = 'Bearer ' + $armTok.Trim(); 'Content-Type' = 'application/json' }
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$v = '?api-version=2024-05-01'

function Get-Nv($name) {
    try { return (Invoke-RestMethod -Uri "$base/namedValues/$name$v" -Headers $H).properties.value } catch { return $null }
}
function Set-Nv($name, $value) {
    $b = @{ properties = @{ displayName = $name; value = "$value"; secret = $false } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/namedValues/$name$v" -Headers $H -Body $b | Out-Null
}
function Invoke-Gateway {
    $t = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>$null
    $payload = @{ model = 'claude-sonnet-5'; max_tokens = 40; messages = @(@{ role = 'user'; content = 'Say OK.' }) } | ConvertTo-Json -Depth 5
    return Invoke-WebRequest -Uri "https://$ApimName.azure-api.net/claude/v1/messages" -Method Post -Body $payload `
           -ContentType 'application/json' -SkipHttpErrorCheck `
           -Headers @{ Authorization = 'Bearer ' + $t.Trim(); 'anthropic-version' = '2023-06-01' }
}
function Get-Header($response, $name) { return ($response.Headers[$name] -join '') }

Write-Host ''
Write-Host "P11 live - $ApimName" -ForegroundColor Cyan

$quotaOrg = Get-Nv 'quota-org'
Assert 'quota-org is configured' ($null -ne $quotaOrg) 'named value missing - redeploy with the current template'
if ($null -eq $quotaOrg) { Write-Host ''; Write-Host '1 assertion(s) failed.' -ForegroundColor Red; exit 1 }

$r = Invoke-Gateway
Assert 'the gateway serves' ([int]$r.StatusCode -eq 200) "HTTP $($r.StatusCode): $($r.Content)"
if ([int]$r.StatusCode -ne 200) { Write-Host ''; Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }

$orgRemaining = Get-Header $r 'x-org-quota-remaining'
$myRemaining = Get-Header $r 'x-quota-remaining-today'
$tier = Get-Header $r 'x-claude-tier'

Assert 'it reports the shared org budget' ($orgRemaining -match '^\d+$') "x-org-quota-remaining=$orgRemaining"
Assert 'it reports the personal budget'   ($myRemaining -match '^\d+$')  "x-quota-remaining-today=$myRemaining"
Assert 'the two are separate counters'    ($orgRemaining -ne $myRemaining) 'both headers reported the same number'
Write-Host ("         tier {0} · org {1:n0} of {2:n0} left · personal {3:n0} left" -f `
    $tier, [double]$orgRemaining, [double]$quotaOrg, [double]$myRemaining) -ForegroundColor DarkGray

if ($ProveRefusal) {
    foreach ($case in @(
        @{ label = 'organisation'; noun = 'the organisation'; nv = 'quota-org'; remaining = $orgRemaining },
        @{ label = 'personal'; noun = 'the individual'; nv = $(if ($tier -eq 'premium') { 'quota-premium' } else { 'quota-standard' }); remaining = $myRemaining }
    )) {
        Write-Host ''
        Write-Host "P11 live - refusal names $($case.noun)" -ForegroundColor Cyan
        $nv = $case.nv
        $original = Get-Nv $nv
        Write-Host "         $nv is $original - restoring it at the end" -ForegroundColor DarkGray

        try {
            # Strictly below what has been spent. Setting it equal is a boundary
            # case: the quota is exceeded when consumption passes it, not when it
            # reaches it.
            $spent = [double]$original - [double]$case.remaining
            Set-Nv $nv ([long][math]::Max(1, [math]::Floor($spent * 0.9)))
            Start-Sleep -Seconds 15

            $refused = Invoke-Gateway
            Assert 'the call is refused' ([int]$refused.StatusCode -eq 403) "HTTP $($refused.StatusCode)"
            $json = $null
            try { $json = $refused.Content | ConvertFrom-Json } catch { }
            Assert 'the reply is JSON' ($null -ne $json) $refused.Content
            if ($json) {
                Assert 'in Anthropic error shape' ($json.error.type -eq 'rate_limit_error') $refused.Content
                Assert "it names $($case.noun)" ($json.error.budget -eq $case.label) "budget=$($json.error.budget)"
                Write-Host ('         ' + $json.error.message) -ForegroundColor DarkGray
            }
        }
        finally {
            try { Set-Nv $nv $original; Write-Host "         $nv restored to $original" -ForegroundColor DarkGray }
            catch { Write-Host "         RESTORE FAILED - set $nv back to $original by hand" -ForegroundColor Red }
        }
        Start-Sleep -Seconds 15
        $back = Invoke-Gateway
        Assert 'raising the ceiling restores service' ([int]$back.StatusCode -eq 200) "HTTP $($back.StatusCode)"
    }
}
else {
    Write-Host ''
    Write-Host '  Add -ProveRefusal to also exhaust each budget and read the refusal.' -ForegroundColor DarkGray
    Write-Host '  That edits named values on this gateway and restores them afterwards.' -ForegroundColor DarkGray
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P11 holds on the live gateway.' -ForegroundColor Green
exit 0
