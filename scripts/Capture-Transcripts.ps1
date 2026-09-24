# Captures real script output for the documentation screenshots.
#
# The interactive wizard is driven with piped answers so the transcript shows
# both the prompts and what a person would type - a -Yes run hides exactly the
# part readers need to see.
#
# Everything here is non-destructive: the wizard runs with -WhatIf and stops at
# the summary.

param(
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ApimName,
    [string]$FoundryAccount,
    [string]$RedactionsFile = $env:REDACTIONS_FILE,
    [switch]$NonInteractive,
    [ValidateSet('All', 'Wizard')][string]$Flow = 'All'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'docs/transcripts'
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (-not $RedactionsFile -or -not (Test-Path $RedactionsFile)) {
    throw 'Supply -RedactionsFile with the private real-to-Contoso replacement map.'
}
$replacementPairs = Get-Content $RedactionsFile -Raw | ConvertFrom-Json
$selectionFile = Join-Path $out "discovery-$PID.json"
$selectionArgs = @((Join-Path $root 'guide/discover-targets.mjs'), '--resources', 'apim,foundry', '--output', $selectionFile)
if ($SubscriptionId) { $selectionArgs += @('--subscription', $SubscriptionId) }
if ($ResourceGroup) { $selectionArgs += @('--resource-group', $ResourceGroup) }
if ($ApimName) { $selectionArgs += @('--apim-name', $ApimName) }
if ($FoundryAccount) { $selectionArgs += @('--foundry', $FoundryAccount) }
if ($NonInteractive) { $selectionArgs += '--non-interactive' }
& node @selectionArgs
if ($LASTEXITCODE) { throw 'Discovery failed; nothing captured.' }
$target = Get-Content $selectionFile -Raw | ConvertFrom-Json
$FoundryAccount = $target.foundry.name
$gatewayBaseUrl = "$($target.apim.gatewayUrl.TrimEnd('/'))/claude"

# Everything captured here ends up in published screenshots, so the operator's
# own identity, tenant and paths are replaced with the documentation values.
function Remove-Identifiers {
    param([string]$Text)
    $Text = $Text -replace [regex]::Escape($env:USERPROFILE), '~'
    $Text = $Text -replace [regex]::Escape($root), '.'
    foreach ($pair in ($replacementPairs | Sort-Object { -([string]$_[0]).Length })) {
        # Same length as the original, deliberately: consume/extend table padding rather
        # than baking equal-width aliases for one customer's resource names into source.
        $from = [string]$pair[0]
        $to = [string]$pair[1]
        $Text = [regex]::Replace($Text, ([regex]::Escape($from) + '(?<padding> {2,})'), {
            param($match)
            $width = $match.Length
            if ($to.Length -ge $width) { throw 'Replacement does not fit the table column; supply a shorter Contoso placeholder.' }
            return $to.PadRight($width)
        })
        $Text = $Text.Replace([string]$pair[0], [string]$pair[1])
    }
    $Text = $Text -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', 'admin@contoso.com'
    $Text = $Text -replace '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '00000000-0000-0000-0000-000000000000'
    foreach ($pair in $replacementPairs) {
        if ($pair[0] -ne $pair[1] -and $Text.Contains([string]$pair[0])) {
            throw 'A real identifier survived transcript redaction.'
        }
    }

    return $Text
}

function Save-Record([string]$Name, [string]$Command, [int]$ExitCode) {
    $manifest = Join-Path $out 'manifest.json'
    $records = if (Test-Path $manifest) { @(Get-Content $manifest -Raw | ConvertFrom-Json) } else { @() }
    $records = @($records | Where-Object file -ne "$Name.txt") + @([ordered]@{
        file = "$Name.txt"
        command = Remove-Identifiers $Command
        live = $true
        captured_at_utc = [datetime]::UtcNow.ToString('o')
        exit_code = $ExitCode
    })
    ConvertTo-Json -InputObject $records -Depth 5 | Set-Content $manifest -Encoding UTF8
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
    # Captured without colour, and it cannot be otherwise: Write-Host
    # -ForegroundColor writes through the console API rather than emitting SGR,
    # so nothing reaches a redirected stream. Setting
    # $PSStyle.OutputRendering = 'Ansi' was tried and does not help - it governs
    # formatted output, not Write-Host. render-terminal.mjs colours the [OK],
    # [WARN] and [FAIL] markers itself, which reproduces what the operator saw
    # from the same signal rather than inventing one.
    $text = cmd /c "`"$($ps.Source)`" -NoProfile -File `"$ScriptPath`" $argLine" | Out-String -Width 96
    $code = $LASTEXITCODE

    $text = Remove-Identifiers $text
    $text | Set-Content (Join-Path $out "$Name.txt") -Encoding UTF8
    Save-Record $Name "$ScriptPath $argLine" $code
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
    $code = $LASTEXITCODE

    Remove-Item $answerFile -Force -ErrorAction SilentlyContinue
    $text = Remove-Identifiers $text
    $text | Set-Content (Join-Path $out "$Name.txt") -Encoding UTF8
    Save-Record $Name "$ScriptPath $argLine" $code
    Write-Host "  -> $Name.txt" -ForegroundColor DarkGray
}

# 1. The admin wizard, interactive, showing the prompts and typed answers.
#    -FoundryAccount is supplied so discovery is skipped: on a subscription with
#    dozens of Cognitive Services accounts that step prints a long list and is
#    slow, and it is not what this screenshot is for. The prompts are.
if ($NonInteractive) {
    Save-Transcript 'admin-wizard' (Join-Path $root 'Install-ClaudeGateway.ps1') @(
        '-WhatIf', '-Yes', '-SubscriptionId', $target.subscriptionId,
        '-FoundryAccount', $FoundryAccount, '-FoundryResourceGroup', $target.foundry.resourceGroup,
        '-ResourceGroup', $target.resourceGroup
    )
}
else {
Save-InteractiveTranscript 'admin-wizard' `
    (Join-Path $root 'Install-ClaudeGateway.ps1') `
    @('-WhatIf', '-FoundryAccount', $FoundryAccount) @(
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
}

if ($Flow -eq 'Wizard') { return }

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
    @('-GatewayBaseUrl', $gatewayBaseUrl, '-SkipLiveCall')

# 5. The network check, on a machine where everything works.
Save-Transcript 'network-check' `
    (Join-Path $root 'scripts/Test-ClaudeNetwork.ps1') @('-IncludeOptional')

# 6. The same check behind a proxy that cuts the response mid-stream.
#
#    This is the screenshot that is hard to obtain and most worth having: every
#    host reads as reachable and the call still fails, which is the state that
#    sends people back to a firewall list that was never wrong. Reproduced
#    rather than staged - hostile-proxy.mjs establishes the connection and then
#    resets it, which is what an inspecting proxy does to server-sent events.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    Write-Host 'starting the cutting proxy for the reset capture ...' -ForegroundColor Cyan
    $proxy = Start-Process -FilePath $node.Source `
        -ArgumentList @((Join-Path $root 'scripts/hostile-proxy.mjs'), '--port', '8873', '--after', '2048') `
        -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $savedHttps = $env:HTTPS_PROXY
    $savedHttp = $env:HTTP_PROXY
    try {
        $env:HTTPS_PROXY = 'http://127.0.0.1:8873'
        $env:HTTP_PROXY = 'http://127.0.0.1:8873'
        Save-Transcript 'network-reset' `
            (Join-Path $root 'scripts/Test-ClaudeNetwork.ps1') @()
    }
    finally {
        $env:HTTPS_PROXY = $savedHttps
        $env:HTTP_PROXY = $savedHttp
        if ($proxy -and -not $proxy.HasExited) { Stop-Process -Id $proxy.Id -Force -ErrorAction SilentlyContinue }
    }
}
else {
    Write-Host 'skipping the reset capture - node is not installed' -ForegroundColor Yellow
}

# 7. The bill of materials, with prices read live rather than quoted.
Save-Transcript 'bom-prices' `
    (Join-Path $root 'scripts/Get-ClaudeBom.ps1') @('-WithPrices')

# 8. Developer onboarding, checks only - the survey a developer runs before
#    anything is written, and the one an administrator runs across a fleet.
Save-Transcript 'onboard-preflight' `
    (Join-Path $root 'scripts/Onboard-ClaudeDeveloper.ps1') `
    @('-ConfigPath', (Join-Path $root 'onboarding/claude-gateway.json'), '-PreflightOnly')

Write-Host ''
Write-Host "transcripts in $out" -ForegroundColor Green
Get-ChildItem $out -Filter *.txt | ForEach-Object { "  {0,-26} {1} lines" -f $_.Name, (Get-Content $_.FullName).Count }
