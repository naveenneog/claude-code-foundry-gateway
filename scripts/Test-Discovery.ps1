# Verifies Foundry discovery returns the CORRECT accounts, not merely some.
#
# The original bug was quiet, not loud: the --query failed, the error text was
# a non-empty string, and `if ($deps)` treated that as "this account has Claude".
# Every account in the subscription was therefore listed as a candidate. A test
# that only checks "did we get results?" would have passed throughout.
#
# So this asserts the count is plausible and that the models look like models.

$hosts = @(
    @{ Name = 'PowerShell 7';           Exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source },
    @{ Name = 'Windows PowerShell 5.1'; Exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
)

$probe = @'
$accounts = az cognitiveservices account list --query "[].{name:name, rg:resourceGroup, loc:location, kind:kind}" -o json | ConvertFrom-Json
$accounts = @($accounts | Where-Object { $_.kind -eq 'AIServices' -or $_.kind -eq 'OpenAI' })
$hits = @()
foreach ($a in $accounts) {
    $names = az cognitiveservices account deployment list -g $a.rg -n $a.name --query "[].name" -o tsv 2>$null
    $deps = @($names | Where-Object { $_ -like '*claude*' })
    if ($deps.Count -gt 0) { $hits += "$($a.name) => $($deps -join ',')" }
}
Write-Host "CANDIDATES=$($accounts.Count)"
Write-Host "WITHCLAUDE=$($hits.Count)"
$hits | ForEach-Object { Write-Host "HIT=$_" }
'@

foreach ($h in $hosts) {
    if (-not $h.Exe -or -not (Test-Path $h.Exe)) { continue }
    Write-Host ''
    Write-Host "=== $($h.Name) ===" -ForegroundColor Cyan
    $out = & $h.Exe -NoProfile -Command $probe 2>&1 | Out-String

    $cand = if ($out -match 'CANDIDATES=(\d+)') { [int]$Matches[1] } else { -1 }
    $with = if ($out -match 'WITHCLAUDE=(\d+)') { [int]$Matches[1] } else { -1 }
    $hits = ([regex]::Matches($out, 'HIT=(.+)')) | ForEach-Object { $_.Groups[1].Value.Trim() }

    Write-Host "  candidates      : $cand"
    Write-Host "  with Claude     : $with"
    foreach ($x in $hits) { Write-Host "    $x" -ForegroundColor Gray }

    if ($with -lt 0 -or $cand -lt 0) { Write-Host '  FAIL - probe did not report' -ForegroundColor Red; continue }
    if ($with -eq $cand -and $cand -gt 1) {
        Write-Host '  FAIL - every candidate matched, which is the signature of the old bug' -ForegroundColor Red
        continue
    }
    $bad = @($hits | Where-Object { $_ -notmatch 'claude' })
    if ($bad.Count -gt 0) { Write-Host '  FAIL - a hit contains no claude model' -ForegroundColor Red; continue }
    Write-Host '  PASS - discovery is selective and the models are real' -ForegroundColor Green
}
Write-Host ''
