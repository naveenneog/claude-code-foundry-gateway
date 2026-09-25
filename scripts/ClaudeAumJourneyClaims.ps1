# Preliminary expected-claim checks for live proof. The service /me call still
# performs signature/issuer/audience validation; decoding is not authentication.
function ConvertFrom-ClaudeAumJourneyToken {
    param([Parameter(Mandatory)][string]$Token)
    $parts=$Token.Split('.')
    if($parts.Count -ne 3){throw 'Expected an access token with three JWT segments.'}
    $body=$parts[1].Replace('-','+').Replace('_','/')
    while($body.Length % 4){$body+='='}
    try{return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($body))|ConvertFrom-Json}
    catch{throw 'Access-token claims could not be decoded.'}
}

function Assert-ClaudeAumJourneyClaims {
    param(
        [Parameter(Mandatory)]$Claims,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$PersonId,
        [ValidateSet('admin','viewer','manager')][string]$ExpectedRole,
        [string[]]$RequiredGroups=@(),
        [string[]]$ForbiddenGroups=@(),
        [int]$MinimumLifetimeSeconds=0
    )
    if($Claims.aud -ne $ClientId -or $Claims.tid -ne $TenantId -or $Claims.oid -ne $PersonId){
        throw 'Token audience, tenant or caller differs from the announced journey.'
    }
    if($Claims.roles -is [string] -or @($Claims.scp -split ' ') -notcontains 'AUM.Access'){
        throw 'Expected delegated AUM role/scope claims.'
    }
    $roles=@($Claims.roles)
    $actual=if($roles -contains 'AUM.Admin'){'admin'}elseif($roles -contains 'AUM.Viewer'){'viewer'}elseif($roles -contains 'AUM.Manager'){'manager'}else{''}
    if($actual -ne $ExpectedRole){throw 'Token role is cached, wider or different; no role-specific call is authorized.'}
    if([long]$Claims.exp -le [datetimeoffset]::UtcNow.ToUnixTimeSeconds()+$MinimumLifetimeSeconds){
        throw 'Access token has insufficient remaining lifetime for safe recovery.'
    }
    if($ExpectedRole -eq 'manager'){
        if($Claims.hasgroups -or $Claims._claim_names.groups -or $Claims.groups -is [string]){
            throw 'Overage or malformed group claims cannot prove manager scope.'
        }
        foreach($group in $RequiredGroups){
            if(@($Claims.groups) -notcontains $group){throw 'The intended manager group is absent from the token.'}
        }
        foreach($group in $ForbiddenGroups){
            if(@($Claims.groups) -contains $group){throw 'A forbidden or wider manager group is present in the token.'}
        }
    }
}
