from pathlib import Path
import subprocess


def test_existing_powershell_runner_exercises_direct_compensation():
    root = Path(__file__).resolve().parents[3]
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(root / "tests" / "Test-AumDirectWrites.ps1")],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "assertions passed" in result.stdout
