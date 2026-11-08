#Requires -Version 7.2
# Host orchestration fixtures only; no target runners or GitHub repositories are changed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$functions = Join-Path $repo 'scripts\WindowsRunnerSetup.ps1'
. $functions
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
Assert ((Get-RunnerSetupScope 'https://github.com/AbsoluteZeroDev/') -eq 'orgs/AbsoluteZeroDev') 'Organization scope incorrect.'
Assert ((Get-RunnerSetupScope 'https://github.com/example/project') -eq 'repos/example/project') 'Repository scope incorrect.'
foreach ($url in 'http://github.com/example', 'https://other.example/example', 'https://github.com/example/project/more', 'https://github.com/example?token=x') {
    Assert-Throws { Get-RunnerSetupScope $url } 'Unsafe target accepted.'
}

# Verify authentication reuses a credential and never starts login/refresh in unattended mode.
$auth = @{ Calls = [Collections.Generic.List[string]]::new(); SignedIn = $true; CanRegister = $true; GrantedScopes = $null }
$oldGhToken = $env:GH_TOKEN
$oldGitHubToken = $env:GITHUB_TOKEN
try {
    Remove-Item Env:GH_TOKEN, Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    function gh {
        $auth.Calls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'auth' -and $args[1] -eq 'status' -and -not $auth.SignedIn) { $global:LASTEXITCODE = 1 }
        if ($args[0] -eq 'api' -and -not $auth.CanRegister) { $global:LASTEXITCODE = 1 }
        if ($args -contains '--include' -and $auth.GrantedScopes) { "X-OAuth-Scopes: $($auth.GrantedScopes)" }
    }
    Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $true -WithSmoke $false
    Assert (-not @($auth.Calls | Where-Object { $_ -match 'auth (login|refresh)' }).Count) 'Existing credential triggered sign-in.'
    Assert (@($auth.Calls | Where-Object { $_ -like '*registration-token --silent' }).Count -eq 1) 'Runner permissions were not checked without token output.'
    $auth.SignedIn = $false
    Assert-Throws { Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $true -WithSmoke $false } 'Unattended setup accepted missing auth.'
    $auth.Calls.Clear()
    Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $false -WithSmoke $true
    Assert (@($auth.Calls | Where-Object { $_ -like 'auth login*--web*admin:org,repo,workflow' }).Count -eq 1) 'Interactive setup did not request the required scopes.'
    $auth.SignedIn = $true; $auth.GrantedScopes = 'repo, admin:org'; $auth.Calls.Clear()
    Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $false -WithSmoke $true
    Assert (@($auth.Calls | Where-Object { $_ -like 'auth refresh*workflow' }).Count -eq 1) 'Missing stored workflow scope was not requested.'
    $auth.Calls.Clear()
    Assert-Throws { Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $true -WithSmoke $true } 'Unattended smoke accepted missing workflow scope.'
    Assert (-not @($auth.Calls | Where-Object { $_ -like 'auth refresh*' }).Count) 'Unattended smoke prompted for authorization.'
    $auth.GrantedScopes = 'repo, admin:org, workflow'
    Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $true -WithSmoke $true
    $auth.SignedIn = $false
    $env:GH_TOKEN = 'synthetic-test-value'
    $auth.Calls.Clear()
    Assert-Throws { Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $false -WithSmoke $true } 'Invalid environment credential triggered browser fallback.'
    Assert (-not @($auth.Calls | Where-Object { $_ -match 'auth (login|refresh)' }).Count) 'Environment credential triggered sign-in.'
} finally {
    $env:GH_TOKEN = $oldGhToken
    $env:GITHUB_TOKEN = $oldGitHubToken
    Remove-Item Function:gh
}

# Verify the real high-level flow and pair-only targeting on hosts with more than two instances.
. $functions
$flow = @{ Auth = 0; Clones = @(); Installs = @(); Verified = 0; Smoke = @() }
function Confirm-RunnerSetupAuthentication { param($Scope, $NonInteractive, $WithSmoke) $flow.Auth++ }
function Confirm-RunnerSetupRepositories { param($Scope, $Repositories) $flow.TargetRepositories = @($Repositories); $Repositories }
function Sync-RunnerSetupInstance { param($Clone, $InstanceId, $SourceCommit, $GitHubUrl) $flow.Clones += $Clone }
function Install-RunnerSetupInstance { param($Clone, $InstanceId, $GitHubUrl, $Labels) $flow.Installs += [pscustomobject]@{ Id = $InstanceId; Labels = $Labels } }
function Get-RunnerSetupEvidence {
    param($Clone, $InstanceId)
    [pscustomobject]@{ Instance = $InstanceId; Name = "custom-$InstanceId"; AgentId = [int]$InstanceId.Substring(3); Workspace = "$Clone\work"; SupervisorPid = 100 + [int]$InstanceId.Substring(3) }
}
function Confirm-RunnerSetupHost { param($Instances, $Scope) $flow.Verified = $Instances.Count }
function Invoke-RunnerSetupSmoke { param($Repository, $Label, $SourceClone, $ExpectedRunnerNames) $flow.Smoke += [pscustomobject]@{ Repo = $Repository; Label = $Label; Names = $ExpectedRunnerNames } }
$flow.BuildAgent = @(); $flow.BuildAgentExit = 0
function Install-RunnerSetupBuildAgent { param($Clone, $InstallRoot) $flow.BuildAgent += [pscustomobject]@{ Clone = $Clone; InstallRoot = $InstallRoot }; $flow.BuildAgentExit }
$options = @{ Count = 3; InstallRoot = 'C:\Fixtures'; GitHubUrl = 'https://github.com/AbsoluteZeroDev'; ExtraLabels = @('extra'); TargetRepositories = @('AbsoluteZeroDev/RunnerSmoke'); SourceCommit = ('a' * 40); SmokeRepository = 'AbsoluteZeroDev/RunnerSmoke'; NonInteractive = $true }
$outcome = Invoke-WindowsRunnerHostSetup @options | Select-Object -Last 1
Assert ($flow.Auth -eq 1 -and $flow.Verified -eq 3 -and $flow.Installs.Count -eq 3) 'Host setup skipped authentication, instances or verification.'
Assert ($flow.TargetRepositories[0] -eq 'AbsoluteZeroDev/RunnerSmoke' -and $outcome.ScopeValidatedRepositories[0] -eq 'AbsoluteZeroDev/RunnerSmoke') 'Intended repositories were not forwarded to preflight or reported separately.'
# BuildAgent is provisioned once per host, from the first instance's clone, after the runners are verified.
Assert ($flow.BuildAgent.Count -eq 1 -and $flow.BuildAgent[0].Clone -eq 'C:\Fixtures\win01' -and $flow.BuildAgent[0].InstallRoot -eq 'C:\Fixtures') 'BuildAgent was not provisioned once from win01.'
Assert ($outcome.BuildAgentExitCode -eq 0 -and -not $outcome.ActionRequired -and $outcome.Runners -eq 3) 'A ready BuildAgent was reported as not ready.'
Assert (($flow.Installs.Id -join ',') -eq 'win01,win02,win03') 'Instance IDs were not deterministic.'
$pair = "subzerodev-pair-$($env:COMPUTERNAME.ToLowerInvariant())"
Assert ($flow.Installs[0].Labels -contains $pair -and $flow.Installs[1].Labels -contains $pair -and $flow.Installs[2].Labels -notcontains $pair) 'Smoke targeting did not select only the first two instances.'
Assert (($flow.Smoke[0].Names -join ',') -eq 'custom-win01,custom-win02') 'Smoke ignored actual persisted identities.'
$flow.BuildAgent = @()
$skipped = Invoke-WindowsRunnerHostSetup @options -SkipBuildAgent $true | Select-Object -Last 1
Assert ($flow.BuildAgent.Count -eq 0 -and $skipped.BuildAgentExitCode -eq 0) '-SkipBuildAgent still provisioned BuildAgent.'
# Exit 2 (the person has to act) is reported, the runners and the smoke test are not blocked, and nothing is thrown.
$flow.BuildAgentExit = 2; $flow.Smoke = @()
$paused = Invoke-WindowsRunnerHostSetup @options | Select-Object -Last 1
Assert ($paused.ActionRequired -and $paused.BuildAgentExitCode -eq 2 -and $flow.Smoke.Count -eq 1) 'Action-required BuildAgent blocked the runners or was not reported.'
# A failed optional integration is a non-zero outcome, not an exception, and the runners stay set up.
$flow.BuildAgentExit = 1
$broken = Invoke-WindowsRunnerHostSetup @options 3>$null | Select-Object -Last 1
Assert ($broken.BuildAgentExitCode -eq 1 -and -not $broken.ActionRequired -and $broken.Runners -eq 3) 'A failed BuildAgent step was hidden or blocked the runners.'
$flow.BuildAgentExit = 0; $flow.Smoke = @()
$options.SmokeRepository = 'DifferentOrg/Smoke'
Assert-Throws { Invoke-WindowsRunnerHostSetup @options } 'Cross-target smoke repository accepted.'
$options.SmokeRepository = ''
$options.Count = 1
Invoke-WindowsRunnerHostSetup @options
Assert ($flow.Smoke.Count -eq 0) 'Setup dispatched a smoke test without a requested repository.'

# A failing per-instance install (for example an earlier version's startup entry that cannot be removed or verified gone, or a
# supervisor that did not initialize) stops host setup at that instance: later instances, verification, BuildAgent and the smoke
# test never run, no success is reported, and the worker process exits non-zero. The real Install-RunnerSetupInstance runs a
# throwaway installer that throws the real migration failure text; everything that would reach GitHub or the host is a recorder.
. $functions
$failure = Join-Path ([IO.Path]::GetTempPath()) ('host-setup-fail-' + [guid]::NewGuid().ToString('N'))
try {
    $migrationFailure = "An earlier version's startup entry for instance win01 could not be removed or verified gone, so the install stopped before any registration change; nothing was started or stopped and no migration is recorded:`n - \SubZeroDev.Runners\Start Windows runner (win01): access denied`nRemove the task in Task Scheduler (taskschd.msc), or repair the Task Scheduler service, then rerun Install-WindowsRunner.ps1 (or scripts\Remove-LegacyTasks.ps1)."
    foreach ($id in 'win01', 'win02') {
        $scriptsDir = Join-Path $failure "root\$id\scripts"
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
        $body = if ($id -eq 'win01') { "throw @'`n$migrationFailure`n'@" } else { "Add-Content -LiteralPath '$failure\calls.txt' 'installer-win02'" }
        Set-Content -LiteralPath (Join-Path $scriptsDir 'Install-WindowsRunner.ps1') "param([string] `$InstanceId, [string] `$GitHubUrl, [string[]] `$ExtraLabels)`n$body"
    }
    $calls = Join-Path $failure 'calls.txt'
    # In-process: the throw reaches the caller of Invoke-WindowsRunnerHostSetup.
    $recorded = [Collections.Generic.List[string]]::new()
    # Installed with Set-Item (not function statements) so each function is still defined once in this file.
    Set-Item -Path Function:Confirm-RunnerSetupAuthentication -Value { param($Scope, $NonInteractive, $WithSmoke) }
    Set-Item -Path Function:Sync-RunnerSetupInstance -Value { param($Clone, $InstanceId, $SourceCommit, $GitHubUrl) }
    Set-Item -Path Function:Get-RunnerSetupEvidence -Value { param($Clone, $InstanceId) $recorded.Add("evidence:$InstanceId"); [pscustomobject]@{ Name = 'n' } }
    Set-Item -Path Function:Confirm-RunnerSetupHost -Value { param($Instances, $Scope) $recorded.Add('verified') }
    Set-Item -Path Function:Install-RunnerSetupBuildAgent -Value { param($Clone, $InstallRoot) $recorded.Add('buildagent'); 0 }
    Set-Item -Path Function:Invoke-RunnerSetupSmoke -Value { param($Repository, $Label, $SourceClone, $ExpectedRunnerNames) $recorded.Add('smoke') }
    $failOptions = @{ Count = 2; InstallRoot = (Join-Path $failure 'root'); GitHubUrl = 'https://github.com/AbsoluteZeroDev'; ExtraLabels = @(); SourceCommit = ('a' * 40); SmokeRepository = 'AbsoluteZeroDev/RunnerSmoke'; NonInteractive = $true }
    $thrown = $null; $output = $null
    try { $output = Invoke-WindowsRunnerHostSetup @failOptions *>&1 | Out-String } catch { $thrown = $_.Exception.Message }
    Assert ($thrown -match 'could not be removed or verified gone') "A failing installer did not fail host setup: $thrown"
    Assert ($thrown -match 'taskschd\.msc') 'The actionable fix was lost on the way out of host setup.'
    Assert ($recorded.Count -eq 0) "Host setup continued after a failed install: $($recorded -join ', ')"
    Assert (-not (Test-Path -LiteralPath $calls)) 'Host setup went on to install the next instance after a failure.'
    Assert ("$output" -notmatch 'Setup complete') 'Host setup reported completion after a failed install.'

    # Real worker process: nothing but the host and GitHub operations is replaced; the process must exit non-zero with the text.
    $workerDir = Join-Path $failure 'worker\scripts'
    New-Item -ItemType Directory -Path $workerDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'scripts\Configure-WindowsRunners.ps1') -Destination $workerDir
    @(
        ". '$functions'"
        'function Confirm-RunnerSetupAuthentication { param($Scope, $NonInteractive, $WithSmoke) }'
        'function Sync-RunnerSetupInstance { param($Clone, $InstanceId, $SourceCommit, $GitHubUrl) }'
        "function Get-RunnerSetupEvidence { param(`$Clone, `$InstanceId) Add-Content -LiteralPath '$calls' 'evidence'; [pscustomobject]@{ Name = 'n' } }"
        "function Confirm-RunnerSetupHost { param(`$Instances, `$Scope) Add-Content -LiteralPath '$calls' 'verified' }"
        "function Install-RunnerSetupBuildAgent { param(`$Clone, `$InstallRoot) Add-Content -LiteralPath '$calls' 'buildagent'; 0 }"
        "function Invoke-RunnerSetupSmoke { param(`$Repository, `$Label, `$SourceClone, `$ExpectedRunnerNames) Add-Content -LiteralPath '$calls' 'smoke' }"
    ) | Set-Content -LiteralPath (Join-Path $workerDir 'WindowsRunnerSetup.ps1')
    $optionsFile = Join-Path $failure 'options.json'
    $failOptions | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $optionsFile
    $workerOutput = & ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workerDir 'Configure-WindowsRunners.ps1') -OptionsPath $optionsFile 2>&1 | Out-String
    $workerExit = $LASTEXITCODE
    Assert ($workerExit -ne 0) "The worker exited $workerExit after a failed install. Output:`n$workerOutput"
    Assert ($workerOutput -match 'could not be removed or verified gone' -and $workerOutput -match 'taskschd\.msc') "The worker lost the failure text:`n$workerOutput"
    Assert ($workerOutput -notmatch 'Setup complete') 'The worker reported completion after a failed install.'
    $workerCalls = if (Test-Path -LiteralPath $calls) { Get-Content -Raw -LiteralPath $calls }
    Assert (-not $workerCalls) "The worker went on after the failure: $workerCalls"
    foreach ($name in 'Confirm-RunnerSetupAuthentication', 'Sync-RunnerSetupInstance', 'Get-RunnerSetupEvidence', 'Confirm-RunnerSetupHost', 'Install-RunnerSetupBuildAgent', 'Invoke-RunnerSetupSmoke') { Remove-Item "Function:$name" -ErrorAction SilentlyContinue }
} finally {
    Remove-Item -LiteralPath $failure -Recurse -Force -ErrorAction SilentlyContinue
}

# Verify online state, remote/local ID equality, isolation and adding labels to existing registrations.
. $functions
$evidence = @(
    [pscustomobject]@{ Instance = 'win01'; Name = 'one'; AgentId = 11; Workspace = 'C:\one'; SupervisorPid = 101; Labels = @('shared', 'host') },
    [pscustomobject]@{ Instance = 'win02'; Name = 'two'; AgentId = 22; Workspace = 'C:\two'; SupervisorPid = 202; Labels = @('shared', 'host') }
)
$remoteFixture = @{ Offline = $false; WrongId = $false; Added = 0 }
function Invoke-RunnerSetupGh {
    param($Arguments)
    if ($Arguments[1] -like '*/labels') { return [pscustomobject]@{ labels = @(@{ name = 'shared' }, @{ name = 'host' }) } }
    @([pscustomobject]@{ runners = @(
        @{ name = 'one'; id = $(if ($remoteFixture.WrongId) { 99 } else { 11 }); status = $(if ($remoteFixture.Offline) { 'offline' } else { 'online' }); labels = @(@{ name = 'shared' }) },
        @{ name = 'two'; id = 22; status = 'online'; labels = @(@{ name = 'shared' }) }
    ) })
}
Set-Item Function:gh -Value { $null = $input | Out-String; $remoteFixture.Added++; $global:LASTEXITCODE = 0 }
Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example
Assert ($remoteFixture.Added -eq 2) 'Existing runners did not receive their missing targeting labels.'
$remoteFixture.Offline = $true
Assert-Throws { Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example } 'Offline runner accepted.'
$remoteFixture.Offline = $false; $remoteFixture.WrongId = $true
Assert-Throws { Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example } 'Mismatched registration ID accepted.'
$remoteFixture.WrongId = $false; $evidence[1].Workspace = 'C:\one'
Assert-Throws { Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example } 'Shared workspace accepted.'
Remove-Item Function:gh

# Existing clone updates must protect identity, scope, local files and commits.
. $functions
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('host-setup-' + [guid]::NewGuid().ToString('N'))
$cloneFixture = @{ Origin = 'https://github.com/The-Running-Dev/SubZeroDev.Runners.git'; Dirty = $false; Diverged = $false; Checkouts = 0 }
try {
    $clone = Join-Path $fixture 'win01'
    New-Item -ItemType Directory -Path (Join-Path $clone '.git') -Force | Out-Null
    $settingsPath = Join-Path $clone 'runners.local.json'
    '{"windows":{"instanceId":"win01"},"github":{"url":"https://github.com/AbsoluteZeroDev"}}' | Set-Content $settingsPath
    Set-Item Function:Invoke-RunnerSetupGit -Value {
        param($Arguments, [switch] $Capture)
        if ($Arguments -contains 'get-url') { return $cloneFixture.Origin }
        if ($Arguments -contains '--porcelain' -and $cloneFixture.Dirty) { return ' M important.ps1' }
        if ($Arguments -contains 'checkout') { $cloneFixture.Checkouts++ }
    }
    Set-Item Function:git -Value { $global:LASTEXITCODE = $(if ($cloneFixture.Diverged) { 1 } else { 0 }) }
    $syncOptions = @{ Clone = $clone; InstanceId = 'win01'; SourceCommit = ('a' * 40); GitHubUrl = 'https://github.com/AbsoluteZeroDev' }
    Sync-RunnerSetupInstance @syncOptions
    Assert ($cloneFixture.Checkouts -eq 1) 'Clean clone was not advanced.'
    $cloneFixture.Dirty = $true
    Assert-Throws { Sync-RunnerSetupInstance @syncOptions } 'Dirty clone was overwritten.'
    $cloneFixture.Dirty = $false; $cloneFixture.Diverged = $true
    Assert-Throws { Sync-RunnerSetupInstance @syncOptions } 'Divergent commits were discarded.'
    $cloneFixture.Diverged = $false
    $before = Get-Content -Raw $settingsPath
    $syncOptions.InstanceId = 'win02'
    Assert-Throws { Sync-RunnerSetupInstance @syncOptions } 'Clone instance identity was reused.'
    $syncOptions.InstanceId = 'win01'; $syncOptions.GitHubUrl = 'https://github.com/elsewhere'
    Assert-Throws { Sync-RunnerSetupInstance @syncOptions } 'Saved GitHub target was silently replaced.'
    Assert ((Get-Content -Raw $settingsPath) -eq $before -and $cloneFixture.Checkouts -eq 1) 'Rejected update changed settings or checked out code.'
    Remove-Item Function:git

    # Exercise the real optional smoke orchestration with synthetic GitHub responses and checker evidence.
    . $functions
    New-Item -ItemType Directory -Path (Join-Path $clone 'tests') -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'windows-runner-smoke.yml') (Join-Path $clone 'tests')
    Copy-Item (Join-Path $PSScriptRoot 'Assert-WindowsRunnerSmoke.ps1') (Join-Path $clone 'tests')
    $smokeFixture = @{ Mismatch = $false; Dispatch = $null; Writes = 0; Jobs = @(
        @{ runner_name = 'custom-one'; runner_id = 11; conclusion = 'success'; steps = @(@{ name = 'Hold slot for overlap check'; started_at = '2026-11-05T10:00:00Z'; completed_at = '2026-11-05T10:01:30Z' }) },
        @{ runner_name = 'custom-two'; runner_id = 22; conclusion = 'success'; steps = @(@{ name = 'Hold slot for overlap check'; started_at = '2026-11-05T10:00:10Z'; completed_at = '2026-11-05T10:01:40Z' }) }
    ) }
    $smokeFixture.Content = Get-Content -Raw (Join-Path $PSScriptRoot 'windows-runner-smoke.yml')
    Set-Item Function:gh -Value {
        $global:LASTEXITCODE = 0
        if ($args[1] -eq 'repos/example/smoke') { return '{"private":true,"default_branch":"main"}' }
        if ($args[1] -like '*/contents/*') {
            $text = if ($smokeFixture.Mismatch) { 'an existing different workflow' } else { $smokeFixture.Content }
            return (@{ content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) } | ConvertTo-Json)
        }
        if ($args[1] -like '*/jobs?*') { return (@{ total_count = 2; jobs = $smokeFixture.Jobs } | ConvertTo-Json -Depth 10) }
    }
    Set-Item Function:Send-RunnerSetupGh -Value {
        param($Arguments, $Body)
        $smokeFixture.Writes++
        $smokeFixture.Dispatch = $Body
    }
    Set-Item Function:Invoke-RunnerSetupGh -Value {
        param($Arguments)
        @{ workflow_runs = @(@{ id = 81; display_title = "Windows runner smoke $($smokeFixture.Dispatch.inputs.setup_id)"; status = 'completed'; conclusion = 'success'; html_url = 'https://github.com/example/smoke/actions/runs/81' }) }
    }
    Invoke-RunnerSetupSmoke -Repository example/smoke -Label pair-label -SourceClone $clone -ExpectedRunnerNames @('custom-one', 'custom-two')
    Assert ($smokeFixture.Writes -eq 1 -and $smokeFixture.Dispatch.inputs.runner_label -eq 'pair-label') 'Smoke workflow was overwritten or dispatch targeted the wrong pair.'
    Assert ($smokeFixture.Dispatch.inputs.runner_names -eq '["custom-one","custom-two"]') 'Dispatch lost actual expected names.'
    $smokeFixture.Mismatch = $true
    Assert-Throws { Invoke-RunnerSetupSmoke -Repository example/smoke -Label pair-label -SourceClone $clone -ExpectedRunnerNames @('custom-one', 'custom-two') } 'Existing differing smoke workflow was overwritten.'
    Assert ($smokeFixture.Writes -eq 1) 'Rejected smoke workflow caused a GitHub write.'
    Remove-Item Function:gh
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: authentication, deterministic host orchestration, target/smoke boundaries, pair labels, registration identity/online checks and isolation (external operations mocked).'
Write-Output 'PASS: a failed per-instance install (legacy startup entry not removable, supervisor not initialized) stops host setup and the worker process exits non-zero with the fix, before verification, BuildAgent, smoke or any success output.'
Write-Output 'PASS: dirty/divergent/mismatched clone rejection and automatic smoke dispatch/correlation/evidence checking without overwriting existing workflows (GitHub operations mocked).'
