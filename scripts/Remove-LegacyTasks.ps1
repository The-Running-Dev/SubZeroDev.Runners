#Requires -Version 7.2
# One-time cleanup for an install that earlier versions set up: removes this clone's legacy sign-in task, log-trim task and
# Run-key entry (and, for an install without an instance id, the combined "Start runners" task). Nothing registers them now.
# Other instances' and other clones' tasks are never touched. A supervisor that one of these tasks started keeps running.
# Safe to rerun: with nothing left it reports that and does nothing. Exit 1 if something could not be removed or confirmed
# gone; only a verified result is recorded (legacy-migration.json), which is what setup verification looks for.
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\LegacyCleanup.ps1"
# The host lock for the whole run: waits for another runner operation on this host, or joins the one that started it.
Enter-HostLock -Kind 'Remove-LegacyTasks'
try {
    $cleanup = Remove-LegacyStartupTasks
    foreach ($line in @($cleanup.Removed) + @($cleanup.Kept)) { Write-Output $line }
    foreach ($line in $cleanup.Failed) { [Console]::Error.WriteLine($line) }
    if (-not ($cleanup.Removed.Count -or $cleanup.Kept.Count -or $cleanup.Failed.Count)) { Write-Output 'No legacy startup tasks to remove.' }
    if (-not $cleanup.Failed.Count) { Save-LegacyMigration 'manual' @($cleanup.Removed) @($cleanup.Kept) }
    exit [int]($cleanup.Failed.Count -gt 0)
} finally { Exit-HostLock }
