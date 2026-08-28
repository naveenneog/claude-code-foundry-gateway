# Captures real script output for the documentation screenshots.
#
# The interactive wizard is driven with piped answers so the transcript shows
# both the prompts and what a person would type - a -Yes run hides exactly the
# part readers need to see.
#
# Everything here is non-destructive: the wizard runs with -WhatIf and stops at
# the summary.

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'docs/transcripts'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# Everything captured here ends up in published screenshots, so the operator's
# own identity, tenant and paths are replaced with the documentation values.
function Remove-Identifiers {
    param([string]$Text)
    $Text = $Text -replace [regex]::Escape($env:USERPROFILE), '~'
    $Text = $Text -replace [regex]::Escape($root), '.'
    $Text = $Text -replace '(?i)naveen\.g@microsoft\.com', 'admin@contoso.com'
    $Text = $Text -replace '(?i)navg@microsoft\.com', 'admin@contoso.com'
    $Text = $Text -replace 'MCAPS-Hybrid-REQ-[0-9-]+-\w+', 'Contoso-Production'
    $Text = $Text -replace 'ai-contosohub530569751908', 'ai-contoso-foundry'
    $Text = $Text -replace 'apim-claude-gw-fzgql9', 'apim-claude-gw'
    $Text = $Text -replace '16b3c013-d300-468d-ac64-7eda0820b6d3', '11111111-2222-3333-4444-555555555555'
    $Text = $Text -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '00000000-0000-0000-0000-000000000000'
    $Text = $Text -replace 'rg-contosohub', 'rg-contoso-ai'

    # The account-discovery step lists every Cognitive Services account in the
    # subscription, so real resource names appear. Scrub the operator-specific
    # tokens generically rather than enumerating each name - a new resource
    # would otherwise leak silently the next time this runs.
    $Text = $Text -replace '(?i)\bai-navgai[0-9]+\b', 'ai-contoso-foundry'
    $Text = $Text -replace '(?i)\bai-navg[-0-9]*\b', 'ai-contoso-eval'
    $Text = $Text -replace '(?i)\bnaveen[a-z0-9-]*\b', 'contoso-service'
    $Text = $Text -replace '(?i)\bnavg[a-z0-9-]*\b', 'contoso-service'
    $Text = $Text -replace '(?i)\bmcaps[a-z0-9-]*\b', 'contoso-safety'
    $Text = $Text -replace '(?i)\brg-navg[a-z0-9-]*\b', 'rg-contoso-ai'
    $Text = $Text -replace '(?i)\bneo-pikachu\b', 'rg-contoso-ai'

    return $Text
}

# Write-Host writes to the host, not the pipeline, so `& $block 2>&1 | Out-String`
# captures nothing - the text appears on the console and the file ends up empty.
# Running the script as a child process and capturing its stdout is the only way
# to get Write-Host output, so both capture paths use a subprocess.
function Save-Transcript {
    param([string]$Name, [string]$ScriptPath, [string[]]$Arguments = @())
    Write-Host "capturing $Name ..." -ForegroundColor Cyan

    $ps = (Get-Command pwsh -ErrorAction SilentlyContinue) ?? (Get-Command powershell)
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $text = cmd /c "`"$($ps.Source)`" -NoProfile -File `"$ScriptPath`" $argLine" | Out-String -Width 96

    $text = Remove-Identifiers $text
    $text | Set-Content (Join-Path $out "$Name.txt") -Encoding UTF8
    $n = (Get-Content (Join-Path $out "$Name.txt")).Count
    Write-Host "  -> $Name.txt  ($n lines)" -ForegroundColor DarkGray
}

# Interactive prompts need a real stdin. A *pipe* puts PowerShell into
# NonInteractive mode and Read-Host refuses; *file redirection* does not, so the
# answers go through a temp file and `cmd /c ... < file`. winpty was tried first
# and rejected - it needs a tty on stdin, which a redirect is not.
function Save-InteractiveTranscript {
    param([string]$Name, [string]$ScriptPath, [string[]]$Arguments, [string[]]$Answers)
    Write-Host "capturing $Name (interactive) ..." -ForegroundColor Cyan

    $answerFile = Join-Path $env:TEMP "transcript-answers.txt"
    ($Answers -join "`n") + "`n" | Set-Content $answerFile -Encoding ASCII -NoNewline

    $ps = (Get-Command pwsh -ErrorAction SilentlyContinue) ?? (Get-Command powershell)
    $argLine = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $text = cmd /c "`"$($ps.Source)`" -NoProfile -File `"$ScriptPath`" $argLine < `"$answerFile`"" | Out-String -Width 96

    Remove-Item $answerFile -Force -ErrorAction SilentlyContinue
    $text = Remove-Identifiers $text
    $text | Set-Content (Join-Path $out "$Name.txt") -Encoding UTF8
    Write-Host "  -> $Name.txt" -ForegroundColor DarkGray
}

# 1. The admin wizard, interactive, showing the prompts and typed answers.
#    -FoundryAccount is supplied so discovery is skipped: on a subscription with
#    dozens of Cognitive Services accounts that step prints a long list and is
#    slow, and it is not what this screenshot is for. The prompts are.
Save-InteractiveTranscript 'admin-wizard' `
    (Join-Path $root 'Install-ClaudeGateway.ps1') `
    @('-WhatIf', '-FoundryAccount', 'ai-contosohub530569751908') @(
        'y'          # use the current subscription
        ''           # resource group
        ''           # location
        ''           # sku
        'claudegw'   # name prefix
        ''           # publisher email
        '30000'      # standard tokens/min - deliberately not the default
        ''           # standard tokens/day
        ''           # premium tokens/min
        ''           # premium tokens/day
        ''           # requests/min
        ''           # standard group
        ''           # premium group
    )

# 2. The developer setup, real run, nothing installed.
Save-Transcript 'workstation-setup' `
    (Join-Path $root 'scripts/Setup-ClaudeWorkstation.ps1') `
    @('-ConfigPath', (Join-Path $root 'onboarding/claude-gateway.json'), '-SkipInstall')

# 3. Onboarding email generation.
Save-Transcript 'onboarding-email' `
    (Join-Path $root 'scripts/New-OnboardingEmail.ps1') `
    @('-ConfigPath', (Join-Path $root 'onboarding/claude-gateway.json'), '-To', 'alice@contoso.com', '-DisplayName', 'Alice')

# 4. The health check.
Save-Transcript 'governance-checks' `
    (Join-Path $root 'scripts/Debug-ClaudeCode.ps1') `
    @('-GatewayBaseUrl', 'https://apim-claude-gw-fzgql9.azure-api.net/claude', '-SkipLiveCall')

Write-Host ''
Write-Host "transcripts in $out" -ForegroundColor Green
Get-ChildItem $out -Filter *.txt | ForEach-Object { "  {0,-26} {1} lines" -f $_.Name, (Get-Content $_.FullName).Count }
