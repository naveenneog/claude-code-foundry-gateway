# Stubs for tests/Test-InstallerCheckpoint.ps1, dot-sourced into a child PowerShell before the
# installer runs. az, Invoke-RestMethod and Invoke-WebRequest become global functions over a JSON
# world file, so nothing reaches Azure; a function is resolved before az.cmd and before a cmdlet.
# Each call is appended to <Log>\az.log. A not-found read writes the error text that az writes and
# exits 3, so the installer meets the same text it would meet live (ADR-0046, U70).
param([Parameter(Mandatory = $true)][string]$World, [Parameter(Mandatory = $true)][string]$Log)
$global:P91WorldPath = $World
$global:P91LogPath = $Log

function global:Read-P91World { [IO.File]::ReadAllText($global:P91WorldPath) | ConvertFrom-Json }
function global:Save-P91World($Value) { [IO.File]::WriteAllText($global:P91WorldPath, ($Value | ConvertTo-Json -Depth 30)) }
function global:Write-P91Log([string]$Name, [string]$Line) { [IO.File]::AppendAllText((Join-Path $global:P91LogPath $Name), $Line + "`n") }
function global:Set-P91Property($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function global:Get-P91Property($Object, [string]$Name) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}
function global:Write-P91Failure([string]$Text, [int]$Code = 1) {
    Write-Error -Message $Text -ErrorAction Continue
    $global:LASTEXITCODE = $Code
}
function global:Copy-P91StateSnapshot([string]$Name) {
    $state = $env:CLAUDE_GATEWAY_STATE_DIR
    if (-not $state -or -not (Test-Path -LiteralPath $state)) { Write-P91Log 'snapshots.log' "$Name none"; return }
    $files = @(Get-ChildItem -LiteralPath $state -Filter 'install-*.json' -File | Where-Object { $_.Name -notmatch '\.tmp-|\.discarded-' })
    if (-not $files.Count) { Write-P91Log 'snapshots.log' "$Name none"; return }
    Copy-Item -LiteralPath $files[0].FullName -Destination (Join-Path $global:P91LogPath "$Name.json") -Force
    Write-P91Log 'snapshots.log' "$Name present"
}

function global:Complete-P91Deployment($World, $Deployment) {
    # A finished deployment creates what main.bicep creates: the gateway, its API, its named values,
    # and the Foundry role assignment when grantFoundryRole is true.
    $apimName = [string]$Deployment.apim
    $apim = Get-P91Property $World.apims $apimName
    if (-not $apim) {
        $apim = [pscustomobject]@{ rg = [string]$Deployment.rg; sku = 'BasicV2'; location = 'eastus2'; publisherEmail = 'ops@contoso.com'; identity = 'SystemAssigned'; principalId = '00000000-0000-4000-8000-0000000000c1'; apis = @(); namedValues = [pscustomobject]@{} }
        Set-P91Property $World.apims $apimName $apim
    }
    if (@($apim.apis) -notcontains 'claude-foundry') { $apim.apis = @(@($apim.apis) + 'claude-foundry') }
    foreach ($nv in 'allow-standard', 'allow-premium', 'quota-overrides', 'bu-registry', 'bu-members', 'bu-parents', 'bu-modes') {
        if (-not (Get-P91Property $apim.namedValues $nv)) { Set-P91Property $apim.namedValues $nv ',,' }
    }
    if (-not (Get-P91Property $apim.namedValues 'entitlement-cache-seconds')) { Set-P91Property $apim.namedValues 'entitlement-cache-seconds' '3600' }
    if ([string]$Deployment.grantRole -eq 'true') {
        $id = "$($World.foundry.id)/providers/Microsoft.Authorization/roleAssignments/" + [guid]::NewGuid().ToString()
        Set-P91Property $World.roleAssignments $id ([pscustomobject]@{ principalId = $apim.principalId; scope = $World.foundry.id; role = 'Cognitive Services User' })
    }
    $Deployment.state = 'Succeeded'
    Set-P91Property $Deployment 'outputs' ([pscustomobject]@{ gatewayUrl = [pscustomobject]@{ value = "https://$apimName.azure-api.net/claude" } })
}

function global:Get-P91Deployment($World, [string]$ResourceGroup, [string]$Name) {
    $group = Get-P91Property $World.deployments $ResourceGroup
    if (-not $group) { return $null }
    return (Get-P91Property $group $Name)
}

function global:az {
    $a = @($args | ForEach-Object { [string]$_ })
    $joined = $a -join ' '
    Write-P91Log 'az.log' $joined
    $global:LASTEXITCODE = 0
    $w = Read-P91World
    $value = { param([string[]]$Names) for ($i = 0; $i -lt $a.Count - 1; $i++) { if ($Names -contains $a[$i]) { return $a[$i + 1] } }; return $null }
    $query = & $value @('--query')
    foreach ($e in @($w.inject.readErrors)) {
        if ($e -and $joined -like [string]$e.match) { Write-P91Failure ([string]$e.text) 1; return }
    }
    switch -Wildcard ($joined) {
        'version*' { return "2.86.0`t2.86.0`t1.1.0`t" }
        'bicep version*' { return 'Bicep CLI version 0.47.16 (p91stub)' }
        'account list-locations*' { return '[{"name":"eastus2","displayName":"East US 2","metadata":{"regionType":"Physical","geographyGroup":"US"}}]' }
        'account list --query*' { return [string]$w.subscriptionId }
        'account show*' {
            $account = [pscustomobject]@{ id = $w.subscriptionId; name = $w.subscriptionName; state = 'Enabled'; tenantId = $w.tenantId; user = [pscustomobject]@{ name = 'admin@contoso.com'; type = 'user' } }
            switch ($query) {
                'name' { return [string]$account.name }
                'id' { return [string]$account.id }
                'tenantId' { return [string]$account.tenantId }
                'user.name' { return 'admin@contoso.com' }
                default { return ($account | ConvertTo-Json -Depth 4 -Compress) }
            }
        }
        'account set --subscription*' { return }
        'account get-access-token*' { return [string]$w.token }
        'cognitiveservices account deployment list*' { return ($w.foundry.deployments | ConvertTo-Json -Depth 8) }
        'cognitiveservices account deployment show*' { return '{"properties":{"provisioningState":"Succeeded"}}' }
        'cognitiveservices account show*' {
            if ($query -eq 'id') { return [string]$w.foundry.id }
            if ($query -eq 'location') { return [string]$w.foundry.location }
            return ([pscustomobject]@{ id = $w.foundry.id; location = $w.foundry.location } | ConvertTo-Json -Compress)
        }
        'group show*' {
            $name = & $value @('-n', '--name')
            $location = Get-P91Property $w.resourceGroups $name
            if (-not $location) { Write-P91Failure "ERROR: (ResourceGroupNotFound) Resource group '$name' could not be found.`nCode: ResourceGroupNotFound" 3; return }
            if ($query -eq 'location') { return [string]$location }
            return ([pscustomobject]@{ name = $name; location = $location } | ConvertTo-Json -Compress)
        }
        'group create*' {
            Copy-P91StateSnapshot 'checkpoint-at-group-create'
            $name = & $value @('-n', '--name')
            $existing = Get-P91Property $w.resourceGroups $name
            if (-not $existing) { Set-P91Property $w.resourceGroups $name (& $value @('-l', '--location')) }
            Save-P91World $w
            return
        }
        'apim show*' {
            $name = & $value @('-n', '--name')
            $rg = & $value @('-g', '--resource-group')
            $apim = Get-P91Property $w.apims $name
            if (-not $apim -or $apim.rg -ne $rg) { Write-P91Failure "ERROR: (ResourceNotFound) The Resource 'Microsoft.ApiManagement/service/$name' under resource group '$rg' was not found.`nCode: ResourceNotFound" 3; return }
            $id = "/subscriptions/$($w.subscriptionId)/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$name"
            $identity = if ($apim.identity -eq 'None') { [pscustomobject]@{ type = 'None' } } else { [pscustomobject]@{ type = $apim.identity; principalId = $apim.principalId } }
            $full = [pscustomobject]@{ name = $name; id = $id; resourceGroup = $rg; location = $apim.location; publisherEmail = $apim.publisherEmail; sku = [pscustomobject]@{ name = $apim.sku; capacity = 1 }; identity = $identity; gatewayUrl = "https://$name.azure-api.net" }
            switch ($query) {
                'name' { return $name }
                'id' { return $id }
                'sku.name' { return [string]$apim.sku }
                'identity.principalId' { if ($apim.identity -eq 'None') { return } else { return [string]$apim.principalId } }
                default { return ($full | ConvertTo-Json -Depth 5 -Compress) }
            }
        }
        'apim list*' { return '[]' }
        'apim api show*' {
            $name = & $value @('--service-name')
            $apim = Get-P91Property $w.apims $name
            $api = & $value @('--api-id')
            if (-not $apim -or @($apim.apis) -notcontains $api) { Write-P91Failure "ERROR: (ResourceNotFound) Api not found.`nCode: ResourceNotFound" 3; return }
            return ([pscustomobject]@{ name = $api } | ConvertTo-Json -Compress)
        }
        'apim nv show*' {
            $name = & $value @('--service-name')
            $id = & $value @('--named-value-id')
            $apim = Get-P91Property $w.apims $name
            $nv = if ($apim) { Get-P91Property $apim.namedValues $id } else { $null }
            if ($null -eq $nv) { Write-P91Failure "ERROR: (ResourceNotFound) Named value '$id' not found.`nCode: ResourceNotFound" 3; return }
            return [string]$nv
        }
        'apim nv list*' {
            $name = & $value @('--service-name')
            $apim = Get-P91Property $w.apims $name
            if (-not $apim) { Write-P91Failure "ERROR: (ResourceNotFound) The Resource 'Microsoft.ApiManagement/service/$name' was not found." 3; return }
            return (@($apim.namedValues.PSObject.Properties | ForEach-Object { [pscustomobject]@{ name = $_.Name; value = [string]$_.Value; secret = $false } }) | ConvertTo-Json -Depth 4)
        }
        'deployment group create*' {
            Copy-P91StateSnapshot ("checkpoint-at-create-" + (& $value @('--name', '-n')))
            $name = & $value @('--name', '-n')
            $rg = & $value @('-g', '--resource-group')
            $parameters = @{}
            foreach ($token in $a) { if ($token -match '^([A-Za-z]+)=(.*)$') { $parameters[$Matches[1]] = $Matches[2] } }
            $apimName = if ($parameters['existingApimName']) { $parameters['existingApimName'] } else { 'apim-' + $parameters['namePrefix'] }
            if (-not (Get-P91Property $w.deployments $rg)) { Set-P91Property $w.deployments $rg ([pscustomobject]@{}) }
            $deployment = [pscustomobject]@{ rg = $rg; apim = $apimName; grantRole = $parameters['grantFoundryRole']; state = 'Running'; polls = @(); error = $null }
            Set-P91Property (Get-P91Property $w.deployments $rg) $name $deployment
            $apim = Get-P91Property $w.apims $apimName
            $mode = [string]$w.inject.createMode
            if ($mode -eq 'fail-identity' -and $apim -and $apim.identity -eq 'None') {
                $deployment.state = 'Failed'
                $deployment.error = [pscustomobject]@{ code = 'InvalidTemplate'; message = "Deployment template validation failed: 'The template resource 'grant-apim-cognitive-services-user' at line '1' and column '1' is not valid: The language expression property 'identity' doesn't exist, available properties are 'apiVersion, location, sku, properties'." }
                Save-P91World $w
                Write-P91Failure "ERROR: {`"code`": `"InvalidTemplate`", `"message`": `"$($deployment.error.message)`"}" 1
                return
            }
            if ($mode -eq 'disconnect') {
                $deployment.polls = @(@($w.inject.runningPolls) | ForEach-Object { [string]$_ })
                Save-P91World $w
                throw 'P91 stub: the client was disconnected while the deployment ran.'
            }
            Complete-P91Deployment $w $deployment
            Save-P91World $w
            return
        }
        'deployment group show*' {
            $name = & $value @('--name', '-n')
            $rg = & $value @('-g', '--resource-group')
            $deployment = Get-P91Deployment $w $rg $name
            if (-not $deployment) { Write-P91Failure "ERROR: (DeploymentNotFound) Deployment '$name' could not be found.`nCode: DeploymentNotFound" 3; return }
            if ($deployment.state -eq 'Running') {
                $polls = @($deployment.polls)
                if ($polls.Count -and [string]$polls[0] -ne 'forever') { $deployment.polls = @($polls | Select-Object -Skip 1) }
                if (-not $polls.Count) { Complete-P91Deployment $w $deployment }
                Save-P91World $w
            }
            $full = [pscustomobject]@{ name = $name; properties = [pscustomobject]@{ provisioningState = $deployment.state; outputs = (Get-P91Property $deployment 'outputs'); error = $deployment.error } }
            switch ($query) {
                'properties.provisioningState' { return [string]$deployment.state }
                'properties.outputs.gatewayUrl.value' { $o = Get-P91Property $deployment 'outputs'; if ($o) { return [string]$o.gatewayUrl.value } else { return } }
                default { return ($full | ConvertTo-Json -Depth 8 -Compress) }
            }
        }
        'deployment group list*' {
            $rg = & $value @('-g', '--resource-group')
            $group = Get-P91Property $w.deployments $rg
            $list = @(if ($group) { foreach ($p in $group.PSObject.Properties) { [pscustomobject]@{ name = $p.Name; properties = [pscustomobject]@{ provisioningState = $p.Value.state } } } })
            return (ConvertTo-Json -InputObject $list -Depth 5)
        }
        'deployment operation group list*' {
            $name = & $value @('--name', '-n')
            $rg = & $value @('-g', '--resource-group')
            $deployment = Get-P91Deployment $w $rg $name
            $ops = @(if ($deployment -and $deployment.error) { [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Failed'; targetResource = [pscustomobject]@{ resourceName = 'grant-apim-cognitive-services-user' }; statusMessage = [pscustomobject]@{ error = $deployment.error } } } })
            return (ConvertTo-Json -InputObject $ops -Depth 8)
        }
        'role assignment list*' {
            $principal = & $value @('--assignee-object-id')
            $scope = & $value @('--scope')
            $list = @(foreach ($p in $w.roleAssignments.PSObject.Properties) {
                if ((-not $principal -or $p.Value.principalId -eq $principal) -and (-not $scope -or $p.Value.scope -eq $scope)) {
                    [pscustomobject]@{ id = $p.Name; principalId = $p.Value.principalId; scope = $p.Value.scope; roleDefinitionName = $p.Value.role }
                }
            })
            return (ConvertTo-Json -InputObject $list -Depth 5)
        }
        'rest*' {
            $url = [string](& $value @('--url', '--uri', '-u'))
            $id = ($url -replace '^https://management\.azure\.com', '') -replace '\?.*$', ''
            $assignment = Get-P91Property $w.roleAssignments $id
            if (-not $assignment) { Write-P91Failure "ERROR: Not Found({`"error`":{`"code`":`"RoleAssignmentNotFound`",`"message`":`"The role assignment '$id' is not found.`"}})" 3; return }
            return ([pscustomobject]@{ id = $id; properties = [pscustomobject]@{ principalId = $assignment.principalId; scope = $assignment.scope } } | ConvertTo-Json -Depth 4 -Compress)
        }
        'ad group list*' {
            # --display-name is a prefix ("Object's display name or its prefix", az ad group list --help).
            # inject.groupLists holds Graph's answer for a name, as a scenario states it.
            $prefix = [string](& $value @('--display-name'))
            $lists = Get-P91Property $w.inject 'groupLists'
            $given = if ($lists) { Get-P91Property $lists $prefix } else { $null }
            if ($null -ne $given) { return (ConvertTo-Json -InputObject @($given) -Depth 4 -Compress) }
            $list = @(foreach ($p in $w.groups.PSObject.Properties) { if ([string]$p.Value -like "$prefix*") { [pscustomobject]@{ id = $p.Name; displayName = [string]$p.Value } } })
            return (ConvertTo-Json -InputObject $list -Depth 4 -Compress)
        }
        'ad group show*' {
            $group = & $value @('--group', '-g')
            $found = @()
            if ($group -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                $byId = Get-P91Property $w.groups $group
                if (-not $byId) { Write-P91Failure "ERROR: Resource '$group' does not exist or one of its queried reference-property objects are not present." 3; return }
                $found = @([pscustomobject]@{ id = $group; displayName = [string]$byId })
            }
            else {
                $found = @(foreach ($p in $w.groups.PSObject.Properties) { if ([string]$p.Value -like "$group*") { [pscustomobject]@{ id = $p.Name; displayName = [string]$p.Value } } })
                if (-not $found.Count) { Write-P91Failure "ERROR: Group $group is not found in Graph " 1; return }
                if ($found.Count -gt 1) { Write-P91Failure "ERROR: More than 1 group objects has the display name of $group" 1; return }
            }
            if ($query -eq 'id') { return [string]$found[0].id }
            return ($found[0] | ConvertTo-Json -Compress)
        }
        'ad group create*' {
            $display = & $value @('--display-name')
            if (@($w.inject.groupCreateFail) -contains $display) { Write-P91Failure "ERROR: Insufficient privileges to complete the operation." 1; return }
            $match = @(foreach ($p in $w.groups.PSObject.Properties) { if ([string]$p.Value -eq $display) { $p.Name } })
            $id = if ($match.Count) { $match[0] } else { [guid]::NewGuid().ToString() }
            if (-not $match.Count) { Set-P91Property $w.groups $id $display; Save-P91World $w }
            $made = [pscustomobject]@{ id = $id; displayName = $display }
            if ($query -eq 'id') { return $id }
            return ($made | ConvertTo-Json -Compress)
        }
        default {
            Write-P91Log 'unexpected.log' $joined
            Write-P91Failure "P91 stub: unexpected az call: $joined" 2
            return
        }
    }
}

function global:Invoke-RestMethod {
    param($Uri, $Method = 'Get', $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing)
    $u = [uri]::UnescapeDataString([string]$Uri)
    Write-P91Log 'az.log' "REST $Method $u"
    if ($u -match "serviceName eq 'API Management'") {
        $rows = foreach ($r in @(@('Basic v2 Unit', 0.21), @('Standard v2 Unit', 0.96), @('Premium v2 Unit', 3.84))) {
            [pscustomobject]@{ meterName = $r[0]; retailPrice = $r[1]; unitPrice = $r[1]; type = 'Consumption'; skuName = ($r[0] -replace ' Unit$', ''); productName = 'API Management'; serviceName = 'API Management'; tierMinimumUnits = 0; unitOfMeasure = '1 Hour'; currencyCode = 'USD'; armRegionName = 'eastus2' }
        }
        return [pscustomobject]@{ Items = @($rows); NextPageLink = $null }
    }
    if ($u -match '^https://management\.azure\.com/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/service/([^/?]+)\?') {
        $w = Read-P91World
        $apim = Get-P91Property $w.apims $Matches[1]
        if (-not $apim) { throw 'Response status code does not indicate success: 404 (Not Found).' }
        return [pscustomobject]@{ properties = [pscustomobject]@{ virtualNetworkType = 'None'; publicNetworkAccess = 'Enabled'; developerPortalStatus = 'Disabled'; legacyPortalStatus = 'Disabled'; customProperties = [pscustomobject]@{}; hostnameConfigurations = @() } }
    }
    throw "P91 stub: unexpected REST call $u"
}

function global:Invoke-WebRequest {
    param($Uri, $Method, $TimeoutSec, $ErrorAction, [switch]$UseBasicParsing)
    Write-P91Log 'az.log' "WEB $Uri"
    [pscustomobject]@{ StatusCode = 200 }
}
