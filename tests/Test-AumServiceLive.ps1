<#
.SYNOPSIS
    Runs reversible Admin-only AUM API evidence on an explicitly selected test gateway.
.DESCRIPTION
    Does not change group membership, role assignments, policy or networking.
    Requires an empty catalog, creates only test units/teams, and restores the
    original catalog in finally. Manager-only tests are a separate go-gated script.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$RecordPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'onboarding\aum-service.json'),
    [Parameter(Mandatory)][string]$UnitGroupName,
    [Parameter(Mandatory)][string]$TeamGroupName,
    [switch]$Execute,
    [switch]$KeepCatalogForManagerDryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\ClaudeAumDeployment.ps1')
$record = Get-Content $RecordPath -Raw | ConvertFrom-Json
$token = Invoke-ClaudeAumAz @('account','get-access-token','--scope',$record.scope,'-o','json')
$headers = @{Authorization='Bearer ' + $token.accessToken}
$unitGroup = Invoke-ClaudeAumAz @('ad','group','show','--group',$UnitGroupName,'-o','json')
$teamGroup = Invoke-ClaudeAumAz @('ad','group','show','--group',$TeamGroupName,'-o','json')
$prefix = 'pilot-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$unitId = "$prefix-unit"; $teamId = "$prefix-team"; $outsideId = "$prefix-other"
$evidence = New-Object System.Collections.Generic.List[object]
function Invoke-LiveApi {
    param([string]$Method, [string]$Path, $Body, [string]$Revision, [int]$Expected=200)
    $h = @{}; foreach ($key in $headers.Keys) { $h[$key] = $headers[$key] }
    if ($Revision) { $h['If-Match'] = $Revision }
    $params = @{Uri="$($record.endpoint)/api/v1/$Path"; Method=$Method; Headers=$h; TimeoutSec=120; UseBasicParsing=$true}
    if ($null -ne $Body) { $params.ContentType='application/json'; $params.Body=($Body | ConvertTo-Json -Depth 12) }
    $start = [datetime]::UtcNow
    try { $response = Invoke-WebRequest @params; $status = [int]$response.StatusCode; $content=$response.Content }
    catch {
        if (-not $_.Exception.Response) { throw }
        $status = [int]$_.Exception.Response.StatusCode
        $content = $_.ErrorDetails.Message
    }
    $result = if ($content) { $content | ConvertFrom-Json } else { $null }
    $evidence.Add([pscustomobject]@{method=$Method; path=$Path; status=$status; utc=$start.ToString('o'); elapsedMs=[math]::Round(([datetime]::UtcNow-$start).TotalMilliseconds); response=$result})
    if ($status -ne $Expected) { throw "$Method $Path returned $status instead of $Expected. $content" }
    return $result
}
function Get-Registry {
    return (Invoke-ClaudeAumAz @('rest','--method','GET','--url',
        "https://management.azure.com$($record.gatewayResourceId)/namedValues/bu-registry?api-version=2024-05-01",'-o','json')).properties.value
}
function Set-LiveBudget([string]$Kind, [string]$Id, [long]$Limit) {
    $current = Invoke-LiveApi GET 'budgets'
    return Invoke-LiveApi PUT "budgets/$Kind/$Id" @{token_limit=$Limit; reason='Reversible AUM service live verification'} $current.revision
}
$beforeCatalog = Invoke-LiveApi GET 'catalog'
$beforeRaw = Get-Registry
if (@($beforeCatalog.organizations).Count -or @($beforeCatalog.departments).Count) {
    throw 'This automated live harness requires an empty isolated test catalog. It refuses to touch existing business-unit configuration.'
}
$plan = [ordered]@{
    unitId=$unitId; teamId=$teamId; outsideId=$outsideId; unitGroupId=$unitGroup.id; teamGroupId=$teamGroup.id
    beforeRaw=$beforeRaw; beforeCatalog=$beforeCatalog; recordPath=$RecordPath
    flows=@('Authenticated reads','Anonymous denial','Catalog create','Budget change/readback/restore',
            'Headroom denial','Request approve/reject/escalate with explicit Admin override','Short boost expiry')
}
if (-not $Execute -or -not $PSCmdlet.ShouldProcess($record.gatewayResourceId, 'Run reversible API writes on this explicitly empty test catalog')) { return $plan }
$keep = $false
try {
    foreach ($path in @('me','capabilities','usage','budgets','trends','requests?limit=3')) { Invoke-LiveApi GET $path | Out-Null }
    $people = Invoke-LiveApi GET 'people?limit=1'
    if (@($people.items).Count) {
        $search = [uri]::EscapeDataString(([string]$people.items[0].id).Substring(0,8))
        $found = Invoke-LiveApi GET "people?search=$search"
        if (-not @($found.items).Count) { throw 'Search did not find the observed person by id prefix.' }
    }
    $savedHeaders = $headers; $headers = @{}
    try { Invoke-LiveApi GET 'me' $null $null 401 | Out-Null }
    finally { $headers = $savedHeaders }
    $entities = @(
        @{id=$unitId; name=$unitGroup.displayName; parent_id=$null; external_ref="entra-group:$($unitGroup.displayName)"},
        @{id=$teamId; name=$teamGroup.displayName; parent_id=$unitId; external_ref="entra-group:$($teamGroup.displayName)"},
        @{id=$outsideId; name=$teamGroup.displayName; parent_id=$unitId; external_ref="entra-group:$($teamGroup.displayName)"}
    )
    $revision = (Invoke-LiveApi GET 'budgets').revision
    Invoke-LiveApi PUT 'catalog' @{entities=$entities; reason='Isolated AUM live test catalog'} $revision | Out-Null
    Set-LiveBudget 'organization' $unitId 9000000 | Out-Null
    Set-LiveBudget 'department' $teamId 3000000 | Out-Null
    Set-LiveBudget 'department' $outsideId 1000000 | Out-Null
    $stable = Get-Registry
    Set-LiveBudget 'department' $teamId 3000001 | Out-Null
    $changed = Get-Registry
    if ($changed -notmatch [regex]::Escape("$teamId=$($teamGroup.displayName):3000001")) { throw 'ARM read-back did not contain the changed test budget.' }
    Set-LiveBudget 'department' $teamId 3000000 | Out-Null
    if ((Get-Registry) -cne $stable) { throw 'Registry did not restore byte-identically after the reversible budget write.' }
    $evidence.Add(@{flow='budget-restored-byte-identically'; utc=[datetime]::UtcNow.ToString('o'); passed=$true})
    $revision = (Invoke-LiveApi GET 'budgets').revision
    Invoke-LiveApi PUT "budgets/department/$teamId" @{token_limit=8000001; reason='Expected parent headroom denial'} $revision 409 | Out-Null

    $request = Invoke-LiveApi POST 'budget-requests' @{scope_type='department'; scope_id=$teamId; token_limit=3000001; reason='Live approval test'} $null 201
    Invoke-LiveApi POST "budget-requests/$($request.id)/approve" @{version=1; reason='Default self-approval must fail'} $null 403 | Out-Null
    Invoke-LiveApi POST "budget-requests/$($request.id)/approve" @{version=1; reason='Explicit single-admin pilot override'; admin_override=$true} | Out-Null
    Set-LiveBudget 'department' $teamId 3000000 | Out-Null
    $request = Invoke-LiveApi POST 'budget-requests' @{scope_type='department'; scope_id=$teamId; token_limit=3000001; reason='Live rejection test'} $null 201
    Invoke-LiveApi POST "budget-requests/$($request.id)/reject" @{version=1; reason='Reject pilot request'; admin_override=$true} | Out-Null
    $request = Invoke-LiveApi POST 'budget-requests' @{scope_type='department'; scope_id=$teamId; token_limit=3000001; reason='Live escalation test'} $null 201
    $escalated = Invoke-LiveApi POST "budget-requests/$($request.id)/escalate" @{version=1; reason='Escalate pilot request'}
    if ($null -ne $escalated.result.approver_scope) { throw 'Request did not escalate to Admin.' }
    Invoke-LiveApi POST "budget-requests/$($request.id)/reject" @{version=2; reason='Close escalated pilot request'; admin_override=$true} | Out-Null

    $revision = (Invoke-LiveApi GET 'budgets').revision
    $expiry = [datetime]::UtcNow.AddSeconds(70).ToString('o')
    $boost = Invoke-LiveApi POST 'boosts' @{scope_type='department'; scope_id=$teamId; token_limit=3000010; expires_at=$expiry; reason='Short live expiry test'} $revision 201
    if ((Get-Registry) -notmatch [regex]::Escape("$teamId=$($teamGroup.displayName):3000010")) { throw 'Boost was not visible in the gateway named value.' }
    $deadline = [datetime]::UtcNow.AddMinutes(5)
    $expired = $false
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 20
        $rows = Invoke-LiveApi GET 'boosts'
        $row = @($rows.items | Where-Object id -eq $boost.result.id)[0]
        if ($row.state -eq 'expired') { $expired = $true; break }
    }
    if (-not $expired) { throw 'The timer did not expire the short boost within five minutes. Do not claim timer success.' }
    if ((Get-Registry) -cne $stable) { throw 'Timer expiry did not restore the prior registry byte-identically.' }
    $evidence.Add(@{flow='timer-restored-byte-identically'; utc=[datetime]::UtcNow.ToString('o'); expires_at=$expiry; passed=$true})
    Invoke-LiveApi GET 'notifications' | Out-Null
    Invoke-LiveApi GET 'audit?limit=200' | Out-Null
    if ($KeepCatalogForManagerDryRun) {
        $keep = $true
        Write-ClaudeAumJson (Join-Path $root '.aum-local\manager-fixture.json') $plan
    }
}
finally {
    try {
        if (-not $keep) {
            $current = Invoke-LiveApi GET 'budgets'
            Invoke-LiveApi PUT 'catalog' @{entities=@(); reason='Live harness finally restoration'} $current.revision | Out-Null
            if ((Get-Registry) -cne $beforeRaw) { throw 'Final registry restoration needs attention.' }
            $evidence.Add(@{flow='original-catalog-restored'; utc=[datetime]::UtcNow.ToString('o'); passed=$true})
        }
    }
    finally { Write-ClaudeAumJson (Join-Path $root '.aum-local\live-evidence.json') $evidence.ToArray() }
}
Write-Host 'Live AUM Admin reads, writes, decisions and real timer expiry passed.' -ForegroundColor Green
