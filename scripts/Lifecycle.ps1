# Runner lifecycle: status, drain, stop, start, maintenance. Dot-source Common.ps1 and Registration.ps1 first.
#
# Draining is admission control, not a check followed by a kill. Closing admission means withdrawing the runner's custom
# labels at GitHub (GitHub then assigns it no job that asks for one of them; a job already assigned keeps running), waiting
# until the runner is idle by both its own processes and GitHub's busy flag, and only then stopping it. The labels are put
# back when maintenance ends. The recovery record (maintenance.json: runner id, scope, the labels it had) is written, atomically,
# BEFORE the first label is withdrawn, and it is removed only after the labels are confirmed back, so a crash or a failed
# call at any point leaves enough to finish the job.
#
# A stop is only reported as done when the resulting state was verified: the container is not running (docker inspect), or
# no supervisor, listener or worker of this instance is left. A command that fails, or a state that cannot be read, is a failed
# stop: maintenance stays on, admission stays closed, and callers must not go on to anything destructive (re-registration).
#
# What this cannot close: a job that targets only the default labels (self-hosted, Windows, X64). Workflows for these
# runners target the subzerodev-* labels.

# --- maintenance state -------------------------------------------------------------------------------------------

function Get-MaintenanceState([string] $StateFile = $MaintenanceFile) {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $state = Get-Content -Raw -LiteralPath $StateFile | ConvertFrom-Json
            if ($null -eq $state) { throw 'The file is empty.' }
            $state
        }
        catch { [pscustomobject]@{ phase = 'unreadable'; reason = $_.Exception.Message } }
    }
}

# Merges $Values into the record and replaces the file in one step (written beside it, flushed, then moved over it), so a
# crash leaves either the previous record or the new one, never half of one. A $null value removes the key.
function Set-MaintenanceState([string] $StateFile, [hashtable] $Values) {
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StateFile)
    $current = @{}
    $existing = Get-MaintenanceState $path
    if ($existing -and $existing.phase -eq 'unreadable') {
        # A record that cannot be read is kept as evidence; nothing can be merged from it.
        Move-Item -LiteralPath $path -Destination ('{0}.unreadable-{1:yyyyMMddHHmmss}' -f $path, [DateTime]::UtcNow) -Force
        $existing = $null
    }
    if ($existing) { foreach ($property in $existing.PSObject.Properties) { $current[$property.Name] = $property.Value } }
    foreach ($key in $Values.Keys) { if ($null -eq $Values[$key]) { $current.Remove($key) } else { $current[$key] = $Values[$key] } }
    $current.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($current | ConvertTo-Json -Depth 5))
    $temp = "$path.tmp"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    $stream = [IO.File]::Create($temp)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [IO.File]::Move($temp, $path, $true)
}

# --- processes and GitHub ----------------------------------------------------------------------------------------

# The GitHub runner behind a registration directory: Status online|offline, Busy, Labels. $null when GitHub cannot say
# (no gh, no network, not registered); Detail then says why.
function Get-GitHubRunnerState([string] $RunnerDirectory) {
    $local = Get-LocalRegistration $RunnerDirectory
    if (-not $local) { return [pscustomobject]@{ Known = $false; Detail = 'not registered' } }
    try {
        $remote = Get-GitHubRunner (Get-RunnerScope $local.gitHubUrl) $local.agentName
        if (-not $remote) { return [pscustomobject]@{ Known = $true; Present = $false; Detail = "GitHub has no runner named $($local.agentName)" } }
        [pscustomobject]@{ Known = $true; Present = $true; Id = $remote.Id; Name = $remote.Name; Status = $remote.Status; Busy = $remote.Busy; Labels = $remote.Labels; CustomLabels = $remote.CustomLabels; Detail = '' }
    }
    catch { [pscustomobject]@{ Known = $false; Detail = $_.Exception.Message } }
}

# What became of the supervisor itself, from its own record. Down = not running although it did not stop on purpose (a stop
# through this tooling marks supervisor.json 'stopped'). Nothing restarts a dead supervisor: it stays down until an explicit Start.
function Get-SupervisorRecoveryReport([bool] $Running, $Status) {
    $down = [bool](-not $Running -and $Status -and $Status.state -and $Status.state -ne 'stopped')
    $summary = @(
        if ($down) { 'The supervisor is not running and did not stop on purpose. Nothing restarts it automatically; start it: Manage-WindowsRunner.ps1 -Action Start.' }
        if ($Status.repeatedDeaths) { [string]$Status.repeatedDeaths }
    )
    [pscustomobject]@{
        Recoveries = if ($Status.recoveries) { [int]$Status.recoveries } else { 0 }; ConsecutiveRecoveries = if ($Status.consecutiveRecoveries) { [int]$Status.consecutiveRecoveries } else { 0 }
        LastRecoveryUtc = $Status.lastRecoveryUtc; LastRecoveryNote = $Status.lastRecoveryNote
        Down = $down; Summary = @($summary)
    }
}

# One object that tells supervisor, listener and GitHub apart.
function Get-WindowsRunnerState {
    # Not $supervisor: variable names are case-insensitive and a function sees its callers' variables, so a local of that name
    # would hide $Supervisor (the script's path) from Get-SupervisorProcess.
    $supervisorProcess = Get-SupervisorProcess
    $listeners = Get-WindowsRunnerListeners
    $workers = Get-WindowsRunnerWorkers
    $github = Get-GitHubRunnerState $WindowsRunner
    $status = Get-SupervisorStatus
    [pscustomobject]@{
        SupervisorRecovery = Get-SupervisorRecoveryReport ([bool]$supervisorProcess) $status
        Instance          = if ($Config.windows.instanceId) { $Config.windows.instanceId } else { 'default' }
        Supervisor        = if ($supervisorProcess) { "running (pid $($supervisorProcess.ProcessId))" } else { 'stopped' }
        SupervisorState   = if ($supervisorProcess -and $status) { $status.state } else { $null }
        SupervisorDetail  = $status
        Listener          = if ($listeners) { "running (pid $(($listeners | ForEach-Object ProcessId) -join ','))" } else { 'none' }
        Job               = if ($workers) { "running (worker pid $(($workers | ForEach-Object ProcessId) -join ','))" } else { 'idle' }
        GitHub            = if ($github.Known -and $github.Present) { "$($github.Status)$(if ($github.Busy) { ', busy' })" } elseif ($github.Known) { 'not registered at GitHub' } else { "unknown ($($github.Detail))" }
        Maintenance       = Get-MaintenanceState
        Healthy           = [bool]($supervisorProcess -and $listeners -and $github.Known -and $github.Present -and $github.Status -eq 'online' -and -not (Get-MaintenanceState))
    }
}
# --- admission ---------------------------------------------------------------------------------------------------

# Who would be drained and which custom labels it has now, after checking that GitHub's runner is this clone's registration.
# Changes nothing, so the recovery record can be written before the first change.
function Get-RunnerAdmission([string] $RunnerDirectory) {
    $local = Get-LocalRegistration $RunnerDirectory
    if (-not $local) { throw "No registration in $RunnerDirectory to close admission for." }
    $scope = Get-RunnerScope $local.gitHubUrl
    $remote = Get-GitHubRunner $scope $local.agentName
    if (-not $remote -or [int64]$remote.Id -ne [int64]$local.agentId) { throw "GitHub's runner '$($local.agentName)' is not this clone's registration (id $($local.agentId))." }
    [pscustomobject]@{ RunnerId = [int64]$remote.Id; AgentName = $local.agentName; Scope = $scope; Labels = @($remote.CustomLabels) }
}

# Withdraws the runner's custom labels at GitHub and verifies, by reading the runner again, that none remain.
function Close-RunnerAdmission($Admission) {
    if (-not $Admission.Labels) { return }
    Remove-GitHubRunnerCustomLabels $Admission.Scope $Admission.RunnerId
    $after = Get-GitHubRunner $Admission.Scope $Admission.AgentName
    if (-not $after -or [int64]$after.Id -ne $Admission.RunnerId) { throw "Runner $($Admission.RunnerId) could not be read back after withdrawing its labels." }
    if ($after.CustomLabels) { throw "Custom labels are still on the runner after withdrawing them: $($after.CustomLabels -join ', ')." }
}

function Open-RunnerAdmission([string] $Scope, [int64] $RunnerId, [string[]] $Labels) {
    if ($Labels) { Add-GitHubRunnerLabels $Scope $RunnerId $Labels }
}

# Puts back the labels the record holds. The runner at GitHub must still be the one that was drained (same id as the clone's
# registration and the record), and every recorded label must be on it afterwards; otherwise this throws and the caller keeps
# the record. Safe to repeat: only labels that are missing are added.
function Restore-RunnerAdmission($State, [string] $RunnerDirectory) {
    $labels = @($State.savedLabels)
    if (-not $labels -or -not $State.scope -or -not $State.runnerId) { return 'nothing to restore' }
    $local = Get-LocalRegistration $RunnerDirectory
    if (-not $local) { throw "The recovery record holds labels of runner $($State.runnerId), but $RunnerDirectory has no registration." }
    if ([int64]$local.agentId -ne [int64]$State.runnerId) { throw "The recovery record is for runner $($State.runnerId); this clone is registered as runner $($local.agentId). Labels not restored." }
    $remote = Get-GitHubRunner $State.scope $local.agentName
    if (-not $remote) { return "GitHub no longer has runner '$($local.agentName)'; nothing to restore" }
    if ([int64]$remote.Id -ne [int64]$State.runnerId) { throw "GitHub's runner '$($local.agentName)' is id $($remote.Id), not $($State.runnerId) from the recovery record. Labels not restored." }
    $missing = @($labels | Where-Object { $_ -notin $remote.Labels })
    if (-not $missing) { return 'labels already present' }
    Open-RunnerAdmission $State.scope ([int64]$State.runnerId) $missing
    $after = Get-GitHubRunner $State.scope $local.agentName
    $still = @($missing | Where-Object { -not $after -or $_ -notin $after.Labels })
    if ($still) { throw "Labels are still missing at GitHub after restoring them: $($still -join ', ')." }
    'restored'
}

# Ends maintenance: puts the withdrawn labels back, then removes the record. The record stays whenever the restoration is not
# confirmed, so ending maintenance again (or after a crash) finishes the job. $false when there was nothing to end.
function Exit-RunnerMaintenance([string] $StateFile, [string] $RunnerDirectory) {
    $state = Get-MaintenanceState $StateFile
    if (-not $state) { return $false }
    if ($state.phase -eq 'unreadable') { throw "The maintenance record $StateFile cannot be read ($($state.reason)), so the withdrawn labels are unknown and it was kept. Restore the runner's labels at GitHub, then delete the file." }
    Restore-RunnerAdmission $state $RunnerDirectory | Out-Null
    Remove-Item -LiteralPath $StateFile -Force
    $true
}

# Idle means not busy by local processes and by GitHub's flag, seen twice in a row two seconds apart.
function Wait-RunnerIdle {
    param([scriptblock] $IsBusy, [string] $RunnerDirectory, [int] $TimeoutMinutes, [int] $PollSeconds, [bool] $UseGitHub = $true)
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $idleSeen = 0
    while ($true) {
        $busy = [bool](& $IsBusy)
        if (-not $busy -and $UseGitHub) {
            $github = Get-GitHubRunnerState $RunnerDirectory
            if ($github.Known -and $github.Present -and $github.Busy) { $busy = $true }
        }
        if ($busy) { $idleSeen = 0 } else { $idleSeen++ }
        if ($idleSeen -ge 2) { return [pscustomobject]@{ Idle = $true; TimedOut = $false } }
        if ($busy -and [DateTime]::UtcNow -ge $deadline) { return [pscustomobject]@{ Idle = $false; TimedOut = $true } }
        Start-Sleep -Seconds $(if ($busy) { $PollSeconds } else { 2 })
    }
}

# Closes admission and waits for idle. Result.Outcome: idle | forced | timeout | failed (timed out, and the labels could not be
# confirmed back: Failures says so and the recovery record is kept).
# The recovery record is written before any label is withdrawn: phase 'closing', then 'draining' once the withdrawal is
# verified. If the withdrawal fails or cannot be verified the labels are put back at once, and the record stays when that
# cannot be confirmed either. On timeout nothing is stopped, admission is reopened and Result.Retained says what is still running.
function Enter-RunnerMaintenance {
    param(
        [Parameter(Mandatory)] [string] $StateFile,
        [Parameter(Mandatory)] [string] $RunnerDirectory,
        [Parameter(Mandatory)] [scriptblock] $IsBusy,
        [string] $Reason = 'maintenance',
        [int] $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes,
        [switch] $Force
    )
    $previous = Get-MaintenanceState $StateFile
    if ($previous -and $previous.phase -eq 'unreadable') { $previous = $null }
    $admission = $null
    $note = 'closed'
    try { $admission = Get-RunnerAdmission $RunnerDirectory }
    catch {
        if (-not $Force) { throw "Could not close admission at GitHub, so a drain would only be a check before a kill: $($_.Exception.Message) Fix gh access, or pass -Force to stop without draining." }
        $note = "not closed: $($_.Exception.Message)"
    }
    # A repeated drain finds the labels already withdrawn: what an earlier attempt recorded stays recorded.
    $saved = @()
    if ($previous -and $previous.savedLabels -and (-not $admission -or [int64]$previous.runnerId -eq $admission.RunnerId)) { $saved += @($previous.savedLabels) }
    if ($admission) { $saved += @($admission.Labels) }
    $values = @{
        phase = if ($admission -and $admission.Labels) { 'closing' } else { 'draining' }
        reason = $Reason; sinceUtc = [DateTime]::UtcNow.ToString('o'); savedLabels = @($saved | Select-Object -Unique); failure = $null
    }
    if ($admission) { $values.scope = $admission.Scope; $values.runnerId = $admission.RunnerId; $values.agentName = $admission.AgentName }
    # Nothing has changed at GitHub yet, so a failure here loses nothing.
    Set-MaintenanceState $StateFile $values
    if ($admission -and $admission.Labels) {
        try { Close-RunnerAdmission $admission; Set-MaintenanceState $StateFile @{ phase = 'draining' } }
        catch {
            $closeError = $_.Exception.Message
            if ($Force) { $note = "not closed: $closeError" }
            else {
                $restoreError = $null
                try { Exit-RunnerMaintenance $StateFile $RunnerDirectory | Out-Null } catch { $restoreError = $_.Exception.Message }
                if (-not $restoreError) { throw "Could not close admission at GitHub: $closeError The labels are confirmed back on the runner; nothing was stopped." }
                throw "Could not close admission at GitHub: $closeError The labels could not be confirmed back ($restoreError). The recovery record $StateFile keeps them; ending maintenance (Manage-WindowsRunner.ps1 -Action Start, or rerunning this command) restores them."
            }
        }
    }
    if ($Force) { return [pscustomobject]@{ Outcome = 'forced'; Admission = $note; Retained = $null } }
    $wait = Wait-RunnerIdle -IsBusy $IsBusy -RunnerDirectory $RunnerDirectory -TimeoutMinutes $TimeoutMinutes -PollSeconds $Config.lifecycle.pollSeconds -UseGitHub ([bool]$admission)
    if ($wait.Idle) { return [pscustomobject]@{ Outcome = 'idle'; Admission = $note; Retained = $null } }
    $retained = "A job was still running after $TimeoutMinutes minutes. Nothing was stopped; the runner takes jobs again (labels restored, maintenance cleared)."
    # Reopening admission can fail like any other GitHub call: report it as an outcome, with the record kept, rather than throwing
    # past callers that only look at Outcome.
    try { Exit-RunnerMaintenance $StateFile $RunnerDirectory | Out-Null }
    catch {
        return [pscustomobject]@{
            Outcome = 'failed'; Admission = $note; Retained = $retained; Cancelled = $null
            Failures = @("A job was still running after $TimeoutMinutes minutes and nothing was stopped, but the labels could not be confirmed back on the runner: $($_.Exception.Message) The recovery record $StateFile keeps them; ending maintenance (Manage-WindowsRunner.ps1 -Action Start, or rerunning this command) restores them.")
        }
    }
    [pscustomobject]@{ Outcome = 'timeout'; Admission = $note; Retained = $retained }
}

# --- Windows runner commands -------------------------------------------------------------------------------------

function Invoke-TaskKill([int] $ProcessId) {
    try {
        $output = & taskkill.exe /PID $ProcessId /T /F 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join ' ').Trim() }
    }
    catch { [pscustomobject]@{ ExitCode = $null; Output = $_.Exception.Message } }
}

# What is left of this instance's runner: supervisor, listener, worker. Throws when that cannot be determined.
function Get-WindowsRunnerSurvivors {
    @(@(Get-SupervisorProcess) + @(Get-WindowsRunnerListeners) + @(Get-WindowsRunnerWorkers) | Where-Object { $_ })
}

# Stops supervisor, listener and worker, then asks again what is left. Stopped is true only when that second look found
# nothing; a command's own exit status is only a detail. A look that fails is an unverified stop. The supervisor's pid file is
# removed, and supervisor.json marked 'stopped', only on success: a supervisor that may still be alive must leave its record as is.
# Nothing else can restart the supervisor, so its absence is the whole condition.
function Stop-WindowsRunnerProcesses {
    param([int] $WaitSeconds = [Math]::Min(10, [int]$Config.lifecycle.stopTimeoutSeconds))
    $details = @()
    $left = @()
    try {
        $supervisorProcess = Get-SupervisorProcess
        if ($supervisorProcess) {
            $kill = Invoke-TaskKill $supervisorProcess.ProcessId
            if ($kill.ExitCode -ne 0) { $details += "taskkill of the supervisor (pid $($supervisorProcess.ProcessId)) exited $($kill.ExitCode): $($kill.Output)" }
        }
        # Whatever the tree kill missed: this instance's own listener and worker, matched by directory boundary.
        foreach ($process in @(@(Get-WindowsRunnerListeners) + @(Get-WindowsRunnerWorkers) | Where-Object { $_ })) {
            try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop } catch { $details += "Stop-Process of pid $($process.ProcessId) failed: $($_.Exception.Message)" }
        }
        $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
        while ($true) {
            $left = @(Get-WindowsRunnerSurvivors)
            if (-not $left -or [DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    catch {
        return [pscustomobject]@{ Stopped = $false; Failures = @($details + "Could not verify that the runner processes are gone: $($_.Exception.Message)"); Remaining = @() }
    }
    if ($left) {
        $ids = ($left | ForEach-Object { $_.ProcessId }) -join ', '
        return [pscustomobject]@{ Stopped = $false; Failures = @($details + "Still running after the stop: pid $ids."); Remaining = $left }
    }
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
    # Killed on purpose, so its successor must not read the stale 'running' status as a crash.
    try { if (Test-Path -LiteralPath $SupervisorStatusFile) { Set-SupervisorStatusValues @{ state = 'stopped'; pid = $null } } } catch { }
    [pscustomobject]@{ Stopped = $true; Failures = @(); Remaining = @() }
}
function New-StopFailure($Result, [string[]] $Failures, $Cancelled) {
    [pscustomobject]@{ Outcome = 'failed'; Admission = $Result.Admission; Retained = $null; Failures = @($Failures); Cancelled = $Cancelled }
}

# Stops this instance's runner after draining it. -Hold keeps maintenance on afterwards, so a supervisor that is started
# idles until Start-WindowsRunner removes the flag. Returns Outcome idle | forced | timeout | failed, plus Retained on timeout and Failures on failed.
# 'failed': a process survived the stop, the stop could not be verified, or the labels could not be confirmed back. Maintenance
# is kept (phase 'stop-failed' with the reason) and admission is not reopened for a runner that did not stop.
function Stop-WindowsRunner {
    param([int] $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes, [switch] $Force, [switch] $Hold, [string] $Reason = 'stop')
    $result = Enter-RunnerMaintenance -StateFile $MaintenanceFile -RunnerDirectory $WindowsRunner -IsBusy { Test-WindowsRunnerBusy } -Reason $Reason -TimeoutMinutes $TimeoutMinutes -Force:$Force
    if ($result.Outcome -in 'timeout', 'failed') { return $result }
    $cancelled = if ($result.Outcome -eq 'forced' -and (Test-WindowsRunnerBusy)) { 'A running job was cancelled.' }
    $stop = Stop-WindowsRunnerProcesses
    if (-not $stop.Stopped) {
        Set-MaintenanceState $MaintenanceFile @{ phase = 'stop-failed'; failure = ($stop.Failures -join ' '); failedUtc = [DateTime]::UtcNow.ToString('o') }
        return New-StopFailure $result $stop.Failures $cancelled
    }
    if ($Hold) {
        # Stopped, so admission can reopen; the flag stays so nothing restarts the listener.
        $state = Get-MaintenanceState $MaintenanceFile
        try { Restore-RunnerAdmission $state $WindowsRunner | Out-Null } catch { $result.Admission += " (labels not restored: $($_.Exception.Message))" }
        Set-MaintenanceState $MaintenanceFile @{ phase = 'held' }
    }
    else {
        try { Exit-RunnerMaintenance $MaintenanceFile $WindowsRunner | Out-Null }
        catch { return New-StopFailure $result @("The runner stopped, but ending maintenance failed and the record was kept: $($_.Exception.Message)") $cancelled }
    }
    $result | Add-Member -NotePropertyName Cancelled -NotePropertyValue $cancelled -PassThru
}

# supervisor.json as written by supervisor $ProcessId once it initialized: its own pid, a start time not before $Since, and a
# live state. A leftover file of an earlier supervisor (another pid, an older start, 'stopped') is not evidence. $null if none.
function Get-SupervisorInitialization([int] $ProcessId, [datetime] $Since) {
    $status = Get-SupervisorStatus
    if (-not $status -or $status.pid -ne $ProcessId -or -not $status.startedUtc) { return }
    # 'starting' is the first thing the supervisor writes, before it has entered its loop: it proves nothing yet. The states below
    # are written only from inside the loop ('restarting' is the pause between two launches of run.cmd).
    if ($status.state -notin 'running', 'restarting', 'backoff', 'maintenance', 'waiting-for-orphan') { return }
    try { $startedUtc = ([datetime]$status.startedUtc).ToUniversalTime() } catch { return }
    if ($startedUtc -lt $Since.ToUniversalTime()) { return }
    $status
}

# Waits, bounded, until the supervisor process $Process of this instance has initialized (Get-SupervisorInitialization) and is
# still the process Get-SupervisorProcess identifies. Not enough: a process object, a pid file, an old supervisor.json, or a
# listener that is online with GitHub. Throws, naming the exit code when there is one, if it exits first or the time runs out.
# A launched process that exits 0 because another supervisor of this instance holds the mutex adopts that one if it has
# initialized. This confirms initialization, not that the supervisor stays up: nothing restarts a supervisor that dies later.
function Wait-SupervisorInitialized {
    param([object] $Process, [datetime] $Since, [int] $TimeoutSeconds = $SupervisorStartTimeoutSeconds)
    $expectedId = [int]$Process.Id
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $adoptDeadline = $null
    while ($true) {
        $found = Get-SupervisorProcess
        if ($found -and [int]$found.ProcessId -eq $expectedId) {
            $initialized = Get-SupervisorInitialization $expectedId $Since
            if ($initialized) { return [pscustomobject]@{ ProcessId = $expectedId; State = $initialized.state; Adopted = ($expectedId -ne [int]$Process.Id) } }
        }
        $last = Get-SupervisorStatus
        $seen = if ($last) { "supervisor.json: pid $($last.pid), state $($last.state), started $($last.startedUtc)" } else { 'no supervisor.json' }
        if ($expectedId -eq [int]$Process.Id -and $Process.PSObject.Properties['HasExited'] -and $Process.HasExited) {
            $exitCode = $Process.ExitCode
            $winner = Get-SupervisorProcess
            if ($exitCode -eq 0 -and $winner -and [int]$winner.ProcessId -ne $expectedId) { $expectedId = [int]$winner.ProcessId; $Since = [datetime]::MinValue; continue }
            # Exit 0 is what a supervisor that lost the mutex does. The winner may not have published its pid file yet (it takes
            # the mutex first), so give it a short, bounded moment before calling this a failure.
            if ($exitCode -eq 0) {
                if (-not $adoptDeadline) { $adoptDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Min(5, $TimeoutSeconds)) }
                if ([DateTime]::UtcNow -lt $adoptDeadline -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250; continue }
            }
            throw "The supervisor (pid $($Process.Id)) exited with code $exitCode before it initialized ($seen). Run it in a console to see why: pwsh -File `"$Supervisor`""
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "The supervisor (pid $expectedId) did not report that it initialized within $TimeoutSeconds seconds ($seen). If it is still running, stop it with Manage-WindowsRunner.ps1 -Action Stop; run it in a console to see why: pwsh -File `"$Supervisor`""
        }
        Start-Sleep -Milliseconds 250
    }
}

# Ends maintenance and starts the supervisor as a detached, hidden process of this user, and returns only once that supervisor
# has confirmed it initialized (Wait-SupervisorInitialized); it throws if it exited, never initialized or timed out. A supervisor
# that is already running is never started twice or interrupted (its mutex would also refuse a second one), and its identity and
# initialization are verified the same way. Nothing starts it at sign-in and nothing restarts it if it dies: this is the only
# way it starts. A supervisor found dead without a clean stop is recorded by the next supervisor (Get-SupervisorRecovery), so
# starting it by hand keeps that history. A supervisor waiting for an orphaned listener says so; it starts no second listener.
function Start-WindowsRunner {
    param([int] $TimeoutSeconds = $SupervisorStartTimeoutSeconds)
    Exit-RunnerMaintenance $MaintenanceFile $WindowsRunner | Out-Null
    $running = Get-SupervisorProcess
    if ($running) { $ready = Wait-SupervisorInitialized ([pscustomobject]@{ Id = $running.ProcessId }) ([datetime]::MinValue) $TimeoutSeconds }
    else {
        $launchedUtc = [DateTime]::UtcNow.AddSeconds(-2)
        # The command line ends with the quoted script path: Get-SupervisorProcess recognises the supervisor by that.
        $process = Start-Process $Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Supervisor`"") -WorkingDirectory $WindowsRunner -WindowStyle Hidden -PassThru
        $ready = Wait-SupervisorInitialized $process $launchedUtc $TimeoutSeconds
    }
    $note = ''
    if ($ready.State -eq 'waiting-for-orphan') {
        $listeners = @(Get-WindowsRunnerListeners | ForEach-Object { $_.ProcessId }) -join ', '
        $note = " - waiting for the existing listener (pid $listeners) to exit; no second listener is started"
    }
    elseif ($ready.State -eq 'maintenance') { $note = ' - in maintenance, no listener until maintenance ends' }
    "$(if ($running -or $ready.Adopted) { 'already running' } else { 'started' }) (pid $($ready.ProcessId))$note"
}
# --- Linux runner commands ---------------------------------------------------------------------------------------

function Get-LinuxMaintenanceFile { Join-Path $LinuxRunner 'maintenance.json' }

# Runs docker and returns its exit code and output. ExitCode is $null when docker could not be run at all.
function Invoke-Docker([string[]] $Arguments) {
    try {
        $output = & $Docker @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join ' ').Trim() }
    }
    catch { [pscustomobject]@{ ExitCode = $null; Output = $_.Exception.Message } }
}

# running | stopped | absent | unknown. Unknown (docker unavailable, daemon unreachable, unexpected answer) is never treated
# as stopped.
function Get-ContainerState([string] $Name) {
    $inspect = Invoke-Docker @('container', 'inspect', '--format', '{{.State.Running}}', $Name)
    if ($null -eq $inspect.ExitCode) { return [pscustomobject]@{ State = 'unknown'; Detail = $inspect.Output } }
    if ($inspect.ExitCode -eq 0) {
        switch ($inspect.Output) {
            'true' { return [pscustomobject]@{ State = 'running'; Detail = '' } }
            'false' { return [pscustomobject]@{ State = 'stopped'; Detail = '' } }
        }
        return [pscustomobject]@{ State = 'unknown'; Detail = "docker inspect answered '$($inspect.Output)'" }
    }
    if ($inspect.Output -match 'No such (container|object)') { return [pscustomobject]@{ State = 'absent'; Detail = '' } }
    [pscustomobject]@{ State = 'unknown'; Detail = "docker inspect exited $($inspect.ExitCode): $($inspect.Output)" }
}

# Result: already-stopped | absent | stopped | failed. A stop is checked by looking at the container afterwards; 'failed' covers
# a container that is still running and one whose state could not be read.
function Stop-LinuxContainer([string] $Name) {
    $before = Get-ContainerState $Name
    if ($before.State -eq 'stopped') { return [pscustomobject]@{ Name = $Name; Result = 'already-stopped'; Detail = '' } }
    if ($before.State -eq 'absent') { return [pscustomobject]@{ Name = $Name; Result = 'absent'; Detail = '' } }
    $stop = Invoke-Docker @('stop', '--timeout', "$($Config.lifecycle.stopTimeoutSeconds)", $Name)
    $after = Get-ContainerState $Name
    switch ($after.State) {
        { $_ -in 'stopped', 'absent' } { return [pscustomobject]@{ Name = $Name; Result = 'stopped'; Detail = if ($stop.ExitCode) { "docker stop exited $($stop.ExitCode): $($stop.Output)" } else { '' } } }
        'running' { return [pscustomobject]@{ Name = $Name; Result = 'failed'; Detail = "$Name is still running after docker stop exited $($stop.ExitCode): $($stop.Output)" } }
    }
    [pscustomobject]@{ Name = $Name; Result = 'failed'; Detail = "The state of $Name could not be verified after docker stop (exit $($stop.ExitCode): $($stop.Output)); $($after.Detail)" }
}

# Stops and removes a container, verified. Result: absent | removed | failed.
function Remove-LinuxContainer([string] $Name) {
    $stop = Stop-LinuxContainer $Name
    if ($stop.Result -eq 'failed') { return $stop }
    if ($stop.Result -eq 'absent') { return $stop }
    $remove = Invoke-Docker @('rm', $Name)
    $after = Get-ContainerState $Name
    if ($after.State -eq 'absent') { return [pscustomobject]@{ Name = $Name; Result = 'removed'; Detail = '' } }
    [pscustomobject]@{ Name = $Name; Result = 'failed'; Detail = "$Name is still $($after.State) after docker rm exited $($remove.ExitCode): $($remove.Output) $($after.Detail)".Trim() }
}

# Runner first, then the Docker sidecar the jobs depend on (reverse of start order). Outcome idle | forced | timeout | failed.
# 'failed': a container did not stop (or its state could not be verified) or the labels could not be confirmed back. The
# containers after a failed one are left alone, maintenance is kept (phase 'stop-failed') and admission is not reopened.
function Stop-LinuxRunners {
    param([int] $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes, [switch] $Force)
    $registered = Test-Path -LiteralPath (Join-Path $LinuxRunner '.runner')
    $result = [pscustomobject]@{ Outcome = 'idle'; Admission = 'no registration'; Retained = $null }
    if ($registered) {
        $result = Enter-RunnerMaintenance -StateFile (Get-LinuxMaintenanceFile) -RunnerDirectory $LinuxRunner -IsBusy { Test-LinuxRunnerBusy } -Reason 'stop' -TimeoutMinutes $TimeoutMinutes -Force:$Force
        if ($result.Outcome -in 'timeout', 'failed') { return $result }
    }
    $containers = @()
    $failed = $null
    foreach ($name in @($LinuxContainers)[-1..-@($LinuxContainers).Count]) {
        if ($failed) { $containers += [pscustomobject]@{ Name = $name; Result = 'skipped'; Detail = "not touched because $($failed.Name) did not stop" }; continue }
        $stop = Stop-LinuxContainer $name
        $containers += $stop
        if ($stop.Result -eq 'failed') { $failed = $stop }
    }
    if ($failed) {
        if ($registered) { Set-MaintenanceState (Get-LinuxMaintenanceFile) @{ phase = 'stop-failed'; failure = $failed.Detail; failedUtc = [DateTime]::UtcNow.ToString('o') } }
        return [pscustomobject]@{ Outcome = 'failed'; Admission = $result.Admission; Retained = $null; Failures = @($failed.Detail); Containers = $containers }
    }
    if ($registered) {
        try { Exit-RunnerMaintenance (Get-LinuxMaintenanceFile) $LinuxRunner | Out-Null }
        catch { return [pscustomobject]@{ Outcome = 'failed'; Admission = $result.Admission; Retained = $null; Failures = @("The containers stopped, but ending maintenance failed and the record was kept: $($_.Exception.Message)"); Containers = $containers } }
    }
    $result | Add-Member -NotePropertyName Containers -NotePropertyValue $containers -PassThru
}
