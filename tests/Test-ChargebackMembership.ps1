# P120: ClaudeCost reads current membership from the projection sync job's console log (ADR-0066).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:count = 0
function Assert([string]$Label, [bool]$Condition, [string]$Detail = '') {
    $script:count++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'P120 chargeback membership from the sync job' -ForegroundColor Cyan

$cost = [IO.File]::ReadAllText((Join-Path $root 'analytics\chargeback-cost.kql'))
$events = [IO.File]::ReadAllText((Join-Path $root 'sync\src\events.mjs'))
$renewal = [IO.File]::ReadAllText((Join-Path $root 'infra\projection-renewal.bicep'))
$testAll = [IO.File]::ReadAllText((Join-Path $root 'tests\Test-All.ps1'))

$event = [regex]::Match($events, "export const MEMBERSHIP_EVENT = '([^']+)'").Groups[1].Value
$jobPrefix = [regex]::Match($renewal, "var jobName = '([a-z-]+)\$\{").Groups[1].Value
Assert 'the job names its membership event and its job-name prefix' ($event -and $jobPrefix) "event '$event', prefix '$jobPrefix'"

$section = [regex]::Match($cost, '// JOB-MEMBERSHIP-BEGIN(?<body>.*?)// JOB-MEMBERSHIP-END', [Text.RegularExpressions.RegexOptions]::Singleline)
Assert 'ClaudeCost has one job-membership section' ($section.Success -and ([regex]::Matches($cost, '// JOB-MEMBERSHIP-BEGIN').Count -eq 1))
$job = $section.Groups['body'].Value
$published = [regex]::Match($cost, '// MEMBERSHIP-BEGIN.*?// MEMBERSHIP-END', [Text.RegularExpressions.RegexOptions]::Singleline)
Assert 'the published membership the publisher replaces is still there, before the job section' (
    $published.Success -and $section.Success -and $published.Index -lt $section.Index)

Assert 'it reads the console log through a fuzzy union, so a workspace without the table still runs' (
    $job -match 'union isfuzzy=true \(datatable\(TimeGenerated: datetime, JobName: string, Log: string\) \[\]\), ContainerAppConsoleLogs')
Assert 'it reads three days, whatever period the report covers' ($job -match '\| where TimeGenerated > ago\(3d\)' -and $job -notmatch '_from|_to')
Assert "it keeps lines from jobs named $jobPrefix* only" ($jobPrefix -and $job.Contains("JobName startswith `"$jobPrefix`""))
Assert "it matches the job's event literally ($event)" ($event -and $job.Contains("Log has `"$event`"") -and $job.Contains("tostring(m.event) == `"$event`""))
Assert 'it parses from the first brace, so a log prefix does not break the JSON (U201)' ($job -match 'parse_json\(substring\(Log, indexof\(Log, "\{"\)\)\)')
Assert 'parts are counted exactly, after removing repeats, not with the approximate dcount()' (
    $job -match 'summarize at = max\(at\) by JobName, run, part, parts' -and $job -notmatch 'dcount')
Assert 'a run counts only when every part from 1 to parts is present' (
    $job -match 'summarize got = count\(\), parts = max\(parts\), least = min\(parts\), low = min\(part\), high = max\(part\), at = max\(at\) by JobName, run' -and
    $job -match 'where parts > 0 and got == parts and least == parts and low == 1 and high == parts')
Assert 'the newest complete run of each job is used, so two gateways sharing a workspace both count' ($job -match 'summarize arg_max\(at, \*\) by JobName')
Assert 'a repeated part is read once' ($job -match 'summarize arg_max\(TimeGenerated, rows, run_at\) by run, part')
Assert 'rows expand to oid, unit and parent, and the newest run decides an identity two jobs both place' (
    $job -match 'mv-expand row = rows' -and
    $job -match 'project oid = tostring\(row\[0\]\), unit = tostring\(row\[1\]\), parent = tostring\(row\[2\]\), run_at' -and
    $job -match 'summarize arg_max\(run_at, unit, parent\) by oid')

$rest = $cost.Substring($section.Index + $section.Length)
Assert "today's mapping is the job's when a complete run exists, else the published table" (
    $rest -match 'let unit_now = union \(job_membership \| where isnotnull\(job_at\)\), \(membership \| where isnull\(job_at\)\)')
Assert 'membership_date names the source' (
    $job -match 'let job_at = toscalar\(job_runs \| summarize max\(at\)\);' -and
    $job -match 'let membership_source = iff\(isnotnull\(job_at\), strcat\(format_datetime\(job_at, "yyyy-MM-dd HH:mm"\), " UTC sync job"\), membership_date\);' -and
    $rest -match 'membership_date = membership_source')

Assert 'Test-All registers this suite' ($testAll -match "Invoke-Check\s+'[^']+'\s+'Test-ChargebackMembership\.ps1'")

Write-Host ''
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) membership assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) membership assertion(s) passed." -ForegroundColor Green
exit 0
