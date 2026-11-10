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
    foreach ($file in 'RunnerArchive.ps1', 'BuildAgent.ps1', 'Registration.ps1', 'Lifecycle.ps1') { Set-Content (Join-Path $scripts $file) '# Fixture: no production module loaded.' }
    @'
$Root = Split-Path $PSScriptRoot -Parent
$Config = Get-Content -Raw (Join-Path $Root 'config.json') | ConvertFrom-Json
$LinuxRunner = Join-Path $Root 'runner installation with spaces'
$DockerSidecar = if ($Config.linux.docker.mode -eq 'sidecar') { $Config.linux.docker.container }
$Docker = 'Invoke-FixtureDocker'
function Enter-HostLock { param($Kind, [switch] $Joinable) }
function Get-LinuxMaintenanceFile { Join-Path $Root 'maintenance.json' }
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
        Remove-Item (Join-Path $temp 'docker.jsonl') -ErrorAction SilentlyContinue
        & (Join-Path $scripts 'New-LinuxRunner.ps1')
        $calls = @(Get-Content (Join-Path $temp 'docker.jsonl') | ForEach-Object { [pscustomobject]@{ Arguments=@($_ | ConvertFrom-Json) } })
        $runs = @($calls | Where-Object { $_.Arguments[0] -eq 'run' })
        $runner = @($runs | Where-Object { (Get-RunName $_.Arguments) -eq $config.linux.container })
        Assert ($runner.Count -eq 1) "Runner container was not created exactly once: $(Get-Content (Join-Path $temp 'docker.jsonl') -Raw)"
        $source = Join-Path $temp 'runner installation with spaces'
        Assert ($runner[0].Arguments -contains "type=bind,source=$source,target=/runner") 'Runner does not retain its writable installation mount.'
        $sidecar = @($runs | Where-Object { (Get-RunName $_.Arguments) -eq $config.linux.docker.container })
        if ($mode -eq 'sidecar') {
            Assert ($sidecar.Count -eq 1) 'Sidecar was not created exactly once.'
            Assert ($sidecar[0].Arguments -contains "type=bind,source=$source,target=/runner,readonly") 'Sidecar cannot resolve runner externals/self-update targets at the same path.'
            $work = "type=volume,source=$($config.linux.docker.workVolume),target=$($config.linux.workFolder)"
            Assert ($sidecar[0].Arguments -contains $work -and $runner[0].Arguments -contains $work) 'Runner and daemon no longer share the workspace at the same path.'
            Assert ($runner[0].Arguments -notcontains '--privileged') 'Sidecar mode unexpectedly privileged the runner.'
        } else {
            Assert ($sidecar.Count -eq 0) 'DinD mode created a sidecar.'
            Assert ($runner[0].Arguments -contains '--privileged' -and $runner[0].Arguments -contains 'BUILD_AGENT_DOCKERD=1') 'DinD daemon settings changed.'
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
    Write-Output 'PASS: real creation entry point, shared workspace/externals paths, spaces in source, read-only sidecar, writable runner, DinD unchanged, failed-sidecar refusal (Docker mocked).'
    # The negative fixture deliberately set this to 1. GitHub's pwsh wrapper exits
    # with LASTEXITCODE after the script returns, so report the successful test exit.
    $global:LASTEXITCODE = 0
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
