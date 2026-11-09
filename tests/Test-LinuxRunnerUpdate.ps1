#Requires -Version 7.2
# Real -Update entry point, version/isolation guards, invocation and maintenance persistence.
# All native calls and GitHub admission operations are fixtures; no Docker daemon/host tool/runner is touched.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('linux-update-' + [guid]::NewGuid().ToString('N'))
$pwsh = (Get-Process -Id $PID).Path
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
try {
    $scripts = Join-Path $temp 'scripts'
    New-Item -ItemType Directory $scripts -Force | Out-Null
    foreach ($file in 'New-LinuxRunner.ps1', 'RunnerConfig.ps1', 'BuildAgent.ps1', 'RunnerArchive.ps1', 'Registration.ps1', 'Compose.ps1', 'HostState.ps1') {
        Copy-Item (Join-Path $repo "scripts/$file") $scripts
    }
    # Common is entirely synthetic. Production version/isolation/state-machine code remains intact.
    @'
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$env:LOCALAPPDATA = Join-Path $Root 'localappdata'
. "$PSScriptRoot/RunnerConfig.ps1"
. "$PSScriptRoot/HostState.ps1"
$Config = Read-RunnerConfig $Root
$LinuxRunner = Join-Path $Root 'registration'
$Docker = 'fixture-docker'
$DockerSidecar = if ($Config.linux.docker.mode -eq 'sidecar') { $Config.linux.docker.container }
$fixture = Get-Content -Raw (Join-Path $Root 'case.json') | ConvertFrom-Json
function Get-LinuxMaintenanceFile { Join-Path $LinuxRunner 'maintenance.json' }
function Trace($Name, $Value) { Add-Content (Join-Path $Root 'trace.jsonl') (ConvertTo-Json -Depth 20 -Compress @{ Name = $Name; Value = $Value }) }
'@ | Set-Content (Join-Path $scripts 'Common.ps1')
    # Load the actual lifecycle functions, then replace only remote/native operations.
    Copy-Item (Join-Path $repo 'scripts/Lifecycle.ps1') (Join-Path $scripts 'Lifecycle.ps1')
    @'
function Get-RunnerAdmission {
    param($RunnerDirectory)
    Trace 'admission' $true
    [pscustomobject]@{ Scope='repos/test/fixture'; RunnerId=7; AgentName='fixture'; Labels=@('subzerodev-linux') }
}
function Invoke-Docker { param([string[]] $Arguments) [pscustomobject]@{ ExitCode = 0; Output = '<no value>' } }
function Close-RunnerAdmission { param($Admission) Trace 'close' $true }
function Restore-RunnerAdmission {
    param($State, $RunnerDirectory)
    Trace 'restore' $State.savedLabels
    if ($fixture.restoreFails) { throw 'fixture label restoration failed' }
}
function Wait-RunnerIdle { param($IsBusy, $RunnerDirectory, $TimeoutMinutes, $PollSeconds, $UseGitHub) [pscustomobject]@{ Idle=($fixture.drain -ne 'timeout') } }
function Test-LinuxRunnerBusy { $false }
function Invoke-BoundedNative {
    param($FilePath, $Arguments, $TimeoutSeconds, $Environment)
    Trace 'native' @{ FilePath=$FilePath; Arguments=@($Arguments); Timeout=$TimeoutSeconds; Environment=$Environment }
    if ($FilePath -eq 'fixture-docker') {
        if ($fixture.isolation -eq 'unreadable') { return [pscustomobject]@{ ExitCode=1; Output=''; Started=$true; TimedOut=$false } }
        if ($fixture.isolation -eq 'malformed') { return [pscustomobject]@{ ExitCode=0; Output='{'; Started=$true; TimedOut=$false } }
        if ($Arguments[2] -like '*Config.Env*') {
            $output = if ($fixture.isolation -eq 'no-hook') { '' } else { 'configured' }
        } else {
            $sidecarRead = $Arguments[-1] -eq $Config.linux.docker.container
            $mounts = if ($sidecarRead) {
                @([pscustomobject]@{ Type='volume'; Name="$($Config.linux.container)-runtimes"; Destination='/runner/externals'; RW=$false })
            } else {
                @([pscustomobject]@{ Type='volume'; Name="$($Config.linux.container)-runtimes"; Destination='/runner-runtime'; RW=$true })
            }
            if ($sidecarRead -and $fixture.isolation -eq 'old-bind') { $mounts += [pscustomobject]@{ Type='bind'; Source=$LinuxRunner; Destination='/runner'; RW=$false } }
            if ($sidecarRead -and $fixture.isolation -eq 'alternate-bind') { $mounts += [pscustomobject]@{ Type='bind'; Source=$LinuxRunner; Destination='/unexpected'; RW=$false } }
            if ($sidecarRead -and $fixture.isolation -eq 'writable') { $mounts[0].RW=$true }
            if (-not $sidecarRead -and $fixture.isolation -eq 'no-runner-volume') { $mounts=@() }
            $output = ConvertTo-Json -InputObject @($mounts) -Compress
        }
        return [pscustomobject]@{ ExitCode=0; Output=$output; Started=$true; TimedOut=$false }
    }
    if ($fixture.crash) { Trace 'crash' $true; [Environment]::Exit(99) }
    if ($fixture.throws) { throw 'fixture native failure' }
    [pscustomobject]@{ ExitCode=$fixture.code; Output=$fixture.output; Started=(-not $fixture.notStarted); TimedOut=[bool]$fixture.timedOut }
}
'@ | Add-Content (Join-Path $scripts 'Lifecycle.ps1')
    $registration = Join-Path $temp 'registration'
    New-Item -ItemType Directory $registration -Force | Out-Null
    Set-Content (Join-Path $registration '.runner') '{"agentId":7,"agentName":"fixture","workFolder":"/tmp/runner-work"}'
    Set-Content (Join-Path $registration '.credentials') 'SYNTHETIC-CREDENTIAL-CANARY'
    $credentialHash = (Get-FileHash (Join-Path $registration '.credentials')).Hash
    $registrationHash = (Get-FileHash (Join-Path $registration '.runner')).Hash
    $stateFile = Join-Path $registration 'maintenance.json'
    $traceFile = Join-Path $temp 'trace.jsonl'
    $toolDir = Join-Path $temp 'tool'
    New-Item -ItemType Directory $toolDir -Force | Out-Null
    Set-Content (Join-Path $toolDir 'build-agent.exe') 'not executable; native invocation is mocked'
    function Invoke-Case {
        param([hashtable] $Values=@{}, [scriptblock] $Configure, [switch] $KeepMaintenance)
        $case = @{ code=0; output='fixture outcome'; isolation='isolated'; drain='idle' }
        foreach ($key in $Values.Keys) { $case[$key]=$Values[$key] }
        $case | ConvertTo-Json | Set-Content (Join-Path $temp 'case.json')
        Remove-Item $traceFile -ErrorAction SilentlyContinue
        if (-not $KeepMaintenance) { Remove-Item $stateFile -ErrorAction SilentlyContinue }
        $config = Get-Content -Raw (Join-Path $repo 'runners.json') | ConvertFrom-Json
        $config.buildAgent.tool.directory = $toolDir
        $config.buildAgent.dotnetRuntime.directory = Join-Path $temp 'runtime'
        $config.buildAgent.paths.workspaceRoot = Join-Path $temp 'workspaces'
        $installed = if ($case.installed) { $case.installed } else { '2.2.0' }
        $store = Join-Path $toolDir '.store/buildagent.tool'
        Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory (Join-Path $store $installed) -Force | Out-Null
        if ($Configure) { & $Configure $config }
        $config | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $temp 'runners.json')
        $output = & $pwsh -NoProfile -File (Join-Path $scripts 'New-LinuxRunner.ps1') -Update 2>&1 | Out-String
        $code = $LASTEXITCODE
        $trace = @(if (Test-Path $traceFile) { Get-Content $traceFile | ForEach-Object { $_ | ConvertFrom-Json } })
        $state = if (Test-Path $stateFile) { Get-Content -Raw $stateFile | ConvertFrom-Json }
        Assert ((Get-FileHash (Join-Path $registration '.credentials')).Hash -eq $credentialHash) 'Credential fixture changed.'
        Assert ((Get-FileHash (Join-Path $registration '.runner')).Hash -eq $registrationHash) 'Registration fixture changed.'
        [pscustomobject]@{ Code=$code; Trace=$trace; State=$state; Output=$output }
    }
    function Updates($Run) { @($Run.Trace | Where-Object { $_.Name -eq 'native' -and $_.Value.Arguments[0] -eq 'update' }) }
    function Count-Trace($Run, $Name) { @($Run.Trace | Where-Object Name -eq $Name).Count }
    function Assert-PreflightRefusal($Run) {
        Assert ($Run.Code -ne 0 -and (Count-Trace $Run 'close') -eq 0 -and (Updates $Run).Count -eq 0) "Refusal mutated admission or ran updater: $($Run.Output)"
    }
    # Exercise the real installer decision and exact SDK arguments with a synthetic package store/native command.
    & {
        . (Join-Path $repo 'scripts/RunnerConfig.ps1')
        . (Join-Path $repo 'scripts/BuildAgent.ps1')
        $settings = [pscustomobject]@{ ToolDirectory=$toolDir; ToolExe=(Join-Path $toolDir 'build-agent.exe'); Package='BuildAgent.Tool'; Version='2.2.0' }
        $store = Join-Path $toolDir '.store/buildagent.tool'
        New-Item -ItemType Directory (Join-Path $store '2.1.0') -Force | Out-Null
        $calls = [Collections.Generic.List[object]]::new()
        function Invoke-Native {
            param($FilePath, $Arguments, $Description)
            $calls.Add(@{ FilePath=$FilePath; Arguments=$Arguments })
            Remove-Item $store -Recurse -Force
            New-Item -ItemType Directory (Join-Path $store '2.2.0') -Force | Out-Null
        }
        Assert ((Install-BuildAgentTool $settings 'fixture-sdk') -eq 'updated') 'Old tool was not updated by installer decision.'
        Assert ($calls.Count -eq 1 -and $calls[0].FilePath -eq 'fixture-sdk' -and ($calls[0].Arguments -join '|') -eq "tool|update|BuildAgent.Tool|--tool-path|$toolDir|--version|2.2.0") 'Installer did not request exact version/tool path.'
        Assert ((Install-BuildAgentTool $settings 'fixture-sdk') -eq 'present' -and $calls.Count -eq 1) 'Matching tool was reinstalled.'
        # Status must report the same gate, rather than treating any non-null updater pin as available.
        function Test-BuildAgentRuntime { param($Settings) $true }
        function Assert-BuildAgentMapping { param($Settings, $RunnerRoot) }
        function Get-DockerDaemonState { param($DockerExe, $DockerHost, $TimeoutSeconds) [pscustomobject]@{ Reachable=$true; OSType='linux'; Detail='fixture daemon' } }
        function Invoke-BoundedNative { param($FilePath, $Arguments, $TimeoutSeconds, $Environment) [pscustomobject]@{ ExitCode=0; Output='fixture image'; Started=$true; TimedOut=$false } }
        $config = Get-Content -Raw (Join-Path $repo 'runners.json') | ConvertFrom-Json
        $config.buildAgent.tool.directory = $toolDir
        $status = Get-BuildAgentStatus $config $temp 'fixture-docker'
        Assert (($status | Where-Object Item -eq 'updater').State -eq 'ok') 'Matching installed updater was unavailable in status.'
        $config.buildAgent.tool.version = '2.1.0'
        $status = Get-BuildAgentStatus $config $temp 'fixture-docker'
        Assert (($status | Where-Object Item -eq 'updater').State -eq 'missing') 'Mismatched configuration was available in status.'
        $config.buildAgent.tool.version = '2.2.0'
        Remove-Item (Join-Path $toolDir 'build-agent.exe')
        $status = Get-BuildAgentStatus $config $temp 'fixture-docker'
        Assert (($status | Where-Object Item -eq 'updater').State -eq 'missing') 'Absent tool was available in status.'
        Set-Content (Join-Path $toolDir 'build-agent.exe') 'not executable; native invocation is mocked'
    }
    foreach ($installed in '2.1.0','2.3.0') { Assert-PreflightRefusal (Invoke-Case @{ installed=$installed }) }
    Assert-PreflightRefusal (Invoke-Case -Configure { param($c) $c.buildAgent.updater.version=$null })
    Assert-PreflightRefusal (Invoke-Case -Configure { param($c) $c.buildAgent.updater.version='2.3.0' })
    foreach ($version in '2.0.0','2.1.0','2.2.0-preview.1') {
        Assert-PreflightRefusal (Invoke-Case @{ installed=$version } -Configure { param($c) $c.buildAgent.tool.version=$version; $c.buildAgent.updater.version=$version }.GetNewClosure())
    }
    foreach ($shape in 'old-bind','alternate-bind','writable','unreadable','malformed','no-hook','no-runner-volume') {
        Assert-PreflightRefusal (Invoke-Case @{ isolation=$shape })
    }
    Assert-PreflightRefusal (Invoke-Case -Configure { param($c) $c.linux.docker.workVolume="$($c.linux.container)-runtimes" })
    foreach ($duration in '0s','invalid','999999999h') { Assert-PreflightRefusal (Invoke-Case -Configure { param($c) $c.buildAgent.updater.healthTimeout=$duration }.GetNewClosure()) }

    foreach ($code in 0,10,20,23,24,30) {
        $run = Invoke-Case @{ code=$code; output= $(if ($code -eq 20) { 'TargetShapeUnsupported: HostConfig.CapAdd' } else { 'fixture outcome' }) }
        Assert ($run.Code -eq $(if ($code -eq 0) { 0 } else { 1 })) "Incorrect script status for updater exit ${code}: $($run.Output)"
        Assert ($null -eq $run.State -and (Count-Trace $run 'restore') -eq 1) "Admission not restored for completed exit ${code}: $($run.Output)"
        Assert ((Updates $run).Count -eq 1) 'Updater not called exactly once.'
        $native = (Updates $run)[0].Value
        Assert (($native.Arguments -join ' ') -eq 'update subzerodev-runner-linux --image subzerodev-runner-linux:local --health-timeout 120s') 'Updater contract changed.'
        Assert ($native.Timeout -eq 720 -and $native.Environment.DOTNET_ROOT -eq (Join-Path $temp 'runtime')) 'Updater environment/timeout incorrect.'
        $nativeAt = [array]::IndexOf($run.Trace, (Updates $run)[0])
        $closeAt = [array]::FindIndex([object[]]$run.Trace, [Predicate[object]]{ param($r) $r.Name -eq 'close' })
        Assert ($closeAt -ge 0 -and $closeAt -lt $nativeAt) 'Updater ran before admission closed.'
        # Only inspect calls may reach Docker: no sidecar, mount or projection is recreated/migrated by -Update.
        Assert (@($run.Trace | Where-Object { $_.Name -eq 'native' -and $_.Value.FilePath -eq 'fixture-docker' -and $_.Value.Arguments[0] -ne 'inspect' }).Count -eq 0) 'Unexpected Docker mutation.'
        if ($code -eq 20) { Assert ($run.Output -match 'TargetShapeUnsupported.*CapAdd' -and $run.Output -match 'untouched') 'Unsupported-settings refusal was hidden.' }
    }
    foreach ($code in 1,11,12,21,22,99) {
        $run = Invoke-Case @{ code=$code }
        Assert ($run.Code -eq 1 -and $run.State.phase -eq 'update-recovery-required' -and (Count-Trace $run 'restore') -eq 0) "Unresolved exit $code reopened admission: $($run.Output)"
        Assert ($run.State.savedLabels -contains 'subzerodev-linux') 'Recovery record lost labels.'
    }
    foreach ($failure in 'timedOut','notStarted','throws') {
        $run = Invoke-Case @{ $failure=$true }
        Assert ($run.Code -eq 1 -and $null -ne $run.State -and (Count-Trace $run 'restore') -eq 0) "$failure reopened admission."
    }
    $run = Invoke-Case @{ code=0; restoreFails=$true }
    Assert ($run.Code -eq 1 -and $run.State.savedLabels -contains 'subzerodev-linux') 'Failed label restoration lost recovery.'
    $run = Invoke-Case @{ drain='timeout' }
    Assert ($run.Code -eq 1 -and (Updates $run).Count -eq 0 -and $null -eq $run.State) 'Busy runner was updated or not readmitted.'

    # Abrupt termination after admission closes: durable state survives across processes. Even an upstream early
    # refusal or AlreadyCurrent must not clear it on retry; only explicit operator recovery may end maintenance.
    $run = Invoke-Case @{ crash=$true }
    Assert ($run.Code -eq 99 -and $run.State.savedLabels -contains 'subzerodev-linux') 'Abrupt interruption lost maintenance.'
    foreach ($code in 0,10,20,21,22,30) {
        $run = Invoke-Case @{ code=$code } -KeepMaintenance
        Assert-PreflightRefusal $run
        Assert ((Count-Trace $run 'restore') -eq 0 -and $run.State.savedLabels -contains 'subzerodev-linux') 'Retry of interrupted update reopened admission.'
    }
    @'
. "$PSScriptRoot/Common.ps1"
. "$PSScriptRoot/Registration.ps1"
. "$PSScriptRoot/Lifecycle.ps1"
Exit-RunnerMaintenance (Get-LinuxMaintenanceFile) $LinuxRunner | Out-Null
'@ | Set-Content (Join-Path $scripts 'recover.ps1')
    & $pwsh -NoProfile -File (Join-Path $scripts 'recover.ps1')
    Assert ($LASTEXITCODE -eq 0 -and -not (Test-Path $stateFile)) 'Explicit synthetic operator recovery failed.'
    $run = Invoke-Case @{ code=10; output='Interrupted: original container restored' } -KeepMaintenance
    Assert ($run.Code -eq 1 -and $null -eq $run.State -and (Count-Trace $run 'restore') -eq 1) 'Confirmed graceful interruption did not restore maintenance.'

    foreach ($duration in @(@('2m',720), @('1h',4200), @('120',720))) {
        $run = Invoke-Case -Configure { param($c) $c.buildAgent.updater.healthTimeout=$duration[0] }.GetNewClosure()
        Assert ($run.Code -eq 0 -and (Updates $run)[0].Value.Timeout -eq $duration[1]) "Incorrect duration: $($duration[0])"
    }
    $run = Invoke-Case -Configure { param($c) $c.linux.docker.mode='dind' }
    Assert ($run.Code -eq 0 -and @($run.Trace | Where-Object { $_.Name -eq 'native' -and $_.Value.FilePath -eq 'fixture-docker' }).Count -eq 0) 'DinD acquired a sidecar dependency.'
    Write-Output 'PASS: coordinated/installed version gates; isolation refusal; drain ordering; updater exit outcomes; saved-label restoration; failure/timeout; crash/lock/recovery across processes; duration units; DinD (synthetic native/GitHub evidence only).'
    $global:LASTEXITCODE = 0
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
