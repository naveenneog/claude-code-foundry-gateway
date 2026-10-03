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

    [ValidateSet('azure','custom')][string]$AddressMode,
    [string]$AddressHostname,
    [ValidateSet('KeyVault','Pfx')][string]$AddressCertificateSource,
    [string]$AddressKeyVaultCertificateId,
    [string]$AddressPfxPath,
    [securestring]$AddressCertificatePassword,
    [string]$AddressDnsZoneResourceId,
    [ValidateSet('AzureDns','External')][string]$AddressDnsMode,
    [string]$AddressReplaceHostname,
    [string]$AddressApprovedPlanFingerprint,

    # Update this existing v2 gateway, taking the reuse path without the menu: its region, tier,
    # name and publisher are kept. The guided flow's -Change foundation passes it (ADR-0032).
    [string]$ExistingApimName,

    [ValidateSet('named-value','projection')]
    [string]$EntitlementStore,
    [ValidateSet('private','public')]
    [string]$ResolverInboundAccess,
    [switch]$DeployProjection,
    [switch]$FlipProjectionAfterCleanCompare,
    [string]$ProjectionReconcilerResourceId,
    [string]$ProjectionRenewalImageDigest,
    [string]$ProjectionRenewalEntryPoint = 'node /app/sync/src/apply-projection.mjs',
    [string]$ProjectionRenewalActionGroupResourceId,
    [string]$ProjectionResolverAppId,

    [int]$TpmStandard,
    [int]$QuotaStandard,
    [int]$TpmPremium,
    [int]$QuotaPremium,
    [int]$QuotaOrg,
    [int]$CallsPerMinute,

    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [ValidateNotNullOrEmpty()][string[]]$StandardModels,
    [ValidateNotNullOrEmpty()][string[]]$PremiumModels,

    # How developers sign in. Written into claude-gateway.json and honoured by
    # Onboard-ClaudeDeveloper.ps1; it configures nothing on this machine.
    [ValidateSet('interactive', 'device', 'helper')]
    [string]$AuthMode,

    # How Claude Desktop itself obtains the bearer token it sends to the
    # gateway. helper-script is the shipped default. external-idp uses a public
    # Entra app registration for Desktop and requires the gateway to accept that
    # token audience.
    [ValidateSet('helper-script', 'external-idp-browser', 'external-idp-broker')]
    [string]$DesktopSignInKind,
    [ValidateSet('id_token', 'access_token')]
    [string]$DesktopBearerTokenType = 'id_token',
    [string]$DesktopEntraClientId,
    [string]$DesktopEntraIssuer,
    [string]$DesktopEntraScopes,
    [string]$DesktopEntraAudience,
    [string]$DesktopEntraResource,

    # The organisation details Anthropic requires on a Claude deployment. Only
    # used when the subscription has no Claude deployment to copy them from.
    [string]$ModelOrganizationName,
    [string]$ModelIndustry,
    [ValidatePattern('^[A-Za-z]{2}$')]
    [string]$ModelCountryCode,

    [switch]$ChooseFinOps,

    # The guided flow passes this: its FinOps step follows the installer, so the installer
    # neither offers the FinOps tool nor lists it as a next step (ADR-0032).
    [switch]$SkipFinOpsOffer,

    # A checkout holds one gateway's record. When onboarding\claude-gateway.json names another
    # gateway, keep it as onboarding\claude-gateway.<resource group>-<instance>.json and start a new
    # one for this gateway. Asked in a console; without this switch an unattended run refuses (P79).
    [switch]$ArchiveSavedRecord,

    # Set this checkout's install checkpoint aside and start again (docs/adr/0046-installer-checkpoint-and-resume.md).
    # Without it a rerun resumes after the last step whose result Azure still shows.
    [switch]$Restart,

    # An answers file (schemas/claude-gateway.answers.schema.json). A parameter passed wins over it, and it
    # wins over the install checkpoint's answers (docs/adr/0047-lean-installer-phase-0.md).
    [string]$AnswersPath,
    # Check the answers and the estate, read-only, print the report and stop; -Json prints it as JSON.
    [switch]$Preflight,
    [switch]$Json,
    # Print the steps with the state the install checkpoint records, and stop.
    [switch]$ListSteps,
    # Run these steps only, each after its prerequisites are completed and verified live.
    [string[]]$Steps,
    # Append one JSON event per line to this file as each step starts, completes, is skipped or fails.
    [string]$ProgressPath,

    # Answers the installer otherwise asks for; an answers file passes them to an unattended run.
    [ValidateRange(3600, 86400)][int]$RevocationWindowSeconds,
    [ValidateSet('report', 'stop')][string]$TeamBudgetBehaviour,
    [ValidateSet('allow', 'deny')][string]$UnassignedDevelopers,
    [int]$DeveloperEstimate,
    [object]$PendingClaudeDeployment,
    [object[]]$BusinessUnits,

    # Accept every default without prompting.
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# At top level a refusal or failure is one line on standard error, which PowerShell's error view
# would wrap at the console width; called from another script or a hosted runspace, the exception
# reaches the caller unchanged (the test Start-ClaudeGateway.ps1:24 uses, U36). The install lock is
# released either way.
$script:InstallTopLevel = -not $MyInvocation.PSCommandPath -and $MyInvocation.InvocationName -ne '.' -and $Host.Name -ne 'Default Host'
trap {
    if (Get-Command Write-ClaudeInstallTrapEvent -ErrorAction SilentlyContinue) { Write-ClaudeInstallTrapEvent $_.Exception.Message }
    if (Get-Command Exit-ClaudeInstallLock -ErrorAction SilentlyContinue) { Exit-ClaudeInstallLock }
    if (-not $script:InstallTopLevel) { break }
    # A secret that the error quotes is replaced (ADR-0047 decision 12); before the libraries load, no Azure CLI
    # call has run, so no error can quote one.
    $line = ($_.Exception.Message -replace '\s*[\r\n]+\s*', ' ').Trim()
    if (Get-Command Protect-ClaudeInstallText -ErrorAction SilentlyContinue) { $line = Protect-ClaudeInstallText $line }
    [Console]::Error.WriteLine($line)
    if ($_.Exception.Message -notlike 'Refused: *' -and (Get-Command Write-ClaudeInstallFailureHint -ErrorAction SilentlyContinue)) { Write-ClaudeInstallFailureHint }
    exit 1
}
$root = $PSScriptRoot
if ($FlipProjectionAfterCleanCompare) {
    if (-not $ProjectionReconcilerResourceId -or -not $ProjectionRenewalImageDigest -or -not $ProjectionRenewalActionGroupResourceId) {
        throw 'Projection switch refused: P86 admission requires -ProjectionReconcilerResourceId, -ProjectionRenewalImageDigest and -ProjectionRenewalActionGroupResourceId. Expected wait after deploying the 30-minute reconciler is about 60-90 minutes.'
    }
}
# -Preflight and -ListSteps read only and print only their report: no prompt and no change (ADR-0047).
. (Join-Path $root 'scripts/ClaudeInstallCheckpoint.ps1')
if ($Preflight -or $ListSteps) {
    if ($ListSteps) { Show-ClaudeInstallStepList -Root $root -Json:$Json; return }
    . (Join-Path $root 'scripts/ClaudeInstallerPreflight.ps1')
    $preflightResult = Get-ClaudeInstallPreflightResult -Bound $PSBoundParameters
    Write-ClaudeGatewayPreflight -Result $preflightResult -Json:$Json
    exit $(if ($preflightResult.result -eq 'PASS') { 0 } else { 1 })
}
if ($Steps) { Set-ClaudeInstallSelection -Steps $Steps }
Initialize-ClaudeInstallProgress -Path $ProgressPath
$desktopSignInHelper = Join-Path $root 'scripts/ClaudeDesktopSignIn.ps1'
if (Test-Path $desktopSignInHelper) { . $desktopSignInHelper }

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
# A warning or a failure line can quote an error, so a secret in it is replaced once the checkpoint library is
# loaded (ADR-0047 decision 12). Each helper stands alone: tests/Test-FlowStart.ps1 runs it outside the installer.
function Write-Warn2($t){ if (Get-Command Protect-ClaudeInstallText -ErrorAction SilentlyContinue) { $t = Protect-ClaudeInstallText ([string]$t) }; Write-Host "    [WARN] $t" -ForegroundColor Yellow }
function Write-Bad($t)  { if (Get-Command Protect-ClaudeInstallText -ErrorAction SilentlyContinue) { $t = Protect-ClaudeInstallText ([string]$t) }; Write-Host "    [FAIL] $t" -ForegroundColor Red }
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

# The region, priced (ADR-0032): the Foundry account's region and the other regions in its
# geography, each with the monthly list price of the three v2 tiers, from one Retail Prices API
# call. Returns the ARM region name.
function Read-GatewayRegion {
    param([string]$Default)
    if ($Yes) { return $Default }
    Write-Note 'Reading the regions this subscription can use and the API Management v2 list prices there (about 6 s)...'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $json = Invoke-AzOptional { az account list-locations -o json }
    $locations = @()
    # Assigned first: on Windows PowerShell 5.1, @(... | ConvertFrom-Json) holds the whole array
    # as one element, and every region then fails the geography match.
    if ($json) { try { $parsed = ($json | Out-String) | ConvertFrom-Json; $locations = @($parsed) } catch { $locations = @() } }
    $script:GatewayPrices = Get-ClaudeApimV2Prices
    Write-Note ('read in {0:N1} s' -f $watch.Elapsed.TotalSeconds)
    $physical = @($locations | Where-Object { $_ -and $_.metadata -and $_.metadata.regionType -eq 'Physical' } | ForEach-Object { [string]$_.name })
    $options = @()
    if ($script:GatewayPrices.ByRegion) { $options = @(Get-ClaudeGatewayRegionOptions -FoundryRegion $Default -Locations $locations -Prices $script:GatewayPrices) }
    if ($options.Count) {
        Write-Host ''
        foreach ($line in (Format-ClaudeGatewayRegionTable -Options $options -Prices $script:GatewayPrices)) { Write-Host "    $line" -ForegroundColor DarkGray }
        Write-Host ''
    }
    else {
        $why = if ($script:GatewayPrices.Unreachable) { $script:GatewayPrices.Unreachable } else { 'no region list was returned' }
        Write-Warn2 "API Management prices could not be read ($why). The summary prices the choice if it can."
    }
    $answer = Read-Default -Prompt 'Region (number or name)' -Default $Default -Validate {
        param($x)
        if (Resolve-ClaudeGatewayRegionAnswer -Answer $x -Options $options -KnownRegions $physical) { return $true }
        # Nothing to check against when neither list could be read.
        if (-not $physical.Count -and -not $options.Count) { return $true }
        Write-Warn2 "'$x' is not a region this subscription can use. Enter a number from the list or a region name such as $Default."
        return $false
    }
    $resolved = Resolve-ClaudeGatewayRegionAnswer -Answer $answer -Options $options -KnownRegions $physical
    if ($resolved) { return $resolved }
    return (ConvertTo-ClaudeArmRegionName $answer)
}

# Each v2 tier's monthly list price in the chosen region, above the tier prompt.
function Show-GatewayTierPrices {
    param([string]$Region)
    if (-not $script:GatewayPrices -or -not $script:GatewayPrices.ByRegion) { $script:GatewayPrices = Get-ClaudeApimV2Prices }
    if (-not $script:GatewayPrices.ByRegion) { Write-Note "Tier prices could not be read: $($script:GatewayPrices.Unreachable)"; return }
    foreach ($line in (Format-ClaudeApimTierPriceLines -Region $Region -Prices $script:GatewayPrices)) { Write-Host "      $line" -ForegroundColor DarkGray }
}

# Next steps, numbered in the order they are printed.
function Write-NextSteps {
    param([object[]]$Steps = @())
    $n = 0
    foreach ($s in @($Steps)) {
        $n++
        Write-Host ("   {0}. {1}" -f $n, $s.Title) -ForegroundColor $(if ($s.Warn) { 'Yellow' } else { 'White' })
        foreach ($line in @($s.Detail)) { Write-Host $line }
        Write-Host ''
    }
}

# On Windows az is az.cmd, and cmd.exe re-reads & | < > ^ ( ) " % in an argument: such a value ends
# the argument early or runs a second command. Checked before the summary, so nothing is created.
function Assert-AzArgumentsSafe {
    param(
        [System.Collections.IDictionary]$Values,
        [bool]$Shim = [bool]((Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source -match '\.(cmd|bat)$')
    )
    if (-not $Shim) { return }
    foreach ($name in @($Values.Keys)) {
        $value = [string]$Values[$name]
        if ($value -match '[&|<>^()"%\r\n]') {
            Write-Bad "$name '$value' holds '$($Matches[0])', which cmd.exe re-reads in an Azure CLI argument on Windows."
            throw "Stopped: $name holds a character that the Azure CLI's cmd.exe shim re-reads (& | < > ^ ( ) `" %). Nothing was created."
        }
    }
}

# --------------------------------------------------------------- 0. sign-in

. (Join-Path $root 'scripts/Show-Banner.ps1')
Show-ClaudeBanner -Subtitle 'Governed gateway for Claude on Microsoft Foundry'

Write-Host ' Every prompt has a default. Press Enter to accept it.' -ForegroundColor DarkGray
Write-Host ' Nothing is created until you confirm the summary.' -ForegroundColor DarkGray
# Fail here, with a remedy, rather than part-way through a deployment.
. (Join-Path $root 'scripts/Test-Prerequisites.ps1')
. (Join-Path $root 'scripts/flow/FlowContract.ps1')
. (Join-Path $root 'scripts/ClaudeModelDeployment.ps1')
. (Join-Path $root 'scripts/ClaudeChoice.ps1')
. (Join-Path $root 'scripts/ClaudeGatewayRegion.ps1')
if (-not (Test-ClaudePrerequisites -Mode Admin)) { return }
# The answers file's answers are bound as if passed, then an interrupted run's answers: a parameter passed
# wins over the answers file, which wins over the checkpoint (ADR-0046, ADR-0047).
if ($AnswersPath) {
    . (Join-Path $root 'scripts/ClaudeInstallerAnswers.ps1')
    $fromAnswers = Import-ClaudeInstallerAnswers -Path $AnswersPath -Bound $PSBoundParameters
    foreach ($name in @($fromAnswers.Keys)) { Set-Variable -Name $name -Value $fromAnswers[$name]; $PSBoundParameters[$name] = $fromAnswers[$name] }
}
$recordedAnswers = Open-ClaudeInstallCheckpoint -Root $root -Bound $PSBoundParameters -Restart:$Restart -WhatIfRun:$WhatIfPreference -AnswersPath $AnswersPath
foreach ($name in @($recordedAnswers.Keys)) { if (-not $PSBoundParameters.ContainsKey($name)) { Set-Variable -Name $name -Value $recordedAnswers[$name]; $PSBoundParameters[$name] = $recordedAnswers[$name] } }
if (-not $PSBoundParameters.ContainsKey('DeveloperEstimate') -and $null -ne ($recordedEstimate = Get-ClaudeInstallAnswer 'DeveloperEstimate')) { $script:DeveloperEstimate = [int]$recordedEstimate }
if (-not $BusinessUnits -and ($recordedUnits = Get-ClaudeInstallAnswer 'BusinessUnits')) { $BusinessUnits = @($recordedUnits) }

# The parameters as bound, before the first az call that uses one. A list passed to one of these
# arrives as text joined by binding, so it is checked here too.
Assert-AzArgumentsSafe -Values ([ordered]@{
    SubscriptionId = $SubscriptionId; FoundryAccount = $FoundryAccount; FoundryResourceGroup = $FoundryResourceGroup
    ResourceGroup = $ResourceGroup; Location = $Location; NamePrefix = $NamePrefix; ExistingApimName = $ExistingApimName
    PublisherEmail = $PublisherEmail; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup
    DesktopEntraClientId = $DesktopEntraClientId; DesktopEntraAudience = $DesktopEntraAudience
})

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
Assert-ClaudeInstallTenant $acct.tenantId

if (-not $SubscriptionId) {
    # Listing every subscription is unusable on a large tenant - this account
    # can see 86 of them. Offer the current one first, which is nearly always
    # right, and only go looking if it is not.
    $currentName = $acct.name
    if ($Yes -or (Read-YesNo "Use subscription '$currentName'?" $true)) {
        $SubscriptionId = $acct.id
    }
    else {
        $subs = Invoke-ClaudeInstallAzShown { az account list --query "[].{name:name, id:id, state:state}" -o json } |
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
Invoke-ClaudeInstallAzShown { az account set --subscription $SubscriptionId }
$subName = (Invoke-ClaudeInstallAzShown { az account show --query name -o tsv })
Write-Ok "subscription: $subName"
Assert-ClaudeInstallSubscription
Assert-ClaudeInstallPrerequisites

# ------------------------------------------------------- 1. Foundry account

Write-Step 'Foundry account'
$pendingDeployment = $null
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
    $accounts = Invoke-ClaudeInstallAzShown { az cognitiveservices account list --query "[].{name:name, rg:resourceGroup, loc:location, kind:kind}" -o json } |
        ConvertFrom-Json
    $accounts = @($accounts | Where-Object { $_.kind -eq 'AIServices' -or $_.kind -eq 'OpenAI' })

    if ($accounts.Count -eq 0) {
        Write-Bad 'No AIServices or OpenAI accounts found in this subscription.'
        throw 'No candidate Foundry account.'
    }
    # Measured 2026-09-27: 2.3-4.1 s per account, one at a time; 13 accounts took about 56 s
    # with no output, which reads as stuck (ADR-0032).
    Write-Note ("checking {0} candidate account(s), about 4 s each (about {1} s)..." -f $accounts.Count, (4 * $accounts.Count))

    $withClaude = @()
    $checked = 0
    foreach ($a in $accounts) {
        $checked++
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $names = az cognitiveservices account deployment list -g $a.rg -n $a.name --query "[].name" -o tsv 2>$null
        $deps = @($names | Where-Object { $_ -like '*claude*' })
        $found = if ($deps.Count) { "$($deps.Count) Claude deployment(s)" } else { 'no Claude deployment' }
        Write-Note ("  [{0}/{1}] {2}: {3} ({4:N1} s)" -f $checked, $accounts.Count, $a.name, $found, $watch.Elapsed.TotalSeconds)
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

        # Created after the summary is confirmed, with everything else: the summary is the approval,
        # and the guided flow asks for no other one before the installer (ADR-0032).
        $pendingDeployment = [pscustomobject]@{
            name = $chosen.model; model = $chosen.model; version = $chosen.version; sku = $chosen.sku; capacity = [int]$cap
            account = $target.name; resourceGroup = $target.rg
        }
        Write-Note "$($chosen.model) is deployed to $($target.name) after you confirm the summary."

        $withClaude += [pscustomobject]@{ Name = $target.name; Rg = $target.rg; Loc = $target.loc; Models = "$($chosen.model) (deployed after the summary)" }
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
        Invoke-ClaudeInstallAzShown { az cognitiveservices account list --query "[].{n:name, rg:resourceGroup}" -o json } |
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
# A resumed run that recorded a Claude deployment still to create creates it after its summary.
if (-not $pendingDeployment -and ($restored = Get-ClaudeInstallPendingDeployment)) { $pendingDeployment = $restored.Deployment; $providerData = $restored.ProviderData }
$deployed = @(Get-ClaudeDeployment -Account $FoundryAccount -ResourceGroup $FoundryResourceGroup)
if ($pendingDeployment -and $pendingDeployment.account -eq $FoundryAccount) { $deployed += $pendingDeployment }
$modelsStd = ''
$modelsPrm = ''
$recordedDeployments = @()
if ($deployed.Count) {
    Write-Step 'Which models each tier may call'
    Write-Host ''
    $i = 1
    foreach ($d in $deployed) { Write-Host ("      {0,2}. {1}" -f $i, (Format-ClaudeDeployment $d)); $i++ }
    Write-Host ''

    # Premium gets everything. Standard gets everything except Opus, which is
    # five times the price of Sonnet per output token - that is the distinction
    # the two tiers exist to make. Both are editable afterwards with
    # Sync-ClaudeModels.ps1, so this only has to be a sensible start.
    $all = @(Sort-ClaudeFlowOrdinal -InputObject @($deployed.name) -Unique)
    $nonOpus = @(Sort-ClaudeFlowOrdinal -InputObject @($deployed | Where-Object { $_.model -notlike '*opus*' } | ForEach-Object { $_.name }) -Unique)
    if (-not $nonOpus.Count) { $nonOpus = $all }

    $stdPick = if ($PSBoundParameters.ContainsKey('StandardModels')) { $StandardModels -join ',' } else {
        Read-Default -Prompt 'Models for the standard tier' -Default ($nonOpus -join ',') `
            -Help 'Comma-separated deployment names. The default excludes Opus.'
    }
    $prmPick = if ($PSBoundParameters.ContainsKey('PremiumModels')) { $PremiumModels -join ',' } else {
        Read-Default -Prompt 'Models for the premium tier' -Default ($all -join ',') -Help 'Comma-separated deployment names.'
    }
    $standardModelNames = @($stdPick -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $premiumModelNames = @($prmPick -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $standardModelNames.Count -or -not $premiumModelNames.Count) { throw 'Each tier needs at least one deployment. An empty model list means allow all and is not an explicit restriction.' }
    foreach ($selected in @($standardModelNames + $premiumModelNames)) {
        if ($selected -notin $all) { throw "Model '$selected' is not deployed on the selected Foundry account." }
    }

    $modelsStd = ',' + ($standardModelNames -join ',') + ','
    $modelsPrm = ',' + ($premiumModelNames -join ',') + ','
    Write-Ok "standard $modelsStd  premium $modelsPrm"
    # Recorded with the model behind each name, because a deployment may be named anything and the
    # clients configure capabilities by model (ADR-0031).
    $allowed = @(($modelsStd + $modelsPrm) -split ',' | Where-Object { $_ } | Select-Object -Unique)
    $recordedDeployments = @($deployed | Where-Object { $allowed -contains $_.name } | ForEach-Object {
        [ordered]@{ name = $_.name; model = $_.model; version = $_.version }
    })
}
else {
    throw "No Claude deployment is available on '$FoundryAccount'. No tier restrictions were discarded; no gateway will be provisioned."
}

# ------------------------------------------------------------- 2. placement

Write-Step 'Where to put the gateway'

# Reusing an instance adopts its group, region, tier, publisher and name. Dot-sourced, so it sets
# these script variables; used by -ExistingApimName and by the reuse menu below.
$ExistingApim = ''
$useExistingGateway = {
    param($instance)
    $ExistingApim = $instance.name
    # The children are parented to the APIM, so the deployment has to target its resource group,
    # not whatever was answered above.
    if ($ResourceGroup -and $ResourceGroup -ne $instance.resourceGroup) {
        Write-Note "Deploying into '$($instance.resourceGroup)' instead - that is where $($instance.name) lives."
    }
    $ResourceGroup = $instance.resourceGroup
    $Location = ConvertTo-ClaudeArmRegionName ([string]$instance.location)
    $Sku = $instance.sku.name
    $PublisherEmail = $instance.publisherEmail
    # Stable, so re-running does not create a fresh Application Insights and Log Analytics
    # workspace every time.
    $NamePrefix = ($instance.name -replace '^apim-', '')
    Write-Ok "reusing $($instance.name) ($($instance.sku.name), $($instance.resourceGroup))"
    # The deployment fails without a system-assigned identity, so the remedy is said before it (U86).
    $identity = (Get-ClaudeApimReuseProblems -Instance $instance).IdentityProblem
    if ($identity) { Write-Warn2 "$($identity.message). $($identity.remedy)" }
}
. (Join-Path $root 'scripts/ClaudeInstallerPreflight.ps1')
if ($ExistingApimName) {
    # Read as the preflight reads it (apim.existingSku, apim.existingIdentity): present, absent or inconclusive.
    $reuse = Get-ClaudeApimReuseState -Name $ExistingApimName -ResourceGroup $ResourceGroup
    if ($reuse.Verdict -ne 'present') {
        Write-Bad "$($reuse.Detail)."
        throw $(if ($reuse.Verdict -eq 'absent') { 'The gateway to update was not found. Nothing was created.' } else { 'The gateway to update could not be read. Nothing was created.' })
    }
    if ($reuse.SkuProblem) { throw "$($reuse.SkuProblem.message). Nothing was created." }
    $named = $reuse.Instance
    if (-not $named.resourceGroup) { $named | Add-Member -NotePropertyName resourceGroup -NotePropertyValue $reuse.ResourceGroup -Force }
    . $useExistingGateway $named
}
if (-not $Location) { $Location = Invoke-ClaudeInstallAzShown { az cognitiveservices account show -g $FoundryResourceGroup -n $FoundryAccount --query location -o tsv } }
if (-not $Location) {
    Write-Bad "Could not resolve the location of '$FoundryAccount'."
    Write-Note 'Pass -Location explicitly.'
    throw 'Location not resolved.'
}
$ResourceGroup = if ($ResourceGroup) { $ResourceGroup } else {
    Read-Default -Prompt 'Resource group' -Default $FoundryResourceGroup `
        -Help 'Created if it does not exist. Same region as Foundry keeps latency down.'
}
# A gateway being updated keeps its region; a resumed run keeps the recorded one.
if (-not (Test-ClaudeInstallResuming)) { $Location = if ($ExistingApim) { $Location } else { Read-GatewayRegion -Default $Location } }

# ------------------------------------------------- reuse an existing gateway
#
# API Management is the entire cost of this accelerator - about $150/month at list price
# for BasicV2 - and creating a second one by accident is easy to do and easy to
# miss. Earlier versions always generated a random name prefix, so every run
# built a new instance even when a perfectly good one already existed.
#
# Only v2 SKUs are offered. Classic tiers attach the policies happily but meter
# zero Anthropic tokens, so every budget silently reads as zero usage.

if (-not $NamePrefix) {
    # Read as the reuse path reads (Get-ClaudeApimReuseCandidates): a list that cannot be read offers no
    # instance and says so, rather than reading as a subscription without one.
    $candidates = Get-ClaudeApimReuseCandidates
    if ($candidates.Verdict -ne 'present') { Write-Warn2 "The API Management instances in this subscription could not be listed ($($candidates.Detail)), so none is offered for reuse; -ExistingApimName names one." }
    $reusable = @($candidates.Instances)

    if ($reusable.Count) {
        Write-Host ''
        Write-Host '    Existing v2 API Management instances you can reuse:' -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $reusable.Count; $i++) {
            $r = $reusable[$i]
            $has = Invoke-AzOptional { az apim api list -g $r.resourceGroup --service-name $r.name --query "[?name=='claude-foundry'].name" -o tsv }
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
            . $useExistingGateway $reusable[[int]$pick - 1]
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

# Whether the entitlement store can hold the declared developers. Identities are held in API
# Management named values, which cap at 4,096 characters; an object id plus its separator costs 37,
# so a list holds about 110 and the business unit map - whose entries are longer - binds first at
# roughly 93. Derived here rather than pasted, on the same two measured constants
# Measure-ClaudeCeiling.ps1 uses. Without a check the installer took "5000 developers", recommended
# a SKU, deployed happily, and the wall arrived weeks later as a sync refusing to write a named value.
$maxChars = 4096
$oidCost = 37
$listCeiling = [int][math]::Floor(($maxChars - 1) / $oidCost)
$buCeiling = [int][math]::Floor(($maxChars - 1) / 44)

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
    $devs = if ($DeveloperEstimate) { "$DeveloperEstimate" } else { Read-Default -Prompt 'How many developers will use this gateway' -Default '50' `
        -Help 'Used to suggest a SKU, and to cost the choices below at your scale. You can override the suggestion.' }
    $n = 0
    if (-not [int]::TryParse($devs, [ref]$n) -or $n -lt 1) { $n = 50 }
    $script:DeveloperEstimate = $n

    # More developers than named values hold: said here as a note, and asked about after the
    # entitlement store is chosen below, where the Cosmos store is one of the choices (P79). Until
    # P79 this asked "Continue anyway" here, before the tier and the store, and said the Cosmos store
    # was not built; P61 built it on every v2 tier.
    if ($n -gt $buCeiling) {
        Write-Host ''
        Write-Note ("{0} developers is more than named values hold (about {1}). The entitlement store question" -f $n, $buCeiling)
        Write-Note 'below recommends the Cosmos store, which holds them on every v2 tier (docs/SCALE.md).'
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
    if (-not $Yes) { Show-GatewayTierPrices -Region $Location; Write-Host '' }

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

# ------------------------------------------------- the saved record and the chosen gateway
#
# A checkout holds one gateway's record. It is compared with the chosen gateway here, as soon as the
# gateway is known, so a record for another gateway stops the run before the remaining questions
# and before anything is created; P69 compared it at the address question, after every answer (P79).
$savedAddressPath = Join-Path $root 'onboarding\claude-gateway.json'
$addressApimName = if ($ExistingApim) { $ExistingApim } else { "apim-$NamePrefix" }
$savedRecordSetAside = $false
. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\ClaudeGatewayAddressInput.ps1')
if (Test-Path -LiteralPath $savedAddressPath) {
    $saved = Read-ClaudeDecisionRecord -Path $savedAddressPath
    $savedSubscription = Get-ClaudeFlowRecordSubscription -Record $saved
    $selectedGateway = "$ResourceGroup/$addressApimName"
    $recordedGateway = if (Test-ClaudeAddressDraftRecord $saved) { $selectedGateway } else { "$([string]$saved.resourceGroup)/$([string]$saved.apimName)" }
    if ($recordedGateway -ine $selectedGateway -or ($savedSubscription -and $savedSubscription -ine $SubscriptionId)) {
        $recordedScope = if ($savedSubscription) { $savedSubscription } else { 'not recorded' }
        $conflict = "Saved record '$savedAddressPath' names gateway '$recordedGateway' (subscription $recordedScope), but the selected gateway is '$selectedGateway' (subscription $SubscriptionId)."
        $stem = (($recordedGateway -replace '[^A-Za-z0-9._-]', '-') -replace '-+', '-').Trim('-')
        $archivePath = Join-Path (Split-Path $savedAddressPath -Parent) "claude-gateway.$stem.json"
        if (Test-Path -LiteralPath $archivePath) {
            $archivePath = Join-Path (Split-Path $savedAddressPath -Parent) ("claude-gateway.$stem.{0}.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
        }
        $archiveName = Split-Path $archivePath -Leaf
        $archive = [bool]$ArchiveSavedRecord
        if (-not $archive -and -not $Yes) {
            Write-Host ''
            Write-Warn2 $conflict
            $answer = Read-Default -Prompt "Keep that record as $archiveName and start a new one for $selectedGateway (yes/no)" -Default 'yes' `
                -Help 'yes renames the record, which stays beside the new one; no stops here. Nothing has been created.' -Validate {
                    param($x)
                    if ($x -in @('yes','no')) { return $true }
                    Write-Warn2 'Must be yes or no.'
                    return $false
                }
            $archive = $answer -eq 'yes'
        }
        if (-not $archive) {
            throw "$conflict No resources were created. Rerun with -ArchiveSavedRecord to keep that record as $archiveName and start a new one, use a separate checkout for the selected gateway, or back up and move this record before rerunning."
        }
        if ($WhatIfPreference) { Write-Note "WhatIf: would keep the record for $recordedGateway as $archivePath." }
        else {
            Move-Item -LiteralPath $savedAddressPath -Destination $archivePath -WhatIf:$false
            Write-Ok "kept the record for $recordedGateway as $archivePath"
        }
        $savedRecordSetAside = $true
    }
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

# Entitlement store. Named values are still the simplest path below about 93
# developers (the business-unit membership value binds before the tier lists,
# whose measured ceiling is about 110 object ids). Above that, raising the APIM
# SKU does not move the 4,096-character named-value limit; the projection in
# docs/adr/0011-projection-platform.md is the configuration change that moves
# identity data out of policy configuration and into Cosmos.
if (-not $EntitlementStore) {
    $storeOptions = @(
        New-ClaudeChoiceOption -Value 'named-value' -Label 'Named values' `
            -Detail 'No extra Azure components. Holds about 93 developers in bu-members and about 110 per tier list; raising the SKU does not move it.' `
            -Recommended:($devCount -le 93) -Reason 'fits the declared developer count'
        New-ClaudeChoiceOption -Value 'projection' -Label 'Cosmos projection' `
            -Detail 'Private Cosmos entitlement store plus Function resolver. Required around 100-500 developers; one deployer can populate, compare and flip after a clean comparison.' `
            -Recommended:($devCount -gt 93) -Reason 'named values cannot hold the declared developer count'
    )
    if ($Yes) {
        $EntitlementStore = if ($devCount -gt 93) { 'projection' } else { 'named-value' }
        Write-Host ("  -EntitlementStore {0}: selected from the declared developer count under -Yes" -f $EntitlementStore) -ForegroundColor DarkGray
    }
    else {
        $EntitlementStore = Select-ClaudeChoice -Parameter EntitlementStore -Question 'Entitlement store' -Options $storeOptions `
            -WhereToFind @('docs/SCALE.md: named-value ceiling', 'docs/SECURE-PROJECTION.md: projection deployment') `
            -AmbiguousMessage 'Choose named-value or projection explicitly for unattended runs.' `
            -Interactive $true
    }
}
if ($Yes -and $EntitlementStore -eq 'projection' -and -not $DeployProjection) {
    throw 'Cannot choose projection unattended with -Yes unless -DeployProjection is also passed; projection requires a compare-gated deployer run. Nothing was created.'
}
if ($DeployProjection -and -not $WhatIfPreference) {
    . (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
    Assert-ClaudeProjectionPowerShell
}
# Named values for more developers than they hold, said where the store is chosen (P79).
if ($EntitlementStore -eq 'named-value' -and $devCount -gt $buCeiling) {
    Write-Host ''
    Write-Warn2 ("Named values hold about {0} developers, and you said {1}." -f $buCeiling, $devCount)
    Write-Host ''
    Write-Host '      Entitlement lives in API Management named values, which cap at 4,096' -ForegroundColor DarkGray
    Write-Host ("      characters. A tier list holds about {0} object ids; the business unit" -f $listCeiling) -ForegroundColor DarkGray
    Write-Host ("      map holds about {0}, and it runs out first. This is a storage limit," -f $buCeiling) -ForegroundColor DarkGray
    Write-Host '      not a licensing one, and raising the SKU does not move it - a larger' -ForegroundColor DarkGray
    Write-Host '      tier raises how many named values exist, not how long each one may be.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '      The Cosmos projection store holds them on every v2 tier: choose projection' -ForegroundColor DarkGray
    Write-Host '      above, or pass -EntitlementStore projection (docs/SCALE.md, docs/adr/0011).' -ForegroundColor DarkGray
    Write-Host '      Moving to it later is a configuration change rather than a redeployment.' -ForegroundColor DarkGray
    Write-Host ("      With named values you can entitle about {0} people, not {1}, and the" -f $buCeiling, $devCount) -ForegroundColor DarkGray
    Write-Host '      sync will refuse the rest rather than silently dropping them.' -ForegroundColor DarkGray
    Write-Host ''
    $goOn = if (Test-ClaudeInstallResuming) { 'yes' } else { Read-Default -Prompt 'Continue with named values (yes/no)' -Default 'yes' `
        -Help ("yes deploys a gateway that serves the first ~{0} and refuses to add more." -f $buCeiling) -Validate {
            param($x)
            if ($x -in @('yes','no')) { return $true }
            Write-Warn2 'Must be yes or no.'
            return $false
        } }
    if ($goOn -eq 'no') { throw 'Stopped before deploying. Nothing was created. Rerun and choose projection, or pass -EntitlementStore projection.' }
}
$ResolverInboundAccess = if ($ResolverInboundAccess) { $ResolverInboundAccess }
elseif ($EntitlementStore -eq 'projection') {
    switch ($Sku) {
        'BasicV2' { 'public' }
        'StandardV2' { 'private' }
        'PremiumV2' { 'private' }
        default { 'private' }
    }
}
else { 'private' }

if ($EntitlementStore -eq 'projection') {
    if ($Sku -eq 'BasicV2' -and $ResolverInboundAccess -ne 'public') {
        throw 'BasicV2 cannot use a private resolver because Basic v2 has no outbound VNet integration. Use -ResolverInboundAccess public or choose StandardV2/PremiumV2. Nothing was created.'
    }
    if ($Sku -in @('StandardV2','PremiumV2') -and $ResolverInboundAccess -ne 'private') {
        Write-Warn2 "$Sku can reach a private resolver; public resolver was requested explicitly."
    }
    Write-Host ''
    if ($ResolverInboundAccess -eq 'public') {
        Write-Host '  Projection resolver: public, Entra-authenticated resolver.' -ForegroundColor Yellow
        Write-Host '    Basic v2 cannot reach private backends. The resolver allows only the gateway managed identity token, pins tenant and audience, and keeps Cosmos private.' -ForegroundColor DarkGray
        Write-Host '    APIM v2 outbound IP addresses are not a stable security boundary, so IP restrictions are optional defense-in-depth, not the primary control.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Projection resolver: private endpoint.' -ForegroundColor Green
        Write-Host '    Standard v2 and Premium v2 reach it through outbound VNet integration; Cosmos remains private.' -ForegroundColor DarkGray
    }
    try {
        $cost100 = & (Join-Path $PSScriptRoot 'scripts/Measure-ClaudeProjectionCost.ps1') -Developers 100 -AsJson 2>$null 6>$null | Out-String | ConvertFrom-Json
        $cost500 = & (Join-Path $PSScriptRoot 'scripts/Measure-ClaudeProjectionCost.ps1') -Developers 500 -AsJson 2>$null 6>$null | Out-String | ConvertFrom-Json
        Write-Host ("    Cost: about `${0:n2}/month at 100 developers and `${1:n2}/month at 500 developers, excluding APIM." -f [decimal]$cost100.monthly_usd.total, [decimal]$cost500.monthly_usd.total) -ForegroundColor DarkGray
    } catch {
        Write-Host '    Cost: run scripts/Measure-ClaudeProjectionCost.ps1 -P61Scenarios for 100 and 500 developer rows.' -ForegroundColor DarkGray
    }
}

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
# An answer given for the window wins over the live one: it is a change the operator asked for.
if ($RevocationWindowSeconds) { $entitlementCacheSeconds = $RevocationWindowSeconds }
elseif ($liveWindow -and [int]::TryParse("$liveWindow".Trim(), [ref]$liveWindowSeconds) -and $liveWindowSeconds -gt 0) {
    $entitlementCacheSeconds = $liveWindowSeconds
    Write-Host ''
    Write-Host ("    Keeping this gateway's revocation window: {0} seconds." -f $liveWindowSeconds) -ForegroundColor Green
    Write-Host ("    Change it with: Set-ApimNamedValue -ResourceGroup {0} -ApimName {1} -Id entitlement-cache-seconds -Value <seconds>" -f $ResourceGroup, $windowTarget) -ForegroundColor DarkGray
}
elseif ($recordedWindow = Get-ClaudeInstallAnswer 'RevocationWindowSeconds') { $entitlementCacheSeconds = [int]$recordedWindow }
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

$budgetMode = if ($TeamBudgetBehaviour) { $TeamBudgetBehaviour } elseif ($recordedMode = Get-ClaudeInstallAnswer 'TeamBudgetBehaviour') { $recordedMode } else { Read-Default -Prompt 'Team budget behaviour (report/stop)' -Default 'report' `
    -Help 'Either way the spend is attributed. This chooses whether it also refuses.' -Validate {
        param($x)
        if ($x -in @('report','stop')) { return $true }
        Write-Warn2 'Must be report or stop.'
        return $false
    } }

# Whether somebody with no team may use it at all.
Write-Host ''
Write-Host '  May a developer with no team assigned use the gateway?' -ForegroundColor White
Write-Host ''
Write-Host '    allow      they are served, and their spend is recorded against no team.' -ForegroundColor DarkGray
Write-Host '    deny       they are refused until somebody assigns them.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    Start on allow unless every developer already has a team. deny on day one' -ForegroundColor DarkGray
Write-Host '    refuses people who have done nothing wrong.' -ForegroundColor DarkGray

$unassignedMode = if ($UnassignedDevelopers) { $UnassignedDevelopers } elseif ($recordedMode = Get-ClaudeInstallAnswer 'UnassignedDevelopers') { $recordedMode } else { Read-Default -Prompt 'Developers with no team (allow/deny)' -Default 'allow' `
    -Help 'Get-ClaudeBusinessUnit.ps1 reports how many are unassigned, so you can switch this when it reaches zero.' -Validate {
        param($x)
        if ($x -in @('allow','deny')) { return $true }
        Write-Warn2 'Must be allow or deny.'
        return $false
    } }

# The address developers are configured against. This one cannot be retrofitted
# cheaply, which is why it is asked rather than defaulted silently.
Write-Host ''
Write-Host '  What address will developers be configured against?' -ForegroundColor White
Write-Host ''
Write-Host ("    azure      https://{0}.azure-api.net/claude" -f $(if ($ExistingApim) { $ExistingApim } else { "apim-$NamePrefix" })) -ForegroundColor DarkGray
Write-Host '               No extra cost, nothing to set up. The instance name is part of' -ForegroundColor DarkGray
Write-Host '               the address, so replacing the gateway later means reconfiguring' -ForegroundColor DarkGray
Write-Host '               every developer machine.' -ForegroundColor DarkGray
Write-Host '    custom     https://claude.<your-company>.com/claude' -ForegroundColor DarkGray
Write-Host '               Costs a DNS record and a certificate. Replacing the gateway' -ForegroundColor DarkGray
Write-Host '               later becomes a DNS change nobody notices.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    This is the one choice on this page that is expensive to change afterwards.' -ForegroundColor DarkGray

$addressPlan = $null
$addressResult = $null
$savedAddressConfig = $null
# Compared with the chosen gateway after the name prefix: a record here is this gateway's, or a first
# Setup's journal, unless it was set aside for another gateway.
if (-not $savedRecordSetAside -and (Test-Path -LiteralPath $savedAddressPath)) {
    $savedAddressConfig = Read-ClaudeDecisionRecord -Path $savedAddressPath
}
$addressValues = @{}
foreach ($key in 'AddressMode','AddressHostname','AddressCertificateSource','AddressKeyVaultCertificateId','AddressPfxPath','AddressDnsZoneResourceId','AddressDnsMode','AddressReplaceHostname') {
    if ($PSBoundParameters.ContainsKey($key)) { $addressValues[$key] = $PSBoundParameters[$key] }
}
$effectiveAddress = Resolve-ClaudeAddressInputs -Record $savedAddressConfig -Values $addressValues
$addressDefault = $effectiveAddress.AddressMode
$addressMode = if ($AddressMode) { $AddressMode } else { Read-Default -Prompt 'Developer address (azure/custom)' -Default $addressDefault `
    -Help 'Custom configures a supplied certificate, the gateway hostname and DNS, then proves HTTPS before publishing the address.' -Validate {
        param($x)
        if ($x -in @('azure','custom')) { return $true }
        Write-Warn2 'Must be azure or custom.'
        return $false
    } }
if ($addressMode -eq 'custom') {
    . (Join-Path $root 'scripts\ClaudeGatewayAddress.ps1')
    if (-not $AddressHostname) { $AddressHostname = Read-Default -Prompt 'Company hostname' -Default $effectiveAddress.AddressHostname -Help 'A DNS hostname, such as claude.contoso.com; not a URL. The domain is already owned by your organization.' }
    if (-not $AddressCertificateSource) { $AddressCertificateSource = Read-Default -Prompt 'Certificate source (KeyVault/Pfx)' -Default $(if ($effectiveAddress.AddressCertificateSource) { $effectiveAddress.AddressCertificateSource } else { 'KeyVault' }) -Help 'No v2 tier offers a free managed certificate. KeyVault references an existing certificate; Pfx uploads its certificate and private key.' }
    if ($AddressCertificateSource -eq 'KeyVault' -and -not $AddressKeyVaultCertificateId) {
        $AddressKeyVaultCertificateId = Read-Default -Prompt 'Key Vault certificate or secret URL' -Default $effectiveAddress.AddressKeyVaultCertificateId -Help 'Example: https://<vault>.vault.azure.net/certificates/<name>. A versionless reference permits rotation.'
    }
    if ($AddressCertificateSource -eq 'Pfx') {
        if (-not $AddressPfxPath) { $AddressPfxPath = Read-Default -Prompt 'PFX file path' -Default $effectiveAddress.AddressPfxPath -Help 'The file contains the hostname certificate, its private key and chain.' }
        if (-not $AddressCertificatePassword -and -not $Yes) { $AddressCertificatePassword = Read-Host 'PFX password (Enter if none; not recorded)' -AsSecureString }
    }
    if (-not $AddressDnsZoneResourceId -or $AddressDnsMode -eq 'External') {
        $dnsChoice = if ($AddressDnsMode) { $AddressDnsMode } else { Read-Default -Prompt 'DNS hosting (AzureDns/External)' -Default $(if ($effectiveAddress.AddressDnsMode) { $effectiveAddress.AddressDnsMode } else { 'External' }) -Help 'AzureDns writes a CNAME in an existing public zone in this subscription; External prints the record and waits for your provider.' }
        if ($dnsChoice -eq 'AzureDns') {
            $AddressDnsZoneResourceId = Read-Default -Prompt 'Azure DNS zone resource ID' -Default $effectiveAddress.AddressDnsZoneResourceId -Help 'Azure portal > DNS zones > the public zone > Properties > Resource ID.'
        }
        elseif ($dnsChoice -eq 'External') { $AddressDnsZoneResourceId = '' }
        elseif ($dnsChoice -ne 'External') { throw 'DNS hosting must be AzureDns or External.' }
    }
    $addressArgs = @{
        SubscriptionId = $SubscriptionId; ResourceGroup = $ResourceGroup; ApimName = $addressApimName
        Hostname = $AddressHostname; CertificateSource = $AddressCertificateSource; KeyVaultCertificateId = $AddressKeyVaultCertificateId
        PfxPath = $AddressPfxPath; CertificatePassword = $AddressCertificatePassword; DnsZoneResourceId = $AddressDnsZoneResourceId
        ReplaceHostname = $AddressReplaceHostname
    }
    if (-not $ExistingApim) {
        $addressArgs.Gateway = [pscustomobject]@{
            id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$addressApimName"
            name = $addressApimName; location = $Location; sku = @{ name = $Sku }
            properties = @{ provisioningState = 'Succeeded'; hostnameConfigurations = @() }
        }
    }
    $addressPlan = Get-ClaudeAddressPlan @addressArgs
    if ($AddressApprovedPlanFingerprint -and (Get-ClaudeFlowFingerprint @($addressPlan)) -ne $AddressApprovedPlanFingerprint) {
        throw 'The company-address plan changed since the guided review; no installer writes were made. Review the flow again.'
    }
    Write-Host (Format-ClaudeFlowReview @($addressPlan))
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

$desktopSignInRecord = [ordered]@{ kind = 'helper-script' }
$desktopGatewayAudience = 'urn:disabled:claude-extra-audience'
$AuthMode = if ($AuthMode) { $AuthMode } else {
    Read-Default -Prompt 'Developer sign-in (interactive/device/helper)' -Default 'interactive' `
        -Help 'Pick device if any developer works on a machine with no browser - it costs nothing on a laptop.' -Validate {
            param($x)
            if ($x -in @('interactive','device','helper')) { return $true }
            Write-Warn2 'Must be interactive, device or helper.'
            return $false
        }
}

Write-Host ''
Write-Host '  How will Claude Desktop sign in to the gateway?' -ForegroundColor White
Write-Host ''
Write-Host '    helper-script          Default. Desktop runs get-foundry-token, which uses' -ForegroundColor DarkGray
Write-Host '                           the developer Azure CLI sign-in. No app registration,' -ForegroundColor DarkGray
Write-Host '                           no new consent, and the gateway audience stays as the' -ForegroundColor DarkGray
Write-Host '                           Foundry data-plane audiences.' -ForegroundColor DarkGray
Write-Host '    external-idp-browser   Desktop opens the system browser against a public' -ForegroundColor DarkGray
Write-Host '                           Entra app registration. Conditional Access applies' -ForegroundColor DarkGray
Write-Host '                           as browser sign-in. The gateway must accept the' -ForegroundColor DarkGray
Write-Host '                           Desktop app audience for id_token mode, or the API' -ForegroundColor DarkGray
Write-Host '                           audience for access_token mode.' -ForegroundColor DarkGray
Write-Host '    external-idp-broker    Desktop uses the Microsoft Entra broker. This is for' -ForegroundColor DarkGray
Write-Host '                           managed-device or token-protection Conditional Access.' -ForegroundColor DarkGray
Write-Host '                           It needs the broker redirect URIs on the public-client' -ForegroundColor DarkGray
Write-Host '                           app and is not supported on Linux.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '    The helper-script path is unchanged for existing installs.' -ForegroundColor DarkGray

$DesktopSignInKind = if ($DesktopSignInKind) { $DesktopSignInKind } else {
    Read-Default -Prompt 'Claude Desktop sign-in (helper-script/external-idp-browser/external-idp-broker)' -Default 'helper-script' `
        -Help 'Pick an external-idp option only after registering the Desktop public-client app.' -Validate {
            param($x)
            if ($x -in @('helper-script', 'external-idp-browser', 'external-idp-broker')) { return $true }
            Write-Warn2 'Must be helper-script, external-idp-browser or external-idp-broker.'
            return $false
        }
}

if ($DesktopSignInKind -ne 'helper-script') {
    $defaultIssuer = "https://login.microsoftonline.com/$($acct.tenantId)/v2.0"
    $DesktopEntraIssuer = if ($DesktopEntraIssuer) { $DesktopEntraIssuer } else { $defaultIssuer }
    if ($DesktopEntraClientId -and -not (Test-ClaudeGuid $DesktopEntraClientId)) {
        throw "Stopped: -DesktopEntraClientId '$DesktopEntraClientId' is not an application (client) id GUID. Nothing was created."
    }
    # Unattended, nothing can be asked: the app, and for access_token its scope and audience, are passed.
    if ($Yes) {
        $missing = @()
        if (-not $DesktopEntraClientId) { $missing += '-DesktopEntraClientId (the Desktop public-client app; scripts/New-ClaudeDesktopEntraApp.ps1 creates it)' }
        if ($DesktopBearerTokenType -eq 'access_token' -and -not $DesktopEntraScopes) { $missing += '-DesktopEntraScopes' }
        if ($DesktopBearerTokenType -eq 'access_token' -and -not $DesktopEntraAudience) { $missing += '-DesktopEntraAudience' }
        if ($missing.Count) { throw "Stopped: Claude Desktop sign-in $DesktopSignInKind under -Yes needs $($missing -join ', '). Nothing was created." }
    }
    $DesktopEntraClientId = if ($DesktopEntraClientId) { $DesktopEntraClientId } else {
        Read-Default -Prompt 'Desktop Entra application (client) ID' -Default '' `
            -Help 'Create it with scripts/New-ClaudeDesktopEntraApp.ps1, or pass -DesktopEntraClientId for unattended runs.' -Validate {
                param($x)
                if (Test-ClaudeGuid $x) { return $true }
                Write-Warn2 'Must be an application client-id GUID.'
                return $false
            }
    }
    if ($DesktopBearerTokenType -eq 'access_token') {
        $DesktopEntraScopes = if ($DesktopEntraScopes) { $DesktopEntraScopes } else {
            Read-Default -Prompt 'Gateway delegated scope' -Default '' `
                -Help 'Example: api://<gateway-app-id>/user_impersonation. It may require tenant admin consent.' -Validate {
                    param($x)
                    if (-not [string]::IsNullOrWhiteSpace($x)) { return $true }
                    Write-Warn2 'Scopes are required for access_token mode.'
                    return $false
                }
        }
        $DesktopEntraAudience = if ($DesktopEntraAudience) { $DesktopEntraAudience } else {
            Read-Default -Prompt 'Gateway token audience' -Default '' `
                -Help 'Usually the gateway API app ID URI, used by APIM to validate aud.' -Validate {
                    param($x)
                    if (-not [string]::IsNullOrWhiteSpace($x)) { return $true }
                    Write-Warn2 'Audience is required for access_token mode.'
                    return $false
                }
        }
    }
    $desktopSignInRecord = [ordered]@{
        kind = 'external-idp'
        flow = $(if ($DesktopSignInKind -eq 'external-idp-broker') { 'broker' } else { 'browser' })
        bearerTokenType = $DesktopBearerTokenType
        clientId = $DesktopEntraClientId
        issuer = $DesktopEntraIssuer.TrimEnd('/')
    }
    if ($DesktopEntraScopes) { $desktopSignInRecord['scopes'] = $DesktopEntraScopes }
    if ($DesktopEntraAudience) { $desktopSignInRecord['audience'] = $DesktopEntraAudience }
    if ($DesktopEntraResource) { $desktopSignInRecord['resource'] = $DesktopEntraResource }

    $desktopChoiceForValidation = Get-ClaudeDesktopSignIn -Config ([pscustomobject]@{ desktopSignIn = [pscustomobject]$desktopSignInRecord })
    $desktopGatewayAudience = Get-ClaudeDesktopGatewayAudience -DesktopSignIn $desktopChoiceForValidation
    Write-Note "Desktop gateway audience: $desktopGatewayAudience"
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
if (-not (Test-ClaudeInstallResuming)) {
    $StandardGroup = Read-Default -Prompt 'Standard tier group' -Default $StandardGroup
    $PremiumGroup  = Read-Default -Prompt 'Premium tier group'  -Default $PremiumGroup
}
Assert-ClaudeInstallNames ([ordered]@{ StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup; NamePrefix = $NamePrefix })

# Every value below reaches az. Checked before the summary, so a refusal creates nothing (ADR-0032).
Assert-AzArgumentsSafe -Values ([ordered]@{
    SubscriptionId = $SubscriptionId; FoundryAccount = $FoundryAccount; FoundryResourceGroup = $FoundryResourceGroup
    ResourceGroup = $ResourceGroup; Location = $Location; NamePrefix = $NamePrefix; ExistingApimName = $ExistingApim
    PublisherEmail = $PublisherEmail; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup
    DesktopGatewayAudience = $desktopGatewayAudience
})

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
    '  '                    = ''
    # Every choice on the Choices page, in the order asked: the summary is the approval (ADR-0032).
    'Entitlement store'     = $(if ($EntitlementStore -eq 'projection') { "projection, resolver $ResolverInboundAccess" } else { $EntitlementStore })
    'Revocation window'     = $(if ($entitlementCacheSeconds % 60) { "$entitlementCacheSeconds seconds" } else { "$($entitlementCacheSeconds / 60) minutes" })
    'Team budget behaviour' = $budgetMode
    'Developers with no team' = $unassignedMode
    'Developer address'     = $(if ($addressPlan) { "custom, https://$AddressHostname/claude ($AddressCertificateSource; costs shown above)" } else { "azure, https://$apimName.azure-api.net/claude" })
    'Developer sign-in'     = $AuthMode
    'Claude Desktop sign-in'= $(if ($desktopSignInRecord.kind -eq 'external-idp') { "$DesktopSignInKind, app $DesktopEntraClientId, $DesktopBearerTokenType" } else { 'helper-script, through the developer''s Azure CLI sign-in' })
}
if ($pendingDeployment) {
    $rows.Insert(2, 'Claude deployment', ("{0} v{1} on {2}, {3} capacity {4} - deployed first, after you confirm" -f $pendingDeployment.model, $pendingDeployment.version, $pendingDeployment.account, $pendingDeployment.sku, $pendingDeployment.capacity))
}
if (Test-ClaudeInstallResuming) { $rows['Checkpoint'] = Get-ClaudeInstallSummaryRow }
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
if (-not (Read-YesNo $(if (Test-ClaudeInstallResuming) { "Resume from $(Get-ClaudeInstallResumeTitle)?" } elseif ($ExistingApim) { 'Apply this to the existing gateway?' } else { 'Create these resources?' }) $true)) {
    Write-Host ''; Write-Host 'Cancelled.' -ForegroundColor Yellow
    if (Test-ClaudeInstallResuming) { Write-Note "The install checkpoint is kept. To discard it and start again: $(Format-ClaudeInstallResume) -Restart" }
    return
}
Assert-ClaudeInstallDesktopApp $DesktopEntraClientId
# The checkpoint is written here, after the summary is confirmed and before the first change (ADR-0032).
Save-ClaudeInstallCheckpoint

# ---------------------------------------------------------------- 6. deploy

Write-Head 'Deploying'

if ($pendingDeployment -and -not (Test-ClaudeInstallStepSkip 'claude-deployment' -Verify { Test-ClaudeInstallModelDeployment $pendingDeployment.resourceGroup $pendingDeployment.account $pendingDeployment.name })) {
    Write-Step 'Claude deployment'
    $made = New-ClaudeDeployment -Account $pendingDeployment.account -ResourceGroup $pendingDeployment.resourceGroup `
        -Model $pendingDeployment.model -Version $pendingDeployment.version -Sku $pendingDeployment.sku -Capacity $pendingDeployment.capacity -ProviderData $providerData
    Write-Ok "deployed $(Format-ClaudeDeployment $made)"
    Complete-ClaudeInstallStep 'claude-deployment' -Receipt ([pscustomobject]@{ account = $pendingDeployment.account; resourceGroup = $pendingDeployment.resourceGroup; name = $pendingDeployment.name; origin = 'created' })
}

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
if (-not (Test-ClaudeInstallStepSkip 'resource-group' -Idempotent -Verify { Test-ClaudeInstallResourceGroup $ResourceGroup })) {
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
        Invoke-ClaudeInstallAzShown { az group create -n $ResourceGroup -l $Location -o none }
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create resource group '$ResourceGroup' in '$Location'. See the error above."
        }
        Write-Ok "$ResourceGroup (created in $Location)"
    }
    Complete-ClaudeInstallStep 'resource-group' -Receipt ([pscustomobject]@{ name = $ResourceGroup; location = $(if ($rgLocation) { $rgLocation } else { $Location }); origin = $(if ($rgLocation) { 'pre-existing' } else { 'created' }) })
}

Write-Step $(if ($ExistingApim) { 'Claude API and policies (a few minutes)' } else { 'API Management and Application Insights (a few minutes)' })
Write-Note 'Safe to leave running.'
# A recorded deployment is awaited, used or shown first; its body below is not re-indented, so that
# this change reads line by line (ADR-0046 decision 10).
$gatewayPlan = Resolve-ClaudeInstallGatewayStep -ResourceGroup $ResourceGroup -ApimName $apimName
$gatewayUrl = $gatewayPlan.GatewayUrl
if ($gatewayPlan.Run) {

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
                apimHostnameConfigurations = @{ value = @($live.hostnameConfigurations) }
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

Register-ClaudeInstallDeployment $deployName -CreatedApim (-not $ExistingApim -and -not $liveId)
Invoke-ClaudeInstallAzShown { az deployment group create `
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
        desktopExtraAudience=$(if ($desktopGatewayAudience) { $desktopGatewayAudience } else { 'urn:disabled:claude-extra-audience' }) `
        entitlementSource=$(if ($entSrc) { $entSrc } else { 'named-value' }) `
        entitlementResolverUrl=$(if ($entUrl) { $entUrl } else { 'https://resolver-not-deployed.invalid' }) `
        entitlementResolverAudience=$(if ($entAud) { $entAud } else { 'https://resolver-not-deployed.invalid' }) `
        entitlementCacheSeconds=$(if ($entitlementCacheSeconds) { $entitlementCacheSeconds } elseif ($entTtl) { $entTtl } else { 3600 }) `
        buUnassigned=$(if ($unassignedMode) { $unassignedMode } else { 'allow' }) `
    @preserveArgs `
    -o none }

if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. See the error above.' }
Write-Ok 'deployed'

$gatewayUrl = az deployment group show -g $ResourceGroup -n $deployName --query "properties.outputs.gatewayUrl.value" -o tsv 2>$null
if (-not $gatewayUrl) { $gatewayUrl = "https://$apimName.azure-api.net/claude" }
Complete-ClaudeInstallGatewayStep -ResourceGroup $ResourceGroup -ApimName $apimName -GatewayUrl $gatewayUrl -GrantedRole $grantRole `
    -FoundryResourceGroup $FoundryResourceGroup -FoundryAccount $FoundryAccount -DesktopClientId $DesktopEntraClientId
}
if ($addressPlan -and (Test-ClaudeInstallStepSelected 'company-address')) {
    if (Test-ClaudeInstallStepSkip 'company-address' -Verify { Test-ClaudeInstallAddress $ResourceGroup $apimName $AddressHostname $savedAddressPath }) {
        $addressRecord = Read-ClaudeDecisionRecord -Path $savedAddressPath
        $addressResult = [pscustomobject]@{ GatewayUrl = [string]$addressRecord.gatewayUrl; Address = $addressRecord.address }
    }
    else {
    Write-Step 'Company address, certificate and DNS'
    $addressResult = Invoke-ClaudeAddressPlan -Plan $addressPlan -CertificatePassword $AddressCertificatePassword -RecordPath $savedAddressPath
    Complete-ClaudeInstallStep 'company-address' -Receipt ([pscustomobject]@{ hostname = $AddressHostname })
    }
    $gatewayUrl = $addressResult.GatewayUrl
}

# ---------------------------------------------------------------- 7. groups

if (Test-ClaudeInstallStepSelected 'entra-groups') {
    Write-Step 'Entra groups'
    Invoke-ClaudeInstallGroups -Groups @([pscustomobject]@{ Role = 'standard'; Name = $StandardGroup }, [pscustomobject]@{ Role = 'premium'; Name = $PremiumGroup })
}

if (Test-ClaudeInstallStepSelected 'sync') {
    Write-Step 'Sync entitlement'
    Start-ClaudeInstallStep 'sync'
    & (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') -ApimName $apimName -ResourceGroup $ResourceGroup `
        -StandardGroup $StandardGroup -PremiumGroup $PremiumGroup
    Complete-ClaudeInstallStep 'sync'
}

if ($EntitlementStore -eq 'projection' -and $DeployProjection -and -not (Test-ClaudeInstallStepSkip 'projection' -Verify {
        # The live check reads the three deployments, which do not show a switch to the projection, so a run
        # that asks for the switch runs the step again (ADR-0047 decision 13).
        if ($FlipProjectionAfterCleanCompare) { Get-ClaudeInstallVerdict 'absent' 'the switch to the projection is asked for' }
        else { Test-ClaudeInstallDeployments $ResourceGroup @("projection-$NamePrefix", "projection-network-$NamePrefix", "projection-resolver-$NamePrefix") } })) {
    Write-Step 'Projection deployment'
    $resolverApp = Get-ClaudeInstallResolverApp -NamePrefix $NamePrefix -Supplied $ProjectionResolverAppId
    $projectionArgs = @(
        '-ResourceGroup', $ResourceGroup,
        '-ApimName', $apimName,
        '-NamePrefix', $NamePrefix,
        '-Location', $Location,
        '-Sku', $Sku,
        '-ResolverInboundAccess', $ResolverInboundAccess,
        '-StandardGroup', $StandardGroup,
        '-PremiumGroup', $PremiumGroup
    )
    if ($ProjectionResolverAppId) { $projectionArgs += @('-ResolverAppId', $ProjectionResolverAppId) }
    elseif ($resolverApp.Id) { $projectionArgs += @('-ResolverAppId', $resolverApp.Id) }
    $projectionArgs += @('-SubscriptionId', $SubscriptionId)
    if ($FlipProjectionAfterCleanCompare) { $projectionArgs += '-FlipAfterCleanCompare' }
    if ($ProjectionReconcilerResourceId) { $projectionArgs += @('-ReconcilerResourceId', $ProjectionReconcilerResourceId) }
    if ($ProjectionRenewalImageDigest) { $projectionArgs += @('-RenewalImageDigest', $ProjectionRenewalImageDigest) }
    if ($ProjectionRenewalEntryPoint) { $projectionArgs += @('-RenewalEntryPoint', $ProjectionRenewalEntryPoint) }
    if ($ProjectionRenewalActionGroupResourceId) { $projectionArgs += @('-RenewalActionGroupResourceId', $ProjectionRenewalActionGroupResourceId) }
    if ($WhatIfPreference) { $projectionArgs += '-WhatIf' }
    & (Join-Path $root 'scripts/Deploy-ClaudeProjection.ps1') @projectionArgs
    if ($LASTEXITCODE -ne 0) { throw 'Projection deployment failed. The gateway was not flipped.' }
    Complete-ClaudeInstallProjection -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix -App $resolverApp
}

# ------------------------------------------------------- 7b. business units
#
# Offered here because the installer already asks for tiers and budgets, and
# stopping short of the thing those budgets are charged to is an odd seam - the
# first question after a deploy was always "so where do I set up chargeback".
#
# Skipped by default under -Yes: a business unit is a naming decision about the
# customer's own organisation, and guessing one unattended leaves a registry
# entry nobody asked for. Units given as answers are applied, attended or not (ADR-0047).
if (-not (Test-ClaudeInstallStepSelected 'business-units')) {
    # -Steps without business-units: this run neither asks for nor writes a business unit.
}
elseif ($BusinessUnits) {
    Write-Step 'Business units'
    if (-not (Test-ClaudeInstallStepSkip 'business-units' -Verify { Test-ClaudeInstallBusinessUnits $ResourceGroup $apimName $args[0] })) {
        Invoke-ClaudeInstallBusinessUnits -Root $root -Units @($BusinessUnits) -ResourceGroup $ResourceGroup -ApimName $apimName
    }
    . (Join-Path $root 'scripts/ClaudeUsdBudgets.ps1'); . (Join-Path $root 'scripts/ClaudeBudgetModes.ps1')
    Write-ClaudeInstallUsdReconcile -ResourceGroup $ResourceGroup -ApimName $apimName
}
elseif (-not $Yes) {
    Write-Step 'Business units (optional)'
    # A resume skips units it finds in bu-registry; the block below is not re-indented (ADR-0046).
    if (-not (Test-ClaudeInstallStepSkip 'business-units' -Verify { Test-ClaudeInstallBusinessUnits $ResourceGroup $apimName $args[0] })) {
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

        # By its exact name, through the function the answers path uses (ADR-0046 decision 11): az ad group
        # show --group would take a single group whose name only starts with this one.
        $unitGroup = Resolve-ClaudeInstallUnitGroup $buGroup
        if ($unitGroup.Verdict -eq 'inconclusive') {
            Write-Warn2 "Entra group '$buGroup' could not be looked up by name ($($unitGroup.Detail)), so business unit $buId is not written."
            Write-Note $(if ($unitGroup.Detail -match 'groups have a name of that length') { 'Rename or remove one of those groups, or give another group name.' } else { 'Sign in with an account that can read Entra groups in Microsoft Graph, then add the unit with Set-ClaudeBusinessUnit.ps1.' })
            continue
        }
        if ($unitGroup.Verdict -eq 'create-failed') {
            # Set-ClaudeBusinessUnit refuses a unit pointing at a group that
            # does not exist, because it would sync to nobody and read as
            # unused rather than broken. Stop here rather than write one.
            Write-Warn2 "Could not create '$buGroup' - your tenant may restrict group creation."
            Write-Note 'Ask an admin to create it, then run Set-ClaudeBusinessUnit.ps1.'
            continue
        }
        if ($unitGroup.Verdict -eq 'created') { Write-Ok "$buGroup created" } else { Write-Ok "$buGroup exists" }

        $buBudget = Read-Int -Prompt 'Monthly budget, US dollars' -Default 5000 `
            -Help 'Converted to tokens on write. List price, and the counter cannot see cached tokens.'

        & (Join-Path $root 'scripts/Set-ClaudeBusinessUnit.ps1') -Id $buId -Group $buGroup -SkipGroupCheck `
            -MonthlyBudgetUsd $buBudget -ApimName $apimName -ResourceGroup $ResourceGroup
        Add-ClaudeInstallBusinessUnit -Id $buId -GroupId $unitGroup.Id -GroupOrigin $unitGroup.Origin
    }
    Complete-ClaudeInstallStep 'business-units'
    }
}

# --------------------------------------------------------------- 8. package

# A run with -Steps writes the package only when it names onboarding-package; the block below is not
# re-indented, so that this change reads line by line.
if (Test-ClaudeInstallStepSelected 'onboarding-package') {
Write-Step 'Onboarding package'
Start-ClaudeInstallStep 'onboarding-package'
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
    subscriptionId = $SubscriptionId
    # What the guided flow records as the foundation decision (ADR-0032).
    sku           = $Sku
    location      = (ConvertTo-ClaudeArmRegionName $Location)
    foundryAccount = $FoundryAccount
    foundryResourceGroup = $FoundryResourceGroup
    standardGroup = $StandardGroup
    premiumGroup  = $PremiumGroup
    # How developers sign in. Decided once, here, rather than left to whoever
    # runs the setup script on each machine - a fleet where half the
    # workstations authenticate differently is a fleet with two support paths.
    # Changeable later by reissuing this file; it configures nothing itself.
    authMode      = $AuthMode
    entitlementStore = $EntitlementStore
    resolverInboundAccess = $ResolverInboundAccess
    projectionDeployer = './scripts/Deploy-ClaudeProjection.ps1'
    desktopSignIn = $desktopSignInRecord
    # Each Claude deployment the tiers allow, with its model: the workstation setup pins Claude
    # Code by model and declares the model's capabilities (ADR-0031).
    deployments = @($recordedDeployments | ForEach-Object { $_ })
    models = @($recordedDeployments | ForEach-Object { $_.name })
    tiers = @{
        standard = @{ tokensPerMinute = $TpmStandard; tokensPerDay = $QuotaStandard; models = @($standardModelNames); modelAllowList = $modelsStd }
        premium  = @{ tokensPerMinute = $TpmPremium;  tokensPerDay = $QuotaPremium; models = @($premiumModelNames); modelAllowList = $modelsPrm }
    }
    organisation = @{ tokensPerMonth = $QuotaOrg; shared = $true; softCap = $true }
    # The request ceiling, so an unattended Change of the foundation gives it back (P72).
    requestsPerMinute = $CallsPerMinute
    generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
}
$configPath = Join-Path $pkg 'claude-gateway.json'
if ($savedAddressConfig) {
    foreach ($p in $savedAddressConfig.PSObject.Properties) {
        if (-not $config.Contains($p.Name)) { $config[$p.Name] = $p.Value }
    }
}
if ($addressResult) {
    $config['address'] = $addressResult.Address
    $recordToWrite = [pscustomobject]$config
    Set-ClaudeDecision -Record $recordToWrite -Key address -Value $addressResult.Address
    Update-ClaudeAddressArtifacts -RecordPath $configPath -OldUrl $(if ($savedAddressConfig) { $savedAddressConfig.gatewayUrl } else { '' }) -NewUrl $gatewayUrl
    Write-ClaudeDecisionRecord -Record $recordToWrite -Path $configPath
}
else {
    $config.Remove('address')
    $config.Remove('pendingAddress')
    if ($config.Contains('decisions') -and $config.decisions) { $config.decisions.PSObject.Properties.Remove('address') }
    if ($config.decisions -and $config.decisions.foundation) {
        foreach ($name in @($config.decisions.foundation.PSObject.Properties.Name | Where-Object { $_ -like 'address*' })) { $config.decisions.foundation.PSObject.Properties.Remove($name) }
        $config.decisions.foundation | Add-Member -NotePropertyName addressMode -NotePropertyValue azure
    }
    if ($savedAddressConfig -and $savedAddressConfig.address) {
        . (Join-Path $root 'scripts\ClaudeGatewayAddress.ps1')
        Update-ClaudeAddressArtifacts -RecordPath $configPath -OldUrl $savedAddressConfig.gatewayUrl -NewUrl $gatewayUrl
    }
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
}
Write-Ok "config: $configPath"
Complete-ClaudeInstallStep 'onboarding-package' -Receipt ([pscustomobject]@{ path = $configPath })
}

# ---------------------------------------------------------------- 9. verify

if (Test-ClaudeInstallStepSelected 'verify') {
    Write-Step 'Verifying the controls'
    Start-ClaudeInstallStep 'verify'
    $verified = $true
    try {
        & (Join-Path $root 'scripts/Show-Governance.ps1') -ApimName $apimName -ResourceGroup $ResourceGroup -SkipThrottleTest
    }
    catch { Write-Warn2 "Verification could not complete: $($_.Exception.Message)"; $verified = $false }
    Complete-ClaudeInstallStep 'verify' -Incomplete:(-not $verified)
}
Close-ClaudeInstallCheckpoint
# A run with -Steps ran what it was asked to; the next steps belong to a whole install.
if ($Steps) { return }

# ----------------------------------------------------------------- 10. next

Write-Head 'Done'
Write-Host ''
Write-Host "  Gateway   $gatewayUrl" -ForegroundColor Green
Write-Host "  Tenant    $($acct.tenantId)" -ForegroundColor Green
Write-Host ''
Write-Host '  Next:' -ForegroundColor White
Write-Host ''
$nextSteps = [System.Collections.Generic.List[object]]::new()
if ($budgetMode -eq 'stop') {
    $nextSteps.Add([pscustomobject]@{ Title = 'You chose stop for team budgets'; Warn = $true; Detail = @(
        '        The per-team quota is deployed and enforcing. Set a figure per team:'
        "        ./scripts/Set-ClaudeBusinessUnit.ps1 -Id <team> -MonthlyBudgetUsd <n> -ApimName $apimName -ResourceGroup $ResourceGroup"
        '        Until a team has one, nothing refuses it. The counter does not see'
        '        cached tokens, so it triggers later than the dollar figure suggests.'
    ) })
}
if ($addressMode -eq 'custom') {
    $nextSteps.Add([pscustomobject]@{ Title = 'Company address configured and proven'; Warn = $false; Detail = @(
        "        $gatewayUrl is recorded in claude-gateway.json."
        '        Existing developer machines need the redistributed settings.'
        '        A later address change is .\Start-ClaudeGateway.ps1 -Action Change -Change address.'
    ) })
}
$nextSteps.Add([pscustomobject]@{ Title = 'Entitle a developer'; Warn = $false; Detail = @(
    "        ./scripts/Set-ClaudeDeveloper.ps1 -User dev@contoso.com -Tier standard ``"
    "            -ApimName $apimName -ResourceGroup $ResourceGroup"
    '      Takes an email, a UPN or an object id, adds them to the group and'
    '      publishes in one step. The raw route needs an object id, not an email:'
    '        $oid = az ad user show --id dev@contoso.com --query id -o tsv'
    "        az ad group member add --group $StandardGroup --member-id `$oid"
    "        ./scripts/Sync-ClaudeAccess.ps1 -ApimName $apimName -ResourceGroup $ResourceGroup"
    '      Portal route: docs/ONBOARDING.md section 2'
) })
$nextSteps.Add([pscustomobject]@{ Title = 'Send them the setup'; Warn = $false; Detail = @(
    "        ./scripts/New-OnboardingEmail.ps1 -ConfigPath $configPath -To dev@contoso.com"
) })
$nextSteps.Add([pscustomobject]@{ Title = 'Close the direct-access bypass - see docs/SETUP.md section 4.1'; Warn = $true; Detail = @(
    '      Anyone holding Cognitive Services User on the Foundry account'
    '      can skip the gateway entirely and ignore these budgets.'
) })
# ADR-0032: run on its own in a console, the installer ends by offering the FinOps tool. The
# guided flow passes -SkipFinOpsOffer because its FinOps step follows.
$offerFinOps = -not $ChooseFinOps -and -not $SkipFinOpsOffer -and -not $Yes -and (Test-ClaudeInteractive)
if (-not $ChooseFinOps -and -not $SkipFinOpsOffer -and -not $offerFinOps) {
    $nextSteps.Add([pscustomobject]@{ Title = "Choose optional FinOps tooling: .\scripts\Select-ClaudeFinOpsTooling.ps1 -Region $Location"; Warn = $false; Detail = @() })
}
Write-NextSteps -Steps $nextSteps
if ($ChooseFinOps -or ($offerFinOps -and (Read-YesNo "Set up a FinOps tool now? It lists each tool with its monthly price in $Location" $true))) {
    & (Join-Path $root 'scripts\Select-ClaudeFinOpsTooling.ps1') -Region $Location -SubscriptionId $SubscriptionId
}
elseif ($offerFinOps) {
    Write-Note "Later: .\scripts\Select-ClaudeFinOpsTooling.ps1 -Region $Location"
}
