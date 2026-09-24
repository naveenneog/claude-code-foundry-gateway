<#
.SYNOPSIS
    Choose independent FinOps tools, with cost, sign-in roles and operations explained.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [ValidateSet('None','Direct','AumService','Turnstile','TurnstileAum')][string]$Tool,
    [string]$Region,
    [hashtable]$AumServiceParameters = @{},
    [string]$TurnstilePath, [string]$TurnstileParameters, [string]$SubscriptionId,
    [switch]$Accept
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
$prices = if ($Region) { Get-ClaudeAumPrices -Region $Region } else { $null }
$options = @(Get-ClaudeFinOpsChoices -Prices $prices)
Write-Host "`nChoose FinOps tooling. Neither tool is required by the other." -ForegroundColor Cyan
for ($i=0; $i -lt $options.Count; $i++) {
    $o = $options[$i]
    Write-Host ("  {0}. {1}: {2}" -f ($i + 1), $o.Label, $o.Cost)
    Write-Host "     Sign-in: $($o.Who). Needs: $($o.Needs)."
    Write-Host "     $($o.Implications)" -ForegroundColor DarkGray
}
Write-Host '  Scoped managers require AUM service or Turnstile. Developers never sign in to a FinOps tool.'
if (-not $Tool) {
    $answer = Read-Host 'Choose a number (no default)'
    $n = 0
    if (-not [int]::TryParse($answer, [ref]$n) -or $n -lt 1 -or $n -gt $options.Count) { throw 'Choose one of the five options.' }
    $Tool = $options[$n - 1].Id
}
if ($Tool -eq 'None') { Write-Host 'No FinOps infrastructure requested. Gateway enforcement is unchanged.'; return }
if ($Tool -eq 'Direct') { Write-Host 'Install the AUM client and choose its Direct backend. No resources created; see docs/AUM-SERVICE.md.'; return }
if ($Tool -eq 'AumService') {
    if ($Region) { $AumServiceParameters.Location = $Region }
    if ($SubscriptionId) { $AumServiceParameters.SubscriptionId = $SubscriptionId }
    if ($Accept) { $AumServiceParameters.Accept = $true }
    & (Join-Path $PSScriptRoot 'Deploy-ClaudeAumService.ps1') @AumServiceParameters -WhatIf:$WhatIfPreference
    return
}
if (-not $TurnstilePath -or -not (Test-Path (Join-Path $TurnstilePath 'scripts\deploy'))) {
    throw 'For Turnstile, clone naveenneog/turnstile and pass -TurnstilePath. Its deployment guide prices the chosen architecture.'
}
if (-not $TurnstileParameters -or -not (Test-Path $TurnstileParameters) -or -not $SubscriptionId) {
    throw 'Turnstile needs -TurnstileParameters and -SubscriptionId. Use docs/TURNSTILE.md; do not point its APIM integration at the governed Claude gateway.'
}
Write-Host 'The Turnstile deployer runs its regional plan before deployment and asks for confirmation. No AUM service is created.'
if ($PSCmdlet.ShouldProcess($TurnstilePath, 'Run Turnstile deployment with its explicit parameters')) {
    Push-Location $TurnstilePath
    try {
        & python -m scripts.deploy deploy --subscription $SubscriptionId --parameters $TurnstileParameters
        if ($LASTEXITCODE) { throw 'Turnstile deployment failed. No AUM service was created.' }
    }
    finally { Pop-Location }
}
if ($Tool -eq 'TurnstileAum') { Write-Host 'Configure AUM with the Turnstile endpoint and token scope after deployment. Use server-advertised capabilities.' }
