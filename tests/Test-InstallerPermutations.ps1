# P72: the installer's summary, which is the approval (ADR-0032), under -WhatIf -Yes over tier,
# entitlement store, developer sign-in and Claude Desktop sign-in, on PowerShell 7 and Windows
# PowerShell 5.1. Offline: tests/InstallerPermutationDriver.ps1 stubs the Azure CLI, the Retail
# Prices API and the reachability probe in process, so a case takes under a second instead of the
# 18-20 s measured live. -Live runs the same cases read-only against the signed-in subscription.
param([switch]$Live, [string]$FoundryAccount, [string]$FoundryResourceGroup, [string]$ReuseGateway, [string]$ReuseResourceGroup, [int]$Parallel = 4, [switch]$Pairs)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host "Installer - summary over tier, store, developer sign-in and Desktop sign-in$(if ($Live) { ' (live, read-only)' })" -ForegroundColor Cyan

$clientId = '11111111-2222-4333-8444-555555555555'
$audience = 'api://p72-gateway'
$scope = 'api://p72-gateway/user_impersonation'
$placement = [ordered]@{ FoundryAccount = 'ai-p72'; FoundryResourceGroup = 'rg-ai-p72'; ResourceGroup = 'rg-p72'; Location = 'eastus2'; NamePrefix = 'p72perm'; PublisherEmail = 'ops@contoso.com' }
$reuse = [ordered]@{ FoundryAccount = 'ai-p72'; FoundryResourceGroup = 'rg-ai-p72'; ResourceGroup = 'rg-p72live'; ExistingApimName = 'apim-p72live' }
$reusedName = 'apim-p72live'; $reusedSku = 'StandardV2'
if ($Live) {
    if (-not $FoundryAccount -or -not $FoundryResourceGroup -or -not $ReuseGateway -or -not $ReuseResourceGroup) { throw '-Live needs -FoundryAccount and -FoundryResourceGroup (a Foundry account with a Claude deployment) and -ReuseGateway and -ReuseResourceGroup (a v2 gateway to read for the reuse case), in the signed-in subscription.' }
    $placement.FoundryAccount = $FoundryAccount; $placement.FoundryResourceGroup = $FoundryResourceGroup; $placement.ResourceGroup = 'rg-p72-whatif'
    $placement.Location = [string](az cognitiveservices account show -g $FoundryResourceGroup -n $FoundryAccount --query location -o tsv)
    $reuse = [ordered]@{ FoundryAccount = $FoundryAccount; FoundryResourceGroup = $FoundryResourceGroup; ResourceGroup = $ReuseResourceGroup; ExistingApimName = $ReuseGateway }
    $reusedName = $ReuseGateway; $reusedSku = [string](az apim show -g $ReuseResourceGroup -n $ReuseGateway --query sku.name -o tsv)
}

# Offline, every combination of tier x store x developer sign-in x Desktop sign-in (96 cases, about
# 40 s on both shells). Live, or with -Pairs, the pairs design: every developer sign-in with every
# Desktop sign-in (the defect this packet found is that pair), and tier and store rotated so that
# every pair of levels of any two of the four factors occurs, in 16 cases of about 20 s each live.
# The coverage of either design is checked below, so an edit cannot drop a case unnoticed.
if ($Live) { $Pairs = [switch]$true }
$tiers = @('BasicV2', 'StandardV2', 'PremiumV2')
$stores = @('named-value', 'projection')
$auths = @('', 'interactive', 'device', 'helper')
$desktops = @('', 'helper-script', 'external-idp-browser', 'external-idp-broker')
$cases = [System.Collections.Generic.List[object]]::new()
for ($a = 0; $a -lt 4; $a++) {
    for ($d = 0; $d -lt 4; $d++) {
        $levels = [System.Collections.Generic.List[object]]::new()
        if ($Pairs) { $levels.Add(@($tiers[($a + $d) % 3], $stores[($a + [math]::Floor($d / 2)) % 2])) }
        else { foreach ($t in $tiers) { foreach ($s in $stores) { $levels.Add(@($t, $s)) } } }
        foreach ($level in $levels) {
            $p = [ordered]@{} + $placement
            $f = [ordered]@{ tier = $level[0]; store = $level[1]; auth = $auths[$a]; desktop = $desktops[$d]; bearer = 'id_token' }
            $p.Sku = $f.tier
            $p.EntitlementStore = $f.store
            if ($f.store -eq 'projection') { $p.DeployProjection = $true }
            if ($f.auth) { $p.AuthMode = $f.auth }
            if ($f.desktop) { $p.DesktopSignInKind = $f.desktop }
            if ($f.desktop -like 'external-idp-*') {
                $p.DesktopEntraClientId = $clientId
                if ($a % 2) { $f.bearer = 'access_token'; $p.DesktopBearerTokenType = 'access_token'; $p.DesktopEntraScopes = $scope; $p.DesktopEntraAudience = $audience }
            }
            $cases.Add([pscustomobject]@{ id = "case-$a$d-$($f.tier)-$($f.store)"; factors = $f; params = $p })
        }
    }
}
$covered = @{}
foreach ($c in $cases) {
    $v = @("tier=$($c.factors.tier)", "store=$($c.factors.store)", "auth=$($c.factors.auth)", "desktop=$($c.factors.desktop)")
    for ($i = 0; $i -lt 4; $i++) { for ($j = $i + 1; $j -lt 4; $j++) { $covered["$($v[$i])|$($v[$j])"] = $true } }
}
$expectedPairs = 3 * 2 + 3 * 4 + 3 * 4 + 2 * 4 + 2 * 4 + 4 * 4
if ($Pairs) { Assert "the design covers every pair of levels of any two factors ($expectedPairs pairs in $($cases.Count) cases)" ($covered.Count -eq $expectedPairs) "$($covered.Count) of $expectedPairs" }
else { Assert "the design is every combination of the four factors ($($cases.Count) distinct cases)" ($cases.Count -eq 96 -and @($cases | ForEach-Object id | Sort-Object -Unique).Count -eq 96 -and $covered.Count -eq $expectedPairs) "$($cases.Count) cases" }

# Refusals: each stops before the summary, with a reason that names what to pass.
function New-RefusalCase([string]$Id, [hashtable]$Extra, [string]$Expect) {
    $p = [ordered]@{} + $placement
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    [pscustomobject]@{ id = $Id; factors = $null; params = $p; expect = $Expect }
}
$refusals = @(
    New-RefusalCase 'refuse-projection-without-deployer' @{ Sku = 'StandardV2'; EntitlementStore = 'projection' } 'unless -DeployProjection'
    New-RefusalCase 'refuse-basic-private-resolver' @{ Sku = 'BasicV2'; EntitlementStore = 'projection'; DeployProjection = $true; ResolverInboundAccess = 'private' } 'BasicV2 cannot use a private resolver'
    New-RefusalCase 'refuse-external-without-client-with-authmode' @{ Sku = 'BasicV2'; EntitlementStore = 'named-value'; AuthMode = 'device'; DesktopSignInKind = 'external-idp-browser' } '-DesktopEntraClientId'
    New-RefusalCase 'refuse-external-without-client' @{ Sku = 'BasicV2'; EntitlementStore = 'named-value'; DesktopSignInKind = 'external-idp-broker' } '-DesktopEntraClientId'
    New-RefusalCase 'refuse-client-not-a-guid' @{ Sku = 'BasicV2'; EntitlementStore = 'named-value'; AuthMode = 'interactive'; DesktopSignInKind = 'external-idp-browser'; DesktopEntraClientId = 'desktop-app' } '-DesktopEntraClientId'
    New-RefusalCase 'refuse-access-token-without-scope' @{ Sku = 'BasicV2'; EntitlementStore = 'named-value'; AuthMode = 'helper'; DesktopSignInKind = 'external-idp-browser'; DesktopEntraClientId = $clientId; DesktopBearerTokenType = 'access_token' } '-DesktopEntraScopes'
)
$reuseParams = [ordered]@{} + $reuse
$reuseParams.EntitlementStore = 'named-value'; $reuseParams.AuthMode = 'device'; $reuseParams.DesktopSignInKind = 'external-idp-broker'; $reuseParams.DesktopEntraClientId = $clientId
$reuseCase = [pscustomobject]@{ id = 'reuse-recorded-gateway'; factors = $null; params = $reuseParams }
$all = @($cases) + @($refusals) + @($reuseCase)

# A checkout keeps one gateway's saved record (onboarding\claude-gateway.json, ignored by Git), and the
# installer compares it with the chosen gateway before its first question (P79). The cases run a copy of
# the installer's inputs without saved records, so the machine's own record cannot change their result.
$installerInputs = @('analytics', 'cli', 'config', 'guide', 'infra', 'resolver', 'scripts', 'service', 'sync')
function Copy-InstallerCheckout([string]$From, [string]$To) {
    New-Item -ItemType Directory -Path (Join-Path $To 'onboarding') -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        if (-not $item.PSIsContainer) { Copy-Item -LiteralPath $item.FullName -Destination $To }
        elseif ($item.Name -in $installerInputs) { Copy-Item -LiteralPath $item.FullName -Destination $To -Recurse }
        elseif ($item.Name -eq 'onboarding') {
            foreach ($file in Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force) {
                if ($file.Name -like 'claude-gateway*.json') { continue }
                $target = Join-Path (Join-Path $To 'onboarding') $file.FullName.Substring($item.FullName.Length + 1)
                New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
        }
    }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('installer-permutations-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    # The checkout's own record is read before anything is copied, so a copy that moves or deletes it is caught.
    $ownRecord = Join-Path $root 'onboarding\claude-gateway.json'
    $ownRecordHash = if (Test-Path -LiteralPath $ownRecord) { (Get-FileHash -LiteralPath $ownRecord).Hash }
    $probeFrom = Join-Path $scratch 'probe-from'
    $probeTo = Join-Path $scratch 'probe-to'
    foreach ($dir in 'onboarding\profiles\standard', 'onboarding\support', 'scripts', 'docs') { New-Item -ItemType Directory -Path (Join-Path $probeFrom $dir) -Force | Out-Null }
    foreach ($file in 'Install-ClaudeGateway.ps1', 'scripts\A.ps1', 'onboarding\README.md', 'onboarding\profiles\standard\managed-settings.json', 'onboarding\claude-gateway.json', 'onboarding\claude-gateway.rg-a-apim-a.json', 'onboarding\support\claude-gateway.json', 'docs\guide.png') {
        [IO.File]::WriteAllText((Join-Path $probeFrom $file), $file)
    }
    Copy-InstallerCheckout $probeFrom $probeTo
    $copied = @(Get-ChildItem -LiteralPath $probeTo -Recurse -File | ForEach-Object { $_.FullName.Substring($probeTo.Length + 1) } | Sort-Object)
    $wanted = @('Install-ClaudeGateway.ps1', 'onboarding\profiles\standard\managed-settings.json', 'onboarding\README.md', 'scripts\A.ps1') | Sort-Object
    Assert 'the installer inputs are copied without any saved gateway record' (($copied -join '|') -eq ($wanted -join '|')) "copied: $($copied -join ', ')"
    $sourceRecords = @('onboarding\claude-gateway.json', 'onboarding\claude-gateway.rg-a-apim-a.json', 'onboarding\support\claude-gateway.json')
    $keptRecords = @($sourceRecords | Where-Object { (Test-Path -LiteralPath (Join-Path $probeFrom $_)) -and [IO.File]::ReadAllText((Join-Path $probeFrom $_)) -ceq $_ })
    Assert 'the copy leaves the saved records it skips in place, unchanged' ($keptRecords.Count -eq $sourceRecords.Count) "unchanged: $($keptRecords -join ', ')"

    $checkout = Join-Path $scratch 'checkout'
    Copy-InstallerCheckout $root $checkout
    $installer = Join-Path $checkout 'Install-ClaudeGateway.ps1'
    Assert 'the cases run a copy of the installer, not the checkout itself' ($installer.StartsWith($scratch) -and -not @(Get-ChildItem -LiteralPath (Join-Path $checkout 'onboarding') -Recurse -File -Filter 'claude-gateway*.json').Count)
    $driver = Join-Path $PSScriptRoot 'InstallerPermutationDriver.ps1'
    $shells = [ordered]@{ '7' = (Get-Process -Id $PID).Path }
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($env:SystemRoot -and (Test-Path -LiteralPath $ps51)) { $shells['5.1'] = $ps51 }
    else { Write-Host '  Windows PowerShell 5.1 is not on this machine; PowerShell 7 only.' -ForegroundColor Yellow }

    # Offline: one process per shell runs every case. Live: the cases are split across processes,
    # since each live case waits about 20 s on the Azure CLI.
    $chunks = if ($Live) { [math]::Max(1, $Parallel) } else { 1 }
    $jobs = foreach ($shell in $shells.Keys) {
        for ($k = 0; $k -lt $chunks; $k++) {
            $slice = @(for ($i = $k; $i -lt $all.Count; $i += $chunks) { $all[$i] | Select-Object id, params })
            $casesPath = Join-Path $scratch "cases-$shell-$k.json"
            ConvertTo-Json -InputObject $slice -Depth 6 | Set-Content -LiteralPath $casesPath -Encoding UTF8
            $resultsPath = Join-Path $scratch "results-$shell-$k.jsonl"
            $argList = @('-NoProfile', '-NonInteractive', '-File', $driver, '-Installer', $installer, '-CasesPath', $casesPath, '-ResultsPath', $resultsPath)
            if ($Live) { $argList += '-Live' }
            [pscustomobject]@{ Shell = $shell; Results = $resultsPath; Process = (Start-Process -FilePath $shells[$shell] -ArgumentList $argList -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $scratch "out-$shell-$k.txt") -RedirectStandardError (Join-Path $scratch "err-$shell-$k.txt")) }
        }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $limit = if ($Live) { 1800 } else { 300 }
    foreach ($j in $jobs) {
        $left = [int][math]::Max(1000, $limit * 1000 - $clock.ElapsedMilliseconds)
        if (-not $j.Process.WaitForExit($left)) { try { $j.Process.Kill() } catch { } }
    }
    $results = @{}
    foreach ($shell in $shells.Keys) {
        $results[$shell] = @{}
        foreach ($j in @($jobs | Where-Object Shell -eq $shell)) {
            if (-not (Test-Path -LiteralPath $j.Results)) { continue }
            foreach ($line in (Get-Content -LiteralPath $j.Results)) { if ($line.Trim()) { $r = $line | ConvertFrom-Json; $results[$shell][$r.id] = $r } }
        }
        $secs = @($results[$shell].Values | ForEach-Object { [double]$_.seconds })
        $total = if ($secs.Count) { ($secs | Measure-Object -Sum).Sum } else { 0 }
        Write-Host ("  PowerShell {0}: {1} of {2} cases ran, {3:N1} s in the installer, {4:N1} s wall" -f $shell, $results[$shell].Count, $all.Count, $total, $clock.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        Assert "PowerShell ${shell}: every case ran" ($results[$shell].Count -eq $all.Count) ("missing: " + ((@($all | Where-Object { -not $results[$shell].ContainsKey($_.id) } | ForEach-Object id)) -join ', ') + ' ' + ((Get-Content -LiteralPath (Join-Path $scratch "err-$shell-0.txt") -ErrorAction SilentlyContinue) -join ' '))
    }

    function Get-Row($r, [string]$Name) { if ($r -and $r.rows -and ($r.rows.PSObject.Properties.Name -contains $Name)) { [string]$r.rows.$Name } else { $null } }
    foreach ($shell in $shells.Keys) {
        $bad = [ordered]@{}
        function Add-Bad([string]$What, [string]$Id, [string]$Detail) { if (-not $bad.Contains($What)) { $bad[$What] = [System.Collections.Generic.List[string]]::new() }; $bad[$What].Add("$Id ($Detail)") }
        foreach ($c in $cases) {
            $r = $results[$shell][$c.id]
            if (-not $r) { continue }
            $f = $c.factors
            if (-not $r.reachedSummary -or -not $r.sawSummary -or $r.failure) { Add-Bad 'reaches the summary and stops at -WhatIf' $c.id $r.failure; continue }
            if (@($r.unexpected).Count) { Add-Bad 'makes only the Azure CLI reads the stub knows' $c.id (@($r.unexpected) -join '; ') }
            if ((Get-Row $r 'API Management') -notmatch ('^apim-p72perm\s+\(' + $f.tier + '\)\s+new$')) { Add-Bad 'the summary names the new gateway and its tier' $c.id (Get-Row $r 'API Management') }
            $resolver = if ($f.tier -eq 'BasicV2') { 'public' } else { 'private' }
            $store = if ($f.store -eq 'projection') { "projection, resolver $resolver" } else { 'named-value' }
            if ((Get-Row $r 'Entitlement store') -ne $store) { Add-Bad 'the summary names the entitlement store' $c.id "want '$store', got '$(Get-Row $r 'Entitlement store')'" }
            $auth = if ($f.auth) { $f.auth } else { 'interactive' }
            if ((Get-Row $r 'Developer sign-in') -ne $auth) { Add-Bad 'the summary names the developer sign-in' $c.id "want '$auth', got '$(Get-Row $r 'Developer sign-in')'" }
            $desktopRow = Get-Row $r 'Claude Desktop sign-in'
            if ($f.desktop -like 'external-idp-*') {
                $want = "$($f.desktop), app $clientId, $($f.bearer)"
                if ($desktopRow -ne $want) { Add-Bad 'the summary names the Claude Desktop sign-in and its app' $c.id "want '$want', got '$desktopRow'" }
                $wantAudience = if ($f.bearer -eq 'access_token') { $audience } else { $clientId }
                if ($r.audience -ne $wantAudience) { Add-Bad 'an external IdP Desktop sign-in derives the gateway audience, with or without -AuthMode' $c.id "auth '$($f.auth)': want '$wantAudience', got '$($r.audience)'" }
            }
            else {
                if ($desktopRow -notmatch '^helper-script\b') { Add-Bad 'the summary names the Claude Desktop sign-in and its app' $c.id "want 'helper-script', got '$desktopRow'" }
                if ($r.audience) { Add-Bad 'the helper script adds no gateway audience' $c.id $r.audience }
            }
            if ((Get-Row $r 'Developer address') -ne 'azure, https://apim-p72perm.azure-api.net/claude') { Add-Bad 'the summary names the developer address with the gateway''s hostname' $c.id (Get-Row $r 'Developer address') }
            if ($r.addressLine -notmatch 'https://apim-p72perm\.azure-api\.net/claude') { Add-Bad 'the address question shows the gateway''s own hostname' $c.id $r.addressLine }
            foreach ($row in @(@('Revocation window', '60 minutes'), @('Team budget behaviour', 'report'), @('Developers with no team', 'allow'))) {
                if ((Get-Row $r $row[0]) -ne $row[1]) { Add-Bad "the summary names the $($row[0].ToLower())" $c.id "want '$($row[1])', got '$(Get-Row $r $row[0])'" }
            }
        }
        foreach ($c in $refusals) {
            $r = $results[$shell][$c.id]
            if (-not $r) { continue }
            # Before the summary means no Summary heading at all, not only no -WhatIf stop after it.
            if ($r.sawSummary -or $r.reachedSummary -or -not $r.failure) { Add-Bad 'each refusal stops before the summary' $c.id $(if ($r.sawSummary) { 'printed the summary' } else { 'reached the -WhatIf stop' }); continue }
            if ($r.failure -notmatch [regex]::Escape($c.expect)) { Add-Bad 'each refusal names what to pass' $c.id "want '$($c.expect)', got '$($r.failure)'" }
            if ($r.failure -notmatch 'Nothing was created') { Add-Bad 'each refusal says that nothing was created' $c.id $r.failure }
        }
        $r = $results[$shell][$reuseCase.id]
        if ($r) {
            # Each check on its own: a chain would report the later ones as passing unevaluated.
            if (-not $r.reachedSummary) { Add-Bad 'a reused gateway reaches the summary' $reuseCase.id $r.failure }
            if ((Get-Row $r 'API Management') -notmatch ('^' + [regex]::Escape($reusedName) + '\s+\(' + $reusedSku + '\)\s+REUSING')) { Add-Bad 'a reused gateway keeps its own tier in the summary' $reuseCase.id (Get-Row $r 'API Management') }
            if ((Get-Row $r 'Developer address') -ne "azure, https://$reusedName.azure-api.net/claude") { Add-Bad 'a reused gateway''s address is its own hostname' $reuseCase.id (Get-Row $r 'Developer address') }
            if ((Get-Row $r 'Claude Desktop sign-in') -ne "external-idp-broker, app $clientId, id_token") { Add-Bad 'a reused gateway keeps the Desktop sign-in chosen with -AuthMode' $reuseCase.id (Get-Row $r 'Claude Desktop sign-in') }
        }
        else { Add-Bad 'a reused gateway reaches the summary' $reuseCase.id 'no result' }
        $names = @('reaches the summary and stops at -WhatIf', 'makes only the Azure CLI reads the stub knows', 'the summary names the new gateway and its tier', 'the summary names the entitlement store', 'the summary names the developer sign-in', 'the summary names the Claude Desktop sign-in and its app', 'an external IdP Desktop sign-in derives the gateway audience, with or without -AuthMode', 'the helper script adds no gateway audience', 'the summary names the developer address with the gateway''s hostname', 'the address question shows the gateway''s own hostname', 'the summary names the revocation window', 'the summary names the team budget behaviour', 'the summary names the developers with no team', 'each refusal stops before the summary', 'each refusal names what to pass', 'each refusal says that nothing was created', 'a reused gateway reaches the summary', 'a reused gateway keeps its own tier in the summary', 'a reused gateway''s address is its own hostname', 'a reused gateway keeps the Desktop sign-in chosen with -AuthMode')
        if ($Live) { $names = @($names | Where-Object { $_ -ne 'makes only the Azure CLI reads the stub knows' }) }
        foreach ($n in $names) {
            $detail = if ($bad.Contains($n)) { "$($bad[$n].Count) case(s): " + (@($bad[$n] | Select-Object -First 3) -join '; ') } else { '' }
            Assert "PowerShell ${shell}: $n" (-not $bad.Contains($n)) $detail
        }
    }

    # The same case gives the same summary on both shells.
    if ($shells.Contains('5.1')) {
        $differ = @(foreach ($c in $all) {
            $a7 = $results['7'][$c.id]; $a5 = $results['5.1'][$c.id]
            if (-not $a7 -or -not $a5) { continue }
            $s7 = ($a7.rows | ConvertTo-Json -Compress) + "|$($a7.reachedSummary)|$($a7.audience)|$($a7.failure)"
            $s5 = ($a5.rows | ConvertTo-Json -Compress) + "|$($a5.reachedSummary)|$($a5.audience)|$($a5.failure)"
            if ($s7 -ne $s5) { $c.id }
        })
        Assert 'PowerShell 7 and Windows PowerShell 5.1 give the same summary, audience and refusal for every case' ($differ.Count -eq 0) ($differ -join ', ')
    }
    $ownRecordKept = if ($ownRecordHash) { (Test-Path -LiteralPath $ownRecord) -and (Get-FileHash -LiteralPath $ownRecord).Hash -eq $ownRecordHash } else { -not (Test-Path -LiteralPath $ownRecord) }
    Assert "the checkout's own saved record is neither changed nor created" $ownRecordKept $ownRecord
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The installer summary holds across the permutations.' -ForegroundColor Green
exit 0
