#Requires -Version 7.2
# Exercises the real installer's settings phase without downloads or GitHub registration.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
# Parse complete files before extracting the settings phase. A valid fragment must not hide a broken installer.
$files = @(Get-ChildItem (Join-Path $repo 'scripts'), $PSScriptRoot -Filter *.ps1 -Recurse) + @(Get-Item (Join-Path $repo 'Setup-WindowsRunners.ps1'))
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "PowerShell syntax errors in $($file.FullName): $($parseErrors -join '; ')" }
    if ($file.Name -eq 'Install-WindowsRunner.ps1') {
        $installerParameters = $ast.ParamBlock.Extent.Text
        $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if (($parameterNames -join ',') -ne 'Name,ExtraLabels,GitHubUrl,WorkFolder,Replace,InstanceId') {
            throw 'Installer parameter order changed or the instance parameter is missing.'
        }
        # Invoke only the real parameter block: binding tests must not download or register a runner.
        $bind = [scriptblock]::Create($ast.ParamBlock.Extent.Text + '; $InstanceId')
        foreach ($id in 'win01', ('a' * 40)) { if ((& $bind -InstanceId $id) -ne $id) { throw 'Valid instance ID rejected.' } }
        foreach ($id in '../bad', ('a' * 41), 'bad.id') {
            $rejected = $false
            try { & $bind -InstanceId $id | Out-Null } catch { $rejected = $true }
            if (-not $rejected) { throw "Unsafe instance ID accepted: $id" }
        }
    }
    $functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
    if ($functions | Group-Object Name | Where-Object Count -gt 1) { throw "Duplicated functions in $($file.Name)." }
}
Write-Output 'PASS: complete PowerShell files parse; installer parameter order and ID validation retained.'
$installer = Get-Content -Raw (Join-Path $repo 'scripts\Install-WindowsRunner.ps1')
$start = $installer.IndexOf('$localPath =')
$end = $installer.IndexOf('$parts =')
$setup = [scriptblock]::Create($installerParameters + "`n" + $installer.Substring($start, $end - $start).Replace('$PSScriptRoot\Common.ps1', '$root\scripts\Common.ps1'))
# The installer's tail: legacy cleanup, housekeeping, direct supervisor start, online wait. Nothing is registered with Windows.
$tailMarker = '# One-time removal of what earlier versions registered'
if ($installer.IndexOf($tailMarker) -lt 0) { throw 'The installer tail marker is gone; update this test.' }
$tailText = $installer.Substring($installer.IndexOf($tailMarker))
foreach ($forbidden in 'Register-ScheduledTask', 'Set-WindowsStartup', 'Register-LogTrimTask', 'Start-ScheduledTask') {
    if ($installer.Contains($forbidden)) { throw "The installer still mentions $forbidden." }
}
# LegacyCleanup.ps1 is not loaded (the test fakes Remove-LegacyStartupTasks) and the real housekeeping must not run: it trims caches.
$tailText = $tailText.Replace('. "$PSScriptRoot\LegacyCleanup.ps1"', '').Replace("& (Join-Path `$PSScriptRoot 'Trim-RunnerLogs.ps1')", '$direct.Trimmed.Add($WindowsRunner)')
if ($tailText.Contains('Trim-RunnerLogs.ps1') -or $tailText.Contains('LegacyCleanup.ps1')) { throw 'The installer tail changed; update the test replacements.' }
$startup = [scriptblock]::Create($tailText)
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('runner-instances-' + [guid]::NewGuid().ToString('N'))
function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function New-Fixture([string] $Id) {
    $clone = Join-Path $fixture $Id
    New-Item -ItemType Directory -Path (Join-Path $clone 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'runners.json') -Destination $clone
    # The whole scripts directory: Common.ps1 dot-sources the shared loader and modules beside it.
    Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -File | Copy-Item -Destination (Join-Path $clone 'scripts')
    $clone
}
function Invoke-Settings {
    param([string] $Clone, [string] $InstanceId, [string] $Name = "subzerodev.runner.windows.$($env:COMPUTERNAME.ToLowerInvariant())", [string] $WorkFolder = '%TEMP%\szr', [string[]] $ExtraLabels = @(), [string] $GitHubUrl = 'https://github.com/AbsoluteZeroDev')
    $root = $Clone
    $arguments = @{}
    foreach ($key in $PSBoundParameters.Keys) { if ($key -ne 'Clone') { $arguments[$key] = $PSBoundParameters[$key] } }
    . $setup @arguments
    [pscustomobject]@{ Config = $Config; Mutex = $WindowsMutexName; LegacyStartTask = $LegacyWindowsTaskName; LegacyTrimTask = $LegacyLogTrimTaskName; Runner = $WindowsRunner }
}
function Test-DirectStart([string] $Clone) {
    . (Join-Path $Clone 'scripts\Common.ps1')
    . (Join-Path $Clone 'scripts\Registration.ps1')
    . (Join-Path $Clone 'scripts\Lifecycle.ps1')
    $InstanceId = $Config.windows.instanceId
    $Name = $Config.windows.name
    $direct = @{ Started = [Collections.Generic.List[object]]::new(); Trimmed = [Collections.Generic.List[string]]::new(); Cleanups = [Collections.Generic.List[object]]::new() }
    # Run the real installer tail and the real Start-WindowsRunner, with the process launch and the cleanup intercepted. Nothing
    # is registered with Windows, no process is started, and no real task or Run entry is looked at.
    function Start-Process {
        param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch] $PassThru)
        $direct.Started.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = @($ArgumentList); WorkingDirectory = $WorkingDirectory; WindowStyle = $WindowStyle })
        [pscustomobject]@{ Id = 987700 }
    }
    function Remove-LegacyStartupTasks {
        # Called with no arguments by the installer: what it would target is decided by the names in this scope.
        $direct.Cleanups.Add([pscustomobject]@{ Start = $LegacyWindowsTaskName; Trim = $LegacyLogTrimTaskName; Script = $Supervisor; Combined = (-not $Config.windows.instanceId) })
        [pscustomobject]@{ Removed = @(); Kept = @(); Failed = @() }
    }
    function Get-SupervisorProcess { $null }
    function Get-RunnerStatus { 'online' }
    . $startup | Out-Null
    Assert ($direct.Started.Count -eq 1) "Expected exactly one supervisor launch, got $($direct.Started.Count)."
    $launch = $direct.Started[0]
    Assert ($launch.FilePath -eq $Pwsh -and $launch.WindowStyle -eq 'Hidden') 'The supervisor is not launched as a hidden pwsh.'
    Assert ($launch.ArgumentList[-2] -eq '-File' -and $launch.ArgumentList[-1] -eq ('"' + $Supervisor + '"')) "Launch targets the wrong supervisor: $($launch.ArgumentList -join ' ')"
    Assert ($Supervisor.StartsWith($Clone, [StringComparison]::OrdinalIgnoreCase) -and $launch.WorkingDirectory -eq $WindowsRunner -and $WindowsRunner.StartsWith($Clone, [StringComparison]::OrdinalIgnoreCase)) 'Launch targets another clone.'
    Assert ($direct.Cleanups.Count -eq 1 -and $direct.Trimmed.Count -eq 1) 'The installer tail did not run the one-time cleanup and the housekeeping once each.'
    $cleanup = $direct.Cleanups[0]
    if ($InstanceId) {
        Assert ($cleanup.Start -eq "Start Windows runner ($InstanceId)" -and $cleanup.Trim -eq "Trim logs ($InstanceId)") "Legacy cleanup names another instance: $($cleanup.Start) / $($cleanup.Trim)"
        Assert (-not $cleanup.Combined) 'A named instance would clean up the combined legacy task of the unnamed install.'
    }
    else {
        Assert ($cleanup.Start -eq 'Start Windows runner' -and $cleanup.Trim -eq 'Trim logs' -and $cleanup.Combined) 'Legacy cleanup names changed for the unnamed install.'
    }
}
try {
    $aClone = New-Fixture 'a'
    $bClone = New-Fixture 'b'
    $legacyClone = New-Fixture 'legacy'
    $a = Invoke-Settings -Clone $aClone -InstanceId 'win01' -ExtraLabels subzerodev-windows-large
    $b = Invoke-Settings -Clone $bClone -InstanceId 'win02' -ExtraLabels subzerodev-windows-large
    $legacy = Invoke-Settings -Clone $legacyClone
    Assert ($a.Config.windows.name -ne $b.Config.windows.name) 'Runner names collide.'
    Assert ($a.Config.windows.workFolder -ne $b.Config.windows.workFolder) 'Workspaces collide.'
    Assert ($a.Runner -ne $b.Runner) 'Runner installations collide.'
    Assert ($a.Mutex -ne $b.Mutex) 'Supervisor mutexes collide.'
    Assert ($a.LegacyStartTask -ne $b.LegacyStartTask) 'Legacy startup task names collide.'
    Assert ($a.LegacyTrimTask -ne $b.LegacyTrimTask) 'Legacy log trim task names collide.'
    Assert ($a.Config.windows.labels -contains 'subzerodev-windows') 'Shared workflow label was lost.'
    Assert ($a.Config.windows.labels -contains 'subzerodev-windows-large') 'Extra label was lost.'
    Assert ($legacy.Mutex -eq 'Local\SubZeroDev.Runners.Windows') 'Legacy mutex changed.'
    Assert ($legacy.LegacyStartTask -eq 'Start Windows runner' -and $legacy.LegacyTrimTask -eq 'Trim logs') 'Legacy task names changed.'
    Assert ($legacy.Config.windows.workFolder -eq '%TEMP%\szr') 'Legacy workspace changed.'
    Assert ($a.Config.windows.name -eq "subzerodev.runner.windows.$($env:COMPUTERNAME.ToLowerInvariant()).win01") 'Unexpected default runner name.'
    Assert ($a.Config.windows.workFolder -eq '%TEMP%\szr\win01') 'Unexpected default instance workspace.'
    $again = Invoke-Settings -Clone $aClone
    Assert ($again.Config.windows.name -eq $a.Config.windows.name -and $again.Config.windows.workFolder -eq $a.Config.windows.workFolder -and $again.Mutex -eq $a.Mutex) 'Rerun lost instance settings.'
    Assert ($again.Config.windows.labels -contains 'subzerodev-windows-large') 'Rerun lost the host targeting label.'
    $recased = Invoke-Settings -Clone $aClone -InstanceId 'WIN01'
    Assert ($recased.Mutex -ceq $a.Mutex) 'Case-only rerun changed the supervisor mutex identity.'
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
    $customClone = New-Fixture 'custom'
    @{ github = @{ url = 'https://github.com/example/project' }; windows = @{ directory = 'custom-runner'; name = 'existing-name'; workFolder = 'C:\RunnerWork\existing' }; logs = @{ retentionDays = 3 } } |
        ConvertTo-Json -Depth 10 | Set-Content (Join-Path $customClone 'runners.local.json')
    New-Item -ItemType Directory -Path (Join-Path $customClone 'custom-runner') -Force | Out-Null
    Set-Content (Join-Path $customClone 'custom-runner\.runner') '{}'
    $before = Get-Content -Raw (Join-Path $customClone 'runners.local.json')
    $rejected = $false
    try { Invoke-Settings -Clone $customClone -InstanceId 'win04' | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Custom windows.directory registration was ignored.'
    Assert ((Get-Content -Raw (Join-Path $customClone 'runners.local.json')) -eq $before) 'Rejected custom-directory setup changed settings.'
    $custom = Invoke-Settings -Clone $customClone
    Assert ($custom.Config.windows.name -eq 'existing-name' -and $custom.Config.windows.workFolder -eq 'C:\RunnerWork\existing') 'Existing unnamed identity changed.'
    Assert ($custom.Config.github.url -eq 'https://github.com/example/project' -and $custom.Config.logs.retentionDays -eq 3) 'Saved scope or unrelated settings changed.'
    $override = Invoke-Settings -Clone $aClone -Name 'custom-win01' -WorkFolder 'C:\RunnerWork\win01' -ExtraLabels @('custom-label') -GitHubUrl 'https://github.com/example/other'
    $retained = Invoke-Settings -Clone $aClone
    Assert ($retained.Config.windows.name -eq 'custom-win01' -and $retained.Config.windows.workFolder -eq 'C:\RunnerWork\win01') 'Explicit identity overrides were not persisted.'
    Assert ($retained.Config.github.url -eq 'https://github.com/example/other' -and $retained.Config.windows.labels -contains 'custom-label') 'Explicit scope or label overrides were not persisted.'
    $invalidClone = New-Fixture 'invalid'
    '{"windows":{"instanceId":"../bad"}}' | Set-Content (Join-Path $invalidClone 'runners.local.json')
    $before = Get-Content -Raw (Join-Path $invalidClone 'runners.local.json')
    $rejected = $false
    try { Invoke-Settings -Clone $invalidClone | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Invalid saved instance ID accepted.'
    Assert ((Get-Content -Raw (Join-Path $invalidClone 'runners.local.json')) -eq $before) 'Invalid saved ID changed settings.'
    Test-DirectStart $aClone
    Test-DirectStart $bClone
    Test-DirectStart $legacyClone
    Write-Output 'PASS: named and unnamed installs start their own supervisor directly and scope the legacy cleanup to their instance (launch and cleanup mocked; nothing registered).'
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
        if (-not ($job | Wait-Job -Timeout 30)) { $job | Stop-Job; $job | Remove-Job; throw 'Mutex child process timed out.' }
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
