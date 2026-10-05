# P66 lifecycle flow: update migrations and change modules. Offline; no Azure writes.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1')

Write-Host ''
Write-Host 'P66 lifecycle - migration detection' -ForegroundColor Cyan

$record = [pscustomobject]@{
    schemaVersion = 1
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    location = 'eastus2'
    sku = 'BasicV2'
}
$policyPath = Join-Path $root 'infra\policy.xml'
$currentPolicy = [IO.File]::ReadAllText($policyPath)
$refs = @(Get-ClaudeFlowLifecyclePolicyNamedValueReferences -PolicyPath $policyPath)
$nv = @{}
foreach ($r in $refs) { $nv[$r] = 'x' }
$nv.Remove('usd-budgets')
$nv.Remove('external-idp-extra-audience')
$oldDiscovery = [pscustomobject]@{
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    location = 'eastus2'
    sku = 'BasicV2'
    policy = '<policies><inbound><base /></inbound></policies>'
    namedValues = $nv
}

. (Join-Path $root 'scripts\flow\migrations\0001-record-schema-v2.ps1')
$schemaPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $oldDiscovery
Assert 'old schema is detected' (-not (Test-ClaudeFlowPlanIsNoop $schemaPlan) -and $schemaPlan.Actions[0].Detail -match '1 -> 2')

. (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1')
$policyPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $oldDiscovery
Assert 'old policy hash is detected' (@($policyPlan.Actions | Where-Object Target -match 'policy').Count -eq 1)
Assert 'missing named values are derived from policy references' (($policyPlan.Data.MissingNamedValues -contains 'usd-budgets') -and ($policyPlan.Data.MissingNamedValues -contains 'external-idp-extra-audience'))
$migration2Source = Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw
Assert 'derived named values include later-release values without hardcoding the detector list' ($migration2Source -match 'Get-ClaudeFlowLifecyclePolicyNamedValueReferences' -and $migration2Source -match '\$missing = @\(\$refs \| Where-Object')
Assert 'rollback plan names Restore-ClaudeGateway' ($policyPlan.Rollback -match 'Restore-ClaudeGateway')
Assert 'policy migration requires a snapshot before writes' ((Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw) -match 'Assert-ClaudeFlowLifecycleSnapshotBeforeWrite')

$allNv = @{}
foreach ($r in $refs) { $allNv[$r] = 'x' }
$freshDiscovery = [pscustomobject]@{
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    location = 'eastus2'
    sku = 'BasicV2'
    policy = $currentPolicy
    namedValues = $allNv
    jobs = @()
}
$noopPolicy = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $freshDiscovery
Assert 'migration is idempotent when policy and named values match' (Test-ClaudeFlowPlanIsNoop $noopPolicy)

$normalizedPolicy = '<policies>usd-budgets usd-budget-state external-idp-extra-audience urn:disabled:claude-extra-audience entitlement-source</policies>'
$normalizedPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $normalizedPolicy; namedValues = $allNv })
Assert 'APIM-normalized current policy markers do not cause repeated updates' (Test-ClaudeFlowPlanIsNoop $normalizedPlan)

$blankAudience = @{}
foreach ($r in $refs) { $blankAudience[$r] = 'x' }
$blankAudience['external-idp-extra-audience'] = ' '
$blankPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $currentPolicy; namedValues = $blankAudience })
Assert 'migration normalizes a blank Desktop audience before policy validation' ($blankPlan.Data.NormalizeDisabledAudience -eq $true -and (($blankPlan.Actions | ForEach-Object Target) -contains 'named value external-idp-extra-audience'))

. (Join-Path $root 'scripts\flow\migrations\0003-job-pins.ps1')
$jobPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ jobs = @([pscustomobject]@{ name = 'turnstile-apply'; commit = 'old' }) })
Assert 'old job commit pins are detected when present' (-not (Test-ClaudeFlowPlanIsNoop $jobPlan) -and $jobPlan.Actions[0].Target -match 'turnstile-apply')

$migrationNames = @(Get-ChildItem (Join-Path $root 'scripts\flow\migrations') -Filter '*.ps1' | Sort-Object Name | ForEach-Object Name)
Assert 'migrations are ordered by numeric prefix' (($migrationNames -join ',') -match '^0001-.*0002-.*0003-') ($migrationNames -join ',')

Write-Host ''
Write-Host 'P66 lifecycle - change modules' -ForegroundColor Cyan

. (Join-Path $root 'scripts\flow\Tier.ps1')
function Get-ClaudeFlowLifecycleApimMonthlyCost {
    param([string]$Sku, [string]$Region, [int]$Units = 1)
    New-ClaudeFlowCost -Item "API Management $Sku" -MonthlyUsd ([decimal]($(if ($Sku -eq 'BasicV2') { 150 } elseif ($Sku -eq 'StandardV2') { 700 } else { 2800 }))) -Source 'test retail price'
}
$tierRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ sku = [pscustomobject]@{ target = 'StandardV2' } } }
$tierDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2' }
$tierOptions = @(Get-ClaudeFlowTierChangeOptions -Record $tierRecord -Discovery $tierDiscovery)
Assert 'tier options offer Basic v2 to Standard v2 in-place' (@($tierOptions | Where-Object { $_.Key -eq 'StandardV2' -and $_.InPlace }).Count -eq 1)
Assert 'tier options do not offer Premium v2 injection as in-place' (@($tierOptions | Where-Object { $_.Key -eq 'PremiumV2' -and (-not $_.InPlace) }).Count -eq 1)
$tierQuestions = @(Get-ClaudeFlowStepQuestions -Record $tierRecord -Discovery $tierDiscovery)
Assert 'tier question uses orchestrator property names' ($tierQuestions[0].Key -eq 'sku' -and $tierQuestions[0].Question -and $tierQuestions[0].WhereToFind -and $tierQuestions[0].PSObject.Properties.Name -contains 'AcceptRecommendedWithoutConsole')
$tierPlan = Get-ClaudeFlowStepPlan -Record $tierRecord -Discovery $tierDiscovery
Assert 'tier plan includes live retail cost and Microsoft Learn research citations' ($tierPlan.Costs[0].MonthlyUsd -eq 700 -and (($tierPlan.Implications -join "`n") -match 'learn.microsoft.com/en-us/azure/api-management'))
Assert 'tier apply snapshots before in-place write' ((Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'Assert-ClaudeFlowLifecycleSnapshotBeforeWrite')
Assert 'tier apply uses a v2-capable ARM API version' ((Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'api-version=2024-05-01' -and (Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'Invoke-RestMethod -Method Patch')

. (Join-Path $root 'scripts\flow\Entitlement.ps1')
$entRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } } }
$entDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; namedValues = @{ 'entitlement-source' = 'named-value' }; cleanComparison = $false }
$entPlan = Get-ClaudeFlowStepPlan -Record $entRecord -Discovery $entDiscovery
Assert 'entitlement plan states Basic v2 public Entra resolver rule' (($entPlan.Implications -join "`n") -match 'Basic v2 uses a public resolver endpoint')
Assert 'entitlement flip is refused without P86 renewal evidence before backup/write' ((Get-Thrown { Invoke-ClaudeFlowStep -Record $entRecord -Plan $entPlan }) -match 'P86 admission needs renewal runner, Cosmos destination, reconciler job, image digest and email action group evidence')
$entQuestions = @(Get-ClaudeFlowStepQuestions -Record $entRecord -Discovery $entDiscovery)
Assert 'entitlement question uses orchestrator property names' ($entQuestions[0].Key -eq 'entitlementStore' -and $entQuestions[0].Question -and $entQuestions[0].WhereToFind)

. (Join-Path $root 'scripts\flow\Network.ps1')
$netRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ network = [pscustomobject]@{ reviewPath = 'review.json' } } }
$netPlan = Get-ClaudeFlowStepPlan -Record $netRecord -Discovery $tierDiscovery
Assert 'network flow keeps its own fingerprint approval requirement' (($netPlan.Implications -join "`n") -match 'not a substitute' -and (Get-Thrown { Invoke-ClaudeFlowStep -Record $netRecord -Plan $netPlan }) -match 'reviewed plan fingerprint')
$netQuestions = @(Get-ClaudeFlowStepQuestions -Record $netRecord -Discovery $tierDiscovery)
Assert 'network question uses orchestrator property names' ($netQuestions[0].Key -eq 'network.reviewPath' -and $netQuestions[0].WhereToFind)

. (Join-Path $root 'scripts\flow\DesktopSignIn.ps1')
$desktopRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{} }
$desktopDiscovery = [pscustomobject]@{
    resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'
    namedValues = @{ 'external-idp-extra-audience' = '' }
    desiredDesktopSignIn = [pscustomobject]@{
        kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'access_token'
        clientId = '11111111-1111-1111-1111-111111111111'
        issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0'
        scopes = 'api://gateway-claude/user_impersonation'
        audience = 'api://gateway-claude'
    }
}
$desktopPlan = Get-ClaudeFlowStepPlan -Record $desktopRecord -Discovery $desktopDiscovery
Assert 'desktop sign-in change writes the extra audience and flags device profile regeneration' (($desktopPlan.Actions | ForEach-Object Target) -contains 'named value external-idp-extra-audience' -and (($desktopPlan.Actions | ForEach-Object Detail) -join ' ') -match 'regenerated')
Assert 'desktop sign-in apply snapshots before audience write' ((Get-Content (Join-Path $root 'scripts\flow\DesktopSignIn.ps1') -Raw) -match 'Assert-ClaudeFlowLifecycleSnapshotBeforeWrite')
$desktopQuestions = @(Get-ClaudeFlowStepQuestions -Record $desktopRecord -Discovery $desktopDiscovery)
Assert 'desktop question uses orchestrator property names' ($desktopQuestions[0].Key -eq 'desktopSignIn' -and $desktopQuestions[0].AcceptRecommendedWithoutConsole)

Write-Host ''
Write-Host 'P96 - the Tier and Desktop sign-in changes name their snapshot as Start prepares them' -ForegroundColor Cyan
# Start-ClaudeGateway.ps1 removes the step functions, dot-sources each module and keeps its Initialize-ClaudeFlowStep
# as Prepare (Start-ClaudeGateway.ps1:154-176). A module without one gets none, and its write gate then stops with
# "A named-value snapshot path is required". The same sequence here, with a repository root whose
# Backup-ClaudeGateway.ps1 writes the snapshot file.
$stubRoot = Join-Path ([IO.Path]::GetTempPath()) ('p96-flow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $stubRoot 'scripts') | Out-Null
[IO.File]::WriteAllText((Join-Path $stubRoot 'scripts\Backup-ClaudeGateway.ps1'), "param([string]`$ResourceGroup, [string]`$ApimName, [string]`$Path, [string]`$SubscriptionId)`nNew-Item -ItemType Directory -Force -Path (Split-Path `$Path -Parent) | Out-Null`n[IO.File]::WriteAllText(`$Path, '{}')`nexit 0`n")
$prepared = @(foreach ($case in @(
            @{ Module = 'Tier.ps1'; Record = $tierRecord; Discovery = $tierDiscovery; Prefix = 'before-tier-apim-contoso-' }
            @{ Module = 'DesktopSignIn.ps1'; Record = $desktopRecord; Discovery = $desktopDiscovery; Prefix = 'before-desktop-sign-in-apim-contoso-' }
        )) {
        foreach ($name in 'Get-ClaudeFlowStepPlan', 'Initialize-ClaudeFlowStep', 'Invoke-ClaudeFlowStep') { Remove-Item "function:\$name" -Force -ErrorAction SilentlyContinue }
        . (Join-Path $root "scripts\flow\$($case.Module)")
        $prepare = if (Get-Command Initialize-ClaudeFlowStep -ErrorAction SilentlyContinue) { (Get-Command Initialize-ClaudeFlowStep).ScriptBlock } else { $null }
        $plan = Get-ClaudeFlowStepPlan -Record $case.Record -Discovery $case.Discovery
        $realRoot = ${function:Get-ClaudeFlowLifecycleRepoRoot}
        Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value ([scriptblock]::Create("'$stubRoot'"))
        try {
            if ($prepare) { & $prepare -Record $case.Record -Plan $plan | Out-Null }
            $gate = Get-Thrown { Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $plan }
        }
        finally { Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value $realRoot }
        $path = [string]$plan.Data.SnapshotPath
        if (-not ($prepare -and -not $gate -and $path -and (Split-Path $path -Leaf).StartsWith($case.Prefix) -and (Split-Path (Split-Path $path -Parent) -Leaf) -eq 'backups' -and
                (Test-Path -LiteralPath $path) -and $plan.Data.SnapshotTaken -eq $true)) {
            "$($case.Module): prepare $([bool]$prepare), gate '$gate', path '$path'"
        }
    })
Assert 'Tier and Desktop sign-in name their snapshot under backups/ when Start prepares them, and the write gate takes it' (-not $prepared.Count) ($prepared -join ' || ')
Remove-Item -LiteralPath $stubRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'P66 lifecycle - plans write nothing' -ForegroundColor Cyan
$updateScript = Get-Content (Join-Path $root 'scripts\Update-ClaudeGateway.ps1') -Raw
$rootUpdateScript = Get-Content (Join-Path $root 'Update-ClaudeGateway.ps1') -Raw
Assert 'standalone update has plan-only default' ($updateScript -match 'Plan only\. Nothing has been changed' -and $updateScript -match 'Add -Apply')
Assert 'root update shim delegates to scripts updater for orchestrator compatibility' ($rootUpdateScript -match 'scripts\\Update-ClaudeGateway\.ps1' -and $rootUpdateScript -match 'RecordPath')
Assert 'standalone update fingerprints before apply' ($updateScript -match 'Get-ClaudeFlowFingerprint' -and $updateScript -match 'ApprovedPlanFingerprint')
Assert 'standalone update uses a stable default snapshot path so the approval fingerprint can be reused' ($updateScript -match 'before-update-\$\(\$target\.ApimName\)\.json' -and $updateScript -notmatch 'before-update-\$\(\$target\.ApimName\)-\$stamp')
Assert 'standalone update writes release and record only after applying' ($updateScript.IndexOf('Set-ClaudeDecisionRelease') -gt $updateScript.IndexOf('foreach ($file in $migrationFiles)'))
Assert 'plans do not call Set-ApimNamedValue directly' ((Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw).IndexOf('function Get-ClaudeFlowMigrationPlan') -lt (Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw).IndexOf('function Invoke-ClaudeFlowMigration'))

Write-Host ''
Write-Host 'P66 lifecycle - live discovery reads the CLI shape' -ForegroundColor Cyan
# az apim nv list returns flattened objects (name, value, secret at the top level). Measured
# 2026-09-27 on a gateway installed by the current release: reading properties.value made every
# value empty, so Update planned a false "whitespace/empty -> disabled URI sentinel" change.
$liveShape = & {
    function az {
        $joined = $args -join ' '
        if ($joined -like 'apim show*') { return '{"id":"/subscriptions/s1/resourceGroups/rg-x/providers/Microsoft.ApiManagement/service/apim-x","location":"eastus2","sku":{"name":"BasicV2","capacity":1}}' }
        if ($joined -like 'apim nv list*') { return '[{"name":"external-idp-extra-audience","value":"urn:disabled:claude-extra-audience","secret":false},{"name":"entitlement-source","value":"named-value","secret":false},{"name":"a-secret","value":null,"secret":true}]' }
        if ($joined -like 'account get-access-token*') { return 'token' }
        throw "unexpected az $joined"
    }
    function Invoke-RestMethod { [pscustomobject]@{ properties = [pscustomobject]@{ value = '<policies />' } } }
    Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup rg-x -ApimName apim-x
}
$liveMap = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $liveShape
Assert 'live discovery reads named-value values from the CLI output' ($liveMap['external-idp-extra-audience'] -eq 'urn:disabled:claude-extra-audience' -and $liveMap['entitlement-source'] -eq 'named-value') (($liveMap.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
Assert 'live discovery leaves secret named values out' (-not $liveMap.ContainsKey('a-secret'))

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Lifecycle flow contract holds.' -ForegroundColor Green
exit 0
