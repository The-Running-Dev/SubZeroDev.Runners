# Host management

`scripts\Manage-RunnerHost.ps1` answers three questions about one host: what runners it owns, what state they are in, and
what would change. It runs in the host's own checkout (not in a Windows instance clone) and needs PowerShell 7.2+.

Design background is in the [runner pool plan](runner-pool-plan.md). This guide covers the actions that exist today.
`Apply` migrates the legacy Linux runner, adds and retires slots and updates drifted ones; `Update` moves the BuildAgent
image to a release.

## Concepts

| Term | Meaning |
| --- | --- |
| Slot | One runner. Linux slots are `linux-01`, `linux-02`, ...; Windows slots are `win01`, `win02`, ... Numbers are never reused |
| Host ID | Lower-cased computer name by default (`hostId` in settings, 1-31 of `a-z0-9-`). Part of each Windows runner name: `subzerodev.runner.windows.<hostId>.win01` |
| Inventory | `%LOCALAPPDATA%\SubZeroDev\Runners\host\inventory.json`: the slots this host's manager owns, with container IDs and runner IDs. An unreadable file is a distinct state, never treated as empty |
| Journal | `operation.json` beside it: the one operation in progress. Hold and Resume refuse a slot while one is unfinished |
| Host lock | One named mutex. Init, Adopt, AutoStart, Hold, Resume and Apply take it for their whole run; Plan and Status take none and write nothing |
| Slot 01 (legacy) | The pre-pool Linux runner `subzerodev.runner.linux` in `linux\runner`, kept under its old name, container and volumes |

Settings resolve in this order, later wins: `runners.json`, `runners.host.json` (written by the manager for a Windows
clone), `runners.local.json` (yours, git-ignored). Host-owned keys are `hostId`, `linux.count`, `windows.count`,
`windows.startAtSignIn`, `windows.updateAtSignIn`, `github.runnerGroup`, `housekeeping.minFreeGB` and `buildAgent.estimate.memory`. A count left `null`
means "no change on that side".

## Actions

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action <Action> [-Slot <id>] [-Json]
```

| Action | Does |
| --- | --- |
| `Init [-LinuxCount] [-WindowsCount] [-HostId]` | Writes the slot counts (default 2 Linux, 2 Windows) and `hostId` into this checkout's `runners.local.json` |
| `Adopt [-ReplaceUnreadable]` | Builds the first inventory from what can be proven: a registration directory whose `.runner` agent ID is the ID GitHub reports under that name, and the containers this repository's scripts created. Writes only the inventory. Refuses when an inventory exists (use `Plan`), or when it is unreadable unless `-ReplaceUnreadable`, which keeps the old file as `inventory.json.unreadable-<utc>` |
| `Plan [-Json]` | Compares settings with the inventory, Docker and GitHub and prints the changes a later Apply would make, with a `planHash`. Exit 0: no changes; 3: changes, or a drift or blocked finding; 1: something the plan needs cannot be read |
| `Status [-Json]` | Prints each slot as GitHub, Docker and the files on disk report it, with drift (image, compose config, compose file, clone settings, runner group) and any unfinished operation |
| `AutoStart` | What runs at host start and sign-in: waits for Docker (up to `buildAgent.docker.readyTimeoutSeconds`), then starts each active Windows slot's supervisor. It never ends maintenance. Linux slots need nothing: Docker restarts their containers and the entrypoint waits while a slot is held. With `windows.updateAtSignIn` it first pulls this checkout and updates the drifted Windows slots ([update at sign-in](#update-at-sign-in)) |
| `Hold -Slot <id>` | Drains the slot, stops it and keeps its maintenance record. Nothing starts it again until `Resume` |
| `Resume -Slot <id>` | The only path that ends the maintenance Hold began: restores labels, deletes the record, starts the one listener (starting a stopped Linux container first) |
| `Apply [-ExpectPlan <hash>]` | Migrates the legacy `linux-01` (see [Legacy Linux migration](#legacy-linux-migration)), then adds the slots the counts want (see [Adding and retiring slots](#adding-and-retiring-slots)), or resumes an unfinished operation. Exit 0 when done or nothing to do; 3 when a surplus slot was not retired; 1 on a refusal or failure. With `-ExpectPlan` it refuses, changing nothing, when the plan is not the reviewed one |
| `Apply -Retire` | Also retires the slots the counts no longer want: drains, deregisters and removes them |
| `Apply -Rollback` | Before the migration is verified: removes the new containers and restarts the pre-pool ones. The inventory is not changed |
| `Apply -Prune` | Removes the pre-pool containers a finished migration kept for rollback, and what retired slots left on disk |
| `Startup` | Applies `windows.startAtSignIn`: writes or removes the per-user Startup entry that runs `AutoStart` |

Typical first run on an existing host:

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action Init -LinuxCount 2 -WindowsCount 2
.\scripts\Manage-RunnerHost.ps1 -Action Adopt
.\scripts\Manage-RunnerHost.ps1 -Action Plan      # exit 3 lists what differs; nothing is changed
.\scripts\Manage-RunnerHost.ps1 -Action Status
```

`Setup-WindowsRunners.ps1` refuses to run once an inventory exists and names this script instead.

## Hold and resume

Hold is the owner's "do not run this runner". It survives reboots, Docker restarts and sign-ins:

- Windows: the supervisor idles while `maintenance.json` exists in the instance, so no listener starts.
- Linux: `linux\entrypoint.sh` logs `Held: ...` and polls every 15 s while `/runner/maintenance.json` exists, then starts
  the listener only after the record is gone.

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action Hold   -Slot win01
.\scripts\Manage-RunnerHost.ps1 -Action Resume -Slot win01
```

Both refuse a slot that is not `active` and a slot with an unfinished operation, naming the operation and its next step.
An operation ends only maintenance that it started itself. Hold's drain follows the rules in
[Draining and its limits](../README.md#draining-and-its-limits): a running job is not cancelled.
`Manage-WindowsRunner.ps1 -Action Start` still ends maintenance for one instance when you run it yourself.

## Start after a reboot

Nothing is a service or a scheduled task. After a restart:

1. Docker Desktop starts (it brings the Linux runner containers back; held ones wait in the entrypoint).
2. Windows supervisors start only if `windows.startAtSignIn` is `true` and the Startup entry exists, or when you run
   `Manage-RunnerHost.ps1 -Action AutoStart` (or `Manage-WindowsRunner.ps1 -Action Start` per clone).
3. A held runner stays held either way.

To start at sign-in, set `"windows": { "startAtSignIn": true }` in `runners.local.json` and run:

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action Startup
```

That writes `SubZeroDev Runners AutoStart.cmd` into your per-user Startup folder (no elevation). Set the value back to
`false` and run `Startup` again to remove it. Setup never enables automatic sign-in or restarts Windows.

### Update at sign-in

With `"windows": { "updateAtSignIn": true }` in `runners.local.json`, `AutoStart` (the Startup entry's, or yours) first
brings the Windows slots up to this checkout:

1. It fast-forwards this checkout to its upstream branch (`git fetch`, then `git merge --ff-only`), only when the checkout
   is on a branch with an upstream and has no changes to tracked files. Anything else (no git, no upstream, local changes,
   no network, diverged history) is a warning and the checkout stays as it is.
2. When the checkout moved, the newer `Manage-RunnerHost.ps1` runs the rest (it joins the same host lock).
3. Each Windows slot the plan shows as `update` is updated as `Apply` would: drained, its clone moved to this commit, its
   generated settings written, started. A busy or held slot is deferred to the next `Apply`; an update that stops keeps
   its journal for `Apply` and is reported.
4. Every active Windows slot is then started as before, maintenance left as it is.

Nothing is added, retired or migrated, the Linux slots and image are left to `Apply`, and nothing is updated while an
operation is unfinished. A failed pull or update makes `AutoStart` exit 1 but never keeps a slot from starting. The
Startup entry itself does not change, so no `Startup` rerun is needed.

## Linux slots as compose services

`New-LinuxRunner.ps1` writes `linux\compose.local.yaml` (git- and Dropbox-ignored) from the resolved slots: one service per
slot, plus the Docker sidecar in `sidecar` mode, `restart: always`, and labels `dev.subzerodev.runners.host` and `.slot`.
Every compose call names its services and uses `--no-deps`; there is no `down`, so one slot is recreated without touching
another. The image carries a build-context hash label (`dev.subzerodev.runners.context`) covering `.dockerignore`, each file
it admits and `BASE_IMAGE`, `RUNNER_VERSION`, `RUNNER_SHA256`; a mismatch rebuilds the image.

```powershell
.\scripts\Get-LinuxRunnerStatus.ps1          # one line per slot: state, container, drift or current
.\scripts\Get-LinuxRunnerStatus.ps1 -Json    # schema subzerodev.linux-runner-status, version 1
```

Each slot reports four checks: `image` (the container runs the current image), `contextHash` (the image was built from the
files on disk), `composeConfigHash` (the container matches the compose definition) and `composeFile` (the file matches what
the scripts generate). Each is `ok`, `drift`, `not-applicable` or `not-checked` with the reason; a check that cannot be made is never
reported `ok`. The command only reads. `New-LinuxRunner.ps1 -Update` refuses containers created by compose; use the
`-Build` path for them.

## Legacy Linux migration

`Plan` lists `migrate-legacy-linux` while `linux-01` still runs as the pre-pool `subzerodev-runner-linux` containers.
`Apply` moves it onto compose (`subzerodev-runner-linux-01` and its sidecar) under the same registration, runner ID and
volumes, as six journaled steps:

| Step | Does |
| --- | --- |
| `drain` | Records whether the slot was already held, closes admission and waits for the running job. On timeout the journal is deleted, admission reopened and nothing else changed |
| `stop-legacy` | Turns off the old containers' restart policy and stops them by ID. The old and new runner never run at the same time |
| `compose-up` | Creates the network and volumes if needed, writes `linux\compose.local.yaml`, starts the sidecar, then the runner |
| `end-maintenance` | Restores labels and deletes the maintenance record, unless the slot was held before Apply |
| `verify` | Waits (`lifecycle.startTimeoutSeconds`) for the new container to run and GitHub to report the same runner ID online |
| `commit` | Records the new containers in the inventory and keeps the old ones as `keptForRollback` |

Before anything changes, Apply refuses when the image is not built, a recorded old container was renamed or cannot be
read, or a container that is not this host's compose `linux-01` holds a target name. If a run stops part-way (killed,
or a step failed), run `Apply` again to finish it, or `Apply -Rollback` to go back; `New-LinuxRunner.ps1`, `Hold` and
`Resume` refuse until one of them finishes. Rollback is refused once `verify` is done.

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action Apply             # migrate, or finish an interrupted migration
.\scripts\Manage-RunnerHost.ps1 -Action Apply -Rollback   # before verify: back to the pre-pool containers
.\scripts\Manage-RunnerHost.ps1 -Action Apply -Prune      # later: remove the kept pre-pool containers
```

`-Prune` removes a kept container only when its recorded ID still names a stopped container with the recorded name. A
renamed, running or unreadable one is kept and reported (exit 1); one already gone is dropped from the record.

## Adding and retiring slots

Set `linux.count` and `windows.count` in `runners.local.json` (or run `Init`), review with `Plan`, then apply:

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action Plan -Json                    # note the planHash
.\scripts\Manage-RunnerHost.ps1 -Action Apply -ExpectPlan <planHash>  # add; refuses if the plan changed since
.\scripts\Manage-RunnerHost.ps1 -Action Apply -Retire                 # also retire slots no longer wanted
.\scripts\Manage-RunnerHost.ps1 -Action Apply -Prune                  # later: remove what retired slots left
```

Each slot gets the next number above the highest ever recorded; a retired or pruned number is never reused. A Linux
slot `NN` is `subzerodev-runner-linux-NN` with its sidecar, network and volumes ending in `-NN`, registered as
`subzerodev.runner.linux.<hostId>.NN`. A Windows slot `winNN` is its own clone at
`%LOCALAPPDATA%\SubZeroDev\Runners\winNN`, registered as `subzerodev.runner.windows.<hostId>.winNN`.

Adding runs five journaled steps:

| Step | Does |
| --- | --- |
| `provision` | Records the slot as `provisioning` (Windows: with its clone path) |
| `register` | Linux: registers the runner with GitHub through the image (the token is never printed); Windows: creates the slot's clone, writes its `runners.host.json` and installs the instance. Records the runner ID from `.runner` |
| `create` | Linux: creates the network and volumes, writes the compose file and starts the sidecar, then the runner |
| `verify` | Waits (`lifecycle.startTimeoutSeconds`) for the container to run and GitHub to report the recorded runner ID online. On failure Apply stops and keeps the journal; rerun it to check again |
| `commit` | Records the containers (or clone) and marks the slot `active` |

Before anything changes, Apply refuses to add when the runner group allows public repositories, free disk is below
`housekeeping.minFreeGB`, or a target container name is held by a container that is not this host's compose slot, or
whose state Docker cannot report. Unknown is never taken as absent.

The Linux adds need the image. When it is missing (a fresh host) or was built from another context, Plan lists a
`build-image` change ahead of them, and Apply builds the image before the first Linux add. If the build fails, or Docker
cannot say whether the image exists, Apply adds no Linux slot and exits 1. The Windows adds go ahead either way.

A slot the counts no longer want is reported and left alone (exit 3) unless `-Retire` is given. Retiring takes the
highest number first and runs seven journaled steps: `withdraw` (records whether it was held, marks it `retiring`),
`drain` (closes admission, waits for the running job; on timeout the journal is deleted, admission reopened and the slot
stays `active`), `stop`, `deregister` (deletes the recorded runner ID; one GitHub no longer has counts as done),
`clear-local` (removes `.runner` and the credentials), `remove-containers`, and `commit` (marks it `retired` and rewrites
the compose file). Volumes, the network and the directory stay until `Apply -Prune`, which removes them and marks the
slot `pruned`; a slot that could not be fully pruned stays `retired` and is tried again next time (exit 1).

A run killed or failed part-way is finished by running `Apply` again (with `-Retire` for a retire). Apply holds the host
lock: a second Apply waits for the first, then finds its work done.

## Updates

```powershell
.\scripts\Manage-RunnerHost.ps1 -Action Update -Version 1.5.0   # move buildAgent.image to that release
.\scripts\Manage-RunnerHost.ps1 -Action Apply                   # finish an interrupted update, or a deferred slot
```

`Update` takes an exact release only (`1.5.0`); `latest`, `1` or `1.4` are refused, as is a tag the registry cannot
resolve, before anything changes. It resolves the tag to its digest and writes it into `runners.local.json`
(`buildAgent.image`, other keys kept) and the inventory, with the digest it replaced, before anything is recreated. It
then rebuilds the Linux image on it (when `linux.baseImage` follows `buildAgent.image`) and applies.

After any adds and retires, `Apply` updates each slot whose containers, image or clone differ from the settings, one at
a time, inside that slot's drain (journaled `drain`, `change`, `resume`, `verify`, `commit`): a Linux slot's own compose
services are recreated (sidecar, then runner; the registration is kept), a Windows slot's clone is synced and its runner
started again. A held slot is skipped (`deferred: held`); a busy one that does not drain in time is left running as it
is (`deferred: busy`). Either exits 3; rerun `Apply` once it is resumed or idle.

An earlier release through `Update` is a rollback and is said so. A digest `Update` replaced that comes back in the
settings (an old `runners.local.json` restored) is a blocked downgrade: `Plan` reports it and `Apply` refuses until the
settings are restored or the rollback is made with `Update`.

## Resources

`Plan` ends with a read-only resources section: each slot volume's size, the free space on Docker's data drive against
`housekeeping.minFreeGB`, the Linux memory the slots are limited to (enforced), the Windows BuildAgent estimate
(`buildAgent.estimate.memory`; advisory, not enforced) and the `[wsl2] memory` cap in `.wslconfig`. A Linux total above
that cap is a warning. Nothing here edits `.wslconfig`, auto sign-in or Docker Desktop settings.
