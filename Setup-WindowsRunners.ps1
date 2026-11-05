#Requires -Version 5.1
<#
.SYNOPSIS
Bootstraps one or more native Windows runners from stock Windows PowerShell.
.DESCRIPTION
Run as the normal Windows user who will execute jobs. Missing prerequisites are installed
with WinGet (which is repaired if absent). Package installers can request UAC consent.
GitHub authorization is reused or opened once in a browser. No token is accepted as an argument.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 16)] [int] $Count = 2,
    [string] $InstallRoot = "$env:LOCALAPPDATA\SubZeroDev\Runners",
    [string] $GitHubUrl = 'https://github.com/AbsoluteZeroDev',
    [string[]] $ExtraLabels = @(),
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,199}$')] [string] $SourceRef = 'main',
    [string] $SmokeRepository,
    [switch] $NonInteractive
)

function Invoke-SetupNative {
    param([string] $File, [string[]] $Arguments, [switch] $Capture)
    $result = & $File @Arguments
    $code = $LASTEXITCODE
    if ($code) { throw "$(Split-Path $File -Leaf) failed (exit $code). Inspect the preceding output and rerun setup." }
    if ($Capture) { $result } else { $result | Out-Host }
}

function Update-SetupPath {
    # Keep process-only entries, then pick up installations without asking for a new terminal.
    $paths = @($env:PATH, [Environment]::GetEnvironmentVariable('PATH', 'Machine'), [Environment]::GetEnvironmentVariable('PATH', 'User'))
    $paths += "$env:ProgramFiles\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd", "$env:ProgramFiles\GitHub CLI", "$env:LOCALAPPDATA\Microsoft\WindowsApps", "$env:ProgramFiles\PowerShell\7"
    $env:PATH = (($paths -join ';').Split(';') | Where-Object { $_ } | Select-Object -Unique) -join ';'
}

function Find-SetupTool([string] $Name) {
    if ($Name -eq 'pwsh') {
        $path = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        if (Test-Path -LiteralPath $path) {
            $version = & $path -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            if ($LASTEXITCODE -eq 0 -and [version]$version -ge [version]'7.2') { return $path }
        }
        return
    }
    $command = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $command.Source }
}

function Test-SetupWinGet([string] $Path) {
    if (-not $Path) { return $false }
    & $Path --version *> $null
    $LASTEXITCODE -eq 0
}

function Repair-SetupWinGet {
    Write-Host 'Installing/repairing WinGet for this user...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ForceBootstrap | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Force -Repository PSGallery | Out-Null
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    try {
        Repair-WinGetPackageManager -Force -Latest -ErrorAction Stop | Out-Host
    } catch {
        Write-Host 'WinGet needs a machine repair. Approve the Windows elevation prompt; runner setup will continue in this normal user session.'
        $repair = @'
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -ForceBootstrap | Out-Null
    Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -Repository PSGallery | Out-Null
    Import-Module Microsoft.WinGet.Client
    Repair-WinGetPackageManager -AllUsers -Force -Latest
} catch { Write-Error $_; exit 1 }
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($repair))
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru
        if ($process.ExitCode) { throw 'Elevated WinGet repair failed. Rerun setup after resolving the displayed App Installer error.' }
        # Register/repair for the original user too, including when UAC used another administrator.
        Repair-WinGetPackageManager -Force -Latest -ErrorAction Stop | Out-Host
    }
}

function Install-SetupPrerequisites {
    Update-SetupPath
    $packages = [ordered]@{ pwsh = 'Microsoft.PowerShell'; git = 'Git.Git'; gh = 'GitHub.cli' }
    $tools = @{}
    $winget = $null
    foreach ($name in $packages.Keys) {
        $path = Find-SetupTool $name
        if (-not $path) {
            if (-not $winget) {
                $winget = Find-SetupTool 'winget'
                if (-not (Test-SetupWinGet $winget)) { Repair-SetupWinGet; Update-SetupPath; $winget = Find-SetupTool 'winget' }
                if (-not (Test-SetupWinGet $winget)) { throw 'WinGet is unavailable after repair. This setup needs a supported Windows desktop with App Installer.' }
            }
            Write-Host "Installing $($packages[$name])..."
            Invoke-SetupNative -File $winget -Arguments @('install', '--id', $packages[$name], '--exact', '--source', 'winget', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
            Update-SetupPath
            $path = Find-SetupTool $name
            if (-not $path) { throw "$($packages[$name]) finished but its executable is unavailable. A reboot may be required; rerun this same setup afterward." }
        }
        $tools[$name] = $path
    }
    $tools
}

function Sync-SetupCheckout {
    param([string] $Git, [string] $Path, [string] $Ref)
    $repository = 'https://github.com/The-Running-Dev/SubZeroDev.Runners.git'
    if (-not (Test-Path -LiteralPath $Path)) {
        Invoke-SetupNative -File $Git -Arguments @('clone', '--no-checkout', $repository, $Path)
    } else {
        if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Not a setup checkout: $Path" }
        $origin = Invoke-SetupNative -File $Git -Arguments @('-C', $Path, 'remote', 'get-url', 'origin') -Capture
        if ($origin -ne $repository) { throw "Unexpected repository at $Path" }
        $dirty = Invoke-SetupNative -File $Git -Arguments @('-C', $Path, 'status', '--porcelain') -Capture
        if ($dirty) { throw "Setup checkout has local changes: $Path. Preserve them before rerunning." }
        if (Test-Path -LiteralPath (Join-Path $Path 'runners.local.json')) { throw 'The setup checkout must not contain a configured runner.' }
    }
    Invoke-SetupNative -File $Git -Arguments @('-C', $Path, 'fetch', '--depth', '1', 'origin', $Ref)
    Invoke-SetupNative -File $Git -Arguments @('-C', $Path, 'checkout', '--detach', 'FETCH_HEAD')
    Invoke-SetupNative -File $Git -Arguments @('-C', $Path, 'rev-parse', 'HEAD') -Capture
}

function Start-WindowsRunnerSetup {
    param([int] $Count, [string] $InstallRoot, [string] $GitHubUrl, [string[]] $ExtraLabels, [string] $SourceRef, [string] $SmokeRepository, [bool] $NonInteractive)
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use 64-bit PowerShell on x64 Windows 10/11 or a compatible Windows VM.' }
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open a normal PowerShell window and run this same setup. Package installers request elevation separately; runner jobs must run unelevated.' }
    if (-not [IO.Path]::IsPathRooted($InstallRoot) -or $InstallRoot -match '(?i)\\Dropbox(\\|$)') { throw 'InstallRoot must be an absolute path outside Dropbox.' }
    $fullRoot = [IO.Path]::GetFullPath($InstallRoot)
    if ($fullRoot -eq [IO.Path]::GetPathRoot($fullRoot)) { throw 'InstallRoot must be a dedicated directory, not a drive root.' }
    $InstallRoot = $fullRoot.TrimEnd('\')
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $tools = Install-SetupPrerequisites
    $checkout = Join-Path $InstallRoot '_setup'
    $commit = Sync-SetupCheckout -Git $tools.git -Path $checkout -Ref $SourceRef
    $worker = Join-Path $checkout 'scripts\Configure-WindowsRunners.ps1'
    if (-not (Test-Path -LiteralPath $worker)) { throw "Source $SourceRef does not contain the automated setup worker." }
    # This file contains options only. Credentials stay in gh's store or the inherited environment.
    $optionsPath = Join-Path ([IO.Path]::GetTempPath()) ("windows-runner-setup-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        @{ Count = $Count; InstallRoot = $InstallRoot; GitHubUrl = $GitHubUrl; ExtraLabels = @($ExtraLabels); SourceCommit = "$commit"; SmokeRepository = $SmokeRepository; NonInteractive = $NonInteractive } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $optionsPath -Encoding UTF8
        Invoke-SetupNative -File $tools.pwsh -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $worker, '-OptionsPath', $optionsPath)
    } finally {
        Remove-Item -LiteralPath $optionsPath -Force -ErrorAction SilentlyContinue
    }
}

Start-WindowsRunnerSetup -Count $Count -InstallRoot $InstallRoot -GitHubUrl $GitHubUrl -ExtraLabels $ExtraLabels -SourceRef $SourceRef -SmokeRepository $SmokeRepository -NonInteractive ([bool]$NonInteractive)
