<#
.SYNOPSIS
    Reversible, opt-in service/API and real Claude proof on a dedicated AUM test gateway.
.DESCRIPTION
    This is DIRECT HTTP with Azure CLI tokens, not an AUM-client journey.
    Uses new owned groups only. Never writes reference policy, network or authority.
    Default is a local-file plan. Execute requires an explicitly closed prior window.
    Immutable usage/audit history is retained; mutable configuration is restored.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\aum-service.json'),
    [string]$BaselinePath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.aum-local\e2e-baseline.json'),
    [string]$PlanPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.aum-local\e2e-gateway-plan.json'),
    [switch]$Execute,
    [switch]$PriorWindowClosed,
    [datetimeoffset]$NotBeforeUtc,
    [switch]$WaitForWarning,
    [ValidateRange(1, 20)][int]$MaxProbeCalls = 16
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'ClaudeAumDeployment.ps1')
$record = Get-Content $RecordPath -Raw | ConvertFrom-Json
$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json
$plan = Get-Content $PlanPath -Raw | ConvertFrom-Json
if ($record.resourceGroup -notlike 'rg-aum-e2e-*' -or
    $record.resourceGroup -ne $plan.ResourceGroup -or
    $record.gatewayResourceId -ne $baseline.Gateway.id) {
    throw 'Only the explicitly recorded dedicated AUM test gateway is allowed.'
}
$description = [ordered]@{
    transport='direct-http-with-Azure-CLI-token'; notAnAumClientClaim=$true
    target=$record.gatewayResourceId; priorWindowClosedRequired=$true
    operations=@('Create five owned test groups','Register unit and teams through service',
        'Map manager groups','Set budgets and all three modes','Nest test groups and add the caller only to the new team',
        'Sync only the dedicated gateway','Send real Claude requests','Verify attributed usage',
        'Restore configuration/member sets and delete all created groups')
}
if (-not $Execute) { return [pscustomobject]$description }
if (-not $PriorWindowClosed) { throw 'No changes made: wait for the prior agent''s explicit window closed.' }
if ($PSBoundParameters.ContainsKey('NotBeforeUtc') -and [datetimeoffset]::UtcNow -lt $NotBeforeUtc) {
    throw 'No changes made: the authorized fallback time has not arrived.'
}
if (-not $PSCmdlet.ShouldProcess($record.gatewayResourceId, 'Run the announced dedicated-gateway proof and restore in finally')) { return }

$events = New-Object System.Collections.Generic.List[object]
$created = New-Object System.Collections.Generic.List[object]
$plannedGroups = New-Object System.Collections.Generic.List[string]
$restoreErrors = New-Object System.Collections.Generic.List[string]
$graph = 'https://graph.microsoft.com/v1.0'
$graphToken = (Invoke-ClaudeAumAz @('account','get-access-token','--subscription',$record.subscriptionId,'--resource','https://graph.microsoft.com','-o','json')).accessToken
$serviceToken = (Invoke-ClaudeAumAz @('account','get-access-token','--subscription',$record.subscriptionId,'--scope',$record.scope,'-o','json')).accessToken
$modelToken = (Invoke-ClaudeAumAz @('account','get-access-token','--subscription',$record.subscriptionId,'--resource','https://cognitiveservices.azure.com','-o','json')).accessToken
$armToken = (Invoke-ClaudeAumAz @('account','get-access-token','--subscription',$record.subscriptionId,'--resource','https://management.azure.com','-o','json')).accessToken
$graphHeaders = @{Authorization='Bearer '+$graphToken}
$serviceHeaders = @{Authorization='Bearer '+$serviceToken}
$armHeaders = @{Authorization='Bearer '+$armToken}
$costUri = "https://management.azure.com$($record.workspaceResourceId)/savedSearches/claudecost?api-version=2020-08-01"
$started = [datetime]::UtcNow
$prefix = 'aum-proof-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$unitId = "$prefix-unit"; $teamId = "$prefix-team"; $outsideId = "$prefix-other"
$output = Join-Path $root ".aum-local\$prefix-evidence.json"

function Add-Evidence([string]$Step, $Data) {
    $events.Add([pscustomobject]@{step=$Step; utc=[datetime]::UtcNow.ToString('o'); data=$Data})
    Write-ClaudeAumJson $output @{transport=$description.transport; target=$record.gatewayResourceId; started_utc=$started.ToString('o'); events=$events.ToArray()}
}
function Invoke-ProofGraph([string]$Method, [string]$Path, $Body=$null) {
    $arguments=@{Uri="$graph$Path";Method=$Method;Headers=$graphHeaders;TimeoutSec=90}
    if ($null -ne $Body) { $arguments.ContentType='application/json'; $arguments.Body=($Body|ConvertTo-Json -Depth 15) }
    return Invoke-RestMethod @arguments
}
function Get-DirectMemberships {
    $uri="$graph/me/memberOf/microsoft.graph.group"
    $ids=@()
    while ($uri) {
        if (-not $uri.StartsWith("$graph/")) { throw 'Unexpected Graph continuation host' }
        $page=Invoke-RestMethod -Uri $uri -Headers $graphHeaders -TimeoutSec 90
        $ids += @($page.value | ForEach-Object id)
        $uri=[string]$page.'@odata.nextLink'
    }
    return @($ids | Sort-Object -Unique)
}
function Invoke-ProofApi([string]$Method, [string]$Path, $Body=$null, [string]$Revision) {
    $headers=@{}; foreach ($key in $serviceHeaders.Keys) { $headers[$key]=$serviceHeaders[$key] }
    if ($Revision) { $headers['If-Match']=Format-ClaudeAumIfMatch $Revision }
    $arguments=@{Uri="$($record.endpoint)/api/v1/$Path";Method=$Method;Headers=$headers;TimeoutSec=120}
    if ($null -ne $Body) { $arguments.ContentType='application/json';$arguments.Body=($Body|ConvertTo-Json -Depth 20) }
    return Invoke-RestMethod @arguments
}
function Get-ProofNvs {
    return @(Invoke-ClaudeAumAz @('apim','nv','list','--subscription',$record.subscriptionId,
        '-g',$record.resourceGroup,'--service-name',$plan.NamePrefix.Insert(0,'apim-'),'-o','json'))
}
function Compare-ProofNvs($Before, $After) {
    $differences=@()
    foreach ($entry in $Before) {
        $match=@($After | Where-Object name -eq $entry.name)
        if ($match.Count -ne 1 -or [string]$match[0].value -cne [string]$entry.value) { $differences += $entry.name }
    }
    $differences += @($After | Where-Object { $_.name -notin @($Before.name) } | ForEach-Object name)
    return @($differences | Sort-Object -Unique)
}
function Set-ProofBudget([string]$Kind,[string]$Key,[long]$Amount) {
    $revision=(Invoke-ProofApi GET 'budgets').revision
    $result=Invoke-ProofApi PUT "budgets/$Kind/$Key" @{token_limit=$Amount;reason='Reversible dedicated-gateway enforcement proof'} $revision
    Add-Evidence "budget.$Kind" @{scope_id=$Key;token_limit=$Amount;audit_id=$result.audit_id}
}
function Set-ProofMode([string]$Mode) {
    $revision=(Invoke-ProofApi GET 'budgets').revision
    $body=@{enforcement=$Mode;reason='Reversible real-request mode proof'}
    if ($Mode -eq 'allowance') { $body.allowance_percent=100 }
    $result=Invoke-ProofApi PUT "modes/$teamId" $body $revision
    Add-Evidence 'mode' @{scope_id=$teamId;mode=$Mode;audit_id=$result.audit_id}
}
function New-ProofGroup([string]$Suffix) {
    $name="$prefix-$Suffix"
    $plannedGroups.Add($name)
    Add-Evidence 'group.create_intent' @{name=$name}
    $group=Invoke-ProofGraph POST '/groups' @{
        displayName=$name;mailEnabled=$false;mailNickname=($name -replace '-','');securityEnabled=$true
        description='Temporary dedicated AUM gateway proof; deleted in finally.'
    }
    $created.Add($group)
    $owners=@((Invoke-ProofGraph GET "/groups/$($group.id)/owners").value)
    if (-not @($owners|Where-Object id -eq $me.id).Count) {
        Invoke-ProofGraph POST "/groups/$($group.id)/owners/`$ref" @{'@odata.id'="$graph/directoryObjects/$($me.id)"} | Out-Null
    }
    Add-Evidence 'group.created' @{id=$group.id;name=$name}
    return $group
}
function Add-ProofMember([string]$Group,[string]$Member) {
    Invoke-ProofGraph POST "/groups/$Group/members/`$ref" @{'@odata.id'="$graph/directoryObjects/$Member"} | Out-Null
}
function Invoke-ClaudeProbe([string]$Phase) {
    $headers=@{Authorization='Bearer '+$modelToken;'anthropic-version'='2023-06-01'}
    $body=@{model=$model;max_tokens=16;stream=$false;messages=@(@{role='user';content='Reply only OK.'})}|ConvertTo-Json -Depth 8
    $at=[datetime]::UtcNow
    $responseHeaders=@{}
    try {
        $response=Invoke-WebRequest -Uri "$($gatewayConfig.gatewayUrl)/v1/messages" -Method Post `
            -Headers $headers -ContentType application/json -Body $body -UserAgent 'aum-service-e2e-proof' -UseBasicParsing -TimeoutSec 120
        $status=[int]$response.StatusCode; $content=$response.Content; $responseHeaders=$response.Headers
    }
    catch {
        if (-not $_.Exception.Response) { throw }
        $status=[int]$_.Exception.Response.StatusCode
        $content=$_.ErrorDetails.Message
        $responseHeaders=$_.Exception.Response.Headers
    }
    $parsed=$null
    if ($content) { try { $parsed=$content|ConvertFrom-Json } catch { $parsed=@{unparsed=$content} } }
    $receipt=[pscustomobject]@{
        phase=$Phase;utc=$at.ToString('o');status=$status;model=$model
        notice=[string]$responseHeaders['x-claude-budget-notice']
        team_remaining=[string]$responseHeaders['x-bu-quota-remaining']
        parent_remaining=[string]$responseHeaders['x-bu-parent-quota-remaining']
        tier=[string]$responseHeaders['x-claude-tier']
        gateway_error=[string]$responseHeaders['x-gateway-error'];body=$parsed
    }
    Add-Evidence 'claude.request' $receipt
    return $receipt
}
function Wait-ClaudeProbe([string]$Phase,[scriptblock]$Accept) {
    for ($attempt=0; $attempt -lt $MaxProbeCalls; $attempt++) {
        $receipt=Invoke-ClaudeProbe $Phase
        if (& $Accept $receipt) { return $receipt }
        if ($receipt.status -notin @(200,403,429)) { throw "Unexpected model HTTP $($receipt.status), phase $Phase" }
        Start-Sleep -Seconds 10
    }
    throw "Expected $Phase enforcement was not observed; do not claim success."
}
function Publish-ProofQueries {
    & (Join-Path $PSScriptRoot 'Publish-ClaudeQueries.ps1') -SubscriptionId $record.subscriptionId `
        -ResourceGroup $record.resourceGroup -ApimName $baseline.Gateway.name `
        -WorkspaceName $baseline.Workspace.name -Query ClaudeCost
}

$me=Invoke-ProofGraph GET '/me'
$identity=Invoke-ProofApi GET 'me'
if ($identity.access -ne 'admin' -or $identity.id -ne $me.id) { throw 'The same recorded person must be AUM.Admin.' }
$membershipsBefore=@(Get-DirectMemberships)
$before=@(Get-ProofNvs)
$costBefore=Invoke-RestMethod -Uri $costUri -Headers $armHeaders -TimeoutSec 90
if (@(Compare-ProofNvs $baseline.NamedValues $before).Count) { throw 'Dedicated gateway changed since baseline; obtain a new coordinated snapshot.' }
$catalogBefore=Invoke-ProofApi GET 'catalog'
if (@($catalogBefore.organizations).Count -or @($catalogBefore.departments).Count) { throw 'An empty dedicated catalog is required.' }
$gatewayConfig=Get-Content (Join-Path $root 'onboarding\claude-gateway.json') -Raw|ConvertFrom-Json
if ($gatewayConfig.apimName -ne $baseline.Gateway.name) { throw 'Onboarding record targets another gateway.' }
$models=@(([string](@($before|Where-Object name -eq 'models-standard')[0].value)).Trim(',').Split(',')|Where-Object{$_})
$model=@($models|Where-Object{$_ -match 'haiku'}|Select-Object -First 1)[0]
if (-not $model) { $model=@($models|Where-Object{$_ -match 'claude'}|Select-Object -First 1)[0] }
if (-not $model) { throw 'No real Claude deployment is allowed in the test standard tier.' }
$catalogChanged=$false
$membershipChanged=$false
$standardId=@($baseline.FoundationGroups|Where-Object name -eq $plan.StandardGroup)[0].id
try {
    Add-Evidence 'snapshot' @{memberships=$membershipsBefore;named_values=$before;catalog=$catalogBefore;cost_function=$costBefore;model=$model}
    $unitGroup=New-ProofGroup 'unit'
    $teamGroup=New-ProofGroup 'team'
    $outsideGroup=New-ProofGroup 'other'
    $unitManagers=New-ProofGroup 'unit-managers'
    $teamManagers=New-ProofGroup 'team-managers'
    $entities=@(
        @{id=$unitId;name=$unitGroup.displayName;parent_id=$null;external_ref="entra-group:$($unitGroup.displayName)"},
        @{id=$teamId;name=$teamGroup.displayName;parent_id=$unitId;external_ref="entra-group:$($teamGroup.displayName)"},
        @{id=$outsideId;name=$outsideGroup.displayName;parent_id=$unitId;external_ref="entra-group:$($outsideGroup.displayName)"}
    )
    $revision=(Invoke-ProofApi GET 'budgets').revision
    $catalogChanged=$true
    Invoke-ProofApi PUT 'catalog' @{entities=$entities;reason='Dedicated real-Claude service proof'} $revision | Out-Null
    foreach ($mapping in @(@{id=$unitId;group=$unitManagers.id},@{id=$teamId;group=$teamManagers.id})) {
        $revision=(Invoke-ProofApi GET 'budgets').revision
        Invoke-ProofApi PUT "manager-groups/$($mapping.id)" @{manager_group_id=$mapping.group;reason='Map empty owned manager groups'} $revision | Out-Null
    }
    Set-ProofBudget 'organization' $unitId 1000000
    Set-ProofBudget 'department' $teamId 100000
    Set-ProofBudget 'department' $outsideId 1000
    Add-ProofMember $unitGroup.id $teamGroup.id
    Add-ProofMember $standardId $teamGroup.id
    $membershipChanged=$true
    Add-ProofMember $teamGroup.id $me.id
    & (Join-Path $PSScriptRoot 'Sync-ClaudeAccess.ps1') -ResourceGroup $record.resourceGroup -ApimName $baseline.Gateway.name `
        -StandardGroup $plan.StandardGroup -PremiumGroup $plan.PremiumGroup
    $synced=@(Get-ProofNvs)
    if ([string](@($synced|Where-Object name -eq 'bu-members')[0].value) -notmatch [regex]::Escape("$($me.id)=$teamId")) {
        throw 'Actual gateway membership did not resolve to the created team.'
    }
    Publish-ProofQueries
    Wait-ClaudeProbe 'entitled' {param($r) $r.status -eq 200 -and $r.tier -eq 'standard'} | Out-Null

    Set-ProofMode 'strict'
    Set-ProofBudget 'department' $teamId 1
    Wait-ClaudeProbe 'strict-refusal' {param($r) $r.status -eq 403 -and [string]$r.body.error.message -match [regex]::Escape($teamId)} | Out-Null

    Set-ProofBudget 'department' $teamId 100000
    $last=Wait-ClaudeProbe 'known-large-limit' {param($r) $r.status -eq 200 -and $r.team_remaining -match '^\d+$' -and [long]$r.team_remaining -gt 50000}
    for ($i=0; $i -lt 8; $i++) {
        $last=Invoke-ClaudeProbe 'allowance-prime'
        if ($last.status -ne 200) { throw 'Priming call was not served under the verified large limit.' }
    }
    $spent=100000-[long]$last.team_remaining
    $base=[long][math]::Max(100,[math]::Floor($spent * 0.8))
    Add-Evidence 'allowance.plan' @{estimated_spent=$spent;nominal_limit=$base;allowance_percent=100;effective_limit=2*$base;estimate_not_hard_accounting=$true}
    Set-ProofMode 'allowance'
    Set-ProofBudget 'department' $teamId $base
    Wait-ClaudeProbe 'allowance-over-nominal' {param($r) $r.status -eq 200 -and $r.notice -match 'mode=allowance:100;status=estimated-over-budget'} | Out-Null
    Wait-ClaudeProbe 'allowance-refusal' {param($r) $r.status -eq 403 -and [string]$r.body.error.message -match [regex]::Escape($teamId)} | Out-Null

    Set-ProofMode 'notify'
    Set-ProofBudget 'department' $teamId 1
    Wait-ClaudeProbe 'notify-serves-over-budget' {param($r) $r.status -eq 200 -and $r.notice -match 'mode=notify;status=usage-reported'} | Out-Null
    $until=[datetime]::UtcNow.AddMinutes(8)
    $usage=$null
    while ([datetime]::UtcNow -lt $until) {
        $usage=Invoke-ProofApi GET "usage?department_id=$teamId"
        if ([long]$usage.requests -gt 0) { break }
        Start-Sleep -Seconds 20
    }
    if (-not $usage -or [long]$usage.requests -lt 1) { throw 'No attributed usage reached the service within eight minutes.' }
    $requests=Invoke-ProofApi GET "requests?department_id=$teamId"
    if (-not @($requests.items|Where-Object{$_.user_id -eq $me.id -and $_.business_unit -eq $teamId}).Count) {
        throw 'The real request ledger did not identify this caller and test team.'
    }
    Add-Evidence 'attribution' @{scope_id=$teamId;usage=$usage;matching_requests=@($requests.items|Where-Object user_id -eq $me.id).Count}
    if ($WaitForWarning) {
        $until=[datetime]::UtcNow.AddMinutes(17)
        $facts=@()
        while ([datetime]::UtcNow -lt $until) {
            $notifications=Invoke-ProofApi GET 'notifications'
            $facts=@($notifications.items|Where-Object{$_.scope_id -eq $teamId -and $_.kind -eq 'budget.warning'})
            if ($facts.Count) { break }
            Start-Sleep -Seconds 20
        }
        if (-not $facts.Count) { throw 'The scheduled warning fact was not observed; do not claim it.' }
        Add-Evidence 'warning.fact' $facts
    }
    Add-Evidence 'proof.passed' @{strict=$true;allowance=$true;notify=$true;real_claude=$true;attribution=$true;not_an_aum_client_claim=$true}
}
finally {
    if ($membershipChanged -and $teamGroup) {
        try { Invoke-ProofGraph DELETE "/groups/$($teamGroup.id)/members/$($me.id)/`$ref" | Out-Null }
        catch {
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { $restoreErrors.Add("Caller removal: $($_.Exception.Message)") }
        }
    }
    if ($teamGroup -and $standardId) {
        try { Invoke-ProofGraph DELETE "/groups/$standardId/members/$($teamGroup.id)/`$ref" | Out-Null }
        catch {
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { $restoreErrors.Add("Tier nesting removal: $($_.Exception.Message)") }
        }
    }
    try {
        & (Join-Path $PSScriptRoot 'Sync-ClaudeAccess.ps1') -ResourceGroup $record.resourceGroup -ApimName $baseline.Gateway.name `
            -StandardGroup $plan.StandardGroup -PremiumGroup $plan.PremiumGroup -AllowEmpty
        if ($catalogChanged) {
            $revision=(Invoke-ProofApi GET 'budgets').revision
            Invoke-ProofApi PUT 'catalog' @{entities=@();reason='Finally restore isolated empty catalog'} $revision | Out-Null
        }
    }
    catch { $restoreErrors.Add("Configuration restoration: $($_.Exception.Message)") }
    try {
        Invoke-RestMethod -Uri $costUri -Method Put -Headers $armHeaders -ContentType application/json `
            -Body (@{properties=$costBefore.properties}|ConvertTo-Json -Depth 20) -TimeoutSec 90 | Out-Null
    }
    catch { $restoreErrors.Add("Saved-query restoration: $($_.Exception.Message)") }
    foreach ($name in $plannedGroups) {
        try {
            $filter=[uri]::EscapeDataString("displayName eq '$($name.Replace("'","''"))'")
            $found=@((Invoke-ProofGraph GET ("/groups?`$filter="+$filter)).value)
            foreach ($group in $found) {
                if (-not @($created | Where-Object id -eq $group.id).Count) { $created.Add($group) }
            }
        }
        catch { $restoreErrors.Add("Uncertain group-create reconciliation: $($_.Exception.Message)") }
    }
    foreach ($group in @($created.ToArray())) {
        try { Invoke-ProofGraph DELETE "/groups/$($group.id)" | Out-Null }
        catch { $restoreErrors.Add("Test group deletion $($group.id): $($_.Exception.Message)") }
    }
    try {
        $after=@(Get-ProofNvs)
        $different=@(Compare-ProofNvs $before $after)
        if ($different.Count) { throw ('Named values differ: '+($different -join ', ')) }
        $costAfter=Invoke-RestMethod -Uri $costUri -Headers $armHeaders -TimeoutSec 90
        foreach ($field in @('query','functionAlias','functionParameters','category','displayName')) {
            if ([string]$costAfter.properties.$field -cne [string]$costBefore.properties.$field) { throw "Saved cost function differs: $field" }
        }
        $memberDeadline=[datetime]::UtcNow.AddMinutes(2)
        do {
            $membersAfter=@(Get-DirectMemberships)
            $memberDifference=@(Compare-Object $membershipsBefore $membersAfter)
            if (-not $memberDifference.Count) { break }
            Start-Sleep -Seconds 10
        } while ([datetime]::UtcNow -lt $memberDeadline)
        if ($memberDifference.Count) { throw 'Direct membership sets differ from snapshot' }
        $afterMe=Invoke-ProofApi GET 'me'
        if ($afterMe.access -ne 'admin' -or $null -ne $afterMe.manager_scope) { throw 'Admin authority was not preserved' }
        Add-Evidence 'restored' @{named_values_byte_identical=$true;cost_function_exact=$true;memberships_exact=$true;admin_preserved=$true;created_groups_deleted=$created.Count;errors=$restoreErrors.ToArray()}
    }
    catch { $restoreErrors.Add("Restoration verification: $($_.Exception.Message)") }
    Add-Evidence 'finished' @{restoration_errors=$restoreErrors.ToArray();mutations_closed=($restoreErrors.Count -eq 0)}
    if ($restoreErrors.Count) { throw ('RESTORATION NEEDS ATTENTION: '+($restoreErrors -join '; ')) }
}
[pscustomobject]@{Transport=$description.transport;Evidence=$output;Passed=$true;Restored=$true}
