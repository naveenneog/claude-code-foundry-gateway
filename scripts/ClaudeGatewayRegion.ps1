<#
.SYNOPSIS
    The gateway's region choice, priced: API Management v2 monthly list prices per region.

.DESCRIPTION
    Install-ClaudeGateway.ps1 asks for a region and then an API Management v2 tier. Both change
    the monthly price, so both prompts show it (ADR-0032). One Azure Retail Prices API query
    returns the three v2 unit meters in every region; `az account list-locations` gives each
    region's geography, so the choice lists the Foundry account's region and the others in its
    geography.

    These are list prices. What an organization pays is on its agreement's price sheet, which
    needs a billing role to read, not a subscription role (docs/UNKNOWNS.md U31).
#>

. (Join-Path $PSScriptRoot 'AzureRetailPrice.ps1')
# Sort-ClaudeFlowOrdinal gives one order on Windows PowerShell 5.1 and PowerShell 7 (P76).
if (-not (Get-Command Sort-ClaudeFlowOrdinal -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'flow\FlowContract.ps1') }

$script:ClaudeApimV2Meters = [ordered]@{ BasicV2 = 'Basic v2 Unit'; StandardV2 = 'Standard v2 Unit'; PremiumV2 = 'Premium v2 Unit' }

function ConvertTo-ClaudeArmRegionName {
    # 'East US 2' (az apim show) and 'eastus2' (ARM, the Retail Prices API) name the same region.
    param([string]$Name)
    if (-not $Name) { return '' }
    return (($Name -replace '\s', '').ToLowerInvariant())
}

function Get-ClaudeApimV2Prices {
    <#
    .SYNOPSIS
        The monthly list price of each API Management v2 tier, one unit at 730 hours, per region.
    .OUTPUTS
        ByRegion: region -> BasicV2/StandardV2/PremiumV2 -> monthly price, or $null where the API
        publishes none. ByRegion is $null when the API could not be reached; Unreachable says why.
    #>
    $read = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    $rows = Get-AzureRetailPriceAcrossRegions -ServiceName 'API Management' -MeterName @($script:ClaudeApimV2Meters.Values)
    if ($null -eq $rows) {
        return [pscustomobject]@{ ByRegion = $null; Currency = 'USD'; RetrievedUtc = $read; Unreachable = [string](Get-AzureRetailPriceUnavailableReason) }
    }
    $byRegion = @{}
    $currency = 'USD'
    foreach ($row in @($rows)) {
        $tier = @($script:ClaudeApimV2Meters.Keys | Where-Object { $script:ClaudeApimV2Meters[$_] -eq $row.MeterName })
        if (-not $tier.Count) { continue }
        if (-not $byRegion.ContainsKey($row.Region)) { $byRegion[$row.Region] = [ordered]@{ BasicV2 = $null; StandardV2 = $null; PremiumV2 = $null } }
        $byRegion[$row.Region][$tier[0]] = ConvertTo-MonthlyPrice -HourlyPrice $row.UnitPrice
        if ($row.Currency) { $currency = $row.Currency }
    }
    [pscustomobject]@{ ByRegion = $byRegion; Currency = $currency; RetrievedUtc = $read; Unreachable = '' }
}

function Get-ClaudeGatewayRegionOptions {
    <#
    .SYNOPSIS
        Numbered region choices: the Foundry account's region first, then the other physical regions
        in its geography that publish a v2 price, cheapest Basic v2 first.
    #>
    param([string]$FoundryRegion, [object[]]$Locations = @(), $Prices)
    # One level flattened: a 5.1 caller can pass the parsed JSON array as a single element.
    $Locations = @($Locations | ForEach-Object { $_ })
    $physical = @($Locations | Where-Object { $_ -and $_.metadata -and $_.metadata.regionType -eq 'Physical' })
    $foundry = @($physical | Where-Object { $_.name -eq $FoundryRegion })
    $group = if ($foundry.Count) { [string]$foundry[0].metadata.geographyGroup } else { '' }
    $byRegion = if ($Prices -and $Prices.ByRegion) { $Prices.ByRegion } else { @{} }
    $monthly = {
        param([string]$Region)
        if ($byRegion.ContainsKey($Region)) { $byRegion[$Region] } else { [ordered]@{ BasicV2 = $null; StandardV2 = $null; PremiumV2 = $null } }
    }
    $options = [System.Collections.Generic.List[object]]::new()
    if ($FoundryRegion) {
        $options.Add([pscustomobject]@{ Number = 0; Region = $FoundryRegion; DisplayName = $(if ($foundry.Count) { [string]$foundry[0].displayName } else { $FoundryRegion }); SameAsFoundry = $true; Monthly = (& $monthly $FoundryRegion) })
    }
    $others = @(Sort-ClaudeFlowOrdinal -Key { if ($null -ne $_.Monthly['BasicV2']) { [decimal]$_.Monthly['BasicV2'] } else { [decimal]::MaxValue } }, { $_.Region } -InputObject @(
        $physical | Where-Object { $group -and $_.name -ne $FoundryRegion -and [string]$_.metadata.geographyGroup -eq $group -and $byRegion.ContainsKey([string]$_.name) } |
            ForEach-Object { [pscustomobject]@{ Number = 0; Region = [string]$_.name; DisplayName = [string]$_.displayName; SameAsFoundry = $false; Monthly = (& $monthly ([string]$_.name)) } }
    ))
    foreach ($o in $others) { $options.Add($o) }
    for ($i = 0; $i -lt $options.Count; $i++) { $options[$i].Number = $i + 1 }
    return @($options)
}

function Format-ClaudeApimMonthly {
    param($Amount, [string]$Currency = 'USD')
    if ($null -eq $Amount) { return 'not published' }
    return ('{0} {1}' -f $Currency, ([decimal]$Amount).ToString('N2', [Globalization.CultureInfo]::InvariantCulture))
}

function Format-ClaudeGatewayRegionTable {
    param([object[]]$Options = @(), $Prices)
    $currency = if ($Prices -and $Prices.Currency) { [string]$Prices.Currency } else { 'USD' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("API Management v2 monthly list price, one unit at 730 hours, from the Azure Retail Prices API, read $($Prices.RetrievedUtc):")
    $lines.Add('')
    $lines.Add(('      {0,-30} {1,-15} {2,-15} {3}' -f 'Region', 'Basic v2', 'Standard v2', 'Premium v2'))
    foreach ($o in @($Options)) {
        $name = if ($o.SameAsFoundry) { "$($o.Region) (Foundry region)" } else { $o.Region }
        $lines.Add(('  {0,2}. {1,-30} {2,-15} {3,-15} {4}' -f $o.Number, $name, (Format-ClaudeApimMonthly $o.Monthly['BasicV2'] $currency), (Format-ClaudeApimMonthly $o.Monthly['StandardV2'] $currency), (Format-ClaudeApimMonthly $o.Monthly['PremiumV2'] $currency)))
    }
    $lines.Add('')
    $lines.Add('The Foundry account''s region keeps latency down. Another region''s name is accepted too.')
    $lines.Add('These are list prices. The agreement''s price sheet states what the organization pays; reading it')
    $lines.Add('takes a billing role, not a subscription role (docs/UNKNOWNS.md U31).')
    return @($lines)
}

function Format-ClaudeApimTierPriceLines {
    param([string]$Region, $Prices)
    $currency = if ($Prices -and $Prices.Currency) { [string]$Prices.Currency } else { 'USD' }
    $monthly = if ($Prices -and $Prices.ByRegion -and $Prices.ByRegion.ContainsKey($Region)) { $Prices.ByRegion[$Region] } else { $null }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Monthly list price in $Region, one unit at 730 hours (Azure Retail Prices API, read $($Prices.RetrievedUtc)):")
    foreach ($tier in @($script:ClaudeApimV2Meters.Keys)) {
        $amount = if ($monthly) { $monthly[$tier] } else { $null }
        $lines.Add(('  {0,-12} {1}' -f $tier, (Format-ClaudeApimMonthly $amount $currency)))
    }
    return @($lines)
}

function Resolve-ClaudeGatewayRegionAnswer {
    <#
    .SYNOPSIS
        The region an answer names: a number from the options, or a region name in any case or
        spacing that is in the options or among the subscription's regions. $null otherwise.
    #>
    param([string]$Answer, [object[]]$Options = @(), [string[]]$KnownRegions = @())
    $text = ([string]$Answer).Trim()
    if (-not $text) { return $null }
    $number = 0
    if ([int]::TryParse($text, [ref]$number)) {
        $hit = @($Options | Where-Object { $_.Number -eq $number })
        if ($hit.Count) { return [string]$hit[0].Region }
        return $null
    }
    $name = ConvertTo-ClaudeArmRegionName $text
    $listed = @($Options | Where-Object { $_.Region -eq $name })
    if ($listed.Count) { return [string]$listed[0].Region }
    $known = @($KnownRegions | Where-Object { $_ -eq $name })
    if ($known.Count) { return [string]$known[0] }
    return $null
}
