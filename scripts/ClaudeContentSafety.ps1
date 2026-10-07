$script:ClaudeContentSafetyTextLimit = 10000
$script:ClaudeContentSafetyDocumentLimit = 10000
$script:ClaudeContentSafetyMaxDocuments = 5
function ConvertTo-ClaudeContentSafetyText {
    param($Value)
    $parts = [Collections.Generic.List[string]]::new()
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { if ($Value.Length -gt 0) { $parts.Add($Value) }; return @($parts) }
    if ($Value -is [array]) { foreach ($item in $Value) { if ($null -ne $item -and [string]$item.type -eq 'text' -and $null -ne $item.text) { $parts.Add([string]$item.text) } } }
    return @($parts)
}
function ConvertTo-ClaudeToolResultText {
    param($Content)
    $parts = [Collections.Generic.List[string]]::new()
    if ($null -eq $Content -or -not ($Content -is [array])) { return @($parts) }
    foreach ($block in $Content) {
        if ([string]$block.type -ne 'tool_result') { continue }
        $toolContent = $block.content
        if ($toolContent -is [string]) { if ($toolContent.Length -gt 0) { $parts.Add($toolContent) }; continue }
        foreach ($text in (ConvertTo-ClaudeContentSafetyText $toolContent)) { $parts.Add($text) }
    }
    return @($parts)
}
function Limit-ClaudeContentSafetyText {
    param([string]$Text, [int]$Limit = $script:ClaudeContentSafetyTextLimit)
    $safe = if ($null -eq $Text) { '' } else { $Text }
    if ($safe.Length -le $Limit) { return [pscustomobject]@{ Text = $safe; Truncated = $false } }
    [pscustomobject]@{ Text = $safe.Substring($safe.Length - $Limit, $Limit); Truncated = $true }
}
function Get-ClaudeContentSafetySlice {
    param([Parameter(Mandatory)][string]$BodyJson)
    $body = $BodyJson | ConvertFrom-Json -Depth 100
    $systemParts = ConvertTo-ClaudeContentSafetyText $body.system
    $messages = @($body.messages)
    $newestUser = $null
    for ($i = $messages.Count - 1; $i -ge 0; $i--) { if ([string]$messages[$i].role -eq 'user') { $newestUser = $messages[$i]; break } }
    $userParts = @(); $toolParts = @(); $fabricatedHistoryLimit = $false
    if ($newestUser) {
        $userParts = ConvertTo-ClaudeContentSafetyText $newestUser.content
        $toolParts = ConvertTo-ClaudeToolResultText $newestUser.content
        foreach ($message in $messages) { if ($message -eq $newestUser) { break }; if ([string]$message.role -eq 'user') { $fabricatedHistoryLimit = $true; break } }
    }
    $systemText = ($systemParts -join "`n"); $userText = ($userParts -join "`n"); $toolText = ($toolParts -join "`n")
    $userLimited = Limit-ClaudeContentSafetyText $userText
    $harmText = (@($systemText, $userText, $toolText) | Where-Object { $_ -ne '' }) -join "`n"
    $harmLimited = Limit-ClaudeContentSafetyText $harmText
    $documents = [Collections.Generic.List[string]]::new(); $documentChars = 0
    foreach ($part in $toolParts) {
        if ($documents.Count -ge $script:ClaudeContentSafetyMaxDocuments -or $documentChars -ge $script:ClaudeContentSafetyDocumentLimit) { break }
        $remaining = $script:ClaudeContentSafetyDocumentLimit - $documentChars
        $limited = Limit-ClaudeContentSafetyText ([string]$part) $remaining
        if ($limited.Text.Length -gt 0) { $documents.Add($limited.Text); $documentChars += $limited.Text.Length }
    }
    $truncated = $userLimited.Truncated -or $harmLimited.Truncated -or (($toolText.Length -gt $script:ClaudeContentSafetyDocumentLimit) -or ($toolParts.Count -gt $script:ClaudeContentSafetyMaxDocuments))
    [pscustomobject]@{ SystemText=$systemText; UserPrompt=$userLimited.Text; Documents=@($documents); AnalyzeText=$harmLimited.Text; Truncated=[bool]$truncated; TruncateMode='newest'; EmptyTextSlice=[string]::IsNullOrEmpty($harmLimited.Text); FabricatedHistoryLimit=$fabricatedHistoryLimit }
}
function Test-ClaudeTextHarm { param([string]$Text) if ([string]::IsNullOrEmpty($Text)) { return $false }; return $Text -match '(?i)harmful|violence|self[- ]?harm|sexual|hate' }
function Test-ClaudePromptAttack { param([string]$Text) if ([string]::IsNullOrEmpty($Text)) { return $false }; return $Text -match '(?i)ignore previous instructions|jailbreak|reveal secrets|bypass safety' }
function New-ClaudeContentSafetyErrorBody { param([string]$Message) [pscustomobject]@{ type='error'; error=[pscustomobject]@{ type='content_safety'; message=$Message } } }
function New-ClaudeContentSafetyFailureResult {
    param([string]$Mode, $Calls, $Slice, $Trace, [string]$Hash)
    $Trace.decision = 'unavailable'
    if ($Mode -eq 'audit') { return [pscustomobject]@{ StatusCode=200; Headers=@{}; Error=$null; ResponseBody=$null; Calls=@($Calls); Slice=$Slice; Trace=[pscustomobject]$Trace; Forwarded=$true; StreamRequested=$false; BodyAvailableForFoundry=$true; OriginalBodyHash=$Hash; ForwardBodyHash=$Hash; Decision=[pscustomobject]@{ WouldBlock=$false; BlockedBy='' } } }
    $err = New-ClaudeContentSafetyErrorBody 'Content Safety unavailable'
    [pscustomobject]@{ StatusCode=503; Headers=@{ 'Content-Type'='application/json'; 'Retry-After'='5' }; Error=$err; ResponseBody=$err; Calls=@($Calls); Slice=$Slice; Trace=[pscustomobject]$Trace; Forwarded=$false; StreamRequested=$false; BodyAvailableForFoundry=$true; OriginalBodyHash=$Hash; ForwardBodyHash=$Hash; Decision=[pscustomobject]@{ WouldBlock=$false; BlockedBy='unavailable' } }
}
function Invoke-ClaudeContentSafetyOffline {
    param([Parameter(Mandatory)][string]$BodyJson,[ValidateSet('off','audit','block')][string]$Mode='block',[int]$Threshold=2,[string]$SimulateFailure='')
    $slice = Get-ClaudeContentSafetySlice -BodyJson $BodyJson
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($BodyJson)))
    $calls = [Collections.Generic.List[object]]::new()
    $trace = [ordered]@{ mode=$Mode; decision='pass'; blockedBy=''; threshold=$Threshold; truncated=[bool]$slice.Truncated; truncateMode=$slice.TruncateMode; fabricatedHistoryLimit=[bool]$slice.FabricatedHistoryLimit; emptyTextSlice=[bool]$slice.EmptyTextSlice; promptShieldUserAttackDetected=$false; promptShieldDocumentAttackDetected=$false; hateSeverity=0; violenceSeverity=0; selfHarmSeverity=0; sexualSeverity=0; contentSafetyStatusCode=0; contentSafetyElapsedMs=1; contentSafetyErrorClass='' }
    $stream = (($BodyJson | ConvertFrom-Json -Depth 100).stream -eq $true)
    if ($Mode -eq 'off') { return [pscustomobject]@{ StatusCode=200; Headers=@{}; Error=$null; ResponseBody=$null; Calls=@(); Slice=$slice; Trace=[pscustomobject]$trace; Forwarded=$true; StreamRequested=$stream; BodyAvailableForFoundry=$true; OriginalBodyHash=$hash; ForwardBodyHash=$hash; Decision=[pscustomobject]@{ WouldBlock=$false; BlockedBy='' } } }
    $shieldBody = [pscustomobject]@{ userPrompt=$slice.UserPrompt; documents=@($slice.Documents) }
    $calls.Add([pscustomobject]@{ Operation='shieldPrompt'; Body=$shieldBody })
    if ($SimulateFailure -match '^shieldPrompt') { $trace.contentSafetyErrorClass = if ($SimulateFailure -match 'malformed') { 'malformed' } else { 'timeout' }; return New-ClaudeContentSafetyFailureResult $Mode $calls $slice $trace $hash }
    $userAttack = Test-ClaudePromptAttack $slice.UserPrompt; $docAttack = @($slice.Documents | Where-Object { Test-ClaudePromptAttack $_ }).Count -gt 0
    $trace.promptShieldUserAttackDetected = $userAttack; $trace.promptShieldDocumentAttackDetected = $docAttack
    $analyzeBody = [pscustomobject]@{ text=$slice.AnalyzeText; categories=@('Hate','Violence','SelfHarm','Sexual'); outputType='FourSeverityLevels' }
    $calls.Add([pscustomobject]@{ Operation='analyze'; Body=$analyzeBody })
    if ($SimulateFailure -match '^analyze') { $trace.contentSafetyStatusCode=502; $trace.contentSafetyErrorClass= if ($SimulateFailure -match 'malformed') { 'malformed' } else { 'service_error' }; return New-ClaudeContentSafetyFailureResult $Mode $calls $slice $trace $hash }
    $harm = Test-ClaudeTextHarm $slice.AnalyzeText; if ($harm) { $trace.violenceSeverity = 2 }
    $blockedBy = ''; if ($userAttack) { $blockedBy='prompt_shield_user' } elseif ($docAttack) { $blockedBy='prompt_shield_document' } elseif ($harm -and $Threshold -le 2) { $blockedBy='severity' }
    if ($blockedBy) { $trace.decision = if ($Mode -eq 'audit') { 'audit' } else { 'block' }; $trace.blockedBy = $blockedBy }
    $wouldBlock = [bool]$blockedBy
    if ($wouldBlock -and $Mode -eq 'block') { $message = if ($blockedBy -match 'prompt_shield') { 'Prompt Shield detected an attack' } else { 'Content Safety severity threshold exceeded' }; $err = New-ClaudeContentSafetyErrorBody $message; return [pscustomobject]@{ StatusCode=403; Headers=@{ 'Content-Type'='application/json' }; Error=$err; ResponseBody=$err; Calls=@($calls); Slice=$slice; Trace=[pscustomobject]$trace; Forwarded=$false; StreamRequested=$stream; BodyAvailableForFoundry=$true; OriginalBodyHash=$hash; ForwardBodyHash=$hash; Decision=[pscustomobject]@{ WouldBlock=$true; BlockedBy=$blockedBy } } }
    [pscustomobject]@{ StatusCode=200; Headers=@{}; Error=$null; ResponseBody=$null; Calls=@($calls); Slice=$slice; Trace=[pscustomobject]$trace; Forwarded=$true; StreamRequested=$stream; BodyAvailableForFoundry=$true; OriginalBodyHash=$hash; ForwardBodyHash=$hash; Decision=[pscustomobject]@{ WouldBlock=$wouldBlock; BlockedBy=$blockedBy } }
}
function ConvertTo-ClaudeAzureLocationName { param([string]$Location) ($Location -replace '\s','').ToLowerInvariant() }
function Test-ClaudeContentSafetyRegion { param([Parameter(Mandatory)][string]$Location) $supported=@('eastus','eastus2','westus','westus3','swedencentral','uksouth','francecentral','germanywestcentral','japaneast','australiaeast','canadacentral','northeurope','westeurope'); $arm=ConvertTo-ClaudeAzureLocationName $Location; if ($supported -contains $arm) { return [pscustomobject]@{ Result='PASS'; Location=$arm; Remedy='' } }; [pscustomobject]@{ Result='FAIL'; Location=$arm; Remedy='Choose a region listed for Azure AI Content Safety Content harms and Prompt Shields in Microsoft Learn region availability, read 2026-10-06.' } }
