# Testing

Every script that changes host state has a `tests\Test-*.ps1` that runs it against fakes (a fake Docker, a fake `gh`,
isolated `LOCALAPPDATA` folders). None of them touches your real runners, registrations or GitHub. The tests are plain
PowerShell scripts that print their assertions and exit non-zero on a failure; there is no test framework to install.

## Run them

From the repository root, in PowerShell 7.2+ on Windows:

```powershell
./tests/Test-RunnerSettings.ps1          # one suite
./tests/Test-Compose.ps1
```

Run every suite CI runs, stopping at the first failure:

```powershell
$suites = Select-String -Path .github/workflows/windows-runner-validation.yml -Pattern 'run: (\./\S+\.ps1)' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
foreach ($suite in $suites) { Write-Host "== $suite"; & $suite; if ($LASTEXITCODE) { throw "$suite failed ($LASTEXITCODE)" } }
```

The hosted Linux job also needs Node 22 and bash (`tests/Test-LinuxRunnerRuntimes.sh`, `scripts/docs-smoke/smoke.test.mjs`):

```powershell
node --test scripts/docs-smoke/smoke.test.mjs
bash tests/Test-LinuxRunnerRuntimes.sh
```

## What each suite covers

| Suite | Covers |
| --- | --- |
| `Test-WindowsRunnerInstances` | Parses every PowerShell file, guards against duplicate function definitions outside `tests\`, exercises isolated instances |
| `Test-RunnerSettings` | Settings validation, slot names, `runners.host.json` layering and drift |
| `Test-RunnerIntegration` | Configuration, BuildAgent invocation, registration, drain, housekeeping and Linux image guards |
| `Test-LifecycleRecovery` | Failed stops, label recovery state and supervisor recovery, including a real supervisor process |
| `Test-HostState` | Inventory, journal, host lock, Adopt, Plan and Status |
| `Test-Maintenance` | AutoStart keeps maintenance; Hold and Resume; the Startup entry |
| `Test-Compose` | Compose generation, per-slot recreate, the image context hash, runtime isolation mount, Linux status |
| `Test-LinuxRunnerUpdate` | The guarded Linux updater with synthetic native calls and admission |
| `Test-LinuxJobContainerMounts`, `Test-LinuxJobContainerProbe` | Job-container mounts and the opt-in probe against a fake Docker |
| `Test-BuildAgentProvisioning` | BuildAgent provisioning and resumable setup state |
| `Test-WindowsRunnerHostSetup`, `Test-WindowsRunnerBootstrap` | Automated host setup with isolated fixtures; the bootstrap under stock Windows PowerShell 5.1 |
| `Test-WindowsRunnerAutomaticAcceptance`, `Test-WindowsRunnerAcceptanceSafeguards` | Resumable automatic acceptance, ownership, interrupted or refused dispatch, stale runners |
| `Test-WindowsRunnerBuildAgentDispatch`, `...BuildAgentEvidence`, `...SmokeEvidence` | Acceptance dispatch with a fake `gh`; evidence checkers with synthetic results |
| `Test-WindowsRunnerRepositoryScope` | Intended repository scope is verified before runners are configured |
| `Test-WindowsHostAcceptance` | Host acceptance against fake clones |
| `Test-LinuxDocsSmokeController`, `scripts\docs-smoke\Test-Eligibility` | Consumer preparation, dispatch recovery, eligibility from a fake GitHub inventory |

## CI

`.github/workflows/windows-runner-validation.yml` has two jobs: the PowerShell suites on a Windows runner, and the Linux
docs-smoke fixtures on a hosted runner. A new script needs a `tests\Test-*.ps1` and a line in that workflow.

## Live checks (not in CI)

These use real runners and a real private repository, so run them by hand when you change that behavior:

- `tests\Invoke-WindowsHostAcceptance.ps1` and `tests\Invoke-WindowsRunnerBuildAgentAcceptance.ps1`: builds and lifecycle
  checks on a provisioned Windows host (see the [Windows runbook](windows-two-runners.md#buildagent-acceptance-real-builds)).
- `Setup-WindowsRunners.ps1 -Repository OWNER/PRIVATE-REPO`: the same checks, run and journaled by setup.
- Linux live acceptance: [Linux docs smoke](linux-docs-smoke.md).
