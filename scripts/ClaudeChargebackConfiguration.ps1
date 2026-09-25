# Mutable configuration is a private, versioned blob, independent of the pinned job code.
function ConvertTo-ClaudeChargebackConfiguration {
    param($Value)
    $copy=$Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $map=@{}
    foreach($p in $copy.Units.PSObject.Properties) { $map[$p.Name]=@($p.Value) }
    $copy.Units=$map
    return $copy
}

function Test-ClaudeReportDomains {
    param([string[]]$Domains)
    if (-not $Domains.Count) { throw 'At least one allowed domain is required. The domain allow-list cannot be disabled.' }
    foreach($domain in $Domains) {
        if ($domain -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+$') {
            throw 'Invalid allowed domain. Use an exact DNS domain, without a wildcard, URL or address.'
        }
    }
}

function ConvertTo-ClaudeReportRecipient {
    param([string]$Address,[string[]]$AllowedDomains)
    Test-ClaudeReportDomains $AllowedDomains
    if ($Address -cmatch '[^\x21-\x7e]' -or $Address.Length -gt 254) { throw 'Invalid recipient address. Supply a bare ASCII email address, without a display name.' }
    try { $mail=New-Object Net.Mail.MailAddress($Address) } catch { throw 'Invalid recipient address.' }
    if ($mail.Address -cne $Address -or $mail.Host -notmatch '\.') { throw 'Invalid recipient address.' }
    if ($AllowedDomains -notcontains $mail.Host.ToLowerInvariant()) { throw 'Recipient domain is not in the allowed-domain list.' }
    return $mail.Address.ToLowerInvariant()
}

function New-ClaudeChargebackConfiguration {
    param([string[]]$AllowedDomains)
    Test-ClaudeReportDomains $AllowedDomains
    [pscustomobject][ordered]@{
        SchemaVersion=1; AllowedDomains=@($AllowedDomains | ForEach-Object {$_.ToLowerInvariant()} | Sort-Object -Unique)
        AllUnitsRecipients=@(); Units=@{}; BusinessUnits=@(); Formats=@('CSV','HTML')
        MonthToDate=$false; DeliveryEnabled=$true; RetentionDays=400
        UpdatedUtc=[datetime]::UtcNow.ToString('o'); Connection=[pscustomobject]@{}
    }
}

function Test-ClaudeChargebackConfiguration {
    param($Configuration)
    if ($Configuration.SchemaVersion -ne 1) { throw 'Unsupported chargeback configuration version.' }
    Test-ClaudeReportDomains @($Configuration.AllowedDomains)
    if ($Configuration.RetentionDays -lt 1 -or $Configuration.RetentionDays -gt 3650) { throw 'RetentionDays must be between 1 and 3650.' }
    if ($Configuration.MonthToDate -isnot [bool] -or $Configuration.DeliveryEnabled -isnot [bool]) { throw 'Period and delivery switches must be JSON booleans.' }
    if (-not @($Configuration.Formats).Count -or @($Configuration.Formats | Where-Object {$_ -notin @('CSV','HTML')}).Count) { throw 'Formats must contain CSV, HTML or both.' }
    if ($Configuration.DeliveryEnabled -and @($Configuration.Formats | Sort-Object -Unique).Count -ne 2) { throw 'Delivery requires both CSV and HTML formats.' }
    foreach($unit in $Configuration.BusinessUnits) { Get-ClaudeReportFileName $unit | Out-Null }
    foreach($address in $Configuration.AllUnitsRecipients) { ConvertTo-ClaudeReportRecipient $address $Configuration.AllowedDomains | Out-Null }
    $units=$Configuration.Units
    if ($units -isnot [Collections.IDictionary]) {
        $units=@{}
        foreach($p in $Configuration.Units.PSObject.Properties) { $units[$p.Name]=@($p.Value) }
    }
    foreach($unit in $units.Keys) {
        Get-ClaudeReportFileName $unit | Out-Null
        foreach($address in $units[$unit]) { ConvertTo-ClaudeReportRecipient $address $Configuration.AllowedDomains | Out-Null }
    }
    if (($Configuration | ConvertTo-Json -Depth 30 -Compress).Length -gt 4000000) { throw 'Configuration exceeds the 4 MB safety limit.' }
}

function Update-ClaudeChargebackRecipients {
    param($Configuration,[string]$Unit,[string[]]$Add,[string[]]$Remove)
    Test-ClaudeChargebackConfiguration $Configuration
    $copy=ConvertTo-ClaudeChargebackConfiguration $Configuration
    if ($Unit -ne 'all') { Get-ClaudeReportFileName $Unit | Out-Null }
    [string[]]$addresses=@(if($Unit -eq 'all') { $copy.AllUnitsRecipients } else { $copy.Units[$Unit] | Where-Object {$_} })
    $adds=@(foreach($a in $Add) { ConvertTo-ClaudeReportRecipient $a $copy.AllowedDomains })
    $removes=@(foreach($a in $Remove) { ConvertTo-ClaudeReportRecipient $a $copy.AllowedDomains })
    $result=@(($addresses + $adds) | ForEach-Object {$_.ToLowerInvariant()} | Where-Object {$_ -notin $removes} | Sort-Object -Unique)
    if($Unit -eq 'all') { $copy.AllUnitsRecipients=$result } else { $copy.Units[$Unit]=$result }
    $copy.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    Test-ClaudeChargebackConfiguration $copy
    return $copy
}

function Get-ClaudeChargebackRecipients {
    param($Configuration,[string]$Scope)
    Test-ClaudeChargebackConfiguration $Configuration
    $values=if($Scope -eq 'all') { @($Configuration.AllUnitsRecipients) } else { @($Configuration.Units[$Scope]) }
    $normalized=@(foreach($a in $values) { if($a) { ConvertTo-ClaudeReportRecipient $a $Configuration.AllowedDomains } })
    return ,@($normalized | Sort-Object -Unique)
}
