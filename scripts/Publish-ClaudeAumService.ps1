<#
.SYNOPSIS
    Publishes reviewed Python code to an already chosen AUM service, with a remote Linux build.
.DESCRIPTION
    Does not provision resources or change roles, network, storage or app settings.
    Uses Azure CLI's Entra-authenticated OneDeploy path; no publishing password.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\aum-service.json')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
$record = Get-Content $RecordPath -Raw | ConvertFrom-Json
if ($record.schemaVersion -ne 1 -or -not $record.functionName -or -not $record.subscriptionId) { throw 'Not an AUM service deployment record.' }
if (-not $PSCmdlet.ShouldProcess($record.functionName, 'Publish AUM code with remote build; infrastructure choices remain unchanged')) { return }
$zip = New-ClaudeAumLocalFile -Extension 'zip'
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source = Join-Path $root 'service\aum'
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($entry in @(Get-ChildItem $source -Recurse -File | Where-Object { $_.FullName -notmatch '__pycache__|\.pyc$' })) {
            $relative = $entry.FullName.Substring($source.Length + 1).Replace('\','/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $entry.FullName, $relative) | Out-Null
        }
    }
    finally { $archive.Dispose() }
    Invoke-ClaudeAumAz @('functionapp','deployment','source','config-zip','--name',$record.functionName,
        '--resource-group',$record.resourceGroup,'--subscription',$record.subscriptionId,'--src',$zip,
        '--build-remote','true','--timeout','1200','-o','json') | Out-Null
    [pscustomobject]@{ Published=$true; Function=$record.functionName; Utc=[datetime]::UtcNow.ToString('o') }
}
finally { Remove-Item $zip -ErrorAction SilentlyContinue }
