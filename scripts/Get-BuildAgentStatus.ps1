#Requires -Version 7.2
# One line per BuildAgent prerequisite: tool, net8.0 runtime, mapping, Docker daemon (Linux containers), image, updater.
# Read-only. Exits 0 when builds can run, 1 when something is missing or wrong. The updater row does not affect the exit
# status: it reports an independent, optional Linux-update feature.
param([switch] $Json)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\BuildAgent.ps1"
$rows = @(Get-BuildAgentStatus -Config $Config -RunnerRoot $Root -DockerExe $Docker)
if ($Json) { $rows | ConvertTo-Json }
else { $rows | Format-Table Item, State, Detail -AutoSize -Wrap | Out-String -Width 200 | Write-Output }
exit [int](@($rows | Where-Object { $_.Item -ne 'updater' -and $_.State -ne 'ok' }).Count -gt 0)
