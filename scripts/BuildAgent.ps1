# BuildAgent integration: the one place that knows where the tool, the net8.0 runtime and the image live, how a build
# is invoked, and whether the Docker daemon can run it. Setup, the workflow-facing Invoke-BuildAgent.ps1 and the
# diagnostics all go through these functions. Dot-source RunnerConfig.ps1 first.
#
# What `build-agent build <type>` does (Docker-BuildAgent docs, Global Tool > Running a build): it runs the image of its
# own version (or $env:BUILD_AGENT_IMAGE) with the current directory mounted at /workspace and the host's Docker daemon
# reachable. It mounts nothing else. This library therefore maps workspace, output and cache as directories inside one
# per-instance workspace, and refuses a configuration that asks for anything the command cannot do.

$BuildAgentTypes = @('docker', 'node', 'node-in-docker', 'node-template', 'forge')

# Everything a caller needs, resolved: absolute paths, the per-instance workspace, the digest-pinned image.
function Get-BuildAgentSettings([Parameter(Mandatory)] $Config) {
    $agent = $Config.buildAgent
    if (-not $agent) { throw 'No buildAgent section in runners.json.' }
    $instance = if ($Config.windows.instanceId) { $Config.windows.instanceId } else { 'default' }
    $toolDirectory = Get-CanonicalPath $agent.tool.directory
    $workspaceRoot = Get-CanonicalPath $agent.paths.workspaceRoot
    $workspace = Join-Path $workspaceRoot $instance
    [pscustomobject]@{
        Enabled          = [bool]$agent.enabled
        Instance         = $instance
        Package          = $agent.tool.package
        Version          = $agent.tool.version
        ToolDirectory    = $toolDirectory
        ToolExe          = Join-Path $toolDirectory 'build-agent.exe'
        ToolStore        = Join-Path $toolDirectory ".store\$($agent.tool.package.ToLowerInvariant())\$($agent.tool.version)"
        RuntimeChannel   = $agent.dotnetRuntime.channel
        RuntimeDirectory = Get-CanonicalPath $agent.dotnetRuntime.directory
        Image            = $agent.image
        ImageDigest      = ($agent.image -replace '^.*@', '')
        DockerHost       = $agent.docker.host
        ReadyTimeout     = [int]$agent.docker.readyTimeoutSeconds
        WorkspaceRoot    = $workspaceRoot
        Workspace        = $workspace
        OutputDirectory  = Join-Path $workspace $agent.paths.outputDirectory
        CacheDirectory   = Join-Path $workspace $agent.paths.cacheDirectory
        CacheRetentionDays = [int]$agent.cache.retentionDays
        CacheMaxGB       = [int]$agent.cache.maxGB
        UpdaterVersion   = $agent.updater.version
    }
}

# Throws when a mapping would give the build something it cannot use or must not see. $RunnerRoot is the clone that
# holds runner registrations and credentials; the workspace may not contain or sit inside it.
function Assert-BuildAgentMapping([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $RunnerRoot) {
    $problems = [Collections.Generic.List[string]]::new()
    $workspace = $Settings.Workspace
    if ($workspace -match '^\\\\') { $problems.Add("The workspace $workspace is a network path; Docker Desktop cannot mount it.") }
    if ($workspace -notmatch '^[A-Za-z]:\\') { $problems.Add("The workspace $workspace is not on a local drive letter.") }
    if ($workspace -match '[,"]') { $problems.Add("The workspace $workspace contains a comma or quote, which a Docker mount specification cannot carry.") }
    if ($workspace -match '(?i)\\Dropbox(\\|$)') { $problems.Add("The workspace $workspace is inside Dropbox; builds would sync their output.") }
    if ((Test-PathUnder $RunnerRoot $workspace) -or (Test-PathUnder $workspace $RunnerRoot)) {
        $problems.Add("The workspace $workspace overlaps the runner clone $RunnerRoot, which holds registrations and credentials; the build container must not see them.")
    }
    foreach ($pair in @(@('output', $Settings.OutputDirectory), @('cache', $Settings.CacheDirectory))) {
        if (-not (Test-PathUnder $pair[1] $workspace) -or (Get-CanonicalPath $pair[1]) -eq (Get-CanonicalPath $workspace)) {
            $problems.Add("The $($pair[0]) directory $($pair[1]) is not inside the workspace, so the build container could not reach it.")
        }
    }
    if ((Get-CanonicalPath $Settings.OutputDirectory) -eq (Get-CanonicalPath $Settings.CacheDirectory)) { $problems.Add('The output and cache directories are the same.') }
    if ($problems.Count) { throw "Invalid BuildAgent mapping:`n - $($problems -join "`n - ")" }
}

# The build, as data: what to run, with which arguments, from which directory and with which environment. Both
# Invoke-BuildAgent and the setup self-check use it, so nothing builds a command line of its own.
function Get-BuildAgentInvocation {
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string] $Type,
        [string[]] $Arguments = @()
    )
    if ($Type -notin $BuildAgentTypes) {
        throw "'$Type' is not a build-agent build type. The types are: $($BuildAgentTypes -join ', '). A build-agent command that runs an arbitrary program does not exist, and a Windows executable cannot run in the Linux container."
    }
    # The arguments after the type belong to build-agent and reach it unchanged: its own syntax decides what is valid
    # (--option value, and single-dash options such as node-template's -AppDir), and values such as paths or file names
    # (build.ps1, tool.exe) are data to it, not programs this script would run.
    $environment = [ordered]@{
        BUILD_AGENT_IMAGE = $Settings.Image
        DOTNET_ROOT       = $Settings.RuntimeDirectory
        DOTNET_ROOT_X64   = $Settings.RuntimeDirectory
        DOTNET_MULTILEVEL_LOOKUP = '0'
        DOTNET_NOLOGO     = '1'
        DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    }
    if ($Settings.DockerHost) { $environment.DOCKER_HOST = $Settings.DockerHost }
    [pscustomobject]@{
        FilePath         = $Settings.ToolExe
        Arguments        = @('build', $Type) + $Arguments
        WorkingDirectory = $Settings.Workspace
        Environment      = $environment
    }
}

# What build-agent's own exit statuses mean before the build starts (Docker-BuildAgent docs, Exit Codes).
function Get-BuildAgentExitMeaning([int] $ExitCode) {
    switch ($ExitCode) {
        0 { 'The build succeeded.' }
        1 { 'build-agent rejected the build type or arguments, or the build step failed.' }
        2 { 'The project configuration file is invalid.' }
        3 { 'The workspace directory does not exist.' }
        5 { 'Docker is unavailable or the image could not be pulled. Run scripts\Get-BuildAgentStatus.ps1.' }
        6 { 'A registry operation failed.' }
        125 { 'Docker never started the container: the workspace or Docker socket mount was most likely refused. On Docker Desktop, check file sharing for the workspace drive.' }
        255 { 'A build target failed; read the summary table above.' }
        default { "The build returned $ExitCode." }
    }
}

# Runs the invocation in its own scope: the environment is set for the child and restored afterwards. Returns the
# tool's exit status unchanged.
function Invoke-BuildAgentInvocation([Parameter(Mandatory)] $Invocation) {
    New-Item -ItemType Directory -Force $Invocation.WorkingDirectory | Out-Null
    $saved = @{}
    foreach ($name in $Invocation.Environment.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $Invocation.Environment[$name], 'Process')
    }
    try {
        # Started as a process with an argument list, so every argument reaches the tool as one argument, exactly as given
        # (spaces, quotes, empty values, a leading dash), whatever PowerShell's native-argument mode is. The tool shares this
        # process's console and output streams; the only value returned is its exit status.
        $info = [Diagnostics.ProcessStartInfo]::new($Invocation.FilePath)
        $info.WorkingDirectory = $Invocation.WorkingDirectory
        $info.UseShellExecute = $false
        foreach ($argument in @($Invocation.Arguments)) { $info.ArgumentList.Add([string]$argument) }
        $process = [Diagnostics.Process]::Start($info)
        try { $process.WaitForExit(); $process.ExitCode } finally { $process.Dispose() }
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

# A bounded native call: output and exit code, or TimedOut when it did not finish. Docker Desktop's CLI can hang while
# the engine starts, and a status command must not.
function Invoke-BoundedNative([string] $FilePath, [string[]] $Arguments, [int] $TimeoutSeconds = 30, [hashtable] $Environment = @{}) {
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($name in $Environment.Keys) { $info.Environment[$name] = $Environment[$name] }
    try { $process = [Diagnostics.Process]::Start($info) }
    catch { return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message; TimedOut = $false; Started = $false } }
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        return [pscustomobject]@{ ExitCode = -1; Output = "Timed out after $TimeoutSeconds seconds."; TimedOut = $true; Started = $true }
    }
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = (($out.Result + $err.Result).Trim()); TimedOut = $false; Started = $true }
}

# The daemon the builds will use: reachable, and a Linux-container engine. Never throws.
function Get-DockerDaemonState([string] $DockerExe, [string] $DockerHost, [int] $TimeoutSeconds = 30) {
    $state = [ordered]@{ CliFound = $false; Reachable = $false; OSType = $null; ServerVersion = $null; Detail = $null }
    if (-not $DockerExe -or -not (Get-Command $DockerExe -ErrorAction SilentlyContinue)) {
        $state.Detail = 'docker.exe was not found. Install Docker Desktop, or put docker.exe on PATH.'
        return [pscustomobject]$state
    }
    $state.CliFound = $true
    $environment = @{}
    if ($DockerHost) { $environment.DOCKER_HOST = $DockerHost }
    $result = Invoke-BoundedNative $DockerExe @('info', '--format', '{{.OSType}}|{{.ServerVersion}}') $TimeoutSeconds $environment
    if ($result.ExitCode -ne 0) {
        $state.Detail = if ($result.TimedOut) { $result.Output } else { "docker info failed (exit $($result.ExitCode)): $(($result.Output -split "`n" | Select-Object -First 3) -join ' ')" }
        return [pscustomobject]$state
    }
    $fields = $result.Output.Split('|')
    $state.Reachable = $true
    $state.OSType = $fields[0].Trim()
    $state.ServerVersion = if ($fields.Count -gt 1) { $fields[1].Trim() }
    $state.Detail = if ($state.OSType -eq 'linux') { "Linux-container daemon $($state.ServerVersion) is ready." }
                    else { "The daemon runs $($state.OSType) containers. Switch Docker Desktop to Linux containers (tray menu, or DockerCli.exe -SwitchLinuxEngine)." }
    [pscustomobject]$state
}

# Polls until the daemon is a ready Linux-container engine or the deadline passes. Returns the last state.
function Wait-DockerReady([string] $DockerExe, [string] $DockerHost, [int] $TimeoutSeconds, [scriptblock] $OnWait) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $state = Get-DockerDaemonState $DockerExe $DockerHost 20
        if ($state.Reachable -and $state.OSType -eq 'linux') { return $state }
        # A Windows-container daemon will not turn into a Linux one by waiting; report it now.
        if ($state.Reachable) { return $state }
        if ($OnWait) { & $OnWait $state }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $deadline)
    $state
}

# The installed tool's version from its package store, without running it. $null when not installed.
function Get-BuildAgentInstalledVersion($Settings) {
    if (-not (Test-Path -LiteralPath $Settings.ToolExe)) { return }
    $store = Join-Path $Settings.ToolDirectory ".store\$($Settings.Package.ToLowerInvariant())"
    if (Test-Path -LiteralPath $store) { (Get-ChildItem -LiteralPath $store -Directory | Sort-Object Name | Select-Object -Last 1).Name }
}

# The v2.2.0 release contains Docker-BuildAgent #136's runner settings support. Both configuration pins and
# the installed tool must agree. A null updater pin deliberately disables integration; never infer it from the image.
function Test-BuildAgentUpdater($Settings) {
    if (-not $Settings.UpdaterVersion) {
        return [pscustomobject]@{ Available = $false; Reason = 'Updater integration is disabled: buildAgent.updater.version is null. BuildAgent.Tool 2.2.0 contains Docker-BuildAgent #136; configure coordinated tool and updater pins only after reviewing that contract.' }
    }
    if ($Settings.Version -ne $Settings.UpdaterVersion) {
        return [pscustomobject]@{ Available = $false; Reason = "Configured tool $($Settings.Version) and updater $($Settings.UpdaterVersion) differ; coordinate buildAgent.tool.version and buildAgent.updater.version." }
    }
    $releaseVersion = $null
    if (-not [version]::TryParse($Settings.UpdaterVersion, [ref]$releaseVersion) -or $releaseVersion -lt [version]'2.2.0') {
        return [pscustomobject]@{ Available = $false; Reason = 'Runner settings require a stable BuildAgent.Tool release from 2.2.0 (Docker-BuildAgent #136); the configured updater predates it or is not a stable release.' }
    }
    $installed = Get-BuildAgentInstalledVersion $Settings
    if ($installed -ne $Settings.UpdaterVersion) {
        $have = if ($installed) { $installed } else { 'none' }
        return [pscustomobject]@{ Available = $false; Reason = "The updater is configured from BuildAgent.Tool $($Settings.UpdaterVersion) but the installed tool is $have. Install exactly that version (buildAgent.tool.version) first." }
    }
    [pscustomobject]@{ Available = $true; Reason = $null }
}

# Seconds, s, m and h match v2.2.0's duration contract. Validate before drain; never strip a unit and shorten the wait.
function Get-BuildAgentUpdateTimeoutSeconds([string] $HealthTimeout) {
    if ($HealthTimeout -cnotmatch '^([1-9][0-9]*)(s|m|h)?$') { throw 'Updater healthTimeout must be positive seconds, or a duration such as 120s, 2m or 1h.' }
    $scale = switch ($Matches[2]) { 'm' { 60 }; 'h' { 3600 }; default { 1 } }
    $seconds = [double]$Matches[1] * $scale + 600
    if ($seconds -gt [int]::MaxValue / 1000) { throw 'Updater healthTimeout exceeds the bounded process wait limit.' }
    [int]$seconds
}

# An update preserves existing mounts; it cannot apply PR #17's isolation migration. Inspect only mounts and the
# allowlisted hook marker (never the full environment/registration). Refuse an old or unverifiable sidecar before drain.
# DinD has no separate daemon registration mount to migrate. Do not recreate anything from this preflight.
function Assert-LinuxUpdaterIsolation($Config, [string] $DockerExe) {
    if ($Config.linux.docker.mode -ne 'sidecar') { return }
    $linux = $Config.linux
    $sidecar = $linux.docker
    $runtimeVolume = "$($linux.container)-runtimes"
    if ($runtimeVolume -in @($linux.cacheVolume, $sidecar.dataVolume, $sidecar.certsVolume, $sidecar.workVolume, $sidecar.dindVolume)) {
        throw 'The derived runtime volume must not alias a runner state, cache or workspace volume.'
    }
    $environment = @{}
    if ($Config.buildAgent.docker.host) { $environment.DOCKER_HOST = $Config.buildAgent.docker.host }
    foreach ($name in @($sidecar.container, $linux.container)) {
        $read = Invoke-BoundedNative $DockerExe @('inspect', '--format', '{{json .Mounts}}', $name) 30 $environment
        if ($read.ExitCode -ne 0 -or $read.TimedOut -or -not $read.Started) { throw "Cannot verify runtime isolation for $name; update refused before drain." }
        try { $mounts = @($read.Output | ConvertFrom-Json -ErrorAction Stop) }
        catch { throw "Cannot parse runtime mounts for $name; update refused before drain." }
        if ($name -eq $sidecar.container) {
            foreach ($mount in $mounts) {
                if ($mount.Type -eq 'bind' -or
                    ($mount.Destination -eq '/runner' -or ($mount.Destination -like '/runner/*' -and $mount.Destination -ne '/runner/externals'))) {
                    throw 'The sidecar still exposes the runner installation. Apply PR #17 through an approved recreation before using -Update.'
                }
            }
            $projection = @($mounts | Where-Object { $_.Type -eq 'volume' -and $_.Name -eq $runtimeVolume -and $_.Destination -eq '/runner/externals' -and $_.RW -eq $false })
        }
        else {
            $projection = @($mounts | Where-Object { $_.Type -eq 'volume' -and $_.Name -eq $runtimeVolume -and $_.Destination -eq '/runner-runtime' -and $_.RW -eq $true })
        }
        if ($projection.Count -ne 1) { throw "PR #17 runtime projection is missing or incorrect on $name; an approved recreation is required before -Update." }
    }
    $hookFormat = '{{range .Config.Env}}{{if eq . "ACTIONS_RUNNER_HOOK_JOB_STARTED=/runner-hooks/Sync-LinuxRunnerRuntimes.sh"}}configured{{end}}{{end}}'
    $hook = Invoke-BoundedNative $DockerExe @('inspect', '--format', $hookFormat, $linux.container) 30 $environment
    if ($hook.ExitCode -ne 0 -or $hook.TimedOut -or -not $hook.Started -or $hook.Output.Trim() -cne 'configured') {
        throw 'PR #17 runtime refresh hook is not verified; update refused before drain.'
    }
}

# The documented update command, nothing else: build-agent update <container> --image <ref> --health-timeout <d>.
# The updater owns the replacement, its lock, the update records and restoring the original container.
function Get-BuildAgentUpdateInvocation($Settings, [Parameter(Mandatory)] [string] $Container, [Parameter(Mandatory)] [string] $Image, [Parameter(Mandatory)] [string] $HealthTimeout) {
    $environment = @{ DOTNET_ROOT = $Settings.RuntimeDirectory; DOTNET_ROOT_X64 = $Settings.RuntimeDirectory }
    if ($Settings.DockerHost) { $environment.DOCKER_HOST = $Settings.DockerHost }
    [pscustomobject]@{
        FilePath    = $Settings.ToolExe
        Arguments   = @('update', $Container, '--image', $Image, '--health-timeout', $HealthTimeout)
        Environment = $environment
    }
}

# What the updater's documented exit statuses mean for the person reading the report.
function Get-BuildAgentUpdateExitMeaning([int] $ExitCode) {
    switch ($ExitCode) {
        0 { 'Updated and healthy, or already on the requested image (no replacement or new health check).' }
        10 { 'The replacement failed or the update was interrupted; the original container was restored. Mounted files and volumes were not rolled back.' }
        11 { 'The unverified replacement was left in place (--no-restore). Manual recovery required; keep maintenance.' }
        12 { 'The original container could not be restored. Manual recovery required; keep maintenance.' }
        20 { 'Refused: target missing or unsupported container settings. This invocation left the container untouched.' }
        21 { 'Refused: updater lock held. Verify its owner and recover the interrupted update; keep maintenance.' }
        22 { 'Refused: updater residue or an unreadable update log. Manual recovery required; keep maintenance.' }
        23 { 'Refused: prior image could not be pinned. This invocation left the container untouched.' }
        24 { 'Refused: update log could not be written. This invocation left the container untouched.' }
        30 { 'The image could not be obtained. This invocation left the container untouched.' }
        default { "build-agent update exited $ExitCode; outcome unverified. Keep maintenance and inspect the updater log and container state." }
    }
}

# The net8.0 runtime BuildAgent.Tool runs on, in the host-level directory. A private SDK for another major version
# does not satisfy it, because the tool's apphost resolves DOTNET_ROOT, not the instance's SDK.
function Test-BuildAgentRuntime($Settings) {
    $dotnet = Join-Path $Settings.RuntimeDirectory 'dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet)) { return $false }
    $runtimes = Join-Path $Settings.RuntimeDirectory 'shared\Microsoft.NETCore.App'
    (Test-Path -LiteralPath $runtimes) -and [bool](Get-ChildItem -LiteralPath $runtimes -Directory -Filter "$($Settings.RuntimeChannel).*" -ErrorAction SilentlyContinue)
}

function Install-BuildAgentRuntime($Settings, [string] $InstallScript) {
    if (Test-BuildAgentRuntime $Settings) { return 'present' }
    New-Item -ItemType Directory -Force $Settings.RuntimeDirectory | Out-Null
    & $InstallScript -Runtime dotnet -Channel $Settings.RuntimeChannel -InstallDir $Settings.RuntimeDirectory -NoPath
    if (-not (Test-BuildAgentRuntime $Settings)) { throw "The .NET $($Settings.RuntimeChannel) runtime is still missing from $($Settings.RuntimeDirectory) after installing it." }
    'installed'
}

# Installs the pinned tool to the host-level directory with an SDK's `dotnet tool install --tool-path`. A different
# installed version is replaced, so a bumped pin takes effect. Serialised across instances by a mutex.
function Install-BuildAgentTool($Settings, [Parameter(Mandatory)] [string] $DotnetExe) {
    $mutex = [Threading.Mutex]::new($false, 'Local\SubZeroDev.Runners.BuildAgentTool')
    if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(10))) { throw 'Another setup holds the BuildAgent tool lock.' }
    try {
        $installed = Get-BuildAgentInstalledVersion $Settings
        if ($installed -eq $Settings.Version) { return 'present' }
        New-Item -ItemType Directory -Force $Settings.ToolDirectory | Out-Null
        $verb = if ($installed) { 'update' } else { 'install' }
        Invoke-Native $DotnetExe @('tool', $verb, $Settings.Package, '--tool-path', $Settings.ToolDirectory, '--version', $Settings.Version) "dotnet tool $verb $($Settings.Package) $($Settings.Version)" | Out-Null
        $now = Get-BuildAgentInstalledVersion $Settings
        if ($now -ne $Settings.Version) { throw "$($Settings.Package) $($Settings.Version) was not installed (found '$now')." }
        if ($installed) { 'updated' } else { 'installed' }
    }
    finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}

# The image reference as the daemon has it: pulled when missing, and the digest verified afterwards.
function Install-BuildAgentImage($Settings, [string] $DockerExe) {
    $environment = @{}
    if ($Settings.DockerHost) { $environment.DOCKER_HOST = $Settings.DockerHost }
    $present = Invoke-BoundedNative $DockerExe @('image', 'inspect', '--format', '{{.Id}}', $Settings.Image) 30 $environment
    if ($present.ExitCode -eq 0) { return [pscustomobject]@{ Result = 'present'; Id = $present.Output } }
    $pull = Invoke-BoundedNative $DockerExe @('pull', $Settings.Image) 1800 $environment
    if ($pull.ExitCode -ne 0) { throw "docker pull $($Settings.Image) failed (exit $($pull.ExitCode)): $($pull.Output)" }
    $verify = Invoke-BoundedNative $DockerExe @('image', 'inspect', '--format', '{{.Id}}', $Settings.Image) 30 $environment
    if ($verify.ExitCode -ne 0) { throw "$($Settings.Image) is not present after pulling it." }
    [pscustomobject]@{ Result = 'pulled'; Id = $verify.Output }
}

# One status row per thing the integration needs. State: ok, missing, action-required, failed. No side effects.
function Get-BuildAgentStatus([Parameter(Mandatory)] $Config, [string] $RunnerRoot, [string] $DockerExe) {
    $settings = Get-BuildAgentSettings $Config
    $rows = [Collections.Generic.List[object]]::new()
    function Add-Row([string] $Item, [string] $State, [string] $Detail) { $rows.Add([pscustomobject]@{ Item = $Item; State = $State; Detail = $Detail }) }
    $version = Get-BuildAgentInstalledVersion $settings
    if (-not $version) { Add-Row 'tool' 'missing' "$($settings.Package) $($settings.Version) is not installed in $($settings.ToolDirectory)." }
    elseif ($version -ne $settings.Version) { Add-Row 'tool' 'failed' "Installed $version, pinned $($settings.Version)." }
    else { Add-Row 'tool' 'ok' "$($settings.Package) $version in $($settings.ToolDirectory)." }
    if (Test-BuildAgentRuntime $settings) { Add-Row 'runtime' 'ok' ".NET $($settings.RuntimeChannel) runtime in $($settings.RuntimeDirectory)." }
    else { Add-Row 'runtime' 'missing' ".NET $($settings.RuntimeChannel) runtime is missing from $($settings.RuntimeDirectory)." }
    try { Assert-BuildAgentMapping $settings $RunnerRoot; Add-Row 'mapping' 'ok' "Workspace $($settings.Workspace)." }
    catch { Add-Row 'mapping' 'failed' $_.Exception.Message }
    $daemon = Get-DockerDaemonState $DockerExe $settings.DockerHost 30
    if ($daemon.Reachable -and $daemon.OSType -eq 'linux') { Add-Row 'docker' 'ok' $daemon.Detail }
    elseif ($daemon.Reachable) { Add-Row 'docker' 'action-required' $daemon.Detail }
    else { Add-Row 'docker' 'missing' $daemon.Detail }
    if ($daemon.Reachable -and $daemon.OSType -eq 'linux') {
        $environment = @{}
        if ($settings.DockerHost) { $environment.DOCKER_HOST = $settings.DockerHost }
        $image = Invoke-BoundedNative $DockerExe @('image', 'inspect', '--format', '{{.Id}}', $settings.Image) 30 $environment
        if ($image.ExitCode -eq 0) { Add-Row 'image' 'ok' "$($settings.ImageDigest) ($($image.Output))." } else { Add-Row 'image' 'missing' "$($settings.Image) is not pulled." }
    }
    else { Add-Row 'image' 'missing' 'Cannot check the image until the daemon is ready.' }
    $updater = Test-BuildAgentUpdater $settings
    if ($updater.Available) { Add-Row 'updater' 'ok' "BuildAgent.Tool $($settings.UpdaterVersion) version gate passed; runtime isolation is checked separately before -Update (host acceptance still required)." }
    else { Add-Row 'updater' 'missing' $updater.Reason }
    $rows
}
