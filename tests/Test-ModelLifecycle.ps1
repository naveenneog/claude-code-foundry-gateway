# P70: offline model lifecycle, including the real flow, backup and profile writers.
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$root = $RepoRoot
$global:P70count = 0
$global:P70failed = 0
function Check([string]$Label, [scriptblock]$Test) {
    $global:P70count++
    try {
        if (-not (& $Test)) { throw 'condition was false' }
        Write-Host "  [OK] $Label"
    }
    catch { $global:P70failed++; Write-Host "  [FAIL] $Label - $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
}
function Reject([scriptblock]$Run, [string]$Pattern) {
    try { & $Run | Out-Null; return $false }
    catch { return ($_.Exception.Message -match $Pattern) }
}
function Clone($Value) { $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json }
function Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Save($Path, $Value) { $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding UTF8 }
function Arg($Words, $Key) {
    $i = [array]::IndexOf([object[]]$Words, $Key)
    if ($i -ge 0 -and $i + 1 -lt $Words.Count) { return [string]$Words[$i + 1] }
    return ''
}

$helper = Join-Path $root 'scripts\ClaudeModelLifecycle.ps1'
Check 'model lifecycle implementation exists' { Test-Path -LiteralPath $helper }
if (-not (Test-Path -LiteralPath $helper)) {
    Write-Host "Model lifecycle: $global:P70count assertions, $global:P70failed failed."
    exit 1
}
. $helper

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p70-models-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$global:P70recordPath = Join-Path $scratch 'claude-gateway.json'
$global:P70bookPath = Join-Path $scratch 'price-book.json'
$global:P70sub = '00000000-0000-0000-0000-000000000070'
$global:P70calls = [Collections.Generic.List[object]]::new()
$global:P70writes = [Collections.Generic.List[string]]::new()
$global:P70rawDeployments = @(
    @{ name = 'sonnet'; properties = @{ model = @{ name = 'claude-sonnet-5'; version = '2'; format = 'Anthropic' }; provisioningState = 'Succeeded' }; sku = @{ name = 'GlobalStandard'; capacity = 20 } }
    @{ name = 'opus'; properties = @{ model = @{ name = 'claude-opus-5'; version = '2'; format = 'Anthropic' }; provisioningState = 'Succeeded' }; sku = @{ name = 'GlobalStandard'; capacity = 40 } }
    @{ name = 'next.opus'; properties = @{ model = @{ name = 'claude-opus-5-5'; version = '2'; format = 'Anthropic' }; provisioningState = 'Succeeded' }; sku = @{ name = 'GlobalStandard'; capacity = 40 } }
    @{ name = 'claude-haiku-4-5'; properties = @{ model = @{ name = 'claude-haiku-4-5'; version = '2'; format = 'Anthropic' }; provisioningState = 'Succeeded' }; sku = @{ name = 'GlobalStandard'; capacity = 50 } }
    @{ name = 'claude-not-really'; properties = @{ model = @{ name = 'gpt-5'; version = '1'; format = 'OpenAI' }; provisioningState = 'Succeeded' }; sku = @{ name = 'GlobalStandard'; capacity = 1 } }
)
$global:P70originalDeployments = Clone $global:P70rawDeployments
$global:P70nvs = @{}
$global:P70azFailure = ''
$global:P70badDeployments = ''
$global:P70backend = 'https://ai-models.services.ai.azure.com/anthropic'
$global:P70backupFails = $false
$global:P70failWrite = ''
$global:P70dropWrite = $false
$global:P70backupRead = $false

function global:az {
    $words = @($args)
    $global:P70calls.Add($words)
    $joined = $words -join ' '
    $global:LASTEXITCODE = 0
    if ($global:P70azFailure -and $joined.StartsWith($global:P70azFailure)) {
        $global:LASTEXITCODE = 3
        if ($global:P70failureJson) { return $global:P70failureJson }
        return 'ERROR: denied'
    }
    if ($joined -like 'account get-access-token*') { return ('offline-' + 'credential') }
    if ($joined -like 'account show*') {
        if ((Arg $words '--query') -eq 'user.name') { return 'operator@contoso.com' }
        if ((Arg $words '--query') -eq 'id') { return $global:P70sub }
        return (@{ id = $global:P70sub; tenantId = '00000000-0000-0000-0000-000000000001'; user = @{ name = 'operator@contoso.com' } } | ConvertTo-Json -Compress)
    }
    if ($joined -like 'apim api show*') { return (@{ serviceUrl = $global:P70backend } | ConvertTo-Json -Compress) }
    if ($joined -like 'apim show*') {
        return (@{ name = 'apim-models'; id = "/subscriptions/$global:P70sub/resourceGroups/rg-models/providers/Microsoft.ApiManagement/service/apim-models"; gatewayUrl = 'https://apim-models.azure-api.net'; location = 'eastus2'; sku = @{ name = 'BasicV2' } } | ConvertTo-Json -Compress)
    }
    if ($joined -like 'cognitiveservices account deployment list*') {
        if ($global:P70badDeployments) { return $global:P70badDeployments }
        return (ConvertTo-Json -InputObject @($global:P70rawDeployments) -Depth 8 -Compress)
    }
    if ($joined -like 'cognitiveservices account show*') {
        return (@{ name = 'ai-models'; properties = @{ endpoints = @{ 'AI Foundry API' = 'https://ai-models.services.ai.azure.com/' } }; endpoints = @{ 'AI Foundry API' = 'https://ai-models.services.ai.azure.com/' } } | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($joined -like 'apim nv list*') {
        $values = @($global:P70nvs.Keys | Sort-Object | ForEach-Object { @{ name = $_; value = $global:P70nvs[$_]; secret = $false } })
        return (ConvertTo-Json -InputObject $values -Depth 6 -Compress)
    }
    if ($joined -like 'apim nv show*') {
        $id = Arg $words '--named-value-id'
        if (-not $global:P70nvs.ContainsKey($id)) {
            $global:LASTEXITCODE = 3
            return 'ERROR: (ResourceNotFound) NamedValue not found'
        }
        if ((Arg $words '--query') -eq 'name') { return $id }
        return $global:P70nvs[$id]
    }
    if ($joined -like 'apim nv update*' -or $joined -like 'apim nv create*') {
        $id = Arg $words '--named-value-id'
        if (-not $global:P70backupRead) { throw 'write reached az before a backup' }
        $global:P70writes.Add($id)
        if ($id -eq $global:P70failWrite) { $global:LASTEXITCODE = 7; return }
        if (-not $global:P70dropWrite) { $global:P70nvs[$id] = Arg $words '--value' }
        return
    }
    if ($joined -like 'monitor diagnostic-settings list*') { return '[]' }
    throw "Unexpected offline az call: $joined"
}

function global:Invoke-RestMethod {
    param($Uri, $Headers, $Method = 'Get', $Body, $ContentType, $TimeoutSec)
    if ($Method -ne 'Get') { throw 'Unexpected REST write in model lifecycle' }
    if ([string]$Uri -like '*/namedValues?*') {
        if ($global:P70backupFails) { throw 'backup read refused' }
        $global:P70backupRead = $true
        return [pscustomobject]@{ value = @($global:P70nvs.Keys | ForEach-Object { [pscustomobject]@{ name = $_; properties = [pscustomobject]@{ value = $global:P70nvs[$_]; displayName = $_; secret = $false; tags = @() } } }) }
    }
    if ([string]$Uri -like '*/policies/policy?*') { return [pscustomobject]@{ properties = [pscustomobject]@{ value = '<policies />' } } }
    if ([string]$Uri -like '*/savedSearches?*' -or [string]$Uri -like '*/workbooks?*') { return [pscustomobject]@{ value = @() } }
    throw "Unexpected offline REST read: $Uri"
}

function Reset-State {
    $global:P70nvs = @{ 'models-standard' = ',sonnet,retired,'; 'models-premium' = ',opus,sonnet,retired,'; 'quota-standard' = '654321' }
    $global:P70rawDeployments = Clone $global:P70originalDeployments
    $global:P70azFailure = ''; $global:P70failureJson = ''; $global:P70badDeployments = ''; $global:P70failWrite = ''
    $global:P70backupFails = $false; $global:P70backupRead = $false; $global:P70dropWrite = $false
    $global:P70backend = 'https://ai-models.services.ai.azure.com/anthropic'
    $global:P70writes.Clear(); $global:P70calls.Clear()
    Save $global:P70bookPath ([ordered]@{ date = '2026-09-15'; source = 'approved test tariff'; privateNote = 'keep'; models = [ordered]@{
        'claude-haiku-4.5' = @{ inputPerM = 1; outputPerM = 5 }
        'claude-sonnet-5' = @{ inputPerM = 2; outputPerM = 10 }
        'claude-opus-5' = @{ inputPerM = 5; outputPerM = 25 }
        'retired' = @{ inputPerM = 3; outputPerM = 15 }
    } })
    $global:P70record = [pscustomobject]@{
        mode = 'gateway'; subscriptionId = $global:P70sub; tenantId = '00000000-0000-0000-0000-000000000001'
        resourceGroup = 'rg-models'; apimName = 'apim-models'; gatewayUrl = 'https://apim-models.azure-api.net/claude'
        foundryAccount = 'ai-models'; foundryResourceGroup = 'rg-foundry'; workspaceName = 'law-models'
        models = @('sonnet', 'opus', 'retired')
        deployments = @(
            [pscustomobject]@{ name = 'sonnet'; model = 'claude-sonnet-5'; version = '1'; capabilities = 'effort,thinking,adaptive_thinking'; claudeCode = '2.1.197'; note = 'preserve me' }
            [pscustomobject]@{ name = 'opus'; model = 'claude-opus-5'; version = '2' }
            [pscustomobject]@{ name = 'retired'; model = 'claude-opus-4-8'; version = '1' }
        )
        tiers = [pscustomobject]@{ standard = [pscustomobject]@{ tokensPerMinute = 20000 }; premium = [pscustomobject]@{ tokensPerDay = 5000000 } }
        desktopSignIn = [pscustomobject]@{ kind = 'helper-script' }
        decisions = [pscustomobject]@{}
        history = @([pscustomobject]@{ action = 'Setup'; decision = 'foundation' })
        customerField = 'preserve'
    }
    Save $global:P70recordPath $global:P70record
    Set-ClaudeRecordProperty $global:P70record '__recordPath' $global:P70recordPath
}
function Plan($Assignments = @{ 'next.opus' = 'premium'; 'claude-haiku-4-5' = 'both'; retired = 'drop' }) {
    New-ClaudeModelPlan -Record $global:P70record -RecordPath $global:P70recordPath -PriceBookPath $global:P70bookPath -TierAssignments $Assignments
}
function Apply($Plan) {
    Initialize-ClaudeModelChange -Record $global:P70record -Plan $Plan
    Invoke-ClaudeModelChange -Record $global:P70record -Plan $Plan | Out-Null
}

function Installer-Models($Standard, $Premium) {
    $source = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
    $from = $source.IndexOf('$deployed = @(Get-ClaudeDeployment')
    $to = $source.IndexOf('# ------------------------------------------------------------- 2. placement', $from)
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    $configAssignment = @($ast.FindAll({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$config'
    }, $true))[0].Extent.Text
    $body = '[CmdletBinding()]param([string[]]$StandardModels,[string[]]$PremiumModels)' + "`n" +
        $source.Substring($from, $to - $from) + "`n" + $configAssignment + "`n" +
        '[pscustomobject]@{ Standard=$modelsStd; Premium=$modelsPrm; Deployments=@($recordedDeployments); Config=$config }'
    function Write-Step { param($Text) }
    function Write-Ok { param($Text) }
    function Write-Note { param($Text) }
    function Read-Default { param($Prompt,$Default,$Help) $Default }
    function ConvertTo-ClaudeArmRegionName { param($Region) $Region }
    $FoundryAccount = 'ai-models'; $FoundryResourceGroup = 'rg-foundry'; $pendingDeployment = $null
    $gatewayUrl = 'https://apim-models.azure-api.net/claude'
    $acct = [pscustomobject]@{ tenantId = '00000000-0000-0000-0000-000000000001' }
    $desktopSignInRecord = @{ kind = 'helper-script' }
    $TpmStandard = 20000; $QuotaStandard = 500000; $TpmPremium = 80000; $QuotaPremium = 5000000
    & ([scriptblock]::Create($body)) -StandardModels $Standard -PremiumModels $Premium
}

$oldNoninteractive = $env:CLAUDE_NONINTERACTIVE
$env:CLAUDE_NONINTERACTIVE = '1'
try {
    Reset-State
    Check 'discovery identifies Claude by model and publisher, not deployment label' {
        $global:P70plan = Plan
        @($global:P70plan.Data.Discovery.Deployments).Count -eq 4 -and 'claude-not-really' -notin @($global:P70plan.Data.Discovery.Deployments.name)
    }
    Check 'plan shows custom deployment model, version, SKU, capacity and price status' {
        $text = Format-ClaudeFlowReview @($global:P70plan)
        $text -match 'next.opus' -and $text -match 'claude-opus-5-5' -and $text -match 'version 2' -and $text -match 'GlobalStandard' -and $text -match 'capacity 40' -and $text -match 'unpriced'
    }
    Check 'plan declares monthly inference cost unknown rather than free' {
        @($global:P70plan.Costs | Where-Object { $null -eq $_.MonthlyUsd -and $_.UnknownReason }).Count -gt 0
    }
    Check 'plan writes neither Azure nor record, book, profiles or snapshot' {
        $global:P70writes.Count -eq 0 -and -not $global:P70backupRead -and (Json $global:P70recordPath).customerField -eq 'preserve' -and -not (Test-Path (Join-Path $scratch 'profiles')) -and -not ((Json $global:P70bookPath).models.PSObject.Properties.Name -contains 'claude-haiku-4-5')
    }
    Check 'all model ARM discovery calls carry the selected subscription' {
        @($global:P70calls | Where-Object { $_[0] -ne 'account' -and (Arg $_ '--subscription') -ne $global:P70sub }).Count -eq 0
    }
    Check 'unchanged discovery yields the same fingerprint' { (Get-ClaudeFlowFingerprint @($global:P70plan)) -eq (Get-ClaudeFlowFingerprint @(Plan)) }
    Check 'tier assignment changes the fingerprint' { (Get-ClaudeFlowFingerprint @($global:P70plan)) -ne (Get-ClaudeFlowFingerprint @(Plan @{ 'next.opus' = 'both'; 'claude-haiku-4-5' = 'both'; retired = 'drop' })) }
    Check 'price change changes the fingerprint' {
        $b = Json $global:P70bookPath; $b.models.'claude-sonnet-5'.inputPerM = 3; Save $global:P70bookPath $b
        (Get-ClaudeFlowFingerprint @($global:P70plan)) -ne (Get-ClaudeFlowFingerprint @(Plan))
    }
    Reset-State
    Check 'a newly discovered unassigned model cannot silently gain a tier' { Reject { Plan @{ retired = 'drop' } } 'tier choice|assignment' }
    Check 'unknown assignment names are refused' { Reject { Plan @{ typo = 'both'; 'next.opus' = 'premium'; 'claude-haiku-4-5' = 'both' } } 'unknown.*(deployment|assignment)|not discovered' }
    Check 'unknown tier choices are refused' { Reject { Plan @{ 'next.opus' = 'everybody'; 'claude-haiku-4-5' = 'both' } } 'choice|tier|assignment' }
    Check 'list-shaped answers are refused, never string-joined' { Reject { Plan @{ 'next.opus' = @('both', '&calc'); 'claude-haiku-4-5' = 'both' } } 'scalar|choice|tier|assignment' }
    Check 'a missing deployment is kept unless explicitly dropped' { (Plan @{ 'next.opus' = 'premium'; 'claude-haiku-4-5' = 'both' }).Data.AfterNamedValues['models-standard'] -match ',retired,' }
    Check 'explicit retirement removes only the missing name' { $global:P70plan = Plan; $global:P70plan.Data.AfterNamedValues['models-standard'] -eq ',claude-haiku-4-5,sonnet,' }
    Check 'removing the last restricted entry never writes allow-all' {
        $global:P70nvs['models-standard'] = ',retired,'
        Reject { Plan @{ retired = 'drop'; 'next.opus' = 'premium'; 'claude-haiku-4-5' = 'premium' } } 'empty|allow.all|last'
    }
    Reset-State
    Check 'an unrestricted tier remains explicitly unrestricted when kept' {
        $global:P70nvs['models-standard'] = ',,'
        $p = Plan @{ 'next.opus' = 'both'; 'claude-haiku-4-5' = 'both'; retired = 'drop' }
        $p.Data.AfterNamedValues['models-standard'] -eq ',,' -and (Format-ClaudeFlowReview @($p)) -match 'unrestricted|allow.all'
    }
    Reset-State
    Check 'failed deployment cannot be newly allowed' {
        $global:P70rawDeployments[2].properties.provisioningState = 'Failed'
        Reject { Plan } 'Succeeded|provision'
    }
    Reset-State
    Check 'duplicate deployment names are refused' {
        $global:P70rawDeployments += $global:P70rawDeployments[0]
        Reject { Plan } 'duplicate'
    }
    Reset-State
    Check 'a failed deployment read is not an empty estate' { $global:P70azFailure = 'cognitiveservices account deployment list'; Reject { Plan } 'failed|exit|read' }
    Reset-State
    Check 'malformed deployment JSON is refused' { $global:P70badDeployments = 'not json'; Reject { Plan } 'JSON|array' }
    Reset-State
    Check 'object-shaped deployment JSON is not treated as one deployment' { $global:P70badDeployments = '{"value":[]}'; Reject { Plan } 'array' }
    Reset-State
    Check 'one deployment survives JSON array handling on both PowerShell hosts' {
        $global:P70rawDeployments = @($global:P70rawDeployments[0])
        $global:P70nvs['models-standard'] = ',sonnet,'; $global:P70nvs['models-premium'] = ',sonnet,'
        $p = Plan @{}
        @($p.Data.Discovery.Deployments).Count -eq 1 -and $p.Data.Discovery.Deployments[0].name -eq 'sonnet'
    }
    Reset-State
    Check 'missing model named values are not silently created as unrestricted lists' { $global:P70nvs.Remove('models-standard'); Reject { Plan } 'models-standard|missing' }
    Reset-State
    Check 'malformed comma sentinel lists are refused' { $global:P70nvs['models-standard'] = 'sonnet'; Reject { Plan } 'comma|sentinel|list' }
    Reset-State
    Check 'unsafe deployment names cannot reach az.cmd writes' { $global:P70rawDeployments[2].name = 'next&calc'; Reject { Plan } 'name|unsafe|characters' }
    Reset-State
    Check 'unsafe recorded resource names cannot reach az.cmd' { $global:P70record.foundryAccount = 'ai&calc'; Reject { Plan } 'name|unsafe|characters' }
    Reset-State
    Check 'object-shaped target inputs are refused before binding' { $global:P70record.foundryAccount = [pscustomobject]@{ value = 'ai' }; Reject { Plan } 'scalar|string|name' }
    Reset-State
    Check 'subscription names are refused instead of switching the active account' { $global:P70record.subscriptionId = 'other subscription'; Reject { Plan } 'subscription|GUID' }
    Reset-State
    Check 'a Foundry account different from the actual gateway backend is refused' { $global:P70backend = 'https://another.services.ai.azure.com/anthropic'; Reject { Plan } 'backend|Foundry' }
    Reset-State
    Check 'negative price entries are refused before any write' {
        $b = Json $global:P70bookPath; $b.models.'claude-haiku-4.5'.inputPerM = -1; Save $global:P70bookPath $b
        Reject { Plan } 'price|rate|negative'
    }
    Reset-State
    Check 'conflicting dotted and hyphenated prices are not silently selected' {
        $b = Json $global:P70bookPath
        Set-ClaudeRecordProperty $b.models 'claude-haiku-4-5' ([pscustomobject]@{ inputPerM = 99; outputPerM = 5 })
        $global:P70rawDeployments[3].name = 'quick'
        Save $global:P70bookPath $b
        Reject { Plan @{ quick = 'both'; 'next.opus' = 'premium' } } 'ambiguous|conflict'
    }
    Reset-State
    Check 'deployment-specific negotiated price takes precedence over model mapping' {
        $b = Json $global:P70bookPath; Set-ClaudeRecordProperty $b.models 'sonnet' ([pscustomobject]@{ inputPerM = 1.5; outputPerM = 7.5 }); Save $global:P70bookPath $b
        $p = Plan
        $p.Data.PriceBookAfter.models.sonnet.inputPerM -eq 1.5
    }
    Reset-State
    Check 'apply cannot run without preparation and snapshot' {
        $global:P70plan = Plan
        (Reject { Invoke-ClaudeModelChange -Record $global:P70record -Plan $global:P70plan } 'snapshot|prepar') -and
            @($global:P70calls | Where-Object { ($_ -join ' ') -match '^apim nv (update|create)' }).Count -eq 0
    }
    Check 'failed snapshot stops Azure and local managed writes' {
        $global:P70backupFails = $true
        (Reject { Apply $global:P70plan } 'backup|snapshot') -and $global:P70writes.Count -eq 0 -and (Json $global:P70recordPath).deployments[0].version -eq '1'
    }
    Reset-State
    Check 'changed tier state after review is refused before writes' {
        $p = Plan; $global:P70nvs['models-premium'] = ',opus,sonnet,'
        (Reject { Apply $p } 'changed|stale|replan') -and $global:P70writes.Count -eq 0
    }
    Reset-State
    Check 'changed deployment version after review is refused' {
        $p = Plan; $global:P70rawDeployments[0].properties.model.version = '3'
        Reject { Apply $p } 'changed|stale|replan'
    }
    Reset-State
    Check 'changed price book after review is refused' {
        $p = Plan; $b = Json $global:P70bookPath; $b.models.retired.inputPerM = 4; Save $global:P70bookPath $b
        Reject { Apply $p } 'changed|stale|replan'
    }
    Reset-State
    Check 'changed record after review is refused' {
        $p = Plan; $r = Json $global:P70recordPath; $r.customerField = 'concurrent'; Save $global:P70recordPath $r
        Reject { Apply $p } 'changed|stale|replan'
    }
    Reset-State
    Check 'Turnstile ownership is visible in a read-only plan' {
        $global:P70nvs['turnstile-integration'] = 'version=1;url=https://turnstile.contoso.example;governanceAuthority=Turnstile;budgetAuthority=Gateway'
        $global:P70plan = Plan
        (Format-ClaudeFlowReview @($global:P70plan)) -match 'Turnstile'
    }
    Check 'apply refuses Turnstile-owned model lists without any write' { (Reject { Apply $global:P70plan } 'Turnstile owns') -and $global:P70writes.Count -eq 0 -and -not $global:P70backupRead }
    Reset-State
    Check 'invalid governance ownership cannot grant write authority' {
        $global:P70nvs['turnstile-integration'] = 'garbage'
        Reject { Apply (Plan) } 'authority|integration'
    }
    Reset-State
    Check 'a failed named-value write is loud and does not claim record success' {
        $p = Plan; $global:P70failWrite = 'models-premium'
        (Reject { Apply $p } 'failed|exit') -and (Json $global:P70recordPath).deployments[0].version -eq '1'
    }
    Reset-State
    Check 'a successful exit with a lost named-value write fails readback' {
        $p = Plan; $global:P70dropWrite = $true
        Reject { Apply $p } 'readback|read.back|match|land'
    }
    Reset-State
    Check 'apply snapshots first and changes only model named values' {
        $p = Plan; Apply $p
        $global:P70backupRead -and $global:P70writes.Count -eq 2 -and @($global:P70writes | Where-Object { $_ -notin @('models-standard', 'models-premium') }).Count -eq 0 -and $global:P70nvs['quota-standard'] -eq '654321'
    }
    Check 'named-value writes carry the target subscription' {
        @($global:P70calls | Where-Object { ($_[0..2] -join ' ') -match '^apim nv (update|create)$' -and (Arg $_ '--subscription') -ne $global:P70sub }).Count -eq 0
    }
    Check 'the record is the allowed live union with actual version and preserved overrides' {
        $r = Json $global:P70recordPath; $d = @($r.deployments | Where-Object name -eq sonnet)[0]
        $r.customerField -eq 'preserve' -and $d.version -eq '2' -and $d.note -eq 'preserve me' -and $d.capabilities -eq 'effort,thinking,adaptive_thinking' -and 'retired' -notin $r.models -and @($r.models).Count -eq 4
    }
    Check 'tier-specific model lists preserve the other tier properties' {
        $r = Json $global:P70recordPath
        ($r.tiers.standard.models -join ',') -eq 'claude-haiku-4-5,sonnet' -and $r.tiers.standard.tokensPerMinute -eq 20000 -and 'next.opus' -in $r.tiers.premium.models
    }
    Check 'price mapping adds deployed Haiku spelling without losing historical prices or metadata' {
        $b = Json $global:P70bookPath
        $b.models.'claude-haiku-4-5'.inputPerM -eq 1 -and $b.models.retired.outputPerM -eq 15 -and $b.privateNote -eq 'keep' -and $b.date -eq '2026-09-15'
    }
    Check 'Opus 5.5 stays unpriced instead of inheriting Opus 5 rates' { 'next.opus' -notin (Json $global:P70bookPath).models.PSObject.Properties.Name }
    Check 'both complete device profile families are generated' {
        (Test-Path (Join-Path $scratch 'profiles\standard\claude-code.reg')) -and (Test-Path (Join-Path $scratch 'profiles\premium\claude-desktop.mobileconfig'))
    }
    Check 'standard client picker and every pin stay in its tier' {
        $p = Json (Join-Path $scratch 'profiles\standard\claude-code.managed-settings.json')
        ($p.availableModels -join ',') -eq 'claude-haiku-4-5,sonnet' -and $p.env.ANTHROPIC_DEFAULT_OPUS_MODEL -in $p.availableModels -and $p.env.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'claude-haiku-4-5'
    }
    Check 'premium pins the newest Opus deployment and declares adaptive capabilities' {
        $p = Json (Join-Path $scratch 'profiles\premium\claude-code.managed-settings.json')
        $p.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'next.opus' -and $p.env.ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES -match 'adaptive_thinking'
    }
    Check 'Desktop inferenceModels exactly match that tier, including one-item arrays' {
        $d = Json (Join-Path $scratch 'profiles\standard\claude-desktop.managed-settings.json')
        (@($d.inferenceModels.name) -join ',') -eq 'claude-haiku-4-5,sonnet'
    }
    Check 'workstation handover records have only their own deployments and no run journal' {
        $r = Json (Join-Path $scratch 'profiles\standard\claude-gateway.json')
        (@($r.deployments.name) -join ',') -eq 'claude-haiku-4-5,sonnet' -and 'activeRun' -notin $r.PSObject.Properties.Name -and '__recordPath' -notin $r.PSObject.Properties.Name
    }
    Check 'workstation helper consumes the generated record with unchanged P67 rules' {
        $r = Json (Join-Path $scratch 'profiles\premium\claude-gateway.json')
        $settings = Set-ClaudeCodeGatewaySettings -Settings ([pscustomobject]@{ theme = 'keep' }) -GatewayUrl $r.gatewayUrl -Deployments @(Get-ClaudeRecordedDeployment -Config $r)
        $settings.theme -eq 'keep' -and $settings.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'next.opus' -and 'claude-haiku-4-5' -in $settings.availableModels
    }
    Check 'handover names both setups and their exact changed settings' {
        $note = Get-Content (Join-Path $scratch 'profiles\README.md') -Raw
        $note -match 'Setup-ClaudeWorkstation.ps1' -and $note -match 'setup-claude-workstation.sh' -and $note -match 'availableModels' -and $note -match 'inferenceModels' -and $note -match 'capabilit'
    }
    Check 'rerunning the same choices makes no additional named-value write' {
        $global:P70record = Json $global:P70recordPath; Set-ClaudeRecordProperty $global:P70record '__recordPath' $global:P70recordPath
        $before = $global:P70writes.Count
        Apply (Plan @{ 'next.opus' = 'premium'; 'claude-haiku-4-5' = 'both' })
        $global:P70writes.Count -eq $before
    }
    Check 'standalone profile regeneration honours recorded tier lists' {
        & (Join-Path $root 'scripts\New-ClaudeCodePolicy.ps1') -ConfigPath $global:P70recordPath -Tier standard -OutputPath (Join-Path $scratch 'regenerated') | Out-Null
        $p = Json (Join-Path $scratch 'regenerated\claude-code.managed-settings.json')
        ($p.availableModels -join ',') -eq 'claude-haiku-4-5,sonnet' -and $p.env.ANTHROPIC_DEFAULT_OPUS_MODEL -in $p.availableModels
    }

    Reset-State
    $standalone = Join-Path $root 'scripts\Sync-ClaudeModels.ps1'
    $answers = Join-Path $scratch 'answers.json'
    Save $answers @{ 'models.tiers.next~opus' = 'premium'; 'models.tiers.claude-haiku-4-5' = 'both'; 'models.tiers.retired' = 'drop'; 'models.priceBookPath' = $global:P70bookPath }
    Check 'standalone answers-file PlanOnly prints a fingerprint and writes nothing' {
        $global:P70preview = & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -PlanOnly *>&1 | Out-String
        $global:P70preview -match 'Fingerprint:\s+[a-f0-9]{64}' -and $global:P70writes.Count -eq 0 -and -not $global:P70backupRead
    }
    Check 'standalone plan waits state their purpose, estimate and elapsed time' { $global:P70preview -match 'about \d+ s' -and $global:P70preview -match '(completed|read|finished|took) in [0-9.,]+ s' }
    Check 'standalone refuses the wrong fingerprint without creating a snapshot' {
        (Reject { & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -ApprovedPlanFingerprint '00000000' } 'fingerprint') -and -not $global:P70backupRead
    }
    Check 'standalone WhatIf writes neither snapshot nor Azure' {
        & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -WhatIf | Out-Null
        -not $global:P70backupRead -and $global:P70writes.Count -eq 0
    }
    Check 'flow module is Change-only and owns models' {
        . (Join-Path $root 'scripts\flow\Models.ps1')
        $info = Get-ClaudeFlowStepInfo
        $info.DecisionKey -eq 'models' -and ($info.Actions -join ',') -eq 'Change'
    }
    Check 'flow uses encoded per-deployment answer keys, with no silent default for new models' {
        . (Join-Path $root 'scripts\flow\Models.ps1')
        $qs = @(Get-ClaudeFlowStepQuestions -Record $global:P70record -Discovery ([pscustomobject]@{}))
        $q = @($qs | Where-Object Key -eq 'models.tiers.next~opus')[0]
        $q.Options.Count -ge 4 -and -not $q.AcceptRecommendedWithoutConsole -and 'models.tiers.retired' -in $qs.Key
    }
    Check 'real guided Change plans from the same answers without a write' {
        $global:P70flowPreview = & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Change -Change models -RecordPath $global:P70recordPath -AnswersPath $answers -PlanOnly *>&1 | Out-String
        $global:P70flowPreview -match '\[Models\]' -and $global:P70flowPreview -match 'Fingerprint:\s+[a-f0-9]{64}' -and $global:P70writes.Count -eq 0 -and -not $global:P70backupRead
    }
    Check 'flow takes a failed snapshot before writing its activeRun journal' {
        $fingerprint = [regex]::Match($global:P70flowPreview, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        $global:P70backupFails = $true
        (Reject { & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Change -Change models -RecordPath $global:P70recordPath -AnswersPath $answers -ApprovedPlanFingerprint $fingerprint } 'backup|snapshot') -and 'activeRun' -notin (Json $global:P70recordPath).PSObject.Properties.Name -and $global:P70writes.Count -eq 0
    }
    $global:P70backupFails = $false
    Check 'real guided Change applies and verifies without losing top-level models' {
        $fingerprint = [regex]::Match($global:P70flowPreview, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Change -Change models -RecordPath $global:P70recordPath -AnswersPath $answers -ApprovedPlanFingerprint $fingerprint | Out-Null
        $r = Json $global:P70recordPath
        @($r.models).Count -eq 4 -and 'activeRun' -notin $r.PSObject.Properties.Name -and @($r.history | Where-Object decision -eq models).Count -eq 1
    }
    Check 'installer names the existing lifecycle command, not a missing capability script' {
        $text = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
        $text -match 'Sync-ClaudeModels.ps1' -and $text -notmatch 'Set-ClaudeCapability.ps1'
    }
    Check 'installer accepts explicit initial model lists for an unattended isolated install' {
        $command = Get-Command (Join-Path $root 'Install-ClaudeGateway.ps1')
        $command.Parameters.ContainsKey('StandardModels') -and $command.Parameters.ContainsKey('PremiumModels')
    }
    Check 'installer uses only the specified models and records their live model identities' {
        $selected = Installer-Models @('sonnet') @('sonnet','opus')
        $selected.Standard -eq ',sonnet,' -and $selected.Premium -eq ',sonnet,opus,' -and @($selected.Deployments).Count -eq 2 -and $selected.Deployments[0].model -match '^claude-'
    }
    Check 'installer refuses an explicitly supplied undeployed model before deployment' {
        Reject { Installer-Models @('made-up') @('opus') } 'not deployed|unknown.*deployment'
    }
    Check 'model choices show the price status before the administrator selects a tier' {
        Reset-State
        $state = Get-ClaudeModelDiscovery (Get-ClaudeModelTarget $global:P70record)
        $qs = @(Get-ClaudeModelQuestions -Record $global:P70record -Discovery $state -PriceBook (Get-ClaudeModelPriceBook $global:P70bookPath))
        @($qs | Where-Object Key -eq 'models.tiers.next~opus')[0].Question -match 'unpriced' -and @($qs | Where-Object Key -eq 'models.tiers.claude-haiku-4-5')[0].Question -match 'per million'
    }
    Check 'oversized model lists fail before backup or writes' {
        $extra = 1..85 | ForEach-Object { 'missing-' + $_.ToString('000') + ('x' * 45) }
        $global:P70nvs['models-standard'] = ',sonnet,' + ($extra -join ',') + ','
        (Reject { Plan } '4096') -and -not $global:P70backupRead
    }
    Check 'a direct-Foundry record is refused by the shared flow implementation' {
        Reset-State; $global:P70record.mode = 'foundry-direct'
        Reject { Plan } 'gateway record|mode'
    }
    Check 'profiles preserve a single deployment as JSON arrays in both clients' {
        Reset-State; $global:P70rawDeployments = @($global:P70rawDeployments[0])
        $global:P70nvs['models-standard'] = ',sonnet,'; $global:P70nvs['models-premium'] = ',sonnet,'
        Apply (Plan @{})
        $desktop = Json (Join-Path $scratch 'profiles\standard\claude-desktop.managed-settings.json')
        $code = Json (Join-Path $scratch 'profiles\standard\claude-code.managed-settings.json')
        $desktop.inferenceModels -is [array] -and @($desktop.inferenceModels).Count -eq 1 -and $code.availableModels -is [array] -and $code.availableModels[0] -eq 'sonnet'
    }
    Check 'retrying exactly the same standalone answers after retirement is idempotent' {
        Reset-State
        $preview = & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -PlanOnly *>&1 | Out-String
        $fp = [regex]::Match($preview, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -ApprovedPlanFingerprint $fp | Out-Null
        $preview = & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -PlanOnly *>&1 | Out-String
        $fp = [regex]::Match($preview, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        $before = $global:P70writes.Count
        & $standalone -RecordPath $global:P70recordPath -AnswersPath $answers -ApprovedPlanFingerprint $fp | Out-Null
        $global:P70writes.Count -eq $before
    }
    Check 'a nonzero Azure exit carrying valid JSON is still a failed read' {
        Reset-State; $global:P70azFailure = 'cognitiveservices account deployment list'; $global:P70failureJson = '[]'
        Reject { Plan } 'az exit 3'
    }
    Check 'the shared named-value writer reports a failed native command itself' {
        Reset-State; $global:P70backupRead = $true; $global:P70failWrite = 'models-standard'
        Reject { Set-ApimNamedValue -ResourceGroup rg-models -ApimName apim-models -SubscriptionId $global:P70sub -Id models-standard -Value ',sonnet,' } 'az exit 7'
    }
    Check 'a profile renderer change invalidates a prepared model plan' {
        Reset-State; $p = Plan; $p.Data.RendererStamp = 'not-the-reviewed-renderer'
        Reject { Apply $p } 'profile renderer'
    }
    Check 'an unsafe subscription is refused before discovery even without a tenant in the record' {
        Reset-State; $global:P70record.subscriptionId = 'bad&subscription'
        $global:P70record.PSObject.Properties.Remove('tenantId')
        (Reject { Plan } 'subscription|GUID') -and $global:P70calls.Count -eq 0
    }
    Check 'model review distinguishes an existing recorded model from a newly discovered model' {
        Reset-State
        $p = Plan; $text = Format-ClaudeFlowReview @($p)
        $text -match 'record: new' -and $text -match 'record: version 1 -> 2'
    }
    Check 'backup token discovery is bound to the model target subscription' {
        Reset-State; Apply (Plan)
        @($global:P70calls | Where-Object { ($_ -join ' ') -like 'account get-access-token*' -and (Arg $_ '--subscription') -ne $global:P70sub }).Count -eq 0
    }
    Check 'a fresh installer record without decisions survives the flow run journal' {
        Reset-State
        $global:P70record.PSObject.Properties.Remove('decisions')
        $global:P70record.PSObject.Properties.Remove('schemaVersion')
        $global:P70record.PSObject.Properties.Remove('__recordPath')
        Save $global:P70recordPath $global:P70record
        $preview = & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Change -Change models -RecordPath $global:P70recordPath -AnswersPath $answers -PlanOnly *>&1 | Out-String
        $fp = [regex]::Match($preview, 'Fingerprint:\s+([a-f0-9]{64})').Groups[1].Value
        & (Join-Path $root 'Start-ClaudeGateway.ps1') -Action Change -Change models -RecordPath $global:P70recordPath -AnswersPath $answers -ApprovedPlanFingerprint $fp | Out-Null
        $r = Json $global:P70recordPath
        @($r.models).Count -eq 4 -and @($r.history | Where-Object decision -eq models).Count -eq 1 -and 'activeRun' -notin $r.PSObject.Properties.Name
    }
    $malformedRows = @(
        @{ Name = 'null model'; Break = { $global:P70rawDeployments[0].properties.model = $null } }
        @{ Name = 'missing model name'; Break = { $global:P70rawDeployments[0].properties.model.PSObject.Properties.Remove('name') } }
        @{ Name = 'empty publisher'; Break = { $global:P70rawDeployments[0].properties.model.format = '' } }
        @{ Name = 'array model name'; Break = { $global:P70rawDeployments[0].properties.model.name = @('claude-sonnet-5') } }
        @{ Name = 'object version'; Break = { $global:P70rawDeployments[0].properties.model.version = [pscustomobject]@{ value = '2' } } }
        @{ Name = 'null deployment'; Break = { $global:P70rawDeployments[0] = $null } }
        @{ Name = 'scalar deployment'; Break = { $global:P70rawDeployments[0] = 'sonnet' } }
        @{ Name = 'array properties'; Break = { $global:P70rawDeployments[0].properties = @($global:P70rawDeployments[0].properties) } }
        @{ Name = 'array model'; Break = { $global:P70rawDeployments[0].properties.model = @($global:P70rawDeployments[0].properties.model) } }
        @{ Name = 'malformed non-Claude row'; Break = { $global:P70rawDeployments[4].properties.model = $null } }
    )
    foreach ($case in $malformedRows) {
        Check "Q1 mixed discovery refuses $($case.Name) before Claude filtering" {
            Reset-State; & $case.Break
            (Reject { Plan } 'deployment identity') -and -not $global:P70backupRead -and $global:P70writes.Count -eq 0
        }
    }
    foreach ($tier in 'standard','premium') {
        foreach ($empty in @('   ', ',,', ' , , ')) {
            Check "S1 $tier rejects a restriction containing only '$empty'" {
                Reset-State
                $standard = @('sonnet'); $premium = @('sonnet')
                if ($tier -eq 'standard') { $standard = @($empty) } else { $premium = @($empty) }
                Reject { Installer-Models $standard $premium } 'empty|at least one'
            }
        }
    }
    Check 'S1 failed installer discovery is not an unrestricted model list' {
        Reset-State; $global:P70azFailure = 'cognitiveservices account deployment list'; $global:P70failureJson = '[]'
        Reject { Installer-Models @('sonnet') @('sonnet') } 'az exit 3'
    }
    Check 'S1 malformed installer discovery is refused' {
        Reset-State; $global:P70badDeployments = 'not json'
        Reject { Installer-Models @('sonnet') @('sonnet') } 'JSON|array'
    }
    Check 'S1 malformed mixed installer rows are not silently dropped' {
        Reset-State; $global:P70rawDeployments[0].properties.model = $null
        Reject { Installer-Models @('opus') @('opus') } 'deployment identity'
    }
    Check 'S1 empty installer discovery cannot discard explicit restrictions' {
        Reset-State; $global:P70rawDeployments = @()
        Reject { Installer-Models @('sonnet') @('sonnet') } 'No Claude deployment|not deployed'
    }
    Check 'S1 a non-Claude-only account cannot create unrestricted Claude tiers' {
        Reset-State; $global:P70rawDeployments = @($global:P70rawDeployments[4])
        Reject { Installer-Models @('sonnet') @('sonnet') } 'No Claude deployment|not deployed'
    }
    Check 'C1 installer records normalized per-tier models and exact sentinel lists' {
        Reset-State
        $selected = Installer-Models @(' sonnet, sonnet ') @('opus', ' sonnet ')
        $cfg = Clone $selected.Config
        ($cfg.tiers.standard.models -join ',') -eq 'sonnet' -and $cfg.tiers.standard.modelAllowList -eq ',sonnet,' -and
            ($cfg.tiers.premium.models -join ',') -eq 'opus,sonnet' -and $cfg.tiers.premium.modelAllowList -eq ',opus,sonnet,' -and
            $cfg.tiers.standard.tokensPerMinute -eq 20000 -and $cfg.tiers.premium.tokensPerDay -eq 5000000
    }
    foreach ($tier in 'standard','premium') {
        Check "C1 an initial Sonnet-only $tier profile never offers excluded Opus" {
            Reset-State; $selected = Installer-Models @('sonnet') @('sonnet')
            $path = Join-Path $scratch "installer-$tier.json"; Save $path $selected.Config
            $out = Join-Path $scratch "installer-$tier"
            & (Join-Path $root 'scripts\New-ClaudeCodePolicy.ps1') -ConfigPath $path -Tier $tier -OutputPath $out | Out-Null
            $code = Json (Join-Path $out 'claude-code.managed-settings.json')
            $desktop = Json (Join-Path $out 'claude-desktop.managed-settings.json')
            $selected.Standard -eq ',sonnet,' -and $selected.Premium -eq ',sonnet,' -and
                ($code.availableModels -join ',') -eq 'sonnet' -and (@($desktop.inferenceModels.name) -join ',') -eq 'sonnet' -and
                $code.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'sonnet'
        }
    }
}
finally {
    $env:CLAUDE_NONINTERACTIVE = $oldNoninteractive
    Remove-Item function:\az, function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Write-Host "Model lifecycle: $global:P70count assertions, $global:P70failed failed."
if ($global:P70failed) { exit 1 }
exit 0
