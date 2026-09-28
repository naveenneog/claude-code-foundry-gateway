# Shared, read-only registration and exact-source receipt contracts (PowerShell 7).
function Get-TestAllRegistration {
    param([string]$Path = (Join-Path $PSScriptRoot 'Test-All.ps1'), [string]$Text, [switch]$IncludeAzure)
    if (-not $PSBoundParameters.ContainsKey('Text')) { $Text = [IO.File]::ReadAllText($Path) }
    $begin = '# BEGIN CHECK REGISTRATION'; $end = '# END CHECK REGISTRATION'
    if ([regex]::Matches($Text, [regex]::Escape($begin)).Count -ne 1 -or
        [regex]::Matches($Text, [regex]::Escape($end)).Count -ne 1) {
        throw 'Missing or ambiguous check registration markers.'
    }
    $block = [regex]::Match($Text, "(?s)$begin(.*?)$end")
    if (-not $block.Success) { throw 'Invalid check registration boundaries.' }
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($block.Groups[1].Value, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse check registration: $($errors[0].Message)" }
    $commands = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Check'
    }, $true) | Sort-Object { $_.Extent.StartOffset })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $index = 0
    foreach ($command in $commands) {
        $elements = $command.CommandElements
        if ($elements.Count -lt 3 -or
            $elements[1] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            $elements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            throw 'Every check registration needs literal name and script arguments.'
        }
        $name = $elements[1].Value; $scriptName = $elements[2].Value
        if (-not $name -or $scriptName -cnotmatch '^[A-Za-z0-9.-]+\.ps1$') { throw 'Invalid literal check identity.' }
        $parameters = @($elements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] })
        $azure = @($parameters | Where-Object ParameterName -eq 'Azure').Count -gt 0
        if ($azure -and -not $IncludeAzure) { continue }
        if (-not $seen.Add($name)) { throw "Duplicate registered check: $name" }
        $reasons = @()
        for ($i = 3; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if ($element -isnot [Management.Automation.Language.CommandParameterAst] -or $element.ParameterName -ne 'SkipReason') { continue }
            $expression = if ($element.Argument) { $element.Argument } else { $elements[$i + 1] }
            if ($expression -is [Management.Automation.Language.StringConstantExpressionAst]) {
                if ($expression.Value) { $reasons += $expression.Value }
            }
            elseif ($expression -is [Management.Automation.Language.VariableExpressionAst]) {
                $variable = $expression.VariablePath.UserPath
                $assignments = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    $node.Left.VariablePath.UserPath -ceq $variable
                }, $true))
                if ($assignments.Count -ne 1 -or $assignments[0].Right -isnot [Management.Automation.Language.IfStatementAst]) {
                    throw "Skip reason for '$name' must have one literal-branch declaration."
                }
                $branches = @($assignments[0].Right.Clauses | ForEach-Object { $_.Item2 })
                if ($assignments[0].Right.ElseClause) { $branches += $assignments[0].Right.ElseClause }
                foreach ($branch in $branches) {
                    if ($branch.Statements.Count -ne 1 -or
                        $branch.Statements[0] -isnot [Management.Automation.Language.PipelineAst] -or
                        $branch.Statements[0].GetPureExpression() -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                        throw "Skip reason for '$name' has a nonliteral branch."
                    }
                    $value = $branch.Statements[0].GetPureExpression().Value
                    if ($value) { $reasons += $value }
                }
            }
            else { throw "Skip reason for '$name' cannot be inventoried without execution." }
        }
        [pscustomobject]@{ Id = $index; Name = $name; Script = $scriptName; Azure = $azure; SkipReasons = @($reasons) }
        $index++
    }
    if ($index -eq 0) { throw 'The check registration is empty.' }
}

function Test-TestAllNumber($Value, [switch]$Positive) {
    $numeric = $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]
    $numeric -and [double]::IsFinite([double]$Value) -and $(if ($Positive) { $Value -gt 0 } else { $Value -ge 0 })
}

function Test-TestAllInteger($Value) { $Value -is [int] -or $Value -is [long] }

function New-TestAllShardPlan {
    param([object[]]$Registration, [Collections.IDictionary]$Timing, [int]$ShardCount, [object[]]$LocalOnly = @())
    if (-not (Test-TestAllInteger $Timing.SchemaVersion) -or $Timing.SchemaVersion -ne 1 -or
        -not (Test-TestAllNumber $Timing.DefaultSeconds -Positive) -or
        $Timing.Seconds -isnot [Collections.IDictionary]) { throw 'Invalid timing schema or default weight.' }
    foreach ($weight in $Timing.Seconds.Values) {
        if (-not (Test-TestAllNumber $weight -Positive)) { throw 'Every committed timing weight must be a positive number.' }
    }
    $locals = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $LocalOnly) {
        if ([string]::IsNullOrWhiteSpace($entry.Reason)) { throw 'Every local-only check needs a reason.' }
        if (@($Registration | Where-Object Name -CEQ $entry.Name).Count -ne 1) { throw "Local-only check is not registered: $($entry.Name)" }
        if ($locals.ContainsKey($entry.Name)) { throw "Duplicate local-only entry: $($entry.Name)" }
        $locals.Add($entry.Name, $entry.Reason)
    }
    if ($ShardCount -lt 1 -or $ShardCount -gt 64 -or $ShardCount -gt ($Registration.Count - $locals.Count)) {
        throw 'ShardCount must be 1-64 and no greater than the number of CI checks.'
    }
    $plan = @(
        foreach ($check in $Registration) {
            $weight = $Timing.DefaultSeconds
            # JSON dictionaries may be case-insensitive; match the registered spelling exactly.
            foreach ($key in $Timing.Seconds.Keys) {
                if ($key -ceq $check.Name) { $weight = $Timing.Seconds[$key]; break }
            }
            [pscustomobject]@{
                Id = $check.Id; Name = $check.Name; Script = $check.Script; ShardIndex = -1
                EstimatedSeconds = [double]$weight
                LocalReason = $(if ($locals.ContainsKey($check.Name)) { $locals[$check.Name] } else { '' })
            }
        }
    )
    $loads = [double[]]::new($ShardCount)
    $weighted = @($plan | Where-Object { -not $_.LocalReason } |
        Sort-Object @{ Expression = 'EstimatedSeconds'; Descending = $true }, Id)
    foreach ($check in $weighted) {
        $bin = 0
        for ($i = 1; $i -lt $ShardCount; $i++) { if ($loads[$i] -lt $loads[$bin]) { $bin = $i } }
        $check.ShardIndex = $bin
        $loads[$bin] += $check.EstimatedSeconds
    }
    $plan
}

function Get-TestAllConfiguration {
    param([string]$Directory = $PSScriptRoot, [int]$ShardCount = 0)
    $registration = @(Get-TestAllRegistration -Path (Join-Path $Directory 'Test-All.ps1'))
    $timing = Get-Content -LiteralPath (Join-Path $Directory 'test-all-durations.json') -Raw | ConvertFrom-Json -AsHashtable
    $local = Get-Content -LiteralPath (Join-Path $Directory 'test-all-local-only.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($local.SchemaVersion -ne 1 -or -not $local.Contains('Checks') -or $local.Checks -isnot [array]) {
        throw 'Invalid local-only manifest schema.'
    }
    if (-not $ShardCount) {
        if ($timing.ShardCount -isnot [int] -and $timing.ShardCount -isnot [long]) { throw 'ShardCount must be an integer.' }
        $ShardCount = $timing.ShardCount
    }
    $plan = @(New-TestAllShardPlan $registration $timing $ShardCount -LocalOnly @($local.Checks))
    [pscustomobject]@{ Registration = $registration; Plan = $plan; ShardCount = $ShardCount; Timing = $timing }
}

function Invoke-TestAllGit {
    param([string]$Root, [string[]]$Arguments)
    $output = & git -C $Root @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output.Trim())" }
    $output.Trim()
}

function Get-TestAllIdentity {
    param([string]$Root = (Split-Path $PSScriptRoot -Parent), [switch]$RequireClean)
    $commit = Invoke-TestAllGit $Root @('rev-parse', '--verify', 'HEAD')
    $tree = Invoke-TestAllGit $Root @('rev-parse', '--verify', 'HEAD^{tree}')
    $dirty = [bool](Invoke-TestAllGit $Root @('status', '--porcelain=v1', '--untracked-files=normal'))
    if ($RequireClean -and $dirty) { throw 'The source tree is dirty; commit or remove changes before collecting exact-source evidence.' }
    [pscustomobject]@{ Commit = $commit; Tree = $tree; Dirty = $dirty }
}

function Test-TestAllNamesEqual($Left, $Right) {
    if (@($Left).Count -ne @($Right).Count) { return $false }
    for ($i = 0; $i -lt @($Left).Count; $i++) { if ($Left[$i] -cne $Right[$i]) { return $false } }
    $true
}

function Assert-TestAllReceiptSet {
    param(
        [object[]]$Receipts, [object[]]$Registration, [object[]]$Plan, [int]$ShardCount,
        [string]$Commit, [string]$Tree, [string]$RunId = '', [int]$RunAttempt = 0
    )
    if ($Commit -cnotmatch '^[a-f0-9]{40}$' -or $Tree -cnotmatch '^[a-f0-9]{40}$') { throw 'Expected commit and tree must be full Git object IDs.' }
    $byName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($check in $Registration) { $byName.Add($check.Name, $check) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenShards = [Collections.Generic.HashSet[int]]::new()
    $ordered = [object[]]::new($Registration.Count)
    $localExpected = @($Plan | Where-Object ShardIndex -eq -1).Count -gt 0
    $firstCi = $Receipts | Where-Object Mode -CEQ 'ci' | Select-Object -First 1
    if (-not $RunId -and $firstCi) { $RunId = [string]$firstCi.RunId }
    if (-not $RunAttempt -and $firstCi) { $RunAttempt = [int]$firstCi.RunAttempt }
    foreach ($receipt in $Receipts) {
        if (-not (Test-TestAllInteger $receipt.SchemaVersion) -or $receipt.SchemaVersion -ne 1) { throw 'Unsupported receipt schema.' }
        if ($receipt.Commit -cne $Commit) { throw "Receipt commit differs from expected commit $Commit." }
        if ($receipt.Tree -cne $Tree) { throw "Receipt tree differs from expected tree $Tree." }
        if ($receipt.Completed -isnot [bool] -or -not $receipt.Completed) { throw 'A receipt is not complete.' }
        if (-not (Test-TestAllInteger $receipt.ShardCount) -or $receipt.ShardCount -ne $ShardCount -or
            -not (Test-TestAllInteger $receipt.ShardIndex)) { throw 'Invalid receipt shard coordinates.' }
        if ($receipt.OwnedChecks -isnot [array] -or $receipt.Results -isnot [array]) {
            throw 'Receipt ownership and results must be JSON arrays, including single-check shards.'
        }
        $index = [int]$receipt.ShardIndex
        if ($receipt.Mode -ceq 'local') {
            if (-not $localExpected -or $index -ne -1) { throw 'Unexpected local-only receipt.' }
        }
        elseif ($receipt.Mode -ceq 'ci') {
            if ($index -lt 0 -or $index -ge $ShardCount) { throw 'Receipt shard index is out of range.' }
            if ([string]$receipt.RunId -cne $RunId) { throw 'Receipts belong to different workflow runs.' }
            if (-not (Test-TestAllInteger $receipt.RunAttempt) -or $receipt.RunAttempt -ne $RunAttempt) {
                throw 'Receipts belong to invalid or different workflow run attempts.'
            }
        }
        else { throw 'Receipt mode must be ci or local.' }
        if (-not $seenShards.Add($index)) { throw "Duplicate shard receipt: $index" }
        if (-not (Test-TestAllNumber $receipt.Seconds)) { throw 'Invalid receipt wall duration.' }
        if (-not $receipt.StartedAt -or -not $receipt.FinishedAt -or
            [datetimeoffset]$receipt.FinishedAt -lt [datetimeoffset]$receipt.StartedAt) { throw 'Invalid receipt time interval.' }
        $owned = @($Plan | Where-Object ShardIndex -eq $index)
        if (-not (Test-TestAllNamesEqual @($receipt.OwnedChecks) @($owned.Name))) { throw "Shard $index ownership does not match the committed plan." }
        foreach ($result in $receipt.Results) {
            if (-not $byName.ContainsKey([string]$result.Name)) { throw "Unregistered result: $($result.Name)" }
            if (-not $seen.Add($result.Name)) { throw "Duplicate result: $($result.Name)" }
            $check = $byName[$result.Name]
            if (-not (Test-TestAllInteger $result.RegistrationId) -or $result.RegistrationId -ne $check.Id -or $result.Script -cne $check.Script) {
                throw "Result identity differs from registration: $($result.Name)"
            }
            if (-not (Test-TestAllNumber $result.Seconds)) { throw "Invalid duration: $($result.Name)" }
            if ($result.Result -ceq 'PASS') {
                if ($null -eq $result.ExitCode -or -not (Test-TestAllNumber $result.ExitCode) -or $result.ExitCode -ne 0) {
                    throw "PASS needs exit code zero: $($result.Name)"
                }
                if ($result.SkipReason) { throw "PASS cannot carry a skip reason: $($result.Name)" }
            }
            elseif ($result.Result -ceq 'SKIP') {
                if ($null -ne $result.ExitCode -or -not $result.SkipReason -or $check.SkipReasons -cnotcontains $result.SkipReason) {
                    throw "SKIP needs this check's registered reason and no process exit: $($result.Name)"
                }
            }
            else { throw "Check did not pass (result $($result.Result)): $($result.Name)" }
            $ordered[$check.Id] = $result
        }
        if (-not (Test-TestAllNamesEqual @($receipt.Results.Name) @($owned.Name))) {
            throw "Shard $index has missing results or results outside its ownership."
        }
    }
    for ($i = 0; $i -lt $ShardCount; $i++) { if (-not $seenShards.Contains($i)) { throw "Missing shard receipt: $i/$ShardCount" } }
    if ($localExpected -and -not $seenShards.Contains(-1)) { throw 'Missing local-only evidence; CI alone is not complete coverage.' }
    if ($seen.Count -ne $Registration.Count -or @($ordered | Where-Object { $null -eq $_ }).Count) {
        throw 'The receipt union has missing registered checks.'
    }
    $ordered
}
