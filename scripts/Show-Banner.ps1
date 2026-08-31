<#
.SYNOPSIS
    Prints the project banner. Dot-source, then call Show-ClaudeBanner.

.DESCRIPTION
    Two renderings. The block-character version looks better, but needs a
    console that can both encode and display them - a Windows console left on a
    legacy code page turns them into mojibake, which is worse than plain ASCII.
    Show-ClaudeBanner picks based on what the console actually reports, and
    -Ascii forces the safe one.
#>

function Show-ClaudeBanner {
    [CmdletBinding()]
    param(
        [string]$Subtitle = 'Governed gateway for Claude on Microsoft Foundry',
        [switch]$Ascii
    )

    $cyan = "`e[36m"; $dim = "`e[90m"; $white = "`e[97m"; $off = "`e[0m"
    # PowerShell 5.1 does not understand `e in a double-quoted string.
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $esc = [char]27
        $cyan = "$esc[36m"; $dim = "$esc[90m"; $white = "$esc[97m"; $off = "$esc[0m"
    }

    # Does this console handle the block characters? Windows consoles on a
    # legacy code page will happily accept the string and render nonsense.
    $unicodeOk = -not $Ascii
    if ($unicodeOk -and ($env:OS -eq 'Windows_NT')) {
        try {
            $cp = [Console]::OutputEncoding.CodePage
            # 65001 = UTF-8, 1200 = UTF-16
            if ($cp -ne 65001 -and $cp -ne 1200) { $unicodeOk = $false }
        }
        catch { $unicodeOk = $false }
    }

    $block = @'
   ▄▀█ ▀█ █ █ █▀█ █▀▀   █▀▀ █   ▄▀█ █ █ █▀▄ █▀▀   █▀▀ █▀█ █▀▄ █▀▀
   █▀█ █▄ █▄█ █▀▄ ██▄   █▄▄ █▄▄ █▀█ █▄█ █▄▀ ██▄   █▄▄ █▄█ █▄▀ ██▄
'@

    # A boxed banner rather than a second figlet. An ASCII figlet at this width
    # renders "Azure Claude Code" almost illegibly, and a fallback nobody can
    # read is worse than a plain one. This cannot be mangled.
    $asciiArt = @'
  +----------------------------------------------------------------------+
  |                                                                      |
  |          A Z U R E     C L A U D E     C O D E                       |
  |                                                                      |
  +----------------------------------------------------------------------+
'@

    Write-Host ''
    Write-Host $cyan -NoNewline
    Write-Host $(if ($unicodeOk) { $block } else { $asciiArt })
    Write-Host $off -NoNewline

    # Named asciiArt, not ascii: PowerShell variables are case-insensitive, so
    # $ascii would BE the -Ascii switch parameter, and assigning a string to a
    # typed switch fails with "cannot convert to SwitchParameter".
    $bar = if ($unicodeOk) { [string]([char]0x2500) * 72 } else { '-' * 72 }

    Write-Host ("  {0}S E T U P{1}  {2}{3}{1}" -f $white, $off, $dim, $Subtitle)
    Write-Host ("  {0}{1}{2}" -f $dim, $bar, $off)
    Write-Host ("  {0}Developer{1} Naveen Gopalakrishna   {2}github.com/naveenneog{1}" -f $dim, $off, $cyan)
    Write-Host ''
}
