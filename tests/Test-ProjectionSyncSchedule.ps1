# P104: each sync job interval maps to one cron expression, one no-success range and one run count (ADR-0058).
$ErrorActionPreference = 'Stop'
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label $Detail" -ForegroundColor Red; $script:fail++ }
}
function Get-Refusal([scriptblock]$Action) {
    try { & $Action | Out-Null; return '' } catch { return $_.Exception.Message }
}

$module = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\ClaudeProjectionSchedule.ps1'
Assert 'the interval module exists' (Test-Path -LiteralPath $module) $module
if (Test-Path -LiteralPath $module) { . $module }
$loaded = [bool](Get-Command ConvertTo-ClaudeProjectionSyncSchedule -ErrorAction SilentlyContinue)
Assert 'it defines ConvertTo-ClaudeProjectionSyncSchedule' $loaded

# Interval, cron (UTC), no-success minutes (2 x interval + 15), runs in a 730-hour month (midpoint away from zero).
$expected = @(
    , @('30m', '*/30 * * * *', 30, 75, 1460)
    , @('1h', '0 * * * *', 60, 135, 730)
    , @('2h', '0 */2 * * *', 120, 255, 365)
    , @('3h', '0 */3 * * *', 180, 375, 243)
    , @('4h', '0 */4 * * *', 240, 495, 183)
    , @('6h', '0 */6 * * *', 360, 735, 122)
    , @('8h', '0 */8 * * *', 480, 975, 91)
    , @('12h', '0 */12 * * *', 720, 1455, 61)
)
Assert 'the expected table has eight rows of five values' ($expected.Count -eq 8 -and @($expected | Where-Object { $_.Count -ne 5 }).Count -eq 0)
if ($loaded) {
    foreach ($row in $expected) {
        $s = ConvertTo-ClaudeProjectionSyncSchedule -Interval $row[0]
        Assert "$($row[0]) runs as '$($row[1])'" ($s.Interval -ceq $row[0] -and $s.Cron -ceq $row[1]) "got '$($s.Interval)' '$($s.Cron)'"
        Assert "$($row[0]) is $($row[2]) minutes and its no-success range is $($row[3]) minutes" ($s.Minutes -eq $row[2] -and $s.NoSuccessMinutes -eq $row[3]) "got $($s.Minutes) / $($s.NoSuccessMinutes)"
        Assert "$($row[0]) runs $($row[4]) times in a 730-hour month" ($s.RunsPerMonth -eq $row[4]) "got $($s.RunsPerMonth)"
        Assert "$($row[0]) reads back from its cron expression" ((ConvertFrom-ClaudeProjectionSyncCron -Cron $row[1]) -ceq $row[0])
    }
    $manual = ConvertTo-ClaudeProjectionSyncSchedule -Interval 'manual'
    Assert 'manual has no cron expression, no no-success range and no scheduled runs' (
        $manual.Interval -ceq 'manual' -and $manual.Cron -ceq '' -and $manual.Minutes -eq 0 -and $manual.NoSuccessMinutes -eq 0 -and $manual.RunsPerMonth -eq 0)
    Assert 'an empty cron expression reads back as manual' ((ConvertFrom-ClaudeProjectionSyncCron -Cron '') -ceq 'manual')
    Assert 'a cron expression outside the list reads back as nothing' ($null -eq (ConvertFrom-ClaudeProjectionSyncCron -Cron '*/15 * * * *'))
    Assert 'an upper-case interval is accepted and written in lower case' ((ConvertTo-ClaudeProjectionSyncSchedule -Interval '2H').Interval -ceq '2h')
    Assert 'the default interval is 2h' ((Get-ClaudeProjectionSyncDefaultInterval) -ceq '2h')
    Assert 'the accepted values are the eight intervals and manual, in order' (
        ((Get-ClaudeProjectionSyncIntervals) -join ',') -ceq '30m,1h,2h,3h,4h,6h,8h,12h,manual')

    foreach ($bad in @('15m', '0m', '24h', '2 h', 'abc', '', ' 2h', '2h;', '90m')) {
        $message = Get-Refusal { ConvertTo-ClaudeProjectionSyncSchedule -Interval $bad }
        Assert "'$bad' is refused with the accepted values" (
            $message -match [regex]::Escape("'$bad'") -and $message -match '30m, 1h, 2h, 3h, 4h, 6h, 8h, 12h, manual' -and $message -match '30 minutes') $message
    }

    # The words an operator reads in the deploy output, the installer review and the schedule script.
    $hasWords = [bool](Get-Command Format-ClaudeProjectionSyncInterval -ErrorAction SilentlyContinue)
    Assert 'it defines Format-ClaudeProjectionSyncInterval' $hasWords
    if ($hasWords) {
        $wordCases = @(
            @{ Interval = '30m'; Words = 'every 30 minutes' }, @{ Interval = '1h'; Words = 'every hour' }, @{ Interval = '2h'; Words = 'every 2 hours' }
            @{ Interval = '3h'; Words = 'every 3 hours' }, @{ Interval = '4h'; Words = 'every 4 hours' }, @{ Interval = '6h'; Words = 'every 6 hours' }
            @{ Interval = '8h'; Words = 'every 8 hours' }, @{ Interval = '12h'; Words = 'every 12 hours' }, @{ Interval = 'manual'; Words = 'only when started' }
            @{ Interval = '2H'; Words = 'every 2 hours' }
        )
        Assert 'the word cases are ten interval and wording pairs' ($wordCases.Count -eq 10 -and @($wordCases | Where-Object { $_ -isnot [hashtable] }).Count -eq 0)
        foreach ($case in $wordCases) {
            $words = Format-ClaudeProjectionSyncInterval -Interval $case.Interval
            Assert "$($case.Interval) reads '$($case.Words)'" ($words -ceq $case.Words) "got '$words'"
        }
        $message = Get-Refusal { Format-ClaudeProjectionSyncInterval -Interval '15m' }
        Assert 'an interval that is not listed has no words' ($message -match "'15m'" -and $message -match '30 minutes') $message
    }
}

if ($fail) { Write-Host "$fail sync schedule assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Sync schedule intervals map to one cron, range and run count.' -ForegroundColor Green
