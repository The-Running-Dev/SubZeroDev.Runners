# Shared settings for the host scripts. Dot-source it: . "$PSScriptRoot\Common.ps1"
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'RunnerConfig.ps1')
$Config = Read-RunnerConfig -Root $Root
$LocalConfig = Join-Path $Root 'runners.local.json'

# docker.exe by supported discovery: the configured CLI, PATH, then Docker Desktop's registered install location.
# $null when Docker is not installed.
function Find-DockerExe {
    $configured = $Config.buildAgent.docker.cli
    if ($configured -and (Test-Path -LiteralPath $configured)) { return (Get-CanonicalPath $configured) }
    $command = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop') {
        $location = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).InstallLocation
        if ($location) {
            $candidate = Join-Path $location 'resources\bin\docker.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    $candidate = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
}

# Docker Desktop's own executable, to start it. $null when it is not installed.
function Find-DockerDesktopExe {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Docker Desktop') {
        $location = (Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).InstallLocation
        if ($location -and (Test-Path -LiteralPath (Join-Path $location 'Docker Desktop.exe'))) { return (Join-Path $location 'Docker Desktop.exe') }
    }
    $candidate = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
}

# PowerShell 7 for the supervisor and child scripts: the running one when this is pwsh, else PATH, else the MSI location.
function Find-PwshExe {
    if ($PSVersionTable.PSEdition -eq 'Core') { return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    $command = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
}

$WindowsRunner = Join-Path $Root $Config.windows.directory
$LinuxRunner = Join-Path $Root $Config.linux.directory
# linux.docker.mode 'sidecar': the Linux runner's Docker daemon is a separate docker:dind container.
# 'dind': the runner container runs its own daemon (build-agent's opt-in dockerd) and there is no sidecar.
$DockerSidecar = if ($Config.linux.docker -and $Config.linux.docker.mode -eq 'sidecar') { $Config.linux.docker.container }
# Linux containers in start order; stop them in reverse.
$LinuxContainers = @(@($DockerSidecar, $Config.linux.container) | Where-Object { $_ })
$Docker = Find-DockerExe
if (-not $Docker) { $Docker = 'docker.exe' }
$Pwsh = Find-PwshExe
if (-not $Pwsh) { $Pwsh = 'pwsh.exe' }
$Supervisor = Join-Path $PSScriptRoot 'Run-WindowsRunner.ps1'
$SupervisorPidFile = Join-Path $WindowsRunner 'supervisor.pid'
# Written by the supervisor: what it is doing now. Written by Manage-WindowsRunner: whether it may start the listener.
$SupervisorStatusFile = Join-Path $WindowsRunner 'supervisor.json'
$MaintenanceFile = Join-Path $WindowsRunner 'maintenance.json'
$WindowsMutexName = 'Local\SubZeroDev.Runners.Windows'
# Named instances live in separate clones, with their own supervisor and mutex.
if ($Config.windows.instanceId) { $WindowsMutexName += ".$($Config.windows.instanceId)" }

# Nothing restarts a dead supervisor: no scheduled task, sign-in entry or watchdog. Its child (run.cmd) is restarted by the
# supervisor itself, with backoff. A supervisor that is found dead by its successor this many times in a row is reported as one
# that keeps dying.
$SupervisorRepeatedDeaths = 3
# Deaths further apart than this are not a streak: a supervisor that ran for longer, then died (a reboot, a logoff), starts a new count.
$SupervisorDeathStreakHours = 6
# Housekeeping (Trim-RunnerLogs.ps1) is not scheduled: the job-completed hook runs it when it has not run for this long.
$TrimIntervalHours = 24
$TrimStampFile = Join-Path $WindowsRunner 'last-trim.txt'
# How long Start-WindowsRunner waits for a launched supervisor to write its initialization status before it fails.
$SupervisorStartTimeoutSeconds = [int]$Config.lifecycle.startTimeoutSeconds

# Names this tooling once registered with Windows to start the supervisor at sign-in and trim logs. They exist only so
# Remove-LegacyStartupTasks (LegacyCleanup.ps1) can remove what an earlier version left; nothing registers them any more.
$LegacyTaskPath = '\SubZeroDev.Runners\'
$LegacyStartupValueName = 'SubZeroDev.Runners'
$LegacyWindowsTaskName = 'Start Windows runner'
$LegacyLogTrimTaskName = 'Trim logs'
$LegacyLogonTaskName = 'Start runners'
if ($Config.windows.instanceId) {
    $LegacyWindowsTaskName += " ($($Config.windows.instanceId))"
    $LegacyLogTrimTaskName += " ($($Config.windows.instanceId))"
}
# Written once, by LegacyCleanup.ps1, when this instance's legacy startup entries are verified gone (or never existed). Setup
# verification reads this file; it never asks Task Scheduler.
$LegacyMigrationFile = Join-Path $WindowsRunner 'legacy-migration.json'

# The completed legacy-migration record of this instance; $null when absent, unreadable or incomplete. A file read only.
function Get-LegacyMigration {
    if (-not (Test-Path -LiteralPath $LegacyMigrationFile)) { return }
    try { $record = Get-Content -Raw -LiteralPath $LegacyMigrationFile | ConvertFrom-Json } catch { return }
    if ($record.schema -eq 1 -and $record.kind -and $record.completedUtc) { $record }
}

# supervisor.json as an object; $null when it is absent or unreadable.
function Get-SupervisorStatus {
    if (-not (Test-Path -LiteralPath $SupervisorStatusFile)) { return }
    try { Get-Content -Raw -LiteralPath $SupervisorStatusFile | ConvertFrom-Json } catch { }
}

# Merges $Values into supervisor.json (whoever writes it: the supervisor, or a stop that marks it stopped).
function Set-SupervisorStatusValues([hashtable] $Values) {
    $merged = [ordered]@{}
    $current = Get-SupervisorStatus
    if ($current) { foreach ($property in $current.PSObject.Properties) { $merged[$property.Name] = $property.Value } }
    foreach ($key in $Values.Keys) { $merged[$key] = $Values[$key] }
    $merged['updatedUtc'] = [DateTime]::UtcNow.ToString('o')
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($SupervisorStatusFile)) | Out-Null
    $merged | ConvertTo-Json | Set-Content -LiteralPath $SupervisorStatusFile
}

# What a starting supervisor concludes from the status its predecessor left. A predecessor stopped on purpose is marked
# 'stopped' (by itself, or by Stop-WindowsRunnerProcesses after killing it); any other state means it died without cleaning up,
# which is a recovery. consecutiveRecoveries restarts when the previous recovery is older than $SupervisorDeathStreakHours, or
# when the supervisor sees a run that lasts past the quick-exit threshold.
function Get-SupervisorRecovery($Previous) {
    $count = { param($value) if ($null -ne $value) { [int]$value } else { 0 } }
    $recovery = @{
        recoveries = (& $count $Previous.recoveries); consecutiveRecoveries = (& $count $Previous.consecutiveRecoveries)
        lastRecoveryUtc = $Previous.lastRecoveryUtc; lastRecoveryNote = $Previous.lastRecoveryNote
        repeatedDeaths = $Previous.repeatedDeaths
    }
    if ($Previous -and $Previous.state -and $Previous.state -ne 'stopped') {
        # The supervisor can run for weeks inside one run.cmd, so the streak cannot be ended by a relaunch. A death long after the
        # previous recovery is a new streak, not the third in a row.
        $last = [DateTime]::MinValue
        if ($recovery.lastRecoveryUtc -and [DateTime]::TryParse("$($recovery.lastRecoveryUtc)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $last) -and
            ([DateTime]::UtcNow - $last.ToUniversalTime()).TotalHours -gt $SupervisorDeathStreakHours) {
            $recovery.consecutiveRecoveries = 0
            $recovery.repeatedDeaths = $null
        }
        $recovery.recoveries++
        $recovery.consecutiveRecoveries++
        $recovery.lastRecoveryUtc = [DateTime]::UtcNow.ToString('o')
        $recovery.lastRecoveryNote = "The previous supervisor (pid $($Previous.pid), last state $($Previous.state)) ended without stopping."
        if ($recovery.consecutiveRecoveries -ge $SupervisorRepeatedDeaths) {
            $recovery.repeatedDeaths = "$([DateTime]::UtcNow.ToString('o')): the supervisor has been found dead $($recovery.consecutiveRecoveries) times in a row. Nothing restarts it automatically; if it dies again, start it with Manage-WindowsRunner.ps1 -Action Start."
        }
    }
    $recovery
}

# The running supervisor, found through the pid file it writes. A pid that now belongs to
# another process (stale file after a hard kill) is ignored and the file removed.
function Get-SupervisorProcess {
    if (-not (Test-Path -LiteralPath $SupervisorPidFile)) { return }
    $id = [int](Get-Content -LiteralPath $SupervisorPidFile -TotalCount 1)
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
    if ($process -and $process.CommandLine -and $process.CommandLine.TrimEnd().EndsWith(('"' + $Supervisor + '"'))) { return $process }
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
}

# Runner.Worker processes of this instance. Matched by directory boundary, so instance win1 never claims win10's worker.
function Get-WindowsRunnerWorkers {
    @(Get-CimInstance Win32_Process -Filter "Name='Runner.Worker.exe'" | Where-Object { $_.ExecutablePath -and (Test-PathUnder $_.ExecutablePath $WindowsRunner) })
}

# Runner.Listener processes of this instance (same directory-boundary match as the workers). Besides the lifecycle code, the
# supervisor asks before it launches one: a listener left behind by a supervisor that died must not get a second one beside it.
function Get-WindowsRunnerListeners {
    @(Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" | Where-Object { $_.ExecutablePath -and (Test-PathUnder $_.ExecutablePath $WindowsRunner) })
}

# True while the Windows runner is executing a job (its Runner.Worker exists).
function Test-WindowsRunnerBusy {
    (Get-WindowsRunnerWorkers).Count -gt 0
}

# True while the Linux container is executing a job. $false when Docker or the container is down.
function Test-LinuxRunnerBusy {
    & $Docker exec $Config.linux.container pgrep -f Runner.Worker 2>$null | Out-Null
    $LASTEXITCODE -eq 0
}

# A Windows toast. Clicking it opens $Open (a log file) when given.
function Show-Notification([string] $Title, [string] $Message, [string] $Open) {
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Show-Notification.ps1'), '-Title', $Title, '-Message', $Message)
    if ($Open) { $arguments += '-Open', $Open }
    # Toasts need the WinRT projection, which only Windows PowerShell 5.1 has.
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
}
