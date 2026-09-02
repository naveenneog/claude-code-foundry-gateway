# P12 verification against the live gateway.
#
# Asserts behaviour, not shape: that APIM accepts the expression-driven quota,
# that the reader reports what the gateway would actually apply, that setting an
# override changes it, that clearing it returns to the tier default, and that a
# second person's override survives both operations.
#
# The override map is captured first and restored in a finally block.

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

# ARM returned a pre-write value once immediately after a successful write, so
# the read-back polls rather than asserting on the first answer.
function Wait-Nv($name, $predicate, $seconds = 20) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        $value = Get-Nv $name
        if (& $predicate $value) { return $value }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $value
}
function Set-Nv($name, $value) {
    $b = @{ properties = @{ displayName = $name; value = "$value"; secret = $false } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/namedValues/$name$v" -Headers $H -Body $b | Out-Null
}
function Call {
    $t = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
    $payload = @{ model = 'claude-sonnet-5'; max_tokens = 40; messages = @(@{ role = 'user'; content = 'Say OK.' }) } | ConvertTo-Json -Depth 5
    return Invoke-WebRequest -Uri "https://$svc.azure-api.net/claude/v1/messages" -Method Post -Body $payload `
           -ContentType 'application/json' -SkipHttpErrorCheck `
           -Headers @{ Authorization = 'Bearer ' + $t.Trim(); 'anthropic-version' = '2023-06-01' }
}

$myOid = (az ad signed-in-user show --query id -o tsv).Trim()
$otherOid = '00000000-0000-0000-0000-000000000001'
$savedMap = $null

try {
    Write-Host ''
    Write-Host 'P12 live - deploy' -ForegroundColor Cyan

    # Seed the map with a second person, so every later step can be checked for
    # having left them alone.
    $savedMap = Get-Nv 'quota-overrides'
    if ($null -eq $savedMap) { Set-Nv 'quota-overrides' ',,'; $savedMap = ',,' }
    Set-Nv 'quota-overrides' ",$otherOid=777777,"
    Assert 'quota-overrides exists' $true

    $policy = Get-Content (Join-Path $root 'infra/policy.xml') -Raw
    $b = @{ properties = @{ value = $policy; format = 'rawxml' } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "$base/apis/claude-foundry/policies/policy$v" -Headers $H -Body $b | Out-Null
    Assert 'APIM accepted the expression-driven quota' $true
    Start-Sleep -Seconds 12

    Write-Host ''
    Write-Host 'P12 live - tier default applies without an override' -ForegroundColor Cyan
    $r = Call
    Assert 'the gateway serves' ([int]$r.StatusCode -eq 200) "HTTP $($r.StatusCode): $($r.Content)"
    $tier = ($r.Headers['x-claude-tier'] -join '')
    $tierQuota = [long](Get-Nv $(if ($tier -eq 'premium') { 'quota-premium' } else { 'quota-standard' }))
    $remaining = [long](($r.Headers['x-quota-remaining-today'] -join ''))
    Assert 'remaining is within the tier default' ($remaining -le $tierQuota) "remaining=$remaining tier=$tierQuota"
    Write-Host ("         tier {0}, daily {1:n0}, {2:n0} left" -f $tier, $tierQuota, $remaining) -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'P12 live - the reader agrees with the gateway' -ForegroundColor Cyan
    $report = & (Join-Path $root 'scripts/Get-ClaudeBudget.ps1') -ResourceGroup $rg -ApimName $svc -AsJson | Out-String | ConvertFrom-Json
    $me = @($report.developers | Where-Object { $_.object_id -eq $myOid })
    Assert 'the reader finds this developer' ($me.Count -eq 1) "$($report.developers.Count) developer(s) reported"
    if ($me.Count -eq 1) {
        Assert 'it reports the tier the gateway used'  ($me[0].tier -eq $tier) "reader=$($me[0].tier) gateway=$tier"
        Assert 'it reports the tier default as source' ($me[0].effective.tokens_per_day_from -eq 'tier') $me[0].effective.tokens_per_day_from
        Assert 'it reports the same daily budget'      ([long]$me[0].effective.tokens_per_day -eq $tierQuota) "reader=$($me[0].effective.tokens_per_day) gateway=$tierQuota"
    }
    Assert 'it reports the org ceiling' ([long]$report.organisation.tokens_per_month -gt 0) "$($report.organisation.tokens_per_month)"
    Assert 'it flags the cap as soft'   ($report.organisation.soft_cap -eq $true)

    Write-Host ''
    Write-Host 'P12 live - setting an override changes what applies' -ForegroundColor Cyan
    & (Join-Path $root 'scripts/Set-ClaudeBudget.ps1') -User $myOid -Tokens 4242 -ResourceGroup $rg -ApimName $svc | Out-Null
    $map = Wait-Nv 'quota-overrides' { param($x) $x -match [regex]::Escape("$myOid=4242") }
    Assert 'the override was written'   ($map -match [regex]::Escape("$myOid=4242")) "map=$map"
    Assert 'the other person survived'  ($map -match [regex]::Escape("$otherOid=777777")) "map=$map"

    Start-Sleep -Seconds 15
    $r2 = Call
    $rem2 = [long](($r2.Headers['x-quota-remaining-today'] -join ''))
    Assert 'the gateway now applies the override' ($rem2 -le 4242) "remaining=$rem2, override was 4242"
    Write-Host ("         daily budget now 4,242 · {0:n0} left" -f $rem2) -ForegroundColor DarkGray

    $report2 = & (Join-Path $root 'scripts/Get-ClaudeBudget.ps1') -User $myOid -ResourceGroup $rg -ApimName $svc -AsJson | Out-String | ConvertFrom-Json
    Assert 'the reader shows the override'   ([long]$report2.developers[0].effective.tokens_per_day -eq 4242) $report2.developers[0].effective.tokens_per_day
    Assert 'and says it came from an override' ($report2.developers[0].effective.tokens_per_day_from -eq 'override')

    Write-Host ''
    Write-Host 'P12 live - clearing it returns to the tier default' -ForegroundColor Cyan
    & (Join-Path $root 'scripts/Set-ClaudeBudget.ps1') -User $myOid -Clear -ResourceGroup $rg -ApimName $svc | Out-Null
    $map2 = Wait-Nv 'quota-overrides' { param($x) $x -notmatch [regex]::Escape("$myOid=") }
    Assert 'the override is gone'      ($map2 -notmatch [regex]::Escape("$myOid=")) "map=$map2"
    Assert 'the other person survived' ($map2 -match [regex]::Escape("$otherOid=777777")) "map=$map2"

    Start-Sleep -Seconds 15
    $r3 = Call
    Assert 'the gateway serves again' ([int]$r3.StatusCode -eq 200) "HTTP $($r3.StatusCode)"
    $rem3 = [long](($r3.Headers['x-quota-remaining-today'] -join ''))
    Assert 'the tier default is back' ($rem3 -gt 4242) "remaining=$rem3"
    Write-Host ("         back to the tier default · {0:n0} left" -f $rem3) -ForegroundColor DarkGray
}
finally {
    if ($null -ne $savedMap) {
        try { Set-Nv 'quota-overrides' $savedMap; Write-Host "`n  quota-overrides restored to '$savedMap'" -ForegroundColor DarkGray }
        catch { Write-Host "  RESTORE FAILED - set quota-overrides back to '$savedMap' by hand" -ForegroundColor Red }
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P12 verified against the live gateway.' -ForegroundColor Green
exit 0
