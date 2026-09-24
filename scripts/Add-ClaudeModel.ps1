<#
.SYNOPSIS
    Makes a newly released Claude model usable, priced and chargeable.

.DESCRIPTION
    A new Claude model turning up in Foundry is routine, and before this it took
    four separate edits to make it usable: deploy it, add it to a tier's allow
    list, add its price so spend is attributed, and hand the model name to
    developers. Miss the third and the model is served but charged at nothing.

    This does all of it in one command and reports what it changed.

      1. Checks the model is actually deployed on the Foundry account, and
         offers to deploy it when it is not
      2. Adds it to the tier allow lists you name
      3. Writes its list price into config/price-book.json
      4. Prints what developers have to change, which is the model name only

    Nothing is guessed. A model that is not deployed is not added to a tier,
    because a tier allowing a model the account does not serve refuses the
    caller with a model name that looks correct. Pass -Deploy to create the
    deployment as part of the same command.

.PARAMETER Model
    The deployment name, as it appears in Foundry - for example claude-opus-5.

.PARAMETER Deploy
    Create the Foundry deployment when it does not exist, rather than refusing.
    Quota failures are reported as quota rather than as a generic failure,
    because the answer to one is a quota request and not a retry.

.PARAMETER Remove
    Take the model out of the tier allow lists. Its price-book entry stays, so
    reports covering past months still price it correctly.

.PARAMETER Tier
    Which tiers may call it: standard, premium, or both. Defaults to premium,
    because a new model is usually the expensive one.

.PARAMETER InputPerMillion
    List price in US dollars per million input tokens.

.PARAMETER OutputPerMillion
    List price in US dollars per million output tokens.

.PARAMETER SkipPrice
    Add the model to the tiers without pricing it. Its usage will then be
    reported at zero, which the command says out loud.

.EXAMPLE
    ./scripts/Add-ClaudeModel.ps1 -Model claude-opus-5 -Tier premium `
        -InputPerMillion 5 -OutputPerMillion 25 `
        -ResourceGroup rg-claude -ApimName apim-claude

.EXAMPLE
    ./scripts/Add-ClaudeModel.ps1 -Model claude-opus-5 -Deploy -Tier premium `
        -InputPerMillion 5 -OutputPerMillion 25 `
        -ResourceGroup rg-claude -ApimName apim-claude

.EXAMPLE
    ./scripts/Add-ClaudeModel.ps1 -Model claude-opus-4.8 -Remove -Tier both `
        -ResourceGroup rg-claude -ApimName apim-claude

.EXAMPLE
    ./scripts/Add-ClaudeModel.ps1 -List -ResourceGroup rg-claude -ApimName apim-claude
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Add', Mandatory = $true)][string]$Model,
    [Parameter(ParameterSetName = 'Add')][ValidateSet('standard', 'premium', 'both')][string]$Tier = 'premium',
    [Parameter(ParameterSetName = 'Add')][decimal]$InputPerMillion,
    [Parameter(ParameterSetName = 'Add')][decimal]$OutputPerMillion,
    [Parameter(ParameterSetName = 'Add')][switch]$SkipPrice,
    [Parameter(ParameterSetName = 'Add')][switch]$SkipDeploymentCheck,
    [Parameter(ParameterSetName = 'Add')][switch]$Deploy,
    [Parameter(ParameterSetName = 'Add')][switch]$Remove,

    [Parameter(ParameterSetName = 'List')][switch]$List,

    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$FoundryAccount
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
# Reused rather than reimplemented: this already filters an account down to the
# deployments the gateway can front, matching on both the model name and the
# publisher format because either alone is wrong. Listing every deployment
# would show sora, embeddings and the GPT family as "not priced", which is true
# and irrelevant - this gateway governs Claude.
. (Join-Path $PSScriptRoot 'ClaudeModelDeployment.ps1')

$priceBookPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config/price-book.json'

function Get-DeployedModels {
    if (-not $FoundryAccount) {
        $accounts = az cognitiveservices account list -g $ResourceGroup --query "[?kind=='AIServices'].name" -o tsv 2>$null
        $names = @($accounts -split "`n" | Where-Object { $_ })
        if ($names.Count -eq 1) { $script:FoundryAccount = $names[0].Trim() }
        elseif ($names.Count -eq 0) { throw "No Foundry account in '$ResourceGroup'. Pass -FoundryAccount." }
        else { throw ("$($names.Count) Foundry accounts in '$ResourceGroup': " + ($names -join ', ') + ". Pass -FoundryAccount.") }
    }
    return @(Get-ClaudeDeployment -Account $FoundryAccount -ResourceGroup $ResourceGroup | ForEach-Object { $_.name })
}

Write-Host ''
Write-Host 'Claude models' -ForegroundColor Cyan

if ($List) {
    $deployed = Get-DeployedModels
    Write-Host "  Foundry : $FoundryAccount ($ResourceGroup)"
    Write-Host ''
    Write-Host ("  {0,-26} {1,-10} {2,-10} {3,12} {4,12}" -f 'Model', 'Deployed', 'Priced', 'In/M', 'Out/M')

    $tiers = @{}
    if ($ApimName) {
        foreach ($t in 'standard', 'premium') {
            $v = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id "models-$t"
            $tiers[$t] = @(([string]$v).Trim(',') -split ',' | Where-Object { $_ })
        }
    }

    $all = @($deployed) + @($ClaudePriceBook.Keys) | Sort-Object -Unique
    foreach ($m in $all) {
        $p = $ClaudePriceBook[$m]
        Write-Host ("  {0,-26} {1,-10} {2,-10} {3,12} {4,12}" -f `
            $m,
            $(if ($deployed -contains $m) { 'yes' } else { 'no' }),
            $(if ($p) { 'yes' } else { 'NO' }),
            $(if ($p) { '$' + $p.InputPerM } else { '-' }),
            $(if ($p) { '$' + $p.OutputPerM } else { '-' })) `
            -ForegroundColor $(if ($deployed -contains $m -and -not $p) { 'Red' } elseif ($deployed -contains $m) { 'Green' } else { 'DarkGray' })
        if ($ApimName) {
            $in = @('standard', 'premium') | Where-Object { $tiers[$_] -contains $m }
            Write-Host ("  {0,-26} tiers: {1}" -f '', $(if ($in) { $in -join ', ' } else { 'none' })) -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host '  A deployed model with no price is served and charged at nothing.' -ForegroundColor DarkGray
    Write-Host '  Price book: ' -NoNewline -ForegroundColor DarkGray
    Write-Host $(if (Test-Path $priceBookPath) { "$priceBookPath ($ClaudePriceBookDate)" } else { "built-in defaults ($ClaudePriceBookDate)" }) -ForegroundColor DarkGray
    exit 0
}

# --- add -------------------------------------------------------------------

if ($Remove) {
    if (-not $ApimName) { throw 'Removing a model changes the tier allow lists, so -ApimName is required.' }
    $targets = if ($Tier -eq 'both') { @('standard', 'premium') } else { @($Tier) }
    $changed = $false
    foreach ($t in $targets) {
        $id = "models-$t"
        $current = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id
        $items = @(([string]$current).Trim(',') -split ',' | Where-Object { $_ })
        if ($items -notcontains $Model) {
            Write-Host "  $id does not list $Model" -ForegroundColor DarkGray
            continue
        }
        $kept = @($items | Where-Object { $_ -ne $Model })
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id `
            -Value $(if ($kept.Count) { ',' + ($kept -join ',') + ',' } else { ',,' })
        Write-Host ("  {0}: removed {1}, {2} left" -f $id, $Model, $kept.Count) -ForegroundColor Yellow
        $changed = $true
    }
    Write-Host ''
    if ($changed) {
        Write-Host '  The price stays in the price book on purpose: a report covering a past' -ForegroundColor DarkGray
        Write-Host '  month still needs the rate that applied then. See ADR-0010.' -ForegroundColor DarkGray
    }
    Write-Host '  If managed settings pin availableModels, regenerate that profile too.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

if (-not $SkipPrice -and -not ($PSBoundParameters.ContainsKey('InputPerMillion') -and $PSBoundParameters.ContainsKey('OutputPerMillion'))) {
    throw ("Pass -InputPerMillion and -OutputPerMillion so '$Model' can be charged, or -SkipPrice to add it unpriced. " +
           "An unpriced model is served and reported at zero, which reads as nobody using it.")
}

if (-not $SkipDeploymentCheck) {
    $deployed = Get-DeployedModels
    if ($deployed -notcontains $Model) {
        if ($Deploy) {
            # Quota is the failure worth naming separately: a subscription can be
            # perfectly healthy and still refuse, and "deployment failed" sends
            # the operator to retry rather than to a quota request.
            Write-Host "  $Model is not deployed - creating it on $FoundryAccount" -ForegroundColor Yellow
            $created = New-ClaudeDeployment -Account $FoundryAccount -ResourceGroup $ResourceGroup -Model $Model
            Write-Host ("  deployed: {0}" -f (Format-ClaudeDeployment $created)) -ForegroundColor Green
        } else {
            $near = @($deployed | Where-Object { $_ -like "*$($Model -replace '[^a-zA-Z]', '')*" -or $Model -like "*$_*" })
            throw ("'$Model' is not deployed on Foundry account '$FoundryAccount'. " +
                   $(if ($near) { "Deployed and similar: $($near -join ', '). " } else { "Deployed: $($deployed -join ', '). " }) +
                   "Pass -Deploy to create it now, or -SkipDeploymentCheck if you are staging configuration ahead of the deployment.")
        }
    } else {
        Write-Host "  $Model is deployed on $FoundryAccount" -ForegroundColor Green
    }
}

# --- price -----------------------------------------------------------------

if (-not $SkipPrice) {
    $doc = if (Test-Path $priceBookPath) { Get-Content $priceBookPath -Raw | ConvertFrom-Json } else { $null }

    $models = [ordered]@{}
    if ($doc -and $doc.models) {
        foreach ($p in $doc.models.PSObject.Properties) { $models[$p.Name] = $p.Value }
    } else {
        # Seed from the built-in table so writing the file for the first time
        # does not drop the models that were already priced.
        foreach ($k in $ClaudePriceBook.Keys | Sort-Object) {
            $models[$k] = [ordered]@{ inputPerM = $ClaudePriceBook[$k].InputPerM; outputPerM = $ClaudePriceBook[$k].OutputPerM }
        }
    }

    $was = $models[$Model]
    $models[$Model] = [ordered]@{ inputPerM = $InputPerMillion; outputPerM = $OutputPerMillion }

    $out = [ordered]@{
        date   = (Get-Date -Format 'yyyy-MM-dd')
        source = 'list price, https://platform.claude.com/docs/en/about-claude/pricing'
        models = $models
    }
    New-Item -ItemType Directory -Path (Split-Path $priceBookPath -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($priceBookPath, ($out | ConvertTo-Json -Depth 6))

    if ($was) {
        Write-Host ("  price updated: `${0}/M in, `${1}/M out (was `${2}/`${3})" -f $InputPerMillion, $OutputPerMillion, $was.inputPerM, $was.outputPerM) -ForegroundColor Yellow
    } else {
        Write-Host ("  priced: `${0}/M in, `${1}/M out" -f $InputPerMillion, $OutputPerMillion) -ForegroundColor Green
    }
    Write-Host ("  price book now holds {0} model(s): {1}" -f $models.Keys.Count, $priceBookPath) -ForegroundColor DarkGray
} else {
    Write-Host '  not priced - usage will report as $0. Re-run without -SkipPrice to fix that.' -ForegroundColor Yellow
}

# --- tiers -----------------------------------------------------------------

if ($ApimName) {
    $targets = if ($Tier -eq 'both') { @('standard', 'premium') } else { @($Tier) }
    foreach ($t in $targets) {
        $id = "models-$t"
        $current = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id
        $items = @(([string]$current).Trim(',') -split ',' | Where-Object { $_ })
        if ($items -contains $Model) {
            Write-Host "  $id already allows $Model" -ForegroundColor DarkGray
            continue
        }
        $items += $Model
        Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id -Value (',' + ($items -join ',') + ',')
        Write-Host ("  {0}: {1} model(s) -> {2}" -f $id, $items.Count, ($items -join ', ')) -ForegroundColor Green
    }
} else {
    Write-Host '  -ApimName not given, so no tier was changed. The model is priced but not callable.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  What developers change' -ForegroundColor Cyan
Write-Host "    The model name, and nothing else. Their gateway URL, token and"
Write-Host "    settings are unchanged:"
Write-Host ''
Write-Host "      claude --model $Model" -ForegroundColor White
Write-Host ''
Write-Host '    If managed settings pin availableModels, add it there too -' -ForegroundColor DarkGray
Write-Host '    ./scripts/New-ClaudeCodePolicy.ps1 -AvailableModels ... - or the' -ForegroundColor DarkGray
Write-Host '    client will hide a model the gateway is willing to serve.' -ForegroundColor DarkGray
Write-Host ''

exit 0
