# A query may return no records and still carry a continuation. Only absence
# of the token ends the scan. Never return partial state after a failed page.
function Get-ClaudeProjectionExisting {
    param([Parameter(Mandatory)][scriptblock]$ReadPage)
    $existing = @{}
    $seen = @{}
    $token = ''
    do {
        $page = & $ReadPage $token
        foreach ($d in @($page.Documents)) { $existing[$d.id] = $d }
        $token = [string]$page.Continuation
        if ($token) {
            if ($seen.ContainsKey($token)) { throw 'Cosmos repeated a continuation token; reconciliation refused.' }
            $seen[$token] = $true
        }
    } while ($token)
    return $existing
}
