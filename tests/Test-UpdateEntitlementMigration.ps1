# P100 (ADR-0054): the update flow moves a named-value gateway to the Cosmos projection. Offline: every Azure,
# Graph and script call goes through a test seam or the P84 fixture; nothing reaches Azure.
param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = & $Action 6>$null }
    catch { $script:CapturedError = $_.Exception.Message }
}

$standardId = '11111111-1111-4111-8111-111111111111'
$premiumId = '22222222-2222-4222-8222-222222222222'
$oid = @('a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000004')
function New-Discovery([hashtable]$NamedValues = @{}, [string]$ApimName = 'apim-contoso', [string]$Sku = 'BasicV2', [string]$Prefix = '') {
    $values = @{ 'entitlement-source' = 'named-value'; 'allow-standard' = ",$($oid[0]),$($oid[1]),"; 'allow-premium' = ",$($oid[2]),"; 'bu-registry' = 'eng=grp-eng,ops=grp-ops' }
    foreach ($k in $NamedValues.Keys) { $values[$k] = $NamedValues[$k] }
    [pscustomobject]@{ subscriptionId = '00000000-0000-4000-8000-000000000084'; resourceGroup = 'rg-contoso'; apimName = $ApimName; location = 'eastus2'; sku = $Sku
        projectionPrefix = $Prefix; namedValues = @($values.GetEnumerator() | ForEach-Object { [pscustomobject]@{ name = $_.Key; value = $_.Value } }) }
}
$record = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; standardGroup = 'team-std'; premiumGroup = 'team-prem' }
$global:GroupDirectory = @{
    'team-std' = @{ Id = $standardId; Name = 'team-std'; Members = @($oid[0], $oid[1]) }
    'team-prem' = @{ Id = $premiumId; Name = 'team-prem'; Members = @($oid[2], $oid[3]) }
    $standardId = @{ Id = $standardId; Name = 'team-std'; Members = @($oid[0], $oid[1]) }
    $premiumId = @{ Id = $premiumId; Name = 'team-prem'; Members = @($oid[2], $oid[3]) }
}
$global:GroupLookups = [Collections.Generic.List[string]]::new()
$findGroup = { param($Value) $global:GroupLookups.Add([string]$Value); $g = $global:GroupDirectory[[string]$Value]; if ($g) { [pscustomobject]$g } else { $null } }
$global:PreflightChecks = @([pscustomobject]@{ Check = 'Graph probe 1'; Result = 'PASS'; Evidence = "Graph reached at $([DateTimeOffset]::UtcNow.ToString('o'))"; Remedy = 'None' })
$global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'PASS'; Evidence = '0 of 100 used'; Remedy = '' })
$global:SeamCalls = [Collections.Generic.List[string]]::new()
$preflight = { param($Parameters) $global:SeamCalls.Add('preflight ' + (($Parameters.Keys | Sort-Object | ForEach-Object { "$_=$($Parameters[$_])" }) -join ' ')); , $global:PreflightChecks }
$readiness = { param($Parameters) $global:SeamCalls.Add('readiness ' + (($Parameters.Keys | Sort-Object | ForEach-Object { "$_=$($Parameters[$_])" }) -join ' ')); , $global:ReadinessChecks }
$inventory = { param($Parameters) [pscustomobject]@{
        Resources = @([pscustomobject]@{ Type = 'Microsoft.DocumentDB/databaseAccounts'; Name = "cosmos-$($Parameters.NamePrefix)"; Sku = 'serverless'; Region = $Parameters.Location; Template = 'infra/projection.bicep'; Purpose = 'entitlement records' })
        Network = [pscustomobject]@{ VirtualNetwork = "vnet-$($Parameters.NamePrefix)"; AddressSpace = '10.10.0.0/16'; Subnets = @(); PrivateEndpoints = @("pe-cosmos-$($Parameters.NamePrefix)"); PrivateDnsZones = @('privatelink.documents.azure.com'); ResolverAccess = $Parameters.ResolverInboundAccess; Runner = "aci-projtest-$($Parameters.NamePrefix)" }
        Identities = @([pscustomobject]@{ Principal = 'runner'; Role = 'Cosmos DB Built-in Data Contributor'; Scope = 'container entitlement'; Purpose = 'apply' }) } }
$formatInventory = { param($Plan) @('resource ' + $Plan.Resources[0].Name, 'network ' + $Plan.Network.VirtualNetwork) }
$cost = { param($Developers, $Region) [pscustomobject]@{ MonthlyUsd = [decimal]57.48; UnknownReason = '' } }
$seams = @{ FindGroup = $findGroup; Preflight = $preflight; Readiness = $readiness; Inventory = $inventory; FormatInventory = $formatInventory; Cost = $cost }
function Get-Facts([hashtable]$Extra = @{}) {
    $p = @{ Discovery = (New-Discovery); Record = $record } + $seams
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    Capture { Get-ClaudeEntitlementMigrationFacts @p }
}

. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1')
. (Join-Path $root 'scripts\ClaudeEntitlementMigration.ps1')

Write-Host 'P100 previous values: groups, prefix, developers'
Get-Facts
$f = $CapturedResult
Assert 'a named-value gateway needs the move' (-not $CapturedError -and $f.Needed -and $f.Store -eq 'named-value') $CapturedError
Assert 'the tier groups come from the decision record, found in Graph' ($f.Groups.Standard.Id -eq $standardId -and $f.Groups.Standard.Source -eq 'decision record' -and $f.Groups.Premium.Id -eq $premiumId) ($f.Groups | ConvertTo-Json -Depth 4 -Compress)
Assert 'the Entra members are compared with the named-value lists' ($f.Groups.Standard.Gained -eq 0 -and $f.Groups.Standard.Lost -eq 0 -and $f.Groups.Premium.Gained -eq 1 -and $f.Groups.Premium.Lost -eq 0)
Assert 'developers are the distinct object ids in both lists' ($f.Developers -eq 3) "$($f.Developers)"
Assert 'business units come from bu-registry' ($f.BusinessUnits -eq 2) "$($f.BusinessUnits)"
Assert 'the prefix is the gateway name without apim-, as the installer derives it' ($f.NamePrefix -eq 'contoso' -and $f.PrefixSource -match 'apim-') "$($f.NamePrefix) / $($f.PrefixSource)"
Assert 'region, SKU and public resolver access come from the gateway and ADR-0052' ($f.Location -eq 'eastus2' -and $f.Sku -eq 'BasicV2' -and $f.ResolverInboundAccess -eq 'public')
Assert 'a clean, assessed gateway is not blocked' (-not $f.Blocked -and @($f.Problems).Count -eq 0) (@($f.Problems) -join '; ')

Get-Facts @{ StandardGroup = $standardId; PremiumGroup = 'none' }
Assert 'parameters win over the record; premium none means no premium group' ($CapturedResult.Groups.Standard.Source -eq 'parameter' -and $CapturedResult.Groups.Premium.Absent) ($CapturedResult.Groups | ConvertTo-Json -Depth 4 -Compress)
$withGroups = New-Discovery @{ 'entitlement-groups' = "standard=$standardId,premium=$premiumId" }
Get-Facts @{ Discovery = $withGroups }
Assert 'the gateway''s entitlement-groups wins over the decision record' ($CapturedResult.Groups.Standard.Source -eq 'gateway entitlement-groups' -and $CapturedResult.Groups.Premium.Source -eq 'gateway entitlement-groups')
$global:GroupDirectory['claude-code-standard'] = $global:GroupDirectory['team-std']
Get-Facts @{ Record = $null }
Assert 'without a record the default group names are tried' ($CapturedResult.Groups.Standard.Source -eq 'default name' -and $CapturedResult.Groups.Standard.Id -eq $standardId) ($CapturedResult.Groups | ConvertTo-Json -Depth 4 -Compress)
$global:GroupDirectory.Remove('claude-code-standard')
Get-Facts @{ Record = $null }
Assert 'a standard group that cannot be found blocks the plan and names -StandardGroup' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match '-StandardGroup') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -Prefix 'recorded-prefix') }
Assert 'a recorded entitlement-projection-prefix wins' ($CapturedResult.NamePrefix -eq 'recorded-prefix' -and $CapturedResult.PrefixSource -match 'entitlement-projection-prefix')
Get-Facts @{ Discovery = (New-Discovery -ApimName 'APIM_Contoso') }
Assert 'a gateway name that gives no valid prefix blocks the plan and names -NamePrefix' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match '-NamePrefix') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -ApimName 'APIM_Contoso'); NamePrefix = 'contoso2' }
Assert '-NamePrefix fills a prefix the gateway cannot give' (-not $CapturedResult.Blocked -and $CapturedResult.NamePrefix -eq 'contoso2' -and $CapturedResult.PrefixSource -eq 'parameter')
Get-Facts @{ Discovery = (New-Discovery -Sku 'Developer') }
Assert 'a classic tier blocks the plan: the projection supports the v2 tiers' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'v2') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ ResolverInboundAccess = 'private' }
Assert 'a private resolver on Basic v2 blocks the plan' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'Basic v2') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery @{ 'entitlement-source' = 'projection' }) }
Assert 'a gateway already on the projection needs no move' (-not $CapturedResult.Needed -and $CapturedResult.Reason -match 'already')
Get-Facts @{ KeepNamedValues = $true }
Assert '-KeepNamedValues keeps named values' (-not $CapturedResult.Needed -and $CapturedResult.Reason -match 'KeepNamedValues')

Write-Host 'P100 readiness: the projection preflight and the readiness checks'
$global:SeamCalls.Clear()
Get-Facts
$calls = $global:SeamCalls -join "`n"
Assert 'the preflight runs with the derived prefix, groups and access' ($calls -match 'preflight .*NamePrefix=contoso' -and $calls -match "StandardGroup=$standardId" -and $calls -match 'ResolverInboundAccess=public') $calls
Assert 'the readiness checks run for the gateway''s region and prefix' ($calls -match 'readiness .*Location=eastus2' -and $calls -match 'readiness .*NamePrefix=contoso') $calls
$global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'FAIL'; Evidence = '100 of 100 used'; Remedy = 'Request a quota increase.' })
Get-Facts
Assert 'a FAIL from the readiness checks blocks the plan' ($CapturedResult.Blocked -and @($CapturedResult.Checks | Where-Object Result -eq 'FAIL').Count -eq 1)
$global:ReadinessChecks = @([pscustomobject]@{ Name = 'Entra app registration'; Result = 'WARN'; Evidence = 'cannot confirm'; Remedy = 'Pass -ResolverAppId.' })
Get-Facts
Assert 'a WARN does not block' (-not $CapturedResult.Blocked)
$global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'PASS'; Evidence = '0 of 100 used'; Remedy = '' })
$global:PreflightChecks = @([pscustomobject]@{ Check = 'Resource-group RBAC'; Result = 'FAIL'; Evidence = 'Owner not proven'; Remedy = 'Grant Owner.' })
Get-Facts
Assert 'a FAIL from the projection preflight blocks the plan' ($CapturedResult.Blocked -and @($CapturedResult.Checks | Where-Object { $_.Name -eq 'Resource-group RBAC' -and $_.Result -eq 'FAIL' }).Count -eq 1)
$global:PreflightChecks = @([pscustomobject]@{ Check = 'Graph probe 1'; Result = 'PASS'; Evidence = "Graph reached at $([DateTimeOffset]::UtcNow.ToString('o'))"; Remedy = 'None' })
Get-Facts @{ Discovery = (New-Discovery @{ 'allow-standard' = ',' + ((1..45000 | ForEach-Object { '{0:x8}-0000-4000-8000-000000000000' -f $_ }) -join ',') + ',' }) }
Assert 'a directory too large for the runner''s transfer blocks the plan and names the sync job' ($CapturedResult.Blocked -and @($CapturedResult.Checks | Where-Object { $_.Name -match 'transfer' -and $_.Result -eq 'FAIL' -and $_.Remedy -match 'Deploy-ClaudeProjectionRenewal' }).Count -eq 1) (($CapturedResult.Checks | ForEach-Object { "$($_.Name)=$($_.Result)" }) -join '; ')

Write-Host 'P100 the plan of migration 0004'
. (Join-Path $root 'scripts\flow\migrations\0004-entitlement-projection.ps1')
function Get-Plan($Discovery) { Capture { Get-ClaudeFlowMigrationPlan -Record $record -Discovery $Discovery } }
$global:AzCalls = 0
function az { $global:AzCalls++; throw "unexpected az call: $($args -join ' ')" }
Get-Plan ([pscustomobject]@{ policyHash = ''; namedValues = @() })
Assert 'a discovery file without migration facts plans nothing and calls nothing' (-not $CapturedError -and (Test-ClaudeFlowPlanIsNoop $CapturedResult) -and $CapturedResult.Summary -match 'not assessed' -and $global:AzCalls -eq 0) "$CapturedError $($CapturedResult.Summary)"
Get-Facts
$facts = $CapturedResult
$discovery = New-Discovery
$discovery | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $facts
Get-Plan $discovery
$plan = $CapturedResult
$review = if ($plan) { Format-ClaudeFlowReview -Plans @($plan) } else { '' }
Assert 'the move is planned' (-not $CapturedError -and -not (Test-ClaudeFlowPlanIsNoop $plan) -and $plan.Step -eq '0004-entitlement-projection') $CapturedError
Assert 'the plan creates each resource of the inventory' (@($plan.Actions | Where-Object { $_.Verb -eq 'Create' -and $_.Target -match 'cosmos-contoso' }).Count -eq 1)
Assert 'the plan names the one switch write and the recorded groups' (@($plan.Actions | Where-Object { $_.Target -match 'entitlement-source' -and $_.Detail -match 'projection' }).Count -eq 1 -and @($plan.Actions | Where-Object { $_.Target -match 'entitlement-groups' }).Count -eq 1)
Assert 'the review shows the groups with their source and drift' ($review -match 'team-std' -and $review -match 'decision record' -and $review -match '1 would gain access') $review
Assert 'the review shows resources, network, identities, cost and time' ($review -match 'resource cosmos-contoso' -and $review -match 'network vnet-contoso' -and $review -match '57\.48' -and $review -match 'minutes') $review
Assert 'the review lists each readiness check' ($review -match 'Container groups in eastus2: PASS') $review
Assert 'the rollback names the restore command' ($plan.Rollback -match 'Restore-ClaudeGateway\.ps1')
$again = New-Discovery
$global:PreflightChecks = @([pscustomobject]@{ Check = 'Graph probe 1'; Result = 'PASS'; Evidence = "Graph reached at $([DateTimeOffset]::UtcNow.AddMinutes(5).ToString('o'))"; Remedy = 'None' })
Get-Facts
$again | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $CapturedResult
Get-Plan $again
Assert 'evidence that changes between runs does not change the fingerprint' ((Get-ClaudeFlowFingerprint -Plans @($plan)) -eq (Get-ClaudeFlowFingerprint -Plans @($CapturedResult)))
$global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'FAIL'; Evidence = '100 of 100 used'; Remedy = 'Request a quota increase.' })
Get-Facts
$blocked = New-Discovery
$blocked | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $CapturedResult
Get-Plan $blocked
Assert 'a blocked plan says so with each FAIL and its remedy' ($CapturedResult.Data.Blocked -and ((Format-ClaudeFlowReview -Plans @($CapturedResult)) -match 'BLOCKED' -and (Format-ClaudeFlowReview -Plans @($CapturedResult)) -match 'Request a quota increase'))
$global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'PASS'; Evidence = '0 of 100 used'; Remedy = '' })
Get-Facts @{ Discovery = (New-Discovery @{ 'entitlement-source' = 'projection' }) }
$onProjection = New-Discovery @{ 'entitlement-source' = 'projection' }
$onProjection | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $CapturedResult
Get-Plan $onProjection
Assert 'a gateway on the projection plans no change' ((Test-ClaudeFlowPlanIsNoop $CapturedResult) -and $CapturedResult.Summary -match 'already')

Write-Host 'P100 the apply: refresh, deploy and switch, record the groups'
$global:ApplyCalls = [Collections.Generic.List[string]]::new()
$applySeams = @{
    EntitlementSync = { param($p) $global:ApplyCalls.Add("sync Store=$($p.EntitlementStore) Live=$($p.LiveEntitlementSource) Std=$($p.StandardGroup)"); [pscustomobject]@{ CompareBaseline = 'Auto'; ServingStore = 'named-value'; Reason = 'refreshed' } }
    ProjectionDeployment = { param($p) $global:ApplyCalls.Add("deploy Prefix=$($p.NamePrefix) Sku=$($p.Sku) Access=$($p.ResolverInboundAccess) Baseline=$($p.CompareBaseline) Std=$($p.StandardGroup) Prem=$($p.PremiumGroup)"); $true }
    SetNamedValue = { param($Id, $Value) $global:ApplyCalls.Add("set $Id=$Value") }
}
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root -ResumeCommand '.\Update-ClaudeGateway.ps1 -ResourceGroup rg-contoso -ApimName apim-contoso' @applySeams }
$applied = $global:ApplyCalls -join "`n"
Assert 'the apply refreshes the named values, then deploys and switches, then records the groups' (-not $CapturedError -and $applied -match '(?s)^sync .*\ndeploy .*\nset entitlement-groups=') "$CapturedError | $applied"
Assert 'the refresh and deployment get the found groups, prefix, SKU and access' ($applied -match "sync Store=projection Live=named-value Std=$standardId" -and $applied -match "deploy Prefix=contoso Sku=BasicV2 Access=public Baseline=Auto Std=$standardId Prem=$premiumId") $applied
Assert 'entitlement-groups holds only object ids, in a form cmd.exe passes unchanged' ($applied -match "set entitlement-groups=standard=$standardId,premium=$premiumId$" -and $applied -notmatch 'set entitlement-groups=.*["''&|<>^() ]') $applied
$global:ApplyCalls.Clear()
$failing = $applySeams.Clone()
$failing.ProjectionDeployment = { param($p) $global:ApplyCalls.Add('deploy'); throw 'Projection deployment failed; named values keep serving and nothing was switched.' }
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root -ResumeCommand '.\Update-ClaudeGateway.ps1 -ResourceGroup rg-contoso -ApimName apim-contoso' @failing }
Assert 'a failed deployment writes no groups and names the command that resumes' ($CapturedError -match 'named values keep serving' -and $CapturedError -match 'Update-ClaudeGateway\.ps1 -ResourceGroup rg-contoso' -and ($global:ApplyCalls -join ' ') -notmatch 'entitlement-groups') $CapturedError
$global:ApplyCalls.Clear()
$blockedFacts = $facts.PSObject.Copy(); $blockedFacts.Blocked = $true
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $blockedFacts -Root $root -ResumeCommand 'x' @applySeams }
Assert 'blocked facts are refused before any write' ($CapturedError -match 'blocked' -and $global:ApplyCalls.Count -eq 0) $CapturedError
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery @{ 'entitlement-source' = 'projection'; 'entitlement-projection-prefix' = 'contoso' }) }
Assert 'the migration verifies entitlement-source projection and the recorded prefix' ($CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery) }
Assert 'a gateway still on named values does not verify after the move' (-not $CapturedResult.Passed)
Remove-Item Function:\az

Write-Host 'P100 the projection preflight returns its checks to the plan'
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\ClaudeGraphMembership.ps1')
. (Join-Path $root 'scripts\ClaudeRunner.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
$preflightParams = @{ ResourceGroup = 'rg-p84'; ApimName = 'apim-p84'; NamePrefix = 'p84fixture'; Sku = 'BasicV2'; ResolverInboundAccess = 'public'; SubscriptionId = '00000000-0000-4000-8000-000000000084'; StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium' }
Reset-ProjectionFixture 'signed-out'
Capture { Invoke-ClaudeProjectionPreflight @preflightParams -PassThru }
Assert 'with -PassThru a failed preflight returns its checks instead of throwing' (-not $CapturedError -and @($CapturedResult.Checks | Where-Object Result -eq 'FAIL').Count -ge 1) $CapturedError
Reset-ProjectionFixture 'signed-out'
Capture { Invoke-ClaudeProjectionPreflight @preflightParams }
Assert 'without -PassThru a failed preflight still throws' ($CapturedError -match 'Projection preflight failed') $CapturedError
Reset-ProjectionFixture
Capture { Invoke-ClaudeProjectionPreflight @preflightParams -PassThru }
Assert 'with -PassThru a healthy preflight returns its checks and context' (-not $CapturedError -and @($CapturedResult.Checks).Count -ge 10 -and @($CapturedResult.Checks | Where-Object Result -eq 'FAIL').Count -eq 0 -and $CapturedResult.Context) $CapturedError

Write-Host "P100_MIGRATION assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
