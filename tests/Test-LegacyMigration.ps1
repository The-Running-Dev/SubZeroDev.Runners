#Requires -Version 7.2
# Tests for the legacy Linux migration (S5): Manage-RunnerHost -Action Apply moves the pre-pool runner (linux-01, legacy)
# onto its compose containers with the same registration, journaled step by step.
#   - the two runner containers never run at the same time (the fake Docker records any moment they do);
#   - a run killed in any step is finished by rerunning Apply, and a failure keeps the journal;
#   - Apply -Rollback before verify puts the pre-pool containers back; after verify it is refused;
#   - a slot the owner held stays held (C4); the pre-pool containers are kept until Apply -Prune;
#   - Prune removes a kept container only by its recorded ID and name, stopped (C3); renamed, running and unknown are kept;
#   - a container at a target name that is not this host's compose linux-01 is refused before anything changes;
#   - New-LinuxRunner refuses while the operation is unfinished.
# Every case uses its own LOCALAPPDATA. GitHub and Docker are a fake gh and docker first on PATH.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

. (Join-Path $repo 'scripts\Common.ps1')
. (Join-Path $repo 'scripts\Registration.ps1')
. (Join-Path $repo 'scripts\Lifecycle.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ('szr-migrate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $temp | Out-Null
$originalLocalAppData = $env:LOCALAPPDATA
$env:SZR_HOST_OPERATION = $null
$pwshPath = (Get-Process -Id $PID).Path
$url = 'https://github.com/AbsoluteZeroDev'
$legacyRunner = $Config.linux.container
$legacyDocker = $Config.linux.docker.container
$newRunner = "$legacyRunner-01"
$newDocker = "$legacyDocker-01"
$legacyRunnerId = 'c' * 64
$legacyDockerId = 'd' * 64
$imageId = 'sha256:' + ('e' * 64)

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

# Both fakes honour kill.json {pattern, skip}: the matching call (after skipping that many) kills the command that made it,
# which is how a run is interrupted inside a step.
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
# The fake GitHub keeps world.json: runners [{id, name, status, busy, labels [{name, type}]}].
$fakeGh = $killHelper + @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
Invoke-FakeKill $dir $line
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
# The fake Docker keeps docker.json: containers [{id, name, image, running, restart, labels}], images {ref: id}, networks,
# busy (exec pgrep answers busy), failOn (regexes whose calls fail), unknownFor (refs whose inspect cannot be answered),
# violations (calls after which both runner containers were running).
$fakeDocker = $killHelper + @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'docker.log') -Value $line
Invoke-FakeKill $dir $line
$path = Join-Path $dir 'docker.json'
$state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
foreach ($pattern in @($state.failOn)) { if ($pattern -and $line -match $pattern) { [Console]::Error.WriteLine("fake docker: failing $line"); exit 1 } }
function Find-Container([string] $Ref) { @($state.containers | Where-Object { $_.id -eq $Ref -or $_.name -eq $Ref }) | Select-Object -First 1 }
function Save-State {
    $running = @($state.containers | Where-Object { $_.name -in $env:FAKE_RUNNER_NAMES.Split(',') -and $_.running })
    if ($running.Count -gt 1) { $state.violations = @(@($state.violations) + $line) }
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
}
function Write-Missing([string] $Ref) { [Console]::Error.WriteLine("Error response from daemon: No such container: $Ref"); exit 1 }
switch ($args[0]) {
    'info' { 'fake docker'; exit 0 }
    'image' {
        $ref = $args[-1]
        $id = $state.images.$ref
        if (-not $id) { [Console]::Error.WriteLine("Error response from daemon: No such image: $ref"); exit 1 }
        $id; exit 0
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
        if ($args[1] -eq 'inspect') { if ($args[2] -in @($state.networks)) { '[]'; exit 0 }; [Console]::Error.WriteLine("network $($args[2]) not found"); exit 1 }
        $state.networks = @(@($state.networks) + $args[2]); Save-State; exit 0
    }
    'volume' { $args[-1]; exit 0 }
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

function Set-World($Fixture, $World) { $World | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'world.json') }
function Get-World($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'world.json') | ConvertFrom-Json }
function Get-Docker($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.GhState 'docker.json') | ConvertFrom-Json }
function Set-Docker($Fixture, $State) { $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'docker.json') }
function Update-Docker($Fixture, [scriptblock] $Change) { $state = Get-Docker $Fixture; & $Change $state; Set-Docker $Fixture $state }
function Get-Container($Fixture, [string] $Name) { @((Get-Docker $Fixture).containers | Where-Object { $_.name -eq $Name }) }
function Get-Log($Fixture, [string] $Log) { @(Get-Content -LiteralPath (Join-Path $Fixture.GhState $Log) -ErrorAction SilentlyContinue) }
function Get-CustomLabels($Fixture) { @((Get-World $Fixture).runners | ForEach-Object { $_.labels } | Where-Object { $_.type -eq 'custom' } | ForEach-Object name) }
function Get-Inventory($Fixture) { Get-Content -Raw -LiteralPath (Join-Path $Fixture.State 'inventory.json') | ConvertFrom-Json }
function Get-Operation($Fixture) { $path = Join-Path $Fixture.State 'operation.json'; if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } }
function Set-Kill($Fixture, [string] $Pattern, [int] $Skip = 0) { @{ pattern = $Pattern; skip = $Skip } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'kill.json') }

function New-Fixture([hashtable] $Local = @{}, [switch] $Held) {
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
        linux = [ordered]@{ count = 1 }; windows = [ordered]@{ count = 0 }
        lifecycle = [ordered]@{ drainTimeoutMinutes = 1; pollSeconds = 1; startTimeoutSeconds = 4 }
    }
    foreach ($key in $Local.Keys) { $settings[$key] = $Local[$key] }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $directory = Join-Path $clone ($Config.linux.directory -replace '/', '\')
    $fixture = [pscustomobject]@{
        Clone = $clone; Shim = $shim; GhState = $ghState; LocalAppData = $localAppData
        State = (Join-Path $localAppData 'SubZeroDev\Runners\host'); Directory = $directory; Record = (Join-Path $directory 'maintenance.json')
        ComposeFile = (Join-Path $clone 'linux\compose.local.yaml')
    }
    New-Item -ItemType Directory -Path $fixture.State, $directory -Force | Out-Null
    [ordered]@{ agentId = 7; agentName = $Config.linux.name; gitHubUrl = $url; workFolder = '_work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory '.runner')
    if ($Held) { Write-Raw $fixture.Record '{"phase":"held","reason":"hold"}' }
    $slot = [ordered]@{ slotId = 'linux-01'; platform = 'linux'; state = 'active'; legacy = $true; runnerName = $Config.linux.name; runnerId = 7; scope = 'orgs/AbsoluteZeroDev'
        registrationDirectory = $directory
        containers = @([ordered]@{ role = 'runner'; name = $legacyRunner; id = $legacyRunnerId }, [ordered]@{ role = 'docker'; name = $legacyDocker; id = $legacyDockerId }) }
    Write-Raw (Join-Path $fixture.State 'inventory.json') (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @($slot) })
    Set-World $fixture @{ runners = @(@{ id = 7; name = $Config.linux.name; status = 'online'; busy = $false; labels = @(@{ name = 'self-hosted'; type = 'read-only' }, @{ name = 'subzerodev-linux'; type = 'custom' }) }) }
    Set-Docker $fixture ([ordered]@{
            busy = $false; failOn = @(); unknownFor = @(); violations = @(); networks = @($Config.linux.docker.network)
            images = @{ $Config.linux.image = $imageId }
            containers = @(
                [ordered]@{ id = $legacyRunnerId; name = $legacyRunner; image = $imageId; running = $true; restart = 'unless-stopped'; labels = @{} }
                [ordered]@{ id = $legacyDockerId; name = $legacyDocker; image = 'sha256:' + ('f' * 64); running = $true; restart = 'unless-stopped'; labels = @{} })
        })
    $fixture
}
function Use-Fixture($Fixture, [scriptblock] $Body) {
    $old = @{ PATH = $env:PATH; FAKE_GH_DIR = $env:FAKE_GH_DIR; LOCALAPPDATA = $env:LOCALAPPDATA; FAKE_RUNNER_NAMES = $env:FAKE_RUNNER_NAMES }
    try {
        $env:PATH = "$($Fixture.Shim);$($old.PATH)"; $env:FAKE_GH_DIR = $Fixture.GhState; $env:LOCALAPPDATA = $Fixture.LocalAppData
        $env:FAKE_RUNNER_NAMES = "$legacyRunner,$newRunner"
        & $Body
    } finally { $env:PATH = $old.PATH; $env:FAKE_GH_DIR = $old.FAKE_GH_DIR; $env:LOCALAPPDATA = $old.LOCALAPPDATA; $env:FAKE_RUNNER_NAMES = $old.FAKE_RUNNER_NAMES }
}
function Invoke-Script($Fixture, [string] $Script, [string[]] $Arguments) {
    Use-Fixture $Fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone "scripts\$Script") @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
function Invoke-Apply($Fixture, [string[]] $Arguments = @()) { Invoke-Script $Fixture 'Manage-RunnerHost.ps1' (@('-Action', 'Apply') + $Arguments) }

# The state a finished migration leaves.
function Assert-Migrated($Fixture, [switch] $Held) {
    Assert (-not (Get-Operation $Fixture)) 'The operation journal was not removed.'
    $record = @((Get-Inventory $Fixture).slots | Where-Object slotId -EQ 'linux-01')[0]
    $runner = @(Get-Container $Fixture $newRunner)
    $sidecar = @(Get-Container $Fixture $newDocker)
    Assert ($runner.Count -eq 1 -and $runner[0].running) "$newRunner is not running."
    Assert ($sidecar.Count -eq 1 -and $sidecar[0].running) "$newDocker is not running."
    Assert ($runner[0].labels.'dev.subzerodev.runners.slot' -eq 'linux-01' -and $runner[0].labels.'dev.subzerodev.runners.host' -eq 'testhost') 'The new runner lacks the compose labels.'
    $names = @($record.containers | ForEach-Object name)
    Assert ($names[0] -eq $newRunner -and $names[1] -eq $newDocker) "The inventory records $($names -join ', ')."
    Assert ($record.containers[0].id -eq $runner[0].id) 'The inventory does not record the new runner by ID.'
    Assert ($record.legacy -and $record.runnerId -eq 7) 'The slot lost its legacy mark or runner ID.'
    $kept = @($record.keptForRollback)
    Assert ($kept.Count -eq 2 -and $kept[0].id -eq $legacyRunnerId -and $kept[1].id -eq $legacyDockerId -and @($kept | Where-Object state -NE 'kept-for-rollback').Count -eq 0) 'keptForRollback is not the two pre-pool containers.'
    Assert (@($kept | Where-Object restart -NE 'unless-stopped').Count -eq 0) 'keptForRollback lost the original restart policy.'
    foreach ($name in $legacyRunner, $legacyDocker) {
        $c = @(Get-Container $Fixture $name)[0]
        Assert ($c -and -not $c.running -and $c.restart -eq 'no') "$name is not kept stopped with restart off."
    }
    Assert ((Get-Inventory $Fixture).generation -ge 2) 'The inventory generation was not bumped.'
    if ($Held) {
        Assert (Test-Path -LiteralPath $Fixture.Record) 'The owner''s hold was ended.'
        Assert ((Get-Content -Raw -LiteralPath $Fixture.Record) -match '"held"') 'The owner''s hold record was rewritten.'
    } else {
        Assert (-not (Test-Path -LiteralPath $Fixture.Record)) 'Maintenance was not ended.'
        Assert ((Get-CustomLabels $Fixture) -contains 'subzerodev-linux') 'The runner labels were not restored.'
    }
    Assert ((Get-Content -Raw -LiteralPath $Fixture.ComposeFile) -match "(?m)^  linux-01:") 'The compose file has no linux-01 service.'
    Assert (@((Get-Docker $Fixture).violations).Count -eq 0) "Both runners ran at once after: $(@((Get-Docker $Fixture).violations) -join ' | ')"
}
# The state a rollback (or a refusal before anything changed) leaves.
function Assert-PrePool($Fixture, [switch] $Held) {
    Assert (-not (Get-Operation $Fixture)) 'The operation journal was not removed.'
    $record = @((Get-Inventory $Fixture).slots | Where-Object slotId -EQ 'linux-01')[0]
    Assert ($record.containers[0].name -eq $legacyRunner -and -not $record.PSObject.Properties['keptForRollback']) 'The inventory was changed.'
    Assert ((Get-Inventory $Fixture).generation -eq 1) 'The inventory generation changed.'
    foreach ($name in $legacyRunner, $legacyDocker) {
        $c = @(Get-Container $Fixture $name)[0]
        Assert ($c -and $c.running -and $c.restart -eq 'unless-stopped') "$name is not running with its restart policy."
    }
    Assert (-not @(Get-Container $Fixture $newRunner).Count -and -not @(Get-Container $Fixture $newDocker).Count) 'A new container is left.'
    if ($Held) { Assert (Test-Path -LiteralPath $Fixture.Record) 'The owner''s hold was ended.' }
    else {
        Assert (-not (Test-Path -LiteralPath $Fixture.Record)) 'Maintenance was not ended.'
        Assert ((Get-CustomLabels $Fixture) -contains 'subzerodev-linux') 'The runner labels were not restored.'
    }
    Assert (@((Get-Docker $Fixture).violations).Count -eq 0) "Both runners ran at once after: $(@((Get-Docker $Fixture).violations) -join ' | ')"
}
function Assert-Exit($Result, [int] $Code, [string] $Pattern) {
    Assert ($Result.ExitCode -eq $Code) "Exit $($Result.ExitCode), expected $Code`: $($Result.Output)"
    if ($Pattern) { Assert ($Result.Output -match $Pattern) "Output does not match '$Pattern': $($Result.Output)" }
}

# --- migration --------------------------------------------------------------------------------------------------------

Test-Case 'Apply migrates linux-01 onto compose with the same registration, never running both runners, and keeps the pre-pool containers' {
    $f = New-Fixture
    $result = Invoke-Apply $f
    Assert-Exit $result 0 'commit: done'
    Assert-Migrated $f
    # The pre-pool runner was drained (labels withdrawn) before it stopped, and stopped before the new one was created.
    $calls = Get-Log $f 'docker.log'
    $stop = [array]::IndexOf($calls, @($calls | Where-Object { $_ -like "stop *$legacyRunnerId" })[0])
    $up = [array]::IndexOf($calls, @($calls | Where-Object { $_ -match 'compose .* up -d --no-deps linux-01$' })[0])
    Assert ($stop -ge 0 -and $up -gt $stop) 'The new runner was created before the pre-pool runner stopped.'
    Assert (@(Get-Log $f 'calls.log' | Where-Object { $_ -match '-X DELETE' }).Count -ge 1) 'Admission was not closed for the drain.'
    $again = Invoke-Apply $f
    Assert-Exit $again 0 'Nothing to migrate'
    $plan = Invoke-Script $f 'Manage-RunnerHost.ps1' @('-Action', 'Plan', '-Json')
    $changes = @(($plan.Output -replace '(?s)^[^{]*', '' | ConvertFrom-Json).changes)
    Assert (-not @($changes | Where-Object kind -EQ 'migrate-legacy-linux').Count) 'Plan still proposes the migration.'
    Assert (@($changes | Where-Object kind -EQ 'prune-kept').Count -eq 1) 'Plan does not propose pruning the kept containers.'
}

Test-Case 'A slot the owner held stays held through the migration, and GitHub labels are not touched' {
    $f = New-Fixture -Held
    $world = Get-World $f; $world.runners[0].status = 'offline'; Set-World $f $world
    $result = Invoke-Apply $f
    Assert-Exit $result 0 'stays held'
    Assert-Migrated $f -Held
    Assert (-not @(Get-Log $f 'calls.log' | Where-Object { $_ -match '/labels' }).Count) 'Labels were changed on a held runner.'
}

foreach ($point in @(
        @{ Step = 'drain'; Pattern = 'exec .* pgrep' }
        @{ Step = 'stop-legacy'; Pattern = "^stop .*$legacyDockerId" }
        @{ Step = 'compose-up'; Pattern = 'compose .* up -d --no-deps linux-01$' }
        @{ Step = 'end-maintenance'; Pattern = '-X POST .*labels' })) {
    Test-Case "A run killed in $($point.Step) is finished by rerunning Apply" {
        $f = New-Fixture
        Set-Kill $f $point.Pattern
        $killed = Invoke-Apply $f
        Assert ($killed.ExitCode -ne 0) "The killed run exited 0: $($killed.Output)"
        Assert (@(Get-Log $f 'killed.log').Count -eq 1) 'The run was not killed.'
        $operation = Get-Operation $f
        Assert ($operation -and (@($operation.steps | Where-Object name -EQ $point.Step)[0].state -eq 'pending')) "The journal does not show $($point.Step) unfinished."
        $result = Invoke-Apply $f
        Assert-Exit $result 0 'Resuming operation'
        Assert-Migrated $f
    }
}

Test-Case 'A failed compose up keeps the journal and the pre-pool runner stopped and held; rerunning Apply finishes it' {
    $f = New-Fixture
    Update-Docker $f { param($s) $s.failOn = @('compose .* up') }
    $failed = Invoke-Apply $f
    Assert-Exit $failed 1 'compose up linux-01-docker exited'
    Assert ((Get-Operation $f)) 'The journal was removed.'
    Assert (Test-Path -LiteralPath $f.Record) 'Maintenance was ended after a failure.'
    Assert (-not @(Get-Container $f $legacyRunner)[0].running) 'The pre-pool runner was started again.'
    Update-Docker $f { param($s) $s.failOn = @() }
    Assert-Exit (Invoke-Apply $f) 0 'Resuming operation'
    Assert-Migrated $f
}

Test-Case 'A drain that times out deletes the journal, changes nothing and reopens admission' {
    $f = New-Fixture
    Update-Docker $f { param($s) $s.busy = $true }
    $result = Invoke-Apply $f
    Assert-Exit $result 1 'migration was not started'
    Assert (-not (Get-Operation $f)) 'The journal was kept after a timed-out drain.'
    Assert (-not (Test-Path -LiteralPath $f.Record)) 'Maintenance was kept after a timed-out drain.'
    Assert ((Get-CustomLabels $f) -contains 'subzerodev-linux') 'Admission was not reopened.'
    Assert (@(Get-Container $f $legacyRunner)[0].running) 'The pre-pool runner was stopped.'
}

# --- rollback ---------------------------------------------------------------------------------------------------------

Test-Case 'Apply -Rollback after a failed verify removes the new containers, restarts the pre-pool ones and ends maintenance' {
    $f = New-Fixture
    $world = Get-World $f; $world.runners[0].status = 'offline'; Set-World $f $world
    $failed = Invoke-Apply $f
    Assert-Exit $failed 1 'stopped at verify'
    Assert ((Get-Operation $f)) 'The journal was removed after a failed verify.'
    $refused = Invoke-Apply $f @('-Prune')
    Assert-Exit $refused 1 'unfinished'
    $result = Invoke-Apply $f @('-Rollback')
    Assert-Exit $result 0 'Rolled back'
    Assert-PrePool $f
    Assert (-not (Test-Path -LiteralPath $f.ComposeFile)) 'The compose file still lists linux-01.'
    Assert-Exit (Invoke-Apply $f @('-Rollback')) 0 'nothing to roll back'
}

Test-Case 'Apply -Rollback after a kill in stop-legacy restarts the pre-pool containers; a held slot stays held' {
    $f = New-Fixture -Held
    Set-Kill $f "^stop .*$legacyDockerId"
    Assert ((Invoke-Apply $f).ExitCode -ne 0) 'The killed run exited 0.'
    Assert-Exit (Invoke-Apply $f @('-Rollback')) 0 'still held'
    Assert-PrePool $f -Held
}

Test-Case 'Apply refuses to resume a rollback, and -Rollback is refused once the migration is verified' {
    $f = New-Fixture
    Set-Kill $f '-X POST .*labels'
    Assert ((Invoke-Apply $f).ExitCode -ne 0) 'The killed run exited 0.'
    Assert-Exit (Invoke-Apply $f) 0 'Resuming operation'
    Assert-Migrated $f
    # A verified journal: rebuild one by hand from a fresh fixture.
    $g = New-Fixture
    Set-Kill $g '-X POST .*labels'
    Invoke-Apply $g | Out-Null
    $operation = Get-Content -Raw -LiteralPath (Join-Path $g.State 'operation.json') | ConvertFrom-Json
    $operation | Add-Member -Force -NotePropertyName rollingBack -NotePropertyValue $true
    $operation | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $g.State 'operation.json')
    Assert-Exit (Invoke-Apply $g) 1 'being rolled back'
    $operation.rollingBack = $false
    foreach ($step in $operation.steps) { if ($step.name -in 'end-maintenance', 'verify') { $step.state = 'done' } }
    $operation | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $g.State 'operation.json')
    Assert-Exit (Invoke-Apply $g @('-Rollback')) 1 'was verified'
    Assert ((Get-Operation $g)) 'A refused rollback removed the journal.'
}

# --- refusals before anything changes ---------------------------------------------------------------------------------

Test-Case 'A foreign container at a target name is refused before anything changes' {
    $f = New-Fixture
    Update-Docker $f { param($s) $s.containers = @(@($s.containers) + [pscustomobject]@{ id = '9' * 64; name = $newRunner; image = $imageId; running = $false; restart = 'no'; labels = [pscustomobject]@{} }) }
    $result = Invoke-Apply $f
    Assert-Exit $result 1 'not this host''s compose linux-01. Nothing was changed'
    Assert (-not (Get-Operation $f)) 'A journal was written.'
    Assert (-not (Test-Path -LiteralPath $f.Record)) 'Maintenance was entered.'
    Assert (@(Get-Container $f $legacyRunner)[0].running) 'The pre-pool runner was stopped.'
    Assert (@(Get-Container $f $newRunner).Count -eq 1) 'The foreign container was touched.'
}

Test-Case 'A recorded pre-pool container that was renamed, or a missing image, is refused before anything changes' {
    $f = New-Fixture
    Update-Docker $f { param($s) @($s.containers | Where-Object id -EQ $legacyDockerId)[0].name = 'someone-else' }
    Assert-Exit (Invoke-Apply $f) 1 'is now named someone-else'
    Assert (-not (Get-Operation $f)) 'A journal was written.'
    $g = New-Fixture
    Update-Docker $g { param($s) $s.images = @{} }
    Assert-Exit (Invoke-Apply $g) 1 'not built'
    Assert (-not (Get-Operation $g) -and -not (Test-Path -LiteralPath $g.Record)) 'Something changed before the image check.'
}

Test-Case 'New-LinuxRunner refuses while the migration is unfinished' {
    $f = New-Fixture
    Update-Docker $f { param($s) $s.failOn = @('compose .* up') }
    Invoke-Apply $f | Out-Null
    Assert ((Get-Operation $f)) 'No unfinished operation to test with.'
    $result = Invoke-Script $f 'New-LinuxRunner.ps1' @()
    Assert-Exit $result 1 'Refused: the unfinished operation migrate-legacy-linux'
}

# --- prune ------------------------------------------------------------------------------------------------------------

Test-Case 'Apply -Prune removes the kept pre-pool containers by recorded ID and empties keptForRollback' {
    $f = New-Fixture
    Assert-Exit (Invoke-Apply $f) 0
    $result = Invoke-Apply $f @('-Prune')
    Assert-Exit $result 0 "removed $legacyRunner"
    Assert (-not @(Get-Container $f $legacyRunner).Count -and -not @(Get-Container $f $legacyDocker).Count) 'A pre-pool container is left.'
    $record = @((Get-Inventory $f).slots | Where-Object slotId -EQ 'linux-01')[0]
    Assert (-not @($record.keptForRollback).Count) 'keptForRollback was not emptied.'
    Assert (@(Get-Container $f $newRunner)[0].running) 'The new runner was touched.'
    Assert-Exit (Invoke-Apply $f @('-Prune')) 0 'nothing to prune'
}

Test-Case 'Prune keeps a renamed, running or unknown container and drops one that is gone, never removing by name alone' {
    $f = New-Fixture
    Assert-Exit (Invoke-Apply $f) 0
    # The runner was renamed; the sidecar is running.
    Update-Docker $f { param($s)
        @($s.containers | Where-Object id -EQ $legacyRunnerId)[0].name = 'renamed-runner'
        @($s.containers | Where-Object id -EQ $legacyDockerId)[0].running = $true
    }
    $result = Invoke-Apply $f @('-Prune')
    Assert-Exit $result 1 'now named renamed-runner'
    Assert ($result.Output -match 'it is running') "The running sidecar was not reported: $($result.Output)"
    Assert (@((Get-Docker $f).containers | Where-Object id -In $legacyRunnerId, $legacyDockerId).Count -eq 2) 'A kept container was removed.'
    Assert (@(@((Get-Inventory $f).slots | Where-Object slotId -EQ 'linux-01')[0].keptForRollback).Count -eq 2) 'A kept record was dropped.'
    # Unknown, then gone with another container under its old name.
    Update-Docker $f { param($s)
        $s.unknownFor = @($legacyDockerId)
        $s.containers = @(@($s.containers | Where-Object id -NE $legacyRunnerId) + [pscustomobject]@{ id = '8' * 64; name = $legacyRunner; image = $imageId; running = $false; restart = 'no'; labels = [pscustomobject]@{} })
    }
    $result = Invoke-Apply $f @('-Prune')
    Assert-Exit $result 1 'unknown'
    Assert ($result.Output -match 'already gone; record dropped') "The gone container was not dropped: $($result.Output)"
    Assert (@(Get-Container $f $legacyRunner).Count -eq 1) 'A container was removed by name alone.'
    $kept = @(@((Get-Inventory $f).slots | Where-Object slotId -EQ 'linux-01')[0].keptForRollback)
    Assert ($kept.Count -eq 1 -and $kept[0].id -eq $legacyDockerId) 'keptForRollback is not just the unknown sidecar.'
}

# --- result -----------------------------------------------------------------------------------------------------------

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host "$($cases.Count - $failed.Count)/$($cases.Count) passed"
if ($failed.Count) { exit 1 }
# The fakes deliberately fail some native calls, and GitHub's pwsh wrapper exits with the last LASTEXITCODE.
exit 0
