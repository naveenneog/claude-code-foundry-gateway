$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\ClaudeAumDirectWrites.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ClaudeBudgetOverride.ps1')
$script:checks = 0
function Assert($condition, $message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
$read = { $script:state.Clone() }
$write = { param($key,$value) $script:state[$key] = $value }
$remove = { param($key) $script:state.Remove($key) }
$before = [ordered]@{ first='old-one'; second='old-two' }
$after = [ordered]@{ first='new-one'; second='new-two' }
$script:state = @{ first='old-one'; second='old-two' }
$result = Invoke-AumVerifiedWrite -Before $before -After $after -Read $read -Write $write -Remove $remove `
    -Operation { $script:state.first='new-one'; $script:state.second='new-two' }
Assert $result.verified 'Successful multi-value writes need read-back.'
Assert ($script:state.second -eq 'new-two') 'Both desired values should persist.'
$script:ran = $false
$result = Invoke-AumVerifiedWrite -Before $after -After $after -Read $read -Write $write -Remove $remove `
    -Operation { $script:ran=$true }
Assert (-not $script:ran -and $result.verified) 'Already-equal state must not run the writer again.'

$script:state = @{ first='old-one'; second='old-two' }
$message = ''
try {
    Invoke-AumVerifiedWrite -Before $before -After $after -Read $read -Write $write -Remove $remove `
        -Operation { $script:state.first='new-one'; throw 'second write failed' }
} catch { $message=$_.Exception.Message }
Assert ($message -match 'restored and verified') 'A failed later write must prove rollback.'
Assert ($script:state.first -eq 'old-one' -and $script:state.second -eq 'old-two') 'Restore exact originals.'

$script:state = @{ first='old-one'; second='old-two' }
try {
    Invoke-AumVerifiedWrite -Before $before -After $after -Read $read -Write $write -Remove $remove `
        -Operation { $script:state.first='new-one' }
} catch { $message=$_.Exception.Message }
Assert ($message -match 'restored and verified') 'Silent read-back mismatch must also compensate.'

$script:state = @{ first='old-one'; second='old-two' }
try {
    Invoke-AumVerifiedWrite -Before $before -After $after -Read $read -Write $write -Remove $remove `
        -Operation { $script:state.first='third-party'; throw 'write race' }
} catch { $message=$_.Exception.Message }
Assert ($message -match 'manual recovery') 'Concurrent third-party state must never be clobbered by rollback.'
Assert ($script:state.first -eq 'third-party') 'Preserve third-party write.'

$script:state = @{ first='old-one'; second='old-two' }
try {
    Invoke-AumVerifiedWrite -Before $before -After $after -Read $read `
        -Write { throw 'restore failed' } -Remove $remove `
        -Operation { $script:state.first='new-one'; throw 'later write failed' }
} catch { $message=$_.Exception.Message }
Assert ($message -match 'manual recovery') 'A failed restore must not claim success.'

$script:state = @{}
try {
    Invoke-AumVerifiedWrite -Before @{} -After @{created='new'} -Read $read -Write $write -Remove $remove `
        -Operation { $script:state.created='new'; throw 'later step failed' }
} catch { $message=$_.Exception.Message }
Assert (-not $script:state.ContainsKey('created')) 'Restore absence by removing only the value this write created.'

$id = '00000000-0000-0000-0000-000000000001'
$raw = ",$id=1234,"
$parsed = ConvertFrom-ClaudeBudgetOverrides $raw
Assert ($parsed[$id] -eq 1234) 'Shared per-person parser reads exact daily tokens.'
Assert ((ConvertTo-ClaudeBudgetOverrides $parsed) -ceq $raw) 'Shared serializer round-trips existing override bytes.'
foreach ($invalid in @(",bad=1,",",$id=0,",",$id=1,$id=2,",",$id=9223372036854775808,")) {
    $refused=$false
    try { ConvertFrom-ClaudeBudgetOverrides $invalid | Out-Null } catch { $refused=$true }
    Assert $refused 'Malformed/duplicate overrides must be refused, never silently dropped.'
}
Write-Host "$script:checks AUM Direct write and override assertions passed."
