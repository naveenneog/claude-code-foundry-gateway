# Where Install-ClaudeGateway.ps1 keeps its install checkpoint, and whether it trusts that place
# (docs/adr/0046-installer-checkpoint-and-resume.md decisions 1 and 2). Dot-sourced by
# scripts/ClaudeInstallCheckpoint.ps1. Runs on Windows PowerShell 5.1 and PowerShell 7.

function Get-ClaudeInstallCloudShell {
    # The Cloud Shell image sets AZUREPS_HOST_ENVIRONMENT; the Azure CLI reads ACC_CLOUD (U64).
    if ("$env:AZUREPS_HOST_ENVIRONMENT" -like 'cloud-shell/*') { return 'AZUREPS_HOST_ENVIRONMENT' }
    if ("$env:ACC_CLOUD") { return 'ACC_CLOUD' }
    return ''
}

function Test-ClaudeInstallWritable([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $probe = Join-Path $Path ('.claude-gateway-probe-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'probe'); Remove-Item -LiteralPath $probe -Force; return $true } catch { return $false }
}

function Get-ClaudeInstallLocation {
    param([Parameter(Mandatory = $true)][string]$Root)
    $windows = Test-ClaudeInstallWindows
    $keyText = if ($windows) { $Root.ToLowerInvariant() } else { $Root }
    $key = 'install-' + (Get-ClaudeInstallSha256 ([Text.Encoding]::UTF8.GetBytes($keyText))).Substring(0, 16)
    $homeDir = if ($env:HOME) { $env:HOME } else { $HOME }
    $join = { param([string]$Parent, [string]$Child) if ($windows) { Join-Path $Parent $Child } else { $Parent.TrimEnd('/') + '/' + $Child } }
    $cloudShell = Get-ClaudeInstallCloudShell
    $persistent = $true; $warning = ''; $cloudDrive = $false
    if ($env:CLAUDE_GATEWAY_STATE_DIR) { $dir = $env:CLAUDE_GATEWAY_STATE_DIR }
    elseif ($cloudShell) {
        $drive = & $join $homeDir 'clouddrive'
        if (Test-ClaudeInstallWritable $drive) { $dir = & $join $drive '.claude-gateway'; $cloudDrive = $true }
        else {
            $dir = & $join $homeDir '.claude-gateway'; $persistent = $false
            $warning = "Cloud Shell without clouddrive ($cloudShell is set and $drive is not a writable directory): the install checkpoint is kept in $dir, which does not persist when the session ends."
        }
    }
    elseif ($windows) { $dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'claude-gateway' }
    else { $base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { & $join (& $join $homeDir '.local') 'state' }; $dir = & $join $base 'claude-gateway' }
    [pscustomobject]@{ Directory = $dir; Checkpoint = (& $join $dir "$key.json"); Lock = (& $join $dir "$key.lock"); Key = $key; HomeDirectory = $homeDir
        Persistent = $persistent; Warning = $warning; CloudShell = $cloudShell; CloudDrive = $cloudDrive; Resolved = ''
        Explicit = [bool]$env:CLAUDE_GATEWAY_STATE_DIR; NoStore = '' }
}

function Set-ClaudeInstallOwnerOnly {
    param([string]$Path, [switch]$Directory)
    if (Test-ClaudeInstallWindows) {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = if ($Directory) { New-Object System.Security.AccessControl.DirectorySecurity } else { New-Object System.Security.AccessControl.FileSecurity }
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', $inherit, 'None', 'Allow')))
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else { & chmod $(if ($Directory) { '700' } else { '600' }) $Path 2>$null }
}

function New-ClaudeInstallStateDirectory([string]$Path) {
    # Each missing directory is created owner-only: one that its group could write would make the store
    # untrusted (decision 2).
    if (Test-ClaudeInstallWindows) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
    else {
        $global:LASTEXITCODE = 0
        & /bin/sh -c 'umask 077 && mkdir -p -- "$1"' sh $Path 2>$null
        if ($LASTEXITCODE -ne 0) { throw "mkdir -p exited $LASTEXITCODE" }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw 'no directory was created' }
    Set-ClaudeInstallOwnerOnly $Path -Directory
}

function Get-ClaudeInstallPosixStat([string]$Path) {
    # The probe of the POSIX store checks: whether the path exists and is a symbolic link, whether the
    # current user (test -O) or root owns it, and its owner and mode as ls prints them. Tests replace it,
    # because Git Bash and Windows have no POSIX modes.
    $item = $null
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { $item = $null }
    if (-not $item) { return [pscustomobject]@{ Exists = $false; Link = $false; Mine = $false; Root = $false; Owner = ''; Mode = '' } }
    $global:LASTEXITCODE = 1
    try { & /bin/sh -c 'test -O "$1"' sh $Path 2>$null } catch { }
    $mine = ($LASTEXITCODE -eq 0)
    $line = ''; $numeric = ''
    try { $line = [string](@(& env LC_ALL=C ls -ldL -- $Path 2>$null) | Select-Object -First 1) } catch { $line = '' }
    try { $numeric = [string](@(& env LC_ALL=C ls -ldLn -- $Path 2>$null) | Select-Object -First 1) } catch { $numeric = '' }
    $fields = @($line.Trim() -split '\s+'); $ids = @($numeric.Trim() -split '\s+')
    [pscustomobject]@{ Exists = $true; Link = [bool]$item.LinkType; Mine = $mine; Root = ($ids.Count -gt 2 -and $ids[2] -eq '0')
        Owner = $(if ($fields.Count -gt 2) { $fields[2] } else { '' }); Mode = $(if ($line.Length -ge 10) { $line.Substring(0, 10) } else { '' }) }
}

function Get-ClaudeInstallPosixRealPath([string]$Path) {
    # The real path (cd -P) of the deepest directory of a path that exists, then the rest as written;
    # '' when none resolves. Tests replace it on Windows, which has no /bin/sh.
    $p = $Path.TrimEnd('/'); if (-not $p) { $p = '/' }
    $rest = ''
    while ($p -ne '/' -and -not (Test-Path -LiteralPath $p -PathType Container)) {
        $i = $p.LastIndexOf('/')
        $rest = $p.Substring($i) + $rest
        $p = if ($i -le 0) { '/' } else { $p.Substring(0, $i) }
    }
    $real = [string](@(& /bin/sh -c 'cd -P -- "$1" 2>/dev/null && pwd -P' sh $p) | Select-Object -First 1)
    if (-not $real) { return '' }
    $out = $real.TrimEnd('/') + $rest
    if ($out) { return $out } else { return '/' }
}

function Get-ClaudeInstallWindowsOwner([string]$Path) {
    # The owner of a path, as a SID. Tests replace it: without the restore privilege an account cannot
    # give a directory another owner.
    return [string](Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
}

function Test-ClaudeInstallReparsePoint([string]$Path) {
    # A junction or a symbolic link (FileAttributes.ReparsePoint), read without following it.
    try { return (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) } catch { return $false }
}

function Get-ClaudeInstallWindowsTrusted { return @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544') }

function Get-ClaudeInstallSidName([string]$Sid) {
    try { return (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { return $Sid }
}

function Get-ClaudeInstallWindowsWriters {
    # The allow rules on a path that grant an account other than the current user, SYSTEM (S-1-5-18) or
    # BUILTIN\Administrators (S-1-5-32-544) a right in the mask. The default mask: WriteData,
    # AppendData, WriteExtendedAttributes, DeleteSubdirectoriesAndFiles, WriteAttributes, Delete,
    # ChangePermissions, TakeOwnership, GENERIC_ALL and GENERIC_WRITE. An inherit-only rule does not
    # apply to the path itself.
    param([string]$Path, [int64]$Mask = (0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000))
    $trusted = Get-ClaudeInstallWindowsTrusted
    foreach ($rule in @((Get-Acl -LiteralPath $Path).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
        if ([string]$rule.AccessControlType -ne 'Allow' -or $trusted -contains [string]$rule.IdentityReference.Value) { continue }
        if (([int]$rule.PropagationFlags -band [int][System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if (([int64][int]$rule.FileSystemRights -band $Mask) -eq 0) { continue }
        [pscustomobject]@{ Sid = [string]$rule.IdentityReference.Value; Name = (Get-ClaudeInstallSidName ([string]$rule.IdentityReference.Value)); Rights = [string]$rule.FileSystemRights }
    }
}

function Get-ClaudeInstallStoreTail {
    $c = $script:ClaudeInstall
    return ('Nothing was read or changed.' + $(if ($c -and $c.Root) { " Resume: $(Format-ClaudeInstallResume)" } else { '' }))
}

function Get-ClaudeInstallWindowsParentProblem([string]$Directory) {
    # An account that may delete what the parent holds, or change its rules, could replace the state
    # directory between a check and a read (decision 2). '' when the parent is trusted.
    $parent = [IO.Path]::GetDirectoryName($Directory.TrimEnd('\'))
    if (-not $parent -or -not (Test-Path -LiteralPath $parent)) { return '' }
    $owner = Get-ClaudeInstallWindowsOwner $parent
    if ((Get-ClaudeInstallWindowsTrusted) -notcontains $owner) {
        return "the directory $parent, which holds the install checkpoint directory $Directory, is owned by $(Get-ClaudeInstallSidName $owner) ($owner), not by the current user, SYSTEM or Administrators, so the store is not trusted."
    }
    # DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership and GENERIC_ALL; FullControl holds them.
    $rule = @(Get-ClaudeInstallWindowsWriters -Path $parent -Mask (0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000))[0]
    if ($rule) { return "the directory $parent, which holds the install checkpoint directory $Directory, lets $($rule.Name) ($($rule.Sid)) delete or replace what it holds ($($rule.Rights)), so the store is not trusted." }
    return ''
}

function Get-ClaudeInstallStorePathProblem {
    # Why another account could have written or replaced a store path, or '' (ADR-0046 decision 2).
    # clouddrive is exempt: its mount sets the modes, and the Cloud Shell storage account's access
    # control applies (U66).
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateSet('directory', 'file')][string]$Kind = 'file')
    $c = $script:ClaudeInstall
    if ($c -and $c.Location -and $c.Location.CloudDrive) { return '' }
    $why = ''
    if (Test-ClaudeInstallWindows) {
        # A state directory still to be created is judged by the directory that will hold it.
        if (-not (Test-Path -LiteralPath $Path)) { if ($Kind -eq 'directory') { return (Get-ClaudeInstallWindowsParentProblem $Path) }; return '' }
        # The state directory's own name is checked for a link where its place is resolved.
        if ($Kind -eq 'file' -and (Test-ClaudeInstallReparsePoint $Path)) { $why = 'is a symbolic link or junction' }
        else {
            $owner = Get-ClaudeInstallWindowsOwner $Path
            if ((Get-ClaudeInstallWindowsTrusted) -notcontains $owner) { $why = "is owned by $(Get-ClaudeInstallSidName $owner) ($owner), not by the current user, SYSTEM or Administrators" }
        }
        if (-not $why) {
            $writer = @(Get-ClaudeInstallWindowsWriters -Path $Path)[0]
            if ($writer) {
                return "the install checkpoint $Kind $Path has an access rule that lets $($writer.Name) ($($writer.Sid)) write it ($($writer.Rights)), so it is not trusted; only the current user, SYSTEM and Administrators may write the store, and a state directory the installer creates is owner-only."
            }
        }
        if (-not $why -and $Kind -eq 'directory') {
            $acl = Get-Acl -LiteralPath $Path
            if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object { $_.IsInherited }).Count) { $why = 'inherits its access rules from the directory that holds it, where one the installer creates has only its own' }
        }
        if ($why) { return "the install checkpoint $Kind $Path $why, so it is not trusted; a state directory the installer creates is owner-only." }
        if ($Kind -eq 'directory') { return (Get-ClaudeInstallWindowsParentProblem $Path) }
        return ''
    }
    $s = Get-ClaudeInstallPosixStat $Path
    if (-not $s.Exists) { return '' }
    if ($Kind -eq 'file' -and $s.Link) { $why = 'is a symbolic link' }
    elseif (-not $s.Mine) { $why = "is owned by $(if ($s.Owner) { $s.Owner } else { 'another user' }), not by the current user" }
    elseif ([string]$s.Mode -match '^.{5}w' -or [string]$s.Mode -match '^.{8}w') { $why = "has mode $($s.Mode) (owner $($s.Owner)), so its group or other users can write it" }
    if ($why) { return "the install checkpoint $Kind $Path $why, so it is not trusted; a state directory the installer creates is owner-only." }
    return ''
}

function Assert-ClaudeInstallStorePath {
    # Refuses a store path that another account could have written or replaced, before the installer
    # reads, parses, locks, renames or replaces anything (ADR-0046 decision 2).
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateSet('directory', 'file')][string]$Kind = 'file', [string]$Tail)
    $why = Get-ClaudeInstallStorePathProblem -Path $Path -Kind $Kind
    if (-not $why) { return }
    if (-not $Tail) { $Tail = Get-ClaudeInstallStoreTail }
    Stop-ClaudeInstall "$why $Tail"
}

function Resolve-ClaudeInstallLocation {
    # Where the state directory is (decision 2): an absolute path inside the user profile (Windows) or
    # $HOME (POSIX), or inside clouddrive in Cloud Shell, and not itself a link or junction. From here on
    # the directory is used by its real path only, and a second resolution must give the same path.
    # Returns '' when the place is trusted, or why it is not.
    $c = $script:ClaudeInstall; $l = $c.Location
    $dir = [string]$l.Directory
    if (Test-ClaudeInstallWindows) {
        if (-not [IO.Path]::IsPathRooted($dir)) { return "the install checkpoint directory $dir is not an absolute path, so it is not used." }
        $real = [IO.Path]::GetFullPath($dir).TrimEnd('\')
        if (Test-ClaudeInstallReparsePoint $real) { return "the install checkpoint directory $dir is a symbolic link or junction, so it is not trusted; the installer does not follow a link in the state directory's own name." }
        $where = 'the user profile'; $within = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('\')
        if ($l.CloudDrive) { $where = 'clouddrive'; $within = [IO.Path]::GetFullPath((Join-Path $l.HomeDirectory 'clouddrive')).TrimEnd('\') }
        if (-not $real.StartsWith($within + '\', [StringComparison]::OrdinalIgnoreCase)) { return "the install checkpoint directory $dir resolves to $real, which is not inside $where $within, so it is not used." }
        # Every directory between the state directory and the profile is itself, so the path is its real path.
        $a = [IO.Path]::GetDirectoryName($real)
        while ($a -and $a.StartsWith($within + '\', [StringComparison]::OrdinalIgnoreCase)) {
            if (Test-ClaudeInstallReparsePoint $a) { return "the directory $a, which holds the install checkpoint directory $real, is a symbolic link or junction, so the store is not trusted." }
            $a = [IO.Path]::GetDirectoryName($a)
        }
        $sep = '\'
    }
    else {
        if (-not $dir.StartsWith('/')) { return "the install checkpoint directory $dir is not an absolute path, so it is not used." }
        if ("$dir/" -match '/\.\.?/') { return "the install checkpoint directory $dir has a . or .. component, so it is not used." }
        $dir = $dir.TrimEnd('/'); if (-not $dir) { $dir = '/' }
        $s = Get-ClaudeInstallPosixStat $dir
        if ($s.Exists -and $s.Link) { return "the install checkpoint directory $dir is a symbolic link or junction, so it is not trusted; the installer does not follow a link in the state directory's own name." }
        $homeReal = if ($l.HomeDirectory) { Get-ClaudeInstallPosixRealPath ([string]$l.HomeDirectory) } else { '' }
        if (-not $homeReal) { return "the home directory $($l.HomeDirectory) could not be resolved, so the install checkpoint directory $dir cannot be placed inside it." }
        $where = 'the home directory'; $within = $homeReal
        if ($l.CloudDrive) { $where = 'clouddrive'; $within = Get-ClaudeInstallPosixRealPath (([string]$l.HomeDirectory).TrimEnd('/') + '/clouddrive') }
        $real = Get-ClaudeInstallPosixRealPath $dir
        if (-not $real -or -not $within -or -not $real.StartsWith($within.TrimEnd('/') + '/', [StringComparison]::Ordinal)) {
            return "the install checkpoint directory $dir resolves to $(if ($real) { $real } else { 'no real path' }), which is not inside $where $within, so it is not used."
        }
        $l | Add-Member -NotePropertyName HomeReal -NotePropertyValue $homeReal -Force
        $sep = '/'
    }
    if ($l.Resolved -and $l.Resolved -ne $real) { return "the install checkpoint directory resolved to $($l.Resolved) at startup and to $real now, so it is not used." }
    $l.Resolved = $real; $l.Directory = $real
    $l.Checkpoint = $real + $sep + "$($l.Key).json"; $l.Lock = $real + $sep + "$($l.Key).lock"
    return ''
}

function Get-ClaudeInstallAncestorProblem {
    # POSIX: every directory from the one that holds the state directory up to $HOME is owned by the
    # current user or root and is not writable by its group or other users unless its sticky bit is set
    # (OpenSSH's StrictModes rule), so no other account can rename an entry between a check and a read.
    # Inside clouddrive the mount sets the modes (U66), so only $HOME is read there. '' when they are.
    if (Test-ClaudeInstallWindows) { return '' }
    $l = $script:ClaudeInstall.Location
    $dir = [string]$l.Directory; $homeReal = [string]$l.HomeReal
    $a = if ($l.CloudDrive) { $homeReal } else { $dir.Substring(0, [math]::Max(1, $dir.LastIndexOf('/'))) }
    while ($true) {
        $s = Get-ClaudeInstallPosixStat $a
        if ($s.Exists) {
            if (-not $s.Mine -and -not $s.Root) { return "the directory $a, which holds the install checkpoint directory $dir, is owned by $(if ($s.Owner) { $s.Owner } else { 'another user' }), not by the current user or root, so the store is not trusted." }
            $mode = [string]$s.Mode
            $sticky = $mode.Length -ge 10 -and 'tT'.Contains([string]$mode[9])
            if ($mode.Length -ge 10 -and ($mode[5] -eq 'w' -or $mode[8] -eq 'w') -and -not $sticky) {
                return "the directory $a, which holds the install checkpoint directory $dir, has mode $mode (owner $($s.Owner)), so its group or other users can rename what it holds, and the store is not trusted."
            }
        }
        if ($a -eq $homeReal -or $a -eq '/') { return '' }
        $a = $a.Substring(0, [math]::Max(1, $a.LastIndexOf('/')))
    }
}

function Get-ClaudeInstallStoreFiles {
    # This checkout's checkpoint, lock and temporary files in the state directory, found by name; none
    # of them is read.
    $l = $script:ClaudeInstall.Location
    $found = @(foreach ($p in @([string]$l.Checkpoint, [string]$l.Lock)) { if (Test-Path -LiteralPath $p) { $p } })
    if (Test-Path -LiteralPath $l.Directory -PathType Container) {
        $found += @(Get-ChildItem -LiteralPath $l.Directory -Filter "$($l.Key).json.tmp-*" -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return $found
}

function Assert-ClaudeInstallStore {
    # Before anything in the store is read: where it is, the state directory, what holds it, and then
    # the checkpoint and the lock (decision 2). A store that fails a check refuses when
    # CLAUDE_GATEWAY_STATE_DIR names it, or when its default place holds this checkout's checkpoint,
    # lock or a temporary file, so that such a file is shown and a run that was to resume does not start
    # over unnoticed. Otherwise the run keeps no store (Location.NoStore) and relies on its live checks
    # (decision 1).
    $l = $script:ClaudeInstall.Location
    $why = Resolve-ClaudeInstallLocation
    if (-not $why) { $why = Get-ClaudeInstallStorePathProblem -Path $l.Directory -Kind directory }
    if (-not $why) { $why = Get-ClaudeInstallAncestorProblem }
    if (-not $why) { $why = Get-ClaudeInstallStorePathProblem -Path $l.Checkpoint -Kind file }
    if (-not $why) { $why = Get-ClaudeInstallStorePathProblem -Path $l.Lock -Kind file }
    if (-not $why) { return }
    if ($l.Explicit) { Stop-ClaudeInstall "$why The directory is named by CLAUDE_GATEWAY_STATE_DIR. $(Get-ClaudeInstallStoreTail)" }
    $found = @(Get-ClaudeInstallStoreFiles)
    if ($found.Count) {
        $what = if ($found.Count -eq 1) { "This checkout's install file $($found[0]) is there" } else { "This checkout's install files $($found -join ', ') are there" }
        Stop-ClaudeInstall "$why $what, so the run stops instead of starting over. Nothing was read or changed. Next step: inspect the file, then remove it or correct the permissions, then rerun: $(Format-ClaudeInstallResume)"
    }
    $l.Persistent = $false
    $l.NoStore = "$why This run keeps no install checkpoint."
}
