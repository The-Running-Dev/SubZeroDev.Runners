#Requires -Version 7.2
# Exercises the real installer's settings phase without downloads or GitHub registration.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$installer = Get-Content -Raw (Join-Path $repo 'scripts\Install-WindowsRunner.ps1')
$start = $installer.IndexOf('$localPath =')
$end = $installer.IndexOf('$parts =')
$setup = [scriptblock]::Create($installer.Substring($start, $end - $start).Replace('$PSScriptRoot\Common.ps1', '$root\scripts\Common.ps1'))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-instances-' + [guid]::NewGuid().ToString('N'))
function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function New-Fixture([string] $Id) {
    $clone = Join-Path $fixture $Id
    New-Item -ItemType Directory -Path (Join-Path $clone 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'runners.json') -Destination $clone
    Copy-Item -LiteralPath (Join-Path $repo 'scripts\Common.ps1') -Destination (Join-Path $clone 'scripts')
    $clone
}
function Invoke-Settings {
    param([string] $Clone, [string] $InstanceId, [string] $Name = "subzerodev.runner.windows.$($env:COMPUTERNAME.ToLowerInvariant())", [string] $WorkFolder = '%TEMP%\szr')
    $root = $Clone
    $ExtraLabels = @('subzerodev-windows-large')
    $GitHubUrl = 'https://github.com/AbsoluteZeroDev'
    . $setup
    [pscustomobject]@{ Config = $Config; Mutex = $WindowsMutexName; StartTask = $WindowsTaskName; TrimTask = $LogTrimTaskName; Runner = $WindowsRunner }
}
try {
    $aClone = New-Fixture 'a'
    $bClone = New-Fixture 'b'
    $legacyClone = New-Fixture 'legacy'
    $a = Invoke-Settings -Clone $aClone -InstanceId 'win01'
    $b = Invoke-Settings -Clone $bClone -InstanceId 'win02'
    $legacy = Invoke-Settings -Clone $legacyClone
    Assert ($a.Config.windows.name -ne $b.Config.windows.name) 'Runner names collide.'
    Assert ($a.Config.windows.workFolder -ne $b.Config.windows.workFolder) 'Workspaces collide.'
    Assert ($a.Runner -ne $b.Runner) 'Runner installations collide.'
    Assert ($a.Mutex -ne $b.Mutex) 'Supervisor mutexes collide.'
    Assert ($a.StartTask -ne $b.StartTask) 'Startup tasks collide.'
    Assert ($a.TrimTask -ne $b.TrimTask) 'Log trim tasks collide.'
    Assert ($a.Config.windows.labels -contains 'subzerodev-windows') 'Shared workflow label was lost.'
    Assert ($a.Config.windows.labels -contains 'subzerodev-windows-large') 'Extra label was lost.'
    Assert ($legacy.Mutex -eq 'Local\SubZeroDev.Runners.Windows') 'Legacy mutex changed.'
    Assert ($legacy.StartTask -eq 'Start Windows runner' -and $legacy.TrimTask -eq 'Trim logs') 'Legacy task names changed.'
    Assert ($legacy.Config.windows.workFolder -eq '%TEMP%\szr') 'Legacy workspace changed.'
    $again = Invoke-Settings -Clone $aClone
    Assert ($again.Config.windows.name -eq $a.Config.windows.name -and $again.Config.windows.workFolder -eq $a.Config.windows.workFolder -and $again.Mutex -eq $a.Mutex) 'Rerun lost instance settings.'
    $before = Get-Content -Raw (Join-Path $aClone 'runners.local.json')
    $rejected = $false
    try { Invoke-Settings -Clone $aClone -InstanceId 'win99' | Out-Null } catch { $rejected = $true }
    Assert $rejected 'An existing clone accepted a different instance ID.'
    Assert ((Get-Content -Raw (Join-Path $aClone 'runners.local.json')) -eq $before) 'Rejected setup changed settings.'
    New-Item -ItemType Directory -Path (Join-Path $legacyClone 'windows') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $legacyClone 'windows\.runner') -Value '{}'
    $rejected = $false
    try { Invoke-Settings -Clone $legacyClone -InstanceId 'win03' | Out-Null } catch { $rejected = $true }
    Assert $rejected 'A configured unnamed clone was reused for a named instance.'
    $mutex = [Threading.Mutex]::new($false, $a.Mutex)
    Assert ($mutex.WaitOne(0)) 'Could not acquire first instance mutex.'
    try {
        $job = Start-Job -ScriptBlock {
            param($First, $Second)
            $one = [Threading.Mutex]::new($false, $First)
            $two = [Threading.Mutex]::new($false, $Second)
            try {
                $same = $one.WaitOne(0)
                $different = $two.WaitOne(0)
                if ($same) { $one.ReleaseMutex() }
                if ($different) { $two.ReleaseMutex() }
                [pscustomobject]@{ Same = $same; Different = $different }
            } finally { $one.Dispose(); $two.Dispose() }
        } -ArgumentList $a.Mutex, $b.Mutex
        $result = $job | Receive-Job -Wait -AutoRemoveJob
        Assert (-not $result.Same -and $result.Different) 'Instance mutex exclusion failed.'
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    Write-Output 'PASS: two isolated instances, retained legacy defaults, safe reruns and cross-process mutex exclusion.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped the temporary directory.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
