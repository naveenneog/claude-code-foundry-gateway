<#
.SYNOPSIS
    Validates, previews and publishes the tenant access catalog through the private projection runner.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAccessCatalogAdministration.ps1')
Invoke-ClaudeAccessCatalogAdministration -ResourceGroup $ResourceGroup -ApimName $ApimName -Path $Path -WhatIf:$WhatIfPreference -Confirm:$false
