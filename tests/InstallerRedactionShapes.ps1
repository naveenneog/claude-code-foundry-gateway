# The secret shapes of ADR-0047 decision 12 for the P92 round-3 tests, dot-sourced by the preflight, step
# and redaction suites: each shape with its own sentinel, the text it becomes, and one sentence that carries
# every shape, as an error that an az call returns and a preflight message or a progress event quotes. The
# sentence holds no full stop followed by a space, so both installers quote all of it as an error's first
# sentence (scripts/ClaudeInstallResume.ps1:16, scripts/install-resume.sh:20).
$script:P92Jwt = 'eyJhbGciOiJSUzI1NiJ9' + '.eyJwOTIiOiJyZWRhY3QifQ' + '.p92JwtSentinel'
$script:P92RedactionCases = @(
    [pscustomobject]@{ Shape = 'JWT'; Text = "jwt $($script:P92Jwt)"; Redacted = 'jwt [redacted]'; Sentinel = 'p92JwtSentinel' }
    [pscustomobject]@{ Shape = 'Bearer'; Text = 'Authorization: Bearer p92BearerSentinel0123'; Redacted = 'Authorization: Bearer [redacted]'; Sentinel = 'p92BearerSentinel' }
    [pscustomobject]@{ Shape = 'sig'; Text = 'https://p92.blob.core.windows.net/c?sv=2024-01-01&sig=p92SigSentinel&se=2026'; Redacted = 'https://p92.blob.core.windows.net/c?sv=2024-01-01&sig=[redacted]&se=2026'; Sentinel = 'p92SigSentinel' }
    [pscustomobject]@{ Shape = 'signature'; Text = 'signature=p92SignatureSentinel'; Redacted = 'signature=[redacted]'; Sentinel = 'p92SignatureSentinel' }
    [pscustomobject]@{ Shape = 'AccountKey'; Text = 'AccountName=p92;AccountKey=p92AccountKeySentinel==;EndpointSuffix=core'; Redacted = 'AccountName=p92;AccountKey=[redacted];EndpointSuffix=core'; Sentinel = 'p92AccountKeySentinel' }
    [pscustomobject]@{ Shape = 'SharedAccessKey'; Text = 'SharedAccessKey=p92SharedAccessKeySentinel;'; Redacted = 'SharedAccessKey=[redacted];'; Sentinel = 'p92SharedAccessKeySentinel' }
    [pscustomobject]@{ Shape = 'SharedAccessSignature'; Text = 'SharedAccessSignature: p92SharedAccessSignatureSentinel'; Redacted = 'SharedAccessSignature: [redacted]'; Sentinel = 'p92SharedAccessSignatureSentinel' }
    [pscustomobject]@{ Shape = 'client_secret'; Text = 'client_secret=p92ClientSecretSentinel&grant_type=client_credentials'; Redacted = 'client_secret=[redacted]&grant_type=client_credentials'; Sentinel = 'p92ClientSecretSentinel' }
    [pscustomobject]@{ Shape = 'clientSecret'; Text = '{"clientSecret": "p92ClientSecretCamelSentinel"}'; Redacted = '{"clientSecret": "[redacted]"}'; Sentinel = 'p92ClientSecretCamelSentinel' }
    [pscustomobject]@{ Shape = 'password'; Text = 'PASSWORD=p92PasswordSentinel'; Redacted = 'PASSWORD=[redacted]'; Sentinel = 'p92PasswordSentinel' }
    [pscustomobject]@{ Shape = 'pwd'; Text = 'pwd: p92PwdSentinel'; Redacted = 'pwd: [redacted]'; Sentinel = 'p92PwdSentinel' }
    [pscustomobject]@{ Shape = 'secret'; Text = 'secret=p92SecretSentinel'; Redacted = 'secret=[redacted]'; Sentinel = 'p92SecretSentinel' }
    [pscustomobject]@{ Shape = 'access_token'; Text = 'access_token=p92AccessTokenSentinel'; Redacted = 'access_token=[redacted]'; Sentinel = 'p92AccessTokenSentinel' }
    [pscustomobject]@{ Shape = 'refresh_token'; Text = "refresh_token: 'p92RefreshTokenSentinel'"; Redacted = "refresh_token: '[redacted]'"; Sentinel = 'p92RefreshTokenSentinel' }
)
$script:P92RedactionSentence = 'ERROR: the request was refused (' + ((@($script:P92RedactionCases) | ForEach-Object { $_.Text }) -join ' ') + ') (Authorization_RequestDenied).'

function Get-P92RedactionProblems([string]$Text, [string[]]$Shapes = @()) {
    # Each sentinel found in the text, and each shape's redacted form the text lacks (only for the given
    # shapes; every shape when none is given).
    $want = if ($Shapes.Count) { @($script:P92RedactionCases | Where-Object { $_.Shape -in $Shapes }) } else { @($script:P92RedactionCases) }
    $found = @($script:P92RedactionCases | Where-Object { $Text.Contains($_.Sentinel) } | ForEach-Object { "sentinel $($_.Sentinel)" })
    $lacking = @($want | Where-Object { -not $Text.Contains($_.Redacted) } | ForEach-Object { "no '$($_.Redacted)'" })
    return @($found + $lacking)
}
function Test-P92NoSentinel([string]$Text) { -not @($script:P92RedactionCases | Where-Object { $Text.Contains($_.Sentinel) }).Count -and -not $Text.Contains('p92RemedySentinel') -and -not $Text.Contains('eyJhbGciOiJSUzI1NiJ9') }
