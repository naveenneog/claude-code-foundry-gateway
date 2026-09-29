param([switch]$NativeChild, [string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$clock = [Diagnostics.Stopwatch]::StartNew()
$script:assertions = 0; $script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''; $script:CapturedResult = $null
    $lines = [Collections.Generic.List[string]]::new()
    try {
        & $Action 6>&1 3>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.InformationRecord]) { $lines.Add([string]$_.MessageData) }
            elseif ($_ -is [Management.Automation.WarningRecord]) { $lines.Add([string]$_) }
            else { $script:CapturedResult = $_; $lines.Add([string]$_) }
        }
    } catch { $script:CapturedError = $_.Exception.Message }
    $script:CapturedOutput = ($lines -join "`n") + "`n" + $CapturedError
}
function Expect-Failure($Name, [scriptblock]$Action, $Pattern) {
    Capture $Action
    Assert $Name ($CapturedError -and $CapturedOutput -match $Pattern) ($CapturedError.Substring(0, [Math]::Min(180, $CapturedError.Length)))
}

if ($NativeChild) {
    . (Join-Path $root 'scripts\ClaudeGraphMembership.ps1')
    . (Join-Path $root 'scripts\ClaudeRunner.ps1')
    Assert 'native fixture owns az' ((Get-Command az -CommandType Application | Select-Object -First 1).Source -eq (Join-Path $env:P84_NATIVE_DIRECTORY 'az.cmd'))
    Expect-Failure 'native Graph CAE remains an error' { Get-GraphToken } 'LocationConditionEvaluationSatisfied'
    Expect-Failure 'native runner nonzero remains an error' { Invoke-RunnerCommand -ResourceGroup rg-p84 -Name runner -Command 'node --version' } 'runner'
    Assert 'native runner failure shows its raw output' ($CapturedOutput -match 'runner-native-output')
    Write-Host "P84_NATIVE assertions=$assertions failed=$failures"
    exit ([int]($failures -gt 0))
}

. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
Reset-ProjectionFixture
. (Join-Path $root 'scripts\ClaudeGraphMembership.ps1')
. (Join-Path $root 'scripts\ClaudeRunner.ps1')
$checksPath = Join-Path $root 'scripts\ClaudeProjectionChecks.ps1'
if (Test-Path $checksPath) { . $checksPath }

function Run-Preflight([string]$Case = 'healthy', [hashtable]$Extra = @{}) {
    Reset-ProjectionFixture $Case
    $params = @{
        ResourceGroup = 'rg-p84'; ApimName = 'apim-p84'; NamePrefix = 'p84fixture'
        Sku = 'BasicV2'; ResolverInboundAccess = 'public'; SubscriptionId = $FixtureSubscription
        StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium'
    }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    Capture { Invoke-ClaudeProjectionPreflight @params }
}
function Guard {
    param([long]$ExpiresAt = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200), [string]$JobId = $FixtureJobId)
    Assert-ClaudeProjectionReconciler -ReconcilerResourceId $JobId -GatewayResourceId $FixtureGatewayId `
        -AccountResourceId $FixtureCosmosId -TenantId $FixtureTenant -ExpiresAt $ExpiresAt
}

Write-Host 'P84 preflight: every check is offline'
Run-Preflight
Assert 'healthy preflight passes' (-not $CapturedError) $CapturedError
Assert 'one table includes evidence, remedy and acting party' (($CapturedOutput -match 'Check\s+Result\s+Evidence\s+Remedy\s+Who') -and ([regex]::Matches($CapturedOutput, 'Check\s+Result\s+Evidence\s+Remedy\s+Who').Count -eq 1))
Assert 'Graph is read twice with one 25-second wait' ($FixtureProbes -eq 2 -and $FixtureWaits.Count -eq 1 -and $FixtureWaits[0] -eq 25)
$calls = $FixtureCalls -join "`n"
Assert 'Graph probes surround the wait' ($calls -match '(?s)HTTP Get https://graph.microsoft.com/v1.0/me.*sleep 25.*HTTP Get https://graph.microsoft.com/v1.0/me')
Assert 'wait carries an estimate' ($CapturedOutput -match '25 s' -and $CapturedOutput -match '30-90 s')
Assert 'capacity is explicitly uncheckable, with regional evidence' ($CapturedOutput -match 'cannot be checked in advance' -and $CapturedOutput -match 'Canada Central' -and $CapturedOutput -match 'Canada East')
Assert 'read-only probes never create or update Azure resources' ($calls -notmatch 'az (deployment .*create|ad app (create|update)|provider register|account set)')
Assert 'RBAC includes group and inherited assignments' ($calls -match 'role assignment list.*--include-groups.*--include-inherited')
Assert 'no Windows query metacharacters' ($calls -notmatch '--query [^\r\n]*[()|&<>^]')
Assert 'exact storage hash is evaluated by local Bicep' ($calls -match 'bicep build-params' -and $calls -match 'storage account check-name.*stres52p2c4jfs43ig')

foreach ($case in @(
    @('signed-out','sign.in|signed in'), @('wrong-subscription','subscription'), @('no-identity','identity'),
    @('wrong-sku','SKU|tier'), @('sp-error','identity|application id'),
    @('cae','LocationConditionEvaluationSatisfied'), @('cae-second','LocationConditionEvaluationSatisfied'),
    @('token-error','Graph'), @('network','network'), @('standard-missing','claude-code-standard'),
    @('premium-missing','claude-code-premium'), @('group-error','lookup'), @('group-duplicate','ambiguous|multiple'),
    @('group-shape','collection|value'), @('policy-false','allowedToCreateApps'), @('policy-error','Policy.Read.All'),
    @('policy-shape','allowedToCreateApps'), @('guest','member user'), @('app-list-error','registration|app'),
    @('contributor-only','Owner|User Access Administrator'), @('role-custom','Owner|User Access Administrator'),
    @('role-conditional','Owner|conditional'), @('role-child','Owner|scope'), @('role-error','role|RBAC'),
    @('cosmos-taken','cosmos-p84fixture'), @('cosmos-error','Cosmos|cosmos'), @('cosmos-shape','Cosmos|cosmos'),
    @('storage-taken','stres52p2c4jfs43ig'), @('storage-error','storage|Storage'), @('storage-shape','storage|Storage'),
    @('site-taken','func-resolver-p84fixture'), @('site-error','Site|site|Function'), @('site-shape','Site|site|Function'),
    @('bicep-evaluation','Bicep|bicep|storage'), @('bicep-shape','storage|Storage')
)) {
    Run-Preflight $case[0]
    Assert "preflight FAIL: $($case[0])" ($CapturedError -and $CapturedOutput -match $case[1])
}
Run-Preflight 'cae-second'
Assert 'CAE has operator, network and admin remedies, not not-found' ($CapturedOutput -match 'VPN' -and $CapturedOutput -match 'IPv6' -and $CapturedOutput -match 'named location' -and $CapturedOutput -match 'temporary exclusion' -and $CapturedOutput -match 'Cloud Shell' -and $CapturedOutput -notmatch 'not found.*empty')
Run-Preflight 'policy-false'
Assert 'admin remedy includes portal registration and exact CLI handoff' ($CapturedOutput -match 'entra.microsoft.com' -and $CapturedOutput -match 'App registrations' -and $CapturedOutput -match 'Expose an API' -and $CapturedOutput -match 'az ad app create' -and $CapturedOutput -match 'az ad app update' -and $CapturedOutput -match '-ResolverAppId')
foreach ($provider in 'Microsoft.App','Microsoft.DocumentDB','Microsoft.Web','Microsoft.ContainerInstance','Microsoft.Network','Microsoft.Storage','Microsoft.OperationalInsights','Microsoft.Insights','Microsoft.Authorization') {
    Run-Preflight "provider:$provider"
    Assert "provider not registered: $provider" ($CapturedError -and $CapturedOutput -match [regex]::Escape($provider))
}
foreach ($tool in 'az','node','npm','tar','bicep') {
    Run-Preflight "tool:$tool"
    Assert "missing local tool: $tool" ($CapturedError -and $CapturedOutput -match [regex]::Escape($tool))
}
foreach ($case in 'existing-app','contributor-uaa','owned-names') {
    Run-Preflight $case
    Assert "idempotent/sufficient preflight: $case" (-not $CapturedError) $CapturedError
}
Run-Preflight 'policy-error' @{ ResolverAppId = '00000000-0000-4000-8000-000000000086' }
Assert 'existing supplied app needs no policy read' (-not $CapturedError -and ($FixtureCalls -join "`n") -notmatch 'authorizationPolicy') $CapturedError
foreach ($case in 'app-error','app-uri') {
    Run-Preflight $case @{ ResolverAppId = '00000000-0000-4000-8000-000000000086' }
    Assert "supplied resolver app FAIL: $case" ($CapturedError -and $CapturedOutput -match 'resolver|Resolver')
}
foreach ($prefix in @('A','a_1','-a','a-','a--b',('a' * 38),'a&echo','a/b')) {
    Run-Preflight 'healthy' @{ NamePrefix = $prefix }
    Assert "unsafe derived prefix: $prefix" ($CapturedError -and $CapturedOutput -match 'NamePrefix|prefix')
}
foreach ($prefix in @('a',('a' * 37),'a-0')) {
    Run-Preflight 'healthy' @{ NamePrefix = $prefix }
    Assert "valid prefix boundary: $($prefix.Length)" (-not $CapturedError) $CapturedError
}
Run-Preflight 'healthy' @{ SubscriptionId = '00000000-0000-4000-8000-000000000099' }
Assert 'explicit target subscription is enforced' ($CapturedError -and $CapturedOutput -match 'subscription')
Run-Preflight 'healthy' @{ ResolverInboundAccess = 'private' }
Assert 'Basic v2 cannot select an unreachable private resolver' ($CapturedError -and $CapturedOutput -match 'BasicV2.*public')
Run-Preflight 'healthy' @{ ResolverAppId = 'not-an-app-id' }
Assert 'invalid app id never reaches CLI' ($CapturedError -and ($FixtureCalls -join "`n") -notmatch 'ad app show.*not-an-app-id')

Write-Host 'P84 Graph failure boundaries'
foreach ($case in '401','403','cae','network','group-error','group-shape','group-duplicate','member-error','member-shape','member-nextlink') {
    Reset-ProjectionFixture $case
    Expect-Failure "Graph $case is not an empty group" { Get-GroupMemberOids -GroupName 'optional' -Token 'offline-token' } 'Graph|group|collection|membership|nextLink|ambiguous'
}
Reset-ProjectionFixture 'group-missing'
Capture { @(Get-GroupMemberOids -GroupName 'optional' -Token 'offline-token').Count }
Assert 'positively absent optional group is empty' (-not $CapturedError -and $CapturedResult -eq 0)
Reset-ProjectionFixture
Capture { @(Get-GroupMemberOids -GroupName "Customer's group & support" -Token 'offline-token').Count }
Assert 'successful membership still returns both identity casts' (-not $CapturedError -and $CapturedResult -eq 2) $CapturedError
Assert 'group display-name quote is escaped in the filter' (($FixtureCalls -join "`n") -match "displayName eq 'Customer''s group & support'")
Assert 'membership lookup never delegates special-character URLs to cmd' (($FixtureCalls -join "`n") -notmatch '^az .*Customer')

Write-Host 'P84 switch evidence'
Reset-ProjectionFixture
Capture { Guard }
Assert 'bound scheduled job with fresh matching success permits switch' (-not $CapturedError -and $CapturedResult.Execution -eq 'recent') $CapturedError
Assert 'switch evidence uses only ARM reads' (($FixtureCalls -join "`n") -notmatch 'HTTP (Post|Put|Patch|Delete)')
Expect-Failure 'missing reconciler refuses with expiry and developer-wide consequence' { Guard -JobId '' } 'at most 2 hours.*\d{4}-\d{2}-\d{2}.*every developer.*503'
foreach ($cron in '* * * * *','*/30 * * * *','5,35 * * * *','59 * * * *') {
    Reset-ProjectionFixture; $FixtureJob.properties.configuration.scheduleTriggerConfig.cronExpression = $cron
    Capture { Guard }
    Assert "supported hourly-or-faster schedule: $cron" (-not $CapturedError) $CapturedError
}
foreach ($cron in '0 */2 * * *','0 * * * 1','0 * 1 * *','0 * * 1 *','60 * * * *','*/0 * * * *','*/60 * * * *','not-cron') {
    Reset-ProjectionFixture; $FixtureJob.properties.configuration.scheduleTriggerConfig.cronExpression = $cron
    Expect-Failure "unsafe/unsupported schedule: $cron" { Guard } 'schedule|cron|hourly'
}
foreach ($entry in @(
    @{ Name='wrong resource type'; Break={ $FixtureJob.type = 'Microsoft.App/containerApps' }; Match='job|resource' },
    @{ Name='foreign resource id'; Break={ $FixtureJob.id = $FixtureJobId.Replace('projection-renewal','other-job') }; Match='id|job' },
    @{ Name='unsuccessful provisioning'; Break={ $FixtureJob.properties.provisioningState = 'Failed' }; Match='provision' },
    @{ Name='manual trigger'; Break={ $FixtureJob.properties.configuration.triggerType = 'Manual' }; Match='Schedule|schedule' },
    @{ Name='absent timeout'; Break={ $FixtureJob.properties.configuration.replicaTimeout = $null }; Match='timeout|Timeout' },
    @{ Name='excessive timeout'; Break={ $FixtureJob.properties.configuration.replicaTimeout = 7200 }; Match='timeout|Timeout|lease' },
    @{ Name='image is only a tag'; Break={ $FixtureJob.properties.template.containers[0].image = 'example.invalid/projection:latest' }; Match='digest|SHA|image' },
    @{ Name='multiple containers'; Break={ $FixtureJob.properties.template.containers += $FixtureJob.properties.template.containers[0] }; Match='container' },
    @{ Name='init container'; Break={ $FixtureJob.properties.template.initContainers = @(@{ name='init' }) }; Match='init' },
    @{ Name='failed execution'; Break={ $FixtureExecution.properties.status = 'Failed' }; Match='succeed|Succeeded|failed' },
    @{ Name='no execution'; Break={ $global:FixtureExecutions = @() }; Match='succeed|Succeeded|execution' },
    @{ Name='old execution start'; Break={ $FixtureExecution.properties.startTime = [DateTimeOffset]::UtcNow.AddSeconds(-7201).ToString('o') }; Match='lease|fresh|execution' },
    @{ Name='future execution'; Break={ $FixtureExecution.properties.endTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o') }; Match='time|future|execution' },
    @{ Name='inverted execution times'; Break={ $FixtureExecution.properties.startTime = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') }; Match='time|execution' },
    @{ Name='bad execution timestamp'; Break={ $FixtureExecution.properties.startTime = 'not-a-time' }; Match='time|execution' },
    @{ Name='foreign execution'; Break={ $FixtureExecution.id = $FixtureJobId.Replace('projection-renewal','other-job') + '/executions/recent' }; Match='execution|job' },
    @{ Name='old image success'; Break={ $FixtureExecution.properties.template.containers[0].image = 'example.invalid/projection@sha256:' + ('b' * 64) }; Match='template|execution' },
    @{ Name='changed command'; Break={ $FixtureExecution.properties.template.containers[0].command = @('echo') }; Match='template|execution' },
    @{ Name='changed arguments'; Break={ $FixtureExecution.properties.template.containers[0].args = @('nothing') }; Match='template|execution' },
    @{ Name='newer failed execution'; Break={
        $failed = $FixtureExecution | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $failed.properties.status = 'Failed'; $failed.properties.startTime = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
        $failed.properties.endTime = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        $global:FixtureExecutions += $failed
    }; Match='failed|failure' }
)) {
    Reset-ProjectionFixture; & $entry.Break
    Expect-Failure "reconciler guard: $($entry.Name)" { Guard } $entry.Match
}
foreach ($field in @('CLAUDE_PROJECTION_CONTRACT','PROJECTION_GATEWAY_RESOURCE_ID','PROJECTION_ACCOUNT_RESOURCE_ID','PROJECTION_TENANT_ID','PROJECTION_DATABASE','PROJECTION_CONTAINER','PROJECTION_MAX_AGE_SECONDS')) {
    Reset-ProjectionFixture
    ($FixtureJob.properties.template.containers[0].env | Where-Object name -eq $field).value = 'wrong'
    ($FixtureExecution.properties.template.containers[0].env | Where-Object name -eq $field).value = 'wrong'
    Expect-Failure "destination/contract binding: $field" { Guard } 'binding|contract|environment'
}
foreach ($case in 'job-error','execution-error','execution-nextlink') {
    Reset-ProjectionFixture $case
    Expect-Failure "unreadable/unsafe ARM evidence: $case" { Guard } 'ARM|execution|nextLink'
}
Reset-ProjectionFixture 'execution-page'
Capture { Guard }
Assert 'execution pagination finds success on the second page' (-not $CapturedError -and ($FixtureCalls -join "`n") -match 'skiptoken=second') $CapturedError
Reset-ProjectionFixture
Expect-Failure 'expired actual snapshot refuses' { Guard -ExpiresAt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1) } 'expir|lease'
Expect-Failure 'almost-expired snapshot has no runway for the next execution' { Guard -ExpiresAt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60) } 'lease|remaining|runway'
Expect-Failure 'job from another subscription refuses' { Guard -JobId $FixtureJobId.Replace($FixtureSubscription,$FixtureTenant) } 'subscription'
Run-Preflight 'healthy' @{ FlipAfterCleanCompare = $true }
Assert 'preflight blocks a requested flip without a reconciler before writes' ($CapturedError -and $CapturedOutput -match 'every developer.*503')

Write-Host 'P84 honest runner and app-registration failures'
Reset-ProjectionFixture
Capture { ConvertFrom-ClaudeRunnerResult -RawOutput "noise`n{`"ok`":true,`"compared`":5}`n" -Step 'compare' }
Assert 'valid runner summary tolerates preceding log lines and a final newline' (-not $CapturedError -and $CapturedResult.compared -eq 5) $CapturedError
foreach ($step in 'apply','compare') {
    foreach ($last in 'command crashed', '{"ok":false,"differences":2}', '{"ok":"false"}', '{}', '') {
        $raw = ((1..50 | ForEach-Object { "raw-line-$_" }) -join "`n") + "`n$last"
        Capture { ConvertFrom-ClaudeRunnerResult -RawOutput $raw -Step $step }
        Assert "$step rejects malformed/unsuccessful summary [$last]" ([bool]$CapturedError)
        Assert "$step prints only the final 40 raw lines [$last]" ($CapturedOutput -match 'raw-line-50' -and $CapturedOutput -notmatch 'raw-line-1\r?\n' -and ([regex]::Matches($CapturedOutput, '(?m)^raw-line-\d+').Count -le 40))
    }
}
foreach ($case in 'app-create-denied','app-create-empty') {
    Reset-ProjectionFixture $case
    Capture { New-ClaudeProjectionResolverApp -NamePrefix p84fixture }
    Assert "app registration failure is honest: $case" ($CapturedError -and $CapturedOutput -match 'app|registration' -and $CapturedOutput -notmatch 'when running with -WhatIf')
    Assert "app update never sees an empty id: $case" (($FixtureCalls -join "`n") -notmatch 'ad app update')
}
Reset-ProjectionFixture
Capture { New-ClaudeProjectionResolverApp -NamePrefix p84fixture }
Assert 'successful app creation updates a nonempty id with its exact URI' (-not $CapturedError -and ($FixtureCalls -join "`n") -match "ad app update.*--id $FixtureApp.*--identifier-uris api://$FixtureApp") $CapturedError

Write-Host 'P84 entry-point wiring'
$deploy = Get-Content (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -Raw
$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
$sync = Get-Content (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Raw
$flow = Get-Content (Join-Path $root 'scripts\flow\Entitlement.ps1') -Raw
$register = Get-Content (Join-Path $root 'tests\Test-All.ps1') -Raw
Assert 'offline check is registered' ($register -match "'Test-ProjectionPreflight.ps1'")
Assert 'deployer checks before its first Azure write' ($deploy -match '(?s)Invoke-ClaudeProjectionPreflight.*if \(\$PreflightOnly\).*New-ClaudeProjectionResolverApp')
Assert 'deployer rechecks the actual snapshot immediately before named-value writes' ($deploy -match '(?s)Assert-ClaudeProjectionReconciler[^\r\n]*[\s\S]*?-ExpiresAt \$snapshotExpiry[\s\S]*?Set-ApimNamedValue' -and $deploy -match 'snapshotExpiry.*expiresAt')
Assert 'both runner steps use the checked result parser' ([regex]::Matches($deploy, 'ConvertFrom-ClaudeRunnerResult').Count -eq 2)
Assert 'projection sync rejects PS 5.1 explicitly' ($sync -match 'Assert-ClaudeProjectionPowerShell|PSVersion.*-lt 7' -and $sync -match 'pwsh|ClaudeProjectionChecks')
Assert 'installer forwards the typed reconciler id and resolver app id' ($installer -match 'ProjectionReconcilerResourceId' -and $installer -match "'-ReconcilerResourceId'" -and $installer -match 'ProjectionResolverAppId' -and $installer -match "'-ResolverAppId'")
Assert 'installer refuses a flip without evidence before foundation writes' ($installer -match '(?s)FlipProjectionAfterCleanCompare.*Assert-ClaudeProjectionReconciler.*az group create')
Assert 'flow records and forwards reconciler evidence' ($flow -match 'reconcilerResourceId' -and $flow -match '-ReconcilerResourceId' -and $flow -match 'verified reconciler')
Assert 'AUM selected group lookup reuses positive Graph collection semantics' ((Get-Content (Join-Path $root 'scripts\Sync-AumMembership.ps1') -Raw) -match 'Get-ClaudeGraphGroup')
Assert 'projection sync uses the checked Graph token helper' ($sync -match '\$graphToken = Get-GraphToken')
Assert 'per-run deploy files are not keyed by PID alone' ($deploy -notmatch '\$NamePrefix-\$PID' -and $deploy -match 'NewGuid')

Reset-ProjectionFixture
Capture { & (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -PreflightOnly }
Assert 'real PreflightOnly invocation returns after checks with no writes' (-not $CapturedError -and ($FixtureCalls -join "`n") -notmatch 'az (deployment|ad app create|ad app update)') $CapturedError
Reset-ProjectionFixture 'signed-out'
Capture { & (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture }
Assert 'real normal invocation fails preflight before every Azure write' ($CapturedError -and $CapturedOutput -match 'preflight' -and ($FixtureCalls -join "`n") -notmatch 'az (deployment|ad app create|ad app update)')

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p84-native-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:PATH; $savedConfig = $env:AZURE_CONFIG_DIR; $savedNative = $env:P84_NATIVE_DIRECTORY
try {
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $cmd = "@echo off`r`nif `"%1`"==`"container`" (echo runner-native-output & exit /b 9)`r`n1>&2 echo ERROR: $FixtureCae`r`nexit /b 9`r`n"
    [IO.File]::WriteAllText((Join-Path $scratch 'az.cmd'), $cmd, [Text.Encoding]::ASCII)
    $env:PATH = $scratch + ';' + $savedPath; $env:AZURE_CONFIG_DIR = Join-Path $scratch 'azure'; $env:P84_NATIVE_DIRECTORY = $scratch
    $shells = @((Microsoft.PowerShell.Core\Get-Command pwsh).Source, (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    foreach ($shell in $shells) {
        $log = Join-Path $scratch ([IO.Path]::GetFileName($shell) + '.log')
        & $shell -NoProfile -NonInteractive -File $PSCommandPath -NativeChild -RepositoryRoot $root *> $log
        $exitCode = $LASTEXITCODE; $text = Get-Content $log -Raw
        Assert "native stderr boundaries: $([IO.Path]::GetFileName($shell))" ($exitCode -eq 0 -and $text -match 'P84_NATIVE assertions=4 failed=0') (($text -split "`n" | Where-Object { $_ -match '\[FAIL\]' }) -join '; ')
        $hostLog = Join-Path $scratch ([IO.Path]::GetFileName($shell) + '-version.log')
        if ($shell -like '*\powershell.exe') {
            & $shell -NoProfile -NonInteractive -File (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -PreflightOnly *> $hostLog
            $versionExit = $LASTEXITCODE; $versionText = Get-Content $hostLog -Raw
            Assert 'deployment on 5.1 fails with run in pwsh before Azure' ($versionExit -ne 0 -and $versionText -match 'run in pwsh' -and $versionText -notmatch 'LocationConditionEvaluationSatisfied')
            & $shell -NoProfile -NonInteractive -File (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') -Account cosmos-p84fixture -ExportPath (Join-Path $scratch 'snapshot.json') *> $hostLog
            $versionExit = $LASTEXITCODE; $versionText = Get-Content $hostLog -Raw
            Assert 'projection sync on 5.1 fails with run in pwsh before Azure' ($versionExit -ne 0 -and $versionText -match 'run in pwsh' -and $versionText -notmatch 'LocationConditionEvaluationSatisfied')
        }
    }
} finally {
    $env:PATH = $savedPath; $env:AZURE_CONFIG_DIR = $savedConfig; $env:P84_NATIVE_DIRECTORY = $savedNative
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Write-Host ("P84 assertions={0} failed={1} seconds={2:N2}" -f $assertions, $failures, $clock.Elapsed.TotalSeconds)
exit ([int]($failures -gt 0))
