# The projection renewal job's templates and deploy script (ADR-0049, P94).
#
# Offline. Templates are compiled with the Bicep CLI and read as ARM JSON; nothing reaches Azure.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('projection-renewal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Get-CompiledTemplate([string]$Relative) {
    $out = Join-Path $work (([IO.Path]::GetFileNameWithoutExtension($Relative)) + '.json')
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $log = & az bicep build --file (Join-Path $root $Relative) --outfile $out 2>&1 | Out-String
    $ErrorActionPreference = $previous
    if (-not (Test-Path -LiteralPath $out)) { Assert "$Relative compiles" $false $log.Trim(); return $null }
    Assert "$Relative compiles" $true
    return (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -AsHashtable)
}

function Get-TemplateResources($Template) {
    if ($Template.resources -is [Collections.IDictionary]) { return @($Template.resources.Values) }
    return @($Template.resources)
}

function ConvertTo-Ipv4Number([string]$Address) {
    $bytes = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    return ([uint64]$bytes[0] -shl 24) + ([uint64]$bytes[1] -shl 16) + ([uint64]$bytes[2] -shl 8) + [uint64]$bytes[3]
}

# Bicep's cidrSubnet(prefix, newBits, index): the index-th subnet of length newBits inside prefix.
function Get-CidrSubnetRange([string]$Prefix, [int]$Bits, [int]$Index) {
    $address, $length = $Prefix -split '/'
    $size = [uint64][math]::Pow(2, 32 - $Bits)
    $start = (ConvertTo-Ipv4Number $address) + ([uint64]$Index * $size)
    [pscustomobject]@{ Start = $start; End = $start + $size - 1; Bits = $Bits }
}

try {
    Write-Host ''
    Write-Host 'Projection renewal - the network has a subnet for the job' -ForegroundColor Cyan

    $network = Get-CompiledTemplate 'infra\projection-network.bicep'
    if ($network) {
        Assert 'an existing VNet passes a renewal subnet' ($network.parameters.Contains('renewalSubnetId') -and $network.parameters.renewalSubnetId.defaultValue -eq '')
        $vnet = Get-TemplateResources $network | Where-Object { $_.type -eq 'Microsoft.Network/virtualNetworks' } | Select-Object -First 1
        $prefix = [string]$network.parameters.vnetAddressPrefix.defaultValue
        $plan = Get-CidrSubnetRange $prefix ([int]($prefix -split '/')[1]) 0
        $ranges = @()
        foreach ($subnet in @($vnet.properties.subnets)) {
            $m = [regex]::Match([string]$subnet.properties.addressPrefix, "cidrSubnet\(parameters\('vnetAddressPrefix'\), (\d+), (\d+)\)")
            Assert "subnet $($subnet.name) is carved from the address plan" $m.Success ([string]$subnet.properties.addressPrefix)
            if ($m.Success) { $ranges += [pscustomobject]@{ Name = $subnet.name; Range = (Get-CidrSubnetRange $prefix ([int]$m.Groups[1].Value) ([int]$m.Groups[2].Value)); Subnet = $subnet } }
        }
        $renewal = $ranges | Where-Object Name -eq 'renewal' | Select-Object -First 1
        Assert 'a new VNet gets a renewal subnet' ([bool]$renewal) (($ranges | ForEach-Object Name) -join ', ')
        if ($renewal) {
            $delegations = @($renewal.Subnet.properties.delegations | ForEach-Object { $_.properties.serviceName })
            Assert 'it is delegated to Microsoft.App/environments only' (($delegations -join ',') -eq 'Microsoft.App/environments') ($delegations -join ',')
            Assert 'it is at least a /27' ($renewal.Range.Bits -le 27) "/$($renewal.Range.Bits)"
        }
        $overlaps = @()
        for ($i = 0; $i -lt $ranges.Count; $i++) {
            if ($ranges[$i].Range.Start -lt $plan.Start -or $ranges[$i].Range.End -gt $plan.End) { $overlaps += "$($ranges[$i].Name) is outside $prefix" }
            for ($j = $i + 1; $j -lt $ranges.Count; $j++) {
                if ($ranges[$i].Range.Start -le $ranges[$j].Range.End -and $ranges[$j].Range.Start -le $ranges[$i].Range.End) { $overlaps += "$($ranges[$i].Name) overlaps $($ranges[$j].Name)" }
            }
        }
        Assert "no subnet overlaps another in the default plan $prefix" ($ranges.Count -ge 4 -and $overlaps.Count -eq 0) ($overlaps -join '; ')
        $output = [string]$network.outputs.renewalSubnetId.value
        Assert 'the renewal subnet is an output, from either VNet shape' ($output -match "subnets/renewal" -and $output -match "parameters\('renewalSubnetId'\)") $output
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection renewal templates and deploy script hold.' -ForegroundColor Green
exit 0
