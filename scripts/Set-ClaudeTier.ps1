<#
.SYNOPSIS
    Reads and changes what each tier may do.

.DESCRIPTION
    A tier answers "what may this developer do": which models they may call,
    how many tokens a minute, and how many a day. Membership is separate - that
    comes from the Entra groups Sync-ClaudeAccess.ps1 resolves - and so is
    chargeback, which is the business unit. See ADR-0008 for why those are
    different axes.

    Everything here is a named value, so a change takes effect on the next
    request with no redeploy.

    **There are two tiers, and this cannot make a third.** The gateway policy
    names `standard` and `premium` directly, in five places: resolving the tier
    from the allow lists, checking the model against the tier's list, the
    per-minute limit, the daily quota, and the refusal message. A third tier is
    a policy change plus the named values to go with it, not a configuration
    change, and pretending otherwise here would produce a tier the gateway
    ignores.

.PARAMETER Tier
    standard or premium.

.PARAMETER TokensPerMinute
    Burst ceiling for one developer in this tier.

.PARAMETER DailyQuota
    Tokens per developer per day in this tier.

.PARAMETER Models
    Comma-separated deployment names this tier may call. Checked against what
    is actually deployed unless -SkipModelCheck.

.EXAMPLE
    ./scripts/Set-ClaudeTier.ps1 -List
    ./scripts/Set-ClaudeTier.ps1 -Tier standard -DailyQuota 750000
    ./scripts/Set-ClaudeTier.ps1 -Tier premium -Models claude-opus-5,claude-sonnet-5
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory = $true)]
    [ValidateSet('standard', 'premium')]
    [string]$Tier,

    [Parameter(ParameterSetName = 'Set')][int]$TokensPerMinute,
    [Parameter(ParameterSetName = 'Set')][int]$DailyQuota,
    [Parameter(ParameterSetName = 'Set')][string]$Models,
    [Parameter(ParameterSetName = 'Set')][switch]$SkipModelCheck,

    [Parameter(ParameterSetName = 'List', Mandatory = $true)][switch]$List,

    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$FoundryAccount,
    [string]$FoundryResourceGroup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup }

function Get-Nv($id) { Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $id }

$TIERS = @('standard', 'premium')

if ($List -or $PSCmdlet.ParameterSetName -eq 'List') {
    Write-Host ''
    Write-Host ("Tiers on {0}" -f $ApimName) -ForegroundColor Cyan
    Write-Host ''
    Write-Host ("  {0,-10} {1,16} {2,16} {3,10}  {4}" -f 'Tier', 'Tokens/minute', 'Tokens/day', 'Members', 'Models')
    Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
    foreach ($t in $TIERS) {
        $allow = [string](Get-Nv "allow-$t")
        $members = @($allow.Trim(',') -split ',' | Where-Object { $_ }).Count
        $models = [string](Get-Nv "models-$t")
        $modelList = @($models.Trim(',') -split ',' | Where-Object { $_ })
        $shown = if ($modelList.Count) { $modelList -join ', ' } else { 'every deployed model' }
        Write-Host ("  {0,-10} {1,16:n0} {2,16:n0} {3,10}  {4}" -f $t, [long](Get-Nv "tpm-$t"), [long](Get-Nv "quota-$t"), $members, $shown)
    }
    Write-Host ''
    Write-Host '  An empty model list means the tier is not restricted to particular models.' -ForegroundColor DarkGray
    Write-Host '  Membership comes from the Entra groups the sync resolves, not from here.' -ForegroundColor DarkGray
    Write-Host '  There are two tiers because the policy names them; a third is a policy change.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

if (-not ($PSBoundParameters.ContainsKey('TokensPerMinute') -or
          $PSBoundParameters.ContainsKey('DailyQuota') -or
          $PSBoundParameters.ContainsKey('Models'))) {
    throw "Nothing to change. Pass -TokensPerMinute, -DailyQuota or -Models, or use -List."
}

$changes = @()

if ($PSBoundParameters.ContainsKey('TokensPerMinute')) {
    if ($TokensPerMinute -lt 1) { throw "-TokensPerMinute must be at least 1." }
    $changes += @{ Id = "tpm-$Tier"; Was = [string](Get-Nv "tpm-$Tier"); Now = [string]$TokensPerMinute; Label = 'tokens per minute' }
}

if ($PSBoundParameters.ContainsKey('DailyQuota')) {
    if ($DailyQuota -lt 1) { throw "-DailyQuota must be at least 1." }
    $changes += @{ Id = "quota-$Tier"; Was = [string](Get-Nv "quota-$Tier"); Now = [string]$DailyQuota; Label = 'tokens per day' }
}

if ($PSBoundParameters.ContainsKey('Models')) {
    $wanted = @($Models -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    # A tier that allows a model the account does not serve produces a refusal
    # naming a model that looks correct, which is a long way to travel for a
    # typo. Checked against what is deployed rather than against a list.
    if ($wanted.Count -and -not $SkipModelCheck) {
        . (Join-Path $PSScriptRoot 'ClaudeModelDeployment.ps1')
        if (-not $FoundryAccount) {
            $accts = @((az cognitiveservices account list --query "[].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })
            foreach ($a in $accts) {
                $arg = (az cognitiveservices account list --query "[].{n:name,rg:resourceGroup}" -o json | ConvertFrom-Json | Where-Object { $_.n -eq $a.Trim() }).rg
                if (@(Get-ClaudeDeployment -Account $a.Trim() -ResourceGroup $arg).Count) { $FoundryAccount = $a.Trim(); $FoundryResourceGroup = $arg; break }
            }
        }
        if ($FoundryAccount) {
            $deployed = @(Get-ClaudeDeployment -Account $FoundryAccount -ResourceGroup $FoundryResourceGroup).name
            $unknown = @($wanted | Where-Object { $_ -notin $deployed })
            if ($unknown.Count) {
                throw ("Not deployed on ${FoundryAccount}: " + ($unknown -join ', ') + ". Deployed: " +
                       ($deployed -join ', ') + ". A tier that allows a model the account does not serve " +
                       "refuses the caller with a model name that looks right. -SkipModelCheck overrides.")
            }
        }
        else {
            Write-Warning "Could not find a Foundry account with Claude deployments to check against; not verifying the model names."
        }
    }

    $value = if ($wanted.Count) { ',' + ($wanted -join ',') + ',' } else { ',,' }
    $changes += @{ Id = "models-$Tier"; Was = [string](Get-Nv "models-$Tier"); Now = $value; Label = 'models' }
}

Write-Host ''
Write-Host ("Tier '{0}' on {1}" -f $Tier, $ApimName) -ForegroundColor Cyan
Write-Host ''
foreach ($c in $changes) {
    if ($c.Was -eq $c.Now) {
        Write-Host ("  {0,-18} unchanged ({1})" -f $c.Label, $c.Now) -ForegroundColor DarkGray
        continue
    }
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $c.Id -Value $c.Now
    Write-Host ("  {0,-18} {1}  ->  {2}" -f $c.Label, $c.Was, $c.Now) -ForegroundColor Green
}

Write-Host ''
Write-Host '  In effect on the next request - named values need no redeploy.' -ForegroundColor DarkGray
Write-Host '  Membership is unchanged; it comes from the Entra groups the sync resolves.' -ForegroundColor DarkGray
Write-Host ''
