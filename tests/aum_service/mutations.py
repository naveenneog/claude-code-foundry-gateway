"""Run narrowly targeted negative mutations in disposable worktree-local copies."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "service" / "aum"
TESTS = ROOT / "tests" / "aum_service"
CASES = [
    ("scope widening", "scope.py",
     "return leaf in self.organization_ids or leaf in self.department_ids", "return True",
     "test_identity.ScopeTests.test_team_parent_is_context_never_authority"),
    ("skipped headroom", "registry.py",
     "if candidate + siblings > ceiling:", "if False:",
     "test_registry.HeadroomTests.test_team_must_fit_parent_less_siblings_and_direct_overrides"),
    ("serializer drift", "registry.py",
     'return checked_value("," + ",".join(f"{k}={v}" for k, v in values.items()) + ",")',
     'return checked_value("," + ",".join(f"{k}={v}" for k, v in reversed(list(values.items()))) + ",")',
     "test_registry.SerializerTests.test_shared_fixtures_python_and_powershell_are_byte_identical"),
    ("boost never expires", "workflows.py",
     'parse_time(record["expires_at"]) > self.service.clock()',
     'parse_time(record["expires_at"]) < self.service.clock()',
     "test_writes.WorkflowTests.test_expiring_boost_restores_previous_value"),
    ("outside-scope manager write", "service.py",
     'if scope is not None:\n            scope.require_write(kind, key, members.get(key))',
     'if False:\n            scope.require_write(kind, key, members.get(key))',
     "test_writes.ServiceWriteTests.test_manager_only_allowed_team_and_person_writes"),
]


def run():
    work = ROOT / ".aum-local" / ("mutations-" + uuid.uuid4().hex)
    work.mkdir(parents=True)
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1",
           "PYTHONPATH": os.pathsep.join(map(str, [work, TESTS, SOURCE]))}
    try:
        baseline = subprocess.run([sys.executable, "-m", "unittest", *[c[-1] for c in CASES]],
                                  env=env, capture_output=True, text=True)
        if baseline.returncode:
            raise RuntimeError("Mutation baseline failed:\n" + baseline.stderr)
        for name, file, old, new, test in CASES:
            destination = work / "aum_service"
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(SOURCE / "aum_service", destination, ignore=shutil.ignore_patterns("__pycache__"))
            path = destination / file
            original = path.read_text(encoding="utf-8")
            if original.count(old) != 1:
                raise RuntimeError(f"Mutation anchor drifted: {name}")
            path.write_text(original.replace(old, new), encoding="utf-8")
            result = subprocess.run([sys.executable, "-m", "unittest", test], env=env,
                                    capture_output=True, text=True)
            if result.returncode == 0 or "AssertionError" not in result.stderr:
                raise RuntimeError(f"Mutation survived or failed for the wrong reason: {name}\n{result.stderr}")
            print(f"PASS - killed {name}")
        print(f"{len(CASES)} authorization/financial mutations killed.")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    run()
