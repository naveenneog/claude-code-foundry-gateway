$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    & node --test (Join-Path $PSScriptRoot 'chargeback-redaction.test.mjs')
    if($LASTEXITCODE -ne 0){throw 'Chargeback portal redaction assertions failed.'}
    $capture=Get-Content (Join-Path $root 'guide\capture-chargeback-portal.mjs') -Raw
    if($capture -notmatch 'AUTH_REQUIRED' -or $capture -notmatch 'validateCaptureProfile' -or $capture -notmatch 'redactPortalPage'){
        throw 'Portal capture must retain auth-stop, copied-profile and redaction guards.'
    }
    Write-Host 'Portal redaction and profile guards passed.'
}
finally {Pop-Location}
exit 0
