# Documentation index

Start with the [repository README](../README.md): what the runners are, setup, settings and every script. This folder
holds the guides behind it. Guides describe how things work now; plans, audits and handoffs record why and in what order.

## Guides (how it works now)

| Document | Read it to |
| --- | --- |
| [Host management](host-management.md) | Run the host manager (`Manage-RunnerHost.ps1`): inventory, Plan/Status, Hold and Resume, start at sign-in, Linux slots as compose services |
| [Windows runners](windows-two-runners.md) | Set up, verify and operate native Windows runner instances; registration scope; BuildAgent acceptance |
| [Linux runtime isolation](linux-runtime-isolation.md) | Understand what job code in the Linux container can and cannot reach (registration and credential files) |
| [Linux updater](build-agent-2.2.0-updater.md) | Replace the Linux container with BuildAgent 2.2.0's guarded updater, and recover from a failed update |
| [Linux docs smoke](linux-docs-smoke.md) | Prove the Linux runner builds a real documentation site end to end |
| [Testing](testing.md) | Run the test suites locally and know what CI runs |
| [Troubleshooting](troubleshooting.md) | Match a symptom to its cause and fix |

## Design, plans and records

| Document | What it is |
| --- | --- |
| [Runner pool plan](runner-pool-plan.md) | The design for N Linux and N Windows slots per host, with owner decisions D1-D4 and resolutions C1-C4 |
| [Automatic acceptance safeguards audit](automatic-acceptance-safeguards-audit.md) | What the automated acceptance run protects against, and the assertions that prove it |
| [`../design/`](../design/10-design.md) | The shape every slice builds against: brief, design, contract, slice list, decisions |
| [`../handoffs/`](../handoffs/runner-pool.md) | Slice-by-slice build notes and test requirements |
| [`../AGENTS.md`](../AGENTS.md) | The working contract for agents and contributors |

## Where to look

| I want to | Go to |
| --- | --- |
| Install runners on a new machine | [README: One-command Windows setup](../README.md#one-command-windows-setup) |
| Use a runner from a workflow | [README: Using the runners from a repository](../README.md#using-the-runners-from-a-repository) |
| Stop, restart or hold a runner without losing a job | [README: Draining and its limits](../README.md#draining-and-its-limits), [Host management](host-management.md#hold-and-resume) |
| See why a runner is offline | [Troubleshooting](troubleshooting.md) |
| Change a setting | [README: settings](../README.md#settings) |
| Upgrade the Linux image or BuildAgent | [Linux updater](build-agent-2.2.0-updater.md) |
