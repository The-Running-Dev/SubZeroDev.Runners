# Two native Windows runners on one host

## Automatic setup (recommended)

Open a **normal, non-elevated Windows PowerShell** window on a new x64 Windows desktop or VM:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1')))
```

No manual Git clone, prerequisite installation, terminal restart or registration token copying is needed.
The entry point supports Windows PowerShell 5.1. It uses Microsoft's `Microsoft.WinGet.Client` repair
route if WinGet is missing/broken, then silently installs missing PowerShell 7.2+, Git and GitHub CLI.
Windows may request package-installation elevation or an elevated WinGet repair; the GitHub setup,
runner registration and job processes continue under the original unelevated user. A new GitHub login
still requires your browser/device approval. Windows Server/Core, LocalSystem and an elevated runner
account are not supported by this interactive-user setup.
The bootstrap permits scripts/modules for its current PowerShell process only; it does not change
the machine's or user's persistent execution policy, and enforced organization policy still applies.

Defaults: two instances (`win01`, `win02`) in `%LOCALAPPDATA%\SubZeroDev\Runners`, registered to
`AbsoluteZeroDev`, with sign-in tasks. The `_setup` directory is a reserved controller checkout;
each instance has its own clone. All clones use one resolved source commit for that run. Package
installs requiring a reboot stop setup and ask you to rerun after the reboot; setup never reboots for you.
Use a unique Windows computer name per host; setup refuses existing runner-name conflicts rather than
taking another machine's registration.

```powershell
# Existing C:\Actions layout / 128 GB host:
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1'))) -InstallRoot C:\Actions -ExtraLabels subzerodev-windows-large -SmokeRepository AbsoluteZeroDev/RunnerSmoke

# Another machine: four instances, automatic registration/startup checks:
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/The-Running-Dev/SubZeroDev.Runners/main/Setup-WindowsRunners.ps1'))) -Count 4
```

Rerunning skips working prerequisites, retains saved names/workspaces/custom labels, keeps the original
instance spelling, and only advances clean runner clones. Dirty checkouts, local commits that would be
discarded, another clone/instance identity, and a different saved GitHub target stop setup. For a custom
target, repeat the same `-GitHubUrl` on reruns. Lowering `-Count` never uninstalls additional instances.
No `--replace`, `git reset`, `git clean`, auto-logon or host reboot is performed.

Every instance also gets a `subzerodev-host-<computer>` label. Only the first two receive
`subzerodev-pair-<computer>` for the concurrent-job test; this works even on a host with more than two
runners. The `subzerodev-windows-large` label is opt-in so ordinary VMs do not receive large-host jobs.

Add `-SmokeRepository AbsoluteZeroDev/RunnerSmoke` to automate the actual GitHub job smoke test.
Setup creates the named repository private if missing and installs the manual-only smoke workflow if
absent, then dispatches and checks two distinct expected identities plus overlapping execution. An
existing repository must be private, within the target organization (or be the exact repository-scoped
runner target), and permitted by the runner group. Setup does not widen runner-group access or overwrite
a differing workflow. OAuth credentials need `repo,workflow` access for workflow creation as well as
runner administration; initial interactive login requests these scopes when smoke is selected. Queued
or unfinished smoke runs time out after eight minutes and are cancelled when their ID is known.

For unattended provisioning, supply `GH_TOKEN` through the VM provisioner's environment or provision
a GitHub CLI login in that user profile, then pass `-NonInteractive`. Setup never saves that token to
its options file, prints it, or embeds it in command arguments. Existing supervisor code strips
`GH_TOKEN` and `GITHUB_TOKEN` from job environments. OS elevation/reboot requirements still apply;
preinstall machine-wide prerequisites if a provisioner cannot handle UAC.

If using a local checkout, run `.\Setup-WindowsRunners.ps1` with the same options. `-SourceRef` accepts
a repository branch/tag/commit (default `main`); it must contain the setup worker. Automated CI exercises
stock Windows PowerShell parsing and mocked package/authentication/host flows. It does not install
WinGet on a clean VM or prove registration/startup on the target machine. The script's host checks and,
if selected, the actual smoke run provide that evidence when you execute it there.

Microsoft's repair reference: <https://learn.microsoft.com/en-us/windows/package-manager/winget/troubleshooting>.
GitHub CLI environment authentication: <https://cli.github.com/manual/gh_help_environment>.

## Manual setup and inspection

These commands configure two independent clones on the 128 GB Windows machine. Run the installer as the normal Windows user whose account will execute jobs. Startup is at that user's sign-in, not at boot. Both jobs share the host's CPU, memory, installed tools and ports; there are no per-runner resource limits.

## Prerequisites

Windows x64, internet access to GitHub and .NET downloads, Git, GitHub CLI and PowerShell 7.2 or later. The installer expects PowerShell at `C:\Program Files\PowerShell\7\pwsh.exe` and installs a private .NET 10 SDK for each runner. Docker is not required.

From a Windows terminal, install missing prerequisites (approve package installer elevation if prompted):

```powershell
$ErrorActionPreference = 'Stop'
foreach ($package in 'Microsoft.PowerShell', 'Git.Git', 'GitHub.cli') {
    winget list --id $package --exact --accept-source-agreements *> $null
    if ($LASTEXITCODE -eq 0) { continue }
    winget install --id $package --exact --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE) { throw "Installing $package failed; inspect winget output." }
}
```

Close the terminal and open a **non-elevated PowerShell 7** window. Sign in with a GitHub account permitted to administer runners in `AbsoluteZeroDev`:

```powershell
gh auth login --hostname github.com --web --scopes admin:org
if ($LASTEXITCODE) { throw 'GitHub sign-in failed.' }
gh auth status --hostname github.com
# For an existing login missing the scope:
# gh auth refresh --hostname github.com --scopes admin:org
```

The default target is `https://github.com/AbsoluteZeroDev`. The organization runner group must allow the repositories that will use the runners. Organization runners do not serve repositories owned by the personal `The-Running-Dev` account. Use `-GitHubUrl https://github.com/OWNER/REPO` for repository-scoped registration instead, with appropriate repository administration access.

## Install two instances

After PR #5 is merged, run:

```powershell
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path C:\Actions -Force | Out-Null
foreach ($id in 'win01', 'win02') {
    $clone = Join-Path 'C:\Actions' $id
    if (-not (Test-Path -LiteralPath $clone)) {
        git clone --branch main https://github.com/The-Running-Dev/SubZeroDev.Runners.git $clone
        if ($LASTEXITCODE) { throw "Cloning $id failed." }
    } else {
        $origin = git -C $clone remote get-url origin
        if ($LASTEXITCODE -or $origin -ne 'https://github.com/The-Running-Dev/SubZeroDev.Runners.git') { throw "Unexpected clone at $clone." }
        $branch = git -C $clone branch --show-current
        if ($LASTEXITCODE -or $branch -ne 'main') { throw "$clone must be on main." }
        $dirty = git -C $clone status --porcelain
        if ($LASTEXITCODE -or $dirty) { throw "$clone has tracked or untracked changes; inspect before updating." }
        git -C $clone pull --ff-only origin main
        if ($LASTEXITCODE) { throw "Updating $id failed." }
    }
    & "$clone\tests\Test-WindowsRunnerInstances.ps1"
    & "$clone\scripts\Install-WindowsRunner.ps1" -InstanceId $id -ExtraLabels subzerodev-windows-large
}
```

The installer obtains short-lived GitHub registration tokens through `gh`; no token needs to be pasted. Do not use `-Replace` for these fresh installs. A name already registered elsewhere must be investigated, rather than taken over automatically. Do not copy configured runner directories or reuse one clone for a different instance ID.

Expected identities (`<computer>` is lowercase `COMPUTERNAME`):

| Item | win01 | win02 |
| --- | --- | --- |
| Clone | `C:\Actions\win01` | `C:\Actions\win02` |
| Runner name | `subzerodev.runner.windows.<computer>.win01` | `subzerodev.runner.windows.<computer>.win02` |
| Default workspace | `%TEMP%\szr\win01` | `%TEMP%\szr\win02` |
| Mutex | `Local\SubZeroDev.Runners.Windows.win01` | `Local\SubZeroDev.Runners.Windows.win02` |
| Sign-in task | `Start Windows runner (win01)` | `Start Windows runner (win02)` |
| Daily task | `Trim logs (win01)` | `Trim logs (win02)` |

Tasks live under `\SubZeroDev.Runners\`. Both retain `subzerodev-windows` and add `subzerodev-windows-large`. Each clone has separate binaries, registration, SDK, NuGet cache, logs and PID file. Reruns retain saved identity, scope and labels when those arguments are omitted. Existing unnamed installations keep their original mutex and task names.

## Verify registration and scheduled tasks on the host

```powershell
$ErrorActionPreference = 'Stop'
$local = @(foreach ($id in 'win01', 'win02') {
    $clone = Join-Path 'C:\Actions' $id
    $config = Get-Content -Raw "$clone\runners.local.json" | ConvertFrom-Json
    $registration = Get-Content -Raw "$clone\windows\.runner" | ConvertFrom-Json
    $task = Get-ScheduledTask -TaskPath '\SubZeroDev.Runners\' -TaskName "Start Windows runner ($id)"
    $trim = Get-ScheduledTask -TaskPath '\SubZeroDev.Runners\' -TaskName "Trim logs ($id)"
    $supervisor = Join-Path $clone 'scripts\Run-WindowsRunner.ps1'
    if ($task.Actions.Arguments -notlike "*$supervisor*" -or $task.Actions.WorkingDirectory -ne "$clone\windows") { throw "Wrong startup action for $id." }
    if ($task.Principal.LogonType -ne 'Interactive' -or $task.Principal.RunLevel -ne 'Limited') { throw "Wrong task principal for $id." }
    if ($task.Settings.MultipleInstances -ne 'IgnoreNew' -or $task.Settings.ExecutionTimeLimit -ne 'PT0S') { throw "Wrong task lifetime settings for $id." }
    $supervisorPid = [int](Get-Content "$clone\windows\supervisor.pid")
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$supervisorPid"
    if (-not $process -or $process.CommandLine -notlike "*$supervisor*") { throw "Supervisor not running for $id." }
    if ($config.windows.instanceId -ne $id -or $registration.agentName -ne $config.windows.name) { throw "Wrong registration for $id." }
    Get-ScheduledTaskInfo -TaskPath $task.TaskPath -TaskName $task.TaskName | Format-List LastRunTime, LastTaskResult
    [pscustomobject]@{ Instance = $id; Name = $registration.agentName; AgentId = $registration.agentId; Workspace = [Environment]::ExpandEnvironmentVariables($config.windows.workFolder); SupervisorPid = $supervisorPid; StartTask = $task.State; TrimTask = $trim.State }
})
$local | Format-Table -AutoSize
foreach ($field in 'Name', 'AgentId', 'Workspace', 'SupervisorPid') {
    if (@($local.$field | Select-Object -Unique).Count -ne 2) { throw "Instances share $field." }
}
$json = gh api orgs/AbsoluteZeroDev/actions/runners --paginate --slurp
if ($LASTEXITCODE) { throw 'Cannot read organization runner registrations.' }
$remote = @((($json | ConvertFrom-Json).runners) | Where-Object { $_.name -in $local.Name })
if ($remote.Count -ne 2) { throw 'Expected both organization registrations.' }
foreach ($runner in $remote) {
    $here = $local | Where-Object Name -eq $runner.name
    if ($runner.id -ne $here.AgentId -or $runner.status -ne 'online') { throw "Runner registration mismatch or offline: $($runner.name)" }
    foreach ($label in 'subzerodev-windows', 'subzerodev-windows-large') {
        if ($label -notin $runner.labels.name) { throw "Missing $label on $($runner.name)." }
    }
}
$remote | Select-Object id, name, status, busy | Format-Table
```

A running supervisor task normally reports `Running`; its `LastTaskResult` may be `267009` (`0x41301`, still running). Check the process and GitHub status, rather than treating that value as failure. Sign out and back in, then repeat the checks to verify the real sign-in trigger. The CI harness constructs task definitions but mocks registration/start; it does not prove task installation on this machine.

## Safe concurrent-job smoke test

Use a private, trusted repository **inside AbsoluteZeroDev** which its runner group permits. Copy `tests\windows-runner-smoke.yml` into that repository as `.github\workflows\windows-runner-smoke.yml`, review it, then commit and push it to the default branch. It is manual-only, requests no token permissions, checks out no repository code, uses no secrets or fixed ports, and only logs runner identity/timestamps and sleeps for 90 seconds. Reserve `subzerodev-windows-large` for these two runners during the test.

For example, from a clean local checkout of that existing organization repository:

```powershell
$ErrorActionPreference = 'Stop'
$smokeRepo = gh repo view --json nameWithOwner --jq .nameWithOwner
if ($LASTEXITCODE -or $smokeRepo -notlike 'AbsoluteZeroDev/*') { throw 'Use an authorized AbsoluteZeroDev repository.' }
$branch = gh repo view --json defaultBranchRef --jq .defaultBranchRef.name
if ($LASTEXITCODE) { throw 'Cannot read the default branch.' }
$current = git branch --show-current
if ($LASTEXITCODE -or $current -ne $branch) { throw 'Check out the smoke repository default branch first.' }
if (git status --porcelain) { throw 'Use a clean smoke repository checkout.' }
New-Item -ItemType Directory -Path .github\workflows -Force | Out-Null
$destination = '.github\workflows\windows-runner-smoke.yml'
if (Test-Path $destination) { throw 'Smoke workflow already exists; inspect it before replacing.' }
Copy-Item C:\Actions\win01\tests\windows-runner-smoke.yml $destination
git add -- $destination
git commit -m 'Add manual Windows runner concurrency smoke test'
if ($LASTEXITCODE) { throw 'Commit failed.' }
git push
if ($LASTEXITCODE) { throw 'Push failed.' }
gh workflow run windows-runner-smoke.yml --repo $smokeRepo --ref $branch -f "computer_name=$env:COMPUTERNAME"
if ($LASTEXITCODE) { throw 'Dispatch failed.' }
gh run list --repo $smokeRepo --workflow windows-runner-smoke.yml --event workflow_dispatch --limit 5
$runId = Read-Host 'Paste the run ID of this dispatch from the list above'
gh run watch $runId --repo $smokeRepo --exit-status
if ($LASTEXITCODE) { throw 'Smoke workflow failed; inspect its logs.' }
& C:\Actions\win01\tests\Assert-WindowsRunnerSmoke.ps1 -Repository $smokeRepo -RunId $runId
gh run view $runId --repo $smokeRepo --log
```

The evidence checker requires successful jobs on both expected names, distinct GitHub runner IDs, and overlapping hold-step intervals. Two successful sequential jobs fail this check. A queued job usually means a missing label, unavailable runner, runner-group repository access, or another job occupying a slot; do not conclude concurrency passed from the dispatch alone. Cancel a stuck run with `gh run cancel $runId --repo $smokeRepo`.

Only results collected from the target host and this actual workflow run establish that the two runners are online and execute jobs concurrently.
