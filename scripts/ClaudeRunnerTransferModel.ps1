# The runner transfer's time model (ADR-0053). scripts/ClaudeRunner.ps1 uses it for Send-RunnerFile's estimate,
# and the update flow's plan (scripts/ClaudeEntitlementMigration.ps1) for a snapshot it has not exported yet, so
# the plan does not load the runner itself.

# The mean time of one exec when this many run at once, measured on 2026-10-06 against a 2-CPU runner in
# East US 2 (ADR-0053). A parallelism between two measured values takes the higher time.
function Get-ClaudeRunnerExecSeconds([int]$Parallel) {
    foreach ($measured in @(@(1, 6.3), @(4, 6.9), @(8, 8.1), @(16, 10.9))) {
        if ($Parallel -le $measured[0]) { return [double]$measured[1] }
    }
    return 15.6
}

# The waves of parts at the time of one exec, plus the directory exec and the assembly exec.
function Get-ClaudeRunnerTransferWaveSeconds([long]$Parts, [int]$Effective, [double]$SecondsPerExec) {
    return ([long][Math]::Ceiling($Parts / [Math]::Max(1, $Effective)) + 2) * $SecondsPerExec
}

# The transfer time of a file not yet written: this many bytes, compressed at the ratio measured for a 500,000-record
# snapshot (12,126,017 of 63,152,686 bytes, U132), sent as base64url in parts of about 4,860 characters, 16 at a time.
function Get-ClaudeRunnerTransferSeconds {
    param([Parameter(Mandatory)][long]$Bytes, [double]$CompressedRatio = 0.192, [ValidateRange(1, 24)][int]$Parallel = 16, [int]$ChunkSize = 4860)
    $characters = [Math]::Ceiling([Math]::Max(1, $Bytes) * $CompressedRatio * 4 / 3)
    $parts = [Math]::Max(1, [long][Math]::Ceiling($characters / $ChunkSize))
    $effective = [int][Math]::Min($Parallel, $parts)
    return Get-ClaudeRunnerTransferWaveSeconds -Parts $parts -Effective $effective -SecondsPerExec (Get-ClaudeRunnerExecSeconds $effective)
}
