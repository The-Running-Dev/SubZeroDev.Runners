# GitHub runner registration, in one place: the runners API, the local .runner registration, and the decision of what a
# run of the installer or Register-Runners.ps1 must do. Dot-source RunnerConfig.ps1 first.
#
# The decision (Get-RegistrationPlan) is a pure function of three facts: the local registration, the runner GitHub has
# under the wanted name, and the wanted settings. Every difference reaches GitHub or is refused with a reason; nothing is
# saved and then ignored.

# Files the Actions runner writes at registration. They are the runner's identity and credentials: cleanup never touches
# them, and Invoke-RunnerRegistration copies them to _recovery before it changes them.
$RunnerRegistrationFiles = @('.runner', '.runner_migrated', '.credentials', '.credentials_migrated', '.credentials_rsaparams')
# Added by the runner itself to every registration; never ours to add or remove.
$RunnerDefaultLabels = @('self-hosted', 'windows', 'linux', 'x64', 'arm64', 'arm')

function Get-RunnerScope([string] $GitHubUrl) {
    $parts = ([Uri]$GitHubUrl).AbsolutePath.Trim('/').Split('/')
    if ($parts.Count -eq 1) { "orgs/$($parts[0])" } else { "repos/$($parts[0])/$($parts[1])" }
}

# gh api, throwing with gh's own message on failure. Returns the output lines.
function Invoke-GhApi([string[]] $Arguments, [string] $Description) {
    $output = & gh api @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE) { throw "$Description failed: $($output -join ' ')" }
    $output
}

function Get-RunnerToken([string] $Scope, [string] $Kind) {
    $token = Invoke-GhApi @('-X', 'POST', "$Scope/actions/runners/$Kind-token", '--jq', '.token') "Requesting a $Kind token for $Scope (gh must be signed in as its admin with the admin:org scope: gh auth refresh --hostname github.com --scopes admin:org)"
    if (-not $token) { throw "No $Kind token for $Scope." }
    ($token | Select-Object -First 1)
}

# The runner GitHub has under $Name, or $null. Labels are every label; CustomLabels excludes the ones the runner adds itself.
function Get-GitHubRunner([string] $Scope, [string] $Name) {
    $lines = Invoke-GhApi @("$Scope/actions/runners", '--paginate', '--jq', '.runners[] | tojson') "Listing runners of $Scope"
    foreach ($line in $lines) {
        $runner = $line | ConvertFrom-Json
        if ($runner.name -ieq $Name) {
            return [pscustomobject]@{
                Id           = [int64]$runner.id
                Name         = $runner.name
                Status       = $runner.status
                Busy         = [bool]$runner.busy
                Labels       = @($runner.labels | ForEach-Object { $_.name })
                CustomLabels = @($runner.labels | Where-Object { $_.type -eq 'custom' } | ForEach-Object { $_.name })
            }
        }
    }
}

function Add-GitHubRunnerLabels([string] $Scope, [int64] $Id, [string[]] $Labels) {
    if (-not $Labels) { return }
    $arguments = @('-X', 'POST', "$Scope/actions/runners/$Id/labels")
    foreach ($label in $Labels) { $arguments += '-f'; $arguments += "labels[]=$label" }
    Invoke-GhApi $arguments "Adding labels $($Labels -join ',') to runner $Id" | Out-Null
}

# Removes every custom label, so no queued job that asks for one can be assigned. The default labels stay.
function Remove-GitHubRunnerCustomLabels([string] $Scope, [int64] $Id) {
    Invoke-GhApi @('-X', 'DELETE', "$Scope/actions/runners/$Id/labels") "Withdrawing the custom labels of runner $Id" | Out-Null
}

function Remove-GitHubRunner([string] $Scope, [int64] $Id) {
    Invoke-GhApi @('-X', 'DELETE', "$Scope/actions/runners/$Id") "Deleting runner $Id from $Scope" | Out-Null
}

# The local registration (.runner), or $null.
function Get-LocalRegistration([string] $RunnerDirectory) {
    $path = Join-Path $RunnerDirectory '.runner'
    if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json }
}

# The work folder as the runner resolves it: absolute as given, or relative to the runner directory.
function Resolve-RunnerWorkFolder([string] $WorkFolder, [string] $RunnerDirectory) {
    $expanded = [Environment]::ExpandEnvironmentVariables($WorkFolder)
    if ([IO.Path]::IsPathRooted($expanded)) { Get-CanonicalPath $expanded } else { Get-CanonicalPath (Join-Path $RunnerDirectory $expanded) }
}

function Test-SameGitHubTarget([string] $A, [string] $B) {
    $A.Trim().TrimEnd('/') -ieq $B.Trim().TrimEnd('/')
}

# What to do, and why. Action: none | register | reconfigure | refuse. Pure: reads nothing.
#   Local        .runner contents or $null          Remote  Get-GitHubRunner result for the wanted name or $null
#   Wanted*      the settings that should be in force
function Get-RegistrationPlan {
    param(
        $Local,
        # The runner GitHub has under the wanted name, or $null.
        $Remote,
        # The runner GitHub has under this clone's own registration (its saved name and target), or $null.
        $LocalRemote,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $GitHubUrl,
        [Parameter(Mandatory)] [string[]] $Labels,
        [Parameter(Mandatory)] [string] $WorkFolder,
        [Parameter(Mandatory)] [string] $RunnerDirectory,
        [bool] $HasCredentials = $true,
        [switch] $Replace
    )
    $reasons = [Collections.Generic.List[string]]::new()
    $refusals = [Collections.Generic.List[string]]::new()
    $wantedFolder = Resolve-RunnerWorkFolder $WorkFolder $RunnerDirectory
    $labelsToAdd = @()
    $preserve = @()
    $linked = $null
    $action = 'none'
    if (-not $Local) {
        if ($Remote -and -not $Replace) {
            $refusals.Add("A runner named $Name is already registered elsewhere (id $($Remote.Id), $($Remote.Status)). Pick another name, or pass -Replace to take its place; that machine then stops receiving jobs.")
        }
        $action = 'register'
        $reasons.Add('This clone has no registration.')
    }
    else {
        # The GitHub runner that this clone's credentials belong to, by id.
        $linked = @($LocalRemote, $Remote) | Where-Object { $_ -and [int64]$_.Id -eq [int64]$Local.agentId } | Select-Object -First 1
        if (-not $HasCredentials) {
            $refusals.Add("This clone has a .runner registration for '$($Local.agentName)' but no .credentials; it was copied from another clone or damaged. Use a fresh clone, or delete the registration files and register again.")
        }
        if ($Remote -and [int64]$Remote.Id -ne [int64]$Local.agentId -and -not $Replace) {
            $refusals.Add("GitHub's runner '$($Remote.Name)' has id $($Remote.Id), this clone's registration has id $($Local.agentId): another machine or clone owns that name. Pick another name, or pass -Replace.")
        }
        if ($Local.agentName -ine $Name) { $reasons.Add("The name changed from '$($Local.agentName)' to '$Name'.") }
        if (-not (Test-SameGitHubTarget $Local.gitHubUrl $GitHubUrl)) { $reasons.Add("The target changed from $($Local.gitHubUrl) to $GitHubUrl.") }
        $savedFolder = Resolve-RunnerWorkFolder $Local.workFolder $RunnerDirectory
        if ($savedFolder -ine $wantedFolder) { $reasons.Add("The work folder changed from $savedFolder to $wantedFolder.") }
        if (-not $linked) { $reasons.Add("GitHub no longer has runner id $($Local.agentId); this clone's credentials are dead.") }
        if ($reasons.Count) { $action = 'reconfigure' }
        if ($linked) {
            # Custom labels added on GitHub survive a re-registration; the configured labels are always applied.
            $preserve = @($linked.CustomLabels | Where-Object { $_ -notin $Labels -and $_.ToLowerInvariant() -notin $RunnerDefaultLabels })
            if ($action -eq 'none') { $labelsToAdd = @($Labels | Where-Object { $_ -notin $linked.Labels }) }
        }
    }
    if ($refusals.Count) { $action = 'refuse' }
    [pscustomobject]@{
        Action         = $action
        Reasons        = @($reasons)
        Refusals       = @($refusals)
        LabelsToAdd    = @($labelsToAdd)
        PreserveLabels = @($preserve)
        AllLabels      = @(@($Labels) + $preserve | Select-Object -Unique)
        WorkFolder     = $wantedFolder
        LinkedId       = if ($linked) { [int64]$linked.Id }
        # Deregister the old registration at GitHub first when it still exists there; otherwise only the local files go.
        RemoveRemote   = [bool]$linked
        RemoveScope    = if ($Local) { Get-RunnerScope $Local.gitHubUrl }
        OldRunnerId    = if ($Local) { [int64]$Local.agentId }
    }
}

# Copies the registration files to _recovery\<utc> with the plan, before they are changed. Keeps the newest five.
function Save-RegistrationEvidence([string] $RunnerDirectory, $Plan) {
    $recovery = Join-Path $RunnerDirectory '_recovery'
    $folder = Join-Path $recovery ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))
    New-Item -ItemType Directory -Force $folder | Out-Null
    foreach ($file in $RunnerRegistrationFiles) {
        $source = Join-Path $RunnerDirectory $file
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $folder }
    }
    $Plan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder 'plan.json')
    Get-ChildItem -LiteralPath $recovery -Directory | Sort-Object Name -Descending | Select-Object -Skip 5 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $folder
}

function Restore-RegistrationEvidence([string] $RunnerDirectory, [string] $Folder) {
    foreach ($file in $RunnerRegistrationFiles) { Remove-Item -LiteralPath (Join-Path $RunnerDirectory $file) -Force -ErrorAction SilentlyContinue }
    foreach ($file in $RunnerRegistrationFiles) {
        $saved = Join-Path $Folder $file
        if (Test-Path -LiteralPath $saved) { Copy-Item -LiteralPath $saved -Destination $RunnerDirectory -Force }
    }
}

# Applies a plan. $BeforeChange runs once before anything is altered (stop the supervisor, drain). Returns what happened.
function Invoke-RunnerRegistration {
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [string] $RunnerDirectory,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $GitHubUrl,
        [switch] $Replace,
        [scriptblock] $BeforeChange,
        # How to run the runner's config command (default: config.cmd in the runner directory). The Linux runner is configured
        # from a throwaway container of its image.
        [scriptblock] $Configure,
        # The --work value when it is not a Windows path (the Linux runner's work folder is inside its container).
        [string] $WorkArgument
    )
    if ($Plan.Action -eq 'refuse') { throw "Registration refused:`n - $($Plan.Refusals -join "`n - ")" }
    $scope = Get-RunnerScope $GitHubUrl
    if ($Plan.Action -eq 'none') {
        if ($Plan.LabelsToAdd.Count) {
            Add-GitHubRunnerLabels $scope $Plan.LinkedId $Plan.LabelsToAdd
            return [pscustomobject]@{ Result = 'labels-added'; Evidence = $null; Labels = $Plan.LabelsToAdd }
        }
        return [pscustomobject]@{ Result = 'unchanged'; Evidence = $null; Labels = @() }
    }
    if ($BeforeChange) { & $BeforeChange }
    if (-not $Configure) {
        $configCmd = Join-Path $RunnerDirectory 'config.cmd'
        if (-not (Test-Path -LiteralPath $configCmd)) { throw "$configCmd is missing; extract the runner first." }
        $Configure = { & $configCmd @args }.GetNewClosure()
    }
    if (-not $WorkArgument) { $WorkArgument = $Plan.WorkFolder }
    $evidence = Save-RegistrationEvidence $RunnerDirectory $Plan
    try {
        if ($Plan.Action -eq 'reconfigure') {
            if ($Plan.RemoveRemote) {
                $removeToken = Get-RunnerToken $Plan.RemoveScope 'remove'
                $output = & $Configure remove --token $removeToken 2>&1 | ForEach-Object { "$_" }
                if ($LASTEXITCODE) { throw "config remove exited ${LASTEXITCODE}: $($output -join ' ')" }
            }
            foreach ($file in $RunnerRegistrationFiles) { Remove-Item -LiteralPath (Join-Path $RunnerDirectory $file) -Force -ErrorAction SilentlyContinue }
        }
        $arguments = @('--unattended', '--url', $GitHubUrl, '--token', (Get-RunnerToken $scope 'registration'), '--name', $Name, '--labels', ($Plan.AllLabels -join ','), '--work', $WorkArgument)
        if ($Replace) { $arguments += '--replace' }
        $output = & $Configure @arguments 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE) { throw "config exited ${LASTEXITCODE}: $($output -join ' ')" }
        $now = Get-LocalRegistration $RunnerDirectory
        if (-not $now -or $now.agentName -ine $Name) { throw "config reported success but .runner does not hold '$Name'." }
    }
    catch {
        $reason = $_.Exception.Message
        # The old registration is put back unless it was already removed at GitHub, in which case its files are dead anyway.
        Restore-RegistrationEvidence $RunnerDirectory $evidence
        throw "Registering '$Name' failed: $reason`nThe previous local registration files were restored from $evidence."
    }
    [pscustomobject]@{ Result = $Plan.Action; Evidence = $evidence; Labels = $Plan.AllLabels }
}

# After registration: the local files and GitHub agree on identity, target, work folder and labels.
# Returns the problems; an empty list means verified.
function Confirm-RunnerRegistration {
    param([string] $RunnerDirectory, [string] $Name, [string] $GitHubUrl, [string[]] $Labels, [string] $WorkFolder)
    $problems = [Collections.Generic.List[string]]::new()
    $local = Get-LocalRegistration $RunnerDirectory
    if (-not $local) { return @('No .runner registration exists.') }
    if ($local.agentName -ine $Name) { $problems.Add("Local name is '$($local.agentName)', expected '$Name'.") }
    if (-not (Test-SameGitHubTarget $local.gitHubUrl $GitHubUrl)) { $problems.Add("Local target is $($local.gitHubUrl), expected $GitHubUrl.") }
    if ((Resolve-RunnerWorkFolder $local.workFolder $RunnerDirectory) -ine (Resolve-RunnerWorkFolder $WorkFolder $RunnerDirectory)) { $problems.Add("Local work folder is $($local.workFolder), expected $WorkFolder.") }
    if (-not (Test-Path -LiteralPath (Join-Path $RunnerDirectory '.credentials'))) { $problems.Add('.credentials is missing.') }
    $remote = Get-GitHubRunner (Get-RunnerScope $GitHubUrl) $Name
    if (-not $remote) { $problems.Add("GitHub has no runner named '$Name' at $GitHubUrl.") }
    else {
        if ([int64]$remote.Id -ne [int64]$local.agentId) { $problems.Add("GitHub's runner id is $($remote.Id), the local registration's is $($local.agentId).") }
        $missing = @($Labels | Where-Object { $_ -notin $remote.Labels })
        if ($missing) { $problems.Add("GitHub's runner lacks labels: $($missing -join ', ').") }
    }
    @($problems)
}
