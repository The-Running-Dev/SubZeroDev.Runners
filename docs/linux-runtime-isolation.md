# Linux sidecar runtime isolation

## Scope and contract

PR #14 mounted the complete registration installation read-only at the sidecar's
`/runner`. This fixed runtime lookup but made `.credentials*` readable through
a nested bind of `/runner`. PR #15 has merged and records that remaining exposure.
Read-only mounts restrict writes, not reads.

This change removes that direct exposure. It does not isolate hostile workflows:
non-container steps still run in the registered runner, and access to a privileged
Docker daemon remains powerful enough to compromise the Docker host. Jobs remain
trusted. The workspace, TLS/certificates, image/cache volumes and DinD contract
are unchanged; registration directories, IDs and names remain where they are.

The trace below is pinned to Actions runner **2.338.0**, the configured release:

| Requirement | Upstream behavior | Consequence |
| --- | --- | --- |
| Job mounts | `ContainerOperationProvider.MountWellKnownDirectories` mounts work, temp, actions and tools; Linux externals is read-only | Work-related paths continue using the existing shared workspace volume |
| JavaScript actions | `NodeScriptActionHandler` executes `externals/<node runtime>/bin/node`; `ContainerInfo` maps externals to `/__e` | The daemon needs `/runner/externals`, not the registration parent |
| Linux variants | `externals.sh` packages Node 20/24 and their `_alpine` variants; `StepHost` selects Alpine where needed | Project every installed `node<digits>[_alpine]/bin/node`, rather than hardcoding Node 24 alone |
| Self-update | `SelfUpdater` copies `externals.<version>`; `update.sh.template` switches `externals` to an absolute versioned sibling link | Resolve the source again before each job; a creation-time bind alone pins the old directory |
| Hook order | `JobExtension` schedules the started hook before container setup/start; `JobHookProvider` uses the default host step context | Refresh outside the job container before Docker resolves its runtime bind; failed refresh prevents initialization |

Sources: [job mounts](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/ContainerOperationProvider.cs),
[path mappings](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/Container/ContainerInfo.cs),
[JavaScript handler](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/Handlers/NodeScriptActionHandler.cs),
[runtime selection](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/Handlers/StepHost.cs),
[runtime packaging](https://github.com/actions/runner/blob/v2.338.0/src/Misc/externals.sh),
[update copy](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Listener/SelfUpdater.cs),
[update links](https://github.com/actions/runner/blob/v2.338.0/src/Misc/layoutbin/update.sh.template),
[hook order](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/JobExtension.cs),
[hook execution](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/JobHookProvider.cs).

## Options compared

| Approach | Update behavior | Exposure / operational cost |
| --- | --- | --- |
| Complete installation bind | Versioned sibling links resolve | Exposes registration files; removed here |
| Bind only current externals or individual runtime directories | Docker resolves/pins sources when the sidecar is created; later link switches or removed old versions are not followed | Smaller surface, but requires coordinated sidecar recreation on each runner update |
| Mount all current versioned externals siblings | Future version directories do not exist at creation | Still requires update coordination and additional mounts |
| Copy full externals into a separate projection | Can refresh per job | Copies npm, links and other files beyond what JavaScript actions need; requires recursive link policy |
| **Project only Node executables (selected)** | Resolve current externals and refresh before each job | Small allowlist; no registration source mount, updater integration or image rebuild |

The outer Docker volume `<linux.container>-runtimes` is mounted writable at
`/runner-runtime` in the runner and read-only at `/runner/externals` in the sidecar.
`volume-nocopy` prevents initialization from an image directory. The derived name
must not alias any configured workspace, cache, TLS or Docker data volume.
The job-start hook stages only regular, executable Node files, rejects symbolic
links inside runtime paths and hardlinked binaries, then removes stale projection
contents and publishes the staged directories. The root `externals` link may
resolve only to `externals` or `externals.<numeric version>` directly under the
runner root. Root registration files and arbitrary runtime siblings are never
opened or copied. The hook does not execute the source runtimes while copying.

This assumes the existing serial, trusted runner. Publication happens between
jobs, not while another job uses the projection. It adds a per-job copy of the
installed Node executables. Unexpected future runtime layouts fail the hook
rather than exposing a wider tree. Node/npm for application builds still comes
from Docker-BuildAgent; the projection supplies only Actions' JavaScript runner.
No BuildAgent digest, toolchain, reusable workflow or runner image changes.

## Validation boundary

`Test-LinuxJobContainerMounts.ps1` invokes the real creation script with fake
Docker and maintenance functions. It checks both modes, mount/hook arguments,
unchanged synthetic registration/credential canaries, failure handling and volume
alias refusal. `Test-LinuxRunnerRuntimes.sh` uses synthetic executable fixtures
and models daemon `/runner/externals` to job `/__e`. It covers Node 20/24 and
Alpine, fresh directories, absolute/relative update links, updated binary refresh,
stale runtime removal, absence of registration canaries and malicious link refusal.
`Test-LinuxJobContainerProbe.ps1` validates the opt-in probe's controller with an
external fake Docker executable. These checks do **not** verify real Docker mount
propagation, real Node binaries, an actual self-update or workflow execution.

No live Docker-host or GitHub consumer acceptance has been performed for this
change. The opt-in probe must separately verify actual runtime binds, the shared
workspace and registration-path absence with the pinned BuildAgent image. A real
documentation workflow is still needed to establish end-to-end compatibility.

## Proposed host actions — require approval before execution

Review the exact commit and confirm the existing host clone first. No host access,
container recreation, registration changes, dispatch or merge is part of the
implementation validation. Existing live containers retain the old mount until
explicitly recreated. Updating source files or using `-Update` alone does not
remove it: BuildAgent's updater preserves existing mounts and sidecar state.

From the approved, clean host checkout of this revision, the proposed commands are:

```powershell
. ./scripts/RunnerConfig.ps1
$config = Read-RunnerConfig -Root $PWD
$registration = Join-Path $PWD (Join-Path $config.linux.directory '.runner')
$before = Get-Content -Raw -LiteralPath $registration | ConvertFrom-Json
if ($before.workFolder -cne $config.linux.workFolder) {
    throw 'Stop: recreation would otherwise rewrite the registered work folder.'
}
# Existing drain path: temporarily withdraw custom labels, wait for idle,
# recreate runner + sidecar, then restore labels. No -Force, -Build or -Update.
./scripts/New-LinuxRunner.ps1 -TimeoutMinutes 5
if ($LASTEXITCODE -ne 0) { throw 'Recreation failed; retain maintenance state for recovery.' }
$after = Get-Content -Raw -LiteralPath $registration | ConvertFrom-Json
if ($after.agentId -ne $before.agentId -or $after.agentName -cne $before.agentName) {
    throw 'Runner identity changed; stop acceptance.'
}
docker inspect --format '{{json .Mounts}}' $config.linux.docker.container
docker inspect --format '{{json .Mounts}}' $config.linux.container
./tests/Invoke-LinuxJobContainerProbe.ps1
```

The reviewed mount output must show the runtime volume, no sidecar installation
bind, and unchanged workspace/cache/TLS/data volumes. The probe refreshes the
projection, writes a unique temporary workspace fixture and creates one bounded
nested container using the pinned BuildAgent image (Docker may pull it). It checks
the parent namespace for registration paths without reading credential contents,
executes real projected Node 24, then removes only its own test objects and writes
a JSON report. It does not prove a real self-update transition. Stop if any
identity, maintenance, mount or probe check fails; do not re-register or prune.

Approval for these host actions does not approve merging or dispatching the docs
smoke. Select the eligible consumer and exact ref/runner ID/name, present the
separate commands from [the smoke runbook](linux-docs-smoke.md), and obtain
approval for those actions before execution.
