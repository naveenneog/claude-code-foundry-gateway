param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
. (Join-Path $root 'scripts\ClaudeContentSafety.ps1')
$script:assertions = 0
$script:failures = 0
function Assert-Harness($Name,$Condition,$Detail='') { $script:assertions++; if($Condition){ Write-Host "  [OK] $Name" } else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" } }
function ConvertTo-Hash($Object) { $Object | ConvertTo-Json -Depth 30 -Compress }
function New-StubResponse([int]$StatusCode, $Body) { [pscustomobject]@{ StatusCode=$StatusCode; Body=$Body } }
function Invoke-ContentSafetyFragmentHarness {
    param([Parameter(Mandatory)][string]$BodyJson,[string]$Mode='block',[int]$Threshold=2,[string]$SimulateFailure='')
    $fragment = Get-Content (Join-Path $root 'infra\content-safety-screening.xml') -Raw
    $decoded = [System.Net.WebUtility]::HtmlDecode($fragment)
    $calls = [Collections.Generic.List[object]]::new()
    $trace = [ordered]@{ mode=$Mode; decision='pass'; blockedBy=''; threshold=$Threshold; truncated=$false; promptShieldUserAttackDetected=$false; promptShieldDocumentAttackDetected=$false; hateSeverity=0; violenceSeverity=0; selfHarmSeverity=0; sexualSeverity=0; contentSafetyElapsedMs=1; contentSafetyErrorClass=''; truncateMode='newest'; emptyTextSlice=$false; fabricatedHistoryLimit=$false }
    if ($Mode -eq 'off') { return [pscustomobject]@{ StatusCode=200; Calls=@(); Trace=[pscustomobject]$trace; Slice=[pscustomobject]@{UserPrompt='';Documents=@();AnalyzeText=''}; Decision=[pscustomobject]@{BlockedBy='';WouldBlock=$false}; Forwarded=$true; Error=$null; ResponseBody=$null } }
    # RED detector: execute the shipped artifact's stub exactly as written, rather than the model.
    if ($decoded -match 'var newestUserSlice = "";' -and $decoded -match 'var sysSlice = "";' -and $decoded -match 'var toolSlice = "";') {
        $slice = [pscustomobject]@{ UserPrompt=''; Documents=@(''); AnalyzeText=''; Truncated=$false; EmptyTextSlice=$true; FabricatedHistoryLimit=$false }
    } else {
        $model = Get-ClaudeContentSafetySlice -BodyJson $BodyJson
        $slice = [pscustomobject]@{ UserPrompt=$model.UserPrompt; Documents=@($model.Documents); AnalyzeText=$model.AnalyzeText; Truncated=$model.Truncated; EmptyTextSlice=$model.EmptyTextSlice; FabricatedHistoryLimit=$model.FabricatedHistoryLimit }
    }
    $trace.truncated = [bool]$slice.Truncated; $trace.emptyTextSlice=[bool]$slice.EmptyTextSlice; $trace.fabricatedHistoryLimit=[bool]$slice.FabricatedHistoryLimit
    if ($slice.EmptyTextSlice) { return [pscustomobject]@{ StatusCode=200; Calls=@(); Trace=[pscustomobject]$trace; Slice=$slice; Decision=[pscustomobject]@{BlockedBy='';WouldBlock=$false}; Forwarded=$true; Error=$null; ResponseBody=$null } }
    $calls.Add([pscustomobject]@{ Operation='shieldPrompt'; Body=[pscustomobject]@{ userPrompt=$slice.UserPrompt; documents=@($slice.Documents) } })
    if ($SimulateFailure -match '^shield') { $trace.decision='unavailable'; $trace.contentSafetyErrorClass='timeout'; return [pscustomobject]@{ StatusCode=$(if($Mode -eq 'block'){503}else{200}); Calls=@($calls); Trace=[pscustomobject]$trace; Slice=$slice; Decision=[pscustomobject]@{BlockedBy='unavailable';WouldBlock=$false}; Forwarded=($Mode -eq 'audit'); Error=[pscustomobject]@{error=[pscustomobject]@{type='content_safety'}}; ResponseBody='content safety unavailable' } }
    $userAttack = Test-ClaudePromptAttack $slice.UserPrompt
    $docAttack = @($slice.Documents | Where-Object { Test-ClaudePromptAttack $_ }).Count -gt 0
    $trace.promptShieldUserAttackDetected=$userAttack; $trace.promptShieldDocumentAttackDetected=$docAttack
    $calls.Add([pscustomobject]@{ Operation='analyze'; Body=[pscustomobject]@{ text=$slice.AnalyzeText; categories=@('Hate','Violence','SelfHarm','Sexual'); outputType='FourSeverityLevels' } })
    if ($SimulateFailure -match '^analyze') { $trace.decision='unavailable'; $trace.contentSafetyErrorClass=$(if($SimulateFailure -match 'malformed'){'malformed'}else{'service_error'}); return [pscustomobject]@{ StatusCode=$(if($Mode -eq 'block'){503}else{200}); Calls=@($calls); Trace=[pscustomobject]$trace; Slice=$slice; Decision=[pscustomobject]@{BlockedBy='unavailable';WouldBlock=$false}; Forwarded=($Mode -eq 'audit'); Error=[pscustomobject]@{error=[pscustomobject]@{type='content_safety'}}; ResponseBody='content safety unavailable' } }
    $harm = Test-ClaudeTextHarm $slice.AnalyzeText; if($harm){ $trace.violenceSeverity=2 }
    $blockedBy=''; if($userAttack){$blockedBy='prompt_shield_user'} elseif($docAttack){$blockedBy='prompt_shield_document'} elseif($harm -and $Threshold -le 2){$blockedBy='severity'}
    if($blockedBy){ $trace.decision=$(if($Mode -eq 'audit'){'audit'}else{'block'}); $trace.blockedBy=$blockedBy }
    $wouldBlock=[bool]$blockedBy
    if($Mode -eq 'block' -and $wouldBlock){ return [pscustomobject]@{ StatusCode=403; Calls=@($calls); Trace=[pscustomobject]$trace; Slice=$slice; Decision=[pscustomobject]@{BlockedBy=$blockedBy;WouldBlock=$true}; Forwarded=$false; Error=[pscustomobject]@{error=[pscustomobject]@{type='content_safety'; message='Content Safety severity threshold exceeded'}}; ResponseBody='content safety blocked' } }
    [pscustomobject]@{ StatusCode=200; Calls=@($calls); Trace=[pscustomobject]$trace; Slice=$slice; Decision=[pscustomobject]@{BlockedBy=$blockedBy;WouldBlock=$wouldBlock}; Forwarded=$true; Error=$null; ResponseBody=$null }
}
