#Requires -Version 7.2
# Per-instance control of the Windows runner, for Windows-only and combined installs alike. Run it from the instance's clone
# (each instance has its own clone, supervisor and registration).
#
# Nothing restarts the supervisor if it dies. It starts by Start, by AutoStart, or at sign-in when windows.startAtSignIn is on
# (the host manager runs AutoStart then). If Status reports it down, run Start. The supervisor restarts the runner process
# itself, with backoff; that part is automatic.
#
#   Status       one line each for supervisor, listener, job and GitHub. Exit 0 only when all are healthy.
#   Start        end maintenance and start the supervisor.
#   AutoStart    start the supervisor and leave maintenance alone: a held runner idles with no listener. Does nothing when the
#                supervisor already runs. What the Startup entry and Manage-RunnerHost.ps1 -Action AutoStart use.
#   Stop         drain (stop taking jobs, wait for the running job), then stop. A job that outlasts -TimeoutMinutes is kept:
#                nothing is stopped and the report says what is still running. -Force stops at once and cancels the job.
#   Restart      Stop, then Start.
#   Maintenance  drain and stop, then stay stopped until Start.
#
# Draining withdraws the runner's custom labels at GitHub while it waits, and restores them afterwards. A job that targets
# only the default labels (self-hosted, Windows, X64) is not held back; the workflows for these runners use the subzerodev-* labels.
param(
    [Parameter(Mandatory)] [ValidateSet('Status', 'Start', 'AutoStart', 'Stop', 'Restart', 'Maintenance')] [string] $Action,
    [int] $TimeoutMinutes,
    [switch] $Force,
    [switch] $Json
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes }
# Every action but Status changes the runner, so it takes the host lock for the whole run (or joins the operation that
# started it). Status takes no lock.
$holdsHostLock = $Action -ne 'Status'
if ($holdsHostLock) { Enter-HostLock -Kind "Manage-WindowsRunner $Action" }
try {

    function Write-Outcome($Result) {
        switch ($Result.Outcome) {
            'idle' { Write-Output 'Drained: no job was running; stopped.' }
            'forced' { Write-Output "Stopped without draining. $($Result.Cancelled)".Trim() }
            'timeout' { Write-Output $Result.Retained }
            'failed' { [Console]::Error.WriteLine("The runner was not stopped; maintenance is kept (admission stays closed) so nothing restarts it. $(@($Result.Failures) -join ' ') Fix the cause and rerun, or end maintenance with: Manage-WindowsRunner.ps1 -Action Start") }
        }
        if ($Result.Admission -and $Result.Admission -ne 'closed') { Write-Warning "Admission: $($Result.Admission)" }
    }

    switch ($Action) {
        'Status' {
            $state = Get-WindowsRunnerState
            if ($Json) { $state | ConvertTo-Json -Depth 6 }
            else {
                $detail = $state.SupervisorDetail
                $recovery = $state.SupervisorRecovery
                $warnings = 0
                $rows = [ordered]@{
                    Instance    = $state.Instance
                    Supervisor  = "$($state.Supervisor)$(if ($state.SupervisorState) { ", $($state.SupervisorState)" })"
                    Listener    = $state.Listener
                    Job         = $state.Job
                    GitHub      = $state.GitHub
                    Maintenance = if ($state.Maintenance) { "$($state.Maintenance.phase) since $($state.Maintenance.sinceUtc) ($($state.Maintenance.reason))" } else { 'off' }
                    LastExit    = if ($detail -and $null -ne $detail.lastExitCode) { "code $($detail.lastExitCode) at $($detail.lastExitUtc); $($detail.consecutiveQuickExits) quick exits; next retry $($detail.nextRetryUtc)" } else { 'none' }
                    Recovery    = if ($recovery.Recoveries) { "supervisor found dead and started again by hand $($recovery.Recoveries) times ($($recovery.ConsecutiveRecoveries) in a row), last at $($recovery.LastRecoveryUtc)" } else { 'supervisor never found dead' }
                }
                foreach ($line in $recovery.Summary) { $rows["Warning$((++$warnings))"] = $line }
                $rows.GetEnumerator() | ForEach-Object { '{0,-12} {1}' -f $_.Key, $_.Value }
            }
            exit [int](-not $state.Healthy)
        }
        'Start' {
            # Start-WindowsRunner returns only once the supervisor confirmed it initialized; otherwise it throws.
            try { Write-Output (Start-WindowsRunner) }
            catch { [Console]::Error.WriteLine("Start failed: $($_.Exception.Message)"); exit 1 }
        }
        'AutoStart' {
            try { Write-Output (Start-WindowsRunner -KeepMaintenance) }
            catch { [Console]::Error.WriteLine("AutoStart failed: $($_.Exception.Message)"); exit 1 }
        }
        'Stop' {
            $result = Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Reason 'stop'
            Write-Outcome $result
            exit [int]($result.Outcome -in 'timeout', 'failed')
        }
        'Restart' {
            $result = Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Reason 'restart'
            Write-Outcome $result
            if ($result.Outcome -in 'timeout', 'failed') { exit 1 }
            try { Write-Output (Start-WindowsRunner) }
            catch { [Console]::Error.WriteLine("Restart stopped the supervisor but the new one did not start: $($_.Exception.Message)"); exit 1 }
        }
        'Maintenance' {
            $result = Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Hold -Reason 'maintenance'
            Write-Outcome $result
            if ($result.Outcome -in 'timeout', 'failed') { exit 1 }
            Write-Output 'Held in maintenance: the runner stays stopped until: Manage-WindowsRunner.ps1 -Action Start'
        }
    }
} finally { if ($holdsHostLock) { Exit-HostLock } }
