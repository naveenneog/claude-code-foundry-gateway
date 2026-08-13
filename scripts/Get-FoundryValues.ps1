<#
.SYNOPSIS
    Discovers every value needed to configure Claude Code for Microsoft Foundry.

.DESCRIPTION
    Prints your subscription, tenant, signed-in account, Foundry resource, resource
    group, Anthropic endpoint, Claude deployment names and data-plane role
    assignment — each with the command that produced it.

    If no resource is supplied, every Foundry (AIServices) account in the current
    subscription is scanned and the ones with Anthropic deployments are reported.

    Use -Mask when screenshotting or pasting into a ticket: identifiers are partially
    redacted while staying recognisable.

.PARAMETER Resource
    Foundry (AIServices) account name. Omit to auto-discover.

.PARAMETER ResourceGroup
    Resource group of that account. Optional.

.PARAMETER Mask
    Partially redact identifiers in the output.

.EXAMPLE
    .\Get-FoundryValues.ps1
    .\Get-FoundryValues.ps1 -Resource ai-contoso... -ResourceGroup rg-contoso... -Mask
#>
[CmdletBinding()]
param(
    [string]$Resource,
    [string]$ResourceGroup,
    [switch]$Mask
)

$ErrorActionPreference = 'Stop'

function Hide-Middle {
    param([string]$Value, [int]$Keep = 4)
    if (-not $Mask -or [string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -le ($Keep * 2)) { return ('*' * $Value.Length) }
    $head = $Value.Substring(0, $Keep)
    $tail = $Value.Substring($Value.Length - $Keep)
    return "$head$('*' * 6)$tail"
}

function Hide-Upn {
    param([string]$Value)
    if (-not $Mask -or [string]::IsNullOrEmpty($Value)) { return $Value }
    $parts = $Value -split '@', 2
    if ($parts.Count -ne 2) { return (Hide-Middle $Value 2) }
    $name = $parts[0]
    $shown = if ($name.Length -le 2) { $name } else { $name[0] + ('*' * ($name.Length - 2)) + $name[-1] }
    return "$shown@$($parts[1])"
}

function Write-Field {
    param([string]$Label, [string]$Value, [string]$Command)
    Write-Host ("  {0,-22} " -f "$Label :") -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor White
    if ($Command) { Write-Host ("  {0,-22} {1}" -f '', $Command) -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "Values needed to configure Claude Code for Microsoft Foundry" -ForegroundColor Cyan
if ($Mask) { Write-Host "(masked for sharing - rerun without -Mask for the real values)" -ForegroundColor DarkYellow }
Write-Host ""

# --- Account ---------------------------------------------------------------
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Write-Host "Not signed in. Run 'az login'." -ForegroundColor Red; exit 1 }

Write-Host "ACCOUNT" -ForegroundColor Yellow
Write-Field 'Signed-in user'  (Hide-Upn $acct.user.name)  'az account show --query user.name -o tsv'
Write-Field 'Subscription ID' (Hide-Middle $acct.id 8)    'az account show --query id -o tsv'
Write-Field 'Tenant ID'       (Hide-Middle $acct.tenantId 8) 'az account show --query tenantId -o tsv'
Write-Host ""

# --- Resource discovery ----------------------------------------------------
if (-not $Resource) {
    Write-Host "FOUNDRY RESOURCES WITH CLAUDE DEPLOYMENTS" -ForegroundColor Yellow
    Write-Host "  scanning AIServices accounts in this subscription..." -ForegroundColor DarkGray

    $accounts = az cognitiveservices account list -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.kind -eq 'AIServices' }

    $found = @()
    foreach ($a in $accounts) {
        $deps = az cognitiveservices account deployment list -n $a.name -g $a.resourceGroup -o json 2>$null |
            ConvertFrom-Json
        $claude = @($deps | Where-Object { $_.properties.model.format -eq 'Anthropic' })
        if ($claude.Count -gt 0) {
            $found += [pscustomobject]@{ Account = $a; Claude = $claude }
        }
    }

    if ($found.Count -eq 0) {
        Write-Host "  none found - deploy a Claude model first (Step 1)." -ForegroundColor Red
        exit 1
    }

    foreach ($f in $found) {
        Write-Host ("  {0}  [{1}]  {2}" -f (Hide-Middle $f.Account.name 6), (Hide-Middle $f.Account.resourceGroup 4), $f.Account.location) -ForegroundColor White
        Write-Host ("      deployments: {0}" -f (($f.Claude.name) -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host ""

    $Resource = $found[0].Account.name
    $ResourceGroup = $found[0].Account.resourceGroup
    Write-Host ("  using: {0}" -f (Hide-Middle $Resource 6)) -ForegroundColor DarkCyan
    Write-Host ""
}

if (-not $ResourceGroup) {
    $ResourceGroup = az cognitiveservices account list -o json 2>$null | ConvertFrom-Json |
        Where-Object { $_.name -eq $Resource } | Select-Object -First 1 -ExpandProperty resourceGroup
}

$account = az cognitiveservices account show -n $Resource -g $ResourceGroup -o json | ConvertFrom-Json

Write-Host "RESOURCE" -ForegroundColor Yellow
Write-Field 'Resource name'  (Hide-Middle $Resource 6)      'az cognitiveservices account list --query "[?kind==``AIServices``].name" -o tsv'
Write-Field 'Resource group' (Hide-Middle $ResourceGroup 4) 'az cognitiveservices account list --query "[].resourceGroup" -o tsv'
Write-Field 'Region'         $account.location              'az cognitiveservices account show -n <res> -g <rg> --query location -o tsv'
Write-Field 'Kind'           $account.kind                  'az cognitiveservices account show -n <res> -g <rg> --query kind -o tsv'
Write-Host ""

Write-Host "ENDPOINT  (this is what ANTHROPIC_FOUNDRY_RESOURCE expands to)" -ForegroundColor Yellow
Write-Field 'Anthropic base' ("https://{0}.services.ai.azure.com/anthropic" -f (Hide-Middle $Resource 6))
Write-Field 'Messages API'   ("https://{0}.services.ai.azure.com/anthropic/v1/messages" -f (Hide-Middle $Resource 6))
Write-Host ""

# --- Deployments -----------------------------------------------------------
Write-Host "DEPLOYMENT NAMES  (use these for the model aliases)" -ForegroundColor Yellow
$deps = az cognitiveservices account deployment list -n $Resource -g $ResourceGroup -o json | ConvertFrom-Json
$claude = @($deps | Where-Object { $_.properties.model.format -eq 'Anthropic' })
if ($claude.Count -eq 0) {
    Write-Host "  none - no Anthropic deployments on this resource." -ForegroundColor Red
}
else {
    foreach ($d in $claude) {
        Write-Host ("  {0,-22} model={1} v{2} sku={3}" -f $d.name, $d.properties.model.name, $d.properties.model.version, $d.sku.name) -ForegroundColor White
    }
}
Write-Host ("  {0,-22} {1}" -f '', 'az cognitiveservices account deployment list -n <res> -g <rg> -o table') -ForegroundColor DarkGray
Write-Host ""

# --- RBAC ------------------------------------------------------------------
Write-Host "DATA-PLANE ROLE  (Cognitive Services User is required)" -ForegroundColor Yellow
$scope = $account.id
$oid = az ad signed-in-user show --query id -o tsv 2>$null
$roles = az role assignment list --assignee $oid --scope $scope --include-inherited -o json 2>$null | ConvertFrom-Json
$names = @($roles | Select-Object -ExpandProperty roleDefinitionName -Unique)

if ($names -contains 'Cognitive Services User') {
    Write-Host "  Cognitive Services User : PRESENT" -ForegroundColor Green
}
else {
    Write-Host "  Cognitive Services User : MISSING  <- inference will return HTTP 401" -ForegroundColor Red
}
Write-Host ("  other roles here        : {0}" -f (($names | Where-Object { $_ -ne 'Cognitive Services User' }) -join ', ')) -ForegroundColor DarkGray
if ($Mask) {
    Write-Field 'Scope' '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<resource>'
}
else {
    Write-Field 'Scope' $scope
}
Write-Host ("  {0,-22} {1}" -f '', 'az role assignment list --assignee <you> --scope <scope> --include-inherited -o table') -ForegroundColor DarkGray
Write-Host ""

# --- Resulting config ------------------------------------------------------
$sonnet = ($claude | Where-Object { $_.name -like '*sonnet*' } | Select-Object -First 1).name
$opus   = ($claude | Where-Object { $_.name -like '*opus*' }   | Select-Object -First 1).name
$haiku  = ($claude | Where-Object { $_.name -like '*haiku*' }  | Select-Object -First 1).name
if (-not $haiku) { $haiku = $sonnet }

Write-Host "RESULTING CONFIG" -ForegroundColor Yellow
Write-Host '  {' -ForegroundColor DarkGray
Write-Host '    "env": {' -ForegroundColor DarkGray
Write-Host '      "CLAUDE_CODE_USE_FOUNDRY": "1",' -ForegroundColor White
Write-Host ('      "ANTHROPIC_FOUNDRY_RESOURCE": "{0}",' -f (Hide-Middle $Resource 6)) -ForegroundColor White
Write-Host ('      "ANTHROPIC_DEFAULT_OPUS_MODEL": "{0}",' -f $opus) -ForegroundColor White
Write-Host ('      "ANTHROPIC_DEFAULT_SONNET_MODEL": "{0}",' -f $sonnet) -ForegroundColor White
Write-Host ('      "ANTHROPIC_DEFAULT_HAIKU_MODEL": "{0}"' -f $haiku) -ForegroundColor White
Write-Host '    }' -ForegroundColor DarkGray
Write-Host '  }' -ForegroundColor DarkGray
Write-Host ""
