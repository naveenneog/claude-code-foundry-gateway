$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fail=0
function Assert([string]$Name,[bool]$Pass){if($Pass){Write-Host "  [OK] $Name"}else{Write-Host "  [FAIL] $Name";$script:fail++}}
function Throws([string]$Name,[scriptblock]$Action,[string]$Pattern){try{& $Action|Out-Null;Assert $Name $false}catch{Assert $Name ($_.Exception.Message -match $Pattern)}}
$file=Join-Path $root 'scripts\ClaudeNetworkReview.ps1'
Assert 'network review gate exists' (Test-Path $file)
if(-not(Test-Path $file)){exit 1}
. (Join-Path $root 'scripts\ClaudeNetworkPricing.ps1')
. $file
$quote=New-ClaudeNetworkConfigurationRate regiona
$line=New-ClaudeNetworkCostItem -Key access -Label access -Quote $quote -CurrentQuantity 1 -DesiredQuantity 1
$decision=[pscustomobject]@{Key='gateway-access';Title='Gateway';Selected=[pscustomobject]@{id='private';label='private';Costs=@($line);Implications=[pscustomobject]@{Security='Private';Capability='Private only';Availability='Depends on route';Operations='DNS';Breaks='Public callers';Rollback='Restore public state';Dependencies='PE'}}}
$action=[pscustomobject]@{Verb='Change';Target='/contoso/apim';Property='publicNetworkAccess';Before='Enabled';After='Disabled';DecisionKey='gateway-access';AccessReducing=$true}
$impact=[pscustomobject]@{Acknowledgement=('a'*64);Coverage=[pscustomobject]@{Complete=$true};Summary=[pscustomobject]@{PotentiallyAffectedUsers=3};Rows=@()}
$review=New-ClaudeNetworkReview -Region regiona -Decisions @($decision) -Actions @($action) -Impact $impact -Parameters @{GatewayAccess='private'} -CostItems @($line)
Assert 'review contains one complete action list and total delta' ($review.Plan.Actions.Count -eq 1 -and $review.Plan.Costs.KnownDeltaMonthly -eq 0)
Assert 'an immutable review has a SHA-256 fingerprint' ($review.Fingerprint -match '^[0-9a-f]{64}$')
Throws 'unattended default ShouldProcess is not approval' {Assert-ClaudeNetworkApproval -Review $review -NonInteractive -ImpactAcknowledgement ('a'*64)} 'explicit'
Throws 'Confirm false alone cannot silently acknowledge a cutoff list' {Assert-ClaudeNetworkApproval -Review $review -NonInteractive -ExplicitConfirmation} 'impact'
Assert 'explicit change approval and the exact impact acknowledgement can proceed' (Assert-ClaudeNetworkApproval -Review $review -NonInteractive -ExplicitConfirmation -ImpactAcknowledgement ('a'*64))
Assert 'WhatIf requires no approval and authorizes no change' (-not (Assert-ClaudeNetworkApproval -Review $review -NonInteractive -WhatIf))
$executor=Get-Content (Join-Path $root 'scripts\New-ClaudeNetworkEdge.ps1') -Raw
Assert 'WhatIf still binds the reviewed parameter values in memory' ($executor -match 'PSVariable\.Set\(\$parameter\.Name,\$parameter\.Value\)' -and $executor -notmatch '(?m)^\s*Set-Variable -Name \$parameter\.Name')
Assert 'deployment requires a priced review before Azure writes' ($executor -match 'if\(-not \$ReviewPath\)' -and $executor.IndexOf('Confirm-ClaudeNetworkReview -Review $review') -lt $executor.IndexOf('function Owned-Put'))
$remover=Get-Content (Join-Path $root 'scripts\Remove-ClaudeNetworkEdge.ps1') -Raw
Assert 'removal checks the reviewed state and approval before rollback/deletion' ($remover -match 'StateFingerprint' -and $remover.IndexOf('Confirm-ClaudeNetworkReview -Review $review') -lt $remover.IndexOf('Wait-ClaudeNetworkResourceReady'))
$incomplete=[pscustomobject]@{Acknowledgement=('b'*64);Coverage=[pscustomobject]@{Complete=$false};Summary=[pscustomobject]@{PotentiallyAffectedUsers=3};Rows=@()}
$gap=New-ClaudeNetworkReview -Region regiona -Decisions @($decision) -Actions @($action) -Impact $incomplete -Parameters @{GatewayAccess='private'} -CostItems @($line)
Throws 'unknown traffic coverage needs a distinct explicit acknowledgement' {Assert-ClaudeNetworkApproval -Review $gap -NonInteractive -ExplicitConfirmation -ImpactAcknowledgement ('b'*64)} 'coverage'
Assert 'the operator may deliberately acknowledge recorded unknown coverage' (Assert-ClaudeNetworkApproval -Review $gap -NonInteractive -ExplicitConfirmation -ImpactAcknowledgement ('b'*64) -AcceptUnknownImpact)
$tamper=$review|ConvertTo-Json -Depth 40|ConvertFrom-Json
$tamper.ReviewJson=$tamper.ReviewJson.Replace('"Disabled"','"Enabled"')
Throws 'changing a serialized plan after review invalidates approval' {Read-ClaudeNetworkReview -Envelope $tamper} 'fingerprint'
$stale=$review|ConvertTo-Json -Depth 40|ConvertFrom-Json
$stalePlan=$stale.ReviewJson|ConvertFrom-Json
$stalePlan.CreatedUtc=[DateTime]::UtcNow.AddMinutes(-31).ToString('o')
$stale.ReviewJson=$stalePlan|ConvertTo-Json -Depth 40 -Compress
$stale.Fingerprint=Get-ClaudeNetworkReviewFingerprint $stale.ReviewJson
Throws 'stale but untampered review cannot authorize a change' {Read-ClaudeNetworkReview -Envelope $stale} 'stale'
$stalePlan.CreatedUtc=[DateTime]::UtcNow.AddMinutes(6).ToString('o')
$stale.ReviewJson=$stalePlan|ConvertTo-Json -Depth 40 -Compress
$stale.Fingerprint=Get-ClaudeNetworkReviewFingerprint $stale.ReviewJson
Throws 'a future review cannot bypass the freshness limit' {Read-ClaudeNetworkReview -Envelope $stale} 'clock'
$unknownQuote=[pscustomobject]@{Known=$false;Rate=$null;Basis='hour'}
$unknownLine=New-ClaudeNetworkCostItem -Key unknown -Label unknown -Quote $unknownQuote -CurrentQuantity 0 -DesiredQuantity 1
$unpriced=New-ClaudeNetworkReview -Region regiona -Decisions @($decision) -Actions @($action) -Impact $impact -Parameters @{} -CostItems @($unknownLine)
Throws 'unpriced resources require a separate acknowledgement' {Assert-ClaudeNetworkApproval -Review $unpriced -NonInteractive -ExplicitConfirmation -ImpactAcknowledgement ('a'*64)} 'Cost coverage'
Assert 'an explicit unknown-price acknowledgement does not discard impact approval' (Assert-ClaudeNetworkApproval -Review $unpriced -NonInteractive -ExplicitConfirmation -ImpactAcknowledgement ('a'*64) -AcceptUnknownCosts)
Throws 'access reduction cannot omit the historical impact report' {New-ClaudeNetworkReview -Region regiona -Decisions @($decision) -Actions @($review.Plan.Actions) -Parameters @{} -CostItems @($line)} 'historical impact'
$missing=[pscustomobject]@{Verb='Change';Target='/contoso/foundry';Property='publicNetworkAccess';Before='Enabled';After='Disabled';DecisionKey='not-chosen';AccessReducing=$true}
Throws 'an action cannot appear without an administrator decision' {New-ClaudeNetworkReview -Region regiona -Decisions @($decision) -Actions @($missing) -Impact $impact -Parameters @{} -CostItems @($line)} 'decision'
$manual=New-ClaudeNetworkReview -Region regiona -Decisions @($decision) -Actions @($action) -Impact $impact -Parameters @{} -CostItems @($line) -Blockers @('The selected deployment needs an approved route.')
Throws 'unsatisfied dependencies block all writes, not just their own action' {Assert-ClaudeNetworkApproval -Review $manual -NonInteractive -ExplicitConfirmation -ImpactAcknowledgement ('a'*64)} 'dependencies'
Throws 'the legacy deployment entry cannot bypass review by passing Confirm false' {& (Join-Path $root 'scripts\New-ClaudeNetworkEdge.ps1') -NonInteractive -Confirm:$false} 'priced administrator review'
if($fail){exit 1}
Write-Host 'Network confirmation and acknowledgement hold.'
exit 0
