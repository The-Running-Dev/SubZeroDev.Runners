# (Re)creates the Linux runner container from runners.json. -Build rebuilds the image first, on linux.baseImage.
# The registration in linux\runner survives; only the container's own disposable filesystem is replaced.
# With linux.docker.mode 'sidecar' it also (re)creates the docker:dind container that jobs use as their Docker daemon;
# with 'dind' it removes that container and runs the runner privileged, with its own daemon.
param([switch] $Build)
. "$PSScriptRoot\Common.ps1"
$linux = $Config.linux
$sidecar = $linux.docker
if ($Build) {
    & $Docker build --pull --build-arg "BASE_IMAGE=$($linux.baseImage)" -f (Join-Path $Root 'linux\Dockerfile') -t $linux.image $Root
    if ($LASTEXITCODE) { throw 'Image build failed.' }
}
# The work folder lives in the registration, so keep it in step with runners.json.
$registration = Join-Path $LinuxRunner '.runner'
if (Test-Path -LiteralPath $registration) {
    $settings = Get-Content -Raw $registration | ConvertFrom-Json
    if ($settings.workFolder -ne $linux.workFolder) {
        $settings.workFolder = $linux.workFolder
        $settings | ConvertTo-Json | Set-Content $registration
    }
}
function Remove-Container([string] $Name) {
    & $Docker container inspect $Name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & $Docker stop --timeout 60 $Name | Out-Null
        & $Docker rm $Name | Out-Null
    }
}
Remove-Container $linux.container
if ($sidecar) { Remove-Container $sidecar.container }
$dockerArgs = @()
if ($DockerSidecar) {
    & $Docker network inspect $sidecar.network 2>$null | Out-Null
    if ($LASTEXITCODE) {
        & $Docker network create $sidecar.network | Out-Null
        if ($LASTEXITCODE) { throw "Network $($sidecar.network) could not be created." }
    }
    # The daemon is privileged; the runner is not. Images and build cache stay in dataVolume across jobs.
    # The work folder is shared at the same path, so bind mounts of a checkout resolve inside the daemon too.
    # dind mounts a tmpfs over /tmp unless /tmp is already a mount, which would hide the work folder; this one keeps it visible.
    & $Docker run -d --name $sidecar.container --restart unless-stopped --privileged --cpus $sidecar.cpus --memory $sidecar.memory `
        --network $sidecar.network --network-alias docker `
        -e DOCKER_TLS_CERTDIR=/certs `
        --tmpfs /tmp `
        --mount "type=volume,source=$($sidecar.dataVolume),target=/var/lib/docker" `
        --mount "type=volume,source=$($sidecar.certsVolume),target=/certs" `
        --mount "type=volume,source=$($sidecar.workVolume),target=$($linux.workFolder)" `
        $sidecar.image | Out-Null
    if ($LASTEXITCODE) { throw 'Docker sidecar start failed.' }
    # The daemon writes the client certificates on its first start; the runner needs them.
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        & $Docker exec $sidecar.container docker version 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 2
    }
    if ($LASTEXITCODE) { throw "Docker sidecar did not become ready: $(& $Docker logs --tail 20 $sidecar.container 2>&1)" }
    $dockerArgs = @(
        '--network', $sidecar.network
        '-e', 'DOCKER_HOST=tcp://docker:2376', '-e', 'DOCKER_TLS_VERIFY=1', '-e', 'DOCKER_CERT_PATH=/certs/client'
        # Ports that Testcontainers publishes live on the daemon's host, not on localhost.
        '-e', 'TESTCONTAINERS_HOST_OVERRIDE=docker'
        '--mount', "type=volume,source=$($sidecar.certsVolume),target=/certs,readonly"
        '--mount', "type=volume,source=$($sidecar.workVolume),target=$($linux.workFolder)"
    )
}
elseif ($sidecar -and $sidecar.mode -eq 'dind') {
    # The runner itself is privileged and runs dockerd; images and build cache stay in dindVolume across jobs.
    # Its daemon listens on the default socket, so DOCKER_HOST stays unset and published ports are on localhost.
    # The stop timeout leaves the entrypoint time to stop the daemon cleanly after the runner exits.
    $dockerArgs = @(
        '--privileged', '-e', 'BUILD_AGENT_DOCKERD=1', '--stop-timeout', '60'
        '--mount', "type=volume,source=$($sidecar.dindVolume),target=/var/lib/docker"
    )
}
& $Docker run -d --name $linux.container --restart unless-stopped --cpus $linux.cpus --memory $linux.memory `
    -e RUNNER_WORK_FOLDER=$($linux.workFolder) `
    -e ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/runner-hooks/Clear-LinuxWorkspace.sh `
    --mount "type=bind,source=$LinuxRunner,target=/runner" `
    --mount "type=volume,source=$($linux.cacheVolume),target=/cache" `
    --mount "type=bind,source=$PSScriptRoot,target=/runner-hooks,readonly" `
    @dockerArgs `
    $linux.image
if ($LASTEXITCODE) { throw 'Container start failed.' }
