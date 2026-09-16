# P20c - teams: a unit with a parent, and tier as a separate axis.
#
# RED first: written before the implementation.
#
# ADR-0008 sets the model. A team is a business unit that names a parent, the
# cascade is two levels deep, membership resolves to the most specific unit,
# and tier is attached by nesting the team group inside the tier group.
#
# The defect this exposed is asserted here too: Graph transitiveMembers returns
# nested group objects as well as users, so a group's object id would land in
# the entitlement list and eat the 4,096-character budget that holds about 110
# object ids.
#
# Every assertion reads a file. There is no live section.

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$bicepPath = Join-Path $root 'infra/main.bicep'
$syncPath = Join-Path $root 'scripts/Sync-ClaudeAccess.ps1'
$setPath = Join-Path $root 'scripts/Set-ClaudeBusinessUnit.ps1'
$getPath = Join-Path $root 'scripts/Get-ClaudeBusinessUnit.ps1'
$helper = Join-Path $root 'scripts/ClaudeBusinessUnit.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Teams - the parent map' -ForegroundColor Cyan

. $helper
Assert 'a parent map can be read' ([bool](Get-Command ConvertFrom-ClaudeBuParents -ErrorAction SilentlyContinue))
Assert 'a parent map can be written' ([bool](Get-Command ConvertTo-ClaudeBuParents -ErrorAction SilentlyContinue))

if (Get-Command ConvertFrom-ClaudeBuParents -ErrorAction SilentlyContinue) {
    $p = ConvertFrom-ClaudeBuParents ',ites-1=mcaps,ites-2=mcaps,'
    Assert 'it reads two teams'        (@($p.Keys).Count -eq 2) "got $(@($p.Keys).Count)"
    Assert 'a team names its parent'   ($p['ites-1'] -eq 'mcaps') "got '$($p['ites-1'])'"
    Assert 'an empty map reads as nothing' (@((ConvertFrom-ClaudeBuParents ',,').Keys).Count -eq 0)

    $round = ConvertTo-ClaudeBuParents (ConvertFrom-ClaudeBuParents ',ites-1=mcaps,')
    Assert 'a parent map round-trips'  ($round -eq ',ites-1=mcaps,') "got '$round'"
    Assert 'it keeps sentinel commas'  ($round.StartsWith(',') -and $round.EndsWith(','))
}

if (Get-Command Resolve-ClaudeBuDepth -ErrorAction SilentlyContinue) {
    $parents = ConvertFrom-ClaudeBuParents ',ites-1=mcaps,ites-2=mcaps,'
    Assert 'a business unit is depth 0' ((Resolve-ClaudeBuDepth -Id 'mcaps'  -Parents $parents) -eq 0)
    Assert 'a team is depth 1'          ((Resolve-ClaudeBuDepth -Id 'ites-1' -Parents $parents) -eq 1)
}
else { Assert 'depth can be resolved' $false 'Resolve-ClaudeBuDepth missing' }

# Two levels, not three. A chain deeper than the policy can express must be
# refused when it is written, not discovered when a budget silently stops
# cascading.
if (Get-Command Test-ClaudeBuDepth -ErrorAction SilentlyContinue) {
    $deep = ConvertFrom-ClaudeBuParents ',squad=ites-1,ites-1=mcaps,'
    $threw = $false
    try { Test-ClaudeBuDepth -Parents $deep } catch { $threw = $true }
    Assert 'a three-level chain is refused' $threw

    $ok = $true
    try { Test-ClaudeBuDepth -Parents (ConvertFrom-ClaudeBuParents ',ites-1=mcaps,') } catch { $ok = $false }
    Assert 'a two-level chain is accepted' $ok

    # A cycle would make the cascade non-terminating.
    $cycle = ConvertFrom-ClaudeBuParents ',a=b,b=a,'
    $threwCycle = $false
    try { Test-ClaudeBuDepth -Parents $cycle } catch { $threwCycle = $true }
    Assert 'a cycle is refused' $threwCycle
}
else { Assert 'depth is bounded when written' $false 'Test-ClaudeBuDepth missing' }

Write-Host ''
Write-Host 'Teams - membership resolves to the most specific unit' -ForegroundColor Cyan

$sync = Get-Content $syncPath -Raw

# Measured 2026-09-15: transitiveMembers on a group containing a nested group
# returned 7 objects, 2 of them #microsoft.graph.group. The typed cast excludes
# them. Filtering client-side on @odata.type does not work, because Graph omits
# that property under a cast.
#
# The read moved to scripts/ClaudeGraphMembership.ps1 so that the sync and
# Compare-ClaudeEntitlement.ps1 cannot drift apart, so it is asserted there.
$graph = Get-Content (Join-Path $root 'scripts/ClaudeGraphMembership.ps1') -Raw
Assert 'membership is read through a typed cast' ($graph -match 'transitiveMembers/\$\(\$cast\.Type\)')
Assert 'and a group object cannot be entitled' ($graph -notmatch 'transitiveMembers\?')

# A developer in claude-team-ites-1 is transitively in claude-bu-mcaps too, so
# order decides which unit they are charged to. Asserted against real data
# rather than against the comment that explains it - matching the prose passed
# while the ordering had been replaced with a constant.
if (Get-Command Sort-ClaudeBuByDepth -ErrorAction SilentlyContinue) {
    $p = ConvertFrom-ClaudeBuParents ',ites-1=mcaps,ites-2=mcaps,'
    $units = @(
        [pscustomobject]@{ Id = 'mcaps';  Group = 'g1'; TokensPerMonth = 1 }
        [pscustomobject]@{ Id = 'ites-1'; Group = 'g2'; TokensPerMonth = 1 }
        [pscustomobject]@{ Id = 'gbb';    Group = 'g3'; TokensPerMonth = 1 }
        [pscustomobject]@{ Id = 'ites-2'; Group = 'g4'; TokensPerMonth = 1 }
    )
    $sorted = @(Sort-ClaudeBuByDepth $units -Parents $p)
    Assert 'teams come before their parents' (($sorted[0].Id -in 'ites-1','ites-2') -and ($sorted[1].Id -in 'ites-1','ites-2')) "got $(($sorted.Id) -join ', ')"
    Assert 'and business units follow'       (($sorted[2].Id -in 'mcaps','gbb') -and ($sorted[3].Id -in 'mcaps','gbb')) "got $(($sorted.Id) -join ', ')"
    # Stable, so ADR-0007's registry-order precedence still decides between
    # two units at the same depth.
    Assert 'order is stable within a depth'  ($sorted[0].Id -eq 'ites-1' -and $sorted[2].Id -eq 'mcaps') "got $(($sorted.Id) -join ', ')"
    Assert 'the sync uses it'                ($sync -match 'Sort-ClaudeBuByDepth')
}
else { Assert 'units can be ordered by depth' $false 'Sort-ClaudeBuByDepth missing' }

Write-Host ''
Write-Host 'Teams - the cascade' -ForegroundColor Cyan

$policy = Get-Content $policyPath -Raw
$bicep = Get-Content $bicepPath -Raw

Assert 'the template takes a parent map'   ($bicep -match 'buParents')
Assert 'it becomes a named value'          ($bicep -match "key: 'bu-parents'")
Assert 'a redeploy preserves it'           ($bicep -match 'buParentsExisting')

Assert 'the policy resolves a parent'      ($policy -match '\{\{bu-parents\}\}')
Assert 'the parent lookup is anchored'     ($policy -match 'var marker = "," \+ (bu|unit)')

# Two limits keyed on different units, so a team and its parent are separate
# counters rather than one shared total.
$limits = [regex]::Matches($policy, '<llm-token-limit(?:(?!/>).)*?/>', 'Singleline')
$buLimits = @($limits | Where-Object { $_.Value -match 'counter-key="@\("bu-"' })
Assert 'there are two business-unit counters' ($buLimits.Count -eq 2) "got $($buLimits.Count)"
Assert 'one is keyed on the unit'          ([bool]($buLimits | Where-Object { $_.Value -match 'businessUnit' }))
Assert 'one is keyed on the parent'        ([bool]($buLimits | Where-Object { $_.Value -match 'parentUnit' }))
Assert 'both are monthly'                  (@($buLimits | Where-Object { $_.Value -match 'token-quota-period="Monthly"' }).Count -eq 2)
Assert 'they report separate headers'      ($policy -match 'x-bu-parent-quota-remaining')

# An unparented unit must not be charged twice, and an unpriced parent must not
# wall off the unit beneath it.
Assert 'no parent means no second charge'  ($policy -match 'parentUnit"\]\s*!=\s*""|parentUnit"\] != ""')
Assert 'an unpriced parent is skipped'     ($policy -match 'parentQuota"\] != "0"')

# The refusal has to say which level ran out, or a team lead cannot tell whether
# to ask for their own budget or the unit's.
$i = $policy.IndexOf('which == "business unit"')
$branch = if ($i -ge 0) { $policy.Substring($i, [Math]::Min(700, $policy.Length - $i)) } else { '' }
Assert 'the refusal names the level that ran out' ($branch -match 'budgetUnit')

Write-Host ''
Write-Host 'Teams - the admin surface' -ForegroundColor Cyan

$w = Get-Content $setPath -Raw
$r = Get-Content $getPath -Raw

Assert 'a unit can be given a parent'   ($w -match '\$Parent')
Assert 'the parent map is written'      ($w -match 'bu-parents')
Assert 'the writer bounds the depth'    ($w -match 'Test-ClaudeBuDepth')
Assert 'the reader shows the hierarchy' ($r -match '(?i)parent|hierarchy|team')

Write-Host ''
Write-Host 'Teams - documentation' -ForegroundColor Cyan

$docPath = Join-Path $root 'docs/BUSINESS-UNITS.md'
$d = Get-Content $docPath -Raw
Assert 'the guide explains teams'        ($d -match '(?i)\bteam\b')
Assert 'it explains the tier axis'       ($d -match '(?i)tier')
Assert 'it shows nesting'                ($d -match '(?i)nest')
Assert 'it states the two-level cap'     ($d -match '(?i)two level|two-level|depth')
Assert 'the decision is recorded'        (Test-Path (Join-Path $root 'docs/adr/0008-teams-and-tiers.md'))

# The portal captures show the model better than prose does: direct members are
# the teams, all members resolves to the people.
foreach ($shot in 'entra-1-bu-direct-members.png', 'entra-2-bu-all-members.png',
                  'entra-3-team-memberships.png', 'entra-4-bu-direct-person.png',
                  'entra-5-team-ites-1-members.png', 'entra-6-team-ites-2-members.png',
                  'entra-7-tier-standard-members.png', 'entra-8-tier-premium-members.png',
                  'entra-9-user-groups.png') {
    Assert "the guide ships $shot" (Test-Path (Join-Path $root "docs/guide/$shot"))
    Assert "and references it"     ($d -match [regex]::Escape($shot))
}

# Every capture must have a redaction job, so a new screenshot cannot be dropped
# into docs with a real name still on it. The guard inside redact-entra.mjs
# enforces that at render time; this asserts each shipped file went through it.
$redact = Get-Content (Join-Path $root 'guide/redact-entra.mjs') -Raw
foreach ($shot in 'entra-5-team-ites-1-members.png', 'entra-6-team-ites-2-members.png',
                  'entra-7-tier-standard-members.png', 'entra-8-tier-premium-members.png',
                  'entra-9-user-groups.png') {
    Assert "$shot has a redaction job" ($redact -match "out: '$([regex]::Escape($shot))'")
}

# The tier captures are the two-axis model seen from the entitlement side, and
# the premium one is the only place a workload identity appears. Assert the
# guide actually explains that rather than just embedding the picture.
Assert 'the guide covers the tier membership view' ($d -match 'claude-code-standard` *\r?\n?holds|holds two teams and three people')
Assert 'it explains the service principal row'     ($d -match 'workload identity, not a person')
Assert 'and says where its spend lands'            ($d -match '(?i)`unassigned`')

# Entitlement is not live. A tier change is two edits in Entra and takes effect
# only when the sync next runs, and this accelerator ships the sync as a script
# to schedule rather than running it. Saying otherwise sends an admin looking
# for a fault after a change that simply has not been applied yet.
Assert 'the guide says a tier change needs the sync' `
    ($d -match 'takes effect when `Sync-ClaudeAccess\.ps1` next runs')
Assert 'and that the sync is not automatic' `
    ($d -match 'sync is not automatic')

# A tier group can hold a workload identity as well as people. Getting that
# wrong is silent: Graph returns 200 and an empty collection rather than an
# error, so the sync writes an entitlement list with the service principal
# missing and the gateway 403s an identity the portal shows as a member.
#
# These assert the call form, not the words. The comment above the call names
# the cast and the header several times while explaining the measurement, so
# matching on those strings would pass with the code deleted.
$sync = Get-Content (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') -Raw
$graphRead = Get-Content (Join-Path $root 'scripts/ClaudeGraphMembership.ps1') -Raw
Assert 'the read asks for service principals' `
    ($graphRead -match [regex]::Escape("Type = 'microsoft.graph.servicePrincipal'"))
Assert 'it still asks for users' `
    ($graphRead -match [regex]::Escape("Type = 'microsoft.graph.user'"))
Assert 'it sends ConsistencyLevel eventual' `
    ($graphRead -match [regex]::Escape("`$headers['ConsistencyLevel'] = 'eventual'"))
Assert 'and counts, which that header requires' `
    ($graphRead -match [regex]::Escape('&`$count=true"'))
Assert 'and the sync uses that read rather than its own' `
    ($sync -match "ClaudeGraphMembership\.ps1'\)" -and $sync -notmatch 'function Get-GroupMemberOids')


# git-ignored, so an unredacted identity cannot reach a commit by being one
# `git add` away - only the redacted output ships.
$capture = Get-Content (Join-Path $root 'guide/capture-entra.mjs') -Raw
Assert 'the capture writes to the ignored folder' ($capture -match "resolve\('\.shots-entra'\)")
Assert 'and not straight into docs'               ($capture -notmatch "OUT = path\.resolve\('docs/guide'\)")

$ignore = Get-Content (Join-Path $root '.gitignore') -Raw
Assert 'the raw captures are git-ignored' ($ignore -match '(?m)^\.shots-entra/')

# The redaction masks rather than covers: a black box over a name is a picture
# nobody can learn the model from.
$redact = Get-Content (Join-Path $root 'guide/redact-entra.mjs') -Raw
# Identities are masked in the middle rather than replaced, so the screenshots
# stay visibly real: a guide whose evidence is all placeholders asks the reader
# to take it on trust. The mask has to be present and the domain has to survive.
#
# The mask is written \u2022 in the source rather than as a literal bullet, so
# the file stays ASCII; the assertion matches that escape, not the character.
Assert 'identities are masked'             ($redact -match '\\u2022')
Assert 'the real domain survives the mask' ($redact -match '@microsoft\.com')
Assert 'and the tenant is not hidden'      ($redact -match 'MICROSOFT NON-PRODUCTION')
# A mask that leaves the local part readable is not a mask.
foreach ($plain in 'naveen\.g@', 'nived\.v@', 'Saurabh\.Seth@', 'vrm@microsoft', 'navg@microsoft', 'sombanerjee@', 'abpatra@', 'rajatsr@') {
    Assert "it does not restate $($plain -replace '\\','')" ($redact -notmatch $plain)
}
# Display names must be masked too, not just addresses.
foreach ($plain in 'Gopalakrishna', 'Velayudhan', 'Mudumbai', 'Banerjee', 'Somnath', 'Abhishek', 'Srivastava') {
    Assert "'$plain' is not left whole" ($redact -notmatch $plain)
}
# A capture with no redaction job is the file that gets copied into docs by
# hand with a real name still on it, so it has to fail rather than be skipped.
# The condition itself is asserted, not the word: matching "unhandled" passed
# while the branch had been changed to if (false) and the exit was dead code.
Assert 'an unredacted capture fails the run' ($redact -match 'if \(unhandled\.length\)[\s\S]{0,800}process\.exit\(1\)')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Team contract holds.' -ForegroundColor Green
exit 0
