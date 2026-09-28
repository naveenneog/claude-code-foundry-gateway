# Read imports without executing a renderer. Unsupported/dynamic paths fail the coverage check.
function Get-ScriptDotSourceClosure {
    param([Parameter(Mandatory = $true)][string]$Path)
    $seen = @{}
    function Resolve-ImportExpression($Node, [string]$Directory, $Assignments, [string[]]$Resolving = @()) {
        if ($Node -is [Management.Automation.Language.StringConstantExpressionAst]) { return [string]$Node.Value }
        if ($Node -is [Management.Automation.Language.VariableExpressionAst]) {
            $name = $Node.VariablePath.UserPath
            if ($name -eq 'PSScriptRoot') { return $Directory }
            $definitions = @($Assignments | Where-Object {
                $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $_.Left.VariablePath.UserPath -eq $name -and $_.Extent.EndOffset -lt $Node.Extent.StartOffset
            })
            if ($name -notin $Resolving -and $definitions.Count -eq 1) {
                return Resolve-ImportExpression $definitions[0].Right $Directory $Assignments @($Resolving + $name)
            }
        }
        elseif ($Node -is [Management.Automation.Language.ExpandableStringExpressionAst]) {
            $value = $Node.Value
            foreach ($expression in $Node.NestedExpressions) {
                $value = $value.Replace($expression.Extent.Text, (Resolve-ImportExpression $expression $Directory $Assignments $Resolving))
            }
            return $value
        }
        elseif ($Node -is [Management.Automation.Language.ParenExpressionAst]) {
            return Resolve-ImportExpression $Node.Pipeline $Directory $Assignments $Resolving
        }
        elseif ($Node -is [Management.Automation.Language.PipelineAst] -and $Node.PipelineElements.Count -eq 1) {
            return Resolve-ImportExpression $Node.PipelineElements[0] $Directory $Assignments $Resolving
        }
        elseif ($Node -is [Management.Automation.Language.CommandExpressionAst]) {
            return Resolve-ImportExpression $Node.Expression $Directory $Assignments $Resolving
        }
        elseif ($Node -is [Management.Automation.Language.StatementBlockAst] -and $Node.Statements.Count -eq 1) {
            return Resolve-ImportExpression $Node.Statements[0] $Directory $Assignments $Resolving
        }
        elseif ($Node -is [Management.Automation.Language.CommandAst] -and $Node.GetCommandName() -eq 'Join-Path') {
            $elements = @($Node.CommandElements | Select-Object -Skip 1)
            if ($elements.Count -eq 2) {
                return Join-Path (Resolve-ImportExpression $elements[0] $Directory $Assignments $Resolving) `
                    (Resolve-ImportExpression $elements[1] $Directory $Assignments $Resolving)
            }
        }
        throw "Cannot resolve renderer import expression '$($Node.Extent.Text)' from its AST."
    }
    function Visit-Import([string]$File) {
        $File = [IO.Path]::GetFullPath($File)
        if ($seen.ContainsKey($File)) { return }
        $seen[$File] = $true
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errors)
        if ($errors.Count) { throw "Cannot parse renderer import '$File': $($errors[0].Message)" }
        $assignments = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true))
        foreach ($import in @($ast.FindAll({
            param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot'
        }, $true))) {
            $target = Resolve-ImportExpression $import.CommandElements[0] (Split-Path $File -Parent) $assignments
            if (-not [IO.Path]::IsPathRooted($target)) {
                throw "Cannot resolve relative renderer import '$target' without a script-root path."
            }
            Visit-Import $target
        }
    }
    Visit-Import $Path
    return @($seen.Keys | Sort-Object)
}
