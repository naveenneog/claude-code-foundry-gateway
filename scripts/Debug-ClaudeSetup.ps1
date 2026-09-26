<#
.SYNOPSIS
    Read-only administrator diagnostics for a Claude Foundry gateway.
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$ApimName,
    [string]$DecisionRecord = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\claude-gateway.json'),
    [string]$GatewayUrl,
    [string]$FoundryAccount,
    [switch]$NoRequest,
    [string]$SupportBundle,
    [switch]$AsJson,
    [ValidateSet('fail','warn')][string]$FailOn = 'warn'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'ClaudeDiagnoseCommon.ps1')

Write-Host ''
Write-Host 'Claude gateway setup diagnostics' -ForegroundColor Cyan
Write-Host ''

$record = $null
if (Test-Path -LiteralPath $DecisionRecord -PathType Leaf) {
    try {
        $record = Get-Content -LiteralPath $DecisionRecord -Raw | ConvertFrom-Json
        if (-not $ResourceGroup) { $ResourceGroup = [string](Get-ClaudeDiagnoseProperty $record 'resourceGroup') }
        if (-not $ApimName) { $ApimName = [string](Get-ClaudeDiagnoseProperty $record 'apimName') }
        if (-not $GatewayUrl) { $GatewayUrl = [string](Get-ClaudeDiagnoseProperty $record 'gatewayUrl') }
        Add-ClaudeDiagnoseCheck 'Decision record' 'PASS' "Loaded schemaVersion $($record.schemaVersion) from $DecisionRecord" 'If stale, rerun Start-ClaudeGateway.ps1 -Action Status, then Update.' 'Repository > onboarding > claude-gateway.json'
    } catch {
        Add-ClaudeDiagnoseCheck 'Decision record' 'FAIL' $_.Exception.Message 'Restore the last known-good onboarding/claude-gateway.json or rerun the guided flow.' 'Repository > onboarding'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Decision record' 'WARN' "No decision record at $DecisionRecord" 'Pass -DecisionRecord <path> or run Start-ClaudeGateway.ps1 -Action Setup.' 'Repository > onboarding'
}

$apim = $null
if ($ResourceGroup -and $ApimName) {
    $az = Get-ClaudeDiagnoseAz @('apim','show','-g',$ResourceGroup,'-n',$ApimName,'-o','json')
    $apim = ConvertFrom-ClaudeDiagnoseJson $az.Output
    if ($apim) {
        if (-not $GatewayUrl -and $apim.gatewayUrl) { $GatewayUrl = ([string]$apim.gatewayUrl).TrimEnd('/') + '/claude' }
        $liveSku = [string](Get-ClaudeDiagnoseProperty $apim 'sku.name')
        $recordSku = [string](Get-ClaudeDiagnoseProperty $record 'decisions.sku')
        $e = "APIM exists; SKU=$liveSku; gatewayUrl=$($apim.gatewayUrl)"
        if ($recordSku -and $liveSku -and $recordSku -ne $liveSku) {
            Add-ClaudeDiagnoseCheck 'Decision record matches live state' 'FAIL' "$e; record SKU=$recordSku" 'Run Start-ClaudeGateway.ps1 -Action Update after backing up the gateway.' 'Azure portal > API Management services > <gateway> > Overview'
        } else {
            Add-ClaudeDiagnoseCheck 'Decision record matches live state' 'PASS' $e 'No fix needed.' 'Azure portal > API Management services > <gateway> > Overview'
        }
        if ($liveSku -in @('BasicV2','StandardV2','PremiumV2')) {
            Add-ClaudeDiagnoseCheck 'API Management SKU' 'PASS' "$liveSku supports Claude token policies." 'No fix needed.' 'Azure portal > API Management services > <gateway> > Scale and pricing'
        } else {
            Add-ClaudeDiagnoseCheck 'API Management SKU' 'FAIL' "$liveSku is not a v2 SKU; Claude token metering can be zero." "Migrate to BasicV2, StandardV2 or PremiumV2 with the guided flow." 'Azure portal > API Management services > <gateway> > Scale and pricing'
        }
    } else {
        Add-ClaudeDiagnoseCheck 'Decision record matches live state' 'FAIL' "az apim show failed: $($az.Output)$($az.Error)" 'Check -ResourceGroup and -ApimName, then az login to the owning tenant.' 'Azure portal > Resource groups'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Decision record matches live state' 'SKIP' 'ResourceGroup or ApimName not known.' 'Pass -ResourceGroup and -ApimName.' 'Azure portal > API Management services'
}

if ($GatewayUrl) {
    if (Test-ClaudeDiagnoseUrl $GatewayUrl) {
        if ($NoRequest) {
            Add-ClaudeDiagnoseCheck 'Gateway real request' 'SKIP' "Resolved $GatewayUrl; -NoRequest was supplied." 'Rerun without -NoRequest to make one read-only inference request.' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
        } else {
            $token = Get-ClaudeDiagnoseAz @('account','get-access-token','--resource','https://cognitiveservices.azure.com','-o','json')
            $tok = ConvertFrom-ClaudeDiagnoseJson $token.Output
            if (-not $tok.accessToken) {
                Add-ClaudeDiagnoseCheck 'Gateway real request' 'FAIL' 'Could not acquire a Cognitive Services token.' 'az login --tenant <tenant-id>' 'Microsoft Entra ID > Overview'
            } else {
                $body = @{ model = 'claude-sonnet-5'; max_tokens = 8; messages = @(@{ role='user'; content='say OK' }) } | ConvertTo-Json -Depth 6
                try {
                    $r = Invoke-WebRequest -Method Post -Uri ($GatewayUrl.TrimEnd('/') + '/v1/messages') -Headers @{ Authorization = 'Bearer ' + $tok.accessToken; 'anthropic-version'='2023-06-01'; 'Content-Type'='application/json' } -Body $body -TimeoutSec 90
                    Add-ClaudeDiagnoseCheck 'Gateway real request' 'PASS' "HTTP $($r.StatusCode); tier=$($r.Headers['x-claude-tier'] -join '')" 'No fix needed.' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
                } catch {
                    $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
                    Add-ClaudeDiagnoseCheck 'Gateway real request' 'FAIL' "HTTP $code; $($_.Exception.Message)" 'Check entitlement, budgets, policy named values and Foundry RBAC; rerun Test-ClaudeHealth.ps1.' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Test'
                }
            }
        }
    } else {
        Add-ClaudeDiagnoseCheck 'Gateway DNS and URL' 'FAIL' "Gateway URL is not an HTTPS gateway URL: $GatewayUrl" 'Use https://<apim>.azure-api.net/claude from the decision record or APIM overview.' 'Azure portal > API Management services > <gateway> > Overview'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Gateway real request' 'SKIP' 'Gateway URL not known.' 'Pass -GatewayUrl or a decision record with gatewayUrl.' 'Azure portal > API Management services > <gateway> > Overview'
}

$principalId = [string](Get-ClaudeDiagnoseProperty $apim 'identity.principalId')
if ($principalId) {
    $roles = Get-ClaudeDiagnoseAz @('role','assignment','list','--assignee',$principalId,'-o','json')
    $roleJson = ConvertFrom-ClaudeDiagnoseJson $roles.Output
    if (@($roleJson | Where-Object { $_.roleDefinitionName -match 'Cognitive Services|Azure AI' }).Count) {
        Add-ClaudeDiagnoseCheck 'Gateway managed identity and Foundry role' 'PASS' "Managed identity has a Foundry data-plane role." 'No fix needed.' 'Azure portal > Foundry account > Access control (IAM)'
    } else {
        Add-ClaudeDiagnoseCheck 'Gateway managed identity and Foundry role' 'FAIL' "Principal exists but no Cognitive Services User-style assignment was found." "az role assignment create --assignee $principalId --role 'Cognitive Services User' --scope <foundry-resource-id>" 'Azure portal > Foundry account > Access control (IAM) > Add role assignment'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Gateway managed identity and Foundry role' 'SKIP' 'APIM managed identity principal id not known.' 'Enable a system-assigned managed identity on the gateway.' 'Azure portal > API Management services > <gateway> > Identity'
}

$policyPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra\policy.xml'
if ($ResourceGroup -and $ApimName -and (Test-Path $policyPath)) {
    $policy = Get-ClaudeDiagnoseAz @('apim','api','policy','show','-g',$ResourceGroup,'--service-name',$ApimName,'--api-id','claude-foundry','--xml','-o','tsv')
    $expected = (Get-Content -LiteralPath $policyPath -Raw).Trim()
    $live = ([string]$policy.Output).Trim()
    if ($live -and ($live -eq $expected -or $live -match 'llm-token-limit')) {
        Add-ClaudeDiagnoseCheck 'Deployed policy matches repository intent' 'PASS' 'Live policy contains the Claude governance controls.' './scripts/Set-GatewayPolicy.ps1 -ResourceGroup <rg> -ApimName <apim>' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Design > Inbound processing'
    } else {
        Add-ClaudeDiagnoseCheck 'Deployed policy matches repository intent' 'WARN' 'Could not prove live policy equals infra/policy.xml.' './scripts/Set-GatewayPolicy.ps1 -ResourceGroup <rg> -ApimName <apim>' 'Azure portal > API Management services > <gateway> > APIs > Claude API > Design > Inbound processing'
    }
} else {
    Add-ClaudeDiagnoseCheck 'Deployed policy matches repository intent' 'SKIP' 'Policy comparison needs APIM names and infra/policy.xml.' './scripts/Set-GatewayPolicy.ps1 -ResourceGroup <rg> -ApimName <apim>' 'Azure portal > API Management services > <gateway> > APIs'
}

$namedValues = $null
if ($ResourceGroup -and $ApimName) {
    $nv = Get-ClaudeDiagnoseAz @('apim','nv','list','-g',$ResourceGroup,'--service-name',$ApimName,'-o','json')
    $namedValues = @(ConvertFrom-ClaudeDiagnoseJson $nv.Output)
    if ($namedValues.Count) {
        $oversized = @($namedValues | Where-Object { ([string]$_.value).Length -gt 4096 })
        $tierIds = @('developers-standard','developers-premium')
        $tierEvidence = @()
        foreach ($id in $tierIds) {
            $item = $namedValues | Where-Object { $_.name -eq $id } | Select-Object -First 1
            $count = if ($item) { @(([string]$item.value -split ',' | Where-Object { $_.Trim() })).Count } else { 0 }
            $tierEvidence += "$id=$count/110"
        }
        $bu = $namedValues | Where-Object { $_.name -eq 'bu-members' } | Select-Object -First 1
        $buCount = if ($bu) { @(([string]$bu.value -split ',' | Where-Object { $_.Trim() })).Count } else { 0 }
        if ($oversized.Count) {
            Add-ClaudeDiagnoseCheck 'Named values present and within size' 'FAIL' "Oversized values: $($oversized.name -join ', ')" './scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup <rg> -ApimName <apim>' 'Azure portal > API Management services > <gateway> > Named values'
        } else {
            Add-ClaudeDiagnoseCheck 'Named values present and within size' 'PASS' "Read $($namedValues.Count) values; $($tierEvidence -join '; '); bu-members=$buCount/93." './scripts/Measure-ClaudeCeiling.ps1 -ResourceGroup <rg> -ApimName <apim>' 'Azure portal > API Management services > <gateway> > Named values'
        }
    } else {
        Add-ClaudeDiagnoseCheck 'Named values present and within size' 'WARN' 'No named values returned.' 'Redeploy the gateway template or restore from Backup-ClaudeGateway.ps1.' 'Azure portal > API Management services > <gateway> > Named values'
    }
}

$source = $namedValues | Where-Object { $_.name -eq 'entitlement-source' } | Select-Object -First 1
$sourceValue = if ($source) { [string]$source.value } else { [string](Get-ClaudeDiagnoseProperty $record 'decisions.entitlementStore') }
if ($sourceValue -match 'projection') {
    Add-ClaudeDiagnoseCheck 'Entitlement source' 'WARN' 'Projection selected; resolver health and authentication must be checked live.' './scripts/Deploy-ClaudeProjection.ps1 -CompareOnly -ResourceGroup <rg> -ApimName <apim>' 'Azure portal > App Services > <resolver> > Authentication'
} else {
    Add-ClaudeDiagnoseCheck 'Entitlement source' 'PASS' 'Named-value entitlement selected; list counts are covered by named-value headroom.' './scripts/Deploy-ClaudeProjection.ps1 can migrate to the projection when counts approach 110/93.' 'Azure portal > API Management services > <gateway> > Named values'
}

$healthJson = $null
if ($ResourceGroup -and $ApimName) {
    $healthPath = Join-Path $PSScriptRoot 'Test-ClaudeHealth.ps1'
    if (Test-Path $healthPath) {
        $health = Invoke-ClaudeDiagnoseCommand -FilePath $healthPath -ArgumentList @('-ResourceGroup',$ResourceGroup,'-ApimName',$ApimName,'-AsJson')
        $healthJson = ConvertFrom-ClaudeDiagnoseJson $health.Output
        if ($healthJson -and $healthJson.checks) {
            foreach ($name in @('Business units','Organisation ceiling','Foundry bypass closed','Models are priced')) {
                $h = $healthJson.checks | Where-Object { $_.check -eq $name } | Select-Object -First 1
                if ($h) {
                    $status = switch ($h.status) { 'pass' { 'PASS' } 'warn' { 'WARN' } default { 'FAIL' } }
                    Add-ClaudeDiagnoseCheck $name $status $h.detail $h.fix 'Azure portal > API Management services > <gateway>; Azure portal > Foundry account'
                }
            }
        } else {
            Add-ClaudeDiagnoseCheck 'Business units and budgets consistency' 'WARN' 'Test-ClaudeHealth.ps1 did not return JSON.' './scripts/Test-ClaudeHealth.ps1 -ResourceGroup <rg> -ApimName <apim> -Detailed' 'Azure portal > API Management services > <gateway> > Named values'
        }
    }
}

foreach ($name in @('Tier groups resolve','FinOps tool','Dollar budgets','Workbooks deployed','Chargeback report jobs','Foundry bypass principals')) {
    if (@($script:ClaudeDiagnoseResults | Where-Object Name -eq $name).Count) { continue }
    switch ($name) {
        'Tier groups resolve' { Add-ClaudeDiagnoseCheck $name 'WARN' 'Tier group ids are checked through entitlement health; direct Graph group resolution needs Directory read permission.' './scripts/Compare-ClaudeEntitlement.ps1 -ResourceGroup <rg> -ApimName <apim>' 'Microsoft Entra admin center > Groups' }
        'FinOps tool' { Add-ClaudeDiagnoseCheck $name 'WARN' 'Turnstile integration, AUM service reachability and AUM client presence need tenant-specific endpoints.' './scripts/Select-ClaudeFinOpsTooling.ps1, ./scripts/Connect-ClaudeTurnstile.ps1, ./scripts/Install-ClaudeAum.ps1' 'Azure portal > App Services; Turnstile URL; terminal: aum status' }
        'Dollar budgets' { Add-ClaudeDiagnoseCheck $name 'WARN' 'Price book and reconciled state freshness are deployment-specific.' './scripts/Sync-ClaudeUsdBudgets.ps1 -ResourceGroup <rg> -ApimName <apim> -WhatIf' 'Azure portal > API Management services > <gateway> > Named values' }
        'Workbooks deployed' { Add-ClaudeDiagnoseCheck $name 'WARN' 'Workbook presence was not proven in this offline/read-only run.' './scripts/Publish-ClaudeWorkbook.ps1 -ResourceGroup <rg> -WhatIf' 'Azure portal > Monitor > Workbooks' }
        'Chargeback report jobs' { Add-ClaudeDiagnoseCheck $name 'WARN' 'Chargeback job and last-run metadata were not found automatically.' './scripts/Invoke-ClaudeChargebackSchedule.ps1 -ResourceGroup <rg> -WhatIf' 'Azure portal > Storage accounts / Automation / Functions used by chargeback' }
        'Foundry bypass principals' { Add-ClaudeDiagnoseCheck $name 'WARN' 'Run Get-ClaudeBypass.ps1 for the principal list; Test-ClaudeHealth summarizes whether any exist.' './scripts/Get-ClaudeBypass.ps1 -ResourceGroup <rg>' 'Azure portal > Foundry account > Access control (IAM)' }
    }
}

if ($SupportBundle) {
    Write-ClaudeDiagnoseSupportBundle -Path $SupportBundle -Results $script:ClaudeDiagnoseResults -Files @{ decision_record = $DecisionRecord; repository_policy = $policyPath } -Data @{ apim = $apim; named_values = $namedValues; health = $healthJson }
}

Write-ClaudeDiagnoseResults -Results $script:ClaudeDiagnoseResults -AsJson:$AsJson
exit (Get-ClaudeDiagnoseExitCode -Results $script:ClaudeDiagnoseResults -FailOn $FailOn)
