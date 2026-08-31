<#
.SYNOPSIS
    Bulk-entitles people to Claude on Foundry from a CSV or an existing Entra
    group, for migrating a population off first-party Claude in one go.

.DESCRIPTION
    Entitlement is Entra group membership. This fills those groups; it does not
    change the gateway. Run Sync-ClaudeAccess.ps1 afterwards to push membership
    into API Management, or let the scheduled sync pick it up.

    Two sources, because migrations arrive in two shapes:

      -Csv        an export from whatever holds the current population - a
                  Center for Enablement roster, a licence report, a
                  spreadsheet. One column of identifiers, optionally a tier.

      -FromGroup  an existing Entra group, including nested ones. This is the
                  cleaner path when the population is already a group.

    Resolving identifiers is the hard part, and it is where a naive import
    silently drops people.

    A person can appear in the directory under several different strings, and
    the one a colleague types into a spreadsheet is often none of them. In the
    tenant this was built against, a single account carried:

        userPrincipalName   navg_microsoft.com#EXT#@fdpo.onmicrosoft.com
        mail                naveen.g@microsoft.com
        otherMails          nag@microsoft.com

    - three different addresses, and the address that person actually signs in
    with, navg@microsoft.com, appears on none of them. Their userType is
    'Member' despite the #EXT# form, so filtering on userType would not have
    caught it either.

    So each identifier is tried four ways, in order, and anything still
    unresolved is reported rather than skipped quietly:

      1. as a UPN or object id, directly
      2. mail eq
      3. otherMails/any
      4. the guest form, local_domain#EXT#@<each verified tenant domain>

    Nothing is written without -Confirm being satisfied; -WhatIf shows the full
    plan including who could not be resolved.

.EXAMPLE
    ./Import-ClaudeEntitlement.ps1 -Csv .\c4e-roster.csv -WhatIf

.EXAMPLE
    ./Import-ClaudeEntitlement.ps1 -FromGroup 'ai-c4e-members' -Tier standard

.EXAMPLE
    ./Import-ClaudeEntitlement.ps1 -Csv .\roster.csv -ReportPath .\result.csv
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Csv,
    [string]$FromGroup,
    [ValidateSet('standard', 'premium')]
    [string]$Tier = 'standard',
    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',
    [string]$UserColumn,
    [string]$TierColumn,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$GRAPH = 'https://graph.microsoft.com/v1.0'

$banner = Join-Path $PSScriptRoot 'Show-Banner.ps1'
if (Test-Path $banner) { . $banner; Show-ClaudeBanner -Subtitle 'Bulk entitlement import' }

if (-not $Csv -and -not $FromGroup) { throw 'Pass -Csv or -FromGroup.' }
if ($Csv -and $FromGroup) { throw 'Pass one of -Csv or -FromGroup, not both.' }
if ($Csv -and -not (Test-Path $Csv)) { throw "CSV not found: $Csv" }

function Write-Step2($t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Write-Ok2($t)   { Write-Host "    [OK]   $t" -ForegroundColor Green }
function Write-Warn3($t) { Write-Host "    [WARN] $t" -ForegroundColor Yellow }
function Write-Note2($t) { Write-Host "    $t" -ForegroundColor DarkGray }

# --------------------------------------------------------------------- graph

$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if (-not $token) { throw 'Could not acquire a Microsoft Graph token. Run: az login' }
$token = $token.Trim()

# Invoke-RestMethod rather than `az rest`: on Windows az is a .cmd shim and
# PowerShell only quotes arguments containing a space, so the '&' between Graph
# query parameters reaches cmd.exe as a command separator. Paging URLs carry
# '&' too, so this is not something quoting would fix.
$H  = @{ Authorization = "Bearer $token" }
$HE = @{ Authorization = "Bearer $token"; ConsistencyLevel = 'eventual' }

function Get-GraphPaged($Uri, $Headers = $H) {
    $out = @()
    do {
        $page = Invoke-RestMethod -Headers $Headers -Uri $Uri -Method Get
        $out += $page.value
        $Uri = $page.'@odata.nextLink'
    } while ($Uri)
    return $out
}

function Resolve-GroupId($NameOrId) {
    if ($NameOrId -match '^[0-9a-fA-F-]{36}$') {
        try { return (Invoke-RestMethod -Headers $H -Uri "$GRAPH/groups/$NameOrId`?`$select=id").id } catch { }
    }
    $esc = $NameOrId.Replace("'", "''")
    $r = Invoke-RestMethod -Headers $H -Uri "$GRAPH/groups?`$filter=displayName eq '$esc'&`$select=id,displayName"
    if (-not $r.value.Count) { return $null }
    return $r.value[0].id
}

# Verified domains are needed to build the guest form of an address.
$verifiedDomains = @((Invoke-RestMethod -Headers $H -Uri "$GRAPH/domains?`$select=id,isVerified").value |
                     Where-Object { $_.isVerified } | ForEach-Object { $_.id })

function Resolve-Principal($Value) {
    $v = $Value.Trim()
    if (-not $v) { return $null }

    # 1. UPN or object id, directly.
    try {
        $u = Invoke-RestMethod -Headers $H -Uri "$GRAPH/users/$([uri]::EscapeDataString($v))?`$select=id,userPrincipalName,displayName"
        return [pscustomobject]@{ Id = $u.id; Upn = $u.userPrincipalName; How = 'upn' }
    } catch { }

    $esc = $v.Replace("'", "''")

    # 2. mail
    try {
        $r = Invoke-RestMethod -Headers $H -Uri "$GRAPH/users?`$filter=mail eq '$esc'&`$select=id,userPrincipalName"
        if ($r.value.Count) { return [pscustomobject]@{ Id = $r.value[0].id; Upn = $r.value[0].userPrincipalName; How = 'mail' } }
    } catch { }

    # 3. otherMails - needs the eventual consistency header and $count
    try {
        $r = Invoke-RestMethod -Headers $HE -Uri "$GRAPH/users?`$count=true&`$filter=otherMails/any(m:m eq '$esc')&`$select=id,userPrincipalName"
        if ($r.value.Count) { return [pscustomobject]@{ Id = $r.value[0].id; Upn = $r.value[0].userPrincipalName; How = 'otherMails' } }
    } catch { }

    # 4. the guest form: someone@corp.com becomes someone_corp.com#EXT#@<tenant>
    if ($v -match '^(.+)@(.+)$') {
        $guestLocal = "$($Matches[1])_$($Matches[2])"
        foreach ($d in $verifiedDomains) {
            $candidate = [uri]::EscapeDataString("$guestLocal#EXT#@$d")
            try {
                $u = Invoke-RestMethod -Headers $H -Uri "$GRAPH/users/$candidate`?`$select=id,userPrincipalName"
                return [pscustomobject]@{ Id = $u.id; Upn = $u.userPrincipalName; How = 'guest-form' }
            } catch { }
        }
    }

    return $null
}

# ---------------------------------------------------------------- the target

Write-Step2 'Target groups'
$targets = @{
    standard = @{ Name = $StandardGroup; Id = (Resolve-GroupId $StandardGroup) }
    premium  = @{ Name = $PremiumGroup;  Id = (Resolve-GroupId $PremiumGroup) }
}
foreach ($k in 'standard', 'premium') {
    if ($targets[$k].Id) { Write-Ok2 "$($targets[$k].Name)  ($k)" }
    else { Write-Warn3 "$($targets[$k].Name) not found - $k rows will be reported, not added" }
}

# ----------------------------------------------------------------- the input

Write-Step2 'Source'
$rows = @()

if ($Csv) {
    $data = Import-Csv $Csv
    if (-not $data.Count) { throw "No rows in $Csv" }

    $cols = $data[0].PSObject.Properties.Name
    # Guess the identifier column so a roster exported from anywhere works
    # without the caller having to describe it.
    if (-not $UserColumn) {
        $UserColumn = @('UserPrincipalName','userPrincipalName','UPN','Email','EmailAddress','Mail','User','Member','SignInName') |
                      Where-Object { $_ -in $cols } | Select-Object -First 1
        if (-not $UserColumn) { $UserColumn = $cols[0] }
    }
    if (-not $TierColumn) {
        $TierColumn = @('Tier','ClaudeTier','Level','Plan') | Where-Object { $_ -in $cols } | Select-Object -First 1
    }

    Write-Note2 "file   : $Csv"
    Write-Note2 "column : $UserColumn$(if ($TierColumn) { "  (tier from '$TierColumn')" } else { "  (tier: $Tier for all)" })"

    foreach ($d in $data) {
        $t = if ($TierColumn -and $d.$TierColumn) { ($d.$TierColumn).ToString().Trim().ToLower() } else { $Tier }
        if ($t -notin 'standard', 'premium') { $t = $Tier }
        $rows += [pscustomobject]@{ Input = ($d.$UserColumn); Tier = $t }
    }
}
else {
    $srcId = Resolve-GroupId $FromGroup
    if (-not $srcId) { throw "Group '$FromGroup' not found." }
    Write-Note2 "group  : $FromGroup"
    Write-Note2 "tier   : $Tier"
    # Transitive, so nested groups behave the way admins expect.
    $members = Get-GraphPaged "$GRAPH/groups/$srcId/transitiveMembers?`$select=id,displayName,userPrincipalName"
    foreach ($m in $members) {
        if (-not $m.id) { continue }
        # Not a ternary: Windows PowerShell 5.1 does not have one, and this repo
        # is expected to run on both hosts.
        $ident = if ($m.userPrincipalName) { $m.userPrincipalName } else { $m.id }
        $rows += [pscustomobject]@{ Input = $ident; Tier = $Tier }
    }
}

Write-Ok2 "$($rows.Count) row(s)"

# --------------------------------------------------------------------- resolve

Write-Step2 'Resolving identifiers'
$resolved = @()
$unresolved = @()
$i = 0
foreach ($r in $rows) {
    $i++
    if ($rows.Count -gt 20 -and ($i % 25 -eq 0)) {
        Write-Progress -Activity 'Resolving' -Status "$i of $($rows.Count)" -PercentComplete (100 * $i / $rows.Count)
    }
    $p = Resolve-Principal $r.Input
    if ($p) { $resolved += [pscustomobject]@{ Input = $r.Input; Tier = $r.Tier; Id = $p.Id; Upn = $p.Upn; How = $p.How } }
    else    { $unresolved += [pscustomobject]@{ Input = $r.Input; Tier = $r.Tier; Id = ''; Upn = ''; How = 'not-found' } }
}
Write-Progress -Activity 'Resolving' -Completed

# Someone listed twice, or in both tiers, would otherwise be added twice.
# Premium wins, matching how the gateway policy resolves a dual member.
$byId = @{}
foreach ($r in $resolved) {
    if (-not $byId.ContainsKey($r.Id)) { $byId[$r.Id] = $r }
    elseif ($r.Tier -eq 'premium') { $byId[$r.Id] = $r }
}
$unique = @($byId.Values)

Write-Ok2 "$($resolved.Count) of $($rows.Count) row(s) resolved, to $($unique.Count) distinct principal(s)"
$byHow = $resolved | Group-Object How | Sort-Object Count -Descending
foreach ($g in $byHow) { Write-Note2 ("matched by {0,-12} {1}" -f $g.Name, $g.Count) }
if ($resolved.Count -ne $unique.Count) {
    Write-Note2 "$($resolved.Count - $unique.Count) row(s) were the same person under another address, or a repeat"
}
if ($unresolved.Count) {
    Write-Warn3 "$($unresolved.Count) could not be resolved:"
    $unresolved | Select-Object -First 10 | ForEach-Object { Write-Note2 "  $($_.Input)" }
    if ($unresolved.Count -gt 10) { Write-Note2 "  ... and $($unresolved.Count - 10) more" }
    Write-Note2 'These are reported, not skipped silently. Use -ReportPath for the full list.'
}

# ------------------------------------------------------------------ existing

Write-Step2 'Comparing with current membership'
$toAdd = @{ standard = @(); premium = @() }
$already = 0
foreach ($k in 'standard', 'premium') {
    if (-not $targets[$k].Id) { continue }
    $current = @{}
    foreach ($m in Get-GraphPaged "$GRAPH/groups/$($targets[$k].Id)/members?`$select=id") { $current[$m.id] = $true }
    foreach ($u in $unique | Where-Object Tier -eq $k) {
        if ($current.ContainsKey($u.Id)) { $already++ } else { $toAdd[$k] += $u }
    }
    Write-Note2 ("{0,-24} {1} existing member(s)" -f $targets[$k].Name, $current.Count)
}
Write-Ok2 "$($toAdd.standard.Count) to add to standard, $($toAdd.premium.Count) to premium, $already already entitled"

# ---------------------------------------------------------------------- write

$totalAdd = $toAdd.standard.Count + $toAdd.premium.Count
$addedOk = 0
$addFailed = @()

if ($totalAdd -eq 0) {
    Write-Host ''
    Write-Host 'Nothing to add - every resolved identity is already entitled.' -ForegroundColor Green
}
elseif ($PSCmdlet.ShouldProcess("$totalAdd principal(s)", 'Add to Entra entitlement groups')) {
    Write-Step2 'Adding members'
    foreach ($k in 'standard', 'premium') {
        $list = $toAdd[$k]
        if (-not $list.Count) { continue }

        # Graph accepts at most 20 members@odata.bind per PATCH. One request per
        # person would be far slower and rate-limit sooner on a large migration.
        for ($o = 0; $o -lt $list.Count; $o += 20) {
            $chunk = $list[$o..([Math]::Min($o + 19, $list.Count - 1))]
            $body = @{ 'members@odata.bind' = @($chunk | ForEach-Object { "$GRAPH/directoryObjects/$($_.Id)" }) } | ConvertTo-Json -Depth 4
            try {
                Invoke-RestMethod -Headers $H -Uri "$GRAPH/groups/$($targets[$k].Id)" -Method Patch `
                    -Body $body -ContentType 'application/json' | Out-Null
                $addedOk += $chunk.Count
                Write-Note2 ("{0,-10} +{1}" -f $k, $chunk.Count)
            }
            catch {
                # One bad id fails the whole batch, so fall back to singles to
                # isolate it rather than losing the other nineteen.
                foreach ($c in $chunk) {
                    try {
                        $one = @{ '@odata.id' = "$GRAPH/directoryObjects/$($c.Id)" } | ConvertTo-Json
                        Invoke-RestMethod -Headers $H -Uri "$GRAPH/groups/$($targets[$k].Id)/members/`$ref" -Method Post `
                            -Body $one -ContentType 'application/json' | Out-Null
                        $addedOk++
                    }
                    catch { $addFailed += [pscustomobject]@{ Upn = $c.Upn; Tier = $k; Error = $_.Exception.Message } }
                }
            }
        }
    }
    Write-Ok2 "$addedOk added"
    if ($addFailed.Count) {
        Write-Warn3 "$($addFailed.Count) failed:"
        $addFailed | Select-Object -First 5 | ForEach-Object { Write-Note2 "  $($_.Upn): $($_.Error)" }
    }
}

# --------------------------------------------------------------------- report

if ($ReportPath) {
    $report = @()
    foreach ($u in $unique) {
        $failed = $addFailed | Where-Object Upn -eq $u.Upn
        $report += [pscustomobject]@{
            Input    = $u.Input
            Resolved = $u.Upn
            ObjectId = $u.Id
            Tier     = $u.Tier
            MatchedBy = $u.How
            Result   = if ($failed) { "failed: $($failed.Error)" }
                       elseif ($u -in $toAdd.standard -or $u -in $toAdd.premium) { if ($WhatIfPreference) { 'would-add' } else { 'added' } }
                       else { 'already-member' }
        }
    }
    foreach ($u in $unresolved) {
        $report += [pscustomobject]@{ Input = $u.Input; Resolved = ''; ObjectId = ''; Tier = $u.Tier; MatchedBy = ''; Result = 'not-found' }
    }
    # -WhatIf:$false deliberately. The report is read-only, and a dry run is
    # exactly when you most want it - it is the artefact you hand back to
    # whoever owns the roster so they can fix the rows that did not resolve.
    $report | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    Write-Ok2 "report: $ReportPath"
}

Write-Host ''
Write-Host 'Group membership is the entitlement. Push it to the gateway with:' -ForegroundColor DarkGray
Write-Host '  ./scripts/Sync-ClaudeAccess.ps1 -ApimName <apim> -ResourceGroup <rg>' -ForegroundColor DarkGray
Write-Host ''
