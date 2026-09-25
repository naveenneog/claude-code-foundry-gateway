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
Write-Host 'Choosing report resources, models and Application Insights' -ForegroundColor Cyan
$script:ReportResources = @()
$script:ReportOutputs = @{}
$script:Insights = @(
    [pscustomobject]@{ name = 'appi-a'; id = '/subscriptions/s/resourceGroups/rg-app/providers/Microsoft.Insights/components/appi-a'; location = 'region-a' }
    [pscustomobject]@{ name = 'appi-b'; id = '/subscriptions/s/resourceGroups/rg-app/providers/Microsoft.Insights/components/appi-b'; location = 'region-b' }
)
$script:GatewayGroups = @([pscustomobject]@{ name = 'apim-a'; group = 'rg-a' }, [pscustomobject]@{ name = 'apim-b'; group = 'rg-b' })
function az {
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'resource list*Microsoft.Insights/components*') { return (ConvertTo-Json -InputObject @($script:Insights)) }
    if ($line -like 'resource list*') { return (ConvertTo-Json -InputObject @($script:ReportResources) -Depth 5) }
    if ($line -like 'deployment group show*') { return (ConvertTo-Json -InputObject $script:ReportOutputs -Depth 5) }
    if ($line -like 'apim list --query*') { return (ConvertTo-Json -InputObject @($script:GatewayGroups)) }
    throw "unexpected az $line"
}
foreach ($kind in 'StorageAccount', 'AdministrationJob') {
    $parameter = if ($kind -eq 'StorageAccount') { 'StorageAccount' } else { 'JobName' }
    $type = if ($kind -eq 'StorageAccount') { 'Microsoft.Storage/storageAccounts' } else { 'Microsoft.App/jobs' }
    $prefix = if ($kind -eq 'StorageAccount') { 'streports' } else { 'job-reports-admin-' }
    $field = if ($kind -eq 'StorageAccount') { 'storageAccount' } else { 'adminJobName' }
    $script:ReportResources = @(
        [pscustomobject]@{ name = "${prefix}one"; type = $type; location = 'region-a'; tags = @{ 'claude-chargeback-gateway' = 'apim-one' } }
        [pscustomobject]@{ name = "${prefix}two"; type = $type; location = 'region-b'; tags = @{ 'claude-chargeback-gateway' = 'apim-one' } }
        [pscustomobject]@{ name = "${prefix}foreign"; type = $type; location = 'region-c'; tags = @{ 'claude-chargeback-gateway' = 'another-gateway' } }
    )
    $script:ReportOutputs = @{}
    $r = Invoke-Choice { Select-ClaudeReportResource -ResourceGroup rg-app -ApimName apim-one -Kind $kind -Interactive $true -Reader (New-Reader @('2')) }
    Assert "$kind number picks only from this gateway's tagged resources" ($r -eq "${prefix}two") "got $r"
    $m = Get-Thrown { Select-ClaudeReportResource -ResourceGroup rg-app -ApimName apim-one -Kind $kind -Interactive $false -Reader $never }
    Assert "$kind ambiguity names candidates, the parameter and lookup locations" ($m -match "${prefix}one" -and $m -match "${prefix}two" -and $m -notmatch "${prefix}foreign" -and $m -match "Pass -$parameter" -and $m -match 'az resource list' -and $m -match 'Azure portal:') $m
    $script:ReportOutputs[$field] = @{ value = "${prefix}two" }
    foreach ($console in $true, $false) {
        $r = Invoke-Choice { Select-ClaudeReportResource -ResourceGroup rg-app -ApimName apim-one -Kind $kind -Interactive $console -Reader $never }
        Assert "$kind deployment output counts as given (console=$console)" ($r -eq "${prefix}two") "got $r"
    }
    $script:ReportOutputs = @{}
    $script:ReportResources = @($script:ReportResources[0])
    foreach ($console in $true, $false) {
        $r = Invoke-Choice { Select-ClaudeReportResource -ResourceGroup rg-app -ApimName apim-one -Kind $kind -Interactive $console -Reader (New-Reader @('')) }
        Assert "$kind sole tagged resource is recommended (console=$console)" ($r -eq "${prefix}one") "got $r"
    }
    $shown = try { Select-ClaudeReportResource -ResourceGroup rg-app -ApimName apim-one -Kind $kind -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
    Assert "$kind options identify the gateway tag and Azure source" ($shown -match 'claude-chargeback-gateway' -and $shown -match 'region-a' -and $shown -match 'az resource list') $shown
    $script:ReportResources = @()
    $m = Get-Thrown { Select-ClaudeReportResource -ResourceGroup rg-app -ApimName apim-one -Kind $kind -Interactive $false -Reader $never }
    Assert "$kind empty discovery explains how to register and look it up" ($m -match 'Register-ClaudeChargebackSchedule' -and $m -match 'Azure portal:' -and $m -match "Pass -$parameter") $m
}

$modelArgs = @{ Names = @('model-b', 'model-a'); Source = 'the deployed Anthropic models on ai-one'; WhereToFind = @('az cognitiveservices account deployment list -g rg-app -n ai-one -o table', 'Azure portal: Foundry > Deployments') }
$r = Invoke-Choice { Select-ClaudeModel @modelArgs -Interactive $true -Reader (New-Reader @('')) }
Assert 'model Enter takes the displayed alphabetical recommendation' ($r -eq 'model-a') "got $r"
$r = Invoke-Choice { Select-ClaudeModel @modelArgs -Interactive $true -Reader (New-Reader @('2')) }
Assert 'model number chooses the other deployment' ($r -eq 'model-b') "got $r"
$m = Get-Thrown { Select-ClaudeModel @modelArgs -Interactive $false -Reader $never }
Assert 'several models never become a certain unattended price decision' ($m -match 'model-a, model-b' -and $m -match 'Pass -Model' -and $m -match 'az cognitiveservices' -and $m -match 'Azure portal:') $m
$shown = try { Select-ClaudeModel @modelArgs -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
Assert 'model choices explain the deployment source and uncertain recommendation' ($shown -match 'ai-one' -and $shown -match 'alphabetical' -and $shown -match 'not a price') $shown
$r = Invoke-Choice { Select-ClaudeModel -Names @('model-a') -Source 'configured tier' -WhereToFind $modelArgs.WhereToFind -Interactive $false -Reader $never }
Assert 'a sole allowed model is certain without a console' ($r -eq 'model-a') "got $r"
$m = Get-Thrown { Select-ClaudeModel -Names @() -Source 'configured tier' -WhereToFind $modelArgs.WhereToFind -Parameter DefaultModel -Interactive $false -Reader $never }
Assert 'no models names the actual parameter and lookup locations' ($m -match 'Pass -DefaultModel' -and $m -match 'Azure portal:' -and $m -match 'az cognitiveservices') $m

$r = Invoke-Choice { Select-ClaudeAppInsights -ResourceGroup rg-app -Interactive $true -Reader (New-Reader @('2')) }
Assert 'Application Insights number returns that component ARM id' ($r -eq $script:Insights[1].id) "got $r"
$m = Get-Thrown { Select-ClaudeAppInsights -ResourceGroup rg-app -Interactive $false -Reader $never }
Assert 'Application Insights ambiguity names candidates and lookup locations' ($m -match 'appi-a, appi-b' -and $m -match 'Pass -AppInsightsName' -and $m -match 'az resource list' -and $m -match 'Azure portal:') $m
$script:Insights = @($script:Insights[0])
foreach ($console in $true, $false) {
    $r = Invoke-Choice { Select-ClaudeAppInsights -ResourceGroup rg-app -Interactive $console -Reader (New-Reader @('')) }
    Assert "the sole Application Insights is recommended (console=$console)" ($r -eq $script:Insights[0].id) "got $r"
}
$shown = try { Select-ClaudeAppInsights -ResourceGroup rg-app -Interactive $true -Reader (New-Reader @('')) 6>&1 | Out-String } catch { "<threw: $($_.Exception.Message)>" }
Assert 'Application Insights options identify their ARM source and region' ($shown -match 'region-a' -and $shown -match 'Microsoft.Insights/components/appi-a' -and $shown -match 'az resource list') $shown
$script:Insights = @()
$m = Get-Thrown { Select-ClaudeAppInsights -ResourceGroup rg-app -Interactive $false -Reader $never }
Assert 'no Application Insights includes command and portal guidance' ($m -match 'Pass -AppInsightsName' -and $m -match 'az resource list' -and $m -match 'Azure portal:') $m

$r = Invoke-Choice { Select-ClaudeResourceGroup -Interactive $true -Reader (New-Reader @('2')) }
Assert 'resource group number chooses from gateways across the subscription' ($r -eq 'rg-b') "got $r"
$m = Get-Thrown { Select-ClaudeResourceGroup -Interactive $false -Reader $never }
Assert 'resource group ambiguity names groups and lookup locations' ($m -match 'rg-a, rg-b' -and $m -match 'az apim list' -and $m -match 'Azure portal:') $m
$script:GatewayGroups = @($script:GatewayGroups[0])
foreach ($console in $true, $false) {
    $r = Invoke-Choice { Select-ClaudeResourceGroup -Interactive $console -Reader (New-Reader @('')) }
    Assert "a sole gateway resource group is recommended (console=$console)" ($r -eq 'rg-a') "got $r"
}

. (Join-Path $root 'scripts/ClaudeChargebackDiscovery.ps1')
$reportOptions = @([pscustomobject]@{Id='region-a';Name='Region A'}, [pscustomobject]@{Id='region-b';Name='Region B'})
$reportWhere = @('az account list-locations -o table', 'Azure portal: Subscriptions > Locations')
$r = Invoke-Choice { Select-ClaudeReportOption -Prompt Location -Parameter Location -Options $reportOptions -DefaultId region-b -WhereToFind $reportWhere -ReadSelection { param($p,$d) '' } }
Assert 'the reports adapter keeps Enter on the gateway region' ($r.Id -eq 'region-b') "got $r"
$r = Invoke-Choice { Select-ClaudeReportOption -Prompt Location -Parameter Location -Options $reportOptions -WhereToFind $reportWhere -ReadSelection { param($p,$d) '2' } }
Assert 'the reports adapter numbers the discovered options' ($r.Id -eq 'region-b') "got $r"
$r = Invoke-Choice { Select-ClaudeReportOption -Prompt Location -Parameter Location -Options $reportOptions -DefaultId region-b -WhereToFind $reportWhere -NonInteractive }
Assert 'the reports adapter accepts a configured region without a console' ($r.Id -eq 'region-b') "got $r"
$m = Get-Thrown { Select-ClaudeReportOption -Prompt Location -Parameter Location -Options $reportOptions -WhereToFind $reportWhere -NonInteractive }
Assert 'the reports adapter ambiguity names candidates and where to find them' ($m -match 'Region A, Region B' -and $m -match 'Pass -Location' -and $m -match 'az account list-locations' -and $m -match 'Azure portal:') $m
$savedInteractive = $env:CLAUDE_NONINTERACTIVE
$env:CLAUDE_NONINTERACTIVE = '1'
try {
    $m = Get-Thrown { Select-ClaudeReportOption -Prompt Location -Parameter Location -Options $reportOptions -WhereToFind $reportWhere }
    Assert 'the reports adapter detects headless execution without a switch' ($m -match 'ambiguous' -and $m -match 'Pass -Location') $m
}
finally { $env:CLAUDE_NONINTERACTIVE = $savedInteractive }

Write-Host ''
Write-Host 'Telemetry keeps an existing job target without asking' -ForegroundColor Cyan
$telemetryFixture = @{
    Mode = 'linked'; InventoryReads = 0
    Linked = '/subscriptions/s/resourceGroups/rg-else/providers/Microsoft.Insights/components/appi-linked'
    Local = '/subscriptions/s/resourceGroups/rg-app/providers/Microsoft.Insights/components/appi-a'
}
$azMock = {
    $global:LASTEXITCODE = 0
    $line = $args -join ' '
    if ($line -like 'account show*') { return 's' }
    if ($line -like 'account get-access-token*') { return 'fixture-token' }
    if ($line -like 'resource list*Microsoft.Insights/components*') {
        $telemetryFixture.InventoryReads++
        return ('[{"name":"appi-a","id":"' + $telemetryFixture.Local + '","location":"region-a"}]')
    }
    throw "unexpected az $line"
}.GetNewClosure()
Set-Item Function:\az $azMock
$armMock = {
    param($Uri, $Headers)
    if ($Uri -like '*/diagnostics/applicationinsights?*') {
        if ($telemetryFixture.Mode -eq 'linked') { return [pscustomobject]@{ properties = @{ loggerId = '/subscriptions/s/resourceGroups/rg-app/providers/Microsoft.ApiManagement/service/apim-one/loggers/current'; metrics = $true } } }
        return $null
    }
    if ($Uri -like '*/loggers/current?*') { return [pscustomobject]@{ properties = @{ resourceId = $telemetryFixture.Linked } } }
    $id = if ($telemetryFixture.Mode -eq 'linked') { $telemetryFixture.Linked } else { $telemetryFixture.Local }
    if ($Uri -eq "https://management.azure.com$id`?api-version=2020-02-02") {
        return [pscustomobject]@{ properties = @{ AppId = 'fixture-app'; WorkspaceResourceId = '/subscriptions/s/resourceGroups/rg-logs/providers/Microsoft.OperationalInsights/workspaces/log-linked' } }
    }
    throw "unexpected ARM read: $Uri"
}.GetNewClosure()
Set-Item Function:\Invoke-RestMethod $armMock
$telemetryScript = Join-Path $root 'scripts/Get-ClaudeTelemetry.ps1'
$r = Invoke-Choice { & $telemetryScript -ResourceGroup rg-app -ApimName apim-one -Interactive $false }
Assert 'a recorded diagnostic keeps the cross-group component ARM id' ($r.AppInsights -eq 'appi-linked' -and $r.Workspace -eq 'log-linked') "$r"
Assert 'a working scheduled telemetry path never inventories choices' ($telemetryFixture.InventoryReads -eq 0)
$telemetryFixture.Mode = 'explicit'
$r = Invoke-Choice { & $telemetryScript -ResourceGroup rg-app -ApimName apim-one -AppInsightsName appi-a -Interactive $false }
Assert 'an explicit telemetry component is given, not asked for' ($r.AppInsights -eq 'appi-a' -and $telemetryFixture.InventoryReads -eq 0) "$r"
$telemetryFixture.Mode = 'discovered'
$r = Invoke-Choice { & $telemetryScript -ResourceGroup rg-app -ApimName apim-one -Interactive $false }
Assert 'a missing logger can use a sole discovered component without a console' ($r.AppInsights -eq 'appi-a' -and $telemetryFixture.InventoryReads -eq 1) "$r"
Remove-Item Function:\Invoke-RestMethod

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

foreach ($name in 'Show-Governance.ps1', 'Setup-ClaudeFoundryDirect.ps1', 'Test-ClaudeNetworkEdge.ps1') {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name offers the model instead of silently taking a deployment" ($text -match 'ClaudeChoice\.ps1' -and $text -match 'Select-ClaudeModel' -and $text -notmatch '\[0\]\.name')
}
foreach ($name in 'ClaudeChargebackStorage.ps1', 'ClaudeChargebackAdministration.ps1') {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name offers the tagged resource with the shared selector" ($text -match 'ClaudeChoice\.ps1' -and $text -match 'Select-ClaudeReportResource' -and $text -notmatch '\[0\]\.name')
}
$schedule = Get-Content (Join-Path $root 'scripts/Register-ClaudeChargebackSchedule.ps1') -Raw
Assert 'reports registration selects storage before a settings write' ($schedule -match 'Get-ClaudeReportStorageAccount' -and $schedule -notmatch '\[0\]\.name' -and
    $schedule.IndexOf('$StorageAccount=Get-ClaudeReportStorageAccount') -lt $schedule.IndexOf("if(`$changes.Count)"))
$reportPass = Get-Content (Join-Path $root 'scripts/Invoke-ClaudeChargebackSchedule.ps1') -Raw
Assert 'a manual reports pass asks only for inputs the job already supplies' ($reportPass -match 'ClaudeChoice\.ps1' -and $reportPass -match 'if\(-not \$StorageAccount\)' -and $reportPass -match 'Get-ClaudeReportStorageAccount')
Assert 'telemetry offers a component when neither diagnostic nor explicit value identifies it' ($telemetry -match 'Select-ClaudeAppInsights -ResourceGroup')
$reportNetwork = Get-Content (Join-Path $root 'scripts/ClaudeChargebackNetwork.ps1') -Raw
Assert 'reports network choices name their parameters and lookup locations' ($reportNetwork -match 'ClaudeChoice\.ps1' -and $reportNetwork -match '\-WhereToFind' -and $reportNetwork -notmatch '\[0\]\.name')
foreach ($name in 'Set-ClaudeChargebackRecipients.ps1', 'Set-ClaudeChargebackSettings.ps1') {
    $text = Get-Content (Join-Path $root "scripts/$name") -Raw
    Assert "$name forwards its explicit job and headless setting" ($text.Contains('Invoke-ClaudeReportAdminRequest $ResourceGroup $ApimName $request $JobName -NonInteractive:$NonInteractive') -and $text -match '\[string\]\$JobName' -and $text -notmatch '\[0\]\.name')
}

$turnstileJob = Get-Content (Join-Path $root 'infra/turnstile-schedule.bicep') -Raw
$reportJob = Get-Content (Join-Path $root 'infra/chargeback-reports.bicep') -Raw
Assert 'Turnstile jobs pass both target values explicitly' ($turnstileJob.Contains('-ResourceGroup "${CLAUDE_RG}" -ApimName "${CLAUDE_APIM}"'))
Assert 'chargeback jobs pass storage and record both target environment values' ($reportJob.Contains('-StorageAccount "${REPORT_STORAGE}"') -and $reportJob -match "name: 'CLAUDE_RG', value: resourceGroup\(\).name" -and $reportJob -match "name: 'CLAUDE_APIM', value: gatewayApimName")

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Scripts ask for what they were not given.' -ForegroundColor Green
exit 0
