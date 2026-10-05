<#
.SYNOPSIS
    Writing an API Management named value without losing the error.

.DESCRIPTION
    Dot-source this. It exists because every named value write in this
    repository used to be made like this:

        az apim nv update ... -o none 2>$null

    with no $LASTEXITCODE check, so a failure was discarded and the caller
    carried on reporting success.

    That matters because named values have a hard size limit. Measured
    2026-09-15 against a live instance: a 4,096-character value returns HTTP
    201, and 8,192 returns HTTP 400, "NamedValue Value should be between 1 and
    4096 characters long."

    An object id is 36 characters, so with separators an allow list holds about
    110 entries. Past that the write failed, the error went to $null, and:

      Sync-ClaudeAccess.ps1   reported a successful sync while entitlement
                              silently stopped updating.
      Show-Governance.ps1     lowers tpm-standard to 100 to demonstrate
                              throttling and then restores it. A failed restore
                              left the standard tier capped at 100 tokens per
                              minute, with nothing said.

    So the size is checked before the call, and the call itself throws on
    failure. A caller that wants to continue past an error has to say so.
#>

# The documented maximum, from the service's own error message rather than from
# a doc page that could drift.
$script:ApimNamedValueMaxLength = 4096
$ApimNamedValueMaxLength = $script:ApimNamedValueMaxLength

function Test-ApimNamedValueLength {
    <#
    .SYNOPSIS
        Throws if a value will not fit in a named value.

    .DESCRIPTION
        Separate from the write so it can be exercised without Azure, and so a
        caller that builds a value incrementally can check before it commits to
        a long round trip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $len = $Value.Length
    if ($len -le $script:ApimNamedValueMaxLength) { return }

    $over = $len - $script:ApimNamedValueMaxLength

    # An allow list is the common case, so say what the limit means in the
    # units the caller is actually thinking in.
    $entries = @($Value.Trim(',') -split ',' | Where-Object { $_ })
    $hint = ''
    if ($entries.Count -gt 1) {
        $per = [math]::Ceiling($len / $entries.Count)
        $fits = [math]::Floor($script:ApimNamedValueMaxLength / $per)
        $hint = " It holds $($entries.Count) entries of about $per characters; roughly $fits fit."
    }

    throw ("Named value '$Id' is $len characters, which is $over over the API Management limit of " +
           "$($script:ApimNamedValueMaxLength).$hint Nothing was written. " +
           "A list this large needs a different store - see docs/ROADMAP.md P19.")
}

function Get-ApimNamedValue {
    <#
    .SYNOPSIS
        Reads a named value, returning $null when it does not exist.

    .DESCRIPTION
        Paired with Set-ApimNamedValue so a caller that has to merge - an
        entitlement list, a business unit registry - reads through the same
        place it writes.

    .PARAMETER FailOnError
        Distinguish a missing named value from a failed read. Use when absence
        grants permission to write: only APIM's NamedValue not found response
        returns null on failure; authorization, connectivity and target errors throw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$ApimName,
        [Parameter(Mandatory = $true)][string]$Id,
        [switch]$FailOnError,
        [string]$SubscriptionId
    )
    $subscriptionArgs = @()
    if ($SubscriptionId) { $subscriptionArgs = @('--subscription', $SubscriptionId) }
    if ($FailOnError) {
        $previousPreference = $ErrorActionPreference
        try {
            # PS 5.1 turns native stderr into ErrorRecords. Collect it before
            # interpreting the exit code, rather than terminating on a real 404.
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            $output = @(az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id --query value -o tsv --only-show-errors @subscriptionArgs 2>&1)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($code -ne 0) {
            $detail = $output | Out-String
            # Measured: az exits 3 with (ResourceNotFound) NamedValue not found.
            # A missing resource group or APIM instance is not a missing value.
            if ($detail -match '(?is)\(ResourceNotFound\)\s+NamedValue not found\b') { return $null }
            throw "Could not read named value '$Id' on '$ApimName' (az exit $code). Check Azure sign-in, named-value read permission and connectivity."
        }
        if (-not $output.Count) { return $null }
        return ($output -join "`n")
    }
    $v = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id --query value -o tsv @subscriptionArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { return $null }
    return $v
}

function Get-ApimServiceId {
    <#
    .SYNOPSIS
        Reads an API Management instance's resource id, returning $null only when Azure reports it missing.

    .DESCRIPTION
        For a caller that treats absence as a new gateway, as Install-ClaudeGateway.ps1 does before it
        deploys the template's defaults. A failed read that returned $null would let such a caller write
        those defaults over an existing gateway's entitlement source, lists and network settings, so only
        Azure's ResourceNotFound or ResourceGroupNotFound answer returns $null (the rule
        scripts/flow/Discovery.ps1 applies to the same read), and any other failure throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$ApimName
    )
    $previousPreference = $ErrorActionPreference
    try {
        # PS 5.1 turns native stderr into ErrorRecords; collect them before reading the exit code.
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        $output = @(az apim show -g $ResourceGroup -n $ApimName --query id -o tsv --only-show-errors 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $cannotTell = "Could not tell whether API Management '$ApimName' exists in '$ResourceGroup'"
    if ($code -eq 0) {
        $ids = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($ids.Count -eq 1 -and $ids[0] -match '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ApiManagement/service/[^/]+$') { return $ids[0] }
        throw "$cannotTell`: az apim show returned no API Management resource id. The gateway template was not deployed; steps before this check are not undone. Check the Azure CLI sign-in and read access to the gateway, then rerun."
    }
    if (($output | Out-String) -match '\((ResourceNotFound|ResourceGroupNotFound)\)') { return $null }
    throw "$cannotTell (az exit $code). A redeploy that took it for a new gateway would write the template's defaults over its entitlement source, lists and network settings, so the gateway template was not deployed; steps before this check are not undone. Check the Azure CLI sign-in, read access to the gateway and connectivity, then rerun."
}

function Set-ApimNamedValue {
    <#
    .SYNOPSIS
        Creates or updates a named value, and throws if it does not land.

    .PARAMETER Secret
        Marks the value secret in API Management. The value is never echoed by
        this function either way.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$ApimName,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [switch]$Secret,
        [string]$SubscriptionId
    )

    $subscriptionArgs = @()
    if ($SubscriptionId) { $subscriptionArgs = @('--subscription', $SubscriptionId) }
    Test-ApimNamedValueLength -Id $Id -Value $Value

    if ($Value -eq '') {
        # API Management's ARM and CLI surfaces both reject an empty value when
        # creating a named value. external-idp-extra-audience also appears in an
        # <audience> element, so policy validation needs a nonempty GUID-shaped
        # sentinel that the policy explicitly treats as disabled.
        $emptySentinel = if ($Id -eq 'external-idp-extra-audience') { 'urn:disabled:claude-extra-audience' } else { ' ' }
        $sub = if ($SubscriptionId) { $SubscriptionId } else { az account show --query id -o tsv }
        if (-not $sub) { throw 'Could not determine the current Azure subscription for an empty named value write.' }
        $token = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv @subscriptionArgs
        $uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName/namedValues/$Id`?api-version=2024-05-01"
        $body = @{ properties = @{ displayName = $Id; value = $emptySentinel; secret = [bool]$Secret } } | ConvertTo-Json -Depth 5
        try {
            Invoke-RestMethod -Uri $uri -Method Put -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -Body $body | Out-Null
            return
        }
        catch {
            throw "Writing empty named value '$Id' failed. $($_.Exception.Message)"
        }
    }

    $exists = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id -o tsv --query name @subscriptionArgs 2>$null

    # Errors are captured rather than discarded, so a failure can be reported
    # with what the service actually said.
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $global:LASTEXITCODE = 0
        if ($exists) {
            az apim nv update -g $ResourceGroup --service-name $ApimName `
                --named-value-id $Id --value $Value -o none @subscriptionArgs 2>$err
        }
        else {
            $args = @('apim', 'nv', 'create', '-g', $ResourceGroup, '--service-name', $ApimName,
                      '--named-value-id', $Id, '--display-name', $Id, '--value', $Value, '-o', 'none')
            if ($Secret) { $args += @('--secret', 'true') }
            $args += $subscriptionArgs
            az @args 2>$err
        }
        $code = $LASTEXITCODE

        if ($code -ne 0) {
            $detail = (Get-Content $err -Raw -ErrorAction SilentlyContinue)
            if ($detail) { $detail = ($detail -replace '\s+', ' ').Trim() }
            throw "Writing named value '$Id' failed (az exit $code). $detail"
        }
    }
    finally {
        Remove-Item $err -Force -ErrorAction SilentlyContinue
    }
}
