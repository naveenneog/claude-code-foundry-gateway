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
    $spec=Get-Content (Join-Path $root 'guide\captures\p50.json') -Raw|ConvertFrom-Json
    if($spec.version -ne 1 -or @($spec.steps).Count -ne 27){throw 'P50 batch handoff must enumerate all 27 required portal views.'}
    if(@($spec.steps.id|Sort-Object -Unique).Count -ne 27 -or @($spec.steps.output|Sort-Object -Unique).Count -ne 27){throw 'Batch IDs and output paths must be unique.'}
    foreach($step in $spec.steps){
        if($step.id -notmatch '^p50-' -or $step.target.discover -notin @('resource','vnet','private-dns') -or -not $step.target.selectionKey){throw 'Batch targets must use explicit discovered resource selections.'}
        if($step.target.discover -eq 'resource' -and (-not $step.target.resourceType -or $step.target.tags.'claude-chargeback-owner' -ne 'P50')){throw 'Generic report resources must be selected by logical ownership tags.'}
        if($step.redaction.mapEnv -ne 'PORTAL_REDACTIONS_FILE'){throw 'Batch redaction guard is missing.'}
        if($step.output -notmatch '^docs/images/chargeback-reports/portal-[a-z-]+\.png$' -or -not (Test-Path (Join-Path $root $step.output))){throw 'Batch output must identify an existing documented live portal image.'}
        if(($step.target|ConvertTo-Json -Compress) -match '/subscriptions/|https?://|[0-9a-f]{8}-[0-9a-f]{4}'){throw 'A literal deployment target entered the batch handoff.'}
    }
    Write-Host 'Portal redaction and profile guards passed.'
}
finally {Pop-Location}
exit 0
