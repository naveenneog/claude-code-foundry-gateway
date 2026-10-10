<#
.SYNOPSIS
    Reading and writing the business unit registry.

.DESCRIPTION
    Dot-source this. It owns one format so the reader, the writer and the tests
    cannot disagree about it.

    The registry lives in the `bu-registry` API Management named value:

        ,finance=Claude BU Finance:5000000,platform=Claude BU Platform:20000000,

    Sentinel commas, matching `allow-standard` and `quota-overrides`, so a
    lookup for ",finance=" cannot partially match ",finance-emea=".

    Three fields per entry:

      id      the stable identifier. It is what the counter key, the ledger and
              every report use, and it never changes. See ADR-0007.
      group   the Entra group whose members belong to this business unit. This
              is a display name and may be renamed without touching the id.
      tokens  the monthly budget, in tokens.

    Why tokens and not dollars: a budget holder sets dollars, but the gateway
    can only count tokens, so the conversion happens here, once, at write time.
    The error in that conversion is real and documented - output is 5x base
    input, a cache read is 0.1x, and the quota counter excludes cached tokens
    entirely. Callers must say so rather than present the figure as money.
#>

. (Join-Path $PSScriptRoot 'ClaudeBudgetModes.ps1')
. (Join-Path $PSScriptRoot 'ClaudeModelPrices.ps1')

# Claude's published list rates, per million tokens, retrieved 2026-09-15 from
# https://platform.claude.com/docs/en/about-claude/pricing
#
# Older books stored only base input and output. Current books may also carry
# explicit cache rates because newer Claude families do not all use the same
# cache-read multiplier. Missing cache rates keep the historical defaults.
#
# Azure bills Claude as a single aggregated Claude Consumption Unit meter where
# 100 CCU is $1.00, and private-offer discounts are applied before that
# conversion, so these support list-price showback and not invoice-accurate
# chargeback. U2 covers what would close that gap.
$script:ClaudePriceBook = @{
    'claude-opus-5'    = @{ InputPerM = [decimal]5.0; OutputPerM = [decimal]25.0 }
    'claude-opus-4.8'  = @{ InputPerM = [decimal]5.0; OutputPerM = [decimal]25.0 }
    'claude-sonnet-5'  = @{ InputPerM = [decimal]2.0; OutputPerM = [decimal]10.0 }
    'claude-haiku-4.5' = @{ InputPerM = [decimal]1.0; OutputPerM = [decimal]5.0 }
}
$script:ClaudePriceBookDate = '2026-09-15'

# A new Claude model should not need a code change to become chargeable. The
# table above is the fallback; config/price-book.json overrides it when present,
# and Add-ClaudeModel.ps1 writes that file.
#
# Rates are cast to decimal on load. ConvertFrom-Json produces doubles, and
# ADR-0010 requires money to be decimal end to end - a double here would reach
# the blended rate and stop the figures reproducing.
$script:ClaudePriceBookPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config/price-book.json'
$script:ClaudePoisonedPriceFamilies = @{}

function Import-ClaudePriceBook {
    param([string]$Path = $script:ClaudePriceBookPath)

    if (-not (Test-Path $Path)) { return $false }

    $doc = Get-Content $Path -Raw | ConvertFrom-Json
    if (-not $doc.models -or $doc.models -isnot [System.Management.Automation.PSCustomObject]) { throw "Price book '$Path' has no 'models' object. Delete it to fall back to the built-in rates." }
    # A book whose entries are all invalid still imports, with every family unpriced; a book with no entries is refused.
    if (-not @($doc.models.PSObject.Properties).Count) { throw "Price book '$Path' lists no models. Delete it to fall back to the built-in rates." }

    $book = @{}
    $poisoned = @{}
    function Add-PoisonedPriceFamily([string]$ModelName, [string]$Field) {
        $family = ConvertTo-ClaudePriceModelKey $ModelName
        if ($family) {
            # The value is the reason a refusal gives for every name in the family.
            $reason = "entry '$ModelName' in price book '$Path' has invalid $Field"
            $poisoned[$family] = $reason
            if ($family.Length -gt 8 -and $family.Substring($family.Length - 8) -match '^\d{8}$') {
                $poisoned[$family.Substring(0, $family.Length - 8)] = $reason
            }
            Write-Warning "Price book '$Path': model '$ModelName' has invalid $Field; normalized family '$family' is unpriced until the entry is fixed."
        }
    }
    function Test-PriceRate([object]$Value) {
        if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
            $Value -is [System.Collections.IEnumerable] -or $Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
            return $null
        }
        # The reconciler's bounds (service/aum/aum_service/usd_budgets.py rate): 0 to 1,000,000 per million tokens.
        # The sign is read before the decimal conversion, which turns -1e-30 into 0.
        if ($Value -lt 0) { return $null }
        try { $parsed = [decimal]$Value } catch { return $null }
        if ($parsed -lt 0 -or $parsed -gt 1000000) { return $null }
        return $parsed
    }
    foreach ($p in $doc.models.PSObject.Properties) {
        $m = $p.Value
        if ($m -isnot [System.Management.Automation.PSCustomObject]) {
            Add-PoisonedPriceFamily $p.Name 'shape (the entry is not an object)'
            continue
        }
        $inputRate = Test-PriceRate $m.inputPerM
        if ($null -eq $inputRate) {
            Add-PoisonedPriceFamily $p.Name 'inputPerM'
            continue
        }
        $outputRate = Test-PriceRate $m.outputPerM
        if ($null -eq $outputRate) {
            Add-PoisonedPriceFamily $p.Name 'outputPerM'
            continue
        }
        $entry = @{
            InputPerM  = $inputRate
            OutputPerM = $outputRate
        }
        $skip = $false
        foreach ($optional in 'cacheReadPerM', 'cacheWrite5mPerM', 'cacheWrite1hPerM') {
            if ($null -ne $m.PSObject.Properties[$optional]) {
                $parsed = Test-PriceRate $m.$optional
                if ($null -eq $parsed) {
                    Add-PoisonedPriceFamily $p.Name $optional
                    $skip = $true
                    break
                }
                $entry[$optional.Substring(0, 1).ToUpperInvariant() + $optional.Substring(1)] = $parsed
            }
        }
        if (-not $skip) { $book[$p.Name] = $entry }
    }

    $script:ClaudePriceBook = $book
    $script:ClaudePoisonedPriceFamilies = $poisoned
    if ($doc.date) { $script:ClaudePriceBookDate = [string]$doc.date }
    return $true
}

# Loaded at dot-source time so every caller sees the same rates. A malformed
# file throws rather than silently leaving the built-in table in place: a price
# book that is being ignored is worse than one that is missing, because the
# figures still look right.
Import-ClaudePriceBook | Out-Null

function Get-ClaudeBusinessUnitPriceBook {
    $models = [ordered]@{}
    foreach ($key in $script:ClaudePriceBook.Keys) {
        $models[$key] = [pscustomobject]@{
            inputPerM = $script:ClaudePriceBook[$key].InputPerM
            outputPerM = $script:ClaudePriceBook[$key].OutputPerM
        }
        foreach ($pair in @(@('CacheReadPerM', 'cacheReadPerM'), @('CacheWrite5mPerM', 'cacheWrite5mPerM'), @('CacheWrite1hPerM', 'cacheWrite1hPerM'))) {
            if ($script:ClaudePriceBook[$key].ContainsKey($pair[0])) {
                $models[$key] | Add-Member -NotePropertyName $pair[1] -NotePropertyValue $script:ClaudePriceBook[$key][$pair[0]]
            }
        }
    }
    return [pscustomobject]@{
        date = $script:ClaudePriceBookDate
        source = 'business-unit token conversion price book'
        models = [pscustomobject]$models
    }
}

function Resolve-ClaudePriceBookEntry {
    param([Parameter(Mandatory = $true)][string]$Model)
    if (Test-ClaudePoisonedPriceFamily $Model) { return $null }
    $book = Get-ClaudeBusinessUnitPriceBook
    $key = Resolve-ClaudePriceBookKey -Name $Model -Book $book
    if (-not $key) { return $null }
    if (Test-ClaudePoisonedPriceFamily $key) { return $null }
    return @{ Key = $key; Price = $script:ClaudePriceBook[$key] }
}

function Test-ClaudePoisonedPriceFamily {
    param([AllowNull()][string]$Model)
    return [bool](Get-ClaudePoisonedPriceFamilyReason $Model)
}

function Get-ClaudePoisonedPriceFamilyReason {
    param([AllowNull()][string]$Model)
    $family = ConvertTo-ClaudePriceModelKey $Model
    if (-not $family -or -not $script:ClaudePoisonedPriceFamilies) { return '' }
    if ($script:ClaudePoisonedPriceFamilies.ContainsKey($family)) { return [string]$script:ClaudePoisonedPriceFamilies[$family] }
    if ($family.Length -gt 8 -and $family.Substring($family.Length - 8) -match '^\d{8}$') {
        $undated = $family.Substring(0, $family.Length - 8)
        if ($script:ClaudePoisonedPriceFamilies.ContainsKey($undated)) { return [string]$script:ClaudePoisonedPriceFamilies[$undated] }
    }
    return ''
}

function Test-ClaudeBuId {
    <#
    .SYNOPSIS
        Throws unless the identifier is safe to put in a counter key and a
        comma-delimited map, and lower-case unless it is already stored.

    .DESCRIPTION
        A new identifier is lower-case, because the dollar budget uses it as its scope and accepts only
        lower-case (ClaudeUsdBudgets.ps1). Before P96 this check ignored case, so a registry can hold an
        identifier with capitals. An identifier that -Registry lists with the same spelling, or one read
        from the registry (-Stored), keeps only the map rule. An identifier that matches a registry entry
        only when case is ignored is refused: the policy finds a unit by its exact spelling
        (infra/policy.xml), so such an identifier is either a mistyped reference to the stored unit or a
        second unit that a reader cannot tell apart from it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id,
        [AllowEmptyCollection()][AllowNull()][string[]]$Registry = @(),
        [switch]$Stored
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "A business unit identifier cannot be empty."
    }
    # Comma separates entries, equals separates id from value, colon separates
    # group from budget. A space would make a counter key ambiguous to read.
    # Known means the same characters: -ccontains compares by culture and takes U+212A KELVIN SIGN for 'K'.
    $known = $Stored -or (@(@($Registry) | Where-Object { [string]::Equals([string]$_, $Id, [System.StringComparison]::Ordinal) }).Count -gt 0)
    if (($known -and $Id -notmatch '^[a-z0-9][a-z0-9-]*\z') -or (-not $known -and $Id -cnotmatch '^[a-z0-9][a-z0-9-]*\z')) {
        throw ("'$Id' is not a valid business unit identifier. Use lower-case letters, digits and " +
               "hyphens, starting with a letter or digit - for example 'finance-emea'. " +
               "It becomes a counter key and a map key, so it cannot contain a space, comma, equals or colon.")
    }
    if (-not $known) {
        $spelling = @(@($Registry) | Where-Object { $_ -eq $Id })
        if ($spelling.Count) {
            throw ("Business unit '$Id' differs only in case from '$($spelling[0])' in the registry. " +
                   "Use '$($spelling[0])' to change that unit, or another lower-case identifier, such as '$Id-2', for a new unit.")
        }
    }
}

function ConvertFrom-ClaudeBuRegistry {
    <#
    .SYNOPSIS
        Parses the registry named value into objects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    $out = @()
    foreach ($entry in ($Value.Trim(',') -split ',' | Where-Object { $_ })) {
        $eq = $entry.IndexOf('=')
        if ($eq -lt 1) { Write-Warning "Ignoring malformed registry entry '$entry'."; continue }
        $id = $entry.Substring(0, $eq)
        $rest = $entry.Substring($eq + 1)

        # The group name may itself contain a colon, so split on the last one -
        # the budget is always the final field.
        $colon = $rest.LastIndexOf(':')
        if ($colon -lt 0) { Write-Warning "Ignoring registry entry '$entry' with no budget."; continue }
        $group = $rest.Substring(0, $colon)
        $tokens = $rest.Substring($colon + 1)

        if ($tokens -notmatch '^\d+$') { Write-Warning "Ignoring registry entry '$entry' with a non-numeric budget."; continue }

        $out += [pscustomobject]@{
            Id              = $id
            Group           = $group
            TokensPerMonth  = [long]$tokens
        }
    }
    return $out
}

function ConvertTo-ClaudeBuRegistry {
    <#
    .SYNOPSIS
        Renders business unit objects back into the named value format.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyCollection()][AllowNull()]$BusinessUnits)

    $items = @($BusinessUnits | Where-Object { $_ })
    if (-not $items.Count) { return ',,' }

    $parts = foreach ($b in $items) {
        Test-ClaudeBuId $b.Id -Stored
        "$($b.Id)=$($b.Group):$([long]$b.TokensPerMonth)"
    }
    return ',' + ($parts -join ',') + ','
}

function ConvertFrom-ClaudeBuMembers {
    <#
    .SYNOPSIS
        Parses the ,oid=bu, membership map.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value)

    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Value)) { return $map }
    foreach ($pair in ($Value.Trim(',') -split ',' | Where-Object { $_ })) {
        $bits = $pair -split '=', 2
        if ($bits.Count -eq 2) { $map[$bits[0]] = $bits[1] }
    }
    return $map
}

function ConvertTo-ClaudeBuMembers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowNull()]$Map)

    if (-not $Map -or -not $Map.Keys.Count) { return ',,' }
    return ',' + (($Map.Keys | ForEach-Object { "$_=$($Map[$_])" }) -join ',') + ','
}

function ConvertFrom-ClaudeBuParents {
    <#
    .SYNOPSIS
        Parses the ,team=parent, map that makes a unit a team.

    .DESCRIPTION
        A team is a business unit that names a parent. ADR-0008 keeps this in a
        second named value rather than a fourth field in the registry entry,
        because a group display name may contain a colon and the budget is
        already found by splitting on the last one. A variable field count makes
        that rule ambiguous.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value, [switch]$ExactKeys)

    # Without -ExactKeys, keys compare without case, as the renewal job reads bu-parents (sync/src/business-units.mjs);
    # tests/Test-ProjectionRenewalRuns.ps1 checks that the two agree. The writers pass -ExactKeys, so a change to one
    # spelling of an identifier leaves the entry of another spelling as it is.
    $map = if ($ExactKeys) { [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal) } else { [ordered]@{} }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $map }
    foreach ($pair in ($Value.Trim(',') -split ',' | Where-Object { $_ })) {
        $bits = $pair -split '=', 2
        if ($bits.Count -eq 2 -and $bits[0] -and $bits[1]) { $map[$bits[0]] = $bits[1] }
    }
    return $map
}

function ConvertTo-ClaudeBuParents {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowNull()]$Map)

    if (-not $Map -or -not $Map.Keys.Count) { return ',,' }
    return ',' + (($Map.Keys | ForEach-Object { "$_=$($Map[$_])" }) -join ',') + ','
}

function Resolve-ClaudeBuDepth {
    <#
    .SYNOPSIS
        How many parents a unit has above it. 0 for a business unit, 1 for a
        team inside one.

    .DESCRIPTION
        Walks the parent chain. Stops at $Limit hops and reports that depth
        rather than looping, so a cycle returns a number the caller can refuse
        instead of hanging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowNull()]$Parents,
        [int]$Limit = 10
    )

    $depth = 0
    $cursor = $Id
    $seen = @{ $Id = $true }
    while ($Parents -and $Parents[$cursor] -and $depth -lt $Limit) {
        $cursor = $Parents[$cursor]
        $depth++
        # A cycle would otherwise walk to $Limit and be reported as a depth,
        # which reads as "too deep" when the real fault is that it never ends.
        if ($seen.ContainsKey($cursor)) { return [int]::MaxValue }
        $seen[$cursor] = $true
    }
    return $depth
}

function Test-ClaudeBuDepth {
    <#
    .SYNOPSIS
        Throws unless every chain in the parent map is at most two levels and
        free of cycles.

    .DESCRIPTION
        The cascade is written into the policy as two llm-token-limit elements
        with statically written counter keys. There is no loop, so a third level
        would not be charged at all. Refusing it here makes that a write-time
        error with a message, rather than a budget that silently stops
        cascading. ADR-0008 records why the cap is two.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Parents)

    if (-not $Parents) { return }
    foreach ($id in @($Parents.Keys)) {
        $depth = Resolve-ClaudeBuDepth -Id $id -Parents $Parents
        if ($depth -eq [int]::MaxValue) {
            throw ("The parent map has a cycle involving '$id'. A unit cannot be inside itself, directly " +
                   "or through another unit.")
        }
        if ($depth -gt 1) {
            throw ("'$id' is $depth levels below the top. The cascade is two levels - a business unit and " +
                   "the teams inside it - because the gateway charges a request to its unit and that unit's " +
                   "parent, and nothing deeper. Point '$id' at a business unit that has no parent of its own.")
        }
    }
}

function Sort-ClaudeBuByDepth {
    <#
    .SYNOPSIS
        Orders units deepest first, so a team is resolved before the business
        unit that contains it.

    .DESCRIPTION
        An Entra group can contain another group, so a business unit group
        transitively contains everyone in its teams and a developer matches
        both. Membership must resolve to the most specific unit; the parent is
        reached through the cascade instead.

        Units at the same depth keep registry order, so ADR-0007's "first match
        in registry order" still decides between them. That order is kept by an
        explicit second key, the unit's position in the registry. Sort-Object
        is not stable: measured 2026-09-23, sorting 2,000 items on a key with
        three values reordered equal items 960 times in PowerShell 7.6 and
        1,011 times in 5.1, and a five-unit registry came back in a different
        order in 5.1 than in 7.6 - so two administrators running the same sync
        from different shells charged the same developer to different units.
        -Stable would fix 7 and does not exist in 5.1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyCollection()][AllowNull()]$Units,
        [Parameter(Mandatory = $true)][AllowNull()]$Parents
    )

    $items = @(@($Units) | Where-Object { $_ })
    if (-not $items.Count) { return @() }
    $position = 0
    $keyed = foreach ($u in $items) {
        [pscustomobject]@{ Unit = $u; Position = $position; Depth = (Resolve-ClaudeBuDepth -Id $u.Id -Parents $Parents) }
        $position++
    }
    return @($keyed |
        Sort-Object -Property @{ Expression = 'Depth'; Descending = $true }, @{ Expression = 'Position'; Ascending = $true } |
        ForEach-Object { $_.Unit })
}

function ConvertTo-ClaudeBuTokens {
    <#
    .SYNOPSIS
        Converts a monthly dollar budget into a token budget.

    .DESCRIPTION
        A budget holder sets dollars; the gateway counts tokens. The conversion
        happens here, once, at write time, rather than per request.

        It assumes a mix, because a dollar does not buy a fixed number of tokens:
        output costs five times base input. The default assumption is stated in
        the output rather than buried, so an administrator can see what they are
        being given.

        This is a proxy, not an accounting identity. The quota counter also
        excludes cached tokens entirely, which on thirty days of live usage was
        38.7% of the real cost weight. Callers must present the result as an
        approximation at list price.

    .PARAMETER OutputShare
        Fraction of tokens assumed to be output. Claude Code is output-light on
        volume and output-heavy on cost; 0.2 is a deliberately conservative
        default, meaning the budget runs out sooner rather than later.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][decimal]$Usd,
        [string]$Model = 'claude-sonnet-5',
        [decimal]$OutputShare = 0.2
    )

    if ($Usd -le 0) { throw "A monthly budget must be greater than zero." }
    if ($OutputShare -lt 0 -or $OutputShare -ge 1) { throw "OutputShare must be between 0 and 1." }

    $resolved = Resolve-ClaudePriceBookEntry $Model
    $price = if ($resolved) { $resolved.Price } else { $null }
    if (-not $price) {
        $poisonReason = Get-ClaudePoisonedPriceFamilyReason $Model
        if ($poisonReason) { throw "No price for '$Model': $poisonReason. Its model family stays unpriced until that entry is corrected." }
        throw ("No price for '$Model'. Known models: " + (($script:ClaudePriceBook.Keys | Sort-Object) -join ', ') + ".")
    }

    # Blended cost of one million mixed tokens at the assumed split.
    $blendedPerM = ($price.InputPerM * (1 - $OutputShare)) + ($price.OutputPerM * $OutputShare)
    $tokens = [long][math]::Floor(($Usd / $blendedPerM) * 1000000)

    [pscustomobject]@{
        Usd             = $Usd
        Model           = $Model
        OutputShare     = $OutputShare
        BlendedUsdPerM  = [math]::Round($blendedPerM, 4)
        TokensPerMonth  = $tokens
        PriceBookDate   = $script:ClaudePriceBookDate
        IsEstimate      = $true
    }
}

function ConvertTo-ClaudeCacheUsd {
    <#
    .SYNOPSIS
        Prices cache-read tokens with the book's effective cache-read rate.

    .DESCRIPTION
        Priced on its own rather than folded into the blended figure, because
        the blend assumes an input/output mix and a cache read is neither. It
        is a third category, and ADR-0010 requires the
        categories to be priced separately and never summed before pricing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$Tokens,
        [string]$Model = 'claude-sonnet-5'
    )
    $resolved = Resolve-ClaudePriceBookEntry $Model
    $price = if ($resolved) { $resolved.Price } else { $null }
    if (-not $price) { return $null }
    $cacheReadPerM = if ($price.ContainsKey('CacheReadPerM')) { $price.CacheReadPerM } else { $price.InputPerM * [decimal]0.1 }
    return [math]::Round(([decimal]$Tokens / [decimal]1000000) * $cacheReadPerM, 2)
}

function ConvertTo-ClaudeBuUsd {
    <#
    .SYNOPSIS
        The reverse, for reporting a token budget back as an approximate figure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$Tokens,
        [string]$Model = 'claude-sonnet-5',
        [decimal]$OutputShare = 0.2
    )
    $resolved = Resolve-ClaudePriceBookEntry $Model
    $price = if ($resolved) { $resolved.Price } else { $null }
    if (-not $price) { return $null }
    $blendedPerM = ($price.InputPerM * (1 - $OutputShare)) + ($price.OutputPerM * $OutputShare)
    return [math]::Round(([decimal]$Tokens / [decimal]1000000) * $blendedPerM, 2)
}

function ConvertTo-ClaudeRequestUsd {
    <#
    .SYNOPSIS
        Prices one request at list price, each token category at its own rate.

    .DESCRIPTION
        A request's categories are known, so it is priced exactly rather than
        through the blended mix a budget uses: input at base input, output at
        the output rate, cache read at the book's effective cache-read rate. ADR-0010: categories
        are priced separately and never summed before pricing, and money stays
        decimal.

        Rounded to six places because one short request costs a fraction of a
        cent, and two places would price most requests at zero. Returns $null
        for a model the price book does not know, so an unpriced request reads
        as unpriced rather than as free.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [long]$InputTokens = 0,
        [long]$OutputTokens = 0,
        [long]$CacheReadTokens = 0
    )
    if ($InputTokens -lt 0 -or $OutputTokens -lt 0 -or $CacheReadTokens -lt 0) {
        throw "A token count cannot be negative (input $InputTokens, output $OutputTokens, cache read $CacheReadTokens)."
    }
    $resolved = Resolve-ClaudePriceBookEntry $Model
    $price = if ($resolved) { $resolved.Price } else { $null }
    if (-not $price) { return $null }
    $perToken = [decimal]1000000
    $cacheReadPerM = if ($price.ContainsKey('CacheReadPerM')) { $price.CacheReadPerM } else { $price.InputPerM * [decimal]0.1 }
    $usd = (([decimal]$InputTokens / $perToken) * $price.InputPerM) +
           (([decimal]$OutputTokens / $perToken) * $price.OutputPerM) +
           (([decimal]$CacheReadTokens / $perToken) * $cacheReadPerM)
    return [math]::Round($usd, 6)
}
