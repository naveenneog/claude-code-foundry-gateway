<#
.SYNOPSIS
    Guided-flow budget step: token budgets or delayed USD budgets with an AUM timer or a scheduled Container Apps reconciler.
#>

$script:FlowRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $script:FlowRoot 'scripts\ClaudeChoice.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{
        Name = 'Budgets'
        Title = 'Token or dollar budgets'
        DecisionKey = 'budgets'
        DependsOn = @('Foundation', 'FinOps')
        Actions = @('Setup', 'Change')
    }
}

function Get-BudgetsFlowDecision {
    param($Record)
    $existing = Get-ClaudeDecision -Record $Record -Key 'budgets'
    if ($null -eq $existing) { return [pscustomobject]@{} }
    return $existing
}

function Get-BudgetsFlowValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.ContainsKey($Name)) { return $Object[$Name] }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Get-BudgetsFlowShippedPriceBook {
    param([string]$Path)
    if (-not $Path) {
        $Path = Join-Path $script:FlowRoot 'config\price-book.json'
        if (-not (Test-Path -LiteralPath $Path)) { $Path = Join-Path $script:FlowRoot 'config\price-book.example.json' }
    }
    $book = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    [pscustomobject]@{
        date = $book.date
        source = $book.source
        models = $book.models
        retrievedUtc = [DateTime]::UtcNow.ToString('o')
        research = @(
            'Microsoft Learn, Claude Consumption Units billing in Microsoft Foundry, retrieved 2026-09-27: https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing'
            'Azure Retail Prices API documentation, retrieved 2026-09-27: https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices'
            'Repository price book source; unknown model prices remain unknown rather than zero.'
        )
    }
}

function Get-BudgetsFlowPriceBook {
    param([string[]]$Models, [string]$Path)
    $book = Get-BudgetsFlowShippedPriceBook -Path $Path
    $items = [ordered]@{}
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($model in @($Models | Where-Object { $_ } | Sort-Object -Unique)) {
        if ($book.models.PSObject.Properties.Name -contains $model) { $items[$model] = $book.models.$model }
        else { $unknown.Add($model) }
    }
    [pscustomobject]@{
        date = $book.date
        source = $book.source
        retrievedUtc = $book.retrievedUtc
        research = $book.research
        models = [pscustomobject]$items
        unknownModels = @($unknown)
        complete = ($unknown.Count -eq 0)
    }
}

function New-BudgetsFlowUsdReconcilerJobDefinition {
    param(
        [string]$GatewayResourceId,
        [string]$WorkspaceResourceId,
        [string]$RepositoryUrl,
        [string]$RepositoryRef,
        [string]$Image = 'mcr.microsoft.com/azure-cli:2.90.0',
        [string]$Cron = '*/5 * * * *'
    )
    if ($RepositoryRef -notmatch '^[0-9a-f]{40}$') { throw 'RepositoryRef must be a full commit id so the reconciler image/checkout is pinned.' }
    if ($Cron -ne '*/5 * * * *') { throw 'The USD reconciler schedule must be every five minutes unless an ADR changes the enforcement envelope.' }
    [pscustomobject]@{
        type = 'Microsoft.App/jobs'
        name = 'job-usd-reconciler'
        schedule = $Cron
        image = $Image
        repositoryUrl = $RepositoryUrl
        repositoryRef = $RepositoryRef
        identity = [pscustomobject]@{
            type = 'UserAssigned'
            grants = @(
                [pscustomobject]@{ scope = $GatewayResourceId; role = 'Claude gateway governance writer'; actions = @('Microsoft.ApiManagement/service/read','Microsoft.ApiManagement/service/namedValues/read','Microsoft.ApiManagement/service/namedValues/write','Microsoft.ApiManagement/service/operationresults/read') }
                [pscustomobject]@{ scope = $WorkspaceResourceId; role = 'Log Analytics Reader'; actions = @('Microsoft.OperationalInsights/workspaces/query/read') }
            )
        }
        command = './scripts/Sync-ClaudeUsdBudgets.ps1'
        arguments = @('-ManagedIdentity')
        implications = @('Delayed observed-cost enforcement: ingestion plus up to five minutes plus execution and APIM propagation.', 'Not an Azure invoice cap; unknown prices block enforcement for affected models.')
    }
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $decision = Get-BudgetsFlowDecision $Record
    if ($decision.currency) { return @() }
    @(
        [pscustomobject]@{
            Key = 'budgets.currency'
            Question = 'Which budget basis should the guided flow configure?'
            Options = @(
                (New-ClaudeChoiceOption -Value 'tokens' -Label 'Token budgets' -Detail '$0 added; realtime approximate APIM token quotas; cache tokens are not counted.' -Recommended -Reason 'Existing gateway behavior with no scheduled reconciliation.')
                (New-ClaudeChoiceOption -Value 'usd' -Label 'Dollar budgets' -Detail 'Uses dated list-price tariffs and delayed observed-category reconciliation; unknown model prices block enforcement.')
            )
            WhereToFind = @('docs/BUDGETS.md#dollar-budgets-what-is-enforced', 'docs/adr/0026-usd-budget-reconciliation.md')
            AcceptRecommendedWithoutConsole = $true
            Recommended = 'tokens'
            Reason = 'Token budgets require no additional job or AUM service timer.'
        }
    )
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $decision = Get-BudgetsFlowDecision $Record
    $currency = if ($decision.currency) { [string]$decision.currency } else { 'tokens' }
    $finops = Get-ClaudeDecision -Record $Record -Key 'finops'
    $reconcile = if ($decision.reconcile) { [string]$decision.reconcile } elseif ($currency -eq 'usd' -and $finops.tool -eq 'AumService') { 'aum-service' } elseif ($currency -eq 'usd') { 'job' } else { 'none' }
    $actions = [System.Collections.Generic.List[object]]::new()
    $implications = [System.Collections.Generic.List[string]]::new()
    $costs = [System.Collections.Generic.List[object]]::new()
    $data = @{ currency = $currency; reconcile = $reconcile }
    if ($currency -eq 'tokens') {
        $actions.Add((New-ClaudeFlowAction -Verb Check -Target 'Token budgets' -Detail 'Use existing quota-org, tier, unit/team and person token controls.'))
        $costs.Add((New-ClaudeFlowCost -Item 'Token budget scheduler' -MonthlyUsd 0 -Source 'No added component; existing API Management policy.'))
        $implications.Add('Token budgets are approximate and prompt/completion only; they are not invoice caps.')
    } elseif ($currency -eq 'usd') {
        $models = @()
        $discoveredModels = Get-BudgetsFlowValue $Discovery 'Models'
        if ($discoveredModels) { $models = @($discoveredModels) }
        elseif ($decision.models) { $models = @($decision.models) }
        else { $models = @('claude-sonnet-5','claude-opus-5') }
        $priceBook = Get-BudgetsFlowPriceBook -Models $models -Path ([string]$decision.priceBookPath)
        $data.priceBook = $priceBook
        $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'usd-budgets' -Detail 'Persist dollar amounts and dated tariff without deleting token guards.'))
        $actions.Add((New-ClaudeFlowAction -Verb Run -Target 'USD reconciliation' -Detail "Mode: $reconcile."))
        $implications.Add('Dollar budgets are delayed observed-cost stops: ledger ingestion plus schedule plus execution plus gateway propagation.')
        $implications.Add('They are not Azure invoice caps; U2 and exact streaming cache-write accounting remain open.')
        if (-not $priceBook.complete) {
            $implications.Add('Blocking gap: missing price for ' + ($priceBook.unknownModels -join ', ') + '. Enforcement for those models must not proceed.')
            $costs.Add((New-ClaudeFlowCost -Item 'Claude model price book' -Source ($priceBook.source + '; Microsoft Learn CCU billing research') -RetrievedUtc $priceBook.retrievedUtc -UnknownReason ('Unknown models: ' + ($priceBook.unknownModels -join ', '))))
        } else {
            $costs.Add((New-ClaudeFlowCost -Item 'Claude model price book' -MonthlyUsd 0 -Source ($priceBook.source + '; dated tariff only, usage billed separately') -RetrievedUtc $priceBook.retrievedUtc))
        }
        if ($reconcile -eq 'aum-service') {
            $costs.Add((New-ClaudeFlowCost -Item 'USD reconciler timer' -MonthlyUsd 0 -Source 'Reuses the AUM service timer, identity, lease and audit; execution/storage usage applies.'))
        } elseif ($reconcile -eq 'job') {
            $repo = if ($decision.repositoryUrl) { [string]$decision.repositoryUrl } else { 'origin' }
            $commit = if ($decision.repositoryRef) { [string]$decision.repositoryRef } else { '0000000000000000000000000000000000000000' }
            if ($commit -eq '0000000000000000000000000000000000000000') {
                try { $commit = (git -C $script:FlowRoot rev-parse HEAD).Trim() } catch { $commit = '0000000000000000000000000000000000000000' }
            }
            $gatewayId = if ($decision.gatewayResourceId) { [string]$decision.gatewayResourceId } else { '/subscriptions/<subscription-id>/resourceGroups/<gateway-rg>/providers/Microsoft.ApiManagement/service/<gateway>' }
            $workspaceId = if ($decision.workspaceResourceId) { [string]$decision.workspaceResourceId } else { '/subscriptions/<subscription-id>/resourceGroups/<workspace-rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>' }
            if ($commit -match '^[0-9a-f]{40}$') {
                $job = New-BudgetsFlowUsdReconcilerJobDefinition -GatewayResourceId $gatewayId -WorkspaceResourceId $workspaceId -RepositoryUrl $repo -RepositoryRef $commit
                $data.reconcilerJob = $job
            }
            $costs.Add((New-ClaudeFlowCost -Item 'USD reconciler Container Apps job' -Source 'Azure Container Apps Consumption active seconds, managed identity; list price depends on region and run duration.' -UnknownReason 'Usage-based job execution and existing environment/network choices.'))
            $implications.Add('The job uses managed identity with named-value write only on the gateway and Log Analytics Reader on the workspace.')
        } else {
            $costs.Add((New-ClaudeFlowCost -Item 'USD reconciliation' -Source 'No scheduler selected.' -UnknownReason 'Dollar enforcement cannot stay fresh without a timer or job.'))
        }
    } else {
        throw "Unknown budget currency '$currency'."
    }
    New-ClaudeFlowPlan -Step 'Budgets' -Summary "Configure $currency budgets." `
        -Actions @($actions) -Costs @($costs) -Implications @($implications) `
        -Requires @('Gateway budget administrator', $(if ($currency -eq 'usd') { 'Workspace reader for reconciliation' })) `
        -Reversible $true -Rollback 'Clear or raise dollar budget definitions and reconcile; token quotas remain separately configurable.' `
        -Data $data
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    if ($Plan.Data.currency -eq 'usd' -and $Plan.Data.priceBook -and -not $Plan.Data.priceBook.complete) {
        throw 'USD budget enforcement is blocked because at least one deployed model has no documented price.'
    }
    if ($Plan.Data.currency -eq 'usd' -and $Plan.Data.reconcile -eq 'job' -and -not $Plan.Data.reconcilerJob) {
        throw 'USD budget reconciler job was not fully defined; repository commit must be pinned.'
    }
    if ($Plan.Data.currency -eq 'usd' -and $Plan.Data.reconcile -eq 'aum-service') {
        & (Join-Path $script:FlowRoot 'scripts\Sync-ClaudeUsdBudgets.ps1')
    }
    return @{ budgets = [pscustomobject]@{ currency = $Plan.Data.currency; reconcile = $Plan.Data.reconcile; configuredUtc = [DateTime]::UtcNow.ToString('o') } }
}

function Test-ClaudeFlowStep {
    param($Record)
    $decision = Get-BudgetsFlowDecision $Record
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{ Name = 'budget decision recorded'; Passed = [bool]$decision.currency; Evidence = $(if ($decision.currency) { $decision.currency } else { 'No budgets.currency in decision record.' }); Fix = 'Run the Budgets step.' })
    if ($decision.currency -eq 'usd') {
        $checks.Add([pscustomobject]@{ Name = 'reconciler selected'; Passed = [bool]$decision.reconcile; Evidence = $(if ($decision.reconcile) { $decision.reconcile } else { 'No reconciler selected.' }); Fix = 'Use AUM service timer or the scheduled reconciler job.' })
    }
    [pscustomobject]@{ Step = 'Budgets'; Passed = -not @($checks | Where-Object { -not $_.Passed }).Count; Checks = @($checks) }
}
