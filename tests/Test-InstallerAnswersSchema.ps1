
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
$script:fail = 0
function Assert($Label, $Condition, $Detail = '') {
    $script:checks++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if($Detail){" - $Detail"})" -ForegroundColor Red; $script:fail++ }
}
function Finish($Name) {
    if ($script:fail) { Write-Host "$Name failed: $script:fail of $script:checks" -ForegroundColor Red; exit 1 }
    Write-Host "$Name passed: $script:checks" -ForegroundColor Green
}

Write-Host ''
Write-Host 'P92 answers schema contract' -ForegroundColor Cyan
$schemaPath = Join-Path $root 'schemas\claude-gateway.answers.schema.json'
$schema = $null
if (Test-Path -LiteralPath $schemaPath) { $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json }
Assert 'schema file exists' (Test-Path -LiteralPath $schemaPath)
$props = @{}
if ($schema -and $schema.properties) { foreach($p in $schema.properties.PSObject.Properties){ $props[$p.Name] = $p.Value } }
$installText = Get-Content -Raw -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1')
$paramText = [regex]::Match($installText, '(?s)param\((.*?)\)\s*\$ErrorActionPreference').Groups[1].Value
$paramNames = @([regex]::Matches($paramText, '(?m)^\s*(?:\[[^\]]+\]\s*)*\$([A-Za-z][A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value })
$excluded = 'AddressCertificatePassword','Yes','WhatIf','Confirm','Restart','ArchiveSavedRecord','AddressApprovedPlanFingerprint','FlipProjectionAfterCleanCompare','ChooseFinOps','SkipFinOpsOffer','Preflight','Json','ListSteps','Steps','ProgressPath','AnswersPath'
$missingParams = @($paramNames | Where-Object { $_ -notin $excluded -and -not $props.ContainsKey($_) })
Assert 'schema-covers-powershell-parameters' ($missingParams.Count -eq 0) ($missingParams -join ', ')
$bash = Get-Content -Raw -LiteralPath (Join-Path $root 'install-claude-gateway.sh')
$flagMap = @{ '--subscription'='SubscriptionId'; '--foundry-account'='FoundryAccount'; '--foundry-rg'='FoundryResourceGroup'; '--resource-group'='ResourceGroup'; '--location'='Location'; '--name-prefix'='NamePrefix'; '--publisher-email'='PublisherEmail'; '--sku'='Sku'; '--tpm-standard'='TpmStandard'; '--quota-standard'='QuotaStandard'; '--tpm-premium'='TpmPremium'; '--quota-premium'='QuotaPremium'; '--calls-per-minute'='CallsPerMinute'; '--standard-group'='StandardGroup'; '--premium-group'='PremiumGroup' }
$missingFlags = @($flagMap.GetEnumerator() | Where-Object { $bash -match [regex]::Escape($_.Key) -and -not $props.ContainsKey($_.Value) } | ForEach-Object { $_.Key })
Assert 'schema-covers-bash-flags' ($missingFlags.Count -eq 0) ($missingFlags -join ', ')
$flowFiles = Get-ChildItem -LiteralPath (Join-Path $root 'scripts\flow') -Filter '*.ps1'
$staticKeys = @($flowFiles | ForEach-Object { [regex]::Matches((Get-Content -Raw -LiteralPath $_.FullName), "Key\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } } | Sort-Object -Unique)
$missingFlow = @($staticKeys | Where-Object { -not $props.ContainsKey($_) })
Assert 'schema-covers-flow-keys' ($missingFlow.Count -eq 0) ($missingFlow -join ', ')
$promptOnly = 'RevocationWindowSeconds','TeamBudgetBehaviour','UnassignedDevelopers','DeveloperEstimate','PendingClaudeDeployment','BusinessUnits'
$missingPrompt = @($promptOnly | Where-Object { -not $props.ContainsKey($_) })
Assert 'schema-covers-prompt-only-answers' ($missingPrompt.Count -eq 0) ($missingPrompt -join ', ')
Assert 'schema-rejects-secret-answers' (-not $props.ContainsKey('AddressCertificatePassword'))
$bu = $props['BusinessUnits']
Assert 'schema-validates-business-unit-tree' ($bu -and $bu.items -and $bu.items.properties.id.pattern -eq '^[a-z0-9-]+$' -and $bu.items.properties.group.pattern -match "\^\[\^,:'" -and $bu.items.properties.mode)
$whenMissing = @($flowFiles | ForEach-Object { $t = Get-Content -Raw -LiteralPath $_.FullName; if ($t -match 'When\s*=') { [regex]::Matches($t, "Key\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } } } | Where-Object { $props.ContainsKey($_) -and -not $props[$_].requires })
Assert 'schema-requires-declarative-conditions' ($whenMissing.Count -eq 0) ($whenMissing -join ', ')
Finish 'P92 answers schema contract'
