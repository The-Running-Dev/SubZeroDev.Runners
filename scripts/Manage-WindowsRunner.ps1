#Requires -Version 7.2
# Per-instance control of the Windows runner, for Windows-only and combined installs alike. Run it from the instance's clone
# (each instance has its own clone, supervisor, task and registration).
#
#   Status       one line each for supervisor, listener, job and GitHub. Exit 0 only when all are healthy.
#   Start        end maintenance and start the supervisor.
#   Stop         drain (stop taking jobs, wait for the running job), then stop. A job that outlasts -TimeoutMinutes is kept:
#                nothing is stopped and the report says what is still running. -Force stops at once and cancels the job.
#   Restart      Stop, then Start.
#   Maintenance  drain and stop, then stay stopped (the sign-in task idles) until Start.
#
# Draining withdraws the runner's custom labels at GitHub while it waits, and restores them afterwards. A job that targets
# only the default labels (self-hosted, Windows, X64) is not held back; the workflows for these runners use the subzerodev-* labels.
param(
    [Parameter(Mandatory)] [ValidateSet('Status', 'Start', 'Stop', 'Restart', 'Maintenance')] [string] $Action,
    [int] $TimeoutMinutes,
    [switch] $Force,
    [switch] $Json
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes }

function Write-Outcome($Result) {
    switch ($Result.Outcome) {
        'idle' { Write-Output 'Drained: no job was running; stopped.' }
        'forced' { Write-Output "Stopped without draining. $($Result.Cancelled)".Trim() }
        'timeout' { Write-Output $Result.Retained }
    }
    if ($Result.Admission -and $Result.Admission -ne 'closed') { Write-Warning "Admission: $($Result.Admission)" }
}

switch ($Action) {
    'Status' {
        $state = Get-WindowsRunnerState
        if ($Json) { $state | ConvertTo-Json -Depth 6 }
        else {
            $detail = $state.SupervisorDetail
            $rows = [ordered]@{
                Instance    = $state.Instance
                Supervisor  = "$($state.Supervisor)$(if ($state.SupervisorState) { ", $($state.SupervisorState)" })"
                Listener    = $state.Listener
                Job         = $state.Job
                GitHub      = $state.GitHub
                Maintenance = if ($state.Maintenance) { "$($state.Maintenance.phase) since $($state.Maintenance.sinceUtc) ($($state.Maintenance.reason))" } else { 'off' }
                StartupTask = $state.StartupTask
                LastExit    = if ($detail -and $null -ne $detail.lastExitCode) { "code $($detail.lastExitCode) at $($detail.lastExitUtc); $($detail.consecutiveQuickExits) quick exits; next retry $($detail.nextRetryUtc)" } else { 'none' }
            }
            $rows.GetEnumerator() | ForEach-Object { '{0,-12} {1}' -f $_.Key, $_.Value }
        }
        exit [int](-not $state.Healthy)
    }
    'Start' { Write-Output (Start-WindowsRunner) }
    'Stop' {
        $result = Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Reason 'stop'
        Write-Outcome $result
        exit [int]($result.Outcome -eq 'timeout')
    }
    'Restart' {
        $result = Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Reason 'restart'
        Write-Outcome $result
        if ($result.Outcome -eq 'timeout') { exit 1 }
        Write-Output (Start-WindowsRunner)
    }
    'Maintenance' {
        $result = Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Hold -Reason 'maintenance'
        Write-Outcome $result
        if ($result.Outcome -eq 'timeout') { exit 1 }
        Write-Output 'Held in maintenance: the runner stays stopped, including after sign-in, until: Manage-WindowsRunner.ps1 -Action Start'
    }
}
