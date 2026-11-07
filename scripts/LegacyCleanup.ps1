# One-time cleanup of what earlier versions registered with Windows: the supervisor's sign-in task ("Start Windows runner"), the
# daily log trim task ("Trim logs"), the combined sign-in task ("Start runners") and the old HKCU Run entry. Nothing registers
# any of them now and nothing starts the supervisor at sign-in. Remove-LegacyTasks.ps1 and Install-WindowsRunner.ps1 run this
# once, so an upgraded install stops being started behind the operator's back. Start and Stop never touch the scheduler.
# Dot-source Common.ps1 first.
#
# Scoped to this clone: a task is removed only when its name (with this instance's suffix) AND its action name this clone's
# script match, so another instance's tasks, and another clone's, are never touched. A running supervisor that was started
# by the task keeps running: removing a task does not stop its process. Idempotent: with nothing left it does nothing.
# Returns Removed, Kept (found but not this clone's) and Failed, each a list of sentences.
function Remove-LegacyStartupTasks {
    param(
        [string] $TaskPath = $LegacyTaskPath,
        [object[]] $Tasks = @(
            @{ Name = $LegacyWindowsTaskName; Script = $Supervisor }
            @{ Name = $LegacyLogTrimTaskName; Script = (Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1') }
            # The combined task has no instance suffix: only an install that never had an instance id owns it.
            if (-not $Config.windows.instanceId) { @{ Name = $LegacyLogonTaskName; Script = (Join-Path $PSScriptRoot 'Start-Runners.ps1') } }
        ),
        [string] $RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        [string] $RunValueName = $LegacyStartupValueName
    )
    $result = [pscustomobject]@{ Removed = [Collections.Generic.List[string]]::new(); Kept = [Collections.Generic.List[string]]::new(); Failed = [Collections.Generic.List[string]]::new() }
    foreach ($entry in $Tasks) {
        try {
            $task = ScheduledTasks\Get-ScheduledTask -TaskPath $TaskPath -TaskName $entry.Name -ErrorAction Stop
        }
        catch {
            if ($_.FullyQualifiedErrorId -match 'NotFound' -or $_.Exception.Message -match 'No MSFT_ScheduledTask objects found') { continue }
            $result.Failed.Add("Could not look for the legacy task $TaskPath$($entry.Name): $($_.Exception.Message)")
            continue
        }
        if (-not $task) { continue }
        $arguments = (@($task.Actions) | ForEach-Object { "$($_.Arguments)" }) -join ' '
        if (-not $arguments.Contains('"' + $entry.Script + '"')) {
            $result.Kept.Add("Left the task $TaskPath$($entry.Name): its action does not run $($entry.Script), so it belongs to another clone.")
            continue
        }
        try {
            ScheduledTasks\Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $entry.Name -Confirm:$false -ErrorAction Stop
            $result.Removed.Add("Removed the legacy task $TaskPath$($entry.Name).")
        }
        catch { $result.Failed.Add("Could not remove the legacy task $TaskPath$($entry.Name): $($_.Exception.Message)") }
    }
    try {
        $value = (Get-ItemProperty -LiteralPath $RunKey -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
        if ($value) {
            if ("$value".Contains($PSScriptRoot)) {
                Remove-ItemProperty -LiteralPath $RunKey -Name $RunValueName -ErrorAction Stop
                $result.Removed.Add("Removed the legacy sign-in entry $RunValueName from $RunKey.")
            }
            else { $result.Kept.Add("Left the sign-in entry $RunValueName in ${RunKey}: it does not run this clone's scripts.") }
        }
    }
    catch { $result.Failed.Add("Could not remove the legacy sign-in entry ${RunValueName}: $($_.Exception.Message)") }
    $result
}
