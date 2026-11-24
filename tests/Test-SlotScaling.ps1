#Requires -Version 7.2
# Tests for adding and retiring slots (S6): Manage-RunnerHost -Action Apply adds the slots the settings want and, with
# -Retire, retires the ones they no longer want, each as a journaled operation.
#   - Scale: slots are added with their own names, network, volumes and registration; numbers are never reused;
#   - Ownership: a container at a new slot's name that is not this host's compose slot is refused before anything changes;
#   - Unknown is not absent: a name Docker cannot answer for is refused, not taken as free;
#   - a run killed in any add or retire step is finished by rerunning Apply; a failed verify keeps the journal;
#   - retire needs -Retire, drains, stops, deregisters, clears the registration and removes the containers; Prune removes
#     what it left on disk; add blockers and a changed plan refuse before anything changes;
#   - Concurrency: a second Apply waits for the first and does not repeat its work.
# Every case uses its own LOCALAPPDATA. GitHub and Docker are a fake gh and docker first on PATH.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

. (Join-Path $repo 'scripts\Common.ps1')
. (Join-Path $repo 'scripts\Registration.ps1')
. (Join-Path $repo 'scripts\Lifecycle.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ('szr-slots-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
$originalLocalAppData = $env:LOCALAPPDATA
$env:SZR_HOST_OPERATION = $null
$pwshPath = (Get-Process -Id $PID).Path
$url = 'https://github.com/AbsoluteZeroDev'
$imageId = 'sha256:' + ('e' * 64)
function Get-RunnerContainerName([int] $N) { '{0}-{1:00}' -f $Config.linux.container, $N }
function Get-SidecarName([int] $N) { '{0}-{1:00}' -f $Config.linux.docker.container, $N }
function Get-LinuxRunnerName([int] $N) { 'subzerodev.runner.linux.testhost.{0:00}' -f $N }

$cases = [Collections.Generic.List[object]]::new()
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body | Out-Null; $cases.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null }); Write-Host "PASS  $Name" }
    catch { $cases.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }); Write-Host "FAIL  $Name`n        $($_.Exception.Message)" }
    finally { $env:LOCALAPPDATA = $originalLocalAppData; $env:SZR_HOST_OPERATION = $null }
}
function New-CaseDirectory { $directory = Join-Path $temp ([guid]::NewGuid().ToString('N').Substring(0, 12)); New-Item -ItemType Directory -Path $directory | Out-Null; $directory }
function Write-Raw([string] $Path, [string] $Text) { New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null; [IO.File]::WriteAllText($Path, $Text) }
function ConvertTo-StateJson([string] $Schema, [hashtable] $Value, [int] $Version = 1) {
    $copy = [ordered]@{ schema = $Schema; version = $Version }
    foreach ($key in $Value.Keys) { $copy[$key] = $Value[$key] }
    ConvertTo-Json -InputObject $copy -Depth 20
}

# Both fakes honour kill.json {pattern, skip}: the matching call (after skipping that many) kills the command that made it.
$killHelper = @'
function Invoke-FakeKill([string] $Dir, [string] $Line) {
    $killPath = Join-Path $Dir 'kill.json'
    if (-not (Test-Path -LiteralPath $killPath)) { return }
    $kill = Get-Content -Raw -LiteralPath $killPath | ConvertFrom-Json
    if ($Line -notmatch $kill.pattern) { return }
    if ($kill.skip -gt 0) { $kill.skip--; $kill | ConvertTo-Json | Set-Content -LiteralPath $killPath; return }
    Remove-Item -LiteralPath $killPath -Force
    $parent = (Get-Process -Id $PID).Parent
    while ($parent -and $parent.ProcessName -ne 'pwsh') { $parent = $parent.Parent }
    Add-Content -LiteralPath (Join-Path $Dir 'killed.log') -Value "$($parent.Id) $Line"
    if ($parent) { Stop-Process -Id $parent.Id -Force }
    exit 1
}
'@
# The fake GitHub keeps world.json: runners [{id, name, status, busy, labels [{name, type}]}], groups (runner groups),
# deleteNotFound (deleting a runner answers 404), registerOffline (runners registered from now on report offline).
$fakeGh = $killHelper + @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
Invoke-FakeKill $dir $line
$path = Join-Path $dir 'world.json'
$world = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
if ($line -match '-X POST .*registration-token') { 'faketoken'; exit 0 }
if ($line -match '-X DELETE .*actions/runners/(\d+)$') {
    if ($world.deleteNotFound) { [Console]::Error.WriteLine('HTTP 404: Not Found'); exit 1 }
    $id = [int64]$Matches[1]
    $world.runners = @($world.runners | Where-Object { [int64]$_.id -ne $id })
    $world | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
    exit 0
}
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
if ($line -match 'actions/runner-groups$|actions/runner-groups ') { foreach ($g in @($world.groups)) { $g | ConvertTo-Json -Compress -Depth 8 }; exit 0 }
if ($line -match 'actions/runners') { foreach ($r in @($world.runners)) { $r | ConvertTo-Json -Compress -Depth 8 }; exit 0 }
exit 0
'@
# The fake Docker keeps docker.json: containers [{id, name, image, running, restart, labels}], images {ref: id}, networks,
# volumes, busy (exec pgrep answers busy), failOn (regexes whose calls fail), unknownFor (refs whose inspect cannot be
# answered). docker run (the runner's configure) writes .runner into the bound directory and registers the runner with
# the fake GitHub.
$fakeDocker = $killHelper + @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'docker.log') -Value $line
Invoke-FakeKill $dir $line
$path = Join-Path $dir 'docker.json'
$state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
foreach ($pattern in @($state.failOn)) { if ($pattern -and $line -match $pattern) { [Console]::Error.WriteLine("fake docker: failing $line"); exit 1 } }
function Find-Container([string] $Ref) { @($state.containers | Where-Object { $_.id -eq $Ref -or $_.name -eq $Ref }) | Select-Object -First 1 }
function Save-State { $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path }
function Write-Missing([string] $Ref) { [Console]::Error.WriteLine("Error response from daemon: No such container: $Ref"); exit 1 }
function Get-Value([string] $Flag) { $i = [array]::IndexOf($args, $Flag); if ($i -ge 0) { $args[$i + 1] } }
switch ($args[0]) {
    'info' { 'fake docker'; exit 0 }
    'image' {
        $ref = $args[-1]
        $id = $state.images.$ref
        if (-not $id) { [Console]::Error.WriteLine("Error response from daemon: No such image: $ref"); exit 1 }
        $id; exit 0
    }
    'run' {
        $mount = $args[[array]::IndexOf($args, '--mount') + 1]
        $target = ($mount -split ',' | Where-Object { $_ -like 'source=*' }) -replace '^source=', ''
        $name = $args[[array]::IndexOf($args, '--name') + 1]
        $labels = $args[[array]::IndexOf($args, '--labels') + 1] -split ','
        $gitHubUrl = $args[[array]::IndexOf($args, '--url') + 1]
        $worldPath = Join-Path $dir 'world.json'
        $world = Get-Content -Raw -LiteralPath $worldPath | ConvertFrom-Json
        $ids = @($world.runners | ForEach-Object { [int64]$_.id }) + 100
        $id = ($ids | Measure-Object -Maximum).Maximum + 1
        $world.runners = @(@($world.runners | Where-Object { $_.name -ne $name }) + [pscustomobject]@{
                id = $id; name = $name; status = $(if ($world.registerOffline) { 'offline' } else { 'online' }); busy = $false
                labels = @(@([pscustomobject]@{ name = 'self-hosted'; type = 'read-only' }) + @($labels | ForEach-Object { [pscustomobject]@{ name = $_; type = 'custom' } }))
            })
        $world | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $worldPath
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        [ordered]@{ agentId = $id; agentName = $name; gitHubUrl = $gitHubUrl; workFolder = '/tmp/runner-work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.runner')
        'Runner successfully added'; exit 0
    }
    'container' {
        $ref = $args[-1]
        if ($ref -in @($state.unknownFor)) { [Console]::Error.WriteLine('error during connect: the daemon did not answer (fake)'); exit 1 }
        $c = Find-Container $ref
        if (-not $c) { Write-Missing $ref }
        if ($args -contains '--format') { if ($c.running) { 'true' } else { 'false' }; exit 0 }
        ConvertTo-Json -Depth 6 -InputObject @([ordered]@{ Id = $c.id; Name = "/$($c.name)"; Image = $c.image; Config = @{ Labels = $c.labels }; State = @{ Running = [bool]$c.running }; HostConfig = @{ RestartPolicy = @{ Name = $c.restart } } })
        exit 0
    }
    'update' {
        $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }
        $c.restart = ($args[1] -replace '^--restart=', ''); Save-State; exit 0
    }
    'stop' { $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }; $c.running = $false; Save-State; exit 0 }
    'start' { $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }; $c.running = $true; Save-State; exit 0 }
    'rm' {
        $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }
        if ($c.running) { [Console]::Error.WriteLine('cannot remove a running container (fake)'); exit 1 }
        $state.containers = @($state.containers | Where-Object { $_.id -ne $c.id }); Save-State; exit 0
    }
    'exec' {
        $c = Find-Container $args[1]
        if (-not $c -or -not $c.running) { exit 1 }
        if ($args[2] -eq 'pgrep') { if ($state.busy) { exit 0 } else { exit 1 } }
        exit 0
    }
    'network' {
        $name = $args[2]
        switch ($args[1]) {
            'inspect' { if ($name -in @($state.networks)) { '[]'; exit 0 }; [Console]::Error.WriteLine("network $name not found"); exit 1 }
            'create' { $state.networks = @(@($state.networks) + $name); Save-State; $name; exit 0 }
            'rm' {
                if ($name -notin @($state.networks)) { [Console]::Error.WriteLine("Error response from daemon: network $name not found"); exit 1 }
                $state.networks = @($state.networks | Where-Object { $_ -ne $name }); Save-State; $name; exit 0
            }
        }
    }
    'volume' {
        $name = $args[2]
        switch ($args[1]) {
            'create' { if ($name -notin @($state.volumes)) { $state.volumes = @(@($state.volumes) + $name); Save-State }; $name; exit 0 }
            'rm' {
                if ($name -notin @($state.volumes)) { [Console]::Error.WriteLine("Error response from daemon: get ${name}: no such volume"); exit 1 }
                $state.volumes = @($state.volumes | Where-Object { $_ -ne $name }); Save-State; $name; exit 0
            }
        }
    }
    'compose' {
        $file = $args[[array]::IndexOf($args, '-f') + 1]
        $services = @($args[([array]::IndexOf($args, '--no-deps') + 1)..($args.Count - 1)] | Where-Object { $_ -notlike '--*' })
        $lines = [IO.File]::ReadAllLines($file)
        foreach ($service in $services) {
            $start = [array]::IndexOf($lines, "  ${service}:")
            if ($start -lt 0) { [Console]::Error.WriteLine("no such service: $service"); exit 1 }
            $name = $null; $image = $null; $labels = [ordered]@{}; $inLabels = $false
            for ($i = $start + 1; $i -lt $lines.Count -and $lines[$i] -match '^\s{3,}'; $i++) {
                $text = $lines[$i]
                if ($text -match '^    container_name: (.+)$') { $name = $Matches[1].Trim('"') }
                if ($text -match '^    image: (.+)$') { $image = $Matches[1].Trim('"') }
                if ($text -match '^    labels:') { $inLabels = $true; continue }
                if ($inLabels) { if ($text -match '^      ([^:]+): (.+)$') { $labels[$Matches[1]] = $Matches[2].Trim('"') } else { $inLabels = $false } }
            }
            $c = Find-Container $name
            if ($c) { $c.running = $true }
            else {
                $id = -join ((1..64) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
                $state.containers = @(@($state.containers) + [pscustomobject]@{ id = $id; name = $name; image = $state.images.$image; running = $true; restart = 'always'; labels = [pscustomobject]$labels })
            }
            Save-State
        }
        exit 0
    }
}
[Console]::Error.WriteLine("fake docker: unexpected call $line")
exit 1
'@
# The Windows clone and registration are faked by overriding the two setup functions in the fixture's copy of
# WindowsRunnerSetup.ps1: Sync writes a clone whose Manage-WindowsRunner.ps1 Maintenance writes maintenance.json
# (exit FAKE_MAINT_EXIT); Install writes .runner and registers the runner online with the fake GitHub.
$windowsOverrides = @'

function Sync-RunnerSetupInstance { param([string] $Clone, [string] $InstanceId, [string] $SourceCommit, [string] $GitHubUrl)
    New-Item -ItemType Directory -Path (Join-Path $Clone 'scripts'), (Join-Path $Clone 'windows') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Clone 'scripts\Manage-WindowsRunner.ps1') -Value @(
        'param([string] $Action)'
        'if ($Action -eq ''Maintenance'') { Set-Content -LiteralPath (Join-Path $PSScriptRoot ''..\windows\maintenance.json'') -Value ''{"phase":"held","reason":"retire"}'' }'
        'exit $(if ($env:FAKE_MAINT_EXIT) { [int]$env:FAKE_MAINT_EXIT } else { 0 })')
}
function Install-RunnerSetupInstance { param([string] $Clone, [string] $InstanceId, [string] $GitHubUrl, [string[]] $Labels, [string] $Name)
    $worldPath = Join-Path $env:FAKE_GH_DIR 'world.json'
    $world = Get-Content -Raw -LiteralPath $worldPath | ConvertFrom-Json
    $id = (@(@($world.runners | ForEach-Object { [int64]$_.id }) + 100) | Measure-Object -Maximum).Maximum + 1
    $world.runners = @(@($world.runners) + [pscustomobject]@{ id = $id; name = $Name; status = 'online'; busy = $false; labels = @([pscustomobject]@{ name = 'self-hosted'; type = 'read-only' }) })
    $world | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $worldPath
    [ordered]@{ agentId = $id; agentName = $Name; gitHubUrl = $GitHubUrl; workFolder = '_work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Clone 'windows\.runner')
    "installed $Name"
}
'@

function Set-World($Fixture, $World) { $World | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'world.json') }
function Get-World($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'world.json') | ConvertFrom-Json }
function Update-World($Fixture, [scriptblock] $Change) { $world = Get-World $Fixture; & $Change $world; Set-World $Fixture $world }
function Get-Docker($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'docker.json') | ConvertFrom-Json }
function Set-Docker($Fixture, $State) { $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'docker.json') }
function Update-Docker($Fixture, [scriptblock] $Change) { $state = Get-Docker $Fixture; & $Change $state; Set-Docker $Fixture $state }
function Get-Container($Fixture, [string] $Name) { @((Get-Docker $Fixture).containers | Where-Object { $_.name -eq $Name }) }
function Get-Log($Fixture, [string] $Log) { @(Get-Content -LiteralPath (Join-Path $Fixture.GhState $Log) -ErrorAction SilentlyContinue) }
function Get-Inventory($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.State 'inventory.json') | ConvertFrom-Json }
function Get-Slot($Fixture, [string] $SlotId) { @((Get-Inventory $Fixture).slots | Where-Object slotId -EQ $SlotId)[0] }
function Get-Operation($Fixture) { $path = Join-Path $Fixture.State 'operation.json'; if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } }
function Set-Kill($Fixture, [string] $Pattern, [int] $Skip = 0) { @{ pattern = $Pattern; skip = $Skip } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'kill.json') }
function Set-Count($Fixture, [string] $Platform, $Count) {
    $path = Join-Path $Fixture.Clone 'runners.local.json'
    $settings = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
    $settings.$Platform.count = $Count
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
}

function New-Fixture([int] $Linux = 1, [int] $Windows = 0, [hashtable] $Local = @{}) {
    $clone = New-CaseDirectory
    Copy-Item (Join-Path $repo 'runners.json') $clone
    Copy-Item (Join-Path $repo 'scripts') (Join-Path $clone 'scripts') -Recurse
    Add-Content -LiteralPath (Join-Path $clone 'scripts\WindowsRunnerSetup.ps1') -Value $windowsOverrides
    # LOCALAPPDATA is outside the clone: the Windows slots' clones must not sit under the checkout.
    $shim = Join-Path $clone 'shim'; $ghState = Join-Path $clone 'gh'; $localAppData = New-CaseDirectory
    New-Item -ItemType Directory -Path $shim, $ghState | Out-Null
    Set-Content -LiteralPath (Join-Path $shim 'gh.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-gh.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'docker.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-docker.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'fake-gh.ps1') -Value $fakeGh
    Set-Content -LiteralPath (Join-Path $shim 'fake-docker.ps1') -Value $fakeDocker
    $settings = [ordered]@{
        hostId = 'testhost'; github = [ordered]@{ url = $url }
        buildAgent = [ordered]@{ docker = [ordered]@{ cli = (Join-Path $shim 'docker.cmd'); readyTimeoutSeconds = 20 } }
        linux = [ordered]@{ count = $Linux }; windows = [ordered]@{ count = $Windows }
        lifecycle = [ordered]@{ drainTimeoutMinutes = 1; pollSeconds = 1; startTimeoutSeconds = 4 }
    }
    foreach ($key in $Local.Keys) { $settings[$key] = $Local[$key] }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $fixture = [pscustomobject]@{
        Clone = $clone; Shim = $shim; GhState = $ghState; LocalAppData = $localAppData
        State = (Join-Path $localAppData 'SubZeroDev\Runners\host'); ComposeFile = (Join-Path $clone 'linux\compose.local.yaml')
        InstallRoot = (Join-Path $localAppData 'SubZeroDev\Runners')
    }
    New-Item -ItemType Directory -Path $fixture.State -Force | Out-Null
    Write-Raw (Join-Path $fixture.State 'inventory.json') (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @() })
    Set-World $fixture @{ runners = @(); groups = @(@{ id = 1; name = 'Default'; allows_public_repositories = $false; visibility = 'all' }); deleteNotFound = $false; registerOffline = $false }
    Set-Docker $fixture ([ordered]@{ busy = $false; failOn = @(); unknownFor = @(); networks = @(); volumes = @(); images = @{ $Config.linux.image = $imageId }; containers = @() })
    $fixture
}
function Use-Fixture($Fixture, [scriptblock] $Body) {
    $old = @{ PATH = $env:PATH; FAKE_GH_DIR = $env:FAKE_GH_DIR; LOCALAPPDATA = $env:LOCALAPPDATA }
    try {
        $env:PATH = "$($Fixture.Shim);$($old.PATH)"; $env:FAKE_GH_DIR = $Fixture.GhState; $env:LOCALAPPDATA = $Fixture.LocalAppData
        & $Body
    } finally { $env:PATH = $old.PATH; $env:FAKE_GH_DIR = $old.FAKE_GH_DIR; $env:LOCALAPPDATA = $old.LOCALAPPDATA }
}
function Invoke-Script($Fixture, [string] $Script, [string[]] $Arguments) {
    Use-Fixture $Fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone "scripts\$Script") @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
function Invoke-Apply($Fixture, [string[]] $Arguments = @()) { Invoke-Script $Fixture 'Manage-RunnerHost.ps1' (@('-Action', 'Apply') + $Arguments) }
function Assert-Exit($Result, [int] $Code, [string] $Pattern) {
    Assert ($Result.ExitCode -eq $Code) "Exit $($Result.ExitCode), expected $Code`: $($Result.Output)"
    if ($Pattern) { Assert ($Result.Output -match $Pattern) "Output does not match '$Pattern': $($Result.Output)" }
}

# The state an added Linux slot leaves.
function Assert-LinuxActive($Fixture, [int] $N) {
    $slotId = 'linux-{0:00}' -f $N
    $record = Get-Slot $Fixture $slotId
    Assert ($record -and $record.state -eq 'active') "$slotId is not active."
    Assert (-not $record.legacy -and $record.runnerName -eq (Get-LinuxRunnerName $N)) "$slotId is named $($record.runnerName)."
    $runner = @(Get-Container $Fixture (Get-RunnerContainerName $N))
    $sidecar = @(Get-Container $Fixture (Get-SidecarName $N))
    Assert ($runner.Count -eq 1 -and $runner[0].running -and $sidecar.Count -eq 1 -and $sidecar[0].running) "The containers of $slotId are not running."
    Assert ($runner[0].labels.'dev.subzerodev.runners.slot' -eq $slotId -and $runner[0].labels.'dev.subzerodev.runners.host' -eq 'testhost') "The runner of $slotId lacks the compose labels."
    Assert (@($record.containers | Where-Object { $_.role -eq 'runner' })[0].id -eq $runner[0].id) "The inventory does not record the runner of $slotId by ID."
    Assert ((Get-Content -Raw -LiteralPath $Fixture.ComposeFile) -match "(?m)^  ${slotId}:") "The compose file has no $slotId service."
    $docker = Get-Docker $Fixture
    Assert (@($docker.volumes | Where-Object { $_ -like ('*-{0:00}' -f $N) }).Count -eq 5) "$slotId has $(@($docker.volumes | Where-Object { $_ -like ('*-{0:00}' -f $N) }).Count) volumes, not 5."
    Assert (@($docker.networks | Where-Object { $_ -like ('*-{0:00}' -f $N) }).Count -eq 1) "$slotId has no network."
    $github = @((Get-World $Fixture).runners | Where-Object { $_.name -eq (Get-LinuxRunnerName $N) })
    Assert ($github.Count -eq 1 -and $github[0].status -eq 'online' -and [int64]$github[0].id -eq [int64]$record.runnerId) "GitHub does not have $slotId online under its recorded id."
    $registration = Get-Content -Raw -LiteralPath (Join-Path $record.registrationDirectory '.runner') | ConvertFrom-Json
    Assert ([int64]$registration.agentId -eq [int64]$record.runnerId) "The local registration of $slotId is not its runner."
}
function Assert-Retired($Fixture, [int] $N) {
    $slotId = 'linux-{0:00}' -f $N
    $record = Get-Slot $Fixture $slotId
    Assert ($record.state -eq 'retired') "$slotId is $($record.state), not retired."
    Assert (-not (Get-Operation $Fixture)) 'The journal was not removed.'
    Assert (-not @((Get-World $Fixture).runners | Where-Object { $_.name -eq (Get-LinuxRunnerName $N) }).Count) "GitHub still has the runner of $slotId."
    Assert (-not (Test-Path -LiteralPath (Join-Path $record.registrationDirectory '.runner'))) "The registration of $slotId was not cleared."
    Assert (-not @(Get-Container $Fixture (Get-RunnerContainerName $N)).Count -and -not @(Get-Container $Fixture (Get-SidecarName $N)).Count) "The containers of $slotId were not removed."
    if (Test-Path -LiteralPath $Fixture.ComposeFile) { Assert ((Get-Content -Raw -LiteralPath $Fixture.ComposeFile) -notmatch "(?m)^  ${slotId}:") "The compose file still has $slotId." }
}
# A fixture with linux-01 and linux-02 added.
function New-TwoSlotFixture {
    $f = New-Fixture -Linux 2
    Assert-Exit (Invoke-Apply $f) 0 'linux-02 is active'
    $f
}

# --- scale ------------------------------------------------------------------------------------------------------------

Test-Case 'Scale: Apply adds linux-01 and linux-02 with their own names, network, volumes and registration, never printing the token' {
    $f = New-Fixture -Linux 2
    $result = Invoke-Apply $f
    Assert-Exit $result 0 'linux-01 is active as'
    Assert-LinuxActive $f 1
    Assert-LinuxActive $f 2
    Assert (-not (Get-Operation $f)) 'The journal was not removed.'
    Assert ($result.Output -notmatch 'faketoken') 'The registration token was printed.'
    Assert ((Get-Inventory $f).generation -ge 2) 'The inventory generation was not bumped.'
    Assert-Exit (Invoke-Apply $f) 0 'Nothing to migrate, add, retire or update'
}

if ($IsWindows) {
    Test-Case 'Scale: Windows slots each get their own clone under InstallRoot, and a retired one is deregistered and its clone pruned' {
        $f = New-Fixture -Linux 0 -Windows 2
        $result = Invoke-Apply $f
        Assert-Exit $result 0 'win02 is active as'
        foreach ($n in 1, 2) {
            $slotId = 'win{0:00}' -f $n
            $record = Get-Slot $f $slotId
            $clone = Join-Path $f.InstallRoot $slotId
            Assert ($record.state -eq 'active' -and $record.installPath -eq $clone) "$slotId is $($record.state) at $($record.installPath)."
            Assert (Test-Path -LiteralPath (Join-Path $clone 'windows\.runner')) "$slotId has no registration in its clone."
            Assert ($record.runnerName -eq "subzerodev.runner.windows.testhost.$slotId") "$slotId is named $($record.runnerName)."
        }
        Set-Count $f 'windows' 1
        $retire = Invoke-Apply $f @('-Retire')
        Assert-Exit $retire 0 'win02 is retired'
        Assert ((Get-Slot $f 'win02').state -eq 'retired' -and (Get-Slot $f 'win01').state -eq 'active') 'win02 was not retired alone.'
        Assert (-not @((Get-World $f).runners | Where-Object { $_.name -like '*win02' }).Count) 'GitHub still has win02.'
        Assert-Exit (Invoke-Apply $f @('-Prune')) 0 'win02: pruned'
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.InstallRoot 'win02'))) 'The clone of win02 was not removed.'
        Assert (Test-Path -LiteralPath (Join-Path $f.InstallRoot 'win01')) 'The clone of win01 was removed.'
    }
}

# --- ownership and unknown state --------------------------------------------------------------------------------------

Test-Case 'Ownership: a container at a new slot''s name that is not this host''s compose slot is refused before anything changes' {
    $f = New-Fixture
    Update-Docker $f { param($s) $s.containers = @([pscustomobject]@{ id = '9' * 64; name = (Get-RunnerContainerName 1); image = $imageId; running = $false; restart = 'no'; labels = [pscustomobject]@{} }) }
    $result = Invoke-Apply $f
    Assert-Exit $result 1 'is not this host''s compose linux-01. Nothing was changed'
    Assert (-not (Get-Operation $f)) 'A journal was written.'
    Assert (-not @((Get-Inventory $f).slots).Count) 'A slot was recorded.'
    Assert (-not @(Get-Log $f 'docker.log' | Where-Object { $_ -match '^(run|compose|volume|network create)' }).Count) 'Something was created.'
    Assert (@(Get-Container $f (Get-RunnerContainerName 1)).Count -eq 1) 'The foreign container was touched.'
}

Test-Case 'Unknown is not absent: a name Docker cannot answer for is refused, not taken as free' {
    $f = New-Fixture
    Update-Docker $f { param($s) $s.unknownFor = @((Get-RunnerContainerName 1)) }
    $result = Invoke-Apply $f
    Assert-Exit $result 1 'is unknown'
    Assert ($result.Output -match 'Nothing was changed') "The refusal does not say nothing changed: $($result.Output)"
    Assert (-not (Get-Operation $f)) 'A journal was written.'
    Assert (-not @(Get-Log $f 'docker.log' | Where-Object { $_ -match '^(run|compose)' }).Count) 'Something was created.'
}

# --- add failures -----------------------------------------------------------------------------------------------------

Test-Case 'A runner GitHub reports offline stops the add at verify with the journal kept; rerunning Apply finishes it' {
    $f = New-Fixture
    Update-World $f { param($w) $w.registerOffline = $true }
    $failed = Invoke-Apply $f
    Assert-Exit $failed 1 'Apply stopped at verify of linux-01'
    Assert ((Get-Operation $f).kind -eq 'add-slot') 'The journal was not kept.'
    Assert ((Get-Slot $f 'linux-01').state -eq 'provisioning') 'The slot is not provisioning.'
    Update-World $f { param($w) foreach ($r in $w.runners) { $r.status = 'online' } }
    Assert-Exit (Invoke-Apply $f) 0 'Resuming operation'
    Assert-LinuxActive $f 1
}

foreach ($point in @(
        @{ Step = 'register'; Pattern = '^run --rm' }
        @{ Step = 'create'; Pattern = 'compose .* up -d --no-deps linux-01$' }
        @{ Step = 'commit'; Pattern = '^container inspect'; Skip = 3 })) {
    Test-Case "Add failure injection: a run killed in $($point.Step) is finished by rerunning Apply" {
        $f = New-Fixture
        Set-Kill $f $point.Pattern ([int]$point.Skip)
        $killed = Invoke-Apply $f
        Assert ($killed.ExitCode -ne 0) "The killed run exited 0: $($killed.Output)"
        Assert (@(Get-Log $f 'killed.log').Count -eq 1) 'The run was not killed.'
        Assert ((Get-Operation $f).kind -eq 'add-slot') 'The journal does not show the add unfinished.'
        $result = Invoke-Apply $f
        Assert-Exit $result 0 'Resuming operation'
        Assert-LinuxActive $f 1
        Assert (@((Get-World $f).runners).Count -eq 1) "GitHub has $(@((Get-World $f).runners).Count) runners after the rerun."
    }
}

# --- retire -----------------------------------------------------------------------------------------------------------

Test-Case 'A slot no longer wanted is not retired without -Retire; with it the highest goes, drained, deregistered and removed' {
    $f = New-TwoSlotFixture
    Set-Count $f 'linux' 1
    $skipped = Invoke-Apply $f
    Assert-Exit $skipped 3 'Not retired: linux-02'
    Assert ((Get-Slot $f 'linux-02').state -eq 'active' -and -not (Get-Operation $f)) 'Something changed without -Retire.'
    $result = Invoke-Apply $f @('-Retire')
    Assert-Exit $result 0 'linux-02 is retired'
    Assert-Retired $f 2
    Assert-LinuxActive $f 1
    Assert (@(Get-Log $f 'calls.log' | Where-Object { $_ -match '-X DELETE .*runners/\d+/labels' }).Count -ge 1) 'Admission was not closed before the drain.'
    Assert-Exit (Invoke-Apply $f) 0 'Nothing to migrate, add, retire or update'
}

foreach ($point in @(
        @{ Step = 'drain'; Pattern = 'exec .* pgrep' }
        @{ Step = 'stop'; Pattern = '^stop ' }
        @{ Step = 'deregister'; Pattern = '-X DELETE .*actions/runners/\d+$' }
        @{ Step = 'remove-containers'; Pattern = '^rm ' })) {
    Test-Case "Retire failure injection: a run killed in $($point.Step) is finished by rerunning Apply -Retire" {
        $f = New-TwoSlotFixture
        Set-Count $f 'linux' 1
        Set-Kill $f $point.Pattern
        $killed = Invoke-Apply $f @('-Retire')
        Assert ($killed.ExitCode -ne 0) "The killed run exited 0: $($killed.Output)"
        Assert (@(Get-Log $f 'killed.log').Count -eq 1) 'The run was not killed.'
        Assert ((Get-Operation $f).kind -eq 'retire-slot') 'The journal does not show the retire unfinished.'
        Assert-Exit (Invoke-Apply $f @('-Retire')) 0 'Resuming operation'
        Assert-Retired $f 2
        Assert-LinuxActive $f 1
    }
}

Test-Case 'A runner GitHub already deleted (404) counts as deregistered' {
    $f = New-TwoSlotFixture
    Set-Count $f 'linux' 1
    Update-World $f { param($w) $w.deleteNotFound = $true }
    Assert-Exit (Invoke-Apply $f @('-Retire')) 0 'linux-02 is retired'
    Assert ((Get-Slot $f 'linux-02').state -eq 'retired' -and -not (Get-Operation $f)) 'The retire did not finish.'
}

Test-Case 'A drain that times out leaves the slot active, deletes the journal and reopens admission' {
    $f = New-TwoSlotFixture
    Set-Count $f 'linux' 1
    Update-Docker $f { param($s) $s.busy = $true }
    $result = Invoke-Apply $f @('-Retire')
    Assert-Exit $result 1 'was not started'
    Assert ((Get-Slot $f 'linux-02').state -eq 'active' -and -not (Get-Operation $f)) 'The slot did not go back to active.'
    $runner = @((Get-World $f).runners | Where-Object { $_.name -eq (Get-LinuxRunnerName 2) })[0]
    Assert (@($runner.labels | Where-Object type -EQ 'custom').Count -ge 1) 'Admission was not reopened.'
    Assert (@(Get-Container $f (Get-RunnerContainerName 2))[0].running) 'The runner was stopped.'
}

# --- prune ------------------------------------------------------------------------------------------------------------

Test-Case 'Apply -Prune removes what a retired slot left (directory, volumes, network); a failure keeps it retired' {
    $f = New-TwoSlotFixture
    Set-Count $f 'linux' 1
    Assert-Exit (Invoke-Apply $f @('-Retire')) 0
    $directory = (Get-Slot $f 'linux-02').registrationDirectory
    Update-Docker $f { param($s) $s.failOn = @('^volume rm .*-work-02$') }
    $failed = Invoke-Apply $f @('-Prune')
    Assert-Exit $failed 1 'linux-02: not fully pruned'
    Assert ((Get-Slot $f 'linux-02').state -eq 'retired') 'A failed prune changed the state.'
    Update-Docker $f { param($s) $s.failOn = @() }
    Assert-Exit (Invoke-Apply $f @('-Prune')) 0 'linux-02: pruned'
    Assert ((Get-Slot $f 'linux-02').state -eq 'pruned') 'linux-02 is not pruned.'
    Assert (-not (Test-Path -LiteralPath $directory)) 'The directory of linux-02 was not removed.'
    $docker = Get-Docker $f
    Assert (-not @($docker.volumes | Where-Object { $_ -like '*-02' }).Count -and -not @($docker.networks | Where-Object { $_ -like '*-02' }).Count) 'linux-02 left a volume or network.'
    Assert-LinuxActive $f 1
    Assert-Exit (Invoke-Apply $f @('-Prune')) 0 'nothing to prune'
    # The numbers are never reused: raising the count again adds linux-03.
    Set-Count $f 'linux' 2
    Assert-Exit (Invoke-Apply $f) 0 'linux-03 is active'
    Assert-LinuxActive $f 3
    Assert ((Get-Slot $f 'linux-02').state -eq 'pruned') 'linux-02 was reused.'
}

# --- blockers and the reviewed plan -----------------------------------------------------------------------------------

Test-Case 'A public runner group, low disk or a missing image refuses the add before anything changes' {
    foreach ($setup in @(
            @{ Why = 'public'; Local = @{}; Change = { param($f) Update-World $f { param($w) $w.groups[0].allows_public_repositories = $true } } }
            @{ Why = 'minFreeGB'; Local = @{ housekeeping = @{ minFreeGB = 100000 } }; Change = { param($f) } }
            @{ Why = 'not built'; Local = @{}; Change = { param($f) Update-Docker $f { param($s) $s.images = @{} } } })) {
        $f = New-Fixture -Local $setup.Local
        & $setup.Change $f
        $result = Invoke-Apply $f
        Assert-Exit $result 1 'Apply added no slot'
        Assert ($result.Output -match $setup.Why) "The refusal does not name the reason '$($setup.Why)': $($result.Output)"
        Assert (-not (Get-Operation $f) -and -not @((Get-Inventory $f).slots).Count) "Something changed with a blocker ($($setup.Why))."
        Assert (-not @(Get-Log $f 'docker.log' | Where-Object { $_ -match '^(run|compose)' }).Count) "Something was created with a blocker ($($setup.Why))."
    }
}

Test-Case 'Apply -ExpectPlan refuses when the plan is not the reviewed one, and applies when it is' {
    $f = New-Fixture
    $refused = Invoke-Apply $f @('-ExpectPlan', ('0' * 64))
    Assert-Exit $refused 1 'Nothing was changed'
    Assert (-not @((Get-Inventory $f).slots).Count) 'A slot was added against a changed plan.'
    $plan = Invoke-Script $f 'Manage-RunnerHost.ps1' @('-Action', 'Plan', '-Json')
    $hash = ($plan.Output -replace '(?s)^[^{]*', '' | ConvertFrom-Json).planHash
    Assert-Exit (Invoke-Apply $f @('-ExpectPlan', $hash)) 0 'linux-01 is active'
}

# --- concurrency ------------------------------------------------------------------------------------------------------

Test-Case 'Concurrency: a second Apply waits for the first and does not repeat its retire' {
    $f = New-TwoSlotFixture
    Set-Count $f 'linux' 1
    Update-Docker $f { param($s) $s.busy = $true }
    $firstOut = Join-Path $f.GhState 'first.out'
    $first = Use-Fixture $f {
        Start-Process -FilePath $pwshPath -PassThru -NoNewWindow -RedirectStandardOutput $firstOut -RedirectStandardError "$firstOut.err" `
            -ArgumentList @('-NoLogo', '-NoProfile', '-File', (Join-Path $f.Clone 'scripts\Manage-RunnerHost.ps1'), '-Action', 'Apply', '-Retire')
    }
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(40)
        while (-not (@(Get-Log $f 'docker.log' | Where-Object { $_ -match 'exec .* pgrep' }).Count) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
        Assert ((Get-Operation $f).kind -eq 'retire-slot') 'The first Apply did not reach the drain.'
        $second = Use-Fixture $f {
            Start-Process -FilePath $pwshPath -PassThru -NoNewWindow -RedirectStandardOutput "$firstOut.2" -RedirectStandardError "$firstOut.2.err" `
                -ArgumentList @('-NoLogo', '-NoProfile', '-File', (Join-Path $f.Clone 'scripts\Manage-RunnerHost.ps1'), '-Action', 'Apply', '-Retire')
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not ((Get-Content -Raw -LiteralPath "$firstOut.2.err" -ErrorAction SilentlyContinue) -match 'Waiting for another runner operation') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 250 }
        Assert ((Get-Content -Raw -LiteralPath "$firstOut.2.err" -ErrorAction SilentlyContinue) -match 'Waiting for another runner operation') 'The second Apply did not wait.'
        Update-Docker $f { param($s) $s.busy = $false }
        Assert ($first.WaitForExit(60000) -and $second.WaitForExit(60000)) 'An Apply did not finish.'
        Assert ($first.ExitCode -eq 0) "The first Apply exited $($first.ExitCode): $(Get-Content -Raw -LiteralPath $firstOut) $(Get-Content -Raw -LiteralPath "$firstOut.err")"
        Assert ($second.ExitCode -eq 0) "The second Apply exited $($second.ExitCode): $(Get-Content -Raw -LiteralPath "$firstOut.2") $(Get-Content -Raw -LiteralPath "$firstOut.2.err")"
        Assert ((Get-Content -Raw -LiteralPath "$firstOut.2") -match 'Nothing to migrate, add, retire or update') 'The second Apply did not find the work done.'
        Assert (@(Get-Log $f 'calls.log' | Where-Object { $_ -match '-X DELETE .*actions/runners/\d+$' }).Count -eq 1) 'The runner was deregistered more than once.'
        Assert-Retired $f 2
        Assert-LinuxActive $f 1
    } finally {
        foreach ($p in $first, $second) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    }
}

# --- result -----------------------------------------------------------------------------------------------------------

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host "$($cases.Count - $failed.Count)/$($cases.Count) passed"
if ($failed.Count) { exit 1 }
# The fakes deliberately fail some native calls, and GitHub's pwsh wrapper exits with the last LASTEXITCODE.
exit 0
