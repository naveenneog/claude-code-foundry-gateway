# Pure assignment of cli/finops test files to Test-All checks (tests/README.md, "AUM test shards").
# Longest first by committed per-file seconds; equal weights keep ordinal file order, and equal
# loads choose the lower shard. The result depends only on the file names and the timing table.
function ConvertFrom-FinOpsShard([string]$Shard) {
    $index = 0
    $count = 0
    $match = [regex]::Match($Shard, '\A([0-9]+)/([1-9][0-9]*)\z')
    if (-not $match.Success -or
        -not [int]::TryParse($match.Groups[1].Value, [ref]$index) -or
        -not [int]::TryParse($match.Groups[2].Value, [ref]$count) -or
        $count -gt 16 -or $index -ge $count) {
        throw 'Shard must be zero-based i/n, with 1 <= n <= 16 and 0 <= i < n (for example 0/4).'
    }
    [pscustomobject]@{ Index = $index; Count = $count }
}

# pytest's default python_files patterns; cli/finops/pyproject.toml sets only testpaths.
# Top level only: Test-FinOpsShards.ps1 compares this list with pytest's own collection.
function Get-FinOpsTestFile([string]$Directory) {
    $names = [string[]]@(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object { $_.Name -like 'test_*.py' -or $_.Name -like '*_test.py' } |
        ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $names
}

function Test-FinOpsWholeNumber($Value) {
    ($Value -is [int] -or $Value -is [long]) -and $Value -gt 0
}

function Read-FinOpsTiming([string]$Path) {
    $timing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    # [pscustomobject] means [psobject], which also matches wrapped numbers and strings.
    $valid = (Test-FinOpsWholeNumber $timing.SchemaVersion) -and $timing.SchemaVersion -eq 1 -and
        (Test-FinOpsWholeNumber $timing.DefaultSeconds) -and
        $timing.Seconds -is [Management.Automation.PSCustomObject]
    if ($valid) {
        foreach ($entry in $timing.Seconds.PSObject.Properties) {
            if (-not (Test-FinOpsWholeNumber $entry.Value)) { $valid = $false }
        }
    }
    if (-not $valid) {
        throw "Invalid AUM test timing in ${Path}: SchemaVersion 1, and whole positive DefaultSeconds and Seconds values."
    }
    $timing
}

# One row per file, in ordinal file order: Name, Seconds (planned weight) and Shard.
function Get-FinOpsShardPlan([string[]]$File, $Timing, [int]$Count) {
    if ($Count -lt 1 -or $Count -gt 16) { throw 'The shard count must be 1-16.' }
    $names = [string[]]@($File)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $weights = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Timing.Seconds.PSObject.Properties) { $weights[$entry.Name] = [long]$entry.Value }
    $rows = @(for ($i = 0; $i -lt $names.Count; $i++) {
        if ($i -and $names[$i] -ceq $names[$i - 1]) { throw "Duplicate AUM test file: $($names[$i])" }
        $seconds = [long]$Timing.DefaultSeconds
        if ($weights.ContainsKey($names[$i])) { $seconds = $weights[$names[$i]] }
        [pscustomobject]@{ Name = $names[$i]; Seconds = $seconds; Shard = -1; Rank = $i }
    })
    $loads = [long[]]::new($Count)
    $order = @($rows | Sort-Object @{ Expression = 'Seconds'; Descending = $true }, @{ Expression = 'Rank'; Descending = $false })
    foreach ($row in $order) {
        $bin = 0
        for ($b = 1; $b -lt $Count; $b++) { if ($loads[$b] -lt $loads[$bin]) { $bin = $b } }
        $row.Shard = $bin
        $loads[$bin] += $row.Seconds
    }
    $rows | Select-Object Name, Seconds, Shard
}
