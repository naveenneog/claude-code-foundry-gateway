# Live reads and step actions of the install checkpoint (docs/adr/0046-installer-checkpoint-and-resume.md).
# Sourced by scripts/install-checkpoint.sh. Each read answers present, absent or inconclusive, and
# only present skips a step (R1). Bash 3.2 and later, with jq; no GNU-only flags.

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

# The resource group: verified live on a resume, otherwise created only when absent. A failed create
# stops the run, so nothing is deployed into a group that does not exist.
ckpt_resource_group_() {
  local location
  ckpt_skip_ resource-group 1 ckpt_verify_rg_ "$1" && return 0
  location="$(az group show -n "$1" --query location -o tsv 2>/dev/null < /dev/null | tr -d '\r')"
  if [ -n "$location" ]; then
    ok_ "$1 (exists, $location)"
    ckpt_set_step_ resource-group completed __keep__ "$(ckpt_jq_ -cn --arg n "$1" --arg l "$location" '{name: $n, location: $l, origin: "pre-existing"}')"
    return 0
  fi
  if ! az group create -n "$1" -l "$2" -o none; then
    bad_ "could not create resource group '$1' in '$2' - see the error above"
    exit 1
  fi
  ok_ "$1"
  ckpt_set_step_ resource-group completed __keep__ "$(ckpt_jq_ -cn --arg n "$1" --arg l "$2" '{name: $n, location: $l, origin: "created"}')"
}
