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
| WSL | No `.wslconfig` (no memory cap). Docker Desktop's own `AutoStart` setting is `false`; Windows auto sign-in is off (`AutoAdminLogon=0`). Neither was changed |

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
