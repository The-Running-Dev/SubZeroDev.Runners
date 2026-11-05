#Requires -Version 7.2
# Internal PowerShell 7 worker; the Windows PowerShell 5.1 entry point installs prerequisites first.
param([Parameter(Mandatory)] [string] $OptionsPath)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$options = Get-Content -Raw -LiteralPath $OptionsPath | ConvertFrom-Json -AsHashtable
. "$PSScriptRoot\WindowsRunnerSetup.ps1"
Invoke-WindowsRunnerHostSetup @options
