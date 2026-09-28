# P75: install-claude-gateway.sh prices its region and tier prompts and its summary, records the
# tier, region and Foundry account, and offers the FinOps tool, as Install-ClaudeGateway.ps1 does
# since P68 (ADR-0032). Each run is bash from a TEMP copy of the files the installer reads, with
# stub az, curl and pwsh first on a PATH that holds neither the real Azure CLI nor PowerShell 7,
# so nothing reaches Azure, the Retail Prices API or the repository.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'macOS/Linux installer - prices, record and FinOps offer' -ForegroundColor Cyan

# Git Bash on Windows: WSL's bash sees another file system. The system bash elsewhere.
$script:windows = [bool]($IsWindows -or $env:OS -eq 'Windows_NT')
$bash = $null
if ($script:windows) {
    foreach ($c in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', (Join-Path "$env:LOCALAPPDATA" 'Programs\Git\bin\bash.exe'))) { if (Test-Path -LiteralPath $c) { $bash = $c; break } }
}
else { $bash = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $bash) { Write-Host '  SKIP - no Git Bash (Windows) or bash (macOS, Linux) on this machine.' -ForegroundColor Yellow; exit 0 }
if (-not (& $bash -c 'command -v jq' 2>$null)) { Write-Host '  SKIP - jq is not on the bash PATH; the installer needs it.' -ForegroundColor Yellow; exit 0 }

function ConvertTo-BashPath([string]$Path) { if ($script:windows) { '/' + ($Path.Replace('\', '/') -replace '^([A-Za-z]):', '$1') } else { $Path } }
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false)) }

$installerPath = Join-Path $root 'install-claude-gateway.sh'
$installer = [IO.File]::ReadAllText($installerPath)

# ------------------------------------------------------------------ static checks
# The script says it runs on macOS, where /bin/bash is 3.2 (web search 2026-09-28): nothing that
# needs bash 4 - associative arrays, mapfile or readarray, case-changing expansions, |& or &>>.
$bash4 = [regex]::Matches($installer, '(?m)^[^#\n]*(\b(declare|local|typeset)\s+-[a-zA-Z]*A\b|\bmapfile\b|\breadarray\b|\$\{[^}\n]*(,,|\^\^)[^}\n]*\}|\|&|&>>|\bcoproc\b)')
Assert 'the installer uses no construct that needs bash 4' ($bash4.Count -eq 0) (@($bash4 | ForEach-Object { $_.Value.Trim() }) -join ' | ')
$syntax = & $bash -n (ConvertTo-BashPath $installerPath) 2>&1 | Out-String
Assert 'the installer passes bash -n' ($LASTEXITCODE -eq 0) $syntax.Trim()
Assert 'no fixed price or 30-45 minute estimate remains' ($installer -notmatch 'about \$150/month' -and $installer -notmatch '30-45 min')

# ------------------------------------------------------------------ fixtures
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bash-installer-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$fixtures = Join-Path $scratch 'fixtures'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$sub = '00000000-0000-4000-8000-0000000000a1'

# Regions: the Foundry account's (eastus2), four others in its geography group that publish v2
# prices, one there that publishes none (EUAP), one in another group, and a logical region.
$locations = @(
    @{ name = 'eastus2'; displayName = 'East US 2'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'eastus'; displayName = 'East US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'centralus'; displayName = 'Central US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'westus3'; displayName = 'West US 3'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'westcentralus'; displayName = 'West Central US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'eastus2euap'; displayName = 'East US 2 EUAP'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'westeurope'; displayName = 'West Europe'; metadata = @{ regionType = 'Physical'; geographyGroup = 'Europe' } }
    @{ name = 'unitedstates'; displayName = 'United States'; metadata = @{ regionType = 'Logical'; geographyGroup = 'US' } }
)
Write-Lf (Join-Path $fixtures 'locations.json') (ConvertTo-Json -InputObject $locations -Depth 5)
# Hourly rates. eastus2 is the live eastus2 rate on 2026-09-28; a free-tier row and a lower
# tier row must be dropped; westcentralus publishes no Premium v2.
function Row($Region, $Meter, $Price, $Sku = '', $Tier = 0) {
    [ordered]@{ currencyCode = 'USD'; tierMinimumUnits = $Tier; retailPrice = $Price; unitPrice = $Price; armRegionName = $Region; meterName = $Meter; productName = 'API Management'; skuName = $(if ($Sku) { $Sku } else { $Meter -replace ' Unit$', '' }); serviceName = 'API Management'; unitOfMeasure = '1 Hour'; type = 'Consumption' }
}
$rates = [ordered]@{ eastus2 = @(0.20548, 0.9589, 3.83562); westus3 = @(0.19, 0.90, 3.60); eastus = @(0.20548, 0.9589, 3.83562); centralus = @(0.22, 1.02, 4.08); westeurope = @(0.26, 1.10, 4.40) }
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($region in $rates.Keys) { $r = $rates[$region]; $rows.Add((Row $region 'Basic v2 Unit' $r[0])); $rows.Add((Row $region 'Standard v2 Unit' $r[1])); $rows.Add((Row $region 'Premium v2 Unit' $r[2])) }
$rows.Add((Row 'westcentralus' 'Basic v2 Unit' 0.21)); $rows.Add((Row 'westcentralus' 'Standard v2 Unit' 0.99))
# A higher tier than the real row, so it is the marginal row unless free-tier rows are dropped.
$rows.Add((Row 'eastus2' 'Basic v2 Unit' 0 'Basic v2 Free' 5))
$rows.Add((Row 'westus3' 'Basic v2 Unit' 0.50 '' 0)); $rows[3].tierMinimumUnits = 10
$priceUrl = 'https://prices.azure.com/api/retail/prices'
Write-Lf (Join-Path $fixtures 'prices.json') (ConvertTo-Json -InputObject ([ordered]@{ BillingCurrency = 'USD'; Items = @($rows); NextPageLink = $null; Count = $rows.Count }) -Depth 5)
$half = [math]::Floor($rows.Count / 2)
Write-Lf (Join-Path $fixtures 'prices-page1.json') (ConvertTo-Json -InputObject ([ordered]@{ Items = @($rows | Select-Object -First $half); NextPageLink = "$priceUrl`?`$skip=$half"; Count = $half }) -Depth 5)
Write-Lf (Join-Path $fixtures 'prices-page2.json') (ConvertTo-Json -InputObject ([ordered]@{ Items = @($rows | Select-Object -Skip $half); NextPageLink = $null; Count = $rows.Count - $half }) -Depth 5)
Write-Lf (Join-Path $fixtures 'deployments.json') (ConvertTo-Json -InputObject @(@{ name = 'claude-sonnet-5'; properties = @{ model = @{ format = 'Anthropic'; name = 'claude-sonnet-5'; version = '2' } } }) -Depth 6)

# Stubs. Every call is logged; an az call the stub does not know fails with exit 2 and is logged.
$azStub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P75_LOG/az.log"
# jq.exe on Windows ends lines with CRLF: a carriage return left in a value would reach Azure.
case "$*" in *$'\r'*) echo "stub az: carriage return in: $*" >&2; printf 'UNEXPECTED carriage return in: %s\n' "$*" >> "$P75_LOG/az.log"; exit 2 ;; esac
case "$*" in
  version*) echo "2.86.0" ;;
  "account list --query"*) exit 0 ;;
  "account show --query user.name -o tsv") echo "admin@contoso.com" ;;
  "account show --query tenantId -o tsv") echo "00000000-0000-0000-0000-000000000000" ;;
  "account show --query name -o tsv") echo "Contoso Engineering" ;;
  "account show --query id -o tsv") echo "SUBSCRIPTION" ;;
  "account show"*) echo '{"id":"SUBSCRIPTION","name":"Contoso Engineering","user":{"name":"admin@contoso.com"},"tenantId":"00000000-0000-0000-0000-000000000000"}' ;;
  "account set --subscription "*) exit 0 ;;
  "bicep version"*) echo "Bicep CLI version 0.46.1 (545b338e2c)" ;;
  "account list-locations -o json") if [ "${P75_LOCATIONS_MODE:-ok}" = fail ]; then echo "ERROR: locations are unavailable" >&2; exit 1; fi; cat "$P75_FIXTURES/locations.json" ;;
  "cognitiveservices account show "*"--query location -o tsv") echo "eastus2" ;;
  "cognitiveservices account deployment list "*"-o json") cat "$P75_FIXTURES/deployments.json" ;;
  "group create "*) exit 0 ;;
  "deployment group create "*) exit 0 ;;
  "deployment group show "*) echo "https://apim-p75.azure-api.net/claude" ;;
  "ad group show --group "*) exit 0 ;;
  *) echo "stub az: unexpected call: $*" >&2; printf 'UNEXPECTED %s\n' "$*" >> "$P75_LOG/az.log"; exit 2 ;;
esac
'@.Replace('SUBSCRIPTION', $sub)
$curlStub = @'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
printf '%s\n' "$url" >> "$P75_LOG/curl.log"
case "$url" in *$'\r'*) echo "stub curl: carriage return in the url" >&2; exit 3 ;; esac
case "$url" in
  https://management.azure.com/*) printf '200'; exit 0 ;;
  https://prices.azure.com/*) ;;
  *) echo "stub curl: unexpected url: $url" >&2; exit 7 ;;
esac
case "${P75_PRICES_MODE:-ok}" in
  fail) echo "curl: (6) Could not resolve host: prices.azure.com" >&2; exit 6 ;;
  garbage) echo "<html>maintenance</html>"; exit 0 ;;
  paged) if [ "$(grep -c 'prices.azure.com' "$P75_LOG/curl.log")" -le 1 ]; then cat "$P75_FIXTURES/prices-page1.json"; else cat "$P75_FIXTURES/prices-page2.json"; fi ;;
  *) cat "$P75_FIXTURES/prices.json" ;;
esac
'@
$pwshStub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P75_LOG/pwsh.log"
case "$*" in *PSVersionTable*) echo "7.6.6" ;; esac
exit 0
'@

# The files the installer reads, and placeholders for the ones it only names.
$template = Join-Path $scratch 'template'
foreach ($d in 'scripts', 'infra') { New-Item -ItemType Directory -Force -Path (Join-Path $template $d) | Out-Null }
Copy-Item -LiteralPath $installerPath -Destination $template
foreach ($f in 'scripts\banner.sh', 'scripts\preflight.sh') { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $template $f) }
foreach ($f in 'scripts\Sync-ClaudeAccess.ps1', 'scripts\Select-ClaudeFinOpsTooling.ps1', 'infra\main.bicep') { Write-Lf (Join-Path $template $f) '# placeholder' }

function New-InstallerRun {
    param([string]$Id, [string[]]$Arguments = @(), [string[]]$Answers = @(), [hashtable]$Environment = @{}, [switch]$NoPwsh)
    $dir = Join-Path $scratch "runs\$Id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $shadow = Join-Path $dir 'repo'
    Copy-Item -LiteralPath $template -Destination $shadow -Recurse
    $shim = Join-Path $dir 'bin'; $logs = Join-Path $dir 'logs'; $homeDir = Join-Path $dir 'home'
    foreach ($d in $shim, $logs, $homeDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Write-Lf (Join-Path $shim 'az') $azStub
    Write-Lf (Join-Path $shim 'curl') $curlStub
    if (-not $NoPwsh) { Write-Lf (Join-Path $shim 'pwsh') $pwshStub }
    $env = [ordered]@{ P75_LOG = (ConvertTo-BashPath $logs); P75_FIXTURES = (ConvertTo-BashPath $fixtures); HOME = (ConvertTo-BashPath $homeDir) }
    foreach ($k in $Environment.Keys) { $env[$k] = [string]$Environment[$k] }
    $exports = @($env.Keys | ForEach-Object { "export $_='" + ([string]$env[$_]).Replace("'", "'\''") + "'" }) -join "`n"
    $quoted = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' '
    $runner = @"
JQDIR="`$(dirname "`$(command -v jq)")"
export PATH="$(ConvertTo-BashPath $shim):`$JQDIR:/usr/bin:/bin"
chmod +x "$(ConvertTo-BashPath $shim)"/* 2>/dev/null
$exports
cd "$(ConvertTo-BashPath $shadow)" || exit 90
exec bash ./install-claude-gateway.sh $quoted 2>&1
"@
    $runnerPath = Join-Path $dir 'run.sh'
    Write-Lf $runnerPath $runner
    [pscustomobject]@{ Id = $Id; Dir = $dir; Repo = $shadow; Logs = $logs; Runner = $runnerPath; Answers = $Answers }
}
function Invoke-InstallerRuns([object[]]$Runs, [int]$TimeoutSeconds = 150) {
    $started = foreach ($r in $Runs) {
        $psi = [Diagnostics.ProcessStartInfo]::new($bash)
        $psi.ArgumentList.Add((ConvertTo-BashPath $r.Runner))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($name in @($psi.Environment.Keys | Where-Object { $_ -like 'P75_*' -or $_ -in 'CLAUDE_INTERACTIVE', 'CLAUDE_NONINTERACTIVE', 'CI', 'TF_BUILD', 'GITHUB_ACTIONS' })) { [void]$psi.Environment.Remove($name) }
        $p = [Diagnostics.Process]::Start($psi)
        # LF only: bash's read keeps a carriage return in the answer.
        $p.StandardInput.Write((@($r.Answers) -join "`n") + "`n")
        $p.StandardInput.Close()
        [pscustomobject]@{ Run = $r; Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $results = @{}
    foreach ($s in $started) {
        $left = [int][math]::Max(1000, $TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds)
        $timedOut = -not $s.Process.WaitForExit($left)
        if ($timedOut) { try { $s.Process.Kill($true) } catch { } }
        $out = if ($s.Out.Wait(5000)) { $s.Out.Result } else { '' }
        $err = if ($s.Err.Wait(5000)) { $s.Err.Result } else { '' }
        $text = (($out + "`n" + $err) -replace "`e\[[0-9;]*m", '').Replace("`r", '')
        $record = Join-Path $s.Run.Repo 'onboarding\claude-gateway.json'
        $read = { param($n) $f = Join-Path $s.Run.Logs $n; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() } }
        $results[$s.Run.Id] = [pscustomobject]@{
            Id = $s.Run.Id; Text = $text; Lines = @($text -split "`n"); ExitCode = $(if ($timedOut) { -1 } else { $s.Process.ExitCode }); TimedOut = $timedOut
            Az = (& $read 'az.log'); Curl = (& $read 'curl.log'); Pwsh = (& $read 'pwsh.log')
            Record = $(if (Test-Path -LiteralPath $record) { Get-Content -LiteralPath $record -Raw | ConvertFrom-Json } else { $null })
        }
    }
    return $results
}
# The position of the first match in the output. Positions, not line numbers: a prompt answered from
# standard input ends without a newline, so the next output shares its line.
function Get-Index($Result, [string]$Pattern) { $m = [regex]::Match($Result.Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline); if ($m.Success) { $m.Index } else { -1 } }
function Get-PriceCalls($Result) { @($Result.Curl | Where-Object { $_ -like 'https://prices.azure.com/*' }) }
function Get-Tail($Result) { (@($Result.Lines | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' }

try {
    $base = @('--subscription', $sub, '--foundry-account', 'ai-p75', '--foundry-rg', 'rg-ai-p75')
    # Placement answers: resource group, region, tier, name prefix, publisher; then five budgets and two groups.
    function Answers([string]$Region, [string]$Sku, [string]$Prefix = 'p75', [string[]]$Tail = @()) { @('', $Region, $Sku, $Prefix, '') + @('', '', '', '', '') + @('', '') + $Tail }
    $runs = @(
        New-InstallerRun 'terminal' ($base + '--what-if') (Answers '2' 'StandardV2')
        New-InstallerRun 'by-name' ($base + '--what-if') (Answers 'East US' 'BasicV2')
        New-InstallerRun 'unknown' ($base + '--what-if') (@('', 'mars', 'West Europe', 'BasicV2', 'p75', '') + @('', '', '', '', '', '', ''))
        New-InstallerRun 'unreachable' ($base + '--what-if') (Answers '' 'PremiumV2') -Environment @{ P75_PRICES_MODE = 'fail' }
        New-InstallerRun 'garbage' ($base + '--what-if') (Answers '' 'BasicV2') -Environment @{ P75_PRICES_MODE = 'garbage' }
        New-InstallerRun 'paged' ($base + '--what-if') (Answers '4' 'BasicV2') -Environment @{ P75_PRICES_MODE = 'paged' }
        New-InstallerRun 'yes' ($base + @('--yes', '--what-if', '--sku', 'PremiumV2', '--location', 'westus3', '--name-prefix', 'p75'))
        New-InstallerRun 'full-yes' ($base + @('--yes', '--sku', 'StandardV2', '--location', 'westus3', '--name-prefix', 'p75'))
        New-InstallerRun 'offer-accept' $base (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1' }
        New-InstallerRun 'offer-decline' $base (Answers '1' 'BasicV2' 'p75' @('y', 'n')) -Environment @{ CLAUDE_INTERACTIVE = '1' }
        New-InstallerRun 'offer-skip' ($base + '--skip-finops-offer') (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1' }
        New-InstallerRun 'offer-choose' ($base + @('--yes', '--choose-finops', '--sku', 'BasicV2', '--name-prefix', 'p75'))
        New-InstallerRun 'offer-noninteractive' $base (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1'; CLAUDE_NONINTERACTIVE = '1' }
        New-InstallerRun 'no-pwsh' $base (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1' } -NoPwsh
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-InstallerRuns $runs
    Write-Host ("  {0} installer runs in {1:N1} s" -f $res.Count, $clock.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    foreach ($r in $res.Values) {
        Assert "$($r.Id): the run ends without a timeout, and without an Azure CLI call the stub does not know" (-not $r.TimedOut -and -not @($r.Az | Where-Object { $_ -like 'UNEXPECTED *' }).Count) ((@($r.Az | Where-Object { $_ -like 'UNEXPECTED *' }) -join '; ') + ' ' + (Get-Tail $r))
    }

    # -------------------------------------------------------------- the region table, in a terminal
    $t = $res['terminal']
    $header = Get-Index $t 'API Management v2 monthly list price, one unit at 730 hours, from the Azure Retail Prices API, read \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC:'
    $want = @(
        '1\. eastus2 \(Foundry region\)\s+USD 150\.00\s+USD 700\.00\s+USD 2,800\.00\s*$'
        '2\. westus3\s+USD 138\.70\s+USD 657\.00\s+USD 2,628\.00\s*$'
        '3\. eastus\s+USD 150\.00\s+USD 700\.00\s+USD 2,800\.00\s*$'
        '4\. westcentralus\s+USD 153\.30\s+USD 722\.70\s+not published\s*$'
        '5\. centralus\s+USD 160\.60\s+USD 744\.60\s+USD 2,978\.40\s*$'
    )
    $at = @($want | ForEach-Object { Get-Index $t $_ })
    Assert 'the region table: the Foundry region first, then its geography cheapest Basic v2 first, one unit at 730 hours' ($header -ge 0 -and -not @($at | Where-Object { $_ -lt 0 }).Count -and (@($at | Sort-Object) -join ',') -eq ($at -join ',') -and $at[0] -gt $header) ("header=$header rows=$($at -join ',') " + ((@($t.Lines | Where-Object { $_ -match '^\s+\d+\. ' }) | Select-Object -First 7) -join ' / '))
    Assert 'the table drops free-tier rows and takes the marginal row of a tiered meter' ((Get-Index $t 'eastus2 \(Foundry region\)\s+USD 0\.00') -lt 0 -and (Get-Index $t 'westus3\s+USD 365\.00') -lt 0) ((@($t.Lines | Where-Object { $_ -match 'eastus2 \(Foundry|westus3' })) -join ' / ')
    Assert 'the table leaves out regions without a v2 price, other geographies and logical regions' ($t.Text -notmatch 'eastus2euap' -and $t.Text -notmatch '\d\. westeurope' -and $t.Text -notmatch 'unitedstates')
    Assert 'the table says these are list prices and names the agreement''s price sheet (U31)' ($t.Text -match 'These are list prices\. The agreement''s price sheet states what the organization pays' -and $t.Text -match 'U31')
    $prompt = Get-Index $t 'Region \(number or name\) \[eastus2\]:'
    $tierHead = Get-Index $t 'Monthly list price in westus3, one unit at 730 hours \(Azure Retail Prices API, read '
    $tierRows = @((Get-Index $t 'BasicV2\s+USD 138\.70\s*$'), (Get-Index $t 'StandardV2\s+USD 657\.00\s*$'), (Get-Index $t 'PremiumV2\s+USD 2,628\.00\s*$'))
    $skuPrompt = Get-Index $t 'API Management SKU \[BasicV2\]:'
    Assert 'the region is asked after the table, and the tier prompt lists each tier''s price in the chosen region' ($prompt -gt $at[-1] -and $tierHead -gt $prompt -and -not @($tierRows | Where-Object { $_ -le $tierHead }).Count -and $skuPrompt -gt $tierRows[-1]) "prompt=$prompt tier=$tierHead rows=$($tierRows -join ',') sku=$skuPrompt"
    Assert 'the summary names the chosen region and prices the chosen tier there' ($t.Text -match '(?m)^\s+Location\s+westus3\s*$' -and $t.Text -match 'Cost: API Management is the bulk of it - StandardV2 in westus3 is USD 657/month at list price' -and $t.Text -match '\(one unit, 730 hours, Azure retail prices read \d{4}-\d{2}-\d{2}\)\.') (Get-Tail $t)
    Assert 'the provisioning note is the measured figure' ($t.Text -match 'Provisioning takes minutes on the v2 tiers - a Premium v2 install measured 5 minutes 23 seconds end to end\.')
    Assert '--what-if stops after the summary, creating nothing' ($t.ExitCode -eq 0 -and $t.Text -match '--what-if - stopping before any change' -and -not @($t.Az | Where-Object { $_ -like 'group create*' -or $_ -like 'deployment group create*' }).Count) "exit=$($t.ExitCode)"
    $calls = @(Get-PriceCalls $t)
    $decoded = if ($calls.Count) { [uri]::UnescapeDataString($calls[0]) } else { '' }
    Assert 'one Retail Prices API call reads the three v2 unit meters, consumption only' ($calls.Count -eq 1 -and $decoded -match [regex]::Escape("serviceName eq 'API Management' and priceType eq 'Consumption' and (meterName eq 'Basic v2 Unit' or meterName eq 'Standard v2 Unit' or meterName eq 'Premium v2 Unit')")) "$($calls.Count) call(s): $decoded"
    Assert 'the regions come from one az account list-locations' (@($t.Az | Where-Object { $_ -eq 'account list-locations -o json' }).Count -eq 1)

    # -------------------------------------------------------------- answers by name, and unknown names
    $n = $res['by-name']
    Assert 'a region named in another case and spacing is taken' ($n.Text -match '(?m)^\s+Location\s+eastus\s*$' -and $n.Text -match 'BasicV2 in eastus is USD 150/month') (Get-Tail $n)
    $u = $res['unknown']
    Assert 'an unknown region is refused and asked again; a known region outside the table is taken' ($u.Text -match "'mars' is not a region this subscription can use\. Enter a number from the list or a region name such as eastus2\." -and $u.Text -match '(?m)^\s+Location\s+westeurope\s*$' -and $u.Text -match 'BasicV2 in westeurope is USD 190/month') (Get-Tail $u)

    # -------------------------------------------------------------- prices that cannot be read
    $x = $res['unreachable']
    Assert 'unreachable prices: the region prompt says why, and the install goes on' ($x.Text -match [regex]::Escape('API Management prices could not be read (curl: (6) Could not resolve host: prices.azure.com). The summary prices the choice if it can.') -and $x.Text -notmatch 'monthly list price, one unit at 730 hours, from') (Get-Tail $x)
    Assert 'unreachable prices: the tier prompt says so' ($x.Text -match [regex]::Escape('Tier prices could not be read: curl: (6) Could not resolve host: prices.azure.com'))
    Assert 'unreachable prices: the summary says the price could not be read and names the pricing page' ($x.Text -match 'The PremiumV2 price in eastus2 could not be read' -and $x.Text -match [regex]::Escape('https://azure.microsoft.com/pricing/details/api-management/') -and $x.ExitCode -eq 0) (Get-Tail $x)
    Assert 'unreachable prices are read once, not again at the tier prompt or the summary' ((@(Get-PriceCalls $x)).Count -eq 1) "$((@(Get-PriceCalls $x)).Count) calls"
    $g = $res['garbage']
    Assert 'a response that is not a price list is reported as such' ($g.Text -match [regex]::Escape('API Management prices could not be read (the response was not a price list)') -and $g.Text -match 'The BasicV2 price in eastus2 could not be read') (Get-Tail $g)
    $p = $res['paged']
    Assert 'a paged response is read to its last page' ((@(Get-PriceCalls $p)).Count -eq 2 -and (@(Get-PriceCalls $p))[1] -eq "$priceUrl`?`$skip=$half" -and (Get-Index $p '5\. centralus\s+USD 160\.60') -ge 0 -and $p.Text -match '(?m)^\s+Location\s+westcentralus\s*$') ((@(Get-PriceCalls $p)) -join ' ; ')

    # -------------------------------------------------------------- unattended
    $y = $res['yes']
    Assert '--yes: no region table and no tier list' ($y.Text -notmatch 'Region \(number or name\)' -and $y.Text -notmatch 'monthly list price, one unit at 730 hours, from' -and $y.Text -notmatch 'Monthly list price in ' -and -not @($y.Az | Where-Object { $_ -like 'account list-locations*' }).Count) (Get-Tail $y)
    Assert '--yes: the summary still prices the choice' ($y.Text -match 'PremiumV2 in westus3 is USD 2,628/month at list price' -and (@(Get-PriceCalls $y)).Count -eq 1) (Get-Tail $y)

    # -------------------------------------------------------------- the record
    $f = $res['full-yes']
    $rec = $f.Record
    Assert 'a full run deploys through the stubs and writes the record' ($f.ExitCode -eq 0 -and $rec) ("exit=$($f.ExitCode) " + (Get-Tail $f))
    Assert 'the record holds mode, tier, region, Foundry account and group, and the request ceiling' ($rec -and $rec.mode -eq 'gateway' -and $rec.sku -eq 'StandardV2' -and $rec.location -eq 'westus3' -and $rec.foundryAccount -eq 'ai-p75' -and $rec.foundryResourceGroup -eq 'rg-ai-p75' -and $rec.requestsPerMinute -eq 120) ($rec | ConvertTo-Json -Compress -Depth 3)
    Assert 'the record keeps what it held: gateway, groups, tiers and deployments' ($rec -and $rec.apimName -eq 'apim-p75' -and $rec.gatewayUrl -eq 'https://apim-p75.azure-api.net/claude' -and $rec.standardGroup -eq 'claude-code-standard' -and $rec.tiers.standard.tokensPerMinute -eq 20000 -and @($rec.models) -contains 'claude-sonnet-5')
    Assert 'the deployment step names a few minutes, not 30-45' ($f.Text -match 'API Management and Application Insights \(a few minutes\)')

    # -------------------------------------------------------------- the FinOps offer
    $finopsRun = { param($r) @($r.Pwsh | Where-Object { $_ -match 'Select-ClaudeFinOpsTooling\.ps1' }) }
    $offerText = 'Set up a FinOps tool now\? It lists each tool with its monthly price in eastus2'
    $step = 'Choose optional FinOps tooling: pwsh -File scripts/Select-ClaudeFinOpsTooling.ps1 -Region'
    $a = $res['offer-accept']
    $opened = @(& $finopsRun $a)
    Assert 'in a terminal the installer ends by offering the FinOps tool, and a yes opens it for the region and subscription' ($a.ExitCode -eq 0 -and $a.Text -match $offerText -and $opened.Count -eq 1 -and $opened[0] -match '^-NoProfile -File .+/scripts/Select-ClaudeFinOpsTooling\.ps1 -Region eastus2 -SubscriptionId ' + [regex]::Escape($sub) + '$') ("exit=$($a.ExitCode) pwsh=" + ($a.Pwsh -join ' ; ') + ' ' + (Get-Tail $a))
    Assert 'the offer comes after the numbered next steps' ((Get-Index $a $offerText) -gt (Get-Index $a '3\. Close the direct-access bypass'))
    $d = $res['offer-decline']
    Assert 'a no leaves the command for later' ($d.Text -match $offerText -and -not (& $finopsRun $d).Count -and $d.Text -match [regex]::Escape('Later: pwsh -File scripts/Select-ClaudeFinOpsTooling.ps1 -Region eastus2')) (Get-Tail $d)
    $s = $res['offer-skip']
    Assert '--skip-finops-offer: no offer, no FinOps step' ($s.ExitCode -eq 0 -and $s.Text -notmatch 'Set up a FinOps tool now' -and $s.Text -notmatch 'Select-ClaudeFinOpsTooling' -and -not (& $finopsRun $s).Count) (Get-Tail $s)
    $c = $res['offer-choose']
    Assert '--choose-finops opens it without asking, even under --yes' ($c.ExitCode -eq 0 -and $c.Text -notmatch 'Set up a FinOps tool now' -and (@(& $finopsRun $c)).Count -eq 1) ("pwsh=" + ($c.Pwsh -join ' ; '))
    Assert 'under --yes the FinOps command is a numbered next step' ($f.Text -match ('(?m)^\s+4\. ' + [regex]::Escape($step) + ' westus3\s*$') -and $f.Text -notmatch 'Set up a FinOps tool now' -and -not (& $finopsRun $f).Count) (Get-Tail $f)
    $ni = $res['offer-noninteractive']
    Assert 'CLAUDE_NONINTERACTIVE=1 wins over CLAUDE_INTERACTIVE=1: no offer, the step instead' ($ni.Text -notmatch 'Set up a FinOps tool now' -and $ni.Text -match [regex]::Escape($step) -and -not (& $finopsRun $ni).Count) (Get-Tail $ni)
    $np = $res['no-pwsh']
    Assert 'without PowerShell 7 there is no offer, and the step says it needs PowerShell 7' ($np.ExitCode -eq 0 -and $np.Text -notmatch 'Set up a FinOps tool now' -and $np.Text -match [regex]::Escape('Choose optional FinOps tooling (needs PowerShell 7): pwsh -File scripts/Select-ClaudeFinOpsTooling.ps1 -Region eastus2')) (Get-Tail $np)
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The macOS/Linux installer prices its choices, records them and offers the FinOps tool.' -ForegroundColor Green
exit 0
