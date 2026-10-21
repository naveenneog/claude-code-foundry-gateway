# Importing this file performs no Azure operation.
. (Join-Path $PSScriptRoot 'ApimNamedValue.ps1')
. (Join-Path $PSScriptRoot 'ClaudeRunner.ps1')
. (Join-Path $PSScriptRoot 'ClaudeProjectionPackage.ps1')

function Assert-ClaudeAccessCatalogAzureName {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateSet('ResourceGroup','ApimName')][string]$Kind
    )
    $valid = if ($Kind -eq 'ResourceGroup') {
        $Value -cmatch '^[A-Za-z0-9._-]{1,90}$'
    }
    else {
        $Value -cmatch '^[A-Za-z][A-Za-z0-9-]{0,49}$'
    }
    if (-not $valid) {
        throw "Access catalog administration refused: $Kind is not a safe Windows Azure name. Use only the documented letters, digits, dot, underscore and hyphen form."
    }
}

function Get-ClaudeAccessCatalogGateway {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $raw = @(az apim show -g $ResourceGroup -n $ApimName --query '{id:id,identity:identity}' -o json --only-show-errors 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) {
        throw 'Access catalog administration could not read API Management. Check Azure sign-in and read permission; no runner or Cosmos write was started.'
    }
    $text = @($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n"
    try { $apim = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Access catalog administration could not parse the API Management discovery response; no runner or Cosmos write was started.' }
    $id = [string]$apim.id
    $parts = $id -split '/'
    $subscriptionId = if ($parts.Count -gt 2) { [string]$parts[2] } else { '' }
    $tenantId = [string]$apim.identity.tenantId
    $guid = '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
    if ($subscriptionId -notmatch $guid) {
        throw 'Access catalog administration could not bind the gateway subscription; no runner or Cosmos write was started.'
    }
    if ($tenantId -notmatch $guid) {
        throw 'Access catalog administration could not bind the gateway managed-identity tenant; no runner or Cosmos write was started.'
    }
    return [pscustomobject]@{
        SubscriptionId = $subscriptionId.ToLowerInvariant()
        TenantId = $tenantId.ToLowerInvariant()
    }
}

function Invoke-ClaudeAccessCatalogLocalValidation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TenantId
    )
    $cli = Join-Path (Split-Path $PSScriptRoot -Parent) 'sync\src\administer-access-catalog.mjs'
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $raw = @(& node $cli --catalog $Path --tenant $TenantId --validate-only 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $last = @($raw | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    $summary = $null
    if ($last) {
        try { $summary = $last | ConvertFrom-Json -ErrorAction Stop }
        catch { $summary = $null }
    }
    if ($code -ne 0 -or -not $summary -or $summary.ok -ne $true -or $summary.mode -ne 'validate') {
        $stage = if ($summary -and [string]$summary.stage -cmatch '^[a-z][a-z-]{0,39}$') { [string]$summary.stage } else { 'catalog' }
        $detail = if ($stage -eq 'catalog' -and $summary -and $summary.detail) { " Problem: $([string]$summary.detail)." } else { '' }
        throw "Access catalog validation refused at stage $stage.$detail Correct the JSON and tenant binding; no runner or Cosmos write was started."
    }
    return $summary
}

function Invoke-ClaudeAccessCatalogAdministration {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ApimName,
        [Parameter(Mandatory)][string]$Path
    )
    Assert-ClaudeAccessCatalogAzureName -Value $ResourceGroup -Kind ResourceGroup
    Assert-ClaudeAccessCatalogAzureName -Value $ApimName -Kind ApimName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Access catalog administration refused: -Path must name one existing JSON file. No Azure read or write was attempted.'
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $gateway = Get-ClaudeAccessCatalogGateway -ResourceGroup $ResourceGroup -ApimName $ApimName
    $prefix = Get-ApimNamedValue -ResourceGroup $ResourceGroup -ApimName $ApimName -Id 'entitlement-projection-prefix' -FailOnError -SubscriptionId $gateway.SubscriptionId
    if ([string]$prefix -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or ([string]$prefix).Length -gt 37) {
        throw 'Access catalog administration refused: entitlement-projection-prefix is missing or malformed. Deploy the private projection first; no runner or Cosmos write was started.'
    }
    $validation = Invoke-ClaudeAccessCatalogLocalValidation -Path $resolvedPath -TenantId $gateway.TenantId
    Write-Host ("Access catalog plan: plans={0} profiles={1} hash={2}" -f $validation.plans, $validation.profiles, $validation.catalogVersion)
    Write-Host ("Projection target: prefix={0} runner=aci-projtest-{0} Cosmos=cosmos-{0}/claude/entitlement" -f $prefix)
    if ($WhatIfPreference) {
        Write-Host 'WhatIf: validation and discovery completed; the runner was not started and Cosmos was not changed.'
        return [pscustomobject]@{
            Published = $false
            Plans = $validation.plans
            Profiles = $validation.profiles
            CatalogVersion = $validation.catalogVersion
        }
    }

    $runner = "aci-projtest-$prefix"
    $cosmosAccount = "cosmos-$prefix"
    $accountResourceId = "/subscriptions/$($gateway.SubscriptionId)/resourceGroups/$ResourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosAccount"
    $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-access-catalog-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $archive = Join-Path $work 'sync-source.tar.gz'
    try {
        if (-not $PSCmdlet.ShouldProcess("$cosmosAccount/claude/entitlement", 'back up and publish the tenant access catalog through the private projection runner')) {
            throw 'Access catalog publication was declined; the runner was not started and Cosmos was not changed.'
        }
        $null = New-ClaudeProjectionSyncArchive -Path $archive -Root (Split-Path $PSScriptRoot -Parent)
        Start-ClaudeProjectionRunner -ResourceGroup $ResourceGroup -Name $runner -SubscriptionId $gateway.SubscriptionId | Out-Null
        Send-RunnerFile -ResourceGroup $ResourceGroup -Name $runner -Path $archive -Destination /work/sync-source.tar.gz -SubscriptionId $gateway.SubscriptionId | Out-Null
        Send-RunnerFile -ResourceGroup $ResourceGroup -Name $runner -Path $resolvedPath -Destination /work/access-catalog.json -SubscriptionId $gateway.SubscriptionId | Out-Null
        Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -SubscriptionId $gateway.SubscriptionId -Command 'tar -x -z -f /work/sync-source.tar.gz -C /work' | Out-Null
        Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -SubscriptionId $gateway.SubscriptionId -Command 'npm --prefix /work/sync ci --omit=dev --ignore-scripts --no-audit --fund=false' | Out-Null
        $raw = Invoke-RunnerCommand -ResourceGroup $ResourceGroup -Name $runner -SubscriptionId $gateway.SubscriptionId -Command (
            "node /work/sync/src/administer-access-catalog.mjs --catalog /work/access-catalog.json --cosmos https://$cosmosAccount.documents.azure.com:443/ " +
            "--database claude --container entitlement --tenant $($gateway.TenantId) --account-resource-id $accountResourceId"
        )
        $result = ConvertFrom-ClaudeRunnerResult -RawOutput $raw -Step 'access catalog publication'
        if ($result.catalogVersion -ne $validation.catalogVersion) {
            throw 'Access catalog publication failed: runner readback hash differs from the locally validated hash.'
        }
        Write-Host ("Access catalog published: status={0} plans={1} profiles={2} hash={3} backup={4}" -f
            $result.status, $result.plans, $result.profiles, $result.catalogVersion, $result.backup)
        return [pscustomobject]@{
            Published = $true
            Status = $result.status
            Plans = $result.plans
            Profiles = $result.profiles
            CatalogVersion = $result.catalogVersion
            Backup = [bool]$result.backup
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
