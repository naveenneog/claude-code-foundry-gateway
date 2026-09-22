<#
.SYNOPSIS
    Credential helper for Claude Desktop. Prints a Microsoft Entra bearer token
    for the Cognitive Services data plane to stdout, and nothing else.

.DESCRIPTION
    Claude Desktop runs the executable named by inferenceCredentialHelper and
    reads a bearer token from its standard output. This implementation reuses
    the Azure CLI's own sign-in, which is why the helper path needs no app
    registration and no admin consent: the Azure CLI client
    (04b07795-8ddb-461a-bbee-02f9e1bf7b46) is already consented in essentially
    every tenant.

    The app sets CLAUDE_HELPER_CONTEXT so a helper can distinguish an
    interactive start from a mid-session refresh. This one uses it only to
    decide whether prompting the user to sign in is acceptable - during a
    silent refresh it fails fast rather than blocking on an interactive prompt
    that nobody is watching.

    Contract, and the reason this file writes so carefully:
      - stdout carries the token and nothing else. Any stray output corrupts it.
      - diagnostics go to stderr.
      - exit non-zero on failure so the app can surface a real error.

.NOTES
    Tokens last roughly 60-75 minutes. The Azure CLI caches and refreshes them,
    so this stays cheap when called repeatedly.
#>
[CmdletBinding()]
param(
    [string]$Resource = 'https://cognitiveservices.azure.com',

    # Pin a tenant when the developer is a guest, or is signed in to several.
    # A bare az login lands guests in their home directory and the resulting
    # token is rejected downstream.
    [string]$TenantId = $env:CLAUDE_FOUNDRY_TENANT_ID,

    # Interactive opens a browser. On a jump box or VDI session there is none,
    # and the helper would otherwise block forever on a prompt nobody can
    # answer. Set CLAUDE_FOUNDRY_AUTH=device there.
    [ValidateSet('interactive', 'device')][string]$Auth = $(
        if ($env:CLAUDE_FOUNDRY_AUTH -eq 'device') { 'device' } else { 'interactive' })
)

$ErrorActionPreference = 'Stop'

function Write-Diag($m) { [Console]::Error.WriteLine("[claude-helper] $m") }

# interactive-start | refresh | (unset on older builds)
$context = $env:CLAUDE_HELPER_CONTEXT
$interactiveAllowed = ($context -ne 'refresh')

try {
    # Windows PowerShell 5.1 compatible on purpose: the .cmd shim invokes
    # powershell.exe, which is 5.1 on most endpoints. No ?? , no ternary.
    #
    # PATH alone is not enough. Claude Desktop spawns this helper with the
    # environment block it was itself started with, so a PATH entry added after
    # the app launched - including the machine-wide one the Azure CLI installer
    # writes - is invisible here. Measured: az.cmd present in machine PATH and
    # resolvable in a shell, and the helper still reported "not found on PATH"
    # when run by Desktop. So fall back to where the CLI actually installs.
    $azPath = $null
    $cmd = Get-Command az.cmd -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command az -ErrorAction SilentlyContinue }
    if ($cmd) { $azPath = $cmd.Source }

    if (-not $azPath) {
        $roots = @()
        if ($env:ProgramFiles)        { $roots += $env:ProgramFiles }
        if (${env:ProgramFiles(x86)}) { $roots += ${env:ProgramFiles(x86)} }
        if ($env:LOCALAPPDATA)        { $roots += (Join-Path $env:LOCALAPPDATA 'Programs') }
        foreach ($r in $roots) {
            $candidate = Join-Path $r 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
            if (Test-Path $candidate) { $azPath = $candidate; break }
        }
        if ($azPath) { Write-Diag "az not on PATH; using $azPath" }
    }

    if (-not $azPath) {
        Write-Diag 'Azure CLI not found on PATH or in the usual install locations.'
        Write-Diag 'If it is installed, quit Claude Desktop completely - including the'
        Write-Diag 'tray icon - and reopen it. A child process inherits the environment'
        Write-Diag 'the app started with, so a PATH change made since then is not visible.'
        throw 'Azure CLI not found.'
    }

    # Not $args - that is an automatic variable.
    $tokenArgs = @('account', 'get-access-token', '--resource', $Resource, '--query', 'accessToken', '-o', 'tsv')
    if ($TenantId) { $tokenArgs += @('--tenant', $TenantId) }

    $token = & $azPath @tokenArgs 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $token) {
        if (-not $interactiveAllowed) {
            Write-Diag 'No cached credential and this is a silent refresh - not prompting.'
            Write-Diag 'Run: az login --tenant <tenant-id>'
            exit 2
        }

        Write-Diag 'No cached credential. Starting interactive sign-in.'
        $loginArgs = @('login')
        if ($TenantId) { $loginArgs += @('--tenant', $TenantId) }
        if ($Auth -eq 'device') {
            # stderr, because stdout carries the token and nothing else.
            $loginArgs += '--use-device-code'
            Write-Diag 'Device code sign-in - the code appears below.'
        }
        & $azPath @loginArgs 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }

        $token = & $azPath @tokenArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not acquire a token after sign-in.' }
    }

    # Cheap sanity check. A JWT starts with the base64 of '{"' - 'eyJ'.
    if ($token -notmatch '^eyJ') {
        throw "Token did not look like a JWT. On Git Bash a bare 'az' can resolve to the WSL shim - use az.cmd."
    }

    # stdout, no trailing newline noise, nothing else.
    [Console]::Out.Write($token.Trim())
    exit 0
}
catch {
    Write-Diag $_.Exception.Message
    exit 1
}
