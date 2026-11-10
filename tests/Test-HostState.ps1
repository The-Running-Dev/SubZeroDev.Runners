#Requires -Version 7.2
# Tests for the host state of the runner pool (S2): scripts\HostState.ps1 (state files, atomic writes, the host lock) and
# scripts\Manage-RunnerHost.ps1 (Init, Adopt, Plan, Status), and the setup refusal once the manager owns the host.
#   - a state file is absent, readable or unreadable; an unreadable one is never treated as absent or empty;
#   - state is written only under the host lock, and atomically: a writer killed mid-write leaves the previous file whole;
#   - Adopt records only registrations GitHub proves (agentId = GitHub's id for that name) and writes nothing when GitHub or
#     Docker cannot be read; Plan and Status change nothing, take no lock and make only read calls;
#   - Status reports what GitHub says (offline) and nothing about why;
#   - the lock waits, joins (a child of a joinable holder) and ignores a stale token.
# Every case uses its own LOCALAPPDATA, so the lock and state of this machine are never touched. GitHub and Docker are a fake
# gh and docker first on PATH.
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
. (Join-Path $repo 'scripts\Registration.ps1')
. (Join-Path $repo 'scripts\Lifecycle.ps1')

$temp = Join-Path ([IO.Path]::GetTempPath()) ('szr-hoststate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
        # A failed case must not leave this process holding a lock or pointing at a case directory.
        while ($global:SubZeroDevHostLock) { Exit-HostLock }
        $env:LOCALAPPDATA = $originalLocalAppData
        $env:SZR_HOST_OPERATION = $null
    }
}
function New-CaseDirectory { $directory = Join-Path $temp ([guid]::NewGuid().ToString('N').Substring(0, 12)); New-Item -ItemType Directory -Path $directory | Out-Null; $directory }
# A LOCALAPPDATA of the case's own, with the host state directory created. Returns the state directory.
function Use-CaseLocalAppData {
    $env:LOCALAPPDATA = New-CaseDirectory
    $state = Get-HostStateDirectory
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $state
}
function Write-Raw([string] $Path, [string] $Text) { [IO.File]::WriteAllText($Path, $Text) }
function ConvertTo-StateJson([string] $Schema, [hashtable] $Value, [int] $Version = 1) {
    $copy = [ordered]@{ schema = $Schema; version = $Version }
    foreach ($key in $Value.Keys) { $copy[$key] = $Value[$key] }
    ConvertTo-Json -InputObject $copy -Depth 20
}

# --- state files ------------------------------------------------------------------------------------------------------

Test-Case 'Read-HostStateFile: a missing file is absent; bad JSON, another schema or version 2 are unreadable; a good one is readable' {
    $state = Use-CaseLocalAppData
    $path = Join-Path $state 'inventory.json'
    $read = Read-HostStateFile $path $HostInventorySchema
    Assert ($read.State -eq 'absent' -and $null -eq $read.Value) "A missing file read as $($read.State)."
    Write-Raw $path '{ not json'
    $read = Read-HostStateFile $path $HostInventorySchema
    Assert ($read.State -eq 'unreadable' -and $read.Reason -match 'not valid JSON') "Bad JSON read as $($read.State) ($($read.Reason))."
    Write-Raw $path '[1, 2]'
    Assert ((Read-HostStateFile $path $HostInventorySchema).State -eq 'unreadable') 'A JSON array was not unreadable.'
    Write-Raw $path (ConvertTo-StateJson $HostOperationSchema @{ id = 'x' })
    $read = Read-HostStateFile $path $HostInventorySchema
    Assert ($read.State -eq 'unreadable' -and $read.Reason -match 'schema') "Another schema read as $($read.State) ($($read.Reason))."
    Write-Raw $path (ConvertTo-StateJson $HostInventorySchema @{ generation = 1 } -Version 2)
    $read = Read-HostStateFile $path $HostInventorySchema
    Assert ($read.State -eq 'unreadable' -and $read.Reason -match 'version') "Version 2 read as $($read.State) ($($read.Reason))."
    Write-Raw $path (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; slots = @() })
    $read = Read-HostStateFile $path $HostInventorySchema
    Assert ($read.State -eq 'readable' -and $read.Value.generation -eq 1) "A good file read as $($read.State) ($($read.Reason))."
}

Test-Case 'Host state is written only under the host lock, with its schema and version' {
    $state = Use-CaseLocalAppData
    $path = Get-HostInventoryPath
    Write-Raw $path 'original'
    Assert-Throws { Write-HostInventory ([ordered]@{ generation = 2; slots = @() }) } 'only under the host lock' 'An inventory was written without the lock.'
    Assert ([IO.File]::ReadAllText($path) -eq 'original') 'The refused write changed the file.'
    Assert-Throws { Remove-HostOperation } 'only under the host lock' 'The journal was removed without the lock.'
    Use-HostLock -Kind 'test' -ScriptBlock { Write-HostInventory ([ordered]@{ generation = 2; slots = @() }) }
    $read = Read-HostInventory
    Assert ($read.State -eq 'readable' -and $read.Value.generation -eq 2 -and $read.Value.updatedUtc) "The inventory written under the lock read as $($read.State) ($($read.Reason))."
    Assert (-not (Test-HostLockHeld) -and -not (Test-Path -LiteralPath (Get-HostLockRecordPath))) 'Use-HostLock did not release the lock and remove lock.json.'
    Assert ($state) 'unused'
}

Test-Case 'A writer killed mid-write leaves the previous file whole (6 kills at random points)' {
    $directory = New-CaseDirectory
    $target = Join-Path $directory 'state.json'
    $writer = Join-Path $directory 'writer.ps1'
    Set-Content -LiteralPath $writer -Value @(
        'param([string] $Path, [string] $RunnerConfig)'
        '$ErrorActionPreference = ''Stop'''
        '. $RunnerConfig'
        '$pad = ''x'' * 2000000'
        'for ($i = 1; ; $i++) { Write-FileAtomic $Path (@{ n = $i; pad = $pad } | ConvertTo-Json -Compress) }')
    $config = Join-Path $repo 'scripts\RunnerConfig.ps1'
    $writes = @()
    foreach ($round in 1..6) {
        $process = Start-Process -FilePath $pwshPath -ArgumentList "-NoLogo -NoProfile -File `"$writer`" -Path `"$target`" -RunnerConfig `"$config`"" -PassThru -WindowStyle Hidden
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path -LiteralPath $target) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Assert (-not $process.HasExited) "The writer exited early (exit $($process.ExitCode))."
            Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 400)
        } finally { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; $process.WaitForExit(10000) | Out-Null }
        $value = $null
        try { $value = [IO.File]::ReadAllText($target) | ConvertFrom-Json } catch { throw "After kill $round the file does not parse: $($_.Exception.Message)" }
        Assert ($value.n -is [long] -or $value.n -is [int]) "After kill $round the file has no whole n."
        Assert ($value.pad.Length -eq 2000000) "After kill $round the file is cut short ($($value.pad.Length) characters of padding)."
        $writes += $value.n
    }
    Assert ($writes.Count -eq 6) 'Not every round was checked.'
}

Test-Case 'Apply, Resume, Hold and Prune refuse without a readable inventory or with an unreadable journal' {
    $state = Use-CaseLocalAppData
    $inventory = Get-HostInventoryPath
    $operation = Get-HostOperationPath
    foreach ($name in 'Apply', 'Resume', 'Hold', 'Prune') {
        Remove-Item -LiteralPath $inventory, $operation -Force -ErrorAction SilentlyContinue
        Assert-Throws { Assert-HostInventoryUsable -Action $name } "^$name refused: there is no host inventory" "$name ran without an inventory."
        Write-Raw $inventory '{ broken'
        Assert-Throws { Assert-HostInventoryUsable -Action $name } "^$name refused: the host inventory .* cannot be read" "$name ran on an unreadable inventory."
        Write-Raw $inventory (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; slots = @() } -Version 2)
        Assert-Throws { Assert-HostInventoryUsable -Action $name } 'cannot be read' "$name ran on an inventory of another version."
        Write-Raw $inventory (ConvertTo-StateJson $HostInventorySchema @{ generation = 4; slots = @() })
        Write-Raw $operation 'not json'
        Assert-Throws { Assert-HostInventoryUsable -Action $name } "^$name refused: the operation journal .* cannot be read" "$name ran with an unreadable journal."
        Write-Raw $operation (ConvertTo-StateJson $HostOperationSchema @{ id = 'op'; kind = 'add'; slotId = 'linux-02'; steps = @() })
        $value = Assert-HostInventoryUsable -Action $name
        Assert ($value.generation -eq 4) "$name did not return the inventory."
    }
    Assert ($state) 'unused'
}

# --- the lock -----------------------------------------------------------------------------------------------------------

Test-Case 'The host lock is re-entrant and removes lock.json at the last exit' {
    Use-CaseLocalAppData | Out-Null
    Enter-HostLock -Kind 'outer'
    Enter-HostLock -Kind 'inner'
    Assert ($global:SubZeroDevHostLock.Depth -eq 2) "Depth is $($global:SubZeroDevHostLock.Depth), not 2."
    $record = Read-HostLockRecord
    Assert ($record.State -eq 'readable' -and $record.Value.pid -eq $PID -and $record.Value.kind -eq 'outer') 'lock.json does not name this process.'
    Exit-HostLock
    Assert ((Test-HostLockHeld) -and (Test-Path -LiteralPath (Get-HostLockRecordPath))) 'The first exit released the lock.'
    Exit-HostLock
    Assert (-not (Test-HostLockHeld)) 'The last exit did not release the lock.'
    Assert (-not (Test-Path -LiteralPath (Get-HostLockRecordPath))) 'lock.json was left after the last exit.'
}

Test-Case 'The lock name follows the state directory, so another LOCALAPPDATA is another lock' {
    $env:LOCALAPPDATA = New-CaseDirectory
    $first = Get-HostLockName
    $env:LOCALAPPDATA = New-CaseDirectory
    $second = Get-HostLockName
    Assert ($first -ne $second) "Two state directories share the lock $first."
    Assert ($first -match '^Local\\SubZeroDev\.Runners\.Host\.[0-9a-f]{16}$') "The lock name $first is not the documented form."
}

Test-Case 'A stale token (holder gone, or another process under the same pid) is not joined and is restored afterwards' {
    foreach ($stale in @(
            @{ Pid = $PID; Start = '2000-01-01T00:00:00.0000000Z'; Label = 'same pid, other start time' }
            @{ Pid = 2147483000; Start = '2000-01-01T00:00:00.0000000Z'; Label = 'no such process' })) {
        Use-CaseLocalAppData | Out-Null
        Write-Raw (Get-HostLockRecordPath) (ConvertTo-StateJson $HostLockSchema @{ token = 'stale-token'; pid = $stale.Pid; processStartUtc = $stale.Start; kind = 'old'; startedUtc = '2000-01-01T00:00:00.0000000Z' })
        $env:SZR_HOST_OPERATION = 'stale-token'
        Enter-HostLock -Kind 'test'
        try {
            Assert (-not $global:SubZeroDevHostLock.Joined) "A stale token was joined ($($stale.Label))."
            Assert (-not $env:SZR_HOST_OPERATION) "The inherited token was left set while holding the lock ($($stale.Label))."
            $record = Read-HostLockRecord
            Assert ($record.State -eq 'readable' -and $record.Value.pid -eq $PID -and $null -eq $record.Value.token) "lock.json was not replaced by this holder ($($stale.Label))."
        } finally { Exit-HostLock }
        Assert ($env:SZR_HOST_OPERATION -eq 'stale-token') "The inherited token was not restored ($($stale.Label))."
        Assert (-not (Test-Path -LiteralPath (Get-HostLockRecordPath))) "lock.json was left ($($stale.Label))."
        $env:SZR_HOST_OPERATION = $null
    }
}

Test-Case 'Maintenance is ended at the end of an operation only when it recorded heldBefore false' {
    $saved = ${function:Exit-RunnerMaintenance}
    $script:exited = $null
    Set-Item -Path function:script:Exit-RunnerMaintenance -Value { param($StateFile, $RunnerDirectory) $script:exited = $StateFile; $true }
    try {
        $step = { param($held) [pscustomobject]@{ name = 'stop'; state = 'done'; facts = [pscustomobject]@{ heldBefore = $held } } }
        $ended = Complete-OperationMaintenance (& $step $true) 'C:\x\maintenance.json' 'C:\x'
        Assert ($ended -eq $false -and $null -eq $script:exited) 'Maintenance the owner held before was ended.'
        Assert-Throws { Complete-OperationMaintenance ([pscustomobject]@{ name = 'stop'; facts = [pscustomobject]@{} }) 'C:\x\maintenance.json' 'C:\x' } 'does not record heldBefore' 'A step without heldBefore ended maintenance.'
        Assert-Throws { Complete-OperationMaintenance (& $step 'false') 'C:\x\maintenance.json' 'C:\x' } 'not true or false' 'heldBefore given as a string ended maintenance.'
        Assert ($null -eq $script:exited) 'A refused step called Exit-RunnerMaintenance.'
        $ended = Complete-OperationMaintenance (& $step $false) 'C:\x\maintenance.json' 'C:\x'
        Assert ($ended -eq $true -and $script:exited -eq 'C:\x\maintenance.json') 'Maintenance this operation started was not ended.'
    } finally { Set-Item -Path function:script:Exit-RunnerMaintenance -Value $saved }
}

Test-Case 'windows-legacy is not numbered: win01 stays, the next Windows slot is win02' {
    $inventory = [pscustomobject]@{ slots = @(
            [pscustomobject]@{ slotId = 'windows-legacy'; platform = 'windows'; state = 'active' }
            [pscustomobject]@{ slotId = 'win01'; platform = 'windows'; state = 'active' }) }
    $numbers = @(Get-SlotNumbers 'windows' 2 $inventory)
    Assert (($numbers -join ',') -eq '1,2') "Slot numbers are $($numbers -join ','), not 1,2."
    $slots = @(Get-WindowsSlots $Config $inventory 2 -InstallRoot 'C:\nowhere')
    Assert ($slots.Count -eq 2 -and $slots[0].SlotId -eq 'win01' -and -not $slots[0].New -and $slots[1].SlotId -eq 'win02' -and $slots[1].New) "Windows slots are $(($slots | ForEach-Object { "$($_.SlotId) new=$($_.New)" }) -join '; ')."
}

# --- entry points (child processes, a fake gh and docker first on PATH, a LOCALAPPDATA of their own) ----------------------

# The fake GitHub reads world.json: runners, groups, groupRepos {id: [repo]}, groupRunners {id: [runnerId]}, and fail (a
# regex: a matching call fails). The fake Docker reads docker.json: unavailable, containers {name: {Id, Image, Labels}},
# images {ref: id}. Both log every call.
$fakeGh = @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
$world = Get-Content -Raw -LiteralPath (Join-Path $dir 'world.json') | ConvertFrom-Json
if ($world.fail -and $line -match $world.fail) { [Console]::Error.WriteLine('HTTP 502: Bad Gateway (fake)'); exit 1 }
if ($line -match '-X (POST|PUT|PATCH|DELETE)') { exit 0 }
$emit = { param($items) foreach ($item in @($items)) { if ($null -ne $item) { $item | ConvertTo-Json -Compress -Depth 8 } } }
if ($line -match 'runner-groups/(\d+)/repositories') { & $emit $world.groupRepos.($Matches[1]); exit 0 }
if ($line -match 'runner-groups/(\d+)/runners') { foreach ($id in @($world.groupRunners.($Matches[1]))) { if ($null -ne $id) { "$id" } }; exit 0 }
if ($line -match 'actions/runner-groups') { & $emit $world.groups; exit 0 }
if ($line -match 'actions/runners') { & $emit $world.runners; exit 0 }
exit 0
'@
$fakeDocker = @'
$dir = $env:FAKE_GH_DIR
Add-Content -LiteralPath (Join-Path $dir 'docker.log') -Value ($args -join ' ')
$state = Get-Content -Raw -LiteralPath (Join-Path $dir 'docker.json') | ConvertFrom-Json
if ($state.unavailable) { [Console]::Error.WriteLine('error during connect: the Docker daemon is not running (fake)'); exit 1 }
$name = $args[-1]
if ($args[0] -eq 'container' -and $args[1] -eq 'inspect') {
    $container = $state.containers.$name
    if (-not $container) { [Console]::Error.WriteLine("Error: No such container: $name"); exit 1 }
    if ($args -contains '--format') { 'true'; exit 0 }
    ConvertTo-Json -Compress -Depth 8 -InputObject @([pscustomobject]@{ Id = $container.Id; Name = "/$name"; Image = $container.Image; Config = [pscustomobject]@{ Labels = $container.Labels } })
    exit 0
}
if ($args[0] -eq 'image' -and $args[1] -eq 'inspect') {
    $id = $state.images.$name
    if (-not $id) { [Console]::Error.WriteLine("Error: No such image: $name"); exit 1 }
    $id
    exit 0
}
[Console]::Error.WriteLine("fake docker: unexpected call $($args -join ' ')")
exit 1
'@
function New-Hex([string] $Seed) { -join ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Seed)) | ForEach-Object { $_.ToString('x2') }) }
function New-Runner([int64] $Id, [string] $Name, [string] $Status = 'online') { [ordered]@{ id = $Id; name = $Name; status = $Status; busy = $false; labels = @() } }
$imageId = 'sha256:' + (New-Hex 'image')

function New-HostFixture([hashtable] $Local = @{}) {
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
        buildAgent = [ordered]@{ docker = [ordered]@{ cli = (Join-Path $shim 'docker.cmd') } }
        linux = [ordered]@{ count = 1 }; windows = [ordered]@{ count = 1 }
    }
    foreach ($key in $Local.Keys) { $settings[$key] = $Local[$key] }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $fixture = [pscustomobject]@{
        Clone = $clone; Shim = $shim; GhState = $ghState; LocalAppData = $localAppData
        InstallRoot = (Join-Path $localAppData 'SubZeroDev\Runners'); State = (Join-Path $localAppData 'SubZeroDev\Runners\host')
    }
    Set-World $fixture @{ runners = @(); groups = @([ordered]@{ id = 1; name = 'Default'; visibility = 'all'; allows_public_repositories = $false }); groupRepos = @{}; groupRunners = @{}; fail = $null }
    Set-Docker $fixture @{ unavailable = $false; containers = @{}; images = @{} }
    $fixture
}
function Set-World($Fixture, [hashtable] $World) { $World | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'world.json') }
function Set-Docker($Fixture, [hashtable] $State) { $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Fixture.GhState 'docker.json') }
function Get-Calls($Fixture, [string] $Log = 'calls.log') { @(Get-Content -LiteralPath (Join-Path $Fixture.GhState $Log) -ErrorAction SilentlyContinue) }
function Clear-Calls($Fixture) { Remove-Item -LiteralPath (Join-Path $Fixture.GhState 'calls.log'), (Join-Path $Fixture.GhState 'docker.log') -Force -ErrorAction SilentlyContinue }
function Write-Registration([string] $Directory, [int64] $Id, [string] $Name) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    [ordered]@{ agentId = $Id; agentName = $Name; gitHubUrl = $url; workFolder = '_work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory '.runner')
}
function Write-FixtureState($Fixture, [string] $File, [string] $Text) {
    New-Item -ItemType Directory -Path $Fixture.State -Force | Out-Null
    Write-Raw (Join-Path $Fixture.State $File) $Text
}
function Get-StateListing($Fixture) {
    if (-not (Test-Path -LiteralPath $Fixture.State)) { return '' }
    (@(Get-ChildItem -LiteralPath $Fixture.State -File | Sort-Object Name | ForEach-Object { "$($_.Name)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }) -join ';')
}
function Use-FixtureEnvironment($Fixture, [scriptblock] $Body) {
    $old = @{ PATH = $env:PATH; FAKE_GH_DIR = $env:FAKE_GH_DIR; LOCALAPPDATA = $env:LOCALAPPDATA }
    try {
        $env:PATH = "$($Fixture.Shim);$($old.PATH)"; $env:FAKE_GH_DIR = $Fixture.GhState; $env:LOCALAPPDATA = $Fixture.LocalAppData
        & $Body
    } finally { $env:PATH = $old.PATH; $env:FAKE_GH_DIR = $old.FAKE_GH_DIR; $env:LOCALAPPDATA = $old.LOCALAPPDATA }
}
function Invoke-HostScript($Fixture, [string] $Script, [string[]] $Arguments) {
    Use-FixtureEnvironment $Fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone "scripts\$Script") @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
}
function Invoke-Manager($Fixture, [string[]] $Arguments) { Invoke-HostScript $Fixture 'Manage-RunnerHost.ps1' $Arguments }
function Get-JsonOutput($Run) {
    $start = $Run.Output.IndexOf('{')
    Assert ($start -ge 0) "No JSON in the output (exit $($Run.ExitCode)):`n$($Run.Output)"
    $Run.Output.Substring($start, $Run.Output.LastIndexOf('}') - $start + 1) | ConvertFrom-Json
}
# A child started in the background with stdout and stderr in files (the lock cases watch it while it runs).
function Start-HostScript($Fixture, [string] $Script, [string[]] $Arguments) {
    $stdout = Join-Path $Fixture.Clone ('out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    Use-FixtureEnvironment $Fixture {
        $process = Start-Process -FilePath $pwshPath -ArgumentList "-NoLogo -NoProfile -File `"$(Join-Path $Fixture.Clone "scripts\$Script")`" $quoted" -RedirectStandardOutput $stdout -RedirectStandardError "$stdout.err" -PassThru -WindowStyle Hidden
        [pscustomobject]@{ Process = $process; Stdout = $stdout; Stderr = "$stdout.err" }
    }
}
function Get-ChildText($Child) { (@((Get-Content -Raw -LiteralPath $Child.Stdout -ErrorAction SilentlyContinue), (Get-Content -Raw -LiteralPath $Child.Stderr -ErrorAction SilentlyContinue)) | Where-Object { $_ }) -join "`n" }
function Wait-ChildText($Child, [string] $Pattern, [int] $Seconds = 60) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Get-ChildText $Child) -match $Pattern) { return $true }
        if ($Child.Process.HasExited) { return ((Get-ChildText $Child) -match $Pattern) }
        Start-Sleep -Milliseconds 200
    }
    $false
}

# The host the Adopt cases prove: the pre-pool Linux runner (id 7), a linux/runner-02 whose .runner says id 9 while GitHub
# says 10 (not proven), this checkout's own Windows runner (windows-legacy, id 20), the clone win01 (id 30), and a clone
# win02 that never registered.
# A git checkout with one commit, so the clone-commit comparison of Plan can be read.
function Initialize-GitCheckout([string] $Directory) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    git -C $Directory init -q 2>&1 | Out-Null
    git -C $Directory -c user.email=test@example.invalid -c user.name=test commit -q --allow-empty -m fixture 2>&1 | Out-Null
}
function Initialize-AdoptableHost($Fixture) {
    Initialize-GitCheckout $Fixture.Clone
    Initialize-GitCheckout (Join-Path $Fixture.InstallRoot 'win01\windows')
    Write-Registration (Join-Path $Fixture.Clone 'linux\runner') 7 'subzerodev.runner.linux'
    Write-Registration (Join-Path $Fixture.Clone 'linux\runner-02') 9 'subzerodev.runner.linux.testhost.02'
    Write-Registration (Join-Path $Fixture.Clone 'windows') 20 'subzerodev.runner.windows'
    Write-Registration (Join-Path $Fixture.InstallRoot 'win01\windows') 30 'subzerodev.runner.windows.testhost.win01'
    New-Item -ItemType Directory -Path (Join-Path $Fixture.InstallRoot 'win02\windows') -Force | Out-Null
    Set-World $Fixture @{
        runners = @(
            (New-Runner 7 'subzerodev.runner.linux'), (New-Runner 10 'subzerodev.runner.linux.testhost.02'),
            (New-Runner 20 'subzerodev.runner.windows'), (New-Runner 30 'subzerodev.runner.windows.testhost.win01'))
        groups = @([ordered]@{ id = 1; name = 'Default'; visibility = 'all'; allows_public_repositories = $false })
        groupRepos = @{}; groupRunners = @{ '1' = @(7, 20, 30) }; fail = $null
    }
    Set-Docker $Fixture @{
        unavailable = $false
        containers = @{
            'subzerodev-runner-linux' = @{ Id = (New-Hex 'runner'); Image = $imageId; Labels = @{ 'com.example' = 'x' } }
            'subzerodev-runner-linux-docker' = @{ Id = (New-Hex 'sidecar'); Image = ('sha256:' + (New-Hex 'dind')); Labels = @{} }
            'subzerodev-runner-linux-02' = @{ Id = (New-Hex 'runner-02'); Image = $imageId; Labels = @{} }
        }
        images = @{ 'subzerodev-runner-linux:local' = $imageId }
    }
}

# --- Adopt --------------------------------------------------------------------------------------------------------------

Test-Case 'Adopt records only proven registrations, with full container IDs, using only read calls' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    $run = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($run.ExitCode -eq 0) "Adopt exited $($run.ExitCode).`n$($run.Output)"
    $inventory = Get-Content -Raw -LiteralPath (Join-Path $fixture.State 'inventory.json') | ConvertFrom-Json
    Assert ($inventory.schema -eq $HostInventorySchema -and $inventory.version -eq 1 -and $inventory.generation -eq 1) 'The inventory has no schema, version 1 and generation 1.'
    Assert ($inventory.hostId -eq 'testhost' -and $inventory.github.scope -eq 'orgs/AbsoluteZeroDev') "The inventory has host $($inventory.hostId) and scope $($inventory.github.scope)."
    $ids = (@($inventory.slots | ForEach-Object { "$($_.slotId)=$($_.runnerId)" }) | Sort-Object) -join ','
    Assert ($ids -eq 'linux-01=7,linux-02=,win01=30,windows-legacy=20') "Adopted slots are $ids."
    $linux = $inventory.slots | Where-Object slotId -EQ 'linux-01'
    Assert ($linux.legacy -eq $true -and $linux.runnerName -eq 'subzerodev.runner.linux') 'linux-01 is not the legacy pre-pool runner.'
    $runner = $linux.containers | Where-Object role -EQ 'runner'
    $sidecar = $linux.containers | Where-Object role -EQ 'docker'
    Assert ($runner.id -cmatch '^[0-9a-f]{64}$' -and $runner.id -eq (New-Hex 'runner') -and $runner.name -eq 'subzerodev-runner-linux') "The runner container is recorded as $($runner.name) $($runner.id)."
    Assert ($sidecar.id -eq (New-Hex 'sidecar') -and $sidecar.name -eq 'subzerodev-runner-linux-docker') 'The Docker sidecar is not recorded by its full ID.'
    $legacy = $inventory.slots | Where-Object slotId -EQ 'windows-legacy'
    Assert ($legacy.legacy -eq $true -and $legacy.installPath -eq (Get-CanonicalPath $fixture.Clone)) 'windows-legacy is not this checkout.'
    Assert ($run.Output -match 'Not adopted: .*runner-02 \(subzerodev\.runner\.linux\.testhost\.02\): .*agentId 9.*id 10') "The unproven runner-02 was not reported.`n$($run.Output)"
    $reserved = $inventory.slots | Where-Object slotId -EQ 'linux-02'
    Assert ($reserved.state -eq 'unowned' -and -not $reserved.runnerId) 'An unproven registration was adopted as a live slot, or its number was not reserved.'
    $calls = Get-Calls $fixture
    Assert ($calls.Count -gt 0 -and -not ($calls | Where-Object { $_ -match '(^| )-X ' })) "Adopt made a GitHub call that is not a read:`n$($calls -join "`n")"
    $docker = Get-Calls $fixture 'docker.log'
    Assert (-not ($docker | Where-Object { $_ -notmatch '^(container|image) inspect ' })) "Adopt made a Docker call that is not an inspect:`n$($docker -join "`n")"
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'lock.json'))) 'Adopt left lock.json.'

    $before = Get-StateListing $fixture
    $again = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($again.ExitCode -eq 1 -and $again.Output -match 'Adopt refused: the host inventory .* exists') "A second Adopt was not refused.`n$($again.Output)"
    Assert ((Get-StateListing $fixture) -eq $before) 'The refused Adopt changed the host state.'
}

Test-Case 'Adopt writes nothing when Docker cannot be read' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    Set-Docker $fixture @{ unavailable = $true; containers = @{}; images = @{} }
    $run = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Adopt stopped, nothing written: whether the container .* is unknown') "Adopt with Docker unavailable was not stopped.`n$($run.Output)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'inventory.json'))) 'An inventory was written although Docker could not be read.'
}

Test-Case 'Adopt writes nothing when GitHub cannot be read' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    $world = Get-Content -Raw -LiteralPath (Join-Path $fixture.GhState 'world.json') | ConvertFrom-Json -AsHashtable
    $world.fail = 'actions/runners'
    Set-World $fixture $world
    $run = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Adopt stopped, nothing written: GitHub could not be read') "Adopt with GitHub failing was not stopped.`n$($run.Output)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'inventory.json'))) 'An inventory was written although GitHub could not be read.'
}

Test-Case 'Adopt over an unreadable inventory is refused, and -ReplaceUnreadable keeps the old file beside the new one' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    Write-FixtureState $fixture 'inventory.json' '{ truncated'
    $run = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'cannot be read') "Adopt over an unreadable inventory was not refused.`n$($run.Output)"
    Assert ([IO.File]::ReadAllText((Join-Path $fixture.State 'inventory.json')) -eq '{ truncated') 'The refused Adopt changed the unreadable inventory.'
    $run = Invoke-Manager $fixture @('-Action', 'Adopt', '-ReplaceUnreadable')
    Assert ($run.ExitCode -eq 0 -and $run.Output -match 'Kept the unreadable inventory as') "Adopt -ReplaceUnreadable failed.`n$($run.Output)"
    $kept = @(Get-ChildItem -LiteralPath $fixture.State -Filter 'inventory.json.unreadable-*')
    Assert ($kept.Count -eq 1 -and [IO.File]::ReadAllText($kept[0].FullName) -eq '{ truncated') 'The unreadable inventory was not kept as it was.'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $fixture.State 'inventory.json') | ConvertFrom-Json).generation -eq 1) 'No new inventory was written.'
}

# --- Plan ---------------------------------------------------------------------------------------------------------------

Test-Case 'Plan without an inventory proposes Adopt, exits 3 and writes nothing' {
    $fixture = New-HostFixture
    $run = Invoke-Manager $fixture @('-Action', 'Plan', '-Json')
    Assert ($run.ExitCode -eq 3) "Plan exited $($run.ExitCode), not 3.`n$($run.Output)"
    $plan = Get-JsonOutput $run
    Assert ($plan.inventory.state -eq 'absent' -and @($plan.changes).Count -eq 1 -and $plan.changes[0].kind -eq 'adopt') "Plan proposed $(@($plan.changes | ForEach-Object kind) -join ',')."
    Assert (-not (Test-Path -LiteralPath $fixture.State) -or -not (Get-ChildItem -LiteralPath $fixture.State)) 'Plan wrote host state.'
}

Test-Case 'Plan after Adopt: migrate linux-01, retire windows-legacy after win01, update win01; a stable planHash; read calls only, nothing written' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    $adopt = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($adopt.ExitCode -eq 0) "Adopt failed.`n$($adopt.Output)"
    $before = Get-StateListing $fixture
    Clear-Calls $fixture
    $first = Invoke-Manager $fixture @('-Action', 'Plan', '-Json')
    Assert ($first.ExitCode -eq 3) "Plan exited $($first.ExitCode), not 3.`n$($first.Output)"
    $plan = Get-JsonOutput $first
    $kinds = (@($plan.changes | ForEach-Object { "$($_.kind):$($_.slotId)" }) | Sort-Object) -join ','
    Assert ($kinds -eq 'migrate-legacy-linux:linux-01,retire:windows-legacy,update:win01') "Plan changes are $kinds."
    $retire = $plan.changes | Where-Object kind -EQ 'retire'
    Assert ($retire.after -eq 'win01 online' -and $retire.requires -eq '-Retire' -and $retire.runnerId -eq 20) 'The windows-legacy retirement does not wait for win01 or does not require -Retire.'
    $update = $plan.changes | Where-Object kind -EQ 'update'
    Assert (@($update.reasons) -contains 'settings') "win01 is updated for $(@($update.reasons) -join ','), not its settings."
    Assert ($plan.planHash -match '^[0-9a-f]{64}$') 'Plan has no planHash.'
    $unowned = @($plan.findings | Where-Object severity -EQ 'unowned')
    Assert ($unowned.Count -eq 1 -and $unowned[0].runnerId -eq 10) "The unproven runner id 10 is not a finding ($(@($plan.findings | ForEach-Object message) -join ' | '))."
    $second = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Plan', '-Json'))
    Assert ($second.planHash -eq $plan.planHash) 'The planHash changed between two runs over the same state.'
    $calls = Get-Calls $fixture
    Assert ($calls.Count -gt 0 -and -not ($calls | Where-Object { $_ -match '(^| )-X ' })) "Plan made a GitHub call that is not a read:`n$($calls -join "`n")"
    $docker = Get-Calls $fixture 'docker.log'
    Assert (-not ($docker | Where-Object { $_ -notmatch '^(container|image) inspect ' })) "Plan made a Docker call that is not an inspect:`n$($docker -join "`n")"
    Assert ((Get-StateListing $fixture) -eq $before) 'Plan changed the host state (inventory, journal or lock.json).'

    $settings = Get-Content -Raw -LiteralPath (Join-Path $fixture.Clone 'runners.local.json') | ConvertFrom-Json
    $settings.windows.count = 2
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixture.Clone 'runners.local.json')
    $third = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Plan', '-Json'))
    Assert ($third.changes | Where-Object { $_.kind -eq 'add' -and $_.slotId -eq 'win02' -and $_.runnerName -eq 'subzerodev.runner.windows.testhost.win02' }) 'windows.count 2 did not add win02.'
    Assert ($third.planHash -ne $plan.planHash) 'The planHash did not change with the plan.'
}

Test-Case 'Plan never adds a slot on top of an unproven registration: its number stays reserved' {
    $fixture = New-HostFixture @{ linux = @{ count = 2 } }
    Initialize-AdoptableHost $fixture
    Assert ((Invoke-Manager $fixture @('-Action', 'Adopt')).ExitCode -eq 0) 'Adopt failed.'
    $plan = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Plan', '-Json'))
    $added = @($plan.changes | Where-Object kind -EQ 'add' | Where-Object platform -EQ 'linux' | ForEach-Object slotId)
    Assert ($added.Count -eq 1 -and $added[0] -eq 'linux-03') "Plan adds $($added -join ',') for linux; linux-02 holds an unproven registration."
}

Test-Case 'Adopt stops, writing nothing, when a .runner file cannot be read' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    Set-Content -LiteralPath (Join-Path $fixture.Clone 'linux\runner-02\.runner') -Value '{ not json'
    $run = Invoke-Manager $fixture @('-Action', 'Adopt')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Adopt stopped, nothing written') "Adopt exited $($run.ExitCode).`n$($run.Output)"
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'inventory.json'))) 'Adopt wrote an inventory with an unreadable .runner.'
}

function Write-Linux02Inventory($Fixture) {
    $slot = [ordered]@{
        slotId = 'linux-02'; platform = 'linux'; state = 'active'; legacy = $false; runnerName = 'subzerodev.runner.linux.testhost.02'; runnerId = 9
        scope = 'orgs/AbsoluteZeroDev'; registrationDirectory = (Join-Path $Fixture.Clone 'linux\runner-02')
        containers = @([ordered]@{ role = 'runner'; id = (New-Hex 'runner-02'); name = 'subzerodev-runner-linux-02'; image = $imageId; labels = @{} })
    }
    Write-FixtureState $Fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @($slot) })
    Set-World $Fixture @{ runners = @((New-Runner 9 'subzerodev.runner.linux.testhost.02')); groups = @([ordered]@{ id = 1; name = 'Default'; visibility = 'all'; allows_public_repositories = $false }); groupRepos = @{}; groupRunners = @{ '1' = @(9) }; fail = $null }
}

Test-Case 'A recorded Linux container that is gone is drift, so Plan has a change' {
    $fixture = New-HostFixture @{ windows = @{ count = 0 } }
    Write-Linux02Inventory $fixture
    Set-Docker $fixture @{ unavailable = $false; containers = @{}; images = @{ 'subzerodev-runner-linux:local' = $imageId } }
    $run = Invoke-Manager $fixture @('-Action', 'Plan', '-Json')
    $plan = Get-JsonOutput $run
    $update = $plan.changes | Where-Object { $_.kind -eq 'update' -and $_.slotId -eq 'linux-02' }
    Assert ($run.ExitCode -eq 3 -and $update -and @($update.reasons) -contains 'container') "A missing container is not drift (exit $($run.ExitCode)).`n$($run.Output)"
}

Test-Case 'Plan says so, exits 1 and has a different planHash when Docker cannot be read' {
    $fixture = New-HostFixture @{ windows = @{ count = 0 } }
    Write-Linux02Inventory $fixture
    Set-Docker $fixture @{ unavailable = $false; containers = @{ 'subzerodev-runner-linux-02' = @{ Id = (New-Hex 'runner-02'); Image = $imageId; Labels = @{} } }; images = @{ 'subzerodev-runner-linux:local' = $imageId } }
    $known = Invoke-Manager $fixture @('-Action', 'Plan', '-Json')
    Assert ($known.ExitCode -eq 0) "Plan over a fully read host exited $($known.ExitCode).`n$($known.Output)"
    Set-Docker $fixture @{ unavailable = $true; containers = @{}; images = @{} }
    $run = Invoke-Manager $fixture @('-Action', 'Plan')
    Assert ($run.ExitCode -eq 1 -and $run.Output -notmatch 'No changes\.' -and $run.Output -match '\[unknown\]') "Plan exited $($run.ExitCode) and said:`n$($run.Output)"
    $hash = (Get-JsonOutput $known).planHash
    $unknownHash = (Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Plan', '-Json'))).planHash
    Assert ($hash -ne $unknownHash) 'An unread host and a clean host have the same planHash.'
}

Test-Case 'Plan with nothing to change exits 0; an unowned runner of this host is a finding, never a change' {
    $fixture = New-HostFixture @{ linux = @{ count = 0 }; windows = @{ count = 0 } }
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @() })
    Set-World $fixture @{ runners = @((New-Runner 99 'subzerodev.runner.linux')); groups = @([ordered]@{ id = 1; name = 'Default'; visibility = 'all'; allows_public_repositories = $false }); groupRepos = @{}; groupRunners = @{}; fail = $null }
    $run = Invoke-Manager $fixture @('-Action', 'Plan')
    Assert ($run.ExitCode -eq 0 -and $run.Output -match 'No changes\.') "Plan exited $($run.ExitCode).`n$($run.Output)"
    Assert ($run.Output -match '\[unowned\] unowned: GitHub runner subzerodev\.runner\.linux \(id 99\)') "The unowned runner is not reported.`n$($run.Output)"
    Assert ($run.Output -notmatch 'runner-group') "A Default group that admits no public repositories was reported.`n$($run.Output)"
}

Test-Case 'Plan with a readable journal proposes finishing the operation; an unreadable inventory or journal exits 1' {
    $fixture = New-HostFixture @{ linux = @{ count = 0 }; windows = @{ count = 0 } }
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @() })
    Write-FixtureState $fixture 'operation.json' (ConvertTo-StateJson $HostOperationSchema @{ id = 'op-1'; kind = 'add'; slotId = 'linux-02'; steps = @([ordered]@{ name = 'register'; state = 'pending'; facts = @{} }) })
    $run = Invoke-Manager $fixture @('-Action', 'Plan', '-Json')
    $plan = Get-JsonOutput $run
    Assert ($run.ExitCode -eq 3 -and $plan.changes[0].kind -eq 'finish-operation' -and $plan.changes[0].operationId -eq 'op-1') "A journal did not give finish-operation (exit $($run.ExitCode)).`n$($run.Output)"
    Write-FixtureState $fixture 'operation.json' 'garbage'
    $run = Invoke-Manager $fixture @('-Action', 'Plan')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Plan cannot be computed') "An unreadable journal did not exit 1.`n$($run.Output)"
    Remove-Item -LiteralPath (Join-Path $fixture.State 'operation.json')
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1 } -Version 9)
    $run = Invoke-Manager $fixture @('-Action', 'Plan')
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'inventory unreadable') "An unreadable inventory did not exit 1.`n$($run.Output)"
}

# --- runner groups ------------------------------------------------------------------------------------------------------

Test-Case 'A runner group that allows public repositories blocks; a group whose repositories differ from the settings is drift' {
    $fixture = New-HostFixture @{ linux = @{ count = 0 }; windows = @{ count = 0 } }
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @() })
    Set-World $fixture @{ runners = @(); groups = @([ordered]@{ id = 1; name = 'Default'; visibility = 'all'; allows_public_repositories = $true }); groupRepos = @{}; groupRunners = @{}; fail = $null }
    $plan = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Plan', '-Json'))
    Assert ($plan.findings | Where-Object { $_.severity -eq 'blocked' -and $_.subject -eq 'runner-group' }) "A public group did not block ($(@($plan.findings | ForEach-Object message) -join ' | '))."

    $fixture = New-HostFixture @{ linux = @{ count = 0 }; windows = @{ count = 0 }; github = @{ url = $url; runnerGroup = @{ name = 'Private'; repositories = @('AbsoluteZeroDev/SubZeroDev.A') } } }
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'orgs/AbsoluteZeroDev' }; slots = @() })
    Set-World $fixture @{
        runners = @(); groups = @([ordered]@{ id = 2; name = 'Private'; visibility = 'selected'; allows_public_repositories = $false })
        groupRepos = @{ '2' = @([ordered]@{ name = 'SubZeroDev.B'; full_name = 'AbsoluteZeroDev/SubZeroDev.B' }) }; groupRunners = @{}; fail = $null
    }
    $status = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Status', '-Json'))
    Assert ($status.runnerGroup.state -eq 'drift' -and ($status.runnerGroup.findings | Where-Object { $_.message -match 'missing: AbsoluteZeroDev/SubZeroDev\.A.*not in the settings: AbsoluteZeroDev/SubZeroDev\.B' })) "Differing repositories are not drift ($($status.runnerGroup.state))."
}

Test-Case 'A repository-scoped host has no runner group to check' {
    $fixture = New-HostFixture @{ linux = @{ count = 0 }; windows = @{ count = 0 } }
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; hostId = 'testhost'; github = @{ scope = 'repos/AbsoluteZeroDev/SubZeroDev.A' }; slots = @() })
    $status = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Status', '-Json'))
    Assert ($status.runnerGroup.state -eq 'not-applicable') "A repository scope gave runner group state $($status.runnerGroup.state)."
    Assert (-not (Get-Calls $fixture | Where-Object { $_ -match 'runner-groups' })) 'Runner groups were listed for a repository scope.'
}

# --- Status -------------------------------------------------------------------------------------------------------------

Test-Case 'Status reports what GitHub says (offline, absent, unknown) and no cause' {
    $fixture = New-HostFixture
    Initialize-AdoptableHost $fixture
    Assert ((Invoke-Manager $fixture @('-Action', 'Adopt')).ExitCode -eq 0) 'Adopt failed.'
    $world = Get-Content -Raw -LiteralPath (Join-Path $fixture.GhState 'world.json') | ConvertFrom-Json -AsHashtable
    $world.runners = @((New-Runner 7 'subzerodev.runner.linux' 'offline'), (New-Runner 20 'subzerodev.runner.windows'))
    Set-World $fixture $world
    $run = Invoke-Manager $fixture @('-Action', 'Status', '-Json')
    Assert ($run.ExitCode -eq 0) "Status exited $($run.ExitCode).`n$($run.Output)"
    $status = Get-JsonOutput $run
    Assert ($status.schema -eq 'subzerodev.runners.host-status' -and $status.version -eq 1) 'Status JSON has no schema and version 1.'
    $linux = $status.slots | Where-Object slotId -EQ 'linux-01'
    Assert ($linux.github.status -eq 'offline') "An offline runner is reported $($linux.github.status)."
    $keys = (@($linux.github.PSObject.Properties.Name) | Sort-Object) -join ','
    Assert ($keys -eq 'busy,status') "The GitHub status carries $keys; nothing but status and busy is reported."
    Assert (($status.slots | Where-Object slotId -EQ 'win01').github.status -eq 'absent') 'A runner GitHub does not list is not absent.'
    $text = Invoke-Manager $fixture @('-Action', 'Status')
    Assert ($text.ExitCode -eq 0 -and $text.Output -match 'linux-01 active subzerodev\.runner\.linux \(id 7\): GitHub offline') "Status text exited $($text.ExitCode).`n$($text.Output)"
    $world.fail = 'actions/runners'
    Set-World $fixture $world
    $status = Get-JsonOutput (Invoke-Manager $fixture @('-Action', 'Status', '-Json'))
    Assert (-not ($status.slots | Where-Object { $_.github.status -ne 'unknown' })) 'A failed listing reported a runner as something other than unknown.'
}

# --- Init ---------------------------------------------------------------------------------------------------------------

Test-Case 'Init writes hostId and counts into runners.local.json, keeps the other settings and existing counts, and is rerunnable' {
    $fixture = New-HostFixture
    $settings = Get-Content -Raw -LiteralPath (Join-Path $fixture.Clone 'runners.local.json') | ConvertFrom-Json
    $settings.PSObject.Properties.Remove('linux'); $settings.PSObject.Properties.Remove('windows')
    $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $fixture.Clone 'runners.local.json')
    $run = Invoke-Manager $fixture @('-Action', 'Init', '-HostId', 'newhost', '-LinuxCount', '3')
    Assert ($run.ExitCode -eq 0) "Init exited $($run.ExitCode).`n$($run.Output)"
    $written = Get-Content -Raw -LiteralPath (Join-Path $fixture.Clone 'runners.local.json') | ConvertFrom-Json
    Assert ($written.hostId -eq 'newhost' -and $written.linux.count -eq 3 -and $written.windows.count -eq 2) "Init wrote hostId $($written.hostId), linux $($written.linux.count), windows $($written.windows.count)."
    Assert ($written.github.url -eq $url -and $written.buildAgent.docker.cli) 'Init dropped other settings.'
    $run = Invoke-Manager $fixture @('-Action', 'Init')
    $again = Get-Content -Raw -LiteralPath (Join-Path $fixture.Clone 'runners.local.json') | ConvertFrom-Json
    Assert ($run.ExitCode -eq 0 -and $again.hostId -eq 'newhost' -and $again.linux.count -eq 3 -and $again.windows.count -eq 2) "A rerun changed the values (exit $($run.ExitCode)).`n$($run.Output)"
    $bad = Invoke-Manager $fixture @('-Action', 'Init', '-HostId', 'Upper')
    Assert ($bad.ExitCode -eq 1 -and $bad.Output -match 'is not a host ID') "An upper-case host ID was accepted.`n$($bad.Output)"
}

Test-Case 'Init over an unreadable runners.local.json fails and leaves it as it is' {
    $fixture = New-HostFixture
    $path = Join-Path $fixture.Clone 'runners.local.json'
    Write-Raw $path '{ "hostId": '
    $run = Invoke-Manager $fixture @('-Action', 'Init', '-LinuxCount', '1')
    Assert ($run.ExitCode -ne 0) "Init over an unreadable runners.local.json exited 0.`n$($run.Output)"
    Assert ([IO.File]::ReadAllText($path) -eq '{ "hostId": ') 'Init changed the unreadable file.'
}

# --- the lock across processes -------------------------------------------------------------------------------------------

Test-Case 'A child of a joinable holder joins its lock and leaves the holder''s lock.json' {
    $fixture = New-HostFixture
    $env:LOCALAPPDATA = $fixture.LocalAppData
    Enter-HostLock -Kind 'test holder' -Joinable
    try {
        $token = $env:SZR_HOST_OPERATION
        Assert ($token) 'A joinable holder did not set SZR_HOST_OPERATION.'
        $child = Start-HostScript $fixture 'Manage-RunnerHost.ps1' @('-Action', 'Init')
        $finished = $child.Process.WaitForExit(90000)
        if (-not $finished) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        Assert $finished "The child waited on its parent's lock.`n$(Get-ChildText $child)"
        Assert ($child.Process.ExitCode -eq 0) "The child exited $($child.Process.ExitCode).`n$(Get-ChildText $child)"
        Assert ((Get-ChildText $child) -notmatch 'Waiting for another runner operation') 'The child waited instead of joining.'
        $record = Read-HostLockRecord
        Assert ($record.State -eq 'readable' -and $record.Value.pid -eq $PID -and $record.Value.token -eq $token) 'The joined child changed or removed the holder''s lock.json.'
    } finally { Exit-HostLock }
    Assert (-not $env:SZR_HOST_OPERATION) 'The token was not cleared when the holder released the lock.'
}

Test-Case 'A command waits while another holds the lock, says so, and runs once it is released' {
    $fixture = New-HostFixture
    $env:LOCALAPPDATA = $fixture.LocalAppData
    Enter-HostLock -Kind 'test holder'
    $child = $null
    try {
        $child = Start-HostScript $fixture 'Manage-RunnerHost.ps1' @('-Action', 'Init')
        Assert (Wait-ChildText $child 'Waiting for another runner operation on this host to finish \(test holder, pid \d+') "The child did not report that it waits.`n$(Get-ChildText $child)"
        Start-Sleep -Seconds 3
        Assert (-not $child.Process.HasExited) "The child ran while the lock was held.`n$(Get-ChildText $child)"
    } finally { Exit-HostLock }
    $finished = $child.Process.WaitForExit(90000)
    if (-not $finished) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
    Assert ($finished -and $child.Process.ExitCode -eq 0) "The child did not finish after the release (exit $(if ($finished) { $child.Process.ExitCode })).`n$(Get-ChildText $child)"
}

Test-Case 'New-LinuxRunner.ps1 waits for the host lock before it does anything' {
    $fixture = New-HostFixture
    $env:LOCALAPPDATA = $fixture.LocalAppData
    Enter-HostLock -Kind 'test holder'
    $child = $null
    try {
        $child = Start-HostScript $fixture 'New-LinuxRunner.ps1' @('-Force')
        Assert (Wait-ChildText $child 'Waiting for another runner operation') "New-LinuxRunner.ps1 did not wait for the lock.`n$(Get-ChildText $child)"
        Assert (-not (Get-Calls $fixture 'docker.log')) 'New-LinuxRunner.ps1 called Docker before it had the lock.'
    } finally {
        if ($child) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue; $child.Process.WaitForExit(10000) | Out-Null }
        Exit-HostLock
    }
}

Test-Case 'Manage-WindowsRunner.ps1 -Action Status takes no lock' {
    $fixture = New-HostFixture
    $unlocked = Invoke-HostScript $fixture 'Manage-WindowsRunner.ps1' @('-Action', 'Status')
    $env:LOCALAPPDATA = $fixture.LocalAppData
    Enter-HostLock -Kind 'test holder'
    try {
        $child = Start-HostScript $fixture 'Manage-WindowsRunner.ps1' @('-Action', 'Status')
        $finished = $child.Process.WaitForExit(90000)
        if (-not $finished) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        Assert $finished "Status waited for the lock.`n$(Get-ChildText $child)"
        Assert ((Get-ChildText $child) -notmatch 'Waiting for another runner operation') 'Status waited for the lock.'
        Assert ($child.Process.ExitCode -eq $unlocked.ExitCode) "Status exited $($child.Process.ExitCode) under the lock and $($unlocked.ExitCode) without it."
    } finally { Exit-HostLock }
}

Test-Case 'An entry script run from a prompt releases the host lock when it returns' {
    $fixture = New-HostFixture
    $output = Use-FixtureEnvironment $fixture {
        $script = Join-Path $fixture.Clone 'scripts\Manage-WindowsRunner.ps1'
        & $pwshPath -NoLogo -NoProfile -Command "& '$script' -Action Stop -Force *> `$null; 'held=' + [bool]`$global:SubZeroDevHostLock; 'file=' + (Test-Path -LiteralPath '$($fixture.State)\lock.json')" 2>&1 | ForEach-Object { "$_" }
    }
    $text = $output -join ' '
    Assert ($text -match 'held=False' -and $text -match 'file=False') "The script left the lock held after it returned: $text"
    $other = Use-FixtureEnvironment $fixture {
        $name = Get-HostLockName
        & $pwshPath -NoLogo -NoProfile -Command "`$m = [Threading.Mutex]::new(`$false, '$name'); try { `$ok = `$m.WaitOne(500) } catch { `$ok = `$true }; 'free=' + `$ok" 2>&1 | ForEach-Object { "$_" }
    }
    Assert (($other -join ' ') -match 'free=True') "Another process could not take the lock afterwards: $($other -join ' ')"
}

# --- setup refusal ------------------------------------------------------------------------------------------------------

Test-Case 'The setup worker refuses under the lock once an inventory exists, before any setup step' {
    $fixture = New-HostFixture
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; slots = @() })
    $worker = New-CaseDirectory
    foreach ($file in 'Configure-WindowsRunners.ps1', 'RunnerConfig.ps1', 'HostState.ps1') { Copy-Item (Join-Path $repo "scripts\$file") $worker }
    $marker = Join-Path $worker 'setup-called.txt'
    Set-Content -LiteralPath (Join-Path $worker 'WindowsRunnerSetup.ps1') -Value "function Invoke-WindowsRunnerHostSetup { Set-Content -LiteralPath '$marker' -Value called; [pscustomobject]@{ ExitCode = 0 } }"
    Set-Content -LiteralPath (Join-Path $worker 'options.json') -Value '{}'
    $run = Use-FixtureEnvironment $fixture {
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $worker 'Configure-WindowsRunners.ps1') -OptionsPath (Join-Path $worker 'options.json') 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Setup refused: this host is managed by scripts\\Manage-RunnerHost\.ps1') "The worker did not refuse.`n$($run.Output)"
    Assert (-not (Test-Path -LiteralPath $marker)) 'The worker ran setup although the host manager owns the host.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'lock.json'))) 'The worker left lock.json.'
}

Test-Case 'Setup-WindowsRunners.ps1 (Windows PowerShell) refuses once an inventory exists' {
    $powershell = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Assert $powershell 'Windows PowerShell is not available.'
    $fixture = New-HostFixture
    Copy-Item (Join-Path $repo 'Setup-WindowsRunners.ps1') $fixture.Clone
    Write-FixtureState $fixture 'inventory.json' (ConvertTo-StateJson $HostInventorySchema @{ generation = 1; slots = @() })
    $run = Use-FixtureEnvironment $fixture {
        $output = & $powershell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture.Clone 'Setup-WindowsRunners.ps1') -NonInteractive 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    Assert ($run.ExitCode -eq 1 -and $run.Output -match 'Setup refused: this host is managed by') "Setup did not refuse.`n$($run.Output)"
}

$env:LOCALAPPDATA = $originalLocalAppData
$env:SZR_HOST_OPERATION = $originalToken
Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host "$($cases.Count - $failed.Count) of $($cases.Count) host state checks passed."
if ($failed) { Write-Host "Failed:`n - $(($failed | ForEach-Object { $_.Name }) -join "`n - ")"; exit 1 }
# The cases run native commands that exit nonzero on purpose; without this a CI step (pwsh -Command) reports the last of them.
exit 0
