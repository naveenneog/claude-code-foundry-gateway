# Install checkpoint and resume for Install-ClaudeGateway.ps1 (docs/adr/0046-installer-checkpoint-and-resume.md).
# Dot-sourced by the installer, so these functions read its script variables. The checkpoint says
# where a rerun resumes; Azure says whether a step is done: a completed step is skipped only when a
# live read shows its result. Runs on Windows PowerShell 5.1 and PowerShell 7.

$script:ClaudeInstallSchema = 'claude-gateway-install-checkpoint'
# Step ids are a stable contract: renaming or removing one needs a schemaVersion bump (ADR-0046).
$script:ClaudeInstallSteps = [ordered]@{
    'claude-deployment' = 'Claude deployment'; 'resource-group' = 'Resource group'; 'gateway-deployment' = 'Gateway deployment'
    'company-address' = 'Company address'; 'entra-groups' = 'Entra groups'; 'sync' = 'Sync entitlement'; 'projection' = 'Projection deployment'
    'business-units' = 'Business units'; 'onboarding-package' = 'Onboarding package'; 'verify' = 'Verification'
}
$script:ClaudeInstallParameterAnswers = @('SubscriptionId', 'FoundryAccount', 'FoundryResourceGroup', 'ResourceGroup', 'Location', 'NamePrefix', 'PublisherEmail', 'Sku', 'DeveloperCount',
    'AddressMode', 'AddressHostname', 'AddressCertificateSource', 'AddressKeyVaultCertificateId', 'AddressPfxPath', 'AddressDnsZoneResourceId', 'AddressDnsMode',
    'AddressReplaceHostname', 'ExistingApimName', 'EntitlementStore', 'ResolverInboundAccess', 'DeployProjection', 'DeploySyncJob', 'ProjectionSyncInterval', 'ProjectionResolverAppId',
    'TpmStandard', 'QuotaStandard', 'TpmPremium', 'QuotaPremium', 'QuotaOrg', 'CallsPerMinute', 'StandardGroup', 'PremiumGroup', 'StandardModels', 'PremiumModels',
    'AuthMode', 'DesktopSignInKind', 'DesktopBearerTokenType', 'DesktopEntraClientId', 'DesktopEntraIssuer', 'DesktopEntraScopes', 'DesktopEntraAudience',
    'DesktopEntraResource', 'DeployContentSafety', 'ContentSafetyMode', 'ModelOrganizationName', 'ModelIndustry', 'ModelCountryCode')
$script:ClaudeInstallPromptAnswers = @('RevocationWindowSeconds', 'TeamBudgetBehaviour', 'UnassignedDevelopers', 'DeveloperEstimate', 'PendingClaudeDeployment', 'BusinessUnits')
$script:ClaudeInstallChoices = @{
    Sku = 'BasicV2', 'StandardV2', 'PremiumV2'; AddressMode = 'azure', 'custom'; AddressCertificateSource = 'KeyVault', 'Pfx'; AddressDnsMode = 'AzureDns', 'External'
    EntitlementStore = 'named-value', 'projection'; ResolverInboundAccess = 'private', 'public'; AuthMode = 'interactive', 'device', 'helper'
    DesktopSignInKind = 'helper-script', 'external-idp-browser', 'external-idp-broker'; DesktopBearerTokenType = 'id_token', 'access_token'
    TeamBudgetBehaviour = 'report', 'stop'; UnassignedDevelopers = 'allow', 'deny'
}
$script:ClaudeInstallIntegers = @('TpmStandard', 'QuotaStandard', 'TpmPremium', 'QuotaPremium', 'QuotaOrg', 'CallsPerMinute', 'RevocationWindowSeconds', 'DeveloperEstimate')
# Answers that Azure CLI places inside an OData string literal without escaping a quote: az ad group
# list --display-name sends startswith(displayName,'<name>') for the tier groups, and az ad app list
# --display-name sends it for claude-projection-resolver-<NamePrefix> (azure-cli 2.86.0
# role/custom.py:757,1904).
$script:ClaudeInstallODataAnswers = @('StandardGroup', 'PremiumGroup', 'NamePrefix')
$script:ClaudeInstallTerminal = @('Succeeded', 'Failed', 'Canceled')
# The files whose hash is the installer version a checkpoint records (shown, not refused: amendment 1).
$script:ClaudeInstallFiles = @('Install-ClaudeGateway.ps1', 'scripts/ClaudeInstallCheckpoint.ps1', 'scripts/ClaudeInstallStore.ps1', 'scripts/ClaudeInstallResume.ps1')
$script:ClaudeInstall = $null

# Test-ClaudeInstallWindows and Test-ClaudeInstallCmdText are in ClaudeInstallResume.ps1, which the preflight loads as well.

function Stop-ClaudeInstall {
    # A refusal is one line: PowerShell's error view would wrap a long one at the console width. A secret that
    # an error it quotes holds is replaced (Protect-ClaudeInstallText, ADR-0047 decision 12).
    param([Parameter(Mandatory = $true)][string]$Message)
    $text = ($Message -replace '\s*[\r\n]+\s*', ' ').Trim()
    if (Get-Command Protect-ClaudeInstallText -ErrorAction SilentlyContinue) { $text = Protect-ClaudeInstallText $text }
    throw ('Refused: ' + $text)
}

function Get-ClaudeInstallSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

function Get-ClaudeInstallFileHash {
    # Each file hashed with CRLF read as LF, so a Windows and a Linux checkout of one commit agree.
    param([string]$Root, [string[]]$Paths)
    [string[]]$sorted = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Select-Object -Unique)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $lines = foreach ($p in $sorted) {
        $full = Join-Path $Root $p
        $text = if (Test-Path -LiteralPath $full) { [IO.File]::ReadAllText($full).Replace("`r`n", "`n") } else { '<missing>' }
        $p + "`t" + (Get-ClaudeInstallSha256 ([Text.Encoding]::UTF8.GetBytes($text)))
    }
    return ('sha256:' + (Get-ClaudeInstallSha256 ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))))
}

function Get-ClaudeInstallTemplateFiles {
    # A template and every file it references through module declarations and load*() calls,
    # recursively, so a changed module or policy changes the deployment step's input (ADR-0046).
    param([string]$Root, [string]$Template)
    $found = [System.Collections.Generic.List[string]]::new()
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Template.Replace('\', '/'))
    while ($queue.Count) {
        $rel = $queue.Dequeue()
        if ($found.Contains($rel)) { continue }
        $found.Add($rel)
        $full = Join-Path $Root $rel
        if ($rel -notmatch '\.bicep$' -or -not (Test-Path -LiteralPath $full)) { continue }
        $dir = [IO.Path]::GetDirectoryName($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $text = [IO.File]::ReadAllText($full)
        foreach ($m in [regex]::Matches($text, "(?m)^\s*module\s+\S+\s+'([^']+)'|load(?:Text|Json)Content\(\s*'([^']+)'|loadFileAsBase64\(\s*'([^']+)'")) {
            $ref = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value | Where-Object { $_ })[0]
            if ($ref -match '^[a-z]+:') { continue }
            $combined = [IO.Path]::GetFullPath((Join-Path (Join-Path $Root $dir) $ref))
            $queue.Enqueue($combined.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\', '/').Length + 1).Replace('\', '/'))
        }
    }
    return @($found)
}

function Move-ClaudeInstallCheckpointFile {
    # The rename that publishes a write; File.Replace is atomic where File.Move cannot overwrite.
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($Source, $Destination, [NullString]::Value) } else { [IO.File]::Move($Source, $Destination) }
}

function Write-ClaudeInstallCheckpoint {
    param([Parameter(Mandatory = $true)]$Checkpoint, [Parameter(Mandatory = $true)][string]$Path)
    $temp = "$Path.tmp-" + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temp, ($Checkpoint | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        if (-not (Test-ClaudeInstallWindows)) { Set-ClaudeInstallOwnerOnly $temp }
        Assert-ClaudeInstallStorePath -Path $temp -Kind file -Tail "The checkpoint was not replaced, and the run stops here.$(if ($script:ClaudeInstall -and $script:ClaudeInstall.Root) { " Resume: $(Format-ClaudeInstallResume)" })"
        Move-ClaudeInstallCheckpointFile -Source $temp -Destination $Path
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function ConvertTo-ClaudeInstallText($Value) {
    # PowerShell 7 reads an ISO time in JSON as a DateTime; the checkpoint keeps it as text.
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function ConvertTo-ClaudeInstallPlain($Value) {
    if ($Value -is [DateTime]) { return (ConvertTo-ClaudeInstallText $Value) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $copy[$p.Name] = ConvertTo-ClaudeInstallPlain $p.Value }
        return [pscustomobject]$copy
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return ,@($Value | ForEach-Object { ConvertTo-ClaudeInstallPlain $_ }) }
    return $Value
}

function Test-ClaudeInstallAnswerText([string]$Text) {
    # Control characters, az's @file syntax, and on Windows what Assert-AzArgumentsSafe refuses.
    if ($Text -match '[\x00-\x1f]') { return 'holds a control character' }
    if ($Text.StartsWith('@')) { return 'begins with @, which az reads as a file name' }
    $cmd = Test-ClaudeInstallCmdText $Text; if ($cmd) { return $cmd }
    return ''
}

function Test-ClaudeInstallAnswer {
    # '' when the installer accepts the recorded value, otherwise why it does not.
    param([string]$Name, $Value)
    if ($Name -notin ($script:ClaudeInstallParameterAnswers + $script:ClaudeInstallPromptAnswers)) { return 'is not an answer the installer records' }
    if ($Name -eq 'PendingClaudeDeployment') {
        if ($Value -isnot [System.Management.Automation.PSCustomObject]) { return 'is not an object' }
        foreach ($p in $Value.PSObject.Properties) {
            if ($p.Name -notin 'name', 'model', 'version', 'sku', 'capacity', 'account', 'resourceGroup') { return "holds '$($p.Name)'" }
            $why = Test-ClaudeInstallAnswerText ([string]$p.Value); if ($why) { return $why }
        }
        return ''
    }
    if ($Name -eq 'BusinessUnits') {
        # Units reach az as group names and Set-ClaudeBusinessUnit.ps1 arguments (ADR-0047).
        foreach ($u in @($Value)) {
            if ($u -isnot [System.Management.Automation.PSCustomObject]) { return 'holds a unit that is not an object' }
            foreach ($p in $u.PSObject.Properties) {
                if ($p.Name -cnotin 'id', 'group', 'parent', 'monthlyUsdBudget', 'mode', 'percent') { return "holds a unit with '$($p.Name)'" }
                if ($p.Name -in 'monthlyUsdBudget', 'percent') { if ("$($p.Value)" -notmatch '^\d{1,9}(\.\d{1,6})?$') { return "holds a unit whose $($p.Name) is not a number" }; continue }
                $why = Test-ClaudeInstallAnswerText ([string]$p.Value); if ($why) { return $why }
            }
            if ([string]$u.id -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or [string]$u.group -match "[',:]" -or [string]$u.mode -cnotin 'Strict', 'Allowance', 'Notify') { return "holds the unit $(ConvertTo-Json -InputObject ([string]$u.id) -Compress) with group $(ConvertTo-Json -InputObject ([string]$u.group) -Compress) and mode $(ConvertTo-Json -InputObject ([string]$u.mode) -Compress)" }
        }
        return ''
    }
    if ($Name -in $script:ClaudeInstallIntegers) { if ("$Value" -notmatch '^\d{1,12}$') { return 'is not a whole number' }; return '' }
    if ($Name -eq 'DeployProjection') { if ($Value -isnot [bool]) { return 'is not true or false' }; return '' }
    if ($Name -eq 'SubscriptionId' -and "$Value" -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return 'is not a subscription id' }
    # An app id reaches az ad app show --id, which places a value that is not a GUID inside an OData
    # string literal, identifierUris/any(s:s eq '<id>') (azure-cli 2.86.0 role/custom.py:784).
    if ($Name -in 'DesktopEntraClientId', 'ProjectionResolverAppId' -and "$Value" -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return 'is not an application (client) id GUID' }
    foreach ($item in @($Value)) {
        if ($item -isnot [string]) { return 'is not text' }
        $why = Test-ClaudeInstallAnswerText $item; if ($why) { return $why }
        if ($Name -in $script:ClaudeInstallODataAnswers -and $item.Contains("'")) { return 'holds a single quote, which Azure CLI would place inside an OData string literal' }
        if ($script:ClaudeInstallChoices.ContainsKey($Name) -and $item -notin $script:ClaudeInstallChoices[$Name]) { return "is not one of $($script:ClaudeInstallChoices[$Name] -join ', ')" }
    }
    return ''
}

function Test-ClaudeInstallReceipt {
    # '' when a step's receipt holds only values of the shape the installer writes. A receipt value
    # reaches az as an argument on a resume, so any other value makes the checkpoint corrupt (R5).
    param([string]$Id, $Receipt)
    if ($null -eq $Receipt) { return '' }
    if ($Receipt -isnot [System.Management.Automation.PSCustomObject]) { return 'is not an object' }
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $guidPart = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    $show = { param($v) ConvertTo-Json -InputObject ([string]$v) -Compress }
    $bad = { param($v, [string]$Pattern) [string]$v -cnotmatch $Pattern -or [bool](Test-ClaudeInstallAnswerText ([string]$v)) }
    $origin = { param($v) $null -ne $v -and [string]$v -notin 'created', 'pre-existing' }
    $name = '^[A-Za-z0-9._()-]{1,90}$'
    $r = $Receipt
    switch ($Id) {
        'claude-deployment' {
            foreach ($p in 'account', 'resourceGroup', 'name') { if (& $bad $r.$p $name) { return "names the $p $(& $show $r.$p)" } }
            if (& $origin $r.origin) { return "has the origin $(& $show $r.origin)" }
        }
        'resource-group' {
            if (& $bad $r.name $name) { return "names the resource group $(& $show $r.name)" }
            if ($r.location -and (& $bad $r.location '^[a-z0-9]+$')) { return "names the location $(& $show $r.location)" }
            if (& $origin $r.origin) { return "has the origin $(& $show $r.origin)" }
        }
        'gateway-deployment' {
            foreach ($d in @($r.deployments | Where-Object { $null -ne $_ })) {
                if (& $bad $d.name '^claude-(gw|gateway)-[A-Za-z0-9-]+$') { return "names the deployment $(& $show $d.name)" }
            }
            if ($r.apimName -and (& $bad $r.apimName '^[A-Za-z][A-Za-z0-9-]{0,49}$')) { return "names the gateway $(& $show $r.apimName)" }
            if ($r.gatewayUrl -and (& $bad $r.gatewayUrl '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$')) { return "holds the gateway URL $(& $show $r.gatewayUrl)" }
            if ($r.roleAssignmentId -and (& $bad $r.roleAssignmentId "^/subscriptions/$guidPart(/[^/\s]+/[^/\s]+)*/providers/Microsoft\.Authorization/roleAssignments/$guidPart$")) { return "holds the role assignment id $(& $show $r.roleAssignmentId)" }
            if ($r.desktopClientId -and (& $bad $r.desktopClientId $guid)) { return "holds the Desktop client id $(& $show $r.desktopClientId)" }
            foreach ($p in 'origin', 'roleOrigin') { if (& $origin $r.$p) { return "has the $p $(& $show $r.$p)" } }
        }
        'company-address' { if ($r.hostname -and (& $bad $r.hostname '^[A-Za-z0-9.-]{1,253}$')) { return "names the hostname $(& $show $r.hostname)" } }
        'entra-groups' {
            foreach ($g in @($r.groups | Where-Object { $null -ne $_ })) {
                if (& $bad $g.id $guid) { return "holds the group id $(& $show $g.id)" }
                if ([string]$g.role -notin 'standard', 'premium' -or (& $origin $g.origin) -or (Test-ClaudeInstallAnswerText ([string]$g.displayName))) { return "holds the group $(& $show $g.displayName) with role $(& $show $g.role) and origin $(& $show $g.origin)" }
            }
        }
        'business-units' {
            foreach ($u in @($r.units | Where-Object { $null -ne $_ })) {
                if (& $bad $u.id '^[a-z0-9][a-z0-9-]*$') { return "names the business unit $(& $show $u.id)" }
                if (& $bad $u.groupId $guid) { return "holds the group id $(& $show $u.groupId)" }
                if (& $origin $u.groupOrigin) { return "has the group origin $(& $show $u.groupOrigin)" }
                if ($u.inputHash -and [string]$u.inputHash -cnotmatch '^sha256:[0-9a-f]{64}$') { return "holds the input hash $(& $show $u.inputHash)" }
            }
        }
        'projection' {
            if ($r.resolverAppId -and (& $bad $r.resolverAppId $guid)) { return "holds the resolver app id $(& $show $r.resolverAppId)" }
            if ($r.resolverAppId -and (& $origin $r.resolverOrigin)) { return "has the resolver origin $(& $show $r.resolverOrigin)" }
        }
        'onboarding-package' { if ([string]$r.path -match '[\x00-\x1f]') { return "holds the path $(& $show $r.path)" } }
    }
    return ''
}

function Read-ClaudeInstallCheckpoint {
    # The checkpoint, or $null when there is none. A file the installer cannot trust is refused and
    # kept as it is (ADR-0046 decision 2).
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Restart)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $tail = ". Nothing was changed. To discard it and start again: $Restart"
    $cp = $null
    try { $cp = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop } catch { Stop-ClaudeInstall "the install checkpoint $Path is not valid JSON ($($_.Exception.Message))$tail" }
    if ($cp -isnot [System.Management.Automation.PSCustomObject]) { Stop-ClaudeInstall "the install checkpoint $Path is not valid JSON (no object)$tail" }
    $cp = ConvertTo-ClaudeInstallPlain $cp
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $why = ''
    if ($cp.schema -ne $script:ClaudeInstallSchema) { $why = "has schema '$($cp.schema)', not $($script:ClaudeInstallSchema)" }
    elseif ("$($cp.schemaVersion)" -ne '1') { $why = "has schemaVersion $($cp.schemaVersion), and this installer reads schemaVersion 1" }
    elseif ("$($cp.runId)" -notmatch '^[0-9a-f]{32}$') { $why = 'has no valid runId' }
    elseif ($cp.installer -notin 'pwsh', 'bash') { $why = "names the installer '$($cp.installer)'" }
    elseif (-not $cp.binding -or "$($cp.binding.tenantId)" -notmatch $guid -or "$($cp.binding.subscriptionId)" -notmatch $guid -or -not $cp.binding.resourceGroup -or -not $cp.binding.apimName) { $why = 'has an incomplete binding' }
    elseif ($cp.answers -isnot [System.Management.Automation.PSCustomObject]) { $why = 'has no answers' }
    if (-not $why) {
        foreach ($p in $cp.answers.PSObject.Properties) { $reason = Test-ClaudeInstallAnswer $p.Name $p.Value; if ($reason) { $why = "holds the answer $($p.Name), which $reason"; break } }
    }
    if (-not $why) {
        foreach ($s in @($cp.steps | Where-Object { $null -ne $_ })) {
            if (-not $script:ClaudeInstallSteps.Contains([string]$s.id)) { $why = "holds an unknown step id '$($s.id)'"; break }
            if ($s.state -notin 'started', 'completed', 'incomplete') { $why = "holds the step $($s.id) in state '$($s.state)'"; break }
            $reason = Test-ClaudeInstallReceipt ([string]$s.id) $s.receipt
            if ($reason) { $why = "holds a receipt of step $($s.id) that $reason"; break }
        }
    }
    if ($why) { Stop-ClaudeInstall "the install checkpoint $Path $why$tail" }
    return $cp
}

function Format-ClaudeInstallResume {
    # The command that resumes this run. -WithAnswers adds every recorded parameter answer, and the
    # answers file the run read, for a checkpoint that does not persist (ADR-0046 decision 14).
    param([switch]$WithAnswers)
    $c = $script:ClaudeInstall
    $quote = { param($v) "'" + ([string]$v).Replace("'", "''") + "'" }
    $line = "Set-Location -LiteralPath $(& $quote $c.Root); ./Install-ClaudeGateway.ps1"
    if ($WithAnswers -and $c.AnswersPath) { $line += " -AnswersPath $(& $quote $c.AnswersPath)" }
    if ($WithAnswers) {
        foreach ($n in $script:ClaudeInstallParameterAnswers) {
            if (-not $c.Answers.Contains($n)) { continue }
            $v = $c.Answers[$n]
            if ($v -is [bool]) { if ($v) { $line += " -$n" }; continue }
            if ($n -in $script:ClaudeInstallIntegers) { $line += " -$n $v"; continue }
            $joined = (@($v) | ForEach-Object { & $quote $_ }) -join ','
            $line += " -$n $joined"
        }
    }
    return $line
}

function Get-ClaudeInstallHostName {
    $name = [Environment]::MachineName
    if (-not (Test-ClaudeInstallWindows)) { try { $u = & uname -n 2>$null; if ($u) { $name = [string]$u } } catch { } }
    return (($name.Trim().ToLowerInvariant()) -split '\.')[0]
}

function Get-ClaudeInstallProcessStart([int]$ProcessId) {
    # Windows reuses process ids under churn, so a lock names its holder by id and start time; both
    # installers read the start with ps on Linux, macOS and Cloud Shell (U72).
    try {
        if (Test-ClaudeInstallWindows) { return (ConvertTo-ClaudeInstallText (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime) }
        return ([string](& env LC_ALL=C TZ=UTC ps -o lstart= -p $ProcessId 2>$null)).Trim()
    }
    catch { return '' }
}

function Get-ClaudeInstallLockState {
    # free, held or stale, who holds it, and when a later run may take it over (ADR-0046 decision 3).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ State = 'free'; Detail = ''; Holder = ''; Ends = '' } }
    $age = ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($Path)).TotalMinutes
    $heartbeat = 'a later run takes it over after 5 minutes without a heartbeat'
    $holder = $null
    try { $holder = ConvertTo-ClaudeInstallPlain ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop) } catch { $holder = $null }
    if (-not $holder -or -not $holder.pid -or -not $holder.host) {
        $unreadable = "its lock is unreadable, written {0:N0} minute(s) ago" -f $age
        return [pscustomobject]@{ State = $(if ($age -lt 5) { 'held' } else { 'stale' }); Detail = ("an unreadable lock written {0:N0} minute(s) ago" -f $age); Holder = $unreadable; Ends = $heartbeat }
    }
    $detail = "host $($holder.host), PID $($holder.pid), started $($holder.processStart)"
    if ([string]$holder.host -ne (Get-ClaudeInstallHostName)) {
        $beat = "{0}, last heartbeat {1:N0} minute(s) ago" -f $detail, $age
        return [pscustomobject]@{ State = $(if ($age -lt 5) { 'held' } else { 'stale' }); Detail = $beat; Holder = $beat; Ends = $heartbeat }
    }
    if (-not (Get-Process -Id ([int]$holder.pid) -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ State = 'stale'; Detail = "$detail, which has exited"; Holder = $detail; Ends = '' } }
    $start = Get-ClaudeInstallProcessStart ([int]$holder.pid)
    if ($start -and $holder.processStart -and $start -ne [string]$holder.processStart) { return [pscustomobject]@{ State = 'stale'; Detail = "$detail; that id now names a process started $start"; Holder = $detail; Ends = '' } }
    return [pscustomobject]@{ State = 'held'; Detail = $detail; Holder = $detail; Ends = 'a later run takes it over once that process has exited' }
}

function Stop-ClaudeInstallLockHeld($Lock, [string]$Path) {
    Stop-ClaudeInstall "another install run ($($Lock.Holder)) holds the lock $Path; nothing was changed. The lock ends with that run: $($Lock.Ends). Resume: $(Format-ClaudeInstallResume)"
}

function Enter-ClaudeInstallLock {
    param([string]$Path, [string]$RunId)
    $fields = [ordered]@{ pid = $PID; processStart = (Get-ClaudeInstallProcessStart $PID); host = (Get-ClaudeInstallHostName); installer = 'pwsh'; runId = $RunId
        acquiredUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $stream = $null
        try { $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
        catch {
            if (-not (Test-Path -LiteralPath $Path)) { throw }
            Assert-ClaudeInstallStorePath -Path $Path -Kind file
            $lock = Get-ClaudeInstallLockState $Path
            if ($lock.State -eq 'held') { Stop-ClaudeInstallLockHeld $lock $Path }
            Write-Host "    Taking over a stale lock: $($lock.Detail)." -ForegroundColor Yellow
            try { Move-Item -LiteralPath $Path -Destination "$Path.stale-$RunId-$attempt" -Force -ErrorAction Stop } catch { }
            continue
        }
        try { $bytes = [Text.Encoding]::UTF8.GetBytes(($fields | ConvertTo-Json -Compress)); $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        if (-not (Test-ClaudeInstallWindows)) { Set-ClaudeInstallOwnerOnly $Path }
        # The heartbeat lets another host tell a live run from a closed Cloud Shell session.
        $beat = [powershell]::Create()
        [void]$beat.AddScript('param($p) while ($true) { Start-Sleep -Seconds 60; try { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow) } catch { } }').AddArgument($Path)
        $handle = $beat.BeginInvoke()
        return [pscustomobject]@{ Path = $Path; RunId = $RunId; Heartbeat = $beat; Handle = $handle }
    }
    Stop-ClaudeInstall "the lock $Path could not be taken. Nothing was changed."
}

function Exit-ClaudeInstallLock {
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Lock) { return }
    $lock = $c.Lock
    $c.Lock = $null
    try { $lock.Heartbeat.Stop(); $lock.Heartbeat.Dispose() } catch { }
    try { if ((([IO.File]::ReadAllText($lock.Path)) | ConvertFrom-Json).runId -eq $lock.RunId) { Remove-Item -LiteralPath $lock.Path -Force } } catch { }
}

function Test-ClaudeInstallResuming { return [bool]($script:ClaudeInstall -and $script:ClaudeInstall.Resuming) }
function Get-ClaudeInstallAnswer([string]$Name) {
    $c = $script:ClaudeInstall
    if ($c -and $c.Resuming -and $c.Answers.Contains($Name)) { return $c.Answers[$Name] }
    return $null
}
function Get-ClaudeInstallStep([string]$Id) {
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Checkpoint) { return $null }
    return @($c.Checkpoint.steps | Where-Object { $null -ne $_ -and $_.id -eq $Id })[0]
}
function Get-ClaudeInstallResumeTitle {
    $c = $script:ClaudeInstall
    $steps = @($c.Checkpoint.steps | Where-Object { $null -ne $_ })
    $open = @($steps | Where-Object { $_.state -ne 'completed' })[0]
    if ($open) { return $script:ClaudeInstallSteps[[string]$open.id] }
    $ids = @($script:ClaudeInstallSteps.Keys)
    $last = if ($steps.Count) { [array]::IndexOf($ids, [string]$steps[-1].id) } else { -1 }
    return $script:ClaudeInstallSteps[$ids[[math]::Min($last + 1, $ids.Count - 1)]]
}
function Stop-ClaudeInstallBinding([string]$Field, [string]$Recorded, [string]$Current) {
    $c = $script:ClaudeInstall
    Stop-ClaudeInstall "the install checkpoint $($c.Location.Checkpoint) is bound to $Field '$Recorded', and this run names '$Current'. Nothing was changed. To discard the checkpoint and start again: $(Format-ClaudeInstallResume) -Restart"
}

function Get-ClaudeInstallVersion {
    # The installer's commit and the hash of its files, read once, on a resume or at the commit point.
    $c = $script:ClaudeInstall
    if (-not $c.Fingerprint) {
        $c.Fingerprint = Get-ClaudeInstallFileHash -Root $c.Root -Paths $script:ClaudeInstallFiles
        if (Get-Command Get-ClaudeFlowReleaseInfo -ErrorAction SilentlyContinue) { $c.Commit = [string](Get-ClaudeFlowReleaseInfo -Repo $c.Root).commit }
    }
    return $c
}

function New-ClaudeInstallContext {
    # The run's install state: where its store is and, once read, its checkpoint and recorded answers.
    param([Parameter(Mandatory = $true)][string]$Root, [System.Collections.IDictionary]$Bound = @{}, [switch]$WhatIfRun, [string]$AnswersPath)
    $script:ClaudeInstall = [pscustomobject]@{ Root = $Root; Location = (Get-ClaudeInstallLocation -Root $Root); Commit = ''; Checkpoint = $null; Resuming = $false
        Fingerprint = ''; Answers = [ordered]@{}; Lock = $null; WhatIf = [bool]$WhatIfRun; CloudShellNoted = $false; SubscriptionId = ''; Bound = @($Bound.Keys | ForEach-Object { [string]$_ })
        AnswersPath = $AnswersPath }
    return $script:ClaudeInstall
}

function Open-ClaudeInstallCheckpoint {
    # At startup, before any question: reads the checkpoint, refuses what it cannot resume, prints
    # where the run resumes and returns the recorded parameter answers (ADR-0046 decisions 5 and 6).
    param([Parameter(Mandatory = $true)][string]$Root, [System.Collections.IDictionary]$Bound = @{}, [switch]$Restart, [switch]$WhatIfRun, [string]$AnswersPath)
    $c = New-ClaudeInstallContext -Root $Root -Bound $Bound -WhatIfRun:$WhatIfRun -AnswersPath $AnswersPath
    $path = $c.Location.Checkpoint
    if ($WhatIfRun) {
        if (Test-Path -LiteralPath $path) { Write-Host "    An install checkpoint exists at $path; -WhatIf previews a first run and changes nothing." -ForegroundColor DarkGray }
        return @{}
    }
    Assert-ClaudeInstallStore
    # A default place that failed a check: no store, so nothing is resumed (decision 2).
    if ($c.Location.NoStore) { return @{} }
    $lock = Get-ClaudeInstallLockState $c.Location.Lock
    if ($lock.State -eq 'held') { Stop-ClaudeInstallLockHeld $lock $c.Location.Lock }
    if ($Restart -and (Test-Path -LiteralPath $path)) {
        $aside = $path -replace '\.json$', ('.discarded-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.json')
        Move-Item -LiteralPath $path -Destination $aside
        Write-Host "    -Restart: the install checkpoint is set aside as $aside." -ForegroundColor Yellow
        return @{}
    }
    $cp = Read-ClaudeInstallCheckpoint -Path $path -Restart ((Format-ClaudeInstallResume) + ' -Restart')
    if (-not $cp) { return @{} }
    if ($cp.installer -ne 'pwsh') {
        Stop-ClaudeInstall "the install checkpoint $path was written by install-claude-gateway.sh, whose steps differ; resume it with that installer. Nothing was changed. To discard it and start again: $(Format-ClaudeInstallResume) -Restart"
    }
    $c.Checkpoint = $cp
    $b = $cp.binding
    # A subscription passed by name is compared after az account set, by its id.
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    if (@($Bound.Keys) -contains 'SubscriptionId' -and [string]$Bound['SubscriptionId'] -match $guid -and [string]$Bound['SubscriptionId'] -ne [string]$b.subscriptionId) {
        Stop-ClaudeInstallBinding 'subscription' ([string]$b.subscriptionId) ([string]$Bound['SubscriptionId'])
    }
    if (@($Bound.Keys) -contains 'ResourceGroup' -and [string]$Bound['ResourceGroup'] -ne [string]$b.resourceGroup) { Stop-ClaudeInstallBinding 'resource group' ([string]$b.resourceGroup) ([string]$Bound['ResourceGroup']) }
    if (@($Bound.Keys) -contains 'ExistingApimName' -and [string]$Bound['ExistingApimName'] -ne [string]$b.apimName) { Stop-ClaudeInstallBinding 'gateway' ([string]$b.apimName) ([string]$Bound['ExistingApimName']) }
    if (@($Bound.Keys) -contains 'NamePrefix' -and [string]$Bound['NamePrefix'] -ne [string]$b.namePrefix -and ('apim-' + $Bound['NamePrefix']) -ne [string]$b.apimName) {
        Stop-ClaudeInstallBinding 'gateway' ([string]$b.apimName) ('apim-' + $Bound['NamePrefix'])
    }
    # The same name, reused this time and created last time or the other way round, is another gateway.
    $reused = if (@($Bound.Keys) -contains 'ExistingApimName') { 'true' } elseif (@($Bound.Keys) -contains 'NamePrefix') { 'false' } else { '' }
    if ($reused -and $reused -ne ([string][bool]$b.reusedApim).ToLowerInvariant()) { Stop-ClaudeInstallBinding 'reusedApim' ([string][bool]$b.reusedApim).ToLowerInvariant() $reused }
    $c.Resuming = $true
    $script:ClaudeInstallRunId = [string]$cp.runId
    foreach ($p in $cp.answers.PSObject.Properties) { $c.Answers[$p.Name] = $p.Value }
    Write-Host ''
    Write-Host "Install checkpoint: $path" -ForegroundColor Cyan
    Write-Host "Resuming install run $($cp.runId), started $($cp.createdUtc) by Install-ClaudeGateway.ps1." -ForegroundColor Cyan
    foreach ($s in @($cp.steps | Where-Object { $null -ne $_ -and $_.state -eq 'completed' })) { Write-Host ("  done {0}  {1}" -f $s.completedUtc, $script:ClaudeInstallSteps[[string]$s.id]) }
    Write-Host ("  resumes at: {0}" -f (Get-ClaudeInstallResumeTitle)) -ForegroundColor Cyan
    $c = Get-ClaudeInstallVersion
    if ([string]$cp.installerFingerprint -ne $c.Fingerprint -or ($cp.installerCommit -and $c.Commit -and $cp.installerCommit -ne $c.Commit)) {
        $short = { param($commit, $fingerprint) $f = ([string]$fingerprint -replace '^sha256:', ''); if ($commit) { "$(([string]$commit).Substring(0, [math]::Min(12, ([string]$commit).Length)))+$($f.Substring(0, [math]::Min(8, $f.Length)))" } else { "sha256:$($f.Substring(0, [math]::Min(12, $f.Length)))" } }
        Write-Host "  checkpoint written by Install-ClaudeGateway.ps1 $(& $short $cp.installerCommit $cp.installerFingerprint); running Install-ClaudeGateway.ps1 $(& $short $c.Commit $c.Fingerprint)" -ForegroundColor Yellow
    }
    $result = @{}
    foreach ($n in $script:ClaudeInstallParameterAnswers) {
        if (-not $c.Answers.Contains($n)) { continue }
        $v = $c.Answers[$n]
        $result[$n] = if ($n -in 'StandardModels', 'PremiumModels') { [string[]]@($v) } else { $v }
    }
    return $result
}

function Assert-ClaudeInstallTenant([string]$TenantId) {
    $c = $script:ClaudeInstall
    if ((Test-ClaudeInstallResuming) -and $TenantId -ne [string]$c.Checkpoint.binding.tenantId) { Stop-ClaudeInstallBinding 'tenant' ([string]$c.Checkpoint.binding.tenantId) $TenantId }
}
function Get-ClaudeInstallSubscriptionId {
    # The subscription az uses after the installer's az account set, read once; a name passed as
    # -SubscriptionId is recorded as this id.
    $c = $script:ClaudeInstall
    if ($c.SubscriptionId) { return $c.SubscriptionId }
    $r = Invoke-ClaudeInstallAzRead @('account', 'show', '-o', 'json')
    $id = ''
    if ($r.Verdict -eq 'present') { try { $id = [string]($r.Output | ConvertFrom-Json -ErrorAction Stop).id } catch { $id = '' } }
    $c.SubscriptionId = $id
    return $id
}
function Assert-ClaudeInstallSubscription {
    if (-not (Test-ClaudeInstallResuming)) { return }
    $c = $script:ClaudeInstall
    $current = Get-ClaudeInstallSubscriptionId
    if (-not $current) { Stop-ClaudeInstall "the current subscription could not be read with az account show, so the install checkpoint $($c.Location.Checkpoint) cannot be matched to it. Nothing was changed." }
    if ($current -ne [string]$c.Checkpoint.binding.subscriptionId) { Stop-ClaudeInstallBinding 'subscription' ([string]$c.Checkpoint.binding.subscriptionId) $current }
}
function Get-ClaudeInstallSummaryRow {
    # The summary's Checkpoint row; an answer this run changes is named, so the confirmation covers it.
    $c = $script:ClaudeInstall
    $now = Get-ClaudeInstallAnswers
    $changed = @(@($now.Keys) + @($c.Answers.Keys) | Select-Object -Unique | Where-Object {
            (ConvertTo-ClaudeFlowCanonical $(if ($now.Contains($_)) { $now[$_] })) -ne (ConvertTo-ClaudeFlowCanonical $(if ($c.Answers.Contains($_)) { $c.Answers[$_] })) })
    $row = "$($c.Location.Checkpoint), run $($c.Checkpoint.runId), $($c.Answers.Count) recorded answers reused, resumes at $(Get-ClaudeInstallResumeTitle)"
    if ($changed.Count) { $row += "; changed since the checkpoint: $($changed -join ', ')" }
    return $row
}

function Get-ClaudeInstallAnswers {
    # The answers of this run, read from the installer's variables after its summary is confirmed.
    # No secret is among them: -AddressCertificatePassword and tokens are never read (decision 15).
    $a = [ordered]@{}
    $read = { param($n) Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue }
    $values = @{ ExistingApimName = (& $read 'ExistingApim'); StandardModels = (& $read 'standardModelNames'); PremiumModels = (& $read 'premiumModelNames') }
    $subscription = Get-ClaudeInstallSubscriptionId
    if ($subscription) { $values['SubscriptionId'] = $subscription }
    $provider = & $read 'providerData'
    if ($provider) { $values['ModelOrganizationName'] = $provider.organizationName; $values['ModelIndustry'] = $provider.industry; $values['ModelCountryCode'] = $provider.countryCode }
    foreach ($n in $script:ClaudeInstallParameterAnswers) {
        $v = if ($values.ContainsKey($n)) { $values[$n] } else { & $read $n }
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v }
        if ($null -eq $v -or ($v -is [bool] -and -not $v) -or "$v" -eq '' -or ($n -in $script:ClaudeInstallIntegers -and "$v" -eq '0')) { continue }
        # Assigned directly: an if expression would unroll a one-model list into text.
        if ($n -in 'StandardModels', 'PremiumModels') { $a[$n] = [string[]]@($v | ForEach-Object { [string]$_ }) }
        elseif ($v -is [bool] -or $n -in $script:ClaudeInstallIntegers) { $a[$n] = $v }
        else { $a[$n] = [string]$v }
    }
    if ($a.Contains('ExistingApimName')) { $a.Remove('NamePrefix') }
    $prompt = @{ RevocationWindowSeconds = (& $read 'entitlementCacheSeconds'); TeamBudgetBehaviour = (& $read 'budgetMode'); UnassignedDevelopers = (& $read 'unassignedMode'); DeveloperEstimate = (& $read 'DeveloperEstimate') }
    foreach ($n in 'RevocationWindowSeconds', 'TeamBudgetBehaviour', 'UnassignedDevelopers', 'DeveloperEstimate') { if ("$($prompt[$n])" -ne '' -and "$($prompt[$n])" -ne '0') { $a[$n] = $(if ($n -in $script:ClaudeInstallIntegers) { [int]$prompt[$n] } else { [string]$prompt[$n] }) } }
    # Get-Variable -ValueOnly writes a list as one object; assigned first, it is read item by item.
    $given = & $read 'BusinessUnits'
    $units = @($given | Where-Object { $_ })
    if ($units.Count) {
        $a['BusinessUnits'] = @($units | ForEach-Object { $u = [ordered]@{}; foreach ($p in $_.PSObject.Properties) { if ($null -ne $p.Value) { $u[$p.Name] = $p.Value } }; [pscustomobject]$u })
    }
    $pending = & $read 'pendingDeployment'
    if ($pending) { $a['PendingClaudeDeployment'] = [pscustomobject][ordered]@{ name = [string]$pending.name; model = [string]$pending.model; version = [string]$pending.version; sku = [string]$pending.sku; capacity = [string]$pending.capacity; account = [string]$pending.account; resourceGroup = [string]$pending.resourceGroup } }
    return $a
}

function Get-ClaudeInstallInputHash([string]$Id) {
    # The answers a step uses, and for a deploying step its templates (ADR-0046 decision 5).
    $c = $script:ClaudeInstall
    $pick = switch ($Id) {
        'resource-group' { 'ResourceGroup', 'Location' }
        'entra-groups' { 'StandardGroup', 'PremiumGroup' }
        'claude-deployment' { @('PendingClaudeDeployment') }
        'business-units' { @('BusinessUnits') }
        'company-address' { @($c.Answers.Keys | Where-Object { $_ -like 'Address*' }) }
        # Every answer the step passes to scripts/Deploy-ClaudeProjection.ps1; the binding fields (resource
        # group, subscription, gateway) are compared by the binding itself (ADR-0046 decision 5, ADR-0047 decision 15).
        'projection' { 'EntitlementStore', 'ResolverInboundAccess', 'NamePrefix', 'Location', 'Sku', 'ProjectionResolverAppId', 'StandardGroup', 'PremiumGroup', 'DeploySyncJob', 'ProjectionSyncInterval' }
        'gateway-deployment' { @($c.Answers.Keys | Where-Object { $_ -notin 'StandardGroup', 'PremiumGroup', 'AuthMode', 'TeamBudgetBehaviour', 'DeveloperEstimate', 'DeployProjection', 'ProjectionResolverAppId', 'DeploySyncJob', 'ProjectionSyncInterval', 'PendingClaudeDeployment', 'ModelOrganizationName', 'ModelIndustry', 'ModelCountryCode' -and $_ -notlike 'Address*' }) }
        default { @() }
    }
    $inputs = [ordered]@{}
    foreach ($k in @($pick)) { if ($c.Answers.Contains($k)) { $inputs[$k] = $c.Answers[$k] } }
    if ($Id -eq 'gateway-deployment') { $inputs['templates'] = Get-ClaudeInstallFileHash -Root $c.Root -Paths (Get-ClaudeInstallTemplateFiles -Root $c.Root -Template 'infra/main.bicep') }
    if ($Id -eq 'projection') { $inputs['templates'] = Get-ClaudeInstallFileHash -Root $c.Root -Paths @('infra/projection.bicep', 'infra/projection-network.bicep', 'infra/resolver.bicep') }
    return ('sha256:' + (Get-ClaudeInstallSha256 ([Text.Encoding]::UTF8.GetBytes((ConvertTo-ClaudeFlowCanonical $inputs)))))
}

function Save-ClaudeInstallCheckpoint {
    # The commit point: after the summary is confirmed, before the first change (ADR-0032). The
    # lock is taken here, so a run still asking its questions holds nothing.
    $c = $script:ClaudeInstall
    if (-not $c -or $c.WhatIf) { return }
    $null = Get-ClaudeInstallVersion
    $answers = Get-ClaudeInstallAnswers
    $read = { param($n) Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue }
    $subscription = Get-ClaudeInstallSubscriptionId
    $binding = [ordered]@{ tenantId = [string](& $read 'acct').tenantId; subscriptionId = $(if ($subscription) { $subscription } else { [string](& $read 'SubscriptionId') }); resourceGroup = [string](& $read 'ResourceGroup')
        apimName = [string](& $read 'apimName'); namePrefix = [string](& $read 'NamePrefix'); reusedApim = [bool](& $read 'ExistingApim') }
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $c.Answers = $answers
    # Without a store: one warning and the resume command with the answers (decision 1).
    if ($c.Location.NoStore) { Write-ClaudeInstallNoStore; return }
    if (-not (Test-Path -LiteralPath $c.Location.Directory)) {
        # A state directory that cannot be created leaves the run without a checkpoint (decision 1).
        try { New-ClaudeInstallStateDirectory $c.Location.Directory }
        catch {
            $c.Location.Persistent = $false
            $c.Location.NoStore = "The install checkpoint directory $($c.Location.Directory) could not be created ($($_.Exception.Message)); this run keeps no checkpoint."
            Write-ClaudeInstallNoStore
            return
        }
    }
    Assert-ClaudeInstallStore
    if ($c.Location.NoStore) { Write-ClaudeInstallNoStore; return }
    if ($c.Checkpoint) {
        $c.Checkpoint.answers = [pscustomobject]$answers
    }
    else {
        $c.Checkpoint = [pscustomobject][ordered]@{ schema = $script:ClaudeInstallSchema; schemaVersion = 1; runId = $script:ClaudeInstallRunId; installer = 'pwsh'
            installerFingerprint = $c.Fingerprint; installerCommit = $c.Commit; checkout = $c.Root; createdUtc = $now; updatedUtc = $now
            binding = [pscustomobject]$binding; answers = [pscustomobject]$answers; steps = @() }
    }
    $c.Checkpoint.installerFingerprint = $c.Fingerprint
    $c.Checkpoint.installerCommit = $c.Commit
    $c.Lock = Enter-ClaudeInstallLock -Path $c.Location.Lock -RunId $c.Checkpoint.runId
    Save-ClaudeInstallState
    if (-not $c.Location.Persistent) {
        Write-Host "    [WARN] $($c.Location.Warning)" -ForegroundColor Yellow
        Write-Host "    Resume: $(Format-ClaudeInstallResume -WithAnswers)"
        $asked = @($script:ClaudeInstallPromptAnswers | Where-Object { $answers.Contains($_) })
        if ($asked.Count) { Write-Host "    A new session asks again for: $($asked -join ', ')." -ForegroundColor DarkGray }
    }
}

function Write-ClaudeInstallNoStore {
    # The run keeps no store: one warning line, then the resume command with every recorded answer, as
    # in an ephemeral Cloud Shell session (ADR-0046 decision 1).
    $c = $script:ClaudeInstall
    Write-Host "    [WARN] $(Protect-ClaudeInstallText $c.Location.NoStore)" -ForegroundColor Yellow
    Write-Host "    Resume: $(Protect-ClaudeInstallText (Format-ClaudeInstallResume -WithAnswers))"
}

function Save-ClaudeInstallState {
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Checkpoint -or -not $c.Lock) { return }
    $c.Checkpoint.updatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    Write-ClaudeInstallCheckpoint -Checkpoint $c.Checkpoint -Path $c.Location.Checkpoint
}

function Set-ClaudeInstallStep {
    # The step's state in the checkpoint, and its event in the progress stream, with or without a store.
    param([string]$Id, [string]$State, [string]$InputHash, $Receipt, [switch]$Quiet)
    if (-not $Quiet) { Write-ClaudeInstallStepEvent -Id $Id -Event $(if ($State -eq 'started') { 'started' } elseif ($State -eq 'completed') { 'completed' } else { 'warning' }) }
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Checkpoint -or -not $c.Lock) { return }
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $step = Get-ClaudeInstallStep $Id
    if (-not $step) {
        $step = [pscustomobject][ordered]@{ id = $Id; state = $State; startedUtc = $now; completedUtc = $null; inputHash = ''; receipt = $null }
        $c.Checkpoint.steps = @(@($c.Checkpoint.steps | Where-Object { $null -ne $_ }) + $step)
    }
    if ($State -eq 'started') { if ($step.state -ne 'started') { $step.startedUtc = $now }; $step.completedUtc = $null } else { $step.completedUtc = $now }
    $step.state = $State
    if ($PSBoundParameters.ContainsKey('InputHash')) { $step.inputHash = $InputHash }
    if ($PSBoundParameters.ContainsKey('Receipt')) { $step.receipt = $Receipt }
    Save-ClaudeInstallState
}
function Start-ClaudeInstallStep([string]$Id) { $old = Get-ClaudeInstallStep $Id; Set-ClaudeInstallStep -Id $Id -State 'started' -InputHash (Get-ClaudeInstallInputHash $Id) -Receipt $(if ($old) { $old.receipt } else { $null }) }
function Complete-ClaudeInstallStep {
    param([string]$Id, $Receipt, [switch]$Incomplete, [switch]$Quiet)
    $state = if ($Incomplete) { 'incomplete' } else { 'completed' }
    if ($PSBoundParameters.ContainsKey('Receipt')) { Set-ClaudeInstallStep -Id $Id -State $state -Receipt $Receipt -Quiet:$Quiet } else { Set-ClaudeInstallStep -Id $Id -State $state -Quiet:$Quiet }
}

function Test-ClaudeInstallStepSkip {
    # $true when the step completed with this input and a live read shows its result (R1). Otherwise
    # the step is marked started and runs; an unreadable result refuses unless the step is idempotent.
    param([string]$Id, [scriptblock]$Verify, [switch]$Idempotent)
    if (-not (Test-ClaudeInstallStepSelected $Id)) { return $true }
    $title = $script:ClaudeInstallSteps[$Id]
    $hash = Get-ClaudeInstallInputHash $Id
    $step = Get-ClaudeInstallStep $Id
    if ($step -and $step.state -eq 'completed' -and [string]$step.inputHash -eq $hash -and $Verify) {
        $v = & $Verify $step.receipt
        if ($v.Verdict -eq 'present') { Write-Host "    [OK]   ${title}: verified live, skipped" -ForegroundColor Green; Write-ClaudeInstallStepEvent -Id $Id -Event 'skipped-verified'; return $true }
        if ($v.Verdict -eq 'inconclusive' -and -not $Idempotent) { Stop-ClaudeInstall "$title could not be verified ($($v.Detail)). Nothing was changed. Resume: $(Format-ClaudeInstallResume)" }
        Write-Host "    ${title}: $(Protect-ClaudeInstallText $v.Detail); running it again" -ForegroundColor Yellow
    }
    elseif ($step -and $step.state -eq 'completed') { Write-Host "    ${title}: its input changed since the checkpoint; running it again" -ForegroundColor Yellow }
    Set-ClaudeInstallStep -Id $Id -State 'started' -InputHash $hash -Receipt $(if ($step) { $step.receipt } else { $null })
    return $false
}

function Close-ClaudeInstallCheckpoint {
    # After the last step: removed when every step completed, kept with the resume command otherwise.
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Checkpoint -or -not $c.Lock) { return }
    $open = @($c.Checkpoint.steps | Where-Object { $null -ne $_ -and $_.state -ne 'completed' })
    if ($script:ClaudeInstallSelection.Count) {
        # -Steps ran part of the install, so the checkpoint is kept for the rest (A11).
        Write-Host "    -Steps ran $($script:ClaudeInstallSelection -join ', '); the install checkpoint is kept, and a run without -Steps resumes the rest." -ForegroundColor DarkGray
        Write-Host "    Resume: $(Protect-ClaudeInstallText (Get-ClaudeInstallResumeLine))"
    }
    elseif ($open.Count) {
        Write-Host "    [WARN] The install checkpoint is kept: $((@($open | ForEach-Object { $script:ClaudeInstallSteps[[string]$_.id] })) -join ', ') did not complete." -ForegroundColor Yellow
        Write-Host "    Resume: $(Protect-ClaudeInstallText $(if ($c.Location.Persistent) { Format-ClaudeInstallResume } else { Format-ClaudeInstallResume -WithAnswers }))"
    }
    else { Remove-Item -LiteralPath $c.Location.Checkpoint -Force -ErrorAction SilentlyContinue; Write-Host '    Install complete; the install checkpoint is removed.' -ForegroundColor DarkGray }
    Exit-ClaudeInstallLock
}

function Write-ClaudeInstallFailureHint {
    # After a failure that is not a refusal: where the checkpoint is and the command that resumes.
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Checkpoint) { return }
    $resume = if ($c.Location.Persistent) { Format-ClaudeInstallResume } else { Format-ClaudeInstallResume -WithAnswers }
    Write-Host "Resume: $(Protect-ClaudeInstallText $resume)"
}

# Where the store is and whether it is trusted, the live reads and step actions, then step selection
# and the progress stream.
. (Join-Path $PSScriptRoot 'ClaudeInstallStore.ps1')
. (Join-Path $PSScriptRoot 'ClaudeInstallResume.ps1')
. (Join-Path $PSScriptRoot 'ClaudeInstallSteps.ps1')
