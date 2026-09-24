<#
.SYNOPSIS
    Connects the gateway to a Turnstile deployment, or shows, changes or removes the connection.

.DESCRIPTION
    Nothing about Turnstile is written into this repository's scripts. This discovers it
    from the Turnstile resource group and stores the result in one named value on the
    gateway, `turnstile-integration`, which Export-ClaudeTurnstileUsage.ps1 and
    Sync-ClaudeTurnstileGovernance.ps1 read. Run it again to change any setting.

    Discovered, never assumed:

      the web app     the one whose settings carry ENTRA_CLIENT_ID, with the tenant pin
                      and admin role that make it admin-only
      the event hub   the one Turnstile's telemetry function consumes, from its
                      EVENT_HUB_NAME and EVENT_HUB_CONNECTION settings

    Access is Microsoft Entra only. The identity that will run the export and the sync
    (you, or a workload identity for a schedule) is granted what it needs and nothing
    else: Azure Event Hubs Data Sender on that one hub and the Turnstile admin app role.
    A workload identity also gets read access to the gateway's named values, its Application
    Insights resource and the workspace behind it.

.PARAMETER TurnstileResourceGroup
    The resource group the Turnstile deployment created.

.PARAMETER ExporterPrincipalId
    Object id of a service principal or managed identity that will run the export and
    the sync on a schedule. Omit to connect for yourself only.

.PARAMETER PriceSource
    Gateway prices usage from this repository's price book, so Turnstile and the
    chargeback report agree. Turnstile leaves pricing to Turnstile's model registry.

.PARAMETER BudgetAuthority
    Gateway keeps budgets authored here and mirrored to Turnstile. Turnstile makes
    Turnstile's budget page the place budgets are edited, pulled back into the gateway by
    Sync-ClaudeTurnstileGovernance.ps1 -Direction FromTurnstile.

.EXAMPLE
    ./scripts/Connect-ClaudeTurnstile.ps1 -TurnstileResourceGroup rg-turnstile-prod

.EXAMPLE
    ./scripts/Connect-ClaudeTurnstile.ps1 -Show

.EXAMPLE
    ./scripts/Connect-ClaudeTurnstile.ps1 -BudgetAuthority Turnstile

.EXAMPLE
    ./scripts/Connect-ClaudeTurnstile.ps1 -Disconnect
#>
[CmdletBinding()]
param(
    [string]$TurnstileResourceGroup,
    [string]$ExporterPrincipalId,
    [ValidateSet('Gateway', 'Turnstile')][string]$PriceSource,
    [ValidateSet('Gateway', 'Turnstile')][string]$BudgetAuthority,
    [Nullable[bool]]$PersonBudgets = $null,
    [switch]$Show,
    [switch]$Disconnect,
    [switch]$SkipValidation,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstile.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')

$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw 'Not signed in. Run: az login' }
if (-not $ApimName) {
    $ApimName = az apim list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    if (-not $ApimName) { throw "No API Management instance in $ResourceGroup. Pass -ApimName." }
}

$current = ConvertFrom-ClaudeTurnstileIntegrationValue (Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue)

if ($Show) {
    if (-not $current) { Write-Host "$ApimName is not connected to Turnstile."; return }
    return [pscustomobject]$current
}

if ($Disconnect) {
    if (-not $current) { Write-Host "$ApimName is not connected to Turnstile."; return }
    # An empty value rather than a delete: the exporter and sync then say "not connected"
    # instead of failing on a missing named value, and a reconnect is a plain update.
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue -Value ' '
    Write-Host "Disconnected $ApimName from Turnstile at $($current['url']). Role assignments are left in place; remove them in Access control if the identity should lose them."
    return
}

# --- Discover, or reuse what is stored ---------------------------------------------------
$rg = if ($TurnstileResourceGroup) { $TurnstileResourceGroup } elseif ($current) { [string]$current['resourceGroup'] } else { $null }
if (-not $rg) { throw 'Pass -TurnstileResourceGroup: the resource group the Turnstile deployment created.' }

$apiApp = $null
$entra = @{}
foreach ($app in @(az webapp list -g $rg --query "[].name" -o tsv 2>$null)) {
    $settings = az webapp config appsettings list -g $rg -n $app --query "[?starts_with(name, 'ENTRA_')].{n:name, v:value}" -o json 2>$null | ConvertFrom-Json
    $client = @($settings | Where-Object { $_.n -eq 'ENTRA_CLIENT_ID' -and $_.v })
    if ($client.Count) {
        $apiApp = $app
        foreach ($s in $settings) { $entra[$s.n] = $s.v }
        break
    }
}
if (-not $apiApp) { throw "No web app in $rg carries ENTRA_CLIENT_ID. Is this a Turnstile resource group, deployed with Microsoft Entra sign-in?" }
$tenants = @()
if ($entra['ENTRA_TENANT_IDS']) { $tenants = @($entra['ENTRA_TENANT_IDS'] | ConvertFrom-Json) }
if (-not $entra['ENTRA_ADMIN_ROLE'] -or -not $tenants.Count) {
    throw ("$apiApp is not admin-only: ENTRA_ADMIN_ROLE and ENTRA_TENANT_IDS must both be set for the export and sync to authenticate " +
        'with Microsoft Entra tokens. Redeploy Turnstile with entraAdminRole and entraTenantId (docs/TURNSTILE.md).')
}
$hostName = az webapp show -g $rg -n $apiApp --query defaultHostName -o tsv
$clientId = [string]$entra['ENTRA_CLIENT_ID']

$telemetry = @(az functionapp list -g $rg --query "[].name" -o tsv 2>$null) | Where-Object {
    (az functionapp config appsettings list -g $rg -n $_ --query "[?name=='EVENT_HUB_NAME'].value" -o tsv 2>$null)
} | Select-Object -First 1
if (-not $telemetry) { throw "No function app in $rg names an EVENT_HUB_NAME. Turnstile's telemetry function is where usage is read." }
$hubName = az functionapp config appsettings list -g $rg -n $telemetry --query "[?name=='EVENT_HUB_NAME'].value" -o tsv
$fqdn = az functionapp config appsettings list -g $rg -n $telemetry --query "[?name=='EVENT_HUB_CONNECTION__fullyQualifiedNamespace'].value" -o tsv
$namespace = ([string]$fqdn).Split('.')[0]
$hubId = az eventhubs eventhub show -g $rg --namespace-name $namespace -n $hubName --query id -o tsv 2>$null
if (-not $hubId) { throw "The telemetry function reads $namespace/$hubName, but that hub is not in $rg." }

$settings = [ordered]@{
    version           = 1
    url               = "https://$hostName"
    clientId          = $clientId
    tenantId          = [string]$tenants[0]
    scope             = "api://$clientId/Turnstile.Manage"
    eventHubNamespace = $namespace
    eventHubName      = $hubName
    resourceGroup     = $rg
    priceSource       = $(if ($PriceSource) { $PriceSource } elseif ($current) { [string]$current['priceSource'] } else { 'Gateway' })
    budgetAuthority   = $(if ($BudgetAuthority) { $BudgetAuthority } elseif ($current) { [string]$current['budgetAuthority'] } else { 'Gateway' })
    personBudgets     = $(if ($null -ne $PersonBudgets) { [bool]$PersonBudgets } elseif ($current) { [bool]$current['personBudgets'] } else { $false })
    connectedAt       = [datetime]::UtcNow.ToString('o')
    connectedBy       = (az account show --query user.name -o tsv)
}
$value = ConvertTo-ClaudeTurnstileIntegrationValue -Settings $settings

# --- Grant the identity that will run the export and sync ---------------------------------
$grants = New-Object System.Collections.Generic.List[string]
if (-not $ExporterPrincipalId) {
    # Connecting for yourself: you will run the export interactively, so you need to send
    # to the hub. The admin app role you already have, through the Turnstile admin group.
    $me = az ad signed-in-user show --query id -o tsv 2>$null
    if ($me) {
        $mine = az role assignment list --assignee $me --role 'Azure Event Hubs Data Sender' --scope $hubId --query "[0].id" -o tsv 2>$null
        if (-not $mine) {
            az role assignment create --assignee-object-id $me --assignee-principal-type User --role 'Azure Event Hubs Data Sender' --scope $hubId -o none
            $grants.Add("Azure Event Hubs Data Sender on $hubName, for you")
        }
    }
}
if ($ExporterPrincipalId) {
    $sp = az ad sp show --id $ExporterPrincipalId --query "{id:id, name:displayName}" -o json 2>$null | ConvertFrom-Json
    if (-not $sp) { throw "$ExporterPrincipalId is not a service principal or managed identity in this tenant. Users are granted through the Turnstile admin group." }
    function Add-Role([string]$Role, [string]$Scope) {
        $existing = az role assignment list --assignee $ExporterPrincipalId --role $Role --scope $Scope --query "[0].id" -o tsv 2>$null
        if (-not $existing) {
            az role assignment create --assignee-object-id $ExporterPrincipalId --assignee-principal-type ServicePrincipal --role $Role --scope $Scope -o none
            $grants.Add("$Role on $(Split-Path $Scope -Leaf)")
        }
    }
    Add-Role 'Azure Event Hubs Data Sender' $hubId
    $apimId = az apim show -g $ResourceGroup -n $ApimName --query id -o tsv
    Add-Role 'API Management Service Reader Role' $apimId
    $telemetryName = & (Join-Path $PSScriptRoot 'Get-ClaudeTelemetry.ps1') -ResourceGroup $ResourceGroup -ApimName $ApimName
    # The export finds the ledger through the Application Insights resource the gateway logs
    # to, so the identity reads that one resource as well as the workspace behind it.
    $component = az resource show -g $ResourceGroup -n $telemetryName.AppInsights --resource-type Microsoft.Insights/components --query "{id:id, workspace:properties.WorkspaceResourceId}" -o json | ConvertFrom-Json
    if ($component.id) { Add-Role 'Reader' $component.id }
    if ($component.workspace) { Add-Role 'Log Analytics Reader' $component.workspace }

    # The Turnstile admin app role, assigned directly: a workload identity cannot join a group.
    $turnstileSp = az ad sp show --id $clientId --query id -o tsv
    $roleId = az ad sp show --id $clientId --query "appRoles[?value=='$($entra['ENTRA_ADMIN_ROLE'])'].id | [0]" -o tsv
    $assigned = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$turnstileSp/appRoleAssignedTo" --query "value[?principalId=='$ExporterPrincipalId' && appRoleId=='$roleId'] | length(@)" -o tsv
    if ([int]$assigned -eq 0) {
        $body = @{ principalId = $ExporterPrincipalId; resourceId = $turnstileSp; appRoleId = $roleId } | ConvertTo-Json -Compress
        $tmp = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($tmp, $body)
            az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$turnstileSp/appRoleAssignedTo" --body "@$tmp" --headers 'Content-Type=application/json' -o none
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        $grants.Add("$($entra['ENTRA_ADMIN_ROLE']) app role on Turnstile")
    }
}

Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $script:TurnstileIntegrationNamedValue -Value $value

# --- Prove it: an admin token reaches the API, admin-only ---------------------------------
$validation = 'skipped'
if (-not $SkipValidation) {
    $token = (az account get-access-token --scope $settings.scope --query accessToken -o tsv 2>$null)
    if (-not $token) { $validation = "could not get a token for $($settings.scope): is your account in the Turnstile admin group?" }
    else {
        try {
            $catalog = Invoke-RestMethod -Uri "$($settings.url)/api/v1/enterprise-catalog" -Headers @{ Authorization = "Bearer $token" }
            $validation = "ok - catalog is $($catalog.source)"
        }
        catch { $validation = "refused: $($_.Exception.Message)" }
    }
}

[pscustomobject][ordered]@{
    Gateway         = $ApimName
    Turnstile       = $settings.url
    EventHub        = "$namespace/$hubName"
    Tenant          = $settings.tenantId
    AdminRole       = $entra['ENTRA_ADMIN_ROLE']
    PriceSource     = $settings.priceSource
    BudgetAuthority = $settings.budgetAuthority
    PersonBudgets   = $settings.personBudgets
    Granted         = $(if ($grants.Count) { $grants.ToArray() } else { @() })
    Validation      = $validation
}
