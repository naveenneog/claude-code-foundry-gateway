# Budget mode metadata stays separate from the legacy group:tokens registry.
# Dot-sourced by ClaudeBusinessUnit.ps1.

function ConvertTo-ClaudeBudgetMode {
    param([AllowNull()]$Mode, [AllowNull()]$AllowancePercent)
    if ($null -eq $Mode) { $Mode = 'strict' }
    if ($Mode -isnot [string] -or $Mode -cnotin @('strict', 'allowance', 'notify')) {
        throw 'enforcement must be strict, allowance or notify (missing means strict).'
    }
    if ($Mode -eq 'allowance') {
        if (($AllowancePercent -isnot [int] -and $AllowancePercent -isnot [long]) -or
            $AllowancePercent -lt 1 -or $AllowancePercent -gt 100) {
            throw 'allowance_percent must be an integer from 1 to 100 for allowance.'
        }
        return "allowance:$AllowancePercent"
    }
    if ($null -ne $AllowancePercent) { throw 'allowance_percent is only valid with allowance.' }
    return $Mode
}

function ConvertFrom-ClaudeBuModes {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq ',,') { return $map }
    if ($Value -notmatch '^,.+,$') { throw 'bu-modes must have sentinel commas.' }
    $seen = @{}
    foreach ($entry in $Value.Trim(',').Split(',')) {
        if ($entry -cnotmatch '^([a-z0-9][a-z0-9-]*)=(strict|notify|allowance:([1-9][0-9]?|100))$') {
            throw "Invalid bu-modes entry '$entry'."
        }
        $id = $Matches[1]; $mode = $Matches[2]
        if ($seen.ContainsKey($id)) { throw "Duplicate bu-modes id '$id'." }
        $seen[$id] = $true
        if ($mode -ne 'strict') { $map[$id] = $mode }
    }
    return $map
}

function ConvertTo-ClaudeBuModes {
    param([AllowNull()][System.Collections.IDictionary]$Modes)
    if (-not $Modes -or -not $Modes.Count) { return ',,' }
    $raw = ',' + ((@($Modes.Keys) | ForEach-Object { "$_=$($Modes[$_])" }) -join ',') + ','
    $validated = ConvertFrom-ClaudeBuModes $raw
    if (-not $validated.Count) { return ',,' }
    return ',' + ((@($validated.Keys) | ForEach-Object { "$_=$($validated[$_])" }) -join ',') + ','
}

function Get-ClaudeBudgetModeAttributes {
    param([string]$Id, [AllowNull()][System.Collections.IDictionary]$Modes)
    $mode = if ($Modes -and $Modes.Contains($Id)) { [string]$Modes[$Id] } else { 'strict' }
    $checked = ConvertFrom-ClaudeBuModes ",$Id=$mode,"
    if (-not $checked.Count) { return [ordered]@{ enforcement = 'strict' } }
    if ($mode.StartsWith('allowance:')) {
        return [ordered]@{ enforcement = 'allowance'; allowance_percent = [int]$mode.Split(':')[1] }
    }
    return [ordered]@{ enforcement = 'notify' }
}
