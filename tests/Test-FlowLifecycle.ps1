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
. (Join-Path $root 'scripts\flow\LifecycleCommon.ps1')

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
$refs = @(Get-ClaudePolicyNamedValueReferences -PolicyPath $policyPath)
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
Assert 'derived named values include later-release values without hardcoding the detector list' ($migration2Source -match 'Get-ClaudePolicyNamedValueReferences' -and $migration2Source -match '\$missing = @\(\$refs \| Where-Object')
Assert 'rollback plan names Restore-ClaudeGateway' ($policyPlan.Rollback -match 'Restore-ClaudeGateway')
Assert 'policy migration requires a snapshot before writes' ((Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw) -match 'Assert-ClaudeFlowSnapshotBeforeWrite')

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

$normalizedPolicy = '<policies>usd-budgets usd-budget-state external-idp-extra-audience 00000000-0000-0000-0000-000000000000 entitlement-source</policies>'
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
function Get-ClaudeFlowApimMonthlyCost {
    param([string]$Sku, [string]$Region, [int]$Units = 1)
    New-ClaudeFlowCost -Item "API Management $Sku" -MonthlyUsd ([decimal]($(if ($Sku -eq 'BasicV2') { 150 } elseif ($Sku -eq 'StandardV2') { 700 } else { 2800 }))) -Source 'test retail price'
}
$tierRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ sku = [pscustomobject]@{ target = 'StandardV2' } } }
$tierDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2' }
$tierOptions = @(Get-ClaudeTierChangeOptions -Record $tierRecord -Discovery $tierDiscovery)
Assert 'tier options offer Basic v2 to Standard v2 in-place' (@($tierOptions | Where-Object { $_.Key -eq 'StandardV2' -and $_.InPlace }).Count -eq 1)
Assert 'tier options do not offer Premium v2 injection as in-place' (@($tierOptions | Where-Object { $_.Key -eq 'PremiumV2' -and (-not $_.InPlace) }).Count -eq 1)
$tierPlan = Get-ClaudeFlowStepPlan -Record $tierRecord -Discovery $tierDiscovery
Assert 'tier plan includes live retail cost and Microsoft Learn research citations' ($tierPlan.Costs[0].MonthlyUsd -eq 700 -and (($tierPlan.Implications -join "`n") -match 'learn.microsoft.com/en-us/azure/api-management'))
Assert 'tier apply snapshots before in-place write' ((Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'Assert-ClaudeFlowSnapshotBeforeWrite')
Assert 'tier apply uses a v2-capable ARM API version' ((Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'api-version=2024-05-01' -and (Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'Invoke-RestMethod -Method Patch')

. (Join-Path $root 'scripts\flow\Entitlement.ps1')
$entRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } } }
$entDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; namedValues = @{ 'entitlement-source' = 'named-value' }; cleanComparison = $false }
$entPlan = Get-ClaudeFlowStepPlan -Record $entRecord -Discovery $entDiscovery
Assert 'entitlement plan states Basic v2 public Entra resolver rule' (($entPlan.Implications -join "`n") -match 'Basic v2 uses a public resolver endpoint')
Assert 'entitlement flip is refused without clean comparison before backup/write' ((Get-Thrown { Invoke-ClaudeFlowStep -Record $entRecord -Plan $entPlan }) -match 'clean projection comparison')

. (Join-Path $root 'scripts\flow\Network.ps1')
$netRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ network = [pscustomobject]@{ reviewPath = 'review.json' } } }
$netPlan = Get-ClaudeFlowStepPlan -Record $netRecord -Discovery $tierDiscovery
Assert 'network flow keeps its own fingerprint approval requirement' (($netPlan.Implications -join "`n") -match 'not a substitute' -and (Get-Thrown { Invoke-ClaudeFlowStep -Record $netRecord -Plan $netPlan }) -match 'reviewed plan fingerprint')

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
Assert 'desktop sign-in apply snapshots before audience write' ((Get-Content (Join-Path $root 'scripts\flow\DesktopSignIn.ps1') -Raw) -match 'Assert-ClaudeFlowSnapshotBeforeWrite')

Write-Host ''
Write-Host 'P66 lifecycle - plans write nothing' -ForegroundColor Cyan
$updateScript = Get-Content (Join-Path $root 'scripts\Update-ClaudeGateway.ps1') -Raw
Assert 'standalone update has plan-only default' ($updateScript -match 'Plan only\. Nothing has been changed' -and $updateScript -match 'Add -Apply')
Assert 'standalone update fingerprints before apply' ($updateScript -match 'Get-ClaudeFlowFingerprint' -and $updateScript -match 'ApprovedPlanFingerprint')
Assert 'standalone update uses a stable default snapshot path so the approval fingerprint can be reused' ($updateScript -match 'before-update-\$\(\$target\.ApimName\)\.json' -and $updateScript -notmatch 'before-update-\$\(\$target\.ApimName\)-\$stamp')
Assert 'standalone update writes release and record only after applying' ($updateScript.IndexOf('Set-ClaudeDecisionRelease') -gt $updateScript.IndexOf('foreach ($file in $migrationFiles)'))
Assert 'plans do not call Set-ApimNamedValue directly' ((Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw).IndexOf('function Get-ClaudeFlowMigrationPlan') -lt (Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw).IndexOf('function Invoke-ClaudeFlowMigration'))

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Lifecycle flow contract holds.' -ForegroundColor Green
exit 0
