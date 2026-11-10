# Runner pool plan

One host, N Linux slots and N Windows slots, set from the host's own settings. BuildAgent does the build work that
does not need Windows; Windows slots run what does. The implementation slices are in
[handoffs/runner-pool.md](../handoffs/runner-pool.md). This revision answers the red-team review of 9c2d603; every
fact below was checked against main (3a7eaf8) and GitHub on 2026-11-10.

## What exists today

| Piece | State |
| --- | --- |
| Linux runner | One container, `subzerodev-runner-linux`, built from `linux/Dockerfile` `FROM linux.baseImage` (the pinned BuildAgent image), so `build <type>` is on its PATH. `docker run --restart unless-stopped`. Registration in `linux/runner`, bind-mounted at `/runner`; maintenance record `linux/runner/maintenance.json`. `linux/entrypoint.sh` runs `exec /runner/run.sh` with no maintenance check. At GitHub: `subzerodev.runner.linux`, online. |
| Windows runners | `Setup-WindowsRunners.ps1 -Count` (`ValidateRange(1,16)`) makes `win01` … under `%LOCALAPPDATA%\SubZeroDev\Runners`, runner names `subzerodev.runner.windows.<computer>.win<nn>`, labels `subzerodev-host-<computer>` and `subzerodev-pair-<computer>` from `$env:COMPUTERNAME`. Each clone gets `-InstanceId`, `-GitHubUrl`, `-ExtraLabels` and nothing else; its `runners.local.json` is written by `Install-WindowsRunner.ps1`. Nothing starts a supervisor except an explicit Start (`WindowsRunnerSetup.ps1:134`). |
| Beast today | Still the single-clone layout: `subzerodev.runner.windows` is registered and **offline**. No `win<nn>` instances exist. |
| Maintenance | `Lifecycle.ps1`: an atomic record (`Set-MaintenanceState`), label withdrawal checked against the runner ID (`Close-RunnerAdmission`), idempotent restore. `Start-WindowsRunner` (line 382) calls `Exit-RunnerMaintenance` before it starts the supervisor, so every start ends maintenance. The supervisor itself (`Run-WindowsRunner.ps1:44`) idles while the record exists. |
| BuildAgent on Windows | `Invoke-BuildAgent.ps1` runs the BuildAgent launcher, which runs `docker run --rm` with the workspace, the socket and named variables, and **no `--cpus` or `--memory`**. Extra mounts are not supported. |
| GitHub | AbsoluteZeroDev is on the Free plan. One runner group, `Default`: visibility `all`, `allows_public_repositories: false`. One public repository exists (`SubZeroDev.Platform.Updater`). Runner groups are available on Free since 2024-10-17. |
| Telemetry | SubZeroDev.Dashboard `runner-telemetry-v1`: strict schema, at most 32 instances, reads `Manage-WindowsRunner.ps1 -Action Status -Json` and `Get-BuildAgentStatus.ps1 -Json`, keyed by `hostId`. Linux is not reported. |

Every workflow in the org targets `[self-hosted, subzerodev, Linux|Windows]` or the label `subzerodev-windows`. Any
slot of the right OS can take any of these jobs, so **the pool needs no workflow change in any repository.**

## Decided

1. Each host runs `linux.count` Linux slots and `windows.count` Windows slots. A new host set up with
   `Manage-RunnerHost.ps1 -Action Init` gets 2 and 2. An existing host keeps what it has until a count is set.
2. Settings (`runners.json` with `runners.local.json` over it) are the only desired state. The compose file and every
   clone's `runners.local.json` are generated from them.
3. A host inventory records what the manager owns; an operation journal makes every mutating operation resumable.
   Nothing is deleted that the inventory does not list and live state does not confirm.
4. Automatic start never ends maintenance. Only an explicit Resume or the existing explicit Start does.
5. Linux slots are compose services with `restart: always`. A compose command always names its services.
6. The existing Linux runner becomes slot 01 under a legacy mapping: same runner name, registration directory and
   volumes. Its registration is not touched.
7. BuildAgent is not changed (open decision D4 can revisit this). Linux slot limits are enforced; budgets for BuildAgent
   containers started by Windows slots are advisory.
8. Repositories move job by job, and moving a stage into BuildAgent is verified per project.

## Open owner decisions

| | Question | Options | Recommendation |
| --- | --- | --- | --- |
| D1 | Which repositories may use the runners? | (a) every private repository, through `Default` as it is today; (b) a group with an explicit repository allowlist | (a) while the owner is the only one with write access to the org's private repositories. Move to (b) when anyone else gets write access: dind slots are privileged, so a workflow can get root in the WSL VM. Public repositories are excluded either way. |
| D2 | Does an ordinary Apply deregister surplus slots? | (a) yes, the count is the desired state; (b) only with `-Retire`; without it, Apply does everything else and reports the surplus | (b). Deregistration is the one step that is not undone by running Apply again. A new registration gets a new runner ID. |
| D3 | Is starting after the owner's automatic sign-in enough? | (a) yes: a per-user Startup entry; (b) runners must run before sign-in | (a). Docker Desktop runs only in a signed-in session, so before sign-in neither the Linux slots nor BuildAgent on Windows can work. (b) means Docker Engine without Desktop, or a VM, which is a different plan. |
| D4 | Is "no BuildAgent change" a hard constraint? | (a) yes: Windows-side BuildAgent budgets stay advisory; (b) no: add `--cpus`/`--memory` to the launcher in Docker-BuildAgent | (a) for now. The WSL memory cap and one BuildAgent container per Windows slot bound the total. Take (b) if target-host acceptance shows a Windows-side build starving the Linux slots. |

Until D1 and D2 are answered, the slices implement the recommendation's mechanism behind a setting
(`github.runnerGroup`) or a switch (`-Retire`), so the answer changes configuration, not code.

## Ownership: host inventory and operation journal

Host state lives outside every clone, in `%LOCALAPPDATA%\SubZeroDev\Runners\host\`, beside the Windows instance clones:

| File | Content |
| --- | --- |
| `inventory.json` | `{ "schema": "subzerodev.runners.host-inventory", "version": 1, "hostId", "generation", "updatedUtc", "github": { "scope" }, "slots": [ … ] }` |
| `operation.json` | The one operation in progress, or absent: `{ "schema": "subzerodev.runners.host-operation", "version": 1, "id", "kind", "slotId", "startedUtc", "steps": [ { "name", "state": "pending\|done", "facts" } ] }` |

A slot entry records `slotId` (`linux-01`, `win01`), `platform`, `state` (`provisioning`, `active`, `retiring`,
`retired`), `runnerName`, `runnerId`, `scope` (`orgs/AbsoluteZeroDev`), `registrationDirectory`, and per platform:
Linux `container`, `composeProject`, `composeService`, `volumes`, `legacy`; Windows `installPath`, `workPath`,
`sourceCommit`, `generatedSettingsHash`. Both files are written with the `Set-MaintenanceState` pattern (temp file,
flush, move). A file that does not parse, or whose `schema`/`version` is unknown, is **unreadable**.

Rules:

- **One lock.** Every mutating command takes the named mutex `Local\SubZeroDev.Runners.Host` for its whole run: the
  host manager's Apply, Adopt, Resume and Hold, and the existing `New-LinuxRunner.ps1`, `Register-Runners.ps1`,
  `Stop-Runners.ps1`, `Start-Runners.ps1`, `Setup-WindowsRunners.ps1` and `Manage-WindowsRunner.ps1 -Action Stop|Start`
  when run directly. The manager sets `SZR_HOST_OPERATION=<operation id>` for the scripts it calls, which then join its
  lock instead of waiting on it. Plan and Status take no lock and change nothing.
- **Plan again under the lock.** Apply takes the lock, finishes any unfinished operation (below), reads settings,
  inventory, Docker and GitHub again, and recomputes the plan. `Plan -Json` prints a `planHash`; `Apply -ExpectPlan
  <hash>` stops without changes if the recomputed plan differs.
- **Ownership is recorded, never inferred.** A container is removed only if the inventory lists it and its labels
  `dev.subzerodev.runners.host=<hostId>` and `dev.subzerodev.runners.slot=<slotId>` match. A GitHub runner is removed
  only by the recorded `runnerId` in the recorded scope, and only when GitHub still reports that ID with the recorded
  name. A name or prefix never authorizes a deletion.
- **Unknown is not absent.** Docker or GitHub unreachable, a timeout, or an unexpected status is *unknown*: the
  operation stops at that step with the journal kept. Only GitHub's 404 for the recorded ID, or Docker's "no such
  container" for the recorded container, counts as gone.
- **Missing or unreadable inventory.** Apply, Resume, Hold and Prune refuse to run. `Manage-RunnerHost.ps1 -Action
  Adopt` builds the first inventory from what can be proven: a registration directory whose `.runner` `agentId`
  GitHub reports under that name, and the container this repository's scripts create for it. Adopt writes only the
  inventory. An unreadable inventory is never replaced unless Adopt is given `-ReplaceUnreadable`, and the old file is
  kept as `inventory.json.unreadable-<utc>`.
- **Prune** removes only `retired` slots' directories, volumes and clones, and a legacy container kept for rollback,
  each re-verified by recorded identity first.

### Retiring a slot

| Step | Done when | If interrupted after this step, the retry … |
| --- | --- | --- |
| 1 Admission withdrawn | maintenance record written, custom labels confirmed gone at GitHub; inventory `retiring` | continues the drain. The record keeps the listener from starting again (see Maintenance). |
| 2 Job drained | `Wait-RunnerIdle` returns idle | checks idle again (the labels are still withdrawn), then stops. A drain timeout aborts the operation: maintenance is ended, the slot stays `active`, and the journal records `retained`. |
| 3 Stopped | Windows: supervisor and listener processes gone; Linux: container stopped | stops again (idempotent). A Docker restart may start the container; its entrypoint sees the record and starts no listener. |
| 4 GitHub registration removed | DELETE of the recorded `runnerId` returned 204 or 404 | checks the recorded ID: 404 is done. It never registers again. |
| 5 Local registration cleared | `.runner`, `.credentials`, `.credentials_rsaparams` removed from the slot's directory (the directory stays) | skips it when the files are gone. |
| 6 Container removed (Linux) | `docker rm` of the recorded container, labels verified | skips it on "no such container"; stops on any other answer. |
| 7 Inventory committed | slot `retired`, `generation` + 1, the operation file deleted | nothing left to do. |

Generating the compose file excludes `retiring` and `retired` slots, so a retry never recreates them; a
`Setup-WindowsRunners.ps1` call never includes them. Adding a slot is journaled the same way: inventory `provisioning`
with its names, directory made, registered (the `runnerId` is read from `.runner` and recorded at once), service
created, online verified, inventory `active`. If the process dies after GitHub accepted the registration but before
`.runner` was written, the retry finds a runner with the slot's exact name and no recorded ID. It reports it and
registers with `--replace` under that name, the existing `Invoke-RunnerRegistration -Replace` path. It deletes nothing.

## Maintenance and automatic start

**Held** means the slot's maintenance record exists, whatever it contains. An unreadable record is held.
`Exit-RunnerMaintenance` already refuses to delete an unreadable record, so only the owner can clear one.

| Path | Ends maintenance? | Starts a listener? |
| --- | --- | --- |
| Docker Desktop starts, `restart: always` brings a Linux slot back | no | only if not held. The entrypoint checks `/runner/maintenance.json` before `exec /runner/run.sh`; while it exists, it waits and checks every 15 s, and the container stays up with no listener. |
| Sign-in: Startup entry → `Manage-RunnerHost.ps1 -Action AutoStart` | no | Windows: starts each `active` instance's supervisor with the new `Manage-WindowsRunner.ps1 -Action AutoStart`, which does not call `Exit-RunnerMaintenance`. The supervisor idles while held, as it does now. Linux: nothing; Docker does it. |
| Apply, any number of times | no | recreates a held Linux slot only when its configuration changed. The record is on the bind mount, so the new container waits too. Never starts a held Windows instance's listener. |
| `Manage-RunnerHost.ps1 -Action Resume -Slot <id>` | yes | restores the labels and deletes the record (`Exit-RunnerMaintenance`). Linux: the waiting entrypoint then runs `run.sh`, and Resume starts the container first if it is stopped. Windows: calls the existing explicit Start. Exactly one listener: one `exec` per container, and the per-instance supervisor mutex. |
| `Manage-WindowsRunner.ps1 -Action Start` (existing) | yes, as today | yes, unchanged |
| `Manage-RunnerHost.ps1 -Action Hold -Slot <id>` | — | drains, then stops; the record stays (`Stop-WindowsRunner -Hold`; the Linux equivalent stops the container and keeps the record). |

**No race with a hold.** A hold writes the record before it withdraws labels, drains, and stops the slot. A
listener that started just before the record appeared is busy or idle when the drain checks it, and is stopped at the
end of the hold. One that would start after the record appeared sees it and does not start. Either way, when Hold
returns, no listener runs and the record exists. The host lock keeps Resume and Hold of the same slot from overlapping.

Withdrawing labels removes only custom labels; `self-hosted`, the OS and the architecture stay. A job that targets
only default labels could still be offered to a held runner while its listener runs. That is why a held slot must
have no listener, not just no custom labels. Every org workflow today includes `subzerodev`.

`windows.startAtSignIn: true` creates the Startup entry; false removes it. This reverses the "explicit Start only"
rule only for a host that opts in, and only for starting a supervisor. A held instance stays held.

## Settings and how they reach each slot

Precedence: `runners.json` < host `runners.local.json` < generated per-clone file. The host manager writes each Windows
clone's `runners.local.json` in full from the host's settings and the instance's identity, with
`"generated": { "by": "Manage-RunnerHost", "hash": "<sha256>" }`. A clone file whose content no longer matches its
hash was edited by hand; Plan reports it as drift and Apply refuses to overwrite it without `-Force`.

| Setting | Resolved from | Reaches Windows instances as |
| --- | --- | --- |
| GitHub target | host `github.url` | `-GitHubUrl` (existing) and the generated file |
| `hostId` | host setting, default the lower-cased computer name | the generated file. `Setup-WindowsRunners.ps1` gains an optional `-HostId` used for `subzerodev-host-<hostId>` and `subzerodev-pair-<hostId>`. The default is the computer name, so existing labels do not change. |
| Runner names | Linux: `subzerodev.runner.linux.<hostId>.<nn>` (slot 01 legacy: `subzerodev.runner.linux`). Windows: `subzerodev.runner.windows.<hostId>.win<nn>`, as today when `hostId` is the computer name. | the generated file (`windows.name`) |
| Labels | `github.labels` + `linux.labels` / `windows.labels` + host labels | `-ExtraLabels` (existing) |
| BuildAgent image, tools, overrides | host `buildAgent.*` | the generated file. Every instance gets the same `buildAgent` block. |
| Install and work paths | `%LOCALAPPDATA%\SubZeroDev\Runners\win<nn>`, `windows.workFolder` | existing; recorded in the inventory |
| Identity and registration | the instance's `.runner` (`agentId`, `agentName`) | recorded in the inventory; checked against GitHub by ID |
| Source revision | the host manager clone's `HEAD`, which must have no uncommitted tracked changes | `SourceCommit` (existing `Sync-RunnerSetupInstance`); one commit for every clone, recorded per instance |

Counts:

- Settings accept `linux.count` and `windows.count` from 0 to 16. `Setup-WindowsRunners.ps1 -Count` stays 1–16.
  The manager calls it only with 1 or more. For 0 it retires every `active` Windows slot through the retire
  operation above.
- **Unset count** (an existing host after the upgrade): the side keeps what the inventory records. Nothing is added
  or retired. A Windows-only host therefore never gains Linux slots because a default exists.
- **New host:** `Manage-RunnerHost.ps1 -Action Init [-LinuxCount 2] [-WindowsCount 2]` writes the counts and `hostId`
  into `runners.local.json`, then Adopt and Plan. The default of 2 lives only here.

## Desired configuration, compose and updates

- **One owner.** Settings hold the image digests (`buildAgent.image`, `linux.baseImage`), `runnerVersion`, limits and
  Docker mode. `linux/compose.local.yaml` (git- and Dropbox-ignored) is generated from them and never edited. Its
  header records the input hash, and the inventory records the hash of the file last written.
- **Image rebuild.** The Linux image's build context is the repository root filtered by `.dockerignore`: the
  Dockerfile, `entrypoint.sh`, `healthcheck.sh` and the runner archive. The manager hashes `.dockerignore`, every file
  it admits and the build arguments (`BASE_IMAGE`, `RUNNER_VERSION`, `RUNNER_SHA256`). It stores the hash as the image
  label `dev.subzerodev.runners.context` and rebuilds when it differs. A test fails if `.dockerignore` admits a file
  the hash does not cover.
- **Changing a slot.** Only inside that slot's drain: hold (or wait for idle), then `docker compose -p
  subzerodev-runners up -d --no-deps --force-recreate <slot services>`, then end maintenance. The slot's services are
  the runner and, in sidecar mode, its sidecar. Compose is never run without service names. `down` is never used. A
  busy slot is never touched by another slot's change.
- **Updates.** A BuildAgent or runner update is a settings change: `Manage-RunnerHost.ps1 -Action Update` resolves the
  release digest and writes it into the host's `runners.local.json`, then runs Apply, which recreates slots one at a
  time under drain. Because the digest is in the desired state first, a later Apply converges to it instead of undoing
  it. `New-LinuxRunner.ps1 -Update` (`build-agent update`) stays for the legacy, pre-compose container. It refuses a
  container with a `com.docker.compose.project` label: the updater reproduces a container from `docker inspect`, and
  it has not been verified to keep compose's ownership labels.
- **Drift.** Plan and Status report, per slot: image other than the resolved digest; `com.docker.compose.config-hash`
  other than `docker compose config --hash <service>`; compose file edited (hash mismatch); a clone's settings edited;
  a clone on another commit. Apply fixes drift only through the same drained per-slot change.

## Legacy Linux runner → slot 01

The mapping keeps runner name `subzerodev.runner.linux`, directory `linux/runner`, and the existing volume names.
There is no volume copy and no re-registration. Only the container changes: from `docker run` to the compose service
`linux-01`, container `subzerodev-runner-linux-01`. The operation `migrate-legacy-linux` runs under the lock and the
journal:

| Step | Action | Failure here leaves |
| --- | --- | --- |
| 0 | Adopt has recorded the legacy slot: `.runner` `agentId` equals GitHub's ID for `subzerodev.runner.linux`, and the container `subzerodev-runner-linux` (and its sidecar in sidecar mode) exist | nothing changed |
| 1 | Hold: record written, labels withdrawn, job drained | the legacy runner held, still registered. Retry continues; Resume undoes it. |
| 2 | Stop the legacy container(s); `docker update --restart=no`; journal records the old policy `unless-stopped` | legacy stopped and unable to restart on its own; registration intact |
| 3 | Write compose with `linux-01` mapped to the legacy directory and volumes; `up -d --no-deps linux-01` | new container up and waiting (the record exists); no listener anywhere |
| 4 | Resume: labels restored, record deleted; the new entrypoint starts `run.sh` | listener in the new container with the same credentials |
| 5 | Verify GitHub reports the same `runnerId` online | — |
| 6 | Inventory: `linux-01` active, `legacy: true`; legacy container recorded `kept-for-rollback`; operation done | — |
| 7 | The legacy container is removed by the next `Apply -Prune`, by recorded container ID, never before step 6 | — |

The two containers never run a listener at the same time: the legacy one is stopped with `--restart=no` before the
new one exists. **Rollback** at any step before 6: `compose rm -s -f linux-01`, `docker update
--restart=unless-stopped` and start the legacy container, then Resume. The credentials were never changed, so the
legacy runner reconnects with the same ID.

Renaming slot 01 to the standard name later (`-RenameLegacy`) is a re-registration: drain, deregister the recorded
ID, register the new name, which gets a new ID. If it fails after the old ID was deregistered, saved credential files
do not bring the registration back, because GitHub has revoked it. The only recovery is to register again. The
journal keeps the slot `retiring` with the old ID recorded as removed, and a retry registers the new name. This is
optional and not part of the pool rollout.

The Windows side on beast is the older single-clone `subzerodev.runner.windows`. Moving it to `win<nn>` is what
`Setup-WindowsRunners.ps1` already does, including the recorded legacy-startup migration. Adopt records the single
clone. Apply runs Setup and retires the single-clone registration only after `win01` is online. That needs `-Retire`
if D2 is (b).

## Resources

| Workload | Limit | Kind |
| --- | --- | --- |
| Linux slot (dind): runner and its nested containers | `linux.cpus`, `linux.memory` on the slot container | enforced by Docker (cgroups in the WSL VM) |
| Linux slot (sidecar): job containers | the sidecar's `cpus`/`memory` | enforced |
| Everything in WSL: all Linux slots, Windows-launched BuildAgent containers | `.wslconfig` `memory`, `processors` | enforced as one shared total; nothing per workload |
| BuildAgent containers started by Windows slots | none; the launcher passes no limits | **advisory**: Plan counts an estimate per Windows slot (`buildAgent.estimate.memory`, default 8g). One container per slot at a time is enforced by the existing per-instance mutex. |
| Native Windows work (WPF tests, signing, packaging) | none | shares the RAM outside the WSL cap |

Disk is shared and grows:

- Docker Desktop's data disk does not shrink on its own.
- In dind mode each slot has its own image store, so images are pulled once per slot.
- Each slot has its own cache volume, and each Windows instance has its own workspace.

Plan reports `docker system df -v` per slot volume and the free space on the drive that holds Docker's data. With
`housekeeping.minFreeGB` set, Plan warns below it and Apply adds no slot below it. Removing a slot's images happens
only inside that slot's drain, with that slot's own daemon. Nothing here reaches into BuildAgent's cache layout.

## Runner group and access

Today all runners are in `Default`: all repositories, no public repositories. The manager **verifies, never
configures**. `github.runnerGroup` names the expected group (default `Default`), and optionally `repositories` for
an allowlist (D1 (b)). Plan and Status check:

- that the group exists;
- that `allows_public_repositories` is false;
- its visibility against the expected value, and, for an allowlist, the selected repositories against the list;
- that every slot's runner is in the group.

A mismatch is reported as drift with what to change at GitHub. Apply refuses to register into a group that allows
public repositories. Registration passes `--runnergroup` when the setting names a group other than `Default`.

## Telemetry and interfaces

- **Unchanged:** `Manage-WindowsRunner.ps1 -Action Status -Json` and `Get-BuildAgentStatus.ps1 -Json`, byte for
  byte; `Invoke-BuildAgent.ps1` parameters; `SZR_SCRIPTS`; the labels `subzerodev`, `subzerodev-linux`,
  `subzerodev-windows`; `Manage-WindowsRunner.ps1 -Action Start` (still ends maintenance).
- **Added:** `Manage-WindowsRunner.ps1 -Action AutoStart`; `Setup-WindowsRunners.ps1 -HostId`; `Manage-RunnerHost.ps1
  -Action Init|Adopt|Plan|Apply|Status|AutoStart|Resume|Hold|Update [-Slot] [-Retire] [-Prune] [-ExpectPlan]
  [-Json]`; `Get-LinuxRunnerStatus.ps1 -Json`. Every new JSON output carries `schema` and `version`.
- **Dashboard:** v1 stays as it is and keeps reporting Windows only. 16 + 16 slots fit v1's 32-instance limit, but v1
  has no platform field. Linux rows reach the Dashboard only through a v2 contract made in SubZeroDev.Dashboard; until
  then `Manage-RunnerHost.ps1 -Action Status -Json` is for local use.

## Rollout per job

The pool serves every job below without workflow changes. "Into BuildAgent" is optional, done per job, after that
project's cross-build has been verified (L1 and L2 below). One WPF project cross-building in HollowMoon proves
nothing for another project's tests or packaging.

| Repository | Workflow / job | Runs on | Stays native | BuildAgent candidate |
| --- | --- | --- | --- | --- |
| HollowMoon | `build.yml` `build` (PR #4) | Windows | WPF tests | game, Core tests, Windows-targeted test build (done in PR #4) |
| HollowMoon | `release.yml` | Windows | installer, signing, publish | game bundle, after `build.yml` passes L3 |
| HotCorners | `ci.yml` `dotnet` (ActionTemplates, `os: ["subzerodev-windows"]`) | Windows | all, until checked per project | non-UI tests, if they cross-build |
| HotCorners | `release.yml` (`environment: release`) | Windows | all | no |
| HotCorners | `claude-code-review.yml` | Linux | — | — |
| Cleaner | `ci.yml` `dotnet` (ActionTemplates, `os: ["subzerodev-windows"]`) | Windows | all, until checked per project | to be checked |
| Licensing | `ci.yml` `linux`, `package` | Linux | — | already Linux; needs Docker in the slot (image builds, acceptance topology), which dind provides |
| Licensing | `ci.yml` `windows` | Windows | all: registry machine identity, 64- and 32-bit processes | no |
| Licensing | `container.yml` `image` | set by ActionTemplates `container.yml` | — | check its `runs-on` before relying on the pool |
| Licensing | `claude-code-review.yml` | Linux | — | — |
| Media | `ci.yml` `web`, `linux` | Linux | — | already Linux |
| Media | `ci.yml` `dotnet`, `windows-package` | Windows | workloads install, tests, packaging | to be checked per project |
| Media | `release.yml` `release` (`environment: release`) | Windows | build, test, package, sign, publish | no |

Release jobs keep `environment: release` and its protection rules. The pool changes neither, and release jobs are
the last to change in any repository.

### Validation levels

| Level | Meaning | HollowMoon PR #4 today |
| --- | --- | --- |
| L1 local | the BuildAgent build passes against the pinned image on a workstation | passed |
| L2 workflow | the GitHub check passes on a self-hosted slot | **not run**: queued, because beast's Windows runner is offline |
| L3 target host | on beast, after Apply: scale, hold, reboot and concurrency acceptance (handoff) | not done |
| L4 generalization | each other repository reaches L1 and L2 for each job it moves | not started |

Mocked tests in this repository are L0 and are reported separately from all of these.

## Beast after a reboot

1. Windows signs in automatically (set by the owner; setup never configures it).
2. Docker Desktop starts; `restart: always` brings back every Linux slot. Held slots wait without a listener.
3. The Startup entry runs `AutoStart`, which waits for `docker info` up to `buildAgent.docker.readyTimeoutSeconds` and
   starts each active Windows supervisor. Held instances idle.
4. `.wslconfig` caps the WSL VM (owner-set, for example `memory=64GB`). Plan warns when the Linux slots' limits plus
   the Windows-side estimates exceed it, and never edits it.
