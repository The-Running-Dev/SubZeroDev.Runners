. "$PSScriptRoot\Common.ps1"
$mutex = [Threading.Mutex]::new($false, 'Local\SubZeroDev.Runners.Windows')
if (-not $mutex.WaitOne(0)) { exit }
try {
    $env:DOTNET_INSTALL_DIR = Join-Path $WindowsRunner '_tool\dotnet'
    $env:DOTNET_ROOT = $env:DOTNET_INSTALL_DIR
    $env:DOTNET_CLI_HOME = Join-Path $WindowsRunner '_dotnet-home'
    $env:NUGET_PACKAGES = Join-Path $WindowsRunner '_nuget'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_NOLOGO = '1'
    $env:ACTIONS_RUNNER_HOOK_JOB_COMPLETED = Join-Path $PSScriptRoot 'Clear-WindowsActionCache.ps1'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
    foreach ($secret in 'GH_TOKEN', 'GITHUB_TOKEN', 'NUGET_FEED_TOKEN') {
        Remove-Item "Env:\$secret" -ErrorAction SilentlyContinue
    }
    $diag = Join-Path $WindowsRunner '_diag'
    New-Item -ItemType Directory -Force $diag | Out-Null
    Set-Content $SupervisorPidFile $PID
    Set-Location $WindowsRunner
    $quickExits = 0
    while ($true) {
        # One console log per runner launch, so Trim-RunnerLogs.ps1 can age them out like the runner's own logs.
        $log = Join-Path $diag ('Console_{0:yyyyMMdd-HHmmss}-utc.log' -f [DateTime]::UtcNow)
        $started = Get-Date
        & .\run.cmd *>> $log
        # run.cmd normally never returns, so three exits in a row within five minutes each means it cannot start.
        $quickExits = if (((Get-Date) - $started).TotalMinutes -lt 5) { $quickExits + 1 } else { 0 }
        if ($quickExits -eq 3) {
            Show-Notification 'SubZeroDev Windows runner keeps failing' "run.cmd exited 3 times in a row (last code $LASTEXITCODE). Retrying every 30 seconds." $log
        }
        Start-Sleep -Seconds 30
    }
}
finally {
    Remove-Item $SupervisorPidFile -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
