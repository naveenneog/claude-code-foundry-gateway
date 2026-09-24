param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent), [string]$KeepOutput)
$ErrorActionPreference = 'Stop'
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackReport.ps1')
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackQuery.ps1')
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackRender.ps1')
$fail = 0
$checks = 0
function Assert($Name, $Condition) {
    $script:checks++
    if (-not $Condition) { $script:fail++; Write-Host "FAIL: $Name" -ForegroundColor Red }
}
function Refuses($Name, [scriptblock]$Action, $Message) {
    $caught = $false
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message -match $Message }
    Assert $Name $caught
}
$fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\chargeback\usage.json') -Raw | ConvertFrom-Json
$base = Join-Path $SourceRoot ('.chargeback-test-' + [guid]::NewGuid().ToString('N'))
try {
    $w = Get-ClaudeReportWindow -Month '2024-02' -Now ([datetime]'2024-03-02T09:00:00Z')
    Assert 'leap month starts at UTC midnight' ($w.From -eq '2024-02-01T00:00:00.0000000Z')
    Assert 'leap month ends exclusively on first March' ($w.To -eq '2024-03-01T00:00:00.0000000Z')
    Assert 'saved inclusive functions stop one tick before March' ($w.QueryTo -eq '2024-02-29T23:59:59.9999999Z')
    $jan = Get-ClaudeReportWindow -Now ([datetime]'2026-01-12T01:00:00Z')
    Assert 'default crosses year boundary' ($jan.Month -eq '2025-12')
    $mtd = Get-ClaudeReportWindow -MonthToDate -Now ([datetime]'2026-09-24T12:34:56Z')
    Assert 'MTD uses fixed UTC snapshot, not end of calendar month' ($mtd.To -eq '2026-09-24T12:34:56.0000000Z')
    Refuses 'bad month rejected' { Get-ClaudeReportWindow -Month '2026-13' } 'yyyy-MM'
    Refuses 'future month rejected' { Get-ClaudeReportWindow -Month '2099-01' } 'future'
    foreach ($v in @('=1+1', '+1', '-1', '@SUM(A1)', "`t=1", "`r@x")) {
        Assert "formula escaped [$v]" ((ConvertTo-ClaudeReportCsvCell $v).StartsWith('"'''))
    }
    Assert 'CSV quotes are doubled' ((ConvertTo-ClaudeReportCsvCell 'a"b') -eq '"a""b"')
    Assert 'normal address remains text' ((ConvertTo-ClaudeReportCsvCell 'alice@contoso.com') -eq '"alice@contoso.com"')
    Assert 'HTML encoded' ((ConvertTo-ClaudeReportHtml '<script>&"') -eq '&lt;script&gt;&amp;&quot;')

    $q = Get-ClaudeReportQuery -Window $w -Kind People -Unit 'engineering' -HashPrefix 'af'
    Assert 'query uses saved cost, not a new tariff' ($q -match 'ClaudeCost\(datetime\(2024-02-01')
    Assert 'query respects exclusive end' ($q.Contains($w.QueryTo))
    Assert 'query scopes before server aggregation' ($q -match 'where Unit == "engineering"' -and $q -match 'summarize')
    Assert 'partition is stable and disjoint' ($q -match 'hash_sha256\(PersonKey\)' -and $q -match '"af"')
    Assert 'people query is bounded' ($q -match 'take 20001')
    Refuses 'KQL injection refused' { Get-ClaudeReportQuery -Window $w -Kind People -Unit 'x" | take 1' } 'identifier'
    Refuses 'unsafe filename refused' { Get-ClaudeReportFileName '../finance' } 'identifier'
    Assert 'reserved bucket has stable name' ((Get-ClaudeReportFileName 'unassigned') -eq 'unassigned')

    $source = @{ PricingDate = '2026-09-15'; MembershipDate = '2026-09-24'; Functions = @(); QueryVersion = 1 }
    $readPeople = { param($unit, $prefix) @($fixture.people | Where-Object Unit -eq $unit) }
    $readDimensions = { param($unit) @([pscustomobject]@{ Kind='Model'; Name='claude-sonnet-5'; Requests=1; EstimatedCostUsd=0.001 }) }
    $args = @{ Window=$w; Catalog=$fixture.catalog; Scopes=$fixture.scopes; ReadPeople=$readPeople; ReadDimensions=$readDimensions; Source=$source; OutputPath=$base; Format=@('CSV','HTML') }
    $result = Write-ClaudeChargebackReport @args
    $dir = $result.Path
    $manifest = Get-Content (Join-Path $dir 'manifest.json') -Raw | ConvertFrom-Json
    Assert 'manifest is complete only after reconciliation' ($manifest.Status -eq 'Complete' -and $manifest.Reconciliation.Matched)
    Assert 'workspace requests reconcile' ($manifest.Reconciliation.Workspace.Requests -eq 10)
    Assert 'workspace cache reads reconcile' ($manifest.Reconciliation.Units.CacheReadTokens -eq 8000)
    Assert 'unknown cache writes remain null' ($null -eq $manifest.Totals.CacheWrite5mTokens)
    Assert 'generation timestamp is UTC' ((Get-Content (Join-Path $dir 'manifest.json') -Raw) -match '"GeneratedUtc"\s*:\s*"[^"]+Z"')
    Assert 'pricing date comes from saved-function source' ($manifest.Source.PricingDate -eq '2026-09-15')
    $summary = @(Import-Csv (Join-Path $dir 'summary.csv'))
    Assert 'zero usage unit emitted' (@($summary | Where-Object { $_.Unit -eq 'research' -and $_.Requests -eq '0' }).Count -eq 1)
    Assert 'Unassigned is explicit, including summary' (@($summary | Where-Object Unit -eq 'unassigned').Count -eq 1)
    Assert 'team appears once as subdivision' (@($summary | Where-Object Team -eq 'platform').Count -eq 1)
    $csv = @(Import-Csv (Join-Path $dir 'engineering.csv'))
    Assert 'one row per engineering person' ($csv.Count -eq 2)
    Assert 'cache write blank, never zero' ($csv[0].CacheWrite5mTokens -eq '' -and $csv[0].CacheWrite1hTokens -eq '')
    Assert 'CSV cost preserves small costs' ([decimal]$csv[0].EstimatedCostUsd -gt 0)
    Assert 'unit CSV contains no other unit people' (-not (($csv.Person -join '') -match 'carol'))
    Assert 'formula in exported person escaped' (@($csv | Where-Object { $_.Person.StartsWith("'=") }).Count -eq 1)
    $html = Get-Content (Join-Path $dir 'engineering.html') -Raw
    Assert 'HTML name escaped, not active markup' ($html -match '&lt;Bob&gt;' -and $html -notmatch '<Bob>')
    Assert 'HTML contains no other unit people' ($html -notmatch 'carol@')
    foreach ($term in @('list price', 'Azure invoice', 'cache write', 'delayed brake', 'prompt and completion', 'UTC', 'Teams', 'Models', 'Clients')) {
        Assert "report prints $term" ($html -match [regex]::Escape($term))
    }
    Assert 'zero usage HTML has explicit empty state' ((Get-Content (Join-Path $dir 'research.html') -Raw) -match 'No usage')
    Assert 'no raw person keys in CSV' (-not ($csv[0].PSObject.Properties.Name -contains 'PersonKey'))
    foreach ($file in $manifest.Files) {
        Assert "hash for $($file.Name)" ((Get-FileHash (Join-Path $dir $file.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.Sha256)
    }
    $broken = @($fixture.scopes | Where-Object Unit -ne 'unassigned')
    Refuses 'missing Unassigned cannot reconcile' { Write-ClaudeChargebackReport @args -Scopes $broken } 'reconcil'
    # A separate splat avoids the duplicate parameter check: the failure must be mathematical.
    $bad = $args.Clone(); $bad.Scopes=$broken; $bad.OutputPath=Join-Path $base 'bad'
    Refuses 'dropped bucket fails mathematical reconciliation' { Write-ClaudeChargebackReport @bad } 'reconcil'
    $bad=$args.Clone(); $bad.ReadPeople={ param($unit,$prefix) $fixture.people }; $bad.OutputPath=Join-Path $base 'leak'
    Refuses 'cross-unit query rows refused before publication' { Write-ClaudeChargebackReport @bad } 'cross-unit'
    Assert 'failed report has no published manifest' (-not (Test-Path (Join-Path $base 'leak\2024-02\manifest.json')))
    $bad=$args.Clone(); $bad.ReadPeople={ param($unit,$prefix) @() }; $bad.OutputPath=Join-Path $base 'lost'
    Refuses 'dropped per-person tokens refused' { Write-ClaudeChargebackReport @bad } 'reconcil'
    $empty=$args.Clone(); $empty.OutputPath=Join-Path $base 'empty'; $empty.ReadPeople={ param($unit,$prefix) @() }; $empty.ReadDimensions={ param($unit) @() }
    $empty.Scopes=@([pscustomobject]@{Level='Workspace';Unit='';Team='';Requests=0;InputTokens=0;OutputTokens=0;CacheReadTokens=0;EstimatedCostUsd=0;People=0;UnpricedRows=0})
    $e=Write-ClaudeChargebackReport @empty
    $em=Get-Content (Join-Path $e.Path 'manifest.json') -Raw | ConvertFrom-Json
    Assert 'empty month reconciles explicitly' ($em.Reconciliation.Matched -and $em.Totals.Requests -eq 0)
    Assert 'empty month still has Unassigned CSV header' ((Get-Content (Join-Path $e.Path 'unassigned.csv')).Count -eq 1)
    $selected=$args.Clone(); $selected.OutputPath=Join-Path $base 'selected'; $selected.BusinessUnit=@('finance'); $selected.Format=@('CSV')
    $s=Write-ClaudeChargebackReport @selected
    Assert 'selection publishes only selected people' ((Test-Path (Join-Path $s.Path 'finance.csv')) -and -not (Test-Path (Join-Path $s.Path 'engineering.csv')))
    Assert 'JSON manifest exists without HTML selection' (Test-Path (Join-Path $s.Path 'manifest.json'))
    if ($KeepOutput) { New-Item -ItemType Directory -Path $KeepOutput -Force | Out-Null; Copy-Item "$dir\*" $KeepOutput -Force }
}
finally { if (Test-Path $base) { Remove-Item $base -Recurse -Force } }
if ($fail) { throw "$fail of $checks chargeback report assertions failed." }
Write-Host "$checks chargeback report assertions passed."
