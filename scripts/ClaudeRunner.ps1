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

    So a file travels as base64url in chunks, each appended by a one-line
    `node -e` program that contains no spaces, and is decoded and checked with
    a SHA-256 at the end. base64url has no character that cmd.exe, PowerShell,
    URL decoding or the ACI tokenizer treats specially.

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
    # The runner splits the command on spaces with no quoting and URL-decodes it, and az.cmd hands every
    # argument to cmd.exe: a quote, '+', '%' or a cmd.exe metacharacter cannot pass through unchanged.
    if ($Command -match '["%+&|<>^\r\n]') {
        throw 'Runner command refused: it holds a quote, +, %, &, |, <, >, ^ or a line break, which the runner or cmd.exe would change.'
    }
    foreach ($target in @($ResourceGroup, $Name, $Container, $SubscriptionId)) { Assert-ClaudeRunnerAzName $target }
    $arguments = @('container','exec','-g',$ResourceGroup,'-n',$Name,'--container-name',$Container,'--exec-command',$Command)
    if ($SubscriptionId) { $arguments += @('--subscription',$SubscriptionId) }
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $out = & az @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    if ($code -ne 0) {
        Write-ClaudeRunnerOutput -RawOutput $out -Step 'runner transport'
        throw "runner transport failed (az exit $code)."
    }
    return $out.Trim()
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

function Send-RunnerFile {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [int]$ChunkSize = 4900,
        [string]$SubscriptionId,
        # A snapshot's apply-by time (Get-RunnerFileDeadline). A transfer estimated to end after it is refused
        # before the first exec, rather than failing at the apply-by check hours later (P98 council round 2).
        [Nullable[DateTimeOffset]]$Deadline,
        # One exec is about five seconds, whatever it does (measured 2026-09-23; see the notes above).
        [double]$SecondsPerCommand = 5
    )
    if ($Destination -match '\s') { throw "Destination '$Destination' contains a space; exec cannot pass it." }
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
    # base64url, not base64. The exec command is URL-decoded on its way in:
    # '+' arrives as a space - which then splits the argument - and '%2B'
    # arrives as '+' (measured 2026-09-23). base64url uses '-' and '_' instead,
    # which survive, and Node decodes it natively.
    $b64 = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $tmp = "$Destination.b64"
    $dir = ($Destination -replace '/[^/]+$', '')
    # ACI refuses an exec command of 5,000 characters or more with
    # InvalidCommandLength (measured 2026-09-23), so a chunk is whatever fits
    # under that once the surrounding program is counted.
    $overhead = ("node -e require('fs').appendFileSync('$tmp','')").Length
    $ChunkSize = [Math]::Min($ChunkSize, 4990 - $overhead)
    if ($null -ne $Deadline) {
        # PowerShell hands a bound Nullable[DateTimeOffset] over as the DateTimeOffset itself.
        $applyBy = [DateTimeOffset]$Deadline
        $commands = [int][Math]::Ceiling($b64.Length / $ChunkSize) + 2
        $seconds = $commands * $SecondsPerCommand
        if ([DateTimeOffset]::UtcNow.AddSeconds($seconds) -gt $applyBy) {
            throw ("Sending $Path ($($bytes.Length) bytes) to runner $Name takes about $([Math]::Ceiling($seconds / 60)) minutes ($commands az container exec " +
                "commands of about $SecondsPerCommand seconds each), past the snapshot's apply-by time $($applyBy.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')). " +
                "The snapshot was not sent and nothing was written. Through the runner, a snapshot of about 40,000 developers fits in the 2-hour apply-by time; " +
                "a larger directory needs the directory-scale transfer planned as ROADMAP packet P99.")
        }
    }
    $null = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $Name -SubscriptionId $SubscriptionId -Command "node -e require('fs').mkdirSync('$dir',{recursive:true});require('fs').writeFileSync('$tmp','')"
    for ($i = 0; $i -lt $b64.Length; $i += $ChunkSize) {
        $part = $b64.Substring($i, [Math]::Min($ChunkSize, $b64.Length - $i))
        $said = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $Name -SubscriptionId $SubscriptionId -Command "node -e require('fs').appendFileSync('$tmp','$part')"
        # An exec that fails prints its error and nothing else; ignoring it is
        # how a copy silently arrives empty.
        if ($said -match 'ERROR|InvalidCommandLength|terminated with non-zero') { throw "Chunk at $i failed: $($said.Substring(0, [Math]::Min(200, $said.Length)))" }
    }
    # No declaration keyword: `const f` needs a space, which exec would split on,
    # and `const$f` is a single identifier. node -e is sloppy mode, so a bare
    # assignment is enough.
    $remote = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $Name -SubscriptionId $SubscriptionId -Command ("node -e f=require('fs');f.writeFileSync('$Destination',Buffer.from(f.readFileSync('$tmp','utf8'),'base64url'));f.unlinkSync('$tmp');" +
        "console.log(require('crypto').createHash('sha256').update(f.readFileSync('$Destination')).digest('hex'))")
    $local = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    $remoteHash = ($remote -split "`n" | Select-Object -Last 1).Trim()
    if ($remoteHash -ne $local) { throw "Copy of $Path to $Destination did not arrive intact (local $local, remote '$remoteHash')." }
    return [pscustomobject]@{ Path = $Path; Destination = $Destination; Bytes = $bytes.Length; Chunks = [Math]::Ceiling($b64.Length / $ChunkSize); Sha256 = $local }
}
