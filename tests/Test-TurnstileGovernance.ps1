# The gateway's business units, teams, groups, tiers and budgets in Turnstile, and the
# connection settings every Turnstile script reads instead of assuming anything.
#
# Offline. The live run against the deployed Turnstile is in docs/TURNSTILE.md.

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}
function Throws([scriptblock]$Block) { try { & $Block | Out-Null; return $false } catch { return $true } }

. (Join-Path $root 'scripts/ClaudeBusinessUnit.ps1')
. (Join-Path $root 'scripts/ClaudeTurnstile.ps1')
. (Join-Path $root 'scripts/ClaudeTurnstileGovernance.ps1')
$connect = Get-Content (Join-Path $root 'scripts/Connect-ClaudeTurnstile.ps1') -Raw
$sync = Get-Content (Join-Path $root 'scripts/Sync-ClaudeTurnstileGovernance.ps1') -Raw -ErrorAction SilentlyContinue

$registry = @(
    [pscustomobject]@{ Id = 'platform'; Group = 'Claude BU Platform'; TokensPerMonth = 20000000 },
    [pscustomobject]@{ Id = 'platform-web'; Group = 'Claude Team Web'; TokensPerMonth = 5000000 },
    [pscustomobject]@{ Id = 'finance'; Group = 'Claude BU Finance'; TokensPerMonth = 8000000 },
    [pscustomobject]@{ Id = 'sandbox'; Group = 'Claude BU Sandbox'; TokensPerMonth = 0 }
)
$parents = [ordered]@{ 'platform-web' = 'platform' }

Write-Host ''
Write-Host 'Turnstile governance - the catalog' -ForegroundColor Cyan

$c = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents -IncludeUnassigned
$orgIds = @($c.organizations | ForEach-Object { $_.id })
$depIds = @($c.departments | ForEach-Object { $_.id })
Assert 'a business unit is an organization'                  ($orgIds -contains 'platform' -and $orgIds -contains 'finance')
Assert 'a team is not an organization'                       ($orgIds -notcontains 'platform-web')
Assert 'a team is a department under its unit'               (@($c.departments | Where-Object { $_.id -eq 'platform-web' -and $_.parent_id -eq 'platform' }).Count -eq 1)
# Usage rows carry the unit as their department for people mapped to it directly.
Assert 'every unit has a department for direct members'      (@($c.departments | Where-Object { $_.id -eq 'finance' -and $_.parent_id -eq 'finance' }).Count -eq 1)
Assert 'the Entra group is carried as the external reference' ((@($c.organizations | Where-Object id -eq 'platform')[0].external_ref) -eq 'entra-group:Claude BU Platform')
Assert 'the name is the group''s display name'               ((@($c.organizations | Where-Object id -eq 'finance')[0].name) -eq 'Claude BU Finance')
Assert 'the monthly budget travels as an attribute'          ((@($c.organizations | Where-Object id -eq 'platform')[0].attributes.tokens_per_month) -eq 20000000)
Assert 'unassigned developers have somewhere to be listed'   ($orgIds -contains 'unassigned' -and $depIds -contains 'unassigned' -and $c.default_department_id -eq 'unassigned')
$plain = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents
Assert 'without unassigned, the first department is default' ($orgIds.Count -eq 4 -and $plain.default_department_id -eq 'platform' -and @($plain.organizations).Count -eq 3)
Assert 'an empty registry is refused'                        (Throws { ConvertTo-ClaudeTurnstileCatalog -Registry @() })
Assert 'every id fits Turnstile''s id rule'                  (@(@($c.organizations) + @($c.departments) | Where-Object { $_.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._:@-]{0,199}$' }).Count -eq 0)

Write-Host ''
Write-Host 'Turnstile governance - budgets' -ForegroundColor Cyan

$plan = Get-ClaudeTurnstileBudgetPlan -Registry $registry -Parents $parents
Assert 'organizations are budgeted before departments'       ($plan[0].ScopeType -eq 'organization' -and $plan[-1].ScopeType -eq 'department')
Assert 'a unit''s budget is its organization''s'             (@($plan | Where-Object { $_.ScopeType -eq 'organization' -and $_.ScopeId -eq 'platform' -and $_.TokenLimit -eq 20000000 }).Count -eq 1)
Assert 'a team''s budget is its department''s'               (@($plan | Where-Object { $_.ScopeType -eq 'department' -and $_.ScopeId -eq 'platform-web' -and $_.TokenLimit -eq 5000000 }).Count -eq 1)
Assert 'a unit with no budget is left unallocated'           (@($plan | Where-Object ScopeId -eq 'sandbox').Count -eq 0)
Assert 'direct-members departments carry no budget'          (@($plan | Where-Object { $_.ScopeType -eq 'department' -and $_.ScopeId -eq 'platform' }).Count -eq 0)

$items = @(
    [pscustomobject]@{ scope_type = 'organization'; scope_id = 'platform'; token_limit = 25000000; updated_by = 'admin@contoso.com' },
    [pscustomobject]@{ scope_type = 'department'; scope_id = 'platform-web'; token_limit = 5000000; updated_by = 'admin@contoso.com' },
    [pscustomobject]@{ scope_type = 'organization'; scope_id = 'finance'; token_limit = $null; updated_by = 'admin@contoso.com' },
    [pscustomobject]@{ scope_type = 'department'; scope_id = 'platform'; token_limit = 999; updated_by = 'admin@contoso.com' },
    [pscustomobject]@{ scope_type = 'organization'; scope_id = 'not-a-unit'; token_limit = 1; updated_by = 'admin@contoso.com' },
    [pscustomobject]@{ scope_type = 'user'; scope_id = 'dev@contoso.com'; token_limit = 1; updated_by = 'admin@contoso.com' }
)
$changes = Compare-ClaudeTurnstileBudgets -Registry $registry -Parents $parents -TurnstileItems $items
Assert 'a budget raised in Turnstile is a change to apply'   (@($changes | Where-Object { $_.Id -eq 'platform' -and $_.Apply -and $_.Was -eq 20000000 -and $_.Now -eq 25000000 }).Count -eq 1)
Assert 'an unchanged budget is not a change'                 (@($changes | Where-Object Id -eq 'platform-web').Count -eq 0)
# Removing a budget in the gateway is a decision, not a side effect of a sync.
Assert 'a budget removed in Turnstile is reported, not applied' (@($changes | Where-Object { $_.Id -eq 'finance' -and -not $_.Apply }).Count -eq 1)
Assert 'a direct-members department cannot set a unit budget' (@($changes | Where-Object { $_.Id -eq 'platform' -and $_.ScopeType -eq 'department' }).Count -eq 0)
Assert 'unknown scopes and people are ignored'               (@($changes | Where-Object { $_.Id -in 'not-a-unit', 'dev@contoso.com' }).Count -eq 0)
Assert 'the change says who made it'                         ((@($changes | Where-Object Id -eq 'platform')[0].Reason) -match 'admin@contoso.com')

Write-Host ''
Write-Host 'Turnstile governance - tiers' -ForegroundColor Cyan

Assert 'a tier''s daily quota is shown as a month''s worth'  ((Get-ClaudeTierMonthlyTokens -DailyQuota 1000000 -Period '2026-09') -eq 30000000 -and (Get-ClaudeTierMonthlyTokens -DailyQuota 1000000 -Period '2026-02') -eq 28000000)
Assert 'a leap February has 29 days'                         ((Get-ClaudeTierMonthlyTokens -DailyQuota 10 -Period '2028-02') -eq 290)
Assert 'a zero quota is refused'                             (Throws { Get-ClaudeTierMonthlyTokens -DailyQuota 0 -Period '2026-09' })
Assert 'a malformed period is refused'                       (Throws { Get-ClaudeTierMonthlyTokens -DailyQuota 5 -Period '2026-13' })
$row = [pscustomobject]@{ timestamp = '2026-09-23T10:00:00Z'; actor = 'dev@contoso.com'; user_id = 'x'; tier = 'Premium'; business_unit = 'platform'; client_surface = 'cli'; model = 'claude-sonnet-5'; prompt_tokens = 1.0; completion_tokens = 1.0; request_id = 'r1'; result_code = '200'; duration_ms = 1 }
$e = ConvertTo-ClaudeTurnstileEvent -Row $row
Assert 'usage carries the tier as its project'               ($e['project_id'] -eq 'tier-premium' -and $e['project'] -eq 'Premium tier')
$none = ConvertTo-ClaudeTurnstileEvent -Row ([pscustomobject]@{ timestamp = '2026-09-23T10:00:00Z'; request_id = 'r2'; prompt_tokens = 1.0; completion_tokens = 1.0 })
Assert 'no tier means an unattributed project'               ($none['project_id'] -eq 'unattributed')

Write-Host ''
Write-Host 'Turnstile governance - the connection settings' -ForegroundColor Cyan

$good = [ordered]@{
    version = 1; url = 'https://api-ts.azurewebsites.net'; clientId = '11111111-2222-3333-4444-555555555555'; tenantId = '00000000-0000-0000-0000-000000000001'
    scope = 'api://11111111-2222-3333-4444-555555555555/Turnstile.Manage'; eventHubNamespace = 'eh-turnstile-abc'; eventHubName = 'token-usage'
    resourceGroup = 'rg-ts'; priceSource = 'Gateway'; budgetAuthority = 'Gateway'; personBudgets = $true; connectedAt = '2026-09-23T00:00:00Z'; connectedBy = 'admin@contoso.com'
}
$json = ConvertTo-ClaudeTurnstileIntegrationValue -Settings $good
$back = ConvertFrom-ClaudeTurnstileIntegrationValue $json
Assert 'settings survive the named value round trip'         ($back['url'] -eq $good.url -and $back['eventHubName'] -eq 'token-usage' -and $back['personBudgets'] -eq $true)
Assert 'they fit in a named value'                           ($json.Length -le 4096)
# On Windows az runs through cmd.exe, which strips double quotes from arguments;
# measured, a JSON value came back as {version:1,url:https://...}.
Assert 'the stored value has no double quote in it'          (-not $json.Contains('"'))
$semi = [ordered]@{}; foreach ($k in $good.Keys) { $semi[$k] = $good[$k] }; $semi['connectedBy'] = 'a;b'
Assert 'a value that would break the format is refused'      (Throws { ConvertTo-ClaudeTurnstileIntegrationValue -Settings $semi })
foreach ($bad in @(@{ url = 'http://plain.example.com' }, @{ clientId = 'not-a-guid' }, @{ scope = 'Turnstile.Manage' }, @{ priceSource = 'Cheapest' }, @{ budgetAuthority = 'Both' }, @{ extra = 'x' })) {
    $s = [ordered]@{}; foreach ($k in $good.Keys) { $s[$k] = $good[$k] }; foreach ($k in $bad.Keys) { $s[$k] = $bad[$k] }
    Assert "an invalid $(@($bad.Keys)[0]) is refused"            (Throws { ConvertTo-ClaudeTurnstileIntegrationValue -Settings $s })
}
Assert 'no stored value means not connected'                 ($null -eq (ConvertFrom-ClaudeTurnstileIntegrationValue ' '))
Assert 'a parameter wins over the stored setting'            ((Resolve-ClaudeTurnstileSetting 'given' $back 'url' 'Url') -eq 'given')
Assert 'the stored setting is used when none is given'       ((Resolve-ClaudeTurnstileSetting $null $back 'eventHubName' 'EventHubName') -eq 'token-usage')
Assert 'a default applies only when nothing is stored'       ((Resolve-ClaudeTurnstileSetting $null $null 'priceSource' 'PriceSource' 'Gateway') -eq 'Gateway')
Assert 'missing everything names the fix'                    ($(try { Resolve-ClaudeTurnstileSetting $null $null 'url' 'Url'; '' } catch { $_.Exception.Message }) -match 'Connect-ClaudeTurnstile')

Write-Host ''
Write-Host 'Turnstile governance - connecting' -ForegroundColor Cyan

Assert 'the web app is found by its Entra settings'          ($connect -match "starts_with\(name, 'ENTRA_'\)" -and $connect -match "ENTRA_CLIENT_ID")
Assert 'the hub is the one Turnstile''s telemetry reads'     ($connect -match "EVENT_HUB_NAME" -and $connect -match 'EVENT_HUB_CONNECTION__fullyQualifiedNamespace')
Assert 'a deployment that is not admin-only is refused'      ($connect -match 'is not admin-only' -and $connect -match "ENTRA_ADMIN_ROLE'\] -or -not \`$tenants\.Count")
Assert 'a workload identity gets only what it needs'         ($connect -match "'Azure Event Hubs Data Sender'" -and $connect -match "'Log Analytics Reader'" -and $connect -match "'API Management Service Reader Role'")
Assert 'and the admin app role, assigned directly'           ($connect -match 'appRoleAssignedTo' -and $connect -match "appRoles\[\?value==")
Assert 'the connection is proven with an admin token'        ($connect -match 'get-access-token --scope \$settings\.scope' -and $connect -match '/api/v1/enterprise-catalog')
Assert 'settings are written to one named value'             ($connect -match 'Set-ApimNamedValue .*-Id \$script:TurnstileIntegrationNamedValue')
Assert 'disconnect leaves the value empty, not missing'      ($connect -match "-Value ' '")

Write-Host ''
Write-Host 'Turnstile governance - the sync script' -ForegroundColor Cyan

Assert 'the sync script exists'                              ([bool]$sync)
Assert 'it authenticates with an Entra token only'           ($sync -match 'get-access-token --scope' -and -not ($sync -match '(?i)password|x-api-key'))
Assert 'it reads the connection, not constants'              ($sync -match 'Resolve-ClaudeTurnstileSetting' -and $sync -match '\$script:TurnstileIntegrationNamedValue')
Assert 'pulling budgets writes nothing without -Apply'       ($sync -match "(?s)FromTurnstile.*if \(-not \`$Apply\)")
Assert 'it writes the registry through the shared renderer'  ($sync -match 'ConvertTo-ClaudeBuRegistry' -and $sync -match "Set-ApimNamedValue .*'bu-registry'")
Assert 'budget authority is honoured'                        ($sync -match "budgetAuthority")

Write-Host ''
Write-Host 'Turnstile - the Entra application, the bill and the pictures' -ForegroundColor Cyan

$entraApp = Get-Content (Join-Path $root 'scripts/New-ClaudeTurnstileEntraApp.ps1') -Raw
$bom = Get-Content (Join-Path $root 'scripts/Get-ClaudeTurnstileBom.ps1') -Raw
$pictures = @('guide/capture-turnstile.mjs', 'guide/capture-turnstile-entra.mjs', 'guide/render-turnstile.mjs') |
    ForEach-Object { Get-Content (Join-Path $root $_) -Raw }
$portal = Get-Content (Join-Path $root 'guide/capture-turnstile-entra.mjs') -Raw

Assert 'a multi-tenant application is refused'               ($entraApp -match "signInAudience -ne 'AzureADMyOrg'\) \{ throw")
Assert 'assignment is required, so Entra refuses the rest'   ($entraApp -match 'appRoleAssignmentRequired = \$true')
Assert 'the role can be held by a workload identity'         ($entraApp -match "allowedMemberTypes = @\('User', 'Application'\)")
Assert 'the Azure CLI is pre-authorized by its published id' ($entraApp -match "04b07795-8ddb-461a-bbee-02f9e1bf7b46")
Assert 'Graph bodies go through a file, not cmd.exe'         ($entraApp -match '''--body'', "@\$file"')
Assert 'an unknown price is not known, never zero'           ($bom -match 'MonthlyUsd = \$\(if \(\$null -eq \$Monthly\) \{ \$null \}' -and $bom -notmatch 'MonthlyUsd = 0')
Assert 'the bill reads the deployment from the connection'   ($bom -match "\`$integration\['resourceGroup'\]")
Assert 'private endpoints are priced where they are published' ($bom -match "Find-Meter 'Virtual Network' 'Global'")
# The picture scripts must carry patterns, never real values. Checked by shape, so this file
# does not have to name what it keeps out: a literal address outside the example domains, or
# an identifier that is neither a placeholder nor the Azure CLI's published id, is a leak.
$literalAddress = '(?<![\\\w.%+-])[A-Za-z0-9._%+-]+@(?!(?:contoso\.com|contoso\.onmicrosoft\.com|example\.(?:com|net|org))\b)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+'
$realGuid = '\b(?!00000000-0000-0000-0000-|04b07795-8ddb-461a-bbee-02f9e1bf7b46)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
Assert 'no real address or identifier is in the picture scripts' (-not (@($pictures | Where-Object { $_ -match $literalAddress -or $_ -match $realGuid }).Count))
Assert 'a portal picture with a real value left is not saved' ($portal -match "(?s)if \(left\.length\).{0,160}continue; \}\s*await page\.screenshot")
Assert 'a multifactor prompt stops the portal capture'       ($portal -match "return 'mfa'" -and $portal -match "state === 'mfa'.{0,200}break")

Write-Host ''
Write-Host 'Turnstile - the schedule' -ForegroundColor Cyan

$scheduleTemplate = Join-Path $root 'infra/turnstile-schedule.bicep'
$job = Get-Content $scheduleTemplate -Raw
$register = Get-Content (Join-Path $root 'scripts/Register-ClaudeTurnstileSchedule.ps1') -Raw
$pass = Get-Content (Join-Path $root 'scripts/Invoke-ClaudeTurnstileSchedule.ps1') -Raw

Assert 'the job holds no secret'                             (-not ($job -match '(?i)secrets:|password|listKeys|sharedKey|clientSecret'))
Assert 'it signs in as its own managed identity'             ($job -match "type: 'UserAssigned'" -and $job -match 'az login --identity --client-id "\$\{AZURE_CLIENT_ID\}"')
Assert 'it grants nothing itself; Connect does, in one place' (-not ($job -match 'roleAssignments') -and $register -match 'Connect-ClaudeTurnstile\.ps1''\) .*-ExporterPrincipalId \$principalId')
Assert 'a failed run is not retried; the next one overlaps'  ($job -match 'replicaRetryLimit: 0')
Assert 'its logs need no workspace key'                      ($job -match "destination: 'azure-monitor'")
Assert 'what it runs is a commit id, not a branch'           ($register -match "RepositoryRef -notmatch '\^\[0-9a-f\]\{40\}\$'\) \{ throw" -and $job -match 'git fetch -q --depth 1 "\$\{REPO_URL\}" "\$\{REPO_REF\}"')
Assert 'it refuses a commit that was never pushed'           ($register -match 'branch -r --contains' -and $register -match 'if \(-not \$onRemote\.Count\) \{ throw')
Assert 'deployment parameters go through a file'            ($register -match '--parameters "@\$file"')
Assert 'the sync uses an application token, not a scope'     ($pass -match 'get-access-token --resource \$resource' -and $pass -match '-AccessToken \$token\.Trim\(\)')
Assert 'the identity reads the Application Insights resource' ($connect -match "if \(\`$component\.id\) \{ Add-Role 'Reader' \`$component\.id \}")
if (Get-Command az -ErrorAction SilentlyContinue) {
    az bicep build --file $scheduleTemplate --stdout *> $null
    Assert 'the schedule template compiles'                  ($LASTEXITCODE -eq 0)
}

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Every Turnstile governance check passed.' -ForegroundColor Green
exit 0
