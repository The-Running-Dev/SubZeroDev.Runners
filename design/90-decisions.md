# Decision log

Append-only. Newest at the top. The rejected alternatives are the point — without them, every future session relitigates the same choice.

## Open
<Questions still undecided. A *todo* noticed while building is a GitHub issue, not an entry here.>

---

### 2026-11-24 - S9: run L3 from the D:\Temp checkout the owner chose, so the pre-pool runners stay unowned and step 2 does not apply
Context: The host manager acts on the checkout it runs from (`scripts/Common.ps1` `$Root`). Beast's pre-pool registrations (`linux/runner/.runner`, `windows/.runner`, and `github.url` in `runners.local.json`) are only in `D:\Dropbox\Projects\SubZeroDev.Runners`. The owner chose `D:\Temp\SubZeroDev.Runners` when asked.
Chosen: Run every L3 step from `D:\Temp\SubZeroDev.Runners`. Its git-ignored `runners.local.json` was given the live install's `github.url`, `windows.workFolder` and `linux.docker.mode: dind`; without `github.url`, Apply has no scope to register into. Adopt proved no slot. Runners 8 and 9 are reported unowned and left alone. Step 2 (the migration) is recorded as not applicable: there was no pre-pool registration in this checkout and no pre-pool container in Docker. Step 3's single-clone case is the unproven one: reported, not retired.
Rejected: Running from the Dropbox checkout, which the owner declined. Copying the pre-pool `.runner` and credentials into `D:\Temp`, which would put a second copy of a live registration on disk.

### 2026-11-24 - S9: work around two gaps with the functions the tools use, and keep the evidence commit out of the slots
Context: On a fresh host neither Apply nor Update builds the Linux image (#32). The docs smoke controller probes the pre-pool container name, not the slot's (#33). Committing evidence on the branch moves this checkout's HEAD, which Status reports as `commit` drift on the Windows clones.
Chosen: Build the image with `Get-LinuxImageBuild` and `Invoke-LinuxImageBuild` (`scripts/Compose.ps1`), then run `Apply -ExpectPlan` on the unchanged plan. Dispatch `self-hosted-docs-smoke.yml` directly with the inputs the controller passes, and let its `verify` job check the evidence. Run HollowMoon's `build.yml` from a throwaway branch that changes only `runs-on`, with no PR, deleting the branch afterwards. Run step 7 with the checkout detached at `5324104`, the clones' commit, whose scripts are identical to the branch.
Rejected: `New-LinuxRunner.ps1 -Build`, which with no compose slot goes on to create a pre-pool `docker run` container. Fixing #32 and #33 in this slice, which is acceptance only. Letting step 7's Apply update the clones to the evidence commit, which would mix an update into the retire test.

### 2026-11-24 - S6: add and retire slots as journaled operations; retire only with -Retire; prune only retired slots
Context: Apply must bring the host to the wanted slot counts, survive a kill at any step, never mistake a container it did not create (or cannot read) for free space, and never deregister a runner unasked.
Chosen: Apply runs add-slot (provision, register, create, verify, commit) and retire-slot (withdraw, drain, stop, deregister, clear-local, remove-containers, commit) under the host lock, one journal at a time; a rerun resumes the journal by kind. Preflight refuses an add, before any change, on a public runner group, low disk (housekeeping.minFreeGB), a missing image, or a target container name that is foreign or whose state is unknown. Verify needs the recorded container running and GitHub reporting the recorded runner ID online; a failed verify keeps the journal. Surplus slots are retired, highest number first, only with -Retire (otherwise exit 3); a drain timeout deletes the journal and reopens admission. Deregistration deletes by recorded ID and treats 404 as done. Each Windows slot gets its own clone at InstallRoot\winNN. -Prune removes what a retired slot left (directory, volumes, network, Windows clone) and marks it pruned; a partial prune keeps it retired. -ExpectPlan refuses when the plan hash differs. Slot numbers are never reused.
Rejected: retiring by default (deregistration is the one step a rerun cannot undo, D2); deregistering by name (another host's runner of that name); removing volumes at retire (no inspection afterwards); reusing a pruned slot's number (GitHub history and logs would mix two runners); one shared Windows clone (C1).
### 2026-11-23 - S5: migrate the pre-pool runner by stop-then-create under a journal; keep the old containers until -Prune
Context: linux-01 still runs as the pre-pool containers; moving it onto compose must keep its registration, never run two listeners for one runner, survive a kill at any point and leave a way back until the new runner is proven.
Chosen: Manage-RunnerHost -Action Apply runs migrate-legacy-linux as six journaled steps (drain, stop-legacy, compose-up, end-maintenance, verify, commit). heldBefore is journaled before maintenance is entered, and maintenance is ended only when this operation began it. The pre-pool containers are stopped (restart off) before the compose containers are created, sharing the registration directory and volumes. A rerun of Apply resumes the journal; a drain timeout deletes it and reopens admission. Apply -Rollback is allowed until verify is done, removes only containers whose ID the journal recorded or that carry this host's compose labels, and restarts the old ones. Commit records the old containers as keptForRollback; Apply -Prune removes one only when its recorded ID still names a stopped container of the recorded name, and keeps renamed, running or unknown ones. Preflight refuses, before any change, a missing image, a renamed or unknown legacy container, or a foreign container at a target name. New-LinuxRunner refuses while an operation is unfinished.
Rejected: create-then-stop (two listeners for one registration); re-registering under a new name (loses runner ID and history; -RenameLegacy stays out of scope); removing the old containers at commit (no way back); removing by name (C3); rollback after verify (the new runner has taken jobs).
### 2026-11-10 - S4: one container spec drives docker run and compose; compose only for inventory slots
Context: the Linux runner must be recreated per slot without touching its neighbours, and an image must not outlive the files it was built from.
Chosen: Get-LinuxContainerSpecs is the single description of a runner and its sidecar; ConvertTo-DockerRunArguments (legacy) and ConvertTo-LinuxComposeYaml (compose) both read it, so they cannot drift. Compose is used only for non-legacy inventory slots, with external pre-created volumes and networks, restart always, and every call `up -d --no-deps <named services>` (no `down`, ever). The image carries a label with a SHA-256 over the files root .dockerignore admits plus BASE_IMAGE, RUNNER_VERSION and RUNNER_SHA256; New-LinuxRunner rebuilds on mismatch or -Build, and Get-LinuxRunnerStatus reports drift, with not-checked (never ok) when a check cannot be made. -Update refuses a container compose manages, or one whose state cannot be determined. Recreate records container role/id entries in the inventory, as the host manager reads them.
Rejected: migrating the pre-pool runner here (S5); a compose `down` or project-wide `up` (would touch other slots); auto-rebuilding on the legacy path (only -Build, which now labels the image).
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

### 2026-11-10 — S2 review: entry scripts release the host lock in finally; Install and Remove-LegacyTasks take it
Context: independent review found entry scripts that took the lock and returned without releasing it, so a later command in the same prompt waited on a dead holder; Install-WindowsRunner and Remove-LegacyTasks took no lock at all.
Chosen: every entry script wraps its body in try/finally with Exit-HostLock (Manage-WindowsRunner only when it took one, never for Status); Install-WindowsRunner and Remove-LegacyTasks take the lock. A test runs an entry script from a prompt and checks the lock is gone.
Rejected: relying on process exit to free the lock.

### 2026-11-10 — S2 review: an unproven registration reserves its slot number as an `unowned` slot
Context: Adopt dropped a registration whose .runner id GitHub did not confirm, so Plan could add a new slot on the same number and register over it.
Chosen: Adopt records it with state `unowned`, no runnerId; Plan skips its number and never changes it. An unreadable .runner is `unknown`, and Adopt stops writing nothing. A failed write leaves the original unreadable inventory in place (Copy-Item, not Move-Item).
Rejected: ignoring unproven registrations.

### 2026-11-10 — S2 review: Plan exit 1 when anything it needs cannot be read; findings are in the planHash
Context: a Plan over an unreadable Docker or clone said "No changes", and its hash equalled a clean host's.
Chosen: any `unknown` finding exits 1 ("Plan is incomplete"); drift/blocked findings exit 3; the hash covers changes plus unknown/drift/blocked findings. A recorded Linux container that is gone, or a Linux slot with no container record, is container drift.
Rejected: treating unread state as absent.

### 2026-11-24 — S7: Update records each replaced digest with its version; a downgrade is judged by version, not by order
Context: a plain list of replaced digests called a move forward after a rollback "Rolling back", and flagged the newer digest restored after a rollback as a downgrade.
Chosen: `inventory.buildAgent.previous` holds `{image, version}`; Update calls it a rollback only when the new version is lower than the recorded one, and Plan/Apply block a settings digest only when it is a replaced one whose version is not newer than the recorded one. Update accepts only `x.y.z`.
Rejected: resolving floating tags, and editing `.wslconfig` or Docker Desktop to fit the memory figures (Plan only reports them; the Windows figure is advisory).