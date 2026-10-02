# P92 A2, A3 and A6 (docs/adr/0047-lean-installer-phase-0.md): the answers schema and its four sources
# agree. Each source is read from the code, not from a list kept here: the PowerShell installer's param
# block (AST), the bash installer's argument loop and recorded answers, the guided flow's question keys
# (static: the AST of scripts/flow; dynamic: each module's question function called over record sets
# that cover every When branch) and the flow's installer map. A parameter or flag with no schema entry
# fails, and so does a When without an equivalent requires.
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
Write-Host 'Installer answers schema drift' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
$pw = 'Install-ClaudeGateway.ps1'; $sh = 'install-claude-gateway.sh'; $fl = 'Start-ClaudeGateway.ps1'
$schemaPath = Join-Path $root 'schemas\claude-gateway.answers.schema.json'
$schema = $null
try { $schema = [IO.File]::ReadAllText($schemaPath) | ConvertFrom-Json -ErrorAction Stop } catch { }
Assert 'the schema reads' ($null -ne $schema)
$props = [ordered]@{}
if ($schema -and $schema.properties) { foreach ($p in $schema.properties.PSObject.Properties) { $props[$p.Name] = $p.Value } }
$controls = [ordered]@{}
if ($schema -and $schema.'x-runControls') { foreach ($p in $schema.'x-runControls'.PSObject.Properties) { $controls[$p.Name] = $p.Value } }
$secrets = if ($schema -and $schema.'x-secrets') { @($schema.'x-secrets'.PSObject.Properties.Name) } else { @() }
function Get-AppliedBy($Def) { @($Def.'x-appliedBy' | ForEach-Object { [string]$_ }) }

# ------------------------------------------------------------------ PowerShell parameters
# Every parameter is an answer the installer applies, a run option or a secret, exactly once.
function Get-ParameterDrift([string]$InstallerPath) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$null, [ref]$null)
    $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $problems = @()
    foreach ($n in $names) {
        $kinds = @()
        if ($props.Contains($n) -and (Get-AppliedBy $props[$n]) -contains $pw) { $kinds += 'answer' }
        if ($controls.Contains($n) -and $controls[$n].$pw) { $kinds += 'run option' }
        if ($secrets -contains $n) { $kinds += 'secret' }
        if ($kinds.Count -ne 1) { $problems += "-$n is $(if ($kinds.Count) { $kinds -join ' and ' } else { 'in no schema entry' })" }
    }
    foreach ($n in @($props.Keys | Where-Object { (Get-AppliedBy $props[$_]) -contains $pw }) + @($controls.Keys | Where-Object { $controls[$_].$pw })) {
        if ($names -notcontains $n) { $problems += "the schema names -$n, which $pw does not declare" }
    }
    return @($problems)
}
$installer = Join-Path $root $pw
$paramDrift = @(Get-ParameterDrift $installer)
Assert 'A2 A6 every Install-ClaudeGateway.ps1 parameter is an answer, a run option or a secret in the schema, and the schema names no parameter the installer lacks' (-not $paramDrift.Count) ($paramDrift -join '; ')
$promptOnly = 'RevocationWindowSeconds', 'TeamBudgetBehaviour', 'UnassignedDevelopers', 'DeveloperEstimate', 'PendingClaudeDeployment', 'BusinessUnits'
$ckptText = [IO.File]::ReadAllText((Join-Path $root 'scripts\ClaudeInstallCheckpoint.ps1'))
$recorded = if ($ckptText -match '\$script:ClaudeInstallPromptAnswers = @\(([^)]*)\)') { @([regex]::Matches($Matches[1], "'([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
$notAnswer = @($promptOnly | Where-Object { -not $props.Contains($_) -or (Get-AppliedBy $props[$_]) -notcontains $pw -or $recorded -notcontains $_ })
Assert 'A3 the six prompt-only answers are parameters, schema answers of Install-ClaudeGateway.ps1, and answers the install checkpoint records' (-not $notAnswer.Count -and -not $paramDrift.Count) ($notAnswer -join ', ')
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('p92-drift-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$probe = Join-Path $sandbox $pw
[IO.File]::WriteAllText($probe, ([IO.File]::ReadAllText($installer) -replace '(?m)^(\s*)\[switch\]\$Yes\r?$', "`$1[string]`$P92DriftProbe,`n`$1[switch]`$Yes"))
$probeDrift = @(Get-ParameterDrift $probe)
Assert 'A6 a parameter added without a schema entry is reported by name (the detector itself)' (($probeDrift -join ';') -match '-P92DriftProbe is in no schema entry') ($probeDrift -join '; ')

# ------------------------------------------------------------------ bash flags
function Get-FlagDrift([string]$InstallerPath) {
    $text = [IO.File]::ReadAllText($InstallerPath)
    $loop = [regex]::Match($text, '(?s)while \[ \$# -gt 0 \]; do(.*?)\n\s*esac\s*\ndone').Groups[1].Value
    $flags = @([regex]::Matches($loop, '(?m)^\s+((?:-[A-Za-z]\|)?--[a-z][a-z-]*|-h\|--help)\)') | ForEach-Object { ($_.Groups[1].Value -split '\|')[-1] })
    $problems = @()
    if (-not $flags.Count) { return @('no flags were read from the argument loop') }
    foreach ($f in $flags) {
        $answer = @($props.Keys | Where-Object { [string]$props[$_].'x-bashFlag' -eq $f -and (Get-AppliedBy $props[$_]) -contains $sh })
        $control = @($controls.Keys | Where-Object { [string]$controls[$_].$sh -eq $f })
        if (($answer.Count + $control.Count) -ne 1) { $problems += "$f is $(if ($answer.Count + $control.Count) { 'in two schema entries' } else { 'in no schema entry' })" }
    }
    foreach ($n in @($props.Keys | Where-Object { (Get-AppliedBy $props[$_]) -contains $sh })) {
        $f = [string]$props[$n].'x-bashFlag'
        if (-not $f -or $flags -notcontains $f) { $problems += "the schema says $sh applies $n through '$f', which its argument loop does not read" }
    }
    return @($problems)
}
$bashInstaller = Join-Path $root $sh
$flagDrift = @(Get-FlagDrift $bashInstaller)
Assert 'A2 A6 every install-claude-gateway.sh flag is an answer or a run option in the schema, and every answer bash applies has its flag' (-not $flagDrift.Count) ($flagDrift -join '; ')
$probeSh = Join-Path $sandbox $sh
[IO.File]::WriteAllText($probeSh, ([IO.File]::ReadAllText($bashInstaller) -replace '(?m)^(\s+)--restart\)', "`$1--drift-probe-flag) shift ;;`n`$1--restart)"))
$probeFlags = @(Get-FlagDrift $probeSh)
Assert 'A6 a flag added without a schema entry is reported by name (the detector itself)' (($probeFlags -join ';') -match '--drift-probe-flag is in no schema entry') ($probeFlags -join '; ')
$ckptSh = [IO.File]::ReadAllText((Join-Path $root 'scripts\install-checkpoint.sh'))
$rows = if ($ckptSh -match "(?s)CKPT_ANSWERS='([^']*)'") { @($Matches[1] -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { , ($_.Trim() -split '\s+') }) } else { @() }
$rowDrift = @(foreach ($r in $rows) {
        $def = $props[$r[0]]
        if (-not $def -or [string]$def.'x-bashFlag' -ne $r[2] -or (($r[3] -eq 'i') -ne ($def.type -eq 'integer'))) { "$($r[0]) $($r[2]) $($r[3])" }
    })
$bashAnswers = @($props.Keys | Where-Object { (Get-AppliedBy $props[$_]) -contains $sh })
Assert 'A13 the answers the bash checkpoint records are the schema answers bash applies, with their flags and whole-number kinds' ($rows.Count -and -not $rowDrift.Count -and
    ((@($rows | ForEach-Object { $_[0] }) | Sort-Object) -join ',') -eq (($bashAnswers | Sort-Object) -join ',')) "drift: $($rowDrift -join '; '); bash answers: $($bashAnswers -join ',')"

# ------------------------------------------------------------------ guided-flow keys
# Static: question objects (a hashtable with Key and Question) in the flow modules and the model
# questions they delegate to; a key built as 'prefix' + name is a prefix.
$staticKeys = [System.Collections.Generic.List[string]]::new(); $staticPrefixes = [System.Collections.Generic.List[string]]::new()
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts\flow') -Filter '*.ps1' -File | Where-Object { $_.Name -notin 'FlowContract.ps1', 'Discovery.ps1' }) + @(Get-Item (Join-Path $root 'scripts\ClaudeModelLifecycle.ps1'))
foreach ($f in $sources) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    foreach ($h in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        $pairs = @{}; foreach ($kv in $h.KeyValuePairs) { $pairs[[string]$kv.Item1.Extent.Text] = $kv.Item2 }
        if (-not $pairs.ContainsKey('Key') -or -not $pairs.ContainsKey('Question')) { continue }
        $expr = $pairs['Key'].Find({ param($n) $n -is [System.Management.Automation.Language.ExpressionAst] }, $true)
        if ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $staticKeys.Add($expr.Value) }
        elseif ($expr -is [System.Management.Automation.Language.BinaryExpressionAst] -and $expr.Left -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $staticPrefixes.Add($expr.Left.Value) }
        else { $staticKeys.Add("<unread key in $($f.Name): $($pairs['Key'].Extent.Text)>") }
    }
}
$inventoryPath = Join-Path $sandbox 'flow-inventory.json'
$childOut = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'FlowQuestionInventory.ps1') -Root $root -OutPath $inventoryPath 2>&1 | ForEach-Object { [string]$_ })
$inventory = if (Test-Path -LiteralPath $inventoryPath) { [IO.File]::ReadAllText($inventoryPath) | ConvertFrom-Json } else { $null }
Assert 'every flow module''s question function ran over the record sets (dynamic inventory)' ($inventory -and @($inventory.modules).Count -ge 30) (($childOut | Select-Object -Last 3) -join ' | ')
$dynamicKeys = @(if ($inventory) { $inventory.modules | ForEach-Object { $_.keys } | ForEach-Object { [string]$_.key } | Sort-Object -Unique })
$unmatched = @($dynamicKeys | Where-Object { $k = $_; $staticKeys -notcontains $k -and -not @($staticPrefixes | Where-Object { $k.StartsWith($_) }).Count })
$unseen = @($staticKeys | Where-Object { $dynamicKeys -notcontains $_ }) + @($staticPrefixes | Where-Object { $p = $_; -not @($dynamicKeys | Where-Object { $_.StartsWith($p) }).Count } | ForEach-Object { "$_*" })
Assert 'U80 the static and dynamic flow-key inventories agree' ($staticKeys.Count -ge 15 -and $staticPrefixes.Count -ge 1 -and -not $unmatched.Count -and -not $unseen.Count) "static: $($staticKeys -join ', '), $($staticPrefixes -join ', ')*; dynamic only: $($unmatched -join ', '); static only: $($unseen -join ', ')"
$alias = @{}
foreach ($n in $props.Keys) { foreach ($a in @($props[$n].'x-flowKeys')) { if ($a) { $alias[[string]$a] = $n } } }
$patterns = if ($schema -and $schema.patternProperties) { @($schema.patternProperties.PSObject.Properties.Name) } else { @() }
$uncovered = @($staticKeys | Where-Object { -not $alias.ContainsKey($_) -and -not ($props.Contains($_) -and (Get-AppliedBy $props[$_]) -contains $fl) }) +
    @($staticPrefixes | Where-Object { $p = $_; -not @($patterns | Where-Object { ($p + 'claude-sonnet-5') -match $_ }).Count } | ForEach-Object { "$_*" })
Assert 'A2 every flow question key is a schema answer: an alias of an installer answer, a flow-only answer, or a pattern' (-not $uncovered.Count) ($uncovered -join ', ')
$map = if ($inventory) { $inventory.foundationMap } else { $null }
$mapDrift = @(if ($map) { foreach ($p in $map.PSObject.Properties) { $want = "foundation.$($p.Value)"; if (-not $props.Contains($p.Name) -or @($props[$p.Name].'x-flowKeys') -notcontains $want) { "$($p.Name) <- $want" } } } else { 'no map' })
$mapKeys = @(if ($map) { $map.PSObject.Properties | ForEach-Object { "foundation.$($_.Value)" } })
$strayAlias = @($alias.Keys | Where-Object { $staticKeys -notcontains $_ -and $mapKeys -notcontains $_ })
Assert 'A2 the flow''s installer map and the schema aliases agree: each foundation.<decision> key aliases its installer parameter, and no alias is unknown to the flow' (-not $mapDrift.Count -and -not $strayAlias.Count) "map: $($mapDrift -join '; '); stray: $($strayAlias -join ', ')"

# ------------------------------------------------------------------ When and requires
function Test-Requires($Conditions, [hashtable]$Answers) {
    foreach ($c in @($Conditions)) {
        $v = if ($Answers.ContainsKey([string]$c.answer)) { $Answers[[string]$c.answer] } else { $null }
        if ($c.PSObject.Properties.Name -contains 'equals') { if ([string]$v -cne [string]$c.equals) { return $false } }
        elseif ($c.PSObject.Properties.Name -contains 'in') { if ([string]$v -cnotin @($c.in | ForEach-Object { [string]$_ })) { return $false } }
        elseif ($c.PSObject.Properties.Name -contains 'present') { if ([bool]$c.present -ne ($null -ne $v -and [string]$v -ne '')) { return $false } }
        else { return $false }
    }
    return $true
}
$whenDrift = @()
foreach ($m in @(if ($inventory) { $inventory.modules })) {
    $answers = @{}
    foreach ($step in $m.decisions.PSObject.Properties) { foreach ($d in $step.Value.PSObject.Properties) { $k = "$($step.Name).$($d.Name)"; if ($alias.ContainsKey($k)) { $answers[$alias[$k]] = $d.Value } } }
    foreach ($k in @($m.keys | Where-Object { $_.hasWhen })) {
        $canonical = if ($alias.ContainsKey($k.key)) { $alias[$k.key] } else { $k.key }
        $conditions = if ($props.Contains($canonical)) { @($props[$canonical].requires) } else { @() }
        if (-not $conditions.Count) { $whenDrift += "$($k.key) has When and no requires"; continue }
        if ((Test-Requires $conditions $answers) -ne [bool]$k.visible) { $whenDrift += "$($k.key) on $($m.record): When says $($k.visible), requires says $(-not $k.visible)" }
    }
}
Assert 'A1 every question with a When has a requires on its schema answer, and the two agree on every record set' ($inventory -and -not $whenDrift.Count) (($whenDrift | Select-Object -Unique) -join '; ')

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
