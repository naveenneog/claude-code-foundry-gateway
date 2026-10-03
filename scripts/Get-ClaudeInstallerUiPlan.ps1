param([Parameter(Mandatory)][string]$AnswersPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Setup -PlanOnly -AnswersPath $AnswersPath 2>&1
$text = ($output | ForEach-Object { [string]$_ }) -join "`n"
$fingerprint = ''
if ($text -match '(?m)^Fingerprint:\s+([a-f0-9]{64})\s*$') { $fingerprint = $Matches[1] }
[pscustomobject]@{ schemaVersion = 1; fingerprint = $fingerprint; text = $text } | ConvertTo-Json -Compress
