# Durable outbox: payloads contain scope and recipient hashes, never recipient address lists.
function Add-ClaudeReportOutbox {
    param([string]$Account,[string]$ReportPath,$Manifest,$Configuration,[string]$Prefix,[string[]]$Scope,[switch]$Resend)
    Test-ClaudeChargebackConfiguration $Configuration
    Test-ClaudeReportArtifacts $ReportPath $Manifest
    if(-not $Configuration.DeliveryEnabled) { throw 'Email delivery is disabled in report settings.' }
    if(@($Manifest.Formats | Sort-Object -Unique).Count -ne 2) { throw 'Email requires CSV and HTML artifacts.' }
    $scopes=@($Manifest.BusinessUnits)+@('all')
    if($Scope) {
        foreach($s in $Scope) { if($s -notin $scopes) {throw 'Requested email scope is not present in the report.'} }
        $scopes=@($Scope | Sort-Object -Unique)
    }
    $queued=0
    $scratch=Join-Path $ReportPath ('.delivery-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $scratch | Out-Null
    try {
        foreach($scopeName in $scopes) {
            $recipients=Get-ClaudeChargebackRecipients $Configuration $scopeName
            if(-not $recipients.Count) { continue }
            $csvNames=if($scopeName -eq 'all') { @('summary.csv')+@($Manifest.BusinessUnits | ForEach-Object {"$_.csv"}) } else { @("$scopeName.csv") }
            $htmlName=if($scopeName -eq 'all') {'index.html'} else {"$scopeName.html"}
            $partDir=Join-Path $scratch $scopeName
            New-Item -ItemType Directory $partDir | Out-Null
            $paths=@($csvNames | ForEach-Object {Join-Path $ReportPath $_})
            $attachments=New-ClaudeReportAttachments -CsvPaths $paths -OutputPath $partDir
            $groups=New-Object 'System.Collections.Generic.List[object]'
            $group=New-Object 'System.Collections.Generic.List[object]';$size=[long]0
            foreach($a in $attachments) {
                $encoded=[long]([math]::Ceiling($a.Bytes/3.0)*4)+256
                if($size+$encoded -gt 6000000 -and $group.Count) { $groups.Add($group.ToArray());$group.Clear();$size=0 }
                $blob="$Prefix/delivery/$scopeName/$($a.Name)"
                Invoke-ClaudeReportBlob -Account $Account -Name $blob -Method PUT -ContentType $a.ContentType -Bytes ([IO.File]::ReadAllBytes($a.Path)) | Out-Null
                $group.Add([pscustomobject]@{Name=$a.Name;Blob=$blob;ContentType=$a.ContentType;Sha256=(Get-FileHash $a.Path -Algorithm SHA256).Hash.ToLowerInvariant()})
                $size+=$encoded
            }
            if($group.Count) {$groups.Add($group.ToArray())}
            $htmlFile=@($Manifest.Files | Where-Object Name -eq $htmlName)
            if($htmlFile.Count -ne 1) {throw 'Expected HTML artifact is missing from the report manifest.'}
            for($offset=0;$offset -lt $recipients.Count;$offset+=50) {
                $end=[math]::Min($offset+49,$recipients.Count-1)
                $hashes=@($recipients[$offset..$end] | ForEach-Object {Get-ClaudeReportAddressHash $_})
                for($part=0;$part -lt $groups.Count;$part++) {
                    $key="$($Manifest.RunId)-$scopeName-$offset-$part"
                    if($Resend) { $key+='-'+[guid]::NewGuid().ToString('N').Substring(0,8) }
                    $receipt=Get-ClaudeReportArchiveJson $Account "$Prefix/receipts/$key.json" -AllowMissing
                    if($receipt) { continue }
                    $name="outbox/$key.json"
                    if(Get-ClaudeReportArchiveJson $Account $name -AllowMissing) {continue}
                    $item=[ordered]@{
                        Version=1;Key=$key;RunPrefix=$Prefix;Month=$Manifest.Month;Scope=$scopeName;RecipientHashes=$hashes
                        HtmlBlob="$Prefix/$htmlName";HtmlSha256=$htmlFile[0].Sha256;Attachments=@($groups[$part])
                        Part=$part+1;Parts=$groups.Count;Status='Pending';OperationId=[guid]::NewGuid().ToString()
                        RecipientCount=0;CreatedUtc=[datetime]::UtcNow.ToString('o');SubmittedUtc=$null;CompletedUtc=$null;LastError=$null
                    }
                    Set-ClaudeReportArchiveJson $Account $name $item @{'If-None-Match'='*'}
                    $queued++
                }
            }
        }
    }
    finally { Remove-Item $scratch -Recurse -Force }
    return $queued
}

function Complete-ClaudeReportOutbox {
    param([string]$Account,[string]$Name,$Item)
    $record=[pscustomobject][ordered]@{
        Key=$Item.Key;Unit=$Item.Scope;MessageId=$Item.OperationId;RecipientCount=$Item.RecipientCount
        Part=$Item.Part;Parts=$Item.Parts;Status=$Item.Status;SubmittedUtc=$Item.SubmittedUtc
        CompletedUtc=$Item.CompletedUtc;Error=$Item.LastError
    }
    Set-ClaudeReportArchiveJson $Account "$($Item.RunPrefix)/receipts/$($Item.Key).json" $record
    $manifest=Get-ClaudeReportArchiveJson $Account "$($Item.RunPrefix)/manifest.json"
    $manifest.Sends=@($manifest.Sends | Where-Object Key -ne $record.Key)+@($record)
    Set-ClaudeReportArchiveJson $Account "$($Item.RunPrefix)/manifest.json" $manifest
    Invoke-ClaudeReportBlob -Account $Account -Name $Name -Method DELETE | Out-Null
}

function Get-ClaudeReportBlobBytes {
    param([string]$Account,[string]$Name,[string]$Sha256)
    $r=Invoke-ClaudeReportBlob -Account $Account -Name $Name
    $bytes=if($r.Content -is [byte[]]) {$r.Content} else {[Text.Encoding]::UTF8.GetBytes([string]$r.Content)}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$actual=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}
    finally {$sha.Dispose()}
    if($actual -ne $Sha256) {throw 'Archived email artifact hash mismatch. Delivery stopped.'}
    return ,$bytes
}

function Invoke-ClaudeReportOutbox {
    param([string]$Account)
    $stored=Get-ClaudeReportConfiguration $Account
    $configuration=$stored.Configuration
    if(-not $configuration.DeliveryEnabled) {return [pscustomobject]@{Status='Disabled'}}
    $names=@(Get-ClaudeReportPendingBlobs $Account | Sort-Object)
    if(-not $names.Count) {return [pscustomobject]@{Status='Empty'}}
    # The infinite lease survives a hung/crashed dispatcher. Never auto-break it and risk two
    # sends: an administrator checks executions, then breaks a stale lease explicitly.
    $lease=[guid]::NewGuid().ToString()
    try {
        Invoke-ClaudeReportBlob -Account $Account -Name 'state/dispatch.json' -Method PUT -Query 'comp=lease' `
            -ExtraHeaders @{'x-ms-lease-action'='acquire';'x-ms-lease-duration'='-1';'x-ms-proposed-lease-id'=$lease} | Out-Null
    }
    catch {
        if($_.Exception.Message -match '409') {return [pscustomobject]@{Status='Busy'}}
        throw
    }
    try {
        $state=Get-ClaudeReportArchiveJson $Account 'state/dispatch.json'
        $now=[datetime]::UtcNow
        if($state.NextActionUtc -and ([datetime]$state.NextActionUtc).ToUniversalTime() -gt $now) {return [pscustomobject]@{Status='RateLimited';NextActionUtc=$state.NextActionUtc}}
        $name=$names[0]
        $item=Get-ClaudeReportArchiveJson $Account $name -AllowMissing
        if(-not $item) {return [pscustomobject]@{Status='Empty'}}
        if($item.Status -in @('Succeeded','Failed','Cancelled','Unknown')) {
            Complete-ClaudeReportOutbox $Account $name $item
            return [pscustomobject]@{Status=$item.Status;MessageId=$item.OperationId}
        }
        # One action every 7 minutes: at most 9 sends OR status queries per rolling hour.
        $state.NextActionUtc=$now.AddSeconds(420).ToString('o')
        Set-ClaudeReportArchiveJson $Account 'state/dispatch.json' $state @{'x-ms-lease-id'=$lease}
        if($item.Status -in @('Submitted','Submitting')) {
            try {
                $status=Invoke-ClaudeReportEmail -Endpoint $configuration.Connection.Endpoint -OperationId $item.OperationId -PollOnly
                if($status.status -in @('Succeeded','Failed','Canceled')) {
                    $item.Status=if($status.status -eq 'Canceled') {'Failed'} else {$status.status}
                    $item.CompletedUtc=[datetime]::UtcNow.ToString('o')
                    if($item.Status -eq 'Failed') {$item.LastError=[string]$status.error.code}
                }
            }
            catch {
                $item.LastError=$_.Exception.Message
                # A request may have been accepted before the process died. A missing operation
                # is ambiguous, never permission to resend personal data automatically.
                if($item.LastError -match '404') {$item.Status='Unknown';$item.CompletedUtc=[datetime]::UtcNow.ToString('o')}
            }
        }
        else {
            # Freshly re-read so a removed address cannot receive an old queued report.
            $configuration=(Get-ClaudeReportConfiguration $Account).Configuration
            $current=Get-ClaudeChargebackRecipients $configuration $item.Scope
            $recipients=@($current | Where-Object {(Get-ClaudeReportAddressHash $_) -in $item.RecipientHashes})
            if(-not $configuration.DeliveryEnabled -or -not $recipients.Count) {
                $item.Status='Cancelled';$item.CompletedUtc=[datetime]::UtcNow.ToString('o')
            }
            else {
                $htmlBytes=Get-ClaudeReportBlobBytes $Account $item.HtmlBlob $item.HtmlSha256
                $attachments=@(foreach($a in $item.Attachments) {
                    $bytes=Get-ClaudeReportBlobBytes $Account $a.Blob $a.Sha256
                    @{name=$a.Name;contentType=$a.ContentType;contentInBase64=[Convert]::ToBase64String($bytes)}
                })
                $body=New-ClaudeReportEmailBody -Sender $configuration.Connection.SenderAddress -Recipients $recipients `
                    -Subject "Claude usage $($item.Month) - $($item.Scope) (part $($item.Part)/$($item.Parts))" `
                    -Html ([Text.Encoding]::UTF8.GetString($htmlBytes)) -Attachments $attachments
                $item.Status='Submitting';$item.SubmittedUtc=[datetime]::UtcNow.ToString('o');$item.RecipientCount=$recipients.Count
                Set-ClaudeReportArchiveJson $Account $name $item
                try {
                    $result=Invoke-ClaudeReportEmail -Endpoint $configuration.Connection.Endpoint -Body $body -OperationId $item.OperationId
                    $item.Status=if($result.status -eq 'Succeeded') {'Succeeded'} else {'Submitted'}
                    if($item.Status -eq 'Succeeded') {$item.CompletedUtc=[datetime]::UtcNow.ToString('o')}
                }
                catch {
                    $item.LastError=$_.Exception.Message
                    if($item.LastError -match 'HTTP 429') {$item.Status='Pending'}
                    elseif($item.LastError -match 'HTTP (400|401|403)') {$item.Status='Failed';$item.CompletedUtc=[datetime]::UtcNow.ToString('o')}
                    # Network errors stay Submitting and are polled, not retried.
                }
            }
        }
        Set-ClaudeReportArchiveJson $Account $name $item
        # Every attempt is visible in the run manifest, not just completed ones.
        $manifest=Get-ClaudeReportArchiveJson $Account "$($item.RunPrefix)/manifest.json"
        $record=[pscustomobject]@{Key=$item.Key;Unit=$item.Scope;MessageId=$item.OperationId;RecipientCount=$item.RecipientCount;Part=$item.Part;Parts=$item.Parts;Status=$item.Status;SubmittedUtc=$item.SubmittedUtc;CompletedUtc=$item.CompletedUtc;Error=$item.LastError}
        $manifest.Sends=@($manifest.Sends | Where-Object Key -ne $item.Key)+@($record)
        Set-ClaudeReportArchiveJson $Account "$($item.RunPrefix)/manifest.json" $manifest
        if($item.Status -in @('Succeeded','Failed','Cancelled','Unknown')) {Complete-ClaudeReportOutbox $Account $name $item}
        if($item.Status -in @('Failed','Unknown')) {throw "Email operation $($item.OperationId) is $($item.Status). Inspect the archived manifest; automatic resend is disabled."}
        return [pscustomobject]@{Status=$item.Status;MessageId=$item.OperationId;Unit=$item.Scope;RecipientCount=$item.RecipientCount}
    }
    finally {
        Invoke-ClaudeReportBlob -Account $Account -Name 'state/dispatch.json' -Method PUT -Query 'comp=lease' `
            -ExtraHeaders @{'x-ms-lease-action'='release';'x-ms-lease-id'=$lease} | Out-Null
    }
}
