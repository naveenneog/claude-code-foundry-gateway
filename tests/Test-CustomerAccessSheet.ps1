# Converts the customer's 47-group sheet into an access catalog the sync job accepts (scripts/ConvertTo-ClaudeAccessCatalog.ps1).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0; $script:count = 0; $expected = 5
function Assert([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green } else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''; Write-Host 'Customer sheet to access catalog' -ForegroundColor Cyan
$out = Join-Path ([IO.Path]::GetTempPath()) ('catalog-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    $log = & pwsh -NoProfile -File (Join-Path $root 'scripts\ConvertTo-ClaudeAccessCatalog.ps1') -InputPath (Join-Path $PSScriptRoot 'fixtures\customer-access-sheet.json') -OutputPath $out -Offline 2>&1 | Out-String
    Assert 'the 47-row sheet converts to 9 plans and 47 profiles' ($LASTEXITCODE -eq 0 -and $log -match '9 plans, 47 profiles') $log.Trim()
    $mod = ([Uri](Join-Path $root 'sync\src\access-catalog.mjs')).AbsoluteUri; $cat = ([Uri]$out).AbsoluteUri
    $probe = "import { canonicalizeAccessCatalog, createProfileSelector } from '$mod'; import { readFileSync } from 'node:fs'; import { fileURLToPath } from 'node:url'; const c = JSON.parse(readFileSync(fileURLToPath('$cat'),'utf8').replace(/^\uFEFF/,'')); const k = canonicalizeAccessCatalog(c); const s = createProfileSelector(c); const g = (r) => c.profiles.find(p => p.id.endsWith('-r'+r)).groupObjectId; const pick = (rows) => s.select(rows.map(g)).id; console.log(JSON.stringify({ plans: k.plans.length, profiles: k.profiles.length, a: pick([1,45]), d: pick([14,18]), b: pick([43,46]), c: pick([18,19]), m365: c.profiles.filter(p => p.connectors.includes('m365')).length, fable: c.profiles.filter(p => p.modelFamilies.includes('fable')).length }));"
    $r = & node --input-type=module -e $probe 2>&1 | Out-String
    $j = try { $r | ConvertFrom-Json } catch { $null }
    Assert 'the sync job''s validator accepts the catalog' ($j -and $j.plans -eq 9 -and $j.profiles -eq 47) $r.Trim()
    Assert 'highest monthly credit wins across groups' ($j -and $j.a -like '*-r45' -and $j.d -like '*-r18') $r.Trim()
    Assert 'at equal credit, M365 and then more model families win' ($j -and $j.b -like '*-r46' -and $j.c -like '*-r19') $r.Trim()
    Assert 'M365 and Fable map to the two and three rows that carry them' ($j -and $j.m365 -eq 2 -and $j.fable -eq 3) $r.Trim()
}
finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:count -ne $expected) { Write-Host "Expected $expected assertions, ran $($script:count)." -ForegroundColor Red; exit 1 }
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) assertion(s) passed." -ForegroundColor Green; exit 0
