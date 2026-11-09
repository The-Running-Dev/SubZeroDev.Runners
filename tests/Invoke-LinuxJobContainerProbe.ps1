#Requires -Version 7.2
<#
Opt-in, real Docker probe on the runner host. Does not stop/recreate/register a runner
or dispatch GitHub jobs. Creates only a uniquely named, bounded nested test container
and a temporary workspace directory, then removes both. Requires the existing runner
container and its configured daemon to be healthy. Run after New-LinuxRunner.ps1.
#>
[CmdletBinding()]
param(
    [string] $DockerCommand = 'docker',
    [string] $OutputPath = (Join-Path ([IO.Path]::GetTempPath()) ('linux-job-probe-' + [guid]::NewGuid().ToString('N') + '.json'))
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts/RunnerConfig.ps1')
$config = Read-RunnerConfig -Root $root
$dockerPath = (Get-Command $DockerCommand -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$id = [guid]::NewGuid().ToString('N')
$name = 'szr-docs-probe-' + $id
$runner = $config.linux.container
$work = $config.linux.workFolder.TrimEnd('/') + '/.szr-docs-probe-' + $id
if ($work -notmatch '^/[A-Za-z0-9_./-]+$' -or $work.Split('/') -contains '..') { throw 'Probe needs a safe absolute Linux workspace path.' }
function Invoke-ProbeDocker([string[]] $Arguments, [int] $TimeoutSeconds = 120, [switch] $AllowFailure) {
    $info = [Diagnostics.ProcessStartInfo]::new($dockerPath)
    $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Docker CLI did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill($true); throw "Docker probe command timed out after $TimeoutSeconds seconds." }
        $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) { throw "Docker probe command exited $($process.ExitCode): $err $out" }
        [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$out.Trim(); Error=$err.Trim() }
    } finally { $process.Dispose() }
}
$report = [ordered]@{ status='failure'; startedUtc=[DateTime]::UtcNow.ToString('o'); runnerContainer=$runner; dockerMode=$config.linux.docker.mode; selectedImage=$config.buildAgent.image; container=$name }
$failure = $null
$createdWork = $false
try {
    $state = Invoke-ProbeDocker @('inspect', '--format', '{{.State.Running}}', $runner)
    if ($state.Output -ne 'true') { throw 'Configured Linux runner container is not running.' }
    # The resolved target is useful when a runner self-update has made externals a symlink.
    $report.externalsTarget = (Invoke-ProbeDocker @('exec', $runner, 'readlink', '-f', '/runner/externals')).Output
    $createdWork = $true
    Invoke-ProbeDocker @('exec', '--env', "PROBE_DIR=$work", '--env', "PROBE_MARKER=$id", $runner, '/bin/sh', '-c',
        'set -eu; mkdir -p "$PROBE_DIR/runner-layout/externals.fixture"; printf "%s" "$PROBE_MARKER" > "$PROBE_DIR/marker"; printf "%s" "$PROBE_MARKER" > "$PROBE_DIR/runner-layout/externals.fixture/marker"; ln -s externals.fixture "$PROBE_DIR/runner-layout/externals"') | Out-Null
    # Use the runner's own Docker connection/TLS environment. The daemon must resolve
    # both bind sources itself, exactly as it does when Actions creates a job container.
    $run = Invoke-ProbeDocker @('exec', $runner, 'docker', 'run', '--rm', '--name', $name,
        '--network', 'none', '--cpus', '1', '--memory', '256m', '--read-only',
        '--mount', 'type=bind,source=/runner/externals,target=/__e,readonly',
        '--mount', "type=bind,source=$work,target=/__w,readonly", '--env', "PROBE_MARKER=$id",
        '--mount', "type=bind,source=$work/runner-layout/externals,target=/__fixture,readonly",
        '--entrypoint', '/bin/sh', $config.buildAgent.image, '-c',
        'set -eu; test "$(cat /__w/marker)" = "$PROBE_MARKER"; test "$(cat /__fixture/marker)" = "$PROBE_MARKER"; /__e/node24/bin/node --version')
    if ($run.Output -notmatch '^v24\.') { throw "Expected runner Node 24 runtime, got: $($run.Output)" }
    $report.nodeRuntime = $run.Output
    $report.workspaceMarkerVerified = $true
    $report.selfUpdateSymlinkVerified = $true
    $report.status = 'success'
} catch { $failure = $_.Exception.Message; $report.error = $failure }
finally {
    # Address only this invocation's known unique name. Never prune unrelated objects.
    try {
        $inspect = Invoke-ProbeDocker @('exec', $runner, 'docker', 'container', 'inspect', '--format', '{{.Name}}', $name) -TimeoutSeconds 15 -AllowFailure
        if ($inspect.ExitCode -eq 0) { Invoke-ProbeDocker @('exec', $runner, 'docker', 'rm', '-f', $name) -TimeoutSeconds 30 | Out-Null }
        if ($createdWork) { Invoke-ProbeDocker @('exec', $runner, 'rm', '-rf', '--', $work) -TimeoutSeconds 15 | Out-Null }
    } catch { $report.status='failure'; $report.cleanupError=$_.Exception.Message; if (-not $failure) { $failure=$_.Exception.Message } }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $absolute = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Path (Split-Path $absolute -Parent) -Force | Out-Null
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $absolute -Encoding utf8
    Write-Output "Probe evidence: $absolute"
}
if ($failure) { throw $failure }
Write-Output 'PASS: nested job container sees the live runner Node 24 runtime, workspace marker and versioned symlink target.'
