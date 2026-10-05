$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$count = 0
function Assert($label, $condition, $detail = '') {
    $script:count++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Live projection verifier - validation, order and teardown (offline)' -ForegroundColor Cyan

$scriptPath = Join-Path $root 'scripts\Test-ClaudeLiveProjection.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-live-verifier-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$installerStub = Join-Path $work 'Install-ClaudeGateway.ps1'
$syncStub = Join-Path $work 'Sync-ClaudeAccess.ps1'
# Stub scripts in a temporary folder: the verifier takes their paths, so no repository file is replaced.
[IO.File]::WriteAllText($installerStub, (@(
    'param($SubscriptionId, $FoundryAccount, $FoundryResourceGroup, $ResourceGroup, $Location, $NamePrefix, $Sku, $EntitlementStore, [switch]$Yes, $StandardGroup, $PremiumGroup)'
    '$global:Live.Calls.Add("installer $ResourceGroup $NamePrefix $Sku $EntitlementStore yes=$Yes $StandardGroup $PremiumGroup")'
    '$global:Live.Synced = $global:Live.Member'
) -join "`n"))
[IO.File]::WriteAllText($syncStub, (@(
    'param($ResourceGroup, $ApimName, $User)'
    '$global:Live.Calls.Add("sync $ResourceGroup $ApimName -User $User")'
    '$global:Live.Synced = $global:Live.Member'
) -join "`n"))
$user = '00000000-0000-4000-8000-0000000000aa'
$sub = '00000000-0000-4000-8000-000000000001'
function Reset-Live([string]$Source = 'projection', [bool]$GroupExists = $false) {
    $global:Live = @{ Calls = [Collections.Generic.List[string]]::new(); Member = $false; Synced = $false; Source = $Source; GroupExists = $GroupExists; Created = @{} }
}
function az {
    $line = $args -join ' '
    $global:Live.Calls.Add("az $line")
    $global:LASTEXITCODE = 0
    switch -Regex ($line) {
        '^account set' { return }
        '^account show' { return (@{ id = $sub; user = @{ name = 'admin@contoso.example' } } | ConvertTo-Json) }
        '^group exists' { return $(if ($global:Live.GroupExists) { 'true' } else { 'false' }) }
        '^ad group show --group (\S+)' { if ($global:Live.Created.ContainsKey($Matches[1])) { return $global:Live.Created[$Matches[1]] }; $global:LASTEXITCODE = 3; return 'ERROR: Resource does not exist' }
        '^ad group create --display-name (\S+)' { $name = $Matches[1]; $id = '00000000-0000-4000-8000-0000000000' + $(if ($name -match 'std') { 'b1' } else { 'b2' }); $global:Live.Created[$name] = $id; return $id }
        '^ad signed-in-user show' { return $user }
        '^ad group member check' { return $(if ($global:Live.Member) { 'true' } else { 'false' }) }
        '^ad group member add' { $global:Live.Member = $true; return }
        '^ad group member remove' { $global:Live.Member = $false; return }
        '^apim nv show .*entitlement-source' { return $global:Live.Source }
        '^apim nv show .*entitlement-projection-prefix' { return 'p98live' }
        '^apim nv show .*models-standard' { return ',claude-haiku-4-5,claude-sonnet-5,' }
        '^apim nv update' { return }
        '^apim show .*gatewayUrl' { return 'https://apim-p98live.azure-api.net' }
        '^apim show .*identity\.principalId' { return '00000000-0000-4000-8000-0000000000c1' }
        '^account get-access-token' { return 'offline-token' }
        '^cognitiveservices account show' { return '/subscriptions/x/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/ai' }
        '^role assignment list' { return '/assignment/one' }
        '^role assignment delete' { return }
        '^ad app list' { return '00000000-0000-4000-8000-0000000000d1' }
        '^ad app delete' { return }
        '^group delete' { return }
        '^ad group delete' { return }
    }
    $global:LASTEXITCODE = 9
    return "unexpected az $line"
}
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $Body, [switch]$SkipHttpErrorCheck, $TimeoutSec)
    $model = ($Body | ConvertFrom-Json).model
    $global:Live.Calls.Add("request $Uri $model auth=$($Headers.Authorization -eq ('Bearer ' + 'offline-token'))")
    [pscustomobject]@{ StatusCode = $(if ($global:Live.Synced) { 200 } else { 403 }) }
}
function Start-Sleep { param($Seconds) }
function Invoke-Verifier([hashtable]$Extra = @{}) {
    $params = @{ SubscriptionId = $sub; Location = 'eastus2'; FoundryAccount = 'ai'; FoundryResourceGroup = 'rg-ai'; ResourceGroup = 'rg-p98-live'; NamePrefix = 'p98live'
        StandardGroup = 'claude-p98-std'; PremiumGroup = 'claude-p98-prm'; UseCurrentAzLogin = $true; Teardown = $true; InstallerPath = $installerStub; SyncAccessPath = $syncStub }
    foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k]) { $params.Remove($k) } else { $params[$k] = $Extra[$k] } }
    $script:Failure = ''
    $global:LASTEXITCODE = 0
    $script:Output = try { & $scriptPath @params 6>$null | Out-String } catch { $script:Failure = $_.Exception.Message; '' }
    $script:Exit = $LASTEXITCODE
}
function At([string]$Pattern) { for ($i = 0; $i -lt $global:Live.Calls.Count; $i++) { if ($global:Live.Calls[$i] -match $Pattern) { return $i } }; return -1 }

try {
    Reset-Live; Invoke-Verifier @{ SubscriptionId = 'bad' }
    Assert 'an invalid subscription id is refused before any az call' ($Failure -match 'SubscriptionId' -and $global:Live.Calls.Count -eq 0) "$Failure | $($global:Live.Calls -join '; ')"

    Reset-Live; Invoke-Verifier @{ ResourceGroup = 'rg&calc' }
    Assert 'a resource group that cmd.exe would re-read is refused before any az call' ($Failure -match 'ResourceGroup' -and $global:Live.Calls.Count -eq 0) $Failure

    Reset-Live
    $saved = $env:AZURE_CONFIG_DIR; $env:AZURE_CONFIG_DIR = ''
    try { Invoke-Verifier @{ UseCurrentAzLogin = $null } } finally { $env:AZURE_CONFIG_DIR = $saved }
    Assert 'the default Azure CLI profile is refused unless -UseCurrentAzLogin is passed' ($Failure -match 'AZURE_CONFIG_DIR' -and $global:Live.Calls.Count -eq 0) $Failure

    Reset-Live; Invoke-Verifier
    $order = @((At '^az group exists'), (At '^az ad group create --display-name claude-p98-std'), (At '^az ad group member add'),
        (At '^installer rg-p98-live p98live BasicV2 projection yes=True claude-p98-std claude-p98-prm'), (At 'entitlement-source'),
        (At '^az apim nv update .*entitlement-cache-seconds --value 60'), (At '^request https://apim-p98live\.azure-api\.net/claude/v1/messages claude-haiku-4-5 auth=True'),
        (At '^az ad group member remove'), (At '^sync rg-p98-live apim-p98live -User 00000000-0000-4000-8000-0000000000aa'))
    Assert 'groups and membership come before the installer; the switch is checked and the cache shortened before the first request' (-not $Failure -and $Exit -ne 1 -and ($order -notcontains -1) -and
        (@(0..($order.Count - 2) | Where-Object { $order[$_] -lt $order[$_ + 1] }).Count -eq ($order.Count - 1))) "$Failure | $($order -join ',') | $($global:Live.Calls -join ' ; ')"
    $requests = @($global:Live.Calls | Where-Object { $_ -like 'request *' })
    $syncs = @($global:Live.Calls | Where-Object { $_ -like 'sync *' })
    Assert 'requests see 200, then 403 after the removal and its targeted sync, then 200 after the re-add and its sync' ($Output -match '"step":\s*"entitled request"' -and
        $Output -match '"step":\s*"removed, then targeted sync"' -and $Output -match '"step":\s*"re-added, then targeted sync"' -and $Output -notmatch '"ok":\s*false' -and
        $syncs.Count -eq 2 -and $requests.Count -ge 3) $Output
    $teardownAt = At '^az role assignment delete --ids /assignment/one'
    Assert 'teardown deletes the gateway identity''s Foundry role assignment by id, the resolver app, the resource group and the groups it created' ($teardownAt -gt (At '^sync ') -and
        (At '^az role assignment list --assignee 00000000-0000-4000-8000-0000000000c1 --scope /subscriptions/x/resourceGroups/rg-ai/providers/Microsoft\.CognitiveServices/accounts/ai') -ge 0 -and
        (At '^az ad app delete --id 00000000-0000-4000-8000-0000000000d1') -ge 0 -and (At '^az group delete --name rg-p98-live --yes --no-wait') -ge 0 -and
        @($global:Live.Calls | Where-Object { $_ -like 'az ad group delete *' }).Count -eq 2) ($global:Live.Calls -join ' ; ')

    Reset-Live -Source 'named-value'; Invoke-Verifier
    Assert 'a gateway the installer left on named values fails the run, sends no request, and is still torn down' ($Exit -eq 1 -and $Output -match '"step":\s*"switch"' -and
        (At '^request ') -lt 0 -and (At '^az group delete --name rg-p98-live') -ge 0) "$Exit | $($global:Live.Calls -join ' ; ')"

    Reset-Live -GroupExists $true; Invoke-Verifier
    Assert 'an existing resource group stops the run and is not deleted' ($Exit -eq 1 -and $Output -match 'already exists' -and (At '^installer ') -lt 0 -and (At '^az group delete') -lt 0) "$Exit | $($global:Live.Calls -join ' ; ')"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count live projection assertion(s) passed." -ForegroundColor Green
exit 0
