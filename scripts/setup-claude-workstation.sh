#!/usr/bin/env bash
#
# Claude on Microsoft Foundry - workstation setup for macOS and Linux.
#
# Companion to Setup-ClaudeWorkstation.ps1. Same job, same output, no admin
# rights, no API key: checks prerequisites, installs what is missing, then
# configures the Claude Code CLI, the VS Code extension, and Claude Desktop
# including Cowork - and finishes with a real call through the gateway.
#
#   ./setup-claude-workstation.sh --config ./claude-gateway.json
#   ./setup-claude-workstation.sh --gateway-url https://x.azure-api.net/claude \
#                                 --tenant-id 00000000-0000-0000-0000-000000000000
#
# Options:
#   --config PATH|URL     the claude-gateway.json your platform team sent
#   --gateway-url URL     if you are not using a config file
#   --tenant-id GUID
#   --skip-install        configure only, install nothing
#   --skip-desktop        leave Claude Desktop alone
#   --skip-vscode         leave VS Code alone
#   --no-cowork           configure Desktop without the Cowork tab
#   --help
#
# Idempotent - re-run it after a change and it reconciles.

set -uo pipefail

GATEWAY_URL=""
TENANT_ID=""
CONFIG=""
SKIP_INSTALL=0
SKIP_DESKTOP=0
SKIP_VSCODE=0
NO_COWORK=0
MODELS=("claude-sonnet-5" "claude-opus-5")

# ------------------------------------------------------------------- output

if [ -t 1 ]; then
  C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'; C_GREY=$'\033[90m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_BOLD=""; C_OFF=""
fi

head_()  { printf '\n%s%s%s\n' "$C_CYAN" "======================================================================" "$C_OFF"
           printf '%s %s%s\n'  "$C_CYAN" "$1" "$C_OFF"
           printf '%s%s%s\n'   "$C_CYAN" "======================================================================" "$C_OFF"; }
step_()  { printf '\n%s==> %s%s\n' "$C_CYAN" "$1" "$C_OFF"; }
ok_()    { printf '    %s[OK]%s   %s\n' "$C_GREEN" "$C_OFF" "$1"; }
warn_()  { printf '    %s[WARN]%s %s\n' "$C_YELLOW" "$C_OFF" "$1"; }
bad_()   { printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$1"; }
note_()  { printf '    %s%s%s\n' "$C_GREY" "$1" "$C_OFF"; }

PROBLEMS=()
problem_() { PROBLEMS+=("$1"); }

usage_() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --------------------------------------------------------------------- args

while [ $# -gt 0 ]; do
  case "$1" in
    --config)      CONFIG="${2:-}"; shift 2 ;;
    --gateway-url) GATEWAY_URL="${2:-}"; shift 2 ;;
    --tenant-id)   TENANT_ID="${2:-}"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --skip-desktop) SKIP_DESKTOP=1; shift ;;
    --skip-vscode)  SKIP_VSCODE=1; shift ;;
    --no-cowork)    NO_COWORK=1; shift ;;
    -h|--help)      usage_ ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------- platform

OS="$(uname -s)"
case "$OS" in
  Darwin)
    PLATFORM="macos"
    VSCODE_USER_DIR="$HOME/Library/Application Support/Code/User"
    CLAUDE_SUPPORT_DIR="$HOME/Library/Application Support/Claude"
    CLAUDE_3P_DIR="$HOME/Library/Application Support/Claude-3p"
    ;;
  Linux)
    PLATFORM="linux"
    VSCODE_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User"
    CLAUDE_SUPPORT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
    CLAUDE_3P_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Claude-3p"
    ;;
  *) echo "Unsupported platform: $OS. On Windows use Setup-ClaudeWorkstation.ps1." >&2; exit 1 ;;
esac

HELPER_DIR="$HOME/.claude-foundry"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/banner.sh" ]; then
  . "$SCRIPT_DIR/banner.sh"
  claude_banner "Workstation setup - CLI, VS Code and Desktop"
else
  head_ "Claude on Microsoft Foundry - workstation setup"
fi
note_ "platform: $PLATFORM"

# ------------------------------------------------------------------- config

step_ "Configuration"
if [ -n "$CONFIG" ]; then
  if [ -z "$(command -v jq || true)" ]; then
    warn_ "jq not found - cannot read the config file"
    note_ "install jq, or pass --gateway-url and --tenant-id directly"
  else
    raw=""
    if printf '%s' "$CONFIG" | grep -qE '^https?://'; then
      raw="$(curl -fsSL "$CONFIG" 2>/dev/null || true)"
    else
      raw="$(cat "$CONFIG" 2>/dev/null || true)"
    fi
    if [ -n "$raw" ]; then
      [ -z "$GATEWAY_URL" ] && GATEWAY_URL="$(printf '%s' "$raw" | jq -r '.gatewayUrl // empty')"
      [ -z "$TENANT_ID" ]   && TENANT_ID="$(printf '%s' "$raw" | jq -r '.tenantId // empty')"
      ok_ "loaded from $CONFIG"
      tpm="$(printf '%s' "$raw" | jq -r '.tiers.standard.tokensPerMinute // empty')"
      tpd="$(printf '%s' "$raw" | jq -r '.tiers.standard.tokensPerDay // empty')"
      [ -n "$tpm" ] && note_ "standard tier: $tpm tokens/min, $tpd tokens/day"
    else
      warn_ "could not read $CONFIG"
    fi
  fi
fi

if [ -z "$GATEWAY_URL" ]; then
  printf '\n'
  bad_ "No gateway configuration."
  printf '\n'
  printf '  This script needs to know which gateway to point at. That comes from a\n'
  printf '  small file called claude-gateway.json.\n\n'
  printf '  Where to get it:\n'
  printf '    Your platform team generates it when they deploy the gateway, and sends\n'
  printf '    it to you - usually attached to your onboarding email, or on an internal\n'
  printf '    share. It is not in this repository, because it describes your specific\n'
  printf '    deployment.\n\n'
  printf '  Then run:\n'
  printf '    ./setup-claude-workstation.sh --config <path-to-claude-gateway.json>\n\n'
  printf '  Or skip the file and pass the two values directly:\n'
  printf '    ./setup-claude-workstation.sh --gateway-url https://<apim>.azure-api.net/claude \\\n'
  printf '                                  --tenant-id <tenant-id>\n\n'
  printf '  \033[90mIt contains no secret - just the gateway URL, tenant id and tier limits.\033[0m\n'
  printf '  \033[90mAccess comes from your Entra group membership, not from this file.\033[0m\n\n'
  exit 1
fi
GATEWAY_URL="${GATEWAY_URL%/}"
ok_ "gateway: $GATEWAY_URL"
[ -n "$TENANT_ID" ] && note_ "tenant : $TENANT_ID"

# Check the environment before touching anything. The gateway URL is known by
# now, so reachability can be probed too. Warnings only: this script installs
# what is missing, so an absent tool is not a blocker here.
if [ -f "$(dirname "$0")/preflight.sh" ]; then
  . "$(dirname "$0")/preflight.sh"
  claude_preflight workstation "$GATEWAY_URL" || true
fi

# ------------------------------------------------------------- prerequisites

step_ "Prerequisites"

have_() { command -v "$1" >/dev/null 2>&1; }

PKG=""
if [ "$PLATFORM" = "macos" ]; then
  have_ brew && PKG="brew"
else
  if   have_ apt-get; then PKG="apt"
  elif have_ dnf;     then PKG="dnf"
  elif have_ pacman;  then PKG="pacman"
  elif have_ zypper;  then PKG="zypper"
  fi
fi
[ -n "$PKG" ] && note_ "package manager: $PKG" || warn_ "no supported package manager found"

install_pkg_() {
  # $1 brew name, $2 apt name, $3 label
  local brew_name="$1" apt_name="$2" label="$3"
  if [ "$SKIP_INSTALL" = "1" ]; then warn_ "$label missing (skipped)"; return 1; fi
  case "$PKG" in
    brew)   note_ "installing $label ..."; brew install "$brew_name" >/dev/null 2>&1 ;;
    apt)    note_ "installing $label ..."; sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y "$apt_name" >/dev/null 2>&1 ;;
    dnf)    note_ "installing $label ..."; sudo dnf install -y "$apt_name" >/dev/null 2>&1 ;;
    pacman) note_ "installing $label ..."; sudo pacman -S --noconfirm "$apt_name" >/dev/null 2>&1 ;;
    zypper) note_ "installing $label ..."; sudo zypper -n install "$apt_name" >/dev/null 2>&1 ;;
    *) bad_ "$label missing and no package manager available"; return 1 ;;
  esac
}

# jq - needed for config parsing and JSON edits.
if have_ jq; then ok_ "jq"; else
  install_pkg_ jq jq "jq" && { have_ jq && ok_ "jq installed" || { bad_ "jq install failed"; problem_ "jq"; }; } || problem_ "jq"
fi

# Node.js - for the Claude Code CLI.
if have_ node; then ok_ "Node.js  $(node --version 2>/dev/null)"; else
  install_pkg_ node nodejs "Node.js" && { have_ node && ok_ "Node.js installed" || problem_ "Node.js"; } || problem_ "Node.js"
fi

# Azure CLI - the credential source for everything here.
if have_ az; then
  ok_ "Azure CLI  $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo '')"
else
  if [ "$SKIP_INSTALL" = "1" ]; then
    bad_ "Azure CLI missing (skipped)"; problem_ "Azure CLI"
  elif [ "$PKG" = "brew" ]; then
    note_ "installing Azure CLI ..."; brew install azure-cli >/dev/null 2>&1
    have_ az && ok_ "Azure CLI installed" || problem_ "Azure CLI"
  else
    note_ "installing Azure CLI ..."
    curl -sL https://aka.ms/InstallAzureCLIDeb 2>/dev/null | sudo bash >/dev/null 2>&1 || true
    if have_ az; then ok_ "Azure CLI installed"; else
      bad_ "Azure CLI install failed"
      note_ "see https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
      problem_ "Azure CLI"
    fi
  fi
fi

# Claude Code CLI.
if have_ claude; then
  ok_ "Claude Code CLI  $(claude --version 2>/dev/null | head -1)"
elif [ "$SKIP_INSTALL" = "1" ]; then
  warn_ "Claude Code CLI missing (skipped)"
else
  note_ "installing Claude Code CLI ..."
  npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
  if have_ claude; then ok_ "Claude Code CLI installed"; else
    warn_ "npm global install failed - it usually needs a writable prefix"
    note_ "try: npm config set prefix ~/.npm-global && export PATH=~/.npm-global/bin:\$PATH"
    problem_ "Claude Code CLI"
  fi
fi

# ------------------------------------------------------------------ sign-in

step_ "Azure sign-in"
if have_ az; then
  current_tenant="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
  need_login=0
  [ -z "$current_tenant" ] && need_login=1
  if [ -n "$TENANT_ID" ] && [ -n "$current_tenant" ] && [ "$current_tenant" != "$TENANT_ID" ]; then
    warn_ "signed into tenant $current_tenant, need $TENANT_ID"
    need_login=1
  fi
  if [ "$need_login" = "1" ]; then
    note_ "a browser window will open"
    if [ -n "$TENANT_ID" ]; then az login --tenant "$TENANT_ID" -o none; else az login -o none; fi
  fi
  who="$(az account show --query user.name -o tsv 2>/dev/null || true)"
  if [ -n "$who" ]; then
    ok_ "$who"
    note_ "tenant $(az account show --query tenantId -o tsv 2>/dev/null)"
  else
    bad_ "sign-in failed"; problem_ "sign-in"
  fi
else
  bad_ "Azure CLI unavailable - cannot sign in"; problem_ "sign-in"
fi

# -------------------------------------------------------------- Claude Code

step_ "Claude Code CLI configuration"
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"
SETTINGS="$CLAUDE_DIR/settings.json"

SONNET=""; OPUS=""
for m in "${MODELS[@]}"; do
  case "$m" in *sonnet*) SONNET="$m" ;; *opus*) OPUS="$m" ;; esac
done

if have_ jq; then
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  cp "$SETTINGS" "$SETTINGS.bak" 2>/dev/null || true

  models_json="$(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -s .)"

  # ANTHROPIC_FOUNDRY_RESOURCE is mutually exclusive with the base URL, so it is
  # deleted rather than merely not set - a leftover value kills the session with
  # "baseURL and resource are mutually exclusive".
  #
  # The haiku alias points at Sonnet because most tenants have no Haiku
  # deployment, and the failure otherwise surfaces mid-task as
  # DeploymentNotFound.
  tmp="$(mktemp)"
  jq \
    --arg url "$GATEWAY_URL" \
    --arg sonnet "$SONNET" \
    --arg opus "$OPUS" \
    --argjson models "$models_json" '
      .env = (.env // {})
      | .env.CLAUDE_CODE_USE_FOUNDRY = "1"
      | .env.ANTHROPIC_FOUNDRY_BASE_URL = $url
      | (if $opus   != "" then .env.ANTHROPIC_DEFAULT_OPUS_MODEL   = $opus   else . end)
      | (if $sonnet != "" then .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $sonnet else . end)
      | (if $sonnet != "" then .env.ANTHROPIC_DEFAULT_HAIKU_MODEL  = $sonnet else . end)
      | del(.env.ANTHROPIC_FOUNDRY_RESOURCE)
      | .availableModels = $models
      | .enforceAvailableModels = true
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  ok_ "$SETTINGS"
else
  bad_ "jq unavailable - cannot safely edit $SETTINGS"; problem_ "settings"
fi

# ------------------------------------------------------------------ VS Code

if [ "$SKIP_VSCODE" = "0" ]; then
  step_ "VS Code extension"
  if have_ code; then
    if code --list-extensions 2>/dev/null | grep -q '^anthropic.claude-code$'; then
      ok_ "extension present"
    elif [ "$SKIP_INSTALL" = "1" ]; then
      warn_ "extension missing (skipped)"
    else
      note_ "installing anthropic.claude-code ..."
      code --install-extension anthropic.claude-code >/dev/null 2>&1 && ok_ "extension installed" || warn_ "extension install failed"
    fi
  else
    warn_ "'code' command unavailable"
    [ "$PLATFORM" = "macos" ] && note_ "in VS Code: Cmd+Shift+P -> Shell Command: Install 'code' command in PATH"
  fi

  # The extension host does not inherit shell environment, so the same values
  # must be written into VS Code's own settings.
  VS_SETTINGS="$VSCODE_USER_DIR/settings.json"
  if [ -d "$VSCODE_USER_DIR" ] && have_ jq; then
    [ -f "$VS_SETTINGS" ] || echo '{}' > "$VS_SETTINGS"
    cp "$VS_SETTINGS" "$VS_SETTINGS.bak" 2>/dev/null || true

    env_arr="$(jq -n \
      --arg url "$GATEWAY_URL" --arg sonnet "$SONNET" --arg opus "$OPUS" '
      [ {name:"CLAUDE_CODE_USE_FOUNDRY", value:"1"},
        {name:"ANTHROPIC_FOUNDRY_BASE_URL", value:$url} ]
      + (if $opus   != "" then [{name:"ANTHROPIC_DEFAULT_OPUS_MODEL",   value:$opus}]   else [] end)
      + (if $sonnet != "" then [{name:"ANTHROPIC_DEFAULT_SONNET_MODEL", value:$sonnet},
                                {name:"ANTHROPIC_DEFAULT_HAIKU_MODEL",  value:$sonnet}] else [] end)')"

    tmp="$(mktemp)"
    # VS Code settings.json is JSONC; jq needs strict JSON, so comments and
    # trailing commas are stripped first. The backup above is the safety net.
    sed -e 's://[^"]*$::' "$VS_SETTINGS" \
      | jq --argjson ev "$env_arr" '.["claudeCode.environmentVariables"] = $ev' > "$tmp" 2>/dev/null \
      && mv "$tmp" "$VS_SETTINGS" \
      && ok_ "$VS_SETTINGS" \
      || { rm -f "$tmp"; warn_ "could not edit VS Code settings.json - left unchanged"
           note_ "add claudeCode.environmentVariables by hand, or remove comments from the file"; }
    note_ "Reload the VS Code window afterwards, or it keeps the old configuration."
  else
    [ -d "$VSCODE_USER_DIR" ] || warn_ "VS Code user directory not found: $VSCODE_USER_DIR"
  fi
fi

# ----------------------------------------------------------- Claude Desktop

if [ "$SKIP_DESKTOP" = "0" ]; then
  step_ "Claude Desktop"

  desktop_present=0
  if [ "$PLATFORM" = "macos" ]; then
    [ -d "/Applications/Claude.app" ] && desktop_present=1
  else
    have_ claude-desktop && desktop_present=1
    [ -d "/opt/Claude" ] && desktop_present=1
  fi

  if [ "$desktop_present" = "0" ]; then
    if [ "$SKIP_INSTALL" = "1" ]; then
      warn_ "Claude Desktop not found (skipped)"
    elif [ "$PLATFORM" = "macos" ] && [ "$PKG" = "brew" ]; then
      note_ "installing Claude Desktop ..."
      brew install --cask claude >/dev/null 2>&1 && desktop_present=1
      [ "$desktop_present" = "1" ] && ok_ "Claude Desktop installed" || warn_ "install failed - get it from claude.ai/download"
    else
      warn_ "Claude Desktop not found"
      note_ "download from https://claude.ai/download, then re-run this script"
    fi
  else
    ok_ "Claude Desktop present"
  fi

  if [ "$desktop_present" = "1" ] && have_ jq; then
    # Credential helper. Uses the Azure CLI's own pre-consented client, so this
    # needs no app registration and no admin consent.
    mkdir -p "$HELPER_DIR"
    HELPER="$HELPER_DIR/get-foundry-token.sh"
    src_helper="$(dirname "$0")/get-foundry-token.sh"
    if [ -f "$src_helper" ]; then
      cp "$src_helper" "$HELPER"
    else
      cat > "$HELPER" <<'HELPEOF'
#!/usr/bin/env bash
# Prints an Entra bearer token for the Cognitive Services data plane on stdout,
# and nothing else. Claude Desktop reads stdout as the token, so any stray
# output corrupts it - diagnostics go to stderr.
set -uo pipefail
RESOURCE="https://cognitiveservices.azure.com"
ARGS=(account get-access-token --resource "$RESOURCE" --query accessToken -o tsv)
[ -n "${CLAUDE_FOUNDRY_TENANT_ID:-}" ] && ARGS+=(--tenant "$CLAUDE_FOUNDRY_TENANT_ID")
token="$(az "${ARGS[@]}" 2>/dev/null || true)"
if [ -z "$token" ]; then
  # CLAUDE_HELPER_CONTEXT is set by the app; during a silent refresh nobody is
  # watching, so fail fast rather than blocking on an interactive prompt.
  if [ "${CLAUDE_HELPER_CONTEXT:-}" = "refresh" ]; then
    echo "[claude-helper] no cached credential; run: az login" >&2
    exit 2
  fi
  echo "[claude-helper] signing in..." >&2
  if [ -n "${CLAUDE_FOUNDRY_TENANT_ID:-}" ]; then az login --tenant "$CLAUDE_FOUNDRY_TENANT_ID" >/dev/null 2>&1
  else az login >/dev/null 2>&1; fi
  token="$(az "${ARGS[@]}" 2>/dev/null || true)"
fi
case "$token" in
  eyJ*) printf '%s' "$token"; exit 0 ;;
  *)    echo "[claude-helper] could not acquire a token" >&2; exit 1 ;;
esac
HELPEOF
    fi
    chmod +x "$HELPER"
    ok_ "credential helper -> $HELPER"

    # Developer settings reveal Settings -> Connection and create the profile
    # library this writes into.
    mkdir -p "$CLAUDE_SUPPORT_DIR"
    DEV_SETTINGS="$CLAUDE_SUPPORT_DIR/developer_settings.json"
    if [ ! -f "$DEV_SETTINGS" ]; then
      echo '{ "allowDevTools": true }' > "$DEV_SETTINGS"
      ok_ "developer settings enabled"
    else
      ok_ "developer settings already enabled"
    fi

    LIB="$CLAUDE_3P_DIR/configLibrary"
    META="$LIB/_meta.json"
    mkdir -p "$LIB"
    if [ ! -f "$META" ]; then
      pid="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "00000000-0000-0000-0000-000000000001")"
      jq -n --arg id "$pid" '{appliedId:$id, entries:[{id:$id, name:"Default"}]}' > "$META"
      note_ "created the profile library"
    fi

    applied="$(jq -r '.appliedId' "$META")"
    PROFILE="$LIB/$applied.json"
    [ -f "$PROFILE" ] && cp "$PROFILE" "$PROFILE.bak"

    models_json="$(printf '%s\n' "${MODELS[@]}" | jq -R '{name: .}' | jq -s .)"
    cowork_val="true"; [ "$NO_COWORK" = "1" ] && cowork_val="false"

    jq -n \
      --arg url "$GATEWAY_URL" \
      --arg helper "$HELPER" \
      --argjson models "$models_json" \
      --argjson cowork "$cowork_val" '{
        inferenceProvider: "gateway",
        inferenceGatewayBaseUrl: $url,
        inferenceGatewayAuthScheme: "bearer",
        inferenceCredentialKind: "helper-script",
        inferenceCredentialHelper: $helper,
        inferenceCredentialHelperTimeoutSec: 60,
        inferenceCredentialHelperTtlSec: 1800,
        inferenceCredentialHelperSilentRefreshEnabled: true,
        inferenceModels: $models,
        chatTabEnabled: true,
        isClaudeCodeForDesktopEnabled: true,
        inferenceModelPricingEnabled: true,
        coworkTabEnabled: $cowork
      }' > "$PROFILE"

    if [ "$NO_COWORK" = "1" ]; then ok_ "profile written"; else ok_ "profile written (Cowork enabled)"; fi
    note_ "Quit Claude Desktop completely, then reopen."
    note_ "Profile path: $PROFILE"
  fi
fi

# ------------------------------------------------------------------- verify

step_ "Verifying"
if have_ az; then
  TOKEN="$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>/dev/null || true)"
else
  TOKEN=""
fi

if [ -z "$TOKEN" ]; then
  bad_ "could not acquire a token"; problem_ "token"
else
  ok_ "Entra token acquired"
  body="$(jq -n --arg m "${MODELS[0]}" '{model:$m, max_tokens:16, messages:[{role:"user", content:"Reply with exactly: READY"}]}' 2>/dev/null \
          || printf '{"model":"%s","max_tokens":16,"messages":[{"role":"user","content":"Reply with exactly: READY"}]}' "${MODELS[0]}")"
  hdrs="$(mktemp)"
  code="$(curl -sS -o /dev/null -D "$hdrs" -w '%{http_code}' \
      -X POST "$GATEWAY_URL/v1/messages" \
      -H "Authorization: Bearer $TOKEN" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      --max-time 90 -d "$body" 2>/dev/null || echo "000")"

  case "$code" in
    200)
      ok_ "gateway responded  HTTP 200"
      tier="$(grep -i '^x-claude-tier:' "$hdrs" | tr -d '\r' | cut -d' ' -f2- || true)"
      rem="$(grep -i '^x-ratelimit-remaining-tokens:' "$hdrs" | tr -d '\r' | cut -d' ' -f2- || true)"
      [ -n "$tier" ] && note_ "tier      $tier"
      [ -n "$rem" ]  && note_ "remaining $rem tokens this minute"
      ;;
    401) bad_ "HTTP 401"; note_ "wrong tenant - re-run with --tenant-id"; problem_ "gateway 401" ;;
    403) bad_ "HTTP 403"; note_ "not entitled yet - ask your platform team to add you and run the sync"; problem_ "gateway 403" ;;
    429) warn_ "HTTP 429 - per-minute budget hit. This actually means it is working." ;;
    000) bad_ "no response"; note_ "check network access to $GATEWAY_URL"; problem_ "network" ;;
    *)   bad_ "HTTP $code"; problem_ "gateway $code" ;;
  esac
  rm -f "$hdrs"
fi

# ------------------------------------------------------------------ summary

head_ "Summary"
echo
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  printf '  %sEverything is configured.%s\n\n' "$C_GREEN" "$C_OFF"
  printf '  %-18s %s\n' "Claude Code CLI" "claude"
  printf '  %-18s %s\n' "VS Code" "reload the window, then Claude Code: Open in Side Bar"
  [ "$SKIP_DESKTOP" = "0" ] && printf '  %-18s %s\n' "Claude Desktop" "quit completely, then reopen"
  echo
  note_ "No API key was issued. You authenticate as yourself, and your usage"
  note_ "is metered against your own budget."
else
  printf '  %s%d item(s) need attention:%s %s\n\n' "$C_YELLOW" "${#PROBLEMS[@]}" "$C_OFF" "${PROBLEMS[*]}"
  note_ "If something was just installed, open a new shell and re-run -"
  note_ "installers do not update the PATH of a session already running."
fi
echo
