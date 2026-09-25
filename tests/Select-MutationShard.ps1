# Pure selection shared by listing and execution; compatible with PowerShell 5.1.
function Get-MutationShardIndices {
    param(
        [ValidateRange(1, 2147483647)][int]$Count,
        [string]$Shard = ''
    )
    $index = 0
    $parts = 1
    if ($Shard) {
        $match = [regex]::Match($Shard, '\A([0-9]+)/([1-9][0-9]*)\z')
        if (-not $match.Success -or
            -not [int]::TryParse($match.Groups[1].Value, [ref]$index) -or
            -not [int]::TryParse($match.Groups[2].Value, [ref]$parts) -or
            $parts -gt 16 -or $index -ge $parts) {
            throw 'Shard must be zero-based i/n, with 1 <= n <= 16 and 0 <= i < n (for example 0/4).'
        }
    }
    for ($i = $index; $i -lt $Count; $i += $parts) { $i }
}
