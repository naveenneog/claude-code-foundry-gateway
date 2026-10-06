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
        'scripts\Test-ClaudeLiveContentSafety.ps1',
        'tests\Test-ContentSafetyPolicy.ps1',
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

$fixture = Copy-P102Fixture 'harm-slice'
$helperPath = Join-Path $fixture 'scripts\ClaudeContentSafety.ps1'
(Get-Content $helperPath -Raw).Replace('harmful|violence|self[- ]?harm|sexual|hate', 'violence|self[- ]?harm|sexual|hate') | Set-Content -LiteralPath $helperPath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'harmful user string returns Anthropic-style 403'
Assert 'breaking harm detection fails the blocking detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$fixture = Copy-P102Fixture 'teardown'
$livePath = Join-Path $fixture 'scripts\Test-ClaudeLiveContentSafety.ps1'
(Get-Content $livePath -Raw).Replace('createdResourceGroup', 'unsafeResourceGroup') | Set-Content -LiteralPath $livePath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyLiveScript.ps1' $fixture 'teardown refuses to delete a group it did not create'
Assert 'removing the teardown ownership guard fails the live-script detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

if ($script:failures) { throw "$($script:failures) of $($script:assertions) assertions failed" }
Write-Host "P102 negative checks passed ($script:assertions assertions)."
