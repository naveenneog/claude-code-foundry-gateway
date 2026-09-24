# Structured operations only. No supplied script text is evaluated in the private admin job.
function Invoke-ClaudeReportAdministration {
    param([string]$Account,$Request)
    if($Request.Operation -notin @('Initialize','Recipients','Settings','Inspect')) {throw 'Unknown report administration operation.'}
    if(($Request | ConvertTo-Json -Depth 30 -Compress).Length -gt 30000) {throw 'Administration request exceeds 30 KB. Apply smaller changes.'}
    $stored=Get-ClaudeReportConfiguration $Account -AllowMissing
    if($Request.Operation -eq 'Initialize') {
        if($stored) {return [pscustomobject]@{Status='Unchanged';Operation='Initialize'}}
        $config=ConvertTo-ClaudeChargebackConfiguration $Request.Configuration
        Test-ClaudeChargebackConfiguration $config
        Save-ClaudeReportConfiguration $Account $config ''
        return [pscustomobject]@{Status='Initialized';Operation='Initialize'}
    }
    if(-not $stored) {throw 'Reports configuration is missing. Register the schedule first.'}
    $config=$stored.Configuration
    if($Request.Operation -eq 'Inspect') {
        # Counts only: complete address lists are read with -List on a VNet-connected host.
        $counts=@([pscustomobject]@{Scope='all';Count=@($config.AllUnitsRecipients).Count})
        foreach($key in @($config.Units.Keys | Sort-Object)) {$counts+= [pscustomobject]@{Scope=$key;Count=@($config.Units[$key]).Count}}
        return [pscustomobject]@{Status='Inspected';Recipients=$counts;Formats=$config.Formats;BusinessUnits=$config.BusinessUnits;MonthToDate=$config.MonthToDate;DeliveryEnabled=$config.DeliveryEnabled;RetentionDays=$config.RetentionDays}
    }
    if($Request.Operation -eq 'Recipients') {
        if(-not $Request.Scope) {throw 'A report recipient scope is required.'}
        if(@($Request.Add | Where-Object {$_}).Count -and @($Request.Remove | Where-Object {$_}).Count) {throw 'Choose either Add or Remove in one request.'}
        $before=Get-ClaudeChargebackRecipients $config $Request.Scope
        $config=Update-ClaudeChargebackRecipients $config $Request.Scope @($Request.Add | Where-Object {$_}) @($Request.Remove | Where-Object {$_})
        $after=Get-ClaudeChargebackRecipients $config $Request.Scope
        if(($before -join ';') -ceq ($after -join ';')) {return [pscustomobject]@{Status='Unchanged';Operation='Recipients';Scope=$Request.Scope}}
    }
    if($Request.Operation -eq 'Settings') {
        $allowed=@('AllowedDomains','BusinessUnits','Formats','MonthToDate','DeliveryEnabled','RetentionDays')
        foreach($p in $Request.Settings.PSObject.Properties) {
            if($p.Name -notin $allowed) {throw 'Unknown report setting. Connection and schema are not mutable through this operation.'}
            $config.($p.Name)=$p.Value
        }
    }
    Test-ClaudeChargebackConfiguration $config
    $config.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    Save-ClaudeReportConfiguration $Account $config $stored.ETag
    return [pscustomobject]@{Status='Saved';Operation=$Request.Operation;Scope=$Request.Scope;Utc=[datetime]::UtcNow.ToString('o')}
}

function New-ClaudeReportInitialSettings {
    param([string[]]$AllowedDomains,$Outputs,[string]$WorkspaceResourceId,[bool]$MonthToDate,[int]$RetentionDays=400)
    $configuration=New-ClaudeChargebackConfiguration $AllowedDomains
    $configuration.MonthToDate=$MonthToDate
    $configuration.RetentionDays=$RetentionDays
    $configuration.Connection=[pscustomobject]@{
        Endpoint=$Outputs.endpoint.value;SenderAddress=$Outputs.senderAddress.value
        JobName=$Outputs.jobName.value;DispatcherJobName=$Outputs.dispatcherJobName.value
        AdminJobName=$Outputs.adminJobName.value;EnvironmentName=$Outputs.environmentName.value
        WorkspaceResourceId=$WorkspaceResourceId
    }
    return $configuration
}

function New-ClaudeReportExecutionTemplate {
    param($Template,[string]$Variable,[string]$Value)
    $containers=@(foreach($container in $Template.containers) {
        $c=[ordered]@{}
        foreach($key in @('name','image','command','args','resources')) {
            if($null -ne $container.$key) {$c[$key]=$container.$key}
        }
        $c.env=@($container.env | Where-Object name -ne $Variable)+@([pscustomobject]@{name=$Variable;value=$Value})
        $c
    })
    return @{containers=$containers}
}

function Invoke-ClaudeReportAdminRequest {
    param([string]$ResourceGroup,[string]$ApimName,$Request,[string]$JobName)
    if(-not $JobName) {
        $jobs=@(az resource list -g $ResourceGroup --resource-type Microsoft.App/jobs -o json | ConvertFrom-Json |
            Where-Object {$_.tags.'claude-chargeback-gateway' -eq $ApimName -and $_.name -like 'job-reports-admin-*'})
        if($LASTEXITCODE -ne 0 -or $jobs.Count -ne 1) {throw 'No unique reports administration job. Register the schedule first.'}
        $JobName=$jobs[0].name
    }
    $json=$Request | ConvertTo-Json -Depth 30 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt 30000) {throw 'Administration request exceeds 30 KB. Apply smaller changes.'}
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $sub=az account show --query id -o tsv
    $path="/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.App/jobs/$JobName"
    $job=Invoke-ClaudeReportArm $path
    $template=New-ClaudeReportExecutionTemplate $job.properties.template 'REPORT_ADMIN_REQUEST' $encoded
    $start=Invoke-ClaudeReportArm "$path/start" POST $template
    if(-not $start.name) {throw 'Administration job did not return an execution name.'}
    $run=Wait-ClaudeReportJob -ResourceGroup $ResourceGroup -Job $JobName -Execution $start.name
    Write-Host 'Administration completed. No report code or resources were redeployed. Job logs contain status/counts, never addresses.'
    return $run
}
