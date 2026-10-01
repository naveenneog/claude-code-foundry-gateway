# P91 S11 and the bash halves of S9, S10 and S12: install-claude-gateway.sh keeps a checkpoint and a
# rerun resumes after the last step whose result Azure still shows (docs/adr/0046-installer-checkpoint-and-resume.md).
# Each run is bash from a copy of the files the installer reads, with stub az, curl, pwsh and ps first
# on a PATH; the az stub keeps its state in a JSON world file through jq, so nothing reaches Azure.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Installer checkpoint and resume (bash installer)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()

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

$installerPath = Join-Path $root 'install-claude-gateway.sh'
$libraryPaths = @('scripts\install-checkpoint.sh', 'scripts\install-resume.sh') | ForEach-Object { Join-Path $root $_ }

# ------------------------------------------------------------------ static checks
# macOS ships bash 3.2 (runner image macOS 26: Bash 3.2.57, docs/UNKNOWNS.md U71), and BSD tools.
$library = if (-not @($libraryPaths | Where-Object { -not (Test-Path -LiteralPath $_) }).Count) { @($libraryPaths | ForEach-Object { [IO.File]::ReadAllText($_) }) -join "`n" } else { '' }
$syntaxOk = [bool]$library
foreach ($p in $libraryPaths) { if (-not (Test-Path -LiteralPath $p) -or (& $bash -n (ConvertTo-BashPath $p) 2>&1 | Out-String).Trim() -ne '' -or $LASTEXITCODE -ne 0) { $syntaxOk = $false } }
Assert 'the checkpoint libraries exist and pass bash -n' $syntaxOk
$forbidden = '(?m)^[^#\n]*(\b(declare|local|typeset)\s+-[a-zA-Z]*A\b|\bmapfile\b|\breadarray\b|\$\{[^}\n]*(,,|\^\^)[^}\n]*\}|\|&|&>>|\bcoproc\b|\bsed\s+-i(\s|$)|\bdate\s+(-[a-zA-Z]*\s+)*-d\b|\breadlink\s+-f\b|\bstat\s+-c\b|\bfind\b[^\n]*-printf\b|\bgrep\s+-[a-zA-Z]*P)'
$hits = @([regex]::Matches(([IO.File]::ReadAllText($installerPath) + "`n" + $library), $forbidden) | ForEach-Object { $_.Value.Trim() })
Assert 'the installer and its library use nothing that needs bash 4 or GNU tools' ($library -and -not $hits.Count) ($hits -join ' | ')

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
  "cognitiveservices account deployment list "*) jq '.foundry.deployments' "$W" ;;
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
    case "$q" in name) echo "$nm" ;; id) echo "/subscriptions/x/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$nm" ;; *) printf '{"name":"%s"}\n' "$nm" ;; esac ;;
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

# ------------------------------------------------------------------ harness
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p91-bash-checkpoint-' + [guid]::NewGuid().ToString('N'))
$template = Join-Path $scratch 'template'
foreach ($d in 'scripts', 'infra') { New-Item -ItemType Directory -Force -Path (Join-Path $template $d) | Out-Null }
Copy-Item -LiteralPath $installerPath -Destination $template
foreach ($f in 'scripts\banner.sh', 'scripts\preflight.sh', 'scripts\install-checkpoint.sh', 'scripts\install-resume.sh', 'infra\main.bicep', 'infra\foundry-role.bicep', 'infra\policy.xml') {
    if (Test-Path -LiteralPath (Join-Path $root $f)) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination (Join-Path $template $f) }
}
foreach ($f in 'scripts\Sync-ClaudeAccess.ps1', 'scripts\Select-ClaudeFinOpsTooling.ps1') { Write-Lf (Join-Path $template $f) '# placeholder' }
$psTable = Join-Path $scratch 'ps-table.txt'
Write-Lf $psTable ''
$sub = '00000000-0000-4000-8000-0000000000a1'

function New-World {
    [ordered]@{
        tenantId = '00000000-0000-4000-8000-0000000000f1'; subscriptionId = $sub; subscriptionName = 'p91-subscription'
        foundry = [ordered]@{ deployments = @([ordered]@{ name = 'claude-sonnet-5'; properties = [ordered]@{ model = [ordered]@{ format = 'Anthropic'; name = 'claude-sonnet-5'; version = '2' } } }) }
        resourceGroups = [ordered]@{ 'rg-ai-p91' = 'eastus2' }; apims = [ordered]@{}; deployments = [ordered]@{}; groups = [ordered]@{}
        inject = [ordered]@{ createMode = 'ok'; sync = ''; readErrors = @(); runningPolls = @(); groupCreateFail = @() }
    }
}
function New-Scenario([string]$Name, $World, $From) {
    $dir = Join-Path $scratch "scenarios\$Name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $s = [pscustomobject]@{ Name = $Name; Dir = $dir; Repo = (Join-Path $dir 'repo'); State = (Join-Path $dir 'state'); World = (Join-Path $dir 'world.json'); Home = (Join-Path $dir 'home'); Runs = 0 }
    New-Item -ItemType Directory -Force -Path $s.Home | Out-Null
    if ($From) {
        Copy-Item -LiteralPath $From.Repo -Destination $s.Repo -Recurse
        Copy-Item -LiteralPath $From.World -Destination $s.World
        New-Item -ItemType Directory -Force -Path $s.State | Out-Null
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
    Write-Lf (Join-Path $shim 'jq') ("#!/usr/bin/env bash`nexec '" + $jqPath.Replace("'", "'\''") + "' `"`$@`"`n")
    $envs = [ordered]@{ P91_WORLD = (ConvertTo-BashPath $Scenario.World); P91_LOG = (ConvertTo-BashPath $logs); P91_PS_TABLE = (ConvertTo-BashPath $psTable); HOME = (ConvertTo-BashPath $Scenario.Home)
        CLAUDE_GATEWAY_STATE_DIR = (ConvertTo-BashPath $Scenario.State); CLAUDE_GATEWAY_DEPLOY_POLL_SECONDS = '0'; CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS = '30' }
    foreach ($k in $Environment.Keys) { $envs[$k] = $Environment[$k] }
    $lines = foreach ($k in $envs.Keys) { if ($null -eq $envs[$k]) { "unset $k" } else { "export $k='" + ([string]$envs[$k]).Replace("'", "'\''") + "'" } }
    $quoted = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "'\''") + "'" }) -join ' '
    $runner = "export PATH=`"$(ConvertTo-BashPath $shim):/usr/bin:/bin`"`nchmod +x `"$(ConvertTo-BashPath $shim)`"/* 2>/dev/null`n$($lines -join "`n")`ncd `"$(ConvertTo-BashPath $Scenario.Repo)`" || exit 90`nexec bash ./install-claude-gateway.sh $quoted < /dev/null"
    $path = Join-Path $dir 'run.sh'
    Write-Lf $path $runner
    [pscustomobject]@{ Scenario = $Scenario; Dir = $dir; Logs = $logs; Runner = $path }
}
function Invoke-Runs([object[]]$Runs, [int]$TimeoutSeconds = 240) {
    $started = foreach ($r in $Runs) {
        $psi = [Diagnostics.ProcessStartInfo]::new($bash)
        $psi.ArgumentList.Add((ConvertTo-BashPath $r.Runner))
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        foreach ($name in @($psi.Environment.Keys | Where-Object { $_ -like 'P91_*' -or $_ -like 'CLAUDE_*' -or $_ -in 'CI', 'TF_BUILD', 'GITHUB_ACTIONS', 'AZUREPS_HOST_ENVIRONMENT', 'ACC_CLOUD' })) { [void]$psi.Environment.Remove($name) }
        $p = [Diagnostics.Process]::Start($psi)
        [pscustomobject]@{ Run = $r; Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync() }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $results = @{}
    foreach ($s in $started) {
        $timedOut = -not $s.Process.WaitForExit([int][math]::Max(1000, $TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if ($timedOut) { try { $s.Process.Kill($true) } catch { } }
        $out = if ($s.Out.Wait(5000)) { $s.Out.Result } else { '' }
        $err = if ($s.Err.Wait(5000)) { $s.Err.Result } else { '' }
        $read = { param($n) $f = Join-Path $s.Run.Logs $n; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() } }
        $results[$s.Run.Dir] = [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $s.Process.ExitCode }); TimedOut = $timedOut
            Out = (($out -replace "`e\[[0-9;]*m", '').Replace("`r", '')); Err = (($err -replace "`e\[[0-9;]*m", '').Replace("`r", ''))
            Az = (& $read 'az.log'); Scripts = (& $read 'scripts.log'); Unexpected = (& $read 'unexpected.log'); Snapshots = (& $read 'snapshots.log') }
    }
    return $results
}
function Get-Calls($Result, [string]$Pattern) { @($Result.Az | Where-Object { $_ -like $Pattern }) }
function Get-ErrLines($Result) { @($Result.Err -split "`n" | Where-Object { $_.Trim() }) }
function Get-Tail($Result) { ((@(($Result.Out + "`n" + $Result.Err) -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ') }
function Test-Refusal($Result, [string]$Field) {
    $lines = @(Get-ErrLines $Result)
    ($Result.ExitCode -eq 1 -and $lines.Count -eq 1 -and $lines[0] -match '^Refused: ' -and $lines[0] -match $Field -and $lines[0] -match 'Nothing was changed')
}

$args0 = @('--subscription', $sub, '--foundry-account', 'ai-p91', '--foundry-rg', 'rg-ai-p91', '--resource-group', 'rg-p91', '--location', 'eastus2',
    '--name-prefix', 'p91gw', '--publisher-email', 'ops@contoso.com', '--sku', 'BasicV2', '--yes', '--skip-finops-offer')
$doneAt = '(?m)^\s+done \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z  '
$resumesAt = '(?m)^\s+resumes at: '
$sleeper = $null
try {
    # ------------------------------------------------------------------ first runs
    $w = New-World; $w.inject.groupCreateFail = @('claude-code-premium')
    $base = New-Scenario 'base' $w
    $w = New-World; $w.inject.createMode = 'disconnect'; $w.inject.runningPolls = @('Running', 'Running')
    $running = New-Scenario 'running' $w
    $w = New-World; $w.inject.createMode = 'fail'; $w.resourceGroups['rg-p91'] = 'eastus2'; $w.apims['apim-p91gw'] = [ordered]@{ rg = 'rg-p91'; sku = 'BasicV2'; location = 'eastus2'; identity = 'SystemAssigned'; apis = @('claude-foundry') }
    $preexisting = New-Scenario 'preexisting' $w
    $w = New-World; $w.inject.groupCreateFail = @('claude-code-premium')
    $noDrive = New-Scenario 'cloudshell-nodrive' $w
    $drive = New-Scenario 'cloudshell-drive' $w
    New-Item -ItemType Directory -Force -Path (Join-Path $drive.Home 'clouddrive') | Out-Null
    $whatIf = New-Scenario 'whatif' (New-World)
    $shellEnv = @{ AZUREPS_HOST_ENVIRONMENT = 'cloud-shell/1.0'; CLAUDE_GATEWAY_STATE_DIR = $null }
    $first = @(
        ($runBase1 = New-Run $base $args0)
        ($runRunning1 = New-Run $running $args0)
        ($runPre1 = New-Run $preexisting $args0)
        ($runNoDrive = New-Run $noDrive $args0 $shellEnv)
        ($runDrive = New-Run $drive $args0 $shellEnv)
        ($runWhatIf = New-Run $whatIf ($args0 + '--what-if'))
    )
    $r1 = Invoke-Runs $first
    $b1 = $r1[$runBase1.Dir]
    $cpFile = Get-CheckpointFile $base
    $cp = if ($cpFile) { try { [IO.File]::ReadAllText($cpFile.FullName) | ConvertFrom-Json } catch { $null } } else { $null }
    $groups = if ($cp) { @(@($cp.steps | Where-Object { $_.id -eq 'entra-groups' })[0].receipt.groups) } else { @() }
    $createdId = [string](@($groups | Where-Object { $_.origin -eq 'created' })[0].id)
    Assert 'S11 run 1 keeps its checkpoint after a group it could not create, with the created group''s id' ($b1.ExitCode -eq 0 -and $cpFile -and $cpFile.BaseName -eq (Get-BashKey $base.Repo) -and
        $createdId -match '^[0-9a-f-]{36}$' -and @($cp.steps | Where-Object { $_.id -eq 'entra-groups' })[0].state -eq 'incomplete' -and $b1.Out -match '(?m)Resume: ') (Get-Tail $b1)
    Assert 'S11 the checkpoint exists before the first change, and --what-if writes none' ((@($b1.Snapshots) -contains 'checkpoint-at-group-create present') -and
        -not (Test-Path -LiteralPath $whatIf.State)) ($b1.Snapshots -join '; ')
    $text = if ($cpFile) { [IO.File]::ReadAllText($cpFile.FullName) } else { '' }
    $answers = 'SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku', 'TpmStandard', 'QuotaStandard', 'TpmPremium', 'QuotaPremium', 'CallsPerMinute', 'StandardGroup', 'PremiumGroup'
    $extra = if ($cp) { @(@($cp.PSObject.Properties.Name | Where-Object { $_ -notin 'schema', 'schemaVersion', 'runId', 'installer', 'installerFingerprint', 'installerCommit', 'checkout', 'createdUtc', 'updatedUtc', 'binding', 'answers', 'steps' }) +
        @($cp.answers.PSObject.Properties.Name | Where-Object { $_ -notin $answers })) } else { @('no checkpoint') }
    Assert 'S10 the bash checkpoint holds the schema''s keys only, written by bash, and no secret' ($cp -and $cp.installer -eq 'bash' -and -not $extra.Count -and
        $text -notmatch '(?i)eyJ[A-Za-z0-9_-]{4,}\.|accountkey=|sharedaccesssignature|-----begin|password|accesstoken') ($extra -join ', ')
    $nd = $r1[$runNoDrive.Dir]
    Assert 'S12 bash in Cloud Shell without clouddrive warns and prints the resume command with the recorded answers on one line' ($nd.Out -match '(?m)\[WARN\].*Cloud Shell.*clouddrive' -and
        $nd.Out -match "(?m)^\s*Resume: cd '.+' && \./install-claude-gateway\.sh .*--resource-group 'rg-p91'.*--name-prefix 'p91gw'" -and
        $null -ne (Get-CheckpointFile $noDrive (Join-Path $noDrive.Home '.claude-gateway'))) (Get-Tail $nd)
    $dr = $r1[$runDrive.Dir]
    Assert 'S12 bash with clouddrive keeps the checkpoint under it and prints the 20-minute line before the deployment' ($null -ne (Get-CheckpointFile $drive (Join-Path $drive.Home 'clouddrive\.claude-gateway')) -and
        $dr.Out -notmatch '(?m)\[WARN\].*clouddrive' -and $dr.Out -match '(?m)20 minutes without interactive activity.*Resume: ') (Get-Tail $dr)

    # ------------------------------------------------------------------ reruns
    $sleeperOut = & $bash -c 'sleep 300 >/dev/null 2>&1 & echo $!'
    $sleeper = "$sleeperOut".Trim()
    Write-Lf $psTable "$sleeper|Thu Oct  1 09:00:00 2026`n"
    $hostName = "$(& $bash -c 'uname -n')".Trim().ToLowerInvariant().Split('.')[0]
    $sc = [ordered]@{}
    foreach ($n in 'tenant', 'subscription', 'group', 'prefix', 'installer', 'version', 'truncated', 'restart', 'liveLock', 'exitedLock', 'otherHost', 'staleHost') { $sc[$n] = New-Scenario $n $null $base }
    foreach ($s in @($base) + @($sc.Values)) { Edit-World $s { param($w) $w.inject.groupCreateFail = @() } }
    Edit-World $sc.tenant { param($w) $w.tenantId = '00000000-0000-4000-8000-0000000000f9' }
    Edit-Checkpoint $sc.installer { param($c) $c.installer = 'pwsh' }
    Add-Content -LiteralPath (Join-Path $sc.version.Repo 'install-claude-gateway.sh') -Value '# a later installer'
    foreach ($n in 'truncated', 'restart') { $f = Get-CheckpointFile $sc[$n]; if ($f) { $t = [IO.File]::ReadAllText($f.FullName); Write-Lf $f.FullName $t.Substring(0, [int]($t.Length / 2)) } }
    $lockOf = { param($s, [hashtable]$fields, [int]$age) $p = Join-Path $s.State ((Get-BashKey $s.Repo) + '.lock'); Write-Lf $p ($fields | ConvertTo-Json -Compress); if ($age) { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-$age)) } }
    & $lockOf $sc.liveLock @{ pid = [int]$sleeper; processStart = 'Thu Oct  1 09:00:00 2026'; host = $hostName; installer = 'bash'; runId = ('a' * 32); acquiredUtc = '2026-10-01T00:00:00Z' } 0
    & $lockOf $sc.exitedLock @{ pid = 999999; processStart = 'Thu Oct  1 08:00:00 2026'; host = $hostName; installer = 'bash'; runId = ('b' * 32); acquiredUtc = '2026-10-01T00:00:00Z' } 0
    & $lockOf $sc.otherHost @{ pid = 4242; processStart = 'x'; host = 'p91-other-host'; installer = 'bash'; runId = ('c' * 32); acquiredUtc = '2026-10-01T00:00:00Z' } 0
    & $lockOf $sc.staleHost @{ pid = 4242; processStart = 'x'; host = 'p91-other-host'; installer = 'bash'; runId = ('d' * 32); acquiredUtc = '2026-10-01T00:00:00Z' } 10
    $hashes = @{}; foreach ($n in 'tenant', 'subscription', 'group', 'prefix', 'installer', 'truncated') { $hashes[$n] = Get-Hash $sc[$n] }
    $bounded = New-Scenario 'bounded' $null $running
    Edit-World $bounded { param($w) foreach ($p in $w.deployments.'rg-p91'.PSObject.Properties) { $p.Value.polls = @('forever') } }
    $swap = { param([string]$flag, [string]$to) $a = @($args0); $i = [array]::IndexOf($a, $flag); $a[$i + 1] = $to; $a }
    $second = @(
        ($runBase2 = New-Run $base $args0)
        ($runRunning2 = New-Run $running $args0)
        ($runBounded = New-Run $bounded $args0 @{ CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS = '1' })
        ($runPre2 = New-Run $preexisting $args0)
        ($runTenant = New-Run $sc.tenant $args0)
        ($runSubscription = New-Run $sc.subscription (& $swap '--subscription' '00000000-0000-4000-8000-0000000000a9'))
        ($runGroup = New-Run $sc.group (& $swap '--resource-group' 'rg-other'))
        ($runPrefix = New-Run $sc.prefix (& $swap '--name-prefix' 'p91other'))
        ($runInstaller = New-Run $sc.installer $args0)
        ($runVersion = New-Run $sc.version $args0)
        ($runTruncated = New-Run $sc.truncated $args0)
        ($runRestart = New-Run $sc.restart ($args0 + '--restart'))
        ($runLiveLock = New-Run $sc.liveLock $args0)
        ($runExitedLock = New-Run $sc.exitedLock $args0)
        ($runOtherHost = New-Run $sc.otherHost $args0)
        ($runStaleHost = New-Run $sc.staleHost $args0)
    )
    $r2 = Invoke-Runs $second
    $b2 = $r2[$runBase2.Dir]
    Assert 'S11 S1 the rerun finds the created group by id, creates only the missing one and no deployment' ($b2.ExitCode -eq 0 -and $createdId -and (Get-Calls $b2 "ad group show --group $createdId*").Count -and
        (Get-Calls $b2 'ad group create --display-name claude-code-premium*').Count -eq 1 -and -not (Get-Calls $b2 'ad group create --display-name claude-code-standard*').Count -and
        -not (Get-Calls $b2 'deployment group create*').Count) (Get-Tail $b2)
    Assert 'S11 S1 the rerun prints completed steps with UTC times and the resume step, then removes the checkpoint' ($b2.Out -match ($doneAt + 'Resource group') -and $b2.Out -match ($doneAt + 'Gateway deployment') -and
        $b2.Out -match ($resumesAt + 'Entra groups') -and $cpFile -and -not (Get-CheckpointFile $base)) (Get-Tail $b2)
    $g1 = $r1[$runRunning1.Dir]; $g2 = $r2[$runRunning2.Dir]
    Assert 'S11 S4 after run 1 died while its deployment ran, the rerun waits for it and creates none' ($g1.ExitCode -ne 0 -and $g2.ExitCode -eq 0 -and -not (Get-Calls $g2 'deployment group create*').Count -and
        (Get-Calls $g2 'deployment group show*').Count -ge 3) (Get-Tail $g2)
    $bb = $r2[$runBounded.Dir]
    Assert 'S11 S4 past the bound the rerun refuses on one line with the resume command' ($bb.ExitCode -eq 1 -and @(Get-ErrLines $bb).Count -eq 1 -and @(Get-ErrLines $bb)[0] -match 'still running' -and
        @(Get-ErrLines $bb)[0] -match 'install-claude-gateway\.sh' -and -not (Get-Calls $bb 'deployment group create*').Count) (Get-Tail $bb)
    $p2 = $r2[$runPre2.Dir]
    Assert 'Decision 9 a bash resume does not redeploy over an APIM it did not create, and names the PowerShell path' ((Test-Refusal $p2 'Install-ClaudeGateway\.ps1 -ExistingApimName') -and
        -not (Get-Calls $p2 'deployment group create*').Count) (Get-Tail $p2)
    foreach ($case in @(@('tenant', $runTenant, 'tenant'), @('subscription', $runSubscription, 'subscription'), @('group', $runGroup, 'resource group'), @('prefix', $runPrefix, 'gateway'), @('installer', $runInstaller, 'Install-ClaudeGateway\.ps1'))) {
        $res = $r2[$case[1].Dir]
        Assert "S11 S5 a different $($case[2] -replace '\\', '') refuses on one line, names it and keeps the checkpoint" ((Test-Refusal $res $case[2]) -and $hashes[$case[0]] -and (Get-Hash $sc[$case[0]]) -eq $hashes[$case[0]]) (Get-Tail $res)
    }
    $v2 = $r2[$runVersion.Dir]
    Assert 'S11 S5 a different installer version resumes and says which wrote the checkpoint' ($v2.ExitCode -eq 0 -and $v2.Out -match '(?m)checkpoint written by install-claude-gateway\.sh \S+; running install-claude-gateway\.sh \S+' -and
        -not (Get-Calls $v2 'deployment group create*').Count) (Get-Tail $v2)
    $tr = $r2[$runTruncated.Dir]
    Assert 'S11 S8 a corrupt checkpoint refuses on one line and keeps the file' ((Test-Refusal $tr 'not valid JSON') -and $hashes.truncated -and (Get-Hash $sc.truncated) -eq $hashes.truncated) (Get-Tail $tr)
    $rs = $r2[$runRestart.Dir]
    Assert 'S11 S8 --restart sets it aside and runs as a first run' ($rs.ExitCode -eq 0 -and @(Get-ChildItem -LiteralPath $sc.restart.State -Filter '*.discarded-*.json').Count -eq 1 -and
        (Get-Calls $rs 'deployment group create*').Count -eq 1) (Get-Tail $rs)
    $l1 = $r2[$runLiveLock.Dir]; $l2 = $r2[$runExitedLock.Dir]; $l3 = $r2[$runOtherHost.Dir]; $l4 = $r2[$runStaleHost.Dir]
    Assert 'S9 bash a live lock refuses naming its PID; an exited holder is stale' ((Test-Refusal $l1 "$sleeper") -and $l2.ExitCode -eq 0 -and $l2.Out -match '(?m)stale lock') ((Get-Tail $l1) + ' || ' + (Get-Tail $l2))
    Assert 'S9 bash another host''s lock refuses with a heartbeat and is stale without one for 5 minutes' ((Test-Refusal $l3 'p91-other-host') -and $l4.ExitCode -eq 0 -and $l4.Out -match '(?m)stale lock') ((Get-Tail $l3) + ' || ' + (Get-Tail $l4))
    $all = @($r1.Values) + @($r2.Values)
    $unexpected = @($all | ForEach-Object { $_.Unexpected } | Where-Object { $_ })
    Assert 'harness: every az call was one the stub knows, and no run timed out' (-not $unexpected.Count -and -not @($all | Where-Object { $_.TimedOut }).Count) (($unexpected | Select-Object -Unique -First 4) -join ' | ')
}
finally {
    if ($sleeper) { & $bash -c "kill $sleeper 2>/dev/null" | Out-Null }
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
