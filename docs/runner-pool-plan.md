# Runner pool plan

One host, N Linux slots and N Windows slots, set from the host's own settings. BuildAgent does the build work that
does not need Windows; Windows slots run what does. The implementation slices are in
[handoffs/runner-pool.md](../handoffs/runner-pool.md). This revision answers the red-team review of 9c2d603, records
the owner's decisions D1–D4, and resolves four ownership and lifecycle contradictions (C1–C4) found against the code.
Every fact below was checked against main (3a7eaf8) and GitHub on 2026-11-10. Observed status and its cause are kept
apart: a cause that was not checked is labelled **not verified**.

## What exists today

| Piece | State |
| --- | --- |
| Linux runner | One container, `subzerodev-runner-linux`, built from `linux/Dockerfile` `FROM linux.baseImage` (the pinned BuildAgent image), so `build <type>` is on its PATH. `docker run --restart unless-stopped`. Registration in `linux/runner`, bind-mounted at `/runner`; maintenance record `linux/runner/maintenance.json`. `linux/entrypoint.sh` runs `exec /runner/run.sh` with no maintenance check. At GitHub: `subzerodev.runner.linux`, online. |
| Windows runners | `Setup-WindowsRunners.ps1 -Count` (`ValidateRange(1,16)`) makes `win01` … under `%LOCALAPPDATA%\SubZeroDev\Runners`, runner names `subzerodev.runner.windows.<computer>.win<nn>`, labels `subzerodev-host-<computer>` and `subzerodev-pair-<computer>` from `$env:COMPUTERNAME`. Each clone gets `-InstanceId`, `-GitHubUrl`, `-ExtraLabels` and nothing else; its `runners.local.json` is written by `Install-WindowsRunner.ps1`. Nothing starts a supervisor except an explicit Start (`WindowsRunnerSetup.ps1:134`). |
| Org runners (GitHub, 2026-11-10) | **Status:** `subzerodev.runner.linux` (id 9) online; `subzerodev.runner.windows` (id 8, labels `self-hosted, Windows, X64, subzerodev, subzerodev-windows`) **offline**. No `win<nn>` runner is registered. **Cause, not verified:** which machine holds id 8's registration, and why it is offline, were not checked on any host. The name has no `.win<nn>` suffix, the pattern of a single-clone `Install-WindowsRunner.ps1` install, but that is an inference from the name only. |
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
   Windows clone's `runners.host.json` are generated from them. Each file has one writer (C2).
3. A host inventory records what the manager owns; an operation journal makes every mutating operation resumable.
   Nothing is deleted that the inventory does not list and live state does not confirm.
4. Automatic start never ends maintenance. Only an explicit Resume or the existing explicit Start does, and an
   operation ends only maintenance it started (C4).
5. Linux slots are compose services with `restart: always`. A compose command always names its services.
6. The existing Linux runner becomes slot 01 under a legacy mapping: same runner name, registration directory and
   volumes. Its registration is not touched.
7. BuildAgent is not changed (D4). Linux slot limits are enforced; budgets for BuildAgent containers started by
   Windows slots are advisory.
8. Repositories move job by job, and moving a stage into BuildAgent is verified per project.

## Owner decisions (decided 2026-11-10)

| | Question | Decision | Why, and when to revisit |
| --- | --- | --- | --- |
| D1 | Which repositories may use the runners? | **(a)** every private repository, through `Default` as it is today. Public repositories excluded. | The owner is the only one with write access to the org's private repositories. Move to (b), a group with an explicit allowlist (`github.runnerGroup.repositories`), when anyone else gets write access: dind slots are privileged, so a workflow can get root in the WSL VM. |
| D2 | Does an ordinary Apply deregister surplus slots? | **(b)** only with `-Retire`. Without it, Apply does everything else, reports the surplus and exits 3. | Deregistration is the one step that running Apply again does not undo. A new registration gets a new runner ID. |
| D3 | Is starting after the owner's automatic sign-in enough? | **(a)** yes: a per-user Startup entry. | Docker Desktop runs only in a signed-in session, so before sign-in neither the Linux slots nor BuildAgent on Windows can work. Running before sign-in means Docker Engine without Desktop, or a VM: a different plan. |
| D4 | Is "no BuildAgent change" a hard constraint? | **(a)** yes, for now: Windows-side BuildAgent budgets stay advisory. | The WSL memory cap and one BuildAgent container per Windows slot bound the total. Revisit (add `--cpus`/`--memory` to the launcher in Docker-BuildAgent) if target-host acceptance shows a Windows-side build starving the Linux slots. |

The mechanisms stay behind a setting (`github.runnerGroup`) or a switch (`-Retire`), so a later change of D1 or D2 is
configuration, not code.

## Ownership and lifecycle contradictions, resolved before implementation

The revised plan still disagreed with the code in four places. Each is resolved here and in the sections below.

| | Contradiction | Evidence | Resolution |
| --- | --- | --- | --- |
| C1 | "Apply never starts a held Windows instance's listener" and "Apply runs Setup" cannot both hold. | `Setup-WindowsRunners.ps1` installs every `win01`…`win<Count>` (`WindowsRunnerSetup.ps1:296`). `Install-WindowsRunner.ps1:84` refuses a held instance and tells the operator to run Start, which ends the hold (`Lifecycle.ps1:384`). Setup's evidence then requires a running supervisor and an online runner (`WindowsRunnerSetup.ps1:139`, `:227`). It also re-installs a retired `win<nn>` whose number is ≤ Count. | The manager **never calls `Setup-WindowsRunners.ps1` or its loop**. It changes one instance at a time through the per-instance functions, and **never changes a held instance**: the change is reported `deferred: held` and made by the first Apply after Resume. When an inventory exists, `Setup-WindowsRunners.ps1` run directly refuses and names `Manage-RunnerHost.ps1`; without one it stays the bootstrap, unchanged. Slot numbers are never reused. |
| C2 | Two writers of a clone's `runners.local.json`. | `Install-WindowsRunner.ps1:41-75` reads, merges and rewrites it on every run; the plan had the manager write it in full with a hash, which every Install would break. | **One writer per file.** `runners.local.json` stays Install's (`github.url`, `windows.instanceId`, `windows.name`, `windows.labels`, `windows.workFolder`). The manager writes a new `runners.host.json` beside it, git-ignored. `Read-RunnerConfig` merges `runners.json` < `runners.host.json` < `runners.local.json`. No `runners.host.json` gives today's result. |
| C3 | Legacy containers cannot pass the label-based removal rule. | `New-LinuxRunner.ps1:99` and `:134` run `docker run` without `--label`, and labels cannot be added to an existing container. | **Container identity is the recorded full container ID plus the recorded name.** Containers the manager creates must also carry the host and slot labels. A legacy container, recorded by Adopt with its ID, is removed only when both ID and name still match. A name alone never authorizes removal. |
| C4 | An operation's drain and the owner's hold share one maintenance record. | Retire step 2's timeout "ends maintenance"; migration step 4 Resumes; Resume or Hold during an operation could delete or rewrite the record mid-operation. `Enter-RunnerMaintenance` merges into an existing record (`Lifecycle.ps1:205`), so the record alone cannot say who held it. | **An operation ends only maintenance it started.** Before `Enter-RunnerMaintenance` the journal records `heldBefore`. If the slot was held before, it stays held when the operation ends, succeeds or aborts. Resume and Hold refuse a slot with an unfinished operation and name it. The record format does not change. |

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
- **Ownership is recorded, never inferred (C3).** The inventory records each container's full ID (`docker inspect
  .Id`) and name. A container is removed only when Docker still reports the recorded ID with the recorded name. For a
  container the manager created, its labels `dev.subzerodev.runners.host=<hostId>` and
  `dev.subzerodev.runners.slot=<slotId>` must match as well; a legacy container made by `docker run` has no labels and
  is identified by ID and name alone. A GitHub runner is removed only by the recorded `runnerId` in the recorded scope,
  and only when GitHub still reports that ID with the recorded name. A name or prefix never authorizes a deletion.
- **An operation ends only the maintenance it started (C4).** Before an operation calls `Enter-RunnerMaintenance`, its
  journal step records `heldBefore` (the record existed). When the operation finishes or aborts, it calls
  `Exit-RunnerMaintenance` only if `heldBefore` is false; otherwise the slot stays held. Resume and Hold refuse a slot
  with an unfinished operation, name the operation, and say to finish it with Apply.
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
| 1 Admission withdrawn | `heldBefore` journaled; maintenance record written, custom labels confirmed gone at GitHub; inventory `retiring` | continues the drain. The record keeps the listener from starting again (see Maintenance). |
| 2 Job drained | `Wait-RunnerIdle` returns idle | checks idle again (the labels are still withdrawn), then stops. A drain timeout aborts the operation: the slot goes back to `active`, the journal records `retained`, and maintenance is ended only if `heldBefore` is false. A slot the owner held stays held. |
| 3 Stopped | Windows: supervisor and listener processes gone; Linux: container stopped | stops again (idempotent). A Docker restart may start the container; its entrypoint sees the record and starts no listener. |
| 4 GitHub registration removed | DELETE of the recorded `runnerId` returned 204 or 404 | checks the recorded ID: 404 is done. It never registers again. |
| 5 Local registration cleared | `.runner`, `.credentials`, `.credentials_rsaparams` removed from the slot's directory (the directory stays) | skips it when the files are gone. |
| 6 Container removed (Linux) | `docker rm` of the recorded container ID, after ID, name and labels are verified | skips it on "no such container"; stops on any other answer. |
| 7 Inventory committed | slot `retired`, `generation` + 1, the operation file deleted | nothing left to do. |

Generating the compose file excludes `retiring` and `retired` slots, so a retry never recreates them. The manager
never calls `Setup-WindowsRunners.ps1`, whose loop installs every number up to `-Count`; it installs only the instance
an operation names (C1). Slot numbers are never reused: a new slot takes the next number above the highest the
inventory has ever recorded. Adding a slot is journaled the same way: inventory `provisioning` with its names,
directory made, registered (the `runnerId` is read from `.runner` and recorded at once), service or instance created,
online verified, inventory `active`. If the process dies after GitHub accepted the registration but before
`.runner` was written, the retry finds a runner with the slot's exact name and no recorded ID. It reports it and
registers with `--replace` under that name, the existing `Invoke-RunnerRegistration -Replace` path. It deletes nothing.

## Maintenance and automatic start

**Held** means the slot's maintenance record exists, whatever it contains. An unreadable record is held.
`Exit-RunnerMaintenance` already refuses to delete an unreadable record, so only the owner can clear one.

| Path | Ends maintenance? | Starts a listener? |
| --- | --- | --- |
| Docker Desktop starts, `restart: always` brings a Linux slot back | no | only if not held. The entrypoint checks `/runner/maintenance.json` before `exec /runner/run.sh`; while it exists, it waits and checks every 15 s, and the container stays up with no listener. |
| Sign-in: Startup entry → `Manage-RunnerHost.ps1 -Action AutoStart` | no | Windows: starts each `active` instance's supervisor with the new `Manage-WindowsRunner.ps1 -Action AutoStart`, which does not call `Exit-RunnerMaintenance`. The supervisor idles while held, as it does now. Linux: nothing; Docker does it. |
| Apply, any number of times | no, unless it started that maintenance itself (C4) | recreates a held Linux slot only when its configuration changed. The record is on the bind mount, so the new container waits too. **Never touches a held Windows instance** (C1): no Sync, no Install, no Start. Its pending change is reported `deferred: held`. |
| `Manage-RunnerHost.ps1 -Action Resume -Slot <id>` | yes | refuses while an operation on that slot is unfinished (C4). Otherwise restores the labels and deletes the record (`Exit-RunnerMaintenance`). Linux: the waiting entrypoint then runs `run.sh`, and Resume starts the container first if it is stopped. Windows: calls the existing explicit Start. Exactly one listener: one `exec` per container, and the per-instance supervisor mutex. |
| `Manage-WindowsRunner.ps1 -Action Start` (existing) | yes, as today | yes, unchanged |
| `Manage-RunnerHost.ps1 -Action Hold -Slot <id>` | — | refuses while an operation on that slot is unfinished (C4). Otherwise drains, then stops; the record stays (`Stop-WindowsRunner -Hold`; the Linux equivalent stops the container and keeps the record). |

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

On the host: `runners.json` < host `runners.local.json`. In each Windows clone (C2), one writer per file:

| File in the clone | Writer | Keys |
| --- | --- | --- |
| `runners.json` | git (the recorded source commit) | shared defaults |
| `runners.host.json` (new, git- and Dropbox-ignored) | the host manager only, written in full | everything the host resolves for the instance: `hostId`, `github.labels`, `github.runnerGroup`, `buildAgent.*`, `lifecycle.*`, `logs.*`, `housekeeping.*`, plus `"generated": { "by": "Manage-RunnerHost", "hash": "<sha256>" }` |
| `runners.local.json` | `Install-WindowsRunner.ps1` only, as today | `github.url`, `windows.instanceId`, `windows.name`, `windows.labels`, `windows.workFolder`; the manager sets them through Install's existing parameters |

`Read-RunnerConfig` merges `runners.json` < `runners.host.json` < `runners.local.json`. A clone without
`runners.host.json` resolves exactly as today. Drift is: `runners.host.json` no longer matches its hash, or
`runners.local.json` sets a key that `runners.host.json` owns. Plan reports both; Apply refuses to overwrite a
hand-edited `runners.host.json` without `-Force`, and never edits `runners.local.json`. `runners.host.json` is
ignored by git, so `Sync-RunnerSetupInstance`'s clean-checkout check still passes.

| Setting | Resolved from | Reaches Windows instances as |
| --- | --- | --- |
| GitHub target | host `github.url` | `-GitHubUrl` (existing); Install writes it to the clone's `runners.local.json` |
| `hostId` | host setting, default the lower-cased computer name | `runners.host.json`. `Setup-WindowsRunners.ps1` gains an optional `-HostId` used for `subzerodev-host-<hostId>` and `subzerodev-pair-<hostId>`. The default is the computer name, so existing labels do not change. |
| Runner names | Linux: `subzerodev.runner.linux.<hostId>.<nn>` (slot 01 legacy: `subzerodev.runner.linux`). Windows: `subzerodev.runner.windows.<hostId>.win<nn>`, as today when `hostId` is the computer name. | `-Name` (existing Install parameter); Install writes `windows.name` |
| Labels | `github.labels` + `linux.labels` / `windows.labels` + host labels | `-ExtraLabels` (existing); Install writes `windows.labels` |
| BuildAgent image, tools, overrides | host `buildAgent.*` | `runners.host.json`. Every instance gets the same `buildAgent` block. |
| Install and work paths | `%LOCALAPPDATA%\SubZeroDev\Runners\win<nn>`, `windows.workFolder` | existing; recorded in the inventory |
| Identity and registration | the instance's `.runner` (`agentId`, `agentName`) | recorded in the inventory; checked against GitHub by ID |
| Source revision | the host manager clone's `HEAD`, which must have no uncommitted tracked changes | `SourceCommit` (existing `Sync-RunnerSetupInstance`); one commit for every clone, recorded per instance |

Counts:

- Settings accept `linux.count` and `windows.count` from 0 to 16. `Setup-WindowsRunners.ps1 -Count` stays 1–16 and
  is not called by the manager (C1). Count 0 retires every `active` slot on that side through the retire operation
  above, with `-Retire`.
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
  subzerodev-runners up -d --no-deps --force-recreate <slot services>`, then end maintenance if the operation started
  it (C4). The slot's services are the runner and, in sidecar mode, its sidecar. Compose is never run without service
  names. `down` is never used. A busy slot is never touched by another slot's change.
- **Changing a Windows instance (C1).** Only an instance that is not held, one at a time, as a journaled operation
  under the host lock: journal `heldBefore` (false), `Enter-RunnerMaintenance`, drain, stop the supervisor;
  `Sync-RunnerSetupInstance` to the recorded commit; write `runners.host.json`; end the operation's maintenance; then
  `Install-WindowsRunner.ps1` with the instance's `-InstanceId`, `-Name`, `-GitHubUrl` and `-ExtraLabels`. Install
  finds no record (so its held-instance refusal at line 84 is never reached), applies any registration change, and
  starts the supervisor. Its `Start-WindowsRunner` ends no maintenance the owner set, because the lock keeps Hold out
  until the operation is done. Then the per-instance evidence check and online-by-ID verification. A held instance is
  skipped and reported `deferred: held`.
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
| 0 | Adopt has recorded the legacy slot: `.runner` `agentId` equals GitHub's ID for `subzerodev.runner.linux`, and the full IDs and names of the container `subzerodev-runner-linux` (and its sidecar in sidecar mode) | nothing changed |
| 1 | Journal `heldBefore`; drain: record written, labels withdrawn, job drained | the legacy runner held, still registered. Retry continues; rollback undoes it. |
| 2 | Stop the legacy container(s) by recorded ID; `docker update --restart=no`; journal records the old policy `unless-stopped` | legacy stopped and unable to restart on its own; registration intact |
| 3 | Write compose with `linux-01` mapped to the legacy directory and volumes; `up -d --no-deps linux-01`; journal the new container's full ID | new container up and waiting (the record exists); no listener anywhere |
| 4 | If `heldBefore` is false: end the operation's maintenance (labels restored, record deleted); the new entrypoint starts `run.sh`. If true: skip; the slot stays held (C4). | listener in the new container with the same credentials, or none while held |
| 5 | Verify GitHub reports the same `runnerId` under the same name: online if step 4 resumed, any status if the slot is held | — |
| 6 | Inventory: `linux-01` active, `legacy: true`; legacy container recorded `kept-for-rollback` with its ID; operation done | — |
| 7 | The legacy container is removed by the next `Apply -Prune`, only while Docker reports its recorded ID and name, never before step 6 | — |

The two containers never run a listener at the same time: the legacy one is stopped with `--restart=no` before the
new one exists. **Rollback** at any step before 6: `compose rm -s -f linux-01`, `docker update
--restart=unless-stopped` and start the legacy container by recorded ID, then end the operation's maintenance only if
`heldBefore` is false. The credentials were never changed, so the legacy runner reconnects with the same ID.

Renaming slot 01 to the standard name later (`-RenameLegacy`) is a re-registration: drain, deregister the recorded
ID, register the new name, which gets a new ID. If it fails after the old ID was deregistered, saved credential files
do not bring the registration back, because GitHub has revoked it. The only recovery is to register again. The
journal keeps the slot `retiring` with the old ID recorded as removed, and a retry registers the new name. This is
optional and not part of the pool rollout.

A single-clone Windows install (a runner name without `.win<nn>`, like `subzerodev.runner.windows`) is adopted only
when its clone is found on the host and its `.runner` `agentId` matches GitHub's ID for that name. Whether such a
clone exists on beast, and whether it is the registration GitHub reports offline as id 8, is **not verified**; Adopt
answers it on the host. If adopted, Apply adds `win01`, `win02` … through the per-instance path (C1), and retires the
single-clone registration with `-Retire` (D2) only after `win01` is online. If no clone proves id 8, the manager does
not touch it, and Plan lists it as an unowned registration for the owner to remove.

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
- **Changed for managed hosts only:** `Setup-WindowsRunners.ps1` refuses when a host inventory exists (C1);
  `Read-RunnerConfig` also reads an optional `runners.host.json` (C2).
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
| L2 workflow | the GitHub check passes on a self-hosted slot | **not run.** Status (verified 2026-11-10): run 42847206551 queued since 15:42 UTC; the only registered runner with `self-hosted, subzerodev, Windows`, id 8, is offline. Cause of the offline state: **not verified**. |
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
