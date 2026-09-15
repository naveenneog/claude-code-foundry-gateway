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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$ApimName,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $v = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id --query value -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v) { return $null }
    return $v
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
        [switch]$Secret
    )

    Test-ApimNamedValueLength -Id $Id -Value $Value

    $exists = az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id $Id -o tsv --query name 2>$null

    # Errors are captured rather than discarded, so a failure can be reported
    # with what the service actually said.
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $global:LASTEXITCODE = 0
        if ($exists) {
            az apim nv update -g $ResourceGroup --service-name $ApimName `
                --named-value-id $Id --value $Value -o none 2>$err
        }
        else {
            $args = @('apim', 'nv', 'create', '-g', $ResourceGroup, '--service-name', $ApimName,
                      '--named-value-id', $Id, '--display-name', $Id, '--value', $Value, '-o', 'none')
            if ($Secret) { $args += @('--secret', 'true') }
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
