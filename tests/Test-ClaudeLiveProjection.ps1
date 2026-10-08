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
$work = Join-Path $root ('.live-verifier-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$installerStub = Join-Path $work 'Install-ClaudeGateway.ps1'
$syncStub = Join-Path $work 'Sync-ClaudeAccess.ps1'
# Stub scripts in a repository-local scratch folder: the verifier takes their paths, so no repository file is replaced.
[IO.File]::WriteAllText($installerStub, (@(
    'param($SubscriptionId, $FoundryAccount, $FoundryResourceGroup, $ResourceGroup, $Location, $NamePrefix, $Sku, $EntitlementStore, [switch]$Yes, $StandardGroup, $PremiumGroup, $ProjectionSyncInterval)'
    '$global:Live.Calls.Add("installer $ResourceGroup $NamePrefix $Sku EntitlementStore=$EntitlementStore yes=$Yes $StandardGroup $PremiumGroup interval=$ProjectionSyncInterval")'
    '$global:Live.Synced = $global:Live.Member'
) -join "`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($syncStub, (@(
    'param($ResourceGroup, $ApimName, $User, [switch]$AllowEmpty, [switch]$AllowEmptyStandard, [switch]$AllowEmptyPremium)'
    'if ($global:Live.SyncFails) { throw "sync failed by fixture" }'
    '$global:Live.Calls.Add("sync $ResourceGroup $ApimName -User $User source=$($global:Live.Source) member=$($global:Live.Member) AllowEmptyStandard=$AllowEmptyStandard")'
    'if (-not $User) {'
    '    $global:Live.EntitlementGroups = ''standard=00000000-0000-4000-8000-0000000000b1,premium=00000000-0000-4000-8000-0000000000b2'''
    '    if ($global:Live.SyncMentionsOtherStore) { Write-Host "projection should not be named" } else { Write-Host "Syncing Entra group membership -> APIM named values" }'
    '    $global:Live.Synced = $global:Live.Member'
    '    return'
    '}'
    'if ($global:Live.Source -eq ''named-value'' -and -not $global:Live.Member -and -not $AllowEmpty -and -not $AllowEmptyStandard) {'
    '    Write-Warning "claude-p98-std resolved to 0 members, but ''allow-standard'' currently entitles 1. Not overwriting."'
    '    $tier = $(if ($global:Live.Synced) { ''standard'' } else { ''none'' })'
    '}'
    'else { $tier = if ($global:Live.AlwaysTier) { [string]$global:Live.AlwaysTier } elseif ($global:Live.SyncTiers.Count) { $next = [string]$global:Live.SyncTiers[0]; $global:Live.SyncTiers.RemoveAt(0); $next } else { if ($global:Live.Member) { ''standard'' } else { ''none'' } } }'
    '$global:Live.Synced = ($tier -eq ''standard'')'
    'if ($global:Live.OmitTierText) { return }'
    'Write-Host "Developer tier as written: $tier"'
    '[pscustomobject]@{ published_tier = $tier; user = $User }'
) -join "`n"), [Text.UTF8Encoding]::new($false))
$updateStub = Join-Path $work 'Update-ClaudeGateway.ps1'
# The update stub: a plan returns the 0004 plan the global state describes; an apply with its fingerprint switches.
[IO.File]::WriteAllText($updateStub, (@(
    'param($ResourceGroup, $ApimName, [switch]$Apply, $ApprovedPlanFingerprint)'
    'if (-not $Apply) {'
    '    $global:Live.Calls.Add("update plan $ResourceGroup $ApimName")'
    '    ''[0004-entitlement-projection] review line from the stub'''
    '    $plan = [pscustomobject]@{ Step = ''0004-entitlement-projection''; Actions = @($global:Live.UpdateActions); Data = @{ Blocked = $global:Live.UpdateBlocked } }'
    '    return [pscustomobject]@{ Plans = @($plan); Fingerprint = (''f'' * 64); SnapshotPath = '''' }'
    '}'
    '$global:Live.Calls.Add("update apply $ResourceGroup $ApimName fp=$ApprovedPlanFingerprint")'
    'if ($ApprovedPlanFingerprint -ne (''f'' * 64)) { throw ''Approved plan fingerprint does not match.'' }'
    'if ($global:Live.UpdateApplyCreatesResolverApp -and -not @($global:Live.AppListResults).Count) { $global:Live.AppListResults = @(@{ appId = ''00000000-0000-4000-8000-0000000000d1''; displayName = ''claude-projection-resolver-p98live'' }) }'
    'if ($global:Live.UpdateApplyFailsAfterApp) { throw ''update apply failed after resolver app creation'' }'
    '$global:Live.Source = ''projection''; $global:Live.EntitlementGroups = ''standard=00000000-0000-4000-8000-0000000000b1,premium=00000000-0000-4000-8000-0000000000b2'''
) -join "`n"), [Text.UTF8Encoding]::new($false))
$user = '00000000-0000-4000-8000-0000000000aa'
$sub = '00000000-0000-4000-8000-000000000001'
$appId = '00000000-0000-4000-8000-0000000000d1'
$otherAppId = '00000000-0000-4000-8000-0000000000d2'
function Reset-Live([string]$Source = 'projection', [bool]$ResourceGroupExists = $false, [string]$AccountId = $sub) {
    $global:Live = @{
        Calls = [Collections.Generic.List[string]]::new()
        Member = $false
        Synced = $false
        Source = $Source
        ResourceGroupExists = $ResourceGroupExists
        ExistingGroups = @{}
        CreatedGroups = @{}
        AccountId = $AccountId
        AccountSetFails = $false
        ResolverExists = $false
        ExistingResolverId = $appId
        ResolverAudience = "api://$appId"
        AppDisplayNames = @{ $appId = 'claude-projection-resolver-p98live'; $otherAppId = 'claude-projection-resolver-p98live-other' }
        DeleteFailures = @{}
        InitialSubscription = '00000000-0000-4000-8000-000000000099'
        UpdateActions = @('Create Microsoft.DocumentDB/databaseAccounts cosmos-p98live')
        UpdateBlocked = $false
        EntitlementGroups = ''
        AppListResults = @()
        AppListFails = $false
        AppListRaw = ''
        UpdateApplyCreatesResolverApp = $false
        UpdateApplyFailsAfterApp = $false
        SyncFails = $false
        OmitTierText = $false
        SyncMentionsOtherStore = $false
        SyncTiers = [Collections.Generic.List[string]]::new()
        AlwaysTier = ''
    }
}
function Add-SubscriptionCheck([string]$line) {
    if ($line -match '^(group|apim|role assignment|cognitiveservices account) ' -and $line -notmatch '(?:^| )--subscription(?: |$)') {
        $global:Live.Calls.Add("missing-subscription $line")
    }
}
function az {
    $line = $args -join ' '
    Add-SubscriptionCheck $line
    $global:Live.Calls.Add("az $line")
    $global:LASTEXITCODE = 0
    switch -Regex ($line) {
        '^account show --query id -o tsv$' { return $global:Live.InitialSubscription }
        '^account set --subscription (\S+)$' { if ($global:Live.AccountSetFails) { $global:LASTEXITCODE = 7; return 'cannot select subscription' }; return }
        '^account show -o json$' { return (@{ id = $global:Live.AccountId; user = @{ name = 'admin@contoso.example' } } | ConvertTo-Json) }
        '^group exists --name (\S+) --subscription (\S+)$' { return $(if ($global:Live.ResourceGroupExists) { 'true' } else { 'false' }) }
        '^ad app list --filter displayName eq ''claude-projection-resolver-([^'']+)'' --query \[\]\.appId -o tsv$' { if ($global:Live.ResolverExists) { return $global:Live.ExistingResolverId }; return '' }
        '^ad app list --display-name ([^ ]+) --query \[\]\.\{appId:appId,displayName:displayName\} -o json$' {
            if ($global:Live.AppListFails) { $global:LASTEXITCODE = 7; return 'app list failed' }
            if ($global:Live.AppListRaw) { return $global:Live.AppListRaw }
            return ($global:Live.AppListResults | ConvertTo-Json -Compress)
        }
        '^ad group list --filter displayName eq ''([^'']+)'' --query \[\]\.id -o tsv$' { $name = $Matches[1]; if ($global:Live.ExistingGroups.ContainsKey($name)) { return $global:Live.ExistingGroups[$name] }; return '' }
        '^ad group create --display-name (\S+) --mail-nickname \S+ --query id -o tsv$' { $name = $Matches[1]; $id = '00000000-0000-4000-8000-0000000000' + $(if ($global:Live.CreatedGroups.Count -eq 0) { 'b1' } else { 'b2' }); $global:Live.CreatedGroups[$name] = $id; return $id }
        '^ad signed-in-user show --query id -o tsv$' { return $user }
        '^ad group member check' { return $(if ($global:Live.Member) { 'true' } else { 'false' }) }
        '^ad group member add' { $global:Live.Member = $true; return }
        '^ad group member remove' { $global:Live.Member = $false; return }
        '^apim nv show .*--named-value-id entitlement-source .* --subscription ' { return $global:Live.Source }
        '^apim nv show .*--named-value-id entitlement-projection-prefix .* --subscription ' { return 'p98live' }
        '^apim nv show .*--named-value-id entitlement-resolver-audience .* --subscription ' { if (-not $global:Live.ResolverAudience) { $global:LASTEXITCODE = 3; return 'not found' }; return $global:Live.ResolverAudience }
        '^apim nv show .*--named-value-id entitlement-groups .* --subscription ' { return $global:Live.EntitlementGroups }
        '^apim nv show .*--named-value-id models-standard .* --subscription ' { return ',claude-haiku-4-5,claude-sonnet-5,' }
        '^apim nv update .*--named-value-id entitlement-cache-seconds --value 60 --subscription ' { return }
        '^apim show .*--query gatewayUrl .* --subscription ' { return 'https://apim-p98live.azure-api.net' }
        '^apim show .*--query identity\.principalId .* --subscription ' { return '00000000-0000-4000-8000-0000000000c1' }
        '^account get-access-token' { return 'offline-token' }
        '^cognitiveservices account show .*--query id .* --subscription ' { return '/subscriptions/x/resourceGroups/rg-ai/providers/Microsoft.CognitiveServices/accounts/ai' }
        '^role assignment list .*--subscription ' { return '/assignment/one' }
        '^role assignment delete --ids /assignment/one --subscription ' { if ($global:Live.DeleteFailures['role']) { $global:LASTEXITCODE = 8; return 'delete role failed' }; return }
        '^ad app show --id ([0-9a-f-]+) --query displayName -o tsv$' { return $global:Live.AppDisplayNames[$Matches[1]] }
        '^ad app delete --id ([0-9a-f-]+)$' { if ($global:Live.DeleteFailures['app']) { $global:LASTEXITCODE = 8; return 'delete app failed' }; return }
        '^group delete --name rg-p98-live --yes --no-wait --subscription ' { if ($global:Live.DeleteFailures['group']) { $global:LASTEXITCODE = 8; return 'delete rg failed' }; return }
        '^ad group delete --group ' { if ($global:Live.DeleteFailures['adgroup']) { $global:LASTEXITCODE = 8; return 'delete group failed' }; return }
    }
    $global:LASTEXITCODE = 9
    return "unexpected az $line"
}
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $Body, [switch]$SkipHttpErrorCheck, $TimeoutSec)
    $model = ($Body | ConvertFrom-Json).model
    $global:Live.Calls.Add("request $Uri $model auth=$($Headers.Authorization -eq 'Bearer offline-token')")
    [pscustomobject]@{ StatusCode = $(if ($global:Live.Synced) { 200 } else { 403 }) }
}
function Start-Sleep { param($Seconds) }
function Invoke-Verifier([hashtable]$Extra = @{}, [switch]$WithHost) {
    $params = @{ SubscriptionId = $sub; Location = 'eastus2'; FoundryAccount = 'ai'; FoundryResourceGroup = 'rg-ai'; ResourceGroup = 'rg-p98-live'; NamePrefix = 'p98live'
        StandardGroup = 'claude-p98-std'; PremiumGroup = 'claude-p98-prm'; UseCurrentAzLogin = $true; Teardown = $true; InstallerPath = $installerStub; SyncAccessPath = $syncStub }
    foreach ($k in $Extra.Keys) { if ($null -eq $Extra[$k]) { $params.Remove($k) } else { $params[$k] = $Extra[$k] } }
    $script:Failure = ''
    $global:LASTEXITCODE = 0
    $script:Output = try { if ($WithHost) { & $scriptPath @params 6>&1 | Out-String } else { & $scriptPath @params 6>$null | Out-String } } catch { $script:Failure = $_.Exception.Message; '' }
    $script:Exit = $LASTEXITCODE
}
function At([string]$Pattern) { for ($i = 0; $i -lt $global:Live.Calls.Count; $i++) { if ($global:Live.Calls[$i] -match $Pattern) { return $i } }; return -1 }
function AtNth([string]$Pattern, [int]$N) {
    $seen = 0
    for ($i = 0; $i -lt $global:Live.Calls.Count; $i++) {
        if ($global:Live.Calls[$i] -match $Pattern) {
            $seen++
            if ($seen -eq $N) { return $i }
        }
    }
    return -1
}
function CountCalls([string]$Pattern) { @($global:Live.Calls | Where-Object { $_ -match $Pattern }).Count }

try {
    Reset-Live; Invoke-Verifier @{ SubscriptionId = 'bad' }
    Assert 'an invalid subscription id is refused before any az call' ($Failure -match 'SubscriptionId' -and $global:Live.Calls.Count -eq 0) "$Failure | $($global:Live.Calls -join '; ')"

    Reset-Live; Invoke-Verifier @{ ResourceGroup = 'rg&calc' }
    Assert 'a resource group that cmd.exe would re-read is refused before any az call' ($Failure -match 'ResourceGroup' -and $global:Live.Calls.Count -eq 0) $Failure

    Reset-Live; Invoke-Verifier @{ ResourceGroup = "rg-p98-live`n" }
    Assert 'a value with a trailing newline is refused before any az call' ($Failure -match 'ResourceGroup' -and $global:Live.Calls.Count -eq 0) "$Failure | $($global:Live.Calls -join '; ')"

    Reset-Live
    $saved = $env:AZURE_CONFIG_DIR; $env:AZURE_CONFIG_DIR = ''
    try { Invoke-Verifier @{ UseCurrentAzLogin = $null } } finally { $env:AZURE_CONFIG_DIR = $saved }
    Assert 'an empty Azure CLI profile is refused unless -UseCurrentAzLogin is passed' ($Failure -match 'AZURE_CONFIG_DIR' -and $global:Live.Calls.Count -eq 0) $Failure

    Reset-Live
    $saved = $env:AZURE_CONFIG_DIR; $env:AZURE_CONFIG_DIR = Join-Path $HOME '.azure'
    try { Invoke-Verifier @{ UseCurrentAzLogin = $null } } finally { $env:AZURE_CONFIG_DIR = $saved }
    Assert 'the default Azure CLI profile path is refused before any az call unless -UseCurrentAzLogin is passed' ($Failure -match 'default Azure CLI profile' -and $global:Live.Calls.Count -eq 0) "$Failure | $($global:Live.Calls -join '; ')"

    Reset-Live; Invoke-Verifier
    $order = @((At '^az group exists'), (At '^az ad app list --filter displayName eq'), (At '^az ad group create --display-name claude-p98-std'), (At '^az ad group member add'),
        (At '^installer rg-p98-live p98live BasicV2 EntitlementStore= yes=True claude-p98-std claude-p98-prm'), (At 'entitlement-source'),
        (At '^az apim nv update .*entitlement-cache-seconds --value 60'), (At '^request https://apim-p98live\.azure-api\.net/claude/v1/messages claude-haiku-4-5 auth=True'),
        (At '^az ad group member remove'), (At '^sync rg-p98-live apim-p98live -User 00000000-0000-4000-8000-0000000000aa'))
    Assert 'groups and membership come before the installer; the installer uses its default store; the switch is checked and the cache shortened before the first request' (-not $Failure -and $Exit -ne 1 -and ($order -notcontains -1) -and
        (@(0..($order.Count - 2) | Where-Object { $order[$_] -lt $order[$_ + 1] }).Count -eq ($order.Count - 1))) "$Failure | $($order -join ',') | $($global:Live.Calls -join ' ; ')"
    $requests = @($global:Live.Calls | Where-Object { $_ -like 'request *' })
    $syncs = @($global:Live.Calls | Where-Object { $_ -like 'sync *' })
    Assert 'requests see 200, then 403 after the removal and its targeted sync, then 200 after the re-add and its sync' ($Output -match '"step":\s*"entitled request"' -and
        $Output -match '"step":\s*"removed, then targeted sync"' -and $Output -match '"step":\s*"re-added, then targeted sync"' -and $Output -notmatch '"ok":\s*false' -and
        $syncs.Count -eq 2 -and $requests.Count -ge 3) $Output
    Assert 'teardown deletes exactly the resolver app id recorded in entitlement-resolver-audience, the gateway role assignment, the resource group and the run groups' ((At '^az apim nv show .*entitlement-resolver-audience') -ge 0 -and
        (At "^az ad app delete --id $appId") -ge 0 -and (At "^az ad app delete --id $otherAppId") -lt 0 -and
        (At '^az role assignment list --assignee 00000000-0000-4000-8000-0000000000c1 --scope /subscriptions/x/resourceGroups/rg-ai/providers/Microsoft\.CognitiveServices/accounts/ai .*--subscription') -ge 0 -and
        (At '^az role assignment delete --ids /assignment/one .*--subscription') -ge 0 -and (At '^az group delete --name rg-p98-live --yes --no-wait .*--subscription') -ge 0 -and
        @($global:Live.Calls | Where-Object { $_ -like 'az ad group delete *' }).Count -eq 2) ($global:Live.Calls -join ' ; ')
    Assert 'teardown never lists resolver apps by display-name' ((At '^az ad app list --display-name') -lt 0) ($global:Live.Calls -join ' ; ')
    Assert 'every subscription-scoped az call carries --subscription' ((At '^missing-subscription ') -lt 0) ($global:Live.Calls -join ' ; ')
    Assert 'with -UseCurrentAzLogin the originally selected subscription is restored at the end' ((At '^az account show --query id -o tsv') -eq 0 -and (At '^az account set --subscription 00000000-0000-4000-8000-000000000099$') -gt (At '^az group delete')) ($global:Live.Calls -join ' ; ')

    Reset-Live -Source 'named-value'; Invoke-Verifier
    Assert 'a gateway the installer left on named values fails the run, sends no request, and is still torn down' ($Exit -eq 1 -and $Output -match '"step":\s*"switch"' -and
        (At '^request ') -lt 0 -and (At '^az group delete --name rg-p98-live') -ge 0) "$Exit | $($global:Live.Calls -join ' ; ')"

    # P104: the sync job's interval reaches the installer; without it the installer's default (2h) applies.
    Reset-Live; Invoke-Verifier @{ ProjectionSyncInterval = '30m' }
    Assert '-ProjectionSyncInterval reaches the installer' ((At '^installer rg-p98-live p98live BasicV2 .* interval=30m$') -ge 0 -and (At '^installer .* interval=$') -lt 0) ($global:Live.Calls -join ' ; ')
    Reset-Live; Invoke-Verifier
    Assert 'without -ProjectionSyncInterval the installer gets none, so its default applies' ((At '^installer rg-p98-live p98live BasicV2 .* interval=$') -ge 0) ($global:Live.Calls -join ' ; ')
    Reset-Live; Invoke-Verifier @{ ProjectionSyncInterval = '2h;calc' }
    Assert 'a -ProjectionSyncInterval outside the list is refused before any Azure call' ($Failure -match [regex]::Escape("-ProjectionSyncInterval '2h;calc' is not in the accepted form") -and $global:Live.Calls.Count -eq 0) "$Failure | $($global:Live.Calls -join ' ; ')"

    # P100: -MigrateWithUpdate installs on named values and moves the gateway with the update's plan and apply alone.
    Reset-Live -Source 'named-value'; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    $order = @((At '^installer rg-p98-live p98live BasicV2 EntitlementStore=named-value yes=True claude-p98-std claude-p98-prm'), (At 'entitlement-source'),
        (At '^request https://apim-p98live\.azure-api\.net/claude/v1/messages claude-haiku-4-5'), (At '^sync rg-p98-live apim-p98live -User  source=named-value member=True'),
        (At '^az apim nv show .*entitlement-groups'), (At '^az ad group member remove'), (At '^sync rg-p98-live apim-p98live -User 00000000-0000-4000-8000-0000000000aa source=named-value member=False'),
        (AtNth '^az ad group member add' 2), (At '^sync rg-p98-live apim-p98live -User 00000000-0000-4000-8000-0000000000aa source=named-value member=True'), (At '^update plan rg-p98-live apim-p98live$'),
        (At "^update apply rg-p98-live apim-p98live fp=$('f' * 64)$"), (AtNth '^az apim nv show .*entitlement-groups' 2),
        (At '^az apim nv update .*entitlement-cache-seconds --value 60'), (AtNth '^az ad group member remove' 2))
    Assert 'with -MigrateWithUpdate: named values record groups, prove removal and re-add with -User, then the update plans and applies with its fingerprint and the projection serves' (
        -not $Failure -and $Exit -ne 1 -and ($order -notcontains -1) -and (@(0..($order.Count - 2) | Where-Object { $order[$_] -lt $order[$_ + 1] }).Count -eq ($order.Count - 1)) -and
        $Output -match '"step":\s*"entitled request on named values"' -and $Output -match '"step":\s*"update plan"' -and $Output -match '"step":\s*"update apply"' -and
        $Output -match '"step":\s*"named-value groups recorded"' -and $Output -match '"step":\s*"named-value removed sync lag"' -and $Output -match '"step":\s*"named-value re-added sync lag"' -and
        $Output -match '"step":\s*"groups recorded"' -and $Output -match '"step":\s*"re-added, then targeted sync"' -and $Output -notmatch '"ok":\s*false') "$Failure | $($order -join ',') | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.SyncTiers.Add('standard'); $global:Live.SyncTiers.Add('none'); $global:Live.SyncTiers.Add('none'); $global:Live.SyncTiers.Add('standard'); Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate stale named-value tiers are retried until none then standard and the lag seconds are recorded' ($Exit -ne 1 -and
        (CountCalls '^sync rg-p98-live apim-p98live -User 00000000-0000-4000-8000-0000000000aa source=named-value') -eq 4 -and
        $Output -match 'from membership removal to tier none \(U157\)' -and $Output -match 'from membership add to tier standard \(U157\)') "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.Synced = $true; $global:Live.Member = $false
    $guardOutput = @(& $syncStub -ResourceGroup rg-p98-live -ApimName apim-p98live -User $user *>&1)
    $guardTier = @($guardOutput | Where-Object { $_ -and $_.PSObject.Properties['published_tier'] } | Select-Object -Last 1).published_tier
    $guardText = (@($guardOutput) | ForEach-Object { if ($_ -is [Management.Automation.WarningRecord]) { $_.Message } elseif ($_ -is [Management.Automation.InformationRecord]) { [string]$_.MessageData } elseif ($_ -is [string]) { $_ } }) -join "`n"
    Assert 'the named-value sync stub models the empty-tier guard without AllowEmptyStandard' ($guardTier -eq 'standard' -and $guardText -match 'resolved to 0 members.*Not overwriting') "tier=$guardTier output=$guardText"
    Reset-Live -Source 'named-value'; $global:Live.AlwaysTier = 'standard'; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub; ChangeWaitSeconds = 60; PollSeconds = 30 }
    Assert 'with -MigrateWithUpdate a named-value tier that never catches up fails with the last printed tier' ($Exit -eq 1 -and $Output -match 'last printed tier standard' -and
        (At '^update plan') -lt 0 -and (At '^az group delete --name rg-p98-live') -ge 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.OmitTierText = $true; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a named-value -User sync that does not print the written tier stops before the update' ($Exit -eq 1 -and $Output -match 'printed no developer tier as written' -and
        (At '^update plan') -lt 0 -and (At '^az group delete --name rg-p98-live') -ge 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.SyncFails = $true; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a named-value sync failure stops before the update and tears down' ($Exit -eq 1 -and $Output -match 'sync failed by fixture' -and
        (At '^update plan') -lt 0 -and (At '^az group delete --name rg-p98-live') -ge 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.SyncFails = $true; $global:Live.ResolverAudience = ''; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a stop before update has no resolver app leftover when no resolver audience exists' ($Exit -eq 1 -and $Output -match 'sync failed by fixture' -and
        $Output -notmatch 'Resolver app was not deleted because entitlement-resolver-audience could not be read') "$Exit | $Output"
    Reset-Live -Source 'named-value'; $global:Live.ResolverAudience = ''; $global:Live.UpdateApplyCreatesResolverApp = $true; $global:Live.UpdateApplyFailsAfterApp = $true; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate an apply failure after resolver app creation deletes the exact-name app by display name' ($Exit -eq 1 -and $Output -match 'update apply failed after resolver app creation' -and
        (At '^az ad app list --display-name claude-projection-resolver-p98live ') -ge 0 -and (At "^az ad app delete --id $appId$") -ge 0 -and
        $Output -notmatch 'Resolver app was not deleted') "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.ResolverAudience = ''; $global:Live.UpdateApplyCreatesResolverApp = $true; $global:Live.UpdateApplyFailsAfterApp = $true
    $global:Live.AppListResults = @(@{ appId = $appId; displayName = 'claude-projection-resolver-p98live' }, @{ appId = $otherAppId; displayName = 'claude-projection-resolver-p98live' })
    Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate two exact-name resolver apps are reported as leftovers with both ids' ($Exit -eq 1 -and $Output -match $appId -and $Output -match $otherAppId -and
        $Output -match 'az ad app delete --id' -and (At "^az ad app delete --id $appId$") -lt 0 -and (At "^az ad app delete --id $otherAppId$") -lt 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.ResolverAudience = ''; $global:Live.UpdateApplyCreatesResolverApp = $true; $global:Live.UpdateApplyFailsAfterApp = $true
    $global:Live.AppListResults = @(@{ appId = $otherAppId; displayName = 'claude-projection-resolver-p98live-old' })
    Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a prefix-only resolver app name is not deleted and not reported as this run leftover' ($Exit -eq 1 -and
        (At "^az ad app delete --id $otherAppId$") -lt 0 -and $Output -notmatch $otherAppId -and $Output -notmatch 'Resolver app was not deleted') "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.ResolverAudience = ''; $global:Live.UpdateApplyFailsAfterApp = $true; $global:Live.AppListFails = $true
    Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a failed resolver app lookup is reported and resource and group teardown still run' ($Exit -eq 1 -and
        $Output -match 'az ad app list --display-name claude-projection-resolver-p98live' -and $Output -match 'az ad app delete --id <appId>' -and
        (At '^az group delete --name rg-p98-live') -ge 0 -and @($global:Live.Calls | Where-Object { $_ -like 'az ad group delete *' }).Count -eq 2) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.ResolverAudience = ''; $global:Live.UpdateApplyFailsAfterApp = $true; $global:Live.AppListRaw = 'not-json'
    Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a malformed resolver app lookup is reported and resource and group teardown still run' ($Exit -eq 1 -and
        $Output -match 'Resolver app lookup by display name' -and $Output -match 'az ad app list --display-name claude-projection-resolver-p98live' -and
        (At '^az group delete --name rg-p98-live') -ge 0 -and @($global:Live.Calls | Where-Object { $_ -like 'az ad group delete *' }).Count -eq 2) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.ResolverAudience = ''; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a missing resolver audience and no app name match reports no resolver leftover after the update ran' ($Exit -eq 0 -and $Output -notmatch 'Resolver app was not deleted' -and
        (At '^update apply') -ge 0 -and (At '^az ad app list --display-name claude-projection-resolver-p98live ') -ge 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.SyncMentionsOtherStore = $true; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate the named-value full sync output must not name the projection store' ($Exit -eq 1 -and $Output -match 'named-value sync output named another store' -and
        (At '^update plan') -lt 0) "$Exit | $Output"
    Reset-Live -Source 'named-value'; $global:Live.UpdateBlocked = $true; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a blocked plan fails the run, applies nothing, and is still torn down' ($Exit -eq 1 -and $Output -match '"step":\s*"update plan"' -and
        (At '^update apply') -lt 0 -and (At '^az group delete --name rg-p98-live') -ge 0) "$Exit | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; $global:Live.UpdateActions = @(); Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub }
    Assert 'with -MigrateWithUpdate a plan with no move fails the run and applies nothing' ($Exit -eq 1 -and (At '^update apply') -lt 0) "$Exit | $($global:Live.Calls -join ' ; ')"
    Reset-Live -Source 'named-value'; Invoke-Verifier @{ MigrateWithUpdate = $true; UpdatePath = $updateStub } -WithHost
    Assert 'with -MigrateWithUpdate the update''s plan review is printed, so the run''s log holds the resources, cost and time it planned' ($Output -match '\[0004-entitlement-projection\] review line from the stub' -and $Exit -ne 1) "$Exit | $Output"

    Reset-Live -ResourceGroupExists $true; Invoke-Verifier
    Assert 'an existing resource group stops the run, names the remedy, and deletes nothing' ($Exit -eq 1 -and $Output -match 'already exists' -and $Output -match 'Remedy: omit -ResourceGroup' -and
        (At '^installer ') -lt 0 -and (At '^az role assignment delete') -lt 0 -and (At '^az ad app delete') -lt 0 -and (At '^az ad app list') -lt 0 -and
        (At '^az group delete') -lt 0 -and (At '^az ad group create') -lt 0 -and (At '^az ad group delete') -lt 0) "$Exit | $($global:Live.Calls -join ' ; ')"

    Reset-Live; $global:Live.AccountSetFails = $true; Invoke-Verifier
    Assert 'az account set failure stops the run and deletes nothing' ($Exit -eq 1 -and (At '^az role assignment delete') -lt 0 -and (At '^az ad app delete') -lt 0 -and
        (At '^az group delete') -lt 0 -and (At '^az ad group delete') -lt 0) "$Exit | $($global:Live.Calls -join ' ; ')"

    Reset-Live; $global:Live.ResolverExists = $true; Invoke-Verifier
    Assert 'an exact existing resolver app is refused before any group or resource group is created' ($Exit -eq 1 -and $Output -match 'claude-projection-resolver-p98live' -and $Output -match 'Nothing was created' -and
        (At '^az ad group create') -lt 0 -and (At '^az group delete') -lt 0 -and (At '^installer ') -lt 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"

    Reset-Live; $global:Live.DeleteFailures['app'] = $true; Invoke-Verifier
    Assert 'a teardown deletion failure makes teardown not ok and exits non-zero with the removal command' ($Exit -eq 1 -and $Output -match '"step":\s*"teardown"' -and $Output -match '"ok":\s*false' -and
        $Output -match 'az ad app delete --id 00000000-0000-4000-8000-0000000000d1') "$Exit | $Output"

    Reset-Live; Invoke-Verifier @{ StandardGroup = $null; PremiumGroup = $null; ResourceGroup = 'rg-p98-live'; NamePrefix = 'p98live' }
    $firstGroups = @($global:Live.CreatedGroups.Keys | Sort-Object)
    Reset-Live; Invoke-Verifier @{ StandardGroup = $null; PremiumGroup = $null; ResourceGroup = 'rg-p98-live'; NamePrefix = 'p98live' }
    $secondGroups = @($global:Live.CreatedGroups.Keys | Sort-Object)
    Assert 'default group names are run-specific across runs' ($firstGroups.Count -eq 2 -and $secondGroups.Count -eq 2 -and ($firstGroups -join ',') -ne ($secondGroups -join ',') -and
        (($firstGroups + $secondGroups) -match '^claude-live-p98-[0-9a-f]{8}-(standard|premium)$').Count -eq 4) "first=$($firstGroups -join ',') second=$($secondGroups -join ',')"

    Reset-Live; $global:Live.ExistingGroups['claude-p98-std'] = '00000000-0000-4000-8000-0000000000e1'; Invoke-Verifier
    Assert 'passing an existing tier group is refused before anything is created or modified' ($Exit -eq 1 -and $Output -match 'omit -StandardGroup and -PremiumGroup' -and
        (At '^az ad group create') -lt 0 -and (At '^az ad group member add') -lt 0 -and (At '^az ad group member remove') -lt 0 -and (At '^installer ') -lt 0 -and (At '^az group delete') -lt 0) "$Exit | $Output | $($global:Live.Calls -join ' ; ')"

    Reset-Live -AccountId '00000000-0000-4000-8000-000000000002'; Invoke-Verifier
    Assert 'a profile on another subscription stops the run before any write and names the sign-in remedy' ($Exit -eq 1 -and $Output -match 'not 00000000-0000-4000-8000-000000000001' -and $Output -match 'Remedy: .*az login' -and
        (At '^az ad group create') -lt 0 -and (At '^installer ') -lt 0 -and (At '^az group delete') -lt 0) "$Exit | $Output"
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count live projection assertion(s) passed." -ForegroundColor Green
exit 0
