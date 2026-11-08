#Requires -Version 7.2
# Dispatch the BuildAgent acceptance workflow in the repository the runners are registered for, wait for it, and judge it
# with Assert-WindowsRunnerBuildAgent.ps1. Run on the Windows host (or anywhere with an authenticated `gh` that can use
# the repository's Actions), with this clone's runners.json pins.
#
#   ./tests/Invoke-WindowsRunnerBuildAgentAcceptance.ps1 -Repository AbsoluteZeroDev/<repo> [-InstallWorkflow]
#
# -Repository must be a repository the registered runners can run workflows for: the organization (or user) the runners were
# registered to, not simply the account `gh` is signed in as. A runner group that does not include the repository leaves the
# jobs queued, and this script then cancels the run when -TimeoutMinutes passes.
# -InstallWorkflow commits tests\windows-runner-buildagent.yml to the repository's default branch if it is not there yet. Without it,
# a missing workflow is an error; a workflow that differs from this clone's template is always an error (it is never overwritten).
param(
    [Parameter(Mandatory)] [string] $Repository,
    [string] $ComputerName = $env:COMPUTERNAME,
    # Label that selects the two runners of this host; setup gives each host a pair label.
    [string] $RunnerLabel,
    [string[]] $ExpectedRunnerNames,
    [switch] $InstallWorkflow,
    [int] $TimeoutMinutes = 45,
    [string] $ReportDirectory,
    # Overridable for tests.
    [string] $CheckerPath = (Join-Path $PSScriptRoot 'Assert-WindowsRunnerBuildAgent.ps1')
)
$ErrorActionPreference = 'Stop'
function Invoke-Gh([string[]] $Arguments, $Body) {
    $output = if ($null -ne $Body) { ($Body | ConvertTo-Json -Depth 8 -Compress) | & gh @Arguments --input - } else { & gh @Arguments }
    if ($LASTEXITCODE) { throw "gh $($Arguments -join ' ') failed." }
    if ($output) { ($output -join "`n") | ConvertFrom-Json }
}
$name = $ComputerName.ToLowerInvariant()
if (-not $RunnerLabel) { $RunnerLabel = "subzerodev-pair-$name" }
if (-not $ExpectedRunnerNames) { $ExpectedRunnerNames = @('win01', 'win02') | ForEach-Object { "subzerodev.runner.windows.$name.$_" } }
if (@($ExpectedRunnerNames).Count -ne 2) { throw 'Exactly two expected runner names are required.' }

$repo = Invoke-Gh @('api', "repos/$Repository")
if (-not $repo.private) { throw "$Repository is public: self-hosted runners must not run workflows from a public repository." }
$template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'windows-runner-buildagent.yml')
$workflowFile = 'windows-runner-buildagent.yml'
$workflowPath = ".github/workflows/$workflowFile"
$existingJson = & gh api "repos/$Repository/contents/$workflowPath" 2>$null
if ($LASTEXITCODE -eq 0) {
    $existing = ($existingJson -join "`n") | ConvertFrom-Json
    $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing.content))
    if ($content.Replace("`r`n", "`n").TrimEnd() -cne $template.Replace("`r`n", "`n").TrimEnd()) { throw "Existing $workflowPath differs from this clone's template. Review it; it will not be overwritten." }
}
elseif ($InstallWorkflow) {
    Invoke-Gh @('api', '-X', 'PUT', "repos/$Repository/contents/$workflowPath") @{ message = 'Add manual Windows runner BuildAgent acceptance workflow'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($template)) } | Out-Null
}
else { throw "$workflowPath is not in $Repository. Rerun with -InstallWorkflow to commit it, or copy tests\windows-runner-buildagent.yml there." }

# A newly committed workflow can take a moment to appear in the Actions API.
$indexed = $false
for ($attempt = 0; $attempt -lt 12 -and -not $indexed; $attempt++) {
    & gh api "repos/$Repository/actions/workflows/$workflowFile" --silent 2>$null
    if ($LASTEXITCODE -eq 0) { $indexed = $true } else { Start-Sleep -Seconds 5 }
}
if (-not $indexed) { throw "The acceptance workflow is not available in Actions. Check $Repository's Actions policy." }

$setupId = [guid]::NewGuid().ToString('N')
$pins = (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'runners.json') -Raw | ConvertFrom-Json).buildAgent
Invoke-Gh @('api', '-X', 'POST', "repos/$Repository/actions/workflows/$workflowFile/dispatches") @{
    ref = $repo.default_branch
    inputs = @{
        computer_name = $ComputerName; runner_label = $RunnerLabel; runner_names = (ConvertTo-Json -InputObject @($ExpectedRunnerNames) -Compress); setup_id = $setupId
        expected_tool_version = $pins.tool.version; expected_image_digest = ($pins.image -replace '^.*@', '')
    }
} | Out-Null
Write-Output "Dispatched $workflowFile in $Repository for $ComputerName ($RunnerLabel), correlation $setupId."

$deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
$run = $null
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $run) {
            $runs = Invoke-Gh @('api', "repos/$Repository/actions/workflows/$workflowFile/runs?event=workflow_dispatch&per_page=100")
            $run = $runs.workflow_runs | Where-Object display_title -eq "Windows runner BuildAgent acceptance $setupId" | Select-Object -First 1
        }
        else { $run = Invoke-Gh @('api', "repos/$Repository/actions/runs/$($run.id)") }
        if ($run -and $run.status -eq 'completed') { break }
        Start-Sleep -Seconds 10
    }
    if (-not $run -or $run.status -ne 'completed') { throw "The acceptance run did not complete in $TimeoutMinutes minutes. Check that $Repository is in the runner group of both runners and that both slots are free." }
    Write-Output "Run $($run.id) $($run.conclusion): $($run.html_url)"
    $checkerArguments = @{ Repository = $Repository; RunId = $run.id; ComputerName = $ComputerName; ExpectedRunnerNames = $ExpectedRunnerNames }
    if ($ReportDirectory) { $checkerArguments.ReportDirectory = $ReportDirectory }
    if ($run.conclusion -ne 'success') {
        # The evidence of a failed run says which check failed; read it, then fail.
        try { & $CheckerPath @checkerArguments | Out-Host } catch { Write-Warning $_.Exception.Message }
        throw "The acceptance run failed: $($run.html_url)"
    }
    & $CheckerPath @checkerArguments | Out-Host
}
finally {
    if ($run -and $run.status -ne 'completed') {
        & gh api -X POST "repos/$Repository/actions/runs/$($run.id)/cancel" --silent
        if ($LASTEXITCODE) { Write-Warning "Could not cancel unfinished acceptance run $($run.id)." }
    }
}
