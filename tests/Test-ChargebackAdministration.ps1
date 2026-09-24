param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Configuration','Administration')) {. (Join-Path $SourceRoot "scripts\ClaudeChargeback$helper.ps1")}
$fail=0;$checks=0
function Assert($Name,$Condition){$script:checks++;if(-not $Condition){$script:fail++;Write-Host "FAIL: $Name"}}
function Refuses($Name,[scriptblock]$Action){$caught=$false;try{& $Action|Out-Null}catch{$caught=$true};Assert $Name $caught}
$script:stored=$null;$script:writes=0
function Get-ClaudeReportConfiguration {param($Account,[switch]$AllowMissing) $script:stored}
function Save-ClaudeReportConfiguration {
    param($Account,$Configuration,$ETag)
    if($script:stored) {Assert 'admin write uses latest ETag' ($ETag -eq '"v1"')}
    $script:writes++;$script:stored=[pscustomobject]@{Configuration=$Configuration;ETag='"v1"'}
}
$c=New-ClaudeChargebackConfiguration @('contoso.com')
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Initialize';Configuration=$c})
Assert 'private bootstrap initializes once' ($r.Status -eq 'Initialized' -and $script:writes -eq 1)
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Initialize';Configuration=$c})
Assert 'repeat bootstrap preserves current config' ($r.Status -eq 'Unchanged' -and $script:writes -eq 1)
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Recipients';Scope='engineering';Add=@('alice@contoso.com')})
Assert 'private operation adds validated recipient' ($script:stored.Configuration.Units.engineering[0] -eq 'alice@contoso.com')
Assert 'success response contains no addresses' (($r|ConvertTo-Json) -notmatch '@contoso')
$before=$script:writes
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Recipients';Scope='engineering';Add=@('alice@contoso.com')})
Assert 'repeat private add does not write a new config version' ($r.Status -eq 'Unchanged' -and $script:writes -eq $before)
Refuses 'private administration still enforces domain' {Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Recipients';Scope='engineering';Add=@('alice@evil.com')})}
Refuses 'no arbitrary script execution operation' {Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Execute';Script='Write-Host unsafe'})}
Refuses 'connection not writable via settings request' {Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Settings';Settings=[pscustomobject]@{Connection=@{Endpoint='elsewhere'}}})}
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Settings';Settings=[pscustomobject]@{MonthToDate=$true;BusinessUnits=@('engineering')}})
Assert 'private settings applied without resource redeployment' ($script:stored.Configuration.MonthToDate -and $script:stored.Configuration.BusinessUnits[0] -eq 'engineering')
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Inspect'})
Assert 'off-network inspect only logs recipient counts' (($r|ConvertTo-Json -Depth 10) -notmatch 'alice@' -and @($r.Recipients | Where-Object Scope -eq engineering)[0].Count -eq 1)
$template=[pscustomobject]@{volumes=@();initContainers=@();containers=@([pscustomobject]@{name='reports';image='fixture';imageType='ContainerImage';command=@('/bin/bash','-c','fixed');resources=@{cpu=1;memory='2Gi'};env=@([pscustomobject]@{name='REPO_REF';value=('a'*40)})})}
$execution=New-ClaudeReportExecutionTemplate $template 'REPORT_ADMIN_REQUEST' 'fixture'
Assert 'execution override omits unsupported volumes' (-not $execution.Contains('volumes'))
Assert 'execution override omits management-only imageType' (-not $execution.containers[0].Contains('imageType'))
Assert 'execution preserves pinned code and fixed command' ($execution.containers[0].command[2] -eq 'fixed' -and @($execution.containers[0].env | Where-Object name -eq 'REPO_REF')[0].value -eq ('a'*40))
Assert 'execution adds one structured payload' (@($execution.containers[0].env | Where-Object name -eq 'REPORT_ADMIN_REQUEST').Count -eq 1)
$request=ConvertFrom-ClaudeReportAdminPayload -Json '{"Operation":"Inspect"}'
Assert 'portal may supply readable JSON, without a Base64 tool' ($request.Operation -eq 'Inspect')
$request=ConvertFrom-ClaudeReportAdminPayload -Encoded ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"Operation":"Inspect"}')))
Assert 'existing encoded execution payload remains supported' ($request.Operation -eq 'Inspect')
Refuses 'ambiguous portal and CLI payloads are refused' {ConvertFrom-ClaudeReportAdminPayload -Json '{"Operation":"Inspect"}' -Encoded 'e30='}
$template.containers[0].env+=@([pscustomobject]@{name='REPORT_ADMIN_JSON';value='{"Operation":"Inspect"}'})
$execution=New-ClaudeReportExecutionTemplate $template 'REPORT_ADMIN_REQUEST' 'fixture'
Assert 'CLI override removes a persisted portal request' (@($execution.containers[0].env|Where-Object name -eq REPORT_ADMIN_JSON).Count -eq 0)
if($fail){throw "$fail of $checks administration assertions failed."}
Write-Host "$checks chargeback administration assertions passed."
