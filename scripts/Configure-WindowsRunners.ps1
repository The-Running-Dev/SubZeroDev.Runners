#Requires -Version 7.2
# Internal PowerShell 7 worker; the Windows PowerShell 5.1 entry point installs prerequisites first.
param([Parameter(Mandatory)] [string] $OptionsPath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot\RunnerConfig.ps1"
. "$PSScriptRoot\HostState.ps1"
# The whole setup runs under the host lock. The scripts it starts (Install, Manage-WindowsRunner) join it.
Enter-HostLock -Kind 'setup' -Joinable
# Checked again under the lock: an inventory written while this waited means the host manager owns the host now.
$inventory = Read-HostInventory
if ($inventory.State -ne 'absent') {
    [Console]::Error.WriteLine("Setup refused: this host is managed by scripts\Manage-RunnerHost.ps1 (its inventory $($inventory.Path) is $($inventory.State)). Change the slot counts in runners.local.json and run Manage-RunnerHost.ps1 -Action Plan, then -Action Apply.")
    Exit-HostLock
    exit 1
}
$options = Get-Content -Raw -LiteralPath $OptionsPath | ConvertFrom-Json -AsHashtable
. "$PSScriptRoot\WindowsRunnerSetup.ps1"
$result = Invoke-WindowsRunnerHostSetup @options
# 0 everything requested is done, 1 the BuildAgent integration or the requested acceptance failed (the runners are set up),
# 2 the person has to act, then rerun.
exit ([int]($result | Select-Object -Last 1).ExitCode)

