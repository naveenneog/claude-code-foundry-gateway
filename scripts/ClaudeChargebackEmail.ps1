# Pure email and attachment construction. Delivery authorization is checked by the outbox.
function Read-ClaudeReportCsvRecord {
    param($Reader)
    $line=$Reader.ReadLine()
    if ($null -eq $line) { return $null }
    $b=New-Object Text.StringBuilder
    [void]$b.Append($line)
    $quotes=([regex]::Matches($line,'"')).Count
    while($quotes % 2 -ne 0) {
        $line=$Reader.ReadLine()
        if($null -eq $line) { throw 'CSV ends inside a quoted field.' }
        [void]$b.Append("`r`n").Append($line)
        $quotes+=([regex]::Matches($line,'"')).Count
    }
    return $b.ToString()
}

function New-ClaudeReportAttachments {
    param([string[]]$CsvPaths,[string]$OutputPath,[ValidateRange(10000,4000000)][int]$PartBytes=3000000)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $result=New-Object 'System.Collections.Generic.List[object]'
    foreach($path in $CsvPaths) {
        $file=Get-Item $path
        if($file.Extension -ne '.csv') { throw 'Only report CSV files can be attached.' }
        if($file.Length -le $PartBytes) {
            $result.Add([pscustomobject]@{Name=$file.Name;Path=$file.FullName;ContentType='text/csv';Bytes=$file.Length})
            continue
        }
        $reader=New-Object IO.StreamReader($file.FullName)
        $part=0; $writer=$null
        try {
            $header=Read-ClaudeReportCsvRecord $reader
            $record=Read-ClaudeReportCsvRecord $reader
            while($null -ne $record) {
                $part++
                $name="$($file.BaseName)-part-$($part.ToString('D4'))"
                $partPath=Join-Path $OutputPath "$name.csv"
                $writer=New-Object IO.StreamWriter($partPath,$false,(New-Object Text.UTF8Encoding($true)))
                $writer.WriteLine($header)
                $bytes=[Text.Encoding]::UTF8.GetByteCount($header)+5
                while($null -ne $record) {
                    $length=[Text.Encoding]::UTF8.GetByteCount($record)+2
                    if($length -gt $PartBytes-1024) { throw 'A CSV record exceeds the attachment part size. Use the private archive instead of email.' }
                    if($bytes+$length -gt $PartBytes) { break }
                    $writer.WriteLine($record); $bytes+=$length
                    $record=Read-ClaudeReportCsvRecord $reader
                }
                $writer.Dispose(); $writer=$null
                $zipPath=Join-Path $OutputPath "$name.zip"
                $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
                try { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$partPath,"$name.csv",[IO.Compression.CompressionLevel]::Optimal) | Out-Null }
                finally { $zip.Dispose() }
                Remove-Item $partPath
                $result.Add([pscustomobject]@{Name="$name.zip";Path=$zipPath;ContentType='application/zip';Bytes=(Get-Item $zipPath).Length})
            }
        }
        finally { if($writer) {$writer.Dispose()}; $reader.Dispose() }
    }
    return ,$result.ToArray()
}

function New-ClaudeReportEmailBody {
    param([string]$Sender,[string[]]$Recipients,[string]$Subject,[string]$Html,[object[]]$Attachments)
    if($Recipients.Count -lt 1 -or $Recipients.Count -gt 50) { throw 'Email needs 1-50 recipients per message.' }
    if($Subject -match '[\r\n]' -or $Sender -match '[\r\n]') { throw 'Email header contains a newline.' }
    $body=[ordered]@{
        senderAddress=$Sender
        recipients=@{bcc=@($Recipients | ForEach-Object {@{address=$_}})}
        content=@{subject=$Subject;html=$Html;plainText='Monthly Claude gateway usage. List-price showback, not an invoice. See the HTML summary and CSV attachment. Cache writes are unknown; enforcement is a delayed brake.'}
        attachments=@($Attachments); userEngagementTrackingDisabled=$true
    }
    if([Text.Encoding]::UTF8.GetByteCount(($body | ConvertTo-Json -Depth 12 -Compress)) -gt 9500000) { throw 'Encoded email request exceeds the safe 9.5 MB size limit.' }
    return $body
}

function Get-ClaudeReportAddressHash {
    param([string]$Address)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Address.ToLowerInvariant())))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Invoke-ClaudeReportEmail {
    param([string]$Endpoint,$Body,[string]$OperationId,[switch]$PollOnly)
    if($Endpoint -notmatch '^https://[a-z0-9.-]+\.communication\.azure\.com/?$') { throw 'Email endpoint must be an Azure Communication Services HTTPS endpoint.' }
    if($OperationId -notmatch '^[0-9a-f-]{36}$') { throw 'Invalid email operation ID.' }
    $headers=@{Authorization='Bearer ' + (Get-ClaudeReportToken 'https://communication.azure.com');'Operation-Id'=$OperationId}
    $base=$Endpoint.TrimEnd('/')
    try {
        if($PollOnly) {
            return Invoke-RestMethod -Uri "$base/emails/operations/$OperationId`?api-version=2023-03-31" -Headers $headers -Method Get
        }
        $json=$Body | ConvertTo-Json -Depth 12 -Compress
        return Invoke-RestMethod -Uri "$base/emails:send?api-version=2023-03-31" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
    }
    catch {
        $status=[int]$_.Exception.Response.StatusCode
        throw "ACS email operation failed (HTTP $status; operation $OperationId). No recipient addresses were logged."
    }
}
