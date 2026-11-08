# Two native Windows runners on one host

## Automatic setup (recommended)

Open a **normal, non-elevated Windows PowerShell** window on a new x64 Windows desktop or VM:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1')))
```

No manual Git clone, prerequisite installation, terminal restart or registration token copying is needed.
The entry point supports Windows PowerShell 5.1. It uses Microsoft's `Microsoft.WinGet.Client` repair
route if WinGet is missing/broken, then silently installs missing PowerShell 7.2+, Git and GitHub CLI.
Windows may request package-installation elevation or an elevated WinGet repair; the GitHub setup,
runner registration and job processes continue under the original unelevated user. A new GitHub login
still requires your browser/device approval. Windows Server/Core, LocalSystem and an elevated runner
account are not supported by this interactive-user setup.
The bootstrap permits scripts/modules for its current PowerShell process only; it does not change
the machine's or user's persistent execution policy, and enforced organization policy still applies.

Defaults: two instances (`win01`, `win02`) in `%LOCALAPPDATA%\SubZeroDev\Runners`, registered to
`AbsoluteZeroDev`; each supervisor is started directly (nothing starts it again after a restart). The `_setup` directory is a reserved controller checkout;
each instance has its own clone. All clones use one resolved source commit for that run. Package
installs requiring a reboot stop setup and ask you to rerun after the reboot; setup never reboots for you.
Use a unique Windows computer name per host; setup refuses existing runner-name conflicts rather than
taking another machine's registration.

```powershell
# Existing C:\Actions layout / 128 GB host:
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1'))) -InstallRoot C:\Actions -ExtraLabels subzerodev-windows-large -SmokeRepository AbsoluteZeroDev/RunnerSmoke

# Another machine: four instances, automatic registration and supervisor checks:
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1'))) -Count 4
```

Rerunning skips working prerequisites, retains saved names/workspaces/custom labels, keeps the original
instance spelling, and only advances clean runner clones. Dirty checkouts, local commits that would be
discarded, another clone/instance identity, and a different saved GitHub target stop setup. For a custom
target, repeat the same `-GitHubUrl` on reruns. Lowering `-Count` never uninstalls additional instances.
No `--replace`, `git reset`, `git clean`, auto-logon or host reboot is performed.

Every instance also gets a `subzerodev-host-<computer>` label. Only the first two receive
`subzerodev-pair-<computer>` for the concurrent-job test; this works even on a host with more than two
runners. The `subzerodev-windows-large` label is opt-in so ordinary VMs do not receive large-host jobs.

## Registration scope and intended repositories

There is no personal-account-wide runner pool. Repository registrations serve exactly one repository,
including when several repositories have the same personal owner. Organization registrations share slots
only across repositories owned by that organization and permitted by its runner group. Labels select
eligible runners; they do not grant access across owners or repositories.

For the current `The-Running-Dev` repositories, use repository scope without transferring anything.
An organization pool is the reusable end state if the consuming repositories are deliberately moved to
`AbsoluteZeroDev`; setting `-GitHubUrl` alone does not move them. Transfers need a separate review of
package access, workflow owner checks, release identities, environments and trusted publishers.

`-TargetRepositories OWNER/REPO[,OWNER/REPO...]` declares the consumers when invoking the bootstrap
as a PowerShell scriptblock (pass an actual string array). Before configuring any instance, the worker
checks every declared target is in the requested scope, reads current repository ownership, refuses
archived/disabled/moved repositories, and verifies that Actions is enabled. Repository scope checks its
own repository even when this option is omitted. Organization scope without an explicit list warns that
repository eligibility has not been checked. API failures stop setup rather than implying eligibility.
The returned `ScopeValidatedRepositories` field records these checks separately from instance evidence.

These are **scope compatibility and Actions-enabled checks**, not proof of runner-group access or
workflow routing. Group selected-repository/public-repository/workflow policies, `runs-on` labels,
required toolchains and actual job results still need separate verification. The checks issue GETs only;
the surrounding setup still authenticates, configures runners and may provision prerequisites as before.
The current `gh` login flow requests classic `repo` for repository scope or `admin:org` for organization
scope. Fine-grained tokens need repository Administration write for repository registration, or organization
Self-hosted runners write for organization registration, plus repository Administration read on declared
consumers to inspect Actions policy. A smoke workflow additionally needs repository Contents/Workflows
write and Actions write; the interactive classic-token path requests `repo,workflow` for that operation.

### Current workflow fit (inspected 2026-11-07)

All seven inspected repositories are currently owned by `The-Running-Dev`. Existing workflows use
GitHub-hosted runners; installing self-hosted runners does not change their routing.

| Repository | Native Windows candidates | Keep elsewhere |
| --- | --- | --- |
| [FileManager](https://github.com/The-Running-Dev/SubZeroDev.FileManager/blob/main/.github/workflows/verify.yml) (private) | Ordinary `verify` job, after toolchain qualification | `msi-upgrade-acceptance.yml` explicitly requires disposable GitHub-hosted VMs |
| [WindowManager](https://github.com/The-Running-Dev/SubZeroDev.WindowManager/blob/main/.github/workflows/ci.yml) (public) | Windows CI/build legs after qualification | Ubuntu leg; review release toolchain/signing requirements separately |
| [Docker-BuildAgent](https://github.com/The-Running-Dev/Docker-BuildAgent/blob/main/.github/workflows/module-tests.yml) (public) | PowerShell module tests | Ubuntu image/build/docs/release jobs |
| [MemoryKit](https://github.com/The-Running-Dev/SubZeroDev.MemoryKit/blob/main/.github/workflows/ci.yml) (public) | Windows Node 22.18/24 matrix legs | Ubuntu/PostgreSQL service jobs; [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/) requires supported hosted runners |
| [GameEngine](https://github.com/The-Running-Dev/SubZeroDev.GameEngine/blob/main/.github/workflows/ci.yml) (public) | No native Windows job in the inspected workflows | Ubuntu jobs and reusable workflow callers; inspect called templates before rerouting |
| [Platform](https://github.com/The-Running-Dev/SubZeroDev.Platform/blob/main/.github/workflows/build.yml) (public) | No native Windows job in the inspected workflows | Ubuntu jobs and reusable workflow callers |
| [Runners](https://github.com/The-Running-Dev/SubZeroDev.Runners/blob/main/.github/workflows/windows-runner-validation.yml) (public) | Windows regression suite after qualification | Keep hosted validation while qualifying new infrastructure |

Public-repository pull requests can execute contributor code. Keep their hosted PR validation until a
separate trusted-job/isolation policy is in place; runner labels and separate clones are not a security
boundary. Also, ordinary Windows runners do not support Actions `services:` or job `container:` Linux
execution; Docker Desktop/BuildAgent steps do not transparently convert Ubuntu workflows.

### Executable setup without changing existing registrations

On a **fresh x64 Windows machine/VM**, in normal Windows PowerShell, the existing bootstrap can
install the FileManager pair. The guards below refuse an existing install directory or active
`win01`/`win02` instance mutex in this session; do not bypass them to repurpose an existing installation.
Stopped installations elsewhere must be inspected separately. `-SkipBuildAgent` installs native runners without the optional
Docker/tool/updater integration. This is a setup command to run deliberately, not a read-only check.

```powershell
$ErrorActionPreference = 'Stop'
if (Test-Path C:\Actions-FileManager) { throw 'Choose a fresh install directory; inspect existing installs first.' }
foreach ($id in 'win01', 'win02') {
    $existingMutex = $null
    if ([Threading.Mutex]::TryOpenExisting("Local\SubZeroDev.Runners.Windows.$id", [ref] $existingMutex)) {
        $existingMutex.Dispose()
        throw "Instance $id is already active in this session; inspect its installation first."
    }
}
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1'))) `
    -Count 2 -InstallRoot C:\Actions-FileManager `
    -GitHubUrl https://github.com/The-Running-Dev/SubZeroDev.FileManager `
    -ExtraLabels subzerodev-windows-large -SkipBuildAgent
```

Repeat the bootstrap invocation (without the fresh-install guards) only for a deliberate rerun of that
same install root and same `-GitHubUrl`. With this change available in the downloaded source, add
`-TargetRepositories @('The-Running-Dev/SubZeroDev.FileManager')`; repository scope validates it
automatically anyway. An organization setup instead supplies the actual **organization-owned** target list.

To add other repository pairs on that same host after the bootstrap has installed PowerShell/Git/gh,
use a **normal PowerShell 7** window and unique IDs. Multiple bootstrap roots would reuse `win01`/`win02`
instance IDs and mutexes; they are not independent. The lower-level installer supports distinct IDs:

```powershell
$ErrorActionPreference = 'Stop'
$plan = @(
    @{ Repository = 'The-Running-Dev/Docker-BuildAgent'; Ids = @('db01', 'db02') },
    @{ Repository = 'The-Running-Dev/SubZeroDev.MemoryKit'; Ids = @('mk01', 'mk02') }
)
$root = 'C:\Actions-Additional'
$source = (git -C C:\Actions-FileManager\_setup rev-parse HEAD)
if ($LASTEXITCODE) { throw 'Cannot resolve the bootstrap source commit.' }
# Validate the entire additive plan before installing anything. Existing clones or active instances are not adopted.
foreach ($item in $plan) {
    foreach ($id in $item.Ids) {
        if (Test-Path (Join-Path $root $id)) { throw "Clone already exists for $id; inspect it first." }
        $existingMutex = $null
        if ([Threading.Mutex]::TryOpenExisting("Local\SubZeroDev.Runners.Windows.$id", [ref] $existingMutex)) {
            $existingMutex.Dispose()
            throw "Instance $id is already active in this session; inspect it first."
        }
    }
}
New-Item -ItemType Directory -Path $root -Force | Out-Null
foreach ($item in $plan) {
    foreach ($id in $item.Ids) {
        $clone = Join-Path $root $id
        git clone https://github.com/The-Running-Dev/SubZeroDev.Runners.git $clone
        if ($LASTEXITCODE) { throw "Clone failed for $id." }
        git -C $clone checkout --detach $source
        if ($LASTEXITCODE) { throw "Source checkout failed for $id." }
        & "$clone\scripts\Install-WindowsRunner.ps1" -InstanceId $id `
            -GitHubUrl "https://github.com/$($item.Repository)" `
            -ExtraLabels subzerodev-windows-large
    }
}
```

This adds four registrations, for six total including the FileManager pair; it does not share the two
FileManager slots across repositories. It is an optional expansion, not something required to establish
the first pair. Each pair has independent binaries, SDK/cache/workspace, supervisor state and credentials to maintain;
all instances still compete for the same CPU/RAM/disk. A separate VM per repository can reuse the
one-command bootstrap because mutex namespaces are then separate (use unique computer names).

Setup and these guards do not query Task Scheduler. Legacy startup entries from an older version are
handled only by the installer's scoped migration, described below. The installer starts each supervisor
directly; after a restart, sign-out or supervisor failure, run `Manage-WindowsRunner.ps1 -Action Start`
in each clone. The supervisor retains its child-runner restart/backoff behavior.

For a qualified Windows job, the proposed routing change is:

```yaml
runs-on: [self-hosted, Windows, X64, subzerodev-windows-large]
```

All labels must match. Keep this out of disposable-MSI and hosted-publishing jobs. Matrix jobs need
an explicit Windows self-hosted label array while retaining their Linux entries. No workflow routing,
registration, group policy or repository ownership is changed by documenting this proposal.

The optional `-SmokeRepository` installs/dispatches a workflow and requires a private repository in
the same registration scope: repository-scoped FileManager runners can smoke only in FileManager,
not a different `RunnerSmoke` repository. A successful smoke checks both expected IDs and overlapping
job intervals; an online registration alone does not prove that. Do not run the smoke option on an
existing repository without authorizing that workflow write.

## BuildAgent provisioning and resuming setup

After the runners are verified, setup provisions the host-level [Docker-BuildAgent](https://github.com/The-Running-Dev/Docker-BuildAgent)
integration (`scripts\Install-BuildAgent.ps1`, once per host, shared by every instance). It reuses the PowerShell, Git and
`gh` the bootstrap just verified and adds, each step skipped when already satisfied:

1. Docker Desktop and its prerequisites (WinGet package, WSL 2), found by supported discovery (`buildAgent.docker.cli` if set,
   `docker.exe` on PATH, then Docker Desktop's registered install location).
2. A running Linux-container daemon: Docker Desktop is started unelevated, switched to Linux containers if it is on Windows
   containers, and waited for up to `buildAgent.docker.readyTimeoutSeconds`. The daemon type and readiness are verified
   with `docker info`, not assumed.
3. The net8.0 runtime (`buildAgent.dotnetRuntime`) that `BuildAgent.Tool` runs on, installed beside the tool. The instances'
   private SDK 10 is not used for this and no second host toolchain is installed.
4. The pinned `BuildAgent.Tool` (`buildAgent.tool.version`, 2.1.0) in `buildAgent.tool.directory`, shared by all instances.
5. The pinned image, pulled by digest (`buildAgent.image`), or a different digest set as `buildAgent.image` in
   `runners.local.json`; a tag or `:latest` is rejected by validation. Every build receives it as `BUILD_AGENT_IMAGE`.

Jobs and the BuildAgent steps run unelevated; only the WinGet package installs can show a UAC prompt. Exit codes of
`Setup-WindowsRunners.ps1`:

| Code | Meaning | What to do |
| --- | --- | --- |
| 0 | Everything finished | Nothing |
| 1 | The optional BuildAgent integration failed; the runners are set up and running | Read the printed step, fix, rerun the same command |
| 2 | Something needs you: restart Windows, sign out and in (for `docker-users`), accept Docker Desktop's first-run terms | Do what the printed list says, then rerun the same command |

The list is also saved in `<InstallRoot>\setup-state.json` (per step: state, time, message), so a rerun resumes after the
restart or sign-out instead of starting over, and an action that was waiting for a restart is dropped once Windows has
booted since. Setup never restarts Windows, never signs you out and never enables automatic sign-in. `-SkipBuildAgent`
skips the whole section. A failed or action-needed BuildAgent step does not stop the runners from being installed,
started or smoke-tested, and nothing about the Dashboard is a runtime dependency of any of this.

Check the result at any time with `scripts\Get-BuildAgentStatus.ps1` (one row each for tool, runtime, mapping, Docker
daemon, image, updater).

## Builds with BuildAgent

Workflow steps call `scripts\Invoke-BuildAgent.ps1 -Type <type>` (the clone's path is in `$env:SZR_SCRIPTS`), which runs
`build-agent build <type>` with the pinned tool, the pinned image and the Docker daemon from this host's validated
configuration. Only the named types BuildAgent already defines are accepted, and Windows executables are never run in the
Linux container.

`build-agent build` mounts one directory, the working directory, as `/workspace` plus the Docker socket. Hence:

- Each instance has its own workspace under `buildAgent.paths.workspaceRoot` (`...\workspaces\win01`, `...\win02`) with the
  build output (`artifacts`) and caches (`.cache`) inside it. Instances cannot see each other's files and two concurrent
  jobs on different instances do not interfere. Two jobs on the same instance wait for each other (one runner takes one
  job at a time anyway).
- **Caches are per instance, not shared.** The first build on each instance is cold. `buildAgent.cache.retentionDays`/`maxGB`
  bound them (applied by `Trim-RunnerLogs.ps1`, which `Start-Runners.ps1`, `Install-WindowsRunner.ps1` and, at most once a day, the Windows job-completed hook run; nothing schedules it). A shared host cache would need a second mount, which BuildAgent does not offer;
  `buildAgent.paths.extraMounts` is therefore required to be empty.
- Paths that cannot be mounted safely are refused before the build starts: UNC paths, folders inside Dropbox, folders that
  overlap a runner clone, paths containing a comma, an output directory outside the workspace.
- Anything that runs outside a job and needs the tool uses the full path from `buildAgent.tool.directory`, not PATH.

BuildAgent's exit status is passed through unchanged, with its documented meaning printed on failure.

## BuildAgent acceptance (real builds)

The 90 s sleep in the smoke workflow below proves only that two runners overlap. It builds nothing and says nothing about
BuildAgent. Acceptance of BuildAgent on these runners is a separate, manual, opt-in set of commands. None of it runs in CI
and none of it has been run for this change: the results below are what you collect on the host.

**1. Two concurrent real builds (GitHub).** `tests\windows-runner-buildagent.yml` is a `workflow_dispatch` template for a
private repository **inside the organization the runners are registered to** (an `AbsoluteZeroDev` repository, not the
personal account: organization runners cannot run workflows of the personal account). It builds the owner's known-working
project, `The-Running-Dev/GitHub-ActionTemplates` at `1c3b5f76554aca455cd4a284c4e473edd21c0d72`, `tests/fixtures/docusaurus`,
with `Invoke-BuildAgent.ps1 -Type node-template -AppDir docs` called through `$env:SZR_SCRIPTS`. Jobs:

| Job | Proves |
| --- | --- |
| `Build slot 1`, `Build slot 2` (one per runner instance, overlapping) | the host, the pinned tool version and the pinned image digest, a reachable Linux Docker daemon, a build that exits 0 and the expected `docs/build/index.html` in that instance's own workspace, stamped with the job's own marker; uploads the build log, the site and a per-job report |
| `Failure propagation` | a deliberately failing `node` build fails with a BuildAgent failure code (1 or 255; 0, 5 and 125 are rejected) |
| `Acceptance report` | judges the evidence of all three and uploads `buildagent-acceptance-report` |

```powershell
# From a clone on the host, with `gh` signed in and able to use the organization repository's Actions:
.\tests\Invoke-WindowsRunnerBuildAgentAcceptance.ps1 -Repository AbsoluteZeroDev/<private-repo> [-InstallWorkflow]
```

The script refuses a public repository, never overwrites a differing workflow, commits the workflow only with
`-InstallWorkflow`, dispatches with the `runners.json` pins, waits, then runs `Assert-WindowsRunnerBuildAgent.ps1`, which
rereads GitHub's own job records and artifacts and fails unless all of these hold:

- two successful build jobs on the two **distinct expected runner names** (distinct GitHub runner IDs) and their overlapping
  build steps;
- separate workspaces and caches per runner;
- the downloaded files, not the reports, prove the output. The checker is given each downloaded artifact folder
  (`buildagent-slot-N`) and requires the expected file there. The mapping is explicit: the workspace-relative artifact
  `docs/build/index.html` is uploaded as `site/index.html` (the site directory `docs/build` becomes `site/`; an artifact outside
  it, or with a `..`, `.`, empty or drive segment, has no uploaded path and fails). It recomputes the file's length and SHA-256
  and compares both with `report.json`; a missing, empty, modified or re-recorded file fails even when `report.json` says it
  exists;
- no cross-contamination, judged from the uploaded `site/` (every file), not from `report.json`: the job's own marker
  (`acceptance-marker-r<run>-a<attempt>-slot<N>`, of this run) is found, and no other marker is present. The report's own
  `markerFound` and `foreignMarkers` flags can only add failures;
- the tool version and image digest equal to the pins;
- the failing build failing the step, not passing.

The report (markdown) is printed and written to `-ReportDirectory`. A queued run usually means the repository is not in the
runners' runner group or a slot is busy; the script cancels the run when `-TimeoutMinutes` passes.

**2. Host acceptance (on the Windows/Docker Desktop host).**

```powershell
# Read-only checks plus real builds; the site must come out of each instance's own workspace:
.\tests\Invoke-WindowsHostAcceptance.ps1 -FixtureDirectory D:\fixture\docusaurus -Stage Readiness,Build,Adoption
# Unchanged setup rerun: registration files, runners.local.json and agent ids must not change:
.\tests\Invoke-WindowsHostAcceptance.ps1 -Stage Rerun -SetupCommand '<the exact Setup-WindowsRunners.ps1 command you ran>'
# Drain, timeout, force: start a long job in the clone first (the 90 s smoke or a build), then:
.\tests\Invoke-WindowsHostAcceptance.ps1 -Stage Drain -AllowDisruptive -DisruptiveClone C:\Actions\win01
.\tests\Invoke-WindowsHostAcceptance.ps1 -Stage Timeout -AllowDisruptive -DisruptiveClone C:\Actions\win01 -TimeoutMinutes 1
.\tests\Invoke-WindowsHostAcceptance.ps1 -Stage Force -AllowDisruptive -DisruptiveClone C:\Actions\win01
```

It runs the real scripts in each clone (`Get-BuildAgentStatus.ps1`, `Invoke-BuildAgent.ps1`, `Manage-WindowsRunner.ps1`,
and `Get-RunnerFacts.ps1` for the read-only registration, migration-record and legacy-entry facts) and writes a report that
lists every stage not selected as `NOT RUN (no evidence collected)`. `Drain`, `Timeout` and `Force` interrupt the named
clone's runner (and start it again), so they need `-AllowDisruptive` and refuse when no job is running.
`Drain` and `Force` start the runner again only after `Manage-WindowsRunner.ps1 -Action Stop` exited 0 **and** a fresh status
shows the supervisor stopped and the job idle. If the stop failed, left either running, or the status cannot be read, the
stage fails, never calls `Start` (which would end the maintenance hold a failed stop keeps), and still writes the report.
`Timeout` accepts exit 1 only for the genuine drain-timeout outcome ("A job was still running after N minutes. Nothing was
stopped; the runner takes jobs again (labels restored, maintenance cleared)") and verifies it from `Get-RunnerFacts.ps1`: the
supervisor and job still run, maintenance is cleared in the status and in the maintenance record, and GitHub lists the same
custom labels as before the stop. Any other exit 1 (for example a failed stop or a label restoration failure with maintenance
retained), or maintenance or admission that cannot be read, fails the stage, and `Start` is never called for it.
Not automated: provisioning a clean VM (run `Setup-WindowsRunners.ps1` there, then the stages above) and reboot or sign-out
resume (restart the VM mid-setup, sign in, rerun the same setup command; the pending-action state must resume it).

**3. Updater, separately.** Normal builds use published tooling (`BuildAgent.Tool` 2.1.0). `buildAgent.updater.version` stays
`null` and `New-LinuxRunner.ps1 -Update` keeps its explicit refusal until a published `BuildAgent.Tool` contains
Docker-BuildAgent PR #136; this repository does not duplicate the updater. After it is published, pin that exact version, then
validate on Docker Desktop: a healthy update, restoration when the replacement fails its health check, and recovery of an
interrupted update.

`Test-WindowsRunnerBuildAgentEvidence.ps1`, `Test-WindowsRunnerBuildAgentDispatch.ps1` and `Test-WindowsHostAcceptance.ps1`
test the checkers with synthetic evidence, a fake `gh` and fake clones (they accept a good run and reject injected defects).
They prove the checkers, not a host or a GitHub job.

## Operating a Windows instance

Run these from the instance's clone as the runner's user (`Manage-WindowsRunner.ps1 -Action ...`):

| Action | Does |
| --- | --- |
| `Status` | One line each for the supervisor (state, PID, restarts, last exit, next retry), the listener process, the running job, and the GitHub registration (online, busy, labels). Exits non-zero unless all are healthy; `-Json` for tools |
| `Start` | Ends maintenance and starts the supervisor (detached, hidden) if none runs, then waits up to `lifecycle.startTimeoutSeconds` (60) for fresh initialization status; prints `started (pid N)` or `already running (pid N)`, and exits 1 with the supervisor's exit code, init failure or timeout otherwise |
| `Stop` | Drains, then stops the supervisor and runner. Registration stays |
| `Restart` | `Stop`, then `Start` |
| `Maintenance` | Drains and stops, and keeps the supervisor idle (`maintenance.json`) until `Start` |

The supervisor restarts a runner that exits, with a growing delay when it exits quickly (30 s, doubling to 10 min), shows one
toast per failure streak and leaves the evidence in `supervisor.json` and the per-launch `_diag\Console_*-utc.log`.

There is no scheduled task, Run entry, service or watchdog: the supervisor runs only because `Start` (or `Start-Runners.ps1`,
or the installer) launched it. If it dies, or the PC restarts, it stays down: `Status` exits 1 while it is down without having
been stopped, the `Recovery` row says so, and the fix is `Manage-WindowsRunner.ps1 -Action Start`. Automatic supervisor
recovery is not promised. When a supervisor does start over a dead predecessor it keeps the one-per-instance mutex, does not
start `run.cmd` while `maintenance.json` exists, and waits (`waiting-for-orphan`) while a listener left by the dead supervisor
still runs, so one listener results. Each recovery is recorded in `supervisor.json` and shown by `Status`; a second in a row raises a toast, and after 3 in a row
without a long run between them, `repeatedDeaths` says so.

**Legacy tasks.** Earlier versions registered `Start Windows runner`, `Trim logs` and `Start runners` under
`\SubZeroDev.Runners\`, plus a `SubZeroDev.Runners` Run entry. `scripts\Remove-LegacyTasks.ps1` (also run by
`Install-WindowsRunner.ps1`) removes this clone's once and does nothing on a second run. A task is removed only when its name
carries this instance's suffix and its action names this clone's script; other instances' and clones' tasks are reported and
kept. Removing a task does not end a supervisor it started. The cleanup runs first in `Install-WindowsRunner.ps1`; an entry of this clone that cannot be inspected, removed or confirmed gone fails the install (nonzero, with the fix) before any registration change, and nothing is recorded. Only a verified result is recorded in `windows\legacy-migration.json`; host verification checks that record, not Task Scheduler. `LegacyCleanup.ps1` is the only code that loads the scheduler module.

`Start` is only reported successful once the supervisor of this clone has written fresh initialization status for its own pid. A live process, a stale `supervisor.pid` or `supervisor.json`, or an online listener left by an earlier supervisor is not enough; an early exit (with the exit code), an initialization failure and a timeout all fail `Start`, `Restart`, `Start-Runners.ps1`, the installer and host setup, and no second listener is started to satisfy the check.

A stop is reported successful only when nothing is left running. `Stop`, `Restart`, `Maintenance` and the registration changes
in `Install-WindowsRunner.ps1` end the supervisor with `taskkill` and then check the process table. A `taskkill` that fails, or
a supervisor, listener or worker still running afterwards, is a failed stop: exit 1, maintenance kept with the reason
(`stop-failed`), labels not restored and, for installation, the registration left unchanged.
A stop that fails (a process or container still running, or a state that cannot be read) exits 1, keeps maintenance with the
reason and does not put the labels back; the original labels are saved in `maintenance.json` before they are withdrawn, so an
interrupted drain can be undone by `Start`.

**Drain, deadline and force.** `Stop`, `Restart` and `Maintenance` first withdraw the runner's custom labels at GitHub so it is
offered no new job (admission control), then wait for the running job up to `lifecycle.drainTimeoutMinutes`
(`-TimeoutMinutes` overrides). Idle is confirmed twice, a local worker-process check and GitHub's busy flag 2 s apart, to cover
a job assigned while the first check ran. If the deadline passes the labels are restored, nothing is stopped and the command
exits non-zero naming the job that was kept. `-Force` stops immediately, cancels the job, and reports what that left behind
(the job's workspace and any containers it started are not cleaned until the next job-completed hook or the trim). If
withdrawing the labels fails, no stop is attempted. A workflow that targets only the default labels (`self-hosted`,
`Windows`, `X64`) is not held back by a drain.

## Evidence: what is checked where

| Scenario | Automated (CI fixtures and mocks) | Real host / real GitHub |
| --- | --- | --- |
| Config validation, merged local override | `Test-RunnerIntegration.ps1` | n/a |
| Fresh install (WinGet, Docker Desktop, tool, image) | Mocked in `Test-BuildAgentProvisioning.ps1` / `Test-WindowsRunnerHostSetup.ps1` | **Not collected**: needs a clean VM with Docker Desktop |
| Resumable setup after restart or sign-out | State file and pending-action logic in `Test-BuildAgentProvisioning.ps1` | **Not collected** |
| Two instances, distinct identity and workspace | `Test-WindowsRunnerInstances.ps1`, `Test-RunnerIntegration.ps1` | Setup with `-SmokeRepository` on the host |
| BuildAgent build | Invocation, mapping and refusal cases; no daemon. Acceptance checkers with synthetic evidence (`Test-WindowsRunnerBuildAgentEvidence.ps1`, `...Dispatch.ps1`, `Test-WindowsHostAcceptance.ps1`) | **Not collected**: runnable now (`Invoke-WindowsRunnerBuildAgentAcceptance.ps1`, `Invoke-WindowsHostAcceptance.ps1 -Stage Build`), but nothing has been run on Docker Desktop yet |
| Two concurrent real builds, no cross-contamination | Same checkers: 44 injected evidence defects rejected, including missing, modified, wrong-length and wrong-hash site files and another slot's marker in the site while `report.json` is clean | **Not collected**: needs the workflow in an AbsoluteZeroDev repository the runners are registered for |
| Concurrent jobs (overlap only; builds nothing) | Smoke evidence checker with synthetic results | `-SmokeRepository` run on the host |
| Supervisor takeover (one listener, maintenance holds, orphan wait) | `Test-LifecycleRecovery.ps1`: the real supervisor script in a child process against a stand-in listener | Same test; no Task Scheduler involved |
| Start confirms initialization, or fails | `Test-LifecycleRecovery.ps1`: early exit 23 (`Manage` Start and `Restart -Force`, `Start-Runners.ps1`: exit 1, Linux still started), alive-but-never-initializes within a 3 s bound (not killed, no second launch), stale `supervisor.json` of another pid, orphan listener alone | Real child processes only (a stub supervisor, a stand-in listener). Not a live runner |
| Start launches one supervisor; a second Start finds it | `Test-LifecycleRecovery.ps1`: fake `Start-Process` (arguments, working directory, hidden, maintenance ended first, already running); real `Manage-WindowsRunner.ps1 -Action Start` twice against the real supervisor | Same test: a real `Start` launched the replacement of a killed supervisor, the second `Start` reported its pid and started nothing |
| Dead supervisor is reported down and started by hand | `Test-LifecycleRecovery.ps1`: recovery bookkeeping, `Status` exit 1 and the `Recovery` row, real killed supervisor then explicit `Start` | Same test. Nothing restarts it, by design |
| Intentional stop stays stopped | `Test-LifecycleRecovery.ps1`: verified `taskkill` then process-table check; stop failure, supervisor, listener and worker still running | Real supervisor and listener stand-in in the same test |
| Failed stop keeps maintenance and exits 1 | `Test-LifecycleRecovery.ps1`: entry points in child processes with a fake `gh` and `docker` and a supervisor `taskkill` refuses to end (`Manage` Stop/Restart/Maintenance, `Stop-Runners.ps1`: exit 1) | **Not collected** against a real Docker daemon |
| Legacy startup entry that cannot be removed fails the install | `Test-LifecycleRecovery.ps1`, `Test-WindowsRunnerInstances.ps1` (throwaway installer, scheduler faked to fail before any registration change), `Test-WindowsRunnerHostSetup.ps1` (real worker process exits non-zero, no success output) | Real Task Scheduler only in the throwaway-folder case below; no live failure induced |
| No scheduler access outside the migration | `Test-LifecycleRecovery.ps1`: a fake `ScheduledTasks` module and `schtasks` shim record any call across setup evidence, Start, Stop, Status and a fresh install (with a negative control); source check | Same test. A fresh install does not probe the scheduler; another clone's same-name task is kept and does not block |
| Legacy tasks are removed once, only this clone's | `Test-LifecycleRecovery.ps1`: real Task Scheduler and registry, in a throwaway task folder and Run key per case (this clone's removed, another clone's and unlisted kept, second run does nothing, a supervisor the task started keeps running); `Test-WindowsRunnerInstances.ps1`: instance-suffixed names | Same tests; the real tasks of this host are fingerprinted before and after and unchanged |
| Task Scheduler restarts a killed or crashed supervisor (historical) | Simulated only, no longer applicable | **Collected, negative, and the reason the scheduler was dropped** (Windows 11 build 26200, 2026-11-07, throwaway tasks under `\SubZeroDev.Runners.Probe\`, restart 3-5 x 1 min): after `taskkill /T /F`, `Stop-Process`, `exit 0`, `exit 1`, `exit 3` and `throw`, the task launched once and was not restarted within 3 minutes. Kept as history; no scheduler infrastructure is built on it |
| Config change reaches the registration | Registration plan cases (name, target, work folder, labels) | **Not collected** against GitHub |
| Active-job drain, timeout and force | Mocked GitHub and processes in `Test-RunnerIntegration.ps1`; fake clones in `Test-WindowsHostAcceptance.ps1` (failed or unverified stops never reach `Start`; a real timeout is told apart from a failed stop) | **Not collected** with a live job (`Invoke-WindowsHostAcceptance.ps1 -Stage Drain,Timeout,Force -AllowDisruptive`) |
| Adoption of the existing installation, legacy-startup cleanup, unchanged setup rerun | `Test-WindowsHostAcceptance.ps1` (fake clones) | **Not collected** (`-Stage Adoption`, `-Stage Rerun`) |
| Linux updater success, unhealthy restore, refusal | Command construction and exit-code mapping only | **Blocked**: needs a published `BuildAgent.Tool` containing Docker-BuildAgent PR #136; `updater.version` stays `null` and the refusal stays until then |
| Cleanup, retries, Docker-unavailable diagnostics | Locked-file, protected-path, retention and free-disk cases | **Not collected** under real Docker Desktop failure |

Mocked and fixture results show the logic; they are not evidence that a host, a Docker daemon or a GitHub job behaved that way.

Add `-SmokeRepository AbsoluteZeroDev/RunnerSmoke` to automate the actual GitHub job smoke test.
Setup creates the named repository private if missing and installs the manual-only smoke workflow if
absent, then dispatches and checks two distinct expected identities plus overlapping execution. An
existing repository must be private, within the target organization (or be the exact repository-scoped
runner target), and permitted by the runner group. Setup does not widen runner-group access or overwrite
a differing workflow. OAuth credentials need `repo,workflow` access for workflow creation as well as
runner administration; initial interactive login requests these scopes when smoke is selected. Queued
or unfinished smoke runs time out after eight minutes and are cancelled when their ID is known.

For unattended provisioning, supply `GH_TOKEN` through the VM provisioner's environment or provision
a GitHub CLI login in that user profile, then pass `-NonInteractive`. Setup never saves that token to
its options file, prints it, or embeds it in command arguments. Existing supervisor code strips
`GH_TOKEN` and `GITHUB_TOKEN` from job environments. OS elevation/reboot requirements still apply;
preinstall machine-wide prerequisites if a provisioner cannot handle UAC.

If using a local checkout, run `.\Setup-WindowsRunners.ps1` with the same options. `-SourceRef` accepts
a repository branch/tag/commit (default `main`); it must contain the setup worker. Automated CI exercises
stock Windows PowerShell parsing and mocked package/authentication/host flows. It does not install
WinGet on a clean VM or prove registration/startup on the target machine. The script's host checks and,
if selected, the actual smoke run provide that evidence when you execute it there.

Microsoft's repair reference: <https://learn.microsoft.com/en-us/windows/package-manager/winget/troubleshooting>.
GitHub CLI environment authentication: <https://cli.github.com/manual/gh_help_environment>.

## Manual setup and inspection

These commands configure two independent clones on the 128 GB Windows machine. Run the installer as the normal Windows user whose account will execute jobs. Nothing starts the supervisors automatically: the installer starts them, and after a restart or a sign-out nothing runs until you run `Manage-WindowsRunner.ps1 -Action Start` in each clone. Both jobs share the host's CPU, memory, installed tools and ports; there are no per-runner resource limits.

## Prerequisites

Windows x64, internet access to GitHub, .NET and `ghcr.io`, Git, GitHub CLI and PowerShell 7.2 or later. The installer expects PowerShell at `C:\Program Files\PowerShell\7\pwsh.exe` and installs a private .NET 10 SDK for each runner. The runners themselves do not need Docker. The BuildAgent integration (below) needs Docker Desktop with WSL 2 and Linux containers; the automatic setup installs and verifies it, the manual route below does not.

From a Windows terminal, install missing prerequisites (approve package installer elevation if prompted):

```powershell
$ErrorActionPreference = 'Stop'
foreach ($package in 'Microsoft.PowerShell', 'Git.Git', 'GitHub.cli') {
    winget list --id $package --exact --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) { continue }
    winget install --id $package --exact --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE) { throw "Installing $package failed; inspect winget output." }
}
```

Close the terminal and open a **non-elevated PowerShell 7** window. Sign in with a GitHub account permitted to administer runners in `AbsoluteZeroDev`:

```powershell
gh auth login --hostname github.com --web --scopes admin:org
if ($LASTEXITCODE) { throw 'GitHub sign-in failed.' }
gh auth status --hostname github.com
# For an existing login missing the scope:
# gh auth refresh --hostname github.com --scopes admin:org
```

The default target is `https://github.com/AbsoluteZeroDev`. The organization runner group must allow the repositories that will use the runners. Organization runners do not serve repositories owned by the personal `The-Running-Dev` account. Use `-GitHubUrl https://github.com/OWNER/REPO` for repository-scoped registration instead, with appropriate repository administration access.

## Install two instances

After PR #5 is merged, run:

```powershell
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path C:\Actions -Force | Out-Null
foreach ($id in 'win01', 'win02') {
    $clone = Join-Path 'C:\Actions' $id
    if (-not (Test-Path -LiteralPath $clone)) {
        git clone --branch main https://github.com/The-Running-Dev/SubZeroDev.Runners.git $clone
        if ($LASTEXITCODE) { throw "Cloning $id failed." }
    } else {
        $origin = git -C $clone remote get-url origin
        if ($LASTEXITCODE -or $origin -ne 'https://github.com/The-Running-Dev/SubZeroDev.Runners.git') { throw "Unexpected clone at $clone." }
        $branch = git -C $clone branch --show-current
        if ($LASTEXITCODE -or $branch -ne 'main') { throw "$clone must be on main." }
        $dirty = git -C $clone status --porcelain
        if ($LASTEXITCODE -or $dirty) { throw "$clone has tracked or untracked changes; inspect before updating." }
        git -C $clone pull --ff-only origin main
        if ($LASTEXITCODE) { throw "Updating $id failed." }
    }
    & "$clone\tests\Test-WindowsRunnerInstances.ps1"
    & "$clone\scripts\Install-WindowsRunner.ps1" -InstanceId $id -ExtraLabels subzerodev-windows-large
}
```

The installer obtains short-lived GitHub registration tokens through `gh`; no token needs to be pasted. Do not use `-Replace` for these fresh installs. A name already registered elsewhere must be investigated, rather than taken over automatically. Do not copy configured runner directories or reuse one clone for a different instance ID.

Expected identities (`<computer>` is lowercase `COMPUTERNAME`):

| Item | win01 | win02 |
| --- | --- | --- |
| Clone | `C:\Actions\win01` | `C:\Actions\win02` |
| Runner name | `subzerodev.runner.windows.<computer>.win01` | `subzerodev.runner.windows.<computer>.win02` |
| Default workspace | `%TEMP%\szr\win01` | `%TEMP%\szr\win02` |
| Mutex | `Local\SubZeroDev.Runners.Windows.win01` | `Local\SubZeroDev.Runners.Windows.win02` |
| Supervisor | `C:\Actions\win01\windows\supervisor.pid` | `C:\Actions\win02\windows\supervisor.pid` |

There are no scheduled tasks; any `Start Windows runner (...)` or `Trim logs (...)` task left by an earlier version is removed by the installer first (if one of this clone's cannot be removed, the install fails and says how to fix it). Both retain `subzerodev-windows` and add `subzerodev-windows-large`. Each clone has separate binaries, registration, SDK, NuGet cache, logs and PID file. Reruns retain saved identity, scope and labels when those arguments are omitted. Existing unnamed installations keep their original mutex name.

## Verify registration and supervisors on the host

```powershell
$ErrorActionPreference = 'Stop'
$local = @(foreach ($id in 'win01', 'win02') {
    $clone = Join-Path 'C:\Actions' $id
    $config = Get-Content -Raw "$clone\runners.local.json" | ConvertFrom-Json
    $registration = Get-Content -Raw "$clone\windows\.runner" | ConvertFrom-Json
    $supervisor = Join-Path $clone 'scripts\Run-WindowsRunner.ps1'
    if (-not (Test-Path -LiteralPath "$clone\windows\legacy-migration.json")) { throw "The legacy startup migration of $id is not recorded; run $clone\scripts\Remove-LegacyTasks.ps1." }
    $supervisorPid = [int](Get-Content "$clone\windows\supervisor.pid")
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$supervisorPid"
    if (-not $process -or $process.CommandLine -notlike "*$supervisor*") { throw "Supervisor not running for $id." }
    if ($config.windows.instanceId -ne $id -or $registration.agentName -ne $config.windows.name) { throw "Wrong registration for $id." }
    [pscustomobject]@{ Instance = $id; Name = $registration.agentName; AgentId = $registration.agentId; Workspace = [Environment]::ExpandEnvironmentVariables($config.windows.workFolder); SupervisorPid = $supervisorPid }
})
$local | Format-Table -AutoSize
foreach ($field in 'Name', 'AgentId', 'Workspace', 'SupervisorPid') {
    if (@($local.$field | Select-Object -Unique).Count -ne 2) { throw "Instances share $field." }
}
$json = gh api orgs/AbsoluteZeroDev/actions/runners --paginate --slurp
if ($LASTEXITCODE) { throw 'Cannot read organization runner registrations.' }
$remote = @((($json | ConvertFrom-Json).runners) | Where-Object { $_.name -in $local.Name })
if ($remote.Count -ne 2) { throw 'Expected both organization registrations.' }
foreach ($runner in $remote) {
    $here = $local | Where-Object Name -eq $runner.name
    if ($runner.id -ne $here.AgentId -or $runner.status -ne 'online') { throw "Runner registration mismatch or offline: $($runner.name)" }
    foreach ($label in 'subzerodev-windows', 'subzerodev-windows-large') {
        if ($label -notin $runner.labels.name) { throw "Missing $label on $($runner.name)." }
    }
}
$remote | Select-Object id, name, status, busy | Format-Table
```

`Manage-WindowsRunner.ps1 -Action Status` in each clone gives the same view and exits 1 when the supervisor is down. After a restart or sign-out the supervisors are down until `Manage-WindowsRunner.ps1 -Action Start` is run; that is expected, not a fault. The CI harness mocks process launch and registration; it does not prove registration on this machine.

## Safe concurrent-job smoke test

This checks **concurrency only** (two runners, overlapping 90 s sleeps). It is not BuildAgent validation; see "BuildAgent acceptance (real builds)" above for that.

Use a private, trusted repository **inside AbsoluteZeroDev** which its runner group permits. Copy `tests\windows-runner-smoke.yml` into that repository as `.github\workflows\windows-runner-smoke.yml`, review it, then commit and push it to the default branch. It is manual-only, requests no token permissions, checks out no repository code, uses no secrets or fixed ports, and only logs runner identity/timestamps and sleeps for 90 seconds. Reserve `subzerodev-windows-large` for these two runners during the test.

For example, from a clean local checkout of that existing organization repository:

```powershell
$ErrorActionPreference = 'Stop'
$smokeRepo = gh repo view --json nameWithOwner --jq .nameWithOwner
if ($LASTEXITCODE -or $smokeRepo -notlike 'AbsoluteZeroDev/*') { throw 'Use an authorized AbsoluteZeroDev repository.' }
$branch = gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
if ($LASTEXITCODE) { throw 'Cannot read the default branch.' }
$current = git branch --show-current
if ($LASTEXITCODE -or $current -ne $branch) { throw 'Check out the smoke repository default branch first.' }
if (git status --porcelain) { throw 'Use a clean smoke repository checkout.' }
New-Item -ItemType Directory -Path .github\workflows -Force | Out-Null
$destination = '.github\workflows\windows-runner-smoke.yml'
if (Test-Path $destination) { throw 'Smoke workflow already exists; inspect it before replacing.' }
Copy-Item C:\Actions\win01\tests\windows-runner-smoke.yml $destination
git add -- $destination
git commit -m 'Add manual Windows runner concurrency smoke test'
if ($LASTEXITCODE) { throw 'Commit failed.' }
git push
if ($LASTEXITCODE) { throw 'Push failed.' }
gh workflow run windows-runner-smoke.yml --repo $smokeRepo --ref $branch -f "computer_name=$env:COMPUTERNAME"
if ($LASTEXITCODE) { throw 'Dispatch failed.' }
gh run list --repo $smokeRepo --workflow windows-runner-smoke.yml --event workflow_dispatch --limit 5
$runId = Read-Host 'Paste the run ID of this dispatch from the list above'
gh run watch $runId --repo $smokeRepo --exit-status
if ($LASTEXITCODE) { throw 'Smoke workflow failed; inspect its logs.' }
& C:\Actions\win01\tests\Assert-WindowsRunnerSmoke.ps1 -Repository $smokeRepo -RunId $runId
gh run view $runId --repo $smokeRepo --log
```

The evidence checker requires successful jobs on both expected names, distinct GitHub runner IDs, and overlapping hold-step intervals. Two successful sequential jobs fail this check. A queued job usually means a missing label, unavailable runner, runner-group repository access, or another job occupying a slot; do not conclude concurrency passed from the dispatch alone. Cancel a stuck run with `gh run cancel $runId --repo $smokeRepo`.

Only results collected from the target host and this actual workflow run establish that the two runners are online and execute jobs concurrently.

