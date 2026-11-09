#Requires -Version 7.2
# Testable host orchestration. Dot-sourcing this file does not install or register anything.
. "$PSScriptRoot\SetupState.ps1"
. "$PSScriptRoot\WindowsRunnerAcceptance.ps1"

function Invoke-RunnerSetupGit {
    param([string[]] $Arguments, [switch] $Capture)
    $result = & git @Arguments
    if ($LASTEXITCODE) { throw "Git failed (exit $LASTEXITCODE). No existing checkout will be reset or cleaned." }
    if ($Capture) { $result } else { $result | Out-Host }
}

function Invoke-RunnerSetupGh {
    param([string[]] $Arguments)
    $result = & gh @Arguments
    if ($LASTEXITCODE) { throw "GitHub operation failed (exit $LASTEXITCODE). Check authentication, permissions and network access." }
    if (-not $result) { throw 'GitHub read returned no JSON; no absence or completion can be inferred.' }
    $decoded = ($result -join "`n") | ConvertFrom-Json
    if (($result -join "`n").Trim() -eq 'null') { throw 'GitHub read returned null instead of a resource.' }
    $decoded
}

function Get-RunnerSetupScope([string] $GitHubUrl) {
    $uri = [uri]$GitHubUrl
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'GitHubUrl must be an HTTPS github.com organization or repository URL.' }
    $parts = $uri.AbsolutePath.Trim('/').Split('/')
    if ($parts.Count -notin 1, 2 -or @($parts | Where-Object { $_ -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' }).Count) { throw 'GitHubUrl must name one organization or one owner/repository.' }
    if ($parts.Count -eq 1) { "orgs/$($parts[0])" } else { "repos/$($parts[0])/$($parts[1])" }
}

function Confirm-RunnerSetupAuthentication {
    param([string] $Scope, [bool] $NonInteractive, [bool] $WithSmoke)
    $tokenEnvironment = [bool]($env:GH_TOKEN -or $env:GITHUB_TOKEN)
    $scopes = if ($Scope.StartsWith('orgs/')) { 'admin:org' } else { 'repo' }
    if ($WithSmoke) { $scopes += ',repo,workflow' }
    & gh auth status --hostname github.com *> $null
    if ($LASTEXITCODE) {
        if ($NonInteractive -or $tokenEnvironment) { throw 'Valid GitHub credentials are required. Provision GH_TOKEN or sign in once with gh auth login.' }
        & gh auth login --hostname github.com --web --git-protocol https --scopes $scopes
        if ($LASTEXITCODE) { throw 'GitHub authorization failed.' }
    }
    if ($WithSmoke -and -not $tokenEnvironment) {
        $headers = & gh api --include user
        if ($LASTEXITCODE) { throw 'Cannot inspect the active GitHub authorization.' }
        $scopeHeader = $headers | Where-Object { $_ -imatch '^X-OAuth-Scopes:' } | Select-Object -First 1
        if ($scopeHeader -and 'workflow' -notin (($scopeHeader -replace '^[^:]+:', '').Split(',').Trim())) {
            if ($NonInteractive) { throw 'The stored GitHub login lacks workflow permission. Provision the required scope before unattended smoke setup.' }
            & gh auth refresh --hostname github.com --scopes $scopes
            if ($LASTEXITCODE) { throw 'GitHub workflow authorization failed.' }
        }
    }
    # Prove runner administration access without printing or persisting a registration token.
    & gh api -X POST "$Scope/actions/runners/registration-token" --silent
    if ($LASTEXITCODE -and -not $NonInteractive -and -not $tokenEnvironment) {
        & gh auth refresh --hostname github.com --scopes $scopes
        if ($LASTEXITCODE) { throw 'GitHub scope authorization failed.' }
        & gh api -X POST "$Scope/actions/runners/registration-token" --silent
    }
    if ($LASTEXITCODE) { throw 'The active GitHub credential cannot administer runners at the requested target.' }
}

# Read-only repository preflight. Scope compatibility is necessary, but does not prove runner-group
# access, workflow label selection, installed toolchains or that a job has actually executed.
function Confirm-RunnerSetupRepositories {
    [CmdletBinding()]
    param([string] $Scope, [string[]] $Repositories)
    if (-not $Repositories.Count -and $Scope.StartsWith('repos/')) { $Repositories = @($Scope.Substring(6)) }
    if (-not $Repositories.Count) {
        Write-Warning 'No -TargetRepositories supplied: repository eligibility has not been checked for this organization registration.'
        return
    }
    # Reject every malformed/cross-scope target before making repository API calls.
    foreach ($repository in $Repositories) {
        if ($repository -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'TargetRepositories must contain owner/repository names.' }
        if (($Scope.StartsWith('orgs/') -and $repository.Split('/')[0] -ine $Scope.Substring(5)) -or
            ($Scope.StartsWith('repos/') -and $repository -ine $Scope.Substring(6))) {
            throw "Runner scope $Scope cannot serve $repository. Use its repository-scoped -GitHubUrl or register within the organization that owns it. No runner instance has been changed."
        }
    }
    foreach ($repository in @($Repositories | Select-Object -Unique)) {
        $metadata = Invoke-RunnerSetupGh -Arguments @('api', "repos/$repository")
        if ($metadata.full_name -ine $repository) { throw "Repository $repository moved or could not be verified. Use its current owner/repository and registration URL." }
        if ($Scope.StartsWith('orgs/') -and $metadata.owner.type -ne 'Organization') { throw "$repository is not owned by an organization; personal accounts have no shared account-level runner pool." }
        if ($metadata.archived -or $metadata.disabled) { throw "Repository $repository is archived or disabled." }
        $policy = Invoke-RunnerSetupGh -Arguments @('api', "repos/$repository/actions/permissions")
        if ($policy.enabled -ne $true) { throw "GitHub Actions is disabled or its enabled state could not be verified for $repository." }
        $repository
    }
}

function Sync-RunnerSetupInstance {
    param([string] $Clone, [string] $InstanceId, [string] $SourceCommit, [string] $GitHubUrl)
    $repository = 'https://github.com/The-Running-Dev/SubZeroDev.Runners.git'
    $fetched = $false
    if (-not (Test-Path -LiteralPath $Clone)) {
        Invoke-RunnerSetupGit -Arguments @('clone', '--no-checkout', $repository, $Clone)
    } else {
        if (-not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) { throw "Not a runner checkout: $Clone" }
        $origin = Invoke-RunnerSetupGit -Arguments @('-C', $Clone, 'remote', 'get-url', 'origin') -Capture
        if ($origin -ne $repository) { throw "Unexpected repository at $Clone" }
        $dirty = Invoke-RunnerSetupGit -Arguments @('-C', $Clone, 'status', '--porcelain') -Capture
        if ($dirty) { throw "Local changes at $Clone; setup will not reset or clean them." }
        $localPath = Join-Path $Clone 'runners.local.json'
        if (Test-Path -LiteralPath $localPath) {
            $local = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json
            if ($local.windows.instanceId -and $local.windows.instanceId -ne $InstanceId) { throw "Clone $Clone belongs to another instance." }
            if ($local.github.url -and $local.github.url.TrimEnd('/') -ine $GitHubUrl.TrimEnd('/')) { throw "Clone $Clone is registered to another GitHub target. Use its original -GitHubUrl or a separate install root." }
        }
        # Preserve commits as well as unstaged files. Only a forward update is allowed.
        Invoke-RunnerSetupGit -Arguments @('-C', $Clone, 'fetch', 'origin', $SourceCommit)
        $fetched = $true
        & git -C $Clone merge-base --is-ancestor HEAD FETCH_HEAD
        if ($LASTEXITCODE) { throw "Requested source would discard commits at $Clone. Update or reconcile that checkout explicitly." }
    }
    if (-not $fetched) { Invoke-RunnerSetupGit -Arguments @('-C', $Clone, 'fetch', 'origin', $SourceCommit) }
    Invoke-RunnerSetupGit -Arguments @('-C', $Clone, 'checkout', '--detach', 'FETCH_HEAD')
}

function Install-RunnerSetupInstance {
    param([string] $Clone, [string] $InstanceId, [string] $GitHubUrl, [string[]] $Labels)
    $localPath = Join-Path $Clone 'runners.local.json'
    if (Test-Path -LiteralPath $localPath) {
        $saved = Get-Content -Raw -LiteralPath $localPath | ConvertFrom-Json
        $Labels = @(@($saved.windows.labels) + $Labels | Where-Object { $_ } | Select-Object -Unique)
    }
    & (Join-Path $Clone 'scripts\Install-WindowsRunner.ps1') -InstanceId $InstanceId -GitHubUrl $GitHubUrl -ExtraLabels $Labels
}

function Get-RunnerSetupEvidence {
    param([string] $Clone, [string] $InstanceId)
    . (Join-Path $Clone 'scripts\Common.ps1')
    $registration = Get-Content -Raw -LiteralPath (Join-Path $WindowsRunner '.runner') | ConvertFrom-Json
    if ($Config.windows.instanceId -ne $InstanceId -or $registration.agentName -ne $Config.windows.name) { throw "Registration identity mismatch for $InstanceId." }
    # Nothing may start the supervisor behind the operator's back. The installer verified this instance's legacy startup entries
    # gone (or never present) and recorded it; this reads that record. It does not ask Task Scheduler, so another clone's task
    # of the same name cannot block this instance and the scheduler is not needed to verify setup.
    if (-not (Get-LegacyMigration)) { throw "The legacy startup migration of $InstanceId is not recorded as complete ($LegacyMigrationFile); rerun scripts\Install-WindowsRunner.ps1 or scripts\Remove-LegacyTasks.ps1 in that clone." }
    $supervisorProcess = Get-SupervisorProcess
    if (-not $supervisorProcess) { throw "Supervisor is not running for $InstanceId." }
    $dotnet = Join-Path $WindowsRunner '_tool\dotnet\dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet)) { throw "Private .NET SDK is missing for $InstanceId." }
    $sdkOutput = @(& $dotnet --version)
    $sdk = $sdkOutput | Select-Object -Last 1
    if ($LASTEXITCODE -or $sdk -notmatch '^10\.') { throw "Private .NET 10 SDK is not working for $InstanceId." }
    $workspace = [Environment]::ExpandEnvironmentVariables($Config.windows.workFolder)
    if (-not [IO.Path]::IsPathRooted($workspace)) { $workspace = Join-Path $WindowsRunner $workspace }
    [pscustomobject]@{ Instance = $InstanceId; Name = $registration.agentName; AgentId = $registration.agentId; Workspace = [IO.Path]::GetFullPath($workspace); SupervisorPid = $supervisorProcess.ProcessId; Labels = @($Config.github.labels) + @($Config.windows.labels) }
}

function Send-RunnerSetupGh {
    param([string[]] $Arguments, [object] $Body)
    $payload = $Body | ConvertTo-Json -Depth 10 -Compress
    $output = @($payload | & gh @Arguments --input - 2>&1)
    if ($LASTEXITCODE) {
        $exception = [Exception]::new('GitHub write failed. A smoke workflow needs repository write access and workflow permission; existing credentials may need gh auth refresh --scopes repo,workflow.')
        # An HTTP 4xx answer proves GitHub refused the request, so nothing was created and a journaled intent can be discarded.
        # Timeouts, 5xx and transport errors are ambiguous and are not marked: the request may have been processed.
        if (($output | Out-String) -match '\(HTTP (4\d\d)\)' -and $Matches[1] -ne '408') { $exception.Data['Rejected'] = $true }
        throw $exception
    }
    $result = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Invoke-RunnerSetupSmoke {
    param([string] $Repository, [string] $Label, [string] $SourceClone, [string[]] $ExpectedRunnerNames)
    $json = & gh api "repos/$Repository" 2>$null
    if ($LASTEXITCODE) {
        Write-Host "Creating private smoke repository $Repository..."
        & gh repo create $Repository --private --description 'Manual native Windows runner concurrency validation'
        if ($LASTEXITCODE) { throw "Cannot access or create smoke repository $Repository." }
        $repo = Invoke-RunnerSetupGh -Arguments @('api', "repos/$Repository")
    } else { $repo = ($json -join "`n") | ConvertFrom-Json }
    if (-not $repo.private) { throw 'Use a private smoke repository. Setup will not change repository visibility.' }
    $template = Get-Content -Raw -LiteralPath (Join-Path $SourceClone 'tests\windows-runner-smoke.yml')
    $workflowPath = '.github/workflows/windows-runner-smoke.yml'
    $existing = & gh api "repos/$Repository/contents/$workflowPath" 2>$null
    if ($LASTEXITCODE -eq 0) {
        $existing = ($existing -join "`n") | ConvertFrom-Json
        $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing.content))
        if ($content.Replace("`r`n", "`n").TrimEnd() -cne $template.Replace("`r`n", "`n").TrimEnd()) { throw "Existing $workflowPath differs. Review it explicitly or choose a dedicated smoke repository; it will not be overwritten." }
    } else {
        Send-RunnerSetupGh -Arguments @('api', '-X', 'PUT', "repos/$Repository/contents/$workflowPath") -Body @{ message = 'Add manual Windows runner concurrency smoke test'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($template)) } | Out-Null
    }
    # Newly committed workflows can take a moment to appear in the Actions API.
    $indexed = $false
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        & gh api "repos/$Repository/actions/workflows/windows-runner-smoke.yml" --silent 2>$null
        if ($LASTEXITCODE -eq 0) { $indexed = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $indexed) { throw 'The smoke workflow is not available in Actions. Check repository Actions policy and rerun setup.' }
    $setupId = [guid]::NewGuid().ToString('N')
    Send-RunnerSetupGh -Arguments @('api', '-X', 'POST', "repos/$Repository/actions/workflows/windows-runner-smoke.yml/dispatches") -Body @{ ref = $repo.default_branch; inputs = @{ computer_name = $env:COMPUTERNAME; runner_label = $Label; runner_names = (ConvertTo-Json -InputObject @($ExpectedRunnerNames) -Compress); setup_id = $setupId } } | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(8)
    $run = $null
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not $run) {
                $runs = Invoke-RunnerSetupGh -Arguments @('api', "repos/$Repository/actions/workflows/windows-runner-smoke.yml/runs?event=workflow_dispatch&per_page=100")
                $run = $runs.workflow_runs | Where-Object display_title -eq "Windows runner smoke $setupId" | Select-Object -First 1
            } else { $run = Invoke-RunnerSetupGh -Arguments @('api', "repos/$Repository/actions/runs/$($run.id)") }
            if ($run -and $run.status -eq 'completed') { break }
            Start-Sleep -Seconds 5
        }
        if (-not $run -or $run.status -ne 'completed') { throw 'Smoke dispatch did not complete in eight minutes. Check runner-group repository access and whether the two slots are occupied.' }
        if ($run.conclusion -ne 'success') { throw "Smoke jobs failed: $($run.html_url)" }
        & (Join-Path $SourceClone 'tests\Assert-WindowsRunnerSmoke.ps1') -Repository $Repository -RunId $run.id -ExpectedRunnerNames $ExpectedRunnerNames | Out-Host
        Write-Host "Actual concurrent GitHub jobs verified: $($run.html_url)"
    } finally {
        if ($run -and $run.status -ne 'completed') {
            & gh api -X POST "repos/$Repository/actions/runs/$($run.id)/cancel" --silent
            if ($LASTEXITCODE) { Write-Warning "Could not cancel unfinished smoke run $($run.id)." }
        }
    }
}

function Confirm-RunnerSetupHost {
    param([object[]] $Instances, [string] $Scope)
    foreach ($field in 'Name', 'AgentId', 'Workspace', 'SupervisorPid') {
        if (@($Instances.$field | Select-Object -Unique).Count -ne $Instances.Count) { throw "Runner instances share $field." }
    }
    $pages = Invoke-RunnerSetupGh -Arguments @('api', "$Scope/actions/runners", '--paginate', '--slurp')
    $all = @($pages | ForEach-Object { $_.runners })
    foreach ($instance in $Instances) {
        $remote = @($all | Where-Object { $_.name -eq $instance.Name })
        if ($remote.Count -ne 1 -or $remote[0].id -ne $instance.AgentId -or $remote[0].status -ne 'online') { throw "Runner is offline or its GitHub ID does not match: $($instance.Name)" }
        $missing = @($instance.Labels | Where-Object { $_ -notin $remote[0].labels.name })
        if ($missing.Count) {
            # Add host/smoke targeting labels to adopted installations without replacing other custom labels.
            $payload = @{ labels = $missing } | ConvertTo-Json -Compress
            $payload | & gh api -X POST "$Scope/actions/runners/$($instance.AgentId)/labels" --input - --silent
            if ($LASTEXITCODE) { throw "Cannot add targeting labels to $($instance.Name)." }
            $labels = Invoke-RunnerSetupGh -Arguments @('api', "$Scope/actions/runners/$($instance.AgentId)/labels")
            if (@($instance.Labels | Where-Object { $_ -notin $labels.labels.name }).Count) { throw "Targeting labels are missing on $($instance.Name)." }
        }
    }
    $Instances | Select-Object Instance, Name, AgentId, Workspace, SupervisorPid | Format-Table -AutoSize | Out-Host
    Write-Host 'Verified on this host: registrations online, unique identities/workspaces/processes, recorded legacy-startup migration and labels.'
}

# Provisions or verifies the host-level BuildAgent integration from an instance's clone, in its own PowerShell so the clone's
# configuration is the one that applies. Returns the exit code: 0 ready, 1 failed, 2 the person has to act first (the actions
# are in the install root's setup state).
function Install-RunnerSetupBuildAgent {
    param([string] $Clone, [string] $InstallRoot)
    $pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    & $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Clone 'scripts\Install-BuildAgent.ps1') -InstallRoot $InstallRoot | Out-Host
    $LASTEXITCODE
}

# Setup keeps going when the optional BuildAgent integration cannot be completed: the registered runners are already verified,
# and a failure here is reported at the end with a non-zero exit instead of undoing or blocking them.
function Invoke-WindowsRunnerHostSetup {
    param(
        [ValidateRange(1, 16)] [int] $Count,
        [string] $InstallRoot,
        [string] $GitHubUrl,
        [string[]] $ExtraLabels,
        [string[]] $TargetRepositories = @(),
        [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceCommit,
        [string] $SmokeRepository,
        [string] $VerificationRepository,
        [bool] $NonInteractive,
        [bool] $SkipBuildAgent
    )
    # Dropping -Repository must not bypass an interrupted stop/dispatch and let the installer reopen maintenance.
    $journal = Get-RunnerAcceptanceState $InstallRoot
    if ($journal.activeRun -and (-not $VerificationRepository -or $journal.repository -ine $VerificationRepository)) { throw 'Interrupted acceptance requires its original -Repository before any runner can be installed or started.' }
    foreach ($pending in @(Get-SetupPendingAction $InstallRoot)) { Write-Host "Resuming; still pending from the last run: [$($pending.kind)] $($pending.message)" }
    $scope = Get-RunnerSetupScope $GitHubUrl
    if ($VerificationRepository) {
        if ($Count -lt 2 -or $SkipBuildAgent) { throw 'Automated verification needs at least two runners and BuildAgent enabled.' }
        if ($VerificationRepository -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'Repository must be owner/repository.' }
        if (($scope.StartsWith('orgs/') -and $VerificationRepository.Split('/')[0] -ine $scope.Substring(5)) -or ($scope.StartsWith('repos/') -and $VerificationRepository -ine $scope.Substring(6))) { throw 'The verification repository must be in the runner registration scope.' }
    }
    if ($SmokeRepository -and $Count -lt 2) { throw 'A concurrent-job smoke test requires at least two runners.' }
    if ($SmokeRepository -and $SmokeRepository -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'SmokeRepository must be owner/repository.' }
    if ($SmokeRepository -and (($scope.StartsWith('orgs/') -and $SmokeRepository.Split('/')[0] -ine $scope.Split('/')[1]) -or ($scope.StartsWith('repos/') -and $SmokeRepository -ine $scope.Substring(6)))) { throw 'The smoke repository must be within the runner organization, or match its repository-scoped target.' }
    Confirm-RunnerSetupAuthentication -Scope $scope -NonInteractive $NonInteractive -WithSmoke ([bool]($SmokeRepository -or $VerificationRepository))
    $targets = @($TargetRepositories)
    if ($VerificationRepository) { $targets += $VerificationRepository }
    $validatedRepositories = @(Confirm-RunnerSetupRepositories -Scope $scope -Repositories $targets)
    if ($VerificationRepository) {
        $verificationTarget = Invoke-RunnerSetupGh -Arguments @('api', "repos/$VerificationRepository")
        if (-not $verificationTarget.private) { throw 'Automated acceptance requires an existing private repository; its visibility will not be changed.' }
        Resume-RunnerSetupAcceptance -InstallRoot $InstallRoot -Repository $VerificationRepository -Count $Count
    }
    if ($validatedRepositories.Count) {
        Write-Host "Repository scope compatibility and Actions-enabled state verified: $($validatedRepositories -join ', ')."
        Write-Host 'These checks do not verify runner-group access, workflow runs-on routing or successful job execution.'
    }
    $computer = $env:COMPUTERNAME.ToLowerInvariant()
    $hostLabel = "subzerodev-host-$computer"
    $pairLabel = "subzerodev-pair-$computer"
    $instances = @(for ($number = 1; $number -le $Count; $number++) {
        $id = 'win{0:D2}' -f $number
        $clone = Join-Path $InstallRoot $id
        Write-Host "Configuring $id..."
        Sync-RunnerSetupInstance -Clone $clone -InstanceId $id -SourceCommit $SourceCommit -GitHubUrl $GitHubUrl
        $labels = @($ExtraLabels) + @($hostLabel)
        if ($number -le 2) { $labels += $pairLabel }
        Install-RunnerSetupInstance -Clone $clone -InstanceId $id -GitHubUrl $GitHubUrl -Labels $labels | Out-Host
        Get-RunnerSetupEvidence -Clone $clone -InstanceId $id
    })
    Confirm-RunnerSetupHost -Instances $instances -Scope $scope
    Set-SetupStep $InstallRoot 'runners'
    $buildAgentExit = 0
    if ($SkipBuildAgent) {
        Write-Host 'BuildAgent integration skipped (-SkipBuildAgent).'
    } else {
        Write-Host 'Provisioning the shared BuildAgent tooling (net8.0 runtime, build-agent tool, Docker, image)...'
        $buildAgentExit = [int](Install-RunnerSetupBuildAgent -Clone (Join-Path $InstallRoot 'win01') -InstallRoot $InstallRoot | Select-Object -Last 1)
    }
    if ($SmokeRepository) {
        Invoke-RunnerSetupSmoke -Repository $SmokeRepository -Label $pairLabel -SourceClone (Join-Path $InstallRoot 'win01') -ExpectedRunnerNames @($instances[0..1].Name)
    } elseif (-not $VerificationRepository) {
        Write-Host 'Actual concurrent-job execution has not been tested. Add -SmokeRepository OWNER/REPO to run and verify it automatically.'
    }
    $exitCode = $buildAgentExit
    $verification = if ($VerificationRepository) { 'blocked' } else { 'not-requested' }
    if ($VerificationRepository -and $buildAgentExit -eq 0) {
        $setupOptions = @{ Count = $Count; InstallRoot = $InstallRoot; GitHubUrl = $GitHubUrl; ExtraLabels = $ExtraLabels; TargetRepositories = $targets; SourceCommit = $SourceCommit; NonInteractive = $NonInteractive; SkipBuildAgent = $false }
        try {
            Invoke-RunnerSetupAcceptance -InstallRoot $InstallRoot -Repository $VerificationRepository -Instances $instances -SetupOptions $setupOptions
            $verification = 'passed'
        } catch {
            $verification = 'failed'; $exitCode = 1
            Write-Warning "Automatic acceptance failed: $($_.Exception.Message) Rerun the same setup command after fixing the cause; verified checkpoints are saved."
        }
    }
    switch ($exitCode) {
        0 { Write-Host "Setup complete: $Count runner(s). The supervisors are running now. Nothing starts them at sign-in or restarts them if they die: run Manage-WindowsRunner.ps1 -Action Start in each clone." }
        2 { Write-Host "Runners are set up ($Count), but BuildAgent needs your action first (listed above). Rerun the same command afterwards; finished steps are skipped." -ForegroundColor Yellow }
        default { Write-Warning "Setup is not verified (exit $exitCode; acceptance $verification). See the failure above; existing registrations are retained." }
    }
    if ($VerificationRepository) { Write-Host "Automated acceptance: $verification. State: $(Join-Path $InstallRoot 'acceptance-state.json')" }
    [pscustomobject]@{ Runners = $Count; BuildAgentExitCode = $buildAgentExit; ExitCode = $exitCode; Verification = $verification; ActionRequired = ($exitCode -eq 2); Instances = $instances; ScopeValidatedRepositories = $validatedRepositories }
}

