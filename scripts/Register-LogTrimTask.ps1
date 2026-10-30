# Schedules Trim-RunnerLogs.ps1 daily at logs.trimAt from runners.json (HH:mm). Set trimAt to null to remove the task.
. "$PSScriptRoot\Common.ps1"
$name = 'Trim logs'
if (-not $Config.logs.trimAt) {
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output 'Log trimming task removed.'
    exit
}
$action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1')`""
$trigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]::ParseExact($Config.logs.trimAt, 'HH:mm', $null))
# Runs as this user while signed in; a missed run (PC off or asleep) happens at the next opportunity.
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskPath $TaskPath -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Description 'Deletes old SubZeroDev.Runners logs and reapplies the Dropbox ignore rules.' -Force | Out-Null
Write-Output "Log trimming scheduled daily at $($Config.logs.trimAt)."
