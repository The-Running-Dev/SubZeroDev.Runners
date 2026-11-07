# Resumable setup state. One small file in the install root records which setup steps finished and what the person must do
# (restart Windows, sign out and in, run something as an administrator) before setup can continue. Rerunning the same setup
# command reads it, drops the actions that are no longer pending, skips nothing that is not provably done, and carries on.
# Setup never restarts Windows, signs the user out or turns on automatic sign-in: it records the action and stops with exit code 2.

$SetupStateFile = 'setup-state.json'

function Get-SetupStatePath([Parameter(Mandatory)] [string] $InstallRoot) { Join-Path $InstallRoot $SetupStateFile }

# The saved state, or an empty one. Never throws: an unreadable file is treated as no state (the checks it summarises run again).
function Read-SetupState([Parameter(Mandatory)] [string] $InstallRoot) {
    $empty = [pscustomobject]@{ version = 1; updatedUtc = $null; completed = [pscustomobject]@{}; actions = @() }
    $path = Get-SetupStatePath $InstallRoot
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        if (-not $state.completed) { $state | Add-Member -Force -NotePropertyName completed -NotePropertyValue ([pscustomobject]@{}) }
        $state | Add-Member -Force -NotePropertyName actions -NotePropertyValue @($state.actions | Where-Object { $_ })
        $state
    }
    catch { $empty }
}

# Writes the state beside a temporary file and moves it into place. The install root is created by the bootstrap; when it
# does not exist (a fixture run) nothing is written.
function Save-SetupState([Parameter(Mandatory)] [string] $InstallRoot, [Parameter(Mandatory)] $State) {
    if (-not (Test-Path -LiteralPath $InstallRoot)) { return }
    $State.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $path = Get-SetupStatePath $InstallRoot
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

# Marks a step finished. Steps are named, for example 'runners' or 'buildagent-tool'.
function Set-SetupStep([string] $InstallRoot, [string] $Step) {
    $state = Read-SetupState $InstallRoot
    $state.completed | Add-Member -Force -NotePropertyName $Step -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
    Save-SetupState $InstallRoot $state
}

# Replaces the pending actions. Each is { Id, Kind, Message }; Kind is one of reboot, sign-out, admin, install, user.
function Set-SetupAction([string] $InstallRoot, [object[]] $Action) {
    $state = Read-SetupState $InstallRoot
    $now = [DateTime]::UtcNow.ToString('o')
    $state.actions = @($Action | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.Id; kind = $_.Kind; message = $_.Message; sinceUtc = $now } })
    Save-SetupState $InstallRoot $state
}

# Last Windows start, in UTC. $null when it cannot be read.
function Get-SetupBootTime {
    try { (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime() } catch { $null }
}

# Pending actions that still apply. A restart action is satisfied once Windows has started after it was recorded; the other
# kinds are satisfied by the live check that raised them, so the next run simply does not raise them again.
function Get-SetupPendingAction([string] $InstallRoot) {
    $boot = Get-SetupBootTime
    # ConvertFrom-Json turns ISO timestamps into DateTime already; a string is parsed as the UTC instant it names.
    $utc = { param($Value) if ($Value -is [DateTime]) { $Value.ToUniversalTime() } else { [DateTime]::Parse([string] $Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } }
    @((Read-SetupState $InstallRoot).actions | Where-Object {
            -not ($_.kind -eq 'reboot' -and $boot -and (& $utc $_.sinceUtc) -lt $boot)
        })
}

# True when Windows reports that it must restart before an installation is complete.
function Test-SetupRebootPending {
    foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        if (Test-Path -LiteralPath $key) { return $true }
    }
    $false
}

# Prints what to do, one numbered line per action, ending with how to resume.
function Write-SetupAction([object[]] $Action, [string] $ResumeCommand) {
    Write-Host ''
    Write-Host 'Setup is paused: finish the following, then rerun the same command. Finished steps are skipped.' -ForegroundColor Yellow
    $number = 0
    foreach ($item in $Action) { $number++; Write-Host ("  {0}. [{1}] {2}" -f $number, $item.Kind, $item.Message) }
    if ($ResumeCommand) { Write-Host "Resume with: $ResumeCommand" }
}
