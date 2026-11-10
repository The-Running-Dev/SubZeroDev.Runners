# The Linux runners as containers: what each one is made of (one spec, used for both `docker run` and the generated compose
# file), the compose file itself, every compose call, and the hash of the image's build context. Dot-source after Common.ps1.
#
#   - Get-LinuxContainerSpecs builds the runner's and the sidecar's settings once. ConvertTo-DockerRunArguments turns them into
#     today's `docker run` lines; ConvertTo-LinuxComposeYaml turns the same specs into compose services. The two cannot drift.
#   - Every compose call goes through Invoke-LinuxCompose: it names its services, passes --no-deps to `up`, and there is no
#     `down`, so a call for one slot cannot touch another slot's containers (a busy runner stays up).
#   - The build context hash covers exactly what `docker build` is sent (see Get-LinuxBuildContextFiles).

$ComposeProject = 'subzerodev-runners'
$ComposeHostLabel = 'dev.subzerodev.runners.host'
$ComposeSlotLabel = 'dev.subzerodev.runners.slot'
$ContextHashLabel = 'dev.subzerodev.runners.context'

function Get-LinuxComposeFilePath([string] $RootDirectory) { Join-Path (Join-Path $RootDirectory 'linux') 'compose.local.yaml' }

# The pre-pool runner as a slot: the names runners.json has always given, on the clone's own directory.
function Get-LegacyLinuxSlot($Config) {
    $docker = $Config.linux.docker
    [pscustomobject]@{
        SlotId = 'linux-01'; Container = $Config.linux.container
        DockerContainer = $(if ($docker -and $docker.mode -eq 'sidecar') { $docker.container })
        Network = $(if ($docker -and $docker.mode -eq 'sidecar') { $docker.network })
        Volumes = [pscustomobject]@{ Cache = $Config.linux.cacheVolume; DockerData = $docker.dataVolume; DockerCerts = $docker.certsVolume; Work = $docker.workVolume; Dind = $docker.dindVolume }
    }
}

function New-Mount([string] $Type, [string] $Source, [string] $Target, [bool] $ReadOnly = $false) {
    [pscustomobject]@{ Type = $Type; Source = $Source; Target = $Target; ReadOnly = $ReadOnly }
}

# The runner container's and the Docker sidecar's settings, as `docker run` has always set them (runner mounts, environment,
# limits, privileged and dind settings). Restart and labels are the caller's: compose says 'always' and labels the container.
# Returns @{ Runner; Sidecar } (Sidecar is $null unless linux.docker.mode is 'sidecar').
function Get-LinuxContainerSpecs($Config, $Slot, [string] $RunnerDirectory, [string] $HooksDirectory, [string] $Restart = 'unless-stopped', $Labels = @{}) {
    $linux = $Config.linux
    $docker = $linux.docker
    $mode = if ($docker) { $docker.mode }
    $volumes = $Slot.Volumes
    $sidecar = $null
    $env = [Collections.Generic.List[string]]::new()
    $env.Add("RUNNER_WORK_FOLDER=$($linux.workFolder)")
    $env.Add('ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/runner-hooks/Clear-LinuxWorkspace.sh')
    $env.Add("RUNNER_CLEANUP_RETRIES=$($Config.housekeeping.retries)")
    $env.Add("RUNNER_CLEANUP_DELAY=$($Config.housekeeping.retryDelaySeconds)")
    $mounts = [Collections.Generic.List[object]]::new()
    $mounts.Add((New-Mount 'bind' $RunnerDirectory '/runner'))
    $mounts.Add((New-Mount 'volume' $volumes.Cache '/cache'))
    $mounts.Add((New-Mount 'bind' $HooksDirectory '/runner-hooks' $true))
    $runner = [ordered]@{
        Name = $Slot.Container; Image = $linux.image; Restart = $Restart; Cpus = $linux.cpus; Memory = $linux.memory
        Privileged = $false; StopTimeout = $null; Network = $null; NetworkAliases = @(); Tmpfs = @(); Labels = $Labels
    }
    if ($mode -eq 'sidecar') {
        # The daemon is privileged; the runner is not. Images and build cache stay in dataVolume across jobs. The work folder is
        # shared at the same path, so bind mounts of a checkout resolve inside the daemon too. Job containers also bind
        # /runner/externals for JavaScript actions: the daemon sees the same runner tree (read-only, only the runner writes it).
        # dind mounts a tmpfs over /tmp unless /tmp is already a mount, which would hide the work folder; this one keeps it visible.
        $sidecar = [ordered]@{
            Name = $Slot.DockerContainer; Image = $docker.image; Restart = $Restart; Cpus = $docker.cpus; Memory = $docker.memory
            Privileged = $true; StopTimeout = $null; Network = $Slot.Network; NetworkAliases = @('docker'); Tmpfs = @('/tmp'); Labels = $Labels
            Env = @('DOCKER_TLS_CERTDIR=/certs')
            Mounts = @(
                (New-Mount 'volume' $volumes.DockerData '/var/lib/docker')
                (New-Mount 'volume' $volumes.DockerCerts '/certs')
                (New-Mount 'volume' $volumes.Work $linux.workFolder)
                (New-Mount 'bind' $RunnerDirectory '/runner' $true)
            )
        }
        $runner.Network = $Slot.Network
        # Ports that Testcontainers publishes live on the daemon's host, not on localhost.
        foreach ($entry in 'DOCKER_HOST=tcp://docker:2376', 'DOCKER_TLS_VERIFY=1', 'DOCKER_CERT_PATH=/certs/client', 'TESTCONTAINERS_HOST_OVERRIDE=docker') { $env.Add($entry) }
        $mounts.Add((New-Mount 'volume' $volumes.DockerCerts '/certs' $true))
        $mounts.Add((New-Mount 'volume' $volumes.Work $linux.workFolder))
    }
    elseif ($mode -eq 'dind') {
        # The runner itself is privileged and runs dockerd; images and build cache stay in dindVolume across jobs. Its daemon
        # listens on the default socket, so DOCKER_HOST stays unset and published ports are on localhost. The stop timeout
        # leaves the entrypoint time to stop the daemon cleanly after the runner exits.
        $runner.Privileged = $true
        $runner.StopTimeout = 60
        $env.Add('BUILD_AGENT_DOCKERD=1')
        $mounts.Add((New-Mount 'volume' $volumes.Dind '/var/lib/docker'))
    }
    $runner.Env = $env.ToArray()
    $runner.Mounts = $mounts.ToArray()
    @{ Runner = [pscustomobject]$runner; Sidecar = $(if ($sidecar) { [pscustomobject]$sidecar }) }
}

function ConvertTo-MountArgument($Mount) {
    "type=$($Mount.Type),source=$($Mount.Source),target=$($Mount.Target)$(if ($Mount.ReadOnly) { ',readonly' })"
}

# `docker run -d ...` arguments for one spec (the legacy, pre-compose way to start a container).
function ConvertTo-DockerRunArguments($Spec) {
    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]]@('run', '-d', '--name', $Spec.Name, '--restart', $Spec.Restart))
    if ($Spec.Privileged) { $arguments.Add('--privileged') }
    $arguments.AddRange([string[]]@('--cpus', "$($Spec.Cpus)", '--memory', "$($Spec.Memory)"))
    if ($Spec.StopTimeout) { $arguments.AddRange([string[]]@('--stop-timeout', "$($Spec.StopTimeout)")) }
    if ($Spec.Network) { $arguments.AddRange([string[]]@('--network', $Spec.Network)) }
    foreach ($alias in $Spec.NetworkAliases) { $arguments.AddRange([string[]]@('--network-alias', $alias)) }
    foreach ($entry in $Spec.Env) { $arguments.AddRange([string[]]@('-e', $entry)) }
    foreach ($path in $Spec.Tmpfs) { $arguments.AddRange([string[]]@('--tmpfs', $path)) }
    foreach ($label in $Spec.Labels.GetEnumerator()) { $arguments.AddRange([string[]]@('--label', "$($label.Key)=$($label.Value)")) }
    foreach ($mount in $Spec.Mounts) { $arguments.AddRange([string[]]@('--mount', (ConvertTo-MountArgument $mount))) }
    $arguments.Add($Spec.Image)
    $arguments.ToArray()
}

# A double-quoted YAML scalar (a JSON string is one), so paths with spaces, colons and backslashes need no thought.
function ConvertTo-YamlScalar($Value) { (ConvertTo-Json -InputObject ([string]$Value) -Compress) }

function ConvertTo-ComposeService($Spec, [string] $ServiceName, [string] $NetworkKey) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("  ${ServiceName}:")
    $lines.Add("    image: $(ConvertTo-YamlScalar $Spec.Image)")
    $lines.Add("    container_name: $(ConvertTo-YamlScalar $Spec.Name)")
    $lines.Add("    restart: $($Spec.Restart)")
    $lines.Add("    cpus: $(if ("$($Spec.Cpus)" -match '^[0-9.]+$') { "$($Spec.Cpus)" } else { ConvertTo-YamlScalar $Spec.Cpus })")
    $lines.Add("    mem_limit: $(ConvertTo-YamlScalar $Spec.Memory)")
    if ($Spec.Privileged) { $lines.Add('    privileged: true') }
    if ($Spec.StopTimeout) { $lines.Add("    stop_grace_period: $($Spec.StopTimeout)s") }
    $lines.Add('    environment:')
    foreach ($entry in $Spec.Env) { $key, $value = $entry -split '=', 2; $lines.Add("      ${key}: $(ConvertTo-YamlScalar $value)") }
    $lines.Add('    volumes:')
    foreach ($mount in $Spec.Mounts) {
        $lines.Add("      - type: $($mount.Type)")
        $lines.Add("        source: $(ConvertTo-YamlScalar $mount.Source)")
        $lines.Add("        target: $(ConvertTo-YamlScalar $mount.Target)")
        if ($mount.ReadOnly) { $lines.Add('        read_only: true') }
    }
    if ($Spec.Tmpfs.Count) { $lines.Add('    tmpfs:'); foreach ($path in $Spec.Tmpfs) { $lines.Add("      - $(ConvertTo-YamlScalar $path)") } }
    if ($Spec.Network) {
        $lines.Add('    networks:')
        $lines.Add("      ${NetworkKey}:")
        if ($Spec.NetworkAliases.Count) { $lines.Add('        aliases:'); foreach ($alias in $Spec.NetworkAliases) { $lines.Add("          - $(ConvertTo-YamlScalar $alias)") } }
    }
    if ($Spec.Labels.Count) { $lines.Add('    labels:'); foreach ($label in $Spec.Labels.GetEnumerator() | Sort-Object Key) { $lines.Add("      $($label.Key): $(ConvertTo-YamlScalar $label.Value)") } }
    $lines
}

# The compose file for these slots (Get-LinuxSlots rows). Networks and volumes are declared external: New-LinuxRunner creates
# them by name before any compose call, so volumes and networks the legacy runner already uses are adopted as they are and no
# compose call can ever remove one. LF line endings, no timestamps: the same slots always give the same bytes.
function ConvertTo-LinuxComposeYaml($Config, $Slots, [string] $RootDirectory, [string] $HooksDirectory) {
    $services = [Collections.Generic.List[string]]::new()
    $networks = [ordered]@{}
    $volumes = [ordered]@{}
    $hostId = Get-RunnerHostId $Config
    foreach ($slot in @($Slots)) {
        $directory = [IO.Path]::GetFullPath((Join-Path $RootDirectory $slot.Directory))
        $labels = @{ $ComposeHostLabel = $hostId; $ComposeSlotLabel = $slot.SlotId }
        $specs = Get-LinuxContainerSpecs $Config $slot $directory $HooksDirectory 'always' $labels
        $networkKey = "net-$($slot.SlotId)"
        $services.Add((ConvertTo-ComposeService $specs.Runner $slot.SlotId $networkKey) -join "`n")
        if ($specs.Sidecar) { $services.Add((ConvertTo-ComposeService $specs.Sidecar "$($slot.SlotId)-docker" $networkKey) -join "`n") }
        if ($slot.Network -and $specs.Sidecar) { $networks[$networkKey] = $slot.Network }
        foreach ($spec in @($specs.Runner, $specs.Sidecar) | Where-Object { $_ }) { foreach ($mount in $spec.Mounts | Where-Object { $_.Type -eq 'volume' }) { $volumes[$mount.Source] = $true } }
    }
    $text = [Collections.Generic.List[string]]::new()
    $text.Add('# Generated by New-LinuxRunner.ps1 from runners.json, runners.local.json and the host inventory. Do not edit; it is rewritten.')
    $text.Add("name: $ComposeProject")
    $text.Add('services:')
    $text.Add(($services -join "`n"))
    if ($networks.Count) {
        $text.Add('networks:')
        foreach ($key in $networks.Keys) { $text.Add("  ${key}:"); $text.Add("    name: $(ConvertTo-YamlScalar $networks[$key])"); $text.Add('    external: true') }
    }
    if ($volumes.Count) {
        $text.Add('volumes:')
        foreach ($name in $volumes.Keys) { $text.Add("  $(ConvertTo-YamlScalar $name):"); $text.Add('    external: true') }
    }
    ($text -join "`n") + "`n"
}

# --- the compose call -------------------------------------------------------------------------------------------------

# `docker compose` on one or more named services. The services are required and must be this pool's own; `up` always gets
# -d --no-deps, and the only other verb is `config --hash` (read-only). There is no way to ask for `down`.
function Invoke-LinuxCompose([Parameter(Mandatory)] [string] $File, [Parameter(Mandatory)] [ValidateSet('up', 'config')] [string] $Verb, [Parameter(Mandatory)] [string[]] $Services, [switch] $ForceRecreate) {
    if (-not $Services.Count) { throw "A compose $Verb call must name its services; none were given." }
    foreach ($service in $Services) { if ($service -notmatch '^linux-\d{2,}(-docker)?$') { throw "Compose service '$service' is not one of this pool's slots." } }
    $arguments = @('compose', '-p', $ComposeProject, '-f', $File)
    if ($Verb -eq 'up') { $arguments += @('up', '-d', '--no-deps'); if ($ForceRecreate) { $arguments += '--force-recreate' } }
    else { $arguments += @('config', '--hash', ($Services -join ',')) }
    Invoke-Docker ($arguments + @(if ($Verb -eq 'up') { $Services }))
}

# Creates the named network and volumes when they do not exist (idempotent), because the compose file declares them external.
function Initialize-LinuxSlotResources($Config, $Slot) {
    $volumes = @($Slot.Volumes.Cache)
    if ($Config.linux.docker.mode -eq 'sidecar') {
        $volumes += @($Slot.Volumes.DockerData, $Slot.Volumes.DockerCerts, $Slot.Volumes.Work)
        $exists = Invoke-Docker @('network', 'inspect', $Slot.Network)
        if ($exists.ExitCode -ne 0) {
            $created = Invoke-Docker @('network', 'create', $Slot.Network)
            if ($created.ExitCode -ne 0) { throw "Network $($Slot.Network) could not be created: $($created.Output)" }
        }
    }
    elseif ($Config.linux.docker.mode -eq 'dind') { $volumes += $Slot.Volumes.Dind }
    foreach ($volume in $volumes) {
        $created = Invoke-Docker @('volume', 'create', $volume)
        if ($created.ExitCode -ne 0) { throw "Volume $volume could not be created: $($created.Output)" }
    }
}

# --- the image's build context hash ----------------------------------------------------------------------------------------

function ConvertTo-DockerIgnoreRegex([string] $Pattern) {
    $builder = [Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $Pattern.Length; $i++) {
        $c = $Pattern[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '*') { [void]$builder.Append('.*'); $i++; if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '/') { $i++ } }
            else { [void]$builder.Append('[^/]*') }
        }
        elseif ($c -eq '?') { [void]$builder.Append('[^/]') }
        else { [void]$builder.Append([regex]::Escape([string]$c)) }
    }
    [void]$builder.Append('$')
    $builder.ToString()
}

# The patterns of a .dockerignore, in order: @{ Negated; Regex; Literal }.
function Read-DockerIgnore([string] $Path) {
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $negated = $text.StartsWith('!')
        if ($negated) { $text = $text.Substring(1).Trim() }
        $text = $text.Trim('/')
        if (-not $text) { continue }
        [pscustomobject]@{ Negated = $negated; Regex = [regex]::new((ConvertTo-DockerIgnoreRegex $text)); Literal = $text }
    }
}

# Last matching pattern wins. A pattern also matches every path below a directory it matches (an excluded directory excludes
# what is in it, unless a later pattern takes something back in).
function Test-DockerIgnored($Patterns, [string] $RelativePath) {
    $ignored = $false
    $segments = $RelativePath -split '/'
    foreach ($pattern in $Patterns) {
        for ($length = 1; $length -le $segments.Count; $length++) {
            if ($pattern.Regex.IsMatch(($segments[0..($length - 1)] -join '/'))) { $ignored = -not $pattern.Negated; break }
        }
    }
    $ignored
}

# Every file `docker build` is sent for this context (relative paths, '/' separators, sorted): the files .dockerignore admits.
# A directory that is excluded is walked only when a later pattern could take something inside it back in.
function Get-LinuxBuildContextFiles([string] $ContextDirectory) {
    $ignorePath = Join-Path $ContextDirectory '.dockerignore'
    $patterns = if (Test-Path -LiteralPath $ignorePath) { @(Read-DockerIgnore $ignorePath) } else { @() }
    $found = [Collections.Generic.List[string]]::new()
    $walk = $null
    $walk = {
        param([string] $Directory, [string] $Prefix)
        foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
            $relative = if ($Prefix) { "$Prefix/$($item.Name)" } else { $item.Name }
            $ignored = Test-DockerIgnored $patterns $relative
            if ($item.PSIsContainer) {
                $mayReturn = @($patterns | Where-Object { $_.Negated -and $_.Literal.StartsWith("$relative/") }).Count -gt 0
                if (-not $ignored -or $mayReturn) { & $walk $item.FullName $relative }
            }
            elseif (-not $ignored) { $found.Add($relative) }
        }
    }
    & $walk $ContextDirectory ''
    # The build always receives .dockerignore itself and the Dockerfile.
    if (Test-Path -LiteralPath $ignorePath) { $found.Add('.dockerignore') }
    $found | Sort-Object -Unique -CaseSensitive
}

# SHA-256 over .dockerignore, each file it admits (path and content) and the build arguments. Anything that changes the image
# changes this value; it is stored as the image label dev.subzerodev.runners.context.
function Get-LinuxBuildContextHash([string] $ContextDirectory, [hashtable] $BuildArguments) {
    $parts = [Collections.Generic.List[string]]::new()
    foreach ($relative in Get-LinuxBuildContextFiles $ContextDirectory) {
        $parts.Add("file:$relative=$((Get-FileHash -LiteralPath (Join-Path $ContextDirectory $relative) -Algorithm SHA256).Hash)")
    }
    foreach ($name in $BuildArguments.Keys | Sort-Object) { $parts.Add("arg:$name=$($BuildArguments[$name])") }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))| ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# The context hash stored on an image: $null when the image is absent or has no label.
function Get-LinuxImageContextHash([string] $Image) {
    $inspect = Invoke-Docker @('image', 'inspect', '--format', "{{ index .Config.Labels `"$ContextHashLabel`" }}", $Image)
    if ($inspect.ExitCode -ne 0) { return $null }
    $value = $inspect.Output.Trim()
    if ($value -and $value -ne '<no value>') { $value }
}

# Whether a container was created by compose. Unknown (docker cannot be asked) counts as compose, so -Update fails closed.
function Get-ContainerComposeProject([string] $Name) {
    $inspect = Invoke-Docker @('container', 'inspect', '--format', '{{ index .Config.Labels "com.docker.compose.project" }}', $Name)
    if ($null -eq $inspect.ExitCode) { return [pscustomobject]@{ State = 'unknown'; Project = $null } }
    if ($inspect.ExitCode -ne 0) { return [pscustomobject]@{ State = $(if ($inspect.Output -match 'No such (container|object)') { 'absent' } else { 'unknown' }); Project = $null } }
    $value = $inspect.Output.Trim()
    [pscustomobject]@{ State = 'present'; Project = $(if ($value -and $value -ne '<no value>') { $value }) }
}
