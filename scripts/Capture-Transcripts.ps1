<#
.SYNOPSIS
    Captures offline script help for documentation without running setup or Azure commands.
.DESCRIPTION
    These are help transcripts, not evidence of a live deployment. No identities,
    cached credentials, client profiles or cloud resources are inspected.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs/transcripts'))

$ErrorActionPreference = 'Stop'
if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Write offline help transcripts')) { return }
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
foreach ($script in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    $text = Get-Help $script.FullName -Full | Out-String -Width 96
    $text = $text.Replace($PSScriptRoot, './scripts')
    $text = "Offline help transcript; script not executed.`n`n$text"
    $text | Set-Content (Join-Path $OutputPath "$($script.BaseName).txt") -Encoding UTF8
}
Write-Host "Offline help transcripts written to $OutputPath"