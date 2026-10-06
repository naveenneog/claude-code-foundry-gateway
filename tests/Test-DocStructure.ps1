

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
  'onboarding\README.md'
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

  $lines = $Text -split "`n", -1

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



function Get-H2Sections([string]$Text) {
  $normalized = $Text -replace "`r", ""
  $matches = [regex]::Matches($normalized, '(?m)^##\s+(.+?)\s*$')
  $sections = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $matches.Count; $i++) {
    $startIndex = $matches[$i].Index + $matches[$i].Length
    $endIndex = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $normalized.Length }
    $body = if ($endIndex -gt $startIndex) { $normalized.Substring($startIndex, $endIndex - $startIndex) } else { '' }
    $sections.Add([pscustomobject]@{
      Title = $matches[$i].Groups[1].Value.Trim()
      Start = $matches[$i].Index
      End = $endIndex
      Body = $body
    })
  }

  return ,$sections.ToArray()

}



function Test-GuideStructure([string]$Path, [string]$Text, [bool]$Enrolled) {

  $errors = New-Object System.Collections.Generic.List[string]

  if ($Text -match "(?<!`r)`n") { $errors.Add('working-tree line endings include isolated LF') }

  $logical = $Text -replace "`r`n", "`n"
  $logical = $logical -replace "`r", ""
  if ($logical -match '(?i)C:\\Users\\') { $errors.Add('local machine path appears in guide') }

  if ($logical -match '(?i)\bAlice\b|\bBob\b|\bNaveen\b') { $errors.Add('personal/example name appears in guide') }

  if (-not $Enrolled) { return ,$errors.ToArray() }



  $sections = Get-H2Sections $logical

  if ($sections.Count -eq 0) { $errors.Add('guide has no H2 sections'); return ,$errors.ToArray() }

  if ($sections[0].Title -ne 'Quickstart') { $errors.Add('first H2 is not Quickstart') }

  $beforeFirstH2 = ($logical -split "`n", -1)[0..([Math]::Max(0,$sections[0].Start-1))] -join "`n"

  if ($beforeFirstH2 -notmatch '(?m)^#\s+\S') { $errors.Add('missing visible H1 before Quickstart') }

  $purposeLines = ($beforeFirstH2 -split "`n") | Where-Object { $_.Trim() -and $_ -notmatch '^---$|^#|^title:|^description:' }

  if ($purposeLines.Count -eq 0) { $errors.Add('missing purpose line before Quickstart') }

  $quick = $sections[0].Body

  if ($quick -notmatch '(?i)Expected result') { $errors.Add('Quickstart lacks Expected result') }

  foreach ($ph in [regex]::Matches($quick, '<[a-zA-Z][a-zA-Z0-9-]*>')) {

    $idx = $quick.IndexOf($ph.Value)

    $prefix = $quick.Substring(0, $idx)

    if ($prefix -notmatch [regex]::Escape($ph.Value)) { $errors.Add("placeholder $($ph.Value) is used before local definition") }

  }



  $terminalNames = @('Next','Next steps','Related','See also','Verify and next steps','9. Next','Related guides','Troubleshoot and next steps','License','5. Next')

  $terminalIndex = -1
  for ($i=0; $i -lt $sections.Count; $i++) { if ($terminalNames -contains $sections[$i].Title) { $terminalIndex = $i } }
  if ($terminalIndex -lt 0) { $errors.Add('missing visible terminal Next/Related section') }
  elseif ($sections[$terminalIndex].Body -match '(?s)<details>') { $errors.Add('terminal navigation section is hidden in details') }



  for ($i = 1; $i -lt $sections.Count; $i++) {

    if ($terminalNames -contains $sections[$i].Title) { continue }

    if ($PermanentReferenceExceptions.ContainsKey($Path)) { continue }

    $body = $sections[$i].Body.Trim()

    if (-not $body) { continue }

    if ($body -notmatch '(?s)^<details>\s*\n\s*<summary>([^<\n#][^<\n]*)</summary>\s*\n\s*\n.+\n\s*</details>\s*$') { $errors.Add("section '$($sections[$i].Title)' body is not exactly one blank-separated details block") }

    if (($body | Select-String -Pattern '<details>' -AllMatches).Matches.Count -gt 1) { $errors.Add("section '$($sections[$i].Title)' nests disclosures") }

    if ($body -match '<summary>\s*(##|<h[1-6])') { $errors.Add("section '$($sections[$i].Title)' uses a heading in summary") }

    if ($body -match '(?i)(<details[^>]+name=|script>|style>)') { $errors.Add("section '$($sections[$i].Title)' uses unsupported disclosure control") }

  }

  return ,$errors.ToArray()

}



function Assert-InvalidCase([string]$Name, [string]$Text, [string]$Expected) {

  $material = $Text -replace '\\n', "`n"
  $errors = Test-GuideStructure 'docs\CASE.md' $material $true
  Assert-Condition (($errors -join '; ') -match $Expected) "negative case not detected: $Name. Errors: $($errors -join '; ')"

  Write-Ok "detected: $Name"

}



Write-Host 'Documentation structure - quickstarts, disclosures and anchors'
function Join-Lines([string[]]$Lines) { return ($Lines -join "`n") }

Assert-InvalidCase 'missing Quickstart' (Join-Lines @('# Guide','','Purpose.','','## Setup','','Text.','','## Next','','- [Next](NEXT.md)')) 'first H2'
Assert-InvalidCase 'absent Expected result' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Do-Thing','```','','## Next','','- [Next](NEXT.md)')) 'Expected result'
Assert-InvalidCase 'undefined placeholder before definition' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','```powershell','Do-Thing -User <developer-upn>','```','','`<developer-upn>` is defined too late.','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'used before'
Assert-InvalidCase 'summary without blank line' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','<summary>Reference</summary>','Text.','</details>','','## Next','','- [Next](NEXT.md)')) 'details block'
Assert-InvalidCase 'heading moved to summary' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Body','','<details>','','<summary>## Body</summary>','','Text.','','</details>','','## Next','','- [Next](NEXT.md)')) 'heading in summary'
Assert-InvalidCase 'terminal Next hidden' (Join-Lines @('# Guide','','Purpose.','','## Quickstart','','**Expected result:** success.','','## Next','','<details>','','<summary>Navigation</summary>','','- [Next](NEXT.md)','','</details>')) 'terminal navigation'
Assert-InvalidCase 'local path and real name' (Join-Lines @('# Guide','','Purpose C:\Users\owner\checkout mentions Alice.','','## Quickstart','','**Expected result:** success.','','## Next','','- [Next](NEXT.md)')) 'local machine path|personal/example name'

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



foreach ($guide in $EnrolledGuides) {

  Assert-Condition ($guides -contains $guide) "enrolled guide not in source guide set: $guide"

  $text = Get-Content -LiteralPath (Join-Path $Root $guide) -Raw

  $errors = Test-GuideStructure $guide $text $true

  Assert-Condition ($errors.Count -eq 0) "structure errors in ${guide}: $($errors -join '; ')"

  Write-Ok "enrolled guide structure holds: $guide"

}

Write-Ok 'permanent reference exceptions are reasoned in the manifest'

Write-Host 'Documentation structure holds.'
