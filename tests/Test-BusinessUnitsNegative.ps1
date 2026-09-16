# Negative test for the business unit checks.
#
# A check that passes is worth nothing until it has been seen to fail. This
# breaks each thing Test-BusinessUnits.ps1 claims to guard, one at a time,
# confirms the suite goes red, and moves on.
#
# It works on a throwaway copy of the repository, never the repository itself.
# The first version edited the real files and restored them afterwards, which
# has two failure modes that matter: two suites running at once see each
# other's mutations, and an interrupted run leaves a corrupted policy.xml
# behind. Both were observed - a concurrent -IncludeAzure run turned the gate
# red while every mutation here reported caught.

$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "bu-negative-$PID-$(Get-Random)"

$mutations = @(
    @{ Name  = 'membership lookup removed from the policy'
       File  = 'infra/policy.xml'
       From  = 'bu-members'
       To    = 'bu-members-DISABLED' }

    @{ Name  = 'comma anchoring dropped from the lookup'
       File  = 'infra/policy.xml'
       From  = 'var marker = "," + oid + "=";'
       To    = 'var marker = oid + "=";' }

    @{ Name  = 'the per-unit quota stops being monthly'
       File  = 'infra/policy.xml'
       From  = 'token-quota-period="Monthly"'
       To    = 'token-quota-period="Yearly"' }

    @{ Name  = 'the refusal stops naming the unit'
       File  = 'infra/policy.xml'
       From  = '(string)(context.Variables.GetValueOrDefault("budgetUnit", "unknown"))'
       To    = '"your unit"' }

    @{ Name  = 'the registry parser splits on the first colon'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'LastIndexOf('
       To    = 'IndexOf(' }

    @{ Name  = 'an identifier with a comma is accepted'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = "^[a-z0-9][a-z0-9-]*$"
       To    = '.' }

    @{ Name  = 'the report stops saying the figure is list price'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = "'  Figures are at list price"
       To    = "'  Figures are at the price" }

    @{ Name  = 'the cache caveat retreats into a comment'
       File  = 'scripts/Get-ClaudeBusinessUnit.ps1'
       From  = 'and exclude cached tokens'
       To    = 'and are approximate' }

    @{ Name  = 'the guide understates the measured cache gap'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = '38.7'
       To    = '3.7' }

    @{ Name  = 'the guide loses its screenshots'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = '!['
       To    = 'see [' }

    @{ Name  = 'the guide stops explaining unassigned'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'unassigned'
       To    = 'unallocated' }

    # --- teams and the cascade (ADR-0008), checked by Test-Teams.ps1 ---

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'membership stops filtering to users'
       File  = 'scripts/Sync-ClaudeAccess.ps1'
       From  = 'transitiveMembers/microsoft.graph.user'
       To    = 'transitiveMembers' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the parent is no longer resolved'
       File  = 'infra/policy.xml'
       From  = '{{bu-parents}}'
       To    = '' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the parent counter disappears'
       File  = 'infra/policy.xml'
       From  = 'counter-key="@("bu-" + (string)context.Variables["parentUnit"])"'
       To    = 'counter-key="@("static")"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the parent quota stops being monthly'
       File  = 'infra/policy.xml'
       From  = 'remaining-quota-tokens-header-name="x-bu-parent-quota-remaining"'
       To    = 'remaining-quota-tokens-header-name="x-bu-other"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'an unpriced parent walls off its teams'
       From  = 'parentQuota"] != "0"'
       File  = 'infra/policy.xml'
       To    = 'parentQuota"] != "x"' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the depth cap is removed from the writer'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'Test-ClaudeBuDepth'
       To    = 'Out-Null #' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'teams stop being resolved before their parents'
       File  = 'scripts/ClaudeBusinessUnit.ps1'
       From  = 'Descending = $true'
       To    = 'Descending = $false' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the sync stops ordering by depth'
       File  = 'scripts/Sync-ClaudeAccess.ps1'
       From  = 'Sort-ClaudeBuByDepth $registry -Parents $parents'
       To    = '$registry' }

    # --- P26, the installer discovers or deploys a model ---

    @{ Name  = 'a redeploy stops preserving the registry'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'buRegistryExisting=$buReg'
       To    = 'tagsIgnored=$buReg' }

    @{ Name  = 'a redeploy stops preserving the parent map'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '--named-value-id bu-parents'
       To    = '--named-value-id bu-nothing' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the Claude filter stops filtering'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = "`$script:ClaudeModelPattern = 'claude'"
       To    = "`$script:ClaudeModelPattern = ''" }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the deployment summary loses its capacity'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = '[{3}, capacity {4}]'
       To    = '[{3}]' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'quota stops being named as a distinct failure'
       File  = 'scripts/ClaudeModelDeployment.ps1'
       From  = "if (`$AzureOutput -match '(?i)quota|InsufficientQuota|exceeded') {"
       To    = 'if ($false) {' }

    @{ Suite = 'Test-ModelDeployment.ps1'
       Name  = 'the tier lists stop coming from what is deployed'
       File  = 'Install-ClaudeGateway.ps1'
       From  = '$deployed = @(Get-ClaudeDeployment'
       To    = '$deployed = @(' }

    # --- screenshot safety: raw captures must not be committable ---

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the capture writes straight into docs'
       File  = 'guide/capture-entra.mjs'
       From  = "const OUT = path.resolve('.shots-entra');"
       To    = "const OUT = path.resolve('docs/guide');" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the raw captures stop being git-ignored'
       File  = '.gitignore'
       From  = '.shots-entra/'
       To    = '.shots-entra-disabled/' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the redaction stops masking identities'
       File  = 'guide/redact-entra.mjs'
       From  = "\u2022"
       To    = "x" }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'a display name is left whole'
       File  = 'guide/redact-entra.mjs'
       From  = 'Go\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022na'
       To    = 'Gopalakrishna' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'an unredacted capture stops failing the run'
       File  = 'guide/redact-entra.mjs'
       From  = 'if (unhandled.length) {'
       To    = 'if (false) {' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the guide stops showing the portal captures'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'entra-2-bu-all-members.png'
       To    = 'nothing.png' }

    @{ Suite = 'Test-Teams.ps1'
       Name  = 'the guide drops the two-axis capture'
       File  = 'docs/BUSINESS-UNITS.md'
       From  = 'entra-3-team-memberships.png'
       To    = 'nothing.png' }

    # --- P24/P27, the Observe half ---

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the client is no longer captured'
       File  = 'infra/policy.xml'
       From  = '<metadata name="Client"'
       To    = '<metadata name="ClientDisabled"' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the agent string stops being bounded'
       File  = 'infra/policy.xml'
       From  = 'ua.Length > 120 ? ua.Substring(0, 120) : ua'
       To    = 'ua' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the surface goes back to a hard-coded list'
       File  = 'analytics/chargeback-ledger.kql'
       From  = 'coalesce(extract(@"\(external,\s*([^)]+)\)", 1, client_raw), "claude-cli")'
       To    = '"cli"' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the publisher stops refusing a missing window line'
       File  = 'scripts/Publish-ClaudeQueries.ps1'
       From  = 'cannot become a parameter'
       To    = 'is fine actually' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook stops checking its functions exist'
       File  = 'scripts/Publish-ClaudeWorkbook.ps1'
       From  = 'does not have'
       To    = 'is missing maybe' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook drops the cache caveat'
       File  = 'infra/workbook.json'
       From  = '38.7'
       To    = '0.0' }

    @{ Suite = 'Test-Observability.ps1'
       Name  = 'the workbook stops splitting by client'
       File  = 'infra/workbook.json'
       From  = 'client_surface'
       To    = 'model' }

    # --- P29, backup and restore ---

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the backup starts reading secret values'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = '$apim/namedValues?api-version=2024-05-01'
       To    = '$apim/namedValues/x/listValue?api-version=2024-05-01' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the backup stops fetching workbook content'
       File  = 'scripts/Backup-ClaudeGateway.ps1'
       From  = 'canFetchContent=true'
       To    = 'canFetchContent=false' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the restore stops being a dry run'
       File  = 'scripts/Restore-ClaudeGateway.ps1'
       From  = 'if (-not $Apply) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the history restore stops being a dry run'
       File  = 'scripts/Restore-ClaudeCode.ps1'
       From  = 'if (-not $Apply) {'
       To    = 'if ($false) {' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the restore stops refusing another gateway'
       File  = 'scripts/Restore-ClaudeGateway.ps1'
       From  = 'Add -Force if you mean it'
       To    = 'carrying on' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the history backup stops excluding the credential file'
       File  = 'scripts/Backup-ClaudeCode.ps1'
       From  = 'oauth, key and token'
       To    = 'nothing much' }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'config credentials stop blocking the backup'
       File  = 'scripts/Backup-ClaudeCode.ps1'
       From  = "Scan = 'block'"
       To    = "Scan = 'report'" }

    @{ Suite = 'Test-Backup.ps1'
       Name  = 'the history restore stops refusing to overwrite'
       File  = 'scripts/Restore-ClaudeCode.ps1'
       From  = 'already have files on disk'
       To    = 'are present' }

    # --- P30-P32 and the workstation tool ---

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the SKU suggestion loses its basis'
       File  = 'Install-ClaudeGateway.ps1'
       From  = 'v2-service-tiers-overview'
       To    = 'some-blog-post' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the SKU stops being overridable'
       File  = 'Install-ClaudeGateway.ps1'
       From  = "Read-Default -Prompt 'API Management SKU' -Default `$suggested"
       To    = "`$suggested # (" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the group is no longer verified'
       File  = 'scripts/Set-ClaudeBusinessUnit.ps1'
       From  = 'az ad group show --group $Group'
       To    = 'echo skip #' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'tier models stop being checked against deployments'
       File  = 'scripts/Set-ClaudeTier.ps1'
       From  = 'Not deployed on'
       To    = 'Probably fine on' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'a third tier is silently accepted'
       File  = 'scripts/Set-ClaudeTier.ps1'
       From  = "ValidateSet('standard', 'premium')"
       To    = "ValidateSet('standard', 'premium', 'lite')" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Desktop backup stops refusing a running app'
       File  = 'scripts/Backup-ClaudeDesktop.ps1'
       From  = 'holds its conversation database open'
       To    = 'is busy' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Desktop backup starts copying the VM images'
       File  = 'scripts/Backup-ClaudeDesktop.ps1'
       From  = "'vm_bundles'     = 'virtual machine images, reinstallable - 10.6 GB measured'"
       To    = "'nothing_much'   = 'x'" }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the Desktop backup stops reporting unreadable files'
       File  = 'scripts/Backup-ClaudeDesktop.ps1'
       From  = 'unreadable'
       To    = 'skipped-quietly' }

    @{ Suite = 'Test-AdminSurface.ps1'
       Name  = 'the migration tool stops warning about the empty Desktop'
       File  = 'scripts/Migrate-ClaudeWorkstation.ps1'
       From  = 'empty Desktop'
       To    = 'fresh start' }
)

$missed = @()
$caught = 0

try {
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    foreach ($d in 'infra', 'scripts', 'tests', 'analytics') {
        if (Test-Path (Join-Path $root $d)) {
            Copy-Item (Join-Path $root $d) $sandbox -Recurse -Force
        }
    }
    # The installer is asserted against too - it is what hands preserved state
    # back to the template.
    Copy-Item (Join-Path $root 'Install-ClaudeGateway.ps1') $sandbox -Force
    # And the capture/redaction pipeline, plus the ignore rules that keep the
    # unredacted captures out of a commit.
    Copy-Item (Join-Path $root 'guide') $sandbox -Recurse -Force
    Copy-Item (Join-Path $root '.gitignore') $sandbox -Force
    # Screenshots are a few megabytes and nothing here reads them, so the
    # markdown is copied without them - except the portal captures, whose
    # presence is asserted.
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs/adr') -Force | Out-Null
    Get-ChildItem (Join-Path $root 'docs') -Recurse -File -Filter *.md | ForEach-Object {
        $rel = $_.FullName.Substring((Join-Path $root 'docs').Length).TrimStart('\', '/')
        $dest = Join-Path (Join-Path $sandbox 'docs') $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Copy-Item $_.FullName $dest -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'docs/guide') -Force | Out-Null
    foreach ($pattern in 'entra-*.png', 'obs-*.png') {
        Get-ChildItem (Join-Path $root 'docs/guide') -File -Filter $pattern -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName (Join-Path $sandbox 'docs/guide') -Force }
    }

    $suite = Join-Path $sandbox 'tests/Test-BusinessUnits.ps1'
    $teamSuite = Join-Path $sandbox 'tests/Test-Teams.ps1'
    $modelSuite = Join-Path $sandbox 'tests/Test-ModelDeployment.ps1'
    $obsSuite = Join-Path $sandbox 'tests/Test-Observability.ps1'
    $backupSuite = Join-Path $sandbox 'tests/Test-Backup.ps1'
    $adminSuite = Join-Path $sandbox 'tests/Test-AdminSurface.ps1'

    # The copy must pass before any mutation, or a "caught" result below could
    # just mean the sandbox is broken.
    foreach ($s in $suite, $teamSuite, $modelSuite, $obsSuite, $backupSuite, $adminSuite) {
        & $s *>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [SETUP] the unmutated copy of $(Split-Path $s -Leaf) already fails - the sandbox is wrong, not the code" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host '  [BASE]   the unmutated copy passes' -ForegroundColor DarkGray

    foreach ($m in $mutations) {
        $path = Join-Path $sandbox $m.File
        $original = [IO.File]::ReadAllText($path)
        $runner = if ($m.Suite) { Join-Path $sandbox "tests/$($m.Suite)" } else { $suite }

        if (-not $original.Contains($m.From)) {
            Write-Host "  [SETUP] '$($m.From)' not found in $($m.File)" -ForegroundColor Yellow
            $missed += "$($m.Name) (mutation did not apply)"
            continue
        }

        # Replace() not -replace: the patterns hold regex metacharacters, and a
        # literal swap is what we want.
        [IO.File]::WriteAllText($path, $original.Replace($m.From, $m.To))

        & $runner *>&1 | Out-Null
        $wentRed = ($LASTEXITCODE -ne 0)

        [IO.File]::WriteAllText($path, $original)

        if ($wentRed) {
            Write-Host "  [CAUGHT] $($m.Name)" -ForegroundColor Green
            $caught++
        }
        else {
            Write-Host "  [MISSED] $($m.Name)" -ForegroundColor Red
            $missed += $m.Name
        }
    }
}
finally {
    if (Test-Path $sandbox) { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "$caught of $($mutations.Count) mutations caught."

if ($missed.Count) {
    Write-Host ''
    Write-Host 'Not caught - these assertions do not measure what they claim:' -ForegroundColor Red
    $missed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'Every mutation was caught.' -ForegroundColor Green
# Explicit: the loop above deliberately leaves $LASTEXITCODE at 1, because the
# last thing it ran was a suite that was supposed to go red. Falling off the
# end here would report that as this script's own failure.
exit 0
