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

# Exercise the actual REST adapter and deletion plan too, not a duplicate of
# the production pagination loop. No Azure CLI or network call is made.
$source = Get-Content (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Raw
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
$function = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Cosmos'
}, $true)
Invoke-Expression $function.Extent.Text
$script:httpTokens = [Collections.Generic.List[string]]::new()
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $Body, [switch]$UseBasicParsing)
    if ($Method -ne 'POST' -or $Uri -notlike 'https://fake.invalid/dbs/*/docs') { throw 'Unexpected fake Cosmos request' }
    $token = [string]$Headers['x-ms-continuation']
    $script:httpTokens.Add($token)
    $page = $pages[$token]
    return [pscustomobject]@{ Content=(@{Documents=@($page.Documents)} | ConvertTo-Json -Depth 5 -Compress)
        Headers=@{'x-ms-continuation'=$page.Continuation} }
}
$base = 'https://fake.invalid'; $authHeader = 'fake'; $Database='claude'; $Container='entitlement'; $q='{}'
$read = [regex]::Match($source, '(?ms)    \$existing = Get-ClaudeProjectionExisting -ReadPage \{.*?^    \}').Value
if (-not $read) { throw 'Production query adapter not found' }
Invoke-Expression $read
$byOid = @{ kept = $true }
Invoke-Expression ([regex]::Match($source, '(?m)^\$orphans = .*$').Value)
if ($orphans.Count -ne 1 -or $orphans[0] -ne 'revoked') { throw 'Production deletion plan lost the last-page revocation' }
if (($script:httpTokens -join ',') -ne ',page+2/token==,last') { throw 'REST adapter dropped or changed continuation' }
Write-Host 'Projection paging: 6 behavioral assertions passed.'
exit 0
