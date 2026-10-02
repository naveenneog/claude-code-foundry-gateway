# The install checkpoint store (docs/adr/0046-installer-checkpoint-and-resume.md decision 2): before
# either installer reads, parses, locks, renames or replaces anything in its state directory, it refuses
# a directory or file that another account could have written. The decision runs here on every platform
# through each library's probe seam; the real Windows access-rule checks run on Windows, and the real
# POSIX mode checks on Linux and macOS (.github/workflows/installer-unix.yml). The schema and step ids
# that the two libraries share are checked for drift.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Install checkpoint store: permissions and shared schema' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$windows = [bool]($IsWindows -or $env:OS -eq 'Windows_NT')
$bash = $null
if ($windows) {
    foreach ($c in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', (Join-Path "$env:LOCALAPPDATA" 'Programs\Git\bin\bash.exe'))) { if (Test-Path -LiteralPath $c) { $bash = $c; break } }
}
else { $bash = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
if (-not $bash) { Write-Host '  [FAIL] no Git Bash (Windows) or bash (macOS, Linux) on this machine, so the bash checks cannot run.' -ForegroundColor Red; exit 1 }
function ConvertTo-BashPath([string]$Path) { if ($windows) { '/' + ($Path.Replace('\', '/') -replace '^([A-Za-z]):', '$1') } else { $Path } }
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false)) }

$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('p91-store-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$psLibrary = Join-Path $root 'scripts/ClaudeInstallCheckpoint.ps1'
$shLibrary = Join-Path $root 'scripts/install-checkpoint.sh'

# The bash library sourced alone, with the installer's output helpers stubbed. P91_FAKE, when set, is
# the body of the probe the decision reads.
$driver = Join-Path $scratch 'driver.sh'
Write-Lf $driver @'
C_YELLOW=""; C_OFF=""; C_GREEN=""; C_CYAN=""; C_GREY=""; C_RED=""
warn_() { printf '[WARN] %s\n' "$1"; }; note_() { :; }; ok_() { :; }; bad_() { :; }
. "$1"
CKPT_ROOT="/p91/checkout"; CKPT_CLOUDDRIVE="${P91_CLOUDDRIVE:-0}"
if [ -n "${P91_FAKE:-}" ]; then ckpt_perm_probe_() { eval "$P91_FAKE"; }; fi
ckpt_perm_check_ "$2" "$3"
echo "PASSED"
'@
function Invoke-BashCheck([string]$Path, [string]$Kind, [string]$Fake, [switch]$CloudDrive) {
    $env:P91_FAKE = $Fake
    $env:P91_CLOUDDRIVE = $(if ($CloudDrive) { '1' } else { '0' })
    try { $out = @(& $bash (ConvertTo-BashPath $driver) (ConvertTo-BashPath $shLibrary) (ConvertTo-BashPath $Path) $Kind 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { Remove-Item Env:P91_FAKE, Env:P91_CLOUDDRIVE -ErrorAction SilentlyContinue }
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n"); Passed = ($code -eq 0 -and ($out -contains 'PASSED')) }
}
function Test-Refused($Result, [string]$Pattern) {
    $lines = @($Result.Text -split "`n" | Where-Object { $_ -match '^Refused: ' })
    $Result.Code -eq 1 -and $lines.Count -eq 1 -and $lines[0] -match $Pattern -and $lines[0] -match 'Nothing was read or changed' -and $lines[0] -match 'Resume: '
}
# The bash library's whole store check for a state directory and a home. uname is replaced here, and
# only here, so that Git Bash takes the Linux path (test only; the installer has no such switch).
$placeDriver = Join-Path $scratch 'place.sh'
Write-Lf $placeDriver @'
C_YELLOW=""; C_OFF=""; C_GREEN=""; C_CYAN=""; C_GREY=""; C_RED=""
warn_() { printf '[WARN] %s\n' "$1"; }; note_() { :; }; ok_() { :; }; bad_() { :; }
. "$1"
uname() { if [ "${1:-}" = "-s" ]; then printf '%s\n' "${P91_UNAME_S:-Linux}"; else command uname "$@"; fi; }
CKPT_ROOT="/p91/checkout"
if [ -n "${P91_FAKE:-}" ]; then ckpt_perm_probe_() { eval "$P91_FAKE"; }; fi
ckpt_location_
ckpt_store_check_
echo "PASSED $CKPT_DIR"
'@
function Invoke-BashPlace([string]$StateDir, [string]$HomeDir, [string]$Fake) {
    $saved = @{ HOME = $env:HOME; CLAUDE_GATEWAY_STATE_DIR = $env:CLAUDE_GATEWAY_STATE_DIR }
    $env:P91_FAKE = $Fake; $env:HOME = $HomeDir; $env:CLAUDE_GATEWAY_STATE_DIR = $StateDir
    try { $out = @(& $bash (ConvertTo-BashPath $placeDriver) (ConvertTo-BashPath $shLibrary) 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { Remove-Item Env:P91_FAKE -ErrorAction SilentlyContinue; $env:HOME = $saved.HOME; $env:CLAUDE_GATEWAY_STATE_DIR = $saved.CLAUDE_GATEWAY_STATE_DIR }
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n"); Passed = ($code -eq 0 -and @($out | Where-Object { $_ -like 'PASSED *' }).Count -eq 1) }
}

try {
    # ------------------------------------------------------------------ the shared schema
    $ps = [IO.File]::ReadAllText($psLibrary)
    $sh = [IO.File]::ReadAllText($shLibrary)
    $psSchema = [regex]::Match($ps, '(?m)^\$script:ClaudeInstallSchema = ''([^'']+)''').Groups[1].Value
    $shSchema = [regex]::Match($sh, '(?m)^CKPT_SCHEMA="([^"]+)"').Groups[1].Value
    $block = [regex]::Match($ps, '(?s)\$script:ClaudeInstallSteps = \[ordered\]@\{(.*?)\n\}').Groups[1].Value
    $psSteps = @([regex]::Matches($block, "'([a-z-]+)' = '") | ForEach-Object { $_.Groups[1].Value })
    $shSteps = @(([regex]::Match($sh, '(?m)^CKPT_STEP_IDS="([^"]+)"').Groups[1].Value -split '\s+') | Where-Object { $_ })
    Assert 'the two libraries name one schema and the same step ids in the same order' ($psSchema -and $psSchema -ceq $shSchema -and $psSteps.Count -ge 10 -and
        ($psSteps -join ' ') -ceq ($shSteps -join ' ')) "pwsh $psSchema [$($psSteps -join ' ')] / bash $shSchema [$($shSteps -join ' ')]"

    # ------------------------------------------------------------------ PowerShell: the decision, through the probe seam
    . $psLibrary
    $realWindows = ${function:Test-ClaudeInstallWindows}
    $realStat = ${function:Get-ClaudeInstallPosixStat}
    $script:ClaudeInstall = [pscustomobject]@{ Root = (Join-Path $scratch 'checkout'); Location = [pscustomobject]@{ CloudDrive = $false }; Answers = [ordered]@{} }
    $seam = Join-Path $scratch 'seam'
    New-Item -ItemType Directory -Force -Path $seam | Out-Null
    $seamFile = Join-Path $seam 'install-0000000000000000.json'
    Write-Lf $seamFile '{}'
    $script:fakeStat = $null
    function Test-ClaudeInstallWindows { $false }
    function Get-ClaudeInstallPosixStat([string]$Path) { $script:fakeStat }
    $decide = {
        param([string]$Path, [string]$Kind, [bool]$Link, [bool]$Mine, [string]$Mode, [string]$Owner)
        $script:fakeStat = [pscustomobject]@{ Exists = $true; Link = $Link; Mine = $Mine; Root = $false; Mode = $Mode; Owner = $Owner }
        try { Assert-ClaudeInstallStorePath -Path $Path -Kind $Kind; 'PASSED' } catch { $_.Exception.Message }
    }
    $refused = { param([string]$Message, [string]$Pattern) $Message -match '^Refused: ' -and $Message -match $Pattern -and $Message -match 'Nothing was read or changed' -and $Message -match 'Resume: ' }
    $a = & $decide $seam 'directory' $false $false 'drwx------' 'p91-other'
    Assert 'pwsh POSIX: a store path another user owns is refused, naming the owner and the path' ((& $refused $a 'is owned by p91-other') -and $a.Contains($seam)) $a
    $b = & $decide $seam 'directory' $false $true 'drwxrwx---' 'p91-me'
    $c = & $decide $seamFile 'file' $false $true '-rw-rw-rw-' 'p91-me'
    Assert 'pwsh POSIX: a directory its group can write and a file other users can write are refused, naming the mode' ((& $refused $b 'drwxrwx---') -and (& $refused $c '-rw-rw-rw-')) "$b || $c"
    $d = & $decide $seamFile 'file' $true $true '-rw-------' 'p91-me'
    $e = & $decide $seam 'directory' $false $true 'drwx------' 'p91-me'
    $f = & $decide $seamFile 'file' $false $true '-rw-------' 'p91-me'
    $script:ClaudeInstall.Location.CloudDrive = $true
    $g = & $decide $seam 'directory' $false $false 'drwxrwxrwx' 'root'
    $script:ClaudeInstall.Location.CloudDrive = $false
    Assert 'pwsh POSIX: a checkpoint that is a symbolic link is refused; owner-only paths and the clouddrive store pass' ((& $refused $d 'symbolic link') -and $e -eq 'PASSED' -and $f -eq 'PASSED' -and $g -eq 'PASSED') "$d || $e || $f || $g"

    # ------------------------------------------------------------------ PowerShell: where the store is, through the seams
    # A POSIX tree written out: the probe answers for each path, and each path is its own real path.
    function Get-ClaudeInstallPosixRealPath([string]$Path) { $Path }
    $node = { param([string]$Mode = 'drwx------', [bool]$Mine = $true, [bool]$Root = $false, [string]$Owner = 'p91-me', [bool]$Link = $false)
        [pscustomobject]@{ Exists = $true; Link = $Link; Mine = $Mine; Root = $Root; Owner = $Owner; Mode = $Mode } }
    $tree = { param([hashtable]$Changes = @{})
        $t = @{ '/home/p91' = (& $node 'drwxr-x---'); '/home/p91/work' = (& $node 'drwxr-xr-x'); '/home/p91/work/state' = (& $node) }
        foreach ($k in $Changes.Keys) { $t[$k] = $Changes[$k] }
        $script:posixTree = $t }
    function Get-ClaudeInstallPosixStat([string]$Path) {
        if ($script:posixTree.ContainsKey($Path)) { return $script:posixTree[$Path] }
        [pscustomobject]@{ Exists = $false; Link = $false; Mine = $false; Root = $false; Owner = ''; Mode = '' }
    }
    $savedHome = $env:HOME; $savedState = $env:CLAUDE_GATEWAY_STATE_DIR
    $place = { param([string]$StateDir)
        $env:HOME = '/home/p91'; $env:CLAUDE_GATEWAY_STATE_DIR = $StateDir
        try { $script:ClaudeInstall = [pscustomobject]@{ Root = '/p91/checkout'; Location = (Get-ClaudeInstallLocation -Root '/p91/checkout'); Answers = [ordered]@{} }; Assert-ClaudeInstallStore; 'PASSED' }
        catch { $_.Exception.Message } }
    & $tree @{ '/home/p91/work' = (& $node 'drwxrwxr-x') }; $la = & $place '/home/p91/work/state'
    & $tree @{ '/home/p91/work' = (& $node 'drwxr-xr-x' $false $false 'p91-other') }; $lb = & $place '/home/p91/work/state'
    & $tree @{ '/home/p91/work' = (& $node 'drwxrwxrwt' $false $true 'root') }; $lc = & $place '/home/p91/work/state'
    Assert 'pwsh POSIX: a directory between the state directory and $HOME that its group can write or another user owns is refused, naming it; a sticky one root owns passes' (
        (& $refused $la '/home/p91/work, which holds') -and $la -match 'drwxrwxr-x' -and (& $refused $lb 'owned by p91-other') -and $lc -eq 'PASSED') "$la || $lb || $lc"
    & $tree @{ '/home/p91/work/state' = (& $node 'drwx------' $true $false 'p91-me' $true) }; $ld = & $place '/home/p91/work/state'
    Assert 'pwsh POSIX: a state directory that is a symbolic link is refused' (& $refused $ld 'symbolic link') $ld
    & $tree; $le = & $place '/srv/p91/state'
    Assert 'pwsh POSIX: a state directory outside $HOME is refused, naming $HOME' ((& $refused $le 'not inside the home directory /home/p91') -and $le.Contains('/srv/p91/state')) $le
    $env:HOME = $savedHome; $env:CLAUDE_GATEWAY_STATE_DIR = $savedState
    Remove-Item function:Get-ClaudeInstallPosixRealPath -ErrorAction SilentlyContinue
    . $psLibrary
    $script:ClaudeInstall = [pscustomobject]@{ Root = (Join-Path $scratch 'checkout'); Location = [pscustomobject]@{ CloudDrive = $false }; Answers = [ordered]@{} }
    Set-Item -Path function:Test-ClaudeInstallWindows -Value $realWindows
    if ($realStat) { Set-Item -Path function:Get-ClaudeInstallPosixStat -Value $realStat }

    # ------------------------------------------------------------------ bash: the decision, through the probe seam
    $sa = Invoke-BashCheck $seam 'directory' "PERM_LINK=0; PERM_MINE=0; PERM_MODE='drwx------'; PERM_OWNER='p91-other'"
    Assert 'bash: a store path another user owns is refused, naming the owner and the path' ((Test-Refused $sa 'is owned by p91-other') -and $sa.Text.Contains((ConvertTo-BashPath $seam))) $sa.Text
    $sb = Invoke-BashCheck $seam 'directory' "PERM_LINK=0; PERM_MINE=1; PERM_MODE='drwxrwx---'; PERM_OWNER='p91-me'"
    $sc = Invoke-BashCheck $seamFile 'file' "PERM_LINK=0; PERM_MINE=1; PERM_MODE='-rw-rw-rw-'; PERM_OWNER='p91-me'"
    Assert 'bash: a directory its group can write and a file other users can write are refused, naming the mode' ((Test-Refused $sb 'drwxrwx---') -and (Test-Refused $sc '-rw-rw-rw-')) "$($sb.Text) || $($sc.Text)"
    $sd = Invoke-BashCheck $seamFile 'file' "PERM_LINK=1; PERM_MINE=1; PERM_MODE='-rw-------'; PERM_OWNER='p91-me'"
    $se = Invoke-BashCheck $seam 'directory' "PERM_LINK=0; PERM_MINE=1; PERM_MODE='drwx------'; PERM_OWNER='p91-me'"
    $sf = Invoke-BashCheck $seamFile 'file' "PERM_LINK=0; PERM_MINE=1; PERM_MODE='-rw-------'; PERM_OWNER='p91-me'"
    $sg = Invoke-BashCheck $seam 'directory' "PERM_LINK=0; PERM_MINE=0; PERM_MODE='drwxrwxrwx'; PERM_OWNER='root'" -CloudDrive
    Assert 'bash: a checkpoint that is a symbolic link is refused; owner-only paths and the clouddrive store pass' ((Test-Refused $sd 'symbolic link') -and $se.Passed -and $sf.Passed -and $sg.Passed) "$($sd.Text) || $($se.Text) || $($sf.Text) || $($sg.Text)"

    # ------------------------------------------------------------------ bash: where the store is, through the probe seam
    # Real directories under a home of their own; the probe answers for each path.
    $bhome = Join-Path $scratch 'bhome'; $bwork = Join-Path $bhome 'work'; $bstate = Join-Path $bwork 'state'
    foreach ($p in $bhome, $bwork, $bstate) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    $bfake = { param([string]$WorkMode = 'drwxr-xr-x', [int]$WorkMine = 1, [int]$WorkRoot = 0, [string]$WorkOwner = 'p91-me', [int]$StateLink = 0)
        "PERM_LINK=0; PERM_MINE=1; PERM_ROOT=0; PERM_OWNER='p91-me'; PERM_MODE='drwx------'; case `"`$1`" in */bhome/work) PERM_MODE='$WorkMode'; PERM_MINE=$WorkMine; PERM_ROOT=$WorkRoot; PERM_OWNER='$WorkOwner' ;; */bhome/work/state) PERM_LINK=$StateLink ;; esac" }
    $ba = Invoke-BashPlace (ConvertTo-BashPath $bstate) (ConvertTo-BashPath $bhome) (& $bfake 'drwxrwxr-x')
    $bb = Invoke-BashPlace (ConvertTo-BashPath $bstate) (ConvertTo-BashPath $bhome) (& $bfake 'drwxr-xr-x' 0 0 'p91-other')
    $bc = Invoke-BashPlace (ConvertTo-BashPath $bstate) (ConvertTo-BashPath $bhome) (& $bfake 'drwxrwxrwt' 0 1 'root')
    Assert 'bash: a directory between the state directory and $HOME that its group can write or another user owns is refused, naming it; a sticky one root owns passes' (
        (Test-Refused $ba '/bhome/work, which holds') -and $ba.Text -match 'drwxrwxr-x' -and (Test-Refused $bb 'owned by p91-other') -and $bc.Passed) "$($ba.Text) || $($bb.Text) || $($bc.Text)"
    $bd = Invoke-BashPlace (ConvertTo-BashPath $bstate) (ConvertTo-BashPath $bhome) (& $bfake 'drwxr-xr-x' 1 0 'p91-me' 1)
    Assert 'bash: a state directory that is a symbolic link is refused' (Test-Refused $bd 'symbolic link') $bd.Text
    $elsewhere = Join-Path $scratch 'elsewhere'; New-Item -ItemType Directory -Force -Path $elsewhere | Out-Null
    $be = Invoke-BashPlace ((ConvertTo-BashPath $elsewhere) + '/state') (ConvertTo-BashPath $bhome) (& $bfake)
    Assert 'bash: a state directory outside $HOME is refused, naming $HOME' ((Test-Refused $be 'not inside the home directory') -and $be.Text -match '/bhome' -and $be.Text -match '/elsewhere/state') $be.Text

    if ($windows) {
        # ------------------------------------------------------------------ Windows: real access rules
        # Fresh security descriptors written through .NET, which writes the access section only:
        # Set-Acl also writes the audit rules, which needs SeSecurityPrivilege.
        $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = { param($Sid, [string]$Rights, [switch]$Inherit) New-Object System.Security.AccessControl.FileSystemAccessRule($Sid, $Rights, $(if ($Inherit) { 'ContainerInherit, ObjectInherit' } else { 'None' }), 'None', 'Allow') }
        $protect = { param([string]$Path, [object[]]$Rules)
            $acl = New-Object System.Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($r in $Rules) { $acl.AddAccessRule($r) }
            [System.IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $acl) }
        $addFileRule = { param([string]$Path, $Rule) $acl = New-Object System.Security.AccessControl.FileSecurity; $acl.AddAccessRule($Rule); [System.IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $acl) }
        $real = { param([string]$Path, [string]$Kind) try { Assert-ClaudeInstallStorePath -Path $Path -Kind $Kind; 'PASSED' } catch { $_.Exception.Message } }
        $open = Join-Path $scratch 'acl-everyone'; New-Item -ItemType Directory -Force -Path $open | Out-Null
        & $protect $open @((& $rule $owner 'FullControl' -Inherit), (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-1-0')) 'Modify' -Inherit))
        $kept = Join-Path $scratch 'acl-owner'; New-Item -ItemType Directory -Force -Path $kept | Out-Null
        & $protect $kept @((& $rule $owner 'FullControl' -Inherit), (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')) 'FullControl' -Inherit),
            (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')) 'FullControl' -Inherit))
        $usersFile = Join-Path $kept 'install-1111111111111111.json'; Write-Lf $usersFile '{}'
        & $addFileRule $usersFile (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')) 'Write')
        $readOnly = Join-Path $kept 'install-2222222222222222.json'; Write-Lf $readOnly '{}'
        & $addFileRule $readOnly (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')) 'ReadAndExecute')
        $wa = & $real $open 'directory'; $wb = & $real $usersFile 'file'
        Assert 'pwsh Windows: an allow rule that lets Everyone modify a directory or Users write a file is refused, naming the rule' ((& $refused $wa 'S-1-1-0') -and (& $refused $wb 'S-1-5-32-545')) "$wa || $wb"
        $wc = & $real $kept 'directory'; $wd = & $real $readOnly 'file'
        Assert 'pwsh Windows: rules for the current user, SYSTEM and Administrators, and a read-only rule for Users, pass' ($wc -eq 'PASSED' -and $wd -eq 'PASSED') "$wc || $wd"

        # Where the store is, and what holds it (decision 2): real junctions and access rules.
        $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $trustedRules = { @((& $rule $owner 'FullControl' -Inherit), (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')) 'FullControl' -Inherit),
            (& $rule (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')) 'FullControl' -Inherit)) }
        $savedState = $env:CLAUDE_GATEWAY_STATE_DIR
        $winPlace = { param([string]$StateDir) $env:CLAUDE_GATEWAY_STATE_DIR = $StateDir
            try { $script:ClaudeInstall = [pscustomobject]@{ Root = (Join-Path $scratch 'checkout'); Location = (Get-ClaudeInstallLocation -Root (Join-Path $scratch 'checkout')); Answers = [ordered]@{} }; Assert-ClaudeInstallStore; 'PASSED' }
            catch { $_.Exception.Message } }
        $target = Join-Path $scratch 'win-target'; New-Item -ItemType Directory -Force -Path $target | Out-Null; & $protect $target (& $trustedRules)
        $reparse = Join-Path $scratch 'win-reparse'; New-Item -ItemType Junction -Path $reparse -Target $target | Out-Null
        $wj = & $winPlace $reparse
        Assert 'pwsh Windows: a state directory that is a junction is refused' ((& $refused $wj 'symbolic link or junction') -and $wj.Contains($reparse)) $wj
        $clean = Join-Path $scratch 'win-clean'; New-Item -ItemType Directory -Force -Path $clean | Out-Null; & $protect $clean (& $trustedRules)
        $inherits = Join-Path $clean 'inherits'; New-Item -ItemType Directory -Force -Path $inherits | Out-Null
        $wi = & $real $inherits 'directory'
        Assert 'pwsh Windows: a state directory whose access rules are inherited, not its own, is refused' (& $refused $wi 'inherits its access rules') $wi
        $deletable = Join-Path $clean 'deletable'; New-Item -ItemType Directory -Force -Path $deletable | Out-Null
        & $protect $deletable @((& $rule $owner 'FullControl' -Inherit), (& $rule $users 'Delete'))
        $wx = & $real $deletable 'directory'
        Assert 'pwsh Windows: a rule that lets Users delete the state directory is refused, naming the rule' (& $refused $wx 'S-1-5-32-545') $wx
        $loose = Join-Path $scratch 'win-loose-parent'; New-Item -ItemType Directory -Force -Path $loose | Out-Null
        & $protect $loose (@(& $trustedRules) + @(& $rule $users 'DeleteSubdirectoriesAndFiles'))
        $looseState = Join-Path $loose 'state'; New-Item -ItemType Directory -Force -Path $looseState | Out-Null; & $protect $looseState @(& $rule $owner 'FullControl' -Inherit)
        $wp = & $real $looseState 'directory'
        Assert 'pwsh Windows: a parent directory that lets Users delete what it holds is refused, naming the parent and the rule' ((& $refused $wp 'S-1-5-32-545') -and $wp.Contains("$loose, which holds")) $wp
        # The owner seam answers for one path; every other path keeps its real owner.
        $script:foreignOwnerPath = ''
        function Get-ClaudeInstallWindowsOwner([string]$Path) {
            if ($Path.TrimEnd('\') -eq $script:foreignOwnerPath) { return 'S-1-5-21-1000-1000-1000-1001' }
            return [string](Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        }
        $script:foreignOwnerPath = $kept.TrimEnd('\'); $wo = & $real $kept 'directory'
        $script:foreignOwnerPath = $scratch.TrimEnd('\'); $wq = & $real $kept 'directory'
        . $psLibrary
        $script:ClaudeInstall = [pscustomobject]@{ Root = (Join-Path $scratch 'checkout'); Location = [pscustomobject]@{ CloudDrive = $false }; Answers = [ordered]@{} }
        Assert 'pwsh Windows: a store path owned by another account than the user, SYSTEM or Administrators is refused, naming the owner (owner seam)' (
            (& $refused $wo 'owned by .*S-1-5-21-1000-1000-1000-1001') -and $wo.Contains("directory $kept is owned by")) $wo
        Assert 'pwsh Windows: a parent directory owned by another account is refused, naming the parent and the owner (owner seam)' (
            (& $refused $wq 'owned by .*S-1-5-21-1000-1000-1000-1001') -and $wq.Contains("$scratch, which holds")) $wq
        $outside = Join-Path ([IO.Path]::GetPathRoot([Environment]::GetFolderPath('UserProfile'))) ('p91-outside-profile-' + [guid]::NewGuid().ToString('N') + '\state')
        $wu = & $winPlace $outside
        Assert 'pwsh Windows: a state directory outside the user profile is refused, naming the profile' ((& $refused $wu 'not inside the user profile') -and $wu.Contains($outside)) $wu
        $env:CLAUDE_GATEWAY_STATE_DIR = $savedState
    }
    else {
        # ------------------------------------------------------------------ Linux and macOS: real modes
        $real = { param([string]$Path, [string]$Kind) try { Assert-ClaudeInstallStorePath -Path $Path -Kind $Kind; 'PASSED' } catch { $_.Exception.Message } }
        $wide = Join-Path $scratch 'mode-0777'; $group = Join-Path $scratch 'mode-0770'; $tight = Join-Path $scratch 'mode-0700'
        foreach ($p in $wide, $group, $tight) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        & chmod 0777 $wide; & chmod 0770 $group; & chmod 0700 $tight
        $loose = Join-Path $tight 'install-1111111111111111.json'; Write-Lf $loose '{}'; & chmod 0666 $loose
        $own = Join-Path $tight 'install-2222222222222222.json'; Write-Lf $own '{}'; & chmod 0600 $own
        $link = Join-Path $tight 'install-3333333333333333.json'; New-Item -ItemType SymbolicLink -Path $link -Target $own | Out-Null
        $results = [ordered]@{ wide = (& $real $wide 'directory'); group = (& $real $group 'directory'); loose = (& $real $loose 'file'); link = (& $real $link 'file'); tight = (& $real $tight 'directory'); own = (& $real $own 'file') }
        Assert 'pwsh POSIX (real modes): 0777 and 0770 directories, a 0666 file and a symbolic link are refused; 0700 and 0600 pass' ((& $refused $results.wide 'drwxrwxrwx') -and
            (& $refused $results.group 'drwxrwx---') -and (& $refused $results.loose '-rw-rw-rw-') -and (& $refused $results.link 'symbolic link') -and $results.tight -eq 'PASSED' -and $results.own -eq 'PASSED') (($results.Values) -join ' || ')
        $bw = Invoke-BashCheck $wide 'directory' ''; $bg = Invoke-BashCheck $group 'directory' ''; $bl = Invoke-BashCheck $loose 'file' ''; $bk = Invoke-BashCheck $link 'file' ''
        $bt = Invoke-BashCheck $tight 'directory' ''; $bo = Invoke-BashCheck $own 'file' ''
        Assert 'bash POSIX (real modes): 0777 and 0770 directories, a 0666 file and a symbolic link are refused; 0700 and 0600 pass' ((Test-Refused $bw 'drwxrwxrwx') -and
            (Test-Refused $bg 'drwxrwx---') -and (Test-Refused $bl '-rw-rw-rw-') -and (Test-Refused $bk 'symbolic link') -and $bt.Passed -and $bo.Passed) (@($bw, $bg, $bl, $bk, $bt, $bo | ForEach-Object { $_.Text }) -join ' || ')

        # Where the store is (decision 2), with real modes and links under a home of the test's own.
        $rhome = Join-Path $scratch 'rhome'; $rwork = Join-Path $rhome 'work'; $rstate = Join-Path $rwork 'state'; $rlink = Join-Path $rhome 'link-state'
        foreach ($p in $rhome, $rwork, $rstate) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
        & chmod 0700 $rhome; & chmod 0775 $rwork; & chmod 0700 $rstate
        New-Item -ItemType SymbolicLink -Path $rlink -Target $rstate | Out-Null
        $savedHome = $env:HOME; $savedState = $env:CLAUDE_GATEWAY_STATE_DIR
        $realPlace = { param([string]$StateDir) $env:HOME = $rhome; $env:CLAUDE_GATEWAY_STATE_DIR = $StateDir
            try { $script:ClaudeInstall = [pscustomobject]@{ Root = (Join-Path $scratch 'checkout'); Location = (Get-ClaudeInstallLocation -Root (Join-Path $scratch 'checkout')); Answers = [ordered]@{} }; Assert-ClaudeInstallStore; 'PASSED' }
            catch { $_.Exception.Message } }
        $pa = & $realPlace $rstate; $pb = & $realPlace $rlink; $pc = & $realPlace (Join-Path $scratch 'elsewhere/state')
        $ba = Invoke-BashPlace $rstate $rhome ''; $bb = Invoke-BashPlace $rlink $rhome ''; $bc = Invoke-BashPlace (Join-Path $scratch 'elsewhere/state') $rhome ''
        & chmod 0755 $rwork
        $pd = & $realPlace $rstate; $bd = Invoke-BashPlace $rstate $rhome ''
        $env:HOME = $savedHome; $env:CLAUDE_GATEWAY_STATE_DIR = $savedState
        Assert 'pwsh POSIX (real modes): a 0775 directory above the state directory, a linked state directory and one outside $HOME are refused; 0755 passes' ((& $refused $pa 'drwxrwxr-x') -and
            (& $refused $pb 'symbolic link') -and (& $refused $pc 'not inside the home directory') -and $pd -eq 'PASSED') "$pa || $pb || $pc || $pd"
        Assert 'bash POSIX (real modes): a 0775 directory above the state directory, a linked state directory and one outside $HOME are refused; 0755 passes' ((Test-Refused $ba 'drwxrwxr-x') -and
            (Test-Refused $bb 'symbolic link') -and (Test-Refused $bc 'not inside the home directory') -and $bd.Passed) (@($ba, $bb, $bc, $bd | ForEach-Object { $_.Text }) -join ' || ')
    }
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
