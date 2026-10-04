# Where install-claude-gateway.sh keeps its install checkpoint, and whether it trusts that place
# (docs/adr/0046-installer-checkpoint-and-resume.md decisions 1 and 2). Sourced by
# scripts/install-checkpoint.sh. Bash 3.2 (the macOS default) and later; no GNU-only flags.

# Cloud Shell sets AZUREPS_HOST_ENVIRONMENT; the Azure CLI reads ACC_CLOUD (U64).
ckpt_cloudshell_() {
  case "${AZUREPS_HOST_ENVIRONMENT:-}" in cloud-shell/*) printf 'AZUREPS_HOST_ENVIRONMENT'; return 0 ;; esac
  if [ -n "${ACC_CLOUD:-}" ]; then printf 'ACC_CLOUD'; fi
}
ckpt_writable_() {
  [ -d "$1" ] || return 1
  local probe="$1/.claude-gateway-probe-$$"
  ( : > "$probe" ) 2>/dev/null || return 1
  rm -f "$probe"
}
ckpt_location_() {
  local drive uname_s
  CKPT_KEY="install-$(printf '%s' "$CKPT_ROOT" | ckpt_sha256_ | cut -c1-16)"
  CKPT_CLOUDSHELL="$(ckpt_cloudshell_)"
  # Git Bash, MSYS2 and Cygwin on Windows: this installer reads no Windows access rules, so it keeps
  # no store there (decision 2); Install-ClaudeGateway.ps1 is the Windows installer.
  uname_s="$(uname -s 2>/dev/null | tr -d '\r')"
  case "$uname_s" in MINGW*|MSYS*|CYGWIN*) CKPT_NOSTORE="on Windows under $uname_s (Git Bash, MSYS2 or Cygwin), install-claude-gateway.sh reads no Windows access rules, so it keeps no install checkpoint; Install-ClaudeGateway.ps1 is the Windows installer" ;; esac
  if [ -n "${CLAUDE_GATEWAY_STATE_DIR:-}" ]; then CKPT_DIR="$CLAUDE_GATEWAY_STATE_DIR"; CKPT_EXPLICIT=1
  elif [ -n "$CKPT_CLOUDSHELL" ]; then
    drive="$HOME/clouddrive"
    if ckpt_writable_ "$drive"; then CKPT_DIR="$drive/.claude-gateway"; CKPT_CLOUDDRIVE=1
    else
      CKPT_DIR="$HOME/.claude-gateway"; CKPT_PERSISTENT=0
      CKPT_WARNING="Cloud Shell without clouddrive ($CKPT_CLOUDSHELL is set and $drive is not a writable directory): the install checkpoint is kept in $CKPT_DIR, which does not persist when the session ends."
    fi
  else CKPT_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-gateway"; fi
  CKPT_FILE="$CKPT_DIR/$CKPT_KEY.json"; CKPT_LOCK="$CKPT_DIR/$CKPT_KEY.lock"
}

# The probe of the store checks: whether the path is a symbolic link, whether the current user (test
# -O) or root owns it, and its owner and mode as ls prints them. Tests replace it, because Git Bash's
# noacl mount reports every file as the current user's with fixed modes.
ckpt_perm_probe_() {
  local line ids
  PERM_LINK=0; PERM_MINE=0; PERM_ROOT=0
  [ -L "$1" ] && PERM_LINK=1
  [ -O "$1" ] && PERM_MINE=1
  line="$(LC_ALL=C ls -ldL "$1" 2>/dev/null | head -n 1 | tr -d '\r')"
  ids="$(LC_ALL=C ls -ldLn "$1" 2>/dev/null | head -n 1 | tr -d '\r')"
  PERM_MODE="$(printf '%s' "$line" | cut -c1-10)"
  PERM_OWNER="$(printf '%s' "$line" | awk '{ print $3 }')"
  [ "$(printf '%s' "$ids" | awk '{ print $3 }')" = "0" ] && PERM_ROOT=1
  return 0
}
# path kind: PERM_WHY says why another account could have written the path, or is empty. clouddrive is
# exempt: its mount sets the modes, and the Cloud Shell storage account's access control applies (U66).
ckpt_perm_why_() {
  PERM_WHY=""
  [ "$CKPT_CLOUDDRIVE" = "1" ] && return 0
  { [ -e "$1" ] || [ -L "$1" ]; } || return 0
  ckpt_perm_probe_ "$1"
  # The state directory's own name is checked for a link where its place is resolved.
  if [ "$2" = "file" ] && [ "$PERM_LINK" = "1" ]; then PERM_WHY="is a symbolic link"
  elif [ "$PERM_MINE" != "1" ]; then PERM_WHY="is owned by ${PERM_OWNER:-another user}, not by the current user"
  else
    case "$PERM_MODE" in ?????w*|????????w*) PERM_WHY="has mode $PERM_MODE (owner $PERM_OWNER), so its group or other users can write it" ;; esac
  fi
  return 0
}
ckpt_store_tail_() { printf 'Nothing was read or changed. Resume: %s' "$(ckpt_resume_cmd_)"; }
# path kind: 0 when no other account could have written the path; otherwise CKPT_UNTRUSTED says why.
ckpt_store_path_() {
  ckpt_perm_why_ "$1" "$2"
  [ -n "$PERM_WHY" ] || return 0
  CKPT_UNTRUSTED="the install checkpoint $2 $1 $PERM_WHY, so it is not trusted; a state directory the installer creates is owner-only."
  return 1
}
# path kind [tail]: refuses a store path another account could have written, before the installer
# reads, parses, locks, renames or replaces anything (ADR-0046 decision 2).
ckpt_perm_check_() {
  local tail="${3:-}"
  ckpt_store_path_ "$1" "$2" && return 0
  [ -n "$tail" ] || tail="$(ckpt_store_tail_)"
  ckpt_refuse_ "$CKPT_UNTRUSTED $tail"
}

# The real path (cd -P) of the deepest directory of a path that exists, then the rest as written.
ckpt_real_dir_() {
  local p="$1" rest="" real
  while [ "$p" != "/" ] && [ ! -d "$p" ]; do
    rest="/${p##*/}$rest"
    p="${p%/*}"; [ -n "$p" ] || p="/"
  done
  real="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
  [ -n "$real" ] || return 1
  real="${real%/}$rest"
  printf '%s' "${real:-/}"
}
# Where the state directory is (decision 2): an absolute path inside $HOME, or inside clouddrive in
# Cloud Shell, and not itself a link. From here on the directory is used by its real path only, and a
# second resolution must give the same path. 0 when the place is trusted; otherwise CKPT_UNTRUSTED says why.
ckpt_location_resolve_() {
  local dir="$CKPT_DIR" home within where real
  case "$dir" in /*) ;; *) CKPT_UNTRUSTED="the install checkpoint directory $dir is not an absolute path, so it is not used."; return 1 ;; esac
  case "$dir/" in */./*|*/../*) CKPT_UNTRUSTED="the install checkpoint directory $dir has a . or .. component, so it is not used."; return 1 ;; esac
  while [ "$dir" != "/" ] && [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    ckpt_perm_probe_ "$dir"
    if [ "$PERM_LINK" = "1" ]; then
      CKPT_UNTRUSTED="the install checkpoint directory $dir is a symbolic link or junction, so it is not trusted; the installer does not follow a link in the state directory's own name."; return 1
    fi
  fi
  home=""; [ -n "${HOME:-}" ] && home="$(ckpt_real_dir_ "$HOME")"
  if [ -z "$home" ]; then CKPT_UNTRUSTED="the home directory ${HOME:-} could not be resolved, so the install checkpoint directory $dir cannot be placed inside it."; return 1; fi
  within="$home"; where="the home directory"
  if [ "$CKPT_CLOUDDRIVE" = "1" ]; then within="$(ckpt_real_dir_ "$HOME/clouddrive")"; where="clouddrive"; fi
  real="$(ckpt_real_dir_ "$dir")"
  case "$real" in
    "${within%/}"/?*) if [ -z "$within" ]; then CKPT_UNTRUSTED="the install checkpoint directory $dir is not inside $where, so it is not used."; return 1; fi ;;
    *) CKPT_UNTRUSTED="the install checkpoint directory $dir resolves to ${real:-no real path}, which is not inside $where $within, so it is not used."; return 1 ;;
  esac
  if [ -n "$CKPT_RESOLVED" ] && [ "$CKPT_RESOLVED" != "$real" ]; then
    CKPT_UNTRUSTED="the install checkpoint directory resolved to $CKPT_RESOLVED at startup and to $real now, so it is not used."; return 1
  fi
  CKPT_RESOLVED="$real"; CKPT_HOME_REAL="$home"
  CKPT_DIR="$real"; CKPT_FILE="$real/$CKPT_KEY.json"; CKPT_LOCK="$real/$CKPT_KEY.lock"
}
# Every directory from the one that holds the state directory up to $HOME is owned by the current user
# or root and is not writable by its group or other users unless its sticky bit is set (OpenSSH's
# StrictModes rule), so no other account can rename an entry between a check and a read. Inside
# clouddrive the mount sets the modes (U66), so only $HOME is read there. 0 when they are; otherwise
# CKPT_UNTRUSTED says why.
ckpt_ancestors_check_() {
  local a
  if [ "$CKPT_CLOUDDRIVE" = "1" ]; then a="$CKPT_HOME_REAL"; else a="${CKPT_DIR%/*}"; [ -n "$a" ] || a="/"; fi
  while :; do
    if [ -e "$a" ]; then
      ckpt_perm_probe_ "$a"
      if [ "$PERM_MINE" != "1" ] && [ "$PERM_ROOT" != "1" ]; then
        CKPT_UNTRUSTED="the directory $a, which holds the install checkpoint directory $CKPT_DIR, is owned by ${PERM_OWNER:-another user}, not by the current user or root, so the store is not trusted."; return 1
      fi
      case "$PERM_MODE" in
        ?????w???[tT]*|????????w[tT]*) ;;
        ?????w*|????????w*) CKPT_UNTRUSTED="the directory $a, which holds the install checkpoint directory $CKPT_DIR, has mode $PERM_MODE (owner ${PERM_OWNER:-unknown}), so its group or other users can rename what it holds, and the store is not trusted."; return 1 ;;
      esac
    fi
    { [ "$a" = "$CKPT_HOME_REAL" ] || [ "$a" = "/" ]; } && break
    a="${a%/*}"; [ -n "$a" ] || a="/"
  done
  return 0
}
# A store that fails a check (decision 2). CLAUDE_GATEWAY_STATE_DIR names the operator's place, so the
# run refuses. A default place that holds this checkout's checkpoint, lock or a temporary file refuses
# too, so that the file is shown and a run that was to resume does not start over unnoticed. Otherwise
# the run keeps no store and relies on its live checks (decision 1). Returns 1.
ckpt_untrusted_store_() {
  local f found="" count=0
  if [ "$CKPT_EXPLICIT" = "1" ]; then ckpt_refuse_ "$CKPT_UNTRUSTED The directory is named by CLAUDE_GATEWAY_STATE_DIR. $(ckpt_store_tail_)"; fi
  for f in "$CKPT_FILE" "$CKPT_LOCK" "$CKPT_FILE".tmp-*; do
    if [ -e "$f" ] || [ -L "$f" ]; then found="${found:+$found, }$f"; count=$((count + 1)); fi
  done
  if [ "$count" -eq 1 ]; then found="This checkout's install file $found is there"; elif [ "$count" -gt 1 ]; then found="This checkout's install files $found are there"; fi
  if [ -n "$found" ]; then
    ckpt_refuse_ "$CKPT_UNTRUSTED $found, so the run stops instead of starting over. Nothing was read or changed. Next step: inspect the file, then remove it or correct the permissions, then rerun: $(ckpt_resume_cmd_)"
  fi
  CKPT_NOSTORE="$CKPT_UNTRUSTED This run keeps no install checkpoint."
  CKPT_PERSISTENT=0
  return 1
}
# Before anything in the store is read: where it is, the state directory, what holds it, and then the
# checkpoint and the lock. 0 when the store is trusted; 1 when the run keeps no store.
ckpt_store_check_() {
  CKPT_UNTRUSTED=""
  if ckpt_location_resolve_ && ckpt_store_path_ "$CKPT_DIR" directory && ckpt_ancestors_check_ &&
    ckpt_store_path_ "$CKPT_FILE" file && ckpt_store_path_ "$CKPT_LOCK" file; then return 0; fi
  ckpt_untrusted_store_
}
