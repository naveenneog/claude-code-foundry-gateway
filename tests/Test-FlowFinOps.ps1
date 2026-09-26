# Guided-flow FinOps step modules. Runs on PowerShell 7 and, from PowerShell 7, Windows PowerShell 5.1.
param([switch]$Child)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0

function Assert($Label, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Throws([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

Write-Host ''
Write-Host "Guided flow FinOps modules ($($PSVersionTable.PSVersion))" -ForegroundColor Cyan

$record = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{} }

. (Join-Path $root 'scripts\flow\FinOps.ps1')
$info = Get-ClaudeFlowStepInfo
Assert 'FinOps exposes the fixed step metadata' ($info.Name -eq 'FinOps' -and $info.DecisionKey -eq 'finops' -and $info.DependsOn -contains 'Foundation')
$questions = @(Get-ClaudeFlowStepQuestions -Record $record -Discovery @{ Region = 'eastus2' })
Assert 'FinOps asks with five tool options' ($questions.Count -eq 1 -and @($questions[0].options).Count -eq 5)
Assert 'FinOps options include prices and sign-in implications' ((@($questions[0].options | Where-Object { $_.Value -eq 'Direct' })[0].Detail -match 'Sign-in') -and (@($questions[0].options | Where-Object { $_.Value -eq 'AumService' })[0].Detail -match 'Cost:'))
$before = $record | ConvertTo-Json -Depth 20 -Compress
$plan = Get-ClaudeFlowStepPlan -Record $record -Discovery @{ Region = 'eastus2' }
$after = $record | ConvertTo-Json -Depth 20 -Compress
Assert 'FinOps plan writes nothing' ($before -ceq $after)
Assert 'Direct plan installs AUM and writes a direct profile' ($plan.Data.tool -eq 'Direct' -and (($plan.Data.commands | ForEach-Object { $_.file }) -contains 'scripts\Install-ClaudeAum.ps1') -and (($plan.Actions | ForEach-Object { $_.Verb }) -contains 'Write'))
$record.decisions | Add-Member -NotePropertyName finops -NotePropertyValue ([pscustomobject]@{ tool = 'TurnstileAum' }) -Force
$turnstilePlan = Get-ClaudeFlowStepPlan -Record $record -Discovery @{ Region = 'eastus2' }
Assert 'Turnstile+AUM plan does not deploy the AUM service' (-not (($turnstilePlan.Data.commands | ForEach-Object { $_.file }) -contains 'scripts\Deploy-ClaudeAumService.ps1'))

. (Join-Path $root 'scripts\flow\Budgets.ps1')
$price = Get-BudgetsFlowPriceBook -Models @('claude-sonnet-5','unknown-model') -Path (Join-Path $root 'config\price-book.example.json')
Assert 'price book keeps known models and refuses unknown models' (-not $price.complete -and $price.unknownModels[0] -eq 'unknown-model' -and $price.models.PSObject.Properties.Name -contains 'claude-sonnet-5')
Assert 'invalid unpinned reconciler job is refused' ((Throws { New-BudgetsFlowUsdReconcilerJobDefinition -GatewayResourceId '/g' -WorkspaceResourceId '/w' -RepositoryUrl 'origin' -RepositoryRef 'main' }) -match 'full commit')
$job = New-BudgetsFlowUsdReconcilerJobDefinition -GatewayResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim' -WorkspaceResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log' -RepositoryUrl 'https://github.com/contoso/repo' -RepositoryRef ('a' * 40)
Assert 'reconciler job is five-minute and pinned' ($job.schedule -eq '*/5 * * * *' -and $job.image -match ':2\.90\.0$' -and $job.repositoryRef -eq ('a' * 40))
Assert 'reconciler identity is least-privilege scoped' (@($job.identity.grants | Where-Object { $_.scope -match 'ApiManagement' -and ($_.actions -contains 'Microsoft.ApiManagement/service/namedValues/write') }).Count -eq 1 -and @($job.identity.grants | Where-Object { $_.role -eq 'Log Analytics Reader' }).Count -eq 1)
$budgetRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ budgets = [pscustomobject]@{ currency = 'usd'; reconcile = 'job'; repositoryRef = ('b' * 40); gatewayResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim'; workspaceResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/log'; models = @('unknown-model') } } }
$blocked = Get-ClaudeFlowStepPlan -Record $budgetRecord -Discovery @{}
Assert 'USD plan blocks enforcement when a deployed model is unpriced' (-not $blocked.Data.priceBook.complete -and ($blocked.Implications -join ' ') -match 'missing price')
Assert 'apply refuses an unpriced USD plan' ((Throws { Invoke-ClaudeFlowStep -Record $budgetRecord -Plan $blocked }) -match 'no documented price')

. (Join-Path $root 'scripts\flow\Monitoring.ps1')
$workbooks = @(Get-MonitoringFlowWorkbookDefinitions)
$shipped = @(Get-ChildItem (Join-Path $root 'infra') -Filter 'workbook*.json' -File)
Assert 'workbook discovery covers every shipped workbook' ($workbooks.Count -eq $shipped.Count -and -not @(Compare-Object ($workbooks.RelativePath | Sort-Object) ($shipped.FullName | ForEach-Object { $_.Substring($root.Length + 1) } | Sort-Object)).Count)
$monitorPlan = Get-ClaudeFlowStepPlan -Record ([pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{} }) -Discovery @{}
Assert 'monitoring plan deploys queries before discovered workbooks' ($monitorPlan.Actions[0].Target -eq 'Saved KQL functions' -and @($monitorPlan.Data.workbooks).Count -eq $shipped.Count)

. (Join-Path $root 'scripts\flow\Reports.ps1')
$reportsRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ reports = [pscustomobject]@{ enabled = $true; allowedDomains = @('contoso.com'); recipients = @('finance@contoso.com'); cron = '0 6 1 * *' } } }
$reportsPlan = Get-ClaudeFlowStepPlan -Record $reportsRecord -Discovery @{}
Assert 'reports plan includes schedule, recipients and one generated report' (($reportsPlan.Actions | ForEach-Object { $_.Target }) -contains 'Chargeback report schedule' -and (($reportsPlan.Actions | ForEach-Object { $_.Target }) -contains 'Report recipients') -and (($reportsPlan.Actions | ForEach-Object { $_.Target }) -contains 'One report'))
Assert 'reports plan carries priced ACS/storage/jobs implications' (($reportsPlan.Costs | ForEach-Object { $_.Item }) -contains 'Chargeback reports standing networking' -and ($reportsPlan.Implications -join ' ') -match 'Azure-managed ACS')

if (-not $Child -and $IsWindows) {
    $ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($ps51) {
        & $ps51.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Child
        Assert 'the same module contract passes on Windows PowerShell 5.1' ($LASTEXITCODE -eq 0)
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Guided flow FinOps modules hold.' -ForegroundColor Green
exit 0
