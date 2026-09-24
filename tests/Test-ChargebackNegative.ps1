# Mutations run isolated copies, never the source or a shared fixed scratch filename.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$scratch=Join-Path $root ('.chargeback-mutations-' + [guid]::NewGuid().ToString('N'))
$cases=@(
    @{Name='wrong month boundary';File='ClaudeChargebackReport.ps1';From='$end.AddTicks(-1)';To='$end.AddTicks(0)';Test='Test-ChargebackReports.ps1'}
    @{Name='dropped cache-read token kind';File='ClaudeChargebackReport.ps1';From='$To.$key += [long]$Row.$key';To='if ($key -ne ''CacheReadTokens'') { $To.$key += [long]$Row.$key }';Test='Test-ChargebackReports.ps1'}
    @{Name='missing Unassigned artifact';File='ClaudeChargebackReport.ps1';From='$ids = @($units.Keys | Sort-Object)';To='$ids = @($units.Keys | Where-Object { $_ -ne ''unassigned'' } | Sort-Object)';Test='Test-ChargebackReports.ps1'}
    @{Name='cross-unit leakage';File='ClaudeChargebackReport.ps1';From='if ($person.Unit -cne $id)';To='if ($false)';Test='Test-ChargebackReports.ps1'}
    @{Name='unescaped CSV formula';File='ClaudeChargebackRender.ps1';From='if ($text -match ''^[\s\x00-\x1f]*[=+\-@]'' -or $text -match ''^[\t\r\n]'')';To='if ($false)';Test='Test-ChargebackReports.ps1'}
    @{Name='disabled domain allow-list';File='ClaudeChargebackConfiguration.ps1';From='if ($AllowedDomains -notcontains $mail.Host.ToLowerInvariant())';To='if ($false)';Test='Test-ChargebackDelivery.ps1'}
    @{Name='removed recipients still mailed';File='ClaudeChargebackOutbox.ps1';From='$current=Get-ClaudeChargebackRecipients $configuration $item.Scope';To='$current=@(''alice@contoso.com'',''bob@contoso.com'')';Test='Test-ChargebackOutbox.ps1'}
    @{Name='BOM breaks private blob listing';File='ClaudeChargebackStorage.ps1';From='return $text.TrimStart([char]0xfeff)';To='return $text';Test='Test-ChargebackStorage.ps1'}
    @{Name='double-slash event prefix stalls delivery';Directory='infra';File='chargeback-reports.bicep';From="blobPrefix: 'outbox'";To="blobPrefix: 'outbox/'";Test='Test-ChargebackSchedule.ps1'}
)
$caught=0
try {
    foreach($case in $cases) {
        $copy=Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory (Join-Path $copy 'scripts') -Force | Out-Null
        Get-ChildItem (Join-Path $root 'scripts') -Filter '*ClaudeChargeback*.ps1' | Copy-Item -Destination (Join-Path $copy 'scripts')
        Copy-Item (Join-Path $root 'scripts\ClaudeBusinessUnit.ps1') (Join-Path $copy 'scripts')
        New-Item -ItemType Directory (Join-Path $copy 'infra') | Out-Null
        Get-ChildItem (Join-Path $root 'infra') -Filter 'chargeback*.bicep' | Copy-Item -Destination (Join-Path $copy 'infra')
        $directory=if($case.Directory) {$case.Directory} else {'scripts'}
        $path=Join-Path $copy "$directory\$($case.File)"
        $original=[IO.File]::ReadAllText($path)
        if(-not $original.Contains($case.From)) {throw "Mutation anchor missing: $($case.Name)"}
        [IO.File]::WriteAllText($path,$original.Replace($case.From,$case.To),(New-Object Text.UTF8Encoding($false)))
        $output=& pwsh -NoProfile -File (Join-Path $PSScriptRoot $case.Test) -SourceRoot $copy 2>&1
        if($LASTEXITCODE -eq 0) {throw "UNCATCHED MUTATION: $($case.Name)"}
        if(($output -join "`n") -notmatch 'assertions failed|FAIL:') {throw "Mutation did not reach an assertion: $($case.Name): $($output -join ' ')"} 
        $caught++
        Write-Host "CAUGHT: $($case.Name)"
        Remove-Item $copy -Recurse -Force
    }
}
finally {if(Test-Path $scratch) {Remove-Item $scratch -Recurse -Force}}
if($caught -ne $cases.Count) {throw 'Not every mutation ran.'}
Write-Host "$caught of $($cases.Count) chargeback mutations caught."
