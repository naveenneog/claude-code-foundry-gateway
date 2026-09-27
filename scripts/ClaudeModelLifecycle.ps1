# ADR-0034: reviewed model reconciliation; dot-sourcing performs no Azure calls.
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'flow\lib\LifecycleCommon.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChoice.ps1')
. (Join-Path $PSScriptRoot 'ClaudeModelDeployment.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
. (Join-Path $PSScriptRoot 'ClaudeClientSupport.ps1')
. (Join-Path $PSScriptRoot 'ClaudeModelPrices.ps1')
. (Join-Path $PSScriptRoot 'ClaudeModelProfiles.ps1')

function Invoke-ClaudeModelWait {
    param([string]$What, [int]$AboutSeconds, [scriptblock]$Run)
    Write-Host "$What (about $AboutSeconds s)..." -ForegroundColor DarkGray
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { & $Run }
    finally { Write-Host ("  completed in {0:N1} s: {1}" -f $clock.Elapsed.TotalSeconds, $What) -ForegroundColor DarkGray }
}

function Invoke-ClaudeModelAz {
    param([string[]]$Arguments, [string]$What, [string]$SubscriptionId, [switch]$Array)
    if ($SubscriptionId) { $Arguments += @('--subscription', $SubscriptionId) }
    $text = Invoke-ClaudeModelWait -What $What -AboutSeconds 4 -Run {
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            $output = @(& az @Arguments -o json --only-show-errors 2>&1)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $saved }
        if ($code -ne 0) { throw "$What failed (az exit $code). Check the selected subscription, read permission and Azure sign-in; no discovery result is assumed." }
        return ($output -join "`n")
    }
    if (-not $text -or ($Array -and -not $text.TrimStart().StartsWith('[')) -or
        (-not $Array -and -not $text.TrimStart().StartsWith('{'))) { throw "$What returned an invalid JSON $(if ($Array) { 'array' } else { 'object' })." }
    $parsed = $text | ConvertFrom-Json
    return ,$parsed
}

function Assert-ClaudeModelName {
    param($Value, [string]$Label)
    if ($Value -isnot [string] -or $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "$Label must be a scalar name containing letters, digits, periods, underscores or hyphens; unsafe characters cannot reach az.cmd."
    }
}

function Get-ClaudeModelTarget {
    param($Record)
    if ($Record.mode -and $Record.mode -ne 'gateway') { throw 'Model lifecycle requires a gateway record, not a direct-Foundry mode.' }
    $target = Get-ClaudeFlowLifecycleRecordTarget -Record $Record
    $foundation = Get-ClaudeDecision -Record $Record -Key foundation
    foreach ($key in 'subscriptionId','resourceGroup','apimName','foundryAccount','foundryResourceGroup') {
        $value = if ($Record.PSObject.Properties.Name -contains $key -and $Record.$key) { $Record.$key } elseif ($foundation -and $foundation.$key) { $foundation.$key } else { '' }
        if ($value -and $value -isnot [string]) { throw "Target $key must be a scalar string." }
        if ($key -ne 'subscriptionId') { Assert-ClaudeModelName $value $key }
        Set-ClaudeRecordProperty $target $key $value
    }
    $tenantId = if ($Record.tenantId) { $Record.tenantId } else { '' }
    if ($target.SubscriptionId -and -not (Test-ClaudeFlowSubscriptionId $target.SubscriptionId)) { throw 'The model target subscription must be a subscription GUID before account discovery.' }
    if (-not $target.SubscriptionId -or -not $tenantId) {
        $account = Invoke-ClaudeModelAz -Arguments @('account','show') -What 'Reading the selected Azure account' -SubscriptionId $target.SubscriptionId
        if (-not $target.SubscriptionId) { $target.SubscriptionId = [string]$account.id }
        if (-not $tenantId) { $tenantId = [string]$account.tenantId }
    }
    if (-not (Test-ClaudeFlowSubscriptionId $target.SubscriptionId)) { throw 'The model target subscription must be a subscription GUID, not a name.' }
    if ($tenantId -isnot [string] -or -not (Test-ClaudeFlowSubscriptionId $tenantId)) { throw 'The model target tenantId must be a tenant GUID.' }
    Set-ClaudeRecordProperty $target 'tenantId' $tenantId
    return $target
}

function Get-ClaudeModelDiscovery {
    param([Parameter(Mandatory = $true)]$Target)
    $scope = @{ SubscriptionId = $Target.SubscriptionId }
    $gateway = Invoke-ClaudeModelAz @scope -Arguments @('apim','show','-g',$Target.ResourceGroup,'-n',$Target.ApimName) -What "Reading gateway $($Target.ApimName)"
    $foundry = Invoke-ClaudeModelAz @scope -Arguments @('cognitiveservices','account','show','-g',$Target.foundryResourceGroup,'-n',$Target.foundryAccount) -What "Reading Foundry account $($Target.foundryAccount)"
    $api = Invoke-ClaudeModelAz @scope -Arguments @('apim','api','show','-g',$Target.ResourceGroup,'--service-name',$Target.ApimName,'--api-id','claude-foundry') -What 'Reading the gateway Foundry backend'
    $endpoints = if ($foundry.properties -and $foundry.properties.endpoints) { $foundry.properties.endpoints } else { $foundry.endpoints }
    $expected = if ($endpoints -and $endpoints.'AI Foundry API') { ([string]$endpoints.'AI Foundry API').TrimEnd('/') + '/anthropic' } else { '' }
    if (-not $expected -or ([string]$api.serviceUrl).TrimEnd('/') -ne $expected) { throw 'The gateway backend does not match the selected Foundry account. The account and gateway must describe the same deployment path.' }
    if (-not $gateway.id -or -not $gateway.gatewayUrl) { throw 'Gateway discovery returned no resource id or gateway URL.' }
    $raw = Invoke-ClaudeModelAz @scope -Arguments @('cognitiveservices','account','deployment','list','-n',$Target.foundryAccount,'-g',$Target.foundryResourceGroup) -What 'Reading Foundry Claude deployments' -Array
    $deployments = @(Select-ClaudeDeployment (@($raw) | ConvertTo-FlatDeployment) | Sort-Object name)
    $seen = @{}
    foreach ($d in $deployments) {
        Assert-ClaudeModelName $d.name 'Deployment name'
        if ($seen.ContainsKey($d.name)) { throw "Duplicate deployment name '$($d.name)' in Foundry discovery." }
        $seen[$d.name] = $true
        if (-not $d.model -or -not $d.version -or -not $d.sku -or -not $d.state) { throw "Deployment '$($d.name)' has incomplete model/version/SKU/provisioning state." }
    }
    $rows = Invoke-ClaudeModelAz @scope -Arguments @('apim','nv','list','-g',$Target.ResourceGroup,'--service-name',$Target.ApimName) -What 'Reading tier model lists and governance ownership' -Array
    $named = @{}
    foreach ($row in @($rows)) {
        if ($row.name -notin @('models-standard','models-premium','turnstile-integration')) { continue }
        $p = if ($row.properties) { $row.properties } else { $row }
        if ($p.secret -or $named.ContainsKey([string]$row.name)) { throw "Named value '$($row.name)' is secret or duplicated; model discovery is incomplete." }
        $named[[string]$row.name] = [string]$p.value
    }
    foreach ($tier in 'standard','premium') {
        $id = "models-$tier"
        if (-not $named.ContainsKey($id)) { throw "Missing named value '$id'; no allow-all default is assumed." }
        $null = ConvertFrom-ClaudeModelList $named[$id]
    }
    [pscustomobject]@{
        Deployments = $deployments; NamedValues = $named
        GatewayId = [string]$gateway.id; GatewayUrl = [string]$gateway.gatewayUrl; Backend = [string]$api.serviceUrl
    }
}

function ConvertFrom-ClaudeModelList {
    param([string]$Value)
    if ($Value -notmatch '^,.*,$' -or $Value -match '\s') { throw "A model list needs comma sentinels and no whitespace." }
    $items = @($Value.Trim(',') -split ',' | Where-Object { $_ })
    foreach ($item in $items) { Assert-ClaudeModelName $item 'Model-list deployment name' }
    if ($Value -ne ',,' -and (',' + ($items -join ',') + ',') -ne $Value) { throw 'Model list has empty entries between comma sentinels.' }
    return @($items | Sort-Object -Unique)
}

function Get-ClaudeModelRecordStamp {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $copy = Read-ClaudeDecisionRecord $Path
    if ((Get-ClaudeDecisionRecordVersion $copy) -notin @(1,2)) { throw 'The model lifecycle does not understand this record schemaVersion.' }
    Set-ClaudeRecordProperty $copy 'schemaVersion' 2
    foreach ($key in '__recordPath','activeRun','history','release') { $copy.PSObject.Properties.Remove($key) }
    if ($copy.decisions) { $copy.decisions.PSObject.Properties.Remove('models') }
    if (-not $copy.decisions -or @($copy.decisions.PSObject.Properties).Count -eq 0) { $copy.PSObject.Properties.Remove('decisions') }
    return Get-ClaudeFlowLifecycleStringHash (ConvertTo-ClaudeFlowCanonical $copy)
}

function Get-ClaudeModelFileStamp {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return Get-ClaudeFlowLifecycleFileHash $Path }
    return 'absent'
}

function Get-ClaudeModelAssignments {
    param($Record)
    $result = @{}
    $decision = Get-ClaudeDecision -Record $Record -Key models
    if ($decision -and $decision.tiers) {
        foreach ($p in $decision.tiers.PSObject.Properties) { $result[$p.Name.Replace('~','.')] = $p.Value }
    }
    return $result
}

function Get-ClaudeModelQuestions {
    param($Record, $Discovery, $PriceBook = $null)
    if (-not $PriceBook) { $PriceBook = Get-ClaudeModelPriceBook (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\price-book.json') }
    $questions = @()
    $prior = Get-ClaudeModelAssignments $Record
    $retired = @($prior.Keys | Where-Object { $prior[$_] -eq 'drop' })
    $names = @(@($Discovery.Deployments.name) + @($Record.models) +
        @(ConvertFrom-ClaudeModelList $Discovery.NamedValues['models-standard']) +
        @(ConvertFrom-ClaudeModelList $Discovery.NamedValues['models-premium']) + $retired | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($name in $names) {
        $live = @($Discovery.Deployments | Where-Object name -eq $name)
        $allowed = @('standard','premium' | Where-Object { $Discovery.NamedValues["models-$_"] -eq ',,' -or $name -in @(ConvertFrom-ClaudeModelList $Discovery.NamedValues["models-$_"]) })
        $existing = -not $live.Count -or $allowed.Count -gt 0
        $options = @()
        if ($existing) { $options += New-ClaudeChoiceOption -Value keep -Label 'Keep current tier access' -Recommended -Reason 'no access change' }
        if ($live.Count) {
            foreach ($value in 'standard','premium','both','none') { $options += New-ClaudeChoiceOption -Value $value -Label $value }
        } else { $options += New-ClaudeChoiceOption -Value drop -Label 'Drop missing deployment from both tier lists' }
        $detail = if ($live.Count) { (Format-ClaudeDeployment $live[0]) + '; ' + (Get-ClaudeDeploymentPrice $live[0] $PriceBook).Detail } else { "$name is missing from Foundry" }
        $questions += [pscustomobject]@{
            Key = 'models.tiers.' + $name.Replace('.','~'); Question = "$detail - which tiers get it?"
            Options = $options; WhereToFind = @('Foundry > Models + endpoints; API Management > Named values > models-standard/models-premium')
            AcceptRecommendedWithoutConsole = [bool]$existing
        }
    }
    return $questions
}

function New-ClaudeModelPlan {
    param(
        [Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$RecordPath,
        [string]$PriceBookPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\price-book.json'),
        [hashtable]$TierAssignments = @{}, $Discovery = $null
    )
    $target = Get-ClaudeModelTarget $Record
    if (-not $Discovery) { $Discovery = Get-ClaudeModelDiscovery $target }
    $RecordPath = [IO.Path]::GetFullPath($RecordPath)
    $PriceBookPath = [IO.Path]::GetFullPath($PriceBookPath)
    $book = Get-ClaudeModelPriceBook $PriceBookPath
    $bookAfter = $book | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $recordAfter = $Record | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $recordAfter.PSObject.Properties.Remove('__recordPath')
    $questions = @(Get-ClaudeModelQuestions $Record $Discovery -PriceBook $book)
    $knownNames = @($questions | ForEach-Object { $_.Key.Substring('models.tiers.'.Length).Replace('~','.') })
    foreach ($name in $TierAssignments.Keys) {
        if ($name -notin $knownNames) { throw "Unknown deployment assignment '$name'; it was not discovered or recorded." }
    }
    $sets = @{}; $open = @{}; $beforeSets = @{}
    foreach ($tier in 'standard','premium') {
        $open[$tier] = $Discovery.NamedValues["models-$tier"] -eq ',,'
        $sets[$tier] = @(if ($open[$tier]) { $Discovery.Deployments.name } else { ConvertFrom-ClaudeModelList $Discovery.NamedValues["models-$tier"] })
        $beforeSets[$tier] = @($sets[$tier] | Sort-Object -Unique)
    }
    $actions = @(); $choices = @{}
    foreach ($name in $knownNames) {
        $live = @($Discovery.Deployments | Where-Object name -eq $name)
        $currently = @('standard','premium' | Where-Object { $name -in $sets[$_] })
        $choice = if ($TierAssignments.ContainsKey($name)) { $TierAssignments[$name] } elseif ($currently.Count -or -not $live.Count) { 'keep' } else { '' }
        if ($choice -isnot [string] -or $choice -notin @('keep','standard','premium','both','none','drop')) { throw "Deployment '$name' needs a scalar tier choice: standard, premium, both, none, or keep/drop for an existing entry." }
        if (-not $live.Count -and $choice -notin @('keep','drop')) { throw "Missing deployment '$name' has only keep or drop choices." }
        if ($live.Count -and $choice -eq 'drop') { throw "Deployment '$name' still exists; the none tier choice removes its access." }
        if ($live.Count -and $live[0].state -ne 'Succeeded' -and $choice -in @('standard','premium','both')) { throw "Deployment '$name' is not Succeeded (provisioning state $($live[0].state)); it cannot be newly allowed." }
        $choices[$name] = $choice
        if ($choice -ne 'keep') {
            foreach ($tier in 'standard','premium') {
                $sets[$tier] = @($sets[$tier] | Where-Object { $_ -ne $name })
                if ($choice -eq $tier -or $choice -eq 'both') { $sets[$tier] += $name }
            }
        }
        if (-not $live.Count) { $actions += New-ClaudeFlowAction -Verb Check -Target $name -Detail "missing from Foundry; $choice in tier lists; unavailable in client profiles" }
    }
    $afterNamed = @{}
    foreach ($tier in 'standard','premium') {
        $sets[$tier] = @($sets[$tier] | Sort-Object -Unique)
        if (-not $sets[$tier].Count) { throw "The last entry of $tier would be removed: an empty list means allow all, not deny all. The change is refused." }
        $unchangedOpen = $open[$tier] -and ($sets[$tier] -join ',') -eq ($beforeSets[$tier] -join ',')
        $afterNamed["models-$tier"] = if ($unchangedOpen) { ',,' } else { ',' + ($sets[$tier] -join ',') + ',' }
        Test-ApimNamedValueLength -Id "models-$tier" -Value $afterNamed["models-$tier"]
        $detail = "$($Discovery.NamedValues["models-$tier"]) -> $($afterNamed["models-$tier"])"
        if ($unchangedOpen) { $detail += ' (unrestricted: allow all deployments, including future ones)' }
        $verb = if ($afterNamed["models-$tier"] -ceq $Discovery.NamedValues["models-$tier"]) { 'Check' } else { 'Update' }
        $actions += New-ClaudeFlowAction -Verb $verb -Target "models-$tier" -Detail $detail
    }
    $permitted = @($Discovery.Deployments | Where-Object { $_.state -eq 'Succeeded' -and ($_.name -in $sets.standard -or $_.name -in $sets.premium) })
    $recorded = @(); $prices = @(); $priceChanged = $false; $costs = @()
    foreach ($d in $Discovery.Deployments) {
        $price = Get-ClaudeDeploymentPrice $d $book
        $tiers = @('standard','premium' | Where-Object { $d.name -in $sets[$_] }) -join ','
        $old = @($Record.deployments | Where-Object name -eq $d.name)
        if ($old.Count -gt 1) { throw "Duplicate deployment '$($d.name)' in the record." }
        $recordState = if (-not $old.Count) { 'new' } elseif ($old[0].model -ne $d.model) { "model $($old[0].model) -> $($d.model)" } elseif ($old[0].version -ne $d.version) { "version $($old[0].version) -> $($d.version)" } else { 'current' }
        $actions += New-ClaudeFlowAction -Verb Check -Target $d.name -Detail "$($d.model), version $($d.version), $($d.sku), capacity $($d.capacity), $($d.state); record: $recordState; tiers $(if ($tiers) { $tiers } else { 'none' }); $($price.Detail)"
        $prices += [pscustomobject]@{ Deployment = $d.name; Price = $price }
        if ($d.name -notin @($permitted.name)) { continue }
        if ($price.SourceKey -and $price.SourceKey -ne $d.name) {
            Set-ClaudeRecordProperty $bookAfter.models $d.name ($book.models.($price.SourceKey) | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
            $priceChanged = $true
            $actions += New-ClaudeFlowAction -Verb Write -Target "$PriceBookPath [$($d.name)]" -Detail "copy dated rate from $($price.SourceKey); existing prices retained"
        }
        $costs += New-ClaudeFlowCost -Item "Inference $($d.name)" -Source ([string]$book.source) -UnknownReason $(if ($price.Status -eq 'unpriced') { $price.Detail } else { 'usage-dependent; token volume is not specified' })
        $entry = if ($old.Count) { $old[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json } else { [pscustomobject]@{} }
        foreach ($field in 'name','model','version','sku','capacity') { Set-ClaudeRecordProperty $entry $field $d.$field }
        $recorded += $entry
    }
    Set-ClaudeRecordProperty $recordAfter 'models' @($recorded.name)
    Set-ClaudeRecordProperty $recordAfter 'deployments' $recorded
    if (-not $recordAfter.tiers) { Set-ClaudeRecordProperty $recordAfter 'tiers' ([pscustomobject]@{}) }
    foreach ($tier in 'standard','premium') {
        if (-not $recordAfter.tiers.$tier) { Set-ClaudeRecordProperty $recordAfter.tiers $tier ([pscustomobject]@{}) }
        $names = @($permitted | Where-Object { $_.name -in $sets[$tier] } | ForEach-Object { $_.name })
        if (-not $names.Count) { throw "Tier $tier has no Succeeded deployment for its profile (allowed: $($sets[$tier] -join ', '); live: $($Discovery.Deployments.name -join ', ')). No client fallback or access grant is assumed." }
        Set-ClaudeRecordProperty $recordAfter.tiers.$tier 'models' $names
        Set-ClaudeRecordProperty $recordAfter.tiers.$tier 'modelAllowList' $afterNamed["models-$tier"]
    }
    foreach ($key in 'subscriptionId','tenantId','resourceGroup','apimName','foundryAccount','foundryResourceGroup') { Set-ClaudeRecordProperty $recordAfter $key $target.$key }
    if (-not $recordAfter.gatewayUrl) { Set-ClaudeRecordProperty $recordAfter 'gatewayUrl' ($Discovery.GatewayUrl.TrimEnd('/') + '/claude') }
    Set-ClaudeRecordProperty $recordAfter 'mode' 'gateway'
    $profileRoot = Join-Path (Split-Path $RecordPath -Parent) 'profiles'
    $actions += New-ClaudeFlowAction -Verb Write -Target $RecordPath -Detail 'allowed live deployments and model versions; client overrides and unrelated fields retained'
    $actions += New-ClaudeFlowAction -Verb Write -Target $profileRoot -Detail 'standard and premium MDM profiles, tier-specific workstation records and developer handover'
    $notes = @(
        'Backup precedes any managed write; only models-standard and models-premium are changed in Azure.'
        'A control-plane readback is not proof of gateway propagation. A real request verifies tier enforcement.'
        'Developer setup is rerun with the tier-specific record: availableModels, alias pins, capability declarations, VS Code model variables and Desktop inferenceModels change.'
        'MDM assignment, saved ClaudeCost query publication and scheduled-reconciler price-book distribution remain explicit follow-up operations.'
    )
    if ($Discovery.NamedValues['turnstile-integration']) { $notes += 'Governance ownership is checked before apply. Turnstile-owned tiers are refused; no authority switch is performed.' }
    New-ClaudeFlowPlan -Step Models -Summary 'Reconcile Foundry deployments with tier access and client profiles' -Actions $actions -Costs $costs `
        -Implications $notes -Requires @('Foundry and API Management read access','API Management Service Contributor','Gateway-owned tier governance') `
        -Rollback 'The non-secret gateway snapshot and record/price-book copies precede the change. Restore only the reviewed model values and local files; replan after a partial failure.' `
        -Data @{
            Target = $target; Discovery = $Discovery; Assignments = $choices; AfterNamedValues = $afterNamed
            RecordAfter = $recordAfter; RecordPath = $RecordPath; RecordStamp = Get-ClaudeModelRecordStamp $RecordPath
            PriceBookPath = $PriceBookPath; PriceBookAfter = $bookAfter; PriceBookStamp = Get-ClaudeModelFileStamp $PriceBookPath; PriceChanged = $priceChanged; Prices = $prices
            ProfileRoot = $profileRoot; RendererStamp = Get-ClaudeModelFileStamp (Join-Path $PSScriptRoot 'New-ClaudeCodePolicy.ps1')
            SnapshotDirectory = Join-Path (Split-Path $RecordPath -Parent) 'model-snapshots'; SnapshotPath = ''; SnapshotTaken = $false
        }
}

function Assert-ClaudeModelPlanFresh {
    param($Plan)
    $d = $Plan.Data
    $live = Get-ClaudeModelDiscovery $d.Target
    $changed = @(
        if ((ConvertTo-ClaudeFlowCanonical $live) -cne (ConvertTo-ClaudeFlowCanonical $d.Discovery)) { 'Azure discovery' }
        if ((Get-ClaudeModelFileStamp $d.PriceBookPath) -cne $d.PriceBookStamp) { 'price book' }
        if ((Get-ClaudeModelRecordStamp $d.RecordPath) -cne $d.RecordStamp) { 'decision record' }
        if ((Get-ClaudeModelFileStamp (Join-Path $PSScriptRoot 'New-ClaudeCodePolicy.ps1')) -cne $d.RendererStamp) { 'profile renderer' }
    )
    if ($changed.Count) { throw "The model plan state changed after review: $($changed -join ', '). No further write was attempted; replan." }
}

function Initialize-ClaudeModelChange {
    param($Record, $Plan)
    Assert-ClaudeModelPlanFresh $Plan
    $d = $Plan.Data
    Invoke-ClaudeModelWait -What 'Checking tier governance ownership' -AboutSeconds 4 -Run {
        Assert-ClaudeGatewayOwnsGovernance -ResourceGroup $d.Target.ResourceGroup -ApimName $d.Target.ApimName -SubscriptionId $d.Target.SubscriptionId -Write Tiers
    }
    if ($d.SnapshotTaken) {
        if (-not (Test-Path -LiteralPath $d.SnapshotPath)) { throw 'The prepared snapshot no longer exists.' }
        return
    }
    $folder = Join-Path $d.SnapshotDirectory ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $d.SnapshotPath = Join-Path $folder 'gateway.json'
    $backupArgs = @{ Path = $d.SnapshotPath; ResourceGroup = $d.Target.ResourceGroup; ApimName = $d.Target.ApimName; SubscriptionId = $d.Target.SubscriptionId }
    if ($Record.workspaceName) { $backupArgs.WorkspaceName = [string]$Record.workspaceName }
    Invoke-ClaudeModelWait -What 'Taking the non-secret gateway snapshot before writes' -AboutSeconds 30 -Run {
        & (Join-Path $PSScriptRoot 'Backup-ClaudeGateway.ps1') @backupArgs
        if (-not (Test-Path -LiteralPath $d.SnapshotPath)) { throw 'The gateway backup did not create a snapshot.' }
        $snapshot = Read-ClaudeDecisionRecord $d.SnapshotPath
        foreach ($id in 'models-standard','models-premium') {
            $entry = @($snapshot.namedValues | Where-Object name -eq $id)
            if ($entry.Count -ne 1 -or $entry[0].value -cne $d.Discovery.NamedValues[$id]) { throw "The backup snapshot's $id changed after review; replan." }
        }
        foreach ($file in @(@($d.RecordPath,'record.json'), @($d.PriceBookPath,'price-book.json'))) {
            if (Test-Path -LiteralPath $file[0]) { Copy-Item -LiteralPath $file[0] -Destination (Join-Path $folder $file[1]) }
        }
    }
    $d.SnapshotTaken = $true
}

function Write-ClaudeModelRecord {
    param($Record, [string]$Path)
    $copy = $Record | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $copy.PSObject.Properties.Remove('__recordPath')
    Write-ClaudeDecisionRecord -Record $copy -Path $Path
}

function Invoke-ClaudeModelChange {
    param($Record, $Plan)
    $d = $Plan.Data
    if (-not $d.SnapshotTaken -or -not $d.SnapshotPath -or -not (Test-Path -LiteralPath $d.SnapshotPath)) { throw 'A prepared named-value snapshot is required before model writes.' }
    Assert-ClaudeModelPlanFresh $Plan
    try {
        foreach ($id in 'models-standard','models-premium') {
            if ($d.AfterNamedValues[$id] -ceq $d.Discovery.NamedValues[$id]) { continue }
            Invoke-ClaudeModelWait -What "Updating $id on $($d.Target.ApimName)" -AboutSeconds 10 -Run {
                Set-ApimNamedValue -ResourceGroup $d.Target.ResourceGroup -ApimName $d.Target.ApimName -SubscriptionId $d.Target.SubscriptionId -Id $id -Value $d.AfterNamedValues[$id]
            }
        }
        Invoke-ClaudeModelWait -What 'Reading back the model named values' -AboutSeconds 8 -Run {
            foreach ($id in 'models-standard','models-premium') {
                $got = Get-ApimNamedValue -ResourceGroup $d.Target.ResourceGroup -ApimName $d.Target.ApimName -SubscriptionId $d.Target.SubscriptionId -Id $id -FailOnError
                if ($got -cne $d.AfterNamedValues[$id]) { throw "Model named-value readback does not match for $id." }
            }
        }
        if ($d.PriceChanged) { Write-ClaudeDecisionRecord -Record $d.PriceBookAfter -Path $d.PriceBookPath }
        foreach ($key in 'mode','models','deployments','tiers','subscriptionId','tenantId','resourceGroup','apimName','foundryAccount','foundryResourceGroup','gatewayUrl') {
            Set-ClaudeRecordProperty $Record $key $d.RecordAfter.$key
        }
        Write-ClaudeModelRecord -Record $Record -Path $d.RecordPath
        $profiles = Invoke-ClaudeModelWait -What 'Generating both tier profiles and workstation records' -AboutSeconds 3 -Run {
            Write-ClaudeModelProfiles -Record $Record -RecordPath $d.RecordPath
        }
        Set-ClaudeDecision -Record $Record -Key deviceProfiles -Value $profiles
        Write-ClaudeModelRecord -Record $Record -Path $d.RecordPath
        Write-Host "Developer handover: $($d.ProfileRoot)\README.md"
        Write-Host 'Rerun workstation setup with its tier record; redistribute the MDM payloads through the fleet tool.'
        $selections = [ordered]@{}
        foreach ($name in ($d.Assignments.Keys | Sort-Object)) { $selections[$name.Replace('.','~')] = $d.Assignments[$name] }
        return @{ models = [pscustomobject]@{ tiers = [pscustomobject]$selections; priceBookPath = $d.PriceBookPath; snapshot = $d.SnapshotPath } }
    }
    catch { throw "Model change failed; snapshot: $($d.SnapshotPath). Partial writes may exist; replan before retrying. $($_.Exception.Message)" }
}
