function Test-ClaudeEntitlementGroupGuid([AllowEmptyString()][string]$Value) {
    return ([string]$Value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
}

# entitlement-groups (ADR-0054): 'standard=<object id>,premium=<object id>|none'. Only object ids, so the
# value passes az.cmd and cmd.exe unchanged; names are read back from Graph.
function ConvertFrom-ClaudeEntitlementGroups([AllowEmptyString()][string]$Value) {
    $result = @{}
    foreach ($pair in ([string]$Value -split ',')) {
        if ($pair -match '^\s*(standard|premium)=([0-9a-fA-F-]{36}|none)\s*$') {
            $id = $Matches[2].ToLowerInvariant()
            if ($Matches[1] -eq 'standard' -and $id -eq 'none') {
                throw "entitlement-groups cannot set standard=none. The standard tier must name a Microsoft Graph group object id. Remedy: pass -StandardGroup <existing standard group> and -PremiumGroup <existing premium group or none>, then add -RecordGroups to replace the gateway record. Nothing was written."
            }
            if ($id -eq 'none' -or (Test-ClaudeEntitlementGroupGuid $id)) { $result[$Matches[1]] = $id }
        }
    }
    return $result
}

function ConvertTo-ClaudeEntitlementGroups([Parameter(Mandatory)][string]$StandardId, [AllowEmptyString()][string]$PremiumId) {
    if (-not (Test-ClaudeEntitlementGroupGuid $StandardId)) { throw "entitlement-groups needs the standard group's object id, not '$StandardId'." }
    $premium = if ($PremiumId) { $PremiumId } else { 'none' }
    if ($premium -ne 'none' -and -not (Test-ClaudeEntitlementGroupGuid $premium)) { throw "entitlement-groups needs the premium group's object id or none, not '$PremiumId'." }
    if ($premium -ne 'none' -and [string]::Equals($StandardId, $premium, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The standard and premium tier groups must be different object ids. Nothing was written.'
    }
    return "standard=$($StandardId.ToLowerInvariant()),premium=$($premium.ToLowerInvariant())"
}

function Resolve-ClaudeEntitlementGroupCandidate {
    param(
        [Parameter(Mandatory)][string]$Tier,
        [object[]]$Candidates,
        [Parameter(Mandatory)][scriptblock]$FindGroup
    )
    foreach ($candidate in $Candidates) {
        if (-not $candidate.Value) { continue }
        if ([string]$candidate.Value -eq 'none') {
            if ($Tier -eq 'standard') {
                return [pscustomobject]@{ Tier = $Tier; Argument = ''; Id = ''; Source = $candidate.Source; Found = $false; Absent = $false; Missing = 'none' }
            }
            return [pscustomobject]@{ Tier = $Tier; Argument = 'none'; Id = 'none'; Source = $candidate.Source; Found = $false; Absent = $true; Missing = ''; DisplayName = 'none' }
        }
        $group = & $FindGroup ([string]$candidate.Value)
        if ($group -and $group.id) {
            $id = ([string]$group.id).ToLowerInvariant()
            return [pscustomobject]@{ Tier = $Tier; Argument = $id; Id = $id; Source = $candidate.Source; Found = $true; Absent = $false; Missing = ''; DisplayName = [string]$candidate.Value }
        }
        if ($candidate.Authoritative) {
            return [pscustomobject]@{ Tier = $Tier; Argument = ''; Id = ''; Source = $candidate.Source; Found = $false; Absent = $false; Missing = [string]$candidate.Value }
        }
    }
    return [pscustomobject]@{ Tier = $Tier; Argument = ''; Id = ''; Source = ''; Found = $false; Absent = $false; Missing = '' }
}

function Resolve-ClaudeEntitlementGroupsForSync {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [string]$StandardGroup,
        [string]$PremiumGroup,
        [Parameter(Mandatory)][scriptblock]$GetNamedValue,
        [Parameter(Mandatory)][scriptblock]$FindGroup
    )
    $raw = [string](& $GetNamedValue 'entitlement-groups')
    $recorded = ConvertFrom-ClaudeEntitlementGroups $raw
    $recordStandard = [string](& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') StandardGroup -ForApimName $ApimName 3>$null)
    $recordPremium = [string](& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') PremiumGroup -ForApimName $ApimName 3>$null)
    $standard = Resolve-ClaudeEntitlementGroupCandidate -Tier 'standard' -FindGroup $FindGroup -Candidates @(
        @{ Value = $StandardGroup; Source = 'parameter'; Authoritative = $true },
        @{ Value = $recorded['standard']; Source = 'gateway entitlement-groups'; Authoritative = $true },
        @{ Value = $recordStandard; Source = 'decision record'; Authoritative = $true },
        @{ Value = 'claude-code-standard'; Source = 'default name'; Authoritative = $true }
    )
    $premium = Resolve-ClaudeEntitlementGroupCandidate -Tier 'premium' -FindGroup $FindGroup -Candidates @(
        @{ Value = $PremiumGroup; Source = 'parameter'; Authoritative = $true },
        @{ Value = $recorded['premium']; Source = 'gateway entitlement-groups'; Authoritative = $true },
        @{ Value = $recordPremium; Source = 'decision record'; Authoritative = $true },
        @{ Value = 'claude-code-premium'; Source = 'default name'; Authoritative = $true }
    )
    $decisionStandard = $null
    if ($recordStandard) {
        $decisionStandard = Resolve-ClaudeEntitlementGroupCandidate -Tier 'standard' -FindGroup $FindGroup -Candidates @(
            @{ Value = $recordStandard; Source = 'decision record'; Authoritative = $true }
        )
    }
    $decisionPremium = $null
    if ($recordPremium) {
        $decisionPremium = Resolve-ClaudeEntitlementGroupCandidate -Tier 'premium' -FindGroup $FindGroup -Candidates @(
            @{ Value = $recordPremium; Source = 'decision record'; Authoritative = $true }
        )
    }
    foreach ($group in @($standard, $premium)) {
        if ($group.Missing -and $group.Source -eq 'gateway entitlement-groups') {
            $switch = if ($group.Tier -eq 'standard') { '-StandardGroup' } else { '-PremiumGroup' }
            throw "U160: the $($group.Tier) tier group '$($group.Missing)' recorded in entitlement-groups was not found in Microsoft Graph. Remedy: pass -StandardGroup <existing standard group> and -PremiumGroup <existing premium group or none>, then add -RecordGroups to replace the gateway record, or restore the recorded group. Nothing was written."
        }
        if ($group.Missing -and $group.Tier -eq 'standard') {
            throw "The standard tier group '$($group.Missing)' from the $($group.Source) was not found in Microsoft Graph. Remedy: pass -StandardGroup <existing standard group> and -PremiumGroup <existing premium group or none>, then add -RecordGroups if this replaces entitlement-groups. Nothing was written."
        }
        if ($group.Missing) {
            $group.Argument = 'none'
            $group.Id = 'none'
            $group.Absent = $true
            $group.Missing = ''
        }
    }
    if ($premium.Id -ne 'none' -and [string]::Equals([string]$standard.Id, [string]$premium.Id, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The standard and premium tier groups must be different object ids. Nothing was written.'
    }
    return [pscustomobject]@{ Standard = $standard; Premium = $premium; Recorded = $recorded; Raw = $raw; DecisionStandard = $decisionStandard; DecisionPremium = $decisionPremium }
}
