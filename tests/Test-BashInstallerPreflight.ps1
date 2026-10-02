# P92 acceptance test 2, bash half (docs/adr/0047-lean-installer-phase-0.md): install-claude-gateway.sh
# --preflight checks every answer and the estate before any write, with the same check ids, results and
# reasons as Install-ClaudeGateway.ps1 -Preflight (tests/Test-InstallerPreflight.ps1). An answer that
# only the PowerShell installer applies is also reported under answers.schema. Runs through the stubs
# of tests/BashInstallerHarness.ps1; nothing reaches Azure.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Installer preflight (bash installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'BashInstallerHarness.ps1')
$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('p92-bash-preflight-' + [guid]::NewGuid().ToString('N'))))
$made = New-BashTemplate $scratch
$template = $made.Template; $psTable = $made.PsTable
$ids = @('answers.schema', 'answers.crossField', 'target.tenant', 'target.subscription', 'operator.adminPrereqs', 'foundry.account', 'foundry.deployments',
    'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity', 'entra.groupNames', 'businessUnits.ids', 'businessUnits.depth', 'address.inputs')
$azureChecks = @('target.tenant', 'target.subscription', 'foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity', 'entra.groupNames')

# ------------------------------------------------------------------ static checks
$p92Libraries = @('scripts/install-answers.sh', 'scripts/install-preflight.sh', 'scripts/install-steps.sh') | ForEach-Object { Join-Path $root $_ }
$missing = @($p92Libraries | Where-Object { -not (Test-Path -LiteralPath $_) })
$syntax = @(foreach ($p in @($p92Libraries | Where-Object { Test-Path -LiteralPath $_ })) { $o = (& $bash -n (ConvertTo-BashPath $p) 2>&1 | Out-String).Trim(); if ($o -or $LASTEXITCODE) { "$p $o" } })
Assert 'A13 the P92 bash libraries exist and pass bash -n' (-not $missing.Count -and -not $syntax.Count) "missing: $($missing -join ', '); $($syntax -join ' | ')"
$forbidden = '(?m)^[^#\n]*(\b(declare|local|typeset)\s+-[a-zA-Z]*A\b|\bmapfile\b|\breadarray\b|\$\{[^}\n]*(,,|\^\^)[^}\n]*\}|\|&|&>>|\bcoproc\b|\bsed\s+-i(\s|$)|\bdate\s+(-[a-zA-Z]*\s+)*-d\b|\breadlink\s+-f\b|\bstat\s+-c\b|\bfind\b[^\n]*-printf\b|\bgrep\s+-[a-zA-Z]*P)'
$text = (@(@($p92Libraries) + (Join-Path $root 'install-claude-gateway.sh') | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n")
$hits = @([regex]::Matches($text, $forbidden) | ForEach-Object { $_.Value.Trim() })
Assert 'A13 bash stays 3.2-compatible: no associative arrays, mapfile, case-modifying expansions, GNU-only sed -i, date -d, readlink -f, stat -c or grep -P' (-not $missing.Count -and -not $hits.Count) ($hits -join ' | ')

$base = [ordered]@{ schemaVersion = 1; SubscriptionId = $sub; FoundryAccount = 'ai-p91'; FoundryResourceGroup = 'rg-ai-p91'; ResourceGroup = 'rg-p91'; Location = 'eastus2'
    NamePrefix = 'p92gw'; PublisherEmail = 'ops@contoso.com'; Sku = 'BasicV2'; StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium' }
function New-Answers([scriptblock]$Change) { $a = ($base | ConvertTo-Json -Depth 8) | ConvertFrom-Json; if ($Change) { & $Change $a }; $a }
function Set-Answer($Doc, [string]$Name, $Value) { $Doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
$scenarios = [ordered]@{}
function Add-Scenario([string]$Name, $World, $Answers, [switch]$Text, [hashtable]$Environment = @{}) {
    $s = New-Scenario $Name $World
    $file = Join-Path $s.Dir 'answers.json'
    Write-Lf $file ($Answers | ConvertTo-Json -Depth 10)
    $arguments = @('--preflight', '--answers-file', (ConvertTo-BashPath $file)) + $(if ($Text) { @() } else { @('--json') })
    $scenarios[$Name] = [pscustomobject]@{ Scenario = $s; Run = (New-Run $s $arguments $Environment); Result = $null; Json = $null; Text = [bool]$Text }
}
function Get-Check($Name, [string]$Id) { $j = $scenarios[$Name].Json; if ($j) { @($j.checks | Where-Object { $_.id -eq $Id })[0] } }
function Show($Name) { $r = $scenarios[$Name].Result; if ($r) { "exit $($r.ExitCode): " + (Get-Tail $r) } else { 'no result' } }

try {
    Add-Scenario 'pass' (New-World) (New-Answers)
    $w = New-World; $w['signedOut'] = $true
    Add-Scenario 'signed-out' $w (New-Answers)
    Add-Scenario 'foundry-missing' (New-World) (New-Answers { param($a) $a.FoundryAccount = 'ai-missing' })
    Add-Scenario 'deployment-missing' (New-World) (New-Answers { param($a) Set-Answer $a 'StandardModels' @('claude-haiku-9') })
    $w = New-World; $w['apimNamesTaken'] = @('apim-p92taken')
    Add-Scenario 'name-taken' $w (New-Answers { param($a) $a.NamePrefix = 'p92taken' })
    $reuse = { param($a) foreach ($n in 'NamePrefix', 'Location', 'PublisherEmail', 'Sku') { $a.PSObject.Properties.Remove($n) }; Set-Answer $a 'ExistingApimName' 'apim-p92reuse' }
    $w = New-World; $w.resourceGroups['rg-p91'] = 'eastus2'; $w.apims['apim-p92reuse'] = [ordered]@{ rg = 'rg-p91'; sku = 'StandardV2'; location = 'eastus2'; identity = 'None'; apis = @() }
    Add-Scenario 'no-identity' $w (New-Answers $reuse)
    $w = New-World; $w.resourceGroups['rg-p91'] = 'eastus2'; $w.apims['apim-p92reuse'] = [ordered]@{ rg = 'rg-p91'; sku = 'Developer'; location = 'eastus2'; identity = 'SystemAssigned'; apis = @() }
    Add-Scenario 'classic-sku' $w (New-Answers $reuse)
    $w = New-World; $w.inject.readErrors = @([ordered]@{ match = 'ad group list --display-name claude-code-standard*'; text = 'ERROR: Insufficient privileges to complete the operation. (Authorization_RequestDenied)' })
    Add-Scenario 'graph-error' $w (New-Answers)
    $w = New-World; $w.inject['groupLists'] = [ordered]@{ 'claude-code-standard' = @([ordered]@{ id = '00000000-0000-4000-8000-0000000002a1'; displayName = 'CLAUDE-CODE-STANDARD' }, [ordered]@{ id = '00000000-0000-4000-8000-0000000002a2'; displayName = 'Claude-Code-Standard' }) }
    Add-Scenario 'same-length' $w (New-Answers)
    $kvBad = { param($a) Set-Answer $a 'AddressMode' 'custom'; Set-Answer $a 'AddressHostname' 'claude.contoso.com'; Set-Answer $a 'AddressCertificateSource' 'KeyVault'; Set-Answer $a 'AddressKeyVaultCertificateId' 'http://kv-contoso/certificates'; Set-Answer $a 'AddressDnsMode' 'External' }
    Add-Scenario 'kv-malformed' (New-World) (New-Answers $kvBad)
    Add-Scenario 'all-at-once' (New-World) (New-Answers { param($a) $a.FoundryAccount = 'ai-missing'; $a.StandardGroup = "O'Brien"
            Set-Answer $a 'BusinessUnits' @([ordered]@{ id = 'Finance'; group = 'claude-bu-finance'; monthlyUsdBudget = 5000; mode = 'Strict' }); & $kvBad $a })
    # One scenario for each branch of the lead's round-2 review, as in tests/Test-InstallerPreflight.ps1:
    # the tenant and the state of the answered subscription, an unreadable one, the account list without
    # FoundryResourceGroup, no Claude deployment, failing admin prerequisites (the harness's curl cannot
    # reach management.azure.com), a PFX path that is not a file, and az output that is not JSON.
    $textWorld = $w
    $otherTenant = '00000000-0000-4000-8000-0000000000f2'
    $w = New-World; $w['subscriptionTenantId'] = $otherTenant
    Add-Scenario 'cross-tenant' $w (New-Answers)
    $w = New-World; $w['subscriptionState'] = 'Disabled'
    Add-Scenario 'disabled' $w (New-Answers)
    $w = New-World; $w.inject.readErrors = @([ordered]@{ match = 'account show --subscription*'; text = "ERROR: (AuthorizationFailed) The client does not have authorization to read subscription $sub." })
    Add-Scenario 'sub-unreadable' $w (New-Answers)
    $noRg = { param($a) $a.PSObject.Properties.Remove('FoundryResourceGroup') }
    Add-Scenario 'list-found' (New-World) (New-Answers $noRg)
    Add-Scenario 'list-missing' (New-World) (New-Answers { param($a) $a.PSObject.Properties.Remove('FoundryResourceGroup'); $a.FoundryAccount = 'ai-missing' })
    $w = New-World; $w.foundry.deployments = @([ordered]@{ name = 'gpt-4o'; properties = [ordered]@{ model = [ordered]@{ format = 'OpenAI'; name = 'gpt-4o'; version = '2024-08-06' } } })
    Add-Scenario 'no-claude' $w (New-Answers)
    Add-Scenario 'prereq-fail' (New-World) (New-Answers) -Environment @{ P91_MANAGEMENT_UNREACHABLE = '1' }
    $pfxMissing = '/nonexistent-p92/no-such-certificate.pfx'
    Add-Scenario 'pfx-missing' (New-World) (New-Answers { param($a) Set-Answer $a 'AddressMode' 'custom'; Set-Answer $a 'AddressHostname' 'claude.contoso.com'; Set-Answer $a 'AddressCertificateSource' 'Pfx'; Set-Answer $a 'AddressPfxPath' $pfxMissing; Set-Answer $a 'AddressDnsMode' 'External' })
    $w = New-World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'cognitiveservices account list*'; text = '<html><body>Service Unavailable</body></html>' })
    Add-Scenario 'list-not-json' $w (New-Answers $noRg)
    $w = New-World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'account show -o json'; text = '<html><body>Sign in</body></html>' })
    Add-Scenario 'account-not-json' $w (New-Answers)
    $w = New-World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'account show -o json'; text = '{"user": {"name": "admin@contoso.com", "type": "user"}, "name": "p91-subscription"}' })
    Add-Scenario 'account-no-tenant' $w (New-Answers)
    Add-Scenario 'text' $textWorld (New-Answers) -Text

    $results = Invoke-Runs @($scenarios.Values | ForEach-Object { $_.Run })
    foreach ($s in $scenarios.Values) {
        $s.Result = $results[$s.Run.Dir]
        if (-not $s.Text) { try { $s.Json = $s.Result.Out | ConvertFrom-Json -ErrorAction Stop } catch { $s.Json = $null } }
    }

    $shape = @(foreach ($s in @($scenarios.GetEnumerator() | Where-Object { -not $_.Value.Text })) {
            $j = $s.Value.Json
            $got = @(if ($j) { $j.checks | ForEach-Object { [string]$_.id } })
            $bad = @(if ($j) { $j.checks | Where-Object { $_.result -cnotin 'PASS', 'FAIL', 'NOT-RUN' -or ($_.result -eq 'NOT-RUN' -and -not $_.reason) -or ($_.result -eq 'FAIL' -and (-not $_.message -or -not $_.remedy)) } })
            if (-not $j -or $j.schemaVersion -ne 1 -or $j.installer -ne 'bash' -or ($got -join ',') -ne ($ids -join ',') -or $bad.Count -or $j.result -cnotin 'PASS', 'FAIL') { "$($s.Key): $(Show $s.Key)" } })
    Assert 'P2 bash --json prints only JSON: schemaVersion 1, installer bash, the 14 check ids once in order, results PASS, FAIL or NOT-RUN, a reason on every NOT-RUN and a remedy on every FAIL' (-not $shape.Count) ($shape -join ' || ')
    $p = $scenarios['pass']
    $notPassed = @($p.Json.checks | Where-Object { $_.result -eq 'FAIL' -or ($_.result -eq 'NOT-RUN' -and $_.reason -notin 'not-applicable', 'not-answered') } | ForEach-Object { "$($_.id) $($_.result) $($_.reason)" })
    $passed = @($p.Json.checks | Where-Object { $_.result -eq 'PASS' } | ForEach-Object id)
    Assert 'P2 bash complete answers over a matching estate pass: exit 0, and every check that applies passes' ($p.Result.ExitCode -eq 0 -and $p.Json.result -eq 'PASS' -and -not $notPassed.Count -and
        -not @('answers.schema', 'answers.crossField', 'target.tenant', 'target.subscription', 'operator.adminPrereqs', 'foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'entra.groupNames' | Where-Object { $passed -notcontains $_ }).Count) "$($notPassed -join ', ') || passed: $($passed -join ', ') || $(Show 'pass')"
    $so = $scenarios['signed-out']
    $azure = @($so.Json.checks | Where-Object { $_.id -in $azureChecks })
    Assert 'P2 bash not signed in: target.tenant and every Azure check report NOT-RUN with a reason, none passes, and the exit code is not 0' ($so.Result.ExitCode -ne 0 -and $azure.Count -eq $azureChecks.Count -and
        -not @($azure | Where-Object { $_.result -ne 'NOT-RUN' -or -not $_.reason -or -not $_.message }).Count -and (Get-Check 'signed-out' 'target.tenant').reason -eq 'not-signed-in') ((@($azure | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') + ' || ' + (Show 'signed-out'))
    $one = { param([string]$Name, [string]$Id, [string]$Pattern)
        $c = Get-Check $Name $Id
        [bool]($scenarios[$Name].Result.ExitCode -ne 0 -and $c -and $c.result -eq 'FAIL' -and ("$($c.message) $($c.remedy)" -match $Pattern)) }
    $psOnly = { param([string]$Name, [string]$Answer) $c = Get-Check $Name 'answers.schema'; [bool]($c -and $c.result -eq 'FAIL' -and (@($c.problems | ForEach-Object { $_.message }) -join ' ') -match "$Answer is applied by Install-ClaudeGateway\.ps1") }
    Assert 'P2 bash a Foundry account that does not exist is its own FAIL, and the deployment check that needs it is NOT-RUN' ((& $one 'foundry-missing' 'foundry.account' 'ai-missing') -and
        (Get-Check 'foundry-missing' 'foundry.deployments').reason -eq 'prerequisite-failed') (Show 'foundry-missing')
    Assert 'P2 bash a named deployment that the account lacks is a FAIL naming it; StandardModels is reported as an answer only PowerShell applies' ((& $one 'deployment-missing' 'foundry.deployments' 'claude-haiku-9') -and (& $psOnly 'deployment-missing' 'StandardModels')) (Show 'deployment-missing')
    Assert 'P2 bash an API Management name another instance holds is a FAIL' (& $one 'name-taken' 'apim.nameAvailability' 'apim-p92taken') (Show 'name-taken')
    $ni = Get-Check 'no-identity' 'apim.existingIdentity'
    Assert 'P2 bash a reused instance without a system-assigned identity is a FAIL with the portal toggle remedy; ExistingApimName is an answer only PowerShell applies' ((& $one 'no-identity' 'apim.existingIdentity' 'apim-p92reuse') -and
        $ni.remedy -match 'Managed identities' -and $ni.remedy -match 'System assigned' -and (& $psOnly 'no-identity' 'ExistingApimName')) (Show 'no-identity')
    Assert 'P2 bash a reused instance on a classic tier is a FAIL naming the tier' (& $one 'classic-sku' 'apim.existingSku' 'Developer') (Show 'classic-sku')
    Assert 'P2 bash a Microsoft Graph read error on a group name is a FAIL (inconclusive), never a pass' (& $one 'graph-error' 'entra.groupNames' 'claude-code-standard') (Show 'graph-error')
    Assert 'P2 bash two groups with names of the configured length are a FAIL naming both ids' (& $one 'same-length' 'entra.groupNames' '0000000002a1.*0000000002a2|0000000002a2.*0000000002a1') (Show 'same-length')
    Assert 'P2 bash a Key Vault certificate URL of the wrong shape is a FAIL of address.inputs' (& $one 'kv-malformed' 'address.inputs' 'AddressKeyVaultCertificateId') (Show 'kv-malformed')
    $aao = @($scenarios['all-at-once'].Json.checks | Where-Object { $_.result -eq 'FAIL' } | ForEach-Object id)
    Assert 'P2 bash one run with four distinct problems reports all four' ($scenarios['all-at-once'].Result.ExitCode -ne 0 -and
        -not @('foundry.account', 'entra.groupNames', 'businessUnits.ids', 'address.inputs' | Where-Object { $aao -notcontains $_ }).Count) "$($aao -join ', ') || $(Show 'all-at-once')"
    # ------------------------------------------------------------------ each branch fails on its own
    $tn = Get-Check 'cross-tenant' 'target.tenant'
    Assert 'P2 bash a subscription in another tenant than the Azure CLI sign-in is a FAIL of target.tenant naming both tenants, with az login --tenant as the remedy' ((& $one 'cross-tenant' 'target.tenant' "is in tenant $otherTenant, and Azure CLI is signed in to tenant 00000000-0000-4000-8000-0000000000f1") -and
        $tn.remedy -match "az login --tenant $otherTenant") (Show 'cross-tenant')
    Assert 'P2 bash a disabled subscription is a FAIL of target.subscription naming its state' (& $one 'disabled' 'target.subscription' 'is Disabled') (Show 'disabled')
    $later = @('foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity')
    $su = @($scenarios['sub-unreadable'].Json.checks | Where-Object { $_.id -in $later -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
    Assert 'P2 bash a subscription Azure CLI cannot read is a FAIL of target.subscription, and each check that reads in it is NOT-RUN (prerequisite-failed)' ((& $one 'sub-unreadable' 'target.subscription' 'is not readable by admin@contoso\.com \(ERROR: \(AuthorizationFailed\)') -and
        $scenarios['sub-unreadable'].Json -and -not $su.Count) "$(($su | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || $(Show 'sub-unreadable')"
    $lf = $scenarios['list-found']; $lfa = Get-Check 'list-found' 'foundry.account'; $lfd = Get-Check 'list-found' 'foundry.deployments'
    Assert 'P2 bash without FoundryResourceGroup, a Foundry account the subscription lists is found, and its deployments are read in its own resource group' ($lfa.result -eq 'PASS' -and $lfa.message -eq 'Foundry account ai-p91 in the subscription' -and
        $lfd.result -eq 'PASS' -and (Get-Calls $lf.Result 'cognitiveservices account list*').Count -eq 1 -and (Get-Calls $lf.Result 'cognitiveservices account deployment list -g rg-ai-p91 -n ai-p91*').Count -eq 1) (Show 'list-found')
    Assert 'P2 bash without FoundryResourceGroup, a Foundry account the subscription does not list is a FAIL of foundry.account, and its deployments are NOT-RUN' ((& $one 'list-missing' 'foundry.account' 'Foundry account ai-missing was not found in the subscription') -and
        (Get-Check 'list-missing' 'foundry.deployments').reason -eq 'prerequisite-failed') (Show 'list-missing')
    Assert 'P2 bash a Foundry account with no Claude deployment and no PendingClaudeDeployment is a FAIL of foundry.deployments' (& $one 'no-claude' 'foundry.deployments' 'the Foundry account ai-p91 has no Claude deployment') (Show 'no-claude')
    Assert 'P2 bash failing admin prerequisites are a FAIL of operator.adminPrereqs naming the failed check (the harness cannot reach management.azure.com)' (& $one 'prereq-fail' 'operator.adminPrereqs' 'cannot reach management\.azure\.com') (Show 'prereq-fail')
    Assert 'P2 bash an AddressPfxPath that is not a file is a FAIL of address.inputs naming the path' (& $one 'pfx-missing' 'address.inputs' "AddressPfxPath '/nonexistent-p92/no-such-certificate\.pfx' is not a file") (Show 'pfx-missing')
    Assert 'P2 bash a Foundry account list that is not JSON is an inconclusive FAIL of foundry.account, and its deployments are NOT-RUN' ((& $one 'list-not-json' 'foundry.account' 'Foundry account ai-p91 could not be read \(az cognitiveservices account list did not return JSON\)') -and
        (Get-Check 'list-not-json' 'foundry.deployments').reason -eq 'prerequisite-failed') (Show 'list-not-json')
    $an = @($scenarios['account-not-json'].Json.checks | Where-Object { $_.id -in @($azureChecks | Select-Object -Skip 1) -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
    Assert 'P2 bash an az account show that is not JSON is an inconclusive FAIL of target.tenant, and every other Azure check is NOT-RUN' ((& $one 'account-not-json' 'target.tenant' 'the signed-in account could not be read \(az account show did not return JSON\)') -and
        $scenarios['account-not-json'].Json -and -not $an.Count) "$(($an | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || $(Show 'account-not-json')"
    $nt = @($scenarios['account-no-tenant'].Json.checks | Where-Object { $_.id -in @($azureChecks | Select-Object -Skip 1) -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
    Assert 'P2 bash an az account show without a tenantId is an inconclusive FAIL of target.tenant, and every other Azure check is NOT-RUN' ((& $one 'account-no-tenant' 'target.tenant' 'the signed-in account could not be read \(az account show returned no tenantId\)') -and
        $scenarios['account-no-tenant'].Json -and -not $nt.Count) "$(($nt | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || $(Show 'account-no-tenant')"
    # Fail closed by construction: every check starts NOT-RUN (not-evaluated) and passes only through
    # pf_pass_ with a message, so a branch that sets nothing cannot read as a PASS.
    $loose = @(foreach ($s in $scenarios.GetEnumerator()) { $j = $s.Value.Json; if ($j) { foreach ($c in @($j.checks)) { if ($c.reason -eq 'not-evaluated' -or ($c.result -eq 'PASS' -and -not "$($c.message)".Trim())) { "$($s.Key): $($c.id) $($c.result)/$($c.reason)" } } } })
    Assert 'P2 bash fail closed: in every scenario each PASS carries its message, and no check is left NOT-RUN not-evaluated (ADR-0047 decision 5)' (-not $loose.Count -and @($scenarios.Values | Where-Object { $_.Json }).Count -ge 20) ($loose -join ' || ')
    $tx = $scenarios['text'].Result
    $lines = @($tx.Out -split "`n" | Where-Object { $_ -match '^\s*\[(PASS|FAIL|NOT-RUN)\] ([A-Za-z.]+): ' })
    $lineIds = @($lines | ForEach-Object { [regex]::Match($_, '\] ([A-Za-z.]+):').Groups[1].Value } | Select-Object -Unique)
    Assert 'P2 bash the text report has one line per check, [RESULT] id: message, and each FAIL line ends with its remedy' ($tx.ExitCode -ne 0 -and ($lineIds -join ',') -eq ($ids -join ',') -and
        @($lines | Where-Object { $_ -match '\[FAIL\] entra\.groupNames: .*Remedy: ' }).Count -ge 1 -and $tx.Out -match '(?m)^\s*Preflight: 14 checks; \d+ PASS, \d+ FAIL, \d+ NOT-RUN\.') (Get-Tail $tx)
    $writes = @(foreach ($s in $scenarios.Values) { @($s.Result.Az | Where-Object { $_ -match '(^| )(create|update|delete|set|add|remove|login|purge|assign|start|stop)( |$)' }) })
    $files = @(foreach ($s in $scenarios.Values) { @(Get-ChildItem -LiteralPath $s.Scenario.Home -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'install-*' } | ForEach-Object Name) })
    $scripts = @(foreach ($s in $scenarios.Values) { @($s.Result.Scripts | Where-Object { $_ -notmatch 'PSVersionTable' }) })
    $unexpected = @(foreach ($s in $scenarios.Values) { @($s.Result.Unexpected) })
    Assert 'P2 bash read-only: no run made a create, update, set, delete, assign or login call, ran a child script, or wrote a checkpoint, lock or temporary file' (-not $writes.Count -and -not $files.Count -and -not $scripts.Count -and
        @($scenarios.Values | Where-Object { $_.Result.Az.Count }).Count -ge 10) "writes: $(($writes | Select-Object -Unique -First 5) -join ' | '); files: $($files -join ', '); scripts: $($scripts -join ', ')"
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @($scenarios.Values | Where-Object { $_.Result.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
