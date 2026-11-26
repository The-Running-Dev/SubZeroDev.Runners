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
| D5 | How does a repository fall back to hosted runners when beast is down? | **(b)**, approved 2026-11-24: a repository variable per OS selects the runner; unset means hosted. | The 2026-11-10 move back was about availability. With (a), label-only `runs-on`, a job waits for beast for up to 24 hours and falling back takes a PR in each repository. With (b) it is one variable change, and no PR. |
| D6 | Do release, signing and deploy jobs move? | **Not in L4 by default.** Each one moves only on the owner's explicit yes, in L4-7. | They hold signing and publishing secrets and environment approvals. Slots run privileged dind (D1), so a workflow on the same host could reach them. |

## The switch (D5 (b))

- Repository variables are `SUBZERODEV_WINDOWS_RUNS_ON` and `SUBZERODEV_LINUX_RUNS_ON`.
  - The self-hosted values are `subzerodev-windows` and `subzerodev-linux`, the pool's existing labels.
  - They are repository variables. On the Free plan an organization variable does not reach a private repository
    (GitHub Docs, "Using secrets in GitHub Actions"), so each slice sets its own.
- Direct jobs use `runs-on: ${{ vars.SUBZERODEV_WINDOWS_RUNS_ON || 'windows-latest' }}`, and the same with the Linux variable and `ubuntu-latest`.
- Jobs that call an ActionTemplates workflow:
  - The list input becomes `os: ${{ format('["{0}"]', vars.SUBZERODEV_WINDOWS_RUNS_ON || 'windows-latest') }}`.
  - The label inputs (`runs-on`, `utility-runs-on`) take the Linux expression.
  - ActionTemplates gates rejected an expression in any `with:` input. [ActionTemplates #54](https://github.com/The-Running-Dev/GitHub-ActionTemplates/pull/54)
    (`a73c2e3`) lets the runner inputs (`os`, `pack-os`, `runs-on`, `utility-runs-on`) take one, so a caller pins
    `a73c2e3` or a later release.
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
1. **Cleaner `ci.yml`.** Done 2026-11-24, [Cleaner #30](https://github.com/AbsoluteZeroDev/SubZeroDev.Cleaner/pull/30).
   - L2 on head `3fdc591`, [run 45487347854](https://github.com/AbsoluteZeroDev/SubZeroDev.Cleaner/actions/runs/45487347854):
     - hosted (variables cleared): attempt 1 passed;
     - pool (variables set): attempt 3 passed, with Test on `beast.win01` and Result on `beast.linux.02`.
   - Attempt 2 on the pool failed `On_this_machine_the_reported_total_matches_the_space_Windows_says_came_back`. The test measures free space on the whole C: volume, which beast shares with Dropbox, Docker and the other slots. It was 113 MiB off against a 100 MiB tolerance, and passed on rerun. It can fail again on beast.
   - Needed first:
     - [ActionTemplates #54](https://github.com/The-Running-Dev/GitHub-ActionTemplates/pull/54), so gates accept the runner expressions;
     - [Cleaner #31](https://github.com/AbsoluteZeroDev/SubZeroDev.Cleaner/pull/31), which fixed 14 CsWinRT1032 test-build errors from the `windows-latest` image of 2026-11-16. That image fails Cleaner's main too.
   - Cleaner's `Main` ruleset required secret-scanning alert resolution while secret scanning is off, which blocked every merge. The rule was removed on the owner's yes, matching HotCorners and Media.
   - Org variables don't reach private repositories on Free, so the later slices also use repository variables.
2. **HotCorners `ci.yml` and `claude-code-review.yml`.** Done 2026-11-25, [HotCorners #220](https://github.com/AbsoluteZeroDev/SubZeroDev.HotCorners/pull/220).
   - Both switched; the template pin moved from `314ba4f` (v2.0.0) to `a73c2e3` (#54). `release.yml` stays hosted (D6).
   - L2 on head `3c3262b`:
     - hosted (variables unset): [CI](https://github.com/AbsoluteZeroDev/SubZeroDev.HotCorners/actions/runs/45581726305/attempts/1) and [review](https://github.com/AbsoluteZeroDev/SubZeroDev.HotCorners/actions/runs/45581724664/attempts/1) attempt 1 passed;
     - pool (variables set): [CI attempt 2](https://github.com/AbsoluteZeroDev/SubZeroDev.HotCorners/actions/runs/45581726305/attempts/2) passed, with Test on `beast.win01` and Result on `beast.linux.02`; [review attempt 3](https://github.com/AbsoluteZeroDev/SubZeroDev.HotCorners/actions/runs/45581724664/attempts/3) passed on `beast.linux.02`.
   - The pool jobs first queued because every beast runner was offline: beast's clock had drifted (the WSL VM was about 4h20m behind), so the Linux tokens expired and `win01` failed to create a session. Resyncing the Windows clock, `wsl --shutdown` and restarting `win01` brought them back. Review attempt 2 lost its runner during that WSL restart.
   - On a Linux slot the review job uses its secrets. D1 allows this because the owner is the only writer.
3. **Licensing `ci.yml` (`linux`, `package`, `windows`), `container.yml` `image`, and `claude-code-review.yml`.** Done 2026-11-25, [Licensing #77](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/pull/77) and [#78](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/pull/78).
   - All five switched; the container template pin moved from `314ba4f` (v2.0.0) to `a73c2e3` (#54). Between the two, the template only gained a Portainer path in its own deploy job, which Licensing does not enable.
   - L2 on head `a099b9f`:
     - hosted (variables unset): [CI](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45605650633/attempts/1), [Container](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45605649712/attempts/1) and [review](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45605649103/attempts/1) attempt 1 passed;
     - pool (variables set), attempt 2 passed on the first try: [CI](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45605650633/attempts/2) with `linux` on `beast.linux.02`, `package` on `beast.linux.01` and `windows` on `beast.win01`; [Container](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45605649712/attempts/2) Build and Result on `beast.linux.01`; [review](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45605649103/attempts/2) on `beast.linux.01`.
   - The Linux slots' dind provided Docker for the image builds, the acceptance topology and the PostgreSQL tests. `windows` ran the registry machine identity tests as 64- and 32-bit processes on `win01`.
   - The template's `Publish` (GHCR push) shares the `runs-on` input with `Build` and runs only on main. Its first pool run, [main run 45609867090](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45609867090), failed in the branch-tip gate: `The term 'gh' is not recognized`. The Linux slot image does not ship the `gh` CLI, and adding it is a change to this repository, not to Licensing, so the image's `Build` and `Publish` went back to hosted in [Licensing #78](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/pull/78). `Result` (`utility-runs-on`) stays on the pool. Nothing was pushed or deployed for `eb10545`. After #78, [main run 45612715897](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45612715897) built and published on hosted, with `Result` on `beast.linux.02`, and [Infra deploy 45613121926](https://github.com/The-Running-Dev/SubZeroDev.Infra/actions/runs/45613121926) succeeded. The hosted `Deploy` job still failed: `infra-deploy` dispatched the Infra run, then got HTTP 404 reading it back. That job did not move, so the failure is outside L4.
   - Pool follow-up, done 2026-11-25: [Runners #43](https://github.com/The-Running-Dev/SubZeroDev.Runners/pull/43) added a pinned `gh` 2.103.3 to the Linux slot image, and [Licensing #79](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/pull/79) moved `Build` and `Publish` back to the variable. [Main run 45661101149](https://github.com/AbsoluteZeroDev/SubZeroDev.Licensing/actions/runs/45661101149) ran Build, Publish (branch-tip gate and GHCR push) and Result on `beast.linux.02`; `Deploy` stayed hosted and succeeded.
   - Stay hosted: `ci.yml` `publish`, which runs only on a version tag and cannot pass L2 from a PR, and `container.yml` `deploy` (D6).
4. **Media `ci.yml` (`web`, `linux`, `dotnet`, `windows-package`).** Done 2026-11-26, [Media #71](https://github.com/AbsoluteZeroDev/SubZeroDev.Media/pull/71).
   - All four switched. ActionTemplates v2.3.0 moved `v2` onto #54 first; `dotnet.yml@v2` stays a moving tag.
   - L2 on head `dfc164b`, [run 45684554656](https://github.com/AbsoluteZeroDev/SubZeroDev.Media/actions/runs/45684554656):
     - hosted (variables unset): [attempt 1](https://github.com/AbsoluteZeroDev/SubZeroDev.Media/actions/runs/45684554656/attempts/1) passed;
     - pool (variables set): [attempt 2](https://github.com/AbsoluteZeroDev/SubZeroDev.Media/actions/runs/45684554656/attempts/2) passed `web` on `beast.linux.01`, `linux` and `dotnet` Result on `beast.linux.02`, and `dotnet` Test on `beast.win01`; `windows-package` failed on `win01`. [Attempt 3](https://github.com/AbsoluteZeroDev/SubZeroDev.Media/actions/runs/45684554656/attempts/3) reran it and passed on `win01`.
   - `windows-package` failed because the Windows slots shared the user's TMP and TEMP. [Runners #46](https://github.com/The-Running-Dev/SubZeroDev.Runners/pull/46) gave each slot its own, and `win01` was updated before attempt 3.
   - Job times, hosted against pool: `dotnet` Test 22.0 min against 7.9 min; `windows-package` 11.5 against 7.4; `web` 5.1 against 11.5; `linux` 6.3 against 12.1. The two Linux jobs ran at the same time on one host, which shares its CPU with the Windows slot; the `wasm-tools` install still runs per job.
   - Known risk: the Uno emsdk cache under `%USERPROFILE%\.uno\emsdk` is shared by every Windows slot on a host. One slot runs today, so it has not collided.
   - Stays hosted: `release.yml` `release` (D6).
   - Media used most of the Windows minutes in October.
   - `dotnet` calls `dotnet.yml@v2`, a moving tag. The slice keeps the reference as it is; pinning it is that repository's own change.
     The switch needs a `v2` release that includes ActionTemplates #54 before this slice starts.
   - The `wasm-tools` workload install runs per job. Check its time on a slot against the hosted run.
5. **HollowMoon `build.yml`, `self-hosted-docs-smoke.yml` `verify`, and Architecture `docs.yml`.** Done 2026-11-26, [HollowMoon #7](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/pull/7) and [Architecture #5](https://github.com/AbsoluteZeroDev/SubZeroDev.Architecture/pull/5).
   - `build.yml` turns the throwaway-branch L2 from 2026-11-24 into the merged state.
   - Architecture passes the Linux expression as `runs-on` and `utility-runs-on`, pinned to ActionTemplates `a73c2e3` (#54); `docs.yml` is unchanged since v2.0.0.
   - HollowMoon L2 on head `6a2293c`:
     - `build`: [run 45865388300](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45865388300) passed hosted in [attempt 1](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45865388300/attempts/1) (2.2 min) and on `beast.win01` in [attempt 2](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45865388300/attempts/2) (2.1 min);
     - smoke `verify`: hosted in [run 45867565586](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45867565586) and on `beast.linux.01` in [run 45868495889](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45868495889), both passed.
   - The smoke's `expected_runner_*` inputs must name the slot that `docs` lands on. With two Linux slots that is a guess, so [run 45865486066](https://github.com/AbsoluteZeroDev/SubZeroDev.HollowMoon/actions/runs/45865486066) failed `verify` on a mismatch and was redispatched.
   - Architecture L2 on head `1f120c9`, [run 45865380135](https://github.com/AbsoluteZeroDev/SubZeroDev.Architecture/actions/runs/45865380135): `docs / Build` passed hosted in [attempt 1](https://github.com/AbsoluteZeroDev/SubZeroDev.Architecture/actions/runs/45865380135/attempts/1) (2.4 min) and on `beast.linux.01` in [attempt 2](https://github.com/AbsoluteZeroDev/SubZeroDev.Architecture/actions/runs/45865380135/attempts/2) (5.8 min).
   - Stays hosted: HollowMoon `release.yml` (D6). Architecture `Deploy` is skipped (`deploy: false`).
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

- The pool's labels, BuildAgent, ActionTemplates beyond #54, and every `environment:` with its protection rules.
- Triggers, secrets and artifact retention in each workflow.
- No repository variable is set before its slice starts.
