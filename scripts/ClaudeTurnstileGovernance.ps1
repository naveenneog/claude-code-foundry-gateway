<#
.SYNOPSIS
    The gateway's business units, teams, tiers and budgets in Turnstile, and the connection settings.

.DESCRIPTION
    Dot-source this after ClaudeBusinessUnit.ps1 and ClaudeTurnstile.ps1. ClaudeTurnstile.ps1
    maps and sends usage; this file maps structure and budgets, and reads and writes the
    turnstile-integration named value that Connect-ClaudeTurnstile.ps1 stores. docs/TURNSTILE.md
    explains both.
#>

# --- Governance: the gateway's business units, teams and budgets in Turnstile ---------
#
# The gateway is where these are enforced (docs/TURNSTILE.md). Turnstile's catalog is
# organization -> department -> person, so a business unit becomes an organization, a
# team becomes a department under it, and every unit also gets a department of its own
# for the people mapped to it directly - which is what usage rows already carry as their
# department, so a person discovered from usage always lands somewhere that exists.

function ConvertTo-ClaudeTurnstileCatalog {
    <#
    .SYNOPSIS
        The Turnstile organization catalog for the gateway's registry.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Registry,
        [System.Collections.IDictionary]$Parents = @{},
        [switch]$IncludeUnassigned
    )
    $organizations = New-Object System.Collections.Generic.List[object]
    $departments = New-Object System.Collections.Generic.List[object]
    $units = @($Registry | Where-Object { $_ -and $_.Id })
    $byId = @{}
    foreach ($u in $units) { $byId[[string]$u.Id] = $u }
    foreach ($u in $units) {
        if ($Parents.Contains([string]$u.Id)) { continue }
        $ref = if ($u.Group) { "entra-group:$($u.Group)" } else { $null }
        $organizations.Add([ordered]@{
            id = [string]$u.Id; name = $(if ($u.Group) { [string]$u.Group } else { [string]$u.Id })
            external_ref = $ref; attributes = [ordered]@{ tokens_per_month = [long]$u.TokensPerMonth; source = 'claude-gateway' }
        })
        $departments.Add([ordered]@{
            id = [string]$u.Id; name = ('{0} (direct members)' -f $(if ($u.Group) { $u.Group } else { $u.Id })); parent_id = [string]$u.Id
            external_ref = $ref; attributes = [ordered]@{ source = 'claude-gateway'; kind = 'unit-direct' }
        })
        foreach ($teamId in @($Parents.Keys | Where-Object { [string]$Parents[$_] -eq [string]$u.Id })) {
            $team = $byId[[string]$teamId]
            if (-not $team) { continue }
            $departments.Add([ordered]@{
                id = [string]$team.Id; name = $(if ($team.Group) { [string]$team.Group } else { [string]$team.Id }); parent_id = [string]$u.Id
                external_ref = $(if ($team.Group) { "entra-group:$($team.Group)" } else { $null })
                attributes = [ordered]@{ tokens_per_month = [long]$team.TokensPerMonth; source = 'claude-gateway'; kind = 'team' }
            })
        }
    }
    if ($IncludeUnassigned) {
        # The gateway's word for an entitled developer in no business unit. Usage rows carry
        # it as the department, so without it those people could never be listed.
        $organizations.Add([ordered]@{ id = 'unassigned'; name = 'Unassigned'; external_ref = $null; attributes = [ordered]@{ source = 'claude-gateway' } })
        $departments.Add([ordered]@{ id = 'unassigned'; name = 'Unassigned'; parent_id = 'unassigned'; external_ref = $null; attributes = [ordered]@{ source = 'claude-gateway'; kind = 'unassigned' } })
    }
    if ($organizations.Count -eq 0) { throw 'The gateway has no business units, and Turnstile needs at least one organization.' }
    $default = if ($IncludeUnassigned) { 'unassigned' } else { [string]$departments[0].id }
    return [ordered]@{
        organizations         = $organizations.ToArray()
        departments           = $departments.ToArray()
        default_department_id = $default
    }
}

function Get-ClaudeTurnstileBudgetPlan {
    <#
    .SYNOPSIS
        The Turnstile budgets that mirror the gateway's monthly unit budgets.

    .DESCRIPTION
        Organizations first, then departments: Turnstile checks a department's budget
        against its organization's, so the parent must exist before the child is set. A
        unit's direct-members department gets none, because the gateway has no separate
        budget for them - their spend counts against the unit.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Registry,
        [System.Collections.IDictionary]$Parents = @{}
    )
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($u in @($Registry | Where-Object { $_ -and -not $Parents.Contains([string]$_.Id) -and [long]$_.TokensPerMonth -gt 0 })) {
        $plan.Add([pscustomobject]@{ ScopeType = 'organization'; ScopeId = [string]$u.Id; TokenLimit = [long]$u.TokensPerMonth })
    }
    foreach ($t in @($Registry | Where-Object { $_ -and $Parents.Contains([string]$_.Id) -and [long]$_.TokensPerMonth -gt 0 })) {
        $plan.Add([pscustomobject]@{ ScopeType = 'department'; ScopeId = [string]$t.Id; TokenLimit = [long]$t.TokensPerMonth })
    }
    return , $plan.ToArray()
}

function Compare-ClaudeTurnstileBudgets {
    <#
    .SYNOPSIS
        Budgets edited in Turnstile that differ from the gateway's registry.

    .DESCRIPTION
        Only a business unit (a Turnstile organization) or a team (a department that is a
        team) can carry a gateway budget. A unit's direct-members department, a department
        the gateway does not know, and a budget removed in Turnstile are reported but never
        applied: removing a budget in the gateway is a decision for Set-ClaudeBusinessUnit,
        not a side effect of a sync.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Registry,
        [System.Collections.IDictionary]$Parents = @{},
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TurnstileItems
    )
    $byId = @{}
    foreach ($u in @($Registry | Where-Object { $_ })) { $byId[[string]$u.Id] = $u }
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($TurnstileItems | Where-Object { $_.scope_type -in 'organization', 'department' })) {
        $id = [string]$item.scope_id
        $unit = $byId[$id]
        $isTeam = $Parents.Contains($id)
        $applies = $unit -and (($item.scope_type -eq 'organization' -and -not $isTeam) -or ($item.scope_type -eq 'department' -and $isTeam))
        if (-not $applies) { continue }
        $now = $item.token_limit
        if ($null -eq $now) {
            $changes.Add([pscustomobject]@{ Id = $id; ScopeType = $item.scope_type; Was = [long]$unit.TokensPerMonth; Now = $null; Apply = $false; Reason = 'removed in Turnstile; not applied' })
            continue
        }
        if ([long]$now -ne [long]$unit.TokensPerMonth) {
            $changes.Add([pscustomobject]@{ Id = $id; ScopeType = $item.scope_type; Was = [long]$unit.TokensPerMonth; Now = [long]$now; Apply = $true; Reason = "set in Turnstile by $($item.updated_by)" })
        }
    }
    return , $changes.ToArray()
}

function Get-ClaudeTierMonthlyTokens {
    <#
    .SYNOPSIS
        A tier's daily quota as a monthly figure, for Turnstile's monthly person budgets.

    .DESCRIPTION
        The gateway enforces the daily quota per request; Turnstile shows monthly budgets. The
        monthly figure is the most a person could use in the month under the daily quota, so
        a person at 100% in Turnstile used their quota every day - it is a display of the
        entitlement, not a second limit.
    #>
    param(
        [Parameter(Mandatory = $true)][long]$DailyQuota,
        [Parameter(Mandatory = $true)][ValidatePattern('^\d{4}-(0[1-9]|1[0-2])$')][string]$Period
    )
    if ($DailyQuota -le 0) { throw 'A daily quota must be greater than zero.' }
    $year, $month = $Period -split '-'
    return $DailyQuota * [datetime]::DaysInMonth([int]$year, [int]$month)
}

# --- Integration settings: discovered at connect time, stored on the gateway -----------
#
# Nothing about a Turnstile deployment is written into these scripts. Connect-ClaudeTurnstile.ps1
# discovers it from the Turnstile resource group and stores it in one named value on the
# gateway; the exporter and the sync read it, and the same command changes it later.

$script:TurnstileIntegrationNamedValue = 'turnstile-integration'
$script:TurnstileIntegrationFields = @('version', 'url', 'clientId', 'tenantId', 'scope', 'eventHubNamespace', 'eventHubName',
    'resourceGroup', 'priceSource', 'budgetAuthority', 'governanceAuthority', 'personBudgets', 'connectedAt', 'connectedBy')

function ConvertTo-ClaudeTurnstileIntegrationValue {
    <#
    .SYNOPSIS
        Validates integration settings and renders them for the named value.
    #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings)
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($Settings.Keys)) { if ($script:TurnstileIntegrationFields -notcontains [string]$k) { $problems.Add("unknown setting '$k'") } }
    if ([string]$Settings['url'] -notmatch '^https://[a-z0-9.-]+(:\d+)?/?$') { $problems.Add('url must be the https origin of the Turnstile web app') }
    if ([string]$Settings['clientId'] -notmatch '^[0-9a-f-]{36}$') { $problems.Add('clientId must be the Turnstile app registration''s client id') }
    if ([string]$Settings['tenantId'] -notmatch '^[0-9a-f-]{36}$') { $problems.Add('tenantId must be a tenant id') }
    if ([string]$Settings['scope'] -notmatch '^api://[0-9a-f-]{36}/\S+$') { $problems.Add('scope must be api://<client id>/<scope>') }
    if ([string]$Settings['priceSource'] -notin 'Gateway', 'Turnstile') { $problems.Add('priceSource must be Gateway or Turnstile') }
    if ([string]$Settings['budgetAuthority'] -notin 'Gateway', 'Turnstile') { $problems.Add('budgetAuthority must be Gateway or Turnstile') }
    if ($Settings.Contains('governanceAuthority') -and [string]$Settings['governanceAuthority'] -notin 'Gateway', 'Turnstile') { $problems.Add('governanceAuthority must be Gateway or Turnstile') }
    if ($Settings.Contains('eventHubNamespace') -and [string]$Settings['eventHubNamespace'] -and [string]$Settings['eventHubNamespace'] -notmatch '^[A-Za-z][A-Za-z0-9-]{4,48}[A-Za-z0-9]$') { $problems.Add('eventHubNamespace is not a valid namespace name') }
    # key=value;key=value, with no quotes anywhere. On Windows az runs through cmd.exe,
    # which strips double quotes from arguments - measured: JSON written this way came back
    # as {version:1,url:https://...} - so every named value here is quote-free.
    foreach ($k in @($Settings.Keys)) {
        $v = [string]$Settings[$k]
        if ($Settings[$k] -is [bool]) { $v = $v.ToLowerInvariant() }
        if ($v -match '[;="]') { $problems.Add("'$k' cannot contain ; = or a double quote") }
    }
    if ($problems.Count) { throw ("Turnstile integration settings are invalid: " + ($problems -join '; ')) }
    $pairs = foreach ($k in $script:TurnstileIntegrationFields) {
        if (-not $Settings.Contains($k)) { continue }
        $v = if ($Settings[$k] -is [bool]) { ([string]$Settings[$k]).ToLowerInvariant() } else { [string]$Settings[$k] }
        "$k=$v"
    }
    $value = $pairs -join ';'
    if ($value.Length -gt 4096) { throw "Turnstile integration settings are $($value.Length) characters; a named value holds 4096." }
    return $value
}

function ConvertFrom-ClaudeTurnstileIntegrationValue {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $settings = [ordered]@{}
    foreach ($pair in ($Value.Trim() -split ';' | Where-Object { $_ })) {
        $eq = $pair.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $pair.Substring(0, $eq)
        $v = $pair.Substring($eq + 1)
        if ($script:TurnstileIntegrationFields -notcontains $k) { continue }
        $settings[$k] = switch ($k) {
            'version' { [int]$v }
            'personBudgets' { $v -eq 'true' }
            default { $v }
        }
    }
    if (-not $settings.Contains('url')) { return $null }
    return $settings
}

function Resolve-ClaudeTurnstileSetting {
    <#
    .SYNOPSIS
        A parameter when given, otherwise the stored setting, otherwise an error naming both.
    #>
    param($Explicit, $Settings, [string]$Name, [string]$Parameter, $Default = $null)
    if ($null -ne $Explicit -and "$Explicit" -ne '') { return $Explicit }
    if ($Settings -and $Settings.Contains($Name) -and $null -ne $Settings[$Name] -and "$($Settings[$Name])" -ne '') { return $Settings[$Name] }
    if ($null -ne $Default) { return $Default }
    throw "No ${Name}: pass -$Parameter, or connect the gateway to Turnstile with ./scripts/Connect-ClaudeTurnstile.ps1."
}

function Get-ClaudeGatewayWorkspaceId {
    <#
    .SYNOPSIS
        The Log Analytics workspace behind the gateway's Application Insights.
    #>
    param([Parameter(Mandatory = $true)][string]$ResourceGroup, [Parameter(Mandatory = $true)][string]$ApimName)
    $telemetry = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName
    $workspace = az resource show -g $ResourceGroup -n $telemetry.AppInsights --resource-type Microsoft.Insights/components --query properties.WorkspaceResourceId -o tsv 2>$null
    if (-not $workspace) { throw "The gateway's Application Insights is not workspace-based, so there is no ledger to read." }
    return [string]$workspace
}

function Get-ClaudeTurnstileTierQuery {
    <#
    .SYNOPSIS
        Each person's most recent tier, from the gateway's own caller trace.

    .DESCRIPTION
        Keyed on the address, because that is how Turnstile knows people. Taken from
        the trace rather than the entitlement lists because the trace records the tier the
        gateway actually applied, and it already carries the address beside the object id.
    #>
    param([ValidateRange(1, 90)][int]$Days = 30)
    return @"
AppTraces
| where TimeGenerated > ago(${Days}d)
| where Properties.RequestId != ""
| extend user = tolower(tostring(Properties.User)), tier = tolower(tostring(Properties.Tier))
| where user contains "@" and isnotempty(tier)
| summarize arg_max(TimeGenerated, tier) by user
| project user, tier
"@
}
