param([string]$CallerChild, [ValidateSet('Absent','Error')][string]$Case = 'Absent',
    [ValidateSet('All','Core','Callers','Cultures')][string]$Group = 'All')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
Reset-ProjectionFixture

if ($CallerChild) {
    $global:R1CallerCase = $Case
    $global:R1Reads = 0; $global:R1Writes = 0
    $global:R1Rest = (Microsoft.PowerShell.Core\Get-Command Invoke-RestMethod).ScriptBlock
    function Invoke-RestMethod {
        param($Uri,$Headers,$Method,$ErrorAction,$TimeoutSec,$Body,$ContentType,[switch]$UseBasicParsing)
        if ([string]$Uri -like 'https://graph.microsoft.com/*') { $global:R1Reads++ }
        if ([uri]::UnescapeDataString([string]$Uri) -match "displayName eq 'claude-code-premium'") {
            if ($global:R1CallerCase -eq 'Error') { throw 'Graph 403 caller fixture: membership read denied' }
            return [pscustomobject]@{ value=@() }
        }
        & $global:R1Rest @PSBoundParameters
    }
    function az {
        $global:LASTEXITCODE = 0
        $line = $args -join ' '
        if ($line -match '\b(create|update|delete|set)\b') { $global:R1Writes++; throw "Unexpected caller write: $line" }
        if ($line -like 'account show*') { return (@{ id=$FixtureSubscription; tenantId=$FixtureTenant; user=@{name='fixture';type='user'} } | ConvertTo-Json -Compress) }
        if ($line -like 'account get-access-token*') { return '{"accessToken":"offline-token"}' }
        $map = [ordered]@{
            'allow-standard'=",$FixtureApp,"; 'allow-premium'=','
            'bu-registry'=',unit=claude-code-premium:100,'; 'bu-parents'=','
            'bu-members'=",$FixtureApp=unit,"; 'entitlement-source'='named-value'
        }
        if ($line -like 'apim nv list*') {
            $values = @($map.GetEnumerator() | ForEach-Object { @{name=$_.Key;value=$_.Value;secret=$false} })
            return (ConvertTo-Json -InputObject $values -Compress)
        }
        if ($line -like 'apim nv show*') {
            $id = $args[([array]::IndexOf($args,'--named-value-id') + 1)]
            if ($line -match '--query value') { return [string]$map[$id] }
            return (@{ name=$id; value=$map[$id]; secret=$false } | ConvertTo-Json -Compress)
        }
        throw "Unexpected caller read: $line"
    }
    $file = Join-Path ([IO.Path]::GetTempPath()) ('p84-caller-' + [guid]::NewGuid().ToString('N') + '.json')
    $errorMessage = ''
    try {
        $target = @{ ApimName='apim-p84'; ResourceGroup='rg-p84' }
        switch ($CallerChild) {
            'Sync-ClaudeAccess' { & (Join-Path $root 'scripts\Sync-ClaudeAccess.ps1') @target -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -WhatIf }
            'Compare-ClaudeEntitlement' { & (Join-Path $root 'scripts\Compare-ClaudeEntitlement.ps1') @target -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -FailOnDrift:$true }
            'Sync-ClaudeProjection' { & (Join-Path $root 'scripts\Sync-ClaudeProjection.ps1') @target -Account cosmos-p84fixture -StandardGroup claude-code-standard -PremiumGroup claude-code-premium -ExportPath $file }
            'Sync-AumMembership' { & (Join-Path $root 'scripts\Sync-AumMembership.ps1') @target -ScopeIds unit }
            default { throw 'Unknown caller fixture.' }
        }
    } catch { $errorMessage = $_.Exception.Message }
    finally { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
    Write-Host "R1_CALLER reads=$R1Reads writes=$R1Writes error=$errorMessage"
    exit ([int][bool]$errorMessage)
}

$clock = [Diagnostics.Stopwatch]::StartNew()
$script:count=0; $script:failed=0
function Assert($Name,$Pass,$Detail='') {
    $script:count++
    if ($Pass) { Write-Host "[OK] $Name" }
    else { $script:failed++; Write-Host "[FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:Failure=''; $script:Result=$null
    $lines=[Collections.Generic.List[string]]::new()
    try {
        & $Action 6>&1 3>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.InformationRecord]) { $lines.Add([string]$_.MessageData) }
            elseif ($_ -is [Management.Automation.WarningRecord]) { $lines.Add([string]$_) }
            else { $script:Result=$_; $lines.Add([string]$_) }
        }
    } catch { $script:Failure=$_.Exception.Message }
    $script:Output=($lines -join "`n") + "`n" + $Failure
}
. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
. (Join-Path $root 'scripts\ClaudeRunner.ps1')
function Preflight($Scenario, [hashtable]$Extra=@{}) {
    Reset-ProjectionFixture $Scenario
    $parameters=@{ResourceGroup='rg-p84';ApimName='apim-p84';NamePrefix='p84fixture'}
    foreach($key in $Extra.Keys){$parameters[$key]=$Extra[$key]}
    Capture { Invoke-ClaudeProjectionPreflight @parameters }
}

if ($Group -in @('All','Core')) {
foreach($scenario in 'premium-missing','policy-error','policy-false','policy-shape','guest') {
    Preflight $scenario
    Assert "preflight does not invent denial: $scenario" (-not $Failure) $Failure
    if($scenario -eq 'premium-missing') {
        Assert 'confirmed-absent premium is a PASS with an absence note' ($Output -match 'PASS' -and $Output -match 'optional.*absent|absent.*optional')
    } else {
        Assert "unknown creation rights are WARN: $scenario" ($Output -match 'WARN' -and $Output -match 'cannot confirm' -and $Output -match '-ResolverAppId')
    }
}
Preflight 'group-error'
Assert 'optional premium lookup error still fails' ([bool]$Failure)
Preflight 'policy-error' @{ResolverAppId=$FixtureApp}
Assert 'supplied app skips policy-class reads' (-not $Failure -and ($FixtureCalls -join "`n") -notmatch 'authorizationPolicy')

$rows=@([pscustomobject]@{Check='Resolver registration';Result='WARN';Evidence=('permission unknown ' * 8);Remedy=('customer admin fallback ' * 9);Who='customer Entra admin'})
Capture { Format-ClaudeProjectionChecks -Checks $rows -Width 100 }
Assert '100-column report has bounded lines' (-not $Failure -and @($Output -split '\r?\n' | Where-Object { $_.Length -gt 100 }).Count -eq 0)
Assert 'narrow records preserve every field' ($Output -match 'Check:' -and $Output -match 'Result:' -and $Output -match 'Evidence:' -and $Output -match 'Remedy:' -and $Output -match 'Who:')

foreach($confirm in @($false,$true)) {
    Reset-ProjectionFixture
    $FixtureJob.properties.template.containers[0].args=@('--whatif')
    $FixtureExecution.properties.template.containers[0].args=@('--whatif')
    Capture { & (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -ResourceGroup rg-p84 -ApimName apim-p84 -NamePrefix p84fixture -FlipAfterCleanCompare -ReconcilerResourceId $FixtureJobId -Confirm:$confirm }
    Assert "deployer refuses missing P86 admission inputs before Azure calls: confirm=$confirm" ($Failure -and $Output -match 'P86 admission requires' -and $Output -match '60-90 minutes')
    Assert "deployer refusal precedes every Azure call: confirm=$confirm" ($FixtureCalls.Count -eq 0)
}
Reset-ProjectionFixture
Capture { & (Join-Path $root 'Install-ClaudeGateway.ps1') -FlipProjectionAfterCleanCompare -DeployProjection -ProjectionReconcilerResourceId $FixtureJobId -Yes }
Assert 'real installer refuses missing renewal digest/action group before discovery, prompts or writes' ($Failure -and $Output -match 'P86 admission requires' -and $Output -match '60-90 minutes' -and $FixtureCalls.Count -eq 0)

. (Join-Path $root 'scripts\flow\Entitlement.ps1')
$record=[pscustomobject]@{schemaVersion=2;decisions=[pscustomobject]@{entitlementStore=[pscustomobject]@{target='projection';reconcilerResourceId=$FixtureJobId}};history=@()}
$discovery=[pscustomobject]@{resourceGroup='rg-p84';apimName='apim-p84';sku='BasicV2';namedValues=@{'entitlement-source'='named-value'};cleanComparison=$true}
$plan=Get-ClaudeFlowStepPlan -Record $record -Discovery $discovery
Reset-ProjectionFixture
Capture { Invoke-ClaudeFlowStep -Record $record -Plan $plan }
Assert 'real Entitlement refuses missing P86 evidence with expected wait' ($Failure -and $Output -match 'P86 admission needs' -and $Output -match '60-90 minutes' -and $FixtureCalls.Count -eq 0)

$discoveryGood=[pscustomobject]@{
    resourceGroup='rg-p84';apimName='apim-p84';sku='BasicV2';namedValues=@{'entitlement-source'='named-value'};cleanComparison=$true
    renewal=[pscustomobject]@{
        kind='claude-projection-renewal-receipt'; schemaVersion=1
        runnerName='aci-projtest-p84fixture'; cosmosAccount='cosmos-p84fixture'; tenantId=$FixtureTenant; accountResourceId=$FixtureCosmosId
        reconcilerResourceId=$FixtureJobId; imageDigest=('sha256:' + ('a' * 64)); actionGroupResourceId="$FixtureRgId/providers/Microsoft.Insights/actionGroups/ag-projection-renewal"
        entryPoint='node /app/sync/src/apply-projection.mjs'
    }
}
$planGood=Get-ClaudeFlowStepPlan -Record $record -Discovery $discoveryGood
$planGood.Data.SnapshotPath = Join-Path ([IO.Path]::GetTempPath()) 'p86-flow-good-snapshot.json'
$planGood.Data.SnapshotTaken = $true
Reset-ProjectionFixture
Capture { Invoke-ClaudeFlowStep -Record $record -Plan $planGood }
# P95: the flow switches through Invoke-ClaudeProjectionSwitch, which needs every receipt field; the
# good path, through the real drift check to the one write, is in tests/Test-ProjectionSwitch.ps1.
Assert 'real Entitlement refuses renewal evidence without every receipt field, before any Azure call' ($Failure -and $Output -match 'renewal evidence has no' -and $FixtureCalls.Count -eq 0)
Assert 'real Entitlement writes no named value when the evidence is incomplete' (($FixtureCalls -join "`n") -notmatch 'apim nv update')

$goodJob = $FixtureJob | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$goodJob.properties.template.containers[0].image = 'example.invalid/projection@sha256:' + ('a' * 64)
$goodJob.properties.template.containers[0].command = @()
$goodJob.properties.template.containers[0].args = @()
Assert 'job definition accepts pinned digest with no command or args override' (Assert-ClaudeProjectionJobDefinition -Job $goodJob -ImageDigest ('sha256:' + ('a' * 64)))
$badJob = $goodJob | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$badJob.properties.template.containers[0].args = @('--whatif')
Capture { Assert-ClaudeProjectionJobDefinition -Job $badJob -ImageDigest ('sha256:' + ('a' * 64)) }
Assert 'job definition rejects args override even when evidence could be good' ($Failure -and $Output -match 'command or args override')

Capture { ConvertFrom-ClaudeProjectionAdmissionResult -RawOutput '{"ok":false,"reason":"missing action group"}' }
Assert 'admission JSON names missing action group as a switch refusal' ($Failure -and $Output -match 'missing action group')

$oid='11111111-2222-4333-8444-555555555555'
$private='secret-finance-unit'
$summary=@{ok=$false;compared=5;differences=1;sample=@(@{oid=$oid;email='private@example.invalid';kind='unit-drift';gateway=$private;projection='secret-platform-unit'})} | ConvertTo-Json -Depth 6 -Compress
$wide=@{ok=$false;compared=999999999999;projectionRecords=999999999999;differences=999999999999;resolved=999999999999;existing=999999999999;toWrite=999999999999;toDelete=999999999999;keptOrphans=999999999999;unchanged=999999999999;written=999999999999;writeFailed=999999999999;deleted=999999999999;deleteFailed=999999999999} | ConvertTo-Json -Compress
foreach($step in 'apply','compare') {
    foreach($raw in @($summary, "prefix private@example.invalid $private`n{$private", '{"private@example.invalid":{"secret-finance-unit":!', '{"ok":false,"compared":"private@example.invalid","differences":"secret-finance-unit"}', ((1..80 | ForEach-Object { 'private@example.invalid secret-finance-unit ' + ('x'*600) }) -join "`n"), ((1..80 | ForEach-Object { $wide }) -join "`n"))) {
        Capture { ConvertFrom-ClaudeRunnerResult -RawOutput $raw -Step $step }
        Assert "$step rejects unsuccessful/malformed output" ([bool]$Failure)
        Assert "$step hides email, unit and raw oid" ($Output -notmatch 'private@example.invalid|secret-finance-unit|secret-platform-unit' -and $Output -notmatch [regex]::Escape($oid))
        Assert "$step diagnostic is capped in lines and characters" ($Output.Length -le (4097 + $Failure.Length) -and @($Output -split '\r?\n' | Where-Object { $_ }).Count -le 41)
    }
}
Capture { Write-ClaudeRunnerOutput -RawOutput $summary -Step compare }
Assert 'structured diagnostics retain useful counts and hashed samples' ($Output -match 'compared=5' -and $Output -match 'differences=1' -and $Output -match 'oid-sha256=[0-9a-f]{12}')
# The heading counts: the diagnostic itself is at most 40 lines and 4096 characters, truncation marker included.
$shortSummaries = (1..40 | ForEach-Object { '{"ok":false,"compared":1,"differences":1}' }) -join "`n"
$longLines = (1..80 | ForEach-Object { 'private@example.invalid secret-finance-unit ' + ('x'*600) }) -join "`n"
foreach ($diagCase in @(@{ Name='forty short summaries'; Raw=$shortSummaries }, @{ Name='eighty long lines'; Raw=$longLines }, @{ Name='eighty wide summaries'; Raw=((1..80 | ForEach-Object { $wide }) -join "`n") })) {
    Capture { Write-ClaudeRunnerOutput -RawOutput $diagCase.Raw -Step compare }
    $text = $Output.TrimEnd("`n")
    $lineCount = @($text -split '\r?\n').Count
    Assert "the diagnostic for $($diagCase.Name) is at most 40 lines, heading included, and 4096 characters" ($lineCount -le 40 -and $text.Length -le 4096) "lines=$lineCount chars=$($text.Length)"
}
# A sweep of summary widths reaches the case where truncation cuts inside the last of 40 lines.
$sweepWorst = 0
foreach ($digits in 1..15) {
    $n = '9' * $digits
    $raw = (1..39 | ForEach-Object { "{`"ok`":false,`"compared`":$n,`"projectionRecords`":$n,`"differences`":$n,`"resolved`":$n}" }) -join "`n"
    Capture { Write-ClaudeRunnerOutput -RawOutput $raw -Step compare }
    $text = $Output.TrimEnd("`n")
    $sweepWorst = [math]::Max($sweepWorst, @($text -split '\r?\n').Count)
    if ($text.Length -gt 4096) { $sweepWorst = 99 }
}
Assert 'truncation keeps every summary width within 40 lines and 4096 characters' ($sweepWorst -le 40) "worst lines=$sweepWorst"

$source=Get-Content (Join-Path $root 'scripts\Deploy-ClaudeProjection.ps1') -Raw
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
$steps=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match 'PSCmdlet.ShouldProcess' -and $node.Clauses[0].Item1.Extent.Text -notmatch 'flip only'},$true))
foreach($step in $steps) {
    $testBlock=[scriptblock]::Create($step.Extent.Text.Replace($step.Clauses[0].Item1.Extent.Text,'$false'))
    Capture { & $testBlock }
    Assert "declined prerequisite aborts: $($step.Clauses[0].Item1.Extent.Text)" ($Failure -and $Output -match 'declined.*abort|declined.*stopp|declined.*no further|declined after admission') $Failure
}
Assert 'all eight deployment decisions are exercised' ($steps.Count -eq 8)
# The ninth decision, the switch itself, lives in the shared switch (ADR-0050): declining it writes nothing.
$switchSource = Get-Content (Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1') -Raw
$switchAst = [Management.Automation.Language.Parser]::ParseInput($switchSource, [ref]$tokens, [ref]$errors)
$switchSteps = @($switchAst.FindAll({ param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -match '-not \$PSCmdlet\.ShouldProcess' }, $true))
foreach ($step in $switchSteps) {
    $testBlock = [scriptblock]::Create($step.Extent.Text.Replace($step.Clauses[0].Item1.Extent.Text, '$true'))
    Capture { & $testBlock }
    Assert "declined switch aborts: $($step.Clauses[0].Item1.Extent.Text)" ($Failure -and $Output -match 'declined after admission' -and $Output -match 'unchanged') $Failure
}
Assert 'the switch decision is exercised' ($switchSteps.Count -eq 1)
Assert 'deployer binds the comparison Boolean rather than an absent switch value' ($source -match '-FailOnDrift:\$true')
}

$scratch=Join-Path ([IO.Path]::GetTempPath()) ('p84-council-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $scratch
try {
    $hosts=@((Microsoft.PowerShell.Core\Get-Command pwsh).Source, (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    if ($Group -in @('All','Callers')) {
        foreach($shell in $hosts) {
            foreach($caller in 'Sync-ClaudeAccess','Compare-ClaudeEntitlement','Sync-ClaudeProjection','Sync-AumMembership') {
                if($caller -eq 'Sync-ClaudeProjection' -and $shell -like '*\powershell.exe'){continue}
                foreach($caseName in 'Absent','Error') {
                    $log=Join-Path $scratch 'caller.log'
                    & $shell -NoProfile -NonInteractive -File $PSCommandPath -CallerChild $caller -Case $caseName *> $log
                    $code=$LASTEXITCODE;$text=Get-Content $log -Raw
                    $expectFailure=$caseName -eq 'Error' -or $caller -eq 'Sync-AumMembership'
                    $reason=if($caseName -eq 'Error'){'Graph 403 caller fixture'}elseif($caller -eq 'Sync-AumMembership'){'confirmed absent'}else{'R1_CALLER reads=[1-9]'}
                    Assert "$caller $caseName on $([IO.Path]::GetFileName($shell))" (($code -ne 0) -eq $expectFailure -and $text -match $reason -and $text -match 'writes=0') (($text -split "`n" | Where-Object { $_ -match 'R1_CALLER' }) -join '')
                }
            }
        }
    }
    if ($Group -in @('All','Cultures')) {
        foreach($culture in 'en-US','en-GB','de-DE') {
            $log=Join-Path $scratch "culture-$culture.log"
            & $hosts[0] -NoProfile -File (Join-Path $PSScriptRoot 'Test-ProjectionPreflight.ps1') -Culture $culture *> $log
            $code=$LASTEXITCODE;$text=Get-Content $log -Raw
            $receipt=[regex]::Match($text,'P84 assertions=(\d+) failed=0')
            if($culture -eq 'en-US'){$baselineCount=if($receipt.Success){$receipt.Groups[1].Value}else{''}}
            Assert "complete preflight suite is culture-independent: $culture" ($code -eq 0 -and $receipt.Success -and $receipt.Groups[1].Value -eq $baselineCount)
        }
    }
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Write-Host ("P84_COUNCIL assertions={0} failed={1} seconds={2:F2}" -f $count,$failed,$clock.Elapsed.TotalSeconds)
exit ([int]($failed -gt 0))
