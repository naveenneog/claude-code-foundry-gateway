#!/usr/bin/env bash
#
# Preflight checks shared by the shell setup scripts. Source it, then call
# claude_preflight.
#
#   . "$(dirname "$0")/preflight.sh"
#   claude_preflight admin        # or: workstation [gateway-url]
#
# Fails fast with a specific remedy rather than part-way through a deployment.
#
# The PowerShell version of this carries an argument-passing canary, because az
# is a .cmd shim on Windows and unquoted native arguments get re-parsed by
# cmd.exe. That failure mode does not exist here - bash passes argv directly -
# so the shell preflight checks tooling, sign-in and reachability instead.

claude_preflight() {
    local mode="${1:-admin}"
    local gateway="${2:-}"
    local problems=0
    local warnings=0

    _p_ok()   { printf '    \033[32m[OK]\033[0m   %s\n' "$1"; }
    _p_warn() { printf '    \033[33m[WARN]\033[0m %s\n' "$1"; warnings=$((warnings+1)); }
    _p_bad()  { printf '    \033[31m[FAIL]\033[0m %s\n' "$1"; problems=$((problems+1)); }
    _p_note() { printf '           \033[90m%s\033[0m\n' "$1"; }

    printf '\n\033[36m==> Checking prerequisites\033[0m\n'

    # ------------------------------------------------------------------ bash
    if [ -n "${BASH_VERSION:-}" ]; then
        _p_ok "bash $BASH_VERSION"
        case "$BASH_VERSION" in
            [1-2].*) _p_warn "bash 3+ recommended; some syntax here may not work" ;;
        esac
    else
        _p_warn "not running under bash - behaviour is untested"
    fi

    # -------------------------------------------------------------- Azure CLI
    if command -v az >/dev/null 2>&1; then
        local azver
        azver="$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo '')"
        if [ -n "$azver" ]; then _p_ok "Azure CLI $azver"; else _p_ok "Azure CLI present"; fi

        # Sanity-check that a query actually round-trips. Unlike Windows this
        # should always pass, so a failure means something genuinely odd - a
        # wrapper on PATH, or a broken install.
        if az account list --query "[?contains(name,'zzzz')].id" -o tsv >/dev/null 2>&1; then
            _p_ok 'Azure CLI argument passing verified'
        else
            _p_warn 'Azure CLI rejected a simple query'
            _p_note 'Check that az on PATH is the real CLI and not a wrapper.'
        fi

        if az account show >/dev/null 2>&1; then
            _p_ok "signed in as $(az account show --query user.name -o tsv 2>/dev/null)"
            _p_note "tenant $(az account show --query tenantId -o tsv 2>/dev/null)"
        else
            _p_warn 'not signed in'
            _p_note 'The script will run az login for you, or run it yourself first.'
            _p_note 'Guests must name the tenant: az login --tenant <tenant-id>'
        fi
    else
        _p_bad 'Azure CLI not found on PATH'
        _p_note 'https://learn.microsoft.com/cli/azure/install-azure-cli'
        _p_note 'If you just installed it, open a new shell - PATH is not refreshed here.'
    fi

    # --------------------------------------------------------------------- jq
    if command -v jq >/dev/null 2>&1; then
        _p_ok "jq $(jq --version 2>/dev/null | sed 's/^jq-//')"
    else
        if [ "$mode" = "admin" ]; then
            _p_bad 'jq not found - required'
            _p_note 'macOS: brew install jq     Debian/Ubuntu: sudo apt-get install jq'
        else
            _p_warn 'jq not found - the setup script will try to install it'
        fi
    fi

    # ----------------------------------------------------------------- by mode
    if [ "$mode" = "admin" ]; then
        if command -v az >/dev/null 2>&1; then
            if az bicep version >/dev/null 2>&1; then
                _p_ok "Bicep $(az bicep version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
            else
                _p_warn 'Bicep not installed'
                _p_note 'The Azure CLI installs it on first use, or run: az bicep install'
            fi
        fi

        # The entitlement sync is PowerShell. Better to say so now than after a
        # 40-minute deployment.
        if command -v pwsh >/dev/null 2>&1; then
            _p_ok "PowerShell $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)"
        else
            _p_warn 'pwsh not found - the entitlement sync step will be skipped'
            _p_note 'Install PowerShell 7, or run Sync-ClaudeAccess.ps1 elsewhere afterwards.'
        fi

        if curl -sS -o /dev/null -m 12 -w '%{http_code}' https://management.azure.com/ 2>/dev/null | grep -qE '^[0-9]{3}$'; then
            _p_ok 'management.azure.com reachable'
        else
            _p_bad 'cannot reach management.azure.com'
            _p_note 'Check proxy, VPN or firewall. Deployment cannot proceed without it.'
        fi
    else
        if command -v node >/dev/null 2>&1; then
            _p_ok "Node.js $(node --version 2>/dev/null)"
        else
            _p_warn 'Node.js not found - needed for the Claude Code CLI'
            _p_note 'The setup script installs it if your package manager is recognised.'
        fi

        if [ -n "$gateway" ]; then
            local code
            code="$(curl -sS -o /dev/null -m 12 -w '%{http_code}' "${gateway%/}/api/hello" 2>/dev/null || echo 000)"
            if [ "$code" != "000" ]; then
                _p_ok "gateway reachable (HTTP $code)"
            else
                _p_bad "cannot reach $gateway"
                _p_note 'Check the URL, and whether a proxy or VPN is in the way.'
            fi
        fi
    fi

    # ----------------------------------------------------------------- verdict
    printf '\n'
    if [ "$problems" -eq 0 ] && [ "$warnings" -eq 0 ]; then
        printf '    \033[32mAll prerequisites satisfied.\033[0m\n\n'
        return 0
    fi
    if [ "$problems" -gt 0 ]; then
        printf '    \033[31m%d blocking issue(s).\033[0m\n' "$problems"
        if [ "$mode" = "admin" ]; then
            printf '    \033[31mFix these and re-run. Nothing has been changed.\033[0m\n\n'
            return 1
        fi
    fi
    [ "$warnings" -gt 0 ] && printf '    \033[33m%d warning(s) - not blocking.\033[0m\n' "$warnings"
    printf '\n'
    return 0
}
