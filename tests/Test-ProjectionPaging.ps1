$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeProjection.ps1')
$script:calls = [Collections.Generic.List[string]]::new()
$pages = @{
    '' = @{ Documents = @(@{ id = 'kept'; tier = 'standard' }); Continuation = 'page+2/token==' }
    'page+2/token==' = @{ Documents = @(); Continuation = 'last' }
    'last' = @{ Documents = @(@{ id = 'revoked'; tier = 'premium' }); Continuation = '' }
}
$existing = Get-ClaudeProjectionExisting -ReadPage {
    param($token)
    $script:calls.Add($token)
    return $pages[$token]
}
if ($existing.Count -ne 2 -or -not $existing.ContainsKey('revoked')) { throw 'Revocation past the first page was lost' }
if (($script:calls -join ',') -ne ',page+2/token==,last') { throw 'Continuation token not replayed exactly, or empty page stopped the scan' }
$refused = $false
$script:repeatedCalls = 0
try { Get-ClaudeProjectionExisting -ReadPage { param($token)
    if (++$script:repeatedCalls -gt 5) { throw 'iteration safety guard' }
    @{ Documents=@(); Continuation='loop' }
} | Out-Null }
catch { $refused = $_.Exception.Message -match 'repeated' }
if (-not $refused) { throw 'Repeated continuation was not refused' }
$refused = $false
try { Get-ClaudeProjectionExisting -ReadPage { param($token) if ($token) { throw 'page failed' }; @{ Documents=@(); Continuation='next' } } | Out-Null }
catch { $refused = $_.Exception.Message -match 'page failed' }
if (-not $refused) { throw 'Incomplete scan did not stop reconciliation' }
Write-Host 'Projection paging: 4 behavioral assertions passed.'
exit 0
