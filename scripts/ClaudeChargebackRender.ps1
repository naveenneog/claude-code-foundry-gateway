# Email-safe HTML and streaming, formula-safe CSV. No external assets or tracking.
$script:ClaudeReportPersonColumns = @('Unit','Person','Team','Tier','Requests','InputTokens','OutputTokens','CacheReadTokens','CacheWrite5mTokens','CacheWrite1hTokens','EstimatedCostUsd','TopModel','Clients','UnpricedRows')
$script:ClaudeReportSummaryColumns = @('Unit','Team','Name','Requests','InputTokens','OutputTokens','CacheReadTokens','CacheWrite5mTokens','CacheWrite1hTokens','EstimatedCostUsd','BudgetTokens','BudgetUsdEstimate','UsedPercent','People','UnpricedRows')
$script:ClaudeReportCaveats = @(
    'Figures are at list price and are not reconciled to an Azure invoice (U2). Costs are derived; tokens and requests are measured in the saved ledger.'
    'Cache reads are attributed from the gateway metric. The two cache write categories are unknown, not zero; real spend is higher than shown.'
    'The budget counter counts prompt and completion only. Cache reads are real cost but neither cache category is counted by the budget (U13).'
    'Enforcement is a delayed brake: it blocks approximately, with overshoot, not a hard spend guarantee (U9/U13).'
    'Attribution and prices use the published ClaudeCost snapshot. Budgets are current at generation, not historical. Telemetry may arrive late; a restatement can change.'
)

function ConvertTo-ClaudeReportCsvCell {
    param($Value)
    $text = if ($null -eq $Value) { '' } elseif ($Value -is [IFormattable]) { $Value.ToString($null,[cultureinfo]::InvariantCulture) } else { [string]$Value }
    if ($text -match '^[\s\x00-\x1f]*[=+\-@]' -or $text -match '^[\t\r\n]') { $text = "'" + $text }
    return '"' + $text.Replace('"','""') + '"'
}

function ConvertTo-ClaudeReportHtml {
    param($Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-ClaudeReportCsvWriter {
    param([string]$Path, [string[]]$Columns)
    $writer = New-Object IO.StreamWriter($Path,$false,(New-Object Text.UTF8Encoding($true)))
    $writer.WriteLine(($Columns -join ','))
    return $writer
}

function Write-ClaudeReportCsvRow {
    param($Writer, $Row, [string[]]$Columns)
    $cells = New-Object string[] $Columns.Count
    for ($i=0; $i -lt $Columns.Count; $i++) { $cells[$i]=ConvertTo-ClaudeReportCsvCell $Row.($Columns[$i]) }
    $Writer.WriteLine(($cells -join ','))
}

function New-ClaudeReportSummary {
    param([string]$Unit,[string]$Team,$Totals,$Catalog)
    $id=if ($Team) { $Team } else { $Unit }
    $entry=$Catalog[$id]
    $budget=if ($entry) { [long]$entry.TokensPerMonth } else { $null }
    # The registry stores only tokens. The USD budget is a labelled Sonnet/20% output estimate,
    # not the original dollars that an administrator entered.
    . (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
    $budgetUsd=if ($null -ne $budget) { ConvertTo-ClaudeBuUsd -Tokens $budget -Model 'claude-sonnet-5' -OutputShare 0.2 } else { $null }
    [pscustomobject][ordered]@{
        Unit=$Unit; Team=$Team; Name=$(if ($entry) {$entry.Group} elseif ($id -eq 'unassigned') {'Unassigned'} else {$id})
        Requests=[long]$Totals.Requests; InputTokens=[long]$Totals.InputTokens; OutputTokens=[long]$Totals.OutputTokens
        CacheReadTokens=[long]$Totals.CacheReadTokens; CacheWrite5mTokens=$null; CacheWrite1hTokens=$null
        EstimatedCostUsd=[decimal]$Totals.EstimatedCostUsd; BudgetTokens=$budget; BudgetUsdEstimate=$budgetUsd
        UsedPercent=$(if ($budget -gt 0) { [math]::Round((([decimal]$Totals.InputTokens + [decimal]$Totals.OutputTokens)/$budget)*100,2,[MidpointRounding]::AwayFromZero) } else {$null})
        People=[long]$Totals.People; UnpricedRows=[long]$Totals.UnpricedRows
    }
}

function Format-ClaudeReportNumber {
    param($Value, [string]$Format='N0')
    if ($null -eq $Value -or "$Value" -eq '') { return 'Unknown' }
    return ([decimal]$Value).ToString($Format,[cultureinfo]::InvariantCulture)
}

function New-ClaudeReportTable {
    param([string[]]$Headings,[object[]]$Rows)
    $b=New-Object Text.StringBuilder
    [void]$b.Append('<div style="overflow-x:auto"><table cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;font-size:13px;text-align:left"><thead><tr>')
    foreach($h in $Headings) { [void]$b.Append('<th scope="col" style="padding:9px 8px;border-bottom:2px solid #d4d8e2;color:#374151">' + (ConvertTo-ClaudeReportHtml $h) + '</th>') }
    [void]$b.Append('</tr></thead><tbody>')
    if (-not $Rows.Count) { [void]$b.Append('<tr><td colspan="' + $Headings.Count + '" style="padding:12px 8px">No usage recorded in this period.</td></tr>') }
    foreach($row in $Rows) {
        [void]$b.Append('<tr>')
        foreach($cell in $row.Cells) { [void]$b.Append('<td style="padding:9px 8px;border-bottom:1px solid #e5e7eb;vertical-align:top;overflow-wrap:anywhere">' + (ConvertTo-ClaudeReportHtml $cell) + '</td>') }
        [void]$b.Append('</tr>')
    }
    [void]$b.Append('</tbody></table></div>')
    return $b.ToString()
}

function New-ClaudeReportPage {
    param([string]$Title,$Window,[string]$Body,$Source)
    $notes=($script:ClaudeReportCaveats | ForEach-Object { '<li style="margin:6px 0">' + (ConvertTo-ClaudeReportHtml $_) + '</li>' }) -join ''
    $safeTitle=ConvertTo-ClaudeReportHtml $Title
    $period=ConvertTo-ClaudeReportHtml "$($Window.From) to $($Window.To) (exclusive)"
    return @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$safeTitle</title>
<style>@media(max-width:600px){.report{padding:18px!important}h1{font-size:23px!important}}@media print{body{background:white!important}.report{max-width:none!important}}</style></head>
<body style="margin:0;background:#f4f5f7;color:#1a1a1a;font-family:Segoe UI,Arial,sans-serif">
<main class="report" style="max-width:860px;margin:24px auto;padding:32px;background:white">
<p style="margin:0 0 12px;color:#4b5563;font-size:14px">Claude gateway / Monthly usage report / $($Window.Month)</p>
<h1 style="margin:0 0 12px;font-size:28px;line-height:1.2;color:#1E2761">$safeTitle</h1>
<p style="margin:0 0 24px;font-size:12px;color:#4b5563;overflow-wrap:anywhere">UTC: $period</p>
$Body
<section style="margin-top:28px;padding:16px;background:#f4f5f7;border:1px solid #d4d8e2"><h2 style="font-size:16px;margin:0 0 8px">How to read these figures</h2>
<ul style="font-size:12px;line-height:1.5;margin:0;padding-left:20px">$notes</ul></section>
<p style="font-size:12px;line-height:1.5;color:#4b5563;margin-top:18px">Price book: $(ConvertTo-ClaudeReportHtml $Source.PricingDate).
Reconciled to the workspace ledger, including Unassigned. This is showback, not an invoice.
CSV contains every person; this page shows the 20 highest estimated costs. Internal usage data: share only with authorized recipients.</p>
</main></body></html>
"@
}

function New-ClaudeReportUnitHtml {
    param($Window,$Summary,[object[]]$Teams,[object[]]$People,[object[]]$Dimensions,$Source)
    $rows=@(
        [pscustomobject]@{Cells=@('Estimated list-price cost (USD)',(Format-ClaudeReportNumber $Summary.EstimatedCostUsd 'N6'))}
        [pscustomobject]@{Cells=@('Requests / people',((Format-ClaudeReportNumber $Summary.Requests) + ' / ' + (Format-ClaudeReportNumber $Summary.People)))}
        [pscustomobject]@{Cells=@('Input / output tokens',((Format-ClaudeReportNumber $Summary.InputTokens) + ' / ' + (Format-ClaudeReportNumber $Summary.OutputTokens)))}
        [pscustomobject]@{Cells=@('Cache read tokens',(Format-ClaudeReportNumber $Summary.CacheReadTokens))}
        [pscustomobject]@{Cells=@('Cache write tokens (5 minute / 1 hour)','Unknown / Unknown')}
        [pscustomobject]@{Cells=@('Budget tokens / used %',((Format-ClaudeReportNumber $Summary.BudgetTokens) + ' / ' + (Format-ClaudeReportNumber $Summary.UsedPercent 'N2')))}
    )
    $body=New-ClaudeReportTable @('Measure','Value') $rows
    if ($Summary.UnpricedRows -gt 0) { $body += '<p style="color:#9f1239">Warning: unpriced ledger rows exist. Estimated cost is incomplete.</p>' }
    $body+='<h2 style="font-size:18px;margin-top:24px">Teams</h2>'
    $body+=New-ClaudeReportTable @('Team','Requests','Estimated USD') @($Teams | ForEach-Object { [pscustomobject]@{Cells=@($_.Team,(Format-ClaudeReportNumber $_.Requests),(Format-ClaudeReportNumber $_.EstimatedCostUsd 'N6'))} })
    $body+='<h2 style="font-size:18px;margin-top:24px">Top people</h2>'
    $body+=New-ClaudeReportTable @('Person','Team / tier','Requests','Estimated USD') @($People | ForEach-Object { [pscustomobject]@{Cells=@($_.Person,("$($_.Team) / $($_.Tier)"),(Format-ClaudeReportNumber $_.Requests),(Format-ClaudeReportNumber $_.EstimatedCostUsd 'N6'))} })
    foreach($kind in @('Model','Client')) {
        $body+="<h2 style=`"font-size:18px;margin-top:24px`">${kind}s</h2>"
        $body+=New-ClaudeReportTable @($kind,'Requests','Estimated USD') @($Dimensions | Where-Object Kind -eq $kind | Sort-Object EstimatedCostUsd -Descending | ForEach-Object { [pscustomobject]@{Cells=@($_.Name,(Format-ClaudeReportNumber $_.Requests),(Format-ClaudeReportNumber $_.EstimatedCostUsd 'N6'))} })
    }
    return New-ClaudeReportPage $Summary.Name $Window $body $Source
}

function New-ClaudeReportIndexHtml {
    param($Window,[object[]]$Summaries,$Totals,$Source)
    $body='<p style="font-size:15px">Selected units: ' + (Format-ClaudeReportNumber $Totals.Requests) + ' requests; USD ' + (Format-ClaudeReportNumber $Totals.EstimatedCostUsd 'N6') + ' estimated list-price cost. Team rows are subdivisions, not additional spend.</p>'
    if($Totals.UnpricedRows -gt 0) {$body+='<p style="color:#9f1239">Warning: unpriced ledger rows exist. Estimated cost is incomplete; see UnpricedRows in summary.csv.</p>'}
    $rows=@($Summaries | ForEach-Object { [pscustomobject]@{Cells=@($_.Name,$_.Unit,$_.Team,(Format-ClaudeReportNumber $_.Requests),(Format-ClaudeReportNumber $_.People),(Format-ClaudeReportNumber $_.EstimatedCostUsd 'N6'))} })
    $body+=New-ClaudeReportTable @('Name','Unit','Team','Requests','People','Estimated USD') $rows
    return New-ClaudeReportPage 'Business-unit chargeback' $Window $body $Source
}
