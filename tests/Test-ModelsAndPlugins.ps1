# Ease of management: the two things an admin does after the gateway is running.
#
#   a new model appears      four things have to agree - deployed, allowed,
#                            priced, selectable - and the third fails quietly.
#                            A model with no price is served and reported at
#                            zero, which reads as nobody using it
#
#   plugins and marketplaces Claude Code and Claude Desktop use different key
#                            names for the same idea, so a profile that sets
#                            one and not the other governs half the fleet
#
# Offline. The live half ran against the reference deployment: Add-ClaudeModel
# listed the account's Claude deployments, refused an undeployed model, and
# wrote a price book that loads back as decimal.

$root = Split-Path $PSScriptRoot -Parent
$add = Join-Path $root 'scripts/Add-ClaudeModel.ps1'
$helper = Join-Path $root 'scripts/ClaudeBusinessUnit.ps1'
$policy = Join-Path $root 'scripts/New-ClaudeCodePolicy.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Models - adding one' -ForegroundColor Cyan

Assert 'a model command exists' (Test-Path $add)
$a = Get-Content $add -Raw

# It must show only what this gateway fronts. The reference account also carries
# GPT, Sora and embedding deployments; listing them as unpriced is true and
# useless, and it buries the Claude model that actually needs a price.
Assert 'it reuses the Claude deployment filter' ($a -match 'ClaudeModelDeployment\.ps1')
Assert 'and does not list deployments itself'   ($a -notmatch 'az cognitiveservices account deployment list')

# The quiet failure. A model served at no price reports as zero usage.
Assert 'an unpriced model is refused by default' `
    ($a -match "-not \`$SkipPrice -and -not \(\`$PSBoundParameters\.ContainsKey\('InputPerMillion'\)")
Assert 'and the consequence is named'  ($a -match 'reported at zero')
Assert 'skipping the price is possible but loud' ($a -match 'will report as \$0')

# A tier allowing a model the account does not serve refuses the caller with a
# model name that looks correct.
Assert 'an undeployed model is refused'   ($a -match "is not deployed on Foundry account")
Assert 'and the error names what is deployed' ($a -match 'Deployed: ')
Assert 'staging ahead of deployment is possible' ($a -match '\$SkipDeploymentCheck')

# Refusing without offering the fix is a dead end. -Deploy creates it, using the
# existing helper so a quota refusal is still reported as quota.
Assert 'it can deploy the model itself' ($a -match 'New-ClaudeDeployment -Account \$FoundryAccount')
Assert 'and the refusal points at that'  ($a -match 'Pass -Deploy to create it now')

# Retiring has to be one command too, or it becomes a portal click-through.
Assert 'a model can be removed from a tier' ($a -match 'if \(\$Remove\)')
Assert 'removal keeps the sentinel commas' ($a -match [regex]::Escape("else { ',,' }"))
Assert 'and the price is deliberately kept' ($a -match 'price stays in the price book on purpose')

Assert 'it tells developers what changes' ($a -match 'What developers change')
Assert 'and warns about pinned availableModels' ($a -match 'availableModels')

Write-Host ''
Write-Host 'Models - the price book' -ForegroundColor Cyan

$h = Get-Content $helper -Raw
Assert 'the price book can be a file'    ($h -match 'config/price-book\.json')
Assert 'it is loaded at dot-source time' ($h -match '(?m)^Import-ClaudePriceBook \| Out-Null')
Assert 'a malformed book throws'         ($h -match 'Delete it to fall back to the built-in rates')
Assert 'and there is still a built-in fallback' ($h -match "'claude-sonnet-5'\s*=\s*@\{ InputPerM = \[decimal\]")

# ConvertFrom-Json yields doubles. ADR-0010 requires decimal end to end, and a
# double here would reach the blended rate and stop figures reproducing.
Assert 'file rates are cast to decimal' `
    ($h -match 'InputPerM\s*=\s*\[decimal\]\$m\.inputPerM' -and $h -match 'OutputPerM\s*=\s*\[decimal\]\$m\.outputPerM')

# Behavioural: load an example book and check what comes back.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pb-" + [guid]::NewGuid().ToString('N') + '.json')
@'
{ "date": "2099-01-01", "models": { "claude-test-1": { "inputPerM": 3.5, "outputPerM": 17.25 } } }
'@ | Set-Content $tmp -Encoding ascii
try {
    . $helper
    Import-ClaudePriceBook -Path $tmp | Out-Null
    Assert 'a file book replaces the built-in one' ($ClaudePriceBook.Keys -contains 'claude-test-1')
    Assert 'and its rates load as decimal'         ($ClaudePriceBook['claude-test-1'].InputPerM -is [decimal])
    Assert 'with the value intact'                 ($ClaudePriceBook['claude-test-1'].OutputPerM -eq [decimal]17.25)
    Assert 'and the book date comes with it'       ($ClaudePriceBookDate -eq '2099-01-01')

    $bad = Join-Path ([IO.Path]::GetTempPath()) ("pb-" + [guid]::NewGuid().ToString('N') + '.json')
    '{ "date": "2099-01-01" }' | Set-Content $bad -Encoding ascii
    $threw = $false
    try { Import-ClaudePriceBook -Path $bad | Out-Null } catch { $threw = $true }
    Assert 'a book with no models throws rather than being ignored' $threw
    Remove-Item $bad -Force -EA SilentlyContinue
}
finally { Remove-Item $tmp -Force -EA SilentlyContinue }

$ignore = Get-Content (Join-Path $root '.gitignore') -Raw
Assert 'the live price book is git-ignored' ($ignore -match '(?m)^config/price-book\.json')
Assert 'and an example ships instead' (Test-Path (Join-Path $root 'config/price-book.example.json'))

Write-Host ''
Write-Host 'Plugins - marketplaces and extensions' -ForegroundColor Cyan

$p = Get-Content $policy -Raw

# One idea, two key names. A profile that sets one governs half the fleet.
Assert 'Claude Code gets strictKnownMarketplaces' ($p -match "\`$settings\['strictKnownMarketplaces'\] = \`$sources")
Assert 'Claude Desktop gets allowedPluginMarketplaces' ($p -match "\`$desktop\['allowedPluginMarketplaces'\] = \`$sources")
Assert 'both come from the same input'  ($p -match '\$sources = @\(\$Marketplace')

Assert 'a marketplace must be owner/repo' ($p -match "is not owner/repo")
Assert 'and it is a source object, not a string' ($p -match "source = 'github'; repo = \`$repo")

Assert 'user marketplace adds can be blocked' ($p -match "userPluginMarketplacesEnabled'\] = \`$false")
Assert 'user plugin uploads too'              ($p -match "userPluginUploadsEnabled'\] = \`$false")
# Those two apply only in third-party mode, so the mode has to be pinned.
Assert 'and the deployment mode is pinned with them' ($p -match "disableDeploymentModeChooser'\] = \`$true")
Assert 'signed extensions can be required'    ($p -match "isDesktopExtensionSignatureRequired'\] = \`$true")

# The desktop block was built and discarded before this, so the tab settings the
# script has always accepted never reached a machine.
#
# Anchored at line start: matching the string anywhere passed with the Save
# commented out, because the commented line still contains it.
Assert 'the desktop profile is written' ($p -match '(?m)^Save "\$desktopBase\.managed-settings\.json"')
Assert 'and a registry form with it'    ($p -match '(?m)^Save "\$desktopBase\.reg"')
Assert 'the registry file is UTF-16'    ($p -match 'Save "\$desktopBase\.reg" \$desktopReg ''Unicode''')

# Desktop reads no subkeys, and every value is a string.
Assert 'desktop values are written as strings' ($p -match "if \(\`$v -is \[bool\]\) \{ if \(\`$v\) \{ 'true' \} else \{ 'false' \} \}")
# Piping a one-element array to ConvertTo-Json unwraps it, and
# allowedPluginMarketplaces is object[] - one marketplace would become an object.
Assert 'arrays survive as arrays' ($p -match 'ConvertTo-Json -InputObject \$v -Depth 8 -Compress')

Write-Host ''
Write-Host 'Documentation' -ForegroundColor Cyan

$m = Get-Content (Join-Path $root 'docs/MODELS.md') -Raw
Assert 'adding a model is documented' ($m -match '(?m)^# Adding a model')
Assert 'it names the four things that must agree' ($m -match 'Deployed' -and $m -match 'Allowed' -and $m -match 'Priced' -and $m -match 'Selectable')
Assert 'and which one fails quietly' ($m -match 'The third is the one that fails quietly')
Assert 'it says the price book is not in the repository' ($m -match 'may hold your\s+negotiated rates')
Assert 'and that a retired model keeps its price' ($m -match 'price-book entry stays')

$pl = Get-Content (Join-Path $root 'docs/PLUGINS.md') -Raw
Assert 'plugins are documented' ($pl -match '(?m)^# Plugins, marketplaces and extensions')
Assert 'it says what a plugin can do' ($pl -match "runs with the developer's own permissions")
# The honest caveat. Without it an admin reads these as a boundary.
Assert 'it states these are not data boundaries' ($pl -match 'feature-availability controls, not data boundaries')
Assert 'and that already-registered marketplaces survive' ($pl -match 'does not revoke what is already\s+there')
Assert 'it names the three silent Desktop failures' `
    ($pl -match 'Desktop values are strings' -and $pl -match 'Desktop reads no subkeys' -and $pl -match 'must be root-owned')
Assert 'and how to check the policy applied' ($pl -match 'Enterprise managed settings\s+\(file\)')
# A verification step for one client only leaves the other half unchecked, and
# a behavioural check alone cannot tell a rejected policy from an applied one
# that happens to allow the thing you tried.
Assert 'Desktop has its own verification'  ($pl -match 'Quit and reopen the app')
Assert 'including where a rejection is logged' ($pl -match 'main\.log')
# An arbitrary repository is not a marketplace.
Assert 'it says a marketplace needs a catalog file' ($pl -match '\.claude-plugin/marketplace\.json')
Assert 'and links the marketplace documentation'    ($pl -match 'code\.claude\.com/docs/en/plugin-marketplaces')

$readme = Get-Content (Join-Path $root 'README.md') -Raw
Assert 'the README links the model guide'  ($readme -match '\[Models\]\(docs/MODELS\.md\)')
Assert 'and the plugin guide'              ($readme -match '\[Plugins\]\(docs/PLUGINS\.md\)')

Write-Host ''
Write-Host 'Health - one command for the whole gateway' -ForegroundColor Cyan

$health = Join-Path $root 'scripts/Test-ClaudeHealth.ps1'
Assert 'a health check exists' (Test-Path $health)
$hc = Get-Content $health -Raw

# It composes the shipped checks rather than reimplementing them. A second copy
# of the logic drifts, and then the summary and the detail disagree.
foreach ($s in 'Compare-ClaudeEntitlement.ps1', 'Measure-ClaudeCeiling.ps1', 'Get-ClaudeBypass.ps1') {
    Assert "it runs $s" ($hc -match [regex]::Escape($s))
}
Assert 'and uses their exit codes'  ($hc -match '\$code = \$LASTEXITCODE')
Assert 'named, not positional'      ($hc -match '\[hashtable\]\$ScriptArgs')

# Write-Host does not travel on the success or error stream, so 2>&1 captured
# nothing and the sub-checks printed sixty lines over the summary.
Assert 'child output is captured, not printed' ($hc -match '& \$path @ScriptArgs \*>&1')
Assert 'and can be shown on request'           ($hc -match 'if \(\$Detailed\) \{ Write-Host \$out')

# The classic-tier case is the one that looks healthy and meters nothing.
Assert 'a classic SKU fails the run' ($hc -match "\`$sku -in @\('BasicV2', 'StandardV2', 'PremiumV2'\)")
Assert 'and says why it matters'     ($hc -match 'meter as zero tokens')

# A deployed model with no price is served and reported at nothing.
Assert 'unpriced models are a failure' ($hc -match 'deployed but unpriced')
# Spend landing on no budget is worth surfacing but is not broken.
Assert 'unassigned developers are a warning' ($hc -match "Add-Result 'Business units' 'warn'")

# quota-org is evaluated before the per-unit quota and on the same monthly
# period, so a ceiling below the sum of the unit budgets makes every one of them
# unreachable while each still reports headroom. Nothing used to notice.
Assert 'the ceiling is compared to the unit budgets' ($hc -match "Add-Result 'Organisation ceiling'")
Assert 'and an unreachable budget fails the run'     ($hc -match "'Organisation ceiling' 'fail'")
Assert 'it says no unit budget can bind'             ($hc -match 'no unit budget can ever bind')
# Teams are charged to their parent as well, so counting both double counts.
Assert 'only top-level units are summed'             ($hc -match '\$reg \| Where-Object \{ -not \$par\[\$_\.Id\] \}')

$sbu = Get-Content (Join-Path $root 'scripts/Set-ClaudeBusinessUnit.ps1') -Raw
Assert 'setting a budget checks the ceiling too' ($sbu -match "Id 'quota-org'")
Assert 'and warns when it cannot be reached'     ($sbu -match 'ceiling is smaller than what the units are allowed')
Assert 'it sums only top-level units'            ($sbu -match '\$registry \| Where-Object \{ -not \$parents\[\$_\.Id\] \}')
Assert 'and names the command that raises it'    ($sbu -match 'named-value-id quota-org')

Assert 'every finding carries its fix' ($hc -match 'if \(\$r\.fix\) \{ Write-Host')
Assert 'it exits non-zero on a failure' ($hc -match '(?m)^if \(\$failed\.Count\) \{ exit 1 \}')
Assert 'and can be made strict'         ($hc -match "if \(\`$FailOn -eq 'warn' -and \`$warned\.Count\) \{ exit 1 \}")
Assert 'it can emit JSON for monitoring' ($hc -match 'healthy = \(\$failed\.Count -eq 0\)')

# Nothing is written. A health check that changes state cannot be run freely.
Assert 'it does not write named values' ($hc -notmatch 'Set-ApimNamedValue')
Assert 'and says so'                    ($hc -match 'Nothing is written')

$readme2 = Get-Content (Join-Path $root 'README.md') -Raw
Assert 'the README points at it' ($readme2 -match 'Test-ClaudeHealth\.ps1')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Models and plugins contract holds.' -ForegroundColor Green
exit 0
