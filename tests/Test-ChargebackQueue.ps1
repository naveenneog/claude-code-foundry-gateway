param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Configuration','Storage','Email','Outbox')) {. (Join-Path $SourceRoot "scripts\ClaudeChargeback$helper.ps1")}
$checks=0;$fail=0
function Assert($Name,$Condition) {$script:checks++;if(-not $Condition){$script:fail++;Write-Host "FAIL: $Name"}}
$script:blobData=@{};$script:zipVersion=0
function Invoke-ClaudeReportBlob {
    param($Account,$Container,$Name,$Method='GET',$Bytes,$ContentType,$ExtraHeaders,[switch]$AllowNotFound)
    if($Method -eq 'PUT') {$script:blobData[$Name]=$Bytes;return}
    if($script:blobData.ContainsKey($Name)) {return [pscustomobject]@{Content=$script:blobData[$Name];Headers=@{ETag='fixture'}}}
    if($AllowNotFound) {return}
    throw 'Fixture blob missing'
}
function New-ClaudeReportAttachments {
    param($CsvPaths,$OutputPath)
    # ZIP metadata/compressor versions can change bytes without changing any CSV record.
    $script:zipVersion++
    $path=Join-Path $OutputPath 'engineering-part-0001.zip'
    [IO.File]::WriteAllText($path,"ZIP representation $script:zipVersion")
    return ,@([pscustomobject]@{Name='engineering-part-0001.zip';Path=$path;ContentType='application/zip';Bytes=(Get-Item $path).Length})
}
$path=Join-Path $SourceRoot ('.chargeback-queue-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $path | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $path 'engineering.csv'),"Person,Requests`r`nalice@contoso.com,1`r`n")
    [IO.File]::WriteAllText((Join-Path $path 'engineering.html'),'<p>Contoso Engineering</p>')
    $files=@(Get-ChildItem $path -File | ForEach-Object {[pscustomobject]@{Name=$_.Name;Sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
    $manifest=[pscustomobject]@{SchemaVersion=1;Status='Complete';Reconciliation=@{Matched=$true};Month='2026-08';RunId='run1'
        Formats=@('CSV','HTML');BusinessUnits=@('engineering');Files=$files}
    $config=New-ClaudeChargebackConfiguration @('contoso.com')
    $config.Units.engineering=@('alice@contoso.com')
    $first=Add-ClaudeReportOutbox contoso $path $manifest $config 'runs/2026-08/run1'
    $item=Get-ClaudeReportArchiveJson contoso 'outbox/run1-engineering-0-0.json'
    Assert 'first enqueue creates exactly one scoped message' ($first -eq 1 -and $item.Scope -eq 'engineering')
    Assert 'queue never stores full recipient addresses' (([Text.Encoding]::UTF8.GetString($script:blobData['outbox/run1-engineering-0-0.json'])) -notmatch '@contoso')
    $repeat=Add-ClaudeReportOutbox contoso $path $manifest $config 'runs/2026-08/run1'
    Assert 'repeat enqueue creates no duplicate message' ($repeat -eq 0)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$actual=([BitConverter]::ToString($sha.ComputeHash($script:blobData[$item.Attachments[0].Blob]))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    Assert 'repeat queueing cannot overwrite pending compressed bytes' ($actual -eq $item.Attachments[0].Sha256)
    $resend=Add-ClaudeReportOutbox contoso $path $manifest $config 'runs/2026-08/run1' -Resend
    Assert 'explicit resend creates one new message' ($resend -eq 1)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$actual=([BitConverter]::ToString($sha.ComputeHash($script:blobData[$item.Attachments[0].Blob]))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    Assert 'resend also leaves the first message immutable' ($actual -eq $item.Attachments[0].Sha256)
}
finally {Remove-Item $path -Recurse -Force}
if($fail) {throw "$fail of $checks queue assertions failed."}
Write-Host "$checks chargeback queue assertions passed."
