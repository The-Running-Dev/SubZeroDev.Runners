#Requires -Version 7.2
<#
On the existing runner host, in its Runners clone:
  ./scripts/docs-smoke/Invoke-Smoke.ps1 -Action Prepare [-Repository org/repo]
  # Review/merge the resulting consumer PR, then:
  ./scripts/docs-smoke/Invoke-Smoke.ps1 -Action Run [-Repository org/repo]
Prepare creates only a consumer branch/PR. Run probes the existing Linux runner,
dispatches the reviewed installed workflow and downloads/verifies its evidence.
Neither action merges, changes registration or recreates/stops a runner.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Run')][string] $Action,
    [string] $Repository,
    [string] $RunnerRegistration,
    [string] $Ref,
    [ValidateRange(1, 120)][int] $TimeoutMinutes = 45,
    [string] $StateDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Consumer.ps1')
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Invoke-DocsSmoke -Root $root -Action $Action -Repository $Repository -RunnerRegistration $RunnerRegistration -Ref $Ref -TimeoutMinutes $TimeoutMinutes -StateDirectory $StateDirectory
