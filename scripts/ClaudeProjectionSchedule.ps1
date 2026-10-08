# The projection sync job's schedule (ADR-0058). Each interval maps to one cron expression, which Container Apps
# evaluates in UTC (U166), to the range the no-success alert reads (2 x interval + 15 minutes) and to the runs in a
# 730-hour month, the Azure convention for an average month (scripts/AzureRetailPrice.ps1). The shortest interval
# is 30 minutes.

function Get-ClaudeProjectionSyncIntervalTable {
    [ordered]@{
        '30m' = @{ Cron = '*/30 * * * *'; Minutes = 30 }
        '1h'  = @{ Cron = '0 * * * *'; Minutes = 60 }
        '2h'  = @{ Cron = '0 */2 * * *'; Minutes = 120 }
        '3h'  = @{ Cron = '0 */3 * * *'; Minutes = 180 }
        '4h'  = @{ Cron = '0 */4 * * *'; Minutes = 240 }
        '6h'  = @{ Cron = '0 */6 * * *'; Minutes = 360 }
        '8h'  = @{ Cron = '0 */8 * * *'; Minutes = 480 }
        '12h' = @{ Cron = '0 */12 * * *'; Minutes = 720 }
    }
}

function Get-ClaudeProjectionSyncIntervals {
    @((Get-ClaudeProjectionSyncIntervalTable).Keys) + 'manual'
}

function Get-ClaudeProjectionSyncDefaultInterval { '2h' }

function ConvertTo-ClaudeProjectionSyncSchedule {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Interval)
    $key = $Interval.ToLowerInvariant()
    if ($key -ceq 'manual') {
        return [pscustomobject]@{ Interval = 'manual'; Cron = ''; Minutes = 0; NoSuccessMinutes = 0; RunsPerMonth = 0 }
    }
    $table = Get-ClaudeProjectionSyncIntervalTable
    if (-not $table.Contains($key)) {
        throw ("Sync interval '{0}' is not one of: {1}. The shortest interval is 30 minutes." -f $Interval, ((Get-ClaudeProjectionSyncIntervals) -join ', '))
    }
    $minutes = [int]$table[$key].Minutes
    [pscustomobject]@{
        Interval         = $key
        Cron             = $table[$key].Cron
        Minutes          = $minutes
        NoSuccessMinutes = 2 * $minutes + 15
        RunsPerMonth     = [int][math]::Round(730 * 60 / $minutes, [MidpointRounding]::AwayFromZero)
    }
}

# How an interval reads in output: every 30 minutes, every hour, every N hours, or only when started.
function Format-ClaudeProjectionSyncInterval {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Interval)
    $schedule = ConvertTo-ClaudeProjectionSyncSchedule -Interval $Interval
    switch ($schedule.Minutes) {
        0 { 'only when started' }
        30 { 'every 30 minutes' }
        60 { 'every hour' }
        default { 'every {0} hours' -f ($schedule.Minutes / 60) }
    }
}

# The interval a deployed job runs at, from its cron expression: manual when it has none, and nothing when the
# expression is not one of the intervals above.
function ConvertFrom-ClaudeProjectionSyncCron {
    param([AllowEmptyString()][string]$Cron)
    if ([string]::IsNullOrWhiteSpace($Cron)) { return 'manual' }
    $table = Get-ClaudeProjectionSyncIntervalTable
    foreach ($key in $table.Keys) {
        if ($table[$key].Cron -ceq $Cron.Trim()) { return $key }
    }
    return $null
}
