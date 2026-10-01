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
# A missing bash or jq fails the suite: nothing would be checked. Test-All skips it with the reason.
if (-not $bash) { Write-Host '  [FAIL] no Git Bash (Windows) or bash (macOS, Linux) on this machine, so no installer check runs.' -ForegroundColor Red; exit 1 }
$jqPath = "$(@(& $bash -c 'command -v jq' 2>$null) | Select-Object -First 1)".Trim()
if (-not $jqPath) { Write-Host '  [FAIL] jq is not on the bash PATH, so no installer check runs; the installer needs jq.' -ForegroundColor Red; exit 1 }
# The runs' PATH is the stubs, then /usr/bin and /bin. A real pwsh there would answer the run that
# has no PowerShell 7 (apt installs /usr/bin/pwsh). "$()": a cast of an empty pipeline is $null.
$systemPwsh = "$(@(& $bash -c 'PATH=/usr/bin:/bin command -v pwsh' 2>$null) | Select-Object -First 1)".Trim()

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

# Regions: the Foundry account's (eastus2), six others in its geography group that publish v2
# prices, one there that publishes none (EUAP), one in another group, and a logical region.
$locations = @(
    @{ name = 'eastus2'; displayName = 'East US 2'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'eastus'; displayName = 'East US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'centralus'; displayName = 'Central US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'westus3'; displayName = 'West US 3'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'westcentralus'; displayName = 'West Central US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'northcentralus'; displayName = 'North Central US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'southcentralus'; displayName = 'South Central US'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'eastus2euap'; displayName = 'East US 2 EUAP'; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    @{ name = 'westeurope'; displayName = 'West Europe'; metadata = @{ regionType = 'Physical'; geographyGroup = 'Europe' } }
    @{ name = 'unitedstates'; displayName = 'United States'; metadata = @{ regionType = 'Logical'; geographyGroup = 'US' } }
)
Write-Lf (Join-Path $fixtures 'locations.json') (ConvertTo-Json -InputObject $locations -Depth 5)
# The same list behind entries that are not region objects, which the installers skip.
Write-Lf (Join-Path $fixtures 'locations-malformed.json') (ConvertTo-Json -InputObject (@('eastus9', $null, 5, @{ name = 5; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }, @{ name = 'westus9'; metadata = 'Physical' }, @{ name = 'northus9' }) + $locations) -Depth 5)
# Hourly rates. eastus2 is the live eastus2 rate on 2026-09-28; a free-tier row and a lower
# tier row must be dropped; westcentralus publishes no Premium v2, northcentralus no Standard v2
# and southcentralus no Basic v2. 0.2205 an hour is 160.965 a month, on a half cent.
function Row($Region, $Meter, $Price, $Sku = '', $Tier = 0) {
    [ordered]@{ currencyCode = 'USD'; tierMinimumUnits = $Tier; retailPrice = $Price; unitPrice = $Price; armRegionName = $Region; meterName = $Meter; productName = 'API Management'; skuName = $(if ($Sku) { $Sku } else { $Meter -replace ' Unit$', '' }); serviceName = 'API Management'; unitOfMeasure = '1 Hour'; type = 'Consumption' }
}
$rates = [ordered]@{ eastus2 = @(0.20548, 0.9589, 3.83562); westus3 = @(0.19, 0.90, 3.60); eastus = @(0.20548, 0.9589, 3.83562); centralus = @(0.22, 1.02, 4.08); westeurope = @(0.26, 1.10, 4.40) }
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($region in $rates.Keys) { $r = $rates[$region]; $rows.Add((Row $region 'Basic v2 Unit' $r[0])); $rows.Add((Row $region 'Standard v2 Unit' $r[1])); $rows.Add((Row $region 'Premium v2 Unit' $r[2])) }
$rows.Add((Row 'westcentralus' 'Basic v2 Unit' 0.21)); $rows.Add((Row 'westcentralus' 'Standard v2 Unit' 0.99))
$rows.Add((Row 'northcentralus' 'Basic v2 Unit' 0.2205)); $rows.Add((Row 'northcentralus' 'Premium v2 Unit' 3.90))
$rows.Add((Row 'southcentralus' 'Standard v2 Unit' 1.05)); $rows.Add((Row 'southcentralus' 'Premium v2 Unit' 4.20))
# A higher tier than the real row, so it is the marginal row unless free-tier rows are dropped.
$rows.Add((Row 'eastus2' 'Basic v2 Unit' 0 'Basic v2 Free' 5))
$rows.Add((Row 'westus3' 'Basic v2 Unit' 0.50 '' 0)); $rows[3].tierMinimumUnits = 10
$priceUrl = 'https://prices.azure.com/api/retail/prices'
function Write-PriceList([string]$Name, [object[]]$Items, $NextPageLink = $null) { Write-Lf (Join-Path $fixtures $Name) (ConvertTo-Json -InputObject ([ordered]@{ BillingCurrency = 'USD'; Items = @($Items); NextPageLink = $NextPageLink; Count = @($Items).Count }) -Depth 5) }
Write-PriceList 'prices.json' $rows
$half = [math]::Floor($rows.Count / 2)
# The next page in the form the API writes it (read 2026-09-28), and two it must not follow.
$nextPage = "https://prices.azure.com:443/api/retail/prices?`$filter=serviceName%20eq%20%27API%20Management%27&`$skip=$half"
Write-PriceList 'prices-page1.json' @($rows | Select-Object -First $half) $nextPage
Write-PriceList 'prices-page2.json' @($rows | Select-Object -Skip $half)
Write-PriceList 'prices-offhost.json' @($rows | Select-Object -First $half) "https://prices.azure.com.evil.example/api/retail/prices?`$skip=$half"
Write-PriceList 'prices-plainhttp.json' @($rows | Select-Object -First $half) "http://prices.azure.com/api/retail/prices?`$skip=$half"
# A price written as a string: a price list, but not in the form the API publishes.
$badRows = @($rows | ForEach-Object { $copy = [ordered]@{}; foreach ($k in $_.Keys) { $copy[$k] = $_[$k] }; $copy })
$badRows[0].retailPrice = '0.20548'
Write-PriceList 'prices-badprice.json' $badRows
# Parity: 60 generated regions in the Foundry region's geography. Each tier is priced at a half-cent
# month (j/2000 an hour, j odd), at up to nine decimal places, at a monthly figure divided by 730,
# or not at all. The table must be the one Install-ClaudeGateway.ps1 prints for the same list.
$rng = [Random]::new(75)
$parityLocations = @($locations[0]) + @(1..60 | ForEach-Object { @{ name = ('pr{0:D2}' -f $_); displayName = ('Parity {0:D2}' -f $_); metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } } })
$parityRows = [System.Collections.Generic.List[object]]::new()
foreach ($i in 0..2) { $parityRows.Add($rows[$i]) }
$halfCent = 0
foreach ($loc in @($parityLocations | Select-Object -Skip 1)) {
    foreach ($meter in 'Basic v2 Unit', 'Standard v2 Unit', 'Premium v2 Unit') {
        $kind = $rng.Next(0, 8)
        if ($kind -eq 0) { continue }
        if ($kind -le 3) { $price = [double](2 * $rng.Next(0, 4000) + 1) / 2000; $halfCent++ }
        elseif ($kind -le 6) { $price = [math]::Round($rng.NextDouble() * 12, $rng.Next(1, 10)) }
        else { $price = ($rng.Next(100, 300000) / 100.0) / 730 }
        $parityRows.Add((Row $loc.name $meter $price))
    }
}
# Ten more written as the API could write them: trailing zeros, exponents, 16 significant digits (which
# [decimal] cuts to 15, 0.2215) and above 10,000; all but 1.25e-05 are half-cent months. Four more are
# 17-digit prices a hair from a half-cent month, where [decimal]'s conversion (VarDecFromR8, in double
# arithmetic) and cutting the shortest decimal form to 15 digits give different cents: PowerShell 7
# prices them 5.48, 147.10, 752.27 and 2918.90. Sentinels are written first and replaced in the JSON text.
$literals = [ordered]@{ '7.77777701' = '0.2005000000'; '7.77777702' = '2.005000000e-1'; '7.77777703' = '10000.0005'; '7.77777704' = '6.25E-2'; '7.77777705' = '0.2214999999999999'; '7.77777706' = '1.25e-05'; '7.77777707' = '0.0074999999999999945'; '7.77777708' = '0.20149999999999949'; '7.77777709' = '1.0305000000000051'; '7.77777711' = '3.9985000000000052' }
$n = $parityLocations.Count
foreach ($sentinel in $literals.Keys) {
    $name = 'pr{0:D2}' -f $n; $n++
    $parityLocations += @{ name = $name; displayName = "Parity $name"; metadata = @{ regionType = 'Physical'; geographyGroup = 'US' } }
    $parityRows.Add((Row $name 'Basic v2 Unit' ([double]$sentinel))); if ($literals[$sentinel] -ne '1.25e-05' -and $sentinel -notin '7.77777707', '7.77777708', '7.77777709', '7.77777711') { $halfCent++ }
}
Write-Lf (Join-Path $fixtures 'locations-parity.json') (ConvertTo-Json -InputObject $parityLocations -Depth 5)
Write-PriceList 'prices-parity.json' $parityRows
$parityPath = Join-Path $fixtures 'prices-parity.json'
$parityText = [IO.File]::ReadAllText($parityPath)
foreach ($sentinel in $literals.Keys) {
    $pattern = '("retailPrice":\s*)' + [regex]::Escape($sentinel) + '(?=[,\s}])'
    if ([regex]::Matches($parityText, $pattern).Count -ne 1) { throw "parity fixture: retailPrice $sentinel is not written once" }
    $parityText = [regex]::Replace($parityText, $pattern, '${1}' + $literals[$sentinel])
}
Write-Lf $parityPath $parityText
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
  "account list-locations -o json")
    case "${P75_LOCATIONS_MODE:-ok}" in
      malformed) cat "$P75_FIXTURES/locations-malformed.json" ;;
      parity) cat "$P75_FIXTURES/locations-parity.json" ;;
      *) cat "$P75_FIXTURES/locations.json" ;;
    esac ;;
  "cognitiveservices account show "*"--query location -o tsv") echo "eastus2" ;;
  "cognitiveservices account deployment list "*"-o json") cat "$P75_FIXTURES/deployments.json" ;;
  "group create "*) exit 0 ;;
  "deployment group create "*) exit 0 ;;
  "deployment group show "*) echo "https://apim-p75.azure-api.net/claude" ;;
  "group show "*) echo "ERROR: (ResourceGroupNotFound) Resource group could not be found." >&2; exit 3 ;;
  "apim show "*) echo "ERROR: (ResourceNotFound) The Resource was not found." >&2; exit 3 ;;
  "deployment group list "*) echo '[]' ;;
  "ad group list --display-name "*) printf '[{"id":"00000000-0000-0000-0000-0000000000a5","displayName":"%s"}]\n' "$5" ;;
  "ad group show --group "*"-o json") printf '{"id":"00000000-0000-0000-0000-0000000000a5","displayName":"%s"}\n' "$5" ;;
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
  https://prices.azure.com/*|https://prices.azure.com:443/*) ;;
  *) echo "stub curl: unexpected url: $url" >&2; exit 7 ;;
esac
case "${P75_PRICES_MODE:-ok}" in
  fail) echo "curl: (6) Could not resolve host: prices.azure.com" >&2; exit 6 ;;
  garbage) echo "<html>maintenance</html>"; exit 0 ;;
  paged) if [ "$(grep -c 'prices.azure.com' "$P75_LOG/curl.log")" -le 1 ]; then cat "$P75_FIXTURES/prices-page1.json"; else cat "$P75_FIXTURES/prices-page2.json"; fi ;;
  offhost|plainhttp|badprice|parity) cat "$P75_FIXTURES/prices-$P75_PRICES_MODE.json" ;;
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
foreach ($f in 'scripts\banner.sh', 'scripts\preflight.sh', 'scripts\install-checkpoint.sh', 'scripts\install-resume.sh') { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $template $f) }
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
    # jq by its absolute path, not its directory on the PATH: that directory can hold a real az or
    # pwsh as well (Homebrew links all three into /opt/homebrew/bin).
    # P75_JQ_VERSION makes jq --version print another release, for the preflight's version check.
    Write-Lf (Join-Path $shim 'jq') ("#!/usr/bin/env bash`nif [ `"`$1`" = '--version' ] && [ -n `"`${P75_JQ_VERSION:-}`" ]; then printf '%s\n' `"`$P75_JQ_VERSION`"; exit 0; fi`nexec '" + $jqPath.Replace("'", "'\''") + "' `"`$@`"`n")
    if (-not $NoPwsh) { Write-Lf (Join-Path $shim 'pwsh') $pwshStub }
    $env = [ordered]@{ P75_LOG = (ConvertTo-BashPath $logs); P75_FIXTURES = (ConvertTo-BashPath $fixtures); HOME = (ConvertTo-BashPath $homeDir) }
    foreach ($k in $Environment.Keys) { $env[$k] = [string]$Environment[$k] }
    $exports = @($env.Keys | ForEach-Object { "export $_='" + ([string]$env[$_]).Replace("'", "'\''") + "'" }) -join "`n"
    $quoted = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' '
    $runner = @"
export PATH="$(ConvertTo-BashPath $shim):/usr/bin:/bin"
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
function Get-PriceCalls($Result) { @($Result.Curl | Where-Object { $_ -like 'https://prices.azure.com/*' -or $_ -like 'https://prices.azure.com:443/*' }) }
function Get-Tail($Result) { (@($Result.Lines | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' }
# The numbered rows of the region table, whitespace collapsed.
function Get-TableRows($Result) {
    $start = Get-Index $Result 'API Management v2 monthly list price, one unit at 730 hours, from the Azure Retail Prices API'
    $end = Get-Index $Result 'Region \(number or name\)'
    if ($start -lt 0 -or $end -lt $start) { return @() }
    @($Result.Text.Substring($start, $end - $start) -split "`n" | Where-Object { $_ -match '^\s*\d+\. ' } | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
}
# The same table from Install-ClaudeGateway.ps1's own functions, over the same fixture files.
. (Join-Path $root 'scripts\ClaudeGatewayRegion.ps1')
function Invoke-RestMethod { param($Uri, $TimeoutSec, $ErrorAction) [pscustomobject]@{ Items = @($script:referenceItems); NextPageLink = $null } }
function Get-PowerShellTableRows([string]$Locations, [string]$Prices) {
    $script:RetailPriceCache.Clear()
    $script:referenceItems = @(([IO.File]::ReadAllText((Join-Path $fixtures $Prices)) | ConvertFrom-Json).Items)
    $read = Get-ClaudeApimV2Prices
    $parsed = [IO.File]::ReadAllText((Join-Path $fixtures $Locations)) | ConvertFrom-Json
    $options = @(Get-ClaudeGatewayRegionOptions -FoundryRegion 'eastus2' -Locations @($parsed) -Prices $read)
    @(Format-ClaudeGatewayRegionTable -Options $options -Prices $read | Where-Object { $_ -match '^\s*\d+\. ' } | ForEach-Object { ($_ -replace '\s+', ' ').Trim() })
}
function Compare-Rows([string[]]$Bash, [string[]]$PowerShell) {
    for ($i = 0; $i -lt [math]::Max($Bash.Count, $PowerShell.Count); $i++) {
        if ($Bash[$i] -cne $PowerShell[$i]) { return "row $($i + 1): bash '$($Bash[$i])', PowerShell '$($PowerShell[$i])'" }
    }
    return ''
}

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
        New-InstallerRun 'malformed' ($base + '--what-if') (@('', 'atlantis', 'West Europe', 'BasicV2', 'p75', '') + @('', '', '', '', '', '', '')) -Environment @{ P75_LOCATIONS_MODE = 'malformed' }
        New-InstallerRun 'badprice' ($base + '--what-if') (Answers '' 'BasicV2') -Environment @{ P75_PRICES_MODE = 'badprice' }
        New-InstallerRun 'offhost' ($base + '--what-if') (Answers '' 'BasicV2') -Environment @{ P75_PRICES_MODE = 'offhost' }
        New-InstallerRun 'plainhttp' ($base + '--what-if') (Answers '' 'BasicV2') -Environment @{ P75_PRICES_MODE = 'plainhttp' }
        New-InstallerRun 'parity' ($base + '--what-if') (Answers '' 'BasicV2') -Environment @{ P75_PRICES_MODE = 'parity'; P75_LOCATIONS_MODE = 'parity' }
        New-InstallerRun 'yes' ($base + @('--yes', '--what-if', '--sku', 'PremiumV2', '--location', 'westus3', '--name-prefix', 'p75'))
        New-InstallerRun 'full-yes' ($base + @('--yes', '--sku', 'StandardV2', '--location', 'westus3', '--name-prefix', 'p75'))
        New-InstallerRun 'offer-accept' $base (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1' }
        New-InstallerRun 'offer-decline' $base (Answers '1' 'BasicV2' 'p75' @('y', 'n')) -Environment @{ CLAUDE_INTERACTIVE = '1' }
        New-InstallerRun 'offer-skip' ($base + '--skip-finops-offer') (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1' }
        New-InstallerRun 'offer-choose' ($base + @('--yes', '--choose-finops', '--sku', 'BasicV2', '--name-prefix', 'p75'))
        New-InstallerRun 'offer-noninteractive' $base (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1'; CLAUDE_NONINTERACTIVE = '1' }
        New-InstallerRun 'no-pwsh' $base (Answers '1' 'BasicV2' 'p75' @('y', 'y')) -Environment @{ CLAUDE_INTERACTIVE = '1' } -NoPwsh
        # jq 1.7.0 as its Windows build names itself, and 1.7.1: only the first is warned about.
        New-InstallerRun 'jq-1.7' ($base + @('--yes', '--what-if', '--sku', 'BasicV2', '--location', 'westus3', '--name-prefix', 'p75')) -Environment @{ P75_JQ_VERSION = 'jq-1.7-dirty' }
        New-InstallerRun 'jq-1.7.1' ($base + @('--yes', '--what-if', '--sku', 'BasicV2', '--location', 'westus3', '--name-prefix', 'p75')) -Environment @{ P75_JQ_VERSION = 'jq-1.7.1' }
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
    $gaps = @((Get-Index $t '6\. northcentralus\s+USD 160\.9\d\s+not published\s+USD 2,847\.00\s*$'), (Get-Index $t '7\. southcentralus\s+not published\s+USD 766\.50\s+USD 3,066\.00\s*$'))
    Assert 'a price that is not published keeps its column: a missing middle or first price moves no other price' (-not @($gaps | Where-Object { $_ -le $at[-1] }).Count) ((@($t.Lines | Where-Object { $_ -match '\d\. (north|south)centralus' })) -join ' / ')
    Assert 'a half-cent month is rounded to even, as the PowerShell installer rounds it: 0.2205 an hour is USD 160.96 a month' ((Get-Index $t '6\. northcentralus\s+USD 160\.96\s') -ge 0) ((@($t.Lines | Where-Object { $_ -match '\d\. northcentralus' })) -join ' / ')
    $psRows = @(Get-PowerShellTableRows 'locations.json' 'prices.json')
    $bashRows = @(Get-TableRows $t)
    $gap = Compare-Rows $bashRows $psRows
    Assert 'the region table is the one Install-ClaudeGateway.ps1 prints for the same regions and prices' ($psRows.Count -eq 7 -and -not $gap) "$($bashRows.Count) bash rows, $($psRows.Count) PowerShell rows; $gap"
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
    Assert 'a paged response is read to its last page, through the next-page link as the API writes it' ((@(Get-PriceCalls $p)).Count -eq 2 -and (@(Get-PriceCalls $p))[1] -eq $nextPage -and (Get-Index $p '5\. centralus\s+USD 160\.60') -ge 0 -and $p.Text -match '(?m)^\s+Location\s+westcentralus\s*$') ((@(Get-PriceCalls $p)) -join ' ; ')

    # -------------------------------------------------------------- lists not in the form the APIs write
    $m = $res['malformed']
    Assert 'a region list with entries that are not regions still checks the answer: an unknown name is refused, a known one outside the table taken' ($m.Text -match "'atlantis' is not a region this subscription can use\." -and $m.Text -match '(?m)^\s+Location\s+westeurope\s*$' -and $m.Text -match 'BasicV2 in westeurope is USD 190/month' -and (Get-Index $m '2\. westus3\s+USD 138\.70') -ge 0) (Get-Tail $m)
    $b = $res['badprice']
    Assert 'a price that is not a number is reported, not shown as prices that are not published' ($b.Text -match [regex]::Escape('API Management prices could not be read (the price list is not in the expected form: ') -and $b.Text -match 'a retailPrice is not a number' -and $b.Text -notmatch 'monthly list price, one unit at 730 hours, from' -and $b.Text -match 'The BasicV2 price in eastus2 could not be read') (Get-Tail $b)
    foreach ($id in 'offhost', 'plainhttp') {
        $o = $res[$id]
        $away = @($o.Curl | Where-Object { $_ -notlike 'https://prices.azure.com/*' -and $_ -notlike 'https://prices.azure.com:443/*' -and $_ -notlike 'https://management.azure.com/*' })
        Assert "${id}: a next page that is not on https://prices.azure.com is not read, and the region prompt says why" (-not $away.Count -and (@(Get-PriceCalls $o)).Count -eq 1 -and $o.Text -match [regex]::Escape('API Management prices could not be read (the next page of the price list is not on https://prices.azure.com)')) ('read: ' + ($o.Curl -join ' ; ') + ' ' + (Get-Tail $o))
    }
    $q = $res['parity']
    $psParity = @(Get-PowerShellTableRows 'locations-parity.json' 'prices-parity.json')
    $bashParity = @(Get-TableRows $q)
    $gap = Compare-Rows $bashParity $psParity
    Assert "$($parityRows.Count) prices in $($parityLocations.Count) regions, $halfCent of them half-cent months, ten written with trailing zeros, an exponent, 16 or 17 significant digits or above 10,000, four of them a hair from a half-cent month, are priced and ordered as Install-ClaudeGateway.ps1 prices and orders them on PowerShell 7" ($psParity.Count -ge 50 -and -not $gap) "$($bashParity.Count) bash rows, $($psParity.Count) PowerShell rows; $gap"

    # -------------------------------------------------------------- unattended
    $y = $res['yes']
    Assert '--yes: no region table and no tier list' ($y.Text -notmatch 'Region \(number or name\)' -and $y.Text -notmatch 'monthly list price, one unit at 730 hours, from' -and $y.Text -notmatch 'Monthly list price in ' -and -not @($y.Az | Where-Object { $_ -like 'account list-locations*' }).Count) (Get-Tail $y)
    Assert '--yes: the summary still prices the choice' ($y.Text -match 'PremiumV2 in westus3 is USD 2,628/month at list price' -and (@(Get-PriceCalls $y)).Count -eq 1) (Get-Tail $y)

    # -------------------------------------------------------------- jq 1.7.0
    $j = $res['jq-1.7']
    Assert 'jq 1.7.0: the preflight says a price written with 17 significant digits can be a cent off and names jq 1.7.1, and the install goes on' ($j.Text -match [regex]::Escape('jq 1.7.0: a price written with 17 significant digits can be a cent off; jq 1.7.1 or later matches the PowerShell installer') -and $j.Text -match 'BasicV2 in westus3 is USD 139/month at list price') (Get-Tail $j)
    $warned = @('jq-1.7.1', 'yes' | Where-Object { $res[$_].Text -match 'jq 1\.7\.0:' })
    Assert 'jq 1.7.1, and the jq on this machine: no such warning' (-not $warned.Count) ($warned -join ', ')

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
    $offerAt = Get-Index $a $offerText
    $stepAt = Get-Index $a '3\. Close the direct-access bypass'
    Assert 'the offer comes after the numbered next steps' ($stepAt -ge 0 -and $offerAt -gt $stepAt) "offer=$offerAt step=$stepAt"
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
    if ($systemPwsh) { Write-Host "  [SKIP] without PowerShell 7: a real pwsh at $systemPwsh is on /usr/bin:/bin, so no run can lack it." -ForegroundColor Yellow }
    else { Assert 'without PowerShell 7 there is no offer, and the step says it needs PowerShell 7' ($np.ExitCode -eq 0 -and $np.Text -notmatch 'Set up a FinOps tool now' -and $np.Text -match [regex]::Escape('Choose optional FinOps tooling (needs PowerShell 7): pwsh -File scripts/Select-ClaudeFinOpsTooling.ps1 -Region eastus2')) (Get-Tail $np) }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The macOS/Linux installer prices its choices, records them and offers the FinOps tool.' -ForegroundColor Green
exit 0
