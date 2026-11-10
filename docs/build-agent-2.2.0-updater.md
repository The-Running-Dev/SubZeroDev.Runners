# BuildAgent.Tool 2.2.0 integration and host acceptance

## Release and pins

[Release v2.2.0](https://github.com/The-Running-Dev/Docker-BuildAgent/releases/tag/v2.2.0)
was published November 9, 2026. [Release workflow 42644447154](https://github.com/The-Running-Dev/Docker-BuildAgent/actions/runs/42644447154)
succeeded at commit `50f62ae7f620a3ab5d4c0a32206984917734e0db`. Its release notes include
[#136](https://github.com/The-Running-Dev/Docker-BuildAgent/pull/136). Publication removes the former upstream
availability blocker; it does not establish consuming-host acceptance.

Both `buildAgent.tool.version` and `buildAgent.updater.version` are `2.2.0` because the updater is part of the
same installed `BuildAgent.Tool` executable, not a separately installed component. The installed version must
match both pins exactly. Null disables the integration, mismatched pins/installations refuse before drain,
and 2.1.0 is explicitly refused even if a local override coordinates both old pins.
The real installer still uses `dotnet tool update/install --tool-path ... --version 2.2.0` under its shared
mutex; matching installations are skipped. Status checks do not install anything. Setup and
`Install-BuildAgent.ps1` can upgrade the shared installation when deliberately run; that remains a separate
approval-gated host action.

`buildAgent.image` remains:

```text
ghcr.io/the-running-dev/build-agent@sha256:cc13d62b66fab58e264eb583de5c47eb5f49a3ee8a2cdd48f0de0b1d0ba16556
```

This is still `BUILD_AGENT_IMAGE` for build invocations and the default Linux runner base. No v2.2.0 image
adoption, runner image rebuild, toolchain bump or mounted runner self-update is included here. The 2.2.0
host launcher with this older image requires real build acceptance separately.

## Released contract used here

Sources inspected at the release tag:
[tool guide](https://github.com/The-Running-Dev/Docker-BuildAgent/blob/v2.2.0/documentation/docs/update-tool.md),
[exit mapping](https://github.com/The-Running-Dev/Docker-BuildAgent/blob/v2.2.0/forge/Update/UpdateCommandLine.cs),
[updater](https://github.com/The-Running-Dev/Docker-BuildAgent/blob/v2.2.0/forge/Update/Updater.cs),
[Docker CLI adapter](https://github.com/The-Running-Dev/Docker-BuildAgent/blob/v2.2.0/forge/Update/CliDockerRuntime.cs),
[upstream regressions](https://github.com/The-Running-Dev/Docker-BuildAgent/blob/v2.2.0/forge/Update.Tests/UpdaterTests.cs).

The command stays `build-agent update <container> --image <reference> --health-timeout <duration>`.
Runners passes the configured local Linux runner image, not the BuildAgent base image, and never passes
`--no-restore`. The updater carries privileged mode, CPU/memory limits (including reservation/swap), tmpfs
options, stop timeout, network aliases, logging, supported mounts and other supported identity settings.
Unsupported settings still refuse before mutation, including capabilities/devices, anonymous volumes,
legacy links, fixed network addresses and image-derived settings that were overridden on the container.
The updater remains the sole owner of recreation, locking, its log and container restoration.

| Updater result | Runners behavior after drain |
| --- | --- |
| 0: healthy replacement or already current | Restore saved labels, clear maintenance only after confirmation, script exit 0. Already current performs no new health check. |
| 10: prior container restored, including graceful interruption | Restore saved labels, script exit 1; mounted writes remain. |
| 20/23/24/30: unsupported/missing target, pin/log/image refusal | This invocation did not mutate the target; restore saved labels, script exit 1. |
| 21/22: lock or residue/log refusal | Keep maintenance and saved labels; an earlier incomplete attempt may need recovery. |
| 11/12/1/unknown, invocation failure or forced timeout | Outcome unresolved; keep maintenance and saved labels. |
| Label restoration fails | Keep the record; script exit 1. |

The `update-running` phase is durably saved **before** invoking the child. A crash retains that phase;
unresolved returns become `update-recovery-required`. Either blocks subsequent `-Update` before drain,
including retries whose upstream result might otherwise be an early refusal or AlreadyCurrent.
No automatic lock clearing, residue deletion, log rewriting, fallback recreation or replay of a live update
is implemented. The process deadline is health duration plus 600 seconds; seconds, `s`, `m`, `h` are handled
without dropping units. A forced timeout is not evidence that graceful restoration happened.

The updater restores the original **container identity**, not changes the replacement wrote to bind mounts
or named volumes. Runner binaries, registration, credentials, self-update state and workspace/cache/data
remain shared and outside that rollback. Exit 10 also does not prove application data compatibility or
that the original has passed a fresh health check.

## PR #17 coordination and credential boundary

[#17](https://github.com/The-Running-Dev/SubZeroDev.Runners/pull/17), inspected at
`4040cec6ea0efbd0162a2e8ca7219ef6bdd9e414`, remains a separate change. It replaces the sidecar's complete
registration-tree bind with a read-only Node runtime projection volume and a runner job-start refresh hook.
This integration does not copy, mount, inspect or disclose registration/credential contents on a real host.

The new sidecar preflight requires:

- Exactly the derived `<linux.container>-runtimes` volume read-only at sidecar `/runner/externals`.
- The same volume writable at runner `/runner-runtime`, with the expected job-start hook marker.
- No sidecar bind mounts or other `/runner` installation mounts, and no alias of the runtime volume with
  configured workspace, cache, certificates or daemon state volumes.
- Successful bounded mount/hook reads. It queries mounts and only the matching hook marker, never the full
  environment or credential files.

An old installation fails before labels are withdrawn. Apply #17's migration by separately approved
recreation and verification first; `-Update` preserves the old mount shape and never migrates the sidecar.
This check establishes the expected layout, not actual projection contents, job behavior, real Node
executables or a broader hostile-workflow isolation claim. #17's own runtime projection/probe regressions
and real acceptance remain necessary. DinD has no separate sidecar projection dependency.

## Verification layers

| Layer | Evidence / remaining work |
| --- | --- |
| Local synthetic | `Test-LinuxRunnerUpdate.ps1` runs the real entry point, version reader/gate, installer decision, invocation builder, maintenance persistence and recovery transitions. SDK/Docker/GitHub operations are faked; registration/credential canaries are synthetic. |
| Focused regression cases | Exact installer arguments and skip-on-match; old/new/missing/configured mismatch; unsupported-settings exit 20; PR #17 old/unreadable/writable/missing mounts/hook/alias; drain timeout; success/restore/refusal; failures/unknown exit; failed label restoration; timeout/start failure/exception; abrupt child-process termination; blocked retries with durable labels; explicit synthetic operator recovery; duration units; DinD. |
| Hosted CI | `.github/workflows/windows-runner-validation.yml` runs these fixtures on hosted Windows together with existing provisioning/integration/lifecycle tests. This remains synthetic evidence even on a hosted Windows machine. See this PR's checks for results. |
| Released upstream | The linked release workflow passed Tests & Coverage and publication. Its source contains runner-settings preservation, unsupported-shape and interruption regressions. This is upstream evidence, not a Runners host acceptance result. |
| Actual Docker host / Windows Docker Desktop | **Not run for this change.** Healthy replacement, failed-health restoration, interruption/residue recovery, real mount fidelity, #17 projection behavior and builds with the unchanged image remain unverified here. |

Local supported commands (no host tool or live daemon required):

```powershell
./tests/Test-LinuxRunnerUpdate.ps1
./tests/Test-LinuxJobContainerMounts.ps1
node --test scripts/docs-smoke/smoke.test.mjs
```

Existing Windows-only provisioning, integration and lifecycle suites run in automatic hosted PR CI.
Do not substitute generic Windows BuildAgent smoke evidence for Linux updater acceptance.

## Proposed host actions — not executed; each requires Ben's approval

First identify the exact host checkout, SDK executable, local overrides and candidate commit. Do not run
setup to pick up these pins incidentally. Review the resulting absolute paths and commands before approving
installation. From that approved checkout, the narrow tool-only action would be:

```powershell
. ./scripts/RunnerConfig.ps1
. ./scripts/BuildAgent.ps1
$config = Read-RunnerConfig -Root $PWD
$settings = Get-BuildAgentSettings $config
$sdk = Join-Path (Join-Path $PWD $config.windows.directory) '_tool/dotnet/dotnet.exe'
if (-not (Test-Path -LiteralPath $sdk)) { throw 'Resolve and approve the actual SDK path first.' }
if ($settings.Version -cne '2.2.0' -or $settings.UpdaterVersion -cne '2.2.0') { throw 'Pin overrides differ; stop.' }
# MUTATION: updates/installs the shared host tool only. No Docker Desktop start, image pull or container update.
Install-BuildAgentTool $settings $sdk
Test-BuildAgentUpdater $settings
```

This expands to `dotnet tool update BuildAgent.Tool --tool-path <resolved ToolDirectory> --version 2.2.0`
(or `install` if absent). It can affect all instances sharing that tool directory. Do not change the
image digest or install a new image with it. Verify real builds against the retained digest using the
existing Windows BuildAgent acceptance workflow only after approving its exact dispatch inputs.

Before any real sidecar-mode update, #17 must be reviewed and activated. Its runbook contains the separate
recreation proposal. That operation temporarily withdraws labels, waits for idle, replaces runner + sidecar
and restores labels; it requires its own approval and is not bundled with tool installation or this PR.
After activation, read-only preflight from the approved checkout is:

```powershell
. ./scripts/Common.ps1
. ./scripts/BuildAgent.ps1
Assert-LinuxUpdaterIsolation $Config $Docker
```

For actual updater acceptance, prepare **disposable registered runner fixtures** on a Docker host, with
isolated synthetic registration/mounted state and distinct baked images. Present the concrete container,
network, volume and image names plus every build/run/update/cleanup command before approval. Exercise:

1. Sidecar and DinD settings (limits, privilege, tmpfs, stop timeout, aliases, mounts), healthy replacement
   and before/after fidelity. Use different image IDs; AlreadyCurrent is not this test.
2. Image with a baked failing health check; require exit 10 and the original container ID/name/settings
   restored. Check mounted-state canaries separately; do not expect their writes to roll back.
3. A genuinely unsupported setting; require exit 20 and unchanged container identity/settings.
4. Graceful interruption after first mutation; require original restoration and the interruption log entry.
5. Abrupt termination; require retained Runners maintenance/labels and a blocked retry. Inventory lock,
   prior container, pin and open log entry, then propose exact recovery actions for approval.
6. Real `New-LinuxRunner.ps1 -Update` wrapper behavior and label restoration using only the disposable
   registration. Use no `-Force`; record script/updater exits, maintenance and GitHub labels.

The eventual real-runner update command would be `./scripts/New-LinuxRunner.ps1 -Update -TimeoutMinutes 5`
from the explicitly approved checkout, using its reviewed overrides. It withdraws runner custom labels,
waits up to five minutes for idle, invokes the pinned updater and conditionally restores admission.
It does not include `-Build` or `-Force`. This is a proposal, not authorization to run it. No live runner
update or intentional interruption is part of implementation validation.

## Recovery review

Keep admission closed after an unresolved attempt. Review only the relevant updater log entries and
Docker state (avoid dumping complete environments). The log is
`%LOCALAPPDATA%/Docker-BuildAgent/updates.jsonl` on Windows. Locks/prior containers are named
`buildagent-lock-<hash>` / `buildagent-prior-<hash>`; `<hash>` is the first 32 lowercase SHA-256 hex
characters of the UTF-8 target name. The prior image pin is `buildagent-prior:<hash>`.

Before proposing any mutation, verify the updater owner is no longer running, identify the prior/current
container IDs, health, mounts and image IDs, assess mounted writes and preserve needed evidence/backups.
`build-agent update --clear-lock <name>` clears only the lock; it does not restore a container or repair
residue/logs. Never approve that as a complete recovery by itself. Present exact affected identities and
commands before clearing/removing/renaming anything or editing the log.

After the operator has verified and approved complete recovery to a usable container, the existing
explicit maintenance-ending action is (also requires approval because it restores live runner admission):

```powershell
. ./scripts/Common.ps1
. ./scripts/Registration.ps1
. ./scripts/Lifecycle.ps1
Exit-RunnerMaintenance (Get-LinuxMaintenanceFile) $LinuxRunner
```

This restores saved labels with identity checks and clears the record only after confirmation. It does
not recover Docker/updater state; doing that first is the operator's responsibility. A later update
needs separate approval. Source integration, PR #17 activation, Docker acceptance and merge are distinct
decisions. This document grants none of those approvals.
