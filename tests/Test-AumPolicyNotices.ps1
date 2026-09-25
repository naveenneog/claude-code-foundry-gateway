param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$policy = Get-Content (Join-Path $root 'infra\policy.xml') -Raw
$trace = [regex]::Match($policy, '(?s)<trace source="claude-budget".*?</trace>')
if (-not $trace.Success) { throw 'Budget trace is missing.' }
$name = 'AumTrace_' + [guid]::NewGuid().ToString('N')
$methods = @()
foreach ($spec in @(@{Name='ParentUnit'; Variable='parentUnit'},@{Name='Notice'; Variable='budgetNotice'})) {
    $node = [regex]::Match($trace.Value, '(?s)<metadata name="' + $spec.Name + '" value="(.*?)"\s*/>')
    if (-not $node.Success) { throw "Missing $($spec.Name) metadata." }
    $expression = [Net.WebUtility]::HtmlDecode($node.Groups[1].Value)
    if ($expression.StartsWith('@{')) { $body=$expression.Substring(2,$expression.Length-3) }
    elseif ($expression.StartsWith('@(')) { $body='return '+$expression.Substring(2,$expression.Length-3)+';' }
    else { throw 'Expected the actual policy expression, not a copied implementation.' }
    $methods += @"
public static string $($spec.Name)(string input) {
    var context = new Context();
    context.Variables["$($spec.Variable)"] = input;
    $body
}
"@
}
$source=@"
using System;
using System.Collections.Generic;
public static class $name {
    public class Context { public Dictionary<string, object> Variables = new Dictionary<string, object>(); }
    $($methods -join "`n")
}
"@
$type = Add-Type -TypeDefinition $source -PassThru | Where-Object Name -eq $name
foreach ($method in @('ParentUnit','Notice')) {
    foreach ($value in @('', $null)) {
        $result=$type.GetMethod($method).Invoke($null,@($value))
        if ([string]::IsNullOrEmpty($result)) { throw "$method emitted an empty trace metadata value; APIM returns 500 instead of the served model response." }
    }
}
$literal='unit;mode=allowance:100;status=estimated-over-budget'
if ($type.GetMethod('Notice').Invoke($null,@($literal)) -cne $literal) { throw 'A real notice was altered.' }
if ($type.GetMethod('ParentUnit').Invoke($null,@('contoso-unit')) -cne 'contoso-unit') { throw 'A real parent id was altered.' }
Write-Host 'Budget trace: actual policy expressions never emit empty required metadata; real values preserved.' -ForegroundColor Green
