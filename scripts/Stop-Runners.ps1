# Stops both runners; registrations stay. -Drain first waits (up to -TimeoutMinutes) for running jobs to finish.
param([switch] $Drain, [int] $TimeoutMinutes = 120)
. "$PSScriptRoot\Common.ps1"
if ($Drain) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Test-WindowsRunnerBusy) -or (Test-LinuxRunnerBusy)) {
        if ((Get-Date) -gt $deadline) { throw "A job was still running after $TimeoutMinutes minutes; nothing was stopped." }
        Write-Output 'Waiting for the running job to finish...'
        Start-Sleep -Seconds 15
    }
}
# Neither runner can be told to stop taking jobs, so a job that starts in the gap between the check and the stop is cancelled.
$supervisor = Get-SupervisorProcess
if ($supervisor) {
    # The supervisor and its own child tree, leaving other runners and apps alone.
    taskkill.exe /PID $supervisor.ProcessId /T /F | Out-Null
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
    Write-Output 'Windows runner stopped.'
}
& $Docker stop --timeout 60 $Config.linux.container | Out-Null
Write-Output 'Linux runner stopped.'
if ($DockerSidecar) {
    & $Docker stop --timeout 60 $DockerSidecar | Out-Null
    Write-Output 'Docker sidecar stopped.'
}
