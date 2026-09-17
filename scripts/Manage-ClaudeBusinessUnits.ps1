<#
.SYNOPSIS
    One console for business units, teams, budgets and people.

.DESCRIPTION
    Chargeback administration was seven separate commands, each correct and each
    needing its own remembered parameters, with a sync afterwards that people
    forgot. That is fine as an API and poor as a day-to-day surface: the common
    session is "add a team, move two people into it, check the budget", which
    should not require looking anything up.

    This is a menu over the same scripts. It reimplements none of them - every
    option shells out to the command it names, so there is one code path and the
    behaviour cannot drift from what the documentation describes.

    It syncs automatically after anything that changes membership or the
    registry. Entitlement is not live: a directory change reaches the gateway
    only when Sync-ClaudeAccess.ps1 runs, and forgetting it is the single most
    common way a change appears not to have worked.

.PARAMETER NoSync
    Do not sync after a change. For batching several edits and syncing once at
    the end; the console says the gateway is behind until you do.

.EXAMPLE
    ./scripts/Manage-ClaudeBusinessUnits.ps1 -ResourceGroup rg-claude -ApimName apim-claude
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:CLAUDE_RG) { $env:CLAUDE_RG } else { 'rg-contosohub' }),
    [Parameter(Mandatory = $true)][string]$ApimName,
    [string]$AppInsightsName,
    [switch]$NoSync
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pending = $false   # a change has been made that the gateway has not seen

function Invoke-Child {
    param([string]$Script, [hashtable]$Arguments)
    $path = Join-Path $root "scripts/$Script"
    if (-not (Test-Path $path)) { throw "$Script is missing from scripts/." }
    & $path @Arguments
}

function Sync-Now {
    Invoke-Child 'Sync-ClaudeAccess.ps1' @{ ResourceGroup = $ResourceGroup; ApimName = $ApimName }
    $script:pending = $false
}

# Called after anything that changes membership or the registry. A change that
# is not synced has not happened as far as the gateway is concerned, and the
# person who made it has usually walked away by the time that shows up.
function Complete-Change {
    if ($NoSync) {
        $script:pending = $true
        Write-Host ''
        Write-Host '  Not synced. The gateway is still serving the previous answer.' -ForegroundColor Yellow
        Write-Host '  Choose "Sync now" before you finish.' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host '  Syncing so the gateway sees it...' -ForegroundColor DarkGray
    Sync-Now
}

function Read-Value {
    param([string]$Prompt, [string]$Default)
    $shown = if ($Default) { " [$Default]" } else { '' }
    Write-Host "  $Prompt$shown" -NoNewline -ForegroundColor White
    Write-Host ': ' -NoNewline
    $a = Read-Host
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim()
}

function Confirm-Identifier {
    param([string]$Id)
    # Same rule the writer enforces, checked here so a bad name is refused while
    # the operator is still looking at the prompt that produced it.
    if ($Id -match '^[a-z0-9][a-z0-9-]*$') { return $true }
    Write-Host "  '$Id' is not usable. Lower case letters, digits and hyphens." -ForegroundColor Yellow
    return $false
}

function Show-Units {
    Invoke-Child 'Get-ClaudeBusinessUnit.ps1' @{ ResourceGroup = $ResourceGroup; ApimName = $ApimName }
}

function Add-Unit {
    param([string]$Parent)

    $what = if ($Parent) { "team inside '$Parent'" } else { 'business unit' }
    Write-Host ''
    Write-Host "  New $what" -ForegroundColor Cyan

    $id = Read-Value 'Identifier'
    if (-not $id -or -not (Confirm-Identifier $id)) { return }

    $prefix = if ($Parent) { 'claude-team-' } else { 'claude-bu-' }
    $group = Read-Value 'Entra group' "$prefix$id"

    # The writer refuses a unit whose group does not exist, because it syncs to
    # nobody and reads as unused rather than broken. Offer to create it here so
    # the refusal is not a dead end.
    $existing = az ad group show --group $group --query id -o tsv 2>$null
    if (-not $existing) {
        Write-Host "  '$group' does not exist." -ForegroundColor Yellow
        if ((Read-Value 'Create it? (y/n)' 'y') -notmatch '^y') { return }
        $made = (az ad group create --display-name $group --mail-nickname $group -o json 2>$null | ConvertFrom-Json).id
        if (-not $made) {
            Write-Host '  Could not create it - your tenant may restrict group creation.' -ForegroundColor Yellow
            return
        }
        Write-Host "  $group created" -ForegroundColor Green
    }

    $budget = Read-Value 'Monthly budget, US dollars' '5000'
    if (-not ($budget -as [decimal])) { Write-Host '  Not a number.' -ForegroundColor Yellow; return }

    $args = @{
        Id = $id; Group = $group; MonthlyBudgetUsd = [decimal]$budget
        ResourceGroup = $ResourceGroup; ApimName = $ApimName
    }
    if ($Parent) { $args['Parent'] = $Parent }
    Invoke-Child 'Set-ClaudeBusinessUnit.ps1' $args
    Complete-Change
}

function Set-Budget {
    Write-Host ''
    Write-Host '  Change a budget' -ForegroundColor Cyan
    $id = Read-Value 'Which unit or team'
    if (-not $id) { return }
    $budget = Read-Value 'New monthly budget, US dollars'
    if (-not ($budget -as [decimal])) { Write-Host '  Not a number.' -ForegroundColor Yellow; return }

    # No -Group: the writer changes the budget alone and leaves the group as it
    # is, so this cannot accidentally repoint a unit at a different population.
    Invoke-Child 'Set-ClaudeBusinessUnit.ps1' @{
        Id = $id; MonthlyBudgetUsd = [decimal]$budget
        ResourceGroup = $ResourceGroup; ApimName = $ApimName
    }
    # A budget lives in a named value the policy reads, not in Entra, so this
    # one does not need a membership sync.
    Write-Host ''
    Write-Host '  Applied. Budgets take effect on the next request.' -ForegroundColor DarkGray
}

function Set-Person {
    param([switch]$Remove)

    Write-Host ''
    Write-Host $(if ($Remove) { '  Remove a developer' } else { '  Add a developer' }) -ForegroundColor Cyan
    $user = Read-Value 'Sign-in name or object id'
    if (-not $user) { return }

    $args = @{ User = $user; ResourceGroup = $ResourceGroup; ApimName = $ApimName }
    if ($Remove) {
        $args['Remove'] = $true
    } else {
        $tier = Read-Value 'Tier (standard/premium)' 'standard'
        if ($tier -notin @('standard', 'premium')) { Write-Host '  Unknown tier.' -ForegroundColor Yellow; return }
        $args['Tier'] = $tier
        $unit = Read-Value 'Business unit or team (blank for none)'
        if ($unit) { $args['BusinessUnit'] = $unit }
    }

    # -Sync is left off deliberately: Complete-Change owns syncing, so the
    # console has one place that decides whether a change has reached the
    # gateway rather than two that disagree.
    Invoke-Child 'Set-ClaudeDeveloper.ps1' $args
    Complete-Change
}

function Show-Consumption {
    $args = @{ ResourceGroup = $ResourceGroup; ApimName = $ApimName }
    if ($AppInsightsName) { $args['AppInsightsName'] = $AppInsightsName }
    Invoke-Child 'Get-ClaudeBusinessUnit.ps1' $args
}

# ------------------------------------------------------------------- console

$banner = Join-Path $PSScriptRoot 'Show-Banner.ps1'
if (Test-Path $banner) { . $banner; Show-ClaudeBanner -Variant console -Subtitle 'Business units and budgets' }

# A menu needs a keyboard. Detected by trying rather than by inspecting the
# host: [Environment]::UserInteractive is true even under -NonInteractive, so
# the environment does not reliably say. Without this the first Read-Host throws
# PowerShell internals into a pipeline or CI log, which reads as the tool being
# broken rather than as the wrong tool for the job.
function Read-Choice {
    try { return (Read-Host).Trim() }
    catch {
        Write-Host ''
        Write-Host '  This console is interactive and there is no terminal attached.' -ForegroundColor Yellow
        Write-Host '  For scripts and pipelines, call the commands directly:' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '    ./scripts/Get-ClaudeBusinessUnit.ps1   list and consumption'
        Write-Host '    ./scripts/Set-ClaudeBusinessUnit.ps1   add a unit or team, change a budget'
        Write-Host '    ./scripts/Set-ClaudeDeveloper.ps1      add or remove a developer'
        Write-Host '    ./scripts/Sync-ClaudeAccess.ps1        push membership to the gateway'
        Write-Host ''
        exit 2
    }
}

while ($true) {
    Write-Host ''
    Write-Host "  Chargeback - $ApimName ($ResourceGroup)" -ForegroundColor Cyan
    if ($pending) { Write-Host '  Changes are not yet synced to the gateway.' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '    1  List business units, teams and budgets'
    Write-Host '    2  Add a business unit'
    Write-Host '    3  Add a team inside a business unit'
    Write-Host '    4  Change a budget'
    Write-Host '    5  Add a developer to a unit or team'
    Write-Host '    6  Remove a developer'
    Write-Host '    7  Show consumption and who is unassigned'
    Write-Host '    8  Sync now'
    Write-Host '    q  Quit'
    Write-Host ''
    Write-Host '  Choose' -NoNewline -ForegroundColor White
    Write-Host ': ' -NoNewline
    $choice = Read-Choice

    try {
        switch ($choice) {
            '1' { Show-Units }
            '2' { Add-Unit }
            '3' {
                $parent = Read-Value 'Parent business unit'
                if ($parent) { Add-Unit -Parent $parent }
            }
            '4' { Set-Budget }
            '5' { Set-Person }
            '6' { Set-Person -Remove }
            '7' { Show-Consumption }
            '8' { Sync-Now }
            'q' {
                if ($pending) {
                    Write-Host ''
                    Write-Host '  Changes have not been synced. The gateway is still serving the old answer.' -ForegroundColor Yellow
                    if ((Read-Value 'Sync before leaving? (y/n)' 'y') -match '^y') { Sync-Now }
                }
                Write-Host ''
                exit 0
            }
            default { Write-Host '  Not an option.' -ForegroundColor DarkGray }
        }
    }
    catch {
        # One failed option must not end the session - an operator halfway
        # through moving a team should not lose the rest of the menu because a
        # group name was mistyped.
        Write-Host ''
        Write-Host "  That did not work: $($_.Exception.Message)" -ForegroundColor Red
    }
}
