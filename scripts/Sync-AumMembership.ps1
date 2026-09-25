<#
.SYNOPSIS
    Refreshes selected business-unit memberships with the signed-in administrator's delegated Graph access.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ResourceGroup,[Parameter(Mandatory)][string]$ApimName,
      [Parameter(Mandatory)][string[]]$ScopeIds,[switch]$Apply,[switch]$AllowReassignment)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeBusinessUnit.ps1')
. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')
. (Join-Path $PSScriptRoot 'ClaudeAumMembership.ps1')
. (Join-Path $PSScriptRoot 'ClaudeAumDirectWrites.ps1')
$before=Get-AumNamedValueMap -ResourceGroup $ResourceGroup -ApimName $ApimName
if($before['turnstile-integration'] -match '(?:governanceAuthority|budgetAuthority)=Turnstile'){
    throw 'Turnstile owns membership publication. Save its catalog and follow its apply job instead.'
}
if($before['entitlement-source'] -eq 'projection'){
    throw 'This gateway uses the projection authority. Refresh its projection pipeline instead of writing an inactive bu-members map.'
}
foreach($name in 'bu-registry','bu-parents','bu-members'){
    if(-not $before.ContainsKey($name)){throw "Required named value '$name' is missing; no refresh performed."}
}
$registry=@(ConvertFrom-ClaudeBuRegistry $before['bu-registry'])
$parents=ConvertFrom-ClaudeBuParents $before['bu-parents']
$current=ConvertFrom-ClaudeBuMembers $before['bu-members']
$members=@{}
$graphToken=Get-GraphToken
try {
    foreach($id in $ScopeIds){
        $scope=@($registry|Where-Object Id -eq $id)
        if($scope.Count -ne 1){throw 'Choose one existing scope id.'}
        $group=az ad group show --group $scope[0].Group --query id -o tsv
        if($LASTEXITCODE -ne 0 -or -not $group){throw 'Selected group lookup failed. No membership was written.'}
        $members[$id]=@((Get-GroupMemberOids -GroupName $scope[0].Group -Token $graphToken).Oid)
    }
} finally {$graphToken=$null}
$plan=New-AumMembershipPlan -Registry $registry -Parents $parents -Current $current -ScopeIds $ScopeIds -Members $members
$result=@{preview=(-not $Apply);action='Refresh selected memberships';scopes=$ScopeIds;
          before=$before['bu-members'];after=$plan.Value;reassigned=$plan.Reassigned;
          effect='Only selected scopes are resolved. Unrelated mappings and tier entitlement are preserved. Gateway propagation may lag.'}
if($Apply){
    if($plan.Reassigned.Count -and -not $AllowReassignment){throw 'This refresh reassigns an existing member. Preview and explicitly allow reassignment.'}
    $after=[ordered]@{'bu-registry'=$before['bu-registry'];'bu-parents'=$before['bu-parents'];'bu-members'=$plan.Value}
    $result.result=Invoke-AumVerifiedWrite -Before $before -After $after `
        -Read {Get-AumNamedValueMap -ResourceGroup $ResourceGroup -ApimName $ApimName} `
        -Write {param($key,$value) Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $key -Value $value} `
        -Remove {throw 'A pre-existing membership value must not be removed.'} `
        -Operation {Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'bu-members' -Value $plan.Value}
}
$result | ConvertTo-Json -Depth 20 -Compress
