#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'AUM Cloud Shell: %s\n' "$*" >&2; exit 2; }
stage='preflight'
trap 'printf "AUM Cloud Shell: %s failed (exit %s).\n" "$stage" "$?" >&2' ERR

dry_run=false
if [[ ${1-} == --dry-run ]]; then dry_run=true; shift; fi
if [[ ${1-} == -- ]]; then shift; fi

[[ ${HOME-} == /* && -d $HOME ]] || fail 'HOME must be an absolute, existing directory.'
for tool in python3 az realpath; do
    command -v "$tool" >/dev/null || fail "Required command is unavailable: $tool."
done
home=$(cd -- "$HOME" && pwd -P)
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source_dir="$repo/cli/finops"
[[ -f "$source_dir/pyproject.toml" ]] || fail 'The launcher must stay in a gateway repository checkout.'
case "$(realpath -m -- "$source_dir")" in
    "$repo"/*) ;;
    *) fail 'The package source resolves outside the repository.' ;;
esac

state="$home/.aum-cloudshell"
bootstrap="$state/uv-0.12.20"
uv="$bootstrap/bin/uv"
venv="$state/venv"
for path in "$state" "$bootstrap" "$bootstrap/bin" "$uv" "$state/tmp" "$state/cache" \
            "$state/cache/pip" "$state/cache/uv" "$state/pycache" "$state/python" \
            "$state/config" "$state/data" "$state/state" "$state/run" "$state/userbase" \
            "$venv" "$venv/bin" "$venv/bin/python" "$venv/bin/aum" \
            "$venv/lib" "$venv/lib64" "$venv/pyvenv.cfg" \
            "$venv/lib/python3.12" "$venv/lib/python3.12/site-packages"; do
    case "$(realpath -m -- "$path")" in
        "$home"/*) ;;
        *) fail "Refusing a destination outside HOME: $path" ;;
    esac
done

plan() {
    printf 'HOME-local state: %s\n' "$state"
    printf 'Python: managed 3.12; create or reuse %s\n' "$venv"
    printf 'Package: editable %s\n' "$source_dir"
    printf 'Existing az sign-in is unchanged; no login or Azure setup is performed.\n'
    printf 'Launch:'
    printf ' %q' "$venv/bin/aum" "$@"
    printf '\n'
}
plan "$@"
if "$dry_run"; then exit 0; fi

umask 077
unset PYTHONHOME PYTHONPATH VIRTUAL_ENV
for variable in "${!PIP_@}" "${!UV_@}" "${!XDG_@}"; do
    unset "$variable"
done
export HOME="$home"
export TMPDIR="$state/tmp" TMP="$state/tmp" TEMP="$state/tmp"
export XDG_CACHE_HOME="$state/cache" PIP_CACHE_DIR="$state/cache/pip"
export XDG_CONFIG_HOME="$state/config" XDG_DATA_HOME="$state/data"
export XDG_STATE_HOME="$state/state" XDG_RUNTIME_DIR="$state/run"
export PYTHONUSERBASE="$state/userbase"
export PYTHONPYCACHEPREFIX="$state/pycache" PIP_CONFIG_FILE=/dev/null
export UV_CACHE_DIR="$state/cache/uv" UV_PYTHON_INSTALL_DIR="$state/python"
mkdir -p -- "$TMPDIR" "$PIP_CACHE_DIR" "$UV_CACHE_DIR" "$PYTHONPYCACHEPREFIX" \
    "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$PYTHONUSERBASE"
install_env=(
    "HOME=$HOME" "PATH=$PATH" "LANG=${LANG:-C.UTF-8}"
    "TMPDIR=$TMPDIR" "TMP=$TMP" "TEMP=$TEMP"
    "PIP_CONFIG_FILE=/dev/null" "PIP_CACHE_DIR=$PIP_CACHE_DIR"
    "PYTHONUSERBASE=$PYTHONUSERBASE" "PYTHONPYCACHEPREFIX=$PYTHONPYCACHEPREFIX"
    "UV_CACHE_DIR=$UV_CACHE_DIR" "UV_PYTHON_INSTALL_DIR=$UV_PYTHON_INSTALL_DIR"
    "XDG_CACHE_HOME=$XDG_CACHE_HOME" "XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
    "XDG_DATA_HOME=$XDG_DATA_HOME" "XDG_STATE_HOME=$XDG_STATE_HOME"
    "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
)
for variable in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy \
                SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE CURL_CA_BUNDLE; do
    if [[ -v $variable ]]; then install_env+=("$variable=${!variable}"); fi
done
printf 'Preparing AUM (estimate 2-5 minutes first run; 10-60 s with cached dependencies).\n'

stage='uv bootstrap'
if [[ ! -x "$uv" ]]; then
    env -i "${install_env[@]}" python3 -I -m pip --isolated install \
        --disable-pip-version-check --no-user --only-binary=:all: \
        --cache-dir "$PIP_CACHE_DIR" --target "$bootstrap" --upgrade uv==0.12.20
fi
stage='managed Python and virtual environment'
if [[ ! -d "$venv" ]]; then
    env -i "${install_env[@]}" "$uv" --no-config venv --python 3.12 --managed-python "$venv"
fi
[[ -x "$venv/bin/python" ]] || fail "The existing venv is incomplete: $venv."
env -i "${install_env[@]}" "$venv/bin/python" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' \
    || fail 'The AUM venv requires Python 3.12 or newer; the existing venv was not replaced.'

stage='AUM package installation'
env -i "${install_env[@]}" "$uv" --no-config pip install --python "$venv/bin/python" --editable "$source_dir"
stage='AUM launch'
exec "$venv/bin/aum" "$@"
