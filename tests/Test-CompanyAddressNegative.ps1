# Every mutation runs the complete original assertion count in a private copy.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temporaryRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Temp'
$scratch = Join-Path $temporaryRoot ('company-mutations-' + [guid]::NewGuid().ToString('N'))
$cases = @(
    @('wait','if\(\[IO.Path\]::GetTempPath\(\).TrimEnd\(''\\'',''/''\) -ne \$ExpectedDirectory.TrimEnd\(''\\'',''/''\)\)','if ($false)','a redirected temporary directory is refused before executing a check','U1 private temporary directory ownership','Test-AddressDeadline.ps1'),
    @('installer','(?m)^    if \(\$AddressApprovedPlanFingerprint -and.*\{$','    if ($false) {','real installer fingerprint mismatch rejects every resource write','Q1 executable fingerprint guard','Test-CompanyInstaller.ps1'),
    @('installer','(?m)^if \(-not \(Read-YesNo.*\{$','if ($false) {','real declined custom confirmation creates nothing','Q1 executable decline guard','Test-CompanyInstaller.ps1'),
    @('installer','(?m)^if \(\$WhatIfPreference\) \{ Write-Warn2 ''WhatIf - stopping before any change\.''; return \}$','if ($false) { return }','custom WhatIf creates no deployment or address','Q1 executable WhatIf guard','Test-CompanyInstaller.ps1'),
    @('installer','(?m)^    \$config.Remove\(''address''\)$','    $null = $config','Azure transition clears both company metadata copies','C2 company metadata cleared','Test-CompanyInstaller.ps1'),
    @('installer','(?m)^    if \(\$config.Contains\(''decisions''\).*Remove\(''address''\).*$','    $null = $config','Azure transition clears both company metadata copies','C2 applied address cleared','Test-CompanyInstaller.ps1'),
    @('installer','(?m)^        Update-ClaudeAddressArtifacts -RecordPath \$configPath.*$','        $null = $configPath','Azure transition updates existing generated settings','C2 generated settings updated','Test-CompanyInstaller.ps1'),
    @('foundation','(?m)^    if \(-not \$Attended\) \{$','    if ($false) {','Foundation fingerprints and prices inherited company address inputs','A1 inherited inputs resolved','Test-CompanyInstaller.ps1'),
    @('foundation','if \(\$installerArgs.AddressMode -eq ''custom''\)','if ($false)','Foundation fingerprints and prices inherited company address inputs','A1 inherited plan fingerprinted','Test-CompanyInstaller.ps1'),
    @('foundation','Hostname = \$installerArgs.AddressHostname','Hostname = $d.addressHostname','Foundation fingerprints and prices inherited company address inputs','A1 planned inputs equal passed inputs','Test-CompanyInstaller.ps1'),
    @('foundation','(?m)^        if \(\$address.Contains\(\$pair.Key\)\).*$','        $null = $address','Foundation merge retains the address chosen by the installer rather than an old proposal','C2 applied Foundation address','Test-CompanyInstaller.ps1'),
    @('start','if \(\$null -ne \$script:FlowAppliedDecisions\)','if ($false)','step receives proposed choices but durable state is still applied (False)','A2 proposals are not persisted','Test-FlowAppliedState.ps1'),
    @('start','Copy-ClaudeFlowValue \$script:FlowAppliedDecisions.PSObject.Properties\[\$step.Info.DecisionKey\].Value','Get-ClaudeDecision -Record $Record -Key $step.Info.DecisionKey','successful history starts before questions, not at the proposed value','A2 history begins at applied value','Test-FlowAppliedState.ps1'),
    @('recovery','\$receipt.fingerprint -eq \(Get-ClaudeFlowFingerprint @\(\$d\)\)','${true}','a tampered recovery receipt cannot bypass drift','C1 receipt integrity','Test-CompanyAddress.ps1'),
    @('recovery','\$d.gatewayId -ieq \$expectedId','${true}','a receipt for another gateway never permits recovery','C1 recovery gateway scope','Test-CompanyAddress.ps1'),
    @('recovery','\(ConvertTo-ClaudeFlowCanonical @\(Get-ClaudeAddressRecoveryHosts \$Gateway\)\) -ceq \(ConvertTo-ClaudeFlowCanonical @\(\$d.expectedHosts\)\)','${true}','unrelated live hostname drift cannot use address recovery','C1 exact recovered host collection','Test-CompanyAddress.ps1'),
    @('start','(?m)^        if \(\$Action -eq ''Change'' -and \$Change -eq ''address''','        if ($true -and $Change -eq ''address''','address recovery cannot bypass drift for another action or decision','C1 recovery action scope','Test-CompanyFlow.ps1'),
    @('start','(?m)^        if \(\$Action -eq ''Change'' -and \$Change -eq ''address''','        if ($Action -eq ''Change'' -and $true','address recovery cannot bypass drift for another action or decision','C1 recovery decision scope','Test-CompanyFlow.ps1'),
    @('flowstep','(?m)^    if \(\$recovery -and \$recovery.Allowed -and.*\{$','    if ($false) {','recovery planning refuses a different proposed hostname','C1 recovery proposed-input scope','Test-CompanyFlow.ps1'),
    @('wait','\$TimeoutSeconds\*1000-\$watch.Elapsed.TotalMilliseconds','$TimeoutSeconds*2000-$watch.Elapsed.TotalMilliseconds','native Azure reads are bounded and their child process is stopped','U1 remaining deadline','Test-AddressDeadline.ps1'),
    @('wait','if\(Test-Path -LiteralPath \$directory\)\{Remove-Item -LiteralPath \$directory -Recurse -Force -ErrorAction Stop\}','if ($false) { }','timed-out checks leave no private ARM body directory behind','U1 cancelled private-body cleanup','Test-AddressDeadline.ps1'),
    @('address','\[Convert\]::ToBase64String\(\$pfxBytes\)','[Convert]::ToBase64String([IO.File]::ReadAllBytes($d.PfxPath))','the uploaded PFX is the approved buffer even if DNS waiting replaces its file','S1 immutable upload buffer'),
    @('certificate','\$sha.ComputeHash\(\$PfxBytes\)','$sha.ComputeHash([IO.File]::ReadAllBytes($PfxPath))','PFX validation and hash use the supplied buffer even when its path is replaced','S1 validation and hash buffer'),
    @('address','(?m)^    if \(-not \(Test-ClaudeFlowSubscriptionId \$SubscriptionId\)\).*$', '    if ($false) { throw ''subscription'' }','subscription ID is required','invalid subscription'),
    @('address','(?m)^    if \(\$ResourceGroup -notmatch.*$', '    if ($false) { throw ''resource group'' }','a CLI metacharacter cannot reach resource discovery','resource group validation'),
    @('address','(?m)^    if \(\$Hostname.Length.*\{$', '    if ($false) {','invalid hostname is refused: https://claude.contoso.test','hostname boundary'),
    @('address','(?m)^    if \(\$CertificateSource -notin.*$', '    if ($false) { throw ''managed not supported'' }','BasicV2 offers supplied certificates, not managed issuance','v2 managed certificate rejection'),
    @('address','(?m)^    if \(\(\$ConnectAddress -or \$DnsServer\).*$', '    if ($false) { throw ''IsolatedProof'' }','a connect-IP override requires isolated proof mode','isolated override boundary'),
    @('address','(?m)^    if \(\$IsolatedProof -and \(\$Hostname.*\{$', '    if ($false) {','test-only TLS cannot be used for a production hostname','reserved proof domain'),
    @('address','(?m)^    if \(\$sku -notin.*$', '    if ($false) { throw ''v2'' }','unsupported gateway tiers fail before writes','gateway tier detector'),
    @('address','(?m)^    if \(\$Gateway.properties.provisioningState -ne.*$', '    if ($false) { throw ''provisioning'' }','a busy service is not modified or hidden by a successful old state','busy service plan'),
    @('address','(?m)^    if \(\$ReplaceHostname -and.*$', '    if ($false) { throw ''replacement'' }','a misspelled replacement is refused instead of ignoring it','explicit replacement target'),
    @('address','(?m)^    if \(\$sku -ne ''PremiumV2''.*\{$', '    if ($false) {','Basic v2 does not silently discard a different company hostname','single-hostname tier limit'),
    @('address','Microsoft\.Network/dnsZones/','Microsoft.Network/(?:dnsZones|privateDnsZones)/','a private DNS zone is not treated as public Azure DNS','public-zone resource type'),
    @('address','(?m)^        if \(\$Matches\[1\] -ine \$SubscriptionId\).*$', '        if ($false) { throw ''subscription'' }','a DNS zone in another subscription is refused','zone subscription pin'),
    @('address','(?m)^        if \(\$Hostname -ieq \$zoneName\).*$', '        if ($false) { throw ''apex'' }','a CNAME at the zone apex is refused before a write','zone apex guard'),
    @('address','(?m)^        if \(-not \$Hostname.EndsWith.*$', '        if ($false) { throw ''zone'' }','a different DNS suffix cannot be mistaken for the selected zone','DNS suffix boundary'),
    @('address','-ProductName \$m.Service -Tier First','-ProductName $m.Service -Tier Marginal','DNS is priced at the first tier of global public meters','first-tier DNS prices'),
    @('address','\$rate = \$null; \$unit =','${rate} = 0; $unit =','an unknown retail price never becomes a zero quote','unknown is not free'),
    @('address','@\(\$hosts\) \+ @\(\$Binding\)','@($Binding)','unrelated portal certificate settings survive exactly','retain hostname collection'),
    @('address','(?m)^    if \(\$record -and .* \{$','    if ($false) {','a record naming another gateway is refused before any write','record gateway pin'),
    @('address','(?m)^    if \(\(Get-ClaudeAddressHostState \$gateway\).*$', '    if ($false) { throw ''changed'' }','changed hostname state invalidates an approved plan before writes','live hostname drift'),
    @('address','(?m)^    if \(\$cert.Thumbprint -ne.*$', '    if ($false) { throw ''certificate changed'' }','a changed certificate invalidates approval before writes','certificate drift'),
    @('address',' -or \$cert.PfxSha256 -ne \$d.Certificate.PfxSha256',' -or $false','changed PFX contents invalidate approval even when the certificate thumbprint stays','PFX content fingerprint'),
    @('address','(?m)^        if \(\(ConvertTo-ClaudeFlowCanonical \$currentDns\).*$', '        if ($false) { throw ''DNS changed'' }','an intervening DNS edit is not overwritten','DNS review drift'),
    @('address','(?m)^    if \(\[bool\]\$vault.properties.enableRbacAuthorization.*$', '    if ($false) { throw ''permission model changed'' }','a changed vault permission model is refused before a grant','vault permission-model drift'),
    @('address','(?m)^        if \(@\(\$assignments \| Where-Object.*$', '        if ($false) { return $Gateway }','an existing certificate-read role is not assigned a second time','idempotent role assignment'),
    @('address','(?m)^            \$permissions.secrets =.*$', '            $permissions.secrets = @(''get'',''list'')','access-policy grants preserve existing secret permissions','additive secret permissions'),
    @('address','(?m)^        if \(\$Gateway.identity.userAssignedIdentities\).*$', '        if ($false) { }','enabling system identity retains every user-assigned identity','preserve user identities'),
    @('address','(?m)^        if \(-not \$bindingMatches\) \{$','        if ($true) {','a known matching binding is not needlessly patched on retry','idempotent certificate binding'),
    @('address','(?m)^        if \(\$g.properties.provisioningState -in.*$', '        if ($false) { throw ''Failed'' }','a failed provisioning state is not mistaken for ready','provisioning failure detector'),
    @('address','(?m)^        if \(\$result.StatusCode -ne 401\).*$', '        if ($false) { throw ''HTTPS 401'' }','HTTPS status failure does not publish the company URL','gateway HTTP proof'),
    @('address','(?m)^        if \(\$result.Thumbprint -ine.*$', '        if ($false) { throw ''certificate'' }','HTTPS certificate failure does not publish the company URL','HTTPS certificate pin'),
    @('address','(?m)^        if \(-not \$result.Trusted.*$', '        if ($false) { throw ''trust'' }','HTTPS trust failure does not publish the company URL','production TLS trust'),
    @('address','(?m)^        if \(\$result.Hostname -ine.*$', '        if ($false) { throw ''hostname'' }','a mismatched hostname cannot pass even the isolated TLS proof contract','HTTPS hostname evidence'),
    @('address','if \(\$d.IsolatedProof\) \{ Write-Host ''ISOLATED PROOF:', 'if ($false) { Write-Host ''ISOLATED PROOF:','self-signed proof is explicit, restricted and cannot publish the record','test proof publication guard'),
    @('address','(?m)^        if \(\$file.Extension -eq ''\.eml''.*\{$','        if ($false) {','generated Outlook mail decodes and updates its base64 HTML body','encoded handover update'),
    @('certificate','if \(\$RequirePrivateKey -and -not \$Certificate.HasPrivateKey\)','if ($false)','PFX validation requires a private key','PFX private key'),
    @('certificate','if \(\$Certificate.NotBefore.ToUniversalTime\(\) -gt \$now -or \$Certificate.NotAfter.ToUniversalTime\(\) -le \$now\)','if ($false)','an expired certificate is refused','certificate validity'),
    @('certificate','if \(-not \$rsa -or \$rsa.KeySize -lt 2048\)','if ($false)','a 1024-bit RSA key is refused','RSA minimum size'),
    @('certificate','if \(-not \$covered\)','if ($false)','an unrelated certificate hostname fails','certificate hostname detector'),
    @('certificate','if \(-not \$san.Count\)','if ($true)','a SAN overrides the subject common name','SAN precedence'),
    @('certificate','if \(\$Hostname.Substring\(\$Hostname.IndexOf\(''\.''\) \+ 1\) -ieq \$name.Substring\(2\)\)','if ($true)','a wildcard certificate cannot match two labels','one-label wildcard'),
    @('certificate','if \(\$KeyVaultCertificateId -notmatch ''\^https://','if ($KeyVaultCertificateId -notmatch ''^https?://','untrusted certificate reference is refused: http://kv-contoso.vault.azure.net/secrets/company','HTTPS Key Vault reference'),
    @('certificate','if \(-not \$metadata.attributes.enabled\)','if ($false)','a disabled Key Vault certificate is refused','certificate enabled state'),
    @('certificate','if \(-not \$metadata.policy.keyProperties.exportable -or \$metadata.policy.secretProperties.contentType -ne ''application/x-pkcs12''\)','if ($false)','a nonexportable Key Vault key is refused','Key Vault exportability'),
    @('certificate','if \(-not \$Thumbprint -or \$Thumbprint -ine \$ExpectedThumbprint\)','if ($false)','trusted TLS with another certificate is refused','TLS exact pin'),
    @('certificate','\(\$IsolatedProof -and \$Errors -eq 4\)','($IsolatedProof)','isolated proof still refuses a hostname mismatch','isolated TLS errors'),
    @('certificate','\$Errors -eq 0 -or \(\$IsolatedProof','${Errors} -eq 4 -or ($IsolatedProof','a self-signed certificate is refused by production TLS','normal TLS trust policy'),
    @('discovery','\$_.type -eq ''Proxy'' -and \$_.hostName','${true} -and $_.hostName','a portal hostname cannot masquerade as a gateway address','Proxy-only discovery'),
    @('discovery','\$parsedUrl.Scheme -eq ''https''','${true}','discovery refuses the noncanonical company URL: http://claude.contoso.test:443/claude','discovery HTTPS scheme'),
    @('discovery','\$parsedUrl.Port -eq 443','${true}','discovery refuses the noncanonical company URL: https://claude.contoso.test:444/claude','discovery HTTPS port'),
    @('discovery','-not \$parsedUrl.UserInfo','${true}','discovery refuses the noncanonical company URL: https://user@claude.contoso.test/claude','discovery URL credentials'),
    @('discovery','-not \$parsedUrl.Query','${true}','discovery refuses the noncanonical company URL: https://claude.contoso.test/claude?token=fixture','discovery query exclusion'),
    @('discovery','-not \$parsedUrl.Fragment','${true}','discovery refuses the noncanonical company URL: https://claude.contoso.test/claude#fragment','discovery fragment exclusion'),
    @('flowstep','(?m)^    Set-ClaudeRecordProperty \$Record address \$result.Address$','    $null = $result.Address','the step updates the top-level installer address as well as the flow decision','installer and flow address agree'),
    @('flowstep','if \(\$d.dnsMode -eq ''AzureDns'' -and -not \$d.dnsZoneResourceId\)','if ($false)','Address AzureDns cannot silently fall back to external DNS when its zone is absent','explicit Azure zone selection'),
    @('start','if \(\$null -ne \$value -and \$value -isnot \[string\]\)','if ($false)','text answers reject a list before parameter binding can join it','text scalar validation'),
    @('start','if \(-not \$q.Optional -and \[string\]::IsNullOrWhiteSpace\(\$value\)\)','if ($false)','a required text answer cannot default to nothing','required address answer'),
    @('start','(?m)^        if \(\$key -match.*transient.*$','        if ($false) { throw ''transient'' }','certificate passwords cannot be persisted in an answers file','transient secrets'),
    @('transport','if \(\$IfMatch\) \{ \$request.Headers\[''If-Match''\] = \$IfMatch \}','if ($false) { }','real ARM transport sends conditional DNS headers and removes the body file','DNS conditional update'),
    @('transport','if \(\$IfNoneMatch\) \{ \$request.Headers\[''If-None-Match''\] = ''\*'' \}','if ($false) { }','real ARM transport sends conditional DNS headers and removes the body file','DNS conditional create')
)
$paths = @{
    address = 'scripts\ClaudeGatewayAddress.ps1'; certificate = 'scripts\ClaudeGatewayCertificate.ps1'
    discovery = 'scripts\flow\Discovery.ps1'; flowstep = 'scripts\flow\Address.ps1'
    start = 'Start-ClaudeGateway.ps1'; transport = 'scripts\ClaudeNetwork.ps1'
    installer = 'Install-ClaudeGateway.ps1'; foundation = 'scripts\flow\Foundation.ps1'
    recovery = 'scripts\ClaudeGatewayAddressRecovery.ps1'; wait = 'scripts\ClaudeGatewayAddressWait.ps1'
}
function Run-Suite([string]$Test) {
    $pipeline = [powershell]::Create()
    $temp=Join-Path $scratch ('suite-temp-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    $environment=@{}
    foreach($name in 'TEMP','TMP','TMPDIR'){$environment[$name]=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,$temp)}
    try {
        $null = $pipeline.AddScript(@'
param($Path)
$global:LASTEXITCODE = 0
& $Path 6>&1
[pscustomobject]@{ P69SuiteExit = $LASTEXITCODE }
'@).AddArgument((Join-Path $scratch "tests\$Test"))
        try { $output = @($pipeline.Invoke()) }
        catch { throw "Suite did not reach its full summary: $Test`n$($_.Exception.Message)" }
        $exit = @($output | Where-Object { $_.PSObject.Properties.Name -contains 'P69SuiteExit' })
        $code = if ($exit.Count -eq 1) { [int]$exit[0].P69SuiteExit } else { -1 }
        $text = (@($output | Where-Object { $_.PSObject.Properties.Name -notcontains 'P69SuiteExit' }) -join "`n") + "`n" + ($pipeline.Streams.Error -join "`n")
    }
    finally {
        $pipeline.Dispose()
        foreach($name in $environment.Keys){[Environment]::SetEnvironmentVariable($name,$environment[$name])}
        if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
    }
    $count = [regex]::Match($text, '(?:Company (?:address|certificate|flow|installer)|Applied flow state|Address deadline): (\d+) assertions, \d+ passed, (\d+) failed\.')
    if (-not $count.Success -or $code -eq -1) { throw "Suite did not reach its full summary: $Test`n$text" }
    [pscustomobject]@{ Code = $code; Text = $text; Count = [int]$count.Groups[1].Value }
}
try {
    $files = @(
        'scripts\ClaudeGatewayAddress.ps1','scripts\ClaudeGatewayCertificate.ps1','scripts\ClaudeGatewayAddressRecovery.ps1','scripts\ClaudeGatewayAddressWait.ps1','scripts\Set-ClaudeGatewayAddress.ps1',
        'scripts\ClaudeNetwork.ps1','scripts\AzureRetailPrice.ps1','scripts\ClaudeChoice.ps1','scripts\ClaudeGatewayRegion.ps1','scripts\ClaudeGatewayAddressInput.ps1',
        'scripts\flow\FlowContract.ps1','scripts\flow\Discovery.ps1','scripts\flow\Address.ps1','scripts\flow\Foundation.ps1',
        'scripts\flow\lib\LifecycleCommon.ps1','Install-ClaudeGateway.ps1','Start-ClaudeGateway.ps1','infra\main.bicep',
        'tests\Test-CompanyAddress.ps1','tests\Test-CompanyCertificate.ps1','tests\Test-CompanyFlow.ps1',
        'tests\Test-CompanyInstaller.ps1','tests\Test-FlowAppliedState.ps1','tests\Test-AddressDeadline.ps1',
        'scripts\Show-Banner.ps1','scripts\Test-Prerequisites.ps1','scripts\ClaudeModelDeployment.ps1','scripts\ClaudeDesktopSignIn.ps1'
    )
    foreach ($file in $files) {
        $to = Join-Path $scratch $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $to
    }
    $counts = @{}
    foreach ($suite in 'Test-CompanyAddress.ps1','Test-CompanyCertificate.ps1','Test-CompanyFlow.ps1','Test-CompanyInstaller.ps1','Test-FlowAppliedState.ps1','Test-AddressDeadline.ps1') {
        $base = Run-Suite $suite
        if ($base.Code -ne 0) { throw "Baseline $suite failed.`n$($base.Text)" }
        $counts[$suite] = $base.Count
    }
    $caught = 0
    $escaped = @()
    foreach ($case in $cases) {
        $file = Join-Path $scratch $paths[$case[0]]
        $suite = if ($case.Count -gt 5) { $case[5] } elseif ($case[0] -eq 'certificate') { 'Test-CompanyCertificate.ps1' } elseif ($case[0] -eq 'address') { 'Test-CompanyAddress.ps1' } else { 'Test-CompanyFlow.ps1' }
        $before = [IO.File]::ReadAllText($file)
        $source = $before.Replace("`r`n", "`n")
        $after = [regex]::Replace($source, $case[1], [Text.RegularExpressions.MatchEvaluator]{ param($m) $case[2] })
        if ($source -eq $after) { throw "Mutation target is absent: $($case[4])" }
        try {
            [IO.File]::WriteAllText($file, $after, (New-Object Text.UTF8Encoding($false)))
            $result = Run-Suite $suite
            if ($result.Code -eq 0 -or $result.Count -ne $counts[$suite] -or -not $result.Text.Contains('[FAIL] ' + $case[3])) {
                $escaped += $case[4]
                Write-Host "  [FAIL] $($case[4]): exit=$($result.Code), assertions=$($result.Count)/$($counts[$suite]); expected detector: $($case[3])"
                continue
            }
            $caught++
            Write-Host "  [OK] $($case[4]): caught, all $($result.Count) assertions ran."
        }
        finally { [IO.File]::WriteAllText($file, $before, (New-Object Text.UTF8Encoding($false))) }
    }
    Write-Host "Company address mutations: $caught/$($cases.Count) caught with complete assertion counts."
    if ($escaped.Count) { throw "Mutations not caught by their named detector: $($escaped -join ', ')" }
}
finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
