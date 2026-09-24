function Test-ClaudeReportCron {
    param([string]$Cron)
    $parts=@($Cron.Trim() -split '\s+')
    if($parts.Count -ne 5 -or $Cron -notmatch '^[0-9*,/ -]+$') { throw 'Cron must be a five-field UTC expression using numbers, *, comma, / and hyphen.' }
    $limits=@(@(0,59),@(0,23),@(1,31),@(1,12),@(0,6))
    for($i=0;$i -lt 5;$i++) {
        foreach($piece in ($parts[$i] -split ',')) {
            if($piece -notmatch '^(\*|\d+(-\d+)?)(/\d+)?$') { throw 'Invalid cron field.' }
            $step=@($piece -split '/')
            if($step.Count -eq 2 -and [int]$step[1] -lt 1) { throw 'Cron step must be positive.' }
            if($step[0] -ne '*') {
                $ends=@($step[0] -split '-' | ForEach-Object {[int]$_})
                foreach($n in $ends) { if($n -lt $limits[$i][0] -or $n -gt $limits[$i][1]) { throw 'Cron field is outside its valid range.' } }
                if($ends.Count -eq 2 -and $ends[0] -gt $ends[1]) { throw 'Cron range must be ascending.' }
            }
        }
    }
}

function New-ClaudeReportScheduleParameters {
    param([string]$ApimName,[string]$WorkspaceResourceId,[string]$RepositoryUrl,[string]$RepositoryRef,[string]$Cron,
        [string]$OperatorObjectId,[string]$OperatorPrincipalType,[string]$Location,[int]$RetentionDays=400)
    if($RepositoryRef -notmatch '^[0-9a-f]{40}$') { throw 'RepositoryRef must be a full published commit ID.' }
    if($RepositoryUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$') { throw 'RepositoryUrl must be a public GitHub HTTPS repository URL.' }
    Test-ClaudeReportCron $Cron
    $params=@{}
    $values=@{gatewayApimName=$ApimName;workspaceResourceId=$WorkspaceResourceId;repositoryUrl=$RepositoryUrl;repositoryRef=$RepositoryRef
        cronExpression=$Cron;operatorObjectId=$OperatorObjectId;operatorPrincipalType=$OperatorPrincipalType;location=$Location;retentionDays=$RetentionDays}
    foreach($k in $values.Keys) { $params[$k]=@{value=$values[$k]} }
    return @{ '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$params }
}

function Invoke-ClaudeReportArm {
    param([string]$Path,[string]$Method='GET',$Body,[string]$ApiVersion='2025-01-01')
    $args=@{Uri="https://management.azure.com$Path`?api-version=$ApiVersion";Method=$Method
        Headers=@{Authorization='Bearer '+(Get-ClaudeReportToken 'https://management.azure.com')};ContentType='application/json'}
    if($Body) {$args.Body=$Body | ConvertTo-Json -Depth 40 -Compress}
    Invoke-RestMethod @args
}

function Update-ClaudeReportJob {
    param([string]$ResourceGroup,[string]$Job,[string]$Cron,[string]$RepositoryRef)
    $sub=az account show --query id -o tsv
    $path="/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.App/jobs/$Job"
    $old=Invoke-ClaudeReportArm $path
    if($Cron) { Test-ClaudeReportCron $Cron; $old.properties.configuration.scheduleTriggerConfig.cronExpression=$Cron }
    if($RepositoryRef) {
        if($RepositoryRef -notmatch '^[0-9a-f]{40}$') { throw 'RepositoryRef must be a full published commit ID.' }
        foreach($container in $old.properties.template.containers) {
            foreach($envValue in $container.env) { if($envValue.name -eq 'REPO_REF') { $envValue.value=$RepositoryRef } }
        }
    }
    $ids=@{}
    foreach($p in $old.identity.userAssignedIdentities.PSObject.Properties) {$ids[$p.Name]=@{}}
    $body=@{location=$old.location;tags=$old.tags;identity=@{type='UserAssigned';userAssignedIdentities=$ids}
        properties=@{environmentId=$old.properties.environmentId;workloadProfileName=$old.properties.workloadProfileName
            configuration=$old.properties.configuration;template=$old.properties.template}}
    Invoke-ClaudeReportArm $path PUT $body | Out-Null
}

function Wait-ClaudeReportJob {
    param([string]$ResourceGroup,[string]$Job)
    $execution=az containerapp job start -g $ResourceGroup -n $Job --query name -o tsv
    if($LASTEXITCODE -ne 0 -or -not $execution) { throw 'Could not start the report job.' }
    $deadline=[datetime]::UtcNow.AddMinutes(65)
    do {
        Start-Sleep -Seconds 15
        $status=az containerapp job execution show -g $ResourceGroup -n $Job --job-execution-name $execution --query properties.status -o tsv
        if($LASTEXITCODE -ne 0) { throw 'Could not read the report job execution status.' }
    } while($status -in @('Running','Processing','') -and [datetime]::UtcNow -lt $deadline)
    if($status -ne 'Succeeded') { throw "Report job $execution ended with status $status. Inspect its console logs; email is not assumed sent." }
    return [pscustomobject]@{Execution=$execution;Status=$status;CompletedUtc=[datetime]::UtcNow.ToString('o')}
}

function Set-ClaudeReportRetention {
    param([string]$ResourceGroup,[string]$Account,[int]$Days)
    $sub=az account show --query id -o tsv
    $path="/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$Account/managementPolicies/default"
    $old=Invoke-ClaudeReportArm $path -ApiVersion '2023-05-01'
    foreach($rule in $old.properties.policy.rules) {
        if($rule.name -eq 'report-retention') {
            $rule.definition.actions.baseBlob.delete.daysAfterModificationGreaterThan=$Days
            $rule.definition.actions.version.delete.daysAfterCreationGreaterThan=$Days
            $rule.definition.actions.snapshot.delete.daysAfterCreationGreaterThan=$Days
        }
        if($rule.name -eq 'configuration-history') { $rule.definition.actions.version.delete.daysAfterCreationGreaterThan=$Days }
    }
    Invoke-ClaudeReportArm $path PUT @{properties=$old.properties} -ApiVersion '2023-05-01' | Out-Null
}
