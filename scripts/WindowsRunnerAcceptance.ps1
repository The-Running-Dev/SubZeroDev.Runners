#Requires -Version 7.2
# Local, resumable acceptance controller. Dot-sourcing has no host or GitHub side effects. Only jobs dispatched by this
# controller can be cancelled or used for disruptive checks. It uses the existing build and host acceptance checkers.

function Get-RunnerAcceptanceState([string] $InstallRoot) {
    $path = Join-Path $InstallRoot 'acceptance-state.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ version = 1; repository = ''; profile = ''; completed = @{}; activeRun = $null } }
    try {
        $state = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
        if ($state.version -ne 1 -or $state.completed -isnot [hashtable]) { throw 'Invalid state schema.' }
        if ($state.activeRun -and ($state.activeRun -isnot [hashtable] -or -not $state.repository -or
            -not $state.activeRun.correlation -or $state.activeRun.stopAttempted -isnot [bool] -or
            $null -eq $state.activeRun.id -or $state.activeRun.id -isnot [long] -and $state.activeRun.id -isnot [int] -or $state.activeRun.id -lt 0)) { throw 'Invalid active-run journal.' }
        $state
    } catch { throw "Cannot read $path. Inspect it before continuing; it may identify a controlled run that still needs cleanup." }
}

function Save-RunnerAcceptanceState([string] $InstallRoot, [hashtable] $State) {
    $path = Join-Path $InstallRoot 'acceptance-state.json'
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Invoke-RunnerAcceptanceProcess {
    param([string] $Script, [hashtable] $Parameters)
    # -Command via stdin preserves string arrays and paths without shell interpolation or quoting rules.
    $options = Join-Path ([IO.Path]::GetTempPath()) "runner-acceptance-$([guid]::NewGuid().ToString('N')).json"
    $envBefore = $env:SZR_ACCEPTANCE_OPTIONS
    try {
        @{ script = $Script; parameters = $Parameters } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $options -Encoding utf8
        $env:SZR_ACCEPTANCE_OPTIONS = $options
        $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        # Hashtable splatting requires a named variable (not @(...)). No user values are interpolated into the command.
        $code = '$ErrorActionPreference = "Stop"; $o = Get-Content -Raw -LiteralPath $env:SZR_ACCEPTANCE_OPTIONS | ConvertFrom-Json -AsHashtable; $p = $o.parameters; & $o.script @p'
        & $pwsh -NoLogo -NoProfile -NonInteractive -Command $code | Out-Host
        if ($LASTEXITCODE) { throw "$(Split-Path $Script -Leaf) failed (exit $LASTEXITCODE)." }
    } finally {
        $env:SZR_ACCEPTANCE_OPTIONS = $envBefore
        Remove-Item -LiteralPath $options -Force -ErrorAction SilentlyContinue
    }
}

function Get-RunnerAcceptanceFacts([string] $Clone) {
    $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $json = & $pwsh -NoLogo -NoProfile -File (Join-Path $Clone 'scripts\Get-RunnerFacts.ps1')
    if ($LASTEXITCODE) { throw 'Runner facts could not be read; maintenance may be held.' }
    $json | ConvertFrom-Json
}

function Get-RunnerAcceptanceStatus([string] $Clone) {
    $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $json = & $pwsh -NoLogo -NoProfile -File (Join-Path $Clone 'scripts\Manage-WindowsRunner.ps1') -Action Status -Json
    # A busy runner has unhealthy status but still has usable JSON. The state fields are checked by the caller.
    $json | ConvertFrom-Json
}

# Run IDs, titles and attempt numbers must agree on EVERY read, including cleanup. A rerun is an operator's new
# attempt, not a continuation owned by this controller. Old journals without workflow identify the lifecycle template.
function Get-RunnerAcceptanceWorkflow([hashtable] $Run) {
    if (-not $Run.workflow -or $Run.workflow -eq 'windows-runner-lifecycle-acceptance.yml') {
        return @{ file = 'windows-runner-lifecycle-acceptance.yml'; title = 'Windows runner lifecycle acceptance' }
    }
    if ($Run.workflow -eq 'windows-runner-buildagent.yml') {
        return @{ file = 'windows-runner-buildagent.yml'; title = 'Windows runner BuildAgent acceptance' }
    }
    throw 'Unknown acceptance workflow in the saved journal. Inspect it before continuing.'
}

function Assert-RunnerAcceptanceRun([object] $Remote, [hashtable] $Run) {
    $workflow = Get-RunnerAcceptanceWorkflow $Run
    if (-not $Run.id -or -not $Run.correlation -or $Remote.id -ne $Run.id -or
        $Remote.event -cne 'workflow_dispatch' -or $Remote.path -cne ".github/workflows/$($workflow.file)" -or
        $Remote.display_title -cne "$($workflow.title) $($Run.correlation)" -or $Remote.run_attempt -ne 1 -or
        ($Run.branch -and $Remote.head_branch -cne $Run.branch) -or
        $Remote.status -notin 'queued', 'in_progress', 'completed', 'waiting', 'pending', 'requested') {
        throw "Run $($Run.id) does not match this controller's workflow, correlation, branch and original attempt; it will not be cancelled or used."
    }
}

function Wait-RunnerAcceptanceRun {
    param([string] $Repository, [long] $RunId, [int] $TimeoutSeconds = 180, [hashtable] $ExpectedRun)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $run = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/runs/$RunId")
        if ($ExpectedRun) { Assert-RunnerAcceptanceRun $run $ExpectedRun }
        if ($run.status -eq 'completed') { return $run }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Controlled run $RunId did not finish within $TimeoutSeconds seconds."
}

function Stop-RunnerAcceptanceRun {
    param([string] $Repository, [hashtable] $Run)
    $remote = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/runs/$($Run.id)")
    Assert-RunnerAcceptanceRun $remote $Run
    if ($remote.status -ne 'completed') {
        Send-RunnerSetupGh @('api', '-X', 'POST', "repos/$Repository/actions/runs/$($Run.id)/cancel") @{} | Out-Null
        $remote = Wait-RunnerAcceptanceRun $Repository $Run.id -ExpectedRun $Run
    }
    $remote
}

function Find-RunnerAcceptanceRun {
    param([string] $Repository, [string] $Correlation, [string] $Workflow = 'windows-runner-lifecycle-acceptance.yml')
    $expected = @{ workflow = $Workflow; correlation = $Correlation }
    $identity = Get-RunnerAcceptanceWorkflow $expected
    # Search all pages: a busy repository can have more than 100 dispatches while a controller is interrupted.
    $pages = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/workflows/$($identity.file)/runs?event=workflow_dispatch&per_page=100", '--paginate', '--slurp')
    $matches = @($pages | ForEach-Object { $_.workflow_runs } | Where-Object display_title -ceq "$($identity.title) $Correlation")
    if ($matches.Count -gt 1) { throw 'Multiple controlled runs share this correlation. Inspect them before resuming.' }
    if ($matches.Count -eq 1) {
        $expected.id = $matches[0].id
        Assert-RunnerAcceptanceRun $matches[0] $expected
        return $matches[0]
    }
}

# Called BEFORE instance installation can start a supervisor or end maintenance. Recover only our old GitHub run. Never
# clear a failed-stop hold: the operator must fix the cause and explicitly end maintenance first.
function Resume-RunnerSetupAcceptance {
    param([string] $InstallRoot, [string] $Repository, [int] $Count)
    $state = Get-RunnerAcceptanceState $InstallRoot
    if ($state.repository -and $state.repository -ine $Repository) { throw 'Acceptance state belongs to another repository. Use its original target or a separate install root.' }
    if (-not $state.activeRun) { return }
    $active = $state.activeRun
    $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/')
    $clones = @(1..$Count | ForEach-Object { Join-Path $root ('win{0:D2}' -f $_) })
    if ($active.clone -and [IO.Path]::GetFullPath($active.clone) -notin $clones) { throw 'Saved controlled run points outside this installation. Inspect acceptance-state.json.' }
    if (-not $active.id) {
        # Dispatch has no run-ID response. A crash between POST and discovery is resolved by its persisted unique title.
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            $found = Find-RunnerAcceptanceRun $Repository $active.correlation $(if ($active.workflow) { $active.workflow } else { 'windows-runner-lifecycle-acceptance.yml' })
            if ($found) { $active.id = $found.id; Save-RunnerAcceptanceState $InstallRoot $state; break }
            Start-Sleep -Seconds 5
        }
    }
    if (-not $active.id) { throw 'The dispatched run could not be identified. The journal is retained; setup will not redispatch or start runners. Retry after GitHub indexing recovers, or inspect the dispatch before explicitly reconciling the journal.' }
    Stop-RunnerAcceptanceRun $Repository $active | Out-Null
    if ($active.stopAttempted) {
        if (-not $active.clone) { throw 'Interrupted lifecycle check has no clone identity. Inspect acceptance-state.json.' }
        $facts = Get-RunnerAcceptanceFacts $active.clone
        if (-not $facts.admission -or $facts.admission.maintenance) {
            throw "The interrupted check may have retained maintenance in $($active.clone). Fix the cause, then explicitly run Manage-WindowsRunner.ps1 -Action Start there. Setup will not clear the hold."
        }
    }
    $state.activeRun = $null
    Save-RunnerAcceptanceState $InstallRoot $state
}

function Install-RunnerAcceptanceWorkflow {
    param([string] $Repository, [string] $SourceClone, [string] $WorkflowFile = 'windows-runner-lifecycle-acceptance.yml', [bool] $InstallWorkflow = $true)
    $identity = Get-RunnerAcceptanceWorkflow @{ workflow = $WorkflowFile }
    $name = $identity.file
    $path = ".github/workflows/$name"
    $template = Get-Content -Raw -LiteralPath (Join-Path $SourceClone "tests\$name")
    $metadata = Invoke-RunnerSetupGh @('api', "repos/$Repository")
    if ($metadata.full_name -ine $Repository -or $metadata.private -isnot [bool] -or $metadata.private -ne $true -or -not $metadata.default_branch) { throw 'Acceptance target is public, moved, or has no default branch; select the existing private repository.' }
    $branch = $metadata.default_branch
    $query = '?ref=' + [uri]::EscapeDataString($branch)
    # A successful directory listing proves absence; authentication/server failures never authorize a PUT. Pin every
    # read and the create to the same explicit branch so a changed default cannot redirect a previously checked write.
    $entry = $null
    $directory = ''
    foreach ($part in '.github', 'workflows', $name) {
        $url = "repos/$Repository/contents$directory$query"
        $contents = @(Invoke-RunnerSetupGh @('api', $url))
        if (@($contents | Where-Object { -not $_.name -or $_.type -notin 'file', 'dir', 'symlink', 'submodule' }).Count) { throw 'Unexpected GitHub Contents directory response; no workflow will be written.' }
        $found = @($contents | Where-Object name -ceq $part)
        if ($found.Count -gt 1) { throw 'Ambiguous GitHub Contents response; no workflow will be written.' }
        if (-not $found.Count) { break }
        $entry = $found[0]
        if ($part -ne $name -and $entry.type -cne 'dir') { throw 'Workflow parent is not a directory; no workflow will be written.' }
        $directory += "/$part"
    }
    if ($directory -eq "/$path") {
        if ($entry.type -cne 'file') { throw "Existing $path is not a regular file." }
        $existing = Invoke-RunnerSetupGh @('api', "repos/$Repository/contents/$path$query")
        if ($existing.type -cne 'file' -or $existing.encoding -cne 'base64' -or -not $existing.content) { throw 'Unexpected GitHub workflow content response.' }
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing.content))
        if ($text.Replace("`r`n", "`n").TrimEnd() -cne $template.Replace("`r`n", "`n").TrimEnd()) { throw "Existing $path differs; it will not be overwritten. Review it before rerunning." }
    } elseif ($InstallWorkflow) {
        # No sha is supplied: a file created by somebody else since the listing causes GitHub to reject this create.
        Send-RunnerSetupGh @('api', '-X', 'PUT', "repos/$Repository/contents/$path") @{ branch = $branch; message = 'Add controlled Windows runner acceptance workflow'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($template)) } | Out-Null
    } else { throw "$path is absent. Use -InstallWorkflow to install it." }
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        & gh api "repos/$Repository/actions/workflows/$name" --silent 2>$null | Out-Null
        if (-not $LASTEXITCODE) { return $branch }
        Start-Sleep -Seconds 5
    }
    throw 'Controlled acceptance workflow was not indexed by Actions.'
}

function Sync-RunnerAcceptanceFixture {
    param([string] $Directory)
    $repository = 'https://github.com/The-Running-Dev/GitHub-ActionTemplates.git'
    $commit = '1c3b5f76554aca455cd4a284c4e473edd21c0d72'
    if (-not (Test-Path -LiteralPath $Directory)) { Invoke-RunnerSetupGit @('clone', '--no-checkout', $repository, $Directory) }
    else {
        $origin = Invoke-RunnerSetupGit @('-C', $Directory, 'remote', 'get-url', 'origin') -Capture
        if ($origin -ne $repository -or (Invoke-RunnerSetupGit @('-C', $Directory, 'status', '--porcelain') -Capture)) { throw "Fixture checkout is unexpected or dirty: $Directory. It will not be overwritten." }
    }
    Invoke-RunnerSetupGit @('-C', $Directory, 'fetch', '--depth', '1', 'origin', $commit)
    Invoke-RunnerSetupGit @('-C', $Directory, 'checkout', '--detach', 'FETCH_HEAD')
    Join-Path $Directory 'tests\fixtures\docusaurus'
}

function Invoke-RunnerAcceptanceLifecycle {
    param([string] $InstallRoot, [string] $Repository, [string] $SourceClone, [string[]] $Clones, [object[]] $Instances, [hashtable] $State, [string] $Mode, [string] $WorkflowBranch, [string] $PairLabel)
    if (-not $PairLabel) { $PairLabel = "subzerodev-pair-$($env:COMPUTERNAME.ToLowerInvariant())" }
    $correlation = [guid]::NewGuid().ToString('N')
    # Read-only lookups come first: a failure here cannot have dispatched anything, so it must not leave a journal that blocks setup.
    if (-not $WorkflowBranch) { $WorkflowBranch = (Invoke-RunnerSetupGh @('api', "repos/$Repository")).default_branch }
    # Persist correlation BEFORE dispatch; a crash before its response is recovered by listing this exact title on resume.
    $State.activeRun = @{ id = 0; correlation = $correlation; workflow = 'windows-runner-lifecycle-acceptance.yml'; branch = $WorkflowBranch; clone = ''; stopAttempted = $false }
    Save-RunnerAcceptanceState $InstallRoot $State
    $hold = if ($Mode -eq 'Drain') { 60 } else { 240 }
    try {
        try {
            Send-RunnerSetupGh @('api', '-X', 'POST', "repos/$Repository/actions/workflows/windows-runner-lifecycle-acceptance.yml/dispatches") @{
                ref = $WorkflowBranch; inputs = @{ correlation = $correlation; runner_label = $PairLabel; hold_seconds = "$hold" }
            } | Out-Null
        } catch {
            # A refused dispatch (HTTP 4xx) created no run, so keeping its journal would block every later setup with nothing to recover.
            if ($_.Exception.Data['Rejected']) { $State.activeRun = $null; Save-RunnerAcceptanceState $InstallRoot $State }
            throw
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        $job = @()
        do {
            if (-not $State.activeRun.id) {
                $run = Find-RunnerAcceptanceRun $Repository $correlation
                if ($run) { $State.activeRun.id = $run.id; Save-RunnerAcceptanceState $InstallRoot $State }
            }
            if ($State.activeRun.id) {
                $jobs = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/runs/$($State.activeRun.id)/jobs?filter=latest&per_page=100")
                $job = @($jobs.jobs | Where-Object { $_.name -ceq 'Controlled lifecycle job' -and $_.run_id -eq $State.activeRun.id -and $_.run_attempt -eq 1 -and $_.status -eq 'in_progress' -and @($_.steps | Where-Object { $_.name -eq 'Hold controlled acceptance job' -and $_.status -eq 'in_progress' }).Count -eq 1 })
                if ($job.Count -eq 1) { break }
            }
            Start-Sleep -Seconds 3
        } while ([DateTime]::UtcNow -lt $deadline)
        if (@($job).Count -ne 1) { throw 'No controlled hold step started within five minutes. Check runner-group access and occupied slots.' }
        $matched = @($Instances | Where-Object { $_.Name -ceq $job[0].runner_name -and $_.AgentId -eq $job[0].runner_id })
        if ($matched.Count -ne 1) { throw 'Controlled job ran on an unexpected runner identity; no local runner will be stopped.' }
        $clone = Join-Path $InstallRoot $matched[0].Instance
        if ($clone -notin $Clones) { throw 'Controlled runner clone is outside the requested installation.' }
        $facts = Get-RunnerAcceptanceFacts $clone
        if (-not $facts.registered -or $facts.agentName -cne $matched[0].Name -or $facts.agentId -ne $matched[0].AgentId) { throw 'Local registration changed after setup; no stop was attempted.' }
        $before = Get-RunnerAcceptanceStatus $clone
        if ("$($before.Job)" -notlike 'running*' -or $before.Maintenance) { throw 'Controlled runner is not busy or is held in maintenance. No stop was attempted.' }
        # Recheck the hold immediately before touching the runner (not just its job's earlier checkout/setup step).
        $remoteRun = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/runs/$($State.activeRun.id)")
        Assert-RunnerAcceptanceRun $remoteRun $State.activeRun
        $latest = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/runs/$($State.activeRun.id)/jobs?filter=latest&per_page=100")
        $stillHolding = @($latest.jobs | Where-Object { $_.id -eq $job[0].id -and $_.name -ceq 'Controlled lifecycle job' -and $_.run_id -eq $State.activeRun.id -and $_.run_attempt -eq 1 -and $_.runner_name -ceq $matched[0].Name -and $_.runner_id -eq $matched[0].AgentId -and $_.status -eq 'in_progress' -and @($_.steps | Where-Object { $_.name -ceq 'Hold controlled acceptance job' -and $_.status -eq 'in_progress' }).Count -eq 1 })
        if ($stillHolding.Count -ne 1) { throw 'The controlled hold ended or its job/runner identity changed; no stop was attempted.' }
        $State.activeRun.clone = $clone; $State.activeRun.stopAttempted = $true
        Save-RunnerAcceptanceState $InstallRoot $State
        Invoke-RunnerAcceptanceProcess (Join-Path $SourceClone 'tests\Invoke-WindowsHostAcceptance.ps1') @{
            Clones = $Clones; Stage = @($Mode); DisruptiveClone = $clone; AllowDisruptive = $true; TimeoutMinutes = 1
            ReportPath = (Join-Path $InstallRoot "acceptance\$Mode.md")
        }
        if ($Mode -eq 'Drain') {
            $done = Wait-RunnerAcceptanceRun $Repository $State.activeRun.id -ExpectedRun $State.activeRun
            if ($done.conclusion -ne 'success') { throw 'The drained controlled job did not finish successfully.' }
        } elseif ($Mode -eq 'Timeout') {
            $live = Invoke-RunnerSetupGh @('api', "repos/$Repository/actions/runs/$($State.activeRun.id)")
            Assert-RunnerAcceptanceRun $live $State.activeRun
            if ($live.status -ne 'in_progress') { throw 'The timed-out controlled job was not retained in progress.' }
        }
        $State.activeRun.stopAttempted = $false
        Save-RunnerAcceptanceState $InstallRoot $State
    } finally {
        # Only clear the journal once cancellation/completion is confirmed. A failed stop keeps stopAttempted so that a later
        # setup cannot call the installer (which starts supervisors) before checking its maintenance hold.
        if ($State.activeRun -and $State.activeRun.id) {
            Stop-RunnerAcceptanceRun $Repository $State.activeRun | Out-Null
            if (-not $State.activeRun.stopAttempted) { $State.activeRun = $null; Save-RunnerAcceptanceState $InstallRoot $State }
        }
    }
}

function Invoke-RunnerSetupAcceptance {
    param([string] $InstallRoot, [string] $Repository, [object[]] $Instances, [hashtable] $SetupOptions)
    $clones = @($Instances | ForEach-Object { Join-Path $InstallRoot $_.Instance })
    $source = $clones[0]
    # Setup gives the first two runners the pair label of the host ID (-HostId), or of the computer name without one.
    $pairLabel = "subzerodev-pair-$(if ($SetupOptions.HostId) { $SetupOptions.HostId } else { $env:COMPUTERNAME.ToLowerInvariant() })"
    $state = Get-RunnerAcceptanceState $InstallRoot
    $material = @($Repository, $SetupOptions.SourceCommit, $SetupOptions.GitHubUrl, $SetupOptions.Count, $clones, $Instances.Instance, $Instances.Name, $Instances.AgentId)
    # Only when set, so profiles recorded before -HostId existed stay valid; a changed ID re-verifies against its pair label.
    if ($SetupOptions.HostId) { $material += "hostId=$($SetupOptions.HostId)" }
    foreach ($clone in $clones) { foreach ($file in 'runners.json', 'runners.local.json') { $material += (Get-FileHash -LiteralPath (Join-Path $clone $file) -Algorithm SHA256).Hash } }
    $profile = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($material | ConvertTo-Json -Depth 5 -Compress))))
    if ($state.activeRun) { throw 'A previous controlled run needs cleanup before acceptance can continue.' }
    if ($state.profile -ne $profile) { $state = @{ version = 1; repository = $Repository; profile = $profile; completed = @{}; activeRun = $null } }
    Save-RunnerAcceptanceState $InstallRoot $state
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'acceptance') -Force | Out-Null
    # Readiness is live on EVERY invocation, including resumes. Completed checkpoints are reused only for the same source,
    # registration IDs and configuration. They describe historical runs, not current continuous monitoring.
    Invoke-RunnerAcceptanceProcess (Join-Path $source 'tests\Invoke-WindowsHostAcceptance.ps1') @{ Clones = $clones; Stage = @('Readiness'); ReportPath = (Join-Path $InstallRoot 'acceptance\readiness.md') }
    $fixture = Sync-RunnerAcceptanceFixture (Join-Path $InstallRoot 'acceptance\fixture')
    foreach ($stage in 'Host', 'Builds', 'Drain', 'Timeout', 'Force') {
        if ($state.completed.ContainsKey($stage)) { Write-Host "Acceptance checkpoint retained: $stage ($($state.completed[$stage]))."; continue }
        switch ($stage) {
            Host {
                # Re-run setup without verification dispatch (no recursion), using a JSON options file for exact arguments.
                $optionsPath = Join-Path $InstallRoot 'acceptance\rerun-options.json'
                $SetupOptions | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $optionsPath -Encoding utf8
                $worker = Join-Path $source 'scripts\Configure-WindowsRunners.ps1'
                $command = '& ' + "'$($worker.Replace("'", "''"))' -OptionsPath '$($optionsPath.Replace("'", "''"))'"
                Invoke-RunnerAcceptanceProcess (Join-Path $source 'tests\Invoke-WindowsHostAcceptance.ps1') @{ Clones = $clones; Stage = @('Build', 'Adoption', 'Rerun'); FixtureDirectory = $fixture; SetupCommand = $command; ReportPath = (Join-Path $InstallRoot 'acceptance\host.md') }
            }
            Builds {
                Invoke-RunnerAcceptanceProcess (Join-Path $source 'tests\Invoke-WindowsRunnerBuildAgentAcceptance.ps1') @{ Repository = $Repository; InstallWorkflow = $true; RunnerLabel = $pairLabel; ExpectedRunnerNames = @($Instances[0..1].Name); TimeoutMinutes = 60; ReportDirectory = (Join-Path $InstallRoot 'acceptance\builds'); StateDirectory = $InstallRoot }
            }
            default {
                $workflowBranch = Install-RunnerAcceptanceWorkflow $Repository $source
                Invoke-RunnerAcceptanceLifecycle -InstallRoot $InstallRoot -Repository $Repository -SourceClone $source -Clones $clones -Instances $Instances -State $state -Mode $stage -WorkflowBranch $workflowBranch -PairLabel $pairLabel
            }
        }
        $state.completed[$stage] = [DateTime]::UtcNow.ToString('o')
        Save-RunnerAcceptanceState $InstallRoot $state
    }
    Set-SetupStep $InstallRoot 'acceptance'
}
