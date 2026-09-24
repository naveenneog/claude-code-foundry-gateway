# Entra-only Blob REST operations. Never request account keys or mint a SAS.
function Get-ClaudeReportStorageAccount {
    param([string]$ResourceGroup,[string]$ApimName,[string]$StorageAccount)
    if($StorageAccount) {
        if($StorageAccount -notmatch '^[a-z0-9]{3,24}$') { throw 'Invalid report storage account name.' }
        return $StorageAccount
    }
    $resources=az resource list -g $ResourceGroup --resource-type Microsoft.Storage/storageAccounts -o json | ConvertFrom-Json
    if($LASTEXITCODE -ne 0) { throw 'Could not discover report storage.' }
    $match=@($resources | Where-Object { $_.tags.'claude-chargeback-gateway' -eq $ApimName })
    if($match.Count -ne 1) { throw 'No unique reports storage account. Register the schedule or pass -StorageAccount.' }
    return [string]$match[0].name
}

function Invoke-ClaudeReportBlob {
    param(
        [string]$Account,[ValidateSet('configuration','reports')][string]$Container='reports',
        [string]$Name,[ValidateSet('GET','PUT','DELETE','HEAD')][string]$Method='GET',
        [byte[]]$Bytes,[string]$ContentType='application/json',[hashtable]$ExtraHeaders=@{},
        [string]$Query,[switch]$AllowNotFound
    )
    if($Account -notmatch '^[a-z0-9]{3,24}$') { throw 'Invalid report storage account name.' }
    $segments=@($Name -split '/' | ForEach-Object {[uri]::EscapeDataString($_)})
    $uri="https://$Account.blob.core.windows.net/$Container/" + ($segments -join '/')
    if($Query) { $uri+='?'+$Query }
    $headers=@{
        Authorization='Bearer ' + (Get-ClaudeReportToken 'https://storage.azure.com/')
        'x-ms-version'='2023-11-03';'x-ms-date'=[datetime]::UtcNow.ToString('R')
    }
    if($Method -eq 'PUT' -and -not $Query) { $headers['x-ms-blob-type']='BlockBlob' }
    foreach($k in $ExtraHeaders.Keys) { $headers[$k]=$ExtraHeaders[$k] }
    $params=@{Uri=$uri;Method=$Method;Headers=$headers;UseBasicParsing=$true;TimeoutSec=120;ErrorAction='Stop'}
    if($null -ne $Bytes) { $params.Body=$Bytes; $params.ContentType=$ContentType }
    try { return Invoke-WebRequest @params }
    catch {
        $status=[int]$_.Exception.Response.StatusCode
        if($AllowNotFound -and $status -eq 404) { return $null }
        if($status -eq 412) { throw 'Configuration or report changed concurrently (HTTP 412). Read it again and retry; no change was saved.' }
        if($status -eq 409) { throw 'Report storage lease is already held (HTTP 409). Another dispatcher is running.' }
        throw "Report storage operation failed (HTTP $status). Check Entra blob roles, network access and role propagation."
    }
}

function ConvertFrom-ClaudeReportBlobText {
    param($Response)
    $text=if($Response.Content -is [byte[]]) {[Text.Encoding]::UTF8.GetString($Response.Content)} else {[string]$Response.Content}
    return $text.TrimStart([char]0xfeff)
}

function Get-ClaudeReportConfiguration {
    param([string]$Account,[switch]$AllowMissing)
    $r=Invoke-ClaudeReportBlob -Account $Account -Container configuration -Name 'settings.json' -AllowNotFound:$AllowMissing
    if(-not $r) { return $null }
    $config=ConvertTo-ClaudeChargebackConfiguration ((ConvertFrom-ClaudeReportBlobText $r) | ConvertFrom-Json)
    Test-ClaudeChargebackConfiguration $config
    [pscustomobject]@{Configuration=$config;ETag=([string]$r.Headers['ETag'])}
}

function Save-ClaudeReportConfiguration {
    param([string]$Account,$Configuration,[string]$ETag)
    Test-ClaudeChargebackConfiguration $Configuration
    $headers=if($ETag) {@{'If-Match'=$ETag}} else {@{'If-None-Match'='*'}}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Configuration | ConvertTo-Json -Depth 30))
    Invoke-ClaudeReportBlob -Account $Account -Container configuration -Name 'settings.json' -Method PUT -Bytes $bytes -ExtraHeaders $headers | Out-Null
}

function Set-ClaudeReportArchiveJson {
    param([string]$Account,[string]$Name,$Value,[hashtable]$Headers=@{})
    Invoke-ClaudeReportBlob -Account $Account -Name $Name -Method PUT -Bytes ([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30))) -ExtraHeaders $Headers | Out-Null
}

function Get-ClaudeReportArchiveJson {
    param([string]$Account,[string]$Name,[switch]$AllowMissing)
    $r=Invoke-ClaudeReportBlob -Account $Account -Name $Name -AllowNotFound:$AllowMissing
    if(-not $r) { return $null }
    return (ConvertFrom-ClaudeReportBlobText $r) | ConvertFrom-Json
}

function Get-ClaudeReportPendingBlobs {
    param([string]$Account)
    $marker=''
    do {
        $query='restype=container&comp=list&prefix=outbox%2F&maxresults=500'
        if($marker) { $query+='&marker='+[uri]::EscapeDataString($marker) }
        $r=Invoke-ClaudeReportBlob -Account $Account -Name '' -Query $query
        [xml]$xml=ConvertFrom-ClaudeReportBlobText $r
        foreach($blob in $xml.EnumerationResults.Blobs.Blob) { if($blob.Name) { [string]$blob.Name } }
        $marker=[string]$xml.EnumerationResults.NextMarker
    } while($marker)
}

function Test-ClaudeReportArtifacts {
    param([string]$Path,$Manifest)
    if($Manifest.SchemaVersion -ne 1 -or $Manifest.Status -ne 'Complete' -or -not $Manifest.Reconciliation.Matched) { throw 'Only a complete, reconciled report can be archived or emailed.' }
    if($Manifest.Month -notmatch '^\d{4}-(0[1-9]|1[0-2])$' -or $Manifest.RunId -notmatch '^[a-zA-Z0-9-]{1,80}$') { throw 'Invalid report manifest identity.' }
    foreach($file in $Manifest.Files) {
        if($file.Name -notmatch '^[a-z0-9-]+\.(csv|html)$') { throw 'Unsafe report artifact path.' }
        $full=Join-Path $Path $file.Name
        if(-not (Test-Path $full) -or (Get-FileHash $full -Algorithm SHA256).Hash -ne $file.Sha256) { throw 'Report artifact hash mismatch. Regenerate rather than sending altered files.' }
    }
}

function Save-ClaudeReportArchive {
    param([string]$Account,[string]$Path,$Manifest)
    Test-ClaudeReportArtifacts $Path $Manifest
    $prefix="runs/$($Manifest.Month)/$($Manifest.RunId)"
    $existing=Get-ClaudeReportArchiveJson $Account "$prefix/manifest.json" -AllowMissing
    if($existing) {
        if(($existing.Files | ConvertTo-Json -Depth 6 -Compress) -ne ($Manifest.Files | ConvertTo-Json -Depth 6 -Compress)) {
            throw 'Archive run ID already exists with different artifacts. Regenerate as a new run.'
        }
        return $prefix
    }
    foreach($file in $Manifest.Files) {
        $type=if($file.Name -like '*.csv') {'text/csv; charset=utf-8'} else {'text/html; charset=utf-8'}
        Invoke-ClaudeReportBlob -Account $Account -Name "$prefix/$($file.Name)" -Method PUT `
            -Bytes ([IO.File]::ReadAllBytes((Join-Path $Path $file.Name))) -ContentType $type | Out-Null
    }
    Set-ClaudeReportArchiveJson $Account "$prefix/manifest.json" $Manifest @{'If-None-Match'='*'}
    return $prefix
}
