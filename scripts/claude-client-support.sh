# Shared by setup-claude-workstation.sh and debug-claude-workstation.sh: what Claude Code must be
# told about the recorded models, and a bounded way to run a client command. Source it; it defines
# functions and ALL_CAPS and runs nothing. The rules mirror scripts/ClaudeClientSupport.ps1
# (sources there, ADR-0031); tests/Test-WorkstationClients.ps1 fails when the two disagree.
#
# Callers set CONFIG_RAW to the text of claude-gateway.json, or leave it empty.

# Opus 4.7 and later, Sonnet 5 and later, and Fable and Mythos 5 and later get every capability,
# so a model released after this file in one of those families works without a change.
ALL_CAPS="effort,xhigh_effort,max_effort,thinking,adaptive_thinking,interleaved_thinking"

# jq -r for a value. A Windows jq.exe, which WSL finds on the Windows PATH it appends, ends every
# line with CRLF, and a carriage return left in a deployment name or URL breaks every match.
jq_value_() { jq -r "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }

# 0 when version $1 is at least $2; both x.y.z.
version_at_least_() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}
version_gt_() { [ "$1" != "$2" ] && version_at_least_ "$1" "$2"; }

# claude-<family>-<major>[-<minor>][-<yyyymmdd>] -> "family major.minor base", or nothing.
model_identity_() {
  if [[ "$1" =~ ^claude-([a-z]+)-([0-9]+)(-([0-9]{1,2}))?(-[0-9]{8})?$ ]]; then
    local fam="${BASH_REMATCH[1]}" maj="${BASH_REMATCH[2]}" min="${BASH_REMATCH[4]}"
    local base="claude-$fam-$maj"; [ -n "$min" ] && base="$base-$min"
    printf '%s %s.%s %s' "$fam" "$maj" "${min:-0}" "$base"
  fi
}
model_caps_() {
  local id fam ver floor
  id="$(model_identity_ "$1")"; [ -z "$id" ] && return 0
  fam="${id%% *}"; ver="$(printf '%s' "$id" | cut -d' ' -f2)"
  case "$fam" in opus) floor="4.7" ;; sonnet|fable|mythos) floor="5.0" ;; *) return 0 ;; esac
  if version_at_least_ "$ver.0" "$floor.0"; then printf '%s' "$ALL_CAPS"; fi
}
# The first Claude Code release that knows a model, from the changelog.
model_min_claude_code_() {
  local base
  base="$(model_identity_ "$1" | cut -d' ' -f3)"
  case "$base" in
    claude-opus-4-7) printf '2.1.111' ;;
    claude-fable-5) printf '2.1.170' ;;
    claude-sonnet-5) printf '2.1.197' ;;
    claude-opus-5) printf '2.1.219' ;;
    claude-fable-5-1) printf '2.1.257' ;;
    claude-opus-5-5) printf '2.1.280' ;;
    *) printf '' ;;
  esac
}
# The model behind a deployment name, from the record when it says; otherwise the name itself.
model_of_() {
  local m=""
  if [ -n "${CONFIG_RAW:-}" ] && command -v jq >/dev/null 2>&1; then
    m="$(printf '%s' "$CONFIG_RAW" | jq_value_ --arg n "$1" '(.deployments // [])[] | select(.name == $n) | .model // empty' 2>/dev/null | head -1)"
  fi
  if [ -n "$m" ]; then printf '%s' "$m"; else printf '%s' "$1"; fi
}
# 0 when the record lists a deployment with this name: in `deployments`, or in `models` for a record
# written before the installer recorded deployments, as Get-ClaudeRecordedDeployment reads it.
deployment_recorded_() {
  [ -n "${CONFIG_RAW:-}" ] && command -v jq >/dev/null 2>&1 &&
    [ "$(printf '%s' "$CONFIG_RAW" | jq_value_ --arg n "$1" '((.deployments // []) | map(.name // empty)) as $d | (if ($d | length) > 0 then $d else ((.models // []) | map(strings)) end) | index($n) != null' 2>/dev/null)" = "true" ]
}
# The capabilities a deployment's model takes. An administrator's override in the record wins: a
# capability list, or "none".
deployment_caps_() {
  local over=""
  if [ -n "${CONFIG_RAW:-}" ] && command -v jq >/dev/null 2>&1; then
    over="$(printf '%s' "$CONFIG_RAW" | jq_value_ --arg n "$1" '(.deployments // [])[] | select(.name == $n) | .capabilities // empty' 2>/dev/null | head -1)"
  fi
  if [ "$over" = "none" ]; then return 0; fi
  if [ -n "$over" ]; then printf '%s' "$over"; else model_caps_ "$(model_of_ "$1")"; fi
}
# The first Claude Code release that knows a deployment's model: the record's claudeCode, else the
# table; nothing when the deployment needs no declaration, as Get-ClaudeCodeRequiredVersion does.
deployment_min_claude_code_() {
  local over=""
  [ -z "$(deployment_caps_ "$1")" ] && return 0
  if [ -n "${CONFIG_RAW:-}" ] && command -v jq >/dev/null 2>&1; then
    over="$(printf '%s' "$CONFIG_RAW" | jq_value_ --arg n "$1" '(.deployments // [])[] | select(.name == $n) | .claudeCode // empty' 2>/dev/null | head -1)"
  fi
  if [ -n "$over" ]; then printf '%s' "$over"; else model_min_claude_code_ "$(model_of_ "$1")"; fi
}

# A capability list as a sorted, comma-separated set.
caps_norm_() {
  printf '%s' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]' | sed '/^$/d' | sort -u | paste -sd, -
}
has_cap_() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }

# Whether Claude Code's requests for one pinned alias work: "ok|", "warn|<reason>" or
# "fail|<reason>". Arguments: the capability variable, the pinned deployment name, its declared
# value (may be empty), and the installed Claude Code version. Measured 2026-09-27 by capturing
# the request each release sent to a local stand-in for the gateway: a declaration listing
# adaptive_thinking made 2.1.101 and 2.1.272 send adaptive thinking; thinking without
# adaptive_thinking made both send thinking.type.enabled, which the 5-series models refuse with
# 400, and only 2.1.272 then retried with adaptive thinking; with no declaration, 2.1.101 sent
# thinking.type.enabled for the name claude-sonnet-5 and adaptive thinking for prod-fast, and
# 2.1.272 sent adaptive thinking for both. Get-ClaudeCodeAliasCheck is the PowerShell twin.
alias_check_() {
  local var="$1" pinned="$2" declared="$3" have="$4"
  local caps release base label d e knows=0
  caps="$(deployment_caps_ "$pinned")"
  if [ -z "$caps" ]; then
    if [ -n "$declared" ] && deployment_recorded_ "$pinned"; then
      printf 'warn|%s is set for %s, which the record does not declare; a declaration turns off every capability it does not list' "$var" "$pinned"
    else
      printf 'ok|'
    fi
    return 0
  fi
  base="$(model_identity_ "$(model_of_ "$pinned")" | cut -d' ' -f3)"; [ -z "$base" ] && base="$(model_of_ "$pinned")"
  label="$pinned"; [ "$base" != "$pinned" ] && label="$pinned ($base)"
  release="$(deployment_min_claude_code_ "$pinned")"
  if [ -n "$release" ] && [ -n "$have" ] && version_at_least_ "$have" "$release"; then knows=1; fi
  if [ -n "$declared" ]; then
    d="$(caps_norm_ "$declared")"; e="$(caps_norm_ "$caps")"
    if [ "$d" = "$e" ]; then printf 'ok|'; return 0; fi
    if has_cap_ "$d" thinking && ! has_cap_ "$d" adaptive_thinking && has_cap_ "$e" adaptive_thinking; then
      if [ "$knows" = "1" ]; then
        printf 'warn|%s lists thinking without adaptive_thinking for %s: Claude Code sends thinking.type.enabled first, and retries with adaptive thinking after the 400' "$var" "$label"
      else
        printf 'fail|%s lists thinking without adaptive_thinking for %s: Claude Code %s sends thinking.type.enabled, which the model refuses with 400' "$var" "$label" "${have:-of unknown version}"
      fi
      return 0
    fi
    printf "warn|%s is '%s' for %s, where the record expects '%s'; a declaration turns off every capability it does not list" "$var" "$declared" "$label" "$caps"
    return 0
  fi
  if [ -z "$release" ]; then
    printf 'warn|%s is not set for %s, and no Claude Code release is recorded as knowing that model' "$var" "$label"
  elif [ "$knows" = "1" ]; then
    printf 'ok|'
  elif [ -n "$(model_identity_ "$pinned")" ]; then
    printf 'fail|%s is not set for %s, and Claude Code %s predates that model (first known to Claude Code %s): it sends thinking.type.enabled, which the model refuses with 400' "$var" "$label" "${have:-of unknown version}" "$release"
  else
    printf 'warn|%s is not set for %s, and Claude Code %s predates that model (first known to Claude Code %s): what it sends for the name %s depends on the release' "$var" "$label" "${have:-of unknown version}" "$release" "$pinned"
  fi
  return 0
}

# Runs a command for at most $1 seconds, then ends it and everything it started: TERM, then KILL 5 s
# later, to the command's own process group. Returns 124 when it ran out of time. The group comes
# from perl (setpgrp; macOS ships perl), setsid (util-linux) or GNU timeout, which is started with
# a longer timer than this one so that only this watchdog decides. Once the time is up the watchdog
# always finishes, so a child that outlives the command on TERM still gets KILL and releases the
# output it holds. With none of the three only the command itself can be ended.
# CLAUDE_BOUNDED_GROUP=perl|setsid|timeout|none picks one, for tests.
run_bounded_() {
  local secs="$1" rc pid watchdog marker target provider tool
  shift
  provider="${CLAUDE_BOUNDED_GROUP:-}"
  if [ -z "$provider" ]; then
    if command -v perl >/dev/null 2>&1; then provider=perl
    elif command -v setsid >/dev/null 2>&1; then provider=setsid
    elif command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then provider=timeout
    else provider=none
    fi
  fi
  marker="$(mktemp 2>/dev/null || printf '%s/claude-bounded-%s-%s' "${TMPDIR:-/tmp}" "$$" "$RANDOM")"
  rm -f "$marker"
  case "$provider" in
    perl)
      perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127;' -- "$@" &
      pid=$!; target="-$pid" ;;
    setsid)
      # A background job of a shell without job control is not a group leader, so setsid does
      # not fork and the job itself leads the new group.
      setsid "$@" &
      pid=$!; target="-$pid" ;;
    timeout)
      tool=timeout; command -v timeout >/dev/null 2>&1 || tool=gtimeout
      "$tool" -k 5 $(( secs + 30 )) "$@" &
      pid=$!; target="-$pid" ;;
    *)
      "$@" &
      pid=$!; target="$pid" ;;
  esac
  ( sleep "$secs"; : > "$marker"
    kill -TERM -- "$target" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
    sleep 5
    kill -KILL -- "$target" 2>/dev/null; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid"; rc=$?
  if [ -e "$marker" ]; then
    wait "$watchdog" 2>/dev/null
    rm -f "$marker"
    return 124
  fi
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  return "$rc"
}