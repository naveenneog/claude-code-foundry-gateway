#!/usr/bin/env bash
#
# Claude on Microsoft Foundry - interactive gateway setup for macOS and Linux.
#
# Companion to Install-ClaudeGateway.ps1. Same wizard, same Bicep, same result:
# discovers your Foundry account, asks for every budget with a default already
# in place, shows a summary, and creates nothing until you confirm.
#
#   ./install-claude-gateway.sh
#   ./install-claude-gateway.sh --yes --foundry-account ai-contoso
#   ./install-claude-gateway.sh --what-if
#
# Re-runnable, so it is also how you change budgets later.

set -uo pipefail

SUBSCRIPTION=""; FOUNDRY_ACCOUNT=""; FOUNDRY_RG=""; RESOURCE_GROUP=""
LOCATION=""; NAME_PREFIX=""; PUBLISHER_EMAIL=""; SKU=""
TPM_STANDARD=""; QUOTA_STANDARD=""; TPM_PREMIUM=""; QUOTA_PREMIUM=""; CALLS_PER_MINUTE=""
STANDARD_GROUP="claude-code-standard"; PREMIUM_GROUP="claude-code-premium"
ASSUME_YES=0; WHAT_IF=0; CHOOSE_FINOPS=0; SKIP_FINOPS_OFFER=0; RESTART=0
FOUNDRY_LOCATION=""; CKPT_SEEN=""; ANSWERS_FILE=""; PREFLIGHT=0; WANT_JSON=0; LIST_STEPS=0; STEPS=""; PROGRESS_FILE=""; LAST_BAD=""

HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -t 1 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_GREY=$'\033[90m'; C_WHITE=$'\033[97m'; C_OFF=$'\033[0m'
else
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""; C_OFF=""
fi

head_() { printf '\n%s========================================================================%s\n' "$C_CYAN" "$C_OFF"
          printf '%s %s%s\n' "$C_CYAN" "$1" "$C_OFF"
          printf '%s========================================================================%s\n' "$C_CYAN" "$C_OFF"; }
step_() { printf '\n%s==> %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok_()   { printf '    %s[OK]%s   %s\n' "$C_GREEN" "$C_OFF" "$1"; }
warn_() { printf '    %s[WARN]%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
bad_()  { LAST_BAD="$1"; printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"; }
note_() { printf '    %s%s%s\n' "$C_GREY" "$1" "$C_OFF"; }

usage_() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Prompt with the default already in place; Enter accepts it.
ask_() {
  local prompt="$1" default="${2:-}" help="${3:-}" answer
  if [ "$ASSUME_YES" = "1" ]; then printf '%s' "$default"; return; fi
  [ -n "$help" ] && printf '    %s%s%s\n' "$C_GREY" "$help" "$C_OFF" >&2
  if [ -n "$default" ]; then
    printf '    %s%s [%s]%s: ' "$C_WHITE" "$prompt" "$default" "$C_OFF" >&2
  else
    printf '    %s%s%s: ' "$C_WHITE" "$prompt" "$C_OFF" >&2
  fi
  read -r answer
  [ -z "$answer" ] && answer="$default"
  printf '%s' "$answer"
}

ask_int_() {
  local prompt="$1" default="$2" help="${3:-}" v
  while true; do
    v="$(ask_ "$prompt" "$default" "$help")"
    case "$v" in
      ''|*[!0-9]*) printf '    %sEnter a whole number.%s\n' "$C_YELLOW" "$C_OFF" >&2 ;;
      *) printf '%s' "$v"; return ;;
    esac
  done
}

ask_yn_() {
  local prompt="$1" default="${2:-y}" a
  if [ "$ASSUME_YES" = "1" ]; then [ "$default" = "y" ] && return 0 || return 1; fi
  local hint="y/N"; [ "$default" = "y" ] && hint="Y/n"
  printf '    %s%s [%s]%s: ' "$C_WHITE" "$prompt" "$hint" "$C_OFF" >&2
  read -r a
  [ -z "$a" ] && a="$default"
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# A terminal, or a test driving one through standard input (CLAUDE_INTERACTIVE=1); never CI, and
# never with CLAUDE_NONINTERACTIVE=1. The rule of Test-ClaudeInteractive in scripts/ClaudeChoice.ps1.
interactive_() {
  [ "${CLAUDE_NONINTERACTIVE:-}" = "1" ] && return 1
  [ "${CLAUDE_INTERACTIVE:-}" = "1" ] && return 0
  [ -n "${CI:-}${TF_BUILD:-}${GITHUB_ACTIONS:-}" ] && return 1
  [ -t 0 ]
}

# 'West US 3' and 'westus3' name the same region; ARM and the Retail Prices API use the second.
arm_region_() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

# API Management prices for the region and tier prompts and the summary (P75, ADR-0032).
. "$HERE/scripts/install-prices.sh"

while [ $# -gt 0 ]; do
  CKPT_SEEN="$CKPT_SEEN $1"  # the flags this run names win over a checkpoint's answers (ADR-0046)
  case "$1" in
    --subscription)     SUBSCRIPTION="${2:-}"; shift 2 ;;
    --foundry-account)  FOUNDRY_ACCOUNT="${2:-}"; shift 2 ;;
    --foundry-rg)       FOUNDRY_RG="${2:-}"; shift 2 ;;
    --resource-group)   RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --location)         LOCATION="${2:-}"; shift 2 ;;
    --name-prefix)      NAME_PREFIX="${2:-}"; shift 2 ;;
    --publisher-email)  PUBLISHER_EMAIL="${2:-}"; shift 2 ;;
    --sku)              SKU="${2:-}"; shift 2 ;;
    --tpm-standard)     TPM_STANDARD="${2:-}"; shift 2 ;;
    --quota-standard)   QUOTA_STANDARD="${2:-}"; shift 2 ;;
    --tpm-premium)      TPM_PREMIUM="${2:-}"; shift 2 ;;
    --quota-premium)    QUOTA_PREMIUM="${2:-}"; shift 2 ;;
    --calls-per-minute) CALLS_PER_MINUTE="${2:-}"; shift 2 ;;
    --standard-group)   STANDARD_GROUP="${2:-}"; shift 2 ;;
    --premium-group)    PREMIUM_GROUP="${2:-}"; shift 2 ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    --what-if)          WHAT_IF=1; shift ;;
    --choose-finops)    CHOOSE_FINOPS=1; shift ;;
    --skip-finops-offer) SKIP_FINOPS_OFFER=1; shift ;;
    --restart)          RESTART=1; shift ;;
    --answers-file)     ANSWERS_FILE="${2:-}"; shift 2 ;;
    --preflight)        PREFLIGHT=1; shift ;;
    --json)             WANT_JSON=1; shift ;;
    --list-steps)       LIST_STEPS=1; shift ;;
    --steps)            STEPS="${2:-}"; shift 2 ;;
    --progress-file)    PROGRESS_FILE="${2:-}"; shift 2 ;;
    -h|--help)          usage_ ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# The install checkpoint (docs/adr/0046-installer-checkpoint-and-resume.md), then the answers file, the
# preflight, --list-steps, --steps and the progress file (docs/adr/0047-lean-installer-phase-0.md).
[ -f "$HERE/scripts/install-checkpoint.sh" ] || { echo "scripts/install-checkpoint.sh is missing from this checkout." >&2; exit 1; }
. "$HERE/scripts/install-checkpoint.sh"
steps_start_

if [ -f "$HERE/scripts/banner.sh" ]; then
  . "$HERE/scripts/banner.sh"
  claude_banner "Governed gateway for Claude on Microsoft Foundry"
else
  head_ "Claude on Microsoft Foundry - governed gateway setup"
  printf '\n'
fi
printf ' %sEvery prompt has a default. Press Enter to accept it.%s\n' "$C_GREY" "$C_OFF"
printf ' %sNothing is created until you confirm the summary.%s\n' "$C_GREY" "$C_OFF"

# Fail here, with a specific remedy, rather than part-way through a deployment.
if [ -f "$HERE/scripts/preflight.sh" ]; then
  . "$HERE/scripts/preflight.sh"
  claude_preflight admin || exit 1
else
  command -v az >/dev/null 2>&1 || { echo "Azure CLI is required. https://learn.microsoft.com/cli/azure/install-azure-cli" >&2; exit 1; }
  command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }
fi

# An interrupted run's checkpoint and answers, used as if passed (docs/adr/0046-installer-checkpoint-and-resume.md).
ckpt_open_ "$HERE" "$RESTART" "$WHAT_IF"

# ------------------------------------------------------------------ sign-in

step_ "Azure sign-in"
if ! az account show >/dev/null 2>&1; then
  warn_ "not signed in - launching az login"
  az login -o none || { bad_ "sign-in failed"; exit 1; }
fi
USER_NAME="$(az account show --query user.name -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
ok_ "$USER_NAME"
note_ "tenant $TENANT_ID"
ckpt_assert_tenant_ "$TENANT_ID"

if [ -z "$SUBSCRIPTION" ]; then
  # Listing every subscription is unusable on a large tenant - some accounts
  # can see dozens. Offer the current one first, then filter if it is wrong.
  CURRENT_NAME="$(az account show --query name -o tsv)"
  if [ "$ASSUME_YES" = "1" ] || ask_yn_ "Use subscription '$CURRENT_NAME'?" "y"; then
    SUBSCRIPTION="$(az account show --query id -o tsv)"
  else
    subs_json="$(az account list --query "[?state=='Enabled'].{name:name,id:id}" -o json)"
    total="$(printf '%s' "$subs_json" | jq 'length')"
    echo
    filter="$(ask_ "Filter by name (blank for all)" "" "$total subscriptions available.")"
    if [ -n "$filter" ]; then
      shown="$(printf '%s' "$subs_json" | jq --arg f "$filter" '[.[] | select(.name | ascii_downcase | contains($f | ascii_downcase))]')"
    else
      shown="$subs_json"
    fi
    n="$(printf '%s' "$shown" | jq 'length')"
    if [ "$n" -eq 0 ]; then warn_ "nothing matched '$filter'"; shown="$subs_json"; n="$total"; fi
    if [ "$n" -gt 25 ]; then
      warn_ "$n matches - showing the first 25. Filter more narrowly to see others."
      shown="$(printf '%s' "$shown" | jq '.[0:25]')"; n=25
    fi
    echo
    printf '%s' "$shown" | jq -r 'to_entries[] | "      \(.key+1). \(.value.name)"'
    echo
    while true; do
      pick="$(ask_ "Subscription number" "1")"
      case "$pick" in
        ''|*[!0-9]*) warn_ "Enter a number between 1 and $n." ;;
        *) if [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then break; else warn_ "Enter a number between 1 and $n."; fi ;;
      esac
    done
    SUBSCRIPTION="$(printf '%s' "$shown" | jq -r --argjson i "$((pick-1))" '.[$i].id')"
  fi
fi
az account set --subscription "$SUBSCRIPTION"
SUB_NAME="$(az account show --query name -o tsv)"
ok_ "subscription: $SUB_NAME"
ckpt_assert_subscription_
steps_prereqs_

# ----------------------------------------------------------- Foundry account

step_ "Foundry account"
if [ -z "$FOUNDRY_ACCOUNT" ]; then
  note_ "looking for accounts with a Claude deployment..."

  # Only AIServices and OpenAI-kind accounts can host a Claude deployment, so
  # filter server-side first. Without this the loop below queries every
  # Cognitive Services account in the subscription - 40+ on a large one - which
  # is slow and floods the console.
  accounts="$(az cognitiveservices account list --query "[?kind=='AIServices' || kind=='OpenAI'].{name:name,rg:resourceGroup,loc:location}" -o json)"
  cand="$(printf '%s' "$accounts" | jq 'length')"
  if [ "$cand" -eq 0 ]; then
    bad_ "no AIServices or OpenAI accounts found in this subscription"
    exit 1
  fi
  note_ "checking $cand candidate account(s)..."

  matches="[]"
  while IFS=$'\t' read -r nm rg loc; do
    [ -z "$nm" ] && continue
    models="$(az cognitiveservices account deployment list -g "$rg" -n "$nm" --query "[?contains(name,'claude')].name" -o tsv 2>/dev/null | paste -sd, -)"
    if [ -n "$models" ]; then
      matches="$(printf '%s' "$matches" | jq --arg n "$nm" --arg r "$rg" --arg l "$loc" --arg m "$models" '. + [{name:$n,rg:$r,loc:$l,models:$m}]')"
    fi
  done < <(printf '%s' "$accounts" | jq -r '.[] | [.name,.rg,.loc] | @tsv')

  count="$(printf '%s' "$matches" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    bad_ "no Foundry account with a Claude deployment in this subscription"
    note_ "deploy claude-sonnet-5 and/or claude-opus-5 first - the gateway fronts a model, it cannot create one"
    exit 1
  fi
  echo
  printf '%s' "$matches" | jq -r 'to_entries[] | "      \(.key+1). \(.value.name)   \(.value.loc)   \(.value.models)"'
  echo
  if [ "$count" -eq 1 ]; then pick=1; else pick="$(ask_ "Account number" "1")"; fi
  idx=$((pick-1))
  FOUNDRY_ACCOUNT="$(printf '%s' "$matches" | jq -r --argjson i "$idx" '.[$i].name')"
  FOUNDRY_RG="$(printf '%s' "$matches" | jq -r --argjson i "$idx" '.[$i].rg')"
  FOUNDRY_LOCATION="$(printf '%s' "$matches" | jq -r --argjson i "$idx" '.[$i].loc')"
  [ -z "$LOCATION" ] && LOCATION="$FOUNDRY_LOCATION"
fi
[ -z "$FOUNDRY_RG" ] && FOUNDRY_RG="$(az cognitiveservices account list --query "[?name=='$FOUNDRY_ACCOUNT'].resourceGroup | [0]" -o tsv)"
if [ -z "$FOUNDRY_RG" ]; then
  bad_ "could not resolve the resource group for '$FOUNDRY_ACCOUNT'"
  note_ "check the name, and that you can see it: az cognitiveservices account list -o table"
  note_ "or pass it explicitly with --foundry-rg"
  exit 1
fi
ok_ "$FOUNDRY_ACCOUNT (rg $FOUNDRY_RG)"

# ---------------------------------------------------------------- placement

step_ "Where to put the gateway"
if [ -z "$LOCATION" ]; then
  FOUNDRY_LOCATION="$(az cognitiveservices account show -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" --query location -o tsv)"
  LOCATION="$FOUNDRY_LOCATION"
fi
if [ -z "$LOCATION" ]; then
  bad_ "could not resolve the location of '$FOUNDRY_ACCOUNT'"
  note_ "pass it explicitly with --location"
  exit 1
fi
[ -z "$RESOURCE_GROUP" ] && RESOURCE_GROUP="$(ask_ "Resource group" "$FOUNDRY_RG" "Created if it does not exist. Same region as Foundry keeps latency down.")"
if [ "$ASSUME_YES" = "1" ] || [ "$CKPT_RESUMING" = "1" ]; then LOCATION="$(arm_region_ "$LOCATION")"; else read_gateway_region_ "$(arm_region_ "$LOCATION")"; fi

# No pre-flight check on v2 SKU availability - there is no reliable CLI call for
# it, and a guess that reports the wrong answer is worse than none. The
# deployment fails clearly if the SKU is unavailable in the region.
if [ -z "$SKU" ] && [ "$ASSUME_YES" != "1" ]; then show_tier_prices_ "$LOCATION"; fi
while true; do
  SKU="${SKU:-$(ask_ "API Management SKU" "BasicV2" "Must be a v2 tier. Classic tiers attach the policies but meter zero Anthropic tokens, so budgets never trigger.")}"
  case "$SKU" in
    BasicV2|StandardV2|PremiumV2) break ;;
    *) warn_ "Must be BasicV2, StandardV2 or PremiumV2."; SKU="" ;;
  esac
done

[ -z "$NAME_PREFIX" ] && NAME_PREFIX="$(ask_ "Name prefix" "claudegw$(od -An -N3 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-6)" "API Management names are globally unique DNS labels.")"
[ -z "$PUBLISHER_EMAIL" ] && PUBLISHER_EMAIL="$(ask_ "Publisher email" "$USER_NAME" "Shown on the API Management instance.")"

# ------------------------------------------------------------------ budgets

head_ "Budgets"
printf '\n %sApplied per developer, keyed on their Entra object id.%s\n' "$C_GREY" "$C_OFF"
printf ' %sChangeable later without redeploying - these are APIM named values.%s\n' "$C_GREY" "$C_OFF"

step_ "Standard tier"
[ -z "$TPM_STANDARD" ]   && TPM_STANDARD="$(ask_int_ "Tokens per minute" 20000 "A busy chat session uses a few thousand. Agentic work uses far more.")"
[ -z "$QUOTA_STANDARD" ] && QUOTA_STANDARD="$(ask_int_ "Tokens per day" 500000 "Roughly a full working day of steady use.")"

step_ "Premium tier"
[ -z "$TPM_PREMIUM" ]   && TPM_PREMIUM="$(ask_int_ "Tokens per minute" 80000 "For heavy agentic use - Cowork and long Claude Code runs.")"
[ -z "$QUOTA_PREMIUM" ] && QUOTA_PREMIUM="$(ask_int_ "Tokens per day" 5000000 "")"

step_ "Safety valve"
[ -z "$CALLS_PER_MINUTE" ] && CALLS_PER_MINUTE="$(ask_int_ "Requests per minute, per developer" 120 "Catches a runaway loop making many small calls.")"

[ "$TPM_STANDARD" -gt "$TPM_PREMIUM" ] 2>/dev/null && warn_ "standard tokens-per-minute is above premium - intended?"
[ "$QUOTA_STANDARD" -gt "$QUOTA_PREMIUM" ] 2>/dev/null && warn_ "standard daily quota is above premium - intended?"

step_ "Entitlement groups"
note_ "Membership of these Entra groups is what grants access."
[ "$CKPT_RESUMING" = "1" ] || STANDARD_GROUP="$(ask_ "Standard tier group" "$STANDARD_GROUP")"
[ "$CKPT_RESUMING" = "1" ] || PREMIUM_GROUP="$(ask_ "Premium tier group" "$PREMIUM_GROUP")"
ckpt_group_names_

# ------------------------------------------------------------------ summary

APIM_NAME="apim-$NAME_PREFIX"
fmt_() { printf "%'d" "$1" 2>/dev/null || printf '%s' "$1"; }

head_ "Summary"
echo
printf '  %-24s %s\n' "Subscription"           "$SUB_NAME"
printf '  %-24s %s\n' "Foundry account"        "$FOUNDRY_ACCOUNT (rg $FOUNDRY_RG)"
printf '  %-24s %s\n' "Gateway resource group" "$RESOURCE_GROUP"
printf '  %-24s %s\n' "Location"               "$LOCATION"
printf '  %-24s %s\n' "API Management"         "$APIM_NAME  ($SKU)"
printf '  %-24s %s\n' "Publisher email"        "$PUBLISHER_EMAIL"
echo
printf '  %-24s %s tokens/min, %s tokens/day\n' "Standard tier" "$(fmt_ "$TPM_STANDARD")" "$(fmt_ "$QUOTA_STANDARD")"
printf '  %-24s %s tokens/min, %s tokens/day\n' "Premium tier"  "$(fmt_ "$TPM_PREMIUM")"  "$(fmt_ "$QUOTA_PREMIUM")"
printf '  %-24s %s requests/min\n'              "Request ceiling" "$CALLS_PER_MINUTE"
echo
printf '  %-24s %s\n' "Entra groups" "$STANDARD_GROUP, $PREMIUM_GROUP"
[ "$CKPT_RESUMING" = "1" ] && printf '  %-24s %s\n' "Checkpoint" "$(ckpt_summary_row_)"
echo
# Priced for the tier and region being created, as Install-ClaudeGateway.ps1 does. This line used
# to name one fixed Basic v2 price, whatever tier and region were chosen.
apim_prices_ || true
APIM_MONTHLY="$(price_ "$LOCATION" "$SKU")"
if [ -n "$APIM_MONTHLY" ]; then
  printf '  %sCost: API Management is the bulk of it - %s in %s is %s/month at list price%s\n' "$C_GREY" "$SKU" "$LOCATION" "$(money_ "$APIM_MONTHLY" 0)" "$C_OFF"
  printf '  %s      (one unit, 730 hours, Azure retail prices read %s).%s\n' "$C_GREY" "${PRICES_READ%% *}" "$C_OFF"
else
  printf '  %sCost: API Management is the bulk of it. The %s price in %s could not be read%s\n' "$C_GREY" "$SKU" "$LOCATION" "$C_OFF"
  printf '  %s      from the Azure retail prices API; check https://azure.microsoft.com/pricing/details/api-management/%s\n' "$C_GREY" "$C_OFF"
fi
printf '  %sProvisioning takes minutes on the v2 tiers - a Premium v2 install measured 5 minutes 23 seconds end to end.%s\n' "$C_GREY" "$C_OFF"
echo

if [ "$WHAT_IF" = "1" ]; then warn_ "--what-if - stopping before any change"; exit 0; fi
ckpt_confirm_ "Create these resources?" || exit 0

# ------------------------------------------------------------------- deploy

head_ "Deploying"

step_ "Resource group"
ckpt_resource_group_ "$RESOURCE_GROUP" "$LOCATION"

step_ "API Management and Application Insights (a few minutes)"
note_ "safe to leave running"
# A recorded deployment is awaited, used or shown first; the body below is not re-indented.
ckpt_gateway_plan_ "$RESOURCE_GROUP" "$APIM_NAME"
GATEWAY_URL="$CKPT_GW_URL"
if [ "$CKPT_GW_RUN" = "1" ]; then
DEPLOY_NAME="claude-gw-$(date +%Y%m%d%H%M%S)"
ckpt_register_deployment_ "$DEPLOY_NAME" "$RESOURCE_GROUP" "$APIM_NAME"
if ! az deployment group create \
      --name "$DEPLOY_NAME" \
      -g "$RESOURCE_GROUP" \
      --template-file "$HERE/infra/main.bicep" \
      --parameters \
        namePrefix="$NAME_PREFIX" \
        location="$LOCATION" \
        foundryAccountName="$FOUNDRY_ACCOUNT" \
        foundryResourceGroup="$FOUNDRY_RG" \
        publisherEmail="$PUBLISHER_EMAIL" \
        apimSku="$SKU" \
        tpmStandard="$TPM_STANDARD" \
        quotaStandard="$QUOTA_STANDARD" \
        tpmPremium="$TPM_PREMIUM" \
        quotaPremium="$QUOTA_PREMIUM" \
        callsPerMinute="$CALLS_PER_MINUTE" \
      -o none; then
  bad_ "deployment failed - see the error above"
  exit 1
fi
ok_ "deployed"

GATEWAY_URL="$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOY_NAME" --query "properties.outputs.gatewayUrl.value" -o tsv 2>/dev/null || true)"
[ -z "$GATEWAY_URL" ] && GATEWAY_URL="https://$APIM_NAME.azure-api.net/claude"
ckpt_complete_gateway_ "$APIM_NAME" "$GATEWAY_URL"
fi

# -------------------------------------------------------------------- groups

step_ "Entra groups"
ckpt_groups_ "$STANDARD_GROUP" "$PREMIUM_GROUP"

# With --steps, each step below runs only when named; the blocks are not re-indented.
if steps_selected_ sync; then
step_ "Sync entitlement"
SYNC_STATE=completed; ckpt_set_step_ sync started
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$HERE/scripts/Sync-ClaudeAccess.ps1" \
    -ApimName "$APIM_NAME" -ResourceGroup "$RESOURCE_GROUP" \
    -StandardGroup "$STANDARD_GROUP" -PremiumGroup "$PREMIUM_GROUP" || { warn_ "sync reported a problem"; SYNC_STATE=incomplete; }
else
  warn_ "PowerShell 7 (pwsh) not found - skipping the entitlement sync"
  note_ "install pwsh, or run this after adding members:"
  note_ "  pwsh -File scripts/Sync-ClaudeAccess.ps1 -ApimName $APIM_NAME -ResourceGroup $RESOURCE_GROUP"
fi
ckpt_set_step_ sync "$SYNC_STATE"
fi

# ------------------------------------------------------------------ package

if steps_selected_ onboarding-package; then
step_ "Onboarding package"
ckpt_set_step_ onboarding-package started
PKG="$HERE/onboarding"
mkdir -p "$PKG"
CONFIG_PATH="$PKG/claude-gateway.json"
# Each Claude deployment with the model behind it: the workstation setups pin Claude Code by model
# and declare its capabilities (ADR-0031). A deployment may be named anything.
DEPLOYMENTS_JSON="$(az cognitiveservices account deployment list -g "$FOUNDRY_RG" -n "$FOUNDRY_ACCOUNT" -o json 2>/dev/null \
  | jq '[ .[] | select((.properties.model.format // "") == "Anthropic" or ((.properties.model.name // "") | test("claude")))
          | {name: .name, model: .properties.model.name, version: (.properties.model.version // "")} ]' 2>/dev/null || true)"
[ -z "$DEPLOYMENTS_JSON" ] && DEPLOYMENTS_JSON="[]"
jq -n \
  --arg url "$GATEWAY_URL" --arg tenant "$TENANT_ID" --arg apim "$APIM_NAME" \
  --arg rg "$RESOURCE_GROUP" --arg sg "$STANDARD_GROUP" --arg pg "$PREMIUM_GROUP" \
  --arg sku "$SKU" --arg loc "$LOCATION" --arg fa "$FOUNDRY_ACCOUNT" --arg frg "$FOUNDRY_RG" \
  --argjson tpms "$TPM_STANDARD" --argjson qs "$QUOTA_STANDARD" \
  --argjson tpmp "$TPM_PREMIUM"  --argjson qp "$QUOTA_PREMIUM" \
  --argjson rpm "$CALLS_PER_MINUTE" \
  --argjson deps "$DEPLOYMENTS_JSON" \
  --arg gen "$(date '+%Y-%m-%d %H:%M')" '{
    mode: "gateway",
    gatewayUrl:$url, tenantId:$tenant, apimName:$apim, resourceGroup:$rg,
    sku:$sku, location:$loc, foundryAccount:$fa, foundryResourceGroup:$frg,
    standardGroup:$sg, premiumGroup:$pg,
    deployments: $deps, models: [ $deps[].name ],
    tiers: { standard:{tokensPerMinute:$tpms, tokensPerDay:$qs},
             premium: {tokensPerMinute:$tpmp, tokensPerDay:$qp} },
    requestsPerMinute:$rpm,
    generated:$gen }' > "$CONFIG_PATH"
ok_ "config: $CONFIG_PATH"
ckpt_set_step_ onboarding-package completed __keep__ "$(jq -cn --arg p "$CONFIG_PATH" '{path: $p}' | tr -d '\r')"
fi
ckpt_close_
# A run with --steps ran what it was asked to; the next steps belong to a whole install.
[ -z "$STEPS" ] || exit 0

# --------------------------------------------------------------------- next

head_ "Done"
echo
printf '  %sGateway   %s%s\n' "$C_GREEN" "$GATEWAY_URL" "$C_OFF"
printf '  %sTenant    %s%s\n' "$C_GREEN" "$TENANT_ID" "$C_OFF"
echo
printf '  %sNext:%s\n\n' "$C_WHITE" "$C_OFF"
echo "   1. Entitle a developer"
echo "        az ad group member add --group $STANDARD_GROUP --member-id <object-id>"
echo "        pwsh -File scripts/Sync-ClaudeAccess.ps1 -ApimName $APIM_NAME -ResourceGroup $RESOURCE_GROUP"
echo "      Portal route: docs/ONBOARDING.md section 2"
echo
echo "   2. Send them the setup"
echo "        scripts/setup-claude-workstation.sh --config $CONFIG_PATH"
echo
printf '   %s3. Close the direct-access bypass - see docs/SETUP.md section 4.1%s\n' "$C_YELLOW" "$C_OFF"
echo "      Anyone holding Cognitive Services User on the Foundry account"
echo "      can skip the gateway entirely and ignore these budgets."
echo

# Run on its own in a terminal, the installer ends by offering the FinOps tool, which lists each
# tool with its monthly price in the gateway's region (ADR-0032). It is a PowerShell script. The
# guided flow and scripts pass --skip-finops-offer; --choose-finops opens it without asking.
FINOPS_LATER="pwsh -File scripts/Select-ClaudeFinOpsTooling.ps1 -Region $LOCATION"
HAVE_PWSH=0; command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=1
OFFER_FINOPS=0
if [ "$CHOOSE_FINOPS" != "1" ] && [ "$SKIP_FINOPS_OFFER" != "1" ] && [ "$ASSUME_YES" != "1" ] && [ "$HAVE_PWSH" = "1" ] && interactive_; then
  OFFER_FINOPS=1
fi
if [ "$CHOOSE_FINOPS" != "1" ] && [ "$SKIP_FINOPS_OFFER" != "1" ] && [ "$OFFER_FINOPS" != "1" ]; then
  if [ "$HAVE_PWSH" = "1" ]; then echo "   4. Choose optional FinOps tooling: $FINOPS_LATER"
  else echo "   4. Choose optional FinOps tooling (needs PowerShell 7): $FINOPS_LATER"; fi
  echo
fi
if [ "$CHOOSE_FINOPS" = "1" ] || { [ "$OFFER_FINOPS" = "1" ] && ask_yn_ "Set up a FinOps tool now? It lists each tool with its monthly price in $LOCATION" "y"; }; then
  if [ "$HAVE_PWSH" = "1" ]; then
    pwsh -NoProfile -File "$HERE/scripts/Select-ClaudeFinOpsTooling.ps1" -Region "$LOCATION" -SubscriptionId "$SUBSCRIPTION" || warn_ "the FinOps tool setup reported a problem"
  else
    warn_ "PowerShell 7 (pwsh) is needed for the FinOps tool setup"
    note_ "Later: $FINOPS_LATER"
  fi
elif [ "$OFFER_FINOPS" = "1" ]; then
  note_ "Later: $FINOPS_LATER"
fi

