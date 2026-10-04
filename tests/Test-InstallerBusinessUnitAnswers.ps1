# P92 acceptance test 6 (docs/adr/0047-lean-installer-phase-0.md): business units and teams from the
# answers file are applied through scripts/Set-ClaudeBusinessUnit.ps1, units before teams, once each:
# the install checkpoint records each unit applied, and a resume verifies them in bu-registry instead
# of applying them again. When the gateway enforces a dollar budget afterwards, the installer prints
# the command that reconciles USD state. Each run is a child PowerShell over the stubs of
# tests/InstallerCheckpointStubs.ps1 and tests/InstallerBusinessUnitStub.ps1; nothing reaches Azure.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'InstallerCheckpointHarness.ps1')
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Installer business units from answers (PowerShell installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$scratch = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('p92-units-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$sub = $script:P91Subscription
$common = @("-SubscriptionId '$sub'", "-FoundryAccount 'ai-p91'", "-FoundryResourceGroup 'rg-ai-p91'", "-EntitlementStore 'named-value'", "-AuthMode 'interactive'",
    "-DesktopSignInKind 'helper-script'", "-AddressMode 'azure'", '-SkipFinOpsOffer', "-ResourceGroup 'rg-p91'", "-Location 'eastus2'", "-NamePrefix 'p91gw'",
    "-PublisherEmail 'ops@contoso.com'", "-Sku 'BasicV2'", "-StandardModels 'claude-sonnet-5'", "-PremiumModels 'claude-opus-5','claude-sonnet-5'", '-TpmStandard 20000',
    '-QuotaStandard 500000', '-TpmPremium 80000', '-QuotaPremium 5000000', '-QuotaOrg 100000000', '-CallsPerMinute 120', '-Yes')
# Answer order puts a team first: the installer orders units before teams itself.
$tree = @(
    [ordered]@{ id = 'finance-emea'; group = 'claude-team-finance-emea'; parent = 'finance'; monthlyUsdBudget = 1000; mode = 'Notify' }
    [ordered]@{ id = 'finance'; group = 'claude-bu-finance'; monthlyUsdBudget = 5000; mode = 'Strict' }
    [ordered]@{ id = 'platform'; group = 'claude-team-platform'; parent = 'engineering'; monthlyUsdBudget = 2000; mode = 'Strict' }
    [ordered]@{ id = 'engineering'; group = 'claude-bu-engineering'; monthlyUsdBudget = 8000; mode = 'Allowance'; percent = 20 }
)
$notify = @($tree | ForEach-Object { $u = [ordered]@{}; foreach ($k in $_.Keys) { $u[$k] = $_[$k] }; $u.mode = 'Notify'; $u.Remove('percent'); $u })
function New-Units([string]$Name, $Units, [scriptblock]$World) {
    $w = New-P91World
    if ($World) { & $World $w }
    $s = New-P91Scenario -Name $Name -Scratch $scratch -Template $template -World $w
    $file = Join-Path $s.Dir 'answers.json'
    Write-P91Text $file ([ordered]@{ schemaVersion = 1; BusinessUnits = @($Units) } | ConvertTo-Json -Depth 8)
    return [pscustomobject]@{ Scenario = $s; Answers = $file }
}
function Get-Units($Result) { @($Result.Scripts | Where-Object { $_ -like 'bu *' }) }
function Get-Ids($Result) { @(Get-Units $Result | ForEach-Object { ($_ -split ' ')[1] }) }
$reconcile = '(?m)Sync-ClaudeUsdBudgets\.ps1 -ResourceGroup rg-p91 -ApimName apim-p91gw'

try {
    $template = New-P91Template $scratch
    $apply = New-Units 'apply' $tree
    $quiet = New-Units 'notify' $notify
    $partial = New-Units 'partial' $tree { param($w) $w.inject.bu = 'refuse:platform' }
    $later = New-Units 'later' $tree { param($w) $w.inject.verify = 'fail' }
    # bu-registry cannot be read (not absent): the step stops before any unit is written or skipped.
    $denied = 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.ApiManagement/service/namedValues/read.'
    $unreadable = New-Units 'registry-unreadable' $tree { param($w) $w.inject.readErrors = @([ordered]@{ match = 'apim nv show * --named-value-id bu-registry *'; text = $denied }) }
    # Round 3, the Security seat's item 4: the installer's business-unit prompt (an attended run over a reused
    # gateway, its questions answered on standard input as in tests/Test-InstallerCheckpoint.ps1 S3) finds a
    # unit's group by the name rule of ADR-0046 decision 11. az ad group show --group falls back to a single
    # prefix match, so a lone claude-bu-platform-admins was taken for claude-bu-platform.
    $prompted = @("-SubscriptionId '$sub'", "-FoundryAccount 'ai-p91'", "-FoundryResourceGroup 'rg-ai-p91'", "-EntitlementStore 'named-value'", "-AuthMode 'interactive'",
        "-DesktopSignInKind 'helper-script'", "-AddressMode 'azure'", '-SkipFinOpsOffer', "-ResourceGroup 'rg-p91'", "-ExistingApimName 'apim-p91reuse'", "-StandardModels 'claude-sonnet-5'",
        "-PremiumModels 'claude-opus-5','claude-sonnet-5'", '-TpmStandard 20000', '-QuotaStandard 500000', '-TpmPremium 80000', '-QuotaPremium 5000000', '-QuotaOrg 100000000', '-CallsPerMinute 120')
    $adminsId = '00000000-0000-4000-8000-0000000003a1'
    $w = New-P91World -ReusedGateway; $w.groups[$adminsId] = 'claude-bu-platform-admins'; $w.inject.bu = 'refuse:zzz'
    $prefixGroup = New-P91Scenario -Name 'prompt-prefix' -Scratch $scratch -Template $template -World $w
    $w = New-P91World -ReusedGateway
    $w.inject['groupLists'] = [ordered]@{ 'claude-bu-platform' = @([ordered]@{ id = '00000000-0000-4000-8000-0000000003b1'; displayName = 'claude-bu-platform' }, [ordered]@{ id = '00000000-0000-4000-8000-0000000003b2'; displayName = 'CLAUDE-BU-PLATFORM' }) }
    $twoGroups = New-P91Scenario -Name 'prompt-two-groups' -Scratch $scratch -Template $template -World $w
    # Round 4, the Coder seat's item 5: a group name the schema refuses (a single quote, a comma or a colon)
    # typed at the prompt is refused there, before any Azure CLI call reads Graph for it.
    $quoteGroup = New-P91Scenario -Name 'prompt-quote' -Scratch $scratch -Template $template -World (New-P91World -ReusedGateway)
    # Round 6, the lead's check of 70f07c0: the prompt applies the same schema rule to cmd.exe metacharacters, which
    # the Azure CLI's az.cmd shim on Windows would re-read (ADR-0047 decision 13, round 5 Security).
    $metaName = 'claude-bu&echo.P92_PROMPT_MARKER&rem'
    $metaGroup = New-P91Scenario -Name 'prompt-metachar' -Scratch $scratch -Template $template -World (New-P91World -ReusedGateway)
    $wave1 = @(
        ($runApply = New-P91Run $apply.Scenario -Arguments ($common + "-AnswersPath '$($apply.Answers)'"))
        ($runNotify = New-P91Run $quiet.Scenario -Arguments ($common + "-AnswersPath '$($quiet.Answers)'"))
        ($runPartial = New-P91Run $partial.Scenario -Arguments ($common + "-AnswersPath '$($partial.Answers)'"))
        ($runLater = New-P91Run $later.Scenario -Arguments ($common + "-AnswersPath '$($later.Answers)'"))
        ($runUnreadable = New-P91Run $unreadable.Scenario -Arguments ($common + "-AnswersPath '$($unreadable.Answers)'"))
        # platform, then zzz, which the stub refuses, so that the checkpoint keeps platform's receipt.
        ($runPrefix = New-P91Run $prefixGroup -Arguments $prompted -Attended -Answers @('', '', '', '', '', 'y', 'platform', '', '', 'y', 'zzz', '', '', '', ''))
        ($runTwoGroups = New-P91Run $twoGroups -Arguments $prompted -Attended -Answers @('', '', '', '', '', 'y', 'platform', '', 'n', '', '', '', ''))
        ($runQuote = New-P91Run $quoteGroup -Arguments $prompted -Attended -Answers @('', '', '', '', '', 'y', 'platform', "O'Brien", 'n', '', '', '', ''))
        ($runMeta = New-P91Run $metaGroup -Arguments $prompted -Attended -Answers @('', '', '', '', '', 'y', 'platform', $metaName, 'n', '', '', '', ''))
    )
    $r1 = Invoke-P91Runs $wave1
    $a = Get-P91Result $r1 $runApply
    $ids = @(Get-Ids $a)
    $firstTeam = [Math]::Min([array]::IndexOf($ids, 'finance-emea'), [array]::IndexOf($ids, 'platform'))
    $lastUnit = [Math]::Max([array]::IndexOf($ids, 'finance'), [array]::IndexOf($ids, 'engineering'))
    Assert 'P6 two units and two teams are applied through Set-ClaudeBusinessUnit.ps1, both units before either team, each once' ($a.ExitCode -eq 0 -and $ids.Count -eq 4 -and
        @($ids | Select-Object -Unique).Count -eq 4 -and $lastUnit -ge 0 -and $firstTeam -gt $lastUnit) "order: $($ids -join ', ') || $(Get-P91Tail $a)"
    $lines = @(Get-Units $a)
    $line = { param([string]$Id) @($lines | Where-Object { ($_ -split ' ')[1] -eq $Id })[0] }
    Assert 'P6 each call passes the group, the parent of a team, the mode, the allowance percentage and the dollar budget' ((& $line 'platform') -match 'claude-team-platform parent=engineering mode=Strict percent= usd=2000' -and
        (& $line 'engineering') -match 'claude-bu-engineering parent= mode=Allowance percent=20 usd=8000' -and (& $line 'finance-emea') -match 'parent=finance mode=Notify') ($lines -join ' | ')
    $groupsMade = @(Get-P91Calls $a 'ad group create --display-name claude-bu-*') + @(Get-P91Calls $a 'ad group create --display-name claude-team-*')
    Assert 'P6 each unit''s group is found or created by the P91 group rule before its unit is written, and the call skips Set-ClaudeBusinessUnit''s own group read' ($groupsMade.Count -eq 4 -and
        @($lines | Where-Object { $_ -match 'skipGroupCheck=True' }).Count -eq 4) ($groupsMade -join ' | ')
    Assert 'P6 with dollar budgets enforced (Strict and Allowance units), the run prints the USD reconcile command for this gateway' ($a.Out -match $reconcile) (Get-P91Tail $a)
    $n = Get-P91Result $r1 $runNotify
    Assert 'P6 with every unit on Notify no dollar budget is enforced, and the reconcile command is not printed' ($n.ExitCode -eq 0 -and (Get-Ids $n).Count -eq 4 -and $n.Out -notmatch 'Sync-ClaudeUsdBudgets') (Get-P91Tail $n)

    $p1 = Get-P91Result $r1 $runPartial
    $resume = New-P91Scenario -Name 'partial-resume' -Scratch $scratch -From $partial.Scenario
    Edit-P91World $resume { param($w) $w.inject.bu = '' }
    # The receipts match, and bu-registry has lost one of their units: that unit is written again.
    $lost = New-P91Scenario -Name 'partial-registry-lost' -Scratch $scratch -From $partial.Scenario
    Edit-P91World $lost { param($w) $w.inject.bu = ''; $nv = $w.apims.'apim-p91gw'.namedValues
        $nv.'bu-registry' = ',' + ((@($nv.'bu-registry'.Trim(',') -split ',' | Where-Object { $_ -and $_ -notlike 'finance=*' })) -join ',') + ',' }
    $l1 = Get-P91Result $r1 $runLater
    $verified = New-P91Scenario -Name 'later-resume' -Scratch $scratch -From $later.Scenario
    Edit-P91World $verified { param($w) $w.inject.verify = '' }
    $cp = Get-P91CheckpointFile $partial.Scenario
    $receipt = if ($cp) { @(([IO.File]::ReadAllText($cp.FullName) | ConvertFrom-Json).steps | Where-Object { $_.id -eq 'business-units' })[0].receipt } else { $null }
    Assert 'setup: a refused unit stops the run, and the checkpoint keeps a receipt for each unit already applied, with its group id' ($p1.ExitCode -ne 0 -and $receipt -and
        ((@($receipt.units | ForEach-Object id) | Sort-Object) -join ',') -eq 'engineering,finance,finance-emea' -and -not @($receipt.units | Where-Object { $_.groupId -notmatch '^[0-9a-f-]{36}$' }).Count) "$(Get-P91Tail $p1) || $($receipt | ConvertTo-Json -Compress -Depth 5)"
    $wave2 = @(
        ($runResume = New-P91Run $resume -Arguments ($common + "-AnswersPath '$($partial.Answers)'"))
        ($runVerified = New-P91Run $verified -Arguments ($common + "-AnswersPath '$($later.Answers)'"))
        ($runLost = New-P91Run $lost -Arguments ($common + "-AnswersPath '$($partial.Answers)'"))
    )
    $r2 = Invoke-P91Runs $wave2
    $p2 = Get-P91Result $r2 $runResume
    Assert 'P6 a resume after a unit failed applies only the units its receipts do not show in bu-registry: no duplicate call' ($p2.ExitCode -eq 0 -and ((Get-Ids $p2) -join ',') -eq 'platform') "$((Get-Ids $p2) -join ', ') || $(Get-P91Tail $p2)"
    $v2 = Get-P91Result $r2 $runVerified
    Assert 'P6 a resume after the business-unit step completed verifies it live and makes no Set-ClaudeBusinessUnit call' ($l1.ExitCode -eq 0 -and $v2.ExitCode -eq 0 -and -not (Get-Ids $v2).Count -and
        $v2.Out -match 'Business units: verified live, skipped') "$(Get-P91Tail $v2)"
    $lr = Get-P91Result $r2 $runLost
    Assert 'P6 a rerun writes a unit again when its receipt matches but bu-registry lacks it, and still skips the units bu-registry shows' ($lr.ExitCode -eq 0 -and ((Get-Ids $lr) -join ',') -eq 'finance,platform') "$((Get-Ids $lr) -join ', ') || $(Get-P91Tail $lr)"
    $ur = Get-P91Result $r1 $runUnreadable
    $urLines = @(Get-P91ErrLines $ur)
    Assert 'P6 an unreadable bu-registry stops the step on one line naming it, with the resume command, and no Set-ClaudeBusinessUnit call is made' ($ur.ExitCode -ne 0 -and -not (Get-Ids $ur).Count -and
        @($urLines | Where-Object { $_ -match 'bu-registry on apim-p91gw could not be read \(ERROR: \(AuthorizationFailed\)' -and $_ -match 'Nothing was changed' -and $_ -match 'Resume: ' }).Count -eq 1) "$($urLines -join ' | ') || $(Get-P91Tail $ur)"
    # ------------------------------------------------------------------ round 3: the prompt's group (item 4)
    $px = Get-P91Result $r1 $runPrefix
    $pxCp = Get-P91CheckpointFile $prefixGroup
    $pxUnits = if ($pxCp) { @(@(([IO.File]::ReadAllText($pxCp.FullName) | ConvertFrom-Json).steps | Where-Object { $_.id -eq 'business-units' })[0].receipt.units) } else { @() }
    $pxUnit = @($pxUnits | Where-Object { $_.id -eq 'platform' })[0]
    $made = @((([IO.File]::ReadAllText($prefixGroup.World) | ConvertFrom-Json).groups.PSObject.Properties | Where-Object { [string]$_.Value -ceq 'claude-bu-platform' }) | ForEach-Object { $_.Name })
    Assert 'R3 when only claude-bu-platform-admins exists, the business-unit prompt creates claude-bu-platform, records the new group''s id, and never takes the prefix group' (
        @(Get-P91Calls $px 'ad group create --display-name claude-bu-platform *').Count -eq 1 -and $made.Count -eq 1 -and $pxUnit -and $pxUnit.groupId -eq $made[0] -and $pxUnit.groupOrigin -eq 'created' -and
        $pxUnit.groupId -ne $adminsId -and -not @(Get-P91Calls $px 'ad group show --group claude-bu-platform*').Count) "unit: $($pxUnit | ConvertTo-Json -Compress) || made: $($made -join ',') || $(Get-P91Tail $px)"
    Assert 'R3 the prompt then writes the unit through Set-ClaudeBusinessUnit.ps1 -SkipGroupCheck, as the answers path does' (@($px.Scripts | Where-Object { $_ -like 'bu platform claude-bu-platform *skipGroupCheck=True' }).Count -eq 1) (($px.Scripts | Where-Object { $_ -like 'bu *' }) -join ' | ')
    $tg = Get-P91Result $r1 $runTwoGroups
    Assert 'R3 when two groups have the name''s length, the prompt refuses that unit with a remedy: no group is created, no unit is written, and the run goes on' ($tg.ExitCode -eq 0 -and
        $tg.Out -match "Entra group 'claude-bu-platform' could not be looked up by name" -and $tg.Out -match 'Rename or remove one of those groups' -and
        -not @(Get-P91Calls $tg 'ad group create --display-name claude-bu-platform *').Count -and -not @($tg.Scripts | Where-Object { $_ -like 'bu platform *' }).Count) (Get-P91Tail $tg)
    $installerText = [IO.File]::ReadAllText((Join-Path $script:P91Root 'Install-ClaudeGateway.ps1'))
    $answersPath = [regex]::Match([IO.File]::ReadAllText((Join-Path $script:P91Root 'scripts/ClaudeInstallSteps.ps1')), '(?s)function Invoke-ClaudeInstallBusinessUnits \{.*?\r?\n\}').Value
    Assert 'R3 both business-unit paths, the prompt and the answers file, find or create a unit''s group through one function, Resolve-ClaudeInstallUnitGroup' ($installerText -match 'Resolve-ClaudeInstallUnitGroup \$buGroup' -and
        $installerText -notmatch 'az ad group show --group \$buGroup' -and $answersPath -match 'Resolve-ClaudeInstallUnitGroup \$group')
    # ------------------------------------------------------------------ round 4: a group name the schema refuses (item 5)
    $tq = Get-P91Result $r1 $runQuote
    # The message and remedy are the schema's own (Install-ClaudeGateway.ps1 reads them at the prompt), so 70f07c0's
    # added metacharacters change their wording here too; the message still has to name the single quote.
    $groupRule = ([IO.File]::ReadAllText((Join-Path $script:P91Root 'schemas/claude-gateway.answers.schema.json')) | ConvertFrom-Json).'$defs'.BusinessUnit.properties.group
    $quoteMessage = [string]$groupRule.'x-patternMessage'; $quoteRemedy = [string]$groupRule.'x-remedy'
    Assert 'R4 a group name with a single quote at the prompt is refused there with the schema''s message and remedy, before any Azure CLI call names it; no unit is written and the run goes on' ($tq.ExitCode -eq 0 -and
        $quoteMessage -match 'single quote' -and $quoteRemedy -and $tq.Out.Contains("Entra group 'O'Brien' $quoteMessage, so business unit platform is not written.") -and
        $tq.Out.Contains($quoteRemedy) -and -not @($tq.Az | Where-Object { $_.Contains("O'Brien") }).Count -and -not @($tq.Scripts | Where-Object { $_ -like 'bu platform *' }).Count) "message: $quoteMessage || $(Get-P91Tail $tq)"
    $tm = Get-P91Result $r1 $runMeta
    Assert 'R6 a group name with cmd.exe metacharacters at the prompt is refused there with the schema''s message and remedy, before any Azure CLI call names it; no unit is written and the run goes on' ($tm.ExitCode -eq 0 -and
        $quoteMessage -match 'cmd\.exe' -and $tm.Out.Contains("Entra group '$metaName' $quoteMessage, so business unit platform is not written.") -and $tm.Out.Contains($quoteRemedy) -and
        -not @($tm.Az | Where-Object { $_.Contains('P92_PROMPT_MARKER') }).Count -and -not @($tm.Scripts | Where-Object { $_ -like 'bu platform *' }).Count) "message: $quoteMessage || $(Get-P91Tail $tm)"
    $unexpected = @(foreach ($r in @($r1.Values) + @($r2.Values)) { @($r.Unexpected) })
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @(@($r1.Values) + @($r2.Values) | Where-Object { $_.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
