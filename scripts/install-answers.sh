# The answers file of install-claude-gateway.sh (docs/adr/0047-lean-installer-phase-0.md). It is checked
# with scripts/install-answers.jq against schemas/claude-gateway.answers.schema.json, the rules
# scripts/ClaudeInstallerAnswers.ps1 applies, then applied under this run's flags: flag, answers file,
# checkpoint, default (A12). Sourced by the installer after scripts/install-checkpoint.sh, and by
# tests/Test-InstallerAnswersSchema.ps1 on its own with HERE set. Bash 3.2 and later, with jq.

ANSWERS_SCHEMA="$HERE/schemas/claude-gateway.answers.schema.json"
ANSWERS_JQ="$HERE/scripts/install-answers.jq"
ANSWERS_JSON=""

# file program: the problems of an answers file for a program, one JSON list on one line.
answers_check_file_() {
  if [ ! -f "$1" ]; then
    printf '[{"checkId":"answers.schema","path":"","message":"the answers file does not exist","remedy":"Give the path of an answers file."}]\n'
    return 0
  fi
  jq -Rs -c --slurpfile schema "$ANSWERS_SCHEMA" --arg consumer "$2" --arg mode text -f "$ANSWERS_JQ" "$1" | tr -d '\r'
}
# json program: the problems of a JSON object of answers for a program.
answers_check_json_() {
  printf '%s' "$1" | jq -c --slurpfile schema "$ANSWERS_SCHEMA" --arg consumer "$2" --arg mode object -f "$ANSWERS_JQ" | tr -d '\r'
}
# The answers file as one JSON object, its byte order mark dropped as the check drops it.
answers_read_() { jq -Rs -c 'ltrimstr("\ufeff") | fromjson' "$1" | tr -d '\r'; }
# The answers this run names by a flag, as a JSON object keyed by installer name (CKPT_ANSWERS).
answers_flags_json_() {
  local name var flag kind value
  while read -r name var flag kind; do
    [ -n "$name" ] || continue
    ckpt_passed_ "$flag" || continue
    eval "value=\${$var:-}"
    printf '%s\t%s\t%s\n' "$name" "$kind" "$value"
  done <<EOF | jq -cR -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (if .[1] == "i" then (.[2] | tonumber? // .[2]) else .[2] end)}) | add // {}' | tr -d '\r'
$CKPT_ANSWERS
EOF
}

# Each answer of the file that this run does not name by a flag is set as if passed, so it wins over
# the checkpoint's answers and binds the checkpoint (ADR-0046 R3). A file with any problem refuses on
# one line, before anything is read from Azure or changed.
answers_apply_() {
  [ -n "${ANSWERS_FILE:-}" ] || return 0
  local problems count first more="" remedy name var flag kind value
  problems="$(answers_check_file_ "$ANSWERS_FILE" install-claude-gateway.sh)"
  count="$(printf '%s' "$problems" | jq 'length' | tr -d '\r')"
  if [ "$count" != "0" ]; then
    # The first problem with its remedy, the number of problems, and the command that lists every one.
    first="$(printf '%s' "$problems" | jq -r '.[0].message' | tr -d '\r')"; remedy="$(printf '%s' "$problems" | jq -r '.[0].remedy // ""' | tr -d '\r')"
    if [ "$count" = "1" ]; then more="1 problem"; else more="$count problems"; fi
    case "$remedy" in ""|*.) ;; *) remedy="$remedy." ;; esac
    ckpt_refuse_ "the answers file $ANSWERS_FILE does not match the answers schema ($more). ${first%.}.${remedy:+ Remedy: $remedy} Nothing was changed. ./install-claude-gateway.sh --preflight --answers-file $(ckpt_quote_ "$ANSWERS_FILE") lists every problem."
  fi
  ANSWERS_JSON="$(answers_read_ "$ANSWERS_FILE")"
  while read -r name var flag kind; do
    [ -n "$name" ] || continue
    ckpt_passed_ "$flag" && continue
    value="$(printf '%s' "$ANSWERS_JSON" | jq -r --arg n "$name" 'if has($n) then (.[$n] | if type == "number" then floor else . end | tostring) else empty end' | tr -d '\r')"
    [ -n "$value" ] || continue
    printf -v "$var" '%s' "$value"
    CKPT_SEEN="$CKPT_SEEN $flag"
  done <<EOF
$CKPT_ANSWERS
EOF
}
