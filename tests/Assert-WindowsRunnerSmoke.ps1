#Requires -Version 7.2
# Read completed GitHub job evidence; never infer concurrency from workflow success alone.
param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [long] $RunId,
    [string] $ComputerName = $env:COMPUTERNAME
)
$ErrorActionPreference = 'Stop'
$json = gh api "repos/$Repository/actions/runs/$RunId/jobs?filter=latest&per_page=100"
if ($LASTEXITCODE) { throw 'Cannot read smoke run jobs.' }
$response = $json | ConvertFrom-Json
if ($response.total_count -ne 2) { throw 'Expected exactly two smoke jobs.' }
$jobs = @($response.jobs)
$expected = @('win01', 'win02') | ForEach-Object { "subzerodev.runner.windows.$($ComputerName.ToLowerInvariant()).$_" }
if (@($jobs | Where-Object { $_.conclusion -ne 'success' }).Count) { throw 'Both smoke jobs must finish successfully.' }
if (@($jobs.runner_id | Select-Object -Unique).Count -ne 2 -or (Compare-Object ($jobs.runner_name | Sort-Object) ($expected | Sort-Object))) {
    throw 'Jobs did not use the two expected runner identities.'
}
$intervals = @($jobs | ForEach-Object {
    $step = @($_.steps | Where-Object name -eq 'Hold slot for overlap check')
    if ($step.Count -ne 1 -or -not $step[0].started_at -or -not $step[0].completed_at) { throw 'Smoke step timestamps are missing.' }
    [pscustomobject]@{ Runner = $_.runner_name; RunnerId = $_.runner_id; Start = [DateTimeOffset]::Parse($step[0].started_at); End = [DateTimeOffset]::Parse($step[0].completed_at) }
})
$latestStart = ($intervals.Start | Sort-Object -Descending | Select-Object -First 1)
$earliestEnd = ($intervals.End | Sort-Object | Select-Object -First 1)
$overlap = ($earliestEnd - $latestStart).TotalSeconds
if ($overlap -le 0) { throw 'Jobs succeeded sequentially; concurrent execution has not been proved.' }
$intervals | Format-Table
Write-Output "PASS: two distinct expected runners had overlapping smoke steps for $overlap seconds."
