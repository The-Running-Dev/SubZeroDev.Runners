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
    # Tests redefine their mocks inside separate scenario scopes by design; only shipped scripts must not duplicate functions.
    if ($file.FullName -notlike "$PSScriptRoot*" -and ($functions | Group-Object Name | Where-Object Count -gt 1)) { throw "Duplicated functions in $($file.Name)." }
}
Write-Output 'PASS: complete PowerShell files parse; installer parameter order and ID validation retained.'
$installer = Get-Content -Raw (Join-Path $repo 'scripts\Install-WindowsRunner.ps1')
$start = $installer.IndexOf('$localPath =')
$end = $installer.IndexOf('try {', $start)
if ($end -lt 0) { throw 'The installer no longer guards its settings write with try; update the test.' }
$setup = [scriptblock]::Create($installerParameters + "`n" + $installer.Substring($start, $end - $start) + "`n. `"`$root\scripts\Common.ps1`"")
# The whole installer from the settings phase on, run in-process (the real one refuses an elevated session, as on CI). Every call
# that would download, register, stop or start is replaced after the real modules load, and the process launch and the scheduler
# are faked, so nothing is registered with Windows and no real task or Run entry is looked at.
foreach ($forbidden in 'Register-ScheduledTask', 'Set-WindowsStartup', 'Register-LogTrimTask', 'Start-ScheduledTask', 'ScheduledTasks', 'schtasks') {
    if ($installer.Contains($forbidden)) { throw "The installer still mentions $forbidden." }
}
$order = 'Invoke-LegacyMigration', 'Get-RunnerArchive', 'Invoke-RunnerRegistration', 'Trim-RunnerLogs.ps1', 'Start-WindowsRunner' | ForEach-Object { $installer.IndexOf($_) }
if ($order -contains -1 -or (($order | Sort-Object) -join ',') -ne ($order -join ',')) { throw "The installer no longer migrates legacy startup entries before it downloads, registers or starts: $($order -join ',')." }
$archiveLoad = '. "$PSScriptRoot\RunnerArchive.ps1"'
$cleanupLoad = '. "$PSScriptRoot\LegacyCleanup.ps1"'
$fullText = $installer.Substring($start).
    Replace('& (Join-Path $PSScriptRoot ''Trim-RunnerLogs.ps1'')', '$trace.Add(''trim'')').
    Replace($archiveLoad, $archiveLoad + "`n. `$injectFakes").
    Replace($cleanupLoad, $cleanupLoad + "`n. `$injectScheduler").
    Replace('$PSScriptRoot', '$scriptsDir')
foreach ($needle in '$trace.Add', '$injectFakes', '$injectScheduler') { if (-not $fullText.Contains($needle)) { throw "The installer changed; update the test replacements ($needle)." } }
$full = [scriptblock]::Create($installerParameters + "`n" + $fullText)
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
# Installer harness. Everything that downloads, registers, stops or starts is replaced after the real modules load; the
# supervisor launch and Task Scheduler are fakes that record what was asked of them.
$injectFakes = {
    function Get-RunnerArchive { $trace.Add('archive'); throw 'The test fake must not download.' }
    function Get-GitHubRunner { $trace.Add('github'); [pscustomobject]@{ Status = 'online' } }
    function Get-LocalRegistration { $trace.Add('local-registration'); $null }
    function Get-RegistrationPlan { $trace.Add('plan'); [pscustomobject]@{ Reasons = @(); LinkedId = $null } }
    function Invoke-RunnerRegistration { $trace.Add('register'); [pscustomobject]@{ Result = 'unchanged' } }
    function Confirm-RunnerRegistration { $trace.Add('confirm'); @() }
    function Stop-WindowsRunner { $trace.Add('stop'); [pscustomobject]@{ Outcome = 'stopped' } }
    function Stop-WindowsRunnerProcesses { $trace.Add('stop'); [pscustomobject]@{ Stopped = $true } }
    function Get-SupervisorProcess { if ($direct.Started.Count) { [pscustomobject]@{ ProcessId = 987700 } } }
    function Start-Process {
        param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch] $PassThru)
        $trace.Add('start')
        $direct.Started.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = @($ArgumentList); WorkingDirectory = $WorkingDirectory; WindowStyle = $WindowStyle })
        # What a healthy supervisor writes once it has initialized.
        Set-SupervisorStatusValues @{ state = 'running'; pid = 987700; startedUtc = [DateTime]::UtcNow.ToString('o') }
        [pscustomobject]@{ Id = 987700 }
    }
}
# Scheduler fake: the real Remove-LegacyStartupTasks (names, ownership, verification) over Get/Remove scriptblocks that log into
# $trace as get:<name> / remove:<name>. $schedulerPlan: Tasks (name -> script it runs), InspectError, RemoveError.
$injectScheduler = {
    $realRemove = ${function:Remove-LegacyStartupTasks}
    $fakeTasks = $schedulerPlan.Tasks
    $fakeGone = [Collections.Generic.HashSet[string]]::new()
    $fakeInspectError = $schedulerPlan.InspectError
    $fakeRemoveError = $schedulerPlan.RemoveError
    $fakeGet = {
        param($Path, $TaskName)
        $trace.Add("get:$TaskName")
        if ($fakeInspectError) { throw $fakeInspectError }
        if ($fakeTasks.ContainsKey($TaskName) -and -not $fakeGone.Contains($TaskName)) {
            return [pscustomobject]@{ Actions = @([pscustomobject]@{ Arguments = "-File `"$($fakeTasks[$TaskName])`"" }) }
        }
        throw "No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'."
    }.GetNewClosure()
    $fakeRemove = {
        param($Path, $TaskName)
        $trace.Add("remove:$TaskName")
        if ($fakeRemoveError) { throw $fakeRemoveError }
        [void]$fakeGone.Add($TaskName)
    }.GetNewClosure()
    # A fresh clone has an empty runner folder when the migration runs; the installer's later steps need the runner files, so they
    # are put in place right after the migration returns.
    $realMigration = ${function:Invoke-LegacyMigration}
    function Invoke-LegacyMigration {
        $result = & $realMigration
        if ($deferFiles) { New-Item -ItemType Directory -Path (Join-Path $WindowsRunner '_tool\dotnet') -Force | Out-Null; Set-Content -LiteralPath (Join-Path $WindowsRunner 'config.cmd') -Value ''; Set-Content -LiteralPath (Join-Path $WindowsRunner '_tool\dotnet\dotnet.exe') -Value '' }
        $result
    }
    function Remove-LegacyStartupTasks {
        # Called with no arguments by the migration: the names and scripts are the real defaults of this scope. The Run key is a
        # throwaway that does not exist.
        & $realRemove -RunKey 'HKCU:\Software\SubZeroDevRunnersTest-DoesNotExist' -GetTask $fakeGet -RemoveTask $fakeRemove
    }
}
function Invoke-Installer {
    param([string] $Clone, [switch] $Upgrade, [switch] $NoRunnerFiles, [switch] $Marker, [switch] $Fresh, [hashtable] $Scheduler = @{ Tasks = @{} }, [string] $InstanceId)
    $scriptsDir = Join-Path $Clone 'scripts'
    $root = $Clone
    $schedulerPlan = $Scheduler
    $trace = [Collections.Generic.List[string]]::new()
    $direct = @{ Started = [Collections.Generic.List[object]]::new() }
    $deferFiles = $Fresh -and -not $NoRunnerFiles
    $windows = Join-Path $Clone 'windows'
    if (Test-Path -LiteralPath $windows) { Remove-Item -LiteralPath $windows -Recurse -Force }
    if (-not $Fresh) { New-Item -ItemType Directory -Path (Join-Path $windows '_tool\dotnet') -Force | Out-Null }
    if (-not $NoRunnerFiles -and -not $Fresh) {
        Set-Content -LiteralPath (Join-Path $windows 'config.cmd') -Value ''
        Set-Content -LiteralPath (Join-Path $windows '_tool\dotnet\dotnet.exe') -Value ''
    }
    if ($Marker) { Set-Content -LiteralPath (Join-Path $windows 'legacy-migration.json') -Value '{"schema":1,"kind":"upgraded","completedUtc":"2026-01-01T00:00:00Z"}' }
    if ($Upgrade) { Set-Content -LiteralPath (Join-Path $windows '.runner') -Value '{"agentName":"before"}' }
    $failure = $null
    $output = @()
    $installArguments = @{}
    if ($InstanceId) { $installArguments.InstanceId = $InstanceId }
    try { $output = @(. $full @installArguments) } catch { $failure = $_.Exception.Message }
    [pscustomobject]@{
        Output = @($output | ForEach-Object { "$_" }); Failure = $failure; Trace = $trace; Started = $direct.Started
        Marker = (Test-Path -LiteralPath $LegacyMigrationFile); MarkerFile = $LegacyMigrationFile
        Pwsh = $Pwsh; Supervisor = $Supervisor; Windows = $WindowsRunner; Config = $Config
        StartTask = $LegacyWindowsTaskName; TrimTask = $LegacyLogTrimTaskName
        Runner = (Join-Path $windows '.runner')
    }
}
function Test-DirectStart([string] $Clone) {
    $instanceId = (Invoke-Settings -Clone $Clone).Config.windows.instanceId
    # An upgrade with this clone's own startup tasks present: they are removed and verified, then the install registers and starts.
    $owned = @{}
    $probe = Invoke-Installer -Clone $Clone -Upgrade -Scheduler @{ Tasks = @{} }
    Assert (-not $probe.Failure) "Probe install failed: $($probe.Failure)"
    $owned[$probe.StartTask] = $probe.Supervisor
    $owned[$probe.TrimTask] = (Join-Path $Clone 'scripts\Trim-RunnerLogs.ps1')
    $run = Invoke-Installer -Clone $Clone -Upgrade -Scheduler @{ Tasks = $owned }
    Assert (-not $run.Failure) "Upgrade install failed: $($run.Failure)"
    Assert ($run.Started.Count -eq 1) "Expected exactly one supervisor launch, got $($run.Started.Count)."
    $launch = $run.Started[0]
    Assert ($launch.FilePath -eq $run.Pwsh -and $launch.WindowStyle -eq 'Hidden') 'The supervisor is not launched as a hidden pwsh.'
    Assert ($launch.ArgumentList[-2] -eq '-File' -and $launch.ArgumentList[-1] -eq ('"' + $run.Supervisor + '"')) "Launch targets the wrong supervisor: $($launch.ArgumentList -join ' ')"
    Assert ($run.Supervisor.StartsWith($Clone, [StringComparison]::OrdinalIgnoreCase) -and $launch.WorkingDirectory -eq $run.Windows -and $run.Windows.StartsWith($Clone, [StringComparison]::OrdinalIgnoreCase)) 'Launch targets another clone.'
    Assert (@($run.Trace | Where-Object { $_ -eq 'trim' }).Count -eq 1) 'The installer did not run housekeeping once.'
    Assert ($run.Marker) 'The completed migration was not recorded.'
    Assert (($run.Output -join "`n") -match 'is online with labels') 'The install did not finish with the online report.'
    Assert (($run.Output -join "`n") -match 'Supervisor started \(pid 987700\)') "The supervisor start was not reported: $($run.Output -join ' | ')"
    $looked = @($run.Trace | Where-Object { $_ -like 'get:*' } | ForEach-Object { $_.Substring(4) } | Select-Object -Unique)
    if ($instanceId) {
        Assert ($run.StartTask -eq "Start Windows runner ($instanceId)" -and $run.TrimTask -eq "Trim logs ($instanceId)") "Legacy cleanup names another instance: $($run.StartTask) / $($run.TrimTask)"
        Assert ($looked -notcontains 'Start runners') 'A named instance looked for the combined legacy task of the unnamed install.'
    }
    else {
        Assert ($run.StartTask -eq 'Start Windows runner' -and $run.TrimTask -eq 'Trim logs' -and $looked -contains 'Start runners') 'Legacy cleanup names changed for the unnamed install.'
    }
    foreach ($name in $run.StartTask, $run.TrimTask) {
        Assert ($run.Trace -contains "remove:$name") "The owned legacy task '$name' was not removed."
    }
    Assert ($run.Trace.IndexOf("remove:$($run.StartTask)") -lt $run.Trace.IndexOf('plan') -and $run.Trace.IndexOf("remove:$($run.StartTask)") -lt $run.Trace.IndexOf('start')) 'The legacy task was removed after the install changed something.'
}
# Fix 1: a startup entry that cannot be removed or inspected stops the install before any change. Fix 2: a fresh or completed
# install never asks the scheduler, and another clone's task does not block.
function Test-InstallerMigration([string] $Clone) {
    Invoke-Settings -Clone $Clone | Out-Null
    $probe = Invoke-Installer -Clone $Clone -Scheduler @{ Tasks = @{} }
    $own = @{ $probe.StartTask = $probe.Supervisor }
    $changes = 'archive', 'github', 'local-registration', 'plan', 'register', 'confirm', 'stop', 'start', 'trim'
    foreach ($case in @(
            @{ Name = 'removal failure'; Plan = @{ Tasks = $own; RemoveError = 'Access is denied.' }; Pattern = 'Could not remove the legacy task.*Access is denied' }
            @{ Name = 'inspection failure'; Plan = @{ Tasks = $own; InspectError = 'The Task Scheduler service is not running.' }; Pattern = 'Could not look for the legacy task.*not running' })) {
        $localFile = Join-Path $Clone 'runners.local.json'
        $localBytes = [IO.File]::ReadAllBytes($localFile)
        $run = Invoke-Installer -Clone $Clone -Upgrade -NoRunnerFiles -Scheduler $case.Plan
        $registrationAfter = Get-Content -Raw -LiteralPath $run.Runner
        Assert ((Compare-Object $localBytes ([IO.File]::ReadAllBytes($localFile)) -SyncWindow 0) -eq $null) "The $($case.Name) left runners.local.json changed."
        Remove-Item -LiteralPath $localFile
        $absent = Invoke-Installer -Clone $Clone -NoRunnerFiles -Scheduler $case.Plan -InstanceId $probe.Config.windows.instanceId
        Assert ($absent.Failure -match $case.Pattern -and -not (Test-Path -LiteralPath $localFile)) "The $($case.Name) left a runners.local.json that did not exist before: $($absent.Failure)"
        [IO.File]::WriteAllBytes($localFile, $localBytes)
        Assert ($run.Failure -match $case.Pattern -and $run.Failure -match 'taskschd\.msc' -and $run.Failure -match 'no migration is recorded') "The $($case.Name) did not fail the install with the fix: $($run.Failure)"
        $touched = @($run.Trace | Where-Object { $_ -in $changes })
        Assert ($touched.Count -eq 0) "The $($case.Name) still changed things first: $($touched -join ', ')"
        Assert ($run.Started.Count -eq 0) "The $($case.Name) still started the supervisor."
        Assert (-not $run.Marker) "The $($case.Name) recorded the migration."
        Assert (-not ($run.Output -match 'online|Supervisor') ) "The $($case.Name) printed success output: $($run.Output -join ' | ')"
        Assert ($registrationAfter -match 'before') 'The failed install changed the registration files.'
    }
    # Fixed scheduler, same clone: the install completes and records it.
    $fixed = Invoke-Installer -Clone $Clone -Upgrade -Scheduler @{ Tasks = $own }
    Assert (-not $fixed.Failure -and $fixed.Marker -and $fixed.Started.Count -eq 1) "The rerun after the fix did not complete: $($fixed.Failure)"
    # Another clone's task of the same name is kept and does not block.
    $foreign = Invoke-Installer -Clone $Clone -Upgrade -Scheduler @{ Tasks = @{ $probe.StartTask = 'C:\other-clone\scripts\Run-WindowsRunner.ps1' } }
    Assert (-not $foreign.Failure -and $foreign.Marker) "A foreign same-name task blocked the install: $($foreign.Failure)"
    Assert ($foreign.Trace -notcontains "remove:$($probe.StartTask)") 'Another clone''s task was removed.'
    Assert ((Get-Content -Raw -LiteralPath $foreign.MarkerFile) -match 'belongs to another clone') 'The kept foreign task was not recorded.'
    # Fresh and already-migrated installs: a scheduler that fails on any access proves it is not asked.
    $tripwire = @{ Tasks = $own; InspectError = 'TRIPWIRE: the scheduler was asked.'; RemoveError = 'TRIPWIRE: the scheduler was asked.' }
    $fresh = Invoke-Installer -Clone $Clone -Fresh -Scheduler $tripwire
    Assert (-not $fresh.Failure -and $fresh.Marker) "A fresh install failed: $($fresh.Failure)"
    Assert (@($fresh.Trace | Where-Object { $_ -match '^(get|remove):' }).Count -eq 0) "A fresh install asked the scheduler: $(($fresh.Trace | Where-Object { $_ -match '^(get|remove):' }) -join ', ')"
    $repeat = Invoke-Installer -Clone $Clone -Upgrade -Marker -Scheduler $tripwire
    Assert (-not $repeat.Failure -and $repeat.Started.Count -eq 1) "Repeating a completed migration failed: $($repeat.Failure)"
    Assert (@($repeat.Trace | Where-Object { $_ -match '^(get|remove):' }).Count -eq 0) 'Repeating a completed migration asked the scheduler.'
    $control = Invoke-Installer -Clone $Clone -Upgrade -Scheduler $tripwire
    Assert ($control.Failure -match 'Could not look for the legacy task') "Control: an upgrade without a record should have asked the failing scheduler: $($control.Failure)"
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
    Write-Output 'PASS: named and unnamed installs migrate their own legacy entries first, then start their own supervisor directly (launch and scheduler faked; nothing registered).'
    Test-InstallerMigration $aClone
    Test-InstallerMigration $legacyClone
    Write-Output 'PASS: an unremovable or uninspectable legacy entry fails the install before any change and without success output; fresh and repeated installs never ask the scheduler; another clone''s task is kept.'
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
