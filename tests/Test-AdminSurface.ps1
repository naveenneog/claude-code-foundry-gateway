# P30-P32 and the workstation migration tool: the admin surface.
#
# Four things that share a property - each one guards against a mistake that is
# invisible after it is made:
#
#   SKU sizing      a tier chosen with no basis, and no way to argue with it
#   group check     a business unit pointing at a group that does not exist
#                   resolves to zero members and reads as unused, not broken
#   tier limits     a tier allowing a model the account does not serve refuses
#                   the caller with a model name that looks correct
#   Desktop backup  a conversation database copied while the app holds it open
#                   is not a database, and restores as corruption
#
# Offline only; the live half ran against the reference gateway.

$root = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $root 'Install-ClaudeGateway.ps1'
$bu = Join-Path $root 'scripts/Set-ClaudeBusinessUnit.ps1'
$tier = Join-Path $root 'scripts/Set-ClaudeTier.ps1'
$bd = Join-Path $root 'scripts/Backup-ClaudeDesktop.ps1'
$rd = Join-Path $root 'scripts/Restore-ClaudeDesktop.ps1'
$mig = Join-Path $root 'scripts/Migrate-ClaudeWorkstation.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Admin - sizing the SKU (P30)' -ForegroundColor Cyan

$i = Get-Content $installer -Raw
Assert 'it asks how many developers'  ($i -match 'How many developers')
Assert 'and shows the arithmetic'     ($i -match 'requests/month')
# Microsoft publishes no requests-per-second per unit for v2 - the guidance is
# to load test - so a recommendation built on an invented RPS is a guess in a
# table. Included monthly volume is published, so that is the basis.
Assert 'it sizes on published volume' ($i -match '10,000,000' -and $i -match '50,000,000')
Assert 'it cites the source'          ($i -match 'v2-service-tiers-overview')
# Volume rarely decides it. Saying so is more useful than a table implying it does.
Assert 'it names the real decider'    ($i -match '(?i)VNet' -and $i -match '(?i)availability zone|zones')
Assert 'the suggestion is overridable' ($i -match "Read-Default -Prompt 'API Management SKU' -Default \`$suggested")

Write-Host ''
Write-Host 'Admin - the group must exist (P31)' -ForegroundColor Cyan

$b = Get-Content $bu -Raw
Assert 'it verifies the group'        ($b -match 'az ad group show --group \$Group')
Assert 'and refuses when absent'      ($b -match 'No Entra group')
# A unit pointing at a missing group is created, syncs to nobody, and reads as
# unused rather than broken. Saying that is the point of the message.
Assert 'it says why that matters'     ($b -match 'reads as unused rather than broken')
Assert 'it offers near matches'       ($b -match "Groups starting")
Assert 'it checks before writing'     ($b.IndexOf('No Entra group') -lt $b.IndexOf('Set-ApimNamedValue'))
Assert 'and can be overridden'        ($b -match '\$SkipGroupCheck')

Write-Host ''
Write-Host 'Admin - tier limits (P32)' -ForegroundColor Cyan

Assert 'a tier script exists' (Test-Path $tier) $tier
$t = Get-Content $tier -Raw
Assert 'it lists the tiers'           ($t -match '\$List')
Assert 'it sets tokens per minute'    ($t -match '\$TokensPerMinute')
Assert 'and the daily quota'          ($t -match '\$DailyQuota')
Assert 'and the model allow list'     ($t -match '\$Models')
# A tier allowing an undeployed model refuses the caller with a name that looks
# right, which is a long way to travel for a typo.
Assert 'models are checked against what is deployed' ($t -match 'Get-ClaudeDeployment' -and $t -match 'Not deployed on')
Assert 'and the check can be skipped' ($t -match '\$SkipModelCheck')
Assert 'it shows before and after'    ($t -match '->')
# The policy names standard and premium directly in five places, so a third
# tier is a policy change. Claiming otherwise would create one the gateway
# ignores.
Assert 'it states a third tier needs policy work' ($t -match 'a third is a policy change|not a configuration')
Assert 'it refuses a tier the policy does not know' ($t -match "ValidateSet\('standard', 'premium'\)")

Write-Host ''
Write-Host 'Admin - Claude Desktop conversations' -ForegroundColor Cyan

Assert 'a Desktop backup exists'  (Test-Path $bd) $bd
Assert 'a Desktop restore exists' (Test-Path $rd) $rd
$d = Get-Content $bd -Raw

Assert 'it knows both profile roots' ($d -match 'Claude-3p' -and $d -match "Join-Path \`$env:APPDATA 'Claude'")
# The single correctness property. Measured with Desktop running: LOCK, LOG and
# 000003.log could not be opened while CURRENT could, so a copy taken then is
# part of a database and restores as corruption.
Assert 'it refuses while Desktop is running' ($d -match 'Get-Process' -and $d -match 'holds its conversation database open')
Assert 'and explains the consequence'        ($d -match 'restores as corruption')
Assert 'it can be forced anyway'             ($d -match 'may not restore')
# Measured: 11.4 GB total, vm_bundles 10.6 GB, session data 4 MB.
# Asserted against the entry in the skip table, not the prose: matching
# "vm_bundles" and "10.6 GB" also matched the comment explaining them, so the
# check passed with the exclusion deleted.
Assert 'it excludes the virtual machine bulk' ($d -match "'vm_bundles'\s*=\s*'")
Assert 'and says how much that is'            ($d -match '10\.6 GB')
Assert 'it captures the conversation store'   ($d -match 'IndexedDB' -and $d -match 'local-agent-mode-sessions')
# First-party conversations are server-side; the local store measured 7 KB.
Assert 'it states 1P chats are not local'     ($d -match 'Anthropic servers|Anthropic backend')
Assert 'and points at the import wizard'      ($d -match 'MIGRATION\.md')
# Copy-Item skips a locked file without comment.
Assert 'it reports files it could not read'   ($d -match 'unreadable')

$dr = Get-Content $rd -Raw
Assert 'the restore is a dry run by default'  ($dr -match 'if \(-not \$Apply\)[\s\S]{0,400}exit 0')
Assert 'it refuses to write into a live app'  ($dr -match 'take the history already on this machine')
Assert 'and refuses to overwrite'             ($dr -match 'already have data')

Write-Host ''
Write-Host 'Admin - the workstation migration tool' -ForegroundColor Cyan

Assert 'a migration tool exists' (Test-Path $mig) $mig
$m = Get-Content $mig -Raw
Assert 'it reports what is on the machine' ($m -match '\$Status')
Assert 'it backs both products up'         ($m -match 'Backup-ClaudeCode' -and $m -match 'Backup-ClaudeDesktop')
Assert 'it configures the gateway'         ($m -match 'Setup-ClaudeWorkstation')
Assert 'it restores both'                  ($m -match 'Restore-ClaudeCode' -and $m -match 'Restore-ClaudeDesktop')
# Configuring switches Desktop to a different profile root, so the first thing
# a developer sees afterwards is an empty Desktop.
Assert 'it warns that configuring empties Desktop' ($m -match 'empty Desktop')
Assert 'it refuses to back up a running Desktop'   ($m -match 'Quit it first')

Write-Host ''
Write-Host 'Admin - one developer (P33)' -ForegroundColor Cyan

$dev = Join-Path $root 'scripts/Set-ClaudeDeveloper.ps1'
Assert 'a developer script exists' (Test-Path $dev) $dev
$dv = Get-Content $dev -Raw

# The whole reason it exists rather than a named value write: the sync rebuilds
# allow-standard and allow-premium from group membership, so a developer added
# straight to the named value works until the next sync and then stops.
Assert 'it edits the Entra group'      ($dv -match 'groups/\$groupId/members')
Assert 'and says why, not the gateway' ($dv -match 'rebuilds' -and $dv -match 'silently stops')
Assert 'it can add to a tier'          ($dv -match '\$Tier')
Assert 'and to a business unit'        ($dv -match '\$BusinessUnit')
Assert 'and remove'                    ($dv -match '\$Remove')
# Leaving someone on a budget they can no longer spend reads as a broken team
# rather than a half-finished offboarding.
Assert 'removal clears every business unit' ($dv -match 'Every unit is cleared')
# checkMemberObjects answers transitively. With teams nested in business units
# and those nested in tier groups, it reports membership you cannot remove.
# Asserted on the call form: the comment explaining why it is not used contains
# the word, so matching the word passes on a script that calls it.
Assert 'membership is checked directly'  ($dv -match '/memberOf\?' -and $dv -notmatch 'checkMemberObjects"|/checkMemberObjects')
Assert 'and the reason is recorded'      ($dv -match 'Request_ResourceNotFound')
# A guest UPN contains #EXT#, and '#' starts a fragment.
# The property is that no raw value reaches a filter, not that the encoder is
# mentioned somewhere - the script encodes in two places and removing one left
# the other to satisfy a looser check.
Assert 'query values are URL-encoded'    ($dv -match 'EscapeDataString')
Assert 'and no raw value reaches a filter' ($dv -notmatch "eq%20'\`$q'" -and $dv -notmatch "eq '\`$q'")
Assert 'and the reason is recorded'      ($dv -match 'starts a fragment')
# The group edit is durable; the gateway still needs the sync.
Assert 'it publishes or says how'        ($dv -match 'Sync-ClaudeAccess')
Assert 'and warns when it has not'       ($dv -match 'not at the gateway')

$onb2 = Get-Content (Join-Path $root 'docs/ONBOARDING.md') -Raw
Assert 'onboarding documents it'         ($onb2 -match 'Set-ClaudeDeveloper')

Write-Host ''
Write-Host 'Admin - bill of materials and the flow diagram (P28)' -ForegroundColor Cyan

$bom = Join-Path $root 'scripts/Get-ClaudeBom.ps1'
Assert 'a bill of materials script exists' (Test-Path $bom) $bom
$bm = Get-Content $bom -Raw
# A resource group holds more than one thing - 66 on the reference deployment,
# five of them this gateway's. A hand-written list drifts from what is there.
Assert 'it reads the live deployment'  ($bm -match 'az resource list')
Assert 'it separates created from reused' ($bm -match 'Reused, not created')
Assert 'and names what is only configuration' ($bm -match 'Configured, and free')
# Prices are regional and change; a figure hard-coded in a script is wrong
# somewhere by the time anyone reads it.
Assert 'it describes cost rather than quoting a price' ($bm -match 'Prices are' -and $bm -notmatch '\$\d+\.\d\d per')
Assert 'it can emit JSON'               ($bm -match '\$AsJson')

$diagram = Join-Path $root 'docs/images/request-flow.png'
Assert 'the flow diagram ships'         (Test-Path $diagram)
$rd2 = Get-Content (Join-Path $root 'guide/render-architecture.mjs') -Raw
# An image model cannot be relied on to spell ApiManagementGatewayLlmLog, and
# the value of this picture is that the names on it are the real ones.
Assert 'it is rendered, not generated'  ($rd2 -match 'Deterministic HTML')
Assert 'it names the real log table'    ($rd2 -match 'ApiManagementGatewayLlmLog')
Assert 'and carries the cache caveat'   ($rd2 -match '38\.7')
$rm = Get-Content (Join-Path $root 'README.md') -Raw
Assert 'the README shows it'            ($rm -match 'request-flow\.png')
Assert 'and points at the live BOM'     ($rm -match 'Get-ClaudeBom')

Write-Host ''
Write-Host 'Admin - optional Grafana (P34)' -ForegroundColor Cyan

$gf = Join-Path $root 'scripts/Publish-ClaudeGrafana.ps1'
Assert 'a Grafana publisher exists' (Test-Path $gf) $gf
$gv = Get-Content $gf -Raw
# It is the only observability option with a standing bill, and the script says
# so rather than leaving that to be discovered on an invoice.
Assert 'it states the standing cost'   ($gv -match 'per instance per hour')
Assert 'and points at the free option' ($gv -match 'Publish-ClaudeWorkbook')
# Creating the instance is a decision with a cost attached.
Assert 'it does not create the instance' ($gv -match 'does not create a Grafana instance')
# One query definition, two consumers.
Assert 'panels reuse the saved function' ($gv -match 'ClaudeChargeback\(\$__timeFrom')
Assert 'and it refuses without them'     ($gv -match 'has no ClaudeChargeback function')
# The amg extension is not installed by default, and its absence used to reach
# ConvertFrom-Json as a parse error.
Assert 'a missing extension is explained' ($gv -match 'az extension add --name amg')
Assert 'and discovery degrades rather than failing' ($gv -match '-Soft')
# Azure's own error here is a Python traceback; repeating it buries the point.
Assert 'it trims Azure''s traceback'     ($gv -match 'Select-Object -Last 4')
Assert 'it refuses an ambiguous workspace' ($gv -match 'renders empty')
$mon2 = Get-Content (Join-Path $root 'docs/MONITORING.md') -Raw
Assert 'monitoring documents it as optional' ($mon2 -match 'Publish-ClaudeGrafana')

Write-Host ''
Write-Host 'Admin - business units at install' -ForegroundColor Cyan

$inst = Get-Content $installer -Raw

# The first question after a deploy was always "so where do I set up
# chargeback". The installer already asks for tiers and budgets, so stopping
# short of the thing those budgets are charged to was an odd seam.
Assert 'the installer offers a business unit' ($inst -match "Write-Step 'Business units \(optional\)'")
Assert 'it can be declined'                   ($inst -match "Read-YesNo 'Create a business unit now\?' \`$false")
Assert 'and more than one can be added'       ($inst -match "while \(Read-YesNo 'Create a business unit now\?'")

# -Yes drives unattended installs and CI. A business unit is a naming decision
# about somebody else's organisation; inventing one unattended leaves a registry
# entry nobody asked for. Asserted on the guard, not on the word.
Assert 'unattended installs skip it entirely' `
    ($inst -match "(?s)if \(-not \`$Yes\) \{\s*\r?\n\s*Write-Step 'Business units \(optional\)'")

# Set-ClaudeBusinessUnit refuses a unit whose group does not exist, because it
# syncs to nobody and reads as unused rather than broken. The installer creates
# the group first, and stops rather than writing a unit it knows will be empty.
Assert 'it creates the Entra group first'  ($inst -match 'az ad group create --display-name \$buGroup')
Assert 'and refuses to write a unit without one' ($inst -match "(?s)Could not create '\`$buGroup'[\s\S]{0,200}continue")

# The identifier keys the budget counter, the ledger and every report.
Assert 'the identifier is validated at the prompt' ($inst -match "\`$buId -notmatch '\^\[a-z0-9\]\[a-z0-9-\]\*\`$'")
Assert 'and it delegates the write'                ($inst -match 'scripts/Set-ClaudeBusinessUnit\.ps1.*-Id \$buId')

Write-Host ''
Write-Host 'Admin - the chargeback console' -ForegroundColor Cyan

$console = Join-Path $root 'scripts/Manage-ClaudeBusinessUnits.ps1'
Assert 'a management console exists' (Test-Path $console)
$mc = Get-Content $console -Raw

# It is a menu over the shipped commands, not a second implementation. A
# parallel implementation drifts, and then the console and the documented
# command disagree about what happened.
foreach ($s in 'Get-ClaudeBusinessUnit.ps1', 'Set-ClaudeBusinessUnit.ps1',
                'Set-ClaudeDeveloper.ps1', 'Sync-ClaudeAccess.ps1') {
    Assert "it delegates to $s" ($mc -match [regex]::Escape("'$s'"))
}
Assert 'and writes nothing itself' ($mc -notmatch 'Set-ApimNamedValue')

# Entitlement is not live. Forgetting the sync is the most common way a change
# looks like it did not work, so the console owns it rather than the operator.
Assert 'a change syncs automatically'   ($mc -match '(?m)^function Complete-Change')
Assert 'and batching is possible'       ($mc -match '\[switch\]\$NoSync')
Assert 'with the gateway marked behind' ($mc -match '\$script:pending = \$true')
Assert 'and a warning on the way out'   ($mc -match "(?s)'q' \{[\s\S]{0,300}Sync before leaving")

# A budget is a named value the policy reads, not directory membership, so it
# does not need a membership sync - and saying so avoids an unnecessary one.
Assert 'a budget change does not force a sync' ($mc -match 'Budgets take effect on the next request')

# One mistyped group must not end a session halfway through moving a team.
Assert 'a failed option does not exit the console' ($mc -match '(?s)catch \{[\s\S]{0,500}That did not work')

# A menu needs a keyboard, and UserInteractive lies under -NonInteractive.
Assert 'it detects a missing terminal by trying' ($mc -match '(?m)^function Read-Choice')
Assert 'and names the direct commands instead'   ($mc -match 'For scripts and pipelines, call the commands directly')

# The console is a different job from the installer and says so on entry.
# Asserted by effect: the helper file has to exist and the variant has to be one
# the helper accepts, because Test-Path swallows a wrong name silently and an
# unknown variant would throw only when someone ran it.
$bannerPath = Join-Path $root 'scripts/Show-Banner.ps1'
Assert 'the console dot-sources a banner that exists' (
    $mc -match "Join-Path \`$PSScriptRoot 'Show-Banner\.ps1'" -and (Test-Path $bannerPath))
$bn = Get-Content $bannerPath -Raw
$variant = if ($mc -match 'Show-ClaudeBanner -Variant (\w+)') { $Matches[1] } else { '' }
Assert 'with a variant the banner accepts' (
    $variant -and $bn -match "ValidateSet\([^)]*'$variant'") "asked for '$variant'"
Assert 'and that variant selects its own art' ($bn -match "(?m)^\s*\`$art = if \(\`$Variant -eq 'console'\)")
Assert 'and names the console in full'        ($bn -match 'Foundry Claude Management Console')

Write-Host ''
Write-Host 'Admin - the resource group it deploys into' -ForegroundColor Cyan

$inst = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw

# A group cannot be moved and main.bicep defaults location to the group's, so a
# pre-existing group in another region silently decides where the gateway lands.
Assert 'it looks before creating'          ($inst -match 'az group show -n \$ResourceGroup --query location')
Assert 'and compares with the request'     ($inst -match '(?m)^\s*\$same = .*ToLower\(\) -eq .*ToLower\(\)')
Assert 'it says the group wins'            ($inst -match "-Location is\W+.{0,40}ignored|ignored\. Deploying into")
Assert 'and names the only way round it'   ($inst -match 'using a different group name')
# The old version printed OK whatever az returned, so a failed create read as a
# success and the next 30 minutes deployed into a group that was never made.
Assert 'a failed create stops the run'     ($inst -match "Could not create resource group")
Assert 'and OK is not printed regardless'  ($inst -notmatch "(?m)^az group create -n \`$ResourceGroup -l \`$Location -o none\r?\nWrite-Ok")

$bicep = Get-Content (Join-Path $root 'infra/main.bicep') -Raw
Assert 'the template takes the group location' ($bicep -match 'param location string = resourceGroup\(\)\.location')
# BCP037 warns that largeLanguageModel is not in the type definition. Measured
# 2026-09-17 against the live gateway: ARM accepts and applies it on the
# API-scoped diagnostic, returning {"logs":"enabled"}. The warning is stale
# typing, not a deployment failure - and removing the property would empty the
# ledger, so it is asserted rather than left to look like dead code.
Assert 'LLM logging is turned on at the API' ($bicep -match '(?m)^\s*largeLanguageModel: \{')
Assert 'and the rows are routed to the workspace' ($bicep -match "category: 'GatewayLlmLogs'")
Assert 'both halves are recorded as required'     ($bicep -match 'Both are needed')

Write-Host ''
Write-Host 'Admin - the choices are asked, not documented' -ForegroundColor Cyan

# These were a page an operator was expected to read, decide from, and then come
# back and set named values by hand. Asked at deployment instead, with the cost
# of each option computed at the developer count they just gave.
Assert 'the installer asks the revocation window' ($inst -match 'Revocation window in minutes')
Assert 'and costs each option'                    ($inst -match 'Measure-ClaudeProjectionCost\.ps1')
Assert 'at the count they gave'                   ($inst -match '-Developers \$devCount -CacheMinutes')
# The cost model is the single source; restating figures would make two.
Assert 'it does not restate a price table'        ($inst -notmatch '(?m)^\s*Write-Host.*\$11\.11')
Assert 'it says what dominates the bill'          ($inst -match 'charged whether anyone')
# Immediate revocation is not a free choice - it makes the resolver a
# per-request dependency, so it is named and refused rather than silently absent.
Assert 'immediate is named and explained'         ($inst -match 'not supported - every request would call the resolver')

Assert 'it asks what a budget does'               ($inst -match 'Team budget behaviour \(report/stop\)')
Assert 'and says what each deploys'               ($inst -match 'Deploys the quota policy as enforcing')
Assert 'and warns stop triggers late'             ($inst -match 'triggers far later than the dollars suggest')
Assert 'choosing stop is echoed at the end'       ($inst -match "budgetMode -eq 'stop'")

Assert 'it asks about unassigned developers'      ($inst -match 'Developers with no team \(allow/deny\)')
Assert 'and it reaches the template'              ($inst -match 'buUnassigned=\$\(if \(\$unassignedMode\)')

# The one that cannot be retrofitted cheaply.
Assert 'it asks which address developers get'     ($inst -match 'Developer address \(azure/custom\)')
Assert 'and names the consequence of the default' ($inst -match 'reconfiguring')
Assert 'and says this one is expensive to change' ($inst -match 'expensive to change afterwards')
Assert 'choosing custom prints the steps'         ($inst -match "addressMode -eq 'custom'")

# Whether the SKU just chosen can be changed later, which differs by tier.
Assert 'it says whether the SKU is reversible'    ($inst -match 'can be changed later: BasicV2 and StandardV2')
Assert 'and when it is a one-time pick'           ($inst -match 'effectively a one-time pick')

$costModel = Get-Content (Join-Path $root 'scripts/Measure-ClaudeProjectionCost.ps1') -Raw
# The default was a fixed 50,000 active, so costing 500 developers reported
# 50,000 of them active and overstated a small deployment a hundredfold.
Assert 'active developers scale with the population' ($costModel -match '\$Developers \* 0\.1')
Assert 'and an impossible figure is refused'         ($costModel -match 'is larger than Developers')

# The installer took a developer count, sized the SKU from it, and never checked
# it against the store that actually holds identities. A population above the
# named-value ceiling deployed happily and hit the wall weeks later, as a sync
# refusing to write, by which time the gateway was in production.
Assert 'the declared population is checked'      ($inst -match 'This holds about \{0\} developers today')
Assert 'against a derived ceiling, not a literal' ($inst -match '(?m)^\s*\$buCeiling = \[int\]\[math\]::Floor')
Assert 'it says a bigger SKU does not help'      ($inst -match 'raising the SKU does not move it')
Assert 'and names what would'                    ($inst -match 'docs/adr/0011')
Assert 'it says the move is configuration'       ($inst -match 'configuration change rather than a redeployment')
Assert 'and the operator can still proceed'      ($inst -match 'Continue anyway \(yes/no\)')
Assert 'or stop before anything is created'      ($inst -match 'Stopped before deploying. Nothing was created')

Write-Host ''
Write-Host 'Admin - the direct Foundry path' -ForegroundColor Cyan

$direct = Join-Path $root 'scripts/Setup-ClaudeFoundryDirect.ps1'
Assert 'a direct setup script ships' (Test-Path $direct)
$ds = Get-Content $direct -Raw

Assert 'it offers device code'        ($ds -match '--use-device-code')
Assert 'and interactive sign-in'      ($ds -match "ValidateSet\('device', 'interactive', 'current'\)")
Assert 'it takes a tenant'            ($ds -match '\[string\]\$TenantId')
Assert 'and an app registration'      ($ds -match '\[string\]\$ClientId')
# Signing in to the wrong directory fails later and less clearly.
#
# Asserted on the throw, not the words. "wrong tenant" also appears in the help
# text further down, and -match is case-insensitive, so matching the phrase was
# satisfied by the explanation while the refusal itself was gone.
Assert 'it refuses the wrong tenant'  ($ds -match "(?m)^\s*throw 'Wrong tenant\.'")
# A config that cannot authenticate is harder to diagnose than a refusal.
$tokenAt = $ds.IndexOf('Data-plane token')
$writeAt = $ds.IndexOf('Claude Code settings')
Assert 'it gets a token before writing' (
    $tokenAt -ge 0 -and $writeAt -ge 0 -and $tokenAt -lt $writeAt) "token at $tokenAt, write at $writeAt"

# The resource, not a base URL. Both present ends the session.
Assert 'it sets the resource, not a url' ($ds -match "ANTHROPIC_FOUNDRY_RESOURCE = \`$Resource")
Assert 'and strips a gateway base url'   ($ds -match "Properties.Remove\('ANTHROPIC_FOUNDRY_BASE_URL'\)")

# The model list, which is the part that fails mid-session when it is wrong.
Assert 'it configures the model list'   ($ds -match "'availableModels'")
Assert 'and enforces it'                ($ds -match "'enforceAvailableModels'")
Assert 'a disabled deployment is skipped' ($ds -match "provisioningState=='Succeeded'")
# Deployment names are chosen by whoever made them, so the name is not evidence
# of which Claude it is. Anchoring the aliases on properties.model.name is the
# difference between working everywhere and working only where someone happened
# to name the deployment after its model.
Assert 'discovery asks for the model too'  ($ds -match 'model:properties\.model\.name')
Assert 'aliases resolve from the model'    ($ds -match '\$_\.model -and \$_\.model -match \$Family')
Assert 'and fall back to the name'         ($ds -match '\$_\.name -match \$Family')
Assert 'a real haiku deployment is preferred' ($ds.Contains("if (`$haiku)  { `$haiku }  else { `$fallback }"))
Assert 'haiku points at a real deployment' ($ds -match "ANTHROPIC_DEFAULT_HAIKU_MODEL'\]\s+=")
# Assuming a deployment name writes a config that fails minutes later as
# DeploymentNotFound, which reads as a Claude Code bug rather than a setting.
Assert 'it refuses to invent a deployment' ($ds -match 'Cannot configure \$Resource without knowing')
Assert 'and never assumes a model name'    ($ds -notmatch "\`$Models = @\('claude-sonnet-5'\)")
Assert 'it names the way past discovery'   ($ds -match '-Models <name>')
# Signing in proves nothing; every account gets a token. The evidence is a real
# call, and it has to happen before the write or a machine that cannot reach
# Foundry is left holding a config that points somewhere it cannot go.
Assert 'access is proved by a real call'   ($ds -match "Step 'Access check'")
Assert 'and before anything is written'    ($ds.IndexOf("Step 'Access check'") -lt $ds.IndexOf("Step 'Claude Code settings'"))
Assert 'a failed check writes nothing'     ($ds -match '(?i)Nothing was written\. This machine is unchanged')
Assert 'and stops the run'                 ($ds -match 'throw "Cannot reach \$Resource as the signed-in principal')
# The old handler printed a list of maybes, and two of them were wrong. Read
# the token and ask Azure instead.
Assert 'a refusal is diagnosed, not listed' ($ds -match 'function Resolve-FoundryDenial')
Assert 'the token is decoded'               ($ds -match 'function ConvertFrom-JwtPayload')
Assert 'so the real principal is named'     ($ds -match '(?i)The call was made as')
Assert 'a 404 is not an auth problem'       ($ds -match '(?i)Authentication succeeded\.')
Assert 'and lists the deployments that exist' ($ds -match '(?i)Anthropic deployments that do exist here')
# Foundry User and Cognitive Services User carry the same data action, so no
# role name may be hardcoded as the required one.
Assert 'role capability is asked of Azure'  ($ds -match 'permissions\[0\]\.dataActions')
Assert 'and matched on the data action'     ($ds.Contains("'Microsoft.CognitiveServices/*'"))
# A substring test would accept Azure AI Developer, which is confined to
# accounts/OpenAI/* and serves no Claude at all.
Assert 'an OpenAI-scoped role is rejected'  ($ds -match "actions -contains 'Microsoft\.CognitiveServices/\*'")
Assert 'and named when it is the cause'     ($ds -match "'Azure AI Developer', 'Cognitive Services OpenAI User'")
Assert 'with why it does not serve Claude'  ($ds -match '(?i)is scoped to accounts/OpenAI/\* only')
Assert 'project scope is offered as a cause' ($ds -match '(?i)on a project inside this account')
# One sign-in, all three clients. Desktop cannot read ~/.claude/settings.json,
# so it needs the base URL and the credential helper instead.
Assert 'it configures VS Code too'          ($ds -match "Step 'VS Code'")
Assert 'as an array of name/value pairs'    ($ds -match "name = 'ANTHROPIC_FOUNDRY_RESOURCE'; value = \`$Resource")
Assert 'and says a reload is needed'        ($ds -match '(?i)Developer: Reload Window')
Assert 'it configures Claude Desktop too'   ($ds -match "Step 'Claude Desktop'")
Assert 'it reuses the gateway helper'       ($ds -match 'get-foundry-token\.cmd')
# One helper location. Two means a machine that has run both scripts keeps two
# copies and a profile can point at the stale one.
Assert 'in the same place as the gateway'   ($ds -match "Join-Path \`$env:LOCALAPPDATA 'ClaudeFoundry'")
Assert 'pointed at the direct base url'     ($ds -match 'inferenceGatewayBaseUrl\s+= \$baseUrl')
# Desktop rewrites its configuration on exit, so writing underneath a running
# instance is discarded the moment the developer quits.
Assert 'a running Desktop is detected'      ($ds -match "Get-Process -Name 'Claude'")
Assert 'and the operator is asked first'    ($ds -match '(?i)Close it and continue')
Assert 'with a reason given'                ($ds -match '(?i)rewrites its configuration when it')
Assert 'declining leaves Desktop alone'     ($ds -match '(?i)Left running\. Desktop was not configured')
Assert 'unattended runs can force it'       ($ds -match '\[switch\]\$Force')
Assert 'processes are stopped by id'        ($ds -match 'Stop-Process -Id \$p\.Id')
Assert 'and a survivor is reported'         ($ds -match '(?i)still running\. Quit it from the tray icon')
Assert 'developer mode is turned on'        ($ds -match "'allowDevTools'")
Assert 'checking the value, not the file'   ($ds -match '\$devDoc\.allowDevTools -eq \$true')
Assert 'either client can be skipped'       (($ds -match '\[switch\]\$SkipDesktop') -and ($ds -match '\[switch\]\$SkipVSCode'))

$ws = Get-Content (Join-Path $root 'scripts/Setup-ClaudeWorkstation.ps1') -Raw
Assert 'the gateway path checks it too'     ($ws -match '\$devDoc\.allowDevTools -eq \$true')
Assert 'and keeps the other keys'           ($ws -match "Add-Member -NotePropertyName 'allowDevTools'")
Assert 'it backs up what was there'     ($ds -match '\.bak')

# Reading the configuration off a machine, including one that has none.
Assert 'it can export the configuration' ($ds -match '\[switch\]\$ShowConfig')
Assert 'and explains a machine with none' ($ds -match 'never been pointed at Foundry')

# A config file, so a developer is handed one thing rather than told four
# values to type. Same shape and idea as the gateway's claude-gateway.json.
Assert 'it reads a config file'          ($ds -match '\[string\]\$ConfigPath')
Assert 'and can write one'               ($ds -match '\[string\]\$WriteConfig')
Assert 'the file is tagged with its mode' ($ds -match "mode\s+= 'foundry-direct'")
# The gateway file has the same extension and a different meaning. Applying one
# as the other fails with an error that never names the file that was wrong.
Assert 'a gateway config is refused'     ($ds -match 'looks like a gateway config')
Assert 'and names the script that wants it' ($ds -match 'Use Setup-ClaudeWorkstation\.ps1 with it instead')
Assert 'explicit arguments still win'    ($ds -match '(?m)^\s*if \(-not \$Resource -and \$cfg\.foundryResource\)')

$fd = Get-Content (Join-Path $root 'docs/FOUNDRY-DIRECT.md') -Raw
Assert 'the direct path is documented'   ($fd.Length -gt 0)
# The failure every direct-path developer meets first. The message names a
# principal, and on this path the principal is often not the person reading it.
# Ordered as it actually occurs: wrong tenant beats missing role in the wild.
Assert 'the 401 is documented'                ($fd -match '(?i)401 Principal does not have access')
Assert 'the wrong tenant is named first'      ($fd -match '(?i)No `AZURE_TENANT_ID`, and the resource is in another tenant')
Assert 'and an empty list is read correctly'  ($fd -match '(?i)wrong tenant, not that you lack a role')
Assert 'the credential chain is explained'    ($fd -match '(?i)sit ahead of the Azure CLI in it')
Assert 'it says what to check first'          ($fd -match 'AZURE_CLIENT_ID\|AZURE_CLIENT_SECRET')
Assert 'and how to grant the role'            ($fd -match '(?i)az role assignment create --assignee')
Assert 'a reload is needed after'             ($fd -match '(?i)extension host reads the environment once')
Assert 'and the gateway path is exempt'       ($fd -match '(?i)developers need no role on the Foundry resource')
# Why the aliases cannot be taken from the deployment name.
Assert 'names are not model names'            ($fd -match '(?i)Deployment names are not model names')
Assert 'with a worked example'                ($fd -match '\| `claude-primary` \| `claude-opus-5` \|')
Assert 'and discovery failure stops'          ($fd -match '(?i)\*\*stops\*\* rather than guessing')
# A pasted catalogue passes enforceAvailableModels and fails per model.
Assert 'availableModels is deployment names'  ($fd -match '(?i)availableModels holds deployment names, not model names')
Assert 'and the query to get them is given'   ($fd -match 'deployment:name, model:properties\.model\.name')
# Entitlement here is an Azure role on a group, not an Entra app permission.
Assert 'the role for a group is documented'   ($fd -match '(?i)Which role, and which scope')
Assert 'assigned to a group, not per person'  ($fd -match '--assignee-principal-type Group')
Assert 'and why that flag is needed'          ($fd -match '(?i)attempts a Graph lookup that frequently fails')
Assert 'no app registration is needed'        ($fd -match '(?i)no Entra app registration')
Assert 'the OpenAI-scoped trap is named'      ($fd -match '\| Azure AI Developer \|')
Assert 'and Cognitive Services OpenAI User'   ($fd -match '\| Cognitive Services OpenAI User \|')
Assert 'with the reason they fail'            ($fd -match '(?i)not served under `accounts/OpenAI/`')
Assert 'account scope, not project'           ($fd -match '(?i)Scope it at the account')
Assert 'and how to find a project-scoped one' ($fd -match '(?i)scope ending in `/projects/')
# One command, and it names the layer rather than the symptom.
Assert 'a single health check is documented' ($fd -match '(?i)One command that checks the whole chain')
Assert 'and it configures nothing'            ($fd -match '(?i)configures nothing, so it is safe')
Assert 'the device-code check is offered'     ($fd -match '(?i)-ClientId <client-id> -TenantId')
Assert 'and marked as beyond RBAC'            ($fd -match '(?i)no role\s*\n?assignment can fix')

$td = Get-Content (Join-Path $root 'scripts/Test-FoundryDirect.ps1') -Raw
Assert 'the health check names the principal' ($td -match '(?i)Token belongs to a signed-in user')
Assert 'and checks the tenant owns it'        ($td -match '(?i)Resource is in the signed-in tenant')
Assert 'and that a role reaches Claude'       ($td -match '(?i)A role reaches the Claude data plane')
Assert 'on the unrestricted data action'      ($td.Contains("'Microsoft.CognitiveServices/*'"))
Assert 'it compares all three clients'        (($td -match '(?i)Claude CLI points where expected') -and
                                               ($td -match '(?i)VS Code agrees with the CLI') -and
                                               ($td -match '(?i)Claude Desktop points where expected'))
Assert 'a gateway machine is said to be one'  ($td -match '(?i)not the direct path')
Assert 'the mutually exclusive pair is caught' ($td -match '(?i)mutually exclusive')
Assert 'device-code init is checked'          ($td -match 'oauth2/v2\.0/devicecode')
Assert 'and the AADSTS code is surfaced'      ($td -match "AADSTS\\d\+")
Assert 'and named as not RBAC'                ($td -match '(?i)app registration or tenant, not RBAC')
# Existing is not working. The helper that broke Desktop was present, named in
# the profile, and executable - it simply could not find az. That passed every
# check in the file, so the check now runs it.
Assert 'the helper is executed, not just found' ($td -match '(?i)Desktop helper returns a token')
Assert 'and run the way Desktop runs it'        ($td -match '(?i)and without the CLI on PATH')
Assert 'with the CLI stripped from PATH'        ($td.Contains("-notmatch 'Azure\\CLI2'"))
Assert 'the tenant variable is checked'         ($td -match '(?i)Desktop helper knows its tenant')
Assert 'and why it matters is stated'           ($td -match '(?i)home-tenant token the gateway refuses')
# Measured: enforceAvailableModels substitutes silently rather than refusing.
Assert 'the model list behaviour is asserted'   ($td -match '(?i)an unlisted model is substituted, not served')
Assert 'and described as silent'                ($td -match '(?i)silently, with no error')
# A gateway machine is not a broken machine.
Assert 'the expected shape is a parameter'      ($td -match "\[ValidateSet\('direct', 'gateway'\)\]\[string\]\`$Expect")
Assert 'and both clients honour it'             (($td -match 'Claude CLI points where expected') -and
                                                 ($td -match 'Claude Desktop points where expected'))
# Two client versions moved in one day; a later failure needs correlating.
Assert 'client versions are reported'           ($td -match '(?i)Versions : CLI')
Assert 'including the VS Code extension'        ($td -match 'code --list-extensions --show-versions')
# Omitting a check silently reads as a pass.
Assert 'a skipped VS Code check says so'        ($td -match '(?i)No user settings file at')
# The developer script answers "is this machine configured?". An admin needs
# the question before it: is there anything here to configure against?
$ad = Get-Content (Join-Path $root 'scripts/Test-FoundryDirectAdmin.ps1') -Raw
Assert 'an admin readiness check ships'         ($ad.Length -gt 0)
Assert 'it changes nothing'                     ($ad -match '(?i)Read-only\. It creates nothing')
Assert 'it names the tenant it looked in'       ($ad -match '(?i)not visible from tenant')
Assert 'it reports usable deployments only'     ($ad -match "provisioningState -eq 'Succeeded'")
Assert 'and warns about the others'             ($ad -match '(?i)list normally and refuse every call')
Assert 'it names missing model families'        ($ad -match '(?i)no \$\(\$missing -join')
Assert 'it asks Azure which roles reach Claude' ($ad.Contains("acts -contains 'Microsoft.CognitiveServices/*'"))
Assert 'and names the OpenAI-scoped trap'       ($ad -match "'Azure AI Developer', 'Cognitive Services OpenAI User'")
Assert 'it counts groups against people'        ($ad -match "principalType -eq 'Group'")
Assert 'and says person-by-person will not scale' ($ad -match '(?i)granted person by person')
Assert 'it checks the resource is reachable'    ($ad -match 'publicNetworkAccess')
Assert 'and notices a deny-by-default firewall' ($ad -match "defaultAction -eq 'Deny'")
Assert 'the Desktop app registration is optional' ($ad -match '(?i)isFallbackPublicClient')
Assert 'it hands over the developer command'    ($ad -match 'Setup-ClaudeFoundryDirect\.ps1 -Resource \$Resource -TenantId')
# Repairs are opt-in and shown before they run. A repair you cannot read is a
# repair you cannot refuse.
Assert 'the admin check can repair'             ($ad -match '\[switch\]\$Fix')
Assert 'but changes nothing by default'         ($ad -match '(?i)Re-run with -Fix to apply these')
Assert 'each repair shows its command'          ($ad -match '\$\(\$r\.Command\)')
Assert 'and is confirmed one at a time'         ($ad -match '(?i)Apply: \$\(\$r\.What\)\? \[y/N\]')
Assert 'unattended runs can skip the asking'    ($ad -match '\[switch\]\$Force')
Assert 'it grants at the account scope'         ($ad -match '--assignee-principal-type \$ptype')
Assert 'a principal can be named to entitle'    ($ad -match '\[string\]\$GrantTo')
Assert 'it fixes the public-client flag'        ($ad -match 'az ad app update --id \$cid --set isFallbackPublicClient=true')
Assert 'and never repairs network posture'      ($ad -match '(?i)security decision, not a configuration fault')
Assert 'propagation is called out after a grant' ($ad -match '(?i)take a few minutes to')

# The developer side repairs this machine, not Azure.
Assert 'the developer check can repair too'     ($td -match '\[switch\]\$Fix')
Assert 'it resolves the endpoint first'         ($td -match '(?i)The endpoint name resolves')
Assert 'and explains the ENOTFOUND it causes'   ($td -match '(?i)Claude Code reports this as ENOTFOUND')
Assert 'a proxy is reported'                    ($td -match '(?i)a proxy is configured for this shell')
Assert 'with the hosts it must not intercept'   ($td -match 'services\.ai\.azure\.com and login\.microsoftonline\.com')
Assert 'a stale session can be refreshed'       ($td -match 'az account clear; az login --tenant')
Assert 'recent grants are named as a cause'     ($td -match '(?i)granted recently, it can take a few minutes')
Assert 'and it points at the admin script'      ($td -match 'Test-FoundryDirectAdmin\.ps1 -Resource \$Resource -GrantTo')
Assert 'a wrong target offers the setup script' ($td -match '(?i)point every client at this resource')
Assert 'and a new terminal is required after'   ($td -match '(?i)a running shell keeps the environment it started with')
# az cognitiveservices account list only sees the active subscription. An
# account with rights over many - 86 measured on one - gets "not visible in
# this tenant" for a resource one subscription away, which is not a
# permissions fault and reads exactly like one.
Assert 'the subscription can be pinned'         ($td -match '\[string\]\$SubscriptionId')
Assert 'and the resource is found without it'   ($td.Contains('function Find-FoundryAccount {'))
Assert 'searching every subscription'           ($td -match "type =~ 'microsoft\.cognitiveservices/accounts'")
Assert 'with a fallback when graph is absent'   ($td -match 'az account list --all --query "\[\]\.id"')
Assert 'the discovery never switches context'   ($td -match '(?i)Changing someone.s CLI context as a side')
Assert 'switching is offered as a repair'       ($td -match 'az account set --subscription \$fs')
Assert 'downstream calls name the subscription' ($td -match "subArg = @\('--subscription'")
Assert 'and so does the deployment lookup'      ($td -match "depSub = @\('--subscription'")
Assert 'it says the client ignores subscriptions' ($td -match '(?i)Code does not use subscriptions at all')

Assert 'the admin check pins a subscription too' ($ad -match '\[string\]\$SubscriptionId')
Assert 'and searches across them'                ($ad -match "type =~ 'microsoft\.cognitiveservices/accounts'")
Assert 'naming the one it found'                 ($ad -match '(?i)not in your active subscription')
Assert 'and pinning every later call'            ($ad -match '-g \$ResourceGroup @subPin')
# The failure where every check passes and Claude Code is still refused: the
# checks read the az token, and Claude Code never asks for it. Pinning the
# chain is documented, and better than deleting an identity the machine needs.
Assert 'the credential chain can be pinned'      ($td -match 'AZURE_TOKEN_CREDENTIALS')
Assert 'to the CLI credential by name'           ($td -match 'AzureCliCredential')
Assert 'with the version it needs'               ($td -match '(?i)@azure/identity 4\.11\.0')
Assert 'and dev as the older fallback'           ($td -match '(?i)dev\s+\(older versions; also excludes MI\)')
Assert 'an existing setting is not overwritten'  ($td -match "GetEnvironmentVariable\('AZURE_TOKEN_CREDENTIALS', 'User'\)")
Assert 'the token override is warned against'    ($td -match 'ANTHROPIC_FOUNDRY_AUTH_TOKEN')
Assert 'because it expires'                      ($td -match '(?i)expires in about an hour')
Assert 'the pin is documented'                   ($fd -match "SetEnvironmentVariable\('AZURE_TOKEN_CREDENTIALS','AzureCliCredential','User'\)")
Assert 'and cited'                               ($fd -match 'credential-chains#defaultazurecredential-overview')
Assert 'with the token override ruled out'       ($fd -match '(?i)Do not set `ANTHROPIC_FOUNDRY_AUTH_TOKEN`')
# Hand-written configuration is where invented model names come from. Claude
# Code refuses with "not available on your foundry deployment", which reads as
# the resource being wrong rather than the file. Reproduced on a healthy
# resource by writing a config in that style.
Assert 'configured models are checked as real'   ($td -match '(?i)Every configured model exists on the resource')
Assert 'covering all three aliases'              ($td -match "ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL'")
Assert 'and the available list'                  ($td -match "Where = 'availableModels'")
Assert 'each invented name is named'             ($td -match '\$\(\$i\.Where\) = \$\(\$i\.Name\)')
Assert 'with what is really deployed'            ($td -match "'deployed here: '")
Assert 'and a repair that discovers them'        ($td -match '(?i)rewrite the model names from what is deployed')
# A file higher in the precedence order silently wins. Without this the check
# reads the user file, calls it correct, and is looking at settings nothing
# uses - which is how a model name appears that is in no file being read.
Assert 'overriding settings files are found'     ($td -match '(?i)Nothing overrides the settings just checked')
Assert 'including the project local one'         ($td -match "settings\.local\.json'\); What = 'project \(local\)'")
Assert 'and the shared project one'              ($td.Contains(".claude\settings.json');       What = 'project (shared)'"))
Assert 'the precedence order is stated'          ($td -match '(?i)Lowest to highest: ~/\.claude/settings\.json')
Assert 'and only Foundry keys are reported'      ($td -match "ANTHROPIC_\|CLAUDE_CODE_USE_FOUNDRY\|AZURE_")

# Read locally: $devGuide is assigned further down this file.
$devFaq = Get-Content (Join-Path $root 'DEVELOPER.md') -Raw
Assert 'the FAQ covers the override'             ($devFaq -match '(?i)I fixed my settings and Claude Code still uses the old model')
Assert 'with the four places in order'           ($devFaq -match '(?i)`\.claude/settings\.local\.json` in the project folder')
Assert 'and why the local one catches people'    ($devFaq -match '(?i)per-machine and usually untracked')
Assert 'it says a new session is needed'         ($devFaq -match '(?i)a running one keeps what it loaded')
# Every resource carries different deployments. Nothing on the direct path may
# assume a model name - measured on a resource holding only claude-opus-4-7,
# where a hardcoded claude-sonnet-5 failed the Messages check on a resource
# that was entirely healthy.
Assert 'the test model is discovered'           ($td -match '(?i)testing with \$Model')
Assert 'and nothing is assumed when it cannot be' ($td -match '(?i)will not invent a name')
Assert 'the round trip is skipped without one'  ($td -match 'if \(\$token -and \$Model\)')
Assert 'no model name is hardcoded in the check' (-not ([regex]::Matches(
    (($td -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s{4}\S.*claude-' }) -join "`n",
    "'claude-(sonnet|opus|haiku)-[0-9]") ).Count)

$sd2 = Get-Content (Join-Path $root 'scripts/Setup-ClaudeFoundryDirect.ps1') -Raw
Assert 'every alias names a real deployment'    ($sd2 -match '\$fallback = if \(\$sonnet\)')
Assert 'including one with no Sonnet at all'    ($sd2.Contains('ANTHROPIC_DEFAULT_SONNET_MODEL''] = if ($sonnet) { $sonnet } else { $fallback }'))
Assert 'and a substitution is reported'         ($sd2 -match '(?i)those aliases point at \$fallback')
Assert 'the setup assumes no model name'        (-not ([regex]::Matches(
    (($sd2 -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n",
    "= 'claude-(sonnet|opus|haiku)-[0-9]") ).Count)
# The Desktop 400. Documented separately because it is the one failure here
# that a role assignment cannot touch.
Assert 'the device-code 400 is documented'    ($fd -match '(?i)Foundry Entra device init failed: HTTP 400')
Assert 'and ruled out as an RBAC problem'     ($fd -match '(?i)No role assignment can fix this')
Assert 'the request it makes is shown'        ($fd -match 'oauth2/v2\.0/devicecode')
Assert 'and that it precedes any token'       ($fd -match '(?i)before any token exists')
Assert 'the three AADSTS causes are listed'   (($fd -match 'AADSTS7000218') -and
                                               ($fd -match 'AADSTS700016') -and
                                               ($fd -match 'AADSTS90002'))
Assert 'the public-client toggle is named'    ($fd -match 'isFallbackPublicClient')
Assert 'the CLI client id is offered'         ($fd -match '04b07795-8ddb-461a-bbee-02f9e1bf7b46')
Assert 'and its caveat given'                 ($fd -match '(?i)blocked?k? it with Conditional Access|block it with Conditional Access')
Assert 'the helper-script escape is named'    ($fd -match '(?i)never calls `/devicecode`')
# Troubleshooting belongs in its own section, not buried in the model list.
Assert 'diagnostics is its own section'       ($fd -match '(?m)^## 4\. Diagnostics')
# A developer reads DEVELOPER.md, not the admin guide, so both errors have to
# be findable there or the diagnosis might as well not exist. Read locally
# rather than relying on a variable defined further down this file.
$devGuide = Get-Content (Join-Path $root 'DEVELOPER.md') -Raw
Assert 'the developer guide lists the 401'    ($devGuide -match 'Principal does not have access to API/Operation')
Assert 'and the device-code 400'              ($devGuide -match 'Foundry Entra device init failed')
Assert 'and links to the diagnostics'         ($devGuide -match 'FOUNDRY-DIRECT\.md#4-diagnostics')
Assert 'saying the 400 is not a role'         ($devGuide -match '(?i)no role assignment can fix it')
# Desktop by hand. It cannot read settings.json, so the manual route is a
# genuinely different set of steps rather than a variation on the CLI one.
Assert 'Desktop can be configured by hand'    ($devGuide -match '(?i)Claude Desktop, if you use it')
Assert 'it says Desktop ignores settings.json' ($devGuide -match '(?i)cannot read\s*\n?`~/\.claude/settings\.json`')
Assert 'it is quit before writing'            ($devGuide -match '(?i)rewrites its\s*\n?configuration on exit')
Assert 'and stopped by id'                    ($devGuide -match 'Stop-Process -Id \$_\.Id')
Assert 'a full reset is offered'              ($devGuide -match 'Remove-Item "\$env:LOCALAPPDATA\\Claude-3p\\configLibrary"')
Assert 'developer mode comes first'           ($devGuide -match '(?i)there is no \*\*Settings')
Assert 'the helper is proved before use'      ($devGuide -match '(?i)Prove the helper works before Desktop depends on it')
Assert 'the tenant variable is explained'     ($devGuide -match 'CLAUDE_FOUNDRY_TENANT_ID')
Assert 'the meta GUID must match'             ($devGuide -match '(?i)leaves it silently on the default profile')
Assert 'and the cmd shim is required'         ($devGuide -match '(?i)Use the \*\*`\.cmd`\*\*, not the `\.ps1`')
# Desktop can own the sign-in itself instead of shelling out to the Azure CLI.
# The default scopes in that screen produce a Graph-audience token, which the
# gateway policy refuses - so the scope has to be written down.
Assert 'the OAuth route is documented'        ($devGuide -match '(?i)Letting Desktop do the sign-in itself')
Assert 'the required audience is named'       ($devGuide -match 'https://cognitiveservices\.azure\.com/\.default offline_access')
Assert 'and the default scopes ruled out'     ($devGuide -match '(?i)Microsoft Graph audience')
Assert 'an access token, not an id token'     ($devGuide -match '(?i)Access token\*\*, not ID token')
Assert 'and it says a registration is needed' ($devGuide -match '(?i)needs a redirect URI, so unlike the helper')
# A browser is not available on a jump box, and the gateway script offered no
# alternative - it announced "a browser window will open" and then hung.
$wsg = Get-Content (Join-Path $root 'scripts/Setup-ClaudeWorkstation.ps1') -Raw
Assert 'the gateway offers device code'       ($wsg -match "\[ValidateSet\('interactive', 'device'\)\]")
Assert 'and passes it to az'                  ($wsg -match "loginArgs \+= '--use-device-code'")
Assert 'the browser default says the way out' ($wsg -match '(?i)re-run with -Auth device')
$hlp = Get-Content (Join-Path $root 'scripts/get-foundry-token.ps1') -Raw
Assert 'the helper can too'                   ($hlp -match 'CLAUDE_FOUNDRY_AUTH')
Assert 'without polluting stdout'             ($hlp -match '(?i)stdout carries the token and nothing else')
Assert 'and it is documented'                 ($devGuide -match '(?i)Signing in without a browser')
# The helper is copied from beside the script, not generated, and it has to
# stay installed - Desktop re-runs it on every refresh.
Assert 'the helper origin is documented'      ($devGuide -match '(?i)\*\*copied,\s*\n?not generated\*\*')
Assert 'and the whole folder is needed'       ($devGuide -match '(?i)Fetch the folder, not the one file')
Assert 'and that it must stay installed'      ($devGuide -match '(?i)breaks Desktop at the next refresh')
Assert 'the missing-helper warning is useful' ($wsg -match '(?i)copied, not generated, so Claude Desktop cannot be')
Assert 'and says what still worked'           ($wsg -match '(?i)The CLI and VS Code are unaffected')
Assert 'no profile is written without it'     ($wsg -match '(?m)^\s*if \(Test-Path \$helperCmd\) \{')
$shim = Get-Content (Join-Path $root 'scripts/get-foundry-token.cmd') -Raw
Assert 'the shim names the real directory'    ($shim -match 'LOCALAPPDATA%\\ClaudeFoundry')
Assert 'and refuses without its partner'      ($shim -match 'if not exist "%HELPER%"')
# Desktop spawns the helper with the environment the app was started with, so
# a PATH entry added since launch is invisible. Measured: az resolvable in a
# shell, and the helper still reported "not found on PATH" under Desktop.
Assert 'the helper does not trust PATH'       ($hlp.Contains('Microsoft SDKs\Azure\CLI2\wbin\az.cmd'))
Assert 'it searches the real install roots'   (($hlp -match '\$env:ProgramFiles') -and
                                               ($hlp -match '\$\{env:ProgramFiles\(x86\)\}'))
Assert 'and says when it fell back'           ($hlp -match '(?i)az not on PATH; using')
Assert 'the fallback is reported on stderr'   ($hlp -match 'function Write-Diag')
Assert 'a genuine absence names the fix'      ($hlp -match '(?i)quit Claude Desktop completely')
Assert 'and why restarting helps'             ($hlp -match '(?i)inherits the environment')
Assert 'no stale handle survives the change'  ($hlp -notmatch '\$az\.Source')
Assert 'it says what it is for'          ($fd -match '(?i)evaluating Foundry, not for running a team')
# The uncomfortable part: this repository ships an audit that looks for exactly
# what this script configures, and a health check that fails on it. A document
# that does not reconcile those leaves an operator to discover it as a bug.
Assert 'it names the bypass audit'       ($fd -match 'Get-ClaudeBypass\.ps1')
Assert 'and that the health check fails' ($fd -match '(?i)fails the\W+run')
Assert 'and calls that correct'          ($fd -match '(?i)correct rather than a false positive')
Assert 'and refuses suppression'         ($fd -match '(?i)does not work is suppressing')
# Revocation works differently here, and assuming otherwise leaves access open.
Assert 'it says group removal does nothing' ($fd -match '(?i)taking\W+somebody out of')
Assert 'and names the real revocation'      ($fd -match '(?i)remove the role assignment')
Assert 'the mutual exclusion is documented' ($fd -match 'mutually\W+exclusive')
Assert 'the config file is documented'      ($fd -match 'claude-foundry-direct\.json')
Assert 'with its schema'                    ($fd -match '"foundryResource"')
Assert 'and why mode is in it'              ($fd -match '(?i)mode.{0,30}earns its place')
Assert 'and that it holds no credential'    ($fd -match '(?i)Nothing in the file is a credential')

# Manual steps, for people who cannot run the script or want to check it.
Assert 'it documents configuring by hand'   ($fd -match '(?i)Configuring it by hand')
Assert 'the role assignment is step two'    ($fd -match 'Cognitive Services User')
Assert 'and it says a role is not a group'  ($fd -match '(?i)an Azure \*\*role\*\*, not group')
# The VS Code setting is an array of name/value pairs. Read from the installed
# extension's own schema, which requires both properties - a map looks
# reasonable, is accepted by the JSON editor, and does nothing.
Assert 'the VS Code setting shape is shown' ($fd -match '"claudeCode\.environmentVariables": \[')
Assert 'and given as name and value pairs'  ($fd -match '\{ "name": "CLAUDE_CODE_USE_FOUNDRY"')
Assert 'and said to be an array'            ($fd -match '(?i)array of name/value objects')
# The extension prefers settings.json, so duplicating into VS Code is usually
# unnecessary - the opposite of what the gateway appendix used to imply.
Assert 'it says VS Code usually needs nothing' ($fd -match '(?i)Usually nothing to do')
Assert 'the login prompt can be turned off'    ($fd -match 'claudeCode\.disableLoginPrompt')
Assert 'and a reload is required'              ($fd -match '(?i)Developer: Reload Window')
# Where the files actually are. Both are called settings.json and only one of
# them follows the OS config directory, which is the whole confusion.
Assert 'the Claude settings path is given'     ($fd.Contains('%USERPROFILE%\.claude\settings.json'))
Assert 'on macOS and Linux too'                ($fd -match '~/\.claude/settings\.json')
Assert 'and noted as the same everywhere'      ($fd -match '(?i)Same location on every platform')
Assert 'the VS Code path is given'             ($fd.Contains('%APPDATA%\Code\User\settings.json'))
Assert 'and its macOS location'                ($fd -match 'Library/Application Support/Code/User/settings\.json')
Assert 'and its Linux location'                ($fd -match 'XDG_CONFIG_HOME:-~/\.config\}/Code/User/settings\.json')
Assert 'the two files are distinguished'       ($fd -match '(?i)different file\*\* in a\s*\n?\*\*different place')
Assert 'the Settings UI is ruled out'          ($fd -match '(?i)not the Settings UI')
Assert 'the local override is named'           ($fd -match 'settings\.local\.json')
Assert 'and the state file is not config'      ($fd -match '(?i)Not configuration; do not hand-edit')

$dev2 = Get-Content (Join-Path $root 'DEVELOPER.md') -Raw
Assert 'the gateway appendix shows the shape too' ($dev2 -match '"claudeCode\.environmentVariables": \[')
Assert 'and no longer implies duplication'        ($dev2 -notmatch 'VS Code needs the same values again')
Assert 'it gives the VS Code settings path'       ($dev2.Contains('%APPDATA%\Code\User\settings.json'))
Assert 'and the Claude settings path'             ($dev2.Contains('%USERPROFILE%\.claude\settings.json'))

$rmd = Get-Content (Join-Path $root 'README.md') -Raw
Assert 'the README links the direct guide' ($rmd -match '\[Foundry direct\]\(docs/FOUNDRY-DIRECT\.md\)')

Write-Host ''
Write-Host 'Admin - documentation' -ForegroundColor Cyan

$mig_doc = Get-Content (Join-Path $root 'docs/MIGRATION.md') -Raw
Assert 'migration documents the workstation tool' ($mig_doc -match 'Migrate-ClaudeWorkstation')
Assert 'and the Desktop backup'                   ($mig_doc -match 'Backup-ClaudeDesktop')
$setup = Get-Content (Join-Path $root 'docs/SETUP.md') -Raw
Assert 'setup documents SKU sizing'               ($setup -match '(?i)how many developers')

# Only Install-ClaudeGateway.ps1 writes onboarding/claude-gateway.json - grep
# the repository and it is the single writer. deploy.ps1 and the portal button
# both leave the reader without the file their developers' setup script reads,
# and neither said so. Asserted on the sentence, not on the filename, which
# appears throughout the page.
Assert 'setup says the script route skips the handover file' `
    ($setup -match 'does \*\*not\*\* write `onboarding/claude-gateway\.json`')
Assert 'and that only the wizard writes it' `
    ($setup -match 'Only the wizard writes that')
Assert 'the portal route lists what it leaves undone' `
    ($setup -match 'Three things the wizard does are left to')
$onb = Get-Content (Join-Path $root 'docs/ONBOARDING.md') -Raw
Assert 'onboarding documents tier limits'         ($onb -match 'Set-ClaudeTier')

# Revocation. Two claims here are load-bearing and were both wrong before:
#
#  - removing one tier group leaves a premium developer entitled, so the
#    documented command has to be the one that clears both tiers and every
#    business unit rather than a single `az ad group member remove`
#  - disabling an Entra account does not invalidate a token already issued.
#    validate-jwt checks the signature and claims and does not call Entra per
#    request, so the old text sent an admin away believing access had stopped
#
# Matched on the specific sentence, not on 'revoke' or 'token', because both
# words appear either side of the correction.
Assert 'revocation uses the command that clears every group' `
    ($onb -match 'Set-ClaudeDeveloper\.ps1 -User [^\r\n]*-Remove -Sync')
Assert 'and says a disabled account is not the revocation' `
    ($onb -match 'does not invalidate one already issued')
Assert 'and names why the gateway cannot tell' `
    ($onb -match 'does not call Entra per request')
Assert 'the checklist covers business unit groups' `
    ($onb -match '(?m)^- \[ \] Removed from every business-unit and team group')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Admin surface contract holds.' -ForegroundColor Green
exit 0
