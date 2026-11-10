# Slices

Each slice is one pull request. Build notes and tests for each are in
[handoffs/runner-pool.md](../handoffs/runner-pool.md) under the same number.

## S1 — Settings and resolution
Status: todo
Acceptance: new settings with validation (`hostId`, `linux.count`, `windows.count`, `windows.startAtSignIn`, `github.runnerGroup`, `housekeeping.minFreeGB`, `buildAgent.estimate.memory`); `Get-LinuxSlots` and `Get-WindowsSlots`; `New-HostSettings` and `Test-HostSettingsDrift`; the `runners.host.json` layer in `Read-RunnerConfig`, an absent file resolving exactly as today; `Setup-WindowsRunners.ps1 -HostId`; the handoff's Settings tests pass in CI.
Out of scope: inventory, journal and lock; any host mutation.

## S2 — Host state: inventory, journal, lock, Init/Adopt, Plan/Status
Status: todo
Depends on: S1
Acceptance: `scripts/HostState.ps1` and `scripts/Manage-RunnerHost.ps1` Init, Adopt, Plan and Status as in the handoff; Setup refuses when an inventory exists; the handoff's Host state, Plan is read-only and Runner group tests pass.
Out of scope: Apply, Hold, Resume.

## S3 — Automatic start keeps maintenance
Status: todo
Depends on: S2
Acceptance: the entrypoint waits while held; `Manage-WindowsRunner -Action AutoStart`; host AutoStart; Hold and Resume with the C4 refusal; the `windows.startAtSignIn` Startup entry; the handoff's Maintenance acceptance tests pass.
Out of scope: compose.

## S4 — Compose and the image context hash
Status: todo
Depends on: S3
Acceptance: `linux/compose.local.yaml` generation, per-slot recreate with `--no-deps`, the context hash label, `-Update` refusing compose containers, `Get-LinuxRunnerStatus.ps1 -Json`; the handoff's Compose tests pass.
Out of scope: legacy migration.

## S5 — Legacy Linux migration
Status: todo
Depends on: S4
Acceptance: journaled `migrate-legacy-linux` with `heldBefore`, rollback before verification, removal only by `-Prune` with recorded ID and name; the handoff's migration failure-injection tests pass.
Out of scope: `-RenameLegacy`.

## S6 — Add and retire slots
Status: todo
Depends on: S5
Acceptance: Apply with add and retire operations, `-Retire`, `-Prune`, `-ExpectPlan` and the per-instance Windows path (C1); the handoff's Scale, Ownership, Unknown-is-not-absent, add and retire failure-injection, and Concurrency tests pass.
Out of scope: Update.

## S7 — Updates and resources
Status: todo
Depends on: S6
Acceptance: `Manage-RunnerHost -Action Update` writes the digest before any recreate; Plan reports disk and memory figures, the Windows-side one advisory; the handoff's Updates tests pass.
Out of scope: editing `.wslconfig`, auto sign-in or Docker Desktop settings.

## S8 — Docs
Status: todo
Depends on: S7
Acceptance: the README covers settings, host manager actions, slot names, held and resume semantics, and the reboot sequence; `docs/windows-two-runners.md` covers AutoStart, Retire and Prune.
Out of scope: target-host execution.

## S9 — Target-host acceptance on beast (L3)
Status: todo
Depends on: S8
Blocked by: the owner's go-ahead in chat to run the L3 steps on beast, a real host with live registrations.
Acceptance: the handoff's L3 steps 1–7 run on beast and are recorded in the pull request.
Out of scope: repository workflow changes.
