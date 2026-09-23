# P29 - backup and restore, for the gateway and for a developer's history.
#
# Two different things with two different risks, and the tests are asymmetric
# for that reason.
#
# The gateway backup must never write a secret to disk. API Management returns
# a secret named value only from the listValue action, so reading the plain
# list makes that safe by construction rather than by care - and the test
# asserts the construction, not the care.
#
# The Claude Code backup cannot be made safe that way, because conversations
# legitimately discuss credentials. Measured against real history, 12 of 93
# transcripts matched a credential keyword and every one was a conversation
# about handling one. So config blocks and transcripts report.

$root = Split-Path $PSScriptRoot -Parent
$bg = Join-Path $root 'scripts/Backup-ClaudeGateway.ps1'
$rg = Join-Path $root 'scripts/Restore-ClaudeGateway.ps1'
$bc = Join-Path $root 'scripts/Backup-ClaudeCode.ps1'
$rc = Join-Path $root 'scripts/Restore-ClaudeCode.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Backup - the gateway' -ForegroundColor Cyan

Assert 'a backup script exists'  (Test-Path $bg) $bg
Assert 'a restore script exists' (Test-Path $rg) $rg
$b = Get-Content $bg -Raw

Assert 'it captures named values' ($b -match 'namedValues\?api-version')
# The whole secret-safety property. listValue returns a secret's contents; the
# plain list omits them. Calling listValue anywhere here would put secrets in a
# file on disk.
#
# Asserted against the call form, not the word: the first version matched the
# comment that explains why the call is not made, so it would have passed on a
# script that made it.
Assert 'it never calls the listValue action' ($b -notmatch '/listValue')
Assert 'and records which were secret' ($b -match 'secretsSkipped')
Assert 'it captures the policy'    ($b -match 'policies/policy')
Assert 'and the saved functions'   ($b -match 'savedSearches')
# The workspace is asked of the gateway, not chosen by counting. Measured on the
# reference deployment: three workspaces in one group, so a count-based choice
# chose nothing and every backup left the saved functions out - which both
# workbooks call, nineteen times between them. A restore from such a file
# brought the workbooks back with every tile on an error.
#
# Asserted on the call and the filter, not the comment above them, which is the
# mistake the first listValue assertion made.
Assert 'the workspace is asked of the gateway'   ($b.Contains('az monitor diagnostic-settings list --resource $apimResourceId'))
Assert 'and restricted to its own resource group' ($b.Contains('/resourceGroups/$([regex]::Escape($ResourceGroup))/providers/Microsoft\.OperationalInsights/workspaces/'))
Assert 'a workspace elsewhere is reported'       ($b -match "and restore publishes into the gateway's own group")
Assert 'and the source of the choice is printed' ($b -match 'named by the gateway diagnostic setting')
Assert 'and the workbooks'         ($b -match 'workbooks\?api-version')
# The list omits serializedData without saying so. A backup of the list alone
# restores an empty workbook and fails at the far end of a migration.
Assert 'workbook content is fetched explicitly' ($b -match 'canFetchContent=true')
# And a listed workbook that cannot be captured must fail the run. The first
# version caught this into a warning and wrote a backup with no workbook in it.
Assert 'a workbook it cannot capture fails the backup' ($b -match 'cannot be restored')
Assert 'the file carries a schema version' ($b -match 'schemaVersion')

Write-Host ''
Write-Host 'Restore - the gateway' -ForegroundColor Cyan

$r = Get-Content $rg -Raw
# A restore overwrites live entitlement and live budgets.
#
# Asserted on the guard, not the wording. PowerShell -match is case-insensitive,
# so matching "Dry run" also matched "dry run" in the help text above, and the
# check passed on a script that had stopped being one.
Assert 'it is a dry run by default'      ($r -match 'if \(-not \$Apply\)[\s\S]{0,400}exit 0')
Assert 'it shows what would change'      ($r -match 'change|create' -and $r -match 'Named value')
Assert 'it refuses another gateway'      ($r -match 'Add -Force if you mean it')
Assert 'it refuses an unknown schema'    ($r -match 'schemaVersion -ne')
Assert 'it refuses a contentless workbook' ($r -match 'has no content')
# Keeping the recorded sourceId points a restored workbook at the workspace the
# migration is leaving behind.
Assert 'it rebinds the workbook to the target workspace' ($r -match '\$source = if \(\$WorkspaceName\)')
Assert 'it reports what it could not restore' ($r -match 'cannot be restored')

Write-Host ''
Write-Host 'Backup - Claude Code history' -ForegroundColor Cyan

Assert 'a backup script exists'  (Test-Path $bc) $bc
Assert 'a restore script exists' (Test-Path $rc) $rc
$c = Get-Content $bc -Raw

Assert 'it captures conversations' ($c -match "Relative = 'projects'")
Assert 'and the command history'   ($c -match 'history\.jsonl')
# Measured: ~/.claude.json holds oauth, key and token material.
Assert 'it excludes the credential file' ($c -match '\.claude\.json')
Assert 'and says why'                    ($c -match 'oauth, key and token')
# Config and transcripts are treated differently on purpose.
Assert 'config credentials block the backup' ($c -match "Scan = 'block'" -and $c -match 'Refusing to write a backup')
Assert 'transcript mentions are reported'    ($c -match "Scan = 'report'")
Assert 'and the reason is recorded'          ($c -match '12 of 93')
# The archive is prompts and source code. Saying so is the only honest control.
Assert 'it labels what the archive holds'    ($c -match 'prompts and source code')
Assert 'it scans before copying'             ($c.IndexOf('Scan before copying') -lt $c.IndexOf('Copy-Item $src $dest'))

Write-Host ''
Write-Host 'Restore - Claude Code history' -ForegroundColor Cyan

$rcc = Get-Content $rc -Raw
Assert 'it is a dry run by default'   ($rcc -match 'if \(-not \$Apply\)[\s\S]{0,400}exit 0')
Assert 'it refuses to overwrite'      ($rcc -match 'already have files on disk')
# Transcripts are append-only. Replacing a populated folder loses the middle.
Assert 'and says what would be lost'  ($rcc -match 'no undo')
Assert 'it refuses an unknown schema' ($rcc -match 'schemaVersion -ne')

Write-Host ''
Write-Host 'Backup - not committed' -ForegroundColor Cyan

$ignore = Get-Content (Join-Path $root '.gitignore') -Raw
Assert 'gateway backups are git-ignored'     ($ignore -match '(?m)^backups/')
Assert 'Claude Code backups are git-ignored' ($ignore -match '(?m)^claude-code-backups/')

Write-Host ''
Write-Host 'Backup - documentation' -ForegroundColor Cyan

$mig = Get-Content (Join-Path $root 'docs/MIGRATION.md') -Raw
Assert 'migration documents the gateway backup' ($mig -match 'Backup-ClaudeGateway')
Assert 'and the restore'                        ($mig -match 'Restore-ClaudeGateway')
Assert 'and the conversation backup'            ($mig -match 'Backup-ClaudeCode')
Assert 'and states secrets are not captured'    ($mig -match '(?i)secret')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Backup contract holds.' -ForegroundColor Green
exit 0
