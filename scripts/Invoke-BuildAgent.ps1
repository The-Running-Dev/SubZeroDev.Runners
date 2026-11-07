#Requires -Version 7.2
# Runs `build-agent build <Type>` for a workflow step on this runner instance: the pinned tool, the digest-pinned image,
# this instance's own workspace. Workflows call this script and nothing else, so the tool location, image reference,
# Docker connection and mapping live in runners.json and scripts\BuildAgent.ps1 only.
#
#   - name: Build
#     shell: pwsh
#     run: ./Invoke-BuildAgent.ps1 -Type docker -Source $env:GITHUB_WORKSPACE
#
# The supervisor exports SZR_SCRIPTS (this scripts folder) to the runner and so to its jobs, so a step can call
# `& "$env:SZR_SCRIPTS\Invoke-BuildAgent.ps1" ...` without knowing where this instance's clone is.
#
# -Source is the checked-out repository. It is copied (robocopy, no .git history needed beyond what the build reads) into the
# instance's build workspace, because build-agent mounts one directory and the build output and caches live beside it.
# -Dry prints the invocation and exits without running anything.
param(
    [Parameter(Mandatory)] [string] $Type,
    # The directory to build. Default: the current directory.
    [string] $Source = (Get-Location).Path,
    # After the build, copy the output directory here (for actions/upload-artifact).
    [string] $CopyOutputTo,
    [switch] $Dry,
    [Parameter(ValueFromRemainingArguments)] [string[]] $BuildArguments = @()
)
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\BuildAgent.ps1"
$settings = Get-BuildAgentSettings $Config
if (-not $settings.Enabled) { throw 'buildAgent.enabled is false for this machine.' }
Assert-BuildAgentMapping $settings $Root
# `--` separates this script's parameters from the build-agent parameters.
$arguments = @($BuildArguments | Where-Object { $_ -ne '--' })
$invocation = Get-BuildAgentInvocation -Settings $settings -Type $Type -Arguments $arguments
if ($Dry) {
    [pscustomobject]@{ FilePath = $invocation.FilePath; Arguments = $invocation.Arguments; WorkingDirectory = $invocation.WorkingDirectory; Image = $settings.Image; DockerHost = $settings.DockerHost } | ConvertTo-Json
    return
}
$problems = @(
    if (-not (Test-Path -LiteralPath $settings.ToolExe)) { "BuildAgent.Tool is not installed ($($settings.ToolExe)). Run Setup-WindowsRunners.ps1." }
    if (-not (Test-BuildAgentRuntime $settings)) { "The .NET $($settings.RuntimeChannel) runtime is missing ($($settings.RuntimeDirectory)). Run Setup-WindowsRunners.ps1." }
)
if ($problems) { throw ($problems -join "`n") }
$daemon = Get-DockerDaemonState $Docker $settings.DockerHost 30
if (-not $daemon.Reachable -or $daemon.OSType -ne 'linux') { [Console]::Error.WriteLine($daemon.Detail); exit 5 }

# One lock per instance workspace: two jobs on one instance cannot interleave; different instances use different directories.
$mutex = [Threading.Mutex]::new($false, "Local\SubZeroDev.Runners.BuildAgent.$($settings.Instance)")
if (-not $mutex.WaitOne([TimeSpan]::FromMinutes(30))) { throw "The build workspace of instance $($settings.Instance) is busy." }
try {
    $sourcePath = Get-CanonicalPath $Source
    if (Test-PathUnder $sourcePath $settings.Workspace) { throw "$sourcePath is inside the build workspace; pass the checked-out repository." }
    # Mirror the source; the output and cache directories are kept.
    $keep = @($Config.buildAgent.paths.outputDirectory, $Config.buildAgent.paths.cacheDirectory)
    New-Item -ItemType Directory -Force $settings.Workspace, $settings.OutputDirectory, $settings.CacheDirectory | Out-Null
    Invoke-Native robocopy @($sourcePath, $settings.Workspace, '/MIR', '/XD', $keep[0], $keep[1], '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:2', '/W:2') 'robocopy of the source' @(0, 1, 2, 3, 4, 5, 6, 7) | Out-Null
    Write-Output "build-agent $($settings.Version) build $Type in $($settings.Workspace) with image $($settings.ImageDigest)"
    $exit = Invoke-BuildAgentInvocation $invocation
    # The status is the tool's own, unchanged, so the workflow step fails with the code the BuildAgent docs define.
    if ($exit -ne 0) { [Console]::Error.WriteLine("build-agent exited $exit. $(Get-BuildAgentExitMeaning $exit)") }
    if ($CopyOutputTo -and (Test-Path -LiteralPath $settings.OutputDirectory)) {
        New-Item -ItemType Directory -Force $CopyOutputTo | Out-Null
        Invoke-Native robocopy @($settings.OutputDirectory, $CopyOutputTo, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') 'copying the build output' @(0, 1, 2, 3, 4, 5, 6, 7) | Out-Null
    }
    exit $exit
}
finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
