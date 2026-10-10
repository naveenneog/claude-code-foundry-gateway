# Each mutation runs the entire lifecycle suite in a private source copy, then restores its file.
param(
    [string]$HostExecutable = (Get-Process -Id $PID).Path,
    [string]$OutputPath,
    [switch]$ValidateOnly,
    [string[]]$CaseNames,
    [switch]$CouncilOnly,
    [ValidateSet('Lifecycle','WorkstationModels')][string]$Suite = 'Lifecycle'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cases = [Collections.Generic.List[object]]::new()
function Mutation($Name, $File, $Before, $After, [int]$Occurrences = 1) {
    $cases.Add([pscustomobject]@{ Name = $Name; File = $File; Before = $Before; After = $After; Occurrences = $Occurrences })
}
$life = 'scripts\ClaudeModelLifecycle.ps1'
$price = 'scripts\ClaudeModelPrices.ps1'
Mutation 'native-exit-is-not-success' $life 'if ($code -ne 0)' 'if ($false)'
Mutation 'deployment-json-array' $life '($Array -and -not $text.TrimStart().StartsWith(''[''))' '$false'
Mutation 'safe-az-names' $life '$Value -isnot [string] -or $Value -notmatch ''^[A-Za-z0-9][A-Za-z0-9._-]*$''' '$false'
Mutation 'gateway-record-mode' $life '$Record.mode -and $Record.mode -ne ''gateway''' '$false'
Mutation 'subscription-is-an-id' $life '-not (Test-ClaudeFlowSubscriptionId $target.SubscriptionId)' '$false' 2
Mutation 'backend-is-the-selected-account' $life '-not $expected -or ([string]$api.serviceUrl).TrimEnd(''/'') -ne $expected' '$false'
Mutation 'duplicate-deployment-refusal' $life '$seen.ContainsKey($d.name)' '$false'
Mutation 'missing-list-refusal' $life '-not $named.ContainsKey($id)' '$false'
Mutation 'unknown-assignment-refusal' $life '$name -notin $knownNames' '$false'
Mutation 'typed-tier-choice' $life '$choice -isnot [string] -or $choice -notin @(''keep'',''standard'',''premium'',''both'',''none'',''drop'')' '$false'
Mutation 'explicit-new-deployment-choice' $life 'elseif ($currently.Count -or -not $live.Count) { ''keep'' } else { '''' }' 'elseif ($currently.Count -or -not $live.Count) { ''keep'' } else { ''none'' }'
Mutation 'missing-deployment-keep-default' $life 'elseif ($currently.Count -or -not $live.Count) { ''keep'' } else { '''' }' 'elseif (-not $live.Count) { ''drop'' } elseif ($currently.Count) { ''keep'' } else { '''' }'
Mutation 'succeeded-before-new-access' $life '$live.Count -and $live[0].state -ne ''Succeeded'' -and $choice -in @(''standard'',''premium'',''both'')' '$false'
Mutation 'last-entry-not-allow-all' $life '-not $sets[$tier].Count' '$false'
Mutation 'unrestricted-list-is-preserved' $life '$open[$tier] -and ($sets[$tier] -join '','') -eq ($beforeSets[$tier] -join '','')' '$false'
Mutation 'named-value-length-preflight' $life 'Test-ApimNamedValueLength -Id "models-$tier" -Value $afterNamed["models-$tier"]' '$null = $afterNamed["models-$tier"]'
Mutation 'recorded-overrides-survive' $life '$entry = if ($old.Count) { $old[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json } else { [pscustomobject]@{} }' '$entry = [pscustomobject]@{}'
Mutation 'root-models-are-the-live-union' $life 'Set-ClaudeRecordProperty $recordAfter ''models'' @($recorded.name)' 'Set-ClaudeRecordProperty $recordAfter ''models'' @(''stale-model'')'
Mutation 'tier-records-are-scoped' $life '$names = @($permitted | Where-Object { $_.name -in $sets[$tier] } | ForEach-Object { $_.name })' '$names = @($permitted.name)'
Mutation 'negative-price-refusal' $price '$value -lt 0 -or [decimal]$value -lt 0' '$false' 2
Mutation 'ambiguous-price-refusal' $price '$rates.Count -gt 1' '$false' 3
Mutation 'negotiated-deployment-price-wins' $price '$key = Resolve-ClaudePriceBookKey -Name ([string]$Deployment.name) -Book $Book' '$key = '''''
Mutation 'equal-rate-spellings-take-ordinal-first' $price 'return [string](@(Sort-ClaudeFlowOrdinal -InputObject $matches)[0])' 'return [string]$matches[0]'
Mutation 'unpriced-never-free' $price 'Detail = "unpriced ($reason); not free"' 'Detail = "free USD 0"'
Mutation 'historical-price-retention' $life '$bookAfter = $book | ConvertTo-Json -Depth 40 | ConvertFrom-Json' '$bookAfter = $book | ConvertTo-Json -Depth 40 | ConvertFrom-Json; $bookAfter.models.PSObject.Properties.Remove(''retired'')'
Mutation 'price-mapping-is-persisted' $life '$priceChanged = $true' '$priceChanged = $false'
Mutation 'snapshot-required-before-write' $life '-not $d.SnapshotTaken -or -not $d.SnapshotPath -or -not (Test-Path -LiteralPath $d.SnapshotPath)' '$false'
Mutation 'stale-state-refusal' $life 'if ($changed.Count) { throw "The model plan state changed' 'if ($false) { throw "The model plan state changed'
Mutation 'ownership-before-snapshot' $life 'Assert-ClaudeGatewayOwnsGovernance -ResourceGroup $d.Target.ResourceGroup -ApimName $d.Target.ApimName -SubscriptionId $d.Target.SubscriptionId -Write Tiers' '$null = $d.Target'
Mutation 'readback-is-not-native-exit' $life '$got -cne $d.AfterNamedValues[$id]' '$false'
Mutation 'snapshot-before-flow-journal' 'Start-ClaudeGateway.ps1' 'Initialize-FlowSteps -Steps $steps -Plans @($plans) -Record $record' '$null = $plans'
Mutation 'write-failure-is-loud' 'scripts\ApimNamedValue.ps1' "if (`$code -ne 0) {`n            `$detail = (Get-Content" "if (`$false) {`n            `$detail = (Get-Content"
Mutation 'writes-keep-selected-subscription' 'scripts\ApimNamedValue.ps1' '--named-value-id $Id --value $Value -o none @subscriptionArgs' '--named-value-id $Id --value $Value -o none'
Mutation 'single-deployment-on-ps51' 'scripts\ClaudeModelDeployment.ps1' '$items = @(@($Deployments) | Where-Object { $_ })' '$items = @(@($Deployments) | Where-Object { $_ }); if ($items.Count -eq 1) { $items = @() }'
Mutation 'profiles-do-not-reexpand-tiers' 'scripts\New-ClaudeCodePolicy.ps1' '$AvailableModels = $permittedNames' '$AvailableModels = @($cfg.models)'
Mutation 'installer-explicit-standard-models' 'Install-ClaudeGateway.ps1' '$PSBoundParameters.ContainsKey(''StandardModels'')' '$false'
Mutation 'installer-refuses-undeployed-models' 'Install-ClaudeGateway.ps1' '$selected -notin $all' '$false'
Mutation 'price-status-at-the-question' $life '(Format-ClaudeDeployment $live[0]) + ''; '' + (Get-ClaudeDeploymentPrice $live[0] $PriceBook).Detail' '(Format-ClaudeDeployment $live[0])'
Mutation 'completed-retirement-can-be-retried' $life '$retired = @($prior.Keys | Where-Object { $prior[$_] -eq ''drop'' })' '$retired = @()'
Mutation 'wrong-fingerprint-cannot-apply' 'scripts\Sync-ClaudeModels.ps1' '-not $ApprovedPlanFingerprint -or $ApprovedPlanFingerprint.Length -lt 8 -or -not $fingerprint.StartsWith($ApprovedPlanFingerprint, [StringComparison]::OrdinalIgnoreCase)' '$false'
Mutation 'subscription-before-account-discovery' $life '$target.SubscriptionId -and -not (Test-ClaudeFlowSubscriptionId $target.SubscriptionId)' '$false'
Mutation 'record-drift-shown-in-review' $life '; record: $recordState; tiers' '; tiers'
Mutation 'snapshot-token-uses-target-tenant' 'scripts\Backup-ClaudeGateway.ps1' '--query accessToken -o tsv @scope' '--query accessToken -o tsv'
Mutation 'fresh-installer-record-normalization' $life 'if (-not $copy.decisions -or @($copy.decisions.PSObject.Properties).Count -eq 0) { $copy.PSObject.Properties.Remove(''decisions'') }' '$null = $copy.decisions'

Mutation 'r1-raw-lifecycle-validation' $life 'Assert-ClaudeDeploymentIdentities -Deployments @($raw)' '$null = $raw'
Mutation 'r1-raw-installer-validation' 'scripts\ClaudeModelDeployment.ps1' 'Assert-ClaudeDeploymentIdentities -Deployments @($parsed)' '$null = $parsed'
Mutation 'r1-raw-identity-shape' 'scripts\ClaudeModelDeployment.ps1' 'foreach ($part in @($row, $row.properties, $row.properties.model))' 'foreach ($part in @())'
Mutation 'r1-raw-identity-string-fields' 'scripts\ClaudeModelDeployment.ps1' '$field.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($field.Value)' '$false'
Mutation 'r1-installer-discovery-exit' 'scripts\ClaudeModelDeployment.ps1' 'if ($code -ne 0) { throw "Reading deployments' 'if ($false) { throw "Reading deployments'
Mutation 'r1-installer-discovery-array' 'scripts\ClaudeModelDeployment.ps1' '-not $raw.StartsWith(''['')' '$false'
Mutation 'r1-installer-no-deployments' 'Install-ClaudeGateway.ps1' 'throw "No Claude deployment is available' 'Write-Note "No Claude deployment is available'
Mutation 'r1-installer-empty-restrictions' 'Install-ClaudeGateway.ps1' '-not $standardModelNames.Count -or -not $premiumModelNames.Count' '$false'
Mutation 'r1-installer-normalization' 'Install-ClaudeGateway.ps1' '$standardModelNames = @($stdPick -split '','' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)' '$standardModelNames = @($stdPick -split '','' | ForEach-Object { $_.Trim() } | Where-Object { $_ })'
Mutation 'r1-initial-standard-record' 'Install-ClaudeGateway.ps1' '; models = @($standardModelNames); modelAllowList = $modelsStd' ''
Mutation 'r1-initial-premium-record' 'Install-ClaudeGateway.ps1' '; models = @($premiumModelNames); modelAllowList = $modelsPrm' ''
Mutation 'r1-renderer-dependency-stamp' $life 'return Get-ClaudeFlowLifecycleStringHash (ConvertTo-ClaudeFlowCanonical $stamps)' 'return Get-ClaudeModelFileStamp (Join-Path $PSScriptRoot ''New-ClaudeCodePolicy.ps1'')'
Mutation 'r1-renderer-dependency-recheck' $life '(Get-ClaudeModelRendererStamp) -cne $d.RendererStamp' '$false'
Mutation 'r1-history-previous-decision' 'scripts\Sync-ClaudeModels.ps1' '-From $decision -To $changes.models' '-To $changes.models'
Mutation 'r1-history-principal' 'scripts\Sync-ClaudeModels.ps1' '-Principal $principal.user.name' ''
Mutation 'r1-history-missing-principal' 'scripts\Sync-ClaudeModels.ps1' '$principal.user.name -isnot [string] -or [string]::IsNullOrWhiteSpace($principal.user.name)' '$false'
Mutation 'r1-empty-write-token-subscription' 'scripts\ApimNamedValue.ps1' '--query accessToken -o tsv @subscriptionArgs' '--query accessToken -o tsv'
Mutation 'r1-nested-generated-artifacts' '.gitignore' "onboarding/**/claude-gateway.json`nonboarding/**/profiles/`nonboarding/**/model-snapshots/" ''
Mutation 'r2-added-renderer-import' 'scripts\New-ClaudeCodePolicy.ps1' '$clientSupport = Join-Path' ". (Join-Path `$PSScriptRoot 'ClaudeGatewayRegion.ps1')`n`$clientSupport = Join-Path"
if ($Suite -eq 'WorkstationModels') {
    $cases.Clear()
    foreach ($alias in 'OPUS','SONNET','HAIKU') {
        Mutation "r1-retired-$($alias.ToLowerInvariant())-alias" 'scripts\setup-claude-workstation.sh' "else del(.env.ANTHROPIC_DEFAULT_${alias}_MODEL) end" 'else . end'
    }
}
if ($CouncilOnly) {
    $selected = @($cases | Where-Object { $_.Name.StartsWith('r1-') })
    $cases.Clear()
    foreach ($case in $selected) { $cases.Add($case) }
}
if ($CaseNames) {
    foreach ($name in $CaseNames) { if ($name -notin @($cases.Name)) { throw "Unknown requested mutation '$name'." } }
    $selected = @($cases | Where-Object { $_.Name -in $CaseNames })
    $cases.Clear()
    foreach ($case in $selected) { $cases.Add($case) }
}
foreach ($case in $cases) {
    $text = [IO.File]::ReadAllText((Join-Path $root $case.File)).Replace("`r`n","`n")
    $hits = [regex]::Matches($text, [regex]::Escape($case.Before)).Count
    if ($hits -ne $case.Occurrences) { throw "Mutation '$($case.Name)' matched $hits sites, expected $($case.Occurrences)." }
}
if ($ValidateOnly) { Write-Host "All $($cases.Count) mutation sites match the current source."; return }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p70-mutations-' + [guid]::NewGuid().ToString('N'))
$shadow = Join-Path $scratch 'source'
$results = [Collections.Generic.List[object]]::new()
$failed = 0
$suiteFile = if ($Suite -eq 'WorkstationModels') { 'Test-WorkstationModels.ps1' } else { 'Test-ModelLifecycle.ps1' }
$suitePath = Join-Path $shadow "tests\$suiteFile"
function Run-Suite([string]$Name) {
    $log = Join-Path $scratch ($Name + '.log')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    & $HostExecutable -NoProfile -ExecutionPolicy Bypass -File $suitePath -RepoRoot $shadow *> $log
    $code = $LASTEXITCODE
    $text = Get-Content -LiteralPath $log -Raw
    $match = [regex]::Match($text, '(?:Model lifecycle|Workstation models): (\d+) assertions, (\d+) failed\.')
    [pscustomobject]@{
        Name = $Name; ExitCode = $code; Assertions = $(if ($match.Success) { [int]$match.Groups[1].Value } else { 0 })
        Failures = $(if ($match.Success) { [int]$match.Groups[2].Value } else { 0 })
        Seconds = [math]::Round($watch.Elapsed.TotalSeconds,1)
        FailedChecks = @($text -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]' })
    }
}
try {
    New-Item -ItemType Directory -Path $shadow | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $shadow 'tests') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "tests\$suiteFile") -Destination $suitePath
    Copy-Item -LiteralPath (Join-Path $root 'tests\ScriptImportCoverage.ps1') -Destination (Join-Path $shadow 'tests')
    Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination $shadow -Recurse
    # The answers schema the guided flow checks -AnswersPath against (ADR-0047).
    Copy-Item -LiteralPath (Join-Path $root 'schemas') -Destination $shadow -Recurse
    # Tracked configuration only: an operator's gitignored config\price-book.json must not change the suite's results.
    foreach ($tracked in @(& git -C $root ls-files -- config)) {
        $trackedTarget = Join-Path $shadow $tracked
        New-Item -ItemType Directory -Path (Split-Path $trackedTarget -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $tracked) -Destination $trackedTarget
    }
    foreach ($file in 'Start-ClaudeGateway.ps1','Install-ClaudeGateway.ps1','.gitignore') { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $shadow }
    & git -C $shadow init --quiet
    if ($LASTEXITCODE) { throw 'Cannot initialise the private mutation source repository.' }
    $head = (& git -C $root rev-parse HEAD).Trim()
    $objects = (& git -C $root rev-parse --path-format=absolute --git-path objects).Trim()
    [IO.File]::WriteAllText((Join-Path $shadow '.git\objects\info\alternates'), $objects + "`n")
    & git -C $shadow update-ref HEAD $head
    if ($LASTEXITCODE) { throw 'Cannot set the private mutation source release identity.' }
    $baseline = Run-Suite 'baseline'
    $results.Add($baseline)
    $minimumAssertions = if ($Suite -eq 'WorkstationModels') { 13 } else { 135 }
    if ($baseline.ExitCode -ne 0 -or $baseline.Assertions -lt $minimumAssertions) {
        $failed++
        $baseline | Format-List
        throw 'The unmodified lifecycle suite did not pass every expected assertion in the private source copy.'
    }
    Write-Host "Baseline: $($baseline.Assertions) assertions, $($baseline.Failures) failed in $($baseline.Seconds)s."
    foreach ($case in $cases) {
        $path = Join-Path $shadow $case.File
        $original = [IO.File]::ReadAllBytes($path)
        try {
            $text = [IO.File]::ReadAllText($path).Replace("`r`n","`n")
            $hits = [regex]::Matches($text, [regex]::Escape($case.Before)).Count
            if ($hits -ne $case.Occurrences) { throw "Mutation '$($case.Name)' matched $hits sites, expected $($case.Occurrences)." }
            [IO.File]::WriteAllText($path, $text.Replace($case.Before,$case.After), (New-Object Text.UTF8Encoding($true)))
            $result = Run-Suite $case.Name
            $caught = $result.ExitCode -ne 0 -and $result.Failures -gt 0 -and $result.Assertions -eq $baseline.Assertions
            $result | Add-Member -NotePropertyName Caught -NotePropertyValue $caught
            $results.Add($result)
            Write-Host "$($case.Name): caught=$caught, $($result.Assertions) assertions, $($result.Failures) failed, $($result.Seconds)s"
            if (-not $caught) { $failed++ }
        }
        finally { [IO.File]::WriteAllBytes($path, $original) }
    }
    $restored = Run-Suite 'restored'
    $results.Add($restored)
    if ($restored.ExitCode -ne 0 -or $restored.Assertions -ne $baseline.Assertions) { $failed++ }
    Write-Host "Restored: $($restored.Assertions) assertions, $($restored.Failures) failed."
}
finally {
    if ($OutputPath) {
        $parent = Split-Path $OutputPath -Parent
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [pscustomobject]@{ hostExecutable = $HostExecutable; utc = [DateTime]::UtcNow.ToString('o'); cases = @($results); failures = $failed } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Write-Host "Model lifecycle mutations: $($cases.Count) cases, $failed uncaught/incomplete."
if ($failed) { exit 1 }
exit 0
