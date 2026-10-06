param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = & $Action }
    catch { $script:CapturedError = $_.Exception.Message }
}

Write-Host 'P97 projection sync scripts'
$script:p97SyncWork = Join-Path ([IO.Path]::GetTempPath()) ('p97-sync-scripts-' + [guid]::NewGuid().ToString('N'))

. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
$calls = [Collections.Generic.List[string]]::new()
function Invoke-ClaudeNetworkAz {
    param([string[]]$Arguments)
    $line = $Arguments -join ' '
    $calls.Add($line)
    if ($line -like 'ad sp show*') { throw 'not found' }
    if ($line -like 'ad sp create*') { return [pscustomobject]@{ appId = $Arguments[-1] } }
    if ($line -like 'ad app create*') { return [pscustomobject]@{ appId = '00000000-0000-4000-8000-000000000086' } }
    if ($line -like 'ad app update*') { return [pscustomobject]@{} }
    throw "unexpected az helper call: $line"
}

Capture { Confirm-ClaudeProjectionResolverServicePrincipal -AppId '00000000-0000-4000-8000-000000000086' }
Assert 'missing resolver service principal is created' (-not $CapturedError -and ($calls -join "`n") -match 'ad sp create --id 00000000-0000-4000-8000-000000000086') $CapturedError
$calls.Clear()
Capture { New-ClaudeProjectionResolverApp -NamePrefix p97fixture }
Assert 'new resolver app confirms its service principal' (-not $CapturedError -and ($calls -join "`n") -match 'ad sp create --id 00000000-0000-4000-8000-000000000086') $CapturedError
$calls.Clear()
Capture { Confirm-ClaudeProjectionResolverServicePrincipal -AppId 'not-a-guid' }
Assert 'invalid resolver app id is rejected before az' ($CapturedError -match 'GUID' -and $calls.Count -eq 0) $CapturedError

function Invoke-TargetedExportFixture {
    param([string]$User, [string[]]$BusinessUnitGroups = @(), [switch]$WhatIf)
    $work = $script:p97SyncWork
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $snapshot = Join-Path $work ("snapshot-$([guid]::NewGuid().ToString('N')).json")
    $global:P97SyncFixtureCalls = [Collections.Generic.List[string]]::new()
    $global:P97SyncFixtureBatches = [Collections.Generic.List[int]]::new()
    function az {
        $words = @($args); $line = $words -join ' '; $global:P97SyncFixtureCalls.Add("az $line"); $global:LASTEXITCODE = 0
        if ($line -like 'account show*') { return '{"id":"00000000-0000-4000-8000-000000000001","tenantId":"00000000-0000-4000-8000-000000000085","user":{"name":"fixture@example.invalid"}}' }
        if ($line -like 'account get-access-token*') { return '{"accessToken":"offline-token"}' }
        throw "unexpected az $line"
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $TimeoutSec, $ErrorAction, $ContentType)
        $global:LASTEXITCODE = 73
        $global:P97SyncFixtureCalls.Add("HTTP $Method $Uri")
        if ([string]$Uri -match '^https://graph\.microsoft\.com/v1\.0/users/[^/]+\?\$select=id$') {
            return [pscustomobject]@{ id = '30000000-0000-4000-8000-000000000001' }
        }
        if ([string]$Uri -like 'https://graph.microsoft.com/v1.0/groups?*') {
            $text = [uri]::UnescapeDataString([string]$Uri)
            $id = if ($text -match "displayName eq 'claude-code-premium'") { '10000000-0000-4000-8000-000000000002' }
            elseif ($text -match "displayName eq 'claude-code-standard'") { '10000000-0000-4000-8000-000000000001' }
            elseif ($text -match "displayName eq 'Unit") { ('20000000-0000-4000-8000-' + ([regex]::Match($text, 'Unit(\d+)').Groups[1].Value.PadLeft(12, '0'))) }
            else { '' }
            if ($id) { return [pscustomobject]@{ value = @([pscustomobject]@{ id = $id }) } }
            return [pscustomobject]@{ value = @() }
        }
        if ([string]$Uri -like 'https://graph.microsoft.com/v1.0/users/*/checkMemberGroups') {
            $data = $Body | ConvertFrom-Json
            $global:P97SyncFixtureBatches.Add(@($data.groupIds).Count)
            $matches = @()
            if ($User -eq 'both@contoso.com') { $matches = @('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002') }
            return [pscustomobject]@{ value = $matches }
        }
        throw "unexpected HTTP $Method $Uri"
    }
    & (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Account cosmos-p97 -TenantId '00000000-0000-4000-8000-000000000085' -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -BusinessUnitGroups $BusinessUnitGroups -ExportPath $snapshot -User $User -WhatIf:$WhatIf | Out-Null
    $written = Test-Path -LiteralPath $snapshot
    $json = if ($written) { Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json } else { $null }
    [pscustomobject]@{ Calls = @($global:P97SyncFixtureCalls); Batches = @($global:P97SyncFixtureBatches); Snapshot = $json; Written = $written; LastExitCode = $global:LASTEXITCODE }
}

Capture { & (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Account cosmos-p97 -User dev@contoso.com }
Assert 'targeted export refuses User without ExportPath and names the command that exports and applies' ($CapturedError -match '-User requires -ExportPath' -and $CapturedError -match 'Remedy: run scripts/Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim> -User') $CapturedError
$exporter = [IO.File]::ReadAllText((Join-Path $root 'scripts\Sync-ClaudeProjection.ps1')) + [IO.File]::ReadAllText((Join-Path $root 'scripts\ClaudeGraphMembership.ps1'))
Assert 'an invalid -User and a scan past the apply-by time name their remedy' ($exporter -match "-User must be an object id GUID or a valid user principal name\. Remedy: " -and $exporter -match 'Nothing exported; resolve again\. Remedy: rerun ') $exporter.Length

# ADR-0051 amendment 2: sync/src/apply-projection.mjs is the one Cosmos writer, so the exporter
# refuses a run with no -ExportPath before it signs in, reads Graph or contacts Cosmos.
$global:P97ExporterCalls = [Collections.Generic.List[string]]::new()
function az { $global:P97ExporterCalls.Add("az $($args -join ' ')"); $global:LASTEXITCODE = 0; throw "unexpected az $($args -join ' ')" }
function Invoke-RestMethod { $global:P97ExporterCalls.Add('Invoke-RestMethod'); throw 'unexpected Invoke-RestMethod' }
function Invoke-WebRequest { $global:P97ExporterCalls.Add('Invoke-WebRequest'); throw 'unexpected Invoke-WebRequest' }
foreach ($case in @(@{ Name = 'a full run'; Extra = @{} }, @{ Name = 'a -WhatIf run'; Extra = @{ WhatIf = $true } })) {
    $global:P97ExporterCalls.Clear()
    $extra = $case.Extra
    Capture { & (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Account cosmos-p97 -TenantId '00000000-0000-4000-8000-000000000085' @extra }
    Assert "without -ExportPath, $($case.Name) refuses before any Azure or Graph call and names the one Cosmos writer and the supported command" ($CapturedError -match 'Nothing was read or written' -and $CapturedError -match 'sync/src/apply-projection\.mjs' -and $CapturedError -match 'Remedy: run scripts/Sync-ClaudeAccess\.ps1 -ResourceGroup <rg> -ApimName <apim>' -and $global:P97ExporterCalls.Count -eq 0) "$CapturedError | calls: $($global:P97ExporterCalls -join ', ')"
}
Remove-Item function:az, function:Invoke-RestMethod, function:Invoke-WebRequest

$none = Invoke-TargetedExportFixture -User 'dev@contoso.com'
Assert 'targeted export resolves a UPN with the exact encoded Graph URL' (($none.Calls -join "`n") -match 'HTTP Get https://graph\.microsoft\.com/v1\.0/users/dev%40contoso\.com\?\$select=id') ($none.Calls -join ' | ')
Assert 'targeted export for a user in no configured group writes a user removal snapshot' ($none.Snapshot.scope -eq 'user' -and $none.Snapshot.user -eq '30000000-0000-4000-8000-000000000001' -and @($none.Snapshot.records).Count -eq 0) ($none.Snapshot | ConvertTo-Json -Compress)
Assert 'successful export returns with LASTEXITCODE 0 for caller checks' ($none.LastExitCode -eq 0) "LASTEXITCODE=$($none.LastExitCode)"
$dry = Invoke-TargetedExportFixture -User 'dev@contoso.com' -WhatIf
Assert '-WhatIf with -ExportPath resolves, writes no snapshot file and returns 0' (-not $dry.Written -and $dry.LastExitCode -eq 0 -and ($dry.Calls -join "`n") -match '/checkMemberGroups') "written=$($dry.Written) LASTEXITCODE=$($dry.LastExitCode)"

$oid = '30000000-0000-4000-8000-000000000009'
$byId = Invoke-TargetedExportFixture -User $oid
Assert 'targeted export uses an object id as-is' (($byId.Calls -join "`n") -notmatch '/users/[^/]+\?\$select=id' -and ($byId.Calls -join "`n") -match "/users/$oid/checkMemberGroups") ($byId.Calls -join ' | ')

$units = @(1..45 | ForEach-Object { "u$_=Unit$_" })
$batched = Invoke-TargetedExportFixture -User $oid -BusinessUnitGroups $units
Assert 'targeted export uses Graph checkMemberGroups batches' (@($batched.Batches | Where-Object { $_ -gt 20 }).Count -eq 0 -and ((@($batched.Batches) | Measure-Object -Sum).Sum -eq 47) -and @($batched.Batches).Count -ge 3) ($batched.Batches -join ',')

$both = Invoke-TargetedExportFixture -User 'both@contoso.com'
Assert 'targeted export writes user-scoped snapshots' (@($both.Snapshot.records).Count -eq 1 -and $both.Snapshot.records[0].tier -eq 'premium' -and $both.Snapshot.scope -eq 'user') ($both.Snapshot | ConvertTo-Json -Compress)

. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
function pwsh {
    $words = @($args)
    $global:FixtureCalls.Add("pwsh $($words -join ' ')")
    $exportIndex = [array]::IndexOf($words, '-ExportPath')
    if ($exportIndex -lt 0) { $global:LASTEXITCODE = 1; return 'missing export path' }
    $path = [string]$words[$exportIndex + 1]
    $userIndex = [array]::IndexOf($words, '-User')
    $user = if ($userIndex -ge 0) { '30000000-0000-4000-8000-000000000001' } else { $null }
    # Times relative to now, as the exporter writes them: a fixed time has passed by the next day, and the
    # runner transfer refuses a snapshot past its apply-by time before sending it.
    $scanned = [DateTimeOffset]::UtcNow
    $snapshot = [ordered]@{
        kind = 'claude-entitlement-snapshot'
        tenantId = $global:FixtureTenant
        generatedAt = $scanned.ToString('yyyy-MM-ddTHH:mm:ssZ')
        reconciliationGeneration = '40000000-0000-4000-8000-000000000001'
        lastVerifiedAt = $scanned.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        expiresAt = $scanned.ToUnixTimeSeconds() + 7200
        mappingVersion = $scanned.ToUnixTimeSeconds()
        records = @()
    }
    if ($user) { $snapshot.scope = 'user'; $snapshot.user = $user }
    [IO.File]::WriteAllText($path, ($snapshot | ConvertTo-Json -Depth 6))
    $global:LASTEXITCODE = 0
    return 'snapshot exported'
}

Reset-ProjectionFixture 'prefix-missing'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection }
Assert 'a projection sync without entitlement-projection-prefix gives the deployer command for this gateway and writes nothing' (
    $CapturedError -match [regex]::Escape('.\scripts\Deploy-ClaudeProjection.ps1 -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix <prefix>') -and
    @($FixtureCalls | Where-Object { $_ -match 'container exec|apply-projection|Sync-ClaudeProjection' }).Count -eq 0) "$CapturedError | $($FixtureCalls -join ' | ')"

Reset-ProjectionFixture 'source-projection'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store auto -AllowEmpty }
$accessCalls = $FixtureCalls -join "`n"
Assert 'Sync-ClaudeAccess -Store auto follows a projection gateway and forwards --allow-empty plus account id' (-not $CapturedError -and $accessCalls -match 'apply-projection\.mjs .*--account-resource-id /subscriptions/00000000-0000-4000-8000-000000000084/resourceGroups/rg-p84/providers/Microsoft\.DocumentDB/databaseAccounts/cosmos-p84fixture .*--allow-empty') "$CapturedError | $accessCalls"
Assert 'Sync-ClaudeAccess projection runner installs production dependencies with safe npm ci flags' ($accessCalls -match 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false') $accessCalls
$runSnapshot = [regex]::Match($accessCalls, 'apply-projection\.mjs .*--snapshot (/work/projection-snapshot-[0-9a-f]{32}\.json)').Groups[1].Value
Assert 'projection access path starts runner and applies contract CLI from its own per-run snapshot path' (-not $CapturedError -and $accessCalls -match 'container show .*aci-projtest-p84fixture' -and $accessCalls -match 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' -and $runSnapshot) "$CapturedError | $accessCalls"
Assert 'projection access uses a temp per-run snapshot directory, not a repo .claude-projection-sync directory' (-not $CapturedError -and $accessCalls -match [regex]::Escape([IO.Path]::GetTempPath()) -and $accessCalls -notmatch '\.claude-projection-sync') "$CapturedError | $accessCalls"
Assert 'projection access removes its own runner snapshot after apply' (-not $CapturedError -and $runSnapshot -and $accessCalls.Contains("rmSync('$runSnapshot'")) "$CapturedError | $accessCalls"

Reset-ProjectionFixture 'apply-excluded'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection 6>&1 }
$excludedText = (@($CapturedResult) | ForEach-Object { [string]$_ }) -join "`n"
Assert 'a full sync that left out users a targeted sync changed says how many, with the remedy' (-not $CapturedError -and $excludedText -match '2 user\(s\)' -and $excludedText -match 'Remedy: rerun scripts/Sync-ClaudeAccess\.ps1') "$CapturedError | $excludedText"
$exportCall = @($FixtureCalls | Where-Object { $_ -like 'pwsh *Sync-ClaudeProjection.ps1*' })
$declared = @((Get-Command (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1')).Parameters.Keys)
$passed = @(if ($exportCall.Count) { ([string]$exportCall[0] -split ' ') | Select-Object -Skip 3 | Where-Object { $_ -match '^-[A-Za-z]+$' } | ForEach-Object { $_.Substring(1) } })
Assert 'every parameter Sync-ClaudeAccess passes to the exporter is one the exporter declares' ($exportCall.Count -eq 1 -and $passed.Count -gt 0 -and @($passed | Where-Object { $_ -notin $declared }).Count -eq 0) "passed: $($passed -join ',') | undeclared: $(@($passed | Where-Object { $_ -notin $declared }) -join ',')"
# Test-All refuses a dirty tree after its checks (tests/TestAll-Sharding.ps1, Get-TestAllIdentity -RequireClean).
Assert 'the .test-work scratch folders that tests create are git-ignored at any depth' ((Get-Content -LiteralPath (Join-Path $root '.gitignore') -Raw) -match '(?m)^\.test-work/\s*$')

Reset-ProjectionFixture 'node-modules-present'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection }
$presentCalls = $FixtureCalls -join "`n"
Assert 'Sync-ClaudeAccess skips runner npm ci when node_modules is already present' (-not $CapturedError -and $presentCalls -notmatch 'npm --prefix /work/sync ci') "$CapturedError | $presentCalls"

Reset-ProjectionFixture 'source-projection'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection }
$projectionRecordCalls = $FixtureCalls -join "`n"
$projectionApplyIndex = [array]::FindIndex([string[]]@($FixtureCalls), [Predicate[string]]{ param($line) $line -match 'apply-projection\.mjs .*--snapshot' })
$projectionRecordIndex = [array]::FindIndex([string[]]@($FixtureCalls), [Predicate[string]]{ param($line) $line -match 'az apim nv (update|create) .*--named-value-id entitlement-groups' })
Assert 'a projection sync records entitlement-groups after the successful apply' (
    -not $CapturedError -and $projectionApplyIndex -ge 0 -and $projectionRecordIndex -gt $projectionApplyIndex) "$CapturedError | $projectionRecordCalls"

Reset-ProjectionFixture 'source-projection'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection -WhatIf }
$projectionWhatIfCalls = $FixtureCalls -join "`n"
Assert 'a projection WhatIf sync does not record entitlement-groups' (
    -not $CapturedError -and $projectionWhatIfCalls -notmatch 'az apim nv (update|create) .*--named-value-id entitlement-groups') "$CapturedError | $projectionWhatIfCalls"

Reset-ProjectionFixture 'source-projection'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection -User missing@contoso.com }
$missingProjectionCalls = $FixtureCalls -join "`n"
Assert 'a projection sync for an unknown UPN stops before writes with a clear message' (
    $CapturedError -match "Graph did not return a valid object id for user 'missing@contoso\.com'" -and
    $missingProjectionCalls -notmatch 'apply-projection|az apim nv (update|create)') "$CapturedError | $missingProjectionCalls"

# P98 council round 2 (Architect): the named-value sync wrote allow-premium, then refused allow-standard over the
# 4,096-character limit, so the gateway served a refreshed premium list beside a stale standard list. Every
# value is now checked before the first write. The fixture answers Graph and az for a gateway with no business units.
function Invoke-NamedValueSyncFixture {
    param([int]$PremiumCount, [int]$StandardCount, [string]$GatewayStandard = '', [string]$GatewayPremium = '', [string]$GatewayGroups = '', [string]$Script = 'Sync-ClaudeAccess.ps1', [hashtable]$Parameters = @{ Store = 'named-value' }, [switch]$FailAllowStandardWrite, [switch]$WithDecisionRecord)
    $global:P98NvCalls = [Collections.Generic.List[string]]::new()
    $script:P98NvResult = $null
    $recordPath = Join-Path $root 'onboarding\claude-gateway.json'
    $hadRecord = Test-Path -LiteralPath $recordPath
    $oldRecord = if ($hadRecord) { Get-Content -LiteralPath $recordPath -Raw } else { '' }
    if ($WithDecisionRecord) {
        New-Item -ItemType Directory -Force -Path (Split-Path $recordPath -Parent) | Out-Null
        @{ apimName = 'apim-p98'; resourceGroup = 'rg-p98'; standardGroup = 'record-standard'; premiumGroup = 'record-premium' } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $recordPath -Encoding UTF8
    }
    $directory = @{
        '10000000-0000-4000-8000-000000000002' = @(1..$PremiumCount | Where-Object { $_ -gt 0 } | ForEach-Object { '40000000-0000-4000-8000-' + ([string]$_).PadLeft(12, '0') })
        '10000000-0000-4000-8000-000000000001' = @(1..$StandardCount | Where-Object { $_ -gt 0 } | ForEach-Object { '50000000-0000-4000-8000-' + ([string]$_).PadLeft(12, '0') })
        '10000000-0000-4000-8000-000000000003' = @(1..$StandardCount | Where-Object { $_ -gt 0 } | ForEach-Object { '51000000-0000-4000-8000-' + ([string]$_).PadLeft(12, '0') })
        '10000000-0000-4000-8000-000000000004' = @(1..$PremiumCount | Where-Object { $_ -gt 0 } | ForEach-Object { '41000000-0000-4000-8000-' + ([string]$_).PadLeft(12, '0') })
        '10000000-0000-4000-8000-000000000005' = @(1..$StandardCount | Where-Object { $_ -gt 0 } | ForEach-Object { '52000000-0000-4000-8000-' + ([string]$_).PadLeft(12, '0') })
        '10000000-0000-4000-8000-000000000006' = @(1..$PremiumCount | Where-Object { $_ -gt 0 } | ForEach-Object { '42000000-0000-4000-8000-' + ([string]$_).PadLeft(12, '0') })
    }
    $gatewayLists = @{ 'allow-standard' = $GatewayStandard; 'allow-premium' = $GatewayPremium; 'bu-members' = ',' }
    if ($GatewayGroups) { $gatewayLists['entitlement-groups'] = $GatewayGroups }
    function az {
        $words = @($args); $line = $words -join ' '; $global:P98NvCalls.Add("az $line"); $global:LASTEXITCODE = 0
        if ($line -like 'account get-access-token*') { return '{"accessToken":"offline-token"}' }
        if ($line -like 'account show*') { return '{"id":"00000000-0000-4000-8000-000000000001","tenantId":"00000000-0000-4000-8000-000000000085"}' }
        if ($line -like 'apim nv show*') {
            $id = [string]$words[[array]::IndexOf($words, '--named-value-id') + 1]
            if ($gatewayLists.ContainsKey($id) -and $gatewayLists[$id]) {
                if ($line -match '--query value') { return $gatewayLists[$id] }
                return (@{ name = $id; value = $gatewayLists[$id] } | ConvertTo-Json -Compress)
            }
            # az prints "(ResourceNotFound) NamedValue not found" on stderr, which these reads discard.
                $global:LASTEXITCODE = 3; return 'ERROR: (ResourceNotFound) NamedValue not found.'
        }
        if ($line -like 'apim nv update*' -or $line -like 'apim nv create*') {
            $id = [string]$words[[array]::IndexOf($words, '--named-value-id') + 1]
            if ($FailAllowStandardWrite -and $id -eq 'allow-standard') { $global:LASTEXITCODE = 9; return 'ERROR: denied' }
            $valueIndex = [array]::IndexOf($words, '--value')
            if ($valueIndex -ge 0) { $gatewayLists[$id] = [string]$words[$valueIndex + 1] }
            return ''
        }
        throw "unexpected az $line"
    }
    function Invoke-RestMethod {
        param($Uri, $Method, $Headers, $Body, $TimeoutSec, $ErrorAction, $ContentType)
        $global:P98NvCalls.Add("HTTP $Method $Uri")
        $text = [uri]::UnescapeDataString([string]$Uri)
        if ($text -match '^https://graph\.microsoft\.com/v1\.0/users/dev@contoso\.com\?\$select=id') {
            return [pscustomobject]@{ id = '50000000-0000-4000-8000-000000000001' }
        }
        if ($text -match '^https://graph\.microsoft\.com/v1\.0/users/missing@contoso\.com\?\$select=id') {
            return [pscustomobject]@{}
        }
        if ($text -match '^https://graph\.microsoft\.com/v1\.0/groups\?') {
            $id = if ($text -match "displayName eq 'claude-code-premium'" -or $text -match "id eq '10000000-0000-4000-8000-000000000002'") { '10000000-0000-4000-8000-000000000002' }
            elseif ($text -match "displayName eq 'claude-code-standard'" -or $text -match "id eq '10000000-0000-4000-8000-000000000001'") { '10000000-0000-4000-8000-000000000001' }
            elseif ($text -match "displayName eq 'record-standard'" -or $text -match "id eq '10000000-0000-4000-8000-000000000003'") { '10000000-0000-4000-8000-000000000003' }
            elseif ($text -match "displayName eq 'record-premium'" -or $text -match "id eq '10000000-0000-4000-8000-000000000004'") { '10000000-0000-4000-8000-000000000004' }
            elseif ($text -match "displayName eq 'gateway-standard'" -or $text -match "id eq '10000000-0000-4000-8000-000000000005'") { '10000000-0000-4000-8000-000000000005' }
            elseif ($text -match "displayName eq 'gateway-premium'" -or $text -match "id eq '10000000-0000-4000-8000-000000000006'") { '10000000-0000-4000-8000-000000000006' }
            else { '' }
            return [pscustomobject]@{ value = @(if ($id) { [pscustomobject]@{ id = $id } }) }
        }
        if ($text -match '^https://graph\.microsoft\.com/v1\.0/groups/([0-9a-f-]+)/transitiveMembers/microsoft\.graph\.user') {
            return [pscustomobject]@{ value = @($directory[$Matches[1]] | ForEach-Object { [pscustomobject]@{ id = $_; displayName = $_ } }) }
        }
        if ($text -match 'transitiveMembers/microsoft\.graph\.servicePrincipal') { return [pscustomobject]@{ value = @() } }
        throw "unexpected HTTP $Method $Uri"
    }
    try {
        $arguments = @{ ApimName = 'apim-p98'; ResourceGroup = 'rg-p98' } + $Parameters
        Capture { & (Join-Path $root "scripts\$Script") @arguments 6>&1 }
        $script:P98NvResult = [pscustomobject]@{ Values = $gatewayLists; Output = (@($CapturedResult) | ForEach-Object { [string]$_ }) -join "`n" }
        $script:FixtureExit = $global:LASTEXITCODE
    }
    finally {
        if ($WithDecisionRecord) {
            if ($hadRecord) { Set-Content -LiteralPath $recordPath -Value $oldRecord -NoNewline }
            elseif (Test-Path -LiteralPath $recordPath) { Remove-Item -LiteralPath $recordPath -Force }
        }
    }
}
function Get-NamedValueWrites { @($global:P98NvCalls | Where-Object { $_ -match '^az apim nv (update|create)' -or $_ -match '^HTTP Put ' }) }

Invoke-NamedValueSyncFixture -PremiumCount 5 -StandardCount 120
$nvWrites = Get-NamedValueWrites
Assert 'a named-value sync with a list over the limit writes no named value, not the premium list first' (
    $CapturedError -match 'over the API Management limit' -and $nvWrites.Count -eq 0) "$CapturedError | writes: $($nvWrites -join ' | ')"
Invoke-NamedValueSyncFixture -PremiumCount 5 -StandardCount 20
$nvWrites = Get-NamedValueWrites
Assert 'a named-value sync within the limit writes both lists' (
    -not $CapturedError -and @($nvWrites -match 'allow-premium').Count -ge 1 -and @($nvWrites -match 'allow-standard').Count -ge 1) "$CapturedError | writes: $($nvWrites -join ' | ')"
Assert 'a named-value sync records entitlement-groups after a successful first sync' (
    -not $CapturedError -and $script:P98NvResult.Values['entitlement-groups'] -eq 'standard=10000000-0000-4000-8000-000000000001,premium=10000000-0000-4000-8000-000000000002') "$CapturedError | groups=$($script:P98NvResult.Values['entitlement-groups']) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 5 -StandardCount 20 -Parameters @{ Store = 'named-value'; WhatIf = $true }
$nvWrites = Get-NamedValueWrites
Assert 'a named-value WhatIf sync without entitlement-groups records nothing' (
    -not $CapturedError -and -not $script:P98NvResult.Values.ContainsKey('entitlement-groups') -and $nvWrites.Count -eq 0) "$CapturedError | groups=$($script:P98NvResult.Values['entitlement-groups']) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 5 -StandardCount 20 -FailAllowStandardWrite
$nvWrites = Get-NamedValueWrites
Assert 'a named-value sync whose list write fails leaves no recorded groups' (
    $CapturedError -match "Writing named value 'allow-standard' failed" -and -not $script:P98NvResult.Values.ContainsKey('entitlement-groups') -and
    @($nvWrites -match 'allow-premium').Count -ge 1 -and @($nvWrites -match 'allow-standard').Count -ge 1 -and @($nvWrites -match 'entitlement-groups').Count -eq 0) "$CapturedError | groups=$($script:P98NvResult.Values['entitlement-groups']) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -Parameters @{ Store = 'named-value'; User = 'dev@contoso.com' }
$nvWrites = Get-NamedValueWrites
Assert 'Sync-ClaudeAccess -User on named values runs the whole refresh and reports the written tier' (
    -not $CapturedError -and @($nvWrites -match 'allow-premium').Count -ge 1 -and @($nvWrites -match 'allow-standard').Count -ge 1 -and
    $script:P98NvResult.Output -match 'developer tier as written: standard') "$CapturedError | output: $($script:P98NvResult.Output) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -GatewayGroups 'standard=10000000-0000-4000-8000-000000000001,premium=10000000-0000-4000-8000-000000000002' -Parameters @{ Store = 'named-value'; User = '40000000-0000-4000-8000-000000000001'; WhatIf = $true }
$nvWrites = Get-NamedValueWrites
Assert 'Sync-ClaudeAccess -User -WhatIf on named values reports the would-be tier and writes nothing' (
    -not $CapturedError -and $nvWrites.Count -eq 0 -and $script:P98NvResult.Output -match 'developer tier as written: premium') "$CapturedError | output: $($script:P98NvResult.Output) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -Parameters @{ Store = 'named-value'; User = 'missing@contoso.com' }
$nvWrites = Get-NamedValueWrites
Assert 'a named-value sync for an unknown UPN stops before writes with a clear message' (
    $CapturedError -match "Graph did not return a valid object id for user 'missing@contoso\.com'" -and $nvWrites.Count -eq 0) "$CapturedError | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -GatewayGroups 'standard=10000000-0000-4000-8000-000000000001,premium=10000000-0000-4000-8000-000000000002' -Parameters @{ Store = 'named-value'; StandardGroup = 'claude-code-premium' }
$nvWrites = Get-NamedValueWrites
Assert 'explicit groups that differ from entitlement-groups refuse before writes and name RecordGroups' (
    $CapturedError -match '-RecordGroups' -and $nvWrites.Count -eq 0) "$CapturedError | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -GatewayGroups 'standard=10000000-0000-4000-8000-000000000001,premium=10000000-0000-4000-8000-000000000002' -Parameters @{ Store = 'named-value'; StandardGroup = 'gateway-standard'; PremiumGroup = 'gateway-premium'; RecordGroups = $true }
$nvWrites = Get-NamedValueWrites
$recordWrite = @($nvWrites | Where-Object { $_ -match 'entitlement-groups' } | Select-Object -Last 1)
Assert 'with RecordGroups explicit changed groups sync and then record the new value' (
    -not $CapturedError -and $script:P98NvResult.Values['entitlement-groups'] -eq 'standard=10000000-0000-4000-8000-000000000005,premium=10000000-0000-4000-8000-000000000006' -and
    @($nvWrites -match 'allow-premium').Count -ge 1 -and @($nvWrites -match 'allow-standard').Count -ge 1 -and $recordWrite -and
    [array]::IndexOf($nvWrites, $recordWrite) -gt [array]::IndexOf($nvWrites, @($nvWrites | Where-Object { $_ -match 'allow-standard' } | Select-Object -Last 1))) "$CapturedError | groups=$($script:P98NvResult.Values['entitlement-groups']) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -WithDecisionRecord
$nvWrites = Get-NamedValueWrites
Assert 'Sync-ClaudeAccess uses the decision record groups before the default group names' (
    -not $CapturedError -and $script:P98NvResult.Values['entitlement-groups'] -eq 'standard=10000000-0000-4000-8000-000000000003,premium=10000000-0000-4000-8000-000000000004') "$CapturedError | groups=$($script:P98NvResult.Values['entitlement-groups']) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -WithDecisionRecord -GatewayGroups 'standard=10000000-0000-4000-8000-000000000005,premium=10000000-0000-4000-8000-000000000006'
$nvWrites = Get-NamedValueWrites
Assert 'Sync-ClaudeAccess uses entitlement-groups before a decision record of this gateway' (
    -not $CapturedError -and @($nvWrites | Where-Object { $_ -match 'entitlement-groups' }).Count -eq 0 -and
    $script:P98NvResult.Values['entitlement-groups'] -eq 'standard=10000000-0000-4000-8000-000000000005,premium=10000000-0000-4000-8000-000000000006') "$CapturedError | groups=$($script:P98NvResult.Values['entitlement-groups']) | writes: $($nvWrites -join ' | ')"

Invoke-NamedValueSyncFixture -PremiumCount 1 -StandardCount 1 -GatewayGroups 'standard=99999999-9999-4999-8999-999999999999,premium=none' -Parameters @{ Store = 'named-value' }
$nvWrites = Get-NamedValueWrites
Assert 'a missing group named by entitlement-groups stops before writes and names the operator remedy' (
    $CapturedError -match 'U160' -and $CapturedError -match '-StandardGroup' -and $CapturedError -match '-PremiumGroup' -and $CapturedError -match '-RecordGroups' -and $nvWrites.Count -eq 0) "$CapturedError | writes: $($nvWrites -join ' | ')"

# P98 council round 2 (Coder note): with one object id in allow-standard and an empty allow-premium, the list reads
# unrolled to a string, the combined list became one concatenated string, and the drift check said "In sync".
Invoke-NamedValueSyncFixture -PremiumCount 0 -StandardCount 1 -GatewayStandard ',00000000-0000-4000-8000-0000000000aa,' -GatewayPremium ',' -Script 'Compare-ClaudeEntitlement.ps1' -Parameters @{}
Assert 'the drift check reports a one-member list that differs from Entra' ($script:FixtureExit -eq 1 -and -not $CapturedError) "exit $($script:FixtureExit) | $CapturedError"
Write-Host "P97_SYNC assertions=$assertions failed=$failures"
Remove-Item -LiteralPath $script:p97SyncWork -Recurse -Force -ErrorAction SilentlyContinue
exit ([int]($failures -gt 0))
