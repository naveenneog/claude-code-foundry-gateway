<#
.SYNOPSIS
    Shared read-only diagnostics helpers for P66.
#>

$script:ClaudeDiagnoseResults = @()

function New-ClaudeDiagnoseCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('PASS','WARN','FAIL','SKIP')][string]$Status,
        [string]$Evidence = '',
        [string]$Fix = '',
        [string]$PortalPath = ''
    )
    [pscustomobject][ordered]@{
        Name = $Name
        Status = $Status
        Evidence = $Evidence
        Fix = $Fix
        PortalPath = $PortalPath
    }
}

function Add-ClaudeDiagnoseCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('PASS','WARN','FAIL','SKIP')][string]$Status,
        [string]$Evidence = '',
        [string]$Fix = '',
        [string]$PortalPath = ''
    )
    $check = New-ClaudeDiagnoseCheck -Name $Name -Status $Status -Evidence $Evidence -Fix $Fix -PortalPath $PortalPath
    $script:ClaudeDiagnoseResults += $check
    return $check
}

function ConvertFrom-ClaudeDiagnoseJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { return ($Text | ConvertFrom-Json) } catch { return $null }
}

function Invoke-ClaudeDiagnoseCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $out = ''
    try {
        $out = & $FilePath @ArgumentList 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out; Error = '' }
    }
    catch {
        [pscustomobject]@{ ExitCode = 999; Output = $out; Error = $_.Exception.Message }
    }
}

function Get-ClaudeDiagnoseAz {
    param([string[]]$Arguments)
    Invoke-ClaudeDiagnoseCommand -FilePath 'az' -ArgumentList $Arguments
}

function Get-ClaudeDiagnoseProperty {
    param($Object, [string]$Path)
    $value = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $value) { return $null }
        if ($value -is [System.Collections.IDictionary]) {
            if (-not $value.Contains($part)) { return $null }
            $value = $value[$part]
        } elseif ($value.PSObject.Properties.Name -contains $part) {
            $value = $value.$part
        } else { return $null }
    }
    return $value
}

function ConvertTo-ClaudeDiagnoseRedactedText {
    param([AllowNull()][object]$InputObject)
    $text = if ($InputObject -is [string]) { $InputObject } else { $InputObject | ConvertTo-Json -Depth 20 }
    if ($null -eq $text) { return '' }
    $text = [string]$text
    $text = [regex]::Replace($text, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '<redacted-email>')
    $text = [regex]::Replace($text, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<redacted-guid>')
    $text = [regex]::Replace($text, '(?i)\b(subscriptions/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<redacted-subscription>')
    $text = [regex]::Replace($text, '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\b', '<redacted-jwt>')
    $text = [regex]::Replace($text, '(?i)\b(sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9_]{20,}|[a-z0-9_=-]{32,}\.[a-z0-9_=-]{16,}\.[a-z0-9_=-]{8,})\b', '<redacted-token>')
    $text = [regex]::Replace($text, '(?i)("?(accessToken|refreshToken|idToken|token|Authorization)"?\s*[:=]\s*"?)([^,"\r\n ]+)', '$1<redacted-token>')
    return $text
}

function Write-ClaudeDiagnoseSupportBundle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Results,
        [hashtable]$Files = @{},
        [hashtable]$Data = @{}
    )
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-diagnose-bundle-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $included = [System.Collections.Generic.List[object]]::new()
    try {
        $resultsPath = Join-Path $temp 'results.json'
        [IO.File]::WriteAllText($resultsPath, (ConvertTo-ClaudeDiagnoseRedactedText ([ordered]@{ generatedUtc = [DateTime]::UtcNow.ToString('o'); checks = $Results })), (New-Object Text.UTF8Encoding($false)))
        $included.Add([pscustomobject]@{ file = 'results.json'; source = 'diagnostics results'; secretPolicy = 'redacted' })

        foreach ($key in $Data.Keys) {
            $name = ($key -replace '[^A-Za-z0-9_.-]', '_') + '.json'
            [IO.File]::WriteAllText((Join-Path $temp $name), (ConvertTo-ClaudeDiagnoseRedactedText $Data[$key]), (New-Object Text.UTF8Encoding($false)))
            $included.Add([pscustomobject]@{ file = $name; source = $key; secretPolicy = 'redacted' })
        }

        foreach ($key in $Files.Keys) {
            $source = [string]$Files[$key]
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $name = ($key -replace '[^A-Za-z0-9_.-]', '_')
            if (-not [IO.Path]::HasExtension($name)) { $name += '.txt' }
            $raw = Get-Content -LiteralPath $source -Raw
            [IO.File]::WriteAllText((Join-Path $temp $name), (ConvertTo-ClaudeDiagnoseRedactedText $raw), (New-Object Text.UTF8Encoding($false)))
            $included.Add([pscustomobject]@{ file = $name; source = $source; secretPolicy = 'redacted' })
        }

        $manifest = [ordered]@{
            generatedUtc = [DateTime]::UtcNow.ToString('o')
            redaction = 'emails, object ids, subscription ids, JWTs and token-like strings are masked'
            included = @($included)
        }
        [IO.File]::WriteAllText((Join-Path $temp 'manifest.json'), ($manifest | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $Path -Force
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Write-ClaudeDiagnoseResults {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [switch]$AsJson
    )
    if ($AsJson) {
        [ordered]@{ checkedUtc = [DateTime]::UtcNow.ToString('o'); checks = $Results } | ConvertTo-Json -Depth 8
        return
    }
    foreach ($r in $Results) {
        $color = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' } }
        Write-Host ("  {0,-4} {1}" -f $r.Status, $r.Name) -ForegroundColor $color
        if ($r.Evidence) { Write-Host ("       Evidence: {0}" -f (ConvertTo-ClaudeDiagnoseRedactedText $r.Evidence)) -ForegroundColor DarkGray }
        if ($r.Fix) { Write-Host ("       Fix: {0}" -f $r.Fix) -ForegroundColor DarkGray }
        if ($r.PortalPath) { Write-Host ("       Portal: {0}" -f $r.PortalPath) -ForegroundColor DarkGray }
    }
}

function Get-ClaudeDiagnoseExitCode {
    param([object[]]$Results, [ValidateSet('fail','warn')][string]$FailOn = 'fail')
    if (@($Results | Where-Object Status -eq 'FAIL').Count) { return 1 }
    if ($FailOn -eq 'warn' -and @($Results | Where-Object Status -eq 'WARN').Count) { return 1 }
    return 0
}

function Test-ClaudeDiagnoseUrl {
    param([string]$Url)
    return ($Url -match '^https://[^/\s]+')
}
