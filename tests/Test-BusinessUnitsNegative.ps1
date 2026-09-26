# Negative test for the business unit checks.
#
# A check that passes is worth nothing until it has been seen to fail. This
# breaks each thing Test-BusinessUnits.ps1 claims to guard, one at a time,
# confirms the suite goes red, and moves on.
#
# It works on a throwaway copy of the repository, never the repository itself.
# The first version edited the real files and restored them afterwards, which
# has two failure modes that matter: two suites running at once see each
# other's mutations, and an interrupted run leaves a corrupted policy.xml
# behind. Both were observed - a concurrent -IncludeAzure run turned the gate
# red while every mutation here reported caught.

param([string]$Shard = '', [switch]$ListMutations)

$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "bu-negative-$PID-$(Get-Random)"

# BEGIN MUTATION MANIFEST
$mutations = @(
    @{ Name  = 'membership lookup removed from the policy'
       File  = 'infra/policy.xml'
       From  = 'bu-members'
       To    = 'bu-members-DISABLED' }

    @{ Name  = 'comma anchoring dropped from the lookup'
       File  = 'infra/policy.xml'
       From  = 'var marker = "," + oid + "=";'
       To    = 'var marker = oid + "=";' }

    @{ Name  = 'the per-unit quota stops being monthly'
       File  = 'infra/policy.xml'
       From  = 'token-quota-period="Monthly"'
       To    = 'token-quota-period="Yearly"' }

    @{ Name  = 'the refusal stops naming the unit'
       File  = 'infra/policy.xml'
       From  = '(string)(context.Variables.GetValueOrDefault("budgetUnit", "unknown"))'
       To    = '"your unit"' }

    @{ Name  = 'the registry parser splits on the first colon'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'LastIndexOf('
       To    = 'IndexOf(' }

    @{ Name  = 'an identifier with a comma is accepted'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = "^[a-z0-9][a-z0-9-]*$"
       To    = '.' }

    @{ Name  = 'the report stops saying the figure is list price'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = "'  Figures are at list price"
       To    = "'  Figures are at the price" }

    @{ Name  = 'the cache caveat retreats into a comment'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'cache write categories are not'
       To    = 'everything is counted' }

    @{ Name  = 'the guide understates the measured cache gap'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = '38.7'
       To    = '3.7' }

    @{ Name  = 'the guide loses its screenshots'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = '!['
       To    = 'see [' }

    @{ Name  = 'the guide stops explaining unassigned'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'unassigned'
       To    = 'unallocated' }

    # --- P20b, the financial semantics ---

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'money goes back to floating point'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = '[Parameter(Mandatory = $true)][decimal]$Usd,'
       To    = '[Parameter(Mandatory = $true)][double]$Usd,' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the price book goes back to doubles'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = "'claude-sonnet-5'  = @{ InputPerM = [decimal]2.0; OutputPerM = [decimal]10.0 }"
       To    = "'claude-sonnet-5'  = @{ InputPerM = 2.0; OutputPerM = 10.0 }" }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the budget writer takes a double again'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = '[decimal]$MonthlyBudgetUsd,'
       To    = '[double]$MonthlyBudgetUsd,' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the figure is presented as invoice-accurate'
       File  = 'docs/adr/0010-financial-semantics.md'
       From  = 'They are'
       To    = 'They are not' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'token categories are summed before pricing'
       File  = 'docs/adr/0010-financial-semantics.md'
       From  = 'never summed before pricing'
       To    = 'summed before pricing' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'pricing goes back to the client alias'
       File  = 'docs/adr/0010-financial-semantics.md'
       From  = 'Pricing joins on `DeploymentName`'
       To    = 'Pricing joins on the model name' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the price book stops being time-versioned'
       File  = 'docs/adr/0010-financial-semantics.md'
       From  = "in force at the request's timestamp"
       To    = 'in force today' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'soft cap is described as warn-only'
       File  = 'docs/adr/0010-financial-semantics.md'
       From  = 'Ours **does** block'
       To    = 'Ours warns only' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the enforcement gap stops being stated'
       File  = 'docs/adr/0010-financial-semantics.md'
       From  = 'Reporting is categorised; enforcement is not'
       To    = 'Both are categorised' }

    # --- cache in chargeback ---

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'chargeback stops reading the cached-token metric'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'Name == "Prompt Cached Tokens"'
       To    = 'Name == "Nothing"' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'cache is folded into the metered total'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'tokens_cache_read = $cacheRead'
       To    = 'tokens_cacheread = $cacheRead' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the report stops admitting cache write is missing'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'excludes_cache_write   = $true'
       To    = 'excludes_cache_write   = $false' }

    @{ Suite = 'Test-BusinessUnits.ps1'
       Name  = 'the report claims the budget counts cache'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'budget_counts_cache    = $false'
       To    = 'budgetcountscache      = $false' }

    # --- teams and the cascade (ADR-0008), checked by Test-Teams.ps1 ---

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'membership stops filtering to users'
       File  = 'scripts/ClaudeGraphMembership.ps1'
       # The URI is built from $cast.Type now, so the old literal survives only
       # in the comment holding the measured table. Mutating a comment proves
       # nothing - this has to hit the cast the code actually issues.
       From  = "Type = 'microsoft.graph.user';"
       To    = "Type = 'microsoft.graph.device';" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the URI stops being built from the cast'
       File  = 'scripts/ClaudeGraphMembership.ps1'
       From  = 'transitiveMembers/$($cast.Type)'
       To    = 'transitiveMembers' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the parent is no longer resolved'
       File  = 'infra/policy.xml'
       From  = '{{bu-parents}}'
       To    = '' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the parent counter disappears'
       File  = 'infra/policy.xml'
       From  = 'counter-key="@("bu-" + (string)context.Variables["parentUnit"])"'
       To    = 'counter-key="@("static")"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the parent quota stops being monthly'
       File  = 'infra/policy.xml'
       From  = 'remaining-quota-tokens-header-name="x-bu-parent-quota-remaining"'
       To    = 'remaining-quota-tokens-header-name="x-bu-other"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'an unpriced parent walls off its teams'
       From  = 'parentQuota"] != "0"'
       File  = 'infra/policy.xml'
       To    = 'parentQuota"] != "x"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the depth cap is removed from the writer'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'Test-ClaudeBuDepth'
       To    = 'Out-Null #' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'teams stop being resolved before their parents'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'Descending = $true'
       To    = 'Descending = $false' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the sync stops ordering by depth'
       File  = 'scripts/Sync-ClaudeAccess.ps1'
       From  = 'Sort-ClaudeBuByDepth $registry -Parents $parents'
       To    = '$registry' }

    # --- P26, the installer discovers or deploys a model ---

    @{ Name  = 'a redeploy stops preserving the registry'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'buRegistryExisting=$buReg'
       To    = 'tagsIgnored=$buReg' }

    @{ Name  = 'a redeploy stops preserving the parent map'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '--named-value-id bu-parents'
       To    = '--named-value-id bu-nothing' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the Claude filter stops filtering'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = "`$script:ClaudeModelPattern = 'claude'"
       To    = "`$script:ClaudeModelPattern = ''" }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the deployment summary loses its capacity'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = '[{3}, capacity {4}]'
       To    = '[{3}]' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'quota stops being named as a distinct failure'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = "if (`$AzureOutput -match '(?i)quota|InsufficientQuota|exceeded') {"
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the tier lists stop coming from what is deployed'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '$deployed = @(Get-ClaudeDeployment'
       To    = '$deployed = @(' }

    # --- screenshot safety: raw captures must not be committable ---

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the capture writes straight into docs'
       File  = 'guide/capture-entra.mjs'
       From  = "const OUT = path.resolve('.shots-entra');"
       To    = "const OUT = path.resolve('docs/guide');" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the raw captures stop being git-ignored'
       File  = '.gitignore'
       From  = '.shots-entra/'
       To    = '.shots-entra-disabled/' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the redaction stops masking identities'
       File  = 'guide/redact-entra.mjs'
       From  = "\u2022"
       To    = "x" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'a display name is left whole'
       File  = 'guide/redact-entra.mjs'
       From  = 'Go\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022na'
       To    = 'Gopalakrishna' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'an unredacted capture stops failing the run'
       File  = 'guide/redact-entra.mjs'
       From  = 'if (unhandled.length) {'
       To    = 'if (false) {' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the guide stops showing the portal captures'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'entra-2-bu-all-members.png'
       To    = 'nothing.png' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the guide drops the two-axis capture'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'entra-3-team-memberships.png'
       To    = 'nothing.png' }

    # The service principal gap. Each of these three is individually enough to
    # make the servicePrincipal query return an empty collection with a 200, so
    # each has to fail the run on its own.
    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the sync stops asking for service principals'
       File  = 'scripts/ClaudeGraphMembership.ps1'
       From  = "Type = 'microsoft.graph.servicePrincipal'"
       To    = "Type = 'microsoft.graph.device'" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the eventual consistency header is dropped'
       File  = 'scripts/ClaudeGraphMembership.ps1'
       From  = "`$headers['ConsistencyLevel'] = 'eventual'"
       To    = "`$headers['ConsistencyLevel'] = 'session'" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the count the header requires is dropped'
       File  = 'scripts/ClaudeGraphMembership.ps1'
       From  = '&`$count=true"'
       To    = '"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the tier membership capture is dropped'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'entra-7-tier-standard-members.png'
       To    = 'nothing.png' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the guide stops explaining the workload identity row'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'workload identity, not a person'
       To    = 'thing' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'a tier change goes back to being instant'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'takes effect when `Sync-ClaudeAccess.ps1` next runs'
       To    = 'takes effect immediately' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'revocation goes back to clearing one group'
       File  = 'docs/ONBOARDING.md'
       From  = '-Remove -Sync'
       To    = '-Remove' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a disabled account is called a revocation again'
       File  = 'docs/ONBOARDING.md'
       From  = 'does not invalidate one already issued'
       To    = 'revokes every token at once' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the script route stops warning about the handover file'
       File  = 'docs/SETUP.md'
       From  = 'Only the wizard writes that'
       To    = 'Every route writes that' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the portal route stops listing what it skips'
       File  = 'docs/SETUP.md'
       From  = 'Three things the wizard does are left to'
       To    = 'Nothing is left to' }

    # --- P18b, the load envelope ---

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the identity ceiling becomes a pasted literal'
       File  = 'scripts/Measure-ClaudeCeiling.ps1'
       From  = '$MaxIdentities = [int][math]::Floor(($MaxChars - 1) / $OidCost)'
       To    = '$MaxIdentities = 110' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'per-entry cost goes back to being assumed'
       File  = 'scripts/Measure-ClaudeCeiling.ps1'
       From  = '$per = if ($items.Count) { [int][math]::Ceiling($chars / $items.Count) } else { $OidCost }'
       To    = '$per = $OidCost' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a secret list is counted as empty headroom'
       File  = 'scripts/Measure-ClaudeCeiling.ps1'
       From  = 'if ($entry.secret)'
       To    = 'if ($false)' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the ceiling report stops failing the run'
       File  = 'scripts/Measure-ClaudeCeiling.ps1'
       From  = 'if ($worst -ge $FailAtPercent)'
       To    = 'if ($false)' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'an unknown SKU is given a guessed cap'
       File  = 'scripts/Measure-ClaudeCeiling.ps1'
       From  = 'Unknown SKU'
       To    = 'Assuming 5000 for SKU' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the envelope stops admitting what it has not measured'
       File  = 'docs/SCALE.md'
       From  = 'demonstration, not a traffic model'
       To    = 'a representative production sample' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'sharding is presented as the answer'
       File  = 'docs/SCALE.md'
       From  = 'Sharding does not rescue it'
       To    = 'Sharding solves it' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a capacity test goes back to counting keys'
       File  = 'docs/SCALE.md'
       From  = 'retains its consumed allowance'
       To    = 'can be created' }

    # --- P19b, the shadow comparison ---

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the comparison forks its own directory read'
       File  = 'scripts/Compare-ClaudeEntitlement.ps1'
       From  = ". (Join-Path `$PSScriptRoot 'ClaudeGraphMembership.ps1')"
       To    = "function Get-GroupMemberOids { @() } # (" }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'tier precedence stops matching the policy'
       File  = 'scripts/Compare-ClaudeEntitlement.ps1'
       From  = "if (`$Premium -contains `$Oid)  { return 'premium' }"
       To    = "if (`$false) { return 'premium' }" }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a secret list is compared as an empty one'
       File  = 'scripts/Compare-ClaudeEntitlement.ps1'
       From  = 'if ($o.secret)'
       To    = 'if ($false)' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the comparison stops failing on drift'
       File  = 'scripts/Compare-ClaudeEntitlement.ps1'
       From  = 'if ($drift.Count -and $FailOnDrift)'
       To    = 'if ($false)' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'stale access stops being named as outliving removal'
       File  = 'scripts/Compare-ClaudeEntitlement.ps1'
       From  = 'Still entitled after removal.'
       To    = 'Not in the group.' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a rollback is allowed to restore spent allowance'
       File  = 'docs/adr/0009-shadow-migration.md'
       From  = 'restores authorization, never consumption'
       To    = 'restores everything' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'counter keys become migratable'
       File  = 'docs/adr/0009-shadow-migration.md'
       From  = 'Counter keys do not change during migration'
       To    = 'Counter keys are re-keyed' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'authorization changes before the canary'
       File  = 'docs/adr/0009-shadow-migration.md'
       From  = 'Five phases. Authorization does not change until phase 4'
       To    = 'Five phases. Authorization changes at phase 1' }

    # --- P25, the overshoot bound ---

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the bound goes back to the median'
       File  = 'scripts/Measure-ClaudeOvershoot.ps1'
       From  = '$result.telemetry_seconds = [int]$row[2]'
       To    = '$result.telemetry_seconds = [int]$row[1]' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'lag stops being read from ingestion time'
       File  = 'scripts/Measure-ClaudeOvershoot.ps1'
       From  = "datetime_diff('second', ingestion_time(), TimeGenerated)"
       To    = '0' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the workspace is guessed again'
       File  = 'scripts/Measure-ClaudeOvershoot.ps1'
       From  = "workspaces in '`$ResourceGroup'"
       To    = 'ignored' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'propagation stops being observed at the gateway'
       File  = 'scripts/Measure-ClaudeOvershoot.ps1'
       From  = '[long]$rem -le $probe'
       To    = '$true' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the override stops being restored'
       File  = 'scripts/Measure-ClaudeOvershoot.ps1'
       From  = "Set-Nv 'quota-overrides' `$saved"
       To    = "`$null" }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'an incomplete measurement passes silently'
       File  = 'scripts/Measure-ClaudeOvershoot.ps1'
       From  = 'if (-not $result.complete)'
       To    = 'if ($false)' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the kill switch is called a hard cap'
       File  = 'docs/SCALE.md'
       From  = 'delayed kill switch, not a hard cap'
       To    = 'hard cap' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the measured bound loses its numbers'
       File  = 'docs/SCALE.md'
       From  = '**511s**'
       To    = 'some seconds' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the binding ceiling goes back to the tier figure'
       File  = 'docs/SCALE.md'
       From  = 'business-unit membership runs out first'
       To    = 'tier lists run out first' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the token-claim dead end stops being recorded'
       File  = 'docs/SCALE.md'
       From  = '### Why not put the tier in the token'
       To    = '### An aside' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the reason the claim cannot be added is dropped'
       File  = 'docs/SCALE.md'
       From  = 'do not own that registration'
       To    = 'could configure it' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the cost model stops charging per cache miss'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '$missesPerMonth     = [long]($DailyActive * $missesPerActiveDay * $WorkingDaysPerMonth)'
       To    = '$missesPerMonth     = [long]($DailyActive * $WorkingDaysPerMonth)' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the free execution grant disappears'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '[long]$FreeExecutionsPerMonth = 1000000'
       To    = '[long]$FreeGrant = 1000000' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'rates become constants with no read date'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = 'read 2026-09-17'
       To    = 'read recently' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the serverless latency trade stops being recorded'
       File  = 'docs/adr/0011-projection-platform.md'
       From  = 'no guaranteed throughput or latency'
       To    = 'predictable performance' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the cache window becomes a budget decision'
       File  = 'docs/adr/0011-projection-platform.md'
       From  = 'choose the window on the revocation requirement'
       To    = 'choose the window on the invoice' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the README stops stating what it holds today'
       File  = 'README.md'
       From  = 'How many developers this holds today'
       To    = 'Scale' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the lookup cost loses its measured p99'
       File  = 'docs/SCALE.md'
       From  = '**301 ms**'
       To    = '**30 ms**' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the resolver failures after idle lose their count'
       File  = 'docs/SCALE.md'
       From  = '| 3 | **2** |'
       To    = '| 3 | 0 |' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the counters are called exact'
       File  = 'docs/SCALE.md'
       From  = 'soft at any scale'
       To    = 'exact at any scale' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the scale guide stops naming U18'
       File  = 'docs/SCALE.md'
       From  = 'That is **U18**'
       To    = 'That is a known issue' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the README implies the projection is the default'
       File  = 'README.md'
       From  = '**It is not the default.**'
       To    = '**It is the default.**' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'private networking stops being priced'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '[bool]$PrivateNetworking = $true'
       To    = '[bool]$PrivateNetworking = $false' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the endpoint charge stops reaching the total'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '$totalUsd = $functionUsd + $cosmosRuUsd + $storageUsd + $networkUsd'
       To    = '$totalUsd = $functionUsd + $cosmosRuUsd + $storageUsd' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'only the Cosmos endpoint is priced again'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '[int]$PrivateEndpoints = 5,'
       To    = '[int]$PrivateEndpoints = 1,' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the private DNS zones stop being priced'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '[int]$PrivateDnsZones = 5,'
       To    = '[int]$PrivateDnsZones = 0,' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the warm resolver instance stops reaching the total'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '+ $networkUsd + $dnsUsd + $alwaysReadyUsd'
       To    = '+ $networkUsd + $dnsUsd' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a redeploy resets the VNet mode'
       File  = 'infra/main.bicep'
       From  = 'virtualNetworkType: apimVirtualNetworkType'
       To    = "virtualNetworkType: 'None'" }

    @{ Suite = 'Test-On-PS51.ps1'
       Name  = 'the revocation-window lookup ends the wizard on 5.1 again'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '$liveWindow = Invoke-AzOptional { az apim nv show -g $ResourceGroup --service-name $windowTarget --named-value-id entitlement-cache-seconds --query value -o tsv }'
       To    = '$liveWindow = az apim nv show -g $ResourceGroup --service-name $windowTarget --named-value-id entitlement-cache-seconds --query value -o tsv 2>$null' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a re-run resets the revocation window to an hour again'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '$entitlementCacheSeconds = $liveWindowSeconds'
       To    = '$entitlementCacheSeconds = 3600' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the installer stops handing the network state back'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "`$preserveArgs = @('--parameters', ""@`$preserveFile"")"
       To    = '$preserveArgs = @()' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the installer redeploys a gateway it could not read'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "throw 'Refusing to redeploy a gateway whose network state could not be read.'"
       To    = "Write-Host ''" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the Deploy to Azure template drifts from main.bicep'
       File  = 'infra/azuredeploy.json'
       From  = '"apimVirtualNetworkType"'
       To    = '"apimVirtualNetworkMode"' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the authentication page claims a service principal token is short'
       File  = 'docs/AUTHENTICATION.md'
       From  = '**1,445 minutes, about 24 hours**'
       To    = '**60 minutes**' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the private deployment page loses the storage endpoints reason'
       File  = 'docs/SECURE-PROJECTION.md'
       From  = 'All three are needed'
       To    = 'Blob is enough' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the private deployment page quotes the old cost'
       File  = 'docs/SECURE-PROJECTION.md'
       From  = '**$69.09**'
       To    = '**$11.11**' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the Consumption plan limitation is dropped'
       File  = 'docs/adr/0011-projection-platform.md'
       From  = 'Y1 Consumption plan has no VNet integration'
       To    = 'Y1 Consumption plan works fine' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the deployment finding stops being recorded'
       File  = 'docs/adr/0011-projection-platform.md'
       From  = 'publicNetworkAccess: Disabled'
       To    = 'public access open' }

    # --- adding a model, and plugin governance ---

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'an unpriced model is accepted silently'
       File  = 'scripts/Add-ClaudeModel.ps1'
       From  = "if (-not `$SkipPrice -and -not (`$PSBoundParameters.ContainsKey('InputPerMillion')"
       To    = "if (`$false -and -not (`$PSBoundParameters.ContainsKey('InputPerMillion')" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'an undeployed model is added anyway'
       File  = 'scripts/Add-ClaudeModel.ps1'
       From  = 'is not deployed on Foundry account'
       To    = 'is fine on account' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the model list stops filtering to Claude'
       File  = 'scripts/Add-ClaudeModel.ps1'
       From  = "ClaudeModelDeployment.ps1"
       To    = "ApimNamedValue.ps1" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'removing a model empties the list without sentinels'
       File  = 'scripts/Add-ClaudeModel.ps1'
       From  = "else { ',,' }"
       To    = "else { '' }" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'price book rates stop being decimal'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'InputPerM  = [decimal]$m.inputPerM'
       To    = 'InputPerM  = $m.inputPerM' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'a malformed price book is silently ignored'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'Delete it to fall back to the built-in rates'
       To    = 'Ignoring it' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the live price book stops being git-ignored'
       File  = '.gitignore'
       From  = 'config/price-book.json'
       To    = '# config/price-book.json' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'Desktop loses its marketplace allowlist'
       File  = 'scripts/New-ClaudeCodePolicy.ps1'
       From  = "`$desktop['allowedPluginMarketplaces'] = `$sources"
       To    = "`$null = `$sources" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the deployment mode stops being pinned'
       File  = 'scripts/New-ClaudeCodePolicy.ps1'
       From  = "`$desktop['disableDeploymentModeChooser'] = `$true"
       To    = "`$null = `$true" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'a one-entry marketplace list collapses to an object'
       File  = 'scripts/New-ClaudeCodePolicy.ps1'
       From  = 'ConvertTo-Json -InputObject $Value -Depth 8 -Compress'
       To    = '($Value | ConvertTo-Json -Depth 8 -Compress)' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the desktop profile stops being written'
       File  = 'scripts/New-ClaudeCodePolicy.ps1'
       From  = 'Save "$desktopBase.managed-settings.json"'
       To    = '# Save "$desktopBase.managed-settings.json"' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'plugin controls are presented as a boundary'
       File  = 'docs/PLUGINS.md'
       From  = 'feature-availability controls, not data boundaries'
       To    = 'hard security boundaries' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the guide stops naming the quiet pricing failure'
       File  = 'docs/MODELS.md'
       From  = 'The third is the one that fails quietly'
       To    = 'All four are obvious' }

    # --- the health check ---

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the health check reimplements a check instead of running it'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = "'Compare-ClaudeEntitlement.ps1'"
       To    = "'Nothing.ps1'" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'sub-check output floods the summary again'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = '& $path @ScriptArgs *>&1'
       To    = '& $path @ScriptArgs 2>&1' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'arguments go back to positional'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = '[hashtable]$ScriptArgs'
       To    = '[string[]]$ScriptArgs' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'a classic SKU stops failing the run'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = "`$sku -in @('BasicV2', 'StandardV2', 'PremiumV2')"
       To    = "`$true" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'an unpriced model stops being a failure'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = 'deployed but unpriced'
       To    = 'some models' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the resource group is created blind again'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'az group show -n $ResourceGroup --query location'
       To    = 'az group show -n $ResourceGroup --query name' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a mismatched region stops being mentioned'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'using a different group name'
       To    = 'carrying on' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a failed group create is reported as success'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'Could not create resource group'
       To    = 'Created resource group' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'LLM logging is turned off at the API'
       File  = 'infra/main.bicep'
       From  = 'largeLanguageModel: {'
       To    = 'notTheLlmDiagnostic: {' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the ledger rows stop reaching the workspace'
       File  = 'infra/main.bicep'
       From  = "category: 'GatewayLlmLogs'"
       To    = "category: 'GatewayLogs'" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'daily allowances stop being compared to the ceiling'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = "Add-Result 'Ceiling headroom'"
       To    = "Add-Result 'Something else'" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the headroom days stop being worked out'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = '$days = [math]::Round($orgMonth / $perDay, 1)'
       To    = '$days = 999' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'over-subscription becomes a hard failure'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = "Add-Result 'Ceiling headroom' 'warn' ``"
       To    = "Add-Result 'Ceiling headroom' 'fail' ``" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'an unreachable unit budget stops being a failure'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = "Add-Result 'Organisation ceiling' 'fail'"
       To    = "Add-Result 'Organisation ceiling' 'warn'" }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the ceiling sum counts teams twice'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = '$top = @($reg | Where-Object { -not $par[$_.Id] })'
       To    = '$top = @($reg)' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'setting a budget stops checking the ceiling'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'ceiling is smaller than what the units are allowed'
       To    = 'ceiling note suppressed' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the budget warning counts teams twice'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = '$topLevel = @($registry | Where-Object { -not $parents[$_.Id] })'
       To    = '$topLevel = @($registry)' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the health check stops exiting non-zero'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = 'if ($failed.Count) { exit 1 }'
       To    = 'if ($false) { exit 1 }' }

    @{ Suite = 'Test-ModelsAndPlugins.ps1'
       Name  = 'the health check starts writing state'
       File  = 'scripts/Test-ClaudeHealth.ps1'
       From  = 'Nothing is written'
       To    = 'Set-ApimNamedValue is used here' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the guide stops saying the sync must be scheduled'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'sync is not automatic'
       To    = 'sync runs on its own' }

    # --- P24/P27, the Observe half ---

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the client is no longer captured'
       File  = 'infra/policy.xml'
       From  = '<metadata name="Client"'
       To    = '<metadata name="ClientDisabled"' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the agent string stops being bounded'
       File  = 'infra/policy.xml'
       From  = 'ua.Length > 120 ? ua.Substring(0, 120) : ua'
       To    = 'ua' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the surface goes back to a hard-coded list'
       File  = 'analytics/chargeback-ledger.kql'
       From  = 'coalesce(extract(@"\(external,\s*([^)]+)\)", 1, client_raw), "claude-cli")'
       To    = '"cli"' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the publisher stops refusing a missing window line'
       File  = 'scripts/Publish-ClaudeQueries.ps1'
       From  = 'cannot become a parameter'
       To    = 'is fine actually' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook stops checking its functions exist'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = 'does not have'
       To    = 'is missing maybe' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook drops the cache caveat'
       File  = 'infra/workbook.json'
       From  = '38.7'
       To    = '0.0' }

    # Money. ADR-0010: categories priced separately, never summed before pricing.
    @{ Suite = 'Test-Observability.ps1'
       Name  = 'cache read is priced at the full input rate'
       File  = 'analytics/chargeback-cost.kql'
       From  = 'let cache_read_multiplier = 0.1;'
       To    = 'let cache_read_multiplier = 1.0;' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'an unpriced model is costed at zero'
       File  = 'analytics/chargeback-cost.kql'
       From  = 'priced_ok = isnotnull(input_per_m)'
       To    = 'priced_ok = true' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'spend stops following today s membership'
       File  = 'analytics/chargeback-cost.kql'
       From  = 'business_unit = coalesce(iff(unit_now'
       To    = 'business_unit = coalesce(iff(false' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'cache is spread across client surfaces'
       File  = 'analytics/chargeback-cost.kql'
       From  = 'client_surface = "cache (no surface)"'
       To    = 'client_surface = "claude-cli"' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the price table stops being generated'
       File  = 'analytics/chargeback-cost.kql'
       From  = '// PRICE-BOOK-BEGIN'
       To    = '// PRICE-BOOK-PASTED' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the publisher stops refusing a missing marker'
       File  = 'scripts/Publish-ClaudeQueries.ps1'
       From  = 'cannot be generated'
       To    = 'was skipped' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'membership failure degrades instead of refusing'
       File  = 'scripts/Publish-ClaudeQueries.ps1'
       From  = 'business unit membership could not be read'
       To    = 'membership was skipped' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the money workbook drops the list price caveat'
       File  = 'infra/workbook-chargeback.json'
       From  = 'higher than shown, never lower'
       To    = 'accurate to the invoice' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the money workbook stops showing developers'
       File  = 'infra/workbook-chargeback.json'
       From  = 'by Developer = actor'
       To    = 'by Developer = tier' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'a tiles section goes back to one row of columns'
       File  = 'infra/workbook-chargeback.json'
       From  = '"titleContent": { "columnMatch": "Metric", "formatter": 1 },'
       To    = '' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the usage workbook loses its tile mapping'
       File  = 'infra/workbook.json'
       From  = '"titleContent": { "columnMatch": "Metric", "formatter": 1 },'
       To    = '' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook path stops being resolved'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = '$WorkbookFile = (Resolve-Path $WorkbookFile).ProviderPath'
       To    = '$WorkbookFile = $WorkbookFile' }

    # Both halves of the "no workspace selected" bug.
    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook is sourced from a REST url again'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = 'sourceId       = $workspaceArmId'
       To    = 'sourceId       = $workspaceId' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'tiles stop being bound to the workspace'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = "-NotePropertyName 'crossComponentResources' -NotePropertyValue @(`$workspaceArmId)"
       To    = "-NotePropertyName 'unusedBinding' -NotePropertyValue @(`$workspaceArmId)" }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'a workbook binding nothing publishes anyway'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = 'no tile targeting a Log Analytics workspace'
       To    = 'nothing to bind, continuing' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an overriding settings file goes unnoticed'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Nothing overrides the settings just checked'
       To    = 'The settings file was read' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the project-local override stops being looked for'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "What = 'project (local)'"
       To    = "What = 'ignored'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the precedence order stops being spelled out'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Lowest to highest: ~/.claude/settings.json'
       To    = 'Several files may apply' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the FAQ drops the settings override'
       File  = 'DEVELOPER.md'
       From  = 'I fixed my settings and Claude Code still uses the old model'
       To    = 'My settings changed' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'configured model names stop being checked'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Every configured model exists on the resource'
       To    = 'Model names are configured' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the available list is exempt from that check'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "Where = 'availableModels'"
       To    = "Where = 'ignored'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an invented name stops being named'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = '$($i.Where) = $($i.Name)'
       To    = 'one or more names are wrong' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the credential chain can no longer be pinned'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'AZURE_TOKEN_CREDENTIALS'
       To    = 'AZURE_TOKEN_UNUSED' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the expiring token override stops being warned against'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'expires in about an hour'
       To    = 'lasts indefinitely' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an existing credential pin is overwritten'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "GetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'User')"
       To    = "GetEnvironmentVariable('NOTHING_AT_ALL', 'User')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the guide drops the credential-chain citation'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'credential-chains#defaultazurecredential-overview'
       To    = 'credential-chains' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the check only looks in the active subscription'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'function Find-FoundryAccount'
       To    = 'function Find-FoundryAccountUnused' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'discovery switches the CLI context behind your back'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "Changing someone's CLI context as a side"
       To    = "Switching context here is fine as a side" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the deployment lookup stops naming its subscription'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "depSub = @('--subscription'"
       To    = "depSub = @('--output'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the admin check stops pinning later calls'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = '-g $ResourceGroup @subPin'
       To    = '-g $ResourceGroup' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the admin check repairs without asking'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = 'Re-run with -Fix to apply these'
       To    = 'Repairs were applied automatically' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a repair no longer shows its command'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = '      $($r.Command)'
       To    = '      (details hidden)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the admin check starts repairing network posture'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = 'security decision, not a configuration fault'
       To    = 'repaired here as well' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the developer check stops resolving the endpoint'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'The endpoint name resolves'
       To    = 'The endpoint name looks plausible' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a stale session stops being offered a refresh'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'az account clear; az login --tenant'
       To    = 'az login --tenant' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'propagation stops being named after a grant'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'granted recently, it can take a few minutes'
       To    = 'granted, it applies at once' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the admin check accepts an OpenAI-scoped role'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = "acts -contains 'Microsoft.CognitiveServices/*'"
       To    = "acts -match 'Microsoft.CognitiveServices'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the admin check counts disabled deployments as usable'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = "provisioningState -eq 'Succeeded'"
       To    = "provisioningState -ne 'Nonsense'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'person-by-person entitlement stops being flagged'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = 'granted person by person'
       To    = 'granted directly' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the admin check stops looking at network reachability'
       File  = 'scripts/Test-FoundryDirectAdmin.ps1'
       From  = 'publicNetworkAccess'
       To    = 'provisioningState' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Sonnet alias goes unset on an Opus-only resource'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'ANTHROPIC_DEFAULT_SONNET_MODEL''] = if ($sonnet) { $sonnet } else { $fallback }'
       To    = 'ANTHROPIC_DEFAULT_SONNET_MODEL''] = $sonnet' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a substituted alias stops being reported'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'those aliases point at $fallback'
       To    = 'aliases resolved' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check invents a model name again'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'will not invent a name'
       To    = 'falls back to claude-sonnet-5' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the round trip runs without a discovered model'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'if ($token -and $Model) {'
       To    = 'if ($token) {' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check stops running the Desktop helper'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Desktop helper returns a token'
       To    = 'Desktop helper is present' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the helper is no longer run without the CLI on PATH'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'and without the CLI on PATH'
       To    = 'and again for luck' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the tenant variable stops being checked'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Desktop helper knows its tenant'
       To    = 'Desktop helper tenant, informational' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the model list is claimed to refuse rather than substitute'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'an unlisted model is substituted, not served'
       To    = 'an unlisted model is refused' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a gateway machine cannot be declared expected'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "[ValidateSet('direct', 'gateway')][string]`$Expect = 'direct'"
       To    = "[string]`$Expect = 'direct'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a missing VS Code config is silently omitted again'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'No user settings file at'
       To    = 'skipped:' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the helper goes back to trusting PATH'
       File  = 'scripts/get-foundry-token.ps1'
       From  = "Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
       To    = "az.cmd" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the missing-CLI message stops naming the restart'
       File  = 'scripts/get-foundry-token.ps1'
       From  = 'quit Claude Desktop completely'
       To    = 'install the Azure CLI' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a missing helper still configures Desktop'
       File  = 'scripts/Setup-ClaudeWorkstation.ps1'
       From  = 'if (Test-Path $helperCmd) {'
       To    = 'if ($true) {' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the shim points at the wrong install directory'
       File  = 'scripts/get-foundry-token.cmd'
       From  = '%LOCALAPPDATA%\ClaudeFoundry\'
       To    = 'C:\ProgramData\claude\' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the gateway loses its device-code option'
       File  = 'scripts/Setup-ClaudeWorkstation.ps1'
       From  = "loginArgs += '--use-device-code'"
       To    = "loginArgs += '-o none'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the helper loses its device-code option'
       File  = 'scripts/get-foundry-token.ps1'
       From  = 'CLAUDE_FOUNDRY_AUTH'
       To    = 'CLAUDE_FOUNDRY_UNUSED' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the OAuth scope reverts to the Graph default'
       File  = 'DEVELOPER.md'
       From  = 'https://cognitiveservices.azure.com/.default offline_access' 
       To    = 'openid profile email offline_access' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the direct path installs a second helper directory'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = "Join-Path `$env:LOCALAPPDATA 'ClaudeFoundry'"
       To    = "Join-Path `$env:USERPROFILE '.claude-foundry'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the developer guide loses the device-code 400'
       File  = 'DEVELOPER.md'
       From  = 'Foundry Entra device init failed'
       To    = 'Desktop connection failed' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the developer guide blames the 400 on a role'
       File  = 'DEVELOPER.md'
       From  = 'no role assignment can fix it'
       To    = 'ask for the missing role' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the device-code 400 is blamed on RBAC'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'No role assignment can fix this'
       To    = 'Grant the missing role' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the public-client toggle is dropped'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'isFallbackPublicClient'
       To    = 'signInAudience' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'diagnostics is folded back into the model list'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = '## 4. Diagnostics'
       To    = '### More about models' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check stops naming the principal'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Token belongs to a signed-in user'
       To    = 'Token acquired' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check accepts an OpenAI-scoped role'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "acts -contains 'Microsoft.CognitiveServices/*'"
       To    = "acts -match 'Microsoft.CognitiveServices'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check stops checking device-code init'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'oauth2/v2.0/devicecode'
       To    = 'oauth2/v2.0/token' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a gateway machine is reported as being on the direct path'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'not the direct path'
       To    = 'direct path' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an OpenAI-scoped role is accepted as data-capable'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = "actions -contains 'Microsoft.CognitiveServices/*'"
       To    = "actions -match 'Microsoft.CognitiveServices'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the OpenAI role trap is dropped from the guide'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = '| Azure AI Developer |'
       To    = '| Some Other Role |' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the group assignment loses its principal type'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = '--assignee-principal-type Group'
       To    = '--assignee-type Group' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'project scope stops being called out'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'Scope it at the account'
       To    = 'Scope it anywhere convenient' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the access check moves back after the write'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = "Step 'Access check'"
       To    = "Step 'Round trip'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a failed access check writes the settings anyway'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'Nothing was written. This machine is unchanged.'
       To    = 'Settings were still written.' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a refusal goes back to a list of maybes'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'function Resolve-FoundryDenial'
       To    = 'function Show-PossibleCauses' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the required role is hardcoded again'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'permissions[0].dataActions'
       To    = 'permissions[0].actions' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a 404 is treated as an authorisation failure'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'Authentication succeeded.'
       To    = 'Authorisation failed.' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Desktop is configured under a running instance'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'Close it and continue'
       To    = 'Continue anyway' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'declining to close Desktop configures it regardless'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'Left running. Desktop was not configured'
       To    = 'Left running. Writing anyway' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Desktop is pointed at a gateway instead of the resource'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'inferenceGatewayBaseUrl                       = $baseUrl'
       To    = 'inferenceGatewayBaseUrl                       = $GatewayUrl' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'developer mode is decided by the file existing'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = '$devDoc -and $devDoc.allowDevTools -eq $true'
       To    = '$devDoc' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the gateway path trusts the file existing too'
       File  = 'scripts/Setup-ClaudeWorkstation.ps1'
       From  = '$devDoc -and $devDoc.allowDevTools -eq $true'
       To    = '$devDoc' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the wrong-tenant cause is demoted below the role'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'No `AZURE_TENANT_ID`, and the resource is in another tenant'
       To    = 'You are missing a role' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an empty resource list is read as a missing role'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'empty list does not prove the tenant is wrong'
       To    = 'you lack a role on it' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the credential chain order stops being stated'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'sit ahead of the Azure CLI in it'
       To    = 'are considered alongside the Azure CLI' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'availableModels stops being deployment names'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'availableModels holds deployment names, not model names'
       To    = 'availableModels lists the Claude models you may use' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'discovery stops asking for the model'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'model:properties.model.name'
       To    = 'model:name' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'aliases go back to matching the deployment name'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = '$_.model -and $_.model -match $Family'
       To    = '$false' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a real haiku deployment stops being preferred'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'if ($haiku)  { $haiku }  else { $fallback }'
       To    = 'if ($false)  { $haiku }  else { $fallback }' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a missing deployment list is assumed instead of refused'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'throw "Cannot configure $Resource without knowing'
       To    = '$Models = @(''claude-sonnet-5''); Note "Cannot configure $Resource without knowing' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the VS Code settings path is dropped from the direct guide'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = '%APPDATA%\Code\User\settings.json'
       To    = 'the usual place' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the two settings.json files stop being distinguished'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'different file** in a'
       To    = 'same file in a' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Settings UI stops being ruled out'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'not the Settings UI'
       To    = 'or the Settings UI' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the state file stops being marked as not configuration'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'Not configuration; do not hand-edit'
       To    = 'Edit it if you need to' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the gateway appendix loses the VS Code path'
       File  = 'DEVELOPER.md'
       From  = '%APPDATA%\Code\User\settings.json'
       To    = 'your VS Code settings' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the VS Code setting is shown as a map'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'array of name/value objects'
       To    = 'map of names to values' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the manual steps drop the role assignment'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'Cognitive Services User'
       To    = 'Reader' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the reload after changing VS Code settings is dropped'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'Developer: Reload Window'
       To    = 'it applies immediately' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the gateway appendix goes back to implying duplication'
       File  = 'DEVELOPER.md'
       From  = '"claudeCode.environmentVariables": ['
       To    = 'VS Code needs the same values again: [' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a gateway config is applied as a direct one'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'looks like a gateway config'
       To    = 'will be treated as direct' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the config file loses its mode tag'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = "mode            = 'foundry-direct'"
       To    = "note            = 'foundry-direct'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the guide stops saying the file holds no credential'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'Nothing in the file is a credential'
       To    = 'Treat the file as a credential' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the direct path sets a base url instead of the resource'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'ANTHROPIC_FOUNDRY_RESOURCE = $Resource'
       To    = 'ANTHROPIC_FOUNDRY_BASE_URL = $Resource' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a disabled deployment is offered as a model'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = "properties.provisioningState=='Succeeded'"
       To    = "properties.provisioningState!='Nothing'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the wrong tenant is accepted'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = "throw 'Wrong tenant.'"
       To    = "Note 'Tenant differs, continuing'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the direct guide stops naming the bypass audit'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'Get-ClaudeBypass.ps1'
       To    = 'some other script' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check finding is called a false positive'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'correct rather than a false positive'
       To    = 'a false positive' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'suppressing the finding becomes an option'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'does not work is suppressing'
       To    = 'also works is suppressing' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the direct guide claims group removal revokes'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'remove the role assignment'
       To    = 'remove them from the group' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the declared population is never checked against the store'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'This holds about {0} developers today'
       To    = 'Sizing looks fine for {0} developers' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the ceiling becomes a pasted number in the installer'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '$buCeiling = [int][math]::Floor(($maxChars - 1) / 44)'
       To    = '$buCeiling = 93' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a bigger SKU is offered as the fix for the ceiling'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'raising the SKU does not move it'
       To    = 'a larger SKU raises it' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the revocation window goes back to being documented'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'Revocation window in minutes'
       To    = 'Cache seconds' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the options stop being costed at their scale'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '-Developers $devCount -CacheMinutes'
       To    = '-Developers 500000 -CacheMinutes' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'stop is offered without saying it triggers late'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'triggers far later than the dollars suggest'
       To    = 'refuses at the figure you set' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the address choice loses its consequence'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'expensive to change afterwards'
       To    = 'easy to change later' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the unassigned answer stops reaching the template'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'buUnassigned=$(if ($unassignedMode)'
       To    = 'buUnassignedUnused=$(if ($unassignedMode)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the SKU reversibility note disappears'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'can be changed later: BasicV2 and StandardV2'
       To    = 'is fine: BasicV2 and StandardV2' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'active developers stop scaling with the population'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '$Developers * 0.1'
       To    = '50000' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'more active developers than developers is costed anyway'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = 'is larger than Developers'
       To    = 'was noted against Developers' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a migration step loses its rollback'
       File  = 'docs/SCALE.md'
       From  = '**Rollback:** set it back to `named-value`'
       To    = 'Once flipped, it is flipped' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the lists are deleted before the watch period'
       File  = 'docs/SCALE.md'
       From  = 'Until then they are your rollback'
       To    = 'They can be removed at any point' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the comparison stops gating the flip'
       File  = 'docs/SCALE.md'
       From  = 'Run the comparison until it reports nothing'
       To    = 'Optionally run the comparison' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the decisions page hides what cannot be deferred'
       File  = 'docs/DECISIONS.md'
       From  = 'The two that are expensive to defer'
       To    = 'Some other settings' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the budget page drops the measured cache gap'
       File  = 'docs/DECISIONS.md'
       From  = '38.7%'
       To    = '1.1' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the entitlement source switch disappears'
       File  = 'infra/policy.xml'
       From  = '{{entitlement-source}}'
       To    = '{{allow-standard}}' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the named-value path stops being guarded'
       File  = 'infra/policy.xml'
       From  = 'when condition="@(!(bool)context.Variables["entResolved"])"'
       To    = 'when condition="@(true)"' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a resolver outage is called a forbidden'
       File  = 'infra/policy.xml'
       From  = 'not a problem with your access'
       To    = 'you are not entitled' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the managed identity token failure reaches the developer'
       File  = 'infra/policy.xml'
       From  = 'context.Variables.ContainsKey("entResolving")'
       To    = 'context.Variables.ContainsKey("neverSet")' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the resolver audience collapses into the url'
       File  = 'infra/policy.xml'
       From  = 'resource="{{entitlement-resolver-audience}}"'
       To    = 'resource="{{entitlement-resolver-url}}"' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the switch defaults to the projection'
       File  = 'infra/main.bicep'
       From  = "param entitlementSource string = 'named-value'"
       To    = "param entitlementSource string = 'projection'" }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'a redeploy silently un-migrates the gateway'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'named-value-id entitlement-source --query value'
       To    = 'named-value-id bu-parents --query value' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the Basic v2 networking floor is dropped'
       File  = 'docs/adr/0013-gateway-outlives-instance.md'
       From  = 'Basic v2 cannot run the design in ADR-0011 at any size'
       To    = 'Basic v2 is fine for small deployments' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'Premium v2 is credited with multi-region'
       File  = 'docs/adr/0013-gateway-outlives-instance.md'
       From  = 'Premium v2 does not do multi-region'
       To    = 'Premium v2 does multi-region' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the custom domain recommendation disappears'
       File  = 'docs/adr/0013-gateway-outlives-instance.md'
       From  = 'custom domain, never the instance hostname'
       To    = 'instance hostname' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the entitlement switch stops being configuration'
       File  = 'docs/adr/0013-gateway-outlives-instance.md'
       From  = 'entitlement-source'
       To    = 'a later policy change' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'billing continuity stops being stated'
       File  = 'docs/adr/0013-gateway-outlives-instance.md'
       From  = 'counter key is the object id, and it does not change'
       To    = 'counter key may be revisited' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the scale guide loses the first-day decisions'
       File  = 'docs/SCALE.md'
       From  = 'Two things to get right on the first day'
       To    = 'Some notes' }

    @{ Suite = 'Test-Scale.ps1'
       Name  = 'the status page calls P19 finished'
       File  = 'docs/STATUS.md'
       From  = 'Not finished'
       To    = 'Delivered' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the Desktop gateway sign-in step disappears'
       File  = 'DEVELOPER.md'
       From  = 'Or sign in with Gateway'
       To    = 'Sign in' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the warning off Google and email is dropped'
       File  = 'DEVELOPER.md'
       From  = 'Do not use'
       To    = 'You may also use' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'a running Desktop is said to be fine'
       File  = 'DEVELOPER.md'
       From  = 'Quit Desktop completely'
       To    = 'Leave Desktop running' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the developer FAQ disappears'
       File  = 'DEVELOPER.md'
       From  = '## FAQ'
       To    = '## Notes' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'chargeback jargon returns to the developer guide'
       File  = 'DEVELOPER.md'
       From  = 'so your organisation can allocate its'
       To    = 'in chargeback' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook stops splitting by client'
       File  = 'infra/workbook.json'
       From  = 'client_surface'
       To    = 'model' }

    # --- P29, backup and restore ---

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the backup starts reading secret values'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = '$apim/namedValues?api-version=2024-05-01'
       To    = '$apim/namedValues/x/listValue?api-version=2024-05-01' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the backup stops fetching workbook content'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = 'canFetchContent=true'
       To    = 'canFetchContent=false' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the restore stops being a dry run'
       File  = 'scripts/Restore-ClaudeGateway.ps1'
       From  = 'if (-not $Apply) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the history restore stops being a dry run'
       File  = 'scripts/Restore-ClaudeCode.ps1'
       From  = 'if (-not $Apply) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the restore stops refusing another gateway'
       File  = 'scripts/Restore-ClaudeGateway.ps1'
       From  = 'Add -Force if you mean it'
       To    = 'carrying on' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the history backup stops excluding the credential file'
       File  = 'scripts/Backup-ClaudeCode.ps1'
       From  = 'oauth, key and token'
       To    = 'nothing much' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'config credentials stop blocking the backup'
       File  = 'scripts/Backup-ClaudeCode.ps1'
       From  = "Scan = 'block'"
       To    = "Scan = 'report'" }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the history restore stops refusing to overwrite'
       File  = 'scripts/Restore-ClaudeCode.ps1'
       From  = 'already have files on disk'
       To    = 'are present' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the installer stops offering a business unit'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "Write-Step 'Business units (optional)'"
       To    = "Write-Step 'Skipped'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an unattended install starts inventing business units'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "if (-not `$Yes) {`r`n    Write-Step 'Business units (optional)'"
       To    = "if (`$true) {`r`n    Write-Step 'Business units (optional)'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a business unit can point at a group that does not exist'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'az ad group create --display-name $buGroup'
       To    = 'echo skip #' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the unit identifier stops being validated'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "`$buId -notmatch '^[a-z0-9][a-z0-9-]*`$'"
       To    = '$false' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the console stops syncing after a change'
       File  = 'scripts/Manage-ClaudeBusinessUnits.ps1'
       From  = 'function Complete-Change'
       To    = 'function Complete-Nothing' }

    # The bug this pair was written for: a Test-Path guard turns a wrong helper
    # name into silence, so the console ran for a whole session with no banner
    # and nothing failed.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the console dot-sources a banner that is not there'
       File  = 'scripts/Manage-ClaudeBusinessUnits.ps1'
       From  = "Join-Path `$PSScriptRoot 'Show-Banner.ps1'"
       To    = "Join-Path `$PSScriptRoot 'ClaudeBanner.ps1'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the console asks for a variant the banner rejects'
       File  = 'scripts/Manage-ClaudeBusinessUnits.ps1'
       From  = 'Show-ClaudeBanner -Variant console'
       To    = 'Show-ClaudeBanner -Variant admin' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the banner stops choosing art by variant'
       File  = 'scripts/Show-Banner.ps1'
       From  = "`$art = if (`$Variant -eq 'console')"
       To    = "`$art = if (`$false)" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the console name shrinks back to an initialism'
       File  = 'scripts/Show-Banner.ps1'
       From  = "'Foundry Claude Management Console'"
       To    = "'C M C'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the console reimplements the write'
       File  = 'scripts/Manage-ClaudeBusinessUnits.ps1'
       From  = "'Set-ClaudeBusinessUnit.ps1'"
       To    = "'Nothing.ps1'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'one mistyped value ends the session'
       File  = 'scripts/Manage-ClaudeBusinessUnits.ps1'
       From  = 'That did not work'
       To    = 'Fatal' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an unsynced change leaves quietly'
       File  = 'scripts/Manage-ClaudeBusinessUnits.ps1'
       From  = 'Sync before leaving'
       To    = 'Goodbye' }

    # --- P30-P32 and the workstation tool ---

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the SKU suggestion loses its basis'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'v2-service-tiers-overview'
       To    = 'some-blog-post' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the SKU stops being overridable'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "Read-Default -Prompt 'API Management SKU' -Default `$suggested"
       To    = "`$suggested # (" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the group is no longer verified'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'az ad group show --group $Group'
       To    = 'echo skip #' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'tier models stop being checked against deployments'
       File  = 'scripts/Set-ClaudeTier.ps1'
       From  = 'Not deployed on'
       To    = 'Probably fine on' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a third tier is silently accepted'
       File  = 'scripts/Set-ClaudeTier.ps1'
       From  = "ValidateSet('standard', 'premium')"
       To    = "ValidateSet('standard', 'premium', 'lite')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Desktop backup stops refusing a running app'
       File  = 'scripts/Backup-ClaudeDesktop.ps1'
       From  = 'holds its conversation database open'
       To    = 'is busy' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Desktop backup starts copying the VM images'
       File  = 'scripts/Backup-ClaudeDesktop.ps1'
       From  = "'vm_bundles'     = 'virtual machine images, reinstallable - 10.6 GB measured'"
       To    = "'nothing_much'   = 'x'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Desktop backup stops reporting unreadable files'
       File  = 'scripts/Backup-ClaudeDesktop.ps1'
       From  = 'unreadable'
       To    = 'skipped-quietly' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the developer script writes to the gateway instead of Entra'
       File  = 'scripts/Set-ClaudeDeveloper.ps1'
       From  = 'groups/$groupId/members'
       To    = 'namedValues/allow' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'removal stops clearing business units'
       File  = 'scripts/Set-ClaudeDeveloper.ps1'
       From  = 'Every unit is cleared'
       To    = 'Only some are cleared' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'membership goes back to the transitive check'
       File  = 'scripts/Set-ClaudeDeveloper.ps1'
       From  = '/memberOf?'
       To    = '/checkMemberObjects?' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'query values stop being URL-encoded'
       File  = 'scripts/Set-ClaudeDeveloper.ps1'
       From  = 'eq%20''$enc'''
       To    = 'eq%20''$q''' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the migration tool stops warning about the empty Desktop'
       File  = 'scripts/Migrate-ClaudeWorkstation.ps1'
       From  = 'empty Desktop'
       To    = 'fresh start' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the BOM stops reading the live deployment'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'az resource list'
       To    = 'echo static #' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the BOM stops separating reused from created'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'Reused, not created'
       To    = 'Other things' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the diagram loses the real log table name'
       File  = 'guide/render-architecture.mjs'
       From  = 'ApiManagementGatewayLlmLog'
       To    = 'the API log' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Grafana stops declaring its standing cost'
       File  = 'scripts/Publish-ClaudeGrafana.ps1'
       From  = 'per instance per hour'
       To    = 'per use' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Grafana starts creating the instance'
       File  = 'scripts/Publish-ClaudeGrafana.ps1'
       From  = 'does not create a Grafana instance'
       To    = 'will create a Grafana instance' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Grafana panels stop reusing the saved function'
       File  = 'scripts/Publish-ClaudeGrafana.ps1'
       From  = 'ClaudeChargeback($__timeFrom, $__timeTo)'
       To    = 'ApiManagementGatewayLlmLog' }

    # Pricing. Every one of these turns a known price into a wrong price or a
    # missing price into an apparent zero, which is the only way this feature
    # does harm: a bill of materials that under-reports is worse than one that
    # declines to quote.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the silent contains() trap stops being recorded'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'contains() is not supported and does not error'
       To    = 'contains() works fine' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Free Tier shadow stops being recorded'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'A Free Tier row shadows the real meter'
       To    = 'Each meter is published once' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'free-tier rows are no longer excluded'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = "notlike '*Free*'"
       To    = "notlike '*NeverMatches*'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the tiered-meter trap stops being recorded'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'Tiered meters start at zero'
       To    = 'Meters have one price' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the caller can no longer choose the tier'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = "[ValidateSet('Marginal', 'First')]"
       To    = '[AllowNull()]' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a missed lookup stops promising not to return zero'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'It never returns 0'
       To    = 'It returns 0' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an empty result unrolls to null again'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'return , $items'
       To    = 'return $items' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the comma-operator reason is dropped'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'Returned with the comma operator'
       To    = 'Returned directly' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the module stops saying Claude is not in the API'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = 'Claude token rates are NOT in this API'
       To    = 'Claude token rates are in this API' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the bill of materials loses its price switch'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = '[switch]$WithPrices'
       To    = '[switch]$Unused' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'prices stop following the region deployed into'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'az group show -n $ResourceGroup --query location'
       To    = 'az account show --query location' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Cosmos is priced by SKU instead of capability'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = "$_.name -eq 'EnableServerless'"
       To    = "$_.name -eq 'Standard'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the ARM-to-meter SKU spelling note is dropped'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'spell the same SKU differently'
       To    = 'agree on SKU names' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an unpriced line stops saying so'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'rate unknown'
       To    = 'no charge' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the JSON total stops excluding Claude tokens'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'not priced here'
       To    = 'fully priced' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the monthly basis stops being stated'
       File  = 'scripts/Get-ClaudeBom.ps1'
       From  = 'month at 730 h'
       To    = 'month' }

    # Network access. The allowlist is the one artefact here that a third party
    # acts on directly, so each claim has to be shown to be load-bearing.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the network check stops testing the measured host'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = '$FoundryResource.services.ai.azure.com'
       To    = '$FoundryResource.cognitiveservices.azure.com' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'reachability is treated as working again'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = 'Reachability is not the same as working'
       To    = 'Reachability is what matters' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the round trip stops streaming'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = '"stream":true'
       To    = '"stream":false' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the client buffers the stream it is testing'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = '--no-buffer'
       To    = '--silent' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a reset stops being told from a block'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = "Verdict = 'reset'"
       To    = "Verdict = 'blocked'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a reset is blamed on the allowlist again'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = 'This is not an allowlist problem'
       To    = 'Check the allowlist' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the fix asked for reverts to allowing'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = 'excluded from TLS inspection rather than merely allowed'
       To    = 'added to the allowlist' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an auth failure is blamed on the network'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = 'the network is fine; this is a role or a firewall'
       To    = 'the host is blocked' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the config silently overrides an explicit argument'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = "PSBoundParameters.ContainsKey('FoundryResource')"
       To    = "PSBoundParameters.ContainsKey('Nothing')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the path actually tested stops being named'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = '$roundTrip.TestedPath'
       To    = '$roundTrip.Verdict' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a dropped IMDS stops being told from a refused one'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = "Behaviour = 'dropped'"
       To    = "Behaviour = 'refused'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the credential pin reverts to a rejected value'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS','dev','User')"
       To    = "SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS','AzureCliCredential','User')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the guide reverts to the rejected value'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = "SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS','dev','User')"
       To    = "SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS','AzureCliCredential','User')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Cloud PC case stops being named'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = 'On a Cloud PC, a Dev Box or an Azure VM with a managed identity'
       To    = 'This is rare' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the audience trap is dropped from the network doc'
       File  = 'docs/NETWORK.md'
       From  = 'is a token audience, not an endpoint'
       To    = 'is the Foundry endpoint' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the azure-api.net suffix warning is dropped'
       File  = 'docs/NETWORK.md'
       From  = 'is not matched by any `*.azure.com` rule'
       To    = 'is covered by `*.azure.com`' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the extension is said to reuse the CLI on PATH'
       File  = 'docs/NETWORK.md'
       From  = 'It does **not** use the CLI on `PATH`'
       To    = 'It uses the CLI on `PATH`' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Desktop is presented as measured when it was not'
       File  = 'docs/NETWORK.md'
       From  = 'runtime egress was **not** captured live'
       To    = 'runtime egress was captured live' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the AppX loopback caveat disappears'
       File  = 'docs/NETWORK.md'
       From  = 'CheckNetIsolation LoopbackExempt'
       To    = 'netsh winhttp' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the observer is implied to read request bodies'
       File  = 'docs/NETWORK.md'
       From  = 'never terminates TLS'
       To    = 'decrypts each request' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the direct guide stops pointing at the network doc'
       File  = 'docs/FOUNDRY-DIRECT.md'
       From  = '**[NETWORK.md](NETWORK.md)**'
       To    = 'the network documentation' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the confirmation prices Basic v2 whatever was chosen'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "`$apimMeter = (`$Sku -replace 'V2`$', ' v2') + ' Unit'"
       To    = "`$apimMeter = 'Basic v2 Unit'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the confirmation prices the wrong region'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "-ServiceName 'API Management' -Region `$Location -MeterName `$apimMeter"
       To    = "-ServiceName 'API Management' -Region 'eastus' -MeterName `$apimMeter" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the overstated gateway price comes back'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'The $Sku price in $Location could not be read'
       To    = 'The $Sku price in $Location (about $250/month) could not be read' }

    # Show-Governance reported a healthy new gateway as failed. Each mutation
    # restores one of the causes; the lifted resolvers must go red.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the governance check assumes a model again'
       File  = 'scripts/Show-Governance.ps1'
       From  = '    [string]$Model,'
       To    = "    [string]`$Model = 'claude-sonnet-5'," }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the governance check ignores the caller''s tier'
       File  = 'scripts/Show-Governance.ps1'
       From  = '--named-value-id "models-$tier"'
       To    = '--named-value-id "models-standard"' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'an unrestricted tier finds no model'
       File  = 'scripts/Show-Governance.ps1'
       From  = "`$claude = @(`$deployments | Where-Object { `$_.name -like 'claude-*' } | Sort-Object name)"
       To    = '$claude = @()' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the metric query goes to the service-level component'
       File  = 'scripts/Show-Governance.ps1'
       From  = 'if ($api) { $paths += "/apis/$($api.name)/diagnostics/applicationinsights" }'
       To    = '' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a failed check hides which refusal it was'
       File  = 'scripts/Show-Governance.ps1'
       From  = '$code = if ($e.code) { $e.code } else { $e.type }'
       To    = '$code = $e.type' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'two statements are fused on one line again'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "Write-Host '   1. Entitle a developer'"
       To    = "Write-Host '   1. Entitle a developer'Write-Host ''" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the installer promises 30-45 minutes again'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "'API Management and Application Insights (a few minutes)'"
       To    = "'API Management and Application Insights (30-45 min)'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the installer blames the bill on one endpoint again'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'Most of that bills at rest - the private endpoints, their DNS zones and a'
       To    = 'Most of that is the private endpoint, and a' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the price library sets strict mode for its caller again'
       File  = 'scripts/AzureRetailPrice.ps1'
       From  = '# No Set-StrictMode here. This file is dot-sourced'
       To    = "Set-StrictMode -Version Latest`r`n# This file is dot-sourced" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'Graph paging reads nextLink as a property again'
       File  = 'scripts/ClaudeGraphMembership.ps1'
       From  = '$uri = if ($next) { $next.Value } else { $null }'
       To    = "`$uri = `$page.'@odata.nextLink'" }

    # The secure projection. Each mutation removes one control or restores one
    # defect measured on the live deployment; Test-SecureProjection.ps1 must go red.
    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the resolver stops requiring authentication'
       File  = 'infra/resolver.bicep'
       From  = 'requireAuthentication: true'
       To    = 'requireAuthentication: false' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'an unauthenticated caller is sent to a sign-in page'
       File  = 'infra/resolver.bicep'
       From  = "unauthenticatedClientAction: 'Return401'"
       To    = "unauthenticatedClientAction: 'RedirectToLoginPage'" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'any application in the tenant may call the resolver'
       File  = 'infra/resolver.bicep'
       From  = 'allowedApplications: allowedCallerAppIds'
       To    = 'allowedApplications: []' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the resolver storage accepts keys again'
       File  = 'infra/resolver.bicep'
       From  = 'allowSharedKeyAccess: false'
       To    = 'allowSharedKeyAccess: true' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'telemetry accepts unauthenticated senders'
       File  = 'infra/resolver.bicep'
       From  = 'DisableLocalAuth: true'
       To    = 'DisableLocalAuth: false' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the resolver is given write access'
       File  = 'infra/resolver.bicep'
       From  = "cosmosDataReader = '00000000-0000-0000-0000-000000000001'"
       To    = "cosmosDataReader = '00000000-0000-0000-0000-000000000002'" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the resolver can read the whole account'
       File  = 'infra/resolver.bicep'
       From  = "scope: '`${cosmos.id}/dbs/`${databaseName}/colls/`${containerName}'"
       To    = 'scope: cosmos.id' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a private resolver keeps a public endpoint'
       File  = 'infra/resolver.bicep'
       From  = "publicNetworkAccess: isPrivate ? 'Disabled' : 'Enabled'"
       To    = "publicNetworkAccess: 'Enabled'" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the resolver subnet gets the Premium-plan delegation'
       File  = 'infra/projection-network.bicep'
       From  = "serviceName: 'Microsoft.App/environments'"
       To    = "serviceName: 'Microsoft.Web/serverFarms'" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'an existing VNet is ignored and a new one created'
       File  = 'infra/projection-network.bicep'
       From  = 'var createVnet = empty(vnetId)'
       To    = 'var createVnet = true' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a missing record becomes an outage again'
       File  = 'infra/policy.xml'
       From  = 'StatusCode == 404)'
       To    = 'StatusCode == 418)' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a refusal is cached for an hour'
       File  = 'infra/policy.xml'
       From  = 'Math.Min(60, int.Parse'
       To    = 'Math.Max(3600, int.Parse' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'an export asks for a Cosmos token it cannot use'
       File  = 'scripts/Sync-ClaudeProjection.ps1'
       From  = 'if (-not $ExportPath) {'
       To    = 'if ($true) {' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the projection charges the last business unit again'
       File  = 'scripts/Sync-ClaudeProjection.ps1'
       From  = 'if (-not $assigned.ContainsKey($m.Oid)) { $byOid[$m.Oid].BusinessUnit = $u.Id; $assigned[$m.Oid] = $true }'
       To    = '$byOid[$m.Oid].BusinessUnit = $u.Id' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the projection ignores team depth'
       File  = 'scripts/Sync-ClaudeProjection.ps1'
       From  = '$units = @(Sort-ClaudeBuByDepth $registry -Parents $parents)'
       To    = '$units = @($registry)' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'units at one depth lose registry order'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = "Sort-Object -Property @{ Expression = 'Depth'; Descending = `$true }, @{ Expression = 'Position'; Ascending = `$true }"
       To    = "Sort-Object -Property @{ Expression = 'Depth'; Descending = `$true }" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a snapshot is applied without validation'
       File  = 'sync/src/apply-projection.mjs'
       From  = 'const problems = validateSnapshot(snap, { tenantId });'
       To    = 'const problems = [];' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'a failed write is reported as ok'
       File  = 'sync/src/apply-projection.mjs'
       From  = 'ok: !(writes.failed || deletes.failed), '
       To    = '' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the in-network sync charges the last business unit'
       File  = 'sync/src/plan.mjs'
       From  = 'if (!assigned.has(m.oid)) { rec.businessUnit = unit.id; assigned.add(m.oid); }'
       To    = 'rec.businessUnit = unit.id;' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'an unreadable directory revokes everyone'
       File  = 'sync/src/plan.mjs'
       From  = 'if (resolved.length === 0 && existing.size > 0 && !allowEmpty) {'
       To    = 'if (false) {' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'Graph silently drops service principals'
       File  = 'sync/src/graph.mjs'
       From  = "ConsistencyLevel: 'eventual'"
       To    = "Prefer: 'none'" }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'files travel as plain base64 again'
       File  = 'scripts/ClaudeRunner.ps1'
       From  = ".Replace('+', '-').Replace('/', '_')"
       To    = '' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'chunks exceed the exec limit'
       File  = 'scripts/ClaudeRunner.ps1'
       From  = '4990 - $overhead'
       To    = '20000' }

    @{ Suite = 'Test-SecureProjection.ps1'
       Name  = 'the gateway decisions cannot be exported'
       File  = 'scripts/Compare-ClaudeEntitlement.ps1'
       From  = '[string]$ExportGatewayPath'
       To    = '[string]$ExportGatewayPathUnused' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the break-even advice uses the wrong price'
       File  = 'docs/COMPARISON.md'
       From  = 'the $150/month gateway'
       To    = 'the $250/month gateway' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the table stops naming which client needs what'
       File  = 'docs/NETWORK.md'
       From  = '| CLI | VS Code | Desktop |'
       To    = '| Needed by |' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'npm is claimed to be needed by every client'
       File  = 'docs/NETWORK.md'
       From  = '`registry.npmjs.org` | 443 | ✅ | — | —'
       To    = '`registry.npmjs.org` | 443 | ✅ | ✅ | ✅' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the marketplace is claimed to be needed by the CLI'
       File  = 'docs/NETWORK.md'
       From  = '`marketplace.visualstudio.com` | 443 | — | ✅ | —'
       To    = '`marketplace.visualstudio.com` | 443 | ✅ | ✅ | —' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'running stops being separated from installing'
       File  = 'docs/NETWORK.md'
       From  = '**Rows 1–3 are the only ones needed to *run***'
       To    = 'Every row is required' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the device-code order stops being stated'
       File  = 'docs/NETWORK.md'
       From  = 'before any token exists'
       To    = 'after the token is issued' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the network doc reverts to a rejected credential value'
       File  = 'docs/NETWORK.md'
       From  = 'takes **`dev`**, not a credential name'
       To    = 'takes a credential name' }

    # A Desktop that is configured correctly and will not open passed every
    # other check, because they all read files.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the health check stops testing that Desktop can start'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = "Add-Result 'Claude Desktop can start'"
       To    = "Add-Result 'Claude Desktop is installed'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the sharing violation stops being named'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'ERROR_SHARING_VIOLATION'
       To    = 'an unknown fault' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a running Desktop is reported as stuck'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = '$running.Count -eq 0'
       To    = '$running.Count -ge 0' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'reinstalling is offered as the remedy again'
       File  = 'scripts/Test-FoundryDirect.ps1'
       From  = 'Reinstalling does not help'
       To    = 'Reinstalling fixes it' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the lock owner goes back to needing handle.exe'
       File  = 'scripts/Get-FileLockOwner.ps1'
       From  = 'RmGetList'
       To    = 'RmGetListUnused' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a kernel-held file stops being explained'
       File  = 'scripts/Get-FileLockOwner.ps1'
       From  = 'locked, and no process owns it'
       To    = 'locked by something' }

    # Documentation evidence. A measured claim with no shown evidence is a
    # claim nobody checks.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the network doc loses its healthy screenshot'
       File  = 'docs/NETWORK.md'
       From  = '](guide/network-check.png)'
       To    = '](guide/missing.png)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the network doc loses its reset screenshot'
       File  = 'docs/NETWORK.md'
       From  = '](guide/network-reset.png)'
       To    = '](guide/missing.png)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the reset capture is no longer said to be real'
       File  = 'docs/NETWORK.md'
       From  = 'reproduced, not staged'
       To    = 'illustrative' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the two network asks are conflated again'
       File  = 'docs/NETWORK.md'
       From  = 'gets the ticket closed as'
       To    = 'is usually fine as' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the network doc drops its prerequisites'
       File  = 'docs/NETWORK.md'
       From  = 'necessary and not sufficient'
       To    = 'all you need' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the README stops showing the priced BOM'
       File  = 'README.md'
       From  = '](docs/guide/bom-prices.png)'
       To    = '](docs/guide/missing.png)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'redaction stops preserving column alignment'
       File  = 'scripts/Capture-Transcripts.ps1'
       From  = 'Same length as the original, deliberately'
       To    = 'Shortened for readability' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the cutting proxy is left running after capture'
       File  = 'scripts/Capture-Transcripts.ps1'
       From  = 'Stop-Process -Id $proxy.Id'
       To    = 'Write-Host $proxy.Id' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a blocked host renders the same as a reachable one'
       File  = 'scripts/render-terminal.mjs'
       From  = '/\bBLOCKED\b/.test(line)'
       To    = '/\bNEVERMATCHES\b/.test(line)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the reason for colouring verdicts is dropped'
       File  = 'scripts/render-terminal.mjs'
       From  = 'a failure that looks like a success'
       To    = 'colour is nice to have' }

    # Onboarding. The ordering is the feature: every one of these turns a
    # refusal into a machine that is configured and does not work.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a failed check no longer stops the write'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = 'Nothing has been written'
       To    = 'Continuing anyway' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the tenant stops being compared to the file'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = '$acct.tenantId -ne $cfg.tenantId'
       To    = '$false' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'onboarding reimplements the network check'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = "Join-Path `$scriptDir 'Test-ClaudeNetwork.ps1'"
       To    = "Join-Path `$scriptDir 'Nothing.ps1'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'onboarding stops verifying what it configured'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = "Join-Path `$scriptDir 'Test-FoundryDirect.ps1'"
       To    = "Join-Path `$scriptDir 'Nothing.ps1'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a reset is blamed on the allowlist during onboarding'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = 'Not an allowlist problem - every host above is reachable'
       To    = 'Check the allowlist' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the mode is guessed rather than read'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = '# Read the mode rather than guessing it'
       To    = '# Guess the mode' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a file that configures neither path is accepted'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = 'Cannot tell what this file configures'
       To    = 'Assuming gateway' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the other path becomes a required host again'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = 'would make an irrelevant'
       To    = 'is useful because it would make an important' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'onboarding pins a credential value the client rejects'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = "SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'dev', 'User')"
       To    = "SetEnvironmentVariable('AZURE_TOKEN_CREDENTIALS', 'AzureCliCredential', 'User')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the onboarding preflight stops being documented'
       File  = 'docs/ONBOARDING.md'
       From  = 'a proxy that cuts the response once it streams'
       To    = 'a network problem' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the onboarding screenshot is dropped'
       File  = 'docs/ONBOARDING.md'
       From  = '](guide/onboard-preflight.png)'
       To    = '](guide/missing.png)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the installer stops asking how developers sign in'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'How will developers sign in?'
       To    = 'Sign-in is configured per machine.' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the sign-in answer never reaches the handover file'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'authMode      = $AuthMode'
       To    = 'authModeUnused = $AuthMode' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the handover file stops saying what it is'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "mode          = 'gateway'"
       To    = "modeUnused    = 'gateway'" }

    # The three bugs the gateway-direct-gateway round trip exposed. Each one
    # produced an error naming something that was not wrong.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the gateway round trip loses its path again'
       File  = 'scripts/Test-ClaudeNetwork.ps1'
       From  = '[string]$GatewayUrl'
       To    = '[string]$GatewayUrlUnused' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'onboarding passes only the gateway host'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = "netArgs['GatewayUrl'] = `$cfg.gatewayUrl"
       To    = "netArgs['GatewayHost'] = `$cfg.gatewayUrl" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'setup arguments go back to positional splatting'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = '$setupArgs = @{ ConfigPath = $ConfigPath }'
       To    = '$setupArgs = @(''-ConfigPath'', $ConfigPath)' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the gateway is verified with the direct check again'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = "Join-Path `$scriptDir 'Debug-ClaudeCode.ps1'"
       To    = "Join-Path `$scriptDir 'Test-FoundryDirect.ps1'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a deliberately skipped client reads as a fault'
       File  = 'scripts/Onboard-ClaudeDeveloper.ps1'
       From  = 'was skipped at your request, so it still points where it did'
       To    = 'is misconfigured' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'redundancy stops being costed at all'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = '[switch]$CompareRedundancy'
       To    = '[switch]$CompareRedundancyUnused,' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'zone redundancy is presented as a published price'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = 'Derived at 1.25x provisioned'
       To    = 'Read from the price list' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the billing model change stops being the headline'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = 'The switch is the billing model, not a feature flag'
       To    = 'Redundancy is a setting' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a stale price is shown when the API is down'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = 'No figures are shown rather than stale ones'
       To    = 'Falling back to the table above' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the standing cost of provisioned is dropped'
       File  = 'scripts/Measure-ClaudeProjectionCost.ps1'
       From  = 'so an idle projection stops being free'
       To    = 'so it is much the same' }

    # A developer budget in money.
    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a developer budget can no longer be set in money'
       File  = 'scripts/Set-ClaudeBudget.ps1'
       From  = '[decimal]$DailyUsd'
       To    = '[decimal]$DailyUsdUnused,' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the dollar conversion is reimplemented locally'
       File  = 'scripts/Set-ClaudeBudget.ps1'
       From  = 'ConvertTo-ClaudeBuTokens -Usd $DailyUsd'
       To    = 'ConvertTo-SomethingElse -Usd $DailyUsd' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the cache blind spot is dropped from the budget prompt'
       File  = 'scripts/Set-ClaudeBudget.ps1'
       From  = 'counts prompt and completion only'
       To    = 'counts everything' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the direction of the budget error stops being stated'
       File  = 'scripts/Set-ClaudeBudget.ps1'
       From  = 'budget runs higher than the figure suggests'
       To    = 'budget is approximate' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the borrowed period name is taken on trust'
       File  = 'scripts/Set-ClaudeBudget.ps1'
       From  = 'TokensPerMonth is named for its first caller'
       To    = 'TokensPerMonth is monthly' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the developer guide loses its preflight'
       File  = 'DEVELOPER.md'
       From  = '-ConfigPath .\claude-gateway.json -PreflightOnly'
       To    = '-ConfigPath .\claude-gateway.json' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the streaming failure stops being named for developers'
       File  = 'DEVELOPER.md'
       From  = 'every prompt dies with `ECONNRESET`'
       To    = 'it fails' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a reset is routed to a firewall rule again'
       File  = 'DEVELOPER.md'
       From  = 'a proxy exclusion rather than a firewall rule'
       To    = 'a firewall rule' }

    # The backup chose its workspace by counting, so on a group holding three it
    # chose nothing and left out the functions both workbooks call.
    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the backup goes back to choosing a workspace by count'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = 'az monitor diagnostic-settings list --resource $apimResourceId'
       To    = 'az monitor diagnostic-settings list --resource $unused' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'a workspace in another group is taken as if it were local'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = '/resourceGroups/$([regex]::Escape($ResourceGroup))/providers/Microsoft\.OperationalInsights/workspaces/'
       To    = '/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'where the gateway writes stops being reported'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = 'and restore publishes into the gateway''s own group'
       To    = 'so it was skipped' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the backup stops saying how it chose the workspace'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = 'named by the gateway diagnostic setting'
       To    = 'chosen' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the empty-ledger trap drops out of troubleshooting'
       File  = 'docs/TROUBLESHOOTING.md'
       From  = 'is empty — even over all time — while the gateway is plainly serving'
       To    = 'is empty' }

    # Two defects in the deploy path, both measured against the live catalogue.
    # Each mutation restores the old behaviour; the behavioural tests must go red.
    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the picker goes back to sorting version strings'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = '$pick = @($g | Where-Object { $_.isDefault })'
       To    = '$pick = @($g | Sort-Object { $_.version } -Descending)' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'a deployment is attempted without provider data'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = 'if (-not $ProviderData -or -not $ProviderData.organizationName -or -not $ProviderData.industry -or -not $ProviderData.countryCode) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the provider data is left out of the request'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = 'modelProviderData = @{'
       To    = 'unusedProviderData = @{' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the deployment stops waiting for provisioning'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = "while (`$state -notin @('Succeeded', 'Failed', 'Canceled')"
       To    = 'while ($false' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the installer stops passing provider data'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '-Capacity ([int]$cap) -ProviderData $providerData'
       To    = '-Capacity ([int]$cap)' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the manual deployment goes back to an inline body'
       File  = 'docs/SETUP.md'
       From  = "--body '@deployment.json'"
       To    = '--body $body' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the picker stops showing where a version is hosted'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '"hosted on $($m.hostedOn)"'
       To    = "''" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the sign-in choice stops being decided once'
       File  = 'docs/SETUP.md'
       From  = 'decided here, once, for everyone'
       To    = 'set per machine' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'device stops being recommended for a browserless box'
       File  = 'docs/SETUP.md'
       From  = 'the only option that works without a browser'
       To    = 'one option' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the wizard choice table loses the sign-in row'
       File  = 'docs/SETUP.md'
       From  = '| Developer sign-in | `interactive` / `device` / `helper` |'
       To    = '| Developer sign-in | see the script |' }

    # Scripts ask for what they were not given (scripts/ClaudeChoice.ps1).
    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a run without a console takes an uncertain recommendation'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if ($AcceptRecommendedWithoutConsole -and $recommended.Count -eq 1)'
       To    = 'if ($recommended.Count -ge 1)' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'Enter chooses when nothing is recommended'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if (-not $answer -and $default)'
       To    = 'if (-not $answer)' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a recorded gateway is asked for again'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if ($match.Count -eq 1) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'the workbook guesses its workspace again'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = '$chosenWorkspaceId = Select-ClaudeWorkspace -ResourceGroup'
       To    = '$chosenWorkspaceId = $null # -ResourceGroup' }

    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD budgets lose their decimal source amount'
       File  = 'scripts/ClaudeUsdBudgets.ps1'
       From  = "amount_usd = `$AmountUsd.ToString('0.#########', [Globalization.CultureInfo]::InvariantCulture)"
       To    = "amount_usd = '0'" }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD writer validates but never persists the dollar edit'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'if ($usdArgs) { Set-ClaudeUsdBudget @usdArgs }'
       To    = 'if ($false) { Set-ClaudeUsdBudget @usdArgs }' }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD configuration no longer enforces named value capacity'
       File  = 'scripts/ClaudeUsdBudgets.ps1'
       From  = '$value.Length -gt 4096'
       To    = '$value.Length -gt 99999' }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD writer skips the shared authority predicate'
       File  = 'scripts/ClaudeUsdBudgets.ps1'
       From  = 'Assert-ClaudeGatewayOwnsGovernance -ResourceGroup $ResourceGroup -ApimName $ApimName -Write UsdBudgets'
       To    = '$null = $ResourceGroup' }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD response collection reads streaming bodies'
       File  = 'infra/policy.xml'
       From  = '!(bool)context.Variables["usdRequestStream"]'
       To    = 'true' }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD expiry uses an unsupported APIM UTC member'
       File  = 'infra/policy.xml'
       From  = '(DateTimeOffset)state'
       To    = '(DateTime)state' }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'USD refusal becomes indistinguishable from token quota'
       File  = 'infra/policy.xml'
       From  = 'usd_budget_exceeded'
       To    = 'quota_exceeded' }
    @{ Suite = 'Test-UsdPolicy.ps1'
       Name  = 'USD expired state remains usable'
       File  = 'infra/policy.xml'
       From  = 'now >= until'
       To    = 'false' }
    @{ Suite = 'Test-UsdPolicy.ps1'
       Name  = 'USD notify requires a reconciled state'
       File  = 'infra/policy.xml'
       From  = 'if (mode == "notify") {'
       To    = 'if (false) {' }
    @{ Suite = 'Test-UsdPolicy.ps1'
       Name  = 'USD stop drops the UTC timestamp designator'
       File  = 'infra/policy.xml'
       From  = 'error["reconciled_at"] = state["reconciled_at"].DeepClone();'
       To    = 'error["reconciled_at"] = (string)state["reconciled_at"];' }
    @{ Suite = 'Test-UsdBudgets.ps1'
       Name  = 'installer resets dollars after a failed configuration read'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '$usdSavedValues = Get-ClaudeUsdNamedValues -ResourceGroup'
       To    = '$usdSavedValues = @{} # -ResourceGroup' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'the Foundry chooser loses the gateway backend recommendation'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if ([uri]::TryCreate([string]$url, [UriKind]::Absolute, [ref]$parsed)) { $backend = $parsed.Host }'
       To    = '$backend = $null' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a recorded Turnstile resource group is asked for again'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if ($Integration -and $Integration.resourceGroup) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'an unattended restore treats the newest backup as certain'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'AcceptRecommendedWithoutConsole = ($files.Count -eq 1)'
       To    = 'AcceptRecommendedWithoutConsole = $true' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a local-only backup follows telemetry into another resource group'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if ($LocalOnly -and $linked -and ($linked -split ''/'')[4] -ine $ResourceGroup) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'reports discovery offers another gateway''s resources'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = '$_.type -eq $type -and $_.tags.''claude-chargeback-gateway'' -eq $ApimName -and'
       To    = '$_.type -eq $type -and' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a recorded reports resource is asked for again'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'if ($recordedMatch.Count -eq 1) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'the alphabetical model recommendation becomes certain in automation'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'AcceptRecommendedWithoutConsole = ($models.Count -eq 1)'
       To    = 'AcceptRecommendedWithoutConsole = $true' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a sole Application Insights is no longer certain'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = '-Recommended:($components.Count -eq 1)'
       To    = '-Recommended:$false' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a sole gateway group is no longer certain'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = '-Recommended:($groups.Count -eq 1) -Reason ''the only resource group with a visible API Management instance'''
       To    = '-Recommended:$false -Reason ''the only resource group with a visible API Management instance''' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'reports options ask for input in a headless process'
       File  = 'scripts/ClaudeChargebackDiscovery.ps1'
       From  = 'else{Test-ClaudeInteractive}'
       To    = 'else{$true}' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'telemetry guesses the recorded component is in the gateway group'
       File  = 'scripts/Get-ClaudeTelemetry.ps1'
       From  = 'if (-not $componentId) { $componentId = '
       To    = 'if ($true) { $componentId = ' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'a sole Turnstile identity no longer works unattended'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = '-Recommended:($identities.Count -eq 1)'
       To    = '-Recommended:$false' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'fleet policy ignores the installer configuration'
       File  = 'scripts/New-ClaudeCodePolicy.ps1'
       From  = 'if (Test-Path -LiteralPath $recordedConfig) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'restore starts before checking the second archive exists'
       File  = 'scripts/Migrate-ClaudeWorkstation.ps1'
       From  = 'if ($archive.Path -and -not (Test-Path -LiteralPath $archive.Path -PathType Leaf)) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'direct account discovery names a parameter the caller does not accept'
       File  = 'scripts/ClaudeChoice.ps1'
       From  = 'Parameter = $Parameter; Question = "Which Foundry account in $scope?"'
       To    = 'Parameter = ''FoundryAccount''; Question = "Which Foundry account in $scope?"' }

    @{ Suite = 'Test-ClaudeChoice.ps1'
       Name  = 'the direct family alias silently takes the first deployment again'
       File  = 'scripts/Setup-ClaudeFoundryDirect.ps1'
       From  = 'Select-ClaudeModel @choice'
       To    = 'return $hits[0].name' }

    @{ Suite = 'Test-GovernanceAuthority.ps1'
       Name  = 'business-unit authority guard removed'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'Assert-ClaudeGatewayOwnsGovernance -ResourceGroup $ResourceGroup -ApimName $ApimName -Write $writes'
       To    = '$null = $writes' }

    @{ Suite = 'Test-GovernanceAuthority.ps1'
       Name  = 'tier authority guard removed'
       File  = 'scripts/Set-ClaudeTier.ps1'
       From  = 'Assert-ClaudeGatewayOwnsGovernance -ResourceGroup $ResourceGroup -ApimName $ApimName -Write Tiers'
       To    = '$null = $Tier' }

    @{ Suite = 'Test-GovernanceAuthority.ps1'
       Name  = 'budget-only authority ignored'
       File  = 'scripts/ClaudeTurnstileGovernance.ps1'
       From  = "$" + "budgetAuthority -eq 'Turnstile'"
       To    = '$false' }

    @{ Suite = 'Test-GovernanceAuthority.ps1'
       Name  = 'business-unit monthly budget intent dropped'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = "if (`$PSBoundParameters.ContainsKey('MonthlyBudgetUsd')) { `$writes += 'Budgets' }"
       To    = "if (`$false) { `$writes += 'Budgets' }" }

    @{ Suite = 'Test-GovernanceAuthority.ps1'
       Name  = 'authority read silently accepts failure'
       File  = 'scripts/ClaudeTurnstileGovernance.ps1'
       From  = '-Id $script:TurnstileIntegrationNamedValue -FailOnError'
       To    = '-Id $script:TurnstileIntegrationNamedValue' }
)

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
    foreach ($d in 'infra', 'scripts', 'tests', 'analytics', 'sync', 'resolver') {
        if (Test-Path (Join-Path $root $d)) {
            Copy-Item (Join-Path $root $d) $sandbox -Recurse -Force
        }
    }
    # The installer is asserted against too - it is what hands preserved state
    # back to the template.
    Copy-Item (Join-Path $root 'Install-ClaudeGateway.ps1') $sandbox -Force
    Copy-Item (Join-Path $root 'README.md') $sandbox -Force
    # The developer-facing guide, which carries the Desktop gateway sign-in step
    # and the FAQ, both of which are asserted against.
    Copy-Item (Join-Path $root 'DEVELOPER.md') $sandbox -Force
    # And the capture/redaction pipeline, plus the ignore rules that keep the
    # unredacted captures out of a commit.
    Copy-Item (Join-Path $root 'guide') $sandbox -Recurse -Force
    Copy-Item (Join-Path $root '.gitignore') $sandbox -Force
    # config/ carries the shipped example only. A developer's own
    # config/price-book.json overrides the built-in rates, and copying it in
    # would make the built-in table dead code inside the sandbox - the mutation
    # that reverts it to doubles then changes nothing and reads as uncaught.
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'config') -Force | Out-Null
    Get-ChildItem (Join-Path $root 'config') -File -Filter '*.example.json' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox 'config') -Force }
    # The rendered diagram, whose presence is asserted.
    if (Test-Path (Join-Path $root 'docs/images')) {
        New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs/images') -Force | Out-Null
        Get-ChildItem (Join-Path $root 'docs/images') -File -Filter '*.png' -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox 'docs/images') -Force }
    }
    # Screenshots are a few megabytes and nothing here reads them, so the
    # markdown is copied without them - except the portal captures, whose
    # presence is asserted.
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs/adr') -Force | Out-Null
    Get-ChildItem (Join-Path $root 'docs') -Recurse -File -Filter *.md | ForEach-Object {
        $rel = $_.FullName.Substring((Join-Path $root 'docs').Length).TrimStart('\', '/')
        $dest = Join-Path (Join-Path $sandbox 'docs') $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Copy-Item $_.FullName $dest -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs/guide') -Force | Out-Null
    foreach ($pattern in 'entra-*.png', 'obs-*.png', 'b6-*.png', 'd[0-9]-*.png', 'network-*.png', 'bom-*.png', 'onboard-*.png') {
        Get-ChildItem (Join-Path $root 'docs/guide') -File -Filter $pattern -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox 'docs/guide') -Force }
    }

    $suite = Join-Path $sandbox 'tests/Test-BusinessUnits.ps1'
    $teamSuite = Join-Path $sandbox 'tests/Test-Teams.ps1'
    $modelSuite = Join-Path $sandbox 'tests/Test-ModelDeployment.ps1'
    $obsSuite = Join-Path $sandbox 'tests/Test-Observability.ps1'
    $backupSuite = Join-Path $sandbox 'tests/Test-Backup.ps1'
    $adminSuite = Join-Path $sandbox 'tests/Test-AdminSurface.ps1'
    $scaleSuite = Join-Path $sandbox 'tests/Test-Scale.ps1'
    $mpSuite = Join-Path $sandbox 'tests/Test-ModelsAndPlugins.ps1'
    $choiceSuite = Join-Path $sandbox 'tests/Test-ClaudeChoice.ps1'
    $usdSuite = Join-Path $sandbox 'tests/Test-UsdBudgets.ps1'
    $usdPolicySuite = Join-Path $sandbox 'tests/Test-UsdPolicy.ps1'
    $authoritySuite = Join-Path $sandbox 'tests/Test-GovernanceAuthority.ps1'

    # The copy must pass before any mutation, or a "caught" result below could
    # just mean the sandbox is broken.
    foreach ($s in $suite, $teamSuite, $modelSuite, $obsSuite, $backupSuite, $adminSuite, $scaleSuite, $mpSuite, $choiceSuite, $authoritySuite, $usdSuite, $usdPolicySuite) {
        & $s *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [SETUP] the unmutated copy of $(Split-Path $s -Leaf) already fails - the sandbox is wrong, not the code" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host '  [BASE]   the unmutated copy passes' -ForegroundColor DarkGray

    foreach ($index in $mutationIndices) {
        $m = $mutations[$index]
        $path = Join-Path $sandbox $m.File
        $original = [IO.File]::ReadAllText($path)
        $runner = if ($m.Suite) { Join-Path $sandbox "tests/$($m.Suite)" } else { $suite }

        if (-not $original.Contains($m.From)) {
            Write-Host "  [SETUP] '$($m.From)' not found in $($m.File)" -ForegroundColor Yellow
            $missed += "$($m.Name) (mutation did not apply)"
            continue
        }

        # Replace() not -replace: the patterns hold regex metacharacters, and a
        # literal swap is what we want.
        [IO.File]::WriteAllText($path, $original.Replace($m.From, $m.To))

        & $runner *>&1 | Out-Null
        $wentRed = ($LASTEXITCODE -ne 0)

        [IO.File]::WriteAllText($path, $original)

        if ($wentRed) {
            Write-Host "  [CAUGHT] $($m.Name)" -ForegroundColor Green
            $caught++
        }
        else {
            Write-Host "  [MISSED] $($m.Name)" -ForegroundColor Red
            $missed += $m.Name
        }
    }
}
finally {
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$caught of $($mutationIndices.Count) mutations caught."

if ($missed.Count) {
    Write-Host ''
    Write-Host 'Not caught - these assertions do not measure what they claim:' -ForegroundColor Red
    $missed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Every mutation was caught.' -ForegroundColor Green
# Explicit: the loop above deliberately leaves $LASTEXITCODE at 1, because the
# last thing it ran was a suite that was supposed to go red. Falling off the
# end here would report that as this script's own failure.
exit 0
