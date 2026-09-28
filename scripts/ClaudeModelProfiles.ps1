function Write-ClaudeModelProfiles {
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$RecordPath)
    $profileRoot = Join-Path (Split-Path $RecordPath -Parent) 'profiles'
    $hasTierModels = $Record.tiers -and @('standard','premium' | Where-Object {
        $Record.tiers.$_ -and $Record.tiers.$_.PSObject.Properties.Name -contains 'models'
    }).Count -eq 2
    foreach ($tier in 'standard', 'premium') {
        $out = Join-Path $profileRoot $tier
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        $configPath = $RecordPath
        if ($hasTierModels) {
            $copy = $Record | ConvertTo-Json -Depth 40 | ConvertFrom-Json
            foreach ($key in '__recordPath', 'activeRun', 'history', 'release') { $copy.PSObject.Properties.Remove($key) }
            $names = @($Record.tiers.$tier.models)
            if (-not $names.Count) { throw "The $tier tier has no live deployments for a workstation profile." }
            Set-ClaudeRecordProperty $copy 'models' $names
            Set-ClaudeRecordProperty $copy 'deployments' @($Record.deployments | Where-Object { $_.name -in $names })
            Set-ClaudeRecordProperty $copy 'workstationTier' $tier
            $configPath = Join-Path $out 'claude-gateway.json'
            Write-ClaudeDecisionRecord -Record $copy -Path $configPath
        }
        & (Join-Path $PSScriptRoot 'New-ClaudeCodePolicy.ps1') -ConfigPath $configPath -Tier $tier -OutputPath $out | Out-Null
    }
    $note = @(
        '# Claude managed profiles'
        ''
        'The standard and premium folders contain separate Claude Code and Desktop MDM profiles.'
        'Each claude-gateway.json is the workstation record for that tier, not an entitlement grant.'
        'Intune, Jamf or Group Policy assignment remains an administrator action; one profile route applies per device.'
        ''
        'Windows developer command from the accelerator folder (standard shown):'
        '```powershell'
        ".\scripts\Setup-ClaudeWorkstation.ps1 -ConfigPath '$((Join-Path $profileRoot 'standard\claude-gateway.json') -replace "'", "''")'"
        '```'
        ''
        'macOS/Linux, with the selected tier record beside the downloaded setup and its helpers:'
        '```bash'
        'bash setup-claude-workstation.sh --config ./claude-gateway.json'
        '```'
        ''
        'Rerunning setup updates availableModels, newest-per-family pinned aliases and capability declarations,'
        'VS Code model environment variables, and Desktop inferenceModels. Unrelated user settings remain.'
        'The gateway URL, sign-in method and Entra entitlement are unchanged. Managed settings take precedence.'
        'The premium command uses the premium record. The MDM payloads are redistributed through the existing fleet tool.'
        ''
        'Saved ClaudeCost queries embed a price book when published. A changed book reaches those queries through'
        'scripts/Publish-ClaudeQueries.ps1, and reaches scheduled dollar reconcilers through their existing deployment path.'
        'Neither publication nor a remote workstation update is performed by model sync.'
    )
    $note | Set-Content -LiteralPath (Join-Path $profileRoot 'README.md') -Encoding UTF8
    return [pscustomobject]@{ generatedUtc = [DateTime]::UtcNow.ToString('o'); root = $profileRoot; tiers = @('standard','premium') }
}
