# Design

The full design is [docs/runner-pool-plan.md](../docs/runner-pool-plan.md); the slice-level build notes are
[handoffs/runner-pool.md](../handoffs/runner-pool.md). This file records the shape that every slice builds against.

## Binding decisions

- Owner decisions (2026-11-10): D1 runner group `Default`, all private repositories, moving to an allowlist when
  anyone else gets write access; D2 surplus slots retired only with `-Retire`, Apply exits 3 on surplus otherwise;
  D3 sign-in start through a per-user Startup entry; D4 BuildAgent is not changed.
- C1: the host manager never calls `Setup-WindowsRunners.ps1`. It changes one Windows instance per operation and never
  a held instance (`deferred: held`). Setup refuses when an inventory exists. Slot numbers are never reused.
- C2: one writer per settings file. `runners.local.json` in a Windows clone stays Install-owned; the manager writes
  `runners.host.json`. Resolution is `runners.json` < `runners.host.json` < `runners.local.json`.
- C3: containers are identified by full ID and name, plus labels for containers the manager created.
- C4: an operation journals `heldBefore` and ends only maintenance it started; Hold and Resume refuse during an
  unfinished operation.

## Components

- Settings: `scripts/RunnerConfig.ps1` (`Read-RunnerConfig`, `Assert-RunnerConfig`), slot resolution
  (`Get-LinuxSlots`, `Get-WindowsSlots`), `New-HostSettings`, `Test-HostSettingsDrift`.
- Host state: `scripts/HostState.ps1` (inventory, journal, `Use-HostLock`) under
  `%LOCALAPPDATA%\SubZeroDev\Runners\host\`.
- Host manager: `scripts/Manage-RunnerHost.ps1` with Init, Adopt, Plan, Status, Apply, Hold, Resume, AutoStart,
  Update.
- Linux slots: `scripts/New-LinuxRunner.ps1` writes `linux/compose.local.yaml`; `linux/entrypoint.sh` waits while
  held.
- Windows slots: `scripts/Manage-WindowsRunner.ps1 -Action AutoStart`, plus the existing `Install-WindowsRunner.ps1`
  and `WindowsRunnerSetup.ps1` instance helpers.
- Drains through `scripts/Lifecycle.ps1`; registrations through `scripts/Registration.ps1`.

## Status versus cause

Observed runner status and its explanation are recorded separately. A cause is written as not verified until
evidence proves it.
