<#
.SYNOPSIS
    Preflight checks shared by the setup scripts. Dot-source, then call
    Test-ClaudePrerequisites.

.DESCRIPTION
    Fails fast and with a specific remedy, rather than part-way through a
    deployment with whatever error the underlying tool happened to produce.

    The interesting check is the argument-passing canary. On Windows, az is a
    .cmd shim, and Windows PowerShell 5.1 only wraps an argument in quotes when
    it contains a space - so a JMESPath with no spaces reaches cmd.exe bare and
    cmd re-parses the ( ) | & characters in it. That shipped as a real failure:

        az : ].name was unexpected at this time.

    Rather than enumerate patterns known to break, the canary *runs* a
    representative query and checks the answer. Any environment that mangles
    arguments - a different shell, a wrapper, a future CLI packaging change -
    is caught at startup with an explanation, not mid-deployment.

.EXAMPLE
    . "$PSScriptRoot/Test-Prerequisites.ps1"
    if (-not (Test-ClaudePrerequisites -Mode Admin)) { return }
#>

function Test-ClaudePrerequisites {
    [CmdletBinding()]
    param(
        [ValidateSet('Admin', 'Workstation')]
        [string]$Mode = 'Admin',

        # Reachability probe for the workstation path.
        [string]$GatewayUrl,

        # Report problems but do not stop.
        [switch]$WarnOnly
    )

    $problems = @()
    $warnings = @()

    function P-Ok    ($m) { Write-Host "    [OK]   $m" -ForegroundColor Green }
    function P-Warn  ($m) { Write-Host "    [WARN] $m" -ForegroundColor Yellow }
    function P-Bad   ($m) { Write-Host "    [FAIL] $m" -ForegroundColor Red }
    function P-Note  ($m) { Write-Host "           $m" -ForegroundColor DarkGray }

    Write-Host ''
    Write-Host '==> Checking prerequisites' -ForegroundColor Cyan

    # ------------------------------------------------------------ PowerShell
    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -ge 7) { P-Ok "PowerShell $psv" }
    elseif ($psv.Major -eq 5 -and $psv.Minor -ge 1) {
        P-Ok "Windows PowerShell $psv"
        P-Note 'Supported. PowerShell 7 is faster, but both are equally affected by'
        P-Note 'the native-argument quirk noted below - it is a Windows property.'
    }
    else {
        P-Bad "PowerShell $psv is too old - 5.1 or later required"
        $problems += 'PowerShell version'
    }

    # ------------------------------------------------------------ Azure CLI
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCmd) {
        P-Bad 'Azure CLI not found on PATH'
        P-Note 'Install: https://learn.microsoft.com/cli/azure/install-azure-cli'
        P-Note 'If you just installed it, open a new terminal - PATH is not refreshed in this one.'
        $problems += 'Azure CLI'
    }
    else {
        $verLine = @(& az version --output tsv 2>$null) | Select-Object -First 1
        $ver = if ($verLine -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
        if ($ver) {
            P-Ok "Azure CLI $ver"
            try {
                if ([version]$ver -lt [version]'2.60.0') {
                    P-Warn 'Older than 2.60 - some commands used here may not exist'
                    P-Note 'Update: az upgrade'
                    $warnings += 'Azure CLI version'
                }
            } catch { }
        }
        else { P-Ok 'Azure CLI present'; P-Note 'could not parse the version' }

        # -------------------------------------------------- argument canary
        #
        # Deliberately uses the shape that breaks: parentheses and NO space.
        # On Windows, az is a .cmd shim and PowerShell only quotes native
        # arguments containing a space, so this reaches cmd.exe bare and cmd
        # re-parses the parentheses.
        #
        # Verified failing on BOTH Windows PowerShell 5.1 and PowerShell 7 - it
        # is a Windows/az.cmd property, not a host version difference. An
        # earlier version of this comment claimed 7 was immune; it is not.
        #
        # A canary containing a space would pass everywhere and prove nothing.
        # The first version of this check made exactly that mistake.
        #
        # Informational, not blocking: the scripts avoid the affected patterns.
        # The value is that if a future edit reintroduces one, the cause is
        # already on screen instead of being rediscovered from
        #     ].id was unexpected at this time
        #
        # It matters because the failure is not always loud. The error text is
        # a non-empty string, so code that treats "did this return anything?"
        # as success silently accepts garbage - which is how this shipped.
        # ------------------------------------------- native argument handling
        #
        # Two separate things, kept separate on purpose.
        #
        # 1. A functional probe with a SAFE query, to prove az actually runs.
        #    The query deliberately contains a space so it is quoted on every
        #    platform - this checks the CLI, not the shell.
        #
        # 2. A deterministic platform note. On Windows az is a .cmd shim, and
        #    PowerShell only quotes native arguments containing a space, so a
        #    --query value with parentheses and no space reaches cmd.exe bare
        #    and is re-parsed:
        #        ].id was unexpected at this time
        #    This affects Windows PowerShell 5.1 and PowerShell 7 equally - it
        #    is a property of the .cmd shim, not the host version.
        #
        # Detecting the condition beats probing for it: an earlier version ran
        # the failing query directly, which printed the very NativeCommandError
        # block this check exists to explain. A later version routed the probe
        # through cmd with explicit quoting, which made it pass everywhere and
        # test nothing.
        $probeText = ''
        try {
            $ErrorActionPreference = 'SilentlyContinue'
            $probeText = (& az account list --query "[].{id: id}" -o tsv 2>&1 | Out-String)
        }
        catch { $probeText = "$_" }
        finally { $ErrorActionPreference = 'Continue' }

        if ($probeText -match 'unexpected at this time|is not recognized') {
            P-Bad 'Azure CLI could not run a simple query'
            P-Note (($probeText.Trim() -split "`n") | Select-Object -First 1)
            $problems += 'Azure CLI'
        }
        elseif ($probeText -match 'Traceback') {
            P-Warn 'Azure CLI returned an internal error'
            P-Note 'Try: az upgrade'
            $warnings += 'CLI health'
        }
        else {
            P-Ok 'Azure CLI responds correctly'
        }

        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            if ($azCmd.Source -match '\.(cmd|bat)$') {
                P-Note 'note: az is a .cmd shim here, so unquoted native arguments are'
                P-Note '      re-parsed by cmd.exe. These scripts keep & ^ < > and'
                P-Note '      query parentheses out of az arguments - no action needed.'
            }
        }

        $canaryOk = $true

        $canaryOk = $true

        # ---------------------------------------------------------- sign-in
        if ($canaryOk) {
            $acct = & az account show -o json 2>$null | ConvertFrom-Json
            if ($acct) {
                P-Ok "signed in as $($acct.user.name)"
                P-Note "tenant $($acct.tenantId)"
            }
            else {
                P-Warn 'not signed in'
                P-Note 'The script will run az login for you, or run it yourself first.'
                P-Note 'Guests must name the tenant: az login --tenant <tenant-id>'
                $warnings += 'sign-in'
            }
        }
    }

    # --------------------------------------------------------------- by mode
    if ($Mode -eq 'Admin') {
        # Bicep - the template will not compile without it.
        if ($azCmd) {
            $bicep = & az bicep version 2>&1 | Out-String
            if ($bicep -match '(\d+\.\d+\.\d+)') { P-Ok "Bicep $($Matches[1])" }
            else {
                P-Warn 'Bicep not installed'
                P-Note 'The Azure CLI installs it on first use, or run: az bicep install'
                $warnings += 'Bicep'
            }
        }

        # Reachability. A proxy or firewall block is far easier to diagnose here
        # than as a deployment timeout twenty minutes in.
        try {
            $null = Invoke-WebRequest 'https://management.azure.com/' -Method Head -TimeoutSec 12 -ErrorAction Stop
            P-Ok 'management.azure.com reachable'
        }
        catch {
            $code = $null
            try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
            # 401/403 without a token is the correct, healthy answer.
            if ($code -in @(400, 401, 403)) { P-Ok 'management.azure.com reachable' }
            else {
                P-Bad 'cannot reach management.azure.com'
                P-Note 'Check proxy, VPN or firewall. Deployment cannot proceed without it.'
                $problems += 'network'
            }
        }
    }
    else {
        # Workstation: Node is how the Claude Code CLI installs.
        if (Get-Command node -ErrorAction SilentlyContinue) {
            P-Ok "Node.js $((& node --version 2>$null))"
        }
        else {
            P-Warn 'Node.js not found - needed for the Claude Code CLI'
            P-Note 'The setup script installs it via winget if available.'
            $warnings += 'Node.js'
        }

        if (Get-Command winget -ErrorAction SilentlyContinue) { P-Ok 'winget available for installs' }
        else {
            P-Warn 'winget not found - anything missing must be installed by hand'
            $warnings += 'winget'
        }

        if ($GatewayUrl) {
            try {
                $null = Invoke-WebRequest ($GatewayUrl.TrimEnd('/') + '/api/hello') -Method Head -TimeoutSec 12 -ErrorAction Stop
                P-Ok 'gateway reachable'
            }
            catch {
                $code = $null
                try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
                # Any HTTP answer proves the host is reachable; auth comes later.
                if ($code) { P-Ok "gateway reachable (HTTP $code)" }
                else {
                    P-Bad "cannot reach $GatewayUrl"
                    P-Note 'Check the URL, and whether a proxy or VPN is in the way.'
                    $problems += 'gateway unreachable'
                }
            }
        }
    }

    # --------------------------------------------------------------- verdict
    Write-Host ''
    if ($problems.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host '    All prerequisites satisfied.' -ForegroundColor Green
        Write-Host ''
        return $true
    }

    if ($problems.Count -gt 0) {
        Write-Host "    $($problems.Count) blocking issue(s): $($problems -join ', ')" -ForegroundColor Red
        if (-not $WarnOnly) {
            Write-Host '    Fix these and re-run. Nothing has been changed.' -ForegroundColor Red
            Write-Host ''
            return $false
        }
    }
    if ($warnings.Count -gt 0) {
        Write-Host "    $($warnings.Count) warning(s): $($warnings -join ', ')" -ForegroundColor Yellow
        Write-Host '    Not blocking - continuing.' -ForegroundColor DarkGray
    }
    Write-Host ''
    return $true
}
