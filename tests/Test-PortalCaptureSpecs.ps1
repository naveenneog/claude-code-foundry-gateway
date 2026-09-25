# Fast, read-only spec/schema/runner tests. No Azure CLI, browser or repository writes.
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    & node --test --test-reporter=tap tests/portal-capture-specs.test.mjs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally { Pop-Location }
exit 0
