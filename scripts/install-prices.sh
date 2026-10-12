# API Management prices for the region and tier prompts and the summary of install-claude-gateway.sh,
# moved here unchanged from the installer (P75, ADR-0032). Sourced by the installer after its output
# helpers. Bash 3.2 and later, with jq and curl; no GNU-only flags.

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
