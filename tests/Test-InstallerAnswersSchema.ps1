# P92 A1-A4 and acceptance test 1 (docs/adr/0047-lean-installer-phase-0.md): one answers schema, read
# the same way by both installers and the guided flow. The PowerShell validator
# (scripts/ClaudeInstallerAnswers.ps1) and the bash validator (scripts/install-answers.sh, with jq) check
# one corpus of answers files: each invalid file fails under the check id that owns its rule, and the
# two validators report the same problems, word for word.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($label, $condition, $detail = '') {
    $script:checks++
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
Write-Host ''
Write-Host 'Installer answers schema (both validators)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()

$ids = @('answers.schema', 'answers.crossField', 'target.tenant', 'target.subscription', 'operator.adminPrereqs', 'foundry.account', 'foundry.deployments',
    'apim.nameAvailability', 'apim.existingSku', 'apim.existingIdentity', 'entra.groupNames', 'businessUnits.ids', 'businessUnits.depth', 'address.inputs')
$consumers = @('Install-ClaudeGateway.ps1', 'install-claude-gateway.sh', 'Start-ClaudeGateway.ps1')

# ------------------------------------------------------------------ the schema document
$schemaPath = Join-Path $root 'schemas/claude-gateway.answers.schema.json'
$schema = $null; $schemaError = ''
# Read as Windows PowerShell 5.1 reads it: without -AsHashtable, names that differ only in case fail.
try { $schema = [IO.File]::ReadAllText($schemaPath) | ConvertFrom-Json -ErrorAction Stop } catch { $schemaError = $_.Exception.Message }
Assert 'A1 the schema is JSON that both PowerShell hosts read (no names that differ only in case)' ($null -ne $schema -and -not $schemaError) $schemaError
$top = if ($schema) { @($schema.PSObject.Properties.Name) } else { @() }
Assert 'A1 the schema states $schema 2020-12, $id, version 1, title, type object, properties, $defs, required and additionalProperties false' ($schema -and
    $schema.'$schema' -eq 'https://json-schema.org/draft/2020-12/schema' -and [string]$schema.'$id' -match '^https://.+claude-gateway\.answers\.schema\.json$' -and $schema.version -eq 1 -and
    $schema.title -and $schema.type -eq 'object' -and $schema.properties -and $schema.'$defs' -and $top -contains 'required' -and $schema.additionalProperties -eq $false) ($top -join ', ')
$props = if ($schema -and $schema.properties) { @($schema.properties.PSObject.Properties) } else { @() }
$badLabel = @($props | Where-Object { -not $_.Value.title -or -not @($_.Value.'x-appliedBy').Count -or @(@($_.Value.'x-appliedBy') | Where-Object { $_ -notin $consumers }).Count } | ForEach-Object Name)
Assert 'A1 every answer has a UI label (title) and names the programs that apply it' ($props.Count -gt 40 -and -not $badLabel.Count) "$($props.Count) answers; without: $($badLabel -join ', ')"
$checkIds = if ($schema) { @($schema.'x-preflightChecks' | ForEach-Object { [string]$_.id }) } else { @() }
$badIds = @($props | Where-Object { $_.Value.'x-checkId' -and [string]$_.Value.'x-checkId' -notin $ids } | ForEach-Object Name)
Assert 'A9 the schema lists the 14 stable preflight check ids in order, and every x-checkId is one of them' (($checkIds -join ',') -eq ($ids -join ',') -and -not $badIds.Count) "$($checkIds -join ','); $($badIds -join ', ')"
$req = { param($n) if ($schema -and $schema.properties.$n) { @($schema.properties.$n.requires) } else { @() } }
$kv = @(& $req 'AddressKeyVaultCertificateId'); $pfx = @(& $req 'AddressPfxPath'); $zone = @(& $req 'AddressDnsZoneResourceId'); $client = @(& $req 'DesktopEntraClientId')
Assert 'A1 conditional answers carry declarative requires: equality (certificate source, DNS mode) and membership (Desktop sign-in)' (
    $kv.Count -eq 1 -and $kv[0].answer -eq 'AddressCertificateSource' -and $kv[0].equals -eq 'KeyVault' -and $pfx.Count -eq 1 -and $pfx[0].equals -eq 'Pfx' -and
    $zone.Count -eq 1 -and $zone[0].answer -eq 'AddressDnsMode' -and $zone[0].equals -eq 'AzureDns' -and $client.Count -eq 1 -and (@($client[0].in) -join ',') -eq 'external-idp-browser,external-idp-broker') (
    ($kv + $pfx + $zone + $client | ConvertTo-Json -Compress -Depth 4))
# DesktopBearerTokenType names a choice (id_token or access_token), not a token; every other name with
# Token in it would hold one.
$secretNamed = @($props | Where-Object { $_.Name -match '(?i)password|secret|(?<!bearer)token' } | ForEach-Object Name)
$secrets = if ($schema) { @($schema.'x-secrets'.PSObject.Properties.Name) } else { @() }
Assert 'A4 no answer is a secret: AddressCertificatePassword is listed as a secret, and no answer is named like one' ($secrets -contains 'AddressCertificatePassword' -and -not $secretNamed.Count -and
    -not ($props.Name -contains 'AddressCertificatePassword')) ($secretNamed -join ', ')
$bu = if ($schema) { $schema.properties.BusinessUnits } else { $null }
$unit = if ($bu -and $bu.items.'$ref') { $schema.'$defs'.(([string]$bu.items.'$ref') -replace '^#/\$defs/', '') } else { $null }
Assert 'A3 BusinessUnits is a structured list: id, group, optional parent, monthlyUsdBudget and mode, nothing else' ($unit -and $unit.additionalProperties -eq $false -and
    ((@($unit.required) | Sort-Object) -join ',') -eq 'group,id,mode,monthlyUsdBudget' -and ((@($unit.properties.PSObject.Properties.Name) | Sort-Object) -join ',') -eq 'group,id,mode,monthlyUsdBudget,parent,percent' -and
    ((@($unit.properties.mode.enum)) -join ',') -eq 'Strict,Allowance,Notify') ($unit | ConvertTo-Json -Compress -Depth 6)

# ------------------------------------------------------------------ the corpus
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p92-answers-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false)) }
$units = @(
    [ordered]@{ id = 'finance'; group = 'claude-bu-finance'; monthlyUsdBudget = 5000; mode = 'Strict' }
    [ordered]@{ id = 'engineering'; group = 'claude-bu-engineering'; monthlyUsdBudget = 8000; mode = 'Allowance'; percent = 20 }
    [ordered]@{ id = 'finance-emea'; group = 'claude-team-finance-emea'; parent = 'finance'; monthlyUsdBudget = 1000; mode = 'Notify' }
    [ordered]@{ id = 'platform'; group = 'claude-team-platform'; parent = 'engineering'; monthlyUsdBudget = 2000; mode = 'Strict' }
)
$valid = [ordered]@{
    schemaVersion = 1; SubscriptionId = '00000000-0000-4000-8000-0000000000a1'; FoundryAccount = 'ai-p92'; FoundryResourceGroup = 'rg-ai-p92'; ResourceGroup = 'rg-p92'
    Location = 'eastus2'; NamePrefix = 'p92gw'; PublisherEmail = 'ops@contoso.com'; Sku = 'BasicV2'; TpmStandard = 20000; QuotaStandard = 500000; TpmPremium = 80000
    QuotaPremium = 5000000; QuotaOrg = 100000000; CallsPerMinute = 120; StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium'
    StandardModels = @('claude-sonnet-5'); PremiumModels = @('claude-sonnet-5', 'claude-opus-5'); EntitlementStore = 'named-value'; AuthMode = 'interactive'
    DesktopSignInKind = 'helper-script'; RevocationWindowSeconds = 3600; TeamBudgetBehaviour = 'report'; UnassignedDevelopers = 'allow'; DeveloperEstimate = 50
    AddressMode = 'custom'; AddressHostname = 'claude.contoso.com'; AddressCertificateSource = 'KeyVault'
    AddressKeyVaultCertificateId = 'https://kv-contoso.vault.azure.net/certificates/company'; AddressDnsMode = 'External'; BusinessUnits = $units
}
$bashValid = [ordered]@{ schemaVersion = 1; SubscriptionId = '00000000-0000-4000-8000-0000000000a1'; FoundryAccount = 'ai-p92'; FoundryResourceGroup = 'rg-ai-p92'
    ResourceGroup = 'rg-p92'; Location = 'eastus2'; NamePrefix = 'p92gw'; PublisherEmail = 'ops@contoso.com'; Sku = 'StandardV2'; TpmStandard = 20000; QuotaStandard = 500000
    TpmPremium = 80000; QuotaPremium = 5000000; CallsPerMinute = 120; StandardGroup = 'claude-code-standard'; PremiumGroup = 'claude-code-premium' }
$flowValid = [ordered]@{ 'foundation.sku' = 'BasicV2'; 'foundation.entitlementStore' = 'named-value'; 'foundation.authMode' = 'device'; 'foundation.desktopSignInKind' = 'helper-script'
    'foundation.resourceGroup' = 'rg-p92'; 'address.hostname' = 'claude.contoso.com'; 'address.certificateSource' = 'Pfx'; 'address.pfxPath' = './company.pfx'; 'address.dnsMode' = 'External'
    'budgets.currency' = 'usd'; 'monitoring.enabled' = 'true'; 'models.tiers.claude-sonnet-5' = 'both'; 'deviceProfiles.conversationStorage' = 'local' }
$cases = [System.Collections.Generic.List[object]]::new()
function Add-Case([string]$Name, [string]$Consumer, [string[]]$Expected, $Base, [scriptblock]$Change, [string]$Text) {
    $file = Join-Path $scratch "$Name.json"
    if ($PSBoundParameters.ContainsKey('Text')) { Write-Lf $file $Text }
    else {
        $doc = ($Base | ConvertTo-Json -Depth 10) | ConvertFrom-Json
        if ($Change) { & $Change $doc }
        Write-Lf $file ($doc | ConvertTo-Json -Depth 10)
    }
    $cases.Add([pscustomobject]@{ Name = $Name; Consumer = $Consumer; Expected = @($Expected); File = $file })
}
function Set-Answer($Doc, [string]$Name, $Value) { $Doc | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
$pw = 'Install-ClaudeGateway.ps1'; $sh = 'install-claude-gateway.sh'; $fl = 'Start-ClaudeGateway.ps1'
Add-Case 'valid' $pw @() $valid
Add-Case 'valid-bash' $sh @() $bashValid
Add-Case 'valid-flow' $fl @() $flowValid
# The lead's list: each fails under its own check id.
Add-Case 'unknown-property' $pw @('answers.schema') $valid { param($d) Set-Answer $d 'Bogus' 1 }
Add-Case 'bu-upper-id' $pw @('businessUnits.ids') $valid { param($d) $d.BusinessUnits[3].id = 'Platform' }
Add-Case 'bu-group-quote' $pw @('entra.groupNames') $valid { param($d) $d.BusinessUnits[1].group = "claude-bu-o'brien" }
Add-Case 'bu-group-comma' $pw @('entra.groupNames') $valid { param($d) $d.BusinessUnits[1].group = 'claude-bu-a,b' }
Add-Case 'bu-group-colon' $pw @('entra.groupNames') $valid { param($d) $d.BusinessUnits[1].group = 'claude-bu-a:b' }
Add-Case 'bu-depth-3' $pw @('businessUnits.depth') $valid { param($d) $d.BusinessUnits += [pscustomobject][ordered]@{ id = 'emea-pay'; group = 'claude-team-emea-pay'; parent = 'finance-emea'; monthlyUsdBudget = 100; mode = 'Strict' } }
Add-Case 'bu-allowance-no-percent' $pw @('answers.crossField') $valid { param($d) $d.BusinessUnits[1].PSObject.Properties.Remove('percent') }
Add-Case 'bu-allowance-0' $pw @('answers.schema') $valid { param($d) $d.BusinessUnits[1].percent = 0 }
Add-Case 'bu-allowance-101' $pw @('answers.schema') $valid { param($d) $d.BusinessUnits[1].percent = 101 }
Add-Case 'bu-negative-budget' $pw @('answers.schema') $valid { param($d) $d.BusinessUnits[0].monthlyUsdBudget = -5 }
Add-Case 'secret-answer' $pw @('answers.schema') $valid { param($d) Set-Answer $d 'AddressCertificatePassword' 'not-a-real-password' }
# Further rules the preflight reports from the answers alone.
Add-Case 'tier-group-quote' $pw @('entra.groupNames') $valid { param($d) $d.StandardGroup = "O'Brien" }
Add-Case 'kv-url-malformed' $pw @('address.inputs') $valid { param($d) $d.AddressKeyVaultCertificateId = 'http://kv-contoso/certificates' }
Add-Case 'custom-address-no-hostname' $pw @('address.inputs') $valid { param($d) $d.PSObject.Properties.Remove('AddressHostname') }
Add-Case 'bu-duplicate-id' $pw @('businessUnits.ids') $valid { param($d) $d.BusinessUnits[3].id = 'finance-emea' }
Add-Case 'bu-unknown-parent' $pw @('businessUnits.depth') $valid { param($d) $d.BusinessUnits[3].parent = 'nosuch' }
Add-Case 'bu-percent-not-allowance' $pw @('answers.crossField') $valid { param($d) $d.BusinessUnits[0] | Add-Member -NotePropertyName percent -NotePropertyValue 10 }
Add-Case 'wrong-type' $pw @('answers.schema') $valid { param($d) $d.TpmStandard = 'lots' }
Add-Case 'classic-sku-answer' $pw @('answers.schema') $valid { param($d) $d.Sku = 'Developer' }
Add-Case 'schema-version-2' $pw @('answers.schema') $valid { param($d) $d.schemaVersion = 2 }
Add-Case 'desktop-without-client' $pw @('answers.crossField') $valid { param($d) $d.DesktopSignInKind = 'external-idp-browser' }
Add-Case 'flow-key-in-installer-file' $pw @('answers.schema') $valid { param($d) Set-Answer $d 'foundation.sku' 'BasicV2' }
Add-Case 'bash-unsupported-answer' $sh @('answers.schema') $bashValid { param($d) Set-Answer $d 'AddressMode' 'azure' }
Add-Case 'flow-installer-name' $fl @('answers.schema') $flowValid { param($d) Set-Answer $d 'Sku' 'BasicV2' }
Add-Case 'flow-bad-choice' $fl @('answers.schema') $flowValid { param($d) $d.'budgets.currency' = 'euros' }
# The three P86 renewal inputs the main merge brought (cfb9dd7) are answers, as ProjectionReconcilerResourceId,
# the fourth input P86 admission requires, is. An action group's id reads Microsoft.Insights/actionGroups in a
# request and microsoft.insights/actionGroups in a response (Learn, Action Groups - Get).
$renewal = [ordered]@{ ProjectionReconcilerResourceId = '/subscriptions/00000000-0000-4000-8000-0000000000a1/resourceGroups/rg-p92/providers/Microsoft.App/jobs/p92gw-reconciler'
    ProjectionRenewalImageDigest = 'sha256:' + ('a' * 64); ProjectionRenewalEntryPoint = 'node /app/sync/src/apply-projection.mjs'
    ProjectionRenewalActionGroupResourceId = '/subscriptions/00000000-0000-4000-8000-0000000000a1/resourceGroups/rg-p92/providers/Microsoft.Insights/actionGroups/ag-projection-renewal' }
Add-Case 'projection-renewal' $pw @() $valid { param($d) foreach ($k in $renewal.Keys) { Set-Answer $d $k $renewal[$k] } }
Add-Case 'projection-renewal-response-casing' $pw @() $valid { param($d) foreach ($k in $renewal.Keys) { Set-Answer $d $k $renewal[$k] }
    $d.ProjectionRenewalActionGroupResourceId = '/subscriptions/00000000-0000-4000-8000-0000000000a1/resourcegroups/rg-p92/providers/microsoft.insights/actionGroups/ag-projection-renewal' }
Add-Case 'projection-digest-malformed' $pw @('answers.schema') $valid { param($d) Set-Answer $d 'ProjectionRenewalImageDigest' 'sha256:ABC' }
Add-Case 'projection-action-group-not-id' $pw @('answers.schema') $valid { param($d) Set-Answer $d 'ProjectionRenewalActionGroupResourceId' 'ag-projection-renewal' }
Add-Case 'projection-entry-point-empty' $pw @('answers.schema') $valid { param($d) Set-Answer $d 'ProjectionRenewalEntryPoint' '' }
Add-Case 'not-json' $pw @('answers.schema') -Text '{"Sku": "BasicV2", '
Add-Case 'names-differ-in-case' $pw @('answers.schema') -Text '{"Sku": "BasicV2", "sku": "BasicV2"}'
Add-Case 'not-an-object' $pw @('answers.schema') -Text '["Sku"]'

# PowerShell: the library the installer dot-sources.
$library = Join-Path $root 'scripts/ClaudeInstallerAnswers.ps1'
$psResults = @{}
$psError = ''
try {
    . $library
    foreach ($c in $cases) { $psResults[$c.Name] = @(Test-ClaudeInstallerAnswersFile -Path $c.File -Consumer $c.Consumer) }
}
catch { $psError = $_.Exception.Message }
Assert 'the PowerShell validator runs over the corpus' (-not $psError -and $psResults.Count -eq $cases.Count) $psError

# Bash: one process sources the library and checks every file.
$bash = $null
if ($IsWindows -or $env:OS -eq 'Windows_NT') { foreach ($b in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', (Join-Path "$env:LOCALAPPDATA" 'Programs\Git\bin\bash.exe'))) { if (Test-Path -LiteralPath $b) { $bash = $b; break } } }
else { $bash = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
function ConvertTo-BashPath([string]$Path) { if ($IsWindows -or $env:OS -eq 'Windows_NT') { '/' + ($Path.Replace('\', '/') -replace '^([A-Za-z]):', '$1') } else { $Path } }
$shResults = @{}
$shError = ''
if (-not $bash) { $shError = 'no Git Bash (Windows) or bash on this machine' }
else {
    $manifest = Join-Path $scratch 'manifest.tsv'
    Write-Lf $manifest ((@($cases | ForEach-Object { "$($_.Name)`t$($_.Consumer)`t$(ConvertTo-BashPath $_.File)" }) -join "`n") + "`n")
    $runner = Join-Path $scratch 'run.sh'
    Write-Lf $runner (@"
export HERE='$(ConvertTo-BashPath $root)'
. "`$HERE/scripts/install-answers.sh" || exit 90
while IFS="`$(printf '\t')" read -r name consumer file; do
  [ -n "`$name" ] || continue
  printf '%s\t%s\n' "`$name" "`$(answers_check_file_ "`$file" "`$consumer" 2>&1 | tr -d '\r\n')"
done < '$(ConvertTo-BashPath $manifest)'
"@)
    $out = @(& $bash (ConvertTo-BashPath $runner) 2>&1 | ForEach-Object { [string]$_ })
    foreach ($line in $out) {
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { continue }
        try { $shResults[$parts[0]] = @($parts[1] | ConvertFrom-Json -ErrorAction Stop) } catch { $shResults[$parts[0]] = @([pscustomobject]@{ checkId = 'unreadable'; path = ''; message = $parts[1]; remedy = '' }) }
    }
    if ($shResults.Count -ne $cases.Count) { $shError = "bash checked $($shResults.Count) of $($cases.Count) files: $((@($out) | Select-Object -Last 3) -join ' | ')" }
}
Assert 'the bash validator runs over the corpus' (-not $shError) $shError

function Format-Problems($List) {
    [string[]]$lines = @(@($List) | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.checkId)|$($_.path)|$($_.message)|$($_.remedy)" })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    return ($lines -join "`n")
}
foreach ($c in $cases) {
    $ps = @($psResults[$c.Name] | Where-Object { $null -ne $_ })
    $sh = @($shResults[$c.Name] | Where-Object { $null -ne $_ })
    $got = @($ps | ForEach-Object { [string]$_.checkId } | Sort-Object)
    $want = @($c.Expected | Sort-Object)
    $label = if ($want.Count) { "$($c.Name) fails under $($want -join ', ') only, with the same problems in both validators ($($c.Consumer))" } else { "$($c.Name) is valid in both validators ($($c.Consumer))" }
    $psText = Format-Problems $ps; $shText = Format-Problems $sh
    $detail = if (($got -join ',') -ne ($want -join ',')) { "PowerShell: $psText" } else { "PowerShell: $psText || bash: $shText" }
    Assert $label ((($got -join ',') -eq ($want -join ',')) -and $psText -eq $shText -and ($want.Count -eq 0 -or @($ps | Where-Object { $_.message -and $_.remedy }).Count -eq $ps.Count)) $detail
}
# Each malformed renewal input is refused by its own form, not as an answer the schema lacks.
$forms = [ordered]@{ 'projection-digest-malformed' = "ProjectionRenewalImageDigest 'sha256:ABC' is not a sha256 image digest"
    'projection-action-group-not-id' = "ProjectionRenewalActionGroupResourceId 'ag-projection-renewal' is not an action group resource ID"
    'projection-entry-point-empty' = 'ProjectionRenewalEntryPoint is empty' }
$formBad = @(foreach ($k in $forms.Keys) { $m = @($psResults[$k] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.message }) -join ' | '; if (-not $m.StartsWith($forms[$k])) { "${k}: $m" } })
Assert 'the three P86 renewal inputs are answers of Install-ClaudeGateway.ps1, each refused by its own form' (-not $formBad.Count) ($formBad -join '; ')
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
