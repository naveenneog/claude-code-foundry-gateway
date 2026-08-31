# Ensures PowerShell scripts containing non-ASCII characters are saved as UTF-8
# WITH a byte-order mark.
#
# Windows PowerShell 5.1 reads .ps1 files as ANSI unless a BOM says otherwise,
# so a UTF-8 file without one has its non-ASCII characters mangled at parse
# time - long before anything is printed. That produced mojibake in the banner
# even though the console code page was 65001, which is why the console-based
# check did not catch it.
#
# PowerShell 7 reads UTF-8 by default, so this is invisible there.

param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [switch]$Check
)

$fixed = 0
$checked = 0

Get-ChildItem $Root -Recurse -Include *.ps1 |
    Where-Object { $_.FullName -notmatch 'node_modules' } |
    ForEach-Object {
        $checked++
        $bytes = [IO.File]::ReadAllBytes($_.FullName)

        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $hasNonAscii = $false
        foreach ($b in $bytes) { if ($b -gt 127) { $hasNonAscii = $true; break } }

        if ($hasNonAscii -and -not $hasBom) {
            if ($Check) {
                Write-Host ("  [FAIL] {0} - non-ASCII without a BOM" -f $_.Name) -ForegroundColor Red
            } else {
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                [IO.File]::WriteAllText($_.FullName, $text, (New-Object Text.UTF8Encoding $true))
                Write-Host ("  added BOM  {0}" -f $_.Name) -ForegroundColor Yellow
            }
            $script:fixed++
        }
        elseif ($hasNonAscii) {
            Write-Host ("  [OK]   {0}" -f $_.Name) -ForegroundColor DarkGray
        }
    }

Write-Host ''
if ($Check) {
    if ($fixed) {
        Write-Host "$fixed file(s) would be mangled by Windows PowerShell 5.1. Run without -Check to fix." -ForegroundColor Red
        exit 1
    }
    Write-Host "$checked script(s) checked, encoding is safe for PowerShell 5.1." -ForegroundColor Green
    # Explicit: without it $LASTEXITCODE keeps whatever the previous command
    # left behind, so a caller can read a stale failure as this script's result.
    exit 0
} else {
    Write-Host "$checked script(s) checked, $fixed fixed." -ForegroundColor $(if ($fixed) { 'Yellow' } else { 'Green' })
    exit 0
}
