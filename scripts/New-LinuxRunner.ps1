# (Re)creates the Linux runner container from runners.json. -Build rebuilds the image first, on linux.baseImage.
# The registration in linux\runner survives; only the container's own disposable filesystem is replaced.
# With linux.docker.mode 'sidecar' it also (re)creates the docker:dind container that jobs use as their Docker daemon;
# with 'dind' it removes that container and runs the runner privileged, with its own daemon.
#
# The running container is replaced only after the runner has been drained: it stops taking jobs (its custom labels are
# withdrawn at GitHub), the script waits up to -TimeoutMinutes for a running job to finish, replaces the container, and
# restores the labels. A job that outlasts the deadline is not cancelled: nothing is replaced and the report says so.
# -Force replaces at once and cancels whatever is running.
#
# -Update hands the replacement of the runner container to BuildAgent's updater (`build-agent update`: lock, update record,
# health wait, restore of the original container). It is blocked until a published BuildAgent.Tool containing
# Docker-BuildAgent PR #136 is configured (buildAgent.updater.version), because without it the updater refuses this runner.
# The updater restores the container, not what the replacement wrote to the mounted /runner (binaries, credentials) or
# volumes; the runner's own mounted self-update is unchanged. The Docker sidecar has no health check, so it is always
# replaced by this script, never by the updater.
# Exit code 0: done. 1: blocked, kept (running job), or failed.
param([switch] $Build, [switch] $Update, [int] $TimeoutMinutes, [switch] $Force)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\RunnerArchive.ps1"
. "$PSScriptRoot\BuildAgent.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes }
$linux = $Config.linux
$sidecar = $linux.docker
if ($Update) {
    $settings = Get-BuildAgentSettings $Config
    $updater = Test-BuildAgentUpdater $settings
    if (-not $updater.Available) {
        [Console]::Error.WriteLine($updater.Reason + ' To replace the container now without the updater, run this script without -Update (it drains the runner first).')
        exit 1
    }
}
if ($Build) {
    # One runner version for both platforms (runners.json runnerVersion), downloaded and checked against the SHA-256 GitHub
    # publishes; the Dockerfile checks it again and fails when either build argument is missing.
    $archive = Get-RunnerArchive -Platform linux-x64 -Version $Config.runnerVersion -DownloadDirectory (Join-Path $Root 'downloads') | Select-Object -Last 1
    & $Docker build --pull --build-arg "BASE_IMAGE=$($linux.baseImage)" --build-arg "RUNNER_VERSION=$($Config.runnerVersion)" --build-arg "RUNNER_SHA256=$($archive.Sha256)" -f (Join-Path $Root 'linux\Dockerfile') -t $linux.image $Root
    if ($LASTEXITCODE) { throw 'Image build failed.' }
}
$registered = Test-Path -LiteralPath (Join-Path $LinuxRunner '.runner')
$maintenanceFile = Get-LinuxMaintenanceFile
if ($registered) {
    $drain = Enter-RunnerMaintenance -StateFile $maintenanceFile -RunnerDirectory $LinuxRunner -IsBusy { Test-LinuxRunnerBusy } -Reason 'replace' -TimeoutMinutes $TimeoutMinutes -Force:$Force
    if ($drain.Outcome -in 'timeout', 'failed') {
        $built = if ($Build) { " The new image $($linux.image) is built; rerun this script to replace the container." }
        $why = if ($drain.Outcome -eq 'failed') { @($drain.Failures) -join ' ' } else { $drain.Retained }
        [Console]::Error.WriteLine("Runner container kept. $why$built")
        exit 1
    }
    if ($drain.Outcome -eq 'forced' -and (Test-LinuxRunnerBusy)) { Write-Warning 'A running job is cancelled by this replacement (-Force).' }
}
if ($Update) {
    # The updater replaces only the runner container, after the drain; the sidecar and its volumes are untouched.
    $invocation = Get-BuildAgentUpdateInvocation $settings $linux.container $linux.image $Config.buildAgent.updater.healthTimeout
    $timeoutSeconds = 600 + [int]($Config.buildAgent.updater.healthTimeout -replace '[^0-9]', '')
    $run = Invoke-BoundedNative $invocation.FilePath $invocation.Arguments $timeoutSeconds $invocation.Environment
    if ($run.Output) { Write-Output $run.Output }
    if ($registered) {
        try { Exit-RunnerMaintenance $maintenanceFile $LinuxRunner | Out-Null }
        catch { [Console]::Error.WriteLine("Maintenance not ended; the recovery record $maintenanceFile is kept: $($_.Exception.Message)"); exit 1 }
    }
    $meaning = Get-BuildAgentUpdateExitMeaning $run.ExitCode
    if ($run.ExitCode) { [Console]::Error.WriteLine($meaning); exit 1 }
    Write-Output $meaning
    exit 0
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
# Each removal is verified (the container is gone afterwards). A container that cannot be stopped or removed stops this script
# with the runner still in maintenance; nothing after it (the sidecar, a new container) is touched.
foreach ($name in @($linux.container) + @(if ($sidecar) { $sidecar.container })) {
    $removed = Remove-LinuxContainer $name
    if ($removed.Result -eq 'failed') {
        [Console]::Error.WriteLine("Container $name was not removed: $($removed.Detail) The runner stays in maintenance$(if ($registered) { " (record $maintenanceFile)" }); fix the cause and rerun this script.")
        exit 1
    }
}
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
    -e RUNNER_CLEANUP_RETRIES=$($Config.housekeeping.retries) `
    -e RUNNER_CLEANUP_DELAY=$($Config.housekeeping.retryDelaySeconds) `
    --mount "type=bind,source=$LinuxRunner,target=/runner" `
    --mount "type=volume,source=$($linux.cacheVolume),target=/cache" `
    --mount "type=bind,source=$PSScriptRoot,target=/runner-hooks,readonly" `
    @dockerArgs `
    $linux.image
if ($LASTEXITCODE) {
    # The old container is gone; the runner stays out of rotation (maintenance kept) until a start succeeds.
    [Console]::Error.WriteLine('Container start failed. The runner stays in maintenance (labels withdrawn); fix the cause and rerun this script.')
    exit 1
}
if ($registered) {
    try { Exit-RunnerMaintenance $maintenanceFile $LinuxRunner | Out-Null }
    catch { [Console]::Error.WriteLine("The container runs, but maintenance was not ended; the recovery record $maintenanceFile is kept: $($_.Exception.Message)"); exit 1 }
}
