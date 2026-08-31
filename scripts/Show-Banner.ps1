<#
.SYNOPSIS
    Prints the project banner. Dot-source, then call Show-ClaudeBanner.

.DESCRIPTION
    The art is deliberately pure ASCII, which means there is exactly one
    rendering and nothing to detect. An earlier version used block characters
    and had to fall back when the console could not display them; it also had
    to be saved as UTF-8 with a BOM, because Windows PowerShell 5.1 reads .ps1
    files as ANSI otherwise and mangled the art at parse time. None of that
    applies here - this renders identically on every console and code page.
#>

function Show-ClaudeBanner {
    [CmdletBinding()]
    param(
        [string]$Subtitle = 'Governed gateway for Claude on Microsoft Foundry'
    )

    $cyan = "`e[36m"; $dim = "`e[90m"; $white = "`e[97m"; $off = "`e[0m"
    # PowerShell 5.1 does not understand `e in a double-quoted string.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $esc = [char]27
        $cyan = "$esc[36m"; $dim = "$esc[90m"; $white = "$esc[97m"; $off = "$esc[0m"
    }

    $art = @'
 _____               _            _____ _           _        _____       _     
|   __|___ _ _ ___ _| |___ _ _   |     | |___ _ _ _| |___   |     |___ _| |___ 
|   __| . | | |   | . |  _| | |  |   --| | .'| | | . | -_|  |   --| . | . | -_|
|__|  |___|___|_|_|___|_| |_  |  |_____|_|__,|___|___|___|  |_____|___|___|___|
                          |___|                                                 
'@

    # Measured from the art rather than hard-coded, so the rule stays flush if
    # the art is ever swapped again. TrimEnd because two lines are padded out
    # with trailing spaces.
    $width = ($art -split "`r?`n" | ForEach-Object { $_.TrimEnd().Length } |
              Measure-Object -Maximum).Maximum

    Write-Host ''
    Write-Host ("{0}{1}{2}" -f $cyan, $art, $off)
    Write-Host ("{0}S E T U P{1}  {2}{3}{1}" -f $white, $off, $dim, $Subtitle)
    Write-Host ("{0}{1}{2}" -f $dim, ('-' * $width), $off)
    Write-Host ("{0}Developer{1} Naveen Gopalakrishna   {2}github.com/naveenneog{1}" -f $dim, $off, $cyan)
    Write-Host ''
}
