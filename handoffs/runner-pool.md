# Handoff: per-host runner pool (N Linux slots, N Windows slots)

For this repository, SubZeroDev.Runners. The design is [docs/runner-pool-plan.md](../docs/runner-pool-plan.md);
read it first. Its "Decided" section, the owner decisions D1–D4 and the resolutions C1–C4 are binding. Follow this
repository's conventions:

- settings through `RunnerConfig.ps1`;
- drains through `Lifecycle.ps1`;
- registrations through `Registration.ps1`;
- for every script that changes, a `tests/Test-*.ps1` with a fake Docker and GitHub, and a line in
  `windows-runner-validation.yml`.

## Goal

Each host runs `linux.count` BuildAgent-based Linux slots and `windows.count` native Windows slots, owned through a
host inventory and changed only by journaled operations under one host lock. An automatic start (Docker restart,
sign-in, Apply) never ends maintenance. Existing hosts keep exactly what they have until a count is set. BuildAgent
is not changed.

## Who uses the runners today (must keep working)

- **The Linux runner** `subzerodev.runner.linux` (container `subzerodev-runner-linux`, registration in
  `linux/runner`). It becomes slot 01 under the legacy mapping, with the same name and registration.
- **The Windows instances** from `Setup-WindowsRunners.ps1` (`win<nn>`), and the single-clone layout from
  `Install-WindowsRunner.ps1`. At GitHub on 2026-11-10, `subzerodev.runner.windows` (id 8) is registered and
  offline, and no `win<nn>` is registered. Which host holds id 8 and why it is offline are not verified.
- **Every org workflow.** They target `[self-hosted, subzerodev, Linux|Windows]` or `subzerodev-windows`, and none
  changes. That includes [AbsoluteZeroDev/SubZeroDev.HollowMoon#4](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/pull/4),
  which calls `"$env:SZR_SCRIPTS\Invoke-BuildAgent.ps1" -Type node -CopyOutputTo …`.
- **SubZeroDev.Dashboard telemetry v1.** It reads `Manage-WindowsRunner.ps1 -Action Status -Json` and
  `Get-BuildAgentStatus.ps1 -Json`; both stay byte for byte.
- **`Manage-WindowsRunner.ps1 -Action Start`**, which keeps ending maintenance (explicit resume).

## What to build (one PR per slice, in order)

1. **Settings and resolution.**
   - Add to `runners.json` and `Assert-RunnerConfig`:
     - `hostId` (default: the lower-cased computer name; pattern `^[a-z0-9][a-z0-9-]{0,30}$`);
     - `linux.count` and `windows.count` (null or 0–16; **no numeric default**);
     - `windows.startAtSignIn` (false);
     - `github.runnerGroup` (`{ "name": "Default", "repositories": null }`);
     - `housekeeping.minFreeGB` (null);
     - `buildAgent.estimate.memory` (`8g`).
   - `Get-LinuxSlots $Config $Inventory` and `Get-WindowsSlots $Config $Inventory` return resolved slots. These are
     names, directories, volumes, containers, services and labels, with slot 01 mapped to the legacy names when the
     inventory marks it `legacy`. No script reads `linux.container`, `linux.directory` or volume names directly after
     this slice.
   - `New-HostSettings $Config $Slot` builds a Windows clone's `runners.host.json` from the host-owned keys in the
     plan's table, with its `generated.hash`. It never contains the Install-owned keys (`github.url`,
     `windows.instanceId`, `windows.name`, `windows.labels`, `windows.workFolder`).
   - `Read-RunnerConfig` merges `runners.json` < `runners.host.json` < `runners.local.json`; a missing
     `runners.host.json` resolves exactly as today. `Test-HostSettingsDrift` reports a hash mismatch and any
     host-owned key that `runners.local.json` sets. Add `/runners.host.json` to `.gitignore` and `dropbox-ignore.txt`.
   - `Setup-WindowsRunners.ps1` gains `-HostId`, which defaults to the computer name, so labels and names are unchanged
     when it is omitted.
2. **Host state: inventory, journal, lock, Init/Adopt, Plan/Status.**
   - New `scripts/HostState.ps1`:
     - reads and writes `inventory.json` and `operation.json` under `%LOCALAPPDATA%\SubZeroDev\Runners\host\`, with
       `schema` and `version`, atomically (reuse the `Set-MaintenanceState` write);
     - an unreadable file is a distinct state, never treated as empty;
     - `Use-HostLock` takes `Local\SubZeroDev.Runners.Host`, or joins it when `SZR_HOST_OPERATION` matches the
       journal's operation id.
   - The existing mutating scripts take the lock when run directly. `Setup-WindowsRunners.ps1` refuses when an
     inventory exists and names `Manage-RunnerHost.ps1` (C1).
   - Inventory containers are recorded by full ID and name (C3). Journal steps that enter maintenance record
     `heldBefore` (C4); `Complete-OperationMaintenance` calls `Exit-RunnerMaintenance` only when it is false.
   - `scripts/Manage-RunnerHost.ps1`:
     - `Init` writes counts (default 2/2) and `hostId` into `runners.local.json`.
     - `Adopt` records only what is proven (the plan's rules) and writes nothing else. It refuses an unreadable
       inventory without `-ReplaceUnreadable`.
     - `Plan [-Json]` and `Status [-Json]` take no lock and make no write calls. Plan prints a `planHash` and exits
       0 (no changes) or 3 (changes).
   - Status reports drift: image, compose config hash, compose file hash, clone settings hash, clone commit, runner
     group. It also reports any unfinished operation.
   - Runner-group verification: expected group exists, `allows_public_repositories` false, visibility and allowlist,
     every slot's runner in the group.
3. **Automatic start keeps maintenance.**
   - `linux/entrypoint.sh`: while `/runner/maintenance.json` exists, log once and check again every 15 s; `exec
     /runner/run.sh` only once it is gone. `configure` is unchanged.
   - `Manage-WindowsRunner.ps1 -Action AutoStart` starts the supervisor without `Exit-RunnerMaintenance`, and does
     nothing if the supervisor is already running (its mutex).
   - `Manage-RunnerHost.ps1 -Action AutoStart` waits for `docker info` up to `buildAgent.docker.readyTimeoutSeconds`,
     then runs AutoStart in each `active` Windows instance.
   - `-Action Hold -Slot` and `-Action Resume -Slot` run under the lock and refuse a slot with an unfinished
     operation, naming it (C4). Resume is the only new owner path to `Exit-RunnerMaintenance`; for Linux it starts a
     stopped container first.
   - `windows.startAtSignIn` adds or removes a per-user Startup entry that runs host AutoStart: no elevation, no
     scheduled task, no service.
4. **Compose and the image context hash.**
   - `New-LinuxRunner.ps1` writes `linux/compose.local.yaml` (add it to `.gitignore` and `dropbox-ignore.txt`) from
     `Get-LinuxSlots`. Each slot gets a service, plus a sidecar in sidecar mode, with:
     - the same mounts, environment, limits and privileged/dind settings as today's `docker run` lines;
     - `restart: always`;
     - labels `dev.subzerodev.runners.host`/`.slot`.
   - Every compose call names its services and uses `--no-deps`; there is no `down`.
   - A per-slot change is hold or idle, then `up -d --no-deps --force-recreate <slot services>`, then end maintenance
     only if the operation started it (C4). The new container's full ID is recorded (C3).
   - The build context hash covers `.dockerignore`, each file it admits, and `BASE_IMAGE`/`RUNNER_VERSION`/`RUNNER_SHA256`.
     It is stored as image label `dev.subzerodev.runners.context`, and the image is rebuilt on a mismatch.
   - `-Update` refuses a container with a `com.docker.compose.project` label.
   - `scripts/Get-LinuxRunnerStatus.ps1 -Json`: one row per slot, `schema`/`version`, `instanceId` `linux-<nn>`.
5. **Legacy Linux migration.**
   - The journaled operation `migrate-legacy-linux`, exactly as the plan's table: record `heldBefore`, drain, stop by
     recorded ID, and `docker update --restart=no`, then compose `linux-01` on the legacy directory and volumes, end
     the operation's maintenance only if `heldBefore` is false, verify the same `runnerId` (online unless held), and
     commit the inventory.
   - The legacy container is kept for rollback until `Apply -Prune`, which removes it only by recorded ID and name.
   - `-Rollback` restores the legacy container while the operation is before its verification step.
   - `-RenameLegacy` is not part of this slice.
6. **Add and retire slots.**
   - Apply takes the lock, finishes an unfinished operation, recomputes the plan (`-ExpectPlan` refuses on
     difference), then runs one journaled operation per slot change:
     - add: `provisioning` → registered (runnerId recorded) → service or instance created → online → `active`;
     - retire: the plan's seven steps, highest-numbered slot first.
   - Surplus slots are retired only with `-Retire` (D2 (b)); without it they are reported and Apply exits 3.
   - Windows (C1): never `Setup-WindowsRunners.ps1`. One instance per operation through `Sync-RunnerSetupInstance`,
     writing `runners.host.json`, and `Install-WindowsRunner.ps1` with `-InstanceId -Name -GitHubUrl -ExtraLabels`,
     inside a drain the operation started and ended before Install runs. A held instance is skipped and reported
     `deferred: held`. Slot numbers are never reused. Count 0 retires every active instance with `-Retire`.
   - Unset count: no change on that side.
   - A single-clone registration is retired only if Adopt proved it (clone found, `agentId` matches), and only after
     `win01` is online. An unproven registration is reported as unowned and never touched.
   - `-Prune` removes `retired` slots' directories, volumes and clones, and the kept legacy container, each verified
     by recorded identity.
   - Apply refuses to register into a group that allows public repositories, and adds no slot below
     `housekeeping.minFreeGB`.
7. **Updates and resources.**
   - `Manage-RunnerHost.ps1 -Action Update` resolves the BuildAgent release digest, writes it into the host's
     `runners.local.json`, then runs Apply, which recreates one slot at a time under drain.
   - Plan reports:
     - per-slot `docker system df -v`;
     - free space on Docker's data drive;
     - the Linux slots' limits plus `buildAgent.estimate.memory` × Windows slots against the `.wslconfig` cap.
       The Windows-side figure is labelled advisory.
   - It never edits `.wslconfig`, auto sign-in or Docker Desktop settings.
8. **Docs and target-host acceptance.**
   - README: settings, host manager actions, slot names, held/resume semantics, reboot sequence.
   - Update `docs/windows-two-runners.md` for AutoStart, Retire and Prune.
   - Run L3 on beast (below) and record it in the PR.

## Contract

| Item | Value |
| --- | --- |
| Desired state | host: `runners.json` < `runners.local.json`. Windows clone: `runners.json` < `runners.host.json` (manager-written, hash-checked) < `runners.local.json` (Install-written). One writer per file. |
| Host state | `%LOCALAPPDATA%\SubZeroDev\Runners\host\inventory.json`, `operation.json`, schema + version, atomic writes |
| Host lock | `Local\SubZeroDev.Runners.Host`; joined through `SZR_HOST_OPERATION` |
| Counts | `linux.count`, `windows.count`: null (keep what exists) or 0–16; `Init` writes 2/2 |
| Linux slot `nn` | runner `subzerodev.runner.linux.<hostId>.<nn>`, container `subzerodev-runner-linux-<nn>`, directory `linux/runner-<nn>`, volumes `…-<nn>`; slot 01 legacy: `subzerodev.runner.linux`, `linux/runner`, existing volumes, container `subzerodev-runner-linux-01` |
| Windows instance | `win<nn>`, runner `subzerodev.runner.windows.<hostId>.win<nn>` |
| Held | the maintenance record exists (unreadable included); no listener while held |
| Ends maintenance | `Manage-RunnerHost -Action Resume` and `Manage-WindowsRunner -Action Start`; an operation ends only maintenance it started (`heldBefore` false) |
| Windows changes | per instance, never through `Setup-WindowsRunners.ps1`; a held instance is never changed (`deferred: held`) |
| Compose | project `subzerodev-runners`, file `linux/compose.local.yaml`, `restart: always`, always with service names and `--no-deps` |
| Deletion | only by recorded identity (runner ID + name + scope; container full ID + name, plus labels for containers the manager created), never by name or prefix; unknown ≠ absent |
| Labels | unchanged: `subzerodev` + `subzerodev-linux` / `subzerodev-windows` + custom; host labels from `hostId` |
| Unchanged | `Invoke-BuildAgent.ps1` parameters, `SZR_SCRIPTS`, both existing `-Json` shapes, `Manage-WindowsRunner -Action Start`, `Setup-WindowsRunners -Count` range, pinned digests, never `:latest` |

## Tests (L0, fakes; reported separately from L1–L3)

- **Settings:**
  - defaults; null count; 0, 16 and 17 (refused); bad `hostId`;
  - slot names for 1, 2 and 16;
  - legacy mapping for slot 01;
  - `runners.host.json` carries every host-owned key and none of Install's;
  - without `runners.host.json`, `Read-RunnerConfig` returns exactly today's result;
  - a hand-edited `runners.host.json` is drift and is not overwritten without `-Force`; a host-owned key set in a
    clone's `runners.local.json` is drift;
  - running `Install-WindowsRunner.ps1` leaves `runners.host.json` byte for byte unchanged, and the manager never
    writes `runners.local.json`;
  - `-HostId` omitted gives today's labels.
- **Host state:**
  - atomic write survives a kill between temp write and move;
  - unreadable or unknown-version inventory makes Apply, Resume, Hold and Prune refuse;
  - Adopt records only proven resources: a container with a matching name but no matching registration is not
    adopted; an adopted container is recorded with its full ID;
  - `-ReplaceUnreadable` keeps the old file;
  - `Setup-WindowsRunners.ps1` refuses when an inventory exists and runs as today when none does.
- **Ownership (C3, C4):**
  - a legacy container (no labels) whose recorded ID and name match is removable; one recreated under the same name
    with a new ID is not, nor is a different container with the recorded ID's name;
  - a retire drain timeout on a slot that was held before leaves the record in place and the labels withdrawn; on a
    slot that was not held, it restores both;
  - Resume and Hold refuse a slot with an unfinished operation and name it; the record is unchanged.
- **Unknown is not absent:** with fake Docker or GitHub returning a timeout or 500 at each step, nothing is deleted,
  the journal is kept, and the slot is not reported as gone.
- **Failure injection, retire:** kill after each of steps 1–7 in turn, then rerun Apply. Each retry finishes the
  operation, issues no second DELETE for a 404 ID, never registers, never recreates the retiring slot in compose, and
  makes no call against another slot's resources.
- **Failure injection, add:**
  - kill after registration but before `.runner` was read: the retry records the ID;
  - kill after GitHub accepted but before `.runner` was written: the retry reports the orphan and registers with
    `--replace`.
- **Failure injection, migration:**
  - kill after each step, then retry; the legacy container never runs while `linux-01` runs;
  - rollback before verification brings back the legacy runner with the same ID;
  - migrating a legacy runner that was already held: no Resume, the record stays, verification accepts the same ID
    offline;
  - the legacy container is not removed before verification, and is removed only by `-Prune`.
- **Concurrency:**
  - two Apply processes: the second waits for the lock and recomputes; with `-ExpectPlan` it refuses;
  - Hold racing Resume on one slot;
  - Hold racing AutoStart: when Hold returns, no listener is running and the record exists;
  - `New-LinuxRunner.ps1` run directly while Apply holds the lock waits;
  - a script called by Apply with `SZR_HOST_OPERATION` joins the lock instead of deadlocking.
- **Maintenance acceptance:**
  - hold → fake Docker restart → the entrypoint runs no `run.sh`;
  - hold → sign-in AutoStart → the supervisor idles with no listener;
  - hold → Apply three times → still held, labels still withdrawn;
  - hold a Windows instance whose settings changed → Apply makes no Sync, Install or Start call for it and reports
    `deferred: held`; after Resume, the next Apply changes it;
  - a Windows change on an instance that was not held never reaches `Install-WindowsRunner.ps1`'s held-instance
    refusal;
  - Resume → labels restored, exactly one listener;
  - unreadable record → held, and Resume refuses with the existing message;
  - `Manage-WindowsRunner -Action Start` still ends maintenance.
- **Compose:**
  - generated file compared with today's `docker run` arguments for both modes, including paths with spaces;
  - every compose call carries service names;
  - **with slot 01 busy, updating or recreating slot 02 makes no call that touches slot 01** (no recreate, no label
    change);
  - changing each of the Dockerfile, `entrypoint.sh`, `healthcheck.sh`, the runner archive, `.dockerignore`, and a
    build argument triggers a rebuild;
  - a file `.dockerignore` admits but the hash does not cover fails the test;
  - `-Update` refuses a compose container.
- **Updates:** Update writes the digest before any recreate. An Apply after a successful Update makes no change. An
  Apply with a stale digest in settings is reported as a downgrade, not silently applied.
- **Scale:**
  - 2→3→1 on each side, with and without `-Retire`;
  - no Apply calls `Setup-WindowsRunners.ps1`; Windows count 0 retires every active instance only with `-Retire`;
  - after `win02` is retired, raising the count adds `win03`, never a second `win02`;
  - a host with no Linux registration and an unset `linux.count` plans no Linux change;
  - Prune removes only retired resources.
- **Runner group:** `Default` as today passes; a group allowing public repositories is drift and blocks
  registration; allowlist mismatch is reported.
- **Plan is read-only:** no fake write calls at all; exit codes 0 and 3; `planHash` is stable for the same state.
- **Status:** `-Json` with `schema`/`version`; the two existing outputs are byte for byte unchanged.

## Target-host acceptance (L3, on beast, recorded in slice 8's PR)

1. Adopt, then Plan; review the plan.
2. Migrate the legacy Linux runner: same runner ID online as `linux-01`.
3. Set counts 2/2, then Apply: `linux-01`, `linux-02`, `win01` and `win02` online. A single-clone Windows
   registration that Adopt proved is retired with `-Retire`; one it did not prove is reported unowned and left alone.
4. Hold `linux-02` and `win02`, then reboot with auto sign-in. All four containers and supervisors come back. The two
   held slots have no listener and stay held. Resume each: one listener each.
5. With a job running on `linux-01`, Update or recreate `linux-02`: the job on `linux-01` finishes untouched.
6. At the same time:
   - HollowMoon's `build.yml` passes on a Windows slot (L2 for PR #4);
   - `tests/linux-runner-docs-smoke.yml` passes on a Linux slot;
   - record the WSL memory peak against the plan's estimate.
7. Lower `windows.count` to 1 and Apply without `-Retire`: reported, nothing removed. With `-Retire`: `win02` drained
   and deregistered. Then `-Prune`.

## Release

Merge slice by slice through this repository's PR flow. Beast moves when slices 1–6 are merged: Adopt, Plan, migrate,
Apply. No repository needs a workflow change for the pool. Moving a stage of a repository's job into BuildAgent is
separate work in that repository, done job by job after that project reaches L1 and L2. Release jobs move last and
keep `environment: release`.
