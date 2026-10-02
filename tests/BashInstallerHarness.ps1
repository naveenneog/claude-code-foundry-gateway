# Harness for the bash installer suites (tests/Test-BashInstallerCheckpoint.ps1 and the P92 bash suites), dot-sourced
# after $root is set. Each run is bash from a copy of the files the installer reads, with stub az, curl, pwsh,
# ps and uname first on a PATH; the az stub keeps its state in a JSON world file through jq, so nothing reaches
# Azure. A suite sets $scratch, then calls New-BashTemplate for $template and $psTable.
$script:windows = [bool]($IsWindows -or $env:OS -eq 'Windows_NT')
$bash = $null
if ($script:windows) {
    foreach ($c in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', (Join-Path "$env:LOCALAPPDATA" 'Programs\Git\bin\bash.exe'))) { if (Test-Path -LiteralPath $c) { $bash = $c; break } }
}
else { $bash = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $bash) { Write-Host '  [FAIL] no Git Bash (Windows) or bash (macOS, Linux) on this machine, so no check runs.' -ForegroundColor Red; exit 1 }
$jqPath = "$(@(& $bash -c 'command -v jq' 2>$null) | Select-Object -First 1)".Trim()
if (-not $jqPath) { Write-Host '  [FAIL] jq is not on the bash PATH; the installer needs it.' -ForegroundColor Red; exit 1 }
Write-Host "  $(& $bash -c 'echo bash $BASH_VERSION')" -ForegroundColor DarkGray

function ConvertTo-BashPath([string]$Path) { if ($script:windows) { '/' + ($Path.Replace('\', '/') -replace '^([A-Za-z]):', '$1') } else { $Path } }
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false)) }
function Get-BashKey([string]$Checkout) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-BashPath $Checkout))) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    'install-' + $hash.Substring(0, 16)
}

# ------------------------------------------------------------------ stubs
$azStub = @'
#!/usr/bin/env bash
W="$P91_WORLD"; L="$P91_LOG"
printf '%s\n' "$*" >> "$L/az.log"
case "$*" in *$'\r'*) printf 'UNEXPECTED carriage return in: %s\n' "$*" >> "$L/unexpected.log"; exit 2 ;; esac
argv_() { want="$1"; shift; prev=""; for a in "$@"; do if [ "$prev" = "$want" ]; then printf '%s' "$a"; return 0; fi; prev="$a"; done; return 1; }
upd_() { tmp="$W.tmp.$$"; jq "$@" "$W" > "$tmp" && mv -f "$tmp" "$W"; }
fail_() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
snap_() {
  f=""; for c in "$CLAUDE_GATEWAY_STATE_DIR" "$HOME/.claude-gateway" "$HOME/clouddrive/.claude-gateway"; do
    [ -n "$c" ] && [ -d "$c" ] || continue
    for x in "$c"/install-*.json; do case "$x" in *.tmp-*|*.discarded-*) ;; *) [ -f "$x" ] && f="$x" ;; esac; done
  done
  if [ -n "$f" ]; then cp "$f" "$L/$1.json"; echo "$1 present" >> "$L/snapshots.log"; else echo "$1 none" >> "$L/snapshots.log"; fi
}
n="$(jq -r '.inject.readErrors | length' "$W")"; i=0
while [ "$i" -lt "$n" ]; do
  m="$(jq -r --argjson i "$i" '.inject.readErrors[$i].match' "$W")"
  case "$*" in $m) fail_ "$(jq -r --argjson i "$i" '.inject.readErrors[$i].text' "$W")" 1 ;; esac
  i=$((i + 1))
done
# Signed out: az answers every call that needs an account as az does without one (P92 preflight).
if [ "$(jq -r '.signedOut // false' "$W")" = "true" ]; then
  case "$*" in version*|"bicep version"*) ;; "account list"*) echo '[]'; exit 0 ;; *) fail_ "ERROR: Please run 'az login' to setup account." 1 ;; esac
fi
sel="$(argv_ --subscription "$@" || true)"
if [ -n "$sel" ]; then
  case "$*" in "account set"*) ;; *) jq -e --arg s "$sel" '.subscriptionId == $s or .subscriptionName == $s' "$W" >/dev/null 2>&1 || fail_ "ERROR: Subscription '$sel' not found. Check the spelling and casing and try again." 1 ;; esac
fi
foundry_() { # name rg: the world's Foundry account, or the not-found error az writes
  jq -e --arg n "$1" --arg r "$2" '(.foundry.name // $n) == $n and ($r == "" or (.foundry.rg // $r) == $r)' "$W" >/dev/null 2>&1 ||
    fail_ "ERROR: (ResourceNotFound) The Resource 'Microsoft.CognitiveServices/accounts/$1' under resource group '$2' was not found." 3
}
q="$(argv_ --query "$@" || true)"
complete_() { # rg name
  upd_ --arg r "$1" --arg n "$2" '
    .deployments[$r][$n] as $d | ($d.apim) as $a
    | .apims[$a] = ((.apims[$a] // {rg: $r, sku: "BasicV2", location: "eastus2", identity: "SystemAssigned", apis: []}) | .apis = ((.apis + ["claude-foundry"]) | unique))
    | .deployments[$r][$n].state = "Succeeded"
    | .deployments[$r][$n].outputs = {gatewayUrl: {value: ("https://" + $a + ".azure-api.net/claude")}}'
}
case "$*" in
  version*) echo "2.86.0" ;;
  "bicep version"*) echo "Bicep CLI version 0.47.16 (p91stub)" ;;
  "account list"*) jq -r '.subscriptionId' "$W" ;;
  "account show --query user.name -o tsv") echo "admin@contoso.com" ;;
  "account show --query tenantId -o tsv") jq -r '.tenantId' "$W" ;;
  "account show --query name -o tsv") jq -r '.subscriptionName' "$W" ;;
  "account show --query id -o tsv") jq -r '.subscriptionId' "$W" ;;
  "account show"*) jq -c '{id: .subscriptionId, name: .subscriptionName, tenantId: .tenantId, user: {name: "admin@contoso.com"}}' "$W" ;;
  "account set --subscription "*) exit 0 ;;
  "cognitiveservices account deployment list "*) foundry_ "$(argv_ -n "$@")" "$(argv_ -g "$@")"; jq '.foundry.deployments' "$W" ;;
  "cognitiveservices account show "*)
    foundry_ "$(argv_ -n "$@")" "$(argv_ -g "$@")"
    case "$q" in
      location) jq -r '.foundry.location // "eastus2"' "$W" ;;
      *) jq -c '{name: .foundry.name, resourceGroup: .foundry.rg, location: (.foundry.location // "eastus2"), kind: "AIServices"}' "$W" ;;
    esac ;;
  "cognitiveservices account list"*)
    case "$*" in *"-o tsv"*) jq -r '.foundry.rg' "$W" ;; *) jq -c '[{name: .foundry.name, resourceGroup: .foundry.rg, rg: .foundry.rg, location: (.foundry.location // "eastus2"), loc: (.foundry.location // "eastus2"), kind: "AIServices"}]' "$W" ;; esac ;;
  "apim check-name "*)
    # The service name is a global DNS label (Learn: Api Management Service - Check Name Availability).
    nm="$(argv_ -n "$@")"
    if jq -e --arg n "$nm" '(.apims[$n] != null) or (((.apimNamesTaken // []) | index([$n])) != null)' "$W" >/dev/null 2>&1; then
      printf '{"message":"%s is already in use. Please select a different name.","nameAvailable":false,"reason":"AlreadyExists"}\n' "$nm"
    else printf '{"message":"","nameAvailable":true,"reason":"Valid"}\n'; fi ;;
  "apim list"*)
    jq -c '[.apims | to_entries[] | {name: .key, resourceGroup: .value.rg, location: (.value.location // "eastus2"), publisherEmail: (.value.publisherEmail // "ops@contoso.com"), sku: {name: (.value.sku // "BasicV2"), capacity: 1},
      identity: (if (.value.identity // "SystemAssigned") == "None" then {type: "None"} else {type: (.value.identity // "SystemAssigned"), principalId: "00000000-0000-4000-8000-0000000000c1"} end)}]' "$W" ;;
  "group show "*)
    rg="$(argv_ -n "$@")"; loc="$(jq -r --arg r "$rg" '.resourceGroups[$r] // empty' "$W")"
    [ -n "$loc" ] || fail_ "ERROR: (ResourceGroupNotFound) Resource group '$rg' could not be found." 3
    if [ "$q" = "location" ]; then echo "$loc"; else printf '{"name":"%s","location":"%s"}\n' "$rg" "$loc"; fi ;;
  "group create "*)
    snap_ checkpoint-at-group-create
    rg="$(argv_ -n "$@")"; loc="$(argv_ -l "$@")"
    upd_ --arg r "$rg" --arg l "$loc" '.resourceGroups[$r] = (.resourceGroups[$r] // $l)' ;;
  "apim show "*)
    rg="$(argv_ -g "$@")"; nm="$(argv_ -n "$@")"
    jq -e --arg n "$nm" --arg r "$rg" '.apims[$n] and .apims[$n].rg == $r' "$W" >/dev/null 2>&1 || fail_ "ERROR: (ResourceNotFound) The Resource 'Microsoft.ApiManagement/service/$nm' under resource group '$rg' was not found." 3
    case "$q" in
      name) echo "$nm" ;;
      id) echo "/subscriptions/x/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$nm" ;;
      *) jq -c --arg n "$nm" --arg r "$rg" '.apims[$n] as $a | {name: $n, resourceGroup: $r, location: ($a.location // "eastus2"), publisherEmail: ($a.publisherEmail // "ops@contoso.com"),
           sku: {name: ($a.sku // "BasicV2"), capacity: 1}, identity: (if ($a.identity // "SystemAssigned") == "None" then {type: "None"} else {type: ($a.identity // "SystemAssigned"), principalId: "00000000-0000-4000-8000-0000000000c1"} end)}' "$W" ;;
    esac ;;
  "apim api show "*)
    nm="$(argv_ --service-name "$@")"; api="$(argv_ --api-id "$@")"
    jq -e --arg n "$nm" --arg a "$api" '(.apims[$n].apis // []) | index($a) != null' "$W" >/dev/null 2>&1 || fail_ "ERROR: (ResourceNotFound) Api not found." 3
    printf '{"name":"%s"}\n' "$api" ;;
  "deployment group create "*)
    nm="$(argv_ --name "$@")"; rg="$(argv_ -g "$@")"
    snap_ "checkpoint-at-create-$nm"
    prefix=""; for a in "$@"; do case "$a" in namePrefix=*) prefix="${a#namePrefix=}" ;; esac; done
    mode="$(jq -r '.inject.createMode' "$W")"
    upd_ --arg r "$rg" --arg n "$nm" --arg a "apim-$prefix" '.deployments[$r] = (.deployments[$r] // {}) | .deployments[$r][$n] = {apim: $a, state: "Running", polls: [], error: null}'
    case "$mode" in
      disconnect) upd_ --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].polls = .inject.runningPolls'; echo "^C" >&2; exit 130 ;;
      fail) upd_ --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].state = "Failed" | .deployments[$r][$n].error = {code: "Conflict", message: "The P91 stub failed this deployment."}'
            fail_ "ERROR: {\"code\": \"Conflict\", \"message\": \"The P91 stub failed this deployment.\"}" 1 ;;
      *) complete_ "$rg" "$nm" ;;
    esac ;;
  "deployment group show "*)
    nm="$(argv_ -n "$@")"; rg="$(argv_ -g "$@")"
    st="$(jq -r --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].state // empty' "$W")"
    [ -n "$st" ] || fail_ "ERROR: (DeploymentNotFound) Deployment '$nm' could not be found." 3
    if [ "$st" = "Running" ]; then
      first="$(jq -r --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].polls[0] // empty' "$W")"
      if [ -z "$first" ]; then complete_ "$rg" "$nm"
      elif [ "$first" != "forever" ]; then upd_ --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].polls |= .[1:]'; fi
      st="$(jq -r --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].state' "$W")"
    fi
    case "$q" in
      properties.provisioningState) echo "$st" ;;
      properties.outputs.gatewayUrl.value) jq -r --arg r "$rg" --arg n "$nm" '.deployments[$r][$n].outputs.gatewayUrl.value // empty' "$W" ;;
      *) jq -c --arg r "$rg" --arg n "$nm" '{name: $n, properties: {provisioningState: .deployments[$r][$n].state, outputs: .deployments[$r][$n].outputs, error: .deployments[$r][$n].error}}' "$W" ;;
    esac ;;
  "deployment group list "*)
    rg="$(argv_ -g "$@")"
    jq -c --arg r "$rg" '[(.deployments[$r] // {}) | to_entries[] | {name: .key, properties: {provisioningState: .value.state}}]' "$W" ;;
  "deployment operation group list "*)
    nm="$(argv_ -n "$@")"; rg="$(argv_ -g "$@")"
    jq -c --arg r "$rg" --arg n "$nm" '[.deployments[$r][$n] | select(.error != null) | {properties: {provisioningState: "Failed", statusMessage: {error: .error}}}]' "$W" ;;
  "ad group list "*)
    # --display-name is a prefix ("Object's display name or its prefix", az ad group list --help), and
    # --filter "id eq '<id>'" keeps that id only (az joins both with and, role/custom.py:1898-1905).
    # inject.groupLists holds Graph's answer for a name, as a scenario states it; the name reaches jq
    # on standard input, so no command-line encoding touches it.
    g="$(argv_ --display-name "$@")"
    fid="$(argv_ --filter "$@" | sed -n "s/^id eq '\([0-9a-fA-F-]*\)'\$/\1/p")"
    given="$( { printf '%s' "$g" | jq -Rs .; cat "$W"; } | jq -s -c '.[0] as $g | (.[1].inject.groupLists // {})[$g] // empty')"
    if [ -z "$given" ]; then given="$(jq -c --arg g "$g" '[.groups | to_entries[] | select((.value | ascii_downcase) | startswith($g | ascii_downcase)) | {id: .key, displayName: .value}]' "$W")"; fi
    if [ -n "$fid" ]; then printf '%s' "$given" | jq -c --arg i "$fid" '[.[] | select(.id == $i)]'; else printf '%s\n' "$given"; fi ;;
  "ad group show "*)
    g="$(argv_ --group "$@")"
    case "$g" in
      ????????-????-????-????-????????????)
        dn="$(jq -r --arg g "$g" '.groups[$g] // empty' "$W")"
        [ -n "$dn" ] || fail_ "ERROR: Resource '$g' does not exist or one of its queried reference-property objects are not present." 3
        id="$g" ;;
      *)
        c="$(jq -r --arg g "$g" '[.groups | to_entries[] | select(.value | startswith($g))] | length' "$W")"
        [ "$c" = "1" ] || fail_ "ERROR: Group $g is not found in Graph " 1
        id="$(jq -r --arg g "$g" '[.groups | to_entries[] | select(.value | startswith($g))][0].key' "$W")"
        dn="$(jq -r --arg i "$id" '.groups[$i]' "$W")" ;;
    esac
    if [ "$q" = "id" ]; then echo "$id"; else printf '{"id":"%s","displayName":"%s"}\n' "$id" "$dn"; fi ;;
  "ad group create "*)
    dn="$(argv_ --display-name "$@")"
    jq -e --arg d "$dn" '.inject.groupCreateFail | index($d) != null' "$W" >/dev/null 2>&1 && fail_ "ERROR: Insufficient privileges to complete the operation." 1
    id="$(jq -r --arg d "$dn" '[.groups | to_entries[] | select(.value == $d)][0].key // empty' "$W")"
    if [ -z "$id" ]; then id="$(printf '%08x-0000-4000-8000-%012x' "$RANDOM$RANDOM" "$$$RANDOM" | cut -c1-36)"; upd_ --arg i "$id" --arg d "$dn" '.groups[$i] = $d'; fi
    if [ "$q" = "id" ]; then echo "$id"; else printf '{"id":"%s","displayName":"%s"}\n' "$id" "$dn"; fi ;;
  *) printf 'UNEXPECTED %s\n' "$*" >> "$L/unexpected.log"; echo "stub az: unexpected call: $*" >&2; exit 2 ;;
esac
'@
$curlStub = @'
#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
printf 'curl %s\n' "$url" >> "$P91_LOG/az.log"
case "$url" in
  https://management.azure.com/*) printf '200' ;;
  https://prices.azure.com/*) printf '{"Items":[],"NextPageLink":null}' ;;
  *) exit 7 ;;
esac
'@
$pwshStub = @'
#!/usr/bin/env bash
printf 'pwsh %s\n' "$*" >> "$P91_LOG/scripts.log"
case "$*" in *PSVersionTable*) echo "7.6.6"; exit 0 ;; esac
case "$*" in *Sync-ClaudeAccess*) [ "$(jq -r '.inject.sync' "$P91_WORLD")" = "fail" ] && { echo "Graph read failed: 404 (Not Found)." >&2; exit 1; } ;; esac
exit 0
'@
$psStub = @'
#!/usr/bin/env bash
# ps -o lstart= -p <pid>: the start time the test recorded for that PID, or nothing.
pid=""; prev=""; for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
line="$(grep "^$pid|" "$P91_PS_TABLE" 2>/dev/null | head -n 1)"
[ -n "$line" ] || exit 1
printf '%s\n' "${line#*|}"
'@
# Test only: uname -s prints P91_UNAME_S when the harness sets it, so that Git Bash takes the Linux
# path (on Windows hosts) and a scenario can be Git Bash on any host. The installer has no switch.
$unameStub = @'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ] && [ -n "${P91_UNAME_S:-}" ]; then printf '%s\n' "$P91_UNAME_S"; exit 0; fi
for u in /usr/bin/uname /bin/uname; do [ -x "$u" ] && exec "$u" "$@"; done
exit 127
'@

# The files the bash installer reads, copied once per suite; every scenario copies the template.
function New-BashTemplate([string]$Scratch) {
    $template = Join-Path $Scratch 'template'
    foreach ($d in 'scripts', 'infra', 'schemas') { New-Item -ItemType Directory -Force -Path (Join-Path $template $d) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $root 'install-claude-gateway.sh') -Destination $template
    $files = @('scripts/banner.sh', 'scripts/preflight.sh', 'infra/main.bicep', 'infra/foundry-role.bicep', 'infra/policy.xml', 'schemas/claude-gateway.answers.schema.json') +
        @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File | Where-Object { $_.Name -like 'install-*' } | ForEach-Object { "scripts/$($_.Name)" })
    foreach ($f in $files) { if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $template $f) } }
    foreach ($f in 'scripts/Sync-ClaudeAccess.ps1', 'scripts/Select-ClaudeFinOpsTooling.ps1') { Write-Lf (Join-Path $template $f) '# placeholder' }
    $table = Join-Path $Scratch 'ps-table.txt'
    Write-Lf $table ''
    return [pscustomobject]@{ Template = $template; PsTable = $table }
}
$sub = '00000000-0000-4000-8000-0000000000a1'

function New-World {
    [ordered]@{
        tenantId = '00000000-0000-4000-8000-0000000000f1'; subscriptionId = $sub; subscriptionName = 'p91-subscription'
        foundry = [ordered]@{ name = 'ai-p91'; rg = 'rg-ai-p91'; location = 'eastus2'; deployments = @([ordered]@{ name = 'claude-sonnet-5'; properties = [ordered]@{ model = [ordered]@{ format = 'Anthropic'; name = 'claude-sonnet-5'; version = '2' } } }) }
        resourceGroups = [ordered]@{ 'rg-ai-p91' = 'eastus2' }; apims = [ordered]@{}; deployments = [ordered]@{}; groups = [ordered]@{}
        inject = [ordered]@{ createMode = 'ok'; sync = ''; readErrors = @(); runningPolls = @(); groupCreateFail = @() }
    }
}
function New-Scenario([string]$Name, $World, $From) {
    $dir = Join-Path $scratch "scenarios/$Name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    # The state directory is inside the scenario's home: the installer refuses one outside $HOME.
    $s = [pscustomobject]@{ Name = $Name; Dir = $dir; Repo = (Join-Path $dir 'repo'); State = (Join-Path $dir 'home/state'); World = (Join-Path $dir 'world.json'); Home = (Join-Path $dir 'home'); Runs = 0 }
    New-Item -ItemType Directory -Force -Path $s.Home | Out-Null
    if ($From) {
        Copy-Item -LiteralPath $From.Repo -Destination $s.Repo -Recurse
        Copy-Item -LiteralPath $From.World -Destination $s.World
        New-Item -ItemType Directory -Force -Path $s.State | Out-Null
        # Owner-only, as the installer creates it: the installer refuses a store its group can write.
        if (-not $script:windows) { & chmod 700 $s.State }
        foreach ($f in @(Get-ChildItem -LiteralPath $From.State -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.lock' })) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $s.State ($f.Name -replace '^install-[0-9a-f]{16}', (Get-BashKey $s.Repo)))
        }
    }
    else { Copy-Item -LiteralPath $template -Destination $s.Repo -Recurse; Write-Lf $s.World ($World | ConvertTo-Json -Depth 20) }
    return $s
}
function Edit-World($Scenario, [scriptblock]$Change) { $w = [IO.File]::ReadAllText($Scenario.World) | ConvertFrom-Json; & $Change $w; Write-Lf $Scenario.World ($w | ConvertTo-Json -Depth 20) }
function Get-CheckpointFile($Scenario, [string]$Dir) {
    $d = if ($Dir) { $Dir } else { $Scenario.State }
    if (-not (Test-Path -LiteralPath $d)) { return $null }
    @(Get-ChildItem -LiteralPath $d -Filter 'install-*.json' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.tmp-|\.discarded-' }) | Select-Object -First 1
}
function Edit-Checkpoint($Scenario, [scriptblock]$Change) {
    $f = Get-CheckpointFile $Scenario
    if (-not $f) { return }
    $cp = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json; & $Change $cp; Write-Lf $f.FullName ($cp | ConvertTo-Json -Depth 20)
}
function Get-Hash($Scenario) { $f = Get-CheckpointFile $Scenario; if ($f) { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } else { '' } }
function New-Run($Scenario, [string[]]$Arguments, [hashtable]$Environment = @{}) {
    $Scenario.Runs++
    $dir = Join-Path $Scenario.Dir "run$($Scenario.Runs)"
    $shim = Join-Path $dir 'bin'; $logs = Join-Path $dir 'logs'
    foreach ($d in $shim, $logs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    Write-Lf (Join-Path $shim 'az') $azStub; Write-Lf (Join-Path $shim 'curl') $curlStub; Write-Lf (Join-Path $shim 'pwsh') $pwshStub; Write-Lf (Join-Path $shim 'ps') $psStub
    Write-Lf (Join-Path $shim 'uname') $unameStub
    Write-Lf (Join-Path $shim 'jq') ("#!/usr/bin/env bash`nexec '" + $jqPath.Replace("'", "'\''") + "' `"`$@`"`n")
    $envs = [ordered]@{ P91_WORLD = (ConvertTo-BashPath $Scenario.World); P91_LOG = (ConvertTo-BashPath $logs); P91_PS_TABLE = (ConvertTo-BashPath $psTable); HOME = (ConvertTo-BashPath $Scenario.Home)
        CLAUDE_GATEWAY_STATE_DIR = (ConvertTo-BashPath $Scenario.State); CLAUDE_GATEWAY_DEPLOY_POLL_SECONDS = '0'; CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS = '30'
        P91_UNAME_S = $(if ($script:windows) { 'Linux' } else { $null }) }
    foreach ($k in $Environment.Keys) { $envs[$k] = $Environment[$k] }
    $lines = foreach ($k in $envs.Keys) { if ($null -eq $envs[$k]) { "unset $k" } else { "export $k='" + ([string]$envs[$k]).Replace("'", "'\''") + "'" } }
    $quoted = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' '
    $runner = "export PATH=`"$(ConvertTo-BashPath $shim):/usr/bin:/bin`"`nchmod +x `"$(ConvertTo-BashPath $shim)`"/* 2>/dev/null`n$($lines -join "`n")`ncd `"$(ConvertTo-BashPath $Scenario.Repo)`" || exit 90`nexec bash ./install-claude-gateway.sh $quoted < /dev/null"
    $path = Join-Path $dir 'run.sh'
    Write-Lf $path $runner
    [pscustomobject]@{ Scenario = $Scenario; Dir = $dir; Logs = $logs; Runner = $path }
}
# At most six runs at a time, each with its own time limit: all of a wave at once on a loaded
# machine ran past one shared limit.
function Invoke-Runs([object[]]$Runs, [int]$Parallel = 6, [int]$TimeoutSeconds = 300) {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($r in $Runs) { $queue.Enqueue($r) }
    $active = [System.Collections.Generic.List[object]]::new()
    $results = @{}
    while ($queue.Count -or $active.Count) {
        while ($queue.Count -and $active.Count -lt $Parallel) {
            $r = $queue.Dequeue()
            $psi = [Diagnostics.ProcessStartInfo]::new($bash)
            $psi.ArgumentList.Add((ConvertTo-BashPath $r.Runner))
            $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            foreach ($name in @($psi.Environment.Keys | Where-Object { $_ -like 'P91_*' -or $_ -like 'CLAUDE_*' -or $_ -in 'CI', 'TF_BUILD', 'GITHUB_ACTIONS', 'AZUREPS_HOST_ENVIRONMENT', 'ACC_CLOUD' })) { [void]$psi.Environment.Remove($name) }
            $p = [Diagnostics.Process]::Start($psi)
            $active.Add([pscustomobject]@{ Run = $r; Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Clock = [Diagnostics.Stopwatch]::StartNew() })
        }
        foreach ($s in @($active)) {
            $timedOut = $s.Clock.Elapsed.TotalSeconds -gt $TimeoutSeconds
            if (-not $s.Process.HasExited -and -not $timedOut) { continue }
            if ($timedOut -and -not $s.Process.HasExited) { try { $s.Process.Kill($true) } catch { } }
            $s.Process.WaitForExit()
            $out = if ($s.Out.Wait(5000)) { $s.Out.Result } else { '' }
            $err = if ($s.Err.Wait(5000)) { $s.Err.Result } else { '' }
            $read = { param($n) $f = Join-Path $s.Run.Logs $n; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() } }
            $results[$s.Run.Dir] = [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $s.Process.ExitCode }); TimedOut = $timedOut
                Out = (($out -replace "`e\[[0-9;]*m", '').Replace("`r", '')); Err = (($err -replace "`e\[[0-9;]*m", '').Replace("`r", ''))
                Az = (& $read 'az.log'); Scripts = (& $read 'scripts.log'); Unexpected = (& $read 'unexpected.log'); Snapshots = (& $read 'snapshots.log') }
            [void]$active.Remove($s)
        }
        Start-Sleep -Milliseconds 100
    }
    return $results
}
function Get-Calls($Result, [string]$Pattern) { @($Result.Az | Where-Object { $_ -like $Pattern }) }
function Get-Order($Result, [string]$First, [string]$Then) {
    $a = -1; $b = -1
    for ($i = 0; $i -lt @($Result.Az).Count; $i++) { if ($a -lt 0 -and $Result.Az[$i] -like $First) { $a = $i }; if ($Result.Az[$i] -like $Then) { $b = $i } }
    return ($a -ge 0 -and $b -gt $a)
}
function Get-ErrLines($Result) { @($Result.Err -split "`n" | Where-Object { $_.Trim() }) }
function Get-Tail($Result) { ((@(($Result.Out + "`n" + $Result.Err) -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ') }
function Test-Refusal($Result, [string]$Field) {
    $lines = @(Get-ErrLines $Result)
    ($Result.ExitCode -eq 1 -and $lines.Count -eq 1 -and $lines[0] -match '^Refused: ' -and $lines[0] -match $Field -and $lines[0] -match 'Nothing was changed')
}
