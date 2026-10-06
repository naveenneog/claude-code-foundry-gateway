<#
.SYNOPSIS
    Copies files into, and runs commands in, the in-VNet runner container.

.DESCRIPTION
    The projection's Cosmos account and the resolver have no public endpoint,
    so anything that writes or measures them runs inside the VNet. The runner
    is an Azure Container Instance there (infra/projection-network.bicep).

    `az container exec` is the only way in, and it has three properties that
    shape this file, all measured 2026-09-23:

      - the command is split on spaces and run without a shell, so there is
        no redirection, no quoting and no pipes;
      - it is URL-decoded on the way in, so '+' becomes a space and '%XX'
        becomes a character;
      - it must be under 5,000 characters, or it fails with
        InvalidCommandLength;
      - one exec is about five seconds, whatever it does.

    So a file travels as base64url in parts, each written by a one-line
    `node -e` program that contains no spaces. base64url has no character
    that cmd.exe, PowerShell, URL decoding or the ACI tokenizer treats
    specially. Since P99 (ADR-0053) the file is gzip-compressed first, up to
    16 parts are written at once, each in its own exec, and one exec
    assembles, decompresses and checks the file with a SHA-256.

.EXAMPLE
    . ./scripts/ClaudeRunner.ps1
    Send-RunnerFile -ResourceGroup rg -Name aci-projtest-x -Path ./snapshot.json -Destination /work/snapshot.json
    Invoke-RunnerCommand -ResourceGroup rg -Name aci-projtest-x -Command 'node --version'
#>

    function Assert-ClaudeRunnerAzName {
        param([AllowEmptyString()][string]$Value)
        if ($Value -and $Value -notmatch '^[A-Za-z0-9._-]+$') { throw "Runner command refused: '$Value' is not a name of letters, digits, '.', '_' or '-'." }
    }

    function Start-ClaudeProjectionRunner {
        param(
            [Parameter(Mandatory)][string]$ResourceGroup,
            [Parameter(Mandatory)][string]$Name,
            [string]$SubscriptionId,
            [int]$WaitTimeoutSeconds = 600,
            [int]$PollSeconds = 10
        )
        foreach ($target in @($ResourceGroup, $Name, $SubscriptionId)) { Assert-ClaudeRunnerAzName $target }
        if ($WaitTimeoutSeconds -lt 1 -or $WaitTimeoutSeconds -gt 3600) { throw 'Runner wait timeout must be between 1 and 3600 seconds.' }
        if ($PollSeconds -lt 1 -or $PollSeconds -gt 120) { throw 'Runner poll interval must be between 1 and 120 seconds.' }
        $subscriptionArgs = @()
        if ($SubscriptionId) { $subscriptionArgs = @('--subscription', $SubscriptionId) }
        function ReadRunnerState {
            $saved = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $global:LASTEXITCODE = 0
                $out = @(az container show -g $ResourceGroup -n $Name --query instanceView.state -o tsv @subscriptionArgs 2>&1)
                $code = $LASTEXITCODE
            } finally { $ErrorActionPreference = $saved }
            if ($code -ne 0) { throw "Could not read runner '$Name' in '$ResourceGroup' (az exit $code). Remedy: redeploy with scripts/Deploy-ClaudeProjection.ps1 and verify the operator can read the container group." }
            return (($out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | Select-Object -Last 1) -as [string]).Trim()
        }
        $state = ReadRunnerState
        if ($state -eq 'Running') { return [pscustomobject]@{ ResourceGroup=$ResourceGroup; Name=$Name; State=$state } }
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            $out = @(az container start -g $ResourceGroup -n $Name @subscriptionArgs 2>&1)
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $saved }
        if ($code -ne 0) { throw "Could not start runner '$Name' (az exit $code). Remedy: redeploy with scripts/Deploy-ClaudeProjection.ps1, then rerun the sync." }
        $waited = 0
        while ($waited -lt $WaitTimeoutSeconds) {
            Start-Sleep -Seconds $PollSeconds
            $waited += $PollSeconds
            $state = ReadRunnerState
            if ($state -eq 'Running') { return [pscustomobject]@{ ResourceGroup=$ResourceGroup; Name=$Name; State=$state } }
        }
        throw "Runner '$Name' did not reach Running within $WaitTimeoutSeconds seconds (last state '$state'). Remedy: inspect 'az container show -g $ResourceGroup -n $Name', or redeploy with scripts/Deploy-ClaudeProjection.ps1."
    }

    function Invoke-RunnerCommand {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string]$Container = 'runner',
        [string]$SubscriptionId
    )
    Assert-ClaudeRunnerCommandText $Command
    foreach ($target in @($ResourceGroup, $Name, $Container, $SubscriptionId)) { Assert-ClaudeRunnerAzName $target }
    $exec = Invoke-ClaudeRunnerExec -Arguments (Get-ClaudeRunnerExecArguments -ResourceGroup $ResourceGroup -Name $Name -Container $Container -SubscriptionId $SubscriptionId -Command $Command)
    $out = $exec.Output
    $code = $exec.ExitCode
    if ($code -ne 0) {
        Write-ClaudeRunnerOutput -RawOutput $out -Step 'runner transport'
        throw "runner transport failed (az exit $code)."
    }
    return $out.Trim()
}

# The runner splits the command on spaces with no quoting and URL-decodes it, and az.cmd hands every
# argument to cmd.exe: a quote, '+', '%' or a cmd.exe metacharacter cannot pass through unchanged.
function Assert-ClaudeRunnerCommandText([string]$Command) {
    if ($Command -match '["%+&|<>^\r\n]') {
        throw 'Runner command refused: it holds a quote, +, %, &, |, <, >, ^ or a line break, which the runner or cmd.exe would change.'
    }
}

function Get-ClaudeRunnerExecArguments {
    param([string]$ResourceGroup, [string]$Name, [string]$Container = 'runner', [string]$SubscriptionId, [string]$Command)
    $arguments = @('container','exec','-g',$ResourceGroup,'-n',$Name,'--container-name',$Container,'--exec-command',$Command)
    if ($SubscriptionId) { $arguments += @('--subscription',$SubscriptionId) }
    return ,$arguments
}

# One exec through whatever `az` resolves to here, without throwing: the caller decides what a failure means.
function Invoke-ClaudeRunnerExec {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $out = & az @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{ ExitCode = $code; Output = [string]$out }
}

# A writer refusal's stage and remedy are shown; its error text, which can name holders and counts, is not.
# The remedy is the writer's fixed guidance: printable ASCII, with no address and no object id.
function Test-ClaudeRunnerStage([string]$Stage) { return ($Stage -cmatch '^[a-z][a-z-]{0,39}\z') }
function Test-ClaudeRunnerRemedy([string]$Remedy) {
    return ($Remedy -cmatch '^Remedy: [\x20-\x7E]{1,400}\z' -and $Remedy -notmatch '@' -and
        $Remedy -notmatch '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
}

function Write-ClaudeRunnerOutput {
    param([AllowEmptyString()][string]$RawOutput, [string]$Step)
    # At most 40 lines and 4,096 characters in total: this heading and a truncation marker count.
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("$Step sanitized runner output (at most 40 lines and 4096 characters, this line included):")
    foreach ($line in @($RawOutput.TrimEnd("`r", "`n") -split '\r?\n' | Select-Object -Last 39)) {
        $doc = $null
        if ($line.TrimStart().StartsWith('{')) {
            try { $doc = $line | ConvertFrom-Json -ErrorAction Stop }
            catch { $doc = $null }
        }
        $safe = [Collections.Generic.List[string]]::new()
        if ($doc) {
            foreach ($field in 'ok','whatIf','expired','compared','projectionRecords','differences','resolved','existing','toWrite','toDelete','keptOrphans','unchanged','written','writeFailed','deleted','deleteFailed','seconds') {
                $property = $doc.PSObject.Properties[$field]
                if ($property -and ($property.Value -is [bool] -or $property.Value -is [ValueType] -and $property.Value -isnot [DateTime] -and $property.Value -isnot [DateTimeOffset])) {
                    $safe.Add("$field=$($property.Value)")
                }
            }
            $stage = $doc.PSObject.Properties['stage']
            if ($stage -and (Test-ClaudeRunnerStage ([string]$stage.Value))) { $safe.Add("stage=$($stage.Value)") }
            $remedy = $doc.PSObject.Properties['remedy']
            if ($remedy -and (Test-ClaudeRunnerRemedy ([string]$remedy.Value))) { $safe.Add("remedy=$($remedy.Value)") }
            $samples = $doc.PSObject.Properties['sample']
            if ($samples) {
                foreach ($sample in @($samples.Value | Select-Object -First 3)) {
                    $oid = $sample.PSObject.Properties['oid']
                    if ($oid) { $safe.Add('oid-sha256=' + (Get-ClaudeRunnerDigest ([string]$oid.Value))) }
                }
            }
        }
        if (-not $safe.Count) { $safe.Add("redacted unstructured output: chars=$($line.Length), sha256=$(Get-ClaudeRunnerDigest $line)") }
        $lines.Add($safe -join '; ')
    }
    $output = $lines -join "`n"
    if ($output.Length -gt 4096) {
        $kept = @($output.Substring(0, 4084) -split "`n" | Select-Object -First 39)
        $output = ($kept -join "`n") + "`n[truncated]"
    }
    Write-Host $output -ForegroundColor Yellow
}

function Get-ClaudeRunnerDigest {
    param([AllowEmptyString()][string]$Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').Substring(0,12).ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertFrom-ClaudeRunnerResult {
    param([AllowEmptyString()][string]$RawOutput, [string]$Step)
    $result = $null
    try {
        $last = $RawOutput.TrimEnd("`r", "`n") -split '\r?\n' | Select-Object -Last 1
        $result = $last | ConvertFrom-Json -ErrorAction Stop
    } catch { $result = $null }
    if ($result -and $result.ok -is [bool] -and $result.ok) { return $result }
    Write-ClaudeRunnerOutput -RawOutput $RawOutput -Step $Step
    # A writer refusal (ok:false with a stage) is named with its remedy; anything else is malformed.
    if ($result -and $result.ok -is [bool] -and $result.PSObject.Properties['stage'] -and (Test-ClaudeRunnerStage ([string]$result.stage))) {
        $remedy = if ($result.PSObject.Properties['remedy'] -and (Test-ClaudeRunnerRemedy ([string]$result.remedy))) { " $([string]$result.remedy)" } else { '' }
        throw "$Step refused at stage $([string]$result.stage).$remedy Sanitized diagnostics are shown above."
    }
    throw "$Step failed: runner summary is malformed or not boolean ok:true. Sanitized diagnostics are shown above."
}

# A snapshot's apply-by time, from the expiresAt (Unix seconds) in its header; $null for a file without one.
# The header comes before the records, so the first 64 KB holds it.
function Get-RunnerFileDeadline {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try { $buffer = New-Object byte[] 65536; $read = $stream.Read($buffer, 0, $buffer.Length) }
    finally { $stream.Dispose() }
    $found = [regex]::Match([Text.Encoding]::UTF8.GetString($buffer, 0, $read), '"expiresAt"\s*:\s*(\d{9,12})\b')
    if (-not $found.Success) { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$found.Groups[1].Value)
}

# The mean time of one exec when this many run at once, measured on 2026-10-06 against a 2-CPU runner in
# East US 2 (ADR-0053). A parallelism between two measured values takes the higher time.
function Get-ClaudeRunnerExecSeconds([int]$Parallel) {
    foreach ($measured in @(@(1, 6.3), @(4, 6.9), @(8, 8.1), @(16, 10.9))) {
        if ($Parallel -le $measured[0]) { return [double]$measured[1] }
    }
    return 15.6
}

# The clock the apply-by checks read; the tests replace it.
function Get-ClaudeRunnerNow { return [DateTimeOffset]::UtcNow }

function Get-ClaudeRunnerTransferRemedy([string]$ResourceGroup, [string]$Name) {
    return ("On 2026-10-06 a snapshot of 500,000 developers took 41 minutes through the runner, in 3,336 parts sent 16 at a time (ADR-0053). " +
        "A full sync that does not fit runs in the optional sync job, which reads Microsoft Graph inside the network and needs the GroupMember.Read.All grant that its " +
        "deployment prints: .\scripts\Deploy-ClaudeProjectionRenewal.ps1 -ResourceGroup $ResourceGroup -ApimName <apim> -NamePrefix $($Name -replace '^aci-projtest-', '') " +
        "-AlertEmail <address>, then az containerapp job start.")
}

# No declaration keyword: `const f` needs a space, which exec would split on, and `const$f` is a single
# identifier. node -e is sloppy mode, so a bare assignment is enough. The program prints the part's own
# index and length, and only that line shows the part was written. The length is printed as a string:
# the runner runs each exec in a terminal, where console.log colours a number (measured 2026-10-06).
function New-ClaudeRunnerPartCommand([string]$PartDir, [int]$Index, [string]$Payload) {
    $file = "$PartDir/" + $Index.ToString('000000')
    return "node -e f=require('fs');p='$file';f.writeFileSync(p,'$Payload');console.log('ok',p.slice(-6),String(f.statSync(p).size))"
}

function Get-ClaudeRunnerPartProblem {
    param($Result, [int]$Index, [int]$Length)
    if ($null -eq $Result) { return 'no result' }
    if ($Result.ExitCode -ne 0) { return "az exit $($Result.ExitCode)" }
    # An exec that fails prints its error and nothing else; ignoring it is how a copy silently arrives empty.
    if ([string]$Result.Output -match 'ERROR|InvalidCommandLength|terminated with non-zero') { return 'the exec reported an error' }
    $acknowledgement = 'ok {0} {1}' -f $Index.ToString('000000'), $Length
    $lines = @((([string]$Result.Output) -replace '\x1b\[[0-9;]*[A-Za-z]', '') -split '\r?\n' | ForEach-Object { $_.Trim() })
    if ($lines -notcontains $acknowledgement) { return "no acknowledgement '$acknowledgement'" }
    return $null
}

function ConvertTo-ClaudeRunnerGzip([byte[]]$Bytes) {
    $buffer = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
    try { $gzip.Write($Bytes, 0, $Bytes.Length) } finally { $gzip.Dispose() }
    return ,$buffer.ToArray()
}

# Ends the processes of one exec. The part's file path is unique to the transfer and the part, and every
# process of the exec (cmd.exe, the Azure CLI's python, a test's fake) carries it on its command line.
# PowerShell's Stop() alone waits for a child process that still holds the output pipe.
function Stop-ClaudeRunnerExecProcess([string]$Needle) {
    $ids = if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        @(Get-CimInstance Win32_Process -Filter ("CommandLine LIKE '%{0}%'" -f $Needle) -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId })
    }
    else { @(Get-Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Needle) } | ForEach-Object { $_.Id }) }
    foreach ($id in $ids) { if ($id -ne $PID) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
}

function Send-RunnerFile {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [int]$ChunkSize = 4900,
        [string]$SubscriptionId,
        # A snapshot's apply-by time (Get-RunnerFileDeadline). A transfer estimated to end after it is refused
        # before the first exec (P98 council round 2), and one whose measured rate projects past it stops (ADR-0053).
        [Nullable[DateTimeOffset]]$Deadline,
        # Kept before the apply-by time for the steps after the transfer: unpacking, installing, and the
        # writer's read of the projection before its first write, where it checks the apply-by time again.
        [ValidateRange(0, 3600)][int]$ReserveSeconds = 600,
        [ValidateRange(1, 24)][int]$Parallel = 16,
        [ValidateRange(1, 5)][int]$Attempts = 3,
        # An exec that has not returned after this long is stopped and its part retried (parallel path only).
        [ValidateRange(10, 3600)][int]$ExecTimeoutSeconds = 120,
        # The mean time of one exec at the parallelism used; by default the measured value.
        [double]$SecondsPerExec
    )
    if ($Destination -match '\s') { throw "Destination '$Destination' contains a space; exec cannot pass it." }
    # The destination is written into node programs inside single quotes.
    if ($Destination -notmatch '^(/[A-Za-z0-9._-]+){2,}$') { throw "Destination '$Destination' is not an absolute runner path of letters, digits, '.', '_' and '-' below a directory." }
    foreach ($target in @($ResourceGroup, $Name, $SubscriptionId)) { Assert-ClaudeRunnerAzName $target }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
    $compressed = ConvertTo-ClaudeRunnerGzip $bytes
    # base64url, not base64. The exec command is URL-decoded on its way in:
    # '+' arrives as a space - which then splits the argument - and '%2B'
    # arrives as '+' (measured 2026-09-23). base64url uses '-' and '_' instead,
    # which survive, and Node decodes it natively.
    $b64 = [Convert]::ToBase64String($compressed).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $dir = ($Destination -replace '/[^/]+$', '')
    $partDir = "$dir/.xfer-" + [guid]::NewGuid().ToString('N').Substring(0, 16)
    # ACI refuses an exec command of 5,000 characters or more with
    # InvalidCommandLength (measured 2026-09-23), so a part is whatever fits
    # under that once the surrounding program is counted.
    $overhead = (New-ClaudeRunnerPartCommand -PartDir $partDir -Index 0 -Payload '').Length
    $ChunkSize = [Math]::Min($ChunkSize, 4990 - $overhead)
    $parts = [Math]::Max(1, [int][Math]::Ceiling($b64.Length / $ChunkSize))
    $payloadOf = { param([int]$Index) $at = ($Index - 1) * $ChunkSize; $b64.Substring($at, [Math]::Min($ChunkSize, $b64.Length - $at)) }
    $execArguments = { param([string]$Command) Get-ClaudeRunnerExecArguments -ResourceGroup $ResourceGroup -Name $Name -SubscriptionId $SubscriptionId -Command $Command }
    # Runspaces cannot see a PowerShell function or alias named az (the offline tests define one); the parts
    # then go one at a time, in process.
    $az = Microsoft.PowerShell.Core\Get-Command az -ErrorAction SilentlyContinue | Select-Object -First 1
    $azPath = if ($az -and $az.CommandType -eq 'Application') { $az.Source } else { '' }
    $effective = if ($azPath) { [Math]::Min($Parallel, $parts) } else { 1 }
    if (-not $PSBoundParameters.ContainsKey('SecondsPerExec')) { $SecondsPerExec = Get-ClaudeRunnerExecSeconds $effective }
    # The waves of parts, the directory exec and the assembly exec, at the measured time per exec.
    $seconds = ([int][Math]::Ceiling($parts / $effective) + 2) * $SecondsPerExec
    $reserveMinutes = [Math]::Round($ReserveSeconds / 60)
    $applyBy = $null
    if ($null -ne $Deadline) {
        # PowerShell hands a bound Nullable[DateTimeOffset] over as the DateTimeOffset itself.
        $applyBy = [DateTimeOffset]$Deadline
        if ((Get-ClaudeRunnerNow).AddSeconds($seconds + $ReserveSeconds) -gt $applyBy) {
            throw ("Sending $Path ($($bytes.Length) bytes, $($compressed.Length) compressed) to runner $Name takes about $([Math]::Ceiling($seconds / 60)) minutes " +
                "($parts parts, $effective at a time, about $SecondsPerExec seconds an exec), and $reserveMinutes minutes are kept for the steps after it; together they pass " +
                "the snapshot's apply-by time $($applyBy.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')). The snapshot was not sent and nothing was written. " +
                (Get-ClaudeRunnerTransferRemedy -ResourceGroup $ResourceGroup -Name $Name))
        }
    }
    $started = Get-ClaudeRunnerNow
    # A transfer estimated at a minute or more says so before it starts, and reports its progress about
    # once a minute while it runs; a shorter one prints nothing.
    $leaf = Split-Path $Path -Leaf
    if ($seconds -ge 60) {
        Write-Host ("Sending {0}: {1} parts, {2} at a time, about {3} minutes." -f $leaf, $parts, $effective, [Math]::Ceiling($seconds / 60))
    }
    $null = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $Name -SubscriptionId $SubscriptionId -Command "node -e require('fs').mkdirSync('$partDir',{recursive:true})"
    $state = [pscustomobject]@{ Done = 0; Retries = 0; Failure = ''; FailedPart = 0; LastOutput = ''; Late = $false; Rate = 0.0; End = $null; ReportedAt = $null }
    $partsStarted = Get-ClaudeRunnerNow
    $state.ReportedAt = $partsStarted
    $progress = {
        $now = Get-ClaudeRunnerNow
        if ($state.Done -ge $parts -or ($now - $state.ReportedAt).TotalSeconds -lt 60) { return }
        $rate = $state.Done / [Math]::Max(($now - $partsStarted).TotalSeconds, 0.001)
        Write-Host ("Sending {0}: {1} of {2} parts ({3}%), about {4} minutes left at {5:N2} parts a second." -f $leaf, $state.Done, $parts,
            [int][Math]::Floor(100 * $state.Done / $parts), [Math]::Ceiling(($parts - $state.Done) / $rate / 60), $rate)
        $state.ReportedAt = $now
    }
    # The measured rate projects the end of the transfer. Until the first wave has finished there is no rate,
    # so the remaining waves are counted at the measured time per exec, as the estimate before the first exec.
    $pace = {
        if ($null -eq $applyBy) { return }
        $now = Get-ClaudeRunnerNow
        $elapsed = [Math]::Max(($now - $partsStarted).TotalSeconds, 0.001)
        if ($state.Done -lt $effective) {
            $state.Rate = $state.Done / $elapsed
            $state.End = $now.AddSeconds(([int][Math]::Ceiling(($parts - $state.Done) / $effective) + 1) * $SecondsPerExec)
        }
        else {
            $state.Rate = $state.Done / $elapsed
            $state.End = $now.AddSeconds(($parts - $state.Done) / $state.Rate + $elapsed / $state.Done * $effective)
        }
        if ($state.End.AddSeconds($ReserveSeconds) -gt $applyBy) { $state.Late = $true }
    }
    if (-not $azPath) {
        for ($index = 1; $index -le $parts -and -not $state.Late -and -not $state.Failure; $index++) {
            $payload = & $payloadOf $index
            $command = New-ClaudeRunnerPartCommand -PartDir $partDir -Index $index -Payload $payload
            Assert-ClaudeRunnerCommandText $command
            for ($attempt = 1; ; $attempt++) {
                $result = Invoke-ClaudeRunnerExec -Arguments (& $execArguments $command)
                $problem = Get-ClaudeRunnerPartProblem -Result $result -Index $index -Length $payload.Length
                if (-not $problem) { $state.Done++; break }
                if ($attempt -ge $Attempts) { $state.Failure = $problem; $state.FailedPart = $index; $state.LastOutput = [string]$result.Output; break }
                $state.Retries++
                Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt))
            }
            if (-not $state.Failure) { & $pace; & $progress }
        }
    }
    else {
        $worker = 'param($Az, [string[]]$Arguments) $ErrorActionPreference = ''Continue''; $global:LASTEXITCODE = 0; $out = & $Az @Arguments 2>&1 | Out-String; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = [string]$out }'
        $fresh = [Collections.Generic.Queue[int]]::new()
        for ($index = 1; $index -le $parts; $index++) { $fresh.Enqueue($index) }
        $retry = [Collections.Generic.List[object]]::new()
        $attemptsOf = @{}
        $running = [Collections.Generic.List[object]]::new()
        $pool = [runspacefactory]::CreateRunspacePool(1, $effective)
        $pool.Open()
        $stopShell = {
            param($Item)
            Stop-ClaudeRunnerExecProcess -Needle ("$partDir/" + $Item.Index.ToString('000000'))
            try { $null = $Item.Shell.Stop() } catch { $null = $_ }
            $Item.Shell.Dispose()
        }
        try {
            while ((-not $state.Late -and -not $state.Failure -and ($fresh.Count -or $retry.Count)) -or $running.Count) {
                while (-not $state.Late -and -not $state.Failure -and $running.Count -lt $effective) {
                    $ready = $retry | Where-Object { $_.NotBefore -le [DateTime]::UtcNow } | Select-Object -First 1
                    if ($ready) { $null = $retry.Remove($ready); $index = $ready.Index }
                    elseif ($fresh.Count) { $index = $fresh.Dequeue() }
                    else { break }
                    $attemptsOf[$index] = 1 + [int]$attemptsOf[$index]
                    $payload = & $payloadOf $index
                    $command = New-ClaudeRunnerPartCommand -PartDir $partDir -Index $index -Payload $payload
                    Assert-ClaudeRunnerCommandText $command
                    $shell = [powershell]::Create()
                    $shell.RunspacePool = $pool
                    $null = $shell.AddScript($worker).AddArgument($azPath).AddArgument((& $execArguments $command))
                    $running.Add([pscustomobject]@{ Index = $index; Length = $payload.Length; Shell = $shell; Handle = $shell.BeginInvoke(); Started = [DateTime]::UtcNow })
                }
                if ($running.Count) {
                    $null = [Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($running | ForEach-Object { $_.Handle.AsyncWaitHandle }), 250)
                }
                elseif ($retry.Count -and -not $state.Late -and -not $state.Failure) {
                    $next = $retry | Sort-Object NotBefore | Select-Object -First 1
                    Start-Sleep -Seconds ([Math]::Max(1, [int][Math]::Ceiling(($next.NotBefore - [DateTime]::UtcNow).TotalSeconds)))
                    $next.NotBefore = [DateTime]::MinValue
                }
                foreach ($item in @($running)) {
                    $timedOut = -not $item.Handle.IsCompleted -and ([DateTime]::UtcNow - $item.Started).TotalSeconds -gt $ExecTimeoutSeconds
                    if (-not $item.Handle.IsCompleted -and -not $timedOut) { continue }
                    $null = $running.Remove($item)
                    if ($timedOut) {
                        & $stopShell $item
                        $result = [pscustomobject]@{ ExitCode = -1; Output = '' }
                        $problem = "no answer within $ExecTimeoutSeconds seconds"
                    }
                    else {
                        try { $result = @($item.Shell.EndInvoke($item.Handle))[0] }
                        catch { $result = [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message } }
                        finally { $item.Shell.Dispose() }
                        $problem = Get-ClaudeRunnerPartProblem -Result $result -Index $item.Index -Length $item.Length
                    }
                    if (-not $problem) { $state.Done++; & $progress; continue }
                    if ($attemptsOf[$item.Index] -ge $Attempts) {
                        if (-not $state.Failure) { $state.Failure = $problem; $state.FailedPart = $item.Index; $state.LastOutput = [string]$result.Output }
                        continue
                    }
                    $state.Retries++
                    $retry.Add([pscustomobject]@{ Index = $item.Index; NotBefore = [DateTime]::UtcNow.AddSeconds([Math]::Pow(2, $attemptsOf[$item.Index])) })
                }
                # Checked on every pass, so a transfer whose execs stall is still stopped before its apply-by time.
                & $pace
                # A late transfer, or a part that failed for good, ends now: the parts in flight would be removed.
                if ($state.Late -or $state.Failure) {
                    foreach ($item in @($running)) { & $stopShell $item }
                    $running.Clear()
                }
            }
        }
        finally {
            foreach ($item in $running) { & $stopShell $item }
            $pool.Close()
            $pool.Dispose()
        }
    }
    $removeParts = { Invoke-ClaudeRunnerExec -Arguments (& $execArguments "node -e require('fs').rmSync('$partDir',{recursive:true,force:true})") }
    if ($state.Failure -or $state.Late) {
        $cleanup = & $removeParts
        $partsNote = if ($cleanup.ExitCode -eq 0 -and $cleanup.Output -notmatch 'ERROR') { 'The parts were removed' } else { "The part directory $partDir could not be removed; the runner's next start clears it" }
        if ($state.Late) {
            $paceText = if ($state.Done -ge $effective) { "at the measured $([Math]::Round($state.Rate, 2)) parts a second" } else { "with $($state.Done) of $parts parts finished so far" }
            throw ("Stopped sending $Path to runner $Name after $($state.Done) of $parts parts: $paceText it would end at " +
                "$($state.End.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')), and with the $reserveMinutes minutes kept for the steps after it, that passes the snapshot's apply-by time " +
                "$($applyBy.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')). $partsNote, and nothing was written. " + (Get-ClaudeRunnerTransferRemedy -ResourceGroup $ResourceGroup -Name $Name))
        }
        Write-ClaudeRunnerOutput -RawOutput $state.LastOutput -Step "runner transfer part $($state.FailedPart)"
        throw ("Sending $Path to runner $Name stopped: part $($state.FailedPart) of $parts failed after $Attempts attempts ($($state.Failure)). Nothing was assembled. $partsNote. " +
            "Remedy: rerun the command. If a part fails again, check that the runner is Running with az container show -g $ResourceGroup -n $Name --query instanceView.state, " +
            "and redeploy it with scripts/Deploy-ClaudeProjection.ps1.")
    }
    # One exec reads the parts in name order, checks their count and length, decompresses them, writes the
    # destination, removes the parts and prints the SHA-256 of what it wrote. A missing or short part prints
    # incomplete-parts or incomplete-length instead, which the hash check below reports. A difference is non-zero, so
    # `if(a-b)` compares without '!', which cmd.exe changes when delayed expansion is on. .NET writes no gzip
    # bytes at all for an empty file, so an empty payload is an empty file.
    $assembly = ("node -e f=require('fs');z=require('zlib');d='$partDir';p=f.readdirSync(d).sort();if(p.length-$parts){console.log('incomplete-parts',String(p.length));process.exit()}" +
        "s=p.map(function(x){return(f.readFileSync(d.concat('/',x),'utf8'))}).join('');if(s.length-$($b64.Length)){console.log('incomplete-length',String(s.length));process.exit()}" +
        "b=s.length?z.gunzipSync(Buffer.from(s,'base64url')):Buffer.alloc(0);f.writeFileSync('$Destination',b);f.rmSync(d,{recursive:true,force:true});" +
        "console.log(require('crypto').createHash('sha256').update(b).digest('hex'))")
    try { $remote = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $Name -SubscriptionId $SubscriptionId -Command $assembly }
    catch { $null = & $removeParts; throw }
    $local = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    $remoteHash = ($remote -split "`n" | Select-Object -Last 1).Trim()
    if ($remoteHash -ne $local) {
        $null = & $removeParts
        throw "Copy of $Path to $Destination did not arrive intact (local $local, remote '$remoteHash')."
    }
    return [pscustomobject]@{
        Path = $Path; Destination = $Destination; Bytes = $bytes.Length; CompressedBytes = $compressed.Length; Parts = $parts; Chunks = $parts
        Parallel = $effective; Retries = $state.Retries; Seconds = [Math]::Round(((Get-ClaudeRunnerNow) - $started).TotalSeconds, 1); Sha256 = $local
    }
}