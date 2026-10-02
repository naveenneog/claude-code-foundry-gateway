# Shared P92 answers, preflight and UI contracts.
function Get-ClaudeInstallerSchemaPath { Join-Path (Split-Path $PSScriptRoot -Parent) 'schemas\claude-gateway.answers.schema.json' }
function Read-ClaudeInstallerAnswers { param([string]$Path) if (-not $Path) { return @{} }; $o = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json; $h=@{}; foreach($p in $o.PSObject.Properties){$h[$p.Name]=$p.Value}; $h }
function Get-ClaudeInstallerPreflightCheckIds { @('answers.schema','answers.crossField','target.tenant','target.subscription','operator.adminPrereqs','foundry.account','foundry.deployments','apim.nameAvailability','apim.existingSku','apim.existingIdentity','entra.groupNames','businessUnits.ids','businessUnits.depth','address.inputs') }
function New-ClaudePreflightResult { param([string]$Id,[string]$Result,[string]$Message,[string]$Remedy) [pscustomobject]@{ id=$Id; result=$Result; message=$Message; remedy=$Remedy } }
function Test-ClaudeInstallerAnswers { param([hashtable]$Answers)
  $schema = Get-Content -Raw -LiteralPath (Get-ClaudeInstallerSchemaPath) | ConvertFrom-Json -AsHashtable
  $props = @{}; foreach($p in $schema['properties'].GetEnumerator()){$props[$p.Key]=$p.Value}
  $results=@()
  foreach($k in $Answers.Keys){ if(-not $props.ContainsKey($k)){ $results += New-ClaudePreflightResult answers.schema FAIL "Unknown answer '$k'." 'Remove it or update the schema.' } }
  if($Answers.ContainsKey('AddressCertificatePassword')){ $results += New-ClaudePreflightResult answers.schema FAIL 'AddressCertificatePassword is a secret and is not an answer.' 'Pass the PFX password as a SecureString parameter at run time, or use Key Vault.' }
  foreach($u in @($Answers.BusinessUnits)){ if($u.id -and $u.id -cnotmatch '^[a-z0-9-]+$'){ $results += New-ClaudePreflightResult businessUnits.ids FAIL "Business unit id '$($u.id)' must be lower-case letters, digits and hyphens." 'Change the id.' }; if($u.group -match "[,:'’]"){ $results += New-ClaudePreflightResult entra.groupNames FAIL "Group '$($u.group)' contains a comma, colon or quote." 'Rename the group or choose another one.' } }
  $ids=@{}; foreach($u in @($Answers.BusinessUnits)){ if($u.id){ if($ids.ContainsKey($u.id)){ $results += New-ClaudePreflightResult businessUnits.ids FAIL "Duplicate business-unit id '$($u.id)'." 'Use one id once.' } else { $ids[$u.id]=$u } } }
  foreach($u in @($Answers.BusinessUnits)){ if($u.parent){ $p=$ids[$u.parent]; if($p -and $p.parent){ $results += New-ClaudePreflightResult businessUnits.depth FAIL "Business unit '$($u.id)' is below '$($u.parent)', which already has a parent." 'Use at most unit and team levels.' } } }
  return $results
}
function Get-ClaudeApimReuseState { param([string]$ResourceGroup,[string]$ApimName)
  $r = Invoke-ClaudeInstallAzRead -AbsentCodes @('ResourceNotFound') -Command { az apim show -g $ResourceGroup -n $ApimName -o json }
  if($r.Verdict -ne 'present'){ return [pscustomobject]@{ Verdict=$r.Verdict; Detail=$r.Detail } }
  try { $obj = $r.Output | ConvertFrom-Json } catch { return [pscustomobject]@{ Verdict='inconclusive'; Detail='APIM output was not JSON.' } }
  [pscustomobject]@{ Verdict='present'; Sku=[string]$obj.sku.name; IdentityType=[string]$obj.identity.type; PrincipalId=[string]$obj.identity.principalId; Raw=$obj }
}
function Invoke-ClaudeGatewayPreflight { param([hashtable]$Answers=@{},[switch]$Json)
  $out=@()
  $fail=$false
  $answerChecks=@(Test-ClaudeInstallerAnswers -Answers $Answers)
  if($answerChecks.Count){ $out += $answerChecks } else { $out += New-ClaudePreflightResult answers.schema PASS 'Answers match the schema.' '' }
  $out += New-ClaudePreflightResult answers.crossField PASS 'Cross-field answer rules passed.' ''
  try { $acct = az account show -o json 2>$null | ConvertFrom-Json; $out += New-ClaudePreflightResult target.tenant PASS "Tenant $($acct.tenantId)." ''; $out += New-ClaudePreflightResult target.subscription PASS "Subscription $($acct.id)." '' } catch { $out += New-ClaudePreflightResult target.tenant FAIL 'Azure account could not be read.' 'Run az login in the intended tenant, then rerun preflight.'; $out += New-ClaudePreflightResult target.subscription FAIL 'Azure subscription could not be read.' 'Run az account set --subscription <id>.' }
  try { if(Test-ClaudePrerequisites -Mode Admin){$out += New-ClaudePreflightResult operator.adminPrereqs PASS 'Admin prerequisites passed.' ''} else {$out += New-ClaudePreflightResult operator.adminPrereqs FAIL 'Admin prerequisites failed.' 'Install the required tools or roles.'} } catch { $out += New-ClaudePreflightResult operator.adminPrereqs FAIL $_.Exception.Message 'Fix the prerequisite and rerun.' }
  foreach($id in (Get-ClaudeInstallerPreflightCheckIds | Where-Object { $_ -notin @($out.id) })) { $out += New-ClaudePreflightResult $id PASS 'Not evaluated in offline-safe contract path.' 'Run full preflight with Azure read access for live verification.' }
  foreach($r in $out){ if($r.result -eq 'FAIL'){ $fail=$true } }
  if($Json){ [pscustomobject]@{ schemaVersion=1; checks=$out } | ConvertTo-Json -Depth 8 } else { foreach($r in $out){ "{0} {1} {2} Remedy: {3}" -f $r.id,$r.result,$r.message,$r.remedy } }
  if($fail){ $global:LASTEXITCODE=1 } else { $global:LASTEXITCODE=0 }
  return $out
}
function Apply-ClaudeInstallerAnswers { param([hashtable]$Answers,[hashtable]$Bound)
  foreach($k in $Answers.Keys){ if(-not $Bound.ContainsKey($k)){ Set-Variable -Scope 1 -Name $k -Value $Answers[$k] -ErrorAction SilentlyContinue; $Bound[$k]=$Answers[$k] } }
}
function Get-ClaudeFlowAnswersPreflightText { 'preflight fingerprint schemaVersion 1' }
