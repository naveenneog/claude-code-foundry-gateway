# P26 - the installer discovers or deploys a model.
#
# RED first: written before the implementation.
#
# Install-ClaudeGateway.ps1 assumed a Claude deployment already existed and
# threw when it did not - "the gateway fronts a model, it cannot create one".
# That is a true statement about the gateway and an unhelpful one about the
# installer, which is talking to a subscription where it could create the
# deployment itself.
#
# What the operator needs: see what is deployed with enough detail to choose,
# choose one, or deploy a model when there is nothing to choose from. And a
# clear failure when the subscription genuinely cannot support it - no eligible
# account, or no quota.
#
# Offline only. The live half is tests/Test-ModelDeploymentLive.ps1.

$root = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $root 'Install-ClaudeGateway.ps1'
$helper = Join-Path $root 'scripts/ClaudeModelDeployment.ps1'

$fail = 0
function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Model deployment - the helper' -ForegroundColor Cyan

Assert 'a helper exists' (Test-Path $helper) $helper
if (Test-Path $helper) {
    . $helper
    foreach ($fn in 'Get-ClaudeDeployment', 'Get-DeployableClaudeModel', 'New-ClaudeDeployment', 'Format-ClaudeDeployment') {
        Assert "it exposes $fn" ([bool](Get-Command $fn -ErrorAction SilentlyContinue))
    }

    # Claude deployments are the ones the gateway can front. Anything else on
    # the same account is somebody else's workload and must not be offered.
    if (Get-Command Select-ClaudeDeployment -ErrorAction SilentlyContinue) {
        $all = @(
            [pscustomobject]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5'; sku = 'GlobalStandard'; capacity = 100 }
            [pscustomobject]@{ name = 'gpt-4o';          model = 'gpt-4o';          sku = 'Standard';       capacity = 50 }
            [pscustomobject]@{ name = 'my-claude-opus';  model = 'claude-opus-5';   sku = 'GlobalStandard'; capacity = 20 }
        )
        $picked = @(Select-ClaudeDeployment -Deployments $all)
        Assert 'it keeps only Claude deployments' ($picked.Count -eq 2) "got $($picked.Count)"
        # A deployment may be named anything; the model behind it is what counts.
        Assert 'it matches on the model, not the deployment name' ([bool]($picked | Where-Object { $_.name -eq 'my-claude-opus' }))
        Assert 'and drops a non-Claude model' (-not ($picked | Where-Object { $_.name -eq 'gpt-4o' }))
    }
    else { Assert 'Claude deployments can be selected' $false 'Select-ClaudeDeployment missing' }

    # A name alone does not tell an operator whether the deployment can carry
    # their traffic. Capacity and SKU do.
    if (Get-Command Format-ClaudeDeployment -ErrorAction SilentlyContinue) {
        $line = Format-ClaudeDeployment ([pscustomobject]@{ name = 'claude-sonnet-5'; model = 'claude-sonnet-5'; version = '1'; sku = 'GlobalStandard'; capacity = 250 })
        Assert 'the summary names the deployment' ($line -match 'claude-sonnet-5')
        Assert 'it shows the SKU'                 ($line -match 'GlobalStandard')
        Assert 'it shows the capacity'            ($line -match '250')
    }
}

Write-Host ''
Write-Host 'Model deployment - the installer' -ForegroundColor Cyan

$i = Get-Content $installer -Raw

# The old behaviour: throw and tell the operator to go and do it themselves.
Assert 'it no longer refuses outright' ($i -notmatch 'it cannot create one')
Assert 'it offers to deploy a model'   ($i -match '(?i)deploy a model|New-ClaudeDeployment')
Assert 'it uses the helper'            ($i -match 'ClaudeModelDeployment\.ps1')

# Selecting a deployment is the point - the tier model lists are what the
# gateway enforces, so a discovered deployment has to reach them.
Assert 'it lets the operator choose per tier' ($i -match "Models for the standard tier" -and $i -match "Models for the premium tier")
Assert 'and choose what to deploy'            ($i -match "Model number")
Assert 'the choice reaches the template' ($i -match 'modelsStandard')
Assert 'for both tiers'                  ($i -match 'modelsPremium')
# Hard-coding the allow list produces a gateway that refuses a model naming one
# the account never served.
Assert 'the lists come from what is deployed' ($i -match 'Get-ClaudeDeployment')

# Failures have to be distinguishable. "No account" and "no quota" need
# different answers from the operator: one is a region or subscription problem,
# the other is a quota request or a smaller capacity.
Assert 'no eligible account is its own message' ($i -match '(?i)No AIServices or OpenAI accounts')

if (Get-Command Get-DeploymentFailureReason -ErrorAction SilentlyContinue) {
    $q = Get-DeploymentFailureReason -AzureOutput 'InsufficientQuota: this would exceed the assigned quota' `
        -Model 'claude-sonnet-5' -Account 'acct' -Sku 'GlobalStandard' -Capacity 500
    Assert 'a quota failure is classified as quota' ($q.Reason -eq 'quota') "got '$($q.Reason)'"
    Assert 'and says what to do about it'   ($q.Message -match '(?i)more quota' -and $q.Message -match '(?i)capacity' -and $q.Message -match '(?i)region')
    Assert 'and names the capacity asked for' ($q.Message -match '500')

    $o = Get-DeploymentFailureReason -AzureOutput 'AuthorizationFailed: the client does not have permission' `
        -Model 'claude-sonnet-5' -Account 'acct'
    Assert 'an unrelated failure is not called quota' ($o.Reason -eq 'other') "got '$($o.Reason)'"
    Assert 'and is not given quota advice' ($o.Message -notmatch '(?i)more quota')
    # The operator needs Azure's own words either way, or the message is a
    # worse version of the error it replaced.
    Assert 'both carry what Azure said' ($q.Message -match 'InsufficientQuota' -and $o.Message -match 'AuthorizationFailed')
}
else { Assert 'deployment failures are classified' $false 'Get-DeploymentFailureReason missing' }

Write-Host ''
Write-Host 'Model deployment - documentation' -ForegroundColor Cyan

$setup = Join-Path $root 'docs/SETUP.md'
$d = Get-Content $setup -Raw
Assert 'setup explains model selection' ($d -match '(?i)deployment')
Assert 'and that the installer can create one' ($d -match '(?i)deploy a model|create a deployment|deploys it for you')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Model deployment contract holds.' -ForegroundColor Green
exit 0
