# The customer sheet (one JSON file) as the single input of a client-run deployment (P124, ADR-0070).
# New-ClaudeAnswersFromSheet turns its gateway, network, projection, deployments and profiles into the installer's
# answers object; nothing here calls Azure.

$script:ClaudeSheetFamilyCodes = @{ Ha = 'haiku'; So = 'sonnet'; Op = 'opus'; Fa = 'fable'; My = 'mythos' }

function Get-ClaudeSheetValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function New-ClaudeAnswersFromSheet {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Sheet)
    $problems = [Collections.Generic.List[string]]::new()
    $gateway = Get-ClaudeSheetValue $Sheet 'gateway'
    $network = Get-ClaudeSheetValue $Sheet 'network'
    $projection = Get-ClaudeSheetValue $Sheet 'projection'
    $deployments = Get-ClaudeSheetValue $Sheet 'deployments'
    $need = { param($Obj, [string]$Path, [string]$Name) $v = Get-ClaudeSheetValue $Obj $Name; if ($null -eq $v -or [string]$v -match '^\s*$|^<.*>$') { $problems.Add("$Path.$Name is required.") }; $v }

    $answers = [ordered]@{}
    $answers.SubscriptionId = & $need $gateway 'gateway' 'subscriptionId'
    $answers.ResourceGroup = & $need $gateway 'gateway' 'resourceGroup'
    $answers.ExistingApimName = & $need $gateway 'gateway' 'apimName'
    $answers.Location = & $need $gateway 'gateway' 'location'
    $answers.PublisherEmail = & $need $gateway 'gateway' 'publisherEmail'
    $answers.Sku = $(if (Get-ClaudeSheetValue $gateway 'apimSku') { Get-ClaudeSheetValue $gateway 'apimSku' } else { 'StandardV2' })
    $answers.FoundryAccount = & $need $gateway 'gateway' 'foundryAccount'
    $answers.FoundryResourceGroup = & $need $gateway 'gateway' 'foundryResourceGroup'
    $auth = $(if (Get-ClaudeSheetValue $gateway 'foundryAuthentication') { [string](Get-ClaudeSheetValue $gateway 'foundryAuthentication') } else { 'managed-identity' })
    if ($auth -notin 'managed-identity', 'client-credentials') { $problems.Add("gateway.foundryAuthentication must be managed-identity or client-credentials, not '$auth'.") }
    $answers.FoundryAuthenticationMode = $auth
    if ($auth -eq 'client-credentials') {
        $answers.FoundrySubscriptionId = & $need $gateway 'gateway' 'foundrySubscriptionId'
        $answers.FoundryEndpoint = & $need $gateway 'gateway' 'foundryEndpoint'
        $answers.FoundryTenantId = & $need $gateway 'gateway' 'foundryTenantId'
        $answers.FoundryClientId = & $need $gateway 'gateway' 'foundryClientId'
        $answers.FoundryCredentialNamedValue = $(if (Get-ClaudeSheetValue $gateway 'foundryCredentialNamedValue') { Get-ClaudeSheetValue $gateway 'foundryCredentialNamedValue' } else { 'foundry-crosstenant-client-secret' })
    }
    elseif ((Get-ClaudeSheetValue $gateway 'foundrySubscriptionId') -and (Get-ClaudeSheetValue $gateway 'foundrySubscriptionId') -ne $answers.SubscriptionId) {
        $problems.Add('gateway.foundrySubscriptionId differs from gateway.subscriptionId: managed identity is granted only inside the gateway subscription; set gateway.foundryAuthentication to client-credentials.')
    }

    $prefix = & $need $projection 'projection' 'namePrefix'
    $answers.NamePrefix = $prefix
    $answers.EntitlementStore = 'projection'
    $answers.ResolverInboundAccess = $(if (Get-ClaudeSheetValue $projection 'resolverInboundAccess') { Get-ClaudeSheetValue $projection 'resolverInboundAccess' } else { 'private' })
    # The installer deploys the job without a schedule; the Schedule phase sets projection.syncInterval once the job
    # has a Graph grant and one proven run (docs/PRODUCTION-ACCESS-PROFILES.md section 10).
    $answers.ProjectionSyncInterval = 'manual'
    if (Get-ClaudeSheetValue $projection 'revocationWindowSeconds') { $answers.RevocationWindowSeconds = [int](Get-ClaudeSheetValue $projection 'revocationWindowSeconds') }
    $org = Get-ClaudeSheetValue $Sheet 'organisation'
    if (Get-ClaudeSheetValue $org 'requestsPerMinutePerUser') { $answers.CallsPerMinute = [int](Get-ClaudeSheetValue $org 'requestsPerMinutePerUser') }

    if ($network) {
        $subnets = Get-ClaudeSheetValue $network 'subnets'
        $zones = Get-ClaudeSheetValue $network 'privateDnsZones'
        $answers.ProjectionNetworkMode = 'existing'
        $answers.ProjectionVnetId = & $need $network 'network' 'vnetId'
        foreach ($pair in @(@('endpoints', 'ProjectionEndpointsSubnetId'), @('runner', 'ProjectionRunnerSubnetId'), @('resolver', 'ProjectionResolverSubnetId'), @('renewal', 'ProjectionRenewalSubnetId'), @('apim', 'ProjectionApimSubnetId'))) {
            $answers[$pair[1]] = & $need $subnets 'network.subnets' $pair[0]
        }
        foreach ($pair in @(@('cosmos', 'ProjectionCosmosDnsZoneId'), @('sites', 'ProjectionSitesDnsZoneId'), @('blob', 'ProjectionBlobDnsZoneId'), @('queue', 'ProjectionQueueDnsZoneId'), @('table', 'ProjectionTableDnsZoneId'))) {
            $v = Get-ClaudeSheetValue $zones $pair[0]
            if ($v) { $answers[$pair[1]] = $v }
        }
    }
    else { $answers.ProjectionNetworkMode = 'managed' }

    $compat = Get-ClaudeSheetValue $gateway 'compatibilityGroups'
    $answers.StandardGroup = & $need $compat 'gateway.compatibilityGroups' 'standard'
    $answers.PremiumGroup = & $need $compat 'gateway.compatibilityGroups' 'premium'

    # Allowed families per compatibility tier, from the profiles' model sets; each family maps to its deployment name.
    $sets = Get-ClaudeSheetValue $Sheet 'modelSets'
    $byTier = @{ standard = [Collections.Generic.HashSet[string]]::new(); premium = [Collections.Generic.HashSet[string]]::new() }
    foreach ($p in @(Get-ClaudeSheetValue $Sheet 'profiles')) {
        $tier = if ([string]$p.level -like 'Standard-*') { 'standard' } else { 'premium' }
        foreach ($f in @(Get-ClaudeSheetValue $sets ([string]$p.modelSet))) { $null = $byTier[$tier].Add([string]$f) }
    }
    foreach ($tier in 'standard', 'premium') {
        $names = @(foreach ($f in 'haiku', 'sonnet', 'opus', 'fable', 'mythos') {
            if (-not $byTier[$tier].Contains($f)) { continue }
            $d = Get-ClaudeSheetValue $deployments $f
            if (-not $d -or [string]$d -match '^<.*>$') { $problems.Add("deployments.$f is required: a $tier profile allows $f.") } else { [string]$d }
        })
        if ($names.Count) { $answers[$(if ($tier -eq 'standard') { 'StandardModels' } else { 'PremiumModels' })] = @($names) }
    }
    [pscustomobject]@{ Answers = $answers; Problems = @($problems); SyncInterval = [string](Get-ClaudeSheetValue $projection 'syncInterval'); AlertEmail = @(Get-ClaudeSheetValue $projection 'alertEmail') }
}
