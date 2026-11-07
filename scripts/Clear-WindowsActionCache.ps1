#Requires -Version 7.2
# Job-completed hook of the Windows runner: empties the work folder's _actions so the next job prepares it fresh.
# All action and post-action steps have finished before this runs. Temporary sharing violations are retried a bounded number of
# times (runners.json housekeeping.retries / retryDelaySeconds). Registration and credentials are never touched.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Housekeeping.ps1"
Write-Output (Clear-RunnerActionCache $WindowsRunner)
