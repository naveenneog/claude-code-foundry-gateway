# Copied by tests/InstallerCheckpointHarness.ps1 into each scenario as scripts/Set-ClaudeBusinessUnit.ps1.
# Logs each call to <log>\scripts.log and writes what the real script writes to the gateway's named values
# in the JSON world: bu-registry, bu-parents, bu-modes, and a dated USD budget in usd-budgets
# (scripts/Set-ClaudeBusinessUnit.ps1, scripts/ClaudeUsdBudgets.ps1). inject.bu 'refuse' refuses every
# call; 'refuse:<id>' refuses that unit only.
param([string]$Id, [string]$Group, [string]$Parent, [switch]$SkipGroupCheck, [decimal]$MonthlyBudgetUsd, [string]$Mode, [object]$AllowancePercent,
    [string]$ApimName, [string]$ResourceGroup)
$w = [IO.File]::ReadAllText($env:P91_WORLD) | ConvertFrom-Json
$line = "bu $Id $Group parent=$Parent mode=$Mode percent=$AllowancePercent usd=$MonthlyBudgetUsd skipGroupCheck=$([bool]$SkipGroupCheck)"
[IO.File]::AppendAllText((Join-Path $env:P91_LOG 'scripts.log'), $line + "`n")
if ($w.inject.bu -eq 'refuse' -or $w.inject.bu -eq "refuse:$Id") { throw "Business unit '$Id' was refused by the stub." }
$nv = $w.apims.$ApimName.namedValues
$read = { param([string]$Name, [string]$Default) $v = $nv.PSObject.Properties[$Name]; if ($v -and $v.Value) { [string]$v.Value } else { $Default } }
$entries = { param([string]$Value) @($Value.Trim(',') -split ',' | Where-Object { $_ }) }
$set = { param([string]$Name, [string[]]$Items) $nv | Add-Member -NotePropertyName $Name -NotePropertyValue $(if ($Items.Count) { ',' + ($Items -join ',') + ',' } else { ',,' }) -Force }
& $set 'bu-registry' (@(& $entries (& $read 'bu-registry' ',,') | Where-Object { $_ -notlike "$Id=*" }) + "${Id}=${Group}:1000")
& $set 'bu-parents' (@(& $entries (& $read 'bu-parents' ',,') | Where-Object { $_ -notlike "$Id=*" }) + $(if ($Parent) { "$Id=$Parent" } else { @() }))
$modeText = if ($Mode -eq 'Allowance') { "allowance:$AllowancePercent" } elseif ($Mode) { $Mode.ToLowerInvariant() } else { 'strict' }
& $set 'bu-modes' (@(& $entries (& $read 'bu-modes' ',,') | Where-Object { $_ -notlike "$Id=*" }) + $(if ($modeText -ne 'strict') { "$Id=$modeText" } else { @() }))
$doc = $null
try { $doc = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((& $read 'usd-budgets' 'e30='))) | ConvertFrom-Json } catch { $doc = $null }
if (-not $doc -or -not $doc.schema_version) { $doc = [pscustomobject]@{ schema_version = 1; price_book = [pscustomobject]@{ date = '2026-09-01'; models = [pscustomobject]@{} }; items = [pscustomobject]@{} } }
$key = $(if ($Parent) { 'department:' } else { 'organization:' }) + $Id
$doc.items | Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{ amount_usd = [string]$MonthlyBudgetUsd; period = 'month'; price_book_date = '2026-09-01' }) -Force
$nv | Add-Member -NotePropertyName 'usd-budgets' -NotePropertyValue ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($doc | ConvertTo-Json -Depth 8 -Compress)))) -Force
[IO.File]::WriteAllText($env:P91_WORLD, ($w | ConvertTo-Json -Depth 30))
