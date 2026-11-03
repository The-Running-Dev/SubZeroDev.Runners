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
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39})
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Dropbox syncs windows\.runner and .credentials*, so two machines sharing that folder overwrite each other's registration.
if ($root -match '(?i)\\Dropbox(\\|$)') { throw "Clone this repository outside Dropbox (for example C:\SubZeroDev.Runners) and run it from there; $root is synced." }
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from a normal, not elevated, PowerShell 7 window: the runner and its jobs run as this user.' }
$missing = @(
    if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) { 'Microsoft.PowerShell' }
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
if (-not $InstanceId) { $InstanceId = $local.windows.instanceId }
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
$scope = if ($parts.Count -eq 1) { "orgs/$($parts[0])" } else { "repos/$($parts[0])/$($parts[1])" }
function Get-RunnerToken([string] $Kind) {
    $token = gh api -X POST "$scope/actions/runners/$Kind-token" --jq .token
    if ($LASTEXITCODE -or -not $token) { throw "No $Kind token for $GitHubUrl. gh must be signed in as its admin with the admin:org scope: gh auth refresh --hostname github.com --scopes admin:org" }
    $token
}
function Get-RunnerStatus {
    $row = gh api "$scope/actions/runners" --paginate --jq '.runners[] | [.name, .status] | @tsv' | Where-Object { $_.Split("`t")[0] -eq $Name }
    if ($row) { $row.Split("`t")[1] }
}

# Runner binaries, checked against the digest GitHub publishes for the release.
$version = $Config.runnerVersion
$zipName = "actions-runner-win-x64-$version.zip"
$downloads = Join-Path $Root 'downloads'
New-Item -ItemType Directory -Force $downloads, $WindowsRunner | Out-Null
$zip = Join-Path $downloads $zipName
if (-not (Test-Path -LiteralPath (Join-Path $WindowsRunner 'config.cmd'))) {
    if (-not (Test-Path -LiteralPath $zip)) {
        Write-Output "Downloading $zipName..."
        Invoke-WebRequest "https://github.com/actions/runner/releases/download/v$version/$zipName" -OutFile $zip
    }
    $release = gh api "repos/actions/runner/releases/tags/v$version" | ConvertFrom-Json
    $digest = ($release.assets | Where-Object name -eq $zipName).digest
    $expected = if ($digest) { $digest -replace '^sha256:' } elseif ($release.body -match '<!-- BEGIN SHA win-x64 -->([0-9a-f]{64})<!-- END SHA win-x64 -->') { $Matches[1] }
    if (-not $expected) { throw "GitHub publishes no SHA-256 for $zipName; not extracting it." }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
        Remove-Item -LiteralPath $zip
        throw "$zipName does not match its published SHA-256 and was deleted; rerun to download it again."
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $WindowsRunner -Force
    Write-Output "Runner $version extracted to $WindowsRunner."
}

# The private SDK the supervisor puts first on PATH; actions/setup-dotnet adds other versions next to it.
$dotnet = Join-Path $WindowsRunner '_tool\dotnet'
if (-not (Test-Path -LiteralPath (Join-Path $dotnet 'dotnet.exe'))) {
    & (Join-Path $PSScriptRoot 'dotnet-install.ps1') -Channel 10.0 -InstallDir $dotnet -NoPath
}

# Registration. A rerun with the same name keeps the existing one.
$registration = Join-Path $WindowsRunner '.runner'
$registeredHere = if (Test-Path -LiteralPath $registration) { (Get-Content -Raw -LiteralPath $registration | ConvertFrom-Json).agentName }
$labels = (@($Config.github.labels) + @($Config.windows.labels)) -join ','
$status = Get-RunnerStatus
if ($registeredHere -eq $Name -and $status) {
    Write-Output "$Name is already registered from this machine ($status)."
}
else {
    if ($status -and -not $Replace) { throw "A runner named $Name is already registered elsewhere ($status). Pick another -Name, or pass -Replace to take its place." }
    $supervisor = Get-SupervisorProcess
    if ($supervisor) { taskkill.exe /PID $supervisor.ProcessId /T /F | Out-Null }
    $configure = Join-Path $WindowsRunner 'config.cmd'
    if ($registeredHere) {
        & $configure remove --token (Get-RunnerToken 'remove')
        Remove-Item -LiteralPath ('.runner', '.runner_migrated', '.credentials', '.credentials_migrated', '.credentials_rsaparams' | ForEach-Object { Join-Path $WindowsRunner $_ }) -Force -ErrorAction SilentlyContinue
    }
    $arguments = @('--unattended', '--url', $GitHubUrl, '--token', (Get-RunnerToken 'registration'), '--name', $Name, '--labels', $labels, '--work', [Environment]::ExpandEnvironmentVariables($Config.windows.workFolder))
    if ($Replace) { $arguments += '--replace' }
    & $configure @arguments
    if ($LASTEXITCODE) { throw "Registering $Name failed." }
}

# Start at sign-in: the supervisor itself, not Start-Runners.ps1, which also needs Docker Desktop and the Linux container.
if (-not $InstanceId) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName 'Start runners' -Confirm:$false -ErrorAction SilentlyContinue }
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Supervisor`"" -WorkingDirectory $WindowsRunner
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT30S'
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
# The supervisor never exits on its own, so no time limit; it also holds a mutex against a second copy.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the SubZeroDev Windows runner supervisor at sign-in.' -Force | Out-Null
& (Join-Path $PSScriptRoot 'Register-LogTrimTask.ps1')

if (-not (Get-SupervisorProcess)) { Start-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName }
for ($attempt = 0; $attempt -lt 24 -and ($status = Get-RunnerStatus) -ne 'online'; $attempt++) { Start-Sleep -Seconds 5 }
if ($status -ne 'online') { throw "$Name is $status after 2 minutes; see the newest Console_*.log in $(Join-Path $WindowsRunner '_diag')." }
Write-Output "$Name is online with labels self-hosted, Windows, X64, $labels."
)]
    [string] $InstanceId
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Dropbox syncs windows\.runner and .credentials*, so two machines sharing that folder overwrite each other's registration.
if ($root -match '(?i)\\Dropbox(\\|$)') { throw "Clone this repository outside Dropbox (for example C:\SubZeroDev.Runners) and run it from there; $root is synced." }
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run from a normal, not elevated, PowerShell 7 window: the runner and its jobs run as this user.' }
$missing = @(
    if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) { 'Microsoft.PowerShell' }
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
$local.github = $local.github ?? @{}
$local.github.url = $GitHubUrl
$local.windows = $local.windows ?? @{}
$local.windows.name = $Name
$local.windows.labels = @(@($shared.windows.labels) + $ExtraLabels | Select-Object -Unique)
$local.windows.workFolder = $WorkFolder
$local | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $localPath
. "$PSScriptRoot\Common.ps1"

$parts = ([Uri]$GitHubUrl).AbsolutePath.Trim('/').Split('/')
$scope = if ($parts.Count -eq 1) { "orgs/$($parts[0])" } else { "repos/$($parts[0])/$($parts[1])" }
function Get-RunnerToken([string] $Kind) {
    $token = gh api -X POST "$scope/actions/runners/$Kind-token" --jq .token
    if ($LASTEXITCODE -or -not $token) { throw "No $Kind token for $GitHubUrl. gh must be signed in as its admin with the admin:org scope: gh auth refresh --hostname github.com --scopes admin:org" }
    $token
}
function Get-RunnerStatus {
    $row = gh api "$scope/actions/runners" --paginate --jq '.runners[] | [.name, .status] | @tsv' | Where-Object { $_.Split("`t")[0] -eq $Name }
    if ($row) { $row.Split("`t")[1] }
}

# Runner binaries, checked against the digest GitHub publishes for the release.
$version = $Config.runnerVersion
$zipName = "actions-runner-win-x64-$version.zip"
$downloads = Join-Path $Root 'downloads'
New-Item -ItemType Directory -Force $downloads, $WindowsRunner | Out-Null
$zip = Join-Path $downloads $zipName
if (-not (Test-Path -LiteralPath (Join-Path $WindowsRunner 'config.cmd'))) {
    if (-not (Test-Path -LiteralPath $zip)) {
        Write-Output "Downloading $zipName..."
        Invoke-WebRequest "https://github.com/actions/runner/releases/download/v$version/$zipName" -OutFile $zip
    }
    $release = gh api "repos/actions/runner/releases/tags/v$version" | ConvertFrom-Json
    $digest = ($release.assets | Where-Object name -eq $zipName).digest
    $expected = if ($digest) { $digest -replace '^sha256:' } elseif ($release.body -match '<!-- BEGIN SHA win-x64 -->([0-9a-f]{64})<!-- END SHA win-x64 -->') { $Matches[1] }
    if (-not $expected) { throw "GitHub publishes no SHA-256 for $zipName; not extracting it." }
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) {
        Remove-Item -LiteralPath $zip
        throw "$zipName does not match its published SHA-256 and was deleted; rerun to download it again."
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $WindowsRunner -Force
    Write-Output "Runner $version extracted to $WindowsRunner."
}

# The private SDK the supervisor puts first on PATH; actions/setup-dotnet adds other versions next to it.
$dotnet = Join-Path $WindowsRunner '_tool\dotnet'
if (-not (Test-Path -LiteralPath (Join-Path $dotnet 'dotnet.exe'))) {
    & (Join-Path $PSScriptRoot 'dotnet-install.ps1') -Channel 10.0 -InstallDir $dotnet -NoPath
}

# Registration. A rerun with the same name keeps the existing one.
$registration = Join-Path $WindowsRunner '.runner'
$registeredHere = if (Test-Path -LiteralPath $registration) { (Get-Content -Raw -LiteralPath $registration | ConvertFrom-Json).agentName }
$labels = (@($Config.github.labels) + @($Config.windows.labels)) -join ','
$status = Get-RunnerStatus
if ($registeredHere -eq $Name -and $status) {
    Write-Output "$Name is already registered from this machine ($status)."
}
else {
    if ($status -and -not $Replace) { throw "A runner named $Name is already registered elsewhere ($status). Pick another -Name, or pass -Replace to take its place." }
    $supervisor = Get-SupervisorProcess
    if ($supervisor) { taskkill.exe /PID $supervisor.ProcessId /T /F | Out-Null }
    $configure = Join-Path $WindowsRunner 'config.cmd'
    if ($registeredHere) {
        & $configure remove --token (Get-RunnerToken 'remove')
        Remove-Item -LiteralPath ('.runner', '.runner_migrated', '.credentials', '.credentials_migrated', '.credentials_rsaparams' | ForEach-Object { Join-Path $WindowsRunner $_ }) -Force -ErrorAction SilentlyContinue
    }
    $arguments = @('--unattended', '--url', $GitHubUrl, '--token', (Get-RunnerToken 'registration'), '--name', $Name, '--labels', $labels, '--work', [Environment]::ExpandEnvironmentVariables($Config.windows.workFolder))
    if ($Replace) { $arguments += '--replace' }
    & $configure @arguments
    if ($LASTEXITCODE) { throw "Registering $Name failed." }
}

# Start at sign-in: the supervisor itself, not Start-Runners.ps1, which also needs Docker Desktop and the Linux container.
Unregister-ScheduledTask -TaskPath $TaskPath -TaskName 'Start runners' -Confirm:$false -ErrorAction SilentlyContinue
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Supervisor`"" -WorkingDirectory $WindowsRunner
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT30S'
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
# The supervisor never exits on its own, so no time limit; it also holds a mutex against a second copy.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the SubZeroDev Windows runner supervisor at sign-in.' -Force | Out-Null
& (Join-Path $PSScriptRoot 'Register-LogTrimTask.ps1')

if (-not (Get-SupervisorProcess)) { Start-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName }
for ($attempt = 0; $attempt -lt 24 -and ($status = Get-RunnerStatus) -ne 'online'; $attempt++) { Start-Sleep -Seconds 5 }
if ($status -ne 'online') { throw "$Name is $status after 2 minutes; see the newest Console_*.log in $(Join-Path $WindowsRunner '_diag')." }
Write-Output "$Name is online with labels self-hosted, Windows, X64, $labels."
