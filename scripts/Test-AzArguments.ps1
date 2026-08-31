<#
.SYNOPSIS
    Flags Azure CLI arguments that cmd.exe will re-parse on Windows.

.DESCRIPTION
    On Windows `az` is a .cmd shim, so every argument is handed to cmd.exe.
    PowerShell only wraps a native argument in quotes when it contains a space,
    so an argument with no space reaches cmd.exe bare and its metacharacters
    are interpreted.

    This has now bitten this repository twice:

      --query "[?contains(name,'claude')].name"
        -> ].name was unexpected at this time

      --uri "https://.../members?$select=id&$top=999"
        -> '$top' is not recognized as an internal or external command

    Both are silent in the worst way: the error text is a non-empty string, so
    `if ($result)` reads it as success and the script carries on with garbage.

    Brackets and braces are safe. & ^ < > | ( ) are not.

    The check walks the syntax tree rather than matching text, so PowerShell's
    own redirections - 2>$null, 2>&1 - are not mistaken for az arguments. They
    are consumed by PowerShell and never reach cmd.exe.
#>

param([string]$Root = (Split-Path $PSScriptRoot -Parent))

# ( and ) only matter inside --query; a bare URL may legitimately contain them
# in other tools, and JMESPath is where they actually appear here.
$always = '&', '^', '<', '>', '|'

$findings = @()
$scanned = 0

foreach ($file in Get-ChildItem $Root -Recurse -Include *.ps1 |
                  Where-Object { $_.FullName -notmatch 'node_modules' }) {

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$errors)
    if (-not $ast) { continue }
    $scanned++

    $commands = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)

    foreach ($cmd in $commands) {
        $name = $null
        try { $name = $cmd.GetCommandName() } catch { }
        if ($name -ne 'az') { continue }

        $elements = @($cmd.CommandElements)
        for ($i = 1; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]

            # Only literal text can be judged statically. A variable's contents
            # are unknown until runtime.
            $value = $null
            if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $value = $el.Value
            }
            elseif ($el -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
                # Interpolated: judge the literal skeleton. A variable could
                # still smuggle a metacharacter in, but the fixed text is what
                # these bugs have always been.
                $value = $el.Value
            }
            else { continue }

            if ([string]::IsNullOrEmpty($value)) { continue }
            # A space makes PowerShell quote the whole argument, so cmd.exe
            # receives it intact.
            if ($value -match '\s') { continue }

            $hits = @($always | Where-Object { $value.Contains($_) })

            $prev = if ($i -gt 1) { $elements[$i - 1].Extent.Text } else { '' }
            if ($prev -eq '--query' -and ($value.Contains('(') -or $value.Contains(')'))) {
                $hits += '( )'
            }

            if ($hits.Count) {
                $findings += [pscustomobject]@{
                    File  = $file.Name
                    Line  = $el.Extent.StartLineNumber
                    Chars = ($hits -join ' ')
                    Text  = $el.Extent.Text
                }
            }
        }
    }
}

Write-Host ''
Write-Host "Azure CLI argument check - $scanned script(s)" -ForegroundColor Cyan

if (-not $findings) {
    Write-Host '  [OK]   no argument will be re-parsed by cmd.exe' -ForegroundColor Green
    Write-Host ''
    exit 0
}

foreach ($f in $findings) {
    Write-Host ("  [FAIL] {0}:{1}  contains {2}" -f $f.File, $f.Line, $f.Chars) -ForegroundColor Red
    Write-Host ("         {0}" -f $f.Text) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Filter in PowerShell, or call the REST API directly, so cmd.exe never sees these.' -ForegroundColor Yellow
Write-Host ''
exit 1
