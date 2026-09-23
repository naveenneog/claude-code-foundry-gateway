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
        $hostedOn = $null
        if ($_.PSObject.Properties['capabilities'] -and $_.capabilities -and $_.capabilities.PSObject.Properties['hostedOn']) {
            $hostedOn = $_.capabilities.hostedOn
        }
        $isDefault = [bool]($_.PSObject.Properties['isDefaultVersion'] -and $_.isDefaultVersion)
        [pscustomobject]@{
            model    = $_.name
            version  = $_.version
            format   = $_.format
            sku      = $(if ($sku) { $sku.name } else { $null })
            maxUnits = $(if ($sku) { $sku.capacity.maximum } else { $null })
            defaultUnits = $(if ($sku) { $sku.capacity.default } else { $null })
            hostedOn = $hostedOn
            isDefault = $isDefault
        }
    } | Where-Object { $_.sku } |
        # One row per model, and the row is the version Azure marks as the
        # default - not the one whose version string sorts highest.
        #
        # Sorting was the first version of this and it was wrong in a way that
        # matters. A model can be offered twice with different hosting: measured
        # 2026-09-23, claude-haiku-4-5 is published as version 2 (hostedOn azure,
        # isDefaultVersion true) and 20251001 (hostedOn anthropic, isDefaultVersion
        # false). As strings '20251001' sorts above '2', so the picker chose the
        # Anthropic-hosted version - silently moving inference to a different
        # operator, which is exactly what a data protection review asks about. The
        # portal defaults to the Azure-hosted version; so does this now.
        Group-Object model | ForEach-Object {
            $g = @($_.Group)
            $pick = @($g | Where-Object { $_.isDefault })
            if (-not $pick.Count) { $pick = @($g | Where-Object { $_.hostedOn -eq 'azure' }) }
            if (-not $pick.Count) { $pick = @($g | Sort-Object { $_.version } -Descending) }
            $pick[0]
        } | Sort-Object model -Descending)
}

# ARM version that carries modelProviderData on a deployment. Read and written
# at this version; older versions return the deployment without it.
$script:DeploymentApiVersion = '2025-12-01'

function Get-ClaudeProviderData {
    <#
    .SYNOPSIS
        The organisation details Anthropic requires on every Claude deployment,
        copied from a deployment that already has them.

    .DESCRIPTION
        Measured 2026-09-23: Azure refuses an Anthropic model deployment without
        properties.modelProviderData - industry, organizationName and countryCode -
        and fails with InvalidModelProviderData. These are the answers the portal
        asks for the first time Claude is deployed in a subscription.
        `az cognitiveservices account deployment create` has no parameter for
        them, which is why this module now deploys through ARM directly.

        Every existing Claude deployment records the answers, so they are copied
        rather than asked again: first from the target account, then from any
        other account in the subscription. Returns $null when there is none to
        copy, and the caller has to ask.
    #>
    [CmdletBinding()]
    param(
        [string]$Account,
        [string]$ResourceGroup
    )

    $sub = az account show --query id -o tsv 2>$null
    $tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $sub -or -not $tok) { return $null }
    $headers = @{ Authorization = 'Bearer ' + $tok.Trim() }

    $accounts = @()
    if ($Account -and $ResourceGroup) { $accounts += [pscustomobject]@{ name = $Account; rg = $ResourceGroup } }
    $all = az cognitiveservices account list -o json 2>$null | ConvertFrom-Json
    foreach ($a in @($all)) {
        if ($a.name -eq $Account) { continue }
        $accounts += [pscustomobject]@{ name = $a.name; rg = $a.resourceGroup }
    }

    foreach ($a in ($accounts | Select-Object -First 30)) {
        $uri = "https://management.azure.com/subscriptions/$($sub.Trim())/resourceGroups/$($a.rg)/providers/Microsoft.CognitiveServices/accounts/$($a.name)/deployments?api-version=$script:DeploymentApiVersion"
        try { $list = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60 } catch { continue }
        foreach ($d in @($list.value)) {
            if ($d.properties.model.format -ne $script:ClaudeFormat) { continue }
            $pd = $d.properties.modelProviderData
            if ($pd -and $pd.organizationName -and $pd.industry -and $pd.countryCode) {
                return @{
                    organizationName = [string]$pd.organizationName
                    industry         = [string]$pd.industry
                    countryCode      = [string]$pd.countryCode
                    copiedFrom       = "$($a.name)/$($d.name)"
                }
            }
        }
    }
    return $null
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

        Deployed through ARM rather than `az cognitiveservices account deployment
        create`, because Azure now requires modelProviderData on every Anthropic
        deployment and the CLI cannot send it - it fails with
        InvalidModelProviderData, measured 2026-09-23. The provider data is
        copied from an existing Claude deployment when there is one; pass
        -ProviderData when there is not.

    .PARAMETER ProviderData
        A hashtable with organizationName, industry and countryCode - the answers
        Anthropic asks for the first time Claude is deployed in a subscription.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$DeploymentName,
        [string]$Version,
        [string]$Sku = 'GlobalStandard',
        [int]$Capacity = 50,
        [hashtable]$ProviderData,
        [int]$TimeoutSeconds = 600
    )

    if (-not $DeploymentName) { $DeploymentName = $Model }

    # No version given: take the one Azure marks as default, which is the
    # Azure-hosted one where both exist. Leaving it to the service is not the
    # same thing - an explicit version is what makes the result reproducible.
    if (-not $Version) {
        $offer = @(Get-DeployableClaudeModel -Account $Account -ResourceGroup $ResourceGroup | Where-Object { $_.model -eq $Model })
        if ($offer.Count) { $Version = $offer[0].version }
    }
    if (-not $Version) { throw "No deployable version of '$Model' was found on $Account." }

    if (-not $ProviderData) { $ProviderData = Get-ClaudeProviderData -Account $Account -ResourceGroup $ResourceGroup }
    if (-not $ProviderData -or -not $ProviderData.organizationName -or -not $ProviderData.industry -or -not $ProviderData.countryCode) {
        throw ("Deploying '$Model' needs the organisation details Anthropic asks for the first time Claude is " +
               "deployed in a subscription: organizationName, industry and countryCode. None could be copied " +
               "from an existing Claude deployment. Pass -ProviderData @{ organizationName = '<your organisation>'; " +
               "industry = 'technology'; countryCode = 'US' }.")
    }

    $sub = az account show --query id -o tsv 2>$null
    $tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv 2>$null
    if (-not $sub -or -not $tok) { throw 'Not signed in to Azure. Run: az login' }
    $headers = @{ Authorization = 'Bearer ' + $tok.Trim() }
    $uri = "https://management.azure.com/subscriptions/$($sub.Trim())/resourceGroups/$ResourceGroup/providers/" +
           "Microsoft.CognitiveServices/accounts/$Account/deployments/$DeploymentName`?api-version=$script:DeploymentApiVersion"

    $body = @{
        sku        = @{ name = $Sku; capacity = $Capacity }
        properties = @{
            model             = @{ format = $script:ClaudeFormat; name = $Model; version = $Version }
            modelProviderData = @{
                organizationName = $ProviderData.organizationName
                industry         = $ProviderData.industry
                countryCode      = $ProviderData.countryCode
            }
        }
    } | ConvertTo-Json -Depth 6

    try {
        $null = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 120
    }
    catch {
        # PowerShell 5.1 puts the response body in ErrorDetails rather than the
        # exception, and the body is where Azure says why.
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        $why = Get-DeploymentFailureReason -AzureOutput $detail -Model $Model -Account $Account -Sku $Sku -Capacity $Capacity
        throw $why.Message
    }

    # The PUT returns while the deployment is still being created. Returning
    # then would hand the caller a deployment that cannot serve yet, and the
    # first call through the gateway would fail for a reason nobody changed.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = $null
    $current = $null
    do {
        Start-Sleep -Seconds 5
        try { $current = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 60 } catch { $current = $null }
        $state = if ($current) { $current.properties.provisioningState } else { $null }
    } while ($state -notin @('Succeeded', 'Failed', 'Canceled') -and (Get-Date) -lt $deadline)

    if ($state -ne 'Succeeded') {
        throw "Deployment of '$Model' to $Account ended in state '$state' after $TimeoutSeconds seconds."
    }
    return (@($current) | ConvertTo-FlatDeployment)
}
