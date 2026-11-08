#Requires -Version 7.2
# Housekeeping for both runners, each part independent: a failing part is reported and does not stop the others.
#   - logs: older than logs.retentionDays go, then the oldest until each _diag folder fits logs.maxMB (newest of each kind stays);
#   - BuildAgent caches: buildAgent.cache.retentionDays / maxGB;
#   - free disk: a warning, and a toast, when a drive holding runners or workspaces is below housekeeping.minFreeGB.
# Registration and credential files are never touched. Exit code 1 when any part failed or a drive is low.
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Housekeeping.ps1"
$problems = [Collections.Generic.List[string]]::new()
# Stamped first, so a failing or slow run is not retried by every job that finishes: the job-completed hook reads this.
try { [IO.Directory]::CreateDirectory($WindowsRunner) | Out-Null; Set-Content -LiteralPath $TrimStampFile -Value ([DateTime]::UtcNow.ToString('o')) }
catch { Write-Warning "Could not record the trim time ($TrimStampFile): $($_.Exception.Message)" }

try {
    $logs = Invoke-LogTrim -DiagnosticsDirectory (Join-Path $WindowsRunner '_diag'), (Join-Path $LinuxRunner '_diag')
    Write-Output "Logs: removed $($logs.Removed) file(s) ($([Math]::Round($logs.BytesBefore / 1MB, 1)) MB -> $([Math]::Round($logs.BytesAfter / 1MB, 1)) MB, limit $($Config.logs.maxMB) MB, age $($Config.logs.retentionDays) days)$(if ($logs.Locked) { "; $($logs.Locked) in use, kept" })."
    if ($logs.BytesAfter -gt $logs.LimitBytes) { Write-Warning "Logs still exceed logs.maxMB: the newest log of each kind and open files are kept." }
}
catch { $problems.Add("Log trim failed: $($_.Exception.Message)"); Write-Warning $problems[-1] }

try {
    if ($Config.buildAgent.enabled) {
        $cache = Invoke-CacheTrim
        Write-Output "BuildAgent cache: removed $($cache.Removed) entr$(if ($cache.Removed -eq 1) { 'y' } else { 'ies' }), freed $([Math]::Round($cache.FreedBytes / 1GB, 2)) GB$(if ($cache.Locked) { "; $($cache.Locked) in use, kept" })."
    }
}
catch { $problems.Add("BuildAgent cache trim failed: $($_.Exception.Message)"); Write-Warning $problems[-1] }

try {
    $paths = @($WindowsRunner, $LinuxRunner)
    if ($Config.buildAgent.enabled) { $paths += (Get-CanonicalPath $Config.buildAgent.paths.workspaceRoot) }
    foreach ($row in Get-FreeDiskReport $paths) {
        Write-Output "Disk $($row.Drive): $($row.FreeGB) GB free (minimum $($row.MinimumGB) GB)."
        if ($row.Low) {
            $problems.Add("Drive $($row.Drive) has $($row.FreeGB) GB free, below housekeeping.minFreeGB ($($row.MinimumGB) GB).")
            Write-Warning $problems[-1]
            Show-Notification 'SubZeroDev runners: low disk space' $problems[-1]
        }
    }
}
catch { $problems.Add("Disk check failed: $($_.Exception.Message)"); Write-Warning $problems[-1] }

# Also keeps paths created since the last start (runner updates, new caches) out of Dropbox.
try { & (Join-Path $PSScriptRoot 'Set-DropboxIgnored.ps1') | Out-Null }
catch { $problems.Add("Dropbox ignore rules failed: $($_.Exception.Message)"); Write-Warning $problems[-1] }

exit [int]($problems.Count -gt 0)
