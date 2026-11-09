# SubZeroDev runners

Self-hosted GitHub Actions runners on one Windows PC with Docker Desktop, shared by SubZeroDev projects. GitHub
still owns triggers, logs, checks, secrets and artifacts; the jobs execute here.

| Runner | Where it runs | `runs-on` |
| --- | --- | --- |
| `subzerodev.runner.windows` | Native process under the signed-in user, kept alive by `scripts\Run-WindowsRunner.ps1` | `subzerodev-windows` or `[self-hosted, subzerodev, Windows]` |
| `subzerodev.runner.linux` | Docker container `subzerodev-runner-linux` on [Docker-BuildAgent](https://github.com/The-Running-Dev/Docker-BuildAgent) (Debian 12, .NET 8/9/10, Node 22, PowerShell, Docker CLI and Engine, GitVersion, NUKE) plus wasm-tools, CMake and Ninja | `subzerodev-linux` or `[self-hosted, subzerodev, Linux]` |

Names and labels come from `runners.json` (`windows.name`, `linux.name`, `github.labels`); the
GitHub URL they are registered to comes from `runners.local.json`, which git ignores:

```json
{ "github": { "url": "https://github.com/<owner>/<repo>" } }
```

Any other setting placed there overrides `runners.json` on this machine only (merged key by key, so a partial override
keeps every other value). Every host script, hook and the supervisor read the merged result through one loader
(`scripts\RunnerConfig.ps1`), which rejects an invalid file with every problem listed: floating image tags (`:latest`, tags
without a digest), a floating tool version, `buildAgent.paths.extraMounts` other than empty, an output directory outside the
workspace, a non-numeric `lifecycle`/`housekeeping` value. Each runner gets `github.labels` plus its own
(`windows.labels`, `linux.labels`) and GitHub's defaults (`self-hosted`, the OS, `X64`).

| Key | Controls |
| --- | --- |
| `runnerVersion` | The one Actions runner version for Windows and Linux. Archives are downloaded from the release and checked against its published SHA-256 (`scripts\RunnerArchive.ps1`); the Linux image build receives the same version and hash |
| `buildAgent` | The pinned `BuildAgent.Tool` (`tool.version`, installed once per host in `tool.directory`), the net8.0 runtime it runs on (`dotnetRuntime`), the image by digest (`image`, passed to every build as `BUILD_AGENT_IMAGE`), the Docker connection (`docker.host`, `null` = Docker Desktop's default), per-instance build workspaces (`paths`), cache retention (`cache`) and the optional updater (`updater.version`, see below) |
| `lifecycle` | Drain deadline, supervisor restart delay, backoff, the quick-exit threshold and `startTimeoutSeconds` (how long `Start` waits for the supervisor to initialize, default 60) |
| `logs`, `housekeeping` | Log age and size caps, cleanup retries, the free-disk warning level |

Each runner takes one job at a time, so one Windows and one Linux job can run together.
Neither needs inbound ports.

## One-command Windows setup

Add `-Repository OWNER/PRIVATE-REPO -Count 2` to provision and automatically verify BuildAgent and runner lifecycle behavior.
Registration defaults to that repository; an explicit organization `-GitHubUrl` can share an organization pool. The command
downloads the pinned fixture, installs acceptance workflows, runs builds and controlled lifecycle checks, and saves resumable
checkpoints. See [the setup guide](docs/windows-two-runners.md#automatic-setup-recommended). Reporting and telemetry remain
separate work.

On a new x64 Windows machine or VM, open a **normal Windows PowerShell window** and paste:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1')))
```

This repairs missing/broken WinGet, installs missing PowerShell 7/Git/GitHub CLI, refreshes PATH,
opens GitHub authorization if necessary, and installs **two** independent runners under
`%LOCALAPPDATA%\SubZeroDev\Runners`. It verifies local tasks, supervisor processes, private .NET 10 SDKs,
GitHub registration IDs, online state and labels before reporting success. Approve any Windows
package-installer elevation prompts and the first GitHub sign-in; the runners remain unelevated.

After the runners are verified it provisions the [Docker-BuildAgent](https://github.com/The-Running-Dev/Docker-BuildAgent)
integration once for the host: Docker Desktop (installed with WinGet if missing, switched to Linux containers, waited
until the daemon answers), the net8.0 runtime, the pinned `BuildAgent.Tool` and the pinned image. `-SkipBuildAgent`
leaves it out. Exit codes: **0** done (and, with `-Repository`, verification passed); **1** the BuildAgent part or the requested verification failed (the runners are still set up and running);
**2** you have to act first (restart Windows, sign out and in, finish Docker Desktop's first run, join `docker-users`).
The steps are printed and saved in `<InstallRoot>\setup-state.json`; do them and run the same command again, finished
steps are skipped. Setup never restarts Windows, signs you out or enables automatic sign-in.

For automatic real parallel-job validation too:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1'))) -SmokeRepository AbsoluteZeroDev/RunnerSmoke
```

The optional smoke repository is created **private** if missing, receives a manual-only validation
workflow if absent, and must be allowed by the organization runner group. Existing different workflows
are never overwritten. Setup dispatches the test, waits, and checks distinct runner IDs and overlapping
execution. Without this option it reports registration/startup verification only.

Use `-Count 4` for four instances, `-InstallRoot C:\Actions` to adopt the earlier layout,
`-ExtraLabels subzerodev-windows-large` only for the large host, or `-NonInteractive` with an already
provisioned `GH_TOKEN`/GitHub CLI login. Tokens are never accepted in command arguments or written to
setup options. See [the Windows runbook](docs/windows-two-runners.md) for details and limitations.

## Layout

| Path | Contents |
| --- | --- |
| `runners.json`, `runners.local.json` | Settings every script reads (the second is git-ignored and wins): GitHub labels and URL, runner names and folders, container, base image, image, cache volume, work folders (`windows.workFolder` may be absolute and use `%TEMP%`-style variables), Docker daemon for Linux jobs (`linux.docker`, see below), CPU/RAM limits, log retention |
| `scripts\` | Host scripts and the job-completed hooks (mounted read-only at `/runner-hooks` in the container) |
| `%LOCALAPPDATA%\SubZeroDev\BuildAgent\` | Host-level, shared by all instances: `tool\` (BuildAgent.Tool), `dotnet\` (net8.0 runtime), `workspaces\<instance>\` (one build workspace per instance, with its `artifacts` and `.cache` inside) |
| `<InstallRoot>\setup-state.json` | What the last setup run finished and what is waiting for you (restart, sign-out, Docker Desktop) |
| `linux\healthcheck.sh` | The Linux runner image's `HEALTHCHECK`: the runner listener is alive and, in `dind` mode, the daemon answers. What the updater judges a replacement by |
| `windows\` | Windows runner: registration, binaries, private .NET SDK (`_tool\dotnet`), NuGet cache, `_work` (unless `windows.workFolder` points elsewhere), `_diag` logs (runner, console and `Startup_*` logs), `supervisor.pid` |
| `linux\Dockerfile`, `linux\entrypoint.sh` | Linux image: `linux.baseImage` (Docker-BuildAgent pinned by digest; bump it in `runners.json`, then `New-LinuxRunner.ps1 -Build`) plus the Actions runner. Jobs run as root, like the base |
| `linux\runner\` | Linux runner, mounted at `/runner`: registration, binaries, `_diag` logs. Checkouts use `/tmp/runner-work` inside the container |
| Docker container `subzerodev-runner-linux-docker` | Sidecar mode only: the Linux jobs' Docker daemon (`linux.docker.image`: `docker:dind` pinned by digest), privileged, on network `subzerodev-runner-linux` as host `docker`. The runner reaches it over TLS (`DOCKER_HOST=tcp://docker:2376`); ports that jobs publish are on `docker`, not `localhost` (`TESTCONTAINERS_HOST_OVERRIDE` is set) |
| Docker volume `subzerodev-runner-linux-cache` | Mounted at `/cache`: the container's home folder and NuGet packages, kept across container and image rebuilds (`docker volume rm` it to start clean) |
| Docker volumes `subzerodev-runner-linux-docker`, `-docker-certs`, `-work` | Sidecar mode: the daemon's images and build cache; its TLS certificates (read-only in the runner); `/tmp/runner-work`, shared by both containers at the same path so bind mounts of a job's checkout work |
| Docker volume `subzerodev-runner-linux-dind` | Dind mode: the runner's own daemon's images and build cache, at `/var/lib/docker` (`linux.docker.dindVolume`) |
| `downloads\` | Actions runner packages for Windows and Linux |
| `dropbox-ignore.txt` | Paths kept local-only |

## Scripts

| Script | Does |
| --- | --- |
| `Start-Runners.ps1` | Reapplies ignore rules, trims logs, starts the Windows supervisor if `supervisor.pid` names none, starts Docker Desktop if needed, then the Docker sidecar (in sidecar mode) and the Linux container. Logs to `windows\_diag\Startup_*-utc.log`; on failure shows a toast that opens that log |
| `Stop-Runners.ps1 [-TimeoutMinutes] [-Force]` | Drains, then stops the Windows runner, the Linux container and the sidecar. Draining withdraws each runner's custom labels at GitHub (no new job is assigned), waits up to `lifecycle.drainTimeoutMinutes` (or `-TimeoutMinutes`) for the running job, restores the labels afterwards. A job that outlasts the deadline is **not** cancelled: that runner keeps running and the report names it (exit 1). `-Force` stops at once and cancels the running job. Registrations stay |
| `Manage-WindowsRunner.ps1 -Action Status\|Start\|Stop\|Restart\|Maintenance [-TimeoutMinutes] [-Force] [-Json]` | One Windows instance, from its clone (also for Windows-only installs). `Status` prints supervisor, listener, job and GitHub state and exits non-zero unless all are healthy. `Stop`/`Restart` drain like `Stop-Runners.ps1`. `Maintenance` drains and stops and keeps the supervisor idle (`maintenance.json`) until `Start` |
| `Register-Runners.ps1` | Drains and stops both runners, then for each decides from what is registered: nothing → register; matching → leave alone; changed name, target or work folder → reconfigure; a runner GitHub no longer has → register again. The runner's ID, labels (including labels added in the GitHub UI), credentials and workspace survive an unchanged rerun; a name registered by another machine is refused. Identity, target, workspace and labels are verified at GitHub before it reports success. Needs `gh` signed in as an admin |
| `Invoke-BuildAgent.ps1 -Type <type> [-Source] [-CopyOutputTo] [-Dry]` | What a workflow step calls to build with Docker-BuildAgent: `build-agent build <type>` (the types it defines) with the pinned tool and image, in this instance's own workspace. `-Dry` prints the invocation. See [BuildAgent builds](#buildagent-builds) |
| `Get-BuildAgentStatus.ps1 [-Json]` | One line each for tool, runtime, mapping, Docker daemon (Linux containers), image and updater; exit 0 when builds can run |
| `Install-BuildAgent.ps1` | Provisions or verifies the host-level pieces (runtime, tool, Docker daemon, image). Exit 0 ready, 1 failed, 2 you must act first. Run by setup; safe to run alone |
| `Remove-LegacyTasks.ps1` | One-time cleanup of what earlier versions registered with Windows: this clone's `\SubZeroDev.Runners\Start Windows runner`, `Trim logs`, `Start runners` tasks (instance suffix included) and the `SubZeroDev.Runners` Run entry. A task is removed only when its action names this clone's script; another instance's or clone's tasks are reported and kept. Removing a task does not stop a supervisor it started. It succeeds only after a second look finds the entries gone; an entry that cannot be inspected or removed is an error (exit 1, with the fix) and nothing is recorded. A success is recorded in `windows\legacy-migration.json`. This script and `LegacyCleanup.ps1` are the only code that talks to Task Scheduler |
| `Install-WindowsRunner.ps1 [-InstanceId] [-Name] [-ExtraLabels] [-GitHubUrl] [-WorkFolder] [-Replace]` | Sets up the Windows runner alone on another machine (no Docker Desktop, no Linux runner), from a clone outside Dropbox, as a non-elevated user: writes `runners.local.json`, downloads the runner and checks its published SHA-256, installs the private .NET 10 SDK, registers it under a per-machine name (default `subzerodev.runner.windows.<computer>`) with the shared labels plus `-ExtraLabels`, and starts the supervisor directly and waits until it reports that it initialized (no scheduled task: nothing starts it at sign-in or after a restart). Refuses a name already registered elsewhere unless `-Replace`. Runs the one-time legacy-task cleanup first, before any download, registration change or process stop; if an earlier version's startup entry of this clone cannot be removed or verified gone, the install fails with nothing changed (see below). On such a machine use `Manage-WindowsRunner.ps1 -Action Start\|Stop\|Status`; the scripts that also drive Docker do not apply there |
| `New-LinuxRunner.ps1 [-Build] [-Update] [-TimeoutMinutes] [-Force]` | Recreates the Docker sidecar (when `linux.docker.mode` is `sidecar`; removes it otherwise) and the container from `runners.json` (`-Build` rebuilds the image first, on `linux.baseImage`, with the verified runner archive) and keeps the registration's work folder in step. A running container is replaced only after the runner has been drained (same deadline and `-Force` semantics as above). `-Update` hands the container replacement to BuildAgent's updater; see [Linux updates](#linux-updates) |
| `Set-DropboxIgnored.ps1` | Marks everything matched by `dropbox-ignore.txt` with `com.dropbox.ignored`. Idempotent |
| `Trim-RunnerLogs.ps1` | Bounded housekeeping, each part independent: `_diag` files older than `logs.retentionDays` and beyond `logs.maxMB` (the newest Runner/Worker/Console log of each runner is kept), per-instance BuildAgent caches older than `buildAgent.cache.retentionDays` or beyond `buildAgent.cache.maxGB`, and a warning when a drive falls below `housekeeping.minFreeGB`. Never touches registration files or credentials; a locked file is retried a bounded number of times, then reported. Nothing schedules it: the Windows job-completed hook runs it when `windows\last-trim.txt` is more than 24 hours old, and `Start-Runners.ps1` and `Install-WindowsRunner.ps1` run it too |
| `Run-WindowsRunner.ps1` | The supervisor: one supervisor per named Windows instance (mutex; unnamed installations keep the original mutex), writes `supervisor.pid`, relaunches `run.cmd` after it exits with a delay that doubles for each quick exit in a row (`lifecycle.restartDelaySeconds` up to `backoffMaxSeconds`), records state, restart count, last exit code and next retry in `supervisor.json`, idles while `maintenance.json` exists, waits for a listener left by a dead supervisor instead of starting a second, records its own recoveries (a streak of deaths restarts when the previous one is more than 6 hours old), one `_diag\Console_*-utc.log` per launch, and a toast after `lifecycle.quickExitLimit` quick exits in a row. Exports `SZR_SCRIPTS` (the scripts folder) to jobs |
| `Show-Notification.ps1` | Windows toast (runs under Windows PowerShell 5.1, which has WinRT); used by the two above |
| `Clear-WindowsActionCache.ps1`, `Clear-LinuxWorkspace.sh` | Job-completed hooks: clear downloaded actions (and Linux checkouts) with a bounded number of retries (`housekeeping.retries`); on Linux also the job's leftover containers, networks and anonymous volumes. NuGet caches, images and build cache stay. They never touch registration or credential files |

```powershell
# From the repository folder
.\scripts\Start-Runners.ps1
.\scripts\Stop-Runners.ps1                     # drains first; add -Force to cancel a running job
.\scripts\Manage-WindowsRunner.ps1 -Action Status   # from an instance's clone
.\scripts\Get-BuildAgentStatus.ps1
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
docker logs --tail 40 subzerodev-runner-linux
```

### Draining and its limits

Stopping, restarting, maintenance and replacing the Linux container all drain first: the runner's custom labels are
withdrawn at GitHub so no new job is assigned, the script checks twice (local worker processes, then GitHub's busy flag,
2 s apart) that nothing is running, and only then stops. If a job is still running at the deadline the labels are
restored and nothing is stopped; the report lists what was kept. `-Force` skips the wait, cancels the job and reports the
state it left behind. A workflow that targets **only** GitHub's default labels (`self-hosted`, `Windows`/`Linux`, `X64`) is
not held back by a drain; the workflows for these runners use the `subzerodev-*` labels.

**A stop that fails is a failure.** After the stop the scripts check what is left (the Windows supervisor, listener and
worker processes; each container's state through `docker container inspect`). A stop command that returns an error, a
container or process that is still running, or a state that cannot be read (Docker or the process table unavailable) is
reported as `failed`, never as stopped: `Stop-Runners.ps1`, `Manage-WindowsRunner.ps1` and `Register-Runners.ps1` exit 1,
maintenance stays on with `phase: stop-failed` and the reason, the labels are **not** put back, and `Register-Runners.ps1`
does not touch the registration of a runner that did not stop. A container that is already stopped or absent is a
successful stop. End the maintenance deliberately with `Manage-WindowsRunner.ps1 -Action Start` (Windows) or by rerunning the
script once the cause is fixed.

**The labels are recorded before they are withdrawn.** `maintenance.json` (in each runner's directory, written atomically)
holds the runner's id, name, scope and its original custom labels, and a `phase` (`closing`, `draining`, `stop-failed`,
`held`). It is written before the first label is deleted and kept whenever the deletion or the check afterwards is uncertain,
so a script that was interrupted after the labels were withdrawn can restore them from the record. Ending maintenance
checks the record's runner id against the registration, restores any label that is missing (a repeat is harmless), confirms
at GitHub that all of them are back, and only then removes the file. If the identity does not match, or a label is still
missing, the record stays and the report says so.

**The Windows supervisor is started directly and nothing restarts it.** There is no scheduled task, Run entry, service or
watchdog. `Manage-WindowsRunner.ps1 -Action Start` (also `Start-Runners.ps1`, `Install-WindowsRunner.ps1` and the end of a
maintenance hold) launches `Run-WindowsRunner.ps1` as a detached, hidden `pwsh`, ends any maintenance hold first, and starts
nothing when the supervisor is already running (it prints `already running (pid N)`). `Start` reports success only after the supervisor of this clone has written fresh initialization status (`supervisor.json` for its own pid, written after this start, in a state past initialization: `running`, `restarting`, `backoff`, `maintenance` or `waiting-for-orphan`; `starting` and `stopped` do not count) within `lifecycle.startTimeoutSeconds`: a process that merely exists, a stale pid or status file, or an online listener left by an earlier supervisor does not count. A second `Start` that loses the single-instance mutex to a supervisor still starting up waits a few seconds for that supervisor's pid before it gives up. If the supervisor exits first (the message carries its exit code), reports an initialization failure, or does not initialize in time, `Start` fails (exit 1; `Restart`, `Start-Runners.ps1`, the installer and host setup fail the same way; `Start-Runners.ps1` starts the Windows runner first and, when that fails, still attempts the Linux containers before it reports the failure). A supervisor that is alive but did not initialize is left running, not killed. The supervisor is recognised by its
`supervisor.pid` and a command line ending in this clone's quoted script path. What the supervisor does is unchanged: it
relaunches `run.cmd` when the listener exits, with the doubling delay and quick-exit toast described above.

**If the supervisor itself dies, it stays down until you start it.** `Manage-WindowsRunner.ps1 -Action Status` reports it as
not running and exits 1 while `supervisor.json` says it did not stop on purpose; the `Recovery` row says so and names the
fix, `Manage-WindowsRunner.ps1 -Action Start`. A reboot ends it the same way. The next supervisor records that
it found its predecessor dead (`recoveries`, `consecutiveRecoveries`, `lastRecoveryNote`) and, after 3 in a row without a
long run in between, `repeatedDeaths` says so and that nothing restarts it automatically.

**Upgrading from the scheduled-task design.** Earlier versions registered `Start Windows runner`, `Trim logs` and
`Start runners` tasks under `\SubZeroDev.Runners\` and a `SubZeroDev.Runners` Run entry. `Remove-LegacyTasks.ps1` (also run by
`Install-WindowsRunner.ps1`, before anything else changes) removes this clone's, once and idempotently, and leaves any task whose
action names another clone's script. A clone that was never set up before is recorded as migrated without asking Task
Scheduler. If this clone's entry cannot be inspected, removed or confirmed gone, the install stops with a nonzero exit and the
fix (remove the task in Task Scheduler, or repair the service, then rerun) before any registration change, process stop or
download, and records nothing; host setup stops there too and reports no success. Removing a task does not stop a supervisor
it started; that one keeps running until you stop it. Setup verification requires the recorded migration
(`windows\legacy-migration.json`), not a Task Scheduler query.

**A stop is only reported successful when nothing is left running.** `Stop`, `Restart`, `Maintenance` and the registration
changes of `Install-WindowsRunner.ps1` end the supervisor with `taskkill`, then check the process table. A `taskkill` that
fails, or a supervisor, listener or worker still running afterwards, is a failed stop: exit 1, maintenance kept with the
reason (phase `stop-failed`), labels not restored, and a registration change refused. The mutex still allows one supervisor
per instance, a supervisor does not start `run.cmd` while `maintenance.json` exists, and it waits (state
`waiting-for-orphan`) while a listener of that instance left by a dead supervisor is still running, rather than registering a
second one.

### BuildAgent builds

Docker-BuildAgent owns the build tooling, the Docker daemon lifecycle and the container updater; this repository only
provisions it and calls it. A workflow step runs `Invoke-BuildAgent.ps1` from the instance's clone (`$env:SZR_SCRIPTS`),
which runs `build-agent build <type>` with the pinned tool, the digest-pinned image (`BUILD_AGENT_IMAGE`) and the
Docker Desktop daemon in Linux-container mode. `build-agent build` mounts only the working directory (as `/workspace`)
and the Docker socket, so:

- each instance builds in its own workspace (`buildAgent.paths.workspaceRoot\<instance>`), the checked-out source copied
  in, with the output (`artifacts`) and caches (`.cache`) inside it. Two instances never share a directory, and two jobs
  on one instance are serialised by a per-instance lock;
- there is **no cache shared between instances**. Each instance warms its own; `buildAgent.cache` prunes them by age and size;
- `buildAgent.paths.extraMounts` must stay empty, and a mapping that is a UNC path, inside a Dropbox folder, overlaps a
  runner clone, contains a comma, or puts the output outside the workspace is refused before anything runs;
- a Windows executable is never run inside the Linux container: only the build types BuildAgent defines (`docker`, `node`,
  `node-in-docker`, `node-template`, `forge`) are accepted.

Acceptance of real builds is separate from the 90 s concurrency smoke (which proves overlap only): `tests/windows-runner-buildagent.yml` runs two concurrent builds of a known-good project plus a failing build and uploads an acceptance report (`tests/Invoke-WindowsRunnerBuildAgentAcceptance.ps1`), and `tests/Invoke-WindowsHostAcceptance.ps1` checks the host (readiness, build, adoption, unchanged rerun, drain/timeout/force). The build checker re-reads the downloaded site files (expected file, length, SHA-256, own and foreign markers) instead of trusting `report.json`, and the disruptive host stages never restart a runner whose stop was not verified. Both are manual and opt-in; see [docs/windows-two-runners.md](docs/windows-two-runners.md#buildagent-acceptance-real-builds) for the commands and which evidence is still uncollected.

The build jobs run unelevated, as the runner's user. That user needs Docker Desktop's pipe: setup reports `docker-users`
membership (which needs a sign-out and sign-in) as an action rather than changing it silently.

### Linux updates

`New-LinuxRunner.ps1` recreates the container itself. `-Update` instead delegates to BuildAgent's updater
(`build-agent update`: locking, an update record, a wait for the replacement's own `HEALTHCHECK`, restore of the original
container). Only a `BuildAgent.Tool` containing Docker-BuildAgent PR #136 can update this container (2.1.0 refuses a
privileged container or one with CPU/memory limits), and that change has **no published artifact yet**, so
`buildAgent.updater.version` is `null` and `-Update` stops with that reason; `Get-BuildAgentStatus.ps1` shows the same. Set
the version only to an exact published release containing #136, never to `latest`; this repository does not duplicate the updater. After publication, validate a healthy update, restoration when the replacement fails its health check, and an interrupted update on Docker Desktop. Notes that hold once it is available:

- restore puts back the container, **not** what the replacement changed in the mounted `/runner` folder (runner binaries,
  registration, credentials) or in volumes. The runner's own mounted self-update still works as before and is outside
  the updater's rollback;
- the `docker:dind` sidecar has no health check, so it is never updater-managed and keeps being recreated by the script.

After editing `runners.json` or `runners.local.json`: `New-LinuxRunner.ps1` for anything under `linux`,
`Register-Runners.ps1` for `github` or a runner name; `logs` settings apply at the next run of `Trim-RunnerLogs.ps1`
(also run by `Start-Runners.ps1` and `Install-WindowsRunner.ps1`).

## Multiple Windows runners on one machine

For complete prerequisite, installation, supervisor verification and concurrent-job smoke commands,
see [the two-runner Windows runbook](docs/windows-two-runners.md).

Use a **separate clone outside Dropbox for each instance**. The Windows installer accepts
`-InstanceId`: it appends the ID to the default per-machine name and gives each instance
its own workspace and supervisor mutex. Each clone also keeps
its own registration, binaries, private SDK, NuGet cache and logs. Instance IDs must be unique on the host.

From a normal, non-elevated PowerShell 7 window on the target machine, with Git, GitHub CLI
and PowerShell 7 installed, sign in if needed:

```powershell
gh auth login --hostname github.com --web --scopes admin:org
$ErrorActionPreference = 'Stop'
foreach ($id in 'win01', 'win02') {
    $clone = Join-Path 'C:\Actions' $id
    if (-not (Test-Path -LiteralPath $clone)) {
        git clone https://github.com/The-Running-Dev/SubZeroDev.Runners.git $clone
        if ($LASTEXITCODE) { throw "Cloning $id failed." }
    }
    & "$clone\scripts\Install-WindowsRunner.ps1" -InstanceId $id -ExtraLabels subzerodev-windows-large
}
gh api orgs/AbsoluteZeroDev/actions/runners --paginate --jq '.runners[] | {name,status,busy}'
```

The default target is https://github.com/AbsoluteZeroDev; pass `-GitHubUrl` to use another
organization or repository. Existing clones must contain the updated installer.
Do not copy a configured runner folder or reuse a clone for a different instance ID.
Reruns retain the saved instance ID, runner name and workspace unless explicitly changed.

Default workspaces are `%TEMP%\szr\win01` and `%TEMP%\szr\win02`.
Custom absolute `-WorkFolder` values must differ. An earlier version registered
`Start Windows runner (win01)` and `Trim logs (win01)` under `\SubZeroDev.Runners\`; the installer removes
those of its own instance once, first (see `Remove-LegacyTasks.ps1`; a failure stops the install) and never another instance's.

Both retain `subzerodev-windows`, so existing eligible jobs can run concurrently, up to two.
Use `subzerodev-windows-large` to target only this machine. There are no per-runner CPU/RAM
limits; jobs share the host user, installed tools, ports and machine-wide state.
Two is a starting concurrency setting; available RAM alone does not determine capacity.

Nothing starts the runners automatically: no scheduled task, no Run entry, no service, no watchdog. After a restart, or
when `Status` shows the supervisor down, run `Manage-WindowsRunner.ps1 -Action Start` in each clone (it starts the
supervisor detached and hidden, and confirms it initialized). Nothing here enables automatic sign-in or restarts the PC. Use the Windows-only
installer/supervisor; the combined start/stop/register scripts also manage Linux and Docker.

## Using the runners from a repository

Use `runs-on: subzerodev-windows` or `subzerodev-linux` (or the label lists above). The single
labels also fit inputs that take one string, such as the `os` list and `utility-runs-on` of the
[GitHub-ActionTemplates](https://github.com/The-Running-Dev/GitHub-ActionTemplates) workflows:

```yaml
with:
  os: '["subzerodev-linux"]'
  utility-runs-on: subzerodev-linux
```

Keep fork pull requests off these machines and give jobs `permissions: {}` unless they need more.
Linux jobs can use `docker`, `docker buildx` and `docker compose`; see below for where the daemon runs.
The-Running-Dev is a user account, so a runner can only be registered to one repository at a
time. Sharing them across repositories needs an organization; see Later.

## Docker in Linux jobs

Job-container workflows such as ActionTemplates `docs.yml` need the runner installation
visible to the Docker daemon as well as the workspace. Sidecar mode shares `/runner`
read-only with that daemon so `/runner/externals` and self-update targets resolve.
Existing containers need recreation to acquire this mount. See the
[Linux documentation smoke runbook](docs/linux-docs-smoke.md) for the opt-in nested
container probe, eligible-consumer check and manual reusable-workflow acceptance.
On the registered host, `scripts/docs-smoke/Invoke-Smoke.ps1 -Action Prepare`
opens the verified consumer's workflow PR; after its merge, `-Action Run` probes,
dispatches, waits and downloads/verifies the site and exact runner evidence.

`linux.docker.mode` picks where the Linux jobs' Docker daemon runs. Switch it in `runners.local.json`
(`{ "linux": { "docker": { "mode": "dind" } } }`), then run `New-LinuxRunner.ps1`.

| Mode | Daemon | Jobs see |
| --- | --- | --- |
| `sidecar` | A separate privileged `docker:dind` container with its own CPU/RAM limits (`linux.docker.cpus`, `.memory`) | `DOCKER_HOST=tcp://docker:2376` over TLS; published ports on host `docker` |
| `dind` | Docker-BuildAgent's opt-in `dockerd` inside the runner container, which then runs privileged (`BUILD_AGENT_DOCKERD=1`). Starts before the runner and stops after it; its log is `/var/log/dockerd.log` | The default socket, `DOCKER_HOST` unset; published ports on `localhost`. The daemon shares the runner's CPU/RAM limits |

Images and build cache stay in each mode's own volume, so switching back and forth keeps both.

## Isolation

Jobs run code from the repositories that use these runners, with that repository's secrets.

- **Now.** Linux jobs run in the container: root inside it, with no host mounts beyond its own
  `/runner` folder, the hooks (read-only) and the cache volume, and the CPU and memory limits from
  `runners.json`. Their Docker daemon is privileged (the sidecar, or in `dind` mode the runner
  container itself), so a job can start a privileged container and from there take over the
  Docker Desktop VM, including the Windows drives that Docker Desktop shares into it. Treat Linux jobs as trusted, like Windows jobs. Windows jobs run as the signed-in host user and can reach
  everything that user can.
- **Next.** The Windows runner moves into a dedicated VM (see Later), which takes host files and
  the user's sign-ins out of reach.
- **Optional.** A third runner only for releases, with its own label (for example
  `subzerodev-release`) and only the release environments' jobs pointed at it, so signing keys
  and release tokens never share a machine with pull request builds.

## Later

- **Organization runners.** Move the private repositories into a free organization and set
  `github.url` to it; `Register-Runners.ps1` then registers organization runners, which the
  Default runner group offers to private repositories only. Steps, none automated:
  1. Create the organization (Free plan) in the GitHub web UI.
  2. Transfer the private repositories that should use the runners (Settings → Transfer).
     GitHub redirects the old URLs, including git remotes, until a repository of the same name
     is created under the old owner.
  3. Packages do not move. Container, npm and NuGet packages stay owned by The-Running-Dev, and
     a transfer drops their link to the repository, so `github.token` stops reading them. For
     private packages that the moved repositories restore: publish them from the organization
     as well, or give the consuming repositories a token that can read them.
  4. Recreate repository secrets and environments where a transfer did not keep them (check
     release environments and their secrets).
  5. Set `github.url` to `https://github.com/<organization>`, run `Register-Runners.ps1`, and
     check the Default runner group's repository access.
  6. Update hard-coded owners: `The-Running-Dev/...` in workflows (release publishing targets
     included), NuGet sources and the docs.
- **Windows runner in a dedicated VM.** Same `windows\` folder and scripts, run inside a VM
  built for it; the supervisor is still started explicitly (`Manage-WindowsRunner.ps1 -Action Start`).
- **Linux stays a container.** Only the host it runs on may change.
- **Automatic start.** There is none by design (see the supervisor paragraph above); it is not planned here.
- **Dev Drive.** Still supported in Windows 11 (only the Dev Home app was retired). A ReFS
  volume with Defender performance mode, at least 50 GB, created from Settings or as a VHDX.
  Fits `windows\_work`, `windows\_nuget` and other caches; Microsoft advises keeping SDKs
  (here `windows\_tool\dotnet`) on the system drive. No gain for the Linux container, whose
  checkouts are already on a volume in Docker's VM. Works inside a VM too.

