# P76: one plan, one order on both shells. Sort-Object compares by culture, and Windows PowerShell
# 5.1 (.NET Framework, NLS) and PowerShell 7 (.NET, ICU) weigh a hyphen differently, so a plan built
# from a culture sort had two fingerprints: measured live on 2026-09-28 over the reference record,
# where Monitoring listed the two workbooks in a different order on each shell. Every sort in
# scripts/flow that feeds a plan orders by code point instead, and every shipped step is compared.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Guided flow - one order and one fingerprint on both shells' -ForegroundColor Cyan

# ------------------------------------------------------------------ no culture sort in scripts/flow
$hits = foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts\flow') -Recurse -Filter '*.ps1' -File)) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Sort-Object', 'sort' }, $true)) {
        '{0}:{1}' -f $f.FullName.Substring($root.Length + 1), $c.Extent.StartLineNumber
    }
}
Assert 'scripts/flow holds no Sort-Object: every sort that feeds a plan uses Sort-ClaudeFlowOrdinal' (@($hits).Count -eq 0) (@($hits) -join ', ')

$shells = [ordered]@{ '7' = (Get-Process -Id $PID).Path }
$ps51 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
if ($ps51 -and (Test-Path -LiteralPath $ps51)) { $shells['5.1'] = $ps51 }
else { Write-Host '  Windows PowerShell 5.1 is not on this machine; the comparisons need both shells and are left out.' -ForegroundColor Yellow }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-ordinal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
function Invoke-Probe([string]$Shell, [string]$Script, [string[]]$Arguments = @()) {
    $out = & $shells[$Shell] -NoProfile -NonInteractive -File $Script @Arguments 2>&1 | Out-String
    $json = @($out -split "`r?`n" | Where-Object { $_ -like 'P76JSON *' } | Select-Object -Last 1)
    if (-not $json.Count) { return [pscustomobject]@{ Failed = $true; Output = $out } }
    $parsed = $json[0].Substring(8) | ConvertFrom-Json
    $parsed | Add-Member -NotePropertyName Failed -NotePropertyValue $false
    $parsed | Add-Member -NotePropertyName Output -NotePropertyValue $out
    return $parsed
}
function Get-Tail([string]$Text) { (@($Text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' }

try {
    # ------------------------------------------------------------------ the helper
    # Words whose culture order differs between NLS and ICU: a hyphen, an underscore, a prefix. Every
    # comparison below is case-sensitive: -eq ignores case, and the order of 'B' and 'b' is part of it.
    $helperProbe = Join-Path $scratch 'helper.ps1'
    Set-Content -LiteralPath $helperProbe -Encoding UTF8 -Value @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\flow\FlowContract.ps1')
$words = @('workbook.json', 'workbook-chargeback.json', 'budgets', 'bu-members', 'Models-Standard', 'models-premium', 'claude-opus-5-5', 'claude-opus-5', 'coop', 'co-op', 'b', 'B', 'a_b', 'a-b')
$files = @([pscustomobject]@{ Name = 'workbook.json' }, [pscustomobject]@{ Name = 'workbook-chargeback.json' })
. (Join-Path $Root 'scripts\flow\Budgets.ps1')
$book = Get-BudgetsFlowPriceBook -Models @('zeta-model', 'claude-sonnet-5', 'Alpha-Model', 'alpha-model', 'zeta-model') -Path (Join-Path $Root 'config\price-book.example.json')
$result = [ordered]@{
    sorted = @(Sort-ClaudeFlowOrdinal -InputObject $words)
    unique = @(Sort-ClaudeFlowOrdinal -InputObject @('b', 'B', 'a', 'b') -Unique)
    files = @(Sort-ClaudeFlowOrdinal -InputObject $files -Key { $_.Name } | ForEach-Object { $_.Name })
    empty = @(Sort-ClaudeFlowOrdinal -InputObject @()).Count
    unpriced = @($book.unknownModels)
}
'P76JSON ' + ($result | ConvertTo-Json -Compress)
'@
    $expected = @('a-b', 'a_b', 'B', 'b', 'bu-members', 'budgets', 'claude-opus-5', 'claude-opus-5-5', 'co-op', 'coop', 'models-premium', 'Models-Standard', 'workbook-chargeback.json', 'workbook.json')
    foreach ($shell in $shells.Keys) {
        $h = Invoke-Probe $shell $helperProbe @('-Root', $root)
        Assert "PowerShell ${shell}: Sort-ClaudeFlowOrdinal orders by code point, ignoring case, with a code-point tie-break" (-not $h.Failed -and (@($h.sorted) -join ',') -ceq ($expected -join ',')) $(if ($h.Failed) { Get-Tail $h.Output } else { @($h.sorted) -join ',' })
        Assert "PowerShell ${shell}: -Unique keeps one of each ignoring case, and -Key sorts objects; an empty list is empty" (-not $h.Failed -and (@($h.unique) -join ',') -ceq 'a,B' -and (@($h.files) -join ',') -ceq 'workbook-chargeback.json,workbook.json' -and $h.empty -eq 0) $(if (-not $h.Failed) { "unique=$(@($h.unique) -join ',') files=$(@($h.files) -join ',') empty=$($h.empty)" })
        Assert "PowerShell ${shell}: the Budgets price book lists each unpriced model once, in code-point order" (-not $h.Failed -and (@($h.unpriced) -join ',') -ceq 'Alpha-Model,zeta-model') $(if (-not $h.Failed) { "unpriced=$(@($h.unpriced) -join ',')" })
    }

    if ($shells.Contains('5.1')) {
        # ------------------------------------------------------------------ every shipped Setup step
        # Planned offline (no Azure read) from one record and one answers file, on each shell.
        $record = Join-Path $scratch 'record.json'
        [ordered]@{
            schemaVersion = 2; mode = 'gateway'; gatewayUrl = 'https://apim-p76.azure-api.net'; apimName = 'apim-p76'; resourceGroup = 'rg-p76'
            decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2'; entitlementStore = 'named-value'; authMode = 'interactive'; desktopSignInKind = 'helper-script'; location = 'eastus2' } }
            deployments = @(@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5' }, @{ name = 'claude-opus-5'; model = 'claude-opus-5' }, @{ name = 'claude-opus-5-5'; model = 'claude-opus-5-5' })
            models = @('claude-sonnet-5', 'claude-opus-5', 'claude-opus-5-5')
            history = @()
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding UTF8
        $answers = Join-Path $scratch 'answers.json'
        @{ 'deviceProfiles.conversationStorage' = 'local' } | ConvertTo-Json | Set-Content -LiteralPath $answers -Encoding UTF8
        $stepProbe = Join-Path $scratch 'steps.ps1'
        Set-Content -LiteralPath $stepProbe -Encoding UTF8 -Value @'
param([string]$Root, [string]$RecordPath, [string]$AnswersPath)
$ErrorActionPreference = 'Stop'
$env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = '1'
Set-Location $Root
# Dot-sourced with Status, which writes nothing: the orchestrator's functions and record stay here.
. (Join-Path $Root 'Start-ClaudeGateway.ps1') -Action Status -RecordPath $RecordPath -AnswersPath $AnswersPath *> $null
$modules = Get-FlowModules -ModulePath (Join-Path $Root 'scripts\flow') -ForAction 'Setup'
$found = Get-FlowDiscoveryForSteps -Record $record -CurrentAction 'Setup' -Attended $false
$plans = [System.Collections.Generic.List[object]]::new()
$steps = [ordered]@{}
foreach ($step in @($modules.Steps)) {
    Invoke-Questions -Steps @($step) -Record $record -Discovery $found -CurrentAction 'Setup' *> $null
    $plan = & $step.Plan -Record $record -Discovery $found
    $plans.Add($plan)
    $steps[$step.Info.Name] = ConvertTo-ClaudeFlowCanonical $plan
}
. (Join-Path $Root 'scripts\flow\migrations\0002-policy-and-named-values.ps1')
$migration = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ policyHash = ''; namedValues = @() })
'P76JSON ' + ([ordered]@{
    steps = $steps
    fingerprint = (Get-ClaudeFlowFingerprint -Plans @($plans))
    references = @(Get-ClaudeFlowLifecyclePolicyNamedValueReferences)
    migration = (ConvertTo-ClaudeFlowCanonical $migration)
} | ConvertTo-Json -Compress -Depth 4)
'@
        $by = [ordered]@{}
        foreach ($shell in $shells.Keys) { $by[$shell] = Invoke-Probe $shell $stepProbe @('-Root', $root, '-RecordPath', $record, '-AnswersPath', $answers) }
        $p7 = $by['7']; $p5 = $by['5.1']
        Assert 'both shells plan every shipped Setup step offline from the record' (-not $p7.Failed -and -not $p5.Failed -and @($p7.steps.PSObject.Properties).Count -ge 5) ("7: " + $(if ($p7.Failed) { Get-Tail $p7.Output } else { @($p7.steps.PSObject.Properties.Name) -join ',' }) + " / 5.1: " + $(if ($p5.Failed) { Get-Tail $p5.Output } else { @($p5.steps.PSObject.Properties.Name) -join ',' }))
        if (-not $p7.Failed -and -not $p5.Failed) {
            $names7 = @($p7.steps.PSObject.Properties.Name); $names5 = @($p5.steps.PSObject.Properties.Name)
            Assert 'both shells plan the same steps in the same order' (($names7 -join ',') -ceq ($names5 -join ',')) "7=$($names7 -join ',') 5.1=$($names5 -join ',')"
            $differ = @(foreach ($n in $names7) {
                $a = [string]$p7.steps.$n; $b = [string]$p5.steps.$n
                if ($a -cne $b) { $i = 0; while ($i -lt [Math]::Min($a.Length, $b.Length) -and $a[$i] -ceq $b[$i]) { $i++ }; "$n at $i" }
            })
            Assert 'every shipped Setup step has the same canonical text on both shells' ($differ.Count -eq 0) ($differ -join '; ')
            Assert 'the Setup plan has one fingerprint on both shells' ($p7.fingerprint -and $p7.fingerprint -ceq $p5.fingerprint) "7=$($p7.fingerprint) 5.1=$($p5.fingerprint)"
            Assert 'the monitoring plan lists the workbooks in code-point order on both shells' ([string]$p7.steps.Monitoring -cmatch 'workbook-chargeback\.json.*workbook\.json' -and [string]$p5.steps.Monitoring -cmatch 'workbook-chargeback\.json.*workbook\.json') ''
            $r7 = @($p7.references); $r5 = @($p5.references)
            Assert 'the Update migration reads each of the policy''s named values once, in one order on both shells' ($r7.Count -gt 5 -and ($r7 -join ',') -ceq ($r5 -join ',') -and -not @($r7 | Group-Object | Where-Object { $_.Count -gt 1 }).Count) "7=$($r7 -join ',') 5.1=$($r5 -join ',')"
            Assert 'the Update migration''s plan has the same canonical text on both shells' ($p7.migration -and $p7.migration -ceq $p5.migration) ''
        }
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Every plan has one order and one fingerprint on both shells.' -ForegroundColor Green
exit 0
