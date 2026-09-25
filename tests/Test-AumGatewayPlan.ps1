param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeAumDeployment.ps1')
$record = New-ClaudeAumLocalFile
$baseline = New-ClaudeAumLocalFile
$plan = New-ClaudeAumLocalFile
$gateway = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-aum-e2e-contoso/providers/Microsoft.ApiManagement/service/apim-contoso'
function az { throw 'A plan must not invoke Azure CLI.' }
function Invoke-RestMethod { throw 'A plan must not invoke HTTP.' }
function Invoke-WebRequest { throw 'A plan must not invoke HTTP.' }
try {
    Write-ClaudeAumJson $record @{resourceGroup='rg-aum-e2e-contoso';gatewayResourceId=$gateway}
    Write-ClaudeAumJson $baseline @{Gateway=@{id=$gateway}}
    Write-ClaudeAumJson $plan @{ResourceGroup='rg-aum-e2e-contoso'}
    $params=@{RecordPath=$record;BaselinePath=$baseline;PlanPath=$plan}
    $result=& (Join-Path $root 'scripts\Test-ClaudeAumGateway.ps1') @params
    if ($result.transport -ne 'direct-http-with-Azure-CLI-token' -or -not $result.notAnAumClientClaim) {
        throw 'Fallback evidence must not impersonate the AUM command face.'
    }
    $denied=$false
    try { & (Join-Path $root 'scripts\Test-ClaudeAumGateway.ps1') @params -Execute -Confirm:$false }
    catch { $denied=$_.Exception.Message -match 'prior agent' }
    if (-not $denied) { throw 'Execution did not require a closed prior window.' }
    $denied=$false
    try { & (Join-Path $root 'scripts\Test-ClaudeAumGateway.ps1') @params -Execute -PriorWindowClosed -NotBeforeUtc ([datetimeoffset]::UtcNow.AddHours(1)) -Confirm:$false }
    catch { $denied=$_.Exception.Message -match 'fallback time' }
    if (-not $denied) { throw 'Execution ignored its not-before boundary.' }
    Write-ClaudeAumJson $record @{resourceGroup='rg-contoso-reference';gatewayResourceId=$gateway}
    $denied=$false
    try { & (Join-Path $root 'scripts\Test-ClaudeAumGateway.ps1') @params }
    catch { $denied=$_.Exception.Message -match 'dedicated AUM test gateway' }
    if (-not $denied) { throw 'The dedicated test-target boundary was not enforced.' }
    $tokens=$null; $parseErrors=$null
    $journey=[System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'scripts\Test-ClaudeAumGateway.ps1'),[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Gateway proof does not parse.' }
    $mainTry=@($journey.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst]
    })[-1]
    $findPublication={param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Publish-ProofQueries'}
    $published=@($mainTry.Body.FindAll($findPublication,$true))
    if ($published.Count -ne 1 -or @($mainTry.Finally.FindAll($findPublication,$true)).Count) {
        throw 'Publish the test membership in the proof body; never regenerate the saved snapshot in finally.'
    }
    $firstProbe=@($mainTry.Body.FindAll({param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Wait-ClaudeProbe'
    },$true))[0]
    if ($published[0].Extent.StartOffset -ge $firstProbe.Extent.StartOffset) {
        throw 'Publish test membership before observing model attribution.'
    }
    $restore=@($mainTry.Finally.FindAll({param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Invoke-RestMethod' -and
        $node.Extent.Text.Contains('$costUri') -and $node.Extent.Text.Contains('$costBefore.properties')
    },$true))
    if ($restore.Count -ne 1) { throw 'Finally must PUT the exact saved ClaudeCost properties.' }
    $costUri='https://example.invalid/savedSearches/claudecost'
    $armHeaders=@{}
    $costBefore=@{properties=[ordered]@{
        query='print snapshot_day=datetime(2026-09-24), team="original-team"'
        functionAlias='ClaudeCost'; functionParameters=''; category='Chargeback'
        displayName='Original cost function'; version=7
    }}
    $script:restoredCost=$null
    function Invoke-RestMethod {
        param($Uri,$Method,$Headers,$ContentType,$Body,$TimeoutSec)
        if ($Uri -ne $costUri -or $Method -ne 'Put') { throw 'Unexpected restoration request.' }
        $script:restoredCost=$Body | ConvertFrom-Json
    }
    & ([scriptblock]::Create($restore[0].Extent.Text))
    foreach ($field in $costBefore.properties.Keys) {
        if ([string]$script:restoredCost.properties.$field -cne [string]$costBefore.properties[$field]) {
            throw "Restoration changed original saved-query property $field."
        }
    }
    Write-Host 'AUM gateway proof: local-only plan, target/window guards, publish-before-probe and exact saved-query restoration passed.' -ForegroundColor Green
}
finally {
    Remove-Item $record,$baseline,$plan -ErrorAction SilentlyContinue
}
