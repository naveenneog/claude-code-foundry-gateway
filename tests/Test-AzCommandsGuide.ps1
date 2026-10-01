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

$assignedAuthVars = New-Object 'System.Collections.Generic.HashSet[string]'
$authorizationHeaders = New-Object Collections.Generic.List[string]
foreach ($block in [regex]::Matches($markdown, '(?ms)^```(?:bash|sh)\s*$(.*?)^```\s*$')) {
    $blockText = $block.Groups[1].Value
    foreach ($line in ($blockText -split "`r?`n")) {
        foreach ($assign in [regex]::Matches($line, '^\s*(?:export\s+)?([A-Z_]+)=["'']?')) {
            [void]$assignedAuthVars.Add($assign.Groups[1].Value)
        }
        foreach ($auth in [regex]::Matches($line, 'Authorization:\s*([^"]+)')) {
            $authorizationHeaders.Add($auth.Value)
        }
    }
}
Assert 'guide has four Authorization headers in bash fences' ($authorizationHeaders.Count -eq 4) "count=$($authorizationHeaders.Count)"
for ($i = 0; $i -lt 4; $i++) {
    $header = if ($i -lt $authorizationHeaders.Count) { $authorizationHeaders[$i] } else { '' }
    $varMatch = [regex]::Match($header, '^Authorization:\s*Bearer\s+\$([A-Z_]+)$')
    Assert "authorization header $i uses Bearer variable form" ($varMatch.Success) $header
    Assert "authorization header $i has no masked literal" ($header -notmatch '\*{6}') $header
    $var = if ($varMatch.Success) { $varMatch.Groups[1].Value } else { '' }
    Assert "authorization header variable $i is assigned before use" ($var -and $assignedAuthVars.Contains($var)) $header
}



function Get-MarkedBashBlock([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "(?ms)# P89-$Name-BEGIN\s*(.*?)# P89-$Name-END")
    if (-not $m.Success) { throw "Missing P89-$Name marked bash block." }
    return $m.Groups[1].Value.Trim()
}

function Convert-ExistingParamToNamedValue([string]$Name) {
    $base = $Name -replace 'Existing$','' -replace 'Value$',''
    $words = [regex]::Replace($base, '([a-z0-9])([A-Z])', '$1-$2').ToLowerInvariant()
    $words
}

$operatorOwnedFromBicep = @([regex]::Matches($bicep, '(?m)^\s*param\s+([A-Za-z][A-Za-z0-9]*Existing)\s+') |
    ForEach-Object { Convert-ExistingParamToNamedValue $_.Groups[1].Value } |
    Sort-Object -Unique)
$expectedReuseRefusal = @($operatorOwnedFromBicep + 'entitlement-source' | Sort-Object -Unique)
$reuseBlockText = Get-MarkedBashBlock $markdown 'REUSE-APIM'
$reuseListMatch = [regex]::Match($reuseBlockText, '\[("allow-standard".*?"entitlement-source")\]')
$reuseRefusalList = if ($reuseListMatch.Success) {
    @([regex]::Matches($reuseListMatch.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
} else { @() }
Assert 'reuse refusal list equals operator-owned Existing named values plus entitlement-source' (
    ($expectedReuseRefusal -join '|') -ceq ($reuseRefusalList -join '|')
) "expected=$($expectedReuseRefusal -join ',') actual=$($reuseRefusalList -join ',')"

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
  if [[ "$query" == *displayName* ]]; then
    if [ "${P89_SCENARIO:-}" = "teardown-group-live-mismatch" ] && [ "$group" = "standard-id" ]; then printf '{"id":"standard-id","displayName":"other","createdDateTime":"2020-01-01T00:00:00Z"}\n'
    elif [ "$group" = "standard-id" ]; then printf '{"id":"standard-id","displayName":"claude-code-standard","createdDateTime":"2020-01-01T00:00:00Z"}\n'; else printf '{"id":"premium-id","displayName":"claude-code-premium","createdDateTime":"2020-01-01T00:00:00Z"}\n'; fi
    exit 0
  fi
  if [[ "$query" == *createdDateTime* ]]; then
    if [ "${P89_SCENARIO:-}" = "group-young" ]; then date -u +"%Y-%m-%dT%H:%M:%SZ"; else printf '2020-01-01T00:00:00Z\n'; fi
    exit 0
  fi
  if [ "$group" = "$STANDARD_GROUP" ]; then printf 'standard-id\n'; else printf 'premium-id\n'; fi
  exit 0
fi
if [ "$1" = "account" ] && [ "$2" = "show" ]; then
  printf 'sub\n'
  exit 0
fi
if [ "$1" = "keyvault" ] && [ "$2" = "certificate" ] && [ "$3" = "show" ]; then
  if [ "${P89_SCENARIO:-}" = "keyvault-show-fail" ]; then echo "vault not found" >&2; exit 3; fi
  printf '{"sid":"https://kv.vault.azure.net/secrets/cert/ver","attributes":{"enabled":true},"policy":{"keyProperties":{"exportable":true},"secretProperties":{"contentType":"application/x-pkcs12"}}}\n'
  exit 0
fi
if [ "$1" = "keyvault" ] && [ "$2" = "show" ]; then
  rbac=true; [ "${P89_SCENARIO:-}" = "keyvault-access-policy" ] && rbac=false
  printf '{"id":"/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv","rbac":%s}\n' "$rbac"
  exit 0
fi
if [ "$1" = "apim" ] && [ "$2" = "show" ]; then
  query="$(arg_after --query "$@")"
  if [ -z "$query" ]; then
    case "${P89_SCENARIO:-}" in
      reuse-no-identity) printf '{"name":"apim","sku":{"name":"BasicV2"},"identity":null}\n' ;;
      reuse-classic-sku) printf '{"name":"apim","sku":{"name":"Developer"},"identity":{"type":"SystemAssigned","principalId":"gateway-object-id"}}\n' ;;
      gateway-address) printf '{"name":"apim","gatewayUrl":"https://apim.azure-api.net","sku":{"name":"PremiumV2"},"identity":{"type":"SystemAssigned","principalId":"gateway-object-id"},"hostnameConfigurations":[{"type":"Proxy","hostName":"custom.example"}]}\n' ;;
      hostname-success) printf '{"name":"apim","gatewayUrl":"https://apim.azure-api.net","sku":{"name":"PremiumV2"},"identity":{"type":"SystemAssigned","principalId":"gateway-object-id"},"hostnameConfigurations":[{"type":"Proxy","hostName":"new.example"}]}\n' ;;
      *) printf '{"name":"apim","gatewayUrl":"https://apim.azure-api.net","sku":{"name":"BasicV2"},"identity":{"type":"SystemAssigned","principalId":"gateway-object-id"}}\n' ;;
    esac
    exit 0
  fi
  case "${P89_SCENARIO:-}" in
    identity-null|identity-patch|identity-timeout)
      if [ -f "${P89_STATE_DIR:-.}/identity-enabled" ] && [ "$query" = "identity" ]; then printf '{"type":"SystemAssigned","principalId":"gateway-object-id"}\n'; elif [ "$query" = "identity" ]; then printf 'null\n'; elif [[ "$query" == *identity.principalId* ]]; then
        state="${P89_STATE_DIR:-.}/identity-poll"; n=0; [ -f "$state" ] && n="$(cat "$state")"; n=$((n+1)); printf '%s' "$n" > "$state"; [ "${P89_SCENARIO:-}" != "identity-timeout" ] && [ "$n" -ge 2 ] && printf 'gateway-object-id\n'
      elif [[ "$query" == *id:id* ]]; then printf '{"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim","identity":null}\n'; else printf '{}\n'; fi
      ;;
    identity-userassigned)
      if [ "$query" = "identity" ]; then printf '{"type":"UserAssigned","principalId":null}\n'; elif [[ "$query" == *id:id* ]]; then printf '{"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim","identity":{"type":"UserAssigned"}}\n'; else printf '\n'; fi
      ;;
    *)
      if [ "$query" = "identity" ]; then printf '{"type":"SystemAssigned","principalId":"gateway-object-id"}\n'; elif [[ "$query" == *identity.principalId* ]]; then printf 'gateway-object-id\n'; elif [[ "$query" == *id:id* ]]; then printf '{"id":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim","identity":{"type":"SystemAssigned","principalId":"gateway-object-id"}}\n'; else printf '{}\n'; fi
      ;;
  esac
  exit 0
fi
if [ "$1" = "group" ]; then
  case "$2" in
    exists) if [ "${P89_SCENARIO:-}" = "rg-exists-fail" ]; then echo "exists failed" >&2; exit 3; elif [ "${P89_SCENARIO:-}" = "rg-existing" ] || [ "${P89_SCENARIO:-}" = "rg-tag-mismatch" ] || [ "${P89_SCENARIO:-}" = "rg-tag-missing" ]; then printf 'true\n'; else printf 'false\n'; fi; exit 0 ;;
    create) printf 'group-create %s\n' "$*" >> "$P89_WRITES"; exit 0 ;;
    show)
      query="$(arg_after --query "$@")"
      if [[ "$query" == *claude-gateway-receipt* ]]; then
        case "${P89_SCENARIO:-}" in
          rg-tag-mismatch|teardown-group-tag-mismatch) printf 'other-nonce\n' ;;
          rg-tag-missing|teardown-group-tag-missing) printf '\n' ;;
          *) printf 'receipt-nonce\n' ;;
        esac
      else
        printf '{"name":"rg","location":"eastus","tags":{"claude-gateway-receipt":"receipt-nonce"}}\n'
      fi
      exit 0
      ;;
    delete) printf 'group-delete %s\n' "$*" >> "$P89_WRITES"; exit 0 ;;
  esac
fi
if [ "$1" = "resource" ] && [ "$2" = "list" ]; then
  printf '[]\n'
  exit 0
fi
if [ "$1" = "apim" ] && [ "$2" = "list" ]; then
  if [ "${P89_SCENARIO:-}" = "apim-list-fail" ]; then echo "apim list failed" >&2; exit 3; fi
  if [ "${P89_SCENARIO:-}" = "apim-existing" ]; then printf '[{"name":"apim"}]\n'; else printf '[]\n'; fi
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
  if [ "${P89_SCENARIO:-}" = "budget-user-fail" ]; then echo "user read failed" >&2; exit 3; fi
  if [ "${P89_SCENARIO:-}" = "budget-user-empty" ]; then printf '\n'; exit 0; fi
  if [ "${P89_SCENARIO:-}" = "budget-user-bad" ]; then printf 'not-a-guid\n'; exit 0; fi
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
  if [ "${P89_SCENARIO:-}" = "resolver-gateway-app-fail" ]; then echo "sp read failed" >&2; exit 3; fi
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
      printf '{"appId":"created-app-id","id":"created-object-id","displayName":"Claude Desktop gateway"}\n'
      exit 0
      ;;
    update|show)
      if [ "$3" = "show" ]; then
        if [ "${P89_SCENARIO:-}" = "redirect-missing-uri" ]; then printf '{"appId":"created-app-id","id":"created-object-id","displayName":"Claude Desktop gateway","publicClient":{"redirectUris":["https://existing.example/callback"]},"isFallbackPublicClient":true}\n'
        elif [ "${P89_SCENARIO:-}" = "redirect-fallback-false" ]; then printf '{"appId":"created-app-id","id":"created-object-id","displayName":"Claude Desktop gateway","publicClient":{"redirectUris":["https://existing.example/callback","http://127.0.0.1/callback","ms-appx-web://Microsoft.AAD.BrokerPlugin/66666666-6666-6666-6666-666666666666","msauth.com.anthropic.claudefordesktop://auth"]},"isFallbackPublicClient":false}\n'
        elif [ -f "${P89_STATE_DIR:-.}/app-updated" ]; then printf '{"appId":"created-app-id","id":"created-object-id","displayName":"Claude Desktop gateway","publicClient":{"redirectUris":["https://existing.example/callback","http://127.0.0.1/callback","ms-appx-web://Microsoft.AAD.BrokerPlugin/66666666-6666-6666-6666-666666666666","msauth.com.anthropic.claudefordesktop://auth"]},"isFallbackPublicClient":true}\n'
        elif [ "${P89_SCENARIO:-}" = "redirect-extra" ]; then printf '{"appId":"created-app-id","id":"created-object-id","displayName":"Claude Desktop gateway","publicClient":{"redirectUris":["https://existing.example/callback"]},"isFallbackPublicClient":false}\n'
        elif [ "${P89_SCENARIO:-}" = "teardown-app-live-mismatch" ]; then printf '{"appId":"created-app-id","id":"other-object-id","displayName":"Claude Desktop gateway","publicClient":{"redirectUris":["http://127.0.0.1/callback"]},"isFallbackPublicClient":true}\n'
        else printf '{"appId":"created-app-id","id":"created-object-id","displayName":"Claude Desktop gateway","publicClient":{"redirectUris":["http://127.0.0.1/callback"]},"isFallbackPublicClient":true}\n'; fi
      else
        printf 'app-update %s\n' "$*" >> "$P89_WRITES"
        printf '1' > "${P89_STATE_DIR:-.}/app-updated"
        printf '{}\n'
      fi
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
      query="$(arg_after --query "$@")"
      scope="$(arg_after --scope "$@" || true)"
      allflag="false"; for a in "$@"; do [ "$a" = "--all" ] && allflag="true"; done
      if [ -z "$scope" ] && [ "$allflag" != "true" ]; then printf 'null\n'; exit 0; fi
      if [[ "$*" == *kv-created-role-id* ]]; then
        case "${P89_SCENARIO:-}" in
          teardown-kv-role-id-mismatch) printf '{"id":"other-kv-role-id","scope":"/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv","roleDefinitionName":"Key Vault Secrets User","principalId":"gateway-object-id"}\n' ;;
          teardown-kv-role-scope-mismatch) printf '{"id":"kv-created-role-id","scope":"/subscriptions/subscription-scope","roleDefinitionName":"Key Vault Secrets User","principalId":"gateway-object-id"}\n' ;;
          teardown-kv-role-live-mismatch|teardown-kv-role-name-mismatch) printf '{"id":"kv-created-role-id","scope":"/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv","roleDefinitionName":"Reader","principalId":"gateway-object-id"}\n' ;;
          teardown-kv-role-principal-mismatch) printf '{"id":"kv-created-role-id","scope":"/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv","roleDefinitionName":"Key Vault Secrets User","principalId":"other-principal"}\n' ;;
          *) printf '{"id":"kv-created-role-id","scope":"/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv","roleDefinitionName":"Key Vault Secrets User","principalId":"gateway-object-id"}\n' ;;
        esac
      elif [[ "$*" == *created-role-id* ]]; then
        case "${P89_SCENARIO:-}" in
          teardown-role-id-mismatch) printf '{"id":"other-role-id","scope":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry","roleDefinitionName":"Cognitive Services User","principalId":"gateway-object-id"}\n' ;;
          teardown-role-scope-mismatch) printf '{"id":"created-role-id","scope":"/subscriptions/subscription-scope","roleDefinitionName":"Cognitive Services User","principalId":"gateway-object-id"}\n' ;;
          teardown-role-live-mismatch|teardown-role-name-mismatch) printf '{"id":"created-role-id","scope":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry","roleDefinitionName":"Reader","principalId":"gateway-object-id"}\n' ;;
          teardown-role-principal-mismatch) printf '{"id":"created-role-id","scope":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry","roleDefinitionName":"Cognitive Services User","principalId":"other-principal"}\n' ;;
          *) printf '{"id":"created-role-id","scope":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry","roleDefinitionName":"Cognitive Services User","principalId":"gateway-object-id"}\n' ;;
        esac
      elif [ "${P89_SCENARIO:-}" = "role-existing" ]; then printf 'existing-role-id\n'; elif [ "${P89_SCENARIO:-}" = "keyvault-existing" ]; then printf 'kv-existing-role-id\n'; fi
      exit 0
      ;;
    create)
      if [ "${P89_SCENARIO:-}" = "role-create-fail" ]; then echo "Role create failed" >&2; exit 3; fi
      role="$(arg_after --role "$@")"
      if [ "$role" = "Key Vault Secrets User" ]; then printf '{"id":"kv-created-role-id","scope":"/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv","roleDefinitionName":"Key Vault Secrets User","principalId":"gateway-object-id"}\n'; else printf '{"id":"created-role-id","scope":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry","roleDefinitionName":"Cognitive Services User","principalId":"gateway-object-id"}\n'; fi
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
  method="$(arg_after --method "$@")"
  url="$(arg_after --url "$@")"
  if [ "$method" = "get" ] && [[ "$url" == *Microsoft.ApiManagement/service* ]]; then
    sku="PremiumV2"; [ "${P89_SCENARIO:-}" = "hostname-standard-refuse" ] && sku="StandardV2"
    provisioning="Succeeded"; certStatus="Ready"; sameBinding=''; includeNew="true"; certStatusProperty='true'
    case "${P89_SCENARIO:-}" in
      hostname-not-succeeded) provisioning="Updating" ;;
      hostname-preserve-clientcert) sameBinding=',{"type":"Proxy","hostName":"new.example","certificateSource":"KeyVault","keyVaultId":"oldsecret","defaultSslBinding":true,"negotiateClientCertificate":true,"certificateStatus":"Ready"}'; includeNew="false" ;;
      hostname-updating-then-succeeded)
        if [ -f "${P89_STATE_DIR:-.}/hostname-patched" ]; then
          state="${P89_STATE_DIR:-.}/hostname-updating-seen"; if [ ! -f "$state" ]; then printf '1' > "$state"; provisioning="Updating"; fi
        fi
        ;;
      hostname-failed) [ -f "${P89_STATE_DIR:-.}/hostname-patched" ] && provisioning="Failed" ;;
      hostname-canceled) [ -f "${P89_STATE_DIR:-.}/hostname-patched" ] && provisioning="Canceled" ;;
      hostname-cert-failed) [ -f "${P89_STATE_DIR:-.}/hostname-patched" ] && certStatus="Failed" ;;
      hostname-cert-timeout) [ -f "${P89_STATE_DIR:-.}/hostname-patched" ] && certStatus="InProgress" ;;
      hostname-empty-certstatus) certStatusProperty='false' ;;
      hostname-no-binding) includeNew='false' ;;
    esac
    printf '{"sku":{"name":"%s"},"properties":{"provisioningState":"%s","hostnameConfigurations":[{"type":"Proxy","hostName":"x.azure-api.net","certificateSource":"BuiltIn"},{"type":"Proxy","hostName":"other.example","certificateSource":"KeyVault","keyVaultId":"oldsecret","defaultSslBinding":false,"negotiateClientCertificate":false,"certificateStatus":"Ready"},{"type":"DeveloperPortal","hostName":"portal.example","certificateSource":"KeyVault","keyVaultId":"portalsecret"}%s' "$sku" "$provisioning" "$sameBinding"
    if [ "$includeNew" = "true" ]; then
      if [ "$certStatusProperty" = "true" ]; then printf ',{"type":"Proxy","hostName":"new.example","certificateSource":"KeyVault","keyVaultId":"https://kv.vault.azure.net/secrets/cert/ver","defaultSslBinding":false,"negotiateClientCertificate":false,"certificateStatus":"%s"}' "$certStatus"; else printf ',{"type":"Proxy","hostName":"new.example","certificateSource":"KeyVault","keyVaultId":"https://kv.vault.azure.net/secrets/cert/ver","defaultSslBinding":false,"negotiateClientCertificate":false}'; fi
    fi
    printf ']}}\n'
    exit 0
  fi
  if [ "$2" = "--method" ] && [ "$3" = "patch" ]; then
    body="$(arg_after --body "$@")"
    printf 'rest-patch-command %s\n' "$*" >> "$P89_WRITES"
    if [ -n "$body" ] && [ -f "${body#@}" ]; then printf 'rest-patch-body '; cat "${body#@}" >> "$P89_WRITES"; printf '\n' >> "$P89_WRITES"; else printf 'rest-patch %s\n' "$*" >> "$P89_WRITES"; fi
    printf '1' > "${P89_STATE_DIR:-.}/identity-enabled"
    if [[ "$url" == *Microsoft.ApiManagement/service* ]]; then
      if [ "${P89_SCENARIO:-}" = "hostname-kv-retry" ] && [ ! -f "${P89_STATE_DIR:-.}/kv-retried" ]; then printf '1' > "${P89_STATE_DIR:-.}/kv-retried"; echo 'KeyVault Forbidden' >&2; exit 3; fi
      if [ "${P89_SCENARIO:-}" = "hostname-patch-other-error" ]; then echo 'BadRequest unrelated' >&2; exit 3; fi
      printf '1' > "${P89_STATE_DIR:-.}/hostname-patched"
    fi
    exit 0
  fi
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
  [ "$id" = "models-standard" ] && printf '1' > "${P89_STATE_DIR:-.}/models-updated"
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
    models-premium)
      if [ "${P89_SCENARIO:-}" = "models-premium-read-fail" ]; then echo "read failed" >&2; exit 3; fi
      if [ "${P89_SCENARIO:-}" = "models-premium-malformed" ]; then printf 'claude-sonnet-5\n'; else printf ',claude-sonnet-5,\n'; fi
      ;;
    models-standard)
      if [ "${P89_SCENARIO:-}" = "model-read-fail" ]; then echo "read failed" >&2; exit 3; fi
      if [ "${P89_SCENARIO:-}" = "model-read-empty" ]; then printf '\n'; exit 0; fi
      if [ "${P89_SCENARIO:-}" = "model-restore-mismatch" ] && [ -f "${P89_STATE_DIR:-.}/models-updated" ]; then printf ',different,\n'; else printf ',claude-sonnet-5,claude-opus-5,\n'; fi
      ;;
    *) printf 'value\n' ;;
  esac
  exit 0
fi
if [ "$1" = "apim" ] && [ "$2" = "nv" ] && [ "$3" = "list" ]; then
  if [ "${P89_SCENARIO:-}" = "reuse-installed" ]; then printf '[{"name":"allow-standard"}]\n'; else printf '[]\n'; fi
  exit 0
fi
if [ "$1" = "deployment" ] && [ "$2" = "group" ]; then
  action="$3"
  if [ "$action" = "what-if" ]; then
    printf 'deployment-what-if %s\n' "$*" >> "$P89_WRITES"
    exit 0
  fi
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
          *) if [ "${P89_SCENARIO:-}" = "resolver-network-missing" ]; then printf '{"runnerName":{"value":"runner-aci"}}\n'; else printf '{"runnerName":{"value":"runner-aci"},"runnerPrincipalId":{"value":"runner-principal"},"resolverSubnetId":{"value":"resolver-subnet"},"endpointsSubnetId":{"value":"endpoints-subnet"},"sitesDnsZoneId":{"value":"sites-zone"},"blobDnsZoneId":{"value":"blob-zone"},"queueDnsZoneId":{"value":"queue-zone"},"tableDnsZoneId":{"value":"table-zone"}}\n'; fi ;;
        esac
        ;;
      projection-resolver-*) if [ "${P89_SCENARIO:-}" = "resolver-site-empty" ]; then printf '\n'; else printf 'func-resolver\n'; fi ;;
      projection-*)
        if [[ "$query" == *accountName.value* ]]; then if [ "${P89_SCENARIO:-}" = "projection-cosmos-empty" ]; then printf '\n'; else printf 'cosmos-prefix\n'; fi; else printf '{"accountName":{"value":"cosmos-prefix"}}\n'; fi
        ;;
      *) printf '{}\n' ;;
    esac
    exit 0
  fi
fi
if [ "$1" = "cognitiveservices" ] && [ "$2" = "account" ] && [ "$3" = "show" ]; then
  printf '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry\n'
  exit 0
fi
if [ "$1" = "cosmosdb" ] && [ "$2" = "sql" ] && [ "$3" = "role" ] && [ "$4" = "assignment" ] && [ "$5" = "create" ]; then
  printf 'cosmos-role\n' >> "$P89_WRITES"
  exit 0
fi
if [ "$1" = "container" ] && [ "$2" = "exec" ]; then
  cmd="$(arg_after --exec-command "$@")"
  printf 'container-exec %s\n' "$cmd" >> "$P89_WRITES"
  if [ "${P89_SCENARIO:-}" = "runner-init-fail" ] && [[ "$cmd" == *writeFileSync* && "$cmd" == *".b64"* ]]; then
    echo "init failed" >&2
    exit 9
  fi
  if [ "${P89_SCENARIO:-}" = "runner-init-error-text" ] && [[ "$cmd" == *writeFileSync* && "$cmd" == *".b64"* ]]; then
    echo "ERROR: init reported error"
    exit 0
  fi
  if [ "${P89_SCENARIO:-}" = "runner-finalize-fail" ] && [[ "$cmd" == *Buffer.from* ]]; then
    echo "finalize failed" >&2
    exit 9
  fi
  if [ "${P89_SCENARIO:-}" = "runner-finalize-error-text" ] && [[ "$cmd" == *Buffer.from* ]]; then
    echo "ERROR: finalize reported error"
    exit 0
  fi
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

function New-GuideCurlStub([string]$Directory) {
    $path = Join-Path $Directory 'curl'
    @'
#!/usr/bin/env bash
case "${P89_SCENARIO:-}" in
  hostname-non401) printf '403\n'; exit 0 ;;
  model-curl-fail) echo 'curl failed' >&2; exit 7 ;;
esac
printf '401\n'
exit 0
'@ | Set-Content -LiteralPath $path -NoNewline
    $path
}

function New-GuideDigStub([string]$Directory) {
    $path = Join-Path $Directory 'dig'
    @'
#!/usr/bin/env bash
case "${P89_SCENARIO:-}" in
  hostname-wrong-cname|hostname-dns-never)
    printf 'wrong.azure-api.net.\n'
    ;;
  hostname-dns-second)
    state="${P89_STATE_DIR:-.}/dns-count"; n=0; [ -f "$state" ] && n="$(cat "$state")"; n=$((n+1)); printf '%s' "$n" > "$state"
    if [ "$n" -ge 2 ]; then printf '%s.azure-api.net.\n' "${APIM_NAME:-apim}"; else printf 'wrong.azure-api.net.\n'; fi
    ;;
  *)
    printf '%s.azure-api.net.\n' "${APIM_NAME:-apim}"
    ;;
esac
exit 0
'@ | Set-Content -LiteralPath $path -NoNewline
    $path
}

function New-GuidePythonStub([string]$Directory) {
    $path = Join-Path $Directory 'python3'
    @'
#!/usr/bin/env bash
printf 'receipt-nonce\n'
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
    New-GuideCurlStub $dir | Out-Null
    New-GuideDigStub $dir | Out-Null
    New-GuidePythonStub $dir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'scripts'), (Join-Path $dir 'sync\src'), (Join-Path $dir 'resolver\src'), (Join-Path $dir 'onboarding'), (Join-Path $dir 'config'), (Join-Path $dir '.p89-receipts') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'scripts\Sync-ClaudeProjection.ps1'), "#!/usr/bin/env bash`nwhile [ `"`$#`" -gt 0 ]; do if [ `"`$1`" = `"-ExportPath`" ]; then shift; printf '{`"members`":[]}\n' > `"`$1`"; fi; shift || true; done`n")
    [IO.File]::WriteAllText((Join-Path $dir 'scripts\Compare-ClaudeEntitlement.ps1'), "#!/usr/bin/env bash`nwhile [ `"`$#`" -gt 0 ]; do if [ `"`$1`" = `"-ExportGatewayPath`" ]; then shift; printf '{`"decisions`":[]}\n' > `"`$1`"; fi; shift || true; done`n")
    [IO.File]::WriteAllText((Join-Path $dir 'sync\package.json'), "{`"scripts`":{}}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'sync\src\apply-projection.mjs'), "console.log(`"ok`")`n")
    [IO.File]::WriteAllText((Join-Path $dir 'resolver\host.json'), "{}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'resolver\package.json'), "{`"dependencies`":{}}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'resolver\src\index.js'), "module.exports={}`n")
    [IO.File]::WriteAllText((Join-Path $dir 'config\price-book.json'), "{`"models`":{}}`n")
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
export PUBLISHER_EMAIL="operator@example.test"
export PUBLISHER_NAME="AI Platform Team"
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
export ENTITLEMENT_CACHE_SECONDS="3600"
export DESKTOP_EXTRA_AUDIENCE="urn:disabled:claude-extra-audience"
export DESKTOP_CLIENT_ID="66666666-6666-6666-6666-666666666666"
export RESOLVER_APP_ID="resolver-app-id"
export KEYVAULT_NAME="kv"
export CERT_NAME="cert"
export CERT_SECRET_ID="https://kv.vault.azure.net/secrets/cert/ver"
export GATEWAY_HOSTNAME="new.example"
export GATEWAY_URL="https://apim.azure-api.net/claude"
export FOUNDRY_TOKEN="foundry-token"
export NON_ENTITLED_TOKEN="non-entitled-token"
export APIM_ID="/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim"
export DEVELOPER_UPN="dev@example.test"
export DEVELOPER_ID="55555555-5555-5555-5555-555555555555"
export GRAPH_RETRY_DELAY_SECONDS="0"
export GRAPH_RETRY_ATTEMPTS="3"
export P89_KEYVAULT_PATCH_TIMEOUT_SECONDS="5"
export P89_DNS_TIMEOUT_SECONDS="1"
export P89_HOSTNAME_TIMEOUT_SECONDS="1"
export P89_HOSTNAME_POLL_SECONDS="0"
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

$resourceGroupBlock = Get-MarkedBashBlock $markdown 'RESOURCE-GROUP'
$groupBlock = Get-MarkedBashBlock $markdown 'GROUP-RECEIPTS'
$apimAbsentBlock = Get-MarkedBashBlock $markdown 'APIM-ABSENT'
$reuseApimBlock = Get-MarkedBashBlock $markdown 'REUSE-APIM'
$identityBlock = Get-MarkedBashBlock $markdown 'GATEWAY-IDENTITY'
$enableIdentityBlock = Get-MarkedBashBlock $markdown 'ENABLE-APIM-IDENTITY'
$graphBlock = Get-MarkedBashBlock $markdown 'ENTITLEMENT-GRAPH'
$publishBlock = Get-MarkedBashBlock $markdown 'ENTITLEMENT-PUBLISH'
$addBlock = Get-MarkedBashBlock $markdown 'DEVELOPER-ADD'
$removeBlock = Get-MarkedBashBlock $markdown 'DEVELOPER-REMOVE'
$roleBlock = Get-MarkedBashBlock $markdown 'FOUNDRY-ROLE'
$tierBlock = Get-MarkedBashBlock $markdown 'TIER-WRITES'
$budgetBlock = Get-MarkedBashBlock $markdown 'BUDGET-WRITE'
$addModelBlock = Get-MarkedBashBlock $markdown 'ADD-MODEL'
$desktopAppBlock = Get-MarkedBashBlock $markdown 'DESKTOP-APP'
$desktopRedirectsBlock = Get-MarkedBashBlock $markdown 'DESKTOP-REDIRECTS'
$gatewayUrlBlock = Get-MarkedBashBlock $markdown 'GATEWAY-URL'
$handoverBlock = Get-MarkedBashBlock $markdown 'HANDOVER'
$keyVaultBlock = Get-MarkedBashBlock $markdown 'KEYVAULT-ACCESS'
$bindHostnameBlock = Get-MarkedBashBlock $markdown 'BIND-HOSTNAME'
$projectionDeployBlock = Get-MarkedBashBlock $markdown 'PROJECTION-DEPLOY'
$resolverDeployBlock = Get-MarkedBashBlock $markdown 'RESOLVER-DEPLOY'
$projectionRunnerBlock = Get-MarkedBashBlock $markdown 'PROJECTION-RUNNER'
$bypassReadBlock = Get-MarkedBashBlock $markdown 'BYPASS-READ'
$teardownReadBlock = Get-MarkedBashBlock $markdown 'TEARDOWN-READ'
$teardownGroupBlock = Get-MarkedBashBlock $markdown 'TEARDOWN-GROUP'
$teardownExternalBlock = Get-MarkedBashBlock $markdown 'TEARDOWN-EXTERNAL'
$modelRefusalBlock = Get-MarkedBashBlock $markdown 'MODEL-REFUSAL'
$entitlementScript = Join-GuideBlocks @($groupBlock, $graphBlock, $publishBlock)

$addressScript = Read-Text (Join-Path $root 'scripts\Set-ClaudeGatewayAddress.ps1')
$scriptTimeoutDefaults = @{
    Hostname = [regex]::Match($addressScript, '\[int\]\$TimeoutSeconds\s*=\s*(\d+)').Groups[1].Value
    Dns = [regex]::Match($addressScript, '\[int\]\$DnsTimeoutSeconds\s*=\s*(\d+)').Groups[1].Value
    Poll = [regex]::Match($addressScript, '\[int\]\$PollSeconds\s*=\s*(\d+)').Groups[1].Value
}
$guideTimeoutDefaults = @{
    Hostname = [regex]::Match($bindHostnameBlock, 'P89_HOSTNAME_TIMEOUT_SECONDS="\$\{P89_HOSTNAME_TIMEOUT_SECONDS:-(\d+)\}"').Groups[1].Value
    Dns = [regex]::Match($bindHostnameBlock, 'P89_DNS_TIMEOUT_SECONDS="\$\{P89_DNS_TIMEOUT_SECONDS:-(\d+)\}"').Groups[1].Value
    Poll = [regex]::Match($bindHostnameBlock, 'P89_HOSTNAME_POLL_SECONDS="\$\{P89_HOSTNAME_POLL_SECONDS:-(\d+)\}"').Groups[1].Value
}
Assert 'hostname timeout default mirrors Set-ClaudeGatewayAddress.ps1 TimeoutSeconds' ($guideTimeoutDefaults.Hostname -and $guideTimeoutDefaults.Hostname -eq $scriptTimeoutDefaults.Hostname) "guide=$($guideTimeoutDefaults.Hostname) script=$($scriptTimeoutDefaults.Hostname)"
Assert 'DNS timeout default mirrors Set-ClaudeGatewayAddress.ps1 DnsTimeoutSeconds' ($guideTimeoutDefaults.Dns -and $guideTimeoutDefaults.Dns -eq $scriptTimeoutDefaults.Dns) "guide=$($guideTimeoutDefaults.Dns) script=$($scriptTimeoutDefaults.Dns)"
Assert 'hostname poll default mirrors Set-ClaudeGatewayAddress.ps1 PollSeconds' ($guideTimeoutDefaults.Poll -and $guideTimeoutDefaults.Poll -eq $scriptTimeoutDefaults.Poll) "guide=$($guideTimeoutDefaults.Poll) script=$($scriptTimeoutDefaults.Poll)"
$modelRefusalExpected = [regex]::Match($markdown, '(?s)# P89-MODEL-REFUSAL-END\s*```\s*Expected result:(.*?)(?:\r?\n\r?\n[A-Z][^\r\n]*\.|\r?\n## )').Groups[1].Value
Assert 'model refusal expected result states standard-tier callers are narrowed until restore' (
    $modelRefusalExpected -match 'Between the narrowing write and the restore, every standard-tier caller is refused models outside the narrowed list\.'
) $modelRefusalExpected
Assert 'resolver deploy removes stale zip before packaging' ($resolverDeployBlock -match 'rm -f resolver\.zip') $resolverDeployBlock
Assert 'resolver deploy builds zip in a subshell so cwd is restored on zip failure' ($resolverDeployBlock -match '\(cd resolver && zip -r \.\./resolver\.zip \.\) \|\| return 1') $resolverDeployBlock
Assert 'resolver deploy removes stale params before jq generation' ($resolverDeployBlock -match 'rm -f resolver-params\.json') $resolverDeployBlock
$guideTestSource = Read-Text $PSCommandPath
Assert 'az role assignment stub matches CLI default scope behavior' ($guideTestSource -match 'if \[ -z "\$scope" \] && \[ "\$allflag" != "true" \]; then printf ''null\\n''; exit 0; fi') 'role assignment list without --scope or --all must not return resource-scoped assignments.'
Assert 'Desktop sign-in section states helper-script needs no app registration' ($markdown -match '§7 applies only to `external-idp-browser` and `external-idp-broker` Desktop sign-in; `helper-script` uses the developer''s Azure CLI sign-in and no app registration') 'missing §7 optional-flow sentence'
Assert 'projection prose states Basic v2 cannot use private resolver path' ($markdown -match 'Basic v2 cannot use this path') 'missing Basic v2 resolver SKU sentence'

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

$apimListFail = Invoke-GuideBashScenario 'apim-list-fail' $apimAbsentBlock
Assert 'APIM list failure refuses before what-if or create' (
    $apimListFail.Exit -ne 0 -and $apimListFail.Output -match 'could not list API Management' -and -not ((Read-ScenarioFile $apimListFail 'calls.log') -match 'deployment group')
) $apimListFail.Output

$apimExisting = Invoke-GuideBashScenario 'apim-existing' $apimAbsentBlock
Assert 'existing APIM refuses first-deployment commands' (
    $apimExisting.Exit -ne 0 -and $apimExisting.Output -match 'already exists' -and -not ((Read-ScenarioFile $apimExisting 'calls.log') -match 'deployment group')
) $apimExisting.Output

$rgNew = Invoke-GuideBashScenario 'rg-new' $resourceGroupBlock
Assert 'resource group new create records created true' (
    $rgNew.Exit -eq 0 -and
    (Read-ScenarioFile $rgNew 'writes.log') -match 'group-create' -and
    (Read-ScenarioFile $rgNew 'writes.log') -match 'claude-gateway-receipt=receipt-nonce' -and
    (Read-ScenarioFile $rgNew '.p89-receipts/resource-group.json' | ConvertFrom-Json).resourceGroup.created -eq $true
) $rgNew.Output

$rgExisting = Invoke-GuideBashScenario 'rg-existing' $resourceGroupBlock
Assert 'resource group existing records created false' (
    $rgExisting.Exit -eq 0 -and
    -not ((Read-ScenarioFile $rgExisting 'writes.log') -match 'group-create') -and
    (Read-ScenarioFile $rgExisting '.p89-receipts/resource-group.json' | ConvertFrom-Json).resourceGroup.created -eq $false
) $rgExisting.Output

$rgReceiptRerun = Invoke-GuideBashScenario 'rg-existing' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":true,""name"":""rg"",""nonce"":""receipt-nonce""}}' > .p89-receipts/resource-group.json; " + $resourceGroupBlock)
Assert 'resource group rerun keeps created true receipt when group still exists' (
    $rgReceiptRerun.Exit -eq 0 -and
    -not ((Read-ScenarioFile $rgReceiptRerun 'writes.log') -match 'group-create') -and
    (Read-ScenarioFile $rgReceiptRerun '.p89-receipts/resource-group.json' | ConvertFrom-Json).resourceGroup.created -eq $true
) $rgReceiptRerun.Output

$rgReceiptMismatch = Invoke-GuideBashScenario 'rg-tag-mismatch' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":true,""name"":""rg"",""nonce"":""receipt-nonce""}}' > .p89-receipts/resource-group.json; " + $resourceGroupBlock)
Assert 'resource group rerun refuses mismatched receipt tag' (
    $rgReceiptMismatch.Exit -ne 0 -and
    $rgReceiptMismatch.Output -match 'receipt tag does not match' -and
    -not ((Read-ScenarioFile $rgReceiptMismatch 'writes.log') -match 'group-create')
) $rgReceiptMismatch.Output

$rgReceiptMissingTag = Invoke-GuideBashScenario 'rg-tag-missing' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":true,""name"":""rg"",""nonce"":""receipt-nonce""}}' > .p89-receipts/resource-group.json; " + $resourceGroupBlock)
Assert 'resource group rerun refuses missing receipt tag' (
    $rgReceiptMissingTag.Exit -ne 0 -and
    $rgReceiptMissingTag.Output -match 'receipt tag does not match' -and
    -not ((Read-ScenarioFile $rgReceiptMissingTag 'writes.log') -match 'group-create')
) $rgReceiptMissingTag.Output

$rgReceiptDeleted = Invoke-GuideBashScenario 'rg-new' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":true,""name"":""rg"",""nonce"":""receipt-nonce""}}' > .p89-receipts/resource-group.json; " + $resourceGroupBlock)
Assert 'resource group deleted after created true receipt is recreated' (
    $rgReceiptDeleted.Exit -eq 0 -and
    (Read-ScenarioFile $rgReceiptDeleted 'writes.log') -match 'group-create' -and
    (Read-ScenarioFile $rgReceiptDeleted '.p89-receipts/resource-group.json' | ConvertFrom-Json).resourceGroup.created -eq $true
) $rgReceiptDeleted.Output

$rgExistsFail = Invoke-GuideBashScenario 'rg-exists-fail' $resourceGroupBlock
Assert 'resource group exists failure refuses with no create' (
    $rgExistsFail.Exit -ne 0 -and
    $rgExistsFail.Output -match 'could not check resource group existence' -and
    -not ((Read-ScenarioFile $rgExistsFail 'writes.log') -match 'group-create')
) $rgExistsFail.Output

$reuseNoIdentity = Invoke-GuideBashScenario 'reuse-no-identity' $reuseApimBlock
Assert 'reuse APIM with no identity refuses before what-if' (
    $reuseNoIdentity.Exit -ne 0 -and $reuseNoIdentity.Output -match 'p89_enable_apim_identity' -and -not ((Read-ScenarioFile $reuseNoIdentity 'calls.log') -match 'deployment group what-if')
) $reuseNoIdentity.Output

$reuseInstalled = Invoke-GuideBashScenario 'reuse-installed' $reuseApimBlock
Assert 'reuse APIM with existing gateway named value refuses' (
    $reuseInstalled.Exit -ne 0 -and $reuseInstalled.Output -match 'already has gateway-owned named values' -and -not ((Read-ScenarioFile $reuseInstalled 'calls.log') -match 'deployment group what-if')
) $reuseInstalled.Output

$reuseClassic = Invoke-GuideBashScenario 'reuse-classic-sku' $reuseApimBlock
Assert 'reuse APIM with classic SKU refuses' (
    $reuseClassic.Exit -ne 0 -and $reuseClassic.Output -match 'not BasicV2, StandardV2 or PremiumV2'
) $reuseClassic.Output

$reuseRoleExisting = Invoke-GuideBashScenario 'role-existing' $reuseApimBlock
Assert 'reuse APIM with existing Foundry role passes grantFoundryRole false' (
    $reuseRoleExisting.Exit -eq 0 -and (Read-ScenarioFile $reuseRoleExisting 'calls.log') -match 'grantFoundryRole=false'
) $reuseRoleExisting.Output

$reuseNoRole = Invoke-GuideBashScenario 'reuse-clean' $reuseApimBlock
Assert 'reuse APIM without Foundry role passes grantFoundryRole true' (
    $reuseNoRole.Exit -eq 0 -and (Read-ScenarioFile $reuseNoRole 'calls.log') -match 'grantFoundryRole=true'
) $reuseNoRole.Output

Assert 'reuse APIM what-if block does not create deployment' (
    $reuseNoRole.Exit -eq 0 -and
    (Read-ScenarioFile $reuseNoRole 'writes.log') -match 'deployment-what-if' -and
    -not ((Read-ScenarioFile $reuseNoRole 'writes.log') -match 'deployment-create')
) $reuseNoRole.Output

$reuseCreate = Invoke-GuideBashScenario 'reuse-clean' ($reuseApimBlock -replace 'p89_deploy_reused_apim whatif', 'p89_deploy_reused_apim create')
Assert 'reuse APIM create argument runs deployment create' (
    $reuseCreate.Exit -eq 0 -and
    (Read-ScenarioFile $reuseCreate 'writes.log') -match 'deployment-create claude-gateway-reuse'
) $reuseCreate.Output

$reuseBadArg = Invoke-GuideBashScenario 'reuse-clean' ($reuseApimBlock -replace 'p89_deploy_reused_apim whatif', 'p89_deploy_reused_apim bad')
Assert 'reuse APIM bad argument refuses without deployment call' (
    $reuseBadArg.Exit -ne 0 -and
    $reuseBadArg.Output -match "pass 'whatif' or 'create'" -and
    -not ((Read-ScenarioFile $reuseBadArg 'writes.log') -match 'deployment-')
) $reuseBadArg.Output

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

$identityNullRead = Invoke-GuideBashScenario 'identity-null' (Join-GuideBlocks @($identityBlock, $roleBlock))
Assert 'missing APIM identity refuses before role list or create' (
    $identityNullRead.Exit -ne 0 -and
    $identityNullRead.Output -match 'no Foundry role check ran' -and
    -not ((Read-ScenarioFile $identityNullRead 'calls.log') -match 'role assignment list --scope .* --assignee  ') -and
    -not ((Read-ScenarioFile $identityNullRead 'calls.log') -match 'role assignment create')
) $identityNullRead.Output

$identityNullStderr = Invoke-GuideBashScenario 'identity-null' (($identityBlock -replace 'p89_gateway_identity\s*$', 'p89_gateway_identity >stdout.txt 2>stderr.txt'))
$identityNullStderrLines = @((Read-ScenarioFile $identityNullStderr 'stderr.txt') -split "`r?`n" | Where-Object { $_ })
Assert 'missing APIM identity refusal emits exactly one stderr line' (
    $identityNullStderr.Exit -ne 0 -and
    $identityNullStderrLines.Count -eq 1 -and
    $identityNullStderrLines[0] -match 'no Foundry role check ran'
) "stderr=$($identityNullStderrLines -join ' | ') output=$($identityNullStderr.Output)"

$identityUserAssigned = Invoke-GuideBashScenario 'identity-userassigned' (Join-GuideBlocks @($enableIdentityBlock, $identityBlock))
Assert 'UserAssigned-only APIM identity refuses without PATCH' (
    $identityUserAssigned.Exit -ne 0 -and
    $identityUserAssigned.Output -match 'UserAssigned' -and
    -not ((Read-ScenarioFile $identityUserAssigned 'writes.log') -match 'rest-patch')
) $identityUserAssigned.Output

$identityPatch = Invoke-GuideBashScenario 'identity-patch' (Join-GuideBlocks @($enableIdentityBlock, $identityBlock))
Assert 'missing APIM identity can be enabled with one PATCH then principal appears' (
    $identityPatch.Exit -eq 0 -and
    @((Read-ScenarioFile $identityPatch 'writes.log') -split "`n" | Where-Object { $_ -match 'rest-patch .*"identity":\{"type":"SystemAssigned"\}' }).Count -eq 1 -and
    $identityPatch.Output -match 'gateway-object-id'
) $identityPatch.Output

$identityTimeout = Invoke-GuideBashScenario 'identity-timeout' ("export IDENTITY_WAIT_ATTEMPTS=2; export IDENTITY_WAIT_DELAY_SECONDS=0; " + $enableIdentityBlock)
Assert 'identity enable bounded wait refuses when principal never appears' (
    $identityTimeout.Exit -ne 0 -and
    $identityTimeout.Output -match 'principalId did not appear' -and
    (Read-ScenarioFile $identityTimeout 'writes.log') -match 'rest-patch'
) $identityTimeout.Output

$roleCreateFail = Invoke-GuideBashScenario 'role-create-fail' (Join-GuideBlocks @($identityBlock, $roleBlock))
Assert 'failing role create refuses and leaves no receipt' (
    $roleCreateFail.Exit -ne 0 -and
    $roleCreateFail.Output -match 'role assignment create failed' -and
    -not (Read-ScenarioFile $roleCreateFail '.p89-receipts/foundry-role.json')
) $roleCreateFail.Output

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

$redirectExtra = Invoke-GuideBashScenario 'redirect-extra' $desktopRedirectsBlock
Assert 'discovered app redirect update preserves extra URI' (
    $redirectExtra.Exit -eq 0 -and
    (Read-ScenarioFile $redirectExtra 'calls.log') -match 'https://existing.example/callback' -and
    (Read-ScenarioFile $redirectExtra 'calls.log') -match 'http://127.0.0.1/callback'
) $redirectExtra.Output

$redirectBrowser = Invoke-GuideBashScenario 'redirect-extra' ("export DESKTOP_SIGN_IN_FLOW=browser; " + $desktopRedirectsBlock)
Assert 'browser Desktop flow adds no broker URIs' (
    $redirectBrowser.Exit -eq 0 -and
    -not ((Read-ScenarioFile $redirectBrowser 'calls.log') -match 'ms-appx-web|msauth.com.anthropic')
) $redirectBrowser.Output

$redirectBroker = Invoke-GuideBashScenario 'redirect-extra' ("export DESKTOP_SIGN_IN_FLOW=broker; " + $desktopRedirectsBlock)
Assert 'broker Desktop flow adds broker redirect URIs' (
    $redirectBroker.Exit -eq 0 -and
    (Read-ScenarioFile $redirectBroker 'calls.log') -match 'ms-appx-web://Microsoft.AAD.BrokerPlugin/66666666-6666-6666-6666-666666666666' -and
    (Read-ScenarioFile $redirectBroker 'calls.log') -match 'msauth.com.anthropic.claudefordesktop://auth'
) $redirectBroker.Output

$redirectPlaceholder = Invoke-GuideBashScenario 'redirect-extra' ("export DESKTOP_CLIENT_ID='<desktop-public-client-app-id>'; " + $desktopRedirectsBlock)
Assert 'empty or placeholder Desktop client id refuses with no update' (
    $redirectPlaceholder.Exit -ne 0 -and
    $redirectPlaceholder.Output -match 'DESKTOP_CLIENT_ID' -and
    -not ((Read-ScenarioFile $redirectPlaceholder 'calls.log') -match 'ad app update')
) $redirectPlaceholder.Output

$redirectMissingUri = Invoke-GuideBashScenario 'redirect-missing-uri' ("export DESKTOP_SIGN_IN_FLOW=broker; " + $desktopRedirectsBlock)
Assert 'Desktop redirect read-back missing required URI refuses' (
    $redirectMissingUri.Exit -ne 0 -and
    $redirectMissingUri.Output -match 'read-back' -and
    (Read-ScenarioFile $redirectMissingUri 'calls.log') -match 'ad app update'
) $redirectMissingUri.Output

$redirectFallbackFalse = Invoke-GuideBashScenario 'redirect-fallback-false' ("export DESKTOP_SIGN_IN_FLOW=broker; " + $desktopRedirectsBlock)
Assert 'Desktop redirect read-back fallback false refuses' (
    $redirectFallbackFalse.Exit -ne 0 -and
    $redirectFallbackFalse.Output -match 'isFallbackPublicClient'
) $redirectFallbackFalse.Output

$gatewayUrlDefault = Invoke-GuideBashScenario 'gateway-url-default' $gatewayUrlBlock
Assert 'gateway URL helper uses live APIM gatewayUrl and SKU' (
    $gatewayUrlDefault.Exit -eq 0 -and
    $gatewayUrlDefault.Output -match 'https://apim.azure-api.net/claude'
) $gatewayUrlDefault.Output

$gatewayUrlAddress = Invoke-GuideBashScenario 'gateway-address' ("mkdir -p .p89-receipts; printf '%s\n' '{""address"":{""hostname"":""custom.example""}}' > .p89-receipts/gateway-address.json; " + $gatewayUrlBlock)
Assert 'gateway URL helper prefers verified company address receipt when live hostname remains' (
    $gatewayUrlAddress.Exit -eq 0 -and
    $gatewayUrlAddress.Output -match 'https://custom.example/claude'
) $gatewayUrlAddress.Output

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

$budgetUserFail = Invoke-GuideBashScenario 'budget-user-fail' $budgetBlock
Assert 'budget write block refuses failed developer id read before write' (
    $budgetUserFail.Exit -ne 0 -and
    $budgetUserFail.Output -match 'could not read developer object id' -and
    -not ((Read-ScenarioFile $budgetUserFail 'writes.log') -match 'quota-overrides=')
) $budgetUserFail.Output

$budgetUserBad = Invoke-GuideBashScenario 'budget-user-bad' $budgetBlock
Assert 'budget write block refuses non-GUID developer id before write' (
    $budgetUserBad.Exit -ne 0 -and
    $budgetUserBad.Output -match 'not a GUID' -and
    -not ((Read-ScenarioFile $budgetUserBad 'writes.log') -match 'quota-overrides=')
) $budgetUserBad.Output

$addModel = Invoke-GuideBashScenario 'add-model' $addModelBlock
Assert 'add model block preserves existing premium models' (
    $addModel.Exit -eq 0 -and
    (Read-ScenarioFile $addModel 'writes.log') -match 'models-premium=,claude-sonnet-5,<deployment-name>,'
) $addModel.Output

$addModelReadFail = Invoke-GuideBashScenario 'models-premium-read-fail' $addModelBlock
Assert 'add model block refuses failed models-premium read before write' (
    $addModelReadFail.Exit -ne 0 -and
    $addModelReadFail.Output -match 'could not read models-premium' -and
    -not ((Read-ScenarioFile $addModelReadFail 'writes.log') -match 'models-premium=')
) $addModelReadFail.Output

$addModelMalformed = Invoke-GuideBashScenario 'models-premium-malformed' $addModelBlock
Assert 'add model block refuses malformed models-premium before write' (
    $addModelMalformed.Exit -ne 0 -and
    $addModelMalformed.Output -match 'comma-sentinel' -and
    -not ((Read-ScenarioFile $addModelMalformed 'writes.log') -match 'models-premium=')
) $addModelMalformed.Output

$handover = Invoke-GuideBashScenario 'handover' (Join-GuideBlocks @($gatewayUrlBlock, $handoverBlock))
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

$kvShowFail = Invoke-GuideBashScenario 'keyvault-show-fail' $keyVaultBlock
Assert 'Key Vault certificate read failure refuses without subscription-scope role create' (
    $kvShowFail.Exit -ne 0 -and
    -not ((Read-ScenarioFile $kvShowFail 'calls.log') -match 'role assignment create') -and
    -not ((Read-ScenarioFile $kvShowFail 'calls.log') -match '--scope ""')
) $kvShowFail.Output

$kvCreated = Invoke-GuideBashScenario 'keyvault-new' $keyVaultBlock
Assert 'RBAC Key Vault without assignment creates exact-vault-scope receipt' (
    $kvCreated.Exit -eq 0 -and
    (Read-ScenarioFile $kvCreated 'calls.log') -match 'role assignment create .*--scope /subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv' -and
    (Read-ScenarioFile $kvCreated '.p89-receipts/keyvault-role.json' | ConvertFrom-Json).keyVaultRole.created -eq $true -and
    (Read-ScenarioFile $kvCreated '.p89-receipts/keyvault-role.json' | ConvertFrom-Json).keyVaultRole.scope -eq '/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv' -and
    (Read-ScenarioFile $kvCreated '.p89-receipts/keyvault-role.json' | ConvertFrom-Json).keyVaultRole.principalId -eq 'gateway-object-id'
) $kvCreated.Output

$kvExisting = Invoke-GuideBashScenario 'keyvault-existing' $keyVaultBlock
Assert 'RBAC Key Vault existing assignment records created false with no create' (
    $kvExisting.Exit -eq 0 -and
    -not ((Read-ScenarioFile $kvExisting 'calls.log') -match 'role assignment create') -and
    (Read-ScenarioFile $kvExisting '.p89-receipts/keyvault-role.json' | ConvertFrom-Json).keyVaultRole.created -eq $false
) $kvExisting.Output

$kvPolicy = Invoke-GuideBashScenario 'keyvault-access-policy' $keyVaultBlock
Assert 'access-policy Key Vault refuses and writes nothing' (
    $kvPolicy.Exit -ne 0 -and
    $kvPolicy.Output -match 'Access policies' -and
    -not ((Read-ScenarioFile $kvPolicy 'writes.log') -match 'kv-created-role-id')
) $kvPolicy.Output

$hostnamePremium = Invoke-GuideBashScenario 'hostname-premium' $bindHostnameBlock
$hostnamePremiumBody = Read-ScenarioFile $hostnamePremium 'hostname-patch.json'
Assert 'Premium hostname patch preserves existing hostnames and appends new binding' (
    $hostnamePremium.Exit -eq 0 -and
    $hostnamePremiumBody -match 'other.example' -and
    $hostnamePremiumBody -match 'portal.example' -and
    $hostnamePremiumBody -match 'new.example'
) $hostnamePremium.Output

$hostnameStandardRefuse = Invoke-GuideBashScenario 'hostname-standard-refuse' $bindHostnameBlock
Assert 'StandardV2 with another custom Proxy hostname refuses without patch' (
    $hostnameStandardRefuse.Exit -ne 0 -and
    $hostnameStandardRefuse.Output -match 'another custom Proxy hostname' -and
    -not ((Read-ScenarioFile $hostnameStandardRefuse 'writes.log') -match 'rest-patch-body')
) $hostnameStandardRefuse.Output

$hostnameReplace = Invoke-GuideBashScenario 'hostname-standard-refuse' ("export REPLACE_HOSTNAME=other.example; " + $bindHostnameBlock)
$hostnameReplaceBody = Read-ScenarioFile $hostnameReplace 'hostname-patch.json'
Assert 'REPLACE_HOSTNAME drops only the named Proxy hostname' (
    $hostnameReplace.Exit -eq 0 -and
    $hostnameReplaceBody -notmatch 'other.example' -and
    $hostnameReplaceBody -match 'portal.example' -and
    $hostnameReplaceBody -match 'new.example'
) $hostnameReplace.Output

$hostnameUnset = Invoke-GuideBashScenario 'hostname-premium' ("unset GATEWAY_HOSTNAME; " + $bindHostnameBlock)
Assert 'unset GATEWAY_HOSTNAME refuses instead of using bash HOSTNAME' (
    $hostnameUnset.Exit -ne 0 -and
    $hostnameUnset.Output -match 'GATEWAY_HOSTNAME is empty'
) $hostnameUnset.Output

$hostnameNotSucceeded = Invoke-GuideBashScenario 'hostname-not-succeeded' $bindHostnameBlock
Assert 'hostname bind refuses non-Succeeded APIM before patch' (
    $hostnameNotSucceeded.Exit -ne 0 -and
    $hostnameNotSucceeded.Output -match "provisioningState is 'Updating'" -and
    -not ((Read-ScenarioFile $hostnameNotSucceeded 'calls.log') -match 'rest --method patch')
) $hostnameNotSucceeded.Output

$hostnameWrongCname = Invoke-GuideBashScenario 'hostname-wrong-cname' ("export P89_DNS_TIMEOUT_SECONDS=1; " + $bindHostnameBlock)
Assert 'hostname bind refuses missing or wrong CNAME before patch' (
    $hostnameWrongCname.Exit -ne 0 -and
    $hostnameWrongCname.Output -match "does not point to 'apim.azure-api.net'" -and
    -not ((Read-ScenarioFile $hostnameWrongCname 'writes.log') -match 'rest-patch-body')
) $hostnameWrongCname.Output

$hostnameDnsSecond = Invoke-GuideBashScenario 'hostname-dns-second' ("export P89_DNS_TIMEOUT_SECONDS=5; " + $bindHostnameBlock)
Assert 'hostname bind waits for DNS CNAME to appear on second poll' (
    $hostnameDnsSecond.Exit -eq 0 -and
    $hostnameDnsSecond.Output -match 'new.example' -and
    (Read-ScenarioFile $hostnameDnsSecond 'dns-count') -match '2'
) $hostnameDnsSecond.Output

$hostnameDnsNever = Invoke-GuideBashScenario 'hostname-dns-never' ("export P89_DNS_TIMEOUT_SECONDS=1; " + $bindHostnameBlock)
Assert 'hostname bind refuses when DNS CNAME never points to gateway' (
    $hostnameDnsNever.Exit -ne 0 -and
    $hostnameDnsNever.Output -match "does not point to 'apim.azure-api.net'" -and
    -not ((Read-ScenarioFile $hostnameDnsNever 'calls.log') -match 'rest --method patch')
) $hostnameDnsNever.Output

$hostnameNoDig = Invoke-GuideBashScenario 'hostname-no-dig' ("rm -f dig; " + $bindHostnameBlock)
Assert 'hostname bind refuses immediately when dig is absent' (
    $hostnameNoDig.Exit -ne 0 -and
    $hostnameNoDig.Output -match 'Cloud Shell.*dig.*preinstalled' -and
    -not ((Read-ScenarioFile $hostnameNoDig 'calls.log') -match 'rest --method patch')
) $hostnameNoDig.Output

$hostnamePreserveClientCert = Invoke-GuideBashScenario 'hostname-preserve-clientcert' $bindHostnameBlock
$hostnamePreserveBody = Read-ScenarioFile $hostnamePreserveClientCert 'hostname-patch.json'
Assert 'hostname bind preserves existing negotiateClientCertificate true in patch' (
    $hostnamePreserveClientCert.Exit -eq 0 -and
    $hostnamePreserveBody -match '"hostName"\s*:\s*"new.example"' -and
    $hostnamePreserveBody -match '"negotiateClientCertificate"\s*:\s*true'
) $hostnamePreserveClientCert.Output

$hostnameKvRetry = Invoke-GuideBashScenario 'hostname-kv-retry' $bindHostnameBlock
Assert 'hostname bind retries Key Vault propagation error then succeeds' (
    $hostnameKvRetry.Exit -eq 0 -and
    @((Read-ScenarioFile $hostnameKvRetry 'writes.log') -split "`n" | Where-Object { $_ -match 'rest-patch-command' }).Count -ge 2 -and
    $hostnameKvRetry.Output -match 'new.example'
) $hostnameKvRetry.Output

$hostnamePatchOtherError = Invoke-GuideBashScenario 'hostname-patch-other-error' $bindHostnameBlock
Assert 'hostname bind refuses non-Key Vault patch error at once' (
    $hostnamePatchOtherError.Exit -ne 0 -and
    @((Read-ScenarioFile $hostnamePatchOtherError 'writes.log') -split "`n" | Where-Object { $_ -match 'rest-patch-command' }).Count -eq 1 -and
    $hostnamePatchOtherError.Output -match 'BadRequest unrelated'
) $hostnamePatchOtherError.Output

$hostnameUpdatingThenSucceeded = Invoke-GuideBashScenario 'hostname-updating-then-succeeded' ("export P89_HOSTNAME_TIMEOUT_SECONDS=5; " + $bindHostnameBlock)
Assert 'hostname bind waits through Updating then Succeeded' (
    $hostnameUpdatingThenSucceeded.Exit -eq 0 -and
    $hostnameUpdatingThenSucceeded.Output -match 'new.example'
) $hostnameUpdatingThenSucceeded.Output

$hostnameFailed = Invoke-GuideBashScenario 'hostname-failed' $bindHostnameBlock
Assert 'hostname bind refuses Failed provisioning state after patch' (
    $hostnameFailed.Exit -ne 0 -and
    $hostnameFailed.Output -match "update state is 'Failed'" -and
    $hostnameFailed.Output -notmatch 'did not finish' -and
    -not (Read-ScenarioFile $hostnameFailed '.p89-receipts/gateway-address.json')
) $hostnameFailed.Output

$hostnameCanceled = Invoke-GuideBashScenario 'hostname-canceled' $bindHostnameBlock
Assert 'hostname bind refuses Canceled provisioning state after patch' (
    $hostnameCanceled.Exit -ne 0 -and
    $hostnameCanceled.Output -match "update state is 'Canceled'" -and
    $hostnameCanceled.Output -notmatch 'did not finish' -and
    -not (Read-ScenarioFile $hostnameCanceled '.p89-receipts/gateway-address.json')
) $hostnameCanceled.Output

$hostnameCertFailed = Invoke-GuideBashScenario 'hostname-cert-failed' $bindHostnameBlock
Assert 'hostname bind refuses Failed certificateStatus after patch' (
    $hostnameCertFailed.Exit -ne 0 -and
    $hostnameCertFailed.Output -match "certificateStatus is 'Failed'" -and
    $hostnameCertFailed.Output -notmatch 'did not finish' -and
    -not (Read-ScenarioFile $hostnameCertFailed '.p89-receipts/gateway-address.json')
) $hostnameCertFailed.Output

$hostnameCertTimeout = Invoke-GuideBashScenario 'hostname-cert-timeout' $bindHostnameBlock
Assert 'hostname bind refuses certificateStatus InProgress timeout' (
    $hostnameCertTimeout.Exit -ne 0 -and
    $hostnameCertTimeout.Output -match 'InProgress'
) $hostnameCertTimeout.Output

$hostnameEmptyStatus = Invoke-GuideBashScenario 'hostname-empty-certstatus' $bindHostnameBlock
Assert 'hostname bind treats empty certificateStatus with existing binding as success' (
    $hostnameEmptyStatus.Exit -eq 0 -and
    $hostnameEmptyStatus.Output -match 'new.example'
) $hostnameEmptyStatus.Output

$hostnameNoBinding = Invoke-GuideBashScenario 'hostname-no-binding' $bindHostnameBlock
Assert 'hostname bind refuses when Succeeded never has the Proxy binding' (
    $hostnameNoBinding.Exit -ne 0 -and
    $hostnameNoBinding.Output -match 'did not finish' -and
    -not (Read-ScenarioFile $hostnameNoBinding '.p89-receipts/gateway-address.json')
) $hostnameNoBinding.Output

$hostnameNon401 = Invoke-GuideBashScenario 'hostname-non401' $bindHostnameBlock
Assert 'hostname bind non-401 proof refuses with no receipt' (
    $hostnameNon401.Exit -ne 0 -and
    $hostnameNon401.Output -match 'not 401' -and
    -not (Read-ScenarioFile $hostnameNon401 '.p89-receipts/gateway-address.json')
) $hostnameNon401.Output

$hostnameSuccess = Invoke-GuideBashScenario 'hostname-success' (Join-GuideBlocks @($bindHostnameBlock, $gatewayUrlBlock))
Assert 'hostname bind success writes receipt and gateway URL uses hostname' (
    $hostnameSuccess.Exit -eq 0 -and
    (Read-ScenarioFile $hostnameSuccess '.p89-receipts/gateway-address.json') -match '"hostname": "new.example"' -and
    $hostnameSuccess.Output -match 'https://new.example/claude'
) $hostnameSuccess.Output

$hostnameNoReceiptDir = Invoke-GuideBashScenario 'hostname-success' ("rm -rf .p89-receipts; " + $bindHostnameBlock)
Assert 'hostname bind creates receipt directory before writing address receipt' (
    $hostnameNoReceiptDir.Exit -eq 0 -and
    (Read-ScenarioFile $hostnameNoReceiptDir '.p89-receipts/gateway-address.json') -match '"hostname": "new.example"'
) $hostnameNoReceiptDir.Output

$projectionDeploy = Invoke-GuideBashScenario 'projection-deploy' $projectionDeployBlock
$projectionDeployWrites = Read-ScenarioFile $projectionDeploy 'writes.log'
Assert 'projection deployment block deploys store before network' (
    $projectionDeploy.Exit -eq 0 -and
    $projectionDeployWrites.IndexOf('deployment-create projection-prefix') -ge 0 -and
    $projectionDeployWrites.IndexOf('deployment-create projection-network-prefix') -gt $projectionDeployWrites.IndexOf('deployment-create projection-prefix')
) $projectionDeploy.Output

$projectionCosmosEmpty = Invoke-GuideBashScenario 'projection-cosmos-empty' $projectionDeployBlock
Assert 'projection deployment refuses empty Cosmos account output before network deploy' (
    $projectionCosmosEmpty.Exit -ne 0 -and
    $projectionCosmosEmpty.Output -match 'Cosmos account output' -and
    -not ((Read-ScenarioFile $projectionCosmosEmpty 'writes.log') -match 'projection-network-prefix')
) $projectionCosmosEmpty.Output

$resolverDeploy = Invoke-GuideBashScenario 'resolver-deploy' (Join-GuideBlocks @($projectionDeployBlock, $resolverDeployBlock))
$resolverParams = Read-ScenarioFile $resolverDeploy 'resolver-params.json'
Assert 'resolver deployment block allows the gateway managed identity app and object ids' (
    $resolverDeploy.Exit -eq 0 -and
    ($resolverParams | ConvertFrom-Json).parameters.allowedCallerAppIds.value[0] -ceq 'gateway-app-id' -and
    ($resolverParams | ConvertFrom-Json).parameters.allowedCallerObjectIds.value[0] -ceq 'gateway-object-id'
) $resolverDeploy.Output

$resolverGatewayAppFail = Invoke-GuideBashScenario 'resolver-gateway-app-fail' (Join-GuideBlocks @($projectionDeployBlock, $resolverDeployBlock))
Assert 'resolver deployment refuses failed gateway app id read before deployment' (
    $resolverGatewayAppFail.Exit -ne 0 -and
    $resolverGatewayAppFail.Output -match 'gateway managed identity app id' -and
    -not ((Read-ScenarioFile $resolverGatewayAppFail 'writes.log') -match 'projection-resolver-prefix')
) $resolverGatewayAppFail.Output

$resolverNetworkMissing = Invoke-GuideBashScenario 'resolver-network-missing' (Join-GuideBlocks @($projectionDeployBlock, $resolverDeployBlock))
Assert 'resolver deployment refuses missing network output fields before deployment' (
    $resolverNetworkMissing.Exit -ne 0 -and
    $resolverNetworkMissing.Output -match 'network outputs are missing' -and
    -not ((Read-ScenarioFile $resolverNetworkMissing 'writes.log') -match 'projection-resolver-prefix')
) $resolverNetworkMissing.Output

$resolverJqFail = Invoke-GuideBashScenario 'resolver-jq-fail' (Join-GuideBlocks @($projectionDeployBlock, "printf '%s\n' stale > resolver-params.json; jq() { if [ `"`${1:-}`" = -n ]; then return 3; fi; command jq `"`$@`"; }", $resolverDeployBlock))
Assert 'resolver deployment removes stale params and refuses jq generation failure before deployment' (
    $resolverJqFail.Exit -ne 0 -and
    $resolverJqFail.Output -match 'resolver parameters could not be generated' -and
    -not (Read-ScenarioFile $resolverJqFail 'resolver-params.json') -and
    -not ((Read-ScenarioFile $resolverJqFail 'writes.log') -match 'projection-resolver-prefix')
) $resolverJqFail.Output

$resolverSiteEmpty = Invoke-GuideBashScenario 'resolver-site-empty' (Join-GuideBlocks @($projectionDeployBlock, $resolverDeployBlock))
Assert 'resolver deployment refuses empty resolver site output before code upload' (
    $resolverSiteEmpty.Exit -ne 0 -and
    $resolverSiteEmpty.Output -match 'resolver site name output' -and
    -not ((Read-ScenarioFile $resolverSiteEmpty 'writes.log') -match 'functionapp deployment')
) $resolverSiteEmpty.Output

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

$runnerInitFail = Invoke-GuideBashScenario 'runner-init-fail' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner failed init stops before apply and compare' (
    $runnerInitFail.Exit -ne 0 -and
    $runnerInitFail.Output -match 'could not initialize transfer' -and
    -not ((Read-ScenarioFile $runnerInitFail 'writes.log') -match 'appendFileSync|Buffer\.from|tar -x|npm --prefix|apply-projection\.mjs')
) $runnerInitFail.Output

$runnerInitErrorText = Invoke-GuideBashScenario 'runner-init-error-text' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner init error text with exit zero stops before chunk and finalization' (
    $runnerInitErrorText.Exit -ne 0 -and
    $runnerInitErrorText.Output -match 'runner initialization reported an error' -and
    -not ((Read-ScenarioFile $runnerInitErrorText 'writes.log') -match 'appendFileSync|Buffer\.from|tar -x|npm --prefix|apply-projection\.mjs')
) $runnerInitErrorText.Output

$runnerHashMismatch = Invoke-GuideBashScenario 'runner-hash-mismatch' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner hash mismatch stops before apply and compare' (
    $runnerHashMismatch.Exit -ne 0 -and
    $runnerHashMismatch.Output -match 'Refused: runner transfer hash mismatch' -and
    -not ((Read-ScenarioFile $runnerHashMismatch 'writes.log') -match 'apply-projection\.mjs')
) $runnerHashMismatch.Output

$runnerFinalizeFail = Invoke-GuideBashScenario 'runner-finalize-fail' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner failed finalization stops before apply and compare' (
    $runnerFinalizeFail.Exit -ne 0 -and
    $runnerFinalizeFail.Output -match 'could not finalize transfer' -and
    $runnerFinalizeFail.Output -notmatch 'hash mismatch' -and
    -not ((Read-ScenarioFile $runnerFinalizeFail 'writes.log') -match 'tar -x|npm --prefix|apply-projection\.mjs')
) $runnerFinalizeFail.Output

$runnerFinalizeErrorText = Invoke-GuideBashScenario 'runner-finalize-error-text' (Join-GuideBlocks @($projectionDeployBlock, $projectionRunnerBlock))
Assert 'runner finalization error text with exit zero stops before apply and compare' (
    $runnerFinalizeErrorText.Exit -ne 0 -and
    $runnerFinalizeErrorText.Output -match 'runner finalization reported an error' -and
    -not ((Read-ScenarioFile $runnerFinalizeErrorText 'writes.log') -match 'tar -x|npm --prefix|apply-projection\.mjs')
) $runnerFinalizeErrorText.Output

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

$modelReadFail = Invoke-GuideBashScenario 'model-read-fail' $modelRefusalBlock
Assert 'model refusal failed read refuses with no write' (
    $modelReadFail.Exit -ne 0 -and
    $modelReadFail.Output -match 'could not read models-standard' -and
    -not ((Read-ScenarioFile $modelReadFail 'writes.log') -match 'models-standard=')
) $modelReadFail.Output

$modelReadEmpty = Invoke-GuideBashScenario 'model-read-empty' $modelRefusalBlock
Assert 'model refusal empty read refuses with no write' (
    $modelReadEmpty.Exit -ne 0 -and
    $modelReadEmpty.Output -match 'could not read models-standard' -and
    -not ((Read-ScenarioFile $modelReadEmpty 'writes.log') -match 'models-standard=')
) $modelReadEmpty.Output

$modelCurlFail = Invoke-GuideBashScenario 'model-curl-fail' $modelRefusalBlock
Assert 'model refusal restores models-standard when curl fails' (
    $modelCurlFail.Exit -eq 0 -and
    @((Read-ScenarioFile $modelCurlFail 'writes.log') -split "`n" | Where-Object { $_ -match 'models-standard=' }).Count -ge 2
) $modelCurlFail.Output

$modelRestoreMismatch = Invoke-GuideBashScenario 'model-restore-mismatch' $modelRefusalBlock
Assert 'model refusal restore read-back mismatch refuses and prints restore value' (
    $modelRestoreMismatch.Exit -ne 0 -and
    $modelRestoreMismatch.Output -match 'Restore this value manually: ,claude-sonnet-5,claude-opus-5,'
) $modelRestoreMismatch.Output

$allCreatedReceipts = "mkdir -p .p89-receipts; printf '%s\n' '{""foundryRole"":{""created"":true,""id"":""created-role-id"",""scope"":""/subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry"",""roleDefinitionName"":""Cognitive Services User"",""principalId"":""gateway-object-id""}}' > .p89-receipts/foundry-role.json; printf '%s\n' '{""group"":{""created"":true,""id"":""standard-id"",""displayName"":""claude-code-standard"",""createdAt"":""2020-01-01T00:00:00Z""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":true,""id"":""premium-id"",""displayName"":""claude-code-premium"",""createdAt"":""2020-01-01T00:00:00Z""}}' > .p89-receipts/group-premium.json; printf '%s\n' '{""app"":{""created"":true,""appId"":""created-app-id"",""objectId"":""created-object-id"",""displayName"":""Claude Desktop gateway""}}' > .p89-receipts/desktop-app.json;"
$keyVaultCreatedReceipt = "printf '%s\n' '{""keyVaultRole"":{""created"":true,""id"":""kv-created-role-id"",""scope"":""/subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv"",""roleDefinitionName"":""Key Vault Secrets User"",""principalId"":""gateway-object-id""}}' > .p89-receipts/keyvault-role.json;"
$allExistingReceipts = "mkdir -p .p89-receipts; printf '%s\n' '{""foundryRole"":{""created"":false,""existingId"":""existing-role-id""}}' > .p89-receipts/foundry-role.json; printf '%s\n' '{""group"":{""created"":false,""id"":""standard-id""}}' > .p89-receipts/group-standard.json; printf '%s\n' '{""group"":{""created"":false,""id"":""premium-id""}}' > .p89-receipts/group-premium.json; printf '%s\n' '{""app"":{""created"":false,""appId"":""existing-app-id""}}' > .p89-receipts/desktop-app.json;"

$teardownCreated = Invoke-GuideBashScenario 'teardown-created' (Join-GuideBlocks @($allCreatedReceipts, $teardownExternalBlock))
Assert 'teardown deletes only receipt-created role assignment' (
    $teardownCreated.Exit -eq 0 -and
    (Read-ScenarioFile $teardownCreated 'calls.log') -match 'role assignment list --scope /subscriptions/sub/resourceGroups/rg/providers/Microsoft.CognitiveServices/accounts/foundry' -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-role created-role-id'
) $teardownCreated.Output
Assert 'teardown deletes receipt-created groups and app' (
    $teardownCreated.Exit -eq 0 -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-group standard-id' -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-group premium-id' -and
    (Read-ScenarioFile $teardownCreated 'writes.log') -match 'delete-app created-app-id'
) $teardownCreated.Output

$teardownRoleMismatch = Invoke-GuideBashScenario 'teardown-role-live-mismatch' (Join-GuideBlocks @($allCreatedReceipts, $teardownExternalBlock))
Assert 'teardown skips role delete when live role differs from receipt and continues' (
    $teardownRoleMismatch.Exit -eq 0 -and
    $teardownRoleMismatch.Output -match 'live Foundry role assignment does not match' -and
    -not ((Read-ScenarioFile $teardownRoleMismatch 'writes.log') -match 'delete-role created-role-id') -and
    (Read-ScenarioFile $teardownRoleMismatch 'writes.log') -match 'delete-group standard-id'
) $teardownRoleMismatch.Output

foreach ($case in @('id','scope','name','principal')) {
    $scenario = "teardown-role-$case-mismatch"
    $run = Invoke-GuideBashScenario $scenario (Join-GuideBlocks @($allCreatedReceipts, $teardownExternalBlock))
    Assert "teardown skips role delete when live role $case differs from receipt" (
        $run.Exit -eq 0 -and
        $run.Output -match 'live Foundry role assignment does not match' -and
        -not ((Read-ScenarioFile $run 'writes.log') -match 'delete-role created-role-id') -and
        (Read-ScenarioFile $run 'writes.log') -match 'delete-group standard-id'
    ) $run.Output
}

$teardownGroupMismatch = Invoke-GuideBashScenario 'teardown-group-live-mismatch' (Join-GuideBlocks @($allCreatedReceipts, $teardownExternalBlock))
Assert 'teardown skips group delete when live group differs from receipt and continues' (
    $teardownGroupMismatch.Exit -eq 0 -and
    $teardownGroupMismatch.Output -match 'live group standard does not match' -and
    -not ((Read-ScenarioFile $teardownGroupMismatch 'writes.log') -match 'delete-group standard-id') -and
    (Read-ScenarioFile $teardownGroupMismatch 'writes.log') -match 'delete-group premium-id'
) $teardownGroupMismatch.Output

$teardownAppMismatch = Invoke-GuideBashScenario 'teardown-app-live-mismatch' (Join-GuideBlocks @($allCreatedReceipts, $teardownExternalBlock))
Assert 'teardown skips app delete when live app differs from receipt' (
    $teardownAppMismatch.Exit -eq 0 -and
    $teardownAppMismatch.Output -match 'live Desktop app registration does not match' -and
    -not ((Read-ScenarioFile $teardownAppMismatch 'writes.log') -match 'delete-app created-app-id')
) $teardownAppMismatch.Output

$teardownKvRole = Invoke-GuideBashScenario 'teardown-kv-role' (Join-GuideBlocks @($allCreatedReceipts, $keyVaultCreatedReceipt, $teardownExternalBlock))
Assert 'teardown deletes matching receipt-created Key Vault role assignment' (
    $teardownKvRole.Exit -eq 0 -and
    (Read-ScenarioFile $teardownKvRole 'calls.log') -match 'role assignment list --scope /subscriptions/sub/resourceGroups/kv-rg/providers/Microsoft.KeyVault/vaults/kv' -and
    (Read-ScenarioFile $teardownKvRole 'writes.log') -match 'delete-role kv-created-role-id'
) $teardownKvRole.Output

$teardownKvRoleMismatch = Invoke-GuideBashScenario 'teardown-kv-role-live-mismatch' (Join-GuideBlocks @($allCreatedReceipts, $keyVaultCreatedReceipt, $teardownExternalBlock))
Assert 'teardown skips Key Vault role delete when live role differs from receipt' (
    $teardownKvRoleMismatch.Exit -eq 0 -and
    $teardownKvRoleMismatch.Output -match 'live Key Vault role assignment does not match' -and
    -not ((Read-ScenarioFile $teardownKvRoleMismatch 'writes.log') -match 'delete-role kv-created-role-id')
) $teardownKvRoleMismatch.Output

foreach ($case in @('id','scope','name','principal')) {
    $scenario = "teardown-kv-role-$case-mismatch"
    $run = Invoke-GuideBashScenario $scenario (Join-GuideBlocks @($allCreatedReceipts, $keyVaultCreatedReceipt, $teardownExternalBlock))
    Assert "teardown skips Key Vault role delete when live role $case differs from receipt" (
        $run.Exit -eq 0 -and
        $run.Output -match 'live Key Vault role assignment does not match' -and
        -not ((Read-ScenarioFile $run 'writes.log') -match 'delete-role kv-created-role-id')
    ) $run.Output
}

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

$teardownGroupCreated = Invoke-GuideBashScenario 'teardown-group-created' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":true,""name"":""rg"",""nonce"":""receipt-nonce""}}' > .p89-receipts/resource-group.json; " + $teardownGroupBlock)
Assert 'teardown group deletes only receipt-created resource group' (
    $teardownGroupCreated.Exit -eq 0 -and (Read-ScenarioFile $teardownGroupCreated 'writes.log') -match 'group-delete'
) $teardownGroupCreated.Output

$teardownGroupTagMismatch = Invoke-GuideBashScenario 'teardown-group-tag-mismatch' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":true,""name"":""rg"",""nonce"":""receipt-nonce""}}' > .p89-receipts/resource-group.json; " + $teardownGroupBlock)
Assert 'teardown group refuses mismatched receipt nonce before delete' (
    $teardownGroupTagMismatch.Exit -ne 0 -and
    $teardownGroupTagMismatch.Output -match 'receipt tag does not match' -and
    -not ((Read-ScenarioFile $teardownGroupTagMismatch 'writes.log') -match 'group-delete')
) $teardownGroupTagMismatch.Output

$teardownGroupExisting = Invoke-GuideBashScenario 'teardown-group-existing' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":false,""name"":""rg""}}' > .p89-receipts/resource-group.json; " + $teardownGroupBlock)
Assert 'teardown group refuses pre-existing resource group' (
    $teardownGroupExisting.Exit -ne 0 -and -not ((Read-ScenarioFile $teardownGroupExisting 'writes.log') -match 'group-delete')
) $teardownGroupExisting.Output

$teardownGroupStderr = Invoke-GuideBashScenario 'teardown-group-existing' ("mkdir -p .p89-receipts; printf '%s\n' '{""resourceGroup"":{""created"":false,""name"":""rg""}}' > .p89-receipts/resource-group.json; " + ($teardownGroupBlock -replace 'p89_teardown_group\s*$', 'p89_teardown_group >stdout.txt 2>stderr.txt'))
Assert 'teardown group pre-existing refusal goes to stderr' (
    $teardownGroupStderr.Exit -ne 0 -and
    (Read-ScenarioFile $teardownGroupStderr 'stderr.txt') -match 'resource group was pre-existing' -and
    -not ((Read-ScenarioFile $teardownGroupStderr 'stdout.txt') -match 'resource group was pre-existing')
) $teardownGroupStderr.Output

$bypassEmpty = Invoke-GuideBashScenario 'bypass-empty' ("unset APIM_PRINCIPAL_ID; " + $bypassReadBlock)
Assert 'bypass read with empty APIM principal refuses before role list' (
    $bypassEmpty.Exit -ne 0 -and
    $bypassEmpty.Output -match 'APIM_PRINCIPAL_ID is empty|FOUNDRY_ID or APIM_PRINCIPAL_ID is empty' -and
    -not ((Read-ScenarioFile $bypassEmpty 'calls.log') -match 'role assignment list')
) $bypassEmpty.Output

$teardownReadEmpty = Invoke-GuideBashScenario 'teardown-read-empty' ("unset FOUNDRY_ID; " + $teardownReadBlock)
Assert 'teardown read with empty Foundry id refuses before role list' (
    $teardownReadEmpty.Exit -ne 0 -and
    $teardownReadEmpty.Output -match 'FOUNDRY_ID or APIM_PRINCIPAL_ID is empty' -and
    -not ((Read-ScenarioFile $teardownReadEmpty 'calls.log') -match 'role assignment list')
) $teardownReadEmpty.Output

if ($script:fail) { throw "$script:fail assertion(s) failed." }
