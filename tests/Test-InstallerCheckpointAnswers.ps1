# A checkpoint resume must never bake in a value its own parameter would refuse if resupplied.
# Reproduced live, 2026-10-13: a run that leaves -DeveloperCount unbound (trusting auto-derivation
# from the tier groups, Install-ClaudeGateway.ps1:762-773) recorded DeveloperCount=0 - the unbound
# [int] parameter's own default - into the checkpoint. On resume,
# Install-ClaudeGateway.ps1:364 (Set-Variable -Name 'DeveloperCount' -Value $recordedAnswers['DeveloperCount'])
# then threw "The variable cannot be validated because the value 0 is not a valid value for the
# DeveloperCount variable", because $DeveloperCount carries [ValidateRange(1,10000000)]
# (Install-ClaudeGateway.ps1:42-43) as a variable-level attribute, not just a parameter-binding-time
# check. The printed "Resume:" command baked in the same unusable -DeveloperCount '0'. Unit-level,
# in-process: Get-ClaudeInstallAnswers and Format-ClaudeInstallResume are pure data transforms over
# script-scope variables: no Azure call, no child process, no az stub needed.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:fail = 0
$script:checks = 0
function Assert($Label, [bool]$Condition, $Detail = '') {
    $script:checks++
    if ($Condition) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label$(if ($Detail) { " - $Detail" })" -ForegroundColor Red; $script:fail++ }
}

Write-Host ''
Write-Host 'Install checkpoint answers never record a value their own parameter would refuse on resume' -ForegroundColor Cyan

. (Join-Path $root 'scripts\ClaudeInstallCheckpoint.ps1')

# Avoids Get-ClaudeInstallSubscriptionId falling through to a real az call: it short-circuits on a
# truthy $script:ClaudeInstall.SubscriptionId.
$script:ClaudeInstall = [pscustomobject]@{ SubscriptionId = '00000000-0000-4000-8000-000000000001'; Root = $root; AnswersPath = ''; Answers = $null }

# Every parameter in $script:ClaudeInstallIntegers must actually be declared [int] on the installer,
# or a future rename of one list without the other reopens exactly this gap.
$installerText = Get-Content -LiteralPath (Join-Path $root 'Install-ClaudeGateway.ps1') -Raw
foreach ($name in $script:ClaudeInstallIntegers) {
    Assert "Install-ClaudeGateway.ps1 declares -$name as [int] (ClaudeInstallIntegers only serializes integers unquoted)" ($installerText -match "\[int\]\`$$name\b")
}
Assert 'DeveloperCount is in ClaudeInstallIntegers, alongside the DeveloperEstimate prompt answer it is distinct from' ($script:ClaudeInstallIntegers -contains 'DeveloperCount')

# DeveloperCount left at its unbound-parameter default of 0 (Install-ClaudeGateway.ps1 never writes a
# derived count back into $DeveloperCount itself; it writes $script:DeveloperEstimate instead).
$script:DeveloperCount = 0
$unboundAnswers = Get-ClaudeInstallAnswers
Assert 'Get-ClaudeInstallAnswers never records DeveloperCount=0 (the unbound-parameter default)' (-not $unboundAnswers.Contains('DeveloperCount')) ($unboundAnswers | ConvertTo-Json -Compress)
$script:ClaudeInstall.Answers = $unboundAnswers
$unboundResume = Format-ClaudeInstallResume -WithAnswers
Assert 'the printed Resume: command carries no -DeveloperCount at all when it was never recorded' ($unboundResume -notmatch '-DeveloperCount\b') $unboundResume

# An explicitly given, valid DeveloperCount is still recorded, and unquoted (it is a real [int]).
$script:DeveloperCount = 25
$explicitAnswers = Get-ClaudeInstallAnswers
Assert 'Get-ClaudeInstallAnswers records an explicit, valid DeveloperCount' ($explicitAnswers.Contains('DeveloperCount') -and $explicitAnswers['DeveloperCount'] -eq 25) ($explicitAnswers | ConvertTo-Json -Compress)
$script:ClaudeInstall.Answers = $explicitAnswers
$explicitResume = Format-ClaudeInstallResume -WithAnswers
Assert 'the printed Resume: command carries -DeveloperCount 25 unquoted, not -DeveloperCount ''25''' ($explicitResume -match '-DeveloperCount 25(?!\S)' -and $explicitResume -notmatch "-DeveloperCount '25'") $explicitResume

# Existing-gateway preservation is intent-sensitive: typed decimal defaults exist
# as variables even when the operator never supplied them.
$script:StandardMonthlyUsd = [decimal]0
$script:PremiumMonthlyUsd = [decimal]0
$script:ModelQuotaOutputShare = [decimal]0.2
$script:modelFamilyQuotaInputsSpecified = $false
$preservingAnswers = Get-ClaudeInstallAnswers
Assert 'an ordinary existing-gateway run does not checkpoint default family-quota inputs' (
    -not $preservingAnswers.Contains('StandardMonthlyUsd') -and
    -not $preservingAnswers.Contains('PremiumMonthlyUsd') -and
    -not $preservingAnswers.Contains('ModelQuotaOutputShare')
) ($preservingAnswers | ConvertTo-Json -Compress)

$script:modelFamilyQuotaInputsSpecified = $true
$disablingAnswers = Get-ClaudeInstallAnswers
Assert 'an explicit zero-dollar configuration checkpoints both zeros and the output-share assumption' (
    $disablingAnswers.Contains('StandardMonthlyUsd') -and $disablingAnswers['StandardMonthlyUsd'] -eq '0' -and
    $disablingAnswers.Contains('PremiumMonthlyUsd') -and $disablingAnswers['PremiumMonthlyUsd'] -eq '0' -and
    $disablingAnswers.Contains('ModelQuotaOutputShare') -and $disablingAnswers['ModelQuotaOutputShare'] -eq '0.2'
) ($disablingAnswers | ConvertTo-Json -Compress)

# Control: before the fix (DeveloperCount absent from ClaudeInstallIntegers), the unbound case would
# have recorded DeveloperCount='0' as a quoted string and the resume line would have carried
# -DeveloperCount '0' - which Install-ClaudeGateway.ps1's own [ValidateRange(1,10000000)] refuses.
# This sentence is proven by the two assertions above; the historical behavior is not re-run here
# because it requires temporarily removing 'DeveloperCount' from the loaded $script:ClaudeInstallIntegers,
# which no later assertion in this file depends on, so it is applied and restored immediately.
$withoutFix = @($script:ClaudeInstallIntegers | Where-Object { $_ -ne 'DeveloperCount' })
$saved = $script:ClaudeInstallIntegers
$script:ClaudeInstallIntegers = $withoutFix
try {
    $script:DeveloperCount = 0
    $regressed = Get-ClaudeInstallAnswers
    $script:ClaudeInstall.Answers = $regressed
    $regressedResume = Format-ClaudeInstallResume -WithAnswers
    Assert 'control: without DeveloperCount in ClaudeInstallIntegers, the historical bug reproduces exactly (quoted ''0'' in both the answers and the resume line)' (
        $regressed.Contains('DeveloperCount') -and $regressed['DeveloperCount'] -eq '0' -and $regressedResume -match "-DeveloperCount '0'"
    ) "answers: $($regressed | ConvertTo-Json -Compress); resume: $regressedResume"
}
finally { $script:ClaudeInstallIntegers = $saved }

Write-Host ''
if ($script:fail) { Write-Host "$($script:fail) of $($script:checks) check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "$($script:checks) check(s) passed: checkpoint answers never record an unresumable value." -ForegroundColor Green
exit 0
