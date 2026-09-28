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
Check 'a redirected temporary directory is refused before executing a check' {
    $errorText=''
    try{Assert-ClaudeAddressCheckDirectory -ExpectedDirectory 'Z:\not-the-owned-check-directory'}catch{$errorText=$_.Exception.Message}
    $errorText -match 'differs from its parent-owned directory'
}
$temporaryRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Temp'
$scratch=Join-Path $temporaryRoot ('address-native-'+[guid]::NewGuid().ToString('N'))
$oldPath=$env:PATH;$oldProbe=$env:P69_DEADLINE_PROBE
try{
    New-Item -ItemType Directory -Path $scratch|Out-Null
    Check 'timed-out checks leave no private ARM body directory behind' {
        $witness=Join-Path $scratch 'private-directory.txt'
        $message=''
        try {
            Wait-ClaudeAddress -Condition 'private body' -About 'about 1 s' -TimeoutSeconds 3 -Arguments @($witness) -Check {
                param($witness)
                $dir=[IO.Path]::GetTempPath()
                [IO.File]::WriteAllText($witness,$dir)
                [IO.File]::WriteAllText((Join-Path $dir 'private-arm-fixture.txt'),'fixture-only')
                Start-Sleep -Seconds 30
                @{Done=$true}
            } | Out-Null
        } catch {$message=$_.Exception.Message}
        $dir=if(Test-Path $witness){[IO.File]::ReadAllText($witness)}else{''}
        $left=$dir -and (Test-Path -LiteralPath (Join-Path $dir 'private-arm-fixture.txt'))
        if($left){Remove-Item -LiteralPath (Join-Path $dir 'private-arm-fixture.txt')}
        if(-not ($message -match 'timed out' -and $dir -like '*claude-address-check-*' -and -not $left -and -not (Test-Path -LiteralPath $dir))){
            throw "Private directory check: message=$message; directory=$dir; file remained=$left"
        }
        $true
    }
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
        if(-not ($message -match 'timed out' -and $watch.Elapsed.TotalSeconds -lt 8 -and $nativeId -gt 0 -and -not $alive)){
            throw "Native deadline check: message=$message; child=$nativeId; alive=$alive; elapsed=$($watch.Elapsed.TotalSeconds)"
        }
        $true
    }
}finally{$env:PATH=$oldPath;$env:P69_DEADLINE_PROBE=$oldProbe;if(Test-Path $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}}
Write-Host "Address deadline: $count assertions, $($count-$failed) passed, $failed failed."
if($failed){exit 1}
