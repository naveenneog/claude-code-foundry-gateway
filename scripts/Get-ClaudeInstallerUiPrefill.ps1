param([ValidateSet('subscriptions','foundryAccounts','deployments')][string]$Kind = 'subscriptions', [string]$SubscriptionId, [string]$FoundryAccount, [string]$FoundryResourceGroup)
$ErrorActionPreference = 'Stop'
$env:NO_COLOR = '1'
$env:PSSTYLE_OUTPUT_RENDERING = 'PlainText'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }
function Write-PrefillError([string]$Field, [string]$Message, [string]$PatternMessage, [string]$Remedy) {
    [pscustomobject]@{
        schemaVersion = 1
        subscriptions = @()
        foundryAccounts = @()
        deployments = @()
        field = $Field
        error = $Message
        patternMessage = $PatternMessage
        remedy = $Remedy
    } | ConvertTo-Json -Compress -Depth 6
    exit 0
}
function Assert-Match([string]$Name, [string]$Value, [string]$Pattern, [string]$PatternMessage, [string]$Remedy) {
    if ($Value -and $Value -notmatch $Pattern) { Write-PrefillError $Name "$Name is not valid for installer UI prefill." $PatternMessage $Remedy }
}
function Assert-Required([string]$Name, [string]$Value, [string]$Remedy) {
    if (-not $Value) { Write-PrefillError $Name "$Name is required for installer UI prefill." 'is required' $Remedy }
}
Assert-Match SubscriptionId $SubscriptionId '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' 'is not a subscription GUID' 'Give the Azure subscription id.'
Assert-Match FoundryAccount $FoundryAccount '^[A-Za-z0-9][A-Za-z0-9-]{1,63}$' 'is not a Foundry account name (2 to 64 letters, digits and hyphens)' 'Give the Foundry account name.'
Assert-Match FoundryResourceGroup $FoundryResourceGroup '^[A-Za-z0-9._()-]{1,90}$' 'is not a resource group name (up to 90 letters, digits and . _ ( ) -)' 'Give the Foundry account resource group.'
if ($Kind -eq 'deployments') {
    Assert-Required FoundryAccount $FoundryAccount 'Choose or type a Foundry account before reading deployments.'
    Assert-Required FoundryResourceGroup $FoundryResourceGroup 'Choose or type the Foundry account resource group before reading deployments.'
}
$result = [ordered]@{ schemaVersion = 1; subscriptions = @(); foundryAccounts = @(); deployments = @() }
try {
    if ($Kind -eq 'subscriptions') {
        $azOutput = & az account list -o json 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($azOutput | ForEach-Object { [string]$_ }) -join "`n") }
        $result.subscriptions = @($azOutput | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ id = [string]$_.id; name = [string]$_.name; tenantId = [string]$_.tenantId } })
    }
    elseif ($Kind -eq 'foundryAccounts') {
        $azArgs = @('cognitiveservices','account','list','-o','json')
        if ($SubscriptionId) { $azArgs += @('--subscription', $SubscriptionId) }
        $azOutput = & az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($azOutput | ForEach-Object { [string]$_ }) -join "`n") }
        $result.foundryAccounts = @($azOutput | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; resourceGroup = [string]$_.resourceGroup; location = [string]$_.location } })
    }
    elseif ($Kind -eq 'deployments') {
        $azArgs = @('cognitiveservices','account','deployment','list','-g',$FoundryResourceGroup,'-n',$FoundryAccount,'-o','json')
        if ($SubscriptionId) { $azArgs += @('--subscription', $SubscriptionId) }
        $azOutput = & az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw (($azOutput | ForEach-Object { [string]$_ }) -join "`n") }
        $result.deployments = @($azOutput | ConvertFrom-Json | ForEach-Object { [pscustomobject]@{ name = [string]$_.name; model = [string]$_.properties.model.name; version = [string]$_.properties.model.version } })
    }
}
catch { $result.error = $_.Exception.Message }
$result | ConvertTo-Json -Compress -Depth 6
