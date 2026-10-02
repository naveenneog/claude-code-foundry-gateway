# The installer preflight (docs/adr/0047-lean-installer-phase-0.md): the 14 checks that
# schemas/claude-gateway.answers.schema.json lists in x-preflightChecks, from the answers and from
# read-only Azure CLI reads, for Install-ClaudeGateway.ps1 -Preflight and Start-ClaudeGateway.ps1
# -PlanOnly. A check that cannot run is NOT-RUN with its reason and never passes (P91 R1). Every check starts
# NOT-RUN (not-evaluated), so a check passes only where a branch passes it with a message. Nothing is
# written: no create, update, set or delete call, no az account set, no checkpoint. scripts/install-preflight.sh
# is the bash engine. Runs on Windows PowerShell 5.1 and PowerShell 7.

. (Join-Path $PSScriptRoot 'ClaudeInstallerAnswers.ps1')
if (-not (Get-Command Test-ClaudePrerequisites -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Test-Prerequisites.ps1') }
# A NOT-RUN with one of these reasons fails the preflight; not-applicable, not-answered and
# discovery-skipped do not.
$script:ClaudePreflightBlocking = @('not-signed-in', 'prerequisite-failed')
# The reason every check starts with. It also fails the preflight: a check that no branch evaluated is a
# defect of the preflight, not a pass (ADR-0047 decision 5).
$script:ClaudePreflightUnevaluated = 'not-evaluated'

function Get-ClaudeApimReuseState {
    # The API Management instance to reuse, read once for the preflight and for the run's reuse path:
    # present with its tier and identity, absent, or inconclusive (P91 R1). Its problems: a classic tier,
    # which meters no Anthropic tokens, and no system-assigned identity, whose principal main.bicep
    # grants Cognitive Services User on the Foundry account (infra/main.bicep:511, docs/UNKNOWNS.md U86).
    param([Parameter(Mandatory = $true)][string]$Name, [string]$ResourceGroup, [string]$Subscription)
    $sub = @(if ($Subscription) { '--subscription', $Subscription })
    $state = [pscustomobject]@{ Verdict = 'inconclusive'; Detail = ''; Instance = $null; ResourceGroup = $ResourceGroup; Sku = ''; IdentityType = ''; SkuProblem = $null; IdentityProblem = $null }
    $r = if ($ResourceGroup) { Invoke-ClaudeInstallAzRead (@('apim', 'show', '-g', $ResourceGroup, '-n', $Name, '-o', 'json') + $sub) @('ResourceNotFound') } else { Invoke-ClaudeInstallAzRead (@('apim', 'list', '-o', 'json') + $sub) }
    $where = if ($ResourceGroup) { " in resource group $ResourceGroup" } else { ' in the subscription' }
    if ($r.Verdict -eq 'absent') { $state.Verdict = 'absent'; $state.Detail = "API Management $Name was not found$where"; return $state }
    if ($r.Verdict -ne 'present') { $state.Detail = "API Management $Name could not be read ($($r.Detail))"; return $state }
    try { $found = @($r.Output | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ }) } catch { $state.Detail = "API Management $Name could not be read as JSON"; return $state }
    $instance = @($found | Where-Object { $_ -and [string]$_.name -eq $Name })[0]
    if (-not $instance) { $state.Verdict = 'absent'; $state.Detail = "API Management $Name was not found$where"; return $state }
    $state.Verdict = 'present'; $state.Instance = $instance
    if ($instance.resourceGroup) { $state.ResourceGroup = [string]$instance.resourceGroup }
    $state.Sku = [string]$instance.sku.name; $state.IdentityType = [string]$instance.identity.type
    $problems = Get-ClaudeApimReuseProblems -Instance $instance
    $state.SkuProblem = $problems.SkuProblem; $state.IdentityProblem = $problems.IdentityProblem
    return $state
}

function Get-ClaudeApimReuseProblems {
    # What stops an instance from being reused, as az apim show or az apim list returns it: a classic tier,
    # or no system-assigned identity. Each is a message and its remedy.
    param([Parameter(Mandatory = $true)]$Instance)
    $name = [string]$Instance.name; $sku = [string]$Instance.sku.name; $type = [string]$Instance.identity.type
    $skuProblem = $null; $identityProblem = $null
    if ($sku -notmatch 'V2$') {
        $skuProblem = [pscustomobject]@{ message = "$name is $sku; only the v2 tiers meter Anthropic tokens, so every budget would read zero"
            remedy = 'Reuse a BasicV2, StandardV2 or PremiumV2 instance, or leave ExistingApimName out to create one.' }
    }
    if ($type -notmatch 'SystemAssigned') {
        $identityProblem = [pscustomobject]@{
            message = "$name has no system-assigned managed identity (identity type $(if ($type) { $type } else { 'none' })); main.bicep grants that identity Cognitive Services User on the Foundry account (infra/main.bicep:511)"
            remedy = "Azure portal > $name > Security > Managed identities > System assigned: On > Save, then run again with -ExistingApimName $name." }
    }
    return [pscustomobject]@{ SkuProblem = $skuProblem; IdentityProblem = $identityProblem }
}

function Get-ClaudeApimReuseCandidates {
    # The v2 instances the installer's menu offers for reuse, read through the P91 verdict reader as
    # Get-ClaudeApimReuseState reads one instance: present with the list, or inconclusive with its detail.
    $r = Invoke-ClaudeInstallAzRead @('apim', 'list', '-o', 'json')
    $state = [pscustomobject]@{ Verdict = $r.Verdict; Detail = $r.Detail; Instances = @() }
    if ($r.Verdict -ne 'present') { return $state }
    try { $all = @($r.Output | ConvertFrom-Json -ErrorAction Stop | ForEach-Object { $_ }) }
    catch { $state.Verdict = 'inconclusive'; $state.Detail = 'az apim list did not return JSON'; return $state }
    $state.Instances = @($all | Where-Object { $_ -and [string]$_.sku.name -match 'V2$' })
    return $state
}

function Get-ClaudePreflightPrerequisites {
    # operator.adminPrereqs: Test-ClaudePrerequisites -Mode Admin (scripts/Test-Prerequisites.ps1:27),
    # its console lines captured so that -Json prints JSON only. A stop of the check itself, for example on
    # az output that is not JSON (scripts/Test-Prerequisites.ps1:166), is a failure of the check.
    try { $out = @(Test-ClaudePrerequisites -Mode Admin 6>&1) }
    catch { return [pscustomobject]@{ Ok = $false; Fails = @("Test-ClaudePrerequisites -Mode Admin stopped ($($_.Exception.Message))"); Warnings = @() } }
    $ok = [bool]@($out | Where-Object { $_ -is [bool] })[-1]
    $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
    $grab = { param([string]$Tag) @($lines | Where-Object { $_ -match "^\s*\[$Tag\]\s+(.+)$" } | ForEach-Object { ($_ -replace "^\s*\[$Tag\]\s+", '').Trim() }) }
    return [pscustomobject]@{ Ok = $ok; Fails = @(& $grab 'FAIL'); Warnings = @(& $grab 'WARN') }
}

function Add-ClaudePreflightProblem($Check, [string]$Message, [string]$Remedy) { $Check.problems.Add([pscustomobject][ordered]@{ message = $Message; remedy = $Remedy }) }
function Set-ClaudePreflightPass($Check, [string]$Message) {
    # The only way to PASS: a check with no problem, which no branch has set NOT-RUN, and a message.
    if ($Check.problems.Count -or -not $Message.Trim()) { return }
    if ($Check.result -eq 'NOT-RUN' -and $Check.reason -ne $script:ClaudePreflightUnevaluated) { return }
    $Check.result = 'PASS'; $Check.reason = $null; $Check.message = $Message; $Check.remedy = ''
}
function Set-ClaudePreflightNotRun($Check, [string]$Reason, [string]$Message, [string]$Remedy = '') {
    # A check with a problem from the answers fails on it; one that cannot run otherwise never passes.
    if (-not $Check.problems.Count) { $Check.result = 'NOT-RUN'; $Check.reason = $Reason; $Check.message = $Message; $Check.remedy = $Remedy }
}
function Get-ClaudePreflightAnswer([System.Collections.IDictionary]$Answers, [hashtable]$Bad, [string]$Name) {
    # An answer to read from Azure: given, and without a problem of its own.
    if ($Bad.ContainsKey($Name) -or -not $Answers.Contains($Name)) { return $null }
    $v = $Answers[$Name]
    if ($null -eq $v -or "$v" -eq '') { return $null }
    # A list is returned as its items: callers that read a list wrap the call in @().
    return $v
}

function Invoke-ClaudeGatewayPreflight {
    # The 14 checks over a set of answers (installer names) and the validator's problems with them.
    # -SkipAzureReason: the Azure checks, and the admin prerequisites that read Azure, are NOT-RUN with
    # that reason and -SkipAzureMessage (the guided flow: discovery-skipped, or not-answered without a subscription).
    param([System.Collections.IDictionary]$Answers = @{}, [object[]]$AnswerProblems = @(), [ValidateSet('pwsh', 'bash')][string]$Installer = 'pwsh',
        [ValidateSet('', 'discovery-skipped', 'not-answered')][string]$SkipAzureReason = '', [string]$SkipAzureMessage = '')
    $checks = [ordered]@{}
    foreach ($id in @((Get-ClaudeAnswersSchema).Document.'x-preflightChecks' | ForEach-Object { [string]$_.id })) {
        $checks[$id] = [pscustomobject][ordered]@{ id = $id; result = 'NOT-RUN'; message = 'no branch of the preflight evaluated this check'; remedy = ''
            reason = $script:ClaudePreflightUnevaluated; problems = [System.Collections.Generic.List[object]]::new() }
    }
    $bad = @{}
    foreach ($p in @($AnswerProblems)) { Add-ClaudePreflightProblem $checks[$p.checkId] $p.message $p.remedy; $bad[(([string]$p.path) -split '[.\[]')[0]] = $true }
    $get = { param([string]$Name) Get-ClaudePreflightAnswer $Answers $bad $Name }
    Set-ClaudePreflightPass $checks['answers.schema'] 'the answers match the answers schema, version 1'
    Set-ClaudePreflightPass $checks['answers.crossField'] 'the answers that depend on each other agree'
    $azure = @('target.tenant', 'target.subscription', 'foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity', 'entra.groupNames')
    if ($SkipAzureReason) {
        foreach ($id in @('operator.adminPrereqs') + $azure) { Set-ClaudePreflightNotRun $checks[$id] $SkipAzureReason $SkipAzureMessage }
    }
    else {
        $pre = Get-ClaudePreflightPrerequisites
        if ($pre.Ok -and -not $pre.Fails.Count) { Set-ClaudePreflightPass $checks['operator.adminPrereqs'] ('Test-ClaudePrerequisites -Mode Admin passed' + $(if ($pre.Warnings.Count) { "; warnings: $($pre.Warnings -join '; ')" })) }
        else { foreach ($f in @(if ($pre.Fails.Count) { $pre.Fails } else { 'Test-ClaudePrerequisites -Mode Admin failed' })) { Add-ClaudePreflightProblem $checks['operator.adminPrereqs'] $f 'Test-ClaudePrerequisites -Mode Admin (scripts/Test-Prerequisites.ps1) prints the remedy under each [FAIL] line.' } }
        $acct = Invoke-ClaudeInstallAzRead @('account', 'show', '-o', 'json')
        # The signed-in account as JSON with its tenant; output that is not JSON, or has no tenantId, is
        # inconclusive, as an unreadable account is.
        $account = $null; $unread = ''
        if ($acct.Verdict -eq 'present') {
            $parsed = $true
            try { if (-not $acct.Output) { throw 'empty' }; $account = $acct.Output | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $false }
            $unread = if (-not $parsed) { 'az account show did not return JSON' } elseif (-not [string]$account.tenantId) { 'az account show returned no tenantId' } else { '' }
        }
        if ($acct.Verdict -ne 'present' -and $acct.Error -match 'az login') {
            foreach ($id in $azure) { Set-ClaudePreflightNotRun $checks[$id] 'not-signed-in' 'Azure CLI is not signed in, so this was not read' 'Run az login (az login --tenant <tenant-id> as a guest), then run the preflight again.' }
        }
        elseif ($acct.Verdict -ne 'present' -or $unread) {
            Add-ClaudePreflightProblem $checks['target.tenant'] "the signed-in account could not be read ($(if ($unread) { $unread } else { $acct.Detail }))" 'Check az account show, then run the preflight again.'
            foreach ($id in $azure | Select-Object -Skip 1) { Set-ClaudePreflightNotRun $checks[$id] 'prerequisite-failed' 'target.tenant failed, so this was not read' 'Correct target.tenant first.' }
        }
        else { Invoke-ClaudeGatewayPreflightAzure -Checks $checks -Answers $Answers -Bad $bad -Account $account -Installer $Installer }
    }
    if (-not $Answers.Contains('BusinessUnits')) { foreach ($id in 'businessUnits.ids', 'businessUnits.depth') { Set-ClaudePreflightNotRun $checks[$id] 'not-answered' 'BusinessUnits is not answered' } }
    else {
        $n = @($Answers['BusinessUnits']).Count
        Set-ClaudePreflightPass $checks['businessUnits.ids'] "$n units and teams; each id is lower-case and given once"
        Set-ClaudePreflightPass $checks['businessUnits.depth'] "$n units and teams; each team's parent is a unit without a parent (two levels)"
    }
    $mode = & $get 'AddressMode'
    if ($mode -eq 'custom') {
        $pfx = & $get 'AddressPfxPath'
        if ((& $get 'AddressCertificateSource') -eq 'Pfx' -and $pfx -and -not (Test-Path -LiteralPath $pfx -PathType Leaf)) { Add-ClaudePreflightProblem $checks['address.inputs'] "AddressPfxPath '$pfx' is not a file" 'Give the path of the PFX file, absolute or relative to the current directory.' }
        Set-ClaudePreflightPass $checks['address.inputs'] "custom address $(& $get 'AddressHostname'): certificate from $(& $get 'AddressCertificateSource'), DNS $(& $get 'AddressDnsMode')"
    }
    elseif ($mode -eq 'azure') { Set-ClaudePreflightNotRun $checks['address.inputs'] 'not-applicable' "AddressMode is azure: the gateway's own address needs no inputs" }
    else { Set-ClaudePreflightNotRun $checks['address.inputs'] 'not-answered' 'AddressMode is not answered; the run asks for it, azure by default' }
    $list = @(foreach ($c in $checks.Values) {
            if ($c.problems.Count) { $c.result = 'FAIL'; $c.reason = $null; $c.message = (@($c.problems | ForEach-Object { $_.message }) -join '; '); $c.remedy = (@($c.problems | ForEach-Object { $_.remedy } | Select-Object -Unique) -join ' ') }
            $c })
    $blocking = @($list | Where-Object { $_.result -eq 'FAIL' -or ($_.result -eq 'NOT-RUN' -and ($_.reason -in $script:ClaudePreflightBlocking -or $_.reason -eq $script:ClaudePreflightUnevaluated)) })
    return [pscustomobject][ordered]@{ schemaVersion = 1; installer = $Installer; answersSchemaVersion = 1; result = $(if ($blocking.Count) { 'FAIL' } else { 'PASS' }); checks = $list }
}
function Invoke-ClaudeGatewayPreflightAzure {
    # The checks that read Azure, once Azure CLI is signed in. Each read names the answered subscription
    # with --subscription, so the preflight leaves the CLI's own subscription alone (az account set writes it).
    param($Checks, [System.Collections.IDictionary]$Answers, [hashtable]$Bad, $Account, [string]$Installer)
    $get = { param([string]$Name) Get-ClaudePreflightAnswer $Answers $Bad $Name }
    $tenant = [string]$Account.tenantId; $user = [string]$Account.user.name
    $sub = @(); $subOk = -not $Bad.ContainsKey('SubscriptionId')
    $subId = & $get 'SubscriptionId'
    if ($subId) {
        $s = Invoke-ClaudeInstallAzRead @('account', 'show', '--subscription', $subId, '-o', 'json')
        $so = $null
        if ($s.Verdict -eq 'present') { try { $so = $s.Output | ConvertFrom-Json -ErrorAction Stop } catch { $so = $null } }
        if (-not $so) { $subOk = $false; Add-ClaudePreflightProblem $Checks['target.subscription'] "subscription '$subId' is not readable by $user ($($s.Detail))" 'Check it with az account list -o table, or sign in to the tenant that holds it.' }
        else {
            $sub = @('--subscription', [string]$so.id)
            if ($so.state -and [string]$so.state -ne 'Enabled') { $subOk = $false; Add-ClaudePreflightProblem $Checks['target.subscription'] "subscription $($so.name) ($($so.id)) is $($so.state)" 'Use an enabled subscription.' }
            Set-ClaudePreflightPass $Checks['target.subscription'] "subscription $($so.name) ($($so.id))"
            if ($so.tenantId -and [string]$so.tenantId -ne $tenant) { Add-ClaudePreflightProblem $Checks['target.tenant'] "subscription $($so.name) is in tenant $($so.tenantId), and Azure CLI is signed in to tenant $tenant" "Run az login --tenant $($so.tenantId), then run the preflight again." }
        }
    }
    elseif ($subOk) { Set-ClaudePreflightPass $Checks['target.subscription'] "SubscriptionId is not answered; the run uses the current subscription $($Account.name) ($($Account.id))" }
    Set-ClaudePreflightPass $Checks['target.tenant'] "signed in as $user in tenant $tenant"
    $later = @('foundry.account', 'foundry.deployments', 'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity')
    if (-not $subOk) { foreach ($id in $later) { Set-ClaudePreflightNotRun $Checks[$id] 'prerequisite-failed' 'target.subscription failed, so this was not read' 'Correct target.subscription first.' } }
    else {
        $fa = & $get 'FoundryAccount'; $frg = & $get 'FoundryResourceGroup'
        if (-not $fa) {
            $reason = if ($Bad.ContainsKey('FoundryAccount')) { 'prerequisite-failed' } else { 'not-answered' }
            Set-ClaudePreflightNotRun $Checks['foundry.account'] 'not-answered' 'FoundryAccount is not answered; the run looks for an account with a Claude deployment'
            Set-ClaudePreflightNotRun $Checks['foundry.deployments'] $reason 'no Foundry account to read the deployments of'
        }
        else {
            $where = if ($frg) { " in resource group $frg" } else { ' in the subscription' }
            if ($frg) { $r = Invoke-ClaudeInstallAzRead (@('cognitiveservices', 'account', 'show', '-g', $frg, '-n', $fa, '-o', 'json') + $sub) @('ResourceNotFound') }
            else {
                $r = Invoke-ClaudeInstallAzRead (@('cognitiveservices', 'account', 'list', '-o', 'json') + $sub)
                if ($r.Verdict -eq 'present') {
                    # A list that is not JSON is inconclusive, as an unreadable list is.
                    $parsed = $null
                    try { if (-not $r.Output) { throw 'empty' }; $parsed = $r.Output | ConvertFrom-Json -ErrorAction Stop }
                    catch { $r = [pscustomobject]@{ Verdict = 'inconclusive'; Detail = 'az cognitiveservices account list did not return JSON' } }
                }
                if ($r.Verdict -eq 'present') {
                    $hit = @(@($parsed) | Where-Object { $_ -and [string]$_.name -eq $fa })[0]
                    if ($hit) { $frg = [string]$hit.resourceGroup } else { $r = [pscustomobject]@{ Verdict = 'absent'; Detail = '' } }
                }
            }
            if ($r.Verdict -eq 'present') { Set-ClaudePreflightPass $Checks['foundry.account'] "Foundry account $fa$where" }
            elseif ($r.Verdict -eq 'absent') { Add-ClaudePreflightProblem $Checks['foundry.account'] "Foundry account $fa was not found$where" 'Check the name and resource group with az cognitiveservices account list -o table.' }
            else { Add-ClaudePreflightProblem $Checks['foundry.account'] "Foundry account $fa could not be read ($($r.Detail))" 'Check access with az cognitiveservices account show, then run the preflight again.' }
            if ($r.Verdict -ne 'present') { Set-ClaudePreflightNotRun $Checks['foundry.deployments'] 'prerequisite-failed' 'foundry.account failed, so the deployments were not read' 'Correct foundry.account first.' }
            else {
                $d = Invoke-ClaudeInstallAzRead (@('cognitiveservices', 'account', 'deployment', 'list', '-g', $frg, '-n', $fa, '-o', 'json') + $sub) @('ResourceNotFound')
                $list = @()
                if ($d.Verdict -eq 'present') { try { $parsed = $d.Output | ConvertFrom-Json -ErrorAction Stop; $list = @($parsed | Where-Object { $_ }) } catch { $d = [pscustomobject]@{ Verdict = 'inconclusive'; Detail = 'the deployment list is not JSON' } } }
                if ($d.Verdict -ne 'present') { Add-ClaudePreflightProblem $Checks['foundry.deployments'] "the deployments of $fa could not be read ($($d.Detail))" 'Check access with az cognitiveservices account deployment list, then run the preflight again.' }
                else {
                    $names = @($list | ForEach-Object { [string]$_.name } | Where-Object { $_ })
                    $claude = @($list | Where-Object { [string]$_.properties.model.format -eq 'Anthropic' -or [string]$_.properties.model.name -like '*claude*' } | ForEach-Object { [string]$_.name })
                    $wanted = @(@(& $get 'StandardModels') + @(& $get 'PremiumModels') | Where-Object { $_ } | Select-Object -Unique)
                    $missing = @($wanted | Where-Object { $names -notcontains $_ })
                    if ($missing.Count) { Add-ClaudePreflightProblem $Checks['foundry.deployments'] "the Foundry account $fa has no deployment named $($missing -join ', ')" "Deploy it in Microsoft Foundry, or answer StandardModels and PremiumModels with deployed names: $(if ($names.Count) { $names -join ', ' } else { 'none' })." }
                    elseif ($wanted.Count) { Set-ClaudePreflightPass $Checks['foundry.deployments'] "deployed on ${fa}: $($wanted -join ', ')" }
                    elseif ($claude.Count) { Set-ClaudePreflightPass $Checks['foundry.deployments'] "$($claude.Count) Claude deployment(s) on ${fa}: $($claude -join ', ')" }
                    elseif (& $get 'PendingClaudeDeployment') { Set-ClaudePreflightPass $Checks['foundry.deployments'] "no Claude deployment on $fa yet; the run creates PendingClaudeDeployment after its summary" }
                    else { Add-ClaudePreflightProblem $Checks['foundry.deployments'] "the Foundry account $fa has no Claude deployment" 'Deploy a Claude model in Microsoft Foundry, or answer PendingClaudeDeployment.' }
                }
            }
        }
        $existing = & $get 'ExistingApimName'; $rg = & $get 'ResourceGroup'; $prefix = & $get 'NamePrefix'
        if ($Answers.Contains('ExistingApimName') -and $Answers['ExistingApimName']) { Set-ClaudePreflightNotRun $Checks['apim.nameAvailability'] 'not-applicable' 'ExistingApimName is answered: the run reuses that instance and creates no name' }
        elseif (-not $prefix) { Set-ClaudePreflightNotRun $Checks['apim.nameAvailability'] 'not-answered' 'NamePrefix is not answered; the run asks for one, claudegw<6 digits> by default' }
        else {
            $name = "apim-$prefix"
            $r = Invoke-ClaudeInstallAzRead (@('apim', 'check-name', '-n', $name, '-o', 'json') + $sub)
            $res = $null
            if ($r.Verdict -eq 'present') { try { $res = $r.Output | ConvertFrom-Json -ErrorAction Stop } catch { $res = $null } }
            if (-not $res -or $null -eq $res.nameAvailable) { Add-ClaudePreflightProblem $Checks['apim.nameAvailability'] "whether $name is free could not be read ($($r.Detail))" "Check az apim check-name -n $name, then run the preflight again." }
            elseif ($res.nameAvailable) { Set-ClaudePreflightPass $Checks['apim.nameAvailability'] "$name is available" }
            else {
                $m = if ($rg) { Invoke-ClaudeInstallAzRead (@('apim', 'show', '-g', $rg, '-n', $name, '--query', 'name', '-o', 'tsv') + $sub) @('ResourceNotFound') } else { [pscustomobject]@{ Verdict = 'absent'; Detail = '' } }
                if ($m.Verdict -eq 'present') { Set-ClaudePreflightPass $Checks['apim.nameAvailability'] "$name exists in resource group $rg; the run updates it" }
                elseif ($m.Verdict -eq 'absent') { Add-ClaudePreflightProblem $Checks['apim.nameAvailability'] "$name is taken by another API Management instance ($($res.reason))" 'Answer another NamePrefix: apim-<NamePrefix> is a globally unique DNS name.' }
                else { Add-ClaudePreflightProblem $Checks['apim.nameAvailability'] "$name is taken, and whether it is the one in $rg could not be read ($($m.Detail))" "Check az apim show -g $rg -n $name, then run the preflight again." }
            }
        }
        if (-not $existing) {
            $reason = if ($Bad.ContainsKey('ExistingApimName')) { 'prerequisite-failed' } else { 'not-applicable' }
            Set-ClaudePreflightNotRun $Checks['apim.existingSku'] 'not-applicable' 'ExistingApimName is not answered: the run creates apim-<NamePrefix>'
            Set-ClaudePreflightNotRun $Checks['apim.existingIdentity'] $reason 'ExistingApimName is not answered, or it has a problem: no instance to read'
        }
        else {
            $state = Get-ClaudeApimReuseState -Name $existing -ResourceGroup $rg -Subscription $(if ($sub.Count) { $sub[1] } else { '' })
            if ($state.Verdict -ne 'present') {
                Add-ClaudePreflightProblem $Checks['apim.existingSku'] $state.Detail $(if ($state.Verdict -eq 'absent') { 'Check the name and resource group with az apim list -o table.' } else { 'Check access with az apim show, then run the preflight again.' })
                Set-ClaudePreflightNotRun $Checks['apim.existingIdentity'] 'prerequisite-failed' 'apim.existingSku failed, so the identity was not read' 'Correct apim.existingSku first.'
            }
            else {
                if ($state.SkuProblem) { Add-ClaudePreflightProblem $Checks['apim.existingSku'] $state.SkuProblem.message $state.SkuProblem.remedy }
                Set-ClaudePreflightPass $Checks['apim.existingSku'] "$existing is $($state.Sku) in resource group $($state.ResourceGroup)"
                if ($state.IdentityProblem) { Add-ClaudePreflightProblem $Checks['apim.existingIdentity'] $state.IdentityProblem.message $state.IdentityProblem.remedy }
                Set-ClaudePreflightPass $Checks['apim.existingIdentity'] "$existing has a system-assigned managed identity"
            }
        }
    }
    # Entra groups are read from the tenant, with or without a subscription: the tier groups, and for
    # Install-ClaudeGateway.ps1 the groups of its business units, each by the name rule of ADR-0046 decision 11.
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($n in 'StandardGroup', 'PremiumGroup') {
        if ($Bad.ContainsKey($n)) { continue }
        $v = if ($Answers.Contains($n) -and $Answers[$n]) { [string]$Answers[$n] } elseif ($n -eq 'StandardGroup') { 'claude-code-standard' } else { 'claude-code-premium' }
        if (-not $names.Contains($v)) { $names.Add($v) }
    }
    if ($Installer -eq 'pwsh') { foreach ($u in @(& $get 'BusinessUnits')) { $g = [string](Get-ClaudeAnswersField $u 'group'); if ($g -and -not $names.Contains($g)) { $names.Add($g) } } }
    $notes = @()
    foreach ($name in $names) {
        $found = Find-ClaudeInstallGroupByName $name
        if ($found.Verdict -eq 'present') { $notes += "'$name' exists ($($found.Id))" }
        elseif ($found.Verdict -eq 'absent') { $notes += "'$name' is created by the run" }
        elseif ($found.Detail -match 'groups have a name of that length') { Add-ClaudePreflightProblem $Checks['entra.groupNames'] "Entra group '$name' is not one group: $($found.Detail)" 'Rename or remove one of those groups, or answer another group name.' }
        else { Add-ClaudePreflightProblem $Checks['entra.groupNames'] "Entra group '$name' could not be looked up by name ($($found.Detail))" 'Sign in with an account that can read Entra groups in Microsoft Graph, for example one with the Directory Readers role, then run the preflight again.' }
    }
    Set-ClaudePreflightPass $Checks['entra.groupNames'] "Entra groups: $($notes -join '; ')"
}

function Format-ClaudeGatewayPreflight {
    # The text report: a count line, then one line per check, and one per problem of a failed check.
    param([Parameter(Mandatory = $true)]$Result)
    $count = { param([string]$R) @($Result.checks | Where-Object { $_.result -eq $R }).Count }
    "Preflight: $(@($Result.checks).Count) checks; $(& $count 'PASS') PASS, $(& $count 'FAIL') FAIL, $(& $count 'NOT-RUN') NOT-RUN."
    foreach ($c in $Result.checks) {
        if ($c.result -eq 'FAIL') { foreach ($p in $c.problems) { "[FAIL] $($c.id): $($p.message)$(if ($p.remedy) { " Remedy: $($p.remedy)" })" } }
        elseif ($c.result -eq 'NOT-RUN') { "[NOT-RUN] $($c.id): $($c.message) ($($c.reason))$(if ($c.remedy) { " Remedy: $($c.remedy)" })" }
        else { "[PASS] $($c.id): $($c.message)" }
    }
}

function Get-ClaudeInstallerPreflightAnswers {
    # The answers of a preflight: the answers file, then the parameters this run names over it (A12),
    # without run options and secrets, and every problem the answers schema finds with them.
    param([System.Collections.IDictionary]$Bound = @{}, [string]$AnswersPath, [ValidateSet('Install-ClaudeGateway.ps1', 'install-claude-gateway.sh', 'Start-ClaudeGateway.ps1')][string]$Consumer = 'Install-ClaudeGateway.ps1')
    $S = Get-ClaudeAnswersSchema
    $answers = [ordered]@{}; $problems = @()
    if ($AnswersPath) {
        $read = Read-ClaudeInstallerAnswersFile -Path $AnswersPath
        $problems += @($read.Problems)
        if ($read.Document) { foreach ($p in $read.Document.PSObject.Properties) { $answers[$p.Name] = $p.Value } }
    }
    foreach ($k in @($Bound.Keys)) {
        if ($S.Controls.ContainsKey([string]$k) -or $S.Secrets.ContainsKey([string]$k)) { continue }
        $v = $Bound[$k]
        if ($null -eq $v) { continue }
        if ($v -is [System.Management.Automation.SwitchParameter]) { $v = [bool]$v }
        $answers[[string]$k] = $v
    }
    $problems += @(Test-ClaudeInstallerAnswers -Answers $answers -Consumer $Consumer)
    return [pscustomobject]@{ Answers = $answers; Problems = @($problems) }
}

function Write-ClaudeGatewayPreflight {
    # The report on the output stream: JSON only with -Json (schemaVersion 1), otherwise the text lines.
    param([Parameter(Mandatory = $true)]$Result, [switch]$Json)
    if ($Json) { return ($Result | ConvertTo-Json -Depth 6) }
    Format-ClaudeGatewayPreflight -Result $Result | ForEach-Object { "  $_" }
}

function Get-ClaudeInstallPreflightResult {
    # Install-ClaudeGateway.ps1 -Preflight: the answers file under the parameters passed, then the checks.
    param([System.Collections.IDictionary]$Bound = @{})
    $in = Get-ClaudeInstallerPreflightAnswers -Bound $Bound -AnswersPath ([string]$Bound['AnswersPath'])
    return (Invoke-ClaudeGatewayPreflight -Answers $in.Answers -AnswerProblems $in.Problems -Installer pwsh)
}
