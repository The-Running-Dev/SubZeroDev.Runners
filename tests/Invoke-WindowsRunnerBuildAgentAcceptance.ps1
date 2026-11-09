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
    # Shared durable dispatch journal for automatic setup; standalone runs use a stable per-target temp directory.
    [string] $StateDirectory,
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

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\WindowsRunnerSetup.ps1')
if (-not $StateDirectory) {
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Repository|$ComputerName|$RunnerLabel")))
    $StateDirectory = Join-Path ([IO.Path]::GetTempPath()) "runner-buildagent-$key"
}
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$journal = Get-RunnerAcceptanceState $StateDirectory
if ($journal.repository -and $journal.repository -ine $Repository) { throw 'Acceptance journal belongs to another repository.' }
# Standalone dispatch never resolves a lifecycle stop journal. Automatic setup recovers it before calling this worker.
if ($journal.activeRun) {
    if ($journal.activeRun.workflow -cne 'windows-runner-buildagent.yml') { throw 'A lifecycle journal requires host setup recovery before builds.' }
    Resume-RunnerSetupAcceptance -InstallRoot $StateDirectory -Repository $Repository -Count 2
    $journal = Get-RunnerAcceptanceState $StateDirectory
}
$journal.repository = $Repository
$workflowFile = 'windows-runner-buildagent.yml'
$branch = Install-RunnerAcceptanceWorkflow -Repository $Repository -SourceClone (Split-Path $PSScriptRoot -Parent) -WorkflowFile $workflowFile -InstallWorkflow ([bool]$InstallWorkflow)
$setupId = [guid]::NewGuid().ToString('N')
$pins = (Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'runners.json') -Raw | ConvertFrom-Json).buildAgent
$journal.activeRun = @{ id = 0; correlation = $setupId; workflow = $workflowFile; branch = $branch; clone = ''; stopAttempted = $false }
Save-RunnerAcceptanceState $StateDirectory $journal
try {
    Invoke-Gh @('api', '-X', 'POST', "repos/$Repository/actions/workflows/$workflowFile/dispatches") @{
        ref = $branch
        inputs = @{
            computer_name = $ComputerName; runner_label = $RunnerLabel; runner_names = (ConvertTo-Json -InputObject @($ExpectedRunnerNames) -Compress); setup_id = $setupId
            expected_tool_version = $pins.tool.version; expected_image_digest = ($pins.image -replace '^.*@', '')
        }
    } | Out-Null
    Write-Output "Dispatched $workflowFile in $Repository for $ComputerName ($RunnerLabel), correlation $setupId."

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $run = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $run) {
            $run = Find-RunnerAcceptanceRun $Repository $setupId $workflowFile
            if ($run) {
                $journal.activeRun.id = $run.id
                Save-RunnerAcceptanceState $StateDirectory $journal
            }
        }
        else { $run = Invoke-Gh @('api', "repos/$Repository/actions/runs/$($journal.activeRun.id)") }
        if ($run) { Assert-RunnerAcceptanceRun $run $journal.activeRun }
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
    # Keep the intent after ambiguous dispatch/discovery failures. A later invocation searches it before creating any new run.
    if ($journal.activeRun.id) {
        Stop-RunnerAcceptanceRun $Repository $journal.activeRun | Out-Null
        $journal.activeRun = $null
        Save-RunnerAcceptanceState $StateDirectory $journal
    }
}
