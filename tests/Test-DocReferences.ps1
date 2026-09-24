# Offline documentation guard. Run from either PowerShell 5.1 or PowerShell 7.
# Markdown links are relative to their page; script examples run at repo root.
# The scope is the user guides, not the historical ledger or ADRs. Links INTO
# those records are still checked. No network, Azure login or packages needed.
#
# GitHub heading rules, checked 2026-09-24:
# https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#section-links
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

function Get-GuideFiles([string]$Repo) {
    foreach ($name in @('README.md', 'DEVELOPER.md', 'guide\README.md')) {
        $p = Join-Path $Repo $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { Get-Item -LiteralPath $p }
    }
    foreach ($folder in @('docs', 'onboarding')) {
        $p = Join-Path $Repo $folder
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $p -Filter '*.md' -File |
            Where-Object { $_.Name -notin @('STATUS.md', 'ROADMAP.md', 'UNKNOWNS.md', 'CHARTER.md') }
    }
}

function Test-ExactRepositoryPath([string]$Repo, [string]$Path, [hashtable]$DirectoryCache) {
    $base = $Repo.TrimEnd('\', '/')
    $Path = $Path.TrimEnd('\', '/')
    if ($Path -eq $base) { return $true }
    if (-not $Path.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $current = $base
    foreach ($part in ($Path.Substring($base.Length + 1) -split '[/\\]')) {
        if (-not $DirectoryCache.ContainsKey($current)) {
            $DirectoryCache[$current] = @(Get-ChildItem -LiteralPath $current -Force | ForEach-Object Name)
        }
        # Windows accepts wrong case; GitHub's repository links do not.
        if ($DirectoryCache[$current] -cnotcontains $part) { return $false }
        $current = Join-Path $current $part
    }
    return $true
}

function Get-MarkdownLines([string]$Text) {
    $fence = ''
    $length = 0
    $lines = $Text -split '\r?\n'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i] -replace '^(?:[ ]{0,3}>[ ]?)+', ''
        if ($line -match '^[ ]{0,3}(`{3,}|~{3,})(.*)$') {
            $mark = $Matches[1]
            if (-not $fence) { $fence = $mark.Substring(0, 1); $length = $mark.Length }
            elseif ($mark.StartsWith($fence) -and $mark.Length -ge $length -and -not $Matches[2].Trim()) {
                $fence = ''
            }
            [pscustomobject]@{ Number = $i + 1; Text = ''; Original = $lines[$i] }
        }
        else {
            $visible = if ($fence) { '' } else { $line }
            [pscustomobject]@{ Number = $i + 1; Text = $visible; Original = $lines[$i] }
        }
    }
}

function Get-HeadingSlug([string]$Heading) {
    $s = $Heading.Trim() -replace '\s+#+\s*$', ''
    $s = $s -replace '<[^>]+>', ''
    $s = $s -replace '!?\[([^\]]*)\]\([^)]*\)', '$1'
    $s = $s -replace '!?\[([^\]]*)\]\[[^\]]*\]', '$1'
    $s = $s -replace '(`+)(.*?)\1', '$2'
    $s = $s -replace '(\*+|~{2})(.*?)\1', '$2'
    $s = $s -replace '(?<!\w)(_+)(.*?)\1(?!\w)', '$2'
    $s = [Net.WebUtility]::HtmlDecode($s).ToLowerInvariant().Trim()
    # Keep Unicode letters/marks/numbers and literal hyphens/underscores.
    # Do not collapse spaces: "one  two" becomes "one--two" on GitHub.
    $s = $s -replace '[^\p{L}\p{M}\p{N}_ -]', ''
    $s.Replace(' ', '-')
}

function Get-DocumentAnchors([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    $lines = @(Get-MarkdownLines $text)
    $anchors = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $headings = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Text
        foreach ($m in [regex]::Matches($line, '<a\b[^>]*\b(?:id|name)\s*=\s*["'']([^"'']+)["'']')) {
            [void]$anchors.Add($m.Groups[1].Value)
        }
        $title = $null
        if ($line -match '^[ ]{0,3}#{1,6}[ \t]+(.+?)\s*$') { $title = $Matches[1] }
        elseif ($i -gt 0 -and $line -match '^[ ]{0,3}(?:=+|-+)[ \t]*$' -and $lines[$i - 1].Text.Trim()) {
            $title = $lines[$i - 1].Text
        }
        if ($null -eq $title) { continue }
        $base = Get-HeadingSlug $title
        $slug = $base
        $suffix = 0
        while ($headings.Contains($slug)) { $suffix++; $slug = "$base-$suffix" }
        [void]$headings.Add($slug)
        [void]$anchors.Add($slug)
    }
    return ,$anchors
}

function Get-MarkdownLinks([object[]]$Lines) {
    $definitions = @{}
    foreach ($line in $Lines) {
        if ($line.Text -match '^[ ]{0,3}\[([^\]]+)\]:[ \t]*(?:<([^>]+)>|(\S+))') {
            $key = ($Matches[1] -replace '\s+', ' ').ToLowerInvariant()
            $target = if ($Matches[2]) { $Matches[2] } else { $Matches[3] }
            $definitions[$key] = $target
            [pscustomobject]@{ Line = $line.Number; Target = $target }
        }
    }
    foreach ($line in $Lines) {
        $s = $line.Text
        if ($s -match '^[ ]{0,3}\[[^\]]+\]:') { continue }
        # Inline code is literal text, not a link or a custom anchor.
        $s = $s -replace '(`+)(.*?)\1', ''
        # Balanced destination parentheses allow paths such as "guide(v2).md".
        foreach ($m in [regex]::Matches($s, '(?<!\\)\]\(\s*(?:<(?<angle>[^>]+)>|(?<bare>(?:[^()\s\\]|\\.|(?<open>\()|(?<-open>\)))+)(?(open)(?!)))(?:\s+["''][^"'']*["''])?\s*\)')) {
            $target = if ($m.Groups['angle'].Success) { $m.Groups['angle'].Value } else { $m.Groups['bare'].Value }
            [pscustomobject]@{ Line = $line.Number; Target = $target }
        }
        foreach ($m in [regex]::Matches($s, '(?<![!\\])\[([^\]]+)\](?:\[([^\]]*)\])?(?!\()')) {
            $key = if ($m.Groups[2].Value) { $m.Groups[2].Value } else { $m.Groups[1].Value }
            $key = ($key -replace '\s+', ' ').ToLowerInvariant()
            if ($definitions.ContainsKey($key)) {
                [pscustomobject]@{ Line = $line.Number; Target = $definitions[$key] }
            }
        }
    }
}

function New-ReferenceFailure($File, $Line, $Kind, $Detail) {
    [pscustomobject]@{ File = $File; Line = $Line; Kind = $Kind; Detail = $Detail }
}

function Get-ScriptParameters([string]$Path) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse script parameters: $Path" }
    $names = @{}
    foreach ($p in $ast.ParamBlock.Parameters) {
        $names[$p.Name.VariablePath.UserPath] = $true
        foreach ($attr in $p.Attributes) {
            if ($attr.TypeName.Name -eq 'Alias') {
                foreach ($arg in $attr.PositionalArguments) { $names[$arg.Value] = $true }
            }
        }
    }
    $binding = @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
    if ($binding.Count) {
        foreach ($name in @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
                'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable')) {
            $names[$name] = $true
        }
        if ($binding[0].NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' -and $_.Argument.Extent.Text -ne '$false' }) {
            $names['WhatIf'] = $true
            $names['Confirm'] = $true
        }
    }
    $names
}

function Get-DocReferenceFailures([string]$Repo) {
    $anchorCache = @{}
    $parameterCache = @{}
    $directoryCache = @{}
    foreach ($file in @(Get-GuideFiles $Repo)) {
        $relative = $file.FullName.Substring($Repo.TrimEnd('\', '/').Length + 1)
        $text = [IO.File]::ReadAllText($file.FullName)
        $lines = @(Get-MarkdownLines $text)
        foreach ($link in @(Get-MarkdownLinks $lines)) {
            $target = $link.Target -replace '\\([() ])', '$1'
            if ($target -match '^(?:[a-z][a-z0-9+.-]*:|//)') { continue }
            $parts = $target -split '#', 2
            $path = [uri]::UnescapeDataString(($parts[0] -split '\?', 2)[0])
            if (-not $path) { $resolved = $file.FullName }
            elseif ($path.StartsWith('/')) { $resolved = Join-Path $Repo $path.TrimStart('/') }
            else { $resolved = Join-Path $file.DirectoryName $path }
            $resolved = [IO.Path]::GetFullPath($resolved)
            if (-not (Test-Path -LiteralPath $resolved)) {
                New-ReferenceFailure $relative $link.Line 'link' $target
                continue
            }
            if (-not (Test-ExactRepositoryPath $Repo $resolved $directoryCache)) {
                New-ReferenceFailure $relative $link.Line 'link-case' "$target (path case or outside repository)"
                continue
            }
            if ($parts.Count -eq 2 -and $parts[1] -and [IO.Path]::GetExtension($resolved) -eq '.md') {
                if (-not $anchorCache.ContainsKey($resolved)) { $anchorCache[$resolved] = Get-DocumentAnchors $resolved }
                $anchor = [uri]::UnescapeDataString($parts[1])
                if (-not $anchorCache[$resolved].Contains($anchor)) {
                    New-ReferenceFailure $relative $link.Line 'anchor' $target
                }
            }
        }
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $number = $i + 1
            $line = $lines[$i].Original
            while ($line -match '(?<!`)`[ \t]*$' -and $i + 1 -lt $lines.Count) {
                $i++
                $line = ($line -replace '`[ \t]*$', '') + ' ' + ($lines[$i].Original -replace '^\s*>?\s*', '')
            }
            $pattern = '(?<![\w/\\.-])(?:(?:\.[/\\])?scripts[/\\][\w.-]+\.ps1|\.[/\\][\w.-]+\.ps1)\b'
            foreach ($m in [regex]::Matches($line, $pattern)) {
                $scriptPath = $m.Value -replace '^\.[/\\]', ''
                $resolved = Join-Path $Repo $scriptPath
                if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                    New-ReferenceFailure $relative $number 'script' $m.Value
                    continue
                }
                if (-not (Test-ExactRepositoryPath $Repo ([IO.Path]::GetFullPath($resolved)) $directoryCache)) {
                    New-ReferenceFailure $relative $number 'script-case' $m.Value
                    continue
                }
                # In Get-Help the path is data; -Full belongs to Get-Help, not
                # to the referenced script. Still verify that the file exists.
                if ($line.Substring(0, $m.Index) -match '\bGet-Help\s+(?:-Name\s+)?$') { continue }
                $tail = $line.Substring($m.Index + $m.Length)
                if ($tail -notmatch '^[ \t]+-[A-Za-z]') { continue }
                if (-not $parameterCache.ContainsKey($resolved)) { $parameterCache[$resolved] = Get-ScriptParameters $resolved }
                # Stop at Markdown's closing backtick or the next shell command.
                $tail = ($tail -split '[`|;#]', 2)[0]
                $tail = $tail -replace "'(?:''|[^'])*'|`"(?:``.|[^`"])*`"", 'VALUE'
                foreach ($p in [regex]::Matches($tail, '(?<!\S)-([A-Za-z][\w]*)(?=[:\s,)]|$)')) {
                    $name = $p.Groups[1].Value
                    if (-not $parameterCache[$resolved].ContainsKey($name)) {
                        New-ReferenceFailure $relative $number 'parameter' "$($m.Value) -$name"
                    }
                }
            }
        }
    }
}

Write-Host 'Documentation references - files, GitHub anchors, scripts and parameters' -ForegroundColor Cyan
$guides = @(Get-GuideFiles $Root)
Assert 'user-facing guides were found' ($guides.Count -gt 0)
$broken = @(Get-DocReferenceFailures $Root)
foreach ($b in $broken) {
    Write-Host ("  [FAIL] {0}:{1} [{2}] {3}" -f $b.File, $b.Line, $b.Kind, $b.Detail) -ForegroundColor Red
}
Assert 'every user-facing reference resolves' ($broken.Count -eq 0) "$($broken.Count) broken reference(s)"

# Test-All supplies a private TEMP per process. Standalone callers may set TEMP
# as well; never create fixtures beside source files while other checks read it.
$scratchRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$scratch = Join-Path $scratchRoot ('docrefs-' + [guid]::NewGuid().ToString('N'))
Assert 'mutation copies use the process-private scratch root' (
    [IO.Path]::GetDirectoryName($scratch).TrimEnd('\', '/') -eq $scratchRoot.TrimEnd('\', '/'))
$utf8 = New-Object Text.UTF8Encoding($false)
function Write-Fixture([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, (($Text -replace '\r?\n', "`r`n").TrimEnd() + "`r`n"), $utf8)
}
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'docs'), (Join-Path $scratch 'scripts') -Force | Out-Null
    $readme = Join-Path $scratch 'README.md'
    $guide = Join-Path $scratch 'docs\guide(v2).md'
    $tool = Join-Path $scratch 'scripts\Get-Example.ps1'
    Write-Fixture $tool '[CmdletBinding(SupportsShouldProcess)] param([Alias("Name")][string]$ResourceGroup)'
    Write-Fixture (Join-Path $scratch 'Install-Example.ps1') 'param([switch]$Yes)'
    $heading = @'
# Overview
## A **bold** `code_name` & detail!
## Repeat
## Repeat
## Repeat-1
## Two  spaces
Setext title
------------
<a name="old-anchor"></a>
```markdown
## Not a heading
[literal](missing.md)
```
'@
    Write-Fixture $guide $heading
    # Keep this test file ASCII while exercising UTF-8 headings and URI escapes.
    $unicodeHeading = '## Caf' + [char]0xE9 + ' ' + [char]0x398
    Write-Fixture $guide ($heading + "`r`n" + $unicodeHeading)
    $valid = @'
# Home
[guide](docs/guide(v2).md#a-bold-code_name--detail)
[second](docs/guide(v2).md#repeat-1)
[collision](docs/guide(v2).md#repeat-1-1)
[spaces](docs/guide(v2).md#two--spaces)
[setext](docs/guide(v2).md#setext-title)
[alias](docs/guide(v2).md#old-anchor)
[encoded](docs/guide%28v2%29.md#overview)
[unicode](docs/guide(v2).md#caf%C3%A9-%CE%B8)
[root](/docs/guide(v2).md)
[directory](docs/)
[reference][intro]
[intro]: docs/guide(v2).md#overview
`[not-a-link](missing.md)`
```powershell
./scripts/Get-Example.ps1 -ResourceGroup 'Contoso' `
    -Name 'Contoso' -WhatIf
./Install-Example.ps1 -Yes
Get-Help ./scripts/Get-Example.ps1 -Full
```
'@
    Write-Fixture $readme $valid
    $r = @(Get-DocReferenceFailures $scratch)
    Assert 'valid links, duplicate/Setext/HTML anchors, scripts and aliases pass' ($r.Count -eq 0) ($r | Out-String)

    $mutations = @(
        @{ Label = 'broken relative link'; From = 'docs/guide%28v2%29.md'; To = 'docs/missing.md'; Kind = 'link' },
        @{ Label = 'broken heading anchor'; From = '#repeat-1)'; To = '#missing-heading)'; Kind = 'anchor' },
        @{ Label = 'heading hidden in a code fence'; From = '#repeat-1)'; To = '#not-a-heading)'; Kind = 'anchor' },
        @{ Label = 'renamed script'; From = 'scripts/Get-Example.ps1'; To = 'scripts/Get-Renamed.ps1'; Kind = 'script' },
        @{ Label = 'missing root script'; From = './Install-Example.ps1'; To = './Install-Missing.ps1'; Kind = 'script' },
        @{ Label = 'wrong parameter'; From = '-ResourceGroup'; To = '-ResourceGruop'; Kind = 'parameter' },
        @{ Label = 'wrong continued parameter'; From = '-Name'; To = '-Wrong'; Kind = 'parameter' },
        @{ Label = 'broken reference definition'; From = '[intro]: docs/guide(v2).md#overview'; To = '[intro]: docs/missing.md'; Kind = 'link' },
        @{ Label = 'wrong-case link'; From = 'docs/guide%28v2%29.md'; To = 'docs/Guide%28v2%29.md'; Kind = 'link-case' },
        @{ Label = 'wrong-case script'; From = 'scripts/Get-Example.ps1'; To = 'scripts/get-example.ps1'; Kind = 'script-case' }
    )
    foreach ($mutation in $mutations) {
        $changed = $valid.Replace($mutation.From, $mutation.To)
        Assert "mutation applied: $($mutation.Label)" ($changed -cne $valid)
        Write-Fixture $readme $changed
        $r = @(Get-DocReferenceFailures $scratch)
        Assert "detected: $($mutation.Label)" (@($r | Where-Object Kind -eq $mutation.Kind).Count -gt 0) ($r | Out-String)
    }
}
finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }

if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "Documentation references hold: $($guides.Count) guides; all mutations caught." -ForegroundColor Green
exit 0
