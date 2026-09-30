import os
from pathlib import Path
import shutil
import shlex
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[3]
LAUNCHER = ROOT / "scripts" / "aum-cloudshell.sh"


def bash():
    if os.name == "nt":
        git = shutil.which("git")
        candidate = Path(git).parents[1] / "bin" / "bash.exe" if git else None
        assert candidate and candidate.is_file(), "Git Bash is required for the offline launcher tests."
        return str(candidate)
    result = shutil.which("bash")
    assert result, "Bash is required for the offline launcher tests."
    return result


def shell_path(path):
    if os.name != "nt":
        return str(path)
    # cygpath names a path under the Windows temp folder /tmp/..., and some Git Bash builds resolve
    # /tmp from the process's TEMP, which these tests set to other folders. The drive form
    # (/c/Users/...) names the same folder without the /tmp mount.
    drive, rest = os.path.splitdrive(os.path.abspath(path))
    root = subprocess.check_output([bash(), "--noprofile", "--norc", "-c", 'cygpath -u "$1"',
                                    "_", drive + "\\"], text=True).strip()
    return root.rstrip("/") + "/" + rest.strip("\\").replace("\\", "/")


PYTHON = r"""#!/usr/bin/env bash
set -eu
printf 'python %s\n' "$*" >> "$HOME/calls"
printf '%s\n' "$TMPDIR" "$TEMP" "$TMP" "$PIP_CACHE_DIR" "$XDG_CACHE_HOME" "$PYTHONPYCACHEPREFIX" >> "$HOME/destinations"
[[ -z ${PIP_TARGET-} && -z ${PIP_PREFIX-} && -z ${PYTHONHOME-} && -z ${PYTHONPATH-} ]] || exit 91
[[ ${FAKE_PIP_EXIT-0} == 0 ]] || { echo 'offline bootstrap failure' >&2; exit "$FAKE_PIP_EXIT"; }
while (($#)); do
  if [[ $1 == --target ]]; then target=$2; break; fi
  shift
done
printf '%s\n' "$target" >> "$HOME/destinations"
mkdir -p "$target/bin"
cp "$TOOLS/uv-template" "$target/bin/uv"
chmod +x "$target/bin/uv"
"""

UV = r"""#!/usr/bin/env bash
set -eu
printf 'uv %s\n' "$*" >> "$HOME/calls"
printf '%s\n' "$UV_CACHE_DIR" "$UV_PYTHON_INSTALL_DIR" >> "$HOME/destinations"
[[ -z ${UV_TARGET-} && -z ${UV_PREFIX-} && -z ${UV_SYSTEM_PYTHON-} ]] || exit 92
[[ $1 == --no-config ]] && shift
if [[ $1 == venv ]]; then
  [[ ${FAKE_VENV_EXIT-0} == 0 ]] || { echo 'offline venv failure' >&2; exit "$FAKE_VENV_EXIT"; }
  dest=${!#}
  printf '%s\n' "$dest" >> "$HOME/destinations"
  mkdir -p "$dest/bin"
  cp "$TOOLS/runtime-template" "$dest/bin/python"
  chmod +x "$dest/bin/python"
else
  [[ $1 == pip && $2 == install && $3 == --python ]]
  runtime=$4
  [[ $5 == --editable ]]
  printf '%s\n' "$6" >> "$HOME/destinations"
  [[ ${FAKE_INSTALL_EXIT-0} == 0 ]] || { echo 'offline package failure' >&2; exit "$FAKE_INSTALL_EXIT"; }
  cp "$TOOLS/aum-template" "$(dirname "$runtime")/aum"
  chmod +x "$(dirname "$runtime")/aum"
fi
"""

RUNTIME = r"""#!/usr/bin/env bash
set -eu
[[ ${FAKE_OLD_RUNTIME-0} == 0 ]] || exit 1
"""

AUM = r"""#!/usr/bin/env bash
set -eu
printf 'aum\n' >> "$HOME/calls"
printf '%s\0' "$@" > "$HOME/aum-arguments"
exit "${FAKE_AUM_EXIT-0}"
"""


def setup(tmp_path):
    assert LAUNCHER.is_file(), "The Cloud Shell launcher has not been implemented."
    home, repo, tools = (tmp_path / name for name in ("home with spaces", "checkout with spaces", "tools"))
    for path in (home, repo / "scripts", repo / "cli" / "finops", tools):
        path.mkdir(parents=True)
    script = repo / "scripts" / LAUNCHER.name
    shutil.copyfile(LAUNCHER, script)
    (repo / "cli" / "finops" / "pyproject.toml").write_text("[project]\nname='offline-aum'\n", encoding="utf-8")
    controls = tools / "controls.env"
    controls.write_text("", encoding="utf-8")
    fixture_context = f"TOOLS={shlex.quote(shell_path(tools))}\n. {shlex.quote(shell_path(controls))}\n"
    for name, content in {"python3": PYTHON, "uv-template": UV, "runtime-template": RUNTIME,
                          "aum-template": AUM, "az": "#!/usr/bin/env bash\nexit 93\n"}.items():
        path = tools / name
        path.write_text(content.replace("set -eu\n", "set -eu\n" + fixture_context, 1),
                        encoding="utf-8", newline="\n")
        path.chmod(0o755)
    return home, repo, tools, script


def run(layout, *args, extra=None):
    home, repo, tools, script = layout
    controls = ("FAKE_PIP_EXIT", "FAKE_VENV_EXIT", "FAKE_INSTALL_EXIT", "FAKE_AUM_EXIT", "FAKE_OLD_RUNTIME")
    (tools / "controls.env").write_text(
        "".join(f"{name}={shlex.quote((extra or {}).get(name, '0'))}\n" for name in controls),
        encoding="utf-8", newline="\n")
    env = dict(os.environ, HOME=shell_path(home), TOOLS=shell_path(tools))
    env.update(extra or {})
    return subprocess.run(
        [bash(), "--noprofile", "--norc", "-c",
         'export PATH="$TOOLS:/usr/bin:/bin"; exec bash "$@"', "_", shell_path(script), *args],
        env=env, cwd=repo, text=True, capture_output=True, timeout=20,
    )


def link_directory(path, target):
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        def quote(value):
            return "'" + str(value).replace("'", "''") + "'"
        subprocess.run(["pwsh", "-NoProfile", "-Command",
                        f"New-Item -ItemType Junction -Path {quote(path)} -Target {quote(target)} | Out-Null"],
                       check=True, capture_output=True)
    else:
        path.symlink_to(target, target_is_directory=True)


@pytest.mark.skipif(os.name != "nt", reason="Git Bash's /tmp mount is a Windows concern.")
def test_shell_paths_do_not_depend_on_the_tmp_mount(tmp_path):
    # Hosted run 36668853983: a Git Bash that resolves /tmp from the process's TEMP could not find
    # /tmp/pytest-of-.../aum-cloudshell.sh once the test handed the launcher another TEMP.
    target = tmp_path / "checkout with spaces" / "scripts"
    target.mkdir(parents=True)
    converted = shell_path(target)
    assert not converted.startswith("/tmp/"), converted
    back = subprocess.check_output([bash(), "--noprofile", "--norc", "-c", 'cygpath -w "$1"', "_", converted],
                                   text=True).strip()
    assert os.path.normcase(back) == os.path.normcase(str(target))


def test_cloudshell_shellcheck_or_bash_syntax():
    assert LAUNCHER.is_file(), "The Cloud Shell launcher has not been implemented."
    assert b"\r" not in LAUNCHER.read_bytes(), "The launcher must also be executable by Linux Bash."
    checker = shutil.which("shellcheck")
    command = [checker, "--shell=bash", str(LAUNCHER)] if checker else [
        bash(), "--noprofile", "--norc", "-n", shell_path(LAUNCHER)]
    result = subprocess.run(command, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr


def test_cloudshell_dry_run_has_plan_without_writes(tmp_path):
    layout = setup(tmp_path)
    home, _, _, _ = layout
    result = run(layout, "--dry-run", "--", "--backend", "direct")
    assert result.returncode == 0, result.stderr
    assert "3.12" in result.stdout and "cli/finops" in result.stdout
    assert ".aum-cloudshell" in result.stdout and "az" in result.stdout
    assert not list(home.iterdir())


def test_cloudshell_creates_reuses_and_forwards_literal_arguments(tmp_path):
    layout = setup(tmp_path)
    home, repo, _, _ = layout
    args = ["--backend", "fake", "--config", "profile with spaces.json", "--reason", "$(touch outside)"]
    for _ in range(2):
        result = run(layout, "--", *args)
        assert result.returncode == 0, result.stderr
    calls = (home / "calls").read_text(encoding="utf-8").splitlines()
    assert len([line for line in calls if line.startswith("python ")]) == 1
    assert len([line for line in calls if line.startswith("uv --no-config venv ")]) == 1
    assert len([line for line in calls if line.startswith("uv --no-config pip install ")]) == 2
    assert calls.count("aum") == 2
    assert "-m pip --isolated install" in calls[0] and "uv==0.12.20" in calls[0]
    assert "--cache-dir " in calls[0]
    assert "--managed-python" in calls[1] and "--python 3.12" in calls[1]
    actual = (home / "aum-arguments").read_bytes().split(b"\0")[:-1]
    assert [arg.decode() for arg in actual] == args
    roots = (shell_path(home) + "/", shell_path(repo) + "/")
    destinations = (home / "destinations").read_text(encoding="utf-8").splitlines()
    assert destinations and all(path.startswith(roots) for path in destinations), destinations
    assert not (repo / "outside").exists()


@pytest.mark.parametrize("variable,code", [
    ("FAKE_PIP_EXIT", 23), ("FAKE_VENV_EXIT", 24), ("FAKE_INSTALL_EXIT", 25),
])
def test_cloudshell_failed_stage_never_launches_aum(tmp_path, variable, code):
    layout = setup(tmp_path)
    result = run(layout, extra={variable: str(code)})
    assert result.returncode == code, result.stderr
    assert "failed" in result.stderr.lower()
    assert not (layout[0] / "aum-arguments").exists()


def test_cloudshell_preserves_aum_exit_status(tmp_path):
    result = run(setup(tmp_path), extra={"FAKE_AUM_EXIT": "19"})
    assert result.returncode == 19


@pytest.mark.parametrize("relative", [
    "", "tmp", "cache", "pycache", "python", "uv-0.12.20", "venv", "venv/lib",
    "config", "data", "state", "run", "userbase",
])
def test_cloudshell_refuses_escaping_destination_links_before_writing(tmp_path, relative):
    layout = setup(tmp_path)
    home = layout[0]
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "sentinel").write_text("unchanged", encoding="utf-8")
    link_directory(home / ".aum-cloudshell" / relative, outside)
    result = run(layout)
    assert result.returncode != 0
    assert "outside HOME" in result.stderr
    assert not (home / "calls").exists()
    assert sorted(path.name for path in outside.iterdir()) == ["sentinel"]


def test_cloudshell_overrides_inherited_write_destinations(tmp_path):
    layout = setup(tmp_path)
    outside = shell_path(tmp_path / "outside")
    variables = ("TMPDIR", "TMP", "TEMP", "PIP_CACHE_DIR", "XDG_CACHE_HOME", "PIP_TARGET",
                 "PIP_PREFIX", "PYTHONHOME", "PYTHONPATH", "PYTHONPYCACHEPREFIX",
                 "UV_CACHE_DIR", "UV_PYTHON_INSTALL_DIR", "VIRTUAL_ENV",
                 "UV_TARGET", "UV_PREFIX", "UV_SYSTEM_PYTHON")
    result = run(layout, extra={name: outside for name in variables})
    assert result.returncode == 0, result.stderr
    assert not (tmp_path / "outside").exists()


def test_cloudshell_missing_az_refuses_before_setup(tmp_path):
    layout = setup(tmp_path)
    (layout[2] / "az").unlink()
    result = run(layout)
    assert result.returncode != 0 and "az" in result.stderr
    assert not list(layout[0].iterdir())


@pytest.mark.parametrize("value", ["", "relative-home"])
def test_cloudshell_requires_absolute_existing_home(tmp_path, value):
    layout = setup(tmp_path)
    result = run(layout, extra={"HOME": value})
    assert result.returncode != 0 and "HOME" in result.stderr
    assert not list(layout[0].iterdir())


def test_cloudshell_rejects_reused_old_python(tmp_path):
    layout = setup(tmp_path)
    assert run(layout).returncode == 0
    (layout[0] / "aum-arguments").unlink()
    result = run(layout, extra={"FAKE_OLD_RUNTIME": "1"})
    assert result.returncode != 0 and "3.12" in result.stderr
    assert not (layout[0] / "aum-arguments").exists()


def test_cloudshell_incomplete_venv_is_not_replaced(tmp_path):
    layout = setup(tmp_path)
    venv = layout[0] / ".aum-cloudshell" / "venv"
    venv.mkdir(parents=True)
    (venv / "sentinel").write_text("unchanged", encoding="utf-8")
    result = run(layout)
    assert result.returncode != 0 and "incomplete" in result.stderr
    assert (venv / "sentinel").read_text(encoding="utf-8") == "unchanged"
    assert not (layout[0] / "aum-arguments").exists()


@pytest.mark.parametrize("escaped", [False, True])
def test_cloudshell_requires_source_in_selected_checkout(tmp_path, escaped):
    layout = setup(tmp_path)
    source = layout[1] / "cli" / "finops"
    if escaped:
        outside = tmp_path / "outside-source"
        source.rename(outside)
        link_directory(source, outside)
    else:
        (source / "pyproject.toml").unlink()
    result = run(layout)
    assert result.returncode != 0 and ("repository" in result.stderr or "checkout" in result.stderr)
    assert not list(layout[0].iterdir())
