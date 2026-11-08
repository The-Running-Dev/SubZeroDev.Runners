#Requires -Version 7.2
# Registers both runners with GitHub under github.url, the names in runners.json (and runners.local.json), github.labels and
# each runner's own labels. Each runner's registration is compared with what is asked for and with what GitHub has:
#   - nothing differs        -> nothing changes (names, ids, custom labels and credentials stay);
#   - labels are missing     -> they are added at GitHub, the registration stays;
#   - name, target or work folder changed, or GitHub lost the runner -> the runner is drained, deregistered and registered again;
#   - the name belongs to another machine or clone -> refused, unless -Replace.
# One runner failing does not stop the other; the exit code is 1 when either failed. Needs gh signed in as an admin of the
# target; the short-lived tokens go straight to the runner's config and are never printed.
param(
    # Take over runners already registered under these names by another machine or clone.
    [switch] $Replace,
    # Registration only: do not start the runners afterwards.
    [switch] $NoStart
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
$github = $Config.github
if (-not $github.url) { throw 'Set github.url in runners.local.json, for example { "github": { "url": "https://github.com/<owner>/<repo>" } }.' }
$scope = Get-RunnerScope $github.url

$runners = @(
    @{
        Label = 'Windows'; Name = $Config.windows.name; Directory = $WindowsRunner; WorkFolder = $Config.windows.workFolder; WorkArgument = $null
        Labels = @(@($github.labels) + @($Config.windows.labels) | Select-Object -Unique); Configure = $null
        Stop = { $stopped = Stop-WindowsRunner -Reason 'registration change'; if ($stopped.Outcome -eq 'timeout') { throw $stopped.Retained }; if ($stopped.Outcome -eq 'failed') { throw "The runner did not stop, so its registration was not changed. $(@($stopped.Failures) -join ' ')" } }
    }
    @{
        # The Linux runner is configured from a throwaway container of the same image, on the same /runner mount.
        Label = 'Linux'; Name = $Config.linux.name; Directory = $LinuxRunner; WorkFolder = $Config.linux.workFolder; WorkArgument = $Config.linux.workFolder
        Labels = @(@($github.labels) + @($Config.linux.labels) | Select-Object -Unique)
        Configure = { & $Docker run --rm --mount "type=bind,source=$LinuxRunner,target=/runner" $Config.linux.image configure @args }
        Stop = { $stopped = Stop-LinuxRunners; if ($stopped.Outcome -eq 'timeout') { throw $stopped.Retained }; if ($stopped.Outcome -eq 'failed') { throw "The runner did not stop, so its registration was not changed. $(@($stopped.Failures) -join ' ')" } }
    }
)

$failures = [Collections.Generic.List[string]]::new()
$changed = $false
foreach ($runner in $runners) {
    try {
        $registration = Get-LocalRegistration $runner.Directory
        $plan = Get-RegistrationPlan `
            -Local $registration -Remote (Get-GitHubRunner $scope $runner.Name) `
            -LocalRemote $(if ($registration) { Get-GitHubRunner (Get-RunnerScope $registration.gitHubUrl) $registration.agentName }) `
            -Name $runner.Name -GitHubUrl $github.url -Labels $runner.Labels -WorkFolder $runner.WorkFolder -RunnerDirectory $runner.Directory `
            -HasCredentials (Test-Path -LiteralPath (Join-Path $runner.Directory '.credentials')) -Replace:$Replace
        foreach ($reason in $plan.Reasons) { Write-Output "$($runner.Label): $reason" }
        $parameters = @{ Plan = $plan; RunnerDirectory = $runner.Directory; Name = $runner.Name; GitHubUrl = $github.url; Replace = $Replace; BeforeChange = $runner.Stop }
        if ($runner.Configure) { $parameters.Configure = $runner.Configure }
        if ($runner.WorkArgument) { $parameters.WorkArgument = $runner.WorkArgument }
        $applied = Invoke-RunnerRegistration @parameters
        if ($applied.Result -notin 'unchanged', 'labels-added') { $changed = $true }
        $problems = @(Confirm-RunnerRegistration -RunnerDirectory $runner.Directory -Name $runner.Name -GitHubUrl $github.url -Labels $runner.Labels -WorkFolder $runner.WorkFolder)
        if ($problems) { throw "does not match the configuration:`n - $($problems -join "`n - ")" }
        Write-Output "$($runner.Label): $($runner.Name) $($applied.Result)$(if ($applied.Evidence) { "; previous registration files in $($applied.Evidence)" })."
    }
    catch {
        $failures.Add("$($runner.Label) runner $($runner.Name): $($_.Exception.Message)")
        Write-Warning $failures[-1]
    }
}
if (-not $NoStart) { & (Join-Path $PSScriptRoot 'Start-Runners.ps1') }
if ($failures.Count) { Write-Error "Registration incomplete:`n - $($failures -join "`n - ")" -ErrorAction Continue; exit 1 }
