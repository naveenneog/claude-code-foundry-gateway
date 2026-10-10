<#
.SYNOPSIS
    Applies a policy XML file to the Claude gateway API in API Management.
.DESCRIPTION
    Creates any named values and policy fragments referenced by the policy before PUTting the API policy.
    This lets pre-P102 gateways accept policy.xml, whose APIM include-fragment depends on a fragment resource.
    Only missing named values are created; existing values are never updated. The script stops before any
    write when the live named-value list cannot be read.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApimName,
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [Parameter(Mandatory = $true)][string]$PolicyFile,
    [string]$ApiId = 'claude-foundry',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'flow\FlowContract.ps1')
. (Join-Path $PSScriptRoot 'flow\lib\LifecycleCommon.ps1')
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')

$resolvedPolicyPath = (Resolve-Path $PolicyFile)
$xml = [IO.File]::ReadAllText($resolvedPolicyPath).TrimStart([char]0xFEFF)
$scope = if (Test-ClaudeFlowSubscriptionId $SubscriptionId) { @{ SubscriptionId = $SubscriptionId } } else { @{} }
$subscriptionArgs = if ($scope.ContainsKey('SubscriptionId')) { @('--subscription', $scope.SubscriptionId) } else { @() }
$defaults = Get-ClaudeFlowLifecycleTemplateNamedValueDefaults
# A failed, empty or malformed read would make every referenced value look missing, and the repair below would
# then overwrite operator-owned values with template defaults. A deployed gateway always has named values.
$global:LASTEXITCODE = 0
$liveNamedValueJson = az apim nv list -g $ResourceGroup --service-name $ApimName -o json @subscriptionArgs
$listProblem = if ($LASTEXITCODE -ne 0) { "az exit $LASTEXITCODE" } else { '' }
$liveNamedValues = $null
if (-not $listProblem) {
    try { $liveNamedValues = ($liveNamedValueJson | Out-String) | ConvertFrom-Json -NoEnumerate -ErrorAction Stop }
    catch { $listProblem = 'the output was not JSON' }
}
if (-not $listProblem -and $liveNamedValues -isnot [array]) { $listProblem = 'the output was not a JSON array' }
elseif (-not $listProblem -and $liveNamedValues.Count -eq 0) { $listProblem = 'the list was empty' }
elseif (-not $listProblem -and @($liveNamedValues | Where-Object { -not [string]$_.name }).Count) { $listProblem = 'an entry had no name' }
if ($listProblem) {
    throw "Could not list the named values of '$ApimName' ($listProblem). No named values were written and no policy was applied. A deployed gateway has named values such as tenant-id, so an empty list counts as a failed read. Remedy: az login, confirm that subscription '$SubscriptionId' can read the API Management named values of '$ResourceGroup/$ApimName', then run this script again."
}
$liveNamedValueMap = Get-ClaudeFlowLifecycleNamedValueMap -Discovery ([pscustomobject]@{ namedValues = @($liveNamedValues) })
$requiredNamedValues = [Collections.Generic.List[string]]::new()
foreach ($name in @(Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences -PolicyPath $resolvedPolicyPath)) { $requiredNamedValues.Add($name) }
if (@(Get-ClaudeFlowLifecyclePolicyFragmentIds -PolicyPath $resolvedPolicyPath | Where-Object { $_ -eq 'content-safety-screening' }).Count) {
    foreach ($name in @($defaults.Keys | Where-Object { $_ -like 'content-safety-*' })) { $requiredNamedValues.Add($name) }
}
$missingNamedValues = @(Sort-ClaudeFlowOrdinal -InputObject @($requiredNamedValues) -Unique | Where-Object { -not $liveNamedValueMap.ContainsKey($_) })
$unknownDefaults = @($missingNamedValues | Where-Object { -not $defaults.Contains($_) -or $null -eq $defaults[$_].Value })
if ($unknownDefaults.Count) {
    throw "Policy references missing named value(s) with no safe template default: $($unknownDefaults -join ', '). No named values were written. Create them first, or run Update-ClaudeGateway.ps1 so the fingerprinted migration can plan them."
}
foreach ($name in $missingNamedValues) {
    if (-not $defaults.Contains($name) -or $null -eq $defaults[$name].Value) {
        throw "Policy references named value '$name' but this script has no safe default. Create the named value first, or run Update-ClaudeGateway.ps1 so the fingerprinted migration can plan it."
    }
    Set-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id $name -Value ([string]$defaults[$name].Value) @scope
}

$token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
foreach ($fragment in @(Get-ClaudeFlowLifecyclePolicyFragmentIds -PolicyPath $resolvedPolicyPath)) {
    $fragmentPath = Join-Path (Join-Path $root 'infra') "$fragment.xml"
    if (-not (Test-Path -LiteralPath $fragmentPath)) { throw "Policy includes fragment '$fragment', but '$fragmentPath' was not found." }
    $fragmentXml = [IO.File]::ReadAllText($fragmentPath).TrimStart([char]0xFEFF)
    $fragmentUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
        "/providers/Microsoft.ApiManagement/service/$ApimName/policyFragments/$fragment`?api-version=2024-05-01"
    $fragmentBody = @{ properties = @{ format = 'rawxml'; value = $fragmentXml } } | ConvertTo-Json -Depth 5 -Compress
    $fragmentResp = Invoke-WebRequest -Uri $fragmentUri -Method Put -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($fragmentBody)) -SkipHttpErrorCheck
    if ($fragmentResp.StatusCode -notin 200, 201) {
        Write-Host "FAILED - fragment '$fragment' HTTP $($fragmentResp.StatusCode)" -ForegroundColor Red
        Write-Host $fragmentResp.Content
        exit 1
    }
}

$uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
       "/providers/Microsoft.ApiManagement/service/$ApimName/apis/$ApiId/policies/policy?api-version=2024-05-01"
$body = @{ properties = @{ format = 'rawxml'; value = $xml } } | ConvertTo-Json -Depth 5 -Compress
$resp = Invoke-WebRequest -Uri $uri -Method Put -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -SkipHttpErrorCheck
if ($resp.StatusCode -in 200, 201) {
    Write-Host "Policy applied to '$ApiId' ($([math]::Round($xml.Length/1KB,1)) KB)" -ForegroundColor Green
}
else {
    Write-Host "FAILED - HTTP $($resp.StatusCode)" -ForegroundColor Red
    Write-Host $resp.Content
    exit 1
}
