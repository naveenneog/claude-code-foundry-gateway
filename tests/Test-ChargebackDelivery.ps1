param([string]$SourceRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackReport.ps1')
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackConfiguration.ps1')
. (Join-Path $SourceRoot 'scripts\ClaudeChargebackEmail.ps1')
$checks=0; $fail=0
function Assert($Name,$Condition) { $script:checks++; if (-not $Condition) { $script:fail++; Write-Host "FAIL: $Name" } }
function Refuses($Name,[scriptblock]$Action,$Message) {
    $caught=$false
    try { & $Action | Out-Null } catch { $caught=$_.Exception.Message -match $Message }
    Assert $Name $caught
}
$c=New-ClaudeChargebackConfiguration @('contoso.com')
Assert 'configuration is versioned' ($c.SchemaVersion -eq 1)
Assert 'initial recipients empty' ($c.AllUnitsRecipients.Count -eq 0 -and $c.Units.Count -eq 0)
Refuses 'domains cannot be empty' { New-ClaudeChargebackConfiguration @() } 'domain'
Refuses 'wildcard domain refused' { New-ClaudeChargebackConfiguration @('*.contoso.com') } 'domain'
Refuses 'header injection domain refused' { New-ClaudeChargebackConfiguration @("contoso.com`r`nbcc:x") } 'domain'
$x=Update-ClaudeChargebackRecipients $c 'engineering' @('Alice@contoso.com','alice@contoso.com') @()
Assert 'add normalizes and deduplicates' ($x.Units.engineering.Count -eq 1 -and $x.Units.engineering[0] -eq 'alice@contoso.com')
$x=Update-ClaudeChargebackRecipients $x 'engineering' @('alice@contoso.com','bob@contoso.com') @()
Assert 'repeat add is idempotent' ($x.Units.engineering.Count -eq 2)
$x=Update-ClaudeChargebackRecipients $x 'engineering' @() @('ALICE@contoso.com')
Assert 'removal is case insensitive' ($x.Units.engineering.Count -eq 1 -and $x.Units.engineering[0] -eq 'bob@contoso.com')
$x=Update-ClaudeChargebackRecipients $x 'engineering' @() @('alice@contoso.com')
Assert 'repeat removal is idempotent' ($x.Units.engineering.Count -eq 1)
$x=Update-ClaudeChargebackRecipients $x 'all' @('admin@contoso.com') @()
Assert 'admin recipients separate' ($x.AllUnitsRecipients.Count -eq 1 -and $x.Units.engineering.Count -eq 1)
foreach($address in @('alice@evil.com','alice@contoso.com.evil.com','alice@sub.contoso.com','not-an-email','Alice <alice@contoso.com>',"alice@contoso.com`r`nbcc:bob@contoso.com")) {
    Refuses "invalid recipient rejected [$address]" { Update-ClaudeChargebackRecipients $c 'engineering' @($address) @() } 'recipient|domain'
}
$bad=New-ClaudeChargebackConfiguration @('contoso.com')
$bad.Units['engineering']=@('alice@evil.com')
Refuses 'edited blob is validated before send' { Test-ClaudeChargebackConfiguration $bad } 'domain'
$bad=New-ClaudeChargebackConfiguration @('contoso.com'); $bad.AllowedDomains=@()
Refuses 'disabled allow-list fails closed' { Test-ClaudeChargebackConfiguration $bad } 'domain'
$large=New-ClaudeChargebackConfiguration @('contoso.com')
for($i=0;$i -lt 500;$i++) { $large.Units["unit-$i"]=@("owner-$i@contoso.com") }
Test-ClaudeChargebackConfiguration $large
Assert 'hundreds of units exceed named-value ceiling safely' (($large | ConvertTo-Json -Depth 8 -Compress).Length -gt 4096)
Assert 'recipients list cannot alias mutable input' ($c.Units.Count -eq 0)
Refuses 'unsafe scope rejected' { Update-ClaudeChargebackRecipients $c '../finance' @('alice@contoso.com') @() } 'identifier'
$clone=ConvertTo-ClaudeChargebackConfiguration ($large | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
Assert 'JSON round trip retains all units' ($clone.Units.Count -eq 500)
Refuses 'unsupported configuration version refused' { $b=New-ClaudeChargebackConfiguration @('contoso.com');$b.SchemaVersion=2;Test-ClaudeChargebackConfiguration $b } 'version'
$payload=New-ClaudeReportEmailBody -Sender 'donotreply@contoso.com' -Recipients @('alice@contoso.com') -Subject 'Report 2026-08' -Html '<p>Contoso</p>' -Attachments @()
Assert 'tracking explicitly disabled' $payload.userEngagementTrackingDisabled
Assert 'recipients hidden from each other' ($payload.recipients.bcc.Count -eq 1 -and -not $payload.recipients.to)
Refuses 'too many recipients per message refused' { New-ClaudeReportEmailBody -Sender 'donotreply@contoso.com' -Recipients (1..51 | ForEach-Object { "owner$_@contoso.com" }) -Subject 'x' -Html 'x' -Attachments @() } '50'
Refuses 'oversize encoded payload refused' { New-ClaudeReportEmailBody -Sender 'donotreply@contoso.com' -Recipients @('alice@contoso.com') -Subject 'x' -Html ('x'*10000001) -Attachments @() } 'size'
$base=Join-Path $SourceRoot ('.chargeback-attachments-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory $base | Out-Null
    $csv=Join-Path $base 'engineering.csv'
    [IO.File]::WriteAllText($csv,"Person,Requests`r`n`"Alice`r`nContoso`",2`r`n`"bob@contoso.com`",3`r`n")
    $parts=New-ClaudeReportAttachments -CsvPaths @($csv) -OutputPath $base
    Assert 'small CSV attached directly' (@($parts).Count -eq 1 -and $parts[0].Name -eq 'engineering.csv')
    $largeCsv=Join-Path $base 'finance.csv'
    $writer=New-Object IO.StreamWriter($largeCsv)
    try {
        $writer.WriteLine('Person,Requests')
        for($i=0;$i -lt 50000;$i++) { $writer.WriteLine(('"user-{0}-{1}@contoso.com",2' -f $i,[guid]::NewGuid().ToString('N'))) }
    } finally { $writer.Dispose() }
    $parts=New-ClaudeReportAttachments -CsvPaths @($largeCsv) -OutputPath $base -PartBytes 200000
    Assert 'large CSV splits into compressed parts' (@($parts).Count -gt 1 -and @($parts | Where-Object Name -notlike '*.zip').Count -eq 0)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $rows=0
    foreach($part in $parts) {
        $archive=[IO.Compression.ZipFile]::OpenRead($part.Path)
        try {
            Assert 'each part contains exactly one CSV' ($archive.Entries.Count -eq 1 -and $archive.Entries[0].Name -like '*.csv')
            $reader=New-Object IO.StreamReader($archive.Entries[0].Open())
            try {
                Assert 'each part has the CSV header' ($reader.ReadLine() -eq 'Person,Requests')
                while($null -ne ($line=$reader.ReadLine())) { $rows++ }
            } finally { $reader.Dispose() }
        } finally { $archive.Dispose() }
    }
    Assert 'split preserves all 50000 rows' ($rows -eq 50000)
}
finally { if(Test-Path $base) { Remove-Item $base -Recurse -Force } }
if($fail) { throw "$fail of $checks chargeback delivery assertions failed." }
Write-Host "$checks chargeback delivery assertions passed."
