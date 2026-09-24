param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackDiscovery.ps1')
$checks=0;$fail=0
function Assert($Name,$Condition){$script:checks++;if(-not $Condition){$script:fail++;Write-Host "FAIL: $Name"}}
function Refuses($Name,[scriptblock]$Action,$Pattern){
    $caught=$false;try{& $Action|Out-Null}catch{$caught=$_.Exception.Message -match $Pattern};Assert $Name $caught
}
$choices=@([pscustomobject]@{Name='first';Id='one'},[pscustomobject]@{Name='second';Id='two'})
$pick=Select-ClaudeReportOption -Prompt 'Resource' -Options $choices -DefaultId two -ReadSelection {param($prompt,$default) ''}
Assert 'blank numbered choice uses the actual configured default' ($pick.Id -eq 'two')
$pick=Select-ClaudeReportOption -Prompt 'Resource' -Options $choices -ReadSelection {param($prompt,$default) '2'}
Assert 'numbered choice selects a discovered resource' ($pick.Id -eq 'two')
$pick=Select-ClaudeReportOption -Prompt 'Resource' -Options $choices -SelectedId one -NonInteractive
Assert 'explicit choice is noninteractive' ($pick.Id -eq 'one')
Refuses 'unknown explicit choice is refused' {Select-ClaudeReportOption -Prompt Resource -Options $choices -SelectedId absent -NonInteractive} 'not found'
Refuses 'ambiguity is not silently first in automation' {Select-ClaudeReportOption -Prompt Resource -Options $choices -NonInteractive} 'ambiguous'
Refuses 'empty discovery is distinct from a default' {Select-ClaudeReportOption -Prompt Resource -Options @() -NonInteractive} 'No'
Assert 'single discovered choice is safe in automation' ((Select-ClaudeReportOption -Prompt Resource -Options @($choices[0]) -NonInteractive).Id -eq 'one')
Refuses 'out of range selection is not accepted' {Select-ClaudeReportOption -Prompt Resource -Options $choices -ReadSelection {param($p,$d) '99'}} 'range'
Refuses 'shell text is not a selection' {Select-ClaudeReportOption -Prompt Resource -Options $choices -ReadSelection {param($p,$d) '1; echo x'}} 'number'
$network=Get-ClaudeReportNetworkPlan -VirtualNetworkPrefix '10.42.8.0/24' -JobsSubnetPrefix '10.42.8.0/26' -EndpointSubnetPrefix '10.42.8.64/27'
Assert 'explicit private address plan is preserved' ($network.VirtualNetworkPrefix -eq '10.42.8.0/24')
Refuses 'overlapping job and endpoint ranges refused' {Get-ClaudeReportNetworkPlan -VirtualNetworkPrefix '10.42.8.0/24' -JobsSubnetPrefix '10.42.8.0/26' -EndpointSubnetPrefix '10.42.8.32/27'} 'overlap'
Refuses 'subnet outside its VNet refused' {Get-ClaudeReportNetworkPlan -VirtualNetworkPrefix '10.42.8.0/24' -JobsSubnetPrefix '10.42.9.0/26' -EndpointSubnetPrefix '10.42.8.64/27'} 'inside'
Refuses 'public address space refused' {Get-ClaudeReportNetworkPlan -VirtualNetworkPrefix '8.8.8.0/24' -JobsSubnetPrefix '8.8.8.0/26' -EndpointSubnetPrefix '8.8.8.64/27'} 'private'
Refuses 'too-small Container Apps subnet refused' {Get-ClaudeReportNetworkPlan -VirtualNetworkPrefix '10.42.8.0/24' -JobsSubnetPrefix '10.42.8.0/28' -EndpointSubnetPrefix '10.42.8.64/27'} '/27'
Refuses 'network addresses must be aligned' {Get-ClaudeReportNetworkPlan -VirtualNetworkPrefix '10.42.8.1/24' -JobsSubnetPrefix '10.42.8.0/26' -EndpointSubnetPrefix '10.42.8.64/27'} 'aligned'
$infra=Get-Content (Join-Path $SourceRoot 'infra\chargeback-reports.bicep') -Raw
Assert 'VNet prefix is a deployment parameter, not a literal subnet' ($infra -match 'addressPrefixes: \[virtualNetworkPrefix\]')
Assert 'jobs subnet is selectable by parameter' ($infra -match 'addressPrefix: jobsSubnetPrefix')
Assert 'endpoint subnet is selectable by parameter' ($infra -match 'addressPrefix: endpointSubnetPrefix')
if($fail){throw "$fail of $checks discovery assertions failed."}
Write-Host "$checks chargeback discovery assertions passed."
