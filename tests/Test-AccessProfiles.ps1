# P116 - expanded projection records enforce model families at the gateway.
$ErrorActionPreference = 'Stop'
trap { Write-Host "  [FAIL] unexpected access-profile policy error: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

$root = Split-Path $PSScriptRoot -Parent
$policy = Get-Content (Join-Path $root 'infra\policy.xml') -Raw
$fail = 0

function Assert($label, $condition, $detail = '') {
    if ($condition) { Write-Host "  [OK]   $label" -ForegroundColor Green }
    else {
        Write-Host "  [FAIL] $label$(if ($detail) { " - $detail" })" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host ''
Write-Host 'P116 access-profile model enforcement' -ForegroundColor Cyan

Assert 'projection cache uses entitlement schema v3' (
    ([regex]::Matches($policy, 'ent:v3:\{\{tenant-id\}\}:')).Count -eq 3 -and
    $policy -notmatch 'ent:v2:\{\{tenant-id\}\}:'
)

$familyMatch = [regex]::Match($policy, '(?s)<set-variable name="modelFamily" value="@\{(.*?)\}" />')
$allowedMatch = [regex]::Match($policy, '(?s)<set-variable name="modelAllowed" value="@\{(.*?)\}" />')
Assert 'policy derives a canonical requested model family' $familyMatch.Success
Assert 'policy retains one model authorization decision' $allowedMatch.Success

foreach ($field in 'schemaVersion', 'planId', 'profileId', 'modelFamilies') {
    Assert "schema-v3 projection reads $field" ($policy -match ('rec\["' + [regex]::Escape($field) + '"\]'))
}

$projectionAt = $policy.IndexOf('<set-variable name="entSchemaVersion"')
$namedValueAt = $policy.IndexOf('<!-- 3. Resolve the tier from Entra group membership.')
Assert 'expanded projection fields are resolved only on the projection path' (
    $projectionAt -ge 0 -and $namedValueAt -gt $projectionAt
)

$modelGateAt = $policy.IndexOf('<set-variable name="modelAllowed"')
$foundryIdentityAt = $policy.IndexOf('output-token-variable-name="msi-token"')
Assert 'model refusal remains before Foundry forwarding' (
    $modelGateAt -ge 0 -and $foundryIdentityAt -gt $modelGateAt
)
$refusal = if ($modelGateAt -ge 0) { $policy.Substring($modelGateAt, [Math]::Min(3000, $policy.Length - $modelGateAt)) } else { '' }
Assert 'model refusal keeps the current Anthropic error shape' (
    $refusal -match 'code="403"' -and
    $refusal -match 'new JProperty\("type", "error"\)' -and
    $refusal -match 'new JProperty\("type", "invalid_request_error"\)' -and
    $refusal -match 'new JProperty\("code", "model_not_allowed"\)'
)

if ($familyMatch.Success -and $allowedMatch.Success) {
    $familyBody = [Net.WebUtility]::HtmlDecode($familyMatch.Groups[1].Value).Replace('context.Variables', 'variables')
    $allowedBody = [Net.WebUtility]::HtmlDecode($allowedMatch.Groups[1].Value).Replace('context.Variables', 'variables')
    foreach ($name in 'models-standard', 'models-premium') {
        $allowedBody = $allowedBody.Replace('"{{' + $name + '}}"', 'named["' + $name + '"]')
    }

    $class = 'AccessProfilePolicy' + [guid]::NewGuid().ToString('N')
    $source = @"
using System;
using System.Collections.Generic;
public class $class {
    public static string Family(Dictionary<string,object> variables) { $familyBody }
    public static bool Allowed(Dictionary<string,object> variables, Dictionary<string,string> named) { $allowedBody }
}
"@
    $references = @((Get-ChildItem (Join-Path $PSHOME 'ref') -Filter '*.dll').FullName)
    try {
        $warnings = @()
        $type = Add-Type -TypeDefinition $source -ReferencedAssemblies $references -PassThru -ErrorAction Stop `
            -IgnoreWarnings -WarningVariable warnings -WarningAction SilentlyContinue
        foreach ($warning in $warnings) {
            if ([string]$warning -notmatch 'CS1701:') { throw [string]$warning }
        }
    }
    catch {
        Write-Host "  [FAIL] policy expressions did not compile: $($_.Exception.Message)" -ForegroundColor Red
        $fail++
        $type = $null
    }

    if ($type) {
        $variables = [Collections.Generic.Dictionary[string,object]]::new()
        $named = [Collections.Generic.Dictionary[string,string]]::new()
        $named['models-standard'] = ',claude-haiku-5-5,'
        $named['models-premium'] = ',,'

        function Evaluate([string]$Model, [int]$SchemaVersion, [string]$Tier, [string]$Families) {
            $variables['modelName'] = $Model
            $variables['entSchemaVersion'] = $SchemaVersion
            $variables['tier'] = $Tier
            $variables['entModelFamilies'] = $Families
            $variables['modelFamily'] = $type::Family($variables)
            return $type::Allowed($variables, $named)
        }

        foreach ($family in 'haiku', 'sonnet', 'opus', 'fable', 'mythos') {
            Assert "schema v3 allows the $family family when present" (
                (Evaluate "claude-$family-test-deployment" 3 'standard' ",$family,")
            )
        }
        Assert 'schema v3 denies a canonical family absent from modelFamilies' (
            -not (Evaluate 'claude-opus-test-deployment' 3 'premium' ',sonnet,')
        )
        Assert 'schema v3 denies an unknown or custom deployment name' (
            -not (Evaluate 'customer-private-deployment' 3 'premium' ',haiku,sonnet,opus,fable,mythos,')
        )
        Assert 'legacy projection keeps the current empty-list allow behavior' (
            (Evaluate 'customer-private-deployment' 2 'premium' ',,')
        )
        Assert 'named-value Standard keeps exact models-standard behavior' (
            (Evaluate 'claude-haiku-5-5' 0 'standard' ',,') -and
            -not (Evaluate 'claude-sonnet-5-5' 0 'standard' ',,')
        )
        Assert 'named-value Premium keeps empty models-premium allow behavior' (
            (Evaluate 'customer-private-deployment' 0 'premium' ',,')
        )
    }
}

if ($allowedMatch.Success) {
    Assert 'client capability settings are not gateway authorization' (
        $allowedMatch.Groups[1].Value -notmatch '(?i)capabilit|connector|m365'
    )
}

Write-Host ''
if ($fail) { Write-Host "$fail access-profile policy assertion(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'P116 access-profile policy contract holds.' -ForegroundColor Green
exit 0
