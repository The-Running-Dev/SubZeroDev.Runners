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
$startup = [scriptblock]::Create($installer.Substring($installer.IndexOf('# Start at sign-in:')).Replace('$PSScriptRoot', "(Join-Path `$Clone 'scripts')"))
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
    [pscustomobject]@{ Config = $Config; Mutex = $WindowsMutexName; StartTask = $WindowsTaskName; TrimTask = $LogTrimTaskName; Runner = $WindowsRunner }
}
function Test-TaskPlan([string] $Clone) {
    . (Join-Path $Clone 'scripts\Common.ps1')
    $InstanceId = $Config.windows.instanceId
    $Name = $Config.windows.name
    $taskCapture = @{ Records = [Collections.Generic.List[object]]::new(); Removed = [Collections.Generic.List[string]]::new(); Started = [Collections.Generic.List[string]]::new() }
    # Construct real Windows task actions/triggers/settings, but intercept registration and starts.
    # This verifies the actual installer tail and trim script without changing the CI host's tasks.
    function Register-ScheduledTask {
        param($TaskPath, $TaskName, $Action, $Trigger, $Principal, $Settings, $Description, [switch] $Force)
        $taskCapture.Records.Add([pscustomobject]@{ Path = $TaskPath; Name = $TaskName; Action = $Action; Trigger = $Trigger; Principal = $Principal; Settings = $Settings })
    }
    function Unregister-ScheduledTask { param($TaskPath, $TaskName, $Confirm, $ErrorAction) $taskCapture.Removed.Add($TaskName) }
    function Start-ScheduledTask { param($TaskPath, $TaskName) $taskCapture.Started.Add($TaskName) }
    function Get-SupervisorProcess { $null }
    function Get-RunnerStatus { 'online' }
    . $startup | Out-Null
    Assert ($taskCapture.Records.Count -eq 2) 'Expected startup and trim task plans.'
    $startTask, $trimTask = $taskCapture.Records
    Assert ($startTask.Name -eq $WindowsTaskName -and $trimTask.Name -eq $LogTrimTaskName) 'Task plan used another instance identity.'
    Assert ($startTask.Path -eq '\SubZeroDev.Runners\' -and $trimTask.Path -eq $startTask.Path) 'Task path changed.'
    Assert ($startTask.Action.Execute -eq $Pwsh -and $startTask.Action.Arguments.Contains('"' + $Supervisor + '"')) 'Startup action targets the wrong supervisor.'
    Assert ($startTask.Action.WorkingDirectory -eq $WindowsRunner) 'Startup working directory targets another clone.'
    Assert ($startTask.Trigger.Delay -eq 'PT30S' -and $startTask.Principal.LogonType -eq 'Interactive' -and $startTask.Principal.RunLevel -eq 'Limited') 'Sign-in principal or trigger changed.'
    Assert ($startTask.Settings.MultipleInstances -eq 'IgnoreNew' -and $startTask.Settings.ExecutionTimeLimit -eq 'PT0S') 'Supervisor task lifetime or duplicate policy changed.'
    Assert ($trimTask.Action.Arguments.Contains((Join-Path $Clone 'scripts\Trim-RunnerLogs.ps1'))) 'Trim action targets another clone.'
    Assert ($taskCapture.Started.Count -eq 1 -and $taskCapture.Started[0] -eq $WindowsTaskName) 'Wrong startup task started.'
    if ($InstanceId) { Assert ($taskCapture.Removed.Count -eq 0) 'Named setup removed a legacy startup task.' }
    else { Assert ($taskCapture.Removed.Count -eq 1 -and $taskCapture.Removed[0] -eq 'Start runners') 'Legacy combined startup migration changed.' }
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
    Assert ($a.StartTask -ne $b.StartTask) 'Startup tasks collide.'
    Assert ($a.TrimTask -ne $b.TrimTask) 'Log trim tasks collide.'
    Assert ($a.Config.windows.labels -contains 'subzerodev-windows') 'Shared workflow label was lost.'
    Assert ($a.Config.windows.labels -contains 'subzerodev-windows-large') 'Extra label was lost.'
    Assert ($legacy.Mutex -eq 'Local\SubZeroDev.Runners.Windows') 'Legacy mutex changed.'
    Assert ($legacy.StartTask -eq 'Start Windows runner' -and $legacy.TrimTask -eq 'Trim logs') 'Legacy task names changed.'
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
    Test-TaskPlan $aClone
    Test-TaskPlan $bClone
    Test-TaskPlan $legacyClone
    Write-Output 'PASS: named and legacy startup/trim task plans, interactive sign-in and duplicate-start policy (registration/start mocked).'
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
