import os
import sys
import shlex

import pytest

from test_p85_cloudshell import run, setup, shell_path


DESTINATIONS = (
    "PIP_LOG", "PIP_CACHE_DIR", "PIP_TARGET", "PIP_PREFIX", "PIP_SRC", "PIP_BUILD_TRACKER",
    "PYTHONUSERBASE", "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "UV_TOOL_DIR", "UV_TOOL_BIN_DIR",
    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR",
    "XDG_CONFIG_DIRS", "XDG_DATA_DIRS", "XDG_FUTURE_DESTINATION",
)


@pytest.mark.parametrize("tool", ["python3", "uv-template"])
def test_installer_child_environment_is_allowlisted_but_aum_keeps_azure_context(tmp_path, tool):
    layout = setup(tmp_path)
    home, _, tools, _ = layout
    for filename in (tool, "aum-template"):
        path = tools / filename
        tag = "uv-template-${2}" if filename == "uv-template" else filename
        capture = f'env -0 > "$HOME/{tag}-environment"\n'
        path.write_text(path.read_text(encoding="utf-8").replace("set -eu\n", "set -eu\n" + capture, 1),
                        encoding="utf-8", newline="\n")
    azure = shell_path(home / "azure-session")
    aliases = {"PIP_--log": "outside", "UV_--cache-dir": "outside",
               "XDG_--data-home": "outside", "UNRELATED_SECRET": "private-marker"}
    result = run(layout, extra={**aliases, "AZURE_CONFIG_DIR": azure,
                                "HTTPS_PROXY": "http://proxy.contoso.test:3128"})
    assert result.returncode == 0, result.stderr

    def environment(filename):
        return dict(record.decode().split("=", 1) for record in (home / filename).read_bytes().split(b"\0") if record)

    names = ["uv-template-venv-environment", "uv-template-pip-environment"] if tool == "uv-template" else [
        "python3-environment"]
    for name in names:
        child = environment(name)
        for key in (*aliases, "AZURE_CONFIG_DIR"):
            assert key not in child
        assert child["HOME"] == shell_path(home)
        assert child["PIP_CONFIG_FILE"] == "/dev/null"
        assert child["HTTPS_PROXY"] == "http://proxy.contoso.test:3128"
        assert child["PIP_CACHE_DIR"].startswith(shell_path(home) + "/")
    assert environment("aum-template-environment")["AZURE_CONFIG_DIR"] == azure


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


@pytest.mark.parametrize("variable", ["PIP_LOG", "PIP_--log"])
def test_real_pip_offline_cannot_write_inherited_external_log(tmp_path, variable):
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
    native = (
        f"REAL_PYTHON={shlex.quote(shell_path(sys.executable))}\n"
        f"REAL_DEVNULL={shlex.quote(os.devnull)}\n"
        f"NATIVE_WINDOWS={'1' if os.name == 'nt' else '0'}\n"
    )
    (tools / "python3").write_text(wrapper.replace("set -eu\n", "set -eu\n" + native, 1),
                                  encoding="utf-8", newline="\n")
    result = run(layout, extra={
        variable: str(logfile), "PIP_NO_INDEX": "1",
    })
    assert result.returncode != 0
    assert "No matching distribution found" in result.stderr, result.stderr
    assert not logfile.exists(), "Real pip created the external PIP_LOG file before failing offline."
    assert list(outside.iterdir()) == []
    assert not (home / "aum-arguments").exists()
