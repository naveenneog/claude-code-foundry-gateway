<#
.SYNOPSIS
    Asks for a value a script was not given, from the options discovered in Azure.

.DESCRIPTION
    Dot-source this. When a script cannot work out a value it needs, it should neither
    guess nor just stop. In an interactive session Select-ClaudeChoice lists what it
    discovered, numbered, says where each option comes from and where to look it up, marks
    the one the deployment itself points at, and asks. Enter takes the recommended option.

    Without a console - a pipeline, a scheduled job, the test suite, pwsh -NonInteractive,
    or CLAUDE_NONINTERACTIVE=1 - it takes a recommended option only when the caller says it
    is certain, and otherwise stops with the same options and the parameter to pass.

    A value the deployment recorded (onboarding/claude-gateway.json, CLAUDE_RG, CLAUDE_APIM)
    counts as given: it is used, and where it came from is printed, without a question.
#>

function Test-ClaudeInteractive {
    if ($env:CLAUDE_NONINTERACTIVE -eq '1' -or $env:CI -or $env:TF_BUILD -or $env:GITHUB_ACTIONS) { return $false }
    if (@([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count) { return $false }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    return [Environment]::UserInteractive
}

function New-ClaudeChoiceOption {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [string]$Label,
        [string]$Detail,
        [switch]$Recommended,
        [string]$Reason
    )
    [pscustomobject]@{
        Value       = $Value
        Label       = $(if ($Label) { $Label } else { $Value })
        Detail      = $Detail
        Recommended = [bool]$Recommended
        Reason      = $Reason
    }
}

function Select-ClaudeChoice {
    <#
    .SYNOPSIS
        One value for -Parameter: asked for in a console, refused with the options without one.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Parameter,
        [Parameter(Mandatory = $true)][string]$Question,
        [object[]]$Options = @(),
        [string[]]$WhereToFind = @(),
        [string]$NoneMessage,
        [string]$AmbiguousMessage,
        # The recommended option is certain (the deployment points at it), so a run without a
        # console may take it. Leave this off when the recommendation is only a best guess.
        [switch]$AcceptRecommendedWithoutConsole,
        [object]$Interactive = $null,
        [scriptblock]$Reader = { param($Prompt) Read-Host $Prompt }
    )
    $Options = @($Options | Where-Object { $null -ne $_ })
    $recommended = @($Options | Where-Object { $_.Recommended })
    $console = if ($null -ne $Interactive) { [bool]$Interactive } else { Test-ClaudeInteractive }
    $hint = if ($WhereToFind.Count) { ' Where to find it: ' + ($WhereToFind -join '; ') + '.' } else { '' }
    $passIt = "Pass -$Parameter."

    if (-not $Options.Count) {
        $message = if ($NoneMessage) { $NoneMessage } else { "Nothing was found to choose for -$Parameter." }
        if ($message -notmatch [regex]::Escape("Pass -$Parameter")) { $message = "$message $passIt" }
        throw ($message + $hint)
    }

    if (-not $console) {
        if ($AcceptRecommendedWithoutConsole -and $recommended.Count -eq 1) {
            Write-Host ("  -{0} {1}: {2}" -f $Parameter, $recommended[0].Label, $recommended[0].Reason) -ForegroundColor DarkGray
            return $recommended[0].Value
        }
        $list = ($Options | ForEach-Object { $_.Label }) -join ', '
        $message = "$($Options.Count) candidate(s) for -${Parameter}: $list."
        if ($AmbiguousMessage) { $message = "$message $AmbiguousMessage" }
        if ($message -notmatch [regex]::Escape("Pass -$Parameter")) { $message = "$message $passIt" }
        throw ($message + $hint)
    }

    Write-Host ''
    Write-Host $Question -ForegroundColor Cyan
    $number = 0
    foreach ($option in $Options) {
        $number++
        $tag = if ($option.Recommended) { ' [recommended]' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f $number, $option.Label, $tag)
        if ($option.Recommended -and $option.Reason) { Write-Host ("     {0}" -f $option.Reason) -ForegroundColor DarkGray }
        if ($option.Detail) { Write-Host ("     {0}" -f $option.Detail) -ForegroundColor DarkGray }
    }
    if ($WhereToFind.Count) {
        Write-Host '  Where to find it:' -ForegroundColor DarkGray
        foreach ($line in $WhereToFind) { Write-Host ("    {0}" -f $line) -ForegroundColor DarkGray }
    }
    $default = 0
    if ($recommended.Count -eq 1) { $default = [array]::IndexOf($Options, $recommended[0]) + 1 }
    $prompt = if ($default) { "Choose 1-$($Options.Count) (Enter for $default, q to stop)" } else { "Choose 1-$($Options.Count) (q to stop)" }
    while ($true) {
        $answer = ([string](& $Reader $prompt)).Trim()
        if (-not $answer -and $default) { return $Options[$default - 1].Value }
        if ($answer -eq 'q' -or $answer -eq 'quit') { throw ("Stopped: no -$Parameter was chosen. $passIt" + $hint) }
        $picked = 0
        if ([int]::TryParse($answer, [ref]$picked) -and $picked -ge 1 -and $picked -le $Options.Count) {
            return $Options[$picked - 1].Value
        }
        Write-Host ("  Type a number from 1 to {0}." -f $Options.Count) -ForegroundColor Yellow
    }
}

function Select-ClaudeResourceGroup {
    <#
    .SYNOPSIS
        The gateway's resource group, from the resource groups that hold API Management.
    #>
    param([object]$Interactive = $null, [scriptblock]$Reader)
    $rows = az apim list --query "[].{name:name,group:resourceGroup}" -o json 2>$null | ConvertFrom-Json
    $groups = @($rows | Group-Object group | Sort-Object Name)
    $options = foreach ($g in $groups) {
        New-ClaudeChoiceOption -Value $g.Name -Detail ('API Management: ' + (($g.Group | ForEach-Object { $_.name }) -join ', '))
    }
    $choice = @{
        Parameter   = 'ResourceGroup'
        Question    = 'Which resource group holds the Claude gateway?'
        Options     = @($options)
        WhereToFind = @(
            'Install-ClaudeGateway.ps1 records it in onboarding/claude-gateway.json; CLAUDE_RG overrides it'
            'Azure portal: API Management services > the gateway > Overview > Resource group'
            'az apim list --query "[].{name:name, group:resourceGroup}" -o table'
        )
        NoneMessage = 'No API Management instance is visible in this subscription (az account show).'
        Interactive = $Interactive
    }
    if ($Reader) { $choice.Reader = $Reader }
    Select-ClaudeChoice @choice
}

function Select-ClaudeGateway {
    <#
    .SYNOPSIS
        The gateway's API Management name in a resource group; the recorded one is recommended.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [string]$ScriptRoot = $PSScriptRoot,
        [object]$Interactive = $null,
        [scriptblock]$Reader
    )
    $recorded = [string](& (Join-Path $ScriptRoot 'Get-ClaudeGatewayTarget.ps1') ApimName 3>$null)
    $names = @((az apim list -g $ResourceGroup --query "[].name" -o tsv 2>$null) -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    # A gateway the installer recorded counts as given: say where it came from, do not ask.
    $match = @($names | Where-Object { $recorded -and $_ -ieq $recorded })
    if ($match.Count -eq 1) {
        Write-Host ("  -ApimName {0}: recorded by the installer (onboarding/claude-gateway.json, or CLAUDE_APIM)" -f $match[0]) -ForegroundColor DarkGray
        return $match[0]
    }
    if ($recorded) {
        Write-Host ("  The recorded gateway {0} is not in {1}; choose from what is there." -f $recorded, $ResourceGroup) -ForegroundColor Yellow
    }
    $options = foreach ($name in $names) {
        if ($names.Count -eq 1) {
            New-ClaudeChoiceOption -Value $name -Recommended -Reason "the only API Management instance in $ResourceGroup"
        }
        else { New-ClaudeChoiceOption -Value $name }
    }
    $choice = @{
        Parameter   = 'ApimName'
        Question    = "Which API Management instance in $ResourceGroup is the Claude gateway?"
        Options     = @($options)
        WhereToFind = @(
            'Install-ClaudeGateway.ps1 records it in onboarding/claude-gateway.json; CLAUDE_APIM overrides it'
            "Azure portal: Resource groups > $ResourceGroup, resources of type API Management service"
            "az apim list -g $ResourceGroup --query [].name -o tsv"
        )
        NoneMessage = "No API Management instance in $ResourceGroup."
        Interactive = $Interactive
        AcceptRecommendedWithoutConsole = $true
    }
    if ($Reader) { $choice.Reader = $Reader }
    Select-ClaudeChoice @choice
}

function Select-ClaudeWorkspace {
    <#
    .SYNOPSIS
        The ARM id of the Log Analytics workspace that holds the gateway's telemetry.

    .DESCRIPTION
        Recommends the workspace linked to the gateway's Application Insights, which is where
        its telemetry lands, and offers the other workspaces in the resource group beside it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [string]$ApimName,
        [string]$AmbiguousMessage,
        [string]$ScriptRoot = $PSScriptRoot,
        [string]$TelemetryScript,
        [object]$Interactive = $null,
        [scriptblock]$Reader
    )
    if (-not $TelemetryScript) { $TelemetryScript = Join-Path $ScriptRoot 'Get-ClaudeTelemetry.ps1' }
    $linked = $null
    $appInsights = $null
    try {
        $telemetryArgs = @{ ResourceGroup = $ResourceGroup }
        if ($ApimName) { $telemetryArgs.ApimName = $ApimName }
        if ($null -ne $Interactive) { $telemetryArgs.Interactive = $Interactive }
        $telemetry = & $TelemetryScript @telemetryArgs 3>$null
        $linked = [string]$telemetry.WorkspaceResourceId
        $appInsights = [string]$telemetry.AppInsights
    }
    catch {
        Write-Host ("  The gateway's Application Insights link could not be read: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
    }

    $options = @()
    if ($linked) {
        $options += New-ClaudeChoiceOption -Value $linked -Label ('{0} ({1})' -f ($linked -split '/')[-1], ($linked -split '/')[4]) `
            -Recommended -Reason "linked to the gateway's Application Insights $appInsights, which is where its telemetry lands"
    }
    $ids = @((az monitor log-analytics workspace list -g $ResourceGroup --query "[].id" -o tsv 2>$null) -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($id in $ids) {
        if ($linked -and $id -ieq $linked) { continue }
        $detail = if ($linked) { "in $ResourceGroup, but not linked to the gateway's Application Insights" } else { $null }
        $options += New-ClaudeChoiceOption -Value $id -Label ('{0} ({1})' -f ($id -split '/')[-1], $ResourceGroup) -Detail $detail
    }
    if (-not $linked -and $options.Count -eq 1) {
        $options[0].Recommended = $true
        $options[0].Reason = "the only Log Analytics workspace in $ResourceGroup"
    }
    $choice = @{
        Parameter        = 'WorkspaceName'
        Question         = "Which Log Analytics workspace holds the gateway's telemetry?"
        Options          = $options
        WhereToFind      = @(
            './scripts/Get-ClaudeTelemetry.ps1 prints it as Workspace'
            "Azure portal: API Management > Monitoring > Application Insights names the gateway's Application Insights; open it > Overview > Workspace"
        )
        NoneMessage      = "No Log Analytics workspace in '$ResourceGroup', and none is linked to the gateway's Application Insights."
        AmbiguousMessage = $AmbiguousMessage
        Interactive      = $Interactive
        AcceptRecommendedWithoutConsole = $true
    }
    if ($Reader) { $choice.Reader = $Reader }
    Select-ClaudeChoice @choice
}

function Select-ClaudeFoundryAccount {
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [string]$ApimName,
        [string]$Kind,
        [object]$Interactive = $null,
        [scriptblock]$Reader
    )
    $discovered = az cognitiveservices account list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
    $accounts = @($discovered | Where-Object { $_.name -and (-not $Kind -or $_.kind -eq $Kind) })
    $backend = $null
    if ($ApimName) {
        try {
            $url = az apim api show -g $ResourceGroup --service-name $ApimName --api-id claude-foundry --query serviceUrl -o tsv 2>$null
            $parsed = $null
            if ([uri]::TryCreate([string]$url, [UriKind]::Absolute, [ref]$parsed)) { $backend = $parsed.Host }
        }
        catch { Write-Verbose 'The gateway backend could not be read; offering the discovered accounts.' }
    }
    $linked = @($accounts | Where-Object {
        $hosts = @()
        $endpoints = @($_.properties.endpoint)
        if ($_.properties.endpoints) { $endpoints += @($_.properties.endpoints.PSObject.Properties | ForEach-Object { $_.Value }) }
        foreach ($endpoint in $endpoints) {
            $parsed = $null
            if ($endpoint -and [uri]::TryCreate([string]$endpoint, [UriKind]::Absolute, [ref]$parsed)) { $hosts += $parsed.Host }
        }
        $backend -and ($hosts -contains $backend -or
            ($_.properties.customSubDomainName -and ($backend -split '\.')[0] -ieq $_.properties.customSubDomainName) -or
            (-not $hosts.Count -and ($backend -split '\.')[0] -ieq $_.name))
    })
    $options = foreach ($account in $accounts) {
        $recommended = ($linked.Count -eq 1 -and $linked[0].name -eq $account.name) -or $accounts.Count -eq 1
        $reason = if ($linked.Count -eq 1 -and $linked[0].name -eq $account.name) {
            "the gateway $ApimName backend points at this account's endpoint"
        } elseif ($accounts.Count -eq 1) { "the only matching Cognitive Services account in $ResourceGroup" } else { '' }
        New-ClaudeChoiceOption -Value $account.name -Detail ("az cognitiveservices account list: {0}, {1}, {2}" -f $ResourceGroup, $account.kind, $account.location) `
            -Recommended:$recommended -Reason $reason
    }
    $choice = @{
        Parameter = 'FoundryAccount'; Question = "Which Foundry account in $ResourceGroup?"
        Options = @($options); Interactive = $Interactive; AcceptRecommendedWithoutConsole = $true
        NoneMessage = "No matching Cognitive Services account is visible in $ResourceGroup."
        WhereToFind = @(
            "az cognitiveservices account list -g $ResourceGroup -o table"
            "az apim api show -g $ResourceGroup --service-name $ApimName --api-id claude-foundry --query serviceUrl -o tsv"
            "Azure portal: Resource groups > $ResourceGroup > Foundry resource > Keys and Endpoint; API Management > APIs > claude-foundry > Settings > Web service URL"
        )
    }
    if ($Reader) { $choice.Reader = $Reader }
    Select-ClaudeChoice @choice
}

function Select-ClaudeTurnstileResourceGroup {
    param(
        [string]$ResourceGroup,
        [string]$ApimName,
        $Integration,
        [object]$Interactive = $null,
        [scriptblock]$Reader
    )
    if ($Integration -and $Integration.resourceGroup) {
        Write-Host ("  -TurnstileResourceGroup {0}: recorded in {1}'s turnstile-integration named value" -f $Integration.resourceGroup, $ApimName) -ForegroundColor DarkGray
        return [string]$Integration.resourceGroup
    }
    $apps = az webapp list --query "[].{name:name,resourceGroup:resourceGroup}" -o json 2>$null | ConvertFrom-Json
    $groups = @($apps | Where-Object { $_.resourceGroup } | Group-Object resourceGroup | Sort-Object Name)
    $options = foreach ($group in $groups) {
        New-ClaudeChoiceOption -Value $group.Name -Detail ('az webapp list: ' + (($group.Group | ForEach-Object { $_.name }) -join ', ')) `
            -Recommended:($groups.Count -eq 1) -Reason 'the only resource group with a visible web app; the connection step verifies its Turnstile settings'
    }
    $choice = @{
        Parameter = 'TurnstileResourceGroup'; Question = 'Which resource group contains your Turnstile deployment?'
        Options = @($options); Interactive = $Interactive; AcceptRecommendedWithoutConsole = $true
        NoneMessage = 'No web app resource group is visible. Check the Turnstile deployment and the selected subscription.'
        WhereToFind = @(
            "az apim nv show -g $ResourceGroup --service-name $ApimName --named-value-id turnstile-integration --query value -o tsv"
            'az webapp list --query "[].{name:name,resourceGroup:resourceGroup}" -o table'
            'Azure portal: API Management > Named values > turnstile-integration > resourceGroup; or the Turnstile App Service > Overview > Resource group'
        )
    }
    if ($Reader) { $choice.Reader = $Reader }
    Select-ClaudeChoice @choice
}

function Select-ClaudeBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [string]$Pattern = '*.zip',
        [string]$Parameter = 'Path',
        [object]$Interactive = $null,
        [scriptblock]$Reader
    )
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter $Pattern -File -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, Name)
    $options = for ($i = 0; $i -lt $files.Count; $i++) {
        $file = $files[$i]
        New-ClaudeChoiceOption -Value $file.FullName -Label $file.Name `
            -Detail ("{0}; modified {1:u} UTC; {2} bytes" -f $file.DirectoryName, $file.LastWriteTimeUtc, $file.Length) `
            -Recommended:($i -eq 0) -Reason 'newest modified archive in this folder; check the source machine before restoring'
    }
    $choice = @{
        Parameter = $Parameter; Question = "Which $Pattern backup should be restored?"
        Options = @($options); Interactive = $Interactive
        AcceptRecommendedWithoutConsole = ($files.Count -eq 1)
        NoneMessage = "No $Pattern backups in '$Folder'. Pass -Folder to say where they are."
        WhereToFind = @(
            "Get-ChildItem -LiteralPath '$Folder' -Filter '$Pattern' | Sort-Object LastWriteTimeUtc -Descending"
            "File Explorer: $Folder (local archives, not an Azure portal resource)"
            'Migrate-ClaudeWorkstation.ps1 -Backup -Folder <folder> creates the archives on the source machine'
        )
    }
    if ($Reader) { $choice.Reader = $Reader }
    Select-ClaudeChoice @choice
}
