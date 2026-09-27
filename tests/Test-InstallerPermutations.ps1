# P72: the installer's summary, which is the approval (ADR-0032), under -WhatIf -Yes over tier,
# entitlement store, developer sign-in and Claude Desktop sign-in, on PowerShell 7 and Windows
# PowerShell 5.1. Offline: tests/InstallerPermutationDriver.ps1 stubs the Azure CLI, the Retail
# Prices API and the reachability probe in process, so a case takes under a second instead of the
# 18-20 s measured live. -Live runs the same cases read-only against the signed-in subscription.
param([switch]$Live, [string]$FoundryAccount, [string]$FoundryResourceGroup, [int]$Parallel = 4)
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
    if (-not $FoundryAccount -or -not $FoundryResourceGroup) { throw '-Live needs -FoundryAccount and -FoundryResourceGroup: a Foundry account with a Claude deployment in the signed-in subscription.' }
    $gateway = az apim list --query '[0].{name:name, rg:resourceGroup, sku:sku.name}' -o json | ConvertFrom-Json
    $placement.FoundryAccount = $FoundryAccount; $placement.FoundryResourceGroup = $FoundryResourceGroup; $placement.ResourceGroup = 'rg-p72-whatif'
    $placement.Location = [string](az cognitiveservices account show -g $FoundryResourceGroup -n $FoundryAccount --query location -o tsv)
    $reuse = [ordered]@{ FoundryAccount = $FoundryAccount; FoundryResourceGroup = $FoundryResourceGroup; ResourceGroup = [string]$gateway.rg; ExistingApimName = [string]$gateway.name }
    $reusedName = [string]$gateway.name; $reusedSku = [string]$gateway.sku
}

# The pairs design: every developer sign-in with every Desktop sign-in (the defect this packet
# found is that pair), and tier and store rotated so that every pair of levels of any two of the
# four factors occurs. The coverage is checked below, so an edit cannot drop a pair unnoticed.
$tiers = @('BasicV2', 'StandardV2', 'PremiumV2')
$stores = @('named-value', 'projection')
$auths = @('', 'interactive', 'device', 'helper')
$desktops = @('', 'helper-script', 'external-idp-browser', 'external-idp-broker')
$cases = [System.Collections.Generic.List[object]]::new()
for ($a = 0; $a -lt 4; $a++) {
    for ($d = 0; $d -lt 4; $d++) {
        $p = [ordered]@{} + $placement
        $f = [ordered]@{ tier = $tiers[($a + $d) % 3]; store = $stores[($a + [math]::Floor($d / 2)) % 2]; auth = $auths[$a]; desktop = $desktops[$d]; bearer = 'id_token' }
        $p.Sku = $f.tier
        $p.EntitlementStore = $f.store
        if ($f.store -eq 'projection') { $p.DeployProjection = $true }
        if ($f.auth) { $p.AuthMode = $f.auth }
        if ($f.desktop) { $p.DesktopSignInKind = $f.desktop }
        if ($f.desktop -like 'external-idp-*') {
            $p.DesktopEntraClientId = $clientId
            if ($a % 2) { $f.bearer = 'access_token'; $p.DesktopBearerTokenType = 'access_token'; $p.DesktopEntraScopes = $scope; $p.DesktopEntraAudience = $audience }
        }
        $cases.Add([pscustomobject]@{ id = "pair-$a$d"; factors = $f; params = $p })
    }
}
$pairs = @{}
foreach ($c in $cases) {
    $v = @("tier=$($c.factors.tier)", "store=$($c.factors.store)", "auth=$($c.factors.auth)", "desktop=$($c.factors.desktop)")
    for ($i = 0; $i -lt 4; $i++) { for ($j = $i + 1; $j -lt 4; $j++) { $pairs["$($v[$i])|$($v[$j])"] = $true } }
}
$expectedPairs = 3 * 2 + 3 * 4 + 3 * 4 + 2 * 4 + 2 * 4 + 4 * 4
Assert "the design covers every pair of levels of any two factors ($expectedPairs pairs in $($cases.Count) cases)" ($pairs.Count -eq $expectedPairs) "$($pairs.Count) of $expectedPairs"

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

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('installer-permutations-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $installer = Join-Path $root 'Install-ClaudeGateway.ps1'
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
            if (-not $r.reachedSummary -or $r.failure) { Add-Bad 'reaches the summary and stops at -WhatIf' $c.id $r.failure; continue }
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
            if ($r.reachedSummary -or -not $r.failure) { Add-Bad 'each refusal stops before the summary' $c.id 'reached the summary'; continue }
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
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The installer summary holds across the permutations.' -ForegroundColor Green
exit 0
