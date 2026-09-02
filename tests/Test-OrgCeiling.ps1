# P11 - the org-wide monthly spend ceiling.
#
# RED first: written before the policy change, and fails for the right reason.
#
# The design is measured, not assumed. Two throwaway APIs on the live gateway
# established both halves (see docs/UNKNOWNS.md U1 and docs/STATUS.md):
#
#   1. A constant counter-key is a single counter shared by every caller.
#   2. <on-error> fires when llm-token-limit refuses, carrying
#      Reason=OpenAITokenQuotaExceeded, Source=llm-token-limit, Scope=api.
#      Those are identical for the org ceiling and the per-user daily quota, so
#      LastError alone cannot tell them apart. Marking the budget in a variable
#      before each limit does: policies run in order and the failing one halts
#      the pipeline, so the last value set names the budget that refused.
#
# The live half of this is deliberately not automated. Proving the ceiling means
# exhausting it, and the only counter that matters is the production one. The
# measurement is recorded instead, with the throwaway-API method that produced
# it, so it can be repeated on demand.

param([switch]$SkipLive)

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$bicepPath = Join-Path $root 'infra/main.bicep'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P11 org ceiling - configuration' -ForegroundColor Cyan

Assert 'the policy exists' (Test-Path $policyPath) $policyPath
Assert 'the template exists' (Test-Path $bicepPath) $bicepPath
if (-not (Test-Path $policyPath) -or -not (Test-Path $bicepPath)) {
    Write-Host ''
    Write-Host "$fail assertion(s) failed." -ForegroundColor Red
    exit 1
}

$policy = Get-Content $policyPath -Raw
$bicep = Get-Content $bicepPath -Raw

Assert 'the template takes an org ceiling'  ($bicep -match 'param\s+quotaOrg\s+int')
Assert 'it becomes a named value'           ($bicep -match "key:\s*'quota-org'")
Assert 'the policy reads it'                ($policy -match '\{\{quota-org\}\}')

Write-Host ''
Write-Host 'P11 org ceiling - enforcement' -ForegroundColor Cyan

# A constant, not an expression. An org ceiling keyed on anything per-caller is
# a per-caller limit wearing the wrong name, which is the failure this guards.
$orgLimit = [regex]::Match($policy, '<llm-token-limit[^>]*counter-key="(?<k>[^"]*)"[^>]*token-quota-period="Monthly"[^>]*/>', 'Singleline')
if (-not $orgLimit.Success) {
    $orgLimit = [regex]::Match($policy, '<llm-token-limit(?:(?!/>).)*?token-quota-period="Monthly"(?:(?!/>).)*?/>', 'Singleline')
}
Assert 'a monthly limit is enforced in the request path' $orgLimit.Success

if ($orgLimit.Success) {
    $orgXml = $orgLimit.Value
    $key = [regex]::Match($orgXml, 'counter-key="([^"]*)"').Groups[1].Value
    Assert 'the org counter-key is a constant' ($key -notmatch '@\(' -and $key.Length -gt 0) "counter-key=$key"
    Assert 'the org limit reports what is left' ($orgXml -match 'remaining-quota-tokens-header-name="x-org-quota-remaining"')

    # Order decides which budget a caller is told about. The org ceiling has to
    # be checked first so that when the organisation is out of money, that is
    # what the developer hears - not a personal-budget message from the limit
    # that happened to run next.
    $orgAt = $policy.IndexOf($orgXml)
    $dailyAt = $policy.IndexOf('token-quota-period="Daily"')
    Assert 'the org ceiling is checked before per-user quotas' (($dailyAt -lt 0) -or ($orgAt -lt $dailyAt)) "org at $orgAt, first daily at $dailyAt"
}

# Per-tier limits must survive. An org ceiling that replaced them would let one
# developer spend the whole organisation's budget.
Assert 'per-tier minute limits still apply' (([regex]::Matches($policy, 'tokens-per-minute=')).Count -ge 2)
Assert 'per-tier daily quotas still apply'  (([regex]::Matches($policy, 'token-quota-period="Daily"')).Count -ge 2)

Write-Host ''
Write-Host 'P11 org ceiling - refusal message' -ForegroundColor Cyan

# Both quotas refuse with 403, the same code the entitlement check uses. Without
# something to tell them apart the developer reads "403" as "I lost access".
Assert 'the budget is marked before each quota'  (([regex]::Matches($policy, '<set-variable name="budget"')).Count -ge 2)
Assert 'the marker names the organisation'       ($policy -match '<set-variable name="budget" value="organisation"')
Assert 'the marker names the individual'         ($policy -match '<set-variable name="budget" value="personal"')
Assert 'a quota refusal is rewritten'            ($policy -match 'OpenAITokenQuotaExceeded')
Assert 'the rewrite happens in on-error'         ($policy -split '<on-error>' | Select-Object -Last 1 | Where-Object { $_ -match 'OpenAITokenQuotaExceeded' })
Assert 'the reply carries which budget'          ($policy -match '"budget"')
Assert 'the reply is in Anthropic error shape'   ($policy -match 'rate_limit_error')

# Measured 2026-09-02: high-concurrency requests can temporarily exceed the
# configured limit, so this is a soft cap. Saying otherwise in the documentation
# would be a promise the policy does not make.
Assert 'the soft cap is stated in the policy' ($policy -match '(?i)soft cap|temporarily exceed')

Write-Host ''
Write-Host 'P11 org ceiling - documentation' -ForegroundColor Cyan

$docs = @(Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue) +
        @(Get-ChildItem $root -Filter '*.md' -ErrorAction SilentlyContinue)
$corpus = ($docs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
Assert 'the ceiling is documented'    ($corpus -match '(?i)quota-org|org(anisation|anization)[- ]wide (monthly )?(spend )?(ceiling|budget)')
Assert 'it is described as a soft cap' ($corpus -match '(?i)soft cap|temporarily exceed')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P11 contract holds.' -ForegroundColor Green
exit 0
