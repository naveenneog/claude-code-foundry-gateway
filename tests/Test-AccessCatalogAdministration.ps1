param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert($Name, $Condition, $Detail = '') {
    $script:assertions++
    if ($Condition) { Write-Host "  [OK] $Name" }
    else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" }
}
function Capture([scriptblock]$Action) {
    $script:CapturedError = ''
    $script:CapturedResult = $null
    try { $script:CapturedResult = @(& $Action 6>&1) }
    catch { $script:CapturedError = $_.Exception.Message }
}

$helperPath = Join-Path $root 'scripts\ClaudeAccessCatalogAdministration.ps1'
$commandPath = Join-Path $root 'scripts\Set-ClaudeAccessCatalog.ps1'
$catalogPath = Join-Path ([IO.Path]::GetTempPath()) ('p116-catalog-' + [guid]::NewGuid().ToString('N') + '.json')
$catalog = [ordered]@{
    schemaVersion = 1
    tenantId = '11111111-2222-4333-8444-555555555555'
    plans = @([ordered]@{
        id = 'developer'; name = 'Developer'; enabled = $true
        nominalCredit = [ordered]@{ amount = 100; currency = 'USD'; period = 'month'; scope = 'user' }
        compatibilityTier = 'standard'
    })
    profiles = @([ordered]@{
        id = 'developer-code'; name = 'Developer Code'; planId = 'developer'
        groupObjectId = '99999999-8888-4777-8666-555555555555'; priority = 10
        capabilities = @('code'); modelFamilies = @('sonnet'); connectors = @(); enabled = $true
    })
}
[IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

try {
    . $helperPath

    $command = Get-Command $commandPath
    Assert 'the command requires ResourceGroup, ApimName and Path' (
        @('ResourceGroup','ApimName','Path' | Where-Object {
            $parameter = $command.Parameters[$_]
            $parameter -and @($parameter.Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count
        }).Count -eq 3)
    Assert 'the command exposes standard WhatIf semantics' ($command.Parameters.ContainsKey('WhatIf'))

    Capture {
        Invoke-ClaudeAccessCatalogLocalValidation -Path $catalogPath -TenantId '11111111-2222-4333-8444-555555555555'
    }
    $realValidation = @($CapturedResult | Where-Object { $_ -and $_.PSObject.Properties['catalogVersion'] } | Select-Object -Last 1)
    Assert 'the PowerShell validation boundary runs the Node canonical validator' (
        -not $CapturedError -and $realValidation.plans -eq 1 -and $realValidation.profiles -eq 1 -and
        [string]$realValidation.catalogVersion -match '^sha256:[0-9a-f]{64}$') "$CapturedError | $($CapturedResult -join ' | ')"
    Capture {
        Invoke-ClaudeAccessCatalogLocalValidation -Path $catalogPath -TenantId 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    }
    Assert 'the PowerShell validation boundary redacts a tenant mismatch' (
        $CapturedError -match 'stage tenant' -and $CapturedError -notmatch '11111111|aaaaaaaa') $CapturedError

    $global:P116Calls = [Collections.Generic.List[string]]::new()
    $global:P116Validation = [pscustomobject]@{
        ok = $true; mode = 'validate'; plans = 1; profiles = 1
        catalogVersion = 'sha256:' + ('a' * 64)
    }
    $global:P116RunnerResult = '{"ok":true,"mode":"publish","status":"created","plans":1,"profiles":1,"catalogVersion":"sha256:' + ('a' * 64) + '","backup":false}'
    function az {
        $words = @($args)
        $line = $words -join ' '
        $global:P116Calls.Add("az $line")
        $global:LASTEXITCODE = 0
        if ($line -like 'apim show*') {
            return '{"id":"/subscriptions/22222222-3333-4444-8555-666666666666/resourceGroups/rg-p116/providers/Microsoft.ApiManagement/service/apim-p116","identity":{"tenantId":"11111111-2222-4333-8444-555555555555","principalId":"77777777-6666-4555-8444-333333333333"}}'
        }
        if ($line -like 'apim nv show*entitlement-projection-prefix*') { return 'p116fixture' }
        throw "unexpected az call: $line"
    }
    function Invoke-ClaudeAccessCatalogLocalValidation {
        param($Path, $TenantId)
        $global:P116Calls.Add("validate $Path tenant-bound")
        return $global:P116Validation
    }
    function New-ClaudeProjectionSyncArchive {
        param($Path, $Root)
        $global:P116Calls.Add("archive $Path")
        [IO.File]::WriteAllText($Path, 'fixture')
        return $Path
    }
    function Start-ClaudeProjectionRunner {
        param($ResourceGroup, $Name, $SubscriptionId)
        $global:P116Calls.Add("start $ResourceGroup $Name $SubscriptionId")
    }
    function Send-RunnerFile {
        param($ResourceGroup, $Name, $Path, $Destination, $SubscriptionId)
        $global:P116Calls.Add("send $Destination")
    }
    function Invoke-RunnerCommand {
        param($ResourceGroup, $Name, $Command, $SubscriptionId)
        $global:P116Calls.Add("exec $Command")
        if ($Command -match 'administer-access-catalog\.mjs') { return $global:P116RunnerResult }
        return ''
    }

    $global:P116Calls.Clear()
    Capture {
        Invoke-ClaudeAccessCatalogAdministration -ResourceGroup rg-p116 -ApimName apim-p116 -Path $catalogPath -WhatIf
    }
    $whatIfText = (@($CapturedResult) | ForEach-Object { [string]$_ }) -join "`n"
    $whatIfCalls = $global:P116Calls -join "`n"
    Assert 'WhatIf validates and discovers the private projection' (
        -not $CapturedError -and $whatIfCalls -match '(?m)^validate ' -and
        $whatIfCalls -match 'az apim show' -and $whatIfCalls -match 'entitlement-projection-prefix') "$CapturedError | $whatIfCalls"
    Assert 'WhatIf prints plan, profile and canonical hash evidence' (
        $whatIfText -match 'plans=1' -and $whatIfText -match 'profiles=1' -and
        $whatIfText -match ('sha256:' + ('a' * 64))) $whatIfText
    Assert 'WhatIf does not start, transfer to or execute in the runner' (
        $whatIfCalls -notmatch '(?m)^(start|send|exec|archive) ') $whatIfCalls

    $global:P116Calls.Clear()
    Capture {
        Invoke-ClaudeAccessCatalogAdministration -ResourceGroup rg-p116 -ApimName apim-p116 -Path $catalogPath
    }
    $normalCalls = $global:P116Calls -join "`n"
    Assert 'normal mode reuses the package, runner lifecycle and file-transfer helpers' (
        -not $CapturedError -and $normalCalls -match '(?m)^archive ' -and
        $normalCalls -match '(?m)^start rg-p116 aci-projtest-p116fixture 22222222-3333-4444-8555-666666666666$' -and
        $normalCalls -match '(?m)^send /work/sync-source\.tar\.gz$' -and
        $normalCalls -match '(?m)^send /work/access-catalog\.json$') "$CapturedError | $normalCalls"
    Assert 'the writer uses managed identity against the same private claude entitlement container' (
        $normalCalls -match 'node /work/sync/src/administer-access-catalog\.mjs ' -and
        $normalCalls -match '--cosmos https://cosmos-p116fixture\.documents\.azure\.com:443/' -and
        $normalCalls -match '--database claude --container entitlement' -and
        $normalCalls -match '--account-resource-id /subscriptions/22222222-3333-4444-8555-666666666666/resourceGroups/rg-p116/providers/Microsoft\.DocumentDB/databaseAccounts/cosmos-p116fixture') $normalCalls
    $mutableAzure = @($global:P116Calls | Where-Object {
        $_ -match '^az ' -and $_ -notmatch '^az apim (show|nv show)\b'
    })
    Assert 'catalog administration makes no Entra or APIM mutation' (
        $mutableAzure.Count -eq 0 -and $normalCalls -notmatch '\bad (group|user|sp)\b|apim nv (create|update|delete)|role assignment') ($mutableAzure -join ' | ')

    $global:P116Calls.Clear()
    $global:P116Validation = $null
    function Invoke-ClaudeAccessCatalogLocalValidation { param($Path, $TenantId); $global:P116Calls.Add('validate refused'); throw 'Catalog validation refused at stage catalog.' }
    Capture {
        Invoke-ClaudeAccessCatalogAdministration -ResourceGroup rg-p116 -ApimName apim-p116 -Path $catalogPath
    }
    Assert 'a malformed catalog stops before every write path' (
        $CapturedError -match 'catalog' -and ($global:P116Calls -join "`n") -notmatch '(?m)^(archive|start|send|exec) ') "$CapturedError | $($global:P116Calls -join ' | ')"

    $global:P116Calls.Clear()
    function Invoke-ClaudeAccessCatalogLocalValidation { param($Path, $TenantId); $global:P116Calls.Add('validate tenant mismatch'); throw 'Catalog validation refused at stage tenant.' }
    Capture {
        Invoke-ClaudeAccessCatalogAdministration -ResourceGroup rg-p116 -ApimName apim-p116 -Path $catalogPath
    }
    Assert 'tenant mismatch stops before every write path without printing either tenant id' (
        $CapturedError -match 'tenant' -and
        $CapturedError -notmatch '11111111|aaaaaaaa' -and
        ($global:P116Calls -join "`n") -notmatch '(?m)^(archive|start|send|exec) ') "$CapturedError | $($global:P116Calls -join ' | ')"

    foreach ($case in @(
        @{ Name = 'resource group metacharacter'; ResourceGroup = 'rg&whoami'; ApimName = 'apim-p116' },
        @{ Name = 'APIM metacharacter'; ResourceGroup = 'rg-p116'; ApimName = 'apim|whoami' }
    )) {
        $global:P116Calls.Clear()
        Capture {
            Invoke-ClaudeAccessCatalogAdministration -ResourceGroup $case.ResourceGroup -ApimName $case.ApimName -Path $catalogPath -WhatIf
        }
        Assert "$($case.Name) is refused before discovery" (
            $CapturedError -match 'refused|name' -and $global:P116Calls.Count -eq 0) "$CapturedError | $($global:P116Calls -join ' | ')"
    }

    $helperText = [IO.File]::ReadAllText($helperPath)
    $nodeText = [IO.File]::ReadAllText((Join-Path $root 'sync\src\access-catalog-administration.mjs')) +
        [IO.File]::ReadAllText((Join-Path $root 'sync\src\administer-access-catalog.mjs'))
    Assert 'the implementation contains no group membership mutation surface' (
        ($helperText + $nodeText) -notmatch 'group member (add|remove|create|delete)|members/\$ref|transitiveMembers')
}
finally {
    Remove-Item -LiteralPath $catalogPath -Force -ErrorAction SilentlyContinue
}

if ($failures) { throw "$failures of $assertions access catalog administration assertions failed." }
Write-Host "$assertions access catalog administration assertions passed."
