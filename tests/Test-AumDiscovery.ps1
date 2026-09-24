param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeAumDeployment.ps1')
$script:commands = @()
$sub = '00000000-0000-0000-0000-000000000001'
$gatewayId = "/subscriptions/$sub/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso"
$insightsId = "/subscriptions/$sub/resourceGroups/rg-telemetry/providers/Microsoft.Insights/components/appi-contoso"
$workspaceId = "/subscriptions/$sub/resourceGroups/rg-telemetry/providers/Microsoft.OperationalInsights/workspaces/log-contoso"
function az {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
    $script:commands += ,$Arguments
    $global:LASTEXITCODE = 0
    $command = $Arguments -join ' '
    $value = switch -Regex ($command) {
        '^account show' { @{id=$sub; tenantId='00000000-0000-0000-0000-000000000002'}; break }
        '^apim list' { ,@(@{ id=$gatewayId; name='apim-contoso'; resourceGroup='rg-contoso'; location='Contoso Region' }); break }
        '^rest .*loggers' { @{value=@(@{properties=@{loggerType='applicationInsights'; resourceId=$insightsId}})}; break }
        '^resource show.*Microsoft.Insights' { @{properties=@{WorkspaceResourceId=$workspaceId}}; break }
        '^resource show.*OperationalInsights' { @{id=$workspaceId; properties=@{customerId='00000000-0000-0000-0000-000000000003'}}; break }
        '^group list' { ,@(@{name='rg-contoso'}); break }
        '^functionapp list-flexconsumption-locations' { ,@(@{name='contoso-region'}); break }
        '^storage account list' { ,@(); break }
        '^appservice plan list' { ,@(); break }
        '^role definition list' { ,@(); break }
        '^rest .*PUT.*roleDefinitions' {
            $bodyIndex = [array]::IndexOf($Arguments, '--body') + 1
            $script:lastRoleBody = Get-Content ($Arguments[$bodyIndex].Substring(1)) -Raw | ConvertFrom-Json
            @{ id="/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000004" }
            break
        }
        default { throw "Unexpected az invocation: $command" }
    }
    ConvertTo-Json -InputObject $value -Depth 10 -Compress
}
$result = Get-ClaudeAumDiscovery -SubscriptionId $sub -GatewayResourceGroup 'rg-contoso' -ApimName 'apim-contoso'
if ($result.Workspace.id -ne $workspaceId) { throw 'Workspace discovery did not follow the gateway logger into its different resource group.' }
if (@($script:commands | Where-Object { $_ -contains 'create' -or $_ -contains 'update' -or $_ -contains 'delete' }).Count) { throw 'Discovery mutated Azure.' }
if (@($script:commands | Where-Object { $_ -contains 'logger' }).Count) { throw 'Discovery used the nonexistent Azure CLI apim logger command.' }
$role = Set-ClaudeAumWriterRole -GatewayResourceId $gatewayId
if (-not $script:lastRoleBody.properties.roleName -or @($script:lastRoleBody.properties.permissions[0].actions).Count -ne 4) {
    throw 'Custom role REST schema lost its roleName or least-privilege actions.'
}
$file = New-ClaudeAumLocalFile
$folder = Split-Path $file -Parent
$leaf = Split-Path $file -Leaf
Push-Location $folder
try {
    Write-ClaudeAumJson $leaf @{discovered=$true}
    if (-not (Test-Path $file)) { throw 'Relative JSON paths did not respect the PowerShell location.' }
}
finally { Pop-Location; Remove-Item $file -ErrorAction SilentlyContinue }
$rejected = $false
try { Invoke-ClaudeAumAz @('rest','--url','https://contoso.invalid/?a=1&b=2') }
catch { $rejected = $_.Exception.Message -match 'Unsafe Azure CLI argument' }
if (-not $rejected) { throw 'cmd.exe-sensitive query arguments were not refused.' }
Write-Host 'AUM discovery: linked workspace, no writes, actual ARM logger route, local files and shell safety passed.' -ForegroundColor Green
