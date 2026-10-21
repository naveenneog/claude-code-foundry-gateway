# P119: each mutant of the project-identifier contract must fail its own assertion in
# Test-ProjectAttribution.ps1 while the suite still runs its full baseline count.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$files = 'infra\policy.xml', 'analytics\chargeback-ledger.kql', 'analytics\chargeback-cost.kql',
    'infra\workbook-chargeback.json', 'tests\Test-All.ps1', 'tests\Test-ProjectAttribution.ps1'
$pwsh = (Get-Process -Id $PID).Path

function Invoke-Suite([string]$Root) {
    $out = & $pwsh -NoProfile -NonInteractive -File (Join-Path $Root 'tests\Test-ProjectAttribution.ps1') 2>&1 | Out-String
    $count = [regex]::Match($out, '(\d+) project assertion').Groups[1].Value
    [pscustomobject]@{ Code = $LASTEXITCODE; Count = $count; Text = $out }
}

$mutants = @(
    @{ File = 'infra\policy.xml'; Old = '<set-header name="x-claude-project" exists-action="delete" />'; New = ''
       Name = 'header forwarded to Foundry'; Expect = 'removed before the request reaches Foundry' },
    @{ File = 'infra\policy.xml'; Old = '<metadata name="ProjectId" value="@((string)context.Variables["projectId"])" />'; New = ''
       Name = 'trace drops ProjectId'; Expect = 'chargeback trace carries ProjectId' },
    @{ File = 'infra\policy.xml'; Old = "(i > 0 && (c == '.' || c == '_' || c == '-'))"; New = "(c == '.' || c == '_' || c == '-')"
       Name = 'leading punctuation accepted'; Expect = 'malformed reads invalid' },
    @{ File = 'infra\policy.xml'; Old = 'if (value.Length > 64) { return "invalid"; }'; New = ''
       Name = 'no length limit'; Expect = 'malformed reads invalid' },
    @{ File = 'analytics\chargeback-ledger.kql'; Old = 'project_id = coalesce(project_id, "unspecified")'; New = 'project_id = project_id'
       Name = 'ledger leaves a missing project empty'; Expect = 'ClaudeChargeback reads ProjectId' },
    @{ File = 'analytics\chargeback-cost.kql'; Old = 'project_id = "cache (no project)",'; New = ''
       Name = 'cache rows lose their project label'; Expect = 'labels cache rows' },
    @{ File = 'infra\workbook-chargeback.json'
       Old = "\n| where '{Project}' == 'All' or project_id == '{Project}'\n| summarize USD = round(sum(usd), 4) by day"
       New = "\n| summarize USD = round(sum(usd), 4) by day"
       Name = 'one table ignores the Project filter'; Expect = 'also honours the Project filter' },
    @{ File = 'tests\Test-All.ps1'; Old = "    Invoke-Check 'Client project identifier in chargeback'   'Test-ProjectAttribution.ps1'"; New = ''
       Name = 'suite unregistered'; Expect = 'Test-All registers this suite' },
    @{ File = 'infra\policy.xml'; Old = '<set-header name="x-claude-project" exists-action="override">'; New = '<set-header name="x-claude-project-off" exists-action="override">'
       Name = 'recorded project not returned to the client'; Expect = 'tells the client which project was recorded' }
)

$scratch = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('p119-mutations-' + [guid]::NewGuid().ToString('N'))
$fail = 0
try {
    foreach ($f in $files) {
        $to = Join-Path $scratch $f
        New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $f) -Destination $to
    }
    $base = Invoke-Suite $scratch
    if ($base.Code -ne 0 -or -not $base.Count) { throw "[SETUP] the unmutated copy fails:`n$($base.Text)" }
    Write-Host ''
    Write-Host "P119 project identifier negative mutations (baseline $($base.Count) assertions)" -ForegroundColor Cyan
    foreach ($m in $mutants) {
        $path = Join-Path $scratch $m.File
        $original = [IO.File]::ReadAllText($path)
        if (-not $original.Contains($m.Old)) { Write-Host "  [FAIL] $($m.Name): mutation text not found" -ForegroundColor Red; $fail++; continue }
        try {
            [IO.File]::WriteAllText($path, $original.Replace($m.Old, $m.New))
            $r = Invoke-Suite $scratch
            $named = $r.Text -match ('\[FAIL\][^\r\n]*' + [regex]::Escape($m.Expect))
            if ($r.Code -ne 0 -and $r.Count -eq $base.Count -and $named) { Write-Host "  [OK]   $($m.Name)" -ForegroundColor Green }
            else { Write-Host "  [FAIL] $($m.Name) escaped (exit $($r.Code), $($r.Count) assertions, targeted=$named)" -ForegroundColor Red; $fail++ }
        }
        finally { [IO.File]::WriteAllText($path, $original) }
    }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail of $($mutants.Count) project mutants escaped." -ForegroundColor Red; exit 1 }
Write-Host "$($mutants.Count) project mutants were caught by their targeted assertion." -ForegroundColor Green
exit 0
