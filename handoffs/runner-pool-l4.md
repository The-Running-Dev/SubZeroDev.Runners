# Handoff: L4, moving the org's repositories onto the pool

Read [docs/runner-pool-plan.md](../docs/runner-pool-plan.md) first; its decisions D1–D4 still bind. S1–S9 in
[runner-pool.md](runner-pool.md) built the pool and passed L3 on beast (2026-11-24). L4 moves the other
repositories' jobs onto it.

## Where the repositories are (checked on GitHub, 2026-11-24)

Every job in the org's private repositories runs on GitHub-hosted runners. Each repository moved to the
self-hosted labels on 2026-10-30/31 and moved back on 2026-11-10 ("restore GitHub-hosted runners": HotCorners #219,
Licensing #70, Media #54, Cleaner `2b1963a`), so that it "no longer depends on local runner availability". The plan's
statement that the pool needs no workflow change no longer holds: every L4 move is a workflow change.

| Repository | Workflow / job | Runs on today | Selected through |
| --- | --- | --- | --- |
| Cleaner | `ci.yml` `dotnet` | `windows-latest`; utility jobs `ubuntu-latest` | ActionTemplates `dotnet.yml` inputs `os`, `utility-runs-on` |
| HotCorners | `ci.yml` `dotnet` | `windows-latest`; utility jobs `ubuntu-latest` | `dotnet.yml` inputs `os`, `utility-runs-on` |
| HotCorners | `claude-code-review.yml` | `ubuntu-latest` | `runs-on` |
| HotCorners | `release.yml` (`environment: release`) | `windows-latest` | `runs-on` |
| Licensing | `ci.yml` `linux`, `package` | `ubuntu-latest` | `runs-on` |
| Licensing | `ci.yml` `windows` | `windows-latest` | `runs-on` |
| Licensing | `ci.yml` `publish` | `ubuntu-latest` | `dotnet.yml` input `utility-runs-on` |
| Licensing | `container.yml` `image` | `ubuntu-latest` | ActionTemplates `container.yml` inputs `runs-on` (needs Docker), `utility-runs-on` |
| Licensing | `container.yml` `deploy` (`environment: production`) | `ubuntu-latest` | `runs-on` |
| Licensing | `claude-code-review.yml` | `ubuntu-latest` | `runs-on` |
| Media | `ci.yml` `web`, `linux` | `ubuntu-latest` | `runs-on` |
| Media | `ci.yml` `dotnet` | `windows-latest` | `dotnet.yml@v2` input `os` |
| Media | `ci.yml` `windows-package` | `windows-latest` | `runs-on` |
| Media | `release.yml` `release` (`environment: release`) | `windows-latest` | `runs-on` |
| HollowMoon | `build.yml` `build` | `windows-latest` | `runs-on` (PR #4, merged 2026-11-10, builds in BuildAgent) |
| HollowMoon | `release.yml` `build` (`environment: package-signing`), `publish` (`environment: release`) | `windows-latest` | `runs-on` |
| HollowMoon | `self-hosted-docs-smoke.yml` (manual) | `docs` on `subzerodev-linux`, `verify` on `ubuntu-latest` | `docs.yml` input `runs-on` |
| Architecture | `docs.yml` `docs` | `ubuntu-latest` (template default) | `docs.yml` input `runs-on` |

Repositories under The-Running-Dev (Dashboard, Notes, Infra, FileManager and others) cannot use the org's runners and
are outside L4. `SubZeroDev.Platform.Updater` is public and stays excluded (D1).

## Decisions for the owner

| | Question | Proposed | Why |
| --- | --- | --- | --- |
| D5 | How does a repository fall back to hosted runners when beast is down? | **(b)** a repository variable per OS selects the runner; unset means hosted. | The 2026-11-10 move back was about availability. With (a), label-only `runs-on`, a job waits for beast for up to 24 hours and falling back takes a PR in each repository. With (b) it is one variable change, and no PR. |
| D6 | Do release, signing and deploy jobs move? | **Not in L4 by default.** Each one moves only on the owner's explicit yes, in L4-7. | They hold signing and publishing secrets and environment approvals. Slots run privileged dind (D1), so a workflow on the same host could reach them. |

Until D5 is decided, L4-1 does not start.

## The switch (D5 (b))

- Repository variables are `SUBZERODEV_WINDOWS_RUNS_ON` and `SUBZERODEV_LINUX_RUNS_ON`.
  - The self-hosted values are `subzerodev-windows` and `subzerodev-linux`, the pool's existing labels.
  - L4-1 checks whether an organization variable reaches a private repository on the Free plan. The later slices use an org variable only if it does.
- Direct jobs use `runs-on: ${{ vars.SUBZERODEV_WINDOWS_RUNS_ON || 'windows-latest' }}`, and the same with the Linux variable and `ubuntu-latest`.
- Jobs that call an ActionTemplates workflow:
  - The list input becomes `os: ${{ format('["{0}"]', vars.SUBZERODEV_WINDOWS_RUNS_ON || 'windows-latest') }}`.
  - The label inputs (`runs-on`, `utility-runs-on`) take the Linux expression.
  - No template changes.
- The slice sets the variable for the L2 run on its PR's head. Until the PR merges, main's workflows don't read the variable, so setting it early changes nothing there. The variable stays set after the merge, and clearing it is the rollback.

## Gate for each job

- A job that only changes runner (no stage moves into BuildAgent) needs **L2**:
  - its check passes on a pool slot, from the slice PR's own head, with the variable set;
  - with the variable cleared it passes on hosted runners once.
- L1 applies only when a stage moves into BuildAgent (L4-6).
- Each L2 run is linked in the slice PR, and the repository's row in the plan's validation table is updated.
- A job that fails on a slot and cannot be fixed inside that repository's slice stays hosted, with the cause recorded. It is not worked around in this repository's scripts without a separate slice.

## What to build (one PR per slice, in the repository it names, in order)

0. **Plan (this repository).** This handoff. Correct the plan's per-job rollout and validation tables to match the
   inventory above.
1. **Cleaner `ci.yml`.**
   - Add the switch to `os` and `utility-runs-on`, then set both variables.
   - This is the smallest Windows job, and it proves the switch and the `dotnet.yml` input expressions.
   - Record whether an org variable would have worked.
2. **HotCorners `ci.yml` and `claude-code-review.yml`.**
   - Switch both.
   - On a Linux slot the review job uses its secrets. D1 allows this because the owner is the only writer.
3. **Licensing `ci.yml` (`linux`, `package`, `windows`, `publish`), `container.yml` `image`, and `claude-code-review.yml`.**
   - `linux`, `package` and `image` need Docker in the slot: image builds, the acceptance topology, and the proxy through Docker's host (`c3bad5f`). The Linux slots' dind provides it.
   - `windows` keeps the registry machine identity and the 64- and 32-bit processes native.
   - `container.yml` `deploy` stays hosted (D6).
4. **Media `ci.yml` (`web`, `linux`, `dotnet`, `windows-package`).**
   - Media used most of the Windows minutes in October.
   - `dotnet` calls `dotnet.yml@v2`, a moving tag. The slice keeps the reference as it is; pinning it is that repository's own change.
   - The `wasm-tools` workload install runs per job. Check its time on a slot against the hosted run.
5. **HollowMoon `build.yml`, `self-hosted-docs-smoke.yml` `verify`, and Architecture `docs.yml`.**
   - `build.yml` turns the throwaway-branch L2 from 2026-11-24 into the merged state.
   - Architecture passes the Linux expression as `runs-on` and `utility-runs-on`.
6. **BuildAgent stages (optional, one PR per project).**
   - Only after that job passes L2 on the pool.
   - Each move needs L1 and L2: HotCorners non-UI tests, Cleaner, and Media `dotnet`/`windows-package`, if they cross-build. HollowMoon was done in PR #4.
   - Skipping this slice leaves L4 complete.
7. **Release, signing and deploy jobs (D6).**
   - Only for the jobs the owner names: HotCorners and Media `release.yml`, HollowMoon `release.yml` (`package-signing`, `release`), and Licensing `container.yml` `deploy` (`production`).
   - Each keeps its environment and protection rules.
   - The first run of each is dispatched by the owner.
8. **Record (this repository).**
   - The validation table gets one L4 row per repository.
   - L4 is done when every non-release job has passed L2 on the pool or has a recorded reason to stay hosted.

## Unchanged

- The pool's labels, BuildAgent, ActionTemplates, and every `environment:` with its protection rules.
- Triggers, secrets and artifact retention in each workflow.
- No repository variable is set before its slice starts.
