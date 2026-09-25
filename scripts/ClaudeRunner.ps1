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

function Invoke-RunnerCommand {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string]$Container = 'runner',
        [string]$SubscriptionId
    )
    $arguments = @('container','exec','-g',$ResourceGroup,'-n',$Name,'--container-name',$Container,'--exec-command',$Command)
    if ($SubscriptionId) { $arguments += @('--subscription',$SubscriptionId) }
    $out = & az @arguments 2>&1 | Out-String
    return $out.Trim()
}

function Send-RunnerFile {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [int]$ChunkSize = 4900,
        [string]$SubscriptionId
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
