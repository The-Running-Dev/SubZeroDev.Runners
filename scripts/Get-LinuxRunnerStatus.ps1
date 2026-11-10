# Read-only status of this host's Linux runners, one row per slot, and whether each is current: the image its container runs
# against the image tag, the image's build context hash against the files on disk, the container's compose config hash
# against the compose file, and the compose file against what the scripts would generate now. Nothing is created or changed.
# -Json writes the rows as JSON (schema subzerodev.linux-runner-status, version 1); without it they print as a table.
# A check that cannot be made says 'not-checked' with the reason; it is never reported as ok.
param([switch] $Json)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
. "$PSScriptRoot\Compose.ps1"

function New-Check([string] $Result, [string] $Detail) { [ordered]@{ result = $Result; detail = $Detail } }

function Get-ContainerFact([string] $Name, [string] $Format) {
    $inspect = Invoke-Docker @('container', 'inspect', '--format', $Format, $Name)
    if ($inspect.ExitCode -eq 0) { $inspect.Output.Trim() }
}

$inventory = Read-HostInventory
$rows = [Collections.Generic.List[object]]::new()
$note = $null
if ($inventory.State -ne 'readable') {
    $note = if ($inventory.State -eq 'absent') { 'There is no host inventory; only the pre-pool runner (if any) exists.' } else { "The host inventory cannot be read: $($inventory.Reason)." }
}
$slots = if ($inventory.State -eq 'readable') { @(Get-LinuxSlots $Config $inventory.Value | Where-Object { -not $_.New }) } else { @() }

$archive = Join-Path (Join-Path $Root 'downloads') "actions-runner-linux-x64-$($Config.runnerVersion).tar.gz"
$expectedContext = $null
$contextReason = $null
if (Test-Path -LiteralPath $archive) {
    $arguments = [ordered]@{ BASE_IMAGE = $Config.linux.baseImage; RUNNER_VERSION = $Config.runnerVersion; RUNNER_SHA256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() }
    $expectedContext = Get-LinuxBuildContextHash $Root $arguments
}
else { $contextReason = "the runner archive $archive is not downloaded, so the build context cannot be hashed" }

$composeFile = Get-LinuxComposeFilePath $Root
$composeSlots = @($slots | Where-Object { -not $_.Legacy })
$fileCheck = if (-not $composeSlots.Count) { New-Check 'not-applicable' 'no compose slots' }
elseif (-not (Test-Path -LiteralPath $composeFile)) { New-Check 'drift' "$composeFile does not exist" }
else {
    $expectedYaml = ConvertTo-LinuxComposeYaml $Config $composeSlots $Root $PSScriptRoot
    if ([IO.File]::ReadAllText($composeFile) -eq $expectedYaml) { New-Check 'ok' $null } else { New-Check 'drift' "$composeFile differs from what the scripts generate now" }
}
$imageId = $null
$inspectImage = Invoke-Docker @('image', 'inspect', '--format', '{{.Id}}', $Config.linux.image)
if ($inspectImage.ExitCode -eq 0) { $imageId = $inspectImage.Output.Trim() }
$imageContext = if ($imageId) { Get-LinuxImageContextHash $Config.linux.image }

foreach ($slot in $slots) {
    $record = Get-InventorySlot $inventory.Value $slot.SlotId
    $containerName = if ($slot.Legacy) { $Config.linux.container } else { $slot.Container }
    $state = (Get-ContainerState $containerName).State
    $image = if (-not $imageId) { New-Check 'not-checked' "the image $($Config.linux.image) is not present" }
    elseif ($state -in 'absent', 'unknown') { New-Check 'not-checked' "the container is $state" }
    elseif ((Get-ContainerFact $containerName '{{.Image}}') -eq $imageId) { New-Check 'ok' $null }
    else { New-Check 'drift' "the container runs an older image than $($Config.linux.image)" }
    $context = if (-not $imageId) { New-Check 'not-checked' 'the image is not present' }
    elseif ($contextReason) { New-Check 'not-checked' $contextReason }
    elseif (-not $imageContext) { New-Check 'drift' 'the image has no build context label (built before it existed); rebuild it' }
    elseif ($imageContext -eq $expectedContext) { New-Check 'ok' $null }
    else { New-Check 'drift' 'the image was built from different files or build arguments than are on disk' }
    $configHash = if ($slot.Legacy) { New-Check 'not-applicable' 'the pre-pool runner is not managed by compose' }
    elseif ($state -in 'absent', 'unknown') { New-Check 'not-checked' "the container is $state" }
    elseif (-not (Test-Path -LiteralPath $composeFile)) { New-Check 'not-checked' 'there is no compose file' }
    else {
        $actual = Get-ContainerFact $containerName '{{ index .Config.Labels "com.docker.compose.config-hash" }}'
        $wanted = Invoke-LinuxCompose -File $composeFile -Verb config -Services @($slot.SlotId)
        $wantedHash = if ($wanted.ExitCode -eq 0) { ($wanted.Output.Trim() -split '\s+' | Select-Object -Last 1) }
        if (-not $wantedHash) { New-Check 'not-checked' "compose could not compute the hash: $($wanted.Output)" }
        elseif ($actual -eq $wantedHash) { New-Check 'ok' $null }
        else { New-Check 'drift' 'the container was created from an older compose definition' }
    }
    $rows.Add([ordered]@{
        instanceId = $slot.SlotId; platform = 'linux'; state = $(if ($record) { $record.state }); legacy = $slot.Legacy
        runnerName = $slot.RunnerName; container = [ordered]@{ name = $containerName; state = $state }
        drift = [ordered]@{ image = $image; contextHash = $context; composeConfigHash = $configHash; composeFile = $(if ($slot.Legacy) { New-Check 'not-applicable' 'the pre-pool runner is not managed by compose' } else { $fileCheck }) }
    })
}

$report = [ordered]@{ schema = 'subzerodev.linux-runner-status'; version = 1; hostId = (Get-RunnerHostId $Config); note = $note; slots = @($rows) }
if ($Json) { ConvertTo-Json -InputObject $report -Depth 8 }
else {
    if ($note) { Write-Output $note }
    foreach ($row in $rows) {
        $drifted = @($row.drift.GetEnumerator() | Where-Object { $_.Value.result -eq 'drift' } | ForEach-Object { $_.Key })
        Write-Output ("{0}  {1}  container {2}  {3}" -f $row.instanceId, $row.state, $row.container.state, $(if ($drifted) { "drift: $($drifted -join ', ')" } else { 'current' }))
    }
}
