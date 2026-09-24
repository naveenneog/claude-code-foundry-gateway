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
Write-Host 'Turnstile governance - authored in Turnstile' -ForegroundColor Cyan

. (Join-Path $root 'scripts/ClaudeTurnstileApply.ps1')
$applyLib = Get-Content (Join-Path $root 'scripts/ClaudeTurnstileApply.ps1') -Raw
$grantGraph = Get-Content (Join-Path $root 'scripts/Grant-ClaudeGovernanceGraphAccess.ps1') -Raw
$schedulePass = Get-Content (Join-Path $root 'scripts/Invoke-ClaudeTurnstileSchedule.ps1') -Raw
$jobTemplate = Get-Content (Join-Path $root 'infra/turnstile-schedule.bicep') -Raw

# What the gateway sends Turnstile comes back as the same registry.
$sent = ConvertTo-ClaudeTurnstileCatalog -Registry $registry -Parents $parents -IncludeUnassigned
$stored = [pscustomobject]@{
    source        = 'configured'
    organizations = @($sent.organizations | ForEach-Object { [pscustomobject]$_ })
    departments   = @($sent.departments | ForEach-Object { [pscustomobject]$_ })
}
# These functions return their array whole; assigning it first lets it be enumerated.
$sentPlan = Get-ClaudeTurnstileBudgetPlan -Registry $registry -Parents $parents
$budgetRows = @($sentPlan | ForEach-Object { [pscustomobject]@{ scope_type = $_.ScopeType; scope_id = $_.ScopeId; token_limit = $_.TokenLimit } })
$round = ConvertFrom-ClaudeTurnstileGovernance -Catalog $stored -BudgetItems $budgetRows
$shape = { param($r) (@($r | Sort-Object Id | ForEach-Object { "$($_.Id)=$($_.Group):$($_.TokensPerMonth)" }) -join ',') }
Assert 'the registry survives the round trip through Turnstile' ((& $shape $round.Registry) -eq (& $shape $registry)) (& $shape $round.Registry)
Assert 'and so do the teams'                                  ((ConvertTo-ClaudeBuParents $round.Parents) -eq (ConvertTo-ClaudeBuParents $parents))
Assert 'with nothing to report'                               (@($round.Problems).Count -eq 0) ($round.Problems -join '; ')

# What an administrator might save.
$edited = [pscustomobject]@{
    source        = 'configured'
    organizations = @(
        [pscustomobject]@{ id = 'platform'; external_ref = 'entra-group:Claude BU Platform' },
        [pscustomobject]@{ id = 'finance'; external_ref = 'entra-group:Claude BU Finance' },
        [pscustomobject]@{ id = 'unassigned'; external_ref = 'entra-group:Claude Everyone' },
        [pscustomobject]@{ id = 'nogroup'; external_ref = $null },
        [pscustomobject]@{ id = 'Bad_Id'; external_ref = 'entra-group:Claude Bad' })
    departments   = @(
        [pscustomobject]@{ id = 'platform'; parent_id = 'platform'; external_ref = 'entra-group:Claude BU Platform' },
        [pscustomobject]@{ id = 'platform-web'; parent_id = 'platform'; external_ref = 'entra-group:Claude Team Web' },
        [pscustomobject]@{ id = 'orphan'; parent_id = 'nogroup'; external_ref = 'entra-group:Claude Orphan' })
}
$edits = @(
    [pscustomobject]@{ scope_type = 'organization'; scope_id = 'platform'; token_limit = 25000000 },
    [pscustomobject]@{ scope_type = 'department'; scope_id = 'platform-web'; token_limit = 6000000 },
    [pscustomobject]@{ scope_type = 'organization'; scope_id = 'finance'; token_limit = $null },
    [pscustomobject]@{ scope_type = 'user'; scope_id = 'dev@contoso.com'; token_limit = 5 })
$tierEdits = @(
    [pscustomobject]@{ id = 'standard'; entra_group = 'claude-code-standard'; tokens_per_minute = 20000; tokens_per_day = 500000; models = @() },
    [pscustomobject]@{ id = 'premium'; entra_group = 'Claude Premium'; tokens_per_minute = 100000; tokens_per_day = 5000000; models = @('claude-opus-5', 'claude-sonnet-5') },
    [pscustomobject]@{ id = 'gold'; entra_group = 'Claude Gold'; tokens_per_minute = 1; tokens_per_day = 1; models = @() })
$d = ConvertFrom-ClaudeTurnstileGovernance -Catalog $edited -BudgetItems $edits -Tiers $tierEdits
$ids = @($d.Registry | ForEach-Object { $_.Id })
$unitOf = { param($id) @($d.Registry | Where-Object Id -eq $id)[0] }
Assert 'the unassigned organization is never a unit, even with a group' ($ids -notcontains 'unassigned')
Assert 'a unit''s direct-members department is not a team'   (@($ids | Where-Object { $_ -eq 'platform' }).Count -eq 1 -and -not $d.Parents.Contains('platform'))
Assert 'a department with its own group is a team'            ($d.Parents['platform-web'] -eq 'platform' -and (& $unitOf 'platform-web').Group -eq 'Claude Team Web')
Assert 'budgets become monthly tokens'                        ((& $unitOf 'platform').TokensPerMonth -eq 25000000 -and (& $unitOf 'platform-web').TokensPerMonth -eq 6000000)
Assert 'no budget is no business-unit budget, not an error'   ((& $unitOf 'finance').TokensPerMonth -eq 0)
Assert 'a unit without a group is reported, not applied'      ($ids -notcontains 'nogroup' -and @($d.Problems -match "business unit 'nogroup': names no Entra group").Count -eq 1)
Assert 'and so is a team under it'                            ($ids -notcontains 'orphan' -and @($d.Problems -match "team 'orphan'").Count -eq 1)
Assert 'an id the gateway cannot use is reported'             ($ids -notcontains 'Bad_Id' -and @($d.Problems -match "'Bad_Id'").Count -eq 1)
Assert 'a person''s budget never reaches the registry'        (@($d.Registry | Where-Object { $_.TokensPerMonth -eq 5 }).Count -eq 0)
Assert 'only the tiers the policy enforces are applied'       ((@($d.Tiers | ForEach-Object { $_.Id }) -join ',') -eq 'standard,premium' -and @($d.Problems -match "tier 'gold'").Count -eq 1)
Assert 'every model is the gateway''s ,, list'                ((@($d.Tiers | Where-Object Id -eq 'standard')[0].Models) -eq ',,')
Assert 'named models are comma-anchored'                      ((@($d.Tiers | Where-Object Id -eq 'premium')[0].Models) -eq ',claude-opus-5,claude-sonnet-5,')
Assert 'Turnstile''s demonstration catalog is never applied'  (Throws { ConvertFrom-ClaudeTurnstileGovernance -Catalog ([pscustomobject]@{ source = 'seeded'; organizations = @(); departments = @() }) })

$gatewayNow = [ordered]@{
    'bu-registry' = ConvertTo-ClaudeBuRegistry @($d.Registry); 'bu-parents' = ConvertTo-ClaudeBuParents $d.Parents
    'tpm-standard' = '20000'; 'quota-standard' = '500000'; 'models-standard' = ',,'
    'tpm-premium' = '100000'; 'quota-premium' = '5000000'; 'models-premium' = ',claude-opus-5,claude-sonnet-5,'
}
$none = Get-ClaudeGatewayGovernanceChanges -Desired $d -Current $gatewayNow
Assert 'a gateway that already matches gets no writes'        (@($none).Count -eq 0)
$gatewayNow['tpm-standard'] = '10000'
$one = Get-ClaudeGatewayGovernanceChanges -Desired $d -Current $gatewayNow
Assert 'one changed limit is one write, with what it was'     (@($one).Count -eq 1 -and $one[0].Id -eq 'tpm-standard' -and $one[0].Was -eq '10000' -and $one[0].Now -eq '20000')

$directory = @{ 'claude bu platform' = 'exists'; 'claude team web' = 'exists'; 'claude bu finance' = 'missing'; 'claude-code-standard' = 'exists'; 'claude premium' = 'exists' }
$lookup = { param($g) $directory[$g.ToLowerInvariant()] }
$sel = Select-ClaudeGovernanceWithGroups -Desired $d -GroupState $lookup
$kept = @($sel.Governance.Registry | ForEach-Object { $_.Id })
Assert 'a unit whose group does not exist is not applied'     ($kept -notcontains 'finance' -and @($sel.Problems -match "no Entra group 'Claude BU Finance'").Count -eq 1)
Assert 'units and teams whose groups exist are applied'       ($kept -contains 'platform' -and $sel.Governance.Parents['platform-web'] -eq 'platform')
Assert 'tiers whose groups exist can have members refreshed'  ($sel.TierGroups['standard'] -eq 'claude-code-standard' -and $sel.TierGroups['premium'] -eq 'Claude Premium')
$directory['claude bu platform'] = 'missing'
$sel = Select-ClaudeGovernanceWithGroups -Desired $d -GroupState $lookup
Assert 'a team whose unit is not applied is not applied'      (@($sel.Governance.Registry | ForEach-Object { $_.Id }) -notcontains 'platform-web' -and -not $sel.Governance.Parents.Contains('platform-web'))
$directory['claude bu platform'] = 'exists'; $directory['claude premium'] = 'missing'
$sel = Select-ClaudeGovernanceWithGroups -Desired $d -GroupState $lookup
Assert 'a tier whose group is missing keeps its limits'       (@($sel.Governance.Tiers).Count -eq 2 -and -not $sel.TierGroups.Contains('premium') -and @($sel.Problems -match "tier 'premium'").Count -eq 1)
$blind = Select-ClaudeGovernanceWithGroups -Desired $d -KnownGroups @('Claude BU Platform', 'Claude Team Web') -GroupState { param($g) 'unknown' }
$seen = @($blind.Governance.Registry | ForEach-Object { $_.Id })
Assert 'unreadable directory: groups in use are trusted'      ($seen -contains 'platform' -and $seen -contains 'platform-web')
Assert 'unreadable directory: a new group is not applied'     ($seen -notcontains 'finance' -and @($blind.Problems -match 'could not be checked').Count -ge 1)
Assert 'unreadable directory: tier limits still apply'        (@($blind.Governance.Tiers).Count -eq 2 -and $blind.TierGroups.Count -eq 0)

Assert 'a push cannot overwrite what Turnstile authored'      ($sync -match "if \(\`$Direction -eq 'ToTurnstile' -and \`$governanceAuthority -eq 'Turnstile' -and -not \`$Seed\) \{")
Assert 'the month is prepared before budgets are read'        ($sync -match "(?s)/api/v1/gateway-governance/prepare.*\`$Period = \[string\]\`$prepared\.period.*\`$budgetDoc = Invoke-Turnstile GET")
Assert 'what governance needs is checked before it is set'    ($connect -match "(?s)No apply job in .{0,400}has no managed identity.{0,300}Set-ApimNamedValue -ResourceGroup \`$ResourceGroup -ApimName \`$ApimName -Id \`$script:TurnstileIntegrationNamedValue -Value \`$value")
Assert 'Turnstile is seeded only when governance moves'       ($connect -match "(?s)if \(-not \`$wasTurnstile\) \{.{0,400}-Direction ToTurnstile -Seed")
Assert 'a failed seed leaves governance with the gateway'     ($connect -match "(?s)catch \{\s+\`$settings\.governanceAuthority = 'Gateway'\s+Set-ApimNamedValue")
Assert 'Turnstile may start the apply job, and only it'       ($connect -match "Role = 'Container Apps Jobs Operator'; Scope = \`$applyJobId \}")
Assert 'the job may write named values, and nothing else'     ($applyLib -match "'Microsoft\.ApiManagement/service/namedValues/write'" -and -not ($applyLib -match 'Microsoft\.ApiManagement/service/(\*|policies|apis|products|certificates|backends)'))
Assert 'going back to the gateway removes both'               ($connect -match "GATEWAY_APPLY_JOB_ID=' -o none" -and $connect -match 'az role assignment delete --ids \$id')
Assert 'a save starts a job that only applies'                ($jobTemplate -match "trigger: 'Manual', skipExport: true" -and $jobTemplate -match 'extra="\$\{extra\} -SkipExport"')
Assert 'a pass applies Turnstile when it authors governance'  ($schedulePass -match "\`$integration\['governanceAuthority'\] -eq 'Turnstile' -or")
Assert 'the Graph grant is one read-only permission'          ($grantGraph -match "\`$permission = 'GroupMember\.Read\.All'" -and -not ($grantGraph -match 'ReadWrite'))
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
Assert 'the start script survives a Windows checkout'        ($job -match "replace\(bootstrap, '\\r', ''\)")
Assert 'a pass reports budgets refused, not just counted'    ($pass -match "like 'refused \*'" -and $pass -match 'refused \$\(\$refused\.Count\)')
if (Get-Command az -ErrorAction SilentlyContinue) {
    az bicep build --file $scheduleTemplate --stdout *> $null
    Assert 'the schedule template compiles'                  ($LASTEXITCODE -eq 0)
}

Write-Host ''
Write-Host 'Turnstile governance - applying to a gateway held in memory' -ForegroundColor Cyan

# The apply reaches Azure through these four functions; they are replaced here, after every
# check above has used the real ones.
function Get-ApimNamedValue { param($ResourceGroup, $ApimName, $Id) $script:gw[$Id] }
function Set-ApimNamedValue { param($ResourceGroup, $ApimName, $Id, $Value) $script:writes++; if (-not $script:dropWrites) { $script:gw[$Id] = $Value } }
function Test-ClaudeGraphGroupAccess { $script:graphState }
function Test-ClaudeEntraGroup { param($Group) $directory[$Group.ToLowerInvariant()] }
$stub = Join-Path ([IO.Path]::GetTempPath()) "turnstile-apply-$PID-$(Get-Random)"
New-Item -ItemType Directory -Path $stub -Force | Out-Null
Set-Content -Path (Join-Path $stub 'Sync-ClaudeAccess.ps1') -Value 'param($ApimName, $ResourceGroup, $StandardGroup, $PremiumGroup) Set-Content -Path (Join-Path $PSScriptRoot "refreshed.txt") -Value "$StandardGroup|$PremiumGroup"'
$refreshed = Join-Path $stub 'refreshed.txt'
$reset = {
    $script:gw = @{
        'bu-registry' = ConvertTo-ClaudeBuRegistry @([pscustomobject]@{ Id = 'platform'; Group = 'Claude BU Platform'; TokensPerMonth = 20000000 })
        'bu-parents' = ',,'; 'tpm-standard' = '10000'; 'quota-standard' = '500000'; 'models-standard' = ',,'
        'tpm-premium' = '100000'; 'quota-premium' = '5000000'; 'models-premium' = ',claude-opus-5,claude-sonnet-5,'
    }
    $script:writes = 0; $script:dropWrites = $false; $script:graphState = 'denied'
    Remove-Item $refreshed -ErrorAction SilentlyContinue
}
$unitsNow = { @(ConvertFrom-ClaudeBuRegistry $script:gw['bu-registry']) }
$directory = @{ 'claude bu platform' = 'exists'; 'claude team web' = 'exists'; 'claude bu finance' = 'exists'; 'claude-code-standard' = 'exists'; 'claude premium' = 'exists' }
$applyArgs = @{ Catalog = $edited; BudgetItems = $edits; Tiers = $tierEdits; ResourceGroup = 'rg'; ApimName = 'apim'; ScriptRoot = $stub }
try {
    & $reset
    $r = Invoke-ClaudeGatewayGovernanceApply @applyArgs
    Assert 'without -Apply nothing is written'                ($script:writes -eq 0 -and @($r.Changes).Count -gt 0 -and $r.Applied -eq 0)

    & $reset
    $r = Invoke-ClaudeGatewayGovernanceApply @applyArgs -Apply
    Assert 'a limit saved in Turnstile reaches the gateway'   ($script:gw['tpm-standard'] -eq '20000' -and $r.Applied -eq @($r.Changes).Count)
    Assert 'a budget saved in Turnstile reaches the gateway'  (@(& $unitsNow | Where-Object Id -eq 'platform')[0].TokensPerMonth -eq 25000000)
    Assert 'without Graph access, membership is left alone'   (-not (Test-Path $refreshed) -and $r.Membership -match 'cannot read Entra groups')
    Assert 'and a group not yet in use is not applied'        (@(& $unitsNow | ForEach-Object { $_.Id }) -notcontains 'finance')

    & $reset; $script:graphState = 'ok'
    $r = Invoke-ClaudeGatewayGovernanceApply @applyArgs -Apply
    Assert 'with Graph access, groups that exist are applied' (@(& $unitsNow | ForEach-Object { $_.Id }) -contains 'finance')
    Assert 'and membership is refreshed from the tier groups' ((Test-Path $refreshed) -and (Get-Content $refreshed -Raw).Trim() -eq 'claude-code-standard|Claude Premium' -and $r.Membership -eq 'refreshed from the Entra groups')

    & $reset; $script:graphState = 'ok'; $directory['claude premium'] = 'missing'
    $r = Invoke-ClaudeGatewayGovernanceApply @applyArgs -Apply
    Assert 'a tier with no group: limits applied, members not' ($script:gw['tpm-standard'] -eq '20000' -and -not (Test-Path $refreshed) -and $r.Membership -match 'every tier needs')
    $directory['claude premium'] = 'exists'

    & $reset
    $empty = [pscustomobject]@{ source = 'configured'; organizations = @(); departments = @() }
    $r = Invoke-ClaudeGatewayGovernanceApply @applyArgs -Catalog $empty -Apply
    Assert 'every unit gone at once is not applied'           (@(& $unitsNow).Count -eq 1 -and @($r.Problems -match 'left as they are').Count -eq 1)
    Assert 'while the tier limits still are'                  ($script:gw['tpm-standard'] -eq '20000')

    & $reset; $script:dropWrites = $true
    Assert 'a write that does not read back is an error'      (Throws { Invoke-ClaudeGatewayGovernanceApply @applyArgs -Apply })
}
finally { Remove-Item $stub -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Every Turnstile governance check passed.' -ForegroundColor Green
exit 0
