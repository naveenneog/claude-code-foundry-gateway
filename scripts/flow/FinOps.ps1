<#
.SYNOPSIS
    Guided-flow FinOps tool step: no tool, AUM Direct, AUM service, Turnstile, or Turnstile plus AUM.
#>

$script:FlowRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'FlowContract.ps1')
. (Join-Path $script:FlowRoot 'scripts\ClaudeChoice.ps1')
. (Join-Path $script:FlowRoot 'scripts\ClaudeAumDeployment.ps1')
. (Join-Path $script:FlowRoot 'scripts\ClaudeFinOpsPrices.ps1')

function Get-ClaudeFlowStepInfo {
    [pscustomobject]@{
        Name = 'FinOps'
        Title = 'FinOps tooling'
        DecisionKey = 'finops'
        DependsOn = @('Foundation')
        Actions = @('Setup', 'Change')
    }
}

function Get-FinOpsFlowDecision {
    param($Record)
    $existing = Get-ClaudeDecision -Record $Record -Key 'finops'
    if ($null -eq $existing) { return [pscustomobject]@{} }
    return $existing
}

function Get-FinOpsFlowDiscoveryValue {
    param($Discovery, [string]$Name)
    if ($null -eq $Discovery) { return $null }
    if ($Discovery -is [System.Collections.IDictionary] -and $Discovery.ContainsKey($Name)) { return $Discovery[$Name] }
    if ($Discovery.PSObject.Properties.Name -contains $Name) { return $Discovery.$Name }
    return $null
}

function Get-FinOpsFlowChoices {
    param($Discovery)
    $region = [string](Get-FinOpsFlowDiscoveryValue $Discovery 'Region')
    $prices = Get-FinOpsFlowDiscoveryValue $Discovery 'AumPrices'
    $turnstile = Get-FinOpsFlowDiscoveryValue $Discovery 'TurnstilePrices'
    if ($region -and $null -eq $prices) { $prices = Get-ClaudeAumPrices -Region $region }
    if ($region -and $null -eq $turnstile -and $null -ne $prices) { $turnstile = Get-ClaudeFinOpsComparisonPrice -Region $region -AumPrices $prices }
    return @(Get-ClaudeFinOpsChoices -Prices $prices -TurnstilePrices $turnstile)
}

function Get-ClaudeFlowStepQuestions {
    param($Record, $Discovery)
    $decision = Get-FinOpsFlowDecision $Record
    if ($decision.tool) { return @() }
    $choices = @(Get-FinOpsFlowChoices -Discovery $Discovery)
    $options = foreach ($choice in $choices) {
        $recommended = $choice.Id -eq 'Direct'
        New-ClaudeChoiceOption -Value $choice.Id -Label $choice.Label `
            -Detail ("Cost: {0}. Sign-in: {1}. Needs: {2}. {3}" -f $choice.Cost, $choice.Who, $choice.Needs, $choice.Implications) `
            -Recommended:$recommended -Reason $(if ($recommended) { 'No server and no extra Azure infrastructure; administrators can add a scoped authority later.' } else { '' })
    }
    return @([pscustomobject]@{
        Key = 'finops.tool'
        Question = 'Which FinOps tool should this gateway use?'
        Options = @($options)
        WhereToFind = @('docs/FINOPS-TOOLS.md', 'scripts/Select-ClaudeFinOpsTooling.ps1 -Region <region>')
        AcceptRecommendedWithoutConsole = $true
        Recommended = 'Direct'
        Reason = 'AUM Direct gives the guided flow a terminal and automation surface with no standing service cost.'
    })
}

function New-FinOpsFlowCommand {
    param([string]$File, [string[]]$Arguments = @(), [string]$Tool = 'powershell')
    [pscustomobject]@{ tool = $Tool; file = $File; arguments = @($Arguments) }
}

function Get-ClaudeFlowStepPlan {
    param($Record, $Discovery)
    $decision = Get-FinOpsFlowDecision $Record
    $tool = if ($decision.tool) { [string]$decision.tool } else { 'Direct' }
    $region = [string](Get-FinOpsFlowDiscoveryValue $Discovery 'Region')
    $choices = @(Get-FinOpsFlowChoices -Discovery $Discovery)
    $choice = @($choices | Where-Object Id -eq $tool)[0]
    if (-not $choice) { throw "Unknown FinOps tool '$tool'." }
    $cost = $null
    $costText = [string]$choice.Cost
    if ($costText -match '\$(\d+(?:\.\d+)?)') {
        $cost = New-ClaudeFlowCost -Item $choice.Label -MonthlyUsd ([decimal]$Matches[1]) -Source 'Select-ClaudeFinOpsTooling.ps1 helpers over Azure Retail Prices API and documented tool BOM' -RetrievedUtc ([DateTime]::UtcNow.ToString('o'))
    } else {
        $cost = New-ClaudeFlowCost -Item $choice.Label -Source 'Select-ClaudeFinOpsTooling.ps1 helpers over Azure Retail Prices API and documented tool BOM' -RetrievedUtc ([DateTime]::UtcNow.ToString('o')) -UnknownReason $costText
    }
    $actions = [System.Collections.Generic.List[object]]::new()
    $requires = [System.Collections.Generic.List[string]]::new()
    $implications = [System.Collections.Generic.List[string]]::new()
    $commands = [System.Collections.Generic.List[object]]::new()
    $implications.Add($choice.Implications)
    $implications.Add("Sign-in: $($choice.Who). Developers never sign in to a FinOps administration tool.")
    switch ($tool) {
        'None' {
            $actions.Add((New-ClaudeFlowAction -Verb Check -Target 'Gateway budgets and telemetry' -Detail 'No FinOps console or service will be added.'))
        }
        'Direct' {
            $actions.Add((New-ClaudeFlowAction -Verb Create -Target 'AUM local environment' -Detail 'Install-ClaudeAum.ps1 installs the terminal client.'))
            $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'AUM profile' -Detail 'aum configure --backend direct --no-prompt --save.'))
            $requires.Add('Azure CLI sign-in with gateway and workspace permissions')
            $commands.Add((New-FinOpsFlowCommand -File 'scripts\Install-ClaudeAum.ps1'))
            $commands.Add((New-FinOpsFlowCommand -Tool 'aum' -File 'aum' -Arguments @('configure','--backend','direct','--no-prompt','--save')))
        }
        'AumService' {
            $actions.Add((New-ClaudeFlowAction -Verb Create -Target 'AUM Entra application' -Detail 'New-ClaudeAumEntraApp.ps1 creates app roles and the consent-free API scope.'))
            $actions.Add((New-ClaudeFlowAction -Verb Deploy -Target 'AUM service' -Detail 'Deploy-ClaudeAumService.ps1 deploys Functions, Storage and selected options.'))
            $requires.Add('App registration ownership and Azure resource deployment rights')
            $commands.Add((New-FinOpsFlowCommand -File 'scripts\New-ClaudeAumEntraApp.ps1'))
            $commands.Add((New-FinOpsFlowCommand -File 'scripts\Deploy-ClaudeAumService.ps1' -Arguments @('-Accept','-Confirm:$false')))
        }
        'Turnstile' {
            $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'Turnstile connection' -Detail 'Connect-ClaudeTurnstile.ps1 records an existing Turnstile and its authorities.'))
            $implications.Add('Deploying Turnstile itself remains the Turnstile guide; this step connects an existing deployment and states its price.')
            $requires.Add('Existing Turnstile URL/scope or resource group, and authority decision')
            $commands.Add((New-FinOpsFlowCommand -File 'scripts\Connect-ClaudeTurnstile.ps1'))
        }
        'TurnstileAum' {
            $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'Turnstile connection' -Detail 'Connect-ClaudeTurnstile.ps1 connects the gateway to Turnstile.'))
            $actions.Add((New-ClaudeFlowAction -Verb Write -Target 'AUM profile' -Detail 'AUM uses Turnstile as the server authority.'))
            $implications.Add('AUM is another Turnstile client; it is not a second writer.')
            $requires.Add('Existing Turnstile plus AUM client installation')
            $commands.Add((New-FinOpsFlowCommand -File 'scripts\Connect-ClaudeTurnstile.ps1'))
            $commands.Add((New-FinOpsFlowCommand -File 'scripts\Install-ClaudeAum.ps1' -Arguments @('-NoConfigure')))
            $commands.Add((New-FinOpsFlowCommand -Tool 'aum' -File 'aum' -Arguments @('configure','--backend','turnstile','--no-prompt','--save')))
        }
    }
    New-ClaudeFlowPlan -Step 'FinOps' -Summary "Choose and configure $($choice.Label)." `
        -Actions @($actions) -Costs @($cost) -Implications @($implications) -Requires @($requires) `
        -Reversible $true -Rollback 'Run Connect-ClaudeTurnstile.ps1 to return authority to Gateway, remove the AUM service with Remove-ClaudeAumService.ps1, or delete the local AUM profile.' `
        -Data @{ tool = $tool; region = $region; commands = @($commands); choice = $choice }
}

function Invoke-FinOpsFlowCommand {
    param($Command)
    if ($Command.tool -eq 'aum') {
        & $Command.file @($Command.arguments)
        if ($LASTEXITCODE) { throw "Command failed: $($Command.file)." }
        return
    }
    $path = Join-Path $script:FlowRoot $Command.file
    & $path @($Command.arguments)
    if ($LASTEXITCODE) { throw "Command failed: $($Command.file)." }
}

function Invoke-ClaudeFlowStep {
    param($Record, $Plan)
    foreach ($command in @($Plan.Data.commands)) { Invoke-FinOpsFlowCommand $command }
    return @{ finops = [pscustomobject]@{ tool = $Plan.Data.tool; configuredUtc = [DateTime]::UtcNow.ToString('o') } }
}

function Test-ClaudeFlowStep {
    param($Record)
    $decision = Get-FinOpsFlowDecision $Record
    $tool = [string]$decision.tool
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{ Name = 'decision recorded'; Passed = [bool]$tool; Evidence = $(if ($tool) { $tool } else { 'No finops.tool in decision record.' }); Fix = 'Run the FinOps step from Start-ClaudeGateway.ps1.' })
    if ($tool -eq 'Direct' -or $tool -eq 'TurnstileAum') {
        $aum = Get-Command aum -ErrorAction SilentlyContinue
        $checks.Add([pscustomobject]@{ Name = 'aum command available'; Passed = [bool]$aum; Evidence = $(if ($aum) { $aum.Source } else { 'aum not found on PATH.' }); Fix = 'Run scripts\Install-ClaudeAum.ps1 and aum configure.' })
    }
    if ($tool -like 'Turnstile*') {
        $connection = Get-ClaudeDecision -Record $Record -Key 'finops'
        $checks.Add([pscustomobject]@{ Name = 'Turnstile authority chosen'; Passed = [bool]$connection.tool; Evidence = 'Connection is verified by Connect-ClaudeTurnstile.ps1 during apply.'; Fix = 'Run Connect-ClaudeTurnstile.ps1 -Show for details.' })
    }
    [pscustomobject]@{ Step = 'FinOps'; Passed = -not @($checks | Where-Object { -not $_.Passed }).Count; Checks = @($checks) }
}
