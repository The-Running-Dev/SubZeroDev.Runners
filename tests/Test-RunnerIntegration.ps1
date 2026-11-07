#Requires -Version 7.2
# Decisions and guards of the BuildAgent integration, registration, lifecycle, housekeeping and Linux image, with GitHub, Docker
# and the Windows process table mocked or replaced by temp folders. Nothing here contacts GitHub or a Docker daemon, so it
# is fixture evidence: it does not replace a run on a Windows host with Docker Desktop, or a real GitHub job.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern, [string] $Message) {
    $thrown = $null
    try { & $Action | Out-Null } catch { $thrown = $_.Exception.Message }
    Assert ($null -ne $thrown) "$Message (nothing was thrown)"
    Assert ($thrown -match $Pattern) "$Message (got: $thrown)"
}

. (Join-Path $repo 'scripts\Common.ps1')
. (Join-Path $repo 'scripts\BuildAgent.ps1')
. (Join-Path $repo 'scripts\Registration.ps1')
. (Join-Path $repo 'scripts\Lifecycle.ps1')
. (Join-Path $repo 'scripts\Housekeeping.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ("runner-integration-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
function Copy-RunnerSettings { Get-Content -Raw -LiteralPath (Join-Path $repo 'runners.json') | ConvertFrom-Json }
try {
    # --- configuration ---------------------------------------------------------------------------------------------
    Assert-RunnerConfig (Copy-RunnerSettings)
    $c = Copy-RunnerSettings; $c.buildAgent.image = 'ghcr.io/the-running-dev/build-agent:latest'
    Assert-Throws { Assert-RunnerConfig $c } 'pinned by digest' 'A tag (latest) was accepted as the BuildAgent image.'
    $c = Copy-RunnerSettings; $c.buildAgent.tool.version = 'latest'
    Assert-Throws { Assert-RunnerConfig $c } 'exact version' 'A floating tool version was accepted.'
    $c = Copy-RunnerSettings; $c.buildAgent.paths.extraMounts = @('D:\cache:/cache')
    Assert-Throws { Assert-RunnerConfig $c } 'extraMounts' 'An extra mount was accepted although build-agent build cannot add one.'
    $c = Copy-RunnerSettings; $c.buildAgent.paths.outputDirectory = '..\escape'
    Assert-Throws { Assert-RunnerConfig $c } 'outputDirectory' 'An output directory outside the workspace was accepted.'
    $c = Copy-RunnerSettings; $c.buildAgent | Add-Member -Force -NotePropertyName updater -NotePropertyValue ([pscustomobject]@{ version = 'latest'; healthTimeout = '120s' })
    Assert-Throws { Assert-RunnerConfig $c } 'updater.version' 'updater.version latest was accepted.'
    $c = Copy-RunnerSettings; $c.runnerVersion = 'latest'; $c.lifecycle.pollSeconds = 0; $c.linux.docker.mode = 'bogus'
    $message = try { Assert-RunnerConfig $c } catch { $_.Exception.Message }
    Assert ($message -match 'runnerVersion' -and $message -match 'pollSeconds' -and $message -match 'docker.mode') "Invalid settings were not all reported together: $message"

    # One merged loader: runners.local.json changes one setting and nothing else.
    $clone = Join-Path $temp 'clone'
    New-Item -ItemType Directory -Path $clone | Out-Null
    Copy-Item (Join-Path $repo 'runners.json') $clone
    Set-Content (Join-Path $clone 'runners.local.json') '{ "linux": { "docker": { "mode": "dind" } }, "windows": { "instanceId": "win07", "labels": ["extra-one"] } }'
    $merged = Read-RunnerConfig -Root $clone
    $base = Copy-RunnerSettings
    Assert ($merged.linux.docker.mode -eq 'dind' -and $merged.linux.docker.container -eq $base.linux.docker.container) 'The local override replaced the whole docker object instead of one setting.'
    Assert ($merged.windows.instanceId -eq 'win07') 'The local instance id did not reach the merged settings.'
    Assert ($merged.linux.baseImage -eq $base.buildAgent.image) 'The Linux base image is not the BuildAgent image digest.'
    Set-Content (Join-Path $clone 'runners.local.json') '{ "buildAgent": { "image": "ghcr.io/the-running-dev/build-agent:latest" } }'
    Assert-Throws { Read-RunnerConfig -Root $clone } 'pinned by digest' 'A local override with latest passed validation.'
    Set-Content (Join-Path $clone 'runners.local.json') '{ not json'
    Assert-Throws { Read-RunnerConfig -Root $clone } 'runners.local.json cannot be read' 'A corrupt local file was ignored.'

    # --- BuildAgent invocation and mapping -------------------------------------------------------------------------
    $settings = Get-BuildAgentSettings $Config
    $invocation = Get-BuildAgentInvocation $settings 'docker' @('--target', 'Publish')
    Assert ($invocation.Arguments -join ' ' -eq 'build docker --target Publish') "Unexpected build arguments: $($invocation.Arguments -join ' ')"
    Assert ($invocation.Environment.BUILD_AGENT_IMAGE -match '@sha256:[0-9a-f]{64}$') 'The build does not select the digest-pinned image.'
    Assert ($invocation.Environment.BUILD_AGENT_IMAGE -notmatch ':latest') 'The build selects a floating image.'
    Assert (-not $invocation.Environment.Contains('DOCKER_HOST')) 'DOCKER_HOST was set although no daemon is configured.'
    Assert ($invocation.WorkingDirectory -eq $settings.Workspace) 'The build does not run in the per-instance workspace.'
    foreach ($type in 'docker', 'node', 'node-in-docker', 'node-template', 'forge') { Get-BuildAgentInvocation $settings $type | Out-Null }
    Assert-Throws { Get-BuildAgentInvocation $settings 'run' } 'not a build-agent build type' 'An invented build type was accepted.'
    # Arguments after the type belong to build-agent and reach it unchanged: single-dash options, values that end like a
    # program or script, paths with spaces, bare values and empty values.
    $verbatim = @(
        , @('-AppDir', 'documentation')
        , @('--target', 'Publish')
        , @('--project', 'tool.exe')
        , @('--script', 'build.ps1', '--shell', 'run.cmd', '--file', 'x.bat')
        , @('-AppDir', 'C:\My Projects\site docs', '--output', 'out dir\a b.ps1')
        , @('Publish')
        , @('--name', '', '--label', 'say "hi"'))
    foreach ($arguments in $verbatim) {
        $built = Get-BuildAgentInvocation $settings 'node-template' $arguments
        Assert (($built.Arguments | ConvertTo-Json -Compress) -eq ((@('build', 'node-template') + $arguments) | ConvertTo-Json -Compress)) "Arguments were changed or rejected: $($arguments -join ' | ') -> $($built.Arguments -join ' | ')"
    }
    Assert-Throws { Get-BuildAgentInvocation $settings 'node-template' @('-AppDir', 'documentation') | Out-Null; Get-BuildAgentInvocation $settings 'run' @('-AppDir', 'documentation') } 'not a build-agent build type' 'The build type is no longer validated.'
    # Process level: each argument is exactly one argument of the tool, and the exit status is the tool's own.
    $echo = Join-Path $temp 'echo-arguments.ps1'
    Set-Content -LiteralPath $echo -Value '$args | ConvertTo-Json -AsArray -Compress | Set-Content -LiteralPath $env:ECHO_OUT; exit 7'
    $received = Join-Path $temp 'received.json'
    $env:ECHO_OUT = $received
    try {
        $sent = @('build', 'node-template', '-AppDir', 'C:\My Projects\site docs', '--script', 'build.ps1', '--project', 'tool.exe', '--name', 'say "hi"', 'Publish')
        $fake = [pscustomobject]@{ FilePath = (Get-Process -Id $PID).Path; Arguments = @('-NoLogo', '-NoProfile', '-File', $echo) + $sent; WorkingDirectory = $temp; Environment = @{} }
        $exitStatus = Invoke-BuildAgentInvocation $fake
        Assert ($exitStatus -eq 7) "The tool's exit status was not returned unchanged (got $exitStatus)."
        Assert ((Get-Content -Raw -LiteralPath $received | ConvertFrom-Json -NoEnumerate | ConvertTo-Json -Compress) -eq ($sent | ConvertTo-Json -Compress)) "The tool received different arguments: $(Get-Content -Raw -LiteralPath $received)"
    }
    finally { Remove-Item Env:\ECHO_OUT -ErrorAction SilentlyContinue }
    $withHost = $settings.PSObject.Copy(); $withHost.DockerHost = 'tcp://127.0.0.1:2375'
    Assert ((Get-BuildAgentInvocation $withHost 'docker').Environment.DOCKER_HOST -eq 'tcp://127.0.0.1:2375') 'A configured Docker host was not passed to the build.'

    function New-InstanceConfig([string] $Id) {
        $copy = $Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $copy.windows | Add-Member -Force -NotePropertyName instanceId -NotePropertyValue $Id
        $copy
    }
    $a = Get-BuildAgentSettings (New-InstanceConfig 'win01'); $b = Get-BuildAgentSettings (New-InstanceConfig 'win02')
    Assert ($a.Workspace -ne $b.Workspace -and $a.OutputDirectory -ne $b.OutputDirectory -and $a.CacheDirectory -ne $b.CacheDirectory) 'Two instances share a workspace, output or cache.'
    $okRoot = 'C:\SubZeroDev.Runners\win01'
    $good = $a.PSObject.Copy(); $good.Workspace = 'C:\Builds\win01'; $good.OutputDirectory = 'C:\Builds\win01\out'; $good.CacheDirectory = 'C:\Builds\win01\cache'
    Assert-BuildAgentMapping $good $okRoot
    foreach ($case in @(
            @{ Path = '\\server\share\win01'; Pattern = 'network path' }
            @{ Path = 'C:\Users\Ben\Dropbox\Builds\win01'; Pattern = 'Dropbox' }
            @{ Path = 'C:\SubZeroDev.Runners\win01\work'; Pattern = 'overlaps the runner clone' }
            @{ Path = 'C:\SubZeroDev.Runners'; Pattern = 'overlaps the runner clone' }
            @{ Path = 'C:\Builds,evil\win01'; Pattern = 'comma or quote' })) {
        $bad = $good.PSObject.Copy(); $bad.Workspace = $case.Path; $bad.OutputDirectory = Join-Path $case.Path 'out'; $bad.CacheDirectory = Join-Path $case.Path 'cache'
        Assert-Throws { Assert-BuildAgentMapping $bad $okRoot } $case.Pattern "A workspace at $($case.Path) was accepted."
    }
    $bad = $good.PSObject.Copy(); $bad.OutputDirectory = 'C:\elsewhere\out'
    Assert-Throws { Assert-BuildAgentMapping $bad $okRoot } 'not inside the workspace' 'An output directory outside the workspace was accepted.'

    # --- updater gate (Docker-BuildAgent PR #136) ------------------------------------------------------------------
    function Get-BuildAgentInstalledVersion { param($Settings) $script:installedTool }
    $script:installedTool = '2.1.0'
    $gate = Test-BuildAgentUpdater $settings
    Assert (-not $gate.Available -and $gate.Reason -match '#136') "The updater is available without a version that has PR #136: $($gate.Reason)"
    Assert ($Config.buildAgent.updater.version -eq $null) 'buildAgent.updater.version is set although no published artifact contains PR #136 (never claim 2.1.0 has it).'
    $pinned = $settings.PSObject.Copy(); $pinned.UpdaterVersion = '2.2.0'
    $gate = Test-BuildAgentUpdater $pinned
    Assert (-not $gate.Available -and $gate.Reason -match '2\.2\.0' -and $gate.Reason -match '2\.1\.0') "A different installed tool still enabled the updater: $($gate.Reason)"
    $script:installedTool = '2.2.0'
    Assert (Test-BuildAgentUpdater $pinned).Available 'The updater stayed blocked with the exact configured version installed.'
    $update = Get-BuildAgentUpdateInvocation $pinned 'subzerodev-runner-linux' 'subzerodev-runner-linux:local' '120s'
    Assert ($update.Arguments -join ' ' -eq 'update subzerodev-runner-linux --image subzerodev-runner-linux:local --health-timeout 120s') "Unexpected updater command: $($update.Arguments -join ' ')"
    Assert (-not $update.Environment.ContainsKey('DOCKER_HOST')) 'An empty DOCKER_HOST was passed to the updater.'
    foreach ($code in 10, 20, 30) { Assert ((Get-BuildAgentUpdateExitMeaning $code) -notmatch '^build-agent update exited') "Exit code $code has no meaning." }
    Assert ((Get-BuildAgentUpdateExitMeaning 20) -match 'untouched') 'A refused update does not say the container is untouched.'

    # --- busy boundary: whole path segments ------------------------------------------------------------------------
    Assert (Test-PathUnder 'C:\Runners\win1\bin\Runner.Worker.exe' 'C:\Runners\win1') 'A process inside the runner directory was not matched.'
    Assert (-not (Test-PathUnder 'C:\Runners\win10\bin\Runner.Worker.exe' 'C:\Runners\win1')) 'win10 was matched as part of win1.'
    Assert (-not (Test-PathUnder 'C:\Runners\win1-old\Runner.Worker.exe' 'C:\Runners\win1')) 'A sibling with the same prefix was matched.'
    Assert (Test-PathUnder 'c:\runners\WIN1\x' 'C:\Runners\win1') 'The comparison is case sensitive.'
    Assert (Test-PathUnder 'C:\Runners\win1' 'C:\Runners\win1\') 'The directory itself, with a trailing separator, was not matched.'

    # --- registration plan -----------------------------------------------------------------------------------------
    $runnerDirectory = 'C:\Runners\win1'
    $url = 'https://github.com/The-Running-Dev'
    $labels = @('subzerodev-windows')
    function New-LocalRegistration($Id = 7, $Name = 'win-a', $Url = $url, $Work = '_work') { [pscustomobject]@{ agentId = $Id; agentName = $Name; gitHubUrl = $Url; workFolder = $Work } }
    function New-RemoteRunner($Id = 7, $Name = 'win-a', $RunnerLabels = @('self-hosted', 'Windows', 'subzerodev-windows'), $Custom = @('subzerodev-windows')) {
        [pscustomobject]@{ Id = $Id; Name = $Name; Status = 'online'; Busy = $false; Labels = $RunnerLabels; CustomLabels = $Custom }
    }
    function Get-TestPlan($Local, $Remote, $LocalRemote = $null, $Name = 'win-a', $Work = '_work', [bool] $Credentials = $true, [switch] $Replace, $WantedLabels = $labels) {
        Get-RegistrationPlan -Local $Local -Remote $Remote -LocalRemote $LocalRemote -Name $Name -GitHubUrl $url -Labels $WantedLabels -WorkFolder $Work -RunnerDirectory $runnerDirectory -HasCredentials $Credentials -Replace:$Replace
    }
    $plan = Get-TestPlan $null $null
    Assert ($plan.Action -eq 'register') "A clone without a registration should register, got $($plan.Action)."
    $plan = Get-TestPlan $null (New-RemoteRunner 99)
    Assert ($plan.Action -eq 'refuse' -and $plan.Refusals[0] -match 'already registered elsewhere') 'Taking another machine''s runner name was not refused.'
    $plan = Get-TestPlan $null (New-RemoteRunner 99) -Replace
    Assert ($plan.Action -eq 'register') '-Replace did not allow taking the name.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner)
    Assert ($plan.Action -eq 'none' -and -not $plan.Reasons) "An unchanged rerun would change the registration: $($plan.Reasons -join '; ')"
    Assert ($plan.LinkedId -eq 7) 'The unchanged rerun lost the registration''s GitHub id.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner) -Name 'win-b' -LocalRemote (New-RemoteRunner)
    Assert ($plan.Action -eq 'reconfigure' -and $plan.Reasons -match 'name changed' -and $plan.RemoveRemote) 'A name change did not reconfigure (and deregister the old runner).'
    $plan = Get-TestPlan (New-LocalRegistration -Url 'https://github.com/Other') (New-RemoteRunner) -LocalRemote (New-RemoteRunner)
    Assert ($plan.Action -eq 'reconfigure' -and $plan.Reasons -match 'target changed') 'A target change did not reconfigure.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner) -Work 'D:\work\win1'
    Assert ($plan.Action -eq 'reconfigure' -and $plan.Reasons -match 'work folder changed') 'A work folder change did not reconfigure.'
    $plan = Get-TestPlan (New-LocalRegistration) $null
    Assert ($plan.Action -eq 'reconfigure' -and $plan.Reasons -match 'no longer has runner id' -and -not $plan.RemoveRemote) 'A runner that GitHub dropped was not re-registered.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner) -Credentials $false
    Assert ($plan.Action -eq 'refuse' -and $plan.Refusals[0] -match 'no \.credentials') 'A registration without credentials was reused.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner 99)
    Assert ($plan.Action -eq 'refuse' -and $plan.Refusals[0] -match 'another machine or clone owns that name') 'A foreign runner with this name was not refused.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner 7 'win-a' @('self-hosted', 'Windows')  @()) -WantedLabels @('subzerodev-windows')
    Assert ($plan.Action -eq 'none' -and $plan.LabelsToAdd -contains 'subzerodev-windows') 'A label added to the configuration did not reach the registration.'
    $plan = Get-TestPlan (New-LocalRegistration) (New-RemoteRunner 7 'win-a' @('self-hosted', 'Windows', 'subzerodev-windows', 'hand-added') @('subzerodev-windows', 'hand-added')) -Name 'win-b' -LocalRemote (New-RemoteRunner 7 'win-a' @('self-hosted', 'Windows', 'subzerodev-windows', 'hand-added') @('subzerodev-windows', 'hand-added'))
    Assert ($plan.PreserveLabels -contains 'hand-added' -and $plan.AllLabels -contains 'hand-added') 'A label added at GitHub was lost across a re-registration.'

    # Drain, stop and recovery-record behavior is covered by tests\Test-LifecycleRecovery.ps1 (a fake GitHub, Docker and process table).

    # --- housekeeping never touches registrations or credentials ---------------------------------------------------
    foreach ($protected in '.runner', '.credentials', '.credentials_rsaparams', 'win01\_recovery\20250101\.runner', 'maintenance.json', 'runners.local.json') {
        Assert (Test-ProtectedRunnerPath (Join-Path 'C:\Runners' $protected)) "$protected is not protected."
    }
    Assert (-not (Test-ProtectedRunnerPath 'C:\Runners\win01\_work\_actions\x')) 'An ordinary cache path is reported as protected.'
    $house = Join-Path $temp 'house'
    New-Item -ItemType Directory -Path $house | Out-Null
    Set-Content (Join-Path $house '.credentials') 'secret'
    Assert-Throws { Remove-PathBounded (Join-Path $house '.credentials') } 'protected runner path' 'Cleanup agreed to delete credentials.'
    Assert (Test-Path -LiteralPath (Join-Path $house '.credentials')) 'The credentials file is gone.'
    $scratch = Join-Path $house 'scratch'
    New-Item -ItemType Directory -Path $scratch | Out-Null
    Set-Content (Join-Path $scratch 'a.txt') 'x'
    Assert (Remove-PathBounded $scratch -Retries 2 -DelaySeconds 0) 'An ordinary folder was not removed.'
    $stream = [IO.File]::Open((Join-Path $house 'locked.txt'), 'Create', 'ReadWrite', 'None')
    try {
        $started = Get-Date
        Assert (-not (Remove-PathBounded (Join-Path $house 'locked.txt') -Retries 3 -DelaySeconds 0.1)) 'A file that is open was reported as removed.'
        Assert (((Get-Date) - $started).TotalSeconds -lt 10) 'The retry loop was not bounded.'
    }
    finally { $stream.Dispose() }

    $runner = Join-Path $temp 'runner'
    New-Item -ItemType Directory -Path (Join-Path $runner '_work\_actions\some-action') -Force | Out-Null
    Set-Content (Join-Path $runner '.runner') '{ "agentName": "win-a", "workFolder": "_work" }'
    Set-Content (Join-Path $runner '.credentials') 'secret'
    Assert ((Clear-RunnerActionCache $runner) -match 'ready') 'The action cache was not cleared.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $runner '_work\_actions')) -and (Test-Path -LiteralPath (Join-Path $runner '.credentials'))) 'Clearing the cache removed the wrong thing.'
    Set-Content (Join-Path $runner '.runner') '{ "agentName": "win-a", "workFolder": ".." }'
    Assert-Throws { Clear-RunnerActionCache $runner } 'contains the runner' 'A work folder that contains the runner was cleaned.'

    $logs = Join-Path $temp 'diag'
    New-Item -ItemType Directory -Path $logs | Out-Null
    foreach ($entry in @(@('Runner_old.log', 500), @('Runner_newer.log', 400), @('Worker_old.log', 450), @('Other_x.log', 450))) {
        $path = Join-Path $logs $entry[0]
        Set-Content $path 'log'
        (Get-Item $path).LastWriteTime = (Get-Date).AddDays(-$entry[1])
    }
    $trim = Invoke-LogTrim @($logs)
    Assert ((Test-Path (Join-Path $logs 'Runner_newer.log')) -and (Test-Path (Join-Path $logs 'Worker_old.log'))) 'The newest log of a kind was removed.'
    Assert (-not (Test-Path (Join-Path $logs 'Runner_old.log')) -and -not (Test-Path (Join-Path $logs 'Other_x.log')) -and $trim.Removed -eq 2) "Old logs were kept: removed $($trim.Removed)."
    $disk = @(Get-FreeDiskReport @($temp))
    Assert ($disk.Count -eq 1 -and $disk[0].FreeGB -gt 0) 'The free-disk report returned nothing for the temp drive.'
    $Config.housekeeping.minFreeGB = 1000000
    Assert (@(Get-FreeDiskReport @($temp))[0].Low) 'A drive below the minimum was not reported low.'

    # --- Linux image ---------------------------------------------------------------------------------------------
    $dockerfile = Get-Content -Raw -LiteralPath (Join-Path $repo 'linux\Dockerfile')
    Assert ($dockerfile -notmatch 'HEALTHCHECK\s+NONE') 'The Dockerfile still disables the health check.'
    Assert ($dockerfile -match 'HEALTHCHECK[^\n]*CMD[^\n]*healthcheck\.sh') 'The Dockerfile has no runner-specific health check.'
    Assert ($dockerfile -match 'RUNNER_SHA256:\?' -and $dockerfile -match 'sha256sum -c') 'The Dockerfile does not verify the runner archive.'
    Assert ($dockerfile -notmatch 'actions-runner-linux-x64-\d') 'The Dockerfile hard-codes a runner version.'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $repo '.dockerignore')) -match 'healthcheck\.sh') '.dockerignore hides the health check from the build context.'
    $newLinux = Get-Content -Raw -LiteralPath (Join-Path $repo 'scripts\New-LinuxRunner.ps1')
    Assert ($newLinux -match 'Test-BuildAgentUpdater' -and $newLinux -match 'RUNNER_SHA256=' -and $newLinux -match 'Enter-RunnerMaintenance') 'New-LinuxRunner.ps1 lost the updater gate, the verified archive or the drain.'
    Assert ($newLinux -notmatch 'update[^\r\n]*latest') 'New-LinuxRunner.ps1 updates to latest.'
    foreach ($file in Get-ChildItem (Join-Path $repo 'scripts') -Filter *.ps1 -File) {
        Assert ((Get-Content -Raw -LiteralPath $file.FullName) -notmatch 'actions-runner-(win|linux)-x64-\d+\.\d+\.\d+') "$($file.Name) hard-codes a runner archive version; runners.json runnerVersion is the only source."
    }
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if ($bash) {
        foreach ($script in 'linux\healthcheck.sh', 'linux\entrypoint.sh', 'scripts\Clear-LinuxWorkspace.sh') {
            $source = (Get-Content -Raw -LiteralPath (Join-Path $repo $script)) -replace "`r`n", "`n"
            $source | & $bash.Source -n
            Assert ($LASTEXITCODE -eq 0) "$script has a shell syntax error."
        }
    }
    else { Write-Host 'bash not found; skipped the shell syntax checks.' }
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $repo 'runners.json')) -notmatch ':latest') 'runners.json refers to a :latest image.'

    Write-Host 'Runner integration checks passed.'
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
