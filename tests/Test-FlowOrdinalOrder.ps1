# P76: one plan, one order on both shells. Sort-Object compares by culture, and Windows PowerShell
# 5.1 (.NET Framework, NLS) and PowerShell 7 (.NET, ICU) weigh a hyphen differently, so a plan built
# from a culture sort had two fingerprints: measured live on 2026-09-28 over the reference record,
# where Monitoring listed the two workbooks in a different order on each shell. Every sort that feeds
# a plan orders by code point instead (Sort-ClaudeFlowOrdinal), and every shipped step is compared.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Guided flow - one order and one fingerprint on both shells' -ForegroundColor Cyan

# ------------------------------------------------------------------ no culture sort in the flow
# The flow's scripts: everything under scripts/flow, and each script at the root or in scripts/
# that loads FlowContract.ps1 (Start-ClaudeGateway.ps1 orders the step modules, and
# Update-ClaudeGateway.ps1 the migrations, before either plan is fingerprinted; the model
# lifecycle, the price book, the deployment list, the region choice and the installer load it for
# Sort-ClaudeFlowOrdinal).
$entryPoints = @(@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File) |
    Where-Object { [IO.File]::ReadAllText($_.FullName) -match 'FlowContract\.ps1' })
$flowScripts = @(@(Get-ChildItem -LiteralPath (Join-Path $root 'scripts\flow') -Recurse -Filter '*.ps1' -File) + $entryPoints)
$hits = foreach ($f in $flowScripts) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Sort-Object', 'sort' }, $true)) {
        '{0}:{1}' -f $f.FullName.Substring($root.Length + 1), $c.Extent.StartLineNumber
    }
}
$entryNames = @($entryPoints | ForEach-Object { $_.FullName.Substring($root.Length + 1) })
$mustLoad = @('Start-ClaudeGateway.ps1', 'scripts\Update-ClaudeGateway.ps1', 'Install-ClaudeGateway.ps1', 'scripts\ClaudeModelLifecycle.ps1',
    'scripts\ClaudeModelPrices.ps1', 'scripts\ClaudeModelDeployment.ps1', 'scripts\ClaudeGatewayRegion.ps1')
$missing = @($mustLoad | Where-Object { $entryNames -notcontains $_ })
Assert 'the scan covers the scripts that load FlowContract.ps1: the orchestrator, the Update, the installer, the model lifecycle, prices, deployments and regions' (-not $missing.Count) ("missing: " + ($missing -join ', '))
Assert 'the flow''s scripts hold no Sort-Object: every sort uses Sort-ClaudeFlowOrdinal' (@($hits).Count -eq 0) (@($hits) -join ', ')

# ------------------------------------------------------------------ every sort the plans can reach
# The scripts that the fingerprinted plans load: Start-ClaudeGateway.ps1 and every step module, the
# Update migrations, the model sync and the installer, and every script they dot-source, followed
# through the syntax tree. A script a step runs as its own command (Monitoring runs
# Publish-ClaudeWorkbook.ps1 with &) is not followed: its output is its own, and the one such script
# with its own fingerprint, the network edge review, hashes the stored text of its review file on
# apply (ClaudeNetworkReview.ps1). A Sort-Object in the scripts followed either became
# Sort-ClaudeFlowOrdinal or is listed here with the reason its order is the same on both shells or
# reaches no plan and no Azure write.
# A listed sort that is gone or changed fails too, so the list is read again when its code changes.
$valueKey = 'value key: numbers, times and versions compare by value on both shells'
$allowed = @(
    @{ File = 'scripts\AzureRetailPrice.ps1'; Line = '@($rows | Sort-Object { [decimal]$_.tierMinimumUnits })[0]'; Reason = $valueKey }
    @{ File = 'scripts\AzureRetailPrice.ps1'; Line = '@($rows | Sort-Object { [decimal]$_.tierMinimumUnits })[-1]'; Reason = $valueKey }
    @{ File = 'scripts\AzureRetailPrice.ps1'; Line = '$pick = @($_.Group | Sort-Object { [decimal]$_.tierMinimumUnits })[-1]'; Reason = $valueKey }
    @{ File = 'scripts\AzureRetailPrice.ps1'; Line = '$key = "$ServiceName|*|" + (@($MeterName | Sort-Object) -join '','')'; Reason = 'in-process: a cache key read and written by one process' }
    @{ File = 'scripts\ClaudeFinOpsPrices.ps1'; Line = 'Sort-Object { [decimal]$_.tierMinimumUnits })'; Reason = $valueKey }
    @{ File = 'scripts\ClaudeBusinessUnit.ps1'; Line = 'Sort-Object -Property @{ Expression = ''Depth''; Descending = $true }, @{ Expression = ''Position''; Ascending = $true } |'; Reason = "$valueKey (two integers)" }
    @{ File = 'scripts\ClaudeBusinessUnit.ps1'; Line = 'throw ("No price for ''$Model''. Known models: " + (($script:ClaudePriceBook.Keys | Sort-Object) -join '', '') + ".")'; Reason = 'console only: the text of an error' }
    @{ File = 'scripts\ClaudeClientSupport.ps1'; Line = 'Sort-Object { ConvertTo-ClaudeClientVersion $_.Name } -Descending)'; Reason = "$valueKey ([version])" }
    @{ File = 'scripts\ClaudeClientSupport.ps1'; Line = 'return [string](@($versions | Sort-Object { ConvertTo-ClaudeClientVersion $_ })[0])'; Reason = "$valueKey ([version])" }
    @{ File = 'scripts\ClaudeClientSupport.ps1'; Line = 'return @([string]$Capabilities -split '','' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)'; Reason = 'in-process: two capability sets compared in one process (Get-ClaudeCodeAliasCheck); the workstation bundle fetches only the files Setup-ClaudeWorkstation.ps1 names (New-OnboardingEmail.ps1), so this file loads nothing more' }
    @{ File = 'scripts\ClaudeChoice.ps1'; Line = '$groups = @($rows | Group-Object group | Sort-Object Name)'; Reason = 'console only: a menu, recommended only when it has one entry' }
    @{ File = 'scripts\ClaudeChoice.ps1'; Line = '$groups = @($apps | Where-Object { $_.resourceGroup } | Group-Object resourceGroup | Sort-Object Name)'; Reason = 'console only: a menu, recommended only when it has one entry' }
    @{ File = 'scripts\ClaudeChoice.ps1'; Line = 'Sort-Object @{ Expression = ''LastWriteTimeUtc''; Descending = $true }, Name)'; Reason = 'console only: a backup menu, newest first by time; the name orders only files written in the same tick' }
    @{ File = 'scripts\ClaudeChoice.ps1'; Line = '$models = @($Names | Where-Object { $_ } | Sort-Object -Unique)'; Reason = 'console only: Select-ClaudeModel, called by Setup-ClaudeFoundryDirect, Show-Governance and Test-ClaudeNetworkEdge, none of which the plans load' }
    @{ File = 'scripts\ClaudeTurnstileApply.ps1'; Line = ''','' + ((@($Value.Trim('','') -split '','' | Where-Object { $_ }) | Sort-Object) -join '','') + '','''; Reason = 'in-process: both sides of one comparison are put in this form by one process; the value written is the desired one' }
    @{ File = 'scripts\ClaudeTurnstileApply.ps1'; Line = 'foreach ($item in @($Snapshot.BudgetItems | Where-Object { $_.scope_type -in ''organization'', ''department'' } | Sort-Object scope_type, scope_id)) {'; Reason = 'in-process: revisions compared key by key; their order reaches only the apply report' }
    @{ File = 'scripts\ClaudeTurnstileApply.ps1'; Line = '$keys = @(@($revisions.Keys) + @($latest.Keys) | Sort-Object -Unique)'; Reason = 'in-process: a set of keys, each compared on its own' }
)
$repoScripts = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File | Where-Object { $_.FullName.Substring($root.Length + 1) -notmatch '^(tests|node_modules|\.git)\\' })
$closureRoots = @(@('Start-ClaudeGateway.ps1', 'scripts\Update-ClaudeGateway.ps1', 'scripts\Sync-ClaudeModels.ps1', 'Install-ClaudeGateway.ps1' | ForEach-Object { Join-Path $root $_ }) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts\flow') -Recurse -Filter '*.ps1' -File | ForEach-Object { $_.FullName }))
$closure = [ordered]@{}
$unresolved = [System.Collections.Generic.List[string]]::new()
$queue = [System.Collections.Generic.Queue[string]]::new()
foreach ($r in $closureRoots) { $queue.Enqueue($r) }
while ($queue.Count) {
    $path = $queue.Dequeue()
    if ($closure.Contains($path)) { continue }
    $closure[$path] = $true
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true)) {
        foreach ($m in [regex]::Matches($c.Extent.Text, '[''"]([^''"]+\.ps1)[''"]')) {
            $suffix = '\' + ($m.Groups[1].Value -replace '/', '\').TrimStart('.', '\')
            $found = @($repoScripts | Where-Object { $_.FullName.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) })
            if (-not $found.Count) { $unresolved.Add("$($path.Substring($root.Length + 1)) -> $($m.Groups[1].Value)") }
            foreach ($f in $found) { $queue.Enqueue($f.FullName) }
        }
    }
}
$closureNames = @($closure.Keys | ForEach-Object { $_.Substring($root.Length + 1) })
$expectedInClosure = @('scripts\flow\FlowContract.ps1', 'scripts\ClaudeModelLifecycle.ps1', 'scripts\ClaudeChoice.ps1', 'scripts\AzureRetailPrice.ps1', 'scripts\ClaudeGatewayRegion.ps1', 'scripts\ClaudeTurnstileApply.ps1', 'scripts\ClaudeClientSupport.ps1')
$notFollowed = @($expectedInClosure | Where-Object { $closureNames -notcontains $_ })
Assert 'the plans'' scripts are followed through every dot-source, and each one named exists' (-not $notFollowed.Count -and -not $unresolved.Count -and $closureNames.Count -ge 30) ("$($closureNames.Count) scripts; not followed: $($notFollowed -join ', '); unresolved: $($unresolved -join ', ')")
$left = @{}
foreach ($a in $allowed) { $k = $a.File + '|' + $a.Line; if ($left.ContainsKey($k)) { $left[$k]++ } else { $left[$k] = 1 } }
$unlisted = [System.Collections.Generic.List[string]]::new()
foreach ($path in $closure.Keys) {
    $lines = [IO.File]::ReadAllLines($path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Sort-Object', 'sort' }, $true)) {
        $k = $path.Substring($root.Length + 1) + '|' + $lines[$c.Extent.StartLineNumber - 1].Trim()
        if ($left.ContainsKey($k) -and $left[$k] -gt 0) { $left[$k]-- } else { $unlisted.Add(('{0}:{1}' -f $path.Substring($root.Length + 1), $c.Extent.StartLineNumber)) }
    }
}
$stale = @($left.Keys | Where-Object { $left[$_] -gt 0 } | ForEach-Object { $_.Split('|')[0] })
Assert 'every Sort-Object the plans can reach is Sort-ClaudeFlowOrdinal or listed with its reason' (-not $unlisted.Count) ($unlisted -join ', ')
Assert "each of the $($allowed.Count) listed sorts is still where the list says, unchanged" (-not $stale.Count) ("gone or changed in: " + ($stale -join ', '))

$shells = [ordered]@{ '7' = (Get-Process -Id $PID).Path }
$ps51 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { '' }
if ($ps51 -and (Test-Path -LiteralPath $ps51)) { $shells['5.1'] = $ps51 }
else { Write-Host '  Windows PowerShell 5.1 is not on this machine; the comparisons need both shells and are left out.' -ForegroundColor Yellow }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('flow-ordinal-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
function Invoke-Probe([string]$Shell, [string]$Script, [string[]]$Arguments = @()) {
    $out = & $shells[$Shell] -NoProfile -NonInteractive -File $Script @Arguments 2>&1 | Out-String
    $json = @($out -split "`r?`n" | Where-Object { $_ -like 'P76JSON *' } | Select-Object -Last 1)
    if (-not $json.Count) { return [pscustomobject]@{ Failed = $true; Output = $out } }
    $parsed = $json[0].Substring(8) | ConvertFrom-Json
    $parsed | Add-Member -NotePropertyName Failed -NotePropertyValue $false
    $parsed | Add-Member -NotePropertyName Output -NotePropertyValue $out
    return $parsed
}
function Get-Tail([string]$Text) { (@($Text -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | ' }

try {
    # ------------------------------------------------------------------ the helper
    # Words whose culture order differs between NLS and ICU: a hyphen, an underscore, a prefix. Every
    # comparison below is case-sensitive: -eq ignores case, and the order of 'B' and 'b' is part of it.
    $helperProbe = Join-Path $scratch 'helper.ps1'
    Set-Content -LiteralPath $helperProbe -Encoding UTF8 -Value @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\flow\FlowContract.ps1')
$words = @('workbook.json', 'workbook-chargeback.json', 'budgets', 'bu-members', 'Models-Standard', 'models-premium', 'claude-opus-5-5', 'claude-opus-5', 'coop', 'co-op', 'b', 'B', 'a_b', 'a-b')
$files = @([pscustomobject]@{ Name = 'workbook.json' }, [pscustomobject]@{ Name = 'workbook-chargeback.json' })
. (Join-Path $Root 'scripts\flow\Budgets.ps1')
$book = Get-BudgetsFlowPriceBook -Models @('zeta-model', 'claude-sonnet-5', 'Alpha-Model', 'alpha-model', 'zeta-model') -Path (Join-Path $Root 'config\price-book.example.json')
$rows = @('westus', 'eastus2', 'usa', 'us-b', 'brazilsouth', 'swedencentral' | ForEach-Object { [pscustomobject]@{ R = $_; P = $(switch ($_) { 'brazilsouth' { [decimal]99.5 } 'swedencentral' { $null } default { [decimal]150 } }) } })
$t0 = [datetime]'2026-09-28T00:00:00Z'
$stamped = @([pscustomobject]@{ Name = 'bz'; T = $t0 }, [pscustomobject]@{ Name = 'new'; T = $t0.AddMinutes(1) }, [pscustomobject]@{ Name = 'b-x'; T = $t0 })
$result = [ordered]@{
    sorted = @(Sort-ClaudeFlowOrdinal -InputObject $words)
    unique = @(Sort-ClaudeFlowOrdinal -InputObject @('b', 'B', 'a', 'b') -Unique)
    files = @(Sort-ClaudeFlowOrdinal -InputObject $files -Key { $_.Name } | ForEach-Object { $_.Name })
    empty = @(Sort-ClaudeFlowOrdinal -InputObject @()).Count
    unpriced = @($book.unknownModels)
    separator = @(Sort-ClaudeFlowOrdinal -InputObject @('a', "a`0A", "a`0b", 'A'))
    priceThenName = @(Sort-ClaudeFlowOrdinal -InputObject $rows -Key { if ($null -ne $_.P) { [decimal]$_.P } else { [decimal]::MaxValue } }, { $_.R } | ForEach-Object { $_.R })
    newestThenName = @(Sort-ClaudeFlowOrdinal -InputObject $stamped -Key @{ Expression = 'T'; Descending = $true }, 'Name' | ForEach-Object { $_.Name })
    descending = @(Sort-ClaudeFlowOrdinal -InputObject @('claude-opus-5a', 'claude-opus-5-x', 'b', 'B') -Descending)
    numbers = @(Sort-ClaudeFlowOrdinal -InputObject @(10, 9, 100, 2.5) -Key { $_ } | ForEach-Object { [string]$_ })
    versions = @(Sort-ClaudeFlowOrdinal -InputObject @([version]'2.10.0', [version]'2.9.1') -Key { $_ } -Descending | ForEach-Object { [string]$_ })
}
'P76JSON ' + ($result | ConvertTo-Json -Compress)
'@
    $expected = @('a-b', 'a_b', 'B', 'b', 'bu-members', 'budgets', 'claude-opus-5', 'claude-opus-5-5', 'co-op', 'coop', 'models-premium', 'Models-Standard', 'workbook-chargeback.json', 'workbook.json')
    foreach ($shell in $shells.Keys) {
        $h = Invoke-Probe $shell $helperProbe @('-Root', $root)
        Assert "PowerShell ${shell}: Sort-ClaudeFlowOrdinal orders by code point, ignoring case, with a code-point tie-break" (-not $h.Failed -and (@($h.sorted) -join ',') -ceq ($expected -join ',')) $(if ($h.Failed) { Get-Tail $h.Output } else { @($h.sorted) -join ',' })
        Assert "PowerShell ${shell}: -Unique keeps one of each ignoring case, and -Key sorts objects; an empty list is empty" (-not $h.Failed -and (@($h.unique) -join ',') -ceq 'a,B' -and (@($h.files) -join ',') -ceq 'workbook-chargeback.json,workbook.json' -and $h.empty -eq 0) $(if (-not $h.Failed) { "unique=$(@($h.unique) -join ',') files=$(@($h.files) -join ',') empty=$($h.empty)" })
        Assert "PowerShell ${shell}: the Budgets price book lists each unpriced model once, in code-point order" (-not $h.Failed -and (@($h.unpriced) -join ',') -ceq 'Alpha-Model,zeta-model') $(if (-not $h.Failed) { "unpriced=$(@($h.unpriced) -join ',')" })
        # A key that holds the character a joined key would use as its separator (U+0000) keeps its place.
        Assert "PowerShell ${shell}: a key holding U+0000 sorts by code point: A, a, a<U+0000>A, a<U+0000>b" (-not $h.Failed -and (@($h.separator) -join '|') -ceq "A|a|a`0A|a`0b") $(if (-not $h.Failed) { (@($h.separator) -join '|').Replace("`0", '<U+0000>') })
        # Keys as Sort-Object's -Property takes them: a [decimal] then a name (the region choice), a
        # descending time then a name (the backup menu), -Descending, and numbers and versions by value.
        Assert "PowerShell ${shell}: two keys, a price then a name by code point, unpriced last" (-not $h.Failed -and (@($h.priceThenName) -join ',') -ceq 'brazilsouth,eastus2,us-b,usa,westus,swedencentral') $(if (-not $h.Failed) { @($h.priceThenName) -join ',' })
        Assert "PowerShell ${shell}: a descending time key, then a name; -Descending reverses code-point order" (-not $h.Failed -and (@($h.newestThenName) -join ',') -ceq 'new,b-x,bz' -and (@($h.descending) -join ',') -ceq 'claude-opus-5a,claude-opus-5-x,b,B') $(if (-not $h.Failed) { "newest=$(@($h.newestThenName) -join ',') descending=$(@($h.descending) -join ',')" })
        Assert "PowerShell ${shell}: numbers and versions compare by value" (-not $h.Failed -and (@($h.numbers) -join ',') -ceq '2.5,9,10,100' -and (@($h.versions) -join ',') -ceq '2.10.0,2.9.1') $(if (-not $h.Failed) { "numbers=$(@($h.numbers) -join ',') versions=$(@($h.versions) -join ',')" })
    }

    # ------------------------------------------------------------------ the libraries the plans call
    # Names whose culture order differs between the shells (a hyphen against a letter or a period),
    # through the model lifecycle's tier lists and questions, the price-book entry a deployment takes,
    # the region choice and the deployable-model list. Before P76 each gave another order on 5.1.
    $bookPath = Join-Path $scratch 'price-book.json'
    [ordered]@{ date = '2026-09-28'; source = 'P76 test tariff'; models = [ordered]@{ 'claude-opus-5' = @{ inputPerM = 5; outputPerM = 25 } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $bookPath -Encoding UTF8
    $libraryProbe = Join-Path $scratch 'libraries.ps1'
    Set-Content -LiteralPath $libraryProbe -Encoding UTF8 -Value @'
param([string]$Root, [string]$BookPath, [string]$Scratch)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts\ClaudeModelLifecycle.ps1')
. (Join-Path $Root 'scripts\ClaudeModelPrices.ps1')
. (Join-Path $Root 'scripts\ClaudeGatewayRegion.ps1')
$record = [pscustomobject]@{ mode = 'gateway'; subscriptionId = '00000000-0000-0000-0000-0000000000a1'; tenantId = '00000000-0000-0000-0000-0000000000b2'
    resourceGroup = 'rg-p76'; apimName = 'apim-p76'; foundryAccount = 'ai-p76'; foundryResourceGroup = 'rg-p76'
    models = @(); deployments = @(); decisions = [pscustomobject]@{}; history = @() }
$live = { param($n) [pscustomobject]@{ name = $n; model = 'claude-opus-5'; version = '1'; sku = 'GlobalStandard'; capacity = 1; state = 'Succeeded' } }
$discovery = [pscustomobject]@{
    Deployments = @((& $live 'claude-opus-5a'), (& $live 'claude-opus-5-x'))
    NamedValues = @{ 'models-standard' = ',claude-opus-5-x,claude-opus-5a,'; 'models-premium' = ',claude-opus-5-x,claude-opus-5a,' }
    GatewayId = '/subscriptions/00000000-0000-0000-0000-0000000000a1/resourceGroups/rg-p76/providers/Microsoft.ApiManagement/service/apim-p76'
    GatewayUrl = 'https://apim-p76.azure-api.net'; Backend = 'https://ai-p76.services.ai.azure.com/anthropic'
}
$plan = New-ClaudeModelPlan -Record $record -RecordPath (Join-Path $Scratch 'record.json') -PriceBookPath $BookPath -Discovery $discovery
$questions = @(Get-ClaudeModelQuestions $record $discovery -PriceBook (Get-ClaudeModelPriceBook $BookPath))
$book = [pscustomobject]@{ date = '2026-09-28'; source = 'P76'; models = [pscustomobject]@{ 'claude-x-1.5' = [pscustomobject]@{ inputPerM = 1; outputPerM = 5 }; 'claude-x-1-5' = [pscustomobject]@{ inputPerM = 1; outputPerM = 5 } } }
$price = Get-ClaudeDeploymentPrice -Deployment ([pscustomobject]@{ name = 'dep'; sku = 'GlobalStandard'; model = 'claude-x-1.5' }) -Book $book
$where = { param($n) [pscustomobject]@{ name = $n; displayName = $n; metadata = [pscustomobject]@{ regionType = 'Physical'; geographyGroup = 'US' } } }
$monthly = { param($b) [ordered]@{ BasicV2 = [decimal]$b; StandardV2 = [decimal]700; PremiumV2 = [decimal]2800 } }
$prices = [pscustomobject]@{ ByRegion = @{ 'eastus2' = (& $monthly 150); 'usa' = (& $monthly 150); 'us-b' = (& $monthly 150); 'centralus' = (& $monthly 140) } }
$regions = @(Get-ClaudeGatewayRegionOptions -FoundryRegion 'eastus2' -Locations @((& $where 'eastus2'), (& $where 'usa'), (& $where 'us-b'), (& $where 'centralus')) -Prices $prices | ForEach-Object { $_.Region })
function az { '[' + ((@('claude-opus-5-x', 'claude-opus-5a') | ForEach-Object { '{"name":"' + $_ + '","format":"Anthropic","version":"1","isDefaultVersion":true,"skus":[{"name":"GlobalStandard","capacity":{"maximum":1,"default":1}}]}' }) -join ',') + ']' }
$deployable = @(Get-DeployableClaudeModel -Account 'ai-p76' -ResourceGroup 'rg-p76' | ForEach-Object { $_.model })
'P76JSON ' + ([ordered]@{
    standard = $plan.Data.AfterNamedValues['models-standard']
    tierVerbs = @($plan.Actions | Where-Object { $_.Target -like 'models-*' } | ForEach-Object { "$($_.Verb) $($_.Target)" })
    questions = @($questions | ForEach-Object { $_.Key })
    fingerprint = (Get-ClaudeFlowFingerprint -Plans @($plan))
    priceKey = $price.SourceKey
    regions = $regions
    deployable = $deployable
} | ConvertTo-Json -Compress -Depth 4)
'@
    $libs = [ordered]@{}
    foreach ($shell in $shells.Keys) {
        $l = Invoke-Probe $shell $libraryProbe @('-Root', $root, '-BookPath', $bookPath, '-Scratch', $scratch)
        $libs[$shell] = $l
        $tail = if ($l.Failed) { Get-Tail $l.Output } else { '' }
        Assert "PowerShell ${shell}: a model change keeps the tier lists in code-point order and asks in that order" (-not $l.Failed -and $l.standard -ceq ',claude-opus-5-x,claude-opus-5a,' -and (@($l.tierVerbs) -join ',') -ceq 'Check models-standard,Check models-premium' -and (@($l.questions) -join ',') -ceq 'models.tiers.claude-opus-5-x,models.tiers.claude-opus-5a') $(if ($l.Failed) { $tail } else { "standard=$($l.standard) verbs=$(@($l.tierVerbs) -join ',') questions=$(@($l.questions) -join ',')" })
        Assert "PowerShell ${shell}: a deployment named in two price-book spellings takes the first by code point" (-not $l.Failed -and $l.priceKey -ceq 'claude-x-1-5') $(if ($l.Failed) { $tail } else { "priceKey=$($l.priceKey)" })
        Assert "PowerShell ${shell}: regions at one price are listed by code point after the Foundry region" (-not $l.Failed -and (@($l.regions) -join ',') -ceq 'eastus2,centralus,us-b,usa') $(if ($l.Failed) { $tail } else { @($l.regions) -join ',' })
        Assert "PowerShell ${shell}: deployable models are listed newest first by descending code point" (-not $l.Failed -and (@($l.deployable) -join ',') -ceq 'claude-opus-5a,claude-opus-5-x') $(if ($l.Failed) { $tail } else { @($l.deployable) -join ',' })
    }
    if ($libs.Contains('5.1')) {
        Assert 'the model change plan has one fingerprint on both shells' (-not $libs['7'].Failed -and -not $libs['5.1'].Failed -and $libs['7'].fingerprint -and $libs['7'].fingerprint -ceq $libs['5.1'].fingerprint) "7=$($libs['7'].fingerprint) 5.1=$($libs['5.1'].fingerprint)"
    }

    if ($shells.Contains('5.1')) {
        # ------------------------------------------------------------------ every shipped Setup step
        # Planned offline (no Azure read) from one record and one answers file, on each shell.
        $record = Join-Path $scratch 'record.json'
        [ordered]@{
            schemaVersion = 2; mode = 'gateway'; gatewayUrl = 'https://apim-p76.azure-api.net'; apimName = 'apim-p76'; resourceGroup = 'rg-p76'
            decisions = [ordered]@{ foundation = [ordered]@{ sku = 'BasicV2'; entitlementStore = 'named-value'; authMode = 'interactive'; desktopSignInKind = 'helper-script'; location = 'eastus2' } }
            deployments = @(@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5' }, @{ name = 'claude-opus-5'; model = 'claude-opus-5' }, @{ name = 'claude-opus-5-5'; model = 'claude-opus-5-5' })
            models = @('claude-sonnet-5', 'claude-opus-5', 'claude-opus-5-5')
            history = @()
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $record -Encoding UTF8
        $answers = Join-Path $scratch 'answers.json'
        @{ 'deviceProfiles.conversationStorage' = 'local' } | ConvertTo-Json | Set-Content -LiteralPath $answers -Encoding UTF8
        $stepProbe = Join-Path $scratch 'steps.ps1'
        Set-Content -LiteralPath $stepProbe -Encoding UTF8 -Value @'
param([string]$Root, [string]$RecordPath, [string]$AnswersPath)
$ErrorActionPreference = 'Stop'
$env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY = '1'
Set-Location $Root
# Dot-sourced with Status, which writes nothing: the orchestrator's functions and record stay here.
. (Join-Path $Root 'Start-ClaudeGateway.ps1') -Action Status -RecordPath $RecordPath -AnswersPath $AnswersPath *> $null
$modules = Get-FlowModules -ModulePath (Join-Path $Root 'scripts\flow') -ForAction 'Setup'
$found = Get-FlowDiscoveryForSteps -Record $record -CurrentAction 'Setup' -Attended $false
$plans = [System.Collections.Generic.List[object]]::new()
$steps = [ordered]@{}
foreach ($step in @($modules.Steps)) {
    Invoke-Questions -Steps @($step) -Record $record -Discovery $found -CurrentAction 'Setup' *> $null
    $plan = & $step.Plan -Record $record -Discovery $found
    $plans.Add($plan)
    $steps[$step.Info.Name] = ConvertTo-ClaudeFlowCanonical $plan
}
. (Join-Path $Root 'scripts\flow\migrations\0002-policy-and-named-values.ps1')
$migration = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ policyHash = ''; namedValues = @() })
'P76JSON ' + ([ordered]@{
    steps = $steps
    fingerprint = (Get-ClaudeFlowFingerprint -Plans @($plans))
    references = @(Get-ClaudeFlowLifecyclePolicyNamedValueReferences)
    migration = (ConvertTo-ClaudeFlowCanonical $migration)
} | ConvertTo-Json -Compress -Depth 4)
'@
        $by = [ordered]@{}
        foreach ($shell in $shells.Keys) { $by[$shell] = Invoke-Probe $shell $stepProbe @('-Root', $root, '-RecordPath', $record, '-AnswersPath', $answers) }
        $p7 = $by['7']; $p5 = $by['5.1']
        Assert 'both shells plan every shipped Setup step offline from the record' (-not $p7.Failed -and -not $p5.Failed -and @($p7.steps.PSObject.Properties).Count -ge 5) ("7: " + $(if ($p7.Failed) { Get-Tail $p7.Output } else { @($p7.steps.PSObject.Properties.Name) -join ',' }) + " / 5.1: " + $(if ($p5.Failed) { Get-Tail $p5.Output } else { @($p5.steps.PSObject.Properties.Name) -join ',' }))
        # Each check below is made whether or not a probe ran, so the suite always makes the same
        # number of checks: a probe that fails fails its checks rather than removing them.
        $ran = -not $p7.Failed -and -not $p5.Failed
        $names7 = if ($ran) { @($p7.steps.PSObject.Properties.Name) } else { @() }
        $names5 = if ($ran) { @($p5.steps.PSObject.Properties.Name) } else { @() }
        Assert 'both shells plan the same steps in the same order' ($ran -and ($names7 -join ',') -ceq ($names5 -join ',')) "7=$($names7 -join ',') 5.1=$($names5 -join ',')"
        $differ = @(foreach ($n in $names7) {
            $a = [string]$p7.steps.$n; $b = [string]$p5.steps.$n
            if ($a -cne $b) { $i = 0; while ($i -lt [Math]::Min($a.Length, $b.Length) -and $a[$i] -ceq $b[$i]) { $i++ }; "$n at $i" }
        })
        Assert 'every shipped Setup step has the same canonical text on both shells' ($ran -and $differ.Count -eq 0) ($differ -join '; ')
        Assert 'the Setup plan has one fingerprint on both shells' ($ran -and $p7.fingerprint -and $p7.fingerprint -ceq $p5.fingerprint) "7=$($p7.fingerprint) 5.1=$($p5.fingerprint)"
        Assert 'the monitoring plan lists the workbooks in code-point order on both shells' ($ran -and [string]$p7.steps.Monitoring -cmatch 'workbook-chargeback\.json.*workbook\.json' -and [string]$p5.steps.Monitoring -cmatch 'workbook-chargeback\.json.*workbook\.json') ''
        $r7 = if ($ran) { @($p7.references) } else { @() }; $r5 = if ($ran) { @($p5.references) } else { @() }
        Assert 'the Update migration reads each of the policy''s named values once, in one order on both shells' ($ran -and $r7.Count -gt 5 -and ($r7 -join ',') -ceq ($r5 -join ',') -and -not @($r7 | Group-Object | Where-Object { $_.Count -gt 1 }).Count) "7=$($r7 -join ',') 5.1=$($r5 -join ',')"
        Assert 'the Update migration''s plan has the same canonical text on both shells' ($ran -and $p7.migration -and $p7.migration -ceq $p5.migration) ''
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Every plan has one order and one fingerprint on both shells.' -ForegroundColor Green
exit 0
