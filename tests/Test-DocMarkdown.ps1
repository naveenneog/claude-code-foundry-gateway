# Offline Markdown command and table-shape guard. No network, Azure login or packages needed.
param([string]$Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$fail = 0

function Assert($Label, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else {
        Write-Host "  [FAIL] $Label - $Detail" -ForegroundColor Red
        $script:fail++
    }
}

function Get-RepoMarkdownFiles([string]$Repo) {
    $files = @(& git -C $Repo ls-files '*.md')
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
    foreach ($file in $files) {
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $file.Replace('/', [IO.Path]::DirectorySeparatorChar)
    }
}

Write-Host 'Markdown commands and tables' -ForegroundColor Cyan
$files = @(Get-RepoMarkdownFiles $Root)
Assert 'at least 100 markdown files were scanned' ($files.Count -ge 100) "$($files.Count) markdown file(s) scanned"

$maskedAuthorization = New-Object Collections.Generic.List[string]
$tableFences = New-Object Collections.Generic.List[string]
foreach ($relative in $files) {
    $path = Join-Path $Root $relative
    $lines = [IO.File]::ReadAllLines($path)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match 'Authorization:\s*\*{6}') {
            $maskedAuthorization.Add(('{0}:{1}' -f $relative, ($i + 1)))
        }
        if ($line -match '^\s*\|') {
            $count = [regex]::Matches($line, '```').Count
            if (($count % 2) -eq 1) { $tableFences.Add(('{0}:{1}' -f $relative, ($i + 1))) }
        }
    }
}

Assert 'no masked Authorization bearer headers are committed' ($maskedAuthorization.Count -eq 0) ($maskedAuthorization -join '; ')
Assert 'no fenced code block opens inside a table row' ($tableFences.Count -eq 0) ($tableFences -join '; ')

if ($fail) { Write-Host "$fail markdown assertion(s) failed."; exit 1 }
Write-Host "Markdown commands and tables hold: $($files.Count) markdown files scanned." -ForegroundColor Green
exit 0
