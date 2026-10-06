<#
.SYNOPSIS
    Installs a disposable gateway with the Cosmos projection and checks one developer's access through it.

.DESCRIPTION
    Works only in the subscription named by -SubscriptionId, and refuses the default Azure CLI profile
    unless -UseCurrentAzLogin is passed. Each step prints what it does:

      1. Checks every input before any Azure call, and that the resource group does not exist yet.
      2. Creates run-specific tier groups and adds the signed-in user to the standard group, before
         the installer reads them.
      3. Runs Install-ClaudeGateway.ps1 -Yes on Basic v2. The installer chooses its default store,
         creates the resource group, deploys the gateway and the projection, and switches the gateway.
      4. Checks that entitlement-source is projection and entitlement-projection-prefix is the prefix.
      5. Sets entitlement-cache-seconds to 60 on this disposable gateway, so a removal shows within a
         minute; the gateway caches an allowed answer for that many seconds (infra/policy.xml).
      6. Sends a request through the gateway as the signed-in user and expects 200.
      7. Removes the user from the group, runs Sync-ClaudeAccess.ps1 -User, and expects 403.
      8. Adds the user back, runs Sync-ClaudeAccess.ps1 -User, and expects 200.

    With -MigrateWithUpdate (ADR-0054), step 3 installs with -EntitlementStore named-value, and before step 4:
      a. Checks that entitlement-source is named-value and sends a request that expects 200.
      b. Runs Update-ClaudeGateway.ps1 -ResourceGroup -ApimName, and stops unless its plan for
         0004-entitlement-projection has actions and is not blocked.
      c. Runs the same command with -Apply -ApprovedPlanFingerprint <the plan's fingerprint>.
    After step 4 it checks that entitlement-groups holds the object ids of the run's two tier groups.

    With -Teardown, whatever happened: deletes only objects this run can prove it created: the gateway
    identity's role assignments on the Foundry account and resolver app only when the disposable resource
    group was created by this run, the resource group, and the tier groups this run created.

.EXAMPLE
    ./scripts/Test-ClaudeLiveProjection.ps1 -SubscriptionId <id> -Location eastus2 -FoundryAccount <name> -FoundryResourceGroup <rg> -UseCurrentAzLogin -Teardown
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$FoundryAccount,
    [Parameter(Mandatory)][string]$FoundryResourceGroup,
    [string]$ResourceGroup,
    [string]$NamePrefix,
    [string]$StandardGroup,
    [string]$PremiumGroup,
    [string]$Model,
    [ValidateRange(60, 1800)][int]$ChangeWaitSeconds = 300,
    [ValidateRange(1, 60)][int]$PollSeconds = 15,
    [switch]$UseCurrentAzLogin,
    [switch]$Teardown,
    [switch]$MigrateWithUpdate,
    # Tests point these at stubs; a live run uses the repository's scripts.
    [Parameter(DontShow)][string]$InstallerPath,
    [Parameter(DontShow)][string]$SyncAccessPath,
    [Parameter(DontShow)][string]$UpdatePath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $InstallerPath) { $InstallerPath = Join-Path $root 'Install-ClaudeGateway.ps1' }
if (-not $SyncAccessPath) { $SyncAccessPath = Join-Path $root 'scripts\Sync-ClaudeAccess.ps1' }
if (-not $UpdatePath) { $UpdatePath = Join-Path $root 'Update-ClaudeGateway.ps1' }
$results = [System.Collections.Generic.List[object]]::new()
. (Join-Path $PSScriptRoot 'ClaudeLiveHarness.ps1')
$guid = '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'
Assert-Form SubscriptionId $SubscriptionId $guid
Assert-Form Location $Location '\A[a-z0-9]{2,40}\z'
Assert-Form FoundryAccount $FoundryAccount '\A[A-Za-z0-9][A-Za-z0-9-]{1,62}\z'
Assert-Form FoundryResourceGroup $FoundryResourceGroup '\A[A-Za-z0-9._-]{1,90}\z'
if ($Model) { Assert-Form Model $Model '\A[A-Za-z0-9._-]{1,64}\z' }
if (-not $ResourceGroup) { $ResourceGroup = 'rg-claude-live-' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
if (-not $NamePrefix) { $NamePrefix = 'clive' + [guid]::NewGuid().ToString('N').Substring(0, 10) }
Assert-Form ResourceGroup $ResourceGroup '\A[A-Za-z0-9._-]{1,90}\z'
Assert-Form NamePrefix $NamePrefix '\A(?=.{1,37}\z)[a-z0-9]+(?:-[a-z0-9]+)*\z'
$standardGroupExplicit = $PSBoundParameters.ContainsKey('StandardGroup') -and -not [string]::IsNullOrWhiteSpace($StandardGroup)
$premiumGroupExplicit = $PSBoundParameters.ContainsKey('PremiumGroup') -and -not [string]::IsNullOrWhiteSpace($PremiumGroup)
if (-not $standardGroupExplicit -or -not $premiumGroupExplicit) {
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    if (-not $standardGroupExplicit) { $StandardGroup = "claude-live-p98-$runId-standard" }
    if (-not $premiumGroupExplicit) { $PremiumGroup = "claude-live-p98-$runId-premium" }
}
Assert-Form StandardGroup $StandardGroup '\A[A-Za-z0-9._-]{1,120}\z'
Assert-Form PremiumGroup $PremiumGroup '\A[A-Za-z0-9._-]{1,120}\z'
Assert-AzProfileAllowed -UseCurrentAzLogin:$UseCurrentAzLogin
$apimName = "apim-$NamePrefix"
$expectedResolverDisplayName = "claude-projection-resolver-$NamePrefix"
$createdGroups = [System.Collections.Generic.List[string]]::new()
$resourceGroupCreated = $false
$installerStarted = $false
$failed = $false
$originalSubscription = $null

try {
    Write-Host "`n==> Subscription and resource group" -ForegroundColor Cyan
    if ($UseCurrentAzLogin) { $originalSubscription = Invoke-Az @('account', 'show', '--query', 'id', '-o', 'tsv') -AllowFailure }
    Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    $account = Invoke-Az @('account', 'show', '-o', 'json') | ConvertFrom-Json
    if ([string]$account.id -ne $SubscriptionId) { throw "The Azure CLI is on subscription $($account.id), not $SubscriptionId. Nothing was created. Remedy: az login --tenant <tenant-id> in the profile this test uses (AZURE_CONFIG_DIR, or the current one with -UseCurrentAzLogin), so that it can select $SubscriptionId, then rerun." }
    Add-Result 'account' $true "$($account.user.name) in $SubscriptionId"
    if ((Invoke-Az @('group', 'exists', '--name', $ResourceGroup, '--subscription', $SubscriptionId)) -eq 'true') { throw "Resource group $ResourceGroup already exists; this test deletes what it creates, so it uses a new one. Nothing was created. Remedy: omit -ResourceGroup, so the test creates rg-claude-live-<random>, or pass a -ResourceGroup name that does not exist yet." }
    $existingResolverApps = Split-NonEmptyLines (Invoke-Az @('ad', 'app', 'list', '--filter', "displayName eq '$expectedResolverDisplayName'", '--query', '[].appId', '-o', 'tsv'))
    if ($existingResolverApps.Count -gt 0) { throw "Resolver app $expectedResolverDisplayName already exists. Nothing was created. Remedy: omit -NamePrefix, so the test uses a new random prefix, or pass a -NamePrefix no other deployment uses." }

    Write-Host "`n==> Tier groups and the signed-in user" -ForegroundColor Cyan
    $groupIds = @{}
    foreach ($name in @($StandardGroup, $PremiumGroup)) {
        $ids = Split-NonEmptyLines (Invoke-Az @('ad', 'group', 'list', '--filter', "displayName eq '$name'", '--query', '[].id', '-o', 'tsv'))
        if ($ids.Count -gt 0) {
            throw "Tier group $name already exists. Nothing was created. Remedy: omit -StandardGroup and -PremiumGroup, so the test creates its own groups."
        }
    }
    foreach ($name in @($StandardGroup, $PremiumGroup)) {
        $id = Invoke-Az @('ad', 'group', 'create', '--display-name', $name, '--mail-nickname', $name, '--query', 'id', '-o', 'tsv')
        Assert-Form 'group id' $id $guid
        $createdGroups.Add($id)
        $groupIds[$name] = $id
    }
    $userId = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv')
    Assert-Form 'signed-in user' $userId $guid
    if ((Invoke-Az @('ad', 'group', 'member', 'check', '--group', $groupIds[$StandardGroup], '--member-id', $userId, '--query', 'value', '-o', 'tsv')) -ne 'true') {
        Invoke-Az @('ad', 'group', 'member', 'add', '--group', $groupIds[$StandardGroup], '--member-id', $userId) | Out-Null
    }
    Wait-Membership $groupIds[$StandardGroup] $userId 'true'
    Add-Result 'groups' $true "$StandardGroup holds $userId; created: $($createdGroups.Count)"

    Write-Host "`n==> Installer with $(if ($MigrateWithUpdate) { 'named values' } else { 'the Cosmos projection default' })" -ForegroundColor Cyan
    $installerArgs = @{ SubscriptionId = $SubscriptionId; FoundryAccount = $FoundryAccount; FoundryResourceGroup = $FoundryResourceGroup
        ResourceGroup = $ResourceGroup; Location = $Location; NamePrefix = $NamePrefix; Sku = 'BasicV2'; Yes = $true; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup }
    if ($MigrateWithUpdate) { $installerArgs.EntitlementStore = 'named-value' }
    $installerStarted = $true
    & $InstallerPath @installerArgs
    $resourceGroupCreated = $true
    Add-Result 'installer' $true $apimName

    if (-not $Model) {
        $models = Invoke-Az @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'models-standard', '--query', 'value', '-o', 'tsv', '--subscription', $SubscriptionId)
        $Model = @([regex]::Matches([string]$models, '[A-Za-z0-9._-]+') | ForEach-Object Value | Select-Object -First 1)[0]
        if (-not $Model) { throw 'models-standard names no model to request.' }
    }
    $gatewayUrl = Invoke-Az @('apim', 'show', '-g', $ResourceGroup, '-n', $apimName, '--query', 'gatewayUrl', '-o', 'tsv', '--subscription', $SubscriptionId)
    $url = "$($gatewayUrl.TrimEnd('/'))/claude/v1/messages"

    if ($MigrateWithUpdate) {
        $source = Invoke-Az @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'entitlement-source', '--query', 'value', '-o', 'tsv', '--subscription', $SubscriptionId)
        if ($source -ne 'named-value') { Add-Result 'named values' $false "entitlement-source '$source'"; throw 'The installer did not leave the gateway on named values.' }
        Add-Result 'named values' $true 'entitlement-source named-value'
        Wait-GatewayStatus $url $Model 200 'entitled request on named values'

        Write-Host "`n==> Update: the plan, then its apply" -ForegroundColor Cyan
        # The plan's review text comes back on the output stream with the result; printed, it keeps the planned
        # resources, cost and time in the run's log.
        $planOutput = @(& $UpdatePath -ResourceGroup $ResourceGroup -ApimName $apimName)
        foreach ($text in @($planOutput | Where-Object { $_ -is [string] })) { Write-Host $text }
        $plan = @($planOutput | Where-Object { $_ -isnot [string] -and $_.PSObject.Properties['Fingerprint'] })[0]
        $move = @(@($plan.Plans) | Where-Object { $_.Step -eq '0004-entitlement-projection' })[0]
        $fingerprint = [string]$plan.Fingerprint
        if (-not $move -or -not @($move.Actions).Count -or $move.Data.Blocked -or $fingerprint -notmatch '\A[0-9a-f]{64}\z') {
            Add-Result 'update plan' $false "move planned: $([bool]$move); actions: $(@($move.Actions).Count); blocked: $([bool]$move.Data.Blocked); fingerprint '$fingerprint'"
            throw 'The update did not plan an unblocked move to the projection.'
        }
        Add-Result 'update plan' $true "fingerprint $fingerprint, $(@($move.Actions).Count) action(s)"
        & $UpdatePath -ResourceGroup $ResourceGroup -ApimName $apimName -Apply -ApprovedPlanFingerprint $fingerprint | Out-Null
        Add-Result 'update apply' $true $fingerprint
    }

    $source = Invoke-Az @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'entitlement-source', '--query', 'value', '-o', 'tsv', '--subscription', $SubscriptionId)
    $prefix = Invoke-Az @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'entitlement-projection-prefix', '--query', 'value', '-o', 'tsv', '--subscription', $SubscriptionId)
    if ($source -ne 'projection' -or $prefix -ne $NamePrefix) { Add-Result 'switch' $false "entitlement-source '$source', prefix '$prefix'"; throw "The $(if ($MigrateWithUpdate) { 'update' } else { 'installer' }) did not leave the gateway on the projection." }
    Add-Result 'switch' $true "entitlement-source projection, prefix $prefix"
    if ($MigrateWithUpdate) {
        $recordedGroups = Invoke-Az @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'entitlement-groups', '--query', 'value', '-o', 'tsv', '--subscription', $SubscriptionId)
        $expectedGroups = "standard=$($groupIds[$StandardGroup]),premium=$($groupIds[$PremiumGroup])".ToLowerInvariant()
        if ($recordedGroups -ne $expectedGroups) { Add-Result 'groups recorded' $false "entitlement-groups '$recordedGroups', expected '$expectedGroups'"; throw 'The update did not record the tier groups.' }
        Add-Result 'groups recorded' $true $recordedGroups
    }
    Invoke-Az @('apim', 'nv', 'update', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'entitlement-cache-seconds', '--value', '60', '--subscription', $SubscriptionId) | Out-Null

    Write-Host "`n==> Requests through the gateway as $userId ($Model)" -ForegroundColor Cyan
    Wait-GatewayStatus $url $Model 200 'entitled request'

    Invoke-Az @('ad', 'group', 'member', 'remove', '--group', $groupIds[$StandardGroup], '--member-id', $userId) | Out-Null
    Wait-Membership $groupIds[$StandardGroup] $userId 'false'
    & $SyncAccessPath -ResourceGroup $ResourceGroup -ApimName $apimName -User $userId
    Wait-GatewayStatus $url $Model 403 'removed, then targeted sync'

    Invoke-Az @('ad', 'group', 'member', 'add', '--group', $groupIds[$StandardGroup], '--member-id', $userId) | Out-Null
    Wait-Membership $groupIds[$StandardGroup] $userId 'true'
    & $SyncAccessPath -ResourceGroup $ResourceGroup -ApimName $apimName -User $userId
    Wait-GatewayStatus $url $Model 200 're-added, then targeted sync'
}
catch {
    $failed = $true
    if ($installerStarted -and -not $resourceGroupCreated) {
        $existsAfterInstaller = Invoke-Az @('group', 'exists', '--name', $ResourceGroup, '--subscription', $SubscriptionId) -AllowFailure
        if ($existsAfterInstaller -eq 'true') { $resourceGroupCreated = $true }
    }
    Add-Result 'stopped' $false $_.Exception.Message
}
finally {
    if ($Teardown) {
        Write-Host "`n==> Teardown" -ForegroundColor Cyan
        $teardownLeft = [System.Collections.Generic.List[string]]::new()
        if ($resourceGroupCreated) {
            $principal = Invoke-Az @('apim', 'show', '-g', $ResourceGroup, '-n', $apimName, '--query', 'identity.principalId', '-o', 'tsv', '--subscription', $SubscriptionId) -AllowFailure
            $foundryId = Invoke-Az @('cognitiveservices', 'account', 'show', '-g', $FoundryResourceGroup, '-n', $FoundryAccount, '--query', 'id', '-o', 'tsv', '--subscription', $SubscriptionId) -AllowFailure
            if ($principal -match $guid -and $foundryId) {
                $assignments = Invoke-Az @('role', 'assignment', 'list', '--assignee', $principal, '--scope', $foundryId, '--query', '[].id', '-o', 'tsv', '--subscription', $SubscriptionId) -AllowFailure
                foreach ($assignment in (Split-NonEmptyLines $assignments)) {
                    [void](Invoke-TeardownAz "Role assignment $assignment" @('role', 'assignment', 'delete', '--ids', $assignment, '--subscription', $SubscriptionId) "az role assignment delete --ids $assignment --subscription $SubscriptionId" $teardownLeft)
                }
            }
            elseif ($principal -or $foundryId) {
                $teardownLeft.Add("Gateway role assignments were not deleted because the gateway principal or Foundry account id could not be read. Remove by listing assignments for the gateway principal on the Foundry account scope in subscription $SubscriptionId.")
            }

            $audience = Invoke-Az @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $apimName, '--named-value-id', 'entitlement-resolver-audience', '--query', 'value', '-o', 'tsv', '--subscription', $SubscriptionId) -AllowFailure
            if ($audience -match '\Aapi://([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\z') {
                $resolverAppId = $Matches[1]
                $displayName = Invoke-Az @('ad', 'app', 'show', '--id', $resolverAppId, '--query', 'displayName', '-o', 'tsv') -AllowFailure
                if ($displayName -eq $expectedResolverDisplayName) {
                    [void](Invoke-TeardownAz "Resolver app $resolverAppId" @('ad', 'app', 'delete', '--id', $resolverAppId) "az ad app delete --id $resolverAppId" $teardownLeft)
                }
                else {
                    $teardownLeft.Add("Resolver app $resolverAppId was not deleted because its displayName was '$displayName', not '$expectedResolverDisplayName'. Remove with: az ad app delete --id $resolverAppId")
                }
            }
            else {
                $teardownLeft.Add("Resolver app was not deleted because entitlement-resolver-audience could not be read from $apimName. Remove with: az ad app delete --id <app-id-from-entitlement-resolver-audience>")
            }
            [void](Invoke-TeardownAz "Resource group $ResourceGroup" @('group', 'delete', '--name', $ResourceGroup, '--yes', '--no-wait', '--subscription', $SubscriptionId) "az group delete --name $ResourceGroup --yes --subscription $SubscriptionId" $teardownLeft)
        }
        foreach ($groupId in $createdGroups) {
            [void](Invoke-TeardownAz "Group $groupId" @('ad', 'group', 'delete', '--group', $groupId) "az ad group delete --group $groupId" $teardownLeft)
        }
        $teardownOk = $teardownLeft.Count -eq 0
        if (-not $teardownOk) { $failed = $true }
        $detail = if ($teardownOk) { "deleted $ResourceGroup (if created), resolver app from entitlement-resolver-audience, role assignments, and $($createdGroups.Count) group(s) created by this run" } else { $teardownLeft -join ' ' }
        Add-Result 'teardown' $teardownOk $detail
    }
    if ($UseCurrentAzLogin -and $originalSubscription -match $guid -and $originalSubscription -ne $SubscriptionId) {
        Invoke-Az @('account', 'set', '--subscription', $originalSubscription) -AllowFailure | Out-Null
    }
    $results | ConvertTo-Json -Depth 4
}
if ($failed) { exit 1 }


