<#
.SYNOPSIS
    Lands memory exported from first-party Claude into the files Claude Code and
    Cowork actually read.

.DESCRIPTION
    Claude.ai memory does not come across to Foundry by itself. There is no
    Anthropic account in third-party mode, so the import flow in Claude's own
    settings has no target here.

    It can still be moved, because the two ends line up:

      - Anthropic documents a prompt-based export. You ask Claude to list
        everything it has stored about you and it returns one code block.
        See support.claude.com/en/articles/12123587
      - Claude Code and Cowork read CLAUDE.md, which is plain Markdown

    So the exported block becomes a CLAUDE.md. This script puts it in the right
    file at the right scope without destroying what is already there.

    Scopes, and who they reach:

      user         ~/.claude/CLAUDE.md
                   That one person, everywhere they work. Read by the CLI, the
                   IDE extensions, and Cowork.

      managed      C:\Program Files\ClaudeCode\CLAUDE.md, or the macOS and
                   Linux equivalents. Everyone on the fleet, above every user
                   and project file. For shared standards, not personal memory.
                   Needs an elevated shell.

      project      ./CLAUDE.md in a repository. Everyone who clones it.

    A note that matters for Cowork: in Cowork sessions Claude Code deliberately
    skips @-imports inside user-scope memory files, so a CLAUDE.md that pulls
    its content in by reference will look empty there. Inline the content, which
    is what this script does.

.EXAMPLE
    ./Import-ClaudeMemory.ps1 -Path .\exported-memory.md

.EXAMPLE
    Get-Clipboard | ./Import-ClaudeMemory.ps1 -Scope user

.EXAMPLE
    ./Import-ClaudeMemory.ps1 -Path .\house-style.md -Scope managed
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(ValueFromPipeline = $true)]
    [string[]]$InputObject,
    [string]$Path,
    [ValidateSet('user', 'managed', 'project')]
    [string]$Scope = 'user',
    [string]$Destination,
    [string]$Title = 'Imported from Claude.ai memory',
    [switch]$Replace
)

begin {
    $ErrorActionPreference = 'Stop'
    $piped = [System.Collections.Generic.List[string]]::new()
    $banner = Join-Path $PSScriptRoot 'Show-Banner.ps1'
    if (Test-Path $banner) { . $banner; Show-ClaudeBanner -Subtitle 'Memory import' }
}

process { if ($InputObject) { foreach ($l in $InputObject) { $piped.Add($l) } } }

end {
    $text = if ($Path) {
        if (-not (Test-Path $Path)) { throw "Not found: $Path" }
        Get-Content $Path -Raw
    } elseif ($piped.Count) {
        $piped -join "`n"
    } else {
        throw 'Pass -Path, or pipe the exported text in.'
    }

    # Anthropic's export prompt asks for one fenced code block, so people
    # usually paste the fence along with it. Strip it rather than making them.
    $trimmed = $text.Trim()
    if ($trimmed -match '(?s)^```[a-zA-Z]*\s*\r?\n(.*?)\r?\n```\s*$') {
        $text = $Matches[1]
        Write-Host '    unwrapped the code fence' -ForegroundColor DarkGray
    }
    $text = $text.Trim()
    if (-not $text) { throw 'Nothing to import - the input was empty.' }

    if (-not $Destination) {
        $Destination = switch ($Scope) {
            'user' { Join-Path $env:USERPROFILE '.claude\CLAUDE.md' }
            'project' { Join-Path (Get-Location) 'CLAUDE.md' }
            'managed' {
                if ($IsMacOS)      { '/Library/Application Support/ClaudeCode/CLAUDE.md' }
                elseif ($IsLinux)  { '/etc/claude-code/CLAUDE.md' }
                else               { Join-Path $env:ProgramFiles 'ClaudeCode\CLAUDE.md' }
            }
        }
    }

    Write-Host ''
    Write-Host "    scope       : $Scope"
    Write-Host "    destination : $Destination"
    Write-Host "    content     : $(($text -split "`n").Count) line(s), $($text.Length) chars"

    if ($Scope -eq 'managed') {
        Write-Host ''
        Write-Host '    Managed scope reaches every developer and outranks their own files.' -ForegroundColor Yellow
        Write-Host '    Use it for shared standards, not for one person''s memory.' -ForegroundColor Yellow
        Write-Host '    Writing here needs an elevated shell.' -ForegroundColor DarkGray
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd'
    $block = @"
<!-- claude-memory-import: begin -->
## $Title

_Imported $stamp from first-party Claude. Edit freely - this is a plain
Markdown file that Claude Code and Cowork read at the start of a session._

$text
<!-- claude-memory-import: end -->
"@

    $existing = if (Test-Path $Destination) { Get-Content $Destination -Raw } else { '' }
    $marker = '<!-- claude-memory-import: begin -->'

    $final = if ($Replace -or -not $existing.Trim()) {
        $block
    }
    elseif ($existing.Contains($marker)) {
        # Re-importing replaces the previous block rather than stacking another
        # copy underneath it, which is what makes this safe to run twice.
        Write-Host '    replacing the previous imported block' -ForegroundColor DarkGray
        [regex]::Replace(
            $existing,
            '(?s)' + [regex]::Escape($marker) + '.*?<!-- claude-memory-import: end -->',
            { $block })
    }
    else {
        # Anything already written by hand is kept, and the import is appended
        # below it - losing a CLAUDE.md someone curated would be a poor trade
        # for a convenience script.
        Write-Host '    appending below the existing content' -ForegroundColor DarkGray
        $existing.TrimEnd() + "`n`n" + $block
    }

    if ($PSCmdlet.ShouldProcess($Destination, 'Write CLAUDE.md')) {
        $dir = Split-Path $Destination -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if ($existing -and -not $Replace) {
            Copy-Item $Destination "$Destination.bak" -Force
            Write-Host "    backed up to $(Split-Path $Destination -Leaf).bak" -ForegroundColor DarkGray
        }
        Set-Content -Path $Destination -Value $final -Encoding UTF8
        Write-Host ''
        Write-Host "    [OK]   written" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Verify: start Claude Code and run /memory - the file should be listed.' -ForegroundColor DarkGray
    Write-Host '  Cowork reads the same file, but skips @-imports inside it, so keep' -ForegroundColor DarkGray
    Write-Host '  the content inline rather than referenced.' -ForegroundColor DarkGray
    Write-Host ''
}
