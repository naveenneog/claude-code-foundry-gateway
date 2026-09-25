param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
foreach($helper in @('Report','Configuration','Email','Outbox')) {. (Join-Path $SourceRoot "scripts\ClaudeChargeback$helper.ps1")}
$checks=0;$fail=0
function Assert($Name,$Condition) {$script:checks++;if(-not $Condition){$script:fail++;Write-Host "FAIL: $Name"}}
$script:config=New-ClaudeChargebackConfiguration @('contoso.com')
$script:config.Units['engineering']=@('alice@contoso.com','bob@contoso.com')
$script:config.Connection=[pscustomobject]@{Endpoint='https://contoso.communication.azure.com';SenderAddress='donotreply@contoso.com'}
$script:store=@{}
$script:sent=New-Object 'System.Collections.Generic.List[object]'
$script:polls=0;$script:held=$false;$script:failMode=''
function Get-ClaudeReportConfiguration {param($Account) [pscustomobject]@{Configuration=$script:config}}
function Get-ClaudeReportPendingBlobs {param($Account) @($script:store.Keys | Where-Object {$_ -like 'outbox/*'})}
function Get-ClaudeReportArchiveJson {
    param($Account,$Name,[switch]$AllowMissing)
    if(-not $script:store.ContainsKey($Name)) {if($AllowMissing){return $null};throw "Missing fixture blob $Name"}
    return ($script:store[$Name] | ConvertFrom-Json)
}
function Set-ClaudeReportArchiveJson {
    param($Account,$Name,$Value,[hashtable]$Headers)
    if($Name -eq 'state/dispatch.json') {Assert 'state write holds the lease' ($script:held -and $Headers['x-ms-lease-id'])}
    $script:store[$Name]=$Value | ConvertTo-Json -Depth 30 -Compress
}
function Invoke-ClaudeReportBlob {
    param($Account,$Name,$Method,$Query,$ExtraHeaders)
    if($Query -eq 'comp=lease') {
        if($ExtraHeaders['x-ms-lease-action'] -eq 'acquire') {if($script:held){throw 'Report storage lease is already held (HTTP 409).'};$script:held=$true}
        else {$script:held=$false}
    } elseif($Method -eq 'DELETE') {$script:store.Remove($Name)}
}
function Get-ClaudeReportBlobBytes {param($Account,$Name,$Sha256) return ,[Text.Encoding]::UTF8.GetBytes('<p>Engineering only</p>')}
function Invoke-ClaudeReportEmail {
    param($Endpoint,$Body,$OperationId,[switch]$PollOnly)
    if($PollOnly) {$script:polls++;return [pscustomobject]@{id=$OperationId;status='Succeeded'}}
    $saved=Get-ClaudeReportArchiveJson $null 'outbox/item.json'
    Assert 'before POST, operation is persisted as Submitting' ($saved.Status -eq 'Submitting' -and $saved.OperationId -eq $OperationId)
    Assert 'network send holds exclusive lease' $script:held
    $script:sent.Add($Body)
    if($script:failMode -eq 'network'){throw 'ACS email operation failed (HTTP 0)'}
    if($script:failMode -eq '429'){throw 'ACS email operation failed (HTTP 429)'}
    return [pscustomobject]@{id=$OperationId;status='Running'}
}
function Reset-Outbox {
    $script:store=@{
        'state/dispatch.json'='{"NextActionUtc":null}'
        'runs/2026-08/run1/manifest.json'='{"Sends":[]}'
    }
    $item=[ordered]@{Version=1;Key='item';RunPrefix='runs/2026-08/run1';Month='2026-08';Scope='engineering'
        RecipientHashes=@((Get-ClaudeReportAddressHash 'alice@contoso.com'),(Get-ClaudeReportAddressHash 'bob@contoso.com'))
        HtmlBlob='runs/2026-08/run1/engineering.html';HtmlSha256='fixture';Attachments=@();Part=1;Parts=1
        Status='Pending';OperationId='11111111-1111-1111-1111-111111111111';RecipientCount=0;CreatedUtc='2026-09-01T00:00:00Z';SubmittedUtc=$null;CompletedUtc=$null;LastError=$null}
    $script:store['outbox/item.json']=$item | ConvertTo-Json -Depth 20 -Compress
    $script:held=$false;$script:failMode='';$script:sent.Clear();$script:polls=0
}
Reset-Outbox
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'first pass submits one email' ($result.Status -eq 'Submitted' -and $script:sent.Count -eq 1)
Assert 'first pass sends only correct recipients' ((@($script:sent[0].recipients.bcc | ForEach-Object {$_['address']}) -join ';') -eq 'alice@contoso.com;bob@contoso.com')
Assert 'manifest records operation, scope and count' (($script:store['runs/2026-08/run1/manifest.json'] | ConvertFrom-Json).Sends[0].RecipientCount -eq 2)
Assert 'manifest never contains addresses' ($script:store['runs/2026-08/run1/manifest.json'] -notmatch '@contoso')
Assert 'lease released after sending' (-not $script:held)
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'second pass respects persistent pacing' ($result.Status -eq 'RateLimited' -and $script:sent.Count -eq 1 -and $script:polls -eq 0)
$script:store['state/dispatch.json']='{"NextActionUtc":null}'
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'next action polls, never resends' ($result.Status -eq 'Succeeded' -and $script:polls -eq 1 -and $script:sent.Count -eq 1)
Assert 'successful item removed from active outbox' (-not $script:store.ContainsKey('outbox/item.json'))
Assert 'receipt persists completed operation' ($script:store.ContainsKey('runs/2026-08/run1/receipts/item.json'))
Reset-Outbox
$script:config.Units['engineering']=@('alice@contoso.com','carol@contoso.com')
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'removed recipients do not receive queued reports' ($script:sent[0].recipients.bcc.Count -eq 1 -and $script:sent[0].recipients.bcc[0].address -eq 'alice@contoso.com')
Assert 'newly added recipients do not receive old queued reports implicitly' (@($script:sent[0].recipients.bcc | ForEach-Object {$_['address']}) -notcontains 'carol@contoso.com')
Reset-Outbox
$script:config.Units['engineering']=@()
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'empty recipients cancel without sending' ($result.Status -eq 'Cancelled' -and $script:sent.Count -eq 0)
Reset-Outbox
$script:config.Units['engineering']=@('alice@evil.com')
$blocked=$false
try {Invoke-ClaudeReportOutbox 'contoso'|Out-Null}catch{$blocked=$_.Exception.Message -match 'domain'}
Assert 'tampered domain fails before transport' ($blocked -and $script:sent.Count -eq 0)
Assert 'lease released after validation error' (-not $script:held)
Reset-Outbox
$script:config.Units['engineering']=@('alice@contoso.com')
$script:failMode='network'
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'ambiguous send persists Submitting' ($result.Status -eq 'Submitting')
$script:store['state/dispatch.json']='{"NextActionUtc":null}'
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'network failure polls same operation instead of duplicate' ($result.Status -eq 'Succeeded' -and $script:sent.Count -eq 1 -and $script:polls -eq 1)
Reset-Outbox
$script:failMode='429'
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'throttled send remains pending with pacing' ($result.Status -eq 'Pending' -and ($script:store['state/dispatch.json'] | ConvertFrom-Json).NextActionUtc)
Reset-Outbox
$script:held=$true
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'concurrent dispatch does not send' ($result.Status -eq 'Busy' -and $script:sent.Count -eq 0)
$script:held=$false
$script:config.DeliveryEnabled=$false
$result=Invoke-ClaudeReportOutbox 'contoso'
Assert 'disabled delivery does not send' ($result.Status -eq 'Disabled' -and $script:sent.Count -eq 0)
if($fail){throw "$fail of $checks outbox assertions failed."}
Write-Host "$checks chargeback outbox assertions passed."
