$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$policyPath = Join-Path $root 'infra\policy.xml'
$text = Get-Content -LiteralPath $policyPath -Raw
$fail = 0

function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red; $script:fail++ }
}

$inboundMatch = [regex]::Match($text, '(?s)<inbound>(.*?)</inbound>')
$inbound = if ($inboundMatch.Success) { $inboundMatch.Groups[1].Value } else { '' }
$firstElement = [regex]::Match($inbound, '^\s*(?:<!--.*?-->\s*)*<([a-z-]+)', [Text.RegularExpressions.RegexOptions]::Singleline)
$corsMatch = [regex]::Match($inbound, '(?s)<cors\b[^>]*>(.*?)</cors>')
$cors = if ($corsMatch.Success) { $corsMatch.Groups[1].Value } else { '' }

function Get-PolicyValues($section, $name) {
    $match = [regex]::Match($section, "(?s)<$name\b[^>]*>(.*?)</$name>")
    if (-not $match.Success) { return @() }
    return @([regex]::Matches($match.Groups[1].Value, '(?s)<(?:origin|method|header)>(.*?)</(?:origin|method|header)>') |
        ForEach-Object { $_.Groups[1].Value.Trim().ToLowerInvariant() })
}

$origins = @(Get-PolicyValues $cors 'allowed-origins')
$methods = @(Get-PolicyValues $cors 'allowed-methods')
$headers = @(Get-PolicyValues $cors 'allowed-headers')
$exposed = @(Get-PolicyValues $cors 'expose-headers')
$originOk = ($origins.Count -eq 1) -and ($origins[0].Trim() -eq 'https://pivot.claude.ai')

Write-Host ''
Write-Host 'Claude Office add-in gateway policy' -ForegroundColor Cyan
Assert 'CORS is present and first in inbound' ($firstElement.Success -and $firstElement.Groups[1].Value -eq 'cors')
Assert 'only pivot.claude.ai is allowed' $originOk ($origins -join ',')
Assert 'wildcard origin is not allowed' ($origins -notcontains '*')
$missingMethods = @('get', 'post' | Where-Object { $methods -notcontains $_ })
$missingHeaders = @('authorization','content-type','accept','anthropic-version','anthropic-beta','x-api-key','x-claude-code-session-id' | Where-Object { $headers -notcontains $_ })
$missingExposed = @('x-claude-gateway-request-id','x-claude-tier' | Where-Object { $exposed -notcontains $_ })
Assert 'GET and POST are allowed' ($missingMethods.Count -eq 0) ($methods -join ',')
Assert 'authentication and Anthropic headers are allowed' ($missingHeaders.Count -eq 0) ($headers -join ',')
Assert 'gateway response headers are explicitly exposed' ($missingExposed.Count -eq 0) ($exposed -join ',')
Assert 'the existing messages operation remains POST /v1/messages' ((Get-Content (Join-Path $root 'infra\main.bicep') -Raw) -match "urlTemplate:\s+'/v1/messages'")
Assert 'the policy still validates Entra tokens' ($text -match 'validate-azure-ad-token')
Assert 'the policy still forwards with managed identity' ($text -match 'authentication-managed-identity')

Write-Host ''
if ($fail) { Write-Host "$fail check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Office gateway policy contract holds.' -ForegroundColor Green
exit 0
