#!/usr/bin/env bash
# Read-only workstation diagnostics for macOS/Linux.
set -uo pipefail

GATEWAY_URL=""
TENANT_ID=""
NO_REQUEST=0
SUPPORT_BUNDLE=""

while [ $# -gt 0 ]; do
  case "$1" in
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

if command -v claude >/dev/null 2>&1; then
  check_ PASS "Claude Code installed" "$(claude --version 2>/dev/null | head -1) at $(command -v claude)" "No fix needed."
else
  check_ FAIL "Claude Code installed" "claude not found" "Install Claude Code and reopen the terminal."
fi

settings="${HOME}/.claude/settings.json"
if [ -f "$settings" ]; then
  check_ PASS "User Claude Code settings" "$settings present" "Check that CLAUDE_CODE_USE_FOUNDRY=1 and ANTHROPIC_FOUNDRY_BASE_URL point at the gateway."
else
  check_ WARN "User Claude Code settings" "$settings not found" "./scripts/setup-claude-workstation.sh --config ./claude-gateway.json --skip-install"
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

if [ -f "${HOME}/Library/Application Support/Claude/claude_desktop_config.json" ] || [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/Claude/claude_desktop_config.json" ]; then
  check_ PASS "Claude Desktop third-party configuration" "Desktop config file present" "Confirm Settings > Connection names the gateway."
else
  check_ WARN "Claude Desktop third-party configuration" "Desktop config not found" "Run setup or deploy managed Desktop configuration."
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
