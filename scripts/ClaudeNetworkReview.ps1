function Get-ClaudeNetworkReviewFingerprint {
    param([string]$Text)
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function New-ClaudeNetworkReview {
    param(
        [string]$Region,[object[]]$Decisions,[object[]]$Actions,[object[]]$CostItems,
        $Impact,[System.Collections.IDictionary]$Parameters,[string[]]$Blockers=@(),
        [object[]]$Snapshots=@(),[string[]]$Warnings=@()
    )
    $keys=@($Decisions|ForEach-Object{$_.Key})
    if(@($keys|Sort-Object -Unique).Count -ne $keys.Count){throw 'A decision key appears more than once.'}
    foreach($action in $Actions){
        if($action.Verb -notin @('Create','Change','Remove','Retain')){throw 'Each action must state Create, Change, Remove or Retain.'}
        if($keys -notcontains $action.DecisionKey){throw "Action '$($action.Target)' lacks an administrator decision."}
    }
    foreach($key in $Parameters.Keys){
        if([string]$key -match 'Password|AccessToken|SecretValue|ConnectionString|PrivateKey'){throw 'A network review must not contain credential values.'}
    }
    $reducing=@($Actions|Where-Object AccessReducing).Count -gt 0
    if($reducing -and (-not $Impact -or -not $Impact.Acknowledgement)){throw 'Access-reducing actions require a historical impact report before review.'}
    $plan=[ordered]@{
        Version=1;CreatedUtc=[DateTime]::UtcNow.ToString('o');Region=$Region
        Decisions=$Decisions;Actions=$Actions;Costs=(Get-ClaudeNetworkCostDelta $CostItems)
        Impact=$Impact;RequiresImpact=$reducing;Parameters=$Parameters;Snapshots=$Snapshots
        Blockers=$Blockers;Warnings=$Warnings
    }
    $json=$plan|ConvertTo-Json -Depth 80 -Compress
    return [pscustomobject]@{Version=1;Fingerprint=(Get-ClaudeNetworkReviewFingerprint $json);ReviewJson=$json;Plan=[pscustomobject]$plan}
}

function Read-ClaudeNetworkReview {
    param($Envelope,[string]$Path,[ValidateRange(1,120)][int]$MaximumAgeMinutes=30)
    if($Path){$Envelope=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json}
    if(-not $Envelope -or $Envelope.Version -ne 1 -or -not $Envelope.ReviewJson){throw 'Expected a versioned network review envelope.'}
    if((Get-ClaudeNetworkReviewFingerprint $Envelope.ReviewJson) -ne $Envelope.Fingerprint){throw 'Network review fingerprint mismatch. Review changed choices again.'}
    $plan=$Envelope.ReviewJson|ConvertFrom-Json
    $created=if($plan.CreatedUtc -is [datetime]){$plan.CreatedUtc.ToUniversalTime()}else{[DateTimeOffset]::Parse([string]$plan.CreatedUtc).UtcDateTime}
    $age=[DateTime]::UtcNow-$created
    if($age.TotalMinutes -gt $MaximumAgeMinutes -or $age.TotalMinutes -lt -5){throw 'The network review is stale or ahead of this clock. Refresh prices, state and impact.'}
    return [pscustomobject]@{Version=1;Fingerprint=$Envelope.Fingerprint;ReviewJson=$Envelope.ReviewJson;Plan=$plan}
}

function Assert-ClaudeNetworkApproval {
    param(
        $Review,[switch]$NonInteractive,[switch]$ExplicitConfirmation,
        [string]$ApprovedPlanFingerprint,[string]$ImpactAcknowledgement,
        [switch]$AcceptUnknownImpact,[switch]$AcceptUnknownCosts,[switch]$WhatIf
    )
    $reviewed=Read-ClaudeNetworkReview -Envelope $Review
    if($WhatIf){return $false}
    if(@($reviewed.Plan.Blockers).Count){throw 'Unmet dependencies block the entire plan before any change: review the listed blockers.'}
    $explicit=$ExplicitConfirmation -or ($ApprovedPlanFingerprint -and $ApprovedPlanFingerprint -eq $reviewed.Fingerprint)
    if(-not $explicit){throw 'An explicit confirmation is required: -Confirm:$false or the exact reviewed plan fingerprint; non-interactive defaults are not approval.'}
    if($ApprovedPlanFingerprint -and $ApprovedPlanFingerprint -ne $reviewed.Fingerprint){throw 'Approved plan fingerprint does not match this plan.'}
    if($reviewed.Plan.RequiresImpact){
        if($ImpactAcknowledgement -ne $reviewed.Plan.Impact.Acknowledgement){throw 'Acknowledge the exact affected-user impact report before restricting access.'}
        if(-not $reviewed.Plan.Impact.Coverage.Complete -and -not $AcceptUnknownImpact){throw 'Impact coverage is incomplete. Explicitly acknowledge the listed unknown coverage; no client is assumed safe.'}
    }
    if(-not $reviewed.Plan.Costs.Complete -and -not $AcceptUnknownCosts){throw 'Cost coverage is incomplete. Explicitly acknowledge unknown prices/consumption instead of treating them as zero.'}
    return $true
}

function Show-ClaudeNetworkReview {
    param($Review)
    $r=Read-ClaudeNetworkReview -Envelope $Review
    Write-Host "`nNETWORK CHANGE CONFIRMATION - nothing has changed" -ForegroundColor Cyan
    Write-Host ("Plan {0}; region {1}; created UTC {2}" -f $r.Fingerprint,$r.Plan.Region,$r.Plan.CreatedUtc)
    foreach($decision in $r.Plan.Decisions){
        Write-Host ("  {0}: {1}" -f $decision.Title,$decision.Selected.label)
        foreach($field in @('Security','Capability','Availability','Operations','Breaks','Rollback','Dependencies')){
            Write-Host ("    {0}: {1}" -f $field,$decision.Selected.Implications.$field) -ForegroundColor DarkGray
        }
    }
    Write-Host "`nComplete create/change/remove/retain list:"
    foreach($action in $r.Plan.Actions){
        Write-Host ("  {0}: {1}" -f $action.Verb.ToUpperInvariant(),$action.Target)
        Write-Host ("    {0}: {1} -> {2}; decision {3}; access reducing: {4}" -f $action.Property,($action.Before|ConvertTo-Json -Compress -Depth 8),($action.After|ConvertTo-Json -Compress -Depth 8),$action.DecisionKey,$action.AccessReducing)
    }
    Write-Host "`nCost delta (USD list prices, 730 hours/month; not an invoice):"
    foreach($item in $r.Plan.Costs.Items){
        Write-Host ("  {0}{1}" -f $item.Label,$(if($item.Shared){' [shared allocation retained]'}else{''}))
        Write-Host ("    Current {0}/h / {1}/month; proposed {2}/h / {3}/month; delta {4}/h / {5}/month" -f
            (Format-ClaudeNetworkMoney $item.CurrentHourly),(Format-ClaudeNetworkMoney $item.CurrentMonthly),
            (Format-ClaudeNetworkMoney $item.DesiredHourly),(Format-ClaudeNetworkMoney $item.DesiredMonthly),
            (Format-ClaudeNetworkMoney $item.DeltaHourly),(Format-ClaudeNetworkMoney $item.DeltaMonthly))
        Write-Host ("    Region {0}; published scope {1}; retrieved UTC {2}" -f $r.Plan.Region,$item.Quote.PublishedRegion,(ConvertTo-ClaudeNetworkUtcText $item.Quote.RetrievedUtc))
    }
    Write-Host ("Known current {0}/hour, {1}/month; proposed {2}/hour, {3}/month; delta {4}/hour, {5}/month." -f
        (Format-ClaudeNetworkMoney $r.Plan.Costs.KnownCurrentHourly),(Format-ClaudeNetworkMoney $r.Plan.Costs.KnownCurrentMonthly),
        (Format-ClaudeNetworkMoney $r.Plan.Costs.KnownDesiredHourly),(Format-ClaudeNetworkMoney $r.Plan.Costs.KnownDesiredMonthly),
        (Format-ClaudeNetworkMoney $r.Plan.Costs.KnownDeltaHourly),(Format-ClaudeNetworkMoney $r.Plan.Costs.KnownDeltaMonthly))
    if(-not $r.Plan.Costs.Complete){Write-Warning 'This is a known subtotal, not a complete total: unpriced/variable lines require acknowledgement.'}
    if($r.Plan.Impact){Show-ClaudeNetworkImpact $r.Plan.Impact}
    foreach($warning in $r.Plan.Warnings){Write-Warning $warning}
    foreach($blocker in $r.Plan.Blockers){Write-Host "BLOCKED: $blocker" -ForegroundColor Red}
}

function Confirm-ClaudeNetworkReview {
    param(
        $Review,[switch]$NonInteractive,[switch]$ExplicitConfirmation,
        [string]$ApprovedPlanFingerprint,[string]$ImpactAcknowledgement,
        [switch]$AcceptUnknownImpact,[switch]$AcceptUnknownCosts,[switch]$WhatIf
    )
    Show-ClaudeNetworkReview $Review
    if($WhatIf){Write-Host 'WhatIf: the same plan and impact are shown; no change is authorized.';return $false}
    if(-not $NonInteractive -and -not $ExplicitConfirmation -and -not $ApprovedPlanFingerprint){
        if(@($Review.Plan.Blockers).Count){throw 'Resolve the listed dependencies before approving this plan.'}
        $phrase='APPLY '+$Review.Fingerprint
        $answer=Read-Host ("Type '{0}' to approve this full cost/change plan AND acknowledge its affected-user list and all displayed unknowns" -f $phrase)
        if($answer -cne $phrase){throw 'Network change not approved; nothing was changed.'}
        $ExplicitConfirmation=$true
        $ImpactAcknowledgement=$Review.Plan.Impact.Acknowledgement
        $AcceptUnknownImpact=$true
        $AcceptUnknownCosts=$true
    }
    return Assert-ClaudeNetworkApproval -Review $Review -NonInteractive:$NonInteractive -ExplicitConfirmation:$ExplicitConfirmation -ApprovedPlanFingerprint $ApprovedPlanFingerprint -ImpactAcknowledgement $ImpactAcknowledgement -AcceptUnknownImpact:$AcceptUnknownImpact -AcceptUnknownCosts:$AcceptUnknownCosts
}
