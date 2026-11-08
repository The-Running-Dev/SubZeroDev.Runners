#Requires -Version 7.2
# Evaluation of BuildAgent acceptance evidence. Dot-source it; it only reads the reports its caller hands it.
#
# The windows-runner-buildagent.yml workflow writes one report.json per build job (buildagent-slot-N) and one for the
# deliberately failing build (buildagent-failure). Test-BuildAgentAcceptance judges them together, so the same rules run
# inside the workflow (report job) and outside it (Assert-WindowsRunnerBuildAgent.ps1, which adds GitHub's own job records).
#
# Passing requires evidence, not a green workflow: the pins, the exit codes, the artifacts, the per-instance isolation, the
# marker each job stamped into its own source, and a real overlap between the two builds. The artifacts and markers are not
# taken from the reports: the uploaded files are re-read (length, SHA-256, markers), so a report that claims files the
# download does not contain is rejected.

# The workflow's collect step copies the instance's site directory (workspace-relative, e.g. docs/build) into this folder of the
# uploaded buildagent-slot-N artifact. It is the one place the workspace-relative artifact paths are mapped to uploaded paths.
$BuildAgentUploadedSiteDirectory = 'site'
$BuildAgentMarkerPattern = 'acceptance-marker-r\d+-a\d+-slot\d+'

# Maps a workspace-relative artifact path (docs/build/index.html) to its path inside the uploaded artifact (site/index.html).
# Returns $null for a path outside the site directory (nothing uploaded stands for it) or one that climbs out of it.
function Get-BuildAgentUploadedPath {
    param(
        [Parameter(Mandatory)] [string] $Artifact,
        [Parameter(Mandatory)] [string] $SiteDirectory,
        [string] $UploadedSiteDirectory = $BuildAgentUploadedSiteDirectory
    )
    $path = ($Artifact -replace '\\', '/').Trim('/')
    $site = ($SiteDirectory -replace '\\', '/').Trim('/')
    if (-not $site -or -not $path.StartsWith("$site/", [StringComparison]::Ordinal)) { return $null }
    $relative = $path.Substring($site.Length + 1)
    $segments = @($relative -split '/')
    if (-not $relative -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..' -or $relative -match ':') { return $null }
    "$UploadedSiteDirectory/$relative"
}

# Every distinct job marker found in any file under a site directory (the raw bytes are searched, so file type does not matter).
function Get-BuildAgentSiteMarkers([Parameter(Mandatory)] [string] $Directory) {
    $found = [Collections.Generic.HashSet[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Recurse -File -Force) {
        $text = [Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($file.FullName))
        foreach ($match in [regex]::Matches($text, $BuildAgentMarkerPattern)) { [void]$found.Add($match.Value) }
    }
    @($found | Sort-Object)
}

# Reads buildagent-slot-* and buildagent-failure sub-folders of an artifact download directory.
function Read-BuildAgentAcceptanceReports([Parameter(Mandatory)] [string] $Directory) {
    $read = {
        param([string] $Path)
        $file = Join-Path $Path 'report.json'
        if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
    }
    $builds = @(Get-ChildItem -LiteralPath $Directory -Directory -Filter 'buildagent-slot-*' -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { & $read $_.FullName } | Where-Object { $_ })
    $failureDirectory = Join-Path $Directory 'buildagent-failure'
    $failure = if (Test-Path -LiteralPath $failureDirectory) { & $read $failureDirectory }
    [pscustomobject]@{ Builds = $builds; Failure = $failure }
}

# -Builds / -Failure: the report.json objects. -Jobs: optional GitHub job records (gh api .../jobs), checked in addition.
# -ExpectedArtifacts: files (relative to the instance workspace) every build must have produced.
# -EvidenceDirectory: the download directory holding each uploaded buildagent-slot-N artifact. A report only says what a job
#   saw; the files are re-read from here: every expected artifact must exist (under -SiteDirectory, mapped to the uploaded
#   -UploadedSiteDirectory), match its recorded length and SHA-256, and the site's markers are recounted from its bytes.
# -ExpectedRunId: when given, each job's marker must belong to that run.
# Returns { Passed; Checks = @{ Name; Passed; Detail } }.
function Test-BuildAgentAcceptance {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Builds,
        $Failure,
        [Parameter(Mandatory)] [string[]] $ExpectedRunnerNames,
        [Parameter(Mandatory)] [string] $ExpectedComputerName,
        [Parameter(Mandatory)] [string] $ExpectedToolVersion,
        [Parameter(Mandatory)] [string] $ExpectedImageDigest,
        [Parameter(Mandatory)] [string[]] $ExpectedArtifacts,
        [Parameter(Mandatory)] [string] $EvidenceDirectory,
        [string] $SiteDirectory = 'docs/build',
        [string] $UploadedSiteDirectory = $BuildAgentUploadedSiteDirectory,
        [string] $ExpectedRunId,
        $Jobs,
        [string] $BuildStepName = 'Run BuildAgent build'
    )
    $checks = [Collections.Generic.List[object]]::new()
    function Add-Check([string] $Name, [bool] $Passed, [string] $Detail) { $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail }) }
    $builds = @($Builds)
    $slots = @($builds | ForEach-Object { [string]$_.slot } | Sort-Object)
    $twoBuilds = $builds.Count -eq 2 -and ($slots -join ',') -eq '1,2'
    Add-Check 'two build reports' $twoBuilds "Slots found: $($slots -join ', ')."
    if (-not $twoBuilds) { return [pscustomobject]@{ Passed = $false; Checks = $checks.ToArray() } }

    # Identity: two different runners, both of this host, both named as expected.
    $names = @($builds.runnerName)
    $identityOk = @($names | Select-Object -Unique).Count -eq 2 -and -not (Compare-Object ($names | Sort-Object) ($ExpectedRunnerNames | Sort-Object)) -and
        -not @($builds | Where-Object { $_.computerName -ine $ExpectedComputerName })
    Add-Check 'distinct runner identities' $identityOk "Runners: $($names -join ', '); expected $($ExpectedRunnerNames -join ', ') on $ExpectedComputerName."

    # Pins: what ran is what runners.json says, on a daemon that answered.
    $pinProblems = foreach ($build in $builds) {
        if ($build.toolVersion -ne $ExpectedToolVersion) { "slot $($build.slot) tool $($build.toolVersion)" }
        if ($build.imageDigest -ne $ExpectedImageDigest) { "slot $($build.slot) image $($build.imageDigest)" }
        if ($build.dockerState -ne 'ok') { "slot $($build.slot) docker $($build.dockerState)" }
        foreach ($row in @($build.statusRows | Where-Object { $_.Item -ne 'updater' -and $_.State -ne 'ok' })) { "slot $($build.slot) $($row.Item) $($row.State)" }
    }
    Add-Check 'tool, image and Docker pins' (-not $pinProblems) $(if ($pinProblems) { @($pinProblems) -join '; ' } else { "BuildAgent.Tool $ExpectedToolVersion, $ExpectedImageDigest, Linux Docker daemon ok on both instances." })

    $badExit = @($builds | Where-Object { $_.exitCode -ne 0 })
    Add-Check 'builds exited 0' ($badExit.Count -eq 0) $(if ($badExit) { "Slot(s) $($badExit.slot -join ', ') exited $($badExit.exitCode -join ', ')." } else { 'Both builds exited 0.' })

    # The builds ran at the same time (inside the workflow's own timestamps).
    $starts = @($builds | ForEach-Object { [DateTimeOffset]::Parse($_.startUtc) })
    $ends = @($builds | ForEach-Object { [DateTimeOffset]::Parse($_.endUtc) })
    $overlap = (($ends | Sort-Object | Select-Object -First 1) - ($starts | Sort-Object -Descending | Select-Object -First 1)).TotalSeconds
    Add-Check 'builds overlapped' ($overlap -gt 0) "Overlap of the two build steps: $([math]::Round($overlap, 1)) s."

    # GitHub's own step records for the same builds, when the caller read them.
    if ($null -ne $Jobs) {
        $buildJobs = @($Jobs | Where-Object { $_.name -like 'Build slot *' })
        $intervals = foreach ($job in $buildJobs) {
            $step = @($job.steps | Where-Object name -eq $BuildStepName)
            if ($step.Count -eq 1 -and $step[0].started_at -and $step[0].completed_at) { [pscustomobject]@{ Start = [DateTimeOffset]::Parse($step[0].started_at); End = [DateTimeOffset]::Parse($step[0].completed_at) } }
        }
        $apiOverlap = if (@($intervals).Count -eq 2) { ((@($intervals.End) | Sort-Object | Select-Object -First 1) - (@($intervals.Start) | Sort-Object -Descending | Select-Object -First 1)).TotalSeconds } else { -1 }
        Add-Check 'GitHub job records overlap' ($buildJobs.Count -eq 2 -and $apiOverlap -gt 0) "Two 'Build slot' jobs with step timestamps; overlap $([math]::Round($apiOverlap, 1)) s."
        $apiRunners = @($buildJobs | ForEach-Object { "$($_.runner_id)" } | Select-Object -Unique)
        $apiNames = @($buildJobs.runner_name)
        Add-Check 'GitHub runner records' ($apiRunners.Count -eq 2 -and -not (Compare-Object ($apiNames | Sort-Object) ($ExpectedRunnerNames | Sort-Object))) "Runner IDs $($apiRunners -join ', ') for $($apiNames -join ', ')."
        $missingJobs = @('Build slot 1', 'Build slot 2', 'Failure propagation', 'Acceptance report') | Where-Object { $_ -notin @($Jobs.name) }
        Add-Check 'workflow jobs present' ($missingJobs.Count -eq 0) $(if ($missingJobs) { "Missing jobs: $($missingJobs -join ', ')." } else { 'Both builds, the failing build and the report ran.' })
        $unfinished = @($Jobs | Where-Object { $_.conclusion -ne 'success' })
        Add-Check 'every job succeeded' ($unfinished.Count -eq 0) $(if ($unfinished) { "Not successful: $(($unfinished | ForEach-Object { "$($_.name)=$($_.conclusion)" }) -join ', ')." } else { "$(@($Jobs).Count) jobs succeeded." })
    }

    # Separate workspaces, caches and outputs: nothing of one instance is inside, or equal to, anything of the other.
    $overlapping = [Collections.Generic.List[string]]::new()
    foreach ($field in 'instance', 'workspace', 'cacheDirectory', 'outputDirectory') {
        $first = [string]$builds[0].$field; $second = [string]$builds[1].$field
        if (-not $first -or -not $second -or $first -ieq $second) { $overlapping.Add($field) }
        elseif ($field -ne 'instance' -and (($first.TrimEnd('\') + '\').StartsWith($second.TrimEnd('\') + '\', 'OrdinalIgnoreCase') -or ($second.TrimEnd('\') + '\').StartsWith($first.TrimEnd('\') + '\', 'OrdinalIgnoreCase'))) { $overlapping.Add("$field (nested)") }
    }
    Add-Check 'separate workspaces, caches and outputs' ($overlapping.Count -eq 0) $(if ($overlapping.Count) { "Shared: $($overlapping -join ', ')." } else { "Instances $(($builds | Sort-Object slot).instance -join ' and ') have their own workspace, cache and output." })

    # Artifacts: each build produced every expected file, with content.
    $artifactProblems = foreach ($build in $builds) {
        $found = @($build.artifacts | ForEach-Object { ([string]$_.path) -replace '\\', '/' })
        foreach ($expected in $ExpectedArtifacts) {
            $entry = @($build.artifacts | Where-Object { (([string]$_.path) -replace '\\', '/') -eq $expected })
            if ($entry.Count -ne 1) { "slot $($build.slot) missing $expected" }
            elseif (-not $entry[0].sha256 -or [long]$entry[0].bytes -le 0) { "slot $($build.slot) $expected is empty" }
        }
        if ($found.Count -eq 0) { "slot $($build.slot) reported no artifacts" }
    }
    Add-Check 'expected artifacts present' (-not $artifactProblems) $(if ($artifactProblems) { @($artifactProblems) -join '; ' } else { "Both builds produced: $($ExpectedArtifacts -join ', ')." })

    # The uploaded files themselves: each expected artifact exists, is not empty, and has the length and SHA-256 the report records.
    $fileProblems = [Collections.Generic.List[string]]::new()
    foreach ($build in $builds) {
        $root = Join-Path $EvidenceDirectory "buildagent-slot-$($build.slot)"
        $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        foreach ($expected in $ExpectedArtifacts) {
            $uploaded = Get-BuildAgentUploadedPath $expected $SiteDirectory $UploadedSiteDirectory
            if ($null -eq $uploaded) { $fileProblems.Add("slot $($build.slot) $expected is not inside the site directory $SiteDirectory, so no uploaded file stands for it"); continue }
            $file = [IO.Path]::GetFullPath((Join-Path $root $uploaded))
            if (-not $file.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { $fileProblems.Add("slot $($build.slot) uploaded no $uploaded for $expected"); continue }
            $length = (Get-Item -LiteralPath $file).Length
            if ($length -le 0) { $fileProblems.Add("slot $($build.slot) uploaded $uploaded is empty"); continue }
            $entry = @($build.artifacts | Where-Object { (([string]$_.path) -replace '\\', '/') -eq $expected })
            if ($entry.Count -ne 1) { $fileProblems.Add("slot $($build.slot) report has no entry for $expected"); continue }
            if (($entry[0].bytes -as [long]) -ne $length) { $fileProblems.Add("slot $($build.slot) $expected is $length bytes, the report says $($entry[0].bytes)") }
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            if (([string]$entry[0].sha256).ToLowerInvariant() -ne $hash) { $fileProblems.Add("slot $($build.slot) $expected has SHA-256 $($hash.Substring(0, 12)), the report says $(([string]$entry[0].sha256).Substring(0, [math]::Min(12, ([string]$entry[0].sha256).Length)))") }
        }
    }
    Add-Check 'artifact files match the report' ($fileProblems.Count -eq 0) $(if ($fileProblems.Count) { $fileProblems -join '; ' } else { "Uploaded $($ExpectedArtifacts -join ', ') (from $SiteDirectory) re-read for both builds: length and SHA-256 match the reports." })

    # No cross-contamination, from the uploaded site itself: it carries the marker stamped into that job's own source, and
    # no other job's marker, whatever the report's flags say.
    $markerProblems = [Collections.Generic.List[string]]::new()
    foreach ($build in $builds) {
        $marker = [string]$build.marker
        if (-not $marker) { $markerProblems.Add("slot $($build.slot) has no marker") }
        elseif ($marker -notmatch "^acceptance-marker-r\d+-a\d+-slot$($build.slot)$") { $markerProblems.Add("slot $($build.slot) marker $marker is not a slot $($build.slot) marker") }
        elseif ($ExpectedRunId -and $marker -notmatch "^acceptance-marker-r$([regex]::Escape($ExpectedRunId))-a") { $markerProblems.Add("slot $($build.slot) marker $marker is not from run $ExpectedRunId") }
        $site = Join-Path (Join-Path $EvidenceDirectory "buildagent-slot-$($build.slot)") $UploadedSiteDirectory
        if (-not (Test-Path -LiteralPath $site -PathType Container)) { $markerProblems.Add("slot $($build.slot) uploaded no site to inspect"); continue }
        $found = @(Get-BuildAgentSiteMarkers $site)
        if ($marker -and $found -notcontains $marker) { $markerProblems.Add("slot $($build.slot) marker $marker is not in its uploaded site") }
        $foreign = @($found | Where-Object { $_ -ne $marker })
        if ($foreign.Count) { $markerProblems.Add("slot $($build.slot) uploaded site contains $($foreign -join ', ')") }
        if (-not $build.markerFound) { $markerProblems.Add("slot $($build.slot) report says its marker is not in its site") }
        if (@($build.foreignMarkers).Count) { $markerProblems.Add("slot $($build.slot) report lists $(@($build.foreignMarkers) -join ', ')") }
    }
    if (@($builds.marker | Select-Object -Unique).Count -ne 2) { $markerProblems.Add('both jobs used the same marker') }
    Add-Check 'no cross-contamination' ($markerProblems.Count -eq 0) $(if ($markerProblems.Count) { $markerProblems -join '; ' } else { 'Each uploaded site contains its own marker and no other job''s.' })

    # A build that fails must fail the step, with a BuildAgent failure code (not 0, not the "daemon unavailable" 5 or "image missing" 125).
    if ($null -eq $Failure) { Add-Check 'failing build propagated' $false 'No buildagent-failure report.' }
    else {
        $propagated = $Failure.stepOutcome -eq 'failure' -and [int]$Failure.exitCode -in 1, 255
        Add-Check 'failing build propagated' $propagated "Deliberate failure: step outcome '$($Failure.stepOutcome)', exit code $($Failure.exitCode) (expected failure with 1 or 255)."
    }
    [pscustomobject]@{ Passed = -not @($checks | Where-Object { -not $_.Passed }).Count; Checks = $checks.ToArray() }
}

# A concise markdown report: the verdict, the checks, and one row per build.
function Format-BuildAgentAcceptanceReport {
    param([Parameter(Mandatory)] $Result, [object[]] $Builds = @(), $Failure, [string] $RunUrl)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# BuildAgent acceptance: $(if ($Result.Passed) { 'PASS' } else { 'FAIL' })")
    if ($RunUrl) { $lines.Add(''); $lines.Add("Run: $RunUrl") }
    $lines.Add(''); $lines.Add('| Check | Result | Detail |'); $lines.Add('| --- | --- | --- |')
    foreach ($check in $Result.Checks) { $lines.Add("| $($check.Name) | $(if ($check.Passed) { 'pass' } else { 'FAIL' }) | $(($check.Detail -replace '\|', '/')) |") }
    if (@($Builds).Count) {
        $lines.Add(''); $lines.Add('| Slot | Runner | Instance | Exit | Tool | Image | Start (UTC) | End (UTC) | Artifacts |'); $lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($build in ($Builds | Sort-Object slot)) {
            $lines.Add("| $($build.slot) | $($build.runnerName) | $($build.instance) | $($build.exitCode) | $($build.toolVersion) | $($build.imageDigest) | $($build.startUtc) | $($build.endUtc) | $((@($build.artifacts) | ForEach-Object { "$($_.path) $($_.sha256.Substring(0, [math]::Min(12, $_.sha256.Length)))" }) -join '; ') |")
        }
    }
    if ($Failure) { $lines.Add(''); $lines.Add("Failing build: step outcome $($Failure.stepOutcome), exit code $($Failure.exitCode).") }
    $lines -join "`n"
}
