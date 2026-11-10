#Requires -Version 7.2
# Stops both runners; registrations stay. Each runner is drained first: it stops taking jobs (its custom labels are withdrawn
# at GitHub), then the script waits up to -TimeoutMinutes for the running job to finish, then stops it and restores the labels.
# A job that outlasts the deadline is not cancelled: that runner keeps running and the report says so. -Force stops at once
# and cancels whatever is running. The Windows runner is stopped before the Linux runner, which stops before its Docker sidecar.
# Exit code 0: both stopped. 1: a runner was kept because of a running job, or could not be stopped.
param([int] $TimeoutMinutes, [switch] $Force)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes }
# The host lock for the whole run: waits for another runner operation on this host, or joins the one that started it.
Enter-HostLock -Kind 'Stop-Runners'
$kept = 0
foreach ($step in @(
        @{ Label = 'Windows'; Run = { Stop-WindowsRunner -TimeoutMinutes $TimeoutMinutes -Force:$Force -Reason 'stop' } }
        @{ Label = 'Linux'; Run = { Stop-LinuxRunners -TimeoutMinutes $TimeoutMinutes -Force:$Force } }
    )) {
    try {
        $result = & $step.Run
        switch ($result.Outcome) {
            'timeout' { $kept++; Write-Warning "$($step.Label) runner kept running. $($result.Retained)" }
            'failed' { $kept++; Write-Warning "$($step.Label) runner not stopped, maintenance kept: $(@($result.Failures) -join ' ')" }
            'forced' { Write-Output "$($step.Label) runner stopped without draining.$(if ($result.Cancelled) { " $($result.Cancelled)" })" }
            default { Write-Output "$($step.Label) runner stopped." }
        }
    }
    catch { $kept++; Write-Warning "$($step.Label) runner not stopped: $($_.Exception.Message)" }
}
exit [int]($kept -gt 0)
