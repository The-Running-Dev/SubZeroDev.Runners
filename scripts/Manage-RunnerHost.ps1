#Requires -Version 7.2
# The host manager: what this host runs, what it owns, and what would change.
#
#   Init    writes hostId and the slot counts (default 2 Linux, 2 Windows) into this checkout's runners.local.json.
#   Adopt   builds the first host inventory from what can be proven: a registration directory whose .runner agentId is the
#           ID GitHub reports under that name, and the containers this repository's scripts create for it. It writes
#           only the inventory.
#   Plan    compares the settings with the inventory, Docker and GitHub and prints the changes Apply would make, with a
#           planHash. Exit 0: no changes; 3: changes; 1: the state cannot be read.
#   Status  prints each slot as GitHub, Docker and the files on disk report it, with drift and any unfinished operation.
#
# Plan and Status take no lock and change nothing. Init and Adopt take the host lock.
param(
    [Parameter(Mandatory)] [ValidateSet('Init', 'Adopt', 'Plan', 'Status')] [string] $Action,
    [ValidateRange(0, 16)] [Nullable[int]] $LinuxCount,
    [ValidateRange(0, 16)] [Nullable[int]] $WindowsCount,
    [string] $HostId,
    # Adopt over an unreadable inventory. The old file is kept beside it as inventory.json.unreadable-<utc>.
    [switch] $ReplaceUnreadable,
    [switch] $Json,
    # Where the Windows instance clones live (winNN). The setup default.
    [string] $InstallRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SubZeroDev\Runners' })
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"

$PlanSchema = 'subzerodev.runners.host-plan'
$StatusSchema = 'subzerodev.runners.host-status'

if ($Config.windows.instanceId) {
    [Console]::Error.WriteLine("Manage-RunnerHost.ps1 runs in the host's own checkout, not in the instance clone $Root (windows.instanceId $($Config.windows.instanceId)).")
    exit 1
}
if ($HostId -and $HostId -cnotmatch '^[a-z0-9][a-z0-9-]{0,30}$') {
    [Console]::Error.WriteLine("-HostId '$HostId' is not a host ID: 1-31 lower-case letters, digits or hyphens, starting with a letter or digit.")
    exit 1
}

# --- Reading GitHub, Docker and git. Every reader returns a result with State; none throws for an answer it did not expect.

# Every runner of a scope: { State = known | unknown; Runners; Reason }.
function Get-ScopeRunners([string] $Scope) {
    try {
        $lines = Invoke-GhApi @("$Scope/actions/runners", '--paginate', '--jq', '.runners[] | tojson') "Listing runners of $Scope"
        $runners = @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        [pscustomobject]@{ State = 'known'; Runners = $runners; Reason = $null }
    } catch { [pscustomobject]@{ State = 'unknown'; Runners = @(); Reason = $_.Exception.Message } }
}

# docker container inspect: { State = present | absent | unknown; Id; Name; Image; Labels; Reason }.
function Get-ContainerRecord([string] $Name) {
    $inspect = Invoke-Docker @('container', 'inspect', $Name)
    if ($null -eq $inspect.ExitCode) { return [pscustomobject]@{ State = 'unknown'; Reason = "docker could not be run: $($inspect.Output)" } }
    if ($inspect.ExitCode -ne 0) {
        if ($inspect.Output -match 'No such (container|object)') { return [pscustomobject]@{ State = 'absent'; Reason = $null } }
        return [pscustomobject]@{ State = 'unknown'; Reason = "docker container inspect $Name exited $($inspect.ExitCode): $($inspect.Output)" }
    }
    try { $item = @($inspect.Output | ConvertFrom-Json)[0] } catch { $item = $null }
    if (-not $item -or -not $item.Id) { return [pscustomobject]@{ State = 'unknown'; Reason = "docker container inspect $Name gave no container ID." } }
    $labels = [ordered]@{}
    if ($item.Config -and $item.Config.Labels) { foreach ($p in $item.Config.Labels.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value } }
    [pscustomobject]@{ State = 'present'; Id = [string]$item.Id; Name = ([string]$item.Name).TrimStart('/'); Image = [string]$item.Image; Labels = $labels; Reason = $null }
}

# The ID of a local image: { State = present | absent | unknown; Id; Reason }.
function Get-ImageId([string] $Image) {
    $inspect = Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $Image)
    if ($null -eq $inspect.ExitCode) { return [pscustomobject]@{ State = 'unknown'; Reason = "docker could not be run: $($inspect.Output)" } }
    if ($inspect.ExitCode -eq 0 -and $inspect.Output -match '^sha256:[0-9a-f]{64}$') { return [pscustomobject]@{ State = 'present'; Id = $inspect.Output; Reason = $null } }
    if ($inspect.ExitCode -ne 0 -and $inspect.Output -match 'No such (image|object)') { return [pscustomobject]@{ State = 'absent'; Reason = $null } }
    [pscustomobject]@{ State = 'unknown'; Reason = "docker image inspect $Image exited $($inspect.ExitCode): $($inspect.Output)" }
}

# HEAD of a git checkout, or $null when it cannot be read.
function Get-GitCommit([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { $output = & git -C $Path rev-parse HEAD 2>$null } catch { return $null }
    if ($LASTEXITCODE -eq 0 -and "$output" -match '^[0-9a-f]{40}$') { "$output" }
}

function Get-InventoryScope($Inventory) {
    if ($Inventory -and $Inventory.github -and $Inventory.github.scope) { return [string]$Inventory.github.scope }
    if ($Config.github.url) { Get-RunnerScope $Config.github.url }
}

# The runner group check (org scope only: a repository's runners have no groups). Result: { state = ok | drift | blocked |
# unknown | not-applicable; group; findings[] }. A group that allows public repositories blocks registration.
function Test-RunnerGroup([string] $Scope, [int64[]] $RunnerIds) {
    $expected = $Config.github.runnerGroup
    $result = [ordered]@{ state = 'ok'; group = $expected.name; findings = [Collections.Generic.List[object]]::new() }
    $add = { param($severity, $message) $result.findings.Add([ordered]@{ severity = $severity; subject = 'runner-group'; message = $message }) }
    if (-not $Scope) { $result.state = 'unknown'; & $add 'unknown' 'No GitHub scope is known (no inventory scope and no github.url).'; return $result }
    if ($Scope -notlike 'orgs/*') { $result.state = 'not-applicable'; return $result }
    try {
        $groups = @(Invoke-GhApi @("$Scope/actions/runner-groups", '--paginate', '--jq', '.runner_groups[] | tojson') "Listing runner groups of $Scope" |
            Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    } catch { $result.state = 'unknown'; & $add 'unknown' $_.Exception.Message; return $result }
    $group = $groups | Where-Object { $_.name -ieq $expected.name } | Select-Object -First 1
    if (-not $group) { $result.state = 'drift'; & $add 'drift' "The runner group '$($expected.name)' does not exist in $Scope."; return $result }
    if ($group.allows_public_repositories -ne $false) {
        $result.state = 'blocked'
        & $add 'blocked' "The runner group '$($group.name)' allows public repositories; no runner is registered into it until that is turned off."
    }
    $wanted = @($expected.repositories | Where-Object { $_ })
    $visibility = if ($wanted.Count) { 'selected' } else { 'all' }
    if ($group.visibility -ne $visibility) {
        if ($result.state -eq 'ok') { $result.state = 'drift' }
        & $add 'drift' "The runner group '$($group.name)' has visibility '$($group.visibility)'; the settings expect '$visibility'."
    }
    try {
        if ($wanted.Count -and $group.visibility -eq 'selected') {
            $repositories = @(Invoke-GhApi @("$Scope/actions/runner-groups/$($group.id)/repositories", '--paginate', '--jq', '.repositories[] | tojson') "Listing the repositories of runner group $($group.id)" |
                Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
            $has = { param($name) [bool]($repositories | Where-Object { $_.name -ieq $name -or $_.full_name -ieq $name }) }
            $missing = @($wanted | Where-Object { -not (& $has $_) })
            $extra = @($repositories | Where-Object { $r = $_; -not ($wanted | Where-Object { $r.name -ieq $_ -or $r.full_name -ieq $_ }) } | ForEach-Object { $_.full_name })
            if ($missing.Count -or $extra.Count) {
                if ($result.state -eq 'ok') { $result.state = 'drift' }
                & $add 'drift' "The repositories of runner group '$($group.name)' differ from the settings (missing: $($missing -join ', '); not in the settings: $($extra -join ', '))."
            }
        }
        if ($RunnerIds.Count) {
            $members = @(Invoke-GhApi @("$Scope/actions/runner-groups/$($group.id)/runners", '--paginate', '--jq', '.runners[] | .id') "Listing the runners of runner group $($group.id)" | Where-Object { $_ } | ForEach-Object { [int64]$_ })
            $outside = @($RunnerIds | Where-Object { $_ -notin $members })
            if ($outside.Count) {
                if ($result.state -eq 'ok') { $result.state = 'drift' }
                & $add 'drift' "Runner IDs $($outside -join ', ') are not in the runner group '$($group.name)'."
            }
        }
    } catch {
        if ($result.state -eq 'ok') { $result.state = 'unknown' }
        & $add 'unknown' $_.Exception.Message
    }
    $result
}

# --- Drift of one recorded slot. Each item: { kind; state = drift | unknown; message }.

function Get-SlotDrift($Slot) {
    $drift = [Collections.Generic.List[object]]::new()
    $add = { param($kind, $state, $message) $drift.Add([ordered]@{ kind = $kind; state = $state; message = $message }) }
    # The pre-pool single-clone install (windows-legacy) is this checkout itself; it is only ever retired, never updated.
    if ($Slot.state -notin 'provisioning', 'active' -or $Slot.slotId -eq 'windows-legacy') { return }
    if ($Slot.platform -eq 'linux') {
        $runner = @($Slot.containers | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
        if ($runner) {
            $container = Get-ContainerRecord $runner.name
            $image = Get-ImageId $Config.linux.image
            if ($container.State -eq 'unknown' -or $image.State -eq 'unknown') {
                & $add 'image' 'unknown' ((@($container.Reason, $image.Reason) | Where-Object { $_ }) -join ' ')
            } elseif ($container.State -eq 'present' -and $container.Id -ne $runner.id) {
                & $add 'container' 'drift' "The container named $($runner.name) is $($container.Id), not the recorded $($runner.id)."
            } elseif ($container.State -eq 'present' -and $image.State -eq 'present' -and $container.Image -ne $image.Id) {
                & $add 'image' 'drift' "The container $($runner.name) runs image $($container.Image); $($Config.linux.image) is now $($image.Id)."
            } elseif ($image.State -eq 'absent') {
                & $add 'image' 'drift' "The image $($Config.linux.image) is not built."
            }
        }
        # The compose config and file hashes start with compose (S4): no slot is composed before it.
    } elseif ($Slot.installPath) {
        $clone = [string]$Slot.installPath
        if (-not (Test-Path -LiteralPath $clone)) { & $add 'clone' 'drift' "The clone $clone does not exist."; return $drift.ToArray() }
        $wanted = (New-HostSettings $Config ([pscustomobject]@{ Platform = 'windows'; SlotId = $Slot.slotId })).generated.hash
        $written = Get-HostSettingsRecord -Clone $clone
        if ($written -ne $wanted) { & $add 'settings' 'drift' "The clone's generated host settings $(if ($written) { "records $written" } else { 'is missing or has no generated hash' }); the settings now give $wanted." }
        foreach ($finding in @(Test-HostSettingsDrift -Clone $clone)) { & $add "settings-$($finding.Kind)" 'drift' $finding.Message }
        $head = Get-GitCommit $Root
        $commit = Get-GitCommit $clone
        if (-not $head -or -not $commit) { & $add 'commit' 'unknown' "The commit of $(if (-not $head) { $Root } else { $clone }) cannot be read." }
        elseif ($head -ne $commit) { & $add 'commit' 'drift' "The clone is at $commit; this checkout is at $head." }
    }
    $drift.ToArray()
}

# --- Plan.

function Get-HostPlan {
    $inventory = Read-HostInventory
    $operation = Read-HostOperation
    $plan = [ordered]@{
        schema = $PlanSchema; version = 1; hostId = (Get-RunnerHostId $Config)
        inventory = [ordered]@{ state = $inventory.State; reason = $inventory.Reason }
        operation = [ordered]@{ state = $operation.State; reason = $operation.Reason }
        changes = [Collections.Generic.List[object]]::new(); findings = [Collections.Generic.List[object]]::new(); planHash = $null
    }
    if ($inventory.State -eq 'unreadable' -or $operation.State -eq 'unreadable') { return $plan }
    $finding = { param($severity, $subject, $message) $plan.findings.Add([ordered]@{ severity = $severity; subject = $subject; message = $message }) }
    if ($inventory.State -eq 'absent') {
        $plan.changes.Add([ordered]@{ kind = 'adopt'; message = 'There is no host inventory. Run -Action Adopt to record what this host runs.' })
    } else {
        $inv = $inventory.Value
        if ($operation.State -eq 'readable') {
            $op = $operation.Value
            $plan.changes.Add([ordered]@{ kind = 'finish-operation'; operationId = $op.id; operation = $op.kind; slotId = $op.slotId })
        }
        $live = @($inv.slots | Where-Object { $_ -and $_.state -in 'provisioning', 'active' })
        foreach ($side in @(
                @{ Platform = 'linux'; Count = $Config.linux.count; Slots = { Get-LinuxSlots $Config $inv } }
                @{ Platform = 'windows'; Count = $Config.windows.count; Slots = { Get-WindowsSlots $Config $inv -InstallRoot $InstallRoot } })) {
            if ($null -eq $side.Count) { continue }
            $wanted = @(& $side.Slots)
            foreach ($slot in $wanted | Where-Object New) {
                $plan.changes.Add([ordered]@{ kind = 'add'; platform = $side.Platform; slotId = $slot.SlotId; runnerName = $slot.RunnerName })
            }
            $keep = @($wanted | ForEach-Object SlotId)
            foreach ($slot in @($live | Where-Object { $_.platform -eq $side.Platform -and $_.slotId -notin $keep } | Sort-Object slotId -Descending)) {
                $change = [ordered]@{ kind = 'retire'; platform = $side.Platform; slotId = $slot.slotId; runnerName = $slot.runnerName; runnerId = $slot.runnerId; requires = '-Retire' }
                if ($slot.slotId -eq 'windows-legacy') { $change.after = 'win01 online' }
                $plan.changes.Add($change)
            }
            foreach ($slot in $wanted | Where-Object { -not $_.New }) {
                $record = Get-InventorySlot $inv $slot.SlotId
                if ($slot.Platform -eq 'linux' -and $slot.Legacy) {
                    $runner = @($record.containers | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
                    if (-not $runner -or $runner.name -ne $slot.Container) {
                        $plan.changes.Add([ordered]@{ kind = 'migrate-legacy-linux'; platform = 'linux'; slotId = $slot.SlotId; runnerId = $record.runnerId; from = $runner.name; to = $slot.Container })
                        continue
                    }
                }
                $drift = @(Get-SlotDrift $record)
                $reasons = @($drift | Where-Object { $_.state -eq 'drift' } | ForEach-Object kind | Select-Object -Unique)
                if ($reasons.Count) { $plan.changes.Add([ordered]@{ kind = 'update'; platform = $slot.Platform; slotId = $slot.SlotId; reasons = $reasons }) }
                foreach ($item in $drift | Where-Object { $_.state -eq 'unknown' }) { & $finding 'unknown' $slot.SlotId $item.message }
            }
        }
        $scope = Get-InventoryScope $inv
        $group = Test-RunnerGroup $scope @($live | Where-Object { $_.runnerId } | ForEach-Object { [int64]$_.runnerId })
        foreach ($item in $group.findings) { $plan.findings.Add($item) }
        foreach ($item in @(Get-UnownedRunners $inv $scope)) { $plan.findings.Add($item) }
    }
    $plan.planHash = Get-PlanHash $plan.changes
    $plan
}

# GitHub runners that carry this host's names but are not recorded: the pre-pool names and any name with .<hostId>.
# They are reported for the owner and never touched.
function Get-UnownedRunners($Inventory, [string] $Scope) {
    if (-not $Scope) { return }
    $listed = Get-ScopeRunners $Scope
    if ($listed.State -ne 'known') { return [ordered]@{ severity = 'unknown'; subject = 'unowned'; message = $listed.Reason } }
    $hostId = Get-RunnerHostId $Config
    $recorded = @($Inventory.slots | Where-Object { $_.runnerId } | ForEach-Object { [int64]$_.runnerId })
    foreach ($runner in $listed.Runners) {
        $ours = $runner.name -ieq $Config.linux.name -or $runner.name -ieq $Config.windows.name -or $runner.name -like "*.$hostId.*"
        if ($ours -and [int64]$runner.id -notin $recorded) {
            [ordered]@{ severity = 'unowned'; subject = 'unowned'; runnerId = [int64]$runner.id; runnerName = $runner.name; message = "GitHub runner $($runner.name) (id $($runner.id)) carries this host's names but no registration here proves it. It is never changed; remove it at GitHub if it is not needed." }
        }
    }
}

function Get-PlanHash($Changes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-CanonicalJson @($Changes)))) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# --- Status.

function Get-HostStatus {
    $inventory = Read-HostInventory
    $operation = Read-HostOperation
    $status = [ordered]@{
        schema = $StatusSchema; version = 1; hostId = (Get-RunnerHostId $Config)
        inventory = [ordered]@{ state = $inventory.State; generation = $null; reason = $inventory.Reason }
        operation = [ordered]@{ state = $operation.State; reason = $operation.Reason }
        slots = [Collections.Generic.List[object]]::new(); runnerGroup = $null; unowned = @()
    }
    if ($operation.State -eq 'readable') {
        $op = $operation.Value
        $pending = @($op.steps | Where-Object { $_.state -ne 'done' }) | Select-Object -First 1
        foreach ($pair in @{ id = $op.id; kind = $op.kind; slotId = $op.slotId; startedUtc = $op.startedUtc; pendingStep = $pending.name }.GetEnumerator()) { $status.operation[$pair.Key] = $pair.Value }
    }
    if ($inventory.State -ne 'readable') { return $status }
    $inv = $inventory.Value
    $status.inventory.generation = $inv.generation
    $scope = Get-InventoryScope $inv
    $listings = @{}
    foreach ($slot in @($inv.slots | Where-Object { $_ })) {
        $slotScope = if ($slot.scope) { [string]$slot.scope } else { $scope }
        if ($slotScope -and -not $listings.ContainsKey($slotScope)) { $listings[$slotScope] = Get-ScopeRunners $slotScope }
        $listing = if ($slotScope) { $listings[$slotScope] }
        # Offline is what GitHub reports. Why a runner is offline is not something this reads, so it is not reported.
        $github = [ordered]@{ status = 'unknown'; busy = $null }
        if ($listing -and $listing.State -eq 'known' -and $slot.runnerId) {
            $match = $listing.Runners | Where-Object { [int64]$_.id -eq [int64]$slot.runnerId } | Select-Object -First 1
            if ($match) { $github.status = [string]$match.status; $github.busy = [bool]$match.busy } else { $github.status = 'absent' }
        }
        $held = if ($slot.registrationDirectory) { Test-Path -LiteralPath (Join-Path $slot.registrationDirectory 'maintenance.json') } else { $null }
        $status.slots.Add([ordered]@{
                slotId = $slot.slotId; platform = $slot.platform; state = $slot.state; runnerName = $slot.runnerName; runnerId = $slot.runnerId
                github = $github; held = $held; drift = @(Get-SlotDrift $slot)
            })
    }
    $live = @($inv.slots | Where-Object { $_ -and $_.state -in 'provisioning', 'active' -and $_.runnerId })
    $status.runnerGroup = Test-RunnerGroup $scope @($live | ForEach-Object { [int64]$_.runnerId })
    $status.unowned = @(Get-UnownedRunners $inv $scope)
    $status
}

# --- Init.

function Invoke-Init {
    Use-HostLock -Kind 'Manage-RunnerHost Init' -ScriptBlock {
        $settings = [pscustomobject]@{}
        if (Test-Path -LiteralPath $LocalConfig) {
            try { $settings = Get-Content -Raw -LiteralPath $LocalConfig | ConvertFrom-Json } catch { throw "$LocalConfig cannot be read ($($_.Exception.Message)); it was not changed." }
            if (-not (IsSettingsObject $settings)) { throw "$LocalConfig is not a JSON object; it was not changed." }
        }
        $set = {
            param($object, [string] $name, $value)
            if ($object.PSObject.Properties[$name]) { $object.$name = $value } else { $object | Add-Member -NotePropertyName $name -NotePropertyValue $value }
        }
        $existing = { param([string] $side) $section = $settings.$side; if ((IsSettingsObject $section) -and $section.PSObject.Properties['count'] -and $null -ne $section.PSObject.Properties['count'].Value) { $section.PSObject.Properties['count'].Value } }
        & $set $settings 'hostId' $(if ($HostId) { $HostId } else { Get-RunnerHostId $Config })
        foreach ($side in @(@{ Name = 'linux'; Value = $LinuxCount }, @{ Name = 'windows'; Value = $WindowsCount })) {
            if (-not (IsSettingsObject $settings.($side.Name))) { & $set $settings $side.Name ([pscustomobject]@{}) }
            $count = if ($null -ne $side.Value) { $side.Value } elseif ($null -ne (& $existing $side.Name)) { & $existing $side.Name } else { 2 }
            & $set $settings.($side.Name) 'count' ([int]$count)
        }
        Write-FileAtomic $LocalConfig ((ConvertTo-Json -InputObject $settings -Depth 32) + "`n")
        $written = Read-RunnerConfig -Root $Root
        "Wrote $LocalConfig`: hostId $($written.hostId), linux.count $($written.linux.count), windows.count $($written.windows.count). Next: -Action Adopt, then -Action Plan."
    }
}

# --- Adopt.

# A registration directory proven against GitHub: its .runner agentId is the ID GitHub reports under its agentName.
# { State = proven | unproven | none | unknown; Registration; Scope; Runner; Reason }.
function Test-Registration([string] $Directory, [hashtable] $Listings) {
    $registration = $null
    try { $registration = Get-LocalRegistration $Directory } catch { return [pscustomobject]@{ State = 'unproven'; Reason = "$Directory\.runner cannot be read." } }
    if (-not $registration) { return [pscustomobject]@{ State = 'none' } }
    if (-not $registration.agentId -or -not $registration.agentName -or -not $registration.gitHubUrl) {
        return [pscustomobject]@{ State = 'unproven'; Registration = $registration; Reason = "$Directory\.runner has no agentId, agentName or gitHubUrl." }
    }
    $scope = Get-RunnerScope $registration.gitHubUrl
    if (-not $Listings.ContainsKey($scope)) { $Listings[$scope] = Get-ScopeRunners $scope }
    $listing = $Listings[$scope]
    if ($listing.State -ne 'known') { return [pscustomobject]@{ State = 'unknown'; Reason = $listing.Reason } }
    $runner = $listing.Runners | Where-Object { $_.name -ieq $registration.agentName } | Select-Object -First 1
    if (-not $runner) { return [pscustomobject]@{ State = 'unproven'; Registration = $registration; Scope = $scope; Reason = "GitHub has no runner named $($registration.agentName) in $scope." } }
    if ([int64]$runner.id -ne [int64]$registration.agentId) {
        return [pscustomobject]@{ State = 'unproven'; Registration = $registration; Scope = $scope; Reason = "$Directory\.runner records agentId $($registration.agentId); GitHub reports $($registration.agentName) as id $($runner.id)." }
    }
    [pscustomobject]@{ State = 'proven'; Registration = $registration; Scope = $scope; Runner = $runner }
}

function Get-ContainerEntry([string] $Role, [string] $Name) {
    $record = Get-ContainerRecord $Name
    if ($record.State -eq 'unknown') { throw "Adopt stopped, nothing written: whether the container $Name exists is unknown ($($record.Reason))." }
    if ($record.State -eq 'present') { [ordered]@{ role = $Role; id = $record.Id; name = $record.Name; image = $record.Image; labels = $record.Labels } }
}

function Invoke-Adopt {
    Use-HostLock -Kind 'Manage-RunnerHost Adopt' -ScriptBlock {
        $inventory = Read-HostInventory
        if ($inventory.State -eq 'readable') { throw "Adopt refused: the host inventory $($inventory.Path) exists. Adopt builds the first inventory only; use -Action Plan to see what differs." }
        if ($inventory.State -eq 'unreadable' -and -not $ReplaceUnreadable) {
            throw "Adopt refused: the host inventory $($inventory.Path) cannot be read because $($inventory.Reason). Restore it, or rerun with -ReplaceUnreadable to rebuild it (the old file is kept)."
        }
        $hostId = Get-RunnerHostId $Config
        $listings = @{}
        $slots = [Collections.Generic.List[object]]::new()
        $unowned = [Collections.Generic.List[object]]::new()
        $now = [DateTime]::UtcNow.ToString('o')
        $consider = {
            param([string] $SlotId, [string] $Platform, [string] $Directory, [scriptblock] $Extra)
            $proof = Test-Registration $Directory $listings
            switch ($proof.State) {
                'none' { return }
                'unknown' { throw "Adopt stopped, nothing written: GitHub could not be read to prove $Directory ($($proof.Reason))." }
                'unproven' { $unowned.Add([ordered]@{ directory = $Directory; runnerName = $proof.Registration.agentName; reason = $proof.Reason }); return }
            }
            $slot = [ordered]@{
                slotId = $SlotId; platform = $Platform; state = 'active'; legacy = $false
                runnerName = [string]$proof.Runner.name; runnerId = [int64]$proof.Runner.id; scope = $proof.Scope
                registrationDirectory = (Get-CanonicalPath $Directory); adoptedUtc = $now
            }
            if ($Extra) { & $Extra $slot $proof }
            $slots.Add($slot)
        }

        # Linux: the pre-pool runner (linux/runner) is slot 01, legacy; linux/runner-NN are slots NN.
        $linuxBase = Join-Path $Root $Config.linux.directory
        & $consider 'linux-01' 'linux' $linuxBase {
            param($slot)
            $slot.legacy = $true
            $slot.containers = @(@(
                    Get-ContainerEntry 'runner' $Config.linux.container
                    if ($DockerSidecar) { Get-ContainerEntry 'docker' $DockerSidecar }) | Where-Object { $_ })
        }
        $parent = Split-Path $linuxBase -Parent
        $leaf = Split-Path $linuxBase -Leaf
        if (Test-Path -LiteralPath $parent) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $parent -Directory | Where-Object { $_.Name -match "^$([regex]::Escape($leaf))-(\d{2})$" } | Sort-Object Name)) {
                $nn = $directory.Name.Substring($leaf.Length + 1)
                if ($nn -eq '01' -and ($slots | Where-Object { $_.slotId -eq 'linux-01' })) {
                    $unowned.Add([ordered]@{ directory = $directory.FullName; reason = 'Slot 01 is already the pre-pool runner (linux/runner).' }); continue
                }
                & $consider "linux-$nn" 'linux' $directory.FullName {
                    param($slot)
                    $slot.containers = @(@(
                            Get-ContainerEntry 'runner' "$($Config.linux.container)-$nn"
                            if ($DockerSidecar) { Get-ContainerEntry 'docker' "$DockerSidecar-$nn" }) | Where-Object { $_ })
                }
            }
        }

        # Windows: setup's instance clones (InstallRoot\winNN), and this checkout's own single-clone install.
        $windowsExtra = {
            param($slot, $proof)
            $clone = Split-Path $slot.registrationDirectory -Parent
            $slot.installPath = $clone
            $slot.workPath = Resolve-RunnerWorkFolder $(if ($proof.Registration.workFolder) { $proof.Registration.workFolder } else { $Config.windows.workFolder }) $slot.registrationDirectory
            $slot.sourceCommit = Get-GitCommit $clone
            $slot.generatedSettingsHash = Get-HostSettingsRecord -Clone $clone
        }
        if ($InstallRoot -and (Test-Path -LiteralPath $InstallRoot)) {
            foreach ($clone in @(Get-ChildItem -LiteralPath $InstallRoot -Directory | Where-Object { $_.Name -cmatch '^win\d{2}$' } | Sort-Object Name)) {
                & $consider $clone.Name 'windows' (Join-Path $clone.FullName $Config.windows.directory) $windowsExtra
            }
        }
        & $consider 'windows-legacy' 'windows' (Join-Path $Root $Config.windows.directory) {
            param($slot, $proof)
            & $windowsExtra $slot $proof
            $slot.legacy = $true
        }

        $scopes = @($slots | ForEach-Object scope | Select-Object -Unique)
        $scope = if ($scopes.Count -eq 1) { $scopes[0] } elseif ($Config.github.url) { Get-RunnerScope $Config.github.url }
        $record = [ordered]@{ generation = 1; hostId = $hostId; github = [ordered]@{ scope = $scope }; slots = $slots.ToArray() }
        if ($inventory.State -eq 'unreadable') {
            $kept = "$($inventory.Path).unreadable-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
            Move-Item -LiteralPath $inventory.Path -Destination $kept
            "Kept the unreadable inventory as $kept."
        }
        Write-HostInventory $record
        "Adopted $($slots.Count) slot(s) into $(Get-HostInventoryPath): $(@($slots | ForEach-Object { "$($_.slotId) ($($_.runnerName), id $($_.runnerId))" }) -join '; ')."
        foreach ($item in $unowned) { "Not adopted: $($item.directory)$(if ($item.runnerName) { " ($($item.runnerName))" }): $($item.reason)" }
    }
}

# --- Output.

function Write-PlanText($Plan) {
    "Host $($Plan.hostId): inventory $($Plan.inventory.state)$(if ($Plan.inventory.reason) { " ($($Plan.inventory.reason))" })"
    if ($Plan.operation.state -eq 'unreadable') { "Operation journal unreadable: $($Plan.operation.reason)" }
    if (-not $Plan.changes.Count) { 'No changes.' }
    foreach ($change in $Plan.changes) {
        $details = @($change.Keys | Where-Object { $_ -ne 'kind' } | ForEach-Object { "$_=$(@($change[$_]) -join ',')" }) -join ' '
        "  $($change.kind) $details"
    }
    foreach ($item in $Plan.findings) { "  [$($item.severity)] $($item.subject): $($item.message)" }
    if ($Plan.planHash) { "planHash: $($Plan.planHash)" }
}

function Write-StatusText($Status) {
    "Host $($Status.hostId): inventory $($Status.inventory.state)$(if ($Status.inventory.generation) { " (generation $($Status.inventory.generation))" })$(if ($Status.inventory.reason) { ": $($Status.inventory.reason)" })"
    switch ($Status.operation.state) {
        'readable' { "Unfinished operation $($Status.operation.kind) ($($Status.operation.id)) on $($Status.operation.slotId), started $($Status.operation.startedUtc), next step $($Status.operation.pendingStep)." }
        'unreadable' { "Operation journal unreadable: $($Status.operation.reason)" }
    }
    foreach ($slot in $Status.slots) {
        $busy = if ($slot.github.busy) { ', busy' } else { '' }
        "  $($slot.slotId) $($slot.state) $($slot.runnerName) (id $($slot.runnerId)): GitHub $($slot.github.status)$busy$(if ($slot.held) { ', held' })"
        foreach ($item in $slot.drift) { "    [$($item.state)] $($item.kind): $($item.message)" }
    }
    if ($Status.runnerGroup) {
        "  runner group $($Status.runnerGroup.group): $($Status.runnerGroup.state)"
        foreach ($item in $Status.runnerGroup.findings) { "    [$($item.severity)] $($item.message)" }
    }
    foreach ($item in $Status.unowned) { "  [$($item.severity)] $($item.message)" }
}

try {
    switch ($Action) {
        'Init' { Invoke-Init; exit 0 }
        'Adopt' { Invoke-Adopt; exit 0 }
        'Plan' {
            $plan = Get-HostPlan
            if ($Json) { ConvertTo-Json -InputObject $plan -Depth 20 } else { Write-PlanText $plan }
            if ($plan.inventory.state -eq 'unreadable' -or $plan.operation.state -eq 'unreadable') {
                [Console]::Error.WriteLine('Plan cannot be computed: the host state cannot be read. Restore the file, or rebuild the inventory with -Action Adopt -ReplaceUnreadable.')
                exit 1
            }
            exit $(if ($plan.changes.Count) { 3 } else { 0 })
        }
        'Status' {
            $status = Get-HostStatus
            if ($Json) { ConvertTo-Json -InputObject $status -Depth 20 } else { Write-StatusText $status }
            exit 0
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
