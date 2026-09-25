# Scripts ask for what they were not given, and refuse with the options when they cannot ask.
# Offline: az, the telemetry lookup and the recorded gateway are stubbed.
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] unexpected error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) {
    try { & $Block *> $null; return $null } catch { return $_.Exception.Message }
}
function New-Reader([string[]]$Answers) {
    $queue = New-Object System.Collections.Queue
    foreach ($a in $Answers) { $queue.Enqueue($a) }
    return { param($Prompt) if ($queue.Count) { $queue.Dequeue() } else { throw 'the reader was asked more times than expected' } }.GetNewClosure()
}
$never = { param($Prompt) throw 'asked without a console' }
# A value-returning call that throws is a failed assertion, not a crash: the business-unit
# harness runs this suite in its own process, where an escaping exception would stop the harness.
function Invoke-Choice([scriptblock]$Block) { try { & $Block 6> $null } catch { "<threw: $($_.Exception.Message)>" } }

. (Join-Path $root 'scripts/ClaudeChoice.ps1')

Write-Host ''
Write-Host 'Choosing a value' -ForegroundColor Cyan
$a = New-ClaudeChoiceOption -Value 'id-a' -Label 'alpha'
$b = New-ClaudeChoiceOption -Value 'id-b' -Label 'beta' -Recommended -Reason 'the deployment points at it'
$c = New-ClaudeChoiceOption -Value 'id-c' -Label 'gamma'
$common = @{ Parameter = 'Thing'; Question = 'Which thing?'; WhereToFind = @('look here') }

$r = Invoke-Choice { Select-ClaudeChoice @common -Options @($a, $b, $c) -Interactive $true -Reader (New-Reader @('')) }
Assert 'Enter takes the recommended option' ($r -eq 'id-b') "got $r"
$r = Invoke-Choice { Select-ClaudeChoice @common -Options @($a, $b, $c) -Interactive $true -Reader (New-Reader @('3')) }
Assert 'a number takes that option' ($r -eq 'id-c') "got $r"
$r = Invoke-Choice { Select-ClaudeChoice @common -Options @($a, $b, $c) -Interactive $true -Reader (New-Reader @('9', 'abc', '1')) }
Assert 'an invalid answer asks again' ($r -eq 'id-a') "got $r"
$r = Invoke-Choice { Select-ClaudeChoice @common -Options @($a, $c) -Interactive $true -Reader (New-Reader @('', '1')) }
Assert 'Enter does not choose when nothing is recommended' ($r -eq 'id-a') "got $r"
$m = Get-Thrown { Select-ClaudeChoice @common -Options @($a, $b) -Interactive $true -Reader (New-Reader @('q')) }
Assert 'q stops and says what to pass' ($m -match 'Stopped' -and $m -match 'Pass -Thing' -and $m -match 'look here') $m

$r = Invoke-Choice { Select-ClaudeChoice @common -Options @($a, $b, $c) -Interactive $false -Reader $never -AcceptRecommendedWithoutConsole }
Assert 'without a console a certain recommendation is taken' ($r -eq 'id-b') "got $r"
$m = Get-Thrown { Select-ClaudeChoice @common -Options @($a, $b, $c) -Interactive $false -Reader $never }
Assert 'but an uncertain one is not' ($m -match '3 candidate\(s\) for -Thing: alpha, beta, gamma' -and $m -match 'Pass -Thing') $m
$m = Get-Thrown { Select-ClaudeChoice @common -Options @($a, $c) -Interactive $false -Reader $never -AcceptRecommendedWithoutConsole -AmbiguousMessage 'Pass -Thing to say which.' }
Assert 'several options without a console refuse, naming them' ($m -match 'alpha, gamma' -and $m -match 'look here') $m
Assert 'and the parameter once' (([regex]::Matches([string]$m, 'Pass -Thing')).Count -eq 1) $m
$m = Get-Thrown { Select-ClaudeChoice @common -Options @() -Interactive $true -Reader $never -NoneMessage 'Nothing here.' }
Assert 'no options refuse even in a console' ($m -match '^Nothing here\. Pass -Thing\.' -and $m -match 'look here') $m

$saved = $env:CLAUDE_NONINTERACTIVE
$env:CLAUDE_NONINTERACTIVE = '1'
Assert 'CLAUDE_NONINTERACTIVE=1 means no console' (-not (Test-ClaudeInteractive))
$env:CLAUDE_NONINTERACTIVE = $saved

Write-Host ''
Write-Host 'Choosing the workspace and the gateway' -ForegroundColor Cyan
$scratch = Join-Path ([IO.Path]::GetTempPath()) "claude-choice-$PID-$(Get-Random)"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $linked = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.OperationalInsights/workspaces/log-gateway'
    $other1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.OperationalInsights/workspaces/log-other'
    $other2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.OperationalInsights/workspaces/workspace-default'
    $telemetryOk = Join-Path $scratch 'telemetry-ok.ps1'
    Set-Content $telemetryOk "param(`$ResourceGroup, `$ApimName, `$Interactive) [pscustomobject]@{ AppInsights = 'appi-gateway'; Workspace = 'log-gateway'; WorkspaceResourceId = '$linked' }"
    $telemetryBroken = Join-Path $scratch 'telemetry-broken.ps1'
    Set-Content $telemetryBroken "param(`$ResourceGroup, `$ApimName, `$Interactive) throw 'no diagnostic names a logger'"
    Set-Content (Join-Path $scratch 'Get-ClaudeGatewayTarget.ps1') 'param($Field) return [string]$env:CLAUDE_TEST_RECORDED_APIM'

    $script:Workspaces = @($other1, $linked, $other2)
    $script:Apims = @('apim-one', 'apim-two')
    function az {
        $line = $args -join ' '
        if ($line -like 'monitor log-analytics workspace list*') { return ($script:Workspaces -join "`n") }
        if ($line -like 'apim list -g*') { return ($script:Apims -join "`n") }
        throw "unexpected az $line"
    }

    $r = Invoke-Choice { Select-ClaudeWorkspace -ResourceGroup rg-app -TelemetryScript $telemetryOk -Interactive $false -Reader $never }
    Assert 'the linked workspace is taken without a console' ($r -eq $linked) "got $r"
    $r = Invoke-Choice { Select-ClaudeWorkspace -ResourceGroup rg-app -TelemetryScript $telemetryOk -Interactive $true -Reader (New-Reader @('')) }
    Assert 'in a console Enter takes the linked workspace' ($r -eq $linked) "got $r"
    $r = Invoke-Choice { Select-ClaudeWorkspace -ResourceGroup rg-app -TelemetryScript $telemetryOk -Interactive $true -Reader (New-Reader @('3')) }
    Assert 'and the others are offered after it' ($r -eq $other2) "got $r"
    $shown = try { Select-ClaudeWorkspace -ResourceGroup rg-app -TelemetryScript $telemetryOk -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
    Assert 'it says where the recommendation comes from' ($shown -match "linked to the gateway's Application Insights appi-gateway") $shown
    Assert 'and where to look it up' ($shown -match 'Get-ClaudeTelemetry\.ps1 prints it as Workspace' -and $shown -match 'Overview > Workspace') $shown
    $m = Get-Thrown { Select-ClaudeWorkspace -ResourceGroup rg-app -TelemetryScript $telemetryBroken -Interactive $false -Reader $never -AmbiguousMessage 'Pass -WorkspaceName to say which.' }
    Assert 'with no link, several workspaces refuse without a console' ($m -match 'log-other' -and $m -match 'workspace-default' -and $m -match 'Pass -WorkspaceName') $m
    $script:Workspaces = @($other1)
    $r = Invoke-Choice { Select-ClaudeWorkspace -ResourceGroup rg-app -TelemetryScript $telemetryBroken -Interactive $false -Reader $never }
    Assert 'with no link, the only workspace in the group is taken' ($r -eq $other1) "got $r"
    $localOnly = $other1.Replace('/rg-app/', '/rg-local/')
    $script:Workspaces = @($localOnly)
    $r = Invoke-Choice { Select-ClaudeWorkspace -ResourceGroup rg-local -TelemetryScript $telemetryOk -LocalOnly -Interactive $false -Reader $never }
    Assert 'a local-only backup does not choose a linked workspace in another group' ($r -eq $localOnly) "got $r"

    $env:CLAUDE_TEST_RECORDED_APIM = 'apim-two'
    $r = Invoke-Choice { Select-ClaudeGateway -ResourceGroup rg-app -ScriptRoot $scratch -Interactive $false -Reader $never }
    Assert 'the recorded gateway is taken without a console' ($r -eq 'apim-two') "got $r"
    $r = Invoke-Choice { Select-ClaudeGateway -ResourceGroup rg-app -ScriptRoot $scratch -Interactive $true -Reader $never }
    Assert 'and is not asked for in a console either' ($r -eq 'apim-two') "got $r"
    $env:CLAUDE_TEST_RECORDED_APIM = 'apim-gone'
    $r = Invoke-Choice { Select-ClaudeGateway -ResourceGroup rg-app -ScriptRoot $scratch -Interactive $true -Reader (New-Reader @('1')) }
    Assert 'a recorded gateway that is not there is asked for' ($r -eq 'apim-one') "got $r"
    $env:CLAUDE_TEST_RECORDED_APIM = ''
    $m = Get-Thrown { Select-ClaudeGateway -ResourceGroup rg-app -ScriptRoot $scratch -Interactive $false -Reader $never }
    Assert 'two unrecorded gateways refuse without a console' ($m -match 'apim-one, apim-two' -and $m -match 'Pass -ApimName') $m
    $r = Invoke-Choice { Select-ClaudeGateway -ResourceGroup rg-app -ScriptRoot $scratch -Interactive $true -Reader (New-Reader @('2')) }
    Assert 'and are offered in a console' ($r -eq 'apim-two') "got $r"
    $script:Apims = @('apim-one')
    $r = Invoke-Choice { Select-ClaudeGateway -ResourceGroup rg-app -ScriptRoot $scratch -Interactive $false -Reader $never }
    Assert 'the only gateway in the group is taken' ($r -eq 'apim-one') "got $r"
}
finally {
    Remove-Item Env:CLAUDE_TEST_RECORDED_APIM -ErrorAction SilentlyContinue
    Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Choosing the Foundry account, Turnstile group and backup' -ForegroundColor Cyan
$script:Accounts = @(
    [pscustomobject]@{ name = 'ai-other'; kind = 'AIServices'; location = 'region-a'; properties = @{ endpoint = 'https://other-endpoint.services.ai.azure.com/' } }
    [pscustomobject]@{ name = 'ai-linked'; kind = 'AIServices'; location = 'region-b'; properties = @{ endpoint = 'https://backend-endpoint.services.ai.azure.com/' } }
)
$script:Backend = 'https://backend-endpoint.services.ai.azure.com/anthropic'
$script:Apps = @(
    [pscustomobject]@{ name = 'api-a'; resourceGroup = 'rg-turnstile-a' }
    [pscustomobject]@{ name = 'api-b'; resourceGroup = 'rg-turnstile-b' }
)
function az {
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'cognitiveservices account list*') { return (ConvertTo-Json -InputObject @($script:Accounts) -Depth 5) }
    if ($line -like 'apim api show*') { return $script:Backend }
    if ($line -like 'webapp list*') { return (ConvertTo-Json -InputObject @($script:Apps)) }
    throw "unexpected az $line"
}
$r = Invoke-Choice { Select-ClaudeFoundryAccount -ResourceGroup rg-app -ApimName apim-one -Interactive $true -Reader (New-Reader @('')) }
Assert 'Foundry Enter takes the account whose endpoint the backend uses' ($r -eq 'ai-linked') "got $r"
$r = Invoke-Choice { Select-ClaudeFoundryAccount -ResourceGroup rg-app -ApimName apim-one -Interactive $true -Reader (New-Reader @('1')) }
Assert 'Foundry number can choose the other account' ($r -eq 'ai-other') "got $r"
$r = Invoke-Choice { Select-ClaudeFoundryAccount -ResourceGroup rg-app -ApimName apim-one -Interactive $false -Reader $never }
Assert 'the backend is a certain Foundry recommendation without a console' ($r -eq 'ai-linked') "got $r"
$shown = try { Select-ClaudeFoundryAccount -ResourceGroup rg-app -ApimName apim-one -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
Assert 'Foundry options name their source and lookup command and portal path' ($shown -match 'gateway.*backend' -and $shown -match 'az cognitiveservices account list' -and $shown -match 'Azure portal:' -and $shown -match 'region-a') $shown
$script:Backend = 'https://not-a-listed-endpoint.services.ai.azure.com/anthropic'
$m = Get-Thrown { Select-ClaudeFoundryAccount -ResourceGroup rg-app -ApimName apim-one -Interactive $false -Reader $never }
Assert 'Foundry ambiguity names both accounts and where to find them' ($m -match 'ai-other' -and $m -match 'ai-linked' -and $m -match 'Pass -FoundryAccount' -and $m -match 'az cognitiveservices account list' -and $m -match 'Azure portal:') $m
$script:Accounts = @($script:Accounts[0])
$r = Invoke-Choice { Select-ClaudeFoundryAccount -ResourceGroup rg-app -ApimName apim-one -Interactive $false -Reader $never }
Assert 'a sole Foundry account is certain without a backend link' ($r -eq 'ai-other') "got $r"
$script:Accounts = @()
$m = Get-Thrown { Select-ClaudeFoundryAccount -ResourceGroup rg-app -Interactive $false -Reader $never }
Assert 'no Foundry account names the command and portal, not a bare refusal' ($m -match 'Pass -FoundryAccount' -and $m -match 'az cognitiveservices account list' -and $m -match 'Azure portal:') $m

$recorded = @{ resourceGroup = 'rg-recorded'; url = 'https://api-recorded.azurewebsites.net' }
foreach ($console in $true, $false) {
    $r = Invoke-Choice { Select-ClaudeTurnstileResourceGroup -ResourceGroup rg-app -ApimName apim-one -Integration $recorded -Interactive $console -Reader $never }
    Assert "a recorded Turnstile group counts as given (console=$console)" ($r -eq 'rg-recorded') "got $r"
}
$r = Invoke-Choice { Select-ClaudeTurnstileResourceGroup -ResourceGroup rg-app -ApimName apim-one -Interactive $true -Reader (New-Reader @('2')) }
Assert 'Turnstile group number picks from discovered web app groups' ($r -eq 'rg-turnstile-b') "got $r"
$m = Get-Thrown { Select-ClaudeTurnstileResourceGroup -ResourceGroup rg-app -ApimName apim-one -Interactive $false -Reader $never }
Assert 'unrecorded Turnstile ambiguity names groups, command and portal' ($m -match 'rg-turnstile-a' -and $m -match 'rg-turnstile-b' -and $m -match 'Pass -TurnstileResourceGroup' -and $m -match 'az webapp list' -and $m -match 'Azure portal:') $m
$script:Apps = @($script:Apps[0])
foreach ($console in $true, $false) {
    $r = Invoke-Choice { Select-ClaudeTurnstileResourceGroup -ResourceGroup rg-app -ApimName apim-one -Interactive $console -Reader (New-Reader @('')) }
    Assert "a sole web app group is recommended (console=$console)" ($r -eq 'rg-turnstile-a') "got $r"
}
$shown = try { Select-ClaudeTurnstileResourceGroup -ResourceGroup rg-app -ApimName apim-one -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
Assert 'Turnstile group options name the app and recorded named value lookup' ($shown -match 'api-a' -and $shown -match 'turnstile-integration' -and $shown -match 'az apim nv show') $shown
$script:Apps = @()
$m = Get-Thrown { Select-ClaudeTurnstileResourceGroup -ResourceGroup rg-app -ApimName apim-one -Interactive $false -Reader $never }
Assert 'no Turnstile group has command and portal guidance' ($m -match 'Pass -TurnstileResourceGroup' -and $m -match 'az webapp list' -and $m -match 'Azure portal:') $m

$scratch = Join-Path ([IO.Path]::GetTempPath()) "claude-backup-choice-$PID-$(Get-Random)"
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $older = Join-Path $scratch 'claude-code-old.zip'
    $newer = Join-Path $scratch 'claude-code-new.zip'
    Set-Content $older 'fixture'
    Set-Content $newer 'fixture'
    (Get-Item $older).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
    (Get-Item $newer).LastWriteTimeUtc = [datetime]'2026-02-01T00:00:00Z'
    $r = Invoke-Choice { Select-ClaudeBackup -Folder $scratch -Pattern 'claude-code-*.zip' -Parameter CodeBackup -Interactive $true -Reader (New-Reader @('')) }
    Assert 'backup Enter recommends the newest by modification time' ($r -eq $newer) "got $r"
    $r = Invoke-Choice { Select-ClaudeBackup -Folder $scratch -Pattern 'claude-code-*.zip' -Parameter CodeBackup -Interactive $true -Reader (New-Reader @('2')) }
    Assert 'backup number can choose an older archive' ($r -eq $older) "got $r"
    $m = Get-Thrown { Select-ClaudeBackup -Folder $scratch -Pattern 'claude-code-*.zip' -Parameter CodeBackup -Interactive $false -Reader $never }
    Assert 'newest does not mean certain: unattended backup ambiguity refuses' ($m -match 'claude-code-new.zip' -and $m -match 'claude-code-old.zip' -and $m -match 'Pass -CodeBackup' -and $m -match 'Get-ChildItem' -and $m -match 'File Explorer:') $m
    $shown = try { Select-ClaudeBackup -Folder $scratch -Pattern 'claude-code-*.zip' -Parameter CodeBackup -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
    Assert 'backup options show source folder, UTC time and recommendation reason' ($shown.Contains($scratch) -and $shown -match '2026-02-01' -and $shown -match 'newest' -and $shown -match 'UTC') $shown
    Remove-Item $newer
    $r = Invoke-Choice { Select-ClaudeBackup -Folder $scratch -Pattern 'claude-code-*.zip' -Parameter CodeBackup -Interactive $false -Reader $never }
    Assert 'a sole backup is certain without a console' ($r -eq $older) "got $r"
    Remove-Item $older
    $m = Get-Thrown { Select-ClaudeBackup -Folder $scratch -Pattern 'claude-code-*.zip' -Parameter CodeBackup -Interactive $false -Reader $never }
    Assert 'no backups names the local lookup instead of an Azure portal' ($m -match 'Pass -CodeBackup' -and $m -match 'Get-ChildItem' -and $m -match 'File Explorer:') $m
}
finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Scripts that use it' -ForegroundColor Cyan
foreach ($name in 'Publish-ClaudeWorkbook.ps1', 'Publish-ClaudeQueries.ps1', 'Publish-ClaudeGrafana.ps1') {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name offers the workspace instead of guessing" ($text -match '\. \(Join-Path \$PSScriptRoot ''ClaudeChoice\.ps1''\)' -and $text -match 'Select-ClaudeWorkspace -ResourceGroup')
    Assert "$name asks for an unknown resource group" ($text -match 'if \(-not \$ResourceGroup\) \{ \$ResourceGroup = Select-ClaudeResourceGroup \}')
}
$telemetry = Get-Content (Join-Path $root 'scripts/Get-ClaudeTelemetry.ps1') -Raw
Assert 'the telemetry lookup no longer takes the first gateway' ($telemetry -notmatch '\[0\]\.name' -and $telemetry -match 'Select-ClaudeGateway -ResourceGroup')
Assert 'and names the linked workspace' ($telemetry -match 'WorkspaceResourceId = ')
$queries = Get-Content (Join-Path $root 'scripts/Publish-ClaudeQueries.ps1') -Raw
Assert 'membership asks for the gateway too' ($queries -notmatch '\[0\]\.name' -and $queries -match 'Select-ClaudeGateway -ResourceGroup')
$grafana = Get-Content (Join-Path $root 'scripts/Publish-ClaudeGrafana.ps1') -Raw
Assert 'Grafana offers the existing instances' ($grafana -match 'Select-ClaudeChoice -Parameter GrafanaName')

foreach ($name in @(
    'Get-ClaudeBudget.ps1', 'Set-ClaudeBudget.ps1', 'Get-ClaudeBusinessUnit.ps1', 'Set-ClaudeBusinessUnit.ps1',
    'Connect-ClaudeTurnstile.ps1', 'Export-ClaudeTurnstileUsage.ps1', 'Invoke-ClaudeTurnstileSchedule.ps1',
    'Register-ClaudeTurnstileSchedule.ps1', 'Sync-ClaudeTurnstileGovernance.ps1', 'Get-ClaudeTurnstileBom.ps1',
    'Open-ClaudeTurnstile.ps1', 'Get-ClaudeBypass.ps1', 'Add-ClaudeModel.ps1', 'Get-ClaudeBom.ps1',
    'Backup-ClaudeGateway.ps1', 'Set-ClaudeTier.ps1', 'Set-ClaudeDeveloper.ps1'
)) {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name loads the shared chooser" ($text -match '\. \(Join-Path \$PSScriptRoot ''ClaudeChoice\.ps1''\)')
    Assert "$name chooses the gateway rather than the first name" ($text -match 'Select-ClaudeGateway -ResourceGroup' -and $text -notmatch '\[0\]\.name')
    Assert "$name asks when the resource group is unknown" ($text -match 'Select-ClaudeResourceGroup')
}
foreach ($name in 'Get-ClaudeBypass.ps1', 'Add-ClaudeModel.ps1') {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name offers the Foundry account" ($text -match 'Select-ClaudeFoundryAccount -ResourceGroup')
}
foreach ($name in 'Connect-ClaudeTurnstile.ps1', 'Get-ClaudeTurnstileBom.ps1') {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name offers an unrecorded Turnstile group" ($text -match 'Select-ClaudeTurnstileResourceGroup')
}
$migration = Get-Content (Join-Path $root 'scripts/Migrate-ClaudeWorkstation.ps1') -Raw
Assert 'workstation restore loads the chooser and stops silently taking the newest' ($migration -match 'ClaudeChoice\.ps1' -and $migration -match 'Select-ClaudeBackup' -and $migration -notmatch '\[0\]\.name')
Assert 'workstation restore permits an explicit archive for automation' ($migration -match '\[string\]\$CodeBackup' -and $migration -match '\[string\]\$DesktopBackup')
$overshoot = Get-Content (Join-Path $root 'scripts/Measure-ClaudeOvershoot.ps1') -Raw
Assert 'overshoot offers a workspace with lookup guidance' ($overshoot -match 'ClaudeChoice\.ps1' -and $overshoot -match 'Select-ClaudeWorkspace -ResourceGroup')
$backup = Get-Content (Join-Path $root 'scripts/Backup-ClaudeGateway.ps1') -Raw
Assert 'gateway backup offers a workspace when no local diagnostic target is certain' ($backup -match 'Select-ClaudeWorkspace -ResourceGroup')

$turnstileJob = Get-Content (Join-Path $root 'infra/turnstile-schedule.bicep') -Raw
$reportJob = Get-Content (Join-Path $root 'infra/chargeback-reports.bicep') -Raw
Assert 'Turnstile jobs pass both target values explicitly' ($turnstileJob.Contains('-ResourceGroup "${CLAUDE_RG}" -ApimName "${CLAUDE_APIM}"'))
Assert 'chargeback jobs pass storage and record both target environment values' ($reportJob.Contains('-StorageAccount "${REPORT_STORAGE}"') -and $reportJob -match "name: 'CLAUDE_RG', value: resourceGroup\(\).name" -and $reportJob -match "name: 'CLAUDE_APIM', value: gatewayApimName")

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Scripts ask for what they were not given.' -ForegroundColor Green
exit 0
