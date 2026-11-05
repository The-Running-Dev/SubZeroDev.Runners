#Requires -Version 7.2
# Synthetic evidence tests only; these do not execute jobs on the target Windows machine.
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Assert-WindowsRunnerSmoke.ps1'
function New-Evidence {
    @{ total_count = 2; jobs = @(
        @{ runner_name = 'subzerodev.runner.windows.test-host.win01'; runner_id = 101; conclusion = 'success'; steps = @(@{ name = 'Hold slot for overlap check'; started_at = '2026-11-05T10:00:00Z'; completed_at = '2026-11-05T10:01:30Z' }) },
        @{ runner_name = 'subzerodev.runner.windows.test-host.win02'; runner_id = 102; conclusion = 'success'; steps = @(@{ name = 'Hold slot for overlap check'; started_at = '2026-11-05T10:00:15Z'; completed_at = '2026-11-05T10:01:45Z' }) }
    ) }
}
function gh { $global:LASTEXITCODE = 0; $script:Evidence | ConvertTo-Json -Depth 10 }
function Assert-Rejected([string] $Case) {
    $rejected = $false
    try { & $checker -Repository example/smoke -RunId 1 -ComputerName test-host | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid smoke evidence accepted: $Case" }
}
$script:Evidence = New-Evidence
& $checker -Repository example/smoke -RunId 1 -ComputerName test-host | Out-Null
$script:Evidence = New-Evidence
$script:Evidence.jobs[1].steps[0].started_at = '2026-11-05T10:02:00Z'
$script:Evidence.jobs[1].steps[0].completed_at = '2026-11-05T10:03:30Z'
Assert-Rejected 'sequential jobs'
$script:Evidence = New-Evidence
$script:Evidence.jobs[1].runner_id = 101
Assert-Rejected 'same runner ID'
$script:Evidence = New-Evidence
$script:Evidence.jobs[1].runner_name = 'subzerodev.runner.windows.other-host.win02'
Assert-Rejected 'wrong host identity'
$script:Evidence = New-Evidence
$script:Evidence.jobs[1].conclusion = 'failure'
Assert-Rejected 'failed job'
$script:Evidence = New-Evidence
$script:Evidence.jobs[1].steps[0].completed_at = $null
Assert-Rejected 'missing interval'
Write-Output 'PASS: synthetic smoke evidence accepts overlap and rejects sequential, duplicate, wrong-host, failed and incomplete jobs. No target-host execution performed.'
