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
    param([string]$User, [string[]]$BusinessUnitGroups = @())
    $work = Join-Path $root '.test-work\p97-sync-scripts'
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
    & (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Account cosmos-p97 -TenantId '00000000-0000-4000-8000-000000000085' -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -BusinessUnitGroups $BusinessUnitGroups -ExportPath $snapshot -User $User | Out-Null
    $json = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    [pscustomobject]@{ Calls = @($global:P97SyncFixtureCalls); Batches = @($global:P97SyncFixtureBatches); Snapshot = $json }
}

Capture { & (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Account cosmos-p97 -User dev@contoso.com }
Assert 'targeted export refuses User without ExportPath' ($CapturedError -match '-User requires -ExportPath') $CapturedError

$none = Invoke-TargetedExportFixture -User 'dev@contoso.com'
Assert 'targeted export resolves a UPN with the exact encoded Graph URL' (($none.Calls -join "`n") -match 'HTTP Get https://graph\.microsoft\.com/v1\.0/users/dev%40contoso\.com\?\$select=id') ($none.Calls -join ' | ')
Assert 'targeted export for a user in no configured group writes a user removal snapshot' ($none.Snapshot.scope -eq 'user' -and $none.Snapshot.user -eq '30000000-0000-4000-8000-000000000001' -and @($none.Snapshot.records).Count -eq 0) ($none.Snapshot | ConvertTo-Json -Compress)

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
    $snapshot = [ordered]@{
        kind = 'claude-entitlement-snapshot'
        tenantId = $global:FixtureTenant
        generatedAt = '2026-10-05T12:00:00Z'
        reconciliationGeneration = '40000000-0000-4000-8000-000000000001'
        lastVerifiedAt = '2026-10-05T12:00:00.000Z'
        expiresAt = 1791208800
        mappingVersion = 1791201600
        records = @()
    }
    if ($user) { $snapshot.scope = 'user'; $snapshot.user = $user }
    [IO.File]::WriteAllText($path, ($snapshot | ConvertTo-Json -Depth 6))
    $global:LASTEXITCODE = 0
    return 'snapshot exported'
}

Reset-ProjectionFixture
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store named-value -User dev@contoso.com }
Assert 'Sync-ClaudeAccess refuses targeted named-value sync before Azure calls' ($CapturedError -match '-User cannot be used with -Store named-value' -and $FixtureCalls.Count -eq 0) "$CapturedError | $($FixtureCalls -join ' | ')"
Assert 'named-value refuses targeted user' ($CapturedError -match '-User cannot be used with -Store named-value' -and $FixtureCalls.Count -eq 0) "$CapturedError | $($FixtureCalls -join ' | ')"

Reset-ProjectionFixture 'source-projection'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store auto -AllowEmpty }
$accessCalls = $FixtureCalls -join "`n"
Assert 'Sync-ClaudeAccess -Store auto follows a projection gateway and forwards --allow-empty plus account id' (-not $CapturedError -and $accessCalls -match 'apply-projection\.mjs .*--account-resource-id /subscriptions/00000000-0000-4000-8000-000000000084/resourceGroups/rg-p84/providers/Microsoft\.DocumentDB/databaseAccounts/cosmos-p84fixture .*--allow-empty') "$CapturedError | $accessCalls"
Assert 'Sync-ClaudeAccess projection runner installs production dependencies with safe npm ci flags' ($accessCalls -match 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false') $accessCalls
Assert 'projection access path starts runner and applies contract CLI' (-not $CapturedError -and $accessCalls -match 'container show .*aci-projtest-p84fixture' -and $accessCalls -match 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' -and $accessCalls -match 'apply-projection\.mjs .*--account-resource-id .*--snapshot /work/projection-snapshot\.json') "$CapturedError | $accessCalls"
Assert 'projection access uses a temp per-run snapshot directory, not a repo .claude-projection-sync directory' (-not $CapturedError -and $accessCalls -match [regex]::Escape([IO.Path]::GetTempPath()) -and $accessCalls -notmatch '\.claude-projection-sync') "$CapturedError | $accessCalls"
Assert 'projection access removes runner snapshot and decision files after apply' (-not $CapturedError -and $accessCalls -match "rmSync\('/work/projection-snapshot\.json'" -and $accessCalls -match "rmSync\('/work/gateway-decisions\.json'") "$CapturedError | $accessCalls"

Reset-ProjectionFixture 'node-modules-present'
Capture { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -ApimName apim-p84 -ResourceGroup rg-p84 -Store projection }
$presentCalls = $FixtureCalls -join "`n"
Assert 'Sync-ClaudeAccess skips runner npm ci when node_modules is already present' (-not $CapturedError -and $presentCalls -notmatch 'npm --prefix /work/sync ci') "$CapturedError | $presentCalls"

Write-Host "P97_SYNC assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
