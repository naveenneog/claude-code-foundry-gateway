# The answers schema check for install-claude-gateway.sh (docs/adr/0047-lean-installer-phase-0.md): the
# same rules, in the same order and with the same words, as scripts/ClaudeInstallerAnswers.ps1, so both
# installers report the same problems for one answers file (tests/Test-InstallerAnswersSchema.ps1).
# Input: the answers file as raw text ($mode "text", jq -Rs) or a JSON object ($mode "object").
# $schema[0] is schemas/claude-gateway.answers.schema.json; $consumer is the program the answers are for.
# Output: a JSON list of problems {checkId, path, message, remedy}. jq 1.5 and later.

def problem($c; $p; $m; $r): {checkId: $c, path: $p, message: $m, remedy: $r};
def andlist: if length <= 1 then (.[0] // "") else (.[:-1] | join(", ")) + " and " + .[-1] end;
def orlist: if length <= 1 then (.[0] // "") else (.[:-1] | join(", ")) + " or " + .[-1] end;
def typeword: {"string": "text", "number": "a number", "boolean": "true or false", "array": "a list", "object": "an object", "null": "null"}[type];
def expectword($t): {"string": "text", "integer": "a whole number", "number": "a number", "boolean": "true or false", "array": "a list", "object": "an object"}[$t];

# A strict JSON scanner (RFC 8259), the same state machine as Get-ClaudeAnswersScan: whether the text is
# JSON, and the property names of each object as written between the quotes.
def numstep($s; $c):
  ($c >= 48 and $c <= 57) as $d | ($c == 101 or $c == 69) as $e
  | if $s == "-" then (if $c == 48 then "0" elif $d then "i" else "" end)
    elif $s == "0" then (if $c == 46 then "." elif $e then "e" else "" end)
    elif $s == "i" then (if $d then "i" elif $c == 46 then "." elif $e then "e" else "" end)
    elif $s == "." then (if $d then "f" else "bad" end)
    elif $s == "f" then (if $d then "f" elif $e then "e" else "" end)
    elif $s == "e" then (if $c == 43 or $c == 45 then "s" elif $d then "x" else "bad" end)
    elif $s == "s" then (if $d then "x" else "bad" end)
    elif $s == "x" then (if $d then "x" else "" end)
    else "bad" end;
def afterv: if (.st | length) == 0 then "e" else "," end;
def closeit: (if .st[-1] == "o" then .out += [.frames[-1]] | .frames = .frames[:-1] else . end) | .st = .st[:-1] | .ex = afterv;
def structural($c):
  if $c == 32 or $c == 9 or $c == 10 or $c == 13 then .
  elif $c == -1 then (if .ex == "e" then . else .ok = false end)
  elif .ex == "v" or .ex == "V" then
    if $c == 123 then .st += ["o"] | .frames += [[]] | .ex = "K"
    elif $c == 91 then .st += ["a"] | .ex = "V"
    elif $c == 34 then .m = "s" | .key = false | .buf = []
    elif $c == 45 or ($c >= 48 and $c <= 57) then .m = "n" | .num = (if $c == 45 then "-" elif $c == 48 then "0" else "i" end)
    elif $c == 116 then .m = "l" | .lit = [114, 117, 101]
    elif $c == 102 then .m = "l" | .lit = [97, 108, 115, 101]
    elif $c == 110 then .m = "l" | .lit = [117, 108, 108]
    elif $c == 93 and .ex == "V" then closeit
    else .ok = false end
  elif .ex == "k" or .ex == "K" then
    if $c == 34 then .m = "s" | .key = true | .buf = []
    elif $c == 125 and .ex == "K" then closeit
    else .ok = false end
  elif .ex == ":" then (if $c == 58 then .ex = "v" else .ok = false end)
  elif .ex == "," then
    if $c == 44 then (if .st[-1] == "o" then .ex = "k" else .ex = "v" end)
    elif ($c == 125 and .st[-1] == "o") or ($c == 93 and .st[-1] == "a") then closeit
    else .ok = false end
  else .ok = false end;
def scan:
  reduce (explode[], -1) as $c ({ok: true, st: [], ex: "v", m: "", esc: false, hex: 0, key: false, buf: [], num: "", lit: [], frames: [], out: []};
    if .ok | not then .
    elif .m == "s" then
      if $c == -1 then .ok = false
      elif .hex > 0 then (if ($c >= 48 and $c <= 57) or ($c >= 65 and $c <= 70) or ($c >= 97 and $c <= 102) then .hex -= 1 | .buf += [$c] else .ok = false end)
      elif .esc then (if ([34, 92, 47, 98, 102, 110, 114, 116] | index([$c])) != null then .esc = false | .buf += [$c] elif $c == 117 then .esc = false | .hex = 4 | .buf += [$c] else .ok = false end)
      elif $c == 92 then .esc = true | .buf += [$c]
      elif $c == 34 then .m = "" | (if .key then .frames[(.frames | length) - 1] += [.buf | implode] | .ex = ":" else .ex = afterv end)
      elif $c < 32 then .ok = false
      else .buf += [$c] end
    elif .m == "n" then
      .num as $num
      | numstep($num; $c) as $next
      | if $next == "bad" then .ok = false
        elif $next != "" then .num = $next
        elif (["0", "i", "f", "x"] | index([$num])) == null then .ok = false
        else .m = "" | .ex = afterv | structural($c) end
    elif .m == "l" then
      if $c >= 0 and (.lit | length) > 0 and .lit[0] == $c then .lit = .lit[1:] | (if (.lit | length) == 0 then .m = "" | .ex = afterv else . end) else .ok = false end
    else structural($c) end)
  | {ok: .ok, frames: .out};

def resolve($S): if has("$ref") then ($S["$defs"][(.["$ref"] | ltrimstr("#/$defs/"))] + del(.["$ref"])) else . end;
def holds($vals): all(.[]; . as $c | ($vals[$c.answer]) as $x | ($x | type) == "string"
  and (if ($c | has("equals")) then $x == $c.equals elif ($c | has("in")) then ($c.in | index([$x])) != null else false end));
def crossfield($rules; $path; $item):
  . as $vals
  | [ $rules[] | . as $r | select($r.when | holds($vals))
      | if ($r.require != null) and (($vals | has($r.require)) | not) then
          (if $item then $path else $r.require end) as $p | problem($r.checkId; $p; "\($p) \($r.message)"; $r.remedy)
        elif ($r.forbid != null) and ($vals | has($r.forbid)) then
          (if $item then "\($path).\($r.forbid)" else $r.forbid end) as $p | problem($r.checkId; $p; "\($p) \($r.message)"; $r.remedy)
        else empty end ];

def validate($S; $node; $path):
  ($node | resolve($S)) as $n
  | . as $v
  | (type) as $t
  | ($v | typeword) as $is
  | if ($n | has("const")) then
      (if $t == ($n.const | type) and $v == $n.const then [] else [problem("answers.schema"; $path; "\($path) is not \($n.const | tojson)"; ($n["x-remedy"] // "Use \($n.const | tojson)."))] end)
    elif $n.type == "string" then
      if $t != "string" then [problem("answers.schema"; $path; "\($path) is \($is), not text"; "Give \($path) as text.")]
      elif ($v | explode | any(.[]; . < 32)) then [problem("answers.schema"; $path; "\($path) holds a control character"; "Remove the control character.")]
      elif ($v | startswith("@")) then [problem("answers.schema"; $path; "\($path) begins with @, which Azure CLI reads as a file name"; "Remove the leading @.")]
      elif ($n.minLength != null) and (($v | length) < $n.minLength) then
        [problem("answers.schema"; $path; (if ($v | length) == 0 then "\($path) is empty" else "\($path) is shorter than \($n.minLength) characters" end); "Give a value for \($path), or leave it out.")]
      elif ($n.maxLength != null) and (($v | length) > $n.maxLength) then [problem("answers.schema"; $path; "\($path) is longer than \($n.maxLength) characters"; "Shorten it to \($n.maxLength) characters.")]
      elif ($n.enum != null) and (($n.enum | index([$v])) == null) then
        ($n.enum | join(", ")) as $list | [problem("answers.schema"; $path; "\($path) '\($v)' is not one of: \($list)"; "Use one of: \($list).")]
      elif ($n.pattern != null) and (($v | test($n.pattern)) | not) then
        [problem(($n["x-checkId"] // "answers.schema"); $path; "\($path) '\($v)' \($n["x-patternMessage"] // "does not have the expected form")"; ($n["x-remedy"] // "Correct the value."))]
      else [] end
    elif $n.type == "integer" or $n.type == "number" then
      expectword($n.type) as $word
      | "Use a value from \($n.minimum) to \($n.maximum)." as $range
      | if $t != "number" then [problem("answers.schema"; $path; "\($path) is \($is), not \($word)"; "Give \($path) as \($word).")]
        elif $n.type == "integer" and $v != ($v | floor) then [problem("answers.schema"; $path; "\($path) is not a whole number"; "Give \($path) as a whole number.")]
        elif ($n.minimum != null) and $v < $n.minimum then [problem("answers.schema"; $path; "\($path) is below \($n.minimum)"; $range)]
        elif ($n.maximum != null) and $v > $n.maximum then [problem("answers.schema"; $path; "\($path) is above \($n.maximum)"; $range)]
        else [] end
    elif $n.type == "boolean" then
      (if $t != "boolean" then [problem("answers.schema"; $path; "\($path) is \($is), not true or false"; "Give \($path) as true or false.")] else [] end)
    elif $n.type == "array" then
      if $t != "array" then [problem("answers.schema"; $path; "\($path) is \($is), not a list"; "Give \($path) as a list.")]
      elif ($n.minItems != null) and (($v | length) < $n.minItems) then [problem("answers.schema"; $path; "\($path) is an empty list"; "Give at least one.")]
      else [ range(0; $v | length) as $i | ($v[$i] | validate($S; $n.items; "\($path)[\($i)]"))[] ] end
    elif $n.type == "object" then
      if $t != "object" then [problem("answers.schema"; $path; "\($path) is \($is), not an object"; "Give \($path) as an object.")]
      else
        ($n.properties // {}) as $fields
        | [ $v | to_entries[] | .key as $k | .value as $x
            | if ($fields | has($k)) then ($x | validate($S; $fields[$k]; "\($path).\($k)"))[]
              else problem("answers.schema"; "\($path).\($k)"; "\($path).\($k) is not a field of \($n.title)"; "Remove it; the fields are \($fields | keys_unsorted | andlist).") end ]
          + [ ($n.required // [])[] as $r | select(($v | has($r)) | not) | problem("answers.schema"; $path; "\($path) has no \($r)"; "Add \($r).") ]
          + ($v | crossfield($n["x-crossField"] // []; $path; true))
      end
    else [] end;

def tree($S; $units):
  if ($units | type) != "array" then [] else
    ($S["$defs"].BusinessUnit.properties.parent.pattern) as $pp
    | [ $units | to_entries[] | select(.value | type == "object") | {i: .key, id: .value.id, parent: .value.parent} ] as $u
    | [ $u[] | select(.id | type == "string") ] as $ids
    | [ $ids[] | . as $x | ([ $ids[] | select(.id == $x.id and .i < $x.i) ][0]) as $y | select($y != null)
        | problem("businessUnits.ids"; "BusinessUnits[\($x.i)].id"; "BusinessUnits[\($x.i)].id '\($x.id)' repeats BusinessUnits[\($y.i)].id"; "Give each unit and team its own id.") ]
    + [ $u[] | select((.parent | type) == "string" and (.parent | test($pp))) | . as $x
        | "BusinessUnits[\($x.i)].parent" as $path
        | if $x.parent == $x.id then problem("businessUnits.depth"; $path; "BusinessUnits[\($x.i)] names itself as its parent"; "Name a unit as parent, or leave parent out.")
          else ([ $ids[] | select(.id == $x.parent) ][0]) as $p
            | if $p == null then problem("businessUnits.depth"; $path; "\($path) '\($x.parent)' names no unit in BusinessUnits"; "Name a unit listed in BusinessUnits, or leave parent out.")
              elif ($p.parent | type) == "string" and $p.parent != "" then
                problem("businessUnits.depth"; $path; "BusinessUnits[\($x.i)] is a team of '\($p.id)', which is a team of '\($p.parent)'; units hold teams and teams hold none (two levels, ADR-0008)"; "Name a unit without a parent as the parent.")
              else empty end
          end ]
  end;

def check_doc($S; $consumer):
  if type != "object" then [problem("answers.schema"; ""; "the answers file is not a JSON object"; "Write the answers as one JSON object.")]
  else
    . as $doc
    | ($consumer == "Start-ClaudeGateway.ps1") as $flow
    | ([ $S.properties | to_entries[] | .key as $n | (.value["x-flowKeys"] // [])[] | {key: ., value: $n} ] | from_entries) as $alias
    | [ $doc | to_entries[] | .key as $k | .value as $v
        | ([ $S.patternProperties | keys_unsorted[] | select(. as $re | $k | test($re)) ][0]) as $re
        | def bad($m; $r): {problem: problem("answers.schema"; $k; $m; $r)};
          def take($n; $node): {name: $n, key: $k, value: $v, node: $node};
          # An answer another program applies is reported, and its value still checked as that program checks it.
          def applied($node): ($node["x-appliedBy"] // []) as $by
            | if ($by | index([$consumer])) == null then take($k; $node) + bad("\($k) is applied by \($by | andlist); \($consumer) does not apply it"; "Remove it, or use \($by[0]), which applies it.") else take($k; $node) end;
        if ($S["x-secrets"] | has($k)) then bad("\($k) is a secret, and an answers file holds no secrets"; "Pass it when the program runs, as -\($k), or answer its prompt.")
        elif ($S.properties | has($k)) then
          ($S.properties[$k]) as $node | ($node["x-flowKeys"] // []) as $aka
          | if $flow and ($aka | length) > 0 then bad("\($k) is an installer name; a guided-flow answers file names it \($aka[0])"; "Name it \($aka[0]).")
            else applied($node) end
        elif ($alias | has($k)) then
          ($alias[$k]) as $n
          | if $flow then take($n; $S.properties[$n]) else bad("\($k) is a guided-flow name; an installer answers file names it \($n)"; "Name it \($n).") end
        elif $re != null then applied($S.patternProperties[$re])
        elif ($S["x-runControls"] | has($k)) then
          ([ $S["x-runControls"][$k]["Install-ClaudeGateway.ps1"], $S["x-runControls"][$k]["install-claude-gateway.sh"] ] | map(select(. != null)) | orlist) as $flags
          | bad("\($k) is a run option, not an answer"; "Pass it on the command line: \($flags).")
        else bad("\($k) is not an answer in the answers schema"; "Remove it, or use a name from schemas/claude-gateway.answers.schema.json.") end ] as $entries
    | ([ $entries[] | select(.name != null) | {key: .name, value: .value} ] | from_entries) as $canon
    | ([ $entries[] | select(.name != null) | {key: .name, value: .key} ] | from_entries) as $keyof
    | [ $entries[] | (if .problem != null then .problem else empty end), (if .node != null then (. as $e | $e.value | validate($S; $e.node; $e.key))[] else empty end) ]
      + ($canon | crossfield($S["x-crossField"] // []; ""; false))
      + [ $canon | keys_unsorted[] as $name | ($S.properties[$name].requires // null) as $req | select($req != null)
          | [ $req[] | . as $c | ($canon[$c.answer]) as $x | select(($x | type) == "string")
              | (if ($c | has("equals")) then $x == $c.equals elif ($c | has("in")) then ($c.in | index([$x])) != null else true end) as $ok
              | select($ok | not)
              | (if ($c | has("equals")) then $c.equals else ($c.in | orlist) end) as $want
              | $keyof[$name] as $k
              | problem("answers.crossField"; $k; "\($k) applies only when \($c.answer) is \($want); the answers give \($c.answer) '\($x)'"; "Remove \($k), or set \($c.answer) to \($want).") ][0] // empty ]
      + (if $canon | has("BusinessUnits") then tree($S; $canon.BusinessUnits) else [] end)
  end;

def check_text($S; $consumer):
  ltrimstr("\ufeff") as $t
  | if ($t | explode | all(.[]; . == 32 or . == 9 or . == 10 or . == 13)) then [problem("answers.schema"; ""; "the answers file is empty"; "Write the answers as one JSON object.")]
    else ($t | scan) as $sc
      | if ($sc.ok | not) then [problem("answers.schema"; ""; "the answers file is not valid JSON"; "Correct the JSON: one object, with no comments and no trailing commas.")]
        elif any($sc.frames[][]; . == "" or (explode | any(.[]; . < 32 or . > 126 or . == 92))) then
          [problem("answers.schema"; ""; "a property name in the answers file is empty, holds an escape sequence or is not printable ASCII"; "Name each answer as the answers schema does.")]
        else
          ([ $sc.frames[] | group_by(ascii_downcase)[] | select(length > 1)[] ] | unique) as $dupes
          | if ($dupes | length) > 0 then [problem("answers.schema"; ""; "the answers file names properties that differ only in case or repeat: \($dupes | join(", "))"; "Keep one spelling of each name.")]
            else ($t | fromjson | check_doc($S; $consumer)) end
        end
    end;

if $mode == "text" then check_text($schema[0]; $consumer) else check_doc($schema[0]; $consumer) end
