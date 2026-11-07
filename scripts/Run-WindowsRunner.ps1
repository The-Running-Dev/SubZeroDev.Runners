. "$PSScriptRoot\Common.ps1"
# Supervisor for this instance's runner: starts run.cmd, restarts it when it exits, backs off when it cannot stay up,
# idles while maintenance.json exists, and records what it is doing in supervisor.json (read by Manage-WindowsRunner.ps1).
$mutex = [Threading.Mutex]::new($false, $WindowsMutexName)
if (-not $mutex.WaitOne(0)) { exit }

function Write-SupervisorStatus([hashtable] $Values) {
    foreach ($key in $Values.Keys) { $script:status[$key] = $Values[$key] }
    $script:status.updatedUtc = [DateTime]::UtcNow.ToString('o')
    try { $script:status | ConvertTo-Json | Set-Content -LiteralPath $SupervisorStatusFile } catch { }
}

try {
    $env:DOTNET_INSTALL_DIR = Join-Path $WindowsRunner '_tool\dotnet'
    $env:DOTNET_ROOT = $env:DOTNET_INSTALL_DIR
    $env:DOTNET_CLI_HOME = Join-Path $WindowsRunner '_dotnet-home'
    $env:NUGET_PACKAGES = Join-Path $WindowsRunner '_nuget'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:ACTIONS_RUNNER_HOOK_JOB_COMPLETED = Join-Path $PSScriptRoot 'Clear-WindowsActionCache.ps1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:SZR_SCRIPTS = $PSScriptRoot
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
    foreach ($secret in 'GH_TOKEN', 'GITHUB_TOKEN', 'NUGET_FEED_TOKEN') {
        Remove-Item "Env:\$secret" -ErrorAction SilentlyContinue
    }
    $diag = Join-Path $WindowsRunner '_diag'
    New-Item -ItemType Directory -Force $diag | Out-Null
    Set-Content $SupervisorPidFile $PID
    Set-Location $WindowsRunner

    $lifecycle = $Config.lifecycle
    # A predecessor that left a status other than 'stopped' died without cleaning up (it was killed, crashed, or the session ended):
    # this start is its recovery. Record it, keep the counts across restarts, and say so when it keeps happening.
    $recovery = Get-SupervisorRecovery (Get-SupervisorStatus)
    $status = @{ state = 'starting'; pid = $PID; startedUtc = [DateTime]::UtcNow.ToString('o'); restarts = 0; consecutiveQuickExits = 0; lastExitCode = $null; lastExitUtc = $null; nextRetryUtc = $null } + $recovery
    Write-SupervisorStatus @{}
    if ($recovery.consecutiveRecoveries -ge 2) {
        Show-Notification 'SubZeroDev Windows runner supervisor keeps dying' "Restarted $($recovery.consecutiveRecoveries) times in a row; Task Scheduler gives up after $SupervisorRestartCount. $($recovery.lastRecoveryNote)" $SupervisorStatusFile
    }
    $quickExits = 0
    while ($true) {
        # Maintenance: nothing may start a listener until Start-WindowsRunner removes the flag.
        if (Test-Path -LiteralPath $MaintenanceFile) {
            Write-SupervisorStatus @{ state = 'maintenance'; nextRetryUtc = $null }
            Start-Sleep -Seconds $lifecycle.pollSeconds
            continue
        }
        # A listener already running here belongs to a supervisor that died (our mutex rules out a live one). Launching run.cmd
        # beside it would register two listeners for one runner, and killing it could cancel a job: wait until it is gone.
        if (@(Get-WindowsRunnerListeners).Count) {
            Write-SupervisorStatus @{ state = 'waiting-for-orphan'; nextRetryUtc = $null }
            Start-Sleep -Seconds $lifecycle.pollSeconds
            continue
        }
        # One console log per runner launch, so Trim-RunnerLogs.ps1 can age them out like the runner's own logs.
        $log = Join-Path $diag ('Console_{0:yyyyMMdd-HHmmss}-utc.log' -f [DateTime]::UtcNow)
        $started = Get-Date
        Write-SupervisorStatus @{ state = 'running'; nextRetryUtc = $null; log = $log }
        & .\run.cmd *>> $log
        $exitCode = $LASTEXITCODE
        # A stop for maintenance kills this process tree; reaching here means run.cmd exited by itself.
        $quick = ((Get-Date) - $started).TotalSeconds -lt $lifecycle.quickExitSeconds
        $quickExits = if ($quick) { $quickExits + 1 } else { 0 }
        # Wait restartDelaySeconds, doubled for each quick exit beyond the first, never more than backoffMaxSeconds.
        $delay = $lifecycle.restartDelaySeconds
        for ($i = 1; $i -lt $quickExits -and $delay -lt $lifecycle.backoffMaxSeconds; $i++) { $delay *= 2 }
        $delay = [Math]::Min($delay, $lifecycle.backoffMaxSeconds)
        # A run that lasted is a healthy supervisor: the streak of supervisor recoveries ends.
        if (-not $quick) { $status.consecutiveRecoveries = 0; $status.retriesExhausted = $null }
        Write-SupervisorStatus @{
            state = if ($quickExits) { 'backoff' } else { 'starting' }; restarts = $status.restarts + 1; consecutiveQuickExits = $quickExits
            lastExitCode = $exitCode; lastExitUtc = [DateTime]::UtcNow.ToString('o'); nextRetryUtc = [DateTime]::UtcNow.AddSeconds($delay).ToString('o')
        }
        # Once per failure streak, not on every retry.
        if ($quickExits -eq $lifecycle.quickExitLimit) {
            Show-Notification 'SubZeroDev Windows runner keeps failing' "run.cmd exited $quickExits times in a row (last code $exitCode). Retrying every $delay seconds at most $($lifecycle.backoffMaxSeconds)." $log
        }
        Start-Sleep -Seconds $delay
    }
}
finally {
    try { Write-SupervisorStatus @{ state = 'stopped'; pid = $null } } catch { }
    Remove-Item $SupervisorPidFile -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
