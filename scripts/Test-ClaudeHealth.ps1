<#
.SYNOPSIS
    One command that answers "is this gateway healthy?".

.DESCRIPTION
    This repository ships a lot of checks. Each is right about its own thing,
    and none of them answers the question an operator actually has on a Monday
    morning, which is whether anything needs attention at all.

    This runs the read-only ones and reports a single verdict. It does not
    reimplement them: each is invoked as it ships, and its exit code is the
    answer. A check that changes behaviour later changes here too, and there is
    no second copy of the logic to drift.

      SKU is v2               a classic tier meters every Claude call as zero
                              tokens, so no budget ever binds
      Entitlement in sync     the gap between a directory change and the sync,
                              during which the gateway enforces a stale answer
      Named value headroom    a tier list holds 110 identities and writes fail
                              outright at the limit
      Models are priced       a deployed model with no price is served and
                              reported at nothing
      Bypass is closed        a principal with data-plane access on Foundry
                              skips every control here
      Business units          spend landing on no budget

    Nothing is written. Every check is a read.

.PARAMETER FailOn
    Which severity makes the run exit non-zero: 'fail' (default) or 'warn'.
    Use 'warn' when running it as a scheduled gate.

.EXAMPLE
    ./scripts/Test-ClaudeHealth.ps1 -ResourceGroup rg-claude -ApimName apim-claude

.EXAMPLE
    ./scripts/Test-ClaudeHealth.ps1 -ResourceGroup rg-claude -ApimName apim-claude -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [string]$FoundryAccount,
    [string]$WorkspaceName,
    [ValidateSet('fail', 'warn')][string]$FailOn = 'fail',
    # Show each check's own output as well as the verdict.
    [switch]$Detailed,
    [switch]$AsJson
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent

$results = @()
function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail, [string]$Fix = '')
    $script:results += [ordered]@{ check = $Name; status = $Status; detail = $Detail; fix = $Fix }
}

# Invokes a shipped check and turns its exit code into a verdict. The scripts
# are the contract; this only reads them.
function Invoke-Check {
    param([string]$Name, [string]$Script, [hashtable]$ScriptArgs, [string]$OkDetail, [string]$BadDetail, [string]$Fix)

    $path = Join-Path $root "scripts/$Script"
    if (-not (Test-Path $path)) {
        Add-Result $Name 'warn' "$Script is not present" ''
        return $null
    }
    # *>&1, not 2>&1. The checks report with Write-Host, which does not travel
    # on the success or error stream, so 2>&1 captured nothing and sixty lines
    # of sub-check output landed on the operator's console underneath the
    # summary that was supposed to replace it.
    $out = & $path @ScriptArgs *>&1 | Out-String
    $code = $LASTEXITCODE
    if ($Detailed) { Write-Host $out -ForegroundColor DarkGray }
    if ($code -eq 0) { Add-Result $Name 'pass' $OkDetail '' }
    else { Add-Result $Name 'fail' $BadDetail $Fix }
    return $out
}

if (-not $AsJson) {
    Write-Host ''
    Write-Host 'Gateway health' -ForegroundColor Cyan
    Write-Host "  APIM : $ApimName ($ResourceGroup)"
    Write-Host ''
}

# --- 1. the SKU ------------------------------------------------------------
# The most common silent failure: on a classic tier the policies attach, the
# API returns 200, and every token count is zero, so no budget binds.
$sku = (az apim show -g $ResourceGroup -n $ApimName --query 'sku.name' -o tsv 2>$null)
$sku = if ($sku) { $sku.Trim() } else { '' }
if (-not $sku) {
    Add-Result 'API Management tier' 'fail' "Could not read the SKU of '$ApimName'" 'Check the name, the resource group, and that you are signed in.'
} elseif ($sku -in @('BasicV2', 'StandardV2', 'PremiumV2')) {
    Add-Result 'API Management tier' 'pass' "$sku meters Claude tokens" ''
} else {
    Add-Result 'API Management tier' 'fail' "$sku is a classic tier: Claude calls meter as zero tokens, so no budget binds" `
        'Migrate to a v2 tier. See docs/SETUP.md 4.1.'
}

# --- 2. entitlement --------------------------------------------------------
$cmp = Invoke-Check 'Entitlement in sync' 'Compare-ClaudeEntitlement.ps1' `
    @{ ResourceGroup = $ResourceGroup; ApimName = $ApimName } `
    'the gateway and the directory agree' `
    'the gateway and the directory disagree' `
    './scripts/Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim>'
if ($cmp -and $cmp -match '(?m)^\s+(missing|stale|tier-drift) \((\d+)\)') {
    $kinds = @([regex]::Matches($cmp, '(?m)^\s+(missing|stale|tier-drift) \((\d+)\)') | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[2].Value)" })
    $results[-1].detail = 'drift: ' + ($kinds -join ', ')
}

# --- 3. headroom -----------------------------------------------------------
Invoke-Check 'Named value headroom' 'Measure-ClaudeCeiling.ps1' `
    @{ ResourceGroup = $ResourceGroup; ApimName = $ApimName } `
    'every list is within 80% of the 4,096-character limit' `
    'a list is near the limit, and a write past it fails outright' `
    'See docs/SCALE.md. The entitlement path caps at 110 identities per tier.' | Out-Null

# --- 4. priced models ------------------------------------------------------
# Not a shipped check with an exit code, so it is read here. A deployed Claude
# model with no price is served and reported at nothing, which looks like
# nobody using it.
try {
    . (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
    . (Join-Path $PSScriptRoot 'ClaudeModelDeployment.ps1')
    $acct = $FoundryAccount
    if (-not $acct) {
        $names = @((az cognitiveservices account list -g $ResourceGroup --query "[?kind=='AIServices'].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
        if ($names.Count -eq 1) { $acct = $names[0].Trim() }
    }
    if (-not $acct) {
        Add-Result 'Models are priced' 'warn' 'could not identify the Foundry account' 'Pass -FoundryAccount.'
    } else {
        $deployed = @(Get-ClaudeDeployment -Account $acct -ResourceGroup $ResourceGroup | ForEach-Object { $_.name })
        $unpriced = @($deployed | Where-Object { -not $ClaudePriceBook[$_] })
        if (-not $deployed.Count) {
            Add-Result 'Models are priced' 'warn' "no Claude deployment on $acct" 'Deploy one, or check the account name.'
        } elseif ($unpriced.Count) {
            Add-Result 'Models are priced' 'fail' ("deployed but unpriced: " + ($unpriced -join ', ')) `
                "./scripts/Add-ClaudeModel.ps1 -Model $($unpriced[0]) -InputPerMillion <n> -OutputPerMillion <n>"
        } else {
            Add-Result 'Models are priced' 'pass' ("all $($deployed.Count) Claude deployment(s) priced") ''
        }
    }
} catch {
    Add-Result 'Models are priced' 'warn' "could not check: $($_.Exception.Message)" ''
}

# --- 5. the bypass ---------------------------------------------------------
Invoke-Check 'Foundry bypass closed' 'Get-ClaudeBypass.ps1' `
    @{ ResourceGroup = $ResourceGroup } `
    'nothing reaches Foundry without passing through the gateway' `
    'a principal can call Foundry directly, skipping every control here' `
    './scripts/Get-ClaudeBypass.ps1 lists them. See docs/SETUP.md 4.2.' | Out-Null

# --- 6. business units -----------------------------------------------------
try {
    $bu = & (Join-Path $root 'scripts/Get-ClaudeBusinessUnit.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName -AsJson 2>$null 6>$null | Out-String | ConvertFrom-Json
    $un = [int]$bu.unassigned.developers
    if ($un -gt 0) {
        Add-Result 'Business units' 'warn' "$un entitled developer(s) belong to no business unit, so their spend counts against no budget" `
            './scripts/Set-ClaudeDeveloper.ps1 -User <upn> -BusinessUnit <id>'
    } else {
        Add-Result 'Business units' 'pass' 'every entitled developer has a business unit' ''
    }
} catch {
    Add-Result 'Business units' 'warn' 'could not read the chargeback report' ''
}

# --- 7. the ceiling above those budgets ------------------------------------
#
# quota-org is evaluated before the per-unit quota and on the same monthly
# period, so the smaller of the two is the one that binds. A ceiling below the
# sum of the unit budgets makes every one of those budgets unreachable: the
# gateway denies the whole organisation first, and each unit still reports
# plenty of headroom. Nothing else in this check would notice.
try {
    $orgRaw = & (Join-Path $root 'scripts/Get-ClaudeBudget.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName -AsJson 2>$null 6>$null |
              Out-String | ConvertFrom-Json
    $orgTokens = [long]$orgRaw.organisation.tokens_per_month

    . (Join-Path $root 'scripts/ApimNamedValue.ps1')
    . (Join-Path $root 'scripts/ClaudeBusinessUnit.ps1')
    $reg = @(ConvertFrom-ClaudeBuRegistry (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-registry'))
    $par = ConvertFrom-ClaudeBuParents (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-parents')

    if (-not $reg.Count) {
        Add-Result 'Organisation ceiling' 'pass' 'no business unit budgets to exceed it' ''
    }
    elseif ($orgTokens -le 0) {
        Add-Result 'Organisation ceiling' 'warn' 'quota-org is unset or zero' 'Set it to at least the sum of the unit budgets.'
    }
    else {
        # Teams are charged to their parent as well, so only top-level units draw.
        $top = @($reg | Where-Object { -not $par[$_.Id] })
        $sum = ($top | Measure-Object -Property TokensPerMonth -Sum).Sum
        if ($sum -gt $orgTokens) {
            Add-Result 'Organisation ceiling' 'fail' `
                ("quota-org is {0:n0} tokens/month but {1} top-level unit(s) are allowed {2:n0}, so no unit budget can ever bind" -f $orgTokens, $top.Count, $sum) `
                ("Raise it: az apim nv update -g $ResourceGroup --service-name $ApimName --named-value-id quota-org --value $sum")
        } else {
            Add-Result 'Organisation ceiling' 'pass' `
                ("{0:n0} tokens/month, above the {1:n0} committed to units" -f $orgTokens, $sum) ''
        }
    }
} catch {
    Add-Result 'Organisation ceiling' 'warn' "could not compare the ceiling to the unit budgets: $($_.Exception.Message)" ''
}

# --- report ----------------------------------------------------------------

$failed = @($results | Where-Object { $_.status -eq 'fail' })
$warned = @($results | Where-Object { $_.status -eq 'warn' })

if ($AsJson) {
    [ordered]@{
        apim = $ApimName; resource_group = $ResourceGroup; sku = $sku
        checked_at = (Get-Date).ToUniversalTime().ToString('o')
        checks = $results
        failed = $failed.Count; warned = $warned.Count
        healthy = ($failed.Count -eq 0)
    } | ConvertTo-Json -Depth 6
} else {
    foreach ($r in $results) {
        $mark, $colour = switch ($r.status) {
            'pass' { 'PASS', 'Green' }
            'warn' { 'WARN', 'Yellow' }
            default { 'FAIL', 'Red' }
        }
        Write-Host ("  {0}  {1,-24} {2}" -f $mark, $r.check, $r.detail) -ForegroundColor $colour
        if ($r.fix) { Write-Host ("        {0}" -f $r.fix) -ForegroundColor DarkGray }
    }
    Write-Host ''
    if (-not $failed.Count -and -not $warned.Count) {
        Write-Host '  Healthy.' -ForegroundColor Green
    } else {
        Write-Host ("  {0} failing, {1} to look at." -f $failed.Count, $warned.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Yellow' })
    }
    Write-Host ''
}

if ($failed.Count) { exit 1 }
if ($FailOn -eq 'warn' -and $warned.Count) { exit 1 }
exit 0
