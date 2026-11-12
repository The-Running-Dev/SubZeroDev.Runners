# Troubleshooting

Start with the status commands; each exits non-zero when something needs attention.

```powershell
.\scripts\Manage-WindowsRunner.ps1 -Action Status    # from a Windows instance's clone
.\scripts\Manage-RunnerHost.ps1 -Action Status       # every slot, with drift and unfinished operations
.\scripts\Get-LinuxRunnerStatus.ps1
.\scripts\Get-BuildAgentStatus.ps1
docker logs --tail 40 subzerodev-runner-linux
```

Logs: `windows\_diag\` (runner, console and `Startup_*` logs), `linux\runner\_diag\`, `<InstallRoot>\setup-state.json`.

## Setup and configuration

| Symptom | Cause | Fix |
| --- | --- | --- |
| Setup exits **2** | You must act first: restart Windows, sign out and in, finish Docker Desktop's first run, or join `docker-users` | Do what it prints, then run the same command again; finished steps are skipped |
| Setup exits **1** | BuildAgent provisioning or the requested verification failed; the runners are still set up | Read the failed step, fix it, rerun |
| `Setup refused: this host is managed by scripts\Manage-RunnerHost.ps1` | An inventory exists | Change counts in `runners.local.json` and use [`Manage-RunnerHost.ps1`](host-management.md) |
| A settings error listing several problems | The loader rejects floating tags (`:latest`, tags without a digest), floating tool versions, non-empty `buildAgent.paths.extraMounts`, an output directory outside the workspace, non-numeric `lifecycle` or `housekeeping` values | Fix every listed key in `runners.local.json` (or `runners.json`); pin images by digest |
| Registration refused: name registered by another machine | Runner names are per machine | Pick another name, or use `Install-WindowsRunner.ps1 -Replace` only if you are replacing that runner |
| `gh` errors during registration | `gh` is not signed in as an admin, or lacks scope | `gh auth refresh --hostname github.com --scopes admin:org` (organization scope) |
| Install stops before any change, naming an earlier version's startup entry | The old scheduled task or Run entry could not be removed or confirmed gone | Remove it in Task Scheduler, rerun; see `Remove-LegacyTasks.ps1` |

## Runner offline or not taking jobs

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Status` reports the supervisor not running, exit 1 | The supervisor died or the PC restarted; nothing restarts it by design | `Manage-WindowsRunner.ps1 -Action Start` (or set `windows.startAtSignIn` and run `Manage-RunnerHost.ps1 -Action Startup`) |
| `repeatedDeaths` in `supervisor.json` | Three recoveries in a row without a long run | Read `windows\_diag\Console_*-utc.log` for the listener's exit cause |
| Runner is online but jobs queue | The workflow's `runs-on` does not match, or a drain withdrew the custom labels | Use `subzerodev-windows` / `subzerodev-linux`; check for `maintenance.json` and end it with `Start` or `Resume` |
| Runner idles with no listener | It is held (`maintenance.json` exists) | `Manage-RunnerHost.ps1 -Action Resume -Slot <id>`; the Linux log says `Held: ...` |
| Linux container restarts or never goes online | Registration missing, or the sidecar daemon is unreachable | Read `docker logs subzerodev-runner-linux` and `linux\runner\_diag\`; `Register-Runners.ps1` fixes a missing registration |
| Docker is not ready after boot | Docker Desktop is slow or not in Linux-container mode | `AutoStart` waits up to `buildAgent.docker.readyTimeoutSeconds` (default 300); start Docker Desktop and rerun |

## Stopping, draining and maintenance

| Symptom | Cause | Fix |
| --- | --- | --- |
| Stop exits 1 and names a runner that kept running | A job outlasted the drain deadline; it was not cancelled | Wait and rerun, or use `-Force` to cancel the job |
| `phase: stop-failed` in `maintenance.json`, labels not restored | A stop command failed or a process is still running, or its state could not be read | Fix the cause, then end maintenance deliberately with `Start` (Windows) or by rerunning the script |
| Hold or Resume refused: unfinished operation | The journal records an operation on that slot | Read the named operation and next step; `Apply` is not yet available, so inspect `operation.json` before touching it |
| Hold or Resume refused: slot is not `active` | The inventory records another state | `Manage-RunnerHost.ps1 -Action Status` |
| Host lock wait or refusal | Another host-manager command is running | Let it finish; the lock is a mutex, so a dead process releases it |
| `inventory.json` unreadable | A partial write or hand edit | Restore it, or `Adopt -ReplaceUnreadable` (the old file is kept as `inventory.json.unreadable-<utc>`) |

## Linux image and updates

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Get-LinuxRunnerStatus` shows `drift: image` | The container runs an older image than the tag | `New-LinuxRunner.ps1` (add `-Build` after changing `linux.baseImage`) |
| `drift: contextHash` | The image was built from different files or arguments than are on disk, or predates the label | `New-LinuxRunner.ps1 -Build` |
| `drift: composeConfigHash` or `composeFile` | `compose.local.yaml` or the container is out of date | `New-LinuxRunner.ps1` regenerates and recreates the slot |
| `-Update refused: ... managed by compose` | The updater would restore the old container | Use `New-LinuxRunner.ps1 -Build`; see the [updater guide](build-agent-2.2.0-updater.md) |
| `not-checked` on a drift row | The check could not be made (no image, container absent or Docker unavailable); never read as `ok` | Start Docker, rebuild or recreate, rerun |
| Job code cannot read `/runner` registration files | Intended: [runtime isolation](linux-runtime-isolation.md) projects only the runtime the jobs need | None |

## Builds

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Invoke-BuildAgent.ps1` refuses the mapping | The workspace is a UNC path, inside Dropbox, overlaps a clone, contains a comma, or puts output outside the workspace | Fix `buildAgent.paths`; keep `extraMounts` empty |
| Build type rejected | Only the types BuildAgent defines are accepted (`docker`, `node`, `node-in-docker`, `node-template`, `forge`) | Use one of them |
| `Get-BuildAgentStatus.ps1` non-zero | Tool, runtime, Docker daemon or image is missing | `Install-BuildAgent.ps1` (exit 2: act first) |
| Low-disk warning from `Trim-RunnerLogs.ps1` | A drive fell below `housekeeping.minFreeGB` | Free space or lower `buildAgent.cache.maxGB` |
