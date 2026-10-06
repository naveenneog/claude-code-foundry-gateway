
# A plain token prints as it is. Anything else is single-quoted, with every single-quote character doubled
# (PowerShell also reads U+2018-U+201B as single quotes), so a pasted rerun line passes the value and runs
# nothing else (P98 council round 2, Security).
function Format-ClaudeInstallerCommandValue {
    param([Parameter(Mandatory)][AllowEmptyString()][object]$Value)
    $text = [string]$Value
    if ($text -cmatch '^[A-Za-z0-9][A-Za-z0-9._:/@=+-]*$') { return $text }
    return "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($text) + "'"
}

function New-ClaudeInstallerCommandLine {
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($Command)
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [switch] -or $value -is [bool]) {
            if ([bool]$value) { $parts.Add("-$key") }
            continue
        }
        if ($null -eq $value -or [string]$value -eq '') { continue }
        if ($value -is [array]) {
            # One parameter with a comma list: a repeated parameter does not bind.
            $parts.Add("-$key"); $parts.Add((@($value | ForEach-Object { Format-ClaudeInstallerCommandValue $_ }) -join ','))
        }
        else { $parts.Add("-$key"); $parts.Add((Format-ClaudeInstallerCommandValue $value)) }
    }
    return ($parts -join ' ')
}

function Get-ClaudeInstallerDeveloperCountFromGroups {
    param([Parameter(Mandatory)][string]$StandardGroup, [Parameter(Mandatory)][string]$PremiumGroup)
    if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue) -or -not (Get-Command Get-GroupMemberOids -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1') }
    $token = Get-GraphToken
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($group in @($StandardGroup, $PremiumGroup | Where-Object { $_ -and $_ -ne 'none' })) {
        foreach ($m in @(Get-GroupMemberOids -GroupName $group -Token $token)) {
            if ($m.Oid) { $null = $ids.Add([string]$m.Oid) }
        }
    }
    return $ids.Count
}

function New-ClaudeInstallerChoiceOption {
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Label,
        [string]$Detail,
        [switch]$Recommended,
        [string]$Reason
    )
    if (Get-Command New-ClaudeChoiceOption -ErrorAction SilentlyContinue) {
        return New-ClaudeChoiceOption -Value $Value -Label $Label -Detail $Detail -Recommended:$Recommended -Reason $Reason
    }
    [pscustomobject]@{ Value = $Value; Label = $Label; Detail = $Detail; Recommended = [bool]$Recommended; Reason = $Reason }
}

function Resolve-ClaudeInstallerEntitlementStore {
    param(
        # Empty when -EntitlementStore was not passed: the installer passes its own value, '' by default.
        [AllowEmptyString()][ValidateSet('named-value','projection','')][string]$EntitlementStore,
        [Parameter(Mandatory)][int]$DeveloperCount,
        [Parameter(Mandatory)][int]$BuCeiling,
        [Parameter(Mandatory)][int]$ListCeiling,
        [switch]$Yes,
        [scriptblock]$Selector,
        [AllowEmptyString()][ValidateSet('named-value','projection','')][string]$DefaultStore = '',
        # The gateway's live entitlement-source, whether or not -EntitlementStore was passed.
        [AllowEmptyString()][string]$LiveStore = ''
    )
    $options = @(
        New-ClaudeInstallerChoiceOption -Value 'projection' -Label 'Cosmos projection (recommended)' `
            -Detail 'Deploys the private Cosmos entitlement store, resolver and switch. This is the default path for every team size.' `
            -Recommended -Reason $(if ($DefaultStore -eq 'named-value') { 'recommended default; this existing gateway currently uses named values and will migrate unless named-value is passed explicitly' } elseif ($DefaultStore -eq 'projection') { 'current store on this existing gateway' } else { 'recommended default for new gateways' })
        New-ClaudeInstallerChoiceOption -Value 'named-value' -Label 'Named values' `
            -Detail ("No Cosmos components. Intended for small teams only: about {0} developers in business-unit membership and about {1} per tier list." -f $BuCeiling, $ListCeiling) `
            -Reason $(if ($DefaultStore -eq 'named-value') { 'explicit small-team fallback; passing this keeps the gateway on named values' } else { 'small-team fallback when you do not want Cosmos components' })
    )
    $store = $EntitlementStore
    if (-not $store) {
        if ($Yes) { $store = 'projection' }
        elseif ($Selector) { $store = & $Selector $options }
        else { $store = 'projection' }
    }
    if ($store -eq 'named-value' -and $LiveStore -eq 'projection') {
        throw ("This gateway serves entitlement from the projection; the installer does not move it back to named values. " +
            "The rollback holds only a population within named-value capacity (about $BuCeiling developers in business-unit membership, about $ListCeiling per tier list): " +
            ".\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup <rg> -ApimName <apim> -Store named-value, then " +
            ".\scripts\Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim> -FailOnDrift, then entitlement-source set to named-value " +
            "(docs/PROJECTION-WORKBOOK.md, Rollback to named values). Without -EntitlementStore the installer keeps the projection. Nothing was created.")
    }
    if ($store -eq 'named-value' -and $DeveloperCount -gt $BuCeiling) {
        throw ("Named values hold about {0} developers in the business-unit map (about {1} in a tier list), and you declared {2}. Choose projection; raising the API Management SKU does not increase one named value's 4,096-character capacity. Nothing was created." -f $BuCeiling, $ListCeiling, $DeveloperCount)
    }
    [pscustomobject]@{ Store = $store; DeployProjection = ($store -eq 'projection'); Options = $options }
}

function Resolve-ClaudeInstallerResolverInboundAccess {
    param(
        [Parameter(Mandatory)][ValidateSet('BasicV2','StandardV2','PremiumV2')][string]$Sku,
        [Parameter(Mandatory)][ValidateSet('named-value','projection')][string]$EntitlementStore,
        [AllowEmptyString()][ValidateSet('private','public','')][string]$Requested
    )
    if ($EntitlementStore -ne 'projection') {
        return [pscustomobject]@{ Access = $(if ($Requested) { $Requested } else { 'private' }); Message = '' }
    }
    $access = if ($Requested) { $Requested } else { 'public' }
    if ($Sku -eq 'BasicV2' -and $access -eq 'private') {
        throw 'BasicV2 cannot use a private resolver because Basic v2 has no outbound VNet integration. Use -ResolverInboundAccess public or choose StandardV2/PremiumV2. Nothing was created.'
    }
    $message = if ($access -eq 'private') {
        'Projection resolver: private endpoint. Prerequisite: gateway outbound VNet integration into the projection network; Microsoft Learn integrate-vnet-outbound, updated 2025-12-04, documents outbound VNet integration for Standard v2 and Premium v2.'
    } else {
        'Projection resolver: public, Entra-authenticated endpoint. The resolver accepts only the gateway managed identity token; Cosmos remains private.'
    }
    [pscustomobject]@{ Access = $access; Message = $message }
}

function Assert-ClaudeInstallerProjectionPrerequisites {
    param(
        [int]$PowerShellMajor = $PSVersionTable.PSVersion.Major,
        [scriptblock]$CommandExists = { param($Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
    )
    if ($PowerShellMajor -lt 7) {
        throw 'Projection deployment requires PowerShell 7. Remedy: rerun this installer in pwsh.'
    }
    foreach ($tool in 'az','node','npm','tar') {
        if (-not (& $CommandExists $tool)) {
            $remedy = switch ($tool) {
                'az' { 'Install Azure CLI, then rerun.' }
                'node' { 'Install node (Node.js), then rerun.' }
                'npm' { 'Install npm with Node.js, then rerun.' }
                'tar' { 'Install tar or run on a shell where tar is on PATH, then rerun.' }
            }
            throw "Projection deployment requires $tool before any Azure write. Remedy: $remedy"
        }
    }
}

function Get-ClaudeInstallerProjectionPlan {
    param([switch]$WhatIf, [switch]$DeploySyncJob)
    $steps = @(
        'Check projection prerequisites',
        'Deploy projection resources',
        'Populate and compare the projection',
        'Switch entitlement-source to projection'
    )
    if ($DeploySyncJob) { $steps += 'Deploy optional sync job' }
    [pscustomobject]@{ Steps = $steps; Writes = $(if ($WhatIf) { @() } else { $steps }) }
}

# Runs one repository script the way the installer does: its output goes to the console, a thrown
# refusal becomes exit 1 with its message shown. Tests pass -InvokeScript to record the call instead.
# The parameters are a dictionary: a string array splatted into a script binds by position, so
# '-ResourceGroup','rg' would arrive as two positional values (measured in the P98 live run, where the
# name prefix reached -Sku).
function Invoke-ClaudeInstallerScript {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters, [scriptblock]$InvokeScript)
    if ($InvokeScript) { return [int](& $InvokeScript $ScriptPath $Parameters) }
    try { & $ScriptPath @Parameters | Out-Host; return 0 }
    catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor Red; return 1 }
}

# Choosing projection deploys it, then switches the gateway (ADR-0052, P98). The deployer deploys,
# populates and compares and leaves named values serving; its -FlipAfterCleanCompare run deploys nothing
# and switches only after the resolver checks, the compare and switch evidence (ADR-0051).
function Invoke-ClaudeInstallerProjectionDeployment {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidateSet('BasicV2','StandardV2','PremiumV2')][string]$Sku,
        [Parameter(Mandatory)][ValidateSet('private','public')][string]$ResolverInboundAccess,
        [Parameter(Mandatory)][string]$StandardGroup,
        [Parameter(Mandatory)][string]$PremiumGroup,
        [string]$SubscriptionId,
        [string]$ProjectionResolverAppId,
        [ValidateSet('Auto','Snapshot')][string]$CompareBaseline = 'Auto',
        # The store that serves until the switch, named in a failure (Invoke-ClaudeInstallerEntitlementSync).
        [ValidateSet('named-value','projection')][string]$ServingStore = 'named-value',
        [switch]$ResolverPublicByDefault,
        [switch]$WhatIf,
        [scriptblock]$InvokeScript
    )
    $serving = if ($ServingStore -eq 'projection') { 'the projection keeps serving' } else { 'named values keep serving' }
    $scriptPath = Join-Path $Root 'scripts\Deploy-ClaudeProjection.ps1'
    $common = [ordered]@{ ResourceGroup = $ResourceGroup; ApimName = $ApimName; NamePrefix = $NamePrefix; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup; CompareBaseline = $CompareBaseline }
    if ($SubscriptionId) { $common['SubscriptionId'] = $SubscriptionId }
    $deployParameters = [ordered]@{} + $common
    $deployParameters['Location'] = $Location; $deployParameters['Sku'] = $Sku; $deployParameters['ResolverInboundAccess'] = $ResolverInboundAccess
    if ($ProjectionResolverAppId) { $deployParameters['ResolverAppId'] = $ProjectionResolverAppId }
    if ($ResolverPublicByDefault) { $deployParameters['ResolverPublicByDefault'] = $true }
    $switchParameters = [ordered]@{} + $common
    $switchParameters['FlipAfterCleanCompare'] = $true
    if ($WhatIf) {
        $previewParameters = [ordered]@{} + $deployParameters
        $previewParameters['WhatIf'] = $true
        if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Parameters $previewParameters -InvokeScript $InvokeScript) -ne 0) {
            throw 'The projection deployment preview failed; nothing was created.'
        }
        Write-Host '    WhatIf: the switch follows the deployment; it reads the deployed resolver and Cosmos account, so a preview does not run it.' -ForegroundColor DarkGray
        return $true
    }
    $deployRerun = New-ClaudeInstallerCommandLine -Command '.\scripts\Deploy-ClaudeProjection.ps1' -Parameters $deployParameters
    if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Parameters $deployParameters -InvokeScript $InvokeScript) -ne 0) {
        throw "Projection deployment failed; $serving and nothing was switched. Rerun after fixing the reason with: $deployRerun"
    }
    if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Parameters $switchParameters -InvokeScript $InvokeScript) -ne 0) {
        $switchRerun = New-ClaudeInstallerCommandLine -Command '.\scripts\Deploy-ClaudeProjection.ps1' -Parameters $switchParameters
        throw "Projection switch refused; $serving. Rerun after fixing the reason with: $switchRerun"
    }
    return $true
}

# The optional sync job (ADR-0051) is deployed after the switch. A failure leaves the projection and the
# switch as they are, so it is reported with the rerun command rather than ending the install.
function Invoke-ClaudeInstallerSyncJobDeployment {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$StandardGroup,
        [Parameter(Mandatory)][string]$PremiumGroup,
        [Parameter(Mandatory)][string]$AlertEmail,
        [string]$SubscriptionId,
        [scriptblock]$InvokeScript
    )
    $jobParameters = [ordered]@{ ResourceGroup = $ResourceGroup; ApimName = $ApimName; NamePrefix = $NamePrefix
        StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup; AlertEmail = @($AlertEmail) }
    if ($SubscriptionId) { $jobParameters['SubscriptionId'] = $SubscriptionId }
    $scriptPath = Join-Path $Root 'scripts\Deploy-ClaudeProjectionRenewal.ps1'
    if ((Invoke-ClaudeInstallerScript -ScriptPath $scriptPath -Parameters $jobParameters -InvokeScript $InvokeScript) -ne 0) {
        $jobRerun = New-ClaudeInstallerCommandLine -Command '.\scripts\Deploy-ClaudeProjectionRenewal.ps1' -Parameters $jobParameters
        Write-Warning "The optional sync job was not deployed; the projection and the switch are unaffected. Rerun: $jobRerun"
        return $false
    }
    return $true
}
function Test-ClaudeInstallerShouldSyncNamedValues {
    param([ValidateSet('named-value','projection')][string]$EntitlementStore, [bool]$NewGateway)
    return ($EntitlementStore -eq 'named-value' -or -not $NewGateway)
}

# What the installer refreshes before the projection deployment, what the projection is compared with, and
# which store serves if a later step fails (P98 council round 2):
# - a gateway already on the projection: its named-value lists are an old rollback copy, so none are
#   refreshed (the deployer's populate step syncs the projection) and the comparison uses a fresh snapshot;
# - a new gateway that gets the projection: nothing serves yet and nothing is refreshed;
# - otherwise the named-value lists are refreshed. Above their capacity Sync-ClaudeAccess.ps1 refuses before
#   its first write, the lists stay as they were and keep serving, and the comparison uses a fresh snapshot.
function Invoke-ClaudeInstallerEntitlementSync {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$StandardGroup,
        [Parameter(Mandatory)][string]$PremiumGroup,
        [Parameter(Mandatory)][ValidateSet('named-value','projection')][string]$EntitlementStore,
        [AllowEmptyString()][string]$LiveEntitlementSource = '',
        [switch]$NewGateway,
        # The update's move with a tier that has no members (ADR-0054): the refresh may empty that tier's list.
        [switch]$AllowEmptyStandard,
        [switch]$AllowEmptyPremium,
        [scriptblock]$InvokeScript
    )
    $serving = if ($LiveEntitlementSource -eq 'projection') { 'projection' } else { 'named-value' }
    if ($EntitlementStore -eq 'projection' -and $serving -eq 'projection') {
        return [pscustomobject]@{ CompareBaseline = 'Snapshot'; ServingStore = 'projection'; Reason = 'already-projection' }
    }
    if (-not (Test-ClaudeInstallerShouldSyncNamedValues -EntitlementStore $EntitlementStore -NewGateway ([bool]$NewGateway))) {
        return [pscustomobject]@{ CompareBaseline = 'Auto'; ServingStore = 'named-value'; Reason = 'new-gateway' }
    }
    $parameters = [ordered]@{ ApimName = $ApimName; ResourceGroup = $ResourceGroup; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup; Store = 'named-value' }
    if ($AllowEmptyStandard) { $parameters['AllowEmptyStandard'] = $true }
    if ($AllowEmptyPremium) { $parameters['AllowEmptyPremium'] = $true }
    $scriptPath = Join-Path $Root 'scripts\Sync-ClaudeAccess.ps1'
    try {
        if ($InvokeScript) { $null = & $InvokeScript $scriptPath $parameters }
        else { & $scriptPath @parameters | Out-Host }
    }
    catch {
        if ($EntitlementStore -eq 'projection' -and $_.Exception.Message -match 'over the API Management limit of') {
            return [pscustomobject]@{ CompareBaseline = 'Snapshot'; ServingStore = 'named-value'; Reason = 'over-capacity' }
        }
        throw
    }
    return [pscustomobject]@{ CompareBaseline = 'Auto'; ServingStore = 'named-value'; Reason = 'refreshed' }
}

# A re-run deploys and switches the projection the gateway records in entitlement-projection-prefix (written by
# scripts/Deploy-ClaudeProjection.ps1), which need not match the API Management name (P98 council round 2).
function Get-ClaudeInstallerProjectionPrefix {
    param([AllowEmptyString()][string]$RecordedPrefix = '', [Parameter(Mandatory)][string]$NamePrefix)
    $recorded = ([string]$RecordedPrefix).Trim()
    if (-not $recorded) { return $NamePrefix }
    if ($recorded.Length -gt 37 -or $recorded -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "The gateway's entitlement-projection-prefix '$recorded' is not a projection name prefix (1-37 lowercase letters or digits, separated by single hyphens). Remedy: correct the named value or pass -EntitlementStore explicitly. Nothing was created."
    }
    return $recorded
}

# A re-run keeps the deployed resolver's network access. A read that fails stops the run before approval,
# rather than defaulting a private resolver to public (P98 council round 2). The resolver runs on a Flex
# Consumption plan (infra/resolver.bicep), for which az functionapp show returns the raw ARM resource, so the
# setting is read at its ARM path, properties.publicNetworkAccess (P98 confirmation round).
function Get-ClaudeInstallerResolverAccess {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$SiteName, [scriptblock]$InvokeAz)
    $arguments = @('resource', 'show', '-g', $ResourceGroup, '-n', $SiteName, '--resource-type', 'Microsoft.Web/sites', '--query', 'properties.publicNetworkAccess', '-o', 'tsv')
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $output = if ($InvokeAz) { @(& $InvokeAz $arguments) } else { @(az @arguments --only-show-errors 2>&1) }
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
    $text = ((@($output) | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $remedy = 'Remedy: pass -ResolverInboundAccess private or public. Nothing was created.'
    if ($code -ne 0) {
        if ($text -match '(?i)\(ResourceNotFound\)|was not found') { return '' }
        throw "Could not read the network access of resolver $SiteName in $ResourceGroup (az exit $code); a re-run keeps it. $remedy"
    }
    switch ($text) {
        'Disabled' { return 'private' }
        'Enabled' { return 'public' }
        default { throw "Resolver $SiteName in $ResourceGroup reports publicNetworkAccess '$text'; a re-run keeps the resolver's access only when it is Enabled or Disabled. $remedy" }
    }
}

function Get-ClaudeInstallerProjectionNextSteps {
    # Two separate next steps: one developer's change (the group change, then a targeted sync), and the
    # optional sync job, which the installer lists after the developer setup step.
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ApimName, [Parameter(Mandatory)][string]$NamePrefix, [string]$StandardGroup = 'claude-code-standard', [string]$PremiumGroup = 'claude-code-premium', [string]$SubscriptionId, [ValidateSet('not-requested','deployed','failed')][string]$SyncJobStatus = 'not-requested', [switch]$DeploySyncJob)
    if ($DeploySyncJob -and $SyncJobStatus -eq 'not-requested') { $SyncJobStatus = 'deployed' }
    $developer = [pscustomobject]@{ Title = 'Add or remove a developer in the projection'; Warn = $false; Detail = @(
        '        Add or remove the developer in the Entra group first, then publish that one projection record:'
        "        .\scripts\Sync-ClaudeAccess.ps1 -ResourceGroup $ResourceGroup -ApimName $ApimName -User <name-or-object-id>"
    ) }
    $syncParams = [ordered]@{ ResourceGroup = $ResourceGroup; ApimName = $ApimName; NamePrefix = $NamePrefix; StandardGroup = $StandardGroup; PremiumGroup = $PremiumGroup; AlertEmail = '<address>' }
    if ($SubscriptionId) { $syncParams['SubscriptionId'] = $SubscriptionId }
    $syncCommand = New-ClaudeInstallerCommandLine -Command '.\scripts\Deploy-ClaudeProjectionRenewal.ps1' -Parameters $syncParams
    $syncJob = if ($SyncJobStatus -eq 'deployed') {
        [pscustomobject]@{ Title = 'Optional: the sync job is deployed'; Warn = $false; Detail = @(
            '        A Privileged Role Administrator or Global Administrator grants its Microsoft Graph permission with the command the deployment printed; then start it with az containerapp job start.'
        ) }
    } elseif ($SyncJobStatus -eq 'failed') {
        [pscustomobject]@{ Title = 'Optional: the sync job was not deployed'; Warn = $true; Detail = @(
            '        The projection is serving, but the optional sync job failed. Rerun it after fixing the printed error:'
            "        $syncCommand"
        ) }
    } else {
        [pscustomobject]@{ Title = 'Optional: the sync job for very large directories'; Warn = $false; Detail = @(
            '        For very large directories, the job reads Microsoft Graph inside the network instead of sending a snapshot through the runner:'
            "        $syncCommand"
        ) }
    }
    return [pscustomobject]@{ Developer = $developer; SyncJob = $syncJob }
}