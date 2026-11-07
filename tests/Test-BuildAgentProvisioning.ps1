#Requires -Version 7.2
# Provisioning decisions and resumable setup state, with every external operation (winget, docker, dotnet, registry) mocked.
# Nothing is installed and no daemon is contacted; this does not replace a run on a fresh Windows host with Docker Desktop.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

. (Join-Path $repo 'scripts\Install-BuildAgent.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ("ba-provision-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $desktopDir = Join-Path $temp 'Docker'
    New-Item -ItemType Directory -Path $desktopDir | Out-Null
    $desktop = Join-Path $desktopDir 'Docker Desktop.exe'
    Set-Content -LiteralPath $desktop -Value ''
    Set-Content -LiteralPath (Join-Path $desktopDir 'DockerCli.exe') -Value ''
    $sdk = Join-Path $temp 'dotnet.exe'
    Set-Content -LiteralPath $sdk -Value ''

    $mock = $null
    function Reset-Mock {
        $script:mock = @{
            Docker = 'C:\docker\docker.exe'; Desktop = $desktop; Started = @(); Switched = 0
            Daemon = [pscustomobject]@{ CliFound = $true; Reachable = $true; OSType = 'linux'; ServerVersion = '27.0'; Detail = 'Linux-container daemon 27.0 is ready.' }
            Waited = [pscustomobject]@{ CliFound = $true; Reachable = $true; OSType = 'linux'; ServerVersion = '27.0'; Detail = 'Linux-container daemon 27.0 is ready.' }
            Runtime = 'present'; RuntimeFails = $false; ToolInstalled = $null; ToolCalls = @(); ToolFails = $false
            ImageCalls = 0; ImageFails = $false; Reboot = $false; Group = $null; AfterSwitch = $null
        }
    }
    function Find-DockerExe { $mock.Docker }
    function Find-DockerDesktopExe { $mock.Desktop }
    function Get-DockerDaemonState { param($DockerExe, $DockerHost, $TimeoutSeconds) $mock.Daemon }
    function Wait-DockerReady { param($DockerExe, $DockerHost, $TimeoutSeconds, $OnWait) if ($mock.Switched -and $mock.AfterSwitch) { $mock.AfterSwitch } else { $mock.Waited } }
    function Start-Process { param($FilePath) $mock.Started += $FilePath }
    function Invoke-BoundedNative { param($FilePath, $Arguments, $TimeoutSeconds, $Environment) if ($Arguments -contains '-SwitchLinuxEngine') { $mock.Switched++ }; [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false; Started = $true } }
    function Install-BuildAgentRuntime { param($Settings, $InstallScript) if ($mock.RuntimeFails) { throw 'runtime download failed' }; $mock.Runtime }
    function Get-BuildAgentInstalledVersion { param($Settings) $mock.ToolInstalled }
    function Install-BuildAgentTool { param($Settings, $DotnetExe) $mock.ToolCalls += $DotnetExe; if ($mock.ToolFails) { throw 'dotnet tool install failed' }; 'installed' }
    function Install-BuildAgentImage { param($Settings, $DockerExe) $mock.ImageCalls++; if ($mock.ImageFails) { throw 'pull failed' }; [pscustomobject]@{ Result = 'pulled'; Id = 'sha256:abc' } }
    function Test-SetupRebootPending { $mock.Reboot }
    function Get-DockerUsersAction { $mock.Group }
    function Get-SetupBootTime { $mock.Boot }

    function Invoke-Host([switch] $SkipImage, [string] $Sdk = $sdk) {
        Install-BuildAgentHost -Config $Config -DotnetExe $Sdk -SkipImage:$SkipImage -OnProgress { param($m) }
    }
    function Row($Result, [string] $Item) { $Result.Rows | Where-Object Item -eq $Item | Select-Object -First 1 }

    # Everything ready: runtime, tool from the given SDK, a Linux daemon and the pinned image.
    Reset-Mock
    $result = Invoke-Host
    Assert (-not $result.Failed -and $result.Actions.Count -eq 0) 'A ready host reported a failure or an action.'
    Assert ((Row $result 'docker').State -eq 'ok' -and (Row $result 'image').State -eq 'pulled' -and $mock.ImageCalls -eq 1) 'Ready host did not verify Docker and pull the image.'
    Assert ($mock.ToolCalls.Count -eq 1 -and $mock.ToolCalls[0] -eq $sdk) 'The tool was not installed with the supplied SDK.'
    Assert ($mock.Started.Count -eq 0) 'Docker Desktop was started although the daemon was already reachable.'

    # An installed tool of the pinned version is accepted without any SDK and is not reinstalled.
    Reset-Mock
    $settings = Get-BuildAgentSettings $Config
    $mock.ToolInstalled = $settings.Version
    $result = Invoke-Host -Sdk ''
    Assert (-not $result.Failed -and $mock.ToolCalls.Count -eq 0 -and (Row $result 'tool').State -eq 'present') 'A pinned tool already installed was reinstalled or rejected.'

    # Tool missing and no SDK: a clear failure, and the other steps still run.
    Reset-Mock
    $result = Invoke-Host -Sdk ''
    Assert ($result.Failed -and (Row $result 'tool').State -eq 'failed' -and (Row $result 'docker').State -eq 'ok') 'A missing SDK stopped the other provisioning steps or went unreported.'

    # Docker Desktop not installed: an install action, the runtime and tool are still provisioned, the image waits.
    Reset-Mock
    $mock.Docker = $null
    $result = Invoke-Host
    Assert ($result.Actions.Count -eq 1 -and $result.Actions[0].Kind -eq 'install' -and $result.Actions[0].Id -eq 'docker-install') 'Missing Docker did not produce the install action.'
    Assert ((Row $result 'image').State -eq 'waiting' -and $mock.ImageCalls -eq 0 -and $mock.ToolCalls.Count -eq 1) 'Missing Docker blocked the runtime/tool or tried to pull.'

    # Daemon down: Docker Desktop is started (unelevated) and waited for.
    Reset-Mock
    $mock.Daemon = [pscustomobject]@{ CliFound = $true; Reachable = $false; OSType = $null; ServerVersion = $null; Detail = 'down' }
    $result = Invoke-Host
    Assert ($mock.Started.Count -eq 1 -and $mock.Started[0] -eq $desktop -and (Row $result 'docker').State -eq 'ok' -and $result.Actions.Count -eq 0) 'A stopped daemon was not started and waited for.'

    # A configured remote DOCKER_HOST is never "fixed" by launching Docker Desktop.
    Reset-Mock
    $mock.Daemon = [pscustomobject]@{ CliFound = $true; Reachable = $false; OSType = $null; ServerVersion = $null; Detail = 'down' }
    $savedHost = $Config.buildAgent.docker.host
    $Config.buildAgent.docker | Add-Member -Force -NotePropertyName host -NotePropertyValue 'tcp://example.invalid:2375'
    $result = Invoke-Host
    $Config.buildAgent.docker | Add-Member -Force -NotePropertyName host -NotePropertyValue $savedHost
    Assert ($mock.Started.Count -eq 0) 'Docker Desktop was launched although a remote DOCKER_HOST is configured.'

    # Daemon never ready after a Windows restart is pending: a reboot action, never a silent restart.
    Reset-Mock
    $unreachable = [pscustomobject]@{ CliFound = $true; Reachable = $false; OSType = $null; ServerVersion = $null; Detail = 'pipe not found' }
    $mock.Daemon = $unreachable; $mock.Waited = $unreachable; $mock.Reboot = $true
    $result = Invoke-Host
    Assert ($result.Actions.Count -eq 1 -and $result.Actions[0].Kind -eq 'reboot') 'A pending restart was not reported as a reboot action.'
    Assert ((Row $result 'docker').State -eq 'action-required' -and (Row $result 'image').State -eq 'waiting' -and $mock.ImageCalls -eq 0) 'An unready daemon still pulled the image.'

    # Not in docker-users: the group action wins over the generic one.
    Reset-Mock
    $mock.Daemon = $unreachable; $mock.Waited = $unreachable
    $mock.Group = [pscustomobject]@{ Id = 'docker-users-signin'; Kind = 'sign-out'; Message = 'sign out and in' }
    $result = Invoke-Host
    Assert ($result.Actions.Count -eq 1 -and $result.Actions[0].Kind -eq 'sign-out') 'A docker-users sign-out was not reported.'

    # Daemon never ready, nothing specific found: the generic person-action carries the reason.
    Reset-Mock
    $mock.Daemon = $unreachable; $mock.Waited = $unreachable
    $result = Invoke-Host
    Assert ($result.Actions.Count -eq 1 -and $result.Actions[0].Kind -eq 'user' -and $result.Actions[0].Message -match 'pipe not found') 'An unready daemon did not carry its diagnostic into the action.'

    # Windows-container daemon: switched to Linux containers through DockerCli, then verified.
    Reset-Mock
    $mock.Daemon = [pscustomobject]@{ CliFound = $true; Reachable = $true; OSType = 'windows'; ServerVersion = '27.0'; Detail = 'runs windows containers' }
    $mock.Waited = $mock.Daemon
    # The wait after the switch reports Linux.
    $mock.AfterSwitch = [pscustomobject]@{ CliFound = $true; Reachable = $true; OSType = 'linux'; ServerVersion = '27.0'; Detail = 'ready' }
    $result = Invoke-Host
    Assert ($mock.Switched -eq 1 -and (Row $result 'docker').State -eq 'ok' -and $result.Actions.Count -eq 0) 'A Windows-container daemon was not switched to Linux containers.'

    # Windows-container daemon that cannot be switched stays an action, and no image is pulled into it.
    Reset-Mock
    $mock.Desktop = $null
    $windows = [pscustomobject]@{ CliFound = $true; Reachable = $true; OSType = 'windows'; ServerVersion = '27.0'; Detail = 'runs windows containers' }
    $mock.Daemon = $windows; $mock.Waited = $windows
    $result = Invoke-Host
    Assert ($result.Actions.Count -eq 1 -and $mock.ImageCalls -eq 0 -and $mock.Switched -eq 0) 'A Windows-container daemon was accepted or pulled into.'

    # A failing step is a failure, not an exception, and later steps still run.
    Reset-Mock
    $mock.RuntimeFails = $true; $mock.ToolFails = $true
    $result = Invoke-Host
    Assert ($result.Failed -and (Row $result 'runtime').State -eq 'failed' -and (Row $result 'tool').State -eq 'failed' -and (Row $result 'image').State -eq 'pulled') 'A failing runtime/tool blocked Docker and the image or was hidden.'
    Reset-Mock
    $mock.ImageFails = $true
    $result = Invoke-Host
    Assert ($result.Failed -and (Row $result 'image').State -eq 'failed') 'A failed image pull was not reported as a failure.'

    # -SkipImage and a disabled integration.
    Reset-Mock
    $result = Invoke-Host -SkipImage
    Assert ($mock.ImageCalls -eq 0 -and (Row $result 'image').State -eq 'skipped') '-SkipImage still pulled.'
    Reset-Mock
    $Config.buildAgent.enabled = $false
    $result = Invoke-Host
    $Config.buildAgent.enabled = $true
    Assert ($result.Rows.Count -eq 1 -and $result.Rows[0].State -eq 'disabled' -and $mock.ToolCalls.Count -eq 0 -and $mock.ImageCalls -eq 0) 'A disabled integration was provisioned.'

    # Resumable state.
    $root = Join-Path $temp 'install-root'
    New-Item -ItemType Directory -Path $root | Out-Null
    Assert (-not (Read-SetupState $root).actions.Count) 'Fresh state was not empty.'
    Set-SetupStep $root 'runners'
    Assert ([bool](Read-SetupState $root).completed.runners) 'A finished step was not persisted.'
    Set-SetupAction $root @([pscustomobject]@{ Id = 'reboot'; Kind = 'reboot'; Message = 'restart' }, [pscustomobject]@{ Id = 'docker-users-signin'; Kind = 'sign-out'; Message = 'sign out' })
    Assert ((Read-SetupState $root).actions.Count -eq 2 -and [bool](Read-SetupState $root).completed.runners) 'Recording actions lost the finished steps.'
    $mock.Boot = [DateTime]::UtcNow.AddMinutes(-5)
    Assert ((Get-SetupPendingAction $root).Count -eq 2) 'A restart that has not happened yet was dropped.'
    $mock.Boot = [DateTime]::UtcNow.AddMinutes(5)
    $pending = @(Get-SetupPendingAction $root)
    Assert ($pending.Count -eq 1 -and $pending[0].kind -eq 'sign-out') 'A restart that already happened was not dropped, or the sign-out action was.'
    Set-SetupAction $root @()
    Assert ((Read-SetupState $root).actions.Count -eq 0 -and [bool](Read-SetupState $root).completed.runners) 'Clearing actions lost the finished steps.'
    Set-Content -LiteralPath (Get-SetupStatePath $root) -Value '{ not json'
    Assert ((Read-SetupState $root).actions.Count -eq 0) 'A corrupt state file threw or was trusted.'
    Save-SetupState (Join-Path $temp 'missing-root') (Read-SetupState $root)
    Assert (-not (Test-Path (Join-Path $temp 'missing-root'))) 'State was written into a directory that does not exist.'
    Assert (-not (Get-ChildItem $root -Filter '*.tmp')) 'A temporary state file was left behind.'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS: BuildAgent provisioning (runtime, tool, Docker start/switch/wait, image, reboot/sign-out/install actions, failures that do not block other steps) and resumable setup state (all external operations mocked).'
