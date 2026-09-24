# Periods, validation and the streaming report coordinator. Dot-source this file.
function Get-ClaudeReportWindow {
    param([string]$Month, [switch]$MonthToDate, [datetime]$Now = [datetime]::UtcNow)
    $nowUtc = $Now.ToUniversalTime()
    if (-not $Month) {
        $Month = if ($MonthToDate) { $nowUtc.ToString('yyyy-MM') } else { $nowUtc.AddMonths(-1).ToString('yyyy-MM') }
    }
    if ($Month -notmatch '^\d{4}-(0[1-9]|1[0-2])$') { throw 'Month must be yyyy-MM.' }
    try { $start = [datetime]::ParseExact("$Month-01", 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime() }
    catch { throw 'Month must be a valid yyyy-MM calendar month.' }
    if ($start -gt $nowUtc) { throw 'A future month cannot be reported.' }
    if ($MonthToDate -and $Month -ne $nowUtc.ToString('yyyy-MM')) { throw 'MonthToDate requires the current UTC month.' }
    $end = if ($MonthToDate) { $nowUtc } else { $start.AddMonths(1) }
    if ($end -gt $nowUtc -and -not $MonthToDate) { throw 'The month is not complete. Use -MonthToDate for the current month.' }
    [pscustomobject]@{
        Month=$Month; From=$start.ToString('o'); To=$end.ToString('o')
        QueryTo=$end.AddTicks(-1).ToString('o'); MonthToDate=[bool]$MonthToDate
    }
}

function Get-ClaudeReportFileName {
    param([string]$Unit)
    if ($Unit -notmatch '^[a-z0-9][a-z0-9-]{0,99}$' -or $Unit -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9]|index|summary|manifest)$') {
        throw 'Invalid report unit identifier. Use 1-100 lower-case letters, digits or hyphens; reserved filenames are not allowed.'
    }
    return $Unit
}

function New-ClaudeReportTotals {
    [pscustomobject][ordered]@{
        Requests=[long]0; InputTokens=[long]0; OutputTokens=[long]0; CacheReadTokens=[long]0
        CacheWrite5mTokens=$null; CacheWrite1hTokens=$null; EstimatedCostUsd=[decimal]0
        People=[long]0; UnpricedRows=[long]0
    }
}

function Add-ClaudeReportTotals {
    param($To, $Row)
    foreach ($key in @('Requests','InputTokens','OutputTokens','CacheReadTokens')) {
        if ($null -eq $Row.$key -or [decimal]$Row.$key -lt 0 -or [decimal]$Row.$key -ne [long]$Row.$key) {
            throw "Invalid or missing $key in report query result."
        }
        $To.$key += [long]$Row.$key
    }
    if ($null -eq $Row.EstimatedCostUsd -or [decimal]$Row.EstimatedCostUsd -lt 0) { throw 'Invalid or missing EstimatedCostUsd in report query result.' }
    $To.EstimatedCostUsd += [decimal]$Row.EstimatedCostUsd
    $To.UnpricedRows += [long]$Row.UnpricedRows
}

function Assert-ClaudeReportReconciliation {
    param($Expected, $Actual, [string]$Scope)
    foreach ($key in @('Requests','InputTokens','OutputTokens','CacheReadTokens')) {
        if ([decimal]$Expected.$key -ne [decimal]$Actual.$key) { throw "Report reconciliation failed for $Scope ($key). No report was published." }
    }
    if ([math]::Abs([decimal]$Expected.EstimatedCostUsd - [decimal]$Actual.EstimatedCostUsd) -gt [decimal]0.000001) {
        throw "Report reconciliation failed for $Scope (EstimatedCostUsd). No report was published."
    }
}

function Write-ClaudeReportJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
}

function Write-ClaudeChargebackReport {
    [CmdletBinding()]
    param(
        $Window, [object[]]$Catalog, [object[]]$Scopes, [scriptblock]$ReadPeople, [scriptblock]$ReadDimensions,
        $Source, [string]$OutputPath, [string[]]$BusinessUnit, [ValidateSet('CSV','HTML')][string[]]$Format = @('CSV','HTML')
    )
    $workspace = @($Scopes | Where-Object Level -eq 'Workspace')
    if ($workspace.Count -ne 1) { throw 'Report reconciliation requires exactly one workspace total.' }
    $units = @{}
    $teams = New-Object 'System.Collections.Generic.List[object]'
    foreach ($scope in $Scopes) {
        if ($scope.Level -eq 'Unit') {
            $id = Get-ClaudeReportFileName $scope.Unit
            if ($units.ContainsKey($id)) { throw 'Report reconciliation found duplicate unit totals.' }
            $units[$id] = $scope
        }
        elseif ($scope.Level -eq 'Team') { $teams.Add($scope) }
    }
    $catalogById = @{}
    foreach ($entry in $Catalog) {
        $id = Get-ClaudeReportFileName $entry.Id
        $catalogById[$id] = $entry
        if (-not $entry.Parent -and -not $units.ContainsKey($id)) {
            $z = New-ClaudeReportTotals
            $z | Add-Member NoteProperty Unit $id
            $units[$id] = $z
        }
        if ($entry.Parent -and -not @($teams | Where-Object Team -eq $id).Count) {
            $z = New-ClaudeReportTotals
            $z | Add-Member NoteProperty Unit $entry.Parent
            $z | Add-Member NoteProperty Team $id
            $teams.Add($z)
        }
    }
    if (-not $units.ContainsKey('unassigned')) {
        $z = New-ClaudeReportTotals
        $z | Add-Member NoteProperty Unit 'unassigned'
        $units['unassigned'] = $z
    }
    $all = New-ClaudeReportTotals
    foreach ($u in $units.Values) { Add-ClaudeReportTotals $all $u }
    Assert-ClaudeReportReconciliation $workspace[0] $all 'workspace (units plus Unassigned)'
    $ids = @($units.Keys | Sort-Object)
    if ($BusinessUnit) {
        foreach ($id in $BusinessUnit) {
            Get-ClaudeReportFileName $id | Out-Null
            if (-not $units.ContainsKey($id)) { throw "Unknown root business unit '$id'. Team filters are not unit reports." }
        }
        $ids = @($BusinessUnit | Sort-Object -Unique)
    }
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    $destination = Join-Path $root $Window.Month
    if ((Test-Path $destination) -and -not (Test-Path (Join-Path $destination 'manifest.json'))) {
        throw 'Output month directory exists without a report manifest; refusing to replace unrelated files.'
    }
    $stage = Join-Path $root ('.building-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $summaries = New-Object 'System.Collections.Generic.List[object]'
    $selectedTotals = New-ClaudeReportTotals
    $rowsWritten = [long]0
    try {
        foreach ($id in $ids) {
            $expected = $units[$id]
            $actual = New-ClaudeReportTotals
            $top = New-Object 'System.Collections.Generic.List[object]'
            $writer = $null
            if ($Format -contains 'CSV') { $writer = New-ClaudeReportCsvWriter (Join-Path $stage "$id.csv") $script:ClaudeReportPersonColumns }
            try {
                $pending = New-Object 'System.Collections.Generic.Stack[string]'
                $pending.Push('')
                while ($pending.Count) {
                    $prefix = $pending.Pop()
                    $page = & $ReadPeople $id $prefix
                    $people = @($page | Where-Object { $null -ne $_ })
                    if ($people.Count -ge 20001) {
                        if ($prefix.Length -ge 8) { throw 'A person partition cannot be bounded. No report was published.' }
                        foreach ($hex in '0123456789abcdef'.ToCharArray()) { $pending.Push("$prefix$hex") }
                        continue
                    }
                    foreach ($person in $people) {
                        if ($person.Unit -cne $id) { throw "Refusing cross-unit row in report '$id'." }
                        Add-ClaudeReportTotals $actual $person
                        $actual.People++
                        if ($writer) { Write-ClaudeReportCsvRow $writer $person $script:ClaudeReportPersonColumns }
                        if ($top.Count -lt 20 -or [decimal]$person.EstimatedCostUsd -gt [decimal]$top[$top.Count-1].EstimatedCostUsd) {
                            $top.Add($person)
                            $sorted = @($top | Sort-Object { [decimal]$_.EstimatedCostUsd } -Descending | Select-Object -First 20)
                            $top.Clear()
                            foreach ($p in $sorted) { $top.Add($p) }
                        }
                    }
                }
            }
            finally { if ($writer) { $writer.Dispose() } }
            Assert-ClaudeReportReconciliation $expected $actual $id
            if ([long]$expected.People -ne $actual.People) { throw "Report reconciliation failed for $id (people count)." }
            $rowsWritten += $actual.People
            Add-ClaudeReportTotals $selectedTotals $actual
            $selectedTotals.People += $actual.People
            $summary = New-ClaudeReportSummary $id '' $expected $catalogById
            $summaries.Add($summary)
            $unitTeams = @($teams | Where-Object Unit -eq $id | Sort-Object Team)
            foreach ($t in $unitTeams) { $summaries.Add((New-ClaudeReportSummary $id $t.Team $t $catalogById)) }
            if ($Format -contains 'HTML') {
                $dimensions = & $ReadDimensions $id
                $html = New-ClaudeReportUnitHtml $Window $summary $unitTeams $top.ToArray() @($dimensions) $Source
                [IO.File]::WriteAllText((Join-Path $stage "$id.html"), $html, (New-Object Text.UTF8Encoding($false)))
            }
        }
        if ($Format -contains 'CSV') {
            $writer = New-ClaudeReportCsvWriter (Join-Path $stage 'summary.csv') $script:ClaudeReportSummaryColumns
            try { foreach ($s in $summaries) { Write-ClaudeReportCsvRow $writer $s $script:ClaudeReportSummaryColumns } }
            finally { $writer.Dispose() }
        }
        if ($Format -contains 'HTML') {
            $html = New-ClaudeReportIndexHtml $Window $summaries.ToArray() $selectedTotals $Source
            [IO.File]::WriteAllText((Join-Path $stage 'index.html'), $html, (New-Object Text.UTF8Encoding($false)))
        }
        $files = @(Get-ChildItem $stage -File | Sort-Object Name | ForEach-Object {
            [ordered]@{ Name=$_.Name; Bytes=$_.Length; Sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
        $manifest = [ordered]@{
            SchemaVersion=1; RunId=([datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
            Status='Complete'; Month=$Window.Month; Window=$Window; GeneratedUtc=[datetime]::UtcNow.ToString('o')
            BusinessUnits=$ids; Formats=$Format; PersonRows=$rowsWritten; SummaryRows=$summaries.Count
            Totals=$selectedTotals; Source=$Source; Files=$files; Sends=@()
            Reconciliation=@{ Matched=$true; Workspace=$workspace[0]; Units=$all; Unassigned=$units['unassigned']; MoneyToleranceUsd=0.000001 }
            Caveats=$script:ClaudeReportCaveats
        }
        Write-ClaudeReportJson (Join-Path $stage 'manifest.json') $manifest
        if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
        Move-Item $stage $destination
        [pscustomobject]@{ Path=$destination; Manifest=$manifest }
    }
    finally { if (Test-Path $stage) { Remove-Item $stage -Recurse -Force } }
}
