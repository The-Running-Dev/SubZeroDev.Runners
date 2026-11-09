# Read-only: no registrations, labels, files, workflows or job state are changed.
# Run with the host's existing authenticated gh session and its Linux .runner file.
# Repository registrations select their own repository. Organization registrations
# require a candidate repository and verified runner-group access.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunnerRegistration,
    [string] $Repository
)
$ErrorActionPreference = 'Stop'
function Get-GitHub([string] $Endpoint) {
    $text = & gh api --method GET $Endpoint --paginate --slurp
    if ($LASTEXITCODE -ne 0) { throw "Cannot verify $Endpoint. Eligibility remains unknown." }
    @($text | ConvertFrom-Json)
}
$local = Get-Content -Raw -LiteralPath $RunnerRegistration | ConvertFrom-Json
$url = [uri]$local.gitHubUrl
if ($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or -not $url.IsDefaultPort -or $url.UserInfo -or $url.Query -or $url.Fragment) { throw 'This smoke test requires an HTTPS github.com registration URL.' }
$parts = $url.AbsolutePath.Trim('/').Split('/')
if ($parts.Count -notin 1, 2 -or @($parts | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' }).Count -or [int64]$local.agentId -le 0 -or -not $local.agentName) { throw 'Unrecognized registration identity or URL.' }
if ($parts.Count -eq 2) {
    $registeredRepository = $parts -join '/'
    if ($Repository -and $Repository -ne $registeredRepository) { throw "Runner is registered only to $registeredRepository; $Repository is not eligible." }
    $Repository = $registeredRepository
    $scope = "repos/$Repository"
} elseif ($parts.Count -eq 1) {
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Repository.Split('/')[0] -ne $parts[0]) {
        throw 'Organization runner: supply -Repository <same-org>/<candidate> to verify group access.'
    }
    $scope = "orgs/$($parts[0])"
} else { throw 'Unrecognized registration URL.' }
$remote = @((Get-GitHub "$scope/actions/runners?per_page=100").runners | Where-Object id -eq $local.agentId)
if ($remote.Count -ne 1 -or $remote[0].name -ne $local.agentName) { throw 'Local identity does not match the live registration.' }
$runner = $remote[0]
$labels = @($runner.labels.name)
if ($runner.os -ne 'linux' -or $labels -notcontains 'subzerodev-linux' -or $labels -notcontains 'self-hosted' -or $labels -notcontains 'X64') {
    throw 'Runner needs Linux, self-hosted, X64 and subzerodev-linux for this image.'
}
$repo = (Get-GitHub "repos/$Repository")[0]
if ($repo.full_name -ine $Repository -or $repo.archived -or $repo.disabled) { throw 'Consumer moved, is unavailable, archived or disabled; eligibility is unresolved.' }
if ($parts.Count -eq 1 -and $repo.owner.type -ne 'Organization') { throw 'Shared runners require an organization-owned consumer.' }
$policy = (Get-GitHub "repos/$Repository/actions/permissions")[0]
if ($policy.enabled -ne $true) { throw 'Consumer Actions policy is disabled or unreadable.' }
if ($runner.busy -isnot [bool]) { throw 'Runner availability could not be read.' }
$groupName = $null
if ($parts.Count -eq 1) {
    $groups = @((Get-GitHub "$scope/actions/runner-groups?per_page=100").runner_groups)
    $membership = @($groups | Where-Object {
        $members = @((Get-GitHub "$scope/actions/runner-groups/$($_.id)/runners?per_page=100").runners)
        $members.id -contains $runner.id
    })
    if ($membership.Count -ne 1) { throw 'Could not establish the runner group.' }
    $group = $membership[0]
    if ($group.inherited -or $group.restricted_to_workflows) { throw 'Inherited/workflow-restricted group: verify the exact reusable-workflow access before choosing this consumer.' }
    if (-not $repo.private -and -not $group.allows_public_repositories) { throw 'Runner group does not allow this public repository.' }
    if ($group.visibility -eq 'selected') {
        $allowed = @((Get-GitHub "$scope/actions/runner-groups/$($group.id)/repositories?per_page=100").repositories)
        if ($allowed.id -notcontains $repo.id) { throw 'Repository is not selected in the runner group.' }
    } elseif ($group.visibility -eq 'private') {
        if (-not $repo.private) { throw 'Runner group permits private repositories only.' }
    } elseif ($group.visibility -ne 'all') { throw 'Unrecognized runner group access policy.' }
    $groupName = $group.name
}
[pscustomobject]@{
    repository = $Repository; registrationUrl = $local.gitHubUrl
    runnerId = $runner.id; runnerName = $runner.name; labels = $labels
    runnerGroup = $groupName; status = $runner.status; busy = $runner.busy
    registrationEligible = $true; availableNow = ($runner.status -eq 'online' -and -not $runner.busy)
    workflowPolicyVerified = $false
    checkedAt = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 5
if ($runner.status -ne 'online' -or $runner.busy) { throw 'Registration is eligible, but the runner is not currently online and idle.' }
