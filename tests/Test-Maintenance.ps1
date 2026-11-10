#Requires -Version 7.2
# Tests for automatic start that keeps maintenance (S3): the Linux entrypoint wait, Manage-WindowsRunner -Action AutoStart,
# and the host manager's AutoStart, Hold, Resume and Startup actions.
#   - a maintenance record holds, whatever it says; a restart of Docker or a sign-in never ends it;
#   - AutoStart waits for Docker, then starts every active Windows slot without ending maintenance;
#   - Hold and Resume are the owner's way in and out; both refuse a slot with an unfinished operation (C4);
#   - an unreadable record is held, and Resume refuses it;
#   - Hold racing Resume, and Hold racing AutoStart, leave one consistent state.
# Every case uses its own LOCALAPPDATA. GitHub and Docker are a fake gh and docker first on PATH; Windows slots are clones
# whose Manage-WindowsRunner.ps1 only logs the action it was asked for.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

. (Join-Path $repo 'scripts\Common.ps1')
. (Join-Path $repo 'scripts\Registration.ps1')
. (Join-Path $repo 'scripts\Lifecycle.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ('szr-maint-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
$originalLocalAppData = $env:LOCALAPPDATA
$originalToken = $env:SZR_HOST_OPERATION
$env:SZR_HOST_OPERATION = $null
$pwshPath = (Get-Process -Id $PID).Path
$url = 'https://github.com/AbsoluteZeroDev'

$cases = [Collections.Generic.List[object]]::new()
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body | Out-Null; $cases.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null }); Write-Host "PASS  $Name" }
    catch { $cases.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }); Write-Host "FAIL  $Name`n        $($_.Exception.Message)" }
    finally {
        while ($global:SubZeroDevHostLock) { Exit-HostLock }
        $env:LOCALAPPDATA = $originalLocalAppData
        $env:SZR_HOST_OPERATION = $null
    }
}
function New-CaseDirectory { $directory = Join-Path $temp ([guid]::NewGuid().ToString('N').Substring(0, 12)); New-Item -ItemType Directory -Path $directory | Out-Null; $directory }
function Write-Raw([string] $Path, [string] $Text) { New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null; [IO.File]::WriteAllText($Path, $Text) }
function ConvertTo-StateJson([string] $Schema, [hashtable] $Value, [int] $Version = 1) {
    $copy = [ordered]@{ schema = $Schema; version = $Version }
    foreach ($key in $Value.Keys) { $copy[$key] = $Value[$key] }
    ConvertTo-Json -InputObject $copy -Depth 20
}

# The fake GitHub keeps world.json: runners [{id, name, status, busy, labels [{name, type}]}]. DELETE .../labels drops the
# custom labels, POST .../labels adds them as custom.
$fakeGh = @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
$path = Join-Path $dir 'world.json'
$world = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
if ($line -match 'actions/runners/(\d+)/labels') {
    $id = [int64]$Matches[1]
    foreach ($runner in @($world.runners)) {
        if ($runner.id -ne $id) { continue }
        if ($line -match '-X DELETE') { $runner.labels = @($runner.labels | Where-Object { $_.type -ne 'custom' }) }
        elseif ($line -match '-X POST') {
            $have = @($runner.labels | ForEach-Object { $_.name })
            foreach ($m in [regex]::Matches($line, 'labels\[\]=(\S+)')) { if ($m.Groups[1].Value -notin $have) { $runner.labels = @($runner.labels) + [pscustomobject]@{ name = $m.Groups[1].Value; type = 'custom' } } }
        }
    }
    $world | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
    exit 0
}
if ($line -match '-X (POST|PUT|PATCH|DELETE)') { exit 0 }
if ($line -match 'actions/runners') { foreach ($r in @($world.runners)) { $r | ConvertTo-Json -Compress -Depth 8 }; exit 0 }
exit 0
'@
# The fake Docker keeps docker.json: unavailable, infoFailures (that many `info` calls fail first), busy (exec pgrep answers
# busy), containers {name: {running}}.
$fakeDocker = @'
$dir = $env:FAKE_GH_DIR
Add-Content -LiteralPath (Join-Path $dir 'docker.log') -Value ($args -join ' ')
$path = Join-Path $dir 'docker.json'
$state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
$save = { $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path }
if ($state.unavailable) { [Console]::Error.WriteLine('error during connect: the Docker daemon is not running (fake)'); exit 1 }
if ($args[0] -eq 'info') {
    if ($state.infoFailures -gt 0) { $state.infoFailures--; & $save; [Console]::Error.WriteLine('daemon not ready (fake)'); exit 1 }
    'fake docker'; exit 0
}
if ($args[0] -eq 'exec') { if ($state.busy) { exit 0 } else { exit 1 } }
$name = $args[-1]
$container = $state.containers.$name
if ($args[0] -eq 'container' -and $args[1] -eq 'inspect') {
    if (-not $container) { [Console]::Error.WriteLine("Error: No such container: $name"); exit 1 }
    if ($args -contains '--format') { if ($container.running) { 'true' } else { 'false' }; exit 0 }
    exit 0
}
if ($args[0] -eq 'stop' -or $args[0] -eq 'start') {
    if (-not $container) { [Console]::Error.WriteLine("Error: No such container: $name"); exit 1 }
    if ($state.failStop -and $args[0] -eq 'stop') { [Console]::Error.WriteLine('stop refused (fake)'); exit 1 }
    $container.running = ($args[0] -eq 'start')
    & $save
    exit 0
}
[Console]::Error.WriteLine("fake docker: unexpected call $($args -join ' ')")
exit 1
'@
# A Windows slot's own Manage-WindowsRunner.ps1: records the action it was asked for, with start and end markers.
$fakeWindowsScript = @'
param([string] $Action)
$log = Join-Path (Split-Path $PSScriptRoot -Parent) 'actions.log'
Add-Content -LiteralPath $log -Value "begin $Action"
Start-Sleep -Milliseconds 600
Add-Content -LiteralPath $log -Value "end $Action"
Write-Output "fake $Action done"
exit 0
'@

function Set-World($Fixture, $World) { $World | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'world.json') }
function Set-Docker($Fixture, $State) { $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'docker.json') }
function Get-Docker($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'docker.json') | ConvertFrom-Json }
function Get-World($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'world.json') | ConvertFrom-Json }
function Get-Log($Fixture, [string] $Log = 'docker.log') { @(Get-Content -LiteralPath (Join-Path $Fixture.GhState $Log) -ErrorAction SilentlyContinue) }
function Get-CustomLabels($Fixture, [string] $Name) { @((Get-World $Fixture).runners | Where-Object name -EQ $Name | ForEach-Object { $_.labels } | Where-Object { $_.type -eq 'custom' } | ForEach-Object name) }

function New-Fixture([hashtable] $Local = @{}) {
    $clone = New-CaseDirectory
    Copy-Item (Join-Path $repo 'runners.json') $clone
    Copy-Item (Join-Path $repo 'scripts') (Join-Path $clone 'scripts') -Recurse
    $shim = Join-Path $clone 'shim'; $ghState = Join-Path $clone 'gh'; $localAppData = Join-Path $clone 'LocalAppData'
    New-Item -ItemType Directory -Path $shim, $ghState, $localAppData | Out-Null
    Set-Content -LiteralPath (Join-Path $shim 'gh.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-gh.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'docker.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-docker.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'fake-gh.ps1') -Value $fakeGh
    Set-Content -LiteralPath (Join-Path $shim 'fake-docker.ps1') -Value $fakeDocker
    $settings = [ordered]@{
        hostId = 'testhost'; github = [ordered]@{ url = $url }
        buildAgent = [ordered]@{ docker = [ordered]@{ cli = (Join-Path $shim 'docker.cmd'); readyTimeoutSeconds = 20 } }
        linux = [ordered]@{ count = 1 }; windows = [ordered]@{ count = 1 }
        lifecycle = [ordered]@{ drainTimeoutMinutes = 1; pollSeconds = 1 }
    }
    foreach ($key in $Local.Keys) { $settings[$key] = $Local[$key] }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $fixture = [pscustomobject]@{
        Clone = $clone; Shim = $shim; GhState = $ghState; LocalAppData = $localAppData
        State = (Join-Path $localAppData 'SubZeroDev\Runners\host'); Linux = (Join-Path $clone 'linux\runner-02')
        Windows = (Join-Path $localAppData 'SubZeroDev\Runners\win01\windows')
    }
    New-Item -ItemType Directory -Path $fixture.State, $fixture.Linux, $fixture.Windows -Force | Out-Null
    # One Linux slot (a runner and its sidecar, both running) whose runner has the custom label subzerodev-linux, and one Windows slot.
    foreach ($entry in @(@($fixture.Linux, 9, 'subzerodev.runner.linux.testhost.02'), @($fixture.Windows, 30, 'subzerodev.runner.windows.testhost.win01'))) {
        [ordered]@{ agentId = $entry[1]; agentName = $entry[2]; gitHubUrl = $url; workFolder = '_work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $entry[0] '.runner')
    }
    $windowsScripts = Join-Path $fixture.Windows '..\scripts'
    New-Item -ItemType Directory -Path $windowsScripts -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $windowsScripts 'Manage-WindowsRunner.ps1') -Value $fakeWindowsScript
    $fixture | Add-Member -NotePropertyName WindowsClone -NotePropertyValue (Join-Path $localAppData 'SubZeroDev\Runners\win01')
    $slots = @(
        [ordered]@{ slotId = 'linux-02'; platform = 'linux'; state = 'active'; legacy = $false; runnerName = 'subzerodev.runner.linux.testhost.02'; runnerId = 9; scope = 'orgs/AbsoluteZeroDev'
            registrationDirectory = $fixture.Linux
            containers = @([ordered]@{ role = 'runner'; name = 'szr-runner-02'; id = 'a' * 64 }, [ordered]@{ role = 'docker'; name = 'szr-docker-02'; id = 'b' * 64 }) }
        [ordered]@{ slotId = 'win01'; platform = 'windows'; state = 'active'; legacy = $false; runnerName = 'subzerodev.runner.windows.testhost.win01'; runnerId = 30; scope = 'orgs/AbsoluteZeroDev'
            registrationDirectory = $fixture.Windows; installPath = $fixture.WindowsClone }
    )
    Write-Raw (Join-Path $fixture.State 'inventory.json') (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = $slots })
    Set-World $fixture @{ runners = @(
            @{ id = 9; name = 'subzerodev.runner.linux.testhost.02'; status = 'online'; busy = $false; labels = @(@{ name = 'self-hosted'; type = 'read-only' }, @{ name = 'subzerodev-linux'; type = 'custom' }) }
            @{ id = 30; name = 'subzerodev.runner.windows.testhost.win01'; status = 'online'; busy = $false; labels = @(@{ name = 'self-hosted'; type = 'read-only' }) }) }
    Set-Docker $fixture @{ unavailable = $false; infoFailures = 0; busy = $false; failStop = $false; containers = @{ 'szr-runner-02' = @{ running = $true }; 'szr-docker-02' = @{ running = $true } } }
    $fixture
}
function Use-Fixture($Fixture, [scriptblock] $Body) {
    $old = @{ PATH = $env:PATH; FAKE_GH_DIR = $env:FAKE_GH_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; SZR_STARTUP_DIRECTORY = $env:SZR_STARTUP_DIRECTORY }
    try {
        $env:PATH = "$($Fixture.Shim);$($old.PATH)"; $env:FAKE_GH_DIR = $Fixture.GhState; $env:LOCALAPPDATA = $Fixture.LocalAppData
        & $Body
    } finally { $env:PATH = $old.PATH; $env:FAKE_GH_DIR = $old.FAKE_GH_DIR; $env:LOCALAPPDATA = $old.LOCALAPPDATA; $env:SZR_STARTUP_DIRECTORY = $old.SZR_STARTUP_DIRECTORY }
}
function Invoke-Manager($Fixture, [string[]] $Arguments) {
    Use-Fixture $Fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone 'scripts\Manage-RunnerHost.ps1') @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
function Start-Manager($Fixture, [string[]] $Arguments) {
    $stdout = Join-Path $Fixture.Clone ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    Use-Fixture $Fixture {
        $process = Start-Process -FilePath $pwshPath -ArgumentList "-NoLogo -NoProfile -File `"$(Join-Path $Fixture.Clone 'scripts\Manage-RunnerHost.ps1')`" $($Arguments -join ' ')" -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err" -PassThru -WindowStyle Hidden
        [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = "$stdout.err" }
    }
}
function Wait-Child($Child, [int] $Seconds = 120) {
    if (-not $Child.Process.WaitForExit($Seconds * 1000)) { Stop-Process -Id $Child.Process.Id -Force -ErrorAction SilentlyContinue; throw "A child did not finish within $Seconds seconds." }
    (@((Get-Content -Raw -LiteralPath $Child.Stdout -ErrorAction SilentlyContinue), (Get-Content -Raw -LiteralPath $Child.Stderr -ErrorAction SilentlyContinue)) | Where-Object { $_ }) -join "`n"
}
function Get-Record($Fixture) { Join-Path $Fixture.Linux 'maintenance.json' }
function Write-Operation($Fixture) {
    Write-Raw (Join-Path $Fixture.State 'operation.json') (ConvertTo-StateJson $HostOperationSchema @{ id = 'op-1'; kind = 'repair'; slotId = 'linux-02'; startedUtc = '2026-11-10T00:00:00.0000000Z'; steps = @(@{ name = 'stop'; state = 'pending' }) })
}

# --- the entrypoint ---------------------------------------------------------------------------------------------------

Test-Case 'The Linux entrypoint waits for maintenance.json to be gone before it starts the listener, and any record holds' {
    $text = [IO.File]::ReadAllText((Join-Path $repo 'linux\entrypoint.sh'))
    $test = $text.IndexOf('if [ -e /runner/maintenance.json ]')
    $wait = $text.IndexOf('while [ -e /runner/maintenance.json ]')
    $run = $text.LastIndexOf('exec /runner/run.sh')
    Assert ($test -ge 0 -and $wait -gt $test -and $run -gt $wait) 'The wait on /runner/maintenance.json does not come before the final exec of run.sh.'
    Assert ($text -notmatch 'cat /runner/maintenance.json|jq|grep.*maintenance') 'The entrypoint reads the record instead of holding on its existence.'
    # Syntax check where a POSIX bash can read the file (Git Bash or Linux); a WSL launcher cannot, so it is skipped there.
    $bash = @('C:\Program Files\Git\bin\bash.exe', '/bin/bash', '/usr/bin/bash') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($bash) {
        $out = & $bash -n ((Join-Path $repo 'linux/entrypoint.sh') -replace '\\', '/') 2>&1
        Assert ($LASTEXITCODE -eq 0) "entrypoint.sh does not parse: $out"
    }
}

# --- Manage-WindowsRunner -Action AutoStart -----------------------------------------------------------------------------

Test-Case 'Start-WindowsRunner -KeepMaintenance leaves the record; without it maintenance ends (Start still ends maintenance)' {
    $script:exits = 0
    $script:Config = $Config
    $saved = @{}
    foreach ($name in 'Exit-RunnerMaintenance', 'Get-SupervisorProcess', 'Wait-SupervisorInitialized') { $saved[$name] = (Get-Item "function:$name").ScriptBlock }
    Set-Item -Path function:script:Exit-RunnerMaintenance -Value { param($StateFile, $RunnerDirectory) $script:exits++; $true }
    Set-Item -Path function:script:Get-SupervisorProcess -Value { [pscustomobject]@{ ProcessId = 4242 } }
    Set-Item -Path function:script:Wait-SupervisorInitialized -Value { [pscustomobject]@{ State = 'maintenance'; ProcessId = 4242; Adopted = $false } }
    try {
        $answer = Start-WindowsRunner -KeepMaintenance
        Assert ($script:exits -eq 0) 'AutoStart ended maintenance.'
        Assert ($answer -match 'already running.*in maintenance, no listener until maintenance ends') "AutoStart answered: $answer"
        Start-WindowsRunner | Out-Null
        Assert ($script:exits -eq 1) 'Start did not end maintenance.'
    } finally { foreach ($name in $saved.Keys) { Set-Item -Path "function:script:$name" -Value $saved[$name] } }
    $source = [IO.File]::ReadAllText((Join-Path $repo 'scripts\Manage-WindowsRunner.ps1'))
    Assert ($source -match "'AutoStart'\s*\{\s*try \{ Write-Output \(Start-WindowsRunner -KeepMaintenance\)") 'Manage-WindowsRunner.ps1 AutoStart does not call Start-WindowsRunner -KeepMaintenance.'
    Assert ($source -match "\[ValidateSet\([^)]*'AutoStart'") 'AutoStart is not an accepted action.'
}

# --- host AutoStart ---------------------------------------------------------------------------------------------------

Test-Case 'AutoStart waits for docker info, then starts the active Windows slots only (and none when the inventory is absent)' {
    $fixture = New-Fixture
    Set-Docker $fixture @{ unavailable = $false; infoFailures = 2; busy = $false; failStop = $false; containers = @{ 'szr-runner-02' = @{ running = $true }; 'szr-docker-02' = @{ running = $true } } }
    $run = Invoke-Manager $fixture @('-Action', 'AutoStart')
    Assert ($run.ExitCode -eq 0) "AutoStart exited $($run.ExitCode).`n$($run.Output)"
    Assert ($run.Output -match 'win01: fake AutoStart done') "No Windows slot was started.`n$($run.Output)"
    $infos = @(Get-Log $fixture | Where-Object { $_ -eq 'info' })
    Assert ($infos.Count -eq 3) "docker info was called $($infos.Count) times, not 3 (two failures, then ready)."
    $actions = @(Get-Content -LiteralPath (Join-Path $fixture.WindowsClone 'actions.log'))
    Assert (($actions -join ',') -eq 'begin AutoStart,end AutoStart') "The Windows slot saw: $($actions -join ',')."
    Assert (-not (Test-Path -LiteralPath (Get-Record $fixture))) 'AutoStart touched the Linux slot.'
    Assert (-not (Get-Log $fixture | Where-Object { $_ -match '^(start|stop) ' })) 'AutoStart started or stopped a Linux container.'

    Remove-Item -LiteralPath (Join-Path $fixture.State 'inventory.json')
    Remove-Item -LiteralPath (Join-Path $fixture.WindowsClone 'actions.log')
    $none = Invoke-Manager $fixture @('-Action', 'AutoStart')
    Assert ($none.ExitCode -eq 0 -and $none.Output -match 'No host inventory') "AutoStart without an inventory: exit $($none.ExitCode).`n$($none.Output)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.WindowsClone 'actions.log'))) 'AutoStart started a slot without an inventory.'
}

Test-Case 'AutoStart does not wait on Docker that is not installed, and reports a slot that fails to start' {
    $fixture = New-Fixture
    Remove-Item -LiteralPath (Join-Path $fixture.Shim 'docker.cmd')
    $worker = Join-Path $fixture.WindowsClone 'scripts\Manage-WindowsRunner.ps1'
    Set-Content -LiteralPath $worker -Value @('param([string] $Action)', '[Console]::Error.WriteLine("cannot start"); exit 1')
    $run = Invoke-Manager $fixture @('-Action', 'AutoStart')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'win01: AutoStart failed \(exit 1\)') "A failed slot did not fail AutoStart (exit $($run.ExitCode)).`n$($run.Output)"
}

Test-Case 'AutoStart over an unreadable inventory refuses' {
    $fixture = New-Fixture
    Write-Raw (Join-Path $fixture.State 'inventory.json') '{ broken'
    $run = Invoke-Manager $fixture @('-Action', 'AutoStart')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'AutoStart refused: the host inventory .* cannot be read') "AutoStart on an unreadable inventory: exit $($run.ExitCode).`n$($run.Output)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.WindowsClone 'actions.log'))) 'AutoStart started a slot on an unreadable inventory.'
}

# --- Hold and Resume ---------------------------------------------------------------------------------------------------

Test-Case 'Hold keeps a record and stops the containers; a Docker restart or AutoStart leaves it; Resume restores labels and starts one listener' {
    $fixture = New-Fixture
    $hold = Invoke-Manager $fixture @('-Action', 'Hold', '-Slot', 'linux-02')
    Assert ($hold.ExitCode -eq 0 -and $hold.Output -match 'linux-02: held') "Hold exited $($hold.ExitCode).`n$($hold.Output)"
    $record = Get-Content -Raw -LiteralPath (Get-Record $fixture) | ConvertFrom-Json
    Assert ($record.phase -eq 'held' -and $record.reason -eq 'hold' -and 'subzerodev-linux' -in @($record.savedLabels)) "The record is $($record | ConvertTo-Json -Compress)."
    Assert (-not (Get-CustomLabels $fixture 'subzerodev.runner.linux.testhost.02')) 'Hold left custom labels on the runner.'
    $docker = Get-Docker $fixture
    Assert (-not $docker.containers.'szr-runner-02'.running -and -not $docker.containers.'szr-docker-02'.running) 'Hold left a container running.'
    $stops = @(Get-Log $fixture | Where-Object { $_ -match '^stop ' })
    Assert ($stops.Count -eq 2 -and $stops[0] -match 'szr-runner-02$' -and $stops[1] -match 'szr-docker-02$') "Containers stopped in this order: $($stops -join ' | ')."

    # hold -> Docker restart -> the container comes back and its entrypoint finds the record: nothing runs run.sh.
    $docker.containers.'szr-runner-02'.running = $true; $docker.containers.'szr-docker-02'.running = $true
    Set-Docker $fixture $docker
    $text = [IO.File]::ReadAllText((Join-Path $repo 'linux\entrypoint.sh'))
    Assert (Test-Path -LiteralPath (Get-Record $fixture)) 'The record vanished when Docker restarted.'
    Assert ($text.IndexOf('while [ -e /runner/maintenance.json ]') -lt $text.LastIndexOf('exec /runner/run.sh')) 'The entrypoint does not wait on the record.'

    # hold -> sign-in AutoStart -> still held, no Linux call.
    $auto = Invoke-Manager $fixture @('-Action', 'AutoStart')
    Assert ($auto.ExitCode -eq 0 -and (Test-Path -LiteralPath (Get-Record $fixture))) "AutoStart changed the hold (exit $($auto.ExitCode)).`n$($auto.Output)"

    Remove-Item -LiteralPath (Join-Path $fixture.GhState 'docker.log')
    $docker.containers.'szr-runner-02'.running = $false; $docker.containers.'szr-docker-02'.running = $false
    Set-Docker $fixture $docker
    $resume = Invoke-Manager $fixture @('-Action', 'Resume', '-Slot', 'linux-02')
    Assert ($resume.ExitCode -eq 0 -and $resume.Output -match 'linux-02: resumed') "Resume exited $($resume.ExitCode).`n$($resume.Output)"
    Assert (-not (Test-Path -LiteralPath (Get-Record $fixture))) 'Resume left the record.'
    Assert ('subzerodev-linux' -in (Get-CustomLabels $fixture 'subzerodev.runner.linux.testhost.02')) 'Resume did not restore the custom label.'
    $starts = @(Get-Log $fixture | Where-Object { $_ -match '^start ' })
    Assert ($starts.Count -eq 2 -and $starts[0] -match 'szr-docker-02$' -and $starts[1] -match 'szr-runner-02$') "Containers started in this order: $($starts -join ' | ') (the sidecar first, once each: one listener)."
    $again = Invoke-Manager $fixture @('-Action', 'Resume', '-Slot', 'linux-02')
    Assert ($again.ExitCode -eq 0 -and $again.Output -match 'not held; nothing to resume') "A second Resume: exit $($again.ExitCode).`n$($again.Output)"
    Assert ((@(Get-Log $fixture | Where-Object { $_ -match '^start ' })).Count -eq 2) 'A second Resume started a container again.'
}

Test-Case 'Hold waits for a running job: nothing is stopped while it runs, and Hold completes once it ends' {
    $fixture = New-Fixture
    $docker = Get-Docker $fixture; $docker.busy = $true; Set-Docker $fixture $docker
    $child = Start-Manager $fixture @('-Action', 'Hold', '-Slot', 'linux-02')
    Start-Sleep -Seconds 5
    Assert (-not $child.Process.HasExited) 'Hold finished while a job was running.'
    Assert (-not (Get-Log $fixture | Where-Object { $_ -match '^stop ' })) 'A container was stopped under a running job.'
    $docker = Get-Docker $fixture; $docker.busy = $false; Set-Docker $fixture $docker
    $text = Wait-Child $child
    Assert ($child.Process.ExitCode -eq 0 -and $text -match 'linux-02: held') "Hold exited $($child.Process.ExitCode).`n$text"
    Assert ((Get-Content -Raw -LiteralPath (Get-Record $fixture) | ConvertFrom-Json).phase -eq 'held') 'No held record after the job ended.'
}

Test-Case 'A container that does not stop keeps the record (stop-failed) and fails Hold' {
    $fixture = New-Fixture
    $docker = Get-Docker $fixture; $docker.failStop = $true; Set-Docker $fixture $docker
    $run = Invoke-Manager $fixture @('-Action', 'Hold', '-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Hold stopped short for linux-02') "A failed stop did not fail Hold (exit $($run.ExitCode)).`n$($run.Output)"
    $record = Get-Content -Raw -LiteralPath (Get-Record $fixture) | ConvertFrom-Json
    Assert ($record.phase -eq 'stop-failed') "The record phase is $($record.phase)."
}

Test-Case 'Hold and Resume refuse a slot with an unfinished operation (C4), naming it and pointing to Apply' {
    $fixture = New-Fixture
    Write-Operation $fixture
    foreach ($verb in 'Hold', 'Resume') {
        $run = Invoke-Manager $fixture @('-Action', $verb, '-Slot', 'linux-02')
        Assert ($run.ExitCode -eq 1 -and $run.Output -match "$verb refused: the unfinished operation repair \(op-1\) on linux-02, started .*, next step stop.*Finish it with Apply first") "$verb with an unfinished operation: exit $($run.ExitCode).`n$($run.Output)"
    }
    Assert (-not (Test-Path -LiteralPath (Get-Record $fixture)) -and -not (Get-Log $fixture | Where-Object { $_ -match '^(stop|start) ' })) 'A refused Hold or Resume changed something.'
    Write-Raw (Join-Path $fixture.State 'operation.json') 'garbage'
    $run = Invoke-Manager $fixture @('-Action', 'Hold', '-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'operation journal .* cannot be read') "Hold with an unreadable journal: exit $($run.ExitCode).`n$($run.Output)"
}

Test-Case 'Hold and Resume refuse a missing slot, no -Slot, and an unreadable or absent inventory' {
    $fixture = New-Fixture
    $run = Invoke-Manager $fixture @('-Action', 'Hold')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Hold needs -Slot') "Hold without -Slot: exit $($run.ExitCode).`n$($run.Output)"
    $run = Invoke-Manager $fixture @('-Action', 'Resume', '-Slot', 'linux-09')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match "inventory has no slot 'linux-09'") "An unknown slot: exit $($run.ExitCode).`n$($run.Output)"
    Write-Raw (Join-Path $fixture.State 'inventory.json') '{ broken'
    $run = Invoke-Manager $fixture @('-Action', 'Hold', '-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Hold refused: the host inventory .* cannot be read') "Hold on an unreadable inventory: exit $($run.ExitCode).`n$($run.Output)"
}

Test-Case 'An unreadable record is held: Resume refuses with the existing message and starts nothing' {
    $fixture = New-Fixture
    Write-Raw (Get-Record $fixture) '{ truncated'
    $docker = Get-Docker $fixture; $docker.containers.'szr-runner-02'.running = $false; $docker.containers.'szr-docker-02'.running = $false; Set-Docker $fixture $docker
    $run = Invoke-Manager $fixture @('-Action', 'Resume', '-Slot', 'linux-02')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'maintenance record .* cannot be read .*so the withdrawn labels are unknown and it was kept') "Resume over an unreadable record: exit $($run.ExitCode).`n$($run.Output)"
    Assert ([IO.File]::ReadAllText((Get-Record $fixture)) -eq '{ truncated') 'The unreadable record was changed.'
    Assert (-not (Get-Log $fixture | Where-Object { $_ -match '^start ' })) 'A container was started under an unreadable record.'
}

Test-Case 'Hold and Resume of a Windows slot go through its own Manage-WindowsRunner (Maintenance, then Start)' {
    $fixture = New-Fixture
    $hold = Invoke-Manager $fixture @('-Action', 'Hold', '-Slot', 'win01')
    $resume = Invoke-Manager $fixture @('-Action', 'Resume', '-Slot', 'win01')
    Assert ($hold.ExitCode -eq 0 -and $resume.ExitCode -eq 0) "Hold exited $($hold.ExitCode), Resume $($resume.ExitCode).`n$($hold.Output)`n$($resume.Output)"
    $actions = @(Get-Content -LiteralPath (Join-Path $fixture.WindowsClone 'actions.log') | Where-Object { $_ -like 'begin*' })
    Assert (($actions -join ',') -eq 'begin Maintenance,begin Start') "The Windows slot saw: $($actions -join ',')."
}

# --- races -------------------------------------------------------------------------------------------------------------

Test-Case 'Hold racing Resume on one slot ends in one consistent state, never a mix' {
    $fixture = New-Fixture
    $holdFirst = Start-Manager $fixture @('-Action', 'Hold', '-Slot', 'linux-02')
    $resume = Start-Manager $fixture @('-Action', 'Resume', '-Slot', 'linux-02')
    $a = Wait-Child $holdFirst; $b = Wait-Child $resume
    Assert ($holdFirst.Process.ExitCode -eq 0 -and $resume.Process.ExitCode -eq 0) "Hold exited $($holdFirst.Process.ExitCode), Resume $($resume.Process.ExitCode).`n$a`n$b"
    $docker = Get-Docker $fixture
    $held = Test-Path -LiteralPath (Get-Record $fixture)
    $running = [bool]$docker.containers.'szr-runner-02'.running
    $labels = @(Get-CustomLabels $fixture 'subzerodev.runner.linux.testhost.02')
    if ($held) { Assert (-not $running -and -not $labels) "Held, but the runner runs ($running) or has labels ($($labels -join ','))." }
    else { Assert ($running -and 'subzerodev-linux' -in $labels) "Not held, but the runner is stopped ($running) or has no label ($($labels -join ','))." }
}

Test-Case 'Hold racing AutoStart: when Hold returns the Windows slot is held and no AutoStart overlaps its Maintenance' {
    $fixture = New-Fixture
    $auto = Start-Manager $fixture @('-Action', 'AutoStart')
    $hold = Start-Manager $fixture @('-Action', 'Hold', '-Slot', 'win01')
    $a = Wait-Child $auto; $h = Wait-Child $hold
    Assert ($auto.Process.ExitCode -eq 0 -and $hold.Process.ExitCode -eq 0) "AutoStart exited $($auto.Process.ExitCode), Hold $($hold.Process.ExitCode).`n$a`n$h"
    $log = @(Get-Content -LiteralPath (Join-Path $fixture.WindowsClone 'actions.log'))
    $pairs = ($log -join ',')
    Assert ($pairs -in 'begin AutoStart,end AutoStart,begin Maintenance,end Maintenance', 'begin Maintenance,end Maintenance,begin AutoStart,end AutoStart') "The Windows slot saw overlapping or missing calls: $pairs."
}

# --- the sign-in entry --------------------------------------------------------------------------------------------------

Test-Case 'windows.startAtSignIn writes a per-user Startup entry that runs host AutoStart, and turning it off removes it' {
    $fixture = New-Fixture @{ windows = @{ count = 1; startAtSignIn = $true } }
    $startup = Join-Path $fixture.Clone 'Startup'
    New-Item -ItemType Directory -Path $startup | Out-Null
    $entry = Join-Path $startup 'SubZeroDev Runners AutoStart.cmd'
    $env:SZR_STARTUP_DIRECTORY = $startup
    Use-Fixture $fixture { $env:SZR_STARTUP_DIRECTORY = $startup }
    $run = Use-Fixture $fixture { $env:SZR_STARTUP_DIRECTORY = $startup; $o = & $pwshPath -NoLogo -NoProfile -File (Join-Path $fixture.Clone 'scripts\Manage-RunnerHost.ps1') -Action Startup 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($o -join "`n") } }
    Assert ($run.ExitCode -eq 0 -and (Test-Path -LiteralPath $entry)) "Startup exited $($run.ExitCode) and wrote no entry.`n$($run.Output)"
    $text = [IO.File]::ReadAllText($entry)
    Assert ($text -match 'Manage-RunnerHost\.ps1" -Action AutoStart' -and $text -match 'pwsh\.exe -NoProfile') "The entry is: $text"
    Assert ($text -notmatch 'schtasks|Register-ScheduledTask|sc\.exe') 'The entry uses a task or a service.'
    $settings = Get-Content -Raw -LiteralPath (Join-Path $fixture.Clone 'runners.local.json') | ConvertFrom-Json
    $settings.windows.startAtSignIn = $false
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixture.Clone 'runners.local.json')
    $off = Use-Fixture $fixture { $env:SZR_STARTUP_DIRECTORY = $startup; $o = & $pwshPath -NoLogo -NoProfile -File (Join-Path $fixture.Clone 'scripts\Manage-RunnerHost.ps1') -Action Startup 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($o -join "`n") } }
    Assert ($off.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $entry)) "Turning it off left the entry (exit $($off.ExitCode)).`n$($off.Output)"
    $env:SZR_STARTUP_DIRECTORY = $null
}

# --- result -------------------------------------------------------------------------------------------------------------

$env:SZR_HOST_OPERATION = $originalToken
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host "`n$($cases.Count - $failed.Count) of $($cases.Count) passed."
Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
if ($failed.Count) { exit 1 }
