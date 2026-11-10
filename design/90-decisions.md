# Decision log

Append-only. Newest at the top. The rejected alternatives are the point — without them, every future session relitigates the same choice.

## Open
<Questions still undecided. A *todo* noticed while building is a GitHub issue, not an entry here.>

---

### 2026-11-10 — S1: housekeeping.minFreeGB stays 10 in runners.json; null means no free-space check
Context: the handoff lists `housekeeping.minFreeGB` with default null, but runners.json already ships 10 and `scripts/Housekeeping.ps1` acts on it.
Chosen: keep 10, accept null (no check) or any non-negative number, so today's housekeeping is unchanged.
Rejected: changing the default to null, which would silently switch off the free-space check on every existing host.

### 2026-11-10 — S1: existing Linux scripts keep reading linux.container and the volume names until S4/S5
Context: the handoff says no script reads `linux.container`, `linux.directory` or volume names directly after S1, but `scripts/Common.ps1`, `New-LinuxRunner.ps1` and the lifecycle scripts drive today's single legacy runner by those names, and S4 (compose) and S5 (legacy migration) are where they move to slots.
Chosen: add `Get-LinuxSlots`/`Get-WindowsSlots` as the resolution every new caller uses; leave the legacy readers untouched until S4/S5 replace them.
Rejected: rewiring the legacy scripts onto slots now, which changes the running runner's behaviour in a slice whose scope excludes any host mutation.

### 2026-11-10 — S1: -HostId never renames an installed Windows runner
Context: `Setup-WindowsRunners.ps1 -HostId` builds `subzerodev.runner.windows.<hostId>.winNN`, but an instance already installed has `windows.name` saved in its Install-owned runners.local.json.
Chosen: pass the hostId name to Install only when no `windows.name` is saved; labels use hostId either way. Omitting -HostId passes no name and keeps the computer-name labels, exactly as before.
Rejected: renaming on rerun, which re-registers a live runner outside the journaled per-instance path S6 adds.
