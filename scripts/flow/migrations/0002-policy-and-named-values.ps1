<#
.SYNOPSIS
    Migration 0002: align deployed policy and policy-referenced named values with this release.
#>

function Get-ClaudeFlowMigrationInfo {
    [pscustomobject]@{
        Name = '0002-policy-and-named-values'
        Title = 'Update gateway policy and policy named values'
        DecisionKey = 'gatewayPolicy'
        DependsOn = @('0001-record-schema-v2')
        Actions = @('Update')
    }
}

function Test-ClaudePolicyHasLifecycleMarkers {
    param([AllowEmptyString()][string]$Policy)
    if (-not $Policy) { return $false }
    foreach ($marker in @('usd-budgets', 'usd-budget-state', 'external-idp-extra-audience', 'urn:disabled:claude-extra-audience', 'entitlement-source')) {
        if (-not $Policy.Contains($marker)) { return $false }
    }
    return $true
}

function Get-ClaudeFlowMigrationPlan {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $root = Get-ClaudeFlowLifecycleRepoRoot
    $policyPath = Join-Path $root 'infra\policy.xml'
    $desiredPolicy = [IO.File]::ReadAllText($policyPath)
    $desiredHash = Get-ClaudeFlowLifecycleStringHash -Text $desiredPolicy
    $livePolicy = if ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'policy') { [string]$Discovery.policy } else { '' }
    $liveHash = if ($livePolicy) { Get-ClaudeFlowLifecycleStringHash -Text $livePolicy } elseif ($Discovery -and $Discovery.policyHash) { [string]$Discovery.policyHash } else { '' }
    $policyCurrent = ($liveHash -eq $desiredHash) -or (Test-ClaudePolicyHasLifecycleMarkers -Policy $livePolicy)
    $refs = @(Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences -PolicyPath $policyPath)
    $fragments = @(Get-ClaudeFlowLifecyclePolicyFragmentIds -PolicyPath $policyPath)
    $templateDefaults = Get-ClaudeFlowLifecycleTemplateNamedValueDefaults
    $liveNamed = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery
    $liveFragments = @{}
    if ($Discovery -and $Discovery.PSObject.Properties.Name -contains 'policyFragments') { foreach ($fragment in @($Discovery.policyFragments)) { $liveFragments[[string]$fragment] = $true } }
    $missing = @($refs | Where-Object { -not $liveNamed.ContainsKey($_) })
    $missingFragments = @($fragments | Where-Object { -not $liveFragments.ContainsKey($_) })
    $normalizeDisabledAudience = $liveNamed.ContainsKey('external-idp-extra-audience') -and
        [string]::IsNullOrWhiteSpace([string]$liveNamed['external-idp-extra-audience'])
    $unknownDefaults = @($missing | Where-Object { -not $templateDefaults.Contains($_) -or $null -eq $templateDefaults[$_].Value })
    $actions = @()
    if ($liveHash -and -not $policyCurrent) {
        $actions += New-ClaudeFlowAction -Verb Update -Target 'apim policy claude-foundry' -Detail "policy hash $liveHash -> $desiredHash"
    }
    elseif (-not $liveHash) {
        $actions += New-ClaudeFlowAction -Verb Check -Target 'apim policy claude-foundry' -Detail 'live policy hash unavailable; apply will read before writing'
    }
    foreach ($name in $missing) {
        $detail = if ($templateDefaults.Contains($name) -and $null -ne $templateDefaults[$name].Value) { 'create with template-compatible default' } else { 'manual value required before apply' }
        $actions += New-ClaudeFlowAction -Verb Create -Target "named value $name" -Detail $detail
    }
    foreach ($fragment in $missingFragments) {
        $actions += New-ClaudeFlowAction -Verb Create -Target "policy fragment $fragment" -Detail 'create reusable APIM policy fragment before the API policy includes it'
    }
    if ($normalizeDisabledAudience) {
        $actions += New-ClaudeFlowAction -Verb Update -Target 'named value external-idp-extra-audience' -Detail 'whitespace/empty -> disabled URI sentinel'
    }
    if (-not $actions.Count) { return New-ClaudeFlowPlan -Step '0002-policy-and-named-values' -Summary 'Policy hash and policy-referenced named values already match this release.' }
    New-ClaudeFlowPlan -Step '0002-policy-and-named-values' `
        -Summary 'Deploy the current policy and create the named values it references before the policy can execute them.' `
        -Actions $actions `
        -Implications @('A named-value snapshot is required before apply.', 'New named values are derived from infra/policy.xml references; the migration refuses policy references that do not have a template default.') `
        -Requires @('API Management Service Contributor or equivalent', 'Backup-ClaudeGateway.ps1 succeeds') `
        -Reversible $true `
        -Rollback 'Restore the pre-update snapshot with Restore-ClaudeGateway.ps1.' `
        -Data @{
            DesiredPolicyHash = $desiredHash
            LivePolicyHash = $liveHash
            PolicyCurrent = $policyCurrent
            PolicyPath = $policyPath
            PolicyNamedValues = $refs
            PolicyFragments = $fragments
            MissingNamedValues = $missing
            MissingPolicyFragments = $missingFragments
            NormalizeDisabledAudience = $normalizeDisabledAudience
            UnknownDefaults = $unknownDefaults
            Target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record -Discovery $Discovery
        }
}

function Invoke-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)]$Plan)
    if (Test-ClaudeFlowPlanIsNoop $Plan) { return @{} }
    if (@($Plan.Data.UnknownDefaults).Count) {
        throw 'Policy references named values with no safe template default: ' + (@($Plan.Data.UnknownDefaults) -join ', ')
    }
    $target = $Plan.Data.Target
    # The update read the gateway in this subscription (ADR-0054); passed only as an ID, because az.cmd re-reads other
    # text. Checked before the backup, which reads the gateway.
    if ([string]$target.SubscriptionId -and -not (Test-ClaudeFlowSubscriptionId ([string]$target.SubscriptionId))) {
        throw "The plan's subscription '$($target.SubscriptionId)' is not a subscription id, so the policy migration cannot name where it writes; nothing was written. Remedy: record the id (az account show --query id -o tsv) in the decision record, then plan again."
    }
    Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $Plan
    $root = Get-ClaudeFlowLifecycleRepoRoot
    . (Join-Path $root 'scripts\ApimNamedValue.ps1')
    $scope = if ([string]$target.SubscriptionId) { @{ SubscriptionId = [string]$target.SubscriptionId } } else { @{} }
    $tokenScope = if ($scope.Count) { @('--subscription', $scope.SubscriptionId) } else { @() }
    $defaults = Get-ClaudeFlowLifecycleTemplateNamedValueDefaults
    foreach ($name in @($Plan.Data.MissingNamedValues)) {
        Set-ApimNamedValue -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Id $name -Value ([string]$defaults[$name].Value) @scope
    }
    if ($Plan.Data.NormalizeDisabledAudience) {
        Set-ApimNamedValue -ResourceGroup $target.ResourceGroup -ApimName $target.ApimName -Id 'external-idp-extra-audience' -Value 'urn:disabled:claude-extra-audience' @scope
    }
    $subscription = if ($target.SubscriptionId) { $target.SubscriptionId } else { az account show --query id -o tsv }
    $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv @tokenScope
    foreach ($fragment in @($Plan.Data.MissingPolicyFragments)) {
        $fragmentPath = Join-Path (Join-Path $root 'infra') "$fragment.xml"
        $fragmentXml = [IO.File]::ReadAllText($fragmentPath)
        $fragmentBody = @{ properties = @{ format = 'rawxml'; value = $fragmentXml } } | ConvertTo-Json -Depth 5
        $fragmentUri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.ApiManagement/service/$($target.ApimName)/policyFragments/$fragment`?api-version=2024-05-01"
        Invoke-RestMethod -Uri $fragmentUri -Method Put -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $fragmentBody | Out-Null
    }
    $policyXml = [IO.File]::ReadAllText([string]$Plan.Data.PolicyPath)
    $body = @{ properties = @{ format = 'rawxml'; value = $policyXml } } | ConvertTo-Json -Depth 5
    $uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.ApiManagement/service/$($target.ApimName)/apis/claude-foundry/policies/policy?api-version=2024-05-01"
    Invoke-RestMethod -Uri $uri -Method Put -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body | Out-Null
    $release = Get-ClaudeFlowReleaseInfo
    Add-ClaudeDecisionHistory -Record $Record -Action Update -Decision gatewayPolicy -From $Plan.Data.LivePolicyHash -To $Plan.Data.DesiredPolicyHash -Commit $release.commit
    @{ policyHash = $Plan.Data.DesiredPolicyHash; namedValues = @($Plan.Data.MissingNamedValues) }
}

function Test-ClaudeFlowMigration {
    param([Parameter(Mandatory = $true)]$Record, $Discovery)
    $root = Get-ClaudeFlowLifecycleRepoRoot
    $desiredHash = Get-ClaudeFlowLifecycleStringHash -Text ([IO.File]::ReadAllText((Join-Path $root 'infra\policy.xml')))
    $livePolicy = if ($Discovery -and $Discovery.policy) { [string]$Discovery.policy } else { '' }
    $liveHash = if ($livePolicy) { Get-ClaudeFlowLifecycleStringHash -Text $livePolicy } elseif ($Discovery -and $Discovery.policyHash) { [string]$Discovery.policyHash } else { '' }
    $hashOk = ($liveHash -eq $desiredHash) -or (Test-ClaudePolicyHasLifecycleMarkers -Policy $livePolicy)
    $liveNamed = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $Discovery
    $missing = @(Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences | Where-Object { -not $liveNamed.ContainsKey($_) })
    [pscustomobject]@{
        Step = '0002-policy-and-named-values'
        Passed = ($hashOk -and $missing.Count -eq 0)
        Checks = @(
            @{ Name = 'policy hash'; Passed = $hashOk; Evidence = "live=$liveHash desired=$desiredHash"; Fix = 'Apply the policy migration.' },
            @{ Name = 'named values'; Passed = ($missing.Count -eq 0); Evidence = "missing=$($missing -join ',')"; Fix = 'Create missing named values or rerun the migration.' }
        )
    }
}
