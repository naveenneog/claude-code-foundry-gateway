# P66 lifecycle flow: update migrations and change modules. Offline; no Azure writes.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Get-Thrown([scriptblock]$Block) { try { & $Block; return '' } catch { return $_.Exception.Message } }

. (Join-Path $root 'scripts\flow\FlowContract.ps1')
. (Join-Path $root 'scripts\flow\lib\LifecycleCommon.ps1')

Write-Host ''
Write-Host 'P66 lifecycle - migration detection' -ForegroundColor Cyan

$record = [pscustomobject]@{
    schemaVersion = 1
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    location = 'eastus2'
    sku = 'BasicV2'
}
$policyPath = Join-Path $root 'infra\policy.xml'
$currentPolicy = [IO.File]::ReadAllText($policyPath)
$refs = @(Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences -PolicyPath $policyPath)
$nv = @{}
foreach ($r in $refs) { $nv[$r] = 'x' }
$nv.Remove('usd-budgets')
$nv.Remove('external-idp-extra-audience')
foreach ($name in @('content-safety-mode','content-safety-endpoint','content-safety-threshold','content-safety-timeout-seconds','content-safety-truncate-mode')) { $nv.Remove($name) }
$oldDiscovery = [pscustomobject]@{
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    location = 'eastus2'
    sku = 'BasicV2'
    policy = '<policies><inbound><base /></inbound></policies>'
    namedValues = $nv
}

. (Join-Path $root 'scripts\flow\migrations\0001-record-schema-v2.ps1')
$schemaPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $oldDiscovery
Assert 'old schema is detected' (-not (Test-ClaudeFlowPlanIsNoop $schemaPlan) -and $schemaPlan.Actions[0].Detail -match '1 -> 2')

. (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1')
$policyPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $oldDiscovery
Assert 'old policy hash is detected' (@($policyPlan.Actions | Where-Object Target -eq 'apim policy claude-foundry').Count -eq 1)
Assert 'missing named values are derived from policy references' (($policyPlan.Data.MissingNamedValues -contains 'usd-budgets') -and ($policyPlan.Data.MissingNamedValues -contains 'external-idp-extra-audience'))
Assert 'fragment named values are included in the migration plan' (($policyPlan.Data.MissingNamedValues -contains 'content-safety-mode') -and ($policyPlan.Data.MissingNamedValues -contains 'content-safety-endpoint') -and ($policyPlan.Data.PolicyFragments -contains 'content-safety-screening')) (($policyPlan.Data.MissingNamedValues + $policyPlan.Data.PolicyFragments) -join ',')
$migration2Source = Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw
Assert 'derived named values include later-release values without hardcoding the detector list' ($migration2Source -match 'Get-ClaudeFlowLifecyclePolicyAndFragmentNamedValueReferences' -and $migration2Source -match '\$missing = @\(\$refs \| Where-Object')
Assert 'rollback plan names Restore-ClaudeGateway' ($policyPlan.Rollback -match 'Restore-ClaudeGateway')
Assert 'policy migration requires a snapshot before writes' ((Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw) -match 'Assert-ClaudeFlowLifecycleSnapshotBeforeWrite')

$allNv = @{}
foreach ($r in $refs) { $allNv[$r] = 'x' }

# P100 council round 4: the plan's target subscription reaches every write of the policy migration, so the
# migration writes where the update read the gateway.
$global:Migration2AzCalls = [Collections.Generic.List[string]]::new()
function global:az { $line = $args -join ' '; $global:Migration2AzCalls.Add($line); $global:LASTEXITCODE = 0; if ($line -match '^account get-access-token') { return 'offline-token' }; return '' }
function global:Invoke-RestMethod { $global:Migration2AzCalls.Add("HTTP $($args -join ' ')"); $null }
try {
    $scopedPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $oldDiscovery
    $scopedPlan.Data.Target.SubscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    $scopedPlan.Data.SnapshotPath = 'unused.json'; $scopedPlan.Data.SnapshotTaken = $true
    $thrown = Get-Thrown { Invoke-ClaudeFlowMigration -Record $record.PSObject.Copy() -Plan $scopedPlan | Out-Null }
    $nvWrites = @($global:Migration2AzCalls | Where-Object { $_ -match '^apim nv (show|create|update)' })
    Assert 'the policy migration reads and writes its named values in the plan''s subscription' (-not $thrown -and $nvWrites.Count -ge 2 -and @($nvWrites | Where-Object { $_ -notmatch '--subscription aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }).Count -eq 0) "$thrown | $($global:Migration2AzCalls -join ' ; ')"
    $tokenCalls = @($global:Migration2AzCalls | Where-Object { $_ -match '^account get-access-token' })
    Assert 'the policy migration takes its tokens for the plan''s subscription' ($tokenCalls.Count -ge 1 -and @($tokenCalls | Where-Object { $_ -notmatch '--subscription aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' }).Count -eq 0) ($global:Migration2AzCalls -join ' ; ')
    $callsText = $global:Migration2AzCalls -join "`n"
    $idxNv = $callsText.IndexOf('apim nv')
    $idxFragment = $callsText.IndexOf('/policyFragments/content-safety-screening')
    $idxPolicy = $callsText.IndexOf('/apis/claude-foundry/policies/policy')
    Assert 'the policy migration writes named values, then fragments, then the policy' ($idxNv -ge 0 -and $idxFragment -gt $idxNv -and $idxPolicy -gt $idxFragment) $callsText
    Assert 'fragment and policy writes use the plan subscription' ($callsText -match 'account get-access-token.*--subscription aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -and $callsText -match '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/.*/policyFragments/content-safety-screening' -and $callsText -match '/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/.*/apis/claude-foundry/policies/policy') $callsText
    $global:Migration2AzCalls.Clear()
    $changedFragmentDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $currentPolicy; namedValues = $allNv; policyFragments = @([pscustomobject]@{ name='content-safety-screening'; value='<fragment><choose /></fragment>' }) }
    $changedFragmentApplyPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $changedFragmentDiscovery
    if (Test-ClaudeFlowPlanIsNoop $changedFragmentApplyPlan) { $thrown = 'the plan was a no-op' }
    else {
        $changedFragmentApplyPlan.Data.Target.SubscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $changedFragmentApplyPlan.Data.SnapshotPath = 'unused.json'; $changedFragmentApplyPlan.Data.SnapshotTaken = $true
        $thrown = Get-Thrown { Invoke-ClaudeFlowMigration -Record $record.PSObject.Copy() -Plan $changedFragmentApplyPlan | Out-Null }
    }
    $changedCallsText = $global:Migration2AzCalls -join "`n"
    Assert 'policy migration applies PUT for an existing fragment whose canonical content differs' (-not $thrown -and $changedCallsText -match '/policyFragments/content-safety-screening' -and $changedCallsText -match '/apis/claude-foundry/policies/policy') "$thrown | $changedCallsText"
    $global:Migration2AzCalls.Clear()
    # P102 council round 2 (Coder): a fragment whose live content could not be read is written with the release content.
    $unreadApplyDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $currentPolicy; namedValues = $allNv; policyFragments = @([pscustomobject]@{ name='content-safety-screening'; value=''; canonicalHash=''; error='Response status code does not indicate success: 500 (Internal Server Error).' }) }
    $unreadApplyPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $unreadApplyDiscovery
    if (Test-ClaudeFlowPlanIsNoop $unreadApplyPlan) { $thrown = 'the plan was a no-op'; $unreadCallsText = '' }
    else {
        $unreadApplyPlan.Data.Target.SubscriptionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $unreadApplyPlan.Data.SnapshotPath = 'unused.json'; $unreadApplyPlan.Data.SnapshotTaken = $true
        $thrown = Get-Thrown { Invoke-ClaudeFlowMigration -Record $record.PSObject.Copy() -Plan $unreadApplyPlan | Out-Null }
        $unreadCallsText = $global:Migration2AzCalls -join "`n"
    }
    Assert 'policy migration writes the release content to a fragment whose live content could not be read' (-not $thrown -and $unreadCallsText -match '/policyFragments/content-safety-screening' -and $unreadCallsText -match '/apis/claude-foundry/policies/policy') "$thrown | $unreadCallsText"
    $global:Migration2AzCalls.Clear()
    $scopedPlan.Data.Target.SubscriptionId = 'not-an-id&calc'
    # No snapshot yet: a check placed after the backup would show the backup's Azure calls.
    $scopedPlan.Data.SnapshotTaken = $false; $scopedPlan.Data.SnapshotPath = Join-Path ([IO.Path]::GetTempPath()) ('p100-0002-' + [guid]::NewGuid().ToString('N') + '.json')
    $thrown = Get-Thrown { Invoke-ClaudeFlowMigration -Record $record.PSObject.Copy() -Plan $scopedPlan | Out-Null }
    Assert 'a target subscription that is not an ID is refused by the policy migration before any Azure call' ($thrown -match 'not a subscription id' -and $global:Migration2AzCalls.Count -eq 0 -and -not (Test-Path -LiteralPath $scopedPlan.Data.SnapshotPath)) "$thrown | $($global:Migration2AzCalls -join ' ; ')"
}
finally { Remove-Item Function:\az, Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }

$desiredFragment = [IO.File]::ReadAllText((Join-Path $root 'infra\content-safety-screening.xml'))
$global:LifecycleDiscoveryCalls = [Collections.Generic.List[string]]::new()
function global:az {
    $line = $args -join ' '
    $global:LifecycleDiscoveryCalls.Add("az $line")
    $global:LASTEXITCODE = 0
    switch -Regex ($line) {
        '^apim show ' { return (@{ id='/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/rg-contoso/providers/Microsoft.ApiManagement/service/apim-contoso'; location='eastus2'; sku=@{ name='BasicV2'; capacity=1 } } | ConvertTo-Json -Depth 5) }
        '^apim nv list ' { return (@(@{ name='content-safety-mode'; value='off' }) | ConvertTo-Json -Depth 5) }
        '^account get-access-token ' { return 'offline-token' }
        '^apim api ' { $global:LASTEXITCODE = 9; return "ERROR: az apim api policy-fragment does not exist" }
    }
    $global:LASTEXITCODE = 9
    return "unexpected az $line"
}
function global:Invoke-RestMethod {
    param($Method,$Uri,$Headers)
    $global:LifecycleDiscoveryCalls.Add("HTTP $Method $Uri")
    if ($Uri -match '/apis/claude-foundry/policies/policy\?api-version=2024-05-01&format=rawxml$') { return [pscustomobject]@{ properties=[pscustomobject]@{ value=$currentPolicy } } }
    if ($Uri -match '/policyFragments\?api-version=2024-05-01$') { return [pscustomobject]@{ value=@([pscustomobject]@{ name='content-safety-screening' }) } }
    if ($Uri -match '/policyFragments/content-safety-screening\?format=xml&api-version=2024-05-01$') {
        if ($global:LifecycleFragmentReadFails) { throw 'Response status code does not indicate success: 500 (Internal Server Error).' }
        return [pscustomobject]@{ properties=[pscustomobject]@{ value=$fragmentReadback } }
    }
    throw "unexpected REST URI $Uri"
}
# A fragment written with format=rawxml and read back with format=xml from a disposable API Management instance on
# 2026-10-07 (P102 probe), with the template it was written from. rawxml is "a non XML encoded policy document" and
# did not parse; xml parses, and API Management encodes the stored text once more.
$fragmentFixtures = Join-Path $root 'tests\fixtures\content-safety-fragment'
$fragmentReadback = [IO.File]::ReadAllText((Join-Path $fragmentFixtures 'apim-readback-format-xml.xml'))
$fragmentTemplate = [IO.File]::ReadAllText((Join-Path $fragmentFixtures 'template.xml'))
$fixtureTemplateHash = Get-ClaudeFlowLifecycleCanonicalXmlHash -XmlText $fragmentTemplate
$storedHash = try { Get-ClaudeFlowLifecycleStoredXmlHash -XmlText $fragmentReadback } catch { "error: $($_.Exception.Message)" }
Assert 'an API Management format=xml read-back hashes like the template it was written from (probe 2026-10-07)' ($fixtureTemplateHash -and $storedHash -eq $fixtureTemplateHash) "stored=$storedHash template=$fixtureTemplateHash"
Assert 'the read-back matches only after its stored text is decoded once more' ((Get-ClaudeFlowLifecycleCanonicalXmlHash -XmlText $fragmentReadback) -ne $fixtureTemplateHash) ''
$lfTemplate = $fragmentTemplate -replace "`r`n", "`n"
$crlfTemplate = $lfTemplate -replace "`n", "`r`n"
Assert 'line endings inside values do not change the canonical hash' ((Get-ClaudeFlowLifecycleCanonicalXmlHash -XmlText $lfTemplate) -eq (Get-ClaudeFlowLifecycleCanonicalXmlHash -XmlText $crlfTemplate)) ''
# P102 council round 4 (Coder): a character reference above 0xFFFF is one character made of two UTF-16 units.
$astral = try { ConvertFrom-ClaudeFlowLifecycleXmlEntities -Text 'smile &#x1F600; and &#128512;' } catch { "error: $($_.Exception.Message)" }
$smile = [char]::ConvertFromUtf32(0x1F600)
Assert 'character references above 0xFFFF decode to their character' ($astral -eq "smile $smile and $smile") $astral
$notCharacters = try { ConvertFrom-ClaudeFlowLifecycleXmlEntities -Text '&#x110000; &#xD800; &#99999999999;' } catch { "error: $($_.Exception.Message)" }
Assert 'a reference outside Unicode, to a surrogate, or too long to be a code point is left as written' ($notCharacters -eq '&#x110000; &#xD800; &#99999999999;') $notCharacters
$global:LifecycleFragmentReadFails = $false
try {
    $discovered = Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup 'rg-contoso' -ApimName 'apim-contoso' -SubscriptionId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert 'live discovery reads the policy fragment with format=xml and records the hash of its stored text' (@($discovered.policyFragments | Where-Object { $_.name -eq 'content-safety-screening' -and $_.value -match '<fragment>' -and $_.canonicalHash -eq $fixtureTemplateHash }).Count -eq 1 -and ($global:LifecycleDiscoveryCalls -join "`n") -match '/policyFragments/content-safety-screening\?format=xml&api-version=2024-05-01') ($global:LifecycleDiscoveryCalls -join ' ; ')
    $badAz = az apim api policy-fragment show --service-name apim-contoso --fragment-id content-safety-screening
    Assert 'fake az refuses nonexistent APIM policy-fragment commands' ($LASTEXITCODE -ne 0 -and $badAz -match 'does not exist') $badAz
    # P102 council round 2 (Coder): a failed fragment read is recorded with its error and warned about, and the plan
    # treats the fragment as not current, so the update neither skips it nor reports it verified.
    $global:LifecycleFragmentReadFails = $true
    $failedRead = @(Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup 'rg-contoso' -ApimName 'apim-contoso' -SubscriptionId 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' 3>&1)
    $readWarnings = (@($failedRead | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message }) -join ' ')
    $failedDiscovery = @($failedRead | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })[0]
    $failedEntry = @($failedDiscovery.policyFragments | Where-Object { $_.name -eq 'content-safety-screening' })[0]
    Assert 'live discovery records a failed fragment read with its error and warns with the fragment name and reason' ($failedEntry -and -not $failedEntry.canonicalHash -and $failedEntry.error -match '500' -and $readWarnings -match 'content-safety-screening' -and $readWarnings -match '500') "$readWarnings | $($failedDiscovery.policyFragments | ConvertTo-Json -Compress)"
    $failedReadDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $currentPolicy; namedValues = $allNv; policyFragments = $failedDiscovery.policyFragments }
    $failedReadPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $failedReadDiscovery
    $failedReadCheck = Test-ClaudeFlowMigration -Record $record -Discovery $failedReadDiscovery
    Assert 'a fragment read that failed in live discovery plans the fragment update and fails the migration check' (-not (Test-ClaudeFlowPlanIsNoop $failedReadPlan) -and @($failedReadPlan.Actions | Where-Object { $_.Target -eq 'policy fragment content-safety-screening' }).Count -eq 1 -and -not $failedReadCheck.Passed) (($failedReadPlan | ConvertTo-Json -Depth 8 -Compress) + ' | ' + ($failedReadCheck | ConvertTo-Json -Depth 8 -Compress))
}
finally { $global:LifecycleFragmentReadFails = $false; Remove-Item Function:\az, Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }

$currentFragments = @([pscustomobject]@{ name='content-safety-screening'; value=$desiredFragment })
$freshDiscovery = [pscustomobject]@{
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    location = 'eastus2'
    sku = 'BasicV2'
    policy = $currentPolicy
    namedValues = $allNv
    policyFragments = $currentFragments
    jobs = @()
}
$noopPolicy = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $freshDiscovery
Assert 'migration is idempotent when policy and named values match' (Test-ClaudeFlowPlanIsNoop $noopPolicy)
$freshWithFragment = $freshDiscovery.PSObject.Copy()
$freshWithFragment | Add-Member -NotePropertyName policyFragments -NotePropertyValue @([pscustomobject]@{ name='content-safety-screening'; value=($desiredFragment -replace '><', ">`r`n<") }) -Force
$noopWithFragment = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $freshWithFragment
Assert 'migration does not rewrite existing policy fragments or named values when canonical XML matches' (Test-ClaudeFlowPlanIsNoop $noopWithFragment)
$differentFragmentDiscovery = $freshDiscovery.PSObject.Copy()
$differentFragmentDiscovery | Add-Member -NotePropertyName policyFragments -NotePropertyValue @([pscustomobject]@{ name='content-safety-screening'; value='<fragment><choose /></fragment>' }) -Force
$differentFragmentPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $differentFragmentDiscovery
Assert 'live policy fragment content drift plans an update that names the differing fragment' (@($differentFragmentPlan.Actions | Where-Object { $_.Target -eq 'policy fragment content-safety-screening' -and $_.Verb -eq 'Update' -and $_.Detail -match 'content differs' }).Count -eq 1) ($differentFragmentPlan | ConvertTo-Json -Depth 8 -Compress)
$differentMigrationCheck = Test-ClaudeFlowMigration -Record $record -Discovery $differentFragmentDiscovery
Assert 'Test-ClaudeFlowMigration is not current when a live fragment content hash differs' (-not $differentMigrationCheck.Passed -and @($differentMigrationCheck.Checks | Where-Object { $_.Name -eq 'policy fragments' -and -not $_.Passed }).Count -eq 1) ($differentMigrationCheck | ConvertTo-Json -Depth 8 -Compress)
$missingFragmentPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $currentPolicy; namedValues = $allNv; policyFragments = @() })
Assert 'missing policy fragment still plans a create' (@($missingFragmentPlan.Actions | Where-Object { $_.Target -eq 'policy fragment content-safety-screening' -and $_.Verb -eq 'Create' }).Count -eq 1) ($missingFragmentPlan | ConvertTo-Json -Depth 8 -Compress)
Assert 'fragment content participates in the update fingerprint' ((Get-ClaudeFlowFingerprint @($noopWithFragment)) -ne (Get-ClaudeFlowFingerprint @($differentFragmentPlan))) 'fingerprints matched despite content drift'
# P102 council round 2 (QA): the approved fingerprint binds the exact fragment content, not only the action shape.
$otherContentDiscovery = $freshDiscovery.PSObject.Copy()
$otherContentDiscovery | Add-Member -NotePropertyName policyFragments -NotePropertyValue @([pscustomobject]@{ name='content-safety-screening'; value='<fragment><choose><otherwise /></choose></fragment>' }) -Force
$otherContentPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $otherContentDiscovery
$actionShape = { param($Plan) (@($Plan.Actions | ForEach-Object { "$($_.Verb) $($_.Target)" }) -join ';') }
Assert 'two different live fragment contents plan the same action shape' ((& $actionShape $differentFragmentPlan) -eq (& $actionShape $otherContentPlan) -and (& $actionShape $otherContentPlan) -match 'Update policy fragment content-safety-screening') "$(& $actionShape $differentFragmentPlan) | $(& $actionShape $otherContentPlan)"
Assert 'the update fingerprint differs for two different live fragment contents with the same action shape' ((Get-ClaudeFlowFingerprint @($differentFragmentPlan)) -ne (Get-ClaudeFlowFingerprint @($otherContentPlan))) 'fingerprints matched for different fragment contents'
$desiredFragmentHash = Get-ClaudeFlowLifecycleCanonicalXmlHash -XmlText $desiredFragment
$liveFragmentHash = Get-ClaudeFlowLifecycleCanonicalXmlHash -XmlText '<fragment><choose /></fragment>'
$fingerprinted = ConvertTo-ClaudeFlowCanonical @($differentFragmentPlan)
$plannedDesiredHashes = if ($differentFragmentPlan.Data) { $differentFragmentPlan.Data.DesiredPolicyFragmentHashes } else { $null }
$plannedLiveHashes = if ($differentFragmentPlan.Data) { $differentFragmentPlan.Data.LivePolicyFragmentHashes } else { $null }
$plannedDesiredHash = if ($plannedDesiredHashes) { [string]$plannedDesiredHashes['content-safety-screening'] } else { '' }
$plannedLiveHash = if ($plannedLiveHashes) { [string]$plannedLiveHashes['content-safety-screening'] } else { '' }
Assert 'the fingerprinted plan data holds the exact desired and live fragment hashes' ($desiredFragmentHash -and $liveFragmentHash -and $plannedDesiredHash -eq $desiredFragmentHash -and $plannedLiveHash -eq $liveFragmentHash -and $fingerprinted.Contains($desiredFragmentHash) -and $fingerprinted.Contains($liveFragmentHash)) ($differentFragmentPlan.Data | ConvertTo-Json -Depth 4 -Compress)
# P102 council round 2 (Coder): a fragment whose content could not be read, or that a discovery names without its
# content, is not current: the plan writes the release content and the check fails until a read returns content
# that matches.
$unreadDiscovery = $freshDiscovery.PSObject.Copy()
$unreadDiscovery | Add-Member -NotePropertyName policyFragments -NotePropertyValue @([pscustomobject]@{ name='content-safety-screening'; value=''; canonicalHash=''; error='Response status code does not indicate success: 500 (Internal Server Error).' }) -Force
$unreadPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $unreadDiscovery
Assert 'a policy fragment whose content could not be read plans an update that writes the release content' (@($unreadPlan.Actions | Where-Object { $_.Target -eq 'policy fragment content-safety-screening' -and $_.Verb -eq 'Update' -and $_.Detail -match 'could not be read' -and $_.Detail -match [regex]::Escape($desiredFragmentHash) }).Count -eq 1 -and @($unreadPlan.Data.UnreadPolicyFragments) -contains 'content-safety-screening') ($unreadPlan | ConvertTo-Json -Depth 8 -Compress)
$unreadCheck = Test-ClaudeFlowMigration -Record $record -Discovery $unreadDiscovery
Assert 'Test-ClaudeFlowMigration is not current when a live fragment could not be read' (-not $unreadCheck.Passed -and @($unreadCheck.Checks | Where-Object { $_.Name -eq 'policy fragments' -and -not $_.Passed -and $_.Evidence -match 'unread=content-safety-screening' }).Count -eq 1) ($unreadCheck | ConvertTo-Json -Depth 8 -Compress)
$nameOnlyDiscovery = $freshDiscovery.PSObject.Copy()
$nameOnlyDiscovery | Add-Member -NotePropertyName policyFragments -NotePropertyValue @('content-safety-screening') -Force
$nameOnlyPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery $nameOnlyDiscovery
Assert 'a policy fragment named without its content is not current' (@($nameOnlyPlan.Actions | Where-Object { $_.Target -eq 'policy fragment content-safety-screening' -and $_.Verb -eq 'Update' -and $_.Detail -match 'not in the discovery' }).Count -eq 1 -and -not (Test-ClaudeFlowMigration -Record $record -Discovery $nameOnlyDiscovery).Passed) ($nameOnlyPlan | ConvertTo-Json -Depth 8 -Compress)

$normalizedPolicy = '<policies>usd-budgets usd-budget-state external-idp-extra-audience urn:disabled:claude-extra-audience entitlement-source <include-fragment fragment-id="content-safety-screening" /></policies>'
$normalizedPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $normalizedPolicy; namedValues = $allNv; policyFragments = $currentFragments })
Assert 'APIM-normalized current policy markers do not cause repeated updates' (Test-ClaudeFlowPlanIsNoop $normalizedPlan)
$oldMarkedPolicy = '<policies>usd-budgets usd-budget-state external-idp-extra-audience urn:disabled:claude-extra-audience entitlement-source</policies>'
$oldMarkedPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $oldMarkedPolicy; namedValues = $allNv; policyFragments = $currentFragments })
Assert 'policy migration rewrites older marked policies that lack the content safety include' (@($oldMarkedPlan.Actions | Where-Object Target -eq 'apim policy claude-foundry').Count -eq 1 -and @($oldMarkedPlan.Data.MissingNamedValues).Count -eq 0 -and @($oldMarkedPlan.Data.MissingPolicyFragments).Count -eq 0) ($oldMarkedPlan | ConvertTo-Json -Depth 8 -Compress)

$blankAudience = @{}
foreach ($r in $refs) { $blankAudience[$r] = 'x' }
$blankAudience['external-idp-extra-audience'] = ' '
$blankPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; policy = $currentPolicy; namedValues = $blankAudience; policyFragments = $currentFragments })
Assert 'migration normalizes a blank Desktop audience before policy validation' ($blankPlan.Data.NormalizeDisabledAudience -eq $true -and (($blankPlan.Actions | ForEach-Object Target) -contains 'named value external-idp-extra-audience'))

. (Join-Path $root 'scripts\flow\migrations\0003-job-pins.ps1')
$jobPlan = Get-ClaudeFlowMigrationPlan -Record $record -Discovery ([pscustomobject]@{ jobs = @([pscustomobject]@{ name = 'turnstile-apply'; commit = 'old' }) })
Assert 'old job commit pins are detected when present' (-not (Test-ClaudeFlowPlanIsNoop $jobPlan) -and $jobPlan.Actions[0].Target -match 'turnstile-apply')

$migrationNames = @(Get-ChildItem (Join-Path $root 'scripts\flow\migrations') -Filter '*.ps1' | Sort-Object Name | ForEach-Object Name)
Assert 'migrations are ordered by numeric prefix' (($migrationNames -join ',') -match '^0001-.*0002-.*0003-') ($migrationNames -join ',')

Write-Host ''
Write-Host 'P66 lifecycle - change modules' -ForegroundColor Cyan

. (Join-Path $root 'scripts\flow\Tier.ps1')
function Get-ClaudeFlowLifecycleApimMonthlyCost {
    param([string]$Sku, [string]$Region, [int]$Units = 1)
    New-ClaudeFlowCost -Item "API Management $Sku" -MonthlyUsd ([decimal]($(if ($Sku -eq 'BasicV2') { 150 } elseif ($Sku -eq 'StandardV2') { 700 } else { 2800 }))) -Source 'test retail price'
}
$tierRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ sku = [pscustomobject]@{ target = 'StandardV2' } } }
$tierDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2' }
$tierOptions = @(Get-ClaudeFlowTierChangeOptions -Record $tierRecord -Discovery $tierDiscovery)
Assert 'tier options offer Basic v2 to Standard v2 in-place' (@($tierOptions | Where-Object { $_.Key -eq 'StandardV2' -and $_.InPlace }).Count -eq 1)
Assert 'tier options do not offer Premium v2 injection as in-place' (@($tierOptions | Where-Object { $_.Key -eq 'PremiumV2' -and (-not $_.InPlace) }).Count -eq 1)
$tierQuestions = @(Get-ClaudeFlowStepQuestions -Record $tierRecord -Discovery $tierDiscovery)
Assert 'tier question uses orchestrator property names' ($tierQuestions[0].Key -eq 'sku' -and $tierQuestions[0].Question -and $tierQuestions[0].WhereToFind -and $tierQuestions[0].PSObject.Properties.Name -contains 'AcceptRecommendedWithoutConsole')
$tierPlan = Get-ClaudeFlowStepPlan -Record $tierRecord -Discovery $tierDiscovery
Assert 'tier plan includes live retail cost and Microsoft Learn research citations' ($tierPlan.Costs[0].MonthlyUsd -eq 700 -and (($tierPlan.Implications -join "`n") -match 'learn.microsoft.com/en-us/azure/api-management'))
Assert 'tier apply snapshots before in-place write' ((Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'Assert-ClaudeFlowLifecycleSnapshotBeforeWrite')
Assert 'tier apply uses a v2-capable ARM API version' ((Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'api-version=2024-05-01' -and (Get-Content (Join-Path $root 'scripts\flow\Tier.ps1') -Raw) -match 'Invoke-RestMethod -Method Patch')

. (Join-Path $root 'scripts\flow\Entitlement.ps1')
$entRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ entitlementStore = [pscustomobject]@{ target = 'projection' } } }
$entDiscovery = [pscustomobject]@{ resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'; namedValues = @{ 'entitlement-source' = 'named-value' }; cleanComparison = $false }
$entPlan = Get-ClaudeFlowStepPlan -Record $entRecord -Discovery $entDiscovery
Assert 'entitlement plan states Basic v2 public Entra resolver rule' (($entPlan.Implications -join "`n") -match 'Basic v2 uses a public resolver endpoint')
# The gateway answers that it has no entitlement-projection-prefix named value (Get-ApimNamedValue returns null for
# not found). A read without -FailOnError would turn an az failure into this same refusal, so the stub rejects it.
function global:Get-ApimNamedValue { param($ResourceGroup, $ApimName, $Id, [switch]$FailOnError) if (-not $FailOnError) { throw 'prefix read without -FailOnError' }; $null }
Assert 'entitlement flip is refused without projection prefix before backup/write' ((Get-Thrown { Invoke-ClaudeFlowStep -Record $entRecord -Plan $entPlan }) -match 'entitlement-projection-prefix' -and (Get-Thrown { Invoke-ClaudeFlowStep -Record $entRecord -Plan $entPlan }) -match 'Deploy-ClaudeProjection\.ps1')
Remove-Item -LiteralPath function:global:Get-ApimNamedValue -ErrorAction SilentlyContinue
$entQuestions = @(Get-ClaudeFlowStepQuestions -Record $entRecord -Discovery $entDiscovery)
Assert 'entitlement question uses orchestrator property names' ($entQuestions[0].Key -eq 'entitlementStore' -and $entQuestions[0].Question -and $entQuestions[0].WhereToFind)

. (Join-Path $root 'scripts\flow\Network.ps1')
$netRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{ network = [pscustomobject]@{ reviewPath = 'review.json' } } }
$netPlan = Get-ClaudeFlowStepPlan -Record $netRecord -Discovery $tierDiscovery
Assert 'network flow keeps its own fingerprint approval requirement' (($netPlan.Implications -join "`n") -match 'not a substitute' -and (Get-Thrown { Invoke-ClaudeFlowStep -Record $netRecord -Plan $netPlan }) -match 'reviewed plan fingerprint')
$netQuestions = @(Get-ClaudeFlowStepQuestions -Record $netRecord -Discovery $tierDiscovery)
Assert 'network question uses orchestrator property names' ($netQuestions[0].Key -eq 'network.reviewPath' -and $netQuestions[0].WhereToFind)

. (Join-Path $root 'scripts\flow\DesktopSignIn.ps1')
$desktopRecord = [pscustomobject]@{ schemaVersion = 2; decisions = [pscustomobject]@{} }
$desktopDiscovery = [pscustomobject]@{
    resourceGroup = 'rg-contoso'; apimName = 'apim-contoso'; location = 'eastus2'; sku = 'BasicV2'
    namedValues = @{ 'external-idp-extra-audience' = '' }
    desiredDesktopSignIn = [pscustomobject]@{
        kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'access_token'
        clientId = '11111111-1111-1111-1111-111111111111'
        issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0'
        scopes = 'api://gateway-claude/user_impersonation'
        audience = 'api://gateway-claude'
    }
}
$desktopPlan = Get-ClaudeFlowStepPlan -Record $desktopRecord -Discovery $desktopDiscovery
Assert 'desktop sign-in change writes the extra audience and flags device profile regeneration' (($desktopPlan.Actions | ForEach-Object Target) -contains 'named value external-idp-extra-audience' -and (($desktopPlan.Actions | ForEach-Object Detail) -join ' ') -match 'regenerated')
Assert 'desktop sign-in apply snapshots before audience write' ((Get-Content (Join-Path $root 'scripts\flow\DesktopSignIn.ps1') -Raw) -match 'Assert-ClaudeFlowLifecycleSnapshotBeforeWrite')
$desktopQuestions = @(Get-ClaudeFlowStepQuestions -Record $desktopRecord -Discovery $desktopDiscovery)
Assert 'desktop question uses orchestrator property names' ($desktopQuestions[0].Key -eq 'desktopSignIn' -and $desktopQuestions[0].AcceptRecommendedWithoutConsole)

Write-Host ''
Write-Host 'P96 - the Tier and Desktop sign-in changes name their snapshot as Start prepares them' -ForegroundColor Cyan
# Start-ClaudeGateway.ps1 removes the step functions, dot-sources each module and keeps its Initialize-ClaudeFlowStep
# as Prepare (Start-ClaudeGateway.ps1:154-176). A module without one gets none, and its write gate then stops with
# "A named-value snapshot path is required". The same sequence here, with a repository root whose
# Backup-ClaudeGateway.ps1 writes the snapshot file.
$stubRoot = Join-Path ([IO.Path]::GetTempPath()) ('p96-flow-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $stubRoot 'scripts') | Out-Null
[IO.File]::WriteAllText((Join-Path $stubRoot 'scripts\Backup-ClaudeGateway.ps1'), "param([string]`$ResourceGroup, [string]`$ApimName, [string]`$Path, [string]`$SubscriptionId)`nNew-Item -ItemType Directory -Force -Path (Split-Path `$Path -Parent) | Out-Null`n[IO.File]::WriteAllText(`$Path, '{}')`nexit 0`n")
$prepared = @(foreach ($case in @(
            @{ Module = 'Tier.ps1'; Record = $tierRecord; Discovery = $tierDiscovery; Prefix = 'before-tier-apim-contoso-' }
            @{ Module = 'DesktopSignIn.ps1'; Record = $desktopRecord; Discovery = $desktopDiscovery; Prefix = 'before-desktop-sign-in-apim-contoso-' }
        )) {
        foreach ($name in 'Get-ClaudeFlowStepPlan', 'Initialize-ClaudeFlowStep', 'Invoke-ClaudeFlowStep') { Remove-Item "function:\$name" -Force -ErrorAction SilentlyContinue }
        . (Join-Path $root "scripts\flow\$($case.Module)")
        $prepare = if (Get-Command Initialize-ClaudeFlowStep -ErrorAction SilentlyContinue) { (Get-Command Initialize-ClaudeFlowStep).ScriptBlock } else { $null }
        $plan = Get-ClaudeFlowStepPlan -Record $case.Record -Discovery $case.Discovery
        $realRoot = ${function:Get-ClaudeFlowLifecycleRepoRoot}
        Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value ([scriptblock]::Create("'$stubRoot'"))
        try {
            if ($prepare) { & $prepare -Record $case.Record -Plan $plan | Out-Null }
            $gate = Get-Thrown { Assert-ClaudeFlowLifecycleSnapshotBeforeWrite -Plan $plan }
        }
        finally { Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value $realRoot }
        $path = [string]$plan.Data.SnapshotPath
        if (-not ($prepare -and -not $gate -and $path -and (Split-Path $path -Leaf).StartsWith($case.Prefix) -and (Split-Path (Split-Path $path -Parent) -Leaf) -eq 'backups' -and
                (Test-Path -LiteralPath $path) -and $plan.Data.SnapshotTaken -eq $true)) {
            "$($case.Module): prepare $([bool]$prepare), gate '$gate', path '$path'"
        }
    })
Assert 'Tier and Desktop sign-in name their snapshot under backups/ when Start prepares them, and the write gate takes it' (-not $prepared.Count) ($prepared -join ' || ')
# The Entitlement step keeps its file name. The shared helper leaves a plan with no actions, and a plan that already
# names its snapshot, as they are.
foreach ($name in 'Get-ClaudeFlowStepPlan', 'Initialize-ClaudeFlowStep', 'Invoke-ClaudeFlowStep') { Remove-Item "function:\$name" -Force -ErrorAction SilentlyContinue }
. (Join-Path $root 'scripts\flow\Entitlement.ps1')
$entitlementPlan = [pscustomobject]@{ Actions = @(@{ Verb = 'Update'; Target = 'entitlement-source' }); Data = @{ Target = @{ ApimName = 'apim-contoso' }; SnapshotPath = $null; SnapshotTaken = $false } }
$noopPlan = [pscustomobject]@{ Actions = @(); Data = @{ Target = @{ ApimName = 'apim-contoso' }; SnapshotPath = $null; SnapshotTaken = $false } }
$namedPlan = [pscustomobject]@{ Actions = @(@{ Verb = 'Update'; Target = 'sku' }); Data = @{ Target = @{ ApimName = 'apim-contoso' }; SnapshotPath = 'kept.json'; SnapshotTaken = $false } }
$realRoot = ${function:Get-ClaudeFlowLifecycleRepoRoot}
Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value ([scriptblock]::Create("'$stubRoot'"))
try {
    Initialize-ClaudeFlowStep -Record $desktopRecord -Plan $entitlementPlan
    Initialize-ClaudeFlowLifecycleSnapshotPath -Plan $noopPlan -Step tier
    Initialize-ClaudeFlowLifecycleSnapshotPath -Plan $namedPlan -Step tier
}
finally { Set-Item -Path function:global:Get-ClaudeFlowLifecycleRepoRoot -Value $realRoot }
$entitlementLeaf = Split-Path ([string]$entitlementPlan.Data.SnapshotPath) -Leaf
Assert 'the Entitlement step keeps its snapshot name, before-entitlement-<gateway>-<time>.json' ($entitlementLeaf -match '^before-entitlement-apim-contoso-\d{8}T\d{6}Z\.json$') $entitlementLeaf
Assert 'a plan with no actions gets no snapshot path' (-not $noopPlan.Data.SnapshotPath) ([string]$noopPlan.Data.SnapshotPath)
Assert 'a plan that already names its snapshot keeps that path' ($namedPlan.Data.SnapshotPath -eq 'kept.json') ([string]$namedPlan.Data.SnapshotPath)
Remove-Item -LiteralPath $stubRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'P102 lifecycle - Foundation preserves Content Safety' -ForegroundColor Cyan
foreach ($name in 'Get-ClaudeFlowStepPlan', 'Initialize-ClaudeFlowStep', 'Invoke-ClaudeFlowStep') { Remove-Item "function:\$name" -Force -ErrorAction SilentlyContinue }
. (Join-Path $root 'scripts\flow\Foundation.ps1')
function Get-ClaudeFlowFoundationCost { param([string]$Sku, [string]$Location) New-ClaudeFlowCost -Item "API Management $Sku" -MonthlyUsd 150 -Source fixture }
$safetyRecord = [pscustomobject]@{
    schemaVersion = 2
    subscriptionId = '00000000-0000-4000-8000-0000000000a1'
    resourceGroup = 'rg-contoso'
    apimName = 'apim-contoso'
    decisions = [pscustomobject]@{
        foundation = [pscustomobject]@{
            contentSafetyMode = 'block'
            foundryAccount = 'ai-contoso'
            foundryResourceGroup = 'rg-ai'
        }
    }
}
$safetyPlan = Get-ClaudeFlowStepPlan -Record $safetyRecord -Discovery ([pscustomobject]@{ action = 'Change'; attended = $false; gateway = [pscustomobject]@{ sku = 'BasicV2'; location = 'eastus2' } })
Assert 'Foundation change passes the recorded Content Safety mode back to the installer' ([string]$safetyPlan.Data.installerArgs.ContentSafetyMode -eq 'block') ($safetyPlan.Data.installerArgs | ConvertTo-Json -Depth 5 -Compress)

Write-Host ''
Write-Host 'P66 lifecycle - plans write nothing' -ForegroundColor Cyan
$updateScript = Get-Content (Join-Path $root 'scripts\Update-ClaudeGateway.ps1') -Raw
$rootUpdateScript = Get-Content (Join-Path $root 'Update-ClaudeGateway.ps1') -Raw
Assert 'standalone update has plan-only default' ($updateScript -match 'Plan only\. Nothing has been changed' -and $updateScript -match 'Add -Apply')
Assert 'root update shim delegates to scripts updater for orchestrator compatibility' ($rootUpdateScript -match 'scripts\\Update-ClaudeGateway\.ps1' -and $rootUpdateScript -match 'RecordPath')
Assert 'standalone update fingerprints before apply' ($updateScript -match 'Get-ClaudeFlowFingerprint' -and $updateScript -match 'ApprovedPlanFingerprint')
Assert 'standalone update uses a stable default snapshot path so the approval fingerprint can be reused' ($updateScript -match 'before-update-\$\(\$target\.ApimName\)\.json' -and $updateScript -notmatch 'before-update-\$\(\$target\.ApimName\)-\$stamp')
Assert 'standalone update writes release and record only after applying' ($updateScript.IndexOf('Set-ClaudeDecisionRelease') -gt $updateScript.IndexOf('foreach ($file in $migrationFiles)'))
Assert 'plans do not call Set-ApimNamedValue directly' ((Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw).IndexOf('function Get-ClaudeFlowMigrationPlan') -lt (Get-Content (Join-Path $root 'scripts\flow\migrations\0002-policy-and-named-values.ps1') -Raw).IndexOf('function Invoke-ClaudeFlowMigration'))

Write-Host ''
Write-Host 'P66 lifecycle - live discovery reads the CLI shape' -ForegroundColor Cyan
# az apim nv list returns flattened objects (name, value, secret at the top level). Measured
# 2026-09-27 on a gateway installed by the current release: reading properties.value made every
# value empty, so Update planned a false "whitespace/empty -> disabled URI sentinel" change.
$liveShape = & {
    function az {
        $joined = $args -join ' '
        if ($joined -like 'apim show*') { return '{"id":"/subscriptions/s1/resourceGroups/rg-x/providers/Microsoft.ApiManagement/service/apim-x","location":"eastus2","sku":{"name":"BasicV2","capacity":1}}' }
        if ($joined -like 'apim nv list*') { return '[{"name":"external-idp-extra-audience","value":"urn:disabled:claude-extra-audience","secret":false},{"name":"entitlement-source","value":"named-value","secret":false},{"name":"a-secret","value":null,"secret":true}]' }
        if ($joined -like 'account get-access-token*') { return 'token' }
        throw "unexpected az $joined"
    }
    function Invoke-RestMethod { [pscustomobject]@{ properties = [pscustomobject]@{ value = '<policies />' } } }
    Get-ClaudeFlowLifecycleLiveDiscovery -ResourceGroup rg-x -ApimName apim-x
}
$liveMap = Get-ClaudeFlowLifecycleNamedValueMap -Discovery $liveShape
Assert 'live discovery reads named-value values from the CLI output' ($liveMap['external-idp-extra-audience'] -eq 'urn:disabled:claude-extra-audience' -and $liveMap['entitlement-source'] -eq 'named-value') (($liveMap.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
Assert 'live discovery leaves secret named values out' (-not $liveMap.ContainsKey('a-secret'))

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Lifecycle flow contract holds.' -ForegroundColor Green
exit 0
