<#
.SYNOPSIS
    Populates the entitlement projection in Cosmos from Microsoft Entra groups.

.DESCRIPTION
    The write side of ADR-0005. Sync-ClaudeAccess.ps1 writes the same membership
    into API Management named values; this writes it into Cosmos, using the same
    Graph resolution so the two cannot disagree about who is in a group.

    Both are written while entitlement-source is 'named-value', which is what
    makes the shadow comparison possible: the projection can be populated,
    watched and compared for as long as an operator wants before anything reads
    it. ADR-0009 phase 1 is schema and population; authorisation does not move
    until the switch is flipped.

    Cosmos here has local authentication disabled, so there is no key to hold.
    Writes go over the data plane with an Entra token, which means the caller
    needs a Cosmos data-plane role assignment - see -WhatIf output for the
    command that grants it.

.PARAMETER Account
    Cosmos account name. Defaults to cosmos-<prefix> as projection.bicep names it.

.PARAMETER WhatIf
    Resolve and report, writing nothing. Use this first on a live directory.

.EXAMPLE
    ./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-claude-gw-fzgql9 -WhatIf

.EXAMPLE
    ./scripts/Sync-ClaudeProjection.ps1 -Account cosmos-claude-gw-fzgql9
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)][string]$Account,
    [string]$Database = 'claude',
    [string]$Container = 'entitlement',
    [string]$TenantId,

    [string]$StandardGroup = 'claude-code-standard',
    [string]$PremiumGroup = 'claude-code-premium',

    [string]$ConfigPath,

    # Business unit groups, as bu-registry records them: id=group-name.
    [string[]]$BusinessUnitGroups,

    # A resync after a directory outage can legitimately resolve fewer people.
    # A resync that resolves nobody is almost always a failure to read Graph,
    # and deleting every record on the strength of it is unrecoverable without
    # another sync. Refused unless the operator says otherwise.
    [switch]$AllowEmpty,

    # Records for identities no longer in any group are removed, because the
    # resolver treats an absent record as not entitled. Keeping them would leave
    # access behind after a removal, which is the failure this whole accelerator
    # is built to avoid.
    [switch]$KeepOrphans
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeGraphMembership.ps1')

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Note($m) { Write-Host "         $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- config file
if ($ConfigPath) {
    try {
        $raw = if ($ConfigPath -match '^https?://') {
            (Invoke-WebRequest -Uri $ConfigPath -UseBasicParsing -TimeoutSec 30).Content
        } else { Get-Content $ConfigPath -Raw }
        $cfg = $raw | ConvertFrom-Json
        if (-not $TenantId -and $cfg.tenantId) { $TenantId = $cfg.tenantId }
        if ($cfg.standardGroup) { $StandardGroup = $cfg.standardGroup }
        if ($cfg.premiumGroup)  { $PremiumGroup  = $cfg.premiumGroup }
        Ok "loaded from $ConfigPath"
    } catch { Write-Warning "Could not read $ConfigPath - $($_.Exception.Message)" }
}

Write-Host ''
Write-Host 'Entra groups -> entitlement projection' -ForegroundColor Cyan
Write-Host "Account  : $Account"
Write-Host "Container: $Database/$Container"

# ---------------------------------------------------------------- 1. identity
Step 'Signing in'
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { Bad "Run 'az login' first."; exit 1 }
if (-not $TenantId) { $TenantId = $acct.tenantId }
Ok "$($acct.user.name)  tenant $TenantId"

# The projection records the tenant on every document, and the resolver refuses
# a record from another one. Writing records stamped with a tenant the operator
# is not signed in to would produce a projection nothing will ever honour.
if ($acct.tenantId -ne $TenantId) {
    Bad "Signed in to $($acct.tenantId) but asked to stamp records with $TenantId."
    Note 'The resolver refuses a record whose tenantId does not match its own,'
    Note 'so these records would be written and then never honoured.'
    Note "  az login --tenant $TenantId"
    exit 1
}

$graphToken = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>$null
if (-not $graphToken) { Bad 'Could not get a Microsoft Graph token.'; exit 1 }

$cosmosToken = az account get-access-token --resource https://cosmos.azure.com --query accessToken -o tsv 2>$null
if (-not $cosmosToken) { Bad 'Could not get a Cosmos data-plane token.'; exit 1 }
# Resolved once, here, rather than inside a message: a command substitution in
# a string still runs under -WhatIf, and a redirect inside it makes PowerShell
# prompt about writing a file that has nothing to do with this script.
$signedInOid = az ad signed-in-user show --query id -o tsv 2>$null
if ($signedInOid) { $signedInOid = $signedInOid.Trim() } else { $signedInOid = '<your-object-id>' }
Ok 'Graph and Cosmos tokens acquired'

# ---------------------------------------------------------------- 2. resolve
Step 'Reading group membership'
$byOid = @{}

foreach ($t in @(
    @{ Name = 'premium';  Group = $PremiumGroup },
    @{ Name = 'standard'; Group = $StandardGroup })) {
    $members = @(Get-GroupMemberOids -GroupName $t.Group -Token $graphToken)
    Write-Host ("  {0,-10} {1,-32} {2} member(s)" -f $t.Name, $t.Group, $members.Count)
    foreach ($m in $members) {
        # Premium is read first and wins, matching the policy, which checks the
        # premium list before the standard one. Someone in both groups is
        # premium in the gateway, so the projection must say the same.
        if (-not $byOid.ContainsKey($m.Oid)) {
            $byOid[$m.Oid] = [pscustomobject]@{ Oid = $m.Oid; Name = $m.Name; Tier = $t.Name; BusinessUnit = '' }
        }
    }
}

if ($BusinessUnitGroups) {
    Step 'Reading business unit membership'
    foreach ($spec in $BusinessUnitGroups) {
        $parts = $spec -split '=', 2
        if ($parts.Count -ne 2) { Write-Warning "Skipping '$spec' - expected id=group-name"; continue }
        $unit = $parts[0].Trim(); $grp = $parts[1].Trim()
        $bm = @(Get-GroupMemberOids -GroupName $grp -Token $graphToken)
        Write-Host ("  {0,-22} {1,-30} {2} member(s)" -f $unit, $grp, $bm.Count)
        foreach ($m in $bm) {
            if ($byOid.ContainsKey($m.Oid)) { $byOid[$m.Oid].BusinessUnit = $unit }
            else { Note "  $($m.Name) is in $unit but no tier - not entitled, so not projected" }
        }
    }
}

$resolved = @($byOid.Values)
Write-Host ''
Ok "$($resolved.Count) entitled identity(ies) resolved"

# ---------------------------------------------------------------- 3. existing
Step 'Reading what the projection holds now'
$base = "https://$Account.documents.azure.com"
$authHeader = "type=aad&ver=1.0&sig=$cosmosToken"

function Invoke-Cosmos {
    param([string]$Method, [string]$Path, [string]$ResourceType, [string]$ResourceLink,
          [hashtable]$Extra = @{}, [string]$Body)
    $h = @{
        'Authorization' = [uri]::EscapeDataString($authHeader)
        'x-ms-version'  = '2018-12-31'
        'x-ms-date'     = [DateTime]::UtcNow.ToString('r')
        'Accept'        = 'application/json'
    }
    foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    $p = @{ Uri = "$base$Path"; Method = $Method; Headers = $h; ContentType = 'application/json'; TimeoutSec = 60 }
    if ($Body) { $p['Body'] = $Body }
    Invoke-RestMethod @p
}

$existing = @{}
try {
    $q = @{ query = 'SELECT c.id, c.oid, c.tier, c.businessUnit, c.mappingVersion FROM c' } | ConvertTo-Json -Compress
    $r = Invoke-Cosmos -Method POST -Path "/dbs/$Database/colls/$Container/docs" `
            -Extra @{ 'x-ms-documentdb-isquery' = 'True'
                      'Content-Type'            = 'application/query+json'
                      'x-ms-documentdb-query-enablecrosspartition' = 'True' } `
            -Body $q
    foreach ($d in @($r.Documents)) { $existing[$d.id] = $d }
    Ok "$($existing.Count) record(s) already there"
}
catch {
    $code = 0
    if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    $body = ''
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }

    # A 403 from Cosmos has more than one cause and they need different people
    # to fix them. Read what it said rather than assuming: measured on a real
    # account where the message was a firewall block and the obvious guess was
    # a missing data-plane role.
    if ($code -eq 403 -and $body -match 'firewall|public internet|blocked by your') {
        Bad 'Forbidden by the Cosmos firewall, not by a role.'
        $ip = ''
        if ($body -match 'IP ([0-9.]+)') { $ip = $Matches[1] }
        if ($ip) { Note "This machine came from $ip, which the account does not allow." }
        Note 'Whoever owns the account decides this. Either it is reachable from'
        Note 'where the sync runs, or the sync runs somewhere it is reachable from.'
        Note ''
        Note "  az cosmosdb show -n $Account -g <rg> --query ""{public:publicNetworkAccess, ipRules:ipRules}"""
        Note ''
        Note 'publicNetworkAccess Disabled means only a private endpoint reaches it,'
        Note 'which no laptop has. An Azure Policy can set that without anyone'
        Note 'choosing it, so check before assuming the template did.'
        exit 1
    }
    if ($code -eq 403) {
        Bad 'Forbidden reading the container, and the message does not mention the firewall.'
        Note 'That leaves the data-plane role. Control-plane roles such as Contributor'
        Note 'do not grant data access here, and a new assignment takes a few minutes.'
        Note ''
        Note 'az cosmosdb sql role assignment create \'
        Note "  --account-name $Account --resource-group <rg> \"
        Note '  --role-definition-name "Cosmos DB Built-in Data Contributor" \'
        Note "  --principal-id $signedInOid \"
        Note '  --scope /'
        if ($body) { Note ''; Note "Cosmos said: $(($body -split "`r?`n")[0])" }
        exit 1
    }
    Bad "Could not read the container: $($_.Exception.Message)"
    if ($body) { Note (($body -split "`r?`n")[0]) }
    exit 1
}

# ---------------------------------------------------------------- 4. compare
Step 'What would change'
$mappingVersion = [int][double]::Parse((Get-Date -UFormat %s))
$toWrite = @()
$unchanged = 0
foreach ($r in $resolved) {
    $cur = $existing[$r.Oid]
    if ($cur) {
        # No ?? here: Windows PowerShell 5.1 is what an admin's box runs.
        $curBu = ''
        if ($cur.businessUnit) { $curBu = $cur.businessUnit }
        if ($cur.tier -eq $r.Tier -and $curBu -eq $r.BusinessUnit) { $unchanged++; continue }
    }
    $toWrite += $r
}
$orphans = @($existing.Keys | Where-Object { -not $byOid.ContainsKey($_) })

Write-Host ("  {0,6}  unchanged" -f $unchanged)
Write-Host ("  {0,6}  to write" -f $toWrite.Count)
Write-Host ("  {0,6}  no longer entitled" -f $orphans.Count)

if ($resolved.Count -eq 0 -and $existing.Count -gt 0 -and -not $AllowEmpty) {
    Write-Host ''
    Bad "Groups resolved to nobody while the projection holds $($existing.Count) record(s)."
    Note 'Removing them all would revoke everyone, and a directory that cannot be'
    Note 'read looks exactly like a directory with nobody in it. Refusing.'
    Note 'Check the group names and that you can read their membership, then'
    Note 're-run with -AllowEmpty if the emptiness is real.'
    exit 1
}

if ($WhatIfPreference) {
    Write-Host ''
    Note 'WhatIf: nothing written.'
    foreach ($r in $toWrite | Select-Object -First 10) { Note "  would write $($r.Oid)  $($r.Tier)  $($r.BusinessUnit)" }
    if ($toWrite.Count -gt 10) { Note "  ... and $($toWrite.Count - 10) more" }
    foreach ($o in $orphans | Select-Object -First 10) { Note "  would remove $o" }
    exit 0
}

# ---------------------------------------------------------------- 5. write
Step 'Writing'
$written = 0; $failed = 0
foreach ($r in $toWrite) {
    $doc = @{
        id             = $r.Oid
        oid            = $r.Oid
        tenantId       = $TenantId
        tier           = $r.Tier
        businessUnit   = $r.BusinessUnit
        mappingVersion = $mappingVersion
        effectiveFrom  = $null
    } | ConvertTo-Json -Compress
    try {
        Invoke-Cosmos -Method POST -Path "/dbs/$Database/colls/$Container/docs" `
            -Extra @{ 'x-ms-documentdb-is-upsert' = 'True'
                      'x-ms-documentdb-partitionkey' = "[""$($r.Oid)""]" } `
            -Body $doc | Out-Null
        $written++
    }
    catch { $failed++; Write-Warning "  $($r.Oid): $($_.Exception.Message)" }
}
Ok "$written record(s) written"
if ($failed) { Bad "$failed record(s) failed" }

$removed = 0
if ($orphans.Count -gt 0 -and -not $KeepOrphans) {
    foreach ($o in $orphans) {
        try {
            Invoke-Cosmos -Method DELETE -Path "/dbs/$Database/colls/$Container/docs/$o" `
                -Extra @{ 'x-ms-documentdb-partitionkey' = "[""$o""]" } | Out-Null
            $removed++
        } catch { Write-Warning "  could not remove $o : $($_.Exception.Message)" }
    }
    Ok "$removed record(s) removed"
}
elseif ($orphans.Count -gt 0) {
    Write-Host "  [WARN] $($orphans.Count) orphan(s) kept (-KeepOrphans)" -ForegroundColor Yellow
    Note 'Those identities are no longer in any group and are still entitled by'
    Note 'the projection. The resolver has no way to know they should not be.'
}

Write-Host ''
Write-Host "Projection now holds $($unchanged + $written) entitled identity(ies)." -ForegroundColor Green
Note "mappingVersion $mappingVersion - a cached answer can be traced to this run."
Write-Host ''
Note 'This changes nothing about who the gateway lets in. Authorisation moves'
Note "only when entitlement-source is set to 'projection'; until then this is"
Note 'a shadow copy to compare against. Compare-ClaudeEntitlement.ps1 does that.'
Write-Host ''
