# Runner lifecycle: status, drain, stop, start, maintenance. Dot-source Common.ps1 and Registration.ps1 first.
#
# Draining is admission control, not a check followed by a kill. Closing admission means withdrawing the runner's custom
# labels at GitHub (GitHub then assigns it no job that asks for one of them; a job already assigned keeps running), waiting
# until the runner is idle by both its own processes and GitHub's busy flag, and only then stopping it. The labels are put
# back when maintenance ends, and are recorded in the maintenance file first, so a crash cannot lose them.
# What this cannot close: a job that targets only the default labels (self-hosted, Windows, X64). Workflows for these
# runners target the subzerodev-* labels.

# --- maintenance state -------------------------------------------------------------------------------------------

function Get-MaintenanceState([string] $StateFile = $MaintenanceFile) {
    if (Test-Path -LiteralPath $StateFile) {
        try { Get-Content -Raw -LiteralPath $StateFile | ConvertFrom-Json } catch { [pscustomobject]@{ phase = 'unreadable'; reason = $_.Exception.Message } }
    }
}

function Set-MaintenanceState([string] $StateFile, [hashtable] $Values) {
    $current = @{}
    $existing = Get-MaintenanceState $StateFile
    if ($existing) { foreach ($property in $existing.PSObject.Properties) { $current[$property.Name] = $property.Value } }
    foreach ($key in $Values.Keys) { $current[$key] = $Values[$key] }
    $current.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $current | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile
}

# --- processes and GitHub ----------------------------------------------------------------------------------------

function Get-WindowsRunnerListeners {
    @(Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" | Where-Object { $_.ExecutablePath -and (Test-PathUnder $_.ExecutablePath $WindowsRunner) })
}

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

# One object that tells supervisor, listener and GitHub apart.
function Get-WindowsRunnerState {
    $supervisor = Get-SupervisorProcess
    $listeners = Get-WindowsRunnerListeners
    $workers = Get-WindowsRunnerWorkers
    $github = Get-GitHubRunnerState $WindowsRunner
    $status = if (Test-Path -LiteralPath $SupervisorStatusFile) { try { Get-Content -Raw -LiteralPath $SupervisorStatusFile | ConvertFrom-Json } catch { $null } }
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Instance          = if ($Config.windows.instanceId) { $Config.windows.instanceId } else { 'default' }
        Supervisor        = if ($supervisor) { "running (pid $($supervisor.ProcessId))" } else { 'stopped' }
        SupervisorState   = if ($supervisor -and $status) { $status.state } else { $null }
        SupervisorDetail  = $status
        Listener          = if ($listeners) { "running (pid $(($listeners | ForEach-Object ProcessId) -join ','))" } else { 'none' }
        Job               = if ($workers) { "running (worker pid $(($workers | ForEach-Object ProcessId) -join ','))" } else { 'idle' }
        GitHub            = if ($github.Known -and $github.Present) { "$($github.Status)$(if ($github.Busy) { ', busy' })" } elseif ($github.Known) { 'not registered at GitHub' } else { "unknown ($($github.Detail))" }
        Maintenance       = Get-MaintenanceState
        StartupTask       = if ($task) { "$($task.State)" } else { 'not registered' }
        Healthy           = [bool]($supervisor -and $listeners -and $github.Known -and $github.Present -and $github.Status -eq 'online' -and -not (Get-MaintenanceState))
    }
}

# --- admission ---------------------------------------------------------------------------------------------------

# Withdraws the runner's custom labels at GitHub and verifies none remain. Returns what is needed to put them back.
function Close-RunnerAdmission([string] $RunnerDirectory) {
    $local = Get-LocalRegistration $RunnerDirectory
    if (-not $local) { throw "No registration in $RunnerDirectory to close admission for." }
    $scope = Get-RunnerScope $local.gitHubUrl
    $remote = Get-GitHubRunner $scope $local.agentName
    if (-not $remote -or [int64]$remote.Id -ne [int64]$local.agentId) { throw "GitHub's runner '$($local.agentName)' is not this clone's registration (id $($local.agentId))." }
    $saved = @($remote.CustomLabels)
    if ($saved) {
        Remove-GitHubRunnerCustomLabels $scope $remote.Id
        $after = Get-GitHubRunner $scope $local.agentName
        if ($after.CustomLabels) { throw "Custom labels are still on the runner after withdrawing them: $($after.CustomLabels -join ', ')." }
    }
    [pscustomobject]@{ RunnerId = [int64]$remote.Id; Scope = $scope; Labels = $saved }
}

function Open-RunnerAdmission([string] $Scope, [int64] $RunnerId, [string[]] $Labels) {
    if ($Labels) { Add-GitHubRunnerLabels $Scope $RunnerId $Labels }
}

# Ends maintenance: puts the withdrawn labels back and removes the state file.
function Exit-RunnerMaintenance([string] $StateFile, [string] $RunnerDirectory) {
    $state = Get-MaintenanceState $StateFile
    if (-not $state) { return $false }
    if ($state.savedLabels -and $state.scope -and $state.runnerId) {
        $remote = Get-GitHubRunner $state.scope (Get-LocalRegistration $RunnerDirectory).agentName
        $missing = @($state.savedLabels | Where-Object { -not $remote -or $_ -notin $remote.Labels })
        if ($missing) { Open-RunnerAdmission $state.scope ([int64]$state.runnerId) $missing }
    }
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

# Closes admission and waits for idle. Result.Outcome: idle | forced | timeout.
# On timeout nothing is stopped, admission is reopened and Result.Retained says what is still running.
function Enter-RunnerMaintenance {
    param(
        [Parameter(Mandatory)] [string] $StateFile,
        [Parameter(Mandatory)] [string] $RunnerDirectory,
        [Parameter(Mandatory)] [scriptblock] $IsBusy,
        [string] $Reason = 'maintenance',
        [int] $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes,
        [switch] $Force
    )
    $closed = $null
    $admission = 'closed'
    try { $closed = Close-RunnerAdmission $RunnerDirectory }
    catch {
        if (-not $Force) { throw "Could not close admission at GitHub, so a drain would only be a check before a kill: $($_.Exception.Message) Fix gh access, or pass -Force to stop without draining." }
        $admission = "not closed: $($_.Exception.Message)"
    }
    $previous = Get-MaintenanceState $StateFile
    $saved = if ($closed -and $closed.Labels) { @($closed.Labels) } elseif ($previous -and $previous.savedLabels) { @($previous.savedLabels) } else { @() }
    $values = @{ phase = 'draining'; reason = $Reason; sinceUtc = [DateTime]::UtcNow.ToString('o'); savedLabels = $saved }
    if ($closed) { $values.scope = $closed.Scope; $values.runnerId = $closed.RunnerId }
    Set-MaintenanceState $StateFile $values
    if ($Force) { return [pscustomobject]@{ Outcome = 'forced'; Admission = $admission; Retained = $null } }
    $wait = Wait-RunnerIdle -IsBusy $IsBusy -RunnerDirectory $RunnerDirectory -TimeoutMinutes $TimeoutMinutes -PollSeconds $Config.lifecycle.pollSeconds -UseGitHub ([bool]$closed)
    if ($wait.Idle) { return [pscustomobject]@{ Outcome = 'idle'; Admission = $admission; Retained = $null } }
    $retained = "A job was still running after $TimeoutMinutes minutes. Nothing was stopped; the runner takes jobs again (labels restored, maintenance cleared)."
    Exit-RunnerMaintenance $StateFile $RunnerDirectory | Out-Null
    [pscustomobject]@{ Outcome = 'timeout'; Admission = $admission; Retained = $retained }
}

# --- Windows runner commands -------------------------------------------------------------------------------------

function Stop-WindowsRunnerProcesses {
    $supervisor = Get-SupervisorProcess
    if ($supervisor) { & taskkill.exe /PID $supervisor.ProcessId /T /F *> $null }
    # Whatever the tree kill missed: this instance's own listener and worker, matched by directory boundary.
    foreach ($process in @(Get-WindowsRunnerListeners) + @(Get-WindowsRunnerWorkers)) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
}

# Stops this instance's runner after draining it. -Hold keeps maintenance on afterwards, so the startup task idles
# until Start-WindowsRunner. Returns Outcome idle | forced | timeout, plus Retained on timeout.
function Stop-WindowsRunner {
    param([int] $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes, [switch] $Force, [switch] $Hold, [string] $Reason = 'stop')
    $result = Enter-RunnerMaintenance -StateFile $MaintenanceFile -RunnerDirectory $WindowsRunner -IsBusy { Test-WindowsRunnerBusy } -Reason $Reason -TimeoutMinutes $TimeoutMinutes -Force:$Force
    if ($result.Outcome -eq 'timeout') { return $result }
    $cancelled = if ($result.Outcome -eq 'forced' -and (Test-WindowsRunnerBusy)) { 'A running job was cancelled.' }
    Stop-WindowsRunnerProcesses
    if ($Hold) {
        # Stopped, so admission can reopen; the flag stays so nothing restarts the listener.
        $state = Get-MaintenanceState $MaintenanceFile
        if ($state.scope -and $state.savedLabels) {
            try { Open-RunnerAdmission $state.scope ([int64]$state.runnerId) @($state.savedLabels) } catch { $result.Admission += " (labels not restored: $($_.Exception.Message))" }
        }
        Set-MaintenanceState $MaintenanceFile @{ phase = 'held' }
    }
    else { Exit-RunnerMaintenance $MaintenanceFile $WindowsRunner | Out-Null }
    $result | Add-Member -NotePropertyName Cancelled -NotePropertyValue $cancelled -PassThru
}

# Ends maintenance and starts the supervisor (through its task when registered, so it has the task's identity).
function Start-WindowsRunner {
    Exit-RunnerMaintenance $MaintenanceFile $WindowsRunner | Out-Null
    if (Get-SupervisorProcess) { return 'already running' }
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName -ErrorAction SilentlyContinue
    if ($task) { Start-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName; return 'started through its scheduled task' }
    Start-Process $Pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$Supervisor`"") -WorkingDirectory $WindowsRunner -WindowStyle Hidden
    'started directly (no scheduled task is registered)'
}

# --- Linux runner commands ---------------------------------------------------------------------------------------

function Get-LinuxMaintenanceFile { Join-Path $LinuxRunner 'maintenance.json' }

# Runner first, then the Docker sidecar the jobs depend on (reverse of start order).
function Stop-LinuxRunners {
    param([int] $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes, [switch] $Force)
    $registered = Test-Path -LiteralPath (Join-Path $LinuxRunner '.runner')
    $result = [pscustomobject]@{ Outcome = 'idle'; Admission = 'no registration'; Retained = $null }
    if ($registered) {
        $result = Enter-RunnerMaintenance -StateFile (Get-LinuxMaintenanceFile) -RunnerDirectory $LinuxRunner -IsBusy { Test-LinuxRunnerBusy } -Reason 'stop' -TimeoutMinutes $TimeoutMinutes -Force:$Force
        if ($result.Outcome -eq 'timeout') { return $result }
    }
    foreach ($name in @($LinuxContainers)[-1..-@($LinuxContainers).Count]) {
        $output = & $Docker stop --timeout $Config.lifecycle.stopTimeoutSeconds $name 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE) { Write-Warning "docker stop $name exited ${LASTEXITCODE}: $($output -join ' ')" }
    }
    if ($registered) { Exit-RunnerMaintenance (Get-LinuxMaintenanceFile) $LinuxRunner | Out-Null }
    $result
}
