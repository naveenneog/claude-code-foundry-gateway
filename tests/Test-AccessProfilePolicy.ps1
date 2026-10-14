param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$commandPath = Join-Path $root 'scripts\New-ClaudeDesktopAccessProfile.ps1'
$catalogPath = Join-Path ([IO.Path]::GetTempPath()) ('p116-profile-' + [guid]::NewGuid().ToString('N') + '.json')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('p116-policy-' + [guid]::NewGuid().ToString('N'))
$script:assertions = 0
$script:failures = 0

function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}

function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = @(& $Action 6>&1) }
    catch { $script:CapturedError = $_.Exception.Message }
}

$catalog = [ordered]@{
    schemaVersion = 1
    tenantId = '11111111-2222-4333-8444-555555555555'
    plans = @([ordered]@{
        id = 'developer'
        name = 'Developer'
        enabled = $true
        nominalCredit = [ordered]@{ amount = 100; currency = 'USD'; period = 'month'; scope = 'user' }
        compatibilityTier = 'standard'
    })
    profiles = @([ordered]@{
        id = 'cowork-design'
        name = 'Cowork and Design'
        planId = 'developer'
        groupObjectId = '99999999-8888-4777-8666-555555555555'
        priority = 10
        capabilities = @('cowork', 'design')
        modelFamilies = @('sonnet', 'mythos')
        connectors = @('m365')
        enabled = $true
    })
}
[IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

try {
    Assert 'the access-profile policy command exists' (Test-Path -LiteralPath $commandPath) $commandPath
    if (-not (Test-Path -LiteralPath $commandPath)) {
        throw 'RED: scripts/New-ClaudeDesktopAccessProfile.ps1 does not exist.'
    }

    $command = Get-Command $commandPath
    $commandText = Get-Content -LiteralPath $commandPath -Raw
    $descriptorText = Get-Content -LiteralPath (Join-Path $root 'sync\src\describe-access-profile.mjs') -Raw
    Assert 'CatalogPath, ProfileId and Platform are mandatory' (
        @('CatalogPath','ProfileId','Platform' | Where-Object {
            $parameter = $command.Parameters[$_]
            $parameter -and @($parameter.Attributes | Where-Object {
                $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory
            }).Count
        }).Count -eq 3)
    Assert 'the command exposes WhatIf' ($command.Parameters.ContainsKey('WhatIf'))
    Assert 'the command reuses the existing full policy generator' (
        $commandText -match "New-ClaudeCodePolicy\.ps1" -and
        $commandText -notmatch 'Windows Registry Editor Version|PayloadType</key>')
    Assert 'the descriptor imports the canonical catalog validator' (
        $descriptorText -match "from './access-catalog\.mjs'" -and
        $descriptorText -match 'canonicalizeAccessCatalog')
    Assert 'the command does not touch AUM or Turnstile' (
        $commandText -notmatch '(?i)aum|turnstile')

    $platformFiles = [ordered]@{
        Linux = 'claude-desktop.managed-settings.json'
        Windows = 'claude-desktop.reg'
        macOS = 'claude-desktop.mobileconfig'
    }
    foreach ($platform in $platformFiles.Keys) {
        $out = Join-Path $scratch $platform
        Capture {
            & $commandPath -CatalogPath $catalogPath -ProfileId cowork-design -Platform $platform `
                -GatewayUrl 'https://gateway.example/claude' -OutputPath $out
        }
        $policyPath = Join-Path $out $platformFiles[$platform]
        $manifestPath = Join-Path $out 'claude-desktop.profile.json'
        Assert "$platform generation succeeds" (-not $CapturedError) $CapturedError
        Assert "$platform writes only the selected policy and manifest" (
            (Test-Path -LiteralPath $policyPath) -and (Test-Path -LiteralPath $manifestPath) -and
            @(Get-ChildItem -LiteralPath $out -File).Count -eq 2) ((Get-ChildItem -LiteralPath $out -File -ErrorAction SilentlyContinue).Name -join ', ')

        if (Test-Path -LiteralPath $manifestPath) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            Assert "$platform manifest identifies plan, profile and catalog" (
                $manifest.plan.id -eq 'developer' -and
                $manifest.profile.id -eq 'cowork-design' -and
                $manifest.catalog.tenantId -eq '11111111-2222-4333-8444-555555555555' -and
                [string]$manifest.catalog.hash -match '^sha256:[0-9a-f]{64}$')
            Assert "$platform manifest keeps model families as metadata" (
                @($manifest.metadata.modelFamilies).Count -eq 2 -and
                @($manifest.metadata.modelFamilies) -contains 'sonnet' -and
                @($manifest.metadata.modelFamilies) -contains 'mythos')
            Assert "$platform reports Design as unsupported" (
                @($manifest.unsupported | Where-Object { $_.id -eq 'design' -and $_.kind -eq 'capability' }).Count -eq 1)
            Assert "$platform reports M365 through the connector deployment path" (
                @($manifest.unmanaged | Where-Object {
                    $_.id -eq 'm365' -and $_.kind -eq 'connector' -and $_.deploymentPath -eq 'connector-admin'
                }).Count -eq 1)
        }
    }

    $linux = Get-Content -LiteralPath (Join-Path $scratch 'Linux\claude-desktop.managed-settings.json') -Raw | ConvertFrom-Json
    Assert 'Linux emits explicit true and false capability controls' (
        $linux.chatTabEnabled -eq $false -and
        $linux.coworkTabEnabled -eq $true -and
        $linux.isClaudeCodeForDesktopEnabled -eq $false)
    Assert 'Linux invents no Design or M365 setting' (
        @($linux.PSObject.Properties.Name | Where-Object { $_ -match '(?i)design|m365' }).Count -eq 0)

    $windows = Get-Content -LiteralPath (Join-Path $scratch 'Windows\claude-desktop.reg') -Raw
    Assert 'Windows emits all three controls as REG_SZ strings' (
        $windows -match '"chatTabEnabled"="false"' -and
        $windows -match '"coworkTabEnabled"="true"' -and
        $windows -match '"isClaudeCodeForDesktopEnabled"="false"')

    $mac = Get-Content -LiteralPath (Join-Path $scratch 'macOS\claude-desktop.mobileconfig') -Raw
    Assert 'macOS emits all three controls as managed strings' (
        $mac -match '<key>chatTabEnabled</key>\s*<string>false</string>' -and
        $mac -match '<key>coworkTabEnabled</key>\s*<string>true</string>' -and
        $mac -match '<key>isClaudeCodeForDesktopEnabled</key>\s*<string>false</string>')

    $whatIfOut = Join-Path $scratch 'whatif'
    Capture {
        & $commandPath -CatalogPath $catalogPath -ProfileId cowork-design -Platform Windows `
            -GatewayUrl 'https://gateway.example/claude' -OutputPath $whatIfOut -WhatIf
    }
    $whatIfText = (@($CapturedResult) | ForEach-Object { [string]$_ }) -join "`n"
    Assert 'WhatIf validates and names both intended outputs' (
        -not $CapturedError -and
        $whatIfText -match 'cowork-design' -and
        $whatIfText -match 'sha256:[0-9a-f]{64}' -and
        $whatIfText -match 'claude-desktop\.reg' -and
        $whatIfText -match 'claude-desktop\.profile\.json') "$CapturedError | $whatIfText"
    Assert 'WhatIf writes nothing' (-not (Test-Path -LiteralPath $whatIfOut))

    foreach ($failure in @(
        @{ Name = 'unknown profile'; Catalog = $catalogPath; Profile = 'missing'; Platform = 'Linux'; Output = $null },
        @{ Name = 'unsafe catalog path'; Catalog = ($catalogPath + '*'); Profile = 'cowork-design'; Platform = 'Linux'; Output = $null },
        @{ Name = 'unsafe output path'; Catalog = $catalogPath; Profile = 'cowork-design'; Platform = 'Linux'; Output = 'Env:\P116Unsafe' },
        @{ Name = 'unsupported platform'; Catalog = $catalogPath; Profile = 'cowork-design'; Platform = 'android'; Output = $null }
    )) {
        $failedOut = Join-Path $scratch ('failed-' + ($failure.Name -replace ' ', '-'))
        $requestedOut = if ($failure.Output) { $failure.Output } else { $failedOut }
        Capture {
            & $commandPath -CatalogPath $failure.Catalog -ProfileId $failure.Profile -Platform $failure.Platform `
                -GatewayUrl 'https://gateway.example/claude' -OutputPath $requestedOut
        }
        Assert "$($failure.Name) fails closed" (
            $CapturedError -and -not (Test-Path -LiteralPath $failedOut)) "$CapturedError"
    }

    $malformed = Join-Path $scratch 'malformed.json'
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    [IO.File]::WriteAllText($malformed, '{"schemaVersion":1}', [Text.UTF8Encoding]::new($false))
    $malformedOut = Join-Path $scratch 'failed-malformed'
    Capture {
        & $commandPath -CatalogPath $malformed -ProfileId cowork-design -Platform Linux `
            -GatewayUrl 'https://gateway.example/claude' -OutputPath $malformedOut
    }
    Assert 'malformed catalog fails closed before output' (
        $CapturedError -and -not (Test-Path -LiteralPath $malformedOut)) $CapturedError

    $hosts = @(
        @{ Name = 'PowerShell 7'; Exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source },
        @{ Name = 'Windows PowerShell 5.1'; Exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
    )
    $ran = 0
    foreach ($hostInfo in $hosts) {
        if (-not $hostInfo.Exe -or -not (Test-Path -LiteralPath $hostInfo.Exe)) {
            Write-Host "  [SKIP] $($hostInfo.Name) is not installed"
            continue
        }
        $hostOut = Join-Path $scratch ('host-' + ($hostInfo.Name -replace '[^A-Za-z0-9]', ''))
        $child = @(& $hostInfo.Exe -NoProfile -File $commandPath -CatalogPath $catalogPath `
            -ProfileId cowork-design -Platform Linux -GatewayUrl 'https://gateway.example/claude' `
            -OutputPath $hostOut 2>&1)
        $code = $LASTEXITCODE
        $hostPolicy = Join-Path $hostOut 'claude-desktop.managed-settings.json'
        $hostJson = if (Test-Path -LiteralPath $hostPolicy) {
            Get-Content -LiteralPath $hostPolicy -Raw | ConvertFrom-Json
        }
        else { $null }
        Assert "$($hostInfo.Name) generates the explicit profile" (
            $code -eq 0 -and $hostJson -and
            $hostJson.chatTabEnabled -eq $false -and
            $hostJson.coworkTabEnabled -eq $true -and
            $hostJson.isClaudeCodeForDesktopEnabled -eq $false) ($child -join ' | ')
        $ran++
    }
    Assert 'at least one supported PowerShell host ran the generator' ($ran -gt 0)
}
finally {
    Remove-Item -LiteralPath $catalogPath -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

if ($failures) { throw "$failures of $assertions access-profile policy assertions failed." }
Write-Host "$assertions access-profile policy assertions passed."
