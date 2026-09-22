<#
.SYNOPSIS
    Admin-side check for the direct Foundry path: is this resource set up so
    developers can actually use it?

.DESCRIPTION
    Test-FoundryDirect.ps1 answers "is this machine configured?". This answers
    the question before it - "is there anything here to configure against?" -
    and it is the one an admin can answer without touching a developer's box.

    Read-only. It creates nothing, changes nothing, and needs only reader
    rights on the resource plus directory read to resolve role assignments.

    Every check here came from a real failure:

      - a resource in a tenant the developer was not signed in to
      - roles that read like the obvious AI roles and serve no Claude
      - a resource carrying one deployment, where clients assumed three
      - a Disabled deployment that lists normally and refuses every call
      - entitlement granted person by person, which does not scale

.PARAMETER Resource
    Foundry (AIServices) account name.

.PARAMETER ResourceGroup
    Its resource group. Discovered when omitted.

.PARAMETER ClientId
    Optional. An app registration developers would use for Claude Desktop's
    own device-code sign-in. Checked for being a public client.

.EXAMPLE
    ./scripts/Test-FoundryDirectAdmin.ps1 -Resource ai-contosohub530569751908

.EXAMPLE
    ./scripts/Test-FoundryDirectAdmin.ps1 -Resource pcsaif56c293bd -ResourceGroup RG-AzureARC
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Resource,
    [string]$ResourceGroup,
    [string]$ClientId,
    # Read-only is the default and the reason this is safe to hand to anyone.
    # -Fix proposes each repair and asks before making it; -Force skips the
    # asking, for a run nobody is watching.
    [switch]$Fix,
    [switch]$Force,
    # Pins the subscription. Without it the resource is searched for across
    # every subscription this account can see - 86 on one measured account,
    # where the active one did not hold the resource.
    [string]$SubscriptionId,
    # Principal to entitle when the resource has nobody who can use it. An
    # Entra group object id is the scalable answer; a user object id works.
    [string]$GrantTo
)

$ErrorActionPreference = 'Continue'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $results.Add([pscustomobject]@{ Check = $Name; Status = $(if ($Ok) { 'PASS' } else { 'FAIL' }) })
    $colour = 'Red'; $tag = 'FAIL'
    if ($Ok) { $colour = 'Green'; $tag = 'PASS' }
    Write-Host ("  [{0}] {1}" -f $tag, $Name) -ForegroundColor $colour
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }

# Repairs are collected as we go and applied at the end, so the operator sees
# the whole picture before anything changes. Each one carries the command it
# would run: a repair you cannot read is a repair you cannot refuse.
$repairs = [System.Collections.Generic.List[object]]::new()
function Add-Repair {
    param([string]$What, [string]$Why, [scriptblock]$Do, [string]$Command)
    $repairs.Add([pscustomobject]@{ What = $What; Why = $Why; Do = $Do; Command = $Command })
}

Write-Host ''
Write-Host 'Foundry direct - admin readiness' -ForegroundColor Cyan
Write-Host "Resource : $Resource"
Write-Host ''

# 1. Signed in, and to which tenant ------------------------------------------
# Stated rather than assumed: a resource in another tenant is the single most
# common developer failure, and it presents as an RBAC message.
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Add-Result 'Azure CLI signed in' $false "Run 'az login --tenant <guid>'."
    Write-Host ''
    Write-Host 'Cannot continue without a sign-in.' -ForegroundColor Red
    exit 1
}
Add-Result 'Azure CLI signed in' $true "$($acct.user.name)  tenant=$($acct.tenantId)"

# 2. The resource exists, and is the right kind ------------------------------
# az cognitiveservices account list only sees the active subscription. An admin
# with rights over many of them gets "not visible in this tenant" for a
# resource sitting one subscription away, which reads as a permissions fault
# and is not one. Look where told, then where pointed, then everywhere.
$subPin = @()
if ($SubscriptionId) { $subPin = @('--subscription', $SubscriptionId) }
$foundSub = $SubscriptionId

if (-not $ResourceGroup) {
    $ResourceGroup = az cognitiveservices account list @subPin --query "[?name=='$Resource'].resourceGroup | [0]" -o tsv 2>$null
    if ($ResourceGroup) { $ResourceGroup = $ResourceGroup.Trim() }
}
if (-not $ResourceGroup -and -not $SubscriptionId) {
    # Resource Graph covers every subscription in this tenant in one call.
    $q = "resources | where type =~ 'microsoft.cognitiveservices/accounts' and name =~ '$Resource' | project resourceGroup, subscriptionId"
    $raw = az graph query -q $q --first 5 -o json 2>$null | ConvertFrom-Json
    if ($raw -and $raw.data -and @($raw.data).Count -gt 0) {
        $hit = @($raw.data)[0]
        $ResourceGroup = $hit.resourceGroup
        $foundSub = $hit.subscriptionId
        $subPin = @('--subscription', $foundSub)
        $subName = az account list --all --query "[?id=='$foundSub'].name | [0]" -o tsv 2>$null
        if ($subName) { $subName = $subName.Trim() } else { $subName = $foundSub }
        Warn "the resource is not in your active subscription"
        Note "found in $subName ($foundSub) - every check below names it explicitly"
        $fs2 = $foundSub
        Add-Repair -What 'pin the Azure CLI to that subscription' `
            -Why 'az commands you run by hand would otherwise look in the wrong one' `
            -Command "az account set --subscription $fs2" `
            -Do {
                az account set --subscription $fs2 2>$null
                return ($LASTEXITCODE -eq 0)
            }.GetNewClosure()
    }
}
if (-not $ResourceGroup) {
    Add-Result 'Resource is visible in this tenant' $false `
        "$Resource is not visible from tenant $($acct.tenantId). Developers signed in here will be refused with a message about a principal, not about tenants."
    Write-Host ''
    Write-Host 'Cannot continue: sign in to the tenant that owns the resource.' -ForegroundColor Red
    exit 1
}
Add-Result 'Resource is visible in this tenant' $true "resource group $ResourceGroup"

$acc = az cognitiveservices account show -n $Resource -g $ResourceGroup @subPin -o json 2>$null | ConvertFrom-Json
if ($acc) {
    $kindOk = ($acc.kind -eq 'AIServices')
    Add-Result 'Account kind serves Anthropic models' $kindOk "kind=$($acc.kind) sku=$($acc.sku.name) location=$($acc.location)"
    if (-not $kindOk) { Note 'Claude is served by AIServices accounts. Other kinds do not carry Anthropic deployments.' }

    # The endpoint developers are told to use is derived from the name, not
    # from properties.endpoint - worth showing both when they differ.
    $derived = "https://$Resource.services.ai.azure.com/anthropic"
    Note "developers use $derived"
}

# 3. Deployments -------------------------------------------------------------
# Every resource carries different deployments; clients must be told what is
# here rather than assume a house standard.
$deps = az cognitiveservices account deployment list -n $Resource -g $ResourceGroup @subPin -o json 2>$null | ConvertFrom-Json
$anthropic = @($deps | Where-Object { $_.properties.model.format -eq 'Anthropic' })
$live = @($anthropic | Where-Object { $_.properties.provisioningState -eq 'Succeeded' })
$dead = @($anthropic | Where-Object { $_.properties.provisioningState -ne 'Succeeded' })

Add-Result 'Anthropic deployments exist' ($live.Count -gt 0) $(
    if ($live.Count -gt 0) { "$($live.Count) usable: " + (($live | ForEach-Object { $_.name }) -join ', ') }
    else { 'none in Succeeded state - developers have nothing to call' })

foreach ($d in $live) {
    if ($d.name -ne $d.properties.model.name) { Note "  $($d.name)  ->  $($d.properties.model.name)" }
}
if ($dead.Count -gt 0) {
    Warn "$($dead.Count) Anthropic deployment(s) not usable: " + (($dead | ForEach-Object { "$($_.name) [$($_.properties.provisioningState)]" }) -join ', ')
    Note 'These list normally and refuse every call. Clients must skip them.'
}

# Which model families are present decides what clients can honestly offer.
if ($live.Count -gt 0) {
    $fam = @{}
    foreach ($f in @('opus', 'sonnet', 'haiku')) {
        $hit = $live | Where-Object { $_.properties.model.name -match $f -or $_.name -match $f } | Select-Object -First 1
        if ($hit) { $fam[$f] = $hit.name }
    }
    $missing = @(@('opus', 'sonnet', 'haiku') | Where-Object { -not $fam.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        Warn "no $($missing -join ', ') deployment here"
        Note 'Clients point those aliases at a deployment that does exist. Left unset,'
        Note 'Claude Code falls back to its own built-in names, which are not deployed'
        Note 'on any Foundry resource, and the session fails as DeploymentNotFound.'
    }
}

# 4. Who can actually use it -------------------------------------------------
# Entitlement on this path is an Azure role, not group membership - but a role
# granted TO a group is how it scales.
$scope = az cognitiveservices account show -n $Resource -g $ResourceGroup @subPin --query id -o tsv 2>$null
if ($scope) { $scope = $scope.Trim() }
$assignments = @()
if ($scope) {
    $raw = az role assignment list --scope $scope --include-inherited -o json 2>$null | ConvertFrom-Json
    if ($raw) { $assignments = @($raw) }
}

# Ask Azure which of the roles present reach the Claude data plane, rather
# than hardcoding role names. Azure AI Developer and Cognitive Services OpenAI
# User are confined to accounts/OpenAI/* and serve no Claude at all.
$roleNames = @($assignments | ForEach-Object { $_.roleDefinitionName } | Sort-Object -Unique)
$capable = @()
foreach ($r in $roleNames) {
    $da = az role definition list --name $r --query "[0].permissions[0].dataActions" -o tsv 2>$null
    if (-not $da) { continue }
    $acts = @($da -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($acts -contains 'Microsoft.CognitiveServices/*') { $capable += $r }
}

$entitled = @($assignments | Where-Object { $capable -contains $_.roleDefinitionName })
Add-Result 'Someone is entitled to call Claude' ($entitled.Count -gt 0) $(
    if ($entitled.Count -gt 0) { "$($entitled.Count) assignment(s) via: " + (($entitled | ForEach-Object { $_.roleDefinitionName } | Sort-Object -Unique) -join ', ') }
    else { 'no assignment here carries Microsoft.CognitiveServices/* - every developer will be refused' })

# Nobody can use the resource at all. That needs a principal naming, which is
# a decision rather than a repair, so it is only offered when one was given.
if ($entitled.Count -eq 0 -and $scope) {
    if ($GrantTo) {
        $gt = $GrantTo
        az ad group show --group $gt -o none 2>$null
        $gtype = 'User'
        if ($LASTEXITCODE -eq 0) { $gtype = 'Group' }
        Add-Repair -What "entitle $gt as a $gtype" -Why 'nobody can call Claude on this resource' `
            -Command "az role assignment create --assignee-object-id $gt --assignee-principal-type $gtype --role ""Cognitive Services User"" --scope $scope" `
            -Do {
                az role assignment create --assignee-object-id $gt --assignee-principal-type $gtype `
                    --role 'Cognitive Services User' --scope $scope -o none 2>$null
                return ($LASTEXITCODE -eq 0)
            }.GetNewClosure()
    }
    else {
        Note 'Pass -GrantTo <group-or-user-object-id> to have this offered as a repair.'
        Note 'A group is the scalable answer; people are then managed by membership.'
    }
}

# Who, holding what, and whether it actually works for them. Only principals
# holding an AI-shaped role are listed: a resource inherits dozens of platform
# assignments - Defender, AKS, governance readers - none of which were ever
# meant to call Claude, and listing them buries the real finding in noise.
#
# The finding that matters is somebody holding a role that reads like access
# and is not: Azure AI Developer and Cognitive Services OpenAI User are
# confined to accounts/OpenAI/*, and an AI role on a project inside the account
# does not cover the account endpoint.
if ($assignments.Count -gt 0) {
    $aiRoles = @($assignments | Where-Object { $_.roleDefinitionName -match 'Cognitive|Foundry|Azure AI' })
    $rows = @()
    foreach ($a in $aiRoles) {
        $display = $a.principalName
        if (-not $display) { $display = $a.principalId }
        if ($display -match '^https://identity\.azure\.net/') { $display = '<managed identity>' }
        if ($display -match '^api://') { $display = '<app registration>' }

        $scopeKind = 'account'
        if ($a.scope -match '/projects/') { $scopeKind = 'PROJECT' }
        elseif ($a.scope -notmatch '/accounts/') {
            $scopeKind = 'inherited'
            if ($a.scope -match '/resourceGroups/') { $scopeKind = 'resource group' }
            if ($a.scope -match '^/subscriptions/[^/]+$') { $scopeKind = 'subscription' }
        }
        $serves = ($capable -contains $a.roleDefinitionName)
        $rows += [pscustomobject]@{
            Principal = $display; Type = $a.principalType; Role = $a.roleDefinitionName
            Scope = $scopeKind; Works = ($serves -and $scopeKind -ne 'PROJECT'); Serves = $serves
        }
    }

    if ($rows.Count -gt 0) {
        Write-Host ''
        Write-Host "  Principals holding an AI role ($($rows.Count))" -ForegroundColor White
        Note 'This names people. Redact before pasting into a ticket.'
        foreach ($r in ($rows | Sort-Object Works, Principal)) {
            $mark = '[ok] '; $col = 'DarkGray'
            if (-not $r.Works) { $mark = '[!!] '; $col = 'Yellow' }
            Write-Host ("         {0}{1,-44} {2,-16} {3,-40} {4}" -f $mark, $r.Principal, $r.Type, $r.Role, $r.Scope) -ForegroundColor $col
        }

        # Someone holding only a non-serving AI role believes they have access
        # and does not. That is the population that raises the 401 ticket.
        $blocked = @($rows | Group-Object Principal | Where-Object {
            @($_.Group | Where-Object { $_.Works }).Count -eq 0
        })
        Add-Result 'Everyone given an AI role can actually call Claude' ($blocked.Count -eq 0) $(
            if ($blocked.Count -eq 0) { "$(@($rows | Group-Object Principal).Count) principal(s), all usable" }
            else { "$($blocked.Count) of $(@($rows | Group-Object Principal).Count) hold an AI role that does not work here" })

        foreach ($b in $blocked) {
            $why = 'holds ' + (($b.Group | ForEach-Object { $_.Role } | Sort-Object -Unique) -join ', ') + ' - no Claude data action'
            $projectScoped = @($b.Group | Where-Object { $_.Serves -and $_.Scope -eq 'PROJECT' })
            if ($projectScoped.Count -gt 0) {
                $why = 'role sits on a project inside the account, not on the account itself'
            }
            Note "  $($b.Name): $why"

            # Repairing this is additive: grant the working role at the account
            # scope. Nothing is removed, so a mistake costs an extra assignment
            # rather than somebody's access.
            $pid = ($assignments | Where-Object {
                $_.principalName -eq $b.Name -or $_.principalId -eq $b.Name
            } | Select-Object -First 1)
            if ($pid -and $scope) {
                $ptype = $pid.principalType
                $pobj  = $pid.principalId
                Add-Repair -What "entitle $($b.Name) at the account scope" -Why $why `
                    -Command "az role assignment create --assignee-object-id $pobj --assignee-principal-type $ptype --role ""Cognitive Services User"" --scope $scope" `
                    -Do {
                        az role assignment create --assignee-object-id $pobj `
                            --assignee-principal-type $ptype --role 'Cognitive Services User' `
                            --scope $scope -o none 2>$null
                        return ($LASTEXITCODE -eq 0)
                    }.GetNewClosure()
            }
        }
    }
}
$groups = @($entitled | Where-Object { $_.principalType -eq 'Group' })
$users  = @($entitled | Where-Object { $_.principalType -eq 'User' })
$sps    = @($entitled | Where-Object { $_.principalType -eq 'ServicePrincipal' })
if ($entitled.Count -gt 0) {
    Write-Host ''
    Note "by principal: $($groups.Count) group(s), $($users.Count) user(s), $($sps.Count) service principal(s)"
    if ($groups.Count -eq 0 -and $users.Count -gt 0) {
        Warn 'entitlement is granted person by person'
        Note 'Assign the role to an Entra group instead and manage people by membership:'
        Note "  az role assignment create --assignee-object-id <group-id> --assignee-principal-type Group ``"
        Note "    --role ""Cognitive Services User"" --scope $scope"
    }
    foreach ($g in $groups) {
        $gn = az ad group show --group $g.principalId --query displayName -o tsv 2>$null
        if ($gn) { Note "  group: $($gn.Trim()) -> $($g.roleDefinitionName)" }
    }
}

# Roles that look right and are not. Reported because someone assigned them
# deliberately, believing they were granting access.
$looksRight = @($roleNames | Where-Object { $_ -in @('Azure AI Developer', 'Cognitive Services OpenAI User', 'Cognitive Services OpenAI Contributor') })
if ($looksRight.Count -gt 0) {
    Warn "$($looksRight -join ', ') assigned here, and grants no Claude access"
    Note 'Those roles are scoped to accounts/OpenAI/* only. Claude is not served there,'
    Note 'so the holder is refused with the same message as someone holding nothing.'
}

# 5. Anything on the resource that would block a developer -------------------
if ($acc) {
    $acl = $acc.properties.networkAcls
    $publicOk = ($acc.properties.publicNetworkAccess -ne 'Disabled')
    Add-Result 'Reachable from developer machines' $publicOk $(
        if ($publicOk) { "publicNetworkAccess=$($acc.properties.publicNetworkAccess)" }
        else { 'publicNetworkAccess is Disabled - only private endpoints reach this, which no laptop has' })

    if ($acl -and $acl.defaultAction -eq 'Deny') {
        $ipCount = 0
        if ($acl.ipRules) { $ipCount = @($acl.ipRules).Count }
        $vnetCount = 0
        if ($acl.virtualNetworkRules) { $vnetCount = @($acl.virtualNetworkRules).Count }
        Warn "firewall default is Deny ($ipCount IP rule(s), $vnetCount VNet rule(s))"
        Note 'Developers outside those ranges are refused at the network, before any token'
        Note 'is examined, and the error will not mention the firewall.'
    }

    $pe = @($acc.properties.privateEndpointConnections)
    if ($pe.Count -gt 0) { Note "$($pe.Count) private endpoint connection(s) on this resource" }
}

# 6. Desktop's own sign-in, when an app registration is nominated ------------
# Claude Desktop can run its own device-code flow instead of using the
# credential helper. That needs a public client, and the failure happens at
# Entra before any token exists, so no role assignment can fix it.
if ($ClientId) {
    $app = az ad app show --id $ClientId -o json 2>$null | ConvertFrom-Json
    if (-not $app) {
        Add-Result 'Desktop app registration is usable' $false "no application $ClientId in tenant $($acct.tenantId)"
    }
    else {
        $isPublic = [bool]$app.isFallbackPublicClient
        Add-Result 'Desktop app registration is usable' $isPublic $(
            if ($isPublic) { "$($app.displayName) is a public client" }
            else { "$($app.displayName) is not a public client - device code returns AADSTS7000218" })
        if (-not $isPublic) {
            Note "  az ad app update --id $ClientId --set isFallbackPublicClient=true"
            $cid = $ClientId
            Add-Repair -What "make $($app.displayName) a public client" `
                -Why 'device code needs a public client; otherwise Entra returns AADSTS7000218' `
                -Command "az ad app update --id $cid --set isFallbackPublicClient=true" `
                -Do {
                    az ad app update --id $cid --set isFallbackPublicClient=true 2>$null
                    return ($LASTEXITCODE -eq 0)
                }.GetNewClosure()
        }
    }
}

# Summary --------------------------------------------------------------------
Write-Host ''
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failed -eq 0) {
    Write-Host "All $($results.Count) checks passed - developers can be pointed at this resource." -ForegroundColor Green
    Write-Host ''
    Write-Host '  Hand them:' -ForegroundColor DarkGray
    Write-Host "    .\Setup-ClaudeFoundryDirect.ps1 -Resource $Resource -TenantId $($acct.tenantId)" -ForegroundColor DarkGray
}
else {
    Write-Host "$failed of $($results.Count) checks failed." -ForegroundColor Red
    Write-Host ''
    Write-Host '  Nothing above was changed. Fix the failures, then re-run.' -ForegroundColor DarkGray
}
# Repairs --------------------------------------------------------------------
# Deliberately after the summary: the operator reads the whole picture, then
# decides. Network posture is never repaired here - closing or opening a
# firewall is a security decision, not a configuration fault.
if ($repairs.Count -gt 0) {
    Write-Host ''
    Write-Host "  $($repairs.Count) repair(s) available" -ForegroundColor Cyan
    foreach ($r in $repairs) {
        Write-Host "    - $($r.What)" -ForegroundColor White
        Write-Host "      $($r.Why)" -ForegroundColor DarkGray
        Write-Host "      $($r.Command)" -ForegroundColor DarkGray
    }
    Write-Host ''
    if (-not $Fix) {
        Write-Host '  Re-run with -Fix to apply these, or copy the commands above.' -ForegroundColor DarkGray
    }
    else {
        $applied = 0
        foreach ($r in $repairs) {
            $go = $Force
            if (-not $go) {
                $ans = Read-Host "  Apply: $($r.What)? [y/N]"
                $go = ($ans -match '^(y|yes)$')
            }
            if (-not $go) { Write-Host "    skipped" -ForegroundColor DarkGray; continue }
            $ok = $false
            try { $ok = [bool](& $r.Do) } catch { $ok = $false }
            if ($ok) {
                Write-Host "    done" -ForegroundColor Green
                $applied++
            }
            else {
                Write-Host "    failed - you may not have rights to make this change" -ForegroundColor Red
                Write-Host "      $($r.Command)" -ForegroundColor DarkGray
            }
        }
        if ($applied -gt 0) {
            Write-Host ''
            Write-Host "  $applied repair(s) applied. Role assignments take a few minutes to" -ForegroundColor DarkGray
            Write-Host '  propagate; re-run this check before telling anyone it is fixed.' -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host '  This is the DIRECT path: no metering, no chargeback, and removing' -ForegroundColor DarkGray
Write-Host '  someone from a group does not revoke it - only the role assignment does.' -ForegroundColor DarkGray
Write-Host ''
exit $(if ($failed -eq 0) { 0 } else { 1 })

