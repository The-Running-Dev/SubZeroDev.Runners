# The one settings loader. runners.json, then runners.local.json (git-ignored, this machine's settings) merged over it,
# then validated. Every host script, the setup phase and the cleanup hooks read settings through Read-RunnerConfig, so
# a value saved to runners.local.json cannot mean one thing to the installer and another to a hook.
# Objects merge setting by setting at every level: { "linux": { "docker": { "mode": "dind" } } } changes only that mode.
function Merge-Settings($Target, $Source) {
    foreach ($setting in $Source.PSObject.Properties) {
        $current = $Target.($setting.Name)
        if ($current -is [pscustomobject] -and $setting.Value -is [pscustomobject]) { Merge-Settings $current $setting.Value }
        else { $Target | Add-Member -Force -NotePropertyName $setting.Name -NotePropertyValue $setting.Value }
    }
}

# Throws one error listing every invalid setting, so a bad runners.local.json is fixed in one pass.
function Assert-RunnerConfig($Config) {
    $problems = [Collections.Generic.List[string]]::new()
    function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { $problems.Add($Message) } }
    function IsDigest([string] $Reference) { $Reference -match '^[^\s@]+@sha256:[0-9a-f]{64}$' }
    function IsRelativeInside([string] $Path) {
        $Path -and -not [IO.Path]::IsPathRooted($Path) -and $Path -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $Path -notmatch '[:*?"<>|]'
    }
    Require ($Config.runnerVersion -match '^\d+\.\d+\.\d+$') 'runnerVersion must be a version such as 2.338.0.'
    if ($Config.windows.instanceId) { Require ($Config.windows.instanceId -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$') 'Invalid windows.instanceId: use 1-40 letters, digits, underscores or hyphens.' }
    Require ([bool]$Config.windows.name) 'windows.name is required.'
    Require ([bool]$Config.windows.workFolder) 'windows.workFolder is required.'
    $agent = $Config.buildAgent
    if ($agent) {
        Require ($agent.tool.version -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') 'buildAgent.tool.version must be an exact version such as 2.1.0, never a range or latest.'
        Require ([bool]$agent.tool.package) 'buildAgent.tool.package is required.'
        Require ([bool]$agent.tool.directory) 'buildAgent.tool.directory is required.'
        Require ($agent.dotnetRuntime.channel -match '^\d+\.\d+$') 'buildAgent.dotnetRuntime.channel must be a channel such as 8.0.'
        Require ([bool]$agent.dotnetRuntime.directory) 'buildAgent.dotnetRuntime.directory is required.'
        Require (IsDigest $agent.image) 'buildAgent.image must be pinned by digest (name@sha256:<64 hex>); a tag, including latest, is refused.'
        if ($agent.docker.host) { Require ($agent.docker.host -match '^(npipe|tcp|unix)://\S+$') 'buildAgent.docker.host must be npipe://, tcp:// or unix://, or null for the default daemon.' }
        Require ([int]$agent.docker.readyTimeoutSeconds -gt 0) 'buildAgent.docker.readyTimeoutSeconds must be a positive number.'
        Require ([bool]$agent.paths.workspaceRoot) 'buildAgent.paths.workspaceRoot is required.'
        Require (IsRelativeInside $agent.paths.outputDirectory) 'buildAgent.paths.outputDirectory must be a relative path inside the workspace.'
        Require (IsRelativeInside $agent.paths.cacheDirectory) 'buildAgent.paths.cacheDirectory must be a relative path inside the workspace.'
        Require (@($agent.paths.extraMounts).Count -eq 0) 'buildAgent.paths.extraMounts must be empty: build-agent build mounts only the workspace and the Docker socket, and there is no supported way to add a mount.'
        Require ([int]$agent.cache.retentionDays -ge 0 -and [int]$agent.cache.maxGB -ge 0) 'buildAgent.cache.retentionDays and maxGB must not be negative.'
        if ($agent.updater.version) { Require ($agent.updater.version -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') 'buildAgent.updater.version must be an exact published BuildAgent.Tool version, never latest.' }
    }
    if ($Config.linux.baseImage) { Require (IsDigest $Config.linux.baseImage) 'linux.baseImage must be pinned by digest.' }
    Require ($Config.linux.docker.mode -in 'sidecar', 'dind') 'linux.docker.mode must be sidecar or dind.'
    foreach ($key in 'drainTimeoutMinutes', 'pollSeconds', 'stopTimeoutSeconds', 'restartDelaySeconds', 'quickExitSeconds', 'quickExitLimit', 'backoffMaxSeconds', 'startTimeoutSeconds') {
        Require ([int]$Config.lifecycle.$key -gt 0) "lifecycle.$key must be a positive number."
    }
    Require ([int]$Config.logs.retentionDays -gt 0 -and [int]$Config.logs.maxMB -gt 0) 'logs.retentionDays and logs.maxMB must be positive.'
    Require ([int]$Config.housekeeping.retries -gt 0 -and [int]$Config.housekeeping.retryDelaySeconds -ge 0) 'housekeeping.retries must be positive; retryDelaySeconds must not be negative.'
    $minFree = $Config.housekeeping.minFreeGB
    # A numeric string ("5") was accepted before null meant "no check"; existing runners.local.json files keep working.
    $minFreeNumber = 0.0
    $isNumber = $minFree -is [int] -or $minFree -is [long] -or $minFree -is [double] -or $minFree -is [decimal]
    if ($isNumber) { $minFreeNumber = [double]$minFree }
    elseif ($minFree -is [string]) { $isNumber = [double]::TryParse($minFree, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$minFreeNumber) }
    Require ($null -eq $minFree -or ($isNumber -and $minFreeNumber -ge 0)) 'housekeeping.minFreeGB must be null (no free-space check) or a number of GB, not negative.'
    if ($null -ne $Config.hostId) { Require ("$($Config.hostId)" -cmatch '^[a-z0-9][a-z0-9-]{0,30}$') 'hostId must be 1-31 lower-case letters, digits or hyphens, starting with a letter or digit.' }
    foreach ($platform in 'linux', 'windows') {
        $count = $Config.$platform.count
        Require ($null -eq $count -or ((IsWholeNumber $count) -and $count -ge 0 -and $count -le 16)) "$platform.count must be null (keep what exists) or a whole number from 0 to 16."
    }
    $signIn = $Config.windows.startAtSignIn
    Require ($null -eq $signIn -or $signIn -is [bool]) 'windows.startAtSignIn must be true or false.'
    $group = $Config.github.runnerGroup
    if ($null -ne $group) {
        Require ($group.name -is [string] -and $group.name.Trim()) 'github.runnerGroup.name is required.'
        $repositories = $group.repositories
        Require ($null -eq $repositories -or @($repositories | Where-Object { -not ($_ -is [string] -and $_ -match '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$') }).Count -eq 0) 'github.runnerGroup.repositories must be null (all repositories) or a list of owner/repository names.'
    }
    if ($agent -and $null -ne $agent.estimate) {
        Require ("$($agent.estimate.memory)" -match '^\d+(\.\d+)?[bkmg]$') 'buildAgent.estimate.memory must be a Docker memory size such as 8g or 512m.'
    }
    if ($problems.Count) { throw "Invalid runners settings:`n - $($problems -join "`n - ")" }
}

# A JSON whole number. ConvertFrom-Json returns Int32 or Int64; a string, decimal or boolean is not a count.
function IsWholeNumber($Value) { $Value -is [int] -or $Value -is [long] }

# The host's identity in runner names and labels: hostId when set, otherwise the lower-cased computer name (what setup used
# before hostId existed, so an unset hostId changes no name or label).
function Get-RunnerHostId($Config) {
    if ($Config.hostId) { return [string]$Config.hostId }
    $computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
    $id = $computer.ToLowerInvariant()
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') { throw "The computer name $computer cannot be a host ID; set hostId (1-31 lower-case letters, digits or hyphens) in runners.local.json." }
    $id
}

function Read-RunnerConfig([Parameter(Mandatory)] [string] $Root) {
    $config = Get-Content -Raw -LiteralPath (Join-Path $Root 'runners.json') | ConvertFrom-Json
    # A Windows clone the host manager owns has runners.host.json, the host's settings for that clone. It sits between
    # runners.json and runners.local.json (which stays Install-owned). Absent, the result is exactly what it was without it.
    $hostFile = Join-Path $Root 'runners.host.json'
    if (Test-Path -LiteralPath $hostFile) {
        try {
            $hostSettings = Get-Content -Raw -LiteralPath $hostFile | ConvertFrom-Json
            if (-not (IsSettingsObject $hostSettings)) { throw 'it is not a JSON object.' }
            $hostSettings.PSObject.Properties.Remove('generated')
            Merge-Settings $config $hostSettings
        }
        catch { throw "runners.host.json cannot be read: $($_.Exception.Message)" }
    }
    $local = Join-Path $Root 'runners.local.json'
    if (Test-Path -LiteralPath $local) {
        try { Merge-Settings $config (Get-Content -Raw -LiteralPath $local | ConvertFrom-Json) }
        catch { throw "runners.local.json cannot be read: $($_.Exception.Message)" }
    }
    # The Linux image is built on the BuildAgent image, so there is one digest. linux.baseImage in runners.local.json
    # overrides it for the Linux runner alone.
    if (-not $config.linux.baseImage -and $config.buildAgent.image) {
        $config.linux | Add-Member -Force -NotePropertyName baseImage -NotePropertyValue $config.buildAgent.image
    }
    Assert-RunnerConfig $config
    $config
}

# Settings the host owns in a Windows clone (written to runners.host.json by the host manager) and the ones Install owns
# (runners.local.json). One writer per file: neither list may appear in the other's file.
function Get-HostOwnedSettingNames { 'hostId', 'github.labels', 'github.runnerGroup', 'buildAgent', 'lifecycle', 'logs', 'housekeeping' }
function Get-InstallOwnedSettingNames { 'github.url', 'windows.instanceId', 'windows.name', 'windows.labels', 'windows.workFolder' }

# Looks up a dotted setting name. Returns $true and sets $Value when the object has it (a null value counts as present).
function Find-Setting($Object, [string] $Name, [ref] $Value) {
    $current = $Object
    foreach ($part in $Name.Split('.')) {
        if ($current -is [Collections.IDictionary]) {
            if (-not $current.Contains($part)) { return $false }
            $current = $current[$part]
        } elseif ((IsSettingsObject $current) -and $current.PSObject.Properties[$part]) {
            $current = $current.$part
        } else { return $false }
    }
    $Value.Value = $current
    $true
}

# JSON with object keys sorted at every level and no whitespace, so the same settings always hash the same.
function ConvertTo-CanonicalJson($Value) {
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [datetime]) {
        $text = if ($Value -is [datetime]) { $Value.ToString('o') } else { [string]$Value }
        $builder = [Text.StringBuilder]::new('"')
        foreach ($c in $text.ToCharArray()) {
            switch ($c) {
                '"' { [void]$builder.Append('\"') }
                '\' { [void]$builder.Append('\\') }
                default { if ([int]$c -lt 0x20) { [void]$builder.AppendFormat('\u{0:x4}', [int]$c) } else { [void]$builder.Append($c) } }
            }
        }
        return $builder.Append('"').ToString()
    }
    if ($Value -is [ValueType]) { return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Collections.IDictionary]) {
        $pairs = foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) { (ConvertTo-CanonicalJson $key) + ':' + (ConvertTo-CanonicalJson $Value[$key]) }
        return '{' + (@($pairs) -join ',') + '}'
    }
    if ($Value -is [Collections.IEnumerable]) { return '[' + (@(foreach ($item in $Value) { ConvertTo-CanonicalJson $item }) -join ',') + ']' }
    if (IsSettingsObject $Value) {
        $pairs = foreach ($property in @($Value.PSObject.Properties | Sort-Object Name -CaseSensitive)) { (ConvertTo-CanonicalJson $property.Name) + ':' + (ConvertTo-CanonicalJson $property.Value) }
        return '{' + (@($pairs) -join ',') + '}'
    }
    ConvertTo-CanonicalJson ([string]$Value)
}

# A JSON object as ConvertFrom-Json returns it. Not -is [pscustomobject]: that is [psobject], which any wrapped value is.
function IsSettingsObject($Value) { $null -ne $Value -and $Value.PSObject.BaseObject -is [Management.Automation.PSCustomObject] }

# SHA-256 (lower-case hex) of the settings' canonical JSON, without their generated block.
function Get-HostSettingsHash($Settings) {
    $copy = [ordered]@{}
    foreach ($property in $Settings.PSObject.Properties) { if ($property.Name -ne 'generated') { $copy[$property.Name] = $property.Value } }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-CanonicalJson $copy))) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# The runners.host.json content for one Windows slot: the host-owned settings resolved on the host, hostId resolved, and a
# generated block whose hash lets Test-HostSettingsDrift see a hand edit. Install-owned settings are never in it.
function New-HostSettings($Config, $Slot) {
    if (-not $Slot -or $Slot.Platform -ne 'windows') { throw 'New-HostSettings builds runners.host.json for a Windows slot only.' }
    $settings = [ordered]@{}
    foreach ($name in Get-HostOwnedSettingNames) {
        $value = $null
        if ($name -eq 'hostId') { $value = Get-RunnerHostId $Config }
        elseif (-not (Find-Setting $Config $name ([ref]$value))) { continue }
        $parts = $name.Split('.')
        $target = $settings
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $target.Contains($parts[$i])) { $target[$parts[$i]] = [ordered]@{} }
            $target = $target[$parts[$i]]
        }
        $target[$parts[-1]] = $value
    }
    # One round trip copies every value, so the result shares nothing with $Config and hashes as it will be read back.
    $result = ConvertTo-Json -InputObject $settings -Depth 32 | ConvertFrom-Json
    $result | Add-Member -NotePropertyName generated -NotePropertyValue ([pscustomobject][ordered]@{ by = 'Manage-RunnerHost'; hash = (Get-HostSettingsHash $result) })
    $result
}

# Writes $Text to $Path through a temporary file in the same directory, flushed to disk, then moved over the target, so a
# reader sees the old file or the new one, never part of one.
function Write-FileAtomic([string] $Path, [string] $Text) {
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temp = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream = [IO.File]::Create($temp)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # [NullString]: PowerShell passes `$null to a string parameter as an empty path, which Replace refuses.
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) } else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

# What differs between a clone's runners.host.json and what the host manager wrote, and which host-owned settings the
# clone's runners.local.json overrides. Each finding is { Kind = unreadable | edited | local-override; File; Setting;
# Message }. A clone without runners.host.json is not managed and has no findings.
function Test-HostSettingsDrift([Parameter(Mandatory)] [string] $Clone) {
    $path = Join-Path $Clone 'runners.host.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    try { $settings = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
    catch { $settings = $null }
    if (-not (IsSettingsObject $settings)) {
        [pscustomobject]@{ Kind = 'unreadable'; File = $path; Setting = $null; Message = "$path cannot be read as a settings object." }
    } elseif (-not (IsSettingsObject $settings.generated) -or $settings.generated.hash -ne (Get-HostSettingsHash $settings)) {
        [pscustomobject]@{ Kind = 'edited'; File = $path; Setting = $null; Message = "$path was changed after the host manager wrote it." }
    }
    $localPath = Join-Path $Clone 'runners.local.json'
    if (Test-Path -LiteralPath $localPath) {
        try { $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json }
        catch { return [pscustomobject]@{ Kind = 'unreadable'; File = $localPath; Setting = $null; Message = "$localPath cannot be read." } }
        foreach ($name in Get-HostOwnedSettingNames) {
            $ignored = $null
            if (Find-Setting $local $name ([ref]$ignored)) {
                [pscustomobject]@{ Kind = 'local-override'; File = $localPath; Setting = $name; Message = "$localPath sets the host-owned setting $name; runners.host.json is where the host sets it." }
            }
        }
    }
}

# The generated.hash a clone's runners.host.json records: what the host manager last wrote there. $null when the file is
# absent, unreadable or has no generated block.
function Get-HostSettingsRecord([Parameter(Mandatory)] [string] $Clone) {
    $path = Join-Path $Clone 'runners.host.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $settings = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { return $null }
    if (-not (IsSettingsObject $settings) -or -not (IsSettingsObject $settings.generated)) { return $null }
    $settings.generated.hash
}

# Writes a clone's runners.host.json, and only that file. A file that is unreadable or was edited by hand is kept unless
# -Force: the edit may be someone's fix, and overwriting it would lose it silently.
function Write-HostSettings([Parameter(Mandatory)] [string] $Clone, [Parameter(Mandatory)] $Settings, [switch] $Force) {
    $path = Join-Path $Clone 'runners.host.json'
    if (-not $Force) {
        $blocking = @(Test-HostSettingsDrift -Clone $Clone | Where-Object { $_.File -eq $path -and $_.Kind -in 'unreadable', 'edited' })
        if ($blocking.Count) { throw "$($blocking[0].Message) It was not overwritten; check the change, then rerun with -Force to replace it." }
    }
    Write-FileAtomic $path (ConvertTo-Json -InputObject $Settings -Depth 32)
}

# Slot numbers for one platform. Live slots (provisioning or active in the inventory) are kept lowest first, so a lower
# count retires the highest numbers. A new slot takes the next number above the highest ever recorded: numbers are never
# reused. A null count keeps exactly the live slots.
function Get-SlotNumbers([string] $Platform, $Count, $Inventory) {
    # A slot without a trailing number (windows-legacy, the pre-pool single-clone install) is not numbered and never counts.
    $recorded = @($Inventory.slots | Where-Object { $_ -and $_.platform -eq $Platform -and "$($_.slotId)" -match '\d+$' })
    $numberOf = { param($slot) [int]($slot.slotId -replace '^\D+', '') }
    $live = @($recorded | Where-Object { $_.state -in 'provisioning', 'active' } | ForEach-Object { & $numberOf $_ } | Sort-Object)
    if ($null -eq $Count) { return $live }
    $numbers = [Collections.Generic.List[int]]::new()
    foreach ($number in $live) { if ($numbers.Count -lt $Count) { $numbers.Add($number) } }
    $next = 1 + [int](@($recorded | ForEach-Object { & $numberOf $_ }) + 0 | Measure-Object -Maximum).Maximum
    while ($numbers.Count -lt $Count) {
        if ($next -gt 99) { throw "No $Platform slot number is left: numbers are never reused and 99 is the highest." }
        $numbers.Add($next); $next++
    }
    $numbers.ToArray()
}

function Get-InventorySlot($Inventory, [string] $SlotId) {
    @($Inventory.slots | Where-Object { $_ -and $_.slotId -eq $SlotId }) | Select-Object -First 1
}

# Every name a Linux slot uses. Slot 01 marked legacy in the inventory keeps the pre-pool runner name, directory, volumes
# and network, so its registration and caches survive; its containers still get the -01 names.
function Get-LinuxSlots($Config, $Inventory, $Count = $Config.linux.count) {
    $hostId = Get-RunnerHostId $Config
    $docker = $Config.linux.docker
    $sidecar = $docker -and $docker.mode -eq 'sidecar'
    $labels = @(@($Config.github.labels) + @($Config.linux.labels) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($number in @(Get-SlotNumbers 'linux' $Count $Inventory)) {
        $nn = '{0:D2}' -f $number
        $slotId = "linux-$nn"
        $record = Get-InventorySlot $Inventory $slotId
        $legacy = [bool]($record -and $record.legacy)
        if ($legacy -and $number -ne 1) { throw "Inventory marks $slotId legacy; only slot 01 can be the pre-pool runner." }
        $suffix = if ($legacy) { '' } else { "-$nn" }
        [pscustomobject][ordered]@{
            Platform = 'linux'
            Number = $number
            SlotId = $slotId
            New = -not ($record -and $record.state -in 'provisioning', 'active')
            Legacy = $legacy
            RunnerName = $(if ($legacy) { $Config.linux.name } else { "$($Config.linux.name).$hostId.$nn" })
            Directory = "$($Config.linux.directory)$suffix"
            Container = "$($Config.linux.container)-$nn"
            Services = @("linux-$nn") + @(if ($sidecar) { "linux-$nn-docker" })
            DockerContainer = $(if ($sidecar) { "$($docker.container)-$nn" })
            Network = $(if ($sidecar) { "$($docker.network)$suffix" })
            Volumes = [pscustomobject][ordered]@{
                Cache = "$($Config.linux.cacheVolume)$suffix"
                DockerData = "$($docker.dataVolume)$suffix"
                DockerCerts = "$($docker.certsVolume)$suffix"
                Work = "$($docker.workVolume)$suffix"
                Dind = "$($docker.dindVolume)$suffix"
                Runtimes = "$($Config.linux.container)-runtimes$suffix"
            }
            Labels = $labels
        }
    }
}

# Every name a Windows slot uses. The host and pair labels are the ones setup has always given (pair: the first two).
function Get-WindowsSlots($Config, $Inventory, $Count = $Config.windows.count, [string] $InstallRoot) {
    $hostId = Get-RunnerHostId $Config
    if (-not $InstallRoot -and $env:LOCALAPPDATA) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'SubZeroDev\Runners' }
    foreach ($number in @(Get-SlotNumbers 'windows' $Count $Inventory)) {
        $id = 'win{0:D2}' -f $number
        $record = Get-InventorySlot $Inventory $id
        $hostLabels = @("subzerodev-host-$hostId") + @(if ($number -le 2) { "subzerodev-pair-$hostId" })
        [pscustomobject][ordered]@{
            Platform = 'windows'
            Number = $number
            SlotId = $id
            InstanceId = $id
            New = -not ($record -and $record.state -in 'provisioning', 'active')
            RunnerName = "subzerodev.runner.windows.$hostId.$id"
            InstallPath = $(if ($InstallRoot) { Join-Path $InstallRoot $id })
            HostLabels = $hostLabels
            Labels = @(@($Config.github.labels) + @($Config.windows.labels) + $hostLabels | Where-Object { $_ } | Select-Object -Unique)
        }
    }
}

# Canonical form of a path: full, no trailing separator. Used for every "is this inside that" decision.
function Get-CanonicalPath([string] $Path) {
    [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\', '/')
}

# True when $Path is $Directory or lies below it. Compares whole path segments, so C:\runner2\x is not inside C:\runner.
function Test-PathUnder([string] $Path, [string] $Directory) {
    if (-not $Path -or -not $Directory) { return $false }
    $candidate = Get-CanonicalPath $Path
    $parent = Get-CanonicalPath $Directory
    $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Runs a native command and throws, with its output, when it exits non-zero. Returns the output lines.
function Invoke-Native([string] $FilePath, [string[]] $Arguments = @(), [string] $Description = $FilePath, [int[]] $AllowedExitCodes = @(0)) {
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -notin $AllowedExitCodes) {
        throw "$Description failed with exit code $LASTEXITCODE.$(if ($output) { "`n$($output -join "`n")" })"
    }
    $output
}
