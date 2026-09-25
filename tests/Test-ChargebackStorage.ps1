param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Configuration','Storage')) {. (Join-Path $SourceRoot "scripts\ClaudeChargeback$helper.ps1")}
$checks=0;$fail=0
function Assert($Name,$Condition) {$script:checks++;if(-not $Condition){$script:fail++;Write-Host "FAIL: $Name"}}
function Refuses($Name,[scriptblock]$Action,$Pattern) {
    $caught=$false
    try{& $Action|Out-Null}catch{$caught=$_.Exception.Message -match $Pattern}
    Assert $Name $caught
}
$script:blobs=@{};$script:puts=0;$script:lastHeaders=@{}
$xmlWithBom=[pscustomobject]@{Content=([string][char]0xfeff+'<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs /></EnumerationResults>')}
$text=ConvertFrom-ClaudeReportBlobText $xmlWithBom
Assert 'Blob XML preamble is removed before string parsing' (-not $text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal))
$bytesWithBom=[pscustomobject]@{Content=[Text.Encoding]::UTF8.GetBytes($xmlWithBom.Content)}
Assert 'byte responses use the same BOM handling' (-not (ConvertFrom-ClaudeReportBlobText $bytesWithBom).StartsWith([string][char]0xfeff,[StringComparison]::Ordinal))
function Invoke-ClaudeReportBlob {
    param($Account,$Container='reports',$Name,$Method='GET',$Bytes,$ContentType,$ExtraHeaders=@{},[switch]$AllowNotFound)
    $script:lastHeaders=$ExtraHeaders
    if($Method -eq 'PUT') {
        if($ExtraHeaders['If-None-Match'] -eq '*' -and $script:blobs.ContainsKey($Name)){throw 'HTTP 412'}
        $script:puts++;$script:blobs[$Name]=[Text.Encoding]::UTF8.GetString($Bytes);return
    }
    if(-not $script:blobs.ContainsKey($Name)) {if($AllowNotFound){return $null};throw 'HTTP 404'}
    [pscustomobject]@{Content=$script:blobs[$Name];Headers=@{ETag='"v1"'}}
}
$c=New-ClaudeChargebackConfiguration @('contoso.com')
Save-ClaudeReportConfiguration 'contoso' $c ''
Assert 'create is conditional, never clobbers an existing document' ($script:lastHeaders['If-None-Match'] -eq '*')
$stored=Get-ClaudeReportConfiguration 'contoso'
Assert 'configuration reads ETag unchanged' ($stored.ETag -eq '"v1"')
Save-ClaudeReportConfiguration 'contoso' $stored.Configuration $stored.ETag
Assert 'update preserves lost-update protection' ($script:lastHeaders['If-Match'] -eq '"v1"')
$c.AllowedDomains=@()
Refuses 'invalid config never written' {Save-ClaudeReportConfiguration 'contoso' $c '"v1"'} 'domain'
$path=Join-Path $SourceRoot ('.chargeback-storage-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $path | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $path 'engineering.csv'),"Person,Requests`r`nalice@contoso.com,1`r`n")
    $m=[pscustomobject]@{SchemaVersion=1;Status='Complete';Reconciliation=@{Matched=$true};Month='2026-08';RunId='run1';Sends=@()
        Files=@([pscustomobject]@{Name='engineering.csv';Sha256=(Get-FileHash (Join-Path $path 'engineering.csv') -Algorithm SHA256).Hash.ToLowerInvariant()})}
    $prefix=Save-ClaudeReportArchive 'contoso' $path $m
    Assert 'archive has run-qualified path' ($prefix -eq 'runs/2026-08/run1')
    Assert 'archive artifact exists' ($script:blobs.ContainsKey("$prefix/engineering.csv"))
    $archived=$script:blobs["$prefix/manifest.json"] | ConvertFrom-Json
    $archived.Sends=@([pscustomobject]@{Status='Succeeded';MessageId='fixture'})
    $script:blobs["$prefix/manifest.json"]=$archived | ConvertTo-Json -Depth 20 -Compress
    $before=$script:puts
    Save-ClaudeReportArchive 'contoso' $path $m | Out-Null
    Assert 'repeat archive never erases concurrent send receipts' (($script:blobs["$prefix/manifest.json"] | ConvertFrom-Json).Sends.Count -eq 1)
    Assert 'repeat archive is read-only' ($script:puts -eq $before)
    [IO.File]::AppendAllText((Join-Path $path 'engineering.csv'),'altered')
    Refuses 'tampered report never sent' {Test-ClaudeReportArtifacts $path $m} 'hash mismatch'
    $m.Files[0].Name='../outside.csv'
    Refuses 'manifest path traversal rejected' {Test-ClaudeReportArtifacts $path $m} 'path'
    $m.Status='Invalidated'
    Refuses 'invalidated saved-function snapshot refused' {Test-ClaudeReportArtifacts $path $m} 'complete'
}
finally {Remove-Item $path -Recurse -Force}
if($fail){throw "$fail of $checks storage assertions failed."}
Write-Host "$checks chargeback storage assertions passed."
