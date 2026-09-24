$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'NetworkEdgeContract.ps1')
$sandbox = Join-Path $root ('shots\network-mutations-' + [guid]::NewGuid().ToString('N'))
$mutations = @(
    @('infra\network-edge.bicep', 'enableResponseBuffering: false', 'enableResponseBuffering: true'),
    @('infra\network-edge.bicep', 'param backendTimeoutSeconds int = 600', 'param backendTimeoutSeconds int = 20'),
    @('infra\network-edge.bicep', 'keyVaultSecretId: certificateSecretId', "data: 'insecure-inline-certificate'"),
    @('infra\network-edge.bicep', "headerValue: '{var_client_ip}'", "headerValue: '{http_req_X-Forwarded-For}'"),
    @('infra\network-edge.bicep', 'pickHostNameFromBackendAddress: true', 'pickHostNameFromBackendAddress: false'),
    @('infra\network-edge.bicep', 'enableHttp2: true', 'enableHttp2: false'),
    @('infra\network-edge-waf.bicep', 'requestBodyCheck: true', 'requestBodyCheck: false'),
    @('infra\network-edge-waf.bicep', 'exclusions: exclusions', 'exclusions: []'),
    @('infra\network-edge-waf.bicep', 'requestBodyEnforcement: true', 'requestBodyEnforcement: false'),
    @('infra\network-private-endpoint.bicep', 'privateDnsZoneId: zoneId', "privateDnsZoneId: ''"),
    @('scripts\New-ClaudeNetworkEdge.ps1', 'Assert-ClaudeNetworkOwnership', 'Assert-OtherOwnership'),
    @('scripts\Remove-ClaudeNetworkEdge.ps1', 'Assert-ClaudeNetworkOwnership', 'Assert-OtherOwnership'),
    @('scripts\Remove-ClaudeNetworkEdge.ps1', 'ShouldProcess', 'MayProcess')
)
$fail = 0
try {
    New-Item -ItemType Directory -Path (Join-Path $sandbox 'infra'),(Join-Path $sandbox 'scripts') -Force | Out-Null
    foreach ($file in @($mutations | ForEach-Object { $_[0] } | Sort-Object -Unique)) {
        Copy-Item (Join-Path $root $file) (Join-Path $sandbox $file)
    }
    if (@(Test-ClaudeNetworkTemplateContract $sandbox).Count) { throw 'Baseline contract is not green.' }
    foreach ($m in $mutations) {
        $path = Join-Path $sandbox $m[0]
        $text = Get-Content $path -Raw
        if (-not $text.Contains($m[1])) { throw "Mutation target not found: $($m[1])" }
        [IO.File]::WriteAllText($path, $text.Replace($m[1],$m[2]), [Text.Encoding]::UTF8)
        $caught = @(Test-ClaudeNetworkTemplateContract $sandbox).Count -gt 0
        if ($caught) { Write-Host "  [OK] caught: $($m[1])" }
        else { Write-Host "  [FAIL] escaped: $($m[1])"; $fail++ }
        [IO.File]::WriteAllText($path, $text, [Text.Encoding]::UTF8)
    }
}
finally { Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
if ($fail) { exit 1 }
Write-Host "$($mutations.Count) network mutations caught."
exit 0
