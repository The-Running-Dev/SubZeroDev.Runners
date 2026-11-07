#Requires -Version 7.2
# One-time cleanup for an install that earlier versions set up: removes this clone's legacy sign-in task, log-trim task and
# Run-key entry (and, for an install without an instance id, the combined "Start runners" task). Nothing registers them now.
# Other instances' and other clones' tasks are never touched. A supervisor that one of these tasks started keeps running.
# Safe to rerun: with nothing left it reports that and does nothing. Exit 1 if something could not be removed.
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\LegacyCleanup.ps1"
$cleanup = Remove-LegacyStartupTasks
foreach ($line in @($cleanup.Removed) + @($cleanup.Kept)) { Write-Output $line }
foreach ($line in $cleanup.Failed) { [Console]::Error.WriteLine($line) }
if (-not ($cleanup.Removed.Count -or $cleanup.Kept.Count -or $cleanup.Failed.Count)) { Write-Output 'No legacy startup tasks to remove.' }
exit [int]($cleanup.Failed.Count -gt 0)
