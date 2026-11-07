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

# PowerShell 7 for scheduled tasks and child scripts: the running one when this is pwsh, else PATH, else the MSI location.
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
$StartupValueName = 'SubZeroDev.Runners'
$TaskPath = '\SubZeroDev.Runners\'
$WindowsMutexName = 'Local\SubZeroDev.Runners.Windows'
$WindowsTaskName = 'Start Windows runner'
$LogTrimTaskName = 'Trim logs'
# Named instances live in separate clones, with their own tasks and supervisor.
if ($Config.windows.instanceId) {
    $WindowsMutexName += ".$($Config.windows.instanceId)"
    $WindowsTaskName += " ($($Config.windows.instanceId))"
    $LogTrimTaskName += " ($($Config.windows.instanceId))"
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

# A hidden, profile-free pwsh command line for a script in this folder.
function Get-HiddenPwshCommand([string] $Script) {
    "`"$Pwsh`" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot $Script)`""
}
