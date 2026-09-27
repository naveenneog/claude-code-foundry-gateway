<#
.SYNOPSIS
    What the Claude clients need for the recorded models: Claude Code capability declarations,
    the Claude Code release that knows each model, installed client versions, and a bounded way
    to run a client command.

.DESCRIPTION
    Dot-source this. Shared by Setup-ClaudeWorkstation.ps1, New-ClaudeCodePolicy.ps1 and
    Debug-ClaudeWorkstation.ps1 so the three cannot disagree. ADR-0031.

    Claude Code never recognises a pinned Microsoft Foundry deployment name and detects
    capabilities from the model ID, so an older release sends thinking.type.enabled to a model
    that accepts only adaptive thinking and gets a 400. Measured 2026-09-27: Claude Code 2.1.101
    returned that 400 through the gateway, and answered once
    ANTHROPIC_DEFAULT_<ALIAS>_MODEL_SUPPORTED_CAPABILITIES listed the model's capabilities.
#>

# Which models Claude Code must be told about, as a rule rather than a list, so a model released
# after this file still works. Sources, retrieved 2026-09-27:
#   "Fable models, Sonnet 5, and Opus 4.7 and later always use adaptive reasoning"
#                      https://code.claude.com/docs/en/model-config
#   capability names   https://code.claude.com/docs/en/model-config
#   xhigh and max      https://platform.claude.com/docs/en/build-with-claude/effort (both listed for
#                      Opus 4.7 and later, Sonnet 5, Fable 5 and later, Mythos 5 and later)
#   first release      https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
# A model in one of these families at or above its floor gets every capability below. A model the
# changelog names also gets the first Claude Code release that knew it; a newer model gets none,
# and the declaration alone makes older releases work with it. An administrator can override
# either per deployment in claude-gateway.json (`capabilities`, `claudeCode`).
$script:ClaudeAdaptiveFamilyFloor = @{ opus = [version]'4.7'; sonnet = [version]'5.0'; fable = [version]'5.0'; mythos = [version]'5.0' }
$script:ClaudeAdaptiveCapabilities = 'effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking'
$script:ClaudeCodeFirstRelease = @{
    'claude-opus-4-7'  = '2.1.111'
    'claude-fable-5'   = '2.1.170'
    'claude-sonnet-5'  = '2.1.197'
    'claude-opus-5'    = '2.1.219'
    'claude-fable-5-1' = '2.1.257'
    'claude-opus-5-5'  = '2.1.280'
}

# Every environment variable this module owns in ~/.claude/settings.json. Anything else in the
# env block belongs to the developer and is kept.
$script:ClaudeCodeGatewayEnvKeys = @(
    'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_RESOURCE',
    'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL',
    'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES', 'ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES',
    'ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES'
)

function ConvertTo-ClaudeClientVersion {
    <#
    .SYNOPSIS
        The first x.y.z in a version banner such as "2.1.101 (Claude Code)", or $null.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $m = [regex]::Match([string]$Text, '\d+\.\d+\.\d+')
    if (-not $m.Success) { return $null }
    return [version]$m.Value
}

function Test-ClaudeClientVersionAtLeast {
    <#
    .SYNOPSIS
        $true or $false, or $null when the installed version cannot be read.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Installed, [Parameter(Mandatory)][string]$Required)
    $have = ConvertTo-ClaudeClientVersion $Installed
    if (-not $have) { return $null }
    return ($have -ge [version]$Required)
}

function ConvertTo-ClaudeModelIdentity {
    <#
    .SYNOPSIS
        claude-<family>-<major>[-<minor>][-<yyyymmdd>] as family, version and base id, or $null.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Model)
    $m = [regex]::Match([string]$Model, '^claude-(?<family>[a-z]+)-(?<major>\d+)(?:-(?<minor>\d{1,2}))?(?:-\d{8})?$')
    if (-not $m.Success) { return $null }
    $minor = if ($m.Groups['minor'].Success) { $m.Groups['minor'].Value } else { '' }
    [pscustomobject]@{
        Family = $m.Groups['family'].Value
        Version = [version]("{0}.{1}" -f $m.Groups['major'].Value, $(if ($minor) { $minor } else { '0' }))
        Base = "claude-$($m.Groups['family'].Value)-$($m.Groups['major'].Value)" + $(if ($minor) { "-$minor" } else { '' })
    }
}

function Get-ClaudeModelClientSupport {
    <#
    .SYNOPSIS
        What Claude Code must be told about a model, or $null when its own detection is enough.

    .PARAMETER Capabilities
        An administrator's override from the record: a capability list, or `none`.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Model, [string]$Capabilities, [string]$ClaudeCode)
    $identity = ConvertTo-ClaudeModelIdentity $Model
    $family = if ($identity) { $identity.Family } elseif ([string]$Model -match '(?i)(opus|sonnet|haiku|fable|mythos)') { $Matches[1].ToLowerInvariant() } else { '' }
    $caps = ''
    if ($Capabilities) { if ($Capabilities -ne 'none') { $caps = $Capabilities } }
    elseif ($identity -and $script:ClaudeAdaptiveFamilyFloor.ContainsKey($identity.Family) -and $identity.Version -ge $script:ClaudeAdaptiveFamilyFloor[$identity.Family]) { $caps = $script:ClaudeAdaptiveCapabilities }
    if (-not $caps) { return $null }
    $release = if ($ClaudeCode) { $ClaudeCode } elseif ($identity -and $script:ClaudeCodeFirstRelease.ContainsKey($identity.Base)) { $script:ClaudeCodeFirstRelease[$identity.Base] } else { $null }
    [pscustomobject]@{
        Model = $(if ($identity) { $identity.Base } else { [string]$Model })
        Family = $family
        Version = $(if ($identity) { $identity.Version } else { $null })
        Capabilities = $caps
        ClaudeCode = $release
    }
}

function Get-ClaudeRecordedDeployment {
    <#
    .SYNOPSIS
        The Claude deployments a record describes, as objects with name and model.

    .DESCRIPTION
        Install-ClaudeGateway.ps1 records `deployments` with each deployment's model. Older
        records carry only `models` (deployment names), and a developer may pass names on the
        command line; in both cases the name stands in for the model.
    #>
    param($Config, [string[]]$Names = @())
    if ($Config -and $Config.PSObject.Properties.Name -contains 'deployments' -and $Config.deployments) {
        return @($Config.deployments | Where-Object { $_.name } | ForEach-Object {
            $p = $_.PSObject.Properties.Name
            [pscustomobject]@{
                name = [string]$_.name
                model = $(if ($_.model) { [string]$_.model } else { [string]$_.name })
                version = [string]$_.version
                # Administrator overrides for a model this file does not describe yet.
                capabilities = $(if ($p -contains 'capabilities') { [string]$_.capabilities } else { '' })
                claudeCode = $(if ($p -contains 'claudeCode') { [string]$_.claudeCode } else { '' })
            }
        })
    }
    $fromNames = @()
    if ($Config -and $Config.PSObject.Properties.Name -contains 'models' -and $Config.models) { $fromNames = @($Config.models) }
    elseif ($Names) { $fromNames = @($Names) }
    return @($fromNames | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ name = [string]$_; model = [string]$_; version = ''; capabilities = ''; claudeCode = '' } })
}

function Get-ClaudeDeploymentClientSupport {
    param($Deployment)
    $caps = if ($Deployment.PSObject.Properties.Name -contains 'capabilities') { [string]$Deployment.capabilities } else { '' }
    $release = if ($Deployment.PSObject.Properties.Name -contains 'claudeCode') { [string]$Deployment.claudeCode } else { '' }
    return (Get-ClaudeModelClientSupport -Model ([string]$Deployment.model) -Capabilities $caps -ClaudeCode $release)
}

function Get-ClaudeCodePinnedModel {
    <#
    .SYNOPSIS
        The deployment each Claude Code alias is pinned to: OPUS, SONNET and HAIKU.

    .DESCRIPTION
        Chosen by model family, never by deployment name, and the newest version in the family
        wins, so a newly deployed model becomes the alias once the setup runs again. Haiku has no
        Foundry deployment in most tenants, so it falls back to the Sonnet deployment and
        background tasks do not fail with DeploymentNotFound mid-session.
    #>
    param([object[]]$Deployments = @())
    $pinned = [ordered]@{}
    foreach ($family in 'opus', 'sonnet', 'haiku') {
        $candidates = @($Deployments | Where-Object {
            $identity = ConvertTo-ClaudeModelIdentity $_.model
            if ($identity) { $identity.Family -eq $family } else { [string]$_.model -match $family }
        })
        # The first candidate with the highest version; Sort-Object has no -Stable on PowerShell 5.1.
        $pick = $null; $pickVersion = $null
        foreach ($candidate in $candidates) {
            $identity = ConvertTo-ClaudeModelIdentity $candidate.model
            $v = if ($identity) { $identity.Version } else { [version]'0.0' }
            if (-not $pick -or $v -gt $pickVersion) { $pick = $candidate; $pickVersion = $v }
        }
        if ($pick) { $pinned[$family.ToUpperInvariant()] = $pick }
    }
    if (-not $pinned.Contains('HAIKU') -and $pinned.Contains('SONNET')) { $pinned['HAIKU'] = $pinned['SONNET'] }
    return $pinned
}

function Get-ClaudeCodeModelEnvironment {
    <#
    .SYNOPSIS
        The Claude Code model variables for a set of deployments: each pinned alias, and a
        capability declaration for every alias whose model is known.
    #>
    param([object[]]$Deployments = @())
    $environment = [ordered]@{}
    $pinned = Get-ClaudeCodePinnedModel -Deployments $Deployments
    foreach ($alias in $pinned.Keys) {
        $deployment = $pinned[$alias]
        $environment["ANTHROPIC_DEFAULT_$($alias)_MODEL"] = [string]$deployment.name
        $known = Get-ClaudeDeploymentClientSupport $deployment
        if ($known) { $environment["ANTHROPIC_DEFAULT_$($alias)_MODEL_SUPPORTED_CAPABILITIES"] = $known.Capabilities }
    }
    return $environment
}

function Get-ClaudeCodeRequiredVersion {
    <#
    .SYNOPSIS
        The newest Claude Code release any recorded model is known to need, with the model.

    .DESCRIPTION
        A model newer than the release table has no requirement here; its capability
        declaration is what lets an older Claude Code use it.
    #>
    param([object[]]$Deployments = @())
    $best = $null
    foreach ($deployment in $Deployments) {
        $known = Get-ClaudeDeploymentClientSupport $deployment
        if (-not $known -or -not $known.ClaudeCode) { continue }
        if (-not $best -or [version]$known.ClaudeCode -gt [version]$best.Version) {
            $best = [pscustomobject]@{ Version = $known.ClaudeCode; Model = $known.Model; Deployment = [string]$deployment.name }
        }
    }
    return $best
}

function ConvertTo-ClaudeCapabilityList {
    <#
    .SYNOPSIS
        A comma-separated capability list as a sorted set, so two declarations compare equal in
        any order.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Capabilities)
    return @([string]$Capabilities -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-ClaudeCodeAliasCheck {
    <#
    .SYNOPSIS
        Whether Claude Code's requests for one pinned alias work: Status ok, warn or fail, with
        the reason.

    .DESCRIPTION
        Measured 2026-09-27 by capturing the request each release sent to a local stand-in for
        the gateway. A declaration listing adaptive_thinking made 2.1.101 and 2.1.272 send
        adaptive thinking. thinking without adaptive_thinking made both send
        thinking.type.enabled, which the 5-series models refuse with 400; only 2.1.272 then
        retried with adaptive thinking. With no declaration, 2.1.101 sent thinking.type.enabled
        for the name claude-sonnet-5 and adaptive thinking for prod-fast, and 2.1.272 sent
        adaptive thinking for both. alias_check_ in claude-client-support.sh is the bash twin.
    #>
    param(
        [Parameter(Mandatory)][string]$Variable,
        [Parameter(Mandatory)][string]$PinnedName,
        [AllowNull()][AllowEmptyString()][string]$Declared,
        $Known,
        [switch]$Recorded,
        [AllowNull()][AllowEmptyString()][string]$Installed
    )
    $ok = [pscustomobject]@{ Status = 'ok'; Text = '' }
    if (-not $Known) {
        if ($Declared -and $Recorded) {
            return [pscustomobject]@{ Status = 'warn'; Text = "$Variable is set for $PinnedName, which the record does not declare; a declaration turns off every capability it does not list" }
        }
        return $ok
    }
    $label = if ($Known.Model -and $Known.Model -ne $PinnedName) { "$PinnedName ($($Known.Model))" } else { $PinnedName }
    $have = ConvertTo-ClaudeClientVersion $Installed
    $haveText = if ($have) { "$have" } else { 'of unknown version' }
    $knows = [bool]($Known.ClaudeCode -and (Test-ClaudeClientVersionAtLeast -Installed $Installed -Required $Known.ClaudeCode) -eq $true)
    if ($Declared) {
        $declaredSet = @(ConvertTo-ClaudeCapabilityList $Declared)
        $expectedSet = @(ConvertTo-ClaudeCapabilityList $Known.Capabilities)
        if (($declaredSet -join ',') -eq ($expectedSet -join ',')) { return $ok }
        if ($declaredSet -contains 'thinking' -and $declaredSet -notcontains 'adaptive_thinking' -and $expectedSet -contains 'adaptive_thinking') {
            if ($knows) {
                return [pscustomobject]@{ Status = 'warn'; Text = "$Variable lists thinking without adaptive_thinking for ${label}: Claude Code sends thinking.type.enabled first, and retries with adaptive thinking after the 400" }
            }
            return [pscustomobject]@{ Status = 'fail'; Text = "$Variable lists thinking without adaptive_thinking for ${label}: Claude Code $haveText sends thinking.type.enabled, which the model refuses with 400" }
        }
        return [pscustomobject]@{ Status = 'warn'; Text = "$Variable is '$Declared' for $label, where the record expects '$($Known.Capabilities)'; a declaration turns off every capability it does not list" }
    }
    if (-not $Known.ClaudeCode) {
        return [pscustomobject]@{ Status = 'warn'; Text = "$Variable is not set for $label, and no Claude Code release is recorded as knowing that model" }
    }
    if ($knows) { return $ok }
    if (ConvertTo-ClaudeModelIdentity $PinnedName) {
        return [pscustomobject]@{ Status = 'fail'; Text = "$Variable is not set for $label, and Claude Code $haveText predates that model (first known to Claude Code $($Known.ClaudeCode)): it sends thinking.type.enabled, which the model refuses with 400" }
    }
    return [pscustomobject]@{ Status = 'warn'; Text = "$Variable is not set for $label, and Claude Code $haveText predates that model (first known to Claude Code $($Known.ClaudeCode)): what it sends for the name $PinnedName depends on the release" }
}

function Set-ClaudeCodeGatewaySettings {
    <#
    .SYNOPSIS
        Points a ~/.claude/settings.json object at the gateway and returns it.

    .DESCRIPTION
        Sets the Foundry provider, the gateway base URL, the pinned models with their capability
        declarations, availableModels and enforceAvailableModels. Removes the variables this
        module owns that no longer apply - ANTHROPIC_FOUNDRY_RESOURCE, which is mutually
        exclusive with the base URL and ends the session with "baseURL and resource are mutually
        exclusive", and declarations for aliases that are no longer pinned. Every other setting
        and environment variable is kept.
    #>
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$GatewayUrl,
        [object[]]$Deployments = @()
    )
    if (-not $Settings) { $Settings = [pscustomobject]@{} }
    $environment = [ordered]@{}
    if ($Settings.PSObject.Properties.Name -contains 'env' -and $Settings.env) {
        foreach ($p in $Settings.env.PSObject.Properties) {
            if ($script:ClaudeCodeGatewayEnvKeys -notcontains $p.Name) { $environment[$p.Name] = $p.Value }
        }
    }
    $environment['CLAUDE_CODE_USE_FOUNDRY'] = '1'
    $environment['ANTHROPIC_FOUNDRY_BASE_URL'] = $GatewayUrl
    $models = Get-ClaudeCodeModelEnvironment -Deployments $Deployments
    foreach ($k in $models.Keys) { $environment[$k] = $models[$k] }
    $Settings | Add-Member -NotePropertyName 'env' -NotePropertyValue ([pscustomobject]$environment) -Force
    $Settings | Add-Member -NotePropertyName 'availableModels' -NotePropertyValue @($Deployments | ForEach-Object { [string]$_.name } | Select-Object -Unique) -Force
    $Settings | Add-Member -NotePropertyName 'enforceAvailableModels' -NotePropertyValue $true -Force
    return $Settings
}

function Get-ClaudeCodeInstall {
    <#
    .SYNOPSIS
        Every Claude Code on PATH, one per folder, in PATH order. The first one runs.

    .DESCRIPTION
        npm puts three shims in one folder: claude.ps1, claude.cmd and an extensionless claude,
        which is a POSIX shell script that Windows cannot start ("not a valid application for
        this OS platform"). A folder is one install, and its runnable file is chosen by
        extension. Group-Object sorts its groups on PowerShell 7, which put the extensionless
        shim first, so the PATH order is kept by hand.
    #>
    param()
    $rank = @{ '.exe' = 0; '.cmd' = 1; '.bat' = 2; '.ps1' = 3; '.com' = 4 }
    $onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $byFolder = [ordered]@{}
    foreach ($command in @(Get-Command claude -All -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) {
        $source = [string]$command.Source
        if (-not $source) { continue }
        $ext = [IO.Path]::GetExtension($source).ToLowerInvariant()
        if ($onWindows -and -not $rank.ContainsKey($ext)) { continue }
        $folder = Split-Path -Parent $source
        $key = if ($onWindows) { $folder.TrimEnd('\').ToLowerInvariant() } else { $folder }
        $score = if ($rank.ContainsKey($ext)) { $rank[$ext] } else { 9 }
        if (-not $byFolder.Contains($key) -or $score -lt $byFolder[$key].Score) { $byFolder[$key] = @{ Score = $score; Command = $command } }
    }
    return @($byFolder.Values | ForEach-Object { $_.Command })
}

function Get-ClaudeDesktopInstall {
    <#
    .SYNOPSIS
        Whether Claude Desktop is installed, its version and how, and the version that is running.

    .DESCRIPTION
        The Microsoft Store and MSIX package is found with Get-AppxPackage, which lists it even
        where Program Files\WindowsApps cannot be read. The per-user installer puts versioned
        folders under %LOCALAPPDATA%\AnthropicClaude and updates by adding a new one, so the
        running process can be an older build than the newest installed: measured on the
        owner's workstation 2026-09-27, 2.9939.2 was installed while app-1.44121.2\claude.exe
        ran, and that build could not read the Entra sign-in keys. RunningVersion is what reads
        the configuration. CLAUDE_CLIENT_DESKTOP_VERSION and CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION
        override detection for tests.
    #>
    param()
    $installed = [pscustomobject]@{ Installed = $false; Version = ''; Source = ''; RunningVersion = ''; RunningPath = '' }
    if ($env:CLAUDE_CLIENT_DESKTOP_VERSION) {
        $installed = [pscustomobject]@{ Installed = $true; Version = $env:CLAUDE_CLIENT_DESKTOP_VERSION; Source = 'CLAUDE_CLIENT_DESKTOP_VERSION'; RunningVersion = ''; RunningPath = '' }
    }
    elseif (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        try {
            $pkg = @(Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.Publisher -match 'Anthropic' }) | Select-Object -First 1
            if ($pkg) { $installed = [pscustomobject]@{ Installed = $true; Version = [string]$pkg.Version; Source = "MSIX $($pkg.PackageFullName)"; RunningVersion = ''; RunningPath = '' } }
        } catch { Write-Verbose "Get-AppxPackage failed: $($_.Exception.Message)" }
    }
    if (-not $installed.Installed -and $env:LOCALAPPDATA) {
        $apps = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'AnthropicClaude') -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Sort-Object { ConvertTo-ClaudeClientVersion $_.Name } -Descending)
        if ($apps.Count) { $installed = [pscustomobject]@{ Installed = $true; Version = ($apps[0].Name -replace '^app-', ''); Source = $apps[0].FullName; RunningVersion = ''; RunningPath = '' } }
    }
    if ($env:CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION) {
        $installed.RunningVersion = $env:CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION
        $installed.RunningPath = 'CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION'
        if (-not $installed.Installed) { $installed.Installed = $true }
        return $installed
    }
    if ($env:CLAUDE_CLIENT_DESKTOP_VERSION) { return $installed }
    foreach ($process in @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue)) {
        $path = try { [string]$process.Path } catch { '' }
        if (-not $path) { continue }
        # app-1.44121.2\claude.exe or WindowsApps\Claude_2.2553.1.0_x64__...
        $fromPath = [regex]::Match($path, '(?i)(app-|Claude_)(\d+\.\d+\.\d+(\.\d+)?)')
        $version = if ($fromPath.Success) { $fromPath.Groups[2].Value } else { try { [string]$process.MainModule.FileVersionInfo.ProductVersion } catch { '' } }
        $installed.RunningVersion = $version
        $installed.RunningPath = $path
        if (-not $installed.Installed) { $installed.Installed = $true; $installed.Version = $version; $installed.Source = 'running process' }
        break
    }
    return $installed
}

function Get-ClaudeDesktopReadingVersion {
    <#
    .SYNOPSIS
        The oldest Desktop build that may read a profile on this machine: the running build when
        it is older than the installed one, otherwise the installed one; empty when unknown.
    #>
    param($Install)
    $versions = @(@($Install.Version, $Install.RunningVersion) | Where-Object { ConvertTo-ClaudeClientVersion $_ })
    if (-not $versions.Count) { return '' }
    return [string](@($versions | Sort-Object { ConvertTo-ClaudeClientVersion $_ })[0])
}

function Get-ClaudeDesktopVersionedShortcut {
    <#
    .SYNOPSIS
        Shortcuts that start one versioned Claude Desktop build instead of the updating launcher.

    .DESCRIPTION
        The per-user installer's launcher is %LOCALAPPDATA%\AnthropicClaude\claude.exe. A shortcut
        pinned to app-<version>\claude.exe keeps starting that build after updates.
    #>
    param([string[]]$Folders)
    if (-not $Folders) {
        $Folders = @(
            (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
            [Environment]::GetFolderPath('Desktop')
        ) | Where-Object { $_ }
    }
    $shell = try { New-Object -ComObject WScript.Shell } catch { $null }
    if (-not $shell) { return @() }
    return @(foreach ($folder in $Folders) {
        foreach ($link in @(Get-ChildItem -LiteralPath $folder -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
            $target = try { [string]$shell.CreateShortcut($link.FullName).TargetPath } catch { '' }
            if ($target -match '(?i)AnthropicClaude\\app-\d+\.\d+\.\d+[^\\]*\\claude\.exe$') {
                [pscustomobject]@{ Shortcut = $link.FullName; Target = $target }
            }
        }
    })
}

function Invoke-ClaudeClientCommand {
    <#
    .SYNOPSIS
        Runs a client command with no input, a time limit and UTF-8 output, and never waits
        for a key press.

    .DESCRIPTION
        Some Claude Code releases' `claude doctor` stop at "Press Enter to continue". Run with the
        console as input, a script waited until someone pressed a key, and its box-drawing
        output, UTF-8 read as the console code page, printed as mojibake. Here standard input is
        closed at once, output is decoded as UTF-8, and the process tree is ended at the time
        limit. Arguments must be fixed words, never user input: a .cmd shim runs through cmd.exe.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 30,
        [string]$WorkingDirectory
    )
    foreach ($a in $Arguments) {
        if ($a -notmatch '^[A-Za-z0-9._=-]+$') { throw "Invoke-ClaudeClientCommand takes fixed words only, not '$a'." }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in @('.cmd', '.bat')) {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /c "' + $Path + '" ' + ($Arguments -join ' ')
    }
    elseif ($ext -eq '.ps1') {
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Path + '" ' + ($Arguments -join ' ')
    }
    else {
        $psi.FileName = $Path
        $psi.Arguments = ($Arguments -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $process = [Diagnostics.Process]::Start($psi) }
    catch {
        # A diagnostic that throws hides every check after it; the failure is the result.
        $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = $null
            StartFailed = $true
            Output = "could not start ${Path}: $reason"
            Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }
    try { $process.StandardInput.Close() } catch { Write-Verbose 'standard input already closed' }
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
    if (-not $finished) {
        # PowerShell 5.1 runs on .NET Framework, which has no Kill(entireProcessTree).
        try { $process.Kill($true) } catch { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null }
        $null = $process.WaitForExit(5000)
    }
    $null = $out.Wait(5000); $null = $err.Wait(5000)
    $text = ([string]$(if ($out.IsCompleted) { $out.Result }) + [string]$(if ($err.IsCompleted) { $err.Result }))
    [pscustomobject]@{
        TimedOut = -not $finished
        ExitCode = $(if ($finished) { $process.ExitCode } else { $null })
        StartFailed = $false
        Output = ConvertTo-ClaudeClientPlainText $text
        Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function ConvertTo-ClaudeClientPlainText {
    <#
    .SYNOPSIS
        Terminal output without escape sequences, box-drawing rules or blank runs.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')
    $t = [regex]::Replace($t, "\x1b\][^\x07]*(\x07|\x1b\\)", '')
    $t = [regex]::Replace($t, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    $lines = foreach ($line in ($t -split "\r?\n")) {
        $trimmed = $line.TrimEnd()
        if ($trimmed -match '^[\s\u2500-\u257F]*$') { continue }
        $trimmed
    }
    return (@($lines) -join [Environment]::NewLine).Trim()
}
