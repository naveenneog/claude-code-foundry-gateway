from pathlib import Path
import subprocess

import pytest


@pytest.mark.parametrize("host", ["pwsh", "powershell"])
def test_batch_json_uses_private_temp_not_the_checkout(host, tmp_path):
    root = Path(__file__).resolve().parents[3]
    script = root / "tests" / "Test-AumReadBatch.ps1"
    command = r"""
$ErrorActionPreference='Stop'
function Set-Content {
    param($LiteralPath, $Encoding, [Parameter(ValueFromPipeline=$true)]$Value)
    begin {
        if (-not [IO.Path]::GetFullPath($LiteralPath).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Batch fixture escaped the process-private TEMP directory.'
        }
        $global:P71FixtureWrites += [string]$LiteralPath
    }
    process { Microsoft.PowerShell.Management\Set-Content -LiteralPath $LiteralPath -Encoding $Encoding -Value $Value }
}
$global:P71FixtureWrites=@()
& '__SCRIPT__'
if (-not $global:P71FixtureWrites.Count) { throw 'The real batch fixture was not exercised.' }
foreach ($path in $global:P71FixtureWrites) {
    if (Test-Path -LiteralPath $path) { throw 'A temporary JSON fixture survived cleanup.' }
}
"""
    import os
    result = subprocess.run([host, "-NoProfile", "-Command", command.replace("__SCRIPT__", str(script))],
                            capture_output=True, text=True, timeout=60,
                            env=dict(os.environ, TEMP=str(tmp_path), TMP=str(tmp_path), TMPDIR=str(tmp_path)))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "14/14 AUM batch read assertions passed" in result.stdout
