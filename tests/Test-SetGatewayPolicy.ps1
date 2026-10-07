# P102 drift repair: Set-GatewayPolicy.ps1 creates only missing safe named values before policy PUTs.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1')

Write-Host ''
Write-Host 'Set-GatewayPolicy - named value drift repair' -ForegroundColor Cyan

$policyPath = Join-Path $root 'infra\policy.xml'
$allReferences = @(Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences -PolicyPath $policyPath)
$contentSafetyNames = @('content-safety-mode','content-safety-endpoint','content-safety-threshold','content-safety-timeout-seconds','content-safety-truncate-mode')

$global:P102SetPolicyLiveNamedValues = @{}
$global:P102SetPolicyCalls = [Collections.Generic.List[string]]::new()
$global:P102SetPolicyPutTargets = [Collections.Generic.List[string]]::new()
$global:P102SetPolicyForbiddenExistingUpdates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$global:P102SetPolicyListMode = 'ok'

function Reset-Fixture([string[]]$Present, [string[]]$ExistingUpdatesForbidden = @(), [string]$ListMode = 'ok') {
    $global:P102SetPolicyListMode = $ListMode
    $global:P102SetPolicyLiveNamedValues = @{}
    foreach ($name in $Present) { $global:P102SetPolicyLiveNamedValues[$name] = "live-$name" }
    $global:P102SetPolicyCalls.Clear()
    $global:P102SetPolicyPutTargets.Clear()
    $global:P102SetPolicyForbiddenExistingUpdates = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $ExistingUpdatesForbidden) { [void]$global:P102SetPolicyForbiddenExistingUpdates.Add($name) }
}

function global:az {
    $line = $args -join ' '
    $global:P102SetPolicyCalls.Add($line)
    $global:LASTEXITCODE = 0
    if ($line -match '^account show') { return '00000000-0000-4000-8000-0000000000a1' }
    if ($line -match '^account get-access-token') { return 'offline-token' }
    if ($line -match '^apim nv list') {
        # A failed az call prints its error on stderr and nothing on stdout.
        switch ($global:P102SetPolicyListMode) {
            'fail' { $global:LASTEXITCODE = 1; return }
            'empty' { return '[]' }
            'object' { return '{ "name": "models-standard", "value": "live" }' }
            'text' { return 'WARNING: the service returned an unexpected page' }
        }
        return (@($global:P102SetPolicyLiveNamedValues.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ name = $_; value = $global:P102SetPolicyLiveNamedValues[$_] } }) | ConvertTo-Json -Depth 4)
    }
    if ($line -match '^apim nv show') {
        $id = ''
        for ($i = 0; $i -lt $args.Count; $i++) {
            if ($args[$i] -eq '--named-value-id' -and $i + 1 -lt $args.Count) { $id = [string]$args[$i + 1] }
        }
        if ($global:P102SetPolicyLiveNamedValues.ContainsKey($id)) { return $global:P102SetPolicyLiveNamedValues[$id] }
        $global:LASTEXITCODE = 3
        return $null
    }
    if ($line -match '^apim nv update') {
        $id = ''
        for ($i = 0; $i -lt $args.Count; $i++) {
            if ($args[$i] -eq '--named-value-id' -and $i + 1 -lt $args.Count) { $id = [string]$args[$i + 1] }
        }
        if ($global:P102SetPolicyForbiddenExistingUpdates.Contains($id)) { throw "existing named value '$id' was updated" }
        $global:LASTEXITCODE = 0
        return
    }
    if ($line -match '^apim nv create') {
        $id = ''
        $value = ''
        for ($i = 0; $i -lt $args.Count; $i++) {
            if ($args[$i] -eq '--named-value-id' -and $i + 1 -lt $args.Count) { $id = [string]$args[$i + 1] }
            if ($args[$i] -eq '--value' -and $i + 1 -lt $args.Count) { $value = [string]$args[$i + 1] }
        }
        $global:P102SetPolicyLiveNamedValues[$id] = $value
        $global:LASTEXITCODE = 0
        return
    }
    throw "Unexpected az call: $line"
}

function global:Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $Body, [switch]$SkipHttpErrorCheck)
    $global:P102SetPolicyPutTargets.Add([string]$Uri)
    [pscustomobject]@{ StatusCode = 200; Content = '{}' }
}
function global:Invoke-RestMethod { throw 'Set-GatewayPolicy should use Invoke-WebRequest in this test.' }

try {
    Reset-Fixture -Present @($allReferences + $contentSafetyNames) -ExistingUpdatesForbidden @($allReferences + $contentSafetyNames)
    $thrown = Get-Thrown { & (Join-Path $root 'scripts\Set-GatewayPolicy.ps1') -ApimName apim-contoso -ResourceGroup rg-contoso -PolicyFile $policyPath -SubscriptionId '00000000-0000-4000-8000-0000000000a1' }
    $nvWrites = @($global:P102SetPolicyCalls | Where-Object { $_ -match '^apim nv (create|update)' })
    Assert 'all present values cause zero named-value writes' (-not $thrown -and $nvWrites.Count -eq 0) "$thrown | $($nvWrites -join '; ')"
    Assert 'all present values still PUT the fragment before the policy' ($global:P102SetPolicyPutTargets.Count -eq 2 -and $global:P102SetPolicyPutTargets[0] -match '/policyFragments/content-safety-screening\?' -and $global:P102SetPolicyPutTargets[1] -match '/apis/claude-foundry/policies/policy\?') ($global:P102SetPolicyPutTargets -join '; ')

    Reset-Fixture -Present @($allReferences | Where-Object { $_ -notin $contentSafetyNames }) -ExistingUpdatesForbidden @($allReferences | Where-Object { $_ -notin $contentSafetyNames })
    $thrown = Get-Thrown { & (Join-Path $root 'scripts\Set-GatewayPolicy.ps1') -ApimName apim-contoso -ResourceGroup rg-contoso -PolicyFile $policyPath -SubscriptionId '00000000-0000-4000-8000-0000000000a1' }
    $creates = @($global:P102SetPolicyCalls | Where-Object { $_ -match '^apim nv create' })
    $updates = @($global:P102SetPolicyCalls | Where-Object { $_ -match '^apim nv update' })
    $createdNames = @($creates | ForEach-Object { if ($_ -match '--named-value-id\s+(\S+)') { $Matches[1] } } | Sort-Object)
    Assert 'missing Content Safety values are created with their defaults only' (-not $thrown -and ($createdNames -join ',') -eq (($contentSafetyNames | Sort-Object) -join ',') -and -not $updates.Count) "$thrown | created=$($createdNames -join ',') updates=$($updates -join '; ')"
    Assert 'Content Safety defaults are safe off-mode values' ($global:P102SetPolicyLiveNamedValues['content-safety-mode'] -eq 'off' -and $global:P102SetPolicyLiveNamedValues['content-safety-endpoint'] -eq 'https://content-safety-off.invalid' -and $global:P102SetPolicyLiveNamedValues['content-safety-threshold'] -eq '2' -and $global:P102SetPolicyLiveNamedValues['content-safety-timeout-seconds'] -eq '10' -and $global:P102SetPolicyLiveNamedValues['content-safety-truncate-mode'] -eq 'newest') ($global:P102SetPolicyLiveNamedValues | ConvertTo-Json -Compress)

    $scratchDir = Join-Path $root '.test-work'
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    $scratch = Join-Path $scratchDir ('set-policy-' + [guid]::NewGuid().ToString('N') + '.xml')
    [IO.File]::WriteAllText($scratch, '<policies><inbound><set-header name="x" exists-action="override"><value>{{tenant-id}}</value></set-header></inbound></policies>')
    try {
        Reset-Fixture -Present @() -ExistingUpdatesForbidden @()
        $thrown = Get-Thrown { & (Join-Path $root 'scripts\Set-GatewayPolicy.ps1') -ApimName apim-contoso -ResourceGroup rg-contoso -PolicyFile $scratch -SubscriptionId '00000000-0000-4000-8000-0000000000a1' }
        $writes = @($global:P102SetPolicyCalls | Where-Object { $_ -match '^apim nv (create|update)' })
        Assert 'a missing named value without a safe default stops before any write and names it' ($thrown -match 'tenant-id' -and $thrown -match 'nothing was written|No named values were written' -and $writes.Count -eq 0 -and $global:P102SetPolicyPutTargets.Count -eq 0) "$thrown | $($writes -join '; ') | $($global:P102SetPolicyPutTargets -join '; ')"

        # Every reference here has a safe default, so a bad list read is the only thing that can stop the run.
        [IO.File]::WriteAllText($scratch, '<policies><inbound><set-variable name="a" value="{{models-standard}}" /><set-variable name="b" value="{{quota-org}}" /></inbound></policies>')
        foreach ($case in @(
                @{ Mode = 'fail'; Label = 'a failed named-value list read' },
                @{ Mode = 'empty'; Label = 'an empty named-value list' },
                @{ Mode = 'object'; Label = 'a named-value list that is not a JSON array' },
                @{ Mode = 'text'; Label = 'a named-value list that is not JSON' })) {
            Reset-Fixture -Present @('models-standard', 'quota-org') -ExistingUpdatesForbidden @('models-standard', 'quota-org') -ListMode $case.Mode
            $thrown = Get-Thrown { & (Join-Path $root 'scripts\Set-GatewayPolicy.ps1') -ApimName apim-contoso -ResourceGroup rg-contoso -PolicyFile $scratch -SubscriptionId '00000000-0000-4000-8000-0000000000a1' }
            $writes = @($global:P102SetPolicyCalls | Where-Object { $_ -match '^apim nv (create|update|show)' })
            Assert "$($case.Label) stops before any named-value read-back, write or PUT" ($thrown -match 'Could not list the named values of ''apim-contoso''' -and $thrown -match 'No named values were written' -and $thrown -match 'Remedy: az login' -and $writes.Count -eq 0 -and $global:P102SetPolicyPutTargets.Count -eq 0) "$thrown | $($writes -join '; ') | $($global:P102SetPolicyPutTargets -join '; ')"
        }
    }
    finally { Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue }

    Assert 'an update of an existing named value would fail the detector' (-not @($global:P102SetPolicyCalls | Where-Object { $_ -match '^apim nv update' }).Count)
}
finally {
    Remove-Item Function:\az, Function:\Invoke-WebRequest, Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Set-GatewayPolicy preserves live named values while repairing missing safe defaults.' -ForegroundColor Green
exit 0
