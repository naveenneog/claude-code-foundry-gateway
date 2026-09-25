<#
.SYNOPSIS
    Reconcile USD budgets from the gateway's categorized ledger, on demand.
.DESCRIPTION
    The same engine runs every five minutes in the optional AUM service, using its
    managed identity, gateway writer lease and audit. This Direct command uses Azure
    CLI sign-in and conditional ARM writes. It refuses Turnstile authority.
    Publish-ClaudeQueries.ps1 must have installed the current ClaudeChargeback.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName,
    [string]$WorkspaceId,
    [string]$SubscriptionId,
    [switch]$ManagedIdentity,
    [string]$Python
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
if (-not $ResourceGroup) { $ResourceGroup = Select-ClaudeResourceGroup }
if (-not $ApimName) { $ApimName = Select-ClaudeGateway -ResourceGroup $ResourceGroup -ScriptRoot $PSScriptRoot }
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
if (-not $SubscriptionId) { throw 'Sign in with az login, or az login --identity in the scheduled environment.' }
if (-not $WorkspaceId) {
    $workspace = Select-ClaudeWorkspace -ResourceGroup $ResourceGroup -ApimName $ApimName -ScriptRoot $PSScriptRoot
    $WorkspaceId = az monitor log-analytics workspace show --ids $workspace --query customerId -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $WorkspaceId) { throw 'Cannot resolve the selected workspace customer id.' }
    Write-Host 'WorkspaceId source: the gateway-linked workspace, Overview > Workspace ID.'
}
$root = Split-Path $PSScriptRoot -Parent
if (-not $Python) { $Python = Join-Path $root '.venv-aum-service\Scripts\python.exe' }
if (-not (Test-Path $Python)) { throw 'Create .venv-aum-service and install service/aum/requirements.txt first, or pass -Python.' }
$before = $env:PYTHONPATH
try {
    $env:PYTHONPATH = Join-Path $root 'service\aum'
    $id = "/subscriptions/$($SubscriptionId.Trim())/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
    $arguments = @('-m', 'aum_service.usd_command', '--gateway-id', $id, '--workspace-id', $WorkspaceId.Trim())
    if ($ManagedIdentity) { $arguments += '--managed-identity' }
    & $Python @arguments
    if ($LASTEXITCODE -ne 0) { throw 'USD reconciliation failed. Existing state was not intentionally lifted; inspect the error and freshness.' }
}
finally { $env:PYTHONPATH = $before }
