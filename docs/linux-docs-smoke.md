# Linux job containers and the reusable documentation smoke test

## Fix and execution boundary

`docs.yml` uses a job container. Actions bind-mounts the runner's `externals`
directory into that container to provide JavaScript runtimes, including the Node
24 runtime used by checkout. A remote Docker sidecar resolves these bind sources
in its own filesystem. Sharing only the work volume leaves `/runner/externals`
unavailable to that daemon.

`New-LinuxRunner.ps1` now shares the same complete runner installation at
`/runner` with the sidecar, read-only. The runner retains its writable mount.
Sharing the complete tree preserves the versioned directories that `externals`
can point to after self-update. The workspace volume and DinD mode are unchanged.
No BuildAgent release, image rebuild or shared ActionTemplates change is needed.
Existing containers acquire the mount only when recreated.

The manual consumer workflow is [`tests/linux-runner-docs-smoke.yml`](../tests/linux-runner-docs-smoke.yml).
It calls ActionTemplates `docs.yml` at `1c3b5f76554aca455cd4a284c4e473edd21c0d72`
with `runs-on: subzerodev-linux` and the image configured in `runners.json`:
`ghcr.io/the-running-dev/build-agent@sha256:cc13d62b66fab58e264eb583de5c47eb5f49a3ee8a2cdd48f0de0b1d0ba16556`.
This uses the image's real `build node-template` and bundled Docusaurus template.
It builds two fixture pages, explicitly uploads the site and disables deployment.
It does not exercise the Windows `BuildAgent.Tool` wrapper.

## Local preparation evidence

| Check | Evidence |
| --- | --- |
| Mount creation regression | Executes `New-LinuxRunner.ps1` with temporary modules/fake Docker; checks matching installation/workspace mounts, read-only sidecar, source with spaces, DinD behavior and failure handling |
| Evidence validator | Synthetic site archives and a local mock jobs API; validates success and rejection of missing artifacts, failed builds, unexpected runner identity and unavailable GitHub metadata |
| Eligibility checker | Mocked repository/org inventories and group access; rejects cross-scope, mismatched/offline identities, restricted groups, archived consumers and disabled Actions |
| Host probe controller | External fake Docker checks the actual nested-container arguments, symlink probe, failure propagation and cleanup on Linux |
| Syntax | PowerShell parser and actionlint for the caller template and modified hosted CI workflow |
| Real Docker/host/GitHub smoke | Not collected in the implementation environment: no Docker CLI/socket, no runner-host connection, no host-local Linux registration; connected runner inventory GET is unavailable |

The fixture tests do not establish real runner acceptance. No eligible consumer,
real workflow run ID or successful host probe is claimed by this document.
The commands below are executable host/consumer acceptance steps, not recorded
execution. Use the existing authenticated host session; these scripts never
request new credentials or change registrations.

## 1. Establish the eligible consumer on the existing host

### Automated consumer preparation and acceptance

In the **existing host clone that contains `linux/runner/.runner`**, use PowerShell 7
and the host's signed-in GitHub CLI session:

```powershell
./scripts/docs-smoke/Invoke-Smoke.ps1 -Action Prepare
```

For repository registration, this discovers that exact repository. For organization
registration, add `-Repository '<org>/<existing consumer>'`; it does not choose an
arbitrary repository. Prepare verifies eligibility and opens a consumer PR adding
only the six runtime files in one commit on a separate branch. An identical prior
branch/PR is reused; existing differing files are refused. It does not merge or
dispatch. Existing consumer push/PR automation can react to the branch/PR.

Review and merge the **consumer PR** it prints, then run:

```powershell
./scripts/docs-smoke/Invoke-Smoke.ps1 -Action Run
```

Supply the same `-Repository` for organization registration. Run checks the exact
installed files on the default branch and selected `-Ref` (default: default branch),
probes the live nested mounts, dispatches with the actual runner name/ID, waits up
to 45 minutes and downloads both site/result artifacts. It independently checks
the site contents and live GitHub job records, then prints the run URL and local
evidence directory. No registration, runner stop/recreation, merge or automatic
trigger is introduced by this controller.

If the live probe fails because existing containers still lack the mount, apply
the reviewed recreation in section 2, then repeat Run. There is no image rebuild
or mode change. Workflow allowlists still need to permit the pinned public actions
and reusable workflow; successful scope validation alone does not prove that.

The controller keeps a per-consumer/runner journal and lock under
`%LOCALAPPDATA%\SubZeroDev\Runners\linux-docs-smoke\` (or `-StateDirectory`). On an
interruption, timeout, missing GitHub response or artifact outage, repeat Run to
resume the original dispatch rather than create another. A busy/offline runner
can be reconciled, but a new dispatch requires it online and idle. Changed
ref/commit/runner, another run attempt, duplicate correlations or unreadable state
stop for reconciliation. Never delete an unresolved journal merely to retry:
inspect the saved run/correlation first. The controller never cancels other jobs.
An explicit non-timeout HTTP 4xx dispatch rejection clears its own intent because
no run was created. Transport/timeouts and server errors retain it. Preparation
can open a consumer PR while the registered runner is unavailable; a new run
still requires online/idle status and a passing live probe. A ref update in the
remaining check-to-dispatch interval can start a different revision, which the
controller rejects when reading its exact head SHA; it does not claim atomic
branch ownership or silently create tags that could trigger release automation.

The detailed individual steps below remain useful for diagnostics.

From the Runners clone containing the Linux registration and the reviewed fix:

```powershell
$registration = Join-Path $PWD 'linux/runner/.runner'
$before = ./scripts/docs-smoke/Get-SmokeEligibility.ps1 -RunnerRegistration $registration | ConvertFrom-Json
$before | Format-List
```

For organization registration, pass an explicit candidate with
`-Repository '<org>/<candidate>'`; no consumer is guessed. The checker compares
the local runner ID/name with live inventory and checks labels, Linux/X64,
online/idle state, consumer metadata, Actions-enabled policy and group repository
access. It stops on inherited/workflow-restricted groups rather than inferring
permission. `workflowPolicyVerified: false` explicitly means that allowlists for
the pinned public reusable workflow/actions must still be checked in that
consumer's Actions settings. Group/workflow policy or unavailable inventory
must be resolved before calling a repository eligible for execution.

## 2. Recreate the affected containers and preserve registration identity

Choose a period when the runner is idle. Check the local registration's work
folder already matches configuration, so recreation does not rewrite that field:

```powershell
. ./scripts/RunnerConfig.ps1
$settings = Read-RunnerConfig -Root $PWD
$local = Get-Content -Raw $registration | ConvertFrom-Json
if ($local.workFolder -cne $settings.linux.workFolder) { throw 'Resolve the existing work-folder mismatch before this acceptance run.' }
./scripts/New-LinuxRunner.ps1 -TimeoutMinutes 5
if ($LASTEXITCODE -ne 0) { throw 'Recreation failed; inspect the retained maintenance record.' }
```

This uses the existing drain path, stops/recreates the Linux runner and sidecar,
and restores custom labels. It does not use `-Force` or `-Update`. Registration,
credentials and Docker data volumes remain in their existing locations. Inspect
the live mounts, then rerun the eligibility check (with the same org candidate
when applicable), and require the runner ID/name to equal `$before`. A retained
maintenance record or unavailable runner is a failed acceptance step.

## 3. Probe actual nested container mounts

```powershell
./tests/Invoke-LinuxJobContainerProbe.ps1
```

This uses the running Linux runner's existing Docker connection, creates a unique
temporary workspace marker and versioned-directory symlink, then starts one
bounded nested container with the pinned BuildAgent image. It must read the same
marker through both workspace and symlink binds and execute the real runner's
`/__e/node24/bin/node`. The report records the resolved live externals target,
image, mode, runtime and result. Only the uniquely named test container and
temporary workspace are cleaned; nothing prunes Docker or stops the runner.
Each CLI command has a timeout, with cleanup attempted even on failure.

## 4. Install the manual workflow in the verified consumer

From this same reviewed Runners revision, propose these **new** consumer files:

- `tests/linux-runner-docs-smoke.yml` copied to `.github/workflows/self-hosted-docs-smoke.yml`
- The `scripts/docs-smoke/` directory
- The `tests/fixtures/self-hosted-docs/` directory

Use a consumer branch/PR, stop on path collisions, and inspect its existing
push/PR automation before committing. This Runners PR does not install files in
an unidentified consumer. GitHub requires the manual workflow on the default
branch before its first dispatch. Keep the consumer merge as a distinct reviewed
action; this preparation does not merge either repository.

## 5. Dispatch and judge the actual result

After confirming the exact consumer/ref and expected runner ID/name:

```powershell
gh workflow run self-hosted-docs-smoke.yml --repo $before.repository --ref '<reviewed ref>' `
  -f "correlation_id=$([guid]::NewGuid().ToString('N'))" `
  -f "expected_runner_name=$($before.runnerName)" -f "expected_runner_id=$($before.runnerId)"
```

There are only manual triggers, no inherited secrets and `deploy: false`. The
reusable workflow requires its existing `contents: read`, `pages: write` and
`id-token: write` caller permissions even with its Deploy job skipped. The
verification job runs on `ubuntu-latest`, downloads the actual Pages
`artifact.tar`, verifies rendered content/assets and embedded run/attempt/commit
evidence, and checks the current-attempt GitHub Build job against the expected
runner name **and numeric ID**. An optional upload failure becomes a smoke-test
failure. A job routed to a different runner cannot establish acceptance.

Keep both `self-hosted-docs-site` and `self-hosted-docs-result` artifacts (one-day
retention), the workflow run/job URLs and host probe JSON. The result artifact
contains `result.json` and available `jobs.json`, including a build that failed
before its hook. The selected immutable image reference is recorded; GitHub's
container-initialization log provides the actual pull/start output. GitHub/API,
artifact-service or evidence failures cannot count as success.

The reusable Build execution timeout is 30 minutes. An offline/ineligible runner
can leave a job queued before that timer starts. Static checks or a successful
Windows acceptance run do not count as Linux smoke acceptance.

## Reproduce preparation checks

```powershell
./tests/Test-LinuxJobContainerMounts.ps1
./scripts/docs-smoke/Test-Eligibility.ps1
./tests/Test-LinuxDocsSmokeController.ps1
node --test scripts/docs-smoke/smoke.test.mjs
# External executable fixture checks require Linux:
./tests/Test-LinuxJobContainerProbe.ps1
actionlint -shellcheck='' tests/linux-runner-docs-smoke.yml .github/workflows/windows-runner-validation.yml
```

References: [pinned reusable workflow](https://github.com/The-Running-Dev/GitHub-ActionTemplates/blob/1c3b5f76554aca455cd4a284c4e473edd21c0d72/.github/workflows/docs.yml),
[runner 2.338.0 job-container mounts](https://github.com/actions/runner/blob/v2.338.0/src/Runner.Worker/ContainerOperationProvider.cs),
[manual workflow requirements](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow).
