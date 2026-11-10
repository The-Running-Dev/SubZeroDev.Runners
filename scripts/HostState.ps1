# Host state of the runner pool: the inventory of what this host's manager owns, the journal of the one operation in
# progress, and the host lock every mutating command takes. Dot-source it after RunnerConfig.ps1 (Common.ps1 does both).
#
# The files live outside every clone, in %LOCALAPPDATA%\SubZeroDev\Runners\host\. Each carries a schema and a version and is
# written atomically (temp file, flush, replace). A file that does not parse, or whose schema or version is not one this
# code knows, is 'unreadable': a state of its own, never treated as absent or empty.

$HostInventorySchema = 'subzerodev.runners.host-inventory'
$HostOperationSchema = 'subzerodev.runners.host-operation'
$HostLockSchema = 'subzerodev.runners.host-lock'
$HostStateVersion = 1
$HostOperationVariable = 'SZR_HOST_OPERATION'

function Get-HostStateDirectory {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set, so the host state directory is unknown.' }
    Join-Path $env:LOCALAPPDATA 'SubZeroDev\Runners\host'
}
function Get-HostInventoryPath { Join-Path (Get-HostStateDirectory) 'inventory.json' }
function Get-HostOperationPath { Join-Path (Get-HostStateDirectory) 'operation.json' }
function Get-HostLockRecordPath { Join-Path (Get-HostStateDirectory) 'lock.json' }
# The lock guards one state directory, so its name is derived from it: a test with its own LOCALAPPDATA never waits on
# (or blocks) the real host's lock.
function Get-HostLockName {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Get-CanonicalPath (Get-HostStateDirectory)).ToLowerInvariant()))[0..7] | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    "Local\SubZeroDev.Runners.Host.$hash"
}

# { State = absent | readable | unreadable; Value; Reason; Path }. Never throws for the file's content.
function Read-HostStateFile([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Schema) {
    $result = [pscustomobject][ordered]@{ State = 'absent'; Value = $null; Reason = $null; Path = $Path }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $result.State = 'unreadable'
    try { $value = [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { $result.Reason = "it is not valid JSON ($($_.Exception.Message))"; return $result }
    if (-not (IsSettingsObject $value)) { $result.Reason = 'it is not a JSON object'; return $result }
    if ($value.schema -ne $Schema) { $result.Reason = "its schema is '$($value.schema)', not '$Schema'"; return $result }
    if (-not (IsWholeNumber $value.version) -or $value.version -ne $HostStateVersion) {
        $result.Reason = "its version is '$($value.version)'; this version of the scripts reads version $HostStateVersion only"
        return $result
    }
    $result.State = 'readable'
    $result.Value = $value
    $result
}

function Read-HostInventory { Read-HostStateFile (Get-HostInventoryPath) $HostInventorySchema }
function Read-HostOperation { Read-HostStateFile (Get-HostOperationPath) $HostOperationSchema }

function Write-HostStateFile([string] $Path, [string] $Schema, $Value) {
    if (-not (Test-HostLockHeld)) { throw "Host state is written only under the host lock ($(Get-HostLockName)); $Path was not changed." }
    $copy = [ordered]@{ schema = $Schema; version = $HostStateVersion }
    if ($Value -is [Collections.IDictionary]) { foreach ($key in $Value.Keys) { if ($key -notin 'schema', 'version') { $copy[$key] = $Value[$key] } } }
    else { foreach ($property in $Value.PSObject.Properties) { if ($property.Name -notin 'schema', 'version') { $copy[$property.Name] = $property.Value } } }
    Write-FileAtomic $Path ((ConvertTo-Json -InputObject $copy -Depth 20) + "`n")
}

# Writes the inventory with updatedUtc set to now. The caller sets generation.
function Write-HostInventory([Parameter(Mandatory)] $Inventory) {
    if ($Inventory -is [Collections.IDictionary]) { $Inventory['updatedUtc'] = [DateTime]::UtcNow.ToString('o') }
    else { $Inventory | Add-Member -Force -NotePropertyName updatedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) }
    Write-HostStateFile (Get-HostInventoryPath) $HostInventorySchema $Inventory
}

function Write-HostOperation([Parameter(Mandatory)] $Operation) { Write-HostStateFile (Get-HostOperationPath) $HostOperationSchema $Operation }

function Remove-HostOperation {
    if (-not (Test-HostLockHeld)) { throw "Host state is changed only under the host lock ($(Get-HostLockName))." }
    $path = Get-HostOperationPath
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# A new journal entry (not written): one operation, its slot and its named steps, all pending.
function New-HostOperation([Parameter(Mandatory)] [string] $Kind, [string] $SlotId, [string[]] $Steps = @()) {
    [pscustomobject][ordered]@{
        schema = $HostOperationSchema; version = $HostStateVersion
        id = [guid]::NewGuid().ToString(); kind = $Kind; slotId = $SlotId; startedUtc = [DateTime]::UtcNow.ToString('o')
        steps = @($Steps | ForEach-Object { [pscustomobject][ordered]@{ name = $_; state = 'pending'; facts = [pscustomobject]@{} } })
    }
}

# Apply, Resume, Hold and Prune change only what the inventory records, so they refuse without a readable one. An
# unreadable operation journal is refused as well: whatever it was doing is unknown. Returns the inventory.
function Assert-HostInventoryUsable([Parameter(Mandatory)] [ValidateSet('Apply', 'Resume', 'Hold', 'Prune')] [string] $Action) {
    $inventory = Read-HostInventory
    switch ($inventory.State) {
        'absent' { throw "$Action refused: there is no host inventory ($($inventory.Path)). Run Manage-RunnerHost.ps1 -Action Adopt first." }
        'unreadable' { throw "$Action refused: the host inventory $($inventory.Path) cannot be read because $($inventory.Reason). What this host owns is unknown, so nothing is changed. Restore the file, or rebuild it with Manage-RunnerHost.ps1 -Action Adopt -ReplaceUnreadable (the old file is kept)." }
    }
    $operation = Read-HostOperation
    if ($operation.State -eq 'unreadable') { throw "$Action refused: the operation journal $($operation.Path) cannot be read because $($operation.Reason). The operation it records is unknown; restore the file before running $Action." }
    $inventory.Value
}

# heldBefore for a journal step that is about to enter maintenance: whether the slot's maintenance record exists now.
# An unreadable record exists, so it counts as held.
function Get-HeldBefore([Parameter(Mandatory)] [string] $StateFile) { [bool](Test-Path -LiteralPath $StateFile) }

# Ends maintenance at the end of an operation only when that operation started it (C4): heldBefore must be recorded and
# false. A slot the owner held before stays held. Returns $true when maintenance was ended.
function Complete-OperationMaintenance([Parameter(Mandatory)] $Step, [Parameter(Mandatory)] [string] $StateFile, [Parameter(Mandatory)] [string] $RunnerDirectory) {
    $facts = if ($Step.PSObject.Properties['facts']) { $Step.facts } else { $Step }
    $held = if ($facts -is [Collections.IDictionary]) { $facts['heldBefore'] } else { $facts.heldBefore }
    if ($null -eq $held) { throw "The step '$($Step.name)' does not record heldBefore, so who held the runner is unknown; its maintenance record $StateFile is kept." }
    if ($held -isnot [bool]) { throw "The step '$($Step.name)' records heldBefore as '$held', not true or false; its maintenance record $StateFile is kept." }
    if ($held) { return $false }
    [bool](Exit-RunnerMaintenance -StateFile $StateFile -RunnerDirectory $RunnerDirectory)
}

# The host lock. One process holds the named mutex; every mutating command takes it for its whole run. A command started
# by the holder joins instead of waiting: a joinable holder records a token in lock.json and in SZR_HOST_OPERATION, and a
# process whose SZR_HOST_OPERATION equals the recorded token, while the recorded holder process is still alive, joins.
# Entry scripts take it with Enter-HostLock and let process exit release it (Windows then marks the mutex abandoned, which
# the next process takes as acquired). Functions use Use-HostLock.
function Test-HostLockHeld { [bool]$global:SubZeroDevHostLock }

function Get-ProcessStartUtc([int] $Id) {
    try { (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { $null }
}

function Read-HostLockRecord { Read-HostStateFile (Get-HostLockRecordPath) $HostLockSchema }

function Test-HostLockJoinable($Record, [string] $Token) {
    if (-not $Token -or $Record.State -ne 'readable' -or -not $Record.Value.token) { return $false }
    if ($Record.Value.token -ne $Token -or -not (IsWholeNumber $Record.Value.pid)) { return $false }
    $started = Get-ProcessStartUtc ([int]$Record.Value.pid)
    # ConvertFrom-Json turns an ISO timestamp into a DateTime: compare as the round-trip string.
    $recorded = $Record.Value.processStartUtc
    if ($recorded -is [datetime]) { $recorded = $recorded.ToUniversalTime().ToString('o') }
    [bool]($started -and $started -eq $recorded)
}

function Enter-HostLock {
    param(
        [Parameter(Mandatory)] [string] $Kind,
        # The holder may be joined by the processes it starts: they inherit SZR_HOST_OPERATION.
        [switch] $Joinable,
        # The join token (the manager passes its operation id). A new GUID when omitted.
        [string] $Token
    )
    $held = $global:SubZeroDevHostLock
    if ($held) { $held.Depth++; return }
    $record = Read-HostLockRecord
    if (Test-HostLockJoinable $record ([Environment]::GetEnvironmentVariable($HostOperationVariable))) {
        $global:SubZeroDevHostLock = @{ Mutex = $null; Depth = 1; Kind = $Kind; Joined = $true; PreviousToken = $null; SetToken = $false }
        return
    }
    $mutex = [Threading.Mutex]::new($false, (Get-HostLockName))
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) }
    catch { if (Test-AbandonedMutex $_) { $acquired = $true } else { $mutex.Dispose(); throw } }
    if (-not $acquired) {
        $record = Read-HostLockRecord
        $holder = if ($record.State -eq 'readable') { " ($($record.Value.kind), pid $($record.Value.pid), since $($record.Value.startedUtc))" } else { '' }
        [Console]::Error.WriteLine("Waiting for another runner operation on this host to finish$holder...")
        try { $mutex.WaitOne() | Out-Null }
        catch { if (-not (Test-AbandonedMutex $_)) { $mutex.Dispose(); throw } }
    }
    $previous = [Environment]::GetEnvironmentVariable($HostOperationVariable)
    $lock = @{ Mutex = $mutex; Depth = 1; Kind = $Kind; Joined = $false; PreviousToken = $previous; SetToken = $false }
    $global:SubZeroDevHostLock = $lock
    try {
        # Whatever lock.json says now is left by a holder that is gone (it no longer holds the mutex): replace it.
        $self = [Diagnostics.Process]::GetCurrentProcess()
        $value = [ordered]@{
            token = $null; pid = $self.Id; processStartUtc = $self.StartTime.ToUniversalTime().ToString('o')
            kind = $Kind; startedUtc = [DateTime]::UtcNow.ToString('o')
        }
        if ($Joinable) {
            $value.token = if ($Token) { $Token } else { [guid]::NewGuid().ToString() }
            [Environment]::SetEnvironmentVariable($HostOperationVariable, $value.token)
            $lock.SetToken = $true
        } elseif ($previous) {
            # A token inherited from a holder that is not this lock's: children must not join a lock this process holds
            # under another identity.
            [Environment]::SetEnvironmentVariable($HostOperationVariable, $null)
            $lock.SetToken = $true
        }
        Write-HostStateFile (Get-HostLockRecordPath) $HostLockSchema $value
    } catch { Exit-HostLock; throw }
}

function Test-AbandonedMutex($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception -is [Threading.AbandonedMutexException]) { return $true }
        $exception = $exception.InnerException
    }
    $false
}

function Exit-HostLock {
    $lock = $global:SubZeroDevHostLock
    if (-not $lock) { return }
    $lock.Depth--
    if ($lock.Depth -gt 0) { return }
    $global:SubZeroDevHostLock = $null
    if ($lock.Joined) { return }
    try {
        $record = Read-HostLockRecord
        if ($record.State -ne 'absent' -and ($record.State -ne 'readable' -or $record.Value.pid -eq $PID)) {
            Remove-Item -LiteralPath $record.Path -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($lock.SetToken) { [Environment]::SetEnvironmentVariable($HostOperationVariable, $lock.PreviousToken) }
        try { $lock.Mutex.ReleaseMutex() } finally { $lock.Mutex.Dispose() }
    }
}

function Use-HostLock {
    param([Parameter(Mandatory)] [string] $Kind, [Parameter(Mandatory)] [scriptblock] $ScriptBlock, [switch] $Joinable, [string] $Token)
    Enter-HostLock -Kind $Kind -Joinable:$Joinable -Token $Token
    try { & $ScriptBlock } finally { Exit-HostLock }
}
