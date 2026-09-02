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

    # Accept every default without prompting.
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

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
        Write-Bad 'No Foundry account with a Claude deployment found in this subscription.'
        Write-Note 'Deploy claude-sonnet-5 and/or claude-opus-5 first - the gateway fronts a model, it cannot create one.'
        throw 'No Claude deployment.'
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
# API Management is the entire cost of this accelerator - roughly $250/month
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

$Sku = if ($Sku) { $Sku } else {
    Read-Default -Prompt 'API Management SKU' -Default 'BasicV2' `
        -Help 'Must be a v2 tier. Classic tiers attach the policies but meter zero Anthropic tokens, so budgets never trigger.' -Validate {
            param($x)
            if ($x -in @('BasicV2','StandardV2','PremiumV2')) { return $true }
            Write-Warn2 'Must be BasicV2, StandardV2 or PremiumV2.'
            return $false
        }
}

# Already fixed when reusing - the name is the existing instance's.
$NamePrefix = if ($NamePrefix) { $NamePrefix } else {
    Read-Default -Prompt 'Name prefix' -Default "claudegw$(Get-Random -Minimum 100000 -Maximum 999999)" `
        -Help 'API Management names are globally unique DNS labels.'
}

$PublisherEmail = if ($PublisherEmail) { $PublisherEmail } else {
    Read-Default -Prompt 'Publisher email' -Default $acct.user.name -Help 'Shown on the API Management instance.'
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
    Write-Host '  Cost: API Management is the bulk of it - BasicV2 is roughly $250/month.' -ForegroundColor DarkGray
    Write-Host '  Provisioning takes 30-45 minutes, most of it API Management.' -ForegroundColor DarkGray
}
Write-Host ''

if ($WhatIfPreference) { Write-Warn2 'WhatIf - stopping before any change.'; return }
if (-not (Read-YesNo $(if ($ExistingApim) { 'Apply this to the existing gateway?' } else { 'Create these resources?' }) $true)) {
    Write-Host ''; Write-Host 'Cancelled.' -ForegroundColor Yellow; return
}

# ---------------------------------------------------------------- 6. deploy

Write-Head 'Deploying'

Write-Step 'Resource group'
az group create -n $ResourceGroup -l $Location -o none
Write-Ok $ResourceGroup

Write-Step $(if ($ExistingApim) { 'Claude API and policies (a few minutes)' } else { 'API Management and Application Insights (30-45 min)' })
Write-Note 'Safe to leave running.'

# Entitlement is owned by Sync-ClaudeAccess.ps1, not by this template. If the
# gateway already exists, read the current allow lists and hand them back, so a
# redeploy cannot reset them to empty and revoke everybody. `what-if` against
# the live gateway showed exactly that happening.
$allowStd = ''
$allowPrm = ''
$quotaOvr = ''
if ($ExistingApim -or (az apim show -g $ResourceGroup -n $apimName --query name -o tsv 2>$null)) {
    $allowStd = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id allow-standard --query value -o tsv 2>$null
    $allowPrm = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id allow-premium  --query value -o tsv 2>$null
    $quotaOvr = az apim nv show -g $ResourceGroup --service-name $apimName --named-value-id quota-overrides --query value -o tsv 2>$null
    if (-not $allowStd) { $allowStd = '' }
    if (-not $allowPrm) { $allowPrm = '' }
    if (-not $quotaOvr) { $quotaOvr = '' }
    $keptStd = @($allowStd.Trim(',') -split ',' | Where-Object { $_ })
    $keptPrm = @($allowPrm.Trim(',') -split ',' | Where-Object { $_ })
    $keptOvr = @($quotaOvr.Trim(',') -split ',' | Where-Object { $_ })
    if ($keptStd.Count -or $keptPrm.Count) {
        Write-Note "preserving entitlement: $($keptStd.Count) standard, $($keptPrm.Count) premium"
    }
    if ($keptOvr.Count) {
        Write-Note "preserving $($keptOvr.Count) per-user budget override(s)"
    }
}

$deployName = "claude-gw-$(Get-Date -Format 'yyyyMMddHHmmss')"

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
        tpmStandard=$TpmStandard `
        quotaStandard=$QuotaStandard `
        tpmPremium=$TpmPremium `
        quotaPremium=$QuotaPremium `
        quotaOrg=$QuotaOrg `
        callsPerMinute=$CallsPerMinute `
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

# --------------------------------------------------------------- 8. package

Write-Step 'Onboarding package'
$pkg = Join-Path $root 'onboarding'
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

$config = [ordered]@{
    gatewayUrl    = $gatewayUrl
    tenantId      = $acct.tenantId
    apimName      = $apimName
    resourceGroup = $ResourceGroup
    standardGroup = $StandardGroup
    premiumGroup  = $PremiumGroup
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
Write-Host '   1. Entitle a developer'
Write-Host "        az ad group member add --group $StandardGroup --member-id <object-id>"
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
