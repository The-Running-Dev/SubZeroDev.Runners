#Requires -Version 7.2
# Sets up the Windows runner, and only the Windows runner, on another machine: writes runners.local.json, downloads
# and verifies the Actions runner, installs the private .NET SDK, registers the runner with GitHub under its own
# name and the shared labels, and starts it now and at every sign-in. No Docker Desktop and no Linux runner.
# Run it from a git clone of this repository outside Dropbox, in a normal (not elevated) PowerShell 7 window,
# signed in to Windows as the user the jobs should run as. Safe to rerun.
param(
    # Unique per machine: a second runner with an existing name would take that runner's place.
    [string] $Name = "subzerodev.runner.windows.$($env:COMPUTERNAME.ToLowerInvariant())",
    # Added to github.labels and windows.labels, for example subzerodev-windows-large to target this machine alone.
    [string[]] $ExtraLabels = @(),
    [string] $GitHubUrl = 'https://github.com/AbsoluteZeroDev',
    [string] $WorkFolder = '%TEMP%\szr',
    # Take over a runner already registered under -Name elsewhere; that machine stops receiving jobs.
    [switch] $Replace,
    # One clone per instance. Gives each instance its own name, workspace, mutex and tasks.
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$')]
    [string] $InstanceId
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Dropbox syncs windows\.runner and .credentials*, so two machines sharing that folder overwrite each other's registration.
if ($root -match '(?i)\\Dropbox(\\|$)') { throw "Clone this repository outside Dropbox (for example C:\SubZeroDev.Runners) and run it from there; $root is synced." }
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from a normal, not elevated, PowerShell 7 window: the runner and its jobs run as this user.' }
$missing = @(
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { 'Git.Git' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { 'GitHub.cli' }
)
if ($missing) { throw "Install first, then open a new window: $(($missing | ForEach-Object { "winget install --id $_ --exact" }) -join '; ')" }
gh auth status --hostname github.com *> $null
if ($LASTEXITCODE) { throw 'Sign in first: gh auth login --hostname github.com --web --scopes admin:org' }

# This machine's settings; whatever else runners.local.json already holds is kept.
$localPath = Join-Path $root 'runners.local.json'
$local = if (Test-Path -LiteralPath $localPath) { Get-Content -Raw $localPath | ConvertFrom-Json -AsHashtable } else { @{} }
$shared = Get-Content -Raw (Join-Path $root 'runners.json') | ConvertFrom-Json
if ($InstanceId -and $local.windows.instanceId -and $local.windows.instanceId -ne $InstanceId) {
    throw "This clone belongs to instance $($local.windows.instanceId). Use a separate clone for $InstanceId."
}
$existingDirectory = if ($local.windows.directory) { $local.windows.directory } else { $shared.windows.directory }
if ($InstanceId -and -not $local.windows.instanceId -and (Test-Path -LiteralPath (Join-Path $root "$existingDirectory\.runner"))) {
    throw 'This clone already has an unnamed runner. Use a fresh clone for a named instance.'
}
# Windows task names are case-insensitive; retain the saved spelling so a rerun cannot change the mutex.
if ($local.windows.instanceId) { $InstanceId = $local.windows.instanceId }
if ($InstanceId -and $InstanceId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$') {
    throw 'Invalid windows.instanceId: use 1-40 letters, digits, underscores or hyphens.'
}
if (-not $PSBoundParameters.ContainsKey('GitHubUrl') -and $local.github.url) { $GitHubUrl = $local.github.url }
if (-not $PSBoundParameters.ContainsKey('ExtraLabels')) { $ExtraLabels = @($local.windows.labels | Where-Object { $_ }) }
if (-not $PSBoundParameters.ContainsKey('Name')) {
    if ($local.windows.name) { $Name = $local.windows.name }
    elseif ($InstanceId) { $Name += ".$InstanceId" }
}
if (-not $PSBoundParameters.ContainsKey('WorkFolder')) {
    if ($local.windows.workFolder) { $WorkFolder = $local.windows.workFolder }
    elseif ($InstanceId) { $WorkFolder = "%TEMP%\szr\$InstanceId" }
}
$local.github = $local.github ?? @{}
$local.github.url = $GitHubUrl
$local.windows = $local.windows ?? @{}
if ($InstanceId) { $local.windows.instanceId = $InstanceId }
$local.windows.name = $Name
$local.windows.labels = @(@($shared.windows.labels) + $ExtraLabels | Select-Object -Unique)
$local.windows.workFolder = $WorkFolder
$local | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $localPath
. "$PSScriptRoot\Common.ps1"

$parts = ([Uri]$GitHubUrl).AbsolutePath.Trim('/').Split('/')
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
. "$PSScriptRoot\RunnerArchive.ps1"
$scope = Get-RunnerScope $GitHubUrl
function Get-RunnerStatus {
    $runner = Get-GitHubRunner $scope $Name
    if ($runner) { $runner.Status }
}
if (Get-MaintenanceState) { throw "This runner is held in maintenance ($MaintenanceFile). Run Manage-WindowsRunner.ps1 -Action Start, then rerun this script." }

# Runner binaries, checked against the digest GitHub publishes for the release.
New-Item -ItemType Directory -Force $WindowsRunner | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $WindowsRunner 'config.cmd'))) {
    $archive = Get-RunnerArchive -Platform win-x64 -Version $Config.runnerVersion -DownloadDirectory (Join-Path $Root 'downloads')
    Expand-Archive -LiteralPath $archive.Path -DestinationPath $WindowsRunner -Force
    Write-Output "Runner $($Config.runnerVersion) extracted to $WindowsRunner."
}

# The private SDK the supervisor puts first on PATH; actions/setup-dotnet adds other versions next to it.
$dotnet = Join-Path $WindowsRunner '_tool\dotnet'
if (-not (Test-Path -LiteralPath (Join-Path $dotnet 'dotnet.exe'))) {
    & (Join-Path $PSScriptRoot 'dotnet-install.ps1') -Channel 10.0 -InstallDir $dotnet -NoPath
    if (-not (Test-Path -LiteralPath (Join-Path $dotnet 'dotnet.exe'))) { throw "The .NET SDK was not installed in $dotnet." }
}

# Registration. What the merged configuration asks for is compared with the local registration and with GitHub; every
# difference is applied or refused, never saved and ignored. Unchanged settings keep the name, id, labels and credentials.
$labelList = @(@($Config.github.labels) + @($Config.windows.labels) | Select-Object -Unique)
$labels = $labelList -join ','
$registration = Get-LocalRegistration $WindowsRunner
$plan = Get-RegistrationPlan `
    -Local $registration `
    -Remote (Get-GitHubRunner $scope $Name) `
    -LocalRemote $(if ($registration) { Get-GitHubRunner (Get-RunnerScope $registration.gitHubUrl) $registration.agentName }) `
    -Name $Name -GitHubUrl $GitHubUrl -Labels $labelList -WorkFolder $Config.windows.workFolder -RunnerDirectory $WindowsRunner `
    -HasCredentials (Test-Path -LiteralPath (Join-Path $WindowsRunner '.credentials')) -Replace:$Replace
foreach ($reason in $plan.Reasons) { Write-Output "Registration: $reason" }
$beforeChange = {
    if (-not (Get-SupervisorProcess) -and -not (Get-WindowsRunnerListeners)) {
        # Nothing is running, but Task Scheduler may be about to restart a supervisor that just died: make sure it cannot
        # (this is quick when nothing is pending), or leave the registration alone.
        $stopped = Stop-WindowsRunnerProcesses
        if (-not $stopped.Stopped) { throw "Registration not changed: Task Scheduler recovery of the supervisor could not be ruled out. $(@($stopped.Failures) -join ' ')" }
        return
    }
    if ($registration -and $plan.LinkedId) {
        # Wait for a running job rather than cancel it, and leave the registration alone if it outlasts the deadline.
        $stopped = Stop-WindowsRunner -Reason 'registration change'
        if ($stopped.Outcome -eq 'timeout') { throw "Registration not changed. $($stopped.Retained)" }
        if ($stopped.Outcome -eq 'failed') { throw "Registration not changed: the runner did not stop. $(@($stopped.Failures) -join ' ')" }
    }
    else {
        $stopped = Stop-WindowsRunnerProcesses
        if (-not $stopped.Stopped) { throw "Registration not changed: the runner did not stop. $(@($stopped.Failures) -join ' ')" }
    }
}
$applied = Invoke-RunnerRegistration -Plan $plan -RunnerDirectory $WindowsRunner -Name $Name -GitHubUrl $GitHubUrl -Replace:$Replace -BeforeChange $beforeChange
switch ($applied.Result) {
    'unchanged' { Write-Output "$Name is already registered from this clone with the requested settings." }
    'labels-added' { Write-Output "$Name keeps its registration; added labels $($applied.Labels -join ', ')." }
    default { Write-Output "$Name registered ($($applied.Result)); previous registration files saved in $($applied.Evidence)." }
}
$problems = @(Confirm-RunnerRegistration -RunnerDirectory $WindowsRunner -Name $Name -GitHubUrl $GitHubUrl -Labels $labelList -WorkFolder $Config.windows.workFolder)
if ($problems) { throw "The registration does not match the configuration:`n - $($problems -join "`n - ")" }
# Start at sign-in: the supervisor itself, not Start-Runners.ps1, which also needs Docker Desktop and the Linux container.
if (-not $InstanceId) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName 'Start runners' -Confirm:$false -ErrorAction SilentlyContinue }
# The task is the supervisor's own process, so Task Scheduler restarts the supervisor if it dies (bounded; see Common.ps1).
Register-WindowsSupervisorTask
& (Join-Path $PSScriptRoot 'Register-LogTrimTask.ps1')

if (-not (Get-SupervisorProcess)) { Start-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName }
for ($attempt = 0; $attempt -lt 24 -and ($status = Get-RunnerStatus) -ne 'online'; $attempt++) { Start-Sleep -Seconds 5 }
if ($status -ne 'online') { throw "$Name is $status after 2 minutes; see the newest Console_*.log in $(Join-Path $WindowsRunner '_diag')." }
Write-Output "$Name is online with labels self-hosted, Windows, X64, $labels."
