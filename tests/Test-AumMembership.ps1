$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\scripts\ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot '..\scripts\ClaudeAumMembership.ps1')
$registry=@(
    [pscustomobject]@{Id='sales';Group='contoso-sales';TokensPerMonth=1000},
    [pscustomobject]@{Id='sales-emea';Group='contoso-team';TokensPerMonth=500},
    [pscustomobject]@{Id='engineering';Group='contoso-engineering';TokensPerMonth=1000}
)
$oid='00000000-0000-0000-0000-000000000001'
$other='00000000-0000-0000-0000-000000000002'
$current=[ordered]@{};$current[$oid]='engineering';$current[$other]='engineering'
$members=@{};$members['sales']=@($oid);$members['sales-emea']=@($oid)
$plan=New-AumMembershipPlan -Registry $registry -Parents @{ 'sales-emea'='sales' } -Current $current `
    -ScopeIds @('sales','sales-emea') -Members $members
if($plan.Map[$oid] -ne 'sales-emea'){throw 'Most specific selected team must win.'}
if($plan.Map[$other] -ne 'engineering'){throw 'An unrelated mapping must survive.'}
if(@($plan.Reassigned).Count -ne 1){throw 'Existing assignment changes require an explicit preview.'}
if((ConvertFrom-ClaudeBuMembers $plan.Value)[$other] -ne 'engineering'){throw 'Use the shared serializer.'}
$bad=$false
try { New-AumMembershipPlan -Registry $registry -Parents @{} -Current $current -ScopeIds @('missing') -Members @{} } catch {$bad=$true}
if(-not $bad){throw 'Unknown scopes must not be mapped.'}
Write-Host '5 AUM membership assertions passed.'
