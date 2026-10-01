# Install checkpoint and resume for install-claude-gateway.sh (docs/adr/0046-installer-checkpoint-and-resume.md).
# Sourced by the installer after its output helpers. The checkpoint says where a rerun resumes; Azure
# says whether a step is done: a completed step is skipped only when a live read shows its result.
# Bash 3.2 (the macOS default) and later, with jq; no associative arrays and no GNU-only flags.

CKPT_SCHEMA="claude-gateway-install-checkpoint"
# Step ids are a stable contract shared with Install-ClaudeGateway.ps1: renaming or removing one needs
# a schemaVersion bump (ADR-0046). This installer runs five of them, in this order.
CKPT_STEP_IDS="claude-deployment resource-group gateway-deployment company-address entra-groups sync projection business-units onboarding-package verify"
CKPT_ORDER="resource-group gateway-deployment entra-groups sync onboarding-package"
# The files whose hash is the installer version a checkpoint records (shown, not refused: amendment 1).
CKPT_FILES="install-claude-gateway.sh scripts/install-checkpoint.sh"
# The answers recorded, by the PowerShell installer's parameter names: name, variable, flag, and i
# for a whole number.
CKPT_ANSWERS='SubscriptionId SUBSCRIPTION --subscription s
FoundryAccount FOUNDRY_ACCOUNT --foundry-account s
FoundryResourceGroup FOUNDRY_RG --foundry-rg s
ResourceGroup RESOURCE_GROUP --resource-group s
Location LOCATION --location s
NamePrefix NAME_PREFIX --name-prefix s
PublisherEmail PUBLISHER_EMAIL --publisher-email s
Sku SKU --sku s
TpmStandard TPM_STANDARD --tpm-standard i
QuotaStandard QUOTA_STANDARD --quota-standard i
TpmPremium TPM_PREMIUM --tpm-premium i
QuotaPremium QUOTA_PREMIUM --quota-premium i
CallsPerMinute CALLS_PER_MINUTE --calls-per-minute i
StandardGroup STANDARD_GROUP --standard-group s
PremiumGroup PREMIUM_GROUP --premium-group s'
CKPT_US=$'\x1f'

CKPT_ROOT=""; CKPT_DIR=""; CKPT_FILE=""; CKPT_LOCK=""; CKPT_PERSISTENT=1; CKPT_WARNING=""; CKPT_CLOUDSHELL=""
CKPT_RESUMING=0; CKPT_JSON=""; CKPT_RUN_ID=""; CKPT_LOCKED=0; CKPT_HEARTBEAT=""; CKPT_REFUSED=0; CKPT_WHAT_IF=0
CKPT_FINGERPRINT=""; CKPT_COMMIT=""; CKPT_TEMPLATES=""; CKPT_NOTED=0; CKPT_SUB_ID=""; CKPT_ANSWER_COUNT=0; CKPT_WRITE_WARNED=0
CKPT_GW_RUN=1; CKPT_GW_URL=""
AZ_VERDICT=""; AZ_OUT=""; AZ_ERR=""; AZ_DETAIL=""; V_VERDICT=""; V_DETAIL=""; LOCK_STATE=""; LOCK_DETAIL=""
DS_VERDICT=""; DS_STATE=""; DS_URL=""; DS_ERROR=""; DS_DETAIL=""

ckpt_title_() {
  case "$1" in
    claude-deployment) printf 'Claude deployment' ;; resource-group) printf 'Resource group' ;;
    gateway-deployment) printf 'Gateway deployment' ;; company-address) printf 'Company address' ;;
    entra-groups) printf 'Entra groups' ;; sync) printf 'Sync entitlement' ;; projection) printf 'Projection deployment' ;;
    business-units) printf 'Business units' ;; onboarding-package) printf 'Onboarding package' ;; verify) printf 'Verification' ;;
    *) printf '%s' "$1" ;;
  esac
}

ckpt_sha256_() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else openssl dgst -sha256 | sed 's/^.*= *//'; fi
}
ckpt_now_() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
ckpt_lower_() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
ckpt_same_() { [ "$(ckpt_lower_ "$1")" = "$(ckpt_lower_ "$2")" ]; }
ckpt_is_guid_() { printf '%s' "$1" | grep -qE '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'; }
ckpt_quote_() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
ckpt_jq_() { jq "$@" | tr -d '\r'; }
ckpt_passed_() { case " ${CKPT_SEEN:-} " in *" $1 "*) return 0 ;; esac; return 1; }
ckpt_terminal_() { case "$1" in Succeeded|Failed|Canceled) return 0 ;; esac; return 1; }
ckpt_setting_() {
  local v; eval "v=\${$1:-}"
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}
ckpt_host_() { uname -n 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -d. -f1 | tr -d '\r'; }
# Windows reuses process ids under churn, so a lock names its holder by id and start time (U72).
ckpt_process_start_() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//' | tr -d '\r'; }

# A refusal is one line on standard error, and changes nothing.
ckpt_refuse_() {
  CKPT_REFUSED=1
  printf 'Refused: %s\n' "$(printf '%s' "$1" | tr '\r\n' '  ')" >&2
  exit 1
}

# The command that resumes this run; with-answers adds every recorded answer, for a checkpoint that
# does not persist (ADR-0046 decision 14).
ckpt_resume_cmd_() {
  local line name var flag kind value
  line="cd $(ckpt_quote_ "$CKPT_ROOT") && ./install-claude-gateway.sh"
  if [ "${1:-}" = "with-answers" ]; then
    while read -r name var flag kind; do
      [ -n "$name" ] || continue
      eval "value=\${$var:-}"
      [ -n "$value" ] || continue
      if [ "$kind" = "i" ]; then line="$line $flag $value"; else line="$line $flag $(ckpt_quote_ "$value")"; fi
    done <<EOF
$CKPT_ANSWERS
EOF
  fi
  printf '%s' "$line"
}

# Cloud Shell sets AZUREPS_HOST_ENVIRONMENT; the Azure CLI reads ACC_CLOUD (U64).
ckpt_cloudshell_() {
  case "${AZUREPS_HOST_ENVIRONMENT:-}" in cloud-shell/*) printf 'AZUREPS_HOST_ENVIRONMENT'; return 0 ;; esac
  if [ -n "${ACC_CLOUD:-}" ]; then printf 'ACC_CLOUD'; fi
}
ckpt_writable_() {
  [ -d "$1" ] || return 1
  local probe="$1/.claude-gateway-probe-$$"
  ( : > "$probe" ) 2>/dev/null || return 1
  rm -f "$probe"
}
ckpt_location_() {
  local key drive
  key="install-$(printf '%s' "$CKPT_ROOT" | ckpt_sha256_ | cut -c1-16)"
  CKPT_CLOUDSHELL="$(ckpt_cloudshell_)"
  if [ -n "${CLAUDE_GATEWAY_STATE_DIR:-}" ]; then CKPT_DIR="$CLAUDE_GATEWAY_STATE_DIR"
  elif [ -n "$CKPT_CLOUDSHELL" ]; then
    drive="$HOME/clouddrive"
    if ckpt_writable_ "$drive"; then CKPT_DIR="$drive/.claude-gateway"
    else
      CKPT_DIR="$HOME/.claude-gateway"; CKPT_PERSISTENT=0
      CKPT_WARNING="Cloud Shell without clouddrive ($CKPT_CLOUDSHELL is set and $drive is not a writable directory): the install checkpoint is kept in $CKPT_DIR, which does not persist when the session ends."
    fi
  else CKPT_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-gateway"; fi
  CKPT_FILE="$CKPT_DIR/$key.json"; CKPT_LOCK="$CKPT_DIR/$key.lock"
}

# Each file hashed with carriage returns removed, so a Windows and a Linux checkout of one commit agree.
ckpt_file_hash_() {
  local p h lines=""
  for p in "$@"; do
    if [ -f "$CKPT_ROOT/$p" ]; then h="$(tr -d '\r' < "$CKPT_ROOT/$p" | ckpt_sha256_)"; else h="$(printf '<missing>' | ckpt_sha256_)"; fi
    lines="$lines$p	$h
"
  done
  printf 'sha256:%s' "$(printf '%s' "$lines" | LC_ALL=C sort | awk 'NR > 1 { printf "\n" } { printf "%s", $0 }' | ckpt_sha256_)"
}
ckpt_normalize_() {
  printf '%s\n' "$1" | awk -F/ '{ n = 0; for (i = 1; i <= NF; i++) { if ($i == "" || $i == ".") continue; if ($i == "..") { if (n > 0) n--; continue }; s[++n] = $i }
    out = ""; for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") s[i]; print out }'
}
# A template and every file it references through module declarations and load*() calls, so a
# changed module or policy changes the deployment step's input (ADR-0046 amendment 1).
ckpt_template_files_() {
  local queue="$1" found="" rel dir refs ref
  while [ -n "$queue" ]; do
    rel="$(printf '%s\n' "$queue" | head -n 1)"
    queue="$(printf '%s\n' "$queue" | sed '1d')"
    [ -n "$rel" ] || continue
    if printf '%s' "$found" | grep -qxF -- "$rel"; then continue; fi
    found="$found$rel
"
    case "$rel" in *.bicep) ;; *) continue ;; esac
    [ -f "$CKPT_ROOT/$rel" ] || continue
    dir="$(dirname "$rel")"
    refs="$(tr -d '\r' < "$CKPT_ROOT/$rel" | grep -oE "^[[:space:]]*module[[:space:]]+[^[:space:]]+[[:space:]]+'[^']+'|load(Text|Json)Content\([[:space:]]*'[^']+'|loadFileAsBase64\([[:space:]]*'[^']+'" | sed -E "s/.*'([^']+)'$/\1/")"
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      case "$ref" in *:*) continue ;; esac
      queue="$queue
$(ckpt_normalize_ "$dir/$ref")"
    done <<EOF
$refs
EOF
  done
  printf '%s' "$found"
}

# present, absent (an error code on the not-found list, separated by |) or inconclusive (any other
# failure). A failed or inconclusive read never skips a step (R1).
ckpt_az_read_() {
  local notfound="$1" errf code saved pattern
  shift
  errf="$CKPT_DIR/.az-stderr-$$"
  { [ -d "$CKPT_DIR" ] && [ -w "$CKPT_DIR" ]; } || errf="$HOME/.claude-gateway-az-stderr-$$"
  AZ_OUT="$(az "$@" 2>"$errf" < /dev/null | tr -d '\r')"; code=$?
  AZ_ERR="$(tr '\r\n' '  ' < "$errf" 2>/dev/null)"; rm -f "$errf"
  AZ_VERDICT=inconclusive
  if [ "$code" -eq 0 ]; then AZ_VERDICT=present
  elif [ -n "$notfound" ]; then
    saved="$IFS"; IFS='|'
    for pattern in $notfound; do case "$AZ_ERR" in *"$pattern"*) AZ_VERDICT=absent ;; esac; done
    IFS="$saved"
  fi
  if [ -n "$AZ_ERR" ]; then AZ_DETAIL="$(printf '%s' "$AZ_ERR" | sed 's/^ *//;s/\. .*$/./')"; else AZ_DETAIL="az exited $code"; fi
}
CKPT_GRAPH_NOT_FOUND='Request_ResourceNotFound|does not exist or one of its queried reference-property objects are not present'

# The checkpoint's validity: the reason it cannot be resumed, PWSH for the other installer's, or nothing.
CKPT_VALIDATE='
def guid: type == "string" and test("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$");
def kinds: {SubscriptionId: "s", FoundryAccount: "s", FoundryResourceGroup: "s", ResourceGroup: "s", Location: "s", NamePrefix: "s",
  PublisherEmail: "s", Sku: "s", TpmStandard: "i", QuotaStandard: "i", TpmPremium: "i", QuotaPremium: "i", CallsPerMinute: "i",
  StandardGroup: "s", PremiumGroup: "s"};
def problem($n; $v):
  if kinds[$n] == null then "is not an answer the installer records"
  elif kinds[$n] == "i" then (if ($v | type) == "number" and $v >= 0 and $v == ($v | floor) then empty else "is not a whole number" end)
  elif ($v | type) != "string" then "is not text"
  elif ($v | explode | map(select(. < 32)) | length) > 0 then "holds a control character"
  elif ($v | startswith("@")) then "begins with @, which az reads as a file name"
  elif $n == "Sku" and (["BasicV2", "StandardV2", "PremiumV2"] | index([$v])) == null then "is not one of BasicV2, StandardV2, PremiumV2"
  elif $n == "SubscriptionId" and ($v | guid | not) then "is not a subscription id"
  else empty end;
if type != "object" then "is not valid JSON (no object)"
elif .schema != "claude-gateway-install-checkpoint" then "has schema \u0027\(.schema)\u0027, not claude-gateway-install-checkpoint"
elif (.schemaVersion | tostring) != "1" then "has schemaVersion \(.schemaVersion), and this installer reads schemaVersion 1"
elif ((.runId | type) != "string") or (.runId | test("^[0-9a-f]{32}$") | not) then "has no valid runId"
elif .installer != "pwsh" and .installer != "bash" then "names the installer \u0027\(.installer)\u0027"
elif .installer == "pwsh" then "PWSH"
elif (.binding | type) != "object" or (.binding.tenantId | guid | not) or (.binding.subscriptionId | guid | not)
  or ((.binding.resourceGroup // "") == "") or ((.binding.apimName // "") == "") then "has an incomplete binding"
elif (.answers | type) != "object" then "has no answers"
else
  ([.answers | to_entries[] | problem(.key; .value) as $p | "holds the answer \(.key), which \($p)"] | first)
  // ([(.steps // [])[] | select(. != null) | .id as $id | .state as $s
        | if (($ids | split(" ")) | index([$id])) == null then "holds an unknown step id \u0027\($id)\u0027"
          elif $s != "started" and $s != "completed" and $s != "incomplete" then "holds the step \($id) in state \u0027\($s)\u0027"
          else empty end] | first)
  // empty
end'

ckpt_get_() { printf '%s' "$CKPT_JSON" | ckpt_jq_ -r "$1 // empty"; }
ckpt_step_field_() { printf '%s' "$CKPT_JSON" | ckpt_jq_ -r --arg id "$1" --arg f "$2" '([.steps[]? | select(.id == $id)][0][$f]) // empty'; }
ckpt_receipt_() { printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --arg id "$1" '([.steps[]? | select(.id == $id)][0].receipt) // empty'; }
ckpt_receipt_field_() { printf '%s' "$CKPT_JSON" | ckpt_jq_ -r --arg id "$1" --arg f "$2" '([.steps[]? | select(.id == $id)][0].receipt[$f]) // empty'; }
ckpt_resume_title_() {
  local open last id next=""
  open="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '[.steps[]? | select(.state != "completed") | .id][0] // empty')"
  if [ -n "$open" ]; then ckpt_title_ "$open"; return 0; fi
  last="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '[.steps[]? | .id] | last // empty')"
  next="resource-group"
  if [ -n "$last" ]; then
    next="$last"
    for id in $CKPT_ORDER; do if [ "$id" = "$last" ]; then next=""; elif [ -z "$next" ]; then next="$id"; fi; done
    [ -n "$next" ] || next="$last"
  fi
  ckpt_title_ "$next"
}
ckpt_binding_refuse_() {
  ckpt_refuse_ "the install checkpoint $CKPT_FILE is bound to $1 '$2', and this run names '$3'. Nothing was changed. To discard the checkpoint and start again: $(ckpt_resume_cmd_) --restart"
}

# At startup, before any question: reads the checkpoint, refuses what it cannot resume, prints where
# the run resumes and sets each recorded answer that this run's flags do not name (decisions 5, 6).
ckpt_open_() {
  local restart="$2" aside reason fields b_tenant b_sub b_rg b_apim b_prefix created was was_commit now name value line var flag
  CKPT_ROOT="$1"; CKPT_WHAT_IF="$3"
  ckpt_location_
  trap 'ckpt_exit_' EXIT
  if [ "$CKPT_WHAT_IF" = "1" ]; then
    if [ -f "$CKPT_FILE" ]; then note_ "An install checkpoint exists at $CKPT_FILE; --what-if previews a first run and changes nothing."; fi
    return 0
  fi
  ckpt_lock_state_ "$CKPT_LOCK"
  [ "$LOCK_STATE" = "held" ] && ckpt_refuse_ "another install run holds the lock $CKPT_LOCK ($LOCK_DETAIL). Nothing was changed."
  if [ "$restart" = "1" ] && [ -f "$CKPT_FILE" ]; then
    aside="${CKPT_FILE%.json}.discarded-$(date -u '+%Y%m%dT%H%M%SZ').json"
    mv -f "$CKPT_FILE" "$aside"
    printf '    %s--restart: the install checkpoint is set aside as %s.%s\n' "$C_YELLOW" "$aside" "$C_OFF"
    return 0
  fi
  [ -f "$CKPT_FILE" ] || return 0
  if ! CKPT_JSON="$(ckpt_jq_ -cs 'if length == 1 then .[0] else error("more than one value") end' "$CKPT_FILE" 2>/dev/null)" || [ -z "$CKPT_JSON" ]; then
    CKPT_JSON=""
    ckpt_refuse_ "the install checkpoint $CKPT_FILE is not valid JSON. Nothing was changed. To discard it and start again: $(ckpt_resume_cmd_) --restart"
  fi
  reason="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r --arg ids "$CKPT_STEP_IDS" "$CKPT_VALIDATE" 2>/dev/null)" || reason="could not be read"
  if [ "$reason" = "PWSH" ]; then
    CKPT_JSON=""
    ckpt_refuse_ "the install checkpoint $CKPT_FILE was written by Install-ClaudeGateway.ps1, whose steps differ; resume it with that installer. Nothing was changed. To discard it and start again: $(ckpt_resume_cmd_) --restart"
  fi
  if [ -n "$reason" ]; then CKPT_JSON=""; ckpt_refuse_ "the install checkpoint $CKPT_FILE $reason. Nothing was changed. To discard it and start again: $(ckpt_resume_cmd_) --restart"; fi
  fields="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '[.binding.tenantId, .binding.subscriptionId, .binding.resourceGroup, .binding.apimName, (.binding.namePrefix // ""), .runId, (.createdUtc // ""), (.installerFingerprint // ""), (.installerCommit // "")] | join("\u001f")')"
  IFS="$CKPT_US" read -r b_tenant b_sub b_rg b_apim b_prefix CKPT_RUN_ID created was was_commit <<EOF
$fields
EOF
  # A subscription named by name is compared after az account set, by its id.
  if ckpt_passed_ --subscription && ckpt_is_guid_ "$SUBSCRIPTION" && ! ckpt_same_ "$SUBSCRIPTION" "$b_sub"; then ckpt_binding_refuse_ subscription "$b_sub" "$SUBSCRIPTION"; fi
  if ckpt_passed_ --resource-group && ! ckpt_same_ "$RESOURCE_GROUP" "$b_rg"; then ckpt_binding_refuse_ "resource group" "$b_rg" "$RESOURCE_GROUP"; fi
  if ckpt_passed_ --name-prefix && [ "$NAME_PREFIX" != "$b_prefix" ] && [ "apim-$NAME_PREFIX" != "$b_apim" ]; then ckpt_binding_refuse_ gateway "$b_apim" "apim-$NAME_PREFIX"; fi
  CKPT_RESUMING=1
  while IFS="$CKPT_US" read -r name value; do
    [ -n "$name" ] || continue
    CKPT_ANSWER_COUNT=$((CKPT_ANSWER_COUNT + 1))
    line="$(printf '%s\n' "$CKPT_ANSWERS" | awk -v n="$name" '$1 == n')"
    var="$(printf '%s' "$line" | cut -d' ' -f2)"; flag="$(printf '%s' "$line" | cut -d' ' -f3)"
    [ -n "$var" ] || continue
    ckpt_passed_ "$flag" && continue
    printf -v "$var" '%s' "$value"
  done <<EOF
$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '.answers | to_entries[] | "\(.key)\u001f\(.value)"')
EOF
  echo
  printf '%sInstall checkpoint: %s%s\n' "$C_CYAN" "$CKPT_FILE" "$C_OFF"
  printf '%sResuming install run %s, started %s by install-claude-gateway.sh.%s\n' "$C_CYAN" "$CKPT_RUN_ID" "$created" "$C_OFF"
  printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '.steps[]? | select(.state == "completed") | "\(.completedUtc)\u001f\(.id)"' | while IFS="$CKPT_US" read -r now name; do
    [ -n "$name" ] && printf '  done %s  %s\n' "$now" "$(ckpt_title_ "$name")"
  done
  printf '%s  resumes at: %s%s\n' "$C_CYAN" "$(ckpt_resume_title_)" "$C_OFF"
  ckpt_version_info_
  if [ "$was" != "$CKPT_FINGERPRINT" ] || { [ -n "$was_commit" ] && [ -n "$CKPT_COMMIT" ] && [ "$was_commit" != "$CKPT_COMMIT" ]; }; then
    printf '  %scheckpoint written by install-claude-gateway.sh %s; running install-claude-gateway.sh %s%s\n' "$C_YELLOW" \
      "$(ckpt_version_ "$was_commit" "$was")" "$(ckpt_version_ "$CKPT_COMMIT" "$CKPT_FINGERPRINT")" "$C_OFF"
  fi
}
# One token: the commit and the files' hash, or the hash alone outside a git checkout.
ckpt_version_() {
  local f="${2#sha256:}"
  if [ -n "$1" ]; then printf '%s+%s' "$(printf '%s' "$1" | cut -c1-12)" "$(printf '%s' "$f" | cut -c1-8)"; else printf 'sha256:%s' "$(printf '%s' "$f" | cut -c1-12)"; fi
}
# The installer's commit and the hash of its files, read once, on a resume or at the commit point.
ckpt_version_info_() {
  [ -z "$CKPT_FINGERPRINT" ] || return 0
  CKPT_FINGERPRINT="$(ckpt_file_hash_ $CKPT_FILES)"
  if command -v git >/dev/null 2>&1; then CKPT_COMMIT="$(git -C "$CKPT_ROOT" rev-parse HEAD 2>/dev/null | tr -d '\r')"; fi
}

ckpt_subscription_id_() {
  if [ -z "$CKPT_SUB_ID" ]; then CKPT_SUB_ID="$(az account show --query id -o tsv 2>/dev/null < /dev/null | tr -d '\r')"; fi
  printf '%s' "$CKPT_SUB_ID"
}
ckpt_assert_tenant_() {
  [ "$CKPT_RESUMING" = "1" ] || return 0
  local b; b="$(ckpt_get_ .binding.tenantId)"
  ckpt_same_ "$1" "$b" || ckpt_binding_refuse_ tenant "$b" "$1"
}
ckpt_assert_subscription_() {
  [ "$CKPT_RESUMING" = "1" ] || return 0
  local b current
  b="$(ckpt_get_ .binding.subscriptionId)"; current="$(ckpt_subscription_id_)"
  [ -n "$current" ] || ckpt_refuse_ "the current subscription could not be read with az account show, so the install checkpoint $CKPT_FILE cannot be matched to it. Nothing was changed."
  ckpt_same_ "$current" "$b" || ckpt_binding_refuse_ subscription "$b" "$current"
}
ckpt_summary_row_() { printf '%s, run %s, %s recorded answers reused, resumes at %s' "$CKPT_FILE" "$CKPT_RUN_ID" "$CKPT_ANSWER_COUNT" "$(ckpt_resume_title_)"; }

# This run's answers, read from the installer's variables after its summary is confirmed. No secret
# is among them (decision 15).
ckpt_answers_json_() {
  local name var flag kind value
  while read -r name var flag kind; do
    [ -n "$name" ] || continue
    if [ "$name" = "SubscriptionId" ] && [ -n "$1" ]; then value="$1"; else eval "value=\${$var:-}"; fi
    [ -n "$value" ] && printf '%s\t%s\t%s\n' "$name" "$kind" "$value"
  done <<EOF | ckpt_jq_ -cR -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (if .[1] == "i" then (.[2] as $v | $v | tonumber? // $v) else .[2] end)}) | add // {}'
$CKPT_ANSWERS
EOF
}

# The commit point: after the summary is confirmed, before the first change (ADR-0032). The lock is
# taken here, so a run still asking its questions holds nothing.
ckpt_save_() {
  [ "$CKPT_WHAT_IF" = "1" ] && return 0
  local sub answers now changed name
  ckpt_version_info_
  sub="$(ckpt_subscription_id_)"; [ -n "$sub" ] || sub="$SUBSCRIPTION"
  answers="$(ckpt_answers_json_ "$sub")"
  now="$(ckpt_now_)"
  if ! mkdir -p "$CKPT_DIR" 2>/dev/null; then warn_ "the install checkpoint directory $CKPT_DIR could not be created; this run keeps no checkpoint"; return 0; fi
  chmod 700 "$CKPT_DIR" 2>/dev/null
  if [ "$CKPT_RESUMING" = "1" ]; then
    changed="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r --argjson a "$answers" '.answers as $o | $a | to_entries[] | select($o[.key] != .value) | .key')"
    for name in $changed; do printf '    %sChanged since the checkpoint: %s%s\n' "$C_YELLOW" "$name" "$C_OFF"; done
    CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --argjson a "$answers" --arg f "$CKPT_FINGERPRINT" --arg c "$CKPT_COMMIT" '.answers = $a | .installerFingerprint = $f | .installerCommit = $c')"
  else
    CKPT_RUN_ID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n\r')"
    CKPT_JSON="$(ckpt_jq_ -cn --arg s "$CKPT_SCHEMA" --arg r "$CKPT_RUN_ID" --arg f "$CKPT_FINGERPRINT" --arg c "$CKPT_COMMIT" --arg k "$CKPT_ROOT" --arg now "$now" \
      --arg t "$TENANT_ID" --arg sub "$sub" --arg rg "$RESOURCE_GROUP" --arg apim "$APIM_NAME" --arg p "$NAME_PREFIX" --argjson a "$answers" \
      '{schema: $s, schemaVersion: 1, runId: $r, installer: "bash", installerFingerprint: $f, installerCommit: $c, checkout: $k, createdUtc: $now, updatedUtc: $now,
        binding: {tenantId: $t, subscriptionId: $sub, resourceGroup: $rg, apimName: $apim, namePrefix: $p, reusedApim: false}, answers: $a, steps: []}')"
  fi
  ckpt_lock_
  ckpt_write_
  if [ "$CKPT_PERSISTENT" != "1" ]; then
    warn_ "$CKPT_WARNING"
    printf '    Resume: %s\n' "$(ckpt_resume_cmd_ with-answers)"
  fi
}

# A temporary file renamed over the checkpoint, so an interrupted write leaves the previous one.
ckpt_write_() {
  [ "$CKPT_LOCKED" = "1" ] && [ -n "$CKPT_JSON" ] || return 0
  local tmp="$CKPT_FILE.tmp-$$-$RANDOM"
  CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --arg now "$(ckpt_now_)" '.updatedUtc = $now')"
  if ( umask 077; printf '%s' "$CKPT_JSON" | jq . | tr -d '\r' > "$tmp" ) 2>/dev/null && chmod 600 "$tmp" 2>/dev/null && mv -f "$tmp" "$CKPT_FILE" 2>/dev/null; then return 0; fi
  rm -f "$tmp"
  if [ "$CKPT_WRITE_WARNED" != "1" ]; then CKPT_WRITE_WARNED=1; warn_ "the install checkpoint could not be written to $CKPT_FILE"; fi
}

# free, held or stale, and who holds it (ADR-0046 decision 3).
ckpt_lock_state_() {
  local path="$1" fields pid host start recent=1 current
  LOCK_STATE=free; LOCK_DETAIL=""
  [ -f "$path" ] || return 0
  [ -n "$(find "$path" -mmin +5 2>/dev/null)" ] && recent=0
  fields="$(ckpt_jq_ -r '[(.pid // "" | tostring), (.host // ""), (.processStart // "")] | join("\u001f")' "$path" 2>/dev/null)"
  IFS="$CKPT_US" read -r pid host start <<EOF
$fields
EOF
  if [ -z "$pid" ] || [ -z "$host" ]; then
    if [ "$recent" = "1" ]; then LOCK_STATE=held; else LOCK_STATE=stale; fi
    LOCK_DETAIL="an unreadable lock"; return 0
  fi
  LOCK_DETAIL="host $host, process $pid started $start"
  if [ "$host" != "$(ckpt_host_)" ]; then
    if [ "$recent" = "1" ]; then LOCK_STATE=held; LOCK_DETAIL="$LOCK_DETAIL, last heartbeat under 5 minutes ago"
    else LOCK_STATE=stale; LOCK_DETAIL="$LOCK_DETAIL, no heartbeat for 5 minutes"; fi
    return 0
  fi
  current="$(ckpt_process_start_ "$pid")"
  if [ -z "$current" ] && ! kill -0 "$pid" 2>/dev/null; then LOCK_STATE=stale; LOCK_DETAIL="$LOCK_DETAIL, which has exited"; return 0; fi
  if [ -n "$current" ] && [ -n "$start" ] && [ "$current" != "$start" ]; then LOCK_STATE=stale; LOCK_DETAIL="$LOCK_DETAIL; that id now names a process started $current"; return 0; fi
  LOCK_STATE=held
}
ckpt_lock_() {
  local attempt=0 fields
  fields="$(ckpt_jq_ -cn --argjson pid "$$" --arg ps "$(ckpt_process_start_ "$$")" --arg h "$(ckpt_host_)" --arg r "$CKPT_RUN_ID" --arg now "$(ckpt_now_)" \
    '{pid: $pid, processStart: $ps, host: $h, installer: "bash", runId: $r, acquiredUtc: $now}')"
  while [ "$attempt" -lt 3 ]; do
    if ( set -C; umask 077; printf '%s' "$fields" > "$CKPT_LOCK" ) 2>/dev/null; then
      CKPT_LOCKED=1
      # The heartbeat lets another host tell a live run from a closed Cloud Shell session.
      ( while sleep 60; do [ -f "$CKPT_LOCK" ] || exit 0; touch "$CKPT_LOCK" 2>/dev/null || exit 0; done ) >/dev/null 2>&1 &
      CKPT_HEARTBEAT=$!
      return 0
    fi
    [ -f "$CKPT_LOCK" ] || ckpt_refuse_ "the lock $CKPT_LOCK could not be created. Nothing was changed."
    ckpt_lock_state_ "$CKPT_LOCK"
    [ "$LOCK_STATE" = "held" ] && ckpt_refuse_ "another install run holds the lock $CKPT_LOCK ($LOCK_DETAIL). Nothing was changed."
    printf '    %sTaking over a stale lock: %s.%s\n' "$C_YELLOW" "$LOCK_DETAIL" "$C_OFF"
    mv -f "$CKPT_LOCK" "$CKPT_LOCK.stale-$CKPT_RUN_ID-$attempt" 2>/dev/null
    attempt=$((attempt + 1))
  done
  ckpt_refuse_ "the lock $CKPT_LOCK could not be taken. Nothing was changed."
}
ckpt_release_() {
  if [ -n "$CKPT_HEARTBEAT" ]; then kill "$CKPT_HEARTBEAT" 2>/dev/null; CKPT_HEARTBEAT=""; fi
  if [ "$CKPT_LOCKED" = "1" ]; then
    case "$(cat "$CKPT_LOCK" 2>/dev/null)" in *"\"$CKPT_RUN_ID\""*) rm -f "$CKPT_LOCK" ;; esac
    CKPT_LOCKED=0
  fi
}
# On exit: the lock is released, and after a failure that is not a refusal the resume command is printed.
ckpt_exit_() {
  local code=$? held="$CKPT_LOCKED"
  ckpt_release_
  if [ "$held" = "1" ] && [ "$code" != "0" ] && [ "$CKPT_REFUSED" != "1" ] && [ -f "$CKPT_FILE" ]; then
    if [ "$CKPT_PERSISTENT" = "1" ]; then printf 'Resume: %s\n' "$(ckpt_resume_cmd_)"; else printf 'Resume: %s\n' "$(ckpt_resume_cmd_ with-answers)"; fi
  fi
}

# The answers a step uses, and for the deployment step its templates (ADR-0046 amendment 1).
ckpt_input_hash_() {
  local pick='{}'
  case "$1" in
    resource-group) pick='{ResourceGroup, Location}' ;;
    entra-groups) pick='{StandardGroup, PremiumGroup}' ;;
    gateway-deployment)
      pick='del(.StandardGroup, .PremiumGroup) + {templates: $t}'
      [ -n "$CKPT_TEMPLATES" ] || CKPT_TEMPLATES="$(ckpt_file_hash_ $(ckpt_template_files_ infra/main.bicep))" ;;
  esac
  printf 'sha256:%s' "$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -cS --arg t "$CKPT_TEMPLATES" "(.answers // {}) | $pick" | ckpt_sha256_)"
}
# id state [inputHash] [receipt JSON]; __keep__ keeps the recorded value.
ckpt_set_step_() {
  [ "$CKPT_LOCKED" = "1" ] || return 0
  CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --arg id "$1" --arg st "$2" --arg h "${3:-__keep__}" --arg r "${4:-__keep__}" --arg now "$(ckpt_now_)" '
    (if any(.steps[]?; .id == $id) then . else .steps = ((.steps // []) + [{id: $id, state: "new", startedUtc: $now, completedUtc: null, inputHash: "", receipt: null}]) end)
    | .steps |= map(if .id == $id then
        (if $st == "started" then (if .state != "started" then .startedUtc = $now else . end) | .completedUtc = null else .completedUtc = $now end)
        | .state = $st
        | (if $h != "__keep__" then .inputHash = $h else . end)
        | (if $r != "__keep__" then .receipt = ($r | fromjson) else . end)
      else . end)')"
  ckpt_write_
}

# 0 when the step completed with this input and a live read shows its result (R1); otherwise the
# step is marked started and runs. An unreadable result refuses unless the step is idempotent.
ckpt_skip_() {
  local id="$1" idempotent="$2" verify="$3" title hash state stored
  shift 3
  title="$(ckpt_title_ "$id")"; hash="$(ckpt_input_hash_ "$id")"
  state="$(ckpt_step_field_ "$id" state)"; stored="$(ckpt_step_field_ "$id" inputHash)"
  if [ "$state" = "completed" ] && [ "$stored" = "$hash" ]; then
    "$verify" "$@"
    if [ "$V_VERDICT" = "present" ]; then printf '    %s[OK]%s   %s: verified live, skipped\n' "$C_GREEN" "$C_OFF" "$title"; return 0; fi
    if [ "$V_VERDICT" = "inconclusive" ] && [ "$idempotent" != "1" ]; then ckpt_refuse_ "$title could not be verified ($V_DETAIL). Nothing was changed. Resume: $(ckpt_resume_cmd_)"; fi
    printf '    %s%s: %s; running it again%s\n' "$C_YELLOW" "$title" "$V_DETAIL" "$C_OFF"
  elif [ "$state" = "completed" ]; then printf '    %s%s: its input changed since the checkpoint; running it again%s\n' "$C_YELLOW" "$title" "$C_OFF"
  fi
  ckpt_set_step_ "$id" started "$hash"
  return 1
}
ckpt_verify_rg_() {
  ckpt_az_read_ 'ResourceGroupNotFound' group show -n "$1" --query location -o tsv
  V_VERDICT="$AZ_VERDICT"
  if [ "$AZ_VERDICT" = "absent" ]; then V_DETAIL="resource group $1 is gone"; else V_DETAIL="resource group $1 could not be read ($AZ_DETAIL)"; fi
}

# Before any wait that can outlast Cloud Shell's 20-minute idle limit (FAQ; ADR-0046 decision 10).
ckpt_cloudshell_line_() {
  [ -n "$CKPT_CLOUDSHELL" ] && [ "$CKPT_NOTED" != "1" ] || return 0
  CKPT_NOTED=1
  if [ "$CKPT_PERSISTENT" = "1" ]; then
    printf '    %sCloud Shell ends a session after 20 minutes without interactive activity; the install checkpoint and the ARM deployment outlive the session. Resume: %s%s\n' "$C_YELLOW" "$(ckpt_resume_cmd_)" "$C_OFF"
  else
    printf '    %sCloud Shell ends a session after 20 minutes without interactive activity; the ARM deployment outlives the session and this install checkpoint does not. Resume: %s%s\n' "$C_YELLOW" "$(ckpt_resume_cmd_ with-answers)" "$C_OFF"
  fi
}

ckpt_deployment_state_() {
  local fields
  DS_STATE=""; DS_URL=""; DS_ERROR=""
  ckpt_az_read_ 'DeploymentNotFound' deployment group show -g "$1" -n "$2" -o json
  DS_VERDICT="$AZ_VERDICT"; DS_DETAIL="$AZ_DETAIL"
  [ "$AZ_VERDICT" = "present" ] || return 0
  if ! fields="$(printf '%s' "$AZ_OUT" | ckpt_jq_ -r '[(.properties.provisioningState // ""), (.properties.outputs.gatewayUrl.value // ""),
      (if .properties.error then "\(.properties.error.code // ""): \(.properties.error.message // "")" else "" end)] | join("\u001f")' 2>/dev/null)"; then
    DS_VERDICT=inconclusive; DS_DETAIL="the deployment record is not JSON"; return 0
  fi
  IFS="$CKPT_US" read -r DS_STATE DS_URL DS_ERROR <<EOF
$fields
EOF
  [ "$DS_STATE" = "Deleted" ] && DS_VERDICT=absent
  return 0
}
# A bounded wait on a deployment ARM is still running; az deployment group wait is not used (U68).
ckpt_wait_deployment_() {
  local poll bound start last=""
  poll="$(ckpt_setting_ CLAUDE_GATEWAY_DEPLOY_POLL_SECONDS 30)"; bound="$(ckpt_setting_ CLAUDE_GATEWAY_DEPLOY_WAIT_SECONDS 3600)"
  [ "$bound" -gt 60 ] && ckpt_cloudshell_line_
  start=$SECONDS
  while :; do
    ckpt_deployment_state_ "$1" "$2"
    if [ "$DS_VERDICT" != "present" ] || ckpt_terminal_ "$DS_STATE"; then return 0; fi
    if [ "$DS_STATE" != "$last" ]; then printf '    %sDeployment %s is %s after %s s; waiting up to %s s.%s\n' "$C_GREY" "$2" "$DS_STATE" "$((SECONDS - start))" "$bound" "$C_OFF"; last="$DS_STATE"; fi
    if [ "$((SECONDS - start))" -ge "$bound" ]; then
      ckpt_refuse_ "deployment $2 in resource group $1 is still running after $bound s, and Azure Resource Manager continues it without this session. Nothing was changed. Resume: $(ckpt_resume_cmd_)"
    fi
    [ "$poll" -gt 0 ] && sleep "$poll"
  done
}
# Never two main.bicep deployments at once: claude-gw- (both installers), claude-gateway- (deploy.ps1).
ckpt_wait_main_deployments_() {
  local names name
  ckpt_az_read_ 'ResourceGroupNotFound' deployment group list -g "$1" -o json
  [ "$AZ_VERDICT" = "absent" ] && return 0
  [ "$AZ_VERDICT" = "present" ] || ckpt_refuse_ "the deployments of resource group $1 could not be listed ($AZ_DETAIL), so another main.bicep deployment cannot be ruled out. Nothing was changed. Resume: $(ckpt_resume_cmd_)"
  names="$(printf '%s' "$AZ_OUT" | ckpt_jq_ -r '.[]? | select((.name // "" | test("^(claude-gw-|claude-gateway-)")) and ((.properties.provisioningState // "") as $s | ["Succeeded", "Failed", "Canceled", "Deleted"] | index([$s]) | not)) | .name')"
  for name in $names; do
    printf '    %sDeployment %s is running; waiting for it before deploying.%s\n' "$C_YELLOW" "$name" "$C_OFF"
    ckpt_wait_deployment_ "$1" "$name"
  done
}
ckpt_verify_gateway_() {
  ckpt_az_read_ 'ResourceNotFound' apim show -g "$1" -n "$2" --query name -o tsv
  if [ "$AZ_VERDICT" != "present" ]; then V_VERDICT="$AZ_VERDICT"; V_DETAIL="API Management $2 is not readable or gone ($AZ_DETAIL)"; return 0; fi
  ckpt_az_read_ 'ResourceNotFound' apim api show -g "$1" --service-name "$2" --api-id claude-foundry -o none
  if [ "$AZ_VERDICT" != "present" ]; then V_VERDICT="$AZ_VERDICT"; V_DETAIL="the Claude API on $2 is not readable or gone ($AZ_DETAIL)"; return 0; fi
  V_VERDICT=present; V_DETAIL=""
}

# Whether the gateway deployment runs (CKPT_GW_RUN) and, when it does not, its URL (CKPT_GW_URL). A
# recorded deployment still running is awaited, one that succeeded is verified live, one that failed
# is shown (ADR-0046 decision 10). A resume deploys again only over an APIM this run created (decision 9).
ckpt_gateway_plan_() {
  local rg="$1" apim="$2" title="Gateway deployment" hash state stored recorded origin
  CKPT_GW_RUN=1; CKPT_GW_URL=""
  [ "$CKPT_LOCKED" = "1" ] || return 0
  hash="$(ckpt_input_hash_ gateway-deployment)"
  state="$(ckpt_step_field_ gateway-deployment state)"; stored="$(ckpt_step_field_ gateway-deployment inputHash)"
  recorded="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '([.steps[]? | select(.id == "gateway-deployment")][0].receipt.deployments // []) | last | .name // empty')"
  if [ -n "$recorded" ]; then
    ckpt_deployment_state_ "$rg" "$recorded"
    if [ "$DS_VERDICT" = "present" ] && ! ckpt_terminal_ "$DS_STATE"; then ckpt_wait_deployment_ "$rg" "$recorded"; fi
    if [ "$DS_VERDICT" = "inconclusive" ]; then
      ckpt_refuse_ "deployment $recorded in resource group $rg could not be read ($DS_DETAIL), so it is neither skipped nor repeated. Nothing was changed. Resume: $(ckpt_resume_cmd_)"
    elif [ "$DS_VERDICT" = "absent" ]; then
      printf '    %s%s: deployment %s is not in the resource group'"'"'s history; deploying again%s\n' "$C_YELLOW" "$title" "$recorded" "$C_OFF"
    elif [ "$DS_STATE" != "Succeeded" ]; then
      printf '    %s%s: deployment %s %s: %s%s\n' "$C_YELLOW" "$title" "$recorded" "$DS_STATE" "$DS_ERROR" "$C_OFF"
      ckpt_az_read_ '' deployment operation group list -g "$rg" -n "$recorded" -o json
      if [ "$AZ_VERDICT" = "present" ]; then
        printf '%s' "$AZ_OUT" | ckpt_jq_ -r '.[]? | select(.properties.provisioningState == "Failed") | "      failed operation: \(.properties.targetResource.resourceName // "-"): \(.properties.statusMessage.error.message // "")"' 2>/dev/null
      fi
    elif [ "$stored" != "$hash" ]; then
      printf '    %s%s: the templates or answers changed since deployment %s; deploying again%s\n' "$C_YELLOW" "$title" "$recorded" "$C_OFF"
    else
      ckpt_verify_gateway_ "$rg" "$apim"
      [ "$V_VERDICT" = "inconclusive" ] && ckpt_refuse_ "$title could not be verified ($V_DETAIL). Nothing was changed. Resume: $(ckpt_resume_cmd_)"
      if [ "$V_VERDICT" = "present" ]; then
        CKPT_GW_URL="$DS_URL"; [ -n "$CKPT_GW_URL" ] || CKPT_GW_URL="$(ckpt_receipt_field_ gateway-deployment gatewayUrl)"
        [ "$state" = "completed" ] || ckpt_complete_gateway_ "$apim" "$CKPT_GW_URL"
        printf '    %s[OK]%s   %s: verified live, skipped (deployment %s)\n' "$C_GREEN" "$C_OFF" "$title" "$recorded"
        CKPT_GW_RUN=0; return 0
      fi
      printf '    %s%s: %s; deploying again%s\n' "$C_YELLOW" "$title" "$V_DETAIL" "$C_OFF"
    fi
  fi
  if [ "$CKPT_RESUMING" = "1" ] && [ "$(ckpt_receipt_field_ gateway-deployment origin)" != "created" ]; then
    ckpt_az_read_ 'ResourceNotFound' apim show -g "$rg" -n "$apim" --query name -o tsv
    if [ "$AZ_VERDICT" = "present" ]; then
      ckpt_refuse_ "a resumed install-claude-gateway.sh deploys again only over an API Management instance its own run created, and $apim existed before this install run; this installer reads back no named values before a deployment. Install-ClaudeGateway.ps1 -ExistingApimName $apim reads them back first. Nothing was changed."
    fi
    [ "$AZ_VERDICT" = "inconclusive" ] && ckpt_refuse_ "API Management $apim could not be read ($AZ_DETAIL), so whether this install run created it is unknown. Nothing was changed. Resume: $(ckpt_resume_cmd_)"
  fi
  ckpt_wait_main_deployments_ "$rg"
  ckpt_set_step_ gateway-deployment started "$hash"
}
# Recorded before az deployment group create, so a resume finds the deployment by name (R4). The
# APIM's origin is read with the first deployment.
ckpt_register_deployment_() {
  local origin
  [ "$CKPT_LOCKED" = "1" ] || return 0
  origin="$(ckpt_receipt_field_ gateway-deployment origin)"
  if [ -z "$origin" ]; then
    ckpt_az_read_ 'ResourceNotFound' apim show -g "$2" -n "$3" --query name -o tsv
    if [ "$AZ_VERDICT" = "absent" ]; then origin=created; else origin=pre-existing; fi
  fi
  CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --arg n "$1" --arg o "$origin" --arg now "$(ckpt_now_)" '
    .steps |= map(if .id == "gateway-deployment" then
      .receipt = ((.receipt // {}) | .deployments = ((.deployments // []) + [{name: $n, recordedUtc: $now, lastState: "started"}]) | .origin = (.origin // $o))
      else . end)')"
  ckpt_write_
  ckpt_cloudshell_line_
}
ckpt_complete_gateway_() {
  [ "$CKPT_LOCKED" = "1" ] || return 0
  CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --arg a "$1" --arg u "$2" '
    .steps |= map(if .id == "gateway-deployment" then
      .receipt = ((.receipt // {}) | .deployments = ((.deployments // []) | if length > 0 then .[:-1] + [(last | .lastState = "Succeeded")] else . end) | .apimName = $a | .gatewayUrl = $u)
      else . end)')"
  ckpt_set_step_ gateway-deployment completed
}

# The tier groups, with receipts: a resume reads each by id and never creates a second group with the
# same name (ADR-0046 decision 11). A name finds a group only by its exact display name.
ckpt_groups_() {
  local old made="" complete=1 verified=0 role name rec id origin when obj resume
  resume="$(ckpt_resume_cmd_)"
  old="$(ckpt_receipt_ entra-groups)"
  ckpt_set_step_ entra-groups started "$(ckpt_input_hash_ entra-groups)"
  for role in standard premium; do
    if [ "$role" = "standard" ]; then name="$1"; else name="$2"; fi
    rec="$(printf '%s' "${old:-null}" | ckpt_jq_ -r --arg r "$role" --arg n "$name" '[(.groups // [])[] | select(.role == $r and .displayName == $n)][0] | if . then [.id, .origin, (.createdUtc // "")] | join("\u001f") else empty end')"
    id=""; origin=""; when=""
    [ -n "$rec" ] && IFS="$CKPT_US" read -r id origin when <<EOF
$rec
EOF
    if [ -n "$id" ]; then
      ckpt_az_read_ "$CKPT_GRAPH_NOT_FOUND" ad group show --group "$id" --query id -o tsv
      if [ "$AZ_VERDICT" = "present" ]; then
        ok_ "$name exists ($id)"; verified=$((verified + 1))
        made="$made$(ckpt_jq_ -cn --arg r "$role" --arg n "$name" --arg i "$id" --arg o "$origin" --arg w "$when" '{role: $r, displayName: $n, id: $i, origin: $o, createdUtc: (if $w == "" then null else $w end)}')
"
        continue
      fi
      [ "$AZ_VERDICT" = "inconclusive" ] && ckpt_refuse_ "Entra group '$name' ($id) could not be read ($AZ_DETAIL), so it is neither skipped nor created again. Nothing was changed. Resume: $resume"
      if [ "$origin" = "created" ]; then
        ckpt_refuse_ "Entra group '$name' ($id), created by this run at $when, is not returned by Microsoft Graph. A group created moments ago can take time to appear in Microsoft Graph, and a rerun later continues without creating a second group. Nothing was changed. Resume: $resume"
      fi
      note_ "$name ($id) is gone; looking it up by name."
    fi
    ckpt_az_read_ '' ad group show --group "$name" -o json
    if [ "$AZ_VERDICT" = "present" ]; then
      obj="$(printf '%s' "$AZ_OUT" | ckpt_jq_ -r --arg n "$name" 'if .displayName == $n and (.id // "") != "" then .id else empty end' 2>/dev/null)"
      if [ -n "$obj" ]; then
        ok_ "$name exists"
        made="$made$(ckpt_jq_ -cn --arg r "$role" --arg n "$name" --arg i "$obj" '{role: $r, displayName: $n, id: $i, origin: "pre-existing", createdUtc: null}')
"
        continue
      fi
    fi
    ckpt_az_read_ '' ad group create --display-name "$name" --mail-nickname "$name" --query id -o tsv
    if [ "$AZ_VERDICT" = "present" ] && [ -n "$AZ_OUT" ]; then
      ok_ "$name created"
      made="$made$(ckpt_jq_ -cn --arg r "$role" --arg n "$name" --arg i "$AZ_OUT" --arg w "$(ckpt_now_)" '{role: $r, displayName: $n, id: $i, origin: "created", createdUtc: $w}')
"
    else
      warn_ "could not create '$name' - your tenant may restrict group creation"
      note_ "ask an admin to create it, then re-run"
      complete=0
    fi
  done
  [ "$verified" = "2" ] && printf '    %s[OK]%s   Entra groups: verified live, skipped\n' "$C_GREEN" "$C_OFF"
  made="$(printf '%s' "$made" | ckpt_jq_ -cs '{groups: .}')"
  if [ "$complete" = "1" ]; then ckpt_set_step_ entra-groups completed __keep__ "$made"; else ckpt_set_step_ entra-groups incomplete __keep__ "$made"; fi
}

# After the last step: removed when every step completed, kept with the resume command otherwise.
ckpt_close_() {
  [ "$CKPT_LOCKED" = "1" ] || return 0
  local open titles="" id
  open="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '[.steps[]? | select(.state != "completed") | .id] | join(" ")')"
  if [ -n "$open" ]; then
    for id in $open; do titles="${titles:+$titles, }$(ckpt_title_ "$id")"; done
    warn_ "The install checkpoint is kept: $titles did not complete."
    if [ "$CKPT_PERSISTENT" = "1" ]; then printf '    Resume: %s\n' "$(ckpt_resume_cmd_)"; else printf '    Resume: %s\n' "$(ckpt_resume_cmd_ with-answers)"; fi
  else
    rm -f "$CKPT_FILE"
    note_ "Install complete; the install checkpoint is removed."
  fi
  ckpt_release_
}
