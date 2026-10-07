

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
  $pattern = '(?i)(?<![A-Za-z0-9_-])\$' + [regex]::Escape($Name) + '(?![A-Za-z0-9_-])'
  foreach ($line in @($ScanLines | Where-Object { $_.Number -lt $BeforeLine -and -not $_.InFence -and $_.Text.Trim() })) {
    if ($line.Text -match $pattern) { return $true }
  }
  return $false
}

function Test-QuickstartPowerShellVariables([string]$Path, [object]$Section, [object[]]$ScanLines) {
  $errors = [System.Collections.Generic.List[string]]::new()
  $auto = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($name in @('true','false','null','_','PSItem','LASTEXITCODE','PSScriptRoot','HOME','PWD','args','Matches','Error','Host','PSVersionTable')) { [void]$auto.Add($name) }
  $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($block in Get-FencedBlocks $Section.Body) {
    if ($block.Language -notin @('powershell','pwsh','ps1')) { continue }
    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($block.Text, [ref]$tokens, [ref]$parseErrors)
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

function Test-QuickstartShellVariables([object]$Section, [object[]]$ScanLines) {
  $errors = [System.Collections.Generic.List[string]]::new()
  $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($block in Get-FencedBlocks $Section.Body) {
    if ($block.Language -notin @('bash','sh','shell')) { continue }
    $lines = $block.Text -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
      $line = $lines[$i]
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

function Test-GuideStructure([string]$Path, [string]$Text, [bool]$Enrolled) {
  $errors = New-Object System.Collections.Generic.List[string]
  if ($Text -match "(?<!`r)`n") { $errors.Add('working-tree line endings include isolated LF') }
  $logical = $Text -replace "`r`n", "`n"
  $logical = $logical -replace "`r", ""
  if ($logical -match '(?i)C:\\Users\\') { $errors.Add('local machine path appears in guide') }
  if ($logical -match '(?i)\bAlice\b|\bBob\b|\bNaveen\b') { $errors.Add('personal/example name appears in guide') }
  $closeRows = @(Get-MarkdownScanLines $logical)
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
      if ($summary -match '(?i)^.+\sdetails$') { $errors.Add("section '$($sections[$i].Title)' uses generic summary '$summary'") }
      if (-not $summaries.Add($summary.ToLowerInvariant())) { $errors.Add("summary '$summary' is duplicated in $Path") }
    }
    if (($body | Select-String -Pattern '<details>' -AllMatches).Matches.Count -gt 1) { $errors.Add("section '$($sections[$i].Title)' nests disclosures") }
    if ($body -match '<summary>\s*(##|<h[1-6])') { $errors.Add("section '$($sections[$i].Title)' uses a heading in summary") }
    if ($body -match '(?i)(<details[^>]+name=|script>|style>)') { $errors.Add("section '$($sections[$i].Title)' uses unsupported disclosure control") }
  }
  return ,$errors.ToArray()
}

function Assert-InvalidCase([string]$Name, [string]$Text, [string]$Expected) {

  $material = $Text -replace '\\n', "`n"
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

function Assert-NoPlaceholderCase([string]$Name, [string]$Text) {
  $material = $Text -replace '\\n', "`n"
  $errors = Test-GuideStructure 'docs\CASE.md' ($material -replace "`n", "`r`n") $true
  $placeholderErrors = @($errors | Where-Object { $_ -match 'placeholder' })
  if ($placeholderErrors.Count -eq 0) {
    Write-Ok "placeholder definitions accepted: $Name"
  } else {
    $script:NegativeFailures.Add("positive placeholder case failed: $Name. Errors: $($placeholderErrors -join '; ')")
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
  }
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
Assert-InvalidCase 'generic summary rejected' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','','<summary>Guide details</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'generic summary'
Assert-InvalidCase 'duplicate summaries rejected' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## One','','<details>','','<summary>First area</summary>','','Text.','','</details>','','## Two','','<details>','','<summary>First area</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'duplicated'
Assert-InvalidCase 'heading directly after a closing details tag' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','','<summary>Area</summary>','','Text.','','</details>','## Next','','- [Next](NEXT.md)')) 'follows </details> without a blank line'
Assert-NoPlaceholderCase 'definition before fenced command' (Join-Lines @('# Guide','','`<developer-upn>` is the selected account.','','## Quickstart','','```powershell','Do-Thing -User <developer-upn>','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))

Assert-InvalidCase 'PowerShell variable before assignment' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'PowerShell variable'
Assert-NoPlaceholderCase 'PowerShell variable assigned before use' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','$rg = ''rg-claude''','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-NoPlaceholderCase 'PowerShell variable defined in prose before use' (Join-Lines @('# Guide','','The `$rg` variable is the selected resource group.','','## Quickstart','','```powershell','Do-Thing -ResourceGroup $rg','```','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)'))
Assert-InvalidCase 'local path and real name' (Join-Lines @('# Guide','','Purpose C:\Users\owner\checkout mentions Alice.','','## Quickstart','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'local machine path|personal/example name'

Assert-Condition ($NegativeFailures.Count -eq 0) ($NegativeFailures -join "`n")

$guides = Get-GuidePaths

Assert-Condition ($guides.Count -ge 44) "expected at least 44 source guides, found $($guides.Count)"

Write-Ok "source guide discovery found $($guides.Count) guides"



foreach ($guide in $guides) {

  $currentPath = Join-Path $Root $guide

  $current = Get-Content -LiteralPath $currentPath -Raw

  $baselinePath = $guide -replace '\\','/'

  $baseline = & git -C $Root show "$BaselineCommit`:$baselinePath" 2>$null

  if ($LASTEXITCODE -ne 0) { throw "baseline guide missing at $baselinePath" }

  $baseAnchors = Get-DocumentAnchors ($baseline -join "`n")

  $currentAnchors = Get-DocumentAnchors ($current -replace "`r`n", "`n")

  foreach ($anchor in $baseAnchors) {

    Assert-Condition ($currentAnchors -contains $anchor) "anchor '$anchor' from $guide at $BaselineCommit is missing"

  }

}

Write-Ok 'baseline heading and explicit anchors are preserved for every guide'

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

Write-Host 'Documentation structure holds.'
