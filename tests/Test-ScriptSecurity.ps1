$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failures = @()
try {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/get-foundry-token.ps1'), [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-FoundryToken' }, $true)
    if (-not $definition) { throw 'Missing testable credential output validator' }
    . ([scriptblock]::Create($definition.Extent.Text))
    foreach ($invalid in @('eyJheader.payload.signature extra', "eyJheader.payload.signature`nInjected", "eyJheader.payload.signature`n", @('eyJheader.payload.signature', 'noise'), 'not-a-token')) {
        if (Test-FoundryToken $invalid) { throw 'Credential helper accepted malformed output' }
    }
    if (-not (Test-FoundryToken 'eyJheader.payload.signature')) { throw 'Credential helper rejected valid token characters' }
} catch { $failures += $_.Exception.Message }
Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseError in $errors) { $failures += "$($_.Name): $($parseError.Message)" }
}
function Test-FailedRead {
    param([string]$File, [string]$FunctionName)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root "scripts/$File"), [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    function Invoke-RestMethod { throw 'Synthetic denied request' }
    function Invoke-WebRequest { throw 'Synthetic denied request' }
    $caught = $false
    try { & $FunctionName 'https://management.azure.com/test' | Out-Null } catch { $caught = $true }
    if (-not $caught) { throw "$File swallowed a failed authenticated read" }
}
foreach ($case in @(@('Get-ClaudeTelemetry.ps1', 'Get-Arm'), @('Get-ClaudeBudget.ps1', 'Get-Nv'), @('Set-ClaudeBudget.ps1', 'Get-Nv'))) {
    try { Test-FailedRead $case[0] $case[1] } catch { $failures += $_.Exception.Message }
}
try {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Set-ClaudeBudget.ps1'), [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-BudgetUser' }, $true)
    if (-not $definition) { throw 'Missing testable budget identity resolver' }
    . ([scriptblock]::Create($definition.Extent.Text))
    function az {
        if ($args[2] -eq 'show') { $global:LASTEXITCODE = 1; return }
        $global:LASTEXITCODE = 0
        if ($args -contains '[0].id') { return '11111111-1111-1111-1111-111111111111' }
        return @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
    }
    $caught = $false
    try { Resolve-BudgetUser 'synthetic@example.org' | Out-Null } catch { $caught = $true }
    if (-not $caught) { throw 'Budget resolution accepted an ambiguous email match' }
    if ((Resolve-BudgetUser 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA') -cne 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') { throw 'Budget resolver did not normalize object ID' }
} catch { $failures += $_.Exception.Message }
try {
    $global:securityWriteCalls = 0
    function az {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'account') { return 'synthetic-token' }
        if ($args[0] -eq 'ad') { return '11111111-1111-1111-1111-111111111111' }
        if ($args[2] -eq 'show') { return '{"value":",11111111-1111-1111-1111-111111111111,"}' }
        $global:securityWriteCalls++
    }
    $global:securityGroupReads = 0
    function Invoke-RestMethod {
        $global:securityGroupReads++
        if ($global:securityGroupReads -eq 2) { throw 'Synthetic standard group read denied' }
        return @{ value = @(@{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'synthetic@example.org' }) }
    }
    $caught = $false
    try { & (Join-Path $root 'scripts/Sync-ClaudeAccess.ps1') -ApimName example -ResourceGroup example 6>$null } catch { $caught = $true }
    if (-not $caught -or $global:securityGroupReads -ne 2 -or $global:securityWriteCalls -ne 0) { throw 'Sync wrote entitlements before resolving both groups' }
} catch { $failures += $_.Exception.Message }
if ($failures.Count) { $failures | Write-Host; exit 1 }
Write-Host 'PowerShell script parsing and fail-closed read checks passed.'