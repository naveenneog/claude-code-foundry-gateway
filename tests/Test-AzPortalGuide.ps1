param(
    [string]$GuidePath,
    [string]$SpecPath,
    [string]$CapturePath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $GuidePath) { $GuidePath = Join-Path $root 'docs\AZ-COMMANDS.md' }
if (-not $SpecPath) { $SpecPath = Join-Path $root 'guide\captures-pending\p90.json' }
if (-not $CapturePath) { $CapturePath = Join-Path $root 'docs\guide\portal-captures.json' }

$script:fail = 0
function Assert($Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
    }
}

function Read-Text($Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Path" }
    Get-Content -LiteralPath $Path -Raw
}

function Get-PartBody([string]$Markdown, [int]$Part) {
    $pattern = "(?ms)^## $Part\. .*?(?=^## \d+\. |^## Pending portal captures|\z)"
    $match = [regex]::Match($Markdown, $pattern)
    if ($match.Success) { return $match.Value }
    return ''
}

function Get-PortalBody([string]$PartBody, [int]$Part) {
    $pattern = "(?ms)^### Part $Part in the portal\s*(.*?)(?=^## \d+\. |^## Pending portal captures|\z)"
    $match = [regex]::Match($PartBody, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-PortalStepTitles([string]$PortalBody) {
    @([regex]::Matches($PortalBody, '(?m)^\d+\. \*\*(.*?)\.\*\*') | ForEach-Object { $_.Groups[1].Value })
}

function Get-CodeFenceText([string]$Markdown) {
    @([regex]::Matches($Markdown, '(?ms)^```(?:bash|powershell)?\r?\n(.*?)^```') | ForEach-Object { $_.Groups[1].Value }) -join "`n"
}

function Get-MarkedBlockText([string]$Markdown, [string]$Marker) {
    $begin = [regex]::Escape("# $Marker-BEGIN")
    $end = [regex]::Escape("# $Marker-END")
    $match = [regex]::Match($Markdown, "(?ms)$begin\s*(.*?)\s*$end")
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-AzLeadSentences([string]$PartBody) {
    $lines = $PartBody -split "`r?`n"
    $leads = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^```bash') {
            for ($j = $i - 1; $j -ge 0; $j--) {
                $lead = $lines[$j].Trim()
                if (-not $lead) { continue }
                if ($lead -notmatch '^Expected result:' -and $lead -notmatch '^### ' -and $lead -notmatch '^```') {
                    $leads += $lead
                }
                break
            }
        }
    }
    $leads
}

function ConvertTo-RepoPath([string]$MarkdownPath) {
    $withoutAnchor = ($MarkdownPath -replace '#.*$', '')
    if (-not $withoutAnchor) { return $null }
    if ($withoutAnchor -match '^[a-z]+://') { return $null }
    $combined = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'docs') ($withoutAnchor -replace '/', '\')))
    if (-not $combined.StartsWith((Join-Path $root 'docs'), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Image reference escapes docs: $MarkdownPath"
    }
    return $combined
}

function Load-Spec([string]$RelativePath) {
    $full = Join-Path $root ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing spec $RelativePath" }
    return Read-Text $full | ConvertFrom-Json
}

Write-Host 'Azure CLI portal guide contract' -ForegroundColor Cyan
$markdown = Read-Text $GuidePath

Assert 'guide contains no six-asterisk Authorization mask' (-not $markdown.Contains('******')) '******'
$authorizationValues = @([regex]::Matches($markdown, 'Authorization: ([^"
]+)') | ForEach-Object { $_.Groups[1].Value })
foreach ($value in $authorizationValues) {
    Assert 'Authorization header starts with Bearer' ($value.StartsWith('Bearer ')) $value
}

$expectedPortalSteps = [ordered]@{
    '1' = @(
        'Set the subscription and confirm the signed-in tenant'
        'Register the resource providers'
        'Discover the Foundry account and Claude deployments'
        'List deployable Claude models when no deployment exists'
        'Check the operator roles without changing them'
    )
    '2' = @(
        'Create the resource group'
        'Confirm the APIM name is absent'
        'Validate the gateway template before deployment'
        'Deploy the gateway template'
        'Reuse an existing APIM instance that has never hosted this gateway'
        'Read policy deployment state'
        'Write and read back one named value'
        'Review template-created diagnostic settings'
    )
    '3' = @(
        'Read the gateway identity and Foundry scope'
        'Enable a missing system-assigned identity before deployment reuses APIM'
        'Grant `Cognitive Services User` to the APIM managed identity when the list above is empty'
    )
    '4' = @(
        'Set tier limits, organisation ceiling, per-minute calls and model allow lists'
        'Set entitlement source and resolver placeholders for the named-value path'
        'Verify the authorization and budget named values that the template initialized'
    )
    '5' = @(
        'Create or discover the two tier groups'
        'Read transitive members from Microsoft Graph as users and service principals'
        'Publish the entitlement lists to APIM named values'
        'Add one developer to a tier and publish'
        'Remove one developer from both tiers and publish'
    )
    '6' = @(
        'List the two tiers'
        'Change one tier''s model list and limits'
        'Set one person''s daily token budget'
        'Clear that person''s daily token budget'
        'Review Foundry deployments before adding a model'
        'Deploy a new Claude model through ARM when Azure requires Anthropic provider data'
        'Add the deployed model to tiers and record prices'
    )
    '7' = @(
        'Create or discover the Desktop public-client app'
        'Configure Desktop redirect URIs'
        'Review Desktop consent state without adding API permissions'
        'Publish the Desktop audience to APIM'
    )
    '8' = @(
        'Resolve the live gateway URL and SKU'
        'Write the developer handover file'
    )
    '9' = @(
        'Review the current gateway hostnames before binding a company address'
        'Validate a Key Vault certificate and grant APIM access'
        'Patch APIM hostname configurations and prove TLS before publishing the handover URL'
    )
    '10' = @(
        'Run read-only preflight checks before any projection write'
        'Create the resolver app registration as a tenant-admin step'
        'Deploy private projection storage and networking'
        'Deploy the resolver with Standard v2 outbound VNet integration and upload code'
        'Set resolver named values without switching entitlement'
        'Populate and compare the projection through an in-VNet runner container'
    )
    '11' = @(
        'Resolve the gateway URL and run an entitled request'
        'Verify non-entitled, model-refusal, bypass-audit and call-ceiling behavior'
        'Review gateway diagnostic settings and Log Analytics tables'
    )
    '12' = @(
        'Delete the gateway resource group after external receipts are reviewed'
        'Review soft-deleted APIM instances before name reuse'
        'Delete receipt-created external objects'
    )
}

$azPortalMapping = [ordered]@{
    '1' = @(
        @{ portal = 'Set the subscription and confirm the signed-in tenant'; az = @('Set the subscription and confirm the signed-in tenant.') }
        @{ portal = 'Register the resource providers'; az = @('Register the resource providers the setup uses.') }
        @{ portal = 'Discover the Foundry account and Claude deployments'; az = @('Discover the Foundry account and Claude deployments.') }
        @{ portal = 'List deployable Claude models when no deployment exists'; az = @('List deployable Claude models when no deployment exists.') }
        @{ portal = 'Check the operator roles without changing them'; az = @('Check the operator roles without changing them.') }
    )
    '2' = @(
        @{ portal = 'Create the resource group'; az = @('Create the resource group.') }
        @{ portal = 'Confirm the APIM name is absent'; az = @('Confirm the APIM name is absent before running the first-deployment commands below.') }
        @{ portal = 'Validate the gateway template before deployment'; az = @('Validate the gateway template before deployment.') }
        @{ portal = 'Deploy the gateway template'; az = @('Deploy Basic v2.', 'Deploy Standard v2 when outbound VNet integration is required.', 'Deploy Premium v2 when the gateway itself must be injected privately.') }
        @{ portal = 'Reuse an existing APIM instance that has never hosted this gateway'; az = @('Reuse an existing APIM instance that has never hosted this gateway.', 'The create follows review of the what-if output.') }
        @{ portal = 'Read policy deployment state'; az = @('Read policy deployment state.') }
        @{ portal = 'Write and read back one named value'; az = @('Write and read back one named value the same way the helper does.') }
        @{ portal = 'Review template-created diagnostic settings'; none = 'Template-created diagnostic settings are a portal read-only review.' }
    )
    '3' = @(
        @{ portal = 'Read the gateway identity and Foundry scope'; az = @('Read the gateway identity and Foundry scope.') }
        @{ portal = 'Enable a missing system-assigned identity before deployment reuses APIM'; az = @('Optional: enable a missing system-assigned identity on an existing APIM instance, then reread it.') }
        @{ portal = 'Grant `Cognitive Services User` to the APIM managed identity when the list above is empty'; az = @('Grant `Cognitive Services User` to the APIM managed identity when the list above is empty.') }
    )
    '4' = @(
        @{ portal = 'Set tier limits, organisation ceiling, per-minute calls and model allow lists'; az = @('Set tier limits, organisation ceiling, per-minute calls and model allow lists.') }
        @{ portal = 'Set entitlement source and resolver placeholders for the named-value path'; az = @('Set entitlement source and resolver placeholders for the named-value path.') }
        @{ portal = 'Verify the authorization and budget named values that the template initialized'; az = @('Verify the authorization and budget named values that the template initialized.') }
    )
    '5' = @(
        @{ portal = 'Create or discover the two tier groups'; az = @('Create or discover the two tier groups.') }
        @{ portal = 'Read transitive members from Microsoft Graph as users and service principals'; az = @('Read transitive members from Microsoft Graph as users and service principals.') }
        @{ portal = 'Publish the entitlement lists to APIM named values'; az = @('Publish premium first, then standard without duplicates.') }
        @{ portal = 'Add one developer to a tier and publish'; az = @('Add one developer to a tier and publish.') }
        @{ portal = 'Remove one developer from both tiers and publish'; az = @('Remove one developer from both tiers and publish.') }
    )
    '6' = @(
        @{ portal = 'List the two tiers'; az = @('List the two tiers.') }
        @{ portal = 'Change one tier''s model list and limits'; az = @('Change one tier''s model list and limits.') }
        @{ portal = 'Set one person''s daily token budget'; az = @('Set one person''s daily token budget.') }
        @{ portal = 'Clear that person''s daily token budget'; az = @('Clear that person''s daily token budget.') }
        @{ portal = 'Review Foundry deployments before adding a model'; az = @('Review Foundry deployments before adding a model.') }
        @{ portal = 'Deploy a new Claude model through ARM when Azure requires Anthropic provider data'; az = @('Deploy a new Claude model through ARM when Azure requires Anthropic provider data.') }
        @{ portal = 'Add the deployed model to tiers and record prices'; az = @('Add the deployed model to tiers and record prices.') }
    )
    '7' = @(
        @{ portal = 'Create or discover the Desktop public-client app'; az = @('Create or discover the Desktop public-client app.') }
        @{ portal = 'Configure Desktop redirect URIs'; az = @('Set public-client redirect URIs, including broker redirects when the Desktop profile uses broker flow.') }
        @{ portal = 'Review Desktop consent state without adding API permissions'; none = 'No az command grants consent or configures API permissions.' }
        @{ portal = 'Publish the Desktop audience to APIM'; az = @('Publish the Desktop gateway audience into APIM.') }
    )
    '8' = @(
        @{ portal = 'Resolve the live gateway URL and SKU'; az = @('Resolve the live gateway URL and SKU.') }
        @{ portal = 'Write the developer handover file'; az = @('Generate `onboarding/claude-gateway.json` with the same schema the installer writes.') }
    )
    '9' = @(
        @{ portal = 'Review the current gateway hostnames before binding a company address'; az = @('Review the current gateway hostnames before binding a company address.') }
        @{ portal = 'Validate a Key Vault certificate and grant APIM access'; az = @('Validate a Key Vault certificate and grant APIM access.') }
        @{ portal = 'Patch APIM hostname configurations and prove TLS before publishing the handover URL'; az = @('Patch APIM hostname configurations and prove TLS before publishing the handover URL.') }
    )
    '10' = @(
        @{ portal = 'Run read-only preflight checks before any projection write'; az = @('Run read-only preflight checks before any projection write.') }
        @{ portal = 'Create the resolver app registration as a tenant-admin step'; az = @('Create the resolver app registration as a tenant-admin step.') }
        @{ portal = 'Deploy private projection storage and networking'; az = @('Deploy private projection storage and networking.') }
        @{ portal = 'Deploy the resolver with Standard v2 outbound VNet integration and upload code'; az = @('Deploy the resolver with Standard v2 outbound VNet integration and upload code.') }
        @{ portal = 'Set resolver named values without switching entitlement'; az = @('Set resolver named values without switching entitlement.') }
        @{ portal = 'Populate and compare the projection through an in-VNet runner container'; az = @('Populate and compare the projection through an in-VNet runner container.') }
        @{ none = 'Projection switch status is read-only and intentionally has no portal step.'; az = @('Projection switch status.') }
    )
    '11' = @(
        @{ portal = 'Resolve the gateway URL and run an entitled request'; az = @("Send a real request with the signed-in user's Foundry token through the gateway.") }
        @{ portal = 'Verify non-entitled, model-refusal, bypass-audit and call-ceiling behavior'; az = @('Verify a non-entitled caller is refused.', 'Verify a model outside the tier is refused.', 'Check for direct Foundry bypass.', 'Measure the per-minute call ceiling.') }
        @{ portal = 'Review gateway diagnostic settings and Log Analytics tables'; none = 'Diagnostic portal review has no az command lead sentence.' }
    )
    '12' = @(
        @{ portal = 'Delete the gateway resource group after external receipts are reviewed'; az = @('Delete the gateway resource group only when this guide created it.') }
        @{ portal = 'Review soft-deleted APIM instances before name reuse'; none = 'Soft-delete review has no portal label asserted by an az block.' }
        @{ portal = 'Delete receipt-created external objects'; az = @('Read resources before deletion.', 'Remove only external resources this guide recorded as created.') }
    )
}

for ($part = 1; $part -le 12; $part++) {
    $body = Get-PartBody $markdown $part
    Assert "part $part exists" ($body.Length -gt 0) "part=$part"
    $portalHeadingCount = @([regex]::Matches($body, "(?m)^### Part $part in the portal\s*$")).Count
    Assert "part $part has exactly one portal subsection" ($portalHeadingCount -eq 1) "count=$portalHeadingCount"
    $portal = Get-PortalBody $body $part
    $titles = @(Get-PortalStepTitles $portal)
    $expectedTitles = @($expectedPortalSteps[[string]$part])
    Assert "part $part portal step count is fixed" ($titles.Count -eq $expectedTitles.Count) "actual=$($titles.Count) expected=$($expectedTitles.Count)"
    for ($i = 0; $i -lt $expectedTitles.Count; $i++) {
        $actualTitle = if ($i -lt $titles.Count) { $titles[$i] } else { '<missing>' }
        Assert "part $part portal step $($i + 1) title is ordered" ($actualTitle -eq $expectedTitles[$i]) "actual=$actualTitle expected=$($expectedTitles[$i])"
    }
    Assert 'part 8 documents no portal equivalent' (($part -ne 8) -or ($portal -match '(?i)No portal equivalent')) 'part=8'
    $changeLaterCount = @([regex]::Matches($portal, '(?m)^\*\*Change later\.\*\*')).Count
    Assert "part $part has exactly one portal Change later paragraph" ($changeLaterCount -eq 1) "count=$changeLaterCount"
    $scanText = $portal
    $bannedPatterns = [ordered]@{
        'portal prose avoids Do not' = '(?i)\bDo not\b'
        'portal prose avoids Don''t' = '(?i)\bDon''t\b'
        'portal prose avoids Make sure' = '(?i)\bMake sure\b'
        'portal prose avoids Ensure' = '(?i)\bEnsure\b'
        'portal prose avoids Remember' = '(?i)\bRemember\b'
        'portal prose avoids Note that' = '(?i)\bNote that\b'
        'portal prose avoids important' = '(?i)\bimportant\b'
        'portal prose avoids leading Keep outside titles' = '(?m)^(?!\d+\. \*\*)\s*Keep\b'
        'portal prose avoids leading Edit outside titles' = '(?m)^(?!\d+\. \*\*)\s*Edit\b'
        'portal prose avoids leading Use outside titles' = '(?m)^(?!\d+\. \*\*)\s*Use\b'
    }
    foreach ($entry in $bannedPatterns.GetEnumerator()) {
        $found = [regex]::Match($scanText, $entry.Value)
        Assert "part $part $($entry.Key)" (-not $found.Success) $found.Value
    }
    $changeLaterText = ''
    $changeLater = [regex]::Match($portal, '(?ms)^\*\*Change later\.\*\*\s*(?<text>.*?)(?=\r?\n\r?\n|\z)')
    if ($changeLater.Success) { $changeLaterText = $changeLater.Groups['text'].Value.Trim() }
    $imperative = [regex]::Match($changeLaterText, '^(Change|Edit|Rerun|Update|Delete|Add|Set|Run|Regenerate|Redistribute)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    Assert "part $part Change later does not start with a bare imperative verb" (-not $imperative.Success) $imperative.Value

    if ($part -eq 2) {
        Assert 'part 2 portal cites the resource-group function' ($portal -match 'p89_resource_group') 'p89_resource_group'
        Assert 'part 2 portal cites the reused-APIM create text' ($portal -match [regex]::Escape('The create follows review of the what-if output.')) 'The create follows review of the what-if output.'
    }
    if ($part -eq 8) { Assert 'part 8 portal cites gateway URL function' ($portal -match 'p89_gateway_url') 'p89_gateway_url' }
    if ($part -eq 9) {
        Assert 'part 9 portal documents immediate dig absence refusal' ($portal -match 'refuses at once when `dig` is absent') 'dig absence refusal'
        Assert 'part 9 portal documents 600-second DNS wait' (($portal -match '600 s') -and ($portal -match 'P89_DNS_TIMEOUT_SECONDS=600')) '600 s P89_DNS_TIMEOUT_SECONDS=600'
        Assert 'part 9 portal documents 2700-second hostname wait' (($portal -match '2,700 s \(45 minutes\)') -and ($portal -match 'P89_HOSTNAME_TIMEOUT_SECONDS=2700') -and ($portal -match 'scripts/Set-ClaudeGatewayAddress.ps1:16')) '2,700 s P89_HOSTNAME_TIMEOUT_SECONDS=2700 scripts/Set-ClaudeGatewayAddress.ps1:16'
    }
    if ($part -eq 11) { Assert 'part 11 portal cites model-refusal function' ($portal -match 'p89_verify_model_refusal') 'p89_verify_model_refusal' }
    if ($part -eq 12) {
        Assert 'part 12 portal cites teardown-group function' ($portal -match 'p89_teardown_group') 'p89_teardown_group'
        Assert 'part 12 portal lists appinsights logger view' (($portal -match 'Monitoring > Application Insights') -and ($portal -match 'logger `appinsights`')) 'Monitoring > Application Insights logger `appinsights`'
        Assert 'part 12 portal documents resource-group receipt tag' (($portal -match 'claude-gateway-receipt') -and ($portal -match 'Resource groups > `\$GATEWAY_RG` > Tags')) 'claude-gateway-receipt Resource group > Tags'
        Assert 'part 12 portal documents no receipts for portal-created objects' (($portal -match 'no `\.p89-receipts` entry') -and ($portal -match 'exact name, creation time and the gateway they serve')) 'portal-created objects receipt wording'
        Assert 'part 12 portal documents role scope and principal checks' (($portal -match 'Foundry role assignments') -and ($portal -match 'verify role, scope and principal') -and ($portal -match 'Key Vault role assignments')) 'role scope principal checks'
    }
    if ($part -eq 7) {
        Assert 'part 7 portal states external-idp applicability' (($portal -match 'external-idp-browser') -and ($portal -match 'external-idp-broker') -and ($portal -match 'helper-script')) 'external-idp-browser external-idp-broker helper-script'
    }
    if ($part -eq 7) {
        Assert 'part 7 intro matches P89 applicability' ($body.Contains("§7 applies only to ``external-idp-browser`` and ``external-idp-broker`` Desktop sign-in; ``helper-script`` uses the developer's Azure CLI sign-in and no app registration")) 'P89 §7 applicability sentence'
    }
    if ($part -eq 10) {
        Assert 'part 10 Change later is a table' ($portal -match '(?m)^\| Changed item \| Portal blade \| Block that reruns \| Effect while `entitlement-source` is `named-value` \|') 'Change later table header'
    }

    $azLeads = @(Get-AzLeadSentences $body)
    $mappings = @($azPortalMapping[[string]$part])
    $mappedPortalTitles = @($mappings | Where-Object { $_.ContainsKey('portal') } | ForEach-Object { $_.portal })
    Assert "part $part every portal step has an az mapping or declared no-portal entry" ((@($titles | Sort-Object) -join "`n") -eq (@($mappedPortalTitles | Sort-Object) -join "`n")) "portal=$($titles -join ' | ') mapped=$($mappedPortalTitles -join ' | ')"

    foreach ($mapping in $mappings) {
        if ($mapping.ContainsKey('portal')) {
            Assert "part $part mapped portal step exists: $($mapping.portal)" ($titles -contains $mapping.portal) $mapping.portal
        }
        else {
            Assert "part $part no-portal entry declares a reason" ($mapping.none.Length -gt 0) ($mapping.none)
        }
        if ($mapping.ContainsKey('az')) {
            foreach ($lead in @($mapping.az)) {
                $count = @($azLeads | Where-Object { $_ -eq $lead }).Count
                Assert "part $part mapped az lead exists exactly once: $lead" ($count -eq 1) "count=$count"
            }
        }
    }

    $mappedLeads = @()
    foreach ($mapping in $mappings) {
        if ($mapping.ContainsKey('az')) { $mappedLeads += @($mapping.az) }
    }
    Assert "part $part az lead set matches mapping" ((@($azLeads | Sort-Object) -join "`n") -eq (@($mappedLeads | Sort-Object) -join "`n")) "az=$($azLeads -join ' | ') mapped=$($mappedLeads -join ' | ')"
}

Assert 'per-step Portal paragraphs are removed' (-not ($markdown -match '(?m)^\*\*Portal\.\*\*'))

$withoutFences = [regex]::Replace($markdown, '(?ms)^```.*?^```', '')
$outsideMarker = [regex]::Match($withoutFences, 'P89-[A-Z-]+')
Assert 'guide prose outside fences avoids P89 marker names' (-not $outsideMarker.Success) $outsideMarker.Value
$outsideLeadSentence = [regex]::Match($withoutFences, '(?i)lead sentence')
Assert 'guide prose outside fences avoids lead sentence wording' (-not $outsideLeadSentence.Success) $outsideLeadSentence.Value
$paragraphs = @(
    [regex]::Split($withoutFences, "(?:\r?\n){2,}") |
    ForEach-Object { ($_.Trim() -replace '\s+', ' ') } |
    Where-Object { $_.Length -ge 80 -and -not $_.StartsWith('|') -and -not $_.StartsWith('![') }
)
$duplicateParagraphs = @(
    $paragraphs | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
)
Assert 'no duplicate prose paragraphs of 80+ chars outside fenced blocks' ($duplicateParagraphs.Count -eq 0) ($duplicateParagraphs -join ' || ')

$captureDoc = Read-Text $CapturePath | ConvertFrom-Json
$recordsByOutput = @{}
foreach ($record in $captureDoc.captures) {
    $recordsByOutput[$record.output] = $record
}
$recordsById = @{}
foreach ($record in $captureDoc.captures) {
    $recordsById[$record.id] = $record
}
$expectedLiveCaptureIds = @(
    'architecture-foundry-overview'
    'architecture-foundry-access'
    'gateway-overview'
    'p54-apim-network'
    'docs-review-api-settings'
    'docs-review-api-policy'
    'docs-review-gateway-diagnostics'
    'gateway-identity'
    'docs-review-gateway-identity'
    'docs-review-foundry-iam'
    'gateway-named-values'
    'docs-review-entra-groups'
    'docs-review-daily-quota-editor'
    'p54-vault-certificate'
    'p54-vault-role'
    'docs-review-cosmos-networking'
    'p54-private-endpoint'
    'p54-private-dns'
    'architecture-projection-networking'
    'docs-review-resolver-authentication'
    'docs-review-resolver-networking'
    'docs-review-workspace-tables'
    'docs-review-workspace-functions'
    'docs-review-workspace-workbooks'
)
$imageCaptionMatches = @([regex]::Matches($markdown, '(?ms)!\[[^\]]+\]\(([^)]+\.png)\)\s*\r?\n\s*\r?\nCapture id:\s+`([^`]+)`\.'))
$imagesByCaption = @{}
foreach ($match in $imageCaptionMatches) {
    $imagesByCaption[$match.Groups[2].Value] = $match.Groups[1].Value
}
$captionIds = @([regex]::Matches($markdown, 'Capture id:\s+`([^`]+)`\.') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
$expectedLiveCaptionIds = @($expectedLiveCaptureIds + @('architecture-foundry-access', 'docs-review-gateway-diagnostics', 'gateway-named-values') | Sort-Object)
Assert 'live capture captions match the fixed expected set' (($captionIds -join "`n") -eq ($expectedLiveCaptionIds -join "`n")) "actual=$($captionIds -join ', ') expected=$($expectedLiveCaptionIds -join ', ')"
foreach ($expectedId in $expectedLiveCaptureIds) {
    Assert "expected live capture is referenced: $expectedId" ($captionIds -contains $expectedId) $expectedId
    $relative = if ($imagesByCaption.ContainsKey($expectedId)) { $imagesByCaption[$expectedId] } else { '' }
    Assert "expected live capture has an image: $expectedId" ($relative.Length -gt 0) $expectedId
    $file = if ($relative) { ConvertTo-RepoPath $relative } else { Join-Path $root '__missing__.png' }
    $repoOutput = (Resolve-Path -LiteralPath $file -ErrorAction SilentlyContinue)
    Assert "image resolves for capture: $expectedId" ($null -ne $repoOutput) $relative
    $output = if ($repoOutput) { [IO.Path]::GetRelativePath($root, $repoOutput.Path).Replace('\', '/') } else { '' }
    $record = if ($output) { $recordsByOutput[$output] } else { $null }
    Assert "image has portal capture record: $expectedId" ($null -ne $record) $output
    $recordOk = $false
    $shaOk = $false
    $recordId = ''
    if ($record) {
        $recordId = $record.id
        $recordOk = [bool]$record.live -and [bool]$record.redaction.applied -and [bool]$record.redaction.leak_check_passed
        if ($repoOutput) {
            $sha = (Get-FileHash -LiteralPath $repoOutput.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            $shaOk = $sha -eq $record.sha256
        }
    }
    Assert "record is live and redacted: $expectedId" $recordOk $recordId
    Assert "record sha256 matches file: $expectedId" $shaOk $output
    Assert "caption id matches record id: $expectedId" ($recordId -eq $expectedId) $recordId
}

$pendingMatch = [regex]::Match($markdown, '(?ms)^## Pending portal captures.*?(?<table>\| planned capture id \| output path under `docs/guide/` \| spec file \| blade \| which step it illustrates \| what must exist live \| capture discovery kind \|\s*\r?\n\|[- |`]+\|\s*\r?\n(?<rows>(?:\|.*\|\s*\r?\n)+))')
Assert 'pending-captures table exists with spec file column' $pendingMatch.Success
$pending = @()
if ($pendingMatch.Success) {
    foreach ($line in ($pendingMatch.Groups['rows'].Value -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -eq 7) {
            $pending += [pscustomobject]@{
                id = $cells[0].Trim('`')
                output = 'docs/guide/' + $cells[1].Trim('`')
                specFile = $cells[2].Trim('`')
            }
        }
    }
}

$allSpecPairs = @()
$specCache = @{}
foreach ($specFile in @('guide/captures-pending/p90.json', 'guide/captures/p60.json')) {
    if (-not $specCache.ContainsKey($specFile)) {
        $specCache[$specFile] = Load-Spec $specFile
    }
    foreach ($step in @($specCache[$specFile].steps)) {
        $allSpecPairs += [pscustomobject]@{
            id = $step.id
            output = $step.output
            specFile = $specFile
        }
    }
}

$pendingPairs = @($pending | ForEach-Object { "$($_.id)|$($_.output)|$($_.specFile)" } | Sort-Object)
$specPairs = @($allSpecPairs | ForEach-Object { "$($_.id)|$($_.output)|$($_.specFile)" } | Sort-Object)
Assert 'pending table matches every staged spec row in both directions' (($pendingPairs -join "`n") -eq ($specPairs -join "`n")) "table=$($pendingPairs -join ', ') spec=$($specPairs -join ', ')"
foreach ($item in $allSpecPairs) {
    $row = @($pending | Where-Object { $_.id -eq $item.id -and $_.output -eq $item.output -and $_.specFile -eq $item.specFile })
    Assert "pending row exists in table for spec step: $($item.id)" ($row.Count -eq 1) "$($item.specFile) $($item.output)"
    Assert "pending output is not already present: $($item.output)" (-not (Test-Path -LiteralPath (Join-Path $root ($item.output -replace '/', '\')) -PathType Leaf)) $item.output
}

$pendingIdsInBody = @([regex]::Matches($markdown, 'Pending capture id:\s+`([^`]+)`\.') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
$pendingIdsInTable = @($pending | ForEach-Object { $_.id } | Sort-Object)
Assert 'every body pending capture id has one pending table row' (($pendingIdsInBody -join "`n") -eq ($pendingIdsInTable -join "`n")) "body=$($pendingIdsInBody -join ', ') table=$($pendingIdsInTable -join ', ')"

Assert 'staged pending capture spec exists' (Test-Path -LiteralPath $SpecPath -PathType Leaf) $SpecPath
$spec = $null
if (Test-Path -LiteralPath $SpecPath -PathType Leaf) {
    $spec = Read-Text $SpecPath | ConvertFrom-Json
    $modulePath = [IO.Path]::GetFullPath((Join-Path $root 'guide\lib\portal-specs.mjs'))
    $check = @"
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const moduleUrl = pathToFileURL(process.argv[2]).href;
const { specProblems } = await import(moduleUrl);
const file = process.argv[3];
const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
const problems = specProblems(doc, file);
if (problems.length) {
  console.error(problems.join('\n'));
  process.exit(1);
}
"@
    $checkPath = Join-Path ([IO.Path]::GetTempPath()) ('p90-spec-check-' + [guid]::NewGuid().ToString('N') + '.mjs')
    Set-Content -LiteralPath $checkPath -Value $check -Encoding UTF8
    try {
        Push-Location $root
        $nodeOutput = & node $checkPath $modulePath $SpecPath 2>&1 | Out-String
        $nodeOk = $LASTEXITCODE -eq 0
    }
    finally {
        Pop-Location
        Remove-Item -LiteralPath $checkPath -Force -ErrorAction SilentlyContinue
    }
    Assert 'staged pending spec passes specProblems()' $nodeOk $nodeOutput
}

$p90Rows = @($pending | Where-Object { $_.specFile -eq 'guide/captures-pending/p90.json' } | ForEach-Object { "$($_.id)|$($_.output)" })
$p90SpecPairs = @()
if ($spec -and $spec.steps) {
    foreach ($step in $spec.steps) { $p90SpecPairs += "$($step.id)|$($step.output)" }
}
Assert 'every p90.json pending step appears in the table' ((@($p90Rows | Sort-Object) -join "`n") -eq (@($p90SpecPairs | Sort-Object) -join "`n")) "table=$($p90Rows -join ', ') spec=$($p90SpecPairs -join ', ')"

$overview = [regex]::Match($markdown, '(?ms)^## Portal and CLI overview\s*(?<table>\| Part \| What it configures .*?\r?\n\|[- |]+\|\s*\r?\n(?<rows>(?:\|.*\|\s*\r?\n)+))')
Assert 'overview table exists' $overview.Success
if ($overview.Success) {
    $parts = @()
    foreach ($line in ($overview.Groups['rows'].Value -split "`r?`n")) {
        if ($line -match '^\|\s*§?(\d+)\b') { $parts += [int]$matches[1] }
        if ($line -match '^\|\s*(\d+)\b') {
            $part = [int]$matches[1]
            Assert "overview portal column links to part $part subsection" ($line -match "\(#part-$part-in-the-portal\)") $line
            if ($part -eq 7) {
                Assert 'overview part 7 states external-idp optionality' (($line -match 'external-idp-browser') -and ($line -match 'external-idp-broker') -and ($line -match 'helper-script')) $line
            }
        }
    }
    $partList = @($parts | Sort-Object) -join ','
    Assert 'overview table has one row per part, 1-12' ($partList -eq '1,2,3,4,5,6,7,8,9,10,11,12') ($parts -join ',')
}

$part7Body = Get-PartBody $markdown 7
$part7Portal = Get-PortalBody $part7Body 7
$part7Code = Get-CodeFenceText $part7Body
$desktopRedirectsBlock = Get-MarkedBlockText $part7Body 'P89-DESKTOP-REDIRECTS'
$commandRedirectUris = @([regex]::Matches($desktopRedirectsBlock, '(?<![A-Za-z0-9+.-])(https?://[^"\s\]]+|msauth\.[^"\s\]]+://[^"\s\]]+)') | ForEach-Object { $_.Groups[1].Value.TrimEnd('"') })
if ($desktopRedirectsBlock -match 'ms-appx-web://Microsoft\.AAD\.BrokerPlugin/" \+ \$clientId') {
    $commandRedirectUris += 'ms-appx-web://Microsoft.AAD.BrokerPlugin/${DESKTOP_CLIENT_ID}'
}
$commandRedirectUris = @($commandRedirectUris | Sort-Object -Unique)
$portalRedirectUris = @([regex]::Matches($part7Portal, '`(https?://[^`\s;,)]+|ms-appx-web://[^`\s;,)]+|msauth\.[^`\s;,)]+://[^`\s;,)]+)`') | ForEach-Object { $_.Groups[1].Value.TrimEnd('.') } | Sort-Object -Unique)
Assert 'part 7 portal redirect URI literals match the bash block' (($portalRedirectUris -join "`n") -eq ($commandRedirectUris -join "`n")) "portal=$($portalRedirectUris -join ', ') command=$($commandRedirectUris -join ', ')"
Assert 'part 7 portal does not use localhost redirect shorthand' (-not ($part7Portal -match 'http://localhost(\b|/)'))
Assert 'part 7 broker redirect URIs are conditional' (($part7Portal -match 'DESKTOP_SIGN_IN_FLOW') -and ($part7Portal -match '\bbroker\b')) 'DESKTOP_SIGN_IN_FLOW broker'

$audienceWrite = [regex]::Match($part7Code, 'az apim nv update[^\r\n]+--named-value-id external-idp-extra-audience[^\r\n]+--value "\$([A-Z][A-Z0-9_]*)"')
$audienceVariable = if ($audienceWrite.Success) { $audienceWrite.Groups[1].Value } else { '' }
Assert 'part 7 bash writes a Desktop audience variable' ($audienceVariable.Length -gt 0)
Assert 'part 7 portal audience variable equals the bash write variable' ($part7Portal -match [regex]::Escape("`$$audienceVariable")) "expected=`$$audienceVariable"
Assert 'part 7 portal does not publish the disabled audience sentinel variable' (-not ($part7Portal -match '\$DESKTOP_EXTRA_AUDIENCE'))

$allCode = Get-CodeFenceText $markdown
$definedVariables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($match in [regex]::Matches($allCode, '(?m)(?:^|[;\s])(?:export\s+)?([A-Z][A-Z0-9_]*)=')) {
    [void]$definedVariables.Add($match.Groups[1].Value)
}
foreach ($match in [regex]::Matches($allCode, '\$\{([A-Z][A-Z0-9_]*):=')) {
    [void]$definedVariables.Add($match.Groups[1].Value)
}
$allowedPendingVariables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$portalUndefined = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
for ($part = 1; $part -le 12; $part++) {
    $portal = Get-PortalBody (Get-PartBody $markdown $part) $part
    foreach ($match in [regex]::Matches($portal, '\$\{?([A-Z][A-Z0-9_]*)\}?')) {
        $name = $match.Groups[1].Value
        if (-not $definedVariables.Contains($name) -and -not $allowedPendingVariables.Contains($name)) {
            [void]$portalUndefined.Add($name)
        }
    }
}
Assert 'every portal variable is defined in a bash block or declared pending' ($portalUndefined.Count -eq 0) ($portalUndefined -join ', ')

if ($script:fail) {
    Write-Host "Azure CLI portal guide contract failed: $script:fail check(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'Azure CLI portal guide contract passed.' -ForegroundColor Green
