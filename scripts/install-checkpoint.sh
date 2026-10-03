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
CKPT_FILES="install-claude-gateway.sh scripts/install-checkpoint.sh scripts/install-store.sh scripts/install-resume.sh"
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
# One rule set for the free text both installers write, the progress stream and every preflight message and
# remedy (ADR-0047 decision 12): a JWT, Bearer <token>, and name=value or name: value for a secret's name. The
# JSON is the same text as Get-ClaudeInstallRedactionRules in scripts/ClaudeInstallResume.ps1
# (tests/Test-InstallerRedaction.ps1). redact replaces each match by its group keep and [redacted], ignoring
# case; a jq program uses it as jq --argjson R "$CKPT_REDACT_RULES" "$CKPT_REDACT_JQ"'<program>'.
CKPT_REDACT_RULES='[{"name":"jwt","pattern":"eyJ[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_.-]*"},{"name":"bearer","pattern":"(?<keep>(?<![A-Za-z0-9_])bearer[ \\t]+)[^;&\"\u0027 \\t\\r\\n]+"},{"name":"named","pattern":"(?<keep>(?<![A-Za-z0-9_])(?:sig|signature|accountkey|sharedaccesskey|sharedaccesssignature|client_secret|clientsecret|password|pwd|secret|access_token|refresh_token)[\"\u0027]?[ \\t]*[=:][ \\t]*[\"\u0027]?)[^;&\"\u0027 \\t\\r\\n]+"}]'
CKPT_REDACT_JQ='def redact: if type == "string" then reduce $R[] as $r (.; gsub($r.pattern; "\(.keep // "")[redacted]"; "i")) else . end;'
# A line printed from an error or a refusal, with each secret shape of CKPT_REDACT_RULES replaced (ADR-0047
# decision 12). Without jq the text is printed as given; the lines printed before the installer's jq check
# (install-claude-gateway.sh, claude_preflight admin) quote no Azure CLI output.
ckpt_redact_() {
  local out
  if out="$(printf '%s' "$1" | jq -Rrs --argjson R "$CKPT_REDACT_RULES" "$CKPT_REDACT_JQ"' redact' 2>/dev/null | tr -d '\r')" && [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$1"; fi
}
# An Azure CLI call whose error output the run shows: its standard output passes through, and its standard
# error is printed after the call, with each secret shape replaced. Returns the call's status.
ckpt_shown_() {
  local err rc
  { err="$("$@" 2>&1 1>&3 3>&-)"; rc=$?; } 3>&1
  [ -z "$err" ] || printf '%s\n' "$(ckpt_redact_ "$err")" >&2
  return "$rc"
}

CKPT_ROOT=""; CKPT_DIR=""; CKPT_FILE=""; CKPT_LOCK=""; CKPT_KEY=""; CKPT_PERSISTENT=1; CKPT_WARNING=""; CKPT_CLOUDSHELL=""; CKPT_CLOUDDRIVE=0
CKPT_NOSTORE=""; CKPT_RESOLVED=""; CKPT_HOME_REAL=""; CKPT_EXPLICIT=0; CKPT_UNTRUSTED=""
CKPT_RESUMING=0; CKPT_JSON=""; CKPT_RUN_ID=""; CKPT_LOCKED=0; CKPT_HEARTBEAT=""; CKPT_REFUSED=0; CKPT_WHAT_IF=0
CKPT_FINGERPRINT=""; CKPT_COMMIT=""; CKPT_TEMPLATES=""; CKPT_NOTED=0; CKPT_SUB_ID=""; CKPT_ANSWER_COUNT=0; CKPT_WRITE_WARNED=0
CKPT_GW_RUN=1; CKPT_GW_URL=""
AZ_VERDICT=""; AZ_OUT=""; AZ_ERR=""; AZ_DETAIL=""; V_VERDICT=""; V_DETAIL=""; LOCK_STATE=""; LOCK_DETAIL=""; LOCK_HOLDER=""; LOCK_ENDS=""
DS_VERDICT=""; DS_STATE=""; DS_URL=""; DS_ERROR=""; DS_DETAIL=""; PERM_LINK=0; PERM_MINE=0; PERM_ROOT=0; PERM_MODE=""; PERM_OWNER=""; PERM_WHY=""
G_VERDICT=""; G_ID=""; G_DETAIL=""

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
  progress_event_ "${PROGRESS_CURRENT:-}" refused "Refused: $1"
  printf 'Refused: %s\n' "$(ckpt_redact_ "$(printf '%s' "$1" | tr '\r\n' '  ')")" >&2
  exit 1
}

# The command that resumes this run; with-answers adds every recorded answer, and the answers file the
# run read, for a checkpoint that does not persist (ADR-0046 decision 14).
ckpt_resume_cmd_() {
  local line name var flag kind value
  line="cd $(ckpt_quote_ "$CKPT_ROOT") && ./install-claude-gateway.sh"
  if [ "${1:-}" = "with-answers" ] && [ -n "${ANSWERS_FILE:-}" ]; then line="$line --answers-file $(ckpt_quote_ "$ANSWERS_FILE")"; fi
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
  elif ($n == "StandardGroup" or $n == "PremiumGroup") and ($v | contains("\u0027")) then "holds a single quote, which Azure CLI would place inside an OData string literal"
  elif $n == "Sku" and (["BasicV2", "StandardV2", "PremiumV2"] | index([$v])) == null then "is not one of BasicV2, StandardV2, PremiumV2"
  elif $n == "SubscriptionId" and ($v | guid | not) then "is not a subscription id"
  else empty end;
def text: type == "string" and ((explode | map(select(. < 32)) | length) == 0) and (startswith("@") | not);
def shaped($re): type == "string" and test($re) and text;
def origin: . == null or . == "created" or . == "pre-existing";
def nonempty: . != null and . != "";
# A receipt value reaches az as an argument on a resume, so a value of another shape is a corrupt checkpoint.
def rproblem($id):
  if . == null then empty
  elif type != "object" then "is not an object"
  elif $id == "resource-group" then
    (if (.name | shaped("^[A-Za-z0-9._()-]{1,90}$") | not) then "names the resource group \(.name | tojson)"
     elif (.location | nonempty) and (.location | shaped("^[a-z0-9]+$") | not) then "names the location \(.location | tojson)"
     elif (.origin | origin | not) then "has the origin \(.origin | tojson)"
     else empty end)
  elif $id == "gateway-deployment" then
    ([(.deployments // [])[] | select(. != null) | select(.name | shaped("^claude-(gw|gateway)-[A-Za-z0-9-]+$") | not) | "names the deployment \(.name | tojson)"] | first)
    // (if (.apimName | nonempty) and (.apimName | shaped("^[A-Za-z][A-Za-z0-9-]{0,49}$") | not) then "names the gateway \(.apimName | tojson)" else empty end)
    // (if (.gatewayUrl | nonempty) and (.gatewayUrl | shaped("^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$") | not) then "holds the gateway URL \(.gatewayUrl | tojson)" else empty end)
    // (if (.origin | origin | not) then "has the origin \(.origin | tojson)" else empty end)
  elif $id == "entra-groups" then
    ([(.groups // [])[] | select(. != null)
      | if (.id | guid | not) or (.id | text | not) then "holds the group id \(.id | tojson)"
        elif ((.role == "standard" or .role == "premium") and (.origin | origin) and (.displayName | text)) | not then "holds the group \(.displayName | tojson) with role \(.role | tojson) and origin \(.origin | tojson)"
        else empty end] | first) // empty
  elif $id == "onboarding-package" then
    (if .path != null and ((.path | type) != "string" or ((.path | explode | map(select(. < 32)) | length) > 0)) then "holds the path \(.path | tojson)" else empty end)
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
  // ([(.steps // [])[] | select(. != null) | .id as $id | (.receipt | rproblem($id)) as $p | "holds a receipt of step \($id) that \($p)"] | first)
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

# The checkpoint file into CKPT_JSON; one the installer cannot read, trust or resume refuses, and is
# kept as it is (decision 2). 1 when there is no checkpoint.
ckpt_read_file_() {
  local reason
  [ -f "$CKPT_FILE" ] || return 1
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
  return 0
}

# At startup, before any question: reads the checkpoint, refuses what it cannot resume, prints where
# the run resumes and sets each recorded answer that this run's flags do not name (decisions 5, 6).
ckpt_open_() {
  local restart="$2" aside fields b_tenant b_sub b_rg b_apim b_prefix run_id created was was_commit now name value line var flag
  CKPT_ROOT="$1"; CKPT_WHAT_IF="$3"
  ckpt_location_
  trap 'ckpt_exit_' EXIT
  if [ "$CKPT_WHAT_IF" = "1" ]; then
    if [ -f "$CKPT_FILE" ]; then note_ "An install checkpoint exists at $CKPT_FILE; --what-if previews a first run and changes nothing."; fi
    return 0
  fi
  [ -n "$CKPT_NOSTORE" ] && return 0
  # A default place that failed a check: no store, so nothing is resumed (decision 2).
  ckpt_store_check_ || return 0
  ckpt_lock_state_ "$CKPT_LOCK"
  [ "$LOCK_STATE" = "held" ] && ckpt_lock_held_
  if [ "$restart" = "1" ] && [ -f "$CKPT_FILE" ]; then
    aside="${CKPT_FILE%.json}.discarded-$(date -u '+%Y%m%dT%H%M%SZ').json"
    mv -f "$CKPT_FILE" "$aside"
    printf '    %s--restart: the install checkpoint is set aside as %s.%s\n' "$C_YELLOW" "$aside" "$C_OFF"
    return 0
  fi
  ckpt_read_file_ || return 0
  fields="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '[.binding.tenantId, .binding.subscriptionId, .binding.resourceGroup, .binding.apimName, (.binding.namePrefix // ""), .runId, (.createdUtc // ""), (.installerFingerprint // ""), (.installerCommit // "")] | join("\u001f")')"
  IFS="$CKPT_US" read -r b_tenant b_sub b_rg b_apim b_prefix run_id created was was_commit <<EOF
$fields
EOF
  # A subscription named by name is compared after az account set, by its id.
  if ckpt_passed_ --subscription && ckpt_is_guid_ "$SUBSCRIPTION" && ! ckpt_same_ "$SUBSCRIPTION" "$b_sub"; then ckpt_binding_refuse_ subscription "$b_sub" "$SUBSCRIPTION"; fi
  if ckpt_passed_ --resource-group && ! ckpt_same_ "$RESOURCE_GROUP" "$b_rg"; then ckpt_binding_refuse_ "resource group" "$b_rg" "$RESOURCE_GROUP"; fi
  if ckpt_passed_ --name-prefix && [ "$NAME_PREFIX" != "$b_prefix" ] && [ "apim-$NAME_PREFIX" != "$b_apim" ]; then ckpt_binding_refuse_ gateway "$b_apim" "apim-$NAME_PREFIX"; fi
  CKPT_RESUMING=1
  CKPT_RUN_ID="$run_id"
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
# The summary's Checkpoint row; an answer this run changes is named, so the confirmation covers it.
ckpt_summary_row_() {
  local changed
  changed="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r --argjson a "$(ckpt_answers_json_ "$(ckpt_subscription_id_)")" '.answers as $o | [$a | to_entries[] | select($o[.key] != .value) | .key] | join(", ")')"
  printf '%s, run %s, %s recorded answers reused, resumes at %s' "$CKPT_FILE" "$CKPT_RUN_ID" "$CKPT_ANSWER_COUNT" "$(ckpt_resume_title_)"
  if [ -n "$changed" ]; then printf '; changed since the checkpoint: %s' "$changed"; fi
}

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
  local sub answers now
  ckpt_version_info_
  sub="$(ckpt_subscription_id_)"; [ -n "$sub" ] || sub="$SUBSCRIPTION"
  answers="$(ckpt_answers_json_ "$sub")"
  now="$(ckpt_now_)"
  # Without a store (Git Bash, or a default place that failed a check at startup): one warning and the
  # resume command with the answers, as in an ephemeral Cloud Shell session (decision 1).
  if [ -n "$CKPT_NOSTORE" ]; then ckpt_nostore_warn_; return 0; fi
  # A state directory that cannot be created leaves the run without a checkpoint (decision 1). Each
  # missing directory is created owner-only (decision 2).
  if ! ( umask 077; mkdir -p "$CKPT_DIR" ) 2>/dev/null; then
    CKPT_NOSTORE="the install checkpoint directory $CKPT_DIR could not be created; this run keeps no checkpoint"
    ckpt_nostore_warn_
    return 0
  fi
  chmod 700 "$CKPT_DIR" 2>/dev/null
  if ! ckpt_store_check_; then ckpt_nostore_warn_; return 0; fi
  if [ "$CKPT_RESUMING" = "1" ]; then
    CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --argjson a "$answers" --arg f "$CKPT_FINGERPRINT" --arg c "$CKPT_COMMIT" '.answers = $a | .installerFingerprint = $f | .installerCommit = $c')"
  else
    [ -n "$CKPT_RUN_ID" ] || CKPT_RUN_ID="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n\r')"
    CKPT_JSON="$(ckpt_jq_ -cn --arg s "$CKPT_SCHEMA" --arg r "$CKPT_RUN_ID" --arg f "$CKPT_FINGERPRINT" --arg c "$CKPT_COMMIT" --arg k "$CKPT_ROOT" --arg now "$now" \
      --arg t "$TENANT_ID" --arg sub "$sub" --arg rg "$RESOURCE_GROUP" --arg apim "$APIM_NAME" --arg p "$NAME_PREFIX" --argjson a "$answers" \
      '{schema: $s, schemaVersion: 1, runId: $r, installer: "bash", installerFingerprint: $f, installerCommit: $c, checkout: $k, createdUtc: $now, updatedUtc: $now,
        binding: {tenantId: $t, subscriptionId: $sub, resourceGroup: $rg, apimName: $apim, namePrefix: $p, reusedApim: false}, answers: $a, steps: []}')"
  fi
  ckpt_lock_
  ckpt_write_
  if [ "$CKPT_PERSISTENT" != "1" ]; then
    warn_ "$CKPT_WARNING"
    printf '    Resume: %s\n' "$(ckpt_redact_ "$(ckpt_resume_cmd_ with-answers)")"
  fi
}

# The run keeps no store: one warning line, then the resume command with every recorded answer.
ckpt_nostore_warn_() {
  CKPT_PERSISTENT=0
  warn_ "$CKPT_NOSTORE"
  printf '    Resume: %s\n' "$(ckpt_redact_ "$(ckpt_resume_cmd_ with-answers)")"
}

# A temporary file renamed over the checkpoint, so an interrupted write leaves the previous one.
ckpt_write_() {
  [ "$CKPT_LOCKED" = "1" ] && [ -n "$CKPT_JSON" ] || return 0
  local tmp="$CKPT_FILE.tmp-$$-$RANDOM"
  CKPT_JSON="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -c --arg now "$(ckpt_now_)" '.updatedUtc = $now')"
  if ( umask 077; printf '%s' "$CKPT_JSON" | jq . | tr -d '\r' > "$tmp" ) 2>/dev/null && chmod 600 "$tmp" 2>/dev/null; then
    ckpt_perm_why_ "$tmp" file
    if [ -n "$PERM_WHY" ]; then
      rm -f "$tmp"
      ckpt_refuse_ "the install checkpoint file $tmp $PERM_WHY, so it is not trusted. The checkpoint was not replaced, and the run stops here. Resume: $(ckpt_resume_cmd_)"
    fi
    mv -f "$tmp" "$CKPT_FILE" 2>/dev/null && return 0
  fi
  rm -f "$tmp"
  if [ "$CKPT_WRITE_WARNED" != "1" ]; then CKPT_WRITE_WARNED=1; warn_ "the install checkpoint could not be written to $CKPT_FILE"; fi
}

# free, held or stale, who holds it, and when a later run may take it over (ADR-0046 decision 3).
ckpt_lock_state_() {
  local path="$1" fields pid host start recent=1 current heartbeat="a later run takes it over after 5 minutes without a heartbeat"
  LOCK_STATE=free; LOCK_DETAIL=""; LOCK_HOLDER=""; LOCK_ENDS=""
  [ -f "$path" ] || return 0
  [ -n "$(find "$path" -mmin +5 2>/dev/null)" ] && recent=0
  fields="$(ckpt_jq_ -r '[(.pid // "" | tostring), (.host // ""), (.processStart // "")] | join("\u001f")' "$path" 2>/dev/null)"
  IFS="$CKPT_US" read -r pid host start <<EOF
$fields
EOF
  if [ -z "$pid" ] || [ -z "$host" ]; then
    if [ "$recent" = "1" ]; then LOCK_STATE=held; else LOCK_STATE=stale; fi
    LOCK_DETAIL="an unreadable lock"; LOCK_HOLDER="its lock is unreadable"; LOCK_ENDS="$heartbeat"; return 0
  fi
  LOCK_DETAIL="host $host, PID $pid, started $start"; LOCK_HOLDER="$LOCK_DETAIL"
  if [ "$host" != "$(ckpt_host_)" ]; then
    LOCK_ENDS="$heartbeat"
    if [ "$recent" = "1" ]; then LOCK_STATE=held; LOCK_DETAIL="$LOCK_DETAIL, last heartbeat under 5 minutes ago"
    else LOCK_STATE=stale; LOCK_DETAIL="$LOCK_DETAIL, no heartbeat for 5 minutes"; fi
    LOCK_HOLDER="$LOCK_DETAIL"
    return 0
  fi
  current="$(ckpt_process_start_ "$pid")"
  if [ -z "$current" ] && ! kill -0 "$pid" 2>/dev/null; then LOCK_STATE=stale; LOCK_DETAIL="$LOCK_DETAIL, which has exited"; return 0; fi
  if [ -n "$current" ] && [ -n "$start" ] && [ "$current" != "$start" ]; then LOCK_STATE=stale; LOCK_DETAIL="$LOCK_DETAIL; that id now names a process started $current"; return 0; fi
  LOCK_STATE=held; LOCK_ENDS="a later run takes it over once that process has exited"
}
ckpt_lock_held_() {
  ckpt_refuse_ "another install run ($LOCK_HOLDER) holds the lock $CKPT_LOCK; nothing was changed. The lock ends with that run: $LOCK_ENDS. Resume: $(ckpt_resume_cmd_)"
}
ckpt_lock_() {
  local attempt=0 fields
  fields="$(ckpt_jq_ -cn --argjson pid "$$" --arg ps "$(ckpt_process_start_ "$$")" --arg h "$(ckpt_host_)" --arg r "$CKPT_RUN_ID" --arg now "$(ckpt_now_)" \
    '{pid: $pid, processStart: $ps, host: $h, installer: "bash", runId: $r, acquiredUtc: $now}')"
  while [ "$attempt" -lt 3 ]; do
    if ( set -C; umask 077; printf '%s' "$fields" > "$CKPT_LOCK" ) 2>/dev/null; then
      CKPT_LOCKED=1
      # The heartbeat lets another host tell a live run from a closed Cloud Shell session; it stops
      # with the installer even when no EXIT trap runs.
      ( parent=$$; while sleep 60; do kill -0 "$parent" 2>/dev/null || exit 0; [ -f "$CKPT_LOCK" ] || exit 0; touch "$CKPT_LOCK" 2>/dev/null || exit 0; done ) >/dev/null 2>&1 &
      CKPT_HEARTBEAT=$!
      return 0
    fi
    [ -f "$CKPT_LOCK" ] || ckpt_refuse_ "the lock $CKPT_LOCK could not be created. Nothing was changed."
    ckpt_perm_check_ "$CKPT_LOCK" file
    ckpt_lock_state_ "$CKPT_LOCK"
    [ "$LOCK_STATE" = "held" ] && ckpt_lock_held_
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
  [ "$code" != "0" ] && [ "$CKPT_REFUSED" != "1" ] && progress_failed_ "$code"
  ckpt_release_
  if [ "$held" = "1" ] && [ "$code" != "0" ] && [ "$CKPT_REFUSED" != "1" ] && [ -f "$CKPT_FILE" ]; then
    if [ "$CKPT_PERSISTENT" = "1" ]; then printf 'Resume: %s\n' "$(ckpt_redact_ "$(ckpt_resume_cmd_)")"; else printf 'Resume: %s\n' "$(ckpt_redact_ "$(ckpt_resume_cmd_ with-answers)")"; fi
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
  progress_state_ "$1" "$2"
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
  steps_selected_ "$id" || return 0
  title="$(ckpt_title_ "$id")"; hash="$(ckpt_input_hash_ "$id")"
  state="$(ckpt_step_field_ "$id" state)"; stored="$(ckpt_step_field_ "$id" inputHash)"
  if [ "$state" = "completed" ] && [ "$stored" = "$hash" ]; then
    "$verify" "$@"
    if [ "$V_VERDICT" = "present" ]; then printf '    %s[OK]%s   %s: verified live, skipped\n' "$C_GREEN" "$C_OFF" "$title"; progress_step_ "$id" skipped-verified; return 0; fi
    if [ "$V_VERDICT" = "inconclusive" ] && [ "$idempotent" != "1" ]; then ckpt_refuse_ "$title could not be verified ($V_DETAIL). Nothing was changed. Resume: $(ckpt_resume_cmd_)"; fi
    printf '    %s%s: %s; running it again%s\n' "$C_YELLOW" "$title" "$(ckpt_redact_ "$V_DETAIL")" "$C_OFF"
  elif [ "$state" = "completed" ]; then printf '    %s%s: its input changed since the checkpoint; running it again%s\n' "$C_YELLOW" "$title" "$C_OFF"
  fi
  ckpt_set_step_ "$id" started "$hash"
  return 1
}
# The summary's confirmation, then the commit point: the checkpoint is written after the summary is
# confirmed and before the first change (ADR-0032). Returns 1 when the operator declines.
ckpt_confirm_() {
  local question="$1"
  [ "$CKPT_RESUMING" = "1" ] && question="Resume from $(ckpt_resume_title_)?"
  if ! ask_yn_ "$question" "y"; then
    echo; echo "Cancelled."
    [ "$CKPT_RESUMING" = "1" ] && note_ "The install checkpoint is kept. To discard it and start again: $(ckpt_resume_cmd_) --restart"
    return 1
  fi
  ckpt_save_
}

# After the last step: removed when every step completed, kept with the resume command otherwise.
ckpt_close_() {
  [ "$CKPT_LOCKED" = "1" ] || return 0
  local open titles="" id
  open="$(printf '%s' "$CKPT_JSON" | ckpt_jq_ -r '[.steps[]? | select(.state != "completed") | .id] | join(" ")')"
  if [ -n "${STEPS:-}" ]; then
    # --steps ran part of the install, so the checkpoint is kept for the rest (A11).
    note_ "--steps ran $(printf '%s' "$STEPS" | sed 's/ /, /g'); the install checkpoint is kept, and a run without --steps resumes the rest."
    printf '    Resume: %s\n' "$(ckpt_redact_ "$(steps_resume_line_)")"
  elif [ -n "$open" ]; then
    for id in $open; do titles="${titles:+$titles, }$(ckpt_title_ "$id")"; done
    warn_ "The install checkpoint is kept: $titles did not complete."
    if [ "$CKPT_PERSISTENT" = "1" ]; then printf '    Resume: %s\n' "$(ckpt_redact_ "$(ckpt_resume_cmd_)")"; else printf '    Resume: %s\n' "$(ckpt_redact_ "$(ckpt_resume_cmd_ with-answers)")"; fi
  else
    rm -f "$CKPT_FILE"
    note_ "Install complete; the install checkpoint is removed."
  fi
  ckpt_release_
}

# Where the store is and whether it is trusted, the live reads and step actions, then step selection, the
# progress stream, the answers file and the preflight (ADR-0047).
. "$(dirname "${BASH_SOURCE[0]}")/install-store.sh"
. "$(dirname "${BASH_SOURCE[0]}")/install-resume.sh"
. "$(dirname "${BASH_SOURCE[0]}")/install-steps.sh"
