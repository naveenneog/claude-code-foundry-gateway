function Get-ClaudeProjectionReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$NamePrefix,
        [switch]$IncludeSyncJob,
        [string]$RepositoryRoot,
        [scriptblock]$InvokeAz
    )

    function New-ReadinessCheck($Name, $Result, $Evidence, $Remedy) {
        [pscustomobject]@{ Name = $Name; Result = $Result; Evidence = $Evidence; Remedy = $Remedy }
    }
    function ConvertTo-LocationKey([string]$Value) {
        return (($Value -replace '\s+', '').ToLowerInvariant())
    }
    function Add-Subscription([string[]]$Arguments) {
        return @($Arguments + @('--subscription', $SubscriptionId))
    }
    function Invoke-ReadinessAz([string[]]$Arguments) {
        $global:LASTEXITCODE = 0
        try {
            $out = & $InvokeAz (Add-Subscription $Arguments)
            $text = (@($out) -join "`n")
            if ($global:LASTEXITCODE -ne 0) { return @{ Ok = $false; Text = $text; Error = "az exited $global:LASTEXITCODE. $text" } }
            return @{ Ok = $true; Text = $text; Error = '' }
        }
        catch {
            return @{ Ok = $false; Text = ''; Error = $_.Exception.Message }
        }
    }
    function Read-Json([string[]]$Arguments) {
        $read = Invoke-ReadinessAz $Arguments
        if (-not $read.Ok) { return @{ Ok = $false; Error = $read.Error; Value = $null; Text = $read.Text } }
        try { return @{ Ok = $true; Error = ''; Value = ($read.Text | ConvertFrom-Json -ErrorAction Stop); Text = $read.Text } }
        catch { return @{ Ok = $false; Error = "unexpected JSON shape: $($_.Exception.Message)"; Value = $null; Text = $read.Text } }
    }
    function Get-JsonProperty($Object, [string]$Name) {
        if ($null -eq $Object) { return $null }
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }
    function Get-NamedUsage($Object, [string]$UsageName) {
        foreach ($item in @(Get-JsonProperty $Object 'value')) {
            $name = Get-JsonProperty (Get-JsonProperty $item 'name') 'value'
            if ($name -eq $UsageName) { return $item }
        }
        return $null
    }
    function ConvertTo-LongOrNull($Value) {
        $number = 0L
        if ([long]::TryParse([string]$Value, [ref]$number)) { return $number }
        return $null
    }
    function New-LimitCheck($Name, $Current, $Need, $Limit, $RemedyDetail) {
        $c = ConvertTo-LongOrNull $Current
        $n = ConvertTo-LongOrNull $Need
        $l = ConvertTo-LongOrNull $Limit
        if ($null -eq $c -or $null -eq $n -or $null -eq $l) {
            return New-ReadinessCheck $Name 'WARN' 'The usage response did not include numeric currentValue and limit.' "Run the Azure usage read for $Name again before applying."
        }
        $evidence = "current $c + need $n <= limit $l"
        if (($c + $n) -le $l) { return New-ReadinessCheck $Name 'PASS' $evidence 'None' }
        return New-ReadinessCheck $Name 'FAIL' $evidence "Request a quota increase in the Azure portal's Quotas page for $RemedyDetail, or use another region/subscription."
    }
    function Count-TsvLines([string]$Text) {
        return @($Text -split '\r?\n' | Where-Object { $_.Trim() }).Count
    }
    function Test-ActionPattern([string]$Pattern, [string]$Action) {
        if (-not $Pattern) { return $false }
        $regex = '^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*') + '$'
        return [regex]::IsMatch($Action, $regex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    function Get-ValidationEvidence([string]$Text) {
        $code = ''
        $message = ''
        try {
            $obj = $Text | ConvertFrom-Json -ErrorAction Stop
            $err = Get-JsonProperty $obj 'error'
            $code = [string](Get-JsonProperty $err 'code')
            $message = [string](Get-JsonProperty $err 'message')
        } catch { }
        if (-not $code -and $Text -match '"code"\s*:\s*"([^"]+)"') { $code = $matches[1] }
        if (-not $message -and $Text -match '"message"\s*:\s*"([^"]+)"') { $message = $matches[1] }
        $evidence = (($code + ' ' + $message).Trim() -replace '\s+', ' ')
        if (-not $evidence) { $evidence = (($Text -replace '\s+', ' ').Trim()) }
        if ($evidence.Length -gt 300) { $evidence = $evidence.Substring(0, 300) }
        return $evidence
    }
    function Get-PolicyNames([string]$Text) {
        $names = [Collections.Generic.List[string]]::new()
        foreach ($pattern in @('policyAssignmentName"?\s*[:=]\s*"?([^",;\s}]+)', 'policyDefinitionName"?\s*[:=]\s*"?([^",;\s}]+)', "policy assignment '([^']+)'", "policy definition '([^']+)'")) {
            foreach ($match in [regex]::Matches($Text, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                if ($match.Groups.Count -gt 1 -and -not $names.Contains($match.Groups[1].Value)) { $names.Add($match.Groups[1].Value) }
            }
        }
        if ($names.Count) { return ($names.ToArray() -join ', ') }
        return 'RequestDisallowedByPolicy'
    }
    function Add-RegionCheck($List, $Name, [string[]]$Arguments, [string]$ResourceType, [string]$CommandText) {
        $read = Read-Json $Arguments
        if (-not $read.Ok) {
            $List.Add((New-ReadinessCheck $Name 'WARN' $read.Error "Run $CommandText and choose a region after the read succeeds."))
            return
        }
        $locations = @()
        if ($ResourceType) {
            $matchType = $null
            foreach ($type in @(Get-JsonProperty $read.Value 'resourceTypes')) {
                if (([string](Get-JsonProperty $type 'resourceType')) -eq $ResourceType) { $matchType = $type; break }
            }
            if ($matchType) { $locations = @(Get-JsonProperty $matchType 'locations') }
        } else {
            foreach ($item in @($read.Value)) { $locations += [string](Get-JsonProperty $item 'name') }
        }
        if (-not $locations -or $locations.Count -eq 0) {
            $List.Add((New-ReadinessCheck $Name 'WARN' 'The location list was missing from the Azure response.' "Run $CommandText and confirm the response shape."))
            return
        }
        $found = @($locations | Where-Object { (ConvertTo-LocationKey $_) -eq $locationKey }).Count -gt 0
        if ($found) { $List.Add((New-ReadinessCheck $Name 'PASS' "$Location is listed." 'None')) }
        else { $List.Add((New-ReadinessCheck $Name 'FAIL' "$Location is not listed." "Choose a region that offers $Name.")) }
    }
    function Add-TemplateValidation($List, $Name, [string]$TemplateFile, [string[]]$Parameters) {
        $args = @('deployment','group','validate','-g',$ResourceGroup,'--template-file',$TemplateFile,'--parameters') + $Parameters + @('-o','json')
        $read = Invoke-ReadinessAz $args
        if ($read.Ok) {
            $List.Add((New-ReadinessCheck $Name 'PASS' "Validated $TemplateFile." 'None'))
            return
        }
        $text = ($read.Error + "`n" + $read.Text)
        if ($text -match 'RequestDisallowedByPolicy') {
            $List.Add((New-ReadinessCheck $Name 'FAIL' ("RequestDisallowedByPolicy: " + (Get-PolicyNames $text)) 'Ask the policy owner for a policy exemption, or use another resource group/subscription.'))
        } else {
            $List.Add((New-ReadinessCheck $Name 'WARN' (Get-ValidationEvidence $text) "Run az deployment group validate for $TemplateFile and resolve the template error before applying."))
        }
    }

    if ($NamePrefix.Length -gt 37 -or $NamePrefix -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw 'NamePrefix must be 1-37 lowercase letters/digits separated by single hyphens.'
    }
    if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path $PSScriptRoot -Parent }
    if (-not $InvokeAz) { $InvokeAz = { param([string[]]$Arguments) & az @Arguments } }

    $locationKey = ConvertTo-LocationKey $Location
    $checks = [Collections.Generic.List[object]]::new()

    Add-RegionCheck $checks 'Region: Cosmos DB accounts' @('provider','show','-n','Microsoft.DocumentDB','-o','json') 'databaseAccounts' 'az provider show -n Microsoft.DocumentDB -o json'
    Add-RegionCheck $checks 'Region: container groups' @('provider','show','-n','Microsoft.ContainerInstance','-o','json') 'containerGroups' 'az provider show -n Microsoft.ContainerInstance -o json'
    Add-RegionCheck $checks 'Region: private endpoints' @('provider','show','-n','Microsoft.Network','-o','json') 'privateEndpoints' 'az provider show -n Microsoft.Network -o json'
    Add-RegionCheck $checks 'Region: Flex Consumption' @('functionapp','list-flexconsumption-locations','-o','json') '' 'az functionapp list-flexconsumption-locations -o json'
    if ($IncludeSyncJob) {
        Add-RegionCheck $checks 'Region: Container Apps environments' @('provider','show','-n','Microsoft.App','-o','json') 'managedEnvironments' 'az provider show -n Microsoft.App -o json'
    }

    $aciUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.ContainerInstance/locations/$locationKey/usages?api-version=2023-05-01"
    $aci = Read-Json @('rest','--method','get','--url',$aciUrl)
    if (-not $aci.Ok) {
        $checks.Add((New-ReadinessCheck 'Usage: container groups' 'WARN' $aci.Error 'Run az rest for Microsoft.ContainerInstance location usages before applying.'))
        $checks.Add((New-ReadinessCheck 'Usage: container cores' 'WARN' $aci.Error 'Run az rest for Microsoft.ContainerInstance location usages before applying.'))
    } else {
        $groups = Get-NamedUsage $aci.Value 'ContainerGroups'
        $cores = Get-NamedUsage $aci.Value 'StandardCores'
        if ($groups) { $checks.Add((New-LimitCheck 'Usage: container groups' (Get-JsonProperty $groups 'currentValue') 1 (Get-JsonProperty $groups 'limit') 'container groups')) }
        else { $checks.Add((New-ReadinessCheck 'Usage: container groups' 'WARN' 'ContainerGroups usage was missing.' 'Run az rest for Microsoft.ContainerInstance location usages before applying.')) }
        if ($cores) { $checks.Add((New-LimitCheck 'Usage: container cores' (Get-JsonProperty $cores 'currentValue') 2 (Get-JsonProperty $cores 'limit') 'container cores')) }
        else { $checks.Add((New-ReadinessCheck 'Usage: container cores' 'WARN' 'StandardCores usage was missing.' 'Run az rest for Microsoft.ContainerInstance location usages before applying.')) }
    }

    $storage = Read-Json @('storage','account','show-usage','--location',$locationKey,'-o','json')
    if (-not $storage.Ok -or $storage.Value -is [array]) { $checks.Add((New-ReadinessCheck 'Usage: storage accounts' 'WARN' 'Storage usage was unreadable or was not the expected single object.' 'Run az storage account show-usage --location <location> -o json before applying.')) }
    else { $checks.Add((New-LimitCheck 'Usage: storage accounts' (Get-JsonProperty $storage.Value 'currentValue') 1 (Get-JsonProperty $storage.Value 'limit') 'storage accounts')) }

    $network = Read-Json @('network','list-usages','--location',$locationKey,'-o','json')
    if (-not $network.Ok) { $checks.Add((New-ReadinessCheck 'Usage: virtual networks' 'WARN' $network.Error 'Run az network list-usages --location <location> -o json before applying.')) }
    else {
        $vnets = $null
        foreach ($item in @($network.Value)) {
            if (([string](Get-JsonProperty (Get-JsonProperty $item 'name') 'value')) -eq 'VirtualNetworks') { $vnets = $item; break }
        }
        if ($vnets) { $checks.Add((New-LimitCheck 'Usage: virtual networks' (Get-JsonProperty $vnets 'currentValue') 1 (Get-JsonProperty $vnets 'limit') 'virtual networks')) }
        else { $checks.Add((New-ReadinessCheck 'Usage: virtual networks' 'WARN' 'VirtualNetworks usage was missing.' 'Run az network list-usages --location <location> -o json before applying.')) }
    }

    $cosmos = Invoke-ReadinessAz @('cosmosdb','list','--query','[].id','-o','tsv')
    if (-not $cosmos.Ok) { $checks.Add((New-ReadinessCheck 'Usage: Cosmos DB accounts' 'WARN' $cosmos.Error 'Run az cosmosdb list --query [].id -o tsv before applying.')) }
    else {
        $cosmosCheck = New-LimitCheck 'Usage: Cosmos DB accounts' (Count-TsvLines $cosmos.Text) 1 250 'Cosmos DB accounts'
        $cosmosCheck.Evidence = "$($cosmosCheck.Evidence) (documented default U135)"
        $checks.Add($cosmosCheck)
    }

    $dns = Invoke-ReadinessAz @('network','private-dns','zone','list','--query','[].id','-o','tsv')
    if (-not $dns.Ok) { $checks.Add((New-ReadinessCheck 'Usage: private DNS zones' 'WARN' $dns.Error 'Run az network private-dns zone list --query [].id -o tsv before applying.')) }
    else {
        $dnsCheck = New-LimitCheck 'Usage: private DNS zones' (Count-TsvLines $dns.Text) 5 1000 'private DNS zones'
        $dnsCheck.Evidence = "$($dnsCheck.Evidence) (documented default U135)"
        $checks.Add($dnsCheck)
    }

    if ($IncludeSyncJob) {
        $appUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.App/locations/$locationKey/usages?api-version=2024-03-01"
        $appUsage = Read-Json @('rest','--method','get','--url',$appUrl)
        if (-not $appUsage.Ok) { $checks.Add((New-ReadinessCheck 'Usage: Container Apps environments' 'WARN' $appUsage.Error 'Run az rest for Microsoft.App location usages before applying.')) }
        else {
            $envUsage = Get-NamedUsage $appUsage.Value 'ManagedEnvironmentCount'
            if ($envUsage) { $checks.Add((New-LimitCheck 'Usage: Container Apps environments' (Get-JsonProperty $envUsage 'currentValue') 1 (Get-JsonProperty $envUsage 'limit') 'Container Apps environments')) }
            else { $checks.Add((New-ReadinessCheck 'Usage: Container Apps environments' 'WARN' 'ManagedEnvironmentCount usage was missing.' 'Run az rest for Microsoft.App location usages before applying.')) }
        }
    }

    $permissionUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $permissions = Read-Json @('rest','--method','get','--url',$permissionUrl)
    if (-not $permissions.Ok) {
        $checks.Add((New-ReadinessCheck 'Role assignments write permission' 'WARN' $permissions.Error 'Run az rest for Microsoft.Authorization permissions on the resource group before applying.'))
    } else {
        $target = 'Microsoft.Authorization/roleAssignments/write'
        $allowed = $false
        foreach ($set in @(Get-JsonProperty $permissions.Value 'value')) {
            $hasAction = $false
            foreach ($action in @(Get-JsonProperty $set 'actions')) {
                if (Test-ActionPattern ([string]$action) $target) { $hasAction = $true; break }
            }
            if (-not $hasAction) { continue }
            $blocked = $false
            foreach ($notAction in @(Get-JsonProperty $set 'notActions')) {
                if (Test-ActionPattern ([string]$notAction) $target) { $blocked = $true; break }
            }
            if (-not $blocked) { $allowed = $true; break }
        }
        if ($allowed) {
            $checks.Add((New-ReadinessCheck 'Role assignments write permission' 'PASS' 'Effective permissions include Microsoft.Authorization/roleAssignments/write.' 'None'))
        } else {
            $checks.Add((New-ReadinessCheck 'Role assignments write permission' 'FAIL' 'Effective permissions do not include Microsoft.Authorization/roleAssignments/write.' 'Grant Owner, or Contributor plus User Access Administrator or Role Based Access Control Administrator, on the resource group.'))
        }
    }

    $checks.Add((New-ReadinessCheck 'Cosmos DB regional capacity' 'NOTE' 'U136: Cosmos DB regional capacity cannot be checked in advance; a capacity failure stops deployment before the switch and named values keep serving.' 'Use another region if Cosmos DB allocation fails.'))

    $projection = Join-Path (Join-Path $RepositoryRoot 'infra') 'projection.bicep'
    $networkTemplate = Join-Path (Join-Path $RepositoryRoot 'infra') 'projection-network.bicep'
    Add-TemplateValidation $checks 'Template validation: projection' $projection @("namePrefix=$NamePrefix", "location=$locationKey", 'networkAccess=private-only')
    Add-TemplateValidation $checks 'Template validation: projection network' $networkTemplate @("namePrefix=$NamePrefix", "location=$locationKey", "cosmosAccountName=cosmos-$NamePrefix", 'runnerEnabled=true')

    return $checks.ToArray()
}
