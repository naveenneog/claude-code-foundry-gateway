<#
.SYNOPSIS
    Exercises mutable report configuration in Azure, restores the exact original settings.
.DESCRIPTION
    Run on a VNet-connected terminal or as an explicit manual administration-job execution.
    No email is sent. Recipient must be the one approved by the operator. Concurrent edits
    cause refusal rather than a restore that overwrites another administrator's work.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$StorageAccount,[Parameter(Mandatory)][string]$Recipient,[switch]$Apply)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($helper in @('Report','Query','Configuration','Storage')) {. (Join-Path $root "scripts\ClaudeChargeback$helper.ps1")}
if(-not $Apply -or -not $PSCmdlet.ShouldProcess($StorageAccount,'Exercise and restore private reporting configuration (no email)')){return}
function Normalize($Value) {
    if($null -eq $Value){return $null}
    if($Value -is [Collections.IDictionary]){
        $o=[ordered]@{};foreach($key in @($Value.Keys|Sort-Object)){if($key -ne 'UpdatedUtc'){$o[$key]=Normalize $Value[$key]}};return $o
    }
    if($Value -is [pscustomobject]){
        $o=[ordered]@{};foreach($p in @($Value.PSObject.Properties|Sort-Object Name)){if($p.Name -ne 'UpdatedUtc'){$o[$p.Name]=Normalize $p.Value}};return $o
    }
    if($Value -is [array]){return ,@($Value|ForEach-Object {Normalize $_})}
    return $Value
}
function Fingerprint($Value){return (Normalize $Value)|ConvertTo-Json -Depth 30 -Compress}
$original=(Get-ClaudeReportConfiguration $StorageAccount).Configuration
ConvertTo-ClaudeReportRecipient $Recipient $original.AllowedDomains | Out-Null
$script:expected=ConvertTo-ClaudeChargebackConfiguration $original
$results=New-Object 'System.Collections.Generic.List[string]'
function Save-Probe($Config,[string]$Label) {
    $current=Get-ClaudeReportConfiguration $StorageAccount
    if((Fingerprint $current.Configuration) -cne (Fingerprint $script:expected)){throw 'A concurrent administrator changed settings. Probe stopped without overwriting it.'}
    Save-ClaudeReportConfiguration $StorageAccount $Config $current.ETag
    $script:expected=ConvertTo-ClaudeChargebackConfiguration $Config
    $read=(Get-ClaudeReportConfiguration $StorageAccount).Configuration
    if((Fingerprint $read) -cne (Fingerprint $script:expected)){throw 'Live configuration readback did not match the requested state.'}
    $results.Add($Label)
}
$scope='verify-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$started=[datetime]::UtcNow
try {
    $c=ConvertTo-ClaudeChargebackConfiguration $script:expected;$c.DeliveryEnabled=$false
    Save-Probe $c 'disable delivery'
    $c=Update-ClaudeChargebackRecipients $script:expected $scope @($Recipient) @()
    Save-Probe $c 'add approved recipient'
    $again=Update-ClaudeChargebackRecipients $script:expected $scope @($Recipient) @()
    if((Fingerprint $again) -cne (Fingerprint $script:expected)){throw 'Duplicate add changed recipient state.'}
    $results.Add('duplicate add is idempotent')
    $addresses=Get-ClaudeChargebackRecipients (Get-ClaudeReportConfiguration $StorageAccount).Configuration $scope
    if($addresses.Count -ne 1 -or $addresses[0] -ne $Recipient.ToLowerInvariant()){throw 'Live list did not return the approved recipient.'}
    $results.Add('list recipients')
    $c=Update-ClaudeChargebackRecipients $script:expected $scope @() @($Recipient)
    Save-Probe $c 'remove recipient'
    $again=Update-ClaudeChargebackRecipients $script:expected $scope @() @($Recipient)
    if((Fingerprint $again) -cne (Fingerprint $script:expected)){throw 'Repeated removal changed recipient state.'}
    $results.Add('duplicate removal is idempotent')
    $refused=$false
    try{Update-ClaudeChargebackRecipients $script:expected $scope @('do-not-send@example.invalid') @()|Out-Null}catch{$refused=$_.Exception.Message -match 'domain'}
    if(-not $refused){throw 'External domain was not refused.'}
    $results.Add('external domain refused without a write')
    foreach($format in @('CSV','HTML')){
        $c=ConvertTo-ClaudeChargebackConfiguration $script:expected;$c.Formats=@($format)
        Save-Probe $c "format $format"
    }
    $c=ConvertTo-ClaudeChargebackConfiguration $script:expected;$c.Formats=@('CSV','HTML');$c.MonthToDate=$true;$c.BusinessUnits=@('unassigned')
    Save-Probe $c 'MTD and selected unit'
    $c=ConvertTo-ClaudeChargebackConfiguration $script:expected;$c.AllowedDomains=@()
    $refused=$false;try{Test-ClaudeChargebackConfiguration $c}catch{$refused=$_.Exception.Message -match 'domain'}
    if(-not $refused){throw 'Empty allowed-domain list was not refused.'}
    $results.Add('empty allowed domains refused')
    $c=ConvertTo-ClaudeChargebackConfiguration $script:expected
    $c.AllowedDomains=@((@($c.AllowedDomains)+@('contoso.com'))|Sort-Object -Unique)
    Save-Probe $c 'allowed-domain list update (delivery remains disabled)'
}
finally {
    $current=Get-ClaudeReportConfiguration $StorageAccount
    if((Fingerprint $current.Configuration) -cne (Fingerprint $script:expected)){throw 'Concurrent settings detected. Automatic restore refused; review blob versions.'}
    Save-ClaudeReportConfiguration $StorageAccount $original $current.ETag
    if((Fingerprint (Get-ClaudeReportConfiguration $StorageAccount).Configuration) -cne (Fingerprint $original)){throw 'Original report settings were not restored.'}
}
[pscustomobject]@{Status='Passed';StartedUtc=$started.ToString('o');CompletedUtc=[datetime]::UtcNow.ToString('o');Checks=$results.ToArray();Restored=$true;EmailSent=$false}|ConvertTo-Json -Depth 5 -Compress
