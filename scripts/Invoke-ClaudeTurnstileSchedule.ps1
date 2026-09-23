<#
.SYNOPSIS
    One scheduled pass: recent usage to Turnstile, then governance, as a workload identity.

.DESCRIPTION
    What the job in infra/turnstile-schedule.bicep runs each hour, and what you run to repeat
    a pass by hand. Everything it needs is on the gateway: the connection that
    Connect-ClaudeTurnstile.ps1 stored, and the business units.

      1. Export-ClaudeTurnstileUsage.ps1 with its own window, the last 120 minutes ending 15
         minutes ago. Consecutive passes overlap, so a missed pass is recovered by the next,
         and Turnstile keeps one copy of each row.
      2. Governance, in the direction the connection says budgets are authored. Gateway pushes
         units, teams and budgets to Turnstile; Turnstile pulls changed budgets back and
         applies them.

    A workload identity cannot hold the delegated Turnstile.Manage scope. It asks for an
    application token for the Turnstile API instead, which carries the Turnstile.Admin app
    role that Connect-ClaudeTurnstile.ps1 -ExporterPrincipalId assigned. Turnstile accepts that
    only from its pinned tenant.

    Exits non-zero if either step fails, so the failure shows in the job's execution history.

.EXAMPLE
    ./scripts/Invoke-ClaudeTurnstileSchedule.ps1

.EXAMPLE
    ./scripts/Invoke-ClaudeTurnstileSchedule.ps1 -SkipGovernance
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$ApimName = $env:CLAUDE_APIM,
    [switch]$SkipGovernance
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')

$started = [datetime]::UtcNow
if (-not (az account show --query id -o tsv 2>$null)) { throw 'Not signed in. In the job this is az login --identity; by hand, az login.' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}
$integration = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)
if (-not $integration) { throw "$ApimName is not connected to Turnstile. Run ./scripts/Connect-ClaudeTurnstile.ps1." }

$export = & (Join-Path $PSScriptRoot 'Export-ClaudeTurnstileUsage.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName

$governance = 'skipped'
if (-not $SkipGovernance) {
    # --resource rather than --scope: a managed identity gets tokens for a resource, and the
    # Turnstile API's resource is its Application ID URI. A person gets their delegated scope.
    $resource = "api://$($integration['clientId'])"
    $token = az account get-access-token --resource $resource --query accessToken -o tsv 2>$null
    if (-not $token) {
        throw "Could not get a token for $resource. Assign this identity Turnstile's admin app role: ./scripts/Connect-ClaudeTurnstile.ps1 -ExporterPrincipalId <object id>."
    }
    $sync = Join-Path $PSScriptRoot 'Sync-ClaudeTurnstileGovernance.ps1'
    $result = if ([string]$integration['budgetAuthority'] -eq 'Turnstile') {
        & $sync -Direction FromTurnstile -Apply -AccessToken $token.Trim() -ResourceGroup $ResourceGroup -ApimName $ApimName
    }
    else {
        & $sync -AccessToken $token.Trim() -ResourceGroup $ResourceGroup -ApimName $ApimName
    }
    $governance = if ($result.Direction -eq 'FromTurnstile') { "from Turnstile: $($result.Changes) change(s), $($result.Applied) applied" }
    else {
        # Counted by outcome: Turnstile answers an unchanged budget with 200 and no change, and
        # refuses a team budget above its unit's, so a bare count would hide both.
        $set = @($result.Budgets | Where-Object { "$_" -like 'set *' }).Count
        $refused = @($result.Budgets | Where-Object { "$_" -like 'refused *' })
        "to Turnstile: $($result.Catalog); budgets set $set, refused $($refused.Count)" + $(if ($refused.Count) { " ($($refused -join '; '))" } else { '' })
    }
}

[pscustomobject][ordered]@{
    Started     = $started.ToString('o')
    Seconds     = [int]([datetime]::UtcNow - $started).TotalSeconds
    Window      = "$($export.From) .. $($export.To)"
    Requests    = $export.Requests
    CacheEvents = $export.CacheEvents
    CostUsd     = $export.CostUsd
    Batches     = $export.Batches
    Governance  = $governance
} | ConvertTo-Json -Compress
