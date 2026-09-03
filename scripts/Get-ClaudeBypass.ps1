<#
.SYNOPSIS
    Who can reach Foundry without going through the gateway.

.DESCRIPTION
    Every control this repository builds - entitlement, the organisation ceiling,
    per-user budgets, the model allowlist - governs traffic that passes through
    the gateway. A principal holding data-plane access directly on the Foundry
    account skips all of it by pointing a client at the endpoint.

    The role set is derived, not hardcoded. Each role assigned at or above the
    Foundry account is looked up and classified by its actual dataActions, which
    is the only way to keep up with roles Azure adds. Measured on the reference
    deployment 2026-09-03: four roles grant Cognitive Services data actions, and
    "Foundry User" grants the same Microsoft.CognitiveServices/* as "Cognitive
    Services User" - a role no version of this documentation had mentioned.

    Inherited assignments count. A role granted at subscription or resource group
    scope still applies to the Foundry account, and does not appear unless asked
    for.

    Findings are graded, because they are not equally serious:

      full     Microsoft.CognitiveServices/* or a wildcard. Can call the
               Messages API directly. This is a bypass.
      partial  Data actions scoped to some paths. Whether the Anthropic route is
               among them depends on the role and the deployment, so it is
               reported for review rather than asserted either way.
      read     Read-only data actions. Not an inference bypass, but still
               data-plane access to a governed resource.

    Exits 1 when any principal other than the gateway holds a full grant, so this
    can run as a check rather than only as a report.

.PARAMETER FoundryAccount
    The Foundry (AIServices) account. Discovered from the resource group when not
    given.

.PARAMETER IncludeRead
    Also list read-only data-plane holders.

.PARAMETER AsJson
    Emit JSON instead of a table.

.EXAMPLE
    ./scripts/Get-ClaudeBypass.ps1

.EXAMPLE
    ./scripts/Get-ClaudeBypass.ps1 -AsJson > bypass.json
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [string]$FoundryAccount,
    [string]$ApimName,
    [switch]$IncludeRead,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }

if (-not $ApimName) { $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null }

# Which Foundry account? The one the gateway actually calls, read from its API
# backend, not the first one in the resource group. A group can hold several
# Cognitive Services accounts, and auditing the wrong one returns a clean result
# for a resource nobody is using.
if (-not $FoundryAccount -and $ApimName) {
    $serviceUrl = az apim api show -g $ResourceGroup --service-name $ApimName --api-id claude-foundry --query serviceUrl -o tsv 2>$null
    if ($serviceUrl -and $serviceUrl -match '^https://([^./]+)\.') {
        $candidate = $Matches[1]
        if (az cognitiveservices account show -g $ResourceGroup -n $candidate --query id -o tsv 2>$null) {
            $FoundryAccount = $candidate
            Write-Verbose "Foundry account taken from the gateway backend: $FoundryAccount"
        }
    }
}
if (-not $FoundryAccount) {
    $accounts = az cognitiveservices account list -g $ResourceGroup --query "[].name" -o tsv 2>$null
    $names = @($accounts -split '\r?\n' | Where-Object { $_ })
    if (-not $names.Count) { throw "No Cognitive Services account in $ResourceGroup. Pass -FoundryAccount." }
    if ($names.Count -gt 1) {
        Write-Warning ("$ResourceGroup holds {0} Cognitive Services accounts and the gateway's backend could not be read. Auditing '{1}'. Pass -FoundryAccount to choose: {2}" -f $names.Count, $names[0], ($names -join ', '))
    }
    $FoundryAccount = $names[0]
}
$scope = az cognitiveservices account show -g $ResourceGroup -n $FoundryAccount --query id -o tsv 2>$null
if (-not $scope) { throw "Foundry account '$FoundryAccount' not found in $ResourceGroup." }

# The gateway is meant to hold this role. Flagging it would teach the operator to
# ignore the output.
$gatewayPrincipal = $null
if ($ApimName) { $gatewayPrincipal = az apim show -g $ResourceGroup -n $ApimName --query "identity.principalId" -o tsv 2>$null }

Write-Verbose "scope: $scope"
$assignments = az role assignment list --scope $scope --include-inherited -o json 2>$null | ConvertFrom-Json
if (-not $assignments) { throw "Could not read role assignments on $FoundryAccount. Reader on the account is enough." }

# Classify each distinct role by what it actually grants, rather than by name.
$classification = @{}
foreach ($roleName in ($assignments | Select-Object -ExpandProperty roleDefinitionName -Unique)) {
    $def = az role definition list --name $roleName -o json 2>$null | ConvertFrom-Json
    if (-not $def) { $classification[$roleName] = @{ Grade = 'unknown'; Actions = 'role definition not readable' }; continue }

    $dataActions = @($def[0].permissions.dataActions) | Where-Object { $_ }
    $relevant = @($dataActions | Where-Object { $_ -like '*CognitiveServices*' -or $_ -eq '*' })

    if (-not $relevant.Count) { $classification[$roleName] = @{ Grade = 'none'; Actions = '' }; continue }

    $full = @($relevant | Where-Object { $_ -eq '*' -or $_ -eq 'Microsoft.CognitiveServices/*' })
    $readOnly = @($relevant | Where-Object { $_ -notmatch '/read$' })

    $grade = if ($full.Count) { 'full' }
             elseif (-not $readOnly.Count) { 'read' }
             else { 'partial' }
    $classification[$roleName] = @{ Grade = $grade; Actions = ($relevant -join '; ') }
}

$findings = @()
foreach ($a in $assignments) {
    $c = $classification[$a.roleDefinitionName]
    if (-not $c -or $c.Grade -eq 'none') { continue }
    $isGateway = ($gatewayPrincipal -and ($a.principalId -eq $gatewayPrincipal))

    $findings += [ordered]@{
        principal       = $(if ($a.principalName) { $a.principalName } else { $a.principalId })
        principal_id    = $a.principalId
        principal_type  = $a.principalType
        role            = $a.roleDefinitionName
        grade           = $c.Grade
        data_actions    = $c.Actions
        assigned_at     = $a.scope
        inherited       = ($a.scope -ne $scope)
        is_gateway      = [bool]$isGateway
        remove          = "az role assignment delete --assignee $($a.principalId) --role `"$($a.roleDefinitionName)`" --scope $($a.scope)"
    }
}

$bypass = @($findings | Where-Object { $_.grade -eq 'full' -and -not $_.is_gateway })
$review = @($findings | Where-Object { $_.grade -eq 'partial' -and -not $_.is_gateway })
$reads  = @($findings | Where-Object { $_.grade -eq 'read' -and -not $_.is_gateway })

$result = [ordered]@{
    foundry_account = $FoundryAccount
    scope           = $scope
    gateway         = [ordered]@{ apim = $ApimName; principal_id = $gatewayPrincipal }
    bypass          = $bypass
    review          = $review
    read_only       = $reads
    counts          = [ordered]@{ bypass = $bypass.Count; review = $review.Count; read_only = $reads.Count }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 10
    if ($bypass.Count) { exit 1 }
    exit 0
}

Write-Host ''
Write-Host ("Foundry account  {0}" -f $FoundryAccount) -ForegroundColor Cyan
Write-Host ("Gateway identity {0}" -f $(if ($gatewayPrincipal) { "$gatewayPrincipal ($ApimName)" } else { 'not found - every holder below will be listed' }))
Write-Host ''

function Show-Group($title, $rows, $colour) {
    if (-not $rows.Count) { return }
    Write-Host $title -ForegroundColor $colour
    foreach ($r in $rows) {
        $where = if ($r.inherited) { 'inherited from ' + ($r.assigned_at -split '/')[-1] } else { 'direct' }
        Write-Host ("  {0,-46} {1,-16} {2,-26} {3}" -f $r.principal, $r.principal_type, $r.role, $where)
    }
    Write-Host ''
}

Show-Group "Can call Foundry directly - these bypass every gateway control ($($bypass.Count))" $bypass 'Red'
Show-Group "Partial data-plane access - review whether the Anthropic route is covered ($($review.Count))" $review 'Yellow'
if ($IncludeRead) { Show-Group "Read-only data-plane access ($($reads.Count))" $reads 'DarkGray' }

if (-not $bypass.Count) {
    Write-Host '  No principal other than the gateway holds full data-plane access.' -ForegroundColor Green
    if (-not $IncludeRead -and $reads.Count) { Write-Host ("  {0} read-only holder(s) not shown. Add -IncludeRead." -f $reads.Count) -ForegroundColor DarkGray }
    exit 0
}

Write-Host 'To remove one:' -ForegroundColor DarkGray
Write-Host ('  ' + $bypass[0].remove) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Check each principal before removing it. A deployment pipeline or another' -ForegroundColor DarkGray
Write-Host '  application may rely on the assignment; the point is that it is ungoverned,' -ForegroundColor DarkGray
Write-Host '  not that it is necessarily wrong.' -ForegroundColor DarkGray
Write-Host ''
Write-Host ("{0} principal(s) can reach Foundry without passing through the gateway." -f $bypass.Count) -ForegroundColor Red
exit 1
