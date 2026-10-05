$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}
function Capture([scriptblock]$Block) { $script:Failure = $null; $script:Result = $null; try { $script:Result = & $Block } catch { $script:Failure = $_.Exception.Message } }
. (Join-Path $PSScriptRoot 'TestProjectionFixture.ps1')
. (Join-Path $root 'scripts\ClaudeRunner.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionChecks.ps1')
. (Join-Path $root 'scripts\ClaudeProjectionSwitch.ps1')

Write-Host ''
Write-Host 'Projection switch evidence - runner admission and switch order' -ForegroundColor Cyan

Reset-ProjectionFixture
Capture { Assert-ClaudeProjectionAdmission -ResourceGroup rg-p84 -RunnerName aci-projtest-p84fixture -CosmosAccount cosmos-p84fixture -TenantId $FixtureTenant -AccountResourceId $FixtureCosmosId }
$calls = $FixtureCalls -join "`n"
Assert 'admission uses check-admission.mjs with the D11 switch-evidence flags only' (-not $Failure -and $Result.mode -eq 'switch-evidence' -and $calls -match 'check-admission\.mjs --cosmos https://cosmos-p84fixture\.documents\.azure\.com:443/ --tenant' -and $calls -match '--account-resource-id' -and $calls -match '--max-evidence-age-seconds 86400' -and $calls -notmatch 'image-digest|entrypoint|action-group|gateway-resource-id|standard-group-id') "$Failure | $calls"
Capture { ConvertFrom-ClaudeProjectionAdmissionResult -RawOutput '{"ok":true,"mode":"projection-admission","generations":3}' }
Assert 'old three-run projection-admission evidence is refused' ($Failure -match 'switch evidence was not accepted') $Failure

$work = Join-Path ([IO.Path]::GetTempPath()) ('p97-switch-test-' + [guid]::NewGuid().ToString('N'))
$backupDir = Join-Path $work 'onboarding'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$compareStub = Join-Path $work 'compare-stub.ps1'
[IO.File]::WriteAllText($compareStub, @'
param([string]$ResourceGroup, [string]$ApimName, [string]$StandardGroup, [string]$PremiumGroup, [string]$ExportGatewayPath, [bool]$FailOnDrift = $true)
$global:FixtureCalls.Add("compare-stub $ResourceGroup $ApimName $StandardGroup $PremiumGroup")
if ($global:CompareDrift) { exit 1 }
[IO.File]::WriteAllText($ExportGatewayPath, '{"kind":"claude-gateway-decisions","premium":[],"standard":[]}')
exit 0
'@)
$syncStub = Join-Path $work 'sync-stub.ps1'
[IO.File]::WriteAllText($syncStub, @'
param([string]$ApimName, [string]$ResourceGroup, [string]$StandardGroup, [string]$PremiumGroup, [string]$ExportPath)
$global:FixtureCalls.Add("sync-export $ResourceGroup $ApimName $StandardGroup $PremiumGroup")
[IO.File]::WriteAllText($ExportPath, '{"scope":"full","records":[]}')
exit 0
'@)
function Invoke-Switch([hashtable]$Extra = @{}) {
    $params = @{ ResourceGroup = 'rg-p84'; ApimName = 'apim-p84'; NamePrefix = 'p84fixture'; StandardGroup = 'claude-code-standard'; PremiumGroup = 'none'; BackupDirectory = $backupDir; CompareScript = $compareStub; SyncProjectionScript = $syncStub }
    foreach ($key in $Extra.Keys) { $params[$key] = $Extra[$key] }
    Invoke-ClaudeProjectionSwitch @params
}
function At([string]$Pattern) { for ($i = 0; $i -lt $FixtureCalls.Count; $i++) { if ($FixtureCalls[$i] -match $Pattern) { return $i } }; return -1 }
function Writes { @($FixtureCalls | Where-Object { $_ -match '^az apim nv (update|create)' }) }

Reset-ProjectionFixture
$global:CompareDrift = $false
Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Capture { Invoke-Switch }
$order = @((At '^confirm-sp '), (At '^compare-stub'), (At '^start-runner rg-p84 aci-projtest-p84fixture'), (At 'apply-projection\.mjs .*--compare /work/gateway-decisions\.json'), (At 'check-admission\.mjs'), (At '^az apim nv update .*entitlement-source --value projection'))
Assert 'switch takes prefix, confirms resolver SP, starts runner, compares, checks evidence and writes once' (-not $Failure -and ($order -notcontains -1) -and (@(0..4 | Where-Object { $order[$_] -lt $order[$_ + 1] }).Count -eq 5) -and @(Writes).Count -eq 1 -and @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue).Count -eq 1) "$Failure | $($order -join ',') | $(($FixtureCalls -join '; '))"
Assert 'switch no longer reads renewal job/action group/digest evidence' (($FixtureCalls -join "`n") -notmatch 'actionGroups|Microsoft.App/jobs|image-digest|entrypoint') ($FixtureCalls -join ' | ')

Reset-ProjectionFixture 'new-gateway'
Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Capture { Invoke-Switch }
$calls = $FixtureCalls -join "`n"
Assert 'new gateway skips drift export and uses compare-snapshot against a fresh full snapshot' (-not $Failure -and $calls -notmatch '(?m)^compare-stub' -and $calls -match '(?m)^sync-export rg-p84 apim-p84' -and $calls -match '--compare-snapshot /work/snapshot\.json') "$Failure | $calls"

Reset-ProjectionFixture 'sp-missing'
Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue | Remove-Item -Force
Capture { Invoke-Switch }
Assert 'missing resolver service principal refuses before compare and backup' ($Failure -match 'service principal' -and (At '^compare-stub') -lt 0 -and @(Writes).Count -eq 0 -and -not @(Get-ChildItem -LiteralPath $backupDir -Filter '*.json' -ErrorAction SilentlyContinue).Count) $Failure

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Projection switch evidence holds.' -ForegroundColor Green
exit 0
