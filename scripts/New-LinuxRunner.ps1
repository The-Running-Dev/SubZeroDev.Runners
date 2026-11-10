# (Re)creates the Linux runner container from runners.json. -Build rebuilds the image first, on linux.baseImage.
# The registration in linux\runner survives; only the container's own disposable filesystem is replaced.
# With linux.docker.mode 'sidecar' it also (re)creates the docker:dind container that jobs use as their Docker daemon;
# with 'dind' it removes that container and runs the runner privileged, with its own daemon.
#
# Two ways to create containers:
#   - The pre-pool runner (slot 01 of a host with no host inventory, or one the inventory marks legacy) is created with
#     `docker run`, exactly as before.
#   - A slot the host inventory records (not legacy) is created from the generated linux\compose.local.yaml with
#     `docker compose up -d --no-deps <services>`: only the named slot's containers are recreated, and the image is rebuilt
#     whenever its build context (Dockerfile, scripts, runner archive, .dockerignore, build arguments) changed. -Slot linux-NN
#     limits the run to one slot; without it every such slot is processed (the pre-pool runner is left alone: migrating it is
#     Manage-RunnerHost's job).
#
# The running container is replaced only after the runner has been drained: it stops taking jobs (its custom labels are
# withdrawn at GitHub), the script waits up to -TimeoutMinutes for a running job to finish, replaces the container, and
# restores the labels. A job that outlasts the deadline is not cancelled: nothing is replaced and the report says so.
# -Force replaces at once and cancels whatever is running. A runner the owner held (Hold) stays held.
#
# -Update hands the replacement of the runner container to BuildAgent's updater (`build-agent update`: lock, update record,
# health wait, restore of the original container). It is blocked until a published BuildAgent.Tool containing
# Docker-BuildAgent PR #136 is configured (buildAgent.updater.version), because without it the updater refuses this runner.
# The updater restores the container, not what the replacement wrote to the mounted /runner (binaries, credentials) or
# volumes; the runner's own mounted self-update is unchanged. The Docker sidecar has no health check, so it is always
# replaced by this script, never by the updater. -Update refuses a compose container: the updater would restore the old
# container and fight the compose file.
# Exit code 0: done. 1: blocked, kept (running job), or failed.
param([switch] $Build, [switch] $Update, [int] $TimeoutMinutes, [switch] $Force, [ValidatePattern('^linux-\d{2,}$')] [string] $Slot)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\RunnerArchive.ps1"
. "$PSScriptRoot\BuildAgent.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
. "$PSScriptRoot\Compose.ps1"
if (-not $PSBoundParameters.ContainsKey('TimeoutMinutes')) { $TimeoutMinutes = $Config.lifecycle.drainTimeoutMinutes }

# The image and the hash of what it was built from. $buildArguments are the Dockerfile's build arguments.
function Get-LinuxImageBuild {
    # One runner version for both platforms (runners.json runnerVersion), downloaded and checked against the SHA-256 GitHub
    # publishes; the Dockerfile checks it again and fails when either build argument is missing.
    $archive = Get-RunnerArchive -Platform linux-x64 -Version $Config.runnerVersion -DownloadDirectory (Join-Path $Root 'downloads') | Select-Object -Last 1
    $buildArguments = [ordered]@{ BASE_IMAGE = $Config.linux.baseImage; RUNNER_VERSION = $Config.runnerVersion; RUNNER_SHA256 = $archive.Sha256 }
    [pscustomobject]@{ Arguments = $buildArguments; Hash = (Get-LinuxBuildContextHash $Root $buildArguments) }
}

function Invoke-LinuxImageBuild($ImageBuild) {
    $arguments = @('build', '--pull', '--label', "$ContextHashLabel=$($ImageBuild.Hash)")
    foreach ($name in $ImageBuild.Arguments.Keys) { $arguments += @('--build-arg', "$name=$($ImageBuild.Arguments[$name])") }
    & $Docker @arguments -f (Join-Path $Root 'linux\Dockerfile') -t $Config.linux.image $Root
    if ($LASTEXITCODE) { throw 'Image build failed.' }
}

# Compose slots: the inventory's live, non-legacy Linux slots (optionally one). Anything else leaves the legacy path as it was.
function Get-ComposeSlots {
    $inventory = Read-HostInventory
    if ($inventory.State -ne 'readable') { return @() }
    $slots = @(Get-LinuxSlots $Config $inventory.Value | Where-Object { -not $_.Legacy -and -not $_.New })
    if ($Slot) { $slots = @($slots | Where-Object { $_.SlotId -eq $Slot }) }
    $slots
}

function Update-WorkFolder([string] $RunnerDirectory) {
    # The work folder lives in the registration, so keep it in step with runners.json.
    $registration = Join-Path $RunnerDirectory '.runner'
    if (Test-Path -LiteralPath $registration) {
        $settings = Get-Content -Raw $registration | ConvertFrom-Json
        if ($settings.workFolder -ne $Config.linux.workFolder) {
            $settings.workFolder = $Config.linux.workFolder
            $settings | ConvertTo-Json | Set-Content $registration
        }
    }
}

function Wait-SidecarReady([string] $Container) {
    # The daemon writes the client certificates on its first start; the runner needs them.
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $probe = Invoke-Docker @('exec', $Container, 'docker', 'version')
        if ($probe.ExitCode -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    $false
}

function Get-ContainerId([string] $Name) {
    $inspect = Invoke-Docker @('container', 'inspect', '--format', '{{.Id}}', $Name)
    if ($inspect.ExitCode -eq 0 -and $inspect.Output.Trim()) { $inspect.Output.Trim() }
}

# One compose slot: drain, recreate its containers (sidecar first, then the runner), record their IDs, end maintenance if
# this run started it. Returns $true when the slot is done; $false (reported) when it was kept or failed.
function Update-ComposeSlot($ComposeSlot, [string] $ComposeFile) {
    $directory = [IO.Path]::GetFullPath((Join-Path $Root $ComposeSlot.Directory))
    $stateFile = Join-Path $directory 'maintenance.json'
    $registered = Test-Path -LiteralPath (Join-Path $directory '.runner')
    $heldBefore = Get-HeldBefore $stateFile
    $container = $ComposeSlot.Container
    if ($registered) {
        $busy = { Invoke-Docker @('exec', $container, 'pgrep', '-f', 'Runner.Worker') | ForEach-Object { $_.ExitCode -eq 0 } }.GetNewClosure()
        $drain = Enter-RunnerMaintenance -StateFile $stateFile -RunnerDirectory $directory -IsBusy $busy -Reason 'replace' -TimeoutMinutes $TimeoutMinutes -Force:$Force
        if ($drain.Outcome -in 'timeout', 'failed') {
            $why = if ($drain.Outcome -eq 'failed') { @($drain.Failures) -join ' ' } else { $drain.Retained }
            [Console]::Error.WriteLine("$($ComposeSlot.SlotId) kept. $why")
            return $false
        }
    }
    Update-WorkFolder $directory
    Initialize-LinuxSlotResources $Config $ComposeSlot
    $sidecarName = $ComposeSlot.Services | Where-Object { $_ -like '*-docker' }
    if ($sidecarName) {
        $up = Invoke-LinuxCompose -File $ComposeFile -Verb up -Services @($sidecarName) -ForceRecreate
        if ($up.ExitCode -ne 0) { [Console]::Error.WriteLine("$($ComposeSlot.SlotId): the Docker sidecar did not start; the runner stays in maintenance. $($up.Output)"); return $false }
        if (-not (Wait-SidecarReady $ComposeSlot.DockerContainer)) { [Console]::Error.WriteLine("$($ComposeSlot.SlotId): the Docker sidecar did not become ready; the runner stays in maintenance."); return $false }
    }
    $up = Invoke-LinuxCompose -File $ComposeFile -Verb up -Services @($ComposeSlot.SlotId) -ForceRecreate
    if ($up.ExitCode -ne 0) { [Console]::Error.WriteLine("$($ComposeSlot.SlotId): the container did not start; the runner stays in maintenance. $($up.Output)"); return $false }
    # The containers this run created, by full ID, so a later step can tell them from anything that merely has the same name.
    $inventory = Read-HostInventory
    if ($inventory.State -eq 'readable') {
        $record = Get-InventorySlot $inventory.Value $ComposeSlot.SlotId
        if ($record) {
            $ids = @([ordered]@{ role = 'runner'; name = $container; id = (Get-ContainerId $container) })
            if ($ComposeSlot.DockerContainer) { $ids += [ordered]@{ role = 'docker'; name = $ComposeSlot.DockerContainer; id = (Get-ContainerId $ComposeSlot.DockerContainer) } }
            $record | Add-Member -Force -NotePropertyName containers -NotePropertyValue $ids
            $inventory.Value | Add-Member -Force -NotePropertyName generation -NotePropertyValue ([int]$inventory.Value.generation + 1)
            Write-HostInventory $inventory.Value
        }
    }
    if ($registered) {
        try { Complete-OperationMaintenance @{ name = 'recreate'; heldBefore = $heldBefore } $stateFile $directory | Out-Null }
        catch { [Console]::Error.WriteLine("$($ComposeSlot.SlotId) runs, but maintenance was not ended; the recovery record $stateFile is kept: $($_.Exception.Message)"); return $false }
    }
    $true
}

# The host lock for the whole run: waits for another runner operation on this host, or joins the one that started it.
Enter-HostLock -Kind 'New-LinuxRunner'
try {
    $linux = $Config.linux
    $sidecar = $linux.docker
    $composeSlots = @(Get-ComposeSlots)
    if ($Slot -and -not $composeSlots.Count) {
        [Console]::Error.WriteLine("$Slot is not a compose slot in the host inventory (the pre-pool runner and unknown slots are not handled by -Slot).")
        exit 1
    }
    if ($Update) {
        # Checked before anything else: a compose container is never handed to the updater.
        $label = if ($composeSlots.Count) { [pscustomobject]@{ State = 'present'; Project = $ComposeProject } } else { Get-ContainerComposeProject $linux.container }
        if ($label.State -eq 'unknown' -or $label.Project) {
            [Console]::Error.WriteLine("-Update refused: $(if ($label.Project) { "the runner container is managed by compose project '$($label.Project)'" } else { 'whether the runner container is managed by compose could not be determined' }). The updater would restore the old container and fight the compose file; replace it with this script (without -Update) or Manage-RunnerHost -Action Update.")
            exit 1
        }
        $settings = Get-BuildAgentSettings $Config
        $updater = Test-BuildAgentUpdater $settings
        if (-not $updater.Available) {
            [Console]::Error.WriteLine($updater.Reason + ' To replace the container now without the updater, run this script without -Update (it drains the runner first).')
            exit 1
        }
    }

    if ($composeSlots.Count) {
        # Compose path. The image is checked against its build context on every run, and rebuilt when it is missing or stale.
        $imageBuild = Get-LinuxImageBuild
        $current = Get-LinuxImageContextHash $linux.image
        if ($Build -or $current -ne $imageBuild.Hash) { Invoke-LinuxImageBuild $imageBuild }
        $allSlots = @(Get-LinuxSlots $Config (Read-HostInventory).Value | Where-Object { -not $_.Legacy -and -not $_.New })
        $composeFile = Get-LinuxComposeFilePath $Root
        $yaml = ConvertTo-LinuxComposeYaml $Config $allSlots $Root $PSScriptRoot
        if (-not (Test-Path -LiteralPath $composeFile) -or [IO.File]::ReadAllText($composeFile) -ne $yaml) { Write-FileAtomic $composeFile $yaml }
        $failed = @()
        foreach ($composeSlot in $composeSlots) { if (-not (Update-ComposeSlot $composeSlot $composeFile)) { $failed += $composeSlot.SlotId } }
        if (-not $Slot) { Write-Output 'The pre-pool runner (if any) was not touched; Manage-RunnerHost migrates it.' }
        if ($failed.Count) { [Console]::Error.WriteLine("Not done: $($failed -join ', ')."); exit 1 }
        return
    }

    if ($Build) {
        $imageBuild = Get-LinuxImageBuild
        Invoke-LinuxImageBuild $imageBuild
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
    Update-WorkFolder $LinuxRunner
    # Each removal is verified (the container is gone afterwards). A container that cannot be stopped or removed stops this script
    # with the runner still in maintenance; nothing after it (the sidecar, a new container) is touched.
    foreach ($name in @($linux.container) + @(if ($sidecar) { $sidecar.container })) {
        $removed = Remove-LinuxContainer $name
        if ($removed.Result -eq 'failed') {
            [Console]::Error.WriteLine("Container $name was not removed: $($removed.Detail) The runner stays in maintenance$(if ($registered) { " (record $maintenanceFile)" }); fix the cause and rerun this script.")
            exit 1
        }
    }
    # The same container specs the compose file is generated from, started the way they always were.
    $specs = Get-LinuxContainerSpecs $Config (Get-LegacyLinuxSlot $Config) $LinuxRunner $PSScriptRoot
    if ($DockerSidecar) {
        & $Docker network inspect $sidecar.network 2>$null | Out-Null
        if ($LASTEXITCODE) {
            & $Docker network create $sidecar.network | Out-Null
            if ($LASTEXITCODE) { throw "Network $($sidecar.network) could not be created." }
        }
        $sidecarArguments = ConvertTo-DockerRunArguments $specs.Sidecar
        & $Docker @sidecarArguments | Out-Null
        if ($LASTEXITCODE) { throw 'Docker sidecar start failed.' }
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            & $Docker exec $sidecar.container docker version 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
        if ($LASTEXITCODE) { throw "Docker sidecar did not become ready: $(& $Docker logs --tail 20 $sidecar.container 2>&1)" }
    }
    $runnerArguments = ConvertTo-DockerRunArguments $specs.Runner
    & $Docker @runnerArguments
    if ($LASTEXITCODE) {
        # The old container is gone; the runner stays out of rotation (maintenance kept) until a start succeeds.
        [Console]::Error.WriteLine('Container start failed. The runner stays in maintenance (labels withdrawn); fix the cause and rerun this script.')
        exit 1
    }
    if ($registered) {
        try { Exit-RunnerMaintenance $maintenanceFile $LinuxRunner | Out-Null }
        catch { [Console]::Error.WriteLine("The container runs, but maintenance was not ended; the recovery record $maintenanceFile is kept: $($_.Exception.Message)"); exit 1 }
    }
} finally { Exit-HostLock }
