$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-applied-' + [guid]::NewGuid().ToString('N'))
$failed = 0; $count = 0
function Check([string]$Name, [scriptblock]$Test) {
    $script:count++
    try { $ok = [bool](& $Test); $why = '' } catch { $ok = $false; $why = $_.Exception.Message }
    if ($ok) { Write-Host "  [OK] $Name" } else { $script:failed++; Write-Host "  [FAIL] $Name $why" }
}
function Write-Json($Path,$Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false))) }
function Run-Flow($Parameters) {
    $pipeline = [powershell]::Create()
    try {
        $null = $pipeline.AddScript('param($entry,$values) & $entry @values *>&1').AddArgument((Join-Path $scratch 'Start-ClaudeGateway.ps1')).AddArgument($Parameters)
        $output = @(); $errorText = ''
        try { $output = @($pipeline.Invoke()) } catch { $errorText = $_.Exception.Message }
        [pscustomobject]@{ Failed = ($pipeline.HadErrors -or [bool]$errorText); Text = ($output -join "`n") + "`n" + $errorText + "`n" + ($pipeline.Streams.Error -join "`n") }
    }
    finally { $pipeline.Dispose() }
}
function Run-StepApply($ModuleName,$Record,$Plan) {
    $pipeline=[powershell]::Create()
    try {
        $null=$pipeline.AddScript(@'
param($Root,$ModuleName,$Record,$Plan)
. (Join-Path $Root 'scripts\flow\FlowContract.ps1')
. (Join-Path $Root "scripts\flow\$ModuleName.ps1")
$invoke=(Get-Command Invoke-ClaudeFlowStep).ScriptBlock
$info=Get-ClaudeFlowStepInfo
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'Start-ClaudeGateway.ps1'),[ref]$t,[ref]$e)
foreach($name in 'Set-FlowRecordProperty','Remove-FlowRecordProperty','Write-FlowDecisionRecord','Test-StepCompleted','Invoke-ApplySteps'){
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Get-FlowPrincipal {'fixture'}
function Get-ClaudeFlowReleaseInfo {param($Repo)[pscustomobject]@{version='fixture';commit='fixture'}}
$script:FlowAppliedDecisions=Copy-ClaudeFlowValue $Record.decisions
if($Plan.PSObject.Properties.Name -contains 'Proposal'){Set-ClaudeDecision $Record $info.DecisionKey $Plan.Proposal}
$failure=''
try{Invoke-ApplySteps -Steps @([pscustomobject]@{Info=$info;Invoke=$invoke}) -Plans @($Plan) -Record $Record -Path $Record.__recordPath -CurrentAction Change -RunId fixture | Out-Null}
catch{$failure=$_.Exception.Message}
[pscustomobject]@{Failure=$failure;Record=$Record}
'@).AddArgument($scratch).AddArgument($ModuleName).AddArgument($Record).AddArgument($Plan)
        @($pipeline.Invoke())[-1]
    }finally{$pipeline.Dispose()}
}
try {
    Check 'decision copies retain one-element and multi-element arrays as arrays' {
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        $one=Copy-ClaudeFlowValue @('new')
        $many=Copy-ClaudeFlowValue @('old','new')
        $one -is [array] -and $one.Count -eq 1 -and $one[0] -eq 'new' -and
            (ConvertTo-Json -InputObject $many -Compress) -eq '["old","new"]'
    }
    Check 'decision copies do not alias nested objects or acquire JSON wrapper properties' {
        . (Join-Path $root 'scripts\flow\FlowContract.ps1')
        $original=[pscustomobject]@{items=@([pscustomobject]@{name='old'})}
        $copy=Copy-ClaudeFlowValue $original
        $copy.items[0].name='new'
        $original.items[0].name -eq 'old' -and $copy.items -is [array] -and
            (ConvertTo-Json -InputObject $copy.items -Compress) -eq '[{"name":"new"}]'
    }
    New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts\flow') -Force | Out-Null
    foreach ($file in 'Start-ClaudeGateway.ps1','scripts\ClaudeChoice.ps1','scripts\flow\FlowContract.ps1') {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $scratch $file)
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\flow\Discovery.ps1'), @'
function Get-ClaudeFlowDiscovery {
    param($RecordPath,$Record)
    if($Record.discoveryWitness){$Record.decisions|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $Record.discoveryWitness -Encoding UTF8}
    [pscustomobject]@{ record=$Record; gateway=$null; comparison=[pscustomobject]@{ status='match'; differences=@() } }
}
'@)
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\flow\Synthetic.ps1'), @'
function Get-ClaudeFlowStepInfo { [pscustomobject]@{ Name='Synthetic'; Title='Generic decision'; DecisionKey='choice'; DependsOn=@(); Actions=@('Change','Guide') } }
function Get-ClaudeFlowStepQuestions {
    param($Record,$Discovery)
    @([pscustomobject]@{ Key='choice.value'; Type='Text'; Question='Proposed value'; Optional=$false })
}
function Get-ClaudeFlowStepPlan {
    param($Record,$Discovery)
    New-ClaudeFlowPlan -Step Synthetic -Summary "Fixture choices: $($Record.decisions.choice.value), $($Record.decisions.finops.tool)" -Actions @(New-ClaudeFlowAction -Verb Update -Target 'fixture') -Data @{ wanted=$Record.decisions.choice.value }
}
function Invoke-ClaudeFlowStep {
    param($Record,$Plan)
    $disk = Read-ClaudeDecisionRecord $Record.__recordPath
    @{ disk=$disk; passed=$Record.decisions.choice; plan=$Plan.Data.wanted } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Record.witness -Encoding UTF8
    $Record.decisions.choice.pin = 'changed-by-step'
    if ($Record.failApply) { throw 'synthetic apply failure' }
    if ($Record.omitDecision) { return @{ note='successful resource check, no applied decision change' } }
    @{ choice = [pscustomobject]@{ value=$Plan.Data.wanted; pin='new-pin' } }
}
function Test-ClaudeFlowStep { param($Record) [pscustomobject]@{ Step='Synthetic'; Passed=$true; Checks=@() } }
function Get-ClaudeFlowReleaseInfo { param($Repo) [pscustomobject]@{ version='fixture'; commit='fixture' } }
function az { $global:LASTEXITCODE=0; '{"user":{"name":"admin@contoso.com"}}' }
'@)
    foreach ($failApply in $false,$true) {
        $recordPath = Join-Path $scratch "record-$failApply.json"
        $witness = Join-Path $scratch "witness-$failApply.json"
        $original = @{
            schemaVersion=2; witness=$witness; failApply=$failApply; history=@()
            decisions=@{ choice=@{ value='old'; pin='old-pin' }; unselected=@{ value='unchanged' } }
        }
        Write-Json $recordPath $original
        $args = @{
            Action='Change'; Change='choice'; RecordPath=$recordPath
            NonInteractiveAnswers=@{ 'choice.value'='new'; 'unselected.value'='not-applied' }
        }
        $preview = Run-Flow ($args + @{ PlanOnly=$true })
        $fingerprint = [regex]::Match($preview.Text, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        Check "generic preview keeps applied decisions ($failApply)" {
            $disk = Get-Content -Raw $recordPath | ConvertFrom-Json
            -not $preview.Failed -and $fingerprint.Length -eq 64 -and $disk.decisions.choice.value -eq 'old'
        }
        $result = Run-Flow ($args + @{ ApprovedPlanFingerprint=$fingerprint })
        $seen = if (Test-Path $witness) { Get-Content -Raw $witness | ConvertFrom-Json } else { $null }
        $after = Get-Content -Raw $recordPath | ConvertFrom-Json
        Check "step receives proposed choices but durable state is still applied ($failApply)" {
            $seen.passed.value -eq 'new' -and $seen.plan -eq 'new' -and $seen.disk.decisions.choice.value -eq 'old' -and $seen.disk.decisions.choice.pin -eq 'old-pin'
        }
        Check "unselected proposed decisions never become applied ($failApply)" { $after.decisions.unselected.value -eq 'unchanged' }
        if ($failApply) {
            Check 'failed apply retains the previous decision and records no success history' {
                $result.Failed -and $result.Text -match 'synthetic apply failure' -and $after.decisions.choice.value -eq 'old' -and $after.decisions.choice.pin -eq 'old-pin' -and @($after.history).Count -eq 0
            }
        }
        else {
            Check 'successful history starts before questions, not at the proposed value' {
                -not $result.Failed -and $after.history[0].from.value -eq 'old' -and $after.history[0].from.pin -eq 'old-pin' -and $after.history[0].to.value -eq 'new'
            }
            Check 'only a successful step advances its applied decision' { $after.decisions.choice.value -eq 'new' -and $after.decisions.choice.pin -eq 'new-pin' }
        }
    }
    $unchangedPath=Join-Path $scratch 'no-returned-decision.json'
    Write-Json $unchangedPath @{schemaVersion=2;omitDecision=$true;witness=(Join-Path $scratch 'no-returned-witness.json');history=@();decisions=@{choice=@{value='old';pin='old-pin'}}}
    $parameters=@{Action='Change';Change='choice';RecordPath=$unchangedPath;NonInteractiveAnswers=@{'choice.value'='new'}}
    $preview=Run-Flow ($parameters+@{PlanOnly=$true})
    $fp=[regex]::Match($preview.Text,'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
    $result=Run-Flow ($parameters+@{ApprovedPlanFingerprint=$fp})
    Check 'a successful step does not implicitly commit a proposal it never returned' {
        $saved=Get-Content -Raw $unchangedPath|ConvertFrom-Json
        -not $result.Failed -and $saved.decisions.choice.value -eq 'old' -and $saved.decisions.choice.pin -eq 'old-pin'
    }
    $readPath=Join-Path $scratch 'read-only.json'
    $discoveryPath=Join-Path $scratch 'discovery-seen.json'
    Write-Json $readPath @{schemaVersion=2;discoveryWitness=$discoveryPath;history=@();decisions=@{choice=@{value='old'};finops=@{tool='None'}}}
    $answers=@{'choice.value'='new';'finops.tool'='AumService'}
    $status=Run-Flow @{Action='Status';RecordPath=$readPath;NonInteractiveAnswers=$answers}
    Check 'Status displays applied decisions rather than unselected proposed answers' {
        -not $status.Failed -and $status.Text -match '"tool":\s*"None"' -and $status.Text -notmatch '"tool":\s*"AumService"'
    }
    Check 'discovery receives applied values even when answers propose other decisions' {
        $seen=Get-Content -Raw $discoveryPath|ConvertFrom-Json
        $seen.finops.tool -eq 'None' -and $seen.choice.value -eq 'old'
    }
    $guide=Run-Flow @{Action='Guide';PlanOnly=$true;RecordPath=$readPath;NonInteractiveAnswers=$answers}
    Check 'Guide plans from applied state and ignores proposed answers' {
        -not $guide.Failed -and $guide.Text -match 'Fixture choices: old, None' -and $guide.Text -notmatch 'Fixture choices: new'
    }
    New-Item -ItemType Directory -Path (Join-Path $scratch 'scripts\flow\lib') -Force|Out-Null
    foreach($file in 'scripts\flow\DesktopSignIn.ps1','scripts\flow\Foundation.ps1','scripts\flow\lib\LifecycleCommon.ps1','scripts\ClaudeDesktopSignIn.ps1','scripts\ClaudeGatewayAddressInput.ps1'){
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $scratch $file)
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\ApimNamedValue.ps1'),@'
function Set-ApimNamedValue {
    param($ResourceGroup,$ApimName,$Id,$Value)
    if($Record.failApply){throw 'mocked Desktop write failed'}
}
'@)
    foreach($fail in $false,$true){
        $path=Join-Path $scratch "desktop-$fail.json"
        $r=[pscustomobject]@{schemaVersion=2;__recordPath=$path;failApply=$fail;history=@();decisions=[pscustomobject]@{
            desktopSignIn=[pscustomobject]@{kind='old'};deviceProfiles=[pscustomobject]@{regenerate=$false};unselected=[pscustomobject]@{value='applied'}
        }}
        Write-Json $path $r
        $p=[pscustomobject]@{Actions=@(@{Verb='Update';Target='fixture'});Data=@{Target=@{ResourceGroup='rg-fixture';ApimName='apim-fixture'};Desired=@{kind='helper-script'};Audience='';BeforeAudience='before';SnapshotPath='fixture';SnapshotTaken=$true}}
        $result=Run-StepApply DesktopSignIn $r $p
        $saved=Get-Content -Raw $path|ConvertFrom-Json
        Check "real DesktopSignIn commits its cross-decision change only after success ($fail)" {
            if($fail){$result.Failure -match 'mocked Desktop write failed' -and $saved.decisions.deviceProfiles.regenerate -eq $false -and @($saved.history).Count -eq 0}
            else{-not $result.Failure -and $saved.decisions.deviceProfiles.regenerate -eq $true -and $saved.decisions.unselected.value -eq 'applied'}
        }
    }
    [IO.File]::WriteAllText((Join-Path $scratch 'Install-ClaudeGateway.ps1'),@'
param()
$recordPath=Join-Path $PSScriptRoot 'onboarding\claude-gateway.json'
$config=Get-Content -Raw $recordPath|ConvertFrom-Json
$config.gatewayUrl='https://apim-fixture.azure-api.net/claude'
$config.PSObject.Properties.Remove('address')
$config.PSObject.Properties.Remove('pendingAddress')
$config.decisions.PSObject.Properties.Remove('address')
$config.decisions.foundation=[pscustomobject]@{addressMode='azure'}
$config|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $recordPath -Encoding UTF8
'@)
    New-Item -ItemType Directory -Path (Join-Path $scratch 'onboarding') -Force|Out-Null
    $path=Join-Path $scratch 'onboarding\claude-gateway.json'
    $r=[pscustomobject]@{schemaVersion=2;__recordPath=$path;gatewayUrl='https://old.contoso.test/claude';history=@();address=@{hostname='old.contoso.test'};pendingAddress=@{unverified=$true};decisions=[pscustomobject]@{foundation=[pscustomobject]@{addressMode='custom';addressHostname='old.contoso.test'};address=[pscustomobject]@{hostname='old.contoso.test'};unselected=@{value='applied'}}}
    Write-Json $path $r
    $result=Run-StepApply Foundation $r ([pscustomobject]@{Data=@{runsInstaller=$true;installerArgs=@{}}})
    $saved=Get-Content -Raw $path|ConvertFrom-Json
    Check 'Foundation Azure transition removes both company metadata copies through the orchestrator' {
        -not $result.Failure -and $saved.gatewayUrl -eq 'https://apim-fixture.azure-api.net/claude' -and
            -not $saved.address -and -not $saved.decisions.address -and -not $saved.pendingAddress -and $saved.decisions.unselected.value -eq 'applied'
    }
    Copy-Item -LiteralPath (Join-Path $root 'scripts\flow\Models.ps1') -Destination (Join-Path $scratch 'scripts\flow\Models.ps1')
    $tokens=$null;$errors=$null
    $modelAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\ClaudeModelLifecycle.ps1'),[ref]$tokens,[ref]$errors)
    $modelFunctions=foreach($name in 'Invoke-ClaudeModelWait','Write-ClaudeModelRecord','Invoke-ClaudeModelChange'){
        $modelAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true).Extent.Text
    }
    $modelStubs=@'
function Assert-ClaudeModelPlanFresh {param($Plan)}
function Get-ApimNamedValue {param($ResourceGroup,$ApimName,$SubscriptionId,$Id,[switch]$FailOnError);$Plan.Data.AfterNamedValues[$Id]}
function Write-ClaudeModelProfiles {
    param($Record,$RecordPath)
    if($Record.failApply){throw 'mocked profile generation failed'}
    [pscustomobject]@{regenerate=$false;root='new-generated-profiles';tiers=@('standard','premium')}
}
'@
    [IO.File]::WriteAllText((Join-Path $scratch 'scripts\ClaudeModelLifecycle.ps1'),($modelFunctions -join "`n")+"`n"+$modelStubs)
    $snapshot=Join-Path $scratch 'model-snapshot.json'
    Write-Json $snapshot @{fixture='prepared'}
    foreach($fail in $false,$true){
        $path=Join-Path $scratch "models-$fail.json"
        $r=[pscustomobject]@{schemaVersion=2;__recordPath=$path;failApply=$fail;models=@('old');history=@();decisions=[pscustomobject]@{
            models=[pscustomobject]@{tiers=@{old='both'}};deviceProfiles=[pscustomobject]@{root='old-profiles';regenerate=$true};unselected=[pscustomobject]@{value='applied'}
        }}
        Write-Json $path $r
        $after=[pscustomobject]@{mode='gateway';models=@('new');deployments=@(@{name='new'});tiers=@{standard=@{models=@('new')};premium=@{models=@('new')}};subscriptionId='00000000-0000-0000-0000-000000000001';tenantId='00000000-0000-0000-0000-000000000001';resourceGroup='rg-fixture';apimName='apim-fixture';foundryAccount='ai-fixture';foundryResourceGroup='rg-fixture';gatewayUrl='https://apim-fixture.azure-api.net/claude'}
        $p=[pscustomobject]@{Proposal=[pscustomobject]@{tiers=@{new='both'}};Data=@{
            SnapshotTaken=$true;SnapshotPath=$snapshot;RecordPath=$path;RecordAfter=$after;PriceChanged=$false
            Target=@{ResourceGroup='rg-fixture';ApimName='apim-fixture';SubscriptionId=$after.subscriptionId}
            Discovery=@{NamedValues=@{'models-standard'=',new,';'models-premium'=',new,'}}
            AfterNamedValues=@{'models-standard'=',new,';'models-premium'=',new,'}
            Assignments=@{new='both'};PriceBookPath='fixture-prices.json';ProfileRoot='new-generated-profiles'
        }}
        $result=Run-StepApply Models $r $p
        $saved=Get-Content -Raw $path|ConvertFrom-Json
        Check "real Models step preserves applied-only decisions on success and failure ($fail)" {
            if($fail){
                $result.Failure -match 'mocked profile generation failed' -and $saved.decisions.models.tiers.old -eq 'both' -and
                    $saved.decisions.models.tiers.PSObject.Properties.Name -notcontains 'new' -and $saved.decisions.deviceProfiles.root -eq 'old-profiles' -and @($saved.history).Count -eq 0
            }else{
                -not $result.Failure -and $saved.models[0] -eq 'new' -and $saved.decisions.models.tiers.new -eq 'both' -and
                    $saved.decisions.deviceProfiles.root -eq 'new-generated-profiles' -and $saved.decisions.unselected.value -eq 'applied'
            }
        }
    }
}
finally { if (Test-Path $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
Write-Host "Applied flow state: $count assertions, $($count - $failed) passed, $failed failed."
if ($failed) { exit 1 }
