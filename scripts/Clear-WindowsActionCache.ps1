#Requires -Version 7.2
# Job-completed hook of the Windows runner: empties the work folder's _actions so the next job prepares it fresh.
# All action and post-action steps have finished before this runs. Temporary sharing violations are retried a bounded number of
# times (runners.json housekeeping.retries / retryDelaySeconds). Registration and credentials are never touched.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Housekeeping.ps1"
Write-Output (Clear-RunnerActionCache $WindowsRunner)

# Nothing is scheduled any more, and the supervisor sits inside run.cmd for as long as the runner lives, so this hook (the one
# thing that runs on a long-lived runner) also keeps the logs and caches within logs.* / housekeeping.*: at most once per
# $TrimIntervalHours. Its failure is a warning; it never fails the job.
try {
    $stamp = Get-Item -LiteralPath $TrimStampFile -ErrorAction SilentlyContinue
    if (-not $stamp -or ([DateTime]::UtcNow - $stamp.LastWriteTimeUtc).TotalHours -ge $TrimIntervalHours) {
        & (Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1') | ForEach-Object { Write-Output $_ }
    }
}
catch { Write-Warning "Housekeeping trim failed: $($_.Exception.Message)" }
exit 0
