$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeGatewayAddress.ps1')
$count=0;$failed=0
function Check([string]$Name,[scriptblock]$Test){
    $script:count++
    try{$ok=[bool](& $Test);$why=''}catch{$ok=$false;$why=$_.Exception.Message}
    if($ok){Write-Host "  [OK] $Name"}else{$script:failed++;Write-Host "  [FAIL] $Name $why"}
}
Check 'late success is rejected at the advertised deadline' {
    $watch=[Diagnostics.Stopwatch]::StartNew();$message=''
    try{Wait-ClaudeAddress -Condition 'slow check' -About 'about 1 s' -TimeoutSeconds 1 -Check {Start-Sleep -Milliseconds 1500;@{Done=$true;Value='too late'}}|Out-Null}
    catch{$message=$_.Exception.Message}
    $message -match 'timed out' -and $watch.Elapsed.TotalSeconds -lt 2.5
}
Check 'an early result retains its value and explicit arguments' {
    $r=Wait-ClaudeAddress -Condition 'quick check' -About 'about 1 s' -TimeoutSeconds 5 -Arguments @('preserved') -Check {param($value) @{Done=$true;Value=$value}}
    $r -eq 'preserved'
}
Check 'a zero deadline does not start a check' {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('deadline-sentinel-'+[guid]::NewGuid().ToString('N'))
    $message=''
    try{Wait-ClaudeAddress -Condition 'expired' -About 'no wait' -TimeoutSeconds 0 -Arguments @($path) -Check {param($p) [IO.File]::WriteAllText($p,'ran');@{Done=$true}}|Out-Null}
    catch{$message=$_.Exception.Message}
    $ran=Test-Path $path
    if($ran){Remove-Item -LiteralPath $path}
    $message -match 'timed out' -and -not $ran
}
$scratch=Join-Path ([IO.Path]::GetTempPath()) ('address-native-'+[guid]::NewGuid().ToString('N'))
$oldPath=$env:PATH;$oldProbe=$env:P69_DEADLINE_PROBE
try{
    New-Item -ItemType Directory -Path $scratch|Out-Null
    $probe=Join-Path $scratch 'pid.txt'
    [IO.File]::WriteAllText((Join-Path $scratch 'az.cmd'),"@echo off`r`n`"$((Get-Process -Id $PID).Path)`" -NoProfile -NonInteractive -File `"%~dp0block.ps1`"`r`n")
    [IO.File]::WriteAllText((Join-Path $scratch 'block.ps1'),'[IO.File]::WriteAllText($env:P69_DEADLINE_PROBE,[string]$PID); Start-Sleep -Seconds 30; ''{}''')
    $env:PATH=$scratch+[IO.Path]::PathSeparator+$oldPath;$env:P69_DEADLINE_PROBE=$probe
    Check 'native Azure reads are bounded and their child process is stopped' {
        $watch=[Diagnostics.Stopwatch]::StartNew();$message=''
        try{Wait-ClaudeAddress -Condition 'native Azure read' -About 'about 1 s' -TimeoutSeconds 4 -Check {Invoke-ClaudeNetworkAz @('account','show')|Out-Null;@{Done=$true}}|Out-Null}
        catch{$message=$_.Exception.Message}
        $nativeId=if(Test-Path $probe){[int][IO.File]::ReadAllText($probe)}else{0}
        $alive=$nativeId -and (Get-Process -Id $nativeId -ErrorAction SilentlyContinue)
        if($alive){Stop-Process -Id $nativeId -Force}
        $message -match 'timed out' -and $watch.Elapsed.TotalSeconds -lt 8 -and $nativeId -gt 0 -and -not $alive
    }
}finally{$env:PATH=$oldPath;$env:P69_DEADLINE_PROBE=$oldProbe;if(Test-Path $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}}
Write-Host "Address deadline: $count assertions, $($count-$failed) passed, $failed failed."
if($failed){exit 1}
