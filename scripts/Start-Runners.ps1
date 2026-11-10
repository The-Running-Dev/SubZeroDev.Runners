#Requires -Version 7.2
# Starts both runners. Each run logs to windows\_diag\Startup_*.log; a failure also shows a toast.
# A Windows runner held in maintenance (Manage-WindowsRunner.ps1 -Action Maintenance) stays held; end that with -Action Start.
# The Windows runner starts first and does not wait for Docker: a Docker failure leaves it running.
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
# The host lock for the whole run: waits for another runner operation on this host, or joins the one that started it.
Enter-HostLock -Kind 'Start-Runners'
$diag = Join-Path $WindowsRunner '_diag'
New-Item -ItemType Directory -Force $diag | Out-Null
$log = Join-Path $diag ('Startup_{0:yyyyMMdd-HHmmss}-utc.log' -f [DateTime]::UtcNow)
function Write-Log([string] $Text) { Add-Content -LiteralPath $log ('{0:HH:mm:ss} {1}' -f (Get-Date), $Text) }
$startTimeoutSeconds = 600
$windowsFailure = $null
try {
    & (Join-Path $PSScriptRoot 'Set-DropboxIgnored.ps1') | Out-Null
    & (Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1') | ForEach-Object { Write-Log $_ }
    if (Get-MaintenanceState) { Write-Log "Windows runner is held in maintenance ($MaintenanceFile); not started." }
    else {
        # A supervisor that exits or never initializes fails the run, but the Linux runner is still attempted.
        try { Write-Log "Windows runner: $(Start-WindowsRunner)." }
        catch { $windowsFailure = "Windows runner did not start: $($_.Exception.Message)"; Write-Log "FAILED: $windowsFailure" }
    }
    # Docker Desktop can take a while to become ready after sign-in.
    & $Docker info --format '{{.OSType}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $desktop = Find-DockerDesktopExe
        if (-not $desktop) { throw 'Docker is not running and Docker Desktop is not installed; the Linux runner was not started. The Windows runner is unaffected.' }
        Start-Process $desktop -WindowStyle Hidden
        Write-Log "Docker Desktop started ($desktop)."
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($startTimeoutSeconds)
    do {
        $output = & $Docker start @LinuxContainers 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Linux containers $($LinuxContainers -join ', ') started."
            if ($windowsFailure) { throw $windowsFailure }
            exit 0
        }
        Start-Sleep -Seconds 10
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Docker did not start $($LinuxContainers -join ', ') within $($startTimeoutSeconds / 60) minutes: $output"
}
catch {
    if ($windowsFailure -and "$_" -ne $windowsFailure) { $failure = "$_ Also: $windowsFailure" } else { $failure = "$_" }
    Write-Log "FAILED: $failure"
    Write-Log $_.ScriptStackTrace
    Show-Notification 'SubZeroDev runners failed to start' $failure $log
    exit 1
}
