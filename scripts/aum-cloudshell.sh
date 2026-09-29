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
unset PYTHONHOME PYTHONPATH VIRTUAL_ENV PIP_TARGET PIP_PREFIX PIP_USER
unset UV_TARGET UV_PREFIX UV_SYSTEM_PYTHON UV_PROJECT_ENVIRONMENT UV_CONFIG_FILE UV_PYTHON
export HOME="$home"
export TMPDIR="$state/tmp" TMP="$state/tmp" TEMP="$state/tmp"
export XDG_CACHE_HOME="$state/cache" PIP_CACHE_DIR="$state/cache/pip"
export PYTHONPYCACHEPREFIX="$state/pycache" PIP_CONFIG_FILE=/dev/null
export UV_CACHE_DIR="$state/cache/uv" UV_PYTHON_INSTALL_DIR="$state/python"
mkdir -p -- "$TMPDIR" "$PIP_CACHE_DIR" "$UV_CACHE_DIR" "$PYTHONPYCACHEPREFIX"
printf 'Preparing AUM (estimate 2-5 minutes first run; 10-60 s with cached dependencies).\n'

stage='uv bootstrap'
if [[ ! -x "$uv" ]]; then
    python3 -I -m pip install --disable-pip-version-check --no-user --only-binary=:all: \
        --target "$bootstrap" --upgrade uv==0.12.20
fi
stage='managed Python and virtual environment'
if [[ ! -d "$venv" ]]; then
    "$uv" --no-config venv --python 3.12 --managed-python "$venv"
fi
[[ -x "$venv/bin/python" ]] || fail "The existing venv is incomplete: $venv."
"$venv/bin/python" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' \
    || fail 'The AUM venv requires Python 3.12 or newer; the existing venv was not replaced.'

stage='AUM package installation'
"$uv" --no-config pip install --python "$venv/bin/python" --editable "$source_dir"
stage='AUM launch'
exec "$venv/bin/aum" "$@"
