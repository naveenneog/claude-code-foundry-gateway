$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$sandbox=Join-Path $root ('shots\network-review-mutations-'+[guid]::NewGuid().ToString('N'))
$engine=(Get-Process -Id $PID).Path
$mutations=@(
    @('ClaudeNetworkReview.ps1','if(-not $explicit)','if($false)','Test-NetworkApproval.ps1','unattended default ShouldProcess is not approval'),
    @('ClaudeNetworkReview.ps1','if($ImpactAcknowledgement -ne $reviewed.Plan.Impact.Acknowledgement)','if($false)','Test-NetworkApproval.ps1','Confirm false alone cannot silently acknowledge a cutoff list'),
    @('ClaudeNetworkReview.ps1','if(-not $reviewed.Plan.Impact.Coverage.Complete -and -not $AcceptUnknownImpact)','if($false)','Test-NetworkApproval.ps1','unknown traffic coverage needs a distinct explicit acknowledgement'),
    @('ClaudeNetworkReview.ps1','if((Get-ClaudeNetworkReviewFingerprint $Envelope.ReviewJson) -ne $Envelope.Fingerprint)','if($false)','Test-NetworkApproval.ps1','changing a serialized plan after review invalidates approval'),
    @('ClaudeNetworkReview.ps1','if($age.TotalMinutes -gt $MaximumAgeMinutes -or $age.TotalMinutes -lt -5)','if($false)','Test-NetworkApproval.ps1','stale but untampered review cannot authorize a change'),
    @('ClaudeNetworkReview.ps1','if(@($reviewed.Plan.Blockers).Count)','if($false)','Test-NetworkApproval.ps1','unsatisfied dependencies block all writes, not just their own action'),
    @('ClaudeNetworkReview.ps1','if(-not $reviewed.Plan.Costs.Complete -and -not $AcceptUnknownCosts)','if($false)','Test-NetworkApproval.ps1','unpriced resources require a separate acknowledgement'),
    @('ClaudeNetworkPricing.ps1','$current=$null;$desired=$null','$current=[decimal]0;$desired=[decimal]0','Test-NetworkDecisions.ps1','unknown proposed price is never a zero'),
    @('ClaudeNetworkPricing.ps1','-and $_.armRegionName -eq $scope -and','-and $true -and','Test-NetworkDecisions.ps1','another region is not silently priced at the first region'),
    @('ClaudeNetworkImpact.ps1','$pathStatus=''Unknown''','$pathStatus=''Inside''','Test-NetworkImpact.ps1','missing/masked client IP is uncertainty, not a safe private route')
)
try {
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'scripts'),(Join-Path $sandbox 'tests') -Force|Out-Null
    Copy-Item (Join-Path $root 'scripts\*.ps1') (Join-Path $sandbox 'scripts')
    foreach($test in @('Test-NetworkApproval.ps1','Test-NetworkDecisions.ps1','Test-NetworkImpact.ps1')){
        Copy-Item (Join-Path $PSScriptRoot $test) (Join-Path $sandbox 'tests')
        $output=& $engine -NoProfile -NonInteractive -File (Join-Path $sandbox ('tests\'+$test)) 2>&1
        if($LASTEXITCODE -ne 0){throw "Unmutated $test failed: $($output -join [Environment]::NewLine)"}
    }
    foreach($mutation in $mutations){
        $path=Join-Path $sandbox ('scripts\'+$mutation[0])
        $original=Get-Content -LiteralPath $path -Raw
        if(-not $original.Contains($mutation[1])){throw "Mutation target absent: $($mutation[1])"}
        try {
            [IO.File]::WriteAllText($path,$original.Replace($mutation[1],$mutation[2]),[Text.Encoding]::UTF8)
            $output=& $engine -NoProfile -NonInteractive -File (Join-Path $sandbox ('tests\'+$mutation[3])) 2>&1
            $exit=$LASTEXITCODE
            if($exit -eq 0 -or -not (($output -join "`n").Contains('[FAIL] '+$mutation[4]))){
                throw "Mutation escaped or failed for the wrong reason: $($mutation[1]); exit $exit; $($output -join [Environment]::NewLine)"
            }
            Write-Host "  [OK] mutation caught: $($mutation[4])"
        } finally {
            [IO.File]::WriteAllText($path,$original,[Text.Encoding]::UTF8)
        }
    }
    Write-Host "$($mutations.Count) administrator-review mutations caught."
} finally {
    if(Test-Path -LiteralPath $sandbox){Remove-Item -LiteralPath $sandbox -Recurse -Force}
}
