#Requires -Version 7.2
# Tests for the Linux runners as compose services (S4): the generated compose file, every compose call, the image's build
# context hash, per-slot recreation, the -Update refusal and Get-LinuxRunnerStatus.ps1 -Json.
#   - one container spec drives both `docker run` and the compose file, and says what `docker run` always said;
#   - every compose call names its services, `up` carries --no-deps, and there is no `down`;
#   - recreating slot 02 while slot 01 is busy touches nothing of slot 01 (containers, labels, volumes, networks);
#   - each of Dockerfile, entrypoint.sh, healthcheck.sh, the runner archive, .dockerignore and a build argument changes the
#     context hash and makes New-LinuxRunner rebuild; a file .dockerignore keeps out does not;
#   - -Update refuses a container compose manages;
#   - the status script reports drift per slot, and 'not-checked' (never 'ok') for what it cannot check.
# GitHub and Docker are a fake gh and docker first on PATH. No daemon, registration or network is used.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

. (Join-Path $repo 'scripts\Common.ps1')
. (Join-Path $repo 'scripts\Compose.ps1')
$HostInventorySchema = 'subzerodev.runners.host-inventory'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('szr-compose-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
$pwshPath = (Get-Process -Id $PID).Path
$url = 'https://github.com/AbsoluteZeroDev'
$baseImage = 'ghcr.io/example/base@sha256:' + ('a' * 64)

$cases = [Collections.Generic.List[object]]::new()
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body | Out-Null; $cases.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null }); Write-Host "PASS  $Name" }
    catch { $cases.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }); Write-Host "FAIL  $Name`n        $($_.Exception.Message)" }
}
function New-CaseDirectory { $directory = Join-Path $temp ([guid]::NewGuid().ToString('N').Substring(0, 12)); New-Item -ItemType Directory -Path $directory | Out-Null; $directory }
function Write-Raw([string] $Path, [string] $Text) { New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null; [IO.File]::WriteAllText($Path, $Text) }

# --- unit: the container specs, the compose file and the compose call -------------------------------------------------------

function Get-Pairs([string[]] $Arguments) {
    # `docker run -d` arguments as sorted "flag value" strings (order never mattered to docker), the image last.
    $pairs = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($a -in 'run', '-d') { continue }
        if ($a -eq '--privileged') { $pairs.Add($a) }
        elseif ($a.StartsWith('-')) { $pairs.Add("$a $($Arguments[$i + 1])"); $i++ }
        else { $pairs.Add("image $a") }
    }
    @($pairs | Sort-Object -CaseSensitive)
}
function Copy-Config($Config, [string] $Mode) {
    $copy = $Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $copy.linux.docker.mode = $Mode
    $copy
}

Test-Case 'The specs give `docker run` the arguments it always had, in sidecar and dind mode, with spaces in the paths' {
    $runnerDir = 'C:\work dir\runner installation'
    $hooks = 'C:\work dir\scripts'
    foreach ($mode in 'sidecar', 'dind') {
        $cfg = Copy-Config $Config $mode
        $linux = $cfg.linux; $d = $linux.docker
        $specs = Get-LinuxContainerSpecs $cfg (Get-LegacyLinuxSlot $cfg) $runnerDir $hooks
        $expected = [Collections.Generic.List[string]]::new()
        foreach ($entry in @(
                "--name $($linux.container)", '--restart unless-stopped', "--cpus $($linux.cpus)", "--memory $($linux.memory)",
                "-e RUNNER_WORK_FOLDER=$($linux.workFolder)", '-e ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/runner-hooks/Clear-LinuxWorkspace.sh',
                "-e RUNNER_CLEANUP_RETRIES=$($cfg.housekeeping.retries)", "-e RUNNER_CLEANUP_DELAY=$($cfg.housekeeping.retryDelaySeconds)",
                "--mount type=bind,source=$runnerDir,target=/runner", "--mount type=volume,source=$($linux.cacheVolume),target=/cache",
                "--mount type=bind,source=$hooks,target=/runner-hooks,readonly", "image $($linux.image)")) { $expected.Add($entry) }
        if ($mode -eq 'sidecar') {
            foreach ($entry in @("--network $($d.network)", '-e DOCKER_HOST=tcp://docker:2376', '-e DOCKER_TLS_VERIFY=1', '-e DOCKER_CERT_PATH=/certs/client',
                    '-e TESTCONTAINERS_HOST_OVERRIDE=docker', "--mount type=volume,source=$($d.certsVolume),target=/certs,readonly",
                    "--mount type=volume,source=$($d.workVolume),target=$($linux.workFolder)")) { $expected.Add($entry) }
        }
        else {
            foreach ($entry in @('--privileged', '-e BUILD_AGENT_DOCKERD=1', '--stop-timeout 60', "--mount type=volume,source=$($d.dindVolume),target=/var/lib/docker")) { $expected.Add($entry) }
        }
        $actual = Get-Pairs (ConvertTo-DockerRunArguments $specs.Runner)
        $want = @($expected | Sort-Object -CaseSensitive)
        Assert (($actual -join "`n") -ceq ($want -join "`n")) "Runner arguments changed in $mode mode.`nactual:`n$($actual -join "`n")`nexpected:`n$($want -join "`n")"
        if ($mode -eq 'sidecar') {
            $side = @(
                "--name $($d.container)", '--restart unless-stopped', '--privileged', "--cpus $($d.cpus)", "--memory $($d.memory)", "--network $($d.network)",
                '--network-alias docker', '-e DOCKER_TLS_CERTDIR=/certs', '--tmpfs /tmp',
                "--mount type=volume,source=$($d.dataVolume),target=/var/lib/docker", "--mount type=volume,source=$($d.certsVolume),target=/certs",
                "--mount type=volume,source=$($d.workVolume),target=$($linux.workFolder)", "--mount type=bind,source=$runnerDir,target=/runner,readonly", "image $($d.image)") | Sort-Object -CaseSensitive
            $actualSide = Get-Pairs (ConvertTo-DockerRunArguments $specs.Sidecar)
            Assert (($actualSide -join "`n") -ceq ($side -join "`n")) "Sidecar arguments changed.`nactual:`n$($actualSide -join "`n")"
        }
        else { Assert ($null -eq $specs.Sidecar) 'dind mode has a sidecar.' }
    }
}

Test-Case 'The compose file says what the specs say: names, images, limits, mounts, environment, networks, labels, external volumes' {
    $root = 'C:\work dir\runner root'
    $hooks = 'C:\work dir\runner root\scripts'
    foreach ($mode in 'sidecar', 'dind') {
        $cfg = Copy-Config $Config $mode
        $cfg.hostId = 'testhost'
        $slots = @(Get-LinuxSlots $cfg ([pscustomobject]@{ slots = @() }) 2)
        $yaml = ConvertTo-LinuxComposeYaml $cfg $slots $root $hooks
        Assert ($yaml -notmatch "`r") 'The compose file has CR characters.'
        Assert ($yaml.EndsWith("`n") -and -not $yaml.EndsWith("`n`n")) 'The compose file does not end in exactly one LF.'
        Assert ($yaml -ceq (ConvertTo-LinuxComposeYaml $cfg $slots $root $hooks)) 'The same slots gave different bytes.'
        Assert ($yaml -match "(?m)^name: $ComposeProject$") 'The compose project name is missing.'
        foreach ($slot in $slots) {
            $directory = [IO.Path]::GetFullPath((Join-Path $root $slot.Directory))
            $specs = Get-LinuxContainerSpecs $cfg $slot $directory $hooks 'always' @{ $ComposeHostLabel = 'testhost'; $ComposeSlotLabel = $slot.SlotId }
            foreach ($spec in @($specs.Runner, $specs.Sidecar) | Where-Object { $_ }) {
                Assert ($yaml.Contains("container_name: $(ConvertTo-YamlScalar $spec.Name)")) "container_name for $($spec.Name) is missing."
                Assert ($yaml.Contains("image: $(ConvertTo-YamlScalar $spec.Image)")) "image of $($spec.Name) is missing."
                Assert ($yaml.Contains("mem_limit: $(ConvertTo-YamlScalar $spec.Memory)")) "mem_limit of $($spec.Name) is missing."
                foreach ($mount in $spec.Mounts) {
                    Assert ($yaml.Contains("source: $(ConvertTo-YamlScalar $mount.Source)")) "mount source $($mount.Source) is missing."
                    Assert ($yaml.Contains("target: $(ConvertTo-YamlScalar $mount.Target)")) "mount target $($mount.Target) is missing."
                }
                foreach ($entry in $spec.Env) { $k, $v = $entry -split '=', 2; Assert ($yaml.Contains("${k}: $(ConvertTo-YamlScalar $v)")) "environment $entry is missing." }
            }
            Assert ($yaml -match "(?m)^  $($slot.SlotId):$") "service $($slot.SlotId) is missing."
            Assert ($yaml.Contains("$ComposeSlotLabel`: $(ConvertTo-YamlScalar $slot.SlotId)")) 'The slot label is missing.'
            Assert ($yaml.Contains('source: "' + ($directory -replace '\\', '\\') + '"')) "The runner directory of $($slot.SlotId) is not quoted as a path with spaces."
        }
        Assert ($yaml -match '(?m)^    restart: always$' -and $yaml -notmatch 'unless-stopped') 'Compose containers do not restart always.'
        Assert ($yaml -match 'external: true') 'Volumes and networks are not external.'
        Assert ($yaml -notmatch '(?m)^\s+driver:') 'The compose file declares a driver (it would create what it must not).'
        if ($mode -eq 'sidecar') {
            Assert ($yaml -match '(?m)^  linux-01-docker:$' -and $yaml -match '(?m)^  linux-02-docker:$') 'A sidecar service is missing.'
            Assert (($yaml -split "`n" | Where-Object { $_ -match '^\s+privileged: true$' }).Count -eq 2) 'Only the two sidecars should be privileged.'
            Assert ($yaml.Contains("aliases:`n          - `"docker`"")) 'The sidecar lost its network alias.'
        }
        else {
            Assert ($yaml -notmatch '-docker:$' -and $yaml -match 'BUILD_AGENT_DOCKERD') 'dind mode has a sidecar or lost its daemon setting.'
            Assert ($yaml -match 'stop_grace_period: 60s') 'dind mode lost its stop timeout.'
        }
    }
}

Test-Case 'Every compose call names its services and --no-deps; nothing can ask for `down`' {
    $script:calls = [Collections.Generic.List[object]]::new()
    function Invoke-Docker([string[]] $Arguments) { $script:calls.Add($Arguments); [pscustomobject]@{ ExitCode = 0; Output = '' } }
    Invoke-LinuxCompose -File 'C:\a b\compose.yaml' -Verb up -Services 'linux-02-docker' -ForceRecreate | Out-Null
    Invoke-LinuxCompose -File 'C:\a b\compose.yaml' -Verb up -Services 'linux-02' | Out-Null
    Invoke-LinuxCompose -File 'C:\a b\compose.yaml' -Verb config -Services 'linux-02' | Out-Null
    $line = { param($c) $c -join ' ' }
    Assert ((& $line $script:calls[0]) -ceq 'compose -p subzerodev-runners -f C:\a b\compose.yaml up -d --no-deps --force-recreate linux-02-docker') "up call: $(& $line $script:calls[0])"
    Assert ((& $line $script:calls[1]) -ceq 'compose -p subzerodev-runners -f C:\a b\compose.yaml up -d --no-deps linux-02') "up call: $(& $line $script:calls[1])"
    Assert ((& $line $script:calls[2]) -ceq 'compose -p subzerodev-runners -f C:\a b\compose.yaml config --hash linux-02') "config call: $(& $line $script:calls[2])"
    foreach ($bad in @(@{ Verb = 'down'; Services = 'linux-02' }, @{ Verb = 'up'; Services = @() }, @{ Verb = 'up'; Services = 'subzerodev-runner-linux' }, @{ Verb = 'up'; Services = 'linux-02;rm' })) {
        $threw = $false
        try { Invoke-LinuxCompose -File 'f' -Verb $bad.Verb -Services $bad.Services | Out-Null } catch { $threw = $true }
        Assert $threw "A compose call with verb '$($bad.Verb)' and services '$($bad.Services -join ',')' was accepted."
    }
    Assert ($script:calls.Count -eq 3) 'A refused compose call still reached docker.'
    foreach ($file in 'Compose.ps1', 'New-LinuxRunner.ps1', 'Get-LinuxRunnerStatus.ps1', 'Manage-RunnerHost.ps1') {
        $text = [IO.File]::ReadAllText((Join-Path $repo "scripts\$file"))
        Assert ($text -notmatch "(?m)'compose'[^\r\n]*'down'|compose\s+down|\bdown\b\s*'?,?\s*-v") "$file can ask compose for `down`."
    }
}

# --- unit: the build context hash ------------------------------------------------------------------------------------------

function New-Context([string] $Directory) {
    New-Item -ItemType Directory -Path (Join-Path $Directory 'linux'), (Join-Path $Directory 'downloads'), (Join-Path $Directory 'scripts') -Force | Out-Null
    Copy-Item (Join-Path $repo '.dockerignore') $Directory
    foreach ($file in 'Dockerfile', 'entrypoint.sh', 'healthcheck.sh') { Copy-Item (Join-Path $repo "linux\$file") (Join-Path $Directory 'linux') }
    [IO.File]::WriteAllText((Join-Path $Directory 'downloads\actions-runner-linux-x64-2.338.0.tar.gz'), 'archive one')
    # What .dockerignore keeps out of the build:
    [IO.File]::WriteAllText((Join-Path $Directory 'README.md'), 'readme')
    [IO.File]::WriteAllText((Join-Path $Directory 'scripts\Common.ps1'), 'script')
    [IO.File]::WriteAllText((Join-Path $Directory 'linux\compose.local.yaml'), 'generated')
    [IO.File]::WriteAllText((Join-Path $Directory 'downloads\notes.txt'), 'note')
}

Test-Case 'The context hash covers exactly the files .dockerignore admits' {
    $context = New-CaseDirectory
    New-Context $context
    $files = @(Get-LinuxBuildContextFiles $context)
    $expected = @('.dockerignore', 'downloads/actions-runner-linux-x64-2.338.0.tar.gz', 'linux/Dockerfile', 'linux/entrypoint.sh', 'linux/healthcheck.sh')
    Assert (($files -join '|') -ceq ($expected -join '|')) "The admitted files are: $($files -join ', ')"
    # The repository's own context: its four tracked files, plus a downloaded runner archive when one is present.
    $own = @(Get-LinuxBuildContextFiles $repo)
    foreach ($needed in '.dockerignore', 'linux/Dockerfile', 'linux/entrypoint.sh', 'linux/healthcheck.sh') { Assert ($needed -in $own) "$needed is not in the repository's build context." }
    $other = @($own | Where-Object { $_ -notin $expected -and $_ -notlike 'downloads/actions-runner-linux-x64-*.tar.gz' })
    Assert (-not $other.Count) "The repository's build context holds files nothing says it should: $($other -join ', ')"
}

Test-Case 'Each admitted file and each build argument changes the hash; a file .dockerignore keeps out does not' {
    $context = New-CaseDirectory
    New-Context $context
    $arguments = @{ BASE_IMAGE = $baseImage; RUNNER_VERSION = '2.338.0'; RUNNER_SHA256 = ('b' * 64) }
    $base = Get-LinuxBuildContextHash $context $arguments
    Assert ($base -match '^[0-9a-f]{64}$') "The hash is not SHA-256: $base"
    Assert ($base -ceq (Get-LinuxBuildContextHash $context $arguments)) 'The hash is not stable.'
    Assert ($base -ceq (Get-LinuxBuildContextHash $context ([ordered]@{ RUNNER_SHA256 = ('b' * 64); RUNNER_VERSION = '2.338.0'; BASE_IMAGE = $baseImage }))) 'The hash depends on the order of the build arguments.'
    foreach ($relative in 'linux/Dockerfile', 'linux/entrypoint.sh', 'linux/healthcheck.sh', 'downloads/actions-runner-linux-x64-2.338.0.tar.gz', '.dockerignore') {
        $path = Join-Path $context $relative
        $before = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path, "$before`nchanged")
        $changed = Get-LinuxBuildContextHash $context $arguments
        [IO.File]::WriteAllText($path, $before)
        Assert ($changed -cne $base) "Changing $relative did not change the hash."
    }
    foreach ($name in $arguments.Keys) {
        $copy = $arguments.Clone(); $copy[$name] = "$($copy[$name])x"
        Assert ((Get-LinuxBuildContextHash $context $copy) -cne $base) "Changing build argument $name did not change the hash."
    }
    foreach ($relative in 'README.md', 'scripts/Common.ps1', 'linux/compose.local.yaml', 'downloads/notes.txt') {
        $path = Join-Path $context $relative
        [IO.File]::WriteAllText($path, 'something else entirely')
        Assert ((Get-LinuxBuildContextHash $context $arguments) -ceq $base) "Changing $relative (not sent to the build) changed the hash."
    }
    [IO.File]::WriteAllText((Join-Path $context 'linux\extra.sh'), 'new')
    Assert ((Get-LinuxBuildContextHash $context $arguments) -ceq $base) 'A new file under linux/ that .dockerignore keeps out changed the hash.'
}

# --- fixtures: the real scripts against a fake docker -----------------------------------------------------------------------

$fakeGh = @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
$path = Join-Path $dir 'world.json'
if ($line -match 'releases/tags/') { Get-Content -Raw -LiteralPath (Join-Path $dir 'release.json'); exit 0 }
$world = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
if ($line -match 'actions/runners/(\d+)/labels') {
    $id = [int64]$Matches[1]
    foreach ($runner in @($world.runners)) {
        if ($runner.id -ne $id) { continue }
        if ($line -match '-X DELETE') { $runner.labels = @($runner.labels | Where-Object { $_.type -ne 'custom' }) }
        elseif ($line -match '-X POST') {
            $have = @($runner.labels | ForEach-Object { $_.name })
            foreach ($m in [regex]::Matches($line, 'labels\[\]=(\S+)')) { if ($m.Groups[1].Value -notin $have) { $runner.labels = @($runner.labels) + [pscustomobject]@{ name = $m.Groups[1].Value; type = 'custom' } } }
        }
    }
    $world | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
    exit 0
}
if ($line -match '-X (POST|PUT|PATCH|DELETE)') { exit 0 }
if ($line -match 'actions/runners') { foreach ($r in @($world.runners)) { $r | ConvertTo-Json -Compress -Depth 8 }; exit 0 }
exit 0
'@
# The fake Docker keeps docker.json: unavailable, busy (containers whose runner has a job), image {id, context} (absent when
# null), services {service: container}, containers {name: {running, project, image, hash}}. Every call is logged to docker.log.
$fakeDocker = @'
$dir = $env:FAKE_GH_DIR
Add-Content -LiteralPath (Join-Path $dir 'docker.log') -Value ($args -join ' ')
$path = Join-Path $dir 'docker.json'
$state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
$save = { $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path }
$a = @($args)
if ($state.unavailable) { [Console]::Error.WriteLine('error during connect: the Docker daemon is not running (fake)'); exit 1 }
$formatIndex = [array]::IndexOf($a, '--format')
$format = if ($formatIndex -ge 0) { $a[$formatIndex + 1] }
switch ($a[0]) {
    'info' { 'fake docker'; exit 0 }
    'volume' { exit 0 }
    'network' { exit 0 }
    'exec' {
        if ($a -contains 'pgrep') { if ($a[1] -in @($state.busy)) { exit 0 } else { exit 1 } }
        exit 0
    }
    'build' {
        $context = ($a | Where-Object { $_ -like 'dev.subzerodev.runners.context=*' } | Select-Object -First 1) -replace '^[^=]+=', ''
        $state | Add-Member -Force -NotePropertyName image -NotePropertyValue ([pscustomobject]@{ id = 'sha256:' + ([guid]::NewGuid().ToString('N')); context = $context })
        & $save
        exit 0
    }
    'image' {
        if (-not $state.image) { [Console]::Error.WriteLine('Error: No such image: ' + $a[-1]); exit 1 }
        if ($format -like '*Config.Labels*') { if ($state.image.context) { $state.image.context } else { '<no value>' } } else { $state.image.id }
        exit 0
    }
    'compose' {
        $verbAt = [array]::IndexOf($a, 'up'); if ($verbAt -lt 0) { $verbAt = [array]::IndexOf($a, 'config') }
        if ($a[$verbAt] -eq 'config') { "$($a[-1]) $($state.configHash)"; exit 0 }
        if ($state.failUp) { [Console]::Error.WriteLine('compose up failed (fake)'); exit 1 }
        $noDeps = [array]::IndexOf($a, '--no-deps')
        foreach ($service in @($a[($noDeps + 1)..($a.Count - 1)] | Where-Object { $_ -notlike '--*' })) {
            $name = $state.services.$service
            $state.containers | Add-Member -Force -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{ running = $true; project = 'subzerodev-runners'; image = $state.image.id; hash = $state.configHash })
        }
        & $save
        exit 0
    }
    'container' {
        $name = $a[-1]
        $container = $state.containers.$name
        if (-not $container) { [Console]::Error.WriteLine("Error: No such container: $name"); exit 1 }
        if ($format -like '*compose.project*') { if ($container.project) { $container.project } else { '<no value>' } }
        elseif ($format -like '*config-hash*') { if ($container.hash) { $container.hash } else { '<no value>' } }
        elseif ($format -eq '{{.Image}}') { $container.image }
        elseif ($format -eq '{{.Id}}') { "id-$name" }
        elseif ($format) { if ($container.running) { 'true' } else { 'false' } }
        exit 0
    }
    { $_ -in 'stop', 'start' } { exit 0 }
}
[Console]::Error.WriteLine("fake docker: unexpected call $($a -join ' ')")
exit 1
'@

function Set-Json([string] $Path, $Value) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path }
function Get-Json([string] $Path) { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
function Set-Archive($Fixture, [string] $Text) {
    $path = Join-Path $Fixture.Clone 'downloads\actions-runner-linux-x64-2.338.0.tar.gz'
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Text)
    $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Json (Join-Path $Fixture.GhState 'release.json') @{ assets = @(@{ name = 'actions-runner-linux-x64-2.338.0.tar.gz'; digest = "sha256:$digest" }) }
    $digest
}
function Get-DockerLog($Fixture) { @(Get-Content -LiteralPath (Join-Path $Fixture.GhState 'docker.log') -ErrorAction SilentlyContinue) }
function Clear-DockerLog($Fixture) { Remove-Item -LiteralPath (Join-Path $Fixture.GhState 'docker.log'), (Join-Path $Fixture.GhState 'calls.log') -ErrorAction SilentlyContinue }
function Get-DockerState($Fixture) { Get-Json (Join-Path $Fixture.GhState 'docker.json') }
function Set-DockerState($Fixture, $State) { Set-Json (Join-Path $Fixture.GhState 'docker.json') $State }

# Two compose slots, 01 and 02, both registered and active; both containers exist and run.
function New-Fixture([hashtable] $Linux = @{}) {
    $clone = New-CaseDirectory
    Copy-Item (Join-Path $repo 'runners.json') $clone
    Copy-Item (Join-Path $repo '.dockerignore') $clone
    Copy-Item (Join-Path $repo 'scripts') (Join-Path $clone 'scripts') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $clone 'linux') | Out-Null
    foreach ($file in 'Dockerfile', 'entrypoint.sh', 'healthcheck.sh') { Copy-Item (Join-Path $repo "linux\$file") (Join-Path $clone 'linux') }
    $shim = Join-Path $clone 'shim'; $ghState = Join-Path $clone 'gh'; $localAppData = Join-Path $clone 'LocalAppData'
    New-Item -ItemType Directory -Path $shim, $ghState, $localAppData | Out-Null
    Set-Content -LiteralPath (Join-Path $shim 'gh.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-gh.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'docker.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-docker.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'fake-gh.ps1') -Value $fakeGh
    Set-Content -LiteralPath (Join-Path $shim 'fake-docker.ps1') -Value $fakeDocker
    $linuxSettings = [ordered]@{ count = 2; baseImage = $baseImage }
    foreach ($key in $Linux.Keys) { $linuxSettings[$key] = $Linux[$key] }
    [ordered]@{
        hostId = 'testhost'; github = [ordered]@{ url = $url }
        buildAgent = [ordered]@{ docker = [ordered]@{ cli = (Join-Path $shim 'docker.cmd'); readyTimeoutSeconds = 20 } }
        linux = $linuxSettings; lifecycle = [ordered]@{ drainTimeoutMinutes = 1; pollSeconds = 1 }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $fixture = [pscustomobject]@{ Clone = $clone; Shim = $shim; GhState = $ghState; LocalAppData = $localAppData; State = (Join-Path $localAppData 'SubZeroDev\Runners\host') }
    New-Item -ItemType Directory -Path $fixture.State -Force | Out-Null
    $slots = foreach ($n in '01', '02') {
        $directory = Join-Path $clone "linux\runner-$n"
        New-Item -ItemType Directory -Path $directory | Out-Null
        [ordered]@{ agentId = [int]$n + 7; agentName = "subzerodev.runner.linux.testhost.$n"; gitHubUrl = $url; workFolder = '_work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory '.runner')
        [ordered]@{ slotId = "linux-$n"; platform = 'linux'; state = 'active'; legacy = $false; runnerName = "subzerodev.runner.linux.testhost.$n"; runnerId = [int]$n + 7
            scope = 'orgs/AbsoluteZeroDev'; registrationDirectory = $directory }
    }
    $inventory = [ordered]@{ schema = 'subzerodev.host-inventory'; version = 1; generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @($slots) }
    $inventory.schema = $HostInventorySchema
    Write-Raw (Join-Path $fixture.State 'inventory.json') (ConvertTo-Json -InputObject $inventory -Depth 20)
    $runners = foreach ($n in '01', '02') {
        @{ id = [int]$n + 7; name = "subzerodev.runner.linux.testhost.$n"; status = 'online'; busy = $false; labels = @(@{ name = 'self-hosted'; type = 'read-only' }, @{ name = 'subzerodev-linux'; type = 'custom' }) }
    }
    Set-Json (Join-Path $ghState 'world.json') @{ runners = @($runners) }
    $services = @{}
    $containers = [ordered]@{}
    foreach ($n in '01', '02') {
        $services["linux-$n"] = "subzerodev-runner-linux-$n"; $services["linux-$n-docker"] = "subzerodev-runner-linux-docker-$n"
        foreach ($name in "subzerodev-runner-linux-$n", "subzerodev-runner-linux-docker-$n") { $containers[$name] = @{ running = $true; project = 'subzerodev-runners'; image = 'sha256:old'; hash = 'oldhash' } }
    }
    Set-Json (Join-Path $ghState 'docker.json') @{ unavailable = $false; busy = @(); image = $null; configHash = 'newhash'; services = $services; containers = $containers }
    $null = Set-Archive $fixture 'archive one'
    $fixture
}
function Use-Fixture($Fixture, [scriptblock] $Body) {
    $old = @{ PATH = $env:PATH; FAKE_GH_DIR = $env:FAKE_GH_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; SZR_HOST_OPERATION = $env:SZR_HOST_OPERATION }
    try { $env:PATH = "$($Fixture.Shim);$($old.PATH)"; $env:FAKE_GH_DIR = $Fixture.GhState; $env:LOCALAPPDATA = $Fixture.LocalAppData; $env:SZR_HOST_OPERATION = $null; & $Body }
    finally { $env:PATH = $old.PATH; $env:FAKE_GH_DIR = $old.FAKE_GH_DIR; $env:LOCALAPPDATA = $old.LOCALAPPDATA; $env:SZR_HOST_OPERATION = $old.SZR_HOST_OPERATION }
}
function Invoke-Script($Fixture, [string] $Script, [string[]] $Arguments = @()) {
    Use-Fixture $Fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone "scripts\$Script") @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
function Get-CustomLabels($Fixture, [string] $Name) { @((Get-Json (Join-Path $Fixture.GhState 'world.json')).runners | Where-Object name -EQ $Name | ForEach-Object { $_.labels } | Where-Object { $_.type -eq 'custom' } | ForEach-Object name) }
function Get-Builds($Fixture) { @(Get-DockerLog $Fixture | Where-Object { $_ -like 'build *' }) }
function Get-Ups($Fixture) { @(Get-DockerLog $Fixture | Where-Object { $_ -like 'compose *' -and $_ -like '* up *' }) }

Test-Case 'Recreating slot 02 while slot 01 is busy touches nothing of slot 01' {
    $f = New-Fixture
    $state = Get-DockerState $f; $state.busy = @('subzerodev-runner-linux-01'); Set-DockerState $f $state
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 0) "New-LinuxRunner -Slot linux-02 exited $($run.ExitCode): $($run.Output)"
    $log = Get-DockerLog $f
    $touching = @($log | Where-Object { $_ -match 'linux-01|runner-linux-01|docker-01' })
    Assert (-not $touching.Count) "Slot 01 was touched:`n$($touching -join "`n")"
    $ups = Get-Ups $f
    Assert ($ups.Count -eq 2) "Expected two compose up calls (sidecar, runner); got: $($ups -join ' | ')"
    Assert ($ups[0] -match '--no-deps --force-recreate linux-02-docker$') "The sidecar was not recreated first, alone: $($ups[0])"
    Assert ($ups[1] -match '--no-deps --force-recreate linux-02$') "The runner was not recreated alone: $($ups[1])"
    $others = @($log | Where-Object { $_ -match '^compose' -and $_ -notmatch ' up ' -and $_ -notmatch ' config ' })
    Assert (-not $others.Count -and -not @($log | Where-Object { $_ -match '^(rm|stop|kill|down)\b| down( |$)' }).Count) "Something other than up ran: $($log -join ' | ')"
    Assert (@($log | Where-Object { $_ -match '^volume create' }).Count -eq 4 -and -not @($log | Where-Object { $_ -match '^volume (rm|prune)|^network (rm|prune)' }).Count) 'Volumes were not created idempotently, or one was removed.'
    $calls = @(Get-Content -LiteralPath (Join-Path $f.GhState 'calls.log') -ErrorAction SilentlyContinue)
    Assert (-not @($calls | Where-Object { $_ -match 'runners/8/' }).Count) 'GitHub was asked about slot 01.'
    Assert ('subzerodev-linux' -in (Get-CustomLabels $f 'subzerodev.runner.linux.testhost.01')) 'Slot 01 lost its labels.'
    Assert ('subzerodev-linux' -in (Get-CustomLabels $f 'subzerodev.runner.linux.testhost.02')) 'Slot 02 did not get its labels back.'
    Assert (-not (Test-Path (Join-Path $f.Clone 'linux\runner-02\maintenance.json'))) 'Slot 02 is still in maintenance.'
    Assert (-not (Test-Path (Join-Path $f.Clone 'linux\runner-01\maintenance.json'))) 'Slot 01 was put in maintenance.'
    $inventory = Get-Json (Join-Path $f.State 'inventory.json')
    $record = $inventory.slots | Where-Object slotId -EQ 'linux-02'
    $recorded = @($record.containers | ForEach-Object { "$($_.role)=$($_.id)" }) -join ','
    Assert ($recorded -ceq 'runner=id-subzerodev-runner-linux-02,docker=id-subzerodev-runner-linux-docker-02') "The new container IDs were not recorded as role/id entries: $recorded"
    Assert ($inventory.generation -eq 2) "The inventory generation is $($inventory.generation), not 2."
    $yaml = [IO.File]::ReadAllText((Join-Path $f.Clone 'linux\compose.local.yaml'))
    Assert ($yaml -match '(?m)^  linux-01:$' -and $yaml -match '(?m)^  linux-02:$') 'compose.local.yaml does not describe both slots.'
}

Test-Case 'Without -Slot every compose slot is recreated, one service group at a time, and compose.local.yaml is written once' {
    $f = New-Fixture
    $run = Invoke-Script $f 'New-LinuxRunner.ps1'
    Assert ($run.ExitCode -eq 0) "New-LinuxRunner exited $($run.ExitCode): $($run.Output)"
    $ups = Get-Ups $f
    Assert ($ups.Count -eq 4) "Expected four compose up calls; got: $($ups -join ' | ')"
    foreach ($up in $ups) { Assert ($up -match ' up -d --no-deps --force-recreate linux-\d\d(-docker)?$') "Compose up without --no-deps and a single service: $up" }
    Assert ($run.Output -match 'pre-pool runner') 'The run does not say it left the pre-pool runner alone.'
    $stamp = (Get-Item (Join-Path $f.Clone 'linux\compose.local.yaml')).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1200
    $null = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
    Assert ((Get-Item (Join-Path $f.Clone 'linux\compose.local.yaml')).LastWriteTimeUtc -eq $stamp) 'An unchanged compose.local.yaml was rewritten.'
}

Test-Case 'A slot that is not a compose slot is refused by -Slot, and nothing is touched' {
    $f = New-Fixture
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-07')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'linux-07 is not a compose slot') "Exit $($run.ExitCode): $($run.Output)"
    Assert (-not (Get-Ups $f).Count -and -not (Get-Builds $f).Count) 'Docker was asked to do something for an unknown slot.'
}

Test-Case 'A failed compose up leaves the runner in maintenance and says so' {
    $f = New-Fixture
    $state = Get-DockerState $f; $state | Add-Member -Force -NotePropertyName failUp -NotePropertyValue $true; Set-DockerState $f $state
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'sidecar did not start; the runner stays in maintenance') "Exit $($run.ExitCode): $($run.Output)"
    Assert (Test-Path (Join-Path $f.Clone 'linux\runner-02\maintenance.json')) 'The maintenance record was dropped after a failed start.'
    Assert ((Get-Ups $f).Count -eq 1) 'The runner was started after its sidecar failed.'
    Assert (@(Get-CustomLabels $f 'subzerodev.runner.linux.testhost.02').Count -eq 0) 'The labels were restored although nothing started.'
}

Test-Case 'Each of Dockerfile, entrypoint.sh, healthcheck.sh, the runner archive, .dockerignore and a build argument triggers a rebuild; nothing else does' {
    $f = New-Fixture
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 0) "First run exited $($run.ExitCode): $($run.Output)"
    $builds = @(Get-Builds $f)
    Assert ($builds.Count -eq 1) "An absent image was not built exactly once: $($builds -join ' | ')"
    Assert ($builds[0] -match '--pull' -and $builds[0] -match "--label dev\.subzerodev\.runners\.context=[0-9a-f]{64}" -and $builds[0] -match "--build-arg BASE_IMAGE=$([regex]::Escape($baseImage))" -and $builds[0] -match '--build-arg RUNNER_VERSION=2\.338\.0' -and $builds[0] -match '--build-arg RUNNER_SHA256=[0-9a-f]{64}') "The build is missing its label or build arguments: $($builds[0])"
    Clear-DockerLog $f
    $null = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
    Assert ((Get-Builds $f).Count -eq 0) 'An image whose context did not change was rebuilt.'
    # A file the build never receives:
    Set-Content -LiteralPath (Join-Path $f.Clone 'README.md') -Value 'not in the context'
    Clear-DockerLog $f
    $null = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
    Assert ((Get-Builds $f).Count -eq 0) 'A file .dockerignore keeps out triggered a rebuild.'
    foreach ($change in @(
            @{ Name = 'Dockerfile'; Apply = { Add-Content -LiteralPath (Join-Path $f.Clone 'linux\Dockerfile') -Value '# changed' } }
            @{ Name = 'entrypoint.sh'; Apply = { Add-Content -LiteralPath (Join-Path $f.Clone 'linux\entrypoint.sh') -Value '# changed' } }
            @{ Name = 'healthcheck.sh'; Apply = { Add-Content -LiteralPath (Join-Path $f.Clone 'linux\healthcheck.sh') -Value '# changed' } }
            @{ Name = '.dockerignore'; Apply = { Add-Content -LiteralPath (Join-Path $f.Clone '.dockerignore') -Value '# changed' } }
            @{ Name = 'the runner archive'; Apply = { $null = Set-Archive $f 'archive two' } }
            @{ Name = 'a build argument (linux.baseImage)'; Apply = {
                    $path = Join-Path $f.Clone 'runners.local.json'; $local = Get-Json $path
                    $local.linux.baseImage = 'ghcr.io/example/other@sha256:' + ('c' * 64); Set-Json $path $local } })) {
        & $change.Apply
        Clear-DockerLog $f
        $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02')
        Assert ($run.ExitCode -eq 0) "The run after changing $($change.Name) exited $($run.ExitCode): $($run.Output)"
        Assert ((Get-Builds $f).Count -eq 1) "Changing $($change.Name) did not trigger exactly one rebuild."
    }
    # -Build rebuilds even when nothing changed.
    Clear-DockerLog $f
    $null = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Slot', 'linux-02', '-Build')
    Assert ((Get-Builds $f).Count -eq 1) '-Build did not rebuild.'
}

Test-Case '-Update refuses a compose container before anything else; a plain container goes on to the updater gate' {
    $f = New-Fixture
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Update')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match '-Update refused: the runner container is managed by compose project') "Exit $($run.ExitCode): $($run.Output)"
    Assert (-not (Get-Ups $f).Count -and -not (Get-Builds $f).Count -and -not (Test-Path (Join-Path $f.Clone 'linux\compose.local.yaml'))) 'A refused -Update changed something.'
    # No inventory: the pre-pool runner. Its container carries a compose label -> refused; without one -> not refused here.
    Remove-Item -LiteralPath (Join-Path $f.State 'inventory.json')
    $state = Get-DockerState $f
    $state.containers | Add-Member -Force -NotePropertyName 'subzerodev-runner-linux' -NotePropertyValue ([pscustomobject]@{ running = $true; project = 'subzerodev-runners'; image = 'x'; hash = 'x' })
    Set-DockerState $f $state
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Update')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match '-Update refused') "A compose-labelled legacy container was not refused: $($run.Output)"
    $state = Get-DockerState $f; $state.containers.'subzerodev-runner-linux'.project = $null; Set-DockerState $f $state
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Update')
    Assert ($run.ExitCode -eq 1 -and $run.Output -notmatch '-Update refused' -and $run.Output -match 'updater') "A plain container should reach the updater gate, not the compose refusal: $($run.Output)"
    # Docker cannot be asked: refused (fails closed), not assumed plain.
    $state = Get-DockerState $f; $state.unavailable = $true; Set-DockerState $f $state
    $run = Invoke-Script $f 'New-LinuxRunner.ps1' @('-Update')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match '-Update refused: whether the runner container is managed by compose could not be determined') "Unknown was not treated as compose: $($run.Output)"
}

Test-Case 'Get-LinuxRunnerStatus.ps1 -Json: schema, per-slot rows and each kind of drift' {
    $f = New-Fixture
    $digest = Get-FileHash -LiteralPath (Join-Path $f.Clone 'downloads\actions-runner-linux-x64-2.338.0.tar.gz') -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLowerInvariant() }
    $expectedContext = Get-LinuxBuildContextHash $f.Clone ([ordered]@{ BASE_IMAGE = $baseImage; RUNNER_VERSION = '2.338.0'; RUNNER_SHA256 = $digest })
    $status = {
        $run = Invoke-Script $f 'Get-LinuxRunnerStatus.ps1' @('-Json')
        Assert ($run.ExitCode -eq 0) "Status exited $($run.ExitCode): $($run.Output)"
        $json = $run.Output | ConvertFrom-Json
        Assert ($json.schema -eq 'subzerodev.linux-runner-status' -and $json.version -eq 1 -and $json.hostId -eq 'testhost') "Schema header: $($run.Output)"
        $json
    }
    # Before any run: containers exist from an older image, no compose file, no image.
    Clear-DockerLog $f
    $report = & $status
    Assert (@($report.slots).Count -eq 2 -and ($report.slots.instanceId -join ',') -eq 'linux-01,linux-02') 'Status does not list slots 01 and 02.'
    $row = $report.slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.platform -eq 'linux' -and $row.legacy -eq $false -and $row.state -eq 'active' -and $row.runnerName -eq 'subzerodev.runner.linux.testhost.02' -and $row.container.name -eq 'subzerodev-runner-linux-02' -and $row.container.state -eq 'running') 'Row fields are wrong.'
    Assert ($row.drift.image.result -eq 'not-checked' -and $row.drift.image.detail -match 'not present') "A missing image was reported as: $($row.drift.image | ConvertTo-Json -Compress)"
    Assert ($row.drift.contextHash.result -eq 'not-checked') 'A missing image was not reported as not-checked.'
    Assert ($row.drift.composeFile.result -eq 'drift' -and $row.drift.composeConfigHash.result -eq 'not-checked') 'A missing compose file is not drift / the hash is not not-checked.'
    # Status changes nothing.
    $log = Get-DockerLog $f
    Assert (-not @($log | Where-Object { $_ -match '^(build|run|rm|stop|start|volume create|network create)|compose.* up ' }).Count) "Status changed something: $($log -join ' | ')"
    # After a real run everything is current: wire the fake so the recreated containers match.
    $null = Invoke-Script $f 'New-LinuxRunner.ps1'
    $report = & $status
    foreach ($slot in $report.slots) {
        foreach ($name in 'image', 'contextHash', 'composeFile', 'composeConfigHash') { Assert ($slot.drift.$name.result -eq 'ok') "$($slot.instanceId) $name is $($slot.drift.$name.result): $($slot.drift.$name.detail)" }
    }
    Assert (($report.slots[0].drift.contextHash.result -eq 'ok') -and ((Get-DockerState $f).image.context -ceq $expectedContext)) 'The image label is not the hash of the files on disk.'
    # Each kind of drift, on its own.
    $state = Get-DockerState $f; $state.containers.'subzerodev-runner-linux-02'.image = 'sha256:older'; Set-DockerState $f $state
    $row = (& $status).slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.drift.image.result -eq 'drift' -and $row.drift.composeConfigHash.result -eq 'ok') 'An older image under the container was not reported as image drift only.'
    $state = Get-DockerState $f; $state.containers.'subzerodev-runner-linux-02'.hash = 'stale'; Set-DockerState $f $state
    $row = (& $status).slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.drift.composeConfigHash.result -eq 'drift') 'An older compose definition was not reported as drift.'
    $state = Get-DockerState $f; $state.image.context = 'stale'; Set-DockerState $f $state
    $row = (& $status).slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.drift.contextHash.result -eq 'drift') 'A stale build context label was not reported as drift.'
    Add-Content -LiteralPath (Join-Path $f.Clone 'linux\compose.local.yaml') -Value '# edited'
    $row = (& $status).slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.drift.composeFile.result -eq 'drift') 'An edited compose file was not reported as drift.'
    # No archive: the context cannot be hashed, which is not-checked, never ok.
    Remove-Item -LiteralPath (Join-Path $f.Clone 'downloads\actions-runner-linux-x64-2.338.0.tar.gz')
    $row = (& $status).slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.drift.contextHash.result -eq 'not-checked' -and $row.drift.contextHash.detail -match 'not downloaded') 'A missing archive was not reported as not-checked.'
    # Docker unavailable: every container-dependent check is not-checked, and the run still succeeds.
    $state = Get-DockerState $f; $state.unavailable = $true; Set-DockerState $f $state
    $row = (& $status).slots | Where-Object instanceId -EQ 'linux-02'
    Assert ($row.container.state -eq 'unknown' -and $row.drift.image.result -eq 'not-checked' -and $row.drift.composeConfigHash.result -eq 'not-checked') 'An unreachable Docker was not reported as unknown / not-checked.'
}

Test-Case 'Get-LinuxRunnerStatus.ps1 without an inventory says so and lists no slots; without -Json it prints one line per slot' {
    $f = New-Fixture
    $text = Invoke-Script $f 'Get-LinuxRunnerStatus.ps1'
    Assert ($text.ExitCode -eq 0 -and $text.Output -match '(?m)^linux-01\s+active\s+container running' -and $text.Output -match '(?m)^linux-02\s+active') "Table output: $($text.Output)"
    Remove-Item -LiteralPath (Join-Path $f.State 'inventory.json')
    $run = Invoke-Script $f 'Get-LinuxRunnerStatus.ps1' @('-Json')
    $json = $run.Output | ConvertFrom-Json
    Assert ($run.ExitCode -eq 0 -and @($json.slots).Count -eq 0 -and $json.note -match 'no host inventory') "Without an inventory: $($run.Output)"
}

# --- result ---------------------------------------------------------------------------------------------------------------

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host "`n$($cases.Count - $failed.Count) of $($cases.Count) passed."
if ($failed.Count) { exit 1 }
$global:LASTEXITCODE = 0
