# Negative test for the Turnstile checks.
#
# A check that passes is worth nothing until it has been seen to fail. This breaks each
# thing Test-Turnstile.ps1 and Test-TurnstileGovernance.ps1 claim to guard, one at a time,
# on a throwaway copy of the repository, and confirms a suite goes red.
#
# Its own file rather than more entries in Test-BusinessUnitsNegative.ps1, which is past
# the size budget; the method is the same.

param([string]$Shard = '', [switch]$ListMutations)

$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('turnstile-negative-' + [guid]::NewGuid().ToString('N'))

# BEGIN MUTATION MANIFEST
$bridge = 'Test-Turnstile.ps1'
$governance = 'Test-TurnstileGovernance.ps1'
$teams = 'Test-Teams.ps1'
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
    @{ Suite = $governance; Name = 'the job''s start script keeps Windows line endings'
       File  = 'infra/turnstile-schedule.bicep'; From = "replace(bootstrap, '\r', '')"; To = 'bootstrap' }
    @{ Suite = $governance; Name = 'a pass hides refused budgets in a count'
       File  = 'scripts/Invoke-ClaudeTurnstileSchedule.ps1'; From = "refused `$(`$refused.Count)"; To = "`$(@(`$result.Budgets).Count) budget(s)" }
    @{ Suite = $bridge; Name = 'the guide drops the measured resend'
       File  = 'docs/TURNSTILE.md'; From = '1,114'; To = '1114' }
    @{ Suite = $governance; Name = 'the unassigned organization becomes a business unit'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ($id -eq ''unassigned'') { continue }'; To = '' }
    @{ Suite = $governance; Name = 'a unit''s direct-members department becomes a team'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if (-not $parent -or $id -eq $parent -or'; To = 'if (-not $parent -or' }
    @{ Suite = $governance; Name = 'membership is refreshed from groups that could not be read'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ($graph -ne ''ok'') {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'a group that cannot be checked is always trusted'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ($known -contains $key) { return $true }'; To = 'return $true' }
    @{ Suite = $governance; Name = 'a group that does not exist is applied'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'default { $problems.Add("${Label}: there is no Entra group ''$Group''"); return $false }'; To = 'default { return $true }' }
    @{ Suite = $governance; Name = 'every model is written as no model'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if (-not $items.Count) { return '',,'' }'; To = 'if (-not $items.Count) { return '','' }' }
    @{ Suite = $governance; Name = 'Turnstile''s demonstration catalog is applied'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ([string]$Catalog.source -ne ''configured'') {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'a write is not read back'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = '-Id $c.Id) -ne $c.Now) {'; To = '-Id $c.Id) -ne $c.Now -and $false) {' }
    @{ Suite = $governance; Name = 'membership is refreshed while a tier has no group'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'elseif (@($script:ClaudeGatewayTiers | Where-Object { -not $selected.TierGroups.Contains($_) }).Count) {'; To = 'elseif ($false) {' }
    @{ Suite = $governance; Name = 'every unit gone at once is applied'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if (-not @($selected.Governance.Registry).Count -and $currentUnits.Count) {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'the job may change the gateway''s policy'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = '''Microsoft.ApiManagement/service/operationresults/read'')'; To = '''Microsoft.ApiManagement/service/operationresults/read'', ''Microsoft.ApiManagement/service/policies/write'')' }
    @{ Suite = $governance; Name = 'a push overwrites what Turnstile authored'
       File  = 'scripts/Sync-ClaudeTurnstileGovernance.ps1'; From = '-and $governanceAuthority -eq ''Turnstile'' -and -not $Seed) {'; To = '-and $governanceAuthority -eq ''Turnstile'' -and $false) {' }
    @{ Suite = $governance; Name = 'budgets are read before the month is prepared'
       File  = 'scripts/Sync-ClaudeTurnstileGovernance.ps1'; From = '$Period = [string]$prepared.period'; To = '' }
    @{ Suite = $governance; Name = 'Turnstile is seeded again on every registration'
       File  = 'scripts/Connect-ClaudeTurnstile.ps1'; From = 'if (-not $wasTurnstile) {'; To = 'if ($true) {' }
    @{ Suite = $governance; Name = 'a failed seed leaves governance with Turnstile'
       File  = 'scripts/Connect-ClaudeTurnstile.ps1'; From = '$settings.governanceAuthority = ''Gateway'''; To = '' }
    @{ Suite = $governance; Name = 'Turnstile''s API is granted on the gateway, not the apply job'
       File  = 'scripts/Connect-ClaudeTurnstile.ps1'; From = 'Role = ''Container Apps Jobs Operator''; Scope = $applyJobId }'; To = 'Role = ''Container Apps Jobs Operator''; Scope = $gatewayId }' }
    @{ Suite = $governance; Name = 'a save starts the job that also exports'
       File  = 'infra/turnstile-schedule.bicep'; From = 'trigger: ''Manual'', skipExport: true'; To = 'trigger: ''Manual'', skipExport: false' }
    @{ Suite = $governance; Name = 'entries in another order are written again'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ((& $canonical $was) -ne (& $canonical ([string]$want[$id]))) {'; To = 'if ($was -ne [string]$want[$id]) {' }
    @{ Suite = $governance; Name = 'every registration restarts Turnstile'
       File  = 'scripts/Connect-ClaudeTurnstile.ps1'; From = 'if ($jobSetting -ne $applyJobId) {'; To = 'if ($true) {' }
    @{ Suite = $governance; Name = 'membership lists are written while the projection is the source'
       File  = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ($current[''entitlement-source''] -eq ''projection'') {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'a manager role can be held by an application'
       File  = 'scripts/New-ClaudeTurnstileEntraApp.ps1'; From = 'allowedMemberTypes = @(''User'') }'; To = 'allowedMemberTypes = @(''User'', ''Application'') }' }
    @{ Suite = $governance; Name = 'tokens carry every group a person is in'
       File  = 'scripts/New-ClaudeTurnstileEntraApp.ps1'; From = 'patch.groupMembershipClaims = ''ApplicationGroup'''; To = 'patch.groupMembershipClaims = ''All''' }
    @{ Suite = $governance; Name = 'the CLI sign-in puts the token in the link'
       File  = 'scripts/Open-ClaudeTurnstile.ps1'; From = 'EscapeDataString($grant.code)'; To = 'EscapeDataString($token)' }
    @{ Suite = $governance; Name = 'unknown modes become valid'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = '$Mode -cnotin @(''strict'', ''allowance'', ''notify'')'; To = '$Mode -cnotin @(''strict'', ''allowance'', ''notify'', ''other'')' }
    @{ Suite = $governance; Name = 'mode names become case insensitive'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = '-cnotin'; To = '-notin' }
    @{ Suite = $governance; Name = 'zero allowance becomes valid'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = '$AllowancePercent -lt 1'; To = '$AllowancePercent -lt 0' }
    @{ Suite = $governance; Name = 'allowance over 100 becomes valid'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = '$AllowancePercent -gt 100'; To = '$AllowancePercent -gt 101' }
    @{ Suite = $governance; Name = 'fractional and string allowances become valid'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = '($AllowancePercent -isnot [int] -and $AllowancePercent -isnot [long])'; To = '$false' }
    @{ Suite = $governance; Name = 'notify may carry an allowance'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = 'if ($null -ne $AllowancePercent) {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'mode parser accepts missing sentinel commas'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = "if (`$Value -notmatch '^,.+,$')"; To = 'if ($false)' }
    @{ Suite = $governance; Name = 'mode parser accepts duplicate ids'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = 'if ($seen.ContainsKey($id))'; To = 'if ($false)' }
    @{ Suite = $governance; Name = 'stored allowances accept zero'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = '([1-9][0-9]?|100)'; To = '([0-9][0-9]?|100)' }
    @{ Suite = $governance; Name = 'strict is not canonicalized away'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = "if (`$mode -ne 'strict')"; To = 'if ($true)' }
    @{ Suite = $governance; Name = 'null metadata is accepted'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$attributes.Contains($key) -and $null -eq $attributes[$key]'; To = '$false' }
    @{ Suite = $governance; Name = 'unit modes are not seeded'
       File = 'scripts/ClaudeTurnstileGovernance.ps1'; From = ' + (Get-ClaudeBudgetModeAttributes -Id $u.Id -Modes $Modes)'; To = '' }
    @{ Suite = $governance; Name = 'team modes are not seeded'
       File = 'scripts/ClaudeTurnstileGovernance.ps1'; From = ' + (Get-ClaudeBudgetModeAttributes -Id $team.Id -Modes $Modes)'; To = '' }
    @{ Suite = $governance; Name = 'seeded allowance is not an integer'
       File = 'scripts/ClaudeBudgetModes.ps1'; From = "allowance_percent = [int]`$mode.Split(':')[1]"; To = "allowance_percent = `$mode.Split(':')[1]" }
    @{ Suite = $governance; Name = 'seed reads the wrong modes named value'
       File = 'scripts/Sync-ClaudeTurnstileGovernance.ps1'; From = "-Id 'bu-modes'"; To = "-Id 'bu-parents'" }
    @{ Suite = $governance; Name = 'mode comparison disappears'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = "'bu-modes'    = ConvertTo-ClaudeBuModes `$Desired.Modes"; To = '' }
    @{ Suite = $governance; Name = 'apply does not read modes in its list call'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = "@('bu-registry', 'bu-parents', 'bu-modes')"; To = "@('bu-registry', 'bu-parents')" }
    @{ Suite = $governance; Name = 'invalid mode no longer stops the apply'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if ($desired.InvalidModes) {'; To = 'if ($false) {' }
    @{ Suite = $governance; Name = 'group filtering discards valid modes'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$modes[$unit.Id] = $Desired.Modes[$unit.Id]'; To = '' }
    @{ Suite = $governance; Name = 'empty catalog clears modes'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = "-notin 'bu-registry', 'bu-parents', 'bu-modes'"; To = "-notin 'bu-registry', 'bu-parents'" }
    @{ Suite = $governance; Name = 'CLI coerces fractional allowance to an integer'
       File = 'scripts/Set-ClaudeBusinessUnit.ps1'; From = '[object]$AllowancePercent'; To = '[int]$AllowancePercent' }
    @{ Suite = $teams; Name = 'CLI cannot select modes'
       File = 'scripts/Set-ClaudeBusinessUnit.ps1'; From = "[ValidateSet('Strict', 'Allowance', 'Notify')]"; To = "[ValidateSet('Strict')]" }
    @{ Suite = $teams; Name = 'CLI keeps a deleted unit mode'
       File = 'scripts/Set-ClaudeBusinessUnit.ps1'; From = '$modes.Remove($Id)'; To = '' }
    @{ Suite = $teams; Name = 'CLI does not validate mode before writing'
       File = 'scripts/Set-ClaudeBusinessUnit.ps1'; From = 'ConvertTo-ClaudeBudgetMode'; To = 'UncheckedMode' }
    @{ Suite = $teams; Name = 'template omits modes'
       File = 'infra/main.bicep'; From = "{ key: 'bu-modes', value: buModesValue }"; To = '' }
    @{ Suite = $teams; Name = 'template resets modes on redeploy'
       File = 'infra/main.bicep'; From = "empty(buModesExisting) ? ',,' : buModesExisting"; To = "',,'" }
    @{ Suite = $teams; Name = 'installer does not read modes'
       File = 'Install-ClaudeGateway.ps1'; From = 'named-value-id bu-modes --query value'; To = 'named-value-id bu-parents --query value' }
    @{ Suite = $teams; Name = 'installer does not preserve modes'
       File = 'Install-ClaudeGateway.ps1'; From = 'buModesExisting=$buModes'; To = "buModesExisting=',,'" }
    @{ Suite = $teams; Name = 'policy omits budget notices'
       File = 'infra/policy.xml'; From = 'name="x-claude-budget-notice"'; To = 'name="x-unused"' }
    @{ Suite = $teams; Name = 'policy omits budget traces'
       File = 'infra/policy.xml'; From = 'source="claude-budget"'; To = 'source="unused"' }
    @{ Suite = $teams; Name = 'budget traces duplicate existing identity joins'
       File = 'infra/policy.xml'; From = 'name="BudgetRequestId"'; To = 'name="RequestId"' }
    @{ Suite = $teams; Name = 'allowance notice triggers before base budget'
       File = 'infra/policy.xml'; From = 'remaining < limit - budget'; To = 'remaining <= limit - budget' }
    @{ Suite = $teams; Name = 'notify notices require a nonexistent counter'
       File = 'infra/policy.xml'; From = 'notices.Add(unit + ";mode=notify;status=usage-reported");'; To = '' }
    @{ Suite = $teams; Name = 'guide drops notice limitations'
       File = 'docs/BUSINESS-UNITS.md'; From = 'notice is deliberately unconditional'; To = 'notice is exact' }
    @{ Suite = $governance; Name = 'changed revisions no longer restart stale plans'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = 'if (-not $changed.Count) {'; To = 'if ($true) {' }
    @{ Suite = $governance; Name = 'freshness compares the stale snapshot to itself'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$fresh = & $ReadGovernance $snapshot'; To = '$fresh = $snapshot' }
    @{ Suite = $governance; Name = 'reconciliation keeps the stale catalog'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$Catalog = $fresh.Catalog;'; To = '' }
    @{ Suite = $governance; Name = 'reconciliation keeps stale budgets'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$BudgetItems = @($fresh.BudgetItems);'; To = '' }
    @{ Suite = $governance; Name = 'reconciliation keeps stale tiers'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$Tiers = @($fresh.Tiers)'; To = '$Tiers = @($Tiers)' }
    @{ Suite = $governance; Name = 'stale retry bound is off by one'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$reconciliations -ge $MaxReconciliations'; To = '$reconciliations -gt $MaxReconciliations' }
    @{ Suite = $governance; Name = 'freshness failures still allow writes'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$Apply = $false'; To = '$Apply = $true' }
    @{ Suite = $governance; Name = 'budget revisions are not compared'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$versions[$key] = & $stamp $item.updated_at $key ($null -eq $item.token_limit)'; To = '' }
    @{ Suite = $governance; Name = 'catalog revision is a constant'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = "catalog = & `$stamp `$Snapshot.Catalog.updated_at 'catalog'"; To = "catalog = 'unchanged'" }
    @{ Suite = $governance; Name = 'tier revision is a constant'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = "tiers = & `$stamp `$Snapshot.TierUpdatedAt 'tiers'"; To = "tiers = 'unchanged'" }
    @{ Suite = $governance; Name = 'new budget month does not invalidate the plan'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = 'period = [string]$Snapshot.BudgetPeriod'; To = "period = 'unchanged'" }
    @{ Suite = $governance; Name = 'required missing timestamps are accepted'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = "if (`$Optional) { return '' }"; To = "return ''" }
    @{ Suite = $governance; Name = 'invalid timestamps are accepted'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = 'throw "Turnstile''s $Label has an invalid updated_at."'; To = "return ''" }
    @{ Suite = $governance; Name = 'sync does not wire up the freshness callback'
       File = 'scripts/Sync-ClaudeTurnstileGovernance.ps1'; From = '-ReadGovernance $readGovernance'; To = '' }
    @{ Suite = $governance; Name = 'freshness decisions are hidden from run output'
       File = 'scripts/Sync-ClaudeTurnstileGovernance.ps1'; From = 'Freshness: $($result.Freshness)'; To = 'Finished' }
    @{ Suite = $governance; Name = 'source revision observations are discarded'
       File = 'scripts/ClaudeTurnstileApply.ps1'; From = '$sourceReads.Add($observation)'; To = '' }
    @{ Suite = $governance; Name = 'the guard is documented as the full concurrency fix'
       File = 'docs/TURNSTILE.md'; From = 'narrows the race window; it does not eliminate it'; To = 'eliminates the race window' }
)
foreach ($scope in 'bu', 'parent') {
    $mutations += @(
        @{ Suite = $teams; Name = "$scope uses base quota instead of effective quota"
           File = 'infra/policy.xml'; From = "token-quota=`"@(long.Parse((string)context.Variables[`"${scope}Limit`"]))`""; To = "token-quota=`"@(long.Parse((string)context.Variables[`"${scope}Quota`"]))`"" }
        @{ Suite = $teams; Name = "$scope no longer exposes remaining quota to notices"
           File = 'infra/policy.xml'; From = "remaining-quota-tokens-variable-name=`"${scope}Remaining`""; To = '' }
        @{ Suite = $teams; Name = "$scope notify limiter is no longer skipped"
           File = 'infra/policy.xml'; From = "${scope}Limit`"] != `"0`""; To = "${scope}Limit`"] != `"x`"" }
        @{ Suite = $teams; Name = "$scope strict base is lost"
           File = 'infra/policy.xml'; From = "return (string)context.Variables[`"${scope}Quota`"];"; To = 'return "0";' }
        @{ Suite = $teams; Name = "$scope allowance loses its base budget"
           File = 'infra/policy.xml'; From = "var tokens = decimal.Parse((string)context.Variables[`"${scope}Quota`"]);"; To = 'var tokens = 0m;' }
    )
}

# END MUTATION MANIFEST
. (Join-Path $PSScriptRoot 'Select-MutationShard.ps1')
$mutationIndices = @(Get-MutationShardIndices -Count $mutations.Count -Shard $Shard)
if ($ListMutations) {
    $inventory = @(foreach ($i in $mutationIndices) { [pscustomobject]@{ Index = $i; Name = $mutations[$i].Name } })
    ConvertTo-Json -InputObject $inventory
    exit 0
}
if ($Shard) { Write-Host "Shard ${Shard}: $($mutationIndices.Count) of $($mutations.Count) mutations." }

$missed = @()
$caught = 0
try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    foreach ($d in 'scripts', 'tests', 'analytics', 'guide', 'infra', 'docs') { Copy-Item (Join-Path $root $d) $sandbox -Recurse -Force }
    Copy-Item (Join-Path $root 'Install-ClaudeGateway.ps1') $sandbox
    Copy-Item (Join-Path $root '.gitignore') $sandbox
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'config') -Force | Out-Null
    Get-ChildItem (Join-Path $root 'config') -File -Filter '*.example.json' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox 'config') -Force }

    foreach ($s in $bridge, $governance, $teams) {
        $baseOutput = & (Join-Path $sandbox "tests/$s") *>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [SETUP] the unmutated copy of $s already fails - the sandbox is wrong, not the code" -ForegroundColor Red
            $baseOutput | Where-Object { "$_" -match '\[FAIL\]|Exception|Error' } | ForEach-Object { Write-Host $_ }
            exit 1
        }
    }
    Write-Host '  [BASE]   the unmutated copy passes' -ForegroundColor DarkGray

    foreach ($index in $mutationIndices) {
        $m = $mutations[$index]
        $path = Join-Path $sandbox $m.File
        $original = [IO.File]::ReadAllText($path)
        if (-not $original.Contains($m.From)) {
            Write-Host "  [SETUP] '$($m.From)' not found in $($m.File)" -ForegroundColor Yellow
            $missed += "$($m.Name) (mutation did not apply)"
            continue
        }
        [IO.File]::WriteAllText($path, $original.Replace($m.From, $m.To))
        try {
            & (Join-Path $sandbox "tests/$($m.Suite)") *>&1 | Out-Null
            $wentRed = ($LASTEXITCODE -ne 0)
        }
        catch { $wentRed = $true }
        finally { [IO.File]::WriteAllText($path, $original) }
        if ($wentRed) { Write-Host "  [CAUGHT] $($m.Name)" -ForegroundColor Green; $caught++ }
        else { Write-Host "  [MISSED] $($m.Name)" -ForegroundColor Red; $missed += $m.Name }
    }
}
finally {
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$caught of $($mutationIndices.Count) mutations caught."
if ($missed.Count) {
    Write-Host 'Not caught - these assertions do not measure what they claim:' -ForegroundColor Red
    $missed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Every mutation was caught.' -ForegroundColor Green
exit 0
