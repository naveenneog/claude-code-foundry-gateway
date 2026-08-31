#!/usr/bin/env bash
#
# Project banner for the shell setup scripts. Source it, then call
# claude_banner "Subtitle".
#
# The art is pure ASCII, so there is one rendering and no locale sniffing: it
# looks the same on every terminal. It is emitted from a quoted heredoc rather
# than printf, because the art contains an apostrophe - which would end a
# single-quoted string - and a percent sign would otherwise need escaping.

claude_banner() {
    local subtitle="${1:-Governed gateway for Claude on Microsoft Foundry}"

    local cyan dim white off
    if [ -t 1 ]; then
        cyan=$'\033[36m'; dim=$'\033[90m'; white=$'\033[97m'; off=$'\033[0m'
    else
        cyan=""; dim=""; white=""; off=""
    fi

    printf '\n%s' "$cyan"
    cat <<'ART'
 _____               _            _____ _           _        _____       _     
|   __|___ _ _ ___ _| |___ _ _   |     | |___ _ _ _| |___   |     |___ _| |___ 
|   __| . | | |   | . |  _| | |  |   --| | .'| | | . | -_|  |   --| . | . | -_|
|__|  |___|___|_|_|___|_| |_  |  |_____|_|__,|___|___|___|  |_____|___|___|___|
                          |___|                                                 
ART
    printf '%s' "$off"

    printf '%sS E T U P%s  %s%s%s\n' "$white" "$off" "$dim" "$subtitle" "$off"
    printf '%s' "$dim"; printf -- '-%.0s' $(seq 1 79); printf '%s\n' "$off"
    printf '%sDeveloper%s Naveen Gopalakrishna   %sgithub.com/naveenneog%s\n\n' \
        "$dim" "$off" "$cyan" "$off"
}
