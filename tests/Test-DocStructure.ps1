

$ErrorActionPreference = 'Stop'



$Root = Split-Path -Parent $PSScriptRoot

$BaselineCommit = '8a4be169210e0966b1f137658afb8cc943b2cef4'

$LedgerNames = @('STATUS.md','ROADMAP.md','UNKNOWNS.md','CHARTER.md')

$PermanentReferenceExceptions = @{

  'docs\CLI-FINOPS.md' = 'nine-line redirect to canonical AUM guide'

  'docs\aum-usd-budgets-client-contract.md' = 'HTTP schema/revision reference'

  'docs\AZ-COMMANDS.md' = 'stateful command reference guarded by marker and portal tests'

  'docs\REFERENCE.md' = 'repository layout reference index'

}

$EnrolledGuides = @(
  'README.md',
  'docs\SETUP.md',
  'docs\ARCHITECTURE.md',
  'docs\BUSINESS-UNITS.md',
  'docs\DECISIONS.md',
  'docs\AUTHENTICATION.md',
  'docs\GUIDED-FLOW.md',
  'docs\OPERATIONS.md',
  'DEVELOPER.md',
  'docs\GET-STARTED.md',
  'docs\ONBOARDING.md',
  'docs\SCALE.md',
  'docs\AUM.md',
  'docs\BUDGETS.md',
  'docs\MODELS.md',
  'docs\FINOPS.md',
  'docs\MONITORING.md',
  'docs\MDM.md',
  'docs\NETWORK.md',
  'docs\NETWORK-ENTERPRISE.md',
  'docs\FINOPS-TOOLS.md',
  'docs\CHARGEBACK-REPORTS.md',
  'docs\AUM-SERVICE.md',
  'docs\TURNSTILE.md',
  'docs\DIAGNOSE.md',
  'docs\DEBUGGING.md',
  'docs\TROUBLESHOOTING.md',
  'docs\MIGRATION.md',
  'docs\PLUGINS.md',
  'docs\GOVERNANCE-CHECKS.md',
  'docs\FOUNDRY-DIRECT.md',
  'docs\DATA-GOVERNANCE.md',
  'docs\COMPARISON.md',
  'docs\AI-GATEWAY-TIER.md',
  'docs\REFERENCE.md',
  'docs\RELEASING.md',
  'onboarding\README.md',
  'guide\README.md'
)



function Write-Ok([string]$Message) { Write-Host "  [OK]   $Message" }

# git's output is decoded with the console encoding when captured with & git. Test-All runs each suite
# without a console, where that is not UTF-8, so a heading with an em dash turned into mojibake and its
# baseline anchor never matched. Read blobs through a process whose output is decoded as UTF-8.
function Get-GitBlobText([string]$Spec) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'
  foreach ($arg in @('-C', $Root, 'show', $Spec)) { $psi.ArgumentList.Add($arg) }
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $process = [Diagnostics.Process]::Start($psi)
  $text = $process.StandardOutput.ReadToEnd(); [void]$process.StandardError.ReadToEnd(); $process.WaitForExit()
  if ($process.ExitCode -ne 0) { return $null }
  return $text
}

function Assert-Condition([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }



function Get-GuidePaths {

  $paths = @('README.md',
  'docs\SETUP.md',
  'docs\ARCHITECTURE.md','DEVELOPER.md',
  'docs\GET-STARTED.md',
  'docs\ONBOARDING.md',
  'docs\SCALE.md',
  'docs\AUM.md',
  'docs\BUDGETS.md',
  'docs\MODELS.md',
  'docs\FINOPS.md',
  'docs\MONITORING.md',
  'docs\MDM.md',
  'docs\NETWORK.md',
  'docs\NETWORK-ENTERPRISE.md',
  'docs\FINOPS-TOOLS.md',
  'docs\CHARGEBACK-REPORTS.md',
  'docs\AUM-SERVICE.md',
  'docs\TURNSTILE.md',
  'docs\DIAGNOSE.md',
  'docs\DEBUGGING.md',
  'docs\TROUBLESHOOTING.md',
  'docs\MIGRATION.md',
  'docs\PLUGINS.md',
  'docs\GOVERNANCE-CHECKS.md',
  'docs\FOUNDRY-DIRECT.md',
  'docs\DATA-GOVERNANCE.md',
  'docs\COMPARISON.md',
  'docs\AI-GATEWAY-TIER.md',
  'docs\REFERENCE.md',
  'docs\RELEASING.md','guide\README.md','onboarding\README.md')

  Get-ChildItem -LiteralPath (Join-Path $Root 'docs') -Filter '*.md' | Sort-Object Name | ForEach-Object {

    if ($LedgerNames -notcontains $_.Name) { $paths += ('docs\' + $_.Name) }

  }

  $paths | Sort-Object -Unique

}



function Remove-InlineCode([string]$Line) {

  return [regex]::Replace($Line, '`[^`]*`', '')

}



function ConvertTo-Slug([string]$Heading) {

  $s = $Heading -replace '<[^>]+>', ''

  $s = $s -replace '[*_~`\[\]()]', ''

  $s = $s.Trim().ToLowerInvariant()

  $s = $s -replace '[^\p{L}\p{Nd} \-]', ''

  $s = $s -replace ' ', '-'

  return $s

}



function Get-DocumentAnchors([string]$Text) {

  $anchors = New-Object System.Collections.Generic.List[string]

  $seen = @{}

  $lines = $Text -split "`n"

  $inFence = $false; $fence = ''

  for ($i = 0; $i -lt $lines.Count; $i++) {

    $line = $lines[$i].TrimEnd("`r")

    if ($line -match '^ {0,3}(```+|~~~+)') {

      $marker = $Matches[1]

      if (-not $inFence) { $inFence = $true; $fence = $marker }

      elseif ($marker[0] -eq $fence[0] -and $marker.Length -ge $fence.Length) { $inFence = $false; $fence = '' }

      continue

    }

    if ($inFence) { continue }

    if ($line -match '^ {0,3}(#{1,6})\s+(.+?)\s*#*\s*$') {

      $title = $Matches[2]

      $slug = ConvertTo-Slug $title

      if ($slug) {

        $count = 0

        if ($seen.ContainsKey($slug)) { $count = [int]$seen[$slug]; $seen[$slug] = $count + 1 } else { $seen[$slug] = 1 }

        if ($count -gt 0) { $slug = "$slug-$count" }

        $anchors.Add($slug)

      }

    }

    foreach ($m in [regex]::Matches((Remove-InlineCode $line), '<a\s+(?:id|name)="([^"]+)"')) { $anchors.Add($m.Groups[1].Value) }

  }

  return ,$anchors.ToArray()

}




function Get-MarkdownScanLines([string]$Text) {
  $lines = ($Text -replace "`r", "") -split "`n"
  $rows = New-Object System.Collections.Generic.List[object]
  $inFence = $false; $fenceChar = ''; $fenceLength = 0; $inComment = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $visible = $line
    $code = $false
    $trimmed = $line -replace '^(?:[ ]{0,3}>[ ]?)+', ''
    if ($trimmed -match '^ {0,3}(```+|~~~+)') {
      $mark = $Matches[1]
      if (-not $inFence) { $inFence = $true; $fenceChar = $mark.Substring(0, 1); $fenceLength = $mark.Length }
      elseif ($mark.Substring(0, 1) -eq $fenceChar -and $mark.Length -ge $fenceLength) { $inFence = $false; $fenceChar = ''; $fenceLength = 0 }
      $visible = ''
    }
    elseif ($inFence) { $visible = ''; $code = $true }
    else {
      if ($inComment) {
        $visible = ''
        if ($line -match '-->') { $inComment = $false }
      }
      elseif ($line -match '<!--') {
        $visible = [regex]::Replace($line, '<!--.*?-->', '')
        if ($line -match '<!--' -and $line -notmatch '-->') { $visible = ''; $inComment = $true }
      }
    }
    $rows.Add([pscustomobject]@{ Number = $i + 1; Text = $visible; Original = $line; InFence = $code })
  }
  return $rows.ToArray()
}

function Get-H2Sections([string]$Text) {
  $rows = Get-MarkdownScanLines $Text
  $heads = @()
  foreach ($row in $rows) {
    if ($row.Text -match '^##\s+(.+?)\s*$') {
      $heads += [pscustomobject]@{ Title = $Matches[1].Trim(); Line = $row.Number }
    }
  }
  $sections = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $heads.Count; $i++) {
    $startLine = $heads[$i].Line
    $endLine = if ($i + 1 -lt $heads.Count) { $heads[$i + 1].Line - 1 } else { $rows.Count }
    $bodyRows = @($rows | Where-Object { $_.Number -gt $startLine -and $_.Number -le $endLine })
    $sections.Add([pscustomobject]@{
      Title = $heads[$i].Title
      StartLine = $startLine
      EndLine = $endLine
      Body = (($bodyRows | ForEach-Object Original) -join "`n")
      BodyVisible = (($bodyRows | ForEach-Object Text) -join "`n")
    })
  }
  return $sections.ToArray()
}

function Get-DetailsRanges([string]$Text) {
  $rows = Get-MarkdownScanLines $Text
  $stack = New-Object System.Collections.Generic.List[int]
  $ranges = New-Object System.Collections.Generic.List[object]
  foreach ($row in $rows) {
    if ($row.Text -match '<details(?:\s|>)') { $stack.Add($row.Number) }
    if ($row.Text -match '</details>') {
      if ($stack.Count -gt 0) {
        $start = $stack[$stack.Count - 1]
        $stack.RemoveAt($stack.Count - 1)
        $ranges.Add([pscustomobject]@{ Start = $start; End = $row.Number })
      }
    }
  }
  foreach ($start in $stack) { $ranges.Add([pscustomobject]@{ Start = $start; End = [int]::MaxValue }) }
  return $ranges.ToArray()
}

function Test-LineInDetails([int]$Line, [object[]]$Ranges) {
  foreach ($range in $Ranges) { if ($Line -ge $range.Start -and $Line -le $range.End) { return $true } }
  return $false
}


function Get-FencedBlocks([string]$Text) {
  $lines = ($Text -replace "`r", "") -split "`n"
  $blocks = New-Object System.Collections.Generic.List[object]
  $inFence = $false; $fenceChar = ''; $fenceLength = 0; $language = ''; $start = 0; $content = [System.Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $trimmed = $line -replace '^(?:[ ]{0,3}>[ ]?)+', ''
    if ($trimmed -match '^ {0,3}(```+|~~~+)\s*([^`]*)$') {
      $mark = $Matches[1]
      if (-not $inFence) {
        $inFence = $true; $fenceChar = $mark.Substring(0, 1); $fenceLength = $mark.Length; $language = ($Matches[2] -split '\s+')[0].Trim().ToLowerInvariant(); $start = $i + 1; $content = [System.Collections.Generic.List[string]]::new()
      }
      elseif ($mark.Substring(0, 1) -eq $fenceChar -and $mark.Length -ge $fenceLength) {
        $blocks.Add([pscustomobject]@{ StartLine = $start; EndLine = $i + 1; Language = $language; Text = ($content -join "`n") })
        $inFence = $false; $fenceChar = ''; $fenceLength = 0; $language = ''
      }
    }
    elseif ($inFence) { $content.Add($line) }
  }
  return $blocks.ToArray()
}

function Test-VisibleProseDefinesVariable([object[]]$ScanLines, [int]$BeforeLine, [string]$Name) {
  # A definition says what the variable holds, not only that it appears: "`$rg` is the resource group",
  # "`$rg` and `$apim` are the ...", "`$rg`: ...", "Set `$rg` to ...", or a table row whose first cell is `$rg`.
  $code = '`\$' + [regex]::Escape($Name) + '`'
  $otherCode = '`\$[A-Za-z_][A-Za-z0-9_:]*`'
  $patterns = @(
    "(?i)$code(?:\s*(?:,|and)\s*$otherCode)*\s*(?:variables?\s+)?(?:(?:is|are|holds|names|means)\s+(?:the|a|an|your|its)\b|[:=]\s*\S)",
    "(?i)(?:$otherCode\s*(?:,|and)\s*)+$code\s*(?:variables?\s+)?(?:(?:is|are|holds|names|means)\s+(?:the|a|an|your|its)\b)",
    "(?i)\b(?:set|replace)\s+$code\s+(?:to|with)\b",
    "^\s*\|\s*$code\s*\|"
  )
  foreach ($line in @($ScanLines | Where-Object { $_.Number -lt $BeforeLine -and -not $_.InFence -and $_.Text.Trim() })) {
    foreach ($pattern in $patterns) { if ($line.Text -match $pattern) { return $true } }
  }
  return $false
}

function Test-QuickstartPowerShellVariables([string]$Path, [object]$Section, [object[]]$ScanLines) {
  $errors = [System.Collections.Generic.List[string]]::new()
  $auto = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @('true','false','null','_','PSItem','LASTEXITCODE','PSScriptRoot','PSCommandPath','MyInvocation','PSBoundParameters','input','HOME','PWD','PSHOME','PID','args','Matches','Error','Host','PSVersionTable','PSEdition','IsWindows','IsLinux','IsMacOS','IsCoreCLR','ExecutionContext','PSCulture','PSUICulture','ShellId','StackTrace','this','profile','ErrorActionPreference','ProgressPreference','VerbosePreference','WarningPreference','InformationPreference','DebugPreference','ConfirmPreference','WhatIfPreference','OFS','NestedPromptLevel')) { [void]$auto.Add($name) }
  $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($block in Get-FencedBlocks $Section.Body) {
    if ($block.Language -notin @('powershell','pwsh','ps1')) { continue }
    $tokens = $null; $parseErrors = $null
    $code = [regex]::Replace($block.Text, '<([a-zA-Z][a-zA-Z0-9-]*)>', 'PLACEHOLDER_$1')
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
      $errors.Add("Quickstart PowerShell block at line $($Section.StartLine + $block.StartLine) does not parse: $(@($parseErrors)[0].Message)")
    }
    foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
      if ([string]$command.GetCommandName() -match '^[-+*/%]?=$') {
        $errors.Add("Quickstart PowerShell at line $($Section.StartLine + $block.StartLine + $command.Extent.StartLineNumber) runs '$($command.GetCommandName())' as a command: an assignment has no variable")
      }
    }
    $definitions = @()
    $definitions += $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left }
    $definitions += $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable }
    $definitions += $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | ForEach-Object { $_.Parameters } | ForEach-Object { $_.Name }
    $definitionKeys = @{}
    foreach ($definition in $definitions) { $definitionKeys[$definition.Extent.StartOffset.ToString() + ':' + $definition.Extent.EndOffset.ToString()] = $true }
    $variables = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | Sort-Object { $_.Extent.StartOffset })
    foreach ($variable in $variables) {
      $key = $variable.Extent.StartOffset.ToString() + ':' + $variable.Extent.EndOffset.ToString()
      $name = $variable.VariablePath.UserPath
      if ($definitionKeys.ContainsKey($key)) { continue }
      if ($variable.VariablePath.IsDriveQualified -and $variable.VariablePath.DriveName -eq 'env') { continue }
      if ($auto.Contains($name)) { continue }
      $earlierInBlock = $false
      foreach ($definition in $definitions) {
        if ($definition.VariablePath.UserPath -eq $name -and $definition.Extent.StartOffset -lt $variable.Extent.StartOffset) { $earlierInBlock = $true; break }
      }
      if ($earlierInBlock) { continue }
      if ($variable.VariablePath.IsGlobal -or $variable.VariablePath.IsScript) {
        if (-not $assigned.Contains($name)) { $errors.Add("PowerShell variable `$$name is used in Quickstart before assignment") }
        continue
      }
      if ($assigned.Contains($name)) { continue }
      $absoluteLine = $Section.StartLine + $block.StartLine + $variable.Extent.StartLineNumber - 1
      if (Test-VisibleProseDefinesVariable $ScanLines $absoluteLine $name) { continue }
      $errors.Add("PowerShell variable `$$name is used in Quickstart before assignment or prose definition")
    }
    foreach ($definition in $definitions | Sort-Object { $_.Extent.StartOffset }) { [void]$assigned.Add($definition.VariablePath.UserPath) }
  }
  return $errors.ToArray()
}

$script:ScriptParameterCache = @{}
function Get-ScriptParameterNames([string]$Path) {
  if (-not $script:ScriptParameterCache.ContainsKey($Path)) {
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $names = [System.Collections.Generic.List[string]]::new()
    if ($scriptAst.ParamBlock) {
      foreach ($parameter in $scriptAst.ParamBlock.Parameters) { $names.Add($parameter.Name.VariablePath.UserPath) }
      $advanced = @($scriptAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count -gt 0 -or
        @($scriptAst.ParamBlock.Parameters | Where-Object { @($_.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' }).Count }).Count -gt 0
      if ($advanced) { foreach ($common in 'Verbose','Debug','ErrorAction','WarningAction','InformationAction','ProgressAction','ErrorVariable','WarningVariable','InformationVariable','OutVariable','OutBuffer','PipelineVariable','WhatIf','Confirm') { $names.Add($common) } }
    }
    $script:ScriptParameterCache[$Path] = $names.ToArray()
  }
  return $script:ScriptParameterCache[$Path]
}

function Test-QuickstartScriptCommands([object]$Section) {
  $errors = [System.Collections.Generic.List[string]]::new()
  foreach ($block in Get-FencedBlocks $Section.Body) {
    if ($block.Language -notin @('powershell','pwsh','ps1')) { continue }
    $code = [regex]::Replace($block.Text, '<([a-zA-Z][a-zA-Z0-9-]*)>', 'PLACEHOLDER_$1')
    $blockAst = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
    foreach ($command in $blockAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
      $name = [string]$command.GetCommandName()
      $elements = @($command.CommandElements)
      $scriptPath = $null; $argElements = @()
      if ($name -match '^\.[\\/][^\\/].*\.ps1$') { $scriptPath = $name; $argElements = @($elements | Select-Object -Skip 1) }
      elseif ($name -match '^(?i)(pwsh|powershell)(\.exe)?$') {
        # pwsh -File <script> <script arguments>: the script's parameters follow its path.
        for ($e = 1; $e -lt $elements.Count - 1; $e++) {
          if ($elements[$e] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$e].ParameterName -match '^(?i)f(ile)?$') {
            $candidate = [string]$elements[$e + 1].Extent.Text.Trim('''', '"')
            if ($candidate -match '^\.?[\\/]?[^\\/].*\.ps1$') { $scriptPath = $candidate; $argElements = @($elements | Select-Object -Skip ($e + 2)) }
            break
          }
        }
      }
      if (-not $scriptPath) { continue }
      $relative = $scriptPath -replace '^\.[\\/]', ''
      $target = Join-Path $Root $relative
      if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $errors.Add("Quickstart command $scriptPath names a script that does not exist"); continue }
      $known = @(Get-ScriptParameterNames $target)
      foreach ($given in @($argElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)) {
        $exact = @($known | Where-Object { $_ -eq $given })
        $prefixHits = @($known | Where-Object { $_ -like "$given*" })
        if (-not $exact.Count -and $prefixHits.Count -ne 1) { $errors.Add("Quickstart command $scriptPath has no parameter -$given") }
      }
    }
  }
  return $errors.ToArray()
}
function Test-QuickstartShellVariables([object]$Section, [object[]]$ScanLines) {
  $errors = [System.Collections.Generic.List[string]]::new()
  $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($block in Get-FencedBlocks $Section.Body) {
    if ($block.Language -notin @('bash','sh','shell')) { continue }
    $lines = $block.Text -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $line = $lines[$i]
      # Single-quoted text is literal in POSIX shells: no expansion, so no variable use.
      $line = [regex]::Replace($line, "'[^']*'", "''")
      foreach ($m in [regex]::Matches($line, '(^|\s)(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=')) { [void]$assigned.Add($m.Groups[2].Value) }
      foreach ($m in [regex]::Matches($line, '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?')) {
        $name = $m.Groups[1].Value
        if ($assigned.Contains($name)) { continue }
        $absoluteLine = $Section.StartLine + $block.StartLine + $i
        if (Test-VisibleProseDefinesVariable $ScanLines $absoluteLine $name) { continue }
        $errors.Add("Shell variable `$$name is used in Quickstart before assignment or prose definition")
      }
    }
  }
  return $errors.ToArray()
}

function Get-TemplatedSummarySuffixes([string[]]$Summaries, [int]$Limit) {
  $counts = @{}
  foreach ($summary in $Summaries) {
    $words = @(($summary.ToLowerInvariant() -replace '[^\p{L}\p{N}\s]', ' ') -split '\s+' | Where-Object { $_ })
    if ($words.Count -lt 3) { continue }
    $key = $words[-3..-1] -join ' '
    if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
  }
  return @($counts.GetEnumerator() | Where-Object { $_.Value -gt $Limit } | ForEach-Object { "'$($_.Key)' ends $($_.Value) summaries" })
}

function Test-GuideStructure([string]$Path, [string]$Text, [bool]$Enrolled) {
  $errors = New-Object System.Collections.Generic.List[string]
  if ($Text -match "(?<!`r)`n") { $errors.Add('working-tree line endings include isolated LF') }
  $logical = $Text -replace "`r`n", "`n"
  $logical = $logical -replace "`r", ""
  if ($logical -match '(?i)C:\\Users\\') { $errors.Add('local machine path appears in guide') }
  if ($logical -match '(?i)\bAlice\b|\bBob\b|\bNaveen\b') { $errors.Add('personal/example name appears in guide') }
  $closeRows = @(Get-MarkdownScanLines $logical)
  foreach ($row in $closeRows) {
    if (-not $row.InFence -and $row.Original -match '^ {0,3}(`{3,})(.*)$' -and $Matches[2] -match '`') {
      $errors.Add("line $($row.Number) opens a backtick fence whose info string contains a backtick, so it is not a code fence (CommonMark 0.31.2, 4.5)")
    }
  }
  for ($k = 0; $k -lt $closeRows.Count - 1; $k++) {
    if ($closeRows[$k].Text -match '^\s*</details>\s*$' -and $closeRows[$k + 1].Original.Trim()) {
      $errors.Add("line $($closeRows[$k + 1].Number) follows </details> without a blank line, so GitHub renders it as raw HTML text: $($closeRows[$k + 1].Original.Trim())")
    }
  }
  if (-not $Enrolled) { return ,$errors.ToArray() }

  $scanLines = Get-MarkdownScanLines $logical
  $detailsRanges = @(Get-DetailsRanges $logical)
  $sections = @(Get-H2Sections $logical)
  if ($sections.Count -eq 0) { $errors.Add('guide has no H2 sections'); return ,$errors.ToArray() }
  if ($sections[0].Title -ne 'Quickstart') { $errors.Add('first H2 is not Quickstart') }

  foreach ($line in $scanLines) {
    if ($line.Text -match '^#{1,2}\s+' -and (Test-LineInDetails $line.Number $detailsRanges)) {
      $errors.Add("heading '$($line.Text.Trim())' is inside details")
    }
  }

  $beforeFirstH2Rows = @($scanLines | Where-Object { $_.Number -lt $sections[0].StartLine })
  if (-not ($beforeFirstH2Rows | Where-Object { $_.Text -match '^#\s+\S' })) { $errors.Add('missing visible H1 before Quickstart') }
  $purposeLines = $beforeFirstH2Rows | Where-Object { $_.Text.Trim() -and $_.Text -notmatch '^---$|^#|^title:|^description:' }
  if ($purposeLines.Count -eq 0) { $errors.Add('missing purpose line before Quickstart') }

  $quick = $sections[0].BodyVisible
  if ($quick -notmatch '(?i)Expected result') { $errors.Add('Quickstart lacks Expected result') }
  if ($quick -match '(?i)<details(?:\s|>)|<summary(?:\s|>)') { $errors.Add('Quickstart body contains details or summary') }
  foreach ($variableError in (Test-QuickstartPowerShellVariables $Path $sections[0] $scanLines)) { $errors.Add($variableError) }
  foreach ($variableError in (Test-QuickstartShellVariables $sections[0] $scanLines)) { $errors.Add($variableError) }
  foreach ($commandError in (Test-QuickstartScriptCommands $sections[0])) { $errors.Add($commandError) }
  $quickRows = @($scanLines | Where-Object { $_.Number -gt $sections[0].StartLine -and $_.Number -le $sections[0].EndLine })
  foreach ($row in $quickRows) {
    if (-not $row.InFence) { continue }
    foreach ($ph in [regex]::Matches($row.Original, '<[a-zA-Z][a-zA-Z0-9-]*>')) {
      $definedEarlier = $false
      foreach ($prior in @($scanLines | Where-Object { $_.Number -lt $row.Number -and -not $_.InFence -and $_.Text.Trim() })) {
        if ($prior.Text -match [regex]::Escape($ph.Value)) { $definedEarlier = $true; break }
      }
      if (-not $definedEarlier) { $errors.Add("placeholder $($ph.Value) is used in a Quickstart command before local definition") }
    }
  }

  $terminalNames = @('Next','Next steps','Related','See also','Verify and next steps','9. Next','Related guides','Troubleshoot and next steps','License','5. Next')
  $terminalIndex = -1
  for ($i=0; $i -lt $sections.Count; $i++) { if ($terminalNames -contains $sections[$i].Title) { $terminalIndex = $i } }
  if ($terminalIndex -lt 0) { $errors.Add('missing visible terminal Next/Related section') }
  elseif ($sections[$terminalIndex].BodyVisible -match '(?s)<details>') { $errors.Add('terminal navigation section is hidden in details') }

  $summaries = New-Object System.Collections.Generic.HashSet[string]
  for ($i = 1; $i -lt $sections.Count; $i++) {
    if ($terminalNames -contains $sections[$i].Title) { continue }
    if ($PermanentReferenceExceptions.ContainsKey($Path)) { continue }
    $body = $sections[$i].BodyVisible.Trim()
    $rawBody = $sections[$i].Body.Trim()
    if (-not $body) {
      if ($rawBody) { $errors.Add("section '$($sections[$i].Title)' body is not exactly one blank-separated details block") }
      continue
    }
    if ($body -notmatch '(?s)^<details>\s*\n\s*<summary>([^<\n#][^<\n]*)</summary>\s*\n\s*\n.+\n\s*</details>\s*$') { $errors.Add("section '$($sections[$i].Title)' body is not exactly one blank-separated details block") }
    else {
      $summary = $Matches[1].Trim()
      $numbering = '^\s*(?:step\s+)?\d+[a-zA-Z]?(?:\.\d+)*[\.\):]?\s*(?:[-\u2013\u2014]\s*)?'
      $titleCore = ($sections[$i].Title -replace "(?i)$numbering", '').Trim()
      $summaryCore = ($summary -replace "(?i)$numbering", '').Trim()
      $summaryWords = @($summaryCore -split '\s+' | Where-Object { $_ })
      if ($summary -match '(?i)\b(reference|details|information|section|content|more|notes|overview)$') { $errors.Add("section '$($sections[$i].Title)' summary '$summary' ends with a generic word") }
      elseif (-not $summaryCore -or ($titleCore -and $summaryCore -match ('(?i)^' + [regex]::Escape($titleCore) + '(?![\p{L}\p{N}])'))) { $errors.Add("section '$($sections[$i].Title)' summary '$summary' repeats its heading instead of naming what the section holds") }
      elseif ($summaryWords.Count -lt 2 -or $summaryWords.Count -gt 14) { $errors.Add("section '$($sections[$i].Title)' summary '$summary' has $($summaryWords.Count) word(s); use 2 to 14") }
      if (-not $summaries.Add($summary.ToLowerInvariant())) { $errors.Add("summary '$summary' is duplicated in $Path") }
    }
    if (($body | Select-String -Pattern '<details>' -AllMatches).Matches.Count -gt 1) { $errors.Add("section '$($sections[$i].Title)' nests disclosures") }
    if ($body -match '<summary>\s*(##|<h[1-6])') { $errors.Add("section '$($sections[$i].Title)' uses a heading in summary") }
    if ($body -match '(?i)(<details[^>]+name=|script>|style>)') { $errors.Add("section '$($sections[$i].Title)' uses unsupported disclosure control") }
  }
  return ,$errors.ToArray()
}

function Assert-InvalidCase([string]$Name, [string]$Text, [string]$Expected) {

  $material = $Text -creplace '\\n', "`n"
  $errors = Test-GuideStructure 'docs\CASE.md' ($material -replace "`n", "`r`n") $true
  if (($errors -join '; ') -match $Expected) {
    Write-Ok "detected: $Name"
  } else {
    $script:NegativeFailures.Add("negative case not detected: $Name. Errors: $($errors -join '; ')")
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
  }

}



Write-Host 'Documentation structure - quickstarts, disclosures and anchors'
function Join-Lines([string[]]$Lines) { return ($Lines -join "`n") }

function Assert-ValidCase([string]$Name, [string]$Text) {
  $material = $Text -creplace '\\n', "`n"
  $errors = Test-GuideStructure 'docs\CASE.md' ($material -replace "`n", "`r`n") $true
  if (@($errors).Count -eq 0) {
    Write-Ok "valid guide accepted: $Name"
  } else {
    $script:NegativeFailures.Add("positive case failed: $Name. Errors: $($errors -join '; ')")
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
  }
}


function Assert-NoErrorCase([string]$Name, [string]$Text, [string]$Pattern) {
  $material = $Text -replace '\n', "`n"
  $errors = Test-GuideStructure 'docs\CASE.md' ($material -replace "`n", "`r`n") $true
  $matched = @($errors | Where-Object { $_ -match $Pattern })
  if ($matched.Count -eq 0) { Write-Ok "valid case accepted: $Name" }
  else { $script:NegativeFailures.Add("valid case failed: $Name. Errors: $($matched -join '; ')"); Write-Host "  [FAIL] $Name" -ForegroundColor Red }
}

$NegativeFailures = [System.Collections.Generic.List[string]]::new()

Assert-InvalidCase 'missing Quickstart' (Join-Lines @('# Guide','','Purpose.','','## Setup','','Text.','','## Next','','- [Next](NEXT.md)')) 'first H2'
Assert-InvalidCase 'absent Expected result' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Do-Thing','```','','## Next','','- [Next](NEXT.md)')) 'Expected result'
Assert-InvalidCase 'undefined placeholder before definition' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Do-Thing -User <developer-upn>','```','','`<developer-upn>` is defined too late.','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'used in a Quickstart command before local definition'
Assert-InvalidCase 'summary without blank line' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','<summary>Reference</summary>','Text.','</details>','','## Next','','- [Next](NEXT.md)')) 'details block'
Assert-InvalidCase 'heading moved to summary' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','','<summary>## Body</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'heading in summary'
Assert-InvalidCase 'terminal Next hidden' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Next','','<details>','','<summary>Navigation</summary>','','- [Next](NEXT.md)','','</details>')) 'terminal navigation'

Assert-InvalidCase 'missing purpose before Quickstart' (Join-Lines @('# Guide','','## Quickstart','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'missing purpose'
Assert-InvalidCase 'fenced heading ignored' (Join-Lines @('# Guide','','Purpose.','','```markdown','## Quickstart','```','','## Next','','- [Next](NEXT.md)')) 'first H2|no H2'
Assert-InvalidCase 'comment heading ignored' (Join-Lines @('# Guide','','Purpose.','','<!--','## Quickstart','-->','','## Next','','- [Next](NEXT.md)')) 'first H2|no H2'
Assert-InvalidCase 'fenced details ignored' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','```markdown','<details>','','<summary>Area</summary>','','Text.','','</details>','```','','## Next','','- [Next](NEXT.md)')) 'details block'
Assert-InvalidCase 'Quickstart heading hidden in details' (Join-Lines @('# Guide','','Purpose.','','<details>','','<summary>Hidden path</summary>','','## Quickstart','','**Expected result:** success.','','</details>','','## Next','','- [Next](NEXT.md)')) 'inside details'
Assert-InvalidCase 'Quickstart body hidden in details' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','<details>','','<summary>Steps</summary>','','**Expected result:** success.','','</details>','','## Next','','- [Next](NEXT.md)')) 'Quickstart body contains details or summary'
Assert-InvalidCase 'generic summary rejected' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Why','','<details>','','<summary>Why reference</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'ends with a generic word'
Assert-InvalidCase 'summary matching heading rejected' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Why','','<details>','','<summary>Why</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'repeats its heading'
Assert-InvalidCase 'numbered heading with a generic summary' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## 5. Show units','','<details>','','<summary>5. Show units reference</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'ends with a generic word'
Assert-InvalidCase 'summary starting with its heading' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Generate a report','','<details>','','<summary>Generate a report commands, choices and checks</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'repeats its heading'
Assert-InvalidCase 'one-word summary' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','','<summary>Area</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'has 1 word'
Assert-ValidCase 'specific summary accepted' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Reference','','<details>','','<summary>CLI commands, backend profiles and manual Azure steps</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)'))
Assert-InvalidCase 'duplicate summaries rejected' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## One','','<details>','','<summary>First area</summary>','','Text.','','</details>','','## Two','','<details>','','<summary>First area</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'duplicated'
Assert-InvalidCase 'heading directly after a closing details tag' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','','<summary>Area</summary>','','Text.','','</details>','## Next','','- [Next](NEXT.md)')) 'follows </details> without a blank line'
Assert-ValidCase 'definition before fenced command' (Join-Lines @('# Guide','','`<developer-upn>` is the selected account.','','## Quickstart','','```powershell','Do-Thing -User <developer-upn>','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))

Assert-InvalidCase 'PowerShell variable before assignment' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'PowerShell variable'
Assert-InvalidCase 'PowerShell variable only mentioned in prose' (Join-Lines @('# Guide','','The command below uses `$rg` later.','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'PowerShell variable \$rg is used'
Assert-InvalidCase 'Quickstart PowerShell that does not parse' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','$record = ','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'does not parse'
Assert-InvalidCase 'Quickstart assignment without a variable' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell',' = Get-Content .\record.json -Raw','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'assignment has no variable'
Assert-InvalidCase 'fence opener with a backtick in its info string' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell`r`n$rg = 1','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'info string contains a backtick'
Assert-InvalidCase 'Quickstart script parameter that does not exist' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','.\scripts\Test-ClaudeHealth.ps1 -NoSuchSwitch','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'has no parameter -NoSuchSwitch'
Assert-InvalidCase 'Quickstart script that does not exist' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','.\scripts\No-SuchScript.ps1','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'names a script that does not exist'
Assert-InvalidCase 'pwsh -File script that does not exist' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','pwsh -NoProfile -File .\scripts\No-SuchScript.ps1','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'names a script that does not exist'
Assert-InvalidCase 'pwsh -File script parameter that does not exist' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','pwsh -NoProfile -File ./scripts/Test-ClaudeHealth.ps1 -NoSuchSwitch','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'has no parameter -NoSuchSwitch'
Assert-InvalidCase 'shell variable used before assignment' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```bash','az group show --name "$RG"','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'Shell variable \$RG'
Assert-ValidCase 'shell single-quoted dollar text is not a variable' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```bash','echo ''$TOKEN is set later''','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-ValidCase 'PowerShell automatic variables need no definition' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Write-Output $PSCommandPath $MyInvocation.MyCommand.Name $IsWindows $PSHOME','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-ValidCase 'Quickstart script call with its real parameters' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','.\scripts\Test-ClaudeHealth.ps1 -ResourceGroup rg-claude -ApimName apim-claude -FailOn warn','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-ValidCase 'PowerShell variable assigned before use' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','$rg = ''rg-claude''','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-ValidCase 'PowerShell variable defined in prose before use' (Join-Lines @('# Guide','','The `$rg` variable is the selected resource group.','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-ValidCase 'PowerShell variables defined together in prose' (Join-Lines @('# Guide','','`$rg` and `$apim` are the gateway resource group and API Management name.','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg -ApimName $apim','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-ValidCase 'PowerShell variable defined in a table' (Join-Lines @('# Guide','','| Input | Value |','|---|---|','| `$rg` | The gateway resource group |','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-InvalidCase 'local path and real name' (Join-Lines @('# Guide','','Purpose C:\Users\owner\checkout mentions Alice.','','## Quickstart','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'local machine path|personal/example name'

Assert-Condition ($NegativeFailures.Count -eq 0) ($NegativeFailures -join "`n")

$guides = Get-GuidePaths

Assert-Condition ($guides.Count -ge 44) "expected at least 44 source guides, found $($guides.Count)"

Write-Ok "source guide discovery found $($guides.Count) guides"



$developerBaseline = Get-GitBlobText "$BaselineCommit`:DEVELOPER.md"
Assert-Condition ($developerBaseline -match ('(?m)^# Claude Code ' + [char]0x2014 + ' developer setup')) 'baseline guides are not read as UTF-8: the DEVELOPER.md H1 em dash did not survive'
Write-Ok 'baseline guides are read as UTF-8 whatever the console encoding'

# A guide added after the baseline commit has no baseline anchors to keep. git ls-tree prints nothing for a
# path that the commit does not contain and fails only on a real error, so a failed read is never taken for
# a new guide.
function Test-BaselineGuidePath([string]$Path) {
  $listed = @(& git -C $Root ls-tree --name-only $BaselineCommit -- $Path 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git ls-tree failed for $Path at ${BaselineCommit}: $($listed -join ' ')" }
  return ($listed.Count -gt 0 -and [string]$listed[0] -eq $Path)
}
Assert-Condition (Test-BaselineGuidePath 'DEVELOPER.md') 'baseline path probe does not find DEVELOPER.md at the baseline commit'
Assert-Condition (-not (Test-BaselineGuidePath 'docs/NO-SUCH-GUIDE.md')) 'baseline path probe reports a guide that the baseline commit does not contain'

$guidesAddedAfterBaseline = [System.Collections.Generic.List[string]]::new()
foreach ($guide in $guides) {

  $currentPath = Join-Path $Root $guide

  $current = Get-Content -LiteralPath $currentPath -Raw

  $baselinePath = $guide -replace '\\','/'

  if (-not (Test-BaselineGuidePath $baselinePath)) { $guidesAddedAfterBaseline.Add($baselinePath); continue }

  $baseline = Get-GitBlobText "$BaselineCommit`:$baselinePath"

  if ($null -eq $baseline) { throw "baseline guide missing at $baselinePath" }

  $baseAnchors = Get-DocumentAnchors ($baseline -replace "`r`n", "`n")

  $currentAnchors = Get-DocumentAnchors ($current -replace "`r`n", "`n")

  foreach ($anchor in $baseAnchors) {

    Assert-Condition ($currentAnchors -contains $anchor) "anchor '$anchor' from $guide at $BaselineCommit is missing"

  }

}

$guidesCheckedAgainstBaseline = $guides.Count - $guidesAddedAfterBaseline.Count
Assert-Condition ($guidesCheckedAgainstBaseline -ge 44) "expected at least 44 guides checked against the baseline, checked $guidesCheckedAgainstBaseline"
Write-Ok "baseline heading and explicit anchors are preserved for every guide ($guidesCheckedAgainstBaseline checked; added after the baseline: $(if ($guidesAddedAfterBaseline.Count) { $guidesAddedAfterBaseline -join ', ' } else { 'none' }))"

$enrolledSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($guide in $EnrolledGuides) { [void]$enrolledSet.Add($guide) }
foreach ($guide in $guides) {
  if ($PermanentReferenceExceptions.ContainsKey($guide)) { continue }
  $text = Get-Content -LiteralPath (Join-Path $Root $guide) -Raw
  if ($text -match '(?m)^##\s+Quickstart\s*$' -and $text -match '<details>') {
    Assert-Condition ($enrolledSet.Contains($guide)) "converted guide is not enrolled: $guide"
  }
}
Write-Ok 'every converted guide is enrolled or a permanent exception'


foreach ($guide in $EnrolledGuides) {

  Assert-Condition ($guides -contains $guide) "enrolled guide not in source guide set: $guide"

  $text = Get-Content -LiteralPath (Join-Path $Root $guide) -Raw

  $errors = Test-GuideStructure $guide $text $true

  Assert-Condition ($errors.Count -eq 0) "structure errors in ${guide}: $($errors -join '; ')"

  Write-Ok "enrolled guide structure holds: $guide"

}

Write-Ok 'permanent reference exceptions are reasoned in the manifest'

# Templated summaries pass every per-guide rule while saying nothing: the same
# closing words appended to every heading. Count each summary's last three words
# across the enrolled guides; a phrase closing more than five summaries is a template.
$templateProbe = @(Get-TemplatedSummarySuffixes (@(1..6 | ForEach-Object { "Area $_ commands, choices and checks" })) 5)
Assert-Condition ($templateProbe.Count -eq 1) "templated-suffix check missed six shared endings: $($templateProbe -join ', ')"
Assert-Condition (@(Get-TemplatedSummarySuffixes (@(1..5 | ForEach-Object { "Area $_ commands, choices and checks" })) 5).Count -eq 0) 'templated-suffix check flagged five shared endings'
$allSummaries = [System.Collections.Generic.List[string]]::new()
foreach ($guide in $EnrolledGuides) {
  if ($PermanentReferenceExceptions.ContainsKey($guide)) { continue }
  $rows = Get-MarkdownScanLines ((Get-Content -LiteralPath (Join-Path $Root $guide) -Raw) -replace "`r", '')
  foreach ($row in $rows) { foreach ($m in [regex]::Matches($row.Text, '<summary>([^<]+)</summary>')) { $allSummaries.Add($m.Groups[1].Value.Trim()) } }
}
Assert-Condition ($allSummaries.Count -gt 0) 'no summaries found, so the templated-suffix check guards nothing'
$templated = @(Get-TemplatedSummarySuffixes $allSummaries.ToArray() 5)
Assert-Condition ($templated.Count -eq 0) "summaries share templated endings: $($templated -join '; ')"
Write-Ok "$($allSummaries.Count) summaries across enrolled guides share no templated ending"

Write-Host 'Documentation structure holds.'
