#!/usr/bin/env bash
#
# Project banner for the shell setup scripts. Source it, then call
# claude_banner "Subtitle".
#
# Two renderings. The block-character version looks better but needs a terminal
# on a UTF-8 locale; anywhere else it becomes mojibake, which is worse than
# plain ASCII. The locale decides, and CLAUDE_BANNER_ASCII=1 forces the safe one.

claude_banner() {
    local subtitle="${1:-Governed gateway for Claude on Microsoft Foundry}"

    local cyan dim white off
    if [ -t 1 ]; then
        cyan=$'\033[36m'; dim=$'\033[90m'; white=$'\033[97m'; off=$'\033[0m'
    else
        cyan=""; dim=""; white=""; off=""
    fi

    local unicode_ok=1
    [ "${CLAUDE_BANNER_ASCII:-0}" = "1" ] && unicode_ok=0
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*) ;;
        *) unicode_ok=0 ;;
    esac

    printf '\n%s' "$cyan"
    if [ "$unicode_ok" = "1" ]; then
        printf '   ▄▀█ ▀█ █ █ █▀█ █▀▀   █▀▀ █   ▄▀█ █ █ █▀▄ █▀▀   █▀▀ █▀█ █▀▄ █▀▀\n'
        printf '   █▀█ █▄ █▄█ █▀▄ ██▄   █▄▄ █▄▄ █▀█ █▄█ █▄▀ ██▄   █▄▄ █▄█ █▄▀ ██▄\n'
    else
        # A boxed banner rather than a second figlet: ASCII figlet at this width
        # renders "Azure Claude Code" almost illegibly, and a fallback nobody
        # can read is worse than a plain one.
        printf '  +----------------------------------------------------------------------+\n'
        printf '  |                                                                      |\n'
        printf '  |          A Z U R E     C L A U D E     C O D E                       |\n'
        printf '  |                                                                      |\n'
        printf '  +----------------------------------------------------------------------+\n'
    fi
    printf '%s' "$off"

    printf '  %sS E T U P%s  %s%s%s\n' "$white" "$off" "$dim" "$subtitle" "$off"
    if [ "$unicode_ok" = "1" ]; then
        printf '  %s' "$dim"; printf '─%.0s' $(seq 1 72); printf '%s\n' "$off"
    else
        printf '  %s' "$dim"; printf -- '-%.0s' $(seq 1 72); printf '%s\n' "$off"
    fi
    printf '  %sDeveloper%s Naveen Gopalakrishna   %sgithub.com/naveenneog%s\n\n' \
        "$dim" "$off" "$cyan" "$off"
}
