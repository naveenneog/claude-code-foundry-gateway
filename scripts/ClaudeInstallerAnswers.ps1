# One answers schema for both installers and the guided flow (docs/adr/0047-lean-installer-phase-0.md).
# Reads schemas/claude-gateway.answers.schema.json and checks an answers file, or a set of answers, for
# Install-ClaudeGateway.ps1, install-claude-gateway.sh or Start-ClaudeGateway.ps1. scripts/install-answers.jq
# applies the same rules in the same order, and the two report the same problems word for word
# (tests/Test-InstallerAnswersSchema.ps1). Each problem names the preflight check id that owns its rule.
# Runs on Windows PowerShell 5.1 and PowerShell 7.

if (-not (Get-Command Get-ClaudeInstallCodePointLength -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'ClaudeInstallResume.ps1') }
$script:ClaudeAnswersSchemaFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas/claude-gateway.answers.schema.json'
$script:ClaudeAnswersSchema = $null

function New-ClaudeAnswersMap {
    # Property names are compared as JSON compares them: exactly, not as PowerShell compares names.
    param($Object)
    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $map[$p.Name] = $p.Value } }
    return , $map
}

function Get-ClaudeAnswersSchema {
    if (-not $script:ClaudeAnswersSchema) {
        $doc = [IO.File]::ReadAllText($script:ClaudeAnswersSchemaFile) | ConvertFrom-Json
        $aliases = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        foreach ($p in $doc.properties.PSObject.Properties) { foreach ($a in @($p.Value.'x-flowKeys')) { if ($a) { $aliases[[string]$a] = $p.Name } } }
        $script:ClaudeAnswersSchema = [pscustomobject]@{
            Document = $doc; Properties = (New-ClaudeAnswersMap $doc.properties); Patterns = (New-ClaudeAnswersMap $doc.patternProperties)
            Defs = (New-ClaudeAnswersMap $doc.'$defs'); Secrets = (New-ClaudeAnswersMap $doc.'x-secrets'); Controls = (New-ClaudeAnswersMap $doc.'x-runControls'); Aliases = $aliases
        }
    }
    return $script:ClaudeAnswersSchema
}

function New-ClaudeAnswersProblem([string]$CheckId, [string]$Path, [string]$Message, [string]$Remedy) {
    [pscustomobject][ordered]@{ checkId = $CheckId; path = $Path; message = $Message; remedy = $Remedy }
}

function Join-ClaudeAnswersList([string[]]$Items, [string]$Last = 'and') {
    # 'A', 'A and B', 'A, B and C', as jq's andlist and orlist join them.
    $Items = @($Items)
    if ($Items.Count -le 1) { return [string]($Items | Select-Object -First 1) }
    return ((@($Items[0..($Items.Count - 2)]) -join ', ') + " $Last " + $Items[-1])
}

function Get-ClaudeAnswersType($Value) {
    # The JSON type of a value read from JSON or passed as a parameter.
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [bool] -or $Value -is [System.Management.Automation.SwitchParameter]) { return 'boolean' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [System.Numerics.BigInteger]) { return 'number' }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [System.Collections.IEnumerable]) { return 'array' }
    return 'other'
}
$script:ClaudeAnswersTypeWords = @{ string = 'text'; number = 'a number'; boolean = 'true or false'; array = 'a list'; object = 'an object'; null = 'null'; other = 'an unsupported value' }
$script:ClaudeAnswersExpectWords = @{ string = 'text'; integer = 'a whole number'; number = 'a number'; boolean = 'true or false'; array = 'a list'; object = 'an object' }

function Get-ClaudeAnswersNumberStep([string]$State, [int]$C) {
    # One character of a JSON number (RFC 8259): the next state, '' when the number ended before C,
    # or 'bad'. The terminal states are 0, i, f and x.
    $digit = $C -ge 48 -and $C -le 57
    $exponent = $C -eq 101 -or $C -eq 69
    switch -CaseSensitive ($State) {
        '-' { if ($C -eq 48) { return '0' } elseif ($digit) { return 'i' } else { return '' } }
        '0' { if ($C -eq 46) { return '.' } elseif ($exponent) { return 'e' } else { return '' } }
        'i' { if ($digit) { return 'i' } elseif ($C -eq 46) { return '.' } elseif ($exponent) { return 'e' } else { return '' } }
        '.' { if ($digit) { return 'f' } else { return 'bad' } }
        'f' { if ($digit) { return 'f' } elseif ($exponent) { return 'e' } else { return '' } }
        'e' { if ($C -eq 43 -or $C -eq 45) { return 's' } elseif ($digit) { return 'x' } else { return 'bad' } }
        's' { if ($digit) { return 'x' } else { return 'bad' } }
        'x' { if ($digit) { return 'x' } else { return '' } }
    }
    return 'bad'
}

function Get-ClaudeAnswersScan([string]$Text) {
    # A strict JSON scanner (RFC 8259), the same state machine as scan in scripts/install-answers.jq:
    # whether the text is JSON, and the property names of each object as written between the quotes.
    # Windows PowerShell's and PowerShell 7's ConvertFrom-Json and jq each accept text the others refuse
    # (comments, single quotes, trailing commas, nan), so the scanner decides what JSON is.
    $s = @{ ok = $true; st = [System.Collections.Generic.List[string]]::new(); ex = 'v'; m = ''; esc = $false; hex = 0; key = $false
        buf = [System.Text.StringBuilder]::new(); num = ''; lit = ''; frames = [System.Collections.Generic.List[object]]::new(); out = [System.Collections.Generic.List[object]]::new() }
    $after = { if ($s.st.Count -eq 0) { 'e' } else { ',' } }
    $close = {
        if ($s.st[$s.st.Count - 1] -eq 'o') { $s.out.Add($s.frames[$s.frames.Count - 1]); $s.frames.RemoveAt($s.frames.Count - 1) }
        $s.st.RemoveAt($s.st.Count - 1); $s.ex = & $after
    }
    $structural = {
        param([int]$C)
        if ($C -eq 32 -or $C -eq 9 -or $C -eq 10 -or $C -eq 13) { return }
        if ($C -eq -1) { if ($s.ex -ne 'e') { $s.ok = $false }; return }
        switch -CaseSensitive ($s.ex) {
            { $_ -eq 'v' -or $_ -eq 'V' } {
                if ($C -eq 123) { $s.st.Add('o'); $s.frames.Add([System.Collections.Generic.List[string]]::new()); $s.ex = 'K' }
                elseif ($C -eq 91) { $s.st.Add('a'); $s.ex = 'V' }
                elseif ($C -eq 34) { $s.m = 's'; $s.key = $false; [void]$s.buf.Clear() }
                elseif ($C -eq 45 -or ($C -ge 48 -and $C -le 57)) { $s.m = 'n'; $s.num = $(if ($C -eq 45) { '-' } elseif ($C -eq 48) { '0' } else { 'i' }) }
                elseif ($C -eq 116) { $s.m = 'l'; $s.lit = 'rue' }
                elseif ($C -eq 102) { $s.m = 'l'; $s.lit = 'alse' }
                elseif ($C -eq 110) { $s.m = 'l'; $s.lit = 'ull' }
                elseif ($C -eq 93 -and $s.ex -ceq 'V') { & $close }
                else { $s.ok = $false }
                return
            }
            { $_ -eq 'k' -or $_ -eq 'K' } {
                if ($C -eq 34) { $s.m = 's'; $s.key = $true; [void]$s.buf.Clear() }
                elseif ($C -eq 125 -and $s.ex -ceq 'K') { & $close }
                else { $s.ok = $false }
                return
            }
            ':' { if ($C -eq 58) { $s.ex = 'v' } else { $s.ok = $false }; return }
            ',' {
                $top = $s.st[$s.st.Count - 1]
                if ($C -eq 44) { $s.ex = $(if ($top -eq 'o') { 'k' } else { 'v' }) }
                elseif (($C -eq 125 -and $top -eq 'o') -or ($C -eq 93 -and $top -eq 'a')) { & $close }
                else { $s.ok = $false }
                return
            }
        }
        $s.ok = $false
    }
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -le $chars.Length -and $s.ok; $i++) {
        $c = if ($i -lt $chars.Length) { [int]$chars[$i] } else { -1 }
        if ($s.m -eq 's') {
            if ($c -eq -1) { $s.ok = $false }
            elseif ($s.hex -gt 0) {
                if (($c -ge 48 -and $c -le 57) -or ($c -ge 65 -and $c -le 70) -or ($c -ge 97 -and $c -le 102)) { $s.hex--; [void]$s.buf.Append([char]$c) } else { $s.ok = $false }
            }
            elseif ($s.esc) {
                if ($c -in 34, 92, 47, 98, 102, 110, 114, 116) { $s.esc = $false; [void]$s.buf.Append([char]$c) }
                elseif ($c -eq 117) { $s.esc = $false; $s.hex = 4; [void]$s.buf.Append([char]$c) }
                else { $s.ok = $false }
            }
            elseif ($c -eq 92) { $s.esc = $true; [void]$s.buf.Append([char]$c) }
            elseif ($c -eq 34) {
                $s.m = ''
                if ($s.key) { $s.frames[$s.frames.Count - 1].Add($s.buf.ToString()); $s.ex = ':' } else { $s.ex = & $after }
            }
            elseif ($c -lt 32) { $s.ok = $false }
            else { [void]$s.buf.Append([char]$c) }
            continue
        }
        if ($s.m -eq 'n') {
            $next = Get-ClaudeAnswersNumberStep $s.num $c
            if ($next -eq 'bad') { $s.ok = $false; continue }
            if ($next) { $s.num = $next; continue }
            if ($s.num -cnotin '0', 'i', 'f', 'x') { $s.ok = $false; continue }
            $s.m = ''; $s.ex = & $after
        }
        elseif ($s.m -eq 'l') {
            if ($c -ge 0 -and $s.lit.Length -and [int]$s.lit[0] -eq $c) { $s.lit = $s.lit.Substring(1); if (-not $s.lit) { $s.m = ''; $s.ex = & $after } } else { $s.ok = $false }
            continue
        }
        & $structural $c
    }
    return [pscustomobject]@{ Ok = [bool]$s.ok; Frames = @($s.out) }
}

function Resolve-ClaudeAnswersNode($Node) {
    # A schema node with its $ref replaced by the definition, the node's own keywords winning.
    $ref = [string]$Node.'$ref'
    if (-not $ref) { return $Node }
    $merged = [ordered]@{}
    foreach ($p in (Get-ClaudeAnswersSchema).Defs[$ref -replace '^#/\$defs/', ''].PSObject.Properties) { $merged[$p.Name] = $p.Value }
    foreach ($p in $Node.PSObject.Properties) { if ($p.Name -cne '$ref') { $merged[$p.Name] = $p.Value } }
    return [pscustomobject]$merged
}

function Test-ClaudeAnswersHolds($Conditions, $Values) {
    # Every condition holds: its answer is text and equals the value or is in the list.
    foreach ($c in @($Conditions)) {
        $x = if ($Values.ContainsKey([string]$c.answer)) { $Values[[string]$c.answer] } else { $null }
        if ($x -isnot [string]) { return $false }
        if ($c.PSObject.Properties.Name -contains 'equals') { if ($x -cne [string]$c.equals) { return $false } }
        elseif ($c.PSObject.Properties.Name -contains 'in') { if ($x -cnotin @($c.in)) { return $false } }
        else { return $false }
    }
    return $true
}

function Get-ClaudeAnswersCrossField($Rules, $Values, [string]$Path, [switch]$Item) {
    # x-crossField: when every condition holds, the rule's answer is required or forbidden.
    foreach ($r in @($Rules)) {
        if (-not $r -or -not (Test-ClaudeAnswersHolds $r.when $Values)) { continue }
        if ($r.require -and -not $Values.ContainsKey([string]$r.require)) {
            $p = if ($Item) { $Path } else { [string]$r.require }
            New-ClaudeAnswersProblem $r.checkId $p "$p $($r.message)" $r.remedy
        }
        elseif ($r.forbid -and $Values.ContainsKey([string]$r.forbid)) {
            $p = if ($Item) { "$Path.$($r.forbid)" } else { [string]$r.forbid }
            New-ClaudeAnswersProblem $r.checkId $p "$p $($r.message)" $r.remedy
        }
    }
}

function Test-ClaudeAnswersValue($Value, $Node, [string]$Path) {
    # The problems of one value against its schema node, in the order scripts/install-answers.jq
    # checks them; a scalar has one problem at most.
    $n = Resolve-ClaudeAnswersNode $Node
    $type = Get-ClaudeAnswersType $Value
    $names = @($n.PSObject.Properties.Name)
    $p = { param([string]$Message, [string]$Remedy, [string]$CheckId = 'answers.schema') New-ClaudeAnswersProblem $CheckId $Path $Message $Remedy }
    $is = $script:ClaudeAnswersTypeWords[$type]
    if ($names -contains 'const') {
        $want = $n.const
        if (-not ($type -eq (Get-ClaudeAnswersType $want) -and [double]$Value -eq [double]$want)) {
            $shown = ConvertTo-Json -InputObject $want -Compress
            & $p "$Path is not $shown" $(if ($n.'x-remedy') { $n.'x-remedy' } else { "Use $shown." })
        }
        return
    }
    $expect = [string]$n.type
    $word = $script:ClaudeAnswersExpectWords[$expect]
    switch -CaseSensitive ($expect) {
        'string' {
            if ($type -ne 'string') { & $p "$Path is $is, not text" "Give $Path as text."; return }
            if ($Value -match '[\x00-\x1f]') { & $p "$Path holds a control character" 'Remove the control character.'; return }
            if ($Value.StartsWith('@')) { & $p "$Path begins with @, which Azure CLI reads as a file name" 'Remove the leading @.'; return }
            $length = Get-ClaudeInstallCodePointLength $Value
            if ($names -contains 'minLength' -and $length -lt [int]$n.minLength) {
                & $p $(if ($length -eq 0) { "$Path is empty" } else { "$Path is shorter than $($n.minLength) characters" }) "Give a value for $Path, or leave it out."; return
            }
            if ($names -contains 'maxLength' -and $length -gt [int]$n.maxLength) { & $p "$Path is longer than $($n.maxLength) characters" "Shorten it to $($n.maxLength) characters."; return }
            if ($names -contains 'enum' -and $Value -cnotin @($n.enum)) { $list = @($n.enum) -join ', '; & $p "$Path '$Value' is not one of: $list" "Use one of: $list."; return }
            if ($names -contains 'pattern' -and $Value -cnotmatch [string]$n.pattern) {
                $why = if ($n.'x-patternMessage') { $n.'x-patternMessage' } else { 'does not have the expected form' }
                & $p "$Path '$Value' $why" $(if ($n.'x-remedy') { $n.'x-remedy' } else { 'Correct the value.' }) $(if ($n.'x-checkId') { $n.'x-checkId' } else { 'answers.schema' }); return
            }
        }
        { $_ -eq 'integer' -or $_ -eq 'number' } {
            if ($type -ne 'number') { & $p "$Path is $is, not $word" "Give $Path as $word."; return }
            $d = [double]$Value
            if ($expect -eq 'integer' -and $d -ne [math]::Floor($d)) { & $p "$Path is not a whole number" "Give $Path as a whole number."; return }
            $range = "Use a value from $($n.minimum) to $($n.maximum)."
            if ($names -contains 'minimum' -and $d -lt [double]$n.minimum) { & $p "$Path is below $($n.minimum)" $range; return }
            if ($names -contains 'maximum' -and $d -gt [double]$n.maximum) { & $p "$Path is above $($n.maximum)" $range; return }
        }
        'boolean' { if ($type -ne 'boolean') { & $p "$Path is $is, not true or false" "Give $Path as true or false." } }
        'array' {
            if ($type -ne 'array') { & $p "$Path is $is, not a list" "Give $Path as a list."; return }
            $items = @($Value)
            if ($names -contains 'minItems' -and $items.Count -lt [int]$n.minItems) { & $p "$Path is an empty list" 'Give at least one.'; return }
            for ($i = 0; $i -lt $items.Count; $i++) { Test-ClaudeAnswersValue $items[$i] $n.items "$Path[$i]" }
        }
        'object' {
            if ($type -ne 'object') { & $p "$Path is $is, not an object" "Give $Path as an object."; return }
            $fields = New-ClaudeAnswersMap $n.properties
            $values = if ($Value -is [System.Collections.IDictionary]) { $m = New-ClaudeAnswersMap $null; foreach ($k in $Value.Keys) { $m[[string]$k] = $Value[$k] }; $m } else { New-ClaudeAnswersMap $Value }
            foreach ($k in @($values.Keys)) {
                if ($fields.ContainsKey($k)) { Test-ClaudeAnswersValue $values[$k] $fields[$k] "$Path.$k" }
                else { New-ClaudeAnswersProblem 'answers.schema' "$Path.$k" "$Path.$k is not a field of $($n.title)" "Remove it; the fields are $(Join-ClaudeAnswersList @($fields.Keys))." }
            }
            foreach ($r in @($n.required)) { if ($r -and -not $values.ContainsKey([string]$r)) { & $p "$Path has no $r" "Add $r." } }
            Get-ClaudeAnswersCrossField $n.'x-crossField' $values $Path -Item
        }
    }
}

function Get-ClaudeAnswersField($Object, [string]$Name) {
    # One field of an object read from JSON or passed in, by its exact name.
    if ($Object -is [System.Collections.IDictionary]) { foreach ($k in @($Object.Keys)) { if ([string]$k -ceq $Name) { return , $Object[$k] } }; return $null }
    foreach ($p in $Object.PSObject.Properties) { if ($p.Name -ceq $Name) { return , $p.Value } }
    return $null
}

function Get-ClaudeAnswersTree($Units) {
    # Business units and teams: each id once (businessUnits.ids), and a parent that is a listed unit
    # without a parent of its own (businessUnits.depth: units hold teams, two levels, ADR-0008).
    if ((Get-ClaudeAnswersType $Units) -ne 'array') { return }
    $parentPattern = [string](Get-ClaudeAnswersSchema).Defs['BusinessUnit'].properties.parent.pattern
    $all = @($Units)
    $u = @(for ($i = 0; $i -lt $all.Count; $i++) {
            if ((Get-ClaudeAnswersType $all[$i]) -ne 'object') { continue }
            [pscustomobject]@{ i = $i; id = (Get-ClaudeAnswersField $all[$i] 'id'); parent = (Get-ClaudeAnswersField $all[$i] 'parent') }
        })
    $ids = @($u | Where-Object { $_.id -is [string] })
    foreach ($x in $ids) {
        $y = @($ids | Where-Object { $_.id -ceq $x.id -and $_.i -lt $x.i }) | Select-Object -First 1
        if ($y) { New-ClaudeAnswersProblem 'businessUnits.ids' "BusinessUnits[$($x.i)].id" "BusinessUnits[$($x.i)].id '$($x.id)' repeats BusinessUnits[$($y.i)].id" 'Give each unit and team its own id.' }
    }
    foreach ($x in @($u | Where-Object { $_.parent -is [string] -and $_.parent -cmatch $parentPattern })) {
        $path = "BusinessUnits[$($x.i)].parent"
        if ($x.parent -ceq $x.id) { New-ClaudeAnswersProblem 'businessUnits.depth' $path "BusinessUnits[$($x.i)] names itself as its parent" 'Name a unit as parent, or leave parent out.'; continue }
        $p = @($ids | Where-Object { $_.id -ceq $x.parent }) | Select-Object -First 1
        if (-not $p) { New-ClaudeAnswersProblem 'businessUnits.depth' $path "$path '$($x.parent)' names no unit in BusinessUnits" 'Name a unit listed in BusinessUnits, or leave parent out.'; continue }
        if ($p.parent -is [string] -and $p.parent -ne '') {
            New-ClaudeAnswersProblem 'businessUnits.depth' $path "BusinessUnits[$($x.i)] is a team of '$($p.id)', which is a team of '$($p.parent)'; units hold teams and teams hold none (two levels, ADR-0008)" 'Name a unit without a parent as the parent.'
        }
    }
}

function Test-ClaudeInstallerAnswers {
    # The problems of a set of answers for one program: an answers file's object, or answers passed as
    # parameters. An installer names an answer by its installer name; the guided flow by its flow key.
    param([Parameter(Mandatory = $true)][AllowNull()]$Answers,
        [Parameter(Mandatory = $true)][ValidateSet('Install-ClaudeGateway.ps1', 'install-claude-gateway.sh', 'Start-ClaudeGateway.ps1')][string]$Consumer)
    $S = Get-ClaudeAnswersSchema
    if ((Get-ClaudeAnswersType $Answers) -ne 'object') { return (New-ClaudeAnswersProblem 'answers.schema' '' 'the answers file is not a JSON object' 'Write the answers as one JSON object.') }
    $doc = if ($Answers -is [System.Collections.IDictionary]) { $m = New-ClaudeAnswersMap $null; foreach ($k in @($Answers.Keys)) { $m[[string]$k] = $Answers[$k] }; $m } else { New-ClaudeAnswersMap $Answers }
    $flow = $Consumer -eq 'Start-ClaudeGateway.ps1'
    $canon = New-ClaudeAnswersMap $null; $keyOf = New-ClaudeAnswersMap $null
    foreach ($k in @($doc.Keys)) {
        $v = $doc[$k]
        $problem = { param([string]$Message, [string]$Remedy) New-ClaudeAnswersProblem 'answers.schema' $k $Message $Remedy }
        $take = { param([string]$Name, $Node) $canon[$Name] = $v; $keyOf[$Name] = $k; Test-ClaudeAnswersValue $v $Node $k }
        $re = @($S.Patterns.Keys | Where-Object { $k -cmatch $_ }) | Select-Object -First 1
        if ($S.Secrets.ContainsKey($k)) { & $problem "$k is a secret, and an answers file holds no secrets" "Pass it when the program runs, as -$k, or answer its prompt."; continue }
        if ($S.Properties.ContainsKey($k)) {
            $node = $S.Properties[$k]; $by = @($node.'x-appliedBy'); $aliases = @($node.'x-flowKeys' | Where-Object { $_ })
            if ($flow -and $aliases.Count) { & $problem "$k is an installer name; a guided-flow answers file names it $($aliases[0])" "Name it $($aliases[0])."; continue }
            # An answer another program applies is reported, and its value still checked as that program checks it.
            if ($by -cnotcontains $Consumer) { & $problem "$k is applied by $(Join-ClaudeAnswersList $by); $Consumer does not apply it" "Remove it, or use $($by[0]), which applies it." }
            & $take $k $node; continue
        }
        if ($S.Aliases.ContainsKey($k)) {
            $name = $S.Aliases[$k]
            if (-not $flow) { & $problem "$k is a guided-flow name; an installer answers file names it $name" "Name it $name."; continue }
            & $take $name $S.Properties[$name]; continue
        }
        if ($re) {
            $node = $S.Patterns[$re]; $by = @($node.'x-appliedBy')
            if ($by -cnotcontains $Consumer) { & $problem "$k is applied by $(Join-ClaudeAnswersList $by); $Consumer does not apply it" "Remove it, or use $($by[0]), which applies it." }
            & $take $k $node; continue
        }
        if ($S.Controls.ContainsKey($k)) {
            $c = $S.Controls[$k]
            $flags = Join-ClaudeAnswersList @(@($c.'Install-ClaudeGateway.ps1', $c.'install-claude-gateway.sh') | Where-Object { $_ }) 'or'
            & $problem "$k is a run option, not an answer" "Pass it on the command line: $flags."; continue
        }
        & $problem "$k is not an answer in the answers schema" 'Remove it, or use a name from schemas/claude-gateway.answers.schema.json.'
    }
    Get-ClaudeAnswersCrossField $S.Document.'x-crossField' $canon ''
    # requires: a conditional answer contradicts the answer it depends on, when that answer is given.
    foreach ($name in @($canon.Keys)) {
        $node = $S.Properties[$name]
        if (-not $node -or -not $node.requires) { continue }
        foreach ($c in @($node.requires)) {
            $x = if ($canon.ContainsKey([string]$c.answer)) { $canon[[string]$c.answer] } else { $null }
            if ($x -isnot [string]) { continue }
            $equals = $c.PSObject.Properties.Name -contains 'equals'
            $holds = if ($equals) { $x -ceq [string]$c.equals } elseif ($c.PSObject.Properties.Name -contains 'in') { $x -cin @($c.in) } else { $true }
            if ($holds) { continue }
            $want = if ($equals) { [string]$c.equals } else { Join-ClaudeAnswersList @($c.in) 'or' }
            $k = $keyOf[$name]
            New-ClaudeAnswersProblem 'answers.crossField' $k "$k applies only when $($c.answer) is $want; the answers give $($c.answer) '$x'" "Remove $k, or set $($c.answer) to $want."
            break
        }
    }
    if ($canon.ContainsKey('BusinessUnits')) { Get-ClaudeAnswersTree $canon['BusinessUnits'] }
}

function Read-ClaudeInstallerAnswersFile {
    # An answers file's object, or the problems that stop it being read, as scripts/install-answers.jq
    # reads it: UTF-8 with a leading byte order mark dropped, strict JSON, property names in printable
    # ASCII, and no two names in one object that differ only in case (PowerShell refuses those).
    param([Parameter(Mandatory = $true)][string]$Path)
    $problem = { param([string]$Message, [string]$Remedy) [pscustomobject]@{ Document = $null; Problems = @(New-ClaudeAnswersProblem 'answers.schema' '' $Message $Remedy) } }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return (& $problem 'the answers file does not exist' 'Give the path of an answers file.') }
    $bytes = [IO.File]::ReadAllBytes($full)
    $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $start, $bytes.Length - $start)
    if ($text -match '^[\x20\x09\x0a\x0d]*$') { return (& $problem 'the answers file is empty' 'Write the answers as one JSON object.') }
    $notJson = { & $problem 'the answers file is not valid JSON' 'Correct the JSON: one object, with no comments and no trailing commas.' }
    $scan = Get-ClaudeAnswersScan $text
    if (-not $scan.Ok) { return (& $notJson) }
    foreach ($frame in $scan.Frames) {
        foreach ($k in @($frame)) {
            if ($k.Length -eq 0 -or $k -match '[^\x20-\x7e]' -or $k.Contains('\')) {
                return (& $problem 'a property name in the answers file is empty, holds an escape sequence or is not printable ASCII' 'Name each answer as the answers schema does.')
            }
        }
    }
    $dupes = [System.Collections.Generic.List[string]]::new()
    foreach ($frame in $scan.Frames) {
        foreach ($g in @(@($frame) | Group-Object { $_.ToLowerInvariant() })) { if ($g.Count -gt 1) { foreach ($n in $g.Group) { if (-not $dupes.Contains($n)) { $dupes.Add($n) } } } }
    }
    if ($dupes.Count) {
        [string[]]$names = $dupes.ToArray(); [Array]::Sort($names, [StringComparer]::Ordinal)
        return (& $problem "the answers file names properties that differ only in case or repeat: $($names -join ', ')" 'Keep one spelling of each name.')
    }
    $convert = @{ ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $convert['DateKind'] = 'String' }
    try { $doc = $text | ConvertFrom-Json @convert } catch { return (& $notJson) }
    return [pscustomobject]@{ Document = $doc; Problems = @() }
}

function Test-ClaudeInstallerAnswersFile {
    # Every problem of an answers file for one program (tests/Test-InstallerAnswersSchema.ps1).
    param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('Install-ClaudeGateway.ps1', 'install-claude-gateway.sh', 'Start-ClaudeGateway.ps1')][string]$Consumer)
    $read = Read-ClaudeInstallerAnswersFile -Path $Path
    if ($read.Problems.Count) { return $read.Problems }
    return @(Test-ClaudeInstallerAnswers -Answers $read.Document -Consumer $Consumer)
}

function Import-ClaudeInstallerAnswers {
    # A run's answers file (A12): any problem refuses on one line before anything is read from Azure.
    # Each answer the run does not pass as a parameter is returned typed as its parameter, to be bound as
    # if passed, so it wins over the install checkpoint's answers and is held to its binding.
    param([Parameter(Mandatory = $true)][string]$Path, [System.Collections.IDictionary]$Bound = @{})
    $read = Read-ClaudeInstallerAnswersFile -Path $Path
    $problems = @($read.Problems)
    if (-not $problems.Count) { $problems = @(Test-ClaudeInstallerAnswers -Answers $read.Document -Consumer 'Install-ClaudeGateway.ps1') }
    if ($problems.Count) {
        # The first problem with its remedy, the number of problems, and the command that lists every one.
        $count = if ($problems.Count -eq 1) { '1 problem' } else { "$($problems.Count) problems" }
        $remedy = ([string]$problems[0].remedy).Trim()
        if ($remedy -and -not $remedy.EndsWith('.')) { $remedy += '.' }
        $quoted = "'" + $Path.Replace("'", "''") + "'"
        Stop-ClaudeInstall "the answers file $Path does not match the answers schema ($count). $(([string]$problems[0].message).TrimEnd('.')).$(if ($remedy) { " Remedy: $remedy" }) Nothing was changed. ./Install-ClaudeGateway.ps1 -Preflight -AnswersPath $quoted lists every problem."
    }
    $S = Get-ClaudeAnswersSchema
    $out = [ordered]@{}
    foreach ($p in $read.Document.PSObject.Properties) {
        if (-not $S.Properties.ContainsKey($p.Name) -or @($Bound.Keys) -contains $p.Name) { continue }
        $out[$p.Name] = switch ([string]$S.Properties[$p.Name].type) {
            'integer' { [int]$p.Value }
            'boolean' { [bool]$p.Value }
            'array' { if ($p.Name -in 'StandardModels', 'PremiumModels') { , [string[]]@($p.Value) } else { , @($p.Value) } }
            default { $p.Value }
        }
    }
    return $out
}
