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

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p91-store-' + [guid]::NewGuid().ToString('N'))
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
        $script:fakeStat = [pscustomobject]@{ Link = $Link; Mine = $Mine; Mode = $Mode; Owner = $Owner }
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
    }
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
