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
Refuses 'private administration still enforces domain' {Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Recipients';Scope='engineering';Add=@('alice@evil.com')})}
Refuses 'no arbitrary script execution operation' {Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Execute';Script='Write-Host unsafe'})}
Refuses 'connection not writable via settings request' {Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Settings';Settings=[pscustomobject]@{Connection=@{Endpoint='elsewhere'}}})}
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Settings';Settings=[pscustomobject]@{MonthToDate=$true;BusinessUnits=@('engineering')}})
Assert 'private settings applied without resource redeployment' ($script:stored.Configuration.MonthToDate -and $script:stored.Configuration.BusinessUnits[0] -eq 'engineering')
$r=Invoke-ClaudeReportAdministration contoso ([pscustomobject]@{Operation='Inspect'})
Assert 'off-network inspect only logs recipient counts' (($r|ConvertTo-Json -Depth 10) -notmatch 'alice@' -and @($r.Recipients | Where-Object Scope -eq engineering)[0].Count -eq 1)
if($fail){throw "$fail of $checks administration assertions failed."}
Write-Host "$checks chargeback administration assertions passed."
