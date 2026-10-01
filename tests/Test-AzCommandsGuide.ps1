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

function Get-MarkedBashBlock([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "(?ms)# P89-$Name-BEGIN\s*(.*?)# P89-$Name-END")
    if (-not $m.Success) { throw "Missing P89-$Name marked bash block." }
    return $m.Groups[1].Value.Trim()
}

function ConvertTo-BashPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    return '/' + (($full -replace '\\','/') -replace '^([A-Za-z]):','$1')
}

function New-GuideAzStub([string]$Directory) {
    $path = Join-Path $Directory 'az'
    @'
#!/usr/bin/env bash
set -u
echo "$*" >> "$P89_CALLS"

arg_after() {
  local key="$1"; shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$key" ]; then shift; printf '%s' "${1:-}"; return 0; fi
    shift
  done
  return 1
}

json_members() {
  local kind="$1"
  case "${P89_SCENARIO}:${kind}" in
    normal:premium-user) printf '{"value":[{"id":"11111111-1111-1111-1111-111111111111"}]}' ;;
    normal:premium-sp) printf '{"value":[{"id":"22222222-2222-2222-2222-222222222222"}]}' ;;
    normal:standard-user) printf '{"value":[{"id":"11111111-1111-1111-1111-111111111111"},{"id":"33333333-3333-3333-3333-333333333333"}]}' ;;
    normal:standard-sp) printf '{"value":[{"id":"44444444-4444-4444-4444-444444444444"}]}' ;;
    empty-premium:premium-user|empty-premium:premium-sp) printf '{"value":[]}' ;;
    empty-premium:standard-user) printf '{"value":[{"id":"33333333-3333-3333-3333-333333333333"}]}' ;;
    empty-premium:standard-sp) printf '{"value":[{"id":"44444444-4444-4444-4444-444444444444"}]}' ;;
    both-empty:*) printf '{"value":[]}' ;;
    oversized:premium-user)
      printf '{"value":['
      local sep=''
      for i in $(seq 1 112); do printf '%s{"id":"aaaaaaaa-aaaa-aaaa-aaaa-%012d"}' "$sep" "$i"; sep=','; done
      printf ']}'
      ;;
    oversized:premium-sp|oversized:standard-sp) printf '{"value":[]}' ;;
    oversized:standard-user) printf '{"value":[{"id":"33333333-3333-3333-3333-333333333333"}]}' ;;
    nextlink:premium-user) printf '{"value":[{"id":"11111111-1111-1111-1111-111111111111"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/next"}' ;;
    nextlink:*) printf '{"value":[]}' ;;
    *) printf '{"value":[]}' ;;
  esac
}

if [ "$1" = "ad" ] && [ "$2" = "group" ] && [ "$3" = "show" ]; then
  group="$(arg_after --group "$@")"
  if [ "$group" = "$STANDARD_GROUP" ]; then printf 'standard-id\n'; else printf 'premium-id\n'; fi
  exit 0
fi
if [ "$1" = "ad" ] && [ "$2" = "user" ] && [ "$3" = "show" ]; then
  printf '55555555-5555-5555-5555-555555555555\n'
  exit 0
fi
if [ "$1" = "ad" ] && [ "$2" = "group" ] && [ "$3" = "member" ]; then
  action="$4"; group="$(arg_after --group "$@")"; member="$(arg_after --member-id "$@")"
  echo "$action $group $member" >> "$P89_MEMBER_CALLS"
  if [ "$action" = "list" ]; then
    if [ "$P89_SCENARIO" = "developer-add" ] && [ "$group" = "$STANDARD_GROUP" ]; then printf '%s\n' "$member"; fi
    exit 0
  fi
  exit 0
fi
if [ "$1" = "rest" ]; then
  url="$(arg_after --url "$@")"
  if [ "${P89_SCENARIO:-}" = "graph403" ] && [[ "$url" == *standard-id*servicePrincipal* ]]; then
    echo "Graph 403" >&2
    exit 3
  fi
  tier=standard; [[ "$url" == *premium-id* ]] && tier=premium
  type=user; [[ "$url" == *servicePrincipal* ]] && type=sp
  json_members "$tier-$type"
  exit 0
fi
if [ "$1" = "apim" ] && [ "$2" = "nv" ] && [ "$3" = "update" ]; then
  id="$(arg_after --named-value-id "$@")"; value="$(arg_after --value "$@")"
  printf '%s=%s\n' "$id" "$value" >> "$P89_WRITES"
  exit 0
fi
if [ "$1" = "apim" ] && [ "$2" = "nv" ] && [ "$3" = "list" ]; then
  printf '[]\n'
  exit 0
fi
printf 'unsupported az stub call: %s\n' "$*" >&2
exit 2
'@ | Set-Content -LiteralPath $path -NoNewline
    $path
}

function Invoke-GuideBashScenario([string]$Name, [string]$Script, [hashtable]$ExtraEnv = @{}) {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    Assert 'Git Bash is available for guide execution tests' (Test-Path -LiteralPath $bash) $bash
    if (-not (Test-Path -LiteralPath $bash)) { return [pscustomobject]@{ Exit = 127; Output = ''; Dir = $null } }
    $jqCheck = & $bash -lc 'command -v jq >/dev/null'
    Assert 'Git Bash has jq for guide execution tests' ($LASTEXITCODE -eq 0) 'jq is required by docs/AZ-COMMANDS.md entitlement publishing blocks.'
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Exit = 127; Output = ''; Dir = $null } }

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('p89-guide-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-GuideAzStub $dir | Out-Null
    $scriptPath = Join-Path $dir 'run.sh'
    @"
#!/usr/bin/env bash
set -uo pipefail
export PATH="$(ConvertTo-BashPath $dir):`$PATH"
export P89_SCENARIO="$Name"
export P89_CALLS="$(ConvertTo-BashPath (Join-Path $dir 'calls.log'))"
export P89_WRITES="$(ConvertTo-BashPath (Join-Path $dir 'writes.log'))"
export P89_MEMBER_CALLS="$(ConvertTo-BashPath (Join-Path $dir 'members.log'))"
export STANDARD_GROUP="claude-code-standard"
export PREMIUM_GROUP="claude-code-premium"
export GATEWAY_RG="rg"
export APIM_NAME="apim"
export DEVELOPER_UPN="dev@example.test"
export DEVELOPER_ID="55555555-5555-5555-5555-555555555555"
cd "$(ConvertTo-BashPath $dir)"
touch "`$P89_CALLS" "`$P89_WRITES" "`$P89_MEMBER_CALLS"
$Script
"@ | Set-Content -LiteralPath $scriptPath -NoNewline
    foreach ($key in $ExtraEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, [string]$ExtraEnv[$key], 'Process')
    }
    try {
        $output = & $bash (ConvertTo-BashPath $scriptPath) 2>&1 | Out-String
        $exit = $LASTEXITCODE
    }
    finally {
        foreach ($key in $ExtraEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    }
    [pscustomobject]@{ Exit = $exit; Output = $output; Dir = $dir }
}

function Read-ScenarioFile($Scenario, [string]$Name) {
    $path = Join-Path $Scenario.Dir $Name
    if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw } else { '' }
}

$graphBlock = Get-MarkedBashBlock $markdown 'ENTITLEMENT-GRAPH'
$publishBlock = Get-MarkedBashBlock $markdown 'ENTITLEMENT-PUBLISH'
$addBlock = Get-MarkedBashBlock $markdown 'DEVELOPER-ADD'
$removeBlock = Get-MarkedBashBlock $markdown 'DEVELOPER-REMOVE'
$entitlementScript = $graphBlock + "`n" + $publishBlock

$normal = Invoke-GuideBashScenario 'normal' $entitlementScript
Assert 'guide execution publishes premium and standard exact values' (
    $normal.Exit -eq 0 -and
    (Read-ScenarioFile $normal 'writes.log') -match 'allow-premium=,11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222,' -and
    (Read-ScenarioFile $normal 'writes.log') -match 'allow-standard=,33333333-3333-3333-3333-333333333333,44444444-4444-4444-4444-444444444444,'
) $normal.Output

$emptyPremium = Invoke-GuideBashScenario 'empty-premium' $entitlementScript @{ ALLOW_EMPTY = 'yes' }
Assert 'empty premium does not empty standard' (
    $emptyPremium.Exit -eq 0 -and
    (Read-ScenarioFile $emptyPremium 'writes.log') -match 'allow-premium=,' -and
    (Read-ScenarioFile $emptyPremium 'writes.log') -match 'allow-standard=,33333333-3333-3333-3333-333333333333,44444444-4444-4444-4444-444444444444,'
) $emptyPremium.Output

$graph403 = Invoke-GuideBashScenario 'graph403' $entitlementScript
Assert 'Graph failure stops before entitlement writes' (
    $graph403.Exit -ne 0 -and -not (Read-ScenarioFile $graph403 'writes.log')
) $graph403.Output

$nextLink = Invoke-GuideBashScenario 'nextlink' $entitlementScript
Assert 'paged Graph response is refused before writes' (
    $nextLink.Exit -ne 0 -and -not (Read-ScenarioFile $nextLink 'writes.log') -and $nextLink.Output -match '@odata.nextLink|paged'
) $nextLink.Output

$oversized = Invoke-GuideBashScenario 'oversized' $entitlementScript @{ ALLOW_EMPTY = 'yes' }
Assert 'oversized allow list is refused before writes' (
    $oversized.Exit -ne 0 -and -not (Read-ScenarioFile $oversized 'writes.log') -and $oversized.Output -match '4,096'
) $oversized.Output

$bothEmptyRefused = Invoke-GuideBashScenario 'both-empty' $entitlementScript
Assert 'both empty groups without ALLOW_EMPTY are refused before writes' (
    $bothEmptyRefused.Exit -ne 0 -and -not (Read-ScenarioFile $bothEmptyRefused 'writes.log') -and $bothEmptyRefused.Output -match 'ALLOW_EMPTY=yes'
) $bothEmptyRefused.Output

$bothEmptyAllowed = Invoke-GuideBashScenario 'both-empty' $entitlementScript @{ ALLOW_EMPTY = 'yes' }
Assert 'both empty groups with ALLOW_EMPTY publish comma sentinels' (
    $bothEmptyAllowed.Exit -eq 0 -and
    (Read-ScenarioFile $bothEmptyAllowed 'writes.log') -match "allow-premium=,\r?\n" -and
    (Read-ScenarioFile $bothEmptyAllowed 'writes.log') -match "allow-standard=,\r?\n"
) $bothEmptyAllowed.Output

$developerAdd = Invoke-GuideBashScenario 'developer-add' $addBlock
Assert 'developer add block adds wanted tier and removes other tier' (
    $developerAdd.Exit -eq 0 -and
    (Read-ScenarioFile $developerAdd 'members.log') -match 'add claude-code-standard 55555555-5555-5555-5555-555555555555' -and
    (Read-ScenarioFile $developerAdd 'members.log') -match 'remove claude-code-premium 55555555-5555-5555-5555-555555555555'
) $developerAdd.Output

$developerRemove = Invoke-GuideBashScenario 'developer-remove' $removeBlock
Assert 'developer remove block removes both direct tier groups' (
    $developerRemove.Exit -eq 0 -and
    (Read-ScenarioFile $developerRemove 'members.log') -match 'remove claude-code-standard' -and
    (Read-ScenarioFile $developerRemove 'members.log') -match 'remove claude-code-premium'
) $developerRemove.Output

$missingFile = Invoke-GuideBashScenario 'normal' $publishBlock
Assert 'execution harness catches missing Graph response files' (
    $missingFile.Exit -ne 0 -and -not (Read-ScenarioFile $missingFile 'writes.log') -and $missingFile.Output -match 'missing|invalid|incomplete'
) $missingFile.Output

$bugDir = Join-Path ([IO.Path]::GetTempPath()) ('p89-grep-bug-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $bugDir | Out-Null
$bugScript = Join-Path $bugDir 'bug.sh'
@'
#!/usr/bin/env bash
set -uo pipefail
printf '33333333-3333-3333-3333-333333333333\n' > standard-all-oids.txt
PREMIUM_OIDS=""
grep -iv -f <(printf '%s\n' "$PREMIUM_OIDS" | tr ',' '\n') standard-all-oids.txt > standard-oids.txt
test -s standard-oids.txt
'@ | Set-Content -LiteralPath $bugScript -NoNewline
$bashForBug = 'C:\Program Files\Git\bin\bash.exe'
$bugOutput = & $bashForBug (ConvertTo-BashPath $bugScript) 2>&1 | Out-String
Assert 'execution harness catches the old empty-premium grep -v -f bug' ($LASTEXITCODE -ne 0) $bugOutput

if ($script:fail) { throw "$script:fail assertion(s) failed." }
