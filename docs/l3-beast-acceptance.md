# L3 target-host acceptance on beast (S9)

The steps are the handoff's "Target-host acceptance" list ([handoffs/runner-pool.md](../handoffs/runner-pool.md)). They ran
on beast on 2026-11-24, from `D:\Temp\SubZeroDev.Runners` at `5324104` on branch `slice/S9-l3-beast`. Each step lists
the commands run, their exit codes, slot states, runner IDs and run links. Times are UTC.

## Host before the run

| Item | State |
| --- | --- |
| Checkout | `D:\Temp\SubZeroDev.Runners`, the owner's choice. The live pre-pool install is `D:\Dropbox\Projects\SubZeroDev.Runners` (`D:\Projects` is a symlink to it). It holds `linux/runner/.runner` and `windows/.runner`, and was left untouched. |
| Settings | `runners.local.json` here was given the live install's `github.url` (`https://github.com/AbsoluteZeroDev`), `windows.workFolder` and `linux.docker.mode: dind`; see `design/90-decisions.md` |
| GitHub | `gh` scopes `admin:org, gist, repo, workflow` (the owner added `admin:org`). Runners: `subzerodev.runner.linux` id 9 offline, `subzerodev.runner.windows` id 8 offline. Group `Default`: visibility all, `allows_public_repositories` false |
| Docker | Docker Desktop was stopped; it was launched without changing settings, and the engine (29.9.3) answered after about 7 minutes. No containers, volumes or runner image existed |
| WSL | No `.wslconfig` (no memory cap). Windows auto sign-in is off (`AutoAdminLogon=0`). Docker Desktop starts at sign-in from its `HKCU\...\Run` entry. Nothing here was changed |

## 1. Adopt, then Plan

```
Manage-RunnerHost.ps1 -Action Adopt   -> exit 0
  Adopted 0 slot(s) into %LOCALAPPDATA%\SubZeroDev\Runners\host\inventory.json
Manage-RunnerHost.ps1 -Action Plan    -> exit 0
  No changes.
  [unowned] subzerodev.runner.linux (id 9) ... no registration here proves it. It is never changed
  [unowned] subzerodev.runner.windows (id 8) ... no registration here proves it. It is never changed
  planHash 6d72a22747fca581af9f165d4d69f7ae259823a5b96fc15e25b746cce8a5d4dc
  Docker data on C:\ 279.8 GB free; WSL memory cap: not set
```

Inventory: `hostId beast`, scope `orgs/AbsoluteZeroDev`, no slots. Reviewed: nothing would change, and both pre-pool
registrations are reported unowned and left alone.

## 2. Migrate the legacy Linux runner

Not applicable on this run. This checkout has no `linux/runner/.runner`, so Adopt recorded no legacy `linux-01`. Docker
also had no pre-pool container (`subzerodev-runner-linux` did not exist). No `migrate-legacy-linux` operation was
planned. Runner id 9 stays unowned and unchanged.

## 3. Counts 2/2, then Apply

```
Manage-RunnerHost.ps1 -Action Init -LinuxCount 2 -WindowsCount 2   -> exit 0
Manage-RunnerHost.ps1 -Action Plan                                  -> exit 3
  add linux-01, linux-02, win01, win02; planHash 81e9836e45ae2e22d1addc7f60634f443a39b10c1ec3b4c2c715990a5022b378
Manage-RunnerHost.ps1 -Action Apply -ExpectPlan 81e9836e...         -> exit 1
  Apply added no slot (linux-01, linux-02, win01, win02): the image subzerodev-runner-linux:local is not built.
Manage-RunnerHost.ps1 -Action Update -Version 2.1.0                 -> exit 1   (2.1.0 is the pinned digest cc13d62b...)
  buildAgent.image is already ...@sha256:cc13d62b... (2.1.0).  Apply added no slot ...: the image ... is not built.
```

No host-manager action builds the image on a fresh host
([#32](https://github.com/The-Running-Dev/SubZeroDev.Runners/issues/32)). As a workaround, the image was built with
the functions Apply uses (`Get-LinuxImageBuild`, `Invoke-LinuxImageBuild` from `scripts/Compose.ps1`). The result is
`sha256:9cb8b704...` with label `dev.subzerodev.runners.context=eedfc6af...`, built 11:30:37 to 11:38:27.

```
Manage-RunnerHost.ps1 -Action Plan                                  -> exit 3 (same planHash 81e9836e...)
Manage-RunnerHost.ps1 -Action Apply -ExpectPlan 81e9836e...         -> exit 0 (11:39 to 11:47:36)
  linux-01 is active as subzerodev.runner.linux.beast.01 with runner id 66.
  linux-02 is active as subzerodev.runner.linux.beast.02 with runner id 67.
  win01 is active as subzerodev.runner.windows.beast.win01 with runner id 68.   (clone %LOCALAPPDATA%\SubZeroDev\Runners\win01 at 5324104)
  win02 is active as subzerodev.runner.windows.beast.win02 with runner id 69.   (clone ...\win02 at 5324104)
Manage-RunnerHost.ps1 -Action Status                                -> exit 0
  linux-01 (id 66) online; linux-02 (id 67) online; win01 (id 68) online; win02 (id 69) online; runner group Default: ok
Manage-RunnerHost.ps1 -Action Plan                                  -> exit 0, No changes.
```

| Slot | Runner (id) | GitHub | Docker / process |
| --- | --- | --- | --- |
| linux-01 | `subzerodev.runner.linux.beast.01` (66) | online, labels `subzerodev,subzerodev-linux` | `subzerodev-runner-linux-01` healthy, compose service `linux-01` |
| linux-02 | `subzerodev.runner.linux.beast.02` (67) | online | `subzerodev-runner-linux-02` healthy, compose service `linux-02` |
| win01 | `subzerodev.runner.windows.beast.win01` (68) | online, labels `subzerodev,subzerodev-windows,subzerodev-host-beast,subzerodev-pair-beast` | supervisor started |
| win02 | `subzerodev.runner.windows.beast.win02` (69) | online, same labels | supervisor started |

The single-clone Windows registration was not proven by Adopt (it is in the other checkout), so it was reported unowned
(id 8) and left alone, as step 3 requires for an unproven registration. No `-Retire` was needed.

## 4. Hold, reboot, Resume

Preparation (11:48 to 11:49):

```
runners.local.json: windows.startAtSignIn true
Manage-RunnerHost.ps1 -Action Startup               -> exit 0  wrote ...\Startup\SubZeroDev Runners AutoStart.cmd (runs -Action AutoStart)
Manage-RunnerHost.ps1 -Action Hold -Slot linux-02   -> exit 0  linux-02: held (linux\runner-02\maintenance.json)
Manage-RunnerHost.ps1 -Action Hold -Slot win02      -> exit 0  win02: Drained: no job was running; stopped.
```

Before the reboot:

- Status: `linux-01` online; `linux-02` offline and held; `win01` online; `win02` held.
- GitHub: `linux-02` (67) shows only `self-hosted,X64,Linux`, so its custom labels are withdrawn.
- `win02`'s record (`phase held`) saved its labels. As designed, the Windows hold put them back once the listener stopped (`scripts/Lifecycle.ps1` `Stop-WindowsRunner -Hold`). No `win02` process runs, and GitHub reported id 69 offline at 11:50:20.
- Containers: `linux-01` up and healthy with one `Runner.Listener` (pid 754); `linux-02` exited (143).

The owner rebooted beast and signed in by hand (auto sign-in is off). Boot time was 12:01:45. In order:

- Docker Desktop started at sign-in from its `Run` entry at 12:03:13, and its engine answered.
- The Startup entry's `AutoStart` started both Windows supervisors: win01 pid 10048 at 12:03:38, and win02 pid 9916 at 12:03:41.
- The `restart: always` containers came back. `linux-01` was listening by 12:03:30.

After the reboot, before Resume:

| Slot | Container / supervisor | Listener | Record |
| --- | --- | --- | --- |
| linux-01 | up, healthy | one (`Runner.Listener run`, pid 340) | none; GitHub online |
| linux-02 | up, healthy; entrypoint logs `Held: /runner/maintenance.json exists; no listener starts until the owner resumes this runner.` | none | `held`; GitHub offline |
| win01 | supervisor `running` (pid 10048) | one (pid 11936) | none; GitHub online |
| win02 | supervisor `maintenance` (pid 9916) | none | `held`; GitHub offline |

`Status` (exit 0) showed the same picture. It also reported a `commit` drift on win01 and win02: the clones are at
`5324104`, while this checkout had moved on to the evidence commit `5ae098c`.

```
Manage-RunnerHost.ps1 -Action Resume -Slot linux-02   -> exit 0  linux-02: resumed; the listener starts.
Manage-RunnerHost.ps1 -Action Resume -Slot win02      -> exit 0  win02: already running (pid 9916) - in maintenance, no listener until maintenance ends
```

Win02's message was printed before the supervisor noticed the record was gone. Afterwards:

- Both maintenance records are deleted.
- `linux-02` has one listener (pid 392), with its custom labels back at GitHub.
- `win02`'s supervisor is `running` with one listener (pid 2436).
- GitHub reported 67 and 69 online at 12:04:42.

Side note: `linux-01`'s runner updated itself to 2.338.2 (`runnerVersion` pins 2.338.0 for new images).

## 5. Recreate linux-02 while a job runs on linux-01

Steps 5 and 6 ran in the same window. The step 6 docs smoke job was the job running on `linux-01`. To make it land on
`linux-01` (the smoke checks it ran on id 66), `linux-02` was held during the dispatch (12:24:40) and resumed
(12:26:01) once the job was running on `linux-01` (12:25:53, `Runner.Worker` pid 1955).

```
Manage-RunnerHost.ps1 -Action Resume -Slot linux-02   -> exit 0  (12:26:01)
New-LinuxRunner.ps1 -Slot linux-02                    -> exit 0  (12:26:10 to 12:26:43)
```

| | Before | After |
| --- | --- | --- |
| linux-01 container | `84734efa2dd1...`, started 12:03:22 | `84734efa2dd1...`, started 12:03:22 (unchanged) |
| linux-01 job | `Runner.Worker` pid 1955 | pid 1955 still running; the job finished `success` at 12:32:42 |
| linux-02 container | `1c0ce8d0e64f...`, started 12:03:20 | `e4fecc2ba931...`, started 12:26:39; the inventory records the new ID (generation 15) |
| GitHub labels | 66 and 67 `subzerodev,subzerodev-linux` | the same; both online and idle |

The job on `linux-01`
([docs smoke run 45393380763](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45393380763), job
`Docs smoke / Build`, 12:25:38 to 12:32:42) finished untouched.

## 6. Concurrent L2 runs and the WSL memory peak

| Run | Workflow | Runner | Result |
| --- | --- | --- | --- |
| [45393284264](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45393284264) | HollowMoon `build.yml` (L2 for HollowMoon#4) | `subzerodev.runner.windows.beast.win02` (69), 12:25:04 to 12:28:12 | success |
| [45393380763](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45393380763) | `self-hosted-docs-smoke.yml` from `tests/linux-runner-docs-smoke.yml` | Build on `subzerodev.runner.linux.beast.01` (66), 12:25:38 to 12:32:42; `Verify smoke evidence` on GitHub-hosted | success |

How the two runs were set up:

- **HollowMoon `build.yml`.** Since [HollowMoon#4](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/pull/4), it runs on `windows-latest`. So it was dispatched from a throwaway branch `l3/beast-windows-build` (commit `32f81d5`), changing only `runs-on` to `[self-hosted, subzerodev, Windows]`. That had the owner's go-ahead. No PR was opened, and the branch was deleted afterwards.
- **Docs smoke consumer.** The consumer is SubZeroDev.HollowMoon. `Invoke-Smoke.ps1 -Action Prepare` (exit 0) opened [HollowMoon#6](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/pull/6), which the owner merged at 12:24:16 (`e540f4f`).
- **Docs smoke dispatch.** `Invoke-Smoke.ps1 -Action Run` stopped before dispatch (exit 1). Its host probe targets the pre-pool container `subzerodev-runner-linux` ([#33](https://github.com/The-Running-Dev/SubZeroDev.Runners/issues/33)). The workflow was dispatched directly instead, with `correlation_id=l3beast20261124122531`, `expected_runner_name=subzerodev.runner.linux.beast.01` and `expected_runner_id=66`. Its `verify` job checked the site artifact and the runner identity.

WSL memory was sampled every 5 s from 12:24:40 to 12:33:22, 75 samples:

| Measure | Peak | Estimate in Plan |
| --- | --- | --- |
| `VmmemWSL` working set (Windows side) | 12.6 GB at 12:32:04 | Linux limits 2 × 8 GB = 16 GB (enforced), plus Windows BuildAgent 2 × 8 GB = 16 GB (advisory) |
| Memory used inside the VM (`free`, docker-desktop) | 6.34 GB at 12:32:04 | |
| `linux-01` container (`docker stats`) | 4.96 GB of its 8 GiB limit | 8 GB |

The VM sees 62.8 GB, and no `.wslconfig` cap is set. The peak stayed well under the 32 GB the plan adds up.

## 7. Lower windows.count to 1: without -Retire, with -Retire, then -Prune

This step ran with the checkout detached at `5324104`, the commit the Windows clones were installed from. Its scripts
are identical to the branch's, which differs only by this file. That way Apply had no `commit` drift to update (see
`design/90-decisions.md`).

```
Manage-RunnerHost.ps1 -Action Init -WindowsCount 1     -> exit 0  linux.count 2, windows.count 1
Manage-RunnerHost.ps1 -Action Plan                     -> exit 3
  retire platform=windows slotId=win02 runnerName=subzerodev.runner.windows.beast.win02 runnerId=69 requires=-Retire
  planHash e388d1321431ad1cbf68165067ff2105a589cdb9addbc543b247561996ed64dd
Manage-RunnerHost.ps1 -Action Apply -ExpectPlan e388d132...           -> exit 3 (12:34:37)
  Not retired: win02 (subzerodev.runner.windows.beast.win02) is no longer wanted; rerun Apply -Retire to retire it.
```

Nothing was removed. `win02` was still `active` in the inventory, its `.runner` and clone were in place, it had one
listener, and GitHub still had id 69 online with all its labels.

```
Manage-RunnerHost.ps1 -Action Apply -Retire -ExpectPlan e388d132...   -> exit 0 (12:35:07 to 12:35:44)
  Retiring win02 (subzerodev.runner.windows.beast.win02, id 69): operation ef900898-e0ee-4adc-9071-4b47b56cf9c2.
  withdraw, drain, stop, deregister, clear-local, remove-containers, commit: done
  win02 is retired. What it left on disk (directory, clone, volumes) stays until Apply -Prune.
```

`win02` was drained and deregistered: GitHub returns 404 for runner 69, no `win02` listener runs, its `.runner` is
cleared, and the inventory shows `retired`. Its clone stayed on disk.

```
Manage-RunnerHost.ps1 -Action Apply -Prune             -> exit 0 (12:35:52)  win02: pruned.
Manage-RunnerHost.ps1 -Action Status                   -> exit 0
  linux-01 (66) online; linux-02 (67) online; win01 (68) online; win02 pruned (69): GitHub absent; runner group Default: ok
Manage-RunnerHost.ps1 -Action Plan                     -> exit 0  No changes.
```

`%LOCALAPPDATA%\SubZeroDev\Runners\win02` is gone, and `win01` is untouched. GitHub lists 66, 67 and 68 online, plus
the unowned 8 and 9 offline.

## End state

The beast host runs `linux-01` (66), `linux-02` (67) and `win01` (68) from `D:\Temp\SubZeroDev.Runners`, with
`linux.count 2` and `windows.count 1`. The pre-pool registrations 8 and 9 are unchanged and offline. The raw command
output is kept on beast in `D:\Temp\l3-evidence-S9`.
