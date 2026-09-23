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
Write-Host 'Model deployment - which version, and what Anthropic now requires' -ForegroundColor Cyan

# Behavioural, not textual. A local `az` function shadows the CLI for the rest
# of this script, so the real selection code runs against the exact catalogue
# shape measured on 2026-09-23: claude-haiku-4-5 published twice, version 2
# hosted on Azure and marked default, 20251001 hosted on Anthropic and not.
# As strings '20251001' sorts above '2'; the old picker chose it.
function az {
  $line = $args -join ' '
  if ($line -like 'cognitiveservices account list-models*') {
      return (@(
          @{ name = 'claude-haiku-4-5'; version = '20251001'; format = 'Anthropic'; isDefaultVersion = $false
             capabilities = @{ hostedOn = 'anthropic' }; skus = @(@{ name = 'GlobalStandard'; capacity = @{ default = 10; maximum = 100 } }) },
          @{ name = 'claude-haiku-4-5'; version = '2'; format = 'Anthropic'; isDefaultVersion = $true
             capabilities = @{ hostedOn = 'azure' }; skus = @(@{ name = 'GlobalStandard'; capacity = @{ default = 10; maximum = 100 } }) }
      ) | ConvertTo-Json -Depth 6)
  }
  return $null
}
$offered = @(Get-DeployableClaudeModel -Account 'acct' -ResourceGroup 'rg' | Where-Object { $_.model -eq 'claude-haiku-4-5' })
Assert 'one row per model is offered'                 ($offered.Count -eq 1) "got $($offered.Count)"
Assert 'and it is the version Azure marks as default' ($offered.Count -eq 1 -and $offered[0].version -eq '2') "got $($offered[0].version)"
Assert 'which is the Azure-hosted one'                ($offered.Count -eq 1 -and $offered[0].hostedOn -eq 'azure')

# Anthropic deployments without modelProviderData are refused by Azure with
# InvalidModelProviderData, and the CLI cannot send it. With nothing to copy,
# the call must stop and say which three fields, before touching Azure at all.
function Get-ClaudeProviderData { return $null }
$threw = $null
try { $null = New-ClaudeDeployment -Account 'acct' -ResourceGroup 'rg' -Model 'claude-haiku-4-5' -Version '2' } catch { $threw = $_.Exception.Message }
Assert 'a deployment with no provider data is refused' ([bool]$threw)
Assert 'naming all three fields it needs' ($threw -match 'organizationName' -and $threw -match 'industry' -and $threw -match 'countryCode')
Remove-Item Function:\az -ErrorAction SilentlyContinue
Remove-Item Function:\Get-ClaudeProviderData -ErrorAction SilentlyContinue

$hs = Get-Content $helper -Raw
Assert 'deployments go through ARM, not the CLI that cannot send it' (-not $hs.Contains("'deployment', 'create'"))
Assert 'the provider data is sent'               ($hs -match 'modelProviderData = @\{')
Assert 'at an API version that carries it'       ($hs -match "DeploymentApiVersion = '2025-12-01'")
Assert 'it is copied from an existing deployment first' ($hs -match 'function Get-ClaudeProviderData')
Assert 'the caller waits for the deployment to finish' ($hs -match "notin @\('Succeeded', 'Failed', 'Canceled'\)")
Assert 'PowerShell 5.1 error bodies are read'    ($hs -match 'ErrorDetails\.Message')

$ins = Get-Content $installer -Raw
Assert 'the installer asks for them only when none can be copied' ($ins -match 'if \(-not \$providerData\)')
Assert 'and passes them to the deployment'       ($ins -match '-ProviderData \$providerData')
Assert 'an unattended install can supply them'   ($ins -match '\[string\]\$ModelOrganizationName')
Assert 'the picker shows where a version is hosted' ($ins -match 'hosted on \$\(\$m\.hostedOn\)')

Write-Host ''
Write-Host 'Model deployment - documentation' -ForegroundColor Cyan

$setup = Join-Path $root 'docs/SETUP.md'
$d = Get-Content $setup -Raw
Assert 'setup explains model selection' ($d -match '(?i)deployment')
Assert 'and that the installer can create one' ($d -match '(?i)deploy a model|create a deployment|deploys it for you')
Assert 'setup says which version is offered and why' ($d -match "'20251001'`` sorts above ``'2'")
Assert 'and names the organisation details Azure requires' ($d -match 'InvalidModelProviderData')
# Measured 2026-09-23: an inline JSON body fails through az.cmd on PowerShell
# 7.6 and 5.1; a body file works on both.
Assert 'the manual deployment sends its body from a file' ($d -match "--body '@deployment\.json'" -and $d -notmatch '--body \$body')

Write-Host ''
if ($fail) { Write-Host "$fail assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Model deployment contract holds.' -ForegroundColor Green
exit 0
