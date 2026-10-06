param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$root = if ($RepositoryRoot) { $RepositoryRoot } else { Split-Path $PSScriptRoot -Parent }
$script:assertions = 0
$script:failures = 0
function Assert-Harness($Name,$Condition,$Detail='') { $script:assertions++; if($Condition){ Write-Host "  [OK] $Name" } else { $script:failures++; Write-Host "  [FAIL] $Name $Detail" } }
function ConvertTo-Hash($Object) { $Object | ConvertTo-Json -Depth 30 -Compress }
function New-StubResponse([int]$StatusCode, $Body) { [pscustomobject]@{ StatusCode=$StatusCode; Body=$Body } }
function Test-ContentSafetyPolicyAllowedTypes {
    param([Parameter(Mandatory)][string]$FragmentText)
    $decoded = [System.Net.WebUtility]::HtmlDecode($FragmentText)
    $violations = [Collections.Generic.List[string]]::new()
    if ($decoded -match '(?m)(^|[^\w.])(System\.)?Action\s*<') {
        $violations.Add('System.Action delegate variables are not allowed in APIM policy expressions.') | Out-Null
    }
    if ($decoded -match '(?m)(^|[^\w.])(System\.)?Func\s*<') {
        $violations.Add('System.Func delegate variables are not allowed in APIM policy expressions.') | Out-Null
    }
    if ($decoded -match 'object\.ReferenceEquals') {
        $violations.Add('System.Object/object.ReferenceEquals is not listed in the APIM allowed CLR type table.') | Out-Null
    }
    if ($decoded -match '=>') {
        $violations.Add('Lambda expressions are not used by this fragment because APIM documents C# 7 policy expressions and allowed CLR types, but does not list delegate variable types.') | Out-Null
    }
    [pscustomobject]@{
        Pass = ($violations.Count -eq 0)
        Violations = @($violations)
        Citation = 'Microsoft Learn, Azure API Management policy expressions, .NET Framework types allowed in policy expressions, read 2026-10-07.'
    }
}
function New-ContentSafetyAnalyzeBody {
    param([int]$Hate = 0, [int]$Violence = 0, [int]$SelfHarm = 0, [int]$Sexual = 0)
    [pscustomobject]@{ categoriesAnalysis = @(
        [pscustomobject]@{ category = 'Hate'; severity = $Hate },
        [pscustomobject]@{ category = 'SelfHarm'; severity = $SelfHarm },
        [pscustomobject]@{ category = 'Sexual'; severity = $Sexual },
        [pscustomobject]@{ category = 'Violence'; severity = $Violence }
    ) }
}
function New-ContentSafetyShieldBody {
    param([bool]$UserAttack = $false, [bool[]]$DocumentAttacks = @())
    [pscustomobject]@{
        userPromptAnalysis = [pscustomobject]@{ attackDetected = $UserAttack }
        documentsAnalysis = @($DocumentAttacks | ForEach-Object { [pscustomobject]@{ attackDetected = [bool]$_ } })
    }
}
function New-ContentSafetyStubMap {
    param($ShieldBody, $AnalyzeBody, [int]$ShieldStatus = 200, [int]$AnalyzeStatus = 200, [switch]$ShieldTimeout, [switch]$AnalyzeTimeout)
    $map = @{}
    $map.shieldPrompt = if ($ShieldTimeout) { $null } else { New-StubResponse $ShieldStatus $ShieldBody }
    $map.analyze = if ($AnalyzeTimeout) { $null } else { New-StubResponse $AnalyzeStatus $AnalyzeBody }
    $map
}
function Get-DefaultContentSafetyStubs { New-ContentSafetyStubMap (New-ContentSafetyShieldBody) (New-ContentSafetyAnalyzeBody) }
function ConvertTo-JsonText($Value) {
    if ($Value -is [string]) { return $Value }
    $Value | ConvertTo-Json -Depth 40 -Compress
}
function ConvertFrom-JsonText($Text) {
    if ([string]::IsNullOrWhiteSpace([string]$Text)) { return $null }
    try { return $Text | ConvertFrom-Json -Depth 80 } catch { return $Text }
}
function ConvertTo-PlainHash($Dictionary) {
    $h = [ordered]@{}
    foreach ($key in $Dictionary.Keys) { $h[$key] = $Dictionary[$key] }
    $h
}
function Get-PolicyExpressionBody([string]$Text) {
    $trimmed = $Text.Trim()
    if ($trimmed.StartsWith('@(') -and $trimmed.EndsWith(')')) { return @{ Kind='single'; Code=$trimmed.Substring(2, $trimmed.Length - 3) } }
    if ($trimmed.StartsWith('@{') -and $trimmed.EndsWith('}')) { return @{ Kind='block'; Code=$trimmed.Substring(2, $trimmed.Length - 3) } }
    return $null
}
function Add-CollectedExpression([Collections.Generic.List[string]]$Expressions, [string]$Text) {
    if ($null -eq $Text) { return }
    if (Get-PolicyExpressionBody $Text) { [void]$Expressions.Add($Text.Trim()) }
}
function Add-XmlExpressions($Node, [Collections.Generic.List[string]]$Expressions) {
    if ($Node.NodeType -ne [System.Xml.XmlNodeType]::Element) { return }
    foreach ($attr in @($Node.Attributes)) { Add-CollectedExpression $Expressions $attr.Value }
    foreach ($child in @($Node.ChildNodes)) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) { Add-XmlExpressions $child $Expressions }
        elseif ($child.NodeType -eq [System.Xml.XmlNodeType]::Text -or $child.NodeType -eq [System.Xml.XmlNodeType]::CDATA) { Add-CollectedExpression $Expressions $child.Value }
    }
}
function Get-ExpressionReferences {
    $refs = @([Newtonsoft.Json.Linq.JObject].Assembly.Location)
    foreach ($name in @('System.Runtime','netstandard','System.Linq','System.Collections')) { $refs += $name }
    $refs
}
function New-ExpressionHost($Xml, [hashtable]$NamedValues) {
    $expressions = [Collections.Generic.List[string]]::new()
    Add-XmlExpressions $Xml.DocumentElement $expressions
    $map = [ordered]@{}
    $unique = @($expressions | Select-Object -Unique)
    $ns = 'P102PolicyRuntime' + [Guid]::NewGuid().ToString('N')
    $typeName = 'Expressions'
    $methods = [Text.StringBuilder]::new()
    $index = 0
    foreach ($expr in $unique) {
        $parsed = Get-PolicyExpressionBody $expr
        $method = 'Eval' + $index
        $map[$expr] = $method
        if ($parsed.Kind -eq 'single') { [void]$methods.AppendLine("  public static object $method(ApimContext context) { return (object)(" + $parsed.Code + "); }") }
        else { [void]$methods.AppendLine("  public static object $method(ApimContext context) { " + $parsed.Code + " }") }
        $index++
    }
    $source = @"
namespace $ns {
using System;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
public class ApimContext { public ApimRequest Request { get; set; } = new ApimRequest(); public Dictionary<string, object> Variables { get; set; } = new Dictionary<string, object>(); }
public class ApimRequest { public ApimMessageBody Body { get; set; } = new ApimMessageBody(""); }
public class ApimMessageBody {
  private readonly string body;
  public ApimMessageBody(string body) { this.body = body ?? ""; }
  public T As<T>(bool preserveContent = false) {
    var target = typeof(T);
    if (target == typeof(string)) { return (T)(object)body; }
    if (target == typeof(JObject)) { return (T)(object)JObject.Parse(body); }
    if (target == typeof(JArray)) { return (T)(object)JArray.Parse(body); }
    if (target == typeof(JToken)) { return (T)(object)JToken.Parse(body); }
    throw new InvalidOperationException("Unsupported body type " + target.FullName);
  }
}
public interface IResponse { int StatusCode { get; } ApimMessageBody Body { get; } }
public class ApimResponse : IResponse { public int StatusCode { get; set; } public ApimMessageBody Body { get; set; } = new ApimMessageBody(""); }
public static class $typeName {
$($methods.ToString())
}
}
"@
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies (Get-ExpressionReferences) -CompilerOptions '/nowarn:1701' | Out-Null
    [pscustomobject]@{ Type = [type]"$ns.$typeName"; ContextType = [type]"$ns.ApimContext"; BodyType = [type]"$ns.ApimMessageBody"; ResponseType = [type]"$ns.ApimResponse"; Map = $map }
}function Resolve-NamedValues([string]$Text, [hashtable]$NamedValues) {
    $result = $Text
    foreach ($key in $NamedValues.Keys) { $result = $result.Replace('{{' + $key + '}}', [string]$NamedValues[$key]) }
    if ($result -match '{{[^}]+}}') { throw "Unresolved named value in policy fragment: $($Matches[0])" }
    $result
}
function Invoke-CompiledExpression($HostInfo, [string]$Text, $Context) {
    if ($null -eq $Text) { return $null }
    $trimmed = $Text.Trim()
    if (-not (Get-PolicyExpressionBody $trimmed)) { return $Text }
    $method = [string]$HostInfo.Map[$trimmed]
    if (-not $method) { throw "Expression was not compiled: $trimmed" }
    $HostInfo.Type.GetMethod($method).Invoke($null, @($Context))
}
function New-ApimContext($HostInfo, [string]$BodyJson) {
    $ctx = [Activator]::CreateInstance($HostInfo.ContextType)
    $ctx.Request.Body = $HostInfo.BodyType.GetConstructor([type[]]@([string])).Invoke([object[]]@([string]$BodyJson))
    $ctx
}
function Set-ApimVariable($Context, [string]$Name, $Value) { $Context.Variables[$Name] = $Value }
function Get-ElementChildren($Node) { @($Node.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element }) }
function Assert-KnownAttributes($Node, [string[]]$Allowed) {
    foreach ($attr in @($Node.Attributes)) { if ($Allowed -notcontains $attr.Name) { throw "Unsupported attribute '$($attr.Name)' on <$($Node.LocalName)>" } }
}
function Get-ElementInnerValue($HostInfo, $Node, $Context) { Invoke-CompiledExpression $HostInfo $Node.InnerText $Context }
function Invoke-PolicyNodes($Nodes, $HostInfo, $Context, [Collections.Generic.List[object]]$Calls, [System.Collections.Specialized.OrderedDictionary]$Trace, [hashtable]$Stubs) {
    foreach ($node in @($Nodes)) {
        switch ($node.LocalName) {
            'choose' {
                Assert-KnownAttributes $node @()
                $matched = $false
                foreach ($child in (Get-ElementChildren $node)) {
                    if ($child.LocalName -eq 'when') {
                        Assert-KnownAttributes $child @('condition')
                        $condition = [bool](Invoke-CompiledExpression $HostInfo $child.GetAttribute('condition') $Context)
                        if ($condition) {
                            $result = Invoke-PolicyNodes (Get-ElementChildren $child) $HostInfo $Context $Calls $Trace $Stubs
                            if ($null -ne $result) { return $result }
                            $matched = $true; break
                        }
                    } elseif ($child.LocalName -eq 'otherwise') {
                        if (-not $matched) {
                            Assert-KnownAttributes $child @()
                            $result = Invoke-PolicyNodes (Get-ElementChildren $child) $HostInfo $Context $Calls $Trace $Stubs
                            if ($null -ne $result) { return $result }
                            $matched = $true; break
                        }
                    } else { throw "Unsupported <choose> child <$($child.LocalName)>" }
                }
            }
            'set-variable' {
                Assert-KnownAttributes $node @('name','value')
                Set-ApimVariable $Context $node.GetAttribute('name') (Invoke-CompiledExpression $HostInfo $node.GetAttribute('value') $Context)
            }
            'send-request' {
                Assert-KnownAttributes $node @('mode','response-variable-name','timeout','ignore-error')
                $req = [ordered]@{ Url=''; Method=''; Headers=[ordered]@{}; Body=$null }
                foreach ($child in (Get-ElementChildren $node)) {
                    switch ($child.LocalName) {
                        'set-url' { Assert-KnownAttributes $child @(); $req.Url = [string](Get-ElementInnerValue $HostInfo $child $Context) }
                        'set-method' { Assert-KnownAttributes $child @(); $req.Method = [string](Get-ElementInnerValue $HostInfo $child $Context) }
                        'set-header' {
                            Assert-KnownAttributes $child @('name','exists-action')
                            $values = @()
                            foreach ($v in (Get-ElementChildren $child)) { if ($v.LocalName -ne 'value') { throw "Unsupported <set-header> child <$($v.LocalName)>" }; Assert-KnownAttributes $v @(); $values += [string](Get-ElementInnerValue $HostInfo $v $Context) }
                            $req.Headers[$child.GetAttribute('name')] = $values
                        }
                        'set-body' { Assert-KnownAttributes $child @(); $bodyText = [string](Get-ElementInnerValue $HostInfo $child $Context); $req.Body = ConvertFrom-JsonText $bodyText }
                        'authentication-managed-identity' { Assert-KnownAttributes $child @('resource','client-id','ignore-error','output-token-variable-name') }
                        default { throw "Unsupported <send-request> child <$($child.LocalName)>" }
                    }
                }
                $operation = if ($req.Url -match '/contentsafety/text:(shieldPrompt|analyze)') { $Matches[1] } else { throw "Unsupported send-request URL '$($req.Url)'" }
                $Calls.Add([pscustomobject]@{ Operation=$operation; Url=$req.Url; Method=$req.Method; Headers=[pscustomobject]$req.Headers; Body=$req.Body }) | Out-Null
                $responseName = $node.GetAttribute('response-variable-name')
                $stub = $Stubs[$operation]
                if ($null -eq $stub) { Set-ApimVariable $Context $responseName $null }
                else {
                    $response = [Activator]::CreateInstance($HostInfo.ResponseType)
                    $response.StatusCode = [int]$stub.StatusCode
                    $response.Body = $HostInfo.BodyType.GetConstructor([type[]]@([string])).Invoke([object[]]@([string](ConvertTo-JsonText $stub.Body)))
                    Set-ApimVariable $Context $responseName $response
                }
            }
            'trace' {
                Assert-KnownAttributes $node @('source','severity')
                foreach ($child in (Get-ElementChildren $node)) {
                    if ($child.LocalName -eq 'message') { Assert-KnownAttributes $child @(); continue }
                    if ($child.LocalName -ne 'metadata') { throw "Unsupported <trace> child <$($child.LocalName)>" }
                    Assert-KnownAttributes $child @('name','value')
                    $Trace[$child.GetAttribute('name')] = [string](Invoke-CompiledExpression $HostInfo $child.GetAttribute('value') $Context)
                }
            }
            'return-response' {
                Assert-KnownAttributes $node @()
                $status = 200; $reason = ''; $headers = [ordered]@{}; $bodyText = ''
                foreach ($child in (Get-ElementChildren $node)) {
                    switch ($child.LocalName) {
                        'set-status' { Assert-KnownAttributes $child @('code','reason'); $status = [int](Invoke-CompiledExpression $HostInfo $child.GetAttribute('code') $Context); $reason = [string](Invoke-CompiledExpression $HostInfo $child.GetAttribute('reason') $Context) }
                        'set-header' {
                            Assert-KnownAttributes $child @('name','exists-action')
                            $values = @(); foreach ($v in (Get-ElementChildren $child)) { if ($v.LocalName -ne 'value') { throw "Unsupported <set-header> child <$($v.LocalName)>" }; Assert-KnownAttributes $v @(); $values += [string](Get-ElementInnerValue $HostInfo $v $Context) }
                            $headers[$child.GetAttribute('name')] = $values
                        }
                        'set-body' { Assert-KnownAttributes $child @(); $bodyText = [string](Get-ElementInnerValue $HostInfo $child $Context) }
                        default { throw "Unsupported <return-response> child <$($child.LocalName)>" }
                    }
                }
                return [pscustomobject]@{ Status=$status; Reason=$reason; Headers=[pscustomobject]$headers; Body=ConvertFrom-JsonText $bodyText; BodyText=$bodyText }
            }
            default { throw "Unsupported policy element <$($node.LocalName)>" }
        }
    }
    $null
}
function Invoke-ContentSafetyFragmentHarness {
    param(
        [Parameter(Mandatory)][string]$BodyJson,
        [ValidateSet('off','audit','block')][string]$Mode='block',
        [int]$Threshold=2,
        [hashtable]$Responses,
        [hashtable]$NamedValues
    )
    $fixture = @{ 'content-safety-mode'=$Mode; 'content-safety-endpoint'='https://example.cognitiveservices.azure.com'; 'content-safety-threshold'=[string]$Threshold; 'content-safety-timeout-seconds'='3'; 'content-safety-truncate-mode'='newest' }
    if ($NamedValues) { foreach ($key in $NamedValues.Keys) { $fixture[$key] = $NamedValues[$key] } }
    $fragmentText = Get-Content (Join-Path $root 'infra\content-safety-screening.xml') -Raw
    $fragmentText = Resolve-NamedValues $fragmentText $fixture
    $xml = [xml]$fragmentText
    if ($xml.DocumentElement.LocalName -ne 'fragment') { throw "Expected <fragment>, got <$($xml.DocumentElement.LocalName)>" }
    Assert-KnownAttributes $xml.DocumentElement @()
    $hostInfo = New-ExpressionHost $xml $fixture
    $ctx = New-ApimContext $hostInfo $BodyJson
    $calls = [Collections.Generic.List[object]]::new()
    $trace = [ordered]@{}
    $stubs = if ($Responses) { $Responses } else { Get-DefaultContentSafetyStubs }
    $return = Invoke-PolicyNodes (Get-ElementChildren $xml.DocumentElement) $hostInfo $ctx $calls $trace $stubs
    $slice = if ($ctx.Variables.ContainsKey('contentSafetySlice')) { ConvertFrom-JsonText ([string]$ctx.Variables['contentSafetySlice']) } else { $null }
    $decision = if ($ctx.Variables.ContainsKey('contentSafetyDecisionJson')) { ConvertFrom-JsonText ([string]$ctx.Variables['contentSafetyDecisionJson']) } else { $null }
    $forwarded = $null -eq $return
    [pscustomobject]@{
        StatusCode = if ($return) { [int]$return.Status } else { 200 }
        Calls = @($calls)
        Variables = [pscustomobject](ConvertTo-PlainHash $ctx.Variables)
        Trace = [pscustomobject]$trace
        Slice = $slice
        Decision = if ($decision) { [pscustomobject]@{ WouldBlock = ([string]$decision.blockedBy -ne '' -and [string]$decision.blockedBy -ne 'unavailable'); BlockedBy = [string]$decision.blockedBy; Raw = $decision } } else { [pscustomobject]@{ WouldBlock=$false; BlockedBy=''; Raw=$null } }
        ReturnResponse = $return
        Forwarded = $forwarded
        Status = if ($forwarded) { 'forwarded' } else { 'return-response' }
        Error = if ($return) { $return.Body } else { $null }
        ResponseBody = if ($return) { $return.Body } else { $null }
    }
}
