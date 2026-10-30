# Shared settings for the host scripts. Dot-source it: . "$PSScriptRoot\Common.ps1"
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Config = Get-Content -Raw (Join-Path $Root 'runners.json') | ConvertFrom-Json
# runners.local.json (git-ignored) holds this machine's settings, such as github.url, over runners.json's. Objects merge
# setting by setting at every level, so { "linux": { "docker": { "mode": "dind" } } } changes only that mode.
function Merge-Settings($Target, $Source) {
    foreach ($setting in $Source.PSObject.Properties) {
        $current = $Target.($setting.Name)
        if ($current -is [pscustomobject] -and $setting.Value -is [pscustomobject]) { Merge-Settings $current $setting.Value }
        else { $Target | Add-Member -Force -NotePropertyName $setting.Name -NotePropertyValue $setting.Value }
    }
}
$LocalConfig = Join-Path $Root 'runners.local.json'
if (Test-Path -LiteralPath $LocalConfig) { Merge-Settings $Config (Get-Content -Raw $LocalConfig | ConvertFrom-Json) }
$WindowsRunner = Join-Path $Root $Config.windows.directory
$LinuxRunner = Join-Path $Root $Config.linux.directory
# linux.docker.mode 'sidecar': the Linux runner's Docker daemon is a separate docker:dind container.
# 'dind': the runner container runs its own daemon (build-agent's opt-in dockerd) and there is no sidecar.
$DockerSidecar = if ($Config.linux.docker -and $Config.linux.docker.mode -eq 'sidecar') { $Config.linux.docker.container }
# Linux containers in start order; stop them in reverse.
$LinuxContainers = @(@($DockerSidecar, $Config.linux.container) | Where-Object { $_ })
$Docker = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
$Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$Supervisor = Join-Path $PSScriptRoot 'Run-WindowsRunner.ps1'
$SupervisorPidFile = Join-Path $WindowsRunner 'supervisor.pid'
$StartupValueName = 'SubZeroDev.Runners'
$TaskPath = '\SubZeroDev.Runners\'

# The running supervisor, found through the pid file it writes. A pid that now belongs to
# another process (stale file after a hard kill) is ignored and the file removed.
function Get-SupervisorProcess {
    if (-not (Test-Path -LiteralPath $SupervisorPidFile)) { return }
    $id = [int](Get-Content -LiteralPath $SupervisorPidFile -TotalCount 1)
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
    if ($process -and $process.CommandLine -and $process.CommandLine.TrimEnd().EndsWith(('"' + $Supervisor + '"'))) { return $process }
    Remove-Item -LiteralPath $SupervisorPidFile -ErrorAction SilentlyContinue
}

# True while the Windows runner is executing a job (its Runner.Worker exists).
function Test-WindowsRunnerBusy {
    [bool](Get-CimInstance Win32_Process -Filter "Name='Runner.Worker.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($WindowsRunner, [StringComparison]::OrdinalIgnoreCase) })
}

# True while the Linux container is executing a job.
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
