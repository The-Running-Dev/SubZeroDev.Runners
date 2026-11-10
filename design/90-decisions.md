# Decision log

Append-only. Newest at the top. The rejected alternatives are the point â€” without them, every future session relitigates the same choice.

## Open
<Questions still undecided. A *todo* noticed while building is a GitHub issue, not an entry here.>

---

### 2026-11-10 - S3: a maintenance record holds by existing, and only Resume (or Start) deletes it
Context: Docker restarts and sign-in must never start a listener under a held runner, and an unreadable record must not read as "not held".
Chosen: the Linux entrypoint and Windows AutoStart treat any maintenance.json as held without parsing it. Manage-WindowsRunner AutoStart starts the supervisor with Start-WindowsRunner -KeepMaintenance (it idles with no listener); Start still ends maintenance. Host Hold and Resume run under a joinable host lock, refuse a slot with an unfinished operation (C4) and point to Apply. Hold stops the runner container first, then the sidecar; Resume starts the sidecar first. Resume over an unreadable record refuses with the existing "kept" message before starting anything. windows.startAtSignIn is a per-user Startup .cmd running host AutoStart (no task, service or elevation).
Rejected: parsing the record in the entrypoint (a corrupt file would start a listener), a scheduled task or service for sign-in (needs elevation, was removed in S1), and making AutoStart call Start (it would end maintenance on every reboot).
### 2026-11-10 — S2: the host lock carries a join token in lock.json and is named per state directory
Context: The handoff's lock is one machine-wide mutex; setup starts child scripts (Install, Manage-WindowsRunner) that must not deadlock on their parent, and tests need a lock of their own.
Chosen: a joinable holder writes a token to lock.json and SZR_HOST_OPERATION; a child joins only when the token matches and the recorded pid is alive with the same start time. The mutex name hashes the lowercased state directory, so another LOCALAPPDATA is another lock. A non-joinable holder clears an inherited token and restores it on exit.
Rejected: an environment flag alone (any process could claim it), and one global mutex name (tests would touch the real host lock).

### 2026-11-10 — S2: the Windows runner of this checkout is slot windows-legacy, outside numbering
Context: Adopt must record the pre-pool runner without it taking a number from the clones win01..winNN.
Chosen: slotId `windows-legacy`; it is skipped by numbering and by drift, and Plan retires it only after win01 is online and with -Retire.
Rejected: numbering it win00 or win01, which collides with the first clone.

### 2026-11-10 — S2: Adopt refuses a readable inventory, and an unreadable one unless -ReplaceUnreadable
Context: An inventory is the host's ownership record; Adopt over it could drop slots.
Chosen: Adopt only creates the first inventory. With -ReplaceUnreadable the unreadable file is kept as inventory.json.unreadable-<stamp> beside the new one. Adopt records a registration only when its .runner agentId equals GitHub's id for that name, and writes nothing when GitHub or Docker cannot be read.
Rejected: merging into an existing inventory, and treating an unreadable one as absent.

### 2026-11-10 — S2: the setup worker takes the joinable lock and rechecks the inventory; the bootstrap's pre-worker steps run unlocked
Context: Setup-WindowsRunners.ps1 (5.1) cannot load HostState.ps1 before the PowerShell 7 worker exists.
Chosen: the 5.1 entry refuses early on an existing inventory; the worker re-checks under the lock. Prerequisite installs before the worker are not locked.
Rejected: porting the lock to 5.1.

### 2026-11-10 — S2: Plan exits 1 on unreadable state, 3 when there are changes; Status reports offline without a cause
Context: Unknown must not read as absent, and an unverified explanation must not be presented as fact.
Chosen: Plan: 0 no changes, 3 changes, 1 unreadable inventory or journal. Status carries only GitHub's status and busy. Compose drift is not applicable before S4. Init writes the checkout's runners.local.json. Manage-WindowsRunner locks every action except Status; the supervisor clears SZR_HOST_OPERATION.
Rejected: a cause field on offline runners, and exiting 0 on unreadable state.

### 2026-11-10 â€” S1: housekeeping.minFreeGB stays 10 in runners.json; null means no free-space check
Context: the handoff lists `housekeeping.minFreeGB` with default null, but runners.json already ships 10 and `scripts/Housekeeping.ps1` acts on it.
Chosen: keep 10, accept null (no check) or any non-negative number, so today's housekeeping is unchanged.
Rejected: changing the default to null, which would silently switch off the free-space check on every existing host.

### 2026-11-10 â€” S1: existing Linux scripts keep reading linux.container and the volume names until S4/S5
Context: the handoff says no script reads `linux.container`, `linux.directory` or volume names directly after S1, but `scripts/Common.ps1`, `New-LinuxRunner.ps1` and the lifecycle scripts drive today's single legacy runner by those names, and S4 (compose) and S5 (legacy migration) are where they move to slots.
Chosen: add `Get-LinuxSlots`/`Get-WindowsSlots` as the resolution every new caller uses; leave the legacy readers untouched until S4/S5 replace them.
Rejected: rewiring the legacy scripts onto slots now, which changes the running runner's behaviour in a slice whose scope excludes any host mutation.

### 2026-11-10 â€” S1: -HostId never renames an installed Windows runner
Context: `Setup-WindowsRunners.ps1 -HostId` builds `subzerodev.runner.windows.<hostId>.winNN`, but an instance already installed has `windows.name` saved in its Install-owned runners.local.json.
Chosen: pass the hostId name to Install only when no `windows.name` is saved; labels use hostId either way. Omitting -HostId passes no name and keeps the computer-name labels, exactly as before.
Rejected: renaming on rerun, which re-registers a live runner outside the journaled per-instance path S6 adds.

### 2026-11-10 â€” S2 review: entry scripts release the host lock in finally; Install and Remove-LegacyTasks take it
Context: independent review found entry scripts that took the lock and returned without releasing it, so a later command in the same prompt waited on a dead holder; Install-WindowsRunner and Remove-LegacyTasks took no lock at all.
Chosen: every entry script wraps its body in try/finally with Exit-HostLock (Manage-WindowsRunner only when it took one, never for Status); Install-WindowsRunner and Remove-LegacyTasks take the lock. A test runs an entry script from a prompt and checks the lock is gone.
Rejected: relying on process exit to free the lock.

### 2026-11-10 â€” S2 review: an unproven registration reserves its slot number as an `unowned` slot
Context: Adopt dropped a registration whose .runner id GitHub did not confirm, so Plan could add a new slot on the same number and register over it.
Chosen: Adopt records it with state `unowned`, no runnerId; Plan skips its number and never changes it. An unreadable .runner is `unknown`, and Adopt stops writing nothing. A failed write leaves the original unreadable inventory in place (Copy-Item, not Move-Item).
Rejected: ignoring unproven registrations.

### 2026-11-10 â€” S2 review: Plan exit 1 when anything it needs cannot be read; findings are in the planHash
Context: a Plan over an unreadable Docker or clone said "No changes", and its hash equalled a clean host's.
Chosen: any `unknown` finding exits 1 ("Plan is incomplete"); drift/blocked findings exit 3; the hash covers changes plus unknown/drift/blocked findings. A recorded Linux container that is gone, or a Linux slot with no container record, is container drift.
Rejected: treating unread state as absent.
