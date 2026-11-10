# Handoff: per-host runner pool (N Linux slots, N Windows slots)

For this repository, SubZeroDev.Runners. The design is [docs/runner-pool-plan.md](../docs/runner-pool-plan.md);
read it first. Follow this repository's own conventions: settings through `RunnerConfig.ps1`, drains through
`Lifecycle.ps1`, registrations through `Register-Runners.ps1`/`Registration.ps1`, a `tests/Test-*.ps1` with a fake
Docker/GitHub for every script that changes, and a line in `windows-runner-validation.yml` for each new test.

## Goal

Each host runs `linux.count` BuildAgent-based Linux runners and `windows.count` native Windows runners, both set in
that host's `runners.local.json` (default 2 each). Raising a count adds slots; lowering it drains the highest-numbered
slots and deregisters them. After a reboot with auto sign-in, every slot comes back without anyone touching it.
BuildAgent is not changed.

## Who uses the runners today (must keep working)

- **The Linux runner** `subzerodev.runner.linux` (container `subzerodev-runner-linux`, registration in `linux/runner`),
  used by `tests/linux-runner-docs-smoke.yml` through ActionTemplates `docs.yml` with `runs-on: subzerodev-linux`.
- **The Windows instances** `win01`, `win02` from `Setup-WindowsRunners.ps1`, and `Install-WindowsRunner.ps1` on
  machines with no Docker.
- **[AbsoluteZeroDev/SubZeroDev.HollowMoon#4](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/pull/4)**:
  `runs-on: [self-hosted, subzerodev, Windows]`, calls `"$env:SZR_SCRIPTS\Invoke-BuildAgent.ps1" -Type node
  -CopyOutputTo "$env:RUNNER_TEMP\buildagent"`. `SZR_SCRIPTS`, `Invoke-BuildAgent.ps1`'s parameters and the labels
  `subzerodev`, `subzerodev-linux`, `subzerodev-windows` do not change.
- **SubZeroDev.Dashboard telemetry v1**, which reads `Manage-WindowsRunner.ps1 -Action Status -Json` and
  `Get-BuildAgentStatus.ps1 -Json`. Their output shapes do not change.

## What to build (one PR per slice, in order)

1. **Settings.** Add `hostId` (default: lower-cased computer name), `linux.count` and `windows.count` (default 2,
   range 0–16) and `windows.startAtSignIn` (default false) to `runners.json` and `Assert-RunnerConfig`. Add name
   templates resolved per slot: Linux runner `subzerodev.runner.linux.<hostId>.<nn>`, container
   `subzerodev-runner-linux-<nn>`, directory `linux/runner-<nn>`, every volume name suffixed `-<nn>`. One helper,
   `Get-LinuxSlots $Config`, returns the resolved slots; every script uses it instead of reading `linux.container`,
   `linux.directory` or the volume names directly. With `linux.count` 1 and no `hostId` nothing is renamed yet.
2. **Linux slots in compose.** `New-LinuxRunner.ps1` writes `linux/compose.local.yaml` (add it to `.gitignore` and
   `dropbox-ignore.txt`) with one service per slot (and one sidecar per slot in sidecar mode), `restart: always`,
   the same mounts, environment, limits and privileged/dind settings that its `docker run` lines use today, and runs
   `docker compose -p subzerodev-runners up -d`. `-Slot <nn>` limits a replace to one slot; the drain, label
   withdrawal and restore stay per slot through `Enter-RunnerMaintenance`/`Exit-RunnerMaintenance`, and the replace is
   `docker compose up -d --no-deps --force-recreate <service>`. `Stop-Runners.ps1`, `Start-Runners.ps1`,
   `Test-LinuxRunnerBusy` and housekeeping loop over the slots. `-Update` keeps using `build-agent update`, one slot
   at a time.
3. **Migrate the single runner.** When `linux/runner/.runner` exists and `linux/runner-01` does not: drain it, stop the
   old container, move the registration to `linux/runner-01`, keep its volumes as slot 01's (rename by copying into
   the `-01` volumes, or map slot 01 to the old names — say which), then `Register-Runners.ps1` re-registers it under
   the new name as it does for any name change. The old container is removed only after slot 01 is online.
4. **Register N Linux slots.** `Register-Runners.ps1` registers every slot in `Get-LinuxSlots`, each from a throwaway
   container on its own `/runner` mount, as it does for the single runner now. A slot above `linux.count` is drained,
   deregistered and its container removed, highest number first; its directory and volumes are kept until
   `-Prune`.
5. **Windows scale-down and sign-in start.** Lowering `windows.count` drains the highest-numbered instances through
   `Manage-WindowsRunner.ps1`, deregisters them and stops their supervisors; their clones stay until `-Prune`. With
   `windows.startAtSignIn` a per-user Startup entry (no elevation, no scheduled task, no service) runs
   `Manage-RunnerHost.ps1 -Action Start`, which waits for `docker info` up to `buildAgent.docker.readyTimeoutSeconds`
   and then starts each instance; held instances stay held. Remove the entry when the setting goes back to false.
6. **Host manager.** `scripts/Manage-RunnerHost.ps1 -Action Plan|Apply|Status|Start [-Prune] [-Json]` as described in
   the plan. Plan changes nothing and exits 0 (nothing to do) or 3 (changes pending). Apply only calls the scripts
   above and `Setup-WindowsRunners.ps1 -Count`. Plan warns when the Linux slots' `memory` plus one BuildAgent
   container per Windows slot exceeds the WSL2 memory cap read from `%UserProfile%\.wslconfig` (or Docker's own
   total when there is no file). It never edits `.wslconfig`, auto sign-in or Docker Desktop settings.
7. **Linux status and telemetry.** `scripts/Get-LinuxRunnerStatus.ps1 -Json`: one row per slot in the shape of the
   Windows status rows, `instanceId` `linux-<nn>`. `Manage-RunnerHost.ps1 -Action Status -Json` returns both sides.
   Point the Dashboard sender at it only if its v1 schema accepts these rows as they are; if it does not, stop and
   write a handoff for SubZeroDev.Dashboard instead of changing the shape here.
8. **Docs.** README: the per-host settings, the host manager, the slot names, the reboot sequence. Update
   `docs/windows-two-runners.md` for scale-down and sign-in start.

## Contract

| Item | Value |
| --- | --- |
| Per-host file | `runners.local.json` (git-ignored), merged over `runners.json` |
| Counts | `linux.count`, `windows.count`: 0–16, default 2, 0 = that side off |
| Host | `hostId`, default the lower-cased computer name |
| Linux slot `nn` | runner `subzerodev.runner.linux.<hostId>.<nn>`, container `subzerodev-runner-linux-<nn>`, directory `linux/runner-<nn>`, volumes `…-<nn>` |
| Windows instance | `win<nn>`, as `Setup-WindowsRunners.ps1` names them today |
| Labels | unchanged: `subzerodev` + `subzerodev-linux` / `subzerodev-windows` + any custom labels, identical on every slot of a side |
| Compose | project `subzerodev-runners`, file `linux/compose.local.yaml`, `restart: always` |
| Scale-down order | highest-numbered slot first, drained before deregistration |
| Host manager | `scripts/Manage-RunnerHost.ps1 -Action Plan\|Apply\|Status\|Start [-Prune] [-Json]` |
| Unchanged | `Invoke-BuildAgent.ps1` parameters, `SZR_SCRIPTS`, both existing `-Json` status shapes, digests pinned, never `:latest` |

## Tests

- Settings: defaults, per-host override, count 0, 17 refused, bad `hostId` refused, slot names resolved for 1, 2, 16.
- Compose file: generated from fake settings for both Docker modes and compared with the `docker run` arguments the
  current script uses (mounts, environment, limits, privileged, `restart: always`), including paths with spaces.
- Drain per slot with a fake Docker and GitHub: a busy slot 02 blocks only slot 02; timeout keeps it; `-Force` replaces.
- Migration: existing `linux/runner` becomes slot 01 with its registration; nothing is removed when a step fails.
- Scale 2→3→1 on each side: the new slot registers; slots 03 then 02 drain and deregister in that order; files kept;
  `-Prune` removes them.
- Sign-in start: waits for a fake `docker info`, times out with a message, leaves a held instance held.
- Plan is read-only (no fake Docker/GitHub write calls) and its exit codes; the memory warning.
- Status `-Json` for both sides; the existing Windows and BuildAgent status outputs byte-for-byte unchanged.
- On beast, recorded in the PR: Apply with counts 2/2, both Linux slots and both Windows instances online in the org,
  a reboot with auto sign-in brings all four back, and HollowMoon's `build.yml` passes on a Windows slot while a
  Linux slot runs `tests/linux-runner-docs-smoke.yml`.

## Release

Merge slice by slice through this repository's PR flow. Beast moves to the pool by setting `hostId` and the counts in
its `runners.local.json` and running `Manage-RunnerHost.ps1 -Action Plan`, then `Apply`. Repositories move to the
runners one PR at a time in the order in the plan, each in its own repository.
