# P67 - client configuration every supported release reads (ADR-0031). Offline; Azure and the
# Claude clients are stubbed. RED first: written while Setup-ClaudeWorkstation.ps1 wrote
# `external-idp` Desktop keys and no Claude Code capability declarations.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$support = Join-Path $root 'scripts\ClaudeClientSupport.ps1'
$desktopHelper = Join-Path $root 'scripts\ClaudeDesktopSignIn.ps1'
$schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\claude-desktop-schema-2.2553.1.0.json') -Raw | ConvertFrom-Json
$allCaps = 'effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking'
# A fake bearer token for the stubs (header {"alg":"none"}), built here so no token-shaped literal is in the source.
$fakeJwt = 'eyJ' + 'hbGciOiJub25lIn0' + '.' + 'eyJzdWIiOiJwNjcifQ' + '.c2ln'

Write-Host ''
Write-Host 'P67 Claude Code model support' -ForegroundColor Cyan
Assert 'the client support module exists' (Test-Path -LiteralPath $support) $support
if (Test-Path -LiteralPath $support) {
    . $support

    $opus = Get-ClaudeModelClientSupport -Model 'claude-opus-5'
    $opus55 = Get-ClaudeModelClientSupport -Model 'claude-opus-5-5'
    $sonnet = Get-ClaudeModelClientSupport -Model 'claude-sonnet-5'
    Assert 'Opus 5 declares every capability the model supports' ($opus.Capabilities -eq $allCaps)
    Assert 'Opus 5 needs the Claude Code release that added it' ($opus.ClaudeCode -eq '2.1.219')
    Assert 'Opus 5.5 is not mistaken for Opus 5' ($opus55.Model -eq 'claude-opus-5-5' -and $opus55.ClaudeCode -eq '2.1.280')
    Assert 'Sonnet 5 needs the Claude Code release that added it' ($sonnet.Capabilities -eq $allCaps -and $sonnet.ClaudeCode -eq '2.1.197')
    Assert 'an unknown model gets no declaration' ($null -eq (Get-ClaudeModelClientSupport -Model 'claude-sonnet-4-6'))
    Assert 'a dated model id is recognised' ((Get-ClaudeModelClientSupport -Model 'claude-sonnet-5-20260601').Model -eq 'claude-sonnet-5')

    Assert 'a CLI banner parses to a version' ((ConvertTo-ClaudeClientVersion '2.1.101 (Claude Code)') -eq [version]'2.1.101')
    Assert 'text without a version parses to nothing' ($null -eq (ConvertTo-ClaudeClientVersion 'claude: command not found'))
    Assert 'an older release is below the requirement' ((Test-ClaudeClientVersionAtLeast -Installed '2.1.101 (Claude Code)' -Required '2.1.219') -eq $false)
    Assert 'a newer release meets the requirement' ((Test-ClaudeClientVersionAtLeast -Installed '2.1.272' -Required '2.1.219') -eq $true)
    Assert 'an unreadable version is unknown, not old' ($null -eq (Test-ClaudeClientVersionAtLeast -Installed 'n/a' -Required '2.1.219'))

    # One verdict per pinned alias, on what each release was measured to send (request capture,
    # 2026-09-27): the cases below are also run through alias_check_ in bash further down.
    $aliasRecordJson = '{"deployments":[{"name":"claude-opus-5","model":"claude-opus-5"},{"name":"prod-big","model":"claude-opus-5"},{"name":"claude-haiku-4-5","model":"claude-haiku-4-5"},{"name":"claude-opus-6","model":"claude-opus-6"},{"name":"prod-plain","model":"claude-opus-5","capabilities":"none"},{"name":"prod-next","model":"claude-next-1","capabilities":"effort,thinking","claudeCode":"2.2.10"}]}'
    $aliasDeployments = @(Get-ClaudeRecordedDeployment -Config ($aliasRecordJson | ConvertFrom-Json))
    $aliasByName = @{}; foreach ($d in $aliasDeployments) { $aliasByName[$d.name] = $d }
    $aliasCases = @(
        [pscustomobject]@{ Label = 'the declaration in another order'; Pinned = 'claude-opus-5'; Declared = 'interleaved_thinking,adaptive_thinking,thinking,max_effort,xhigh_effort,effort'; Installed = '2.1.101'; Expect = 'ok'; Match = '^$' }
        [pscustomobject]@{ Label = 'thinking without adaptive on an old release'; Pinned = 'claude-opus-5'; Declared = 'thinking'; Installed = '2.1.101'; Expect = 'fail'; Match = 'sends thinking\.type\.enabled, which the model refuses with 400' }
        [pscustomobject]@{ Label = 'thinking without adaptive on a release that knows the model'; Pinned = 'claude-opus-5'; Declared = 'thinking'; Installed = '2.1.272'; Expect = 'warn'; Match = 'retries with adaptive thinking' }
        [pscustomobject]@{ Label = 'a partial declaration'; Pinned = 'claude-opus-5'; Declared = 'effort,adaptive_thinking'; Installed = '2.1.101'; Expect = 'warn'; Match = 'turns off every capability' }
        [pscustomobject]@{ Label = 'no declaration, model id, old release'; Pinned = 'claude-opus-5'; Declared = ''; Installed = '2.1.101'; Expect = 'fail'; Match = 'predates that model \(first known to Claude Code 2\.1\.219\)' }
        [pscustomobject]@{ Label = 'no declaration, custom name, old release'; Pinned = 'prod-big'; Declared = ''; Installed = '2.1.101'; Expect = 'warn'; Match = 'prod-big \(claude-opus-5\).*depends on the release' }
        [pscustomobject]@{ Label = 'no declaration, a release that knows the model'; Pinned = 'claude-opus-5'; Declared = ''; Installed = '2.1.272'; Expect = 'ok'; Match = '^$' }
        [pscustomobject]@{ Label = 'no declaration, a model newer than the table'; Pinned = 'claude-opus-6'; Declared = ''; Installed = '2.1.290'; Expect = 'warn'; Match = 'no Claude Code release is recorded' }
        [pscustomobject]@{ Label = 'a declaration for a model that needs none'; Pinned = 'claude-haiku-4-5'; Declared = 'effort,thinking'; Installed = '2.1.101'; Expect = 'warn'; Match = 'which the record does not declare' }
        [pscustomobject]@{ Label = 'no declaration for a model that needs none'; Pinned = 'claude-haiku-4-5'; Declared = ''; Installed = '2.1.101'; Expect = 'ok'; Match = '^$' }
        [pscustomobject]@{ Label = 'an unrecorded unknown name'; Pinned = 'mystery'; Declared = 'effort'; Installed = '2.1.101'; Expect = 'ok'; Match = '^$' }
        [pscustomobject]@{ Label = 'a declaration where the record says none'; Pinned = 'prod-plain'; Declared = 'effort'; Installed = '2.1.101'; Expect = 'warn'; Match = 'prod-plain, which the record does not declare' }
        [pscustomobject]@{ Label = 'an override model, not declared, below its release'; Pinned = 'prod-next'; Declared = ''; Installed = '2.2.9'; Expect = 'warn'; Match = 'prod-next \(claude-next-1\).*2\.2\.10.*depends on the release' }
        [pscustomobject]@{ Label = 'an override model declared as the record says'; Pinned = 'prod-next'; Declared = 'effort,thinking'; Installed = '2.1.101'; Expect = 'ok'; Match = '^$' }
        [pscustomobject]@{ Label = 'thinking without adaptive, release unreadable'; Pinned = 'claude-opus-5'; Declared = 'thinking'; Installed = ''; Expect = 'fail'; Match = 'Claude Code of unknown version sends' }
    )
    $aliasVerdicts = @(foreach ($c in $aliasCases) {
        $recorded = $aliasByName.ContainsKey($c.Pinned)
        $known = if ($recorded) { Get-ClaudeDeploymentClientSupport $aliasByName[$c.Pinned] } else { Get-ClaudeModelClientSupport -Model $c.Pinned }
        Get-ClaudeCodeAliasCheck -Variable 'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES' -PinnedName $c.Pinned -Declared $c.Declared -Known $known -Recorded:$recorded -Installed $c.Installed
    })
    for ($i = 0; $i -lt $aliasCases.Count; $i++) {
        Assert "alias check: $($aliasCases[$i].Label) is $($aliasCases[$i].Expect)" ($aliasVerdicts[$i].Status -eq $aliasCases[$i].Expect -and $aliasVerdicts[$i].Text -match $aliasCases[$i].Match) "$($aliasVerdicts[$i].Status): $($aliasVerdicts[$i].Text)"
    }

    # npm's layout: claude.ps1, claude.cmd and an extensionless POSIX script in one folder.
    # PowerShell 7's Group-Object sorted the extensionless one first, and Windows cannot start it.
    $installScratch = Join-Path ([IO.Path]::GetTempPath()) "ws-install-$PID-$(Get-Random)"
    $npmDir = Join-Path $installScratch 'npm'; $nativeDir = Join-Path $installScratch 'native'; $posixDir = Join-Path $installScratch 'posix-only'
    New-Item -ItemType Directory -Force -Path $npmDir, $nativeDir, $posixDir | Out-Null
    $savedPath = $env:PATH
    try {
        Set-Content -LiteralPath (Join-Path $npmDir 'claude') -Encoding ASCII -Value "#!/bin/sh`nexec node `"`$basedir/node_modules/@anthropic-ai/claude-code/cli.js`" `"`$@`""
        Set-Content -LiteralPath (Join-Path $posixDir 'claude') -Encoding ASCII -Value "#!/bin/sh`nexec node `"`$basedir/cli.js`" `"`$@`""
        Set-Content -LiteralPath (Join-Path $npmDir 'claude.cmd') -Encoding ASCII -Value "@echo off`r`necho 2.1.101 (Claude Code)"
        Set-Content -LiteralPath (Join-Path $npmDir 'claude.ps1') -Encoding ASCII -Value "'2.1.101 (Claude Code)'"
        Set-Content -LiteralPath (Join-Path $nativeDir 'claude.cmd') -Encoding ASCII -Value "@echo off`r`necho 2.1.272 (Claude Code)"
        if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
            $env:PATH = $posixDir + [IO.Path]::PathSeparator + $npmDir + [IO.Path]::PathSeparator + $nativeDir
            $installs = @(Get-ClaudeCodeInstall)
            Assert 'one install per folder, in PATH order' ($installs.Count -eq 2 -and $installs[0].Source -like "$npmDir*" -and $installs[1].Source -like "$nativeDir*") (($installs | ForEach-Object Source) -join ', ')
            Assert 'a folder with only a POSIX script is not an install on Windows' (-not @($installs | Where-Object { $_.Source -like "$posixDir*" }).Count) (($installs | ForEach-Object Source) -join ', ')
            Assert 'the Windows shim is chosen, never npm''s POSIX script' ($installs.Count -and [IO.Path]::GetFileName($installs[0].Source) -eq 'claude.cmd') (($installs | ForEach-Object Source) -join ', ')
            $ran = Invoke-ClaudeClientCommand -Path $installs[0].Source -Arguments @('--version') -TimeoutSeconds 30
            Assert 'the chosen install answers' ($ran.StartFailed -eq $false -and $ran.Output -match '2\.1\.101') $ran.Output
            $threw = $false
            try { $bad = Invoke-ClaudeClientCommand -Path (Join-Path $npmDir 'claude') -Arguments @('--version') -TimeoutSeconds 10 } catch { $threw = $true }
            Assert 'a file Windows cannot start is a result, not an exception' (-not $threw -and $bad.StartFailed -and $bad.Output -match 'could not start') $(if ($threw) { 'threw' } else { $bad.Output })
        }
    }
    finally {
        $env:PATH = $savedPath
        Remove-Item -LiteralPath $installScratch -Recurse -Force -ErrorAction SilentlyContinue
    }

    # The deployment name is arbitrary; the model decides.
    $custom = @(
        [pscustomobject]@{ name = 'prod-big'; model = 'claude-opus-5'; version = '2' }
        [pscustomobject]@{ name = 'prod-fast'; model = 'claude-sonnet-5'; version = '2' }
    )
    $envCustom = Get-ClaudeCodeModelEnvironment -Deployments $custom
    Assert 'Opus is pinned to its deployment name' ($envCustom['ANTHROPIC_DEFAULT_OPUS_MODEL'] -eq 'prod-big')
    Assert 'Sonnet is pinned to its deployment name' ($envCustom['ANTHROPIC_DEFAULT_SONNET_MODEL'] -eq 'prod-fast')
    Assert 'Haiku falls back to the Sonnet deployment' ($envCustom['ANTHROPIC_DEFAULT_HAIKU_MODEL'] -eq 'prod-fast')
    Assert 'capabilities are declared for each pinned alias' (
        $envCustom['ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES'] -eq $allCaps -and
        $envCustom['ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES'] -eq $allCaps -and
        $envCustom['ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES'] -eq $allCaps)

    $unknown = Get-ClaudeCodeModelEnvironment -Deployments @([pscustomobject]@{ name = 'claude-sonnet-4-6'; model = 'claude-sonnet-4-6' })
    Assert 'an unknown model is pinned without a declaration' ($unknown['ANTHROPIC_DEFAULT_SONNET_MODEL'] -eq 'claude-sonnet-4-6' -and -not $unknown.Contains('ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES'))

    $required = Get-ClaudeCodeRequiredVersion -Deployments $custom
    Assert 'the required release is the newest any recorded model needs' ($required.Version -eq '2.1.219' -and $required.Model -eq 'claude-opus-5')
    Assert 'no known model means no requirement' ($null -eq (Get-ClaudeCodeRequiredVersion -Deployments @([pscustomobject]@{ name = 'x'; model = 'claude-sonnet-4-6' })))

    # Future models: the rule covers what the release table does not list yet.
    $future = Get-ClaudeModelClientSupport -Model 'claude-opus-6'
    Assert 'a model newer than this file is declared by its family' ($future.Capabilities -eq $allCaps -and $future.Family -eq 'opus')
    Assert 'a model newer than this file sets no Claude Code release' ($null -eq $future.ClaudeCode)
    Assert 'a future model alone sets no requirement' ($null -eq (Get-ClaudeCodeRequiredVersion -Deployments @([pscustomobject]@{ name = 'next'; model = 'claude-sonnet-6' })))
    Assert 'Fable 5.1 is covered with its release' ((Get-ClaudeModelClientSupport -Model 'claude-fable-5-1').ClaudeCode -eq '2.1.257')
    Assert 'Opus 4.7 is the first Opus that needs a declaration' ($null -ne (Get-ClaudeModelClientSupport -Model 'claude-opus-4-7') -and $null -eq (Get-ClaudeModelClientSupport -Model 'claude-opus-4-6'))
    Assert 'Haiku 4.5 is left to Claude Code''s own detection' ($null -eq (Get-ClaudeModelClientSupport -Model 'claude-haiku-4-5'))
    $overridden = Get-ClaudeCodeModelEnvironment -Deployments @([pscustomobject]@{ name = 'prod-new'; model = 'claude-sonnet-7'; capabilities = 'effort,thinking'; claudeCode = '' })
    Assert 'an administrator override in the record wins' ($overridden['ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES'] -eq 'effort,thinking')
    $none = Get-ClaudeCodeModelEnvironment -Deployments @([pscustomobject]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5'; capabilities = 'none'; claudeCode = '' })
    Assert 'an override of none leaves the model to Claude Code' (-not $none.Contains('ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES'))
    $owner = @(
        [pscustomobject]@{ name = 'claude-opus-5'; model = 'claude-opus-5' }
        [pscustomobject]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5' }
        [pscustomobject]@{ name = 'claude-opus-5-5'; model = 'claude-opus-5-5' }
        [pscustomobject]@{ name = 'claude-haiku-4-5'; model = 'claude-haiku-4-5' }
    )
    $ownerEnv = Get-ClaudeCodeModelEnvironment -Deployments $owner
    Assert 'a newly deployed model in a family becomes its alias' ($ownerEnv['ANTHROPIC_DEFAULT_OPUS_MODEL'] -eq 'claude-opus-5-5')
    Assert 'a Haiku deployment takes the Haiku alias and needs no declaration' ($ownerEnv['ANTHROPIC_DEFAULT_HAIKU_MODEL'] -eq 'claude-haiku-4-5' -and -not $ownerEnv.Contains('ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES'))
    Assert 'the owner''s deployments need Claude Code 2.1.280' ((Get-ClaudeCodeRequiredVersion -Deployments $owner).Version -eq '2.1.280')

    $fromRecord = @(Get-ClaudeRecordedDeployment -Config ([pscustomobject]@{ deployments = $custom }))
    Assert 'recorded deployments are read from the record' ($fromRecord.Count -eq 2 -and $fromRecord[0].model -eq 'claude-opus-5')
    $fromNames = @(Get-ClaudeRecordedDeployment -Config ([pscustomobject]@{ models = @('claude-sonnet-5', 'claude-opus-5') }))
    Assert 'an older record with model names still yields deployments' ($fromNames.Count -eq 2 -and $fromNames[1].model -eq 'claude-opus-5')
    $fromParam = @(Get-ClaudeRecordedDeployment -Config ([pscustomobject]@{}) -Names @('claude-sonnet-5'))
    Assert 'names passed on the command line are the last fallback' ($fromParam.Count -eq 1 -and $fromParam[0].name -eq 'claude-sonnet-5')

    $existing = [pscustomobject]@{
        env = [pscustomobject]@{ HTTPS_PROXY = 'http://proxy.contoso.example:8080'; ANTHROPIC_FOUNDRY_RESOURCE = 'old-resource'; ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = 'effort' }
        model = 'sonnet'
    }
    $updated = Set-ClaudeCodeGatewaySettings -Settings $existing -GatewayUrl 'https://gw.contoso.example/claude' -Deployments @([pscustomobject]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5' })
    Assert 'gateway settings select Foundry through the gateway' ($updated.env.CLAUDE_CODE_USE_FOUNDRY -eq '1' -and $updated.env.ANTHROPIC_FOUNDRY_BASE_URL -eq 'https://gw.contoso.example/claude')
    Assert 'gateway settings keep unrelated environment variables' ($updated.env.HTTPS_PROXY -eq 'http://proxy.contoso.example:8080')
    Assert 'gateway settings remove the conflicting resource' (-not ($updated.env.PSObject.Properties.Name -contains 'ANTHROPIC_FOUNDRY_RESOURCE'))
    Assert 'gateway settings remove a declaration for an alias no longer pinned' (-not ($updated.env.PSObject.Properties.Name -contains 'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES'))
    Assert 'gateway settings declare the pinned Sonnet capabilities' ($updated.env.ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES -eq $allCaps)
    Assert 'gateway settings keep unrelated settings' ($updated.model -eq 'sonnet' -and $updated.enforceAvailableModels -eq $true -and @($updated.availableModels) -contains 'claude-sonnet-5')

    $ws = Get-Content -LiteralPath (Join-Path $root 'scripts\Setup-ClaudeWorkstation.ps1') -Raw
    Assert 'the Windows workstation setup writes settings through the shared function' ($ws -match 'Set-ClaudeCodeGatewaySettings' -and $ws -match 'ClaudeClientSupport\.ps1')
    Assert 'the Windows workstation setup compares the CLI with the required release' ($ws -match 'Get-ClaudeCodeRequiredVersion' -and $ws -match 'claude update')
    Assert 'the Windows workstation setup proves Claude Code itself answers' ($ws -match "@\('-p', 'ping', '--model', \`$probeModel\)")
    Assert 'the Windows workstation setup renders Desktop keys for the build that reads them' ($ws -match 'Get-ClaudeDesktopReadingVersion' -and $ws -match '-DesktopVersion \$desktopReads')
    $install = [pscustomobject]@{ Version = '2.9939.2'; RunningVersion = '1.44121.2' }
    Assert 'an older running build is the one a profile is written for' ((Get-ClaudeDesktopReadingVersion -Install $install) -eq '1.44121.2')
    Assert 'with nothing running the installed build is used' ((Get-ClaudeDesktopReadingVersion -Install ([pscustomobject]@{ Version = '2.9939.2'; RunningVersion = '' })) -eq '2.9939.2')
    Assert 'an unknown version is empty' ((Get-ClaudeDesktopReadingVersion -Install ([pscustomobject]@{ Version = ''; RunningVersion = '' })) -eq '')
    $sh = Get-Content -LiteralPath (Join-Path $root 'scripts\setup-claude-workstation.sh') -Raw
    Assert 'the macOS/Linux workstation setup declares model capabilities' ($sh -match '_MODEL_SUPPORTED_CAPABILITIES' -and $sh -match 'claude-client-support\.sh' -and (Get-Content -LiteralPath (Join-Path $root 'scripts\claude-client-support.sh') -Raw) -match 'adaptive_thinking')
    $gen = Get-Content -LiteralPath (Join-Path $root 'scripts\New-ClaudeCodePolicy.ps1') -Raw
    Assert 'the MDM profile uses the shared model table' ($gen -match 'Get-ClaudeModelClientSupport' -and $gen -match 'Get-ClaudeCodePinnedModel')
    $mdmScratch = Join-Path ([IO.Path]::GetTempPath()) ('mdm-models-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $mdmScratch | Out-Null
    try {
        $mdmConfig = Join-Path $mdmScratch 'claude-gateway.json'
        @{ gatewayUrl = 'https://gw.contoso.example/claude'; deployments = @(@{ name = 'prod-big'; model = 'claude-opus-5'; version = '2' }, @{ name = 'prod-fast'; model = 'claude-sonnet-5'; version = '2' }); desktopSignIn = @{ kind = 'helper-script' } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mdmConfig -Encoding UTF8
        $mdmOut = Join-Path $mdmScratch 'out'
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\New-ClaudeCodePolicy.ps1') -ConfigPath $mdmConfig -Tier premium -OutputPath $mdmOut *> $null
        $mdmEnv = (Get-Content -LiteralPath (Join-Path $mdmOut 'claude-code.managed-settings.json') -Raw | ConvertFrom-Json).env
        Assert 'the MDM profile pins aliases by model to custom deployment names' ($mdmEnv.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'prod-big' -and $mdmEnv.ANTHROPIC_DEFAULT_SONNET_MODEL -eq 'prod-fast' -and $mdmEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'prod-fast')
        Assert 'the MDM profile declares each pinned model''s capabilities' ($mdmEnv.ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES -eq $allCaps -and $mdmEnv.ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES -eq $allCaps -and $mdmEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES -eq $allCaps)
        $generator = Join-Path $root 'scripts\New-ClaudeCodePolicy.ps1'
        function Get-MdmEnv([string]$Config, [string]$Name, [string[]]$Extra = @()) {
            $out = Join-Path $mdmScratch $Name
            & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $generator -ConfigPath $Config -Tier premium -OutputPath $out @Extra *> $null
            $file = Join-Path $out 'claude-code.managed-settings.json'
            if (Test-Path -LiteralPath $file) { (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).env } else { $null }
        }
        # One recorded deployment. Assigning an if statement unrolled it, and on Windows PowerShell
        # 5.1 a single object has no Count, so the default names were pinned instead.
        $oneConfig = Join-Path $mdmScratch 'one.json'
        Set-Content -LiteralPath $oneConfig -Encoding UTF8 -Value '{ "gatewayUrl": "https://gw.contoso.example/claude", "deployments": [ { "name": "prod-fast", "model": "claude-sonnet-5", "version": "2" } ], "desktopSignIn": { "kind": "helper-script" } }'
        $oneEnv = Get-MdmEnv $oneConfig 'one'
        Assert 'the MDM profile pins a record with one deployment' ($oneEnv -and $oneEnv.ANTHROPIC_DEFAULT_SONNET_MODEL -eq 'prod-fast' -and $oneEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'prod-fast' -and $oneEnv.ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES -eq $allCaps) ($oneEnv | ConvertTo-Json -Compress)
        # With no Haiku deployment recorded, the haiku alias follows the Sonnet choice, including
        # one the administrator passed.
        $overEnv = Get-MdmEnv $mdmConfig 'over' @('-SonnetModel', 'prod-stable')
        Assert 'with no Haiku deployment the haiku alias follows an explicit -SonnetModel' ($overEnv -and $overEnv.ANTHROPIC_DEFAULT_SONNET_MODEL -eq 'prod-stable' -and $overEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'prod-stable') ($overEnv | ConvertTo-Json -Compress)
        $haikuConfig = Join-Path $mdmScratch 'haiku.json'
        Set-Content -LiteralPath $haikuConfig -Encoding UTF8 -Value '{ "gatewayUrl": "https://gw.contoso.example/claude", "deployments": [ { "name": "prod-big", "model": "claude-opus-5" }, { "name": "prod-fast", "model": "claude-sonnet-5" }, { "name": "prod-small", "model": "claude-haiku-4-5" } ], "desktopSignIn": { "kind": "helper-script" } }'
        $haikuEnv = Get-MdmEnv $haikuConfig 'haiku' @('-SonnetModel', 'prod-fast')
        Assert 'a recorded Haiku deployment keeps the haiku alias, with no declaration' ($haikuEnv -and $haikuEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'prod-small' -and -not $haikuEnv.PSObject.Properties['ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES']) ($haikuEnv | ConvertTo-Json -Compress)
    }
    finally { Remove-Item -LiteralPath $mdmScratch -Recurse -Force -ErrorAction SilentlyContinue }
    $installer = Get-Content -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
    Assert 'the installer records each deployment with its model' ($installer -match 'deployments\s*=' -and $installer -match 'model\s*=\s*\$_\.model')
}

Write-Host ''
Write-Host 'P67 Claude Desktop keys against the installed release' -ForegroundColor Cyan
. $desktopHelper
$helperChoice = Get-ClaudeDesktopSignIn -Config ([pscustomobject]@{ desktopSignIn = [pscustomobject]@{ kind = 'helper-script' } })
$browserChoice = Get-ClaudeDesktopSignIn -Config ([pscustomobject]@{ desktopSignIn = [pscustomobject]@{ kind = 'external-idp'; flow = 'browser'; bearerTokenType = 'id_token'; clientId = '11111111-1111-1111-1111-111111111111'; issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0' } })
$brokerChoice = Get-ClaudeDesktopSignIn -Config ([pscustomobject]@{ desktopSignIn = [pscustomobject]@{ kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'access_token'; clientId = '11111111-1111-1111-1111-111111111111'; issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0'; scopes = 'api://gateway-claude/user_impersonation'; audience = 'api://gateway-claude' } })
foreach ($case in @(@{ Name = 'helper-script'; Choice = $helperChoice }, @{ Name = 'Entra browser'; Choice = $browserChoice }, @{ Name = 'Entra broker'; Choice = $brokerChoice })) {
    $rendered = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.contoso.example/claude' -Models @('claude-sonnet-5') -HelperPath 'C:\h\get-foundry-token.cmd' -DesktopSignIn $case.Choice
    $unknownKeys = @($rendered.Keys | Where-Object { $schema.flatKeys -notcontains $_ })
    Assert "$($case.Name): every key is one Desktop $($schema.desktopVersion) reads" ($unknownKeys.Count -eq 0) ($unknownKeys -join ', ')
    Assert "$($case.Name): the credential kind is one Desktop $($schema.desktopVersion) reads" ($schema.credentialKinds -contains $rendered.inferenceCredentialKind) $rendered.inferenceCredentialKind
}
$browserRendered = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.contoso.example/claude' -Models @('claude-sonnet-5') -DesktopSignIn $browserChoice
$brokerRendered = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.contoso.example/claude' -Models @('claude-sonnet-5') -DesktopSignIn $brokerChoice
Assert 'Entra sign-in uses the interactive kind' ($browserRendered.inferenceCredentialKind -eq 'interactive')
Assert 'Entra sign-in writes the identity provider under inferenceGatewayOidc' ($browserRendered.inferenceGatewayOidc.clientId -eq '11111111-1111-1111-1111-111111111111' -and $browserRendered.inferenceGatewayOidc.issuer -match '/v2\.0$')
Assert 'the browser flow is the default and writes no flow key' (-not $browserRendered.Contains('inferenceGatewayOidcAuthFlow'))
Assert 'the broker flow is written under inferenceGatewayOidcAuthFlow' ($brokerRendered.inferenceGatewayOidcAuthFlow -eq 'broker' -and $brokerRendered.inferenceGatewayOidc.scopes -eq 'api://gateway-claude/user_impersonation')
Assert 'nothing needs Desktop 2.7032.0' (-not ($browserRendered.Contains('inferenceIdpOidc') -or $brokerRendered.Contains('inferenceIdpAuthFlow')))
Assert 'helper sign-in needs Desktop 1.10628.0, for silent refresh' ((Get-ClaudeDesktopRequiredVersion -Settings (New-ClaudeDesktopSettings -GatewayUrl 'https://g/claude' -Models @('m') -HelperPath 'C:\h.cmd' -DesktopSignIn $helperChoice)) -eq '1.10628.0')
Assert 'browser sign-in needs Desktop 1.8555.0' ((Get-ClaudeDesktopRequiredVersion -Settings $browserRendered) -eq '1.8555.0')
Assert 'broker sign-in needs Desktop 1.25927.0' ((Get-ClaudeDesktopRequiredVersion -Settings $brokerRendered) -eq '1.25927.0')
Assert 'the Windows helper path key needs Desktop 2.2553.0' ((Get-ClaudeDesktopRequiredVersion -Settings @{ inferenceCredentialKind = 'helper-script'; inferenceCredentialHelperWindows = 'C:\h.cmd' }) -eq '2.2553.0')
Assert 'external-idp is refused on a release before 2.7032.0' ((Test-ClaudeDesktopCredentialKindSupported -Kind 'external-idp' -Version '2.2553.1.0') -eq $false)
Assert 'external-idp is read from 2.7032.0' ((Test-ClaudeDesktopCredentialKindSupported -Kind 'external-idp' -Version '2.7032.0') -eq $true)
Assert 'interactive is read on the installed release' ((Test-ClaudeDesktopCredentialKindSupported -Kind 'interactive' -Version $schema.desktopVersion) -eq $true)
# Written for the build that reads it: the owner's workstation ran 1.44121.2 with 2.9939.2 installed.
$forNew = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.contoso.example/claude' -Models @('claude-sonnet-5') -DesktopSignIn $brokerChoice -DesktopVersion '2.9939.2'
Assert 'a Desktop that reads the current spelling gets it' ($forNew.inferenceCredentialKind -eq 'external-idp' -and $forNew.inferenceIdpOidc.clientId -and $forNew.inferenceIdpAuthFlow -eq 'broker' -and -not $forNew.Contains('inferenceGatewayOidc'))
$forOld = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.contoso.example/claude' -Models @('claude-sonnet-5') -DesktopSignIn $brokerChoice -DesktopVersion '1.44121.2'
Assert 'the owner''s stale 1.44121.2 build gets the spelling it reads' ($forOld.inferenceCredentialKind -eq 'interactive' -and $forOld.inferenceGatewayOidcAuthFlow -eq 'broker' -and -not $forOld.Contains('inferenceIdpOidc'))
Assert 'the current-spelling profile needs 2.7032.0' ((Get-ClaudeDesktopRequiredVersion -Settings $forNew) -eq '2.7032.0')
$forced = New-ClaudeDesktopSettings -GatewayUrl 'https://gw.contoso.example/claude' -Models @('claude-sonnet-5') -DesktopSignIn $browserChoice -KeySpelling current
Assert 'an administrator can force the current spelling' ($forced.inferenceCredentialKind -eq 'external-idp' -and -not $forced.Contains('inferenceIdpAuthFlow'))

# New-ClaudeCodePolicy.ps1 is sometimes copied without its helpers; its fallback renderer must match.
$lone = Join-Path ([IO.Path]::GetTempPath()) ('policy-alone-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $lone | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $root 'scripts\New-ClaudeCodePolicy.ps1') -Destination $lone
    $cfgPath = Join-Path $lone 'claude-gateway.json'
    @{ gatewayUrl = 'https://gw.contoso.example/claude'; models = @('claude-sonnet-5'); desktopSignIn = @{ kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'id_token'; clientId = '11111111-1111-1111-1111-111111111111'; issuer = 'https://login.microsoftonline.com/22222222-2222-2222-2222-222222222222/v2.0' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    $outDir = Join-Path $lone 'out'
    # A separate process: in this one the shared functions are already loaded and would hide the fallback.
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $lone 'New-ClaudeCodePolicy.ps1') -ConfigPath $cfgPath -OutputPath $outDir *> $null
    $desktopJson = Get-Content -LiteralPath (Join-Path $outDir 'claude-desktop.managed-settings.json') -Raw | ConvertFrom-Json
    Assert 'the policy generator alone renders the interactive kind' ($desktopJson.inferenceCredentialKind -eq 'interactive' -and $desktopJson.inferenceGatewayOidcAuthFlow -eq 'broker' -and $desktopJson.inferenceGatewayOidc.clientId)
    Assert 'the policy generator alone writes no key Desktop 2.2553.1.0 ignores' (@($desktopJson.PSObject.Properties.Name | Where-Object { $schema.flatKeys -notcontains $_ }).Count -eq 0)
    $outCurrent = Join-Path $lone 'out-current'
    & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $lone 'New-ClaudeCodePolicy.ps1') -ConfigPath $cfgPath -OutputPath $outCurrent -DesktopKeySpelling current *> $null
    $currentJson = Get-Content -LiteralPath (Join-Path $outCurrent 'claude-desktop.managed-settings.json') -Raw | ConvertFrom-Json
    Assert 'a fleet on 2.7032.0 can be given the current spelling' ($currentJson.inferenceCredentialKind -eq 'external-idp' -and $currentJson.inferenceIdpAuthFlow -eq 'broker' -and $currentJson.inferenceIdpOidc.clientId)
}
finally { Remove-Item -LiteralPath $lone -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'P67 workstation diagnostics' -ForegroundColor Cyan
# Separate processes with stubbed az, claude and code, so nothing here reaches Azure or a real client.
$diagScratch = Join-Path ([IO.Path]::GetTempPath()) ('ws-diag-' + [guid]::NewGuid().ToString('N'))
$stubs = Join-Path $diagScratch 'bin'
$homeDir = Join-Path $diagScratch 'home'
$localApp = Join-Path $homeDir 'AppData\Local'
New-Item -ItemType Directory -Force -Path $stubs, (Join-Path $homeDir '.claude'), (Join-Path $homeDir 'AppData\Roaming\Code\User'), (Join-Path $localApp 'Claude-3p\configLibrary'), (Join-Path $localApp 'Claude-3p\logs') | Out-Null
$savedEnv = @{}
foreach ($name in 'PATH', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'CLAUDE_DIAGNOSE_HOME', 'CLAUDE_DIAGNOSE_FORCE_NO_REQUEST', 'CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS', 'CLAUDE_CLIENT_DESKTOP_VERSION', 'CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION', 'CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT', 'STUB_CLAUDE_VERSION') { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    Set-Content -LiteralPath (Join-Path $stubs 'az.cmd') -Encoding ASCII -Value @'
@echo off
if "%1"=="account" if "%2"=="show" (
  echo {"tenantId":"11111111-1111-1111-1111-111111111111","user":{"name":"dev@example.com","type":"user"}}
  exit /b 0
)
if "%1"=="account" if "%2"=="get-access-token" (
  echo {"accessToken":"stub-token-value","expiresOn":"2099-12-31 00:00:00.000000"}
  exit /b 0
)
echo {}
exit /b 0
'@
    # The owner's Claude Code 2.1.101: doctor prints box-drawing rules and warnings, then waits.
    Set-Content -LiteralPath (Join-Path $stubs 'claude-stub.ps1') -Encoding ASCII -Value @'
# $args, not a param block: Windows PowerShell would read --version as a parameter name.
$Verb = [string]$args[0]
$out = [Console]::OpenStandardOutput()
function Say([string]$text) { $b = [Text.Encoding]::UTF8.GetBytes($text + "`n"); $out.Write($b, 0, $b.Length); $out.Flush() }
if ($Verb -eq '--version') { Say ('{0} (Claude Code)' -f $(if ($env:STUB_CLAUDE_VERSION) { $env:STUB_CLAUDE_VERSION } else { '2.1.101' })); exit 0 }
if ($Verb -eq 'doctor') {
    Say ([string][char]0x2500 * 40)
    Say ' Diagnostics'
    Say (' ' + [char]0x2514 + ' Currently running: native (2.1.101)')
    Say ' Warning: Leftover npm global installation at C:\Users\dev\AppData\Roaming\npm\claude'
    Say (' Press Enter to continue' + [char]0x2026)
    Start-Sleep -Seconds 600
    exit 0
}
Say 'OK'
'@
    Set-Content -LiteralPath (Join-Path $stubs 'claude.cmd') -Encoding ASCII -Value "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0claude-stub.ps1`" %*"
    # npm also writes claude.ps1 and an extensionless POSIX script beside claude.cmd.
    Set-Content -LiteralPath (Join-Path $stubs 'claude') -Encoding ASCII -Value "#!/bin/sh`nexec node `"`$basedir/node_modules/@anthropic-ai/claude-code/cli.js`" `"`$@`""
    Set-Content -LiteralPath (Join-Path $stubs 'claude.ps1') -Encoding ASCII -Value "& (Join-Path `$PSScriptRoot 'claude-stub.ps1') @args"
    Set-Content -LiteralPath (Join-Path $stubs 'code.cmd') -Encoding ASCII -Value "@echo off`r`nif `"%1`"==`"--version`" (echo 1.139.1& exit /b 0)`r`nif `"%1`"==`"--list-extensions`" (echo anthropic.claude-code& exit /b 0)`r`nexit /b 0"

    $record = Join-Path $diagScratch 'claude-gateway.json'
    @{ gatewayUrl = 'https://apim-test.azure-api.net/claude'; tenantId = '11111111-1111-1111-1111-111111111111'; deployments = @(@{ name = 'claude-opus-5'; model = 'claude-opus-5' }, @{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $record -Encoding UTF8
    $settingsPath = Join-Path $homeDir '.claude\settings.json'
    @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus-5'; ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    # The profile the owner's Desktop could not read: the new spelling on a release before 2.7032.0.
    $library = Join-Path $localApp 'Claude-3p\configLibrary'
    @{ appliedId = 'aaaaaaaa-0000-0000-0000-000000000001'; entries = @(@{ id = 'aaaaaaaa-0000-0000-0000-000000000001'; name = 'Default' }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $library '_meta.json') -Encoding UTF8
    @{ inferenceProvider = 'gateway'; inferenceGatewayBaseUrl = 'https://apim-test.azure-api.net/claude'; inferenceCredentialKind = 'external-idp'; inferenceIdpAuthFlow = 'browser'; inferenceIdpOidc = @{ issuer = 'https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0'; clientId = '22222222-2222-2222-2222-222222222222'; bearerTokenType = 'id_token' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $library 'aaaaaaaa-0000-0000-0000-000000000001.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $localApp 'Claude-3p\logs\main.log') -Encoding UTF8 -Value @(
        '2026-09-27 10:00:00 [info] [custom-3p] Credentials loaded from managed config { provider: ''gateway'' }'
        '2026-09-27 10:00:05 [error] [custom-3p] inference request failed: getaddrinfo ENOTFOUND claude.contoso.example'
    )

    $env:PATH = $stubs + [IO.Path]::PathSeparator + $savedEnv['PATH']
    $env:USERPROFILE = $homeDir
    $env:APPDATA = Join-Path $homeDir 'AppData\Roaming'
    $env:LOCALAPPDATA = $localApp
    $env:CLAUDE_DIAGNOSE_HOME = $homeDir
    $env:CLAUDE_DIAGNOSE_FORCE_NO_REQUEST = '1'
    $env:CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS = '5'
    $env:CLAUDE_CLIENT_DESKTOP_VERSION = '2.2553.1.0'
    Remove-Item Env:\CLAUDE_DIAGNOSE_WINDOWS_POLICY_ROOT -ErrorAction SilentlyContinue
    $diagScript = Join-Path $root 'scripts\Debug-ClaudeWorkstation.ps1'
    $hostExe = (Get-Process -Id $PID).Path
    function Invoke-WorkstationDiag([string]$RecordFile) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $text = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $diagScript -RecordPath $RecordFile -NoRequest *>&1 | Out-String
        [pscustomobject]@{ Text = $text; Seconds = $sw.Elapsed.TotalSeconds }
    }
    function Get-CheckBlock([string]$Text, [string]$Name) {
        $m = [regex]::Match($Text, '(?ms)^\s*(PASS|WARN|FAIL|SKIP) ' + [regex]::Escape($Name) + '\s*$.*?(?=^\s*(PASS|WARN|FAIL|SKIP) |\z)')
        if ($m.Success) { $m.Value } else { '' }
    }

    $first = Invoke-WorkstationDiag $record
    Assert 'diagnostics finish although claude doctor waits for a key press' ($first.Seconds -lt 90) ("{0:n0} s" -f $first.Seconds)
    $installed = Get-CheckBlock $first.Text 'Claude Code installed'
    Assert 'diagnostics run the Windows shim beside npm''s POSIX script' ($installed -match '^\s*PASS' -and $installed -match '2\.1\.101' -and $installed -match 'claude\.cmd') $installed
    $doctor = Get-CheckBlock $first.Text 'claude doctor'
    Assert 'a doctor that does not finish is reported, not waited for' ($doctor -match '^\s*WARN' -and $doctor -match 'did not finish within 5 s') $doctor
    Assert 'doctor warnings are shown as readable text' ($doctor -match 'Leftover npm global installation')
    Assert 'no output is read in the wrong code page' ($first.Text -notmatch [regex]::Escape(([string][char]0x0393) + [char]0x00F6))
    $cli = Get-CheckBlock $first.Text 'Claude Code and the recorded models'
    Assert 'an old Claude Code without declarations fails with the model and release' ($cli -match '^\s*FAIL' -and $cli -match '2\.1\.101' -and $cli -match 'claude-opus-5' -and $cli -match '2\.1\.219') $cli
    $desktop = Get-CheckBlock $first.Text 'Claude Desktop sign-in configuration'
    Assert 'an external-idp profile on Desktop 2.2553.1.0 fails with the release it needs' ($desktop -match '^\s*FAIL' -and $desktop -match 'external-idp' -and $desktop -match '2\.7032\.0' -and $desktop -match '2\.2553\.1\.0') $desktop
    $log = Get-CheckBlock $first.Text 'Claude Desktop recent errors'
    Assert 'Desktop''s own log errors are shown' ($log -match '^\s*WARN' -and $log -match 'ENOTFOUND claude\.contoso\.example') $log
    # The time limit is proven above; the later runs do not need to wait 5 s for the stub each time.
    $env:CLAUDE_DIAGNOSE_DOCTOR_TIMEOUT_SECONDS = '1'

    # After the setup script: declarations present and the compatible Desktop spelling.
    @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus-5'; ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5'; ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = $allCaps; ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES = $allCaps } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    @{ inferenceProvider = 'gateway'; inferenceGatewayBaseUrl = 'https://apim-test.azure-api.net/claude'; inferenceGatewayAuthScheme = 'bearer'; inferenceCredentialKind = 'interactive'; inferenceGatewayOidc = @{ issuer = 'https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0'; clientId = '22222222-2222-2222-2222-222222222222'; bearerTokenType = 'id_token' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $library 'aaaaaaaa-0000-0000-0000-000000000001.json') -Encoding UTF8
    $second = Invoke-WorkstationDiag $record
    $cli2 = Get-CheckBlock $second.Text 'Claude Code and the recorded models'
    Assert 'with declarations an old Claude Code is a warning to update' ($cli2 -match '^\s*WARN' -and $cli2 -match 'claude update') $cli2
    $desktop2 = Get-CheckBlock $second.Text 'Claude Desktop sign-in configuration'
    Assert 'the interactive spelling passes on Desktop 2.2553.1.0' ($desktop2 -match '^\s*PASS' -and $desktop2 -match 'interactive') $desktop2

    # A record the guided flow wrote before its setup finished.
    $partial = Join-Path $diagScratch 'partial.json'
    @{ schemaVersion = 2; decisions = @{ foundation = @{ sku = 'BasicV2' } }; activeRun = @{ id = 'r1' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $partial -Encoding UTF8
    $third = Invoke-WorkstationDiag $partial
    $recordBlock = Get-CheckBlock $third.Text 'Decision record'
    Assert 'an unfinished record is named as unfinished' ($recordBlock -match '^\s*WARN' -and $recordBlock -match 'no gatewayUrl') $recordBlock
    Assert 'no fix prints an empty tenant' ($third.Text -notmatch '--tenant\s+--' -and $third.Text -notmatch '--tenant\s*$')

    # The owner's workstation: 2.9939.2 installed, 1.44121.2 running, the current spelling on disk.
    @{ inferenceProvider = 'gateway'; inferenceGatewayBaseUrl = 'https://apim-test.azure-api.net/claude'; inferenceCredentialKind = 'external-idp'; inferenceIdpOidc = @{ issuer = 'https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0'; clientId = '22222222-2222-2222-2222-222222222222'; bearerTokenType = 'id_token' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $library 'aaaaaaaa-0000-0000-0000-000000000001.json') -Encoding UTF8
    $env:CLAUDE_CLIENT_DESKTOP_VERSION = '2.9939.2'
    $env:CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION = '1.44121.2'
    $fourth = Invoke-WorkstationDiag $record
    $running = Get-CheckBlock $fourth.Text 'Claude Desktop running build'
    Assert 'an older running build than the installed one is reported' ($running -match '^\s*WARN' -and $running -match '2\.9939\.2' -and $running -match '1\.44121\.2') $running
    $desktop4 = Get-CheckBlock $fourth.Text 'Claude Desktop sign-in configuration'
    Assert 'the running build decides whether the profile is readable' ($desktop4 -match '^\s*FAIL' -and $desktop4 -match '1\.44121\.2' -and $desktop4 -match '2\.7032\.0') $desktop4
    Remove-Item Env:\CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION -ErrorAction SilentlyContinue
    $fifth = Invoke-WorkstationDiag $record
    $desktop5 = Get-CheckBlock $fifth.Text 'Claude Desktop sign-in configuration'
    Assert 'the current spelling passes on the updated build' ($desktop5 -match '^\s*PASS' -and $desktop5 -match 'external-idp') $desktop5

    # A model newer than the release table: only its declaration keeps an older release safe.
    $futureRecord = Join-Path $diagScratch 'future.json'
    @{ gatewayUrl = 'https://apim-test.azure-api.net/claude'; tenantId = '11111111-1111-1111-1111-111111111111'; deployments = @(@{ name = 'claude-opus-6'; model = 'claude-opus-6' }, @{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $futureRecord -Encoding UTF8
    @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus-6'; ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5'; ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES = $allCaps } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $future = Invoke-WorkstationDiag $futureRecord
    $cliFuture = Get-CheckBlock $future.Text 'Claude Code and the recorded models'
    Assert 'a future model pinned without its declaration is reported' ($cliFuture -match '^\s*WARN' -and $cliFuture -match 'claude-opus-6' -and $cliFuture -match 'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES') $cliFuture
    @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus-6'; ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = $allCaps; ANTHROPIC_DEFAULT_SONNET_MODEL = 'claude-sonnet-5'; ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES = $allCaps } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $futureDeclared = Invoke-WorkstationDiag $futureRecord
    $cliFutureDeclared = Get-CheckBlock $futureDeclared.Text 'Claude Code and the recorded models'
    Assert 'once declared, a future model leaves only the update to report' ($cliFutureDeclared -match '^\s*WARN' -and $cliFutureDeclared -match 'claude update' -and $cliFutureDeclared -notmatch 'is not set') $cliFutureDeclared

    # Declarations that differ from the record, judged on what each release was measured to send.
    $declRecord = Join-Path $diagScratch 'declarations.json'
    @{ gatewayUrl = 'https://apim-test.azure-api.net/claude'; tenantId = '11111111-1111-1111-1111-111111111111'; deployments = @(@{ name = 'claude-opus-5'; model = 'claude-opus-5' }, @{ name = 'prod-fast'; model = 'claude-sonnet-5' }, @{ name = 'claude-haiku-4-5'; model = 'claude-haiku-4-5' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $declRecord -Encoding UTF8
    @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus-5'; ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = 'thinking'; ANTHROPIC_DEFAULT_SONNET_MODEL = 'prod-fast'; ANTHROPIC_DEFAULT_HAIKU_MODEL = 'claude-haiku-4-5'; ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES = $allCaps } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $oldDecl = Get-CheckBlock (Invoke-WorkstationDiag $declRecord).Text 'Claude Code and the recorded models'
    Assert 'thinking without adaptive_thinking fails on a release that does not retry' ($oldDecl -match '^\s*FAIL' -and $oldDecl -match 'OPUS_MODEL_SUPPORTED_CAPABILITIES lists thinking without adaptive_thinking') $oldDecl
    Assert 'a custom deployment name without a declaration is a warning, not a failure' ($oldDecl -match 'not set for prod-fast \(claude-sonnet-5\)' -and $oldDecl -match 'depends on the release') $oldDecl
    Assert 'a declaration the record does not expect is reported' ($oldDecl -match 'HAIKU_MODEL_SUPPORTED_CAPABILITIES is set for claude-haiku-4-5, which the record does not declare') $oldDecl
    @{ env = @{ CLAUDE_CODE_USE_FOUNDRY = '1'; ANTHROPIC_FOUNDRY_BASE_URL = 'https://apim-test.azure-api.net/claude'; ANTHROPIC_DEFAULT_OPUS_MODEL = 'claude-opus-5'; ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES = 'thinking'; ANTHROPIC_DEFAULT_SONNET_MODEL = 'prod-fast'; ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES = 'effort,adaptive_thinking'; ANTHROPIC_DEFAULT_HAIKU_MODEL = 'claude-opus-5'; ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES = 'interleaved_thinking,adaptive_thinking,thinking,max_effort,xhigh_effort,effort' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $env:STUB_CLAUDE_VERSION = '2.1.290'
    $newDecl = Get-CheckBlock (Invoke-WorkstationDiag $declRecord).Text 'Claude Code and the recorded models'
    Remove-Item Env:\STUB_CLAUDE_VERSION -ErrorAction SilentlyContinue
    Assert 'a release that knows the model retries after the 400, so it is a warning' ($newDecl -match '^\s*WARN' -and $newDecl -match 'retries with adaptive thinking') $newDecl
    Assert 'a partial declaration is reported with what it turns off' ($newDecl -match "is 'effort,adaptive_thinking' for prod-fast" -and $newDecl -match 'turns off every capability') $newDecl
    Assert 'a declaration in another order is the same declaration' ($newDecl -notmatch 'HAIKU_MODEL_SUPPORTED_CAPABILITIES') $newDecl
}
finally {
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$diagScratch*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $diagScratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'P67 Windows setup, run from only the files the onboarding email fetches' -ForegroundColor Cyan
# The real Setup-ClaudeWorkstation.ps1 against a local listener standing in for the gateway, with
# az, claude and code stubbed and HOME, APPDATA and LOCALAPPDATA in a scratch folder.
if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host '  [SKIP] not Windows; the Windows setup was not run' -ForegroundColor Yellow
}
else {
    $e2e = Join-Path ([IO.Path]::GetTempPath()) "ws-setup-$PID-$(Get-Random)"
    $e2eSaved = @{}
    foreach ($name in 'PATH', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'CLAUDE_CLIENT_DESKTOP_VERSION', 'CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION', 'STUB_LOG') { $e2eSaved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    $listenerJob = $null
    $hostExe = (Get-Process -Id $PID).Path
    # A hard time limit for each script run here: without -UseBasicParsing, Windows PowerShell 5.1
    # in a hidden window hung in Invoke-WebRequest instead of failing, and blocked the suite.
    function Invoke-BoundedScript([string]$Script, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 180) {
        $out = Join-Path $e2e ('run-{0}.out' -f [guid]::NewGuid().ToString('N'))
        $quoted = @(@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
        $p = Start-Process -FilePath $hostExe -ArgumentList $quoted -RedirectStandardOutput $out -RedirectStandardError "$out.err" -WindowStyle Hidden -PassThru
        # Windows PowerShell 5.1 keeps no exit code unless the handle is read while the process runs.
        $null = $p.Handle
        $finished = $p.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null; $null = $p.WaitForExit(5000) }
        $text = [string](Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) + [string](Get-Content -LiteralPath "$out.err" -Raw -ErrorAction SilentlyContinue)
        [pscustomobject]@{ Text = $text; ExitCode = $(if ($finished) { $p.ExitCode } else { $null }); TimedOut = -not $finished }
    }
    try {
        $e2eHome = Join-Path $e2e 'home'; $e2eStubs = Join-Path $e2e 'stubs'; $e2eScripts = Join-Path $e2e 'claude-setup'
        $e2eVs = Join-Path $e2eHome 'AppData\Roaming\Code\User'; $e2eLocal = Join-Path $e2eHome 'AppData\Local'
        New-Item -ItemType Directory -Force -Path $e2eStubs, $e2eScripts, (Join-Path $e2eHome '.claude'), $e2eVs, $e2eLocal | Out-Null

        # The files the email tells a developer to fetch, read from the email it generates.
        $emailConfig = Join-Path $e2e 'email-config.json'
        Set-Content -LiteralPath $emailConfig -Encoding UTF8 -Value '{ "gatewayUrl": "https://gw.contoso.example/claude", "tenantId": "11111111-1111-1111-1111-111111111111", "standardGroup": "claude-code-standard", "tiers": { "standard": { "tokensPerMinute": 20000, "tokensPerDay": 500000 } } }'
        $null = Invoke-BoundedScript (Join-Path $root 'scripts\New-OnboardingEmail.ps1') @('-ConfigPath', $emailConfig, '-To', 'dev@contoso.example', '-DistributionUrl', 'https://share.contoso.example/claude', '-OutputPath', (Join-Path $e2e 'email')) 60
        $emailText = @(Get-ChildItem -LiteralPath (Join-Path $e2e 'email') -Filter '*.txt' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join ''
        $fetchLine = @($emailText -split "`r?`n" | Where-Object { $_ -match 'Invoke-RestMethod' }) | Select-Object -First 1
        $fetched = @([regex]::Matches([string]$fetchLine, "'([A-Za-z0-9._-]+)'") | ForEach-Object { $_.Groups[1].Value })
        $absent = @($fetched | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root "scripts\$_")) })
        Assert 'the email fetches the setup, its helpers and the Desktop token helpers' ((@('Setup-ClaudeWorkstation.ps1', 'ClaudeClientSupport.ps1', 'ClaudeDesktopSignIn.ps1', 'get-foundry-token.ps1', 'get-foundry-token.cmd') | Where-Object { $fetched -notcontains $_ }).Count -eq 0 -and $absent.Count -eq 0) "fetched: $($fetched -join ', ')"
        foreach ($f in $fetched) { Copy-Item -LiteralPath (Join-Path $root "scripts\$f") -Destination $e2eScripts }

        # Only the setup script: it stops at once and names what is missing.
        $alone = Join-Path $e2e 'alone'; New-Item -ItemType Directory -Force -Path $alone | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'scripts\Setup-ClaudeWorkstation.ps1') -Destination $alone
        $aloneRun = Invoke-BoundedScript (Join-Path $alone 'Setup-ClaudeWorkstation.ps1') @('-GatewayUrl', 'https://gw.contoso.example/claude', '-SkipInstall') 60
        $aloneOut = $aloneRun.Text; $aloneCode = $aloneRun.ExitCode
        Assert 'the setup alone stops at once and names its missing helpers' ($aloneCode -eq 1 -and $aloneOut -match 'ClaudeClientSupport\.ps1 and ClaudeDesktopSignIn\.ps1 must be in the same folder') "exit=$aloneCode $($aloneOut.Trim())"

        Set-Content -LiteralPath (Join-Path $e2eStubs 'az.cmd') -Encoding ASCII -Value (@'
@echo off
if "%1"=="account" if "%2"=="show" (
  echo {"tenantId":"11111111-1111-1111-1111-111111111111","user":{"name":"dev@contoso.example","type":"user"}}
  exit /b 0
)
if "%1"=="account" if "%2"=="get-access-token" (
  echo @FAKE_JWT@
  exit /b 0
)
echo {}
exit /b 0
'@).Replace('@FAKE_JWT@', $fakeJwt)
        Set-Content -LiteralPath (Join-Path $e2eStubs 'claude-e2e.ps1') -Encoding ASCII -Value @'
Add-Content -LiteralPath $env:STUB_LOG -Value ($args -join ' ')
if ([string]$args[0] -eq '--version') { '2.1.101 (Claude Code)'; exit 0 }
'pong'
'@
        Set-Content -LiteralPath (Join-Path $e2eStubs 'claude.cmd') -Encoding ASCII -Value "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0claude-e2e.ps1`" %*"
        Set-Content -LiteralPath (Join-Path $e2eStubs 'claude') -Encoding ASCII -Value "#!/bin/sh`nexec node `"`$basedir/cli.js`" `"`$@`""
        Set-Content -LiteralPath (Join-Path $e2eStubs 'claude.ps1') -Encoding ASCII -Value "& (Join-Path `$PSScriptRoot 'claude-e2e.ps1') @args"
        Set-Content -LiteralPath (Join-Path $e2eStubs 'code.cmd') -Encoding ASCII -Value "@echo off`r`nif `"%1`"==`"--version`" (echo 1.139.1& exit /b 0)`r`nif `"%1`"==`"--list-extensions`" (echo anthropic.claude-code& exit /b 0)`r`nexit /b 0"

        # The gateway stand-in records each request and answers like the gateway.
        $port = Get-Random -Minimum 20000 -Maximum 40000
        $requestLog = Join-Path $e2e 'requests.log'
        $listenerJob = Start-Job -ArgumentList $port, $requestLog -ScriptBlock {
            param($port, $requestLog)
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            while ($listener.IsListening) {
                $ctx = $listener.GetContext()
                if ($ctx.Request.RawUrl -eq '/p67-stop') { $ctx.Response.StatusCode = 204; $ctx.Response.Close(); $listener.Stop(); break }
                $body = (New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
                $auth = [string]$ctx.Request.Headers['Authorization']
                $kind = if ($auth -match '^Bearer eyJ') { 'bearer-jwt' } elseif ($auth) { 'other' } else { 'none' }
                [IO.File]::AppendAllText($requestLog, ('{0} {1} auth={2} body={3}' -f $ctx.Request.HttpMethod, $ctx.Request.RawUrl, $kind, ($body -replace '\s+', ' ')) + [Environment]::NewLine)
                $text = if ($ctx.Request.RawUrl -match '/v1/messages') { '{"id":"msg_p67","type":"message","role":"assistant","content":[{"type":"text","text":"READY"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}' } else { '{}' }
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.Headers.Add('x-claude-tier', 'standard')
                $ctx.Response.Headers.Add('x-ratelimit-remaining-tokens', '19980')
                if ($ctx.Request.HttpMethod -ne 'HEAD') { $bytes = [Text.Encoding]::UTF8.GetBytes($text); $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
                $ctx.Response.Close()
            }
        }
        $up = $false
        for ($i = 0; $i -lt 40 -and -not $up; $i++) {
            try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/ready" -Method Head -UseBasicParsing -TimeoutSec 2; $up = $true } catch { Start-Sleep -Milliseconds 500 }
        }
        Assert 'the gateway stand-in is listening' $up "port $port"

        $e2eRecord = Join-Path $e2e 'claude-gateway.json'
        Set-Content -LiteralPath $e2eRecord -Encoding UTF8 -Value (@"
{ "gatewayUrl": "http://127.0.0.1:$port/claude", "tenantId": "11111111-1111-1111-1111-111111111111",
  "deployments": [ { "name": "claude-opus-5", "model": "claude-opus-5" }, { "name": "prod-big", "model": "claude-opus-5-5" },
                   { "name": "claude-sonnet-5", "model": "claude-sonnet-5" }, { "name": "claude-haiku-4-5", "model": "claude-haiku-4-5" } ],
  "desktopSignIn": { "kind": "external-idp", "flow": "broker", "bearerTokenType": "id_token", "clientId": "22222222-2222-2222-2222-222222222222",
                     "issuer": "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0" },
  "tiers": { "standard": { "tokensPerMinute": 20000, "tokensPerDay": 500000 } } }
"@)
        Set-Content -LiteralPath (Join-Path $e2eHome '.claude\settings.json') -Encoding UTF8 -Value '{ "env": { "ANTHROPIC_FOUNDRY_RESOURCE": "left-over", "MY_TOOL": "keep" }, "theme": "dark" }'
        Set-Content -LiteralPath (Join-Path $e2eVs 'settings.json') -Encoding UTF8 -Value @'
{
  // a developer comment
  "editor.fontSize": 14,
  "claudeCode.environmentVariables": [ { "name": "MY_VAR", "value": "keep" }, { "name": "ANTHROPIC_FOUNDRY_RESOURCE", "value": "left-over" } ]
}
'@
        $stubLog = Join-Path $e2e 'claude-calls.log'
        $env:PATH = $e2eStubs + [IO.Path]::PathSeparator + $e2eSaved['PATH']
        $env:USERPROFILE = $e2eHome
        $env:APPDATA = Join-Path $e2eHome 'AppData\Roaming'
        $env:LOCALAPPDATA = $e2eLocal
        $env:CLAUDE_CLIENT_DESKTOP_VERSION = '2.9939.2'
        $env:CLAUDE_CLIENT_DESKTOP_RUNNING_VERSION = '1.44121.2'
        $env:STUB_LOG = $stubLog
        $setupSw = [Diagnostics.Stopwatch]::StartNew()
        $setupRun = Invoke-BoundedScript (Join-Path $e2eScripts 'Setup-ClaudeWorkstation.ps1') @('-ConfigPath', $e2eRecord, '-SkipInstall') 180
        $setupOut = $setupRun.Text
        $setupSw.Stop()
        foreach ($name in $e2eSaved.Keys) { [Environment]::SetEnvironmentVariable($name, $e2eSaved[$name], 'Process') }
        $tail = (($setupOut -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 12) -join ' | '
        Assert "the Windows setup finishes in under 2 minutes ($([int]$setupSw.Elapsed.TotalSeconds) s)" (-not $setupRun.TimedOut -and $setupSw.Elapsed.TotalSeconds -lt 120) $(if ($setupRun.TimedOut) { "no exit within 180 s; ended. $tail" } else { '' })
        Assert 'the Windows setup reports nothing needing attention' ($setupOut -match 'Everything is configured') $tail

        $e2eSettings = Get-Content -LiteralPath (Join-Path $e2eHome '.claude\settings.json') -Raw | ConvertFrom-Json
        $wantEnv = Get-ClaudeCodeModelEnvironment -Deployments (Get-ClaudeRecordedDeployment -Config (Get-Content -LiteralPath $e2eRecord -Raw | ConvertFrom-Json))
        $envDiffer = @(foreach ($k in $script:ClaudeCodeGatewayEnvKeys) {
            if ($k -in 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_RESOURCE') { continue }
            $have = [string]$e2eSettings.env.$k; $want = if ($wantEnv.Contains($k)) { [string]$wantEnv[$k] } else { '' }
            if ($have -ne $want) { "$k wrote '$have', expected '$want'" }
        })
        Assert 'the Windows setup pins and declares what the rules give for the record' ($envDiffer.Count -eq 0 -and $e2eSettings.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'prod-big' -and $e2eSettings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'claude-haiku-4-5') ($envDiffer -join '; ')
        Assert 'the Windows setup keeps the developer''s own settings and removes the resource variable' ($e2eSettings.env.MY_TOOL -eq 'keep' -and $e2eSettings.theme -eq 'dark' -and -not $e2eSettings.env.PSObject.Properties['ANTHROPIC_FOUNDRY_RESOURCE'] -and $e2eSettings.env.ANTHROPIC_FOUNDRY_BASE_URL -eq "http://127.0.0.1:$port/claude")
        $vsRaw = Get-Content -LiteralPath (Join-Path $e2eVs 'settings.json') -Raw
        $vsDoc = ($vsRaw -replace '(?m)^\s*//.*$', '') | ConvertFrom-Json
        $vsVars = @{}; foreach ($v in @($vsDoc.'claudeCode.environmentVariables')) { $vsVars[$v.name] = $v.value }
        Assert 'the Windows setup keeps the developer''s VS Code variables and replaces its own' ($vsVars['MY_VAR'] -eq 'keep' -and $vsDoc.'editor.fontSize' -eq 14 -and -not $vsVars.ContainsKey('ANTHROPIC_FOUNDRY_RESOURCE') -and $vsVars['ANTHROPIC_DEFAULT_OPUS_MODEL'] -eq 'prod-big' -and $vsVars['ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES'] -eq $allCaps) (($vsVars.Keys | Sort-Object) -join ',')

        $e2eLib = Join-Path $e2eLocal 'Claude-3p\configLibrary'
        $e2eMeta = if (Test-Path -LiteralPath (Join-Path $e2eLib '_meta.json')) { Get-Content -LiteralPath (Join-Path $e2eLib '_meta.json') -Raw | ConvertFrom-Json } else { $null }
        $e2eProfile = if ($e2eMeta -and (Test-Path -LiteralPath (Join-Path $e2eLib "$($e2eMeta.appliedId).json"))) { Get-Content -LiteralPath (Join-Path $e2eLib "$($e2eMeta.appliedId).json") -Raw | ConvertFrom-Json } else { $null }
        Assert 'the Windows setup writes the spelling the running 1.44121.2 build reads' ($e2eProfile -and $e2eProfile.inferenceCredentialKind -eq 'interactive' -and $e2eProfile.inferenceGatewayOidcAuthFlow -eq 'broker' -and $e2eProfile.inferenceGatewayOidc.clientId -eq '22222222-2222-2222-2222-222222222222' -and -not $e2eProfile.PSObject.Properties['inferenceIdpOidc'] -and (@($e2eProfile.inferenceModels | ForEach-Object { $_.name }) -join ',') -eq 'claude-opus-5,prod-big,claude-sonnet-5,claude-haiku-4-5') ($e2eProfile | ConvertTo-Json -Compress -Depth 5)
        Assert 'the Windows setup names the stale running Desktop build' ($setupOut -match '2\.9939\.2 is installed, but 1\.44121\.2 is running') $tail

        $requests = if (Test-Path -LiteralPath $requestLog) { Get-Content -LiteralPath $requestLog -Raw } else { '' }
        Assert 'the Windows setup''s request reaches the gateway with a bearer token for the Sonnet deployment' ($requests -match 'POST /claude/v1/messages auth=bearer-jwt body=.*"model":\s*"claude-sonnet-5"' -and $setupOut -match 'gateway responded\s+HTTP 200' -and $setupOut -match 'tier\s+standard') $requests.Trim()
        $calls = if (Test-Path -LiteralPath $stubLog) { Get-Content -LiteralPath $stubLog -Raw } else { '' }
        Assert 'the Windows setup asks Claude Code itself for a reply' ($calls -match '-p ping --model claude-sonnet-5' -and $setupOut -match 'Claude Code answered through the gateway') $calls.Trim()
        Assert 'the Windows setup names the Claude Code release the record needs' ($setupOut -match 'predates 2\.1\.280' -and $setupOut -match 'claude update') $tail
    }
    finally {
        foreach ($name in $e2eSaved.Keys) { [Environment]::SetEnvironmentVariable($name, $e2eSaved[$name], 'Process') }
        if ($listenerJob) {
            # Stop-Job waits up to two minutes for a job blocked in GetContext; a stop request ends it.
            try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:$port/p67-stop" -UseBasicParsing -TimeoutSec 5 } catch { Write-Verbose 'listener already stopped' }
            $null = Wait-Job $listenerJob -Timeout 10
            Remove-Job $listenerJob -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $e2e -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host 'P67 macOS and Linux setup writes what the Windows setup writes' -ForegroundColor Cyan
# The real setup-claude-workstation.sh, run against a scratch HOME with az, claude, code, curl,
# uname and claude-desktop stubbed, so the platform is Linux and nothing leaves the machine.
$bash = $null
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    foreach ($candidate in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if (Test-Path -LiteralPath $candidate) { $bash = $candidate; break }
    }
}
else { $cmd = Get-Command bash -ErrorAction SilentlyContinue; if ($cmd) { $bash = $cmd.Source } }
$bashJq = if ($bash) { (& $bash -c 'command -v jq >/dev/null 2>&1 && echo yes' 2>$null) -eq 'yes' } else { $false }
if (-not $bash -or -not $bashJq) {
    Write-Host "  [SKIP] $(if (-not $bash) { 'no Git Bash or bash on this host' } else { 'bash has no jq' }); the bash setup was not run" -ForegroundColor Yellow
}
else {
    $bashScratch = Join-Path ([IO.Path]::GetTempPath()) "ws-bash-$PID-$(Get-Random)"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    function Write-Lf([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $utf8) }
    # A script file rather than bash -c: Windows PowerShell 5.1 drops the double quotes inside a
    # native argument, which garbled the JSON record and the TERM trap in the scripts below.
    function Invoke-BashText([string]$Text) {
        $file = Join-Path $bashScratch ("run-{0}.sh" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($file, $Text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
        return (& $bash (ConvertTo-BashPath $file) 2>&1 | Out-String)
    }
    function ConvertTo-BashPath([string]$Path) {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return $Path }
        $full = [IO.Path]::GetFullPath($Path)
        return '/' + $full.Substring(0, 1).ToLowerInvariant() + $full.Substring(2).Replace('\', '/')
    }
    try {
        $bin = Join-Path $bashScratch 'bin'
        $home2 = Join-Path $bashScratch 'home'
        $vsDir = Join-Path $home2 '.config\Code\User'
        New-Item -ItemType Directory -Force -Path $bin, (Join-Path $home2 '.claude'), $vsDir | Out-Null
        Write-Lf (Join-Path $bin 'uname') "#!/usr/bin/env bash`ncase `"`${1:-}`" in -m) echo x86_64 ;; -r) echo 6.0.0 ;; *) echo Linux ;; esac`n"
        Write-Lf (Join-Path $bin 'az') (@'
#!/usr/bin/env bash
case "$*" in
  *get-access-token*) printf '%s\n' '@FAKE_JWT@' ;;
  *"account show --query tenantId"*) echo 11111111-1111-1111-1111-111111111111 ;;
  *"account show --query user.name"*) echo dev@contoso.example ;;
  version*) echo 2.77.0 ;;
  *) echo '{}' ;;
esac
'@).Replace('@FAKE_JWT@', $fakeJwt)
        Write-Lf (Join-Path $bin 'claude') @'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "${1:-}" in --version) echo "${STUB_CLAUDE_VERSION:-2.1.101} (Claude Code)" ;; -p) echo pong ;; esac
'@
        Write-Lf (Join-Path $bin 'curl') @'
#!/usr/bin/env bash
hdr=""
while [ $# -gt 0 ]; do case "$1" in -D) hdr="$2"; shift 2 ;; -w|-o|-m|-X|-H|-d|--max-time) shift 2 ;; *) shift ;; esac; done
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nx-claude-tier: standard\r\n' > "$hdr"
printf '200'
'@
        Write-Lf (Join-Path $bin 'code') "#!/usr/bin/env bash`n[ `"`${1:-}`" = --list-extensions ] && echo anthropic.claude-code`nexit 0`n"
        Write-Lf (Join-Path $bin 'claude-desktop') "#!/usr/bin/env bash`nexit 0`n"

        $bashRecord = [ordered]@{
            gatewayUrl = 'https://apim-test.azure-api.net/claude'
            tenantId = '11111111-1111-1111-1111-111111111111'
            deployments = @(
                [ordered]@{ name = 'claude-opus-5'; model = 'claude-opus-5' },
                [ordered]@{ name = 'prod-big'; model = 'claude-opus-5-5' },
                [ordered]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5'; capabilities = 'effort,thinking' },
                [ordered]@{ name = 'claude-haiku-4-5'; model = 'claude-haiku-4-5' },
                [ordered]@{ name = 'prod-next'; model = 'claude-next-1'; capabilities = 'effort,thinking'; claudeCode = '2.2.10' },
                [ordered]@{ name = 'prod-plain'; model = 'claude-opus-5'; capabilities = 'none'; claudeCode = '9.9.9' }
            )
            desktopSignIn = [ordered]@{ kind = 'external-idp'; flow = 'broker'; bearerTokenType = 'id_token'; clientId = '22222222-2222-2222-2222-222222222222'; issuer = 'https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0' }
        }
        $bashConfig = Join-Path $bashScratch 'claude-gateway.json'
        Write-Lf $bashConfig ($bashRecord | ConvertTo-Json -Depth 6)
        Write-Lf (Join-Path $home2 '.claude\settings.json') '{ "env": { "ANTHROPIC_FOUNDRY_RESOURCE": "left-over", "MY_TOOL": "keep" }, "theme": "dark" }'
        Write-Lf (Join-Path $vsDir 'settings.json') @'
{
  // a developer comment
  "editor.fontSize": 14,
  "claudeCode.environmentVariables": [ { "name": "MY_VAR", "value": "keep" }, { "name": "ANTHROPIC_FOUNDRY_RESOURCE", "value": "left-over" } ]
}
'@
        $stubLog = Join-Path $bashScratch 'claude-calls.log'
        $inner = "chmod +x '$(ConvertTo-BashPath $bin)'/*; export HOME='$(ConvertTo-BashPath $home2)'; unset XDG_CONFIG_HOME; export PATH='$(ConvertTo-BashPath $bin)':`"`$PATH`"; export STUB_LOG='$(ConvertTo-BashPath $stubLog)'; timeout 120 bash '$(ConvertTo-BashPath (Join-Path $root 'scripts\setup-claude-workstation.sh'))' --config '$(ConvertTo-BashPath $bashConfig)' --skip-install </dev/null 2>&1"
        $bashSw = [Diagnostics.Stopwatch]::StartNew()
        $bashOut = Invoke-BashText $inner
        $bashSw.Stop()
        Assert "the bash setup finishes in under 2 minutes ($([int]$bashSw.Elapsed.TotalSeconds) s)" ($bashSw.Elapsed.TotalSeconds -lt 120)

        $bashSettings = Get-Content -LiteralPath (Join-Path $home2 '.claude\settings.json') -Raw | ConvertFrom-Json
        $psEnv = Get-ClaudeCodeModelEnvironment -Deployments (Get-ClaudeRecordedDeployment -Config ($bashRecord | ConvertTo-Json -Depth 6 | ConvertFrom-Json))
        $mismatch = @(foreach ($k in $script:ClaudeCodeGatewayEnvKeys) {
            if ($k -in 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_FOUNDRY_RESOURCE') { continue }
            $b = [string]$bashSettings.env.$k; $p = if ($psEnv.Contains($k)) { [string]$psEnv[$k] } else { '' }
            if ($b -ne $p) { "$k bash='$b' pwsh='$p'" }
        })
        Assert 'bash pins and declares exactly what the PowerShell setup does' ($mismatch.Count -eq 0) ($mismatch -join '; ')
        Assert 'bash pins the newest Opus, whatever its deployment is called' ($bashSettings.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq 'prod-big' -and $bashSettings.env.ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES -eq $allCaps)
        Assert 'bash honours an administrator capability override' ($bashSettings.env.ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES -eq 'effort,thinking')
        Assert 'bash gives a Haiku deployment the Haiku alias with no declaration' ($bashSettings.env.ANTHROPIC_DEFAULT_HAIKU_MODEL -eq 'claude-haiku-4-5' -and -not $bashSettings.env.PSObject.Properties['ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES'])
        Assert 'bash removes the resource variable and keeps the developer''s own settings' (-not $bashSettings.env.PSObject.Properties['ANTHROPIC_FOUNDRY_RESOURCE'] -and $bashSettings.env.MY_TOOL -eq 'keep' -and $bashSettings.theme -eq 'dark')
        Assert 'bash lists every recorded deployment' ((@($bashSettings.availableModels) -join ',') -eq 'claude-opus-5,prod-big,claude-sonnet-5,claude-haiku-4-5,prod-next,prod-plain')

        $vsSettings = Get-Content -LiteralPath (Join-Path $vsDir 'settings.json') -Raw | ConvertFrom-Json
        $vsEnv = @{}; foreach ($e in @($vsSettings.'claudeCode.environmentVariables')) { $vsEnv[$e.name] = $e.value }
        Assert 'bash keeps the developer''s own VS Code variables' ($vsEnv['MY_VAR'] -eq 'keep' -and $vsSettings.'editor.fontSize' -eq 14) (($vsEnv.Keys | Sort-Object) -join ',')
        Assert 'bash replaces the VS Code variables it owns' (-not $vsEnv.ContainsKey('ANTHROPIC_FOUNDRY_RESOURCE') -and $vsEnv['ANTHROPIC_DEFAULT_HAIKU_MODEL'] -eq 'claude-haiku-4-5' -and $vsEnv['ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES'] -eq $allCaps)

        $library = Join-Path $home2 '.config\Claude-3p\configLibrary'
        $meta = if (Test-Path -LiteralPath (Join-Path $library '_meta.json')) { Get-Content -LiteralPath (Join-Path $library '_meta.json') -Raw | ConvertFrom-Json } else { $null }
        $profilePath = if ($meta) { Join-Path $library "$($meta.appliedId).json" } else { '' }
        $bashProfile = if ($profilePath -and (Test-Path -LiteralPath $profilePath)) { Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json } else { $null }
        Assert 'bash writes a Linux Desktop profile the original spelling' ($bashProfile -and $bashProfile.inferenceCredentialKind -eq 'interactive' -and $bashProfile.inferenceGatewayOidc.clientId -eq '22222222-2222-2222-2222-222222222222' -and $bashProfile.inferenceGatewayOidcAuthFlow -eq 'broker' -and -not $bashProfile.PSObject.Properties['inferenceIdpOidc']) $profilePath

        $calls = if (Test-Path -LiteralPath $stubLog) { Get-Content -LiteralPath $stubLog -Raw } else { '' }
        Assert 'bash asks Claude Code itself for a reply through the gateway' ($calls -match '-p ping --model claude-sonnet-5' -and $bashOut -match 'Claude Code answered through the gateway') (($bashOut -split "`r?`n" | Where-Object { $_ -match 'Claude Code|Verifying|FAIL|\[x\]' }) -join ' | ')
        $psRequired = Get-ClaudeCodeRequiredVersion -Deployments (Get-ClaudeRecordedDeployment -Config ($bashRecord | ConvertTo-Json -Depth 6 | ConvertFrom-Json))
        Assert 'bash and PowerShell name the same Claude Code release the record needs' ($psRequired.Version -eq '2.2.10' -and $bashOut -match 'predates 2\.2\.10' -and $bashOut -match 'claude update') "pwsh=$($psRequired.Version)"
        Assert 'a deployment declared none asks for no release' ($bashOut -notmatch '9\.9\.9')
        Assert 'bash reports nothing needing attention' ($bashOut -match 'Everything is configured') (($bashOut -split "`r?`n" | Select-Object -Last 8) -join ' | ')

        # The macOS/Linux diagnostics read what the setup wrote, with the same rules.
        function Get-ShCheckBlock([string]$Text, [string]$Name) {
            $m = [regex]::Match($Text, '(?ms)^\s*(PASS|WARN|FAIL|SKIP) ' + [regex]::Escape($Name) + '\s*$.*?(?=^\s*(PASS|WARN|FAIL|SKIP) |\z)')
            if ($m.Success) { $m.Value } else { '' }
        }
        $diagInner = "export HOME='$(ConvertTo-BashPath $home2)'; unset XDG_CONFIG_HOME; export PATH='$(ConvertTo-BashPath $bin)':`"`$PATH`"; export STUB_LOG='$(ConvertTo-BashPath $stubLog)'; timeout 60 bash '$(ConvertTo-BashPath (Join-Path $root 'scripts\debug-claude-workstation.sh'))' --config '$(ConvertTo-BashPath $bashConfig)' --no-request </dev/null 2>&1"
        $diagOut = Invoke-BashText $diagInner
        $shModels = Get-ShCheckBlock $diagOut 'Claude Code and the recorded models'
        Assert 'bash diagnostics: with declarations, only the update is reported' ($shModels -match '^\s*WARN' -and $shModels -match '2\.2\.10' -and $shModels -match 'claude update') $shModels
        $shDesktop = Get-ShCheckBlock $diagOut 'Claude Desktop sign-in configuration'
        Assert 'bash diagnostics read the Desktop profile the setup wrote' ($shDesktop -match '^\s*PASS' -and $shDesktop -match 'kind interactive') $shDesktop
        $undeclared = Get-Content -LiteralPath (Join-Path $home2 '.claude\settings.json') -Raw | ConvertFrom-Json
        foreach ($p in @($undeclared.env.PSObject.Properties.Name | Where-Object { $_ -like '*_SUPPORTED_CAPABILITIES' })) { $undeclared.env.PSObject.Properties.Remove($p) }
        Write-Lf (Join-Path $home2 '.claude\settings.json') ($undeclared | ConvertTo-Json -Depth 6)
        $diagOut2 = Invoke-BashText $diagInner
        $shModels2 = Get-ShCheckBlock $diagOut2 'Claude Code and the recorded models'
        Assert 'bash diagnostics: an old Claude Code without declarations fails for a model id' ($shModels2 -match '^\s*FAIL' -and $shModels2 -match 'not set for claude-sonnet-5' -and $shModels2 -match '2\.1\.197') $shModels2
        Assert 'bash diagnostics: a custom deployment name without one is named as depending on the release' ($shModels2 -match 'not set for prod-big \(claude-opus-5-5\)' -and $shModels2 -match '2\.1\.280' -and $shModels2 -match 'depends on the release') $shModels2
        $partial = Get-Content -LiteralPath (Join-Path $home2 '.claude\settings.json') -Raw | ConvertFrom-Json
        $partial.env | Add-Member -NotePropertyName 'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES' -NotePropertyValue 'thinking' -Force
        Write-Lf (Join-Path $home2 '.claude\settings.json') ($partial | ConvertTo-Json -Depth 6)
        $shModels3 = Get-ShCheckBlock (Invoke-BashText $diagInner) 'Claude Code and the recorded models'
        Assert 'bash diagnostics: thinking without adaptive_thinking fails on a release that does not retry' ($shModels3 -match '^\s*FAIL' -and $shModels3 -match 'OPUS_MODEL_SUPPORTED_CAPABILITIES lists thinking without adaptive_thinking for prod-big') $shModels3

        # Two copies of the model rules: the PowerShell module and the bash library both bash
        # scripts source. Neither bash script keeps a copy of its own.
        $libPath = Join-Path $root 'scripts\claude-client-support.sh'
        $libText = Get-Content -LiteralPath $libPath -Raw
        $releaseTable = { param([string]$Text) @([regex]::Matches($Text, "(claude-[a-z0-9-]+)\) printf '(\d+\.\d+\.\d+)'") | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[2].Value)" } | Sort-Object) -join ',' }
        $psTable = @($script:ClaudeCodeFirstRelease.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Sort-Object) -join ','
        Assert 'the PowerShell and bash release tables agree' ($psTable -eq (& $releaseTable $libText)) "pwsh=$psTable bash=$(& $releaseTable $libText)"
        $floors = 'opus) floor="{0}" ;; sonnet|fable|mythos) floor="{1}"' -f $script:ClaudeAdaptiveFamilyFloor['opus'].ToString(), $script:ClaudeAdaptiveFamilyFloor['sonnet'].ToString()
        Assert 'the PowerShell and bash capability rules agree' ($libText.Contains("ALL_CAPS=`"$script:ClaudeAdaptiveCapabilities`"") -and $libText.Contains($floors) -and $script:ClaudeAdaptiveFamilyFloor['fable'] -eq $script:ClaudeAdaptiveFamilyFloor['sonnet'] -and $script:ClaudeAdaptiveFamilyFloor['mythos'] -eq $script:ClaudeAdaptiveFamilyFloor['sonnet']) $floors
        $localCopies = @(foreach ($s in 'setup-claude-workstation.sh', 'debug-claude-workstation.sh') {
            $t = Get-Content -LiteralPath (Join-Path $root "scripts\$s") -Raw
            if ($t -notmatch '\. "\$CLIENT_SUPPORT"' -or $t -match '(?m)^(model_[a-z_]+|deployment_[a-z_]+|alias_check_|run_bounded_)\(\)') { $s }
        })
        Assert 'both bash scripts source the library and keep no copy of the rules' ($localCopies.Count -eq 0) ($localCopies -join ', ')

        # The same verdict, word for word, from Get-ClaudeCodeAliasCheck and alias_check_.
        $shCases = @($aliasCases | ForEach-Object { "alias_check_ 'ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES' '$($_.Pinned)' '$($_.Declared)' '$($_.Installed)'; echo" })
        $shScript = ". '$(ConvertTo-BashPath $libPath)'`nCONFIG_RAW='$aliasRecordJson'`n" + ($shCases -join "`n")
        $shVerdicts = @((Invoke-BashText $shScript) -split "`r?`n" | Where-Object { $_ -match '^(ok|warn|fail)\|' })
        $differ = @(for ($i = 0; $i -lt $aliasCases.Count; $i++) {
            $ps = "$($aliasVerdicts[$i].Status)|$($aliasVerdicts[$i].Text)"
            $sh = if ($i -lt $shVerdicts.Count) { $shVerdicts[$i] } else { '(missing)' }
            if ($ps -ne $sh) { "$($aliasCases[$i].Label): pwsh '$ps' bash '$sh'" }
        })
        Assert "alias_check_ gives the PowerShell verdict for all $($aliasCases.Count) cases" ($shVerdicts.Count -eq $aliasCases.Count -and $differ.Count -eq 0) ($differ -join ' || ')

        # A hard time limit: a command that ignores TERM ends within the limit plus the 5 s grace,
        # its output is released, and a normal exit code passes through. The second run takes the
        # watchdog, which is what macOS without coreutils uses.
        $boundedScript = @'
. '@LIB@'
s=$(date +%s); out="$(run_bounded_ 2 bash -c 'trap "" TERM; sleep 30; echo late' </dev/null)"; rc=$?; echo "timeout rc=$rc secs=$(( $(date +%s) - s )) out=[$out]"
export CLAUDE_BOUNDED_NO_TIMEOUT=1
s=$(date +%s); out="$(run_bounded_ 2 bash -c 'trap "" TERM; sleep 30; echo late' </dev/null)"; rc=$?; echo "watchdog rc=$rc secs=$(( $(date +%s) - s )) out=[$out]"
out="$(run_bounded_ 10 bash -c 'echo ran; exit 3' </dev/null)"; echo "passthrough rc=$? out=[$out]"
'@.Replace('@LIB@', (ConvertTo-BashPath $libPath))
        $boundedOut = Invoke-BashText $boundedScript
        foreach ($path in 'timeout', 'watchdog') {
            $m = [regex]::Match($boundedOut, "$path rc=(\d+) secs=(\d+) out=\[([^\]]*)\]")
            Assert "run_bounded_ ($path) ends a command that ignores TERM" ($m.Success -and $m.Groups[1].Value -eq '124' -and [int]$m.Groups[2].Value -le 12 -and $m.Groups[3].Value -notmatch 'late') $boundedOut.Trim()
        }
        Assert 'run_bounded_ passes a normal exit code and output through' ($boundedOut -match 'passthrough rc=3 out=\[ran\]') $boundedOut.Trim()
    }
    finally {
        Remove-Item -LiteralPath $bashScratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Client configuration contract holds.' -ForegroundColor Green
exit 0
