# P18b: the load envelope, and the ceilings that decide it.
#
# The failure this guards against is a capacity claim with no measurement
# behind it. Two specific ways that happens here:
#
#   a ceiling copied from a document   Documents drift, and the one for named
#                                      values disagreed with the service. Every
#                                      figure the script enforces has to be
#                                      derived or measured, not pasted
#
#   a traffic model invented to fill   The reference deployment holds 111
#   a gap                              requests across 2 days. An envelope
#                                      extrapolated from that would read as
#                                      evidence and be nothing of the kind
#
# Offline. The live half ran against the reference gateway: 4,096 characters
# accepted and 4,097 rejected, 110 object ids accepted and 111 rejected.

$root = Split-Path $PSScriptRoot -Parent
$ceiling = Join-Path $root 'scripts/Measure-ClaudeCeiling.ps1'
$scale = Join-Path $root 'docs/SCALE.md'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Scale - the ceiling measurement' -ForegroundColor Cyan

Assert 'a ceiling script exists' (Test-Path $ceiling)
$c = Get-Content $ceiling -Raw

# The limit itself. Asserted as the assignment, because the comment above it
# explains the measurement and repeats every number in prose - matching "4096"
# anywhere in the file would pass with the constant deleted.
Assert 'the character limit is the measured one' ($c -match '\$MaxChars\s*=\s*4096')
Assert 'an object id costs 37 characters'        ($c -match '\$OidCost\s*=\s*37')

# The identity ceiling has to be derived from those two. A hard-coded 110 would
# still be correct today and would silently stop being correct if the service
# raised the limit.
Assert 'the identity ceiling is derived, not pasted' `
    ($c -match '\$MaxIdentities\s*=\s*\[int\]\[math\]::Floor\(\(\$MaxChars - 1\) / \$OidCost\)')
Assert 'and it is not written as a literal' ($c -notmatch '\$MaxIdentities\s*=\s*110')

# Per-entry cost is measured from the list being read. bu-members entries carry
# "oid=unit" and cost more than a bare object id, so assuming 37 would overstate
# the remaining room on exactly the list that fills first.
Assert 'per-entry cost is measured from the data' `
    ($c -match '\$per\s*=\s*if \(\$items\.Count\)\s*\{\s*\[int\]\[math\]::Ceiling\(\$chars / \$items\.Count\)')

# A secret named value returns no value. Counting that as an empty list reads as
# maximum headroom, which is the wrong direction to be wrong in.
Assert 'a secret list is reported, not counted as empty' ($c -match 'if \(\$entry\.secret\)')

# It has to fail, not just report. The condition is asserted rather than the
# word "exit", which appears on the success path too.
Assert 'it exits non-zero past the threshold' `
    ($c -match 'if \(\$worst -ge \$FailAtPercent\)[\s\S]{0,600}exit 1')
Assert 'the threshold is overridable' ($c -match '\[int\]\$FailAtPercent = 80')

# The published per-instance caps differ by SKU, and a wrong cap is worse than
# a missing one, so an unrecognised SKU must say so rather than default.
Assert 'named value caps are held per SKU'   ($c -match "'StandardV2'\s*=\s*10000")
Assert 'and Basic v2 is the lower figure'    ($c -match "'BasicV2'\s*=\s*5000")
Assert 'an unknown SKU is reported, not guessed' ($c -match 'Unknown SKU')

Write-Host ''
Write-Host 'Scale - the envelope' -ForegroundColor Cyan

Assert 'the envelope is documented' (Test-Path $scale)
$s = Get-Content $scale -Raw

Assert 'it names the tier list ceiling'  ($s -match '110 object ids is 4,071 characters')
# 110 is right for a tier list and wrong as *the* ceiling. A bu-members entry is
# "oid=unit," - 38 characters plus the unit name - so it holds about 93 with a
# six-character unit id, and fewer with a longer one. Business-unit membership
# therefore runs out first, and an operator planning against 110 over-plans by
# roughly a fifth.
#
# \s+ between words and a tolerant gap for markdown emphasis: the sentence wraps
# and carries ** around "longer unit name", so a plain phrase match fails for
# reasons that have nothing to do with the claim.
Assert 'it names the lower business-unit ceiling' ($s -match '(?m)about 93')
Assert 'and says that one binds first'            ($s -match 'business-unit membership\s+runs out first')
Assert 'and that it varies with the unit name'    ($s -match 'longer unit\W+name')Assert 'it states writes fail, not truncate' ($s -match 'fails outright')
Assert 'it rejects sharding as the escape'   ($s -match 'Sharding does not rescue it')
Assert 'and says why, not just that'         ($s -match 'in \*\*API Management policy configuration\*\* is what cannot work')

# The five numbers. A capacity page that lists only headcount is the thing this
# packet exists to stop.
foreach ($n in 'Daily active developers', 'Peak requests per second', 'Peak token rate',
                'Streaming concurrency', 'Burst shape') {
    Assert "the envelope asks for $n" ($s -match [regex]::Escape($n))
}

# The honesty requirement. This deployment cannot supply a traffic model, and
# the page has to say so rather than quietly presenting the method as a result.
#
# Asserted as a shape rather than a number. The first version pinned the exact
# figure, which went stale the moment the 30-day window moved past the days it
# counted - the test then failed for the page being current. What has to hold
# is that a measured figure is quoted with the date it was read, not which
# figure it is.
Assert 'it states what has not been measured' ($s -match 'ledger\s+holds \*\*\d+ requests across \d+ days\*\*')
Assert 'with the date it was read'            ($s -match 'measured 20\d\d-\d\d-\d\d')
Assert 'and calls it a demonstration'         ($s -match 'demonstration, not a traffic model')
Assert 'and refuses to extrapolate from it'   ($s -match 'evidence behind it')

# A counter test that only proves keys can be created proves nothing about
# whether allowance survives.
Assert 'it defines what a capacity test must prove' ($s -match 'retains its consumed allowance')
foreach ($e in 'Scale-out', 'Policy deployment', 'Period rollover') {
    Assert "and covers $e" ($s -match [regex]::Escape($e))
}

Assert 'it points at the projection decision' ($s -match 'adr/0005-identity-projection\.md')

# The first thing a reviewer proposes is "put the tier in a token claim and skip
# the lookup". It cannot work here and that has to be written down, or it gets
# re-proposed every review: the policy validates tokens for
# https://cognitiveservices.azure.com, a first-party Microsoft resource, and
# app roles and the groups claim are configured on the application registration.
# Nobody here owns that registration, so there is nowhere to put the claim.
Assert 'the closed token-claim path is recorded' ($s -match '(?m)^### Why not put the tier in the token')
Assert 'it names the audience that closes it'    ($s -match 'cognitiveservices\.azure\.com')
Assert 'and why the claim cannot be added'       ($s -match 'do not own that registration')

Write-Host ''
Write-Host 'Scale - the shadow comparison (P19b)' -ForegroundColor Cyan

$cmp = Join-Path $root 'scripts/Compare-ClaudeEntitlement.ps1'
Assert 'a comparison script exists' (Test-Path $cmp)
$p = Get-Content $cmp -Raw

# Both sides must read the directory the same way. The membership read was
# extracted precisely so the writer and the comparison cannot drift; a
# comparison with its own Graph call reports its own bugs as drift.
Assert 'the comparison reuses the shared membership read' `
    ($p -match "ClaudeGraphMembership\.ps1'\)")
$sync = Get-Content (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') -Raw
Assert 'and so does the sync' ($sync -match "ClaudeGraphMembership\.ps1'\)")
Assert 'neither still defines its own'  ($p -notmatch 'function Get-GroupMemberOids' -and $sync -notmatch 'function Get-GroupMemberOids')

$shared = Join-Path $root 'scripts/ClaudeGraphMembership.ps1'
Assert 'the shared helper exists' (Test-Path $shared)
$sh = Get-Content $shared -Raw
# The request form that took six measured combinations to find lives here now,
# so these assert it in its new home rather than where it used to be.
Assert 'it asks for service principals'   ($sh -match [regex]::Escape("Type = 'microsoft.graph.servicePrincipal'"))
Assert 'it sends ConsistencyLevel eventual' ($sh -match [regex]::Escape("`$headers['ConsistencyLevel'] = 'eventual'"))
Assert 'and counts, which that header requires' ($sh -match [regex]::Escape('&`$count=true"'))

# Precedence has to match the policy or the comparison invents drift. The
# policy tests premium first; so must this.
Assert 'premium is resolved before standard' `
    ($p -match "if \(\`$Premium -contains \`$Oid\)\s*\{\s*return 'premium' \}[\s\S]{0,120}if \(\`$Standard -contains \`$Oid\)")
$policy = Get-Content (Join-Path $root 'infra/policy.xml') -Raw
Assert 'which is the order the policy uses' `
    ($policy -match 'allow-premium\}\}"\)\.Contains\(oid\)[\s\S]{0,200}allow-standard\}\}"\)\.Contains\(oid\)')

# A secret named value returns no value. Treating it as empty would report
# every entitled identity as missing - a page of false drift, not a finding.
Assert 'a secret list stops the comparison' ($p -match 'if \(\$o\.secret\)[\s\S]{0,200}throw')

# The three outcomes are not interchangeable: one is a developer waiting, one
# is access that should have gone.
foreach ($k in 'missing', 'stale', 'tier-drift') {
    Assert "it distinguishes $k" ($p -match "'$k'")
}
Assert 'stale is described as access outliving removal' ($p -match 'Still entitled after removal')
Assert 'it fails the run on drift' ($p -match 'if \(\$drift\.Count -and \$FailOnDrift\)[\s\S]{0,60}exit 1')

$adr = Join-Path $root 'docs/adr/0009-shadow-migration.md'
Assert 'the migration decision is recorded' (Test-Path $adr)
$a = Get-Content $adr -Raw
Assert 'authorization changes only at the canary' ($a -match '(?m)^Five phases\. Authorization does not change until phase 4')
Assert 'a rollback does not return spent allowance' ($a -match 'restores authorization, never consumption')
Assert 'counter keys are preserved, not migrated'  ($a -match 'Counter keys do not change during migration')
Assert 'the opening balance is deferred, not fudged' ($a -match 'deferred to P20b')
Assert 'and the comparison was negative-tested'   ($a -match 'produced `stale \(1\)` and exit 1')

Write-Host ''
Write-Host 'Scale - the overshoot bound (P25)' -ForegroundColor Cyan

$ovs = Join-Path $root 'scripts/Measure-ClaudeOvershoot.ps1'
Assert 'an overshoot measurement exists' (Test-Path $ovs)
$o = Get-Content $ovs -Raw

# Lag is read from the data, not polled for. The polling version reported "not
# visible within 420s" against a real lag near 80 seconds, because it caught and
# discarded its own query errors - a failing query and an empty result were
# indistinguishable.
Assert 'lag is measured with ingestion_time'  ($o -match "datetime_diff\('second', ingestion_time\(\), TimeGenerated\)")
Assert 'and the query is not silently caught' ($o -notmatch '(?s)Invoke-RestMethod[^\r\n]*loganalytics[\s\S]{0,400}\}\s*catch\s*\{\s*\}')

# The bound takes the worst case. A median bound is wrong about half the time,
# in the direction that matters.
Assert 'the bound uses the worst lag'   ($o -match 'worst = max\(lag\)')
Assert 'and the median is reported too' ($o -match 'p50 = percentile\(lag, 50\)')
Assert 'the worst case feeds the window' ($o -match '\$result\.telemetry_seconds = \[int\]\$row\[2\]')

# Propagation has to be observed through the gateway. Reading the named value
# back from ARM returns the new value at once and says nothing about when the
# policy sees it.
Assert 'propagation is observed at the gateway' ($o -match "x-quota-remaining-today")
Assert 'and it polls until the policy serves it' ($o -match '\[long\]\$rem -le \$probe')

# Three workspaces in the reference group, and [0] was not the gateway's. The
# first run reported zero requests against a ledger holding 29.
Assert 'an ambiguous workspace is refused' ($o -match "workspaces in '\`$ResourceGroup'")
Assert 'and it never takes the first one'  ($o -notmatch '\[0\]\.customerId')

# Whatever happens, the override must not be left behind.
Assert 'the override is restored in a finally' ($o -match '(?s)finally\s*\{[\s\S]{0,400}Set-Nv ''quota-overrides'' \$saved')
Assert 'and a failed restore is loud'          ($o -match 'RESTORE FAILED')

Assert 'an incomplete measurement fails the run' ($o -match 'if \(-not \$result\.complete\)[\s\S]{0,40}exit 1')

Assert 'the measured bound is documented'  ($s -match 'delayed kill switch, not a hard cap')
Assert 'with the measured terms'           ($s -match '\*\*193s worst\*\*' -and $s -match '\*\*17s\*\*' -and $s -match '\*\*511s\*\*')
Assert 'it says why the median is not used' ($s -match 'A bound built on the median would be wrong')
Assert 'and what a hard cap would need'     ($s -match 'admission-time budget reservation')

Write-Host ''
Write-Host 'Scale - what the projection costs (ADR-0011)' -ForegroundColor Cyan

$cost = Join-Path $root 'scripts/Measure-ClaudeProjectionCost.ps1'
Assert 'a cost model exists' (Test-Path $cost)

# Behavioural. The claim that decides P19 is that the bill is small at the full
# requirement, so assert the number rather than the prose describing it.
$big = & $cost -Developers 500000 -DailyActive 50000 -CacheMinutes 60 -AsJson | ConvertFrom-Json
# Under $100: the usage lines are about $4, and the rest is what the private
# shape bills at rest - five endpoints, five zones and one warm resolver
# instance, as deployed and measured 2026-09-23. The earlier $11.11 priced one
# endpoint and no warm instance.
Assert '500k developers cost tens of dollars, not thousands' ($big.monthly_usd.total -lt 100 -and $big.monthly_usd.total -gt 0) "got $($big.monthly_usd.total)"
Assert 'and the projection is under a gigabyte'    ($big.derived.storage_gb -lt 1) "got $($big.derived.storage_gb)"

# The private endpoint is the only line that bills at rest, and it was found by
# deploying rather than by reading a pricing page: the reference subscription
# enforces publicNetworkAccess Disabled above the resource group. An accelerator
# for large enterprises has to assume that baseline, so it defaults on.
Assert 'private networking is priced in'  ($big.monthly_usd.private_endpoint -gt 0)
Assert 'and defaults to on'               ((Get-Content $cost -Raw) -match '\[bool\]\$PrivateNetworking = \$true')
Assert 'every endpoint the deployment has is counted' ((Get-Content $cost -Raw) -match '\[int\]\$PrivateEndpoints = 5,')
Assert 'and every zone'                   ($big.monthly_usd.private_dns_zones -eq 2.5) "got $($big.monthly_usd.private_dns_zones)"
$open = & $cost -Developers 500000 -DailyActive 50000 -PrivateNetworking:$false -AsJson | ConvertFrom-Json
Assert 'turning it off removes exactly the network lines' `
    ([math]::Round($big.monthly_usd.total - $open.monthly_usd.total, 2) -eq [math]::Round($big.monthly_usd.private_endpoint + $big.monthly_usd.private_dns_zones, 2))
# A warm instance is a cold-start decision, not a network one, and it is the
# single largest line at rest.
$cold = & $cost -Developers 500000 -DailyActive 50000 -AlwaysReadyInstances 0 -AsJson | ConvertFrom-Json
Assert 'a warm resolver instance is priced'  ($big.monthly_usd.resolver_always_ready -eq 26.28) "got $($big.monthly_usd.resolver_always_ready)"
Assert 'and choosing none removes exactly it' `
    ([math]::Round($big.monthly_usd.total - $cold.monthly_usd.total, 2) -eq $big.monthly_usd.resolver_always_ready)

# Cost follows cache misses, not requests. If that ever inverts, the model is
# measuring the wrong thing and every figure built on it is wrong.
$short = & $cost -Developers 500000 -DailyActive 50000 -CacheMinutes 15 -AsJson | ConvertFrom-Json
Assert 'a shorter cache window costs more' ($short.monthly_usd.total -gt $big.monthly_usd.total)
Assert 'and it scales with the window, four to one' `
    ([math]::Abs(($short.derived.misses_per_month / $big.derived.misses_per_month) - 4) -lt 0.01)

# A pilot pays only what bills at rest - the usage lines round to nothing - or
# the pay-per-use claim is not true.
$small = & $cost -Developers 8 -DailyActive 8 -AsJson | ConvertFrom-Json
Assert 'a small pilot pays only what bills at rest' ($small.monthly_usd.total -eq $small.monthly_usd.at_rest) "got $($small.monthly_usd.total) against $($small.monthly_usd.at_rest)"
Assert 'and at rest is the three standing lines'    ($small.monthly_usd.at_rest -eq [math]::Round($small.monthly_usd.private_endpoint + $small.monthly_usd.private_dns_zones + $small.monthly_usd.resolver_always_ready, 2))

# Rates change and are regional. They must be parameters with a read date, not
# constants buried in arithmetic - the same reason the token price book moved to
# config/price-book.json.
$c = Get-Content $cost -Raw
Assert 'rates are parameters'      ($c -match '\[decimal\]\$UsdPerMillionRu')
Assert 'and carry a read date'     ($c -match 'read 2026-09-17')

# The free grant, asserted by its effect rather than by its name. Renaming only
# the parameter leaves the body referencing an undefined variable, which
# PowerShell coerces to 0 - the grant silently disappears while the identifier
# is still present in the file, so a name match passes on broken code.
#
# 28,409 active developers is about 5M executions, comfortably past the 1M
# grant, so the grant has to be visible in the arithmetic.
$above = & $cost -Developers 500000 -DailyActive 28409 -AsJson | ConvertFrom-Json
$execs = $above.derived.misses_per_month
$expected = [math]::Round((($execs - 1000000) / 1000000) * 0.20, 2)
Assert 'the free execution grant is subtracted' `
    ($above.monthly_usd.functions -eq $expected) "got $($above.monthly_usd.functions), expected $expected from $execs executions"

$a11 = Join-Path $root 'docs/adr/0011-projection-platform.md'
Assert 'the platform decision is recorded' (Test-Path $a11)
$d11 = Get-Content $a11 -Raw
Assert 'it names both components'  ($d11 -match 'Cosmos DB serverless' -and $d11 -match 'Functions on the Consumption plan')
Assert 'it states the total'       ($d11 -match '\*\*\$11\.11\*\*')
Assert 'and records the deployment finding' ($d11 -match 'publicNetworkAccess: Disabled')
Assert 'and that Consumption cannot reach it' ($d11 -match 'Y1 Consumption plan has no VNet integration')
# Serverless is cheap and gives no latency guarantee. Recording the price
# without the trade would be selling it.
Assert 'it records the latency trade' ($d11 -match 'no guaranteed throughput or latency')
Assert 'and the serverless ceiling'   ($d11 -match '5,000 RU/s')
# The window is a revocation decision, not a budget one.
Assert 'it says to choose the window on revocation' ($d11 -match 'choose the window on the revocation requirement')
Assert 'and leaves that number open' ($d11 -match 'remains open')

Write-Host ''
Write-Host 'Scale - the projection template' -ForegroundColor Cyan

$proj = Join-Path $root 'infra/projection.bicep'
Assert 'the projection template exists' (Test-Path $proj)
$pb = Get-Content $proj -Raw

# The partition key is the whole design. /oid gives one logical partition per
# identity and a 1-RU point read. /tenantId - which the ADR-0005 wording invites -
# puts all 500,000 in a single logical partition against a 20 GB cap, and looks
# perfectly healthy at eight developers.
Assert 'it partitions on the object id' ($pb -match "paths:\s*\[\s*'/oid'\s*\]")
Assert 'and not on the tenant'          ($pb -notmatch "paths:\s*\[\s*'/tenantId'\s*\]")

# Serverless, so an accelerator shipped to a customer with eight developers
# bills them nothing and the same template serves 500,000.
Assert 'the account is serverless' ($pb -match "name:\s*'EnableServerless'")

# The gateway reaches Foundry with a managed identity. A connection-string key
# on the projection would reintroduce exactly the credential this accelerator
# exists to remove.
Assert 'local auth is disabled' ($pb -match 'disableLocalAuth:\s*true')

# It must not be in the default install path. Wiring it in would give every
# customer a Cosmos account nothing reads plus a private endpoint billing at
# rest, for a feature that does nothing until the resolver exists.
$mainBicep = Get-Content (Join-Path $root 'infra/main.bicep') -Raw
$installer2 = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
Assert 'the installer does not deploy it yet' `
    ($mainBicep -notmatch 'projection\.bicep' -and $installer2 -notmatch 'projection\.bicep')
Assert 'and the guide says why'  ($s -match 'not wired into the installer')
Assert 'and how to deploy it alone' ($s -match 'template-file infra/projection\.bicep')

Write-Host ''
Write-Host 'Scale - the projection, measured (P19)' -ForegroundColor Cyan

# The claim the whole design rests on: a lookup is a point read whose cost does
# not follow collection size. Measured from inside the VNet, because the data
# plane is unreachable from outside it.
Assert 'the capacity result is recorded'    ($s -match 'The projection, measured 2026-09-17')
Assert 'it reports the measured sizes'      ($s -match '\| \*\*100,000\*\* \| \*\*1\*\* \|')
# U14, closed 2026-09-23: through the gateway, a miss against a hit, with the
# model call taken out so the lookup is all that differs.
Assert 'the lookup cost is recorded'        ($s -match 'The lookup through the gateway, measured 2026-09-23')
Assert 'with miss percentiles'              ($s -match '\| Cache miss \(1-second window, 1\.2 s apart\) \| 67 ms \| \*\*91 ms\*\* \| \*\*149 ms\*\* \| \*\*301 ms\*\* \| 389 ms \|')
# Measured since, 2026-09-24: the first lookup after idle, and a burst of misses.
Assert 'and what the first lookup after idle did' ($s -match '(?s)After idle, and under a burst, measured 2026-09-24[\s\S]{0,700}no always-ready instance \| 3 \| \*\*2\*\*')
Assert 'the burst failures are named U18'       ($s -match 'That is \*\*U18\*\*')
Assert 'and U18 is open in the register'        ((Get-Content (Join-Path $root 'docs/UNKNOWNS.md') -Raw) -match '\| U18 \| OPEN \|')
# U9, narrowed 2026-09-24: 500,000 keys accepted and charged, no allowance exact.
Assert 'the counters at 500,000 keys are recorded' ($s -match 'Counters at 500,000 keys, measured 2026-09-24')
Assert 'and they are said to be soft'           ($s -match 'soft at any scale')
Assert 'and says why it stays flat'         ($s -match 'every identity is its own logical partition')
# Writes are slow and that is a migration-window fact, not a request-path one.
Assert 'the backfill rate is stated'        ($s -match '190 records a second')
Assert 'and what it means for a backfill'   ($s -match 'roughly 45 minutes')

$net = Join-Path $root 'infra/projection-network.bicep'
Assert 'the private networking template exists' (Test-Path $net)
$nb = Get-Content $net -Raw
# A private endpoint without the DNS zone resolves to the public address, which
# then refuses - the failure reads as a firewall problem rather than a DNS one.
Assert 'it creates the private DNS zone'  ($nb -match "privatelink\.documents\.azure\.com")
Assert 'and links the zone to the endpoint' ($nb -match 'privateDnsZoneGroups')
Assert 'the endpoint targets the SQL group' ($nb -match "groupIds:\s*\[\s*'Sql'\s*\]")
# The runner is a test fixture and bills while it exists.
Assert 'the in-VNet runner is optional'   ($nb -match 'param runnerEnabled bool')
Assert 'and never restarts'               ($nb -match "restartPolicy: 'Never'")

$a12 = Join-Path $root 'docs/adr/0012-store-and-availability.md'
Assert 'the tiering decision is recorded' (Test-Path $a12)
$d12 = Get-Content $a12 -Raw
Assert 'it rejects a size-based second tier' ($d12 -match 'no engineering discontinuity at 1,000')
Assert 'and names the real second axis'      ($d12 -match 'single-region only')
Assert 'the two switches are independent'    ($d12 -match '-EntitlementStore' -and $d12 -match '-ProjectionHa')
Assert 'the default stays the cheap one'     ($d12 -match 'default: named-values')
Assert 'and multi-region is labelled as billing at rest' ($d12 -match 'standing cost')

Write-Host ''
Write-Host 'Scale - reachable from the README' -ForegroundColor Cyan

# The operating envelope belongs where someone evaluating the accelerator will
# see it, not three pages into SCALE.md. Without it a reader reasonably assumes
# the 500,000 figure the design discusses is what the thing does today.
$readmeTop = (Get-Content (Join-Path $root 'README.md') -Raw)
Assert 'the README states the current ceiling'   ($readmeTop -match 'How many developers this holds today')
Assert 'and gives the measured number'           ($readmeTop -match 'roughly 93 developers')
Assert 'and says the larger design is not the default yet' ($readmeTop -match 'It is not the default, and it is not yet\s*\r?\n?>?\s*load-tested at 500,000\*\*')
Assert 'and points at how to check your own'     ($readmeTop -match 'Measure-ClaudeCeiling\.ps1')

# Documentation that nothing links to is documentation nobody reads. Six pages
# were unreachable from the README before this check existed, including the
# business unit guide, which is a whole feature area.
#
# Asserted per file, so a new page under docs/ either gets linked or fails the
# run. The list is derived from the directory rather than written out, because
# a hard-coded list stops catching the next one.
$readme = Get-Content (Join-Path $root 'README.md') -Raw
$unlinked = @()
foreach ($doc in Get-ChildItem (Join-Path $root 'docs') -File -Filter *.md) {
    if ($readme -notmatch [regex]::Escape($doc.Name)) { $unlinked += $doc.Name }
}
Assert 'every page under docs/ is linked from the README' ($unlinked.Count -eq 0) ($unlinked -join ', ')

# The ADR directory is linked as a set, not only the individual records that
# happen to be cited in prose.
Assert 'the decision records are linked as a set' ($readme -match '\]\(docs/adr/\)')
Assert 'and the scale guide is in the index'      ($readme -match '\[Scale\]\(docs/SCALE\.md\)')

Write-Host ''
Write-Host 'Scale - the status page tells the truth about P19' -ForegroundColor Cyan

$status = Get-Content (Join-Path $root 'docs/STATUS.md') -Raw

# The failure this guards: a status page that reports a decision as though it
# were a delivery. P19 has an ADR, a costing, a deployed-and-verified template
# and a measured capacity result - and none of that raises the ceiling by one
# developer, because nothing populates the projection and nothing reads it.
Assert 'it says P19 is not finished'            ($status -match '(?i)Not finished')
Assert 'and gives the ceiling that still binds' ($status -match 'about 93 developers')
# Superseded 2026-09-23: population and the resolver now exist and were run
# end to end, so the page must say what is still missing instead.
Assert 'it says the path was run, not just designed' ($status -match 'deployed with no public endpoint')
Assert 'and that it is not the default'         ($status -match 'the projection is not the default')
Assert 'it names what is still missing'         ($status -match '(?s)Still missing before 500,000[\s\S]{0,300}Counters at that cardinality \(U9\)\.\*\* Narrowed, not closed')
Assert 'and reports U14 as measured'            ($status -match "resolver's p99 on a miss \(U14\)\s+is: 301 ms")
Assert 'including Foundry quota'                ($status -match '(?s)Still missing before 500,000[\s\S]{0,700}Foundry quota')
Assert 'and the policy path'                    ($status -match '(?s)not built[\s\S]{0,1000}cache-lookup-value')
# What is genuinely retired should be said too, or the entry reads as no
# progress at all.
Assert 'it records the storage risk as retired' ($status -match '(?i)Storage risk[\s\S]{0,140}Retired')
Assert 'with the measurement behind it'         ($status -match '1 RU flat')
# The open input is a decision, not an engineering task, and it blocks the rest.
Assert 'it names the one open input'            ($status -match '(?i)how long the gateway may keep serving')

Write-Host ''
Write-Host 'Scale - the gateway outlives the instance (ADR-0013)' -ForegroundColor Cyan

$adr13 = Get-Content (Join-Path $root 'docs/adr/0013-gateway-outlives-instance.md') -Raw

# The SKU floor is a networking fact, not a headcount one. A Basic v2 gateway
# cannot join a virtual network, and the projection sits behind a private
# endpoint because the Cosmos account comes back with public access disabled.
Assert 'it records the tier capabilities'       ($adr13 -match 'Virtual network integration')
Assert 'Basic v2 cannot run the design'         ($adr13 -match '(?i)Basic v2 cannot run the design in ADR-0011 at any size')
Assert 'and Standard v2 is named as the floor'  ($adr13 -match '(?i)floor for the projection is\s+\*\*Standard v2|SKU floor for the projection is \*\*Standard v2')
Assert 'Premium v2 multi-region is corrected'   ($adr13 -match '(?i)Premium v2 does not do multi-region')
Assert 'and Premium classic is named instead'   ($adr13 -match '(?i)Only Premium classic does')
Assert 'the in-place path is recorded'          ($adr13 -match '(?i)Basic v2 and Standard v2')
Assert 'and that it does not interrupt traffic' ($adr13 -match 'will not experience gateway')

# The requirement: 200 developers today reaching 200,000 without reconfiguring
# the 200. The hostname is the thing that blocks it.
Assert 'developers get a custom domain'    ($adr13 -match '(?i)custom domain, never the instance hostname')
Assert 'and the reason is the instance name in the URL' ($adr13 -match '(?i)instance name is in the hostname|instance name into the configuration')

# Not modifying the gateway is the constraint, so both paths ship on day one and
# the switch is configuration.
Assert 'both entitlement paths ship together' ($adr13 -match '(?i)carries both entitlement paths')
Assert 'and the switch is a named value'      ($adr13 -match 'entitlement-source')
Assert 'the migration is a flip, not a deploy' ($adr13 -match '(?i)no gateway change, and the rollback')

# Billing continuity is the other half of the requirement.
Assert 'the counter key does not change'  ($adr13 -match '(?i)counter key is the object id, and it does not change')
Assert 'and spend history is located'     ($adr13 -match '(?i)Log Analytics, which survives any tier change')

Assert 'the unknown it leaves is recorded' (
    (Get-Content (Join-Path $root 'docs/UNKNOWNS.md') -Raw) -match '\| U14 \| CLOSED \| What does the projection resolver add to p99 on a cache miss\? Measured 2026-09-23')

$scale = Get-Content (Join-Path $root 'docs/SCALE.md') -Raw
Assert 'the scale guide carries the SKU table'  ($scale -match '(?s)Basic v2[\s\S]{0,200}Premium \(classic\)')
Assert 'and the two first-day decisions'        ($scale -match '(?i)Two things to get right on the first day')
Assert 'and links the decision record'          ($scale -match '0013-gateway-outlives-instance')

Write-Host ''
Write-Host 'Scale - the entitlement source is a switch, not a rewrite (P19a)' -ForegroundColor Cyan

$pol = Get-Content (Join-Path $root 'infra/policy.xml') -Raw

# Both paths ship together so a migration is a named-value change rather than a
# policy deployment against a gateway carrying live traffic - ADR-0013.
Assert 'the policy reads an entitlement source'  ($pol -match '\{\{entitlement-source\}\}')
Assert 'and still has the named-value path'      ($pol -match '\{\{allow-premium\}\}.*Contains\(oid\)|Contains\(oid\)')
Assert 'the list path is guarded, not deleted'   ($pol -match '(?s)when condition="@\(!\(bool\)context\.Variables\["entResolved"\]\)"')
Assert 'the projection path caches the record'   ($pol -match 'cache-store-value key="@\("ent:"')
Assert 'and the window is configurable'          ($pol -match '\{\{entitlement-cache-seconds\}\}')
# The audience and the URL are different things; a token for the URL is rejected.
Assert 'the token audience is its own value'     ($pol -match 'resource="\{\{entitlement-resolver-audience\}\}"')

# ADR-0005: a lookup failure is not a user-not-found. 403 would tell an entitled
# developer they had lost access.
Assert 'a resolver failure answers 503'          ($pol -match '(?s)entitlement service did not answer[\s\S]{0,400}|503')
Assert 'and says it is not the developer'        ($pol -match 'not a problem with your access')
Assert 'a missing resolver is named as such'     ($pol -match 'resolver is deployed\. Set entitlement-resolver-url')
Assert 'and says access has not changed'         ($pol -match 'No developer access has changed')
# send-request's ignore-error does not cover a managed-identity token failure,
# which throws out of the block and would otherwise reach the developer as 500.
Assert 'on-error catches the entitlement phase'  ($pol -match 'context\.Variables\.ContainsKey\("entResolving"\)')

$bicep = Get-Content (Join-Path $root 'infra/main.bicep') -Raw
Assert 'the template creates the switch'         ($bicep -match "key: 'entitlement-source'")
Assert 'and defaults it to the list path'        ($bicep -match "param entitlementSource string = 'named-value'")
Assert 'the switch is constrained'               ($bicep -match "(?s)@allowed\(\[\s*'named-value'\s*'projection'\s*\]\)")

# A redeploy that did not read the source back would return a migrated operator
# to lists that stopped being maintained the moment they migrated.
$inst = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
Assert 'a redeploy preserves the source'         ($inst -match "named-value-id entitlement-source --query value")
Assert 'and hands it back to the template'       ($inst -match 'entitlementSource=\$\(if \(\$entSrc\)')
Assert 'the resolver settings survive too'       ($inst -match 'entitlementResolverUrl=\$\(if \(\$entUrl\)')
Assert 'and it says so when migrated'            ($inst -match 'preserving entitlement source: projection')

Write-Host ''
Write-Host 'Scale - the decisions, and the move itself (P19e)' -ForegroundColor Cyan

$dec = Get-Content (Join-Path $root 'docs/DECISIONS.md') -Raw

# Two of the nine cannot be retrofitted, and both cost nothing on day one. A
# decisions page that buries them among the reversible ones is not doing its job.
Assert 'the decisions page exists'          ($dec.Length -gt 0)
Assert 'it separates what cannot be deferred' ($dec -match '(?i)expensive to defer')
Assert 'the custom domain is one of them'   ($dec -match '(?i)company web address')
Assert 'and the region family the other'    ($dec -match '(?i)survive an Azure region failing')
Assert 'each option says what the default does' ($dec -match '(?i)Default today:')
# Numbers are computed elsewhere; the page must not become a second source.
Assert 'the window costs point at the script'  ($dec -match 'Measure-ClaudeProjectionCost\.ps1')
Assert 'and are labelled as computed'          ($dec -match '(?i)not quoted')
Assert 'the budget entry states the cache gap' ($dec -match '41\.5')
Assert 'and what to say instead'               ($dec -match '(?i)attribute the cost.{0,40}cap it')

$scale2 = Get-Content (Join-Path $root 'docs/SCALE.md') -Raw
Assert 'the move is written as steps'       ($scale2 -match '(?i)The move itself, step by step')
Assert 'every step carries a rollback'      (
    ([regex]::Matches($scale2, '(?m)^\*\*Rollback:\*\*')).Count -ge 5)
Assert 'it checks the tier first'           ($scale2 -match '(?s)step by step[\s\S]{0,2000}Basic v2 cannot join')
Assert 'the comparison gates the flip'      ($scale2 -match '(?i)Run the comparison until it reports nothing')
Assert 'the flip is one named value'        ($scale2 -match 'named-value-id entitlement-source --value projection')
Assert 'and rolling back is the same value' ($scale2 -match '(?i)set it back to .named-value')
Assert 'the lists are kept as the rollback' ($scale2 -match '(?i)Until then they are your rollback')
Assert 'it states what does not change'     ($scale2 -match '(?i)What does not change')
Assert 'including the developer address'    ($scale2 -match '(?i)no developer reconfigures anything')
Assert 'and that allowances do not reset'   ($scale2 -match '(?i)allowances do not reset')

$rm2 = Get-Content (Join-Path $root 'README.md') -Raw
Assert 'the README offers the decisions'    ($rm2 -match '\[Decisions\]\(docs/DECISIONS\.md\)')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Scale contract holds.' -ForegroundColor Green
exit 0
