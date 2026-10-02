# Steps, step selection and the progress stream of install-claude-gateway.sh (docs/adr/0047-lean-installer-phase-0.md),
# the contracts of scripts/ClaudeInstallSteps.ps1: --list-steps reads the install checkpoint only, --steps
# runs the named steps after each prerequisite is completed in the checkpoint and verified live (P91 R1),
# and --progress-file appends one JSON event per line, with the messages Install-ClaudeGateway.ps1 writes.
# Sourced by the installer after scripts/install-checkpoint.sh. Bash 3.2 and later, with jq.

PROGRESS_LAST=""; PROGRESS_CURRENT=""

# A step's prerequisites: the steps whose result it uses, as Install-ClaudeGateway.ps1 lists them.
steps_deps_() {
  case "$1" in
    gateway-deployment) printf 'resource-group' ;;
    sync) printf 'gateway-deployment entra-groups' ;;
    onboarding-package) printf 'gateway-deployment' ;;
  esac
}
steps_selected_() { [ -z "${STEPS:-}" ] && return 0; case " $STEPS " in *" $1 "*) return 0 ;; esac; return 1; }
steps_resume_line_() { if [ "$CKPT_PERSISTENT" = "1" ] && [ -z "$CKPT_NOSTORE" ]; then ckpt_resume_cmd_; else ckpt_resume_cmd_ with-answers; fi; }

# One event, one line of JSON (NDJSON), appended in one write. A JWT-shaped value in a message is
# replaced, so no token reaches the stream (ADR-0046 decision 15).
progress_event_() {
  [ -n "${PROGRESS_FILE:-}" ] || return 0
  local line
  line="$(jq -cn --arg t "$(ckpt_now_)" --arg r "$CKPT_RUN_ID" --arg s "$1" --arg e "$2" --arg m "$3" --arg c "${4:-}" '
    def clean: gsub("\\s*[\\r\\n]+\\s*"; " ") | gsub("eyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_.-]*"; "[redacted]") | sub("^\\s+"; "") | sub("\\s+$"; "");
    {schemaVersion: 1, time: $t, runId: $r, stepId: $s, event: $e, message: ($m | clean), resumeCommand: ($c | clean)}' | tr -d '\r')"
  printf '%s\n' "$line" >> "$PROGRESS_FILE"
}
# id event [reason]: '<title>: started', 'completed', 'verified live, skipped', 'incomplete' (a warning
# with the resume command) or 'failed: <reason>'. A step is started once, however often its state is written.
progress_step_() {
  local last text resume=""
  last="$(printf '%s\n' "$PROGRESS_LAST" | tr ' ' '\n' | sed -n "s/^$1=//p" | tail -n 1)"
  [ "$2" = "started" ] && [ "$last" = "started" ] && return 0
  PROGRESS_LAST="$PROGRESS_LAST $1=$2"
  if [ "$2" = "started" ]; then PROGRESS_CURRENT="$1"; elif [ "$PROGRESS_CURRENT" = "$1" ]; then PROGRESS_CURRENT=""; fi
  case "$2" in
    started) text="started" ;; completed) text="completed" ;; skipped-verified) text="verified live, skipped" ;;
    warning) text="incomplete"; resume="$(steps_resume_line_)" ;; *) text="failed: ${3:-}"; resume="$(steps_resume_line_)" ;;
  esac
  progress_event_ "$1" "$2" "$(ckpt_title_ "$1"): $text" "$resume"
}
# The event of a step's checkpoint state, written with or without a store; CKPT_QUIET=1 writes none.
progress_state_() {
  [ "${CKPT_QUIET:-0}" = "1" ] && return 0
  case "$2" in started) progress_step_ "$1" started ;; completed) progress_step_ "$1" completed ;; incomplete) progress_step_ "$1" warning ;; esac
}
# From the EXIT trap after a stop that is not a refusal: 'failed' for the running step.
progress_failed_() {
  local reason="install-claude-gateway.sh stopped with exit code $1"
  [ -n "${LAST_BAD:-}" ] && reason="$LAST_BAD"
  if [ -n "$PROGRESS_CURRENT" ]; then progress_step_ "$PROGRESS_CURRENT" failed "$reason"
  else progress_event_ "" failed "$reason" "$(steps_resume_line_)"; fi
}

# --steps: each id a step this installer runs, refused on one line before anything is read.
steps_select_() {
  local id
  [ -n "${STEPS:-}" ] || return 0
  STEPS="$(printf '%s' "$STEPS" | tr ',' ' ')"
  for id in $STEPS; do
    case " $CKPT_ORDER " in *" $id "*) ;; *) ckpt_refuse_ "--steps '$id' names no step of install-claude-gateway.sh. Its steps are $(printf '%s' "$CKPT_ORDER" | sed 's/ /, /g'). Nothing was changed." ;; esac
  done
}

# The tier groups the checkpoint records, read live by id and listed under the configured name by the
# name rule (ADR-0046 decision 11), as a resume reads them.
steps_verify_groups_() {
  local role name rec
  V_VERDICT=present; V_DETAIL=""
  for role in standard premium; do
    if [ "$role" = "standard" ]; then name="$STANDARD_GROUP"; else name="$PREMIUM_GROUP"; fi
    rec="$(printf '%s' "$(ckpt_receipt_ entra-groups)" | ckpt_jq_ -r --arg r "$role" --arg n "$name" '[(.groups // [])[] | select(.role == $r and .displayName == $n)][0].id // empty')"
    if [ -z "$rec" ]; then V_VERDICT=absent; V_DETAIL="the checkpoint records no $role group named '$name'"; return 0; fi
    ckpt_az_read_ "$CKPT_GRAPH_NOT_FOUND" ad group show --group "$rec" --query id -o tsv
    if [ "$AZ_VERDICT" != "present" ]; then V_VERDICT="$AZ_VERDICT"; V_DETAIL="Entra group '$name' ($rec) is not returned by Microsoft Graph ($AZ_DETAIL)"; return 0; fi
    ckpt_group_lookup_ "$name" "$rec"
    if [ "$G_VERDICT" != "present" ] || ! ckpt_same_ "$G_ID" "$rec"; then V_VERDICT=inconclusive; V_DETAIL="Entra group '$name' ($rec) is not listed by Microsoft Graph under that name"; return 0; fi
  done
}

# Before any question and any change: each prerequisite of a selected step is completed in the install
# checkpoint and verified live, or the run refuses on one line naming it (A11).
steps_prereqs_() {
  [ -n "${STEPS:-}" ] || return 0
  local s dep why state where="an install checkpoint"
  [ -n "$CKPT_JSON" ] && where="the install checkpoint $CKPT_FILE"
  for s in $STEPS; do
    why=""
    for dep in $(steps_deps_ "$s"); do
      steps_selected_ "$dep" && continue
      state="$(ckpt_step_field_ "$dep" state)"
      if [ -z "$state" ]; then why="${why:+$why; }$dep is not in $where"; continue; fi
      if [ "$state" != "completed" ]; then why="${why:+$why; }$dep is $state in $where"; continue; fi
      case "$dep" in
        resource-group) ckpt_verify_rg_ "$RESOURCE_GROUP" ;;
        gateway-deployment) ckpt_verify_gateway_ "$RESOURCE_GROUP" "$(ckpt_get_ .binding.apimName)" ;;
        entra-groups) steps_verify_groups_ ;;
        *) V_VERDICT=present ;;
      esac
      [ "$V_VERDICT" = "present" ] || why="${why:+$why; }$dep: $V_DETAIL"
    done
    [ -z "$why" ] || ckpt_refuse_ "step $s needs $(steps_deps_ "$s" | sed 's/ / and /g') completed and verified live: $why. Nothing was changed. Run the prerequisite first, or run without --steps to resume every step."
  done
}

# --list-steps: the steps and the state the install checkpoint records; no Azure call, nothing written.
steps_list_() {
  local id rows="" cp="" head
  ckpt_location_
  if [ -z "$CKPT_NOSTORE" ] && ckpt_store_check_ && ckpt_read_file_; then cp="$CKPT_FILE"; fi
  for id in $CKPT_ORDER; do
    rows="$rows$id$CKPT_US$(ckpt_title_ "$id")$CKPT_US$(steps_deps_ "$id")$CKPT_US$(ckpt_step_field_ "$id" state)
"
  done
  if [ "${WANT_JSON:-0}" = "1" ]; then
    printf '%s' "$rows" | ckpt_jq_ -R -s --arg cp "$cp" --arg run "$(ckpt_get_ .runId)" '
      {schemaVersion: 1, installer: "bash", checkpoint: (if $cp == "" then null else $cp end), runId: (if $run == "" then null else $run end),
       steps: [ split("\n")[] | select(length > 0) | split("\u001f") | {id: .[0], title: .[1], dependencies: (.[2] | split(" ") | map(select(length > 0))), state: (if .[3] == "" then "not-started" else .[3] end)} ]}'
    return 0
  fi
  if [ -n "$cp" ]; then head="Install checkpoint: $cp, run $(ckpt_get_ .runId)"; elif [ -n "$CKPT_NOSTORE" ]; then head="$CKPT_NOSTORE"; else head="No install checkpoint at $CKPT_FILE."; fi
  printf '%s\n' "$head"
  printf '%s' "$rows" | while IFS="$CKPT_US" read -r id title deps state; do
    [ -n "$id" ] && printf '%-20s %-24s %s\n' "$id" "$title" "${state:-not-started}"
  done
}

# Before the banner: --list-steps and --preflight print only their report and stop; --steps, the progress
# file and the answers file are checked, and the answers applied under this run's flags (ADR-0047).
steps_start_() {
  local rc
  CKPT_ROOT="$HERE"
  [ -n "$CKPT_RUN_ID" ] || CKPT_RUN_ID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n\r')"
  if [ "$LIST_STEPS" = "1" ]; then steps_list_; exit 0; fi
  if [ "$PREFLIGHT" = "1" ]; then preflight_run_; rc=$?; exit "$rc"; fi
  trap 'ckpt_exit_' EXIT
  steps_select_
  if [ -n "${PROGRESS_FILE:-}" ]; then ( : >> "$PROGRESS_FILE" ) 2>/dev/null || ckpt_refuse_ "--progress-file $PROGRESS_FILE cannot be written. Nothing was changed."; fi
  answers_apply_
}

. "$(dirname "${BASH_SOURCE[0]}")/install-answers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/install-preflight.sh"
