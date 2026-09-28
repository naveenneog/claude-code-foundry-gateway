function Stop-ClaudeAddressCheckProcess {
    param([Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    if ($PSVersionTable.PSEdition -eq 'Core') { $Process.Kill($true); return }
    $ids = New-Object 'Collections.Generic.List[int]'
    $ids.Add($Process.Id)
    for ($i=0; $i -lt $ids.Count; $i++) {
        foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($ids[$i])")) { $ids.Add([int]$child.ProcessId) }
    }
    foreach ($id in $ids) {
        $target=Get-Process -Id $id -ErrorAction SilentlyContinue
        if(-not $target){continue}
        try { Stop-Process -Id $id -Force -ErrorAction Stop }
        catch { if(Get-Process -Id $id -ErrorAction SilentlyContinue){throw} }
        if(-not $target.WaitForExit(1000)){throw "Address check child process $id did not stop."}
    }
}

function Invoke-ClaudeAddressCheck {
    param([scriptblock]$Check, [object[]]$Arguments = @(), [int]$TimeoutMilliseconds)
    if ($TimeoutMilliseconds -le 0) { throw [TimeoutException]::new('Address check deadline expired.') }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $payload = [Management.Automation.PSSerializer]::Serialize(@{
        module=(Join-Path $PSScriptRoot 'ClaudeGatewayAddress.ps1'); script=$Check.ToString(); arguments=@($Arguments)
    },100)
    $program = @'
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    $request=[Management.Automation.PSSerializer]::Deserialize([Console]::In.ReadToEnd())
    . $request.module
    $arguments=@($request.arguments)
    $state=& ([scriptblock]::Create($request.script)) @arguments
    [Console]::Out.Write([Management.Automation.PSSerializer]::Serialize($state,100))
} catch { [Console]::Error.Write($_.Exception.Message); exit 1 }
'@
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = (Get-Process -Id $PID).Path
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($program))
    $start.WorkingDirectory = (Get-Location).Path
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $process=$null
    try {
        $process=[Diagnostics.Process]::Start($start)
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $write=$process.StandardInput.WriteAsync($payload)
        $left=[Math]::Max(0,$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds)
        if(-not $write.Wait($left)){throw [TimeoutException]::new('Address check input exceeded its deadline.')}
        $process.StandardInput.Close()
        $left=[Math]::Max(0,$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds)
        if(-not $process.WaitForExit($left)){throw [TimeoutException]::new('Address check exceeded its deadline.')}
        $left=[Math]::Max(0,$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds)
        if(-not $stdout.Wait($left) -or -not $stderr.Wait([Math]::Max(0,$TimeoutMilliseconds-[int]$clock.ElapsedMilliseconds))){
            throw [TimeoutException]::new('Address check output exceeded its deadline.')
        }
        if($process.ExitCode -ne 0){throw "Address check failed: $($stderr.Result)"}
        if($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds){throw [TimeoutException]::new('Address check returned after its deadline.')}
        [Management.Automation.PSSerializer]::Deserialize($stdout.Result)
    }
    finally {
        if($process){try{Stop-ClaudeAddressCheckProcess $process}finally{$process.Dispose()}}
        $payload=$null
    }
}

function Wait-ClaudeAddress {
    param([string]$Condition,[string]$About,[double]$TimeoutSeconds=2700,[double]$PollSeconds=15,[scriptblock]$Check,[object[]]$Arguments=@())
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Write-Host ("Waiting for {0} ({1}; timeout {2} s)..." -f $Condition,$About,$TimeoutSeconds)
    $status='deadline expired'
    try {
        while($true){
            $left=[int][Math]::Max(0,[Math]::Floor($TimeoutSeconds*1000-$watch.Elapsed.TotalMilliseconds))
            if($left -le 0){throw [TimeoutException]::new($status)}
            $state=Invoke-ClaudeAddressCheck -Check $Check -Arguments $Arguments -TimeoutMilliseconds $left
            if($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw [TimeoutException]::new('check returned after its deadline')}
            if($state.Done){Write-Host ("  {0} ready in {1:N1} s." -f $Condition,$watch.Elapsed.TotalSeconds);return $state.Value}
            $status=[string]$state.Status
            Write-Host ("  {0}: {1}; elapsed {2:N1} s." -f $Condition,$status,$watch.Elapsed.TotalSeconds)
            $sleep=[int][Math]::Max(0,[Math]::Min($PollSeconds*1000,$TimeoutSeconds*1000-$watch.Elapsed.TotalMilliseconds))
            if($sleep){Start-Sleep -Milliseconds $sleep}
        }
    }
    catch [TimeoutException] {throw ("{0} timed out after {1:N1} s: {2}" -f $Condition,$watch.Elapsed.TotalSeconds,$_.Exception.Message)}
    finally {Write-Host ("  {0} wait ended after {1:N1} s." -f $Condition,$watch.Elapsed.TotalSeconds)}
}

function Invoke-ClaudeAddressArm {
    param([string]$Url,[string]$Method='get',$Body,[string]$StateDirectory,[switch]$AllowNotFound,[string]$IfMatch,[switch]$IfNoneMatch)
    $values=@{}
    foreach($key in $PSBoundParameters.Keys){
        $value=$PSBoundParameters[$key]
        $values[$key]=if($value -is [Management.Automation.SwitchParameter]){[bool]$value}else{$value}
    }
    Wait-ClaudeAddress -Condition "$Method ARM resource" -About 'about 4 s' -TimeoutSeconds 45 -Arguments @($values) -Check {
        param($values)
        @{Done=$true;Value=(Invoke-ClaudeNetworkArm @values)}
    }
}
