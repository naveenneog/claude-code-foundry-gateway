# The renewal block of docs/AZ-COMMANDS.md, run in Git Bash against a stub az (P94, ADR-0049).
#
# Kept apart from tests/Test-AzCommandsGuide.ps1, which owns the guide-wide checks (az help flags,
# Bicep parameters of every deployed template, named values). This file runs the one block and checks
# its order, the parameter file it writes and the package it builds from. Offline.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function ConvertTo-BashPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    return '/' + (($full -replace '\\', '/') -replace '^([A-Za-z]):', '$1')
}

$bash = 'C:\Program Files\Git\bin\bash.exe'
$guide = [IO.File]::ReadAllText((Join-Path $root 'docs\AZ-COMMANDS.md'))
$match = [regex]::Match($guide, '(?ms)# P89-PROJECTION-RENEWAL-BEGIN\s*(.*?)# P89-PROJECTION-RENEWAL-END')
Write-Host ''
Write-Host 'Azure CLI guide - the renewal block' -ForegroundColor Cyan
Assert 'the guide has the renewal block' $match.Success
Assert 'Git Bash is available' (Test-Path -LiteralPath $bash) $bash
if (-not $match.Success -or -not (Test-Path -LiteralPath $bash)) { exit 1 }
$block = $match.Groups[1].Value.Trim()

. (Join-Path $root 'scripts\ClaudeProjectionPackage.ps1')
$tar = [regex]::Match($block, '(?m)^\s*tar -c -f - (.+?) \| tar -x -f - -C "\$PACKAGE_DIR"')
Assert 'the block packages exactly the sync package paths' ($tar.Success -and ($tar.Groups[1].Value.Trim() -split '\s+') -join ' ' -ceq ((Get-ClaudeProjectionSyncPackagePaths) -join ' ')) $tar.Groups[1].Value

$digest = 'sha256:' + ('f' * 64)
$stub = @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$P94_CALLS"
args="$*"
case "$args" in
  "deployment group show -g rg -n projection-network-prefix "*)
    if [ "${P94_SCENARIO:-}" = "no-subnet" ]; then printf '\n'; else printf '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.Network/virtualNetworks/vnet-prefix/subnets/renewal\n'; fi ;;
  "deployment group show -g rg -n projection-prefix "*) printf 'cosmos-prefix\n' ;;
  "resource list -g rg "*)
    printf 'cosmos-prefix\tMicrosoft.DocumentDB/databaseAccounts\nacrprefix\tMicrosoft.ContainerRegistry/registries\nid-projection-renewal-prefix\tMicrosoft.ManagedIdentity/userAssignedIdentities\nag-projection-renewal-prefix\tmicrosoft.insights/actiongroups\nsqr-projection-prefix-no-success-45m\tmicrosoft.insights/scheduledqueryrules\n'
    if [ "${P94_SCENARIO:-}" = "p86-leftovers" ]; then printf 'caj-projection-renewal-prefix\tMicrosoft.App/jobs\ncae-projection-prefix\tmicrosoft.app/managedenvironments\n'; fi
    if [ "${P94_SCENARIO:-}" = "p86-name-other-type" ]; then printf 'cae-projection-prefix\tMicrosoft.Network/networkSecurityGroups\n'; fi ;;
  "monitor log-analytics workspace list "*)
    printf '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law\n'
    if [ "${P94_SCENARIO:-}" = "two-workspaces" ]; then printf '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law2\n'; fi ;;
  "ad group show --group claude-code-standard "*) printf '10000000-0000-4000-8000-000000000001\n' ;;
  "ad group show --group claude-code-premium "*) printf '10000000-0000-4000-8000-000000000002\n' ;;
  "apim show "*) printf '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.ApiManagement/service/apim\n' ;;
  "deployment group create "*)
    printf 'create %s\n' "$*" >> "$P94_WRITES"
    case "$args" in *"--parameters @renewal-params.json"*) cp renewal-params.json "$P94_STATE/renewal-params.captured.json" ;; esac ;;
  "deployment group show -g rg -n projection-registry-prefix "*)
    printf '{"acrName":{"value":"acrprefix"},"identityName":{"value":"id-projection-renewal-prefix"},"identityPrincipalId":{"value":"40000000-0000-4000-8000-000000000002"}}\n' ;;
  "acr build "*)
    printf 'build %s\n' "$*" >> "$P94_WRITES"
    context="${@: -3:1}"
    printf '%s\n' "$context" > "$P94_STATE/package-dir.txt"
    (cd "$context" && find . -type f | sed 's|^\./||' | sort) > "$P94_STATE/package.txt"
    if [ "${P94_SCENARIO:-}" = "build-fails" ]; then echo "ERROR: (TasksOperationsNotAllowed) ACR Tasks requests are not permitted." >&2; exit 1; fi ;;
  "acr manifest show-metadata "*)
    if [ "${P94_SCENARIO:-}" = "bad-digest" ]; then printf 'latest\n'; else printf '%s\n' "$P94_DIGEST"; fi ;;
  "deployment group show -g rg -n projection-renewal-prefix "*) printf '{"job":"/subscriptions/sub/resourceGroups/rg/providers/Microsoft.App/jobs/caj-renew-x","actionGroup":"ag"}\n' ;;
  *) echo "stub az has no answer for: $args" >&2; exit 9 ;;
esac
'@

function Invoke-RenewalBlock([string]$Scenario, [hashtable]$Environment = @{}) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('p94-guide-' + [guid]::NewGuid().ToString('N'))
    foreach ($relative in 'sync\src', 'resolver\src', 'bin') { New-Item -ItemType Directory -Force -Path (Join-Path $dir $relative) | Out-Null }
    foreach ($file in 'sync\Dockerfile', 'sync\package.json', 'sync\package-lock.json', 'sync\src\apply-projection.mjs', 'sync\src\plan.mjs', 'resolver\src\entitlement.mjs') {
        [IO.File]::WriteAllText((Join-Path $dir $file), "stand-in`n")
    }
    [IO.File]::WriteAllText((Join-Path $dir 'bin\az'), $stub.Replace("`r`n", "`n"))
    # The group block in section 5 records the tier groups; the renewal block reads those receipts.
    if ($Scenario -ne 'no-group-receipts') {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir '.p89-receipts') | Out-Null
        $standardId = if ($Scenario -eq 'bad-receipt-id') { 'not-a-guid' } else { '10000000-0000-4000-8000-000000000001' }
        $premiumId = if ($Scenario -eq 'same-groups') { '10000000-0000-4000-8000-000000000001' } else { '10000000-0000-4000-8000-000000000002' }
        $premiumName = if ($Scenario -eq 'stale-receipt') { 'claude-code-premium-2025' } else { 'claude-code-premium' }
        foreach ($group in @(@('standard', $standardId, 'claude-code-standard'), @('premium', $premiumId, $premiumName))) {
            [IO.File]::WriteAllText((Join-Path $dir ".p89-receipts\group-$($group[0]).json"), (@{ group = @{ created = $false; id = $group[1]; displayName = $group[2]; createdAt = '' } } | ConvertTo-Json -Compress))
        }
    }
    $exports = @{ GATEWAY_RG = 'rg'; APIM_NAME = 'apim'; NAME_PREFIX = 'prefix'; LOCATION = 'eastus2'; TENANT_ID = '00000000-0000-4000-8000-000000000094'
        STANDARD_GROUP = 'claude-code-standard'; PREMIUM_GROUP = 'claude-code-premium'; ALERT_EMAIL = 'ops@example.invalid'; IMAGE_TAG = 'sync-test' }
    foreach ($key in $Environment.Keys) { $exports[$key] = $Environment[$key] }
    $lines = @('#!/usr/bin/env bash', 'set -uo pipefail', "export PATH=`"$(ConvertTo-BashPath (Join-Path $dir 'bin')):`$PATH`"", "chmod +x `"$(ConvertTo-BashPath (Join-Path $dir 'bin\az'))`"",
        "export P94_SCENARIO='$Scenario'", "export P94_DIGEST='$digest'", "export P94_STATE=`"$(ConvertTo-BashPath $dir)`"",
        "export P94_CALLS=`"$(ConvertTo-BashPath (Join-Path $dir 'calls.log'))`"", "export P94_WRITES=`"$(ConvertTo-BashPath (Join-Path $dir 'writes.log'))`"",
        "touch `"`$P94_CALLS`" `"`$P94_WRITES`"", "cd `"$(ConvertTo-BashPath $dir)`"")
    foreach ($key in $exports.Keys) { $lines += "export $key='$($exports[$key])'" }
    # After the block: is the directory the build read from still there? The block's status is kept.
    $leftCheck = @('p94_status=$?', 'if [ -s "$P94_STATE/package-dir.txt" ] && [ -d "$(cat "$P94_STATE/package-dir.txt")" ]; then echo "P94-PACKAGE-DIR-LEFT"; fi', 'exit "$p94_status"')
    [IO.File]::WriteAllText((Join-Path $dir 'run.sh'), (($lines + $block + $leftCheck) -join "`n") + "`n")
    $output = & $bash (ConvertTo-BashPath (Join-Path $dir 'run.sh')) 2>&1 | Out-String
    $exit = $LASTEXITCODE
    $read = { param($name) $path = Join-Path $dir $name; if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' } }
    $result = [pscustomobject]@{
        Exit = $exit; Output = $output; Calls = (& $read 'calls.log'); Writes = (& $read 'writes.log'); Package = (& $read 'package.txt')
        PackageDir = (& $read 'package-dir.txt').Trim(); PackageLeft = ($output -match 'P94-PACKAGE-DIR-LEFT')
        Params = $(if (Test-Path -LiteralPath (Join-Path $dir 'renewal-params.captured.json')) { Get-Content -LiteralPath (Join-Path $dir 'renewal-params.captured.json') -Raw | ConvertFrom-Json -AsHashtable } else { $null })
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $result
}

$jq = & $bash -lc 'command -v jq >/dev/null && echo yes'
Assert 'Git Bash has jq' ($jq -match 'yes')

$healthy = Invoke-RenewalBlock 'healthy'
$writes = @($healthy.Writes -split "`n" | Where-Object { $_ })
Assert 'a healthy run completes' ($healthy.Exit -eq 0) $healthy.Output
Assert 'registry, then build, then the job' ($writes.Count -eq 3 -and $writes[0] -match '^create .*-n projection-registry-prefix ' -and $writes[1] -match '^build ' -and $writes[2] -match '^create .*-n projection-renewal-prefix ') ($writes -join ' | ')
$calls = @($healthy.Calls -split "`n" | Where-Object { $_ })
$digestAt = [Array]::IndexOf($calls, @($calls | Where-Object { $_ -match '^acr manifest show-metadata ' })[0])
$buildAt = [Array]::IndexOf($calls, @($calls | Where-Object { $_ -match '^acr build ' })[0])
$renewalAt = [Array]::IndexOf($calls, @($calls | Where-Object { $_ -match '^deployment group create .*projection-renewal' })[0])
Assert 'the digest is read after the build and before the job' ($buildAt -ge 0 -and $buildAt -lt $digestAt -and $digestAt -lt $renewalAt) ($calls -join ' | ')
$package = @($healthy.Package -split "`n" | Where-Object { $_ })
foreach ($file in 'sync/Dockerfile', 'sync/package-lock.json', 'sync/src/apply-projection.mjs', 'resolver/src/entitlement.mjs') {
    Assert "the image builds from a package holding $file" ($package -contains $file) ($package -join ', ')
}
Assert 'the package directory is removed after the build' ($healthy.PackageDir -and -not $healthy.PackageLeft) "package dir '$($healthy.PackageDir)' left: $($healthy.PackageLeft)"
$templateText = [IO.File]::ReadAllText((Join-Path $root 'infra\projection-renewal.bicep'))
$declared = @{}
foreach ($m in [regex]::Matches($templateText, '(?m)^param\s+([A-Za-z][A-Za-z0-9]*)\s+\w+(\s*=)?')) { $declared[$m.Groups[1].Value] = $m.Groups[2].Success }
$given = if ($healthy.Params) { @($healthy.Params.parameters.Keys) } else { @() }
$unknown = @($given | Where-Object { -not $declared.ContainsKey($_) })
$missing = @($declared.Keys | Where-Object { -not $declared[$_] -and $given -notcontains $_ })
Assert 'the parameter file names only template parameters' ($given.Count -gt 0 -and $unknown.Count -eq 0) ($unknown -join ', ')
Assert 'and every parameter the template requires' ($given.Count -gt 0 -and $missing.Count -eq 0) ($missing -join ', ')
$value = { param($name) if ($healthy.Params) { $healthy.Params.parameters[$name].value } }
Assert 'the job is pinned to the digest the registry reported' ((& $value 'syncImageDigest') -ceq $digest)
Assert 'the job gets the tier group ids, the gateway and the alert address' ((& $value 'standardGroupId') -eq '10000000-0000-4000-8000-000000000001' -and (& $value 'premiumGroupId') -eq '10000000-0000-4000-8000-000000000002' -and
    (& $value 'gatewayResourceId') -match 'Microsoft\.ApiManagement/service/apim$' -and ((& $value 'actionGroupEmailReceivers') -join ',') -eq 'ops@example.invalid')
Assert 'the tenant administrator step names the job identity' ($healthy.Output -match 'Grant-ClaudeProjectionRenewalGraphAccess\.ps1 -PrincipalId 40000000-0000-4000-8000-000000000002')
Assert 'the tier group ids come from the group receipts, with no directory lookup' ($healthy.Calls -notmatch '(?m)^ad group ') (($healthy.Calls -split "`n" | Where-Object { $_ -match '^ad ' }) -join ' | ')

foreach ($case in @(
        @{ Name = 'an alert address with a command separator'; Scenario = 'healthy'; Environment = @{ ALERT_EMAIL = 'ops@example.invalid&calc' }; Expect = 'ALERT_EMAIL' }
        @{ Name = 'the alert address placeholder'; Scenario = 'healthy'; Environment = @{ ALERT_EMAIL = '<alert-email>' }; Expect = 'ALERT_EMAIL' }
        @{ Name = 'a network without the renewal subnet'; Scenario = 'no-subnet'; Environment = @{}; Expect = 'renewal subnet' }
        @{ Name = 'two workspaces in the gateway resource group'; Scenario = 'two-workspaces'; Environment = @{}; Expect = 'WORKSPACE_ID' }
        @{ Name = 'P86 renewal resources that the new names would leave behind'; Scenario = 'p86-leftovers'; Environment = @{}; Expect = 'caj-projection-renewal-prefix cae-projection-prefix' }
        @{ Name = 'no group receipts from section 5'; Scenario = 'no-group-receipts'; Environment = @{}; Expect = 'group receipt' }
        @{ Name = 'one group for both tiers'; Scenario = 'same-groups'; Environment = @{}; Expect = 'same group' }
        @{ Name = 'a group receipt recorded for another group name'; Scenario = 'stale-receipt'; Environment = @{}; Expect = "premium group receipt from section 5 records no object id for PREMIUM_GROUP 'claude-code-premium'" }
        @{ Name = 'a group receipt whose id is not an object id'; Scenario = 'bad-receipt-id'; Environment = @{}; Expect = "standard group receipt from section 5 records no object id for STANDARD_GROUP 'claude-code-standard'" }
    )) {
    $refused = Invoke-RenewalBlock $case.Scenario $case.Environment
    Assert "refused before any deployment: $($case.Name)" ($refused.Exit -ne 0 -and $refused.Output -match "Refused: .*$([regex]::Escape($case.Expect))" -and -not $refused.Writes.Trim()) "$($refused.Output.Trim()) | writes: $($refused.Writes.Trim())"
}
$badDigest = Invoke-RenewalBlock 'bad-digest'
Assert 'a digest that is not sha256 stops before the job' ($badDigest.Exit -ne 0 -and $badDigest.Output -match 'not a sha256 digest' -and $badDigest.Writes -notmatch 'projection-renewal-prefix') $badDigest.Output.Trim()
$buildFails = Invoke-RenewalBlock 'build-fails'
Assert 'a refused build stops before the job and removes the package directory' ($buildFails.Exit -ne 0 -and $buildFails.Writes -match '(?m)^build ' -and $buildFails.Writes -notmatch 'projection-renewal-prefix' -and $buildFails.PackageDir -and -not $buildFails.PackageLeft) "$($buildFails.Output.Trim()) | left: $($buildFails.PackageLeft)"
$noPremium = Invoke-RenewalBlock 'healthy' @{ PREMIUM_GROUP = 'none' }
Assert 'PREMIUM_GROUP=none deploys without the premium receipt' ($noPremium.Exit -eq 0 -and $noPremium.Params.parameters.premiumGroupId.value -eq 'none') $noPremium.Output.Trim()
$otherType = Invoke-RenewalBlock 'p86-name-other-type'
Assert 'a resource with a P86 name but another type does not stop the block' ($otherType.Exit -eq 0 -and $otherType.Writes -match 'projection-renewal-prefix') $otherType.Output.Trim()

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Azure CLI guide renewal block holds.' -ForegroundColor Green
exit 0
