<#
.SYNOPSIS
    Generates reconciled monthly business-unit CSV, HTML and a JSON manifest.
.DESCRIPTION
    Uses the published ClaudeCost and ClaudeChargeback functions. The default is the previous
    calendar month, UTC. Each unit's files contain only that unit. No file is published when
    reconciliation fails. Figures are list-price showback, not an Azure invoice.
.EXAMPLE
    ./scripts/New-ClaudeChargebackReport.ps1 -Month 2026-08 -BusinessUnit engineering
.EXAMPLE
    ./scripts/New-ClaudeChargebackReport.ps1 -MonthToDate -Send
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Month, [switch]$MonthToDate, [string[]]$BusinessUnit,
    [string]$OutputPath = './chargeback-reports',
    [ValidateSet('CSV','HTML')][string[]]$Format = @('CSV','HTML'),
    [switch]$Send, [string]$StorageAccount,
    [string]$ResourceGroup = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ResourceGroup),
    [string]$ApimName = $(& (Join-Path $PSScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName),
    [string]$WorkspaceResourceId = $env:CLAUDE_REPORT_WORKSPACE
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ClaudeChargebackReport.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackQuery.ps1')
. (Join-Path $PSScriptRoot 'ClaudeChargebackRender.ps1')
$window=Get-ClaudeReportWindow -Month $Month -MonthToDate:$MonthToDate
foreach($unit in $BusinessUnit) { Get-ClaudeReportFileName $unit | Out-Null }
if ($Send -and (@($Format | Sort-Object -Unique).Count -ne 2)) { throw 'Email requires CSV and HTML. Choose both formats before sending.' }
if (-not $PSCmdlet.ShouldProcess("$OutputPath/$($window.Month)", "Generate report ($($window.From) to $($window.To), UTC, exclusive end)$(if($Send){' and queue email'})")) { return }
if (-not $ResourceGroup -or -not $ApimName) { throw 'Pass -ResourceGroup and -ApimName, or set CLAUDE_RG and CLAUDE_APIM.' }
if (-not $WorkspaceResourceId) {
    . (Join-Path $PSScriptRoot 'ClaudeTurnstileGovernance.ps1')
    $WorkspaceResourceId=Get-ClaudeGatewayWorkspaceId -ResourceGroup $ResourceGroup -ApimName $ApimName
}
$source=Get-ClaudeReportSource $WorkspaceResourceId
$catalog=@(Get-ClaudeReportCatalog -ResourceGroup $ResourceGroup -ApimName $ApimName)
$scopes=Invoke-ClaudeReportQuery $WorkspaceResourceId (Get-ClaudeReportQuery $window Scopes)
$readPeople={param($unit,$prefix) Invoke-ClaudeReportQuery $WorkspaceResourceId (Get-ClaudeReportQuery $window People $unit $prefix)}
$readDimensions={param($unit) Invoke-ClaudeReportQuery $WorkspaceResourceId (Get-ClaudeReportQuery $window Dimensions $unit)}
$result=Write-ClaudeChargebackReport -Window $window -Catalog $catalog -Scopes $scopes -ReadPeople $readPeople -ReadDimensions $readDimensions `
    -Source $source -OutputPath $OutputPath -BusinessUnit $BusinessUnit -Format $Format
$after=Get-ClaudeReportSource $WorkspaceResourceId
if (($after.Functions | ConvertTo-Json -Compress) -ne ($source.Functions | ConvertTo-Json -Compress)) {
    $result.Manifest.Status='Invalidated'
    Write-ClaudeReportJson (Join-Path $result.Path 'manifest.json') $result.Manifest
    throw 'Saved functions changed during generation. Report invalidated; regenerate before sending.'
}
Write-Host "UTC period: $($window.From) <= time < $($window.To)"
foreach($note in $script:ClaudeReportCaveats) { Write-Host $note }
Write-Host "Reconciliation PASS: $($result.Manifest.Totals.Requests) selected requests; $($result.Manifest.PersonRows) person rows."
if ($Send) {
    & (Join-Path $PSScriptRoot 'Send-ClaudeChargebackReport.ps1') -ReportPath $result.Path -StorageAccount $StorageAccount -ResourceGroup $ResourceGroup -ApimName $ApimName
}
$result
