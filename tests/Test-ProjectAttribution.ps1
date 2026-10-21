# P119: a client-declared project identifier reaches the chargeback report (ADR-0065).
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
Write-Host 'P119 project identifier' -ForegroundColor Cyan

$policy = [IO.File]::ReadAllText((Join-Path $root 'infra\policy.xml'))
$ledger = [IO.File]::ReadAllText((Join-Path $root 'analytics\chargeback-ledger.kql'))
$cost = [IO.File]::ReadAllText((Join-Path $root 'analytics\chargeback-cost.kql'))
$workbook = [IO.File]::ReadAllText((Join-Path $root 'infra\workbook-chargeback.json'))
$testAll = [IO.File]::ReadAllText((Join-Path $root 'tests\Test-All.ps1'))

# Behavior: compile the policy's own expression with a header dictionary standing in for context.
$expression = [regex]::Match($policy, '<set-variable name="projectId" value="@\{(?<code>.*?)\}" />',
    [Text.RegularExpressions.RegexOptions]::Singleline)
Assert 'the policy derives projectId in one extractable expression' $expression.Success
if ($expression.Success) {
    $code = [Net.WebUtility]::HtmlDecode($expression.Groups['code'].Value).
        Replace('context.Request.Headers.GetValueOrDefault("x-claude-project", "")', 'header')
    Add-Type -TypeDefinition @"
using System;
public static class P119ProjectContract {
    public static string Project(string header) {
$code
    }
}
"@ -ErrorAction Stop
    $cases = [ordered]@{
        'PRJ-1042' = 'prj-1042'; '  alpha.web_2  ' = 'alpha.web_2'; '' = 'unspecified'; '   ' = 'unspecified'
        'has space' = 'invalid'; '-leading' = 'invalid'; ('a' * 65) = 'invalid'; 'x,y' = 'invalid'; 'é' = 'invalid'
    }
    $wrong = @(foreach ($k in $cases.Keys) { $got = [P119ProjectContract]::Project($k); if ($got -cne $cases[$k]) { "'$k' -> '$got' (want '$($cases[$k])')" } })
    Assert 'a valid header is lower-cased; missing reads unspecified; malformed reads invalid' (-not $wrong.Count) ($wrong -join '; ')
    Assert 'the 64-character maximum is accepted' ([P119ProjectContract]::Project('a' * 64) -eq ('a' * 64))
}

$inbound = $policy.Substring(0, [Math]::Max(0, $policy.IndexOf('<backend>')))
Assert 'the header is removed before the request reaches Foundry' ($inbound -match '<set-header name="x-claude-project" exists-action="delete" />')
$trace = [regex]::Match($policy, '<trace source="claude-chargeback".*?</trace>', [Text.RegularExpressions.RegexOptions]::Singleline)
Assert 'the chargeback trace carries ProjectId' ($trace.Success -and $trace.Value -match '<metadata name="ProjectId" value="@\(\(string\)context.Variables\["projectId"\]\)" />')
$outbound = $policy.Substring([Math]::Max(0, $policy.IndexOf('<outbound>')))
Assert 'the response tells the client which project was recorded' ($outbound -match '<set-header name="x-claude-project" exists-action="override">\s*<value>@\(\(string\)context.Variables\["projectId"\]\)</value>')

Assert 'ClaudeChargeback reads ProjectId and exposes project_id' (
    $ledger -match 'project_id = tostring\(Properties\.ProjectId\)' -and
    $ledger -match 'project_id = take_any\(project_id\)' -and
    $ledger -match 'project_id = coalesce\(project_id, "unspecified"\)')
Assert 'ClaudeCost groups metered spend by project and labels cache rows without inventing a split' (
    $cost -match 'by day = startofday\(timestamp\), user_id, actor, business_unit_at_time = business_unit, project_id,' -and
    $cost -match 'project_id = "cache \(no project\)"' -and
    $cost -match '\| project day, actor, user_id, business_unit, business_unit_parent, business_unit_at_time,\s*project_id,')

$wb = $workbook | ConvertFrom-Json
$queries = @($wb.items | ForEach-Object { if ($_.content.query) { [string]$_.content.query } })
$params = @($wb.items | Where-Object { $_.type -eq 9 } | ForEach-Object { $_.content.parameters } | ForEach-Object { $_.name })
Assert 'the workbook offers a Project filter' ($params -contains 'Project')
Assert 'the workbook has a spend table grouped by business unit and project' (
    @($queries | Where-Object { $_ -match "by \['Business unit'\] = business_unit, Project = project_id" }).Count -eq 1)
$unitFiltered = @($queries | Where-Object { $_ -match "'\{BusinessUnit\}' == 'All' or business_unit == '\{BusinessUnit\}'" })
$unfiltered = @($unitFiltered | Where-Object { $_ -notmatch "'\{Project\}' == 'All' or project_id == '\{Project\}'" })
Assert 'every table that honours the business-unit filter also honours the Project filter' (
    $unitFiltered.Count -ge 7 -and -not $unfiltered.Count) "$($unitFiltered.Count) unit-filtered, $($unfiltered.Count) without Project"

Assert 'Test-All registers this suite' ($testAll -match "Invoke-Check\s+'[^']+'\s+'Test-ProjectAttribution\.ps1'")

Write-Host ''
if ($script:fail) { Write-Host "$($script:fail) of $($script:count) project assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:count) project assertion(s) passed." -ForegroundColor Green
exit 0
