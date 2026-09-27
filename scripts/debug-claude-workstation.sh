#!/usr/bin/env bash
# Read-only workstation diagnostics for macOS/Linux.
set -uo pipefail

GATEWAY_URL=""
TENANT_ID=""
NO_REQUEST=0
SUPPORT_BUNDLE=""
CONFIG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --gateway-url) GATEWAY_URL="${2:-}"; shift 2 ;;
    --tenant-id) TENANT_ID="${2:-}"; shift 2 ;;
    --no-request|--no-request) NO_REQUEST=1; shift ;;
    --support-bundle) SUPPORT_BUNDLE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '1,80p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

FAILS=0
WARNS=0
RESULTS=""

mask_() {
  sed -E \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<redacted-email>/g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<redacted-guid>/g' \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/<redacted-jwt>/g' \
    -e 's/sk-[A-Za-z0-9_-]{12,}/<redacted-token>/g'
}

check_() {
  local status="$1" name="$2" evidence="$3" fix="$4"
  [ "$status" = "FAIL" ] && FAILS=$((FAILS+1))
  [ "$status" = "WARN" ] && WARNS=$((WARNS+1))
  printf '  %-4s %s\n' "$status" "$name"
  printf '       Evidence: %s\n' "$evidence" | mask_
  printf '       Fix: %s\n' "$fix"
  RESULTS="${RESULTS}{\"name\":\"$name\",\"status\":\"$status\",\"evidence\":\"$(printf '%s' "$evidence" | mask_ | tr '\n' ' ')\",\"fix\":\"$fix\"}"$'\n'
}

# ADR-0031: the model rules and the bounded client command live in one file, shared with
# setup-claude-workstation.sh. It must sit beside this script.
CLIENT_SUPPORT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-client-support.sh"
if [ ! -f "$CLIENT_SUPPORT" ]; then
  echo "claude-client-support.sh must be in the same folder as this script ($(dirname "${BASH_SOURCE[0]}"))." >&2
  echo "Fetch the whole scripts folder, not this file alone." >&2
  exit 1
fi
. "$CLIENT_SUPPORT"
CONFIG_RAW=""
if [ -n "$CONFIG" ] && [ -f "$CONFIG" ]; then CONFIG_RAW="$(cat "$CONFIG" 2>/dev/null || true)"; fi
if [ -n "$CONFIG_RAW" ] && command -v jq >/dev/null 2>&1; then
  [ -z "$GATEWAY_URL" ] && GATEWAY_URL="$(printf '%s' "$CONFIG_RAW" | jq_value_ '.gatewayUrl // empty' 2>/dev/null)"
  [ -z "$TENANT_ID" ] && TENANT_ID="$(printf '%s' "$CONFIG_RAW" | jq_value_ '.tenantId // empty' 2>/dev/null)"
fi

echo
echo "Claude workstation diagnostics"
echo

if command -v az >/dev/null 2>&1; then
  check_ PASS "Azure CLI installed" "$(command -v az)" "No fix needed."
  acct="$(az account show -o json 2>/dev/null || true)"
  if [ -n "$acct" ]; then
    tenant="$(printf '%s' "$acct" | grep -oE '"tenantId"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"/\1/')"
    if [ -n "$TENANT_ID" ] && [ "$tenant" != "$TENANT_ID" ]; then
      check_ FAIL "Azure sign-in and tenant" "tenant $tenant" "az login --tenant $TENANT_ID --allow-no-subscriptions"
    else
      check_ PASS "Azure sign-in and tenant" "tenant $tenant" "No fix needed."
    fi
    if az account get-access-token --resource https://cognitiveservices.azure.com -o json >/dev/null 2>&1; then
      check_ PASS "Cognitive Services token" "token obtained; value not printed" "No fix needed."
    else
      check_ FAIL "Cognitive Services token" "token was not obtainable" "az login --tenant $TENANT_ID --allow-no-subscriptions"
    fi
  else
    check_ FAIL "Azure sign-in and tenant" "az account show returned no account" "az login --tenant $TENANT_ID --allow-no-subscriptions"
  fi
else
  check_ FAIL "Azure CLI installed" "az not found" "Install Azure CLI from the approved package channel."
fi

cc_version=""
if command -v claude >/dev/null 2>&1; then
  cc_version="$(run_bounded_ 30 claude --version </dev/null 2>/dev/null | head -1)"
  if [ -n "$cc_version" ]; then
    check_ PASS "Claude Code installed" "$cc_version at $(command -v claude)" "No fix needed."
  else
    check_ FAIL "Claude Code installed" "claude --version gave no answer within 30 s at $(command -v claude)" "Reinstall Claude Code from the approved channel, then reopen the terminal."
  fi
else
  check_ FAIL "Claude Code installed" "claude not found" "Install Claude Code and reopen the terminal."
fi

settings="${HOME}/.claude/settings.json"
if [ -f "$settings" ]; then
  check_ PASS "User Claude Code settings" "$settings present" "Check that CLAUDE_CODE_USE_FOUNDRY=1 and ANTHROPIC_FOUNDRY_BASE_URL point at the gateway."
else
  check_ WARN "User Claude Code settings" "$settings not found" "./scripts/setup-claude-workstation.sh --config ./claude-gateway.json --skip-install"
fi

# Claude Code sends thinking.type.enabled to a model it does not know, and the 5-series models
# refuse it with a 400. Each pinned alias is judged by alias_check_ (claude-client-support.sh),
# on what each Claude Code release was measured to send.
if [ -n "$cc_version" ] && [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
  cc_have="$(printf '%s' "$cc_version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  deployments=""
  [ -n "$CONFIG_RAW" ] && deployments="$(printf '%s' "$CONFIG_RAW" | jq_value_ '(.deployments // [])[] | .name // empty' 2>/dev/null)"
  [ -z "$deployments" ] && deployments="$(jq_value_ '(.env // {}) | [.ANTHROPIC_DEFAULT_OPUS_MODEL, .ANTHROPIC_DEFAULT_SONNET_MODEL, .ANTHROPIC_DEFAULT_HAIKU_MODEL][] | strings' "$settings" 2>/dev/null | sort -u)"
  need=""; need_model=""
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    n="$(deployment_min_claude_code_ "$d")"
    if [ -n "$n" ] && { [ -z "$need" ] || ! version_at_least_ "$need" "$n"; }; then need="$n"; need_model="$(model_of_ "$d")"; fi
  done <<EOF
$deployments
EOF
  pinned_known=""; fails=""; warns=""
  for alias in OPUS SONNET HAIKU; do
    pinned="$(jq_value_ --arg k "ANTHROPIC_DEFAULT_${alias}_MODEL" '(.env // {})[$k] // empty' "$settings" 2>/dev/null)"
    [ -z "$pinned" ] && continue
    var="ANTHROPIC_DEFAULT_${alias}_MODEL_SUPPORTED_CAPABILITIES"
    declared="$(jq_value_ --arg k "$var" '(.env // {})[$k] // empty' "$settings" 2>/dev/null)"
    [ -n "$(deployment_caps_ "$pinned")" ] && pinned_known="${pinned_known:+$pinned_known, }$alias"
    verdict="$(alias_check_ "$var" "$pinned" "$declared" "$cc_have")"
    case "${verdict%%|*}" in
      fail) fails="${fails:+$fails; }${verdict#*|}" ;;
      warn) warns="${warns:+$warns; }${verdict#*|}" ;;
    esac
  done
  behind=0
  if [ -n "$need" ] && { [ -z "$cc_have" ] || ! version_at_least_ "$cc_have" "$need"; }; then behind=1; fi
  models_fix="./scripts/setup-claude-workstation.sh --config ./claude-gateway.json writes the declarations and runs claude update."
  if [ -n "$fails" ]; then
    check_ FAIL "Claude Code and the recorded models" "${fails}${warns:+; $warns}." "$models_fix"
  elif [ "$behind" = "1" ] && [ -z "$pinned_known" ]; then
    check_ FAIL "Claude Code and the recorded models" "Claude Code $cc_have predates $need, the first release that knows $need_model, and settings.json pins no model it could declare capabilities for. Requests fail with 400 thinking.type.enabled is not supported." "$models_fix"
  elif [ -n "$warns" ]; then
    check_ WARN "Claude Code and the recorded models" "${warns}." "$models_fix"
  elif [ "$behind" = "1" ]; then
    check_ WARN "Claude Code and the recorded models" "Claude Code $cc_have predates $need, the first release that knows $need_model; its requests work through the capability declarations in settings.json for $pinned_known." "claude update"
  elif [ -n "$need" ]; then
    check_ PASS "Claude Code and the recorded models" "Claude Code $cc_have knows $need_model (from $need)." "No fix needed."
  elif [ -n "$pinned_known" ]; then
    check_ PASS "Claude Code and the recorded models" "settings.json declares the capabilities of every pinned model ($pinned_known)." "No fix needed."
  fi
fi

sources=()
[ -f "/Library/Application Support/ClaudeCode/managed-settings.json" ] && sources+=("managed-file")
[ -f "/etc/claude-code/managed-settings.json" ] && sources+=("etc-file")
if [ "${#sources[@]}" -gt 0 ]; then
  check_ PASS "Managed settings precedence" "Sources: ${sources[*]}; managed/file source wins over user settings where supported" "Remove stale lower-precedence settings."
else
  check_ WARN "Managed settings precedence" "No macOS/Linux managed settings source found" "Deploy a mobileconfig or managed-settings.json if this is a managed device."
fi

if [ -n "${ANTHROPIC_FOUNDRY_BASE_URL:-}" ] && [ -n "${ANTHROPIC_FOUNDRY_RESOURCE:-}" ]; then
  check_ FAIL "Configuration conflicts" "base URL and resource are both set" "Keep only ANTHROPIC_FOUNDRY_BASE_URL for the gateway."
else
  check_ PASS "Configuration conflicts" "No mutually exclusive gateway variables found" "No fix needed."
fi

if command -v code >/dev/null 2>&1; then
  if code --list-extensions 2>/dev/null | grep -qi '^anthropic\.claude-code$'; then
    check_ PASS "VS Code and Claude extension" "VS Code and anthropic.claude-code present" "No fix needed."
  else
    check_ WARN "VS Code and Claude extension" "VS Code present; extension not found" "code --install-extension anthropic.claude-code"
  fi
else
  check_ WARN "VS Code and Claude extension" "code not found" "Install VS Code if needed."
fi

case "$(uname -s)" in
  Darwin) desktop_3p="$HOME/Library/Application Support/Claude-3p"; desktop_app="/Applications/Claude.app" ;;
  *)      desktop_3p="${XDG_CONFIG_HOME:-$HOME/.config}/Claude-3p"; desktop_app="" ;;
esac
desktop_version=""
if [ -n "$desktop_app" ] && [ -f "$desktop_app/Contents/Info.plist" ] && command -v defaults >/dev/null 2>&1; then
  desktop_version="$(defaults read "$desktop_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
fi
desktop_profile=""
if [ -f "$desktop_3p/configLibrary/_meta.json" ] && command -v jq >/dev/null 2>&1; then
  applied="$(jq_value_ '.appliedId // empty' "$desktop_3p/configLibrary/_meta.json" 2>/dev/null)"
  [ -n "$applied" ] && desktop_profile="$desktop_3p/configLibrary/$applied.json"
fi
if [ -n "$desktop_profile" ] && [ -f "$desktop_profile" ]; then
  kind="$(jq_value_ '.inferenceCredentialKind // empty' "$desktop_profile" 2>/dev/null)"
  current_keys="$(jq_value_ '(has("inferenceIdpOidc") or has("inferenceIdpAuthFlow"))' "$desktop_profile" 2>/dev/null)"
  base="$(jq_value_ '.inferenceGatewayBaseUrl // empty' "$desktop_profile" 2>/dev/null)"
  helper="$(jq_value_ '.inferenceCredentialHelper // empty' "$desktop_profile" 2>/dev/null)"
  evidence="kind ${kind:-none}; gateway ${base:-none}; Desktop ${desktop_version:-release unknown}; profile $desktop_profile"
  if [ -z "$kind" ]; then
    check_ FAIL "Claude Desktop sign-in configuration" "$evidence" "Re-run setup, which writes the credential kind."
  elif { [ "$kind" = "external-idp" ] || [ "$current_keys" = "true" ]; } && [ -n "$desktop_version" ] && ! version_at_least_ "$desktop_version" "2.7032.0"; then
    check_ FAIL "Claude Desktop sign-in configuration" "$evidence. external-idp, inferenceIdpOidc and inferenceIdpAuthFlow need Desktop 2.7032.0." "Re-run setup, which writes the spelling this Desktop reads, or update Desktop."
  elif [ "$kind" = "helper-script" ] && { [ -z "$helper" ] || [ ! -f "$helper" ]; }; then
    check_ FAIL "Claude Desktop sign-in configuration" "$evidence. The credential helper ${helper:-(none named)} does not exist." "Re-run setup, which installs the helper."
  elif [ -n "$GATEWAY_URL" ] && [ -n "$base" ] && [ "${base%/}" != "${GATEWAY_URL%/}" ]; then
    check_ WARN "Claude Desktop sign-in configuration" "$evidence. The profile names a different gateway than $GATEWAY_URL." "Re-run setup with the current claude-gateway.json."
  else
    check_ PASS "Claude Desktop sign-in configuration" "$evidence" "Confirm Settings > Connection names the gateway."
  fi
else
  check_ WARN "Claude Desktop sign-in configuration" "No third-party profile under $desktop_3p/configLibrary" "Run setup or deploy managed Desktop configuration."
fi

if [ -n "$GATEWAY_URL" ]; then
  host="$(printf '%s' "$GATEWAY_URL" | sed -E 's#^https?://([^/]+)/?.*#\1#')"
  if command -v getent >/dev/null 2>&1 && getent hosts "$host" >/dev/null 2>&1; then
    check_ PASS "Network path to gateway" "DNS resolves $host; proxy=${HTTPS_PROXY:-${https_proxy:-none}}; NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-}" "No fix needed."
  elif command -v dig >/dev/null 2>&1 && dig +short "$host" >/dev/null 2>&1; then
    check_ PASS "Network path to gateway" "DNS resolves $host; proxy=${HTTPS_PROXY:-${https_proxy:-none}}; NODE_EXTRA_CA_CERTS=${NODE_EXTRA_CA_CERTS:-}" "No fix needed."
  else
    check_ WARN "Network path to gateway" "DNS could not be proven for $host" "Fix DNS/proxy/custom CA; see docs/NETWORK.md."
  fi
  if [ "$NO_REQUEST" = "1" ]; then
    check_ SKIP "Gateway real request" "--no-request was supplied" "Rerun without --no-request to send one small request."
  else
    check_ WARN "Gateway real request" "Not sent by the shell diagnostics without an access token wrapper" "Run Debug-ClaudeCode.ps1 or setup's verification path."
  fi
else
  check_ SKIP "Network path to gateway" "Gateway URL not supplied" "Pass --gateway-url."
fi

if [ -n "$SUPPORT_BUNDLE" ]; then
  tmp="$(mktemp -d)"
  printf '{"generatedUtc":"%s","redaction":"emails, GUIDs and token-like strings masked"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/manifest.json"
  printf '%s\n' "$RESULTS" | mask_ > "$tmp/results.json"
  (cd "$tmp" && zip -q -r "$SUPPORT_BUNDLE" .)
  rm -rf "$tmp"
fi

[ "$FAILS" -gt 0 ] && exit 1
exit 0
