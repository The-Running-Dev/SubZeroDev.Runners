#Requires -Version 7.2
# Tests of the host acceptance script against FAKE clones (stub scripts that read a behavior file). Nothing real is built,
# started or stopped; this proves the acceptance script accepts a healthy host and rejects each defect it exists to catch.
# It is not evidence about any real host.
$ErrorActionPreference = 'Stop'
$host1 = Join-Path $PSScriptRoot 'Invoke-WindowsHostAcceptance.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "host-acceptance-test-$PID"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$digest = 'sha256:cc13d62b66fab58e264eb583de5c47eb5f49a3ee8a2cdd48f0de0b1d0ba16556'
$fixture = Join-Path $work 'fixture'
New-Item -ItemType Directory -Force $fixture | Out-Null

$fakeScripts = @{
    'Get-RunnerFacts.ps1'       = @'
$clone = Split-Path $PSScriptRoot -Parent
$b = Get-Content -Raw "$clone\behavior.json" | ConvertFrom-Json
if ($b.stop.factsUnreadable -and (Select-String -LiteralPath "$clone\calls.log" -Pattern 'manage Stop' -Quiet)) { 'not json'; exit 1 }
Get-Content -Raw "$clone\facts.json"
'@
    'Get-BuildAgentStatus.ps1'  = @'
param([switch] $Json)
$clone = Split-Path $PSScriptRoot -Parent
$b = Get-Content -Raw "$clone\behavior.json" | ConvertFrom-Json
Get-Content -Raw "$clone\status.json"
exit $b.buildStatusExit
'@
    'Invoke-BuildAgent.ps1'     = @'
param([string] $Type, [string] $Source, [Parameter(ValueFromRemainingArguments)] [string[]] $Rest)
$clone = Split-Path $PSScriptRoot -Parent
$b = Get-Content -Raw "$clone\behavior.json" | ConvertFrom-Json
$facts = Get-Content -Raw "$clone\facts.json" | ConvertFrom-Json
Add-Content "$clone\calls.log" "build $Type $Rest"
if ($Type -eq 'node') { exit $b.failExit }
if ($b.writeSite) {
    $site = Join-Path $facts.buildAgent.workspace 'docs\build'
    New-Item -ItemType Directory -Force $site | Out-Null
    Set-Content -LiteralPath (Join-Path $site 'index.html') -Value '<html>site</html>'
}
exit $b.buildExit
'@
    'Manage-WindowsRunner.ps1'  = @'
param([string] $Action, [int] $TimeoutMinutes, [switch] $Force, [switch] $Json)
$clone = Split-Path $PSScriptRoot -Parent
$b = Get-Content -Raw "$clone\behavior.json" | ConvertFrom-Json
$stateFile = "$clone\state.json"
Add-Content "$clone\calls.log" "manage $Action timeout=$TimeoutMinutes force=$Force"
switch ($Action) {
    'Status' {
        if ($b.stop.statusUnreadable -and (Select-String -LiteralPath "$clone\calls.log" -Pattern 'manage Stop' -Quiet)) { 'not json'; exit 1 }
        Get-Content -Raw $stateFile; exit $b.statusExit
    }
    'Stop' {
        $s = Get-Content -Raw $stateFile | ConvertFrom-Json
        foreach ($p in $b.stop.patch.PSObject.Properties) { $s.($p.Name) = $p.Value }
        $s | ConvertTo-Json -Depth 8 | Set-Content $stateFile
        $f = Get-Content -Raw "$clone\facts.json" | ConvertFrom-Json
        foreach ($p in $b.stop.factsPatch.PSObject.Properties) { $f.admission.($p.Name) = $p.Value }
        $f | ConvertTo-Json -Depth 8 | Set-Content "$clone\facts.json"
        $b.stop.output
        exit $b.stop.exit
    }
    'Start' {
        $s = Get-Content -Raw $stateFile | ConvertFrom-Json
        $s.Supervisor = 'running (pid 7)'; $s.Job = 'idle'; $s.Maintenance = $null
        $s | ConvertTo-Json -Depth 8 | Set-Content $stateFile
        exit $b.startExit
    }
}
'@
}
function Save-Json($Value, [string] $Path) { $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path }
function Update-Json([string] $Path, [scriptblock] $Edit) {
    $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    & $Edit $value
    Save-Json $value $Path
}
# Adds or replaces a property on a parsed JSON object (a plain assignment fails for one that is not there yet).
function Set-Prop($Object, [string] $Name, $Value) { Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value -Force }
function New-FakeClone([string] $Root, [string] $Name) {
    $clone = Join-Path $Root $Name
    New-Item -ItemType Directory -Force (Join-Path $clone 'scripts'), (Join-Path $clone 'windows') | Out-Null
    foreach ($script in $fakeScripts.GetEnumerator()) { Set-Content -LiteralPath (Join-Path $clone "scripts\$($script.Key)") -Value $script.Value }
    Set-Content -LiteralPath (Join-Path $clone 'windows\.runner') -Value "runner $Name"
    Set-Content -LiteralPath (Join-Path $clone 'windows\.credentials') -Value "credentials $Name"
    Set-Content -LiteralPath (Join-Path $clone 'runners.local.json') -Value '{ "local": true }'
    Save-Json @{ buildAgent = @{ tool = @{ version = '2.2.0' }; image = "ghcr.io/example/build-agent@$digest"; updater = @{ version = '2.2.0' } } } (Join-Path $clone 'runners.json')
    Save-Json @{
        instance = $Name; clone = $clone; windowsRunner = (Join-Path $clone 'windows'); registered = $true; agentId = 11; agentName = "runner.$Name"; credentials = $true
        localConfig = (Join-Path $clone 'runners.local.json')
        migration = @{ kind = 'upgraded'; completedUtc = '2026-11-08T10:00:00Z'; removed = @(); kept = @() }
        legacyTasks = @(@{ Name = 'Start Windows runner'; Present = $false; RunsThisClone = $false; Error = $null })
        legacyRunEntry = @{ present = $false; runsThisClone = $false; error = $null }
        admission = @{ maintenance = $null; gitHubKnown = $true; customLabels = @("subzerodev-$Name"); detail = '' }
        buildAgent = @{ workspace = (Join-Path $clone 'ws') }
    } (Join-Path $clone 'facts.json')
    Save-Json @(
        @{ Item = 'tool'; State = 'ok'; Detail = 'BuildAgent.Tool 2.2.0 in C:\tool.' }, @{ Item = 'runtime'; State = 'ok'; Detail = '.NET 8' },
        @{ Item = 'mapping'; State = 'ok'; Detail = 'mapped' }, @{ Item = 'docker'; State = 'ok'; Detail = 'Linux' },
        @{ Item = 'image'; State = 'ok'; Detail = $digest }, @{ Item = 'updater'; State = 'ok'; Detail = '2.2.0 version gate passed' }) (Join-Path $clone 'status.json')
    Save-Json @{ buildStatusExit = 0; statusExit = 0; buildExit = 0; failExit = 1; writeSite = $true; startExit = 0
        stop = @{ exit = 0; output = 'Drained: no job was running; stopped.'; patch = @{ Supervisor = 'stopped'; Job = 'idle' }; factsPatch = @{}; statusUnreadable = $false; factsUnreadable = $false } } (Join-Path $clone 'behavior.json')
    Save-Json @{ Instance = $Name; Supervisor = 'running (pid 5)'; Job = 'running (worker pid 6)'; Maintenance = $null; Healthy = $true } (Join-Path $clone 'state.json')
    $clone
}
# Runs the host script on fresh fake clones (after $Prepare edits them) and returns Passed and the report text.
function Invoke-Host([string[]] $Stage, [scriptblock] $Prepare = {}, [hashtable] $Extra = @{}, [int] $Count = 1) {
    $root = Join-Path $work ([guid]::NewGuid().ToString('N'))
    $clones = @(1..$Count | ForEach-Object { New-FakeClone $root "win0$_" })
    & $Prepare $clones
    $report = Join-Path $root 'report.md'
    $arguments = @{ Clones = $clones; Stage = $Stage; ReportPath = $report; FixtureDirectory = $fixture } + $Extra
    if ($arguments.ContainsKey('DisruptiveClone')) { $arguments.DisruptiveClone = $clones[0] }
    if ($arguments.ContainsKey('SetupCommand')) { $arguments.SetupCommand = & $arguments.SetupCommand $clones }
    $passed = $true
    try { & $host1 @arguments | Out-Null } catch { $passed = $false; $thrown = $_.Exception.Message }
    [pscustomobject]@{ Passed = $passed; Report = $(if (Test-Path -LiteralPath $report) { Get-Content -Raw -LiteralPath $report } else { $thrown }); Clones = $clones }
}
function Assert-Passes([string] $Case, $Run) { if (-not $Run.Passed) { throw "Case '$Case' should pass:`n$($Run.Report)" } }
function Get-Calls($Run) { Get-Content -Raw "$($Run.Clones[0])\calls.log" }
# A disruptive stage that did not stop the runner for certain must leave maintenance alone: Start ends it, so it never runs.
function Assert-NoStart([string] $Case, $Run) { if ((Get-Calls $Run) -match 'manage Start') { throw "Case '$Case' called Start, which would end the maintenance an unsuccessful stop keeps." } }
function Assert-Fails([string] $Case, [string] $Check, $Run) {
    if ($Run.Passed) { throw "Defect accepted: $Case" }
    if ($Run.Report -notmatch "\| $([regex]::Escape($Check)) \| FAIL \|") { throw "Case '$Case' was rejected, but check '$Check' did not fail:`n$($Run.Report)" }
}
$cases = 0

# --- a healthy host -------------------------------------------------------------------------------------------
$run = Invoke-Host 'Readiness', 'Build', 'Adoption' -Count 2
Assert-Passes 'healthy host' $run
if ($run.Report -notmatch 'NOT RUN \(no evidence collected\): Rerun, Drain, Timeout, Force') { throw "Unselected stages are not reported as NOT RUN:`n$($run.Report)" }
foreach ($clone in $run.Clones) { if (-not ((Get-Content -Raw "$clone\calls.log") -match 'build node-template -AppDir docs')) { throw 'The build type and project arguments were not passed to Invoke-BuildAgent.ps1.' } }

# Optional disabling remains supported for build-only readiness; it is not updater acceptance.
$disabled = Invoke-Host 'Readiness' -Prepare {
    param($c)
    Update-Json "$($c[0])\runners.json" { param($r) $r.buildAgent.updater.version = $null }
    Update-Json "$($c[0])\status.json" { param($rows) $rows[5].State = 'missing' }
}
Assert-Passes 'explicitly disabled updater' $disabled

# --- Readiness / Build / Adoption defects -----------------------------------------------------------------------
$defects = [ordered]@{
    'docker row missing'      = @{ Stage = 'Readiness'; Check = 'status: docker'; Prepare = { param($c) Update-Json "$($c[0])\status.json" { param($rows) $rows[3].State = 'missing' } } }
    'status exit non-zero'    = @{ Stage = 'Readiness'; Check = 'Get-BuildAgentStatus exits 0'; Prepare = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.buildStatusExit = 1 } } }
    'tool version differs'    = @{ Stage = 'Readiness'; Check = 'tool version is the pin'; Prepare = { param($c) Update-Json "$($c[0])\status.json" { param($rows) $rows[0].Detail = 'BuildAgent.Tool 2.0.9 in C:\tool.' } } }
    'image digest differs'    = @{ Stage = 'Readiness'; Check = 'image digest is the pin'; Prepare = { param($c) Update-Json "$($c[0])\status.json" { param($rows) $rows[4].Detail = 'sha256:' + ('0' * 64) } } }
    'pins differ per clone'   = @{ Stage = 'Readiness'; Check = 'clones carry the same pins'; Count = 2; Prepare = { param($c) Update-Json "$($c[1])\runners.json" { param($r) $r.buildAgent.tool.version = '2.0.0' } } }
    'updater version mismatch' = @{ Stage = 'Readiness'; Check = 'updater configuration matches status'; Prepare = { param($c) Update-Json "$($c[0])\runners.json" { param($r) $r.buildAgent.updater.version = '2.3.0' } } }
    'updater status missing' = @{ Stage = 'Readiness'; Check = 'updater configuration matches status'; Prepare = { param($c) Update-Json "$($c[0])\status.json" { param($rows) $rows[5].State = 'missing' } } }
    'build exits non-zero'    = @{ Stage = 'Build'; Check = 'project build exits 0 (node-template)'; Prepare = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.buildExit = 1 } } }
    'site not produced'       = @{ Stage = 'Build'; Check = "expected artifact docs\build\index.html exists in this instance's workspace"; Prepare = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.writeSite = $false } } }
    'failing build exits 0'   = @{ Stage = 'Build'; Check = 'a failing build propagates failure'; Prepare = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.failExit = 0 } } }
    'failing build exits 125' = @{ Stage = 'Build'; Check = 'a failing build propagates failure'; Prepare = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.failExit = 125 } } }
    'not registered'          = @{ Stage = 'Adoption'; Check = 'existing registration adopted (.runner and .credentials)'; Prepare = { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.registered = $false } } }
    'no credentials'          = @{ Stage = 'Adoption'; Check = 'existing registration adopted (.runner and .credentials)'; Prepare = { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.credentials = $false } } }
    'no migration record'     = @{ Stage = 'Adoption'; Check = 'legacy-migration record complete'; Prepare = { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.migration = $null } } }
    'legacy task remains'     = @{ Stage = 'Adoption'; Check = 'no legacy scheduled task runs this clone'; Prepare = { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.legacyTasks[0].Present = $true; $f.legacyTasks[0].RunsThisClone = $true } } }
    'legacy task unreadable'  = @{ Stage = 'Adoption'; Check = 'no legacy scheduled task runs this clone'; Prepare = { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.legacyTasks[0].Error = 'access denied' } } }
    'legacy Run entry'        = @{ Stage = 'Adoption'; Check = 'no legacy Run entry runs this clone'; Prepare = { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.legacyRunEntry.present = $true; $f.legacyRunEntry.runsThisClone = $true } } }
}
foreach ($defect in $defects.GetEnumerator()) {
    $count = if ($defect.Value.Count) { $defect.Value.Count } else { 1 }
    Assert-Fails $defect.Key $defect.Value.Check (Invoke-Host $defect.Value.Stage $defect.Value.Prepare -Count $count)
    $cases++
}
# A legacy task that belongs to another clone is not this clone's defect.
Assert-Passes 'another clone task is ignored' (Invoke-Host 'Adoption' { param($c) Update-Json "$($c[0])\facts.json" { param($f) $f.legacyTasks[0].Present = $true } })

# --- Rerun ------------------------------------------------------------------------------------------------------
$unchanged = { param($c) 'exit 0' }
Assert-Passes 'unchanged rerun' (Invoke-Host 'Rerun' -Extra @{ SetupCommand = $unchanged })
Assert-Fails 'setup rewrote .runner' 'registration and working config files unchanged' (Invoke-Host 'Rerun' -Extra @{ SetupCommand = { param($c) "Set-Content -LiteralPath '$($c[0])\windows\.runner' -Value rewritten" } }); $cases++
Assert-Fails 'setup rewrote local config' 'registration and working config files unchanged' (Invoke-Host 'Rerun' -Extra @{ SetupCommand = { param($c) "Set-Content -LiteralPath '$($c[0])\runners.local.json' -Value '{}'" } }); $cases++
Assert-Fails 'setup deleted credentials' 'registration and working config files unchanged' (Invoke-Host 'Rerun' -Extra @{ SetupCommand = { param($c) "Remove-Item -LiteralPath '$($c[0])\windows\.credentials'" } }); $cases++
Assert-Fails 'agent re-registered' 'agent id and name unchanged' (Invoke-Host 'Rerun' -Extra @{ SetupCommand = { param($c) "`$f = Get-Content -Raw '$($c[0])\facts.json' | ConvertFrom-Json; `$f.agentId = 99; `$f | ConvertTo-Json -Depth 8 | Set-Content '$($c[0])\facts.json'" } }); $cases++
Assert-Fails 'setup fails' 'unchanged setup command exits 0' (Invoke-Host 'Rerun' -Extra @{ SetupCommand = { param($c) 'exit 3' } }); $cases++
$refused = $false
try { & $host1 -Clones @($run.Clones[0]) -Stage Rerun -ReportPath (Join-Path $work 'x.md') | Out-Null } catch { $refused = $_.Exception.Message -match 'SetupCommand' }
if (-not $refused) { throw 'Rerun without -SetupCommand was not refused.' }

# --- Drain, Timeout, Force --------------------------------------------------------------------------------------
foreach ($mode in 'Drain', 'Timeout', 'Force') {
    $refused = $false
    try { & $host1 -Clones @($run.Clones[0]) -Stage $mode -DisruptiveClone $run.Clones[0] -ReportPath (Join-Path $work 'x.md') | Out-Null } catch { $refused = $_.Exception.Message -match 'AllowDisruptive' }
    if (-not $refused) { throw "$mode ran without -AllowDisruptive." }
}
$disruptive = @{ AllowDisruptive = $true; DisruptiveClone = 'set' }
$idle = { param($c) Update-Json "$($c[0])\state.json" { param($s) $s.Job = 'idle' } }
# The real outputs of Manage-WindowsRunner.ps1 -Action Stop: the genuine drain timeout, and stops that failed (maintenance kept).
$timeoutText = 'A job was still running after 1 minutes. Nothing was stopped; the runner takes jobs again (labels restored, maintenance cleared).'
$labelFailText = 'The runner was not stopped; maintenance is kept (admission stays closed) so nothing restarts it. A job was still running after 1 minutes and nothing was stopped, but the labels could not be confirmed back on the runner: boom Fix the cause and rerun, or end maintenance with: Manage-WindowsRunner.ps1 -Action Start'
$stopFailText = 'The runner was not stopped; maintenance is kept (admission stays closed) so nothing restarts it. Still running after the stop: pid 6. Fix the cause and rerun, or end maintenance with: Manage-WindowsRunner.ps1 -Action Start'
$held = [pscustomobject]@{ phase = 'stop-failed'; reason = 'stop'; failure = 'Still running after the stop: pid 6.' }
$stopTimeout = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.exit = 1; $b.stop.output = $timeoutText; $b.stop.patch.Supervisor = 'running (pid 5)'; $b.stop.patch.Job = 'running (worker pid 6)' } }
$stopForce = { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.output = 'Stopped without draining. A running job was cancelled.' } }

Assert-Passes 'drain' (Invoke-Host 'Drain' -Extra $disruptive)
Assert-Passes 'timeout' (Invoke-Host 'Timeout' $stopTimeout $disruptive)
Assert-Passes 'force' (Invoke-Host 'Force' $stopForce $disruptive)
$run = Invoke-Host 'Timeout' $stopTimeout ($disruptive + @{ TimeoutMinutes = 2 })
if ((Get-Content -Raw "$($run.Clones[0])\calls.log") -notmatch 'manage Stop timeout=2 force=False') { throw 'The Timeout stage did not pass -TimeoutMinutes to Stop.' }
if ((Get-Content -Raw "$((Invoke-Host 'Force' $stopForce $disruptive).Clones[0])\calls.log") -notmatch 'manage Stop timeout=0 force=True') { throw 'The Force stage did not pass -Force to Stop.' }

foreach ($mode in 'Drain', 'Timeout', 'Force') {
    Assert-Fails "$mode without a running job" 'a job is already running' (Invoke-Host $mode $idle $disruptive); $cases++
}
Assert-Fails 'drain stop fails' 'Stop exits 0 once the job finished' (Invoke-Host 'Drain' { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.exit = 1 } } $disruptive); $cases++
Assert-Fails 'drain leaves supervisor running' 'runner is stopped and idle afterwards' (Invoke-Host 'Drain' { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.patch.Supervisor = 'running (pid 5)' } } $disruptive); $cases++
Assert-Fails 'timeout exits 0' 'Stop exits 1 when the job outlasts the timeout' (Invoke-Host 'Timeout' { param($c) & $stopTimeout $c; Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.exit = 0 } } $disruptive); $cases++
Assert-Fails 'timeout stops the runner' 'supervisor and job are kept running' (Invoke-Host 'Timeout' { param($c) & $stopTimeout $c; Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.patch.Supervisor = 'stopped' } } $disruptive); $cases++
Assert-Fails 'force does not report the cancel' 'the running job was cancelled and the runner stopped' (Invoke-Host 'Force' { param($c) } $disruptive); $cases++
Assert-Fails 'force leaves a job' 'the running job was cancelled and the runner stopped' (Invoke-Host 'Force' { param($c) & $stopForce $c; Update-Json "$($c[0])\behavior.json" { param($b) $b.stop.patch.Job = 'running (worker pid 6)' } } $disruptive); $cases++
Assert-Fails 'start fails after drain' 'Start restores a healthy runner' (Invoke-Host 'Drain' { param($c) Update-Json "$($c[0])\behavior.json" { param($b) $b.startExit = 1 } } $disruptive); $cases++
Assert-Fails 'unhealthy after start' 'Start restores a healthy runner' (Invoke-Host 'Force' { param($c) & $stopForce $c; Update-Json "$($c[0])\behavior.json" { param($b) $b.statusExit = 1 } } $disruptive); $cases++

# --- Start never follows a stop that failed or could not be verified ---------------------------------------------------
$withheld = 'Start withheld: the stop is not verified, maintenance is preserved'
foreach ($mode in 'Drain', 'Force') {
    $prep = if ($mode -eq 'Force') { $stopForce } else { { param($c) } }
    $broken = [ordered]@{
        'stop exits non-zero'              = { param($b) $b.stop.exit = 1 }
        'stop exits 0, supervisor running' = { param($b) $b.stop.patch.Supervisor = 'running (pid 5)' }
        'stop exits 0, job running'        = { param($b) $b.stop.patch.Job = 'running (worker pid 6)' }
        'status unreadable after the stop' = { param($b) $b.stop.statusUnreadable = $true }
    }
    foreach ($case in $broken.GetEnumerator()) {
        $edit = $case.Value
        $run = Invoke-Host $mode { param($c) & $prep $c; Update-Json "$($c[0])\behavior.json" $edit } $disruptive
        Assert-Fails "$mode, $($case.Key)" $withheld $run
        Assert-NoStart "$mode, $($case.Key)" $run
        $cases++
    }
    # A successful stop still restarts the runner.
    $run = Invoke-Host $mode $prep $disruptive
    Assert-Passes "$mode restarts after a verified stop" $run
    if ((Get-Calls $run) -notmatch 'manage Start') { throw "$mode did not start the runner after a verified stop." }
}

# --- A drain timeout is told apart from a failed stop ------------------------------------------------------------------
$run = Invoke-Host 'Timeout' $stopTimeout $disruptive
Assert-Passes 'genuine timeout' $run
Assert-NoStart 'genuine timeout' $run
$timeoutDefects = [ordered]@{
    'labels not restored, maintenance kept' = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) $b.stop.output = $labelFailText; Set-Prop $b.stop.patch 'Maintenance' ([pscustomobject]@{ phase = 'draining'; reason = 'stop' }); Set-Prop $b.stop.factsPatch 'maintenance' ([pscustomobject]@{ phase = 'draining'; reason = 'stop' }); Set-Prop $b.stop.factsPatch 'customLabels' @() } }
    'labels not restored, reported'         = @{ Check = 'Stop reports the drain timeout, not a failed stop'; Edit = { param($b) $b.stop.output = $labelFailText } }
    'labels gone from GitHub'               = @{ Check = 'custom labels are back at GitHub'; Edit = { param($b) Set-Prop $b.stop.factsPatch 'customLabels' @() } }
    'labels differ from before'             = @{ Check = 'custom labels are back at GitHub'; Edit = { param($b) Set-Prop $b.stop.factsPatch 'customLabels' @('other-label') } }
    'a label is added'                      = @{ Check = 'custom labels are back at GitHub'; Edit = { param($b) Set-Prop $b.stop.factsPatch 'customLabels' @('subzerodev-win01', 'x') } }
    'GitHub cannot say after the stop'      = @{ Check = 'custom labels are back at GitHub'; Edit = { param($b) Set-Prop $b.stop.factsPatch 'gitHubKnown' $false } }
    'other stop failure, exit 1'            = @{ Check = 'Stop reports the drain timeout, not a failed stop'; Edit = { param($b) $b.stop.output = $stopFailText; Set-Prop $b.stop.patch 'Maintenance' $held; Set-Prop $b.stop.factsPatch 'maintenance' $held } }
    'other stop failure keeps maintenance'  = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) $b.stop.output = $stopFailText; Set-Prop $b.stop.patch 'Maintenance' $held; Set-Prop $b.stop.factsPatch 'maintenance' $held } }
    'timeout text but maintenance retained' = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) Set-Prop $b.stop.patch 'Maintenance' $held; Set-Prop $b.stop.factsPatch 'maintenance' $held } }
    'status shows maintenance only'         = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) Set-Prop $b.stop.patch 'Maintenance' $held } }
    'record shows maintenance only'         = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) Set-Prop $b.stop.factsPatch 'maintenance' $held } }
    'maintenance record unreadable'         = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) Set-Prop $b.stop.factsPatch 'maintenance' ([pscustomobject]@{ phase = 'unreadable'; reason = 'bad json' }) } }
    'facts unreadable after the stop'       = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) $b.stop.factsUnreadable = $true } }
    'status unreadable after the stop'      = @{ Check = 'maintenance is cleared (no hold kept)'; Edit = { param($b) $b.stop.statusUnreadable = $true } }
    'exit 0 instead of 1'                   = @{ Check = 'Stop exits 1 when the job outlasts the timeout'; Edit = { param($b) $b.stop.exit = 0 } }
}
foreach ($case in $timeoutDefects.GetEnumerator()) {
    $edit = $case.Value.Edit
    $run = Invoke-Host 'Timeout' { param($c) & $stopTimeout $c; Update-Json "$($c[0])\behavior.json" $edit } $disruptive
    Assert-Fails "timeout, $($case.Key)" $case.Value.Check $run
    Assert-NoStart "timeout, $($case.Key)" $run
    $cases++
}
# Labels the runner never carried before the stop cannot be shown to be restored.
Assert-Fails 'timeout, no labels recorded before' 'custom labels are back at GitHub' (Invoke-Host 'Timeout' { param($c) & $stopTimeout $c; Update-Json "$($c[0])\facts.json" { param($f) $f.admission.customLabels = @() } } $disruptive); $cases++

# --- the real read-only facts script ---------------------------------------------------------------------------------
$facts = & pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\scripts\Get-RunnerFacts.ps1') | Out-String | ConvertFrom-Json
foreach ($name in 'instance', 'windowsRunner', 'registered', 'migration', 'legacyTasks', 'legacyRunEntry', 'admission', 'buildAgent') { if ($facts.PSObject.Properties.Name -notcontains $name) { throw "Get-RunnerFacts.ps1 omits '$name'." } }
if ($facts.buildAgent.version -ne (Get-Content -Raw (Join-Path $PSScriptRoot '..\runners.json') | ConvertFrom-Json).buildAgent.tool.version) { throw 'Get-RunnerFacts.ps1 reports another tool version than runners.json.' }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "PASS: host acceptance accepts a healthy fake host and rejects $($cases + $defects.Count - $defects.Count) injected defects across readiness, build, adoption, rerun, drain, timeout and force; disruptive stages need -AllowDisruptive. Fake clones only; no real host exercised."
