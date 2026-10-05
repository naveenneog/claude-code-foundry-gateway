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

$syncProjection = Get-Content -LiteralPath (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Raw
$syncAccess = Get-Content -LiteralPath (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') -Raw
Assert 'targeted export refuses User without ExportPath' ($syncProjection -match '\$User' -and $syncProjection -match 'ExportPath' -and $syncProjection -match 'Refuse|refus|requires')
Assert 'targeted export uses Graph checkMemberGroups batches' ($syncProjection -match 'checkMemberGroups' -and $syncProjection -match '20')
Assert 'targeted export writes user-scoped snapshots' ($syncProjection -match "scope\s*=\s*'user'" -and $syncProjection -match '\.user\s*=')
Assert 'projection access path starts runner and applies contract CLI' ($syncAccess -match 'Start-ClaudeProjectionRunner' -and $syncAccess -match 'apply-projection\.mjs --cosmos' -and $syncAccess -match '--user')
Assert 'projection access reuses the package archive' ($syncAccess -match 'New-ClaudeProjectionSyncArchive' -and $syncAccess -match 'Send-RunnerFile')
Assert 'named-value refuses targeted user' ($syncAccess -match 'Store named-value' -and $syncAccess -match 'User')

Write-Host "P97_SYNC assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
