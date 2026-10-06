# P20-P22 - business units: registry, membership, and the soft cap.
#
# RED first: written before the implementation.
#
# ADR-0007 sets the model. A business unit is an Entra group registered with a
# budget, the registry key is the stable identifier rather than the display
# name, and a developer in no business unit is "unassigned" - allowed by
# default, because a default of deny would refuse every request on the
# deployment that installs this.
#
# The budget is stored in dollars and enforced in tokens, with a measured error:
# output is 5x base input, a cache read is 0.1x, and llm-token-limit "currently
# counts prompt and completion tokens only", which leaves 38.7% of real cost
# weight outside the counter on thirty days of live usage. That gap is asserted
# to be stated, not hidden.
#
# Every assertion here reads a file. There is no live section, so there is no
# -SkipLive: the checks run the same whether or not Azure is reachable.

$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra/policy.xml'
$bicepPath = Join-Path $root 'infra/main.bicep'
$setPath = Join-Path $root 'scripts/Set-ClaudeBusinessUnit.ps1'
$getPath = Join-Path $root 'scripts/Get-ClaudeBusinessUnit.ps1'
$helper = Join-Path $root 'scripts/ClaudeBusinessUnit.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$policy = if (Test-Path $policyPath) { Get-Content $policyPath -Raw } else { '' }
$bicep = if (Test-Path $bicepPath) { Get-Content $bicepPath -Raw } else { '' }

Write-Host ''
Write-Host 'Business units - the registry' -ForegroundColor Cyan

Assert 'a parsing helper exists' (Test-Path $helper) $helper
if (Test-Path $helper) {
    . $helper
    Assert 'it can read a registry'  ([bool](Get-Command ConvertFrom-ClaudeBuRegistry -ErrorAction SilentlyContinue))
    Assert 'it can write a registry' ([bool](Get-Command ConvertTo-ClaudeBuRegistry -ErrorAction SilentlyContinue))

    if (Get-Command ConvertFrom-ClaudeBuRegistry -ErrorAction SilentlyContinue) {
        $parsed = ConvertFrom-ClaudeBuRegistry ',finance=Claude BU Finance:5000000,platform=Claude BU Platform:20000000,'
        Assert 'it reads two business units' (@($parsed).Count -eq 2) "got $(@($parsed).Count)"
        $fin = @($parsed | Where-Object { $_.Id -eq 'finance' })
        Assert 'the key is the identifier'   ($fin.Count -eq 1)
        Assert 'the group is kept apart from it' ($fin.Count -eq 1 -and $fin[0].Group -eq 'Claude BU Finance') "got '$($fin[0].Group)'"
        Assert 'the budget is a number'      ($fin.Count -eq 1 -and [long]$fin[0].TokensPerMonth -eq 5000000)

        # Empty is the shipped default and must not blow up.
        Assert 'an empty registry reads as nothing' (@(ConvertFrom-ClaudeBuRegistry ',,').Count -eq 0)

        # A display name may itself contain a colon, which is why the split is
        # on the last one. Splitting on the first would put ": EMEA" into the
        # budget and throw, or worse, parse to something wrong.
        $colon = @(ConvertFrom-ClaudeBuRegistry ',emea=Claude: EMEA engineering:7000000,')
        Assert 'a colon in the group name survives' ($colon.Count -eq 1 -and $colon[0].Group -eq 'Claude: EMEA engineering') "got '$($colon[0].Group)'"
        Assert 'and its budget still parses'        ($colon.Count -eq 1 -and [long]$colon[0].TokensPerMonth -eq 7000000) "got '$($colon[0].TokensPerMonth)'"

        # Round trip, because the writer is what an admin command produces.
        $round = ConvertTo-ClaudeBuRegistry (ConvertFrom-ClaudeBuRegistry ',finance=Claude BU Finance:5000000,')
        Assert 'a registry round-trips'      ($round -eq ',finance=Claude BU Finance:5000000,') "got '$round'"
        Assert 'it keeps sentinel commas'    ($round.StartsWith(',') -and $round.EndsWith(','))
    }

    if (Get-Command Test-ClaudeBuId -ErrorAction SilentlyContinue) {
        # The identifier lands in a counter key and a comma-delimited map, so it
        # cannot contain a comma, an equals or a colon.
        foreach ($bad in 'has space', 'has,comma', 'has=equals', 'has:colon', '') {
            $threw = $false
            try { Test-ClaudeBuId $bad } catch { $threw = $true }
            Assert "'$bad' is refused as an identifier" $threw
        }
        $ok = $true
        try { Test-ClaudeBuId 'finance-emea' } catch { $ok = $false }
        Assert "'finance-emea' is accepted" $ok

        # P96: the dollar budget uses the identifier as its scope and accepts only lower-case
        # (scripts/ClaudeUsdBudgets.ps1:42), so a new identifier with a capital is refused here, with the
        # rule. Before P96 this check ignored case, so a registry can hold an identifier with capitals; an
        # identifier the registry holds with that exact spelling stays usable, and the registry with it can still be written.
        $caseRefusal = ''
        try { Test-ClaudeBuId 'Platform' } catch { $caseRefusal = $_.Exception.Message }
        Assert "a new identifier with a capital, 'Platform', is refused with the lower-case rule" ($caseRefusal -match 'lower-case letters') $caseRefusal
        $respelt = ''
        try { Test-ClaudeBuId 'Sales' -Registry @('sales', 'platform') } catch { $respelt = $_.Exception.Message }
        Assert "'Sales' is refused when the registry holds 'sales', rather than taken as that unit" ($respelt -match 'lower-case letters') $respelt
        $inverse = ''
        try { Test-ClaudeBuId 'legacy-unit' -Registry @('finance', 'Legacy-Unit') } catch { $inverse = $_.Exception.Message }
        Assert "'legacy-unit' is refused when the registry holds 'Legacy-Unit', naming the stored spelling" ($inverse -match 'differs only in case' -and $inverse.Contains("'Legacy-Unit'")) $inverse
        # Council round 2 (Security): -ccontains compares by culture, so U+212A KELVIN SIGN equals 'K'. An identifier is
        # known only when the registry holds the same characters.
        $lookalike = ''
        try { Test-ClaudeBuId "$([char]0x212A)ey" -Registry @('platform', 'Key') } catch { $lookalike = $_.Exception.Message }
        Assert 'a look-alike of a stored identifier is not known, and is refused' ($lookalike -match 'not a valid business unit identifier') $lookalike
        $legacy = 'not run'
        try { Test-ClaudeBuId 'Legacy-Unit' -Registry @('finance', 'Legacy-Unit'); $legacy = '' } catch { $legacy = $_.Exception.Message }
        Assert 'an identifier the registry holds with capitals stays usable' (-not $legacy) $legacy
        $unsafe = ''
        try { Test-ClaudeBuId 'Has Space' -Registry @('Has Space') } catch { $unsafe = $_.Exception.Message }
        Assert 'a stored identifier is still refused when it could break the map' ($unsafe -match 'not a valid business unit identifier') $unsafe
        $written = ''
        try { $written = ConvertTo-ClaudeBuRegistry @([pscustomobject]@{ Id = 'Legacy-Unit'; Group = 'Claude BU Legacy'; TokensPerMonth = 5 }) } catch { $written = "threw: $($_.Exception.Message)" }
        Assert 'a registry that holds a stored identifier with capitals is still written' ($written -eq ',Legacy-Unit=Claude BU Legacy:5,') $written

        # The interactive manager checks a new identifier at its prompt with the writer's rule, before it offers
        # to create the Entra group (scripts/Manage-ClaudeBusinessUnits.ps1, Add-Unit).
        $manageAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Manage-ClaudeBusinessUnits.ps1'), [ref]$null, [ref]$null)
        $confirmAst = $manageAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Confirm-Identifier' }, $true)
        if ($confirmAst) {
            . ([scriptblock]::Create($confirmAst.Extent.Text))
            Assert "the manager's prompt refuses a new identifier with a capital, 'Platform'" (-not (Confirm-Identifier 'Platform' 6>$null))
            Assert "the manager's prompt accepts 'finance-emea'" ([bool](Confirm-Identifier 'finance-emea' 6>$null))
            $shown = (Confirm-Identifier 'Platform' 6>&1 | ForEach-Object { "$_" }) -join ' '
            Assert "the manager's prompt shows the writer's message" ($shown.Contains("'Platform' is not a valid business unit identifier") -and $shown.Contains('starting with a letter or digit')) $shown

            # Council round 2 (UX): Add-Unit reads the registry and checks the identifier against it before it looks up
            # or offers to create the Entra group; a registry it cannot read stops it the same way.
            $addAst = $manageAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-Unit' }, $true)
            $readAst = $manageAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-Value' }, $true)
            $runAdd = {
                param([string]$Answer, [scriptblock]$ReadRegistry)
                $calls = [System.Collections.Generic.List[string]]::new()
                & {
                    . ([scriptblock]::Create($readAst.Extent.Text))
                    . ([scriptblock]::Create($addAst.Extent.Text))
                    function Read-Host { $Answer }
                    function az { $calls.Add("az $($args -join ' ')"); $global:LASTEXITCODE = 0 }
                    function Get-ApimNamedValue { param($ResourceGroup, $ApimName, $Id, [switch]$FailOnError) $calls.Add("read $Id"); & $ReadRegistry }
                    function Invoke-Child { param($Script, $Arguments) $calls.Add("child $Script") }
                    function Complete-Change { }
                    $ResourceGroup = 'rg-test'; $ApimName = 'apim-test'
                    Add-Unit 6>$null | Out-Null
                }
                return , $calls.ToArray()
            }
            if ($addAst -and $readAst) {
                $legacy = { ',sales=Sales:1000,Legacy-Unit=Legacy:3000,' }
                $alias = & $runAdd 'legacy-unit' $legacy
                Assert "the manager refuses another spelling of a stored unit before the Entra group step" (($alias -join ' | ') -ceq 'read bu-registry') ($alias -join ' | ')
                $unread = & $runAdd 'research' { throw 'ERROR: (AuthorizationFailed) cannot read' }
                Assert "the manager stops before the Entra group step when it cannot read the registry" (($unread -join ' | ') -ceq 'read bu-registry') ($unread -join ' | ')
                # Council round 3 (UX): Get-ApimNamedValue -FailOnError returns $null for a named value that does not exist.
                $absent = & $runAdd 'research' { $null }
                Assert "the manager stops before the Entra group step when the gateway has no bu-registry" (($absent -join ' | ') -ceq 'read bu-registry') ($absent -join ' | ')
                # Council round 4 (UX note): the stop names the command that updates this gateway.
                $absentText = & {
                    . ([scriptblock]::Create($readAst.Extent.Text))
                    . ([scriptblock]::Create($addAst.Extent.Text))
                    function Read-Host { 'research' }
                    function az { $global:LASTEXITCODE = 0 }
                    function Get-ApimNamedValue { param($ResourceGroup, $ApimName, $Id, [switch]$FailOnError) $null }
                    function Invoke-Child { }
                    function Complete-Change { }
                    $ResourceGroup = 'rg-test'; $ApimName = 'apim-test'
                    Add-Unit 6>&1 | Out-String
                }
                Assert "the manager's missing-registry stop names the update command for this gateway" ($absentText -match 'Update-ClaudeGateway\.ps1 -RecordPath \S+ -ResourceGroup rg-test -ApimName apim-test') $absentText
                $fresh = & $runAdd 'research' $legacy
                Assert "the manager reaches the Entra group step for a new lower-case identifier" ($fresh.Count -ge 2 -and $fresh[0] -ceq 'read bu-registry' -and $fresh[1] -like 'az ad group show*') ($fresh -join ' | ')
            }
            else { Assert "the manager's Add-Unit can be read" $false 'Add-Unit or Read-Value missing from scripts/Manage-ClaudeBusinessUnits.ps1' }
        }
        else { Assert "the manager's prompt checks the identifier" $false 'Confirm-Identifier missing from scripts/Manage-ClaudeBusinessUnits.ps1' }
    }
    else { Assert 'it validates an identifier' $false 'Test-ClaudeBuId missing' }
}

Write-Host ''
Write-Host 'Business units - the admin surface' -ForegroundColor Cyan

Assert 'a writer exists' (Test-Path $setPath) $setPath
Assert 'a reader exists' (Test-Path $getPath) $getPath

if (Test-Path $setPath) {
    $w = Get-Content $setPath -Raw
    Assert 'it adds a business unit'      ($w -match '\$Group')
    Assert 'it takes a dollar budget'     ($w -match '\$MonthlyBudgetUsd')
    # Editing means changing the group an existing unit points at, or its
    # budget, without touching the identifier. ADR-0007 keeps the id stable on
    # purpose, so there is no separate rename parameter to look for.
    Assert 'it can repoint an existing unit' ($w -match 'if \(\$Group\) \{ \$Group \}' -or $w -match '\$targetGroup')
    Assert 'it can change a budget alone'    ($w -match "PSBoundParameters.ContainsKey\('MonthlyBudgetUsd'\)")
    Assert 'it can remove one'            ($w -match '\$Remove')
    Assert 'it writes through the guard'  ($w -match 'Set-ApimNamedValue')
    # The same failure that emptied the entitlement allow list.
    Assert 'it reads before it writes'    ($w.IndexOf('Get-ApimNamedValue') -ge 0 -or $w -match 'ConvertFrom-ClaudeBuRegistry')
    Assert 'it refuses to drop another unit' ($w -match '(?i)Refusing to write|would be lost')
}
if (Test-Path $getPath) {
    $r = Get-Content $getPath -Raw
    Assert 'the reader lists business units' ($r -match 'ConvertFrom-ClaudeBuRegistry')
    Assert 'it reports members'              ($r -match '(?i)member')
    Assert 'it reports the unassigned'       ($r -match '(?i)unassigned')
    Assert 'it can emit JSON'                ($r -match '\$AsJson')
    # A dollar figure with no caveat attached is the failure mode here. The
    # caveat has to reach the operator, so both the <# #> help block and #
    # comments are stripped before asserting - a warning in a file header is
    # not a warning.
    #
    # Asserted per surface. A single match over the whole file passed on the
    # JSON field alone while the terminal caveat had been deleted, and most
    # people read the terminal.
    $emitted = [regex]::Replace($r, '(?s)<#.*?#>', '')
    $emitted = ($emitted -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $shown = ($emitted -split "`n" | Where-Object { $_ -match 'Write-Host' }) -join "`n"

    Assert 'the terminal states list price'  ($shown -match '(?i)list price')
    # The caveat changed rather than went away. Cache *read* is now attributed
    # from the gateway metric; the two cache *write* categories are not, and the
    # budget still counts neither. Asserting the old "excludes cached tokens"
    # wording here would now be asserting something untrue.
    Assert 'the terminal still states what cache is missing' ($shown -match '(?i)cache write')
    Assert 'and that the budget counts no cache'             ($shown -match '(?i)budget itself counts neither')
    Assert 'the JSON records list price'     ($emitted -match "(?i)source\s*=\s*'list price'")
    Assert 'the JSON records the remaining cache gap' ($emitted -match '(?i)excludes_cache_write')
    Assert 'and that enforcement is still blind to cache' ($emitted -match '(?i)budget_counts_cache')
}

Write-Host ''
Write-Host 'Business units - enforcement' -ForegroundColor Cyan

Assert 'the template takes a registry'    ($bicep -match 'param\s+buRegistryExisting\s+string')
Assert 'and a membership map'             ($bicep -match 'param\s+buMembersExisting\s+string')
Assert 'and the unassigned behaviour'     ($bicep -match 'param\s+buUnassigned\s+string')
Assert 'they become named values'         ($bicep -match "key:\s*'bu-registry'" -and $bicep -match "key:\s*'bu-members'")
# A redeploy must not wipe them, which is what happened to the allow lists.
Assert 'a redeploy preserves the registry' ($bicep -match 'empty\(buRegistryExisting\)\s*\?')
Assert 'a redeploy preserves membership'   ($bicep -match 'empty\(buMembersExisting\)\s*\?')

# The template being willing to preserve is half the contract. Every existing
# "a redeploy preserves X" check asserted only the Bicep expression, so a
# parameter the installer never passes still looked preserved - and the
# business unit parameters were exactly that. The default is ',,', so a
# redeploy would have emptied the registry, the membership map and the parent
# map, silently unassigning everyone.
$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
foreach ($nv in 'bu-registry', 'bu-members', 'bu-parents') {
    Assert "the installer reads $nv off the gateway" ($installer -match [regex]::Escape("--named-value-id $nv"))
}
foreach ($p in 'buRegistryExisting', 'buMembersExisting', 'buParentsExisting') {
    Assert "and hands $p back" ($installer -match ($p + '='))
}

Assert 'the policy resolves a business unit' ($policy -match '<set-variable name="businessUnit"')
Assert 'it reads the membership map'         ($policy -match '\{\{bu-members\}\}')
Assert 'the lookup is anchored on commas'    ($policy -match '","\s*\+\s*oid|"," \+ oid')
Assert 'an unknown developer is unassigned'  ($policy -match 'unassigned')

$buLimit = [regex]::Match($policy, '<llm-token-limit(?:(?!</?llm-token-limit).)*?businessUnit(?:(?!/>).)*?/>', 'Singleline')
Assert 'a budget is enforced per business unit' $buLimit.Success
Assert 'it is a monthly quota'                  ($buLimit.Success -and $buLimit.Value -match 'token-quota-period="Monthly"')
Assert 'it reports what is left'                ($buLimit.Success -and $buLimit.Value -match 'remaining-quota-tokens-header-name')
# A unit with no budget set should behave like the org ceiling alone, not like a
# wall, so the limit is skipped rather than enforcing zero.
Assert 'an unpriced unit is not refused'        ($policy -match '\$buQuota"\] != "0"|buQuota"\]\s*!=\s*"0"')

# Fourth refusal the gateway can return. It has to name itself or it is
# indistinguishable from the other three.
Assert 'the budget marker names the unit'  ($policy -match '<set-variable name="budget" value="business unit"')
# Scoped to the branch that builds the message. Taking the whole tail of the
# policy from one index made this pass on any occurrence of "businessUnit"
# anywhere below it, including the lookup 200 lines earlier.
#
# It names budgetUnit rather than businessUnit: with teams there are two budgets
# in play, and the message has to say which one ran out. See ADR-0008.
$i = $policy.IndexOf('which == "business unit"')
$branch = if ($i -ge 0) { $policy.Substring($i, [Math]::Min(600, $policy.Length - $i)) } else { '' }
Assert 'the refusal has a business unit branch' ($i -ge 0)
Assert 'the refusal names the budget that ran out' ($branch -match 'context\.Variables[^"]*"budgetUnit"')

# Installing this must not refuse anyone who has no business unit yet.
Assert 'unassigned is allowed by default' ($bicep -match "buUnassigned string = 'allow'")

Write-Host ''
Write-Host 'Business units - money (ADR-0010)' -ForegroundColor Cyan

# Money is decimal. A rate of 0.000002 per token accumulated over millions of
# tokens in binary floating point does not reproduce, and a chargeback figure
# that changes between two runs of the same query cannot be argued with.
#
# Asserted behaviourally as well as on the source, because the type is the
# mechanism and reproducibility is the property that matters.
. $helper

$conv = ConvertTo-ClaudeBuTokens -Usd 5000 -Model 'claude-sonnet-5'
Assert 'a dollar budget converts as decimal'  ($conv.Usd -is [decimal])
Assert 'and the blended rate is decimal'      ($conv.BlendedUsdPerM -is [decimal])

$back = ConvertTo-ClaudeBuUsd -Tokens $conv.TokensPerMonth -Model 'claude-sonnet-5'
Assert 'the conversion round-trips exactly'   ($back -eq [decimal]5000.00) "got $back"
Assert 'and returns decimal, not double'      ($back -is [decimal])

# Rounding once at the end, not per row. 1,389 tokens is $0.0050004, which
# rounds up to a cent on its own; three of them rounded first total $0.03, while
# the same 4,167 tokens priced once is $0.0150012 and rounds to $0.02. One cent
# per three rows compounds across a month of them.
$perRow = @(1..3 | ForEach-Object { ConvertTo-ClaudeBuUsd -Tokens 1389 -Model 'claude-sonnet-5' })
$summedRows = [decimal]0; foreach ($r in $perRow) { $summedRows += $r }
$summedOnce = ConvertTo-ClaudeBuUsd -Tokens 4167 -Model 'claude-sonnet-5'
Assert 'rounding per row overstates the total' ($summedRows -eq [decimal]0.03) "got $summedRows"
Assert 'rounding once gives the exact figure'  ($summedOnce -eq [decimal]0.02) "got $summedOnce"
Assert 'and the two genuinely differ'          ($summedRows -ne $summedOnce)

$h = Get-Content $helper -Raw
Assert 'no money parameter is double' ($h -notmatch '\[double\]\$Usd' -and $h -notmatch '\[double\]\$OutputShare')

# Asserted on the values, not the source. Matching "InputPerM = [decimal]"
# anywhere passed with one model reverted to doubles, and the behavioural tests
# above did not catch it either: PowerShell promotes to decimal when *either*
# operand is decimal, so a double price book still produced decimal output as
# long as OutputShare was decimal. That makes the price book's own type a
# latent problem rather than a visible one - a caller passing a double
# OutputShare would silently lose precision on that model alone.
$badPrices = @()
foreach ($model in $ClaudePriceBook.Keys) {
    $entry = $ClaudePriceBook[$model]
    if ($entry.InputPerM -isnot [decimal])  { $badPrices += "$model.InputPerM" }
    if ($entry.OutputPerM -isnot [decimal]) { $badPrices += "$model.OutputPerM" }
}
Assert 'every price book rate is decimal' ($badPrices.Count -eq 0) ($badPrices -join ', ')
Assert 'and the book is not empty'        ($ClaudePriceBook.Keys.Count -ge 4)

$setSrc = Get-Content $setPath -Raw
Assert 'the writer takes a decimal budget' ($setSrc -match '\[decimal\]\$MonthlyBudgetUsd')

$adr10 = Join-Path $root 'docs/adr/0010-financial-semantics.md'
Assert 'the financial decision is recorded' (Test-Path $adr10)
$f10 = Get-Content $adr10 -Raw

# The eight questions it exists to settle. Each is asserted on a sentence that
# occurs once, not on the topic word, which appears throughout.
Assert 'it settles tariff versus actual cost'   ($f10 -match 'They are\s+\*\*showback\*\*')
Assert 'it refuses to sum token categories'     ($f10 -match 'never summed before pricing')
Assert 'it prices the deployment, not the alias' ($f10 -match 'Pricing joins on `DeploymentName`')
Assert 'it forbids floating point for money'    ($f10 -match 'Never `float` or `double`')
Assert 'it rounds once, at the end'             ($f10 -match 'Round half away from zero')
Assert 'the price book is time-versioned'       ($f10 -match 'in force at the request''s timestamp')
Assert 'periods are UTC'                        ($f10 -match '(?m)^Periods are UTC')
Assert 'corrections are new rows'               ($f10 -match 'A correction is a new row')
Assert 'soft cap is not warn-only'              ($f10 -match 'Ours \*\*does\*\* block')
Assert 'and enforcement is stated as uncategorised' ($f10 -match 'Reporting is categorised; enforcement is not')

Write-Host ''
Write-Host 'Business units - cache in chargeback' -ForegroundColor Cyan

# Cache is 38.7% of real cost weight on measured usage, and it is uneven: a team
# reusing a large cached prompt is under-charged against one that does not. A
# chargeback figure that omits it is not just low, it is unfair in a way that
# makes it arguable - which is the one thing chargeback cannot afford to be.
#
# The per-request log genuinely lacks the columns; that was measured. But the
# gateway's own llm-emit-token-metric emits "Prompt Cached Tokens" carrying
# UserId, which is exactly what the business-unit map keys on. Measured
# 2026-09-17 on the reference workspace: AppMetrics holds 6,833,717 cached
# tokens for UserId 43cc5304, so the join is available.
$getSrc = Get-Content $getPath -Raw
Assert 'the report reads the cached-token metric' ($getSrc -match 'Name == "Prompt Cached Tokens"')
Assert 'and keys it on the object id'              ($getSrc -match 'cache_read = sum\(Sum\) by user_id = tostring\(Properties\.UserId\)')
# The field assignment, not the word. "cache_read" also appears in
# cache_read_usd_estimate and cache_read_known, so matching it anywhere passed
# with the field renamed away.
Assert 'cache is a field of its own, beside tokens_used' ($getSrc -match 'tokens_cache_read = \$cacheRead')
Assert 'and is priced at the cache rate, not the blend' ($getSrc -match 'ConvertTo-ClaudeCacheUsd -Tokens \$cacheRead')

# Cache write stays unattributed - it exists only in the response body, and
# reading that in outbound ends streaming. The report has to say so rather than
# imply cache is now fully counted. Asserted on the key and its value, because
# the phrase "cache write" also appears in the comment explaining it.
Assert 'the JSON names cache read as known'     ($getSrc -match 'cache_read_known\s*=\s*\$true')
Assert 'and cache write as still excluded'      ($getSrc -match 'excludes_cache_write\s*=\s*\$true')
Assert 'and the budget as blind to both'        ($getSrc -match 'budget_counts_cache\s*=\s*\$false')

Write-Host ''
Write-Host 'Business units - documentation' -ForegroundColor Cyan

$docPath = Join-Path $root 'docs/BUSINESS-UNITS.md'
Assert 'there is a guide' (Test-Path $docPath) $docPath
if (Test-Path $docPath) {
    $d = Get-Content $docPath -Raw
    foreach ($task in 'Add', 'budget', 'Rename', 'Remove') {
        Assert "the guide covers $task" ($d -match "(?i)$task")
    }
    Assert 'it shows the commands'   ($d -match 'Set-ClaudeBusinessUnit')
    Assert 'it explains unassigned'  ($d -match '(?i)unassigned')
    # Both halves, not either: '38\.7|cache' is an alternation, and the word
    # "cache" alone passed it while the measured figure was wrong.
    Assert 'it states the measured cache gap' ($d -match '38\.7')
    Assert 'and what it is a gap in'          ($d -match '(?i)cach')
    Assert 'it states the figure is list price' ($d -match '(?i)list price')
    Assert 'it carries screenshots'  ($d -match '!\[')
}

$adr = Join-Path $root 'docs/adr/0007-business-unit-model.md'
Assert 'the decision is recorded' (Test-Path $adr)

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Business unit contract holds.' -ForegroundColor Green
exit 0
