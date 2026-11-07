# One-time migration away from what earlier versions registered with Windows: the supervisor's sign-in task ("Start Windows
# runner"), the daily log trim task ("Trim logs"), the combined sign-in task ("Start runners") and the old HKCU Run entry.
# Nothing registers any of them now and nothing starts the supervisor at sign-in. This file is the only place that talks to Task
# Scheduler; Start, Stop, Status, setup verification and a fresh install never load it. Dot-source Common.ps1 first.
#
# Scoped to this clone: a task is removed only when its name (with this instance's suffix) AND its action name this clone's
# script match, so another instance's tasks, and another clone's, are never touched. A running supervisor that was started
# by the task keeps running: removing a task does not stop its process. Idempotent: with nothing left it does nothing.
# Returns Removed, Kept (found but not this clone's) and Failed, each a list of sentences. An entry is Removed only after a
# second look finds it gone; failing to inspect, remove or confirm an owned entry is Failed.
$LegacyRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Test-LegacyTaskMissing($ErrorRecord) {
    $ErrorRecord.FullyQualifiedErrorId -match 'NotFound' -or $ErrorRecord.Exception.Message -match 'No MSFT_ScheduledTask objects found'
}

function Remove-LegacyStartupTasks {
    param(
        [string] $TaskPath = $LegacyTaskPath,
        [object[]] $Tasks = @(
            @{ Name = $LegacyWindowsTaskName; Script = $Supervisor }
            @{ Name = $LegacyLogTrimTaskName; Script = (Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1') }
            # The combined task has no instance suffix: only an install that never had an instance id owns it.
            if (-not $Config.windows.instanceId) { @{ Name = $LegacyLogonTaskName; Script = (Join-Path $PSScriptRoot 'Start-Runners.ps1') } }
        ),
        [string] $RunKey = $LegacyRunKey,
        [string] $RunValueName = $LegacyStartupValueName,
        # Task Scheduler access, replaceable so a test can make it fail. Both throw on any error.
        [scriptblock] $GetTask = { param($Path, $Name) ScheduledTasks\Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop },
        [scriptblock] $RemoveTask = { param($Path, $Name) ScheduledTasks\Unregister-ScheduledTask -TaskPath $Path -TaskName $Name -Confirm:$false -ErrorAction Stop }
    )
    $result = [pscustomobject]@{ Removed = [Collections.Generic.List[string]]::new(); Kept = [Collections.Generic.List[string]]::new(); Failed = [Collections.Generic.List[string]]::new() }
    foreach ($entry in $Tasks) {
        $label = "$TaskPath$($entry.Name)"
        try { $task = & $GetTask $TaskPath $entry.Name }
        catch {
            if (Test-LegacyTaskMissing $_) { continue }
            $result.Failed.Add("Could not look for the legacy task ${label}: $($_.Exception.Message)")
            continue
        }
        if (-not $task) { continue }
        $arguments = (@($task.Actions) | ForEach-Object { "$($_.Arguments)" }) -join ' '
        if (-not $arguments.Contains('"' + $entry.Script + '"')) {
            $result.Kept.Add("Left the task ${label}: its action does not run $($entry.Script), so it belongs to another clone.")
            continue
        }
        try { & $RemoveTask $TaskPath $entry.Name | Out-Null }
        catch {
            $result.Failed.Add("Could not remove the legacy task ${label}: $($_.Exception.Message)")
            continue
        }
        # Success is a second look that finds nothing, not the absence of an error from the removal.
        try { $left = & $GetTask $TaskPath $entry.Name }
        catch {
            if (Test-LegacyTaskMissing $_) { $left = $null }
            else { $result.Failed.Add("Removed the legacy task ${label} but could not confirm it is gone: $($_.Exception.Message)"); continue }
        }
        if ($left) { $result.Failed.Add("The legacy task ${label} is still registered after it was removed."); continue }
        $result.Removed.Add("Removed the legacy task $label.")
    }
    try {
        $value = (Get-ItemProperty -LiteralPath $RunKey -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
        if ($value) {
            if ("$value".Contains($PSScriptRoot)) {
                Remove-ItemProperty -LiteralPath $RunKey -Name $RunValueName -ErrorAction Stop
                if ((Get-ItemProperty -LiteralPath $RunKey -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName) {
                    $result.Failed.Add("The legacy sign-in entry $RunValueName is still in $RunKey after it was removed.")
                }
                else { $result.Removed.Add("Removed the legacy sign-in entry $RunValueName from $RunKey.") }
            }
            else { $result.Kept.Add("Left the sign-in entry $RunValueName in ${RunKey}: it does not run this clone's scripts.") }
        }
    }
    catch { $result.Failed.Add("Could not remove the legacy sign-in entry ${RunValueName}: $($_.Exception.Message)") }
    $result
}

# A clone that has run before (a registration, a supervisor pid or status file) may have been given startup entries by an
# earlier version. A clone with none of these has never been set up: nothing could have registered anything for it.
function Test-LegacyUpgrade {
    foreach ($name in '.runner', 'supervisor.json', 'supervisor.pid') {
        if (Test-Path -LiteralPath (Join-Path $WindowsRunner $name)) { return $true }
    }
    $false
}

function Save-LegacyMigration([string] $Kind, [string[]] $Removed = @(), [string[]] $Kept = @()) {
    [IO.Directory]::CreateDirectory($WindowsRunner) | Out-Null
    $record = [ordered]@{ schema = 1; kind = $Kind; instanceId = "$($Config.windows.instanceId)"; completedUtc = [DateTime]::UtcNow.ToString('o'); removed = @($Removed); kept = @($Kept) }
    $temporary = "$LegacyMigrationFile.tmp"
    $record | ConvertTo-Json | Set-Content -LiteralPath $temporary
    Move-Item -LiteralPath $temporary -Destination $LegacyMigrationFile -Force
}

# The migration step of the installer. Decides fresh or upgrade without asking Task Scheduler:
# - already recorded complete: nothing to do, the scheduler is not touched;
# - never set up here (fresh): nothing to migrate, recorded, the scheduler is not touched;
# - set up before (upgrade): this clone's legacy entries are removed and verified gone. Any entry that cannot be inspected,
#   removed or confirmed gone throws (nothing is recorded), so the caller stops before it changes a registration. Another
#   clone's entries are kept and do not block. Returns the report lines.
function Invoke-LegacyMigration {
    param([string] $Kind = 'upgraded')
    $recorded = Get-LegacyMigration
    if ($recorded) { return [pscustomobject]@{ Kind = $recorded.kind; Changed = $false; Lines = @() } }
    if (-not (Test-LegacyUpgrade)) {
        Save-LegacyMigration 'fresh'
        return [pscustomobject]@{ Kind = 'fresh'; Changed = $true; Lines = @() }
    }
    $cleanup = Remove-LegacyStartupTasks
    if ($cleanup.Failed.Count) {
        $who = if ($Config.windows.instanceId) { "instance $($Config.windows.instanceId)" } else { 'this install' }
        throw ("An earlier version's startup entry for $who could not be removed or verified gone, so the install stopped before any registration change; nothing was started or stopped and no migration is recorded:`n - $(@($cleanup.Failed) -join "`n - ")`n" +
            "Remove the task in Task Scheduler (taskschd.msc), or repair the Task Scheduler service, then rerun Install-WindowsRunner.ps1 (or scripts\Remove-LegacyTasks.ps1).")
    }
    Save-LegacyMigration $Kind @($cleanup.Removed) @($cleanup.Kept)
    [pscustomobject]@{ Kind = $Kind; Changed = $true; Lines = @(@($cleanup.Removed) + @($cleanup.Kept)) }
}
