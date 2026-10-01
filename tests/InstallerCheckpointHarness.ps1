# Harness for tests/Test-InstallerCheckpoint.ps1. Each scenario has its own copy of the files the
# installer reads (its checkout, which keys its checkpoint), its own JSON world for the az stub of
# tests/InstallerCheckpointStubs.ps1, and its own CLAUDE_GATEWAY_STATE_DIR. Runs are child
# PowerShell processes, started from the command line so that the installer runs at top level.
$script:P91Root = Split-Path $PSScriptRoot -Parent
$script:P91StubsPath = Join-Path $PSScriptRoot 'InstallerCheckpointStubs.ps1'
$script:P91Pwsh = (Get-Process -Id $PID).Path
$script:P91Subscription = '00000000-0000-4000-8000-0000000000a1'
$script:P91Tenant = '00000000-0000-4000-8000-0000000000f1'

function Write-P91Text([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }

function Get-P91Key([string]$Checkout) {
    # ADR-0046 decision 1, computed here independently of the installer.
    $text = if ($env:OS -eq 'Windows_NT') { $Checkout.ToLowerInvariant() } else { $Checkout }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
    'install-' + $hash.Substring(0, 16)
}

function New-P91Template([string]$Scratch) {
    $template = Join-Path $Scratch 'template'
    foreach ($dir in 'scripts\flow\lib', 'infra', 'config', 'onboarding') { New-Item -ItemType Directory -Force -Path (Join-Path $template $dir) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $script:P91Root 'Install-ClaudeGateway.ps1') -Destination $template
    Get-ChildItem -LiteralPath (Join-Path $script:P91Root 'scripts') -File | Where-Object { $_.Extension -in '.ps1', '.sh' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $template 'scripts') }
    Copy-Item -Path (Join-Path $script:P91Root 'scripts\flow\*.ps1') -Destination (Join-Path $template 'scripts\flow')
    Copy-Item -Path (Join-Path $script:P91Root 'scripts\flow\lib\*.ps1') -Destination (Join-Path $template 'scripts\flow\lib')
    Copy-Item -Path (Join-Path $script:P91Root 'infra\*') -Destination (Join-Path $template 'infra')
    Copy-Item -Path (Join-Path $script:P91Root 'config\*.example.json') -Destination (Join-Path $template 'config')
    # The child scripts the installer runs after its deployment, replaced by stubs that log and fail
    # when the world says so.
    $prelude = '$w = [IO.File]::ReadAllText($env:P91_WORLD) | ConvertFrom-Json' + "`n"
    Write-P91Text (Join-Path $template 'scripts\Sync-ClaudeAccess.ps1') ("param([string]`$ApimName, [string]`$ResourceGroup, [string]`$StandardGroup, [string]`$PremiumGroup)`n" + $prelude +
        "[IO.File]::AppendAllText((Join-Path `$env:P91_LOG 'scripts.log'), `"sync `$ApimName `$StandardGroup `$PremiumGroup``n`")`n" +
        "if (`$w.inject.sync -eq 'graph404') { throw 'Graph read failed: Response status code does not indicate success: 404 (Not Found).' }`n")
    Write-P91Text (Join-Path $template 'scripts\Set-ClaudeBusinessUnit.ps1') ("param([string]`$Id, [string]`$Group, [int]`$MonthlyBudgetUsd, [string]`$ApimName, [string]`$ResourceGroup)`n" + $prelude +
        "[IO.File]::AppendAllText((Join-Path `$env:P91_LOG 'scripts.log'), `"bu `$Id `$Group``n`")`n" +
        "if (`$w.inject.bu -eq 'refuse') { throw `"Business unit '`$Id' was refused by the stub.`" }`n" +
        "`$apim = `$w.apims.`$ApimName; `$apim.namedValues.'bu-registry' = (`$apim.namedValues.'bu-registry'.TrimEnd(',') + `",`$Id=`$Group:1000,`")`n" +
        "[IO.File]::WriteAllText(`$env:P91_WORLD, (`$w | ConvertTo-Json -Depth 30))`n")
    Write-P91Text (Join-Path $template 'scripts\Show-Governance.ps1') ("param([string]`$ApimName, [string]`$ResourceGroup, [switch]`$SkipThrottleTest)`n" +
        "[IO.File]::AppendAllText((Join-Path `$env:P91_LOG 'scripts.log'), `"governance `$ApimName``n`")`n")
    Write-P91Text (Join-Path $template 'scripts\Deploy-ClaudeProjection.ps1') ("[IO.File]::AppendAllText((Join-Path `$env:P91_LOG 'scripts.log'), `"projection``n`")`n")
    return $template
}

function New-P91World {
    param([switch]$ReusedGateway, [string]$IdentityType = 'SystemAssigned')
    $foundryId = "/subscriptions/$($script:P91Subscription)/resourceGroups/rg-ai-p91/providers/Microsoft.CognitiveServices/accounts/ai-p91"
    $deployments = @(foreach ($m in @(@('claude-opus-5', 40), @('claude-sonnet-5', 20))) {
        [ordered]@{ name = $m[0]; sku = [ordered]@{ name = 'GlobalStandard'; capacity = $m[1] }; properties = [ordered]@{ provisioningState = 'Succeeded'; model = [ordered]@{ format = 'Anthropic'; name = $m[0]; version = '2' } } }
    })
    $world = [ordered]@{
        tenantId = $script:P91Tenant; subscriptionId = $script:P91Subscription; subscriptionName = 'p91-subscription'
        # A JWT-shaped value: the checkpoint must never hold it (S10).
        token = 'eyJhbGciOiJub25lIn0.eyJQOTEiOiJUT0tFTi1TRU5USU5FTCJ9.c2lnbmF0dXJl'
        foundry = [ordered]@{ name = 'ai-p91'; rg = 'rg-ai-p91'; location = 'eastus2'; id = $foundryId; deployments = $deployments }
        resourceGroups = [ordered]@{ 'rg-ai-p91' = 'eastus2' }
        apims = [ordered]@{}; deployments = [ordered]@{}; groups = [ordered]@{}; roleAssignments = [ordered]@{}
        inject = [ordered]@{ createMode = 'ok'; sync = ''; bu = ''; readErrors = @(); runningPolls = @(); groupCreateFail = @() }
    }
    if ($ReusedGateway) {
        $world.resourceGroups['rg-p91'] = 'eastus2'
        $world.apims['apim-p91reuse'] = [ordered]@{ rg = 'rg-p91'; sku = 'StandardV2'; location = 'East US 2'; publisherEmail = 'ops@contoso.com'; identity = $IdentityType
            principalId = '00000000-0000-4000-8000-0000000000c2'; apis = @()
            namedValues = [ordered]@{ 'entitlement-cache-seconds' = '900'; 'allow-standard' = ',00000000-0000-4000-8000-0000000000d1,'; 'allow-premium' = ',,'; 'quota-overrides' = ',,'; 'bu-registry' = ',,'; 'bu-members' = ',,'; 'bu-parents' = ',,'; 'bu-modes' = ',,' } }
    }
    return $world
}

function Protect-P91Directory([string]$Path, [string[]]$AlsoWritableBy = @()) {
    # Owner-only, as the installer creates a state directory (ADR-0046 decision 2): a copied state
    # directory would otherwise inherit its parent's rules, and the installer refuses a store that
    # another account can write. -AlsoWritableBy adds Modify rules for other SIDs. .NET writes the
    # access section only; Set-Acl also writes the audit rules, which needs SeSecurityPrivilege.
    if ($env:OS -eq 'Windows_NT') {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        foreach ($sid in $AlsoWritableBy) { $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))) }
        [System.IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $acl)
    }
    else { & chmod 700 $Path }
}

function Add-P91FileWriter([string]$Path, [string]$Sid) {
    # An explicit Write rule for another SID beside the file's inherited rules; .NET writes the access
    # section only, where Set-Acl on a file also writes the audit rules (SeSecurityPrivilege).
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($Sid)), 'Write', 'Allow')))
    [System.IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($Path), $acl)
}

function New-P91Scenario {
    # A fresh scenario from the template, or a copy of another scenario's checkout, world and state.
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Scratch, [string]$Template, $World, $From)
    $dir = Join-Path $Scratch "scenarios\$Name"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $s = [pscustomobject]@{ Name = $Name; Dir = $dir; Repo = (Join-Path $dir 'repo'); State = (Join-Path $dir 'state'); World = (Join-Path $dir 'world.json'); Runs = 0 }
    if ($From) {
        Copy-Item -LiteralPath $From.Repo -Destination $s.Repo -Recurse
        Copy-Item -LiteralPath $From.World -Destination $s.World
        New-Item -ItemType Directory -Force -Path $s.State | Out-Null
        Protect-P91Directory $s.State
        # The checkpoint is keyed by its checkout, so a copy is renamed for the new checkout.
        foreach ($f in @(Get-ChildItem -LiteralPath $From.State -File -ErrorAction SilentlyContinue)) {
            $target = $f.Name -replace '^install-[0-9a-f]{16}', (Get-P91Key $s.Repo)
            if ($f.Name -notmatch '\.lock') { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $s.State $target) }
        }
    }
    else {
        Copy-Item -LiteralPath $Template -Destination $s.Repo -Recurse
        Write-P91Text $s.World (($World | ConvertTo-Json -Depth 30))
    }
    return $s
}

function Edit-P91World($Scenario, [scriptblock]$Change) {
    $w = [IO.File]::ReadAllText($Scenario.World) | ConvertFrom-Json
    & $Change $w
    Write-P91Text $Scenario.World ($w | ConvertTo-Json -Depth 30)
}

function Get-P91CheckpointFile($Scenario, [string]$State) {
    $dir = if ($State) { $State } else { $Scenario.State }
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    @(Get-ChildItem -LiteralPath $dir -Filter 'install-*.json' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.tmp-|\.discarded-' }) | Select-Object -First 1
}

function New-P91Run {
    param($Scenario, [string[]]$Arguments = @(), [string[]]$Answers = @(), [hashtable]$Environment = @{}, [switch]$Attended, [string]$Command)
    $Scenario.Runs++
    $logs = Join-Path $Scenario.Dir ("run{0}" -f $Scenario.Runs)
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $installer = Join-Path $Scenario.Repo 'Install-ClaudeGateway.ps1'
    $body = if ($Command) { $Command } else { "& '$installer' $($Arguments -join ' ')" }
    $text = ". '$($script:P91StubsPath)' -World '$($Scenario.World)' -Log '$logs'; `$global:LASTEXITCODE = 0; $body; if (-not `$?) { exit 1 }; exit 0"
    $envs = [ordered]@{ P91_WORLD = $Scenario.World; P91_LOG = $logs; CLAUDE_GATEWAY_STATE_DIR = $Scenario.State; CLAUDE_GATEWAY_DEPLOY_POLL_SECONDS = '0'; CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS = '30' }
    if ($Attended) { $envs['CLAUDE_INTERACTIVE'] = '1' }
    foreach ($k in $Environment.Keys) { $envs[$k] = $Environment[$k] }
    [pscustomobject]@{ Scenario = $Scenario; Logs = $logs; Text = $text; Env = $envs; Answers = $Answers; Attended = [bool]$Attended }
}

function Invoke-P91Runs([object[]]$Runs, [int]$Parallel = 6, [int]$TimeoutSeconds = 240) {
    $results = @{}
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($r in $Runs) { $queue.Enqueue($r) }
    $active = [System.Collections.Generic.List[object]]::new()
    while ($queue.Count -or $active.Count) {
        while ($queue.Count -and $active.Count -lt $Parallel) {
            $r = $queue.Dequeue()
            $psi = [Diagnostics.ProcessStartInfo]::new($script:P91Pwsh)
            foreach ($arg in @('-NoProfile') + $(if (-not $r.Attended) { @('-NonInteractive') } else { @() }) + @('-Command', $r.Text)) { $psi.ArgumentList.Add($arg) }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            foreach ($name in @($psi.Environment.Keys | Where-Object { $_ -like 'P91_*' -or $_ -like 'CLAUDE_*' -or $_ -in 'CI', 'TF_BUILD', 'GITHUB_ACTIONS', 'AZUREPS_HOST_ENVIRONMENT', 'ACC_CLOUD' })) { [void]$psi.Environment.Remove($name) }
            foreach ($k in $r.Env.Keys) { if ($null -eq $r.Env[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = [string]$r.Env[$k] } }
            $p = [Diagnostics.Process]::Start($psi)
            $p.StandardInput.Write((@($r.Answers) -join "`n") + "`n")
            $p.StandardInput.Close()
            $active.Add([pscustomobject]@{ Run = $r; Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Clock = [Diagnostics.Stopwatch]::StartNew() })
        }
        foreach ($s in @($active)) {
            $timedOut = $s.Clock.Elapsed.TotalSeconds -gt $TimeoutSeconds
            if (-not $s.Process.HasExited -and -not $timedOut) { continue }
            if ($timedOut -and -not $s.Process.HasExited) { try { $s.Process.Kill($true) } catch { } }
            $s.Process.WaitForExit()
            $out = if ($s.Out.Wait(5000)) { $s.Out.Result } else { '' }
            $err = if ($s.Err.Wait(5000)) { $s.Err.Result } else { '' }
            $read = { param($n) $f = Join-Path $s.Run.Logs $n; if (Test-Path -LiteralPath $f) { @(Get-Content -LiteralPath $f | Where-Object { $_ }) } else { @() } }
            $results[$s.Run.Logs] = [pscustomobject]@{
                Run = $s.Run; ExitCode = $(if ($timedOut) { -1 } else { $s.Process.ExitCode }); TimedOut = $timedOut; Seconds = [math]::Round($s.Clock.Elapsed.TotalSeconds, 1)
                Out = (($out -replace "`e\[[0-9;]*m", '').Replace("`r", '')); Err = (($err -replace "`e\[[0-9;]*m", '').Replace("`r", ''))
                Az = (& $read 'az.log'); Scripts = (& $read 'scripts.log'); Unexpected = (& $read 'unexpected.log'); Snapshots = (& $read 'snapshots.log')
            }
            [void]$active.Remove($s)
        }
        Start-Sleep -Milliseconds 100
    }
    return $results
}

function Get-P91Result($Results, $Run) { $Results[$Run.Logs] }
function Get-P91Calls($Result, [string]$Pattern) { @($Result.Az | Where-Object { $_ -like $Pattern }) }
function Get-P91ErrLines($Result) { @($Result.Err -split "`n" | Where-Object { $_.Trim() }) }
function Get-P91Tail($Result) { ((@(($Result.Out + "`n" + $Result.Err) -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 4) -join ' | ') }
function Get-P91Hash([string]$Path) { if ($Path -and (Test-Path -LiteralPath $Path)) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { '' } }
