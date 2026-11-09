#Requires -Version 7.2
# Executes the real container-creation entry point with a temporary Common.ps1
# and fake Docker. No daemon, registration, runner process or GitHub is touched.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('linux-mount-test-' + [guid]::NewGuid().ToString('N'))
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Get-RunName($Arguments) { $index = [array]::IndexOf([object[]]$Arguments, '--name'); if ($index -ge 0) { $Arguments[$index + 1] } }
try {
    $scripts = Join-Path $temp 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item (Join-Path $repo 'scripts/New-LinuxRunner.ps1') $scripts
    Copy-Item (Join-Path $repo 'scripts/Compose.ps1') $scripts
    foreach ($file in 'RunnerArchive.ps1', 'BuildAgent.ps1', 'Registration.ps1', 'Lifecycle.ps1') { Set-Content (Join-Path $scripts $file) '# Fixture: no production module loaded.' }
    @'
$Root = Split-Path $PSScriptRoot -Parent
$Config = Get-Content -Raw (Join-Path $Root 'config.json') | ConvertFrom-Json
$LinuxRunner = Join-Path $Root 'runner installation with spaces'
$DockerSidecar = if ($Config.linux.docker.mode -eq 'sidecar') { $Config.linux.docker.container }
$Docker = 'Invoke-FixtureDocker'
function Enter-HostLock { param($Kind, [switch] $Joinable) }
function Exit-HostLock { }
function Read-HostInventory { [pscustomobject]@{ State = 'absent' } }
function Get-LinuxMaintenanceFile { Join-Path $Root 'maintenance.json' }
function Enter-RunnerMaintenance { [pscustomobject]@{ Outcome='drained' } }
function Exit-RunnerMaintenance { }
function Remove-LinuxContainer { param($Name) [pscustomobject]@{ Result='removed' } }
function Invoke-FixtureDocker {
    Add-Content (Join-Path $Root 'docker.jsonl') (ConvertTo-Json -InputObject @($args) -Compress)
    $global:LASTEXITCODE = 0
    if ($Config.failSidecar -and $args[0] -eq 'run' -and $args -contains $Config.linux.docker.container) { $global:LASTEXITCODE = 1 }
}
'@ | Set-Content (Join-Path $scripts 'Common.ps1')
    foreach ($mode in 'sidecar', 'dind') {
        $config = Get-Content -Raw (Join-Path $repo 'runners.json') | ConvertFrom-Json
        $config.linux.docker.mode = $mode
        $config | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $temp 'config.json')
        $source = Join-Path $temp 'runner installation with spaces'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        $registration = '{"agentId":12345,"agentName":"synthetic-existing-runner","workFolder":"' + $config.linux.workFolder + '"}'
        Set-Content (Join-Path $source '.runner') $registration
        Set-Content (Join-Path $source '.credentials') 'synthetic credential canary'
        $before = Get-FileHash (Join-Path $source '.runner'), (Join-Path $source '.credentials')
        Remove-Item (Join-Path $temp 'docker.jsonl') -ErrorAction SilentlyContinue
        & (Join-Path $scripts 'New-LinuxRunner.ps1')
        $after = Get-FileHash (Join-Path $source '.runner'), (Join-Path $source '.credentials')
        Assert (($before.Hash -join ',') -ceq ($after.Hash -join ',')) 'Existing synthetic registration identity or credential file changed.'
        $calls = @(Get-Content (Join-Path $temp 'docker.jsonl') | ForEach-Object { [pscustomobject]@{ Arguments=@($_ | ConvertFrom-Json) } })
        $runs = @($calls | Where-Object { $_.Arguments[0] -eq 'run' })
        $runner = @($runs | Where-Object { (Get-RunName $_.Arguments) -eq $config.linux.container })
        Assert ($runner.Count -eq 1) "Runner container was not created exactly once: $(Get-Content (Join-Path $temp 'docker.jsonl') -Raw)"
        Assert ($runner[0].Arguments -contains "type=bind,source=$source,target=/runner") 'Runner does not retain its writable installation mount.'
        $sidecar = @($runs | Where-Object { (Get-RunName $_.Arguments) -eq $config.linux.docker.container })
        if ($mode -eq 'sidecar') {
            Assert ($sidecar.Count -eq 1) 'Sidecar was not created exactly once.'
            $runtimeVolume = "$($config.linux.container)-runtimes"
            Assert ($sidecar[0].Arguments -contains "type=volume,source=$runtimeVolume,target=/runner/externals,readonly,volume-nocopy") 'Sidecar cannot resolve the read-only runtime projection at the Actions bind source.'
            Assert (@($sidecar[0].Arguments | Where-Object { $_ -like 'type=bind,*' -or $_ -like '*target=/runner,*' }).Count -eq 0) 'Sidecar exposes a host bind or the complete runner installation.'
            Assert ($runner[0].Arguments -contains "type=volume,source=$runtimeVolume,target=/runner-runtime,volume-nocopy") 'Runner does not share the writable runtime projection.'
            Assert ($runner[0].Arguments -contains 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/runner-hooks/Sync-LinuxRunnerRuntimes.sh') 'Runtime projection is not refreshed before job containers start.'
            $work = "type=volume,source=$($config.linux.docker.workVolume),target=$($config.linux.workFolder)"
            Assert ($sidecar[0].Arguments -contains $work -and $runner[0].Arguments -contains $work) 'Runner and daemon no longer share the workspace at the same path.'
            Assert ($runner[0].Arguments -notcontains '--privileged') 'Sidecar mode unexpectedly privileged the runner.'
        } else {
            Assert ($sidecar.Count -eq 0) 'DinD mode created a sidecar.'
            Assert ($runner[0].Arguments -contains '--privileged' -and $runner[0].Arguments -contains 'BUILD_AGENT_DOCKERD=1') 'DinD daemon settings changed.'
            Assert (@($runner[0].Arguments | Where-Object { $_ -like '*ACTIONS_RUNNER_HOOK_JOB_STARTED*' -or $_ -like '*target=/runner-runtime*' }).Count -eq 0) 'DinD unexpectedly acquired sidecar projection settings.'
        }
    }
    # Failed sidecar start must not continue to a runner with unusable container support.
    $config.linux.docker.mode = 'sidecar'
    $config | Add-Member -NotePropertyName failSidecar -NotePropertyValue $true
    $config | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $temp 'config.json')
    Remove-Item (Join-Path $temp 'docker.jsonl')
    $failed = $false
    try { & (Join-Path $scripts 'New-LinuxRunner.ps1') } catch { $failed = $_.Exception.Message -match 'sidecar start failed' }
    Assert $failed 'Sidecar failure was hidden.'
    $calls = @(Get-Content (Join-Path $temp 'docker.jsonl') | ForEach-Object { [pscustomobject]@{ Arguments=@($_ | ConvertFrom-Json) } })
    Assert (@($calls | Where-Object { $_.Arguments[0] -eq 'run' -and (Get-RunName $_.Arguments) -eq $config.linux.container }).Count -eq 0) 'Runner started after sidecar failure.'
    # Refuse a state-volume alias before any Docker invocation/removal.
    $config.failSidecar = $false
    $config.linux.docker.certsVolume = "$($config.linux.container)-runtimes"
    $config | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $temp 'config.json')
    Remove-Item (Join-Path $temp 'docker.jsonl')
    $failed = $false
    try { & (Join-Path $scripts 'New-LinuxRunner.ps1') } catch { $failed = $_.Exception.Message -match 'runtime volume must not alias' }
    Assert $failed 'Runtime volume may alias sensitive state.'
    Assert (-not (Test-Path (Join-Path $temp 'docker.jsonl'))) 'Volume alias refusal touched Docker.'
    Write-Output 'PASS: real creation entry point, runtime-only sidecar volume and pre-job hook, no registration bind, shared workspace, spaces in source, writable runner, DinD unchanged, failure/alias refusal (Docker mocked).'
    # The negative fixture deliberately set this to 1. GitHub's pwsh wrapper exits
    # with LASTEXITCODE after the script returns, so report the successful test exit.
    $global:LASTEXITCODE = 0
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
