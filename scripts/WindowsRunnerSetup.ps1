#Requires -Version 7.2
# Testable host orchestration. Dot-sourcing this file does not install or register anything.

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
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
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
    # Prove runner administration access without printing or persisting a registration token.
    & gh api -X POST "$Scope/actions/runners/registration-token" --silent
    if ($LASTEXITCODE -and -not $NonInteractive -and -not $tokenEnvironment) {
        & gh auth refresh --hostname github.com --scopes $scopes
        if ($LASTEXITCODE) { throw 'GitHub scope authorization failed.' }
        & gh api -X POST "$Scope/actions/runners/registration-token" --silent
    }
    if ($LASTEXITCODE) { throw 'The active GitHub credential cannot administer runners at the requested target.' }
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
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $WindowsTaskName -ErrorAction Stop
    if ($task.Actions.Execute -ne $Pwsh -or -not $task.Actions.Arguments.Contains('"' + $Supervisor + '"') -or $task.Actions.WorkingDirectory -ne $WindowsRunner) { throw "Wrong startup action for $InstanceId." }
    if ($task.Principal.LogonType -ne 'Interactive' -or $task.Principal.RunLevel -ne 'Limited' -or $task.Settings.MultipleInstances -ne 'IgnoreNew' -or $task.Settings.ExecutionTimeLimit -ne 'PT0S') { throw "Unsafe startup task settings for $InstanceId." }
    if ($Config.logs.trimAt) {
        $trim = Get-ScheduledTask -TaskPath $TaskPath -TaskName $LogTrimTaskName -ErrorAction Stop
        if (-not $trim.Actions.Arguments.Contains((Join-Path $Clone 'scripts\Trim-RunnerLogs.ps1'))) { throw "Wrong trim task for $InstanceId." }
    }
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
    $result = $payload | & gh @Arguments --input -
    if ($LASTEXITCODE) { throw 'GitHub write failed. A smoke workflow needs repository write access and workflow permission; existing credentials may need gh auth refresh --scopes repo,workflow.' }
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
    Write-Host 'Verified on this host: registrations online, unique identities/workspaces/processes, startup tasks and labels.'
}

function Invoke-WindowsRunnerHostSetup {
    param(
        [ValidateRange(1, 16)] [int] $Count,
        [string] $InstallRoot,
        [string] $GitHubUrl,
        [string[]] $ExtraLabels,
        [ValidatePattern('^[0-9a-f]{40}$')] [string] $SourceCommit,
        [string] $SmokeRepository,
        [bool] $NonInteractive
    )
    $scope = Get-RunnerSetupScope $GitHubUrl
    if ($SmokeRepository -and $Count -lt 2) { throw 'A concurrent-job smoke test requires at least two runners.' }
    if ($SmokeRepository -and $SmokeRepository -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*/[a-zA-Z0-9][a-zA-Z0-9_.-]*$') { throw 'SmokeRepository must be owner/repository.' }
    if ($SmokeRepository -and (($scope.StartsWith('orgs/') -and $SmokeRepository.Split('/')[0] -ine $scope.Split('/')[1]) -or ($scope.StartsWith('repos/') -and $SmokeRepository -ine $scope.Substring(6)))) { throw 'The smoke repository must be within the runner organization, or match its repository-scoped target.' }
    Confirm-RunnerSetupAuthentication -Scope $scope -NonInteractive $NonInteractive -WithSmoke ([bool]$SmokeRepository)
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
    if ($SmokeRepository) {
        Invoke-RunnerSetupSmoke -Repository $SmokeRepository -Label $pairLabel -SourceClone (Join-Path $InstallRoot 'win01') -ExpectedRunnerNames @($instances[0..1].Name)
    } else {
        Write-Host 'Actual concurrent-job execution has not been tested. Add -SmokeRepository OWNER/REPO to run and verify it automatically.'
    }
    Write-Host "Setup complete: $Count runner(s). Automatic startup occurs when this Windows user signs in."
}
