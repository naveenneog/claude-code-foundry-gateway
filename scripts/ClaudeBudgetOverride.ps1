function ConvertFrom-ClaudeBudgetOverrides {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { throw 'quota-overrides is unavailable; refusing an incomplete read.' }
    $map = [ordered]@{}
    if ($Value -eq ',,') { return $map }
    if ($Value -notmatch '^,.+,$') { throw 'quota-overrides requires sentinel commas.' }
    foreach ($entry in $Value.Trim(',').Split(',')) {
        $parts = $entry.Split('=')
        $parsed = [guid]::Empty
        $amount = [long]0
        if ($parts.Count -ne 2 -or -not [guid]::TryParse($parts[0], [ref]$parsed) -or
            -not [long]::TryParse($parts[1], [ref]$amount) -or $amount -lt 1 -or $map.Contains($parts[0])) {
            throw 'Malformed or duplicate quota override; refusing to discard another person''s budget.'
        }
        $map[$parts[0]] = $amount
    }
    return $map
}

function ConvertTo-ClaudeBudgetOverrides {
    param([System.Collections.IDictionary]$Overrides)
    if (-not $Overrides -or -not $Overrides.Count) { return ',,' }
    $value = ',' + (($Overrides.Keys | ForEach-Object { "$_=$($Overrides[$_])" }) -join ',') + ','
    ConvertFrom-ClaudeBudgetOverrides $value | Out-Null
    if ($value.Length -gt 4096) {
        throw 'The override map exceeds the gateway named-value capacity. No budget was written.'
    }
    return $value
}
