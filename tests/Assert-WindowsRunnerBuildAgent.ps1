#Requires -Version 7.2
# Judge a completed windows-runner-buildagent.yml run from GitHub's own records: the job list (runner identities, step
# timestamps, conclusions) and the artifacts the jobs uploaded (build logs, sites, per-job reports). It never infers success
# from the workflow's colour. Needs an authenticated `gh` that can read the repository's Actions data.
#
#   ./tests/Assert-WindowsRunnerBuildAgent.ps1 -Repository AbsoluteZeroDev/<repo> -RunId <id> -ComputerName <host>
#
# The tool version and image digest default to the pins in runners.json. The acceptance report is written to
# -ReportDirectory (default: a new folder under the temp directory) and printed.
param(
    [Parameter(Mandatory)] [string] $Repository,
    [Parameter(Mandatory)] [long] $RunId,
    [string] $ComputerName = $env:COMPUTERNAME,
    [string[]] $ExpectedRunnerNames,
    [string] $ExpectedToolVersion,
    [string] $ExpectedImageDigest,
    [string[]] $ExpectedArtifacts = @('docs/build/index.html'),
    [string] $ReportDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BuildAgentAcceptance.ps1')
if (-not $ExpectedToolVersion -or -not $ExpectedImageDigest) {
    $pins = (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'runners.json') -Raw | ConvertFrom-Json).buildAgent
    if (-not $ExpectedToolVersion) { $ExpectedToolVersion = $pins.tool.version }
    if (-not $ExpectedImageDigest) { $ExpectedImageDigest = $pins.image -replace '^.*@', '' }
}
$expected = @('win01', 'win02') | ForEach-Object { "subzerodev.runner.windows.$($ComputerName.ToLowerInvariant()).$_" }
if ($ExpectedRunnerNames) { $expected = @($ExpectedRunnerNames) }
if ($expected.Count -ne 2 -or @($expected | Select-Object -Unique).Count -ne 2) { throw 'Exactly two distinct expected runner names are required.' }

$json = gh api "repos/$Repository/actions/runs/$RunId/jobs?filter=latest&per_page=100"
if ($LASTEXITCODE) { throw 'Cannot read the acceptance run jobs.' }
$jobs = @(($json | ConvertFrom-Json).jobs)

$download = Join-Path ([IO.Path]::GetTempPath()) "buildagent-acceptance-$RunId-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $download | Out-Null
gh run download $RunId --repo $Repository --dir $download
if ($LASTEXITCODE) { throw 'Cannot download the acceptance run artifacts.' }

$reports = Read-BuildAgentAcceptanceReports $download
$result = Test-BuildAgentAcceptance -Builds $reports.Builds -Failure $reports.Failure -Jobs $jobs -ExpectedRunnerNames $expected `
    -ExpectedComputerName $ComputerName -ExpectedToolVersion $ExpectedToolVersion -ExpectedImageDigest $ExpectedImageDigest -ExpectedArtifacts $ExpectedArtifacts
$markdown = Format-BuildAgentAcceptanceReport -Result $result -Builds $reports.Builds -Failure $reports.Failure -RunUrl "https://github.com/$Repository/actions/runs/$RunId"
if (-not $ReportDirectory) { $ReportDirectory = Join-Path $download 'report' }
New-Item -ItemType Directory -Force $ReportDirectory | Out-Null
$markdown | Set-Content -LiteralPath (Join-Path $ReportDirectory 'acceptance-report.md') -Encoding utf8
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDirectory 'acceptance-report.json') -Encoding utf8
$markdown | Write-Output
Write-Output "Evidence downloaded to $download; report in $ReportDirectory."
if (-not $result.Passed) { throw 'BuildAgent acceptance evidence is not sufficient.' }
Write-Output 'PASS: two distinct runner instances built concurrently with the pinned tool and image, each with its own artifacts, and a failing build failed its step.'
