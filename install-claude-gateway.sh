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
FOUNDRY_LOCATION=""; CKPT_SEEN=""

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
bad_()  { printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"; }
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

# ------------------------------------------------------------------ prices
#
# API Management is the bulk of the gateway's cost, and the region and tier each change it, so
# both prompts and the summary show it (ADR-0032), as Install-ClaudeGateway.ps1 does. One Azure
# Retail Prices API call returns the three v2 unit meters in every region: 182 rows on one page
# in 0.6 s, measured 2026-09-28. These are list prices; the agreement's price sheet states what
# the organization pays (docs/UNKNOWNS.md U31).
PRICES_READ=""; PRICES_JSON="{}"; PRICES_CURRENCY="USD"; PRICES_UNREACHABLE=""

# Read once. A failure is kept, so the tier prompt and the summary do not ask again.
apim_prices_() {
  [ -n "$PRICES_READ" ] && return 0
  PRICES_READ="$(date -u '+%Y-%m-%d %H:%M') UTC"
  local filter url body pages="" page=0
  filter="serviceName eq 'API Management' and priceType eq 'Consumption' and (meterName eq 'Basic v2 Unit' or meterName eq 'Standard v2 Unit' or meterName eq 'Premium v2 Unit')"
  url="https://prices.azure.com/api/retail/prices?\$filter=$(jq -rn --arg f "$filter" '$f | @uri')"
  while [ -n "$url" ] && [ "$page" -lt 20 ]; do
    if ! body="$(curl -fsS --proto '=https' --max-time 30 "$url" 2>&1)"; then
      PRICES_UNREACHABLE="$(printf '%s\n' "$body" | head -n 1)"
      [ -z "$PRICES_UNREACHABLE" ] && PRICES_UNREACHABLE="curl failed without a message"
      return 1
    fi
    if ! printf '%s' "$body" | jq -e '.Items | type == "array"' >/dev/null 2>&1; then
      PRICES_UNREACHABLE="the response was not a price list"
      return 1
    fi
    pages="$pages$body"$'\n'
    url="$(printf '%s' "$body" | jq -r '.NextPageLink // empty')"
    # The API names its next page https://prices.azure.com:443/api/retail/prices?...&$skip=1000
    # (read 2026-09-28). A link anywhere else is not followed.
    case "$url" in
      ''|https://prices.azure.com/*|https://prices.azure.com:443/*) ;;
      *) PRICES_UNREACHABLE="the next page of the price list is not on https://prices.azure.com"; return 1 ;;
    esac
    page=$((page + 1))
  done
  # Through standard input: all pages are about 100 KB, over the 32,767 characters a Windows
  # command line holds. Consumption rows only, free tiers dropped, the marginal row of a tiered
  # meter, as Get-AzureRetailPriceAcrossRegions does. One unit at 730 hours to the cent as
  # ConvertTo-MonthlyPrice computes it on PowerShell 7: ConvertFrom-Json reads the price as a
  # double, [decimal] converts the double as .NET's VarDecFromR8 does (scaled by a power of ten in
  # double arithmetic, then rounded half to even to at most 15 significant digits), and
  # [math]::Round rounds the product half to even. The same steps run here, in double arithmetic
  # and on digit strings, so 0.2005 an hour is 146.36 a month in both installers, and the cent does
  # not depend on the price's size, its trailing zeros or an exponent. Windows PowerShell 5.1 reads
  # a price written without an exponent as an exact decimal, so for a price with more than 15
  # significant digits the two PowerShell hosts can differ by a cent; this installer gives
  # PowerShell 7's cent. jq 1.7.0 converts a number through a 16-digit decimal, so a price written
  # with 17 significant digits can differ by a cent (the preflight warns); jq 1.7.1 and later round
  # a price written with more than 17 significant digits to 17 before converting it. The API writes
  # API Management v2 prices with at most 7 significant digits (measured 2026-09-28).
  local transformed
  if ! transformed="$(printf '%s' "$pages" | jq -cs '
    def digits_num: explode | reduce .[] as $c (0; . * 10 + $c - 48);
    def zeros($n): [range(0; $n)] | map("0") | join("");
    def odd_digit: (explode[0] - 48) % 2 == 1;
    def pow10($n): "1e\($n)" | tonumber;
    def times73: explode | reverse
      | reduce .[] as $c ({out: [], carry: 0}; (($c - 48) * 73 + .carry) as $v | .out += [($v % 10) + 48] | .carry = (($v - ($v % 10)) / 10))
      | (.out + (.carry | if . > 0 then (tostring | explode | reverse) else [] end)) | reverse | implode;
    # frexp exponent e of a positive double, 2^(e-1) <= x < 2^e, by exact halving and doubling
    # (jq 1.5 has no frexp).
    def exponent2:
      {x: ., e: 0}
      | until(.x < 1; .x = .x / 2 | .e = .e + 1)
      | until(.x >= 0.5; .x = .x * 2 | .e = .e - 1)
      | .e;
    # VarDecFromR8 for a positive double: {d: the integer digits, s: the scale}, value d / 10^s.
    def dec15:
      exponent2 as $exp
      | if $exp < -94 then {d: "0", s: 0} else
          (14 - (($exp * 19728) / 65536 | floor)) as $p0
          | (if $p0 >= 0 then ([$p0, 28] | min) as $p | {v: (. * pow10($p)), p: $p}
             elif $p0 != -1 or . >= 1e15 then {v: (. / pow10(-$p0)), p: $p0}
             else {v: ., p: 0} end)
          | (if .v < 1e14 and .p < 28 then {v: (.v * 10), p: (.p + 1)} else . end)
          | (.v | floor) as $t | (.v - $t) as $fr
          | {d: ((if $fr > 0.5 or ($fr == 0.5 and (($t / 2 | floor) * 2 != $t)) then $t + 1 else $t end) | tostring), s: .p}
        end;
    def monthly:
      (. + 0) as $x
      | if $x == 0 then 0 else
          ($x | if . < 0 then -. else . end | dec15) as $q
          | ($q.d | times73) as $p
          | (3 - $q.s) as $shift
          | (if $shift >= 0 then ($p + zeros($shift) | digits_num)
             else (-$shift) as $l
               | (zeros($l + 1 - ($p | length)) + $p) as $pp
               | ($pp | length) as $n
               | ($pp[0:($n - $l)] | digits_num) as $c
               | $pp[($n - $l):] as $frac
               | if $frac[0:1] > "5" or ($frac[0:1] == "5" and (($frac[1:] | test("[1-9]")) or ($pp[($n - $l - 1):($n - $l)] | odd_digit))) then $c + 1 else $c end
             end) as $cents
          | (if $x < 0 then -$cents else $cents end) / 100
        end;
    [ .[].Items[] | select(.type == "Consumption" and .retailPrice != null
        and ((.skuName // "") | test("free"; "i") | not) and ((.productName // "") | test("free"; "i") | not)) ]
    | if any(.[]; (.retailPrice | type) != "number") then error("a retailPrice is not a number") else . end
    | group_by((.armRegionName // "") + "|" + (.meterName // "")) | map(max_by(.tierMinimumUnits // 0))
    | reduce .[] as $r ({};
        ({"Basic v2 Unit": "BasicV2", "Standard v2 Unit": "StandardV2", "Premium v2 Unit": "PremiumV2"}[$r.meterName // ""]) as $t
        | if $t and $r.armRegionName then .[$r.armRegionName][$t] = ($r.retailPrice | monthly) else . end)' 2>&1)"; then
    PRICES_UNREACHABLE="the price list is not in the expected form: $(printf '%s\n' "$transformed" | head -n 1)"
    return 1
  fi
  PRICES_JSON="$transformed"
  [ -z "$PRICES_JSON" ] && PRICES_JSON="{}"
  PRICES_CURRENCY="$(printf '%s' "$pages" | jq -rs '[ .[].Items[].currencyCode | select(. != null and . != "") ][0] // "USD"')"
  return 0
}

# The monthly list price of one tier in one region, or nothing where none is published.
price_() { printf '%s' "$PRICES_JSON" | jq -r --arg r "$1" --arg t "$2" '.[$r][$t] // empty'; }

# USD 2,800.00, or USD 2,800 with no decimals, as the PowerShell installer prints amounts.
money_() {
  local amount="$1" decimals="${2:-2}"
  if [ -z "$amount" ] || [ "$amount" = "null" ]; then printf 'not published'; return; fi
  LC_ALL=C awk -v v="$amount" -v d="$decimals" -v c="$PRICES_CURRENCY" 'BEGIN {
    if (d == 0) { s = sprintf("%d", int(v + 0.5)); frac = "" }
    else { s = sprintf("%.2f", v); n = index(s, "."); frac = substr(s, n); s = substr(s, 1, n - 1) }
    out = ""
    while (length(s) > 3) { out = "," substr(s, length(s) - 2) out; s = substr(s, 1, length(s) - 3) }
    printf "%s %s%s%s", c, s, out, frac
  }'
}

# Numbered options, one per line: number, region, then the Basic, Standard and Premium v2 monthly
# price, or null where none is published: read with a tab IFS joins empty fields, which moved the
# next price into the empty column. The default region first, then the other physical regions in
# its geography group that publish a v2 price, cheapest Basic v2 first
# (scripts/ClaudeGatewayRegion.ps1). An entry that is not a region object is skipped, as
# Read-GatewayRegion skips it. jq.exe on Windows ends each line with CRLF: Git Bash's command
# substitution drops the last line's carriage return, but read keeps the others' in the last field.
region_options_() {
  local default="$1" locations="$2"
  [ -z "$PRICES_UNREACHABLE" ] || return 0
  printf '%s\n%s' "$PRICES_JSON" "$locations" | jq -rs --arg d "$default" '
    .[0] as $p
    | [ .[1][] | objects | select((.name | type) == "string" and (.metadata | type) == "object" and (.metadata.regionType // "") == "Physical") ] as $phys
    | ([ $phys[] | select(.name == $d) ][0].metadata.geographyGroup // "") as $g
    | ([ $d ] + ([ $phys[] | select($g != "" and .name != $d and (.metadata.geographyGroup // "") == $g and $p[.name] != null) | .name ]
          | sort_by([ ($p[.].BasicV2 // 1e18), . ])))
    | to_entries[]
    | [ (.key + 1), .value, ($p[.value].BasicV2 // "null"), ($p[.value].StandardV2 // "null"), ($p[.value].PremiumV2 // "null") ] | @tsv' 2>/dev/null | tr -d '\r'
}

# The region an answer names: a number from the options, or a region name in any case or spacing
# that is among the options or the subscription's physical regions. Nothing otherwise.
resolve_region_() {
  local answer="$1" options="$2" known="$3" text
  text="$(arm_region_ "$answer")"
  [ -z "$text" ] && return 0
  case "$text" in
    *[!0-9]*) ;;
    *) printf '%s\n' "$options" | awk -F '\t' -v n="$text" '$1 == n { print $2; exit }'; return 0 ;;
  esac
  if printf '%s\n' "$options" | awk -F '\t' -v r="$text" '$2 == r { f = 1 } END { exit !f }'; then printf '%s' "$text"; return 0; fi
  if printf '%s\n' "$known" | grep -qxF -- "$text"; then printf '%s' "$text"; fi
}

# The region, priced. Sets LOCATION to the region chosen, in its ARM name.
read_gateway_region_() {
  local default="$1" locations options known answer resolved tries=0 started=$SECONDS
  local n region b s p label
  note_ "Reading the regions this subscription can use and the API Management v2 list prices there (about 6 s)..."
  locations="$(az account list-locations -o json 2>/dev/null)" || locations="[]"
  printf '%s' "$locations" | jq -e 'type == "array"' >/dev/null 2>&1 || locations="[]"
  apim_prices_ || true
  note_ "read in $((SECONDS - started)) s"
  known="$(printf '%s' "$locations" | jq -r '.[] | objects | select((.name | type) == "string" and (.metadata | type) == "object" and (.metadata.regionType // "") == "Physical") | .name')"
  options="$(region_options_ "$default" "$locations")"
  if [ -n "$options" ]; then
    echo
    printf '    %sAPI Management v2 monthly list price, one unit at 730 hours, from the Azure Retail Prices API, read %s:%s\n' "$C_GREY" "$PRICES_READ" "$C_OFF"
    echo
    printf '    %s      %-30s %-15s %-15s %s%s\n' "$C_GREY" "Region" "Basic v2" "Standard v2" "Premium v2" "$C_OFF"
    while IFS=$'\t' read -r n region b s p; do
      [ -z "$n" ] && continue
      label="$region"
      [ -n "$FOUNDRY_LOCATION" ] && [ "$region" = "$FOUNDRY_LOCATION" ] && label="$region (Foundry region)"
      printf '    %s  %2s. %-30s %-15s %-15s %s%s\n' "$C_GREY" "$n" "$label" "$(money_ "$b")" "$(money_ "$s")" "$(money_ "$p")" "$C_OFF"
    done <<EOF
$options
EOF
    echo
    note_ "The Foundry account's region keeps latency down. Another region's name is accepted too."
    note_ "These are list prices. The agreement's price sheet states what the organization pays; reading it"
    note_ "takes a billing role, not a subscription role (docs/UNKNOWNS.md U31)."
    echo
  elif [ -n "$PRICES_UNREACHABLE" ]; then
    warn_ "API Management prices could not be read ($PRICES_UNREACHABLE). The summary prices the choice if it can."
  fi
  while true; do
    answer="$(ask_ "Region (number or name)" "$default")"
    resolved="$(resolve_region_ "$answer" "$options" "$known")"
    if [ -n "$resolved" ]; then LOCATION="$resolved"; return 0; fi
    # Nothing to check against when neither list could be read.
    if [ -z "$options" ] && [ -z "$known" ]; then LOCATION="$(arm_region_ "$answer")"; return 0; fi
    warn_ "'$answer' is not a region this subscription can use. Enter a number from the list or a region name such as $default."
    tries=$((tries + 1))
    if [ "$tries" -ge 10 ]; then bad_ "no region this subscription can use was given"; echo "Stopped before deploying. Nothing was created." >&2; exit 1; fi
  done
}

# Each v2 tier's monthly list price in the chosen region, above the tier prompt.
show_tier_prices_() {
  local region="$1" tier
  apim_prices_ || true
  if [ -n "$PRICES_UNREACHABLE" ]; then note_ "Tier prices could not be read: $PRICES_UNREACHABLE"; return 0; fi
  printf '      %sMonthly list price in %s, one unit at 730 hours (Azure Retail Prices API, read %s):%s\n' "$C_GREY" "$region" "$PRICES_READ" "$C_OFF"
  for tier in BasicV2 StandardV2 PremiumV2; do
    printf '      %s  %-12s %s%s\n' "$C_GREY" "$tier" "$(money_ "$(price_ "$region" "$tier")")" "$C_OFF"
  done
}

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
    -h|--help)          usage_ ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

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
[ -f "$HERE/scripts/install-checkpoint.sh" ] || { echo "scripts/install-checkpoint.sh is missing from this checkout." >&2; exit 1; }
. "$HERE/scripts/install-checkpoint.sh"
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

# ------------------------------------------------------------------ package

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
ckpt_close_

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

