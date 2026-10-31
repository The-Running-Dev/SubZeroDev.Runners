# SubZeroDev runners

Self-hosted GitHub Actions runners on one Windows PC with Docker Desktop, shared by SubZeroDev projects. GitHub
still owns triggers, logs, checks, secrets and artifacts; the jobs execute here.

| Runner | Where it runs | `runs-on` |
| --- | --- | --- |
| `subzerodev.runner.windows` | Native process under the signed-in user, kept alive by `scripts\Run-WindowsRunner.ps1` | `subzerodev-windows` or `[self-hosted, subzerodev, Windows]` |
| `subzerodev.runner.linux` | Docker container `subzerodev-runner-linux` on [Docker-BuildAgent](https://github.com/The-Running-Dev/Docker-BuildAgent) (Debian 12, .NET 8/9/10, Node 22, PowerShell, Docker CLI and Engine, GitVersion, NUKE) plus wasm-tools, CMake and Ninja | `subzerodev-linux` or `[self-hosted, subzerodev, Linux]` |

Names and labels come from `runners.json` (`windows.name`, `linux.name`, `github.labels`); the
GitHub URL they are registered to comes from `runners.local.json`, which git ignores:

```json
{ "github": { "url": "https://github.com/<owner>/<repo>" } }
```

Any other setting placed there overrides `runners.json` on this machine only. Each runner gets `github.labels` plus its own
(`windows.labels`, `linux.labels`) and GitHub's defaults (`self-hosted`, the OS, `X64`).

Each runner takes one job at a time, so one Windows and one Linux job can run together.
Neither needs inbound ports.

## Layout

| Path | Contents |
| --- | --- |
| `runners.json`, `runners.local.json` | Settings every script reads (the second is git-ignored and wins): GitHub labels and URL, runner names and folders, container, base image, image, cache volume, work folders (`windows.workFolder` may be absolute and use `%TEMP%`-style variables), Docker daemon for Linux jobs (`linux.docker`, see below), CPU/RAM limits, startup mode, log retention |
| `scripts\` | Host scripts and the job-completed hooks (mounted read-only at `/runner-hooks` in the container) |
| `windows\` | Windows runner: registration, binaries, private .NET SDK (`_tool\dotnet`), NuGet cache, `_work` (unless `windows.workFolder` points elsewhere), `_diag` logs (runner, console and `Startup_*` logs), `supervisor.pid` |
| `linux\Dockerfile`, `linux\entrypoint.sh` | Linux image: `linux.baseImage` (Docker-BuildAgent pinned by digest; bump it in `runners.json`, then `New-LinuxRunner.ps1 -Build`) plus the Actions runner. Jobs run as root, like the base |
| `linux\runner\` | Linux runner, mounted at `/runner`: registration, binaries, `_diag` logs. Checkouts use `/tmp/runner-work` inside the container |
| Docker container `subzerodev-runner-linux-docker` | Sidecar mode only: the Linux jobs' Docker daemon (`linux.docker.image`: `docker:dind` pinned by digest), privileged, on network `subzerodev-runner-linux` as host `docker`. The runner reaches it over TLS (`DOCKER_HOST=tcp://docker:2376`); ports that jobs publish are on `docker`, not `localhost` (`TESTCONTAINERS_HOST_OVERRIDE` is set) |
| Docker volume `subzerodev-runner-linux-cache` | Mounted at `/cache`: the container's home folder and NuGet packages, kept across container and image rebuilds (`docker volume rm` it to start clean) |
| Docker volumes `subzerodev-runner-linux-docker`, `-docker-certs`, `-work` | Sidecar mode: the daemon's images and build cache; its TLS certificates (read-only in the runner); `/tmp/runner-work`, shared by both containers at the same path so bind mounts of a job's checkout work |
| Docker volume `subzerodev-runner-linux-dind` | Dind mode: the runner's own daemon's images and build cache, at `/var/lib/docker` (`linux.docker.dindVolume`) |
| `downloads\` | Actions runner packages for Windows and Linux |
| `dropbox-ignore.txt` | Paths kept local-only |

## Scripts

| Script | Does |
| --- | --- |
| `Start-Runners.ps1` | Reapplies ignore rules, trims logs, starts the Windows supervisor if `supervisor.pid` names none, starts Docker Desktop if needed, then the Docker sidecar (in sidecar mode) and the Linux container. Logs to `windows\_diag\Startup_*-utc.log`; on failure shows a toast that opens that log |
| `Stop-Runners.ps1 [-Drain] [-TimeoutMinutes 120]` | Kills the Windows supervisor (from `supervisor.pid`) and its runner, stops the Linux container, then the sidecar (in sidecar mode). `-Drain` first waits for running jobs to finish and stops nothing if one is still running at the timeout. Registrations stay |
| `Register-Runners.ps1` | Drains and stops both runners, removes their current registrations, registers them under `github.url` with the names and labels from `runners.json`, starts them. Needs `gh` signed in as an admin |
| `Set-WindowsStartup.ps1 [-Mode Disabled\|Logon]` | Applies `windows.startup` (or `-Mode`). `Logon` registers `\SubZeroDev.Runners\Start runners`, run 30 s after this user signs in and retried up to three times if `Start-Runners.ps1` fails; `Disabled` removes it. Both remove the older `SubZeroDev.Runners` Run entry (Windows could skip it at sign-in) |
| `New-LinuxRunner.ps1 [-Build]` | Recreates the Docker sidecar (when `linux.docker.mode` is `sidecar`; removes it otherwise) and the container from `runners.json` (`-Build` rebuilds the image first, on `linux.baseImage`) and keeps the registration's work folder in step |
| `Set-DropboxIgnored.ps1` | Marks everything matched by `dropbox-ignore.txt` with `com.dropbox.ignored`. Idempotent |
| `Trim-RunnerLogs.ps1` | Deletes `_diag` files older than `logs.retentionDays` in both runners, keeping the newest Runner/Worker/Console log of each runner |
| `Register-LogTrimTask.ps1` | Schedules the trim daily at `logs.trimAt` as `\SubZeroDev.Runners\Trim logs`. `trimAt: null` removes it |
| `Run-WindowsRunner.ps1` | The supervisor: one instance per user (mutex), writes `supervisor.pid`, relaunches `run.cmd` 30 s after it exits, one `_diag\Console_*-utc.log` per launch, and a toast after three quick exits in a row |
| `Show-Notification.ps1` | Windows toast (runs under Windows PowerShell 5.1, which has WinRT); used by the two above |
| `Clear-WindowsActionCache.ps1`, `Clear-LinuxWorkspace.sh` | Job-completed hooks: clear downloaded actions (and Linux checkouts) with retries; on Linux also the job's leftover containers, networks and anonymous volumes. NuGet caches, images and build cache stay |

```powershell
# From the repository folder
.\scripts\Start-Runners.ps1
.\scripts\Stop-Runners.ps1 -Drain
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
docker logs --tail 40 subzerodev-runner-linux
```

After editing `runners.json` or `runners.local.json`: rerun `Set-WindowsStartup.ps1` for `windows.startup`,
`Register-LogTrimTask.ps1` for `logs`, `New-LinuxRunner.ps1` for anything under `linux`,
`Register-Runners.ps1` for `github` or a runner name.

## Using the runners from a repository

Use `runs-on: subzerodev-windows` or `subzerodev-linux` (or the label lists above). The single
labels also fit inputs that take one string, such as the `os` list and `utility-runs-on` of the
[GitHub-ActionTemplates](https://github.com/The-Running-Dev/GitHub-ActionTemplates) workflows:

```yaml
with:
  os: '["subzerodev-linux"]'
  utility-runs-on: subzerodev-linux
```

Keep fork pull requests off these machines and give jobs `permissions: {}` unless they need more.
Linux jobs can use `docker`, `docker buildx` and `docker compose`; see below for where the daemon runs.
The-Running-Dev is a user account, so a runner can only be registered to one repository at a
time. Sharing them across repositories needs an organization; see Later.

## Docker in Linux jobs

`linux.docker.mode` picks where the Linux jobs' Docker daemon runs. Switch it in `runners.local.json`
(`{ "linux": { "docker": { "mode": "dind" } } }`), then run `New-LinuxRunner.ps1`.

| Mode | Daemon | Jobs see |
| --- | --- | --- |
| `sidecar` | A separate privileged `docker:dind` container with its own CPU/RAM limits (`linux.docker.cpus`, `.memory`) | `DOCKER_HOST=tcp://docker:2376` over TLS; published ports on host `docker` |
| `dind` | Docker-BuildAgent's opt-in `dockerd` inside the runner container, which then runs privileged (`BUILD_AGENT_DOCKERD=1`). Starts before the runner and stops after it; its log is `/var/log/dockerd.log` | The default socket, `DOCKER_HOST` unset; published ports on `localhost`. The daemon shares the runner's CPU/RAM limits |

Images and build cache stay in each mode's own volume, so switching back and forth keeps both.

## Isolation

Jobs run code from the repositories that use these runners, with that repository's secrets.

- **Now.** Linux jobs run in the container: root inside it, with no host mounts beyond its own
  `/runner` folder, the hooks (read-only) and the cache volume, and the CPU and memory limits from
  `runners.json`. Their Docker daemon is privileged (the sidecar, or in `dind` mode the runner
  container itself), so a job can start a privileged container and from there take over the
  Docker Desktop VM, including the Windows drives that Docker Desktop shares into it. Treat Linux jobs as trusted, like Windows jobs. Windows jobs run as the signed-in host user and can reach
  everything that user can.
- **Next.** The Windows runner moves into a dedicated VM (see Later), which takes host files and
  the user's sign-ins out of reach.
- **Optional.** A third runner only for releases, with its own label (for example
  `subzerodev-release`) and only the release environments' jobs pointed at it, so signing keys
  and release tokens never share a machine with pull request builds.

## Later

- **Organization runners.** Move the private repositories into a free organization and set
  `github.url` to it; `Register-Runners.ps1` then registers organization runners, which the
  Default runner group offers to private repositories only. Steps, none automated:
  1. Create the organization (Free plan) in the GitHub web UI.
  2. Transfer the private repositories that should use the runners (Settings → Transfer).
     GitHub redirects the old URLs, including git remotes, until a repository of the same name
     is created under the old owner.
  3. Packages do not move. Container, npm and NuGet packages stay owned by The-Running-Dev, and
     a transfer drops their link to the repository, so `github.token` stops reading them. For
     private packages that the moved repositories restore: publish them from the organization
     as well, or give the consuming repositories a token that can read them.
  4. Recreate repository secrets and environments where a transfer did not keep them (check
     release environments and their secrets).
  5. Set `github.url` to `https://github.com/<organization>`, run `Register-Runners.ps1`, and
     check the Default runner group's repository access.
  6. Update hard-coded owners: `The-Running-Dev/...` in workflows (release publishing targets
     included), NuGet sources and the docs.
- **Windows runner in a dedicated VM.** Same `windows\` folder and scripts, run inside a VM
  built for it; startup then becomes a boot-time task or service in the VM rather than the
  host user's logon.
- **Linux stays a container.** Only the host it runs on may change.
- **Startup modes.** `Logon` (a sign-in scheduled task) is the only automatic mode today.
  Candidates: a boot-time scheduled task (runs without signing in) or the runner's own
  Windows service.
- **Dev Drive.** Still supported in Windows 11 (only the Dev Home app was retired). A ReFS
  volume with Defender performance mode, at least 50 GB, created from Settings or as a VHDX.
  Fits `windows\_work`, `windows\_nuget` and other caches; Microsoft advises keeping SDKs
  (here `windows\_tool\dotnet`) on the system drive. No gain for the Linux container, whose
  checkouts are already on a volume in Docker's VM. Works inside a VM too.
