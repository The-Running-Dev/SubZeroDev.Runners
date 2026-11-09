#Requires -Version 7.2
# Internal PowerShell 7 worker; the Windows PowerShell 5.1 entry point installs prerequisites first.
param([Parameter(Mandatory)] [string] $OptionsPath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$options = Get-Content -Raw -LiteralPath $OptionsPath | ConvertFrom-Json -AsHashtable
. "$PSScriptRoot\WindowsRunnerSetup.ps1"
$result = Invoke-WindowsRunnerHostSetup @options
# 0 everything requested is done, 1 the BuildAgent integration or the requested acceptance failed (the runners are set up),
# 2 the person has to act, then rerun.
exit ([int]($result | Select-Object -Last 1).ExitCode)

