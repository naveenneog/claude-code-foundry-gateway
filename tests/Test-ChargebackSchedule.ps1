param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackReport.ps1')
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackSchedule.ps1')
$fail=0; $checks=0
function Assert($Name,$Condition) { $script:checks++; if(-not $Condition) {$script:fail++;Write-Host "FAIL: $Name"} }
function Refuses($Name,[scriptblock]$Action) { $threw=$false;try{& $Action|Out-Null}catch{$threw=$true};Assert $Name $threw }
foreach($cron in @('0 6 1 * *','*/7 * * * *','15 8 * * 1-5')) { Test-ClaudeReportCron $cron; Assert "valid cron $cron" $true }
foreach($cron in @('0 6 1 *','0 6 1 * * & echo bad','0 6 1 * *|x','61 0 1 * *','0 25 * * *')) { Refuses "reject invalid cron $cron" {Test-ClaudeReportCron $cron} }
$p=New-ClaudeReportScheduleParameters -ApimName 'apim-contoso' -WorkspaceResourceId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso/providers/Microsoft.OperationalInsights/workspaces/log-contoso' -RepositoryUrl 'https://github.com/contoso/gateway.git' -RepositoryRef ('a'*40) -Cron '0 6 1 * *' -OperatorObjectId '11111111-1111-1111-1111-111111111111' -OperatorPrincipalType User -Location eastus2
Assert 'pins full commit' ($p.parameters.repositoryRef.value -eq ('a'*40))
Assert 'cron is data, not shell interpolation' ($p.parameters.cronExpression.value -eq '0 6 1 * *')
Refuses 'mutable ref refused' { New-ClaudeReportScheduleParameters -RepositoryRef main }
Refuses 'repository shell metacharacters refused' { New-ClaudeReportScheduleParameters -RepositoryRef ('a'*40) -RepositoryUrl 'https://github.com/contoso/gw.git;rm' }
$infra=Get-Content (Join-Path $SourceRoot 'infra\chargeback-reports.bicep') -Raw
foreach($text in @("allowBlobPublicAccess: false","allowSharedKeyAccess: false","isVersioningEnabled: true","deleteRetentionPolicy","Microsoft.Communication/emailServices","AzureManaged","Consumption","Microsoft.ManagedIdentity/userAssignedIdentities","configuration","Storage Blob Data")) {
    Assert "infrastructure declares $text" ($infra.Contains($text))
}
Assert 'dedicated environment, not Turnstile' ($infra -match 'cae-reports-' -and $infra -notmatch 'cae-turnstile')
Assert 'job has no connection string' ($infra -notmatch 'connectionString|listKeys\(')
Assert 'two short-lived jobs share outbox' ($infra -match 'dispatcher' -and $infra -match 'generator')
Assert 'bootstrap strips Windows carriage returns' ($infra -match "replace\(bootstrap, '\\r', ''\)")
Assert 'job pins code rather than fetching main' ($infra -match 'REPO_REF' -and $infra -notmatch 'git.+ main')
Assert 'role excludes gateway write' ($infra -notmatch 'Microsoft.ApiManagement/service/namedValues/write')
Assert 'role excludes keys' ($infra -notmatch 'ListKeys/action|RegenerateKey')
$register=Get-Content (Join-Path $SourceRoot 'scripts\Register-ClaudeChargebackSchedule.ps1') -Raw
Assert 'schedule supports WhatIf' ($register -match 'SupportsShouldProcess')
Assert 'parameters go through a file' ($register -match '--parameters "@\$')
Assert 'updates use existing resource patch' ($register -match 'Update-ClaudeReportJob')
Assert 'RunNow waits and asserts success' ($register -match 'Wait-ClaudeReportJob')
$runner=Get-Content (Join-Path $SourceRoot 'scripts\Invoke-ClaudeChargebackSchedule.ps1') -Raw
Assert 'scheduled worker reads configuration every execution' ($runner -match 'Get-ClaudeReportConfiguration')
Assert 'generation archives even without recipients' ($runner -match 'Save-ClaudeReportArchive')
$outbox=Get-Content (Join-Path $SourceRoot 'scripts\ClaudeChargebackOutbox.ps1') -Raw
Assert 'sender rechecks current recipients' ($outbox -match 'Get-ClaudeChargebackRecipients')
Assert 'sender serializes with blob lease' ($outbox -match 'x-ms-lease-action')
Assert 'outbox stores no address list' ($outbox -notmatch 'Recipients=\$recipients')
Assert 'send state persisted before network operation' ($outbox -match "(?s)Status='Submitting'.*?Set-ClaudeReportArchiveJson.*?Invoke-ClaudeReportEmail -Endpoint[^\r\n]+-Body")
Assert 'dispatcher scales to zero with no pending blobs' ($infra -match "minExecutions: 0" -and $infra -match "type: 'azure-blob'")
$blobPrefix=[regex]::Match($infra,"blobPrefix: '([^']+)'").Groups[1].Value
Assert 'KEDA effective prefix matches the outbox (it appends the delimiter)' (($blobPrefix+'/') -ceq 'outbox/')
Assert 'storage is network-private, not just authenticated' ($infra -match "publicNetworkAccess: 'Disabled'" -and $infra -match 'infrastructureSubnetId:')
Assert 'private blob endpoint and DNS are declared' ($infra -match 'Microsoft.Network/privateEndpoints' -and $infra -match 'privatelink.blob.core.windows.net')
Assert 'manual administration has its own identity' ($infra -match 'adminIdentity' -and $infra -match "mode: 'admin'")
if($fail){throw "$fail of $checks schedule assertions failed."}
Write-Host "$checks chargeback schedule assertions passed."
