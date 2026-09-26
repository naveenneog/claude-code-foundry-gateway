# Execute the actual policy expression against typed fixtures, not a parallel implementation.
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] unexpected USD policy error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition) {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label" -ForegroundColor Red; $script:fail++ }
}
function Pack($value) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($value | ConvertTo-Json -Depth 20 -Compress))) }
$policy = Get-Content (Join-Path $root 'infra\policy.xml') -Raw
$body = [regex]::Match($policy, '(?s)<set-variable name="usdDecision" value="@\{(.*?)\}" />').Groups[1].Value
Assert 'USD expression is present' ([bool]$body)
$body = [Net.WebUtility]::HtmlDecode($body).Replace('context.Variables', 'variables')
foreach ($name in 'usd-budgets', 'usd-budget-state', 'bu-modes', 'bu-parents', 'bu-members', 'entitlement-source') {
    $body = $body.Replace('"{{' + $name + '}}"', 'named["' + $name + '"]')
}
$class = 'UsdPolicy' + [guid]::NewGuid().ToString('N')
$source = "using System; using Newtonsoft.Json.Linq; using System.Collections.Generic; public class $class { public static string Evaluate(Dictionary<string,object> variables, Dictionary<string,string> named) { $body } }"
$references = @((Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName) + [Newtonsoft.Json.Linq.JObject].Assembly.Location
try {
    # PowerShell bundles a net6 Newtonsoft assembly with net10 reference assemblies.
    # Accept only that runtime-unification warning; every other compiler warning fails.
    $warnings = @()
    $type = Add-Type -TypeDefinition $source -ReferencedAssemblies $references -PassThru -ErrorAction Stop `
        -IgnoreWarnings -WarningVariable warnings -WarningAction SilentlyContinue
    foreach ($warning in $warnings) {
        if ([string]$warning -notmatch 'CS1701:') { throw [string]$warning }
    }
}
catch { Write-Host "  [FAIL] policy expression did not compile: $($_.Exception.Message)"; exit 1 }
$variables = [Collections.Generic.Dictionary[string,object]]::new()
$variables['userId'] = '00000000-0000-0000-0000-000000000001'
$variables['businessUnit'] = 'finance'
$variables['parentUnit'] = ''
$variables['buMode'] = 'strict'
$variables['parentMode'] = 'strict'
$named = [Collections.Generic.Dictionary[string,string]]::new()
foreach ($key in 'bu-modes', 'bu-members', 'bu-parents') { $named[$key] = ',,' }
$named['entitlement-source'] = 'named-value'
$named['usd-budgets'] = 'e30='
$named['usd-budget-state'] = 'e30='
function Evaluate {
    try { return ($type::Evaluate($variables, $named) | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ http_status = 599; message = $_.Exception.Message } }
}
Assert 'disabled USD controls preserve old behavior' ($null -eq (Evaluate).http_status)
$spec = @{ schema_version = 1; items = @{ 'organization:finance' = @{ amount_usd = '1'; period = 'month' } } }
$named['usd-budgets'] = Pack $spec
Assert 'missing enforced state fails closed with 503' ((Evaluate).http_status -eq 503)
$variables['buMode'] = 'notify'
$notice = Evaluate
Assert 'notify never refuses solely because reconciliation state is missing' ($null -eq $notice.http_status -and @($notice.notices).Count -eq 1)
$variables['buMode'] = 'strict'
$material = (@('usd-budgets','bu-modes','bu-parents','bu-members','entitlement-source') | ForEach-Object { $named[$_] }) -join "`n"
$hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($material))).Replace('-', '').ToLowerInvariant()
$now = [datetime]::UtcNow
$item = @{ scope_type = 'organization'; scope_id = 'finance'; budget_usd = '1'; effective_budget_usd = '1'
    spent_usd = '1.000001'; status = 'stop'; exact = $true
    period_start = $now.AddDays(-1).ToString('o'); period_end = $now.AddDays(1).ToString('o') }
$state = @{ schema_version = 1; source_revision = 'independent-fixture'; policy_revision = $hash
    reconciled_at = $now.AddSeconds(-10).ToString('o'); valid_until = $now.AddSeconds(600).ToString('o')
    items = @{ 'organization:finance' = $item } }
$named['usd-budget-state'] = Pack $state
$stop = Evaluate
Assert 'stop returns the distinct 403 and exact decimal text' ($stop.http_status -eq 403 -and $stop.code -eq 'usd_budget_exceeded' -and $stop.spent_usd -ceq '1.000001')
Assert 'stop identifies scope and reconciliation time' ($stop.scope_id -eq 'finance' -and $stop.scope_type -eq 'organization' -and $stop.reconciled_at)
Assert 'wire reconciliation time retains an explicit UTC designator' ($type::Evaluate($variables, $named) -match '"reconciled_at":"[^"]+Z"')
$compact = @{ schema_version = 1; encoding = 'compact-v1'; source_revision = $state.source_revision; policy_revision = $hash
    reconciled_at = $state.reconciled_at; valid_until = $state.valid_until; price_book_date = '2026-09-16'
    periods = @{ month = @($item.period_start, $item.period_end) }
    items = @{ 'organization:finance' = @('month', '1', '1', '1.000001', 'stop', 'strict', 7, @()) } }
$named['usd-budget-state'] = Pack $compact
$packedStop = Evaluate
Assert 'compact state reconstructs the same scope and exact spend' ($packedStop.http_status -eq 403 -and $packedStop.scope_id -eq 'finance' -and $packedStop.spent_usd -ceq '1.000001' -and $packedStop.exact)
$item.status = 'allow'
$named['usd-budget-state'] = Pack $state
Assert 'a reconciled allowance is admitted' ($null -eq (Evaluate).http_status)
$item.status = 'unpriced'; $item.spent_usd = $null; $item.exact = $false
$named['usd-budget-state'] = Pack $state
Assert 'unpriced usage is not admitted or reported as zero' ((Evaluate).code -eq 'usd_budget_unpriced' -and $null -eq (Evaluate).spent_usd)
$item.status = 'allow'
$state.valid_until = $now.AddSeconds(-1).ToString('o')
$named['usd-budget-state'] = Pack $state
Assert 'expired enforced state is a distinct dependency refusal' ((Evaluate).code -eq 'usd_budget_state_stale')
$variables['buMode'] = 'notify'
Assert 'notify does not depend on an unexpired reconciler' ($null -eq (Evaluate).http_status)
$variables['buMode'] = 'strict'
$state.valid_until = $now.AddSeconds(600).ToString('o')
$state.policy_revision = 'wrong'
$named['usd-budget-state'] = Pack $state
Assert 'a stale configuration cannot lift a stop' ((Evaluate).http_status -eq 503)
$variables['businessUnit'] = 'finance-emea'
Assert 'prefix matches never apply another unit budget' ($null -eq (Evaluate).http_status)
$variables['businessUnit'] = 'finance'
$variables['buMode'] = 'notify'
$spec.items['user:00000000-0000-0000-0000-000000000001'] = @{ amount_usd = '1'; period = 'day' }
$named['usd-budgets'] = Pack $spec
Assert 'notify cannot bypass an enforced personal scope' ((Evaluate).http_status -eq 503)
if ($fail) { Write-Host "$fail policy expression assertion(s) failed."; exit 1 }
Write-Host 'Actual USD policy expression passed.'
exit 0
