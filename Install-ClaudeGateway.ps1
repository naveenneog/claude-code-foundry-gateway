<#
.SYNOPSIS
    Interactive end-to-end setup for the Claude on Foundry governed gateway.

.DESCRIPTION
    One command that walks an administrator through the whole build: picks the
    subscription and Foundry account, collects every budget with a sensible
    default already filled in, deploys the gateway, creates the Entra tier
    groups, syncs entitlement, verifies the controls, and writes an onboarding
    package to hand to developers.

    Every prompt has a default. Pressing Enter throughout produces a working,
    sensibly-governed deployment, so the fast path is Enter-Enter-Enter and the
    slow path is available when it matters.

    Nothing is created until the summary is confirmed.

    Re-runnable. Existing resources are detected and reused rather than
    duplicated, so this doubles as the way to change budgets later.

.EXAMPLE
    ./Install-ClaudeGateway.ps1

.EXAMPLE
    # unattended, taking every default
    ./Install-ClaudeGateway.ps1 -FoundryAccount ai-contoso -Yes

.EXAMPLE
    ./Install-ClaudeGateway.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId,
    [string]$FoundryAccount,
    [string]$FoundryResourceGroup,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$NamePrefix,
    [string]$PublisherEmail,
    [ValidateSet('BasicV2', 'StandardV2', 'PremiumV2')]
    [string]$Sku,

    [int]$TpmStandard,
    [int]$QuotaStandard,
    [int]$TpmPremium,
    [int]$QuotaPremium,
    [int]$QuotaOrg,
    [int]$CallsPerMinute,

    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',

    # How developers sign in. Written into claude-gateway.json and honoured by
    # Onboard-ClaudeDeveloper.ps1; it configures nothing on this machine.
    [ValidateSet('interactive', 'device', 'helper')]
    [string]$AuthMode,

    # The organisation details Anthropic requires on a Claude deployment. Only
    # used when the subscription has no Claude deployment to copy them from.
    [string]$ModelOrganizationName,
    [string]$ModelIndustry,
    [ValidatePattern('^[A-Za-z]{2}$')]
    [string]$ModelCountryCode,

    [switch]$ChooseFinOps,

    # Accept every default without prompting.
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# An az call for something that may not exist yet. az reports that on stderr,
# and Windows PowerShell 5.1 turns stderr into a NativeCommandError even under
# 2>$null - which, with ErrorActionPreference Stop, ends the script. Measured
# 2026-09-23: reading a new gateway's revocation window stopped the wizard on
# 5.1 with ResourceNotFound. Returns the output, or $null when az failed.
function Invoke-AzOptional([scriptblock]$Command) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Command 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    }
    catch { return $null }
    finally { $ErrorActionPreference = $saved }
}

# ------------------------------------------------------------------ output

function Write-Head($t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host " $t" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}
function Write-Step($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok($t)   { Write-Host "    [OK]   $t" -ForegroundColor Green }
function Write-Warn2($t){ Write-Host "    [WARN] $t" -ForegroundColor Yellow }
function Write-Bad($t)  { Write-Host "    [FAIL] $t" -ForegroundColor Red }
function Write-Note($t) { Write-Host "    $t" -ForegroundColor DarkGray }

# Prompt with a default already in place. Enter accepts it.
function Read-Default {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [string]$Help,
        [scriptblock]$Validate
    )
    if ($Yes) { return $Default }

    while ($true) {
        if ($Help) { Write-Host "    $Help" -ForegroundColor DarkGray }
        $shown = if ($Default) { " [$Default]" } else { '' }
        Write-Host "    $Prompt$shown" -NoNewline -ForegroundColor White
        Write-Host ': ' -NoNewline
        $answer = Read-Host
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if ([string]::IsNullOrWhiteSpace($answer)) { Write-Warn2 'A value is required.'; continue }
        if ($Validate -and -not (& $Validate $answer)) { continue }
        return $answer
    }
}

function Read-Int {
    param([string]$Prompt, [int]$Default, [string]$Help)
    $v = Read-Default -Prompt $Prompt -Default "$Default" -Help $Help -Validate {
        param($x)
        if ($x -as [int]) { return $true }
        Write-Warn2 'Enter a whole number.'
        return $false
    }
    return [int]$v
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    if ($Yes) { return $Default }
    $d = if ($Default) { 'Y/n' } else { 'y/N' }
    Write-Host "    $Prompt [$d]" -NoNewline -ForegroundColor White
    Write-Host ': ' -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a -match '^y'
}

# --------------------------------------------------------------- 0. sign-in

. (Join-Path $root 'scripts/Show-Banner.ps1')
Show-ClaudeBanner -Subtitle 'Governed gateway for Claude on Microsoft Foundry'

Write-Host ' Every prompt has a default. Press Enter to accept it.' -ForegroundColor DarkGray
Write-Host ' Nothing is created until you confirm the summary.' -ForegroundColor DarkGray
# Fail here, with a remedy, rather than part-way through a deployment.
. (Join-Path $root 'scripts/Test-Prerequisites.ps1')
. (Join-Path $root 'scripts/ClaudeModelDeployment.ps1')
if (-not (Test-ClaudePrerequisites -Mode Admin)) { return }

Write-Step 'Azure sign-in'
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Write-Warn2 'Not signed in. Launching az login.'
    az login -o none
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw 'Sign-in failed.' }
}
Write-Ok "$($acct.user.name)"
Write-Note "tenant $($acct.tenantId)"

if (-not $SubscriptionId) {
    # Listing every subscription is unusable on a large tenant - this account
    # can see 86 of them. Offer the current one first, which is nearly always
    # right, and only go looking if it is not.
    $currentName = $acct.name
    if ($Yes -or (Read-YesNo "Use subscription '$currentName'?" $true)) {
        $SubscriptionId = $acct.id
    }
    else {
        $subs = az account list --query "[].{name:name, id:id, state:state}" -o json |
            ConvertFrom-Json |
            Where-Object { $_.state -eq 'Enabled' }
        $subs = @($subs)
        Write-Host ''
        $filter = Read-Default -Prompt 'Filter by name (blank for all)' -Default '' `
            -Help "$($subs.Count) subscriptions available."
        $shown = if ($filter) { @($subs | Where-Object { $_.name -like "*$filter*" }) } else { $subs }

        if ($shown.Count -eq 0) { Write-Warn2 "Nothing matched '$filter'."; $shown = $subs }
        if ($shown.Count -gt 25) {
            Write-Warn2 "$($shown.Count) matches - showing the first 25. Filter more narrowly to see others."
            $shown = $shown[0..24]
        }

        Write-Host ''
        $i = 1
        foreach ($s in $shown) { Write-Host ("      {0,2}. {1}" -f $i, $s.name); $i++ }
        Write-Host ''
        $pick = Read-Default -Prompt 'Subscription number' -Default '1' -Validate {
            param($x)
            if (($x -as [int]) -and [int]$x -ge 1 -and [int]$x -le $shown.Count) { return $true }
            Write-Warn2 "Enter a number between 1 and $($shown.Count)."
            return $false
        }
        $SubscriptionId = $shown[[int]$pick - 1].id
    }
}
az account set --subscription $SubscriptionId
$subName = (az account show --query name -o tsv)
Write-Ok "subscription: $subName"

# ------------------------------------------------------- 1. Foundry account

Write-Step 'Foundry account'
if (-not $FoundryAccount) {
    Write-Note 'Looking for accounts with a Claude deployment...'

    # NOTE ON --query AND WINDOWS POWERSHELL 5.1
    #
    # az is a .cmd shim. PowerShell 5.1 only wraps an argument in quotes when it
    # contains a space, so a JMESPath with no spaces reaches cmd.exe bare and cmd
    # re-parses it. "[?contains(name,'claude')].name" therefore dies with
    #     ].name was unexpected at this time
    # because cmd sees the parentheses. PowerShell 7 quotes differently, which is
    # why this only ever showed up for 5.1 users.
    #
    # Keep JMESPath here free of ( ) | & < > ^ and filter in PowerShell instead.
    # Brackets and braces alone are fine.
    $accounts = az cognitiveservices account list --query "[].{name:name, rg:resourceGroup, loc:location, kind:kind}" -o json |
        ConvertFrom-Json
    $accounts = @($accounts | Where-Object { $_.kind -eq 'AIServices' -or $_.kind -eq 'OpenAI' })

    if ($accounts.Count -eq 0) {
        Write-Bad 'No AIServices or OpenAI accounts found in this subscription.'
        throw 'No candidate Foundry account.'
    }
    Write-Note "checking $($accounts.Count) candidate account(s)..."

    $withClaude = @()
    foreach ($a in $accounts) {
        $names = az cognitiveservices account deployment list -g $a.rg -n $a.name --query "[].name" -o tsv 2>$null
        $deps = @($names | Where-Object { $_ -like '*claude*' })
        if ($deps.Count -gt 0) {
            $withClaude += [pscustomobject]@{ Name = $a.name; Rg = $a.rg; Loc = $a.loc; Models = ($deps -join ', ') }
        }
    }

    if ($withClaude.Count -eq 0) {
        # The gateway cannot create a model, but this installer is already
        # signed in to the subscription where one could be created, so stopping
        # here sends the operator away to do by hand what it could do now.
        Write-Note 'No Foundry account in this subscription has a Claude deployment yet.'
        Write-Host ''
        $i = 1
        foreach ($a in $accounts) { Write-Host ("      {0,2}. {1,-34} {2}" -f $i, $a.name, $a.loc); $i++ }
        Write-Host ''
        $pick = if ($accounts.Count -eq 1) { '1' } else { Read-Default -Prompt 'Deploy a model into which account' -Default '1' }
        $target = $accounts[[int]$pick - 1]

        $offer = @(Get-DeployableClaudeModel -Account $target.name -ResourceGroup $target.rg)
        if (-not $offer.Count) {
            Write-Bad "No Claude model is available to deploy on $($target.name) in $($target.loc)."
            Write-Note 'Claude is not offered in every region. Create a Foundry account in a region that has it,'
            Write-Note 'then run this again: az cognitiveservices account list-models -n <account> -g <rg> -o table'
            throw 'No deployable Claude model.'
        }

        Write-Host ''
        $i = 1
        foreach ($m in $offer) {
            # Where it is hosted is shown because it is not obvious from the
            # version and it is what a data protection review asks: the same
            # model can be published as Azure-hosted and Anthropic-hosted.
            $where = if ($m.hostedOn) { "hosted on $($m.hostedOn)" } else { '' }
            Write-Host ("      {0,2}. {1,-22} v{2,-12} {3,-16} {4}" -f $i, $m.model, $m.version, $m.sku, $where); $i++
        }
        Write-Host ''
        $mp = Read-Default -Prompt 'Model number' -Default '1'
        $chosen = $offer[[int]$mp - 1]
        $cap = Read-Default -Prompt 'Capacity (thousands of tokens per minute)' -Default "$($chosen.defaultUnits)" `
            -Help 'Raise it later without redeploying the gateway. Too high fails on quota.'

        # Anthropic requires the organisation's details on every Claude
        # deployment, and Azure refuses one without them. This branch runs only
        # when the subscription has no Claude deployment at all, so there is
        # nothing to copy them from and they have to be asked - once. Every later
        # deployment copies them from this one.
        $providerData = Get-ClaudeProviderData -Account $target.name -ResourceGroup $target.rg
        if (-not $providerData) {
            Write-Host ''
            Write-Note 'Anthropic asks for three details the first time Claude is deployed in a subscription.'
            Write-Note 'They are recorded on the deployment and copied from it after this.'
            $org = if ($ModelOrganizationName) { $ModelOrganizationName } else {
                Read-Default -Prompt 'Organisation name' -Default '' -Validate {
                    param($x)
                    if ($x.Trim()) { return $true }
                    Write-Warn2 'The organisation name is required.'
                    return $false
                }
            }
            $industry = if ($ModelIndustry) { $ModelIndustry } else { Read-Default -Prompt 'Industry' -Default 'technology' }
            $country = if ($ModelCountryCode) { $ModelCountryCode } else {
                Read-Default -Prompt 'Country (two-letter code)' -Default 'US' -Validate {
                    param($x)
                    if ($x -match '^[A-Za-z]{2}$') { return $true }
                    Write-Warn2 'Two letters, for example US, CA or GB.'
                    return $false
                }
            }
            if (-not "$org".Trim()) {
                throw 'Claude deployment needs an organisation name. Pass -ModelOrganizationName for an unattended install.'
            }
            $providerData = @{ organizationName = "$org".Trim(); industry = "$industry".Trim(); countryCode = "$country".Trim().ToUpper() }
        }

        Write-Note "deploying $($chosen.model) to $($target.name)..."
        $made = New-ClaudeDeployment -Account $target.name -ResourceGroup $target.rg `
            -Model $chosen.model -Version $chosen.version -Sku $chosen.sku -Capacity ([int]$cap) -ProviderData $providerData
        Write-Ok "deployed $(Format-ClaudeDeployment $made)"

        $withClaude += [pscustomobject]@{ Name = $target.name; Rg = $target.rg; Loc = $target.loc; Models = $made.name }
    }

    Write-Host ''
    $i = 1
    foreach ($c in $withClaude) { Write-Host ("      {0,2}. {1,-34} {2,-14} {3}" -f $i, $c.Name, $c.Loc, $c.Models); $i++ }
    Write-Host ''
    $pick = if ($withClaude.Count -eq 1) { '1' } else { Read-Default -Prompt 'Account number' -Default '1' }
    $sel = $withClaude[[int]$pick - 1]
    $FoundryAccount = $sel.Name
    $FoundryResourceGroup = $sel.Rg
    if (-not $Location) { $Location = $sel.Loc }
}
if (-not $FoundryResourceGroup) {
    # Same guard as the shell version: an az call that fails silently leaves
    # these empty and the deployment then fails with something far less
    # obvious than "I could not find your account".
    $FoundryResourceGroup = @(
        az cognitiveservices account list --query "[].{n:name, rg:resourceGroup}" -o json |
            ConvertFrom-Json |
            Where-Object { $_.n -eq $FoundryAccount }
    )[0].rg
}
if (-not $FoundryResourceGroup) {
    Write-Bad "Could not resolve the resource group for '$FoundryAccount'."
    Write-Note 'Check the name and that you can see it: az cognitiveservices account list -o table'
    Write-Note 'Or pass -FoundryResourceGroup explicitly.'
    throw 'Foundry resource group not resolved.'
}
Write-Ok "$FoundryAccount (rg $FoundryResourceGroup)"

# ------------------------------------------------- 1b. which models to allow
#
# The tier allow lists are what the gateway enforces, so they have to come from
# what is actually deployed. Hard-coding them produces a gateway that allowlists
# a model the account does not serve, and the developer sees a refusal naming a
# model that looks correct.
$deployed = @(Get-ClaudeDeployment -Account $FoundryAccount -ResourceGroup $FoundryResourceGroup)
$modelsStd = ''
$modelsPrm = ''
if ($deployed.Count) {
    Write-Step 'Which models each tier may call'
    Write-Host ''
    $i = 1
    foreach ($d in $deployed) { Write-Host ("      {0,2}. {1}" -f $i, (Format-ClaudeDeployment $d)); $i++ }
    Write-Host ''

    # Premium gets everything. Standard gets everything except Opus, which is
    # five times the price of Sonnet per output token - that is the distinction
    # the two tiers exist to make. Both are editable afterwards with
    # Set-ClaudeCapability.ps1, so this only has to be a sensible start.
    $all = @($deployed.name | Sort-Object -Unique)
    $nonOpus = @($deployed | Where-Object { $_.model -notlike '*opus*' } | ForEach-Object { $_.name } | Sort-Object -Unique)
    if (-not $nonOpus.Count) { $nonOpus = $all }

    $stdPick = Read-Default -Prompt 'Models for the standard tier' -Default ($nonOpus -join ',') `
        -Help 'Comma-separated deployment names. Opus is left out by default because it costs five times Sonnet per output token.'
    $prmPick = Read-Default -Prompt 'Models for the premium tier' -Default ($all -join ',') `
        -Help 'Comma-separated deployment names.'

    $modelsStd = ',' + (($stdPick -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ',') + ','
    $modelsPrm = ',' + (($prmPick -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ',') + ','
    Write-Ok "standard $modelsStd  premium $modelsPrm"
}
else {
    Write-Note "no Claude deployment visible on $FoundryAccount - leaving both tier model lists empty"
}

# ------------------------------------------------------------- 2. placement

Write-Step 'Where to put the gateway'
if (-not $Location) { $Location = az cognitiveservices account show -g $FoundryResourceGroup -n $FoundryAccount --query location -o tsv }
if (-not $Location) {
    Write-Bad "Could not resolve the location of '$FoundryAccount'."
    Write-Note 'Pass -Location explicitly.'
    throw 'Location not resolved.'
}
$ResourceGroup = if ($ResourceGroup) { $ResourceGroup } else {
    Read-Default -Prompt 'Resource group' -Default $FoundryResourceGroup `
        -Help 'Created if it does not exist. Same region as Foundry keeps latency down.'
}
$Location = Read-Default -Prompt 'Location' -Default $Location

# ------------------------------------------------- reuse an existing gateway
#
# API Management is the entire cost of this accelerator - about $150/month at list price
# for BasicV2 - and creating a second one by accident is easy to do and easy to
# miss. Earlier versions always generated a random name prefix, so every run
# built a new instance even when a perfectly good one already existed.
#
# Only v2 SKUs are offered. Classic tiers attach the policies happily but meter
# zero Anthropic tokens, so every budget silently reads as zero usage.

$ExistingApim = ''
if (-not $NamePrefix) {
    $allApim = az apim list -o json 2>$null | ConvertFrom-Json
    $reusable = @($allApim | Where-Object { $_.sku.name -match 'V2$' })

    if ($reusable.Count) {
        Write-Host ''
        Write-Host '    Existing v2 API Management instances you can reuse:' -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $reusable.Count; $i++) {
            $r = $reusable[$i]
            $has = az apim api list -g $r.resourceGroup --service-name $r.name --query "[?name=='claude-foundry'].name" -o tsv 2>$null
            $note = if ($has) { 'already has the Claude API - this would update it' } else { 'would add the Claude API' }
            Write-Host ("       {0}. {1,-24} {2,-10} {3,-14} {4}" -f ($i + 1), $r.name, $r.sku.name, $r.location, $r.resourceGroup) -ForegroundColor White
            Write-Host ("          {0}" -f $note) -ForegroundColor DarkGray
        }
        Write-Host ("       {0}. create a new one" -f ($reusable.Count + 1)) -ForegroundColor White
        Write-Host ''

        $pick = Read-Default -Prompt 'Which' -Default ([string]($reusable.Count + 1)) `
            -Help 'Reusing avoids a second API Management bill. The Claude API, policies and named values are added to it.' -Validate {
                param($x)
                $n = 0
                if ([int]::TryParse($x, [ref]$n) -and $n -ge 1 -and $n -le ($reusable.Count + 1)) { return $true }
                Write-Warn2 "Enter a number between 1 and $($reusable.Count + 1)."
                return $false
            }

        if ([int]$pick -le $reusable.Count) {
            $chosen = $reusable[[int]$pick - 1]
            $ExistingApim = $chosen.name
            # The children are parented to the APIM, so the deployment has to
            # target its resource group, not whatever was answered above.
            if ($ResourceGroup -ne $chosen.resourceGroup) {
                Write-Note "Deploying into '$($chosen.resourceGroup)' instead - that is where $($chosen.name) lives."
                $ResourceGroup = $chosen.resourceGroup
            }
            $Location = $chosen.location
            $Sku      = $chosen.sku.name
            $PublisherEmail = $chosen.publisherEmail
            # Stable, so re-running does not create a fresh Application Insights
            # and Log Analytics workspace every time.
            $NamePrefix = ($chosen.name -replace '^apim-', '')
            Write-Ok "reusing $($chosen.name) ($($chosen.sku.name), $($chosen.resourceGroup))"

            if ($chosen.identity.type -and $chosen.identity.type -notmatch 'SystemAssigned') {
                Write-Warn2 "$($chosen.name) has identity '$($chosen.identity.type)'. Deploying sets SystemAssigned, which the gateway needs to call Foundry."
            }
        }
    }
}

# No pre-flight check on v2 SKU availability. There is no reliable CLI call for
# it - an earlier version used `az apim list-skus`, which does not exist, so the
# error text landed in the variable and the script warned that East US 2 lacked
# v2 support while a BasicV2 instance was running there. A check that invents a
# warning is worse than no check.
#
# The deployment itself is the authority: if the SKU is unavailable in the
# region it fails immediately and says so.

$Sku = if ($Sku) { $Sku }
elseif ($ExistingApim) {
    # Reusing an instance means its SKU is already decided. Asking how many
    # developers there are and which tier to buy, when neither answer can
    # change anything, is a question with no effect - and it shifted every
    # later answer in the scripted reuse path by one.
    $existingSku = az apim show -g $ResourceGroup -n $ExistingApim --query "sku.name" -o tsv 2>$null
    if (-not $existingSku) { $existingSku = 'BasicV2' }
    Write-Note "reusing $ExistingApim, which is $existingSku - SKU not asked"
    $existingSku.Trim()
}
else {
    # Sizing by developer count, using the only figure Microsoft actually
    # publishes for v2. There is no documented requests-per-second per unit -
    # the guidance is to load test - so a recommendation built on an invented
    # RPS number would be a guess wearing a table's clothes. Included monthly
    # request volume is published, so that is what the arithmetic uses.
    #
    #   Basic v2     10M requests/month, up to 10 units, no VNet, no zones
    #   Standard v2  50M requests/month, up to 10 units, VNet, zones
    #   Premium v2   unlimited,          up to 30 units, VNet injection, zones
    #   - https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview
    $devs = Read-Default -Prompt 'How many developers will use this gateway' -Default '50' `
        -Help 'Used to suggest a SKU, and to cost the choices below at your scale. You can override the suggestion.'
    $n = 0
    if (-not [int]::TryParse($devs, [ref]$n) -or $n -lt 1) { $n = 50 }
    $script:DeveloperEstimate = $n

    # Whether the entitlement store can hold that many at all.
    #
    # The SKU arithmetic above is about request volume, and volume is almost
    # never what stops this. Identities are held in API Management named values,
    # which cap at 4,096 characters; an object id plus its separator costs 37, so
    # a list holds about 110 and the business unit map - whose entries are longer
    # - binds first at roughly 93.
    #
    # Derived here rather than pasted, on the same two measured constants
    # Measure-ClaudeCeiling.ps1 uses. There is no gateway to measure yet, which
    # is exactly why this has to be said before one is built rather than after.
    #
    # Without this the installer took "5000 developers", recommended a SKU,
    # deployed happily, and the wall arrived weeks later as a sync refusing to
    # write a named value - by which time the gateway was in production.
    $maxChars = 4096
    $oidCost = 37
    $listCeiling = [int][math]::Floor(($maxChars - 1) / $oidCost)
    $buCeiling = [int][math]::Floor(($maxChars - 1) / 44)

    if ($n -gt $buCeiling) {
        Write-Host ''
        Write-Warn2 ("This holds about {0} developers today, and you said {1}." -f $buCeiling, $n)
        Write-Host ''
        Write-Host '      Entitlement lives in API Management named values, which cap at 4,096' -ForegroundColor DarkGray
        Write-Host ("      characters. A tier list holds about {0} object ids; the business unit" -f $listCeiling) -ForegroundColor DarkGray
        Write-Host ("      map holds about {0}, and it runs out first. This is a storage limit," -f $buCeiling) -ForegroundColor DarkGray
        Write-Host '      not a licensing one, and raising the SKU does not move it - a larger' -ForegroundColor DarkGray
        Write-Host '      tier raises how many named values exist, not how long each one may be.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '      The store that removes this limit is designed, costed and measured,' -ForegroundColor DarkGray
        Write-Host '      and is not built yet - see docs/SCALE.md and docs/adr/0011.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '      Deploying now is still reasonable: the gateway works, and the move to' -ForegroundColor DarkGray
        Write-Host '      the larger store is a configuration change rather than a redeployment.' -ForegroundColor DarkGray
        Write-Host ("      But you will be able to entitle about {0} people, not {1}, and the" -f $buCeiling, $n) -ForegroundColor DarkGray
        Write-Host '      sync will refuse the rest rather than silently dropping them.' -ForegroundColor DarkGray
        Write-Host ''

        $goOn = Read-Default -Prompt 'Continue anyway (yes/no)' -Default 'yes' `
            -Help 'yes deploys a gateway that serves the first ~93 and refuses to add more.' -Validate {
                param($x)
                if ($x -in @('yes','no')) { return $true }
                Write-Warn2 'Must be yes or no.'
                return $false
            }
        if ($goOn -eq 'no') { throw 'Stopped before deploying. Nothing was created.' }
    }

    # A deliberately generous assumption. Claude Code is chatty - a session is
    # many calls - so 500 a day per developer errs towards recommending more
    # rather than less, and the arithmetic is shown so it can be argued with.
    $perDevPerDay = 500
    $monthly = [long]$n * $perDevPerDay * 22

    Write-Host ''
    Write-Host ("      {0:n0} developers x {1} requests/day x 22 days = {2:n0} requests/month" -f $n, $perDevPerDay, $monthly) -ForegroundColor DarkGray
    Write-Host ("      Basic v2 includes 10,000,000 and Standard v2 50,000,000." -f $monthly) -ForegroundColor DarkGray

    # Volume rarely decides it, and saying so is more useful than a table that
    # implies it does. Basic v2 covers roughly 900 developers on this
    # assumption; what actually moves an enterprise off it is the absence of
    # VNet integration and availability zones.
    $suggested =
        if ($monthly -gt 50000000) { 'PremiumV2' }
        elseif ($monthly -gt 10000000) { 'StandardV2' }
        else { 'BasicV2' }

    Write-Host ''
    if ($suggested -eq 'BasicV2') {
        Write-Host '      Volume alone suggests BasicV2. Choose StandardV2 anyway if you need the' -ForegroundColor DarkGray
        Write-Host '      gateway inside a VNet or spread across availability zones - BasicV2 has' -ForegroundColor DarkGray
        Write-Host '      neither, and that is what usually decides this rather than request count.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ("      {0} suggested on volume. It also brings VNet integration and zones." -f $suggested) -ForegroundColor DarkGray
    }
    Write-Host ''

    Read-Default -Prompt 'API Management SKU' -Default $suggested `
        -Help 'Must be a v2 tier. Classic tiers attach the policies but meter zero Anthropic tokens, so budgets never trigger.' -Validate {
            param($x)
            if ($x -in @('BasicV2','StandardV2','PremiumV2')) { return $true }
            Write-Warn2 'Must be BasicV2, StandardV2 or PremiumV2.'
            return $false
        }
}

# How reversible that choice was. Learn documents upgrade and downgrade between
# Basic v2 and Standard v2 only, with no gateway downtime and no change of
# address. Premium v2 is not a documented in-place target from either, so
# reaching it means a new instance - which is survivable only if developers were
# never configured against the instance hostname. See ADR-0013.
Write-Host ''
if ($Sku -in @('BasicV2', 'StandardV2')) {
    Write-Note "$Sku can be changed later: BasicV2 and StandardV2 upgrade and downgrade in place,"
    Write-Note 'with no downtime and no change of address. Moving beyond StandardV2 cannot.'
} else {
    Write-Note "$Sku is effectively a one-time pick: it is not a documented in-place target,"
    Write-Note 'so changing tier later means a new instance and a new gateway address.'
}

# Already fixed when reusing - the name is the existing instance's.
$NamePrefix = if ($NamePrefix) { $NamePrefix } else {
    Read-Default -Prompt 'Name prefix' -Default "claudegw$(Get-Random -Minimum 100000 -Maximum 999999)" `
        -Help 'API Management names are globally unique DNS labels.'
}

$PublisherEmail = if ($PublisherEmail) { $PublisherEmail } else {
    Read-Default -Prompt 'Publisher email' -Default $acct.user.name -Help 'Shown on the API Management instance.'
}

# ------------------------------------------------- 1c. governance choices
#
# These were a page of documentation and an operator was expected to read it,
# decide, and then come back and set named values by hand. They are asked here
# instead, with the cost of each option computed at the developer count given
# above rather than quoted from a table written for somebody else's scale.

Write-Head 'Choices'

$devCount = if ($script:DeveloperEstimate) { $script:DeveloperEstimate } else { 50 }

# Revocation window. The gateway holds an entitlement answer rather than asking
# on every request, so someone removed from the directory keeps working for up
# to this long. Shorter is safer and costs more, because cost follows cache
# misses. The figures come from the shipped cost model so there is one source.
$windows = @(
    @{ Label = 'Immediate - no caching at all'; Minutes = 0 }
    @{ Label = '15 minutes';                    Minutes = 15 }
    @{ Label = '1 hour';                        Minutes = 60 }
    @{ Label = '4 hours';                       Minutes = 240 }
)
Write-Host ''
Write-Host "  If you remove someone, how long may they keep working?" -ForegroundColor White
Write-Host "  Costed for $devCount developer(s), once the projection is in use." -ForegroundColor DarkGray
Write-Host ''
foreach ($w in $windows) {
    if ($w.Minutes -eq 0) {
        Write-Host ("    {0,-32} not supported - every request would call the resolver," -f $w.Label) -ForegroundColor DarkGray
        Write-Host ("    {0,-32} which is a dependency on its uptime for every call" -f '') -ForegroundColor DarkGray
        continue
    }
    $c = $null
    try {
        $c = & (Join-Path $PSScriptRoot 'scripts/Measure-ClaudeProjectionCost.ps1') `
                -Developers $devCount -CacheMinutes $w.Minutes -AsJson 2>$null 6>$null |
             Out-String | ConvertFrom-Json
    } catch { }
    if ($c) {
        Write-Host ("    {0,-32} `${1,-8} per month" -f $w.Label, $c.monthly_usd.total) -ForegroundColor DarkGray
    } else {
        Write-Host ("    {0,-32} (cost model unavailable)" -f $w.Label) -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '    Most of that bills at rest - the private endpoints, their DNS zones and a' -ForegroundColor DarkGray
Write-Host '    warm resolver instance - whether anyone calls the resolver or not.' -ForegroundColor DarkGray
Write-Host '    Shortening the window moves only the rest.' -ForegroundColor DarkGray

# A re-run used to reset this. The prompt's answer always won over the value
# read back from the gateway, so every re-run deployed
# entitlementCacheSeconds=3600 - measured on three consecutive re-runs,
# 2026-09-23 - and a gateway set to a shorter window went back to an hour
# without anyone choosing it. This is how long a removed developer keeps
# working, so it is kept when the gateway already has one, and said so.
$windowTarget = if ($ExistingApim) { $ExistingApim } else { "apim-$NamePrefix" }
$liveWindow = Invoke-AzOptional { az apim nv show -g $ResourceGroup --service-name $windowTarget --named-value-id entitlement-cache-seconds --query value -o tsv }
$liveWindowSeconds = 0
if ($liveWindow -and [int]::TryParse("$liveWindow".Trim(), [ref]$liveWindowSeconds) -and $liveWindowSeconds -gt 0) {
    $entitlementCacheSeconds = $liveWindowSeconds
    Write-Host ''
    Write-Host ("    Keeping this gateway's revocation window: {0} seconds." -f $liveWindowSeconds) -ForegroundColor Green
    Write-Host ("    Change it with: Set-ApimNamedValue -ResourceGroup {0} -ApimName {1} -Id entitlement-cache-seconds -Value <seconds>" -f $ResourceGroup, $windowTarget) -ForegroundColor DarkGray
}
else {
    $revoke = Read-Default -Prompt 'Revocation window in minutes' -Default '60' `
        -Help 'Applies once you move to the projection. Changeable later with one command.' -Validate {
            param($x)
            $v = 0
            if ([int]::TryParse($x, [ref]$v) -and $v -ge 60 -and $v -le 1440) { return $true }
            Write-Warn2 'Between 60 and 1440 minutes. Below an hour the resolver becomes a per-request dependency.'
            return $false
        }
    $entitlementCacheSeconds = [int]$revoke * 60
}

# What a team budget does when it is reached.
Write-Host ''
Write-Host '  When a team reaches its budget, what should happen?' -ForegroundColor White
Write-Host ''
Write-Host '    report     the budget is reported and nothing is blocked. Deploys the' -ForegroundColor DarkGray
Write-Host '               per-team counter and the chargeback workbook only.' -ForegroundColor DarkGray
Write-Host '    stop       the same, plus the gateway refuses the team once the monthly' -ForegroundColor DarkGray
Write-Host '               token figure is reached. Deploys the quota policy as enforcing.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    Worth knowing before choosing stop: the counter cannot see cached tokens,' -ForegroundColor DarkGray
Write-Host '    and on measured usage cache was the majority of real cost. A stop set from' -ForegroundColor DarkGray
Write-Host '    a dollar figure therefore triggers far later than the dollars suggest.' -ForegroundColor DarkGray

$budgetMode = Read-Default -Prompt 'Team budget behaviour (report/stop)' -Default 'report' `
    -Help 'Either way the spend is attributed. This chooses whether it also refuses.' -Validate {
        param($x)
        if ($x -in @('report','stop')) { return $true }
        Write-Warn2 'Must be report or stop.'
        return $false
    }

# Whether somebody with no team may use it at all.
Write-Host ''
Write-Host '  May a developer with no team assigned use the gateway?' -ForegroundColor White
Write-Host ''
Write-Host '    allow      they are served, and their spend is recorded against no team.' -ForegroundColor DarkGray
Write-Host '    deny       they are refused until somebody assigns them.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    Start on allow unless every developer already has a team. deny on day one' -ForegroundColor DarkGray
Write-Host '    refuses people who have done nothing wrong.' -ForegroundColor DarkGray

$unassignedMode = Read-Default -Prompt 'Developers with no team (allow/deny)' -Default 'allow' `
    -Help 'Get-ClaudeBusinessUnit.ps1 reports how many are unassigned, so you can switch this when it reaches zero.' -Validate {
        param($x)
        if ($x -in @('allow','deny')) { return $true }
        Write-Warn2 'Must be allow or deny.'
        return $false
    }

# The address developers are configured against. This one cannot be retrofitted
# cheaply, which is why it is asked rather than defaulted silently.
Write-Host ''
Write-Host '  What address will developers be configured against?' -ForegroundColor White
Write-Host ''
Write-Host ("    azure      https://{0}.azure-api.net/claude" -f $NamePrefix) -ForegroundColor DarkGray
Write-Host '               No extra cost, nothing to set up. The instance name is part of' -ForegroundColor DarkGray
Write-Host '               the address, so replacing the gateway later means reconfiguring' -ForegroundColor DarkGray
Write-Host '               every developer machine.' -ForegroundColor DarkGray
Write-Host '    custom     https://claude.<your-company>.com/claude' -ForegroundColor DarkGray
Write-Host '               Costs a DNS record and a certificate. Replacing the gateway' -ForegroundColor DarkGray
Write-Host '               later becomes a DNS change nobody notices.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    This is the one choice on this page that is expensive to change afterwards.' -ForegroundColor DarkGray

$addressMode = Read-Default -Prompt 'Developer address (azure/custom)' -Default 'azure' `
    -Help 'Choosing custom does not configure it here - it records the intent and prints the steps at the end.' -Validate {
        param($x)
        if ($x -in @('azure','custom')) { return $true }
        Write-Warn2 'Must be azure or custom.'
        return $false
    }

# How developers sign in. Asked here rather than left to each workstation,
# because a fleet where half the machines authenticate one way and half another
# is a fleet with two support paths and two sets of symptoms. It configures
# nothing now - it is written into claude-gateway.json and honoured by
# Onboard-ClaudeDeveloper.ps1 on each machine.
Write-Host ''
Write-Host '  How will developers sign in?' -ForegroundColor White
Write-Host ''
Write-Host '    interactive  az login opens a browser on the machine. The right default for' -ForegroundColor DarkGray
Write-Host '                 a laptop, and impossible on a jump box, VDI session or SSH.' -ForegroundColor DarkGray
Write-Host '    device       az login --use-device-code prints a code to enter in a browser' -ForegroundColor DarkGray
Write-Host '                 elsewhere. Works everywhere, including where no browser exists.' -ForegroundColor DarkGray
Write-Host '    helper       a credential helper script fetches the token on demand. Needed' -ForegroundColor DarkGray
Write-Host '                 for Claude Desktop, which cannot read the other two; the setup' -ForegroundColor DarkGray
Write-Host '                 installs it either way. Choose this to make it the route for' -ForegroundColor DarkGray
Write-Host '                 every client rather than only Desktop.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    Changeable later by reissuing the file and re-running the onboarding script.' -ForegroundColor DarkGray

$AuthMode = if ($AuthMode) { $AuthMode } else {
    Read-Default -Prompt 'Developer sign-in (interactive/device/helper)' -Default 'interactive' `
        -Help 'Pick device if any developer works on a machine with no browser - it costs nothing on a laptop.' -Validate {
            param($x)
            if ($x -in @('interactive','device','helper')) { return $true }
            Write-Warn2 'Must be interactive, device or helper.'
            return $false
        }
}

# ---------------------------------------------------------------- 3. limits

Write-Head 'Budgets'
Write-Host ''
Write-Host ' Applied per developer, keyed on their Entra object id.' -ForegroundColor DarkGray
Write-Host ' Changeable later without redeploying - these are APIM named values.' -ForegroundColor DarkGray
Write-Host ''

Write-Step 'Standard tier'
$TpmStandard   = if ($TpmStandard)   { $TpmStandard }   else { Read-Int 'Tokens per minute' 20000  'A busy chat session uses a few thousand. Agentic work uses far more.' }
$QuotaStandard = if ($QuotaStandard) { $QuotaStandard } else { Read-Int 'Tokens per day'    500000 'Roughly a full working day of steady use.' }

Write-Step 'Premium tier'
$TpmPremium   = if ($TpmPremium)   { $TpmPremium }   else { Read-Int 'Tokens per minute' 80000   'For heavy agentic use - Cowork and long Claude Code runs.' }
$QuotaPremium = if ($QuotaPremium) { $QuotaPremium } else { Read-Int 'Tokens per day'    5000000 '' }

Write-Step 'Organisation ceiling'
$QuotaOrg = if ($QuotaOrg) { $QuotaOrg } else {
    Read-Int 'Tokens per month, everyone combined' 100000000 'Total across all developers. The default is about one premium developer''s month, so raise it before a wider rollout.'
}

Write-Step 'Safety valve'
$CallsPerMinute = if ($CallsPerMinute) { $CallsPerMinute } else {
    Read-Int 'Requests per minute, per developer' 120 'Catches a runaway loop making many small calls.'
}

if ($TpmStandard -gt $TpmPremium) { Write-Warn2 'Standard tokens-per-minute is above premium. Intended?' }
if ($QuotaStandard -gt $QuotaPremium) { Write-Warn2 'Standard daily quota is above premium. Intended?' }
if ($QuotaOrg -lt $QuotaPremium) { Write-Warn2 'The monthly organisation ceiling is below one premium developer''s daily quota. One developer can exhaust it in a day.' }

# ---------------------------------------------------------------- 4. groups

Write-Step 'Entitlement groups'
Write-Note 'Membership of these Entra groups is what grants access.'
$StandardGroup = Read-Default -Prompt 'Standard tier group' -Default $StandardGroup
$PremiumGroup  = Read-Default -Prompt 'Premium tier group'  -Default $PremiumGroup

# --------------------------------------------------------------- 5. summary

$apimName = if ($ExistingApim) { $ExistingApim } else { "apim-$NamePrefix" }
Write-Head 'Summary'
Write-Host ''
$rows = [ordered]@{
    'Subscription'          = $subName
    'Foundry account'       = "$FoundryAccount (rg $FoundryResourceGroup)"
    'Gateway resource group'= $ResourceGroup
    'Location'              = $Location
    'API Management'        = if ($ExistingApim) { "$apimName  ($Sku)  REUSING - not creating" } else { "$apimName  ($Sku)  new" }
    'Publisher email'       = $PublisherEmail
    ''                      = ''
    'Standard tier'         = "$('{0:n0}' -f $TpmStandard) tokens/min, $('{0:n0}' -f $QuotaStandard) tokens/day"
    'Premium tier'          = "$('{0:n0}' -f $TpmPremium) tokens/min, $('{0:n0}' -f $QuotaPremium) tokens/day"
    'Organisation ceiling'  = "$('{0:n0}' -f $QuotaOrg) tokens/month, shared - soft cap"
    'Request ceiling'       = "$CallsPerMinute requests/min"
    ' '                     = ''
    'Entra groups'          = "$StandardGroup, $PremiumGroup"
    'Developer sign-in'     = $AuthMode
}
foreach ($k in $rows.Keys) {
    if ([string]::IsNullOrWhiteSpace($k)) { Write-Host '' ; continue }
    Write-Host ("  {0,-24} {1}" -f $k, $rows[$k])
}
Write-Host ''
if ($ExistingApim) {
    Write-Host "  Reusing $apimName - no new API Management, no new bill." -ForegroundColor Green
    Write-Host '  Adds the Claude API, its policies and named values. Takes a few minutes.' -ForegroundColor DarkGray
    Write-Host '  Its SKU, location and publisher details are re-asserted unchanged.' -ForegroundColor DarkGray
} else {
    # Priced for the SKU and region being created. This line used to say
    # 'BasicV2 is about $150/month' whatever was chosen, so a Premium v2
    # install in Canada Central - $2,800/month, measured 2026-09-23 - was
    # approved against a figure nineteen times too low.
    . (Join-Path $root 'scripts/AzureRetailPrice.ps1')
    $apimMeter = ($Sku -replace 'V2$', ' v2') + ' Unit'
    $apimPrice = $null
    try { $apimPrice = Get-AzureRetailPrice -ServiceName 'API Management' -Region $Location -MeterName $apimMeter } catch { $apimPrice = $null }
    if ($apimPrice) {
        $apimMonthly = ConvertTo-MonthlyPrice -HourlyPrice $apimPrice.UnitPrice
        Write-Host ("  Cost: API Management is the bulk of it - {0} in {1} is {2} {3:N0}/month at list price" -f $Sku, $Location, $apimPrice.Currency, $apimMonthly) -ForegroundColor DarkGray
        Write-Host ("        (one unit, 730 hours, Azure retail prices read {0})." -f $apimPrice.RetrievedUtc.Substring(0, 10)) -ForegroundColor DarkGray
    }
    else {
        Write-Host "  Cost: API Management is the bulk of it. The $Sku price in $Location could not be read" -ForegroundColor DarkGray
        Write-Host '        from the Azure retail prices API; check https://azure.microsoft.com/pricing/details/api-management/' -ForegroundColor DarkGray
    }
    Write-Host '  Provisioning takes minutes on the v2 tiers - a Premium v2 install measured 5.5 minutes end to end.' -ForegroundColor DarkGray
}
Write-Host ''

if ($WhatIfPreference) { Write-Warn2 'WhatIf - stopping before any change.'; return }
if (-not (Read-YesNo $(if ($ExistingApim) { 'Apply this to the existing gateway?' } else { 'Create these resources?' }) $true)) {
    Write-Host ''; Write-Host 'Cancelled.' -ForegroundColor Yellow; return
}

# ---------------------------------------------------------------- 6. deploy

Write-Head 'Deploying'

Write-Step 'Resource group'
# A resource group cannot be moved, and every resource below takes its location
# from the group - main.bicep defaults `location` to resourceGroup().location.
#
# The previous version ran `az group create` unconditionally and printed OK
# whatever happened. Against a group that already existed in another region that
# printed a red InvalidResourceGroupLocation error immediately followed by [OK],
# and then deployed the whole gateway into the group's region while -Location
# was quietly ignored. Nobody reading that output would know which region they
# had ended up in.
$rgLocation = az group show -n $ResourceGroup --query location -o tsv 2>$null
if ($rgLocation) {
    $rgLocation = $rgLocation.Trim()
    $same = ($rgLocation -replace '\s', '').ToLower() -eq ($Location -replace '\s', '').ToLower()
    if ($same) {
        Write-Ok "$ResourceGroup (exists, $rgLocation)"
    }
    else {
        Write-Ok "$ResourceGroup (exists)"
        Write-Warn2 "It is in '$rgLocation', not the '$Location' you asked for."
        Write-Note  "A resource group cannot be moved, and everything here takes its location from"
        Write-Note  "the group - so the gateway will be created in '$rgLocation' and -Location is"
        Write-Note  "ignored. Deploying into '$Location' means using a different group name."
    }
}
else {
    az group create -n $ResourceGroup -l $Location -o none
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create resource group '$ResourceGroup' in '$Location'. See the error above."
    }
    Write-Ok "$ResourceGroup (created in $Location)"
}

Write-Step $(if ($ExistingApim) { 'Claude API and policies (a few minutes)' } else { 'API Management and Application Insights (a few minutes)' })
Write-Note 'Safe to leave running.'

# Entitlement is owned by Sync-ClaudeAccess.ps1, not by this template. If the
# gateway already exists, read the current allow lists and hand them back, so a
# redeploy cannot reset them to empty and revoke everybody. `what-if` against
# the live gateway showed exactly that happening.
$allowStd = ''
$allowPrm = ''
$quotaOvr = ''
$buReg = ''
$buMem = ''
$buPar = ''
$usdBudgets = ''
$usdBudgetState = ''
if ($ExistingApim -or (Invoke-AzOptional { az apim show -g $ResourceGroup -n $apimName --query name -o tsv })) {
    . (Join-Path $PSScriptRoot 'scripts\ClaudeUsdBudgets.ps1')
    $usdSavedValues = Get-ClaudeUsdNamedValues -ResourceGroup $ResourceGroup -ApimName $apimName
    $usdBudgets = $usdSavedValues['usd-budgets']
    $usdBudgetState = $usdSavedValues['usd-budget-state']
    $allowStd = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id allow-standard --query value -o tsv 2>$null
    $allowPrm = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id allow-premium  --query value -o tsv 2>$null
    $quotaOvr = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id quota-overrides --query value -o tsv 2>$null
    # Business units, their membership and the parent map are owned by
    # Set-ClaudeBusinessUnit.ps1 and Sync-ClaudeAccess.ps1 after the first
    # deployment, exactly like entitlement above. Their template parameters
    # default to ',,', so leaving them out of this read does not preserve them -
    # it empties the registry and unassigns every developer on the next
    # redeploy.
    $buReg = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id bu-registry --query value -o tsv 2>$null
    $buModes = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id bu-modes --query value -o tsv 2>$null
    $buMem = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id bu-members  --query value -o tsv 2>$null
    $buPar = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id bu-parents  --query value -o tsv 2>$null
    # Which entitlement path this gateway is on. An operator who has migrated to
    # the projection has flipped this deliberately; a redeploy that did not read
    # it back would return them to the named-value lists silently, and those
    # lists stopped being maintained the moment they migrated. The developer
    # population would shrink to whatever was last written to them, with no
    # error anywhere. Same failure mode as the business unit registry above.
    $entSrc = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id entitlement-source --query value -o tsv 2>$null
    $entUrl = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id entitlement-resolver-url --query value -o tsv 2>$null
    $entAud = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id entitlement-resolver-audience --query value -o tsv 2>$null
    $entTtl = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id entitlement-cache-seconds --query value -o tsv 2>$null
    if (-not $allowStd) { $allowStd = '' }
    if (-not $allowPrm) { $allowPrm = '' }
    if (-not $quotaOvr) { $quotaOvr = '' }
    if (-not $buReg) { $buReg = '' }
    if (-not $buMem) { $buMem = '' }
    if (-not $buPar) { $buPar = '' }
    $keptStd = @($allowStd.Trim(',') -split ',' | Where-Object { $_ })
    $keptPrm = @($allowPrm.Trim(',') -split ',' | Where-Object { $_ })
    $keptOvr = @($quotaOvr.Trim(',') -split ',' | Where-Object { $_ })
    $keptBu  = @($buReg.Trim(',') -split ',' | Where-Object { $_ })
    $keptMem = @($buMem.Trim(',') -split ',' | Where-Object { $_ })
    if ($keptStd.Count -or $keptPrm.Count) {
        Write-Note "preserving entitlement: $($keptStd.Count) standard, $($keptPrm.Count) premium"
    }
    if ($keptOvr.Count) {
        Write-Note "preserving $($keptOvr.Count) per-user budget override(s)"
    }
    if ($keptBu.Count) {
        Write-Note "preserving $($keptBu.Count) business unit(s) and $($keptMem.Count) membership(s)"
    }
    if ($entSrc -eq 'projection') {
        Write-Note "preserving entitlement source: projection (resolver $entUrl)"
    }
}

$deployName = "claude-gw-$(Get-Date -Format 'yyyyMMddHHmmss')"

# The service's own network and portal state, read back for the same reason as
# the named values above. The template writes the service whenever it owns it,
# and an ARM PUT replaces what it does not state: a what-if against a Premium v2
# gateway with outbound VNet integration (2026-09-23) predicted
# virtualNetworkType External -> None, the subnet removed, publicNetworkAccess
# and customProperties dropped, and both portals switched on. A gateway made
# private would then fail every request after an ordinary re-run.
#
# Read over ARM at 2024-05-01 because az apim show does not return the portal
# fields, and passed as a parameter file because customProperties is an object
# and an inline JSON argument does not survive the az.cmd shim.
$preserveArgs = @()
$liveId = Invoke-AzOptional { az apim show -g $ResourceGroup -n $apimName --query id -o tsv }
if ($liveId) {
    $armToken = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    $live = $null
    try { $live = (Invoke-RestMethod -Uri "https://management.azure.com$($liveId.Trim())?api-version=2024-05-01" -Headers @{ Authorization = "Bearer $armToken" }).properties } catch { $live = $null }
    if ($live) {
        $preserve = @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{
                apimVirtualNetworkType    = @{ value = $(if ($live.virtualNetworkType) { "$($live.virtualNetworkType)" } else { 'None' }) }
                apimSubnetId              = @{ value = "$($live.virtualNetworkConfiguration.subnetResourceId)" }
                apimPublicNetworkAccess   = @{ value = $(if ($live.publicNetworkAccess) { "$($live.publicNetworkAccess)" } else { 'Enabled' }) }
                apimDeveloperPortalStatus = @{ value = $(if ($live.developerPortalStatus) { "$($live.developerPortalStatus)" } else { 'Disabled' }) }
                apimLegacyPortalStatus    = @{ value = $(if ($live.legacyPortalStatus) { "$($live.legacyPortalStatus)" } else { 'Disabled' }) }
                apimCustomProperties      = @{ value = $(if ($live.customProperties) { $live.customProperties } else { @{} }) }
            }
        }
        $preserveFile = Join-Path ([IO.Path]::GetTempPath()) "claude-gw-preserve-$deployName.json"
        [IO.File]::WriteAllText($preserveFile, ($preserve | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        $preserveArgs = @('--parameters', "@$preserveFile")
        if ($live.virtualNetworkType -and "$($live.virtualNetworkType)" -ne 'None') {
            Write-Note "preserving VNet mode: $($live.virtualNetworkType) ($(("$($live.virtualNetworkConfiguration.subnetResourceId)" -split '/')[-1]))"
        }
        if ("$($live.publicNetworkAccess)" -eq 'Disabled') { Write-Note 'preserving public network access: Disabled' }
    }
    else {
        Write-Warn2 'Could not read the gateway''s network settings, so a redeploy could reset them. Stopping.'
        Write-Note  "Check you can read it: az apim show -g $ResourceGroup -n $apimName"
        throw 'Refusing to redeploy a gateway whose network state could not be read.'
    }
}

# Azure rejects a second Cognitive Services User assignment for the same
# principal at the same scope, even under a different name, with
# RoleAssignmentExists. A gateway that already has the role - because an earlier
# run, deploy.ps1, or an administrator granted it - therefore fails the
# deployment rather than skipping the grant.
#
# So check first. Only possible when reusing, because a gateway being created
# has no identity yet.
$grantRole = $true
if ($ExistingApim) {
    $apimOid = az apim show -g $ResourceGroup -n $apimName --query identity.principalId -o tsv 2>$null
    if ($apimOid) {
        $foundryId = az cognitiveservices account show -g $FoundryResourceGroup -n $FoundryAccount --query id -o tsv 2>$null
        if ($foundryId) {
            # Filtered here rather than in --query: a JMESPath filter needs
            # parentheses, and on Windows az is a .cmd shim that lets cmd.exe
            # re-parse them.
            $existingRoles = az role assignment list --scope $foundryId --include-inherited -o json 2>$null | ConvertFrom-Json
            $match = @($existingRoles | Where-Object {
                $_.roleDefinitionName -eq 'Cognitive Services User' -and $_.principalId -eq $apimOid
            })
            if ($match.Count) {
                $grantRole = $false
                Write-Note "role assignment already in place - not re-granting"
            }
        }
    }
}

az deployment group create `
    --name $deployName `
    -g $ResourceGroup `
    --template-file (Join-Path $root 'infra/main.bicep') `
    --parameters `
        namePrefix=$NamePrefix `
        existingApimName=$ExistingApim `
        location=$Location `
        foundryAccountName=$FoundryAccount `
        foundryResourceGroup=$FoundryResourceGroup `
        publisherEmail=$PublisherEmail `
        apimSku=$Sku `
        grantFoundryRole=$($grantRole.ToString().ToLower()) `
        allowStandardValueExisting=$allowStd `
        allowPremiumValueExisting=$allowPrm `
        quotaOverridesExisting=$quotaOvr `
        buRegistryExisting=$buReg `
        buMembersExisting=$buMem `
        buParentsExisting=$buPar `
        buModesExisting=$buModes `
        usdBudgetsExisting=$usdBudgets `
        usdBudgetStateExisting=$usdBudgetState `
        modelsStandard=$modelsStd `
        modelsPremium=$modelsPrm `
        tpmStandard=$TpmStandard `
        quotaStandard=$QuotaStandard `
        tpmPremium=$TpmPremium `
        quotaPremium=$QuotaPremium `
        quotaOrg=$QuotaOrg `
        callsPerMinute=$CallsPerMinute `
        entitlementSource=$(if ($entSrc) { $entSrc } else { 'named-value' }) `
        entitlementResolverUrl=$(if ($entUrl) { $entUrl } else { 'https://resolver-not-deployed.invalid' }) `
        entitlementResolverAudience=$(if ($entAud) { $entAud } else { 'https://resolver-not-deployed.invalid' }) `
        entitlementCacheSeconds=$(if ($entitlementCacheSeconds) { $entitlementCacheSeconds } elseif ($entTtl) { $entTtl } else { 3600 }) `
        buUnassigned=$(if ($unassignedMode) { $unassignedMode } else { 'allow' }) `
    @preserveArgs `
    -o none

if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. See the error above.' }
Write-Ok 'deployed'

$gatewayUrl = az deployment group show -g $ResourceGroup -n $deployName --query "properties.outputs.gatewayUrl.value" -o tsv 2>$null
if (-not $gatewayUrl) { $gatewayUrl = "https://$apimName.azure-api.net/claude" }

# ---------------------------------------------------------------- 7. groups

Write-Step 'Entra groups'
foreach ($g in @($StandardGroup, $PremiumGroup)) {
    $existing = az ad group show --group $g --query id -o tsv 2>$null
    if ($existing) { Write-Ok "$g exists" }
    else {
        $id = (az ad group create --display-name $g --mail-nickname $g -o json 2>$null | ConvertFrom-Json).id
        if ($id) { Write-Ok "$g created" }
        else {
            Write-Warn2 "Could not create '$g' - your tenant may restrict group creation."
            Write-Note 'Ask an admin to create it, then re-run.'
        }
    }
}

Write-Step 'Sync entitlement'
& (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') -ApimName $apimName -ResourceGroup $ResourceGroup `
    -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup

# ------------------------------------------------------- 7b. business units
#
# Offered here because the installer already asks for tiers and budgets, and
# stopping short of the thing those budgets are charged to is an odd seam - the
# first question after a deploy was always "so where do I set up chargeback".
#
# Skipped by default under -Yes: a business unit is a naming decision about the
# customer's own organisation, and guessing one unattended leaves a registry
# entry nobody asked for.
if (-not $Yes) {
    Write-Step 'Business units (optional)'
    Write-Note 'A business unit is an Entra group with a monthly budget. Usage is charged to it.'
    Write-Note 'Skip this and add them later with ./scripts/Set-ClaudeBusinessUnit.ps1.'

    while (Read-YesNo 'Create a business unit now?' $false) {
        $buId = Read-Default -Prompt 'Identifier' -Default 'platform' `
            -Help 'Short and stable - it keys the budget counter and every report. Lower case, no spaces.'

        # Validated here rather than at the write, so a bad name is caught while
        # the operator is still looking at the prompt that produced it.
        if ($buId -notmatch '^[a-z0-9][a-z0-9-]*$') {
            Write-Warn2 "'$buId' is not usable. Use lower case letters, digits and hyphens."
            continue
        }

        $buGroup = Read-Default -Prompt 'Entra group' -Default "claude-bu-$buId" `
            -Help 'Who belongs to the unit. Created here if it does not exist.'

        $existing = az ad group show --group $buGroup --query id -o tsv 2>$null
        if (-not $existing) {
            $newId = (az ad group create --display-name $buGroup --mail-nickname $buGroup -o json 2>$null | ConvertFrom-Json).id
            if ($newId) { Write-Ok "$buGroup created" }
            else {
                # Set-ClaudeBusinessUnit refuses a unit pointing at a group that
                # does not exist, because it would sync to nobody and read as
                # unused rather than broken. Stop here rather than write one.
                Write-Warn2 "Could not create '$buGroup' - your tenant may restrict group creation."
                Write-Note 'Ask an admin to create it, then run Set-ClaudeBusinessUnit.ps1.'
                continue
            }
        }
        else { Write-Ok "$buGroup exists" }

        $buBudget = Read-Int -Prompt 'Monthly budget, US dollars' -Default 5000 `
            -Help 'Converted to tokens on write. List price, and the counter cannot see cached tokens.'

        & (Join-Path $root 'scripts/Set-ClaudeBusinessUnit.ps1') -Id $buId -Group $buGroup `
            -MonthlyBudgetUsd $buBudget -ApimName $apimName -ResourceGroup $ResourceGroup
    }
}

# --------------------------------------------------------------- 8. package

Write-Step 'Onboarding package'
$pkg = Join-Path $root 'onboarding'
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

$config = [ordered]@{
    # Tagged with what it is. The direct path writes the same shape with
    # mode 'foundry-direct', and the two files have the same extension and
    # opposite meanings - applying one as the other produces a machine pointed
    # at something that is not a gateway, and an error naming neither file.
    mode          = 'gateway'
    gatewayUrl    = $gatewayUrl
    tenantId      = $acct.tenantId
    apimName      = $apimName
    resourceGroup = $ResourceGroup
    standardGroup = $StandardGroup
    premiumGroup  = $PremiumGroup
    # How developers sign in. Decided once, here, rather than left to whoever
    # runs the setup script on each machine - a fleet where half the
    # workstations authenticate differently is a fleet with two support paths.
    # Changeable later by reissuing this file; it configures nothing itself.
    authMode      = $AuthMode
    tiers = @{
        standard = @{ tokensPerMinute = $TpmStandard; tokensPerDay = $QuotaStandard }
        premium  = @{ tokensPerMinute = $TpmPremium;  tokensPerDay = $QuotaPremium }
    }
    organisation = @{ tokensPerMonth = $QuotaOrg; shared = $true; softCap = $true }
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
}
$configPath = Join-Path $pkg 'claude-gateway.json'
$config | ConvertTo-Json -Depth 6 | Set-Content $configPath -Encoding UTF8
Write-Ok "config: $configPath"

# ---------------------------------------------------------------- 9. verify

Write-Step 'Verifying the controls'
try {
    & (Join-Path $root 'scripts/Show-Governance.ps1') -ApimName $apimName -ResourceGroup $ResourceGroup -SkipThrottleTest
}
catch { Write-Warn2 "Verification could not complete: $($_.Exception.Message)" }

# ----------------------------------------------------------------- 10. next

Write-Head 'Done'
Write-Host ''
Write-Host "  Gateway   $gatewayUrl" -ForegroundColor Green
Write-Host "  Tenant    $($acct.tenantId)" -ForegroundColor Green
Write-Host ''
Write-Host '  Next:' -ForegroundColor White
Write-Host ''
if ($budgetMode -eq 'stop') {
    Write-Host '   0. You chose stop for team budgets' -ForegroundColor Yellow
    Write-Host '        The per-team quota is deployed and enforcing. Set a figure per team:'
    Write-Host "        ./scripts/Set-ClaudeBusinessUnit.ps1 -Id <team> -MonthlyBudgetUsd <n> -ApimName $apimName -ResourceGroup $ResourceGroup"
    Write-Host '        Until a team has one, nothing refuses it. The counter does not see'
    Write-Host '        cached tokens, so it triggers later than the dollar figure suggests.'
    Write-Host ''
}
if ($addressMode -eq 'custom') {
    Write-Host '   0. You chose a company address' -ForegroundColor Yellow
    Write-Host '        Nothing here configured it. Add the hostname and certificate to the'
    Write-Host '        gateway, point DNS at it, then hand developers that address instead:'
    Write-Host "        az apim update -g $ResourceGroup -n $apimName --set hostnameConfigurations=..."
    Write-Host '        Do it before onboarding anyone, or they are configured against the'
    Write-Host '        Azure address and have to be reconfigured later.'
    Write-Host ''
}
Write-Host '   1. Entitle a developer'
Write-Host "        ./scripts/Set-ClaudeDeveloper.ps1 -User dev@contoso.com -Tier standard ``"
Write-Host "            -ApimName $apimName -ResourceGroup $ResourceGroup"
Write-Host '      Takes an email, a UPN or an object id, adds them to the group and'
Write-Host '      publishes in one step. The raw route needs an object id, not an email:'
Write-Host '        $oid = az ad user show --id dev@contoso.com --query id -o tsv'
Write-Host "        az ad group member add --group $StandardGroup --member-id `$oid"
Write-Host "        ./scripts/Sync-ClaudeAccess.ps1 -ApimName $apimName -ResourceGroup $ResourceGroup"
Write-Host '      Portal route: docs/ONBOARDING.md section 2'
Write-Host ''
Write-Host '   2. Send them the setup'
Write-Host "        ./scripts/New-OnboardingEmail.ps1 -ConfigPath $configPath -To dev@contoso.com"
Write-Host ''
Write-Host '   3. Close the direct-access bypass - see docs/SETUP.md section 4.1' -ForegroundColor Yellow
Write-Host '      Anyone holding Cognitive Services User on the Foundry account'
Write-Host '      can skip the gateway entirely and ignore these budgets.'
Write-Host ''
if ($ChooseFinOps) {
    & (Join-Path $root 'scripts\Select-ClaudeFinOpsTooling.ps1') -Region $Location -SubscriptionId $SubscriptionId
}
else { Write-Host '   4. Choose optional FinOps tooling: .\scripts\Select-ClaudeFinOpsTooling.ps1' }
