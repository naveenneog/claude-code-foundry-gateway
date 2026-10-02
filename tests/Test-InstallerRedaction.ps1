# P92 round 3, the Security seat's item 5 (docs/adr/0047-lean-installer-phase-0.md decision 12): one rule set
# redacts the secrets that an error can quote in the free text both installers write, the progress stream and
# every preflight message and remedy. The PowerShell rules (Get-ClaudeInstallRedactionRules,
# scripts/ClaudeInstallResume.ps1) and the bash rules (CKPT_REDACT_RULES, scripts/install-checkpoint.sh) are the
# same JSON text, and both engines turn one corpus into the same text: each shape of
# tests/InstallerRedactionShapes.ps1 into its [redacted] form, and text without a secret unchanged. The
# installers' own use of the rules is tested in the preflight and step suites.
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
Write-Host 'Installer redaction (both engines)' -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
. (Join-Path $PSScriptRoot 'InstallerRedactionShapes.ps1')
$scratch = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('p92-redaction-' + [guid]::NewGuid().ToString('N'))))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false)) }
function ConvertTo-BashPath([string]$Path) { if ($IsWindows -or $env:OS -eq 'Windows_NT') { '/' + ($Path.Replace('\', '/') -replace '^([A-Za-z]):', '$1') } else { $Path } }

# Text that holds no secret, and stays as it is: names that only contain a secret's name, prose, an empty
# value, a Bearer without a token, and text outside ASCII.
$plain = @('AddressCertificatePassword: give it as -AddressCertificatePassword', 'DesktopBearerTokenType id_token', 'the password is wrong', 'signature verified',
    'Bearer', 'password=', 'secrets, keys and tokens', 'Sync-ClaudeAccess.ps1 -ResourceGroup rg-p91', "subscription 'p91-subscription' (00000000-0000-4000-8000-0000000000a1)",
    'clientSecretExpiry: 2026-12-01', 'Caf' + [char]0xE9 + ' ' + [char]::ConvertFromUtf32(0x1F642) + ' ok')
$corpus = @(@($P92RedactionCases | ForEach-Object { $_.Text }) + $plain + @($P92RedactionSentence, ('line one AccountKey=k1' + "`r`n" + 'pwd: two'), 'Bearer [redacted]', 'secret=[redacted]'))
$expected = @(@($P92RedactionCases | ForEach-Object { $_.Redacted }) + $plain + @($null, ('line one AccountKey=[redacted]' + "`r`n" + 'pwd: [redacted]'), 'Bearer [redacted]', 'secret=[redacted]'))

try {
    # ------------------------------------------------------------------ one rule set
    $psSource = [IO.File]::ReadAllText((Join-Path $root 'scripts/ClaudeInstallResume.ps1'))
    $shSource = [IO.File]::ReadAllText((Join-Path $root 'scripts/install-checkpoint.sh'))
    $psJson = [regex]::Match($psSource, "(?m)^\s*\`$json = '(\[[^']*\])'").Groups[1].Value
    $shJson = [regex]::Match($shSource, "(?m)^CKPT_REDACT_RULES='(\[[^']*\])'").Groups[1].Value
    $rules = $null; try { $rules = @($shJson | ConvertFrom-Json -ErrorAction Stop) } catch { }
    Assert 'R3 the PowerShell and bash rule sets are the same JSON text: JWT, Bearer and the named secrets, in that order' ($psJson -and $psJson -ceq $shJson -and $rules -and
        (@($rules | ForEach-Object { $_.name }) -join ',') -eq 'jwt,bearer,named') "PowerShell: $psJson || bash: $shJson"

    # ------------------------------------------------------------------ PowerShell
    $psOut = @(); $psError = ''
    try {
        . (Join-Path $root 'scripts/ClaudeInstallResume.ps1')
        $psOut = @($corpus | ForEach-Object { Protect-ClaudeInstallText $_ })
    }
    catch { $psError = $_.Exception.Message }
    $psShapes = @(for ($i = 0; $i -lt $P92RedactionCases.Count; $i++) { if ($psOut.Count -le $i -or $psOut[$i] -cne $expected[$i]) { "$($P92RedactionCases[$i].Shape): $(if ($psOut.Count -gt $i) { $psOut[$i] })" } })
    Assert 'R3 PowerShell (Protect-ClaudeInstallText) turns each shape into its [redacted] form: JWT, Bearer, sig, signature, AccountKey, SharedAccessKey, SharedAccessSignature, client_secret, clientSecret, password, pwd, secret, access_token, refresh_token' (
        -not $psError -and -not $psShapes.Count) "$psError $($psShapes -join ' || ')"
    $first = $P92RedactionCases.Count
    $psPlain = @(for ($i = $first; $i -lt $first + $plain.Count; $i++) { if ($psOut.Count -le $i -or $psOut[$i] -cne $expected[$i]) { "$($corpus[$i]) -> $(if ($psOut.Count -gt $i) { $psOut[$i] })" } })
    Assert 'R3 PowerShell leaves text without a secret as it is (names that contain a secret''s name, prose, an empty value, a lone Bearer, text outside ASCII)' (-not $psError -and $psOut.Count -eq $corpus.Count -and -not $psPlain.Count) ($psPlain -join ' || ')
    $sentenceOut = if ($psOut.Count -gt $first + $plain.Count) { $psOut[$first + $plain.Count] } else { '' }
    $psSentence = @(Get-P92RedactionProblems $sentenceOut)
    Assert 'R3 PowerShell redacts every shape in one sentence, a value ends at a semicolon, an ampersand, white space, a quote or the end, and a second pass changes nothing' ($sentenceOut -and -not $psSentence.Count -and
        $psOut[-3] -ceq $expected[-3] -and $psOut[-2] -ceq $expected[-2] -and $psOut[-1] -ceq $expected[-1] -and (Protect-ClaudeInstallText $sentenceOut) -ceq $sentenceOut) "$($psSentence -join '; ') || $sentenceOut"

    # ------------------------------------------------------------------ bash, through jq
    $bash = $null
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { foreach ($b in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', (Join-Path "$env:LOCALAPPDATA" 'Programs\Git\bin\bash.exe'))) { if (Test-Path -LiteralPath $b) { $bash = $b; break } } }
    else { $bash = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    $shOut = @(); $shError = ''
    if (-not $bash) { $shError = 'no Git Bash (Windows) or bash on this machine' }
    else {
        $corpusFile = Join-Path $scratch 'corpus.json'
        Write-Lf $corpusFile (ConvertTo-Json -InputObject @($corpus) -Compress)
        $runner = Join-Path $scratch 'run.sh'; $outFile = Join-Path $scratch 'out.json'
        Write-Lf $runner (@"
export HERE='$(ConvertTo-BashPath $root)'
. "`$HERE/scripts/install-checkpoint.sh" || exit 90
jq -c --argjson R "`$CKPT_REDACT_RULES" "`$CKPT_REDACT_JQ"' map(redact)' '$(ConvertTo-BashPath $corpusFile)' | tr -d '\r' > '$(ConvertTo-BashPath $outFile)'
"@)
        # Read as UTF-8 from a file: a native command's output is decoded with the console's code page.
        $log = @(& $bash (ConvertTo-BashPath $runner) 2>&1 | ForEach-Object { [string]$_ })
        $raw = if (Test-Path -LiteralPath $outFile) { [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8).Trim() } else { '' }
        try { $shOut = @($raw | ConvertFrom-Json -ErrorAction Stop) } catch { $shError = "bash printed no JSON list: $raw $($log -join ' | ')" }
    }
    $shShapes = @(for ($i = 0; $i -lt $P92RedactionCases.Count; $i++) { if ($shOut.Count -le $i -or $shOut[$i] -cne $expected[$i]) { "$($P92RedactionCases[$i].Shape): $(if ($shOut.Count -gt $i) { $shOut[$i] })" } })
    Assert 'R3 bash (the redact rule of CKPT_REDACT_JQ, in jq) turns each shape into its [redacted] form' (-not $shError -and -not $shShapes.Count) "$shError $($shShapes -join ' || ')"
    $diff = @(for ($i = 0; $i -lt $corpus.Count; $i++) { if ($psOut.Count -le $i -or $shOut.Count -le $i -or $psOut[$i] -cne $shOut[$i]) { "#$i PowerShell: $(if ($psOut.Count -gt $i) { $psOut[$i] }) || bash: $(if ($shOut.Count -gt $i) { $shOut[$i] })" } })
    Assert 'R3 both engines give the same text for the whole corpus, character for character' (-not $psError -and -not $shError -and $psOut.Count -eq $corpus.Count -and $shOut.Count -eq $corpus.Count -and -not $diff.Count) (($diff | Select-Object -First 3) -join ' ## ')
}
finally {
    if ($env:P91_KEEP_SCRATCH -ne '1') { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host ("{0} checks, {1} failed, {2:N1} s" -f $script:checks, $script:fail, $watch.Elapsed.TotalSeconds)
if ($script:fail) { exit 1 }
