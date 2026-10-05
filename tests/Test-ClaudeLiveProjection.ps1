$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
$count = 0
function Assert($label, $condition, $detail = '') {
    $script:count++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) {
    $script:Failure = ''
    $script:Result = $null
    try { $script:Result = & $Block }
    catch { $script:Failure = $_.Exception.Message }
}

Write-Host ''
Write-Host 'Live projection verification script - validation and order' -ForegroundColor Cyan

$scriptPath = Join-Path $root 'scripts\Test-ClaudeLiveProjection.ps1'
$calls = [System.Collections.Generic.List[string]]::new()
function az {
    $joined = $args -join ' '
    $calls.Add("az $joined")
    $global:LASTEXITCODE = 0
    if ($joined -like 'group exists*') { return 'false' }
    if ($joined -like 'account set*') { return }
    if ($joined -like 'account show*') { return '{"tenantId":"00000000-0000-4000-8000-0000000000f1","user":{"name":"admin@contoso.com"}}' }
    if ($joined -like 'ad signed-in-user show*') { return '00000000-0000-4000-8000-0000000000aa' }
    if ($joined -like 'ad group member add*') { return }
    if ($joined -like 'group create*') { return }
    if ($joined -like 'group delete*') { return }
    if ($joined -like 'ad group delete*') { return }
    if ($joined -like 'ad app list*') { return '[]' }
    if ($joined -like 'role assignment delete*') { return }
    $calls.Add("unexpected $joined")
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec)
    $calls.Add("request $Uri $Body")
    [pscustomobject]@{ id = 'msg_01'; content = @(@{ text = 'ok' }) }
}

Capture { & $scriptPath -SubscriptionId bad -Location eastus2 -FoundryAccount ai -FoundryResourceGroup rg-ai -UseCurrentAzLogin }
Assert 'invalid subscription id is refused before any az call' ($Failure -match 'SubscriptionId' -and $calls.Count -eq 0) "$Failure | $($calls -join '; ')"

$calls.Clear()
$oldAzConfig = $env:AZURE_CONFIG_DIR
$env:AZURE_CONFIG_DIR = ''
try {
    Capture { & $scriptPath -SubscriptionId 00000000-0000-4000-8000-000000000001 -Location eastus2 -FoundryAccount ai -FoundryResourceGroup rg-ai }
}
finally { $env:AZURE_CONFIG_DIR = $oldAzConfig }
Assert 'the script refuses the default Azure profile unless explicitly allowed' ($Failure -match 'AZURE_CONFIG_DIR' -and $calls.Count -eq 0) "$Failure | $($calls -join '; ')"

$calls.Clear()
$syncPath = Join-Path $root 'scripts\Sync-ClaudeAccess.ps1'
$syncOriginal = if (Test-Path -LiteralPath $syncPath) { Get-Content -LiteralPath $syncPath -Raw } else { $null }
$installerPath = Join-Path $root 'Install-ClaudeGateway.ps1'
$installerOriginal = Get-Content -LiteralPath $installerPath -Raw
try {
    [IO.File]::WriteAllText($installerPath, 'param($SubscriptionId,$FoundryAccount,$FoundryResourceGroup,$ResourceGroup,$Location,$NamePrefix,$Sku,$EntitlementStore,$StandardGroup,$PremiumGroup,[switch]$Yes,[switch]$DeployProjection) $global:LiveProjectionCalls.Add("installer $ResourceGroup $EntitlementStore $Sku $DeployProjection $StandardGroup $PremiumGroup")', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($syncPath, 'param($ResourceGroup,$ApimName,$User) $global:LiveProjectionCalls.Add("sync $ResourceGroup $ApimName $User")', [Text.UTF8Encoding]::new($false))
    $global:LiveProjectionCalls = $calls
    $env:AZURE_CONFIG_DIR = Join-Path $root '.az-live-projection-test'
    Capture {
        & $scriptPath -SubscriptionId 00000000-0000-4000-8000-000000000001 -Location eastus2 -FoundryAccount ai -FoundryResourceGroup rg-ai `
            -ResourceGroup rg-p98-live -NamePrefix p98live -StandardGroup claude-p98-std -PremiumGroup claude-p98-prm -UseCurrentAzLogin -Teardown
    }
}
finally {
    [IO.File]::WriteAllText($installerPath, $installerOriginal, [Text.UTF8Encoding]::new($false))
    if ($null -ne $syncOriginal) { [IO.File]::WriteAllText($syncPath, $syncOriginal, [Text.UTF8Encoding]::new($false)) }
    $env:AZURE_CONFIG_DIR = $oldAzConfig
}
$order = $calls -join "`n"
Assert 'the live script reports JSON and runs installer, user sync and gateway request in order' (
    -not $Failure -and
    ($order -match 'az group exists --name rg-p98-live') -and
    ($order -match 'az group create') -and
    ($order -match 'installer rg-p98-live projection BasicV2 True claude-p98-std claude-p98-prm') -and
    ($order -match 'az ad group member add --group claude-p98-std') -and
    ($order -match 'sync rg-p98-live apim-p98live 00000000-0000-4000-8000-0000000000aa') -and
    ($order -match 'request https://apim-p98live.azure-api.net/claude/v1/messages') -and
    ($order -match 'az group delete --name rg-p98-live') -and
    (([array]::IndexOf($calls.ToArray(), @($calls | Where-Object { $_ -like 'installer *' })[0])) -lt ([array]::IndexOf($calls.ToArray(), @($calls | Where-Object { $_ -like 'sync *' })[0])))
) "$Failure`n$order"

Write-Host ''
if ($fail) { Write-Host "$fail of $count assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$count live projection assertion(s) passed." -ForegroundColor Green
