# P13 - per-group capability scoping.
#
# RED first: written before the implementation.
#
# ADR-0004 sets the rule this asserts: anything that can be enforced at the
# gateway is enforced at the gateway, and everything else is described as a
# management control rather than a security boundary.
#
# So the model allowlist is server-side, in the policy, where a modified client
# cannot reach it. Tabs, permissions, hooks and MCP servers are client-side
# wherever they come from - Anthropic states "a user who can run a modified
# Claude Code binary can bypass any client-side control" - so they ride per-tier
# managed settings and the documentation has to say what they are.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$bicepPath = Join-Path $root 'infra/main.bicep'
$profilePath = Join-Path $root 'scripts/New-ClaudeCodePolicy.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$policy = if (Test-Path $policyPath) { Get-Content $policyPath -Raw } else { '' }
$bicep = if (Test-Path $bicepPath) { Get-Content $bicepPath -Raw } else { '' }

Write-Host ''
Write-Host 'P13 capability scoping - models, enforced at the gateway' -ForegroundColor Cyan

Assert 'the template takes a model list per tier' ($bicep -match 'param\s+modelsStandard\s+string' -and $bicep -match 'param\s+modelsPremium\s+string')
Assert 'they become named values'                 ($bicep -match "key:\s*'models-standard'" -and $bicep -match "key:\s*'models-premium'")
Assert 'the policy reads them'                    ($policy -match '\{\{models-standard\}\}' -and $policy -match '\{\{models-premium\}\}')

# The check must happen before the request reaches Foundry, or it is not a
# control - it is a report.
$modelGate = [regex]::Match($policy, '<set-variable name="modelAllowed".*?/>', 'Singleline')
Assert 'the policy decides whether the model is allowed' $modelGate.Success
Assert 'the decision uses the caller tier' ($modelGate.Success -and $modelGate.Value -match 'tier')

# Sentinel commas, so claude-opus-5 cannot match claude-opus-5-mini and a
# narrower list cannot be widened by a prefix.
Assert 'the lookup is anchored on commas' ($modelGate.Success -and $modelGate.Value -match '","\s*\+|"," \+')

$refusal = $policy.Substring([Math]::Max(0, $policy.IndexOf('modelAllowed')))
Assert 'a disallowed model is refused'       ($refusal -match 'model_not_allowed|invalid_request_error')
Assert 'the refusal names the model'         ($refusal -match 'modelName')
Assert 'the refusal is in Anthropic shape'   ($refusal -match '"type", "error"')

# The gate has to sit ahead of the managed-identity swap, otherwise a rejected
# model has already been sent upstream.
$gateAt = $policy.IndexOf('modelAllowed')
$msiAt = $policy.IndexOf('authentication-managed-identity')
Assert 'the model is checked before Foundry is called' (($gateAt -ge 0) -and ($msiAt -ge 0) -and ($gateAt -lt $msiAt)) "gate at $gateAt, managed identity at $msiAt"

Write-Host ''
Write-Host 'P13 capability scoping - settings, delivered per tier' -ForegroundColor Cyan

Assert 'the profile generator exists' (Test-Path $profilePath) $profilePath
if (Test-Path $profilePath) {
    $gen = Get-Content $profilePath -Raw
    Assert 'it generates per tier'            ($gen -match '\$Tier')
    Assert 'it scopes the model list to tier' ($gen -match 'availableModels|AvailableModels')
    Assert 'it can scope Desktop tabs'        ($gen -match 'coworkTabEnabled')
}

Write-Host ''
Write-Host 'P13 capability scoping - documentation' -ForegroundColor Cyan

$docs = @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue) +
        @(Get-ChildItem $root -Filter '*.md' -ErrorAction SilentlyContinue)
$corpus = ($docs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"

Assert 'ADR-0004 is recorded' (Test-Path (Join-Path $root 'docs/adr/0004-policy-out-of-band.md'))

# Claiming a client-side control is a security boundary would be the actual
# failure this packet could ship, so the honest framing is asserted.
Assert 'client-side controls are called what they are' ($corpus -match '(?i)bypass any client-side control|client-side control')
Assert 'the model allowlist is described as server-side' ($corpus -match '(?i)model allowlist')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P13 contract holds.' -ForegroundColor Green
exit 0
