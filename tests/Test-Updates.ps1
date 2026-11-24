#Requires -Version 7.2
# Tests for updates and resources (S7): Manage-RunnerHost -Action Update -Version x.y.z and the update phase of Apply.
#   - Update resolves the BuildAgent release to its digest and writes it into runners.local.json and the inventory before
#     anything is recreated; the Linux image is rebuilt on it and each slot recreated inside its own drain; Apply after
#     Update has nothing to do; GitHub registrations are kept;
#   - a run killed while recreating is finished by Apply;
#   - a floating or partial version, or one the registry cannot resolve, is refused before anything changes;
#   - a replaced digest back in the settings is a blocked downgrade: Plan reports it, Apply refuses it; an earlier release
#     through Update is a rollback and is said so;
#   - a held slot is deferred (deferred: held), a busy one that does not drain is left as it is (deferred: busy) while the
#     others update;
#   - Plan reports volumes, Docker's data drive and memory read only, the Windows figure advisory, and never edits
#     .wslconfig.
# Every case uses its own LOCALAPPDATA. GitHub and Docker are a fake gh and docker first on PATH.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

. (Join-Path $repo 'scripts\Common.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ('szr-updates-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
$originalLocalAppData = $env:LOCALAPPDATA
$env:SZR_HOST_OPERATION = $null
$pwshPath = (Get-Process -Id $PID).Path
$url = 'https://github.com/AbsoluteZeroDev'
$imageId = 'sha256:' + ('e' * 64)
$agentRepository = ([string](Get-Content -Raw -LiteralPath (Join-Path $repo 'runners.json') | ConvertFrom-Json).buildAgent.image) -replace '@.*$', ''
$originalAgent = [string](Get-Content -Raw -LiteralPath (Join-Path $repo 'runners.json') | ConvertFrom-Json).buildAgent.image
$newDigest = 'sha256:' + ('1' * 64)
$newAgent = "$agentRepository@$newDigest"
$archiveName = 'actions-runner-linux-x64-{0}.tar.gz' -f (Get-Content -Raw -LiteralPath (Join-Path $repo 'runners.json') | ConvertFrom-Json).runnerVersion
function Get-RunnerContainerName([int] $N) { '{0}-{1:00}' -f $Config.linux.container, $N }
function Get-SidecarName([int] $N) { '{0}-{1:00}' -f $Config.linux.docker.container, $N }

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
# The fake GitHub keeps world.json: runners [{id, name, status, busy, labels}], groups, and release (the actions/runner
# release the archive is checked against).
$fakeGh = $killHelper + @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
Invoke-FakeKill $dir $line
$path = Join-Path $dir 'world.json'
$world = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
if ($line -match '-X POST .*registration-token') { 'faketoken'; exit 0 }
if ($line -match 'repos/actions/runner/releases/tags/') { $world.release | ConvertTo-Json -Depth 8; exit 0 }
if ($line -match '-X (POST|PUT|PATCH|DELETE)') { exit 0 }
# Every runner is in the Default group.
if ($line -match 'actions/runner-groups/\d+/runners') { foreach ($r in @($world.runners)) { $r.id }; exit 0 }
if ($line -match 'actions/runner-groups$|actions/runner-groups ') { foreach ($g in @($world.groups)) { $g | ConvertTo-Json -Compress -Depth 8 }; exit 0 }
if ($line -match 'actions/runners') { foreach ($r in @($world.runners)) { $r | ConvertTo-Json -Compress -Depth 8 }; exit 0 }
exit 0
'@
# The fake Docker keeps docker.json: containers [{id, name, image, running, restart, labels}], images {ref: id}, labels
# {ref: context hash}, registry {repo:tag: digest}, volumes, networks, busyFor (containers whose exec pgrep answers busy),
# failOn (regexes whose calls fail). build gives the tagged image a new ID and label; compose up --force-recreate gives a
# container a new ID on the current image.
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
function New-Id { -join ((1..64) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }) }
switch ($args[0]) {
    'info' { 'fake docker'; exit 0 }
    'image' {
        $ref = $args[-1]
        $id = $state.images.$ref
        if (-not $id) { [Console]::Error.WriteLine("Error response from daemon: No such image: $ref"); exit 1 }
        if ($line -match 'runners\.context') { $label = $state.labels.$ref; if ($label) { $label } else { '<no value>' }; exit 0 }
        $id; exit 0
    }
    'build' {
        $tag = $args[[array]::IndexOf($args, '-t') + 1]
        $label = ($args[[array]::IndexOf($args, '--label') + 1] -split '=', 2)[1]
        if (-not $state.images) { $state | Add-Member -Force images ([pscustomobject]@{}) }
        if (-not $state.labels) { $state | Add-Member -Force labels ([pscustomobject]@{}) }
        $state.images | Add-Member -Force -NotePropertyName $tag -NotePropertyValue ('sha256:' + (New-Id))
        $state.labels | Add-Member -Force -NotePropertyName $tag -NotePropertyValue $label
        Save-State
        'built (fake)'; exit 0
    }
    'buildx' {
        $ref = $args[-1]
        $digest = $state.registry.$ref
        if (-not $digest) { [Console]::Error.WriteLine("ERROR: ${ref}: not found"); exit 1 }
        "Name:      $ref"; 'MediaType: application/vnd.oci.image.index.v1+json'; "Digest:    $digest"; exit 0
    }
    'system' {
        ConvertTo-Json -Compress -InputObject @(@($state.volumes) | ForEach-Object { [ordered]@{ Name = $_; Size = '1.5GB' } }); exit 0
    }
    'container' {
        $ref = $args[-1]
        $c = Find-Container $ref
        if (-not $c) { Write-Missing $ref }
        if ($args -contains '--format') {
            if ($line -match 'compose\.project') { $c.labels.'com.docker.compose.project'; exit 0 }
            if ($c.running) { 'true' } else { 'false' }; exit 0
        }
        ConvertTo-Json -Depth 6 -InputObject @([ordered]@{ Id = $c.id; Name = "/$($c.name)"; Image = $c.image; Config = @{ Labels = $c.labels }; State = @{ Running = [bool]$c.running }; HostConfig = @{ RestartPolicy = @{ Name = $c.restart } } })
        exit 0
    }
    'update' { $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }; $c.restart = ($args[1] -replace '^--restart=', ''); Save-State; exit 0 }
    'stop' { $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }; $c.running = $false; Save-State; exit 0 }
    'start' { $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }; $c.running = $true; Save-State; exit 0 }
    'rm' {
        $c = Find-Container $args[-1]; if (-not $c) { Write-Missing $args[-1] }
        $state.containers = @($state.containers | Where-Object { $_.id -ne $c.id }); Save-State; exit 0
    }
    'exec' {
        $c = Find-Container $args[1]
        if (-not $c -or -not $c.running) { exit 1 }
        if ($args[2] -eq 'pgrep') { if ($c.name -in @($state.busyFor)) { exit 0 } else { exit 1 } }
        exit 0
    }
    'run' {
        $mount = $args[[array]::IndexOf($args, '--mount') + 1]
        $target = ($mount -split ',' | Where-Object { $_ -like 'source=*' }) -replace '^source=', ''
        $name = $args[[array]::IndexOf($args, '--name') + 1]
        $gitHubUrl = $args[[array]::IndexOf($args, '--url') + 1]
        $worldPath = Join-Path $dir 'world.json'
        $world = Get-Content -Raw -LiteralPath $worldPath | ConvertFrom-Json
        $id = (@(@($world.runners | ForEach-Object { [int64]$_.id }) + 100) | Measure-Object -Maximum).Maximum + 1
        $world.runners = @(@($world.runners | Where-Object { $_.name -ne $name }) + [pscustomobject]@{ id = $id; name = $name; status = 'online'; busy = $false; labels = @([pscustomobject]@{ name = 'self-hosted'; type = 'read-only' }) })
        $world | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $worldPath
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        [ordered]@{ agentId = $id; agentName = $name; gitHubUrl = $gitHubUrl; workFolder = '/tmp/runner-work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.runner')
        'Runner successfully added'; exit 0
    }
    'network' {
        $name = $args[2]
        switch ($args[1]) {
            'inspect' { if ($name -in @($state.networks)) { '[]'; exit 0 }; [Console]::Error.WriteLine("network $name not found"); exit 1 }
            'create' { $state.networks = @(@($state.networks) + $name); Save-State; $name; exit 0 }
        }
    }
    'volume' {
        $name = $args[2]
        if ($args[1] -eq 'create') { if ($name -notin @($state.volumes)) { $state.volumes = @(@($state.volumes) + $name); Save-State }; $name; exit 0 }
    }
    'compose' {
        $file = $args[[array]::IndexOf($args, '-f') + 1]
        $recreate = $args -contains '--force-recreate'
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
            if ($c -and -not $recreate) { $c.running = $true }
            else {
                $state.containers = @(@($state.containers | Where-Object { $_.name -ne $name }) + [pscustomobject]@{ id = (New-Id); name = $name; image = $state.images.$image; running = $true; restart = 'always'; labels = [pscustomobject]$labels })
            }
            Save-State
        }
        exit 0
    }
}
[Console]::Error.WriteLine("fake docker: unexpected call $line")
exit 1
'@

function Set-World($Fixture, $World) { $World | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'world.json') }
function Get-World($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'world.json') | ConvertFrom-Json }
function Get-Docker($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'docker.json') | ConvertFrom-Json }
function Set-Docker($Fixture, $State) { $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'docker.json') }
function Update-Docker($Fixture, [scriptblock] $Change) { $state = Get-Docker $Fixture; & $Change $state; Set-Docker $Fixture $state }
function Get-Container($Fixture, [string] $Name) { @((Get-Docker $Fixture).containers | Where-Object { $_.name -eq $Name }) | Select-Object -First 1 }
function Get-Log($Fixture, [string] $Log) { @(Get-Content -LiteralPath (Join-Path $Fixture.GhState $Log) -ErrorAction SilentlyContinue) }
function Get-Inventory($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.State 'inventory.json') | ConvertFrom-Json }
function Get-Slot($Fixture, [string] $SlotId) { @((Get-Inventory $Fixture).slots | Where-Object slotId -EQ $SlotId)[0] }
function Get-Operation($Fixture) { $path = Join-Path $Fixture.State 'operation.json'; if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } }
function Get-LocalSettings($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.Clone 'runners.local.json') | ConvertFrom-Json }
function Set-Kill($Fixture, [string] $Pattern, [int] $Skip = 0) { @{ pattern = $Pattern; skip = $Skip } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'kill.json') }

function New-Fixture([int] $Linux = 1) {
    $clone = New-CaseDirectory
    Copy-Item (Join-Path $repo 'runners.json'), (Join-Path $repo '.dockerignore') $clone
    Copy-Item (Join-Path $repo 'scripts') (Join-Path $clone 'scripts') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $clone 'linux'), (Join-Path $clone 'downloads') | Out-Null
    foreach ($file in 'Dockerfile', 'entrypoint.sh', 'healthcheck.sh') { Copy-Item (Join-Path $repo "linux\$file") (Join-Path $clone 'linux') }
    # The runner archive is already downloaded, so nothing is fetched; the fake release publishes its SHA-256.
    $archive = Join-Path $clone "downloads\$archiveName"
    [IO.File]::WriteAllText($archive, 'fake runner archive')
    $archiveSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $shim = Join-Path $clone 'shim'; $ghState = Join-Path $clone 'gh'; $localAppData = New-CaseDirectory
    New-Item -ItemType Directory -Path $shim, $ghState | Out-Null
    Set-Content -LiteralPath (Join-Path $shim 'gh.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-gh.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'docker.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-docker.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'fake-gh.ps1') -Value $fakeGh
    Set-Content -LiteralPath (Join-Path $shim 'fake-docker.ps1') -Value $fakeDocker
    $settings = [ordered]@{
        hostId = 'testhost'; github = [ordered]@{ url = $url }
        buildAgent = [ordered]@{ docker = [ordered]@{ cli = (Join-Path $shim 'docker.cmd'); readyTimeoutSeconds = 20 } }
        linux = [ordered]@{ count = $Linux }; windows = [ordered]@{ count = 0 }
        lifecycle = [ordered]@{ drainTimeoutMinutes = 1; pollSeconds = 1; startTimeoutSeconds = 4 }
    }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $fixture = [pscustomobject]@{
        Clone = $clone; Shim = $shim; GhState = $ghState; LocalAppData = $localAppData
        State = (Join-Path $localAppData 'SubZeroDev\Runners\host'); WslConfig = (Join-Path $clone 'wslconfig')
    }
    New-Item -ItemType Directory -Path $fixture.State -Force | Out-Null
    Write-Raw (Join-Path $fixture.State 'inventory.json') (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @() })
    Set-World $fixture @{
        runners = @(); groups = @(@{ id = 1; name = 'Default'; allows_public_repositories = $false; visibility = 'all' })
        release = @{ assets = @(@{ name = $archiveName; digest = "sha256:$archiveSha" }) }
    }
    # The built image carries the context hash the settings give, so nothing is stale until the settings change.
    $hash = & $pwshPath -NoLogo -NoProfile -Command ". '$clone\scripts\Common.ps1'; . '$clone\scripts\Compose.ps1'; Get-LinuxExpectedContextHash `$Config `$Root"
    Assert ($LASTEXITCODE -eq 0 -and "$hash" -match '^[0-9a-f]{64}$') "The fixture's context hash could not be computed: $hash"
    Set-Docker $fixture ([ordered]@{
            failOn = @(); busyFor = @(); networks = @(); volumes = @(); containers = @()
            images = @{ $Config.linux.image = $imageId }; labels = @{ $Config.linux.image = "$hash" }
            registry = @{ "${agentRepository}:1.4.0" = ($originalAgent -replace '^.*@', ''); "${agentRepository}:1.5.0" = $newDigest }
        })
    $fixture
}
function Use-Fixture($Fixture, [scriptblock] $Body) {
    $old = @{ PATH = $env:PATH; FAKE_GH_DIR = $env:FAKE_GH_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; SZR_WSLCONFIG = $env:SZR_WSLCONFIG; SZR_DOCKER_DATA = $env:SZR_DOCKER_DATA }
    try {
        $env:PATH = "$($Fixture.Shim);$($old.PATH)"; $env:FAKE_GH_DIR = $Fixture.GhState; $env:LOCALAPPDATA = $Fixture.LocalAppData
        $env:SZR_WSLCONFIG = $Fixture.WslConfig; $env:SZR_DOCKER_DATA = $Fixture.Clone
        & $Body
    } finally { foreach ($key in $old.Keys) { Set-Item -Path "env:$key" -Value $old[$key] } }
}
function Invoke-Script($Fixture, [string[]] $Arguments) {
    Use-Fixture $Fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone 'scripts\Manage-RunnerHost.ps1') @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
function Invoke-Apply($Fixture, [string[]] $Arguments = @()) { Invoke-Script $Fixture (@('-Action', 'Apply') + $Arguments) }
function Invoke-Update($Fixture, [string] $Version) { Invoke-Script $Fixture @('-Action', 'Update', '-Version', $Version) }
function Assert-Exit($Result, [int] $Code, [string] $Pattern) {
    Assert ($Result.ExitCode -eq $Code) "Exit $($Result.ExitCode), expected $Code`: $($Result.Output)"
    if ($Pattern) { Assert ($Result.Output -match $Pattern) "Output does not match '$Pattern': $($Result.Output)" }
}
# A fixture with its Linux slots added and running on the current image.
function New-ActiveFixture([int] $Linux = 1) {
    $f = New-Fixture -Linux $Linux
    Assert-Exit (Invoke-Apply $f) 0 ('linux-{0:00} is active' -f $Linux)
    $f
}
# A Linux slot runs the current image: its runner is recorded by ID and runs the image the tag now names.
function Assert-OnCurrentImage($Fixture, [int] $N) {
    $docker = Get-Docker $Fixture
    $runner = Get-Container $Fixture (Get-RunnerContainerName $N)
    Assert ($runner -and $runner.running -and $runner.image -eq $docker.images.($Config.linux.image)) "linux-$('{0:00}' -f $N) does not run the current image."
    $record = Get-Slot $Fixture ('linux-{0:00}' -f $N)
    Assert (@($record.containers | Where-Object { $_.role -eq 'runner' })[0].id -eq $runner.id) "The inventory does not record the recreated runner of linux-$('{0:00}' -f $N)."
}

# --- Update -----------------------------------------------------------------------------------------------------------

Test-Case 'Update records the digest, rebuilds the image and recreates each Linux slot in its drain; Apply then has nothing to do' {
    $f = New-ActiveFixture -Linux 2
    $before = @(1, 2 | ForEach-Object { (Get-Container $f (Get-RunnerContainerName $_)).id })
    $registrations = @(Get-Log $f 'calls.log' | Where-Object { $_ -match 'registration-token' }).Count
    $result = Invoke-Update $f '1.5.0'
    Assert-Exit $result 0 'Moving buildAgent\.image to 1\.5\.0'
    Assert ($result.Output -match 'Building ' -and $result.Output -match 'linux-01 is updated' -and $result.Output -match 'linux-02 is updated') "Update did not rebuild and update both slots: $($result.Output)"
    $local = Get-LocalSettings $f
    Assert ($local.buildAgent.image -eq $newAgent -and $local.buildAgent.docker.cli) "runners.local.json has $($local.buildAgent.image), or lost its other buildAgent keys."
    $inventory = Get-Inventory $f
    Assert ($inventory.buildAgent.image -eq $newAgent -and $inventory.buildAgent.version -eq '1.5.0') 'The inventory does not record the new BuildAgent digest.'
    Assert (@($inventory.buildAgent.previous | Where-Object { $_.image -eq $originalAgent }).Count -eq 1) 'The inventory does not keep the replaced digest.'
    Assert (@(Get-Log $f 'docker.log' | Where-Object { $_ -match '^build ' -and $_ -match [regex]::Escape("BASE_IMAGE=$newAgent") }).Count -eq 1) 'The Linux image was not built once on the new digest.'
    foreach ($n in 1, 2) { Assert-OnCurrentImage $f $n }
    Assert ((Get-Container $f (Get-RunnerContainerName 1)).id -ne $before[0] -and (Get-Container $f (Get-RunnerContainerName 2)).id -ne $before[1]) 'A runner container was not recreated.'
    Assert (@(Get-Log $f 'calls.log' | Where-Object { $_ -match 'registration-token' }).Count -eq $registrations) 'Update registered a runner again.'
    Assert (-not (Get-Operation $f)) 'The journal was not removed.'
    Assert-Exit (Invoke-Apply $f) 0 'Nothing to migrate, add, retire or update'
    $plan = Invoke-Script $f @('-Action', 'Plan')
    Assert-Exit $plan 0 'No changes\.'
}

Test-Case 'Update writes runners.local.json and the inventory before anything is recreated; a run killed while recreating is finished by Apply' {
    $f = New-ActiveFixture -Linux 2
    Set-Kill $f 'compose .*--force-recreate'
    $killed = Invoke-Update $f '1.5.0'
    Assert ($killed.ExitCode -ne 0) "The killed Update exited 0: $($killed.Output)"
    Assert ((Get-LocalSettings $f).buildAgent.image -eq $newAgent) 'runners.local.json was not written before the recreate.'
    Assert ((Get-Inventory $f).buildAgent.image -eq $newAgent) 'The inventory was not written before the recreate.'
    $op = Get-Operation $f
    Assert ($op -and $op.kind -eq 'update-slot' -and $op.slotId -eq 'linux-01') 'No update journal was left for linux-01.'
    $plan = Invoke-Script $f @('-Action', 'Plan')
    Assert-Exit $plan 3 'finish-operation'
    $result = Invoke-Apply $f
    Assert-Exit $result 0 'Resuming operation'
    Assert ($result.Output -match 'linux-01 is updated' -and $result.Output -match 'linux-02 is updated') "Apply did not finish both updates: $($result.Output)"
    foreach ($n in 1, 2) { Assert-OnCurrentImage $f $n }
    Assert (@(Get-Log $f 'docker.log' | Where-Object { $_ -match '^build ' }).Count -eq 1) 'The image was built more than once.'
    Assert-Exit (Invoke-Apply $f) 0 'Nothing to migrate, add, retire or update'
}

Test-Case 'A floating, partial or unresolvable version is refused before anything changes' {
    $f = New-ActiveFixture
    $settings = Get-Content -Raw -LiteralPath (Join-Path $f.Clone 'runners.local.json')
    $inventory = Get-Content -Raw -LiteralPath (Join-Path $f.State 'inventory.json')
    foreach ($version in 'latest', '1', '1.4', 'v1.5.0', '1.5.0-rc1') {
        Assert-Exit (Invoke-Update $f $version) 1 'is not an exact release.*Nothing was changed'
    }
    Assert (-not @(Get-Log $f 'docker.log' | Where-Object { $_ -match '^buildx' }).Count) 'A floating version was resolved.'
    Assert-Exit (Invoke-Update $f '9.9.9') 1 'could not be resolved.*Nothing was changed'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $f.Clone 'runners.local.json')) -eq $settings) 'runners.local.json was changed.'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $f.State 'inventory.json')) -eq $inventory) 'The inventory was changed.'
    Assert (-not @(Get-Log $f 'docker.log' | Where-Object { $_ -match '^(build|compose) .*force-recreate|^build ' }).Count) 'Something was built or recreated.'
}

Test-Case 'A replaced digest back in the settings is a blocked downgrade: Plan reports it, Apply refuses; Update to an earlier release is a rollback' {
    $f = New-ActiveFixture
    Assert-Exit (Invoke-Update $f '1.5.0') 0 'linux-01 is updated'
    # An older runners.local.json restored: the digest Update replaced is back.
    $local = Get-LocalSettings $f
    $local.buildAgent.image = $originalAgent
    $local | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $f.Clone 'runners.local.json')
    $runner = (Get-Container $f (Get-RunnerContainerName 1)).id
    Assert-Exit (Invoke-Script $f @('-Action', 'Plan')) 3 '\[blocked\] buildAgent: .*downgrade'
    Assert-Exit (Invoke-Apply $f) 1 'Apply refused: .*downgrade.*Nothing was changed'
    Assert ((Get-Container $f (Get-RunnerContainerName 1)).id -eq $runner) 'The refused Apply recreated the runner.'
    # The rollback that was meant: Update to the earlier release.
    $local.buildAgent.image = $newAgent
    $local | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $f.Clone 'runners.local.json')
    $rollback = Invoke-Update $f '1.4.0'
    Assert-Exit $rollback 0 'Rolling back buildAgent\.image to 1\.4\.0 .* from 1\.5\.0'
    Assert ($rollback.Output -match 'linux-01 is updated') "The rollback did not recreate linux-01: $($rollback.Output)"
    Assert ((Get-LocalSettings $f).buildAgent.image -eq $originalAgent -and (Get-Inventory $f).buildAgent.version -eq '1.4.0') 'The rollback was not recorded.'
    Assert-OnCurrentImage $f 1
    $plan = Invoke-Script $f @('-Action', 'Plan')
    Assert-Exit $plan 0 'No changes\.'
    # Moving forward again is not a rollback, and the later digest restored after a rollback is not a downgrade.
    Assert-Exit (Invoke-Update $f '1.5.0') 0 'Moving buildAgent\.image to 1\.5\.0'
}

Test-Case 'A held slot is deferred (deferred: held) and a busy one left as it is (deferred: busy) while the others update' {
    $f = New-ActiveFixture -Linux 3
    Assert-Exit (Invoke-Script $f @('-Action', 'Hold', '-Slot', 'linux-02')) 0 'held'
    Update-Docker $f { param($s) $s.busyFor = @(Get-RunnerContainerName 3) }
    $busyRunner = (Get-Container $f (Get-RunnerContainerName 3)).id
    $result = Invoke-Update $f '1.5.0'
    Assert-Exit $result 3 'linux-01 is updated'
    Assert ($result.Output -match 'Deferred: linux-02 is held.*\(deferred: held\)') "linux-02 was not deferred as held: $($result.Output)"
    Assert ($result.Output -match 'Deferred: linux-03 is busy.*\(deferred: busy') "linux-03 was not deferred as busy: $($result.Output)"
    Assert-OnCurrentImage $f 1
    $busy = Get-Container $f (Get-RunnerContainerName 3)
    Assert ($busy.id -eq $busyRunner -and $busy.running) 'The busy runner was not left as it was.'
    Assert (-not (Test-Path -LiteralPath (Join-Path (Get-Slot $f 'linux-03').registrationDirectory 'maintenance.json'))) 'The busy slot was left in maintenance.'
    Assert (-not (Get-Operation $f)) 'A journal was left for a deferred slot.'
    # Once resumed and idle, Apply updates them.
    Assert-Exit (Invoke-Script $f @('-Action', 'Resume', '-Slot', 'linux-02')) 0 'resumed'
    Update-Docker $f { param($s) $s.busyFor = @() }
    $apply = Invoke-Apply $f
    Assert-Exit $apply 0 'linux-02 is updated'
    Assert ($apply.Output -match 'linux-03 is updated') "linux-03 was not updated once idle: $($apply.Output)"
    foreach ($n in 1, 2, 3) { Assert-OnCurrentImage $f $n }
}

# --- resources --------------------------------------------------------------------------------------------------------

Test-Case 'Plan reports volumes, Docker''s data drive and memory read only, the Windows figure advisory, and never edits .wslconfig' {
    $f = New-ActiveFixture -Linux 2
    Write-Raw $f.WslConfig "[wsl2]`nmemory=8GB`nprocessors=4`n"
    $wsl = Get-Content -Raw -LiteralPath $f.WslConfig
    $plan = Invoke-Script $f @('-Action', 'Plan')
    Assert-Exit $plan 0 'Resources \(read only\):'
    Assert ($plan.Output -match 'volume \S+-01 \(linux-01\): 1\.5GB') "Plan does not list the slot volumes: $($plan.Output)"
    Assert ($plan.Output -match 'Linux memory \(enforced\): 2 slot\(s\) x 12 GB = 24 GB') "Plan does not total the Linux memory: $($plan.Output)"
    Assert ($plan.Output -match 'Windows memory \(advisory, not enforced\): 0 slot\(s\)') "Plan does not label the Windows memory advisory: $($plan.Output)"
    Assert ($plan.Output -match 'WSL memory cap: 8GB') "Plan does not report the WSL cap: $($plan.Output)"
    Assert ($plan.Output -match '\[warning\] resources: The Linux slots may use 24 GB, more than the WSL memory cap 8GB') "Plan does not warn about the WSL cap: $($plan.Output)"
    Assert ($plan.Output -match 'Docker data .* GB free, minimum') "Plan does not report Docker's data drive: $($plan.Output)"
    Assert ((Get-Content -Raw -LiteralPath $f.WslConfig) -eq $wsl) '.wslconfig was changed.'
    # The warning is for the owner: not hashed, and the plan is otherwise clean (exit 0).
    $json = (Invoke-Script $f @('-Action', 'Plan', '-Json')).Output | ConvertFrom-Json
    Assert ($json.resources.memory.windows.basis -match 'advisory' -and $json.resources.memory.wslCap.memory -eq '8GB') 'The JSON plan lacks the resources.'
    Remove-Item -LiteralPath $f.WslConfig
    Assert-Exit (Invoke-Script $f @('-Action', 'Plan')) 0 'WSL memory cap: not set'
    Update-Docker $f { param($s) $s.failOn = @('^system ') }
    Assert-Exit (Invoke-Script $f @('-Action', 'Plan')) 0 'volumes: unknown'
}

# --- result -----------------------------------------------------------------------------------------------------------

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host "$($cases.Count - $failed.Count)/$($cases.Count) passed"
if ($failed.Count) { exit 1 }
# The fakes deliberately fail some native calls, and GitHub's pwsh wrapper exits with the last LASTEXITCODE.
exit 0
