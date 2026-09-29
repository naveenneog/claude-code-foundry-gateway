$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$engine = (Get-Process -Id $PID).Path
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('company-runner-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $scratch 'tests') -Force | Out-Null
$tokens = $null; $errors = $null
$runner = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-CompanyAddressNegative.ps1'), [ref]$tokens, [ref]$errors)
$fn = $runner.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Run-Suite' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$count = 0; $failed = 0
function Check([string]$Name, [scriptblock]$Test) {
    $script:count++
    try { $ok = [bool](& $Test); $why = '' } catch { $ok = $false; $why = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK] $Name" } else { $script:failed++; Write-Host "  [FAIL] $Name $why" }
}
function Fixture([string]$Name, [string]$Content) {
    [IO.File]::WriteAllText((Join-Path $scratch "tests\$Name"), $Content, (New-Object Text.UTF8Encoding($false)))
}
try {
    Fixture 'pass.ps1' @'
$global:P69RunnerLeak = 'must-not-survive'
Write-Host '  [OK] fixture'
Write-Host 'Company address: 3 assertions, 3 passed, 0 failed.'
exit 0
'@
    Fixture 'fail.ps1' @'
Write-Host '  [FAIL] fixture detector'
Write-Host 'Company address: 3 assertions, 2 passed, 1 failed.'
exit 9
'@
    Fixture 'isolated.ps1' @'
if (Get-Variable P69RunnerLeak -Scope Global -ErrorAction SilentlyContinue) {
    Write-Host 'Company address: 3 assertions, 2 passed, 1 failed.'
    exit 1
}
Write-Host 'Company address: 3 assertions, 3 passed, 0 failed.'
exit 0
'@
    Fixture 'partial.ps1' @'
Write-Host '  [FAIL] partial fixture'
throw 'Did not reach the full assertion count.'
'@
    Check 'suite runs use fresh runspaces rather than dozens of native startups' { $fn.Body.Extent.Text -match '\[powershell\]::Create\(\)' }
    Check 'a passing suite retains its full count and output' {
        $r = Run-Suite 'pass.ps1'
        $r.Code -eq 0 -and $r.Count -eq 3 -and $r.Text.Contains('[OK] fixture')
    }
    Check 'a failing suite preserves the exact exit code and named detector' {
        $r = Run-Suite 'fail.ps1'
        $r.Code -eq 9 -and $r.Count -eq 3 -and $r.Text.Contains('[FAIL] fixture detector')
    }
    Check 'globals from an earlier mutation cannot survive into the next suite' { (Run-Suite 'isolated.ps1').Code -eq 0 }
    Check 'a partial suite cannot be counted as a caught mutation' {
        try { Run-Suite 'partial.ps1'; $false } catch { $_.Exception.Message -match 'full summary' }
    }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Write-Host "Company mutation runner: $count assertions, $($count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
