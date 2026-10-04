# P92 acceptance test 2, PowerShell half (docs/adr/0047-lean-installer-phase-0.md): Install-ClaudeGateway.ps1
# -Preflight checks every answer and the estate before any write. Each scenario is a child PowerShell over
# the az stub of tests/InstallerCheckpointStubs.ps1 with its own world; nothing reaches Azure. The bash
# installer's half is tests/Test-BashInstallerPreflight.ps1.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerCheckpointHarness.ps1')
. (Join-Path $PSScriptRoot 'InstallerRedactionShapes.ps1')
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Installer preflight (PowerShell installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$scratch = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('p92-preflight-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$script:windows = [bool]($IsWindows -or $env:OS -eq 'Windows_NT')
$ids = @('answers.schema', 'answers.crossField', 'target.tenant', 'target.subscription', 'operator.adminPrereqs', 'foundry.account', 'foundry.deployments',
    'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity', 'entra.groupNames', 'businessUnits.ids', 'businessUnits.depth', 'address.inputs')
$azureChecks = @('target.tenant', 'target.subscription', 'foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity', 'entra.groupNames')
$sub = $script:P91Subscription
$answers = [ordered]@{ schemaVersion = 1; SubscriptionId = $sub; FoundryAccount = 'ai-p91'; FoundryResourceGroup = 'rg-ai-p91'; ResourceGroup = 'rg-p91'; Location = 'eastus2'
    NamePrefix = 'p92gw'; PublisherEmail = 'ops@contoso.com'; Sku = 'BasicV2'; StandardModels = @('claude-sonnet-5'); PremiumModels = @('claude-opus-5', 'claude-sonnet-5')
    EntitlementStore = 'named-value'; AuthMode = 'interactive'; DesktopSignInKind = 'helper-script'; AddressMode = 'azure' }
function New-Answers([scriptblock]$Change) { $a = ($answers | ConvertTo-Json -Depth 8) | ConvertFrom-Json; if ($Change) { & $Change $a }; $a }
function Set-Answer($Doc, [string]$Name, $Value) { $Doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
function Remove-Answer($Doc, [string]$Name) { $Doc.PSObject.Properties.Remove($Name) }
$scenarios = [ordered]@{}
function Add-Scenario([string]$Name, $World, $Answers, [switch]$Text) {
    $s = New-P91Scenario -Name $Name -Scratch $scratch -Template $template -World $World
    $file = Join-Path $s.Dir 'answers.json'
    Write-P91Text $file ($Answers | ConvertTo-Json -Depth 10)
    $arguments = @('-Preflight', "-AnswersPath '$file'") + $(if ($Text) { @() } else { @('-Json') })
    $scenarios[$Name] = [pscustomobject]@{ Scenario = $s; Run = (New-P91Run $s -Arguments $arguments); Result = $null; Json = $null; Text = [bool]$Text }
}
function Get-Check($Name, [string]$Id) { $j = $scenarios[$Name].Json; if ($j) { @($j.checks | Where-Object { $_.id -eq $Id })[0] } }
function Show($Name) { $r = $scenarios[$Name].Result; if ($r) { "exit $($r.ExitCode): " + (Get-P91Tail $r) } else { 'no result' } }
function Invoke-CmdMarkerPreflight {
    param([string]$Name, [scriptblock]$Change)
    $dir = Join-Path $scratch "cmd-marker\$Name"
    $repo = Join-Path $dir 'repo'
    $bin = Join-Path $dir 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -LiteralPath $template -Destination $repo -Recurse
    $marker = Join-Path $dir 'marker.txt'
    $doc = New-Answers
    & $Change $doc
    $answersPath = Join-Path $dir 'answers.json'
    Write-P91Text $answersPath ($doc | ConvertTo-Json -Depth 10)
    Write-P91Text (Join-Path $bin 'az.cmd') $markerAz
    $psi = [Diagnostics.ProcessStartInfo]::new($script:P91Pwsh)
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $repo 'Install-ClaudeGateway.ps1'), '-Preflight', '-Json', '-AnswersPath', $answersPath)) { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.WorkingDirectory = $repo
    $psi.Environment['PATH'] = "$bin;$($psi.Environment['PATH'])"
    $psi.Environment['AZURE_CONFIG_DIR'] = Join-Path $dir 'az'
    $psi.Environment['P93_MARKER_PATH'] = $marker
    $p = [Diagnostics.Process]::Start($psi)
    # Both pipes drain at once on threads of their own (ADR-0047 decision 16), and the run is bounded.
    $outRead = Start-ChildOutputRead $p.StandardOutput
    $errRead = Start-ChildOutputRead $p.StandardError
    $exited = $p.WaitForExit(120000)
    if (-not $exited) { try { $p.Kill($true) } catch { } }
    $out = Receive-ChildOutputRead $outRead "The standard output of the $Name marker preflight"
    $err = Receive-ChildOutputRead $errRead "The standard error of the $Name marker preflight"
    $messages = try { @(($out | ConvertFrom-Json -ErrorAction Stop).checks | ForEach-Object { $_.problems } | ForEach-Object { [string]$_.message }) } catch { @() }
    [pscustomobject]@{ Name = $Name; ExitCode = $(if ($exited) { $p.ExitCode } else { -1 }); Out = $out; Err = $err; Marker = $marker; Messages = $messages }
}

try {
    $template = New-P91Template $scratch
    if ($script:windows) {
        # A payload that fits every other rule of each answer: short (SubscriptionId allows 100 characters) and
        # without a colon (a unit's group refused a colon before 70f07c0). cmd.exe expands P93_MARKER_PATH, which
        # each run sets to its own marker file, so a value that reaches the az.cmd shim writes that file.
        $markerPayload = 'p93&echo.P93_PREFILL_MARKER>%P93_MARKER_PATH%&rem'
        $markerAz = @'
@echo off
if "%1"=="version" echo {"azure-cli":"2.90.0"}& exit /b 0
if "%1"=="bicep" echo Bicep CLI version 0.46.1& exit /b 0
if "%1"=="account" if "%2"=="show" echo {"id":"00000000-0000-4000-8000-0000000000a1","tenantId":"00000000-0000-4000-8000-0000000000f1","name":"p91-subscription","state":"Enabled","user":{"name":"admin@contoso.com"}}& exit /b 0
if "%1"=="account" if "%2"=="list" echo [{"id":"00000000-0000-4000-8000-0000000000a1","tenantId":"00000000-0000-4000-8000-0000000000f1","name":"p91-subscription","state":"Enabled"}]& exit /b 0
echo []
exit /b 0
'@
        # Control: the payload given to the shim as PowerShell passes a native argument writes the marker, so a
        # preflight that leaves no marker never passed the value to Azure CLI.
        $controlDir = Join-Path $scratch 'cmd-marker\control'
        New-Item -ItemType Directory -Force -Path $controlDir | Out-Null
        Write-P91Text (Join-Path $controlDir 'az.cmd') $markerAz
        $controlMarker = Join-Path $controlDir 'marker.txt'
        $env:P93_MARKER_PATH = $controlMarker
        try { $null = & (Join-Path $controlDir 'az.cmd') account show --subscription $markerPayload 2>&1 } finally { Remove-Item Env:P93_MARKER_PATH -ErrorAction SilentlyContinue }
        Assert 'control: the marker payload given straight to an az.cmd shim writes its marker file on this machine' (Test-Path -LiteralPath $controlMarker) $controlMarker
        $schemaDoc = [IO.File]::ReadAllText((Join-Path $script:P91Root 'schemas/claude-gateway.answers.schema.json')) | ConvertFrom-Json
        $markerCases = @(
            @{ Name = 'SubscriptionId'; Path = 'SubscriptionId'; Rule = $schemaDoc.properties.SubscriptionId; Change = { param($a) $a.SubscriptionId = $markerPayload } }
            @{ Name = 'StandardGroup'; Path = 'StandardGroup'; Rule = $schemaDoc.properties.StandardGroup; Change = { param($a) Set-Answer $a 'StandardGroup' $markerPayload } }
            @{ Name = 'PremiumGroup'; Path = 'PremiumGroup'; Rule = $schemaDoc.properties.PremiumGroup; Change = { param($a) Set-Answer $a 'PremiumGroup' $markerPayload } }
            @{ Name = 'BusinessUnits.group'; Path = 'BusinessUnits'; Rule = $schemaDoc.'$defs'.BusinessUnit.properties.group; Change = { param($a) Set-Answer $a 'BusinessUnits' @([ordered]@{ id = 'finance'; group = $markerPayload; monthlyUsdBudget = 100; mode = 'Strict' }) } }
            @{ Name = 'FoundryAccount'; Path = 'FoundryAccount'; Rule = $schemaDoc.properties.FoundryAccount; Change = { param($a) $a.FoundryAccount = $markerPayload } }
        )
        $markerRuns = @(foreach ($c in $markerCases) { $r = Invoke-CmdMarkerPreflight $c.Name $c.Change; $r | Add-Member -NotePropertyName Case -NotePropertyValue $c; $r })
        $markerLeaks = @($markerRuns | Where-Object { Test-Path -LiteralPath $_.Marker })
        # Each value is refused by its own pattern rule: a problem that names the answer and carries the schema's message.
        $markerMisses = @($markerRuns | Where-Object { $run = $_; $why = [string]$run.Case.Rule.'x-patternMessage'
                $run.ExitCode -eq 0 -or -not $why -or -not @($run.Messages | Where-Object { $_.StartsWith($run.Case.Path) -and $_.Contains($why) }).Count })
        Assert 'P93 Windows preflight refuses cmd.exe marker answers before any az.cmd argument can execute them: SubscriptionId, StandardGroup, PremiumGroup, BusinessUnits.group and another az-bound answer' (-not $markerLeaks.Count -and -not $markerMisses.Count) (
            'leaks: ' + (($markerLeaks | ForEach-Object { $_.Name }) -join ', ') + '; misses: ' + (($markerMisses | ForEach-Object { "$($_.Name) exit=$($_.ExitCode) problems=$($_.Messages -join ' / ')" }) -join ', '))
    }
    else {
        Assert 'P93 Windows cmd.exe marker preflight control is Windows-only' $true
        Assert 'P93 Windows cmd.exe marker preflight cases are Windows-only' $true
    }
    Add-Scenario 'pass' (New-P91World) (New-Answers)
    $w = New-P91World; $w['signedOut'] = $true
    Add-Scenario 'signed-out' $w (New-Answers)
    Add-Scenario 'foundry-missing' (New-P91World) (New-Answers { param($a) $a.FoundryAccount = 'ai-missing' })
    Add-Scenario 'deployment-missing' (New-P91World) (New-Answers { param($a) $a.StandardModels = @('claude-haiku-9') })
    $w = New-P91World; $w['apimNamesTaken'] = @('apim-p92taken')
    Add-Scenario 'name-taken' $w (New-Answers { param($a) $a.NamePrefix = 'p92taken' })
    $reuse = { param($a) Remove-Answer $a 'NamePrefix'; Remove-Answer $a 'Location'; Remove-Answer $a 'PublisherEmail'; Remove-Answer $a 'Sku'; Set-Answer $a 'ExistingApimName' 'apim-p91reuse' }
    Add-Scenario 'no-identity' (New-P91World -ReusedGateway -IdentityType 'None') (New-Answers $reuse)
    $w = New-P91World -ReusedGateway; $w.apims['apim-p91reuse'].sku = 'Developer'
    Add-Scenario 'classic-sku' $w (New-Answers $reuse)
    $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'ad group list --display-name claude-code-standard*'; text = 'ERROR: Insufficient privileges to complete the operation. (Authorization_RequestDenied)' })
    Add-Scenario 'graph-error' $w (New-Answers)
    $w = New-P91World; $w.inject['groupLists'] = [ordered]@{ 'claude-code-standard' = @([ordered]@{ id = '00000000-0000-4000-8000-0000000002a1'; displayName = 'CLAUDE-CODE-STANDARD' }, [ordered]@{ id = '00000000-0000-4000-8000-0000000002a2'; displayName = 'Claude-Code-Standard' }) }
    Add-Scenario 'same-length' $w (New-Answers)
    $kvBad = { param($a) $a.AddressMode = 'custom'; Set-Answer $a 'AddressHostname' 'claude.contoso.com'; Set-Answer $a 'AddressCertificateSource' 'KeyVault'; Set-Answer $a 'AddressKeyVaultCertificateId' 'http://kv-contoso/certificates'; Set-Answer $a 'AddressDnsMode' 'External' }
    Add-Scenario 'kv-malformed' (New-P91World) (New-Answers $kvBad)
    Add-Scenario 'all-at-once' (New-P91World) (New-Answers { param($a) $a.FoundryAccount = 'ai-missing'; Set-Answer $a 'StandardGroup' "O'Brien"
            Set-Answer $a 'BusinessUnits' @([ordered]@{ id = 'Finance'; group = 'claude-bu-finance'; monthlyUsdBudget = 5000; mode = 'Strict' }); & $kvBad $a })
    # One scenario for each branch of the lead's round-2 review, each with its own FAIL line (the found
    # account with its PASS): the tenant and the state of the answered subscription, an unreadable one, the
    # account list without FoundryResourceGroup, no Claude deployment, failing admin prerequisites (the
    # harness fails the argument canary of scripts/Test-Prerequisites.ps1), a PFX path that is not a file,
    # and az output that is not JSON (ADR-0047 decision 5).
    $otherTenant = '00000000-0000-4000-8000-0000000000f2'
    $w = New-P91World; $w['subscriptionTenantId'] = $otherTenant
    Add-Scenario 'cross-tenant' $w (New-Answers)
    $w = New-P91World; $w['subscriptionState'] = 'Disabled'
    Add-Scenario 'disabled' $w (New-Answers)
    $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'account show --subscription*'; text = "ERROR: (AuthorizationFailed) The client does not have authorization to read subscription $sub." })
    Add-Scenario 'sub-unreadable' $w (New-Answers)
    $noRg = { param($a) Remove-Answer $a 'FoundryResourceGroup' }
    Add-Scenario 'list-found' (New-P91World) (New-Answers $noRg)
    Add-Scenario 'list-missing' (New-P91World) (New-Answers { param($a) Remove-Answer $a 'FoundryResourceGroup'; $a.FoundryAccount = 'ai-missing' })
    $w = New-P91World; $w.foundry.deployments = @([ordered]@{ name = 'gpt-4o'; sku = [ordered]@{ name = 'GlobalStandard'; capacity = 10 }; properties = [ordered]@{ provisioningState = 'Succeeded'; model = [ordered]@{ format = 'OpenAI'; name = 'gpt-4o'; version = '2024-08-06' } } })
    Add-Scenario 'no-claude' $w (New-Answers { param($a) Remove-Answer $a 'StandardModels'; Remove-Answer $a 'PremiumModels' })
    $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'account list --query*'; text = 'az : ].name was unexpected at this time.' })
    Add-Scenario 'prereq-fail' $w (New-Answers)
    $pfxMissing = '/nonexistent-p92/no-such-certificate.pfx'
    Add-Scenario 'pfx-missing' (New-P91World) (New-Answers { param($a) $a.AddressMode = 'custom'; Set-Answer $a 'AddressHostname' 'claude.contoso.com'; Set-Answer $a 'AddressCertificateSource' 'Pfx'; Set-Answer $a 'AddressPfxPath' $pfxMissing; Set-Answer $a 'AddressDnsMode' 'External' })
    $w = New-P91World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'cognitiveservices account list*'; text = '<html><body>Service Unavailable</body></html>' })
    Add-Scenario 'list-not-json' $w (New-Answers $noRg)
    $w = New-P91World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'account show -o json'; text = '<html><body>Sign in</body></html>' })
    Add-Scenario 'account-not-json' $w (New-Answers)
    $w = New-P91World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'account show -o json'; text = '{"user": {"name": "admin@contoso.com", "type": "user"}, "name": "p91-subscription"}' })
    Add-Scenario 'account-no-tenant' $w (New-Answers)
    # Round 3, the Coder seat's item 1: a subscription record without its id, with a null id or without its
    # tenant, and a current account without an id when SubscriptionId is not answered.
    $user = '"user": {"name": "admin@contoso.com", "type": "user"}'
    $record = { param([string]$Json) $w = New-P91World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'account show --subscription*'; text = $Json }); $w }
    Add-Scenario 'sub-no-id' (& $record ('{"name": "p91-subscription", "state": "Enabled", "tenantId": "' + $script:P91Tenant + '", ' + $user + '}')) (New-Answers)
    Add-Scenario 'sub-null-id' (& $record ('{"id": null, "name": "p91-subscription", "state": "Enabled", "tenantId": "' + $script:P91Tenant + '", ' + $user + '}')) (New-Answers)
    Add-Scenario 'sub-no-tenant' (& $record ('{"id": "' + $sub + '", "name": "p91-subscription", "state": "Enabled", ' + $user + '}')) (New-Answers)
    $w = New-P91World; $w.inject['rawOutputs'] = @([ordered]@{ match = 'account show -o json'; text = ('{"name": "p91-subscription", "tenantId": "' + $script:P91Tenant + '", ' + $user + '}') })
    Add-Scenario 'current-no-id' $w (New-Answers { param($a) Remove-Answer $a 'SubscriptionId' })
    # Round 3, the Security seat's item 5: an error that a message quotes carries every secret shape of
    # tests/InstallerRedactionShapes.ps1, and a remedy lists a deployment named like a secret.
    $redactWorld = { $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'ad group list --display-name claude-code-standard*'; text = $P92RedactionSentence })
        $w.foundry.deployments = @(@($w.foundry.deployments) + @([ordered]@{ name = 'secret=p92RemedySentinel'; sku = [ordered]@{ name = 'GlobalStandard'; capacity = 10 }; properties = [ordered]@{ provisioningState = 'Succeeded'; model = [ordered]@{ format = 'OpenAI'; name = 'gpt-4o'; version = '2024-08-06' } } })); $w }
    $redactAnswers = { param($a) $a.StandardModels = @('claude-sonnet-5', 'claude-p92-missing') }
    Add-Scenario 'redact' (& $redactWorld) (New-Answers $redactAnswers)
    Add-Scenario 'redact-text' (& $redactWorld) (New-Answers $redactAnswers) -Text
    Add-Scenario 'text' (New-P91World -ReusedGateway -IdentityType 'None') (New-Answers $reuse) -Text
    # Round 3, the UX seat's item 9: the engine with every Azure branch left out (a child PowerShell that
    # replaces Invoke-ClaudeGatewayPreflightAzure), so that the checks it evaluates stay not-evaluated.
    $probe = New-P91Scenario -Name 'not-evaluated' -Scratch $scratch -Template $template -World (New-P91World)
    $probeRun = New-P91Run $probe -Command (". '$(Join-Path $probe.Repo 'scripts\ClaudeInstallerPreflight.ps1')'; " +
        'function Get-ClaudePreflightPrerequisites { [pscustomobject]@{ Ok = $true; Fails = @(); Warnings = @() } }; function Invoke-ClaudeGatewayPreflightAzure { }; ' +
        "Invoke-ClaudeGatewayPreflight -Answers ([ordered]@{ SubscriptionId = '$sub' }) -Installer pwsh | ConvertTo-Json -Depth 6")
    # Two runs, kept apart from the read-only preflight scenarios: the run reads a reused instance, and
    # the instances its menu offers, through the same functions as the preflight (U82).
    $runArgs = @("-SubscriptionId '$sub'", "-FoundryAccount 'ai-p91'", "-FoundryResourceGroup 'rg-ai-p91'", "-EntitlementStore 'named-value'", "-AuthMode 'interactive'",
        "-DesktopSignInKind 'helper-script'", "-AddressMode 'azure'", '-SkipFinOpsOffer', "-ResourceGroup 'rg-p91'", "-StandardModels 'claude-sonnet-5'",
        "-PremiumModels 'claude-opus-5','claude-sonnet-5'", '-TpmStandard 20000', '-QuotaStandard 500000', '-TpmPremium 80000', '-QuotaPremium 5000000', '-QuotaOrg 100000000', '-CallsPerMinute 120', '-Yes')
    $runIdentity = New-P91Run (New-P91Scenario -Name 'run-no-identity' -Scratch $scratch -Template $template -World (New-P91World -ReusedGateway -IdentityType 'None')) -Arguments ($runArgs + "-ExistingApimName 'apim-p91reuse'")
    $w = New-P91World; $w.inject.readErrors = @([ordered]@{ match = 'apim list*'; text = 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.ApiManagement/service/read.' })
    $runList = New-P91Run (New-P91Scenario -Name 'run-list-error' -Scratch $scratch -Template $template -World $w) -Arguments ($runArgs + @("-Location 'eastus2'", "-PublisherEmail 'ops@contoso.com'", "-Sku 'BasicV2'"))

    $results = Invoke-P91Runs (@($scenarios.Values | ForEach-Object { $_.Run }) + @($runIdentity, $runList, $probeRun))
    foreach ($s in $scenarios.Values) {
        $s.Result = Get-P91Result $results $s.Run
        if (-not $s.Text) { try { $s.Json = $s.Result.Out | ConvertFrom-Json -ErrorAction Stop } catch { $s.Json = $null } }
    }

    # ------------------------------------------------------------------ the JSON contract
    $shape = @(foreach ($s in @($scenarios.GetEnumerator() | Where-Object { -not $_.Value.Text })) {
            $j = $s.Value.Json
            $got = @(if ($j) { $j.checks | ForEach-Object { [string]$_.id } })
            $bad = @(if ($j) { $j.checks | Where-Object { $_.result -cnotin 'PASS', 'FAIL', 'NOT-RUN' -or ($_.result -eq 'NOT-RUN' -and -not $_.reason) -or ($_.result -eq 'FAIL' -and (-not $_.message -or -not $_.remedy)) } })
            if (-not $j -or $j.schemaVersion -ne 1 -or $j.installer -ne 'pwsh' -or ($got -join ',') -ne ($ids -join ',') -or $bad.Count -or $j.result -cnotin 'PASS', 'FAIL') { "$($s.Key): $(Show $s.Key)" } })
    Assert 'P2 -Json prints only JSON: schemaVersion 1, installer pwsh, the 14 check ids once in order, results PASS, FAIL or NOT-RUN, a reason on every NOT-RUN and a remedy on every FAIL' (-not $shape.Count) ($shape -join ' || ')

    # ------------------------------------------------------------------ each scenario
    $p = $scenarios['pass']
    $notPassed = @($p.Json.checks | Where-Object { $_.result -eq 'FAIL' -or ($_.result -eq 'NOT-RUN' -and $_.reason -notin 'not-applicable', 'not-answered') } | ForEach-Object { "$($_.id) $($_.result) $($_.reason)" })
    $passed = @($p.Json.checks | Where-Object { $_.result -eq 'PASS' } | ForEach-Object id)
    Assert 'P2 complete answers over a matching estate pass: exit 0, and every check that applies passes (tenant, subscription, prerequisites, Foundry account and deployments, name, groups)' ($p.Result.ExitCode -eq 0 -and $p.Json.result -eq 'PASS' -and
        -not $notPassed.Count -and -not @('answers.schema', 'answers.crossField', 'target.tenant', 'target.subscription', 'operator.adminPrereqs', 'foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'entra.groupNames' | Where-Object { $passed -notcontains $_ }).Count) "$($notPassed -join ', ') || passed: $($passed -join ', ') || $(Show 'pass')"
    $so = $scenarios['signed-out']
    $azure = @($so.Json.checks | Where-Object { $_.id -in $azureChecks })
    Assert 'P2 not signed in: target.tenant and every Azure check report NOT-RUN with a reason, none passes, and the exit code is not 0' ($so.Result.ExitCode -ne 0 -and $azure.Count -eq $azureChecks.Count -and
        -not @($azure | Where-Object { $_.result -ne 'NOT-RUN' -or -not $_.reason -or -not $_.message }).Count -and (Get-Check 'signed-out' 'target.tenant').reason -eq 'not-signed-in' -and
        (Get-Check 'signed-out' 'answers.schema').result -eq 'PASS') ((@($azure | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') + ' || ' + (Show 'signed-out'))
    $one = { param([string]$Name, [string]$Id, [string]$Pattern)
        $c = Get-Check $Name $Id
        [bool]($scenarios[$Name].Result.ExitCode -ne 0 -and $c -and $c.result -eq 'FAIL' -and ("$($c.message) $($c.remedy)" -match $Pattern)) }
    Assert 'P2 a Foundry account that does not exist is its own FAIL, and the deployment check that needs it is NOT-RUN' ((& $one 'foundry-missing' 'foundry.account' 'ai-missing') -and
        (Get-Check 'foundry-missing' 'foundry.deployments').result -eq 'NOT-RUN' -and (Get-Check 'foundry-missing' 'foundry.deployments').reason -eq 'prerequisite-failed') (Show 'foundry-missing')
    Assert 'P2 a named deployment that the account lacks is a FAIL naming it' (& $one 'deployment-missing' 'foundry.deployments' 'claude-haiku-9') (Show 'deployment-missing')
    Assert 'P2 an API Management name another instance holds is a FAIL' (& $one 'name-taken' 'apim.nameAvailability' 'apim-p92taken') (Show 'name-taken')
    $ni = Get-Check 'no-identity' 'apim.existingIdentity'
    Assert 'P2 a reused API Management instance without a system-assigned identity is a FAIL whose remedy is the portal toggle, then -ExistingApimName' ((& $one 'no-identity' 'apim.existingIdentity' 'apim-p91reuse') -and
        $ni.remedy -match 'Managed identities' -and $ni.remedy -match 'System assigned' -and $ni.remedy -match '-ExistingApimName apim-p91reuse' -and (Get-Check 'no-identity' 'apim.existingSku').result -eq 'PASS') (Show 'no-identity')
    Assert 'P2 a reused instance on a classic tier is a FAIL naming the tier' (& $one 'classic-sku' 'apim.existingSku' 'Developer') (Show 'classic-sku')
    Assert 'P2 a Microsoft Graph read error on a group name is a FAIL (inconclusive), never a pass' (& $one 'graph-error' 'entra.groupNames' 'claude-code-standard') (Show 'graph-error')
    Assert 'P2 two groups with names of the configured length are a FAIL naming both ids' (& $one 'same-length' 'entra.groupNames' '0000000002a1.*0000000002a2|0000000002a2.*0000000002a1') (Show 'same-length')
    Assert 'P2 a Key Vault certificate URL of the wrong shape is a FAIL of address.inputs' (& $one 'kv-malformed' 'address.inputs' 'AddressKeyVaultCertificateId') (Show 'kv-malformed')
    $aao = @($scenarios['all-at-once'].Json.checks | Where-Object { $_.result -eq 'FAIL' } | ForEach-Object id)
    Assert 'P2 one run with four distinct problems reports all four (Foundry account, group name, business-unit id, Key Vault URL)' ($scenarios['all-at-once'].Result.ExitCode -ne 0 -and
        -not @('foundry.account', 'entra.groupNames', 'businessUnits.ids', 'address.inputs' | Where-Object { $aao -notcontains $_ }).Count) "$($aao -join ', ') || $(Show 'all-at-once')"
    # ------------------------------------------------------------------ each branch fails on its own
    $tn = Get-Check 'cross-tenant' 'target.tenant'
    Assert 'P2 a subscription in another tenant than the Azure CLI sign-in is a FAIL of target.tenant naming both tenants, with az login --tenant as the remedy' ((& $one 'cross-tenant' 'target.tenant' "is in tenant $otherTenant, and Azure CLI is signed in to tenant $($script:P91Tenant)") -and
        $tn.remedy -match "az login --tenant $otherTenant") (Show 'cross-tenant')
    Assert 'P2 a disabled subscription is a FAIL of target.subscription naming its state' (& $one 'disabled' 'target.subscription' 'is Disabled') (Show 'disabled')
    $later = @('foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity')
    $su = @($scenarios['sub-unreadable'].Json.checks | Where-Object { $_.id -in $later -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
    Assert 'P2 a subscription Azure CLI cannot read is a FAIL of target.subscription, and each check that reads in it is NOT-RUN (prerequisite-failed)' ((& $one 'sub-unreadable' 'target.subscription' 'is not readable by admin@contoso\.com \(ERROR: \(AuthorizationFailed\)') -and
        $scenarios['sub-unreadable'].Json -and -not $su.Count) "$(($su | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || $(Show 'sub-unreadable')"
    $lf = $scenarios['list-found']; $lfa = Get-Check 'list-found' 'foundry.account'; $lfd = Get-Check 'list-found' 'foundry.deployments'
    Assert 'P2 without FoundryResourceGroup, a Foundry account the subscription lists is found, and its deployments are read in its own resource group' ($lfa.result -eq 'PASS' -and $lfa.message -eq 'Foundry account ai-p91 in the subscription' -and
        $lfd.result -eq 'PASS' -and (Get-P91Calls $lf.Result 'cognitiveservices account list*').Count -eq 1 -and (Get-P91Calls $lf.Result 'cognitiveservices account deployment list -g rg-ai-p91 -n ai-p91*').Count -eq 1) (Show 'list-found')
    Assert 'P2 without FoundryResourceGroup, a Foundry account the subscription does not list is a FAIL of foundry.account, and its deployments are NOT-RUN' ((& $one 'list-missing' 'foundry.account' 'Foundry account ai-missing was not found in the subscription') -and
        (Get-Check 'list-missing' 'foundry.deployments').reason -eq 'prerequisite-failed') (Show 'list-missing')
    Assert 'P2 a Foundry account with no Claude deployment and no PendingClaudeDeployment is a FAIL of foundry.deployments' (& $one 'no-claude' 'foundry.deployments' 'the Foundry account ai-p91 has no Claude deployment') (Show 'no-claude')
    Assert 'P2 failing admin prerequisites are a FAIL of operator.adminPrereqs naming the failed check (the harness fails the argument canary)' (& $one 'prereq-fail' 'operator.adminPrereqs' 'Azure CLI could not run a simple query') (Show 'prereq-fail')
    Assert 'P2 an AddressPfxPath that is not a file is a FAIL of address.inputs naming the path' (& $one 'pfx-missing' 'address.inputs' "AddressPfxPath '/nonexistent-p92/no-such-certificate\.pfx' is not a file") (Show 'pfx-missing')
    Assert 'P2 a Foundry account list that is not JSON is an inconclusive FAIL of foundry.account, not a crash, and its deployments are NOT-RUN' ((& $one 'list-not-json' 'foundry.account' 'Foundry account ai-p91 could not be read \(az cognitiveservices account list did not return JSON\)') -and
        (Get-Check 'list-not-json' 'foundry.deployments').reason -eq 'prerequisite-failed') (Show 'list-not-json')
    $an = @($scenarios['account-not-json'].Json.checks | Where-Object { $_.id -in @($azureChecks | Select-Object -Skip 1) -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
    Assert 'P2 an az account show that is not JSON is an inconclusive FAIL of target.tenant, not a crash, and every other Azure check is NOT-RUN' ((& $one 'account-not-json' 'target.tenant' 'the signed-in account could not be read \(az account show did not return JSON\)') -and
        $scenarios['account-not-json'].Json -and -not $an.Count) "$(($an | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || $(Show 'account-not-json')"
    $nt = @($scenarios['account-no-tenant'].Json.checks | Where-Object { $_.id -in @($azureChecks | Select-Object -Skip 1) -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
    Assert 'P2 an az account show without a tenantId is an inconclusive FAIL of target.tenant, and every other Azure check is NOT-RUN' ((& $one 'account-no-tenant' 'target.tenant' 'the signed-in account could not be read \(az account show returned no tenantId\)') -and
        $scenarios['account-no-tenant'].Json -and -not $nt.Count) "$(($nt | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || $(Show 'account-no-tenant')"
    # ------------------------------------------------------------------ round 3: the subscription record (item 1)
    function Get-EmptySubscription($Result) { @($Result.Az | Where-Object { $tk = @($_ -split ' '); $i = [array]::IndexOf($tk, '--subscription'); $i -ge 0 -and ($i + 1 -ge $tk.Count -or $tk[$i + 1] -in '', 'null', "''", '""') }) }
    $recordCase = { param([string]$Name, [string]$Message)
        $c = Get-Check $Name 'target.subscription'
        $notRun = @($scenarios[$Name].Json.checks | Where-Object { $_.id -in $later -and ($_.result -ne 'NOT-RUN' -or $_.reason -ne 'prerequisite-failed') })
        $empty = @(Get-EmptySubscription $scenarios[$Name].Result)
        [pscustomobject]@{ Ok = [bool]((& $one $Name 'target.subscription' ('^' + [regex]::Escape($Message) + ' ')) -and $scenarios[$Name].Json -and -not $notRun.Count -and -not $empty.Count)
            Detail = "$($c.result): $($c.message) || $(($notRun | ForEach-Object { "$($_.id)=$($_.result)/$($_.reason)" }) -join ', ') || empty: $($empty -join ' | ')" } }
    $rc = & $recordCase 'sub-no-id' "subscription '$sub' is not readable by admin@contoso.com (az account show returned no subscription id)"
    Assert 'R3 a subscription record without an id is an inconclusive FAIL of target.subscription, each later check is NOT-RUN (prerequisite-failed), and no az call names an empty subscription' $rc.Ok $rc.Detail
    $rc = & $recordCase 'sub-null-id' "subscription '$sub' is not readable by admin@contoso.com (az account show returned no subscription id)"
    Assert 'R3 a subscription record whose id is null is an inconclusive FAIL of target.subscription, each later check is NOT-RUN, and no az call names an empty or null subscription' $rc.Ok $rc.Detail
    $rc = & $recordCase 'sub-no-tenant' "subscription '$sub' is not readable by admin@contoso.com (az account show returned no tenantId)"
    Assert 'R3 a subscription record without a tenantId is an inconclusive FAIL of target.subscription, and each later check is NOT-RUN' $rc.Ok $rc.Detail
    $rc = & $recordCase 'current-no-id' 'the current subscription could not be read (az account show returned no subscription id)'
    Assert 'R3 with SubscriptionId not answered, a current account without an id is an inconclusive FAIL of target.subscription, and each later check is NOT-RUN' $rc.Ok $rc.Detail
    # ------------------------------------------------------------------ round 3: redaction (item 5)
    $rd = $scenarios['redact']; $eg = Get-Check 'redact' 'entra.groupNames'; $fd = Get-Check 'redact' 'foundry.deployments'
    $egProblems = @(Get-P92RedactionProblems "$($eg.message)")
    Assert 'R3 the JSON report redacts every secret shape in an error that a message quotes: each becomes its [redacted] form, and no sentinel appears in stdout or stderr' ($eg.result -eq 'FAIL' -and -not $egProblems.Count -and
        (Test-P92NoSentinel ($rd.Result.Out + $rd.Result.Err))) "$($egProblems -join '; ') || $($eg.message)"
    Assert 'R3 the JSON report redacts a secret in a remedy: a deployment named secret=<value> is listed as secret=[redacted]' ($fd.result -eq 'FAIL' -and "$($fd.remedy)" -match 'secret=\[redacted\]' -and
        @($fd.problems | Where-Object { "$($_.remedy)" -match 'secret=\[redacted\]' }).Count -eq 1 -and "$($fd.remedy)" -notmatch 'p92RemedySentinel') "$($fd.remedy)"
    $rt = $scenarios['redact-text'].Result
    $rtLine = @($rt.Out -split "`n" | Where-Object { $_ -match '\[FAIL\] entra\.groupNames: ' }) -join "`n"
    $rtProblems = @(Get-P92RedactionProblems $rtLine)
    Assert 'R3 the text report redacts the same: each shape in its [redacted] form, the remedy too, and no sentinel appears in stdout or stderr' ($rtLine -and -not $rtProblems.Count -and $rt.Out -match '\[FAIL\] foundry\.deployments: .*secret=\[redacted\]' -and
        (Test-P92NoSentinel ($rt.Out + $rt.Err))) "$($rtProblems -join '; ') || $rtLine"
    # ------------------------------------------------------------------ round 3: a check no branch evaluates (item 9)
    $pe = Get-P91Result $results $probeRun
    $pj = $null; try { $pj = $pe.Out | ConvertFrom-Json -ErrorAction Stop } catch { }
    $unevaluated = @(if ($pj) { $pj.checks | Where-Object { $_.reason -eq 'not-evaluated' } })
    $wrongText = @($unevaluated | Where-Object { $_.result -ne 'NOT-RUN' -or $_.message -cne 'the preflight did not evaluate this check, which is a defect of the preflight' -or
            $_.remedy -cne 'Run the preflight from the latest checkout; if the check is still not evaluated, report it with this output.' })
    Assert 'R3 a check that no branch evaluates is NOT-RUN (not-evaluated), says the preflight did not evaluate it, which is a defect of the preflight, gives the remedy to run the latest checkout or report it, and fails the preflight' (
        $pj -and $pj.result -eq 'FAIL' -and $unevaluated.Count -eq 8 -and -not $wrongText.Count) "$(@($unevaluated | ForEach-Object { "$($_.id): $($_.message) / $($_.remedy)" } | Select-Object -First 2) -join ' || ') || $(Get-P91Tail $pe)"
    # Fail closed by construction: every check starts NOT-RUN (not-evaluated) and passes only through
    # Set-ClaudePreflightPass with a message, so a branch that sets nothing cannot read as a PASS.
    $loose = @(foreach ($s in $scenarios.GetEnumerator()) { $j = $s.Value.Json; if ($j) { foreach ($c in @($j.checks)) { if ($c.reason -eq 'not-evaluated' -or ($c.result -eq 'PASS' -and -not "$($c.message)".Trim())) { "$($s.Key): $($c.id) $($c.result)/$($c.reason)" } } } })
    Assert 'P2 fail closed: in every scenario each PASS carries its message, and no check is left NOT-RUN not-evaluated (ADR-0047 decision 5)' (-not $loose.Count -and @($scenarios.Values | Where-Object { $_.Json }).Count -ge 20) ($loose -join ' || ')
    $tx = $scenarios['text'].Result
    $lines = @($tx.Out -split "`n" | Where-Object { $_ -match '^\s*\[(PASS|FAIL|NOT-RUN)\] ([A-Za-z.]+): ' })
    $lineIds = @($lines | ForEach-Object { [regex]::Match($_, '\] ([A-Za-z.]+):').Groups[1].Value } | Select-Object -Unique)
    Assert 'P2 the text report has one line per check, [RESULT] id: message, and each FAIL line ends with its remedy' ($tx.ExitCode -ne 0 -and ($lineIds -join ',') -eq ($ids -join ',') -and
        @($lines | Where-Object { $_ -match '\[FAIL\] apim\.existingIdentity: .*Remedy: .*System assigned' }).Count -eq 1 -and $tx.Out -match '(?m)^\s*Preflight: 14 checks; \d+ PASS, \d+ FAIL, \d+ NOT-RUN\.') (Get-P91Tail $tx)

    # ------------------------------------------------------------------ the run reads as the preflight reads
    $ri = Get-P91Result $results $runIdentity
    Assert 'P2 the run reads a reused instance through the preflight''s reader: without a system-assigned identity it warns with the apim.existingIdentity message and remedy' (
        $ni -and $ni.message -and $ri.Out.Contains("[WARN] $($ni.message). $($ni.remedy)")) "preflight: $($ni.message) | run: $(Get-P91Tail $ri)"
    $rl = Get-P91Result $results $runList
    Assert 'P2 the run''s reuse menu reads through the verdict reader: a failed az apim list warns that none is offered, naming the error, and the run creates its own instance' (
        $rl.ExitCode -eq 0 -and $rl.Out -match '\[WARN\] The API Management instances in this subscription could not be listed \(.*AuthorizationFailed.*\), so none is offered for reuse' -and
        (Get-P91Calls $rl 'deployment group create*').Count -eq 1) (Get-P91Tail $rl)

    # ------------------------------------------------------------------ read-only
    $writes = @(foreach ($s in $scenarios.Values) { @($s.Result.Az | Where-Object { $_ -match '(^| )(create|update|delete|set|add|remove|login|purge|assign|start|stop)( |$)' }) })
    $files = @(foreach ($s in $scenarios.Values) { @(Get-ChildItem -LiteralPath $s.Scenario.State -Force -ErrorAction SilentlyContinue | ForEach-Object Name) })
    $scripts = @(foreach ($s in $scenarios.Values) { @($s.Result.Scripts) })
    $unexpected = @(foreach ($s in $scenarios.Values) { @($s.Result.Unexpected) })
    Assert 'P2 read-only: no run made a create, update, set, delete, assign or login call, ran a child script, or wrote a checkpoint, lock or temporary file' (-not $writes.Count -and -not $files.Count -and -not $scripts.Count -and
        @($scenarios.Values | Where-Object { $_.Result.Az.Count }).Count -ge 10) "writes: $(($writes | Select-Object -Unique -First 5) -join ' | '); files: $($files -join ', '); scripts: $($scripts -join ', ')"
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @($scenarios.Values | Where-Object { $_.Result.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
