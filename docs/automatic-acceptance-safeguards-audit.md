# PR #12 automated acceptance safeguard audit

Date: 2026-11-09. Baseline: merged main `e1375d838815d417d84609fa0b2e1f034a00fbbf` (PR #12). The supplied `a427f52` controller is unchanged in that merge. Corrections in this branch are proposed; nothing has been merged or exercised on a real runner host.

## Verdict

**PR #12 is not cleared for unattended acceptance on a host serving unrelated jobs.** The existing code has useful identity and maintenance protections, but interruption recovery has concrete gaps. This patch closes the reproduced journal and response-validation gaps. It does not establish exclusive ownership of a live runner between a GitHub observation and the eventual local stop, or serialize concurrent setup processes.

A controlled first Windows run remains a separate, explicitly approved operation. Passing the synthetic tests below establishes controller behavior under those fixtures; it does not establish Windows installation, Docker Desktop behavior, or successful private-repository execution.

## Findings and corrections

| Finding in merged code | Consequence | Proposed correction and proof |
| --- | --- | --- |
| Recovery searches for an undiscovered dispatch for about one minute, then clears `activeRun` even if no run was found. Discovery reads only the first 100 runs. | A delayed/indexing-hidden job can survive recovery; setup can dispatch another job and proceed with installation. | Search paginated results, reject duplicate correlations, and retain the journal and block setup when discovery is inconclusive. Recovery regression fails against baseline and passes here. |
| BuildAgent dispatch has no durable dispatch journal. It discovers by title and then trusts refreshed run data for cancellation. | Process termination can orphan builds. A wrong refreshed ID can redirect its later read/cancel path. | Persist intent before POST, share the setup journal, recover before redispatch, retain ambiguous failures, and keep the original ID fixed. The fake-gh dispatcher tests cover lost POST responses, discovery failure, retry and changed refresh IDs. |
| Lifecycle cancellation checks event/path/title, but not returned ID or run attempt. | Unexpected responses or an operator's rerun can be treated as the original controlled attempt. | Validate ID, event, exact workflow path/title, branch when recorded, original attempt and recognized status on discovery, refresh, cancellation and completion confirmation. Mismatch preserves the journal. |
| The final lifecycle job recheck checks job ID and hold status but does not repeat runner name/ID verification. The local registration is not re-read. | A changed response or registration can invalidate the previously selected clone while disruption proceeds. | Re-read local registration, validate the run, and require exactly one matching job/run/attempt/runner/active hold immediately before the child call. Regressions cover changed name, ID, local registration, ended hold, wrong run/attempt and duplicate jobs. |
| Removing verification options bypasses `Resume-RunnerSetupAcceptance`, allowing the installer to start a supervisor/end maintenance. | An interrupted acceptance hold can be reopened by a changed invocation. | Block setup with an active journal unless the original verification repository is supplied. Baseline regression records an installer call; patched code refuses it before installation. |
| Workflow reads and creates rely on the implicit default branch. The build installer interprets any failed content read as absence. | A default-branch change can redirect a write away from the inspected branch; read failures can provoke an unjustified create attempt. | Share the lifecycle/build installer, require successful directory reads, reject malformed/empty/null responses and differing content, and pass an explicit branch on every Contents read/create. Creation supplies no existing blob SHA. A concurrent file creation is left to GitHub's create-conflict handling. |
| Checkpoints explicitly include source, names/IDs and configuration hashes, but omit the requested scope, count and clone-to-instance mapping. | Historical evidence does not explicitly describe the full setup selection. | Include those fields in the profile. Existing source/configuration/registration invalidation tests are extended for scope and instance ordering. |

The cancellation checks protect against response inconsistency; they are not a claim that GitHub ordinarily returns another run for a requested ID. No account compromise is assumed by the audit.

## Execution trace and verified protections

| Phase | Reads, mutations and failure behavior |
| --- | --- |
| Preflight and registration | `Invoke-WindowsRunnerHostSetup` checks verification scope, count, BuildAgent eligibility and existing private target. Authentication preflight can request a registration token. Installer may register/adopt runners and start supervisors; it is a consequential operation, not a read-only check. Recovery runs before these instance operations. |
| Repository modification | Build and lifecycle templates become `.github/workflows/windows-runner-buildagent.yml` and `.github/workflows/windows-runner-lifecycle-acceptance.yml`. Equal content is retained; differing content is refused. Missing files are committed separately by the Contents API to the inspected default branch. They are not automatically deleted or reverted. |
| Host and concurrent builds | Live readiness is checked on every acceptance invocation. Host acceptance builds the pinned fixture, checks adoption, and reruns setup without recursive acceptance. Build acceptance targets the host pair label, receives expected runner names and pinned tool/image inputs, and invokes the existing evidence checker. |
| Lifecycle dispatch and selection | Each Drain/Timeout/Force dispatch records a unique correlation before POST. Routing uses the host pair label; the actual clone is selected by runner name and numeric agent ID. Only an active controlled hold is eligible. The selected clone must belong to the requested installation. |
| Maintenance and stop | `Stop-WindowsRunner` records maintenance before withdrawing custom labels. Drain waits for idle. Timeout must prove labels restored and maintenance cleared. Force can stop active processes. An unverified/failed stop retains maintenance; the host acceptance script withholds Start unless stop exited successfully and the runner is observed stopped/idle. These production lifecycle routines are unchanged by this patch. |
| Cancellation | Cleanup addresses only the persisted run ID, revalidates the allowed workflow/correlation/branch/original attempt, and confirms completion. It does not enumerate and cancel arbitrary busy jobs. An unconfirmed cancellation retains the journal. |
| Interrupted-run recovery | Wrong repository/outside-installation clone is refused. Missing ID is resolved through the persisted correlation. Unresolved identity now blocks, including an intent saved before a POST whose result was lost. `stopAttempted` requires readable maintenance facts and refuses a retained hold. A crash before a POST is indistinguishable from a lost response; this intentionally requires reconciliation if no run ever appears. |
| Checkpoints | Successful stages are saved separately; a later failure does not mark that stage complete or erase earlier completed stages. Source/selection/configuration changes invalidate historical stage results. Checkpoints describe previous successful checks, not continuous health. |

## Remaining risks

1. **Observation-to-stop race.** The last GitHub hold check, journal save, child startup and eventual `Stop` are separate operations. If the hold finishes or is externally cancelled in that interval, an unrelated job might occupy the same runner. Another name/ID check alone cannot make that interval atomic. This remains a blocker to a guarantee of safe disruption on shared busy runners.
2. **Custom-label withdrawal is not complete admission isolation.** As the existing management script documents, a workflow targeting only `self-hosted`, `Windows` and `X64` can still route to the runner. Force intentionally tolerates admission-closure failures. The patch does not turn these routines into exclusive job leases.
3. **Concurrent controllers are not serialized.** Two setup/build invocations sharing an installation/journal can race its read/replace operations and overwrite active-run tracking. Temporary-file replacement reduces torn-write exposure, but is not a mutual-exclusion lock. Concurrent setup must not be considered supported by this patch.
4. **Default-branch commits can activate existing repository automation.** The two acceptance templates use `workflow_dispatch`, but creating their files still creates real commits. Existing push-triggered workflows, webhooks or external automation may react to those commits. No permission or workflow-conflict check prevents those secondary effects. Partial installation (one file committed before a later failure) remains possible.
5. **Remote workflow content is mutable after inspection.** Explicit branch selection prevents accidental redirection by a changed default, but it does not prevent another actor editing that branch before dispatch. The code does not pin dispatch to an immutable reviewed tag or prove the dispatched workflow's blob.
6. **Historical/unavailable state needs human reconciliation.** A deleted run, GitHub list limits/outage, unreadable journal, retained maintenance, or build dispatched by an older version without a journal can need manual investigation. The patch prefers blocking to guessing. Old journals without a workflow field retain lifecycle compatibility, but lack a recorded branch constraint.

These are source-level observations and scheduling inferences, not reproduced damage to a real host or repository.

## Validation performed

Local runtime: PowerShell 7.5.4 on Linux. All GitHub and runner mutations in the controller suites were mocked.

| Check | Result |
| --- | --- |
| `Test-WindowsRunnerAcceptanceSafeguards.ps1` | PASS: 42 assertions. |
| Same new suite against unmodified merged scripts, selecting Recovery, Cancellation, Disruption and Options separately | All four scenarios FAIL at the intended regression assertion. |
| `Test-WindowsRunnerAutomaticAcceptance.ps1` | PASS, including child argument/exit handling, three lifecycle modes, maintenance holds, failure/resume, live readiness and expanded checkpoint invalidation. Its printed synthetic child exception is expected and asserted. |
| `Test-WindowsRunnerBuildAgentDispatch.ps1` | PASS, including new lost-response/discovery/identity cases and existing installation/input/evidence checks. |
| `Test-WindowsRunnerRepositoryScope.ps1` | PASS. |
| Parse every PowerShell file; `git diff --check` | PASS. |
| Full HostSetup and BuildAgent evidence suites | Not validated here: fixtures require the Windows `C:` drive. |
| Full lifecycle recovery suite | Not validated here: Windows environment prerequisites are absent (`ProgramFiles` at the initial failure). |
| Full host acceptance suite | Not claimed passed. Automatic approval review blocked the run after an unsolicited Application Insights connection with an unestablished payload; it was not retried or bypassed. |
| Windows CI | Not run for this audit. The proposed commit uses `[skip ci]` so publishing its review branch/PR does not run the existing push/pull_request workflow. |

The new safeguard suite is wired into the existing Windows validation workflow for a separately approved validation run.

## Real-host actions requiring a separate exact approval

No target private repository, install root, final source revision or live runner IDs have been selected for execution by this audit. Before execution, a concrete plan must identify those actual values and enumerate:

- The source revision and exact setup command; prerequisite installation/elevation, possible interactive Docker actions, and registration/adoption/start of each named runner.
- Each proposed workflow file, its exact contents, target branch and commit operation, plus existing repository automation that could be triggered.
- One BuildAgent workflow dispatch and one lifecycle dispatch per uncompleted Drain/Timeout/Force stage (with their exact inputs and target labels).
- Which controlled run/runner/clone may be drained, timed out, forcibly stopped, restarted or cancelled; how interrupted owned runs and retained maintenance will be handled.
- The checks for exclusive use of the host during disruption, and the remaining race/default-label limitations above.

No runner registration, stop, workflow dispatch, private-target default-branch modification or merge was performed in this audit.

## Sources

- [PR #12](https://github.com/The-Running-Dev/SubZeroDev.Runners/pull/12)
- [Merged controller](https://github.com/The-Running-Dev/SubZeroDev.Runners/blob/e1375d838815d417d84609fa0b2e1f034a00fbbf/scripts/WindowsRunnerAcceptance.ps1)
- [Merged build dispatcher](https://github.com/The-Running-Dev/SubZeroDev.Runners/blob/e1375d838815d417d84609fa0b2e1f034a00fbbf/tests/Invoke-WindowsRunnerBuildAgentAcceptance.ps1)
- [Merged host acceptance](https://github.com/The-Running-Dev/SubZeroDev.Runners/blob/e1375d838815d417d84609fa0b2e1f034a00fbbf/tests/Invoke-WindowsHostAcceptance.ps1)
- [Merged lifecycle](https://github.com/The-Running-Dev/SubZeroDev.Runners/blob/e1375d838815d417d84609fa0b2e1f034a00fbbf/scripts/Lifecycle.ps1)
- [GitHub dispatch reference requirements](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)
- [GitHub skip instructions and their event limitations](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs)
