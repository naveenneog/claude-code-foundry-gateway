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
    )) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $fixture $file) }
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
@'
<fragment>
    <choose>
        <when condition='@("{{content-safety-mode}}" != "off")'>
            <set-variable name="contentSafetyStartedAt" value="@(DateTime.UtcNow)" />
            <set-variable name="contentSafetyThreshold" value='@(int.Parse("{{content-safety-threshold}}"))' />
            <set-variable name="contentSafetySlice" value='@{ return new JObject(new JProperty("userPrompt", ""), new JProperty("documents", new JArray()), new JProperty("analyzeText", ""), new JProperty("truncated", false), new JProperty("emptyTextSlice", true), new JProperty("fabricatedHistoryLimit", false)).ToString(Newtonsoft.Json.Formatting.None); }' />
            <set-variable name="contentSafetyDecisionJson" value='@{ return new JObject(new JProperty("decision", "pass"), new JProperty("blockedBy", ""), new JProperty("hateSeverity", 0), new JProperty("violenceSeverity", 0), new JProperty("selfHarmSeverity", 0), new JProperty("sexualSeverity", 0), new JProperty("promptShieldUserAttackDetected", false), new JProperty("promptShieldDocumentAttackDetected", false), new JProperty("contentSafetyStatusCode", 0), new JProperty("contentSafetyErrorClass", "")).ToString(Newtonsoft.Json.Formatting.None); }' />
            <set-variable name="contentSafetyDecision" value='@(JObject.Parse((string)context.Variables["contentSafetyDecisionJson"])["decision"].ToString())' />
            <trace source="claude-content-safety" severity="information">
                <message>content safety request screening</message>
                <metadata name="mode" value="{{content-safety-mode}}" />
                <metadata name="decision" value='@(JObject.Parse((string)context.Variables["contentSafetyDecisionJson"])["decision"].ToString())' />
                <metadata name="blockedBy" value='@(JObject.Parse((string)context.Variables["contentSafetyDecisionJson"])["blockedBy"].ToString())' />
                <metadata name="threshold" value='@(((int)context.Variables["contentSafetyThreshold"]).ToString())' />
                <metadata name="truncated" value="False" />
                <metadata name="hateSeverity" value="0" />
                <metadata name="violenceSeverity" value="0" />
                <metadata name="selfHarmSeverity" value="0" />
                <metadata name="sexualSeverity" value="0" />
                <metadata name="promptShieldUserAttackDetected" value="False" />
                <metadata name="promptShieldDocumentAttackDetected" value="False" />
                <metadata name="contentSafetyStatusCode" value="0" />
                <metadata name="contentSafetyElapsedMs" value="0" />
                <metadata name="contentSafetyErrorClass" value="" />
            </trace>
        </when>
    </choose>
</fragment>
'@ | Set-Content -LiteralPath $fragmentPath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'ExpressionValueValidationFailure|block mode calls Prompt Shields and analyze once for benign strings'
Assert 'restoring the stub empty slice fails the fragment harness' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$fixture = Copy-P102Fixture 'severity-threshold'
$fragmentPath = Join-Path $fixture 'infra\content-safety-screening.xml'
(Get-Content $fragmentPath -Raw).Replace('&gt;= threshold', '&gt;= threshold + 100') | Set-Content -LiteralPath $fragmentPath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'harmful user string returns Anthropic-style 403'
Assert 'breaking severity detection fails the blocking detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$fixture = Copy-P102Fixture 'teardown'
$livePath = Join-Path $fixture 'scripts\Test-ClaudeLiveContentSafety.ps1'
(Get-Content $livePath -Raw).Replace('foreach ($groupId in @($Receipt.createdGroups)) { if ($groupId) { Invoke-TeardownAz ''tier group'' @(''ad'',''group'',''delete'',''--group'',[string]$groupId) "az ad group delete --group $groupId" $left | Out-Null } }', '') | Set-Content -LiteralPath $livePath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyLiveScript.ps1' $fixture 'teardown-only deletes recorded groups even when the resource group was never created'
Assert 'removing group cleanup fails the live-script detector' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

$savedAssertions = $script:assertions
$savedFailures = $script:failures
. (Join-Path $root 'tests\ContentSafetyPolicyHarness.ps1')
$script:assertions = $savedAssertions
$script:failures = $savedFailures
$delegateFragment = @'
<fragment>
  <set-variable name="bad" value='@{ Func&lt;string,string&gt; newest = s =&gt; s; Action&lt;JToken,System.Text.StringBuilder&gt; addText = (token, output) =&gt; {}; return ""; }' />
</fragment>
'@
$allowed = Test-ContentSafetyPolicyAllowedTypes -FragmentText $delegateFragment
Assert 'allowed-type detector rejects System.Action and System.Func delegate variables' (-not $allowed.Pass -and ($allowed.Violations -join '; ') -match 'System\.Action' -and ($allowed.Violations -join '; ') -match 'System\.Func') (($allowed.Violations -join '; '))

$fixture = Copy-P102Fixture 'empty-trace-metadata'
$fragmentPath = Join-Path $fixture 'infra\content-safety-screening.xml'
(Get-Content $fragmentPath -Raw).Replace('new JProperty("contentSafetyErrorClass", "none")', 'new JProperty("contentSafetyErrorClass", "")') | Set-Content -LiteralPath $fragmentPath -Encoding UTF8
$r = Invoke-ExpectFailure 'tests\Test-ContentSafetyPolicy.ps1' $fixture 'ExpressionValueValidationFailure at trace'
Assert 'empty trace metadata value fails the fragment harness' ($r.Failed -and $r.Matched) $r.Output
Remove-Item -LiteralPath $fixture -Recurse -Force

if ($script:failures) { throw "$($script:failures) of $($script:assertions) assertions failed" }
Write-Host "P102 negative checks passed ($script:assertions assertions)."
