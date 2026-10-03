param([Parameter(Mandatory)][string]$AnswersPath)
$ErrorActionPreference = 'Stop'
if ($env:P93_INSTALLER_UI_PLAN_JSON) { $env:P93_INSTALLER_UI_PLAN_JSON; exit 0 }
$root = Split-Path $PSScriptRoot -Parent
$output = & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Setup -PlanOnly -AnswersPath $AnswersPath 2>&1
$text = ($output | ForEach-Object { [string]$_ }) -join "`n"
$fingerprint = ''
if ($text -match '(?im)fingerprint[:\s]+([A-Za-z0-9:._-]+)') { $fingerprint = $Matches[1] }
[pscustomobject]@{ schemaVersion = 1; fingerprint = $fingerprint; text = $text } | ConvertTo-Json -Compress
