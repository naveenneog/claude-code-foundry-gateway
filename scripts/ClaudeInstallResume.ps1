# Live reads and step actions of the install checkpoint (docs/adr/0046-installer-checkpoint-and-resume.md).
# Dot-sourced by scripts/ClaudeInstallCheckpoint.ps1. Each read answers present, absent or
# inconclusive, and only present skips a step (R1). Runs on Windows PowerShell 5.1 and PowerShell 7.

function Invoke-ClaudeInstallAzRead {
    # present, absent (an error code on the read's not-found list) or inconclusive (anything else).
    # Invoke-AzOptional cannot tell absent from unreadable, so it is not used for a verification.
    param([string[]]$Arguments, [string[]]$NotFound = @())
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try { $all = @(& az @Arguments 2>&1); $code = $LASTEXITCODE } catch { $all = @($_); $code = 1 } finally { $ErrorActionPreference = $saved }
    $err = (@($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() }) -join ' ').Trim()
    $out = (@($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $verdict = if ($code -eq 0) { 'present' } elseif (@($NotFound | Where-Object { $err.Contains($_) }).Count) { 'absent' } else { 'inconclusive' }
    $detail = if ($err) { ($err -split '(?<=\.)\s')[0] } else { "az exited $code" }
    return [pscustomobject]@{ Verdict = $verdict; Output = $out; Error = $err; Detail = $detail }
}
$script:ClaudeInstallGraphNotFound = @('Request_ResourceNotFound', 'does not exist or one of its queried reference-property objects are not present')

function Get-ClaudeInstallSetting([string]$Name, [int]$Default) {
    $v = 0
    if ([int]::TryParse([string][Environment]::GetEnvironmentVariable($Name), [ref]$v) -and $v -ge 0) { return $v }
    return $Default
}

function Write-ClaudeInstallCloudShellLine([int]$Seconds = [int]::MaxValue) {
    # Before any wait that can outlast Cloud Shell's 20-minute idle limit (FAQ; ADR-0046 decision 10):
    # a bounded wait longer than 60 s, or az deployment group create, which has no bound.
    $c = $script:ClaudeInstall
    if (-not $c -or -not $c.Location.CloudShell -or $c.CloudShellNoted -or $Seconds -le 60) { return }
    $c.CloudShellNoted = $true
    $resume = if ($c.Location.Persistent) { Format-ClaudeInstallResume } else { Format-ClaudeInstallResume -WithAnswers }
    $outlive = if ($c.Location.NoStore) { 'the ARM deployment outlives the session, and this run keeps no install checkpoint' }
    elseif ($c.Location.Persistent) { 'the install checkpoint and the ARM deployment outlive the session' } else { 'the ARM deployment outlives the session and this install checkpoint does not' }
    Write-Host "    Cloud Shell ends a session after 20 minutes without interactive activity; $outlive. Resume: $resume" -ForegroundColor Yellow
}

function Get-ClaudeInstallDeploymentState([string]$ResourceGroup, [string]$Name) {
    $r = Invoke-ClaudeInstallAzRead @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', $Name, '-o', 'json') @('DeploymentNotFound')
    $state = [pscustomobject]@{ Verdict = $r.Verdict; State = ''; GatewayUrl = ''; Error = ''; Detail = $r.Detail }
    if ($r.Verdict -ne 'present') { return $state }
    try { $d = $r.Output | ConvertFrom-Json -ErrorAction Stop } catch { $state.Verdict = 'inconclusive'; $state.Detail = 'the deployment record is not JSON'; return $state }
    $state.State = [string]$d.properties.provisioningState
    if ($d.properties.outputs -and $d.properties.outputs.gatewayUrl) { $state.GatewayUrl = [string]$d.properties.outputs.gatewayUrl.value }
    if ($d.properties.error) { $state.Error = "$($d.properties.error.code): $($d.properties.error.message)" }
    if ($state.State -eq 'Deleted') { $state.Verdict = 'absent' }
    return $state
}

function Wait-ClaudeInstallDeployment([string]$ResourceGroup, [string]$Name) {
    # A bounded wait on a deployment ARM is still running; az deployment group wait is not used (U68).
    $poll = Get-ClaudeInstallSetting 'CLAUDE_GATEWAY_DEPLOY_POLL_SECONDS' 30
    $bound = Get-ClaudeInstallSetting 'CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS' 3600
    Write-ClaudeInstallCloudShellLine $bound
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = ''
    while ($true) {
        $s = Get-ClaudeInstallDeploymentState $ResourceGroup $Name
        if ($s.Verdict -ne 'present' -or $s.State -in $script:ClaudeInstallTerminal) { return $s }
        if ($s.State -ne $last) { Write-Host ("    Deployment {0} is {1} after {2:N0} s; waiting up to {3} s." -f $Name, $s.State, $watch.Elapsed.TotalSeconds, $bound) -ForegroundColor DarkGray; $last = $s.State }
        if ($watch.Elapsed.TotalSeconds -ge $bound) {
            Stop-ClaudeInstall "deployment $Name in resource group $ResourceGroup is still running after $bound s, and Azure Resource Manager continues it without this session. Nothing was changed. Resume: $(Format-ClaudeInstallResume)"
        }
        if ($poll -gt 0) { Start-Sleep -Seconds $poll }
    }
}

function Wait-ClaudeInstallMainDeployments([string]$ResourceGroup) {
    # Never two main.bicep deployments at once: claude-gw- (both installers), claude-gateway- (deploy.ps1).
    $r = Invoke-ClaudeInstallAzRead @('deployment', 'group', 'list', '-g', $ResourceGroup, '-o', 'json') @('ResourceGroupNotFound')
    if ($r.Verdict -eq 'absent') { return }
    if ($r.Verdict -ne 'present') { Stop-ClaudeInstall "the deployments of resource group $ResourceGroup could not be listed ($($r.Detail)), so another main.bicep deployment cannot be ruled out. Nothing was changed. Resume: $(Format-ClaudeInstallResume)" }
    $parsed = if ($r.Output) { $r.Output | ConvertFrom-Json } else { @() }
    foreach ($d in @($parsed)) {
        $state = [string]$d.properties.provisioningState
        if ([string]$d.name -notmatch '^(claude-gw-|claude-gateway-)' -or $state -in ($script:ClaudeInstallTerminal + 'Deleted')) { continue }
        Write-Host "    Deployment $($d.name) is $state; waiting for it before deploying." -ForegroundColor Yellow
        $null = Wait-ClaudeInstallDeployment $ResourceGroup ([string]$d.name)
    }
}

function Test-ClaudeInstallGateway([string]$ResourceGroup, [string]$ApimName, $Receipt) {
    $apim = Invoke-ClaudeInstallAzRead @('apim', 'show', '-g', $ResourceGroup, '-n', $ApimName, '--query', 'name', '-o', 'tsv') @('ResourceNotFound')
    if ($apim.Verdict -ne 'present') { return [pscustomobject]@{ Verdict = $apim.Verdict; Detail = "API Management $ApimName is not readable or gone ($($apim.Detail))" } }
    $api = Invoke-ClaudeInstallAzRead @('apim', 'api', 'show', '-g', $ResourceGroup, '--service-name', $ApimName, '--api-id', 'claude-foundry', '-o', 'none') @('ResourceNotFound')
    if ($api.Verdict -ne 'present') { return [pscustomobject]@{ Verdict = $api.Verdict; Detail = "the Claude API on $ApimName is not readable or gone ($($api.Detail))" } }
    if ($Receipt -and $Receipt.roleOrigin -eq 'created' -and $Receipt.roleAssignmentId) {
        $role = Invoke-ClaudeInstallAzRead @('rest', '--method', 'get', '--url', "https://management.azure.com$($Receipt.roleAssignmentId)?api-version=2022-04-01", '-o', 'json') @('RoleAssignmentNotFound')
        if ($role.Verdict -ne 'present') { return [pscustomobject]@{ Verdict = $role.Verdict; Detail = "the gateway's Foundry role assignment is not readable or gone ($($role.Detail))" } }
        $why = Test-ClaudeInstallRoleAssignment -Output $role.Output -Id ([string]$Receipt.roleAssignmentId) -ResourceGroup $ResourceGroup -ApimName $ApimName
        if ($why) { return [pscustomobject]@{ Verdict = 'inconclusive'; Detail = $why } }
    }
    return [pscustomobject]@{ Verdict = 'present'; Detail = '' }
}

function Test-ClaudeInstallRoleAssignment {
    # '' when the role assignment a receipt names is what the deployment grants: Cognitive Services User
    # (a97b65f3-24c7-4388-baec-2e87135dc908, infra/foundry-role.bicep:13) on the Foundry account, to the
    # gateway's identity. Otherwise why not, so a resume does not take another assignment for it (R5).
    param([string]$Output, [string]$Id, [string]$ResourceGroup, [string]$ApimName)
    $read = { param($n) [string](Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    $p = $null
    try { $p = ($Output | ConvertFrom-Json -ErrorAction Stop).properties } catch { $p = $null }
    if (-not $p) { return "the role assignment $Id could not be read as JSON" }
    $foundry = Invoke-ClaudeInstallAzRead @('cognitiveservices', 'account', 'show', '-g', (& $read 'FoundryResourceGroup'), '-n', (& $read 'FoundryAccount'), '--query', 'id', '-o', 'tsv')
    $principal = Invoke-ClaudeInstallAzRead @('apim', 'show', '-g', $ResourceGroup, '-n', $ApimName, '--query', 'identity.principalId', '-o', 'tsv')
    if ($foundry.Verdict -ne 'present' -or -not $foundry.Output -or $principal.Verdict -ne 'present' -or -not $principal.Output) { return "the Foundry account or the gateway's identity could not be read to check the role assignment $Id" }
    $role = @(([string]$p.roleDefinitionId) -split '/')[-1]
    $same = { param([string]$A, [string]$B) [string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase) }
    if ((& $same $p.scope $foundry.Output) -and (& $same $role 'a97b65f3-24c7-4388-baec-2e87135dc908') -and (& $same $p.principalId $principal.Output)) { return '' }
    return "the role assignment $Id in the install checkpoint grants role $role at $($p.scope) to $($p.principalId), not Cognitive Services User at $($foundry.Output) to the gateway's identity $($principal.Output)"
}

function Resolve-ClaudeInstallGatewayStep {
    # Whether the gateway deployment runs. A recorded deployment still running is awaited, one that
    # succeeded is verified live, one that failed is shown; the installer's read-backs then run
    # before any new deployment (ADR-0046 decision 10).
    param([string]$ResourceGroup, [string]$ApimName)
    $title = $script:ClaudeInstallSteps['gateway-deployment']
    $step = Get-ClaudeInstallStep 'gateway-deployment'
    # Another step selected with -Steps: the gateway its prerequisite check verified, as recorded.
    if (-not (Test-ClaudeInstallStepSelected 'gateway-deployment')) { return [pscustomobject]@{ Run = $false; GatewayUrl = $(if ($step -and $step.receipt) { [string]$step.receipt.gatewayUrl } else { "https://$ApimName.azure-api.net/claude" }) } }
    $hash = Get-ClaudeInstallInputHash 'gateway-deployment'
    $recorded = if ($step -and $step.receipt) { @($step.receipt.deployments | Where-Object { $null -ne $_ }) | Select-Object -Last 1 } else { $null }
    if ($recorded) {
        $name = [string]$recorded.name
        $s = Get-ClaudeInstallDeploymentState $ResourceGroup $name
        if ($s.Verdict -eq 'present' -and $s.State -notin $script:ClaudeInstallTerminal) { $s = Wait-ClaudeInstallDeployment $ResourceGroup $name }
        if ($s.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "deployment $name in resource group $ResourceGroup could not be read ($($s.Detail)), so it is neither skipped nor repeated. Nothing was changed. Resume: $(Format-ClaudeInstallResume)" }
        if ($s.Verdict -eq 'absent') { Write-Host "    ${title}: deployment $name is not in the resource group's history; deploying again" -ForegroundColor Yellow }
        elseif ($s.State -ne 'Succeeded') {
            Write-Host "    ${title}: deployment $name $($s.State): $($s.Error)" -ForegroundColor Yellow
            $ops = Invoke-ClaudeInstallAzRead @('deployment', 'operation', 'group', 'list', '-g', $ResourceGroup, '-n', $name, '-o', 'json') @()
            if ($ops.Verdict -eq 'present' -and $ops.Output) {
                foreach ($o in @($ops.Output | ConvertFrom-Json)) { if ($o.properties.provisioningState -eq 'Failed') { Write-Host "      failed operation: $($o.properties.targetResource.resourceName): $($o.properties.statusMessage.error.message)" -ForegroundColor DarkGray } }
            }
        }
        elseif ([string]$step.inputHash -ne $hash) { Write-Host "    ${title}: the templates or answers changed since deployment $name; deploying again" -ForegroundColor Yellow }
        else {
            $live = Test-ClaudeInstallGateway $ResourceGroup $ApimName $step.receipt
            if ($live.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "$title could not be verified ($($live.Detail)). Nothing was changed. Resume: $(Format-ClaudeInstallResume)" }
            if ($live.Verdict -eq 'present') {
                $url = if ($s.GatewayUrl) { $s.GatewayUrl } else { [string]$step.receipt.gatewayUrl }
                if ($step.state -ne 'completed') { $recorded.lastState = 'Succeeded'; Set-ClaudeInstallReceiptValue $step.receipt 'gatewayUrl' $url; Complete-ClaudeInstallStep 'gateway-deployment' -Receipt $step.receipt }
                else { Write-ClaudeInstallStepEvent -Id 'gateway-deployment' -Event 'skipped-verified' }
                Write-Host "    [OK]   ${title}: verified live, skipped (deployment $name)" -ForegroundColor Green
                return [pscustomobject]@{ Run = $false; GatewayUrl = $url }
            }
            Write-Host "    ${title}: $($live.Detail); deploying again" -ForegroundColor Yellow
        }
    }
    Wait-ClaudeInstallMainDeployments $ResourceGroup
    Set-ClaudeInstallStep -Id 'gateway-deployment' -State 'started' -InputHash $hash -Receipt $(if ($step) { $step.receipt } else { $null })
    return [pscustomobject]@{ Run = $true; GatewayUrl = '' }
}

function Set-ClaudeInstallReceiptValue($Receipt, [string]$Name, $Value) {
    if ($Receipt.PSObject.Properties.Name -contains $Name) { $Receipt.$Name = $Value } else { $Receipt | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Register-ClaudeInstallDeployment([string]$Name, [bool]$CreatedApim) {
    # Recorded before az deployment group create, so a resume finds the deployment by name (R4). The
    # APIM's origin is recorded with the first deployment: a resume finds the APIM that deployment made.
    $step = Get-ClaudeInstallStep 'gateway-deployment'
    $receipt = if ($step -and $step.receipt) { $step.receipt } else { [pscustomobject][ordered]@{ deployments = @() } }
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $receipt.deployments = @(@($receipt.deployments | Where-Object { $null -ne $_ }) + [pscustomobject][ordered]@{ name = $Name; recordedUtc = $now; lastState = 'started' })
    if ($receipt.PSObject.Properties.Name -notcontains 'origin') { Set-ClaudeInstallReceiptValue $receipt 'origin' $(if ($CreatedApim) { 'created' } else { 'pre-existing' }) }
    Set-ClaudeInstallStep -Id 'gateway-deployment' -State 'started' -Receipt $receipt
    Write-ClaudeInstallCloudShellLine
}

function Complete-ClaudeInstallGatewayStep {
    param([string]$ResourceGroup, [string]$ApimName, [string]$GatewayUrl, [bool]$GrantedRole, [string]$FoundryResourceGroup, [string]$FoundryAccount, [string]$DesktopClientId)
    $step = Get-ClaudeInstallStep 'gateway-deployment'
    if (-not $step) { return }
    $receipt = $step.receipt
    @($receipt.deployments)[-1].lastState = 'Succeeded'
    Set-ClaudeInstallReceiptValue $receipt 'apimName' $ApimName
    Set-ClaudeInstallReceiptValue $receipt 'gatewayUrl' $GatewayUrl
    $principal = Invoke-ClaudeInstallAzRead @('apim', 'show', '-g', $ResourceGroup, '-n', $ApimName, '--query', 'identity.principalId', '-o', 'tsv')
    $scope = Invoke-ClaudeInstallAzRead @('cognitiveservices', 'account', 'show', '-g', $FoundryResourceGroup, '-n', $FoundryAccount, '--query', 'id', '-o', 'tsv')
    # Both values non-empty: az role assignment list treats an empty scope or assignee as no filter.
    if ($principal.Output -and $scope.Output) {
        $list = Invoke-ClaudeInstallAzRead @('role', 'assignment', 'list', '--assignee-object-id', $principal.Output, '--scope', $scope.Output, '--role', 'Cognitive Services User', '-o', 'json')
        $match = if ($list.Verdict -eq 'present' -and $list.Output) { @($list.Output | ConvertFrom-Json | Where-Object { $_.scope -eq $scope.Output }) | Select-Object -First 1 } else { $null }
        if ($match) { Set-ClaudeInstallReceiptValue $receipt 'roleAssignmentId' ([string]$match.id); Set-ClaudeInstallReceiptValue $receipt 'roleOrigin' $(if ($GrantedRole) { 'created' } else { 'pre-existing' }) }
    }
    if ($DesktopClientId) { Set-ClaudeInstallReceiptValue $receipt 'desktopClientId' $DesktopClientId }
    Complete-ClaudeInstallStep 'gateway-deployment' -Receipt $receipt
}

function Get-ClaudeInstallCodePointLength([string]$Text) {
    # Unicode code points, as jq's length counts a string: a surrogate pair is one. Windows
    # PowerShell 5.1 runs on .NET Framework, which has no String.EnumerateRunes.
    $count = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ([char]::IsHighSurrogate($Text[$i]) -and $i + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) { $i++ }
        $count++
    }
    return $count
}

function Assert-ClaudeInstallNames {
    # At input, before the summary: a name that Azure CLI places inside an OData string literal holds no
    # single quote (ADR-0046 decision 11). A refusal is one line naming the parameter.
    param([System.Collections.IDictionary]$Values)
    foreach ($n in @($Values.Keys)) {
        $v = [string]$Values[$n]
        if ($n -notin $script:ClaudeInstallODataAnswers -or -not $v.Contains("'")) { continue }
        $what = if ($n -eq 'NamePrefix') { "name prefixes containing a single quote are not supported, because Azure CLI places the projection resolver app name claude-projection-resolver-$v inside an OData string literal" }
        else { 'Entra group names containing a single quote are not supported, because Azure CLI places the name inside an OData string literal' }
        Stop-ClaudeInstall "-$n '$v': $what (startswith(displayName,'<name>')). Nothing was changed."
    }
}

function Find-ClaudeInstallGroupByName([string]$Name, [string]$Id) {
    # A group by display name (ADR-0046 decision 11), and with -Id the group of that id only. az ad
    # group list --display-name sends startswith(displayName,'<name>') to Microsoft Graph, and --filter
    # adds "id eq '<id>'" (az joins both with and, role/custom.py:1898-1905), so each listed name starts
    # with the name under Graph's own comparison, and a listed name with as many code points is the name.
    # No name is compared here, as in install-resume.sh. present: one such group with an id; absent:
    # none (longer names only); inconclusive: a failed read, output that is not a JSON list of groups, a
    # name that is not text, or a group of that length without an id, or more than one.
    $query = @('ad', 'group', 'list', '--display-name', $Name)
    if ($Id) { $query += @('--filter', "id eq '$Id'") }
    $r = Invoke-ClaudeInstallAzRead ($query + @('-o', 'json'))
    $result = { param([string]$Verdict, [string]$Id, [string]$Detail) [pscustomobject]@{ Verdict = $Verdict; Id = $Id; Detail = $Detail } }
    if ($r.Verdict -ne 'present') { return (& $result 'inconclusive' '' $r.Detail) }
    $unreadable = 'the group list is not a JSON list of groups'
    if (-not $r.Output.StartsWith('[')) { return (& $result 'inconclusive' '' $unreadable) }
    # PowerShell 7 reads an ISO 8601 string as a date unless -DateKind String (7.5 and later) is given.
    $convert = @{ ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $convert['DateKind'] = 'String' }
    try { $parsed = $r.Output | ConvertFrom-Json @convert } catch { return (& $result 'inconclusive' '' $unreadable) }
    $length = Get-ClaudeInstallCodePointLength $Name
    $same = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $parsed) {
        if ($null -eq $item) { continue }
        if ($item -isnot [System.Management.Automation.PSCustomObject]) { return (& $result 'inconclusive' '' $unreadable) }
        $shown = $item.displayName
        if ($null -ne $shown -and $shown -isnot [string]) { return (& $result 'inconclusive' '' $unreadable) }
        if ($shown -is [string] -and (Get-ClaudeInstallCodePointLength $shown) -eq $length) { $same.Add($item) }
    }
    $ids = @($same | ForEach-Object { if ($_.id -is [string] -and $_.id) { $_.id } else { '?' } })
    if ($same.Count -gt 1) { return (& $result 'inconclusive' '' "$($same.Count) groups have a name of that length: $($ids -join ', ')") }
    if ($same.Count -eq 1 -and $ids[0] -eq '?') { return (& $result 'inconclusive' '' 'the group with a name of that length has no id') }
    if ($same.Count -eq 1) { return (& $result 'present' $ids[0] '') }
    return (& $result 'absent' '' '')
}

function Invoke-ClaudeInstallGroups {
    # The tier groups, with receipts: a resume reads each by id and never creates a second group
    # with the same name (ADR-0046 decision 11). A receipt applies to the name it records, compared
    # code point by code point as jq's == compares, and a name finds a group by its length.
    param([object[]]$Groups)
    if (-not (Test-ClaudeInstallStepSelected 'entra-groups')) { return }
    $step = Get-ClaudeInstallStep 'entra-groups'
    $old = if ($step -and $step.receipt) { @($step.receipt.groups | Where-Object { $null -ne $_ }) } else { @() }
    $hash = Get-ClaudeInstallInputHash 'entra-groups'
    $resume = Format-ClaudeInstallResume
    # Started in the progress stream only when a group is looked up by name: a resume that verifies every
    # receipt live skips the step.
    Set-ClaudeInstallStep -Id 'entra-groups' -State 'started' -InputHash $hash -Receipt $(if ($step) { $step.receipt } else { $null }) -Quiet
    $made = [System.Collections.Generic.List[object]]::new()
    $complete = $true
    $verified = 0
    foreach ($g in $Groups) {
        $rec = @($old | Where-Object { $_.role -eq $g.Role -and [string]::Equals([string]$_.displayName, [string]$g.Name, [StringComparison]::Ordinal) }) | Select-Object -First 1
        if ($rec -and $rec.id) {
            $r = Invoke-ClaudeInstallAzRead @('ad', 'group', 'show', '--group', [string]$rec.id, '--query', 'id', '-o', 'tsv') $script:ClaudeInstallGraphNotFound
            if ($r.Verdict -eq 'present') {
                # The receipt's id must be the configured group: listed under its name, by the name rule.
                $named = Find-ClaudeInstallGroupByName $g.Name ([string]$rec.id)
                if ($named.Verdict -ne 'present' -or -not [string]::Equals($named.Id, [string]$rec.id, [StringComparison]::OrdinalIgnoreCase)) {
                    $why = if ($named.Verdict -eq 'absent') { 'the group with that id has another name' } elseif ($named.Verdict -eq 'present') { "Microsoft Graph listed $($named.Id)" } else { $named.Detail }
                    Stop-ClaudeInstall "Entra group '$($g.Name)' ($($rec.id)) in the install checkpoint is not listed by Microsoft Graph under that name ($why), so it is neither used nor created again. Nothing was changed. Resume: $resume"
                }
                Write-Host "    [OK]   $($g.Name) exists ($($rec.id))" -ForegroundColor Green; $made.Add($rec); $verified++; continue
            }
            if ($r.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "Entra group '$($g.Name)' ($($rec.id)) could not be read ($($r.Detail)), so it is neither skipped nor created again. Nothing was changed. Resume: $resume" }
            if ($rec.origin -eq 'created') {
                Stop-ClaudeInstall "Entra group '$($g.Name)' ($($rec.id)), created by this run at $($rec.createdUtc), is not returned by Microsoft Graph. A group created moments ago can take time to appear in Microsoft Graph, and a rerun later continues without creating a second group. Nothing was changed. Resume: $resume"
            }
            Write-Host "    $($g.Name) ($($rec.id)) is gone; looking it up by name." -ForegroundColor Yellow
        }
        Write-ClaudeInstallStepEvent -Id 'entra-groups' -Event 'started'
        $found = Find-ClaudeInstallGroupByName $g.Name
        if ($found.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "Entra group '$($g.Name)' could not be looked up by name ($($found.Detail)), so it is neither reused nor created. Nothing was changed by this step. Resume: $resume" }
        if ($found.Verdict -eq 'present') {
            Write-Host "    [OK]   $($g.Name) exists" -ForegroundColor Green
            $made.Add([pscustomobject][ordered]@{ role = $g.Role; displayName = $g.Name; id = $found.Id; origin = 'pre-existing'; createdUtc = $null })
            continue
        }
        $created = Invoke-ClaudeInstallAzRead @('ad', 'group', 'create', '--display-name', $g.Name, '--mail-nickname', $g.Name, '-o', 'json')
        $obj = $null
        if ($created.Verdict -eq 'present') { try { $obj = $created.Output | ConvertFrom-Json -ErrorAction Stop } catch { $obj = $null } }
        if ($obj -and $obj.id) {
            Write-Host "    [OK]   $($g.Name) created" -ForegroundColor Green
            $made.Add([pscustomobject][ordered]@{ role = $g.Role; displayName = $g.Name; id = [string]$obj.id; origin = 'created'; createdUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) })
        }
        else {
            Write-Host "    [WARN] Could not create '$($g.Name)' - your tenant may restrict group creation." -ForegroundColor Yellow
            Write-Host '    Ask an admin to create it, then re-run.' -ForegroundColor DarkGray
            $complete = $false
        }
    }
    $all = $verified -eq @($Groups).Count
    if ($all) { Write-Host "    [OK]   $($script:ClaudeInstallSteps['entra-groups']): verified live, skipped" -ForegroundColor Green; Write-ClaudeInstallStepEvent -Id 'entra-groups' -Event 'skipped-verified' }
    Complete-ClaudeInstallStep 'entra-groups' -Receipt ([pscustomobject]@{ groups = @($made) }) -Incomplete:(-not $complete) -Quiet:$all
}

function Get-ClaudeInstallVerdict([string]$Verdict, [string]$Detail) { return [pscustomobject]@{ Verdict = $Verdict; Detail = $Detail } }

function Add-ClaudeInstallBusinessUnit([string]$Id, [string]$GroupId, [string]$GroupOrigin, [string]$InputHash) {
    # Each unit written, so a resume after a later refusal verifies it in bu-registry (S3).
    $step = Get-ClaudeInstallStep 'business-units'
    if (-not $step) { return }
    $units = @(if ($step.receipt) { $step.receipt.units | Where-Object { $null -ne $_ -and $_.id -ne $Id } })
    $unit = [ordered]@{ id = $Id; groupId = $GroupId; groupOrigin = $GroupOrigin }
    if ($InputHash) { $unit['inputHash'] = $InputHash }
    $units += [pscustomobject]$unit
    Set-ClaudeInstallStep -Id 'business-units' -State 'started' -Receipt ([pscustomobject]@{ units = @($units) })
}

function Get-ClaudeInstallResolverApp([string]$NamePrefix, [string]$Supplied) {
    # The projection's resolver app by id when known: supplied, recorded by an earlier attempt, or the
    # one app with the display name Deploy-ClaudeProjection.ps1 gives it (ClaudeProjectionChecks.ps1:167).
    # An id from the checkpoint, as a receipt or as a recorded answer this run does not pass again, is
    # checked live before it is used (R5).
    $c = $script:ClaudeInstall
    $expected = "claude-projection-resolver-$NamePrefix"
    $fromCheckpoint = (Test-ClaudeInstallResuming) -and @($c.Bound) -notcontains 'ProjectionResolverAppId'
    if ($Supplied) {
        if ($fromCheckpoint) { Assert-ClaudeInstallResolverApp $Supplied $expected }
        return [pscustomobject]@{ Id = $Supplied; Origin = 'pre-existing' }
    }
    $step = Get-ClaudeInstallStep 'projection'
    if ($step -and $step.receipt -and $step.receipt.resolverAppId) {
        Assert-ClaudeInstallResolverApp ([string]$step.receipt.resolverAppId) $expected
        return [pscustomobject]@{ Id = [string]$step.receipt.resolverAppId; Origin = [string]$step.receipt.resolverOrigin }
    }
    $r = Invoke-ClaudeInstallAzRead @('ad', 'app', 'list', '--display-name', $expected, '--query', '[].appId', '-o', 'tsv')
    $ids = @(if ($r.Verdict -eq 'present') { $r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    if ($ids.Count -eq 1) { return [pscustomobject]@{ Id = $ids[0]; Origin = 'pre-existing' } }
    return [pscustomobject]@{ Id = ''; Origin = 'created' }
}

function Assert-ClaudeInstallResolverApp([string]$AppId, [string]$Expected) {
    # The app an id names: it exists, its appId is that id, and its display name is the resolver's. An id
    # that is not a GUID is not read: az ad app show --id would place it inside an OData string literal.
    if ($AppId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        Stop-ClaudeInstall "the projection resolver app id '$AppId' in the install checkpoint is not an application (client) id GUID; az ad app show --id places any other value inside an OData string literal, so it is not read. Nothing was changed. Resume: $(Format-ClaudeInstallResume)"
    }
    $r = Invoke-ClaudeInstallAzRead @('ad', 'app', 'show', '--id', $AppId, '-o', 'json') $script:ClaudeInstallGraphNotFound
    $why = ''
    if ($r.Verdict -ne 'present') { $why = "is not returned by Microsoft Graph ($($r.Detail))" }
    else {
        $app = $null
        try { $app = $r.Output | ConvertFrom-Json -ErrorAction Stop } catch { $app = $null }
        if (-not $app) { $why = 'could not be read as JSON' }
        elseif (-not [string]::Equals([string]$app.appId, $AppId, [StringComparison]::OrdinalIgnoreCase)) { $why = "names the application whose appId is $($app.appId)" }
        elseif (-not [string]::Equals([string]$app.displayName, $Expected, [StringComparison]::Ordinal)) { $why = "is named '$($app.displayName)', not '$Expected'" }
    }
    if ($why) { Stop-ClaudeInstall "the projection resolver app $AppId in the install checkpoint $why, so it is not used. Nothing was changed. Resume: $(Format-ClaudeInstallResume)" }
}

function Complete-ClaudeInstallProjection([string]$ResourceGroup, [string]$NamePrefix, $App) {
    $id = [string]$App.Id
    if (-not $id) {
        $r = Invoke-ClaudeInstallAzRead @('deployment', 'group', 'show', '-g', $ResourceGroup, '-n', "projection-resolver-$NamePrefix", '--query', 'properties.parameters.resolverAppId.value', '-o', 'tsv')
        if ($r.Verdict -eq 'present') { $id = $r.Output }
    }
    Complete-ClaudeInstallStep 'projection' -Receipt ([pscustomobject][ordered]@{ resolverAppId = $id; resolverOrigin = [string]$App.Origin })
}

function Test-ClaudeInstallResourceGroup([string]$Name) {
    $r = Invoke-ClaudeInstallAzRead @('group', 'show', '-n', $Name, '--query', 'location', '-o', 'tsv') @('ResourceGroupNotFound')
    $detail = if ($r.Verdict -eq 'absent') { "resource group $Name is gone" } else { "resource group $Name could not be read ($($r.Detail))" }
    return (Get-ClaudeInstallVerdict $r.Verdict $detail)
}

function Test-ClaudeInstallBusinessUnits([string]$ResourceGroup, [string]$ApimName, $Receipt) {
    $units = @(if ($Receipt) { $Receipt.units | Where-Object { $null -ne $_ } })
    if (-not $units.Count) { return (Get-ClaudeInstallVerdict 'present' '') }
    $r = Invoke-ClaudeInstallAzRead @('apim', 'nv', 'show', '-g', $ResourceGroup, '--service-name', $ApimName, '--named-value-id', 'bu-registry', '--query', 'value', '-o', 'tsv') @('ResourceNotFound')
    if ($r.Verdict -ne 'present') { return (Get-ClaudeInstallVerdict $r.Verdict "bu-registry could not be read ($($r.Detail))") }
    $missing = @($units | Where-Object { $r.Output -notmatch (',' + [regex]::Escape([string]$_.id) + '=') })
    if ($missing.Count) { return (Get-ClaudeInstallVerdict 'absent' "business unit $($missing[0].id) is not in bu-registry") }
    return (Get-ClaudeInstallVerdict 'present' '')
}

function Test-ClaudeInstallDeployments([string]$ResourceGroup, [string[]]$Names) {
    foreach ($n in $Names) {
        $s = Get-ClaudeInstallDeploymentState $ResourceGroup $n
        if ($s.Verdict -ne 'present') { return (Get-ClaudeInstallVerdict $s.Verdict "deployment $n is gone or unreadable ($($s.Detail))") }
        if ($s.State -ne 'Succeeded') { return (Get-ClaudeInstallVerdict 'absent' "deployment $n is $($s.State)") }
    }
    return (Get-ClaudeInstallVerdict 'present' '')
}

function Test-ClaudeInstallModelDeployment([string]$ResourceGroup, [string]$Account, [string]$Name) {
    $r = Invoke-ClaudeInstallAzRead @('cognitiveservices', 'account', 'deployment', 'show', '-g', $ResourceGroup, '-n', $Account, '--deployment-name', $Name, '--query', 'properties.provisioningState', '-o', 'tsv') @('DeploymentNotFound', 'ResourceNotFound')
    if ($r.Verdict -ne 'present') { return (Get-ClaudeInstallVerdict $r.Verdict "Claude deployment $Name is gone or unreadable ($($r.Detail))") }
    if ($r.Output -eq 'Succeeded') { return (Get-ClaudeInstallVerdict 'present' '') }
    if ($r.Output -eq 'Failed') { return (Get-ClaudeInstallVerdict 'absent' "Claude deployment $Name failed") }
    return (Get-ClaudeInstallVerdict 'inconclusive' "Claude deployment $Name is $($r.Output)")
}

function Get-ClaudeInstallPendingDeployment {
    # The Claude deployment an interrupted run recorded and Azure does not show yet, with the
    # provider answers it needs; nothing when none was recorded or it now exists (R1).
    $given = Get-Variable -Name 'PendingClaudeDeployment' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $recorded = if ($given) { $given } else { Get-ClaudeInstallAnswer 'PendingClaudeDeployment' }
    if (-not $recorded) { return $null }
    $v = Test-ClaudeInstallModelDeployment ([string]$recorded.resourceGroup) ([string]$recorded.account) ([string]$recorded.name)
    if ($v.Verdict -eq 'present') { return $null }
    if ($v.Verdict -eq 'inconclusive') { Stop-ClaudeInstall "$($v.Detail), so it is neither skipped nor created again. Nothing was changed. Resume: $(Format-ClaudeInstallResume)" }
    # The provider answers as passed, from the answers file or recorded (they are parameter answers).
    $read = { param($n) [string](Get-Variable -Name $n -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
    return [pscustomobject]@{ Deployment = $recorded; ProviderData = @{ organizationName = (& $read 'ModelOrganizationName'); industry = (& $read 'ModelIndustry'); countryCode = (& $read 'ModelCountryCode') } }
}

function Test-ClaudeInstallAddress([string]$ResourceGroup, [string]$ApimName, [string]$Hostname, [string]$RecordPath) {
    $r = Invoke-ClaudeInstallAzRead @('apim', 'show', '-g', $ResourceGroup, '-n', $ApimName, '-o', 'json') @('ResourceNotFound')
    if ($r.Verdict -ne 'present') { return (Get-ClaudeInstallVerdict $r.Verdict "API Management $ApimName could not be read ($($r.Detail))") }
    $names = @(($r.Output | ConvertFrom-Json).hostnameConfigurations | ForEach-Object { [string]$_.hostName })
    $record = if (Test-Path -LiteralPath $RecordPath) { [IO.File]::ReadAllText($RecordPath) | ConvertFrom-Json } else { $null }
    if ($names -notcontains $Hostname -or -not $record -or -not $record.address -or $record.pendingAddress) { return (Get-ClaudeInstallVerdict 'absent' "the company address $Hostname is not bound and recorded") }
    return (Get-ClaudeInstallVerdict 'present' '')
}

function Assert-ClaudeInstallDesktopApp([string]$ClientId) {
    # A supplied Desktop app is pre-existing by definition; a resume reads it by id and takes it only
    # when its appId is that id: az ad app show --id also accepts an object id (decision 8, R5).
    if (-not (Test-ClaudeInstallResuming) -or -not $ClientId) { return }
    # az ad app show --id places a value that is not a GUID inside an OData string literal,
    # identifierUris/any(s:s eq '<id>') (azure-cli 2.86.0 role/custom.py:784), so it is not read.
    if ($ClientId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        Stop-ClaudeInstall "the Claude Desktop app id '$ClientId' is not an application (client) id GUID; az ad app show --id places any other value inside an OData string literal, so it is not read. Nothing was changed."
    }
    $r = Invoke-ClaudeInstallAzRead @('ad', 'app', 'show', '--id', $ClientId, '--query', 'appId', '-o', 'tsv') $script:ClaudeInstallGraphNotFound
    if ($r.Verdict -ne 'present') { Stop-ClaudeInstall "the Claude Desktop app $ClientId is gone or unreadable ($($r.Detail)); scripts/New-ClaudeDesktopEntraApp.ps1 creates one. Nothing was changed." }
    $appId = ([string]$r.Output).Trim()
    if (-not [string]::Equals($appId, $ClientId, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-ClaudeInstall "the Claude Desktop app id $ClientId names the application whose appId is $(if ($appId) { $appId } else { 'empty' }), so it is not used. Nothing was changed. Resume: $(Format-ClaudeInstallResume)"
    }
}
