# The installer preflight of install-claude-gateway.sh (docs/adr/0047-lean-installer-phase-0.md): the 14
# checks of Install-ClaudeGateway.ps1 -Preflight (scripts/ClaudeInstallerPreflight.ps1), with the same
# ids, results, reasons and report. A check that cannot run is NOT-RUN with its reason and never passes
# (P91 R1). A check without a pf_pass_ line that has a message is NOT-RUN (not-evaluated), which fails the
# preflight, so a check passes only where a branch passes it (ADR-0047 decision 5). Read-only: no create,
# update, set or delete call, no az account set, no checkpoint.
# Sourced by scripts/install-steps.sh. Bash 3.2 and later, with jq.

PF_LINES=""; PF_ANSWERS="{}"; PF_BAD=" "; PF_SUB=""
PF_IDS="answers.schema answers.crossField target.tenant target.subscription operator.adminPrereqs foundry.account foundry.deployments apim.nameAvailability apim.existingSku apim.existingIdentity entra.groupNames businessUnits.ids businessUnits.depth address.inputs"

# kind id reason message remedy: a problem, a pass or a NOT-RUN line of one check.
pf_add_() { PF_LINES="$PF_LINES$1$CKPT_US$2$CKPT_US$3$CKPT_US$4$CKPT_US${5:-}
"; }
pf_fail_() { pf_add_ problem "$1" "" "$2" "$3"; }
pf_pass_() { pf_add_ pass "$1" "" "$2" ""; }
pf_notrun_() { pf_add_ notrun "$1" "$2" "$3" "${4:-}"; }
# An answer to read from Azure: given, and without a problem of its own; a list is printed one per line.
pf_get_() {
  case "$PF_BAD" in *" $1 "*) return 0 ;; esac
  printf '%s' "$PF_ANSWERS" | jq -r --arg n "$1" '.[$n] // empty | if type == "array" then .[] | tostring elif type == "object" then tojson else tostring end' | tr -d '\r'
}
pf_has_() { printf '%s' "$PF_ANSWERS" | jq -e --arg n "$1" 'has($n) and .[$n] != null and .[$n] != ""' >/dev/null 2>&1; }

# The answers: the answers file, then the flags this run names over it (A12), and every problem the
# answers schema finds with them. An answer with a problem of its value is not read from Azure; one that
# only Install-ClaudeGateway.ps1 applies is reported and still checked, as that installer checks it.
pf_answers_() {
  local problems="[]" flags id path message remedy
  flags="$(answers_flags_json_)"
  PF_ANSWERS="$flags"
  if [ -n "${ANSWERS_FILE:-}" ]; then
    problems="$(answers_check_file_ "$ANSWERS_FILE" install-claude-gateway.sh | jq -c '[.[] | select(.path == "")]' | tr -d '\r')"
    [ "$problems" = "[]" ] && PF_ANSWERS="$(jq -cn --argjson f "$(answers_read_ "$ANSWERS_FILE")" --argjson g "$flags" '$f + $g' | tr -d '\r')"
  fi
  problems="$(jq -cn --argjson a "$problems" --argjson b "$(answers_check_json_ "$PF_ANSWERS" install-claude-gateway.sh)" '$a + $b' | tr -d '\r')"
  while IFS="$CKPT_US" read -r id path message remedy; do
    [ -n "$id" ] && pf_fail_ "$id" "$message" "$remedy"
  done <<EOF
$(printf '%s' "$problems" | jq -r '.[] | [.checkId, .path, .message, .remedy] | join("\u001f")' | tr -d '\r')
EOF
  for path in $(answers_check_json_ "$PF_ANSWERS" Install-ClaudeGateway.ps1 | jq -r '.[].path' | tr -d '\r'); do PF_BAD="$PF_BAD${path%%[.[]*} "; done
}

# operator.adminPrereqs: claude_preflight admin (scripts/preflight.sh), its lines captured.
# Why a subscription record from az account show cannot be used, or nothing when it can: output that is not
# JSON, or a record without its id or tenantId (ADR-0047 decision 5).
pf_record_problem_() {
  local why
  [ -n "$1" ] || { printf '%s' "az account show did not return JSON"; return 0; }
  why="$(printf '%s' "$1" | jq -r 'if type != "object" then "az account show did not return JSON" elif (.id | type) != "string" or .id == "" then "az account show returned no subscription id" elif (.tenantId | type) != "string" or .tenantId == "" then "az account show returned no tenantId" else "" end' 2>/dev/null)" || why="az account show did not return JSON"
  printf '%s' "$why" | tr -d '\r'
}

pf_prereqs_() {
  local out rc line fails="" warns=""
  [ "$(type -t claude_preflight 2>/dev/null)" = "function" ] || . "$HERE/scripts/preflight.sh"
  out="$(claude_preflight admin 2>&1 | tr -d '\033\r' | sed 's/\[[0-9;]*m//g')"; rc=$?
  while IFS= read -r line; do
    case "$line" in *"[FAIL]"*) fails="${fails}$(printf '%s' "${line#*\[FAIL\]}" | sed 's/^ *//')$CKPT_US" ;; *"[WARN]"*) warns="${warns:+$warns; }$(printf '%s' "${line#*\[WARN\]}" | sed 's/^ *//')" ;; esac
  done <<EOF
$out
EOF
  if [ -z "$fails" ] && [ "$rc" = "0" ]; then pf_pass_ operator.adminPrereqs "claude_preflight admin passed${warns:+; warnings: $warns}"; return 0; fi
  [ -n "$fails" ] || fails="claude_preflight admin failed$CKPT_US"
  local saved="$IFS"; IFS="$CKPT_US"
  for line in $fails; do [ -n "$line" ] && pf_fail_ operator.adminPrereqs "$line" "claude_preflight admin (scripts/preflight.sh) prints the remedy under each [FAIL] line."; done
  IFS="$saved"
}

# The checks that read Azure, once Azure CLI is signed in. Each read names the answered subscription with
# --subscription, so the preflight leaves the CLI's own subscription alone (az account set writes it).
pf_azure_() {
  local tenant user sub sub_ok=1 so name s_name="" s_state="" s_tenant="" why=""
  tenant="$(printf '%s' "$1" | jq -r '.tenantId // ""' | tr -d '\r')"; user="$(printf '%s' "$1" | jq -r '.user.name // ""' | tr -d '\r')"
  case "$PF_BAD" in *" SubscriptionId "*) sub_ok=0 ;; esac
  sub="$(pf_get_ SubscriptionId)"
  if [ -n "$sub" ]; then
    ckpt_az_read_ '' account show --subscription "$sub" -o json
    so="$AZ_OUT"; why="$AZ_DETAIL"
    # A record is used only with its id and tenant: without them each later read would name
    # --subscription null, or the wrong tenant would go unseen (ADR-0047 decision 5).
    if [ "$AZ_VERDICT" = "present" ]; then why="$(pf_record_problem_ "$so")"; [ -z "$why" ] || AZ_VERDICT=inconclusive; fi
    if [ "$AZ_VERDICT" != "present" ]; then
      sub_ok=0; pf_fail_ target.subscription "subscription '$sub' is not readable by $user ($why)" "Check it with az account list -o table, or sign in to the tenant that holds it."
    else
      PF_SUB="$(printf '%s' "$so" | jq -r '.id' | tr -d '\r')"
      eval "$(printf '%s' "$so" | jq -r '@sh "s_name=\(.name // "") s_state=\(.state // "") s_tenant=\(.tenantId // "")"' | tr -d '\r')"
      if [ -n "$s_state" ] && [ "$s_state" != "Enabled" ]; then sub_ok=0; pf_fail_ target.subscription "subscription $s_name ($PF_SUB) is $s_state" "Use an enabled subscription."; fi
      pf_pass_ target.subscription "subscription $s_name ($PF_SUB)"
      if [ -n "$s_tenant" ] && [ "$s_tenant" != "$tenant" ]; then pf_fail_ target.tenant "subscription $s_name is in tenant $s_tenant, and Azure CLI is signed in to tenant $tenant" "Run az login --tenant $s_tenant, then run the preflight again."; fi
    fi
  elif [ "$sub_ok" = "1" ] && ! printf '%s' "$1" | jq -e '(.id | type) == "string" and .id != ""' >/dev/null 2>&1; then
    sub_ok=0; pf_fail_ target.subscription "the current subscription could not be read (az account show returned no subscription id)" "Check az account show, or answer SubscriptionId, then run the preflight again."
  elif [ "$sub_ok" = "1" ]; then
    pf_pass_ target.subscription "SubscriptionId is not answered; the run uses the current subscription $(printf '%s' "$1" | jq -r '"\(.name) (\(.id))"' | tr -d '\r')"
  fi
  pf_pass_ target.tenant "signed in as $user in tenant $tenant"
  set -- ${PF_SUB:+--subscription "$PF_SUB"}
  if [ "$sub_ok" != "1" ]; then
    for name in foundry.account foundry.deployments apim.nameAvailability apim.existingSku apim.existingIdentity; do pf_notrun_ "$name" prerequisite-failed "target.subscription failed, so this was not read" "Correct target.subscription first."; done
  else
    pf_foundry_ "$@"
    pf_apim_ "$@"
  fi
  pf_groups_
}

pf_foundry_() {
  local fa frg where names claude wanted missing reason
  fa="$(pf_get_ FoundryAccount)"; frg="$(pf_get_ FoundryResourceGroup)"
  if [ -z "$fa" ]; then
    reason=not-answered; case "$PF_BAD" in *" FoundryAccount "*) reason=prerequisite-failed ;; esac
    pf_notrun_ foundry.account not-answered "FoundryAccount is not answered; the run looks for an account with a Claude deployment"
    pf_notrun_ foundry.deployments "$reason" "no Foundry account to read the deployments of"
    return 0
  fi
  if [ -n "$frg" ]; then where=" in resource group $frg"; ckpt_az_read_ 'ResourceNotFound' cognitiveservices account show -g "$frg" -n "$fa" -o json "$@"
  else
    where=" in the subscription"; ckpt_az_read_ '' cognitiveservices account list -o json "$@"
    # A list that is not JSON is inconclusive, as an unreadable list is.
    if [ "$AZ_VERDICT" = "present" ] && { [ -z "$AZ_OUT" ] || ! printf '%s' "$AZ_OUT" | jq empty >/dev/null 2>&1; }; then
      AZ_VERDICT=inconclusive; AZ_DETAIL="az cognitiveservices account list did not return JSON"
    fi
    if [ "$AZ_VERDICT" = "present" ]; then
      frg="$(printf '%s' "$AZ_OUT" | jq -r --arg n "$fa" '[.[]? | select(.name == $n)][0].resourceGroup // empty' | tr -d '\r')"
      [ -n "$frg" ] || AZ_VERDICT=absent
    fi
  fi
  case "$AZ_VERDICT" in
    present) pf_pass_ foundry.account "Foundry account $fa$where" ;;
    absent) pf_fail_ foundry.account "Foundry account $fa was not found$where" "Check the name and resource group with az cognitiveservices account list -o table." ;;
    *) pf_fail_ foundry.account "Foundry account $fa could not be read ($AZ_DETAIL)" "Check access with az cognitiveservices account show, then run the preflight again." ;;
  esac
  if [ "$AZ_VERDICT" != "present" ]; then pf_notrun_ foundry.deployments prerequisite-failed "foundry.account failed, so the deployments were not read" "Correct foundry.account first."; return 0; fi
  ckpt_az_read_ 'ResourceNotFound' cognitiveservices account deployment list -g "$frg" -n "$fa" -o json "$@"
  if [ "$AZ_VERDICT" != "present" ] || ! printf '%s' "$AZ_OUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
    pf_fail_ foundry.deployments "the deployments of $fa could not be read (${AZ_DETAIL:-the deployment list is not JSON})" "Check access with az cognitiveservices account deployment list, then run the preflight again."; return 0
  fi
  names="$(printf '%s' "$AZ_OUT" | jq -r '[.[] | .name // empty] | join(", ")' | tr -d '\r')"
  claude="$(printf '%s' "$AZ_OUT" | jq -r '[.[] | select((.properties.model.format // "") == "Anthropic" or ((.properties.model.name // "") | test("claude"))) | .name] | "\(length)\u001f\(join(", "))"' | tr -d '\r')"
  wanted="$( { pf_get_ StandardModels; printf '\n'; pf_get_ PremiumModels; } | awk 'NF && !seen[$0]++' | paste -sd, - | sed 's/,/, /g')"
  missing="$(printf '%s' "$AZ_OUT" | jq -r --arg w "$wanted" '[.[] | .name] as $have | [$w | split(", ")[] | select(length > 0) | select(. as $x | $have | index([$x]) | not)] | join(", ")' | tr -d '\r')"
  if [ -n "$missing" ]; then pf_fail_ foundry.deployments "the Foundry account $fa has no deployment named $missing" "Deploy it in Microsoft Foundry, or answer StandardModels and PremiumModels with deployed names: ${names:-none}."
  elif [ -n "$wanted" ]; then pf_pass_ foundry.deployments "deployed on $fa: $wanted"
  elif [ "${claude%%$CKPT_US*}" != "0" ]; then pf_pass_ foundry.deployments "${claude%%$CKPT_US*} Claude deployment(s) on $fa: ${claude#*$CKPT_US}"
  elif pf_has_ PendingClaudeDeployment; then pf_pass_ foundry.deployments "no Claude deployment on $fa yet; the run creates PendingClaudeDeployment after its summary"
  else pf_fail_ foundry.deployments "the Foundry account $fa has no Claude deployment" "Deploy a Claude model in Microsoft Foundry, or answer PendingClaudeDeployment."; fi
}

pf_apim_() {
  local existing rg prefix name avail reason where found sku="" identity="" state_rg=""
  existing="$(pf_get_ ExistingApimName)"; rg="$(pf_get_ ResourceGroup)"; prefix="$(pf_get_ NamePrefix)"
  if pf_has_ ExistingApimName; then pf_notrun_ apim.nameAvailability not-applicable "ExistingApimName is answered: the run reuses that instance and creates no name"
  elif [ -z "$prefix" ]; then pf_notrun_ apim.nameAvailability not-answered "NamePrefix is not answered; the run asks for one, claudegw<6 digits> by default"
  else
    name="apim-$prefix"
    ckpt_az_read_ '' apim check-name -n "$name" -o json "$@"
    avail="$(printf '%s' "$AZ_OUT" | jq -r 'if type == "object" and .nameAvailable != null then "\(.nameAvailable)\u001f\(.reason // "")" else empty end' 2>/dev/null | tr -d '\r')"
    if [ "$AZ_VERDICT" != "present" ] || [ -z "$avail" ]; then pf_fail_ apim.nameAvailability "whether $name is free could not be read ($AZ_DETAIL)" "Check az apim check-name -n $name, then run the preflight again."
    elif [ "${avail%%$CKPT_US*}" = "true" ]; then pf_pass_ apim.nameAvailability "$name is available"
    else
      reason="${avail#*$CKPT_US}"
      if [ -n "$rg" ]; then ckpt_az_read_ 'ResourceNotFound' apim show -g "$rg" -n "$name" --query name -o tsv "$@"; else AZ_VERDICT=absent; fi
      case "$AZ_VERDICT" in
        present) pf_pass_ apim.nameAvailability "$name exists in resource group $rg; the run updates it" ;;
        absent) pf_fail_ apim.nameAvailability "$name is taken by another API Management instance ($reason)" "Answer another NamePrefix: apim-<NamePrefix> is a globally unique DNS name." ;;
        *) pf_fail_ apim.nameAvailability "$name is taken, and whether it is the one in $rg could not be read ($AZ_DETAIL)" "Check az apim show -g $rg -n $name, then run the preflight again." ;;
      esac
    fi
  fi
  if [ -z "$existing" ]; then
    reason=not-applicable; case "$PF_BAD" in *" ExistingApimName "*) reason=prerequisite-failed ;; esac
    pf_notrun_ apim.existingSku not-applicable "ExistingApimName is not answered: the run creates apim-<NamePrefix>"
    pf_notrun_ apim.existingIdentity "$reason" "ExistingApimName is not answered, or it has a problem: no instance to read"
    return 0
  fi
  # The reuse read of Get-ClaudeApimReuseState: present, absent or inconclusive.
  if [ -n "$rg" ]; then where=" in resource group $rg"; ckpt_az_read_ 'ResourceNotFound' apim show -g "$rg" -n "$existing" -o json "$@"; found="$AZ_OUT"
  else where=" in the subscription"; ckpt_az_read_ '' apim list -o json "$@"; found="$(printf '%s' "$AZ_OUT" | jq -c --arg n "$existing" '[.[]? | select((.name // "" | ascii_downcase) == ($n | ascii_downcase))][0] // empty' 2>/dev/null | tr -d '\r')"; [ "$AZ_VERDICT" = "present" ] && [ -z "$found" ] && AZ_VERDICT=absent; fi
  if [ "$AZ_VERDICT" != "present" ]; then
    if [ "$AZ_VERDICT" = "absent" ]; then pf_fail_ apim.existingSku "API Management $existing was not found$where" "Check the name and resource group with az apim list -o table."
    else pf_fail_ apim.existingSku "API Management $existing could not be read ($AZ_DETAIL)" "Check access with az apim show, then run the preflight again."; fi
    pf_notrun_ apim.existingIdentity prerequisite-failed "apim.existingSku failed, so the identity was not read" "Correct apim.existingSku first."
    return 0
  fi
  eval "$(printf '%s' "$found" | jq -r '@sh "sku=\(.sku.name // "") identity=\(.identity.type // "") state_rg=\(.resourceGroup // "")"' | tr -d '\r')"
  [ -n "$state_rg" ] || state_rg="$rg"
  case "$sku" in *V2) pf_pass_ apim.existingSku "$existing is $sku in resource group $state_rg" ;;
    *) pf_fail_ apim.existingSku "$existing is $sku; only the v2 tiers meter Anthropic tokens, so every budget would read zero" "Reuse a BasicV2, StandardV2 or PremiumV2 instance, or leave ExistingApimName out to create one." ;; esac
  case "$identity" in *SystemAssigned*) pf_pass_ apim.existingIdentity "$existing has a system-assigned managed identity" ;;
    *) pf_fail_ apim.existingIdentity "$existing has no system-assigned managed identity (identity type ${identity:-none}); main.bicep grants that identity Cognitive Services User on the Foundry account (infra/main.bicep:511)" \
         "Azure portal > $existing > Security > Managed identities > System assigned: On > Save, then run again with -ExistingApimName $existing." ;; esac
}

# Entra groups are read from the tenant, with or without a subscription: the tier groups, each by the name
# rule of ADR-0046 decision 11 (install-claude-gateway.sh applies no business units).
pf_groups_() {
  local n name notes="" any=0
  for n in StandardGroup PremiumGroup; do
    case "$PF_BAD" in *" $n "*) continue ;; esac
    name="$(pf_get_ "$n")"
    if [ -z "$name" ]; then if [ "$n" = "StandardGroup" ]; then name="claude-code-standard"; else name="claude-code-premium"; fi; fi
    [ "$n" = "PremiumGroup" ] && [ "$name" = "${PF_FIRST_GROUP:-}" ] && continue
    PF_FIRST_GROUP="$name"; any=1
    ckpt_group_lookup_ "$name"
    case "$G_VERDICT" in
      present) notes="${notes:+$notes; }'$name' exists ($G_ID)" ;;
      absent) notes="${notes:+$notes; }'$name' is created by the run" ;;
      *) case "$G_DETAIL" in
           *"groups have a name of that length"*) pf_fail_ entra.groupNames "Entra group '$name' is not one group: $G_DETAIL" "Rename or remove one of those groups, or answer another group name." ;;
           *) pf_fail_ entra.groupNames "Entra group '$name' could not be looked up by name ($G_DETAIL)" "Sign in with an account that can read Entra groups in Microsoft Graph, for example one with the Directory Readers role, then run the preflight again." ;;
         esac ;;
    esac
  done
  [ "$any" = "1" ] && pf_pass_ entra.groupNames "Entra groups: $notes"
  return 0
}

# --preflight: prints the report, as JSON with --json, and returns 0 only when no check fails and none
# is NOT-RUN for a blocking reason.
preflight_run_() {
  local id acct result mode n unread=""
  PF_LINES=""; PF_BAD=" "; PF_SUB=""; PF_FIRST_GROUP=""
  pf_answers_
  pf_pass_ answers.schema "the answers match the answers schema, version 1"
  pf_pass_ answers.crossField "the answers that depend on each other agree"
  pf_prereqs_
  ckpt_az_read_ '' account show -o json
  acct="$AZ_OUT"
  # The signed-in account as JSON with its tenant; output that is not JSON, or has no tenantId, is
  # inconclusive, as an unreadable account is.
  if [ "$AZ_VERDICT" = "present" ]; then
    if [ -z "$acct" ] || ! printf '%s' "$acct" | jq empty >/dev/null 2>&1; then unread="az account show did not return JSON"
    elif ! printf '%s' "$acct" | jq -e '(.tenantId // "") != ""' >/dev/null 2>&1; then unread="az account show returned no tenantId"; fi
  fi
  if [ "$AZ_VERDICT" != "present" ] || [ -n "$unread" ]; then
    case "$AZ_VERDICT:$AZ_ERR" in
      present:*) pf_fail_ target.tenant "the signed-in account could not be read ($unread)" "Check az account show, then run the preflight again."
         for id in target.subscription foundry.account foundry.deployments apim.nameAvailability apim.existingSku apim.existingIdentity entra.groupNames; do
           pf_notrun_ "$id" prerequisite-failed "target.tenant failed, so this was not read" "Correct target.tenant first."; done ;;
      *"az login"*) for id in target.tenant target.subscription foundry.account foundry.deployments apim.nameAvailability apim.existingSku apim.existingIdentity entra.groupNames; do
          pf_notrun_ "$id" not-signed-in "Azure CLI is not signed in, so this was not read" "Run az login (az login --tenant <tenant-id> as a guest), then run the preflight again."; done ;;
      *) pf_fail_ target.tenant "the signed-in account could not be read ($AZ_DETAIL)" "Check az account show, then run the preflight again."
         for id in target.subscription foundry.account foundry.deployments apim.nameAvailability apim.existingSku apim.existingIdentity entra.groupNames; do
           pf_notrun_ "$id" prerequisite-failed "target.tenant failed, so this was not read" "Correct target.tenant first."; done ;;
    esac
  else pf_azure_ "$acct"; fi
  if printf '%s' "$PF_ANSWERS" | jq -e 'has("BusinessUnits")' >/dev/null 2>&1; then
    n="$(printf '%s' "$PF_ANSWERS" | jq -r '.BusinessUnits | if type == "array" then length else 1 end' | tr -d '\r')"
    pf_pass_ businessUnits.ids "$n units and teams; each id is lower-case and given once"
    pf_pass_ businessUnits.depth "$n units and teams; each team's parent is a unit without a parent (two levels)"
  else for id in businessUnits.ids businessUnits.depth; do pf_notrun_ "$id" not-answered "BusinessUnits is not answered"; done; fi
  mode="$(pf_get_ AddressMode)"
  case "$mode" in
    custom)
      if [ "$(pf_get_ AddressCertificateSource)" = "Pfx" ] && [ -n "$(pf_get_ AddressPfxPath)" ] && [ ! -f "$(pf_get_ AddressPfxPath)" ]; then
        pf_fail_ address.inputs "AddressPfxPath '$(pf_get_ AddressPfxPath)' is not a file" "Give the path of the PFX file, absolute or relative to the current directory."
      fi
      pf_pass_ address.inputs "custom address $(pf_get_ AddressHostname): certificate from $(pf_get_ AddressCertificateSource), DNS $(pf_get_ AddressDnsMode)" ;;
    azure) pf_notrun_ address.inputs not-applicable "AddressMode is azure: the gateway's own address needs no inputs" ;;
    *) pf_notrun_ address.inputs not-answered "AddressMode is not answered; the run asks for it, azure by default" ;;
  esac
  # Each message and remedy with the secrets an error quoted replaced (redact, scripts/install-checkpoint.sh).
  result="$(printf '%s' "$PF_LINES" | jq -R -s -c --arg ids "$PF_IDS" --argjson R "$CKPT_REDACT_RULES" "$CKPT_REDACT_JQ"'
    def firstseen: reduce .[] as $x ([]; if index([$x]) != null then . else . + [$x] end);
    [ split("\n")[] | select(length > 0) | split("\u001f") | {kind: .[0], id: .[1], reason: .[2], message: (.[3] | redact), remedy: (.[4] | redact)} ] as $l
    | [ $ids | split(" ")[] as $id
        | [ $l[] | select(.id == $id) ] as $mine
        | [ $mine[] | select(.kind == "problem") ] as $p
        | if ($p | length) > 0 then {id: $id, result: "FAIL", message: ($p | map(.message) | join("; ")), remedy: ($p | map(.remedy) | firstseen | join(" ")), reason: null, problems: [ $p[] | {message, remedy} ]}
          elif any($mine[]; .kind == "notrun") then ([ $mine[] | select(.kind == "notrun") ] | last) as $n | {id: $id, result: "NOT-RUN", message: $n.message, remedy: $n.remedy, reason: $n.reason, problems: []}
          elif any($mine[]; .kind == "pass" and (.message // "") != "") then ([ $mine[] | select(.kind == "pass" and (.message // "") != "") ] | last) as $s | {id: $id, result: "PASS", message: $s.message, remedy: "", reason: null, problems: []}
          else {id: $id, result: "NOT-RUN", message: "the preflight did not evaluate this check, which is a defect of the preflight", remedy: "Run the preflight from the latest checkout; if the check is still not evaluated, report it with this output.", reason: "not-evaluated", problems: []} end ] as $checks
    | {schemaVersion: 1, installer: "bash", answersSchemaVersion: 1,
       result: (if any($checks[]; .result == "FAIL" or (.result == "NOT-RUN" and ((.reason == "not-signed-in" or .reason == "prerequisite-failed") or .reason == "not-evaluated"))) then "FAIL" else "PASS" end), checks: $checks}' | tr -d '\r')"
  if [ "${WANT_JSON:-0}" = "1" ]; then printf '%s' "$result" | jq . | tr -d '\r'
  else
    printf '%s' "$result" | jq -r '
      "Preflight: \(.checks | length) checks; \([.checks[] | select(.result == "PASS")] | length) PASS, \([.checks[] | select(.result == "FAIL")] | length) FAIL, \([.checks[] | select(.result == "NOT-RUN")] | length) NOT-RUN.",
      (.checks[] | if .result == "FAIL" then (.problems[] as $p | "[FAIL] \(.id): \($p.message)\(if $p.remedy != "" then " Remedy: \($p.remedy)" else "" end)")
        elif .result == "NOT-RUN" then "[NOT-RUN] \(.id): \(.message) (\(.reason))\(if .remedy != "" then " Remedy: \(.remedy)" else "" end)"
        else "[PASS] \(.id): \(.message)" end)' | tr -d '\r' | sed 's/^/  /'
  fi
  [ "$(printf '%s' "$result" | jq -r '.result' | tr -d '\r')" = "PASS" ]
}
