$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path $root ('.test-work\p118-mutations-' + [guid]::NewGuid().ToString('N'))
$baselineCount = 32

function Copy-P118File([string]$RelativePath) {
    $source = Join-Path $root $RelativePath
    $target = Join-Path $sandbox $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target
}

function Invoke-P118FocusedTest {
    $output = & pwsh -NoProfile -File (Join-Path $sandbox 'tests\Test-ModelFamilyQuotas.ps1') 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

Write-Host ''
Write-Host 'P118 model-family quota negative mutations' -ForegroundColor Cyan

try {
    foreach ($relative in @(
        'Install-ClaudeGateway.ps1',
        'config\price-book.example.json',
        'infra\main.bicep',
        'infra\policy.xml',
        'schemas\claude-gateway.answers.schema.json',
        'scripts\ClaudeInstallCheckpoint.ps1',
        'scripts\ClaudeModelFamilyQuotas.ps1',
        'scripts\ClaudeModelPrices.ps1',
        'scripts\flow\FlowContract.ps1',
        'scripts\flow\lib\LifecycleCommon.ps1',
        'tests\Test-All.ps1',
        'tests\Test-ModelFamilyQuotas.ps1'
    )) { Copy-P118File $relative }

    $baseline = Invoke-P118FocusedTest
    if ($baseline.ExitCode -ne 0 -or $baseline.Output -notmatch "$baselineCount model-family quota assertion\(s\) passed") {
        throw "The unmutated P118 sandbox did not pass $baselineCount assertions.`n$($baseline.Output)"
    }

    $mutants = @(
        @{ Name = 'equal split removed'; File = 'scripts\ClaudeModelFamilyQuotas.ps1'
            Old = '$allocatedUsd = [decimal]$tierSpec.MonthlyUsd / [decimal]$families.Count'
            New = '$allocatedUsd = [decimal]$tierSpec.MonthlyUsd' },
        @{ Name = 'cheapest family rate used'; File = 'scripts\ClaudeModelFamilyQuotas.ps1'
            Old = '$rate = [decimal](($familyPrices | Measure-Object -Property BlendedUsdPerM -Maximum).Maximum)'
            New = '$rate = [decimal](($familyPrices | Measure-Object -Property BlendedUsdPerM -Minimum).Minimum)' },
        @{ Name = 'deployment alias mapping omitted'; File = 'scripts\ClaudeModelFamilyQuotas.ps1'
            Old = '$parts.Add("deployment`:$name=$($familiesByDeployment[$name])")'
            New = '[void]$familiesByDeployment[$name]' },
        @{ Name = 'exact alias precedence removed'; File = 'infra\policy.xml'
            Old = 'var marker = ",deployment:" + model + "=";'
            New = 'var marker = ",missing-deployment:" + model + "=";' },
        @{ Name = 'counter tier omitted'; File = 'infra\policy.xml'
            Old = ' + ":family:" + (string)context.Variables["tier"] + ":" + (string)context.Variables["modelFamily"]'
            New = ' + ":family:" + (string)context.Variables["modelFamily"]' },
        @{ Name = 'quota lookup tier omitted'; File = 'infra\policy.xml'
            Old = 'var marker = "," + tier + ":" + family + "=";'
            New = 'var marker = "," + family + "=";' },
        @{ Name = 'missing enabled-family entry allowed'; File = 'infra\policy.xml'
            Old = 'if (start &lt; 0) { return (long)-1; }'
            New = 'if (start &lt; 0) { return (long)0; }' },
        @{ Name = 'organisation ordering marker removed'; File = 'infra\policy.xml'
            Old = '<set-variable name="budget" value="organisation" />'
            New = '<set-variable name="budget" value="organisation-late" />' },
        @{ Name = 'existing rerun always recalculates'; File = 'scripts\ClaudeModelFamilyQuotas.ps1'
            Old = 'Recalculate = -not $ExistingGateway -or $monthlyChanged'
            New = 'Recalculate = $true' },
        @{ Name = 'preserved map skips az argument guard'; File = 'Install-ClaudeGateway.ps1'
            Old = 'Assert-AzArgumentsSafe -Values ([ordered]@{ ModelFamilyQuotas = $modelFamilyQuotas })'
            New = 'Write-Verbose $modelFamilyQuotas' },
        @{ Name = 'old gateway safe default removed'; File = 'scripts\flow\lib\LifecycleCommon.ps1'
            Old = 'models-premium|model-family-quotas|bu-registry'
            New = 'models-premium|bu-registry' }
    )

    foreach ($mutant in $mutants) {
        $path = Join-Path $sandbox $mutant.File
        $original = [IO.File]::ReadAllText($path)
        if (-not $original.Contains($mutant.Old)) { throw "Mutation anchor missing: $($mutant.Name)." }
        try {
            [IO.File]::WriteAllText($path, $original.Replace($mutant.Old, $mutant.New), [Text.UTF8Encoding]::new($false))
            if ($path.EndsWith('.ps1')) {
                $tokens = $null
                $errors = $null
                [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
                if ($errors.Count) { throw "Mutation '$($mutant.Name)' did not load: $($errors[0].Message)" }
            }
            $result = Invoke-P118FocusedTest
            if ($result.ExitCode -eq 0 -or $result.Output -notmatch "of $baselineCount assertion\(s\) failed") {
                throw "Mutation '$($mutant.Name)' was not caught by the loaded $baselineCount-assertion suite.`n$($result.Output)"
            }
            Write-Host "  [OK]   $($mutant.Name)" -ForegroundColor Green
        }
        finally {
            [IO.File]::WriteAllText($path, $original, [Text.UTF8Encoding]::new($false))
        }
    }
}
finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}

Write-Host ''
Write-Host '11 model-family quota mutants were caught without load failures.' -ForegroundColor Green
exit 0
