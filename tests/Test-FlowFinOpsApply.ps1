# P79: the guided flow's FinOps step runs each tool's commands with the parameters it plans. Found
# by the owner on 2026-09-28: every choice but None stopped with "Cannot convert value to type
# System.String." (FinOps.ps1, `& $path @($Command.arguments)`): @( ) passes the argument list as
# one array, which an advanced script refuses for a [string] parameter, and a string such as
# '-Accept' in a splatted array is a positional value to a script, not a parameter name.
# The scripts the step runs are replaced by stubs that carry the real scripts' parameter blocks and
# log what they were given, so a change to a real script's parameters reaches this test.
param([switch]$Child, [string]$Scratch)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, $Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

# What each choice must run: a PowerShell script with its named parameters, or aum with its arguments.
$expected = [ordered]@{
    None         = @()
    Direct       = @('Install-ClaudeAum.ps1 {}', 'aum configure --backend direct --no-prompt --save')
    AumService   = @('New-ClaudeAumEntraApp.ps1 {}', 'Deploy-ClaudeAumService.ps1 {Accept=True; Confirm=False}')
    Turnstile    = @('Connect-ClaudeTurnstile.ps1 {}')
    TurnstileAum = @('Connect-ClaudeTurnstile.ps1 {}', 'Install-ClaudeAum.ps1 {NoConfigure=True}', 'aum configure --backend turnstile --no-prompt --save')
}

if ($Child) {
    # One shell: apply every choice against the stubs and print what ran.
    $env:P79_FINOPS_LOG = Join-Path $Scratch 'finops-log.txt'
    function global:aum { Add-Content -LiteralPath $env:P79_FINOPS_LOG -Value ('aum ' + (@($args) -join ' ')); 'aum output that is not a change' }
    . (Join-Path $Scratch 'scripts\flow\FinOps.ps1')
    foreach ($tool in $expected.Keys) {
        if (Test-Path -LiteralPath $env:P79_FINOPS_LOG) { Remove-Item -LiteralPath $env:P79_FINOPS_LOG -Force }
        $record = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ finops = [pscustomobject]@{ tool = $tool } } }
        $result = [ordered]@{ tool = $tool; ran = @(); error = ''; returned = '' }
        try {
            # No region: the choices are built without reading the Retail Prices API.
            $plan = Get-ClaudeFlowStepPlan -Record $record -Discovery @{}
            $out = @(Invoke-ClaudeFlowStep -Record $record -Plan $plan)
            $result.returned = if ($out.Count -eq 1 -and $out[0] -is [System.Collections.IDictionary]) { 'one change set: ' + (@($out[0].Keys) -join ',') } else { "$($out.Count) objects" }
        }
        catch { $result.error = $_.Exception.Message }
        if (Test-Path -LiteralPath $env:P79_FINOPS_LOG) { $result.ran = @([IO.File]::ReadAllLines($env:P79_FINOPS_LOG)) }
        'P79JSON ' + ([pscustomobject]$result | ConvertTo-Json -Compress -Depth 4)
    }
    exit 0
}

Write-Host ''
Write-Host 'Guided flow - the FinOps step runs what it plans' -ForegroundColor Cyan
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-finops-apply-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'onboarding') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $scratch -Recurse
    # Connect-ClaudeTurnstile.ps1 takes its -ResourceGroup default from the record.
    @{ resourceGroup = 'rg-p79'; apimName = 'apim-p79' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $scratch 'onboarding\claude-gateway.json') -Encoding UTF8
    $stubbed = @()
    foreach ($name in 'Install-ClaudeAum.ps1', 'New-ClaudeAumEntraApp.ps1', 'Deploy-ClaudeAumService.ps1', 'Connect-ClaudeTurnstile.ps1') {
        $real = Join-Path $root "scripts\$name"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($real, [ref]$null, [ref]$null)
        if (-not $ast.ParamBlock) { throw "$name has no param block to copy." }
        $attributes = @($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
        # Output, as the real scripts write, so the step must keep it out of its change set.
        $body = @"
$attributes
$($ast.ParamBlock.Extent.Text)
`$bound = @(`$PSBoundParameters.Keys | Sort-Object | ForEach-Object { `$v = `$PSBoundParameters[`$_]; if (`$v -is [System.Management.Automation.SwitchParameter]) { `$v = [bool]`$v }; "`$_=`$v" }) -join '; '
Add-Content -LiteralPath `$env:P79_FINOPS_LOG -Value ('$name {' + `$bound + '}')
'$name output that is not a change'
"@
        [IO.File]::WriteAllText((Join-Path $scratch "scripts\$name"), $body, (New-Object System.Text.UTF8Encoding($false)))
        $stubbed += $name
    }
    Assert 'the four scripts the step runs are stubbed with their real parameter blocks' ($stubbed.Count -eq 4)

    $shells = [ordered]@{ '7' = (Get-Process -Id $PID).Path }
    $ps51 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
    if ($ps51 -and (Test-Path -LiteralPath $ps51)) { $shells['5.1'] = $ps51 }
    foreach ($shell in $shells.Keys) {
        $text = & $shells[$shell] -NoProfile -NonInteractive -File $PSCommandPath -Child -Scratch $scratch 2>&1 | Out-String
        $runs = @{}
        foreach ($line in @($text -split "`r?`n" | Where-Object { $_ -like 'P79JSON *' })) { $r = $line.Substring(8) | ConvertFrom-Json; $runs[[string]$r.tool] = $r }
        foreach ($tool in $expected.Keys) {
            $r = $runs[$tool]
            $want = @($expected[$tool])
            $ran = if ($r) { @($r.ran) } else { @() }
            $ok = $r -and -not $r.error -and (($ran -join ' | ') -ceq ($want -join ' | ')) -and $r.returned -ceq 'one change set: finops'
            $detail = if (-not $r) { (@($text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' } else { "error=[$($r.error)] ran=[$($ran -join ' | ')] returned=[$($r.returned)]" }
            Assert "PowerShell ${shell}: $tool runs $(if ($want.Count) { $want -join ', then ' } else { 'nothing' }), and returns only its change set" $ok $detail
        }
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'The FinOps step runs every tool as it plans.' -ForegroundColor Green
exit 0
