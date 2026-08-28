# Runs the bash test suite for the shell scripts using Git Bash.
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) { throw 'Git Bash not found.' }

$script = Join-Path $PSScriptRoot 'test-setup-workstation.sh'
$p = '/' + ($script -replace '\\','/' -replace '^([A-Za-z]):','$1')

& $bash $p 2>&1 | ForEach-Object { $_ }
exit $LASTEXITCODE
