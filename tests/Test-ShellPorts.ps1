$ErrorActionPreference = 'Stop'
& node --test (Join-Path $PSScriptRoot 'shell-ports.test.mjs') (Join-Path $PSScriptRoot 'script-security.test.mjs')
exit $LASTEXITCODE