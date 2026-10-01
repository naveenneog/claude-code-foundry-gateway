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
foreach ($block in [regex]::Matches($markdown, '(?ms)^```(?:bash|sh)\s*$(.*?)^```\s*$')) {
    Assert 'bash code block contains no exit command' ($block.Groups[1].Value -notmatch '(?m)(^|[;&|\s])exit(\s|$)') ($block.Groups[1].Value.Substring(0, [Math]::Min(160, $block.Groups[1].Value.Length)))
}

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

function Join-GuideBlocks([string[]]$Blocks) {
    ($Blocks | Where-Object { $_ }) -join "`nrc=`$?; [ `"`$rc`" -eq 0 ] || exit `"`$rc`"`n"
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
    group404-twice:premium-user|group404-twice:premium-sp) printf '{"value":[{"id":"11111111-1111-1111-1111-111111111111"}]}' ;;
    group404-twice:standard-user|group404-twice:standard-sp) printf '{"value":[{"id":"33333333-3333-3333-3333-333333333333"}]}' ;;
    *) printf '{"value":[]}' ;;
  esac
}

if [ "$1" = "ad" ] && [ "$2" = "group" ] && [ "$3" = "show" ]; then
  group="$(arg_after --group "$@")"
  query="$(arg_after --query "$@")"
  if [[ "$query" == *createdDateTime* ]]; then
    if [ "${P89_SCENARIO:-}" = "group-young" ]; then date -u +"%Y-%m-%dT%H:%M:%SZ"; else printf '2020-01-01T00:00:00Z\n'; fi
    exit 0
  fi
  if [ "$group" = "$STANDARD_GROUP" ]; then printf 'standard-id\n'; else printf 'premium-id\n'; fi
  exit 0
fi
if [ "$1" = "ad" ] && [ "$2" = "group" ] && [ "$3" = "list" ]; then
  filter="$(arg_after --filter "$@")"
  if [ "${P89_SCENARIO:-}" = "group-list-fail" ]; then echo "Forbidden({\"error\":{\"code\":\"Authorization_RequestDenied\"}})" >&2; exit 3; fi
  if [ "${P89_SCENARIO:-}" = "group-duplicate" ]; then printf '[{"id":"g1","createdDateTime":"2020-01-01T00:00:00Z"},{"id":"g2","createdDateTime":"2020-01-01T00:00:00Z"}]\n'; exit 0; fi
  if [ "${P89_SCENARIO:-}" = "group-create-fail" ]; then printf '[]\n'; exit 0; fi
  if [[ "$filter" == *"$STANDARD_GROUP"* ]]; then printf '[{"id":"standard-id","createdDateTime":"2020-01-01T00:00:00Z"}]\n'; else printf '[{"id":"premium-id","createdDateTime":"2020-01-01T00:00:00Z"}]\n'; fi
  exit 0
fi
if [ "$1" = "ad" ] && [ "$2" = "group" ] && [ "$3" = "create" ]; then
  if [ "${P89_SCENARIO:-}" = "group-create-fail" ]; then echo "Directory_QuotaExceeded" >&2; exit 3; fi
  name="$(arg_after --display-name "$@")"
  id="premium-id"; [ "$name" = "$STANDARD_GROUP" ] && id="standard-id"
  printf '{"id":"%s","displayName":"%s","createdDateTime":"%s"}\n' "$id" "$name" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  exit 0
fi
if [ "$1" = "ad" ] && [ "$2" = "group" ] && [ "$3" = "delete" ]; then
  printf 'delete-group %s\n' "$(arg_after --group "$@")" >> "$P89_WRITES"
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
if [ "$1" = "ad" ] && [ "$2" = "sp" ] && [ "$3" = "show" ]; then
  printf 'gateway-app-id\n'
  exit 0
fi
if [ "$1" = "ad" ] && [ "$2" = "app" ]; then
  case "$3" in
    list)
      if [ "${P89_SCENARIO:-}" = "app-list-fail" ]; then echo "Forbidden({\"error\":{\"code\":\"Authorization_RequestDenied\"}})" >&2; exit 3; fi
      if [ "${P89_SCENARIO:-}" = "app-duplicate" ]; then printf '[{"appId":"a1","id":"o1"},{"appId":"a2","id":"o2"}]\n'; exit 0; fi
      if [ "${P89_SCENARIO:-}" = "app-create-fail" ]; then printf '[]\n'; exit 0; fi
      if [ "${P89_SCENARIO:-}" = "app-existing" ]; then printf '[{"appId":"existing-app-id","id":"existing-object-id"}]\n'; else printf '[]\n'; fi
      exit 0
      ;;
    create)
      if [ "${P89_SCENARIO:-}" = "app-create-fail" ]; then echo "Authorization_RequestDenied" >&2; exit 3; fi
      printf '{"appId":"created-app-id","displayName":"Claude Desktop gateway"}\n'
      exit 0
      ;;
    update|show)
      printf '{}\n'
      exit 0
      ;;
    delete)
      printf 'delete-app %s\n' "$(arg_after --id "$@")" >> "$P89_WRITES"
      exit 0
      ;;
  esac
fi
if [ "$1" = "role" ] && [ "$2" = "assignment" ]; then
  action="$3"
  case "$action" in
    list)
      if [ "${P89_SCENARIO:-}" = "role-existing" ]; then printf 'existing-role-id\n'; fi
      exit 0
      ;;
    create)
      printf '{"id":"created-role-id"}\n'
      exit 0
      ;;
    delete)
      id="$(arg_after --ids "$@")"
      printf 'delete-role %s\n' "$id" >> "$P89_WRITES"
      exit 0
      ;;
  esac
fi
if [ "$1" = "rest" ]; then
  url="$(arg_after --url "$@")"
  if [ "${P89_SCENARIO:-}" = "graph403" ] && [[ "$url" == *standard-id*servicePrincipal* ]]; then
    echo "Forbidden({\"error\":{\"code\":\"Authorization_RequestDenied\",\"innerError\":{\"request-id\":\"40400000-0000-0000-0000-000000000000\"}}})" >&2
    exit 3
  fi
  if [ "${P89_SCENARIO:-}" = "graph403-window" ]; then
    echo "Forbidden({\"error\":{\"code\":\"Authorization_RequestDenied\",\"innerError\":{\"request-id\":\"40400000-0000-0000-0000-000000000000\"}}})" >&2
    exit 3
  fi
  if [ "${P89_SCENARIO:-}" = "group404-twice" ]; then
    state="${P89_STATE_DIR:-.}/404-count"
    n=0; [ -f "$state" ] && n="$(cat "$state")"
    n=$((n+1)); printf '%s' "$n" > "$state"
    if [ "$n" -le 2 ]; then echo "Not Found({\"error\":{\"code\":\"Request_ResourceNotFound\"}})" >&2; exit 3; fi
  fi
  if [ "${P89_SCENARIO:-}" = "group404-old" ]; then
    echo "Not Found({\"error\":{\"code\":\"Request_ResourceNotFound\"}})" >&2
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
if [ "$1" = "apim" ] && [ "$2" = "nv" ] && [ "$3" = "show" ]; then
  id="$(arg_after --named-value-id "$@")"
  case "$id" in
    quota-overrides)
      if [ "${P89_SCENARIO:-}" = "budget-oversize" ]; then
        printf ','
        for i in $(seq 1 115); do printf 'aaaaaaaa-aaaa-aaaa-aaaa-%012d=1,' "$i"; done
        printf '\n'
      else
        printf ',aaaaaaaa-aaaa-aaaa-aaaa-000000000001=100,55555555-5555-5555-5555-555555555555=50,\n'
      fi
      ;;
    models-premium) printf ',claude-sonnet-5,\n' ;;
    models-standard) printf ',claude-sonnet-5,claude-opus-5,\n' ;;
    *) printf 'value\n' ;;
  esac
  exit 0
fi
if [ "$1" = "apim" ] && [ "$2" = "nv" ] && [ "$3" = "list" ]; then
  printf '[]\n'
  exit 0
fi
if [ "$1" = "deployment" ] && [ "$2" = "group" ]; then
  action="$3"
  if [ "$action" = "create" ]; then
    name="$(arg_after -n "$@")"
    printf 'deployment-create %s\n' "$name" >> "$P89_WRITES"
    exit 0
  fi
  if [ "$action" = "show" ]; then
    name="$(arg_after -n "$@")"
    query="$(arg_after --query "$@")"
    case "$name" in
      claude-gateway-basicv2) printf 'https://gateway.example/claude\n' ;;
      projection-network-*)
        case "$query" in
          *runnerName.value*) printf 'runner-aci\n' ;;
          *runnerPrincipalId.value*) printf 'runner-principal\n' ;;
          *) printf '{"runnerName":{"value":"runner-aci"},"runnerPrincipalId":{"value":"runner-principal"},"resolverSubnetId":{"value":"resolver-subnet"},"endpointsSubnetId":{"value":"endpoints-subnet"},"sitesDnsZoneId":{"value":"sites-zone"},"blobDnsZoneId":{"value":"blob-zone"},"queueDnsZoneId":{"value":"queue-zone"},"tableDnsZoneId":{"value":"table-zone"}}\n' ;;
        esac
        ;;
      projection-resolver-*) printf 'func-resolver\n' ;;
      projection-*)
        if [[ "$query" == *accountName.value* ]]; then printf 'cosmos-prefix\n'; else printf '{"accountName":{"value":"cosmos-prefix"}}\n'; fi
        ;;
      *) printf '{}\n' ;;
    esac
    exit 0
  fi
fi
if [ "$1" = "cosmosdb" ] && [ "$2" = "sql" ] && [ "$3" = "role" ] && [ "$4" = "assignment" ] && [ "$5" = "create" ]; then
  printf 'cosmos-role\n' >> "$P89_WRITES"
  exit 0
fi
if [ "$1" = "container" ] && [ "$2" = "exec" ]; then
  cmd="$(arg_after --exec-command "$@")"
  printf 'container-exec %s\n' "$cmd" >> "$P89_WRITES"
  if [ "${P89_SCENARIO:-}" = "runner-chunk-fail" ] && [[ "$cmd" == *appendFileSync* ]]; then
    echo "chunk failed" >&2
    exit 9
  fi
  if [ "${P89_SCENARIO:-}" = "runner-chunk-error-text" ] && [[ "$cmd" == *appendFileSync* ]]; then
    echo "ERROR: simulated chunk failure"
    exit 0
  fi
  if [[ "$cmd" == *createHash* ]]; then
    if [ "${P89_SCENARIO:-}" = "runner-hash-mismatch" ]; then
      printf 'remote-bad-hash\n'
    elif [[ "$cmd" == *sync-source.tar.gz* ]]; then
      sha256sum sync-source.tar.gz | awk '{print $1}'
    elif [[ "$cmd" == *snapshot.json* ]]; then
      sha256sum snapshot.json | awk '{print $1}'
    elif [[ "$cmd" == *gateway-decisions.json* ]]; then
      sha256sum gateway-decisions.json | awk '{print $1}'
    else
      printf 'unknown-hash\n'
    fi
  fi
  exit 0
fi
if [ "$1" = "functionapp" ]; then
  printf 'functionapp %s\n' "$*" >> "$P89_WRITES"
  if [ "$2" = "show" ]; then printf '{"name":"func-resolver","state":"Running","host":"func-resolver.azurewebsites.net"}\n'; fi
  exit 0
fi
printf 'unsupported az stub call: %s\n' "$*" >&2
exit 2
'@ | Set-Content -LiteralPath $path -NoNewline
    $path
}

function New-GuideZipStub([string]$Directory) {
    $path = Join-Path $Directory 'zip'
    @'
#!/usr/bin/env bash
out=""
for arg in "$@"; do
  case "$arg" in
    *.zip) out="$arg"; break ;;
  esac
done
[ -n "$out" ] && printf 'zip' > "$out"
exit 0
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
    New-GuideZipStub $dir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'scripts'), (Join-Path $dir 'sync\src'), (Join-Path $dir 'resolver\src'), (Join-Path $dir 'onboarding'), (Join-Path $dir '.p89-receipts') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'scripts\Sync-ClaudeProjection.ps1'), "#!/usr/bin/env bash`nwhile [ `"`$#`" -gt 0 ]; do if [ `"`$1`" = `"-ExportPath`" ]; then shift; printf '{`"members`":[]}\n' > `"`$1`"; fi; shift || true; done`n")
    [IO.File]::WriteAllText((Join-Path $dir 'scripts\Compare-ClaudeEntitlement.ps1'), "#!/usr/bin/env bash`nwhile [ `"`$#`" -gt 0 ]; do if [ `"`$1`" = `"-ExportGatewayPath`" ]; then shift; printf '{`"decisions`":[]}\n' > `"`$1`"; fi; shift || true; done`n")
    [IO.File]::WriteAllText((Join-Path $dir 'sync\package.json'), "{`"scripts`":{}}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'sync\src\apply-projection.mjs'), "console.log(`"ok`")`n")
    [IO.File]::WriteAllText((Join-Path $dir 'resolver\host.json'), "{}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'resolver\package.json'), "{`"dependencies`":{}}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'resolver\src\index.js'), "module.exports={}`n")
    $scriptPath = Join-Path $dir 'run.sh'
    @"
#!/usr/bin/env bash
set -uo pipefail
export PATH="$(ConvertTo-BashPath $dir):`$PATH"
export P89_SCENARIO="$Name"
export P89_CALLS="$(ConvertTo-BashPath (Join-Path $dir 'calls.log'))"
export P89_WRITES="$(ConvertTo-BashPath (Join-Path $dir 'writes.log'))"
export P89_MEMBER_CALLS="$(ConvertTo-BashPath (Join-Path $dir 'members.log'))"
export P89_STATE_DIR="$(ConvertTo-BashPath $dir)"
export STANDARD_GROUP="claude-code-standard"
export PREMIUM_GROUP="claude-code-premium"
export GATEWAY_RG="rg"
export APIM_NAME="apim"
export APIM_PRINCIPAL_ID="gateway-object-id"
export FOUNDRY_ID="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry"
export SUBSCRIPTION_ID="sub"
export TENANT_ID="tenant"
export LOCATION="eastus"
export NAME_PREFIX="prefix"
export FOUNDRY_ACCOUNT="foundry"
export FOUNDRY_RG="foundry-rg"
export SONNET_DEPLOYMENT="claude-sonnet-5"
export OPUS_DEPLOYMENT="claude-opus-5"
export HAIKU_DEPLOYMENT="claude-haiku-4-5"
export TPM_STANDARD="20000"
export QUOTA_STANDARD="500000"
export TPM_PREMIUM="80000"
export QUOTA_PREMIUM="5000000"
export QUOTA_ORG="100000000"
export CALLS_PER_MINUTE="120"
export MODELS_STANDARD=",claude-sonnet-5,"
export MODELS_PREMIUM=",claude-sonnet-5,claude-opus-5,"
export DESKTOP_CLIENT_ID="66666666-6666-6666-6666-666666666666"
export RESOLVER_APP_ID="resolver-app-id"
export DEVELOPER_UPN="dev@example.test"
export DEVELOPER_ID="55555555-5555-5555-5555-555555555555"
export GRAPH_RETRY_DELAY_SECONDS="0"
export GRAPH_RETRY_ATTEMPTS="3"
cd "$(ConvertTo-BashPath $dir)"
chmod +x scripts/Sync-ClaudeProjection.ps1 scripts/Compare-ClaudeEntitlement.ps1
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

$groupBlock = Get-MarkedBashBlock $markdown 'GROUP-RECEIPTS'
$graphBlock = Get-MarkedBashBlock $markdown 'ENTITLEMENT-GRAPH'
$publishBlock = Get-MarkedBashBlock $markdown 'ENTITLEMENT-PUBLISH'
$addBlock = Get-MarkedBashBlock $markdown 'DEVELOPER-ADD'
$removeBlock = Get-MarkedBashBlock $markdown 'DEVELOPER-REMOVE'
$roleBlock = Get-MarkedBashBlock $markdown 'FOUNDRY-ROLE'
$tierBlock = Get-MarkedBashBlock $markdown 'TIER-WRITES'
$budgetBlock = Get-MarkedBashBlock $markdown 'BUDGET-WRITE'
$desktopAppBlock = Get-MarkedBashBlock $markdown 'DESKTOP-APP'
$handoverBlock = Get-MarkedBashBlock $markdown 'HANDOVER'
$projectionDeployBlock = Get-MarkedBashBlock $markdown 'PROJECTION-DEPLOY'
$resolverDeployBlock = Get-MarkedBashBlock $markdown 'RESOLVER-DEPLOY'
$projectionRunnerBlock = Get-MarkedBashBlock $markdown 'PROJECTION-RUNNER'
$teardownExternalBlock = Get-MarkedBashBlock $markdown 'TEARDOWN-EXTERNAL'
$entitlementScript = Join-GuideBlocks @($groupBlock, $graphBlock, $publishBlock)

$normal = Invoke-GuideBashScenario 'normal' $entitlementScript
Assert 'guide execution publishes premium and standard exact values' (
    $normal.Exit -eq 0 -and
    (Read-ScenarioFile $normal 'writes.log') -match 'allow-premium=,11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222,' -and
    (Read-ScenarioFile $normal 'writes.log') -match 'allow-standard=,33333333-3333-3333-3333-333333333333,44444444-4444-4444-4444-444444444444,'
) $normal.Output

$exitMutation = $publishBlock -replace 'return 1', 'exit 1'
Assert 'static guard catches an exit command mutation' ($exitMutation -match '(?m)(^|[;&|\s])exit(\s|$)')
$refusingBlock = Invoke-GuideBashScenario 'normal' ("printf '%s\n' '{""value"":[]}' > premium-users.json; printf '%s\n' '{""value"":[]}' > premium-service-principals.json; printf '%s\n' '{""value"":[]}' > standard-users.json; printf '%s\n' '{""value"":[]}' > standard-service-principals.json; " + $publishBlock + "; echo still-alive")
Assert 'refusing block returns to shell instead of closing it' ($refusingBlock.Output -match 'still-alive') $refusingBlock.Output
$exitRefusingBlock = Invoke-GuideBashScenario 'normal' ("printf '%s\n' '{""value"":[]}' > premium-users.json; printf '%s\n' '{""value"":[]}' > premium-service-principals.json; printf '%s\n' '{""value"":[]}' > standard-users.json; printf '%s\n' '{""value"":[]}' > standard-service-principals.json; " + $exitMutation + "; echo still-alive")
Assert 'exit mutation closes shell before still-alive proof' ($exitRefusingBlock.Output -notmatch 'still-alive')

$groupListFail = Invoke-GuideBashScenario 'group-list-fail' $groupBlock
Assert 'group list failure refuses and does not create' (
    $groupListFail.Exit -ne 0 -and $groupListFail.Output -match 'could not list group' -and -not ((Read-ScenarioFile $groupListFail 'calls.log') -match 'ad group create')
) $groupListFail.Output
$groupDuplicate = Invoke-GuideBashScenario 'group-duplicate' $groupBlock
Assert 'duplicate group names are refused with no receipt' (
    $groupDuplicate.Exit -ne 0 -and $groupDuplicate.Output -match 'groups are named' -and -not (Read-ScenarioFile $groupDuplicate '.p89-receipts/group-standard.json')
) $groupDuplicate.Output
$groupCreateFail = Invoke-GuideBashScenario 'group-create-fail' $groupBlock
Assert 'group create failure refuses with no receipt' (
    $groupCreateFail.Exit -ne 0 -and $groupCreateFail.Output -match 'Tenant settings may block group creation' -and -not (Read-ScenarioFile $groupCreateFail '.p89-receipts/group-standard.json')
) $groupCreateFail.Output

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

$newGroupReceipts = "mkdir -p .p89-receipts; now=`$(date -u +%Y-%m-%dT%H:%M:%SZ); printf '%s\n' '{""group"":{""created"":true,""id"":""standard-id"",""displayName"":""claude-code-standard"",""createdAt"":""'`$now'""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":true,""id"":""premium-id"",""displayName"":""claude-code-premium"",""createdAt"":""'`$now'""}}' > .p89-receipts/group-premium.json;"
$oldGroupReceipts = "mkdir -p .p89-receipts; printf '%s\n' '{""group"":{""created"":false,""id"":""standard-id"",""displayName"":""claude-code-standard"",""createdAt"":""2020-01-01T00:00:00Z""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":false,""id"":""premium-id"",""displayName"":""claude-code-premium"",""createdAt"":""2020-01-01T00:00:00Z""}}' > .p89-receipts/group-premium.json;"

$group404Then200 = Invoke-GuideBashScenario 'group404-twice' (Join-GuideBlocks @($newGroupReceipts, $graphBlock, $publishBlock))
Assert 'new group 404 retries then publishes after Graph index catches up' (
    $group404Then200.Exit -eq 0 -and
    (Read-ScenarioFile $group404Then200 'writes.log') -match 'allow-premium=' -and
    $group404Then200.Output -match 'retrying after index propagation'
) $group404Then200.Output

$group404Old = Invoke-GuideBashScenario 'group404-old' (Join-GuideBlocks @($oldGroupReceipts, $graphBlock, $publishBlock))
Assert 'old group 404 stops with no entitlement write' (
    $group404Old.Exit -ne 0 -and -not ((Read-ScenarioFile $group404Old 'writes.log') -match 'allow-')
) $group404Old.Output

$graph403Window = Invoke-GuideBashScenario 'graph403-window' (Join-GuideBlocks @($newGroupReceipts, $graphBlock, $publishBlock))
Assert 'Graph 403 inside retry window stops immediately with no entitlement write' (
    $graph403Window.Exit -ne 0 -and -not ((Read-ScenarioFile $graph403Window 'writes.log') -match 'allow-') -and -not ($graph403Window.Output -match 'retrying after index propagation')
) $graph403Window.Output
$loose404GraphBlock = $graphBlock -replace 'retryable_not_found="false"', 'retryable_not_found="true"'
$loose404Graph = Invoke-GuideBashScenario 'graph403-window' (Join-GuideBlocks @($newGroupReceipts, $loose404GraphBlock, $publishBlock))
Assert 'loose 404 parser mutation retries a 403 with request-id containing 404' ($loose404Graph.Output -match 'retrying after index propagation') $loose404Graph.Output

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
cd "$(dirname "$0")"
printf '33333333-3333-3333-3333-333333333333\n' > standard-all-oids.txt
PREMIUM_OIDS=""
grep -iv -f <(printf '%s\n' "$PREMIUM_OIDS" | tr ',' '\n') standard-all-oids.txt > standard-oids.txt
test -s standard-oids.txt
'@ | Set-Content -LiteralPath $bugScript -NoNewline
$bashForBug = 'C:\Program Files\Git\bin\bash.exe'
$bugOutput = & $bashForBug (ConvertTo-BashPath $bugScript) 2>&1 | Out-String
Assert 'execution harness catches the old empty-premium grep -v -f bug' ($LASTEXITCODE -ne 0) $bugOutput

$roleCreated = Invoke-GuideBashScenario 'role-new' $roleBlock
Assert 'role assignment block records newly created assignment id' (
    $roleCreated.Exit -eq 0 -and
    (Read-ScenarioFile $roleCreated '.p89-receipts/foundry-role.json' | ConvertFrom-Json).foundryRole.created -eq $true -and
    (Read-ScenarioFile $roleCreated '.p89-receipts/foundry-role.json') -match 'created-role-id'
) $roleCreated.Output

$roleExisting = Invoke-GuideBashScenario 'role-existing' $roleBlock
Assert 'role assignment block records pre-existing assignment without creating' (
    $roleExisting.Exit -eq 0 -and
    (Read-ScenarioFile $roleExisting '.p89-receipts/foundry-role.json' | ConvertFrom-Json).foundryRole.created -eq $false -and
    -not ((Read-ScenarioFile $roleExisting 'writes.log') -match 'created-role-id')
) $roleExisting.Output

$desktopAppCreated = Invoke-GuideBashScenario 'app-new' $desktopAppBlock
Assert 'desktop app block records created app receipt' (
    $desktopAppCreated.Exit -eq 0 -and
    (Read-ScenarioFile $desktopAppCreated '.p89-receipts/desktop-app.json' | ConvertFrom-Json).app.created -eq $true
) $desktopAppCreated.Output

$desktopAppExisting = Invoke-GuideBashScenario 'app-existing' $desktopAppBlock
Assert 'desktop app block records pre-existing app receipt' (
    $desktopAppExisting.Exit -eq 0 -and
    (Read-ScenarioFile $desktopAppExisting '.p89-receipts/desktop-app.json' | ConvertFrom-Json).app.created -eq $false
) $desktopAppExisting.Output
$appListFail = Invoke-GuideBashScenario 'app-list-fail' $desktopAppBlock
Assert 'app list failure refuses and does not create' (
    $appListFail.Exit -ne 0 -and $appListFail.Output -match 'could not list app' -and -not ((Read-ScenarioFile $appListFail 'calls.log') -match 'ad app create')
) $appListFail.Output
$appDuplicate = Invoke-GuideBashScenario 'app-duplicate' $desktopAppBlock
Assert 'duplicate app names are refused with no receipt' (
    $appDuplicate.Exit -ne 0 -and $appDuplicate.Output -match 'apps are named' -and -not (Read-ScenarioFile $appDuplicate '.p89-receipts/desktop-app.json')
) $appDuplicate.Output
$appCreateFail = Invoke-GuideBashScenario 'app-create-fail' $desktopAppBlock
Assert 'app create failure refuses with no receipt' (
    $appCreateFail.Exit -ne 0 -and $appCreateFail.Output -match 'Tenant settings may block app registration' -and -not (Read-ScenarioFile $appCreateFail '.p89-receipts/desktop-app.json')
) $appCreateFail.Output

$tierWrites = Invoke-GuideBashScenario 'tier-writes' $tierBlock
Assert 'tier write block writes limits and guarded model list' (
    $tierWrites.Exit -eq 0 -and
    (Read-ScenarioFile $tierWrites 'writes.log') -match 'tpm-standard=30000' -and
    (Read-ScenarioFile $tierWrites 'writes.log') -match 'quota-standard=750000' -and
    (Read-ScenarioFile $tierWrites 'writes.log') -match 'models-standard=,claude-sonnet-5,'
) $tierWrites.Output

$budgetWrite = Invoke-GuideBashScenario 'budget-write' $budgetBlock
Assert 'budget write block preserves other overrides and replaces target oid' (
    $budgetWrite.Exit -eq 0 -and
    (Read-ScenarioFile $budgetWrite 'writes.log') -match 'quota-overrides=,aaaaaaaa-aaaa-aaaa-aaaa-000000000001=100,55555555-5555-5555-5555-555555555555=2000000,'
) $budgetWrite.Output

$budgetOversize = Invoke-GuideBashScenario 'budget-oversize' $budgetBlock
Assert 'budget write block refuses oversize quota-overrides before write' (
    $budgetOversize.Exit -ne 0 -and
    -not ((Read-ScenarioFile $budgetOversize 'writes.log') -match 'quota-overrides=') -and
    $budgetOversize.Output -match '4,096'
) $budgetOversize.Output

$handover = Invoke-GuideBashScenario 'handover' $handoverBlock
$handoverJson = Read-ScenarioFile $handover 'onboarding/claude-gateway.json'
$installerText = Read-Text (Join-Path $root 'Install-ClaudeGateway.ps1')
$configBlock = [regex]::Match($installerText, '(?s)\$config = \[ordered\]@\{(.*?)\n\}').Groups[1].Value
$installerKeys = @([regex]::Matches($configBlock, '(?m)^    ([A-Za-z][A-Za-z0-9]*)\s*=') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$guideKeys = @((($handoverJson | ConvertFrom-Json).PSObject.Properties.Name) | Sort-Object -Unique)
Assert 'handover block emits installer top-level key set' (
    $handover.Exit -eq 0 -and
    (($installerKeys -join '|') -ceq ($guideKeys -join '|'))
) "installer=$($installerKeys -join ',') guide=$($guideKeys -join ',') output=$($handover.Output)"
$handoverObject = $handoverJson | ConvertFrom-Json
Assert 'handover block emits installer value types used by workstation setup' (
    $handoverObject.subscriptionId -is [string] -and
    @($handoverObject.tiers.standard.models).Count -ge 1 -and
    $handoverObject.tiers.standard.modelAllowList -is [string] -and
    $handoverObject.requestsPerMinute -is [ValueType]
) $handoverJson
$setupText = Read-Text (Join-Path $root 'scripts\Setup-ClaudeWorkstation.ps1')
$onboardText = Read-Text (Join-Path $root 'scripts\Onboard-ClaudeDeveloper.ps1')
Assert 'workstation setup and onboarding scripts accept ConfigPath handover input' (
    $setupText -match '\[string\]\$ConfigPath' -and $onboardText -match '\[Parameter\(Mandatory = \$true\)\]\[string\]\$ConfigPath' -and $onboardText -match '\[switch\]\$PreflightOnly'
)

$projectionDeploy = Invoke-GuideBashScenario 'projection-deploy' $projectionDeployBlock
$projectionDeployWrites = Read-ScenarioFile $projectionDeploy 'writes.log'
Assert 'projection deployment block deploys store before network' (
    $projectionDeploy.Exit -eq 0 -and
    $projectionDeployWrites.IndexOf('deployment-create projection-prefix') -ge 0 -and
    $projectionDeployWrites.IndexOf('deployment-create projection-network-prefix') -gt $projectionDeployWrites.IndexOf('deployment-create projection-prefix')
) $projectionDeploy.Output

$resolverDeploy = Invoke-GuideBashScenario 'resolver-deploy' (Join-GuideBlocks @($projectionDeployBlock, $resolverDeployBlock))
$resolverParams = Read-ScenarioFile $resolverDeploy 'resolver-params.json'
Assert 'resolver deployment block allows the gateway managed identity app and object ids' (
    $resolverDeploy.Exit -eq 0 -and
    ($resolverParams | ConvertFrom-Json).parameters.allowedCallerAppIds.value[0] -ceq 'gateway-app-id' -and
    ($resolverParams | ConvertFrom-Json).parameters.allowedCallerObjectIds.value[0] -ceq 'gateway-object-id'
) $resolverDeploy.Output

$projectionRunner = Invoke-GuideBashScenario 'projection-runner' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
$runnerCalls = Read-ScenarioFile $projectionRunner 'writes.log'
Assert 'projection runner block assigns Cosmos role and transfers files before apply and compare' (
    $projectionRunner.Exit -eq 0 -and
    $runnerCalls -match 'cosmos-role' -and
    $runnerCalls -match 'sync-source\.tar\.gz' -and
    $runnerCalls -match 'snapshot\.json' -and
    $runnerCalls -match 'apply-projection\.mjs --cosmos .* --snapshot /work/snapshot\.json' -and
    $runnerCalls -match 'gateway-decisions\.json' -and
    $runnerCalls -match 'apply-projection\.mjs --cosmos .* --compare /work/gateway-decisions\.json'
) $projectionRunner.Output

$runnerChunkFail = Invoke-GuideBashScenario 'runner-chunk-fail' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner failed chunk stops before apply and compare' (
    $runnerChunkFail.Exit -ne 0 -and
    $runnerChunkFail.Output -match 'Refused: runner transfer chunk failed' -and
    -not ((Read-ScenarioFile $runnerChunkFail 'writes.log') -match 'apply-projection\.mjs')
) $runnerChunkFail.Output

$runnerHashMismatch = Invoke-GuideBashScenario 'runner-hash-mismatch' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner hash mismatch stops before apply and compare' (
    $runnerHashMismatch.Exit -ne 0 -and
    $runnerHashMismatch.Output -match 'Refused: runner transfer hash mismatch' -and
    -not ((Read-ScenarioFile $runnerHashMismatch 'writes.log') -match 'apply-projection\.mjs')
) $runnerHashMismatch.Output

$runnerChunkErrorText = Invoke-GuideBashScenario 'runner-chunk-error-text' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner chunk error text with exit zero stops before apply and compare' (
    $runnerChunkErrorText.Exit -ne 0 -and
    $runnerChunkErrorText.Output -match 'Refused: runner transfer chunk reported an error' -and
    -not ((Read-ScenarioFile $runnerChunkErrorText 'writes.log') -match 'apply-projection\.mjs')
) $runnerChunkErrorText.Output
$chunkErrorMutation = $projectionRunnerBlock -replace 'ERROR\|InvalidCommandLength\|terminated with non-zero', 'NO_MATCH'
$chunkErrorMutationRun = Invoke-GuideBashScenario 'runner-chunk-error-text' (Join-GuideBlocks @($projectionDeployBlock, $chunkErrorMutation))
Assert 'chunk error-text guard mutation reaches apply and is caught' (
    $chunkErrorMutationRun.Exit -eq 0 -and (Read-ScenarioFile $chunkErrorMutationRun 'writes.log') -match 'apply-projection\.mjs'
) $chunkErrorMutationRun.Output

$allCreatedReceipts = "mkdir -p .p89-receipts; printf '%s\n' '{""foundryRole"":{""created"":true,""id"":""created-role-id""}}' > .p89-receipts/foundry-role.json; printf '%s\n' '{""group"":{""created"":true,""id"":""standard-id""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":true,""id"":""premium-id""}}' > .p89-receipts/group-premium.json; printf '%s\n' '{""app"":{""created"":true,""appId"":""created-app-id""}}' > .p89-receipts/desktop-app.json;"
$allExistingReceipts = "mkdir -p .p89-receipts; printf '%s\n' '{""foundryRole"":{""created"":false,""existingId"":""existing-role-id""}}' > .p89-receipts/foundry-role.json; printf '%s\n' '{""group"":{""created"":false,""id"":""standard-id""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":false,""id"":""premium-id""}}' > .p89-receipts/group-premium.json; printf '%s\n' '{""app"":{""created"":false,""appId"":""existing-app-id""}}' > .p89-receipts/desktop-app.json;"

$teardownCreated = Invoke-GuideBashScenario 'teardown-created' (Join-GuideBlocks @($allCreatedReceipts, $teardownExternalBlock))
Assert 'teardown deletes only receipt-created role assignment' (
    $teardownCreated.Exit -eq 0 -and (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-role created-role-id'
) $teardownCreated.Output
Assert 'teardown deletes receipt-created groups and app' (
    $teardownCreated.Exit -eq 0 -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-group standard-id' -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-group premium-id' -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-app created-app-id'
) $teardownCreated.Output

$teardownExisting = Invoke-GuideBashScenario 'teardown-existing' (Join-GuideBlocks @($allExistingReceipts, $teardownExternalBlock))
Assert 'teardown preserves pre-existing role assignment' (
    $teardownExisting.Exit -eq 0 -and -not ((Read-ScenarioFile $teardownExisting 'writes.log') -match 'delete-role')
) $teardownExisting.Output
Assert 'teardown preserves pre-existing groups and app' (
    $teardownExisting.Exit -eq 0 -and
    -not ((Read-ScenarioFile $teardownExisting 'writes.log') -match 'delete-group|delete-app')
) $teardownExisting.Output

$teardownMissingReceipt = Invoke-GuideBashScenario 'teardown-missing-receipt' $teardownExternalBlock
Assert 'teardown with missing receipt refuses and deletes nothing' (
    $teardownMissingReceipt.Exit -ne 0 -and
    $teardownMissingReceipt.Output -match 'No receipt' -and
    -not ((Read-ScenarioFile $teardownMissingReceipt 'writes.log') -match 'delete-')
) $teardownMissingReceipt.Output
$missingPremiumReceipt = "mkdir -p .p89-receipts; printf '%s\n' '{""foundryRole"":{""created"":true,""id"":""created-role-id""}}' > .p89-receipts/foundry-role.json; printf '%s\n' '{""group"":{""created"":true,""id"":""standard-id""}}' > .p89-receipts/group-standard.json;"
$teardownMissingPremium = Invoke-GuideBashScenario 'teardown-missing-premium' (Join-GuideBlocks @($missingPremiumReceipt, $teardownExternalBlock))
Assert 'missing premium group receipt refuses before any external delete' (
    $teardownMissingPremium.Exit -ne 0 -and
    $teardownMissingPremium.Output -match 'group-premium' -and
    -not ((Read-ScenarioFile $teardownMissingPremium 'writes.log') -match 'delete-')
) $teardownMissingPremium.Output
$noAppReceipt = "mkdir -p .p89-receipts; printf '%s\n' '{""foundryRole"":{""created"":false,""existingId"":""existing-role-id""}}' > .p89-receipts/foundry-role.json; printf '%s\n' '{""group"":{""created"":false,""id"":""standard-id""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":false,""id"":""premium-id""}}' > .p89-receipts/group-premium.json;"
$teardownNoApp = Invoke-GuideBashScenario 'teardown-no-app-receipt' (Join-GuideBlocks @($noAppReceipt, $teardownExternalBlock))
Assert 'missing optional Desktop app receipt does not fail teardown' (
    $teardownNoApp.Exit -eq 0 -and $teardownNoApp.Output -match 'No Desktop app receipt'
) $teardownNoApp.Output

if ($script:fail) { throw "$script:fail assertion(s) failed." }
