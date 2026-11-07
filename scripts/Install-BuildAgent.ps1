#Requires -Version 7.2
# Provisions or verifies the host-level BuildAgent integration, once per host (every instance shares it):
#   1. the net8.0 runtime BuildAgent.Tool runs on, in buildAgent.dotnetRuntime.directory (the instances' private SDK 10 is not enough);
#   2. the pinned BuildAgent.Tool, in buildAgent.tool.directory, installed with an SDK's `dotnet tool install --tool-path`;
#   3. a ready Linux-container Docker daemon: starts Docker Desktop (unelevated), switches to Linux containers, waits;
#   4. the pinned image, pulled by digest.
# Nothing here elevates, restarts Windows, signs the user out or enables automatic sign-in. When a step needs the person (Docker
# Desktop is not installed, a restart or sign-out is pending, the user is not in docker-users, first-run terms are open) the
# step is reported as an action and the script exits 2; rerun it afterwards and finished steps are skipped.
#
# Exit codes: 0 everything ready, 1 a step failed, 2 the person has to act first.
param(
    # A dotnet.exe that has an SDK (an instance's private one). Only needed to install or update the tool.
    [string] $DotnetExe,
    [string] $InstallRoot,
    [switch] $SkipImage,
    [switch] $Json
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\BuildAgent.ps1"
. "$PSScriptRoot\SetupState.ps1"
# Default SDK for installing the tool: this clone's private one (installed by Install-WindowsRunner.ps1).
if (-not $DotnetExe) { $DotnetExe = Join-Path $WindowsRunner '_tool\dotnet\dotnet.exe' }

function New-ProvisionAction([string] $Id, [string] $Kind, [string] $Message) { [pscustomobject]@{ Id = $Id; Kind = $Kind; Message = $Message } }

# Whether this sign-in is in docker-users (Docker Desktop's named pipe needs it), and if not, what to do about it.
# $null when the group does not exist (a per-user Docker install) or cannot be read.
function Get-DockerUsersAction {
    try {
        $group = Get-LocalGroup -Name 'docker-users' -ErrorAction Stop
        $current = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($current.Groups.Value -contains $group.SID.Value) { return }
        $member = Get-LocalGroupMember -Group 'docker-users' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $current.Name }
        if ($member) { New-ProvisionAction 'docker-users-signin' 'sign-out' "$($current.Name) was added to docker-users; sign out of Windows and in again so it takes effect, then rerun setup." }
        else { New-ProvisionAction 'docker-users' 'admin' "Add $($current.Name) to docker-users from an administrator prompt: net localgroup docker-users `"$($current.Name)`" /add. Then sign out of Windows and in again and rerun setup." }
    }
    catch { }
}

# Provisions the integration. Returns { Rows, Actions, Failed, Image } and never throws for an expected condition.
function Install-BuildAgentHost {
    param(
        [Parameter(Mandatory)] $Config,
        [string] $DotnetExe,
        [switch] $SkipImage,
        [scriptblock] $OnProgress = { param($Message) Write-Host $Message }
    )
    $settings = Get-BuildAgentSettings $Config
    $rows = [Collections.Generic.List[object]]::new()
    $actions = [Collections.Generic.List[object]]::new()
    $failed = $false
    $image = $null
    function Add-Row([string] $Item, [string] $State, [string] $Detail) { $rows.Add([pscustomobject]@{ Item = $Item; State = $State; Detail = $Detail }); & $OnProgress "  $Item`: $State - $Detail" }

    if (-not $settings.Enabled) {
        Add-Row 'buildagent' 'disabled' 'buildAgent.enabled is false; nothing to provision.'
        return [pscustomobject]@{ Rows = $rows; Actions = @(); Failed = $false; Image = $null }
    }

    # 1. Runtime (needs no daemon, so it goes first and a missing Docker does not hide it).
    try { Add-Row 'runtime' (Install-BuildAgentRuntime $settings (Join-Path $PSScriptRoot 'dotnet-install.ps1')) ".NET $($settings.RuntimeChannel) runtime in $($settings.RuntimeDirectory)." }
    catch { $failed = $true; Add-Row 'runtime' 'failed' $_.Exception.Message }

    # 2. Tool. The SDK is the caller's; without one an installed tool of the pinned version is still accepted.
    try {
        $installedVersion = Get-BuildAgentInstalledVersion $settings
        if ($installedVersion -eq $settings.Version) { Add-Row 'tool' 'present' "$($settings.Package) $installedVersion in $($settings.ToolDirectory)." }
        elseif (-not $DotnetExe -or -not (Test-Path -LiteralPath $DotnetExe)) {
            $failed = $true
            Add-Row 'tool' 'failed' "$($settings.Package) $($settings.Version) is not installed and no .NET SDK was given to install it with (-DotnetExe)."
        }
        else { Add-Row 'tool' (Install-BuildAgentTool $settings $DotnetExe) "$($settings.Package) $($settings.Version) in $($settings.ToolDirectory)." }
    }
    catch { $failed = $true; Add-Row 'tool' 'failed' $_.Exception.Message }

    # 3. Docker. Find it, start it, make it a Linux-container engine, wait for it.
    $docker = Find-DockerExe
    if (-not $docker) {
        $actions.Add((New-ProvisionAction 'docker-install' 'install' 'Docker Desktop is not installed. Install it (winget install -e --id Docker.DockerDesktop, or the installer from docker.com; both ask for administrator approval), restart Windows if it asks, start Docker Desktop once and accept its terms, then rerun setup.'))
        Add-Row 'docker' 'action-required' $actions[-1].Message
    }
    else {
        $state = Get-DockerDaemonState $docker $settings.DockerHost 20
        if (-not $state.Reachable) {
            $desktop = Find-DockerDesktopExe
            if ($desktop -and -not $settings.DockerHost) {
                & $OnProgress "  docker: starting Docker Desktop ($desktop)"
                Start-Process -FilePath $desktop | Out-Null
            }
            $state = Wait-DockerReady $docker $settings.DockerHost $settings.ReadyTimeout { param($s) & $OnProgress "  docker: waiting for the daemon - $($s.Detail)" }
        }
        if ($state.Reachable -and $state.OSType -ne 'linux') {
            $desktop = Find-DockerDesktopExe
            $cli = if ($desktop) { Join-Path (Split-Path $desktop) 'DockerCli.exe' }
            if ($cli -and (Test-Path -LiteralPath $cli)) {
                & $OnProgress '  docker: switching Docker Desktop to Linux containers'
                $null = Invoke-BoundedNative $cli @('-SwitchLinuxEngine') 120
                $state = Wait-DockerReady $docker $settings.DockerHost 120 $null
            }
        }
        if ($state.Reachable -and $state.OSType -eq 'linux') { Add-Row 'docker' 'ok' $state.Detail }
        else {
            $reason = if ($state.Reachable) { $state.Detail } else { "The Docker daemon did not become ready within $($settings.ReadyTimeout) seconds. $($state.Detail)" }
            $pending = [Collections.Generic.List[object]]::new()
            if (Test-SetupRebootPending) { $pending.Add((New-ProvisionAction 'reboot' 'reboot' 'Windows has a restart pending (Docker Desktop and its WSL 2 prerequisites need it). Restart Windows yourself, start Docker Desktop, then rerun setup.')) }
            $groupAction = Get-DockerUsersAction
            if ($groupAction) { $pending.Add($groupAction) }
            if (-not $pending.Count) { $pending.Add((New-ProvisionAction 'docker-ready' 'user' "$reason Open Docker Desktop, finish its first-run steps (terms, WSL 2), make sure it is set to Linux containers, then rerun setup.")) }
            foreach ($item in $pending) { $actions.Add($item) }
            Add-Row 'docker' 'action-required' $reason
        }
    }

    # 4. Image, only against a ready Linux daemon.
    if ($SkipImage) { Add-Row 'image' 'skipped' '-SkipImage was given.' }
    elseif ($rows | Where-Object { $_.Item -eq 'docker' -and $_.State -eq 'ok' }) {
        try {
            $image = Install-BuildAgentImage $settings $docker
            Add-Row 'image' $image.Result "$($settings.Image) ($($image.Id))."
        }
        catch { $failed = $true; Add-Row 'image' 'failed' $_.Exception.Message }
    }
    else { Add-Row 'image' 'waiting' 'The image is pulled once the Docker daemon is ready.' }

    [pscustomobject]@{ Rows = $rows; Actions = @($actions); Failed = $failed; Image = $image }
}

# Direct run. Dot-sourcing (the setup worker's tests do) defines the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    $result = Install-BuildAgentHost -Config $Config -DotnetExe $DotnetExe -SkipImage:$SkipImage -OnProgress { param($m) if (-not $Json) { Write-Host $m } }
    if ($InstallRoot) {
        if ($result.Actions.Count) { Set-SetupAction $InstallRoot $result.Actions }
        elseif (-not $result.Failed) { Set-SetupAction $InstallRoot @(); Set-SetupStep $InstallRoot 'buildagent' }
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 }
    elseif ($result.Actions.Count) { Write-SetupAction $result.Actions "pwsh -File `"$PSCommandPath`"" }
    exit $(if ($result.Actions.Count) { 2 } elseif ($result.Failed) { 1 } else { 0 })
}
