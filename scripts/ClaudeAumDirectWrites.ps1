function Invoke-AumVerifiedWrite {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Before,
        [System.Collections.IDictionary]$After,
        [scriptblock]$Read,
        [scriptblock]$Write,
        [scriptblock]$Remove,
        [scriptblock]$Operation
    )
    $keys = @($After.Keys)
    $current = & $Read
    foreach ($key in $keys) {
        if ($current.Contains($key) -ne $Before.Contains($key) -or
            ($Before.Contains($key) -and [string]$current[$key] -cne [string]$Before[$key])) {
            throw 'Named values changed before the write. Refresh and preview again.'
        }
    }
    $changed = @($keys | Where-Object {
        -not $current.Contains($_) -or [string]$current[$_] -cne [string]$After[$_]
    })
    if (-not $changed.Count) { return @{ verified=$true; rollback=$false; changed=@(); unchanged=$true } }
    try {
        & $Operation | Out-Null
        $current = & $Read
        foreach ($key in $keys) {
            if (-not $current.Contains($key) -or [string]$current[$key] -cne [string]$After[$key]) {
                throw 'Named value read-back mismatch.'
            }
        }
        return @{ verified=$true; rollback=$false; changed=@($changed) }
    }
    catch {
        $recovery = @()
        [array]::Reverse($keys)
        foreach ($key in $keys) {
            try {
                $current = & $Read
                $existed = $Before.Contains($key)
                if (($existed -and $current.Contains($key) -and [string]$current[$key] -ceq [string]$Before[$key]) -or
                    (-not $existed -and -not $current.Contains($key))) { continue }
                if (-not $current.Contains($key) -or [string]$current[$key] -cne [string]$After[$key]) {
                    throw 'Concurrent state differs from both before and expected values.'
                }
                if ($existed) { & $Write $key ([string]$Before[$key]) | Out-Null }
                else { & $Remove $key | Out-Null }
                $verified = & $Read
                if ($verified.Contains($key) -ne $existed -or
                    ($existed -and [string]$verified[$key] -cne [string]$Before[$key])) {
                    throw 'Restore read-back failed.'
                }
            }
            catch { $recovery += [string]$key }
        }
        if ($recovery.Count) {
            throw ('Change failed; manual recovery required for named values: ' + ($recovery -join ', ') +
                   '. A conflicting value was not overwritten. Inspect current state before any retry.')
        }
        throw 'Change failed; previous values restored and verified. Refresh before retrying.'
    }
}

function Get-AumNamedValueMap {
    param([string]$ResourceGroup, [string]$ApimName)
    $raw = az apim nv list -g $ResourceGroup --service-name $ApimName -o json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read named-value state; no safe write or rollback is possible.' }
    $map = @{}
    foreach ($value in @($raw | ConvertFrom-Json)) {
        if (-not $value.secret) { $map[[string]$value.name] = [string]$value.value }
        elseif ($value.name -match '^(bu-|quota-|tpm-|models-|allow-|turnstile-integration$)') {
            throw 'Governance named values must be nonsecret. Inspect the gateway configuration.'
        }
    }
    return $map
}
