param([string[]]$Probe, [string]$ReceiptPath, [switch]$SelfTest, [switch]$ValidateAnchors)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$clock = [Diagnostics.Stopwatch]::StartNew()

function Test-MutationCaught($Result, [int]$Baseline) {
    return ($Result.SyntaxValid -and $Result.ExitCode -ne 0 -and
        $Result.Assertions -eq $Baseline -and $Result.Failed -gt 0)
}
$checks = @(
    @{ SyntaxValid=$true; ExitCode=1; Assertions=10; Failed=1; Expected=$true }
    @{ SyntaxValid=$false; ExitCode=1; Assertions=10; Failed=1; Expected=$false }
    @{ SyntaxValid=$true; ExitCode=1; Assertions=9; Failed=1; Expected=$false }
    @{ SyntaxValid=$true; ExitCode=1; Assertions=10; Failed=0; Expected=$false }
    @{ SyntaxValid=$true; ExitCode=0; Assertions=10; Failed=1; Expected=$false }
)
foreach ($check in $checks) {
    if ((Test-MutationCaught $check 10) -ne $check.Expected) { throw 'The mutation detector self-check failed.' }
}
Write-Host 'Mutation detector: 5/5 checks passed (syntax, count, assertion and exit status).'
if ($SelfTest) { exit 0 }

$cases = [Collections.Generic.List[object]]::new()
function Add-Guard($Name, $File, $Marker) { $cases.Add(@{ Name=$Name; File=$File; Marker=$Marker; Kind='guard' }) }
function Add-Text($Name, $File, $From, $To) { $cases.Add(@{ Name=$Name; File=$File; From=$From; To=$To; Kind='text' }) }
$checksFile = 'scripts\ClaudeProjectionChecks.ps1'
$graphFile = 'scripts\ClaudeGraphMembership.ps1'
$runnerFile = 'scripts\ClaudeRunner.ps1'
$deployFile = 'scripts\Deploy-ClaudeProjection.ps1'

foreach ($guard in @(
    @('PowerShell version','Projection deployment and sync require'),
    @('prefix naming intersection','NamePrefix is invalid'),
    @('safe target names','Resource group or gateway name is unsafe'),
    @('typed subscription and app ids','SubscriptionId and ResolverAppId must be GUIDs'),
    @('Azure sign-in state','Azure CLI is not signed in'),
    @('explicit subscription','selected subscription does not match'),
    @('gateway read dependency','gateway subscription is unverified'),
    @('gateway resource identity','returned gateway subscription/resource id'),
    @('gateway tenant and identity','Gateway managed identity or tenant'),
    @('gateway SKU','Requested SKU'),
    @('Basic v2 resolver reachability','BasicV2 requires'),
    @('gateway app id','Gateway managed identity application id could not be read'),
    @('resource group identity','Resource group id does not match'),
    @('Graph probe identity','Graph did not return the signed-in user id'),
    @('group token dependency','Graph token could not be acquired; group lookup'),
    @('required tier group','Required tier group'),
    @('supplied resolver app identity','supplied resolver app could not be verified'),
    @('unique resolver registration','Resolver registration display name is ambiguous'),
    @('resolver identifier URI','resolver app must have identifier URI'),
    @('member-user creation permission','App creation permission is unproven: a member user'),
    @('explicit app creation policy','allowedToCreateApps is not explicitly true'),
    @('provider read dependency','Provider reads require the verified subscription'),
    @('registered providers','Unregistered or unreadable provider(s)'),
    @('role read dependency','Role evidence requires verified user and resource group ids'),
    @('required resource-group roles','Owner, or Contributor plus User Access Administrator, was not proven'),
    @('name read dependency','Name availability requires the verified resource group'),
    @('Bicep storage name shape','Bicep returned no valid derived storage account name'),
    @('Cosmos global name','Cosmos name cosmos-'),
    @('storage global name','Storage name'),
    @('Functions global name','Function site'),
    @('preflight FAIL stops writes','Projection preflight failed'),
    @('app creation id before update','Resolver app creation returned no valid application id'),
    @('actual snapshot expiry','actual snapshot has no valid expiry'),
    @('reconciler required','ReconcilerResourceId is required'),
    @('reconciler resource-id shape','must identify a Microsoft.App/jobs ARM resource'),
    @('reconciler subscription binding','must share the verified subscription'),
    @('ARM job identity','ARM returned a different job resource id/type'),
    @('job provisioned','Reconciler provisioning has not succeeded'),
    @('job scheduled','Reconciler trigger must be Schedule'),
    @('hourly cron','Reconciler cron must be'),
    @('replica timeout','Reconciler replica timeout must be'),
    @('lease runway','insufficient remaining runway'),
    @('one reconciler container','exactly one container'),
    @('no init containers','does not permit init containers'),
    @('pinned image digest','image requires a SHA-256 digest'),
    @('literal unique environment','must contain unique literal non-secret values'),
    @('destination environment binding','does not match the projection contract'),
    @('safe complete execution pagination','ARM execution nextLink is foreign, repeated'),
    @('execution collection shape','ARM returned an invalid execution collection'),
    @('execution belongs to job','ARM returned an invalid execution name'),
    @('execution start time','Execution start time is malformed'),
    @('execution end time','Execution end time is malformed'),
    @('latest execution succeeded','No latest succeeded execution'),
    @('success inside lease','Succeeded execution is outside'),
    @('success matches current template','Succeeded execution used a different')
)) { Add-Guard $guard[0] $checksFile $guard[1] }
foreach ($guard in @(
    @('nonempty Graph token','No Microsoft Graph access token was returned'),
    @('Graph URL boundary','Graph nextLink is outside'),
    @('nonempty group name','Graph group name is required'),
    @('positive group collection','lookup returned an invalid collection'),
    @('unambiguous group','is ambiguous: multiple groups'),
    @('group has id','has no id'),
    @('membership repeated page','Graph membership nextLink repeated'),
    @('membership collection','returned an invalid collection.'),
    @('membership has id','contains an identity without an id')
)) { Add-Guard $guard[0] $graphFile $guard[1] }
Add-Guard 'runner exit code' $runnerFile 'runner transport failed'
Add-Guard 'runner boolean ok' $runnerFile 'runner summary must contain boolean ok:true'
Add-Guard 'projection sync host' 'scripts\Sync-ClaudeProjection.ps1' 'Projection sync requires PowerShell 7'
Add-Guard 'Cosmos runner role write failure' $deployFile 'Runner Cosmos role assignment failed'
Add-Guard 'flow clean comparison' 'scripts\flow\Entitlement.ps1' 'clean projection comparison is required'

foreach ($provider in 'Microsoft.App','Microsoft.DocumentDB','Microsoft.Web','Microsoft.ContainerInstance','Microsoft.Network','Microsoft.Storage','Microsoft.OperationalInsights','Microsoft.Insights') {
    Add-Text "provider $provider" $checksFile "'$provider'," ''
}
Add-Text 'provider Microsoft.Authorization' $checksFile ",'Microsoft.Authorization'" ''
foreach ($tool in 'az','node','npm') { Add-Text "local tool $tool" $checksFile "'$tool'," '' }
Add-Text 'local tool tar' $checksFile ",'tar'" ''
Add-Text 'two Graph probes' $checksFile 'foreach ($probe in 1..2)' 'foreach ($probe in 1..1)'
Add-Text 'Graph stability delay' $checksFile 'Start-Sleep -Seconds 25' 'Write-Verbose ''no wait'''
Add-Text 'capacity limitation is honest' $checksFile 'Capacity cannot be checked in advance.' 'Capacity is guaranteed.'
Add-Text 'operator wait estimate' $checksFile '30-90 s' 'some time'
Add-Text 'acting party column' $checksFile "Label='Who'" "Label='Hidden'"
Add-Text 'CAE VPN remedy' $graphFile 'fully on or off the VPN' 'unchanged'
Add-Text 'CAE IPv6 remedy' $graphFile 'IPv6/IPv4 egress' 'network egress'
Add-Text 'CAE Cloud Shell caveat' $graphFile 'Azure Cloud Shell' 'another terminal'
Add-Text 'admin portal remedy' $checksFile 'Expose an API' 'Overview'
Add-Text 'Graph error cannot become absence' $graphFile 'throw "Graph read failed: $($_.Exception.Message) $(Get-ClaudeGraphFailureRemedy $_.Exception.Message)"' 'return [pscustomobject]@{ value=@() }'
Add-Text 'positive absent optional group' $graphFile 'if ($groups.Count -eq 0) { return $null }' 'if ($false) { return $null }'
Add-Text 'bounded raw output' $runnerFile 'Select-Object -Last 40' 'Select-Object -Last 41'
Add-Text 'raw output is visible' $runnerFile 'Write-Host $_' 'Write-Verbose $_'
Add-Text 'app failure is not WhatIf' $checksFile 'Resolver app creation failed:' 'ResolverAppId is required when running with -WhatIf:'
Add-Text 'PreflightOnly does not deploy' $deployFile 'if ($PreflightOnly) { return }' 'if ($false) { return }'
Add-Text 'sync uses checked Graph token' 'scripts\Sync-ClaudeProjection.ps1' '$graphToken = Get-GraphToken' '$graphToken = ''unchecked'''
Add-Text 'installer checks evidence' 'Install-ClaudeGateway.ps1' 'if ($FlipProjectionAfterCleanCompare) {
    . (Join-Path $root ''scripts\ClaudeProjectionChecks.ps1'')' 'if ($false) {
    . (Join-Path $root ''scripts\ClaudeProjectionChecks.ps1'')'
Add-Text 'installer forwards reconciler id' 'Install-ClaudeGateway.ps1' "'-ReconcilerResourceId'" "'-WrongReconcilerId'"
Add-Text 'flow forwards reconciler id' 'scripts\flow\Entitlement.ps1' '-ReconcilerResourceId $Plan.Data.ReconcilerResourceId' '-WrongReconcilerId $Plan.Data.ReconcilerResourceId'
Add-Text 'flow requires evidence before backup' 'scripts\flow\Entitlement.ps1' "if (`$Plan.Data.Desired -eq 'projection' -and -not `$Plan.Data.ReconcilerResourceId)" 'if ($false)'
Add-Text 'verified subscription on every switch write' $deployFile '-SubscriptionId $preflight.SubscriptionId' ''
Add-Text 'actual snapshot expiry is passed' $deployFile '-ExpiresAt $snapshotExpiry' '-ExpiresAt 0'
Add-Text 'Entra drift refuses comparison' $deployFile '-ExportGatewayPath $gateway -FailOnDrift' '-ExportGatewayPath $gateway'
Add-Text 'canonical storage hash input' $checksFile '$context.ResourceGroupId = [string]$rg.id' '$context.ResourceGroupId = "/subscriptions/$($context.SubscriptionId)/resourceGroups/$ResourceGroup"'
Add-Text 'current execution wins over old success' $checksFile 'Sort-Object Start -Descending' 'Sort-Object Start'
Add-Text 'Linux environment names are case sensitive' $checksFile '[StringComparer]::Ordinal)' '[StringComparer]::OrdinalIgnoreCase)'
Add-Text 'ARM id casing is not a new destination' $checksFile '[StringComparison]::OrdinalIgnoreCase' '[StringComparison]::Ordinal'
Add-Text 'installer resolves the gateway target' 'Install-ClaudeGateway.ps1' '$apimName = if ($ExistingApim) { $ExistingApim } else { "apim-$NamePrefix" }' ''
$cases.Add(@{ Name='late switch guard'; File=$deployFile; Kind='command'; Command='Assert-ClaudeProjectionReconciler' })

function Get-MutatedSource($Case, [string]$Text) {
    if ($Case.Kind -eq 'text') {
        if (-not $Text.Contains($Case.From)) { throw "Mutation anchor missing: $($Case.Name)" }
        return $Text.Replace($Case.From, $Case.To)
    }
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Baseline mutation source has invalid syntax.' }
    if ($Case.Kind -eq 'command') {
        $nodes = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Case.Command }, $true))
        if ($nodes.Count -ne 1) { throw "Expected one command anchor: $($Case.Name)" }
        $extent = $nodes[0].Extent
        return $Text.Substring(0,$extent.StartOffset) + '$null' + $Text.Substring($extent.EndOffset)
    }
    $nodes = @($ast.FindAll({
        param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and
        @($n.Clauses[0].Item2.Statements | Where-Object {
            $_ -is [Management.Automation.Language.ThrowStatementAst] -and $_.Extent.Text.Contains($Case.Marker)
        }).Count -eq 1
    }, $true))
    if ($nodes.Count -ne 1) { throw "Expected one guard anchor ($($nodes.Count) found): $($Case.Name)" }
    $extent = $nodes[0].Clauses[0].Item1.Extent
    return $Text.Substring(0,$extent.StartOffset) + '$false' + $Text.Substring($extent.EndOffset)
}

if ($ValidateAnchors) {
    foreach ($case in $cases) {
        $text = Get-Content -LiteralPath (Join-Path $root $case.File) -Raw
        $mutant = Get-MutatedSource $case $text
        $tokens=$null; $errors=$null
        $null = [Management.Automation.Language.Parser]::ParseInput($mutant,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw "Mutation syntax is invalid: $($case.Name)" }
    }
    Write-Host "Mutation anchors and syntax: $($cases.Count)/$($cases.Count) valid."
    exit 0
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('p84-mutations-' + [guid]::NewGuid().ToString('N'))
$results = [Collections.Generic.List[object]]::new()
function Run-Suite([string]$Log) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & pwsh -NoProfile -File (Join-Path $sandbox 'tests\Test-ProjectionPreflight.ps1') *> $Log
    $code=$LASTEXITCODE; $text=Get-Content -LiteralPath $Log -Raw
    $summary=[regex]::Match($text,'P84 assertions=(\d+) failed=(\d+) seconds=')
    @{
        ExitCode=$code; Assertions=$(if($summary.Success){[int]$summary.Groups[1].Value}else{0})
        Failed=$(if($summary.Success){[int]$summary.Groups[2].Value}else{0})
        Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,2); SyntaxValid=$true
        FailureLines=@($text -split '\r?\n' | Where-Object { $_ -match '\[FAIL\]' } | Select-Object -First 4)
    }
}
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'tests') -Force
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $sandbox -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1') -Destination $sandbox
    foreach ($file in 'Test-ProjectionPreflight.ps1','TestProjectionFixture.ps1','Test-All.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $sandbox 'tests')
    }
    $sourceCommit = (& git -C $root rev-parse HEAD).Trim()
    $baseline = Run-Suite (Join-Path $sandbox 'baseline.log')
    if ($baseline.ExitCode -ne 0 -or $baseline.Assertions -eq 0 -or $baseline.Failed -ne 0) { throw "Mutation baseline failed: $($baseline.FailureLines -join '; ')" }
    Write-Host "Baseline: $($baseline.Assertions) assertions, $($baseline.Seconds) s."
    $selected = @($cases | Where-Object { -not $Probe -or $_.Name -in $Probe })
    if (-not $selected.Count -or ($Probe -and $selected.Count -ne $Probe.Count)) { throw 'An unknown or duplicate mutation probe was requested.' }
    foreach ($case in $selected) {
        $file = Join-Path $sandbox $case.File
        $bytes = [IO.File]::ReadAllBytes($file)
        try {
            $text = Get-Content -LiteralPath $file -Raw
            $mutant = Get-MutatedSource $case $text
            $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
            [IO.File]::WriteAllText($file,$mutant,[Text.UTF8Encoding]::new($bom))
            $tokens=$null; $errors=$null
            $null = [Management.Automation.Language.Parser]::ParseInput($mutant,[ref]$tokens,[ref]$errors)
            $result = if ($errors.Count) { @{ ExitCode=1; Assertions=0; Failed=0; Seconds=0; SyntaxValid=$false; FailureLines=@('Invalid mutant syntax') } } else { Run-Suite (Join-Path $sandbox 'mutant.log') }
            $caught = Test-MutationCaught $result $baseline.Assertions
            $results.Add([pscustomobject]@{ Name=$case.Name; File=$case.File; Caught=$caught; Result=$result })
            Write-Host "[$(if($caught){'CAUGHT'}else{'NOT CAUGHT'})] $($case.Name): $($result.Assertions) assertions, $($result.Failed) failed, $($result.Seconds) s."
        } finally { [IO.File]::WriteAllBytes($file,$bytes) }
    }
    $restored = Run-Suite (Join-Path $sandbox 'restored.log')
    $good = $restored.ExitCode -eq 0 -and $restored.Assertions -eq $baseline.Assertions -and $restored.Failed -eq 0
    $missed = @($results | Where-Object { -not $_.Caught })
    if ($ReceiptPath) {
        $receipt = @{ SourceCommit=$sourceCommit; Baseline=$baseline; Restored=$restored; Results=@($results); Seconds=[Math]::Round($clock.Elapsed.TotalSeconds,2) }
        [IO.File]::WriteAllText($ReceiptPath,($receipt | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
    Write-Host "P84 mutations: $($results.Count-$missed.Count)/$($results.Count) caught; baseline=$($baseline.Assertions); restored=$good; seconds=$([Math]::Round($clock.Elapsed.TotalSeconds,2))."
    if ($missed.Count -or -not $good) { exit 1 }
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
