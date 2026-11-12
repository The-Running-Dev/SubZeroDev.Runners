# Host management

`scripts\Manage-RunnerHost.ps1` answers three questions about one host: what runners it owns, what state they are in, and
what would change. It runs in the host's own checkout (not in a Windows instance clone) and needs PowerShell 7.2+.

Design background is in the [runner pool plan](runner-pool-plan.md). This guide covers the actions that exist today.
`Apply` (adding and retiring slots), legacy Linux migration and `Update` are planned slices and are not available yet.

## Concepts

| Term | Meaning |
| --- | --- |
| Slot | One runner. Linux slots are `linux-01`, `linux-02`, ...; Windows slots are `win01`, `win02`, ... Numbers are never reused |
| Host ID | Lower-cased computer name by default (`hostId` in settings, 1-31 of `a-z0-9-`). Part of each Windows runner name: `subzerodev.runner.windows.<hostId>.win01` |
| Inventory | `%LOCALAPPDATA%\SubZeroDev\Runners\host\inventory.json`: the slots this host's manager owns, with container IDs and runner IDs. An unreadable file is a distinct state, never treated as empty |
| Journal | `operation.json` beside it: the one operation in progress. Hold and Resume refuse a slot while one is unfinished |
| Host lock | One named mutex. Init, Adopt, AutoStart, Hold and Resume take it for their whole run; Plan and Status take none and write nothing |
| Slot 01 (legacy) | The pre-pool Linux runner `subzerodev.runner.linux` in `linux\runner`, kept under its old name, container and volumes |

Settings resolve in this order, later wins: `runners.json`, `runners.host.json` (written by the manager for a Windows
clone), `runners.local.json` (yours, git-ignored). Host-owned keys are `hostId`, `linux.count`, `windows.count`,
`windows.startAtSignIn`, `github.runnerGroup`, `housekeeping.minFreeGB` and `buildAgent.estimate.memory`. A count left `null`
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
| `AutoStart` | What runs at host start and sign-in: waits for Docker (up to `buildAgent.docker.readyTimeoutSeconds`), then starts each active Windows slot's supervisor. It never ends maintenance. Linux slots need nothing: Docker restarts their containers and the entrypoint waits while a slot is held |
| `Hold -Slot <id>` | Drains the slot, stops it and keeps its maintenance record. Nothing starts it again until `Resume` |
| `Resume -Slot <id>` | The only path that ends the maintenance Hold began: restores labels, deletes the record, starts the one listener (starting a stopped Linux container first) |
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
