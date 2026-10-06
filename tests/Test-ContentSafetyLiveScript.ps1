param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name,$Condition,$Detail='') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Run-LiveScript([string[]]$ArgumentList, [string]$PathPrefix) {
    $oldPath = $env:PATH
    $oldLog = $env:P102_AZ_LOG
    $env:PATH = "$PathPrefix;$oldPath"
    $env:P102_AZ_LOG = Join-Path $PathPrefix 'az.log'
    try {
        $out = & pwsh -NoProfile -File (Join-Path $root 'scripts\Test-ClaudeLiveContentSafety.ps1') @ArgumentList 2>&1 | Out-String
        [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $out; Log = if (Test-Path $env:P102_AZ_LOG) { Get-Content $env:P102_AZ_LOG -Raw } else { '' } }
    }
    finally {
        $env:PATH = $oldPath
        if ($null -eq $oldLog) { Remove-Item Env:P102_AZ_LOG -ErrorAction SilentlyContinue } else { $env:P102_AZ_LOG = $oldLog }
    }
}

$work = Join-Path $root '.p102-live-test'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work | Out-Null
@'
@echo off
echo %*>> "%P102_AZ_LOG%"
if "%1 %2"=="account show" echo {"id":"00000000-0000-4000-8000-000000000102","tenantId":"00000000-0000-4000-8000-000000000103"}
if "%1 %2"=="group create" echo {"name":"ok"}
if "%1 %2 %3"=="deployment group create" echo {"properties":{"outputs":{"gatewayUrl":{"value":"https://apim.example/claude"},"apimPrincipalId":{"value":"11111111-1111-4111-8111-111111111111"}}}}
if "%1 %2 %3"=="role assignment delete" echo {}
if "%1 %2"=="group delete" echo {}
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $work 'az.cmd') -Encoding ASCII

Write-Host 'P102 live script refusals'
$common = @('-SubscriptionId','00000000-0000-4000-8000-000000000102','-Location','eastus2','-NamePrefix','p102live','-FoundryAccountName','ai','-FoundryResourceGroup','rg-ai','-PublisherEmail','ops@example.com','-PublisherName','Ops','-RunId','abc123','-SkipHttpChecks')
$savedAzureConfigDir = $env:AZURE_CONFIG_DIR
Remove-Item Env:AZURE_CONFIG_DIR -ErrorAction SilentlyContinue
$r = Run-LiveScript $common $work
if ($savedAzureConfigDir) { $env:AZURE_CONFIG_DIR = $savedAzureConfigDir }
Assert 'live script refuses default Azure CLI profile unless UseCurrentAzLogin' ($r.Exit -ne 0 -and $r.Output -match 'UseCurrentAzLogin' -and $r.Log -eq '') $r.Output
$bad = @('-UseCurrentAzLogin','-SubscriptionId','bad subscription','-Location','eastus2','-NamePrefix','p102live','-FoundryAccountName','ai','-FoundryResourceGroup','rg-ai','-PublisherEmail','ops@example.com','-PublisherName','Ops','-RunId','abc123','-SkipHttpChecks')
$r = Run-LiveScript $bad $work
Assert 'live script validates inputs before any az call' ($r.Exit -ne 0 -and $r.Output -match 'SubscriptionId' -and $r.Log -eq '') $r.Output

Write-Host 'P102 live script setup order'
Remove-Item -LiteralPath (Join-Path $work 'az.log') -Force -ErrorAction SilentlyContinue
$r = Run-LiveScript (@('-UseCurrentAzLogin') + $common) $work
Assert 'setup succeeds with stubbed az' ($r.Exit -eq 0) $r.Output
Assert 'setup uses account show before create and deployment' ($r.Log -match '(?s)^account show.*group create.*deployment group create') $r.Log
Assert 'setup uses run-specific resource group and enables Content Safety explicitly' ($r.Log -match 'rg-p102-live-abc123' -and $r.Log -match 'deployContentSafety=true' -and $r.Log -match 'contentSafetyMode=block') $r.Log
$scriptText = Get-Content (Join-Path $root 'scripts\Test-ClaudeLiveContentSafety.ps1') -Raw
Assert 'script names T1 through T11 and latency evidence' ($scriptText -match 'T1' -and $scriptText -match 'T11' -and $scriptText -match 'latency')

Write-Host 'P102 live script teardown'
$receipt = Join-Path $work 'receipt.json'
@{ runId='abc123'; resourceGroup='rg-p102-live-abc123'; createdResourceGroup=$true; roleAssignmentId='/subscriptions/00000000-0000-4000-8000-000000000102/resourceGroups/rg-p102-live-abc123/providers/Microsoft.CognitiveServices/accounts/cs/providers/Microsoft.Authorization/roleAssignments/ra' } | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $work 'az.log') -Force -ErrorAction SilentlyContinue
$r = Run-LiveScript @('-UseCurrentAzLogin','-Teardown','-ReceiptPath',$receipt) $work
Assert 'teardown deletes the recorded role assignment before the recorded resource group' ($r.Exit -eq 0 -and $r.Log -match '(?s)role assignment delete --ids .*/roleAssignments/ra.*group delete --name rg-p102-live-abc123') ($r.Output + $r.Log)
Assert 'teardown refuses to delete a group it did not create' ($scriptText -match 'createdResourceGroup')
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:failures) { throw "$($script:failures) of $($script:assertions) assertions failed" }
Write-Host "P102 live script checks passed ($script:assertions assertions)."
