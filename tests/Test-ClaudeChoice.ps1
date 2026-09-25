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

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Scripts ask for what they were not given.' -ForegroundColor Green
exit 0
