$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$runbookPath = Join-Path $root 'docs\PRODUCTION-ACCESS-PROFILES.md'
$catalogPath = Join-Path $root 'config\access-catalog.example.json'
$customerVnetImage = Join-Path $root 'docs\guide\production-customer-vnet.png'
$failures = 0
$assertions = 0

function Assert-Runbook {
    param([string]$Name, [bool]$Condition)
    $script:assertions++
    if ($Condition) {
        Write-Host "ok $script:assertions - $Name"
    }
    else {
        $script:failures++
        Write-Host "not ok $script:assertions - $Name"
    }
}

$catalog = Get-Content -Raw -LiteralPath $catalogPath | ConvertFrom-Json
Assert-Runbook 'the shipped production example contains nine plans' (@($catalog.plans).Count -eq 9)
Assert-Runbook 'the shipped production example contains 47 profiles' (@($catalog.profiles).Count -eq 47)
Assert-Runbook 'the production runbook exists' (Test-Path -LiteralPath $runbookPath -PathType Leaf)

$runbook = if (Test-Path -LiteralPath $runbookPath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $runbookPath
}
else {
    ''
}

Assert-Runbook 'the runbook names the nine-plan and 47-profile configuration' (
    $runbook -match '(?i)nine plans' -and $runbook -match '(?i)47 (?:Entra )?(?:profile )?groups'
)
Assert-Runbook 'the runbook states that catalog publication does not create Entra groups' (
    $runbook -match '(?i)Set-ClaudeAccessCatalog\.ps1.+does not create.+Entra groups'
)
Assert-Runbook 'the runbook gives one unattended resource deployment command' (
    $runbook -match '(?s)Install-ClaudeGateway\.ps1.+-AnswersPath.+-Yes'
)
Assert-Runbook 'the runbook gives the supported catalog preview and publish commands' (
    $runbook -match '(?s)Set-ClaudeAccessCatalog\.ps1.+-WhatIf.+Set-ClaudeAccessCatalog\.ps1'
)
Assert-Runbook 'the runbook gives the one-command scheduled-sync Graph grant' (
    $runbook -match 'Grant-ClaudeProjectionRenewalGraphAccess\.ps1\s+-PrincipalId\s+<job-managed-identity-principal-id>'
)
$missingNetworkAnswers = @(
    'ProjectionNetworkMode',
    'ProjectionVnetId',
    'ProjectionEndpointsSubnetId',
    'ProjectionRunnerSubnetId',
    'ProjectionResolverSubnetId',
    'ProjectionRenewalSubnetId',
    'ProjectionApimSubnetId'
) | Where-Object { $runbook -notmatch [regex]::Escape($_) }
Assert-Runbook 'the customer VNet example names every projection network answer' (
    @($missingNetworkAnswers).Count -eq 0
)
Assert-Runbook 'the runbook distinguishes nominal credit metadata from enforced USD budgets' (
    $runbook -match '(?i)nominalCredit.+metadata' -and $runbook -match '(?i)explicit.+USD budgets'
)
Assert-Runbook 'the runbook embeds the customer VNet screenshot' (
    $runbook -match 'guide/production-customer-vnet\.png'
)
Assert-Runbook 'the customer VNet screenshot exists' (
    Test-Path -LiteralPath $customerVnetImage -PathType Leaf
)
$groupBlock = [regex]::Match(
    $runbook,
    '(?s)```powershell\s*(?<code>\$ErrorActionPreference = ''Stop''.+?Prepared \$catalogPath.+?)\s*```'
)
$groupBlockParses = $false
if ($groupBlock.Success) {
    try {
        [void][scriptblock]::Create($groupBlock.Groups['code'].Value)
        $groupBlockParses = $true
    }
    catch {
        $groupBlockParses = $false
    }
}
Assert-Runbook 'the 47-group preparation block parses as PowerShell' $groupBlockParses

$answersBlock = [regex]::Match(
    $runbook,
    '(?s)```json\s*(?<json>\{\s*"SubscriptionId".+?"ProjectionApimSubnetId".+?\})\s*```'
)
$answersBlockParses = $false
if ($answersBlock.Success) {
    try {
        $answers = $answersBlock.Groups['json'].Value | ConvertFrom-Json -ErrorAction Stop
        $answersBlockParses = [string]$answers.ProjectionNetworkMode -eq 'existing'
    }
    catch {
        $answersBlockParses = $false
    }
}
Assert-Runbook 'the customer VNet answers example parses as JSON' $answersBlockParses

if ($failures) {
    throw "$failures of $assertions production access runbook assertions failed."
}
Write-Host "$assertions production access runbook assertions passed."
