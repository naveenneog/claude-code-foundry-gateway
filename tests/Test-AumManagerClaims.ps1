param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$helper=Join-Path $root 'scripts\ClaudeAumJourneyClaims.ps1'
if (-not (Test-Path $helper)) { throw 'Manager journey must independently check expected claims before server scope proof.' }
. $helper
$tokens=$null;$parseErrors=$null
$journey=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\Test-ClaudeAumManagerJourney.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Manager journey does not parse.'}
$topLevel=@($journey.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object Name)
foreach($required in @('Get-JourneyGraphRows','Get-AssignmentTuples','Get-ManagerJourneyToken')){
    if($required -notin $topLevel){throw "$required must be available before any journey call, not nested in a conditional helper."}
}
$client='00000000-0000-0000-0000-000000000001'
$tenant='00000000-0000-0000-0000-000000000002'
$person='00000000-0000-0000-0000-000000000003'
$group='00000000-0000-0000-0000-000000000004'
$claims=@{aud=$client;tid=$tenant;oid=$person;roles=@('AUM.Manager');groups=@($group);scp='AUM.Access';exp=[datetimeoffset]::UtcNow.ToUnixTimeSeconds()+1800}
$args=@{Claims=$claims;ClientId=$client;TenantId=$tenant;PersonId=$person;ExpectedRole='manager';RequiredGroups=@($group)}
Assert-ClaudeAumJourneyClaims @args
foreach ($bad in @(
    @{roles=@('AUM.Admin','AUM.Manager')},
    @{roles=@('AUM.Viewer','AUM.Manager')},
    @{groups=@()},
    @{hasgroups=$true},
    @{aud=$tenant},
    @{oid=$tenant},
    @{scp='other'},
    @{exp=1}
)) {
    $changed=@{};foreach($key in $claims.Keys){$changed[$key]=$claims[$key]}
    foreach($key in $bad.Keys){$changed[$key]=$bad[$key]}
    $call=@{};foreach($key in $args.Keys){$call[$key]=$args[$key]};$call.Claims=$changed
    $rejected=$false;try{Assert-ClaudeAumJourneyClaims @call}catch{$rejected=$true}
    if(-not $rejected){throw 'A stale, wider or wrong-identity claim set was accepted.'}
}
$rejected=$false
try{Assert-ClaudeAumJourneyClaims @args -ForbiddenGroups @($group)}catch{$rejected=$true}
if(-not $rejected){throw 'A forbidden manager group was accepted.'}
$encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims|ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
$decoded=ConvertFrom-ClaudeAumJourneyToken "fixture.$encoded.not-a-signature"
if($decoded.oid -ne $person){throw 'Claim decoding changed the caller.'}
Write-Host 'AUM journey claim guards: identity, role precedence, scope, overage and lifetime passed. Server still verifies signature.' -ForegroundColor Green
