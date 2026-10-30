# Starts both runners. Each run logs to windows\_diag\Startup_*.log; a failure also shows a toast.
. "$PSScriptRoot\Common.ps1"
$diag = Join-Path $WindowsRunner '_diag'
New-Item -ItemType Directory -Force $diag | Out-Null
$log = Join-Path $diag ('Startup_{0:yyyyMMdd-HHmmss}-utc.log' -f [DateTime]::UtcNow)
function Write-Log([string] $Text) { Add-Content -LiteralPath $log ('{0:HH:mm:ss} {1}' -f (Get-Date), $Text) }
try {
    & (Join-Path $PSScriptRoot 'Set-DropboxIgnored.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1') | ForEach-Object { Write-Log $_ }
    if (Get-SupervisorProcess) {
        Write-Log 'Windows supervisor already running.'
    }
    else {
        Start-Process $Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Supervisor`"") -WorkingDirectory $WindowsRunner -WindowStyle Hidden
        Write-Log 'Windows supervisor started.'
    }
    # Docker Desktop can take a while to become ready after sign-in.
    & $Docker info --format '{{.OSType}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe' -WindowStyle Hidden
        Write-Log 'Docker Desktop started.'
    }
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $output = & $Docker start @LinuxContainers 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Linux containers $($LinuxContainers -join ', ') started."
            exit 0
        }
        Start-Sleep -Seconds 10
    }
    throw "Docker did not start $($LinuxContainers -join ', ') within 10 minutes: $output"
}
catch {
    Write-Log "FAILED: $_"
    Write-Log $_.ScriptStackTrace
    Show-Notification 'SubZeroDev runners failed to start' "$_" $log
    exit 1
}
