param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
. (Join-Path $root 'scripts\ClaudeContentSafety.ps1')
$script:assertions = 0; $script:failures = 0
function Assert($Name,$Condition,$Detail='') { $script:assertions++; if ($Condition) { Write-Host "  [OK] $Name" } else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" } }

Write-Host 'P102 deployment contract'
$contentSafety = Get-Content (Join-Path $root 'infra\content-safety.bicep') -Raw
$main = Get-Content (Join-Path $root 'infra\main.bicep') -Raw
$installer = Get-Content (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
Assert 'Content Safety module creates a ContentSafety S0 account with custom subdomain and local auth disabled' ($contentSafety -match "kind:\s*'ContentSafety'" -and $contentSafety -match "name:\s*'S0'" -and $contentSafety -match 'customSubDomainName' -and $contentSafety -match 'disableLocalAuth:\s*true')
Assert 'Content Safety module grants Cognitive Services User to the APIM principal' ($contentSafety -match 'Cognitive Services User' -and $contentSafety -match 'roleAssignments' -and $contentSafety -match 'principalId')
Assert 'main template defaults content safety off without creating an account' ($main -match 'param deployContentSafety bool = false' -and $main -match "param contentSafetyMode string = 'off'" -and $main -match "module contentSafety 'content-safety\.bicep' = if \(deployContentSafety\)")
$missingNamedValues = @('content-safety-mode','content-safety-endpoint','content-safety-threshold','content-safety-timeout-seconds','content-safety-truncate-mode') | Where-Object { $main -notmatch [regex]::Escape($_) }
Assert 'main template adds endpoint, threshold, timeout and fragment named values' (@($missingNamedValues).Count -eq 0) (@($missingNamedValues) -join ',')
Assert 'main template creates the APIM policy fragment and the API policy depends on it' ($main -match 'service/policyFragments' -and $main -match "loadTextContent\('content-safety-screening.xml'\)" -and $main -match 'contentSafetyFragment')
Assert 'installer exposes an opt-in Content Safety switch and preserves existing mode unless explicitly changed' ($installer.Contains('[switch]$DeployContentSafety') -and $installer.Contains('$operatorSuppliedContentSafetyMode') -and $installer.Contains('contentSafetyMode=$contentSafetyModeForDeployment'))
$unsafeContentSafetyReads = @('content-safety-mode','content-safety-endpoint','content-safety-threshold','content-safety-timeout-seconds','content-safety-truncate-mode') | Where-Object {
    $installer -notmatch "Get-ApimNamedValue[^\r\n]+-Id '$([regex]::Escape($_))'[^\r\n]+-FailOnError"
}
Assert 'installer Content Safety read-back fails closed on read errors' ($unsafeContentSafetyReads.Count -eq 0) (@($unsafeContentSafetyReads) -join ',')
$supported = Test-ClaudeContentSafetyRegion 'East US 2'
$unsupported = Test-ClaudeContentSafetyRegion 'antarcticacentral'
Assert 'supported Content Safety region passes readiness' ($supported.Result -eq 'PASS' -and $supported.Location -eq 'eastus2') ($supported | ConvertTo-Json -Compress)
Assert 'unsupported Content Safety region blocks before writes with a cited remedy' ($unsupported.Result -eq 'FAIL' -and $unsupported.Remedy -match 'Microsoft Learn' -and $unsupported.Remedy -match '2026-10-06') ($unsupported | ConvertTo-Json -Compress)

Write-Host 'P102 Bicep compilation'
$out = & az bicep build --file (Join-Path $root 'infra\main.bicep') --stdout --only-show-errors 2>&1 | Out-String
Assert 'main.bicep compiles offline' ($LASTEXITCODE -eq 0 -and $out -match 'Microsoft.ApiManagement/service/policyFragments') $out
$compiled = $out | ConvertFrom-Json -Depth 100
$fragmentRefs = @([regex]::Matches($fragment, '\{\{([^}]+)\}\}') | ForEach-Object { $_.Groups[1].Value.Trim() } | Sort-Object -Unique)
$namedKeys = @([regex]::Matches($main, "\{\s*key:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$missingFragmentRefs = @($fragmentRefs | Where-Object { $namedKeys -notcontains $_ })
Assert 'every content-safety fragment named value reference is declared in main.bicep' ($missingFragmentRefs.Count -eq 0) (@($missingFragmentRefs) -join ',')
$fragmentResource = @($compiled.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/policyFragments' -and $_.name -match 'content-safety-screening' })[0]
$apiPolicyResource = @($compiled.resources | Where-Object { $_.type -eq 'Microsoft.ApiManagement/service/apis/policies' })[0]
Assert 'compiled Content Safety fragment depends on APIM named values' (@($fragmentResource.dependsOn) -contains 'apimNamedValues') (($fragmentResource.dependsOn | Out-String).Trim())
Assert 'compiled API policy depends on the Content Safety fragment' (@($apiPolicyResource.dependsOn | Where-Object { $_ -match 'policyFragments' -and $_ -match 'content-safety-screening' }).Count -eq 1) (($apiPolicyResource.dependsOn | Out-String).Trim())

if ($script:failures) { throw "$($script:failures) of $($script:assertions) assertions failed" }
Write-Host "P102 content safety deployment checks passed ($script:assertions assertions)."
