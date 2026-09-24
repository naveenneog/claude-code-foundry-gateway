<#
.SYNOPSIS
    Measures offline generation with at least 100,000 synthetic Contoso person rows.
#>
param([ValidateRange(100000,500000)][int]$People=100000,[string]$ReceiptPath)
$ErrorActionPreference='Stop'
if($People % 10000 -ne 0) {throw 'Use a multiple of 10,000 synthetic people.'}
$root=Split-Path $PSScriptRoot -Parent
foreach($helper in @('Report','Query','Render')) {. (Join-Path $root "scripts\ClaudeChargeback$helper.ps1")}
$work=Join-Path $root ('.chargeback-benchmark-'+[guid]::NewGuid().ToString('N'))
$catalog=New-Object 'System.Collections.Generic.List[object]'
$scopes=New-Object 'System.Collections.Generic.List[object]'
$units=[int]($People/10000)
for($i=0;$i -lt $units;$i++) {
    $catalog.Add([pscustomobject]@{Id="unit-$i";Group="Contoso unit $i";TokensPerMonth=100000000;Parent=''})
    $scopes.Add([pscustomobject]@{Level='Unit';Unit="unit-$i";Team='';Requests=10000;InputTokens=1000000;OutputTokens=200000;CacheReadTokens=10000000;EstimatedCostUsd=6;People=10000;UnpricedRows=0})
}
$scopes.Add([pscustomobject]@{Level='Workspace';Unit='';Team='';Requests=$People;InputTokens=$People*100;OutputTokens=$People*20;CacheReadTokens=$People*1000;EstimatedCostUsd=([decimal]$People*[decimal]0.0006);People=$People;UnpricedRows=0})
$reader={
    param($unit,$prefix)
    if($unit -eq 'unassigned') {return}
    for($i=0;$i -lt 10000;$i++) {
        [pscustomobject]@{Unit=$unit;PersonKey="$unit-$i";Person="developer-$unit-$i@contoso.com";Team='';Tier='standard'
            Requests=1;InputTokens=100;OutputTokens=20;CacheReadTokens=1000;EstimatedCostUsd=[decimal]0.0006;TopModel='claude-sonnet-5';Clients='sdk-cli; cache (no surface)'}
    }
}
$dimensions={
    param($unit)
    if($unit -eq 'unassigned') {return @()}
    @([pscustomobject]@{Kind='Model';Name='claude-sonnet-5';Requests=10000;EstimatedCostUsd=6},
      [pscustomobject]@{Kind='Client';Name='sdk-cli / cache (fixture)';Requests=10000;EstimatedCostUsd=6})
}
$window=Get-ClaudeReportWindow -Month '2026-08'
$source=@{PricingDate='2026-09-15';MembershipDate='2026-09-24';Functions=@();QueryVersion=1}
$clock=[Diagnostics.Stopwatch]::StartNew()
try {
    $r=Write-ClaudeChargebackReport -Window $window -Catalog $catalog.ToArray() -Scopes $scopes.ToArray() -ReadPeople $reader `
        -ReadDimensions $dimensions -Source $source -OutputPath $work -Format CSV,HTML
    $clock.Stop()
    if($r.Manifest.PersonRows -ne $People -or -not $r.Manifest.Reconciliation.Matched) {throw 'Synthetic report did not preserve all person rows.'}
    $bytes=(Get-ChildItem $r.Path -File | Measure-Object Length -Sum).Sum
    $receipt=[ordered]@{
        Measurement='MEASURED offline generation, including synthetic row construction, CSV/HTML/hash/manifest. Not Azure query time.'
        Utc=[datetime]::UtcNow.ToString('o');People=$People;Units=$units;Seconds=[math]::Round($clock.Elapsed.TotalSeconds,3)
        RowsPerSecond=[math]::Round($People/$clock.Elapsed.TotalSeconds);OutputBytes=$bytes;PeakWorkingSetBytes=[Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64
        PowerShell=$PSVersionTable.PSVersion.ToString();Reconciled=$r.Manifest.Reconciliation.Matched
    }
    if($ReceiptPath) {Write-ClaudeReportJson $ReceiptPath $receipt}
    $receipt | ConvertTo-Json
}
finally {if(Test-Path $work){Remove-Item $work -Recurse -Force}}
