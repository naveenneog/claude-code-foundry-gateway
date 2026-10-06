param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name,$Condition,$Detail='') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Copy-P102Fixture($Name) {
    $fixture = Join-Path $root ".p102-negative-$Name"
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($dir in 'infra','scripts','tests') { New-Item -ItemType Directory -Path (Join-Path $fixture $dir) -Force | Out-Null }
    foreach ($file in @(
        'infra\policy.xml',
        'infra\content-safety-screening.xml',
        'infra\main.bicep',
        'infra\content-safety.bicep',
        'scripts\ClaudeContentSafety.ps1',
        'scripts\ClaudeLiveHarness.ps1',
        'scripts\Test-ClaudeLiveProjection.ps1',
        'scripts\Test-ClaudeLiveContentSafety.ps1',
        'tests\Test-ContentSafetyPolicy.ps1',
        'tests\ContentSafetyPolicyHarness.ps1',
        'tests\Test-ContentSafetyLiveScript.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $fixture $file)
    }
    $fixture
}
function Invoke-ExpectFailure([string]$Script, [string]$Fixture, [string]$Pattern) {
    $output = & pwsh -NoProfile -File (Join-Path $Fixture $Script) -RepositoryRoot $Fixture 2>&1 | Out-String
    [pscustomobject]@{ Failed = ($LASTEXITCODE -ne 0 -or $output -match 'assertions failed'); Output = $output; Matched = ($output -match $Pattern) }
}

Write-Host 'P102 negative checks'
$fixture = Copy-P102Fixture 'policy-include'
$policyPath = Join-Path $fixture 'infra\policy.xml'
(Get-Content $policyPath -Raw).Replace('        <include-fragment fragment-id="content-safety-screening" />', '') | Set-Content -LiteralPath $policyPath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'policy includes the content-safety-screening fragment'
Assert 'removing the APIM include fails the policy detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$fixture = Copy-P102Fixture 'stub-slice'
$fragmentPath = Join-Path $fixture 'infra\content-safety-screening.xml'
$fragmentText = Get-Content $fragmentPath -Raw
$fragmentText = [regex]::Replace($fragmentText, 'var sys = new System\.Text\.StringBuilder\(\);[\s\S]*?return new JObject\(', 'var newestUserSlice = ""; var sysSlice = ""; var toolSlice = ""; var truncated = false; return new JObject(', 1)
$fragmentText = [regex]::Replace($fragmentText, 'new JProperty\("userPrompt", userPrompt\),[\s\S]*?new JProperty\("fabricatedHistoryLimit", fabricated\)', 'new JProperty("userPrompt", newestUserSlice), new JProperty("documents", new JArray(toolSlice)), new JProperty("analyzeText", sysSlice + newestUserSlice + toolSlice), new JProperty("truncated", truncated), new JProperty("emptyTextSlice", String.IsNullOrEmpty(sysSlice + newestUserSlice + toolSlice))', 1)
Set-Content -LiteralPath $fragmentPath -Value $fragmentText -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'block mode calls Prompt Shields and analyze once for benign strings'
Assert 'restoring the stub empty slice fails the fragment harness' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$fixture = Copy-P102Fixture 'harm-slice'
$helperPath = Join-Path $fixture 'scripts\ClaudeContentSafety.ps1'
(Get-Content $helperPath -Raw).Replace('harmful|violence|self[- ]?harm|sexual|hate', 'violence|self[- ]?harm|sexual|hate') | Set-Content -LiteralPath $helperPath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'harmful user string returns Anthropic-style 403'
Assert 'breaking harm detection fails the blocking detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$fixture = Copy-P102Fixture 'teardown'
$livePath = Join-Path $fixture 'scripts\Test-ClaudeLiveContentSafety.ps1'
(Get-Content $livePath -Raw).Replace('foreach ($groupId in @($Receipt.createdGroups)) { if ($groupId) { Invoke-TeardownAz ''tier group'' @(''ad'',''group'',''delete'',''--group'',[string]$groupId) "az ad group delete --group $groupId" $left | Out-Null } }', '') | Set-Content -LiteralPath $livePath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyLiveScript.ps1' $fixture 'teardown-only deletes recorded groups even when the resource group was never created'
Assert 'removing group cleanup fails the live-script detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

if ($script:failures) { throw "$($script:failures) of $($script:assertions) assertions failed" }
Write-Host "P102 negative checks passed ($script:assertions assertions)."
