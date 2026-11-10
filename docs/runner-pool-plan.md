# Runner pool plan

One host, N Linux slots and N Windows slots, all set from the host's own `runners.local.json`.
BuildAgent does the build work on both sides; the Windows slots only run what needs Windows.
The implementation slices are in [handoffs/runner-pool.md](../handoffs/runner-pool.md).

## What exists today (main, 3a7eaf8)

| Piece | State |
| --- | --- |
| Linux runner | One container, `subzerodev-runner-linux`, built `FROM linux.baseImage`, which is the pinned BuildAgent image. It is already a BuildAgent container: `build <type>` is on its PATH, `build-agent-entrypoint` is its entrypoint, and `linux.docker.mode` picks a `docker:dind` sidecar or BuildAgent's own daemon (`BUILD_AGENT_DOCKERD=1`). One slot only. |
| Linux lifecycle | `New-LinuxRunner.ps1` drains by withdrawing labels, replaces the container, restores the labels. `-Update` uses `build-agent update`. `docker run --restart unless-stopped`. |
| Windows runners | `Setup-WindowsRunners.ps1 -Count` (1–16, default 2), instances `win01`, `win02`, each its own clone under `%LOCALAPPDATA%\SubZeroDev\Runners`, registered to `AbsoluteZeroDev`. Lowering `-Count` never removes an instance. Supervisors are started directly; nothing starts them again after a restart. |
| BuildAgent on Windows | `Invoke-BuildAgent.ps1 -Type -Source -CopyOutputTo`: mirrors the checkout into the instance's workspace, takes a per-instance mutex, runs `build-agent build <type>` in a Linux container, passes the exit code through, copies `artifacts` out. `SZR_SCRIPTS` points at the scripts folder. |
| Settings | `runners.json`, with `runners.local.json` (git-ignored, per machine) merged over it setting by setting and validated by `RunnerConfig.ps1`. |
| Telemetry | SubZeroDev.Dashboard `runner-telemetry-v1`: a sender on the host reads `Manage-WindowsRunner.ps1 -Action Status -Json` and `Get-BuildAgentStatus.ps1 -Json` and POSTs one snapshot per `hostId` (at most 32 instances). Linux is not reported. |

The gaps are: Linux is one slot, counts are not per-host settings, lowering a count does nothing, the
Windows supervisors do not come back after a reboot, and Linux slots are missing from telemetry.

## The build model: BuildAgent does the work, hooks do the rest

No new build type and no BuildAgent change. Each repository describes its build with BuildAgent's
existing extension points:

| Stage | Where | What runs |
| --- | --- | --- |
| Before | `set-environment.ps1` (every type except `node-template`), `.build/.build.env.map` | Environment, feed tokens. Only names in the launcher's list or a map file reach the container. |
| Build | `.build/.build.scripts` → `.build/build.ps1` | Everything that does not need Windows: npm/pnpm, `dotnet test`, and Windows-targeted builds with `-p:EnableWindowsTargeting=true`. |
| After (container) | `.build/.build.copy` | Hands outputs to `artifacts/<last folder name>`. |
| After (host) | Workflow steps on a Windows slot | Only Windows-only work: WPF/WinForms tests against the container's binaries, signing, installers. |

`.build.scripts` line rules matter: lines starting with npm, pnpm, yarn, bash/sh, `pwsh -c`, or ending
in `.ps1` are dispatched to that tool; anything else is run as a bare program with no arguments, so put
`dotnet …` in `build.ps1`, not on its own line. The `node` chain is Clean → GenerateEnvironment →
BuildApplication → CopyToArtifacts, and Clean wipes `artifacts`.

**Proven on HollowMoon** ([AbsoluteZeroDev/SubZeroDev.HollowMoon#4](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/pull/4)):
the pinned image ran `build node` and exited 0 — 140 game tests, 23 Core tests, and the WPF App and
App.Tests projects compiled on Linux with 0 warnings. The Windows host then ran the 12 WPF tests
against those binaries. That repository's `.build/` and `build.yml` are the template for the rest.

Where a job runs:

- **All-Linux repositories** run on `subzerodev-linux` and call `build <type>` straight in the checkout
  (the slot is the BuildAgent image; `build` uses the current directory). No launcher, no copy.
- **Repositories with Windows-only steps** run on `subzerodev-windows`, call `Invoke-BuildAgent.ps1` for
  the build, then run the Windows-only steps on `artifacts` copied to `$RUNNER_TEMP`.

## Per-host settings

Counts and the host's identity go in `runners.local.json`, the file every script already reads. No new
settings file. `runners.json` gains the defaults:

```json
{
  "hostId": null,
  "linux":   { "count": 2 },
  "windows": { "count": 2 }
}
```

Beast's `runners.local.json`:

```json
{
  "hostId": "beast",
  "github": { "url": "https://github.com/AbsoluteZeroDev" },
  "linux":   { "count": 2, "cpus": 4, "memory": "8g", "docker": { "mode": "dind" } },
  "windows": { "count": 2 }
}
```

- `count` defaults to 2; `0` turns that side off on this host. Validation: 0–16, the same ceiling as
  `-Count`.
- `hostId` is required once there is more than one host. It names runners and keys telemetry; it
  defaults to the lower-cased computer name.
- `cpus` and `memory` are per slot. Two slots at 4 CPUs / 8g (dind: daemon inside the slot) is 16g.
  In sidecar mode add the sidecar's 4g per slot.

## Linux slots

Each slot is one runner with its own registration, container, volumes and maintenance file. The single
runner becomes slot 01.

| Item | Slot `n` (two digits) |
| --- | --- |
| Runner name | `subzerodev.runner.linux.<hostId>.<n>` |
| Registration directory | `linux/runner-<n>` (bind-mounted at `/runner`) |
| Container | `subzerodev-runner-linux-<n>` |
| Volumes | cache, dind data (or sidecar data/certs/work) suffixed `-<n>` |
| Labels | `subzerodev`, `subzerodev-linux`, plus `linux.labels` — the same for every slot |

**Compose with `restart: always`.** `New-LinuxRunner.ps1` writes `linux/compose.local.yaml`
(git-ignored) from the merged settings — one service per slot, plus a sidecar per slot in sidecar
mode — and the project `subzerodev-runners` is brought up with `docker compose`. Docker Desktop starts
at sign-in and brings every slot back; no scheduled task is needed for Linux. The image and every
`FROM` stay pinned by digest.

The drain logic stays as it is, per slot: withdraw that slot's labels, wait for its job, then
`docker compose up -d --no-deps --force-recreate <slot>`, then restore its labels. A slot in maintenance
that Docker restarts (`always` brings back a stopped container when Docker restarts) still has its
labels withdrawn at GitHub, so it takes no jobs until maintenance ends.

**Docker mode.** Both modes stay. For slots, `dind` is the default: one privileged container per slot,
its own daemon and data volume, no shared Docker state between slots, half the containers. `sidecar`
remains for a host where a privileged runner is not wanted.

**Migration of the existing runner.** Slot 01 takes over `linux/runner`'s registration (moved to
`linux/runner-01`) and the existing volumes. Its name changes, so `Register-Runners.ps1` does what it
already does on a name change: drain, deregister, register again.

## Windows slots

`windows.count` drives the existing multi-instance setup (`win01` … `winNN`); the host manager calls
`Setup-WindowsRunners.ps1 -Count <windows.count>`. Two things are added:

- **Scaling down.** Lowering the count drains the highest-numbered instances first, deregisters them and
  stops their supervisors. The clone and work folder are kept until the next `Apply -Prune`, so nothing
  is deleted by a count change alone.
- **Start after a reboot.** A per-user Startup entry (not elevated, not a service) runs
  `Manage-RunnerHost.ps1 -Action Start` at sign-in. It waits for `docker info` (up to
  `buildAgent.docker.readyTimeoutSeconds`), then runs `Manage-WindowsRunner.ps1 -Action Start` in each
  instance clone, so the first job can call BuildAgent. An instance held in maintenance stays held. This
  reverses the current "explicit Start only" choice for hosts that opt in (`windows.startAtSignIn: true`);
  a supervisor that dies while signed in still waits for an explicit Start, as today.

The Linux slots belong to the clone that runs the host manager (on beast, the existing Runners clone);
each Windows instance keeps its own clone under `%LOCALAPPDATA%\SubZeroDev\Runners`.

## Host manager

`Manage-RunnerHost.ps1 -Action Plan|Apply|Status|Start [-Prune] [-Json]` — one entry point over the
existing scripts, not a replacement for them.

- **Plan** reads the merged settings, Docker, both sides' registrations and GitHub, and prints what Apply
  would do: slots to add, recreate, drain, deregister. Changes nothing. Exit 0 when nothing to do, 3 when
  there is.
- **Apply** does the plan: builds the Linux image if `runnerVersion` or the base digest changed, writes
  the compose file, registers new slots, drains and removes surplus slots highest-first, brings the
  compose project up, runs `Setup-WindowsRunners.ps1 -Count`. Reuses `Register-Runners.ps1`,
  `New-LinuxRunner.ps1`, `Lifecycle.ps1` — nothing is drained or registered by new code paths.
- **Status** is one row per slot on both sides: name, local state, GitHub online/busy, maintenance,
  BuildAgent readiness. `-Json` is what telemetry reads.

## Beast after a reboot

1. Windows signs in automatically (set by the owner; setup never configures auto sign-in).
2. Docker Desktop starts at sign-in; the compose project's `restart: always` brings up every Linux slot.
3. The Startup entry waits for `docker info`, then starts the Windows supervisors.
4. `%UserProfile%\.wslconfig` caps the WSL2 VM, which holds every Linux slot and every BuildAgent
   container the Windows slots start: `memory=64GB` and `processors=` about half the cores leaves the
   rest of the 128 GB for Windows jobs. The host manager's Plan warns when the slots' `memory` total
   plus one BuildAgent container per Windows slot exceeds that cap.

## Telemetry

Keep the Dashboard's v1 contract and sender. Add `Get-LinuxRunnerStatus.ps1 -Json`, one row per slot in
the same shape as the Windows status rows (`instanceId` `linux-01`, `linux-02` …), and have the sender
read `Manage-RunnerHost.ps1 -Action Status -Json` instead of the two producers. If the Dashboard's
strict schema cannot carry Linux slots as they are (for example it needs a platform field), that is a
v2 contract change in SubZeroDev.Dashboard, made there, not here.

## Rollout across AbsoluteZeroDev

| Repository | Runs on | Build |
| --- | --- | --- |
| SubZeroDev.HollowMoon | Windows slot | `Invoke-BuildAgent -Type node`; WPF tests on the host. `release.yml` moves next: BuildAgent step, copy `dist` back to `outputs/moonstone-mvp/dist`, then `Build-Installer.ps1 -SkipGame` and signing. |
| SubZeroDev.HotCorners | Windows slot | Build and non-UI tests in BuildAgent with `EnableWindowsTargeting`; UI tests on the host. |
| SubZeroDev.Cleaner | Windows slot | `dotnet publish -r win-x64` in BuildAgent; signing and installer on the host. |
| SubZeroDev.Licensing | Linux slot | `build <type>` in the checkout. |
| SubZeroDev.Media | Linux slot | `build <type>` in the checkout. |

One repository at a time, in that order, each its own PR in its own repository. A repository moves
only after its BuildAgent build has passed once locally against the pinned image.

## Decisions and limits

- The org is on GitHub Free: one runner group (Default), so labels are the only routing. Every slot on a
  side carries the same labels; GitHub picks any idle one.
- Every slot on a host shares the host's Docker Desktop. A runaway job can starve the others; `cpus` and
  `memory` per slot are the guard.
- `--privileged` (dind) gives jobs root in Docker Desktop's VM. Private repositories of this org only.
- Nothing here changes BuildAgent. A BuildAgent release only moves `buildAgent.image` and
  `linux.baseImage` to a new digest.
