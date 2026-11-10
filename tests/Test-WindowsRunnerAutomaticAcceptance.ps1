#Requires -Version 7.2
# Synthetic host/GitHub operations only. The real checkpoint controller is exercised; no runner is installed or stopped.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$setup = Join-Path $repo 'scripts\WindowsRunnerSetup.ps1'
. $setup
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('automatic-acceptance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    # The actual child-process bridge preserves arrays, Boolean switches, quotes and spaced paths.
    $bridge = Join-Path $root "child's script.ps1"
    $saved = Join-Path $root 'arguments.json'
    'param([string[]] $Clones, [switch] $AllowDisruptive, [string] $Output) @{ Clones = $Clones; Disruptive = [bool]$AllowDisruptive } | ConvertTo-Json | Set-Content -LiteralPath $Output' | Set-Content -LiteralPath $bridge
    Invoke-RunnerAcceptanceProcess $bridge @{ Clones = @("C:\a folder\Ben's runner", 'C:\other'); AllowDisruptive = $true; Output = $saved }
    $argsSaved = Get-Content -Raw -LiteralPath $saved | ConvertFrom-Json
    Assert ($argsSaved.Clones.Count -eq 2 -and $argsSaved.Clones[0] -ceq "C:\a folder\Ben's runner" -and $argsSaved.Disruptive) 'Child bridge corrupted structured options.'
    'throw "synthetic child failure"' | Set-Content -LiteralPath $bridge
    # GitHub dot-sources this suite and exits with LASTEXITCODE afterwards. An expected native failure must not poison
    # that outer status after its exception has been asserted; unexpected child failures still escape and fail the suite.
    $exitBeforeExpectedFailure = $global:LASTEXITCODE
    try { Assert-Throws { Invoke-RunnerAcceptanceProcess $bridge @{} } 'Child process failure was swallowed.' }
    finally { $global:LASTEXITCODE = $exitBeforeExpectedFailure }

    $clones = @('win01', 'win02' | ForEach-Object { Join-Path $root $_ })
    foreach ($clone in $clones) {
        New-Item -ItemType Directory -Path $clone -Force | Out-Null
        '{"pins":"one"}' | Set-Content -LiteralPath (Join-Path $clone 'runners.json')
        '{"labels":["one"]}' | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    }
    $instances = @(
        [pscustomobject]@{ Instance = 'win01'; Name = 'runner-one'; AgentId = 11 },
        [pscustomobject]@{ Instance = 'win02'; Name = 'runner-two'; AgentId = 22 }
    )
    $f = @{ Calls = [Collections.Generic.List[string]]::new(); Fail = ''; Held = $false; Cancelled = 0 }
    function Invoke-RunnerAcceptanceProcess {
        param($Script, $Parameters)
        $stage = if ($Parameters.Stage) { $Parameters.Stage -join ',' } else { 'Builds' }
        $f.Calls.Add($stage)
        if ($f.Fail -eq $stage) { throw "Failure at $stage" }
    }
    function Sync-RunnerAcceptanceFixture { param($Directory) $f.Calls.Add('fixture'); Join-Path $Directory 'tests\fixtures\docusaurus' }
    function Install-RunnerAcceptanceWorkflow { param($Repository, $SourceClone) $f.Calls.Add('workflow') }
    function Invoke-RunnerAcceptanceLifecycle {
        param($InstallRoot, $Repository, $SourceClone, $Clones, $Instances, $State, $Mode, $WorkflowBranch)
        $f.Calls.Add($Mode)
        if ($f.Fail -eq $Mode) { throw "Failure at $Mode" }
    }
    $options = @{ Count = 2; InstallRoot = $root; GitHubUrl = 'https://github.com/example/private'; SourceCommit = ('a' * 40); NonInteractive = $true }
    Invoke-RunnerSetupAcceptance $root example/private $instances $options
    $first = $f.Calls -join '|'
    Assert ($first -eq 'Readiness|fixture|Build,Adoption,Rerun|Builds|workflow|Drain|workflow|Timeout|workflow|Force') "Stages not orchestrated automatically: $first"
    $state = Get-RunnerAcceptanceState $root
    Assert ($state.completed.Count -eq 5 -and -not $state.activeRun) 'Not all successful stages were checkpointed.'
    $f.Calls.Clear()
    Invoke-RunnerSetupAcceptance $root example/private $instances $options
    Assert (($f.Calls -join '|') -eq 'Readiness|fixture') 'Unchanged resume repeated completed disruptive stages or skipped live readiness.'
    # A changed registration, configuration or source invalidates historical checkpoints.
    foreach ($change in 'registration', 'config', 'source', 'scope', 'instance-map') {
        switch ($change) {
            registration { $instances[1].AgentId = 23 }
            config { '{"pins":"two"}' | Set-Content -LiteralPath (Join-Path $clones[0] 'runners.json') }
            source { $options.SourceCommit = 'b' * 40 }
            scope { $options.GitHubUrl = 'https://github.com/example' }
            instance-map { $instances = @($instances[1], $instances[0]) }
        }
        $f.Calls.Clear()
        Invoke-RunnerSetupAcceptance $root example/private $instances $options
        Assert ($f.Calls -contains 'Builds' -and $f.Calls -contains 'Force') "Changed $change reused obsolete acceptance."
    }
    # Completed Host/Builds survive a later failure; the failed stage and those after it do not become passed.
    $state.completed = @{}; Save-RunnerAcceptanceState $root $state
    $f.Fail = 'Timeout'
    Assert-Throws { Invoke-RunnerSetupAcceptance $root example/private $instances $options } 'Lifecycle failure was hidden.'
    $state = Get-RunnerAcceptanceState $root
    Assert ($state.completed.ContainsKey('Host') -and $state.completed.ContainsKey('Builds') -and $state.completed.ContainsKey('Drain') -and -not $state.completed.ContainsKey('Timeout') -and -not $state.completed.ContainsKey('Force')) 'Failed lifecycle stage was marked complete or previous evidence lost.'
    $f.Fail = ''; $f.Calls.Clear()
    Invoke-RunnerSetupAcceptance $root example/private $instances $options
    Assert ($f.Calls -contains 'Timeout' -and $f.Calls -contains 'Force' -and $f.Calls -notcontains 'Drain' -and $f.Calls -notcontains 'Builds') 'Resume did not continue at the failed checkpoint.'

    $instances = @($instances[1], $instances[0])

    # Recovery runs BEFORE installation may start anything. A failed-stop hold is never cleared automatically.
    . $setup
    $f.Held = $true
    function Stop-RunnerAcceptanceRun { param($Repository, $Run) $f.Cancelled++; [pscustomobject]@{ status = 'completed'; conclusion = 'cancelled' } }
    function Get-RunnerAcceptanceFacts { param($Clone) [pscustomobject]@{ admission = @{ maintenance = $(if ($f.Held) { @{ phase = 'stop-failed' } } else { $null }) } } }
    $state = Get-RunnerAcceptanceState $root
    $state.activeRun = @{ id = 81; correlation = 'own'; clone = $clones[0]; stopAttempted = $true }
    Save-RunnerAcceptanceState $root $state
    Assert-Throws { Resume-RunnerSetupAcceptance $root example/private 2 } 'Recovery accepted a retained failed-stop hold.'
    Assert ((Get-RunnerAcceptanceState $root).activeRun.stopAttempted) 'Recovery discarded its failed-stop journal.'
    $f.Held = $false
    Resume-RunnerSetupAcceptance $root example/private 2
    Assert (-not (Get-RunnerAcceptanceState $root).activeRun) 'Recovery did not clear a cleaned-up controlled run.'
    $state.activeRun = @{ id = 81; correlation = 'own'; clone = 'C:\unrelated'; stopAttempted = $true }
    Save-RunnerAcceptanceState $root $state
    $cancelledBefore = $f.Cancelled
    Assert-Throws { Resume-RunnerSetupAcceptance $root example/private 2 } 'Recovery accepted an unrelated clone.'
    Assert ($f.Cancelled -eq $cancelledBefore) 'Invalid recovery touched GitHub.'
    Assert-Throws { Resume-RunnerSetupAcceptance $root other/private 2 } 'Recovery crossed repository boundaries.'
    # A crash after dispatch but before discovering its run ID is resolved from the saved correlation.
    $state.activeRun = @{ id = 0; correlation = 'own'; clone = ''; stopAttempted = $false }
    Save-RunnerAcceptanceState $root $state
    function Find-RunnerAcceptanceRun { param($Repository, $Correlation) [pscustomobject]@{ id = 82 } }
    Resume-RunnerSetupAcceptance $root example/private 2
    Assert (-not (Get-RunnerAcceptanceState $root).activeRun) 'Dispatch/discovery interruption was not recovered.'

    # The real cancellation helper rejects a run not owned by this workflow/correlation.
    . $setup
    $f.WrongRun = $true; $f.Writes = 0
    function Invoke-RunnerSetupGh {
        param($Arguments)
        [pscustomobject]@{ id = 81; run_attempt = 1; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-lifecycle-acceptance.yml'; display_title = $(if ($f.WrongRun) { 'somebody else' } else { 'Windows runner lifecycle acceptance own' }); status = 'completed' }
    }
    function Send-RunnerSetupGh { param($Arguments, $Body) $f.Writes++ }
    Assert-Throws { Stop-RunnerAcceptanceRun example/private @{ id = 81; correlation = 'own' } } 'Cancellation accepted another run.'
    Assert ($f.Writes -eq 0) 'Cancellation touched an unrelated run.'
    $f.WrongRun = $false
    Stop-RunnerAcceptanceRun example/private @{ id = 81; correlation = 'own' } | Out-Null
    Assert ($f.Writes -eq 0) 'Completed run was cancelled again.'

    # Real lifecycle controller against API/process recorders: identity checks, cleanup, failed-stop journal.
    . $setup
    $f.WrongRunner = $false; $f.StopFails = $false; $f.LocalChecks = 0; $f.Correlation = ''; $f.RemoteDone = $false; $f.Cancel = 0
    Set-Item -Path Function:Invoke-RunnerSetupGh -Value {
        param($Arguments)
        $url = $Arguments[1]
        if ($url -eq 'repos/example/private') { return [pscustomobject]@{ default_branch = 'main' } }
        if ($url -like '*runs?event=*') { return [pscustomobject]@{ workflow_runs = @(@{ id = 81; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-lifecycle-acceptance.yml'; run_attempt = 1; head_branch = 'main'; status = 'in_progress'; display_title = "Windows runner lifecycle acceptance $($f.Correlation)" }) } }
        if ($url -like '*/jobs?*') {
            return [pscustomobject]@{ jobs = @(@{ id = 91; run_id = 81; run_attempt = 1; name = 'Controlled lifecycle job'; status = 'in_progress'; runner_name = 'runner-one'; runner_id = $(if ($f.WrongRunner) { 99 } else { 11 }); steps = @(@{ name = 'Hold controlled acceptance job'; status = 'in_progress' }) }) }
        }
        if ($url -like '*/runs/81') { return [pscustomobject]@{ id = 81; run_attempt = 1; head_branch = 'main'; status = $(if ($f.RemoteDone) { 'completed' } else { 'in_progress' }); conclusion = 'success'; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-lifecycle-acceptance.yml'; display_title = "Windows runner lifecycle acceptance $($f.Correlation)" } }
        throw "Unexpected API read: $url"
    }
    Set-Item -Path Function:Send-RunnerSetupGh -Value {
        param($Arguments, $Body)
        if ($Arguments -like '*/cancel') { $f.Cancel++; $f.RemoteDone = $true }
        else { $f.Correlation = $Body.inputs.correlation; $f.RemoteDone = $false }
    }
    function Get-RunnerAcceptanceFacts { param($Clone) [pscustomobject]@{ registered = $true; agentId = 11; agentName = 'runner-one' } }
    function Get-RunnerAcceptanceStatus { param($Clone) [pscustomobject]@{ Job = 'running (worker pid 7)'; Maintenance = $null } }
    Set-Item -Path Function:Invoke-RunnerAcceptanceProcess -Value {
        param($Script, $Parameters)
        $f.LocalChecks++
        Assert ($Parameters.AllowDisruptive -and $Parameters.DisruptiveClone -eq $clones[0]) 'Lifecycle controller chose another clone or lost its disruptive flag.'
        if ($f.StopFails) { throw 'synthetic failed stop; maintenance held' }
        if ($Parameters.Stage -contains 'Drain') { $f.RemoteDone = $true }
    }
    foreach ($mode in 'Drain', 'Timeout', 'Force') {
        $state = Get-RunnerAcceptanceState $root; $state.activeRun = $null
        Invoke-RunnerAcceptanceLifecycle -InstallRoot $root -Repository example/private -SourceClone $clones[0] -Clones $clones -Instances $instances -State $state -Mode $mode
        Assert (-not (Get-RunnerAcceptanceState $root).activeRun) "$mode leaked its controlled run."
    }
    Assert ($f.LocalChecks -eq 3 -and $f.Cancel -eq 2) 'Controlled lifecycle runs were not cleaned up.'
    $f.WrongRunner = $true; $beforeCheck = $f.LocalChecks
    Assert-Throws { Invoke-RunnerAcceptanceLifecycle -InstallRoot $root -Repository example/private -SourceClone $clones[0] -Clones $clones -Instances $instances -State $state -Mode Force } 'Runner-ID mismatch accepted.'
    Assert ($f.LocalChecks -eq $beforeCheck -and -not (Get-RunnerAcceptanceState $root).activeRun) 'Wrong-runner case touched the host or leaked its run.'
    $f.WrongRunner = $false; $f.StopFails = $true
    Assert-Throws { Invoke-RunnerAcceptanceLifecycle -InstallRoot $root -Repository example/private -SourceClone $clones[0] -Clones $clones -Instances $instances -State $state -Mode Force } 'Failed stop swallowed.'
    Assert ((Get-RunnerAcceptanceState $root).activeRun.stopAttempted) 'Remote cleanup discarded a failed-stop journal.'

    $state.activeRun = $null; Save-RunnerAcceptanceState $root $state

    # Real high-level setup: rejected targets and deferred Docker actions must not trigger acceptance or claim readiness.
    . $setup
    $f.Acceptance = 0; $f.BuildExit = 0; $f.Recover = 0; $f.Install = 0; $f.Private = $true; $f.AcceptFail = $false
    function Confirm-RunnerSetupAuthentication { param($Scope, $NonInteractive, $WithSmoke) $f.WorkflowAuth = $WithSmoke }
    function Confirm-RunnerSetupRepositories { param($Scope, $Repositories) $Repositories }
    Set-Item -Path Function:Invoke-RunnerSetupGh -Value { param($Arguments) [pscustomobject]@{ private = $f.Private } }
    function Resume-RunnerSetupAcceptance { param($InstallRoot, $Repository, $Count) $f.Recover++; if ($f.Held) { throw 'maintenance held' } }
    function Sync-RunnerSetupInstance { param($Clone, $InstanceId, $SourceCommit, $GitHubUrl) }
    function Install-RunnerSetupInstance { param($Clone, $InstanceId, $GitHubUrl, $Labels) $f.Install++ }
    function Get-RunnerSetupEvidence { param($Clone, $InstanceId) [pscustomobject]@{ Instance = $InstanceId; Name = $InstanceId; AgentId = [int]$InstanceId.Substring(3) } }
    function Confirm-RunnerSetupHost { param($Instances, $Scope) }
    function Install-RunnerSetupBuildAgent { param($Clone, $InstallRoot) $f.BuildExit }
    function Invoke-RunnerSetupAcceptance { param($InstallRoot, $Repository, $Instances, $SetupOptions) $f.Acceptance++; if ($f.AcceptFail) { throw 'acceptance failed' } }
    $hostOptions = @{ Count = 2; InstallRoot = $root; GitHubUrl = 'https://github.com/example/private'; SourceCommit = 'a' * 40; VerificationRepository = 'example/private'; NonInteractive = $true }
    $f.BuildExit = 2
    $paused = Invoke-WindowsRunnerHostSetup @hostOptions | Select-Object -Last 1
    Assert ($paused.ExitCode -eq 2 -and $paused.Verification -eq 'blocked' -and $f.Acceptance -eq 0 -and $f.WorkflowAuth) 'Pending Docker action ran acceptance or lost its exit 2.'
    $f.BuildExit = 0
    $done = Invoke-WindowsRunnerHostSetup @hostOptions | Select-Object -Last 1
    Assert ($done.ExitCode -eq 0 -and $done.Verification -eq 'passed' -and $f.Acceptance -eq 1) 'Ready host did not run end-to-end verification.'
    $f.AcceptFail = $true
    $failed = Invoke-WindowsRunnerHostSetup @hostOptions 3>$null | Select-Object -Last 1
    Assert ($failed.ExitCode -eq 1 -and $failed.Verification -eq 'failed') 'Acceptance failure was reported as successful setup.'
    $f.Held = $true; $beforeInstall = $f.Install
    Assert-Throws { Invoke-WindowsRunnerHostSetup @hostOptions } 'An interrupted failed-stop hold was ignored.'
    Assert ($f.Install -eq $beforeInstall) 'Installer ran before maintenance recovery was checked.'
    $f.Held = $false; $f.Private = $false
    Assert-Throws { Invoke-WindowsRunnerHostSetup @hostOptions } 'Public verification repository accepted.'
    $f.Private = $true; $hostOptions.VerificationRepository = 'other/project'
    Assert-Throws { Invoke-WindowsRunnerHostSetup @hostOptions } 'Cross-scope acceptance repository accepted.'
    $hostOptions.VerificationRepository = 'example/private'; $hostOptions.Count = 1
    Assert-Throws { Invoke-WindowsRunnerHostSetup @hostOptions } 'Single runner accepted for concurrent verification.'
    $hostOptions.Count = 2; $hostOptions.SkipBuildAgent = $true
    Assert-Throws { Invoke-WindowsRunnerHostSetup @hostOptions } 'Verification accepted disabled BuildAgent.'

    # The real worker process must exit with the overall result (a failed acceptance is exit 1 even though BuildAgent exited 0),
    # not with the BuildAgent exit code alone; the 5.1 entry point only treats 0 and 2 as non-fatal.
    $workerDir = Join-Path $root 'exit-worker\scripts'
    New-Item -ItemType Directory -Path $workerDir -Force | Out-Null
    foreach ($file in 'Configure-WindowsRunners.ps1', 'RunnerConfig.ps1', 'HostState.ps1') { Copy-Item -LiteralPath (Join-Path $repo "scripts\$file") -Destination $workerDir }
    $savedLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = Join-Path $root 'exit-worker\LocalAppData'
    $workerOptions = Join-Path $root 'exit-worker\options.json'
    '{}' | Set-Content -LiteralPath $workerOptions
    $pwshExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    foreach ($case in @(@{ Overall = 0; BuildAgent = 0 }, @{ Overall = 1; BuildAgent = 0 }, @{ Overall = 2; BuildAgent = 2 }, @{ Overall = 1; BuildAgent = 1 })) {
        "function Invoke-WindowsRunnerHostSetup { param() [pscustomobject]@{ BuildAgentExitCode = $($case.BuildAgent); ExitCode = $($case.Overall) } }" | Set-Content -LiteralPath (Join-Path $workerDir 'WindowsRunnerSetup.ps1')
        & $pwshExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $workerDir 'Configure-WindowsRunners.ps1') -OptionsPath $workerOptions | Out-Null
        $workerExit = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Assert ($workerExit -eq $case.Overall) "Worker exited $workerExit for overall result $($case.Overall) (BuildAgent $($case.BuildAgent))."
    }
    $env:LOCALAPPDATA = $savedLocalAppData
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temp.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS: automatic setup stages, exact child arguments, checkpoint resume/invalidation, interrupted-run ownership and maintenance protection, registration boundaries, deferred actions and failure exits (host/GitHub operations mocked).'
