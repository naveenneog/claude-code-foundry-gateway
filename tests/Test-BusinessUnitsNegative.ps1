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

$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "bu-negative-$PID-$(Get-Random)"

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
       From  = '111 requests across 2 days'
       To    = 'ample production traffic' }

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
       Name  = 'the README implies the projection is shipped'
       File  = 'README.md'
       From  = 'is not built**'
       To    = 'is included**' }

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
       From  = 'ConvertTo-Json -InputObject $v -Depth 8 -Compress'
       To    = '($v | ConvertTo-Json -Depth 8 -Compress)' }

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
)

$missed = @()
$caught = 0

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    foreach ($d in 'infra', 'scripts', 'tests', 'analytics') {
        if (Test-Path (Join-Path $root $d)) {
            Copy-Item (Join-Path $root $d) $sandbox -Recurse -Force
        }
    }
    # The installer is asserted against too - it is what hands preserved state
    # back to the template.
    Copy-Item (Join-Path $root 'Install-ClaudeGateway.ps1') $sandbox -Force
    Copy-Item (Join-Path $root 'README.md') $sandbox -Force
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
    foreach ($pattern in 'entra-*.png', 'obs-*.png') {
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

    # The copy must pass before any mutation, or a "caught" result below could
    # just mean the sandbox is broken.
    foreach ($s in $suite, $teamSuite, $modelSuite, $obsSuite, $backupSuite, $adminSuite, $scaleSuite, $mpSuite) {
        & $s *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [SETUP] the unmutated copy of $(Split-Path $s -Leaf) already fails - the sandbox is wrong, not the code" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host '  [BASE]   the unmutated copy passes' -ForegroundColor DarkGray

    foreach ($m in $mutations) {
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
Write-Host "$caught of $($mutations.Count) mutations caught."

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
