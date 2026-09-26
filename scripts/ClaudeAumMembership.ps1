function New-AumMembershipPlan {
    param($Registry, [System.Collections.IDictionary]$Parents, [System.Collections.IDictionary]$Current,
          [string[]]$ScopeIds, [System.Collections.IDictionary]$Members)
    if (-not $ScopeIds.Count) { throw 'Select at least one existing scope.' }
    foreach ($id in $ScopeIds) {
        if ($id -notin @($Registry.Id)) { throw 'Selected membership scope does not exist.' }
        if (-not $Members.Contains($id)) { throw 'A selected group was not completely read. No partial refresh is allowed.' }
    }
    $map=[ordered]@{}
    foreach($key in $Current.Keys) { if($Current[$key] -notin $ScopeIds){$map[$key]=$Current[$key]} }
    $assigned=@{};$reassigned=@()
    foreach($row in @(Sort-ClaudeBuByDepth $Registry -Parents $Parents | Where-Object Id -in $ScopeIds)) {
        foreach($oid in $Members[$row.Id]) {
            if($assigned.ContainsKey($oid)){continue}
            $assigned[$oid]=$row.Id
            if($Current.Contains($oid) -and $Current[$oid] -ne $row.Id){
                $reassigned += @{ id=$oid; before=$Current[$oid]; after=$row.Id }
            }
            $map[$oid]=$row.Id
        }
    }
    return @{ Map=$map; Value=(ConvertTo-ClaudeBuMembers $map); Reassigned=$reassigned; Selected=$ScopeIds }
}
