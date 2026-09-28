<#
.SYNOPSIS
    The guided flow's shared contract (ADR-0030): plans, costs, fingerprints, the decision record
    and step ordering. Dot-source this; it makes no Azure calls.
#>

$script:ClaudeFlowVerbs = @('Create', 'Update', 'Delete', 'Grant', 'Revoke', 'Deploy', 'Run', 'Write', 'Migrate', 'Check')

function New-ClaudeFlowAction {
    param(
        [Parameter(Mandatory = $true)][string]$Verb,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Detail = ''
    )
    if ($Verb -notin $script:ClaudeFlowVerbs) { throw "Unknown flow verb '$Verb'. Use one of: $($script:ClaudeFlowVerbs -join ', ')." }
    [pscustomobject][ordered]@{ Verb = $Verb; Target = $Target; Detail = $Detail }
}

function New-ClaudeFlowCost {
    param(
        [Parameter(Mandatory = $true)][string]$Item,
        [Nullable[decimal]]$MonthlyUsd = $null,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$RetrievedUtc = '',
        [string]$UnknownReason = ''
    )
    if ($null -ne $MonthlyUsd -and $MonthlyUsd -lt 0) { throw "Cost '$Item' is negative." }
    if ($null -eq $MonthlyUsd -and -not $UnknownReason) { throw "Cost '$Item' has no amount; give the reason it is unknown (-UnknownReason)." }
    [pscustomobject][ordered]@{
        Item = $Item
        MonthlyUsd = $MonthlyUsd
        Source = $Source
        RetrievedUtc = $RetrievedUtc
        UnknownReason = $UnknownReason
    }
}

function New-ClaudeFlowPlan {
    param(
        [string]$Step,
        [string]$Summary = '',
        [object[]]$Actions = @(),
        [object[]]$Costs = @(),
        [string[]]$Implications = @(),
        [string[]]$Requires = @(),
        [bool]$Reversible = $true,
        [string]$Rollback = '',
        [hashtable]$Data = @{}
    )
    if (-not $Step) { throw 'A flow plan needs a step name.' }
    [pscustomobject][ordered]@{
        Step = $Step
        Summary = $Summary
        Actions = @($Actions)
        Costs = @($Costs)
        Implications = @($Implications)
        Requires = @($Requires)
        Reversible = $Reversible
        Rollback = $Rollback
        Data = $Data
    }
}

function Test-ClaudeFlowPlanIsNoop {
    param([Parameter(Mandatory = $true)]$Plan)
    return (@($Plan.Actions).Count -eq 0)
}

function Get-ClaudeFlowTotalMonthlyUsd {
    param([object[]]$Plans = @())
    [decimal]$known = 0
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($plan in $Plans) {
        foreach ($cost in @($plan.Costs)) {
            if ($null -ne $cost.MonthlyUsd) { $known += [decimal]$cost.MonthlyUsd }
            else { $unknown.Add("$($cost.Item) ($($cost.UnknownReason))") }
        }
    }
    [pscustomobject]@{ KnownMonthlyUsd = $known; Unknown = @($unknown) }
}

function ConvertTo-ClaudeFlowJsonString {
    # A JSON string written the same way on every shell. ConvertTo-Json escapes ' < > & as \u0027 on
    # Windows PowerShell 5.1 and not on PowerShell 7, which gave one plan two fingerprints (P72).
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder ($Text.Length + 2)
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -lt 0x20 -or $code -gt 0x7e) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ClaudeFlowCanonical {
    # Sorted keys and invariant number formatting, so a fingerprint does not depend on property
    # order, culture or shell. RetrievedUtc is left out: re-reading an unchanged price is not a new plan.
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-ClaudeFlowJsonString $Value) }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [decimal] -or $Value -is [double] -or $Value -is [int] -or $Value -is [long]) { return ([decimal]$Value).ToString('0.############', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [System.Collections.IDictionary]) {
        # Ordinal: Sort-Object compares by culture, and .NET Framework and .NET sort punctuation differently.
        [string[]]$keys = @($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $pairs = foreach ($k in $keys) {
            if ($k -eq 'RetrievedUtc') { continue }
            (ConvertTo-ClaudeFlowJsonString $k) + ':' + (ConvertTo-ClaudeFlowCanonical $Value[$k])
        }
        return '{' + ($pairs -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return '[' + ((@($Value) | ForEach-Object { ConvertTo-ClaudeFlowCanonical $_ }) -join ',') + ']'
    }
    if ($Value -is [pscustomobject]) {
        $table = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $table[$p.Name] = $p.Value }
        return ConvertTo-ClaudeFlowCanonical $table
    }
    return (ConvertTo-ClaudeFlowJsonString ([string]$Value))
}

function Get-ClaudeFlowFingerprint {
    param([object[]]$Plans = @())
    $text = ConvertTo-ClaudeFlowCanonical @($Plans)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) } finally { $sha.Dispose() }
    return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
}

function Read-ClaudeDecisionRecord {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    try { return ($text | ConvertFrom-Json) }
    catch { throw "The decision record '$Path' is not valid JSON; fix or restore it before running the flow: $($_.Exception.Message)" }
}

function Get-ClaudeDecisionRecordVersion {
    param([Parameter(Mandatory = $true)]$Record)
    if ($Record.PSObject.Properties.Name -contains 'schemaVersion') { return [int]$Record.schemaVersion }
    return 1
}

function Set-ClaudeRecordProperty {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Set-ClaudeDecision {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Key, $Value)
    Set-ClaudeRecordProperty $Record 'schemaVersion' 2
    if (-not ($Record.PSObject.Properties.Name -contains 'decisions') -or $null -eq $Record.decisions) {
        Set-ClaudeRecordProperty $Record 'decisions' ([pscustomobject]@{})
    }
    $stored = if ($Value -is [System.Collections.IDictionary]) { [pscustomobject]$Value } else { $Value }
    Set-ClaudeRecordProperty $Record.decisions $Key $stored
}

function Get-ClaudeDecision {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Key)
    if (-not ($Record.PSObject.Properties.Name -contains 'decisions') -or $null -eq $Record.decisions) { return $null }
    if ($Record.decisions.PSObject.Properties.Name -contains $Key) { return $Record.decisions.$Key }
    return $null
}

function Add-ClaudeDecisionHistory {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Decision = '',
        $From = $null,
        $To = $null,
        [string]$Principal = '',
        [string]$Commit = ''
    )
    Set-ClaudeRecordProperty $Record 'schemaVersion' 2
    $history = [System.Collections.Generic.List[object]]::new()
    if ($Record.PSObject.Properties.Name -contains 'history' -and $null -ne $Record.history) {
        foreach ($entry in @($Record.history)) { $history.Add($entry) }
    }
    $history.Add([pscustomobject][ordered]@{
        utc = [DateTime]::UtcNow.ToString('o')
        action = $Action
        decision = $Decision
        from = $From
        to = $To
        by = $Principal
        commit = $Commit
    })
    Set-ClaudeRecordProperty $Record 'history' ([object[]]$history.ToArray())
}

function Set-ClaudeDecisionRelease {
    param([Parameter(Mandatory = $true)]$Record, [string]$Version = '', [string]$Commit = '')
    Set-ClaudeRecordProperty $Record 'schemaVersion' 2
    Set-ClaudeRecordProperty $Record 'release' ([pscustomobject][ordered]@{ version = $Version; commit = $Commit; appliedUtc = [DateTime]::UtcNow.ToString('o') })
}

function Write-ClaudeDecisionRecord {
    # Written beside the target and moved over it, so an interrupted write never leaves a half
    # record behind.
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $temp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temp, ($Record | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Get-ClaudeFlowReleaseInfo {
    param([string]$Repo = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
    # A copy without git, or not in a repository, records no commit instead of stopping the apply.
    # Continue: on Windows PowerShell 5.1 git's stderr under Stop is a terminating NativeCommandError.
    $commit = ''; $version = ''
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $commit = [string](git -C $Repo rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -ne 0) { $commit = '' }
            $version = [string](git -C $Repo describe --tags --always 2>$null)
            if ($LASTEXITCODE -ne 0) { $version = '' }
        }
        catch { $commit = ''; $version = '' }
        finally { $ErrorActionPreference = $saved }
    }
    [pscustomobject]@{ version = $version; commit = $commit }
}

function Get-ClaudeFlowRecordSubscription {
    # The one subscription the record names: top level first, then the foundation decision. Discovery
    # and the installer both use it, so they read and write the same subscription (ADR-0032).
    param($Record)
    if ($null -eq $Record) { return '' }
    if ($Record.PSObject.Properties.Name -contains 'subscriptionId' -and $Record.subscriptionId) { return ([string]$Record.subscriptionId).Trim() }
    $decision = Get-ClaudeDecision -Record $Record -Key foundation
    if ($decision -and $decision.PSObject.Properties.Name -contains 'subscriptionId' -and $decision.subscriptionId) { return ([string]$decision.subscriptionId).Trim() }
    return ''
}

function Test-ClaudeFlowSubscriptionId {
    param([string]$Value)
    return ($Value -match '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')
}

function Test-ClaudeFlowAzCmdShim {
    # On Windows az is az.cmd, and cmd.exe re-reads & | < > ^ ( ) " % in the arguments it is given.
    $az = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]($az -and $az.Source -match '\.(cmd|bat)$')
}

function Get-ClaudeFlowStepOrder {
    # Dependencies first; steps with no order between them keep the order they were given in.
    param([object[]]$Steps = @())
    $byName = @{}
    foreach ($s in $Steps) { $byName[$s.Name] = $s }
    foreach ($s in $Steps) {
        foreach ($d in @($s.DependsOn)) {
            if ($d -and -not $byName.ContainsKey($d)) { throw "Step '$($s.Name)' depends on unknown step '$d'." }
        }
    }
    $state = @{}
    $ordered = [System.Collections.Generic.List[object]]::new()
    $visit = $null
    $visit = {
        param($name)
        if ($state[$name] -eq 'done') { return }
        if ($state[$name] -eq 'visiting') { throw "Flow steps form a dependency cycle through '$name'." }
        $state[$name] = 'visiting'
        foreach ($d in @($byName[$name].DependsOn)) { if ($d) { & $visit $d } }
        $state[$name] = 'done'
        $ordered.Add($byName[$name])
    }
    foreach ($s in $Steps) { & $visit $s.Name }
    return @($ordered)
}

function Format-ClaudeFlowReview {
    param([object[]]$Plans = @())
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($plan in $Plans) {
        $lines.Add('')
        $lines.Add("[$($plan.Step)] $($plan.Summary)")
        if (Test-ClaudeFlowPlanIsNoop $plan) { $lines.Add('  no change'); continue }
        foreach ($a in $plan.Actions) { $lines.Add("  $($a.Verb.PadRight(8)) $($a.Target)$(if ($a.Detail) { " - $($a.Detail)" })") }
        foreach ($c in $plan.Costs) {
            $amount = if ($null -ne $c.MonthlyUsd) { '$' + ([decimal]$c.MonthlyUsd).ToString('N2', $inv) + '/month' } else { "unknown ($($c.UnknownReason))" }
            $lines.Add("  cost     $($c.Item): $amount [$($c.Source)]")
        }
        foreach ($i in $plan.Implications) { $lines.Add("  note     $i") }
        if (@($plan.Requires).Count) { $lines.Add("  needs    $($plan.Requires -join ', ')") }
        $lines.Add("  undo     $(if ($plan.Reversible) { $plan.Rollback } else { "not reversible: $($plan.Rollback)" })")
    }
    $total = Get-ClaudeFlowTotalMonthlyUsd -Plans $Plans
    $lines.Add('')
    $lines.Add("Known monthly cost at list price: `$$($total.KnownMonthlyUsd.ToString('N2', $inv))")
    foreach ($u in $total.Unknown) { $lines.Add("  plus $u") }
    return ($lines -join [Environment]::NewLine)
}
