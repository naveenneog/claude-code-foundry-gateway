function Add-Result([string]$Step, [bool]$Ok, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ step = $Step; ok = $Ok; detail = $Detail })
    $colour = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1} {2}" -f $(if ($Ok) { 'OK' } else { 'FAIL' }), $Step, $Detail) -ForegroundColor $colour
}
function Assert-Form([string]$Name, [string]$Value, [string]$Pattern) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch $Pattern) { throw "-$Name '$Value' is not in the accepted form; nothing was created." }
}
function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $trimmed = $Path.Trim().TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    try { return [IO.Path]::GetFullPath($trimmed).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    catch { return $trimmed }
}
function Assert-AzProfileAllowed([switch]$UseCurrentAzLogin) {
    $azProfile = Get-NormalizedPath $env:AZURE_CONFIG_DIR
    $defaultAzProfile = Get-NormalizedPath (Join-Path $HOME '.azure')
    if (-not $UseCurrentAzLogin -and [string]::IsNullOrWhiteSpace($azProfile)) {
        throw 'Set AZURE_CONFIG_DIR to an isolated profile signed in for this test, or pass -UseCurrentAzLogin to use the current Azure CLI profile; nothing was created.'
    }
    if (-not $UseCurrentAzLogin -and $azProfile -and [string]::Equals($azProfile, $defaultAzProfile, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'AZURE_CONFIG_DIR points at the default Azure CLI profile. Set it to an isolated profile signed in for this test, or pass -UseCurrentAzLogin to use the current Azure CLI profile; nothing was created.'
    }
}
function Invoke-Az([string[]]$Arguments, [switch]$AllowFailure) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = @(& az @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $saved }
    $text = (@($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n").Trim()
    if ($code -ne 0 -and -not $AllowFailure) {
        $errors = (@($output | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) -join ' ').Trim()
        if (-not $errors) { $errors = $text }
        throw "az $($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' ') failed (exit $code): $errors"
    }
    if ($code -ne 0) { return $null }
    return $text
}
function Invoke-TeardownAz([string]$Label, [string[]]$Arguments, [string]$Removal, [System.Collections.Generic.List[string]]$Left) {
    $out = Invoke-Az $Arguments -AllowFailure
    if ($null -eq $out) {
        $Left.Add("$Label was not deleted. Remove with: $Removal")
        return $false
    }
    return $true
}
function Invoke-GatewayRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$BodyObject,
        [int]$TimeoutSec = 120
    )
    $token = Invoke-Az @('account', 'get-access-token', '--resource', 'https://cognitiveservices.azure.com', '--query', 'accessToken', '-o', 'tsv')
    if (-not $token) { throw 'No access token for https://cognitiveservices.azure.com; the request was not sent.' }
    $body = $BodyObject | ConvertTo-Json -Depth 40 -Compress
    $headers = @{ Authorization = "Bearer $token"; 'anthropic-version' = '2023-06-01'; 'Content-Type' = 'application/json' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $status = 0
    $content = ''
    try {
        $response = Invoke-WebRequest -Uri $Url -Method Post -Headers $headers -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -TimeoutSec $TimeoutSec
        $status = [int]$response.StatusCode
        $content = [string]$response.Content
    }
    catch {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $content = $_.Exception.Message
    }
    $clock.Stop()
    $errorType = ''
    try { $json = $content | ConvertFrom-Json -Depth 20; $errorType = [string]$json.error.type } catch {}
    [pscustomobject]@{ StatusCode = $status; ErrorType = $errorType; Content = $content; LatencyMs = [int]$clock.ElapsedMilliseconds }
}
function Get-GatewayStatus([string]$Url, [string]$ModelName) {
    $body = @{ model = $ModelName; max_tokens = 16; messages = @(@{ role = 'user'; content = 'Hello, please say OK.' }) }
    (Invoke-GatewayRequest -Url $Url -BodyObject $body).StatusCode
}
function Wait-GatewayStatus([string]$Url, [string]$ModelName, [int]$Expected, [string]$Step) {
    $deadline = (Get-Date).AddSeconds($ChangeWaitSeconds)
    $seen = @()
    do {
        $status = Get-GatewayStatus -Url $Url -ModelName $ModelName
        $seen += $status
        if ($status -eq $Expected) { Add-Result $Step $true "HTTP $status after $($seen.Count) request(s)"; return }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    Add-Result $Step $false "expected HTTP $Expected; saw $($seen -join ', ') over $ChangeWaitSeconds s"
    throw "$Step did not reach HTTP $Expected."
}
function Wait-Membership([string]$GroupId, [string]$MemberId, [string]$Expected) {
    $deadline = (Get-Date).AddSeconds($ChangeWaitSeconds)
    do {
        $value = Invoke-Az @('ad', 'group', 'member', 'check', '--group', $GroupId, '--member-id', $MemberId, '--query', 'value', '-o', 'tsv')
        if ($value -eq $Expected) { return }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    throw "Microsoft Graph did not report membership '$Expected' for $MemberId in $GroupId within $ChangeWaitSeconds s."
}
function Split-NonEmptyLines([AllowEmptyString()][string]$Text) {
    return @(([string]$Text) -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
