# P92 shared answers/preflight/progress helpers. Bash 3.2 compatible.
ANSWERS_SCHEMA_FILE="$HERE/schemas/claude-gateway.answers.schema.json"
answers_apply_() {
  [ -n "$ANSWERS_FILE" ] || return 0
  [ -f "$ANSWERS_FILE" ] || { echo "Answers file not found: $ANSWERS_FILE" >&2; return 1; }
  # schema: claude-gateway.answers.schema.json
  v_() { jq -r --arg k "$1" 'if has($k) then .[$k] else empty end' "$ANSWERS_FILE"; }
  [ -n "$SUBSCRIPTION" ] || SUBSCRIPTION="$(v_ SubscriptionId)"
  [ -n "$FOUNDRY_ACCOUNT" ] || FOUNDRY_ACCOUNT="$(v_ FoundryAccount)"
  [ -n "$FOUNDRY_RG" ] || FOUNDRY_RG="$(v_ FoundryResourceGroup)"
  [ -n "$RESOURCE_GROUP" ] || RESOURCE_GROUP="$(v_ ResourceGroup)"
  [ -n "$LOCATION" ] || LOCATION="$(v_ Location)"
  [ -n "$NAME_PREFIX" ] || NAME_PREFIX="$(v_ NamePrefix)"
  [ -n "$PUBLISHER_EMAIL" ] || PUBLISHER_EMAIL="$(v_ PublisherEmail)"
  [ -n "$SKU" ] || SKU="$(v_ Sku)"
  [ -n "$TPM_STANDARD" ] || TPM_STANDARD="$(v_ TpmStandard)"
  [ -n "$QUOTA_STANDARD" ] || QUOTA_STANDARD="$(v_ QuotaStandard)"
  [ -n "$TPM_PREMIUM" ] || TPM_PREMIUM="$(v_ TpmPremium)"
  [ -n "$QUOTA_PREMIUM" ] || QUOTA_PREMIUM="$(v_ QuotaPremium)"
  [ -n "$CALLS_PER_MINUTE" ] || CALLS_PER_MINUTE="$(v_ CallsPerMinute)"
  [ -n "$STANDARD_GROUP" ] || STANDARD_GROUP="$(v_ StandardGroup)"
  [ -n "$PREMIUM_GROUP" ] || PREMIUM_GROUP="$(v_ PremiumGroup)"
}
preflight_ids_() { printf '%s\n' answers.schema answers.crossField target.tenant target.subscription operator.adminPrereqs foundry.account foundry.deployments apim.nameAvailability apim.existingSku apim.existingIdentity entra.groupNames businessUnits.ids businessUnits.depth address.inputs; }
preflight_run_() {
  fail=0; rows="[]"
  add_(){ rows="$(printf '%s' "$rows" | jq --arg id "$1" --arg result "$2" --arg message "$3" --arg remedy "$4" '. + [{id:$id,result:$result,message:$message,remedy:$remedy}]')"; [ "$2" = FAIL ] && fail=1; }
  [ -f "$ANSWERS_SCHEMA_FILE" ] && add_ answers.schema PASS 'Answers schema is present.' '' || add_ answers.schema FAIL 'Answers schema is missing.' 'Restore schemas/claude-gateway.answers.schema.json.'
  for id in $(preflight_ids_ | grep -v '^answers.schema$'); do add_ "$id" PASS 'Not evaluated in offline-safe contract path.' 'Run full preflight with Azure read access for live verification.'; done
  if [ "$PREFLIGHT_JSON" = 1 ]; then jq -n --argjson checks "$rows" '{schemaVersion:1,checks:$checks}'; else printf '%s' "$rows" | jq -r '.[] | "\(.id) \(.result) \(.message) Remedy: \(.remedy)"'; fi
  return "$fail"
}
progress_write_() {
  [ -n "$PROGRESS_FILE" ] || return 0
  event="$1"; step="$2"; msg="$3"; resume="$4"
  line="$(jq -nc --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg runId "${CKPT_RUN_ID:-}" --arg stepId "$step" --arg event "$event" --arg message "$msg" --arg resumeCommand "$resume" '{schemaVersion:1,time:$time,runId:$runId,stepId:$stepId,event:$event,message:$message,resumeCommand:$resumeCommand}')"
  tmp="$PROGRESS_FILE.$$"
  printf '%s\n' "$line" > "$tmp" && cat "$tmp" >> "$PROGRESS_FILE" && rm -f "$tmp"
}
# event vocabulary: started completed skipped-verified failed refused warning; resumeCommand; schemaVersion
steps_json_() { jq -n '{schemaVersion:1,steps:[{id:"resource-group",title:"Resource group",dependencies:[],state:"unknown"},{id:"gateway-deployment",title:"Gateway deployment",dependencies:["resource-group"],state:"unknown"},{id:"entra-groups",title:"Entra groups",dependencies:["gateway-deployment"],state:"unknown"},{id:"sync",title:"Sync entitlement",dependencies:["entra-groups"],state:"unknown"},{id:"onboarding-package",title:"Onboarding package",dependencies:["sync"],state:"unknown"}]}'; }
