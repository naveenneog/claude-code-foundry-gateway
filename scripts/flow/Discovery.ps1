<#
.SYNOPSIS
    Read-only discovery for the guided flow (ADR-0032): the one gateway the record names, if any.

.DESCRIPTION
    Discovery used to list every subscription, API Management instance, Foundry account, workspace
    and deployment before the first question: 66 s on the reference subscription, for lists no
    step read. It now reads only the gateway the record names, and every read prints what it reads
    with an estimate before it starts and the time it took after.
#>

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ClaudeGatewayRegion.ps1')

# Measured 2026-09-27 on the reference subscription: az apim show took 3.3-3.7 s.
$script:ClaudeFlowGatewayReadSeconds = 4

function Invoke-ClaudeFlowAzRead {
    # One Azure CLI read, announced with an estimate and timed. A failure is returned, not thrown.
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][int]$AboutSeconds,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Write-Host ("Reading {0} from Azure (about {1} s)..." -f $What, $AboutSeconds) -ForegroundColor DarkGray
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $value = $null
    $failure = ''
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        $failure = 'the Azure CLI (az) is not installed or not on PATH'
    }
    else {
        # Windows PowerShell 5.1 turns native stderr into a terminating error under Stop.
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& az @Arguments -o json 2>&1)
            $code = $LASTEXITCODE
        }
        catch { $output = @(); $code = -1; $failure = $_.Exception.Message }
        finally { $ErrorActionPreference = $saved }
        $errors = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
        $text = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
        if (-not $failure -and $code -eq 0) {
            try { $value = $text | ConvertFrom-Json } catch { $failure = "the Azure CLI returned output that is not JSON: $($_.Exception.Message)" }
        }
        elseif (-not $failure) {
            $failure = if ($errors.Count) { $errors[0] } else { "az exited with code $code" }
        }
    }
    $seconds = $watch.Elapsed.TotalSeconds
    if ($failure) { Write-Host ("  not read after {0:N1} s: {1}" -f $seconds, $failure) -ForegroundColor Yellow }
    else { Write-Host ("  read in {0:N1} s" -f $seconds) -ForegroundColor DarkGray }
    [pscustomobject]@{
        Value = $value
        Failure = $failure
        NotFound = [bool]($failure -match '\((ResourceNotFound|ResourceGroupNotFound)\)')
        Seconds = $seconds
    }
}

function Get-ClaudeFlowDiscovery {
    param(
        [string]$RecordPath = 'onboarding/claude-gateway.json',
        $Record = $null
    )
    if (-not $Record -and (Test-Path -LiteralPath $RecordPath)) {
        try { $Record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json }
        catch { $Record = $null }
    }
    if ($env:CLAUDE_FLOW_SKIP_AZ_DISCOVERY -eq '1') {
        return [pscustomobject][ordered]@{
            record = $Record
            gateway = $null
            Region = $null
            comparison = [pscustomobject]@{ status = 'skipped'; differences = @(); reason = 'CLAUDE_FLOW_SKIP_AZ_DISCOVERY=1' }
        }
    }

    $recordApim = if ($Record -and $Record.apimName) { [string]$Record.apimName } else { '' }
    $recordGroup = if ($Record -and $Record.resourceGroup) { [string]$Record.resourceGroup } else { '' }
    $decision = if ($Record -and $Record.PSObject.Properties.Name -contains 'decisions' -and $Record.decisions -and $Record.decisions.PSObject.Properties.Name -contains 'foundation') { $Record.decisions.foundation } else { $null }
    $recordedRegion = if ($Record -and $Record.location) { [string]$Record.location } elseif ($decision -and $decision.location) { [string]$decision.location } else { '' }
    $differences = [System.Collections.Generic.List[string]]::new()
    $gateway = $null
    $status = 'match-or-unknown'
    $reason = ''

    if (-not ($recordApim -and $recordGroup)) {
        $where = if ($RecordPath) { $RecordPath } else { 'the decision record' }
        Write-Host "No gateway is recorded in $where, so nothing is read from Azure." -ForegroundColor DarkGray
        $status = 'nothing-recorded'
    }
    else {
        # az is a .cmd shim on Windows, and cmd.exe re-reads & | < > ^ ( ) and quotes in an unquoted
        # argument, so a recorded name is passed only when it is letters, digits and . _ -. That covers
        # every API Management name; a resource group with parentheses, which Azure allows, is not read.
        $safeName = { param([string]$Value) $Value -match '^[A-Za-z0-9._-]{1,90}$' }
        $subscription = if ($Record.subscriptionId) { [string]$Record.subscriptionId } elseif ($decision -and $decision.subscriptionId) { [string]$decision.subscriptionId } else { '' }
        $read = $null
        if (-not ((& $safeName $recordGroup) -and (& $safeName $recordApim))) {
            $status = 'unknown'
            $reason = "the recorded gateway '$recordGroup/$recordApim' has characters that cmd.exe would re-read in an Azure CLI argument, so it was not read"
            Write-Host "Recorded gateway not read: $reason." -ForegroundColor Yellow
        }
        else {
            $arguments = @('apim', 'show', '-g', $recordGroup, '-n', $recordApim)
            # A subscription is passed only as an id; a name is free text and may hold any of those.
            if ($subscription -match '^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$') { $arguments += @('--subscription', $subscription) }
            $read = Invoke-ClaudeFlowAzRead -What "API Management $recordGroup/$recordApim" -AboutSeconds $script:ClaudeFlowGatewayReadSeconds -Arguments $arguments
        }
        if ($read -and $read.NotFound) {
            $differences.Add("record names API Management '$recordApim' in '$recordGroup', but Azure reports it was not found: $($read.Failure)")
        }
        elseif ($read -and $read.Failure) {
            $status = 'unknown'
            $reason = "the recorded gateway could not be read: $($read.Failure)"
        }
        elseif ($read) {
            $live = $read.Value
            $gateway = [pscustomobject]@{
                name = [string]$live.name
                resourceGroup = $recordGroup
                location = ConvertTo-ClaudeArmRegionName ([string]$live.location)
                sku = if ($live.sku) { [string]$live.sku.name } else { '' }
                publisherEmail = [string]$live.publisherEmail
                gatewayUrl = [string]$live.gatewayUrl
            }
            $recordUrl = if ($Record.gatewayUrl) { ([string]$Record.gatewayUrl).TrimEnd('/') } else { '' }
            $liveUrl = $gateway.gatewayUrl.TrimEnd('/')
            if ($recordUrl -and $liveUrl -and -not ($recordUrl -eq $liveUrl -or $recordUrl.StartsWith($liveUrl + '/', [StringComparison]::OrdinalIgnoreCase))) {
                $differences.Add("record gatewayUrl '$($Record.gatewayUrl)' differs from live '$($gateway.gatewayUrl)'")
            }
        }
    }

    if ($differences.Count) { $status = 'drift' }
    $region = if ($gateway -and $gateway.location) { $gateway.location } else { ConvertTo-ClaudeArmRegionName $recordedRegion }
    [pscustomobject][ordered]@{
        record = $Record
        gateway = $gateway
        Region = $(if ($region) { $region } else { $null })
        comparison = [pscustomobject]@{ status = $status; differences = @($differences); reason = $reason }
    }
}