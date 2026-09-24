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

# Claude's published list rates, per million tokens, retrieved 2026-09-15 from
. (Join-Path $PSScriptRoot 'ClaudeBudgetModes.ps1')

# Claude's published list rates, per million tokens, retrieved 2026-09-15 from
# https://platform.claude.com/docs/en/about-claude/pricing
#
# Only base input and output are stored. The cache rates are multipliers of base
# input - read 0.1x, five-minute write 1.25x, one-hour write 2x - so recording
# them separately would be three more numbers to keep current for no gain.
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

function Import-ClaudePriceBook {
    param([string]$Path = $script:ClaudePriceBookPath)

    if (-not (Test-Path $Path)) { return $false }

    $doc = Get-Content $Path -Raw | ConvertFrom-Json
    if (-not $doc.models) { throw "Price book '$Path' has no 'models' object. Delete it to fall back to the built-in rates." }

    $book = @{}
    foreach ($p in $doc.models.PSObject.Properties) {
        $m = $p.Value
        if ($null -eq $m.inputPerM -or $null -eq $m.outputPerM) {
            throw "Price book '$Path': model '$($p.Name)' is missing inputPerM or outputPerM."
        }
        $book[$p.Name] = @{
            InputPerM  = [decimal]$m.inputPerM
            OutputPerM = [decimal]$m.outputPerM
        }
    }
    if ($book.Keys.Count -eq 0) { throw "Price book '$Path' lists no models. Delete it to fall back to the built-in rates." }

    $script:ClaudePriceBook = $book
    if ($doc.date) { $script:ClaudePriceBookDate = [string]$doc.date }
    return $true
}

# Loaded at dot-source time so every caller sees the same rates. A malformed
# file throws rather than silently leaving the built-in table in place: a price
# book that is being ignored is worse than one that is missing, because the
# figures still look right.
Import-ClaudePriceBook | Out-Null

function Test-ClaudeBuId {
    <#
    .SYNOPSIS
        Throws unless the identifier is safe to put in a counter key and a
        comma-delimited map.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "A business unit identifier cannot be empty."
    }
    # Comma separates entries, equals separates id from value, colon separates
    # group from budget. A space would make a counter key ambiguous to read.
    if ($Id -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw ("'$Id' is not a valid business unit identifier. Use lower-case letters, digits and " +
               "hyphens, starting with a letter or digit - for example 'finance-emea'. " +
               "It becomes a counter key and a map key, so it cannot contain a space, comma, equals or colon.")
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

    $items = @($BusinessUnits) | Where-Object { $_ }
    if (-not $items.Count) { return ',,' }

    $parts = foreach ($b in $items) {
        Test-ClaudeBuId $b.Id
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
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][AllowNull()][string]$Value)

    $map = [ordered]@{}
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

    $price = $script:ClaudePriceBook[$Model]
    if (-not $price) {
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
        Prices cache-read tokens, which are 0.1x the base input rate.

    .DESCRIPTION
        Priced on its own rather than folded into the blended figure, because
        the blend assumes an input/output mix and a cache read is neither. It
        is a third category at a tenth of base input, and ADR-0010 requires the
        categories to be priced separately and never summed before pricing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][long]$Tokens,
        [string]$Model = 'claude-sonnet-5'
    )
    $price = $script:ClaudePriceBook[$Model]
    if (-not $price) { return $null }
    # 0.1x base input, per Claude's published cache rates.
    return [math]::Round(([decimal]$Tokens / [decimal]1000000) * $price.InputPerM * [decimal]0.1, 2)
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
    $price = $script:ClaudePriceBook[$Model]
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
        the output rate, cache read at 0.1x base input. ADR-0010: categories
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
    $price = $script:ClaudePriceBook[$Model]
    if (-not $price) { return $null }
    $perToken = [decimal]1000000
    $usd = (([decimal]$InputTokens / $perToken) * $price.InputPerM) +
           (([decimal]$OutputTokens / $perToken) * $price.OutputPerM) +
           (([decimal]$CacheReadTokens / $perToken) * $price.InputPerM * [decimal]0.1)
    return [math]::Round($usd, 6)
}
