#Requires -Version 7.2
# Job-started hook of the Windows runner: removes a dangling Uno emsdk link before the job builds (see Repair-UnoEmsdkLink in
# Housekeeping.ps1). It never fails the job.
$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot\Common.ps1"
    . "$PSScriptRoot\Housekeeping.ps1"
    Repair-UnoEmsdkLink $env:USERPROFILE | ForEach-Object { Write-Output $_ }
}
catch { Write-Warning "Uno emsdk link check failed: $($_.Exception.Message)" }
exit 0
