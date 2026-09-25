# Nothing about one deployment is written into the scripts.
#
# Scripts take the gateway's resource group from the environment or from what the installer
# recorded (scripts/Get-ClaudeGatewayTarget.ps1), never from a name in the code, so a clone
# pointed at another deployment cannot quietly act on the reference one. This checks the code
# for the reference deployment's names, and the resolver's order.
#
# Offline. The resolver runs in a sandbox copy, so the real onboarding file is not touched.

$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

# The reference deployment's names belong only in this detector, never runtime defaults.
$reference = @('rg-contosohub', 'apim-claude-gw-fzgql9', 'ai-contosohub530569751908', 'log-claude-gw-fzgql9', 'appi-claude-gw-fzgql9')
$allowed = @('tests/Test-NoDeploymentValues.ps1')

function Find-Reference([string[]]$Paths) {
    foreach ($f in $Paths) {
        $rel = $f.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($allowed -contains $rel) { continue }
        $text = Get-Content $f -Raw
        foreach ($name in $reference) { if ($text.Contains($name)) { "${rel}: $name" } }
    }
}

Write-Host 'No deployment in the code' -ForegroundColor Cyan

$code = @(Get-ChildItem (Join-Path $root 'scripts'), (Join-Path $root 'tests') -Recurse -File -Include *.ps1) +
    @(Get-ChildItem (Join-Path $root 'guide'), (Join-Path $root 'scripts') -Recurse -File -Filter *.mjs) +
    @(Get-ChildItem $root -File -Filter *.ps1) | ForEach-Object { $_.FullName }
$found = @(Find-Reference $code)
Assert 'no script or test names the reference deployment' (-not $found.Count) ($found -join '; ')

# The check has been seen to fail: a planted name in a copy is found.
$plant = Join-Path ([IO.Path]::GetTempPath()) "nodeploy-$PID.ps1"
try {
    [IO.File]::WriteAllText($plant, "param([string]`$ResourceGroup = 'rg-contosohub')")
    $saved = $root; $root = [IO.Path]::GetTempPath().TrimEnd('\', '/')
    $control = @(Find-Reference @($plant))
    $root = $saved
    Assert 'and a planted name would be found'               ($control.Count -eq 1)
}
finally { Remove-Item $plant -ErrorAction SilentlyContinue }

$mjsPlant = Join-Path ([IO.Path]::GetTempPath()) "nodeploy-$PID.mjs"
try {
    [IO.File]::WriteAllText($mjsPlant, "const defaultGateway = 'apim-claude-gw-fzgql9';")
    $saved = $root; $root = [IO.Path]::GetTempPath().TrimEnd('\', '/')
    $control = @(Find-Reference @($mjsPlant))
    $root = $saved
    Assert 'a planted .mjs deployment literal is caught' ($control.Count -eq 1)
}
finally { Remove-Item $mjsPlant -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host 'Where the gateway is found' -ForegroundColor Cyan

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "gwtarget-$PID-$(Get-Random)"
$savedRg = $env:CLAUDE_RG; $savedApim = $env:CLAUDE_APIM
try {
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'scripts') -Force | Out-Null
    Copy-Item (Join-Path $root 'scripts/Get-ClaudeGatewayTarget.ps1') (Join-Path $sandbox 'scripts') -Force
    $resolver = Join-Path $sandbox 'scripts/Get-ClaudeGatewayTarget.ps1'
    $env:CLAUDE_RG = $null; $env:CLAUDE_APIM = $null

    $none = & $resolver ResourceGroup 3>$null
    Assert 'with nothing recorded, nothing is assumed'       ($none -eq '')

    New-Item -ItemType Directory -Path (Join-Path $sandbox 'onboarding') -Force | Out-Null
    '{"resourceGroup":"rg-recorded","apimName":"apim-recorded"}' | Set-Content (Join-Path $sandbox 'onboarding/claude-gateway.json')
    Assert 'what the installer recorded is used'             ((& $resolver ResourceGroup) -eq 'rg-recorded' -and (& $resolver ApimName) -eq 'apim-recorded')

    $env:CLAUDE_RG = 'rg-from-environment'
    Assert 'the environment wins over the record'            ((& $resolver ResourceGroup) -eq 'rg-from-environment')
}
finally {
    $env:CLAUDE_RG = $savedRg; $env:CLAUDE_APIM = $savedApim
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

$defaults = @($code | Where-Object { (Get-Content $_ -Raw) -match '\[string\]\$ResourceGroup = ' })
# A script that creates a deployment names the resource group it will create; that is a choice
# made at deployment, not a pointer at an existing one.
$creators = @('deploy.ps1')
$defaults = @($defaults | Where-Object { $creators -notcontains (Split-Path $_ -Leaf) })
$resolving = @($defaults | Where-Object { (Get-Content $_ -Raw) -match "Get-ClaudeGatewayTarget\.ps1'\) ResourceGroup" })
Assert 'every -ResourceGroup default comes from the resolver' ($defaults.Count -gt 0 -and $resolving.Count -eq $defaults.Count) "$($resolving.Count) of $($defaults.Count)"

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Every deployment-values check passed.' -ForegroundColor Green
exit 0
