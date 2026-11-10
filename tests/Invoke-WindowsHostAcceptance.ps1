#Requires -Version 7.2
# Live acceptance of the Windows/Docker Desktop host, run ON that host against its instance clones. It runs the real scripts and
# writes a report of what was checked; a stage that is not selected is listed as NOT RUN, never as passed.
#
#   Readiness   BuildAgent status is ok in every clone and matches the runners.json pins (read-only).
#   Build       a project build per clone through Invoke-BuildAgent.ps1 produces its site; a deliberately failing build fails.
#   Adoption    registration, credentials and the legacy-migration record are present; no legacy startup entries remain (read-only).
#   Rerun       runs -SetupCommand again and proves the registration files, runners.local.json and the agent id are unchanged.
#   Drain       (needs -AllowDisruptive and a job already running on -DisruptiveClone) Stop waits for the job, the runner then stops.
#   Timeout     (same) Stop -TimeoutMinutes shorter than the job keeps the runner and the job running and exits 1.
#   Force       (same) Stop -Force stops at once and the job is cancelled.
# Drain, Timeout and Force each interrupt the runner of -DisruptiveClone and start it again afterwards; start a long job (the
# 90 s smoke or a build) in it first. The workflow run's own conclusion (success, still running, cancelled) is for you to read.
#
#   ./tests/Invoke-WindowsHostAcceptance.ps1 -FixtureDirectory D:\fixture\docusaurus
#   ./tests/Invoke-WindowsHostAcceptance.ps1 -Stage Rerun -SetupCommand '.\Setup-WindowsRunners.ps1 ...'
param(
    [string[]] $Clones = @('C:\Actions\win01', 'C:\Actions\win02'),
    [ValidateSet('Readiness', 'Build', 'Adoption', 'Rerun', 'Drain', 'Timeout', 'Force')]
    [string[]] $Stage = @('Readiness', 'Build', 'Adoption'),
    # A checkout of the build fixture (GitHub-ActionTemplates tests/fixtures/docusaurus) for the Build stage.
    [string] $FixtureDirectory,
    [string] $BuildType = 'node-template',
    [string[]] $BuildArguments = @('-AppDir', 'docs'),
    [string] $SiteIndex = 'docs\build\index.html',
    # The exact command that set the host up (run through pwsh -Command) for the Rerun stage.
    [string] $SetupCommand,
    [string] $DisruptiveClone,
    [switch] $AllowDisruptive,
    [int] $TimeoutMinutes = 1,
    [string] $ReportPath = (Join-Path ([IO.Path]::GetTempPath()) "windows-host-acceptance-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')).md")
)
$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.List[object]]::new()
function Add-Check([string] $StageName, [string] $Clone, [string] $Name, [bool] $Passed, [string] $Detail = '') {
    $results.Add([pscustomobject]@{ Stage = $StageName; Clone = (Split-Path $Clone -Leaf); Check = $Name; Passed = $Passed; Detail = $Detail })
}
function Invoke-Script([string] $Clone, [string] $Script, [string[]] $Arguments = @()) {
    $output = & pwsh -NoProfile -File (Join-Path $Clone "scripts\$Script") @Arguments 2>&1 | Out-String
    [pscustomobject]@{ Exit = $LASTEXITCODE; Output = $output.Trim() }
}
function Read-Json([string] $Text) { try { $Text | ConvertFrom-Json } catch { $null } }
function Get-Facts([string] $Clone) { Read-Json (Invoke-Script $Clone 'Get-RunnerFacts.ps1').Output }
function Get-Pins([string] $Clone) { (Get-Content -Raw -LiteralPath (Join-Path $Clone 'runners.json') | ConvertFrom-Json).buildAgent }
function Get-RunnerState([string] $Clone) { Read-Json (Invoke-Script $Clone 'Manage-WindowsRunner.ps1' @('-Action', 'Status', '-Json')).Output }

foreach ($clone in $Clones) { if (-not (Test-Path -LiteralPath (Join-Path $clone 'scripts'))) { throw "$clone is not an instance clone (no scripts folder)." } }
if ($Stage | Where-Object { $_ -in 'Drain', 'Timeout', 'Force' }) {
    if (-not $AllowDisruptive) { throw 'Drain, Timeout and Force interrupt a runner; pass -AllowDisruptive to run them.' }
    if (-not $DisruptiveClone -or $DisruptiveClone -notin $Clones) { throw '-DisruptiveClone must be one of -Clones.' }
}
if ('Build' -in $Stage -and -not (Test-Path -LiteralPath $FixtureDirectory)) { throw '-FixtureDirectory must be a checkout of the build fixture for the Build stage.' }
if ('Rerun' -in $Stage -and -not $SetupCommand) { throw '-SetupCommand is required for the Rerun stage.' }

if ('Readiness' -in $Stage) {
    $pinSets = foreach ($clone in $Clones) { $pins = Get-Pins $clone; "$($pins.tool.version)|$($pins.updater.version)|$($pins.image)" }
    Add-Check 'Readiness' 'all' 'clones carry the same pins' (@($pinSets | Select-Object -Unique).Count -eq 1) ($pinSets -join ' / ')
    foreach ($clone in $Clones) {
        $pins = Get-Pins $clone
        $status = Invoke-Script $clone 'Get-BuildAgentStatus.ps1' @('-Json')
        $rows = @(Read-Json $status.Output)
        Add-Check 'Readiness' $clone 'Get-BuildAgentStatus exits 0' ($status.Exit -eq 0) "exit $($status.Exit)"
        foreach ($item in 'tool', 'runtime', 'mapping', 'docker', 'image') {
            $row = $rows | Where-Object Item -eq $item | Select-Object -First 1
            Add-Check 'Readiness' $clone "status: $item" ([bool]($row -and $row.State -eq 'ok')) "$($row.State) $($row.Detail)"
        }
        $tool = $rows | Where-Object Item -eq 'tool' | Select-Object -First 1
        $image = $rows | Where-Object Item -eq 'image' | Select-Object -First 1
        Add-Check 'Readiness' $clone 'tool version is the pin' ([bool]($tool -and "$($tool.Detail)" -like "*$($pins.tool.version)*")) "pin $($pins.tool.version)"
        Add-Check 'Readiness' $clone 'image digest is the pin' ([bool]($image -and "$($image.Detail)" -like "*$($pins.image -replace '^.*@', '')*")) "pin $($pins.image)"
        # Version readiness only: this does not establish Linux mount isolation or Docker Desktop update acceptance.
        $updater = $rows | Where-Object Item -eq 'updater' | Select-Object -First 1
        $updaterReady = if ($pins.updater.version) {
            $pins.updater.version -eq $pins.tool.version -and $updater -and $updater.State -eq 'ok'
        } else { $updater -and $updater.State -eq 'missing' }
        Add-Check 'Readiness' $clone 'updater configuration matches status' ([bool]$updaterReady) "pin $($pins.updater.version); updater row: $($updater.State) $($updater.Detail)"
    }
}

if ('Build' -in $Stage) {
    $failing = Join-Path ([IO.Path]::GetTempPath()) "host-acceptance-failing-$PID"
    New-Item -ItemType Directory -Force $failing | Out-Null
    '{ "name": "failing-build", "version": "1.0.0", "scripts": { "build": "node -e \"process.exit(7)\"", "build:prod": "node -e \"process.exit(7)\"" } }' | Set-Content -LiteralPath (Join-Path $failing 'package.json')
    foreach ($clone in $Clones) {
        $facts = Get-Facts $clone
        $build = Invoke-Script $clone 'Invoke-BuildAgent.ps1' (@('-Type', $BuildType, '-Source', $FixtureDirectory) + $BuildArguments)
        Add-Check 'Build' $clone "project build exits 0 ($BuildType)" ($build.Exit -eq 0) "exit $($build.Exit)"
        $site = if ($facts) { Join-Path $facts.buildAgent.workspace $SiteIndex }
        $length = if ($site -and (Test-Path -LiteralPath $site)) { (Get-Item -LiteralPath $site).Length } else { 0 }
        Add-Check 'Build' $clone "expected artifact $SiteIndex exists in this instance's workspace" ($length -gt 0) "$site ($length bytes)"
        $bad = Invoke-Script $clone 'Invoke-BuildAgent.ps1' @('-Type', 'node', '-Source', $failing)
        Add-Check 'Build' $clone 'a failing build propagates failure' ($bad.Exit -in 1, 255) "exit $($bad.Exit) (0, 5 and 125 would mean it did not build)"
    }
    Remove-Item -LiteralPath $failing -Recurse -Force -ErrorAction SilentlyContinue
}

if ('Adoption' -in $Stage) {
    foreach ($clone in $Clones) {
        $facts = Get-Facts $clone
        if (-not $facts) { Add-Check 'Adoption' $clone 'facts readable' $false 'Get-RunnerFacts.ps1 returned no JSON'; continue }
        Add-Check 'Adoption' $clone 'existing registration adopted (.runner and .credentials)' ([bool]($facts.registered -and $facts.credentials)) "agent $($facts.agentName) id $($facts.agentId)"
        Add-Check 'Adoption' $clone 'legacy-migration record complete' ([bool]$facts.migration) "$($facts.migration.kind) at $($facts.migration.completedUtc)"
        $left = @($facts.legacyTasks | Where-Object { $_.RunsThisClone -or $_.Error })
        Add-Check 'Adoption' $clone "no legacy scheduled task runs this clone" ($left.Count -eq 0) (($left | ForEach-Object { "$($_.Name): $($_.Error)" }) -join '; ')
        Add-Check 'Adoption' $clone 'no legacy Run entry runs this clone' (-not $facts.legacyRunEntry.runsThisClone -and -not $facts.legacyRunEntry.error) "$($facts.legacyRunEntry.error)"
    }
}

if ('Rerun' -in $Stage) {
    $files = '.runner', '.runner_migrated', '.credentials', '.credentials_migrated', '.credentials_rsaparams'
    function Get-Fingerprint([string] $Clone, $Facts) {
        $paths = @($files | ForEach-Object { Join-Path $Facts.windowsRunner $_ }) + $Facts.localConfig
        $paths | ForEach-Object { "$(Split-Path $_ -Leaf)=$(if (Test-Path -LiteralPath $_) { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } else { 'absent' })" }
    }
    $before = @{}
    foreach ($clone in $Clones) { $facts = Get-Facts $clone; $before[$clone] = @{ Facts = $facts; Files = Get-Fingerprint $clone $facts } }
    $global:LASTEXITCODE = 0
    & pwsh -NoProfile -Command $SetupCommand 2>&1 | Out-Host
    $setupExit = $LASTEXITCODE
    Add-Check 'Rerun' 'all' 'unchanged setup command exits 0' ($setupExit -eq 0) "exit $setupExit"
    foreach ($clone in $Clones) {
        $after = Get-Facts $clone
        $old = $before[$clone]
        Add-Check 'Rerun' $clone 'registration and working config files unchanged' (($old.Files -join ',') -ceq ((Get-Fingerprint $clone $after) -join ',')) ($old.Files -join ', ')
        Add-Check 'Rerun' $clone 'agent id and name unchanged' ("$($old.Facts.agentId)|$($old.Facts.agentName)" -ceq "$($after.agentId)|$($after.agentName)" -and $old.Facts.registered) "$($after.agentName) id $($after.agentId)"
    }
}

foreach ($mode in 'Drain', 'Timeout', 'Force') {
    if ($mode -notin $Stage) { continue }
    $clone = $DisruptiveClone
    $state = Get-RunnerState $clone
    if (-not $state -or "$($state.Job)" -notlike 'running*') { Add-Check $mode $clone 'a job is already running' $false "Job: $($state.Job). Start a long job on this runner first, then rerun this stage."; continue }
    $arguments = switch ($mode) { 'Drain' { @('-Action', 'Stop', '-TimeoutMinutes', '60') } 'Timeout' { @('-Action', 'Stop', '-TimeoutMinutes', "$TimeoutMinutes") } 'Force' { @('-Action', 'Stop', '-Force') } }
    # The custom labels the runner carries before the stop: what a genuine timeout must have put back.
    $labelsBefore = if ($mode -eq 'Timeout') { Get-Facts $clone }
    $stop = Invoke-Script $clone 'Manage-WindowsRunner.ps1' $arguments
    $after = Get-RunnerState $clone
    $stopped = [bool]($after -and "$($after.Supervisor)" -eq 'stopped' -and "$($after.Job)" -eq 'idle')
    switch ($mode) {
        'Drain' {
            Add-Check $mode $clone 'Stop exits 0 once the job finished' ($stop.Exit -eq 0) "exit $($stop.Exit): $($stop.Output)"
            Add-Check $mode $clone 'runner is stopped and idle afterwards' $stopped $(if ($after) { "Supervisor $($after.Supervisor); Job $($after.Job)" } else { 'status after the stop is unreadable' })
        }
        'Timeout' {
            # Exit 1 alone is not a drain timeout: Stop also exits 1 when the labels could not be put back (maintenance stays on, and
            # the runner and job are running just the same). The timeout is genuine only when its own outcome was reported and the
            # state read back shows maintenance cleared and the custom labels the runner had before.
            $after_facts = Get-Facts $clone
            $kept = [bool]($after -and "$($after.Supervisor)" -like 'running*' -and "$($after.Job)" -like 'running*')
            $reported = [bool]($stop.Output -match 'A job was still running after \d+ minutes\. Nothing was stopped; the runner takes jobs again' -and $stop.Output -notmatch 'maintenance is kept|was not stopped|could not be confirmed')
            Add-Check $mode $clone 'Stop exits 1 when the job outlasts the timeout' ($stop.Exit -eq 1) "exit $($stop.Exit): $($stop.Output)"
            Add-Check $mode $clone 'Stop reports the drain timeout, not a failed stop' $reported "$($stop.Output)"
            Add-Check $mode $clone 'supervisor and job are kept running' $kept $(if ($after) { "Supervisor $($after.Supervisor); Job $($after.Job)" } else { 'status after the stop is unreadable' })
            $cleared = [bool]($after -and $null -eq $after.Maintenance -and $after_facts -and $after_facts.admission -and $null -eq $after_facts.admission.maintenance)
            $hold = if (-not $after_facts -or -not $after_facts.admission) { 'facts after the stop are unreadable' } elseif ($after_facts.admission.maintenance) { "maintenance retained (phase $($after_facts.admission.maintenance.phase)): $($after_facts.admission.maintenance.failure)" } elseif (-not $after) { 'status after the stop is unreadable' } else { "Maintenance $($after.Maintenance)" }
            Add-Check $mode $clone 'maintenance is cleared (no hold kept)' $cleared "$hold. A retained hold is left as it is; end it with Manage-WindowsRunner.ps1 -Action Start only once the cause is fixed."
            $wanted = @($labelsBefore.admission.customLabels | Sort-Object)
            $found = @($after_facts.admission.customLabels | Sort-Object)
            $restored = [bool]($labelsBefore -and $labelsBefore.admission.gitHubKnown -and $wanted.Count -gt 0 -and $after_facts -and $after_facts.admission.gitHubKnown -and (($wanted -join ',') -ceq ($found -join ',')))
            Add-Check $mode $clone 'custom labels are back at GitHub' $restored $(if (-not $labelsBefore -or -not $after_facts) { 'facts unreadable' } else { "before: $($wanted -join ', '); after: $($found -join ', ')" })
        }
        'Force' {
            Add-Check $mode $clone 'Stop -Force exits 0' ($stop.Exit -eq 0) "exit $($stop.Exit): $($stop.Output)"
            Add-Check $mode $clone 'the running job was cancelled and the runner stopped' ([bool]($stopped -and $stop.Output -match 'cancelled')) $(if ($after) { "Supervisor $($after.Supervisor); Job $($after.Job)" } else { 'status after the stop is unreadable' })
        }
    }
    if ($mode -ne 'Timeout') {
        # Start ends maintenance, which would undo the hold an unsuccessful stop deliberately keeps. It runs only after a stop that
        # exited 0 and whose state read back as stopped and idle; otherwise the stage fails and the hold is left for the operator.
        if ($stop.Exit -eq 0 -and $stopped) {
            $start = Invoke-Script $clone 'Manage-WindowsRunner.ps1' @('-Action', 'Start')
            $healthy = Invoke-Script $clone 'Manage-WindowsRunner.ps1' @('-Action', 'Status')
            Add-Check $mode $clone 'Start restores a healthy runner' ($start.Exit -eq 0 -and $healthy.Exit -eq 0) "Start exit $($start.Exit); Status exit $($healthy.Exit)"
        }
        else {
            Add-Check $mode $clone 'Start withheld: the stop is not verified, maintenance is preserved' $false "Stop exit $($stop.Exit); stopped and idle: $stopped. Start was not run, so any maintenance hold is intact; fix the cause, then end it with Manage-WindowsRunner.ps1 -Action Start."
        }
    }
}

$notRun = 'Readiness', 'Build', 'Adoption', 'Rerun', 'Drain', 'Timeout', 'Force' | Where-Object { $_ -notin $Stage }
$passed = -not ($results | Where-Object { -not $_.Passed })
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# Windows host acceptance: $(if ($passed) { 'PASS' } else { 'FAIL' })")
$lines.Add("Host $env:COMPUTERNAME, $([DateTime]::UtcNow.ToString('o')). Clones: $($Clones -join ', ').")
$lines.Add('')
$lines.Add('| Stage | Clone | Check | Result | Detail |')
$lines.Add('| --- | --- | --- | --- | --- |')
foreach ($row in $results) { $lines.Add("| $($row.Stage) | $($row.Clone) | $($row.Check) | $(if ($row.Passed) { 'PASS' } else { 'FAIL' }) | $("$($row.Detail)" -replace '\|', '/' -replace '\r?\n', ' ') |") }
if ($notRun) { $lines.Add(''); $lines.Add("NOT RUN (no evidence collected): $($notRun -join ', ')") }
$lines | Set-Content -LiteralPath $ReportPath -Encoding utf8
$lines | Write-Output
Write-Output "Report: $ReportPath"
if (-not $passed) { throw 'Windows host acceptance failed.' }
