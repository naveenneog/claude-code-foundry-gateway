# Negative test for the Turnstile checks.
#
# A check that passes is worth nothing until it has been seen to fail. This breaks each
# thing Test-Turnstile.ps1 and Test-TurnstileGovernance.ps1 claim to guard, one at a time,
# on a throwaway copy of the repository, and confirms a suite goes red.
#
# Its own file rather than more entries in Test-BusinessUnitsNegative.ps1, which is past
# the size budget; the method is the same.

$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "turnstile-negative-$PID-$(Get-Random)"

$bridge = 'Test-Turnstile.ps1'
$governance = 'Test-TurnstileGovernance.ps1'
$mutations = @(
    @{ Suite = $bridge; Name = 'usage is sent as eventhub, distorting Turnstile''s cache correction'
       File  = 'scripts/ClaudeTurnstile.ps1'; From = "ingest_source      = 'backfill'"; To = "ingest_source      = 'eventhub'" }
    @{ Suite = $bridge; Name = 'the event check stops refusing estimated rows'
       File  = 'scripts/ClaudeTurnstile.ps1'; From = "-and `$Event['estimated'] -ne `$false)"; To = '-and $false)' }
    @{ Suite = $bridge; Name = 'the batch check stops refusing estimated rows'
       File  = 'scripts/ClaudeTurnstile.ps1'; From = "if (`$e['estimated'] -ne `$false) {"; To = 'if ($false) {' }
    @{ Suite = $bridge; Name = 'unmeasured cache is no longer named the way Turnstile names it'
       File  = 'scripts/ClaudeTurnstile.ps1'; From = "`$script:TurnstileCacheUnmeasured = 'stream_cache_usage_unavailable'"; To = "`$script:TurnstileCacheUnmeasured = 'cache_unknown'" }
    @{ Suite = $governance; Name = 'a team stops being a department under its unit'
       File  = 'scripts/ClaudeTurnstileGovernance.ps1'; From = '[string]$team.Id }); parent_id = [string]$u.Id'; To = '[string]$team.Id }); parent_id = [string]$team.Id' }
    @{ Suite = $governance; Name = 'a setting that breaks the named value format is accepted'
       File  = 'scripts/ClaudeTurnstileGovernance.ps1'; From = "if (`$v -match '[;=`"]') {"; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'budgets pulled from Turnstile are written without -Apply'
       File  = 'scripts/Sync-ClaudeTurnstileGovernance.ps1'; From = 'if (-not $Apply) {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'Connect accepts a Turnstile that is not admin-only'
       File  = 'scripts/Connect-ClaudeTurnstile.ps1'; From = "if (-not `$entra['ENTRA_ADMIN_ROLE'] -or -not `$tenants.Count) {"; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'a multi-tenant application is used for Turnstile'
       File  = 'scripts/New-ClaudeTurnstileEntraApp.ps1'; From = "if (`$app.signInAudience -ne 'AzureADMyOrg') { throw"; To = 'if ($false) { throw' }
    @{ Suite = $governance; Name = 'Entra stops requiring assignment'
       File  = 'scripts/New-ClaudeTurnstileEntraApp.ps1'; From = '@{ appRoleAssignmentRequired = $true }'; To = '@{ appRoleAssignmentRequired = $false }' }
    @{ Suite = $governance; Name = 'an unpriced line is reported as costing nothing'
       File  = 'scripts/Get-ClaudeTurnstileBom.ps1'; From = 'MonthlyUsd = $(if ($null -eq $Monthly) { $null }'; To = 'MonthlyUsd = $(if ($null -eq $Monthly) { 0 }' }
    @{ Suite = $governance; Name = 'a portal picture with a real value left is saved anyway'
       File  = 'guide/capture-turnstile-entra.mjs'; From = 'if (left.length) {'; To = 'if (false) {' }
    @{ Suite = $governance; Name = 'a real address is written into a picture script'
       File  = 'guide/render-turnstile.mjs'; From = "'amara.okafor@contoso.com']"; To = "'amara.okafor@fabrikam.com']" }
    @{ Suite = $governance; Name = 'a real identifier is written into a picture script'
       File  = 'guide/capture-turnstile-entra.mjs'; From = "const PUBLIC_GUIDS = ['04b07795-8ddb-461a-bbee-02f9e1bf7b46'];"; To = "const PUBLIC_GUIDS = ['04b07795-8ddb-461a-bbee-02f9e1bf7b46', '5a7c9e21-3b4d-4f6a-8c2e-9d1b7f3a6e45'];" }
    @{ Suite = $bridge; Name = 'the guide drops the one-enforcer rule'
       File  = 'docs/TURNSTILE.md'; From = 'One enforcer'; To = 'Enforcement' }
    @{ Suite = $governance; Name = 'a failed scheduled run is retried'
       File  = 'infra/turnstile-schedule.bicep'; From = 'replicaRetryLimit: 0'; To = 'replicaRetryLimit: 3' }
    @{ Suite = $governance; Name = 'the job''s logs need the workspace key'
       File  = 'infra/turnstile-schedule.bicep'; From = "destination: 'azure-monitor'"; To = "destination: 'log-analytics'" }
    @{ Suite = $governance; Name = 'the job may run a branch rather than a commit'
       File  = 'scripts/Register-ClaudeTurnstileSchedule.ps1'; From = "if (`$RepositoryRef -notmatch '^[0-9a-f]{40}$') { throw"; To = 'if ($false) { throw' }
    @{ Suite = $governance; Name = 'the job may run a commit that was never pushed'
       File  = 'scripts/Register-ClaudeTurnstileSchedule.ps1'; From = 'if (-not $onRemote.Count) { throw'; To = 'if ($false) { throw' }
    @{ Suite = $governance; Name = 'the scheduled sync asks for a delegated scope'
       File  = 'scripts/Invoke-ClaudeTurnstileSchedule.ps1'; From = 'get-access-token --resource $resource'; To = 'get-access-token --scope $resource' }
    @{ Suite = $governance; Name = 'the identity cannot read the Application Insights resource'
       File  = 'scripts/Connect-ClaudeTurnstile.ps1'; From = "if (`$component.id) { Add-Role 'Reader' `$component.id }"; To = '' }
    @{ Suite = $bridge; Name = 'the guide drops the measured resend'
       File  = 'docs/TURNSTILE.md'; From = '1,114'; To = '1114' }
)

$missed = @()
$caught = 0
try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    foreach ($d in 'scripts', 'tests', 'analytics', 'guide', 'infra') { Copy-Item (Join-Path $root $d) $sandbox -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs') -Force | Out-Null
    Copy-Item (Join-Path $root 'docs/TURNSTILE.md') (Join-Path $sandbox 'docs') -Force
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'config') -Force | Out-Null
    Get-ChildItem (Join-Path $root 'config') -File -Filter '*.example.json' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox 'config') -Force }

    foreach ($s in $bridge, $governance) {
        & (Join-Path $sandbox "tests/$s") *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [SETUP] the unmutated copy of $s already fails - the sandbox is wrong, not the code" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host '  [BASE]   the unmutated copy passes' -ForegroundColor DarkGray

    foreach ($m in $mutations) {
        $path = Join-Path $sandbox $m.File
        $original = [IO.File]::ReadAllText($path)
        if (-not $original.Contains($m.From)) {
            Write-Host "  [SETUP] '$($m.From)' not found in $($m.File)" -ForegroundColor Yellow
            $missed += "$($m.Name) (mutation did not apply)"
            continue
        }
        [IO.File]::WriteAllText($path, $original.Replace($m.From, $m.To))
        & (Join-Path $sandbox "tests/$($m.Suite)") *>&1 | Out-Null
        $wentRed = ($LASTEXITCODE -ne 0)
        [IO.File]::WriteAllText($path, $original)
        if ($wentRed) { Write-Host "  [CAUGHT] $($m.Name)" -ForegroundColor Green; $caught++ }
        else { Write-Host "  [MISSED] $($m.Name)" -ForegroundColor Red; $missed += $m.Name }
    }
}
finally {
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$caught of $($mutations.Count) mutations caught."
if ($missed.Count) {
    Write-Host 'Not caught - these assertions do not measure what they claim:' -ForegroundColor Red
    $missed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Every mutation was caught.' -ForegroundColor Green
exit 0
