<#
Converts the customer's 47-group sheet JSON into the gateway access catalog (config/access-catalog.example.json shape).
Fills empty objectIds from Microsoft Graph by exact display name, through REST (the names contain $ ( ) , which az.cmd
would hand to cmd.exe). Writes nothing in Entra.
#>
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$Offline   # test only: fake object ids, no Graph call
)
$ErrorActionPreference = 'Stop'
$guid = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
$src = Get-Content -Raw -LiteralPath $InputPath | ConvertFrom-Json
$capability = @{ Co = 'code'; Cw = 'cowork'; Ch = 'chat'; De = 'design' }
$byProfile = @{}; foreach ($p in $src.profiles) { $byProfile[$p.id] = $p }

# Plans (tiers): one per sheet profile - level, model set and credit - so each gets its own limits (ADR-0069).
# Standard levels map to the standard compatibility tier, Advanced and Power to premium.
$plans = [ordered]@{}
foreach ($p in $src.profiles) {
    $id = ([string]$p.id).ToLowerInvariant()
    if ($id -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$') { throw "Profile id '$($p.id)' is not a lowercase id of letters, digits and hyphens." }
    if ($plans.Contains($id)) { throw "Profile id '$id' appears twice." }
    if (-not ([decimal]$p.creditUsd -gt 0)) { throw "Profile '$id' needs a positive creditUsd." }
    $plans[$id] = [ordered]@{ id = $id; name = "$($p.level) $($p.modelSet) - `$$($p.creditUsd) nominal monthly credit"; enabled = $true
        nominalCredit = [ordered]@{ amount = [int]$p.creditUsd; currency = 'USD'; period = 'month'; scope = 'user' }
        compatibilityTier = $(if ([string]$p.level -like 'Standard-*') { 'standard' } else { 'premium' }) }
}
$token = $null
if (-not $Offline) { $token = az account get-access-token --resource-type ms-graph --query accessToken -o tsv; if (-not $token) { throw 'No Graph token; run az login.' } }
function Resolve-Group([string]$Name) {
    $escaped = $Name.Replace("'", "''")
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$([Uri]::EscapeDataString($escaped))'&`$select=id,displayName"
    $hits = @((Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }).value | Where-Object { $_.displayName -ceq $Name })
    if ($hits.Count -ne 1) { throw "Group '$Name': $($hits.Count) exact matches; set its objectId in the input." }
    return ([string]$hits[0].id).ToLowerInvariant()
}

# multipleGroupRule highest-monthly: a person in several groups gets the profile with the highest credit; ties broken by
# more model families, then more capabilities, then M365, then row. Priorities are unique, as the catalog requires.
$rows = foreach ($g in $src.groups) {
    $p = $byProfile[$g.profile]; if (-not $p) { throw "Row $($g.row): unknown profile '$($g.profile)'." }
    $families = @($src.modelSets.($p.modelSet)); if (-not $families.Count) { throw "Row $($g.row): unknown modelSet '$($p.modelSet)'." }
    $caps = @($g.capabilities | ForEach-Object { if (-not $capability.ContainsKey($_)) { throw "Row $($g.row): unknown capability '$_'." }; $capability[$_] })
    [pscustomobject]@{ Group = $g; Profile = $p; Families = $families; Caps = $caps
        Rank = ([int]$p.creditUsd * 1000000) + ($families.Count * 10000) + ($caps.Count * 100) + $(if ($g.m365) { 50 } else { 0 }) }
}
$priority = 0
$profiles = foreach ($r in @($rows | Sort-Object Rank, { $_.Group.row })) {
    $priority++
    $g = $r.Group
    $oid = [string]$g.objectId
    if (-not $oid) { $oid = if ($Offline) { '00000000-0000-4000-8000-{0:d12}' -f [int]$g.row } else { Resolve-Group $g.displayName } }
    if ($oid -notmatch $guid) { throw "Row $($g.row): objectId '$oid' is not a GUID." }
    $suffix = (($g.capabilities -join '-') + $(if ($g.m365) { '-m365' } else { '' })).ToLowerInvariant()
    [ordered]@{
        id = "$($r.Profile.id)-$suffix-r$($g.row)"; name = $g.displayName; planId = ([string]$r.Profile.id).ToLowerInvariant()
        groupObjectId = $oid.ToLowerInvariant(); priority = $priority; capabilities = @($r.Caps); modelFamilies = @($r.Families)
        connectors = @(if ($g.m365) { 'm365' }); enabled = $true
    }
}
$tenant = [string]$src.gateway.tenantId
if ($tenant -notmatch $guid) { if ($Offline) { $tenant = '00000000-0000-4000-8000-0000000000aa' } else { throw 'gateway.tenantId is not a GUID.' } }
$catalog = [ordered]@{ schemaVersion = 1; tenantId = $tenant.ToLowerInvariant(); plans = @($plans.Values); profiles = @($profiles) }
$catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Wrote $OutputPath : $(@($catalog.plans).Count) plans, $(@($catalog.profiles).Count) profiles."
