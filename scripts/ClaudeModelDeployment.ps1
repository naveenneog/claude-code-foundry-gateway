<#
.SYNOPSIS
    Finding, describing and creating Claude model deployments.

.DESCRIPTION
    Dot-source this. Install-ClaudeGateway.ps1 used to assume a Claude
    deployment already existed and stopped with "the gateway fronts a model, it
    cannot create one" when it did not. That is true of the gateway and beside
    the point for the installer, which is already signed in to the subscription
    where the deployment would be made.

    Everything here normalises the Azure CLI shape into flat objects, so the
    selection and formatting logic can be tested without a subscription:

        name      the deployment name - arbitrary, chosen by whoever made it
        model     the model behind it, which is what the gateway allowlists
        version   model version
        format    publisher format; Anthropic for Claude
        sku       GlobalStandard, Standard, ProvisionedManaged
        capacity  units of the SKU
        state     provisioning state

    A deployment may be named anything, so selection matches on the model and
    the format, never on the deployment name.
#>

# Matching on both because either alone is wrong: a deployment of a Claude model
# may be named "prod-1", and a customer may have named an OpenAI deployment
# "claude-replacement". The model name is authoritative; format is the
# cross-check that keeps a badly named OpenAI deployment out.
$script:ClaudeModelPattern = 'claude'
$script:ClaudeFormat = 'Anthropic'

function ConvertTo-FlatDeployment {
    <#
    .SYNOPSIS
        Normalises `az cognitiveservices account deployment list` output.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][AllowNull()]$Deployment)

    process {
        if (-not $Deployment) { return }
        [pscustomobject]@{
            name     = $Deployment.name
            model    = $Deployment.properties.model.name
            version  = $Deployment.properties.model.version
            format   = $Deployment.properties.model.format
            sku      = $Deployment.sku.name
            capacity = $Deployment.sku.capacity
            state    = $Deployment.properties.provisioningState
        }
    }
}

function Select-ClaudeDeployment {
    <#
    .SYNOPSIS
        Keeps only the deployments the gateway can front.

    .DESCRIPTION
        Anything else on the account is somebody else's workload. Offering it
        would produce a gateway that allowlists a model it cannot serve.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyCollection()][AllowNull()]$Deployments)

    $items = @($Deployments) | Where-Object { $_ }
    if (-not $items.Count) { return @() }
    return @($items | Where-Object {
        $_.model -and (
            $_.model -like "*$script:ClaudeModelPattern*" -or
            $_.format -eq $script:ClaudeFormat
        )
    })
}

function Format-ClaudeDeployment {
    <#
    .SYNOPSIS
        One line describing a deployment, with enough to choose between two.

    .DESCRIPTION
        A name alone does not say whether the deployment can carry the traffic.
        SKU and capacity do, and they are the two things an operator changes
        when it cannot.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)]$Deployment)

    $model = if ($Deployment.model -and $Deployment.model -ne $Deployment.name) { " -> $($Deployment.model)" } else { '' }
    $ver = if ($Deployment.version) { " v$($Deployment.version)" } else { '' }
    $cap = if ($null -ne $Deployment.capacity) { "$($Deployment.capacity)" } else { '?' }
    return ("{0}{1}{2}  [{3}, capacity {4}]" -f $Deployment.name, $model, $ver, $Deployment.sku, $cap)
}

function Get-ClaudeDeployment {
    <#
    .SYNOPSIS
        Claude deployments on one Foundry account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][string]$ResourceGroup
    )

    # No --query: a JMESPath with parentheses reaches cmd.exe bare through the
    # az .cmd shim on Windows PowerShell and dies there. Filter in PowerShell.
    $raw = az cognitiveservices account deployment list -n $Account -g $ResourceGroup -o json 2>$null
    if (-not $raw) { return @() }

    $parsed = try { $raw | ConvertFrom-Json } catch { $null }
    if (-not $parsed) { return @() }

    return @(Select-ClaudeDeployment (@($parsed) | ConvertTo-FlatDeployment))
}

function Get-DeployableClaudeModel {
    <#
    .SYNOPSIS
        Claude models this account could deploy, newest first.

    .DESCRIPTION
        Read from the account rather than hard-coded, because what is offerable
        depends on the region and on what the subscription is entitled to. A
        hard-coded list goes stale and then offers a model that cannot be
        created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][string]$ResourceGroup
    )

    $raw = az cognitiveservices account list-models -n $Account -g $ResourceGroup -o json 2>$null
    if (-not $raw) { return @() }
    $parsed = try { $raw | ConvertFrom-Json } catch { $null }
    if (-not $parsed) { return @() }

    $claude = @($parsed | Where-Object {
        $_.name -and ($_.name -like "*$script:ClaudeModelPattern*" -or $_.format -eq $script:ClaudeFormat)
    })

    return @($claude | ForEach-Object {
        # A model may be offered under several SKUs. GlobalStandard is the
        # pay-as-you-go one and is what an accelerator should default to;
        # anything provisioned is a capacity commitment the operator should
        # make deliberately.
        $skus = @($_.skus | Where-Object { $_.name })
        $preferred = @($skus | Where-Object { $_.name -eq 'GlobalStandard' })
        $sku = if ($preferred.Count) { $preferred[0] } elseif ($skus.Count) { $skus[0] } else { $null }
        [pscustomobject]@{
            model    = $_.name
            version  = $_.version
            format   = $_.format
            sku      = $(if ($sku) { $sku.name } else { $null })
            maxUnits = $(if ($sku) { $sku.capacity.maximum } else { $null })
            defaultUnits = $(if ($sku) { $sku.capacity.default } else { $null })
        }
    } | Where-Object { $_.sku } |
        # One row per model. Azure lists every version separately - measured
        # 2026-09-15, claude-sonnet-5 came back as v1 and v2 - and offering the
        # same model twice is a choice nobody wants to make. Newest wins.
        Group-Object model | ForEach-Object {
            @($_.Group | Sort-Object { $_.version } -Descending)[0]
        } | Sort-Object model -Descending)
}

function Get-DeploymentFailureReason {
    <#
    .SYNOPSIS
        Classifies an Azure deployment failure, and writes the message for it.

    .DESCRIPTION
        Quota is the failure worth separating. A subscription can be entirely
        healthy and still refuse, and a generic "deployment failed" sends the
        operator to retry or to check permissions when the answer is a quota
        request, a smaller capacity, or a different region.

        Split out from New-ClaudeDeployment so the classification can be tested
        without a subscription.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$AzureOutput,
        [string]$Model = 'the model',
        [string]$Account = 'the account',
        [string]$Sku = 'GlobalStandard',
        [int]$Capacity = 0
    )

    if ($AzureOutput -match '(?i)quota|InsufficientQuota|exceeded') {
        return [pscustomobject]@{
            Reason  = 'quota'
            Message = ("Deploying '$Model' to $Account failed for quota. The subscription has no room for " +
                       "$Capacity units of $Sku in this region. Ask for more quota, lower -Capacity, or pick " +
                       "another region, then run this again. Azure reported: " + $AzureOutput.Trim())
        }
    }
    return [pscustomobject]@{
        Reason  = 'other'
        Message = ("Deploying '$Model' to $Account failed. Azure reported: " + $AzureOutput.Trim())
    }
}

function New-ClaudeDeployment {
    <#
    .SYNOPSIS
        Creates a deployment and returns it, or throws with the reason.

    .DESCRIPTION
        Quota is the failure worth naming. A subscription can be perfectly
        healthy and still refuse, and "deployment failed" sends the operator to
        the wrong place - the answer is a quota request, not a retry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$DeploymentName,
        [string]$Version,
        [string]$Sku = 'GlobalStandard',
        [int]$Capacity = 50
    )

    if (-not $DeploymentName) { $DeploymentName = $Model }

    # Not $args: that is an automatic variable in PowerShell and assigning to it
    # is at best confusing and at worst silently wrong inside a function.
    $azArgs = @(
        'cognitiveservices', 'account', 'deployment', 'create',
        '-n', $Account, '-g', $ResourceGroup,
        '--deployment-name', $DeploymentName,
        '--model-name', $Model,
        '--model-format', $script:ClaudeFormat,
        '--sku-name', $Sku,
        '--sku-capacity', $Capacity
    )
    if ($Version) { $azArgs += @('--model-version', $Version) }

    $out = & az @azArgs -o json 2>&1
    $joined = ($out | Out-String)

    if ($LASTEXITCODE -ne 0) {
        $why = Get-DeploymentFailureReason -AzureOutput $joined -Model $Model -Account $Account -Sku $Sku -Capacity $Capacity
        throw $why.Message
    }

    $created = try { $joined | ConvertFrom-Json } catch { $null }
    if (-not $created) { throw "Deployment of '$Model' reported success but returned nothing to confirm it." }
    return (@($created) | ConvertTo-FlatDeployment)
}
