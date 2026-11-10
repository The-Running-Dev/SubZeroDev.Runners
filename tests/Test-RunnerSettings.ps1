#Requires -Version 7.2
# Settings and slot resolution (S1): validation, slot names, runners.host.json layering, drift and the one-writer rule.
# Temporary folders only; no runner, container or GitHub registration is touched.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\RunnerConfig.ps1')
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message, [string] $Pattern) {
    $thrown = $null
    try { & $Action | Out-Null } catch { $thrown = $_.Exception.Message }
    Assert ($null -ne $thrown) $Message
    if ($Pattern) { Assert ($thrown -match $Pattern) "$Message (wrong reason: $thrown)" }
}
function New-Root([hashtable] $Local) {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('runner-settings-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'runners.json') -Destination $root
    if ($Local) { ConvertTo-Json -InputObject $Local -Depth 10 | Set-Content -LiteralPath (Join-Path $root 'runners.local.json') }
    $root
}
$roots = [Collections.Generic.List[string]]::new()
function Use-Root([hashtable] $Local) { $root = New-Root $Local; $roots.Add($root); $root }
$fixedHost = @{ hostId = 'beast' }

try {
    # Defaults: counts unset (keep what exists), sign-in start off, the Default group for all repositories.
    $config = Read-RunnerConfig (Use-Root $fixedHost)
    Assert ($null -eq $config.linux.count -and $null -eq $config.windows.count) 'Counts have a numeric default.'
    Assert ($config.windows.startAtSignIn -eq $false) 'windows.startAtSignIn does not default to false.'
    Assert ($config.github.runnerGroup.name -eq 'Default' -and $null -eq $config.github.runnerGroup.repositories) 'The runner group default is wrong.'
    Assert ($config.buildAgent.estimate.memory -eq '8g') 'The BuildAgent memory estimate default is wrong.'
    Assert ((Get-RunnerHostId $config) -eq 'beast') 'hostId from runners.local.json was not used.'
    $noHost = Read-RunnerConfig (Use-Root)
    if ($env:COMPUTERNAME -and $env:COMPUTERNAME.ToLowerInvariant() -match '^[a-z0-9][a-z0-9-]{0,30}$') {
        Assert ((Get-RunnerHostId $noHost) -eq $env:COMPUTERNAME.ToLowerInvariant()) 'An unset hostId is not the lower-cased computer name.'
    }

    # Counts: null, 0 and 16 accepted; 17, -1, a string and a fraction refused. hostId: the pattern only.
    foreach ($count in 0, 16) {
        $ok = Read-RunnerConfig (Use-Root @{ hostId = 'beast'; linux = @{ count = $count }; windows = @{ count = $count } })
        Assert ($ok.linux.count -eq $count -and $ok.windows.count -eq $count) "Count $count was not kept."
    }
    foreach ($bad in 17, -1, '2', 2.5) {
        Assert-Throws { Read-RunnerConfig (Use-Root @{ linux = @{ count = $bad } }) } "linux.count $bad was accepted." 'linux\.count'
        Assert-Throws { Read-RunnerConfig (Use-Root @{ windows = @{ count = $bad } }) } "windows.count $bad was accepted." 'windows\.count'
    }
    foreach ($bad in 'Beast', 'beast_2', '-beast', ('a' * 32), '') {
        if ($bad -eq '') { continue }
        Assert-Throws { Read-RunnerConfig (Use-Root @{ hostId = $bad }) } "hostId '$bad' was accepted." 'hostId'
    }
    Assert-Throws { Read-RunnerConfig (Use-Root @{ windows = @{ startAtSignIn = 'yes' } }) } 'A non-boolean startAtSignIn was accepted.' 'startAtSignIn'
    Assert-Throws { Read-RunnerConfig (Use-Root @{ github = @{ runnerGroup = @{ name = '' } } }) } 'An empty runner group name was accepted.' 'runnerGroup\.name'
    Assert-Throws { Read-RunnerConfig (Use-Root @{ github = @{ runnerGroup = @{ name = 'Pool'; repositories = @('not a repo') } } }) } 'A bad group repository was accepted.' 'repositories'
    Assert-Throws { Read-RunnerConfig (Use-Root @{ housekeeping = @{ minFreeGB = -1 } }) } 'A negative minFreeGB was accepted.' 'minFreeGB'
    Assert-Throws { Read-RunnerConfig (Use-Root @{ buildAgent = @{ estimate = @{ memory = 'lots' } } }) } 'A bad memory estimate was accepted.' 'estimate\.memory'
    $nullFree = Read-RunnerConfig (Use-Root @{ housekeeping = @{ minFreeGB = $null } })
    Assert ($null -eq $nullFree.housekeeping.minFreeGB) 'A null minFreeGB (no free-space check) was refused.'
    # The earlier check accepted a numeric string, so a runners.local.json written for it must still load.
    $stringFree = Read-RunnerConfig (Use-Root @{ housekeeping = @{ minFreeGB = '5' } })
    Assert ([double]$stringFree.housekeeping.minFreeGB -eq 5) 'A numeric-string minFreeGB from an existing runners.local.json was refused.'
    Assert-Throws { Read-RunnerConfig (Use-Root @{ housekeeping = @{ minFreeGB = 'lots' } }) } 'A non-numeric minFreeGB was accepted.' 'minFreeGB'

    # Slot names for 1, 2 and 16 slots on both platforms, on an empty inventory.
    foreach ($count in 1, 2, 16) {
        $linux = @(Get-LinuxSlots $config $null $count)
        $windows = @(Get-WindowsSlots $config $null $count 'C:\Root')
        Assert ($linux.Count -eq $count -and $windows.Count -eq $count) "Wrong slot count for $count."
        $last = '{0:D2}' -f $count
        Assert ($linux[-1].SlotId -eq "linux-$last" -and $linux[-1].RunnerName -eq "subzerodev.runner.linux.beast.$last") "Linux slot $last is misnamed: $($linux[-1].RunnerName)"
        Assert ($linux[-1].Container -eq "subzerodev-runner-linux-$last" -and $linux[-1].Directory -eq "linux/runner-$last") "Linux slot $last container or directory is wrong."
        Assert ($linux[-1].Volumes.Cache -match "-$last$" -and $linux[-1].New) "Linux slot $last volumes or New flag wrong."
        Assert (@($linux.Container | Select-Object -Unique).Count -eq $count -and @($linux.Volumes.Cache | Select-Object -Unique).Count -eq $count) 'Linux slots share a container or a cache volume.'
        Assert ($windows[-1].InstanceId -eq "win$last" -and $windows[-1].RunnerName -eq "subzerodev.runner.windows.beast.win$last" -and $windows[-1].InstallPath -eq "C:\Root\win$last") "Windows slot $last is misnamed."
        foreach ($slot in $windows) {
            Assert ($slot.Labels -contains 'subzerodev-host-beast') "win$($slot.Number) lacks the host label."
            Assert (($slot.Labels -contains 'subzerodev-pair-beast') -eq ($slot.Number -le 2)) "win$($slot.Number) has the wrong pair label."
        }
        foreach ($label in @($config.github.labels) + @($config.linux.labels)) { Assert ($linux[0].Labels -contains $label) "Linux slot lacks the $label label." }
        foreach ($label in @($config.github.labels) + @($config.windows.labels)) { Assert ($windows[0].Labels -contains $label) "Windows slot lacks the $label label." }
    }

    # Slot 01 marked legacy keeps the pre-pool names (its registration and caches survive); its container still gets -01.
    $legacyInventory = [pscustomobject]@{ slots = @([pscustomobject]@{ platform = 'linux'; slotId = 'linux-01'; state = 'active'; legacy = $true }) }
    $pair = @(Get-LinuxSlots $config $legacyInventory 2)
    Assert ($pair[0].Legacy -and -not $pair[0].New -and $pair[0].RunnerName -eq $config.linux.name -and $pair[0].Directory -eq $config.linux.directory) 'The legacy slot lost its runner name or directory.'
    Assert ($pair[0].Volumes.Cache -eq $config.linux.cacheVolume -and $pair[0].Volumes.Work -eq $config.linux.docker.workVolume) 'The legacy slot lost its volumes.'
    Assert ($pair[0].Container -eq "$($config.linux.container)-01") 'The legacy slot container is not the -01 name.'
    Assert (-not $pair[1].Legacy -and $pair[1].RunnerName -eq 'subzerodev.runner.linux.beast.02' -and $pair[1].New) 'Slot 02 beside a legacy slot is wrong.'
    $badLegacy = [pscustomobject]@{ slots = @([pscustomobject]@{ platform = 'linux'; slotId = 'linux-02'; state = 'active'; legacy = $true }) }
    Assert-Throws { Get-LinuxSlots $config $badLegacy 2 } 'A legacy mark on slot 02 was accepted.' 'only slot 01'

    # Numbers are never reused; a lower count retires the highest; a null count keeps exactly the live slots.
    $history = [pscustomobject]@{ slots = @(
        [pscustomobject]@{ platform = 'windows'; slotId = 'win01'; state = 'active' },
        [pscustomobject]@{ platform = 'windows'; slotId = 'win02'; state = 'retired' },
        [pscustomobject]@{ platform = 'windows'; slotId = 'win03'; state = 'active' }
    ) }
    Assert ((@(Get-WindowsSlots $config $history 3 'C:\Root').SlotId -join ',') -eq 'win01,win03,win04') 'A retired slot number was reused.'
    Assert ((@(Get-WindowsSlots $config $history 1 'C:\Root').SlotId -join ',') -eq 'win01') 'A lower count did not keep the lowest live slot.'
    Assert ((@(Get-WindowsSlots $config $history $null 'C:\Root').SlotId -join ',') -eq 'win01,win03') 'A null count did not keep exactly the live slots.'
    Assert (@(Get-WindowsSlots $config $history 0 'C:\Root').Count -eq 0) 'Count 0 returned slots.'
    $full = [pscustomobject]@{ slots = @([pscustomobject]@{ platform = 'linux'; slotId = 'linux-99'; state = 'retired' }) }
    Assert-Throws { Get-LinuxSlots $config $full 1 } 'A slot number above 99 was issued.' '99'

    # runners.host.json carries every host-owned setting and none of Install's.
    $slot = @(Get-WindowsSlots $config $null 1 'C:\Root')[0]
    $settings = New-HostSettings $config $slot
    foreach ($name in Get-HostOwnedSettingNames) { $v = $null; Assert (Find-Setting $settings $name ([ref]$v)) "runners.host.json lacks $name." }
    foreach ($name in Get-InstallOwnedSettingNames) { $v = $null; Assert (-not (Find-Setting $settings $name ([ref]$v))) "runners.host.json carries the Install-owned $name." }
    Assert ($settings.hostId -eq 'beast' -and $settings.generated.by -eq 'Manage-RunnerHost' -and $settings.generated.hash -eq (Get-HostSettingsHash $settings)) 'The generated block is wrong.'
    Assert-Throws { New-HostSettings $config @(Get-LinuxSlots $config $null 1)[0] } 'Host settings were built for a Linux slot.'

    # Without runners.host.json, Read-RunnerConfig resolves exactly as the pre-S1 loader (runners.json < runners.local.json).
    function Read-PreviousConfig([string] $Root) {
        $previous = Get-Content -Raw -LiteralPath (Join-Path $Root 'runners.json') | ConvertFrom-Json
        $localPath = Join-Path $Root 'runners.local.json'
        if (Test-Path -LiteralPath $localPath) { Merge-Settings $previous (Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json) }
        if (-not $previous.linux.baseImage -and $previous.buildAgent.image) { $previous.linux | Add-Member -Force -NotePropertyName baseImage -NotePropertyValue $previous.buildAgent.image }
        $previous
    }
    foreach ($local in $null, @{ github = @{ url = 'https://github.com/example' }; windows = @{ instanceId = 'win01'; name = 'n' }; lifecycle = @{ pollSeconds = 9 } }) {
        $root = Use-Root $local
        Assert ((ConvertTo-CanonicalJson (Read-RunnerConfig $root)) -eq (ConvertTo-CanonicalJson (Read-PreviousConfig $root))) 'Without runners.host.json the settings differ from the previous loader.'
    }

    # Precedence: runners.json < runners.host.json < runners.local.json; the generated block never reaches the settings.
    $clone = Use-Root @{ windows = @{ instanceId = 'win01' }; lifecycle = @{ pollSeconds = 7 } }
    $hostSettings = New-HostSettings $config $slot
    $hostSettings.lifecycle.pollSeconds = 5; $hostSettings.lifecycle.drainTimeoutMinutes = 11
    $hostSettings.generated.hash = Get-HostSettingsHash $hostSettings
    Write-HostSettings -Clone $clone -Settings $hostSettings
    $layered = Read-RunnerConfig $clone
    Assert ($layered.lifecycle.pollSeconds -eq 7 -and $layered.lifecycle.drainTimeoutMinutes -eq 11 -and $layered.hostId -eq 'beast') 'The three files did not layer in order.'
    Assert (-not $layered.PSObject.Properties['generated']) 'The generated block leaked into the settings.'
    Assert (@(Test-HostSettingsDrift -Clone $clone | Where-Object Kind -ne 'local-override').Count -eq 0) 'A freshly written runners.host.json reported drift.'
    Assert ((@(Test-HostSettingsDrift -Clone $clone).Setting) -contains 'lifecycle') 'A host-owned setting in runners.local.json was not reported.'
    Assert (@(Test-HostSettingsDrift -Clone (Use-Root)).Count -eq 0) 'A clone without runners.host.json reported drift.'

    # A hand edit is drift and is kept unless -Force; the manager never writes runners.local.json.
    $clone = Use-Root @{ windows = @{ instanceId = 'win01'; name = 'kept' } }
    $hostPath = Join-Path $clone 'runners.host.json'
    $localPath = Join-Path $clone 'runners.local.json'
    $localBefore = [IO.File]::ReadAllBytes($localPath)
    Write-HostSettings -Clone $clone -Settings (New-HostSettings $config $slot)
    $edited = (Get-Content -Raw -LiteralPath $hostPath) -replace '"retentionDays":\s*\d+', '"retentionDays": 99'
    Assert ($edited -match '"retentionDays": 99') 'The fixture edit did not apply.'
    [IO.File]::WriteAllText($hostPath, $edited)
    $editedBytes = [IO.File]::ReadAllBytes($hostPath)
    Assert ((@(Test-HostSettingsDrift -Clone $clone).Kind) -contains 'edited') 'A hand edit was not reported as drift.'
    Assert-Throws { Write-HostSettings -Clone $clone -Settings (New-HostSettings $config $slot) } 'A hand-edited runners.host.json was overwritten without -Force.' '-Force'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hostPath)) -eq [Convert]::ToBase64String($editedBytes)) 'The refused write changed runners.host.json.'
    Write-HostSettings -Clone $clone -Settings (New-HostSettings $config $slot) -Force
    Assert (@(Test-HostSettingsDrift -Clone $clone).Count -eq 0) '-Force did not replace the edited file.'
    [IO.File]::WriteAllText($hostPath, '[1, 2]')
    Assert ((@(Test-HostSettingsDrift -Clone $clone).Kind) -contains 'unreadable') 'A non-object runners.host.json was not reported.'
    Assert-Throws { Write-HostSettings -Clone $clone -Settings (New-HostSettings $config $slot) } 'An unreadable runners.host.json was overwritten without -Force.' '-Force'
    Assert-Throws { Read-RunnerConfig $clone } 'An unreadable runners.host.json was read as settings.' 'runners\.host\.json cannot be read'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($localPath)) -eq [Convert]::ToBase64String($localBefore)) 'The host manager changed runners.local.json.'
    Assert (@(Get-ChildItem -LiteralPath $clone -Filter '*.tmp' -Force).Count -eq 0) 'An atomic write left a temporary file.'

    # One writer per file: only RunnerConfig.ps1 names runners.host.json, so Install and its helpers cannot write it.
    $writers = @(Get-ChildItem -LiteralPath $repo -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' -and (Select-String -LiteralPath $_.FullName -SimpleMatch 'runners.host.json' -Quiet) })
    Assert (($writers.Name -join ',') -eq 'RunnerConfig.ps1') "Scripts other than RunnerConfig.ps1 name runners.host.json: $($writers.Name -join ', ')"
    Assert (-not (Select-String -LiteralPath (Join-Path $repo 'scripts\RunnerConfig.ps1') -Pattern 'runners\.local\.json.*(Set-Content|WriteAll|Write-FileAtomic)|(Set-Content|WriteAll|Write-FileAtomic).*runners\.local\.json' -Quiet)) 'RunnerConfig.ps1 writes runners.local.json.'
    Assert ((Get-Content -Raw (Join-Path $repo '.gitignore')) -match '(?m)^/runners\.host\.json$') 'runners.host.json is not git-ignored.'
    Assert ((Get-Content -Raw (Join-Path $repo 'dropbox-ignore.txt')) -match '(?m)^runners\.host\.json$') 'runners.host.json is not in dropbox-ignore.txt.'

    # The loader is also dot-sourced by Windows PowerShell 5.1 scripts: it must parse there and hash identically.
    $desktop = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($desktop) {
        $hashScript = ". '$(Join-Path $repo 'scripts\RunnerConfig.ps1')'; `$c = Read-RunnerConfig '$($roots[0])'; `$s = New-HostSettings `$c @(Get-WindowsSlots `$c `$null 1 'C:\Root')[0]; `$s.generated.hash"
        $desktopHash = (& $desktop.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -Command $hashScript 2>&1 | Out-String).Trim()
        Assert ($desktopHash -eq $settings.generated.hash) "Windows PowerShell 5.1 hashes runners.host.json differently: $desktopHash"
    }
} finally {
    foreach ($root in $roots) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host 'PASS: settings defaults and validation, Linux and Windows slot names (1, 2, 16, legacy 01, no reuse), runners.host.json contents, layering, drift, -Force and the one-writer rule.'
