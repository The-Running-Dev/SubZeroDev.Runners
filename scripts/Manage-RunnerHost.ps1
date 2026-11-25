#Requires -Version 7.2
# The host manager: what this host runs, what it owns, and what would change.
#
#   Init    writes hostId and the slot counts (default 2 Linux, 2 Windows) into this checkout's runners.local.json.
#   Adopt   builds the first host inventory from what can be proven: a registration directory whose .runner agentId is the
#           ID GitHub reports under that name, and the containers this repository's scripts create for it. It writes
#           only the inventory.
#   Plan    compares the settings with the inventory, Docker and GitHub and prints the changes Apply would make, with a
#           planHash. Exit 0: no changes; 3: changes, or a drift/blocked finding; 1: the state, or something the plan needs, cannot be read.
#   Status  prints each slot as GitHub, Docker and the files on disk report it, with drift and any unfinished operation.
#
#   AutoStart  what runs at host start and at sign-in: waits for Docker (up to buildAgent.docker.readyTimeoutSeconds), then
#           starts each active Windows slot's supervisor without ending maintenance. Linux slots need nothing: Docker restarts
#           their containers and the entrypoint waits while a slot is held.
#   Hold -Slot  drains the slot, stops it and keeps its maintenance record: nothing starts it again until Resume.
#   Resume -Slot  the only owner path that ends the maintenance Hold began: restores labels, deletes the record, starts the
#           one listener. Hold and Resume refuse a slot while an operation on it is unfinished (finish it with Apply).
#   Startup applies windows.startAtSignIn: writes or removes the per-user Startup entry that runs AutoStart.
#   Apply   carries out the plan, each change one operation journaled step by step in operation.json; rerunning Apply
#           finishes an interrupted one. In order: migrate-legacy-linux (the pre-pool linux-01 onto its compose containers with
#           the same registration; -Rollback undoes it before it is verified, and its pre-pool containers are kept stopped for
#           rollback), then add (lowest number first: Linux registers in a throwaway container and starts on compose, Windows
#           gets its own clone InstallRoot\winNN), then retire (highest number first, only with -Retire: drained, stopped,
#           removed at GitHub and locally; windows-legacy only once win01 is online). -ExpectPlan <planHash> refuses before
#           any change when the plan is not the one reviewed. Apply -Prune removes what is kept for rollback and what retired
#           slots left on disk (directory, clone, volumes). Exit 0: done; 3: a retire was skipped or deferred; 1: failed.
#           After the adds and retires Apply updates each drifted slot, one at a time, inside that slot's drain: a Linux
#           slot is recreated on its own compose services (sidecar, then runner; never down), a Windows slot's clone is
#           synced, its host settings written and its runner started again. A held slot is skipped (deferred: held), a
#           busy one that does not drain in time is left as it is (deferred: busy). A stale BuildAgent digest (one Update
#           replaced) is reported as a downgrade and Apply refuses it.
#   Update -Version x.y.z  resolves the BuildAgent image tag to its digest, writes buildAgent.image into runners.local.json
#           and the inventory before anything is recreated, rebuilds the Linux image on it, then applies like Apply. A
#           floating tag (latest) is refused. An earlier version is a rollback and is said so.
#
# Plan also reports resources: slot volumes, the Docker data drive's free space, the memory the slots are limited to and
# the Windows BuildAgent estimate (advisory), against the .wslconfig memory cap (read only, never edited).
#
# Plan and Status take no lock and change nothing. Init, Adopt, AutoStart, Hold, Resume, Apply and Update take the host lock.
param(
    [Parameter(Mandatory)] [ValidateSet('Init', 'Adopt', 'Plan', 'Status', 'AutoStart', 'Hold', 'Resume', 'Startup', 'Apply', 'Update')] [string] $Action,
    # The slot Hold and Resume act on, e.g. linux-01 or win02.
    [string] $Slot,
    [ValidateRange(0, 16)] [Nullable[int]] $LinuxCount,
    [ValidateRange(0, 16)] [Nullable[int]] $WindowsCount,
    [string] $HostId,
    # Adopt over an unreadable inventory. The old file is kept beside it as inventory.json.unreadable-<utc>.
    [switch] $ReplaceUnreadable,
    # Apply: undo the unfinished legacy migration instead of finishing it (only before it is verified).
    [switch] $Rollback,
    # Apply: remove the containers a finished migration kept for rollback (by recorded ID and name), and what retired slots left.
    [switch] $Prune,
    # Apply: retire the slots the settings no longer want. Without it a retire is reported and skipped (exit 3).
    [switch] $Retire,
    # Apply: the planHash -Action Plan printed. Apply refuses before any change when the plan is no longer that one.
    [string] $ExpectPlan,
    # Update: the BuildAgent release to move to, e.g. 1.4.2. Resolved to its digest; floating tags are refused.
    [string] $Version,
    [switch] $Json,
    # Where the Windows instance clones live (winNN). The setup default.
    [string] $InstallRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SubZeroDev\Runners' })
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
. "$PSScriptRoot\Compose.ps1"
. "$PSScriptRoot\Housekeeping.ps1"
. "$PSScriptRoot\RunnerArchive.ps1"
. "$PSScriptRoot\WindowsRunnerSetup.ps1"

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

# docker container inspect (by name or full ID): { State = present | absent | unknown; Id; Name; Image; Labels; Running;
# RestartPolicy; Reason }.
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
    $running = if ($item.State -and $null -ne $item.State.Running) { [bool]$item.State.Running }
    $restart = if ($item.HostConfig -and $item.HostConfig.RestartPolicy) { [string]$item.HostConfig.RestartPolicy.Name }
    [pscustomobject]@{ State = 'present'; Id = [string]$item.Id; Name = ([string]$item.Name).TrimStart('/'); Image = [string]$item.Image; Labels = $labels; Running = $running; RestartPolicy = $restart; Reason = $null }
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
            } elseif ($container.State -eq 'absent') {
                & $add 'container' 'drift' "The container named $($runner.name) does not exist."
            } elseif ($image.State -eq 'absent') {
                & $add 'image' 'drift' "The image $($Config.linux.image) is not built."
            }
        } else {
            & $add 'container' 'drift' "No runner container is recorded for $($Slot.slotId)."
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

function Get-HostPlan([switch] $Resources) {
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
        $downgrade = Get-DowngradeFinding $inv
        if ($downgrade) { $plan.findings.Add($downgrade) }
        # Whether the built Linux image is not the one the settings build (base image, runner version, archive): read once,
        # and only when the image exists and the runner archive is downloaded, so Plan never downloads or builds anything.
        $cache = @{}
        $imageStale = {
            if (-not $cache.ContainsKey('stale')) {
                $cache.stale = $false
                if ((Get-ImageId $Config.linux.image).State -eq 'present') {
                    $expected = Get-LinuxExpectedContextHash $Config $Root
                    if ($expected -and (Get-LinuxImageContextHash $Config.linux.image) -ne $expected) { $cache.stale = $true }
                }
            }
            $cache.stale
        }
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
                if ($slot.slotId -eq 'windows-legacy' -and $Config.windows.count -gt 0) { $change.after = 'win01 online' }
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
                if ($record.PSObject.Properties['keptForRollback'] -and @($record.keptForRollback).Count) {
                    $plan.changes.Add([ordered]@{ kind = 'prune-kept'; platform = $slot.Platform; slotId = $slot.SlotId; containers = @($record.keptForRollback | ForEach-Object { $_.name }); requires = '-Prune' })
                }
                $drift = @(Get-SlotDrift $record)
                $reasons = @($drift | Where-Object { $_.state -eq 'drift' } | ForEach-Object kind | Select-Object -Unique)
                if ($slot.Platform -eq 'linux' -and $slot.Composed -and -not $reasons.Count -and (& $imageStale)) { $reasons = @('image-context') }
                if ($reasons.Count) { $plan.changes.Add([ordered]@{ kind = 'update'; platform = $slot.Platform; slotId = $slot.SlotId; reasons = $reasons }) }
                foreach ($item in $drift | Where-Object { $_.state -eq 'unknown' }) { & $finding 'unknown' $slot.SlotId $item.message }
            }
        }
        # A Linux add needs the image: Apply builds it first when it is missing or stale, so the plan says so.
        $linuxAdd = @($plan.changes | Where-Object { $_.kind -eq 'add' -and $_.platform -eq 'linux' }) | Select-Object -First 1
        if ($linuxAdd) {
            $image = Get-ImageId $Config.linux.image
            if ($image.State -eq 'unknown') { & $finding 'unknown' 'image' "Whether the image $($Config.linux.image) exists is unknown ($($image.Reason))." }
            elseif ($image.State -eq 'absent' -or (& $imageStale)) {
                $plan.changes.Insert($plan.changes.IndexOf($linuxAdd), [ordered]@{ kind = 'build-image'; platform = 'linux'; image = $Config.linux.image; reason = $(if ($image.State -eq 'absent') { 'not built' } else { 'image-context' }) })
            }
        }
        $scope = Get-InventoryScope $inv
        $group = Test-RunnerGroup $scope @($live | Where-Object { $_.runnerId } | ForEach-Object { [int64]$_.runnerId })
        foreach ($item in $group.findings) { $plan.findings.Add($item) }
        foreach ($item in @(Get-UnownedRunners $inv $scope)) { $plan.findings.Add($item) }
    }
    # What the plan cannot tell apart from "nothing to do" is part of it: a finding that is unknown, drift or blocked.
    $plan.planHash = Get-PlanHash ([ordered]@{ changes = $plan.changes; findings = @($plan.findings | Where-Object { $_.severity -in 'unknown', 'drift', 'blocked' }) })
    # Resources are read only for the owner: not hashed, and a warning never changes the exit code.
    if ($Resources) {
        $plan.resources = Get-HostResources $(if ($inventory.State -eq 'readable') { $inventory.Value })
        foreach ($warning in $plan.resources.warnings) { & $finding 'warning' 'resources' $warning }
    }
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

# A BuildAgent digest that Update replaced, back in the settings (an older runners.local.json restored, say): a downgrade
# nobody asked for. Update -Version with the older release is how a rollback is asked for.
function Get-DowngradeFinding($Inventory) {
    $recorded = if ($Inventory -and $Inventory.PSObject.Properties['buildAgent']) { $Inventory.buildAgent }
    if (-not $recorded -or -not $recorded.image) { return }
    $current = [string]$Config.buildAgent.image
    if ($current -eq $recorded.image) { return }
    # A replaced digest is a downgrade unless it is known to be a later release than the recorded one (a rollback then
    # restored settings from before it).
    $entry = @($recorded.previous | Where-Object { $_ -and $_.image -eq $current }) | Select-Object -First 1
    if (-not $entry) { return }
    if ($entry.version -and $recorded.version -and [version]$entry.version -gt [version]$recorded.version) { return }
    [ordered]@{
        severity = 'blocked'; subject = 'buildAgent'
        message = "buildAgent.image is $current, a digest Update replaced with $($recorded.image)$(if ($recorded.version) { " ($($recorded.version))" }). That is a downgrade and is not applied; restore buildAgent.image in runners.local.json, or roll back with -Action Update -Version <release>."
    }
}

# '8g', '512m', '24GB', '1.5GB', '12kB' as bytes, or $null.
function ConvertTo-ByteCount([string] $Size) {
    if ($Size -notmatch '^\s*(\d+(?:\.\d+)?)\s*([kmgt]?)(i?b)?\s*$') { return $null }
    $power = @{ '' = 0; 'k' = 1; 'm' = 2; 'g' = 3; 't' = 4 }[$Matches[2].ToLowerInvariant()]
    [double]$Matches[1] * [Math]::Pow(1024, $power)
}

function Format-GB([double] $Bytes) { '{0:0.#} GB' -f ($Bytes / 1GB) }

# The memory cap of the WSL 2 VM Docker Desktop runs Linux containers in: [wsl2] memory= in .wslconfig. Read only.
function Get-WslMemoryCap {
    $path = if ($env:SZR_WSLCONFIG) { $env:SZR_WSLCONFIG } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.wslconfig' }
    $result = [ordered]@{ file = $path; memory = $null; bytes = $null }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $result }
    $section = $null
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*\[(.+?)\]\s*$') { $section = $Matches[1].Trim().ToLowerInvariant(); continue }
        if ($section -eq 'wsl2' -and $line -match '^\s*memory\s*=\s*([^#;\s]+)') { $result.memory = $Matches[1]; $result.bytes = ConvertTo-ByteCount $Matches[1] }
    }
    $result
}

# What Plan reports about disk and memory. Nothing here is hashed or changes the exit code: a warning is for the owner.
function Get-HostResources($Inventory) {
    $warnings = [Collections.Generic.List[string]]::new()
    $linuxRows = @(if ($Inventory) { Get-LinuxSlots $Config $Inventory $null })
    $windowsCount = if ($null -ne $Config.windows.count) { [int]$Config.windows.count } elseif ($Inventory) { @($Inventory.slots | Where-Object { $_ -and $_.platform -eq 'windows' -and $_.state -in 'provisioning', 'active' }).Count } else { 0 }

    $volumes = [ordered]@{ state = 'known'; items = [Collections.Generic.List[object]]::new(); reason = $null }
    $names = @{}
    foreach ($row in $linuxRows) { foreach ($p in $row.Volumes.PSObject.Properties) { if ($p.Value) { $names[[string]$p.Value] = $row.SlotId } } }
    if ($names.Count) {
        $df = Invoke-Docker @('system', 'df', '-v', '--format', '{{json .Volumes}}')
        $listed = $null
        if ($df.ExitCode -eq 0) { try { $listed = @($df.Output | ConvertFrom-Json) } catch { $listed = $null } }
        if ($null -eq $listed) {
            $volumes.state = 'unknown'; $volumes.reason = "docker system df -v could not be read: $($df.Output)"
            $warnings.Add("Slot volume sizes are unknown ($($volumes.reason)).")
        } else {
            foreach ($item in $listed | Where-Object { $_ -and $names.ContainsKey([string]$_.Name) } | Sort-Object Name) {
                $volumes.items.Add([ordered]@{ slotId = $names[[string]$item.Name]; name = [string]$item.Name; size = [string]$item.Size })
            }
        }
    }

    $dataPath = if ($env:SZR_DOCKER_DATA) { $env:SZR_DOCKER_DATA } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Docker' }
    $disk = [ordered]@{ path = $dataPath; drive = $null; freeGB = $null; minimumGB = [double]$Config.housekeeping.minFreeGB; low = $null }
    try {
        $report = @(Get-FreeDiskReport @($dataPath)) | Select-Object -First 1
        if ($report) { $disk.drive = $report.Drive; $disk.freeGB = $report.FreeGB; $disk.low = $report.Low }
        if ($report.Low) { $warnings.Add("Docker's data drive $($report.Drive) has $($report.FreeGB) GB free, below housekeeping.minFreeGB ($($report.MinimumGB) GB).") }
    } catch { $warnings.Add("The free space of Docker's data drive ($dataPath) cannot be read: $($_.Exception.Message)") }

    $perLinux = ConvertTo-ByteCount $Config.linux.memory
    if ($Config.linux.docker.mode -eq 'sidecar' -and $Config.linux.docker.memory) { $perLinux += ConvertTo-ByteCount $Config.linux.docker.memory }
    $perWindows = ConvertTo-ByteCount $Config.buildAgent.estimate.memory
    $linuxTotal = $perLinux * $linuxRows.Count
    $cap = Get-WslMemoryCap
    $memory = [ordered]@{
        linux = [ordered]@{ slots = $linuxRows.Count; perSlot = (Format-GB $perLinux); total = (Format-GB $linuxTotal); basis = 'enforced: linux.memory plus the Docker sidecar limit' }
        windows = [ordered]@{ slots = $windowsCount; perSlot = (Format-GB $perWindows); total = (Format-GB ($perWindows * $windowsCount)); basis = 'advisory: buildAgent.estimate.memory, not enforced' }
        wslCap = [ordered]@{ file = $cap.file; memory = $cap.memory }
    }
    if ($cap.bytes -and $linuxTotal -gt $cap.bytes) {
        $warnings.Add("The Linux slots may use $(Format-GB $linuxTotal), more than the WSL memory cap $($cap.memory) in $($cap.file). This is only reported: .wslconfig is never edited here.")
    }
    [ordered]@{ volumes = $volumes; dockerData = $disk; memory = $memory; warnings = $warnings.ToArray() }
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
    try { $registration = Get-LocalRegistration $Directory } catch { return [pscustomobject]@{ State = 'unknown'; Reason = "$Directory\.runner cannot be read." } }
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
                'unproven' {
                    $unowned.Add([ordered]@{ directory = $Directory; runnerName = $proof.Registration.agentName; reason = $proof.Reason })
                    # The directory holds a registration this host does not own: its number is reserved, so Plan never proposes
                    # a new slot on top of it. The slot is not live and nothing manages it.
                    if ($SlotId -match '\d+$') {
                        $slots.Add([ordered]@{ slotId = $SlotId; platform = $Platform; state = 'unowned'; legacy = $false; registrationDirectory = (Get-CanonicalPath $Directory); reason = $proof.Reason; adoptedUtc = $now })
                    }
                    return
                }
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

        $scopes = @($slots | Where-Object { $_.state -eq 'active' } | ForEach-Object scope | Select-Object -Unique)
        $scope = if ($scopes.Count -eq 1) { $scopes[0] } elseif ($Config.github.url) { Get-RunnerScope $Config.github.url }
        $record = [ordered]@{ generation = 1; hostId = $hostId; github = [ordered]@{ scope = $scope }; slots = $slots.ToArray() }
        if ($inventory.State -eq 'unreadable') {
            $kept = "$($inventory.Path).unreadable-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
            Copy-Item -LiteralPath $inventory.Path -Destination $kept
            "Kept the unreadable inventory as $kept."
        }
        Write-HostInventory $record
        "Adopted $(@($slots | Where-Object { $_.state -eq 'active' }).Count) slot(s) into $(Get-HostInventoryPath): $(@($slots | Where-Object { $_.state -eq 'active' } | ForEach-Object { "$($_.slotId) ($($_.runnerName), id $($_.runnerId))" }) -join '; ')."
        foreach ($item in $unowned) { "Not adopted: $($item.directory)$(if ($item.runnerName) { " ($($item.runnerName))" }): $($item.reason)" }
    }
}

# --- AutoStart, Hold, Resume and the sign-in entry.

# Runs the instance's own Manage-WindowsRunner.ps1. The caller holds the host lock as joinable, so the child joins it.
function Invoke-InstanceAction($Record, [string] $InstanceAction) {
    $worker = Join-Path ([string]$Record.installPath) 'scripts\Manage-WindowsRunner.ps1'
    if (-not (Test-Path -LiteralPath $worker)) { return [pscustomobject]@{ ExitCode = 1; Output = "$worker does not exist." } }
    $output = & (Get-Process -Id $PID).Path -NoProfile -File $worker -Action $InstanceAction 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n").Trim() }
}

# Waits for the Docker daemon: nothing to wait for when docker cannot be run at all, and a daemon that never answers is
# reported, not fatal (Windows runners do not need it to start).
function Wait-DockerReady {
    $deadline = [DateTime]::UtcNow.AddSeconds([int]$Config.buildAgent.docker.readyTimeoutSeconds)
    while ($true) {
        $info = Invoke-Docker @('info')
        if ($null -eq $info.ExitCode) { return 'docker is not installed here; not waiting for it.' }
        if ($info.ExitCode -eq 0) { return $null }
        $left = ($deadline - [DateTime]::UtcNow).TotalSeconds
        if ($left -le 0) { return "Docker did not answer within $($Config.buildAgent.docker.readyTimeoutSeconds) seconds ($($info.Output))." }
        Start-Sleep -Seconds ([Math]::Min(5, [Math]::Ceiling($left)))
    }
}

# What runs at host start (and at sign-in): every active Windows slot's supervisor starts with maintenance left as it is.
# Linux slots need nothing: Docker restarts their containers and the entrypoint waits while a slot is held.
function Invoke-AutoStart {
    $inventory = Read-HostInventory
    if ($inventory.State -eq 'absent') { 'No host inventory: nothing is managed here, so nothing was started.'; return }
    if ($inventory.State -eq 'unreadable') { throw "AutoStart refused: the host inventory $($inventory.Path) cannot be read because $($inventory.Reason)." }
    $warning = Wait-DockerReady
    if ($warning) { Write-Warning $warning }
    Use-HostLock -Kind 'Manage-RunnerHost AutoStart' -Joinable -ScriptBlock {
        $current = Assert-HostInventoryUsable 'Resume'
        foreach ($slot in @($current.slots | Where-Object { $_ -and $_.platform -eq 'windows' -and $_.state -eq 'active' } | Sort-Object slotId)) {
            $result = Invoke-InstanceAction $slot 'AutoStart'
            if ($result.ExitCode -eq 0) { "$($slot.slotId): $($result.Output)" }
            else { $script:HostFailed = $true; [Console]::Error.WriteLine("$($slot.slotId): AutoStart failed (exit $($result.ExitCode)): $($result.Output)") }
        }
    }
}

# The active slot -Slot names, or a refusal. A slot with an unfinished operation is refused (C4): Hold and Resume would
# change what the operation recorded about who held it.
function Get-ManagedSlot([string] $Verb) {
    if (-not $Slot) { throw "$Verb needs -Slot <slotId> (see -Action Status)." }
    $inv = Assert-HostInventoryUsable $Verb
    $record = Get-InventorySlot $inv $Slot
    if (-not $record) { throw "$Verb refused: the inventory has no slot '$Slot'." }
    if ($record.state -ne 'active') { throw "$Verb refused: slot $Slot is $($record.state), not active." }
    $operation = Read-HostOperation
    if ($operation.State -eq 'readable') {
        $op = $operation.Value
        $pending = @($op.steps | Where-Object { $_.state -ne 'done' }) | Select-Object -First 1
        throw "$Verb refused: the unfinished operation $($op.kind) ($($op.id)) on $($op.slotId), started $($op.startedUtc), next step $($pending.name), may change what is held. Finish it with Apply first."
    }
    $record
}

function Invoke-Hold {
    Use-HostLock -Kind 'Manage-RunnerHost Hold' -Joinable -ScriptBlock {
        $record = Get-ManagedSlot 'Hold'
        if ($record.platform -eq 'windows') {
            $result = Invoke-InstanceAction $record 'Maintenance'
            if ($result.ExitCode -ne 0) { $script:HostFailed = $true; [Console]::Error.WriteLine("Hold failed for $Slot (exit $($result.ExitCode)): $($result.Output)"); return }
            "${Slot}: $($result.Output)"
            return
        }
        $dir = [string]$record.registrationDirectory
        $file = Join-Path $dir 'maintenance.json'
        $runner = @($record.containers | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
        $busy = { if ($runner) { & $Docker exec $runner.name pgrep -f Runner.Worker 2>$null | Out-Null; $LASTEXITCODE -eq 0 } else { $false } }.GetNewClosure()
        $drain = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy $busy -Reason 'hold' -TimeoutMinutes $Config.lifecycle.drainTimeoutMinutes
        if ($drain.Outcome -in 'timeout', 'failed') {
            $script:HostFailed = $true
            [Console]::Error.WriteLine("Hold did not complete for ${Slot}: $(if ($drain.Failures) { @($drain.Failures) -join ' ' } else { $drain.Retained })")
            return
        }
        # The runner first, then the Docker sidecar its jobs depend on.
        $containers = @(@($record.containers | Where-Object { $_.role -eq 'runner' }) + @($record.containers | Where-Object { $_.role -ne 'runner' }))
        for ($i = 0; $i -lt $containers.Count; $i++) {
            $stop = Stop-LinuxContainer $containers[$i].name
            if ($stop.Result -eq 'failed') {
                Set-MaintenanceState $file @{ phase = 'stop-failed'; failure = $stop.Detail; failedUtc = [DateTime]::UtcNow.ToString('o') }
                $script:HostFailed = $true
                [Console]::Error.WriteLine("Hold stopped short for ${Slot}: $($stop.Detail) The record is kept, so no listener starts.")
                return
            }
        }
        Set-MaintenanceState $file @{ phase = 'held' }
        "${Slot}: held. The record $file stays until -Action Resume."
    }
}

function Invoke-Resume {
    Use-HostLock -Kind 'Manage-RunnerHost Resume' -Joinable -ScriptBlock {
        $record = Get-ManagedSlot 'Resume'
        if ($record.platform -eq 'windows') {
            $result = Invoke-InstanceAction $record 'Start'
            if ($result.ExitCode -ne 0) { $script:HostFailed = $true; [Console]::Error.WriteLine("Resume failed for $Slot (exit $($result.ExitCode)): $($result.Output)"); return }
            "${Slot}: $($result.Output)"
            return
        }
        $dir = [string]$record.registrationDirectory
        $file = Join-Path $dir 'maintenance.json'
        if (-not (Test-Path -LiteralPath $file)) { "${Slot}: not held; nothing to resume."; return }
        # An unreadable record is refused with the existing message before anything starts.
        if ((Get-MaintenanceState $file).phase -eq 'unreadable') { Exit-RunnerMaintenance $file $dir | Out-Null }
        # Containers first (a held entrypoint waits), the record last: exactly one listener starts, when the record goes.
        foreach ($container in @(@($record.containers | Where-Object { $_.role -ne 'runner' }) + @($record.containers | Where-Object { $_.role -eq 'runner' }))) {
            $state = (Get-ContainerState $container.name).State
            if ($state -in 'absent', 'unknown') { $script:HostFailed = $true; [Console]::Error.WriteLine("Resume stopped for ${Slot}: container $($container.name) is $state, so no listener would start. The record is kept; start Docker or run Apply, then Resume again."); return }
            if ($state -eq 'stopped') {
                $start = Invoke-Docker @('start', $container.name)
                if ($start.ExitCode -ne 0) { $script:HostFailed = $true; [Console]::Error.WriteLine("Resume stopped for ${Slot}: docker start $($container.name) exited $($start.ExitCode): $($start.Output) The record is kept."); return }
            }
        }
        Exit-RunnerMaintenance $file $dir | Out-Null
        "${Slot}: resumed; the listener starts."
    }
}

# windows.startAtSignIn: a per-user Startup entry that runs host AutoStart. No elevation, no scheduled task, no service.
function Get-StartupEntryPath {
    $directory = if ($env:SZR_STARTUP_DIRECTORY) { $env:SZR_STARTUP_DIRECTORY } else { [Environment]::GetFolderPath('Startup') }
    Join-Path $directory 'SubZeroDev Runners AutoStart.cmd'
}

function Set-StartupEntry {
    $path = Get-StartupEntryPath
    if ($Config.windows.startAtSignIn -eq $true) {
        $worker = Join-Path $PSScriptRoot 'Manage-RunnerHost.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
        Write-FileAtomic $path "@echo off`r`nstart `"`" /min `"$Pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$worker`" -Action AutoStart`r`n"
        "windows.startAtSignIn is on: wrote $path."
    }
    elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force; "windows.startAtSignIn is off: removed $path." }
    else { "windows.startAtSignIn is off: no Startup entry exists." }
}

# --- Apply: the legacy Linux migration, its rollback, and pruning what it kept for rollback.
#
# The migration is one journaled operation (operation.json, kind migrate-legacy-linux) with these steps, each done once and
# safe to repeat after a crash: drain (heldBefore journaled first), stop-legacy (restart policy journaled, then off, then
# stopped, all by recorded ID), compose-up (the compose linux-01 on the pre-pool directory and volumes: sidecar first, then
# the runner; new IDs journaled), end-maintenance (only when the migration started it), verify (GitHub reports the same
# runner ID and name), commit (the inventory records the new containers and keeps the old ones for rollback; the journal
# is deleted last). The two runner containers share one registration and never listen at the same time: the old one is
# stopped before the new one exists, and the new one waits in its entrypoint while the maintenance record exists.

$MigrationKind = 'migrate-legacy-linux'
$MigrationSteps = @('drain', 'stop-legacy', 'compose-up', 'end-maintenance', 'verify', 'commit')

function Get-OperationStep($Operation, [string] $Name) { @($Operation.steps | Where-Object { $_.name -eq $Name }) | Select-Object -First 1 }

function Get-StepFact($Step, [string] $Name) { if ($Step -and $Step.facts -and $Step.facts.PSObject.Properties[$Name]) { $Step.facts.$Name } }

function Set-StepFact($Operation, $Step, [string] $Name, $Value) {
    if (-not $Step.facts) { $Step | Add-Member -Force -NotePropertyName facts -NotePropertyValue ([pscustomobject]@{}) }
    $Step.facts | Add-Member -Force -NotePropertyName $Name -NotePropertyValue $Value
    Write-HostOperation $Operation
}

function Complete-OperationStep($Operation, $Step) {
    $Step.state = 'done'
    $Step | Add-Member -Force -NotePropertyName doneUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
    Write-HostOperation $Operation
}

function Test-OurComposeContainer($Container, [string] $SlotId) {
    $Container.Labels -and $Container.Labels[$ComposeHostLabel] -eq (Get-RunnerHostId $Config) -and $Container.Labels[$ComposeSlotLabel] -eq $SlotId
}

# The recorded runner container first, then the Docker sidecar (the order a drain stops them in).
function Get-RunnerFirst($Containers) { @(@($Containers | Where-Object { $_.role -eq 'runner' }) + @($Containers | Where-Object { $_.role -ne 'runner' })) }

function Get-RunnerBusyCheck([string] $Container) {
    # A GetNewClosure block does not see this script's functions when the script is run from an interactive session
    # (./scripts/Manage-RunnerHost.ps1), so it carries Invoke-Docker itself.
    $invokeDocker = ${function:Invoke-Docker}
    { (& $invokeDocker @('exec', $Container, 'pgrep', '-f', 'Runner.Worker')).ExitCode -eq 0 }.GetNewClosure()
}

function Wait-ComposeSidecarReady([string] $Container) {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ((Invoke-Docker @('exec', $Container, 'docker', 'version')).ExitCode -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    $false
}

# The compose file holds every composed slot (and, while migrating, linux-01). No slots: no file.
function Write-LinuxComposeFile($Slots) {
    $path = Get-LinuxComposeFilePath $Root
    if (-not @($Slots).Count) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        return $path
    }
    $yaml = ConvertTo-LinuxComposeYaml $Config @($Slots | Sort-Object Number) $Root $PSScriptRoot
    if (-not (Test-Path -LiteralPath $path) -or [IO.File]::ReadAllText($path) -ne $yaml) { Write-FileAtomic $path $yaml }
    $path
}

# The legacy slot's row from Get-LinuxSlots and its inventory record, or a refusal.
function Get-MigrationSlot($Inventory, [string] $Verb) {
    $row = @(Get-LinuxSlots $Config $Inventory | Where-Object { $_.SlotId -eq 'linux-01' }) | Select-Object -First 1
    $record = Get-InventorySlot $Inventory 'linux-01'
    if (-not $row -or -not $record) { throw "$Verb refused: the inventory has no slot linux-01." }
    if (-not $row.Legacy) { throw "$Verb refused: linux-01 is not the pre-pool runner (legacy) in the inventory." }
    [pscustomobject]@{ Row = $row; Record = $record; Directory = [string]$record.registrationDirectory; StateFile = (Join-Path ([string]$record.registrationDirectory) 'maintenance.json') }
}

# What must hold before a migration is journaled. Nothing is changed by this.
function Assert-MigrationPreflight($Target) {
    $record = $Target.Record
    if ($record.state -ne 'active') { throw "Apply refused: linux-01 is $($record.state), not active." }
    if (-not $record.runnerId) { throw 'Apply refused: linux-01 records no runner ID, so the migrated runner could not be verified.' }
    if (-not $Target.Directory -or -not (Test-Path -LiteralPath (Join-Path $Target.Directory '.runner'))) { throw "Apply refused: linux-01's registration $($Target.Directory)\.runner does not exist." }
    $legacy = @(Get-RunnerFirst $record.containers)
    if (-not @($legacy | Where-Object { $_.role -eq 'runner' }).Count) { throw 'Apply refused: no pre-pool runner container is recorded for linux-01.' }
    foreach ($entry in $legacy) {
        if (-not $entry.id -or -not $entry.name) { throw "Apply refused: a recorded $($entry.role) container of linux-01 has no ID or name." }
        $found = Get-ContainerRecord $entry.id
        if ($found.State -eq 'unknown') { throw "Apply refused: whether the container $($entry.name) ($($entry.id)) exists is unknown ($($found.Reason))." }
        if ($found.State -eq 'absent') { throw "Apply refused: the recorded container $($entry.name) ($($entry.id)) does not exist. Nothing was changed." }
        if ($found.Name -ne $entry.name) { throw "Apply refused: the recorded container $($entry.id) is now named $($found.Name), not $($entry.name). Nothing was changed." }
    }
    $image = Get-ImageId $Config.linux.image
    if ($image.State -ne 'present') { throw "Apply refused: the image $($Config.linux.image) is $(if ($image.State -eq 'absent') { 'not built' } else { "unknown ($($image.Reason))" }). Build it, then rerun Apply." }
    foreach ($name in @($Target.Row.Container, $Target.Row.DockerContainer) | Where-Object { $_ }) {
        $found = Get-ContainerRecord $name
        if ($found.State -eq 'unknown') { throw "Apply refused: whether a container named $name exists is unknown ($($found.Reason))." }
        if ($found.State -eq 'present' -and -not (Test-OurComposeContainer $found 'linux-01')) { throw "Apply refused: a container named $name ($($found.Id)) exists and is not this host's compose linux-01. Nothing was changed." }
    }
}

function Invoke-MigrationDrain($Operation, $Step, $Target) {
    $held = Get-StepFact $Step 'heldBefore'
    if ($null -eq $held) {
        # Journaled before maintenance is entered, never recomputed: a retry would otherwise find its own record.
        $held = Get-HeldBefore $Target.StateFile
        Set-StepFact $Operation $Step 'heldBefore' $held
    }
    if (-not $held) {
        $runner = @($Target.Record.containers | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
        $drain = Enter-RunnerMaintenance -StateFile $Target.StateFile -RunnerDirectory $Target.Directory -IsBusy (Get-RunnerBusyCheck $runner.id) -Reason 'migrate' -TimeoutMinutes $Config.lifecycle.drainTimeoutMinutes
        if ($drain.Outcome -eq 'timeout') {
            Remove-HostOperation
            throw "Apply stopped: $($drain.Retained) The migration was not started (journal deleted); rerun Apply when the runner is idle."
        }
        if ($drain.Outcome -eq 'failed') { throw "Apply stopped in the drain: $(@($drain.Failures) -join ' ') The journal is kept; rerun Apply, or Apply -Rollback." }
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-MigrationStopLegacy($Operation, $Step, $Target) {
    $kept = @(Get-StepFact $Step 'containers')
    if (-not $kept.Count) {
        # The restart policies are journaled before any is changed, so a rollback can put back exactly what was there.
        $kept = @(foreach ($entry in Get-RunnerFirst $Target.Record.containers) {
                $found = Get-ContainerRecord $entry.id
                if ($found.State -ne 'present' -or $found.Name -ne $entry.name) { throw "Apply stopped: the recorded container $($entry.name) ($($entry.id)) is $(if ($found.State -eq 'present') { "named $($found.Name)" } else { $found.State }). $($found.Reason) The journal is kept." }
                [pscustomobject][ordered]@{ role = $entry.role; id = $found.Id; name = $found.Name; image = $found.Image; restart = $(if ($found.RestartPolicy) { $found.RestartPolicy } else { 'no' }) }
            })
        Set-StepFact $Operation $Step 'containers' $kept
    }
    foreach ($entry in $kept) {
        $found = Get-ContainerRecord $entry.id
        if ($found.State -ne 'present' -or $found.Name -ne $entry.name) { throw "Apply stopped: the recorded container $($entry.name) ($($entry.id)) is $(if ($found.State -eq 'present') { "named $($found.Name)" } else { $found.State }). $($found.Reason) The journal is kept; nothing else was changed." }
        if ($found.RestartPolicy -ne 'no') {
            $update = Invoke-Docker @('update', '--restart=no', $entry.id)
            if ($update.ExitCode -ne 0) { throw "Apply stopped: docker update --restart=no $($entry.name) exited $($update.ExitCode): $($update.Output) The journal is kept." }
        }
        $stop = Stop-LinuxContainer $entry.id
        if ($stop.Result -eq 'failed') { throw "Apply stopped: $($stop.Detail) The journal is kept." }
        if ($stop.Result -eq 'absent') { throw "Apply stopped: the recorded container $($entry.name) ($($entry.id)) disappeared. The journal is kept." }
    }
    Complete-OperationStep $Operation $Step
}

function Get-MigrationComposeSlots($Inventory, $Target) {
    @(@(Get-LinuxSlots $Config $Inventory | Where-Object { $_.Composed -and $_.SlotId -ne 'linux-01' }) + $Target.Row)
}

function Invoke-MigrationComposeUp($Operation, $Step, $Inventory, $Target) {
    $row = $Target.Row
    Initialize-LinuxSlotResources $Config $row
    $file = Write-LinuxComposeFile (Get-MigrationComposeSlots $Inventory $Target)
    $journaled = @(Get-StepFact $Step 'new' | ForEach-Object { $_.id })
    $wanted = @(@(if ($row.DockerContainer) { [pscustomobject]@{ role = 'docker'; name = $row.DockerContainer; service = "$($row.SlotId)-docker" } }) + [pscustomobject]@{ role = 'runner'; name = $row.Container; service = $row.SlotId })
    $new = [Collections.Generic.List[object]]::new()
    foreach ($item in $wanted) {
        $found = Get-ContainerRecord $item.name
        if ($found.State -eq 'unknown') { throw "Apply stopped: whether $($item.name) exists is unknown ($($found.Reason)). The journal is kept." }
        if ($found.State -eq 'present' -and $found.Id -notin $journaled -and -not (Test-OurComposeContainer $found 'linux-01')) { throw "Apply stopped: a container named $($item.name) ($($found.Id)) exists and is not this host's compose linux-01. The journal is kept." }
        $up = Invoke-LinuxCompose -File $file -Verb up -Services @($item.service)
        if ($up.ExitCode -ne 0) { throw "Apply stopped: compose up $($item.service) exited $($up.ExitCode): $($up.Output) The journal is kept; the pre-pool runner stays stopped and in maintenance." }
        $created = Get-ContainerRecord $item.name
        if ($created.State -ne 'present') { throw "Apply stopped: $($item.name) is $($created.State) after compose up. $($created.Reason) The journal is kept." }
        $new.Add([pscustomobject][ordered]@{ role = $item.role; name = $created.Name; id = $created.Id })
        Set-StepFact $Operation $Step 'new' $new.ToArray()
        if ($item.role -eq 'docker' -and -not (Wait-ComposeSidecarReady $item.name)) { throw "Apply stopped: the Docker sidecar $($item.name) did not become ready. The journal is kept." }
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-MigrationEndMaintenance($Operation, $Step, $Target) {
    $held = Get-StepFact (Get-OperationStep $Operation 'drain') 'heldBefore'
    Complete-OperationMaintenance @{ name = 'end-maintenance'; heldBefore = $held } $Target.StateFile $Target.Directory | Out-Null
    Complete-OperationStep $Operation $Step
}

function Invoke-MigrationVerify($Operation, $Step, $Inventory, $Target) {
    $held = [bool](Get-StepFact (Get-OperationStep $Operation 'drain') 'heldBefore')
    $runnerId = [int64]$Target.Record.runnerId
    $scope = if ($Target.Record.scope) { [string]$Target.Record.scope } else { Get-InventoryScope $Inventory }
    $newRunner = @(Get-StepFact (Get-OperationStep $Operation 'compose-up') 'new' | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
    $deadline = [DateTime]::UtcNow.AddSeconds([int]$Config.lifecycle.startTimeoutSeconds)
    while ($true) {
        $container = Get-ContainerRecord $newRunner.id
        $listing = Get-ScopeRunners $scope
        $match = if ($listing.State -eq 'known') { $listing.Runners | Where-Object { [int64]$_.id -eq $runnerId } | Select-Object -First 1 }
        $why = if ($container.State -ne 'present' -or $container.Name -ne $newRunner.name) { "the container $($newRunner.name) ($($newRunner.id)) is $($container.State) $($container.Reason)" }
        elseif (-not $container.Running) { "the container $($newRunner.name) is not running" }
        elseif ($listing.State -ne 'known') { "GitHub could not be read ($($listing.Reason))" }
        elseif (-not $match) { "GitHub has no runner with id $runnerId" }
        elseif ($match.name -ne $Config.linux.name) { "GitHub's runner $runnerId is named $($match.name), not $($Config.linux.name)" }
        elseif (-not $held -and $match.status -ne 'online') { "GitHub reports runner $runnerId $($match.status)" }
        if (-not $why) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Apply stopped at verify: $why. The journal is kept; rerun Apply to check again, or Apply -Rollback to go back to the pre-pool runner." }
        Start-Sleep -Seconds ([Math]::Max(1, [int]$Config.lifecycle.pollSeconds))
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-MigrationCommit($Operation, $Step, $Inventory, $Target) {
    $now = [DateTime]::UtcNow.ToString('o')
    $containers = @(foreach ($entry in Get-RunnerFirst @(Get-StepFact (Get-OperationStep $Operation 'compose-up') 'new')) {
            $found = Get-ContainerRecord $entry.id
            if ($found.State -ne 'present') { throw "Apply stopped at commit: the new container $($entry.name) ($($entry.id)) is $($found.State). $($found.Reason) The journal is kept." }
            [ordered]@{ role = $entry.role; id = $found.Id; name = $found.Name; image = $found.Image; labels = $found.Labels }
        })
    $kept = @(foreach ($entry in @(Get-StepFact (Get-OperationStep $Operation 'stop-legacy') 'containers')) {
            [ordered]@{ role = $entry.role; id = $entry.id; name = $entry.name; image = $entry.image; restart = $entry.restart; state = 'kept-for-rollback'; keptUtc = $now; operationId = $Operation.id }
        })
    $Target.Record | Add-Member -Force -NotePropertyName containers -NotePropertyValue $containers
    $Target.Record | Add-Member -Force -NotePropertyName keptForRollback -NotePropertyValue $kept
    $Target.Record | Add-Member -Force -NotePropertyName migratedUtc -NotePropertyValue $now
    $Inventory | Add-Member -Force -NotePropertyName generation -NotePropertyValue ([int]$Inventory.generation + 1)
    Write-HostInventory $Inventory
    Complete-OperationStep $Operation $Step
    Remove-HostOperation
}

function Invoke-LegacyMigration($Inventory, $Operation) {
    $target = Get-MigrationSlot $Inventory 'Apply'
    if (-not $Operation) {
        Assert-MigrationPreflight $target
        $Operation = New-HostOperation -Kind $MigrationKind -SlotId 'linux-01' -Steps $MigrationSteps
        Write-HostOperation $Operation
        "Migrating linux-01 ($($target.Record.runnerName), id $($target.Record.runnerId)) to compose: operation $($Operation.id)."
    } else { "Resuming operation $($Operation.id) ($MigrationKind) on linux-01." }
    foreach ($step in @($Operation.steps)) {
        if ($step.state -eq 'done') { continue }
        switch ($step.name) {
            'drain' { Invoke-MigrationDrain $Operation $step $target }
            'stop-legacy' { Invoke-MigrationStopLegacy $Operation $step $target }
            'compose-up' { Invoke-MigrationComposeUp $Operation $step $Inventory $target }
            'end-maintenance' { Invoke-MigrationEndMaintenance $Operation $step $target }
            'verify' { Invoke-MigrationVerify $Operation $step $Inventory $target }
            'commit' { Invoke-MigrationCommit $Operation $step $Inventory $target }
            default { throw "Apply stopped: operation $($Operation.id) has an unknown step '$($step.name)'. The journal is kept." }
        }
        "  $($step.name): done"
    }
    $held = [bool](Get-StepFact (Get-OperationStep $Operation 'drain') 'heldBefore')
    "linux-01 runs on compose as $($target.Row.Container) with runner id $($target.Record.runnerId)$(if ($held) { '; it stays held until -Action Resume' }). The pre-pool containers are kept, stopped, for rollback; Apply -Prune removes them."
}

# Undoes an unfinished migration before it is verified: the new containers go (only ones this migration or this host's
# compose created for linux-01), the pre-pool containers get their restart policy back and start, and maintenance ends
# only if the migration started it. The inventory is not changed. Safe to repeat.
function Invoke-MigrationRollback($Inventory, $Operation) {
    if ($Operation.kind -ne $MigrationKind) { throw "Apply -Rollback refused: the unfinished operation is $($Operation.kind), not $MigrationKind." }
    $verify = Get-OperationStep $Operation 'verify'
    if ($verify.state -eq 'done') { throw "Apply -Rollback refused: the migration was verified (GitHub reports the runner on its new container). Run Apply to commit it." }
    $target = Get-MigrationSlot $Inventory 'Apply -Rollback'
    $Operation | Add-Member -Force -NotePropertyName rollingBack -NotePropertyValue $true
    Write-HostOperation $Operation
    $drain = Get-OperationStep $Operation 'drain'
    $held = Get-StepFact $drain 'heldBefore'
    $ended = Get-OperationStep $Operation 'end-maintenance'
    $new = @(Get-StepFact (Get-OperationStep $Operation 'compose-up') 'new')
    if ($ended.state -eq 'done' -and $held -eq $false -and $new.Count) {
        # The new runner may be listening: drain it before its container goes.
        $runner = @($new | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
        $redrain = Enter-RunnerMaintenance -StateFile $target.StateFile -RunnerDirectory $target.Directory -IsBusy (Get-RunnerBusyCheck $runner.id) -Reason 'rollback' -TimeoutMinutes $Config.lifecycle.drainTimeoutMinutes
        if ($redrain.Outcome -in 'timeout', 'failed') { throw "Apply -Rollback stopped: the new runner did not drain. $(if ($redrain.Failures) { @($redrain.Failures) -join ' ' } else { $redrain.Retained }) The journal is kept; rerun Apply -Rollback." }
        $ended.state = 'pending'
        Write-HostOperation $Operation
    }
    # The new containers, runner first. A container is removed only when it is the journaled one or carries this host's
    # compose labels for linux-01; anything else under those names stops the rollback.
    $journaled = @($new | ForEach-Object { $_.id })
    foreach ($entry in $new) {
        $found = Get-ContainerRecord $entry.id
        if ($found.State -eq 'unknown') { throw "Apply -Rollback stopped: whether $($entry.name) ($($entry.id)) exists is unknown ($($found.Reason)). The journal is kept." }
        if ($found.State -eq 'present' -and $found.Name -ne $entry.name) { throw "Apply -Rollback stopped: the new container $($entry.id) is now named $($found.Name), not $($entry.name); remove it by hand. The journal is kept." }
    }
    foreach ($name in @($target.Row.Container, $target.Row.DockerContainer) | Where-Object { $_ }) {
        $found = Get-ContainerRecord $name
        if ($found.State -eq 'absent') { continue }
        if ($found.State -eq 'unknown') { throw "Apply -Rollback stopped: whether $name exists is unknown ($($found.Reason)). The journal is kept." }
        if ($found.Id -notin $journaled -and -not (Test-OurComposeContainer $found 'linux-01')) { throw "Apply -Rollback stopped: the container named $name ($($found.Id)) was not created by this migration; it was left alone. The journal is kept." }
        $removed = Remove-LinuxContainer $found.Id
        if ($removed.Result -eq 'failed') { throw "Apply -Rollback stopped: $($removed.Detail) The journal is kept." }
    }
    # The pre-pool containers, sidecar first (the runner's jobs depend on it): their restart policy back, then started.
    $kept = @(Get-StepFact (Get-OperationStep $Operation 'stop-legacy') 'containers')
    foreach ($entry in @(@($kept | Where-Object { $_.role -ne 'runner' }) + @($kept | Where-Object { $_.role -eq 'runner' }))) {
        $found = Get-ContainerRecord $entry.id
        if ($found.State -ne 'present' -or $found.Name -ne $entry.name) { throw "Apply -Rollback stopped: the pre-pool container $($entry.name) ($($entry.id)) is $(if ($found.State -eq 'present') { "named $($found.Name)" } else { $found.State }). $($found.Reason) The journal is kept." }
        if ($found.RestartPolicy -ne $entry.restart) {
            $update = Invoke-Docker @('update', "--restart=$($entry.restart)", $entry.id)
            if ($update.ExitCode -ne 0) { throw "Apply -Rollback stopped: docker update --restart=$($entry.restart) $($entry.name) exited $($update.ExitCode): $($update.Output) The journal is kept." }
        }
        if (-not $found.Running) {
            $start = Invoke-Docker @('start', $entry.id)
            if ($start.ExitCode -ne 0) { throw "Apply -Rollback stopped: docker start $($entry.name) exited $($start.ExitCode): $($start.Output) The journal is kept." }
        }
    }
    # Maintenance last: the pre-pool entrypoint waits while the record exists, so exactly one listener starts here.
    if ($null -ne $held) { Complete-OperationMaintenance @{ name = 'rollback'; heldBefore = $held } $target.StateFile $target.Directory | Out-Null }
    Write-LinuxComposeFile @(Get-LinuxSlots $Config $Inventory | Where-Object { $_.Composed }) | Out-Null
    Remove-HostOperation
    "Rolled back operation $($Operation.id): linux-01 runs on the pre-pool containers again$(if ($held) { ' (still held; -Action Resume ends that)' }). The inventory was not changed."
}

# --- Apply: adding and retiring slots.
#
# add-slot, one journaled operation per slot (steps provision, register, create, verify, commit): the slot is recorded as
# provisioning before anything exists for it, registered (Linux: config.sh in a throwaway container of the pinned image on
# the slot's own directory; Windows: its own clone InstallRoot\winNN set up and installed), started (Linux: the slot's
# compose services, sidecar first), verified (GitHub reports the recorded runner ID under the slot's name, online), and
# committed active. The runner ID is journaled and recorded the moment it is known, so a crash never leaves a registration
# nobody owns.
#
# retire-slot (steps withdraw, drain, stop, deregister, clear-local, remove-containers, commit): heldBefore is journaled and
# the slot marked retiring, the runner drained (a timeout puts the slot back to active and deletes the journal), stopped,
# removed at GitHub by its recorded ID, its local registration deleted, its containers removed (only the recorded ones or
# this host's compose ones for that slot), and the slot recorded retired. Its directory, clone and volumes stay for Prune.

$AddKind = 'add-slot'
$AddSteps = @('provision', 'register', 'create', 'verify', 'commit')
$RetireKind = 'retire-slot'
$RetireSteps = @('withdraw', 'drain', 'stop', 'deregister', 'clear-local', 'remove-containers', 'commit')
$script:ApplyExit = 0

function Set-RecordValue($Record, [string] $Name, $Value) { $Record | Add-Member -Force -NotePropertyName $Name -NotePropertyValue $Value }

function Save-Inventory($Inventory) {
    Set-RecordValue $Inventory 'generation' ([int]$Inventory.generation + 1)
    Write-HostInventory $Inventory
}

# The names Get-LinuxSlots or Get-WindowsSlots gives a recorded slot, whatever state it is in now.
function Get-RecordRow($Record) {
    $probe = [pscustomobject]@{ slots = @([pscustomobject]@{ slotId = $Record.slotId; platform = $Record.platform; state = 'active'; legacy = [bool]$Record.legacy; containers = @($Record.containers) }) }
    $rows = if ($Record.platform -eq 'linux') { Get-LinuxSlots $Config $probe $null } else { Get-WindowsSlots $Config $probe $null -InstallRoot $InstallRoot }
    $row = @($rows) | Select-Object -First 1
    if ($row -and $Record.platform -eq 'windows' -and $Record.PSObject.Properties['installPath'] -and $Record.installPath) { $row.InstallPath = [string]$Record.installPath }
    $row
}

# Every live composed Linux slot, whatever the count says: a slot waiting to be retired still runs on compose.
function Get-ComposedLinuxSlots($Inventory) { @(Get-LinuxSlots $Config $Inventory $null | Where-Object Composed) }

# Why no slot can be added now, or $null. Checked once, before any add.
function Get-AddBlocker($Inventory, $Adds) {
    $scope = Get-InventoryScope $Inventory
    if (-not $scope) { return 'no GitHub scope is known (no inventory scope and no github.url).' }
    $group = Test-RunnerGroup $scope @()
    if ($group.state -in 'blocked', 'unknown') { return "the runner group check is $($group.state): $(@($group.findings | ForEach-Object { $_.message }) -join ' ')" }
    $linux = @($Adds | Where-Object { $_.platform -eq 'linux' })
    $windows = @($Adds | Where-Object { $_.platform -eq 'windows' })
    if ($windows.Count -and -not $IsWindows) { return 'Windows slots are added only on Windows.' }
    if ($windows.Count -and -not $InstallRoot) { return 'no -InstallRoot is known for the Windows clones.' }
    $paths = @(@(if ($linux.Count) { $Root }) + @(if ($windows.Count) { $InstallRoot }))
    foreach ($disk in @(Get-FreeDiskReport $paths)) {
        if ($disk.Low) { return "drive $($disk.Drive) has $($disk.FreeGB) GB free, below housekeeping.minFreeGB ($($disk.MinimumGB) GB)." }
    }
    $null
}

# Before Linux adds: builds the image when it is missing or was built from another context (S4: the image is rebuilt on a
# mismatch), so a fresh host needs no separate build step. Returns why the Linux adds cannot go ahead, or $null. Only the
# Linux adds depend on it: the Windows adds go ahead either way.
function Get-LinuxImageBlocker {
    $image = Get-ImageId $Config.linux.image
    if ($image.State -eq 'unknown') { return "whether the image $($Config.linux.image) exists is unknown ($($image.Reason))." }
    if ($image.State -eq 'present' -and -not (Test-LinuxImageStale)) { return $null }
    try {
        $build = Get-LinuxImageBuild $Config $Root
        Write-Host "Building $($Config.linux.image) on $($Config.linux.baseImage)."
        Invoke-LinuxImageBuild $Config $Root $build
    } catch { return "the image $($Config.linux.image) could not be built: $($_.Exception.Message)" }
    if ((Get-ImageId $Config.linux.image).State -ne 'present') { return "the image $($Config.linux.image) is still not there after building it." }
    $null
}

# The compose containers a Linux slot would get: absent, or already this host's compose ones for that slot.
function Assert-LinuxNamesFree($Row) {
    foreach ($name in @($Row.Container, $Row.DockerContainer) | Where-Object { $_ }) {
        $found = Get-ContainerRecord $name
        if ($found.State -eq 'unknown') { throw "Apply refused: whether a container named $name exists is unknown ($($found.Reason)). Nothing was changed." }
        if ($found.State -eq 'present' -and -not (Test-OurComposeContainer $found $Row.SlotId)) { throw "Apply refused: a container named $name ($($found.Id)) exists and is not this host's compose $($Row.SlotId). Nothing was changed." }
    }
}

function Invoke-AddProvision($Operation, $Step, $Inventory, $Row) {
    $record = Get-InventorySlot $Inventory $Row.SlotId
    if (-not $record) {
        $directory = if ($Row.Platform -eq 'linux') { Join-Path $Root $Row.Directory } else { Join-Path $Row.InstallPath $Config.windows.directory }
        $record = [pscustomobject][ordered]@{
            slotId = $Row.SlotId; platform = $Row.Platform; state = 'provisioning'; legacy = $false
            runnerName = $Row.RunnerName; scope = (Get-InventoryScope $Inventory)
            registrationDirectory = (Get-CanonicalPath $directory); containers = @()
            provisionedUtc = [DateTime]::UtcNow.ToString('o'); operationId = $Operation.id
        }
        if ($Row.Platform -eq 'windows') { Set-RecordValue $record 'installPath' (Get-CanonicalPath $Row.InstallPath) }
        Set-RecordValue $Inventory 'slots' @(@($Inventory.slots | Where-Object { $_ }) + $record)
        Save-Inventory $Inventory
    } elseif ($record.state -ne 'provisioning') {
        throw "Apply stopped: $($Row.SlotId) is $($record.state) in the inventory, not provisioning. The journal is kept."
    }
    if ($Row.Platform -eq 'linux') { New-Item -ItemType Directory -Force -Path $record.registrationDirectory | Out-Null }
    Complete-OperationStep $Operation $Step
}

# The registration the slot's directory holds, checked against the slot's name, recorded in the journal and the inventory.
function Save-AddRegistration($Operation, $Step, $Inventory, $Record) {
    $registration = Get-LocalRegistration ([string]$Record.registrationDirectory)
    if (-not $registration -or -not $registration.agentId) { throw "Apply stopped at register: $($Record.registrationDirectory)\.runner records no agentId. The journal is kept." }
    if ($registration.agentName -ine $Record.runnerName) { throw "Apply stopped at register: $($Record.registrationDirectory)\.runner is $($registration.agentName), not $($Record.runnerName). The journal is kept." }
    Set-StepFact $Operation $Step 'runnerId' ([int64]$registration.agentId)
    Set-RecordValue $Record 'runnerId' ([int64]$registration.agentId)
    Save-Inventory $Inventory
}

function Invoke-AddRegister($Operation, $Step, $Inventory, $Row, $Record) {
    $dir = [string]$Record.registrationDirectory
    if (-not (Get-LocalRegistration $dir)) {
        $scope = [string]$Record.scope
        if ($Row.Platform -eq 'linux') {
            $arguments = @('configure', '--unattended', '--url', $Config.github.url, '--name', $Record.runnerName, '--labels', ($Row.Labels -join ','), '--work', $Config.linux.workFolder)
            $orphan = Get-GitHubRunner $scope $Record.runnerName
            if ($orphan) {
                "  GitHub already has a runner named $($Record.runnerName) (id $($orphan.Id)) that no registration here owns; it is replaced."
                $arguments += '--replace'
            }
            $token = Get-RunnerToken $scope 'registration'
            $run = Invoke-Docker (@('run', '--rm', '--mount', "type=bind,source=$dir,target=/runner", $Config.linux.image) + $arguments + @('--token', $token))
            if ($run.ExitCode -ne 0) {
                $output = "$($run.Output)".Replace($token, '***')
                throw "Apply stopped at register: configuring $($Record.runnerName) exited $($run.ExitCode): $output The journal is kept."
            }
        } else {
            $clone = [string]$Record.installPath
            Sync-RunnerSetupInstance -Clone $clone -InstanceId $Row.InstanceId -SourceCommit (Get-GitCommit $Root) -GitHubUrl $Config.github.url
            Write-HostSettings -Clone $clone -Settings (New-HostSettings $Config $Row)
            Install-RunnerSetupInstance -Clone $clone -InstanceId $Row.InstanceId -GitHubUrl $Config.github.url -Labels $Row.HostLabels -Name $Record.runnerName | Out-Host
        }
    }
    Save-AddRegistration $Operation $Step $Inventory $Record
    Complete-OperationStep $Operation $Step
}

function Invoke-AddCreate($Operation, $Step, $Inventory, $Row) {
    if ($Row.Platform -eq 'linux') {
        Initialize-LinuxSlotResources $Config $Row
        $file = Write-LinuxComposeFile (Get-ComposedLinuxSlots $Inventory)
        $new = [Collections.Generic.List[object]]::new()
        foreach ($entry in @(Get-StepFact $Step 'new')) { $new.Add($entry) }
        $journaled = @($new | ForEach-Object { $_.id })
        $wanted = @(@(if ($Row.DockerContainer) { [pscustomobject]@{ role = 'docker'; name = $Row.DockerContainer; service = "$($Row.SlotId)-docker" } }) + [pscustomobject]@{ role = 'runner'; name = $Row.Container; service = $Row.SlotId })
        foreach ($item in $wanted) {
            $found = Get-ContainerRecord $item.name
            if ($found.State -eq 'unknown') { throw "Apply stopped: whether $($item.name) exists is unknown ($($found.Reason)). The journal is kept." }
            if ($found.State -eq 'present' -and $found.Id -notin $journaled -and -not (Test-OurComposeContainer $found $Row.SlotId)) { throw "Apply stopped: a container named $($item.name) ($($found.Id)) exists and is not this host's compose $($Row.SlotId). The journal is kept." }
            $up = Invoke-LinuxCompose -File $file -Verb up -Services @($item.service)
            if ($up.ExitCode -ne 0) { throw "Apply stopped: compose up $($item.service) exited $($up.ExitCode): $($up.Output) The journal is kept." }
            $created = Get-ContainerRecord $item.name
            if ($created.State -ne 'present') { throw "Apply stopped: $($item.name) is $($created.State) after compose up. $($created.Reason) The journal is kept." }
            if ($created.Id -notin $journaled) {
                @($new | Where-Object { $_.role -eq $item.role }) | ForEach-Object { [void]$new.Remove($_) }
                $new.Add([pscustomobject][ordered]@{ role = $item.role; name = $created.Name; id = $created.Id })
                Set-StepFact $Operation $Step 'new' $new.ToArray()
            }
            if ($item.role -eq 'docker' -and -not (Wait-ComposeSidecarReady $item.name)) { throw "Apply stopped: the Docker sidecar $($item.name) did not become ready. The journal is kept." }
        }
    }
    Complete-OperationStep $Operation $Step
}

# The slot's runner is running (Linux: the container the create step journaled) and GitHub reports it online under its name.
function Invoke-AddVerify($Operation, $Step, $Record, [string] $CreateStep = 'create') {
    $runnerId = [int64]$Record.runnerId
    $newRunner = @(Get-StepFact (Get-OperationStep $Operation $CreateStep) 'new' | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
    $deadline = [DateTime]::UtcNow.AddSeconds([int]$Config.lifecycle.startTimeoutSeconds)
    while ($true) {
        $why = $null
        if ($Record.platform -eq 'linux') {
            $container = Get-ContainerRecord $newRunner.id
            if ($container.State -ne 'present' -or $container.Name -ne $newRunner.name) { $why = "the container $($newRunner.name) ($($newRunner.id)) is $($container.State) $($container.Reason)" }
            elseif (-not $container.Running) { $why = "the container $($newRunner.name) is not running" }
        }
        if (-not $why) {
            $listing = Get-ScopeRunners ([string]$Record.scope)
            $match = if ($listing.State -eq 'known') { $listing.Runners | Where-Object { [int64]$_.id -eq $runnerId } | Select-Object -First 1 }
            $why = if ($listing.State -ne 'known') { "GitHub could not be read ($($listing.Reason))" }
            elseif (-not $match) { "GitHub has no runner with id $runnerId" }
            elseif ($match.name -ne $Record.runnerName) { "GitHub's runner $runnerId is named $($match.name), not $($Record.runnerName)" }
            elseif ($match.status -ne 'online') { "GitHub reports runner $runnerId $($match.status)" }
        }
        if (-not $why) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Apply stopped at verify of $($Record.slotId): $why. The journal is kept; rerun Apply to check again." }
        Start-Sleep -Seconds ([Math]::Max(1, [int]$Config.lifecycle.pollSeconds))
    }
    Complete-OperationStep $Operation $Step
}

# The containers a step journaled as new, as the inventory records them (runner first).
function Get-JournaledContainers($Operation, [string] $StepName) {
    @(foreach ($entry in Get-RunnerFirst @(Get-StepFact (Get-OperationStep $Operation $StepName) 'new')) {
            $found = Get-ContainerRecord $entry.id
            if ($found.State -ne 'present') { throw "Apply stopped at commit: the new container $($entry.name) ($($entry.id)) is $($found.State). $($found.Reason) The journal is kept." }
            [ordered]@{ role = $entry.role; id = $found.Id; name = $found.Name; image = $found.Image; labels = $found.Labels }
        })
}

function Set-WindowsCloneRecord($Record) {
    $clone = [string]$Record.installPath
    Set-RecordValue $Record 'sourceCommit' (Get-GitCommit $clone)
    Set-RecordValue $Record 'generatedSettingsHash' (Get-HostSettingsRecord -Clone $clone)
}

function Invoke-AddCommit($Operation, $Step, $Inventory, $Record) {
    if ($Record.platform -eq 'linux') {
        Set-RecordValue $Record 'containers' @(Get-JournaledContainers $Operation 'create')
    } else {
        $registration = Get-LocalRegistration ([string]$Record.registrationDirectory)
        Set-RecordValue $Record 'workPath' (Resolve-RunnerWorkFolder $(if ($registration.workFolder) { $registration.workFolder } else { $Config.windows.workFolder }) $Record.registrationDirectory)
        Set-WindowsCloneRecord $Record
    }
    $Record.state = 'active'
    Set-RecordValue $Record 'addedUtc' ([DateTime]::UtcNow.ToString('o'))
    Save-Inventory $Inventory
    Complete-OperationStep $Operation $Step
    Remove-HostOperation
}

function Invoke-SlotAdd($Inventory, $Operation, [string] $SlotId, [string] $Platform) {
    if ($Operation) { $Platform = [string]$Operation.platform }
    $row = Get-RecordRow ([pscustomobject]@{ slotId = $SlotId; platform = $Platform; legacy = $false; containers = @() })
    if (-not $row) { throw "Apply stopped: no $Platform slot $SlotId can be named." }
    if ($Platform -eq 'windows' -and -not $row.InstallPath) { throw "Apply stopped: no -InstallRoot is known for $SlotId's clone." }
    if (-not $Operation) {
        if ($Platform -eq 'linux') { Assert-LinuxNamesFree $row }
        $Operation = New-HostOperation -Kind $AddKind -SlotId $SlotId -Steps $AddSteps
        Set-RecordValue $Operation 'platform' $Platform
        Write-HostOperation $Operation
        "Adding $SlotId ($($row.RunnerName)): operation $($Operation.id)."
    } else { "Resuming operation $($Operation.id) ($AddKind) on $SlotId." }
    foreach ($step in @($Operation.steps)) {
        if ($step.state -eq 'done') { continue }
        $record = Get-InventorySlot $Inventory $SlotId
        if ($step.name -ne 'provision' -and -not $record) { throw "Apply stopped: the inventory has no slot $SlotId although operation $($Operation.id) provisioned it. The journal is kept." }
        switch ($step.name) {
            'provision' { Invoke-AddProvision $Operation $step $Inventory $row }
            'register' { Invoke-AddRegister $Operation $step $Inventory $row $record }
            'create' { Invoke-AddCreate $Operation $step $Inventory $row }
            'verify' { Invoke-AddVerify $Operation $step $record }
            'commit' { Invoke-AddCommit $Operation $step $Inventory $record }
            default { throw "Apply stopped: operation $($Operation.id) has an unknown step '$($step.name)'. The journal is kept." }
        }
        "  $($step.name): done"
    }
    $record = Get-InventorySlot $Inventory $SlotId
    "$SlotId is active as $($record.runnerName) with runner id $($record.runnerId)."
}

# A drain that ended without a hold: the slot goes back to active and the journal is deleted, so nothing is half-retired.
function Undo-RetireStart($Inventory, $Record, [string] $Why) {
    $Record.state = 'active'
    Save-Inventory $Inventory
    Remove-HostOperation
    throw "Apply stopped: $Why The retire of $($Record.slotId) was not started (state back to active, journal deleted); rerun Apply -Retire when it is idle."
}

function Invoke-RetireWithdraw($Operation, $Step, $Inventory, $Record) {
    if ($null -eq (Get-StepFact $Step 'heldBefore')) {
        Set-StepFact $Operation $Step 'heldBefore' (Get-HeldBefore (Join-Path ([string]$Record.registrationDirectory) 'maintenance.json'))
    }
    if ($Record.state -ne 'retiring') {
        $Record.state = 'retiring'
        Save-Inventory $Inventory
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-RetireDrain($Operation, $Step, $Inventory, $Record) {
    $dir = [string]$Record.registrationDirectory
    $file = Join-Path $dir 'maintenance.json'
    if (-not (Get-StepFact (Get-OperationStep $Operation 'withdraw') 'heldBefore')) {
        if ($Record.platform -eq 'linux') {
            $runner = @($Record.containers | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
            $busy = if ($runner) { Get-RunnerBusyCheck $runner.name } else { { $false } }
            $drain = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory $dir -IsBusy $busy -Reason 'retire' -TimeoutMinutes $Config.lifecycle.drainTimeoutMinutes
            if ($drain.Outcome -eq 'timeout') { Undo-RetireStart $Inventory $Record $drain.Retained }
            if ($drain.Outcome -eq 'failed') { throw "Apply stopped in the drain of $($Record.slotId): $(@($drain.Failures) -join ' ') The journal is kept; rerun Apply -Retire." }
        } else {
            $result = Invoke-InstanceAction $Record 'Maintenance'
            if ($result.ExitCode -ne 0) {
                if (Test-Path -LiteralPath $file) { throw "Apply stopped in the drain of $($Record.slotId) (exit $($result.ExitCode)): $($result.Output) The journal is kept; rerun Apply -Retire." }
                Undo-RetireStart $Inventory $Record "$($Record.slotId) did not drain (exit $($result.ExitCode)): $($result.Output)"
            }
        }
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-RetireStop($Operation, $Step, $Record) {
    if ($Record.platform -eq 'linux') {
        foreach ($entry in Get-RunnerFirst @($Record.containers)) {
            $found = Get-ContainerRecord $entry.id
            if ($found.State -eq 'absent') { continue }
            if ($found.State -eq 'unknown') { throw "Apply stopped: whether $($entry.name) ($($entry.id)) exists is unknown ($($found.Reason)). The journal is kept." }
            if ($found.Name -ne $entry.name) { throw "Apply stopped: the recorded container $($entry.id) is now named $($found.Name), not $($entry.name). The journal is kept." }
            $stop = Stop-LinuxContainer $found.Id
            if ($stop.Result -eq 'failed') { throw "Apply stopped: $($stop.Detail) The journal is kept." }
        }
    }
    # A Windows slot was stopped and held by its own Maintenance action in the drain.
    Complete-OperationStep $Operation $Step
}

function Invoke-RetireDeregister($Operation, $Step, $Inventory, $Record) {
    $scope = if ($Record.scope) { [string]$Record.scope } else { Get-InventoryScope $Inventory }
    $runner = Get-GitHubRunner $scope $Record.runnerName
    if (-not $runner) { "  GitHub has no runner named $($Record.runnerName); nothing to remove there." }
    elseif ($Record.runnerId -and [int64]$runner.Id -ne [int64]$Record.runnerId) { "  GitHub's $($Record.runnerName) is id $($runner.Id), not the recorded $($Record.runnerId); it is not this slot's and is left alone." }
    else {
        try { Remove-GitHubRunner $scope $runner.Id }
        catch { if ($_.Exception.Message -notmatch '404|Not Found') { throw } }
    }
    Set-StepFact $Operation $Step 'deregistered' $true
    Complete-OperationStep $Operation $Step
}

function Invoke-RetireClearLocal($Operation, $Step, $Record) {
    foreach ($name in '.runner', '.credentials', '.credentials_rsaparams') {
        $path = Join-Path ([string]$Record.registrationDirectory) $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-RetireRemoveContainers($Operation, $Step, $Record) {
    if ($Record.platform -eq 'linux') {
        foreach ($entry in Get-RunnerFirst @($Record.containers)) {
            $found = Get-ContainerRecord $entry.id
            if ($found.State -eq 'absent') { continue }
            if ($found.State -eq 'unknown') { throw "Apply stopped: whether $($entry.name) ($($entry.id)) exists is unknown ($($found.Reason)). The journal is kept." }
            if ($found.Name -ne $entry.name -and -not (Test-OurComposeContainer $found $Record.slotId)) { throw "Apply stopped: the recorded container $($entry.id) is now named $($found.Name), not $($entry.name); it was left alone. The journal is kept." }
            $removed = Remove-LinuxContainer $found.Id
            if ($removed.Result -eq 'failed') { throw "Apply stopped: $($removed.Detail) The journal is kept." }
        }
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-RetireCommit($Operation, $Step, $Inventory, $Record) {
    $Record.state = 'retired'
    Set-RecordValue $Record 'retiredUtc' ([DateTime]::UtcNow.ToString('o'))
    Save-Inventory $Inventory
    if ($Record.platform -eq 'linux') { Write-LinuxComposeFile (Get-ComposedLinuxSlots $Inventory) | Out-Null }
    Complete-OperationStep $Operation $Step
    Remove-HostOperation
}

function Invoke-SlotRetire($Inventory, $Operation, [string] $SlotId) {
    $record = Get-InventorySlot $Inventory $SlotId
    if (-not $record) { throw "Apply stopped: the inventory has no slot $SlotId to retire." }
    if (-not $Operation) {
        if ($record.state -ne 'active') { throw "Apply refused: $SlotId is $($record.state), not active." }
        if (-not $record.registrationDirectory) { throw "Apply refused: $SlotId records no registration directory." }
        $Operation = New-HostOperation -Kind $RetireKind -SlotId $SlotId -Steps $RetireSteps
        Set-RecordValue $Operation 'platform' ([string]$record.platform)
        Write-HostOperation $Operation
        "Retiring $SlotId ($($record.runnerName), id $($record.runnerId)): operation $($Operation.id)."
    } else { "Resuming operation $($Operation.id) ($RetireKind) on $SlotId." }
    foreach ($step in @($Operation.steps)) {
        if ($step.state -eq 'done') { continue }
        switch ($step.name) {
            'withdraw' { Invoke-RetireWithdraw $Operation $step $Inventory $record }
            'drain' { Invoke-RetireDrain $Operation $step $Inventory $record }
            'stop' { Invoke-RetireStop $Operation $step $record }
            'deregister' { Invoke-RetireDeregister $Operation $step $Inventory $record }
            'clear-local' { Invoke-RetireClearLocal $Operation $step $record }
            'remove-containers' { Invoke-RetireRemoveContainers $Operation $step $record }
            'commit' { Invoke-RetireCommit $Operation $step $Inventory $record }
            default { throw "Apply stopped: operation $($Operation.id) has an unknown step '$($step.name)'. The journal is kept." }
        }
        "  $($step.name): done"
    }
    "$SlotId is retired. What it left on disk (directory, clone, volumes) stays until Apply -Prune."
}

# --- Apply: updating a drifted slot.
#
# update-slot, one journaled operation per slot (steps drain, change, resume, verify, commit): heldBefore is journaled and
# the runner drained (a busy runner that does not drain in time is left as it is and the journal deleted: deferred: busy),
# changed (Linux: its own compose services recreated, sidecar then runner, never down; Windows: its clone synced to this
# checkout and its host settings written), started again (maintenance ended only because this operation began it),
# verified online at GitHub, and the new containers or clone state recorded.

$UpdateKind = 'update-slot'
$UpdateSteps = @('drain', 'change', 'resume', 'verify', 'commit')

function Get-SlotMaintenanceFile($Record) { Join-Path ([string]$Record.registrationDirectory) 'maintenance.json' }

# Drains the slot. Returns why it was not drained ("busy: ...") for a runner that stayed busy, else $null.
function Invoke-UpdateDrain($Operation, $Step, $Record) {
    $file = Get-SlotMaintenanceFile $Record
    if ($null -eq (Get-StepFact $Step 'heldBefore')) { Set-StepFact $Operation $Step 'heldBefore' (Get-HeldBefore $file) }
    if (Get-StepFact $Step 'heldBefore') { throw "Apply stopped: $($Record.slotId) was held before its update began; Resume it, then rerun Apply. The journal is kept." }
    if ($Record.platform -eq 'linux') {
        $runner = @($Record.containers | Where-Object { $_.role -eq 'runner' }) | Select-Object -First 1
        $busy = if ($runner) { Get-RunnerBusyCheck $runner.name } else { { $false } }
        $drain = Enter-RunnerMaintenance -StateFile $file -RunnerDirectory ([string]$Record.registrationDirectory) -IsBusy $busy -Reason 'update' -TimeoutMinutes $Config.lifecycle.drainTimeoutMinutes
        if ($drain.Outcome -eq 'timeout') { return "busy: $($drain.Retained)" }
        if ($drain.Outcome -eq 'failed') { throw "Apply stopped in the drain of $($Record.slotId): $(@($drain.Failures) -join ' ') The journal is kept; rerun Apply." }
    } else {
        $result = Invoke-InstanceAction $Record 'Maintenance'
        if ($result.ExitCode -ne 0) {
            if (Test-Path -LiteralPath $file) { throw "Apply stopped in the drain of $($Record.slotId) (exit $($result.ExitCode)): $($result.Output) The journal is kept; rerun Apply." }
            return "busy: $($Record.slotId) did not drain (exit $($result.ExitCode)): $($result.Output)"
        }
    }
    Complete-OperationStep $Operation $Step
    $null
}

function Invoke-UpdateChange($Operation, $Step, $Inventory, $Record) {
    $row = Get-RecordRow $Record
    if ($Record.platform -eq 'linux') {
        Initialize-LinuxSlotResources $Config $row
        $file = Write-LinuxComposeFile (Get-ComposedLinuxSlots $Inventory)
        $new = [Collections.Generic.List[object]]::new()
        foreach ($entry in @(Get-StepFact $Step 'new')) { $new.Add($entry) }
        $recorded = @($Record.containers | ForEach-Object { $_.id })
        $wanted = @(@(if ($row.DockerContainer) { [pscustomobject]@{ role = 'docker'; name = $row.DockerContainer; service = "$($row.SlotId)-docker" } }) + [pscustomobject]@{ role = 'runner'; name = $row.Container; service = $row.SlotId })
        foreach ($item in $wanted) {
            $journaled = @($new | Where-Object { $_.role -eq $item.role } | ForEach-Object { $_.id })
            $found = Get-ContainerRecord $item.name
            if ($found.State -eq 'unknown') { throw "Apply stopped: whether $($item.name) exists is unknown ($($found.Reason)). The journal is kept." }
            if ($found.State -eq 'present' -and $found.Id -in $journaled) {
                # Recreated by an earlier run of this step.
            } else {
                if ($found.State -eq 'present' -and $found.Id -notin $recorded -and -not (Test-OurComposeContainer $found $row.SlotId)) { throw "Apply stopped: a container named $($item.name) ($($found.Id)) exists and is not this host's compose $($row.SlotId). The journal is kept." }
                $up = Invoke-LinuxCompose -File $file -Verb up -Services @($item.service) -ForceRecreate
                if ($up.ExitCode -ne 0) { throw "Apply stopped: compose up $($item.service) exited $($up.ExitCode): $($up.Output) The journal is kept." }
                $created = Get-ContainerRecord $item.name
                if ($created.State -ne 'present') { throw "Apply stopped: $($item.name) is $($created.State) after compose up. $($created.Reason) The journal is kept." }
                @($new | Where-Object { $_.role -eq $item.role }) | ForEach-Object { [void]$new.Remove($_) }
                $new.Add([pscustomobject][ordered]@{ role = $item.role; name = $created.Name; id = $created.Id })
                Set-StepFact $Operation $Step 'new' $new.ToArray()
            }
            if ($item.role -eq 'docker' -and -not (Wait-ComposeSidecarReady $item.name)) { throw "Apply stopped: the Docker sidecar $($item.name) did not become ready. The journal is kept." }
        }
    } else {
        $clone = [string]$Record.installPath
        Sync-RunnerSetupInstance -Clone $clone -InstanceId $row.InstanceId -SourceCommit (Get-GitCommit $Root) -GitHubUrl $Config.github.url
        Write-HostSettings -Clone $clone -Settings (New-HostSettings $Config $row)
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-UpdateResume($Operation, $Step, $Record) {
    if ($Record.platform -eq 'linux') {
        $held = Get-StepFact (Get-OperationStep $Operation 'drain') 'heldBefore'
        Complete-OperationMaintenance ([pscustomobject]@{ name = 'resume'; heldBefore = $held }) (Get-SlotMaintenanceFile $Record) ([string]$Record.registrationDirectory) | Out-Null
    } else {
        $result = Invoke-InstanceAction $Record 'Start'
        if ($result.ExitCode -ne 0) { throw "Apply stopped: starting $($Record.slotId) exited $($result.ExitCode): $($result.Output) The journal is kept; rerun Apply." }
    }
    Complete-OperationStep $Operation $Step
}

function Invoke-UpdateCommit($Operation, $Step, $Inventory, $Record) {
    if ($Record.platform -eq 'linux') { Set-RecordValue $Record 'containers' @(Get-JournaledContainers $Operation 'change') }
    else { Set-WindowsCloneRecord $Record }
    Set-RecordValue $Record 'updatedUtc' ([DateTime]::UtcNow.ToString('o'))
    Save-Inventory $Inventory
    Complete-OperationStep $Operation $Step
    Remove-HostOperation
}

function Invoke-SlotUpdate($Inventory, $Operation, [string] $SlotId, [string[]] $Reasons) {
    $record = Get-InventorySlot $Inventory $SlotId
    if (-not $record) { throw "Apply stopped: the inventory has no slot $SlotId to update." }
    if (-not $Operation) {
        if ($record.state -ne 'active') { "Not updated: $SlotId is $($record.state), not active."; $script:ApplyExit = 3; return }
        if (Test-Path -LiteralPath (Get-SlotMaintenanceFile $record)) { "Deferred: $SlotId is held; Resume it, then rerun Apply (deferred: held)."; $script:ApplyExit = 3; return }
        if ($record.platform -eq 'linux') {
            $row = @(Get-LinuxSlots $Config $Inventory $null | Where-Object { $_.SlotId -eq $SlotId }) | Select-Object -First 1
            if (-not $row -or -not $row.Composed) { "Not updated: $SlotId does not run on compose yet."; $script:ApplyExit = 3; return }
        } elseif ('clone' -in $Reasons -or -not $record.installPath) {
            $script:HostFailed = $true
            [Console]::Error.WriteLine("Not updated: $SlotId's clone $($record.installPath) does not exist; it is not recreated by an update.")
            return
        }
        $Operation = New-HostOperation -Kind $UpdateKind -SlotId $SlotId -Steps $UpdateSteps
        Set-RecordValue $Operation 'platform' ([string]$record.platform)
        Write-HostOperation $Operation
        "Updating $SlotId ($($record.runnerName))$(if ($Reasons.Count) { " for $($Reasons -join ', ')" }): operation $($Operation.id)."
    } else { "Resuming operation $($Operation.id) ($UpdateKind) on $SlotId." }
    foreach ($step in @($Operation.steps)) {
        if ($step.state -eq 'done') { continue }
        switch ($step.name) {
            'drain' {
                $deferred = Invoke-UpdateDrain $Operation $step $record
                if ($deferred) {
                    Remove-HostOperation
                    "Deferred: $SlotId is busy and was left as it is; rerun Apply when it is idle (deferred: $deferred)."
                    $script:ApplyExit = 3
                    return
                }
            }
            'change' { Invoke-UpdateChange $Operation $step $Inventory $record }
            'resume' { Invoke-UpdateResume $Operation $step $record }
            'verify' { Invoke-AddVerify $Operation $step $record -CreateStep 'change' }
            'commit' { Invoke-UpdateCommit $Operation $step $Inventory $record }
            default { throw "Apply stopped: operation $($Operation.id) has an unknown step '$($step.name)'. The journal is kept." }
        }
        "  $($step.name): done"
    }
    "$SlotId is updated."
}

# Whether the built Linux image is missing or not the one the settings build (base image, runner version, archive).
function Test-LinuxImageStale {
    if ((Get-ImageId $Config.linux.image).State -ne 'present') { return $true }
    $expected = Get-LinuxExpectedContextHash $Config $Root
    [bool]($expected -and (Get-LinuxImageContextHash $Config.linux.image) -ne $expected)
}

# windows-legacy goes only once win01 runs: active, with a runner ID GitHub reports online. Returns why not, or $null.
function Get-LegacyRetireBlocker($Inventory) {
    $win01 = Get-InventorySlot $Inventory 'win01'
    if (-not $win01 -or $win01.state -ne 'active' -or -not $win01.runnerId) { return 'win01 is not active yet.' }
    $listing = Get-ScopeRunners $(if ($win01.scope) { [string]$win01.scope } else { Get-InventoryScope $Inventory })
    if ($listing.State -ne 'known') { return "GitHub could not be read to see win01 online ($($listing.Reason))." }
    $runner = $listing.Runners | Where-Object { [int64]$_.id -eq [int64]$win01.runnerId } | Select-Object -First 1
    if (-not $runner -or $runner.status -ne 'online') { return "GitHub does not report win01 (id $($win01.runnerId)) online." }
    $null
}

# --- Apply -Prune: what a migration kept for rollback, and what retired slots left.

# A kept container is removed only when the recorded ID still names a stopped container with the recorded name; one that is
# gone is dropped from the record; anything else is kept and reported.
function Invoke-PruneKept($Inventory, $Slot) {
    $changed = $false
    $remaining = [Collections.Generic.List[object]]::new()
    foreach ($entry in Get-RunnerFirst @($Slot.keptForRollback)) {
        $found = Get-ContainerRecord $entry.id
        $keep = $null
        switch ($found.State) {
            'absent' { "$($Slot.slotId): $($entry.name) ($($entry.id)) is already gone; record dropped." }
            'unknown' { $keep = "whether it exists is unknown ($($found.Reason))" }
            default {
                if ($found.Id -ne $entry.id) { $keep = "docker reports it as $($found.Id), not the recorded ID" }
                elseif ($found.Name -ne $entry.name) { $keep = "it is now named $($found.Name), not $($entry.name)" }
                elseif ($found.Running -ne $false) { $keep = 'it is running' }
                else {
                    $remove = Invoke-Docker @('rm', $entry.id)
                    $after = Get-ContainerRecord $entry.id
                    if ($after.State -eq 'absent') { "$($Slot.slotId): removed $($entry.name) ($($entry.id))." }
                    else { $keep = "docker rm exited $($remove.ExitCode): $($remove.Output) and it is still $($after.State)" }
                }
            }
        }
        if ($keep) {
            $remaining.Add($entry)
            $script:HostFailed = $true
            [Console]::Error.WriteLine("$($Slot.slotId): kept $($entry.name) ($($entry.id)): $keep. Nothing else under that name is touched.")
        } else { $changed = $true }
    }
    Set-RecordValue $Slot 'keptForRollback' $remaining.ToArray()
    $changed
}

# Removes a Docker volume or network by name; gone already counts as removed. Returns why it is kept, or $null.
function Remove-DockerObject([string] $Kind, [string] $Name) {
    $result = Invoke-Docker @($Kind, 'rm', $Name)
    if ($result.ExitCode -eq 0) { return $null }
    if ($null -ne $result.ExitCode -and $result.Output -match 'No such|not found') { return $null }
    "docker $Kind rm $Name exited $($result.ExitCode): $($result.Output)"
}

# What a retired slot left: the Linux directory and volumes (and the sidecar network), or the Windows clone. The clone of
# windows-legacy is this checkout and is never removed. The slot becomes pruned only when nothing is left.
function Invoke-PruneRetired($Slot) {
    $kept = [Collections.Generic.List[string]]::new()
    $row = Get-RecordRow $Slot
    if ($Slot.platform -eq 'linux') {
        $dir = [string]$Slot.registrationDirectory
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            if (-not (Test-PathUnder $dir $Root)) { $kept.Add("$dir is not inside $Root") }
            elseif (-not (Remove-PathBounded -Path $dir)) { $kept.Add("$dir is still in use") }
        }
        $volumes = @($row.Volumes.Cache)
        if ($Config.linux.docker.mode -eq 'sidecar') { $volumes += @($row.Volumes.DockerData, $row.Volumes.DockerCerts, $row.Volumes.Work, $row.Volumes.Runtimes) }
        elseif ($Config.linux.docker.mode -eq 'dind') { $volumes += $row.Volumes.Dind }
        foreach ($volume in $volumes | Where-Object { $_ }) { $why = Remove-DockerObject 'volume' $volume; if ($why) { $kept.Add($why) } }
        if ($row.Network) { $why = Remove-DockerObject 'network' $row.Network; if ($why) { $kept.Add($why) } }
    } else {
        $clone = [string]$Slot.installPath
        if ($clone -and (Test-PathUnder $clone $Root)) { "$($Slot.slotId): $clone is this checkout; it is kept (only its registration was removed)." }
        elseif ($clone -and (Test-Path -LiteralPath $clone)) {
            if ((Split-Path $clone -Leaf) -cnotmatch '^win\d{2}$') { $kept.Add("$clone is not an instance clone (winNN)") }
            elseif (-not (Remove-PathBounded -Path $clone)) { $kept.Add("$clone is still in use") }
        }
    }
    if ($kept.Count) {
        $script:HostFailed = $true
        [Console]::Error.WriteLine("$($Slot.slotId): not fully pruned: $($kept -join '; '). It stays retired; rerun Apply -Prune.")
        return $false
    }
    $Slot.state = 'pruned'
    Set-RecordValue $Slot 'prunedUtc' ([DateTime]::UtcNow.ToString('o'))
    "$($Slot.slotId): pruned."
    $true
}

function Invoke-Prune($Inventory) {
    $operation = Read-HostOperation
    if ($operation.State -eq 'readable') { throw "Apply -Prune refused: the operation $($operation.Value.kind) ($($operation.Value.id)) is unfinished; finish it with Apply (or Apply -Rollback) first." }
    $changed = $false
    $withKept = @($Inventory.slots | Where-Object { $_ -and $_.PSObject.Properties['keptForRollback'] -and @($_.keptForRollback).Count })
    $retired = @($Inventory.slots | Where-Object { $_ -and $_.state -eq 'retired' })
    if (-not $withKept.Count -and -not $retired.Count) { 'Nothing is kept for rollback; nothing to prune.'; return }
    foreach ($slot in $withKept) {
        $results = @(Invoke-PruneKept $Inventory $slot)
        $results | Select-Object -SkipLast 1
        if ($results[-1] -eq $true) { $changed = $true }
    }
    foreach ($slot in $retired) {
        $results = @(Invoke-PruneRetired $slot)
        $results | Select-Object -SkipLast 1
        if ($results[-1] -eq $true) { $changed = $true }
    }
    if ($changed) { Save-Inventory $Inventory }
}

function Invoke-Apply {
    Use-HostLock -Kind 'Manage-RunnerHost Apply' -Joinable -ScriptBlock {
        $inventory = Assert-HostInventoryUsable $(if ($Prune) { 'Prune' } else { 'Apply' })
        if ($Prune) { Invoke-Prune $inventory; return }
        $operation = Read-HostOperation
        $op = if ($operation.State -eq 'readable') { $operation.Value }
        if ($Rollback) {
            if (-not $op) { 'No unfinished operation; nothing to roll back.'; return }
            Invoke-MigrationRollback $inventory $op
            return
        }
        if ($ExpectPlan) {
            $reviewed = Get-HostPlan
            if ($reviewed.planHash -ne $ExpectPlan) { throw "Apply refused: the plan is now $($reviewed.planHash), not the reviewed $ExpectPlan. Nothing was changed; review -Action Plan again." }
        }
        Invoke-ApplyChanges $inventory $op
    }
}

# What Apply and Update carry out, under the host lock: an unfinished operation, the legacy migration, adds, retires, then
# each drifted slot's update, one at a time.
function Invoke-ApplyChanges($inventory, $op, [switch] $Rebuild) {
    $downgrade = Get-DowngradeFinding $inventory
    if ($downgrade) { throw "Apply refused: $($downgrade.message) Nothing was changed." }
    $acted = $false
    if ($op) {
        if ($op.PSObject.Properties['rollingBack'] -and $op.rollingBack) { throw "Apply refused: operation $($op.id) was being rolled back. Finish that with Apply -Rollback." }
        switch ($op.kind) {
            $MigrationKind { Invoke-LegacyMigration $inventory $op }
            $AddKind { Invoke-SlotAdd $inventory $op $op.slotId }
            $RetireKind { Invoke-SlotRetire $inventory $op $op.slotId }
            $UpdateKind { Invoke-SlotUpdate $inventory $op $op.slotId @() }
            default { throw "Apply refused: the unfinished operation $($op.kind) ($($op.id)) is not one this version of Apply finishes." }
        }
        $acted = $true
        $inventory = Assert-HostInventoryUsable 'Apply'
    }
    $row = @(Get-LinuxSlots $Config $inventory | Where-Object { $_.SlotId -eq 'linux-01' -and $_.Legacy -and -not $_.New -and -not $_.Composed }) | Select-Object -First 1
    if ($row) {
        Invoke-LegacyMigration $inventory $null
        $acted = $true
        $inventory = Assert-HostInventoryUsable 'Apply'
    }
    $plan = Get-HostPlan
    $adds = @($plan.changes | Where-Object { $_.kind -eq 'add' })
    $retires = @($plan.changes | Where-Object { $_.kind -eq 'retire' })
    if ($adds.Count) {
        $blocker = Get-AddBlocker $inventory $adds
        if ($blocker) {
            $script:HostFailed = $true
            [Console]::Error.WriteLine("Apply added no slot ($(@($adds | ForEach-Object { $_.slotId }) -join ', ')): $blocker")
        } else {
            $linuxAdds = @($adds | Where-Object { $_.platform -eq 'linux' })
            if ($linuxAdds.Count) {
                $imageBlocker = Get-LinuxImageBlocker
                if ($imageBlocker) {
                    $script:HostFailed = $true
                    [Console]::Error.WriteLine("Apply added no Linux slot ($(@($linuxAdds | ForEach-Object { $_.slotId }) -join ', ')): $imageBlocker")
                    $adds = @($adds | Where-Object { $_.platform -ne 'linux' })
                }
            }
            foreach ($add in $adds) {
                Invoke-SlotAdd $inventory $null $add.slotId $add.platform
                $inventory = Assert-HostInventoryUsable 'Apply'
            }
        }
        $acted = $true
    }
    foreach ($change in $retires) {
        $acted = $true
        if (-not $Retire) {
            "Not retired: $($change.slotId) ($($change.runnerName)) is no longer wanted; rerun Apply -Retire to retire it."
            $script:ApplyExit = 3
            continue
        }
        if ($change.Contains('after')) {
            $why = Get-LegacyRetireBlocker $inventory
            if ($why) { "Deferred: $($change.slotId) is retired only after $($change.after): $why"; $script:ApplyExit = 3; continue }
        }
        Invoke-SlotRetire $inventory $null $change.slotId
        $inventory = Assert-HostInventoryUsable 'Apply'
    }
    # Updates last, one slot at a time. The Linux image is rebuilt first when the settings build a different one, so
    # each slot is recreated on it inside its own drain.
    # Update always checks the image against what the settings build (downloading the runner archive if need be);
    # Apply only when the plan already shows a Linux update.
    $updates = @((Get-HostPlan).changes | Where-Object { $_.kind -eq 'update' })
    $linuxUpdates = @($updates | Where-Object { $_.platform -eq 'linux' }).Count
    if (($Rebuild -and @(Get-ComposedLinuxSlots $inventory).Count) -or ($linuxUpdates -and (Test-LinuxImageStale))) {
        $build = Get-LinuxImageBuild $Config $Root
        if ((Get-ImageId $Config.linux.image).State -ne 'present' -or (Get-LinuxImageContextHash $Config.linux.image) -ne $build.Hash) {
            "Building $($Config.linux.image) on $($Config.linux.baseImage)."
            Invoke-LinuxImageBuild $Config $Root $build
            $updates = @((Get-HostPlan).changes | Where-Object { $_.kind -eq 'update' })
        }
    }
    foreach ($change in $updates) {
        $acted = $true
        Invoke-SlotUpdate $inventory $null $change.slotId @($change.reasons)
        $inventory = Assert-HostInventoryUsable 'Apply'
    }
    if (-not $acted) { 'Nothing to migrate, add, retire or update: the slots match the settings.' }
}

# The digest a BuildAgent release tag resolves to, read from the registry without pulling.
function Resolve-BuildAgentDigest([string] $Repository, [string] $Release) {
    $inspect = Invoke-Docker @('buildx', 'imagetools', 'inspect', "${Repository}:$Release")
    if ($inspect.ExitCode -ne 0) { throw "Update refused: ${Repository}:$Release could not be resolved (exit $($inspect.ExitCode)): $($inspect.Output) Nothing was changed." }
    if ($inspect.Output -notmatch 'Digest:\s+(sha256:[0-9a-f]{64})') { throw "Update refused: no digest was found for ${Repository}:$Release. Nothing was changed." }
    "$Repository@$($Matches[1])"
}

function Invoke-Update {
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Update refused: -Version '$Version' is not an exact release such as 1.4.2. A floating tag (latest, 1, 1.4) is never resolved. Nothing was changed." }
    Use-HostLock -Kind 'Manage-RunnerHost Update' -Joinable -ScriptBlock {
        $inventory = Assert-HostInventoryUsable 'Apply'
        $operation = Read-HostOperation
        if ($operation.State -eq 'readable') { throw "Update refused: the operation $($operation.Value.kind) ($($operation.Value.id)) is unfinished; finish it with Apply first. Nothing was changed." }
        $current = [string]$Config.buildAgent.image
        $repository = $current -replace '@.*$', ''
        $slash = $repository.LastIndexOf('/')
        $colon = $repository.LastIndexOf(':')
        if ($colon -gt $slash) { $repository = $repository.Substring(0, $colon) }
        $image = Resolve-BuildAgentDigest $repository $Version
        $recorded = if ($inventory.PSObject.Properties['buildAgent']) { $inventory.buildAgent }
        # Every digest replaced so far, with its release when known: { image; version }.
        $previous = [Collections.Generic.List[object]]::new()
        $known = @(@($recorded.previous | Where-Object { $_ -and $_.image }) +
            @(if ($recorded -and $recorded.image) { [pscustomobject]@{ image = [string]$recorded.image; version = $recorded.version } }) +
            [pscustomobject]@{ image = $current; version = $null })
        foreach ($entry in $known) {
            if ($entry.image -eq $image -or @($previous | Where-Object { $_.image -eq $entry.image }).Count) { continue }
            $previous.Add([pscustomobject][ordered]@{ image = [string]$entry.image; version = $entry.version })
        }
        if ($image -eq $current) { "buildAgent.image is already $image ($Version)." }
        elseif ($recorded -and $recorded.version -and [version]$Version -lt [version]$recorded.version) { "Rolling back buildAgent.image to $Version ($image) from $($recorded.version)." }
        else { "Moving buildAgent.image to $Version ($image)." }

        # The settings first, then the inventory, then anything recreated: a run stopped after this point finishes with Apply.
        $local = if (Test-Path -LiteralPath $LocalConfig) { Get-Content -Raw -LiteralPath $LocalConfig | ConvertFrom-Json } else { [pscustomobject]@{} }
        if (-not $local.PSObject.Properties['buildAgent'] -or $local.buildAgent -isnot [pscustomobject]) { $local | Add-Member -Force -NotePropertyName buildAgent -NotePropertyValue ([pscustomobject]@{}) }
        $local.buildAgent | Add-Member -Force -NotePropertyName image -NotePropertyValue $image
        Write-FileAtomic $LocalConfig (ConvertTo-Json -InputObject $local -Depth 20)
        $script:Config = Read-RunnerConfig -Root $Root
        Set-RecordValue $inventory 'buildAgent' ([pscustomobject][ordered]@{ image = $image; version = $Version; updatedUtc = [DateTime]::UtcNow.ToString('o'); previous = $previous.ToArray() })
        Save-Inventory $inventory
        "runners.local.json and the inventory record buildAgent.image $image."
        if ($local.PSObject.Properties['linux'] -and $local.linux.PSObject.Properties['baseImage'] -and $local.linux.baseImage) {
            "Note: linux.baseImage in runners.local.json ($($local.linux.baseImage)) overrides the BuildAgent image for the Linux slots; they are not moved."
        }
        Invoke-ApplyChanges $inventory $null -Rebuild
    }
}

# --- Output.

function Test-PlanFindings($Plan) { [bool]@($Plan.findings | Where-Object { $_.severity -in 'unknown', 'drift', 'blocked' }).Count }

function Write-PlanText($Plan) {
    "Host $($Plan.hostId): inventory $($Plan.inventory.state)$(if ($Plan.inventory.reason) { " ($($Plan.inventory.reason))" })"
    if ($Plan.operation.state -eq 'unreadable') { "Operation journal unreadable: $($Plan.operation.reason)" }
    if (-not $Plan.changes.Count) { if (Test-PlanFindings $Plan) { 'No changes to apply, but the findings below are not resolved.' } else { 'No changes.' } }
    foreach ($change in $Plan.changes) {
        $details = @($change.Keys | Where-Object { $_ -ne 'kind' } | ForEach-Object { "$_=$(@($change[$_]) -join ',')" }) -join ' '
        "  $($change.kind) $details"
    }
    foreach ($item in $Plan.findings) { "  [$($item.severity)] $($item.subject): $($item.message)" }
    if ($Plan.planHash) { "planHash: $($Plan.planHash)" }
    if ($Plan.Contains('resources')) {
        $r = $Plan.resources
        'Resources (read only):'
        if ($r.volumes.state -ne 'known') { "  volumes: unknown" }
        foreach ($item in $r.volumes.items) { "  volume $($item.name) ($($item.slotId)): $($item.size)" }
        $d = $r.dockerData
        "  Docker data $($d.path)$(if ($d.drive) { " on $($d.drive)" }): $(if ($null -ne $d.freeGB) { "$($d.freeGB) GB free" } else { 'free space unknown' }), minimum $($d.minimumGB) GB"
        "  Linux memory (enforced): $($r.memory.linux.slots) slot(s) x $($r.memory.linux.perSlot) = $($r.memory.linux.total)"
        "  Windows memory (advisory, not enforced): $($r.memory.windows.slots) slot(s) x $($r.memory.windows.perSlot) = $($r.memory.windows.total)"
        "  WSL memory cap: $(if ($r.memory.wslCap.memory) { "$($r.memory.wslCap.memory) ($($r.memory.wslCap.file))" } else { 'not set' })"
    }
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
        'AutoStart' { Invoke-AutoStart; exit [int]$script:HostFailed }
        'Hold' { Invoke-Hold; exit [int]$script:HostFailed }
        'Resume' { Invoke-Resume; exit [int]$script:HostFailed }
        'Apply' { Invoke-Apply; exit $(if ($script:HostFailed) { 1 } else { [int]$script:ApplyExit }) }
        'Update' { Invoke-Update; exit $(if ($script:HostFailed) { 1 } else { [int]$script:ApplyExit }) }
        'Startup' { Set-StartupEntry; exit 0 }
        'Plan' {
            $plan = Get-HostPlan -Resources
            if ($Json) { ConvertTo-Json -InputObject $plan -Depth 20 } else { Write-PlanText $plan }
            if ($plan.inventory.state -eq 'unreadable' -or $plan.operation.state -eq 'unreadable') {
                [Console]::Error.WriteLine('Plan cannot be computed: the host state cannot be read. Restore the file, or rebuild the inventory with -Action Adopt -ReplaceUnreadable.')
                exit 1
            }
            # 3: changes, or a drifted or blocked finding to act on; 1: something could not be read, so "no changes" is not known.
            $unknown = @($plan.findings | Where-Object { $_.severity -eq 'unknown' }).Count
            if ($unknown) { [Console]::Error.WriteLine("Plan is incomplete: $unknown item(s) could not be read.") }
            exit $(if ($unknown) { 1 } elseif ($plan.changes.Count -or (Test-PlanFindings $plan)) { 3 } else { 0 })
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
