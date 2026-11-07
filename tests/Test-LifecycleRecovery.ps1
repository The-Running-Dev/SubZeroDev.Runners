#Requires -Version 7.2
# Regression tests for the stop, start and recovery behavior of scripts\Lifecycle.ps1 and its entry points:
#   - a stop that fails, or whose result cannot be verified, is a failure: maintenance stays on, admission stays closed, nothing
#     destructive (re-registration) follows, and the entry points exit nonzero;
#   - the recovery record (runner id, scope, original labels) is written, atomically, before the first label is withdrawn, and is
#     removed only after the labels are confirmed back;
#   - the supervisor is started and stopped directly (no Task Scheduler, no autostart): Start launches one hidden process, a dead
#     supervisor is reported down and nothing restarts it, and the one-time cleanup of legacy tasks is scoped to this clone.
# GitHub, Docker and the Windows process table are replaced by fakes (script-scope functions, and a fake gh/docker on PATH for
# the entry-point cases). The cleanup cases use real Task Scheduler, but only a throwaway task folder and Run key of their own.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern, [string] $Message) {
    $thrown = $null
    try { & $Action | Out-Null } catch { $thrown = $_.Exception.Message }
    Assert ($null -ne $thrown) "$Message (nothing was thrown)"
    Assert ($thrown -match $Pattern) "$Message (got: $thrown)"
}

. (Join-Path $repo 'scripts\Common.ps1')
. (Join-Path $repo 'scripts\Registration.ps1')
. (Join-Path $repo 'scripts\Lifecycle.ps1')


# Nothing in this file may start, stop or remove a real process or task of this machine. Three layers:
#  1. every instance-specific name the lifecycle code uses (the mutex) is a throwaway one, and every fake pid is not a valid
#     Windows pid (not a multiple of 4), so even a call that got past the fakes would address nothing real;
#  2. Start-Process, Stop-Process, Invoke-TaskKill and the process-table queries are replaced by fakes below, and the file aborts
#     before the first case if any of them does not resolve to the fake from the scope the lifecycle functions run in. The cleanup
#     cases register their tasks in a throwaway task folder and Run key, never in the real ones;
#  3. the legacy tasks this clone would otherwise own (and the live default ones) are fingerprinted now and again at the end,
#     and the run fails if any changed.
. (Join-Path $repo 'scripts\LegacyCleanup.ps1')
$testInstance = 'lrtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$realTaskPaths = @('\SubZeroDev.Runners\', $LegacyTaskPath) | Select-Object -Unique
$realTaskNames = @($LegacyWindowsTaskName, 'Start Windows runner', $LegacyLogTrimTaskName, 'Trim logs', $LegacyLogonTaskName) | Select-Object -Unique
function Get-RealTaskFingerprint {
    foreach ($path in $realTaskPaths) {
        foreach ($name in $realTaskNames) {
            $task = ScheduledTasks\Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
            if (-not $task) { "$path${name}: absent"; continue }
            $action = @($task.Actions)[0]
            $info = ScheduledTasks\Get-ScheduledTaskInfo -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
            "$path${name}: $($task.State) | $($action.Execute) $($action.Arguments) | $($action.WorkingDirectory) | restart $($task.Settings.RestartCount) | last run $($info.LastRunTime) result $($info.LastTaskResult)"
        }
    }
}
$realTasksBefore = Get-RealTaskFingerprint
$WindowsMutexName = "Local\SubZeroDev.Runners.Windows.$testInstance"

$temp =Join-Path ([IO.Path]::GetTempPath()) ('lifecycle-recovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$Config.lifecycle.pollSeconds = 1
$Config.lifecycle.stopTimeoutSeconds = 1
$url = 'https://github.com/AbsoluteZeroDev'
$scopeName = 'orgs/AbsoluteZeroDev'

$cases = [Collections.Generic.List[object]]::new()
function Test-Case([string] $Name, [scriptblock] $Body) {
    try { & $Body | Out-Null; $cases.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null }); Write-Host "PASS  $Name" }
    catch { $cases.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message }); Write-Host "FAIL  $Name`n        $($_.Exception.Message)" }
}
function New-CaseDirectory { $directory = Join-Path $temp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $directory | Out-Null; $directory }
function Join-Sorted($Values) { (@($Values) | Sort-Object) -join ',' }

# --- fake GitHub -------------------------------------------------------------------------------------------------------
# One runner (id 7) with two custom labels. Flags make individual calls fail or misbehave.
function New-FakeGitHub([string] $StateFile) {
    @{
        StateFile = $StateFile; LocalId = 7; RemoteId = 7; Absent = $false; Busy = $false
        Defaults = @('self-hosted', 'Windows', 'X64'); Custom = @('subzerodev', 'subzerodev-windows')
        Deletes = 0; Adds = 0; AddCalls = [Collections.Generic.List[object]]::new(); StateAtDelete = $null
        GetThrows = $null; FailGetAfterDelete = $false; DeleteNoop = $false; DeleteThrowsAfter = $null; AddFails = $null; AddDropsLast = $false
    }
}
function Get-GitHubRunner($Scope, $Name) {
    if ($gh.GetThrows) { throw $gh.GetThrows }
    if ($gh.FailGetAfterDelete -and $gh.Deletes -gt 0) { throw 'HTTP 502: bad gateway' }
    if ($gh.Absent) { return $null }
    [pscustomobject]@{ Id = [int64]$gh.RemoteId; Name = $Name; Status = 'online'; Busy = $gh.Busy; Labels = @($gh.Defaults) + @($gh.Custom); CustomLabels = @($gh.Custom) }
}
function Remove-GitHubRunnerCustomLabels($Scope, $Id) {
    $gh.Deletes++
    $gh.StateAtDelete = if (Test-Path -LiteralPath $gh.StateFile) { Get-Content -Raw -LiteralPath $gh.StateFile | ConvertFrom-Json }
    if ($gh.DeleteNoop) { return }
    $gh.Custom = @()
    if ($gh.DeleteThrowsAfter) { throw $gh.DeleteThrowsAfter }
}
function Add-GitHubRunnerLabels($Scope, $Id, $Labels) {
    $gh.Adds++
    $gh.AddCalls.Add(@($Labels))
    if ($gh.AddFails) { throw $gh.AddFails }
    $take = if ($gh.AddDropsLast) { @($Labels | Select-Object -SkipLast 1) } else { @($Labels) }
    $gh.Custom = @(@($gh.Custom) + $take | Select-Object -Unique)
}
function Get-LocalRegistration($RunnerDirectory) {
    [pscustomobject]@{ agentId = $gh.LocalId; agentName = 'runner-a'; gitHubUrl = $url; workFolder = '_work' }
}
function Write-Record([string] $StateFile, [hashtable] $Extra = @{}) {
    $values = @{ phase = 'closing'; reason = 'test'; sinceUtc = [DateTime]::UtcNow.ToString('o'); scope = $scopeName; runnerId = 7; agentName = 'runner-a'; savedLabels = @('subzerodev', 'subzerodev-windows') }
    foreach ($key in $Extra.Keys) { $values[$key] = $Extra[$key] }
    Set-MaintenanceState $StateFile $values
}

# --- admission and the recovery record ----------------------------------------------------------------------------------
Test-Case 'an idle drain records the labels; ending maintenance restores them and removes the record' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    $result = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -Reason 'test' -TimeoutMinutes 1
    Assert ($result.Outcome -eq 'idle') "Unexpected outcome $($result.Outcome)."
    Assert ($gh.Deletes -eq 1 -and -not $gh.Custom) 'The custom labels were not withdrawn.'
    $record = Get-MaintenanceState $file
    Assert ($record.phase -eq 'draining' -and $record.runnerId -eq 7 -and $record.scope -eq $scopeName -and (Join-Sorted $record.savedLabels) -eq 'subzerodev,subzerodev-windows') "The record is incomplete: $($record | ConvertTo-Json -Compress)"
    Assert (Exit-RunnerMaintenance $file $dir) 'Ending maintenance reported nothing to end.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows') 'The labels were not restored.'
    Assert (-not (Test-Path -LiteralPath $file)) 'The record was kept after a confirmed restoration.'
}

Test-Case 'the record (identity, scope, labels) exists before the first label is withdrawn' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -Reason 'test' -TimeoutMinutes 1 -Force | Out-Null
    $seen = $gh.StateAtDelete
    Assert ($null -ne $seen) 'No record existed when the labels were withdrawn.'
    Assert ($seen.phase -eq 'closing' -and $seen.runnerId -eq 7 -and $seen.scope -eq $scopeName -and (Join-Sorted $seen.savedLabels) -eq 'subzerodev,subzerodev-windows') "The record at the time of the DELETE was incomplete: $($seen | ConvertTo-Json -Compress)"
}

Test-Case 'a drain timeout restores the labels and clears the record' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    $result = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $true } -Reason 'test' -TimeoutMinutes 0
    Assert ($result.Outcome -eq 'timeout' -and $result.Retained -match 'Nothing was stopped') "A running job past the deadline did not keep the runner: $($result.Outcome)"
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'The labels were not restored after the timeout.'
}

Test-Case '-Force does not wait for the job' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    $result = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $true } -Reason 'test' -TimeoutMinutes 5 -Force
    Assert ($result.Outcome -eq 'forced') '-Force waited for the job.'
    Assert ((Get-MaintenanceState $file).phase -eq 'draining') 'The forced stop left no record.'
}

Test-Case 'admission that cannot be read is refused without -Force and writes nothing' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.GetThrows = 'HTTP 401: bad credentials'
    Assert-Throws { Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 } 'Could not close admission' 'A drain went ahead although admission could not be closed.'
    Assert (-not (Test-Path -LiteralPath $file) -and $gh.Deletes -eq 0) 'Something was changed although nothing could be verified.'
    $result = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 -Force
    Assert ($result.Outcome -eq 'forced' -and $result.Admission -match '^not closed') 'A forced stop did not report that admission stayed open.'
}

Test-Case 'a DELETE that fails after the labels are gone puts them back and says so' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.DeleteThrowsAfter = 'HTTP 502: bad gateway'
    Assert-Throws { Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 } 'confirmed back' 'The failed withdrawal was not reported with a confirmed restoration.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows') 'The labels are still withdrawn.'
    Assert (-not (Test-Path -LiteralPath $file)) 'The record was kept although the labels are confirmed back.'
}

Test-Case 'a failure right after the DELETE, with GitHub then unreachable, keeps the record; ending maintenance recovers from it' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.FailGetAfterDelete = $true
    Assert-Throws { Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 } 'could not be confirmed back' 'An unconfirmed restoration was reported as done.'
    Assert (-not $gh.Custom) 'The scenario did not withdraw the labels.'
    $record = Get-MaintenanceState $file
    Assert ($null -ne $record -and $record.phase -eq 'closing' -and (Join-Sorted $record.savedLabels) -eq 'subzerodev,subzerodev-windows' -and $record.runnerId -eq 7) 'The recovery record was lost or incomplete.'
    $gh.FailGetAfterDelete = $false
    Assert (Exit-RunnerMaintenance $file $dir) 'Ending maintenance found nothing to do.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'The saved record did not restore the labels.'
}

Test-Case 'a failed restoration keeps the record, and a retry after the outage finishes it' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.DeleteThrowsAfter = 'HTTP 502'; $gh.AddFails = 'HTTP 503'
    Assert-Throws { Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 } 'could not be confirmed back' 'A failed restoration was not reported.'
    Assert ((Test-Path -LiteralPath $file) -and -not $gh.Custom) 'The record was dropped although the labels are not back.'
    $gh.AddFails = $null
    Assert (Exit-RunnerMaintenance $file $dir) 'The retry found nothing to do.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'The retry did not restore the labels.'
}

Test-Case 'a crash between the record and the DELETE leaves a record that restores everything' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    Write-Record $file
    $gh.Custom = @()
    Assert (Exit-RunnerMaintenance $file $dir) 'Nothing was ended.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'The record from the interrupted drain did not restore the labels.'
}

Test-Case 'partial restoration keeps the record; the retry adds only what is missing; a third call does nothing' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    Write-Record $file -Extra @{ phase = 'draining' }
    $gh.Custom = @(); $gh.AddDropsLast = $true
    Assert-Throws { Exit-RunnerMaintenance $file $dir } 'still missing' 'A partial restoration was reported as complete.'
    Assert (Test-Path -LiteralPath $file) 'The record was removed although a label is missing.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev') 'The scenario did not leave exactly one label missing.'
    $gh.AddDropsLast = $false
    Assert (Exit-RunnerMaintenance $file $dir) 'The retry found nothing to do.'
    Assert ((@($gh.AddCalls[-1]) -join ',') -eq 'subzerodev-windows') "The retry re-added more than the missing label: $(@($gh.AddCalls[-1]) -join ',')"
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'The retry did not complete the restoration.'
    $before = $gh.Adds
    Assert (-not (Exit-RunnerMaintenance $file $dir)) 'A third call claimed to end maintenance again.'
    Assert ($gh.Adds -eq $before) 'A repeated end of maintenance called GitHub again.'
}

Test-Case 'a record for a different runner id is not restored onto this one and is kept' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    Write-Record $file -Extra @{ runnerId = 99 }
    $gh.Custom = @()
    Assert-Throws { Exit-RunnerMaintenance $file $dir } 'runner 99' 'A record of another runner was applied.'
    Assert ($gh.Adds -eq 0 -and (Test-Path -LiteralPath $file)) 'Labels were added, or the record was removed, for the wrong runner.'
}

Test-Case 'a GitHub runner with another id than the record is not touched and the record is kept' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.RemoteId = 8
    Write-Record $file
    $gh.Custom = @()
    Assert-Throws { Exit-RunnerMaintenance $file $dir } 'not 7' 'A different GitHub runner received the labels.'
    Assert ($gh.Adds -eq 0 -and (Test-Path -LiteralPath $file)) 'Labels were added, or the record was removed, for the wrong runner.'
}

Test-Case 'a runner that GitHub no longer has needs no restoration and the record is cleared' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.Absent = $true
    Write-Record $file
    Assert (Exit-RunnerMaintenance $file $dir) 'Nothing was ended.'
    Assert ($gh.Adds -eq 0 -and -not (Test-Path -LiteralPath $file)) 'The record of a deleted runner was kept, or labels were added somewhere.'
}

Test-Case 'a DELETE that changed nothing is detected by reading the runner back' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file; $gh.DeleteNoop = $true
    Assert-Throws { Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 } 'still on the runner|confirmed back' 'A withdrawal that changed nothing was accepted as admission closed.'
    Assert ($gh.Adds -eq 0) 'Labels were added although none were missing.'
}

Test-Case 'a repeated drain keeps the first record and withdraws nothing twice' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 -Force | Out-Null
    Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 -Force | Out-Null
    Assert ($gh.Deletes -eq 1) 'The labels were withdrawn twice.'
    Assert ((Join-Sorted (Get-MaintenanceState $file).savedLabels) -eq 'subzerodev,subzerodev-windows') 'The second drain overwrote the saved labels with the empty set.'
    Exit-RunnerMaintenance $file $dir | Out-Null
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows') 'The original labels were not restored after a repeated drain.'
}

# --- the record on disk --------------------------------------------------------------------------------------------------
Test-Case 'a stale partial temp file does not corrupt the next write' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'
    Set-Content -LiteralPath "$file.tmp" -Value '{ "phase": "clos'
    Set-MaintenanceState $file @{ phase = 'closing'; runnerId = 7 }
    $record = Get-MaintenanceState $file
    Assert ($record.phase -eq 'closing' -and $record.runnerId -eq 7) 'The record is not what was written.'
    Assert (-not (Test-Path -LiteralPath "$file.tmp")) 'The temp file was left behind.'
}

Test-Case 'a write that cannot replace the record leaves the previous record intact' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'
    Set-MaintenanceState $file @{ phase = 'draining'; runnerId = 7 }
    $handle = [IO.File]::Open($file, 'Open', 'Read', 'Read')
    try { Assert-Throws { Set-MaintenanceState $file @{ phase = 'stop-failed' } } '.' 'A write over a record that is held open was reported as done.' }
    finally { $handle.Dispose() }
    $record = Get-MaintenanceState $file
    Assert ($record.phase -eq 'draining' -and $record.runnerId -eq 7) "The previous record was damaged: $($record | ConvertTo-Json -Compress)"
}

Test-Case 'merging keeps unrelated keys, and a null value removes one' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'
    Set-MaintenanceState $file @{ phase = 'stop-failed'; failure = 'x'; runnerId = 7 }
    Set-MaintenanceState $file @{ phase = 'draining'; failure = $null }
    $record = Get-MaintenanceState $file
    Assert ($record.phase -eq 'draining' -and $record.runnerId -eq 7 -and -not $record.PSObject.Properties['failure']) "Unexpected merge result: $($record | ConvertTo-Json -Compress)"
}

Test-Case 'an unreadable record is kept as evidence when a new one is written, and ending maintenance refuses it' {
    $dir = New-CaseDirectory; $file = Join-Path $dir 'maintenance.json'; $gh = New-FakeGitHub $file
    Set-Content -LiteralPath $file -Value '{ not json'
    Assert-Throws { Exit-RunnerMaintenance $file $dir } 'cannot be read' 'An unreadable record was treated as empty.'
    Assert ((Get-Content -Raw -LiteralPath $file) -match 'not json' -and $gh.Adds -eq 0) 'The unreadable record was removed or acted on.'
    Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy { $false } -TimeoutMinutes 1 -Force | Out-Null
    Assert (@(Get-ChildItem -LiteralPath $dir -Filter 'maintenance.json.unreadable-*').Count -eq 1) 'The unreadable record was not preserved beside the new one.'
    Assert ((Get-MaintenanceState $file).phase -eq 'draining') 'The new record is not valid.'
    $empty = Join-Path $dir 'empty.json'
    New-Item -ItemType File -Path $empty | Out-Null
    Assert-Throws { Exit-RunnerMaintenance $empty $dir } 'cannot be read' 'An empty record (an interrupted write by an older version) was treated as no maintenance.'
}

# --- Linux stop ---------------------------------------------------------------------------------------------------------
function Test-LinuxRunnerBusy { $false }
$sidecarName = $LinuxContainers[0]
$runnerName = $LinuxContainers[-1]
function New-FakeDocker {
    @{
        State = @{ $sidecarName = 'running'; $runnerName = 'running' }
        Calls = [Collections.Generic.List[string]]::new()
        StopFails = @(); StopLies = @(); StopNonzero = @(); InspectUnknown = @(); InspectNoExit = @(); RmFails = @()
    }
}
function Invoke-Docker([string[]] $Arguments) {
    $dk.Calls.Add($Arguments -join ' ')
    $name = $Arguments[-1]
    switch ($Arguments[0]) {
        'container' {
            if ($dk.InspectNoExit -contains $name) { return [pscustomobject]@{ ExitCode = $null; Output = 'docker.exe could not be run' } }
            if ($dk.InspectUnknown -contains $name) { return [pscustomobject]@{ ExitCode = 1; Output = 'error during connect: Cannot connect to the Docker daemon' } }
            switch ($dk.State[$name]) {
                'running' { return [pscustomobject]@{ ExitCode = 0; Output = 'true' } }
                'stopped' { return [pscustomobject]@{ ExitCode = 0; Output = 'false' } }
                default { return [pscustomobject]@{ ExitCode = 1; Output = "Error response from daemon: No such object: $name" } }
            }
        }
        'stop' {
            if ($dk.StopFails -contains $name) { return [pscustomobject]@{ ExitCode = 1; Output = "Error response from daemon: cannot stop container: ${name}: permission denied" } }
            if ($dk.StopLies -contains $name) { return [pscustomobject]@{ ExitCode = 0; Output = $name } }
            $dk.State[$name] = 'stopped'
            return [pscustomobject]@{ ExitCode = $(if ($dk.StopNonzero -contains $name) { 1 } else { 0 }); Output = $name }
        }
        'rm' {
            if ($dk.RmFails -contains $name) { return [pscustomobject]@{ ExitCode = 1; Output = 'Error response from daemon: removal in progress' } }
            $dk.State[$name] = 'absent'
            return [pscustomobject]@{ ExitCode = 0; Output = $name }
        }
    }
    [pscustomobject]@{ ExitCode = 1; Output = "unexpected docker call: $($Arguments -join ' ')" }
}
function New-LinuxFixture {
    $directory = New-CaseDirectory
    Set-Content -LiteralPath (Join-Path $directory '.runner') -Value '{ "agentId": 7, "agentName": "runner-a", "gitHubUrl": "https://github.com/AbsoluteZeroDev" }'
    $directory
}
function Get-StopCalls { @($dk.Calls | Where-Object { $_ -match '^stop ' }) }

Test-Case 'Linux: a successful stop stops the runner, then the sidecar, restores the labels and clears the record' {
    $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker
    $result = Stop-LinuxRunners -Force
    Assert ($result.Outcome -in 'forced', 'idle') "A successful stop was reported as $($result.Outcome)."
    $stops = Get-StopCalls
    Assert ($stops.Count -eq 2 -and $stops[0] -match [regex]::Escape($runnerName) + '$' -and $stops[1] -match [regex]::Escape($sidecarName) + '$') "The stop order is wrong: $($stops -join ' | ')"
    Assert ($dk.State[$runnerName] -eq 'stopped' -and $dk.State[$sidecarName] -eq 'stopped') 'A container is still running.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'The labels were not restored, or the record was kept, after a successful stop.'
}

Test-Case 'Linux: a runner container that will not stop is a failed stop; maintenance stays and nothing else is touched' {
    $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker; $dk.StopFails = @($runnerName)
    $result = Stop-LinuxRunners -Force
    Assert ($result.Outcome -eq 'failed') "A container that would not stop was reported as $($result.Outcome)."
    Assert (@($result.Failures) -join ' ' -match 'still running') "The failure does not say what happened: $(@($result.Failures) -join ' ')"
    $record = Get-MaintenanceState $file
    Assert ($null -ne $record -and $record.phase -eq 'stop-failed' -and $record.failure -match [regex]::Escape($runnerName) -and (Join-Sorted $record.savedLabels) -eq 'subzerodev,subzerodev-windows') 'Maintenance or the recovery information was not kept.'
    Assert ($gh.Adds -eq 0 -and -not $gh.Custom) 'Admission was reopened for a runner that did not stop.'
    Assert (($result.Containers | Where-Object Name -eq $sidecarName).Result -eq 'skipped' -and $dk.State[$sidecarName] -eq 'running') 'The sidecar was stopped although the runner it serves is still running.'
}

Test-Case 'Linux: a sidecar that will not stop is a failed stop; maintenance stays' {
    $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker; $dk.StopFails = @($sidecarName)
    $result = Stop-LinuxRunners -Force
    Assert ($result.Outcome -eq 'failed' -and (@($result.Failures) -join ' ') -match [regex]::Escape($sidecarName)) "Unexpected result: $($result.Outcome) $(@($result.Failures) -join ' ')"
    Assert ((Get-MaintenanceState $file).phase -eq 'stop-failed' -and $gh.Adds -eq 0) 'Maintenance was not kept, or admission was reopened.'
}

Test-Case 'Linux: docker stop that exits 0 but leaves the container running is a failed stop' {
    $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker; $dk.StopLies = @($runnerName)
    $result = Stop-LinuxRunners -Force
    Assert ($result.Outcome -eq 'failed' -and $gh.Adds -eq 0 -and (Test-Path -LiteralPath $file)) "Unexpected result: $($result.Outcome)."
}

Test-Case 'Linux: a container state that cannot be read is unverified, not stopped' {
    foreach ($mode in 'InspectUnknown', 'InspectNoExit') {
        $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker; $dk[$mode] = @($runnerName)
        $result = Stop-LinuxRunners -Force
        Assert ($result.Outcome -eq 'failed' -and (@($result.Failures) -join ' ') -match 'could not be verified') "$mode : unexpected result $($result.Outcome) $(@($result.Failures) -join ' ')"
        Assert ($gh.Adds -eq 0 -and (Get-MaintenanceState $file).phase -eq 'stop-failed') "$mode : admission was reopened or maintenance dropped."
    }
}

Test-Case 'Linux: containers that are already stopped or absent are not an error and are not stopped again' {
    $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker
    $dk.State[$runnerName] = 'stopped'; $dk.State[$sidecarName] = 'absent'
    $result = Stop-LinuxRunners -Force
    Assert ($result.Outcome -in 'forced', 'idle') "Unexpected outcome $($result.Outcome): $(@($result.Failures) -join ' ')"
    Assert ((Get-StopCalls).Count -eq 0) "docker stop was called for containers that were not running: $((Get-StopCalls) -join ' | ')"
    Assert (($result.Containers | Where-Object Name -eq $runnerName).Result -eq 'already-stopped' -and ($result.Containers | Where-Object Name -eq $sidecarName).Result -eq 'absent') 'The per-container results do not distinguish already-stopped from absent.'
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows' -and -not (Test-Path -LiteralPath $file)) 'A stop of stopped containers did not end maintenance.'
}

Test-Case 'Linux: docker stop exiting nonzero is fine when the container is verifiably stopped' {
    $LinuxRunner = New-LinuxFixture; $gh = New-FakeGitHub (Join-Path $LinuxRunner 'maintenance.json'); $dk = New-FakeDocker; $dk.StopNonzero = @($runnerName)
    $result = Stop-LinuxRunners -Force
    Assert ($result.Outcome -in 'forced', 'idle') "A stop that was verified was reported as $($result.Outcome)."
}

Test-Case 'Linux: removing a container is verified too' {
    $dk = New-FakeDocker; $dk.StopFails = @($runnerName)
    Assert ((Remove-LinuxContainer $runnerName).Result -eq 'failed') 'A container that would not stop was reported as removed.'
    Assert (-not ($dk.Calls | Where-Object { $_ -match '^rm ' })) 'docker rm was called on a container that is still running.'
    $dk = New-FakeDocker; $dk.RmFails = @($runnerName)
    $removed = Remove-LinuxContainer $runnerName
    Assert ($removed.Result -eq 'failed' -and $removed.Detail -match 'still stopped') "A container that is still there was reported as removed: $($removed.Result) $($removed.Detail)"
    $dk = New-FakeDocker; $dk.State[$runnerName] = 'absent'
    Assert ((Remove-LinuxContainer $runnerName).Result -eq 'absent') 'An absent container was not reported as absent.'
    $dk = New-FakeDocker
    Assert ((Remove-LinuxContainer $runnerName).Result -eq 'removed') 'A removable container was not removed.'
}

Test-Case 'a failed stop stops re-registration before it changes anything' {
    $LinuxRunner = New-LinuxFixture; $file = Join-Path $LinuxRunner 'maintenance.json'; $gh = New-FakeGitHub $file; $dk = New-FakeDocker; $dk.StopFails = @($runnerName)
    $configured = @{ Count = 0 }
    $plan = [pscustomobject]@{ Action = 'reconfigure'; RemoveRemote = $true; RemoveScope = $scopeName; WorkFolder = '/tmp/x'; AllLabels = @('subzerodev-linux'); Reasons = @('work folder changed'); Refusals = @(); LinkedId = 7 }
    $beforeChange = { $stopped = Stop-LinuxRunners; if ($stopped.Outcome -eq 'timeout') { throw $stopped.Retained }; if ($stopped.Outcome -eq 'failed') { throw "The runner did not stop, so its registration was not changed. $(@($stopped.Failures) -join ' ')" } }
    Assert-Throws { Invoke-RunnerRegistration -Plan $plan -RunnerDirectory $LinuxRunner -Name 'runner-a' -GitHubUrl $url -BeforeChange $beforeChange -Configure { $configured.Count++ } } 'did not stop, so its registration was not changed' 'Re-registration went ahead after a failed stop.'
    Assert ($configured.Count -eq 0) 'The runner configuration was run after a failed stop.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $LinuxRunner '_recovery')) -and (Test-Path -LiteralPath (Join-Path $LinuxRunner '.runner'))) 'The registration files were saved away or removed after a failed stop.'
    Assert ($gh.Adds -eq 0 -and (Get-MaintenanceState $file).phase -eq 'stop-failed') 'Admission was restored, or maintenance dropped, after a failed stop.'
}

# --- fake process start -------------------------------------------------------------------------------------------------
# Start-Process is replaced at script scope, so no case here can launch a real supervisor. Order is the sequence of start, kill
# and stop calls across the fakes; Started records every launch.
function New-FakeSpawn { @{ Order = @(); Started = @() } }
$spawn = New-FakeSpawn
function Start-Process {
    [CmdletBinding()] param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch] $PassThru)
    $spawn.Order += 'start-process'
    $spawn.Started += , [pscustomobject]@{ FilePath = $FilePath; ArgumentList = @($ArgumentList); WorkingDirectory = $WorkingDirectory; WindowStyle = "$WindowStyle"; MaintenanceAtStart = (Test-Path -LiteralPath $MaintenanceFile) }
    if ($PassThru) { [pscustomobject]@{ Id = 987700 } }
}
# --- Windows stop -------------------------------------------------------------------------------------------------------
# Fake pids are not valid Windows pids (not multiples of 4), so nothing real is ever addressed.
function New-FakeWindows {
    @{
        Supervisor = [pscustomobject]@{ ProcessId = 987653 }; Listeners = @([pscustomobject]@{ ProcessId = 987654 }); Workers = @([pscustomobject]@{ ProcessId = 987655 })
        TaskKillFails = $false; TaskKillGone = $false; StopProcessFails = $false; QueryThrows = $null; Kills = @(); Stops = @()
    }
}
function Get-SupervisorProcess { if ($win.QueryThrows) { throw $win.QueryThrows }; $win.Supervisor }
function Get-WindowsRunnerListeners { if ($win.QueryThrows) { throw $win.QueryThrows }; @($win.Listeners | Where-Object { $_ }) }
function Get-WindowsRunnerWorkers { if ($win.QueryThrows) { throw $win.QueryThrows }; @($win.Workers | Where-Object { $_ }) }
function Test-WindowsRunnerBusy { $false }
function Invoke-TaskKill([int] $ProcessId) {
    $win.Kills += $ProcessId
    $spawn.Order += 'taskkill'
    if ($win.TaskKillFails) { return [pscustomobject]@{ ExitCode = 1; Output = 'ERROR: The process could not be terminated. Access is denied.' } }
    $win.Supervisor = $null; $win.Listeners = @(); $win.Workers = @()
    [pscustomobject]@{ ExitCode = $(if ($win.TaskKillGone) { 128 } else { 0 }); Output = '' }
}
function Stop-Process {
    [CmdletBinding()] param([int] $Id, [switch] $Force)
    $win.Stops += $Id; $spawn.Order += 'stop-process'
    if ($win.StopProcessFails) { throw 'Access is denied' }
    $win.Listeners = @($win.Listeners | Where-Object { $_.ProcessId -ne $Id }); $win.Workers = @($win.Workers | Where-Object { $_.ProcessId -ne $Id })
}
function New-WindowsFixture { $directory = New-CaseDirectory; Set-Content -LiteralPath (Join-Path $directory 'supervisor.pid') -Value '987653'; $directory }
# Dot-source it (. Use-WindowsFixture): points every path variable at a fresh directory and nothing running, in the caller's scope.
function Use-WindowsFixture {
    $dir = New-WindowsFixture; $WindowsRunner = $dir; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'
    $SupervisorStatusFile = Join-Path $dir 'supervisor.json'; $MaintenanceFile = Join-Path $dir 'maintenance.json'
    $win = New-FakeWindows; $win.Supervisor = $null; $win.Listeners = @(); $win.Workers = @(); $spawn = New-FakeSpawn
}
# Abort before any case runs unless every one of them is the fake, as seen from inside a lifecycle function.
foreach ($name in 'Start-Process', 'Stop-Process', 'Invoke-TaskKill', 'Get-SupervisorProcess', 'Get-WindowsRunnerListeners', 'Get-WindowsRunnerWorkers', 'Test-WindowsRunnerBusy') {
    # The lifecycle functions were dot-sourced into this scope, so they resolve a name exactly as this line does.
    $resolved = Get-Command $name
    if ($resolved.CommandType -ne 'Function' -or $resolved.ScriptBlock.File -ne $PSCommandPath) {
        throw "ABORTED: $name resolves to $($resolved.CommandType) $($resolved.Source), not this file's fake; running the cases could start or stop a real process."
    }
}
Test-Case 'Windows: supervisor, listener and worker are gone after the stop, and the pid file is removed' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $win = New-FakeWindows
    $result = Stop-WindowsRunnerProcesses -WaitSeconds 1
    Assert ($result.Stopped -and -not $result.Failures) "A clean stop was not reported as stopped: $(@($result.Failures) -join ' ')"
    Assert ($win.Kills -contains 987653 -and -not (Test-Path -LiteralPath $SupervisorPidFile)) 'The supervisor was not killed or its pid file remains.'
}

Test-Case 'Windows: a taskkill that fails while the supervisor lives on is a failed stop and keeps the pid file' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $win = New-FakeWindows; $win.TaskKillFails = $true; $win.Listeners = @(); $win.Workers = @()
    $result = Stop-WindowsRunnerProcesses -WaitSeconds 1
    Assert (-not $result.Stopped) 'A supervisor that is still running was reported as stopped.'
    Assert ((@($result.Failures) -join ' ') -match 'taskkill of the supervisor \(pid 987653\) exited 1' -and (@($result.Failures) -join ' ') -match 'Still running after the stop: pid 987653') "The failure text is incomplete: $(@($result.Failures) -join ' ')"
    Assert (Test-Path -LiteralPath $SupervisorPidFile) 'The pid file of a supervisor that is still running was removed.'
}

Test-Case 'Windows: a taskkill that exits nonzero is fine when nothing is left' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $win = New-FakeWindows; $win.TaskKillGone = $true
    Assert (Stop-WindowsRunnerProcesses -WaitSeconds 1).Stopped 'A verified stop was reported as failed because of the exit code.'
}

Test-Case 'Windows: a listener that cannot be stopped is a failed stop' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $win = New-FakeWindows; $win.Supervisor = $null; $win.Workers = @(); $win.StopProcessFails = $true
    $result = Stop-WindowsRunnerProcesses -WaitSeconds 1
    Assert (-not $result.Stopped -and (@($result.Failures) -join ' ') -match 'Stop-Process of pid 987654 failed') "Unexpected result: $($result.Stopped) $(@($result.Failures) -join ' ')"
}

Test-Case 'Windows: a process table that cannot be read is an unverified stop' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $win = New-FakeWindows; $win.QueryThrows = 'CIM is unavailable'
    $result = Stop-WindowsRunnerProcesses -WaitSeconds 1
    Assert (-not $result.Stopped -and (@($result.Failures) -join ' ') -match 'Could not verify') "Unexpected result: $($result.Stopped) $(@($result.Failures) -join ' ')"
    Assert (Test-Path -LiteralPath $SupervisorPidFile) 'The pid file was removed although nothing was verified.'
}

Test-Case 'Windows: nothing running is a successful stop' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $win = New-FakeWindows; $win.Supervisor = $null; $win.Listeners = @(); $win.Workers = @()
    Assert (Stop-WindowsRunnerProcesses -WaitSeconds 1).Stopped 'Nothing running was reported as a failed stop.'
}

Test-Case 'Windows: a failed stop keeps maintenance, keeps admission closed and does not report success' {
    $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $WindowsRunner = $dir; $MaintenanceFile = Join-Path $dir 'maintenance.json'
    $gh = New-FakeGitHub $MaintenanceFile; $win = New-FakeWindows; $win.TaskKillFails = $true
    $result = Stop-WindowsRunner -Force -Reason 'stop'
    Assert ($result.Outcome -eq 'failed' -and (@($result.Failures) -join ' ') -match 'Still running') "Unexpected outcome $($result.Outcome)."
    $record = Get-MaintenanceState $MaintenanceFile
    Assert ($null -ne $record -and $record.phase -eq 'stop-failed' -and $record.failure -match 'Still running' -and (Join-Sorted $record.savedLabels) -eq 'subzerodev,subzerodev-windows') 'Maintenance or the recovery information was not kept.'
    Assert ($gh.Adds -eq 0 -and -not $gh.Custom) 'Admission was reopened although the runner is still running.'
}

Test-Case 'Windows: a verified stop restores admission; -Hold also keeps the startup hold' {
    foreach ($hold in $false, $true) {
        $dir = New-WindowsFixture; $SupervisorPidFile = Join-Path $dir 'supervisor.pid'; $WindowsRunner = $dir; $MaintenanceFile = Join-Path $dir 'maintenance.json'
        $gh = New-FakeGitHub $MaintenanceFile; $win = New-FakeWindows
        $result = Stop-WindowsRunner -Force -Hold:$hold -Reason 'stop'
        Assert ($result.Outcome -eq 'forced') "Hold=$hold : unexpected outcome $($result.Outcome): $(@($result.Failures) -join ' ')"
        Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows') "Hold=$hold : the labels were not restored."
        if ($hold) { Assert ((Get-MaintenanceState $MaintenanceFile).phase -eq 'held') 'The hold was not kept.' }
        else { Assert (-not (Test-Path -LiteralPath $MaintenanceFile)) 'The record was kept after a confirmed restoration.' }
    }
}

# --- start: the supervisor is launched directly ---------------------------------------------------------------------------
Test-Case 'Start: no supervisor running launches exactly one hidden supervisor process and reports its pid' {
    . Use-WindowsFixture
    $how = Start-WindowsRunner
    Assert ($how -eq 'started (pid 987700)') "Unexpected result: $how"
    Assert (@($spawn.Started).Count -eq 1 -and ($spawn.Order -join ',') -eq 'start-process') "Unexpected calls: $($spawn.Order -join ',')"
    $launch = $spawn.Started[0]
    Assert ($launch.FilePath -eq $Pwsh -and $launch.WorkingDirectory -eq $WindowsRunner -and $launch.WindowStyle -eq 'Hidden') "Launch: $($launch | ConvertTo-Json -Compress)"
    $arguments = @($launch.ArgumentList)
    Assert ($arguments.Count -ge 2 -and $arguments[-2] -eq '-File' -and $arguments[-1] -eq ('"' + $Supervisor + '"')) "The supervisor script is not the -File target: $($arguments -join ' ')"
    Assert ($arguments -contains '-NoProfile' -and $arguments -contains '-NonInteractive') "The supervisor would read a profile or prompt: $($arguments -join ' ')"
}

Test-Case 'Start: a supervisor that is already running is left alone' {
    . Use-WindowsFixture
    $win.Supervisor = [pscustomobject]@{ ProcessId = 987653 }
    $how = Start-WindowsRunner
    Assert ($how -eq 'already running (pid 987653)') "Unexpected result: $how"
    Assert (-not $spawn.Order -and -not $win.Kills -and -not $win.Stops) "Something was started or stopped: $($spawn.Order -join ',')"
}

Test-Case 'Start: maintenance has ended, and the labels are back, by the time the supervisor is launched' {
    . Use-WindowsFixture
    $gh = New-FakeGitHub $MaintenanceFile
    $win.Supervisor = [pscustomobject]@{ ProcessId = 987653 }; $win.Listeners = @([pscustomobject]@{ ProcessId = 987654 })
    $held = Stop-WindowsRunner -Force -Hold -Reason 'maintenance'
    Assert ($held.Outcome -eq 'forced' -and (Get-MaintenanceState $MaintenanceFile).phase -eq 'held') "The hold was not set: $($held.Outcome) $(@($held.Failures) -join ' ')"
    Assert ((Join-Sorted $gh.Custom) -eq 'subzerodev,subzerodev-windows') 'The labels were not restored by the stop.'
    $spawn = New-FakeSpawn
    $how = Start-WindowsRunner
    Assert ($how -eq 'started (pid 987700)') "Unexpected result: $how"
    Assert (@($spawn.Started).Count -eq 1 -and -not $spawn.Started[0].MaintenanceAtStart) 'The supervisor was launched while maintenance was still on, so it would idle.'
    Assert (-not (Test-Path -LiteralPath $MaintenanceFile)) 'The hold was not ended by Start.'
}

Test-Case 'No script outside the legacy cleanup registers, starts or inspects scheduled tasks, and the config has no startup or trim-time setting' {
    $allowed = 'LegacyCleanup.ps1', 'WindowsRunnerSetup.ps1'
    $hits = Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -Filter '*.ps1' | Where-Object { $_.Name -notin $allowed } |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'ScheduledTask|schtasks|CurrentVersion.Run' } | ForEach-Object { $_.Name }
    Assert (-not $hits) "Scheduler references remain in: $($hits -join ', ')"
    Assert (-not (Test-Path -LiteralPath (Join-Path $repo 'scripts\Set-WindowsStartup.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts\Register-LogTrimTask.ps1'))) 'A scheduler registration script is still present.'
    $shared = Get-Content -Raw -LiteralPath (Join-Path $repo 'runners.json') | ConvertFrom-Json
    Assert ($null -eq $shared.windows.startup -and $null -eq $shared.logs.trimAt) 'runners.json still carries windows.startup or logs.trimAt.'
}
Test-Case 'Stop: a verified stop marks supervisor.json stopped (so the next start is no recovery); a failed stop leaves it alone' {
    . Use-WindowsFixture
    $win.Supervisor = [pscustomobject]@{ ProcessId = 987653 }
    Set-SupervisorStatusValues @{ state = 'running'; pid = 987653; recoveries = 1 }
    Assert (Stop-WindowsRunnerProcesses -WaitSeconds 1).Stopped 'The stop failed.'
    $recorded = Get-SupervisorStatus
    Assert ($recorded.state -eq 'stopped' -and $null -eq $recorded.pid -and $recorded.recoveries -eq 1) "Status after the stop: $($recorded | ConvertTo-Json -Compress)"
    . Use-WindowsFixture
    $win.Supervisor = [pscustomobject]@{ ProcessId = 987653 }; $win.TaskKillFails = $true
    Set-SupervisorStatusValues @{ state = 'running'; pid = 987653 }
    Assert (-not (Stop-WindowsRunnerProcesses -WaitSeconds 1).Stopped) 'A failed stop was reported as stopped.'
    Assert ((Get-SupervisorStatus).state -eq 'running') 'A failed stop marked the supervisor stopped.'
}

# --- supervisor recovery bookkeeping -------------------------------------------------------------------------------------
Test-Case 'Recovery: nothing before it, or a predecessor that stopped on purpose, is no recovery' {
    foreach ($previous in $null, [pscustomobject]@{ state = 'stopped'; pid = $null }) {
        $recovery = Get-SupervisorRecovery $previous
        Assert ($recovery.recoveries -eq 0 -and $recovery.consecutiveRecoveries -eq 0 -and -not $recovery.repeatedDeaths -and -not $recovery.lastRecoveryNote) "Unexpected recovery: $($recovery | ConvertTo-Json -Compress)"
    }
}

Test-Case 'Recovery: a predecessor that did not stop counts, once more each time, with its pid and state in the note' {
    $recovery = Get-SupervisorRecovery ([pscustomobject]@{ state = 'running'; pid = 4242; recoveries = 2; consecutiveRecoveries = 1 })
    Assert ($recovery.recoveries -eq 3 -and $recovery.consecutiveRecoveries -eq 2) "Counts: $($recovery.recoveries) / $($recovery.consecutiveRecoveries)"
    Assert ($recovery.lastRecoveryNote -match 'pid 4242' -and $recovery.lastRecoveryNote -match 'last state running' -and $recovery.lastRecoveryNote -match 'ended without stopping' -and $recovery.lastRecoveryUtc) "Note: $($recovery.lastRecoveryNote)"
    Assert (-not $recovery.repeatedDeaths) 'A supervisor found dead twice was reported as repeatedly dying.'
}

Test-Case 'Recovery: a supervisor found dead 3 times in a row is reported as repeatedly dying, and no automatic restart is promised' {
    Assert ($SupervisorRepeatedDeaths -eq 3) "The threshold is $SupervisorRepeatedDeaths."
    $recovery = Get-SupervisorRecovery ([pscustomobject]@{ state = 'backoff'; pid = 1; recoveries = 9; consecutiveRecoveries = 2 })
    Assert ($recovery.consecutiveRecoveries -eq 3 -and $recovery.repeatedDeaths -match 'found dead 3 times in a row' -and $recovery.repeatedDeaths -match 'Nothing restarts it automatically' -and $recovery.repeatedDeaths -match 'Manage-WindowsRunner.ps1 -Action Start') "Repeated deaths: $($recovery.repeatedDeaths)"
    Assert ($recovery.repeatedDeaths -notmatch 'retr|Task Scheduler') "The text talks about retries or Task Scheduler: $($recovery.repeatedDeaths)"
    $recovery = Get-SupervisorRecovery ([pscustomobject]@{ state = 'stopped'; repeatedDeaths = 'KEPT' })
    Assert ($recovery.repeatedDeaths -eq 'KEPT') 'A stop on purpose dropped the recorded repeated deaths (only a long run clears them).'
}

Test-Case 'Recovery report: down is not running without a clean stop; the summary says nothing restarts it and what to do' {
    $report = Get-SupervisorRecoveryReport $false ([pscustomobject]@{ state = 'running'; recoveries = 2; consecutiveRecoveries = 2; lastRecoveryUtc = 'x' })
    Assert ($report.Down -and $report.Recoveries -eq 2 -and $report.ConsecutiveRecoveries -eq 2) "Report: $($report | ConvertTo-Json -Compress -Depth 3)"
    $text = @($report.Summary) -join ' '
    Assert ($text -match 'not running and did not stop on purpose' -and $text -match 'Nothing restarts it automatically' -and $text -match 'Manage-WindowsRunner.ps1 -Action Start') "The summary does not say the supervisor is down, that nothing restarts it, and what to do: $text"
    Assert (-not (Get-SupervisorRecoveryReport $true ([pscustomobject]@{ state = 'running' })).Down) 'A running supervisor was reported down.'
    Assert (-not (Get-SupervisorRecoveryReport $false ([pscustomobject]@{ state = 'stopped' })).Down) 'A supervisor stopped on purpose was reported down.'
    $report = Get-SupervisorRecoveryReport $false $null
    Assert (-not $report.Down -and -not @($report.Summary)) "A supervisor that never ran was reported down: $($report | ConvertTo-Json -Compress -Depth 3)"
    $report = Get-SupervisorRecoveryReport $true ([pscustomobject]@{ state = 'running'; repeatedDeaths = 'REPEATED' })
    Assert ((@($report.Summary) -join ' ') -match 'REPEATED') 'The recorded repeated deaths are missing from the summary.'
    Assert (-not ($report.PSObject.Properties.Name | Where-Object { $_ -match 'Task|Restarts|Exhaust' })) "The report still carries scheduler properties: $($report.PSObject.Properties.Name -join ',')"
}

Test-Case 'Recovery report: Get-WindowsRunnerState carries it, with no task in it, and a dead supervisor is not healthy' {
    . Use-WindowsFixture
    Set-SupervisorStatusValues @{ state = 'running'; pid = 987653; recoveries = 1; consecutiveRecoveries = 1 }
    $state = Get-WindowsRunnerState
    Assert ($state.SupervisorRecovery.Down -and $state.SupervisorRecovery.Recoveries -eq 1 -and -not $state.Healthy) "State: $($state.SupervisorRecovery | ConvertTo-Json -Compress -Depth 3)"
    Assert (-not ($state.PSObject.Properties.Name | Where-Object { $_ -match 'Task|Startup' })) "The state still carries a task: $($state.PSObject.Properties.Name -join ',')"
}
# --- entry points (child processes, fake gh and docker first on PATH) -----------------------------------------------------
$pwshPath = (Get-Process -Id $PID).Path
function New-EntryPointFixture([string] $DockerStopExit) {
    $clone = New-CaseDirectory
    Copy-Item (Join-Path $repo 'runners.json') $clone
    Copy-Item (Join-Path $repo 'scripts') (Join-Path $clone 'scripts') -Recurse
    $shim = Join-Path $clone 'shim'; $ghState = Join-Path $clone 'gh'
    New-Item -ItemType Directory -Path $shim, $ghState | Out-Null
    Set-Content -LiteralPath (Join-Path $shim 'docker.cmd') -Value @(
        '@echo off'
        'if "%1"=="container" ( echo true& exit /b 0 )'
        'if "%1"=="stop" ( echo Error response from daemon: cannot stop container 1>&2& exit /b 1 )'
        'exit /b 1')
    Set-Content -LiteralPath (Join-Path $shim 'gh.cmd') -Value @('@echo off', 'pwsh -NoLogo -NoProfile -File "%~dp0fake-gh.ps1" %*', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $shim 'fake-gh.ps1') -Value @'
$dir = $env:FAKE_GH_DIR
$line = $args -join ' '
Add-Content -LiteralPath (Join-Path $dir 'calls.log') -Value $line
$path = Join-Path $dir 'runner.json'
$runner = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
if ($line -match 'DELETE' -and $line -match '/labels') {
    $runner.labels = @($runner.labels | Where-Object { $_.type -ne 'custom' })
    $runner | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
    exit 0
}
if ($line -match 'POST' -and $line -match '/labels') {
    $labels = @($runner.labels)
    foreach ($argument in $args) { if ($argument -like 'labels`[`]=*') { $labels += [pscustomobject]@{ name = $argument.Substring(9); type = 'custom' } } }
    $runner.labels = $labels
    $runner | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
    exit 0
}
if ($line -match 'actions/runners' -and $line -match '--paginate') { $runner | ConvertTo-Json -Compress -Depth 5; exit 0 }
exit 0
'@
    $runnerJson = [pscustomobject]@{ id = 7; name = 'subzerodev.runner.linux'; status = 'online'; busy = $false; labels = @(
            [pscustomobject]@{ name = 'self-hosted'; type = 'read-only' }, [pscustomobject]@{ name = 'Linux'; type = 'read-only' }
            [pscustomobject]@{ name = 'subzerodev'; type = 'custom' }, [pscustomobject]@{ name = 'subzerodev-linux'; type = 'custom' }) }
    $runnerJson | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ghState 'runner.json')
    @{ github = @{ url = $url }; windows = @{ instanceId = $testInstance }; buildAgent = @{ docker = @{ cli = (Join-Path $shim 'docker.cmd') } } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $clone 'runners.local.json')
    $linux = Join-Path $clone 'linux\runner'
    New-Item -ItemType Directory -Path $linux | Out-Null
    [pscustomobject]@{ agentId = 7; agentName = 'subzerodev.runner.linux'; gitHubUrl = $url; workFolder = '/old/work' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $linux '.runner')
    Set-Content -LiteralPath (Join-Path $linux '.credentials') -Value 'secret'
    [pscustomobject]@{ Clone = $clone; Shim = $shim; GhState = $ghState; Linux = $linux }
}
function Invoke-EntryPoint($Fixture, [string] $Script, [string[]] $Arguments) {
    $oldPath = $env:PATH; $oldGh = $env:FAKE_GH_DIR
    try {
        $env:PATH = "$($Fixture.Shim);$oldPath"; $env:FAKE_GH_DIR = $Fixture.GhState
        $output = & $pwshPath -NoLogo -NoProfile -File (Join-Path $Fixture.Clone "scripts\$Script") @Arguments 2>&1 | ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    finally { $env:PATH = $oldPath; $env:FAKE_GH_DIR = $oldGh }
}

Test-Case 'Stop-Runners.ps1 exits 1 and keeps maintenance when a container does not stop' {
    $fixture = New-EntryPointFixture
    $run = Invoke-EntryPoint $fixture 'Stop-Runners.ps1' @('-Force')
    Assert ($run.ExitCode -eq 1) "Stop-Runners.ps1 exited $($run.ExitCode) although a container did not stop.`n$($run.Output)"
    Assert ($run.Output -match 'Linux runner not stopped, maintenance kept') "The failure was not reported.`n$($run.Output)"
    $record = Get-MaintenanceState (Join-Path $fixture.Linux 'maintenance.json')
    Assert ($null -ne $record -and $record.phase -eq 'stop-failed' -and $record.runnerId -eq 7 -and (Join-Sorted $record.savedLabels) -eq 'subzerodev,subzerodev-linux') 'The recovery record was not kept with the original labels.'
    $calls = Get-Content -LiteralPath (Join-Path $fixture.GhState 'calls.log')
    Assert (-not ($calls | Where-Object { $_ -match 'POST' -and $_ -match '/labels' })) 'The labels were put back although the runner did not stop.'
    Assert ($run.Output -match 'Windows runner stopped') "The Windows runner (nothing running in the fixture) was not reported stopped.`n$($run.Output)"
}

Test-Case 'Register-Runners.ps1 does not touch the registration after a failed stop' {
    $fixture = New-EntryPointFixture
    $before = Get-Content -Raw -LiteralPath (Join-Path $fixture.Linux '.runner')
    $run = Invoke-EntryPoint $fixture 'Register-Runners.ps1' @('-NoStart')
    Assert ($run.ExitCode -eq 1) "Register-Runners.ps1 exited $($run.ExitCode).`n$($run.Output)"
    Assert ($run.Output -match 'did not stop, so its registration was not changed') "The failed stop was not the reason reported for the Linux runner.`n$($run.Output)"
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $fixture.Linux '.runner')) -eq $before -and -not (Test-Path -LiteralPath (Join-Path $fixture.Linux '_recovery'))) 'The registration files were changed or saved away.'
    $calls = Get-Content -LiteralPath (Join-Path $fixture.GhState 'calls.log')
    Assert (-not ($calls | Where-Object { $_ -match 'registration-token|remove-token' })) 'A registration or removal token was requested after a failed stop.'
    Assert ((Get-MaintenanceState (Join-Path $fixture.Linux 'maintenance.json')).phase -eq 'stop-failed') 'Maintenance was not kept.'
}

Test-Case 'Manage-WindowsRunner.ps1 -Action Status exits 1 and says what to do when the supervisor died without stopping' {
    $fixture = New-EntryPointFixture
    $windowsDir = Join-Path $fixture.Clone 'windows'
    New-Item -ItemType Directory -Path $windowsDir | Out-Null
    # A supervisor that wrote 'running' and has no process: it was killed (or the session ended) rather than stopped.
    @{ state = 'running'; pid = 2147483000; recoveries = 1; consecutiveRecoveries = 1 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $windowsDir 'supervisor.json')
    $run = Invoke-EntryPoint $fixture 'Manage-WindowsRunner.ps1' @('-Action', 'Status')
    Assert ($run.ExitCode -eq 1) "Status exited $($run.ExitCode) for a supervisor that is down.`n$($run.Output)"
    Assert ($run.Output -match 'Warning1\s+.*not running and did not stop on purpose' -and $run.Output -match 'Manage-WindowsRunner.ps1 -Action Start') "The status does not name the failure and the fix.`n$($run.Output)"
    Assert ($run.Output -match 'Recovery\s+supervisor found dead and started again by hand 1 times') "The recovery history is missing.`n$($run.Output)"
}

# --- one-time legacy cleanup ----------------------------------------------------------------------------------------------
# Real Task Scheduler and registry, but only in a throwaway task folder and Run key made for each case and removed after it.
# The functions under test are given those names explicitly; nothing here names a real task or the real Run key.
function Use-LegacyScratch {
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $taskPath = "\SubZeroDev.Runners.Test-$suffix\"
    $runKey = "HKCU:\Software\SubZeroDev.Runners.Test-$suffix"
    $directory = New-CaseDirectory
    [pscustomobject]@{ TaskPath = $taskPath; RunKey = $runKey; Directory = $directory; Names = [Collections.Generic.List[string]]::new() }
}
function Add-LegacyScratchTask($Scratch, [string] $Name, [string] $Script) {
    $action = ScheduledTasks\New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Script`""
    ScheduledTasks\Register-ScheduledTask -TaskPath $Scratch.TaskPath -TaskName $Name -Action $action -Trigger (ScheduledTasks\New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddDays(30))) -Force | Out-Null
    $Scratch.Names.Add($Name)
}
function Test-LegacyScratchTask($Scratch, [string] $Name) { [bool](ScheduledTasks\Get-ScheduledTask -TaskPath $Scratch.TaskPath -TaskName $Name -ErrorAction SilentlyContinue) }
function Remove-LegacyScratch($Scratch) {
    foreach ($name in $Scratch.Names) { ScheduledTasks\Unregister-ScheduledTask -TaskPath $Scratch.TaskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Scratch.RunKey -Recurse -Force -ErrorAction SilentlyContinue
}

Test-Case 'Legacy cleanup: removes this clone''s task and Run value, keeps another clone''s, leaves unlisted tasks alone, and a second run does nothing' {
    $scratch = Use-LegacyScratch
    $mine = Join-Path $scratch.Directory 'mine.ps1'; $theirs = Join-Path $scratch.Directory 'other-clone.ps1'
    try {
        Add-LegacyScratchTask $scratch 'Mine' $mine
        Add-LegacyScratchTask $scratch 'Foreign' $theirs
        Add-LegacyScratchTask $scratch 'Untouched' $mine
        New-Item -Path $scratch.RunKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $scratch.RunKey -Name 'Mine' -Value "`"$Pwsh`" -File `"$(Join-Path $repo 'scripts\Start-Runners.ps1')`""
        Set-ItemProperty -LiteralPath $scratch.RunKey -Name 'Foreign' -Value "`"$Pwsh`" -File `"C:\somewhere\else\Start-Runners.ps1`""
        # 'Foreign' is in the list, with this clone's script, but its registered action runs another clone's script.
        $list = @(@{ Name = 'Mine'; Script = $mine }, @{ Name = 'Foreign'; Script = $mine }, @{ Name = 'Missing'; Script = $mine })
        $first = Remove-LegacyStartupTasks -TaskPath $scratch.TaskPath -Tasks $list -RunKey $scratch.RunKey -RunValueName 'Mine'
        Assert ($first.Removed.Count -eq 2 -and $first.Failed.Count -eq 0) "Removed/failed: $($first.Removed -join ' | ') / $($first.Failed -join ' | ')"
        Assert (-not (Test-LegacyScratchTask $scratch 'Mine')) 'This clone''s task is still registered.'
        Assert (-not (Get-ItemProperty -LiteralPath $scratch.RunKey -Name 'Mine' -ErrorAction SilentlyContinue)) 'This clone''s Run value is still there.'
        Assert ($first.Kept.Count -eq 1 -and $first.Kept[0] -match 'Foreign' -and $first.Kept[0] -match 'another clone') "The other clone's task was not kept: $($first.Kept -join ' | ')"
        Assert (Test-LegacyScratchTask $scratch 'Foreign') 'Another clone''s task was removed.'
        Assert (Test-LegacyScratchTask $scratch 'Untouched') 'A task that was not in the list was removed.'
        $second = Remove-LegacyStartupTasks -TaskPath $scratch.TaskPath -Tasks $list -RunKey $scratch.RunKey -RunValueName 'Mine'
        Assert ($second.Removed.Count -eq 0 -and $second.Failed.Count -eq 0) "A second run did something: $($second.Removed -join ' | ') / $($second.Failed -join ' | ')"
        $third = Remove-LegacyStartupTasks -TaskPath $scratch.TaskPath -Tasks @() -RunKey $scratch.RunKey -RunValueName 'Foreign'
        Assert ($third.Removed.Count -eq 0 -and $third.Kept.Count -eq 1 -and (Get-ItemProperty -LiteralPath $scratch.RunKey -Name 'Foreign').Foreign) "Another clone's Run value was not kept: $($third.Kept -join ' | ')"
    }
    finally { Remove-LegacyScratch $scratch }
}

Test-Case 'Legacy cleanup: the defaults name the supervisor and log trim tasks, each removed only when it runs this clone''s script' {
    $scratch = Use-LegacyScratch
    try {
        Add-LegacyScratchTask $scratch $LegacyWindowsTaskName $Supervisor
        Add-LegacyScratchTask $scratch $LegacyLogTrimTaskName 'C:\somewhere\else\scripts\Trim-RunnerLogs.ps1'
        $result = Remove-LegacyStartupTasks -TaskPath $scratch.TaskPath -RunKey $scratch.RunKey
        Assert ($result.Removed.Count -eq 1 -and $result.Removed[0] -match [regex]::Escape($LegacyWindowsTaskName)) "Removed: $($result.Removed -join ' | ')"
        Assert ($result.Kept.Count -eq 1 -and $result.Kept[0] -match [regex]::Escape($LegacyLogTrimTaskName)) "Kept: $($result.Kept -join ' | ')"
        Assert (-not (Test-LegacyScratchTask $scratch $LegacyWindowsTaskName) -and (Test-LegacyScratchTask $scratch $LegacyLogTrimTaskName)) 'The wrong task was removed.'
        Assert ($result.Failed.Count -eq 0) "Failed: $($result.Failed -join ' | ')"
    }
    finally { Remove-LegacyScratch $scratch }
}

Test-Case 'Legacy cleanup: removing a task does not stop the supervisor that task started' {
    $scratch = Use-LegacyScratch
    $sleeper = Join-Path $scratch.Directory 'sleeper.ps1'
    Set-Content -LiteralPath $sleeper -Value 'Start-Sleep -Seconds 120'
    $find = { @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*$sleeper*" }) }
    try {
        Add-LegacyScratchTask $scratch 'Mine' $sleeper
        ScheduledTasks\Start-ScheduledTask -TaskPath $scratch.TaskPath -TaskName 'Mine'
        $end = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (& $find) -and [DateTime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 300 }
        Assert ((& $find).Count -ge 1) 'The scratch task did not start its process.'
        $result = Remove-LegacyStartupTasks -TaskPath $scratch.TaskPath -Tasks @(@{ Name = 'Mine'; Script = $sleeper }) -RunKey $scratch.RunKey -RunValueName 'Mine'
        Assert ($result.Removed.Count -eq 1 -and -not (Test-LegacyScratchTask $scratch 'Mine')) "The task was not removed: $($result.Removed -join ' | ') / $($result.Failed -join ' | ')"
        Start-Sleep -Seconds 1
        Assert ((& $find).Count -ge 1) 'Removing the task ended the process it had started.'
    }
    finally {
        foreach ($process in & $find) { Microsoft.PowerShell.Management\Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
        Remove-LegacyScratch $scratch
    }
}

# The clone has its own throwaway instance id, so none of its task names exists. The Run value name has no instance suffix and is
# read from the real key, but is removed only if it runs this clone's scripts, which it cannot (the clone is new).
Test-Case 'Remove-LegacyTasks.ps1 in a new clone removes nothing and exits 0' {
    $fixture = New-EntryPointFixture
    $run = Invoke-EntryPoint $fixture 'Remove-LegacyTasks.ps1' @()
    Assert ($run.ExitCode -eq 0) "Exit $($run.ExitCode).`n$($run.Output)"
    Assert ($run.Output -notmatch 'Removed the legacy') "Something was removed.`n$($run.Output)"
    Assert ($run.Output -match 'No legacy startup tasks to remove\.' -or $run.Output -match 'Left the ') "Neither 'nothing to remove' nor a kept line was printed.`n$($run.Output)"
}

# A clone whose supervisor cannot be killed: supervisor.json says it was running, Get-SupervisorProcess and Invoke-TaskKill are
# replaced (functions appended to the clone's own copy of Lifecycle.ps1) by a supervisor with a fake pid that taskkill refuses to
# end. Nothing here addresses a real process.
function New-UnstoppableSupervisorFixture {
    $fixture = New-EntryPointFixture
    $windowsDir = Join-Path $fixture.Clone 'windows'
    New-Item -ItemType Directory -Path $windowsDir | Out-Null
    @{ state = 'running'; pid = 987653 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $windowsDir 'supervisor.json')
    $localPath = Join-Path $fixture.Clone 'runners.local.json'
    $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json -AsHashtable
    $local.lifecycle = @{ stopTimeoutSeconds = 1; pollSeconds = 1 }
    $local | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $localPath
    Add-Content -LiteralPath (Join-Path $fixture.Clone 'scripts\Lifecycle.ps1') -Value @'

function Get-SupervisorProcess { [pscustomobject]@{ ProcessId = 987653 } }
function Invoke-TaskKill([int] $ProcessId) { [pscustomobject]@{ ExitCode = 1; Output = 'ERROR: The process could not be terminated. Access is denied.' } }
'@
    $fixture | Add-Member -NotePropertyName WindowsDir -NotePropertyValue $windowsDir -PassThru
}

Test-Case 'Manage-WindowsRunner.ps1 -Action Stop, Restart and Maintenance exit 1 and keep maintenance when the supervisor cannot be ended' {
    foreach ($action in @('Stop'), @('Restart'), @('Maintenance')) {
        $fixture = New-UnstoppableSupervisorFixture
        $run = Invoke-EntryPoint $fixture 'Manage-WindowsRunner.ps1' (@('-Action') + $action + @('-Force'))
        Assert ($run.ExitCode -eq 1) "-Action $action exited $($run.ExitCode) although the supervisor is still running.`n$($run.Output)"
        Assert ($run.Output -match 'The runner was not stopped; maintenance is kept' -and $run.Output -match 'taskkill of the supervisor \(pid 987653\)') "-Action $action did not report the reason.`n$($run.Output)"
        $record = Get-MaintenanceState (Join-Path $fixture.WindowsDir 'maintenance.json')
        Assert ($null -ne $record -and $record.phase -eq 'stop-failed' -and $record.failure -match 'Still running') "-Action ${action}: maintenance was not kept with the reason: $($record | ConvertTo-Json -Compress)"
    }
}

Test-Case 'Stop-Runners.ps1 reports a Windows supervisor that cannot be ended as not stopped' {
    $fixture = New-UnstoppableSupervisorFixture
    $run = Invoke-EntryPoint $fixture 'Stop-Runners.ps1' @('-Force')
    Assert ($run.ExitCode -eq 1) "Stop-Runners.ps1 exited $($run.ExitCode).`n$($run.Output)"
    Assert ($run.Output -match 'Windows runner not stopped, maintenance kept: .*Still running') "The Windows failure was not reported.`n$($run.Output)"
    Assert ((Get-MaintenanceState (Join-Path $fixture.WindowsDir 'maintenance.json')).phase -eq 'stop-failed') 'Maintenance was not kept.'
}
# The real supervisor script in a child process, against a stand-in runner: run.cmd starts a copy of ping.exe named
# Runner.Listener.exe, inside a clone of its own with a throwaway instance id (own mutex, own pid file). Nothing here
# addresses the supervisor or the clone of this machine.
Test-Case 'Real supervisor: a killed supervisor is replaced by an explicit Start with exactly one listener, and maintenance still prevents the listener' {
    $fixture = New-EntryPointFixture
    $windowsDir = Join-Path $fixture.Clone 'windows'
    New-Item -ItemType Directory -Path (Join-Path $windowsDir 'bin') | Out-Null
    Copy-Item (Join-Path $env:SystemRoot 'System32\PING.EXE') (Join-Path $windowsDir 'bin\Runner.Listener.exe')
    Set-Content -LiteralPath (Join-Path $windowsDir 'run.cmd') -Value @('@echo off', '"%~dp0bin\Runner.Listener.exe" -n 600 127.0.0.1 >nul')
    $localPath = Join-Path $fixture.Clone 'runners.local.json'
    $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json -AsHashtable
    $local.lifecycle = @{ pollSeconds = 1 }
    $local | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $localPath
    $script = Join-Path $fixture.Clone 'scripts\Run-WindowsRunner.ps1'
    $statusPath = Join-Path $windowsDir 'supervisor.json'; $maintenancePath = Join-Path $windowsDir 'maintenance.json'
    $started = [Collections.Generic.List[object]]::new()
    $getStatus = { if (Test-Path -LiteralPath $statusPath) { try { Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch { } } }
    $getListeners = { @(Get-CimInstance Win32_Process -Filter "Name='Runner.Listener.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$windowsDir\", [StringComparison]::OrdinalIgnoreCase) }) }
    $waitFor = { param([scriptblock] $Condition, [string] $What, [int] $Seconds = 40)
        $end = [DateTime]::UtcNow.AddSeconds($Seconds)
        while ([DateTime]::UtcNow -lt $end) { if (& $Condition) { return }; Start-Sleep -Milliseconds 300 }
        throw "Timed out after ${Seconds}s waiting for: $What. Status: $((& $getStatus | ConvertTo-Json -Compress)); listeners: $((& $getListeners).Count)"
    }
    # Start-Process is faked in this file; the real one is addressed by module on purpose.
    $startSupervisor = { $process = Microsoft.PowerShell.Management\Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script) -WindowStyle Hidden -PassThru; $started.Add($process); $process }
    try {
        # 1. The first supervisor starts one listener.
        $first = & $startSupervisor
        & $waitFor { (& $getListeners).Count -eq 1 -and (& $getStatus).state -eq 'running' } 'the first supervisor to start its listener'
        Assert (-not (& $getStatus).recoveries) 'A fresh start was counted as a recovery.'

        # 2. The supervisor dies the hard way (no finally block). Its listener survives, as it would in a real failure.
        Microsoft.PowerShell.Management\Stop-Process -Id $first.Id -Force; $first.WaitForExit()
        Assert ((& $getStatus).state -eq 'running') 'A killed supervisor left a status that says it stopped.'
        Assert ((& $getListeners).Count -eq 1) 'The listener did not survive the supervisor.'

        # 3. Nothing restarts it. An explicit Start (Manage-WindowsRunner.ps1 -Action Start, in this clone) launches a replacement,
        #    which records the recovery and does not start a second listener. Not run through Invoke-EntryPoint: the detached
        #    supervisor must not be able to hold a pipe of this test open.
        $manageStart = {
            $out = Join-Path $fixture.Clone ('start-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.out')
            $manage = Microsoft.PowerShell.Management\Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-File', (Join-Path $fixture.Clone 'scripts\Manage-WindowsRunner.ps1'), '-Action', 'Start') -RedirectStandardOutput $out -PassThru -WindowStyle Hidden
            if (-not $manage.WaitForExit(60000)) { throw 'Manage-WindowsRunner.ps1 -Action Start did not return within 60 s.' }
            if ($manage.ExitCode -ne 0) { throw "Manage-WindowsRunner.ps1 -Action Start exited $($manage.ExitCode): $(Get-Content -Raw -LiteralPath $out)" }
            (Get-Content -Raw -LiteralPath $out)
        }
        $startText = & $manageStart
        Assert ($startText -match 'started \(pid (\d+)\)') "Start did not report a started supervisor: $startText"
        $second = Get-Process -Id ([int]$Matches[1]); $started.Add($second)
        & $waitFor { (& $getStatus).state -eq 'waiting-for-orphan' } 'the replacement supervisor to wait for the orphaned listener'
        $status = & $getStatus
        Assert ($status.recoveries -eq 1 -and $status.consecutiveRecoveries -eq 1 -and $status.lastRecoveryNote -match 'ended without stopping') "The recovery was not recorded: $($status | ConvertTo-Json -Compress)"
        Start-Sleep -Seconds 3
        Assert ((& $getListeners).Count -eq 1) "There are $((& $getListeners).Count) listeners beside the orphan."

        # 3b. A second Start finds that supervisor (pid file and command line) and starts nothing.
        $again = & $manageStart
        Assert ($again -match "already running \(pid $($second.Id)\)") "A second Start did not find the running supervisor: $again"
        Assert ((& $getListeners).Count -eq 1 -and -not $second.HasExited) 'The second Start disturbed the supervisor or the listener.'
        # 4. A duplicate supervisor exits at once and cleanly on the mutex; it touches nothing.
        $third = & $startSupervisor
        Assert ($third.WaitForExit(30000) -and $third.ExitCode -eq 0) 'A duplicate supervisor did not exit cleanly.'
        Assert ((& $getListeners).Count -eq 1 -and -not $second.HasExited) 'The duplicate disturbed the running supervisor or the listener.'

        # 5. The replacement dies as well and the orphan is gone; maintenance is on before the next supervisor starts.
        Microsoft.PowerShell.Management\Stop-Process -Id $second.Id -Force; $second.WaitForExit()
        foreach ($listener in & $getListeners) { Microsoft.PowerShell.Management\Stop-Process -Id $listener.ProcessId -Force }
        & $waitFor { (& $getListeners).Count -eq 0 } 'the orphaned listener to end'
        # Keep this test from raising a real toast (two recoveries in a row notify): the streak is not what is under test here.
        $status = & $getStatus
        $status.consecutiveRecoveries = 0
        $status | ConvertTo-Json | Set-Content -LiteralPath $statusPath
        Set-Content -LiteralPath $maintenancePath -Value '{"phase":"stopped"}'
        $fourth = & $startSupervisor
        & $waitFor { (& $getStatus).state -eq 'maintenance' } 'the supervisor to idle in maintenance'
        Start-Sleep -Seconds 3
        Assert ((& $getListeners).Count -eq 0) 'A listener started while maintenance was on.'

        # 6. Ending maintenance gives exactly one listener.
        Remove-Item -LiteralPath $maintenancePath
        & $waitFor { (& $getListeners).Count -eq 1 -and (& $getStatus).state -eq 'running' } 'the listener to start after maintenance ended'
        Start-Sleep -Seconds 3
        Assert ((& $getListeners).Count -eq 1) "There are $((& $getListeners).Count) listeners after maintenance ended."
    }
    finally {
        foreach ($process in $started) { if (-not $process.HasExited) { Microsoft.PowerShell.Management\Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
        foreach ($listener in & $getListeners) { Microsoft.PowerShell.Management\Stop-Process -Id $listener.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

Test-Case 'The real legacy scheduled tasks of this machine were not changed by this run' {
    $after = Get-RealTaskFingerprint
    Assert (($after -join "`n") -eq ($realTasksBefore -join "`n")) "A real task changed.`nBefore:`n$($realTasksBefore -join "`n")`nAfter:`n$($after -join "`n")"
}

Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
$failed = @($cases | Where-Object { -not $_.Passed })
Write-Host "$($cases.Count - $failed.Count) of $($cases.Count) lifecycle recovery checks passed."
if ($failed) { Write-Host "Failed:`n - $(($failed | ForEach-Object { $_.Name }) -join "`n - ")"; exit 1 }
# The cases run native commands that exit nonzero on purpose; without this a CI step (pwsh -Command) reports the last of them.
exit 0
