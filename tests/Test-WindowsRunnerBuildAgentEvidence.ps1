#Requires -Version 7.2
# Synthetic evidence tests only; these do not execute builds on the target Windows machine. They prove that the acceptance
# checker accepts complete evidence and rejects each defect it exists to catch.
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'Assert-WindowsRunnerBuildAgent.ps1'
$digest = 'sha256:cc13d62b66fab58e264eb583de5c47eb5f49a3ee8a2cdd48f0de0b1d0ba16556'
$names = 'subzerodev.runner.windows.test-host.win01', 'subzerodev.runner.windows.test-host.win02'
$reportDirectory = Join-Path ([IO.Path]::GetTempPath()) "buildagent-evidence-test-$PID"

function New-Build([int] $Slot, [string] $Start, [string] $End) {
    $instance = "win0$Slot"
    @{
        kind = 'build'; slot = $Slot; runnerName = $names[$Slot - 1]; computerName = 'test-host'; instance = $instance
        workspace = "C:\Users\svc\AppData\Local\SubZeroDev\BuildAgent\workspaces\$instance"
        cacheDirectory = "C:\Users\svc\AppData\Local\SubZeroDev\BuildAgent\workspaces\$instance\.cache"
        outputDirectory = "C:\Users\svc\AppData\Local\SubZeroDev\BuildAgent\workspaces\$instance\artifacts"
        buildType = 'node-template'; buildArguments = '-AppDir docs'; startUtc = $Start; endUtc = $End
        toolVersion = '2.1.0'; imageDigest = $digest; dockerState = 'ok'
        statusRows = @(
            @{ Item = 'tool'; State = 'ok'; Detail = 'BuildAgent.Tool 2.1.0 in C:\tool.' }, @{ Item = 'docker'; State = 'ok'; Detail = 'Linux' },
            @{ Item = 'image'; State = 'ok'; Detail = $digest }, @{ Item = 'updater'; State = 'missing'; Detail = 'blocked' })
        exitCode = 0; marker = "acceptance-marker-r7-a1-slot$Slot"; markerFound = $true; foreignMarkers = @()
        artifacts = @(@{ path = 'docs/build/index.html'; sha256 = ('a' * 63) + "$Slot"; bytes = 1234 })
    }
}
function New-Job([string] $Name, [string] $Runner, [int] $Id, [string] $Start, [string] $End) {
    @{ name = $Name; conclusion = 'success'; runner_name = $Runner; runner_id = $Id; steps = @(@{ name = 'Run BuildAgent build'; started_at = $Start; completed_at = $End }) }
}
function New-Evidence {
    @{
        Jobs = @(
            (New-Job 'Build slot 1' $names[0] 101 '2026-11-08T10:00:00Z' '2026-11-08T10:03:00Z'),
            (New-Job 'Build slot 2' $names[1] 102 '2026-11-08T10:00:20Z' '2026-11-08T10:03:10Z'),
            (New-Job 'Failure propagation' $names[0] 101 '2026-11-08T10:04:00Z' '2026-11-08T10:05:00Z'),
            (New-Job 'Acceptance report' $names[1] 102 '2026-11-08T10:05:10Z' '2026-11-08T10:05:20Z'))
        Builds = @((New-Build 1 '2026-11-08T10:00:01Z' '2026-11-08T10:03:00Z'), (New-Build 2 '2026-11-08T10:00:21Z' '2026-11-08T10:03:10Z'))
        Failure = @{ kind = 'failure'; runnerName = $names[0]; buildType = 'node'; stepOutcome = 'failure'; exitCode = 1 }
    }
}
$fixture = @{}
function gh {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'api') { return (@{ total_count = @($fixture.Evidence.Jobs).Count; jobs = @($fixture.Evidence.Jobs) } | ConvertTo-Json -Depth 10) }
    if ($args[0] -eq 'run' -and $args[1] -eq 'download') {
        $directory = $args[([array]::IndexOf($args, '--dir') + 1)]
        foreach ($build in $fixture.Evidence.Builds) {
            $path = Join-Path $directory "buildagent-slot-$($build.slot)"
            New-Item -ItemType Directory -Force $path | Out-Null
            $build | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $path 'report.json')
        }
        if ($fixture.Evidence.Failure) {
            $path = Join-Path $directory 'buildagent-failure'
            New-Item -ItemType Directory -Force $path | Out-Null
            $fixture.Evidence.Failure | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $path 'report.json')
        }
        return
    }
    throw "Unexpected gh call: $args"
}
function Invoke-Checker { & $checker -Repository example/acceptance -RunId 1 -ComputerName test-host -ReportDirectory $reportDirectory }
function Assert-Rejected([string] $Case, [string] $Reason) {
    Remove-Item -LiteralPath $reportDirectory -Recurse -Force -ErrorAction SilentlyContinue
    $message = $null
    try { Invoke-Checker | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message) { throw "Invalid BuildAgent evidence accepted: $Case" }
    # The checker must reject for the reason under test, not for an unrelated one.
    $file = Join-Path $reportDirectory 'acceptance-report.md'
    $report = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw } else { $message }
    if ($report -notmatch "\| $([regex]::Escape($Reason)) \| FAIL \|") { throw "Case '$Case' was rejected, but check '$Reason' did not fail:`n$report" }
}

$fixture.Evidence = New-Evidence
$output = Invoke-Checker | Out-String
if ($output -notmatch 'BuildAgent acceptance: PASS' -or $output -notmatch 'PASS: two distinct') { throw "Complete evidence was not accepted:`n$output" }
foreach ($expected in 'docs/build/index.html', $names[0], $names[1], $digest) { if ($output -notlike "*$expected*") { throw "The report omits '$expected'." } }

# Each case starts from good evidence and breaks exactly one thing.
$cases = [ordered]@{
    'only one build report'                    = @{ Reason = 'two build reports'; Break = { $fixture.Evidence.Builds = @($fixture.Evidence.Builds[0]) } }
    'same runner twice'                        = @{ Reason = 'distinct runner identities'; Break = { $fixture.Evidence.Builds[1].runnerName = $names[0] } }
    'runner of another host'                   = @{ Reason = 'distinct runner identities'; Break = { $fixture.Evidence.Builds[1].runnerName = 'subzerodev.runner.windows.other-host.win02' } }
    'job ran on another machine'               = @{ Reason = 'distinct runner identities'; Break = { $fixture.Evidence.Builds[1].computerName = 'other-host' } }
    'wrong tool version'                       = @{ Reason = 'tool, image and Docker pins'; Break = { $fixture.Evidence.Builds[1].toolVersion = '2.0.9' } }
    'wrong image digest'                       = @{ Reason = 'tool, image and Docker pins'; Break = { $fixture.Evidence.Builds[0].imageDigest = 'sha256:' + ('0' * 64) } }
    'Docker daemon not ok'                     = @{ Reason = 'tool, image and Docker pins'; Break = { $fixture.Evidence.Builds[0].dockerState = 'missing' } }
    'a status row failed'                      = @{ Reason = 'tool, image and Docker pins'; Break = { $fixture.Evidence.Builds[1].statusRows[2].State = 'missing' } }
    'build exited non-zero'                    = @{ Reason = 'builds exited 0'; Break = { $fixture.Evidence.Builds[1].exitCode = 1 } }
    'build never recorded an exit code'        = @{ Reason = 'builds exited 0'; Break = { $fixture.Evidence.Builds[1].exitCode = -1 } }
    'sequential builds (reports)'              = @{ Reason = 'builds overlapped'; Break = { $fixture.Evidence.Builds[1].startUtc = '2026-11-08T10:04:00Z'; $fixture.Evidence.Builds[1].endUtc = '2026-11-08T10:06:00Z' } }
    'sequential builds (GitHub step records)'  = @{ Reason = 'GitHub job records overlap'; Break = { $fixture.Evidence.Jobs[1].steps[0].started_at = '2026-11-08T10:04:00Z'; $fixture.Evidence.Jobs[1].steps[0].completed_at = '2026-11-08T10:06:00Z' } }
    'same runner ID in GitHub records'         = @{ Reason = 'GitHub runner records'; Break = { $fixture.Evidence.Jobs[1].runner_id = 101 } }
    'a job did not succeed'                    = @{ Reason = 'every job succeeded'; Break = { $fixture.Evidence.Jobs[3].conclusion = 'failure' } }
    'a job is missing'                         = @{ Reason = 'workflow jobs present'; Break = { $fixture.Evidence.Jobs = @($fixture.Evidence.Jobs | Where-Object name -ne 'Failure propagation') } }
    'shared workspace'                         = @{ Reason = 'separate workspaces, caches and outputs'; Break = { $fixture.Evidence.Builds[1].workspace = $fixture.Evidence.Builds[0].workspace } }
    'shared cache'                             = @{ Reason = 'separate workspaces, caches and outputs'; Break = { $fixture.Evidence.Builds[1].cacheDirectory = $fixture.Evidence.Builds[0].cacheDirectory } }
    'shared instance'                          = @{ Reason = 'separate workspaces, caches and outputs'; Break = { $fixture.Evidence.Builds[1].instance = 'win01' } }
    'output nested in the other output'        = @{ Reason = 'separate workspaces, caches and outputs'; Break = { $fixture.Evidence.Builds[1].outputDirectory = Join-Path $fixture.Evidence.Builds[0].outputDirectory 'inner' } }
    'artifact missing'                         = @{ Reason = 'expected artifacts present'; Break = { $fixture.Evidence.Builds[1].artifacts = @() } }
    'artifact is a different file'             = @{ Reason = 'expected artifacts present'; Break = { $fixture.Evidence.Builds[1].artifacts[0].path = 'docs/build/404.html' } }
    'artifact is empty'                        = @{ Reason = 'expected artifacts present'; Break = { $fixture.Evidence.Builds[0].artifacts[0].bytes = 0 } }
    'marker not in the site'                   = @{ Reason = 'no cross-contamination'; Break = { $fixture.Evidence.Builds[0].markerFound = $false } }
    'other job marker in the site'             = @{ Reason = 'no cross-contamination'; Break = { $fixture.Evidence.Builds[1].foreignMarkers = @('acceptance-marker-r7-a1-slot1') } }
    'both jobs stamped the same marker'        = @{ Reason = 'no cross-contamination'; Break = { $fixture.Evidence.Builds[1].marker = $fixture.Evidence.Builds[0].marker } }
    'failing build exited 0'                   = @{ Reason = 'failing build propagated'; Break = { $fixture.Evidence.Failure.exitCode = 0 } }
    'failing build never reached the tool (5)' = @{ Reason = 'failing build propagated'; Break = { $fixture.Evidence.Failure.exitCode = 5 } }
    'failing build image missing (125)'        = @{ Reason = 'failing build propagated'; Break = { $fixture.Evidence.Failure.exitCode = 125 } }
    'failing build step succeeded'             = @{ Reason = 'failing build propagated'; Break = { $fixture.Evidence.Failure.stepOutcome = 'success' } }
    'failure report missing'                   = @{ Reason = 'failing build propagated'; Break = { $fixture.Evidence.Failure = $null } }
}
foreach ($case in $cases.GetEnumerator()) {
    $fixture.Evidence = New-Evidence
    & $case.Value.Break
    Assert-Rejected $case.Key $case.Value.Reason
}
Remove-Item -LiteralPath $reportDirectory -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "PASS: synthetic BuildAgent evidence accepts a complete run and rejects $($cases.Count) defects (identity, pins, exit codes, overlap, isolation, artifacts, cross-contamination, failure propagation). No target-host execution performed."
