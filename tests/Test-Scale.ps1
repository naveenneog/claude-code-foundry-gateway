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
Assert 'it states what has not been measured' ($s -match '111 requests across 2 days')
Assert 'and refuses to extrapolate from it'   ($s -match 'no evidence behind it')

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
Assert '500k developers cost tens of dollars, not thousands' ($big.monthly_usd.total -lt 50 -and $big.monthly_usd.total -gt 0) "got $($big.monthly_usd.total)"
Assert 'and the projection is under a gigabyte'    ($big.derived.storage_gb -lt 1) "got $($big.derived.storage_gb)"

# The private endpoint is the only line that bills at rest, and it was found by
# deploying rather than by reading a pricing page: the reference subscription
# enforces publicNetworkAccess Disabled above the resource group. An accelerator
# for large enterprises has to assume that baseline, so it defaults on.
Assert 'private networking is priced in'  ($big.monthly_usd.private_endpoint -gt 0)
Assert 'and defaults to on'               ((Get-Content $cost -Raw) -match '\[bool\]\$PrivateNetworking = \$true')
$open = & $cost -Developers 500000 -DailyActive 50000 -PrivateNetworking:$false -AsJson | ConvertFrom-Json
Assert 'turning it off removes exactly that line' `
    ([math]::Round($big.monthly_usd.total - $open.monthly_usd.total, 2) -eq $big.monthly_usd.private_endpoint)

# Cost follows cache misses, not requests. If that ever inverts, the model is
# measuring the wrong thing and every figure built on it is wrong.
$short = & $cost -Developers 500000 -DailyActive 50000 -CacheMinutes 15 -AsJson | ConvertFrom-Json
Assert 'a shorter cache window costs more' ($short.monthly_usd.total -gt $big.monthly_usd.total)
Assert 'and it scales with the window, four to one' `
    ([math]::Abs(($short.derived.misses_per_month / $big.derived.misses_per_month) - 4) -lt 0.01)

# A pilot must cost nothing measurable, or the pay-per-use claim is not true.
$small = & $cost -Developers 8 -DailyActive 8 -AsJson | ConvertFrom-Json
Assert 'a small pilot pays only the endpoint' ($small.monthly_usd.total -eq $small.monthly_usd.private_endpoint) "got $($small.monthly_usd.total)"

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
Assert 'and says the larger design is not built' ($readmeTop -match 'is not built\*\*')
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
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Scale contract holds.' -ForegroundColor Green
exit 0
