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
$leaver = 'b0000000-0000-4000-8000-000000000009'
Get-Facts @{ Discovery = (New-Discovery @{ 'allow-standard' = ",$($oid[0]),$($oid[1]),$leaver," }) }
Assert 'a listed developer who left the group counts as losing access at the move' ($CapturedResult.Groups.Standard.Lost -eq 1 -and $CapturedResult.Groups.Standard.Gained -eq 0) ($CapturedResult.Groups.Standard | ConvertTo-Json -Compress)
Assert 'developers are the distinct Entra members of both tier groups, the population the move deploys; the named-value lists are counted apart' ($f.Developers -eq 4 -and $f.ListedDevelopers -eq 3) "$($f.Developers) / $($f.ListedDevelopers)"
Assert 'business units come from bu-registry, with their ids in code-point order' ($f.BusinessUnits -eq 2 -and (@($f.BusinessUnitIds) -join ',') -ceq 'eng,ops') "$($f.BusinessUnits) / $(@($f.BusinessUnitIds) -join ',')"
$swapped = New-Discovery @{ 'bu-registry' = 'fin=grp-fin,hr=grp-hr' }
Get-Facts @{ Discovery = $swapped }
$swappedFacts = $CapturedResult
Get-Facts @{ Discovery = (New-Discovery @{ 'bu-parents' = 'ops=eng' }) }
Assert 'a business-unit registry or hierarchy of the same size but other content changes the facts the fingerprint covers' ((@($swappedFacts.BusinessUnitIds) -join ',') -ceq 'fin,hr' -and $CapturedResult.BusinessUnitParentsSha256 -match '^[0-9a-f]{64}$' -and $CapturedResult.BusinessUnitParentsSha256 -ne $f.BusinessUnitParentsSha256) "$(@($swappedFacts.BusinessUnitIds) -join ',') / $($CapturedResult.BusinessUnitParentsSha256) / $($f.BusinessUnitParentsSha256)"
Get-Facts @{ Discovery = (New-Discovery @{ 'bu-registry' = 'eng=grp-other,ops=grp-ops' }) }
Assert 'a unit that keeps its ID but maps to another group changes the facts the fingerprint covers' ($f.BusinessUnitRegistrySha256 -match '^[0-9a-f]{64}$' -and $CapturedResult.BusinessUnitRegistrySha256 -match '^[0-9a-f]{64}$' -and $CapturedResult.BusinessUnitRegistrySha256 -ne $f.BusinessUnitRegistrySha256 -and (@($CapturedResult.BusinessUnitIds) -join ',') -ceq 'eng,ops') "$($f.BusinessUnitRegistrySha256) / $($CapturedResult.BusinessUnitRegistrySha256)"
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
$underscoreRecord = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'APIM_Contoso'; standardGroup = 'team-std'; premiumGroup = 'team-prem' }
Get-Facts @{ Discovery = (New-Discovery -ApimName 'APIM_Contoso'); Record = $underscoreRecord }
Assert 'a gateway name that gives no valid prefix blocks the plan and names -NamePrefix' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match '-NamePrefix') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -ApimName 'APIM_Contoso'); Record = $underscoreRecord; NamePrefix = 'contoso2' }
Assert '-NamePrefix fills a prefix the gateway cannot give' (-not $CapturedResult.Blocked -and $CapturedResult.NamePrefix -eq 'contoso2' -and $CapturedResult.PrefixSource -eq 'parameter') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -Prefix 'Bad_Prefix'); NamePrefix = 'contoso3' }
Assert 'a recorded prefix that is not valid gives way to -NamePrefix' (-not $CapturedResult.Blocked -and $CapturedResult.NamePrefix -eq 'contoso3' -and $CapturedResult.PrefixSource -eq 'parameter') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -Prefix 'Bad_Prefix') }
Assert 'a recorded prefix that is not valid, without -NamePrefix, blocks the plan and names both' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'Bad_Prefix' -and (@($CapturedResult.Problems) -join ' ') -match '-NamePrefix') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -Prefix 'recorded-prefix'); NamePrefix = 'other-prefix' }
Assert 'a -NamePrefix that differs from the recorded prefix blocks the plan, which names both' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'recorded-prefix' -and (@($CapturedResult.Problems) -join ' ') -match 'other-prefix') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery -Prefix 'recorded-prefix'); NamePrefix = 'recorded-prefix' }
Assert 'a -NamePrefix equal to the recorded prefix is accepted' (-not $CapturedResult.Blocked -and $CapturedResult.NamePrefix -eq 'recorded-prefix') (@($CapturedResult.Problems) -join '; ')
$otherRecord = [pscustomobject]@{ resourceGroup = 'rg-other'; apimName = 'apim-other'; standardGroup = 'team-std'; premiumGroup = 'team-prem' }
Get-Facts @{ Record = $otherRecord }
Assert 'a decision record of another gateway is not a source of tier groups, and the plan says so' ($CapturedResult.Groups.Standard.Source -ne 'decision record' -and $CapturedResult.Blocked -and $CapturedResult.RecordNote -match 'rg-other' -and $CapturedResult.RecordNote -match 'apim-other') "$($CapturedResult.Groups.Standard.Source) | $($CapturedResult.RecordNote)"
$neighbourRecord = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-other'; standardGroup = 'team-std'; premiumGroup = 'team-prem' }
Get-Facts @{ Record = $neighbourRecord }
Assert 'a decision record of another gateway in the same resource group is not a source of tier groups either' ($CapturedResult.Groups.Standard.Source -ne 'decision record' -and $CapturedResult.RecordNote -match 'rg-contoso/apim-other') "$($CapturedResult.Groups.Standard.Source) | $($CapturedResult.RecordNote)"
$otherSubscriptionRecord = [pscustomobject]@{ subscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; standardGroup = 'team-std'; premiumGroup = 'team-prem' }
Get-Facts @{ Record = $otherSubscriptionRecord }
Assert 'a decision record of a gateway with the same names in another subscription is not a source of tier groups' ($CapturedResult.Groups.Standard.Source -ne 'decision record' -and -not $CapturedResult.RecordFits -and $CapturedResult.RecordNote -match 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') "$($CapturedResult.Groups.Standard.Source) | $($CapturedResult.RecordNote)"
Get-Facts @{ Record = ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; standardGroup = 'team-std'; premiumGroup = 'claude-code-premium' }); Discovery = (New-Discovery @{ 'allow-premium' = '' }) }
Assert 'a record that names the default premium group, which the tenant does not have, plans no premium tier when allow-premium is empty, as before' (-not $CapturedResult.Blocked -and $CapturedResult.Groups.Premium.Absent) (@($CapturedResult.Problems) -join '; ')
$sameRecordOtherCase = [pscustomobject]@{ resourceGroup = 'RG-Contoso'; apimName = 'APIM-contoso'; standardGroup = 'team-std'; premiumGroup = 'team-prem' }
Get-Facts @{ Record = $sameRecordOtherCase }
Assert 'Azure names compare without case, so the gateway''s own record still counts' ($CapturedResult.Groups.Standard.Source -eq 'decision record' -and -not $CapturedResult.RecordNote) "$($CapturedResult.Groups.Standard.Source) | $($CapturedResult.RecordNote)"
Get-Facts @{ Discovery = (New-Discovery -Sku 'Developer') }
Assert 'a classic tier blocks the plan: the projection supports the v2 tiers' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'v2') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ ResolverInboundAccess = 'private' }
Assert 'a private resolver on Basic v2 blocks the plan' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'Basic v2') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery @{ 'entitlement-source' = 'projection' }) }
Assert 'a gateway already on the projection needs no move' (-not $CapturedResult.Needed -and $CapturedResult.Reason -match 'already')
Get-Facts @{ KeepNamedValues = $true }
Assert '-KeepNamedValues keeps named values' (-not $CapturedResult.Needed -and $CapturedResult.Reason -match 'KeepNamedValues')
Get-Facts @{ PowerShellMajor = 5 }
Assert 'on Windows PowerShell 5.1 no move is planned, so the other migrations still apply, and the reason names pwsh' (-not $CapturedResult.Needed -and -not $CapturedResult.Blocked -and $CapturedResult.Reason -match 'pwsh') "$($CapturedResult.Reason)"
$global:GroupDirectory['claude-code-premium'] = @{ Id = '33333333-3333-4333-8333-333333333333'; Name = 'claude-code-premium'; Members = @($oid[3]) }
Get-Facts @{ PremiumGroup = 'team-prm' }
Assert 'a -PremiumGroup that Graph cannot find blocks the plan and names it, rather than falling back to the default name' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'team-prm' -and -not $CapturedResult.Groups.Premium.Found) (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ StandardGroup = 'team-stdx' }
Assert 'a -StandardGroup that Graph cannot find blocks the plan and names it' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'team-stdx') (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Discovery = (New-Discovery @{ 'entitlement-groups' = "standard=$standardId,premium=66666666-6666-4666-8666-666666666666" }) }
Assert 'a premium group that entitlement-groups records but Graph no longer finds blocks the plan, rather than falling back' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match '66666666-6666-4666-8666-666666666666') (@($CapturedResult.Problems) -join '; ')
$global:GroupDirectory['claude-code-standard'] = @{ Id = '77777777-7777-4777-8777-777777777777'; Name = 'claude-code-standard'; Members = @($oid[0]) }
$global:GroupDirectory['claude-code-premium'] = @{ Id = '33333333-3333-4333-8333-333333333333'; Name = 'claude-code-premium'; Members = @($oid[3]) }
Get-Facts @{ Record = ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; standardGroup = 'team-deleted'; premiumGroup = 'team-prem' }) }
Assert 'a standard group the decision record names but Graph no longer finds blocks the plan, rather than falling back to the default name' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'team-deleted' -and -not $CapturedResult.Groups.Standard.Found) (@($CapturedResult.Problems) -join '; ')
Get-Facts @{ Record = ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; standardGroup = 'team-std'; premiumGroup = 'team-prem-deleted' }) }
Assert 'a premium group the decision record names but Graph no longer finds blocks the plan, rather than falling back to the default name' ($CapturedResult.Blocked -and (@($CapturedResult.Problems) -join ' ') -match 'team-prem-deleted' -and -not $CapturedResult.Groups.Premium.Found) (@($CapturedResult.Problems) -join '; ')
$global:GroupDirectory.Remove('claude-code-standard'); $global:GroupDirectory.Remove('claude-code-premium')
$global:GroupDirectory.Remove('claude-code-premium')

Write-Host 'P100 readiness: the projection preflight and the readiness checks'
$global:SeamCalls.Clear()
Get-Facts
$calls = $global:SeamCalls -join "`n"
Assert 'the preflight runs with the derived prefix, groups and access' ($calls -match 'preflight .*NamePrefix=contoso' -and $calls -match "StandardGroup=$standardId" -and $calls -match 'ResolverInboundAccess=public') $calls
Assert 'the readiness checks run for the gateway''s region and prefix' ($calls -match 'readiness .*Location=eastus2' -and $calls -match 'readiness .*NamePrefix=contoso') $calls
$global:SeamCalls.Clear()
$global:GroupDirectory['claude-code-premium'] = @{ Id = '33333333-3333-4333-8333-333333333333'; Name = 'claude-code-premium'; Members = @($oid[3]) }
Get-Facts @{ PremiumGroup = 'none' }
$noPremiumFacts = $CapturedResult
Assert 'with -PremiumGroup none the preflight is told none, even when a group has the default premium name' (($global:SeamCalls -join ' ') -match 'preflight .*PremiumGroup=none ' -and $noPremiumFacts.Groups.Premium.Absent) ($global:SeamCalls -join ' | ')
$global:GroupDirectory.Remove('claude-code-premium')
$global:ResolverApp = '44444444-4444-4444-8444-444444444444'
Get-Facts @{ Preflight = { param($Parameters) [pscustomobject]@{ Checks = $global:PreflightChecks; Context = @{ ResolverAppId = $global:ResolverApp } } } }
$pinnedFacts = $CapturedResult
Assert 'the resolver app the preflight found is part of the facts the fingerprint covers' ($pinnedFacts.ResolverAppId -eq $global:ResolverApp -and -not $pinnedFacts.Blocked) "$($pinnedFacts.ResolverAppId) | $CapturedError"
$global:SeamCalls.Clear()
$displayRegion = New-Discovery; $displayRegion.location = 'East US 2'
$global:CostRegions = [Collections.Generic.List[string]]::new()
Get-Facts @{ Discovery = $displayRegion; Cost = { param($Developers, $Region) $global:CostRegions.Add([string]$Region); [pscustomobject]@{ MonthlyUsd = [decimal]57.48; UnknownReason = '' } } }
Assert 'a region that az apim show gives as a display name is used as its ARM name, as the installer does' ($CapturedResult.Location -eq 'eastus2' -and @($global:CostRegions) -contains 'eastus2' -and ($global:SeamCalls -join ' ') -match 'preflight .*Location=eastus2') "$($CapturedResult.Location) / $(@($global:CostRegions) -join ',') / $($global:SeamCalls -join ' | ')"
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
# The refresh and the snapshot carry the Entra members, not the named-value lists: the transfer estimate gets a tier
# group's members (45,000 here) even when the named-value lists hold a few developers.
$global:GroupDirectory['team-std'] = @{ Id = $standardId; Name = 'team-std'; Members = @(1..45000 | ForEach-Object { '{0:x8}-0000-4000-8000-000000000000' -f $_ }) }
$global:TransferAskedFor = $null
Get-Facts @{ TransferMinutes = { param($Developers) $global:TransferAskedFor = $Developers; 200 } }
Assert 'a tier group too large for the runner''s transfer blocks the plan and names the sync job, even when the named-value lists are small' ($CapturedResult.Blocked -and @($CapturedResult.Checks | Where-Object { $_.Name -match 'transfer' -and $_.Result -eq 'FAIL' -and $_.Remedy -match 'Deploy-ClaudeProjectionRenewal' }).Count -eq 1 -and $CapturedResult.ListedDevelopers -eq 3 -and $global:TransferAskedFor -ge 45000) "asked for $global:TransferAskedFor; $(($CapturedResult.Checks | ForEach-Object { "$($_.Name)=$($_.Result)" }) -join '; ')"
Get-Facts
Assert 'a tier group of 45,000 developers fits the runner''s compressed parallel transfer and does not block the plan' (-not $CapturedResult.Blocked -and @($CapturedResult.Checks | Where-Object { $_.Name -match 'transfer' }).Count -eq 0) (($CapturedResult.Checks | ForEach-Object { "$($_.Name)=$($_.Result)" }) -join '; ')
$global:GroupDirectory['team-std'] = @{ Id = $standardId; Name = 'team-std'; Members = @($oid[0], $oid[1]) }
# P99 measured 41 minutes for a 500,000-record snapshot on 2026-10-06 (ADR-0053); the plan's estimate uses the
# runner's own transfer model.
$estimate500k = Get-ClaudeMigrationTransferMinutes -Developers 500000
Assert 'the plan estimates the transfer as the runner sends it: 500,000 developers take 30 to 45 minutes' ($estimate500k -ge 30 -and $estimate500k -le 45) "$estimate500k minutes"
Assert 'the 110-minute transfer limit falls between 1,000,000 and 2,000,000 developers' ((Get-ClaudeMigrationTransferMinutes -Developers 1000000) -le 110 -and (Get-ClaudeMigrationTransferMinutes -Developers 2000000) -gt 110) "$(Get-ClaudeMigrationTransferMinutes -Developers 1000000) / $(Get-ClaudeMigrationTransferMinutes -Developers 2000000) minutes"

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
$writeOrder = @($plan.Actions | ForEach-Object { [string]$_.Target })
$indexOf = { param($Pattern) for ($i = 0; $i -lt $writeOrder.Count; $i++) { if ($writeOrder[$i] -match $Pattern) { return $i } }; return -1 }
Assert 'the plan lists the writes in the order the apply makes them: the groups, the refresh, the resources, then the switch last' ((& $indexOf 'entitlement-groups') -eq 0 -and (& $indexOf 'named-value refresh') -eq 1 -and (& $indexOf 'cosmos-contoso') -gt 1 -and (& $indexOf 'entitlement-source') -eq ($writeOrder.Count - 1)) ($writeOrder -join ' | ')
Assert 'the review shows the groups with their source and drift' ($review -match 'team-std' -and $review -match 'decision record' -and $review -match '1 would gain access') $review
Assert 'the review shows resources, network, identities, cost and time' ($review -match 'resource cosmos-contoso' -and $review -match 'network vnet-contoso' -and $review -match '57\.48' -and $review -match 'minutes') $review
Assert 'the review lists each readiness check' ($review -match 'Container groups in eastus2: PASS') $review
Assert 'the rollback names the restore command with its folder, as run from the repository root' ($plan.Rollback -match '\.\\scripts\\Restore-ClaudeGateway\.ps1 -Path') $plan.Rollback
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
$noMovePlan = $CapturedResult
Get-Facts @{ PremiumGroup = 'none' }
$nonePlanDiscovery = New-Discovery
$nonePlanDiscovery | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $CapturedResult
Get-Plan $nonePlanDiscovery
$noneReview = if ($CapturedResult) { Format-ClaudeFlowReview -Plans @($CapturedResult) } else { '' }
Assert 'with no premium group the plan says how many listed developers leave the premium tier' ($noneReview -match 'Premium tier group: no group \(parameter\); 1 developer\(s\) in allow-premium leave the premium tier') $noneReview
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery) -Plan $noMovePlan }
Assert 'a plan with no move verifies without reading the store (-KeepNamedValues leaves named values)' ($CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
Capture { New-ClaudeEntitlementMigrationFailure -Discovery (New-Discovery) -Message 'Graph returned 403 for the group lookup.' }
$failed = New-Discovery
$failed | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $CapturedResult
Get-Plan $failed
$failedReview = if ($CapturedResult) { Format-ClaudeFlowReview -Plans @($CapturedResult) } else { '' }
Assert 'facts that cannot be read block the plan and say why' (-not $CapturedError -and $CapturedResult.Data.Blocked -and $failedReview -match 'could not be assessed: Graph returned 403 for the group lookup\.') "$CapturedError $failedReview"
Capture { New-ClaudeEntitlementMigrationFailure -Discovery (New-Discovery @{ 'entitlement-source' = 'projection' }) -Message 'Graph returned 403.' }
Assert 'facts that cannot be read on a gateway already on the projection plan no move' (-not $CapturedResult.Needed -and -not $CapturedResult.Blocked)
$global:GroupDirectory['team-std'] = @{ Id = $standardId; Name = 'team-std'; Members = @($oid[0], $oid[1], $oid[2]) }
Get-Facts
Assert 'a member of both groups counts as premium only, as Sync-ClaudeAccess writes the lists' ($CapturedResult.Groups.Standard.Members -eq 2 -and $CapturedResult.Groups.Standard.Gained -eq 0) ($CapturedResult.Groups.Standard | ConvertTo-Json -Compress)
$global:GroupDirectory['team-std'] = @{ Id = $standardId; Name = 'team-std'; Members = @($oid[0], $oid[1]) }

Write-Host 'P100 the apply: record the groups, refresh, deploy and switch'
$global:ApplyCalls = [Collections.Generic.List[string]]::new()
$applySeams = @{
    EntitlementSync = { param($p) $global:ApplyCalls.Add("sync Store=$($p.EntitlementStore) Live=$($p.LiveEntitlementSource) Std=$($p.StandardGroup) Prem=$($p.PremiumGroup) EmptyStandard=$([bool]$p.AllowEmptyStandard) EmptyPremium=$([bool]$p.AllowEmptyPremium)"); [pscustomobject]@{ CompareBaseline = 'Auto'; ServingStore = 'named-value'; Reason = 'refreshed' } }
    ProjectionDeployment = { param($p) $global:ApplyCalls.Add("deploy Prefix=$($p.NamePrefix) Sku=$($p.Sku) Access=$($p.ResolverInboundAccess) Baseline=$($p.CompareBaseline) Std=$($p.StandardGroup) Prem=$($p.PremiumGroup) App=$($p.ProjectionResolverAppId)"); $true }
    SetNamedValue = { param($Id, $Value) $global:ApplyCalls.Add("set $Id=$Value") }
}
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root -ResumeCommand '.\Update-ClaudeGateway.ps1 -ResourceGroup rg-contoso -ApimName apim-contoso' @applySeams }
$applied = $global:ApplyCalls -join "`n"
# The groups are recorded first: a later step that fails leaves them on the gateway for the resume, and a switch
# can never happen without them.
Assert 'the apply records the groups, then refreshes the named values, then deploys and switches' (-not $CapturedError -and $applied -match '(?s)^set entitlement-groups=[^\n]*\nsync [^\n]*\ndeploy [^\n]*$') "$CapturedError | $applied"
Assert 'the refresh and deployment get the found groups, prefix, SKU and access' ($applied -match "sync Store=projection Live=named-value Std=$standardId" -and $applied -match "deploy Prefix=contoso Sku=BasicV2 Access=public Baseline=Auto Std=$standardId Prem=$premiumId") $applied
Assert 'entitlement-groups holds only object ids, in a form cmd.exe passes unchanged' ($applied -match "(?m)^set entitlement-groups=standard=$standardId,premium=$premiumId$" -and $applied -notmatch 'set entitlement-groups=.*["''&|<>^() ]') $applied
$global:ApplyCalls.Clear()
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $noPremiumFacts -Root $root @applySeams }
$appliedNone = $global:ApplyCalls -join "`n"
Assert 'with no premium group the refresh, the deployment and the record all say none, never the default premium name' (-not $CapturedError -and $appliedNone -match '(?m)^sync .* Prem=none EmptyStandard=False EmptyPremium=True$' -and $appliedNone -match '(?m)^deploy .* Prem=none App=$' -and $appliedNone -match '(?m)^set entitlement-groups=standard=[0-9a-f-]+,premium=none$' -and $appliedNone -notmatch 'claude-code-premium') "$CapturedError | $appliedNone"
Assert 'with a premium group the refresh keeps its guard against emptying allow-premium' ($applied -match '(?m)^sync .* EmptyPremium=False$') $applied
$global:GroupDirectory['team-std'] = @{ Id = $standardId; Name = 'team-std'; Members = @() }
Get-Facts
$emptyStandardFacts = $CapturedResult
$global:GroupDirectory['team-std'] = @{ Id = $standardId; Name = 'team-std'; Members = @($oid[0], $oid[1]) }
$global:ApplyCalls.Clear()
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $emptyStandardFacts -Root $root @applySeams }
Assert 'a tier group with no members, whose listed developers the plan counts as leaving, lets the refresh empty that list' (-not $CapturedError -and $emptyStandardFacts.Groups.Standard.Lost -eq 2 -and ($global:ApplyCalls -join "`n") -match '(?m)^sync .* EmptyStandard=True EmptyPremium=False$') "$CapturedError | $($global:ApplyCalls -join ' ; ')"
. (Join-Path $root 'scripts\ClaudeInstallProjection.ps1')
$global:SyncArguments = $null
Capture { Invoke-ClaudeInstallerEntitlementSync -Root $root -ResourceGroup rg-contoso -ApimName apim-contoso -StandardGroup $standardId -PremiumGroup none -EntitlementStore projection -LiveEntitlementSource named-value -AllowEmptyPremium -InvokeScript { param($Path, $Parameters) $global:SyncArguments = $Parameters; 0 } }
Assert 'the installer''s refresh passes -AllowEmptyPremium and none to Sync-ClaudeAccess when the update asks for it' (-not $CapturedError -and $global:SyncArguments -and $global:SyncArguments['AllowEmptyPremium'] -eq $true -and $global:SyncArguments['PremiumGroup'] -eq 'none') "$CapturedError $($global:SyncArguments | ConvertTo-Json -Compress)"
$global:SyncArguments = $null
Capture { Invoke-ClaudeInstallerEntitlementSync -Root $root -ResourceGroup rg-contoso -ApimName apim-contoso -StandardGroup $standardId -PremiumGroup $premiumId -EntitlementStore projection -LiveEntitlementSource named-value -InvokeScript { param($Path, $Parameters) $global:SyncArguments = $Parameters; 0 } }
Assert 'without it the installer''s refresh keeps Sync-ClaudeAccess''s guard' (-not $CapturedError -and $global:SyncArguments -and -not $global:SyncArguments.Contains('AllowEmptyPremium')) "$CapturedError $($global:SyncArguments | ConvertTo-Json -Compress)"
$global:SyncArguments = $null
Capture { Invoke-ClaudeInstallerEntitlementSync -Root $root -ResourceGroup rg-contoso -ApimName apim-contoso -StandardGroup $standardId -PremiumGroup $premiumId -EntitlementStore projection -LiveEntitlementSource named-value -AllowEmptyStandard -InvokeScript { param($Path, $Parameters) $global:SyncArguments = $Parameters; 0 } }
Assert 'the installer''s refresh passes -AllowEmptyStandard to Sync-ClaudeAccess when the update asks for it' (-not $CapturedError -and $global:SyncArguments -and $global:SyncArguments['AllowEmptyStandard'] -eq $true -and -not $global:SyncArguments.Contains('AllowEmptyPremium')) "$CapturedError $($global:SyncArguments | ConvertTo-Json -Compress)"
$global:ApplyCalls.Clear()
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $pinnedFacts -Root $root @applySeams }
Assert 'the deployment uses the resolver app the plan found' (-not $CapturedError -and ($global:ApplyCalls -join "`n") -match "(?m)^deploy .* App=$($global:ResolverApp)$") ($global:ApplyCalls -join ' ; ')
$global:ApplyCalls.Clear()
$groupsFail = $applySeams.Clone()
$groupsFail.SetNamedValue = { param($Id, $Value) $global:ApplyCalls.Add("set $Id"); throw 'az apim nv update failed (exit 1).' }
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root @groupsFail }
Assert 'a failed groups write stops before the refresh, the deployment and the switch, and names the update that resumes' ($CapturedError -match 'nothing was switched' -and $CapturedError -match 'Update-ClaudeGateway\.ps1 -ResourceGroup rg-contoso' -and ($global:ApplyCalls -join ' ; ') -eq 'set entitlement-groups') "$CapturedError | $($global:ApplyCalls -join ' ; ')"
$global:ApplyCalls.Clear()
$failing = $applySeams.Clone()
$failing.ProjectionDeployment = { param($p) $global:ApplyCalls.Add('deploy'); throw 'Projection deployment failed; named values keep serving and nothing was switched.' }
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root -ResumeCommand '.\Update-ClaudeGateway.ps1 -ResourceGroup rg-contoso -ApimName apim-contoso' @failing }
Assert 'a failed deployment, after the groups and the refresh, names the command that resumes' ($CapturedError -match 'named values keep serving' -and $CapturedError -match 'Update-ClaudeGateway\.ps1 -ResourceGroup rg-contoso' -and ($global:ApplyCalls -join ' ; ') -match '^set entitlement-groups=[^;]+ ; sync [^;]+ ; deploy$') "$CapturedError | $($global:ApplyCalls -join ' ; ')"
$global:ApplyCalls.Clear()
# The prefix and access have no home on the gateway before the deployer writes them: a resume that re-resolved
# them could pick a second prefix or another access.
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $facts -Root $root @failing }
$expectedResume = ".\Update-ClaudeGateway.ps1 -ResourceGroup rg-contoso -ApimName apim-contoso -StandardGroup $standardId -PremiumGroup $premiumId -NamePrefix contoso -ResolverInboundAccess public"
Assert 'the resume command carries the resolved groups, prefix and access' ($CapturedError -and $CapturedError.EndsWith($expectedResume)) $CapturedError
$noPremium = $facts.PSObject.Copy(); $noPremium.Groups = [pscustomobject]@{ Standard = $facts.Groups.Standard; Premium = [pscustomobject]@{ Tier = 'premium'; Found = $false; Absent = $true; Id = '' } }
$noPremium.ResourceGroup = "rg (it's prod)"
Capture { Get-ClaudeEntitlementMigrationResumeCommand -Facts $noPremium }
Assert 'a tier without a group resumes as -PremiumGroup none, and other values are quoted for PowerShell' ($CapturedResult -match [regex]::Escape("-ResourceGroup 'rg (it''s prod)' -ApimName apim-contoso") -and $CapturedResult -match '-PremiumGroup none -NamePrefix') "$CapturedResult $CapturedError"
Capture { Get-ClaudeEntitlementMigrationResumeCommand -Facts $facts -RecordPath 'C:\ops\gateway records\contoso.json' }
Assert 'a decision record other than the default is part of the resume command, quoted' ($CapturedResult -and $CapturedResult.StartsWith(".\Update-ClaudeGateway.ps1 -RecordPath 'C:\ops\gateway records\contoso.json' -ResourceGroup rg-contoso")) "$CapturedResult $CapturedError"
# Through migration 0004: the updater records the record path in the plan data, and the apply's resume names it.
$plan.Data.SnapshotPath = Join-Path ([IO.Path]::GetTempPath()) 'p100-unused-snapshot.json'; $plan.Data.SnapshotTaken = $true
$plan.Data.RecordPath = 'C:\ops\gateway records\contoso.json'
Capture { Invoke-ClaudeFlowMigration -Record $record -Plan $plan }
Assert 'a failed apply through migration 0004 names the plan''s decision record in its resume command' ($CapturedError -match [regex]::Escape("Resume with the same update: .\Update-ClaudeGateway.ps1 -RecordPath 'C:\ops\gateway records\contoso.json' -ResourceGroup rg-contoso")) $CapturedError
$plan.Data.Remove('RecordPath'); $plan.Data.SnapshotTaken = $false
$migration0004 = [IO.File]::ReadAllText((Join-Path $root 'scripts\flow\migrations\0004-entitlement-projection.ps1'))
Assert 'migration 0004 leaves the resume command to the apply, which knows the resolved values' ($migration0004 -notmatch 'ResumeCommand')
$global:ApplyCalls.Clear()
$blockedFacts = $facts.PSObject.Copy(); $blockedFacts.Blocked = $true
Capture { Invoke-ClaudeEntitlementMigrationApply -Facts $blockedFacts -Root $root -ResumeCommand 'x' @applySeams }
Assert 'blocked facts are refused before any write' ($CapturedError -match 'blocked' -and $global:ApplyCalls.Count -eq 0) $CapturedError

Write-Host 'P100 one backup per update; the record names the groups the move used'
$sharedPath = Join-Path ([IO.Path]::GetTempPath()) 'p100-shared-snapshot.json'
$shared = @(
    [pscustomobject]@{ Step = 'a'; Data = @{ SnapshotPath = $sharedPath; SnapshotTaken = $true } },
    [pscustomobject]@{ Step = 'b'; Data = @{ SnapshotPath = $sharedPath; SnapshotTaken = $false } },
    [pscustomobject]@{ Step = 'c'; Data = @{ SnapshotPath = 'other.json'; SnapshotTaken = $false } },
    [pscustomobject]@{ Step = 'd'; Data = $null })
Capture { Sync-ClaudeFlowLifecycleSnapshotTaken -Plans $shared }
Assert 'a backup one migration took counts for every migration that shares its path, so a later one does not overwrite it' (-not $CapturedError -and $shared[1].Data.SnapshotTaken -and -not $shared[2].Data.SnapshotTaken) $CapturedError
$updaterSource = [IO.File]::ReadAllText((Join-Path $root 'scripts\Update-ClaudeGateway.ps1'))
Assert 'the updater shares the backup between migrations after each one runs' ($updaterSource -match '(?s)Invoke-ClaudeFlowMigration -Record \$record -Plan \$plan \| Out-Null\s+Sync-ClaudeFlowLifecycleSnapshotTaken -Plans \$plans') ''
$recordCopy = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; standardGroup = 'old-std'; premiumGroup = 'old-prem' }
Capture { Set-ClaudeEntitlementMigrationRecordGroups -Record $recordCopy -Facts $noPremiumFacts }
Assert 'the decision record names the groups the move used, so a later Sync-ClaudeAccess reads them' (-not $CapturedError -and $CapturedResult -eq $true -and $recordCopy.standardGroup -eq $noPremiumFacts.Groups.Standard.Id -and $recordCopy.premiumGroup -eq 'none') "$CapturedError $($recordCopy | ConvertTo-Json -Compress)"
$foreignRecordObject = [pscustomobject]@{ resourceGroup = 'rg-a'; apimName = 'apim-a'; standardGroup = 'team-a-std'; premiumGroup = 'team-a-prem' }
$movedFacts = $noPremiumFacts.PSObject.Copy(); $movedFacts | Add-Member -NotePropertyName RecordFits -NotePropertyValue $false -Force
Capture { Set-ClaudeEntitlementMigrationRecordGroups -Record $foreignRecordObject -Facts $movedFacts }
Assert 'a decision record of another gateway keeps its groups: the move does not write them' (-not $CapturedError -and $CapturedResult -eq $false -and $foreignRecordObject.standardGroup -eq 'team-a-std' -and $foreignRecordObject.premiumGroup -eq 'team-a-prem') "$CapturedError $($foreignRecordObject | ConvertTo-Json -Compress)"
$migration0004Source = [IO.File]::ReadAllText((Join-Path $root 'scripts\flow\migrations\0004-entitlement-projection.ps1'))
Assert 'migration 0004 records the groups and the history row only in a decision record of the moved gateway, after the apply succeeds' ($migration0004Source -match '(?s)Invoke-ClaudeEntitlementMigrationApply [^\r\n]+\r?\n(\s*#[^\r\n]*\r?\n)*\s+if \(Set-ClaudeEntitlementMigrationRecordGroups -Record \$Record -Facts \$facts\) \{[^}]*Add-ClaudeDecisionHistory') ''
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery @{ 'entitlement-source' = 'projection'; 'entitlement-projection-prefix' = 'contoso' }) }
Assert 'the migration verifies entitlement-source projection and the recorded prefix' ($CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery) }
Assert 'a gateway still on named values does not verify after the move' (-not $CapturedResult.Passed)
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery @{ 'entitlement-source' = 'projection' }) }
Assert 'a projection without a recorded prefix does not verify' (-not $CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
$recordedGroups = "standard=$standardId,premium=$premiumId"
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery @{ 'entitlement-source' = 'projection'; 'entitlement-projection-prefix' = 'contoso' }) -Plan $plan }
Assert 'after a move, a gateway without the recorded tier groups does not verify' (-not $CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery @{ 'entitlement-source' = 'projection'; 'entitlement-projection-prefix' = 'other'; 'entitlement-groups' = $recordedGroups }) -Plan $plan }
Assert 'after a move, a prefix other than the planned one does not verify' (-not $CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
Capture { Test-ClaudeFlowMigration -Record $record -Discovery (New-Discovery @{ 'entitlement-source' = 'projection'; 'entitlement-projection-prefix' = 'contoso'; 'entitlement-groups' = $recordedGroups }) -Plan $plan }
Assert 'after a move, the projection, the planned prefix and the recorded tier groups verify' ($CapturedResult.Passed) ($CapturedResult | ConvertTo-Json -Depth 4 -Compress)
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

Write-Host 'P100 the group name none means no group, with no Graph lookup'
# Any user can create a Microsoft 365 group, so a group named "none" may exist; it must never become the premium tier.
$savedGraphRead = ${function:Invoke-ClaudeGraphRead}
$savedRest = Get-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
$global:GraphReads = 0
function Invoke-ClaudeGraphRead { $global:GraphReads++; [pscustomobject]@{ value = @([pscustomobject]@{ id = '55555555-5555-4555-8555-555555555555' }) } }
function Invoke-RestMethod { $global:GraphReads++; throw 'unexpected Graph request' }
try {
    Capture { Get-ClaudeGraphGroup -GroupName 'none' -Token 'offline' }
    $noneGroup = $CapturedResult; $noneGroupError = $CapturedError
    Capture { @(Get-GroupMemberOids -GroupName 'None' -Token 'offline' 3>$null) }
    Assert 'the group name none is no group: no Graph read, even when a group of that name exists' ($null -eq $noneGroup -and -not $noneGroupError -and -not $CapturedError -and @($CapturedResult).Count -eq 0 -and $global:GraphReads -eq 0) "reads=$($global:GraphReads) $noneGroupError $CapturedError"
    $noneWarnings = @(Get-GroupMemberOids -GroupName 'none' -Token 'offline' 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Assert 'no premium group is not reported as a group that was not found' ($noneWarnings.Count -eq 0) (@($noneWarnings | ForEach-Object Message) -join '; ')
}
finally {
    ${function:Invoke-ClaudeGraphRead} = $savedGraphRead
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    if ($savedRest) { Set-Item Function:\Invoke-RestMethod -Value $savedRest.ScriptBlock }
}

Write-Host 'P100 printed commands are one PowerShell statement'
foreach ($value in @("Claude premium$([char]0x2019); Start-Process calc; #", "x$([char]0x2018)y", '-Apply', "rg (it's prod)")) {
    $line = ".\Update-ClaudeGateway.ps1 -PremiumGroup $(ConvertTo-ClaudeFlowCommandArgument $value) -Apply"
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$parseErrors)
    $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
    $parameters = @($commands | ForEach-Object { $_.CommandElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
    Assert "a printed value stays one argument: $value" (-not $parseErrors.Count -and $commands.Count -eq 1 -and ($parameters -join ',') -eq 'PremiumGroup,Apply') "$line | commands=$($commands.Count) parameters=$($parameters -join ',')"
}

Write-Host 'P100 live discovery reads the gateway in the decision record''s subscription'
$global:LiveAzCalls = [Collections.Generic.List[string]]::new()
$savedRestForDiscovery = Get-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
function az {
    $line = $args -join ' '; $global:LiveAzCalls.Add($line); $global:LASTEXITCODE = 0
    if ($line -match '^apim show') { return '{"id":"/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso","location":"eastus2","sku":{"name":"BasicV2","capacity":1}}' }
    if ($line -match '^apim nv list') { return '[]' }
    if ($line -match '^account get-access-token') { return 'offline-token' }
    throw "unexpected az call: $line"
}
function Invoke-RestMethod { [pscustomobject]@{ properties = [pscustomobject]@{ value = '<policies />' } } }
try {
    Capture { Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup rg-contoso -ApimName apim-contoso -SubscriptionId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }
    Assert 'live discovery with a subscription reads the gateway and its named values in that subscription' (-not $CapturedError -and @($global:LiveAzCalls | Where-Object { $_ -match '^apim (show|nv list) .*--subscription aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }).Count -eq 2 -and $CapturedResult.subscriptionId -eq 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') "$CapturedError | $($global:LiveAzCalls -join ' ; ')"
    Assert 'live discovery reads the policy with a token for that subscription''s tenant' (@($global:LiveAzCalls | Where-Object { $_ -match '^account get-access-token .*--subscription aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }).Count -eq 1) ($global:LiveAzCalls -join ' ; ')
    $global:LiveAzCalls.Clear()
    Capture { Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup rg-contoso -ApimName apim-contoso -SubscriptionId 'not-a-guid&calc' }
    Assert 'a subscription that is not an ID is not passed to the Azure CLI' (-not $CapturedError -and @($global:LiveAzCalls | Where-Object { $_ -match '--subscription' }).Count -eq 0) "$CapturedError | $($global:LiveAzCalls -join ' ; ')"
}
finally {
    Remove-Item Function:\az -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    if ($savedRestForDiscovery) { Set-Item Function:\Invoke-RestMethod -Value $savedRestForDiscovery.ScriptBlock }
}

Write-Host 'P100 Update-ClaudeGateway: no record, the apply command, a blocked plan'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p100-update-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Force -Path $scratch
try {
    function Write-DiscoveryFile([string]$Name, $Facts) {
        $d = New-Discovery
        $d | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $Facts
        $path = Join-Path $scratch $Name
        [IO.File]::WriteAllText($path, ($d | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        return $path
    }
    $global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'PASS'; Evidence = '0 of 100 used'; Remedy = '' })
    Get-Facts
    $cleanPath = Write-DiscoveryFile 'clean.json' $CapturedResult
    $global:ReadinessChecks = @([pscustomobject]@{ Name = 'Container groups in eastus2'; Result = 'FAIL'; Evidence = '100 of 100 used'; Remedy = 'Request a quota increase.' })
    Get-Facts
    $blockedPath = Write-DiscoveryFile 'blocked.json' $CapturedResult
    $missingRecord = Join-Path $scratch 'no-record.json'
    $updater = Join-Path $root 'scripts\Update-ClaudeGateway.ps1'
    $said = & pwsh -NoProfile -NonInteractive -Command "& '$updater' -RecordPath '$missingRecord' -DiscoveryPath '$cleanPath' -ResourceGroup rg-contoso -ApimName apim-contoso -StandardGroup team-std 6>&1 | Out-String" 2>&1 | Out-String
    $fp = [regex]::Match($said, 'Plan fingerprint: ([0-9a-f]{64})').Groups[1].Value
    Assert 'without a record, -ResourceGroup and -ApimName are enough to plan' ($said -match 'No decision record at' -and $fp -and $said -match '0004-entitlement-projection') ($said -replace '\s+', ' ').Substring(0, [Math]::Min(300, ($said -replace '\s+', ' ').Length))
    Assert 'the plan prints the apply command with its fingerprint and the given options' ($said -match [regex]::Escape("-StandardGroup team-std -Apply -ApprovedPlanFingerprint $fp") -and $said -match '-ResourceGroup rg-contoso -ApimName apim-contoso') ($said -split "`n" | Where-Object { $_ -match 'Apply' } | Select-Object -First 2)
    $said = & pwsh -NoProfile -NonInteractive -Command "& '$updater' -RecordPath '$missingRecord' -DiscoveryPath '$blockedPath' -ResourceGroup rg-contoso -ApimName apim-contoso 6>&1 | Out-String" 2>&1 | Out-String
    $blockedFp = [regex]::Match($said, 'Plan fingerprint: ([0-9a-f]{64})').Groups[1].Value
    Assert 'a blocked plan prints no apply command and says why' ($said -match 'blocked in 0004-entitlement-projection' -and $said -notmatch '-ApprovedPlanFingerprint') ($said -split "`n" | Where-Object { $_ -match 'blocked|Apply' } | Select-Object -First 3)
    Assert 'a blocked move names -KeepNamedValues, with which the other migrations apply and named values stay' ($said -match '-KeepNamedValues') ($said -split "`n" | Where-Object { $_ -match 'blocked' } | Select-Object -First 2)
    $said = & pwsh -NoProfile -NonInteractive -Command "try { & '$updater' -RecordPath '$missingRecord' -DiscoveryPath '$blockedPath' -ResourceGroup rg-contoso -ApimName apim-contoso -Apply -ApprovedPlanFingerprint $blockedFp 6>&1 | Out-Null; 'NO-THROW' } catch { 'THROWN: ' + `$_.Exception.Message }" 2>&1 | Out-String
    Assert 'a blocked plan is refused on apply even with its own fingerprint, before any backup' ($said -match 'THROWN: The plan is blocked in 0004-entitlement-projection' -and $said -match '-KeepNamedValues' -and -not (Test-Path -LiteralPath (Join-Path $root 'backups\before-update-apim-contoso.json'))) ($said.Trim())
    Assert 'no record was written by a plan' (-not (Test-Path -LiteralPath $missingRecord))
    $said = & pwsh -NoProfile -NonInteractive -Command "try { & '$updater' -RecordPath '$missingRecord' -DiscoveryPath '$cleanPath' -ResourceGroup rg-contoso -ApimName apim-contoso -Apply -ApprovedPlanFingerprint $('0' * 64) 6>&1 | Out-Null; 'NO-THROW' } catch { 'THROWN: ' + `$_.Exception.Message }" 2>&1 | Out-String
    Assert 'a fingerprint that does not match is refused with nothing written, and names the current fingerprint and the next step' ($said -match 'THROWN: .*does not match' -and $said -match 'nothing was written' -and $said -match "-ApprovedPlanFingerprint $fp" -and -not (Test-Path -LiteralPath $missingRecord)) ($said.Trim())
    $updaterText = [IO.File]::ReadAllText($updater)
    $foreignRecord = Join-Path $scratch 'foreign-record.json'
    [IO.File]::WriteAllText($foreignRecord, ([ordered]@{ schemaVersion = 2; resourceGroup = 'rg-a'; apimName = 'apim-a'; standardGroup = 'team-a-std'; premiumGroup = 'team-a-prem'; release = @{ version = 'v0'; commit = 'old' }; decisions = @{} } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $foreignBefore = [IO.File]::ReadAllText($foreignRecord)
    $said = & pwsh -NoProfile -NonInteractive -Command "& '$updater' -RecordPath '$foreignRecord' -DiscoveryPath '$cleanPath' 6>&1 | Out-String" 2>&1 | Out-String
    $foreignFp = [regex]::Match($said, 'Plan fingerprint: ([0-9a-f]{64})').Groups[1].Value
    Assert 'a plan made with a decision record of another gateway names both gateways and the -RecordPath remedy' ($said -match 'describes rg-a/apim-a, not rg-contoso/apim-contoso' -and $said -match '-RecordPath') (($said -split "`n" | Where-Object { $_ -match 'describes' } | Select-Object -First 2) -join ' ')
    $said = & pwsh -NoProfile -NonInteractive -Command "try { & '$updater' -RecordPath '$foreignRecord' -DiscoveryPath '$cleanPath' -Apply -ApprovedPlanFingerprint $foreignFp 6>&1 | Out-Null; 'NO-THROW' } catch { 'THROWN: ' + `$_.Exception.Message }" 2>&1 | Out-String
    Assert 'with a decision record of another gateway the apply is refused before any write, and the record is unchanged' ($said -match 'THROWN: .*describes rg-a/apim-a' -and [IO.File]::ReadAllText($foreignRecord) -ceq $foreignBefore -and -not (Test-Path -LiteralPath (Join-Path $root 'backups\before-update-apim-contoso.json'))) ($said.Trim())
    $otherSubscriptionFile = Join-Path $scratch 'other-subscription-record.json'
    [IO.File]::WriteAllText($otherSubscriptionFile, ([ordered]@{ schemaVersion = 2; subscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; release = @{ version = 'v0'; commit = 'old' }; decisions = @{} } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $otherSubscriptionBefore = [IO.File]::ReadAllText($otherSubscriptionFile)
    $said = & pwsh -NoProfile -NonInteractive -Command "try { & '$updater' -RecordPath '$otherSubscriptionFile' -DiscoveryPath '$cleanPath' -Apply -ApprovedPlanFingerprint $('0' * 64) 6>&1 | Out-Null; 'NO-THROW' } catch { 'THROWN: ' + `$_.Exception.Message }" 2>&1 | Out-String
    Assert 'with a decision record of the same names in another subscription the apply is refused before any write' ($said -match 'THROWN: .*subscription aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -and [IO.File]::ReadAllText($otherSubscriptionFile) -ceq $otherSubscriptionBefore) ($said.Trim())
    Assert 'live discovery reads the gateway in the decision record''s subscription, before and after each migration' (([regex]::Matches($updaterText, 'Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup \$target\.ResourceGroup -ApimName \$target\.ApimName -SubscriptionId \$recordSubscription')).Count -eq 2) ''
    # Every write of the update (the backup, the migrations, the deployer, the switch) uses the Azure CLI's current
    # subscription, so the update applies only where that is the subscription the record names (council round 4).
    $sameGatewayRecord = Join-Path $scratch 'same-gateway-record.json'
    [IO.File]::WriteAllText($sameGatewayRecord, ([ordered]@{ schemaVersion = 2; subscriptionId = '00000000-0000-4000-8000-000000000084'; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; release = @{ version = 'v0'; commit = 'old' }; decisions = @{} } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $sameGatewayBefore = [IO.File]::ReadAllText($sameGatewayRecord)
    $guardSnapshot = Join-Path $scratch 'guard-snapshot.json'
    $cliStub = @'
function global:az {
    $line = $args -join ' '; $global:LASTEXITCODE = 0
    if ($line -match '^apim show -g rg-contoso -n apim-contoso --subscription 00000000-0000-4000-8000-000000000084') { return '{"id":"/subscriptions/00000000-0000-4000-8000-000000000084/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso","location":"eastus2","sku":{"name":"BasicV2","capacity":1}}' }
    if ($line -match '^apim nv list') { return '[]' }
    if ($line -match '^account get-access-token') { return 'offline-token' }
    if ($line -match '^account show') { return $env:P100_CLI_SUBSCRIPTION }
    throw "unexpected az call: $line"
}
function global:Invoke-RestMethod { [pscustomobject]@{ properties = [pscustomobject]@{ value = '<policies />' } } }
'@
    function Invoke-UpdaterWithCli([string]$CliSubscription, [string]$Arguments) {
        $script = Join-Path $scratch ('cli-' + [guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($script, $cliStub + "`ntry { & '$updater' $Arguments 6>&1 | Out-String } catch { 'THROWN: ' + `$_.Exception.Message }", (New-Object Text.UTF8Encoding($false)))
        $env:P100_CLI_SUBSCRIPTION = $CliSubscription
        try { return (& pwsh -NoProfile -NonInteractive -File $script 2>&1 | Out-String) } finally { Remove-Item Env:\P100_CLI_SUBSCRIPTION -ErrorAction SilentlyContinue }
    }
    $said = Invoke-UpdaterWithCli 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' "-RecordPath '$sameGatewayRecord' -KeepNamedValues -SnapshotPath '$guardSnapshot'"
    Assert 'a plan made with the Azure CLI on another subscription than the record names prints az account set instead of the apply command' ($said -match 'current subscription is bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -and $said -match 'az account set --subscription 00000000-0000-4000-8000-000000000084' -and $said -notmatch '-ApprovedPlanFingerprint') (($said -split "`n" | Where-Object { $_ -match 'subscription|Apply|THROWN' } | Select-Object -First 3) -join ' ')
    $said = Invoke-UpdaterWithCli '00000000-0000-4000-8000-000000000084' "-RecordPath '$sameGatewayRecord' -KeepNamedValues -SnapshotPath '$guardSnapshot'"
    Assert 'a plan made with the Azure CLI on the subscription the record names prints the apply command' ($said -match '-KeepNamedValues -Apply -ApprovedPlanFingerprint [0-9a-f]{64}' -and $said -notmatch 'az account set') (($said -split "`n" | Where-Object { $_ -match 'subscription|Apply|THROWN' } | Select-Object -First 3) -join ' ')
    $said = Invoke-UpdaterWithCli 'unused' "-RecordPath '$sameGatewayRecord' -DiscoveryPath '$cleanPath' -SnapshotPath '$guardSnapshot'"
    $guardFp = [regex]::Match($said, 'Plan fingerprint: ([0-9a-f]{64})').Groups[1].Value
    $said = Invoke-UpdaterWithCli 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' "-RecordPath '$sameGatewayRecord' -DiscoveryPath '$cleanPath' -SnapshotPath '$guardSnapshot' -Apply -ApprovedPlanFingerprint $guardFp"
    Assert 'with the Azure CLI on another subscription than the record names the apply is refused before any write, and names az account set' ($guardFp -and $said -match 'THROWN: .*current subscription is bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -and $said -match 'az account set --subscription 00000000-0000-4000-8000-000000000084' -and $said -match 'Nothing was written' -and -not (Test-Path -LiteralPath $guardSnapshot) -and [IO.File]::ReadAllText($sameGatewayRecord) -ceq $sameGatewayBefore) ($said.Trim())
    $said = Invoke-UpdaterWithCli '00000000-0000-4000-8000-000000000084' "-RecordPath '$sameGatewayRecord' -DiscoveryPath '$cleanPath' -SnapshotPath '$guardSnapshot' -Apply -ApprovedPlanFingerprint $guardFp"
    Assert 'with the Azure CLI on the subscription the record names the apply passes that check and reaches its first write step' ($said -match 'THROWN: ' -and $said -notmatch 'current subscription is' -and [IO.File]::ReadAllText($sameGatewayRecord) -ceq $sameGatewayBefore) ($said.Trim())
    Assert 'a migration that does not verify names the restore command with its folder' ($updaterText -match [regex]::Escape("did not verify. Roll back with .\scripts\Restore-ClaudeGateway.ps1 -Path '")) ''
    Assert 'the updater puts a record path other than the default in every plan''s data, for the resume command' ($updaterText -match '\$plan\.Data\.RecordPath = \$resumeRecordPath') ''
    $shim = [IO.File]::ReadAllText((Join-Path $root 'Update-ClaudeGateway.ps1'))
    Assert 'the root shim forwards the migration options' ($shim -match "'StandardGroup', 'PremiumGroup', 'NamePrefix', 'ResolverInboundAccess'" -and $shim -match 'KeepNamedValues = \$true')
    $rootShim = Join-Path $root 'Update-ClaudeGateway.ps1'
    $said = & pwsh -NoProfile -NonInteractive -Command "& '$rootShim' -RecordPath '$missingRecord' -DiscoveryPath '$cleanPath' -ResourceGroup rg-contoso -ApimName apim-contoso -PremiumGroup team-prem -NamePrefix contoso -ResolverInboundAccess public 6>&1 | Out-String" 2>&1 | Out-String
    Assert 'through the root shim the options reach the plan''s apply command' ($said -match '-PremiumGroup team-prem -NamePrefix contoso -ResolverInboundAccess public -Apply -ApprovedPlanFingerprint [0-9a-f]{64}') ($said -split "`n" | Where-Object { $_ -match 'Apply|rror' } | Select-Object -First 2)
    # The root shim always passes the record path; the printed command names it only when it is not the default record.
    # A scratch copy of the repository holds its own default record, so a record of the checkout plays no part (P79).
    $copy = Join-Path $scratch 'repo'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $copy 'onboarding')
    foreach ($d in 'scripts', 'infra', 'config') { Copy-Item -LiteralPath (Join-Path $root $d) -Destination $copy -Recurse }
    Copy-Item -LiteralPath $rootShim -Destination $copy
    [IO.File]::WriteAllText((Join-Path $copy 'onboarding\claude-gateway.json'), ([ordered]@{ schemaVersion = 2; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; release = @{ version = 'v0'; commit = 'old' }; decisions = @{} } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $said = & pwsh -NoProfile -NonInteractive -Command "& '$(Join-Path $copy 'Update-ClaudeGateway.ps1')' -DiscoveryPath '$cleanPath' -ResourceGroup rg-contoso -ApimName apim-contoso 6>&1 | Out-String" 2>&1 | Out-String
    $applyLine = @($said -split "`r?`n" | Where-Object { $_ -match '-ApprovedPlanFingerprint [0-9a-f]{64}' })[0]
    Assert 'the printed apply command leaves out the default record path' ($applyLine -and $applyLine -notmatch '-RecordPath' -and $applyLine -match '^\s*\.\\Update-ClaudeGateway\.ps1 -DiscoveryPath \S+ -ResourceGroup rg-contoso -ApimName apim-contoso -Apply') "$applyLine | $(($said -split "`n" | Select-Object -Last 3) -join ' ')"

    # Every migration's Test runs after an apply. A gateway that stays on named values (no migration facts in
    # the discovery, or -KeepNamedValues) must verify: 0004 has nothing to verify when it planned no move.
    $policyPath = Join-Path $root 'infra\policy.xml'
    $policyValues = @{}
    foreach ($name in @(Get-ClaudeFlowLifecyclePolicyNamedValueReferences -PolicyPath $policyPath)) { $policyValues[$name] = 'x' }
    $policyValues['entitlement-source'] = 'named-value'
    $current = New-Discovery $policyValues
    $current | Add-Member -NotePropertyName policy -NotePropertyValue ([IO.File]::ReadAllText($policyPath))
    $currentPath = Join-Path $scratch 'current.json'
    [IO.File]::WriteAllText($currentPath, ($current | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    $Keeping = $current.PSObject.Copy()
    Get-Facts @{ KeepNamedValues = $true }
    $Keeping | Add-Member -NotePropertyName entitlementMigration -NotePropertyValue $CapturedResult -Force
    $keepingPath = Join-Path $scratch 'keeping.json'
    [IO.File]::WriteAllText($keepingPath, ($Keeping | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    foreach ($case in @(@{ Name = 'a discovery without migration facts'; Path = $currentPath; Extra = '' }, @{ Name = '-KeepNamedValues'; Path = $keepingPath; Extra = ' -KeepNamedValues' })) {
        $recordFile = Join-Path $scratch ('record-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($recordFile, (@{ schemaVersion = 2; resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; release = @{ version = 'v0'; commit = 'old' }; decisions = @{} } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        $planned = & pwsh -NoProfile -NonInteractive -Command "& '$updater' -RecordPath '$recordFile' -DiscoveryPath '$($case.Path)'$($case.Extra) 6>&1 | Out-String" 2>&1 | Out-String
        $caseFp = [regex]::Match($planned, 'Plan fingerprint: ([0-9a-f]{64})').Groups[1].Value
        $applied = & pwsh -NoProfile -NonInteractive -Command "try { & '$updater' -RecordPath '$recordFile' -DiscoveryPath '$($case.Path)'$($case.Extra) -Apply -ApprovedPlanFingerprint $caseFp 6>&1 | Out-String } catch { 'THROWN: ' + `$_.Exception.Message }" 2>&1 | Out-String
        $written = Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json
        Assert "an update with no move applies and verifies on a gateway that keeps named values ($($case.Name))" ($caseFp -and $applied -match 'Updated\. Snapshot:' -and $applied -notmatch 'THROWN' -and $written.release.commit -ne 'old') (($applied -split "`n" | Where-Object { $_ -match 'THROWN|verify|Updated' } | Select-Object -First 2) -join ' ')
    }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "P100_MIGRATION assertions=$assertions failed=$failures"
exit ([int]($failures -gt 0))
