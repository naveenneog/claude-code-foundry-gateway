from pathlib import Path
import subprocess


def test_selected_membership_plan_preserves_unrelated_mapping():
    root = Path(__file__).resolve().parents[3]
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(root / "tests" / "Test-AumMembership.ps1")],
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
