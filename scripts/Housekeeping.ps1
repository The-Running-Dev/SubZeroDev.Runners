# Cleanup shared by the completion hook, the log-trim task and the setup scripts. Every deletion is bounded (a retry count and
# delay from runners.json housekeeping), never touches a runner's registration or credentials, and reports what it kept.
# Dot-source Common.ps1 first.

# Names that identify a runner and its state. Nothing here is removed by any cleanup, wherever it sits below a runner directory.
$script:ProtectedRunnerNames = @(
    '.runner', '.runner_migrated', '.credentials', '.credentials_migrated', '.credentials_rsaparams',
    '_recovery', 'maintenance.json', 'supervisor.json', 'runners.local.json', '.path', '.env'
)

# True when the file or directory is a registration or state file that cleanup must keep.
function Test-ProtectedRunnerPath([string] $Path) {
    $parts = (Get-CanonicalPath $Path) -split '[\\/]'
    foreach ($part in $parts) { if ($part -in $script:ProtectedRunnerNames) { return $true } }
    $false
}

# Removes a file or directory tree, retrying a sharing violation up to $Retries times. Returns $true when it is gone and
# $false when it is still in use after the last attempt; it never waits longer than $Retries x $DelaySeconds.
function Remove-PathBounded {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $Retries = $Config.housekeeping.retries,
        [double] $DelaySeconds = $Config.housekeeping.retryDelaySeconds
    )
    if (Test-ProtectedRunnerPath $Path) { throw "Refusing to remove protected runner path $Path." }
    for ($attempt = 1; $attempt -le [Math]::Max(1, $Retries); $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
            return $true
        }
        catch {
            if ($attempt -ge $Retries) { return $false }
            Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000))
        }
    }
    $false
}

# Empties <work>\_actions of one runner so the next job prepares it fresh. Throws when the work folder is not a safe target or
# when the cache is still locked after the bounded retries; returns a message otherwise.
function Clear-RunnerActionCache([Parameter(Mandatory)] [string] $RunnerDirectory) {
    $registration = Join-Path $RunnerDirectory '.runner'
    if (-not (Test-Path -LiteralPath $registration)) { throw "No registration in $RunnerDirectory; no action cache to clear." }
    # The work folder the runner was registered with (windows.workFolder): relative to the runner, or absolute.
    $work = (Get-Content -Raw -LiteralPath $registration | ConvertFrom-Json).workFolder
    if (-not $work) { throw "The registration in $RunnerDirectory has no work folder." }
    $workPath = Get-CanonicalPath ([IO.Path]::Combine($RunnerDirectory, "$work"))
    if ($workPath -eq [IO.Path]::GetPathRoot($workPath).TrimEnd('\', '/')) { throw "Unexpected action cache path $workPath." }
    if (Test-PathUnder $RunnerDirectory $workPath) { throw "The work folder $workPath contains the runner; refusing to clear it." }
    $cache = Join-Path $workPath '_actions'
    if (-not (Remove-PathBounded $cache)) {
        throw "The action cache $cache is still in use after $($Config.housekeeping.retries) attempts; the next job will reuse it."
    }
    'Action cache is ready for the next job.'
}

# Deletes diagnostic logs older than logs.retentionDays, then the oldest ones until the folder is within logs.maxMB.
# The newest log of each kind (Runner, Worker, Console, Startup) is always kept: a listener that has run for weeks still writes it.
# Returns { Removed, Kept, BytesBefore, BytesAfter, Locked }.
function Invoke-LogTrim([Parameter(Mandatory)] [string[]] $DiagnosticsDirectory) {
    $cutoff = (Get-Date).AddDays(-[int]$Config.logs.retentionDays)
    $limit = [long]$Config.logs.maxMB * 1MB
    $removed = 0; $locked = 0; $before = 0L; $after = 0L
    foreach ($diag in $DiagnosticsDirectory) {
        if (-not (Test-Path -LiteralPath $diag)) { continue }
        $files = @(Get-ChildItem -LiteralPath $diag -Recurse -File -Force | Where-Object { -not (Test-ProtectedRunnerPath $_.FullName) })
        $before += ($files | Measure-Object Length -Sum).Sum
        $newest = @($files | Where-Object Name -match '^(Runner|Worker|Console|Startup)_' |
                Group-Object { $_.Name.Split('_')[0] } | ForEach-Object { ($_.Group | Sort-Object LastWriteTime)[-1].FullName })
        $candidates = @($files | Where-Object { $_.FullName -notin $newest } | Sort-Object LastWriteTime)
        $size = ($files | Measure-Object Length -Sum).Sum
        foreach ($file in $candidates) {
            if ($file.LastWriteTime -ge $cutoff -and $size -le $limit) { break }
            # A single attempt: an open log is left for the next run rather than waited on.
            if (Remove-PathBounded $file.FullName -Retries 1 -DelaySeconds 0) { $removed++; $size -= $file.Length }
            else { $locked++ }
        }
        $after += [Math]::Max(0, $size)
    }
    [pscustomobject]@{ Removed = $removed; Locked = $locked; BytesBefore = $before; BytesAfter = $after; LimitBytes = $limit }
}

# The BuildAgent cache folders of every instance under the shared workspace root.
function Get-BuildAgentCacheDirectory {
    $agent = $Config.buildAgent
    if (-not $agent -or -not $agent.enabled) { return @() }
    $root = Get-CanonicalPath $agent.paths.workspaceRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory -Force | ForEach-Object { Join-Path $_.FullName $agent.paths.cacheDirectory } | Where-Object { Test-Path -LiteralPath $_ })
}

# Applies buildAgent.cache.retentionDays and maxGB to each instance's cache: entries untouched for longer than the retention go
# first, then the least recently used until the cache fits. Entries that are in use are left for the next run.
function Invoke-CacheTrim {
    $cutoff = (Get-Date).AddDays(-[int]$Config.buildAgent.cache.retentionDays)
    $limit = [long]$Config.buildAgent.cache.maxGB * 1GB
    $removed = 0; $locked = 0; $bytes = 0L
    foreach ($cache in Get-BuildAgentCacheDirectory) {
        $entries = @(Get-ChildItem -LiteralPath $cache -Force | ForEach-Object {
                $size = if ($_.PSIsContainer) { (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { $_.Length }
                [pscustomobject]@{ Path = $_.FullName; Used = $_.LastWriteTime; Size = [long]$size }
            } | Sort-Object Used)
        $total = ($entries | Measure-Object Size -Sum).Sum
        foreach ($entry in $entries) {
            if ($entry.Used -ge $cutoff -and $total -le $limit) { break }
            if (Remove-PathBounded $entry.Path -Retries 1 -DelaySeconds 0) { $removed++; $bytes += $entry.Size; $total -= $entry.Size }
            else { $locked++ }
        }
    }
    [pscustomobject]@{ Removed = $removed; Locked = $locked; FreedBytes = $bytes }
}

# Free space on the drives that hold the runners, the work folders and the BuildAgent workspaces, against housekeeping.minFreeGB.
# Returns one row per drive: { Drive, FreeGB, MinimumGB, Low }.
function Get-FreeDiskReport([string[]] $Path) {
    $minimum = [double]$Config.housekeeping.minFreeGB
    $Path | ForEach-Object { [IO.Path]::GetPathRoot((Get-CanonicalPath $_)) } | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
        $drive = [IO.DriveInfo]::new($_)
        $free = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        [pscustomobject]@{ Drive = $_; FreeGB = $free; MinimumGB = $minimum; Low = ($free -lt $minimum) }
    }
}
