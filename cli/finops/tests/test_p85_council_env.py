import os
import sys

import pytest

from test_p85_cloudshell import run, setup, shell_path


DESTINATIONS = (
    "PIP_LOG", "PIP_CACHE_DIR", "PIP_TARGET", "PIP_PREFIX", "PIP_SRC", "PIP_BUILD_TRACKER",
    "PYTHONUSERBASE", "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "UV_TOOL_DIR", "UV_TOOL_BIN_DIR",
    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
    "XDG_CONFIG_DIRS", "XDG_DATA_DIRS", "XDG_FUTURE_DESTINATION",
)


@pytest.mark.parametrize("name", DESTINATIONS)
def test_each_inherited_destination_is_unset_or_home_confined(tmp_path, name):
    layout = setup(tmp_path)
    home, _, tools, _ = layout
    outside = tmp_path / "outside"
    outside.mkdir()
    audit = """
for variable in """ + " ".join(DESTINATIONS) + r"""; do
  destination=${!variable-}
  [[ -n "$destination" ]] || continue
  if [[ $variable == PIP_LOG ]]; then
    mkdir -p "$(dirname "$destination")"
    printf 'unexpected external log\n' >> "$destination"
  else
    mkdir -p "$destination"
    printf 'write probe\n' > "$destination/probe"
  fi
done
"""
    for filename in ("python3", "uv-template", "aum-template"):
        path = tools / filename
        path.write_text(path.read_text(encoding="utf-8").replace("set -eu\n", "set -eu\n" + audit, 1),
                        encoding="utf-8", newline="\n")
    destination = outside / ("pip.log" if name == "PIP_LOG" else name)
    result = run(layout, extra={name: shell_path(destination)})
    assert result.returncode == 0, result.stderr
    assert list(outside.iterdir()) == [], f"{name} caused a write outside HOME/repo."
    assert (home / "aum-arguments").exists()


def test_real_pip_offline_cannot_write_inherited_external_log(tmp_path):
    layout = setup(tmp_path)
    home, _, tools, _ = layout
    outside = tmp_path / "outside"
    outside.mkdir()
    logfile = outside / "pip.log"
    wrapper = r"""#!/usr/bin/env bash
set -eu
if [[ ${NATIVE_WINDOWS-} == 1 ]]; then
  for variable in TMPDIR TMP TEMP PIP_CACHE_DIR PYTHONPYCACHEPREFIX; do
    value=${!variable-}
    if [[ $value == /* ]]; then
      printf -v "$variable" '%s' "$(cygpath -w "$value")"
      export "$variable"
    fi
  done
fi
export PIP_CONFIG_FILE="$REAL_DEVNULL"
unset PIP_FIND_LINKS
exec "$REAL_PYTHON" "$@" --no-index --no-deps --no-build-isolation
"""
    (tools / "python3").write_text(wrapper, encoding="utf-8", newline="\n")
    result = run(layout, extra={
        "REAL_PYTHON": shell_path(sys.executable), "REAL_DEVNULL": os.devnull,
        "NATIVE_WINDOWS": "1" if os.name == "nt" else "0",
        "PIP_LOG": str(logfile), "PIP_NO_INDEX": "1",
    })
    assert result.returncode != 0
    assert "No matching distribution found" in result.stderr, result.stderr
    assert not logfile.exists(), "Real pip created the external PIP_LOG file before failing offline."
    assert list(outside.iterdir()) == []
    assert not (home / "aum-arguments").exists()
