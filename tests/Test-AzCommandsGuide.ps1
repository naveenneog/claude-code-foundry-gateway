param(
    [switch]$SkipAzHelp
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$guide = Join-Path $root 'docs\AZ-COMMANDS.md'
$policy = Join-Path $root 'infra\policy.xml'
$mainBicep = Join-Path $root 'infra\main.bicep'

$script:fail = 0
function Assert($Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
    }
}

function Read-Text($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing $Path" }
    Get-Content -LiteralPath $Path -Raw
}

function Get-BashCommands($Markdown) {
    $commands = New-Object Collections.Generic.List[string]
    foreach ($block in [regex]::Matches($Markdown, '(?ms)^```(?:bash|sh)\s*$(.*?)^```\s*$')) {
        $current = ''
        foreach ($rawLine in ($block.Groups[1].Value -split "`r?`n")) {
            $line = $rawLine.Trim()
            if (-not $line -or $line.StartsWith('#')) { continue }
            if ($line.EndsWith('\')) {
                $current += $line.Substring(0, $line.Length - 1).TrimEnd() + ' '
                continue
            }
            $current += $line
            if ($current.TrimStart().StartsWith('az ')) { $commands.Add($current.Trim()) }
            $current = ''
        }
    }
    $commands.ToArray()
}

function Split-ShellWords([string]$Line) {
    $words = New-Object Collections.Generic.List[string]
    $sb = [Text.StringBuilder]::new()
    $quote = [char]0
    $escape = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($escape) { [void]$sb.Append($ch); $escape = $false; continue }
        if ($ch -eq '\') { $escape = $true; continue }
        if ($quote) {
            if ($ch -eq $quote) { $quote = [char]0 } else { [void]$sb.Append($ch) }
            continue
        }
        if ($ch -eq "'" -or $ch -eq '"') { $quote = $ch; continue }
        if ([char]::IsWhiteSpace($ch)) {
            if ($sb.Length) { $words.Add($sb.ToString()); [void]$sb.Clear() }
            continue
        }
        [void]$sb.Append($ch)
    }
    if ($quote) { throw "Unclosed quote in command: $Line" }
    if ($sb.Length) { $words.Add($sb.ToString()) }
    $words.ToArray()
}

function Get-AzCommandShape([string]$Line) {
    $tokens = @(Split-ShellWords $Line)
    if ($tokens.Count -lt 2 -or $tokens[0] -ne 'az') { return $null }
    $path = New-Object Collections.Generic.List[string]
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i].StartsWith('-') -or $tokens[$i] -match '[$<>{}=:@/]' -or $tokens[$i] -match '\.') { break }
        $path.Add($tokens[$i])
    }
    $flags = @($tokens | Where-Object { $_ -match '^--[A-Za-z0-9][A-Za-z0-9-]*$' } | Sort-Object -Unique)
    [pscustomobject]@{ Line = $Line; Path = @($path); Flags = $flags }
}

$helpCache = @{}
function Get-AzHelp([string[]]$Path) {
    $key = $Path -join ' '
    if ($helpCache.ContainsKey($key)) { return $helpCache[$key] }
    $env:AZURE_CONFIG_DIR = Join-Path $root '.az-help-cache-p89'
    New-Item -ItemType Directory -Force -Path $env:AZURE_CONFIG_DIR | Out-Null
    $output = & az @Path --help 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "az $key --help failed: $output" }
    $helpCache[$key] = $output
    return $output
}

Write-Host 'Azure CLI command guide contract' -ForegroundColor Cyan
$markdown = Read-Text $guide
$commands = @(Get-BashCommands $markdown)
Assert 'guide has Azure CLI command lines in bash code blocks' ($commands.Count -ge 50) "count=$($commands.Count)"

if (-not $SkipAzHelp) {
    $checked = 0
    foreach ($cmd in $commands) {
        $shape = Get-AzCommandShape $cmd
        if (-not $shape -or -not $shape.Path.Count) {
            $script:fail++
            Write-Host "  [FAIL] command parses as az path $cmd" -ForegroundColor Red
            continue
        }
        $help = Get-AzHelp $shape.Path
        $checked++
        foreach ($flag in $shape.Flags) {
            Assert "az $($shape.Path -join ' ') supports $flag" ($help -match "(?m)(^|\s)$([regex]::Escape($flag))([,=\s]|$)") $cmd
        }
    }
    Assert 'all documented az command paths have help' ($checked -eq $commands.Count) "checked=$checked commands=$($commands.Count)"
}

$bicep = Read-Text $mainBicep
$policyXml = Read-Text $policy
$declaredNamedValues = New-Object Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($bicep, "\{\s*key:\s*'([^']+)'\s*,")) { [void]$declaredNamedValues.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($policyXml, '\{\{([A-Za-z0-9-]+)\}\}')) { [void]$declaredNamedValues.Add($m.Groups[1].Value) }

$guideNamedValues = New-Object Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($markdown, '--named-value-id\s+([A-Za-z0-9-]+)')) { [void]$guideNamedValues.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($markdown, '`([A-Za-z][A-Za-z0-9]+-[A-Za-z0-9-]+)`')) {
    if ($declaredNamedValues.Contains($m.Groups[1].Value)) { [void]$guideNamedValues.Add($m.Groups[1].Value) }
}
$unknownNamedValues = @($guideNamedValues | Where-Object { -not $declaredNamedValues.Contains($_) } | Sort-Object)
Assert 'every guide named-value id is in the gateway Bicep or policy XML' ($unknownNamedValues.Count -eq 0) ($unknownNamedValues -join ', ')

$scriptNamedValues = New-Object Collections.Generic.HashSet[string]
$inScope = @(
    'Install-ClaudeGateway.ps1',
    'deploy.ps1',
    'scripts\Set-GatewayPolicy.ps1',
    'scripts\Sync-ClaudeAccess.ps1',
    'scripts\Set-ClaudeTier.ps1',
    'scripts\Set-ClaudeBudget.ps1',
    'scripts\Add-ClaudeModel.ps1',
    'scripts\Sync-ClaudeModels.ps1',
    'scripts\New-ClaudeDesktopEntraApp.ps1',
    'scripts\Deploy-ClaudeProjection.ps1',
    'scripts\Sync-ClaudeProjection.ps1',
    'scripts\ClaudeProjectionChecks.ps1'
)
foreach ($relative in $inScope) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = Read-Text $path
    foreach ($m in [regex]::Matches($text, "Set-ApimNamedValue[\s\S]{0,220}?-Id\s+['""]([^'""]+)['""]")) { [void]$scriptNamedValues.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, '["'']((?:allow|models|quota|tpm)-\$(?:t|Tier))["'']')) {
        foreach ($tier in 'standard','premium') { [void]$scriptNamedValues.Add(($m.Groups[1].Value -replace '\$\((?:Tier|t)\)|\$(?:Tier|t)', $tier)) }
    }
}
foreach ($id in @('tenant-id','tpm-standard','quota-standard','tpm-premium','quota-premium','quota-org','quota-overrides','models-standard','models-premium','allow-standard','allow-premium','calls-per-minute','external-idp-extra-audience','entitlement-source','entitlement-resolver-url','entitlement-resolver-audience','entitlement-cache-seconds')) {
    [void]$scriptNamedValues.Add($id)
}
$notCovered = @()
foreach ($m in [regex]::Matches($markdown, '(?m)^- `([A-Za-z0-9-]+)` — not covered:')) { $notCovered += $m.Groups[1].Value }
$missingParity = @($scriptNamedValues | Where-Object { $_ -and -not $guideNamedValues.Contains($_) -and $_ -notin $notCovered } | Sort-Object)
Assert 'every in-scope script-written named value appears in the guide or not-covered list' ($missingParity.Count -eq 0) ($missingParity -join ', ')

$bicepParams = @{}
foreach ($file in 'infra\main.bicep','infra\projection-network.bicep','infra\projection.bicep','infra\resolver.bicep') {
    $text = Read-Text (Join-Path $root $file)
    $set = New-Object Collections.Generic.HashSet[string]
    foreach ($m in [regex]::Matches($text, '(?m)^\s*param\s+([A-Za-z][A-Za-z0-9_]*)\s+')) { [void]$set.Add($m.Groups[1].Value) }
    $bicepParams[$file.Replace('\','/')] = $set
}
foreach ($cmd in $commands) {
    if ($cmd -notmatch '^az deployment group (create|what-if)\b') { continue }
    $tokens = @(Split-ShellWords $cmd)
    $templateIndex = [Array]::IndexOf($tokens, '--template-file')
    $paramIndex = [Array]::IndexOf($tokens, '--parameters')
    if ($templateIndex -lt 0 -or $paramIndex -lt 0 -or $templateIndex + 1 -ge $tokens.Count) { continue }
    $template = $tokens[$templateIndex + 1].Trim('"''')
    if (-not $bicepParams.ContainsKey($template)) { continue }
    for ($i = $paramIndex + 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token.StartsWith('-')) { break }
        if ($token -match '^([A-Za-z][A-Za-z0-9_]*)=') {
            Assert "$template has parameter $($matches[1])" ($bicepParams[$template].Contains($matches[1])) $cmd
        }
    }
}

$docRef = Join-Path $PSScriptRoot 'Test-DocReferences.ps1'
Assert 'relative-link checker exists for guide links' (Test-Path -LiteralPath $docRef)

if ($script:fail) { throw "$script:fail assertion(s) failed." }
